package fs

import "core:mem/virtual"
import "../crdt"
import "../fshist"
import "../fstree"
import "../journal"
import "../odb"
import "../prim"

REC_REDACT :: fshist.REC_REDACT

Redact_Result :: struct {
	spans:     int,
	zeroed:    i64,
	files:     int,
	rewrites:  int,
	dropped:   int,
	ranges:    []journal.Range,
	unreached: []odb.Unreached,
}

Redact_Plan :: struct {
	data: rawptr,
	call: proc(data: rawptr, ranges: []journal.Range) -> Error,
}

history_redactions :: proc(h: ^History) -> u64 {
	return h.redactions
}

history_redact :: proc(h: ^History, spans: []crdt.Op_Span, allocator := context.allocator, plan := Redact_Plan{}) -> (res: Redact_Result, err: Error) {
	h.redactions += 1
	defer if r := h.opts.redacted; r.call != nil {
		r.call(r.data, res.unreached)
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return {}, .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	history_wake(h) or_return
	redact_preflight(h, spans) or_return
	all := make([dynamic]crdt.Op_Span, context.temp_allocator)
	for sp in spans {
		if sp.len <= 0 {
			continue
		}
		append(&all, sp)
		crdt.graph_redact(&h.g, sp.id.actor, sp.id.seq, sp.len, &all)
	}
	if len(all) == 0 {
		return {}, .None
	}
	clear(&h.io)
	w := prim.writer(&h.io)
	prim.write_u8(&w, REC_REDACT)
	prim.write_uvarint(&w, u64(len(all)))
	for sp in all {
		prim.write_id(&w, sp.id.actor)
		prim.write_uvarint(&w, sp.id.seq)
		prim.write_uvarint(&w, u64(sp.len))
	}
	if _, jerr := journal.journal_append(&h.journal, h.io[:]); jerr != .None {
		return {}, .Io
	}
	if journal.journal_commit(&h.journal) != .None {
		return {}, .Io
	}
	res.spans = len(all)
	records := make([dynamic][2]i64, context.temp_allocator)
	extra := make([dynamic]crdt.Op_Span, context.temp_allocator)
	own_records(h, all[:], &records, &extra) or_return
	if plan.call != nil && len(records) > 0 {
		planned := make([]journal.Range, len(records), context.temp_allocator)
		for rec, i in records {
			planned[i] = journal.Range{rec[0], rec[1]}
		}
		plan.call(plan.data, planned) or_return
	}
	targets := make([dynamic]odb.Oid, context.temp_allocator)
	protect := make([dynamic]odb.Oid, context.temp_allocator)
	res.files = apply_redaction(h, all[:], extra[:], &targets, &protect) or_return
	zero_blobs(h, all[:], targets[:]) or_return
	if h.db != nil && len(targets) > 0 {
		from_odb(odb.scrub_note(h.db, targets[:], protect[:])) or_return
	}
	history_persist(h) or_return
	for rec in records {
		replace_record(h, rec[0], all[:]) or_return
	}
	history_persist(h) or_return
	ranges := make([dynamic]journal.Range, 0, len(records), allocator)
	for rec in records {
		if e := journal.journal_redact(&h.journal, rec[0], rec[1]); e != .None {
			res.ranges = ranges[:]
			return res, .Io
		}
		append(&ranges, journal.Range{rec[0], rec[1]})
		res.zeroed += rec[1] - rec[0]
	}
	res.ranges = ranges[:]
	if f := h.opts.fault; f.zeroed != nil {
		f.zeroed(f.data)
	}
	history_own_applied(h)
	if history_persist(h) != .None {
		history_reload(h)
	}
	if h.db != nil && len(targets) > 0 {
		unstage(h, targets[:], protect[:])
		rewrites, stats, rerr := odb.redact(h.db, targets[:], "refs/0ndb/", protect[:], true, allocator)
		if rerr != .None {
			return res, from_odb(rerr)
		}
		res.rewrites = len(rewrites)
		res.dropped = stats.commits_rewritten
		res.unreached = stats.unreached
	}
	if h.awake {
		history_unload_files(h)
	}
	return res, .None
}

@(private)
replace_record :: proc(h: ^History, off: i64, spans: []crdt.Op_Span) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	body := read_stream(h, 0, off, &buf) or_return
	payload, ok := batch_payload(body)
	if !ok {
		return .None
	}
	b, derr := crdt.batch_decode(payload, context.temp_allocator, &h.dict)
	if derr != .None {
		return .Corrupt
	}
	ops := make([]crdt.Op_Run, len(b.ops), context.temp_allocator)
	inodes := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	pos: u64
	for op, i in b.ops {
		ops[i] = op
		s0 := b.seq + pos
		pos += u64(op.len)
		if op.kind != .Opaque {
			append(&inodes, op_inode(h, op.target))
		}
		if op.kind != .Insert && op.kind != .Insert_Carry {
			continue
		}
		c := make([]u8, len(op.content), context.temp_allocator)
		copy(c, op.content)
		for sp in spans {
			if sp.id.actor != b.actor {
				continue
			}
			lo := max(s0, sp.id.seq)
			hi := min(s0 + u64(op.len), sp.id.seq + u64(sp.len))
			for k := lo; k < hi; k += 1 {
				c[k - s0] = 0
			}
		}
		ops[i].content = c
	}
	b.ops = ops
	orig := u64(off)
	kind := body[0]
	prevs: []u8
	if body[0] == REC_REPLACE {
		r, rok := replace_decode(body)
		if !rok {
			return .Corrupt
		}
		orig = r.orig
		kind = r.kind
		prevs = r.prevs
	}
	clear(&h.io)
	w := prim.writer(&h.io)
	prim.write_u8(&w, REC_REPLACE)
	prim.write_uvarint(&w, orig)
	if orig == u64(off) {
		prim.write_u8(&w, kind)
	} else {
		count := 1
		rest := prevs
		for len(rest) > 0 {
			_, n := prim.get_uvarint(rest)
			rest = rest[n:]
			count += 1
		}
		prim.write_u8(&w, kind | fshist.REPLACE_PREVS)
		prim.write_uvarint(&w, u64(count))
		prim.write_raw(&w, prevs)
		prim.write_uvarint(&w, u64(off))
	}
	if crdt.batch_encode(&b, &h.io, &h.dict) != .None {
		return .Too_Large
	}
	new_off, jerr := journal.journal_append(&h.journal, h.io[:])
	if jerr != .None {
		return from_journal(jerr)
	}
	if cerr := journal.journal_commit(&h.journal); cerr != .None {
		return from_journal(cerr)
	}
	return replace_chain(h, 0, orig, u64(off), u64(new_off), inodes[:])
}

@(private)
replace_key :: proc(stream: u32, orig: u64) -> []u8 {
	out := make([]u8, 15, context.temp_allocator)
	out[0] = 'r'
	out[1] = 'p'
	out[2] = ':'
	prim.put_u32le(out[3:7], stream)
	prim.put_u64le(out[7:15], orig)
	return out
}

@(private)
replace_chain :: proc(h: ^History, stream: u32, orig: u64, prev: u64, new_off: u64, inodes: []fstree.Inode_Id) -> Error {
	key := replace_key(stream, orig)
	last := prev
	if data, found := kv_get(&h.kv, key, context.temp_allocator) or_return; found && len(data) == 8 {
		last = prim.get_u64le(data)
	}
	froms := [3]u64{orig, prev, last}
	for f, i in froms {
		seen := false
		for j in 0 ..< i {
			seen ||= froms[j] == f
		}
		if !seen && f != new_off {
			remap_ref(h, stream, f, new_off, inodes) or_return
		}
	}
	v: [8]u8
	prim.put_u64le(v[:], new_off)
	return kv_put(&h.kv, key, v[:])
}

@(private)
own_records :: proc(h: ^History, spans: []crdt.Op_Span, records: ^[dynamic][2]i64, extra: ^[dynamic]crdt.Op_Span) -> Error {
	seen := make(map[i64]bool, context.temp_allocator)
	r: journal.Reader
	journal.journal_reader(&h.journal, &r, context.temp_allocator)
	defer journal.reader_close(&r)
	for sp in spans {
		got := 0
		for got < sp.len {
			id := crdt.Op_Id{sp.id.actor, sp.id.seq + u64(got)}
			lv, ok := crdt.graph_lv(&h.g, id)
			if !ok {
				break
			}
			first, n, stream, off, found := history_batch_at(h, lv)
			if !found {
				break
			}
			got += max(n - (lv - first), 1)
			if stream != 0 || seen[i64(off)] {
				continue
			}
			seen[i64(off)] = true
			body, next, jerr := journal.record_at(&r, i64(off))
			if jerr == .Redacted {
				continue
			}
			if jerr != .None {
				return from_journal(jerr)
			}
			if len(body) > 0 && (body[0] == REC_BATCH || body[0] == REC_IMPORT) {
				b, derr := crdt.batch_decode(body[1:], context.temp_allocator, &h.dict)
				if derr == .None {
					pos: u64
					for op in b.ops {
						if op.kind != .Opaque {
							append(extra, crdt.Op_Span{crdt.Op_Id{b.actor, b.seq + pos}, 0})
							extra[len(extra) - 1].id = op.target
						}
						pos += u64(op.len)
					}
				}
			}
			append(records, [2]i64{i64(off), next})
		}
	}
	return .None
}

@(private)
redact_preflight :: proc(h: ^History, spans: []crdt.Op_Span) -> Error {
	p: crdt.Redact_Preview
	all := make([dynamic]crdt.Op_Span, context.temp_allocator)
	for sp in spans {
		if sp.len > 0 {
			append(&all, sp)
			crdt.graph_redact_preview(&h.g, &p, sp.id.actor, sp.id.seq, sp.len, &all)
		}
	}
	records := make([dynamic][2]i64, context.temp_allocator)
	also := make([dynamic]crdt.Op_Span, context.temp_allocator)
	own_records(h, all[:], &records, &also) or_return
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	targets := make([dynamic]odb.Oid, context.temp_allocator)
	redaction_touched(h, all[:], also[:], &touched, &targets, true) or_return
	for ino in sorted_inodes(touched) {
		redaction_file(h, ino) or_return
	}
	return .None
}

@(private)
redaction_file :: proc(h: ^History, ino: fstree.Inode_Id) -> (f: ^File_State, err: Error) {
	if cached, ok := h.files[ino]; ok {
		delete_key(&h.files, ino)
		history_unload_files(h)
		h.files[ino] = cached
		return cached, .None
	}
	history_unload_files(h)
	return history_file(h, ino)
}

@(private)
redaction_touched :: proc(h: ^History, spans: []crdt.Op_Span, also: []crdt.Op_Span, touched: ^map[fstree.Inode_Id]bool, targets: ^[dynamic]odb.Oid, strict: bool) -> Error {
	for x in also {
		touched[op_inode(h, x.id)] = false
	}
	for sp in spans {
		got := 0
		for got < sp.len {
			id := crdt.Op_Id{sp.id.actor, sp.id.seq + u64(got)}
			lv, ok := crdt.graph_lv(&h.g, id)
			if !ok {
				break
			}
			first, n, stream, off, found := history_batch_at(h, lv)
			if !found {
				break
			}
			b, berr := history_read_batch(h, stream, off, context.temp_allocator)
			if strict && berr == .Not_Found {
				return .Not_Found
			}
			if berr == .None {
				pos: u64
				for op in b.ops {
					s0 := b.seq + pos
					pos += u64(op.len)
					if op.kind == .Opaque || b.actor != sp.id.actor {
						continue
					}
					if s0 + u64(op.len) <= sp.id.seq || s0 >= sp.id.seq + u64(sp.len) {
						continue
					}
					touched[op_inode(h, op.target)] = true
					if op.kind == .Insert_Ref && h.db != nil {
						append(targets, odb_oid(op.ref.oid))
					}
				}
			}
			got += max(n - (lv - first), 1)
		}
	}
	return .None
}

@(private)
apply_redaction :: proc(h: ^History, spans: []crdt.Op_Span, also: []crdt.Op_Span, targets: ^[dynamic]odb.Oid, protect: ^[dynamic]odb.Oid) -> (files: int, err: Error) {
	views_stale(h)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	redaction_touched(h, spans, also, &touched, targets, false) or_return
	for ino in sorted_inodes(touched) {
		secret := touched[ino]
		f := redaction_file(h, ino) or_return
		for sp in spans {
			crdt.text_redact(&f.text, &h.g, sp.id.actor, sp.id.seq, sp.len)
			crdt.log_redact(&f.log, &h.g, sp.id.actor, sp.id.seq, sp.len)
		}
		if secret && f.rec.has_cp && f.rec.cp_len > 0 {
			append(targets, odb.Oid(f.rec.cp_text))
		}
		blob_versions_hit(h, ino, spans, targets) or_return
		if h.db != nil {
			data := crdt.text_bytes(&f.text, context.temp_allocator)
			oid, werr := history_stage_blob(h, data)
			if werr != .None {
				return files, werr
			}
			history_note_file_blob(h, ino, oid, crdt.text_version(&f.text, &h.g, context.temp_allocator))
			append(protect, oid)
			clear(&f.rec.cp_version)
			append(&f.rec.cp_version, ..crdt.text_version(&f.text, &h.g, context.temp_allocator))
			clear(&f.rec.cp_spans)
			append(&f.rec.cp_spans, ..crdt.text_spans(&f.text, &h.g, context.temp_allocator))
			f.rec.spans_ext = false
			f.rec.cp_text = fshist.Raw_Oid(oid)
			f.rec.cp_len = i64(len(data))
			f.rec.cp_count = f.rec.ops + u32(len(f.new_refs))
			f.rec.has_cp = true
			f.dirty = true
		}
		persist_file(h, ino, f) or_return
		files += 1
	}
	history_kv_commit(h) or_return
	return files, .None
}

mount_redact_range :: proc(m: ^Mount, path: string, version: Version, from, to: int, allocator := context.allocator, plan := Redact_Plan{}) -> (res: Redact_Result, err: Error) {
	mount_sync(m) or_return
	h := m.history
	e, found := shadow_get(&m.shadow, path) or_return
	if !found || e.kind != .File {
		return {}, .Not_Found
	}
	v := version if len(version) > 0 else m.synced[:]
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return {}, .Corrupt
	}
	_, spans := history_text_spans_at(h, e.inode, lvs[:], context.temp_allocator) or_return
	ids := make([dynamic]crdt.Op_Span, context.temp_allocator)
	at := 0
	for s in spans {
		lo := max(at, from)
		hi := min(at + s.len, to)
		if hi > lo {
			append(&ids, crdt.Op_Span{crdt.Op_Id{s.id.actor, s.id.seq + u64(lo - at)}, hi - lo})
		}
		at += s.len
	}
	res, err = history_redact(h, ids[:], allocator, plan)
	if err != .None {
		return res, err
	}
	if mount_wake(m) == .None {
		m.rescan = false
	}
	return res, .None
}

@(private)
apply_redact_record :: proc(h: ^History, body: []u8, preflight := false, remote := false) -> Error {
	h.redactions += 1
	unreached: []odb.Unreached
	defer if r := h.opts.redacted; r.call != nil {
		r.call(r.data, unreached)
	}
	rd := prim.reader(body[1:])
	n := prim.read_uvarint(&rd)
	if n > u64(len(body)) {
		return .Corrupt
	}
	spans := make([dynamic]crdt.Op_Span, 0, int(n), context.temp_allocator)
	for _ in 0 ..< n {
		a := prim.read_id(&rd)
		seq := prim.read_uvarint(&rd)
		l := prim.read_uvarint(&rd)
		if l == 0 || l > crdt.MAX_RUN {
			return .Corrupt
		}
		append(&spans, crdt.Op_Span{crdt.Op_Id{a, seq}, int(l)})
	}
	if !prim.reader_ok(&rd) {
		return .Corrupt
	}
	if preflight {
		redact_preflight(h, spans[:]) or_return
	}
	closure := make([dynamic]crdt.Op_Span, context.temp_allocator)
	append(&closure, ..spans[:])
	for sp in spans {
		crdt.graph_redact(&h.g, sp.id.actor, sp.id.seq, sp.len, &closure)
	}
	if remote {
		owned_redacted(h, closure[:])
	}
	targets := make([dynamic]odb.Oid, context.temp_allocator)
	protect := make([dynamic]odb.Oid, context.temp_allocator)
	apply_redaction(h, closure[:], nil, &targets, &protect) or_return
	zero_blobs(h, closure[:], targets[:]) or_return
	if h.db != nil && len(targets) > 0 {
		unstage(h, targets[:], protect[:])
		_, st, _ := odb.redact(h.db, targets[:], "refs/0ndb/", protect[:], true, context.temp_allocator)
		unreached = st.unreached
	}
	return .None
}

@(private)
owned_redacted :: proc(h: ^History, spans: []crdt.Op_Span) {
	for sp in spans {
		if history_owns(h, sp.id) {
			append(&h.own_red, sp)
		}
	}
}

@(private)
redact_cascade :: proc(h: ^History, spans: []crdt.Op_Span, remote: bool) -> Error {
	if len(spans) == 0 {
		return .None
	}
	if remote {
		owned_redacted(h, spans)
	}
	targets := make([dynamic]odb.Oid, context.temp_allocator)
	protect := make([dynamic]odb.Oid, context.temp_allocator)
	apply_redaction(h, spans, nil, &targets, &protect) or_return
	zero_blobs(h, spans, targets[:]) or_return
	if h.db != nil && len(targets) > 0 {
		unstage(h, targets[:], protect[:])
		odb.redact(h.db, targets[:], "refs/0ndb/", protect[:], true, context.temp_allocator)
	}
	return .None
}

history_take_own_redactions :: proc(h: ^History, allocator := context.allocator) -> []crdt.Op_Span {
	out := make([]crdt.Op_Span, len(h.own_red), allocator)
	copy(out, h.own_red[:])
	clear(&h.own_red)
	return out
}

@(private)
unstage :: proc(h: ^History, targets: []odb.Oid, protect: []odb.Oid) {
	i := 0
	for i < len(h.staged) {
		s := h.staged[i]
		hit := false
		for t in targets {
			hit ||= t == s.oid
		}
		for p in protect {
			hit &&= p != s.oid
		}
		if !hit {
			i += 1
			continue
		}
		delete(s.data, h.allocator)
		ordered_remove(&h.staged, i)
	}
}

@(private)
ZEROED_DIR :: "zeroed"

@(private)
zeroed_path :: proc(h: ^History, oid: odb.Oid) -> (path: string, err: Error) {
	hb: [odb.MAX_HEX]u8
	hex := odb.oid_to_string(oid, h.db.format, &hb)
	dir, derr := path_join(h.dir, ZEROED_DIR, context.temp_allocator)
	if derr != nil {
		return "", .No_Memory
	}
	p, perr := path_join(dir, hex, context.temp_allocator)
	if perr != nil {
		return "", .No_Memory
	}
	return p, .None
}

@(private)
zeroed_read :: proc(h: ^History, oid: odb.Oid) -> (data: []u8, ok: bool) {
	if h.db == nil {
		return nil, false
	}
	p, perr := zeroed_path(h, oid)
	if perr != .None {
		return nil, false
	}
	d, rerr := prim.read_file(h.vfs, p, h.allocator)
	if rerr != .None {
		return nil, false
	}
	return d, true
}

@(private)
span_holds :: proc(spans: []crdt.Op_Span, actor: prim.Id, seq: u64) -> bool {
	for sp in spans {
		if sp.id.actor == actor && seq >= sp.id.seq && seq < sp.id.seq + u64(sp.len) {
			return true
		}
	}
	return false
}

@(private)
zero_blobs :: proc(h: ^History, spans: []crdt.Op_Span, targets: []odb.Oid) -> Error {
	if h.db == nil || len(targets) == 0 {
		return .None
	}
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	ignored := make([dynamic]odb.Oid, context.temp_allocator)
	redaction_touched(h, spans, nil, &touched, &ignored, false) or_return
	refs := make([dynamic]Op_Ref, context.temp_allocator)
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		out := (^[dynamic]Op_Ref)(data)
		if len(key) == 13 && key[0] == 'f' {
			r: File_Record
			r.cp_version = make([dynamic]crdt.Op_Id, context.temp_allocator)
			r.cp_spans = make([dynamic]crdt.Author_Span, context.temp_allocator)
			if decode_file_record(value, &r) == .None && r.has_base {
				append(out, r.base)
			}
			return true
		}
		if len(key) != 18 || key[0] != 'f' || key[1] != 'o' {
			return true
		}
		rd := prim.reader(value)
		for !prim.reader_done(&rd) {
			ref: Op_Ref
			ref.stream = u32(prim.read_uvarint(&rd))
			ref.off = prim.read_uvarint(&rd)
			ref.from = u32(prim.read_uvarint(&rd))
			ref.to = u32(prim.read_uvarint(&rd))
			if !prim.reader_ok(&rd) {
				break
			}
			append(out, ref)
		}
		return true
	}
	kv_each(&h.kv, &refs, visit) or_return
	for ino in sorted_inodes(touched) {
		f := redaction_file(h, ino) or_return
		append(&refs, ..f.new_refs[:])
	}
	done := make(map[odb.Oid]bool, context.temp_allocator)
	dir_ready := false
	for b in targets {
		if done[b] {
			continue
		}
		done[b] = true
		t, data, rerr := odb.read(h.db, b, context.temp_allocator)
		if rerr != .None || t != .Blob {
			continue
		}
		out := make([]u8, len(data), context.temp_allocator)
		used := make([]bool, len(data), context.temp_allocator)
		red := make([]bool, len(data), context.temp_allocator)
		seen := make(map[[2]u64]bool, context.temp_allocator)
		for ref in refs {
			key := [2]u64{u64(ref.stream), ref.off}
			if seen[key] {
				continue
			}
			seen[key] = true
			batch, berr := history_read_batch(h, ref.stream, ref.off, context.temp_allocator)
			if berr != .None {
				continue
			}
			pos: u64
			for op in batch.ops {
				s0 := batch.seq + pos
				pos += u64(op.len)
				if op.kind != .Insert_Ref || odb_oid(op.ref.oid) != b {
					continue
				}
				for k in 0 ..< op.len {
					p := op.ref.offset + k
					if p < 0 || p >= len(data) {
						continue
					}
					if span_holds(spans, batch.actor, s0 + u64(k)) {
						red[p] = true
					} else {
						used[p] = true
						out[p] = data[p]
					}
				}
			}
		}
		for p in 0 ..< len(data) {
			if red[p] && used[p] {
				return .Invalid
			}
		}
		if !dir_ready {
			dir, derr := path_join(h.dir, ZEROED_DIR, context.temp_allocator)
			if derr != nil {
				return .No_Memory
			}
			from_prim(prim.mkdir_all(h.vfs, dir, 0o700)) or_return
			from_prim(prim.sync_dir(h.vfs, h.dir)) or_return
			dir_ready = true
		}
		zp := zeroed_path(h, b) or_return
		from_prim(prim.replace_atomic(h.vfs, zp, out)) or_return
	}
	if f := h.opts.fault; f.blob_zeroed != nil {
		f.blob_zeroed(f.data)
	}
	return .None
}

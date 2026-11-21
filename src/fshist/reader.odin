package fshist

import "base:runtime"
import "core:slice"
import "../crdt"
import "../fstree"
import "../journal"
import "../prim"

Blob_Source :: struct {
	data: rawptr,
	read: proc(data: rawptr, oid: Oid, off: i64, dst: []u8) -> (int, Error),
}

Stream_Source :: struct {
	data:   rawptr,
	reader: proc(data: rawptr, stream: prim.Id) -> ^journal.Reader,
}

Want :: struct {
	stream: prim.Id,
	from:   i64,
	to:     i64,
	blob:   Oid,
}

Lv_Entry :: struct {
	first:  crdt.Lv,
	n:      int,
	stream: u32,
	off:    u64,
}

@(private)
Rec_Key :: struct {
	stream: u32,
	off:    u64,
}

@(private)
File :: struct {
	rec:      File_Record,
	refs:     [dynamic]Op_Ref,
	using st: Text_State,
}

Reader :: struct {
	allocator:   runtime.Allocator,
	id:          prim.Id,
	streams:     Stream_Source,
	blobs:       Blob_Source,
	kv:          map[string][]u8,
	g:           crdt.Graph,
	tree:        fstree.Tree,
	stream_ids:  [dynamic]prim.Id,
	applied:     [dynamic]i64,
	dicts:       [dynamic]crdt.Actor_Dict,
	moves_count: u64,
	moves:       [dynamic]fstree.Move_Ref,
	lvidx:       [dynamic]Lv_Entry,
	files:       map[fstree.Inode_Id]^File,
	replaced:    map[Rec_Key]u64,
	redactions:  [dynamic]crdt.Op_Span,
	wants:       [dynamic]Want,
	blob_oid:    Oid,
	blob_data:   []u8,
	missing:     bool,
	started:     bool,
}

reader_init :: proc(r: ^Reader, history: prim.Id, streams: Stream_Source, blobs: Blob_Source, allocator := context.allocator) {
	r^ = {
		allocator = allocator,
		id        = history,
		streams   = streams,
		blobs     = blobs,
	}
	r.kv = make(map[string][]u8, allocator)
	r.stream_ids = make([dynamic]prim.Id, allocator)
	r.applied = make([dynamic]i64, allocator)
	r.dicts = make([dynamic]crdt.Actor_Dict, allocator)
	r.moves = make([dynamic]fstree.Move_Ref, allocator)
	r.lvidx = make([dynamic]Lv_Entry, allocator)
	r.files = make(map[fstree.Inode_Id]^File, allocator)
	r.replaced = make(map[Rec_Key]u64, allocator)
	r.redactions = make([dynamic]crdt.Op_Span, allocator)
	r.wants = make([dynamic]Want, allocator)
	crdt.graph_init(&r.g, allocator, crdt.Graph_Source{r, reader_page})
	fstree.init(&r.tree, tree_source(r), 0, allocator = allocator)
}

reader_destroy :: proc(r: ^Reader) {
	for _, f in r.files {
		file_drop(r, f)
	}
	delete(r.files)
	for k, v in r.kv {
		delete(k, r.allocator)
		delete(v, r.allocator)
	}
	delete(r.kv)
	for &d in r.dicts {
		crdt.dict_destroy(&d)
	}
	delete(r.dicts)
	delete(r.stream_ids)
	delete(r.applied)
	delete(r.moves)
	delete(r.lvidx)
	delete(r.replaced)
	delete(r.redactions)
	delete(r.wants)
	if r.blob_data != nil {
		delete(r.blob_data, r.allocator)
	}
	fstree.destroy(&r.tree)
	crdt.graph_destroy(&r.g)
	r^ = {}
}

reader_seed :: proc(r: ^Reader, checkpoint_meta: []u8) -> Error {
	if r.started {
		return .Invalid
	}
	rd := prim.reader(checkpoint_meta)
	header := false
	done := false
	for !done {
		frame := prim.read_bytes(&rd)
		if !prim.reader_ok(&rd) || len(frame) == 0 {
			return .Corrupt
		}
		fr := prim.reader(frame[1:])
		switch frame[0] {
		case 1:
			if prim.read_u8(&fr) != 1 || prim.read_id(&fr) != r.id {
				return .Invalid
			}
			header = true
		case 2:
			if !header {
				return .Corrupt
			}
			key := prim.read_bytes(&fr)
			value := prim.read_bytes(&fr)
			if !prim.reader_ok(&fr) {
				return .Corrupt
			}
			kv_set(r, key, value)
		case 3:
			data := prim.read_bytes(&fr)
			if !prim.reader_ok(&fr) || len(data) % LVIDX_REC != 0 {
				return .Corrupt
			}
			for i := 0; i < len(data); i += LVIDX_REC {
				append(&r.lvidx, Lv_Entry{crdt.Lv(prim.get_u64le(data[i:])), int(prim.get_u32le(data[i + 12:])), prim.get_u32le(data[i + 8:]), prim.get_u64le(data[i + 16:])})
			}
		case 4:
			done = true
		case:
			return .Corrupt
		}
	}
	if !header {
		return .Corrupt
	}
	return seed_state(r)
}

@(private)
seed_state :: proc(r: ^Reader) -> Error {
	fstree.destroy(&r.tree)
	crdt.graph_destroy(&r.g)
	src := crdt.Graph_Source{r, reader_page}
	if meta, ok := r.kv["g"]; ok {
		if crdt.graph_open(&r.g, meta, src, r.allocator) != .None {
			crdt.graph_init(&r.g, r.allocator, src)
			fstree.init(&r.tree, tree_source(r), 0, allocator = r.allocator)
			return .Corrupt
		}
	} else {
		crdt.graph_init(&r.g, r.allocator, src)
	}
	max_lamport: u64
	for x in r.g.heads {
		max_lamport = max(max_lamport, crdt.graph_lamport(&r.g, x))
	}
	fstree.init(&r.tree, tree_source(r), max_lamport, allocator = r.allocator)
	s, ok := r.kv["s"]
	if !ok {
		return .None
	}
	rd := prim.reader(s)
	if prim.read_u8(&rd) != STATE_FORMAT {
		return .Corrupt
	}
	ns := prim.read_uvarint(&rd)
	if ns > u64(len(s)) {
		return .Corrupt
	}
	for i in 0 ..< ns {
		append(&r.stream_ids, prim.read_id(&rd))
		append(&r.applied, i64(prim.read_uvarint(&rd)))
		d: crdt.Actor_Dict
		crdt.dict_init(&d, r.allocator)
		if i > 0 {
			nd := prim.read_uvarint(&rd)
			if nd > u64(prim.reader_remaining(&rd)) {
				crdt.dict_destroy(&d)
				return .Corrupt
			}
			for _ in 0 ..< nd {
				crdt.dict_add(&d, prim.read_id(&rd))
			}
		}
		append(&r.dicts, d)
	}
	nd := prim.read_uvarint(&rd)
	for _ in 0 ..< nd {
		id := prim.read_id(&rd)
		if len(r.dicts) > 0 {
			crdt.dict_add(&r.dicts[0], id)
		}
	}
	r.moves_count = prim.read_uvarint(&rd)
	if !prim.reader_ok(&rd) {
		return .Corrupt
	}
	return .None
}

reader_admit :: proc(r: ^Reader, stream: prim.Id, upto: i64) -> (admitted: int, err: Error) {
	r.started = true
	clear(&r.wants)
	si := stream_slot(r, stream)
	jr: ^journal.Reader
	if r.streams.reader != nil {
		jr = r.streams.reader(r.streams.data, stream)
	}
	if jr == nil {
		want_add(r, Want{stream = stream, from = r.applied[si], to = upto})
		return 0, .Missing
	}
	pos := r.applied[si]
	for pos < upto {
		body, next, jerr := journal.record_at(jr, pos)
		#partial switch jerr {
		case .None:
		case .Redacted:
			r.applied[si] = next
			pos = next
			continue
		case .Eof:
			return admitted, .None
		case .Missing:
			want_add(r, Want{stream = stream, from = pos, to = upto})
			return admitted, .Missing
		case:
			return admitted, .Corrupt
		}
		if !journal.is_sig(body) {
			n := apply_record(r, u32(si), u64(pos), body) or_return
			admitted += n
		}
		r.applied[si] = next
		pos = next
	}
	return admitted, .None
}

reader_lookup :: proc(r: ^Reader, path: string) -> (fstree.Inode_Id, bool, Error) {
	snap := fstree.current(&r.tree)
	id, ok, err := fstree.lookup(&snap, path)
	if err != nil {
		return {}, false, tree_err(err)
	}
	return id, ok, .None
}

reader_children :: proc(r: ^Reader, dir: fstree.Inode_Id, allocator := context.allocator) -> ([]fstree.Child, Error) {
	snap := fstree.current(&r.tree)
	out, err := fstree.children(&snap, dir, allocator = allocator)
	if err != nil {
		return nil, tree_err(err)
	}
	return out, .None
}

reader_text :: proc(r: ^Reader, inode: fstree.Inode_Id, allocator := context.allocator) -> (text: []u8, err: Error) {
	clear(&r.wants)
	f := heads_text(r, inode) or_return
	return crdt.text_bytes(&f.text, allocator), .None
}

reader_spans :: proc(r: ^Reader, inode: fstree.Inode_Id, allocator := context.allocator) -> (spans: []crdt.Author_Span, err: Error) {
	clear(&r.wants)
	f := heads_text(r, inode) or_return
	return crdt.text_spans(&f.text, &r.g, allocator), .None
}

reader_text_at :: proc(r: ^Reader, inode: fstree.Inode_Id, version: []crdt.Op_Id, allocator := context.allocator) -> (text: []u8, spans: []crdt.Author_Span, err: Error) {
	clear(&r.wants)
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&r.g, version, &lvs) != .None {
		return nil, nil, .Missing
	}
	f := file_get(r, inode) or_return
	tmp: File
	tmp.rec = f.rec
	tmp.refs = f.refs
	load(r, inode, &tmp, lvs[:]) or_return
	defer {
		crdt.text_destroy(&tmp.text)
		crdt.log_destroy(&tmp.log)
	}
	return crdt.text_bytes(&tmp.text, allocator), crdt.text_spans(&tmp.text, &r.g, allocator), .None
}

reader_wants :: proc(r: ^Reader) -> []Want {
	if len(r.wants) < 2 {
		return r.wants[:]
	}
	slice.sort_by(r.wants[:], proc(a, b: Want) -> bool {
		if a.blob != b.blob {
			x, y := a.blob, b.blob
			return x.len < y.len || (x.len == y.len && string(x.bytes[:]) < string(y.bytes[:]))
		}
		if a.stream != b.stream {
			return crdt.id_less(a.stream, b.stream)
		}
		return a.from < b.from
	})
	n := 1
	for i in 1 ..< len(r.wants) {
		cur := r.wants[i]
		top := &r.wants[n - 1]
		if cur.blob == top.blob && cur.blob.len > 0 {
			continue
		}
		if cur.blob.len == 0 && top.blob.len == 0 && cur.stream == top.stream && cur.from <= top.to {
			top.to = max(top.to, cur.to)
		} else {
			r.wants[n] = cur
			n += 1
		}
	}
	resize(&r.wants, n)
	return r.wants[:]
}

reader_unload :: proc(r: ^Reader, inode: fstree.Inode_Id) {
	if f, ok := r.files[inode]; ok {
		text_drop(&f.st)
	}
	if r.blob_data != nil {
		delete(r.blob_data, r.allocator)
		r.blob_data = nil
		r.blob_oid = {}
	}
	crdt.graph_trim(&r.g)
}

reader_heads :: proc(r: ^Reader, allocator := context.allocator) -> []crdt.Op_Id {
	return crdt.graph_version_ids(&r.g, r.g.heads[:], allocator)
}

reader_applied :: proc(r: ^Reader, stream: prim.Id) -> i64 {
	for s, i in r.stream_ids {
		if s == stream {
			return r.applied[i]
		}
	}
	return 0
}

@(private)
tree_source :: proc(r: ^Reader) -> fstree.Source {
	return fstree.Source {
		data = r,
		actor = proc(data: rawptr, actor: u32) -> prim.Id {
			r := (^Reader)(data)
			if int(actor) < len(r.g.actors) {
				return r.g.actors[actor]
			}
			return {}
		},
		load_inode = proc(data: rawptr, id: fstree.Inode_Id) -> ([]u8, bool) {
			r := (^Reader)(data)
			v, ok := r.kv[string(inode_key("ti", id))]
			return v, ok
		},
		load_node = proc(data: rawptr, key: fstree.Node_Key) -> ([]u8, bool) {
			r := (^Reader)(data)
			v, ok := r.kv[string(node_key(key))]
			return v, ok
		},
		load_moves = proc(data: rawptr, from_lamport: u64, out: ^[dynamic]fstree.Move_Ref) -> bool {
			r := (^Reader)(data)
			chunks := (r.moves_count + MOVES_CHUNK - 1) / MOVES_CHUNK
			for c in 0 ..< chunks {
				v, ok := r.kv[string(moves_key(c))]
				if !ok || !decode_moves(v, from_lamport, out) {
					return false
				}
			}
			for m in r.moves {
				if m.event.lamport >= from_lamport {
					append(out, m)
				}
			}
			return true
		},
	}
}

@(private)
reader_page :: proc(data: rawptr, key: crdt.Page_Key, out: ^[dynamic]u8) -> bool {
	r := (^Reader)(data)
	v, ok := r.kv[string(page_key(key))]
	if !ok {
		return false
	}
	clear(out)
	append(out, ..v)
	return true
}

@(private)
kv_set :: proc(r: ^Reader, key: []u8, value: []u8) {
	v := make([]u8, len(value), r.allocator)
	copy(v, value)
	if old, ok := &r.kv[string(key)]; ok {
		delete(old^, r.allocator)
		old^ = v
		return
	}
	k := make([]u8, len(key), r.allocator)
	copy(k, key)
	r.kv[string(k)] = v
}

@(private)
tree_err :: proc(e: fstree.Error) -> Error {
	switch x in e {
	case fstree.Tree_Error:
		if x == .Unavailable {
			return .Missing
		}
	case runtime.Allocator_Error:
		return .No_Memory
	}
	return .Corrupt
}

@(private)
want_add :: proc(r: ^Reader, w: Want) {
	append(&r.wants, w)
}

@(private)
stream_slot :: proc(r: ^Reader, stream: prim.Id) -> int {
	for s, i in r.stream_ids {
		if s == stream {
			return i
		}
	}
	append(&r.stream_ids, stream)
	append(&r.applied, 0)
	d: crdt.Actor_Dict
	crdt.dict_init(&d, r.allocator)
	append(&r.dicts, d)
	return len(r.stream_ids) - 1
}

@(private)
inode_of :: proc(data: rawptr, id: crdt.Op_Id) -> fstree.Inode_Id {
	r := (^Reader)(data)
	return fstree.Inode_Id{crdt.graph_intern(&r.g, id.actor), id.seq}
}

@(private)
op_of :: proc(r: ^Reader, id: fstree.Inode_Id) -> crdt.Op_Id {
	if id == fstree.ROOT {
		return {}
	}
	if int(id.actor) < len(r.g.actors) {
		return crdt.Op_Id{r.g.actors[id.actor], id.seq}
	}
	return {}
}

@(private)
apply_record :: proc(r: ^Reader, si: u32, off: u64, body: []u8) -> (n: int, err: Error) {
	if len(body) == 0 {
		return 0, .None
	}
	switch body[0] {
	case REC_ACTORS:
		rd := prim.reader(body[1:])
		c := prim.read_uvarint(&rd)
		if c > u64(len(body)) {
			return 0, .Corrupt
		}
		for _ in 0 ..< c {
			crdt.dict_add(&r.dicts[si], prim.read_id(&rd))
		}
		if !prim.reader_ok(&rd) {
			return 0, .Corrupt
		}
		return 0, .None
	case REC_REPLACE:
		old, ok := replace_old(body)
		if !ok {
			return 0, .Corrupt
		}
		prev, had := r.replaced[Rec_Key{si, old}]
		r.replaced[Rec_Key{si, old}] = off
		for &e in r.lvidx {
			if e.stream == si && (e.off == old || (had && e.off == prev)) {
				e.off = off
			}
		}
		texts_drop(r)
		return 0, .None
	case REC_REDACT:
		rd := prim.reader(body[1:])
		c := prim.read_uvarint(&rd)
		if c > u64(len(body)) {
			return 0, .Corrupt
		}
		for _ in 0 ..< c {
			a := prim.read_id(&rd)
			s := prim.read_uvarint(&rd)
			l := prim.read_uvarint(&rd)
			append(&r.redactions, crdt.Op_Span{crdt.Op_Id{a, s}, int(l)})
		}
		if !prim.reader_ok(&rd) {
			return 0, .Corrupt
		}
		texts_drop(r)
		return 0, .None
	case REC_BATCH, REC_IMPORT:
		return apply_batch(r, si, off, body)
	}
	return 0, .None
}

@(private)
apply_batch :: proc(r: ^Reader, si: u32, off: u64, body: []u8) -> (n: int, err: Error) {
	b, derr := crdt.batch_decode(body[1:], context.temp_allocator, &r.dicts[si])
	if derr != .None {
		return 0, .Corrupt
	}
	parents := make([dynamic]crdt.Lv, context.temp_allocator)
	skip, gerr := crdt.graph_check(&r.g, &b, &parents)
	if gerr == .Missing {
		return 0, .Missing
	}
	if gerr != .None {
		return 0, .Corrupt
	}
	total := crdt.batch_len(&b)
	if skip >= total {
		return 0, .None
	}
	first, gskip, aerr := crdt.graph_add(&r.g, &b)
	if aerr != .None {
		return 0, .Corrupt
	}
	append(&r.lvidx, Lv_Entry{first, total - gskip, si, off})
	import_batch := body[0] == REC_IMPORT
	actor := crdt.graph_intern(&r.g, b.actor)
	lv := first
	rest := gskip
	pos := 0
	for op in b.ops {
		if rest >= op.len {
			rest -= op.len
			pos += op.len
			continue
		}
		start := pos + rest
		cnt := op.len - rest
		rest = 0
		if op.kind == .Opaque && cnt == op.len {
			apply_opaque(r, b.actor, actor, b.seq + u64(start), lv, op.content) or_return
		} else if import_batch && op.kind == .Insert_Ref {
			ino := inode_of(r, op.target)
			f := file_get(r, ino) or_return
			file_record_destroy(&f.rec)
			f.rec = File_Record {
				has_cp     = true,
				cp_text    = oid_from_crdt(op.ref.oid),
				cp_len     = i64(op.len),
				cp_version = make([dynamic]crdt.Op_Id, r.allocator),
				cp_spans   = make([dynamic]crdt.Author_Span, r.allocator),
				has_base   = true,
				base       = Op_Ref{si, off, 0, u32(pos + op.len)},
			}
			at := crdt.Op_Id{b.actor, b.seq + u64(pos)}
			append(&f.rec.cp_version, crdt.Op_Id{b.actor, at.seq + u64(op.len) - 1})
			append(&f.rec.cp_spans, crdt.Author_Span{id = at, op = at, len = op.len})
			text_drop(&f.st)
		}
		lv += cnt
		pos += op.len
	}
	if !import_batch {
		for t in text_targets(&b) {
			f := file_get(r, inode_of(r, t)) or_return
			append(&f.refs, Op_Ref{si, off, u32(gskip), u32(total)})
			text_drop(&f.st)
		}
	}
	return total - gskip, .None
}

@(private)
apply_opaque :: proc(r: ^Reader, actor_id: prim.Id, actor: u32, seq: u64, lv: crdt.Lv, content: []u8) -> Error {
	op, ok := decode_opaque(content, r, inode_of)
	if !ok {
		return .None
	}
	lamport := crdt.graph_lamport(&r.g, lv)
	switch o in op {
	case Tree_Op:
		id := fstree.Op_Id{actor, seq}
		if e := fstree.apply(&r.tree, id, lamport, o.op); e == nil {
			if _, mv := o.op.(fstree.Op_Move); mv {
				append(&r.moves, fstree.Move_Ref{event = {lamport = lamport, seq = seq, actor = actor}, inode = fstree.op_inode(id, o.op)})
			}
		} else if e == .Unavailable {
			return .Missing
		}
	case Content_Op:
		f := file_get(r, o.inode) or_return
		reg := Blob_Reg {
			lamport = lamport,
			actor   = actor_id,
			seq     = seq,
			oid     = o.oid,
			size    = o.size,
		}
		if !f.rec.has_blob || blob_newer(reg, f.rec.blob) {
			f.rec.blob = reg
			f.rec.has_blob = true
		}
	case Git_Op:
	}
	return .None
}

reader_blob :: proc(r: ^Reader, inode: fstree.Inode_Id) -> (reg: Blob_Reg, found: bool, err: Error) {
	f := file_get(r, inode) or_return
	return f.rec.blob, f.rec.has_blob, .None
}

@(private)
file_get :: proc(r: ^Reader, inode: fstree.Inode_Id) -> (f: ^File, err: Error) {
	if x, ok := r.files[inode]; ok {
		return x, .None
	}
	f = new(File, r.allocator)
	f.rec.cp_version = make([dynamic]crdt.Op_Id, r.allocator)
	f.rec.cp_spans = make([dynamic]crdt.Author_Span, r.allocator)
	f.refs = make([dynamic]Op_Ref, r.allocator)
	if v, ok := r.kv[string(inode_key("f", inode))]; ok {
		if e := decode_file_record(v, &f.rec); e != .None {
			file_record_destroy(&f.rec)
			delete(f.refs)
			free(f, r.allocator)
			return nil, e
		}
	}
	r.files[inode] = f
	return f, .None
}

@(private)
texts_drop :: proc(r: ^Reader) {
	for _, f in r.files {
		text_drop(&f.st)
	}
}

@(private)
file_drop :: proc(r: ^Reader, f: ^File) {
	text_drop(&f.st)
	file_record_destroy(&f.rec)
	delete(f.refs)
	free(f, r.allocator)
}

@(private)
heads_text :: proc(r: ^Reader, inode: fstree.Inode_Id) -> (f: ^File, err: Error) {
	f = file_get(r, inode) or_return
	if f.loaded {
		return f, .None
	}
	heads := make([]crdt.Lv, len(r.g.heads), context.temp_allocator)
	copy(heads, r.g.heads[:])
	load(r, inode, f, heads) or_return
	return f, .None
}

@(private)
load :: proc(r: ^Reader, inode: fstree.Inode_Id, f: ^File, v: []crdt.Lv) -> Error {
	r.missing = false
	src := Text_Source {
		data       = r,
		g          = &r.g,
		allocator  = r.allocator,
		content    = crdt.Content_Source{r, content_read},
		copies     = crdt.Copy_Source{r, copy_read},
		op_ref     = proc(data: rawptr, inode: fstree.Inode_Id, i: u32) -> (Op_Ref, Error) {
			r := (^Reader)(data)
			chunk, ok := r.kv[string(ops_key(inode, i / OPS_CHUNK))]
			if !ok {
				return {}, .Corrupt
			}
			ref, rok := op_ref_at(chunk, i % OPS_CHUNK)
			return ref, .None if rok else .Corrupt
		},
		record     = proc(data: rawptr, stream: u32, off: u64, buf: ^[dynamic]u8) -> ([]u8, Error) {
			return record((^Reader)(data), stream, off)
		},
		dict       = proc(data: rawptr, stream: u32) -> ^crdt.Actor_Dict {
			return &(^Reader)(data).dicts[stream]
		},
		checkpoint = proc(data: rawptr, oid: Raw_Oid, size: i64, allocator: runtime.Allocator) -> ([]u8, Error) {
			r := (^Reader)(data)
			out := make([]u8, int(size), allocator)
			got, e := blob_read(r, oid_full(oid), 0, out)
			if e != .None {
				return nil, e
			}
			if got != len(out) {
				return nil, .Not_Found
			}
			return out, .None
		},
	}
	e := text_load(&src, &f.st, inode, op_of(r, inode), &f.rec, f.refs[:], v)
	if e != .None {
		text_drop(&f.st)
		return .Missing if r.missing || e == .Missing else e
	}
	redact_loaded(r, f)
	return .None
}

@(private)
record :: proc(r: ^Reader, stream: u32, off: u64) -> (body: []u8, err: Error) {
	if int(stream) >= len(r.stream_ids) {
		return nil, .Corrupt
	}
	at := off
	if n, ok := r.replaced[Rec_Key{stream, off}]; ok {
		at = n
	}
	id := r.stream_ids[stream]
	jr: ^journal.Reader
	if r.streams.reader != nil {
		jr = r.streams.reader(r.streams.data, id)
	}
	if jr == nil {
		want_add(r, Want{stream = id, from = i64(at), to = i64(at) + 1})
		return nil, .Missing
	}
	b, _, jerr := journal.record_at(jr, i64(at))
	#partial switch jerr {
	case .None:
		return b, .None
	case .Redacted:
		return nil, .Redacted
	case .Missing, .Eof:
		want_add(r, Want{stream = id, from = i64(at), to = i64(at) + 1})
		return nil, .Missing
	}
	return nil, .Corrupt
}

@(private)
redact_loaded :: proc(r: ^Reader, f: ^File) {
	for sp in r.redactions {
		crdt.text_redact(&f.text, &r.g, sp.id.actor, sp.id.seq, sp.len)
		crdt.log_redact(&f.log, &r.g, sp.id.actor, sp.id.seq, sp.len)
	}
}

@(private)
blob_read :: proc(r: ^Reader, oid: Oid, off: i64, dst: []u8) -> (int, Error) {
	if r.blobs.read == nil {
		want_add(r, Want{blob = oid})
		return 0, .Missing
	}
	n, e := r.blobs.read(r.blobs.data, oid, off, dst)
	if e == .Missing || e == .Not_Found {
		want_add(r, Want{blob = oid})
		r.missing = true
		return n, .Missing
	}
	return n, e
}

@(private)
content_read :: proc(data: rawptr, oid: crdt.Oid, offset: int, dst: []u8) -> bool {
	r := (^Reader)(data)
	o := Oid{len = oid.len}
	x := oid
	copy(o.bytes[:], x.bytes[:])
	n, e := blob_read(r, o, i64(offset), dst)
	return e == .None && n == len(dst)
}

@(private)
batch_at :: proc(r: ^Reader, lv: crdt.Lv) -> (e: Lv_Entry, found: bool) {
	lo, hi := 0, len(r.lvidx)
	for lo < hi {
		mid := (lo + hi) / 2
		if r.lvidx[mid].first <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return {}, false
	}
	x := r.lvidx[lo - 1]
	if lv >= x.first + crdt.Lv(x.n) {
		return {}, false
	}
	return x, true
}

@(private)
copy_read :: proc(data: rawptr, src: crdt.Op_Id, dst: []u8, authors: ^[dynamic]crdt.Author_Span) -> int {
	return copy_depth((^Reader)(data), src, dst, authors, 0)
}

@(private)
copy_depth :: proc(r: ^Reader, src: crdt.Op_Id, dst: []u8, authors: ^[dynamic]crdt.Author_Span, depth: int) -> int {
	got := 0
	outer: for got < len(dst) && depth < 64 {
		id := crdt.Op_Id{src.actor, src.seq + u64(got)}
		lv, ok := crdt.graph_lv(&r.g, id)
		if !ok {
			break
		}
		e, found := batch_at(r, lv)
		if !found {
			break
		}
		body, rerr := record(r, e.stream, e.off)
		if rerr != .None {
			r.missing ||= rerr == .Missing
			break
		}
		payload, pok := batch_payload(body)
		if !pok {
			break
		}
		b, derr := crdt.batch_decode(payload, context.temp_allocator, &r.dicts[e.stream])
		if derr != .None || b.actor != id.actor || id.seq < b.seq {
			break
		}
		rel := int(id.seq - b.seq)
		pos := 0
		for op in b.ops {
			if rel >= pos + op.len {
				pos += op.len
				continue
			}
			k := rel - pos
			avail := min(op.len - k, len(dst) - got)
			#partial switch op.kind {
			case .Insert:
				copy(dst[got:got + avail], op.content[k:k + avail])
				append(authors, crdt.Author_Span{id = id, op = id, len = avail})
			case .Insert_Ref:
				if !content_read(r, op.ref.oid, op.ref.offset + k, dst[got:got + avail]) {
					break outer
				}
				append(authors, crdt.Author_Span{id = id, op = id, len = avail})
			case .Insert_Copy:
				sub := copy_depth(r, crdt.Op_Id{op.src.actor, op.src.seq + u64(k)}, dst[got:got + avail], authors, depth + 1)
				if sub < avail {
					got += sub
					break outer
				}
			case:
				break outer
			}
			got += avail
			continue outer
		}
		break
	}
	return got
}

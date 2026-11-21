package convergence

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "../../src/crdt"
import "../../src/prim"

Rng :: struct {
	s: u64,
}

next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(next(r) % u64(n))
}

chance :: proc(r: ^Rng, pct: int) -> bool {
	return below(r, 100) < pct
}

FILES :: 2

target_of :: proc(f: int) -> crdt.Op_Id {
	id: prim.Id
	id[0] = 0xff
	return crdt.Op_Id{id, u64(f)}
}

actor_of :: proc(n: int) -> prim.Id {
	id: prim.Id
	id[0] = u8(n * 37 + 11)
	id[15] = u8(n)
	return id
}

File :: struct {
	text: crdt.Text,
	log:  crdt.Text_Log,
}

Snapshot :: struct {
	file:    int,
	version: []crdt.Op_Id,
	bytes:   []u8,
	spans:   []crdt.Author_Span,
	anchor:  crdt.Anchor,
	has:     bool,
}

Store :: struct {
	pages: map[crdt.Page_Key][dynamic]u8,
}

store_load :: proc(data: rawptr, key: crdt.Page_Key, out: ^[dynamic]u8) -> bool {
	s := (^Store)(data)
	p, ok := s.pages[key]
	if !ok {
		return false
	}
	append(out, ..p[:])
	return true
}

blob_read :: proc(data: rawptr, oid: crdt.Oid, offset: int, dst: []u8) -> bool {
	for &b, i in dst {
		b = u8('0' + (int(oid.bytes[0]) + int(oid.len) + offset + i) % 10)
	}
	return true
}

Replica :: struct {
	dict:      ^crdt.Actor_Dict,
	store:     Store,
	paged:     bool,
	keys:      [dynamic]crdt.Page_Key,
	history:   [dynamic][]crdt.Op_Id,
	g:         crdt.Graph,
	files:     [FILES]File,
	actor:     prim.Id,
	seq:       u64,
	inbox:     [dynamic][]u8,
	pending:   [dynamic][]u8,
	snapshots: [dynamic]Snapshot,
	conflicts: [dynamic]crdt.Conflict,
}

replica_init :: proc(r: ^Replica, n: int, paged := false) {
	r.paged = paged
	r.store.pages = make(map[crdt.Page_Key][dynamic]u8)
	r.keys = make([dynamic]crdt.Page_Key)
	r.history = make([dynamic][]crdt.Op_Id)
	if paged {
		crdt.graph_init(&r.g, source = crdt.Graph_Source{&r.store, store_load}, page_size = 4, window = 1)
	} else {
		crdt.graph_init(&r.g)
	}
	for &f in r.files {
		crdt.text_init(&f.text)
		crdt.log_init(&f.log, content = crdt.Content_Source{nil, blob_read}, copies = crdt.Copy_Source{r, copy_read})
	}
	r.actor = actor_of(n)
	r.inbox = make([dynamic][]u8)
	r.pending = make([dynamic][]u8)
	r.snapshots = make([dynamic]Snapshot)
	r.conflicts = make([dynamic]crdt.Conflict)
}

conflicts_clear :: proc(list: ^[dynamic]crdt.Conflict) {
	for c in list {
		delete(c.ours)
		delete(c.theirs)
	}
	clear(list)
}

flush :: proc(r: ^Replica) {
	if !r.paged {
		return
	}
	crdt.graph_dirty(&r.g, &r.keys)
	for k in r.keys {
		buf := make([dynamic]u8)
		assert(crdt.graph_page_encode(&r.g, k, &buf) == .None)
		if old, ok := r.store.pages[k]; ok {
			delete(old)
		}
		r.store.pages[k] = buf
		crdt.graph_page_clean(&r.g, k)
	}
	crdt.graph_trim(&r.g)
}

replica_destroy :: proc(r: ^Replica) {
	for _, v in r.store.pages {
		delete(v)
	}
	delete(r.store.pages)
	delete(r.keys)
	for h in r.history {
		delete(h)
	}
	delete(r.history)
	crdt.graph_destroy(&r.g)
	for &f in r.files {
		crdt.text_destroy(&f.text)
		crdt.log_destroy(&f.log)
	}
	for m in r.inbox {
		delete(m)
	}
	for m in r.pending {
		delete(m)
	}
	for s in r.snapshots {
		delete(s.version)
		delete(s.bytes)
		delete(s.spans)
	}
	delete(r.inbox)
	delete(r.pending)
	delete(r.snapshots)
	conflicts_clear(&r.conflicts)
	delete(r.conflicts)
}

apply_batch :: proc(t: ^testing.T, r: ^Replica, b: ^crdt.Batch, collect: bool) -> crdt.Error {
	parents := make([dynamic]crdt.Lv)
	defer delete(parents)
	skip, err := crdt.graph_check(&r.g, b, &parents)
	if err != .None {
		return err
	}
	n := crdt.batch_len(b)
	if skip >= n {
		return .None
	}
	valid := n - skip
	for f in 0 ..< FILES {
		file := &r.files[f]
		v, e := crdt.text_check(&file.text, &r.g, &file.log, b, target_of(f), skip, parents[:])
		testing.expect_value(t, e, crdt.Error.None)
		valid = min(valid, v)
	}
	if valid == 0 {
		return .Invalid
	}
	use := b
	cut: crdt.Batch
	if skip + valid < n {
		cut, _ = crdt.batch_slice(b, 0, skip + valid)
		use = &cut
	}
	defer if use == &cut {
		crdt.batch_destroy(&cut)
	}
	first, skip2, err2 := crdt.graph_add(&r.g, use)
	testing.expect_value(t, err2, crdt.Error.None)
	testing.expect_value(t, skip2, skip)
	for f in 0 ..< FILES {
		testing.expect_value(t, crdt.log_add_batch(&r.files[f].log, &r.g, use, target_of(f), first, skip), crdt.Error.None)
	}
	for f in 0 ..< FILES {
		file := &r.files[f]
		before := crdt.text_bytes(&file.text)
		defer delete(before)
		db: crdt.Delta_Builder
		crdt.delta_builder_init(&db, context.temp_allocator)
		e := crdt.text_merge(&file.text, &r.g, &file.log, r.g.heads[:], &r.conflicts if collect else nil, delta_sink(&db))
		testing.expect_value(t, e, crdt.Error.None)
		check_delta(t, &file.text, &r.g, &db, before)
		size := crdt.text_len(&file.text)
		for c in r.conflicts {
			testing.expect(t, 0 <= c.start && c.start <= c.end && c.end <= size, "conflict region out of range")
			testing.expect(t, len(c.ours) > 0 && len(c.theirs) > 0, "conflict without both sides")
		}
		conflicts_clear(&r.conflicts)
	}
	flush(r)
	return .None if skip + valid == n else .Invalid
}

delta_sink :: proc(db: ^crdt.Delta_Builder) -> crdt.Text_Sink {
	return crdt.Text_Sink {
		data = db,
		insert = proc(data: rawptr, pos: int, bytes: []u8, author: crdt.Op_Id) {
			b := (^crdt.Delta_Builder)(data)
			c := make([]u8, len(bytes), b.allocator)
			copy(c, bytes)
			crdt.delta_step_insert(b, pos, c, author.actor)
		},
		delete = proc(data: rawptr, pos: int, bytes: []u8) {
			b := (^crdt.Delta_Builder)(data)
			c := make([]u8, len(bytes), b.allocator)
			copy(c, bytes)
			crdt.delta_step_delete(b, pos, c)
		},
	}
}

Check_Reader :: struct {
	t: ^crdt.Text,
	g: ^crdt.Graph,
}

check_delta :: proc(t: ^testing.T, text: ^crdt.Text, g: ^crdt.Graph, db: ^crdt.Delta_Builder, before: []u8) {
	after := crdt.text_bytes(text, context.temp_allocator)
	cr := Check_Reader{text, g}
	rd := crdt.Text_Reader {
		data = &cr,
		read = proc(data: rawptr, pos: int, dst: []u8) -> int {
			return crdt.text_read((^Check_Reader)(data).t, pos, dst)
		},
		author = proc(data: rawptr, pos: int) -> prim.Id {
			c := (^Check_Reader)(data)
			a, _, _ := crdt.text_author(c.t, c.g, pos)
			return a.actor
		},
		len = len(after),
	}
	regions := crdt.delta_regions(db, context.temp_allocator)
	wide := crdt.delta_widen(regions, &rd, context.temp_allocator)
	for utf16 in ([]bool{false, true}) {
		ops := make([dynamic]crdt.Delta_Op, context.temp_allocator)
		crdt.delta_emit(wide, utf16, proc(data: rawptr, pos: int) -> int {
			return crdt.text_units_at((^crdt.Text)(data), pos)
		}, text, &ops)
		if !utf16 {
			got, ok := crdt.delta_apply(before, ops[:], context.temp_allocator)
			testing.expect(t, ok && string(got) == string(after), "delta does not replay to the merged text")
		}
		if utf16 {
			old_units, new_units := 0, 0
			for o in ops {
				switch o.kind {
				case .Retain:
					old_units += o.n
					new_units += o.n
				case .Delete:
					old_units += o.n
				case .Insert:
					new_units += o.n
				}
			}
			testing.expect(t, crdt.units(before) - old_units == crdt.units(after) - new_units, "utf16 delta lengths disagree")
		}
	}
	for &r in wide {
		if len(r.ins) > 0 {
			at := r.new
			for o in r.ins {
				testing.expect(t, string(after[at:][:o.n]) == string(o.text), "region insert text mismatch")
				at += o.n
			}
		}
	}
	if len(after) > 0 {
		for k in 0 ..< 4 {
			p := (len(after) * k) / 4
			testing.expect_value(t, crdt.text_units_at(text, p), crdt.units(after[:p]))
		}
		testing.expect_value(t, crdt.text_units(text), crdt.units(after))
		u := crdt.text_units(text) / 2
		b := crdt.text_byte_at(text, u)
		testing.expect(t, crdt.units(after[:b]) <= u, "byte_at overshoots")
	}
}

hostile :: proc(id: prim.Id) -> bool {
	return id[1] == 0xad
}

REDACT :: u8(0xff)

redact_msg :: proc(actor: prim.Id, seq: u64, n: int) -> []u8 {
	buf := make([dynamic]u8)
	w := prim.writer(&buf)
	prim.write_u8(&w, REDACT)
	prim.write_id(&w, actor)
	prim.write_uvarint(&w, seq)
	prim.write_uvarint(&w, u64(n))
	return buf[:]
}

apply_redact :: proc(r: ^Replica, msg: []u8) {
	rd := prim.reader(msg[1:])
	actor := prim.read_id(&rd)
	seq := prim.read_uvarint(&rd)
	n := int(prim.read_uvarint(&rd))
	added := make([dynamic]crdt.Op_Span)
	defer delete(added)
	crdt.graph_redact(&r.g, actor, seq, n, &added)
	for a in added {
		for &f in r.files {
			crdt.log_redact(&f.log, &r.g, a.id.actor, a.id.seq, a.len)
			crdt.text_redact(&f.text, &r.g, a.id.actor, a.id.seq, a.len)
		}
	}
}

copy_read :: proc(data: rawptr, src: crdt.Op_Id, dst: []u8, authors: ^[dynamic]crdt.Author_Span) -> int {
	r := (^Replica)(data)
	done := 0
	for done < len(dst) {
		step := 0
		for &f in r.files {
			step = crdt.log_read(&f.log, &r.g, crdt.Op_Id{src.actor, src.seq + u64(done)}, dst[done:], authors)
			if step > 0 {
				break
			}
		}
		if step == 0 {
			break
		}
		done += step
	}
	return done
}

expected :: proc(g: ^crdt.Graph, s: Snapshot) -> ([]u8, []crdt.Author_Span) {
	bytes := slice.clone(s.bytes)
	spans := make([dynamic]crdt.Author_Span)
	pos := 0
	for sp in s.spans {
		for i in 0 ..< sp.len {
			id := crdt.Op_Id{sp.id.actor, sp.id.seq + u64(i)}
			op := crdt.Op_Id{sp.op.actor, sp.op.seq + u64(i)}
			red := crdt.graph_is_redacted(g, op)
			if red {
				bytes[pos + i] = 0
			}
			if n := len(spans); n > 0 {
				l := &spans[n - 1]
				if l.id.actor == id.actor && l.id.seq + u64(l.len) == id.seq && l.op.actor == op.actor && l.op.seq + u64(l.len) == op.seq && l.redacted == red {
					l.len += 1
					continue
				}
			}
			append(&spans, crdt.Author_Span{id = id, op = op, len = 1, redacted = red})
		}
		pos += sp.len
	}
	return bytes, spans[:]
}

deliver :: proc(t: ^testing.T, r: ^Replica, msg: []u8, rng: ^Rng) -> bool {
	if len(msg) > 0 && msg[0] == REDACT {
		apply_redact(r, msg)
		return true
	}
	b, err := crdt.batch_decode(msg, dict = r.dict)
	testing.expect_value(t, err, crdt.Error.None)
	if err != .None {
		return true
	}
	defer crdt.batch_destroy(&b)
	e := apply_batch(t, r, &b, chance(rng, 30))
	if e == .Missing {
		return false
	}
	if !hostile(b.actor) {
		testing.expect_value(t, e, crdt.Error.None)
	}
	return true
}

drain_pending :: proc(t: ^testing.T, r: ^Replica, rng: ^Rng) {
	for {
		progress := false
		for i := 0; i < len(r.pending); {
			if deliver(t, r, r.pending[i], rng) {
				delete(r.pending[i])
				unordered_remove(&r.pending, i)
				progress = true
			} else {
				i += 1
			}
		}
		if !progress {
			return
		}
	}
}

deliver_one :: proc(t: ^testing.T, r: ^Replica, rng: ^Rng) {
	if len(r.inbox) == 0 {
		return
	}
	i := below(rng, len(r.inbox))
	msg := r.inbox[i]
	unordered_remove(&r.inbox, i)
	if deliver(t, r, msg, rng) {
		delete(msg)
		drain_pending(t, r, rng)
	} else {
		append(&r.pending, msg)
	}
}

encode :: proc(b: ^crdt.Batch, dict: ^crdt.Actor_Dict = nil) -> []u8 {
	buf := make([dynamic]u8)
	err := crdt.batch_encode(b, &buf, dict)
	assert(err == .None)
	return buf[:]
}

send :: proc(rs: []Replica, from: int, b: ^crdt.Batch, rng: ^Rng) {
	n := crdt.batch_len(b)
	for &r, i in rs {
		if i == from {
			continue
		}
		cuts: [dynamic]int
		defer delete(cuts)
		append(&cuts, 0)
		if n > 1 && chance(rng, 40) {
			for _ in 0 ..< 1 + below(rng, 3) {
				append(&cuts, 1 + below(rng, n - 1))
			}
		}
		append(&cuts, n)
		slice.sort(cuts[:])
		for k in 0 ..< len(cuts) - 1 {
			if cuts[k] == cuts[k + 1] {
				continue
			}
			part, err := crdt.batch_slice(b, cuts[k], cuts[k + 1])
			assert(err == .None)
			append(&r.inbox, encode(&part, r.dict if chance(rng, 50) else nil))
			if chance(rng, 10) {
				append(&r.inbox, encode(&part, r.dict))
			}
			crdt.batch_destroy(&part)
		}
	}
}

LETTERS := [?]string{"abcdefgh", "ijklmnop", "qrstuvwx", "ABCDEFGH", "IJKLMNOP", "ab\xc3\xa9\xe2\x82\xac\xf0\x9d\x84\x9e"}

pick_pos :: proc(rng: ^Rng, size: int) -> int {
	switch below(rng, 6) {
	case 0:
		return 0
	case 1:
		return size
	case 2:
		return size / 2
	}
	return below(rng, size + 1)
}

local_edit :: proc(t: ^testing.T, rs: []Replica, who: int, rng: ^Rng) {
	r := &rs[who]
	sizes: [FILES]int
	for f in 0 ..< FILES {
		sizes[f] = crdt.text_len(&r.files[f].text)
	}
	ops := make([dynamic]crdt.Op_Run)
	defer delete(ops)
	content := make([dynamic][]u8)
	defer {
		for c in content {
			delete(c)
		}
		delete(content)
	}
	letters := LETTERS[who % len(LETTERS)]
	for _ in 0 ..< 1 + below(rng, 3) {
		f := below(rng, FILES)
		size := sizes[f]
		op := crdt.Op_Run {
			target = target_of(f),
		}
		roll := below(rng, 100)
		if size == 0 || roll < 55 {
			n := 1 + below(rng, 6)
			if chance(rng, 10) {
				n = 20 + below(rng, 300)
			}
			buf := make([]u8, n)
			for i in 0 ..< n {
				buf[i] = letters[below(rng, len(letters))]
			}
			append(&content, buf)
			op.kind = .Insert
			op.pos = pick_pos(rng, size)
			op.len = n
			op.content = buf
			if chance(rng, 20) {
				op.kind = .Insert_Ref
				op.content = nil
				op.ref.oid.len = 20 if chance(rng, 50) else 32
				op.ref.oid.bytes[0] = u8(below(rng, 256))
				op.ref.offset = below(rng, 1 << 20)
			} else if chance(rng, 30) {
				src := &r.files[below(rng, FILES)].log
				for _ in 0 ..< 8 {
					if len(src.entries) == 0 {
						break
					}
					e := src.entries[below(rng, len(src.entries))]
					if !crdt.is_insert(e.kind) {
						continue
					}
					k := below(rng, e.len)
					n = 1 + below(rng, min(e.len - k, 60))
					op.kind = .Insert_Copy
					op.content = nil
					op.len = n
					op.src = crdt.graph_id(&r.g, e.lv + k)
					break
				}
			}
			sizes[f] += n
		} else if roll < 85 {
			op.kind = .Delete
			op.pos = below(rng, size)
			maxn := size - op.pos
			op.len = 1 + below(rng, min(maxn, 8 if chance(rng, 80) else 200))
			sizes[f] -= op.len
		} else {
			op.kind = .Delete_Back
			op.pos = below(rng, size)
			op.len = 1 + below(rng, min(op.pos + 1, 12))
			sizes[f] -= op.len
		}
		append(&ops, op)
	}
	parents := crdt.graph_version_ids(&r.g, r.g.heads[:])
	defer delete(parents)
	lamport: u64 = 0
	for h in r.g.heads {
		lamport = max(lamport, crdt.graph_lamport(&r.g, h))
	}
	b := crdt.Batch {
		actor   = r.actor,
		seq     = r.seq,
		lamport = lamport + 1,
		parents = parents,
		ops     = ops[:],
	}
	err := apply_batch(t, r, &b, false)
	testing.expect_value(t, err, crdt.Error.None)
	r.seq += u64(crdt.batch_len(&b))
	for f in 0 ..< FILES {
		testing.expect_value(t, crdt.text_len(&r.files[f].text), sizes[f])
	}
	send(rs, who, &b, rng)
	if len(r.history) < 24 {
		append(&r.history, crdt.graph_version_ids(&r.g, r.g.heads[:]))
	}
}

attack :: proc(t: ^testing.T, rs: []Replica, who: int, rng: ^Rng, counter: ^u64) {
	r := &rs[who]
	counter^ += 1
	actor: prim.Id
	actor[0] = 0xee
	actor[1] = 0xad
	for i in 0 ..< 8 {
		actor[2 + i] = u8(counter^ >> (8 * u64(i)))
	}
	heads := crdt.graph_version_ids(&r.g, r.g.heads[:])
	defer delete(heads)
	parents := heads
	if len(r.history) > 0 && chance(rng, 50) {
		parents = r.history[below(rng, len(r.history))]
	}
	lamport: u64 = 0
	for p in parents {
		lv, _ := crdt.graph_lv(&r.g, p)
		lamport = max(lamport, crdt.graph_lamport(&r.g, lv))
	}
	ops := make([dynamic]crdt.Op_Run)
	defer delete(ops)
	content := make([dynamic]u8)
	defer delete(content)
	for _ in 0 ..< 32 {
		append(&content, 'Z')
	}
	for _ in 0 ..< 1 + below(rng, 3) {
		f := below(rng, FILES)
		size := crdt.text_len(&r.files[f].text)
		op := crdt.Op_Run {
			target = target_of(f),
			pos    = below(rng, 2 * size + 4),
			len    = 1 + below(rng, 12),
		}
		switch below(rng, 4) {
		case 3:
			op.kind = .Insert_Copy
			victim := &rs[below(rng, len(rs))]
			op.src = crdt.Op_Id{victim.actor, u64(below(rng, int(victim.seq) + 8))}
		case 0:
			op.kind = .Insert
			op.content = content[:op.len]
		case 1:
			op.kind = .Delete
		case:
			op.kind = .Delete_Back
		}
		append(&ops, op)
	}
	b := crdt.Batch {
		actor   = actor,
		seq     = 0,
		lamport = lamport + 1,
		parents = parents,
		ops     = ops[:],
	}
	zero := b
	bad := [1]crdt.Op_Run{{target = target_of(0), kind = .Delete, pos = 0, len = 0}}
	zero.ops = bad[:]
	scratch := make([dynamic]crdt.Lv)
	defer delete(scratch)
	_, zerr := crdt.graph_check(&r.g, &zero, &scratch)
	testing.expect_value(t, zerr, crdt.Error.Invalid)
	send(rs, -1, &b, rng)
}

snapshot :: proc(r: ^Replica, rng: ^Rng) {
	f := below(rng, FILES)
	file := &r.files[f]
	s := Snapshot {
		file    = f,
		version = crdt.text_version(&file.text, &r.g),
		bytes   = crdt.text_bytes(&file.text),
		spans   = crdt.text_spans(&file.text, &r.g),
	}
	if crdt.text_len(&file.text) > 0 {
		s.anchor, s.has = crdt.anchor_at(&file.text, &r.g, below(rng, crdt.text_len(&file.text)), .Before)
	}
	append(&r.snapshots, s)
}

spans_equal :: proc(a, b: []crdt.Author_Span) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

check_spans :: proc(t: ^testing.T, spans: []crdt.Author_Span, size: int) {
	total := 0
	for s in spans {
		total += s.len
	}
	testing.expect_value(t, total, size)
}

run_fuzz :: proc(t: ^testing.T, seed: u64, replicas: int, rounds: int) {
	rng := Rng{seed}
	rs := make([]Replica, replicas)
	defer {
		for &r in rs {
			replica_destroy(&r)
		}
		delete(rs)
	}
	dict: crdt.Actor_Dict
	crdt.dict_init(&dict)
	defer crdt.dict_destroy(&dict)
	crdt.dict_add(&dict, target_of(0).actor)
	for &r, i in rs {
		replica_init(&r, i, seed % 2 == 1)
		r.dict = &dict
		if i % 2 == 0 {
			crdt.dict_add(&dict, r.actor)
		}
	}
	attacks: u64
	for _ in 0 ..< rounds {
		who := below(&rng, replicas)
		switch below(&rng, 10) {
		case 0 ..= 3:
			if chance(&rng, 10) {
				victim := &rs[below(&rng, replicas)]
				seq := u64(below(&rng, int(victim.seq) + 20))
				n := 1 + below(&rng, 40)
				for &o in rs {
					append(&o.inbox, redact_msg(victim.actor, seq, n))
					if chance(&rng, 20) {
						append(&o.inbox, redact_msg(victim.actor, seq, n))
					}
				}
			} else if chance(&rng, 12) {
				attack(t, rs, who, &rng, &attacks)
			} else {
				local_edit(t, rs, who, &rng)
			}
		case 4 ..= 8:
			for _ in 0 ..< 1 + below(&rng, 4) {
				deliver_one(t, &rs[who], &rng)
			}
		case:
			snapshot(&rs[who], &rng)
		}
	}
	for {
		busy := false
		for &r in rs {
			for len(r.inbox) > 0 {
				deliver_one(t, &r, &rng)
				busy = true
			}
		}
		if !busy {
			break
		}
	}
	for &r in rs {
		for m in r.pending {
			b, err := crdt.batch_decode(m, dict = r.dict)
			testing.expect(t, err == .None && hostile(b.actor), "honest batch left pending")
			crdt.batch_destroy(&b)
		}
	}
	v0 := crdt.graph_version_ids(&rs[0].g, rs[0].g.heads[:])
	defer delete(v0)
	for f in 0 ..< FILES {
		b0 := crdt.text_bytes(&rs[0].files[f].text)
		s0 := crdt.text_spans(&rs[0].files[f].text, &rs[0].g)
		defer delete(b0)
		defer delete(s0)
		check_spans(t, s0, len(b0))
		for &r, i in rs[1:] {
			vi := crdt.graph_version_ids(&r.g, r.g.heads[:])
			bi := crdt.text_bytes(&r.files[f].text)
			si := crdt.text_spans(&r.files[f].text, &r.g)
			ok := slice.equal(v0, vi) && slice.equal(b0, bi) && spans_equal(s0, si)
			if !ok {
				testing.expectf(t, false, "seed %v file %v: replica %v diverged (%v vs %v bytes)", seed, f, i + 1, len(b0), len(bi))
			}
			delete(vi)
			delete(bi)
			delete(si)
		}
	}
	for &r in rs {
		for s in r.snapshots {
			file := &r.files[s.file]
			lvs := make([dynamic]crdt.Lv)
			defer delete(lvs)
			testing.expect_value(t, crdt.graph_version_lvs(&r.g, s.version, &lvs), crdt.Error.None)
			empty: crdt.Text
			crdt.text_init(&empty)
			out, err := crdt.text_checkout(&empty, &r.g, &file.log, lvs[:])
			crdt.text_destroy(&empty)
			testing.expect_value(t, err, crdt.Error.None)
			got := crdt.text_bytes(&out)
			gs := crdt.text_spans(&out, &r.g)
			want, wspans := expected(&r.g, s)
			defer delete(want)
			defer delete(wspans)
			if !slice.equal(got, want) || !spans_equal(gs, wspans) {
				testing.expectf(t, false, "seed %v: checkout mismatch (%v vs %v bytes)", seed, len(got), len(s.bytes))
			}
			delete(got)
			delete(gs)
			crdt.text_destroy(&out)
			if s.has {
				p0, e0 := crdt.anchor_resolve(&rs[0].files[s.file].text, &rs[0].g, &rs[0].files[s.file].log, s.anchor)
				testing.expect_value(t, e0, crdt.Error.None)
				testing.expect(t, p0 >= 0 && p0 <= crdt.text_len(&rs[0].files[s.file].text), "anchor out of range")
				live := crdt.text_spans(&rs[0].files[s.file].text, &rs[0].g)
				at := 0
				for sp in live {
					if sp.op.actor == s.anchor.id.actor && s.anchor.id.seq >= sp.op.seq && s.anchor.id.seq < sp.op.seq + u64(sp.len) {
						testing.expect_value(t, p0, at + int(s.anchor.id.seq - sp.op.seq))
					}
					at += sp.len
				}
				delete(live)
				for &o in rs[1:] {
					pi, ei := crdt.anchor_resolve(&o.files[s.file].text, &o.g, &o.files[s.file].log, s.anchor)
					testing.expect_value(t, ei, crdt.Error.None)
					testing.expect_value(t, pi, p0)
				}
			}
		}
	}
	for &r in rs {
		if !r.paged {
			continue
		}
		meta := make([dynamic]u8)
		defer delete(meta)
		testing.expect_value(t, crdt.graph_meta_encode(&r.g, &meta), crdt.Error.None)
		g2: crdt.Graph
		testing.expect_value(t, crdt.graph_open(&g2, meta[:], crdt.Graph_Source{&r.store, store_load}, window = 1), crdt.Error.None)
		defer crdt.graph_destroy(&g2)
		testing.expect(t, slice.equal(g2.heads[:], r.g.heads[:]), "reopened heads")
		for s in r.snapshots {
			lvs := make([dynamic]crdt.Lv)
			defer delete(lvs)
			testing.expect_value(t, crdt.graph_version_lvs(&g2, s.version, &lvs), crdt.Error.None)
			empty: crdt.Text
			crdt.text_init(&empty)
			out, err := crdt.text_checkout(&empty, &g2, &r.files[s.file].log, lvs[:])
			crdt.text_destroy(&empty)
			testing.expect_value(t, err, crdt.Error.None)
			got := crdt.text_bytes(&out)
			want, wspans := expected(&g2, s)
			testing.expect(t, slice.equal(got, want), "checkout through reopened graph")
			delete(want)
			delete(wspans)
			delete(got)
			crdt.text_destroy(&out)
			crdt.graph_trim(&g2)
		}
		testing.expect(t, !g2.failed, "reopened graph failed to load a page")
	}
	for f in 0 ..< FILES {
		buf := make([dynamic]u8)
		defer delete(buf)
		testing.expect_value(t, crdt.checkpoint_encode(&rs[0].files[f].text, &rs[0].g, &buf), crdt.Error.None)
		body := crdt.text_bytes(&rs[0].files[f].text)
		defer delete(body)
		back, err := crdt.checkpoint_decode(&rs[1].g, buf[:], body)
		testing.expect_value(t, err, crdt.Error.None)
		a := crdt.text_spans(&back, &rs[1].g)
		b := crdt.text_spans(&rs[1].files[f].text, &rs[1].g)
		testing.expect(t, spans_equal(a, b), "checkpoint round trip")
		testing.expect(t, slice.equal(back.version[:], rs[1].files[f].text.version[:]), "checkpoint version")
		delete(a)
		delete(b)
		crdt.text_destroy(&back)
	}
}

@(test)
convergence :: proc(t: ^testing.T) {
	for seed in 1 ..= u64(120) {
		run_fuzz(t, seed, 3 + int(seed % 4), 250)
	}
}

type_run :: proc(r: ^Replica, f: int, pos: int, s: string, backward: bool) {
	for i in 0 ..< len(s) {
		at := pos if backward else pos + i
		parents := crdt.graph_version_ids(&r.g, r.g.heads[:])
		lamport: u64 = 0
		for h in r.g.heads {
			lamport = max(lamport, crdt.graph_lamport(&r.g, h))
		}
		ops := [1]crdt.Op_Run{{target = target_of(f), kind = .Insert, pos = at, len = 1, content = transmute([]u8)s[i:i + 1]}}
		b := crdt.Batch {
			actor   = r.actor,
			seq     = r.seq,
			lamport = lamport + 1,
			parents = parents,
			ops     = ops[:],
		}
		first, skip, err := crdt.graph_add(&r.g, &b)
		assert(err == .None)
		crdt.log_add_batch(&r.files[f].log, &r.g, &b, target_of(f), first, skip)
		e := crdt.text_merge(&r.files[f].text, &r.g, &r.files[f].log, r.g.heads[:])
		assert(e == .None)
		r.seq += 1
		buf := make([dynamic]u8)
		_ = crdt.batch_encode(&b, &buf)
		append(&r.pending, buf[:])
		delete(parents)
	}
}

exchange :: proc(t: ^testing.T, rs: []Replica) {
	msgs := make([dynamic][]u8)
	defer {
		for m in msgs {
			delete(m)
		}
		delete(msgs)
	}
	for &r in rs {
		append(&msgs, ..r.pending[:])
		clear(&r.pending)
	}
	for &r in rs {
		for m in msgs {
			append(&r.inbox, slice.clone(m))
		}
		rng := Rng{7}
		for len(r.inbox) > 0 {
			deliver_one(t, &r, &rng)
		}
		testing.expect_value(t, len(r.pending), 0)
	}
}

random_delta :: proc(rng: ^Rng, size: int, tag: u8) -> []crdt.Delta_Op {
	out := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	at := 0
	for at < size || chance(rng, 30) {
		if chance(rng, 25) {
			break
		}
		switch below(rng, 3) {
		case 0:
			n := min(1 + below(rng, 4), size - at)
			crdt.delta_push(&out, crdt.Delta_Op{kind = .Retain, n = n})
			at += n
		case 1:
			n := min(1 + below(rng, 3), size - at)
			crdt.delta_push(&out, crdt.Delta_Op{kind = .Delete, n = n})
			at += n
		case 2:
			n := 1 + below(rng, 3)
			txt := make([]u8, n, context.temp_allocator)
			for &c in txt {
				c = tag + u8(below(rng, 3))
			}
			crdt.delta_push(&out, crdt.Delta_Op{kind = .Insert, n = n, text = txt})
		}
	}
	return out[:]
}

@(test)
deltas :: proc(t: ^testing.T) {
	rng := Rng{7}
	for _ in 0 ..< 20000 {
		size := below(&rng, 12)
		doc := make([]u8, size, context.temp_allocator)
		for &c in doc {
			c = 'a' + u8(below(&rng, 26))
		}
		a := random_delta(&rng, size, 'A')
		b := random_delta(&rng, size, '0')
		a2 := make([dynamic]crdt.Delta_Op, context.temp_allocator)
		b2 := make([dynamic]crdt.Delta_Op, context.temp_allocator)
		crdt.delta_transform(a, b, false, &a2, &b2)
		da, ok1 := crdt.delta_apply(doc, a, context.temp_allocator)
		db, ok2 := crdt.delta_apply(doc, b, context.temp_allocator)
		x, ok3 := crdt.delta_apply(da, b2[:], context.temp_allocator)
		y, ok4 := crdt.delta_apply(db, a2[:], context.temp_allocator)
		testing.expect(t, ok1 && ok2 && ok3 && ok4 && string(x) == string(y), "transform does not converge")
		p := below(&rng, size + 1)
		pa := crdt.delta_transform_pos(a, p, false, false)
		testing.expect(t, pa >= 0 && pa <= len(da), "transformed position out of range")
		free_all(context.temp_allocator)
	}
}

@(test)
no_interleaving :: proc(t: ^testing.T) {
	Case :: struct {
		back: [3]bool,
	}
	cases := [?]Case{{{false, false, false}}, {{true, true, true}}, {{false, true, false}}, {{true, false, true}}}
	words := [3]string{"aaaaaaaa", "bbbbbbbb", "cccccccc"}
	for c in cases {
		rs := make([]Replica, 3)
		for &r, i in rs {
			replica_init(&r, i)
		}
		type_run(&rs[0], 0, 0, "XY", false)
		exchange(t, rs)
		for i in 0 ..< 3 {
			type_run(&rs[i], 0, 1, words[i], c.back[i])
		}
		exchange(t, rs)
		text := crdt.text_bytes(&rs[0].files[0].text)
		s := string(text)
		testing.expect_value(t, len(s), 26)
		testing.expect(t, s[0] == 'X' && s[25] == 'Y', s)
		for w in words {
			testing.expectf(t, strings.contains(s, w), "interleaved: %v", s)
		}
		for &r in rs[1:] {
			other := crdt.text_bytes(&r.files[0].text)
			testing.expect(t, slice.equal(text, other), "diverged")
			delete(other)
		}
		delete(text)
		for &r in rs {
			replica_destroy(&r)
		}
		delete(rs)
	}
}

Edit :: struct {
	pos:  int,
	del:  int,
	char: u8,
}

synth_trace :: proc(n: int, seed: u64) -> []Edit {
	rng := Rng{seed}
	out := make([]Edit, n)
	size := 0
	cursor := 0
	burst := 0
	for i in 0 ..< n {
		if burst == 0 && below(&rng, 1000) < 75 {
			if below(&rng, 100) < 15 {
				cursor = below(&rng, size + 1)
			} else {
				burst = 1 + below(&rng, 12)
			}
		}
		if burst > 0 && cursor > 0 {
			out[i] = Edit{cursor - 1, 1, 0}
			cursor -= 1
			size -= 1
			burst -= 1
		} else {
			burst = 0
			out[i] = Edit{cursor, 0, u8('a' + below(&rng, 26))}
			cursor += 1
			size += 1
		}
	}
	return out
}

compress :: proc(trace: []Edit, target: crdt.Op_Id, content: ^[dynamic]u8) -> []crdt.Op_Run {
	runs := make([dynamic]crdt.Op_Run)
	for e in trace {
		if n := len(runs); n > 0 {
			last := &runs[n - 1]
			if e.del == 0 && last.kind == .Insert && e.pos == last.pos + last.len {
				append(content, e.char)
				last.len += 1
				continue
			}
			if e.del == 1 && last.kind == .Delete_Back && e.pos == last.pos - last.len {
				last.len += 1
				continue
			}
		}
		if e.del == 0 {
			append(content, e.char)
			append(&runs, crdt.Op_Run{target = target, kind = .Insert, pos = e.pos, len = 1})
		} else {
			append(&runs, crdt.Op_Run{target = target, kind = .Delete_Back, pos = e.pos, len = 1})
		}
	}
	at := 0
	for &r in runs {
		if r.kind == .Insert {
			r.content = content[at:][:r.len]
			at += r.len
		}
	}
	return runs[:]
}

replay_local :: proc(r: ^Replica, runs: []crdt.Op_Run, keep: ^[dynamic][]u8) -> int {
	ops := 0
	for &run in runs {
		parents: [1]crdt.Op_Id
		b := crdt.Batch {
			actor   = r.actor,
			seq     = r.seq,
			lamport = r.seq + 1,
			ops     = slice.from_ptr(&run, 1),
		}
		if r.seq > 0 {
			parents[0] = crdt.Op_Id{r.actor, r.seq - 1}
			b.parents = parents[:]
		}
		first, skip, err := crdt.graph_add(&r.g, &b)
		assert(err == .None)
		crdt.log_add_batch(&r.files[0].log, &r.g, &b, run.target, first, skip)
		e := crdt.text_merge(&r.files[0].text, &r.g, &r.files[0].log, r.g.heads[:])
		assert(e == .None)
		r.seq += u64(run.len)
		ops += run.len
		if keep != nil {
			out := make([dynamic]u8)
			_ = crdt.batch_encode(&b, &out)
			append(keep, out[:])
		}
	}
	return ops
}

rate :: proc(ops: int, d: time.Duration) -> f64 {
	return f64(ops) / time.duration_seconds(d) / 1e6
}

@(test)
throughput :: proc(t: ^testing.T) {
	trace := synth_trace(260_000, 42)
	defer delete(trace)
	content := make([dynamic]u8)
	defer delete(content)
	runs := compress(trace, target_of(0), &content)
	defer delete(runs)

	a: Replica
	replica_init(&a, 1)
	defer replica_destroy(&a)
	encoded := make([dynamic][]u8)
	defer {
		for m in encoded {
			delete(m)
		}
		delete(encoded)
	}
	start := time.tick_now()
	ops := replay_local(&a, runs, nil)
	local := time.tick_since(start)
	final := crdt.text_bytes(&a.files[0].text)
	defer delete(final)

	b: Replica
	replica_init(&b, 1)
	defer replica_destroy(&b)
	_ = replay_local(&b, runs, &encoded)
	bytes := 0
	for m in encoded {
		bytes += len(m)
	}

	c: Replica
	replica_init(&c, 2)
	defer replica_destroy(&c)
	dec: crdt.Decoder
	crdt.decoder_init(&dec)
	defer crdt.decoder_destroy(&dec)
	start = time.tick_now()
	for m in encoded {
		bt, err := crdt.decode(&dec, m)
		assert(err == .None)
		first, skip, e := crdt.graph_add(&c.g, &bt)
		assert(e == .None)
		crdt.log_add_batch(&c.files[0].log, &c.g, &bt, target_of(0), first, skip)
		_ = crdt.text_merge(&c.files[0].text, &c.g, &c.files[0].log, c.g.heads[:])
	}
	remote := time.tick_since(start)
	got := crdt.text_bytes(&c.files[0].text)
	testing.expect(t, slice.equal(got, final), "remote replay differs")
	delete(got)

	single := make([dynamic]crdt.Op_Run)
	defer delete(single)
	single_content := make([dynamic]u8)
	defer delete(single_content)
	for e in trace {
		if e.del == 0 {
			append(&single_content, e.char)
		}
	}
	at := 0
	for e in trace {
		if e.del == 0 {
			append(&single, crdt.Op_Run{target = target_of(0), kind = .Insert, pos = e.pos, len = 1, content = single_content[at:][:1]})
			at += 1
		} else {
			append(&single, crdt.Op_Run{target = target_of(0), kind = .Delete, pos = e.pos, len = 1})
		}
	}
	d: Replica
	replica_init(&d, 3)
	defer replica_destroy(&d)
	start = time.tick_now()
	_ = replay_local(&d, single[:], nil)
	per_op := time.tick_since(start)
	got = crdt.text_bytes(&d.files[0].text)
	testing.expect(t, slice.equal(got, final), "per-op replay differs")
	delete(got)

	empty: crdt.Text
	crdt.text_init(&empty)
	start = time.tick_now()
	co, cerr := crdt.text_checkout(&empty, &a.g, &a.files[0].log, a.files[0].text.version[:])
	checkout := time.tick_since(start)
	crdt.text_destroy(&empty)
	testing.expect_value(t, cerr, crdt.Error.None)
	got = crdt.text_bytes(&co)
	testing.expect(t, slice.equal(got, final), "checkout differs")
	delete(got)
	crdt.text_destroy(&co)

	half := len(trace) / 4
	t1 := synth_trace(half, 7)
	t2 := synth_trace(half, 8)
	defer delete(t1)
	defer delete(t2)
	c1 := make([dynamic]u8)
	c2 := make([dynamic]u8)
	defer delete(c1)
	defer delete(c2)
	r1 := compress(t1, target_of(0), &c1)
	r2 := compress(t2, target_of(0), &c2)
	defer delete(r1)
	defer delete(r2)
	x: Replica
	y: Replica
	replica_init(&x, 4)
	replica_init(&y, 5)
	defer replica_destroy(&x)
	defer replica_destroy(&y)
	xs := make([dynamic][]u8)
	ys := make([dynamic][]u8)
	defer {
		for m in xs {
			delete(m)
		}
		for m in ys {
			delete(m)
		}
		delete(xs)
		delete(ys)
	}
	_ = replay_local(&x, r1, &xs)
	_ = replay_local(&y, r2, &ys)
	start = time.tick_now()
	for m in ys {
		bt, _ := crdt.decode(&dec, m)
		first, skip, _ := crdt.graph_add(&x.g, &bt)
		crdt.log_add_batch(&x.files[0].log, &x.g, &bt, target_of(0), first, skip)
	}
	_ = crdt.text_merge(&x.files[0].text, &x.g, &x.files[0].log, x.g.heads[:])
	merge := time.tick_since(start)
	for m in xs {
		bt, _ := crdt.decode(&dec, m)
		first, skip, _ := crdt.graph_add(&y.g, &bt)
		crdt.log_add_batch(&y.files[0].log, &y.g, &bt, target_of(0), first, skip)
	}
	_ = crdt.text_merge(&y.files[0].text, &y.g, &y.files[0].log, y.g.heads[:])
	mx := crdt.text_bytes(&x.files[0].text)
	my := crdt.text_bytes(&y.files[0].text)
	testing.expect(t, slice.equal(mx, my), "merged replicas differ")
	delete(mx)
	delete(my)
	merge_ops := 0
	for r in r1 {
		merge_ops += r.len
	}
	for r in r2 {
		merge_ops += r.len
	}

	spans := crdt.text_spans(&a.files[0].text, &a.g)
	defer delete(spans)
	fmt.printfln("trace: %v ops, %v runs, final %v bytes, %v graph entries, %v spans", ops, len(runs), len(final), crdt.graph_records(&a.g), len(spans))
	fmt.printfln("local apply (runs):   %.1f Mops/s (%v)", rate(ops, local), local)
	fmt.printfln("remote decode+apply:  %.1f Mops/s (%v), %v bytes encoded", rate(ops, remote), remote, bytes)
	fmt.printfln("local apply (per op): %.1f Mops/s (%v)", rate(ops, per_op), per_op)
	fmt.printfln("checkout from empty:  %.1f Mops/s (%v)", rate(ops, checkout), checkout)
	fmt.printfln("merge 2x%v concurrent ops: %v (%.1f Mops/s)", half, merge, rate(merge_ops, merge))

	fork := make([dynamic]u8)
	defer delete(fork)
	tail := runs[len(runs) - 40:]
	z: Replica
	replica_init(&z, 6)
	defer replica_destroy(&z)
	_ = replay_local(&z, runs[:len(runs) - 40], nil)
	parents := crdt.graph_version_ids(&z.g, z.g.heads[:])
	defer delete(parents)
	side := [1]crdt.Op_Run{{target = target_of(0), kind = .Insert, pos = 0, len = 5, content = transmute([]u8)string("hello")}}
	sb := crdt.Batch {
		actor   = actor_of(7),
		seq     = 0,
		lamport = z.seq + 1,
		parents = parents,
		ops     = side[:],
	}
	_ = crdt.batch_encode(&sb, &fork)
	_ = replay_local(&z, tail, nil)
	start = time.tick_now()
	fb, _ := crdt.decode(&dec, fork[:])
	first, skip, _ := crdt.graph_add(&z.g, &fb)
	crdt.log_add_batch(&z.files[0].log, &z.g, &fb, target_of(0), first, skip)
	_ = crdt.text_merge(&z.files[0].text, &z.g, &z.files[0].log, z.g.heads[:])
	small := time.tick_since(start)
	fmt.printfln("merge 5-op branch into %v-op history (40 concurrent runs): %v", ops, small)

	anchors := make([dynamic]crdt.Anchor)
	defer delete(anchors)
	arng := Rng{5}
	for _ in 0 ..< 10_000 {
		an, _ := crdt.anchor_at(&a.files[0].text, &a.g, below(&arng, len(final)), .Before)
		append(&anchors, an)
	}
	start = time.tick_now()
	for an in anchors {
		_, _ = crdt.anchor_resolve(&a.files[0].text, &a.g, &a.files[0].log, an)
	}
	fmt.printfln("resolve 10k anchors (incl. index build): %v", time.tick_since(start))

	dict: crdt.Actor_Dict
	crdt.dict_init(&dict)
	defer crdt.dict_destroy(&dict)
	crdt.dict_add(&dict, a.actor)
	crdt.dict_add(&dict, target_of(0).actor)
	dict_bytes := 0
	for m in encoded {
		bt, _ := crdt.decode(&dec, m)
		out := make([dynamic]u8)
		_ = crdt.batch_encode(&bt, &out, &dict)
		dict_bytes += len(out)
		delete(out)
	}
	fmt.printfln("encoded with actor dictionary: %v bytes (%.1f bytes/batch, was %.1f)", dict_bytes, f64(dict_bytes) / f64(len(encoded)), f64(bytes) / f64(len(encoded)))

	for paged in ([2]bool{false, true}) {
		h: Replica
		replica_init(&h, 8)
		defer replica_destroy(&h)
		if paged {
			crdt.graph_destroy(&h.g)
			crdt.graph_init(&h.g, source = crdt.Graph_Source{&h.store, store_load})
			h.paged = true
		}
		actors := [4]prim.Id{actor_of(20), actor_of(21), actor_of(22), actor_of(23)}
		seqs: [4]u64
		prev: crdt.Op_Id
		batches := 100_000
		mops := [1]crdt.Op_Run{{target = target_of(1), kind = .Delete, pos = 0, len = 10}}
		start = time.tick_now()
		for i in 0 ..< batches {
			k := i % 4
			pb := [1]crdt.Op_Id{prev}
			bt := crdt.Batch {
				actor   = actors[k],
				seq     = seqs[k],
				lamport = u64(i * 10 + 1),
				ops     = mops[:],
			}
			if i > 0 {
				bt.parents = pb[:]
			}
			_, _, e := crdt.graph_add(&h.g, &bt)
			assert(e == .None)
			seqs[k] += 10
			prev = crdt.Op_Id{actors[k], seqs[k] - 1}
			if paged && i % 4096 == 0 {
				flush(&h)
			}
		}
		flush(&h)
		build := time.tick_since(start)
		stored := 0
		for _, v in h.store.pages {
			stored += len(v)
		}
		mem := crdt.graph_memory(&h.g)
		start = time.tick_now()
		hit := 0
		for i in 0 ..< 1000 {
			lv, _ := crdt.graph_lv(&h.g, crdt.Op_Id{actors[i % 4], u64(i * 997 % 250_000)})
			buf: [1]crdt.Lv
			hit += len(crdt.graph_parents(&h.g, lv, &buf))
		}
		random := time.tick_since(start)
		crdt.graph_trim(&h.g)
		fmt.printfln("graph 1M ops / %v records, paged=%v: resident %.2f MiB, persisted %.2f MiB, build %v, 1000 random old lookups %v", crdt.graph_records(&h.g), paged, f64(mem) / (1 << 20), f64(stored) / (1 << 20), build, random)
	}
}

@(test)
malformed :: proc(t: ^testing.T) {
	rng := Rng{99}
	rs := make([]Replica, 2)
	defer {
		for &r in rs {
			replica_destroy(&r)
		}
		delete(rs)
	}
	for &r, i in rs {
		replica_init(&r, i)
	}
	for _ in 0 ..< 300 {
		local_edit(t, rs, below(&rng, 2), &rng)
		if chance(&rng, 30) {
			deliver_one(t, &rs[below(&rng, 2)], &rng)
		}
	}
	junk: Replica
	replica_init(&junk, 9)
	defer replica_destroy(&junk)
	dec: crdt.Decoder
	crdt.decoder_init(&dec)
	defer crdt.decoder_destroy(&dec)
	scratch := make([dynamic]u8)
	defer delete(scratch)
	for msg in rs[1].inbox {
		for _ in 0 ..< 8 {
			clear(&scratch)
			append(&scratch, ..msg)
			switch below(&rng, 3) {
			case 0:
				scratch[below(&rng, len(scratch))] ~= u8(1 << uint(below(&rng, 8)))
			case 1:
				resize(&scratch, below(&rng, len(scratch)))
			case:
				for _ in 0 ..< 4 {
					scratch[below(&rng, len(scratch))] = u8(next(&rng))
				}
			}
			b, err := crdt.decode(&dec, scratch[:])
			if err != .None {
				continue
			}
			_ = apply_batch(t, &junk, &b, true)
		}
		b, err := crdt.decode(&dec, msg)
		testing.expect_value(t, err, crdt.Error.None)
		_ = apply_batch(t, &junk, &b, false)
	}
}

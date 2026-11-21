package crdt

import "../prim"

BATCH_FORMAT :: u8(1)
CHECKPOINT_FORMAT :: u8(1)
MAX_POS :: 1 << 46

@(private)
Actor_Table :: struct {
	ids: [dynamic]prim.Id,
}

@(private)
actor_slot :: proc(t: ^Actor_Table, id: prim.Id) -> u64 {
	for x, i in t.ids {
		if x == id {
			return u64(i)
		}
	}
	append(&t.ids, id)
	return u64(len(t.ids) - 1)
}

BATCH_DICT_FORMAT :: u8(2)

Actor_Dict :: struct {
	ids:   [dynamic]prim.Id,
	index: map[prim.Id]u32,
}

dict_init :: proc(d: ^Actor_Dict, allocator := context.allocator) {
	d.ids = make([dynamic]prim.Id, allocator)
	d.index = make(map[prim.Id]u32, allocator)
}

dict_destroy :: proc(d: ^Actor_Dict) {
	delete(d.ids)
	delete(d.index)
	d^ = {}
}

dict_add :: proc(d: ^Actor_Dict, id: prim.Id) -> u32 {
	if ix, ok := d.index[id]; ok {
		return ix
	}
	ix := u32(len(d.ids))
	append(&d.ids, id)
	d.index[id] = ix
	return ix
}

dict_find :: proc(d: ^Actor_Dict, id: prim.Id) -> (u32, bool) {
	ix, ok := d.index[id]
	return ix, ok
}

batch_encode :: proc(b: ^Batch, buf: ^[dynamic]u8, dict: ^Actor_Dict = nil) -> Error {
	table := Actor_Table {
		ids = make([dynamic]prim.Id, 0, 8, buf.allocator),
	}
	defer delete(table.ids)
	append(&table.ids, b.actor)
	for p in b.parents {
		actor_slot(&table, p.actor)
	}
	for &op in b.ops {
		if op.len <= 0 || op.len > MAX_RUN || op.pos < -MAX_RUN || op.pos > MAX_POS {
			return .Invalid
		}
		if op.kind == .Insert && len(op.content) != op.len {
			return .Invalid
		}
		if op.kind == .Insert_Ref && (op.ref.offset < 0 || op.ref.offset > MAX_POS) {
			return .Invalid
		}
		actor_slot(&table, op.target.actor)
		if op.kind == .Insert_Copy {
			actor_slot(&table, op.src.actor)
		}
		if op.kind == .Insert_Ref && op.ref.oid.len != 20 && op.ref.oid.len != 32 {
			return .Invalid
		}
	}
	w := prim.writer(buf)
	prim.write_u8(&w, BATCH_FORMAT if dict == nil else BATCH_DICT_FORMAT)
	prim.write_uvarint(&w, u64(len(table.ids)))
	for id in table.ids {
		if dict == nil {
			prim.write_id(&w, id)
		} else if ix, ok := dict_find(dict, id); ok {
			prim.write_uvarint(&w, u64(ix) + 1)
		} else {
			prim.write_uvarint(&w, 0)
			prim.write_id(&w, id)
		}
	}
	prim.write_uvarint(&w, b.seq)
	prim.write_uvarint(&w, b.lamport)
	prim.write_uvarint(&w, u64(len(b.parents)))
	for p in b.parents {
		prim.write_uvarint(&w, actor_slot(&table, p.actor))
		prim.write_uvarint(&w, p.seq)
	}
	prim.write_uvarint(&w, u64(len(b.ops)))
	prev: Op_Id
	pred := 0
	for &op, i in b.ops {
		same := i > 0 && op.target == prev
		prim.write_u8(&w, u8(op.kind) | (8 if same else 0))
		if !same {
			prim.write_uvarint(&w, actor_slot(&table, op.target.actor))
			prim.write_uvarint(&w, op.target.seq)
			pred = 0
			prev = op.target
		}
		prim.write_uvarint(&w, u64(op.len))
		if op.kind != .Opaque {
			prim.write_ivarint(&w, i64(op.pos - pred))
		}
		switch op.kind {
		case .Insert:
			prim.write_raw(&w, op.content)
			pred = op.pos + op.len
		case .Insert_Ref:
			oid := op.ref.oid
			prim.write_u8(&w, oid.len)
			prim.write_raw(&w, oid_bytes(&oid))
			prim.write_uvarint(&w, u64(op.ref.offset))
			pred = op.pos + op.len
		case .Insert_Copy:
			prim.write_uvarint(&w, actor_slot(&table, op.src.actor))
			prim.write_uvarint(&w, op.src.seq)
			pred = op.pos + op.len
		case .Delete:
			pred = op.pos
		case .Delete_Back:
			pred = op.pos - op.len
		case .Opaque:
			prim.write_bytes(&w, op.content)
		}
	}
	if w.err != .None {
		return .Too_Large
	}
	return .None
}

Decoder :: struct {
	actors:  [dynamic]prim.Id,
	parents: [dynamic]Op_Id,
	ops:     [dynamic]Op_Run,
}

decoder_init :: proc(d: ^Decoder, allocator := context.allocator) {
	d.actors = make([dynamic]prim.Id, allocator)
	d.parents = make([dynamic]Op_Id, allocator)
	d.ops = make([dynamic]Op_Run, allocator)
}

decoder_destroy :: proc(d: ^Decoder) {
	delete(d.actors)
	delete(d.parents)
	delete(d.ops)
	d^ = {}
}

decode :: proc(d: ^Decoder, data: []u8, dict: ^Actor_Dict = nil) -> (b: Batch, err: Error) {
	clear(&d.actors)
	clear(&d.parents)
	clear(&d.ops)
	r := prim.reader(data)
	format := prim.read_u8(&r)
	if format != BATCH_FORMAT && (format != BATCH_DICT_FORMAT || dict == nil) {
		return {}, .Corrupt
	}
	na := prim.read_uvarint(&r)
	if r.err != .None || na == 0 || na > u64(prim.reader_remaining(&r)) {
		return {}, .Corrupt
	}
	for _ in 0 ..< int(na) {
		if format == BATCH_FORMAT {
			append(&d.actors, prim.read_id(&r))
			continue
		}
		ref := prim.read_uvarint(&r)
		if ref == 0 {
			append(&d.actors, prim.read_id(&r))
		} else if ref - 1 < u64(len(dict.ids)) {
			append(&d.actors, dict.ids[ref - 1])
		} else {
			return {}, .Corrupt
		}
	}
	if r.err != .None {
		return {}, .Corrupt
	}
	actors := d.actors[:]
	b.actor = actors[0]
	b.seq = prim.read_uvarint(&r)
	b.lamport = prim.read_uvarint(&r)
	np := prim.read_uvarint(&r)
	if r.err != .None || np > u64(prim.reader_remaining(&r) / 2) {
		return {}, .Corrupt
	}
	for _ in 0 ..< int(np) {
		ix := prim.read_uvarint(&r)
		seq := prim.read_uvarint(&r)
		if ix >= u64(len(actors)) {
			return {}, .Corrupt
		}
		append(&d.parents, Op_Id{actors[ix], seq})
	}
	nr := prim.read_uvarint(&r)
	if r.err != .None || nr == 0 || nr > u64(prim.reader_remaining(&r) / 2) {
		return {}, .Corrupt
	}
	total := 0
	target: Op_Id
	pred := 0
	for i in 0 ..< int(nr) {
		tag := prim.read_u8(&r)
		if tag & ~u8(15) != 0 || tag & 7 > u8(max(Op_Kind)) || (i == 0 && tag & 8 != 0) {
			return {}, .Corrupt
		}
		kind := Op_Kind(tag & 7)
		if tag & 8 == 0 {
			ix := prim.read_uvarint(&r)
			seq := prim.read_uvarint(&r)
			if ix >= u64(len(actors)) {
				return {}, .Corrupt
			}
			target = Op_Id{actors[ix], seq}
			pred = 0
		}
		n := prim.read_uvarint(&r)
		if r.err != .None || n == 0 || n > MAX_RUN {
			return {}, .Corrupt
		}
		op := Op_Run {
			target = target,
			kind   = kind,
			len    = int(n),
		}
		if kind != .Opaque {
			delta := prim.read_ivarint(&r)
			if delta < -MAX_POS || delta > MAX_POS {
				return {}, .Corrupt
			}
			op.pos = pred + int(delta)
			if op.pos < -MAX_RUN || op.pos > MAX_POS {
				return {}, .Corrupt
			}
		}
		switch kind {
		case .Insert:
			op.content = prim.read_raw(&r, op.len)
			pred = op.pos + op.len
		case .Insert_Ref:
			ol := prim.read_u8(&r)
			if ol != 20 && ol != 32 {
				return {}, .Corrupt
			}
			op.ref.oid.len = ol
			prim.read_fixed(&r, op.ref.oid.bytes[:ol])
			off := prim.read_uvarint(&r)
			if off > MAX_POS {
				return {}, .Corrupt
			}
			op.ref.offset = int(off)
			pred = op.pos + op.len
		case .Insert_Copy:
			ix := prim.read_uvarint(&r)
			sq := prim.read_uvarint(&r)
			if ix >= u64(len(actors)) || sq >= MAX_COUNTER - u64(op.len) {
				return {}, .Corrupt
			}
			op.src = Op_Id{actors[ix], sq}
			pred = op.pos + op.len
		case .Delete:
			pred = op.pos
		case .Delete_Back:
			pred = op.pos - op.len
		case .Opaque:
			op.content = prim.read_bytes(&r)
		}
		if r.err != .None {
			return {}, .Corrupt
		}
		total += op.len
		if total > MAX_RUN {
			return {}, .Corrupt
		}
		append(&d.ops, op)
	}
	if !prim.reader_done(&r) || b.seq >= MAX_COUNTER - u64(total) || b.lamport == 0 || b.lamport >= MAX_COUNTER - u64(total) {
		return {}, .Corrupt
	}
	b.parents = d.parents[:]
	b.ops = d.ops[:]
	return b, .None
}

batch_decode :: proc(data: []u8, allocator := context.allocator, dict: ^Actor_Dict = nil) -> (b: Batch, err: Error) {
	d: Decoder
	decoder_init(&d, allocator)
	defer decoder_destroy(&d)
	b = decode(&d, data, dict) or_return
	b.parents = make([]Op_Id, len(d.parents), allocator)
	copy(b.parents, d.parents[:])
	b.ops = make([]Op_Run, len(d.ops), allocator)
	copy(b.ops, d.ops[:])
	return b, .None
}

batch_slice :: proc(b: ^Batch, from, to: int, allocator := context.allocator) -> (out: Batch, err: Error) {
	n := batch_len(b)
	if from < 0 || to > n || from >= to {
		return {}, .Invalid
	}
	out.actor = b.actor
	out.seq = b.seq + u64(from)
	out.lamport = b.lamport + u64(from)
	if from == 0 {
		out.parents = make([]Op_Id, len(b.parents), allocator)
		copy(out.parents, b.parents)
	} else {
		out.parents = make([]Op_Id, 1, allocator)
		out.parents[0] = Op_Id{b.actor, out.seq - 1}
	}
	ops := make([dynamic]Op_Run, 0, len(b.ops), allocator)
	o := 0
	for op in b.ops {
		lo := max(from, o)
		hi := min(to, o + op.len)
		if hi > lo {
			if op.kind == .Opaque && (lo > o || hi < o + op.len) {
				delete(ops)
				delete(out.parents, allocator)
				return {}, .Invalid
			}
			append(&ops, run_tail(run_head(op, hi - o), lo - o))
		}
		o += op.len
	}
	out.ops = ops[:]
	return out, .None
}

checkpoint_encode :: proc(t: ^Text, g: ^Graph, buf: ^[dynamic]u8) -> Error {
	spans := text_spans(t, g, buf.allocator)
	defer delete(spans, buf.allocator)
	table := Actor_Table {
		ids = make([dynamic]prim.Id, 0, 8, buf.allocator),
	}
	defer delete(table.ids)
	version := text_version(t, g, buf.allocator)
	defer delete(version, buf.allocator)
	for v in version {
		actor_slot(&table, v.actor)
	}
	for s in spans {
		actor_slot(&table, s.op.actor)
		actor_slot(&table, s.id.actor)
	}
	ends := make([]u64, len(table.ids), buf.allocator)
	defer delete(ends, buf.allocator)
	w := prim.writer(buf)
	prim.write_u8(&w, CHECKPOINT_FORMAT)
	prim.write_uvarint(&w, u64(len(table.ids)))
	for id in table.ids {
		prim.write_id(&w, id)
	}
	prim.write_uvarint(&w, u64(len(version)))
	for v in version {
		prim.write_uvarint(&w, actor_slot(&table, v.actor))
		prim.write_uvarint(&w, v.seq)
	}
	prim.write_uvarint(&w, u64(len(spans)))
	for s in spans {
		ix := actor_slot(&table, s.op.actor)
		copied := s.id != s.op
		prim.write_uvarint(&w, ix)
		prim.write_ivarint(&w, i64(s.op.seq) - i64(ends[ix]))
		prim.write_uvarint(&w, u64(s.len) << 2 | (2 if copied else 0) | (1 if s.redacted else 0))
		if copied {
			prim.write_uvarint(&w, actor_slot(&table, s.id.actor))
			prim.write_uvarint(&w, s.id.seq)
		}
		ends[ix] = s.op.seq + u64(s.len)
	}
	if w.err != .None {
		return .Too_Large
	}
	return .None
}

checkpoint_decode :: proc(g: ^Graph, data: []u8, text: []u8, allocator := context.allocator) -> (t: Text, err: Error) {
	r := prim.reader(data)
	if prim.read_u8(&r) != CHECKPOINT_FORMAT {
		return {}, .Corrupt
	}
	na := prim.read_uvarint(&r)
	if r.err != .None || na > u64(prim.reader_remaining(&r) / 16) {
		return {}, .Corrupt
	}
	actors := make([]prim.Id, int(na), allocator)
	defer delete(actors, allocator)
	ends := make([]u64, int(na), allocator)
	defer delete(ends, allocator)
	for i in 0 ..< len(actors) {
		actors[i] = prim.read_id(&r)
	}
	nv := prim.read_uvarint(&r)
	if r.err != .None || nv > u64(prim.reader_remaining(&r) / 2) {
		return {}, .Corrupt
	}
	version := make([]Op_Id, int(nv), allocator)
	defer delete(version, allocator)
	for i in 0 ..< len(version) {
		ix := prim.read_uvarint(&r)
		seq := prim.read_uvarint(&r)
		if ix >= na {
			return {}, .Corrupt
		}
		version[i] = Op_Id{actors[ix], seq}
	}
	ns := prim.read_uvarint(&r)
	if r.err != .None || ns > u64(prim.reader_remaining(&r) / 3) {
		return {}, .Corrupt
	}
	spans := make([]Author_Span, int(ns), allocator)
	defer delete(spans, allocator)
	for i in 0 ..< len(spans) {
		ix := prim.read_uvarint(&r)
		d := prim.read_ivarint(&r)
		packed := prim.read_uvarint(&r)
		n := packed >> 2
		if r.err != .None || ix >= na || n == 0 || n > MAX_RUN {
			return {}, .Corrupt
		}
		seq := i64(ends[ix]) + d
		if seq < 0 || u64(seq) >= MAX_COUNTER - n {
			return {}, .Corrupt
		}
		op := Op_Id{actors[ix], u64(seq)}
		author := op
		if packed & 2 != 0 {
			ax := prim.read_uvarint(&r)
			as := prim.read_uvarint(&r)
			if r.err != .None || ax >= na || as >= MAX_COUNTER - n {
				return {}, .Corrupt
			}
			author = Op_Id{actors[ax], as}
		}
		spans[i] = Author_Span{id = author, op = op, len = int(n), redacted = packed & 1 == 1}
		ends[ix] = u64(seq) + n
	}
	if !prim.reader_done(&r) {
		return {}, .Corrupt
	}
	err = text_from(&t, g, text, spans, version, allocator)
	return
}

package engine

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "../crdt"
import "../prim"
import osync "../sync"

CURSOR_TAG :: u64(0x30_6e_64_62_63_75_72_73)
CURSOR_MAX_RANGES :: 256

@(private)
Cursor_Set :: struct {
	device:  prim.Id,
	actor:   prim.Id,
	seq:     u64,
	ranges:  [dynamic][2]Anchor,
	missing: bool,
}

@(private)
_cursor_set_free :: proc(e: ^Engine, c: ^Cursor_Set) {
	delete(c.ranges)
}

@(private)
_anchor_put :: proc(w: ^prim.Writer, a: Anchor) {
	if a.id.actor == {} {
		prim.write_u8(w, u8(min(a.offset, 1)))
		return
	}
	prim.write_u8(w, 2 if a.bias == .Before else 3)
	prim.write_id(w, a.id.actor)
	prim.write_uvarint(w, a.id.seq)
	prim.write_uvarint(w, u64(max(a.offset, 0)))
}

@(private)
_anchor_get :: proc(r: ^prim.Reader) -> (a: Anchor) {
	k := prim.read_u8(r)
	switch k {
	case 0:
		return ANCHOR_START
	case 1:
		return ANCHOR_END
	}
	a.bias = .Before if k == 2 else .After
	a.id.actor = prim.read_id(r)
	a.id.seq = prim.read_uvarint(r)
	a.offset = int(min(prim.read_uvarint(r), u64(crdt.MAX_POS)))
	return
}

anchor_encode :: proc(a: Anchor, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, 0, 32, allocator)
	w := prim.writer(&buf)
	_anchor_put(&w, a)
	return buf[:]
}

anchor_decode :: proc(b: []u8) -> (a: Anchor, ok: bool) {
	r := prim.reader(b)
	a = _anchor_get(&r)
	return a, prim.reader_ok(&r) && prim.reader_done(&r)
}

buffer_cursors :: proc(e: ^Engine, id: Buffer_Id, rev: u64, ranges: []Cursor_Range) -> Error {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return .Not_Found
	}
	if len(ranges) > CURSOR_MAX_RANGES {
		return .Limit
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_base(e, b, rev) or_return
	_buffer_view_ready(e, b, h) or_return
	pos := make([]int, 2 * len(ranges), context.temp_allocator)
	for r, i in ranges {
		pos[2 * i] = r.anchor
		pos[2 * i + 1] = r.head
	}
	anchors := buffer_anchors(e, id, rev, pos, .After, context.temp_allocator) or_return
	clear(&b.mine)
	for i in 0 ..< len(ranges) {
		append(&b.mine, [2]Anchor{anchors[2 * i], anchors[2 * i + 1]})
	}
	b.mine_dirty = true
	_touch(e)
	return .None
}

@(private)
_cursors_publish :: proc(e: ^Engine, b: ^Buffer, h: ^Handle, ranges: [][2]Anchor) {
	b.mine_seq += 1
	_cursors_local(e, b.object.id, b.id, e.self, b.actor, b.mine_seq, ranges)
	if !h.sp.repl_on {
		return
	}
	devices := make([dynamic]osync.Device_Id, context.temp_allocator)
	osync.replicator_present(&h.sp.repl, &devices)
	if len(devices) == 0 {
		return
	}
	plain := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&plain)
	prim.write_id(&w, b.actor)
	prim.write_uvarint(&w, b.mine_seq)
	prim.write_uvarint(&w, u64(len(ranges)))
	for r in ranges {
		_anchor_put(&w, r[0])
		_anchor_put(&w, r[1])
	}
	key, index := osync.cursor_keys(&h.scope)
	defer crypto.zero_explicit(&key, size_of(key))
	msg := make([]u8, 16 + 12 + len(plain) + chacha20poly1305.TAG_SIZE, context.temp_allocator)
	copy(msg[:16], index[:])
	nonce := msg[16:28]
	prim.random_fill(e.cfg.random, nonce)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	defer chacha20poly1305.reset(&ctx)
	body := msg[28:28 + len(plain)]
	tag := msg[28 + len(plain):]
	chacha20poly1305.seal(&ctx, body, tag, nonce, index[:], plain[:])
	for d in devices {
		osync.replicator_direct(&h.sp.repl, d, CURSOR_TAG, msg)
	}
}

@(private)
Cursor_Msg :: struct {
	space:   prim.Id,
	device:  prim.Id,
	payload: []u8,
}

@(private)
_cursors_queue :: proc(e: ^Engine, sp: ^Space, device: prim.Id, payload: []u8) {
	if len(e.buffers) == 0 || len(payload) == 0 || len(e.cursor_inbox) >= 4096 {
		return
	}
	p := make([]u8, len(payload), e.allocator)
	copy(p, payload)
	append(&e.cursor_inbox, Cursor_Msg{space = sp.id, device = device, payload = p})
	_touch(e)
}

@(private)
_cursors_drain :: proc(e: ^Engine) {
	if len(e.cursor_inbox) == 0 {
		return
	}
	msgs := e.cursor_inbox
	e.cursor_inbox = make([dynamic]Cursor_Msg, e.allocator)
	for m in msgs {
		if sp, ok := e.spaces[m.space]; ok {
			_cursors_received(e, sp, m.device, m.payload)
		}
		delete(m.payload, e.allocator)
	}
	delete(msgs)
}

@(private)
_cursors_free_inbox :: proc(e: ^Engine) {
	for m in e.cursor_inbox {
		delete(m.payload, e.allocator)
	}
	delete(e.cursor_inbox)
	e.cursor_inbox = nil
}

@(private)
_cursors_received :: proc(e: ^Engine, sp: ^Space, device: prim.Id, payload: []u8) {
	if len(payload) < 16 + 12 + chacha20poly1305.TAG_SIZE || device == e.self {
		return
	}
	for b in e.buffers {
		if b.object.space != sp.id {
			continue
		}
		h, ok := e.handles[b.object.id]
		if !ok {
			continue
		}
		key, index := osync.cursor_keys(&h.scope)
		defer crypto.zero_explicit(&key, size_of(key))
		if string(index[:]) != string(payload[:16]) {
			continue
		}
		n := len(payload) - 28 - chacha20poly1305.TAG_SIZE
		plain := make([]u8, n, context.temp_allocator)
		ctx: chacha20poly1305.Context
		chacha20poly1305.init(&ctx, key[:])
		good := chacha20poly1305.open(&ctx, plain, payload[16:28], index[:], payload[28:28 + n], payload[28 + n:])
		chacha20poly1305.reset(&ctx)
		if !good {
			return
		}
		r := prim.reader(plain)
		actor := prim.read_id(&r)
		seq := prim.read_uvarint(&r)
		cnt := prim.read_uvarint(&r)
		if !prim.reader_ok(&r) || cnt > CURSOR_MAX_RANGES {
			return
		}
		ranges := make([][2]Anchor, int(cnt), context.temp_allocator)
		for &x in ranges {
			x[0] = _anchor_get(&r)
			x[1] = _anchor_get(&r)
		}
		if !prim.reader_ok(&r) {
			return
		}
		_cursors_local(e, b.object.id, 0, device, actor, seq, ranges)
		return
	}
}

@(private)
_cursors_gone :: proc(e: ^Engine, device: prim.Id) {
	for b in e.buffers {
		i := 0
		changed := false
		for i < len(b.cursors) {
			if b.cursors[i].device == device {
				_cursor_set_free(e, &b.cursors[i])
				ordered_remove(&b.cursors, i)
				changed = true
				continue
			}
			i += 1
		}
		if changed {
			_cursors_emit(e, b)
		}
	}
}

@(private)
_cursors_local :: proc(e: ^Engine, object: prim.Id, from: Buffer_Id, device: prim.Id, actor: prim.Id, seq: u64, ranges: [][2]Anchor) {
	list := make([dynamic]^Buffer, 0, len(e.buffers), context.temp_allocator)
	append(&list, ..e.buffers[:])
	for b in list {
		if b.object.id != object || b.id == from {
			continue
		}
		idx := -1
		for c, i in b.cursors {
			if c.device == device && c.actor == actor {
				idx = i
			}
		}
		if idx >= 0 && b.cursors[idx].seq >= seq && device != e.self {
			continue
		}
		if len(ranges) == 0 {
			if idx >= 0 {
				_cursor_set_free(e, &b.cursors[idx])
				ordered_remove(&b.cursors, idx)
				_cursors_emit(e, b)
			}
			continue
		}
		if idx < 0 {
			append(&b.cursors, Cursor_Set{device = device, actor = actor, ranges = make([dynamic][2]Anchor, e.allocator)})
			idx = len(b.cursors) - 1
		}
		c := &b.cursors[idx]
		c.seq = seq
		clear(&c.ranges)
		append(&c.ranges, ..ranges)
		_cursors_emit(e, b)
	}
}

@(private)
_cursors_emit :: proc(e: ^Engine, b: ^Buffer) {
	if b.cb == nil {
		return
	}
	h, ok := e.handles[b.object.id]
	if !ok || _buffer_view_ready(e, b, h) != .None {
		return
	}
	out := make([]Remote_Cursor, len(b.cursors), context.temp_allocator)
	for &c, i in b.cursors {
		c.missing = false
		rs := make([]Cursor_Range, len(c.ranges), context.temp_allocator)
		for r, j in c.ranges {
			rs[j] = Cursor_Range{_resolve_one(b, r[0]), _resolve_one(b, r[1])}
			if rs[j].anchor < 0 || rs[j].head < 0 {
				c.missing = true
			}
		}
		out[i] = Remote_Cursor{device = c.device, actor = c.actor, ranges = rs}
	}
	ev := Buffer_Event{kind = .Cursors, buffer = b.id, rev = b.rev, ack = b.recv, length = _length(b), cursors = out}
	cb, data := b.cb, b.data
	{
		context = _outer(e)
		cb(data, e, &ev)
	}
}

@(private)
_cursors_after_delta :: proc(e: ^Engine, b: ^Buffer) {
	for c in b.cursors {
		if c.missing {
			_cursors_emit(e, b)
			return
		}
	}
}

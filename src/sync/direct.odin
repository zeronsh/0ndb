package osync

import "../prim"

client_direct :: proc(c: ^Client, to: Device_Id, tag: u64, payload: []u8) -> Error {
	if len(payload) > DIRECT_MAX {
		return .Too_Large
	}
	b := _client_buf(c)
	start := frame_begin(b, .Direct) or_return
	w := prim.writer(b)
	t := to
	prim.write_raw(&w, t[:])
	prim.write_u64le(&w, tag)
	prim.write_raw(&w, payload)
	return frame_end(b, start, &w)
}

@(private)
_client_direct_event :: proc(it: ^Item, handler: Client_Handler, user: rawptr) -> Error {
	if len(it.data) < DIRECT_FIXED {
		return .Protocol
	}
	ev := Event{kind = .Direct if it.frame == .Directed else .Undelivered}
	copy(ev.id[:16], it.data[:16])
	ev.at = i64(prim.get_u64le(it.data[16:]))
	ev.data = it.data[DIRECT_FIXED:]
	return handler(user, &ev)
}

@(private)
_on_direct :: proc(c: ^Conn, rd: ^prim.Reader) {
	if prim.reader_remaining(rd) < DIRECT_FIXED || prim.reader_remaining(rd) - DIRECT_FIXED > DIRECT_MAX {
		_fail(c, .Protocol)
		return
	}
	to: Device_Id
	prim.read_fixed(rd, to[:])
	tag := prim.read_u64le(rd)
	payload := prim.read_raw(rd, prim.reader_remaining(rd))
	sp := c.space
	if sp == nil || !_can(c, .List, {}) {
		_direct_undelivered(c, to, tag)
		return
	}
	for f in sp.feeders {
		if f == c || f.dead || f.closing || !f.presence || f.principal.participant != to {
			continue
		}
		buf, aerr := make([]u8, FRAME_HEADER + DIRECT_FIXED + len(payload), c.relay.allocator)
		if aerr != nil {
			_conn_close(c)
			return
		}
		frame_header(buf, .Directed, DIRECT_FIXED + len(payload))
		from := c.principal.participant
		copy(buf[FRAME_HEADER:], from[:])
		prim.put_u64le(buf[FRAME_HEADER + 16:], tag)
		copy(buf[FRAME_HEADER + DIRECT_FIXED:], payload)
		_push_buf(f, buf)
		_conn_kick(f)
		return
	}
	_direct_undelivered(c, to, tag)
}

@(private)
_direct_undelivered :: proc(c: ^Conn, to: Device_Id, tag: u64) {
	b: [FRAME_HEADER + DIRECT_FIXED]u8
	frame_header(b[:], .Undelivered, DIRECT_FIXED)
	t := to
	copy(b[FRAME_HEADER:], t[:])
	prim.put_u64le(b[FRAME_HEADER + 16:], tag)
	_push_small(c, b[:])
	_conn_kick(c)
}

replicator_direct :: proc(r: ^Replicator, to: Device_Id, tag: u64, payload: []u8) -> Error {
	if r.phase != .Ready {
		return .Busy
	}
	_enter(r)
	defer _leave(r)
	return client_direct(&r.client, to, tag, payload)
}

@(private)
_on_direct_event :: proc(r: ^Replicator, ev: ^Event) {
	d: Device_Id
	copy(d[:], ev.id[:16])
	_emit(r, Repl_Event{kind = .Direct if ev.kind == .Direct else .Undelivered, device = d, length = ev.at, meta = ev.data})
}

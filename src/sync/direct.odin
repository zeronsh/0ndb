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

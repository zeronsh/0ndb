package osync

import "../prim"

client_note :: proc(c: ^Client, id: Stream_Id, length: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Note) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(length, 0)))
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)id)
	return .None
}

client_trim :: proc(c: ^Client, id: Stream_Id, base: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Trim) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(base, 0)))
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)id)
	return .None
}

client_fill_reserve :: proc(c: ^Client, id: Stream_Id, at: i64, n: int) -> (dst: []u8, err: Error) {
	if n <= 0 || n > APPEND_MAX {
		return nil, .Too_Large
	}
	b := _client_buf(c)
	start := len(b)
	if rerr := resize(b, start + FRAME_HEADER + FILL_FIXED + n); rerr != nil {
		resize(b, start)
		return nil, .No_Memory
	}
	frame_header(b[start:], .Fill, FILL_FIXED + n)
	sid := id
	copy(b[start + FRAME_HEADER:], sid[:])
	prim.put_u64le(b[start + FRAME_HEADER + 32:], u64(at))
	return b[start + FRAME_HEADER + FILL_FIXED:], .None
}

client_fill_commit :: proc(c: ^Client, id: Stream_Id, reserved: int, used: int) {
	b := _client_buf(c)
	start := len(b) - reserved - FRAME_HEADER - FILL_FIXED
	if used <= 0 {
		resize(b, start)
		return
	}
	prim.put_u32le(b[start:start + 4], u32(FILL_FIXED + used))
	resize(b, len(b) - (reserved - used))
	_await_add(c, cast([32]u8)id)
}

client_pull :: proc(c: ^Client, holder: Device_Id, tag: u64, id: Stream_Id, from, to: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Pull) or_return
	w := prim.writer(b)
	h := holder
	prim.write_raw(&w, h[:])
	prim.write_u64le(&w, tag)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(from, 0)))
	prim.write_u64le(&w, u64(max(to, from, 0)))
	return frame_end(b, start, &w)
}

client_serve_reserve :: proc(c: ^Client, requester: Device_Id, tag: u64, id: Stream_Id, at: i64, n: int) -> (dst: []u8, err: Error) {
	if n < 0 || n > SERVE_MAX {
		return nil, .Too_Large
	}
	b := _client_buf(c)
	start := len(b)
	if rerr := resize(b, start + FRAME_HEADER + SERVE_FIXED + n); rerr != nil {
		resize(b, start)
		return nil, .No_Memory
	}
	frame_header(b[start:], .Serve, SERVE_FIXED + n)
	q := requester
	copy(b[start + FRAME_HEADER:], q[:])
	prim.put_u64le(b[start + FRAME_HEADER + 16:], tag)
	sid := id
	copy(b[start + FRAME_HEADER + 24:], sid[:])
	prim.put_u64le(b[start + FRAME_HEADER + 56:], u64(at))
	return b[start + FRAME_HEADER + SERVE_FIXED:], .None
}

client_serve_commit :: proc(c: ^Client, reserved: int, used: int, word: u64) {
	b := _client_buf(c)
	start := len(b) - reserved - FRAME_HEADER - SERVE_FIXED
	u := max(used, 0)
	prim.put_u32le(b[start:start + 4], u32(SERVE_FIXED + u))
	prim.put_u64le(b[start + FRAME_HEADER + 64:], word)
	resize(b, len(b) - (reserved - u))
}

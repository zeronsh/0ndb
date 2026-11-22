package osync

import "../prim"

Store_Account :: struct {
	writes:      u64,
	write_bytes: u64,
	pending:     i64,
	day:         i64,
	day_bytes:   u64,
	total_bytes: u64,
}

Storage_Done :: #type proc(ctx: rawptr, result: Error, value: i64)

Relay_Storage :: struct {
	data:            rawptr,
	namespace_open:  proc(data: rawptr, ns: Space_Id) -> (h: rawptr, usage: i64, err: Error),
	namespace_close: proc(data: rawptr, h: rawptr),
	stream_open:     proc(data: rawptr, ns: rawptr, id: Stream_Id, create: bool) -> (s: rawptr, length: i64, err: Error),
	stream_close:    proc(data: rawptr, s: rawptr),
	stream_probe:    proc(data: rawptr, ns: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool, err: Error),
	stream_base:     proc(data: rawptr, s: rawptr) -> i64,
	stream_read:     proc(data: rawptr, s: rawptr, at: i64, dst: []u8) -> (int, Error),
	stream_extent:   proc(data: rawptr, s: rawptr, at: i64, n: i64) -> (fd: prim.Fd, off: i64, len: i64, ok: bool),
	stream_hint:     proc(data: rawptr, ns: rawptr, id: Stream_Id) -> (length: i64, base: i64, exists: bool),
	append_begin:    proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error),
	append_write:    proc(data: rawptr, w: rawptr, bytes: []u8) -> Error,
	append_commit:   proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr),
	append_abort:    proc(data: rawptr, w: rawptr),
	fill_begin:      proc(data: rawptr, s: rawptr, at: i64, total: i64) -> (w: rawptr, err: Error),
	note:            proc(data: rawptr, s: rawptr, length: i64, done: Storage_Done, ctx: rawptr),
	drop:            proc(data: rawptr, ns: rawptr, id: Stream_Id, done: Storage_Done, ctx: rawptr),
	redact:          proc(data: rawptr, s: rawptr, from, to: i64, done: Storage_Done, ctx: rawptr),
	trim:            proc(data: rawptr, s: rawptr, base: i64, done: Storage_Done, ctx: rawptr),
	evict:           proc(data: rawptr, s: rawptr, upto: i64, done: Storage_Done, ctx: rawptr),
	restore:         proc(data: rawptr, s: rawptr, at: i64, bytes: []u8, done: Storage_Done, ctx: rawptr),
	stream_trimmed:  proc(data: rawptr, s: rawptr) -> bool,
	list_begin:      proc(data: rawptr, ns: rawptr, since: i64) -> (it: rawptr, cursor: i64, err: Error),
	list_next:       proc(data: rawptr, it: rawptr) -> (id: Stream_Id, ok: bool),
	list_end:        proc(data: rawptr, it: rawptr),
	put_begin:       proc(data: rawptr, ns: rawptr, key: Object_Key, total: i64) -> (w: rawptr, exists: bool, err: Error),
	put_write:       proc(data: rawptr, w: rawptr, bytes: []u8) -> Error,
	put_commit:      proc(data: rawptr, w: rawptr, done: Storage_Done, ctx: rawptr),
	put_abort:       proc(data: rawptr, w: rawptr),
	object_open:     proc(data: rawptr, ns: rawptr, key: Object_Key) -> (o: rawptr, size: i64, err: Error),
	object_read:     proc(data: rawptr, o: rawptr, at: i64, dst: []u8) -> (int, Error),
	object_extent:   proc(data: rawptr, o: rawptr, at: i64, n: i64) -> (fd: prim.Fd, off: i64, len: i64, ok: bool),
	object_close:    proc(data: rawptr, o: rawptr),
	object_remove:   proc(data: rawptr, ns: rawptr, key: Object_Key, done: Storage_Done, ctx: rawptr),
	account:         proc(data: rawptr, ns: rawptr) -> Store_Account,
	objects:         proc(data: rawptr, ns: rawptr, out: ^[dynamic]Object_Key) -> Error,
	atomic:          bool,
	on_ready:        proc(data: rawptr, cb: proc(ctx: rawptr), ctx: rawptr),
}

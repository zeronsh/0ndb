#+build linux, darwin, windows
package osync

replicator_direct :: proc(r: ^Replicator, to: Device_Id, tag: u64, payload: []u8) -> Error {
	if r.phase != .Ready {
		return .Busy
	}
	_enter(r)
	defer _leave(r)
	client_direct(&r.client, to, tag, payload) or_return
	_repl_flush(r)
	return .None
}

@(private)
_on_direct_event :: proc(r: ^Replicator, ev: ^Event) {
	d: Device_Id
	copy(d[:], ev.id[:16])
	_emit(r, Repl_Event{kind = .Direct if ev.kind == .Direct else .Undelivered, device = d, length = ev.at, meta = ev.data})
}

#+build linux, darwin, windows
package osync

import "../prim"

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
	if u64(ev.at) == SERVABLE_TAG {
		if ev.kind == .Direct {
			_pipe_on_servable(r, d, ev.data)
		}
		return
	}
	_emit(r, Repl_Event{kind = .Direct if ev.kind == .Direct else .Undelivered, device = d, length = ev.at, meta = ev.data})
}

replicator_present :: proc(r: ^Replicator, out: ^[dynamic]Device_Id) {
	for d in prim.sorted_keys(r.presence) {
		if d not_in r.presence {
			continue
		}
		p := r.presence[d]
		if p.up {
			append(out, d)
		}
	}
}

cursor_keys :: proc(sc: ^Scope) -> (key: [32]u8, index: [16]u8) {
	e: [4]u8
	prim.put_u32le(e[:], sc.content.epoch)
	_derive(sc.content.key[:], "0ndb cursors", e[:], key[:])
	index = stream_suffix(sc, "0ndb cursors", 0)
	return
}

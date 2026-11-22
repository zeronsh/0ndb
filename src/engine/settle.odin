package engine

import osync "../sync"

Settle_Result :: enum u8 {
	Settled,
	Relay,
}

Settle_Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, e: ^Engine, res: Settle_Result),
}

settle :: proc(e: ^Engine, done: Settle_Done) {
	context = context_for(e)
	if done.call == nil {
		return
	}
	append(&e.settles, done)
	for _, h in e.handles {
		if h.w_open {
			h.local = true
		}
	}
	_touch(e)
}

settle_pending :: proc(e: ^Engine) -> int {
	return len(e.settles)
}

@(private)
_settle_check :: proc(e: ^Engine) {
	if len(e.settles) == 0 {
		return
	}
	res, ready := _settle_state(e)
	if !ready {
		return
	}
	list := e.settles
	e.settles = make([dynamic]Settle_Done, e.allocator)
	defer delete(list)
	for d in list {
		context = _outer(e)
		d.call(d.data, e, res)
	}
}

@(private)
_settle_state :: proc(e: ^Engine) -> (res: Settle_Result, ready: bool) {
	if e.fatal != .None {
		return .Relay, true
	}
	for _, sp in e.spaces {
		if sp.open && sp.repl_on && (!sp.connected || !osync.replicator_live(&sp.repl)) {
			return .Relay, true
		}
	}
	if len(e.batches) > 0 || len(e.dirty) > 0 || len(e.card_pubs) > 0 || len(e.content.ups) > 0 {
		return .Settled, false
	}
	for _, h in e.handles {
		if h.local {
			return .Settled, false
		}
	}
	for _, sp in e.spaces {
		if !sp.open || !sp.repl_on {
			continue
		}
		pending, broken := osync.replicator_unsettled(&sp.repl)
		if broken {
			return .Relay, true
		}
		if pending {
			return .Settled, false
		}
	}
	return .Settled, true
}

@(private)
_settle_abort :: proc(e: ^Engine) {
	list := e.settles
	e.settles = make([dynamic]Settle_Done, e.allocator)
	defer delete(list)
	for d in list {
		context = _outer(e)
		d.call(d.data, e, .Relay)
	}
}

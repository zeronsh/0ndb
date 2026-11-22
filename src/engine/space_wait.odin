package engine

import "../prim"

@(private)
Space_Wait :: struct {
	space:   prim.Id,
	ready:   Ready,
	cmd:     ^Pending_Cmd,
	catalog: bool,
	woke:    bool,
}

@(private)
_space_settling :: proc(e: ^Engine, sp: ^Space) -> bool {
	if sp.keyless || sp.mem.removed || sp.mem.revoked {
		return false
	}
	if sp.mem.have_naming && (sp.mode != .End_To_End || sp.mem.current >= 0) {
		return false
	}
	return !(sp.mem.caught && _members_ready(sp) && !sp.mem.member)
}

@(private)
_space_settling_id :: proc(e: ^Engine, space: prim.Id) -> (sp: ^Space, settling: bool) {
	x, ok := e.spaces[space]
	if !ok || x.keyless {
		return nil, false
	}
	if !x.open {
		if _, err := _space_open(e, space); err != .None {
			return nil, false
		}
	}
	return x, _space_settling(e, x)
}

@(private)
_space_wait :: proc(e: ^Engine, sp: ^Space, ready: Ready, cmd: ^Pending_Cmd) -> Error {
	if _, err := append(&e.space_waits, Space_Wait{space = sp.id, ready = ready, cmd = cmd}); err != nil {
		return .No_Memory
	}
	return .Pending
}

@(private)
_space_wait_catalog :: proc(e: ^Engine, sp: ^Space, ready: Ready) -> Error {
	if _, err := append(&e.space_waits, Space_Wait{space = sp.id, ready = ready, catalog = true}); err != nil {
		return .No_Memory
	}
	return .Pending
}

@(private)
_space_waits_wake :: proc(e: ^Engine, space: prim.Id, catalog := false) {
	for &w in e.space_waits {
		if w.space == space && w.catalog == catalog {
			w.woke = true
			e.space_woke = true
			_touch(e)
		}
	}
}

@(private)
_space_waits_catalog_changed :: proc(e: ^Engine, space: prim.Id, id: prim.Id) {
	if len(e.space_waits) > 0 && id == _catalog_id(space) {
		_space_waits_wake(e, space, true)
	}
}

@(private)
_space_waits_run :: proc(e: ^Engine) {
	if !e.space_woke {
		return
	}
	e.space_woke = false
	fire := make([dynamic]Space_Wait, context.temp_allocator)
	for i := 0; i < len(e.space_waits); {
		w := e.space_waits[i]
		if w.catalog && !w.woke {
			i += 1
			continue
		}
		if sp, ok := e.spaces[w.space]; ok && !w.catalog && _space_settling(e, sp) {
			i += 1
			continue
		}
		ordered_remove(&e.space_waits, i)
		append(&fire, w)
	}
	for w in fire {
		err := Error.None
		sp, ok := e.spaces[w.space]
		if !ok || sp.mem.removed || sp.mem.revoked || (!w.catalog && !sp.mem.member) {
			err = .Permission
		}
		_space_wait_finish(e, w, err)
	}
}

@(private)
_space_wait_finish :: proc(e: ^Engine, w: Space_Wait, err: Error) {
	if w.cmd != nil {
		if err != .None {
			_cmd_fail(e, w.cmd, err)
		} else {
			_cmd_retry(e, w.cmd, 0)
		}
	} else if w.ready.call != nil {
		context = _outer(e)
		w.ready.call(w.ready.data, e, err)
	}
}

@(private)
_space_waits_fail_all :: proc(e: ^Engine, err: Error) {
	ws := e.space_waits
	e.space_waits = make([dynamic]Space_Wait, e.allocator)
	for w in ws {
		_space_wait_finish(e, w, err)
	}
	delete(ws)
}

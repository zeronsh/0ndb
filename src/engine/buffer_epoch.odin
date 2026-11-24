package engine

import "../fs"
import "../fshist"
import omap "../map"
import "../prim"

@(private)
LIVE_EPOCH_KEY :: [1]u8{'L'}

@(private)
Live_Ids :: struct {
	object: prim.Id,
	actor:  prim.Id,
}

@(private)
_live_epoch_load :: proc(e: ^Engine) -> Error {
	k := LIVE_EPOCH_KEY
	v, found, err := omap.db_get(&e.reg.db, ROOT_SPACES, k[:], context.temp_allocator)
	if err != .None {
		return _oerr(err)
	}
	if !found {
		return .None
	}
	if len(v) != 9 || v[8] > 1 {
		return .Corrupt
	}
	e.live_epoch = prim.get_u64le(v)
	if v[8] != 0 {
		return _live_epoch_next(e)
	}
	return .None
}

@(private)
_live_epoch_next :: proc(e: ^Engine) -> Error {
	if e.live_epoch == max(u64) {
		return .Corrupt
	}
	e.live_epoch += 1
	e.live_armed = false
	clear(&e.live_ids)
	return .None
}

@(private)
_live_arm :: proc(e: ^Engine) -> bool {
	if e.live_armed {
		return true
	}
	if !_live_epoch_put(e, true) {
		return false
	}
	e.live_armed = true
	return true
}

@(private)
_live_disarm :: proc(e: ^Engine) {
	if e.live_armed && e.reg.open && e.fatal == .None && len(e.batches) == 0 && _live_epoch_put(e, false) {
		e.live_armed = false
	}
}

@(private)
_live_epoch_put :: proc(e: ^Engine, armed: bool) -> bool {
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return false
	}
	k := LIVE_EPOCH_KEY
	v: [9]u8
	prim.put_u64le(v[:8], e.live_epoch)
	v[8] = u8(armed)
	if omap.txn_put(t, ROOT_SPACES, k[:], v[:]) != .None {
		omap.txn_abort(t)
		_reg_fail(e, .Io)
		return false
	}
	if _reg_commit(e, t) != .None {
		return false
	}
	e.reg.meta = true
	return true
}

@(private)
_live_actor :: proc(e: ^Engine, base: prim.Id) -> prim.Id {
	if e.live_epoch == 0 && base != e.self {
		return base
	}
	return fshist.epoch_actor(e.self, base, e.live_epoch)
}

@(private)
_buffer_actor :: proc(e: ^Engine, b: ^Buffer, hist: ^fs.History) -> Error {
	actor := _live_actor(e, b.base)
	if sent, ok := e.live_ids[Live_Ids{b.object.id, actor}]; ok && fs.history_next_seq(hist, actor) < sent {
		_live_epoch_next(e) or_return
		actor = _live_actor(e, b.base)
	}
	b.actor = actor
	return .None
}

@(private)
_buffer_actor_register :: proc(e: ^Engine, b: ^Buffer, hist: ^fs.History) -> Error {
	if b.actor == b.base {
		return .None
	}
	return _ferr(fs.history_register_epoch_actor(hist, b.base, e.live_epoch))
}

@(private)
_live_note :: proc(e: ^Engine, b: ^Buffer, next: u64) {
	if e.live_ids == nil {
		e.live_ids = make(map[Live_Ids]u64, e.allocator)
	}
	k := Live_Ids{b.object.id, b.actor}
	e.live_ids[k] = max(e.live_ids[k], next)
}

package engine

import "../convo"
import "../obj"
import "../prim"

Convo_Settings :: convo.Settings

Convo_Status :: struct {
	status:      convo.Status,
	head:        Rid,
	position:    Rid,
	browsing:    bool,
	head_status: convo.Seal_Status,
	queued:      int,
	waiting:     int,
	intents:     int,
	running:     bool,
	awaiting:    bool,
	revive:      bool,
	head_hlc:    prim.Hlc,
}

convo_create :: proc(e: ^Engine, space: prim.Id, settings: Convo_Settings = {}) -> (o: Object, err: Error) {
	o = Object{space, prim.id_new()}
	h := _handle_get(e, o, .Conversation) or_return
	_handle_create_writer(h, settings) or_return
	_catalog_created(e, h, settings.title, settings.parent, settings.workspace, settings.agent)
	return o, .None
}

convo_open :: proc(e: ^Engine, o: Object) -> Error {
	_, err := _handle_get(e, o, .Conversation)
	return err
}

convo_writer :: proc(e: ^Engine, o: Object) -> (w: ^convo.Writer, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_create_writer(h) or_return
	_handle_mark(h)
	return &h.cw, .None
}

convo_view :: proc(e: ^Engine, o: Object) -> (v: ^obj.View, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	return &h.view, .None
}

touched :: proc(e: ^Engine, o: Object) {
	if h, ok := e.handles[o.id]; ok {
		_handle_mark(h)
	}
}

pin :: proc(e: ^Engine, o: Object) {
	if h, ok := e.handles[o.id]; ok {
		h.pins += 1
	}
}

unpin :: proc(e: ^Engine, o: Object) {
	if h, ok := e.handles[o.id]; ok && h.pins > 0 {
		h.pins -= 1
	}
}

convo_status :: proc(e: ^Engine, o: Object, ready: Ready = {}) -> (st: Convo_Status, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None {
		return st, _pending_result(e, h, _oerr(terr), ready)
	}
	if _handle_waiting(h) && ready.call != nil {
		return _status_of(&h.view, &t), _wait(e, h, ready)
	}
	return _status_of(&h.view, &t), .None
}

@(private)
_status_of :: proc(v: ^obj.View, t: ^convo.Tail) -> Convo_Status {
	return Convo_Status {
		status = t.status,
		head = convo.tail_head(v, t),
		position = convo.tail_position(v, t),
		browsing = t.browsing,
		head_status = t.head_status,
		queued = t.queued,
		waiting = t.waiting,
		intents = t.intents,
		running = t.running,
		awaiting = t.awaiting,
		revive = t.revive,
		head_hlc = t.head_hlc,
	}
}

convo_page :: proc(e: ^Engine, o: Object, from: convo.Position = {}, limit := 32, allocator := context.allocator, ready: Ready = {}) -> (p: convo.Page, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	if _handle_waiting(h) && ready.call != nil && len(h.view.segs) == 0 {
		return p, _wait(e, h, ready)
	}
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None && terr != .Missing {
		return p, _oerr(terr)
	}
	if terr == .Missing {
		return p, _pending_result(e, h, .Missing, ready)
	}
	pg, perr := convo.page(&h.view, &t, from, limit, allocator)
	if perr != .None {
		return pg, _pending_result(e, h, _oerr(perr), ready)
	}
	if _handle_waiting(h) && ready.call != nil {
		return pg, _wait(e, h, ready)
	}
	return pg, .None
}

convo_message :: proc(e: ^Engine, o: Object, pos: convo.Position, allocator := context.allocator, ready: Ready = {}) -> (m: convo.Message, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None {
		return m, _pending_result(e, h, _oerr(terr), ready)
	}
	msg, merr := convo.message(&h.view, &t, pos, allocator)
	if merr != .None {
		return msg, _pending_result(e, h, _oerr(merr), ready)
	}
	return msg, .None
}

convo_siblings :: proc(e: ^Engine, o: Object, msg: Rid, allocator := context.allocator, ready: Ready = {}) -> (list: []Rid, at: int, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None {
		return nil, 0, _pending_result(e, h, _oerr(terr), ready)
	}
	l, i, serr := convo.siblings(&h.view, &t, msg, allocator)
	if serr != .None {
		return nil, 0, _pending_result(e, h, _oerr(serr), ready)
	}
	return l, i, .None
}

convo_intents :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (items: []convo.Intent, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	it, ierr := convo.intents(&h.view, allocator)
	if ierr != .None {
		return nil, _pending_result(e, h, _oerr(ierr), ready)
	}
	return it, .None
}

convo_mounts :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (out: []convo.Mount_Entry, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	m, merr := convo.mounts(&h.view, allocator)
	if merr != .None {
		return nil, _pending_result(e, h, _oerr(merr), ready)
	}
	return m, .None
}

convo_files_at :: proc(e: ^Engine, o: Object, msg: Rid, allocator := context.allocator, ready: Ready = {}) -> (out: []convo.File_Delta, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	f, ferr := convo.files_at(&h.view, msg, allocator)
	if ferr != .None {
		return nil, _pending_result(e, h, _oerr(ferr), ready)
	}
	return f, .None
}

convo_compactions :: proc(e: ^Engine, o: Object, floor: prim.Hlc = 0, allocator := context.allocator, ready: Ready = {}) -> (out: []convo.Compaction, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	c, cerr := convo.compactions(&h.view, floor, allocator)
	if cerr != .None {
		return nil, _pending_result(e, h, _oerr(cerr), ready)
	}
	return c, .None
}

convo_unsealed :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (out: []convo.Unsealed, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	u, uerr := convo.unsealed(&h.view, allocator)
	if uerr != .None {
		return nil, _pending_result(e, h, _oerr(uerr), ready)
	}
	return u, .None
}

convo_settings :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (s: Convo_Settings, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	best := -1
	best_hlc := max(prim.Hlc)
	for i in 0 ..< len(h.view.segs) {
		if obj.end(&h.view, i) == 0 {
			continue
		}
		body, _, gerr := obj.get(&h.view, i, 0)
		if gerr != .None {
			if gerr == .Missing {
				return s, _pending_result(e, h, .Missing, ready)
			}
			continue
		}
		env, derr := obj.decode_envelope(body, 0)
		if derr != .None {
			continue
		}
		head, herr := obj.decode_head(&env)
		if herr != .None || len(head.settings) == 0 {
			continue
		}
		if head.created < best_hlc {
			best_hlc = head.created
			best = i
		}
	}
	if best < 0 {
		return s, .None
	}
	body, _, _ := obj.get(&h.view, best, 0)
	env, _ := obj.decode_envelope(body, 0)
	head, _ := obj.decode_head(&env)
	raw, rerr := convo.decode_settings(head.settings)
	if rerr != .None {
		return s, _oerr(rerr)
	}
	s.title = _clone(raw.title, allocator) or_return
	s.agent = raw.agent
	s.workspace = raw.workspace
	s.parent = raw.parent
	s.provider = _clone(raw.provider, allocator) or_return
	s.model = _clone(raw.model, allocator) or_return
	return s, .None
}

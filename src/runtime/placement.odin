package rt

import "../convo"
import eng "../engine"
import "../obj"
import "../prim"

@(private)
_evaluate_sender :: proc(r: ^Runtime, o: Object) {
	c, found, cerr := eng.catalog_get(r.e, o, context.temp_allocator)
	if cerr != .None || !found || c.kind != .Conversation {
		return
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr == .Missing {
		eng.convo_status(r.e, o, _wait_ready(r, o))
		return
	}
	if terr != .None {
		return
	}
	items, ierr := convo.intents(v, context.temp_allocator)
	if ierr == .Missing {
		eng.convo_intents(r.e, o, context.temp_allocator, _wait_ready(r, o))
		return
	}
	if ierr != .None {
		return
	}
	if !runners_loaded(r, o, true) {
		return
	}
	waiting: Rid
	defer _claim_prune(r, o, waiting)
	if t.running {
		if _, live := _open_live(r, o, v, &t); live {
			return
		}
	}
	if task_cancelled(r, o) {
		return
	}
	if !t.running {
		for &it in items {
			if it.kind != .Queue && it.kind != .Steer {
				continue
			}
			if it.by == r.self && prim.id_is_zero(place_intent(r, o, &it)) {
				_placement_waiting(r, o, it.item, _intent_provider(r, o), {})
			}
			return
		}
	}
	msg, um, dead, ok := _unanswered(r, o, v, &t)
	if !ok {
		if !t.running && t.queued == 0 {
			_pending_clear(r, o)
		}
		return
	}
	if um.author != r.self {
		return
	}
	waiting = msg
	x, assignee := _place_message(r, o, v, &t, &um, dead)
	if prim.id_is_zero(x) {
		return
	}
	a, _ := agent_resolve(r, o, um.provider, um.model, context.temp_allocator)
	provider := placement_provider(&a)
	if x != assignee {
		w := _convo_w(r, o)
		if w == nil {
			return
		}
		if _, aerr := convo.writer_assign(w, msg, x); aerr != .None {
			return
		}
		eng.touched(r.e, o)
		_claim_overdue(r, o, msg, x, provider)
	}
	_promote_for_run(r, o, msg, x)
	if _pending_put(r, o, Pending_Entry{msg = msg, provider = provider, since_ms = wall_ms(r), runner = x, assigned = true}) {
		_placement_hook(r, o, Placement_Info{state = .Assigned, msg = msg, runner = x, provider = provider, since_ms = wall_ms(r)})
	}
}

@(private)
_unanswered :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail) -> (msg: Rid, um: convo.Message, dead: prim.Id, ok: bool) {
	head, head_err := convo.tail_head(v, t)
	if head_err != .None || obj.rid_none(head) {
		return
	}
	hm, herr := convo.message(v, t, convo.Position{msg = head}, context.temp_allocator)
	if herr != .None {
		return
	}
	if hm.role == .User || hm.role == .System {
		if hm.open || hm.status != .Done {
			return
		}
		return head, hm, {}, true
	}
	if !hm.open || obj.rid_none(hm.parent) || hm.runner == r.self {
		return
	}
	reassigned := false
	if as, aerr := convo.assignee(v, t, hm.parent); aerr == .None && !prim.id_is_zero(as) && as != hm.runner {
		reassigned = true
	}
	if !reassigned && !runner_gone(r, o.space, hm.runner) {
		return
	}
	pm, perr := convo.message(v, t, convo.Position{msg = hm.parent}, context.temp_allocator)
	if perr != .None {
		return
	}
	return hm.parent, pm, hm.runner, true
}

placement_status :: proc(r: ^Runtime, o: Object) -> (info: Placement_Info, err: Error) {
	context = eng.context_for(r.e)
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return info, _eerr(verr)
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return info, .Pending if terr == .Missing else .Engine
	}
	if !runners_loaded(r, o, false) {
		return info, .Pending
	}
	if t.running {
		if runner, live := _open_live(r, o, v, &t); live {
			info.state = .Running
			info.runner = runner
			return info, .None
		}
	}
	if task_cancelled(r, o) {
		return info, .None
	}
	pend, has := pending_get(r, o)
	items, ierr := convo.intents(v, context.temp_allocator)
	if ierr == .None {
		for &it in items {
			if it.kind != .Queue && it.kind != .Steer {
				continue
			}
			info.msg = it.item
			info.provider = _intent_provider(r, o)
			info.runner = place_intent(r, o, &it)
			info.state = .Waiting_Runner if prim.id_is_zero(info.runner) else .Assigned
			if has && pend.msg == it.item {
				info.since_ms = pend.since_ms
			}
			return info, .None
		}
	}
	head, hm, dead, uok := _unanswered(r, o, v, &t)
	if !uok {
		return info, .None
	}
	a, _ := agent_resolve(r, o, hm.provider, hm.model, context.temp_allocator)
	info.msg = head
	info.provider = placement_provider(&a)
	exclude := dead
	if as, aerr := convo.assignee(v, &t, head); aerr == .None && !prim.id_is_zero(as) && as != dead {
		overdue := !runner_live(r, o.space, as, info.provider)
		for w in r.leases {
			if w.claim && w.object == o && w.msg == head && w.runner == as && wall_ms(r) >= w.seen + r.cfg.claim_wait_ms {
				overdue = true
			}
		}
		if !overdue {
			info.state = .Assigned
			info.runner = as
			return info, .None
		}
		exclude = as
	}
	p := Placement {
		kind     = .Message,
		object   = o,
		msg      = head,
		sender   = hm.author,
		agent    = a.object.id,
		provider = info.provider,
		policy   = a.policy,
		exclude  = exclude,
	}
	info.runner = place(r, &p)
	if prim.id_is_zero(info.runner) {
		info.state = .Waiting_Runner
		info.runner = exclude
		if has && pend.msg == head {
			info.since_ms = pend.since_ms
		}
		return info, .None
	}
	info.state = .Assigned
	return info, .None
}

@(private)
_open_live :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail) -> (runner: prim.Id, live: bool) {
	list, err := convo.unsealed(v, context.temp_allocator)
	if err != .None {
		return {}, true
	}
	for u in list {
		if u.state != .Running {
			continue
		}
		m, merr := convo.message(v, t, convo.Position{msg = u.msg}, context.temp_allocator)
		if merr != .None {
			return u.msg.seg, true
		}
		if as, aerr := convo.assignee(v, t, m.parent); aerr == .None && !prim.id_is_zero(as) && as != m.runner {
			continue
		}
		if m.runner != r.self && runner_gone(r, o.space, m.runner) {
			continue
		}
		if m.runner == r.self && run_find(r, o) == nil {
			continue
		}
		return m.runner, true
	}
	return {}, false
}

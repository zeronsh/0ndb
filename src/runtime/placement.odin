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
	waiting: Rid
	defer _claim_prune(r, o, waiting)
	if t.running {
		_pending_settled(r, o, v, &t, {})
		return
	}
	if task_cancelled(r, o) {
		return
	}
	for &it in items {
		if it.kind != .Queue && it.kind != .Steer {
			continue
		}
		if it.by != r.self {
			return
		}
		if prim.id_is_zero(place_intent(r, o, &it)) {
			_placement_waiting(r, o, it.item, _intent_provider(r, o), {})
		} else {
			_pending_settled(r, o, v, &t, {})
		}
		return
	}
	head := convo.tail_head(v, &t)
	if obj.rid_none(head) {
		return
	}
	hm, herr := convo.message(v, &t, convo.Position{msg = head}, context.temp_allocator)
	if herr != .None {
		return
	}
	if (hm.role != .User && hm.role != .System) || hm.open || hm.status != .Done {
		_pending_settled(r, o, v, &t, {})
		return
	}
	if hm.author != r.self {
		return
	}
	waiting = head
	x, assignee := _place_message(r, o, v, &t, &hm)
	if prim.id_is_zero(x) {
		return
	}
	a, _ := agent_resolve(r, o, hm.provider, hm.model, context.temp_allocator)
	provider := placement_provider(&a)
	if x != assignee {
		w := _convo_w(r, o)
		if w == nil {
			return
		}
		if _, aerr := convo.writer_assign(w, head, x); aerr != .None {
			return
		}
		eng.touched(r.e, o)
		_claim_overdue(r, o, head, x, provider)
	}
	if _pending_put(r, o, Pending_Entry{msg = head, provider = provider, since_ms = wall_ms(r), runner = x, assigned = true}) {
		_placement_hook(r, o, Placement_Info{state = .Assigned, msg = head, runner = x, provider = provider, since_ms = wall_ms(r)})
	}
}

@(private)
_pending_settled :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail, keep: Rid) {
	p, ok := pending_get(r, o)
	if !ok || p.msg == keep {
		return
	}
	if p.msg.seg != r.self {
		if _, merr := convo.message(v, t, convo.Position{msg = p.msg}, context.temp_allocator); merr != .None {
			if s := obj.view_find(v, p.msg.seg); s < 0 {
				return
			}
		}
	}
	_pending_clear(r, o)
}

placement_status :: proc(r: ^Runtime, o: Object) -> (info: Placement_Info, err: Error) {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return info, _eerr(verr)
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return info, .Pending if terr == .Missing else .Engine
	}
	if t.running {
		info.state = .Running
		return info, .None
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
	head := convo.tail_head(v, &t)
	if obj.rid_none(head) {
		return info, .None
	}
	hm, herr := convo.message(v, &t, convo.Position{msg = head}, context.temp_allocator)
	if herr != .None {
		return info, .Pending if herr == .Missing else .Engine
	}
	if (hm.role != .User && hm.role != .System) || hm.open || hm.status != .Done {
		return info, .None
	}
	a, _ := agent_resolve(r, o, hm.provider, hm.model, context.temp_allocator)
	info.msg = head
	info.provider = placement_provider(&a)
	exclude: prim.Id
	if as, aerr := convo.assignee(v, &t, head); aerr == .None && !prim.id_is_zero(as) {
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

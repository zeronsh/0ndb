package rt

import "core:slice"
import "../agent"
import "../convo"
import eng "../engine"
import "../fs"
import omap "../map"
import "../obj"
import "../odb"
import "../prim"

REVIVE_PROMPT :: "Your previous turn was cut off by a restart of the machine running you. Continue the task from exactly where you left off; do not repeat work that is already done."

evaluate :: proc(r: ^Runtime, o: Object) {
	context = eng.context_for(r.e)
	if r.closing {
		return
	}
	if !r.cfg.runner {
		_evaluate_sender(r, o)
		return
	}
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
	if _follow_stale(r, o, v, &c) {
		return
	}
	if r.quiesce.on && run_find(r, o) == nil {
		_quiesce_hold(r, o)
		return
	}
	if _revive_pending(r, o, v) {
		return
	}
	if !runners_loaded(r, o, true) {
		return
	}
	_lease_prune(r, o, v)
	items, ierr := convo.intents(v, context.temp_allocator)
	if ierr == .Missing {
		eng.convo_intents(r.e, o, context.temp_allocator, _wait_ready(r, o))
		return
	}
	if ierr != .None {
		return
	}
	if run := run_find(r, o); run != nil {
		_claim_prune(r, o, {})
		_run_intents(run, v, &t, items)
		return
	}
	cancelled := task_cancelled(r, o)
	head, head_err := convo.tail_head(v, &t)
	if head_err != .None {
		eng.convo_status(r.e, o, _wait_ready(r, o))
		return
	}
	busy := t.running && _running_live(r, o, v, &t)
	waiting_msg: Rid
	defer _claim_prune(r, o, waiting_msg)
	if !busy && !cancelled && !obj.rid_none(head) {
		if hm, herr := convo.message(v, &t, convo.Position{msg = head}, context.temp_allocator); herr == .None && (hm.role == .User || hm.role == .System) && !hm.open && hm.status == .Done {
			waiting_msg = head
			if _placed_here(r, o, v, &t, &hm) {
				start_run(r, o, head)
			}
			return
		}
	}
	for &it in items {
		#partial switch it.kind {
		case .Queue, .Steer:
			if cancelled {
				if place_intent(r, o, &it) == r.self {
					if w := _convo_w(r, o); w != nil {
						convo.writer_unqueue(w, it.item, .Cancelled)
					}
				}
				continue
			}
			if busy {
				break
			}
			x := place_intent(r, o, &it)
			if prim.id_is_zero(x) {
				_placement_waiting(r, o, it.item, _intent_provider(r, o), {})
			}
			if x != r.self {
				return
			}
			_start_from_intent(r, o, head, &it)
			return
		case .Interrupt, .Answer:
			if busy {
				continue
			}
			if place_intent(r, o, &it) == r.self {
				if w := _convo_w(r, o); w != nil {
					convo.writer_unqueue(w, it.item, .Rejected)
				}
			}
		}
	}
	if obj.rid_none(head) || cancelled {
		return
	}
	hm, herr := convo.message(v, &t, convo.Position{msg = head}, context.temp_allocator)
	if herr != .None {
		return
	}
	switch hm.role {
	case .User, .System:
		if hm.open || hm.status != .Done || busy {
			return
		}
		waiting_msg = head
		if _placed_here(r, o, v, &t, &hm) {
			start_run(r, o, head)
		}
	case .Assistant, .Tool:
		if !hm.open || hm.runner == r.self || obj.rid_none(hm.parent) {
			return
		}
		assignee, aerr := convo.assignee(v, &t, hm.parent)
		if aerr == .None && assignee == r.self {
			start_run(r, o, hm.parent)
			return
		}
		expires, live := _lease_live(r, o, v, &hm)
		if live {
			lease_watch(r, o, expires)
			return
		}
		a, ok := agent_resolve(r, o, hm.provider, hm.model, context.temp_allocator)
		if !ok {
			return
		}
		um, uerr := convo.message(v, &t, convo.Position{msg = hm.parent}, context.temp_allocator)
		if uerr != .None {
			return
		}
		p := Placement {
			kind     = .Takeover,
			object   = o,
			msg      = hm.parent,
			sender   = um.author,
			agent    = a.object.id,
			provider = placement_provider(&a),
			policy   = a.policy,
			exclude  = hm.runner,
		}
		x := place(r, &p)
		if prim.id_is_zero(x) {
			_placement_waiting(r, o, hm.parent, p.provider, hm.runner)
		}
		if x == r.self && start_run(r, o, hm.parent) == .None {
			r.stats.takeovers += 1
		}
	}
}

@(private)
_claim_lease :: proc(v: ^obj.View, claim: Rid) -> (lease_ms: i64, stamp: prim.Hlc, ok: bool) {
	if obj.rid_none(claim) {
		return 0, 0, false
	}
	x, xerr := obj.vref(v, claim)
	if xerr != .None {
		return 0, 0, false
	}
	body, _, gerr := obj.get(v, x.seg, x.off)
	if gerr != .None || obj.is_redacted(body) {
		return 0, 0, false
	}
	rec, derr := convo.decode_record(body, x.off, context.temp_allocator)
	if derr != .None {
		return 0, 0, false
	}
	c, cok := rec.body.(convo.Claim)
	if !cok {
		return 0, 0, false
	}
	return i64(min(c.lease, u64(max(i64) / 4))), rec.stamp, true
}

@(private)
_lease_live :: proc(r: ^Runtime, o: Object, v: ^obj.View, m: ^convo.Message) -> (expires_ms: i64, live: bool) {
	if m.runner == r.self {
		return 0, true
	}
	if runner_gone(r, o.space, m.runner) {
		return 0, false
	}
	lease, stamp, ok := _claim_lease(v, m.claim)
	if !ok || lease <= 0 {
		return 0, true
	}
	last := stamp
	if s := obj.view_find(v, m.id.seg); s >= 0 {
		if act, aerr := convo.segment_activity(v, s); aerr == .None && act > last {
			last = act
		}
	}
	now := wall_ms(r)
	seen := now
	found := false
	for &w in r.leases {
		if !w.claim && w.object == o && w.msg == m.id {
			found = true
			if w.activity != last {
				w.activity = last
				w.seen = now
			}
			seen = w.seen
		}
	}
	if !found {
		w := Lease_Watch{object = o, msg = m.id, activity = last, seen = now}
		watched := false
		for x in r.leases {
			watched ||= x.object == o && x.sub != 0
		}
		if !watched {
			if sid, serr := eng.subscribe(r.e, o, .Conversation, _on_watch_convo, r); serr == .None {
				w.sub = sid
			}
		}
		append(&r.leases, w)
	}
	expires_ms = max(prim.hlc_ms(last), seen) + lease
	return expires_ms, now < expires_ms
}

@(private)
_running_live :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail) -> bool {
	list, err := convo.unsealed(v, context.temp_allocator)
	if err != .None {
		return true
	}
	any := false
	for u in list {
		if u.state != .Running {
			continue
		}
		if u.msg.seg == r.self {
			return true
		}
		m, merr := convo.message(v, t, convo.Position{msg = u.msg}, context.temp_allocator)
		if merr != .None {
			return true
		}
		assignee, aerr := convo.assignee(v, t, m.parent)
		if aerr == .None && !prim.id_is_zero(assignee) && assignee != m.runner {
			continue
		}
		expires, live := _lease_live(r, o, v, &m)
		if live {
			lease_watch(r, o, expires)
			any = true
		}
	}
	return any
}

lease_watch :: proc(r: ^Runtime, o: Object, at_ms: i64) {
	for &w in r.leases {
		if !w.claim && w.object == o {
			w.at = at_ms if w.at == 0 else min(w.at, at_ms)
		}
	}
	_lease_arm(r)
}

@(private)
_lease_arm :: proc(r: ^Runtime) {
	l := eng.loop(r.e)
	at: i64 = 0
	for w in r.leases {
		if w.at > 0 && (at == 0 || w.at < at) {
			at = w.at
		}
	}
	if at == r.lease_at && (at == 0 || prim.timer_pending(l, r.lease_timer)) {
		return
	}
	if r.lease_timer != 0 {
		prim.timer_cancel(l, r.lease_timer)
		r.lease_timer = 0
	}
	r.lease_at = at
	if at != 0 {
		r.lease_timer = prim.timer(l, max(at - wall_ms(r), 0) + 1, r, _on_lease_timer)
	}
}

@(private)
_on_lease_timer :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	r.lease_timer = 0
	r.lease_at = 0
	now := wall_ms(r)
	for &w in r.leases {
		if w.at > 0 && w.at <= now {
			w.at = 0
			_queue_eval(r, w.object)
		}
	}
	_lease_arm(r)
}

@(private)
_on_renew :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Run)(data).r.e)
	run := (^Run)(data)
	r := run.r
	run.renew_timer = 0
	if run.state == .Finished || run.superseded {
		return
	}
	if w := _writer(run); w != nil {
		if _, err := convo.writer_claim(w, run.user, r.cfg.lease_ms, run.lines); err == .Not_Assigned {
			run.superseded = true
			run_notice(run, "this turn was reassigned to another runner")
			run_interrupt(run)
			return
		}
		eng.touched(r.e, run.o)
	}
	run.renew_timer = prim.timer(l, i64(r.cfg.lease_ms / 3), run, _on_renew)
}

place_intent :: proc(r: ^Runtime, o: Object, it: ^convo.Intent) -> prim.Id {
	a, _ := agent_resolve(r, o, "", "", context.temp_allocator)
	p := Placement {
		kind     = .Intent,
		object   = o,
		msg      = it.item,
		sender   = it.by,
		agent    = a.object.id,
		provider = placement_provider(&a),
		policy   = a.policy,
	}
	return place(r, &p)
}

@(private)
_intent_provider :: proc(r: ^Runtime, o: Object) -> string {
	a, ok := agent_resolve(r, o, "", "", context.temp_allocator)
	if !ok {
		return ""
	}
	return placement_provider(&a)
}

@(private)
_placed_here :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail, m: ^convo.Message) -> bool {
	x, _ := _place_message(r, o, v, t, m)
	return x == r.self
}

@(private)
_place_message :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail, m: ^convo.Message, dead: prim.Id = {}) -> (runner: prim.Id, assignee: prim.Id) {
	a, _ := agent_resolve(r, o, m.provider, m.model, context.temp_allocator)
	provider := placement_provider(&a)
	exclude := dead
	if as, aerr := convo.assignee(v, t, m.id); aerr == .None && !prim.id_is_zero(as) {
		assignee = as
		if as == r.self && r.cfg.runner && as != dead {
			return as, as
		}
		if as != dead && !_claim_overdue(r, o, m.id, as, provider) {
			return as, as
		}
		exclude = as
	}
	p := Placement {
		kind     = .Message,
		object   = o,
		msg      = m.id,
		sender   = m.author,
		agent    = a.object.id,
		provider = provider,
		policy   = a.policy,
		exclude  = exclude,
	}
	runner = place(r, &p)
	if prim.id_is_zero(runner) {
		_placement_waiting(r, o, m.id, provider, exclude)
	}
	return runner, assignee
}

@(private)
_claim_overdue :: proc(r: ^Runtime, o: Object, msg: Rid, runner: prim.Id, provider: string) -> bool {
	if !runner_live(r, o.space, runner, provider) {
		return true
	}
	now := wall_ms(r)
	for &w in r.leases {
		if w.claim && w.object == o && w.msg == msg {
			if w.runner != runner {
				w.runner = runner
				w.seen = now
				w.at = 0
			}
			due := w.seen + r.cfg.claim_wait_ms
			if now >= due {
				return true
			}
			if w.at == 0 || w.at > due {
				w.at = due
				_lease_arm(r)
			}
			return false
		}
	}
	due := now + r.cfg.claim_wait_ms
	append(&r.leases, Lease_Watch{object = o, msg = msg, runner = runner, seen = now, at = due, claim = true})
	_lease_arm(r)
	return false
}

@(private)
_claim_prune :: proc(r: ^Runtime, o: Object, keep: Rid) {
	i := 0
	changed := false
	for i < len(r.leases) {
		w := r.leases[i]
		if w.claim && w.object == o && (obj.rid_none(keep) || w.msg != keep) {
			unordered_remove(&r.leases, i)
			changed = true
			continue
		}
		i += 1
	}
	if changed {
		_lease_arm(r)
	}
}

@(private)
_placement_waiting :: proc(r: ^Runtime, o: Object, msg: Rid, provider: string, waiting_on: prim.Id) {
	if _pending_put(r, o, Pending_Entry{msg = msg, provider = provider, since_ms = wall_ms(r), runner = waiting_on}) {
		_placement_hook(r, o, Placement_Info{state = .Waiting_Runner, msg = msg, provider = provider, runner = waiting_on, since_ms = wall_ms(r)})
	}
}

@(private)
_placement_hook :: proc(r: ^Runtime, o: Object, info: Placement_Info) {
	if r.cfg.hooks.placement != nil {
		r.cfg.hooks.placement(r.cfg.hooks.data, r, o, info)
	}
}

convo_runners :: proc(r: ^Runtime, o: Object, from: Rid) -> []prim.Id {
	out := make([dynamic]prim.Id, context.temp_allocator)
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return out[:]
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return out[:]
	}
	cur := from
	if _, merr := convo.message(v, &t, convo.Position{msg = cur}, context.temp_allocator); obj.rid_none(cur) || merr != .None {
		cur, _ = convo.tail_head(v, &t)
	}
	for _ in 0 ..< 64 {
		if obj.rid_none(cur) {
			break
		}
		m, merr := convo.message(v, &t, convo.Position{msg = cur}, context.temp_allocator)
		if merr != .None {
			break
		}
		if !prim.id_is_zero(m.runner) {
			append(&out, m.runner)
			break
		}
		cur = m.parent
	}
	ms, mserr := convo.mounts(v, context.temp_allocator)
	if mserr == .None {
		for {
			best := -1
			for m, i in ms {
				if m.removed || len(m.path) == 0 || prim.id_is_zero(m.by) || slice.contains(out[:], m.by) {
					continue
				}
				if best < 0 || m.stamp > ms[best].stamp || (m.stamp == ms[best].stamp && obj.id_less(m.by, ms[best].by)) {
					best = i
				}
			}
			if best < 0 {
				break
			}
			append(&out, ms[best].by)
		}
	}
	return out[:]
}

@(private)
_convo_w :: proc(r: ^Runtime, o: Object) -> ^convo.Writer {
	w, err := eng.convo_writer(r.e, o)
	if err != .None {
		return nil
	}
	return w
}

@(private)
_start_from_intent :: proc(r: ^Runtime, o: Object, head: Rid, it: ^convo.Intent) {
	w := _convo_w(r, o)
	if w == nil {
		return
	}
	native := ""
	if a, ok := agent_resolve(r, o, "", "", context.temp_allocator); ok && a.kind == .Harness {
		native = a.provider
	}
	msg, merr := convo.writer_message(w, convo.Msg_Spec{role = .User, author = it.by, parent = head, runner = r.self, intent = it.item, native = native, files = current_files(r, o, head)})
	if merr != .None {
		return
	}
	if len(it.text) > 0 {
		convo.writer_block(w, msg, .Text, transmute([]u8)it.text)
	}
	for a in it.attachments {
		if len(a.oid) == 20 || len(a.oid) == 32 {
			convo.writer_block_ref(w, msg, .File, convo.Blob{oid = a.oid, size = a.size}, a.mime, a.name)
		}
	}
	convo.writer_seal(w, msg, .Done)
	convo.writer_unqueue(w, it.item, .Started, msg)
	eng.touched(r.e, o)
	start_run(r, o, msg)
}

start_run :: proc(r: ^Runtime, o: Object, user: Rid) -> Error {
	if run_find(r, o) != nil {
		return .Busy
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return .Engine
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return .Pending
	}
	um, merr := convo.message(v, &t, convo.Position{msg = user}, context.temp_allocator)
	if merr != .None {
		return .Pending
	}
	run := _run_new(r, o)
	if run == nil {
		return .Limit
	}
	a, ok := agent_resolve(r, o, um.provider, um.model, run.alloc)
	if !ok {
		_run_free(run)
		return .Not_Found
	}
	run.ai = a
	run.user = user
	run.parent = um.parent
	_user_content(run, &um)
	exhausted := false
	if t, tok := task_get(r, o); tok && t.budget != {} {
		used := _used(r, o)
		if t.budget.tokens > 0 && used.input + used.output + used.cache_read + used.cache_write >= t.budget.tokens {
			exhausted = true
		}
		run.ai.budget = budget_min(run.ai.budget, _remaining(r, o, t.budget))
	}
	w := _convo_w(r, o)
	if w == nil {
		_run_free(run)
		return .Engine
	}
	assignee, _ := convo.assignee(v, &t, user)
	if assignee != r.self {
		if _, aerr := convo.writer_assign(w, user, r.self); aerr != .None {
			_run_free(run)
			return .Engine
		}
	}
	lines := _new_lines(r, o, run)
	claim, cerr := convo.writer_claim(w, user, r.cfg.lease_ms, lines)
	if cerr != .None {
		_run_free(run)
		return .Not_Assigned if cerr == .Not_Assigned else .Engine
	}
	run.claim = claim
	_pending_put(r, o, Pending_Entry{msg = user, provider = placement_provider(&run.ai), since_ms = wall_ms(r), runner = r.self, assigned = true})
	_claim_prune(r, o, {})
	if exhausted {
		eng.pin(r.e, o)
		run.pinned = true
		run.lines = lines
		if _ensure_reply(run, nil) != .None {
			_run_free(run)
			return .Engine
		}
		run.state = .Running
		run_error(run, "the task's budget is exhausted")
		run_finish(run, .Failed)
		return .Budget
	}
	return _run_begin(run, lines)
}

@(private)
_used :: proc(r: ^Runtime, o: Object) -> convo.Usage {
	c, found, err := eng.catalog_get(r.e, o, context.temp_allocator)
	if err != .None || !found || len(c.usage) == 0 {
		return {}
	}
	rd := prim.reader(c.usage)
	return convo.decode_usage(&rd)
}

@(private)
_run_begin :: proc(run: ^Run, lines: []convo.Line) -> Error {
	r := run.r
	o := run.o
	eng.pin(r.e, o)
	run.pinned = true
	if sid, serr := eng.subscribe(r.e, o, .Conversation, _on_run_convo, run); serr == .None {
		run.sub = sid
	}
	r.stats.runs_started += 1
	run.lines = lines
	run.renew_timer = prim.timer(eng.loop(r.e), i64(r.cfg.lease_ms / 3), run, _on_renew)
	if run.ai.budget.seconds > 0 {
		run.budget_timer = prim.timer(eng.loop(r.e), run.ai.budget.seconds * 1000, run, _on_budget_timer)
	}
	if len(lines) > 0 {
		ws, werr := worktree_open(r, o, run, lines)
		if werr != .None {
			_ensure_reply(run, nil)
			run_error(run, "the conversation's file trees could not be materialized")
			run.state = .Running
			run_finish(run, .Failed)
			return werr
		}
		run.ws = ws
		worktree_fence(ws, 0, _begin_fenced)
		return .None
	}
	if err := _ensure_reply(run, nil); err != .None {
		_run_free(run)
		return err
	}
	return _run_setup(run)
}

@(private)
_ensure_reply :: proc(run: ^Run, files: []convo.File_Delta) -> Error {
	if !obj.rid_none(run.reply) {
		return .None
	}
	r := run.r
	o := run.o
	w := _convo_w(r, o)
	if w == nil {
		return .Engine
	}
	a := &run.ai
	spec := convo.Msg_Spec{role = .Assistant, parent = run.user, runner = r.self, provider = a.provider, model = a.model, claim = run.claim.off, native = a.provider if a.kind == .Harness else "", files = files}
	reply: Rid
	err: convo.Error
	if !obj.rid_none(run.revive_of) {
		spec.parent = {}
		reply, err = convo.writer_revive(w, run.revive_of, spec)
	} else {
		reply, err = convo.writer_message(w, spec)
	}
	if err != .None {
		return .Engine
	}
	run.reply = reply
	run_raw_owner(run)
	state_run_put(r, Run_Entry{object = o, user = run.user, reply = run.reply, claim = run.claim, agent = run.ai.object.id, lines = lines_encode(run.lines)})
	eng.touched(r.e, o)
	eng.catalog_usage(r.e, o, {})
	return .None
}

@(private)
_start_files :: proc(run: ^Run) -> []convo.File_Delta {
	ws := run.ws
	if ws == nil {
		return nil
	}
	cur := make(map[string]convo.File_Delta, context.temp_allocator)
	for mb in ws.members {
		if mb.m == nil {
			continue
		}
		cur[mb.name] = convo.File_Delta{mount = mb.name, tree = mb.tree, line = mb.conv_line, version = version_encode(mb.start, mb.branch, mb.commit)}
	}
	return files_delta(run.r, run.o, run.user, ws_names(ws), cur)
}

@(private)
ws_names :: proc(ws: ^Worktree) -> []string {
	out := make([]string, len(ws.members), context.temp_allocator)
	for mb, i in ws.members {
		out[i] = mb.name
	}
	return out
}

files_delta :: proc(r: ^Runtime, o: Object, parent: Rid, names: []string, cur: map[string]convo.File_Delta) -> []convo.File_Delta {
	base: []convo.File_Delta
	if !obj.rid_none(parent) {
		if b, err := eng.convo_files_at(r.e, o, parent, context.temp_allocator); err == .None {
			base = b
		}
	}
	out := make([dynamic]convo.File_Delta, context.temp_allocator)
	for name in names {
		c, ok := cur[name]
		if !ok {
			continue
		}
		same := false
		for f in base {
			if f.mount == name && f.tree == c.tree && f.line == c.line && string(f.version) == string(c.version) {
				same = true
			}
		}
		if !same {
			append(&out, c)
		}
	}
	return out[:]
}

current_files :: proc(r: ^Runtime, o: Object, parent: Rid) -> []convo.File_Delta {
	ms, err := eng.convo_mounts(r.e, o, context.temp_allocator)
	if err != .None || len(ms) == 0 {
		return nil
	}
	cur := make(map[string]convo.File_Delta, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for m in ms {
		tree := Object{o.space, m.tree}
		h, herr := eng.tree_history(r.e, tree)
		if herr != .None {
			continue
		}
		v, found, verr := fs.history_line(h, line_name(m.line), context.temp_allocator)
		if verr == .None && found {
			cur[m.name] = convo.File_Delta{mount = m.name, tree = m.tree, line = m.line, version = version_encode(v, "", "")}
			append(&names, m.name)
		}
		eng.tree_release(r.e, tree)
	}
	return files_delta(r, o, parent, names[:], cur)
}

@(private)
_begin_fenced :: proc(r: ^Runtime, o: Object, arg: int, err: Error) {
	run := run_find(r, o)
	if run == nil || run.ws == nil || run.state != .Preparing {
		return
	}
	if e := _worktree_begin(run.ws, run); e != .None || err != .None {
		_ensure_reply(run, nil)
		run_error(run, "the conversation's file trees could not be materialized")
		run.state = .Running
		run_finish(run, .Failed)
		return
	}
	if _ensure_reply(run, _start_files(run)) != .None {
		run.state = .Running
		run_finish(run, .Failed)
		return
	}
	_run_setup(run)
}

@(private)
_run_setup :: proc(run: ^Run) -> Error {
	if run.ws != nil && worktree_needs_setup(run.ws) {
		return worktree_setup(run.ws, run, _run_launch)
	}
	_run_launch(run)
	return .None
}

@(private)
_run_launch :: proc(run: ^Run) {
	run.state = .Running
	switch run.ai.kind {
	case .Harness:
		if err := harness_start(run); err != .None && err != .Pending {
			run_error(run, "the agent could not be started")
			run_finish(run, .Failed)
		}
	case .Native:
		if err := native_start(run); err != .None {
			run_error(run, "the model could not be reached")
			run_finish(run, .Failed)
		}
	}
}

@(private)
_new_lines :: proc(r: ^Runtime, o: Object, run: ^Run) -> []convo.Line {
	ms, err := eng.convo_mounts(r.e, o, context.temp_allocator)
	if err != .None || len(ms) == 0 {
		return nil
	}
	out := make([]convo.Line, len(ms), run.alloc)
	for m, i in ms {
		out[i] = convo.Line{mount = clone(m.name, run.alloc), line = new_id(r)}
	}
	return out
}

lines_encode :: proc(lines: []convo.Line) -> []u8 {
	if len(lines) == 0 {
		return nil
	}
	b := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&b)
	prim.write_uvarint(&w, u64(len(lines)))
	for l in lines {
		prim.write_str(&w, l.mount)
		prim.write_id(&w, l.line)
	}
	return b[:]
}

lines_decode :: proc(b: []u8, allocator := context.temp_allocator) -> []convo.Line {
	if len(b) == 0 {
		return nil
	}
	rd := prim.reader(b)
	n := prim.read_uvarint(&rd)
	if n > 4096 {
		return nil
	}
	out := make([dynamic]convo.Line, 0, int(n), allocator)
	for _ in 0 ..< n {
		m := prim.read_str(&rd)
		l := prim.read_id(&rd)
		if !prim.reader_ok(&rd) {
			return nil
		}
		append(&out, convo.Line{mount = clone(m, allocator), line = l})
	}
	return out[:]
}

@(private)
_user_content :: proc(run: ^Run, m: ^convo.Message) {
	b := make(Buf, context.temp_allocator)
	files := make([dynamic]agent.Attachment, run.alloc)
	for blk in m.blocks {
		#partial switch blk.kind {
		case .Text:
			if len(b) > 0 {
				append(&b, "\n\n")
			}
			append(&b, ..blk.text)
		case .File, .Image:
			data := blk.text
			if blk.is_ref {
				data = _blob_read(run.r, blk.blob.oid)
			}
			if len(data) == 0 {
				continue
			}
			append(&files, agent.Attachment{name = clone(blk.name, run.alloc), mime = clone(blk.id, run.alloc), data = clone_bytes(data, run.alloc)})
		}
	}
	run.text = clone(string(b[:]), run.alloc)
	run.files = files[:]
}

@(private)
_blob_read :: proc(r: ^Runtime, oid_bytes: []u8) -> []u8 {
	if len(oid_bytes) != 20 && len(oid_bytes) != 32 {
		return nil
	}
	db, err := eng.device_odb(r.e)
	if err != .None {
		return nil
	}
	oid: odb.Oid
	copy(oid[:], oid_bytes)
	_, data, rerr := odb.read(db, oid, context.temp_allocator)
	if rerr != .None {
		return nil
	}
	return data
}

@(private)
_on_run_convo :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	context = eng.context_for((^Run)(data).r.e)
	run := (^Run)(data)
	for d in deltas {
		if d.kind == .Intent || d.kind == .Run {
			_queue_eval(run.r, run.o)
			return
		}
	}
}

@(private)
_run_intents :: proc(run: ^Run, v: ^obj.View, t: ^convo.Tail, items: []convo.Intent) {
	r := run.r
	if run.state == .Finished {
		return
	}
	if !run.superseded {
		assignee, aerr := convo.assignee(v, t, run.user)
		if aerr == .None && !prim.id_is_zero(assignee) && assignee != r.self {
			run.superseded = true
			run_notice(run, "this turn was reassigned to another runner")
			run_interrupt(run)
			return
		}
	}
	if task_cancelled(r, run.o) && !run.cancelled {
		run.cancelled = true
		run_interrupt(run)
	}
	for &it in items {
		targets_run := obj.rid_none(it.target) || it.target == run.reply || it.target == run.user
		#partial switch it.kind {
		case .Steer:
			if !targets_run || run_steered(run, it.item) || run.state != .Running || run.interrupting {
				continue
			}
			run_steer(run, &it)
		case .Interrupt:
			if !targets_run {
				continue
			}
			if w := _writer(run); w != nil {
				convo.writer_unqueue(w, it.item, .Applied, run.reply)
			}
			run_interrupt(run)
		case .Answer:
			for p, i in run.perms {
				if p.block != it.target {
					continue
				}
				run_answer(run, p.id, it.allow, it.text)
				if w := _writer(run); w != nil {
					convo.writer_unqueue(w, it.item, .Applied, run.reply)
				}
				ordered_remove(&run.perms, i)
				break
			}
		}
	}
}

run_steer :: proc(run: ^Run, it: ^convo.Intent) {
	files := make([dynamic]agent.Attachment, context.temp_allocator)
	for a in it.attachments {
		data := _blob_read(run.r, a.oid)
		if len(data) > 0 {
			append(&files, agent.Attachment{name = a.name, mime = a.mime, data = data})
		}
	}
	id := rid_uuid(it.item)
	ok := false
	if run.proc_ != nil {
		run.raw_link = it.item
		ok = proc_steer(run.proc_, it.text, id, files[:])
		run.raw_link = {}
	} else if run.native != nil {
		ok = native_steer(run.native, it.text, id, files[:])
	}
	if ok {
		append(&run.steered, it.item)
	}
}

run_answer :: proc(run: ^Run, id: string, allow: bool, text: string) {
	if run.proc_ != nil {
		proc_answer(run.proc_, id, allow)
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kbool(&b, "allow", allow)
	if len(text) > 0 {
		jw_kstr(&b, "text", text)
	}
	append(&b, '}')
	run_block(run, .Permission_Answer, b[:], id)
	run.cur = -1
}

@(private)
_recover :: proc(r: ^Runtime, space: prim.Id) {
	now := wall_ms(r)
	for ent in state_runs(r, space) {
		if run_find(r, ent.object) != nil {
			continue
		}
		w := _convo_w(r, ent.object)
		if w == nil {
			state_run_clear(r, ent.object)
			continue
		}
		convo.writer_interrupt_open(w, now)
		eng.touched(r.e, ent.object)
		if r.quiesce.on || (_replicated(r, ent.object.space) && _follow_start(r, ent.object)) {
			append(&r.revives, Revive_Wait{object = ent.object})
			continue
		}
		_revive_decide(r, ent)
	}
}


@(private)
_revive_pending :: proc(r: ^Runtime, o: Object, v: ^obj.View) -> bool {
	idx := -1
	for x, i in r.revives {
		if x.object == o {
			idx = i
		}
	}
	if idx < 0 {
		return false
	}
	if !_revive_ready(r, o, v) {
		_follow_start(r, o)
		return true
	}
	unordered_remove(&r.revives, idx)
	if ent, ok := state_run_get(r, o); ok {
		_revive_decide(r, ent)
	}
	return true
}

@(private)
_revive_ready :: proc(r: ^Runtime, o: Object, v: ^obj.View) -> bool {
	if !eng.space_caught_up(r.e, o.space) {
		return false
	}
	for w in r.waits {
		if w.object == o {
			return false
		}
	}
	ready := _wait_ready(r, o)
	ready.fresh = true
	if _, serr := eng.convo_status(r.e, o, ready); serr == .Pending {
		return false
	}
	_wait_drop(r, ready)
	c, found, err := eng.catalog_get(r.e, o, context.temp_allocator)
	if err != .None || !found {
		return false
	}
	for p in c.participants {
		if p == r.self {
			continue
		}
		s := obj.view_find(v, p)
		if s < 0 || obj.end(v, s) == 0 {
			return false
		}
	}
	return true
}

@(private)
_revive_decide :: proc(r: ^Runtime, ent: Run_Entry) {
	w := _convo_w(r, ent.object)
	if w == nil {
		return
	}
	lines := lines_decode(ent.lines)
	revived := false
	list, n := convo.writer_revivable(w)
	for i in 0 ..< n {
		msg := list[i]
		if msg != ent.reply || revived {
			convo.writer_decline(w, msg)
			continue
		}
		if _revive(r, ent, lines) == .None {
			revived = true
		} else {
			convo.writer_decline(w, msg)
		}
	}
	if !revived {
		_land_lines(r, ent.object, ent.claim, lines)
		state_run_clear(r, ent.object)
	}
	eng.touched(r.e, ent.object)
	eng.catalog_usage(r.e, ent.object, {})
}

@(private)
_revive :: proc(r: ^Runtime, ent: Run_Entry, lines: []convo.Line) -> Error {
	o := ent.object
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return .Engine
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return .Pending
	}
	um, merr := convo.message(v, &t, convo.Position{msg = ent.user}, context.temp_allocator)
	if merr != .None {
		return .Pending
	}
	rm, rerr := convo.message(v, &t, convo.Position{msg = ent.reply}, context.temp_allocator)
	if rerr != .None {
		return .Pending
	}
	run := _run_new(r, o)
	if run == nil {
		return .Limit
	}
	a, ok := agent_resolve(r, o, um.provider, um.model, run.alloc)
	if !ok {
		_run_free(run)
		return .Not_Found
	}
	p := Placement {
		kind   = .Revive,
		object = o,
		msg    = ent.reply,
		sender = r.self,
		agent  = a.object.id,
		policy = a.policy,
	}
	if place(r, &p) != r.self {
		_run_free(run)
		return .Not_Assigned
	}
	if assignee, aerr := convo.assignee(v, &t, ent.user); aerr == .None && !prim.id_is_zero(assignee) && assignee != r.self {
		_run_free(run)
		return .Not_Assigned
	}
	run.ai = a
	run.user = ent.user
	run.parent = um.parent
	run.revive = true
	run.text = REVIVE_PROMPT
	run.checkpoint = clone(rm.seal_native, run.alloc)
	w := _convo_w(r, o)
	if w == nil {
		_run_free(run)
		return .Engine
	}
	owned := make([]convo.Line, len(lines), run.alloc)
	for l, i in lines {
		owned[i] = convo.Line{mount = clone(l.mount, run.alloc), line = l.line}
	}
	claim, cerr := convo.writer_claim(w, ent.user, r.cfg.lease_ms, owned)
	if cerr != .None {
		_run_free(run)
		return .Not_Assigned
	}
	run.claim = claim
	run.revive_of = ent.reply
	run.attempt = rm.open_state == .Revive ? 1 : 0
	_run_begin(run, owned)
	return .None
}

@(private)
_land_lines :: proc(r: ^Runtime, o: Object, claim: Rid, lines: []convo.Line) {
	if len(lines) == 0 {
		return
	}
	ms, err := eng.convo_mounts(r.e, o, context.temp_allocator)
	if err != .None {
		return
	}
	files := make([dynamic]convo.File_Delta, context.temp_allocator)
	for l in lines {
		for m in ms {
			if m.name != l.mount {
				continue
			}
			tree := Object{o.space, m.tree}
			h, herr := eng.tree_history(r.e, tree)
			if herr != .None {
				continue
			}
			v, found, verr := fs.history_line(h, line_name(l.line), context.temp_allocator)
			if verr == .None && found {
				fs.history_set_line(h, line_name(m.line), v)
				append(&files, convo.File_Delta{mount = m.name, tree = m.tree, line = m.line, version = version_encode(v, "", "")})
			}
			eng.tree_release(r.e, tree)
		}
	}
	if len(files) > 0 {
		if w := _convo_w(r, o); w != nil {
			convo.writer_landed(w, claim, files[:], .Interrupted)
		}
	}
}

@(private)
_reply_hooks :: proc(r: ^Runtime, o: Object, reply: Rid, status: convo.Seal_Status) {
	channel_reply(r, o, reply, status)
	if r.cfg.hooks.sealed != nil {
		r.cfg.hooks.sealed(r.cfg.hooks.data, r, o, reply, status)
	}
}

@(private)
_lease_prune :: proc(r: ^Runtime, o: Object, v: ^obj.View) {
	any := false
	for w in r.leases {
		any ||= !w.claim && w.object == o
	}
	if !any {
		return
	}
	list, err := convo.unsealed(v, context.temp_allocator)
	if err != .None {
		return
	}
	i := 0
	for i < len(r.leases) {
		w := r.leases[i]
		keep := w.object != o || w.claim
		if !keep {
			for u in list {
				keep ||= u.msg == w.msg && u.state == .Running
			}
		}
		if !keep {
			if w.sub != 0 {
				eng.unsubscribe(r.e, w.sub)
			}
			unordered_remove(&r.leases, i)
			continue
		}
		i += 1
	}
	_lease_arm(r)
}

@(private)
_on_watch_convo :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	for d in deltas {
		_queue_eval(r, d.object)
		return
	}
}

@(private)
_view_activity :: proc(v: ^obj.View) -> i64 {
	best: prim.Hlc
	for s in 0 ..< len(v.segs) {
		if a, err := convo.segment_activity(v, s); err == .None && a > best {
			best = a
		}
	}
	return prim.hlc_ms(best)
}

@(private)
_follow_stale :: proc(r: ^Runtime, o: Object, v: ^obj.View, c: ^eng.Catalog_Entry) -> (waiting: bool) {
	remote := false
	for p in c.participants {
		remote ||= p != r.self
	}
	idx := -1
	for f, i in r.follows {
		if f.object == o {
			idx = i
		}
	}
	author := _activity_author(r, o)
	behind := remote && i64(c.activity) > _view_activity(v) && author != r.self && runner_present(r, o.space, author)
	if idx < 0 {
		if !behind || run_find(r, o) != nil {
			return false
		}
		return _follow_start(r, o)
	}
	f := &r.follows[idx]
	if !f.fresh {
		return true
	}
	eng.unsubscribe(r.e, f.sub)
	if f.timer != 0 {
		prim.timer_cancel(eng.loop(r.e), f.timer)
	}
	free(f.grace, r.allocator)
	unordered_remove(&r.follows, idx)
	return false
}

FOLLOW_GRACE_MS :: 5000

@(private)
_on_follow_grace :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Follow_Grace)(data).r.e)
	g := (^Follow_Grace)(data)
	for &f in g.r.follows {
		if f.sub == g.sub {
			f.timer = 0
			f.fresh = true
			_queue_eval(g.r, f.object)
		}
	}
}

@(private)
_follow_start :: proc(r: ^Runtime, o: Object) -> bool {
	for f in r.follows {
		if f.object == o {
			return true
		}
	}
	sid, serr := eng.subscribe(r.e, o, .Conversation, _on_follow_convo, r)
	if serr != .None {
		return false
	}
	g := new(Follow_Grace, r.allocator)
	g^ = {r = r, sub = sid}
	append(&r.follows, Follow{object = o, sub = sid, grace = g, timer = prim.timer(eng.loop(r.e), FOLLOW_GRACE_MS, g, _on_follow_grace)})
	return true
}

@(private)
_on_follow_convo :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	remote := false
	for d in deltas {
		remote ||= !d.local
	}
	if !remote {
		return
	}
	for &f in r.follows {
		if f.sub == sub {
			f.fresh = true
			_queue_eval(r, f.object)
		}
	}
}

@(private)
_activity_author :: proc(r: ^Runtime, o: Object) -> prim.Id {
	kb: [16]u8
	key := omap.catalog_key(o.id, &kb)
	en, found, err := eng.map_get(r.e, eng.space_catalog(r.e, o.space), key, context.temp_allocator)
	if err != .None || !found {
		return {}
	}
	for reg in en.registers {
		if reg.tag == u32(omap.Catalog_Tag.Activity) {
			return reg.by
		}
	}
	return {}
}


@(private)
_replicated :: proc(r: ^Runtime, space: prim.Id) -> bool {
	info, err := eng.space_info(r.e, space)
	return err == .None && len(info.relay) > 0
}

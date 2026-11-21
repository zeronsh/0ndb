package rt

import "../agent"
import "../convo"
import eng "../engine"
import "../fs"
import "../obj"
import "../odb"
import "../prim"

REVIVE_PROMPT :: "Your previous turn was cut off by a restart of the machine running you. Continue the task from exactly where you left off; do not repeat work that is already done."

evaluate :: proc(r: ^Runtime, o: Object) {
	if !r.cfg.runner || r.closing {
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
	items, ierr := convo.intents(v, context.temp_allocator)
	if ierr == .Missing {
		eng.convo_intents(r.e, o, context.temp_allocator, _wait_ready(r, o))
		return
	}
	if ierr != .None {
		return
	}
	if run := run_find(r, o); run != nil {
		_run_intents(run, v, &t, items)
		return
	}
	cancelled := task_cancelled(r, o)
	head := convo.tail_head(v, &t)
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
			if t.running {
				break
			}
			if place_intent(r, o, &it) != r.self {
				return
			}
			_start_from_intent(r, o, head, &it)
			return
		case .Interrupt, .Answer:
			if t.running {
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
		if hm.open || hm.status != .Done || t.running {
			return
		}
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
		}
	}
}

place_intent :: proc(r: ^Runtime, o: Object, it: ^convo.Intent) -> prim.Id {
	a, ok := agent_resolve(r, o, "", "", context.temp_allocator)
	if !ok {
		return {}
	}
	p := Placement {
		kind   = .Intent,
		object = o,
		msg    = it.item,
		sender = it.by,
		agent  = a.object.id,
		policy = a.policy,
	}
	return place(r, &p)
}

@(private)
_placed_here :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail, m: ^convo.Message) -> bool {
	assignee, aerr := convo.assignee(v, t, m.id)
	if aerr == .None && !prim.id_is_zero(assignee) {
		return assignee == r.self
	}
	a, ok := agent_resolve(r, o, m.provider, m.model, context.temp_allocator)
	if !ok {
		return false
	}
	p := Placement {
		kind   = .Message,
		object = o,
		msg    = m.id,
		sender = m.author,
		agent  = a.object.id,
		policy = a.policy,
	}
	return place(r, &p) == r.self
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
	msg, merr := convo.writer_message(w, convo.Msg_Spec{role = .User, author = it.by, parent = head, runner = r.self, intent = it.item, native = native})
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
	reply, rerr := convo.writer_message(w, convo.Msg_Spec{role = .Assistant, parent = user, runner = r.self, provider = a.provider, model = a.model, claim = claim.off, native = a.provider if a.kind == .Harness else ""})
	if rerr != .None {
		_run_free(run)
		return .Engine
	}
	run.reply = reply
	if exhausted {
		eng.pin(r.e, o)
		run.pinned = true
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
	state_run_put(r, Run_Entry{object = o, user = run.user, reply = run.reply, claim = run.claim, agent = run.ai.object.id, lines = lines_encode(lines)})
	eng.touched(r.e, o)
	eng.catalog_usage(r.e, o, {})
	if sid, serr := eng.subscribe(r.e, o, .Conversation, _on_run_convo, run); serr == .None {
		run.sub = sid
	}
	r.stats.runs_started += 1
	if run.ai.budget.seconds > 0 {
		run.budget_timer = prim.timer(eng.loop(r.e), run.ai.budget.seconds * 1000, run, _on_budget_timer)
	}
	if len(lines) > 0 {
		ws, werr := worktree_open(r, o, run, lines)
		if werr != .None {
			run_error(run, "the conversation's file trees could not be materialized")
			run.state = .Running
			run_finish(run, .Failed)
			return werr
		}
		run.ws = ws
	}
	return _run_setup(run)
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
		if err := harness_start(run); err != .None {
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
		ok = proc_steer(run.proc_, it.text, id, files[:])
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
	reply, verr2 := convo.writer_revive(w, ent.reply, convo.Msg_Spec{role = .Assistant, runner = r.self, provider = a.provider, model = a.model, claim = claim.off, native = a.provider if a.kind == .Harness else ""})
	if verr2 != .None {
		_run_free(run)
		return .Engine
	}
	run.reply = reply
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
			convo.writer_landed(w, claim, files[:])
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

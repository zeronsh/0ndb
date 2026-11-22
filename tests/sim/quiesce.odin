package sim

import "core:fmt"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/http"
import "../../src/model"
import "../../src/obj"
import "../../src/prim"
import rt "../../src/runtime"
import osync "../../src/sync"

QUIESCE_SPACE_NAME :: "quiesce"
SIM_MODEL :: "sim-model"

Quiesce_World :: struct {
	on:        bool,
	space:     prim.Id,
	convo:     eng.Object,
	runner:    int,
	members:   [dynamic]int,
	active:    bool,
	inc:       int,
	runs_at:   u64,
	accepted:  u64,
	declined:  [rt.Quiesce_Result]u64,
	stops:     u64,
	offs:      u64,
	held_runs: u64,
	asleep:    bool,
	unran:     u64,
	window:    [dynamic]int,
}

Sim_Http :: struct {
	rng:  Rng,
	next: u64,
	hold: bool,
	reqs: [dynamic]Sim_Http_Req,
}

Sim_Http_Req :: struct {
	id:     http.Id,
	sink:   http.Sink,
	step:   int,
	steps:  int,
	parked: bool,
}

@(private = "file")
Quiesce_Ask :: struct {
	w:   ^World,
	n:   ^Node,
	inc: int,
	op:  int,
}

sim_runtime_config :: proc(n: ^Node) -> rt.Config {
	return rt.Config {
		runner = n.idx == n.w.quiesce.runner,
		default_provider = "sim",
		default_model = SIM_MODEL,
		home_dir = NODE_DIR + "/home",
		work_root = NODE_DIR + "/work",
		model = rt.Model_Plug{data = n, resolve = _sim_model_resolve},
		capacity = 1,
	}
}

@(private = "file")
_sim_model_resolve :: proc(data: rawptr, r: ^rt.Runtime, provider: string, model_id: string, cfg: ^model.Config, m: ^model.Model) -> bool {
	cfg^ = model.Config {
		spec    = model.custom_spec(SIM_MODEL, .Anthropic, 200_000, 4096),
		api_key = "sim",
		url     = "http://sim.invalid/v1/messages",
	}
	m^ = model.model_for(.Anthropic)
	return true
}

sim_http_client :: proc(n: ^Node) -> http.Client {
	return http.Client{data = n, start = _sim_http_start, cancel = _sim_http_cancel}
}

sim_http_hold :: proc(n: ^Node, on: bool) {
	n.http.hold = on
	if on {
		return
	}
	for &q in n.http.reqs {
		if q.parked {
			q.parked = false
			schedule(n.w, Sim_Event{at = n.w.now + 1_000_000, kind = EV_SIM_HTTP, node = n.idx, gen = u64(n.incarnation), arg = u64(q.id)})
		}
	}
}

@(private = "file")
_sim_http_start :: proc(data: rawptr, req: ^http.Request, sink: http.Sink) -> (http.Id, http.Error) {
	n := (^Node)(data)
	w := n.w
	if n.rt_on && rt.quiesced(&n.rt) && w.quiesce.active && w.quiesce.inc == n.incarnation {
		world_fail(w, "quiesce: %s started a model request while quiesced", n.name)
	}
	n.http.next += 1
	id := http.Id(n.http.next)
	world_note(w, "%s model request %d", n.name, n.http.next)
	append(&n.http.reqs, Sim_Http_Req{id = id, sink = sink, steps = 3 + rng_int(&n.http.rng, 6)})
	schedule(w, Sim_Event{at = w.now + rng_range(&n.http.rng, 1, 40) * 1_000_000, kind = EV_SIM_HTTP, node = n.idx, gen = u64(n.incarnation), arg = u64(id)})
	return id, .None
}

@(private = "file")
_sim_http_cancel :: proc(data: rawptr, id: http.Id) {
	n := (^Node)(data)
	for q, i in n.http.reqs {
		if q.id == id {
			ordered_remove(&n.http.reqs, i)
			return
		}
	}
}

sim_http_event :: proc(w: ^World, ev: ^Sim_Event) {
	n := w.nodes[ev.node]
	if !n.alive || u64(n.incarnation) != ev.gen {
		return
	}
	idx := -1
	for q, i in n.http.reqs {
		if q.id == http.Id(ev.arg) {
			idx = i
		}
	}
	if idx < 0 || n.http.reqs[idx].parked {
		return
	}
	q := &n.http.reqs[idx]
	id, sink := q.id, q.sink
	context = instance_context(&n.inst)
	defer node_after(n)
	if q.step == 0 {
		q.step = 1
		hs := [1]http.Header{{name = "content-type", value = "text/event-stream"}}
		sink.head(sink.data, id, 200, hs[:])
		schedule(w, Sim_Event{at = w.now + rng_range(&n.http.rng, 1, 30) * 1_000_000, kind = EV_SIM_HTTP, node = n.idx, gen = ev.gen, arg = ev.arg})
		return
	}
	body: string
	last := q.step >= q.steps
	if last && n.http.hold {
		q.parked = true
		return
	}
	switch {
	case q.step == 1:
		body = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sim\",\"model\":\"sim-model\",\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
	case last:
		body = "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
	case:
		body = fmt.tprintf("event: content_block_delta\ndata: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"reply %d \"}}}}\n\n", q.step)
	}
	q.step += 1
	keep := sink.body(sink.data, id, transmute([]u8)body)
	if !keep || last {
		for x, i in n.http.reqs {
			if x.id == id {
				ordered_remove(&n.http.reqs, i)
				break
			}
		}
		sink.done(sink.data, id, .None if keep else .Cancelled, "")
		return
	}
	schedule(w, Sim_Event{at = w.now + rng_range(&n.http.rng, 1, 30) * 1_000_000, kind = EV_SIM_HTTP, node = n.idx, gen = ev.gen, arg = ev.arg})
}

quiesce_setup :: proc(w: ^World) -> bool {
	q := &w.quiesce
	q.members = make([dynamic]int, w.allocator)
	q.window = make([dynamic]int, w.allocator)
	if len(w.nodes) < 2 || env_u64("SIM_QUIESCE", 1) == 0 {
		return true
	}
	q.runner = len(w.nodes) - 1
	n0 := w.nodes[0]
	{
		context = instance_context(&n0.inst)
		id, err := eng.space_create(&n0.e, QUIESCE_SPACE_NAME, "relay", w.relay.public)
		if err != .None || eng.space_open(&n0.e, id) != .None {
			world_fail(w, "quiesce: space setup failed: %v", err)
			return false
		}
		q.space = id
		node_after(n0)
	}
	append(&q.members, 0)
	for i in 1 ..< len(w.nodes) {
		if i != q.runner && i != 1 {
			continue
		}
		n := w.nodes[i]
		proof: []u8
		{
			context = instance_context(&n0.inst)
			p, aerr := eng.member_add(&n0.e, q.space, n.identity, .Device, .Admin, .Approval, 0, w.allocator)
			if aerr != .None {
				world_fail(w, "quiesce: member_add for %s failed: %v", n.name, aerr)
				return false
			}
			proof = p
			node_after(n0)
		}
		context = instance_context(&n.inst)
		if _, err := eng.space_join_enrollment(&n.e, q.space, proof, QUIESCE_SPACE_NAME, "relay", w.relay.public); err != .None {
			world_fail(w, "quiesce: %s join failed: %v", n.name, err)
			return false
		}
		if err := eng.space_open(&n.e, q.space); err != .None {
			world_fail(w, "quiesce: %s space_open failed: %v", n.name, err)
			return false
		}
		node_after(n)
		append(&q.members, i)
	}
	{
		context = instance_context(&n0.inst)
		o, err := eng.convo_create(&n0.e, q.space, eng.Convo_Settings{title = "quiesce"})
		if err != .None {
			world_fail(w, "quiesce: convo_create failed: %v", err)
			return false
		}
		q.convo = o
		node_after(n0)
	}
	q.on = true
	for i in q.members {
		quiesce_runtime_start(w.nodes[i])
	}
	return true
}

quiesce_runtime_start :: proc(n: ^Node) {
	w := n.w
	rng_init(&n.http.rng, w.cfg.seed, 17_000 + u64(n.idx) * 64 + u64(n.incarnation))
	if n.http.reqs == nil {
		n.http.reqs = make([dynamic]Sim_Http_Req, w.allocator)
	}
	clear(&n.http.reqs)
	n.http.hold = false
	member := false
	for i in w.quiesce.members {
		member ||= i == n.idx
	}
	if !w.quiesce.on || !member || n.rt_on || !n.e_open {
		return
	}
	if n.idx == w.quiesce.runner {
		w.quiesce.asleep = false
	}
	context = instance_context(&n.inst)
	if err := rt.open(&n.rt, &n.e, sim_runtime_config(n), context.allocator); err != .None {
		_quiesce_start_failed(n, "open", err)
		return
	}
	n.rt_on = true
	if err := rt.attach(&n.rt, w.quiesce.space); err != .None {
		_quiesce_start_failed(n, "attach", err)
	}
	node_after(n)
}

@(private = "file")
_quiesce_start_failed :: proc(n: ^Node, what: string, err: rt.Error) {
	w := n.w
	if n.restart_pending || (w.cfg.io_rate > 0 && err == .Engine) {
		world_note(w, "%s runtime %s hit the failed engine (%v); supervisor restarts it", n.name, what, err)
		n.restart_pending = true
		return
	}
	world_fail(w, "quiesce: %s runtime %s failed: %v", n.name, what, err)
}

quiesce_runtime_kill :: proc(n: ^Node) {
	n.rt_on = false
	n.rt = {}
	clear(&n.http.reqs)
	if n.idx == n.w.quiesce.runner {
		n.w.quiesce.active = false
		if !n.w.quiesce.asleep {
			_quiesce_window_end(n.w, false)
		}
	}
}

quiesce_runtime_close :: proc(n: ^Node) {
	if !n.rt_on {
		return
	}
	context = instance_context(&n.inst)
	rt.close(&n.rt)
	n.rt_on = false
}

quiesce_destroy :: proc(w: ^World) {
	w.quiesce.on = false
	delete(w.quiesce.members)
	delete(w.quiesce.window)
	w.quiesce.members = nil
	w.quiesce.window = nil
}

@(private = "file")
_quiesce_window_end :: proc(w: ^World, kept: bool) {
	q := &w.quiesce
	if !q.on {
		return
	}
	if !kept {
		for i in q.window {
			w.model.ops[i].delta = 0
		}
	}
	clear(&q.window)
}

op_run_queue :: proc(w: ^World) {
	q := &w.quiesce
	if !q.on {
		return
	}
	cands := make([dynamic]int, context.temp_allocator)
	for i in q.members {
		if w.nodes[i].alive {
			append(&cands, i)
		}
	}
	if len(cands) == 0 {
		return
	}
	n := w.nodes[cands[rng_int(&w.rng, len(cands))]]
	m := &w.model
	op := new_op(m, .Run_Queue, n, -1)
	op.token = new_token(m, n, "w")
	context = instance_context(&n.inst)
	rid, err := eng.convo_queue(&n.e, q.convo, op.token, nil, op_done_handle(op))
	if err != .Pending {
		op.rid = rid
	}
	runner := w.nodes[q.runner]
	held := (runner.rt_on && rt.quiesced(&runner.rt)) || (q.asleep && !runner.alive)
	if held {
		op.delta = 1
		append(&q.window, op.idx)
	}
	world_note(w, "%s queues %s for the runner (held=%v alive=%v) -> %v", n.name, op.token, held, runner.alive, err)
	op_result(op, n, err)
	node_after(n)
}

op_quiesce :: proc(w: ^World) {
	q := &w.quiesce
	if !q.on {
		return
	}
	n := w.nodes[q.runner]
	if !n.alive || !n.rt_on {
		return
	}
	_quiesce_window_end(w, false)
	m := &w.model
	op := new_op(m, .Quiesce, n, -1)
	lift := i64(180_000) if !rng_chance(&w.rng, 1, 4) else i64(200 + rng_int(&w.rng, 2000))
	ask := new(Quiesce_Ask, w.allocator)
	ask^ = Quiesce_Ask{w = w, n = n, inc = n.incarnation, op = op.idx}
	context = instance_context(&n.inst)
	runs := rt.stats(&n.rt).runs_started
	res, pending := rt.quiesce(&n.rt, true, lift, rt.Quiesce_Done{data = ask, call = _on_quiesce_answer})
	world_note(w, "%s quiesce (lift %d ms) -> %v pending=%v", n.name, lift, res, pending)
	if pending {
		q.active = true
		q.inc = n.incarnation
		q.runs_at = runs
	} else {
		free(ask, w.allocator)
		q.declined[res] += 1
		op_done(op, eng.pending_seq(&n.e), .None)
	}
	node_after(n)
}

@(private = "file")
_on_quiesce_answer :: proc(data: rawptr, r: ^rt.Runtime, res: rt.Quiesce_Result) {
	ask := (^Quiesce_Ask)(data)
	w, n, inc, opi := ask.w, ask.n, ask.inc, ask.op
	free(ask, w.allocator)
	q := &w.quiesce
	if n.incarnation != inc || !n.alive {
		return
	}
	world_note(w, "%s quiesce answered %v", n.name, res)
	if res != .Accepted {
		q.declined[res] += 1
		q.active = false
		_quiesce_window_end(w, false)
		op_done(w.model.ops[opi], eng.pending_seq(&n.e), .None)
		return
	}
	q.accepted += 1
	op_done(w.model.ops[opi], eng.pending_seq(&n.e), .None)
	_quiesce_relay_check(w, n)
	stop := !rng_chance(&w.fault_rng, 1, 5)
	schedule(w, Sim_Event{at = w.now + rng_range(&w.fault_rng, 1, 400) * 1_000_000, kind = EV_QUIESCE_STEP, node = n.idx, gen = u64(n.incarnation), arg = 0 if stop else 1})
}

@(private = "file")
_quiesce_relay_check :: proc(w: ^World, n: ^Node) {
	if !w.relay.alive {
		world_fail(w, "quiesce: %s accepted with the relay down", n.name)
		return
	}
	for sid, sp in n.e.spaces {
		if !sp.open || !sp.repl_on {
			continue
		}
		for id, l in sp.repl.locals {
			if l.superseded || l.hollow {
				continue
			}
			want := l.durable
			if len(l.path) > 0 {
				context = instance_context(&n.inst)
				if st, err := prim.stat(n.e.vfs, l.path); err == .None {
					want = max(want, st.size)
				}
				node_after(n)
			}
			if want <= 0 {
				continue
			}
			length, base, exists := _quiesce_relay_probe(w, sid, id)
			if !exists || length < want {
				world_fail(w, "quiesce: %s accepted but the relay holds %d of %d durable bytes of %s (base %d, %s)", n.name, length, want, stream_short(id), base, l.name)
			}
		}
	}
}

@(private = "file")
_quiesce_relay_probe :: proc(w: ^World, space: prim.Id, id: osync.Stream_Id) -> (length, base: i64, exists: bool) {
	rn := &w.relay
	context = instance_context(&rn.inst)
	defer relay_after(rn)
	r := &rn.r
	st := r.store
	ns: rawptr
	opened := false
	if sp, ok := r.spaces[space]; ok && sp.ns != nil {
		ns = sp.ns
	} else {
		h, _, err := st.namespace_open(st.data, space)
		if err != .None {
			return
		}
		ns = h
		opened = true
	}
	defer if opened {
		st.namespace_close(st.data, ns)
	}
	l, b, ex, err := st.stream_probe(st.data, ns, id)
	if err != .None {
		return
	}
	return l, b, ex
}

quiesce_event :: proc(w: ^World, ev: ^Sim_Event) {
	n := w.nodes[ev.node]
	q := &w.quiesce
	if !n.alive || u64(n.incarnation) != ev.gen || !n.rt_on {
		return
	}
	held := rt.quiesced(&n.rt)
	if held && q.active {
		context = instance_context(&n.inst)
		now := rt.stats(&n.rt).runs_started
		node_after(n)
		if now != q.runs_at {
			world_fail(w, "quiesce: %s started %d turns while quiesced", n.name, now - q.runs_at)
		}
	}
	if ev.arg == 1 {
		q.offs += 1
		q.active = false
		_quiesce_window_end(w, false)
		context = instance_context(&n.inst)
		rt.quiesce(&n.rt, false)
		world_note(w, "%s quiesce lifted by the host (was quiesced=%v)", n.name, held)
		node_after(n)
		return
	}
	q.stops += 1
	q.active = false
	q.asleep = true
	_quiesce_window_end(w, true)
	_quiesce_stop(n)
}

@(private = "file")
_quiesce_stop :: proc(n: ^Node) {
	w := n.w
	context = w.ctx
	n.disk.dead = false
	n.boot += 1
	world_note(w, "%s stopped after quiesce (power off, durable disk)", n.name)
	w.stats.crashes += 1
	node_kill(n)
	disk_crash(&n.disk, .Power, &w.fault_rng)
	model_node_crashed(&w.model, n, .Power)
	schedule(w, Sim_Event{at = w.now + rng_range(&w.fault_rng, 50, 3000) * 1_000_000, kind = .Restart, node = n.idx})
}

check_quiesce :: proc(w: ^World) {
	q := &w.quiesce
	if !q.on {
		return
	}
	n := w.nodes[q.runner]
	msgs := make([dynamic]convo.Message, context.temp_allocator)
	its: []convo.Intent
	for round := 0; ; round += 1 {
		if !n.alive {
			return
		}
		what, err := _quiesce_read(w, n, &msgs, &its)
		if err == .None {
			break
		}
		if round >= 12 || !(err == .Missing || err == .Pending || err == .Busy) {
			world_fail(w, "quiesce: %s cannot %s the runtime conversation: %v", n.name, what, err)
			return
		}
		run_until(w, w.now + 120_000_000_000, true)
		if len(w.failures) > 0 {
			return
		}
	}
	everyone := true
	for i in q.members {
		everyone &&= w.nodes[i].alive
	}
	for op in w.model.ops {
		if op.kind != .Run_Queue || !(op.status == .Acked || op.status == .Observed) {
			continue
		}
		users := 0
		replies := 0
		for m in msgs {
			if m.role == .User && msg_text(m) == op.token {
				users += 1
				for x in msgs {
					if x.role == .Assistant && x.parent == m.id {
						replies += 1
					}
				}
			}
		}
		pending := false
		for it in its {
			if it.text == op.token {
				pending = true
			}
		}
		if (op.delta == 0 || !everyone) && users <= 1 && replies <= 1 {
			if replies == 0 {
				q.unran += 1
			}
			continue
		}
		if pending || users != 1 || replies != 1 {
			world_fail(w, "quiesce: queued %s ran %d times (%d messages, still queued %v, sent while the runner was quiesced or asleep %v)", op.token, replies, users, pending, op.delta != 0)
			for m in msgs {
				world_note(w, "  msg %s role=%v parent=%s status=%v open=%v text=%q", rid_str(m.id), m.role, rid_str(m.parent), m.status, m.open, msg_text(m))
			}
		}
	}
	context = instance_context(&n.inst)
	rs := rt.stats(&n.rt)
	world_note(w, "quiesce: %d accepted, declined %v, %d stops, %d host lifts, %d turns held, %d sends outside quiesce not run; runner evaluations %d, runs %d started %d finished", q.accepted, q.declined, q.stops, q.offs, rs.quiesce_held, q.unran, rs.evaluations, rs.runs_started, rs.runs_finished)
}

@(private = "file")
_quiesce_read :: proc(w: ^World, n: ^Node, msgs: ^[dynamic]convo.Message, its: ^[]convo.Intent) -> (what: string, err: eng.Error) {
	q := &w.quiesce
	what = "read"
	ready := eng.Ready{data = nil, call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}}
	context = instance_context(&n.inst)
	defer node_after(n)
	clear(msgs)
	seen := make(map[eng.Rid]bool, context.temp_allocator)
	st := eng.convo_status(&n.e, q.convo, ready) or_return
	pos := convo.Position{msg = st.head}
	for _ in 0 ..< 256 {
		if obj.rid_none(pos.msg) {
			break
		}
		pg, perr := eng.convo_page(&n.e, q.convo, pos, 32, context.temp_allocator, ready)
		if perr != .None {
			return "page", perr
		}
		for msg in pg.messages {
			if seen[msg.id] {
				continue
			}
			seen[msg.id] = true
			full, merr := eng.convo_message(&n.e, q.convo, convo.Position{msg = msg.id}, context.temp_allocator, ready)
			if merr == .None {
				append(msgs, full)
			}
		}
		if !pg.more || pg.next == pos {
			break
		}
		pos = pg.next
	}
	its^, _ = eng.convo_intents(&n.e, q.convo, context.temp_allocator, ready)
	return "read", .None
}

EV_SIM_HTTP: Ev_Kind
EV_QUIESCE_STEP: Ev_Kind

@(init)
_quiesce_hooks :: proc "contextless" () {
	register_final_check(25, check_quiesce)
	register_world(25, nil, quiesce_destroy)
	EV_SIM_HTTP = register_event(sim_http_event)
	EV_QUIESCE_STEP = register_event(quiesce_event)
}

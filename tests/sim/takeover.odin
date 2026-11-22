package sim

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/obj"
import "../../src/prim"
import rt "../../src/runtime"

T_NODES :: 5
T_CLIENT :: 0
T_DEV_A :: 1
T_DEV_B :: 2
T_POOL_A :: 3
T_POOL_B :: 4

@(private = "file")
T_World :: struct {
	w:      ^World,
	space:  prim.Id,
	answer: prim.Id,
	asked:  int,
}

@(private = "file")
_tw: ^T_World

@(private = "file")
_fail :: proc(w: ^World, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args, allocator = w.allocator)
	world_note(w, "FAIL %s", msg)
	append(&w.failures, msg)
}

@(private = "file")
_rt_start :: proc(n: ^Node) {
	tw := _tw
	if n.rt_on || !n.e_open || tw == nil || prim.id_is_zero(tw.space) {
		return
	}
	context = instance_context(&n.inst)
	cfg := sim_runtime_config(n)
	cfg.runner = n.idx != T_CLIENT
	cfg.pool = n.idx == T_POOL_A || n.idx == T_POOL_B
	cfg.name = fmt.tprintf("n%d", n.idx)
	cfg.capacity = 8
	cfg.scheduler = rt.Scheduler{data = n, place = rt.default_scheduler().place, ask = _ask}
	if err := rt.open(&n.rt, &n.e, cfg, context.allocator); err != .None {
		_fail(n.w, "%s runtime open: %v", n.name, err)
		return
	}
	n.rt_on = true
	if err := rt.attach(&n.rt, tw.space); err != .None {
		_fail(n.w, "%s runtime attach: %v", n.name, err)
	}
	node_after(n)
	if cfg.runner {
		sim_http_hold(n, true)
	}
}

@(private = "file")
_ask :: proc(data: rawptr, r: ^rt.Runtime, p: ^rt.Placement, token: u64) {
	n := (^Node)(data)
	w := n.w
	_tw.asked += 1
	schedule(w, Sim_Event{at = w.now + 30_000_000, kind = .Takeover_Answer, node = n.idx, gen = u64(n.incarnation), arg = token})
}

takeover_answer :: proc(w: ^World, ev: ^Sim_Event) {
	n := w.nodes[ev.node]
	if _tw == nil || !n.alive || !n.rt_on || u64(n.incarnation) != ev.gen {
		return
	}
	context = instance_context(&n.inst)
	if prim.id_is_zero(_tw.answer) {
		rt.placed(&n.rt, ev.arg, {}, false)
	} else {
		rt.placed(&n.rt, ev.arg, _tw.answer, true)
	}
	node_after(n)
}

@(private = "file")
_settle :: proc(w: ^World, ms: i64) {
	until := w.now + ms * 1_000_000
	run_until(w, until, true)
	w.now = max(w.now, until)
}

@(private = "file")
_down :: proc(w: ^World, idx: int) {
	n := w.nodes[idx]
	if n.alive {
		context = instance_context(&n.inst)
		eng.flush(&n.e)
		node_after(n)
		node_kill(n)
		context = w.ctx
		disk_crash(&n.disk, .Process, &w.fault_rng)
	}
}


@(private = "file")
_up :: proc(w: ^World, idx: int) {
	n := w.nodes[idx]
	if !n.alive && !node_start(n) {
		_fail(w, "n%d did not start", idx)
	}
}

@(private = "file")
_id :: proc(w: ^World, idx: int) -> prim.Id {
	return w.nodes[idx].identity.id
}

@(private = "file")
_setup :: proc(w: ^World, tw: ^T_World) -> bool {
	n0 := w.nodes[T_CLIENT]
	{
		context = instance_context(&n0.inst)
		id, err := eng.space_create(&n0.e, "takeover", "relay", w.relay.public)
		if err != .None || eng.space_open(&n0.e, id) != .None {
			_fail(w, "space setup: %v", err)
			return false
		}
		tw.space = id
		node_after(n0)
	}
	for i in 1 ..< T_NODES {
		n := w.nodes[i]
		proof: []u8
		{
			context = instance_context(&n0.inst)
			p, aerr := eng.member_add(&n0.e, tw.space, n.identity, .Device, .Admin, .Approval, 0, w.allocator)
			node_after(n0)
			if aerr != .None {
				_fail(w, "member_add n%d: %v", i, aerr)
				return false
			}
			proof = p
		}
		context = instance_context(&n.inst)
		if _, err := eng.space_join_enrollment(&n.e, tw.space, proof, "takeover"); err != .None || eng.space_open(&n.e, tw.space) != .None {
			_fail(w, "n%d join: %v", i, err)
			return false
		}
		node_after(n)
		delete(proof, w.allocator)
	}
	for n in w.nodes {
		_rt_start(n)
	}
	_settle(w, 6000)
	return true
}

@(private = "file")
_replies :: proc(w: ^World, o: eng.Object, msg: eng.Rid) -> (runners: [dynamic]prim.Id) {
	runners = make([dynamic]prim.Id, w.allocator)
	n := w.nodes[T_CLIENT]
	context = instance_context(&n.inst)
	defer node_after(n)
	st, serr := eng.convo_status(&n.e, o)
	if serr != .None {
		return
	}
	if hm, herr := eng.convo_message(&n.e, o, convo.Position{msg = st.head}, context.temp_allocator); herr == .None && hm.role == .Assistant && hm.parent == msg {
		append(&runners, hm.runner)
	}
	if list, uerr := eng.convo_unsealed(&n.e, o, context.temp_allocator); uerr == .None {
		for u in list {
			if u.msg == st.head {
				continue
			}
			if m, merr := eng.convo_message(&n.e, o, convo.Position{msg = u.msg}, context.temp_allocator); merr == .None && m.role == .Assistant && m.parent == msg {
				append(&runners, m.runner)
			}
		}
	}
	pos := convo.Position{msg = st.head}
	for _ in 0 ..< 32 {
		if obj.rid_none(pos.msg) {
			break
		}
		pg, perr := eng.convo_page(&n.e, o, pos, 32, context.temp_allocator)
		if perr != .None {
			break
		}
		for m in pg.messages {
			if m.role == .Assistant && m.parent == msg && m.id != st.head {
				append(&runners, m.runner)
			}
		}
		if !pg.more || pg.next == pos {
			break
		}
		pos = pg.next
	}
	return
}

@(private = "file")
_ran_on :: proc(w: ^World, o: eng.Object, msg: eng.Rid, idx: int) -> bool {
	list := _replies(w, o, msg)
	defer delete(list)
	for x in list {
		if x == _id(w, idx) {
			return true
		}
	}
	return false
}

@(private = "file")
_ran_off :: proc(w: ^World, o: eng.Object, msg: eng.Rid, keep: ..int) -> (other: prim.Id, moved: bool) {
	list := _replies(w, o, msg)
	defer delete(list)
	outer: for x in list {
		for k in keep {
			if x == _id(w, k) {
				continue outer
			}
		}
		return x, true
	}
	return {}, false
}

@(private = "file")
_placement :: proc(w: ^World, o: eng.Object) -> rt.Placement_Info {
	n := w.nodes[T_CLIENT]
	context = instance_context(&n.inst)
	defer node_after(n)
	info, _ := rt.placement_status(&n.rt, o)
	return info
}

@(private = "file")
_start :: proc(w: ^World, tw: ^T_World, label: string, policy: eng.Takeover, on: int) -> (o: eng.Object, msg: eng.Rid, ok: bool) {
	n := w.nodes[T_CLIENT]
	context = instance_context(&n.inst)
	cerr: eng.Error
	o, cerr = eng.convo_create(&n.e, tw.space, eng.Convo_Settings{title = label})
	if cerr != .None {
		node_after(n)
		_fail(w, "%s: convo_create %v", label, cerr)
		return
	}
	eng.takeover_set(&n.e, o, .Conversation, policy)
	serr: eng.Error
	msg, serr = eng.convo_send(&n.e, o, label)
	if serr == .None {
		_, serr = eng.exec(&n.e, eng.Cmd_Assign{object = o, msg = msg, runner = _id(w, on)})
	}
	node_after(n)
	if serr != .None && serr != .Pending {
		_fail(w, "%s: send %v", label, serr)
		return
	}
	for _ in 0 ..< 100 {
		_settle(w, 100)
		if _ran_on(w, o, msg, on) {
			return o, msg, true
		}
	}
	_fail(w, "%s: n%d never started the turn it was assigned", label, on)
	return o, msg, false
}

@(private = "file")
_running :: proc(w: ^World, idx: int, ms: i64) -> bool {
	for _ in 0 ..< int(ms / 100) {
		_settle(w, 100)
		n := w.nodes[idx]
		if n.alive && n.rt_on && rt.active_runs(&n.rt) > 0 {
			return true
		}
	}
	return false
}


@(private = "file")
_resume :: proc(w: ^World, o: eng.Object, idx: int) -> rt.Error {
	n := w.nodes[T_CLIENT]
	context = instance_context(&n.inst)
	defer node_after(n)
	return rt.resume(&n.rt, o, _id(w, idx))
}

@(private = "file")
_wait_moved :: proc(w: ^World, o: eng.Object, msg: eng.Rid, from: int, ms: i64) -> (prim.Id, bool) {
	for _ in 0 ..< int(ms / 100) {
		_settle(w, 100)
		if x, moved := _ran_off(w, o, msg, from); moved {
			return x, true
		}
	}
	return {}, false
}

@(private = "file")
_scenario :: proc(w: ^World, tw: ^T_World) {
	idle: {
		o, msg, ok := _start(w, tw, "default-device", .Default, T_DEV_A)
		if !ok {
			break idle
		}
		_down(w, T_DEV_A)
		_settle(w, 5000)
		if x, moved := _ran_off(w, o, msg, T_DEV_A); moved {
			_fail(w, "default: a stopped device's turn moved to %s on its own", id_short(x))
		}
		if p := _placement(w, o); p.state != .Idle || p.last_runner != _id(w, T_DEV_A) {
			_fail(w, "default: placement %v last %s, want idle on n1", p.state, id_short(p.last_runner))
		}
		_up(w, T_DEV_A)
		if !_running(w, T_DEV_A, 10_000) {
			_fail(w, "default: n1 did not revive its own turn after restarting")
		}
		if x, moved := _ran_off(w, o, msg, T_DEV_A); moved {
			_fail(w, "default: the turn moved to %s instead of reviving on its runner", id_short(x))
		}
	}
	resume: {
		o, msg, ok := _start(w, tw, "default-resume", .Default, T_DEV_A)
		if !ok {
			break resume
		}
		_down(w, T_DEV_A)
		_settle(w, 3000)
		if err := _resume(w, o, T_DEV_B); err != .None {
			_fail(w, "resume: %v", err)
		}
		if _, moved := _wait_moved(w, o, msg, T_DEV_A, 10_000); !moved || !_ran_on(w, o, msg, T_DEV_B) {
			p := _placement(w, o)
			n2 := w.nodes[T_DEV_B]
			context = instance_context(&n2.inst)
			cur, last, _ := rt.runner_of(&n2.rt, o)
			info, perr := rt.placement_status(&n2.rt, o)
			node_after(n2)
			context = w.ctx
			_fail(w, "resume: the turn did not continue on n2 after assign (n0 sees %v runner %s last %s; n2 sees cur %s last %s placement %v %v runner %s, active %d)", p.state, id_short(p.runner), id_short(p.last_runner), id_short(cur), id_short(last), info.state, perr, id_short(info.runner), rt.active_runs(&n2.rt))
		}
		_up(w, T_DEV_A)
		_settle(w, 3000)
	}
	auto: {
		o, msg, ok := _start(w, tw, "auto-device", .Auto, T_DEV_A)
		if !ok {
			break auto
		}
		_down(w, T_DEV_A)
		if _, moved := _wait_moved(w, o, msg, T_DEV_A, 10_000); !moved {
			_fail(w, "auto: no runner took over the stopped device's turn")
		}
		_up(w, T_DEV_A)
		_settle(w, 3000)
	}
	never: {
		o, msg, ok := _start(w, tw, "never-pool", .Never, T_POOL_A)
		if !ok {
			break never
		}
		_down(w, T_POOL_A)
		_settle(w, 5000)
		if x, moved := _ran_off(w, o, msg, T_POOL_A); moved {
			_fail(w, "never: the turn moved to %s", id_short(x))
		}
		if p := _placement(w, o); p.state != .Waiting_Runner || p.runner != _id(w, T_POOL_A) {
			_fail(w, "never: placement %v runner %s, want waiting on n3", p.state, id_short(p.runner))
		}
		_up(w, T_POOL_A)
		_settle(w, 3000)
	}
	pool_wait: {
		o, msg, ok := _start(w, tw, "default-pool", .Default, T_POOL_A)
		if !ok {
			break pool_wait
		}
		_down(w, T_POOL_A)
		_settle(w, 5000)
		if x, moved := _ran_off(w, o, msg, T_POOL_A); moved {
			_fail(w, "default pool: the reference scheduler moved the turn to %s", id_short(x))
		}
		if p := _placement(w, o); p.state != .Waiting_Runner || p.runner != _id(w, T_POOL_A) {
			_fail(w, "default pool: placement %v runner %s, want a request naming n3", p.state, id_short(p.runner))
		}
		_up(w, T_POOL_A)
		_settle(w, 3000)
	}
	pool_host: {
		o, msg, ok := _start(w, tw, "default-pool-host", .Default, T_POOL_A)
		if !ok {
			break pool_host
		}
		tw.answer = _id(w, T_POOL_B)
		asked := tw.asked
		_down(w, T_POOL_A)
		x, moved := _wait_moved(w, o, msg, T_POOL_A, 10_000)
		if !moved || x != _id(w, T_POOL_B) {
			n4 := w.nodes[T_POOL_B]
			context = instance_context(&n4.inst)
			cur, last, _ := rt.runner_of(&n4.rt, o)
			info, _ := rt.placement_status(&n4.rt, o)
			active := rt.active_runs(&n4.rt)
			node_after(n4)
			context = w.ctx
			p := _placement(w, o)
			_fail(w, "default pool: the host's answer n4 did not take the turn (moved %v to %s; n4 active %d cur %s last %s placement %v runner %s; n0 placement %v runner %s)", moved, id_short(x), active, id_short(cur), id_short(last), info.state, id_short(info.runner), p.state, id_short(p.runner))
		}
		if tw.asked == asked {
			_fail(w, "default pool: the scheduler plug was never asked")
		}
		tw.answer = {}
		_up(w, T_POOL_A)
		_settle(w, 3000)
	}
	device_host: {
		o, msg, ok := _start(w, tw, "default-device-host", .Default, T_DEV_A)
		if !ok {
			break device_host
		}
		tw.answer = _id(w, T_DEV_B)
		_down(w, T_DEV_A)
		_settle(w, 5000)
		if x, moved := _ran_off(w, o, msg, T_DEV_A); moved {
			_fail(w, "default device: the turn moved to %s because the scheduler said so", id_short(x))
		}
		tw.answer = {}
		_up(w, T_DEV_A)
		_settle(w, 3000)
	}
}


takeover_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = T_NODES
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 3072
	cfg.storage = .Stored
	cfg.durability = .Async
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	main_size, temp_size := region_main_size, region_temp_size
	region_configure(160, 48)
	defer {
		region_main_size, region_temp_size = main_size, temp_size
	}
	w := new(World)
	world_init(w, cfg)
	tw := new(T_World)
	tw.w = w
	_tw = tw
	w.rt_start = _rt_start
	defer {
		_tw = nil
		free(tw)
		world_destroy(w)
		free(w)
	}
	if !relay_start(&w.relay) {
		append(&failures, fmt.aprintf("relay start"))
		return
	}
	for i in 0 ..< T_NODES {
		if !node_start(w.nodes[i]) {
			append(&failures, fmt.aprintf("n%d start", i))
			return
		}
	}
	if _setup(w, tw) {
		_scenario(w, tw)
	}
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	return
}

@(test)
takeover :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	sync.mutex_guard(&serial)
	from: u64 = 1
	count: u64 = 4
	if s, ok := os.lookup_env("SIM_TAKEOVER_SEED", context.temp_allocator); ok && len(s) > 0 {
		from, _ = strconv.parse_u64(s)
		count = 1
	}
	for seed in from ..< from + count {
		fails := takeover_run(seed)
		for f in fails {
			fmt.eprintfln("takeover seed %d: %s", seed, f)
		}
		testing.expect(t, len(fails) == 0, fmt.tprintf("takeover seed %d failed", seed))
		for f in fails {
			delete(f)
		}
		delete(fails)
	}
}

package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fshist"
import "../../src/prim"

@(private = "file")
EC_ROOT :: "/work/event-crash-n0-git"

@(private = "file")
EC_BASE :: "base line\n"

@(private = "file")
EC_KEPT :: "kept line\n"

@(private = "file")
EC_TOOL :: "tool line\n"

@(private = "file")
EC_ONE :: "edit one\n"

@(private = "file")
EC_TWO :: "edit two\n"

@(private = "file")
EC_ROOT_2 :: "/work/event-crash2-n0-git"

@(private = "file")
EC_STEPS_LANDED :: false

@(private = "file")
EC_MORE :: "more line\n"

Event_Crash_Arm :: struct {
	agent:   bool,
	process: bool,
	more:    bool,
}

Event_Crash_Result :: struct {
	crashed: bool,
	typed:   bool,
	events:  int,
	empty:   int,
	landed:  bool,
	open:    bool,
}

@(private = "file")
_ec_world :: proc(seed: u64) -> ^World {
	cfg := default_config(seed)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.durability = .Async
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	return w
}

@(private = "file")
_ec_end :: proc(w: ^World) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ec_mount :: proc(n: ^Node, root: string) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == root && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_ec_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_ec_id :: proc(w: ^World, n: ^Node) -> prim.Id {
	return prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
}

@(private = "file")
_ec_scoped :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, scope: ^fs.Scope, path: string, data: string) -> bool {
	abs := strings.concatenate({sm.root, "/", path}, context.temp_allocator)
	fs.mount_observe_begin(sm.m, path, scope)
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
	if _ec_write(disk_vfs(&n.disk), abs, data) != .None {
		return false
	}
	fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	return true
}

@(private = "file")
Ec_Observed :: struct {
	done: bool,
	err:  fs.Error,
}

@(private = "file")
_ec_observed :: proc(ctx: rawptr, err: fs.Error) {
	o := cast(^Ec_Observed)ctx
	o.done = true
	o.err = err
}

@(private = "file")
_ec_held :: proc(w: ^World, n: ^Node, root: string, actor: prim.Id, path: string, data: string) -> bool {
	context = instance_context(&n.inst)
	sm := _ec_mount(n, root)
	scope := _ec_open(w, n, sm, actor)
	obs: Ec_Observed
	if fs.mount_observe_begin(sm.m, path, scope, _ec_observed, &obs) != .None {
		return false
	}
	for limit := w.now + 2_000_000_000; !obs.done && w.now < limit; {
		run_until(w, w.now + 10_000_000, true)
		context = instance_context(&n.inst)
	}
	if !obs.done || obs.err != .None || _ec_mount(n, root) != sm {
		return false
	}
	abs := strings.concatenate({root, "/", path}, context.temp_allocator)
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
	if _ec_write(disk_vfs(&n.disk), abs, data) != .None {
		return false
	}
	fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	return true
}

@(private = "file")
_ec_open :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, actor: prim.Id) -> ^fs.Scope {
	return fs.scope_open(n.reg, sm.m, _ec_id(w, n), actor)
}

@(private = "file")
_ec_setup :: proc(w: ^World, roots: []string) -> (tree: eng.Object, ok: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "event crash: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "event-crash")
		if err != .None {
			world_fail(w, "event crash: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "event crash: tree_create: %v", err)
			return
		}
		node_after(n)
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	when_s := clock_wall(&n.clock) / 1_000_000_000
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(EC_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}, {name = "c.txt", data = transmute([]u8)string("main c\n")}}
	for root in roots {
		if err := git_checkout_create(vfs, root, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
			world_fail(w, "event crash: git checkout: %v", err)
			return
		}
		if err := node_mount(w, n, oi, root); err != .None {
			world_fail(w, "event crash: mount %s: %v", root, err)
			return
		}
		append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(root, w.allocator)})
		run_until(w, w.now + 2_000_000_000, true)
	}
	return tree, true
}

@(private = "file")
_ec_behind :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, kept, tool: string) -> bool {
	hold := _ec_open(w, n, sm, _ec_id(w, n))
	fs.scope_write_begin(hold, "a.txt")
	reader := _ec_open(w, n, sm, _ec_id(w, n))
	fs.scope_read_base(reader, "a.txt", transmute([]u8)string(EC_BASE))
	if !fs.scope_pinned(reader, "a.txt") {
		return false
	}
	return _ec_scoped(w, n, sm, _ec_open(w, n, sm, _ec_id(w, n)), "a.txt", strings.concatenate({EC_BASE, kept}, context.temp_allocator)) && _ec_scoped(w, n, sm, reader, "a.txt", strings.concatenate({EC_BASE, tool}, context.temp_allocator))
}

event_crash_run :: proc(seed: u64, arm: Event_Crash_Arm, crash_at: u64) -> (failures: [dynamic]string, res: Event_Crash_Result) {
	w := _ec_world(seed)
	res = _event_crash(w, arm, crash_at)
	return _ec_end(w), res
}

@(private = "file")
_event_crash :: proc(w: ^World, arm: Event_Crash_Arm, crash_at: u64) -> (res: Event_Crash_Result) {
	tree, ok := _ec_setup(w, []string{EC_ROOT})
	if !ok {
		return
	}
	n := w.nodes[0]
	vfs := disk_vfs(&n.disk)
	owner, pseudo := _ec_id(w, n), _ec_id(w, n)
	agent: prim.Id
	before: fs.Version
	named: {
		context = instance_context(&n.inst)
		sm := _ec_mount(n, EC_ROOT)
		agent = fshist.ingestion_actor(sm.m.history.self, pseudo)
		if sm == nil || fs.history_register_owned_actor(sm.m.history, agent, pseudo, owner) != .None || !_ec_behind(w, n, sm, EC_KEPT, EC_TOOL) {
			world_fail(w, "event crash: the named version")
			return
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	start: {
		context = instance_context(&n.inst)
		v, err := eng.tree_version(&n.e, tree, "main", w.allocator)
		if err != .None {
			world_fail(w, "event crash: version: %v", err)
			return
		}
		before = v
	}
	block: {
		context = instance_context(&n.inst)
		sm := _ec_mount(n, EC_ROOT)
		if (arm.agent && !_ec_scoped(w, n, sm, _ec_open(w, n, sm, agent), "b.txt", "main b\nraised\n")) || (!arm.agent && _ec_write(vfs, EC_ROOT + "/b.txt", "main b\nraised\n") != .None) {
			world_fail(w, "event crash: b.txt")
			return
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	crashes := w.stats.crashes
	edit: {
		context = instance_context(&n.inst)
		text :: EC_BASE + EC_TOOL + EC_ONE + EC_TWO
		if (arm.agent && !_ec_held(w, n, EC_ROOT, agent, "a.txt", text)) || (!arm.agent && _ec_write(vfs, EC_ROOT + "/a.txt", text) != .None) {
			world_fail(w, "event crash: the edit")
			return
		}
		n.disk.force_process = arm.process
		n.disk.crash_at = n.disk.stats.ops + crash_at
		node_after(n)
	}
	for limit := w.now + 20_000_000_000; arm.more && w.now < limit && !res.typed; {
		t, more := next_time(w)
		if !more {
			break
		}
		run_until(w, t, false)
		if w.stats.crashes > crashes && n.alive && n.e_open {
			context = instance_context(&n.inst)
			n.disk.probe += 1
			have, herr := prim.read_file(vfs, EC_ROOT + "/a.txt", context.temp_allocator)
			n.disk.probe -= 1
			if herr == .None && strings.contains(string(have), EC_TWO) {
				res.typed = _ec_write(vfs, EC_ROOT + "/a.txt", strings.concatenate({string(have), EC_MORE}, context.temp_allocator)) == .None
				node_after(n)
			}
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	res.crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "event crash: node did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	sm := _ec_mount(n, EC_ROOT)
	data, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if rerr != .None || sm == nil {
		world_fail(w, "event crash: read: %v", rerr)
		return
	}
	for line in ([]string{EC_BASE, EC_KEPT, EC_TOOL, EC_ONE, EC_TWO, EC_MORE}) {
		want := 0 if line == EC_MORE && !res.typed else 1
		if c := strings.count(string(data), line); c != want {
			world_fail(w, "event crash: %v: %q appears %d times, want %d (%q), at disk op %d", arm, strings.trim_space(line), c, want, string(data), crash_at)
		}
	}
	set: []prim.Id
	serr: fs.Error
	if arm.agent {
		set, serr = fs.history_owned_actors(sm.m.history, []prim.Id{owner}, context.temp_allocator)
	} else {
		set, serr = fs.history_mount_actors(sm.m.history, []prim.Id{sm.m.id}, []string{sm.m.line}, context.temp_allocator)
	}
	if serr != .None {
		world_fail(w, "event crash: the undo's actors: %v", serr)
		return
	}
	for a in set {
		if a == agent || a == sm.m.actor {
			continue
		}
		known := crdt.graph_known(&sm.m.history.g, a)
		res.events += 1 if known > 0 else 0
		res.empty += 1 if known == 0 else 0
	}
	if len(w.failures) > 0 {
		return
	}
	was := strings.clone(string(data), context.temp_allocator)
	if _, uerr := eng.tree_revert_set(&n.e, tree, before, set, "main"); uerr != .None {
		world_fail(w, "event crash: undo: %v", uerr)
		return
	}
	want := was
	gone := [3]string{EC_ONE, EC_TWO, EC_MORE if !arm.agent else ""}
	for line in gone {
		if len(line) > 0 {
			want, _ = strings.replace_all(want, line, "", context.temp_allocator)
		}
	}
	now, nerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	res.landed = nerr == .None && string(now) == want
	if !res.landed && arm.agent && nerr == .None && (!arm.process || !EC_STEPS_LANDED) {
		res.open = true
	} else if !res.landed {
		world_fail(w, "event crash: %v: the undo left %q (%v), want %q, at disk op %d", arm, string(now), nerr, want, crash_at)
	}
	return
}

event_two_mounts_run :: proc(seed: u64, blocked: bool) -> (failures: [dynamic]string, events: u64, count: int) {
	w := _ec_world(seed)
	events, count = _event_two(w, blocked)
	return _ec_end(w), events, count
}

@(private = "file")
_event_two :: proc(w: ^World, blocked: bool) -> (events: u64, count: int) {
	roots := [2]string{EC_ROOT, EC_ROOT_2}
	tree, ok := _ec_setup(w, roots[:])
	if !ok {
		return
	}
	n := w.nodes[0]
	vfs := disk_vfs(&n.disk)
	kept := [2]string{EC_KEPT, "kept second\n"}
	tool := [2]string{EC_TOOL, "tool second\n"}
	named: {
		context = instance_context(&n.inst)
		for root, i in roots {
			sm := _ec_mount(n, root)
			if sm == nil || !_ec_behind(w, n, sm, kept[i], tool[i]) {
				world_fail(w, "two mounts: the named version in %s", root)
				return
			}
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	if blocked {
		for root, i in roots {
			name := "/b.txt" if i == 0 else "/c.txt"
			text := "main b\nraised\n" if i == 0 else "main c\nraised\n"
			block: {
				context = instance_context(&n.inst)
				if _ec_write(vfs, strings.concatenate({root, name}, context.temp_allocator), text) != .None {
					world_fail(w, "two mounts: %s", name)
					return
				}
				node_after(n)
			}
			run_until(w, w.now + 2_000_000_000, true)
		}
	}
	for root, i in roots {
		edit: {
			context = instance_context(&n.inst)
			if _ec_write(vfs, strings.concatenate({root, "/a.txt"}, context.temp_allocator), strings.concatenate({EC_BASE, tool[i], EC_ONE}, context.temp_allocator)) != .None {
				world_fail(w, "two mounts: the edit in %s", root)
				return
			}
			node_after(n)
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	for root in roots {
		if sm := _ec_mount(n, root); sm != nil {
			events += sm.m.event_actors
		}
	}
	data, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if rerr != .None {
		world_fail(w, "two mounts: read: %v", rerr)
		return
	}
	for line in ([]string{EC_BASE, kept[0], kept[1], tool[0], tool[1]}) {
		if c := strings.count(string(data), line); c != 1 {
			world_fail(w, "two mounts: blocked=%v: %q appears %d times (%q)", blocked, strings.trim_space(line), c, string(data))
		}
	}
	count = strings.count(string(data), EC_ONE)
	if count != 2 {
		world_fail(w, "two mounts: blocked=%v: each mount's own edit must stay: %q appears %d times (%q)", blocked, strings.trim_space(EC_ONE), count, string(data))
	}
	return
}

@(test)
event_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for bits in 0 ..< 8 {
		arm := Event_Crash_Arm{agent = bits & 1 != 0, process = bits & 2 != 0, more = bits & 4 != 0}
		points, typed, bad, empty, most, open := 0, 0, 0, 0, 0, 0
		for k in u64(1) ..= 3000 {
			failures, res := event_crash_run(1, arm, k)
			for f in failures {
				if bad < 3 {
					fmt.eprintf("event_crash: %s\n", f)
				}
				delete(f)
			}
			bad += 1 if len(failures) > 0 else 0
			typed += 1 if res.typed else 0
			open += 1 if res.open else 0
			empty += 1 if res.empty > 0 else 0
			most = max(most, res.events)
			delete(failures)
			if !res.crashed {
				break
			}
			points += 1
		}
		fmt.eprintf("event_crash: %v: points=%d typed_after=%d runs_with_an_empty_actor=%d most_event_actors=%d undo_open=%d failed=%d\n", arm, points, typed, empty, most, open, bad)
		testing.expect(t, bad == 0, fmt.tprintf("event_crash %v failed", arm))
		testing.expect(t, most > 0 && (!arm.more || typed > 0), "event_crash: nothing used an event actor, or nobody typed")
	}
}

@(test)
event_two_mounts :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for blocked in ([]bool{false, true}) {
		bad, used := 0, 0
		for seed in u64(1) ..= 20 {
			failures, events, _ := event_two_mounts_run(seed, blocked)
			for f in failures {
				if bad < 2 {
					fmt.eprintf("event_two_mounts seed %d: %s\n", seed, f)
				}
				delete(f)
			}
			bad += 1 if len(failures) > 0 else 0
			used += 1 if events > 0 else 0
			delete(failures)
		}
		fmt.eprintf("event_two_mounts: blocked=%v: %d of 20 used an event actor, %d failed\n", blocked, used, bad)
		testing.expect(t, bad == 0, "event_two_mounts failed")
		testing.expect(t, !blocked || used > 0, "event_two_mounts: no blocked run used an event actor")
	}
}

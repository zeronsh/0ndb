package sim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
ST_ROOT :: "/work/snapshot-turn-n0-git"

@(private = "file")
ST_BASE :: "base line\n"

@(private = "file")
ST_EDIT :: "person line\n"

@(private = "file")
ST_B :: "b base\n"

@(private = "file")
ST_AGENT :: "agent one\nagent two\n"

Snapshot_Turn_Result :: struct {
	reached: bool,
	credited: bool,
}

snapshot_turn_run :: proc(seed: u64, step: int) -> (failures: [dynamic]string, res: Snapshot_Turn_Result) {
	failures = make([dynamic]string)
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
	res = _snapshot_turn(w, step)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_st_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == ST_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_st_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_snapshot_turn :: proc(w: ^World, step: int) -> (res: Snapshot_Turn_Result) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "snapshot turn: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "snapshot-turn")
		if err != .None {
			world_fail(w, "snapshot turn: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "snapshot turn: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(ST_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, ST_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "snapshot turn: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, ST_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "snapshot turn: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, ST_ROOT); err != .None {
		world_fail(w, "snapshot turn: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(ST_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _st_write(vfs, ST_ROOT + "/b.txt", ST_B) != .None {
		world_fail(w, "snapshot turn: b.txt")
		return
	}
	bset: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	open :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, actor: prim.Id) -> ^fs.Scope {
		return fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), actor)
	}
	person: {
		context = instance_context(&n.inst)
		sm := _st_mount(n)
		if sm == nil {
			world_fail(w, "snapshot turn: mount missing")
			return
		}
		hold := open(w, n, sm, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		fs.scope_write_begin(hold, "a.txt")
		if _st_write(vfs, ST_ROOT + "/a.txt", ST_BASE + ST_EDIT) != .None {
			world_fail(w, "snapshot turn: person's edit")
			return
		}
		node_after(n)
	}
	for _ in 0 ..< step {
		t, ok := next_time(w)
		if !ok {
			break
		}
		run_until(w, t, false)
	}
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	before: []crdt.Op_Id
	turn: {
		context = instance_context(&n.inst)
		sm := _st_mount(n)
		if sm == nil {
			world_fail(w, "snapshot turn: mount missing at the agent's turn")
			return
		}
		before = slice.clone(_line_heads(sm.m), w.allocator)
		scope := open(w, n, sm, agent)
		fs.scope_read_base(scope, "b.txt", transmute([]u8)string(ST_B))
		fs.mount_observe_begin(sm.m, "b.txt", scope)
		_writer_set(w, n, ST_ROOT + "/b.txt", Writer_Info{scope = scope, agent = true})
		if _st_write(vfs, ST_ROOT + "/b.txt", ST_B + ST_AGENT) != .None {
			world_fail(w, "snapshot turn: the agent's write")
			return
		}
		fs.scope_close(n.reg, scope)
		_forget_scope(w, n, scope)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	sm := _st_mount(n)
	if sm == nil {
		world_fail(w, "snapshot turn: mount missing at the end")
		return
	}
	data, spans, berr := eng.tree_blame(&n.e, tree, "b.txt", context.temp_allocator, "main")
	if berr != .None || string(data) != ST_B + ST_AGENT {
		world_fail(w, "snapshot turn: b.txt on main is %q (%v), step %d", string(data), berr, step)
		return
	}
	agent_bytes := 0
	for sp in spans {
		if sp.id.actor == agent {
			agent_bytes += sp.len
		}
	}
	res.credited = agent_bytes == len(ST_AGENT)
	after := slice.clone(_line_heads(sm.m), w.allocator)
	if rerr := fs.mount_revert(sm.m, fs.Version(before), fs.Version(after), agent); rerr != .None {
		world_fail(w, "snapshot turn: undo of the agent's turn failed: %v, step %d", rerr, step)
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	b2, _ := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator, {}, "main")
	a2, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if string(b2) != ST_B {
		world_fail(w, "snapshot turn: after the turn's undo b.txt on main is %q, want %q (agent credited %d of %d bytes), step %d", string(b2), ST_B, agent_bytes, len(ST_AGENT), step)
	}
	if string(a2) != ST_BASE + ST_EDIT {
		world_fail(w, "snapshot turn: the turn's undo changed a.txt to %q, step %d", string(a2), step)
	}
	return
}

@(test)
snapshot_turn :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad, credited := 0, 0
	for step in 0 ..< 60 {
		failures, res := snapshot_turn_run(1, step)
		for f in failures {
			fmt.eprintf("snapshot_turn: %s\n", f)
			delete(f)
		}
		bad += 1 if len(failures) > 0 else 0
		credited += 1 if res.credited else 0
		delete(failures)
	}
	fmt.eprintf("snapshot_turn: 60 steps, %d failed, %d with the agent credited for all its bytes\n", bad, credited)
	testing.expect(t, bad == 0, "snapshot_turn: the turn's undo did not remove exactly the agent's bytes")
}

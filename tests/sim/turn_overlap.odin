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
TV_ROOT :: "/work/turn-overlap-n0-git"

@(private = "file")
TV_BASE :: "base line\n"

@(private = "file")
TV_EDIT :: "person line\n"

@(private = "file")
TV_B :: "b base\n"

@(private = "file")
TV_AGENT :: "agent one\nagent two\n"

@(private = "file")
_tv_run :: proc(seed: u64, step: int) -> (failures: [dynamic]string) {
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
	_tv_case(w, step)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_tv_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == TV_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_tv_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_tv_case :: proc(w: ^World, step: int) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "turn overlap: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "turn-overlap")
		if err != .None {
			world_fail(w, "turn overlap: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "turn overlap: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(TV_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, TV_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "turn overlap: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, TV_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "turn overlap: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, TV_ROOT); err != .None {
		world_fail(w, "turn overlap: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(TV_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _tv_write(vfs, TV_ROOT + "/b.txt", TV_B) != .None {
		world_fail(w, "turn overlap: b.txt")
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
	hold: ^fs.Scope
	person: {
		context = instance_context(&n.inst)
		sm := _tv_mount(n)
		if sm == nil {
			world_fail(w, "turn overlap: mount missing")
			return
		}
		hold = open(w, n, sm, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		fs.scope_write_begin(hold, "a.txt")
		if _tv_write(vfs, TV_ROOT + "/a.txt", TV_BASE + TV_EDIT) != .None {
			world_fail(w, "turn overlap: person's edit")
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
		sm := _tv_mount(n)
		if sm == nil {
			world_fail(w, "turn overlap: mount missing at the agent's turn")
			return
		}
		before = slice.clone(_line_heads(sm.m), w.allocator)
		scope := open(w, n, sm, agent)
		fs.scope_read_base(scope, "b.txt", transmute([]u8)string(TV_B))
		fs.mount_observe_begin(sm.m, "b.txt", scope)
		_writer_set(w, n, TV_ROOT + "/b.txt", Writer_Info{scope = scope, agent = true})
		if _tv_write(vfs, TV_ROOT + "/b.txt", TV_B + TV_AGENT) != .None {
			world_fail(w, "turn overlap: the agent's write")
			return
		}
		fs.scope_close(n.reg, scope)
		_forget_scope(w, n, scope)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	hold_end: {
		context = instance_context(&n.inst)
		defer node_after(n)
		fs.scope_write_end(hold, "a.txt")
		fs.scope_close(n.reg, hold)
	}
	run_until(w, w.now + 2_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	sm := _tv_mount(n)
	if sm == nil {
		world_fail(w, "turn overlap: mount missing at the end")
		return
	}
	data, _, berr := eng.tree_blame(&n.e, tree, "b.txt", context.temp_allocator, "main")
	if berr != .None || string(data) != TV_B + TV_AGENT {
		world_fail(w, "turn overlap: b.txt on main is %q (%v), step %d", string(data), berr, step)
		return
	}
	_, aspans, aerr := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, "main")
	if aerr != .None {
		world_fail(w, "turn overlap: blame a.txt: %v, step %d", aerr, step)
		return
	}
	for sp in aspans {
		if sp.id.actor == agent {
			world_fail(w, "turn overlap: %d bytes of a.txt are credited to the agent that opened later, step %d", sp.len, step)
		}
	}
	if _, rerr := fs.mount_revert_set(sm.m, fs.Version(before), []prim.Id{agent}); rerr != .None {
		world_fail(w, "turn overlap: undo of the agent's turn failed: %v, step %d", rerr, step)
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	b2, _ := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator, {}, "main")
	a2, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if string(b2) != TV_B {
		world_fail(w, "turn overlap: after the turn's undo b.txt on main is %q, want %q, step %d", string(b2), TV_B, step)
	}
	if string(a2) != TV_BASE + TV_EDIT {
		world_fail(w, "turn overlap: the turn's undo changed a.txt to %q, step %d", string(a2), step)
	}
	n.disk.probe += 1
	disk, _ := prim.read_file(vfs, TV_ROOT + "/a.txt", context.temp_allocator)
	n.disk.probe -= 1
	if string(disk) != TV_BASE + TV_EDIT {
		world_fail(w, "turn overlap: after the turn's undo a.txt on disk is %q, step %d", string(disk), step)
	}
}

@(test)
turn_overlap :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad := 0
	for step in 0 ..< 60 {
		failures := _tv_run(1, step)
		for f in failures {
			fmt.eprintf("turn_overlap: %s\n", f)
			delete(f)
		}
		bad += 1 if len(failures) > 0 else 0
		delete(failures)
	}
	fmt.eprintf("turn_overlap: 60 steps, %d failed\n", bad)
	testing.expect(t, bad == 0, "turn_overlap: the turn's undo did not remove exactly the agent's bytes")
}

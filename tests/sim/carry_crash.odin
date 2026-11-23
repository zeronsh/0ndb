package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

CARRY_ROOT :: "/work/carry-n0-git"

carry_crash_run :: proc(seed: u64, crash_at: u64) -> (failures: [dynamic]string, crashed: bool) {
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
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	crashed = _carry_crash(w, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_carry_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == CARRY_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_carry_crash :: proc(w: ^World, crash_at: u64) -> (crashed: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "carry: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "carry")
		if err != .None {
			world_fail(w, "carry: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "carry: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("shared a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, CARRY_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}}
	if err := git_branch_commit(vfs, CARRY_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, CARRY_ROOT); err != .None {
		world_fail(w, "carry: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(CARRY_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, CARRY_ROOT, "feature", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "carry: checkout feature: %v %v", res, err)
		return
	}
	after: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	{
		context = instance_context(&n.inst)
		sm := _carry_mount(n)
		if sm == nil || fs.mount_line(sm.m) != "git:refs/heads/feature" {
			world_fail(w, "carry: the mount did not follow feature")
			return
		}
		scope := sim_scope_open(w, n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		if oerr := fs.mount_observe_begin(sm.m, "a.txt", scope); oerr != .None {
			world_fail(w, "carry: observe: %v", oerr)
			return
		}
		if werr := _carry_write(vfs, CARRY_ROOT + "/a.txt", transmute([]u8)string("shared a\nagent line\n")); werr != .None {
			world_fail(w, "carry: agent write: %v", werr)
			return
		}
		if serr := fs.scope_close(n.reg, scope); serr != .None {
			world_fail(w, "carry: scope close: %v", serr)
			return
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	crashes := w.stats.crashes
	n.disk.crash_at = n.disk.stats.ops + crash_at
	back := make([dynamic]Git_Change, context.temp_allocator)
	res, cerr := git_checkout(vfs, CARRY_ROOT, "main", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &back)
	if !n.disk.dead && (res != .Done || cerr != .None) {
		world_fail(w, "carry: checkout main: %v %v", res, cerr)
		return
	}
	step: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "carry: node did not come back")
		return
	}
	sm := _carry_mount(n)
	if sm == nil {
		world_fail(w, "carry: mount missing after recovery")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	head, _ := prim.read_file(vfs, CARRY_ROOT + "/.git/HEAD", context.temp_allocator)
	if strings.trim_space(string(head)) != "ref: refs/heads/main" {
		return
	}
	data, spans, berr := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, "main")
	if berr != .None {
		world_fail(w, "carry: blame a.txt on main: %v", berr)
		return
	}
	disk, _ := prim.read_file(vfs, CARRY_ROOT + "/a.txt", context.temp_allocator)
	if string(data) != string(disk) {
		world_fail(w, "carry: a.txt on main is %q, disk %q", string(data), string(disk))
	}
	for sp in spans {
		if sp.id.actor == agent {
			world_fail(w, "carry: a.txt on main credits %d bytes git carried to the agent's scope %s", sp.len, id_short(agent))
		}
	}
	return
}

@(test)
line_carry_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for k in u64(1) ..= 4000 {
		failures, crashed := carry_crash_run(1, k)
		for f in failures {
			fmt.eprintf("line_carry_crash at disk op %d: %s\n", k, f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0, fmt.tprintf("line_carry_crash at disk op %d failed", k))
		delete(failures)
		if !crashed {
			fmt.eprintf("line_carry_crash: %d crash points\n", k - 1)
			return
		}
	}
	testing.expect(t, false, "line_carry_crash: the checkout never completed without a crash")
}

@(private = "file")
_carry_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

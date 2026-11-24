package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
RK_ROOT :: "/work/rk-n0-git"

@(private = "file")
RK_FEATURE :: "git:refs/heads/feature"

@(private = "file")
RK_BASE :: "base line\n"

@(private = "file")
RK_OTHER :: "other line\n"

@(private = "file")
_rk_checkout :: proc(w: ^World, n: ^Node, branch: string) -> bool {
	changes := make([dynamic]Git_Change, context.temp_allocator)
	res, err := git_checkout(disk_vfs(&n.disk), RK_ROOT, branch, false, clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng), &changes)
	after: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 4_000_000_000, true)
	return res == .Done && err == .None
}

@(private = "file")
_rk_count :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (c: int, text: string) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.tree_read(&n.e, tree, "a.txt", w.allocator, {}, RK_FEATURE)
	if err != .None {
		return -1, fmt.tprintf("%v", err)
	}
	return strings.count(string(data), RK_OTHER), string(data)
}

@(private = "file")
_retarget_keep :: proc(w: ^World) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "retarget: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "retarget")
		if err != .None {
			world_fail(w, "retarget: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "retarget: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(RK_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if git_checkout_create(vfs, RK_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)) != .None ||
	   git_branch_commit(vfs, RK_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)) != .None {
		world_fail(w, "retarget: git setup")
		return
	}
	if err := node_mount(w, n, oi, RK_ROOT); err != .None {
		world_fail(w, "retarget: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(RK_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if !_rk_checkout(w, n, "feature") || !_rk_checkout(w, n, "main") {
		world_fail(w, "retarget: round trip")
		return
	}
	other: {
		context = instance_context(&n.inst)
		defer node_after(n)
		base, _ := eng.tree_version(&n.e, tree, RK_FEATURE, context.temp_allocator)
		if err := eng.tree_write(&n.e, tree, "a.txt", transmute([]u8)string(RK_BASE + RK_OTHER), base, RK_FEATURE); err != .None {
			world_fail(w, "retarget: tree_write on feature: %v", err)
			return
		}
	}
	run_until(w, w.now + 4_000_000_000, true)
	if c, text := _rk_count(w, n, tree); c != 1 {
		world_fail(w, "retarget: the write is not on feature before the checkout (%q)", text)
		return
	}
	if !_rk_checkout(w, n, "feature") {
		world_fail(w, "retarget: checkout feature")
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	c, text := _rk_count(w, n, tree)
	if c != 1 {
		world_fail(w, "retarget: the acked write appears %d times on feature after the checkout (%q)", c, text)
	}
	disk, derr := prim.read_file(vfs, RK_ROOT + "/a.txt", context.temp_allocator)
	if derr != .None || string(disk) != text {
		world_fail(w, "retarget: a.txt on disk is %q (%v), feature %q", string(disk), derr, text)
	}
}

@(test)
retarget_keep :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	cfg := default_config(1)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	w := new(World)
	world_init(w, cfg)
	_retarget_keep(w)
	for f in w.failures {
		fmt.eprintf("retarget_keep: %s\n", f)
	}
	testing.expect(t, len(w.failures) == 0, "retarget_keep failed")
	world_destroy(w)
	free(w)
}

package sim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/odb"
import "../../src/prim"

LINE_COMMIT_ROOT :: "/work/line-commit-n0-git"

line_commit_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_line_commit(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_line_commit :: proc(w: ^World) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "line_commit: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "lc")
		if err != .None {
			world_fail(w, "line_commit: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "line_commit: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("main a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\nshared\n")}}
	if err := git_checkout_create(vfs, LINE_COMMIT_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "line_commit: git checkout: %v", err)
		return
	}
	feature := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\nshared\n")}, {name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	removed := [?]string{"a.txt"}
	if err := git_branch_commit(vfs, LINE_COMMIT_ROOT, "feature", feature[:], removed[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "line_commit: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, LINE_COMMIT_ROOT); err != .None {
		world_fail(w, "line_commit: mount: %v", err)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	sm := n.mounts[len(n.mounts) - 1]
	ref, _ := prim.read_file(vfs, LINE_COMMIT_ROOT + "/.git/refs/heads/feature", context.temp_allocator)
	head, lerr := fs.line_from_commit(sm.m, "git:refs/heads/feature", fs.mount_synced(sm.m), strings.trim_space(string(ref)), "refs/heads/feature")
	if lerr != .None {
		world_fail(w, "line_commit: line_from_commit: %v", lerr)
		return
	}
	if len(head) == 0 {
		world_fail(w, "line_commit: no head")
	}
	want := [?][2]string{{"b.txt", "feature b\nshared\n"}, {"c.txt", "feature c\n"}}
	names, nerr := eng.tree_list(&n.e, tree, "", context.temp_allocator, {}, "git:refs/heads/feature")
	if nerr != .None {
		world_fail(w, "line_commit: list: %v", nerr)
		return
	}
	slice.sort(names)
	if fmt.tprint(names) != fmt.tprint([]string{"b.txt", "c.txt"}) {
		world_fail(w, "line_commit: feature lists %v", names)
	}
	for pw in want {
		p, text := pw[0], pw[1]
		data, rerr := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, "git:refs/heads/feature")
		if rerr != .None || string(data) != text {
			world_fail(w, "line_commit: feature %s is %q (%v), want %q", p, string(data), rerr, text)
		}
	}
	main_names, _ := eng.tree_list(&n.e, tree, "", context.temp_allocator, {}, "main")
	slice.sort(main_names)
	if fmt.tprint(main_names) != fmt.tprint([]string{"a.txt", "b.txt"}) {
		world_fail(w, "line_commit: main lists %v", main_names)
	}
	data, _ := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator, {}, "main")
	if string(data) != "main b\nshared\n" {
		world_fail(w, "line_commit: main b.txt is %q", string(data))
	}
	blame, spans, berr := eng.tree_blame(&n.e, tree, "b.txt", context.temp_allocator, "git:refs/heads/feature")
	if berr != .None || len(spans) == 0 || string(blame) != "feature b\nshared\n" {
		world_fail(w, "line_commit: blame %q %d %v", string(blame), len(spans), berr)
	}
	_ = odb.Oid{}
}

@(test)
line_from_commit_lines :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := line_commit_run(1)
	for f in failures {
		fmt.eprintf("line_from_commit: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "line_from_commit failed")
	delete(failures)
}

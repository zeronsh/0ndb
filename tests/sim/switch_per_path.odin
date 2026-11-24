package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
PP_ROOT :: "/work/per-path-n0-git"

@(private = "file")
PP_FEATURE :: "git:refs/heads/feature"

@(private = "file")
PP_BASE :: "base line\n"

@(private = "file")
PP_DIRTY :: "main uncommitted line\n"

@(private = "file")
PP_EDIT :: "edit line\n"

Per_Path_Result :: struct {
	crashed: bool,
	edited:  bool,
	unwritten: bool,
}

switch_per_path_run :: proc(seed: u64, process: bool, crash_at: u64) -> (failures: [dynamic]string, res: Per_Path_Result) {
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
	res = _per_path(w, process, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_pp_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == PP_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_pp_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_per_path :: proc(w: ^World, process: bool, crash_at: u64) -> (res: Per_Path_Result) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "switch per path: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "switch-per-path")
		if err != .None {
			world_fail(w, "switch per path: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "switch per path: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(PP_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, PP_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "switch per path: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, PP_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "switch per path: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, PP_ROOT); err != .None {
		world_fail(w, "switch per path: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(PP_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _pp_write(vfs, PP_ROOT + "/a.txt", PP_BASE + PP_DIRTY) != .None {
		world_fail(w, "switch per path: dirty write")
		return
	}
	dirty: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	crashes := w.stats.crashes
	n.disk.force_process = process
	n.disk.crash_at = n.disk.stats.ops + crash_at
	begin: {
		context = instance_context(&n.inst)
		if sm := _pp_mount(n); sm != nil {
			fs.mount_line_switch(sm.m, PP_FEATURE)
		}
		node_after(n)
	}
	for limit := w.now + 20_000_000_000; w.now < limit && !res.edited; {
		t, ok := next_time(w)
		if !ok {
			break
		}
		run_until(w, t, false)
		if w.stats.crashes == crashes || !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		sm := _pp_mount(n)
		if sm == nil {
			continue
		}
		if _, pending := fs.mount_switch_pending(sm.m); !pending || sm.m.switch_phase < fs.SWITCH_TARGET {
			continue
		}
		n.disk.probe += 1
		have, herr := prim.read_file(vfs, PP_ROOT + "/a.txt", context.temp_allocator)
		n.disk.probe -= 1
		if herr != .None || string(have) != PP_BASE + PP_DIRTY {
			continue
		}
		res.unwritten = true
		res.edited = _pp_write(vfs, PP_ROOT + "/a.txt", PP_BASE + PP_DIRTY + PP_EDIT) == .None
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	res.crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "switch per path: node did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	on_main, merr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	on_feat, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, PP_FEATURE)
	if merr != .None || strings.count(string(on_main), PP_DIRTY) != 1 {
		world_fail(w, "switch per path: main's uncommitted line appears %d times on main (%v %q), at disk op %d", strings.count(string(on_main), PP_DIRTY), merr, string(on_main), crash_at)
	}
	if strings.contains(string(on_feat), PP_DIRTY) {
		world_fail(w, "switch per path: main's uncommitted line leaked onto feature (%q), at disk op %d", string(on_feat), crash_at)
	}
	if res.edited && (strings.count(string(on_main), PP_EDIT) != 1 || strings.contains(string(on_feat), PP_EDIT)) {
		world_fail(w, "switch per path: an edit of a path the switch had not written is on main %d times and on feature %d times, at disk op %d", strings.count(string(on_main), PP_EDIT), strings.count(string(on_feat), PP_EDIT), crash_at)
	}
	return
}

@(test)
switch_per_path :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for process in ([]bool{false, true}) {
		points, edited, bad, bad_unedited := 0, 0, 0, 0
		for k in u64(1) ..= 4000 {
			failures, res := switch_per_path_run(1, process, k)
			for f in failures {
				fmt.eprintf("switch_per_path: %s\n", f)
				delete(f)
			}
			if len(failures) > 0 {
				bad += 1
				bad_unedited += 0 if res.edited else 1
			}
			edited += 1 if res.edited else 0
			delete(failures)
			if !res.crashed {
				break
			}
			points += 1
		}
		fmt.eprintf("switch_per_path: process=%v: points=%d edited=%d failed=%d (%d with no edit)\n", process, points, edited, bad, bad_unedited)
		testing.expect(t, edited > 0, "switch_per_path: no run edited a path the switch had not written")
		testing.expect(t, bad == 0, "switch_per_path: an edit during a switch left the line whose text the disk held")
	}
}

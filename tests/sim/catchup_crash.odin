package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

CATCHUP_ROOT :: "/work/catchup-n0"

catchup_crash_run :: proc(seed: u64, crash_at: u64) -> (failures: [dynamic]string, crashed: bool) {
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
	crashed = _catchup_crash(w, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_catchup_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == CATCHUP_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_catchup_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_catchup_crash :: proc(w: ^World, crash_at: u64) -> (crashed: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "catchup: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "catchup")
		if err != .None {
			world_fail(w, "catchup: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "catchup: tree_create: %v", err)
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
	prim.mkdir_all(vfs, CATCHUP_ROOT, 0o755)
	if err := node_mount(w, n, oi, CATCHUP_ROOT); err != .None {
		world_fail(w, "catchup: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(CATCHUP_ROOT, w.allocator)})
	_catchup_write(vfs, CATCHUP_ROOT + "/a.txt", "L0\n")
	first: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 5_000_000_000, true)
	commit: {
		context = instance_context(&n.inst)
		sm := _catchup_mount(n)
		if sm == nil {
			world_fail(w, "catchup: mount missing")
			return
		}
		_catchup_write(vfs, CATCHUP_ROOT + "/a.txt", "L0\nL1\nL2\n")
		fs.mount_mark_rescan(sm.m)
		if perr := fs.mount_pass(sm.m, true); perr != .None {
			world_fail(w, "catchup: pass: %v", perr)
			return
		}
	}
	edited := "L0\nL1\nL3\n"
	_catchup_write(vfs, CATCHUP_ROOT + "/a.txt", edited)
	crashes := w.stats.crashes
	n.disk.crash_at = n.disk.stats.ops + crash_at
	arm: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "catchup: node did not come back")
		return
	}
	check: {
		context = instance_context(&n.inst)
		defer node_after(n)
		disk, _ := prim.read_file(vfs, CATCHUP_ROOT + "/a.txt", context.temp_allocator)
		if string(disk) != edited {
			world_fail(w, "catchup: the person's edit was overwritten: a.txt is %q, written %q", string(disk), edited)
		}
		data, terr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator)
		if terr != .None || string(data) != string(disk) {
			world_fail(w, "catchup: a.txt in history is %q (%v), disk %q", string(data), terr, string(disk))
		}
		for line in ([]string{"L0\n", "L1\n", "L3\n"}) {
			if c := strings.count(string(data), line); c != 1 {
				world_fail(w, "catchup: %q appears %d times in a.txt's history", strings.trim_space(line), c)
			}
		}
	}
	return
}

@(test)
catch_up_after_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for k in u64(1) ..= 4000 {
		failures, crashed := catchup_crash_run(1, k)
		for f in failures {
			fmt.eprintf("catch_up_after_crash at disk op %d: %s\n", k, f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0, fmt.tprintf("catch_up_after_crash at disk op %d failed", k))
		delete(failures)
		if !crashed {
			fmt.eprintf("catch_up_after_crash: %d crash points\n", k - 1)
			return
		}
	}
	testing.expect(t, false, "catch_up_after_crash: the run never finished without a crash")
}

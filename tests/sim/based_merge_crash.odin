package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

MERGE_ROOT :: "/work/merge-n0"

based_merge_run :: proc(seed: u64, crash_at: u64, sync_fail: bool) -> (failures: [dynamic]string, crashed: bool) {
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
	crashed = _merge_crash(w, crash_at, sync_fail)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_merge_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == MERGE_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_merge_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_merge_crash :: proc(w: ^World, crash_at: u64, sync_fail: bool) -> (crashed: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "merge: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "merge")
		if err != .None {
			world_fail(w, "merge: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "merge: tree_create: %v", err)
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
	base := "base line\n"
	if prim.mkdir_all(vfs, MERGE_ROOT) != .None || _merge_write(vfs, MERGE_ROOT + "/a.txt", base) != .None {
		world_fail(w, "merge: setup write")
		return
	}
	if err := node_mount(w, n, oi, MERGE_ROOT); err != .None {
		world_fail(w, "merge: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(MERGE_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	typed := "typed line\n"
	tool := "tool line\n"
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	crashes := w.stats.crashes
	pin: {
		context = instance_context(&n.inst)
		sm := _merge_mount(n)
		if sm == nil {
			world_fail(w, "merge: mount missing")
			return
		}
		scope := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		fs.scope_read_base(scope, "a.txt", transmute([]u8)base)
		if !fs.scope_pinned(scope, "a.txt") {
			world_fail(w, "merge: read base did not pin")
			return
		}
		tbase, _ := eng.tree_version(&n.e, tree, "", context.temp_allocator)
		if terr := eng.tree_write(&n.e, tree, "a.txt", transmute([]u8)strings.concatenate({base, typed}, context.temp_allocator), tbase); terr != .None {
			world_fail(w, "merge: tree_write: %v", terr)
			return
		}
		fs.mount_observe_begin(sm.m, "a.txt", scope)
		_writer_set(w, n, MERGE_ROOT + "/a.txt", Writer_Info{scope = scope, agent = true})
		n.disk.crash_at = n.disk.stats.ops + crash_at
		if sync_fail {
			n.disk.fail_sync = 1
			n.disk.fail_sync_root = MERGE_ROOT
			n.disk.fail_sync_dir = sm.m.dir
		}
		if _merge_write(vfs, MERGE_ROOT + "/a.txt", strings.concatenate({base, tool}, context.temp_allocator)) != .None || n.disk.dead {
			break pin
		}
		fs.scope_close(n.reg, scope)
		_forget_scope(w, n, scope)
	}
	n.disk.fail_sync = 0
	n.disk.fail_sync_root = ""
	n.disk.fail_sync_dir = ""
	if n.disk.dead {
		node_crashed(n)
	} else {
		after: {
			context = instance_context(&n.inst)
			node_after(n)
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "merge: node did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	data, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator)
	if rerr != .None {
		world_fail(w, "merge: tree_read: %v", rerr)
		return
	}
	for line in ([]string{base, typed, tool}) {
		if c := strings.count(string(data), line); c > 1 {
			world_fail(w, "merge: %q appears %d times in a.txt (%q), crash at disk op %d, sync fail %v", strings.trim_space(line), c, string(data), crash_at, sync_fail)
		}
	}
	return
}

@(test)
based_merge_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for sync_fail in ([]bool{false, true}) {
		points := 0
		for k in u64(1) ..= 4000 {
			failures, crashed := based_merge_run(1, k, sync_fail)
			for f in failures {
				fmt.eprintf("based_merge_crash at disk op %d (sync fail %v): %s\n", k, sync_fail, f)
				delete(f)
			}
			testing.expect(t, len(failures) == 0, fmt.tprintf("based_merge_crash at disk op %d failed", k))
			delete(failures)
			if !crashed {
				points = int(k) - 1
				break
			}
		}
		fmt.eprintf("based_merge_crash: %d crash points (sync fail %v)\n", points, sync_fail)
	}
}

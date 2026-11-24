package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

MR_ROOT :: "/work/retry"

Mr_Wake :: enum u8 {
	Event,
	Op,
	Sync,
}

@(private = "file")
_mr_run :: proc(w: ^World, wake: Mr_Wake) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "%v: node start", wake)
		return
	}
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "retry")
		if err == .None {
			eng.space_open(&n.e, space)
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		if err != .None {
			world_fail(w, "%v: setup: %v", wake, err)
			return
		}
	}
	m := &w.model
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	prim.mkdir_all(vfs, MR_ROOT, 0o755)
	for name in ([]string{"a.txt", "b.txt"}) {
		p := fmt.tprintf("%s/%s", MR_ROOT, name)
		if fd, oerr := prim.open_file(vfs, p, {.Write, .Create, .Truncate}, 0o644); oerr == .None {
			prim.write_at(vfs, fd, transmute([]u8)string("first\n"), 0)
			prim.close_file(vfs, fd)
		}
	}
	if err := node_mount(w, n, len(m.objs) - 1, MR_ROOT); err != .None {
		world_fail(w, "%v: mount: %v", wake, err)
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	n.disk.fail_root = MR_ROOT
	n.disk.fail_stuck = true
	write :: proc(n: ^Node, tree: eng.Object, name, text: string) -> eng.Error {
		context = instance_context(&n.inst)
		defer node_after(n)
		base: fs.Version
		_, rerr := eng.tree_read(&n.e, tree, name, context.temp_allocator, {}, "", nil, &base)
		if rerr != .None {
			return rerr
		}
		return eng.tree_write(&n.e, tree, name, transmute([]u8)text, base)
	}
	if err := write(n, tree, "a.txt", "acked\n"); err != .None {
		world_fail(w, "%v: CONTROL: the tree write answers %v", wake, err)
		return
	}
	run_until(w, w.now + 3600_000_000_000, true)
	{
		mt: ^fs.Mount
		for x in n.mounts {
			if x.root == MR_ROOT {
				mt = x.m
			}
		}
		if mt == nil {
			world_fail(w, "%v: the mount is gone", wake)
			return
		}
		if mt.step_tries < 2 {
			world_fail(w, "%v: CONTROL: the write never failed (%d tries)", wake, mt.step_tries)
		}
		if mt.step_tries > fs.STEP_RETRY_TRIES + 1 {
			world_fail(w, "%v: %d tries, want at most %d", wake, mt.step_tries, fs.STEP_RETRY_TRIES + 1)
		}
		if prim.timer_pending(mt.reg.loop, mt.timer) {
			world_fail(w, "%v: a timer is armed an hour after the failure", wake)
		}
		if path, err := fs.mount_failed(mt); err == .None || path != "a.txt" {
			world_fail(w, "%v: the failure shows as %q %v", wake, path, err)
		}
	}
	n.disk.fail_stuck = false
	n.disk.fail_root = ""
	run_until(w, w.now + 60_000_000_000, true)
	switch wake {
	case .Event:
		if fd, oerr := prim.open_file(vfs, MR_ROOT + "/b.txt", {.Write, .Create, .Truncate}, 0o644); oerr == .None {
			prim.write_at(vfs, fd, transmute([]u8)string("touched\n"), 0)
			prim.close_file(vfs, fd)
		}
		context = instance_context(&n.inst)
		node_after(n)
	case .Op:
		if err := write(n, tree, "b.txt", "another\n"); err != .None {
			world_fail(w, "%v: the next write answers %v", wake, err)
		}
	case .Sync:
		context = instance_context(&n.inst)
		for x in n.mounts {
			if x.root == MR_ROOT && x.m != nil {
				fs.mount_sync(x.m)
			}
		}
		node_after(n)
	}
	run_until(w, w.now + 60_000_000_000, true)
	n.disk.probe += 1
	disk, derr := prim.read_file(vfs, MR_ROOT + "/a.txt", w.allocator)
	n.disk.probe -= 1
	if derr != .None || string(disk) != "acked\n" {
		world_fail(w, "%v: the acked write is not on disk after the cause is fixed: %q %v", wake, string(disk), derr)
	}
	for x in n.mounts {
		if x.root == MR_ROOT && x.m != nil {
			if path, err := fs.mount_failed(x.m); err != .None {
				world_fail(w, "%v: still marked failed: %q %v", wake, path, err)
			}
		}
	}
}

@(test)
mount_retry :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for wake in Mr_Wake {
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
		_mr_run(w, wake)
		for f in w.failures {
			fmt.eprintf("mount_retry: %s\n", strings.trim_space(f))
		}
		testing.expect(t, len(w.failures) == 0, "mount_retry failed")
		world_destroy(w)
		free(w)
	}
}

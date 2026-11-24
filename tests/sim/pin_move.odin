package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
PM_A :: "/work/move-a"

@(private = "file")
PM_B :: "/work/move-b"

@(private = "file")
PM_ONE :: "one line\n"

@(private = "file")
PM_TWO :: "two line\n"

@(private = "file")
PM_TOOL :: "tool line\n"

Pm_Kind :: enum u8 {
	Rename_Rewrite,
	Swap,
	Remote_Rename,
	Dir_Move_Hold,
}

@(private = "file")
_pm_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_pm_count :: proc(n: ^Node, tree: eng.Object, line: string) -> int {
	total := 0
	names, _ := tree_walk(n, tree, {}, "")
	for nm in names {
		d, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator)
		total += strings.count(string(d), line)
	}
	return total
}

@(private = "file")
_pm_disk_equals :: proc(w: ^World, n: ^Node, tree: eng.Object, root: string, arm: string) {
	names, _ := tree_walk(n, tree, {}, "")
	for nm in names {
		d, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator)
		n.disk.probe += 1
		got, gerr := prim.read_file(disk_vfs(&n.disk), strings.concatenate({root, "/", nm}, context.temp_allocator), context.temp_allocator)
		n.disk.probe -= 1
		if gerr != .None || string(got) != string(d) {
			world_fail(w, "pin move %s on %s: %s on disk is %q (%v), in the tree %q", arm, n.name, nm, string(got), gerr, string(d))
		}
	}
}

@(private = "file")
_pm_files :: proc(n: ^Node, tree: eng.Object) -> string {
	b := strings.builder_make(context.temp_allocator)
	names, _ := tree_walk(n, tree, {}, "")
	for nm in names {
		d, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator)
		fmt.sbprintf(&b, "%s=%q ", nm, string(d))
	}
	return strings.to_string(b)
}

pin_move_run :: proc(seed: u64, kind: Pm_Kind) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
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
	_pin_move(w, kind)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_pin_move :: proc(w: ^World, kind: Pm_Kind) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	tree: eng.Object
	space: prim.Id
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "move", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "pin move: space: %v", err)
			return
		}
		space = id
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "pin move: member_add: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "pin move: tree_create: %v", err)
			return
		}
	}
	defer delete(proof, w.allocator)
	join: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "move", "relay", w.relay.public); err != .None {
			world_fail(w, "pin move: join: %v", err)
			return
		}
		eng.space_open(&b.e, space)
	}
	run_until(w, w.now + 10_000_000_000, true)
	cop := new_op(&w.model, .Create, a, len(w.model.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&w.model.objs, ob)
	if err := node_mount(w, a, 0, PM_A); err != .None {
		world_fail(w, "pin move: mount a: %v", err)
		return
	}
	if err := node_mount(w, b, 0, PM_B); err != .None {
		world_fail(w, "pin move: mount b: %v", err)
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	vfs := disk_vfs(&a.disk)
	dir := "/d" if kind == .Dir_Move_Hold else ""
	write: {
		context = instance_context(&a.inst)
		defer node_after(a)
		if kind == .Dir_Move_Hold {
			prim.mkdir_all(vfs, PM_A + "/d", 0o755)
		}
		_pm_write(vfs, strings.concatenate({PM_A, dir, "/a.txt"}, context.temp_allocator), PM_ONE)
		if kind == .Swap {
			_pm_write(vfs, PM_A + "/c.txt", PM_TWO)
		}
	}
	run_until(w, w.now + 15_000_000_000, true)
	sm: ^Sim_Mount
	for &x in a.mounts {
		if x.root == PM_A {
			sm = &x
		}
	}
	if sm == nil || sm.m == nil {
		world_fail(w, "pin move: no mount")
		return
	}
	agent := prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
	path := "d/a.txt" if kind == .Dir_Move_Hold else "a.txt"
	scope: ^fs.Scope
	pin: {
		context = instance_context(&a.inst)
		defer node_after(a)
		scope = fs.scope_open(a.reg, sm.m, prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng)), agent)
		if kind == .Dir_Move_Hold {
			fs.scope_write_begin(scope, path)
		} else {
			fs.scope_read_base(scope, path, transmute([]u8)string(PM_ONE))
		}
		if !fs.scope_pinned(scope, path) {
			world_fail(w, "pin move %v: pinned nothing", kind)
			return
		}
	}
	switch kind {
	case .Rename_Rewrite:
		rename: {
			context = instance_context(&a.inst)
			prim.rename(vfs, PM_A + "/a.txt", PM_A + "/b.txt")
			node_after(a)
		}
		run_until(w, w.now + 5_000_000_000, true)
	case .Swap:
		swap: {
			context = instance_context(&a.inst)
			prim.rename(vfs, PM_A + "/a.txt", PM_A + "/t")
			prim.rename(vfs, PM_A + "/c.txt", PM_A + "/a.txt")
			prim.rename(vfs, PM_A + "/t", PM_A + "/c.txt")
			node_after(a)
		}
		run_until(w, w.now + 5_000_000_000, true)
	case .Remote_Rename:
		remote: {
			context = instance_context(&b.inst)
			prim.rename(disk_vfs(&b.disk), PM_B + "/a.txt", PM_B + "/b.txt")
			node_after(b)
		}
		run_until(w, w.now + 15_000_000_000, true)
	case .Dir_Move_Hold:
		dirmove: {
			context = instance_context(&b.inst)
			prim.rename(disk_vfs(&b.disk), PM_B + "/d", PM_B + "/e")
			node_after(b)
		}
		run_until(w, w.now + 15_000_000_000, true)
		held: {
			a.disk.probe += 1
			got, gerr := prim.read_file(vfs, PM_A + "/d/a.txt", context.temp_allocator)
			a.disk.probe -= 1
			if gerr != .None || string(got) != PM_ONE {
				world_fail(w, "pin move Dir_Move_Hold: the held path d/a.txt moved during the hold: %q (%v)", string(got), gerr)
			}
		}
	}
	fmt.eprintf("PMDBG %v before write: %s\n", kind, _pm_files(a, tree))
	act: {
		context = instance_context(&a.inst)
		abs := strings.concatenate({PM_A, "/", path}, context.temp_allocator)
		_writer_set(w, a, abs, Writer_Info{scope = scope, agent = true})
		fs.mount_observe_begin(sm.m, path, scope)
		if werr := _pm_write(vfs, abs, strings.concatenate({PM_ONE, PM_TOOL}, context.temp_allocator)); werr != .None {
			world_fail(w, "pin move %v: the agent's write failed: %v", kind, werr)
		}
		if kind == .Dir_Move_Hold {
			fs.scope_write_base(scope, path, transmute([]u8)string(PM_ONE))
			fs.scope_write_end(scope, path)
		}
		fs.scope_close(a.reg, scope)
		_forget_scope(w, a, scope)
		node_after(a)
	}
	run_until(w, w.now + 30_000_000_000, true)
	fmt.eprintf("PMDBG %v after write: %s\n", kind, _pm_files(a, tree))
	for x in ([]^Node{a, b}) {
		context = instance_context(&x.inst)
		defer node_after(x)
		root := PM_A if x == a else PM_B
		_pm_disk_equals(w, x, tree, root, fmt.tprintf("%v", kind))
		if c := _pm_count(x, tree, PM_TOOL); c != 1 {
			world_fail(w, "pin move %v on %s: tool line appears %d times (%s)", kind, x.name, c, _pm_files(x, tree))
		}
		if c := _pm_count(x, tree, PM_ONE); kind != .Rename_Rewrite && c < 1 {
			world_fail(w, "pin move %v on %s: one line is gone (%s)", kind, x.name, _pm_files(x, tree))
		}
	}
}

@(test)
pin_move :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for kind in Pm_Kind {
		failures := pin_move_run(1, kind)
		for f in failures {
			fmt.eprintf("pin_move: %s\n", f)
			delete(f)
		}
		fmt.eprintf("pin_move: %v failures=%d\n", kind, len(failures))
		testing.expect(t, len(failures) == 0, fmt.tprintf("pin_move %v failed", kind))
		delete(failures)
	}
}

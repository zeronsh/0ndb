package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

RF_ROOT :: "/work/faults"

RF_FILES :: 300

Rf_Op :: enum u8 {
	List,
	Ingest,
	Ingest_Nudged,
	Ingest_Then_Write,
	Materialize,
}

@(private = "file")
Rf :: struct {
	disk:   ^Disk,
	prefix: string,
	nth:    int,
	reads:  int,
	fired:  int,
	path:   [256]u8,
	plen:   int,
}

@(private = "file", thread_local)
_rf: Rf

@(init)
_read_fault_init :: proc "contextless" () {
	register_disk_fault(_rf_read)
}

@(private = "file")
_rf_read :: proc(d: ^Disk, path: string) -> prim.Error {
	if _rf.disk != d || _rf.nth == 0 || d.probe > 0 || d.quiet || !strings.has_prefix(path, _rf.prefix) {
		return .None
	}
	_rf.reads += 1
	if _rf.reads != _rf.nth {
		return .None
	}
	_rf.nth = 0
	_rf.fired += 1
	_rf.plen = copy(_rf.path[:], path)
	return .Io
}

read_fault_arm :: proc(d: ^Disk, prefix: string, nth: int) {
	_rf = {disk = d, prefix = prefix, nth = nth}
}

read_fault_disarm :: proc(allocator := context.temp_allocator) -> (fired: bool, path: string) {
	fired = _rf.fired > 0
	path = strings.clone(string(_rf.path[:_rf.plen]), allocator)
	_rf = {}
	return
}

@(private = "file")
_rf_name :: proc(i: int) -> string {
	return fmt.tprintf("d%02d/f%03d.txt", i % 20, i)
}

@(private = "file")
_rf_write :: proc(vfs: prim.Vfs, path, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	return err
}

@(private = "file")
_rf_mount :: proc(n: ^Node) -> ^fs.Mount {
	for &x in n.mounts {
		if x.root == RF_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_rf_check :: proc(w: ^World, n: ^Node, tree: eng.Object, want: map[string]string, what: string) {
	vfs := disk_vfs(&n.disk)
	if !n.alive || !n.e_open {
		world_fail(w, "%s: the node is down", what)
		return
	}
	for i in 0 ..< RF_FILES {
		name := _rf_name(i)
		n.disk.probe += 1
		disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", RF_ROOT, name), context.temp_allocator)
		n.disk.probe -= 1
		if derr != .None || string(disk) != want[name] {
			world_fail(w, "%s: %s on disk is %q (%v), want %q", what, name, string(disk), derr, want[name])
			return
		}
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	total := 0
	for d in 0 ..< 20 {
		names, lerr := eng.tree_list(&n.e, tree, fmt.tprintf("d%02d", d), context.temp_allocator)
		if lerr != .None {
			world_fail(w, "%s: list d%02d after the fault: %v", what, d, lerr)
			return
		}
		total += len(names)
		for nm in names {
			if strings.contains(nm, "~") {
				world_fail(w, "%s: d%02d holds the collision copy %s", what, d, nm)
				return
			}
		}
	}
	if total != RF_FILES {
		world_fail(w, "%s: the tree lists %d files, want %d", what, total, RF_FILES)
		return
	}
	for i in 0 ..< RF_FILES {
		name := _rf_name(i)
		data, rerr := eng.tree_read(&n.e, tree, name, context.temp_allocator)
		if rerr != .None || string(data) != want[name] {
			world_fail(w, "%s: %s in the tree is %q (%v), want %q", what, name, string(data), rerr, want[name])
			return
		}
	}
}

@(private = "file")
_rf_run :: proc(w: ^World, op: Rf_Op, prefix: string, nth: int) -> (fired: bool, errs: string) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "read fault: node start")
		return
	}
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "faults")
		if err == .None {
			eng.space_open(&n.e, space)
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		if err != .None {
			world_fail(w, "read fault: setup: %v", err)
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
	want := make(map[string]string, w.allocator)
	for d in 0 ..< 20 {
		prim.mkdir_all(vfs, fmt.tprintf("%s/d%02d", RF_ROOT, d), 0o755)
	}
	for i in 0 ..< RF_FILES {
		name := strings.clone(_rf_name(i), w.allocator)
		want[name] = fmt.aprintf("file %d\n", i, allocator = w.allocator)
		_rf_write(vfs, fmt.tprintf("%s/%s", RF_ROOT, name), want[name])
	}
	if err := node_mount(w, n, len(m.objs) - 1, RF_ROOT); err != .None {
		world_fail(w, "read fault: mount: %v", err)
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	if _rf_mount(n) == nil {
		world_fail(w, "read fault: mount missing")
		return
	}
	_rf_check(w, n, tree, want, "before the fault")
	if len(w.failures) > 0 {
		return
	}
	target := strings.clone(_rf_name(137), w.allocator)
	b := strings.builder_make(w.allocator)
	read_fault_arm(&n.disk, prefix, nth)
	switch op {
	case .List:
		context = instance_context(&n.inst)
		defer node_after(n)
		for d in 0 ..< 20 {
			names, lerr := eng.tree_list(&n.e, tree, fmt.tprintf("d%02d", d), context.temp_allocator)
			if lerr != .None {
				fmt.sbprintf(&b, "list %v ", lerr)
			} else if len(names) != RF_FILES / 20 {
				world_fail(w, "list during the fault: d%02d lists %d files with no error, want %d", d, len(names), RF_FILES / 20)
			}
		}
	case .Ingest, .Ingest_Nudged, .Ingest_Then_Write:
		want[target] = "edited by a person\n"
		if err := _rf_write(vfs, fmt.tprintf("%s/%s", RF_ROOT, target), want[target]); err != .None {
			fmt.sbprintf(&b, "write %v ", err)
		}
		context = instance_context(&n.inst)
		defer node_after(n)
		if mt := _rf_mount(n); mt != nil {
			if serr := fs.mount_sync(mt); serr != .None {
				fmt.sbprintf(&b, "sync %v ", serr)
			}
		}
	case .Materialize:
		context = instance_context(&n.inst)
		defer node_after(n)
		base: fs.Version
		_, rerr := eng.tree_read(&n.e, tree, target, context.temp_allocator, {}, "", nil, &base)
		if rerr != .None {
			fmt.sbprintf(&b, "tree_read %v ", rerr)
		} else if werr := eng.tree_write(&n.e, tree, target, transmute([]u8)string("written by the engine\n"), base); werr != .None {
			fmt.sbprintf(&b, "tree_write %v ", werr)
		} else {
			want[target] = "written by the engine\n"
		}
	}
	run_until(w, w.now + 3_000_000_000, true)
	path: string
	fired, path = read_fault_disarm(w.allocator)
	run_until(w, w.now + 20_000_000_000, true)
	#partial switch op {
	case .Ingest_Nudged:
		other := _rf_name(21)
		want[other] = "nudge\n"
		_rf_write(vfs, fmt.tprintf("%s/%s", RF_ROOT, other), "nudge\n")
		{
			context = instance_context(&n.inst)
			node_after(n)
		}
		run_until(w, w.now + 20_000_000_000, true)
	case .Ingest_Then_Write:
		{
			context = instance_context(&n.inst)
			base: fs.Version
			if cur, rerr := eng.tree_read(&n.e, tree, target, context.temp_allocator, {}, "", nil, &base); rerr == .None {
				next := strings.concatenate({string(cur), "engine line\n"}, context.temp_allocator)
				werr := eng.tree_write(&n.e, tree, target, transmute([]u8)next, base)
				fmt.sbprintf(&b, "then_write %v ", werr)
			}
			node_after(n)
		}
		run_until(w, w.now + 20_000_000_000, true)
		n.disk.probe += 1
		disk, _ := prim.read_file(vfs, fmt.tprintf("%s/%s", RF_ROOT, target), w.allocator)
		n.disk.probe -= 1
		if !strings.contains(string(disk), "edited by a person") {
			context = instance_context(&n.inst)
			cur, rerr := eng.tree_read(&n.e, tree, target, context.temp_allocator)
			names, lerr := eng.tree_list(&n.e, tree, "d17", context.temp_allocator)
			fmt.eprintf("read_fault: after the loss nth=%d: tree %q %v, d17 %v %v\n", nth, string(cur), rerr, names, lerr)
			inode_hits := 0
			if mt := _rf_mount(n); mt != nil {
				h := mt.history
				for lv in 0 ..< h.g.next {
					first, _, stream, off, ok := fs.history_batch_at(h, lv)
					if !ok || first != lv {
						continue
					}
					if bt, berr := fs.history_read_batch(h, stream, off, context.temp_allocator); berr == .None {
						for o in bt.ops {
							if strings.contains(string(o.content), "edited by a person") {
								inode_hits += 1
							}
						}
					}
				}
			}
			fmt.eprintf("read_fault: the lost text is in %d history ops\n", inode_hits)
			node_after(n)
			world_fail(w, "%v, read %d under %s (%s) failed once [%s]: LOST: the person's edit is gone from disk, which holds %q", op, nth, prefix, path, strings.to_string(b), string(disk))
		}
		return fired, strings.clone(strings.to_string(b), context.allocator)
	}
	_rf_check(w, n, tree, want, fmt.tprintf("%v, read %d under %s (%s) failed once [%s]", op, nth, prefix, path, strings.to_string(b)))
	return fired, strings.clone(strings.to_string(b), context.allocator)
}

@(test)
read_fault :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	if env_u64("SIM_READ_FAULT", 0) == 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	most := int(env_u64("RF_MAX", 400))
	for op in Rf_Op {
		for prefix in ([]string{"/data", RF_ROOT}) {
			points, bad := 0, 0
			only := int(env_u64("RF_ONLY", 0))
			for nth in 0 ..= most {
				if only != 0 && nth != 0 && nth != only {
					continue
				}
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
				fired, errs := _rf_run(w, op, prefix, nth)
				delete(errs)
				if nth == 0 && len(w.failures) > 0 {
					fmt.eprintf("read_fault: CONTROL %v under %s fails: %s\n", op, prefix, w.failures[0])
				}
				if len(w.failures) > 0 {
					bad += 1
					for f in w.failures {
						if bad <= int(env_u64("RF_PRINT", 6)) {
							fmt.eprintf("read_fault: %s\n", f)
						}
					}
				}
				world_destroy(w)
				free(w)
				if !fired && nth > 0 {
					break
				}
				points += int(fired)
				if nth == 0 && bad > 0 {
					break
				}
			}
			fmt.eprintf("read_fault: %v under %s: %d fault points, %d failed\n", op, prefix, points, bad)
			testing.expect(t, bad == 0, "read_fault failed")
		}
	}
}

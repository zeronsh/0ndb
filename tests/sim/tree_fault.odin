package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

TF_ROOT :: "/work/faults"

TF_DIRS :: 20

TF_FILES :: 300

TF_DIR :: "d17"

Tf_Op :: enum u8 {
	Engine_Create,
	Engine_Over,
	Engine_Edit,
	Disk_Edit,
	Disk_Create,
	List,
}

@(private = "file")
_tf_name :: proc(i: int) -> string {
	return fmt.tprintf("d%d/f%03d.txt", i % TF_DIRS, i)
}

@(private = "file")
_tf_text :: proc(i: int) -> string {
	return fmt.tprintf("file %d\n", i)
}

@(private = "file")
_tf_write :: proc(vfs: prim.Vfs, path, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	return err
}

@(private = "file")
_tf_mount :: proc(n: ^Node) -> ^fs.Mount {
	for &x in n.mounts {
		if x.root == TF_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_tf_edit :: proc(n: ^Node, tree: eng.Object, path, text: string, create: bool) -> eng.Error {
	context = instance_context(&n.inst)
	defer node_after(n)
	base: fs.Version
	if create {
		base = tree_base(&n.e, tree)
	} else {
		_, rerr := eng.tree_read(&n.e, tree, path, context.temp_allocator, {}, "", nil, &base)
		if rerr != .None {
			return rerr
		}
	}
	return eng.tree_write(&n.e, tree, path, transmute([]u8)text, base)
}

@(private = "file")
_tf_missing :: proc(w: ^World, n: ^Node, tree: eng.Object, disk: bool) -> (missing: int, sample: string) {
	vfs := disk_vfs(&n.disk)
	b := strings.builder_make(w.allocator)
	context = instance_context(&n.inst)
	defer node_after(n)
	for i in 0 ..< TF_FILES {
		name := _tf_name(i)
		text := ""
		ok := false
		if disk {
			n.disk.probe += 1
			data, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", TF_ROOT, name), context.temp_allocator)
			n.disk.probe -= 1
			text, ok = string(data), derr == .None
		} else {
			data, rerr := eng.tree_read(&n.e, tree, name, context.temp_allocator)
			text, ok = string(data), rerr == .None
		}
		if !ok || !strings.has_prefix(text, _tf_text(i)) {
			missing += 1
			if missing == 1 {
				fmt.sbprintf(&b, "%s %q", name, text)
			}
		}
	}
	return missing, strings.to_string(b)
}

@(private = "file")
_tf_run :: proc(w: ^World, op: Tf_Op, nth: int) -> (fired: bool, path: string, errs: string) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	vfs := disk_vfs(&a.disk)
	tree: eng.Object
	space: prim.Id
	{
		context = instance_context(&a.inst)
		id, err := eng.space_create(&a.e, "faults", "relay", w.relay.public)
		if err == .None {
			err = eng.space_open(&a.e, id)
		}
		space = id
		proof: []u8
		if err == .None {
			proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		}
		if err == .None {
			tree, err = eng.tree_create(&a.e, space, "work")
		}
		node_after(a)
		if err != .None {
			world_fail(w, "tree fault: setup: %v", err)
			return
		}
		context = instance_context(&b.inst)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "faults", "relay", w.relay.public); jerr != .None {
			world_fail(w, "tree fault: join: %v", jerr)
			return
		}
		eng.space_open(&b.e, space)
		node_after(b)
	}
	m := &w.model
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	for d in 0 ..< TF_DIRS {
		prim.mkdir_all(vfs, fmt.tprintf("%s/d%d", TF_ROOT, d), 0o755)
	}
	for i in 0 ..< TF_FILES {
		_tf_write(vfs, fmt.tprintf("%s/%s", TF_ROOT, _tf_name(i)), _tf_text(i))
	}
	if err := node_mount(w, a, len(m.objs) - 1, TF_ROOT); err != .None {
		world_fail(w, "tree fault: mount: %v", err)
		return
	}
	for _ in 0 ..< 8 {
		run_until(w, w.now + 10_000_000_000, true)
		if n, _ := _tf_missing(w, b, tree, false); n == 0 {
			break
		}
	}
	for who in ([]^Node{a, b}) {
		if n, s := _tf_missing(w, who, tree, false); n > 0 {
			world_fail(w, "CONTROL: %s misses %d files before the fault: %s", who.name, n, s)
			return
		}
	}
	run_until(w, w.now + 30_000_000_000, true)
	eb := strings.builder_make(w.allocator)
	if op == .Engine_Over {
		a.disk.probe += 1
		_tf_write(vfs, TF_ROOT + "/" + TF_DIR + "/new.txt", "local\n")
		a.disk.probe -= 1
	}
	read_fault_arm(&a.disk, "/data", nth)
	switch op {
	case .Engine_Create, .Engine_Over:
		if err := _tf_edit(a, tree, TF_DIR + "/new.txt", "new\n", true); err != .None {
			fmt.sbprintf(&eb, "write %v ", err)
		}
	case .Engine_Edit:
		if err := _tf_edit(a, tree, _tf_name(17), fmt.tprintf("%sengine line\n", _tf_text(17)), false); err != .None {
			fmt.sbprintf(&eb, "write %v ", err)
		}
	case .Disk_Edit:
		_tf_write(vfs, fmt.tprintf("%s/%s", TF_ROOT, _tf_name(37)), fmt.tprintf("%sedited on disk\n", _tf_text(37)))
		context = instance_context(&a.inst)
		node_after(a)
	case .Disk_Create:
		_tf_write(vfs, TF_ROOT + "/" + TF_DIR + "/person.txt", "a person's file\n")
		context = instance_context(&a.inst)
		node_after(a)
	case .List:
		context = instance_context(&a.inst)
		names, lerr := eng.tree_list(&a.e, tree, TF_DIR, context.temp_allocator)
		if lerr == .None && len(names) != TF_FILES / TF_DIRS {
			world_fail(w, "list during the fault: %d names with no error, want %d", len(names), TF_FILES / TF_DIRS)
		}
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	fired, path = read_fault_disarm(w.allocator)
	errs = strings.to_string(eb)
	what := fmt.aprintf("%v, read %d (%s) failed once [%s]", op, nth, path, errs, allocator = w.allocator)
	run_until(w, w.now + 30_000_000_000, true)
	look :: proc(w: ^World, n: ^Node, tree: eng.Object, what, when_: string, disk: bool) {
		if !n.alive || !n.e_open {
			world_fail(w, "%s: %s: %s is down", what, when_, n.name)
			return
		}
		if k, s := _tf_missing(w, n, tree, disk); k > 0 {
			world_fail(w, "%s: %s: %s %s misses %d of %d files, first %s", what, when_, n.name, "DISK" if disk else "TREE", k, TF_FILES, s)
		}
	}
	look(w, a, tree, what, "after the fault", true)
	look(w, a, tree, what, "after the fault", false)
	look(w, b, tree, what, "after the fault", false)
	if err := _tf_edit(a, tree, TF_DIR + "/after.txt", "after\n", true); err != .None && fired {
		world_fail(w, "%s: a create in %s after the fault answers %v", what, TF_DIR, err)
	}
	_tf_write(vfs, fmt.tprintf("%s/%s", TF_ROOT, _tf_name(57)), fmt.tprintf("%sand a later edit\n", _tf_text(57)))
	{
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 60_000_000_000, true)
	look(w, a, tree, what, "after a later write there", true)
	look(w, a, tree, what, "after a later write there", false)
	look(w, b, tree, what, "after a later write there", false)
	if a.alive {
		node_crash_now(a, .Process, u64(nth))
	}
	run_until(w, w.now + 5_000_000_000, true)
	if a.alive && _tf_mount(a) == nil {
		if err := node_mount(w, a, len(m.objs) - 1, TF_ROOT); err != .None {
			world_fail(w, "%s: the remount answers %v", what, err)
		}
	}
	run_until(w, w.now + 60_000_000_000, true)
	look(w, a, tree, what, "after a restart", true)
	look(w, a, tree, what, "after a restart", false)
	look(w, b, tree, what, "after a restart", false)
	return
}

@(test)
tree_fault :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	step := max(int(env_u64("TF_STEP", 1)), 1)
	most := int(env_u64("TF_MAX", 600))
	print := int(env_u64("TF_PRINT", 6))
	for op in Tf_Op {
		points, bad, shown := 0, 0, 0
		for nth := 0; nth <= most; nth += step if nth > 0 else 1 {
			cfg := default_config(1)
			cfg.nodes = 2
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
			fired, _, _ := _tf_run(w, op, nth)
			if len(w.failures) > 0 {
				bad += 1
				if nth == 0 {
					fmt.eprintf("tree_fault: CONTROL %v fails: %s\n", op, w.failures[0])
				}
				for f in w.failures {
					if shown < print {
						shown += 1
						fmt.eprintf("tree_fault: %v read %d: %s\n", op, nth, f)
					}
				}
			}
			world_destroy(w)
			free(w)
			if nth == 0 && bad > 0 || nth > 0 && !fired {
				break
			}
			points += int(fired)
		}
		fmt.eprintf("tree_fault: %v: %d fault points, %d failed\n", op, points, bad)
		testing.expect(t, bad == 0, "tree_fault failed")
	}
}

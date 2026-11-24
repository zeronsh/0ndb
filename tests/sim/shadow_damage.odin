package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fstree"
import "../../src/prim"

SD_ROOT :: "/work/damaged"

SD_FILES :: 40

SD_TARGET :: 13

Sd_Op :: enum u8 {
	Unchanged,
	Edited,
	Deleted,
	Renamed,
}

Sd_Hurt :: enum u8 {
	None,
	Record,
	Record_No_Index,
}

@(private = "file")
_sd_name :: proc(i: int) -> string {
	return fmt.tprintf("d%d/f%02d.txt", i % 4, i)
}

@(private = "file")
_sd_write :: proc(vfs: prim.Vfs, path, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	return err
}

@(private = "file")
_sd_mount :: proc(n: ^Node) -> ^fs.Mount {
	for &x in n.mounts {
		if x.root == SD_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_sd_inode :: proc(n: ^Node, path: string) -> (id: fstree.Inode_Id, found: bool) {
	mt := _sd_mount(n)
	if mt == nil || mt.history == nil {
		return
	}
	h := mt.history
	if fs.history_wake(h) != .None {
		return
	}
	v, ok, err := fs.history_line(h, mt.line, context.temp_allocator)
	if err != .None || !ok {
		v = fs.history_heads(h, context.temp_allocator)
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return
	}
	snap, serr := fs.version_snapshot(h, lvs[:])
	if serr != .None {
		return
	}
	defer fstree.snapshot_destroy(&snap)
	at, has, lerr := fstree.lookup(&snap, path)
	return at, has && lerr == nil
}

@(private = "file")
_sd_damage :: proc(w: ^World, n: ^Node, name: string, hurt: Sd_Hurt) -> bool {
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	done := false
	for f in files {
		if !strings.contains(f.path, "/shadow") || !strings.has_suffix(f.path, ".log") {
			continue
		}
		at := -1
		k := 0
		for {
			i := disk_index_of(f.data[k:], transmute([]u8)name)
			if i < 0 {
				break
			}
			at = k + i
			k = at + len(name)
		}
		if at < 0 {
			continue
		}
		b := [1]u8{f.data[at + len(name) + 4] ~ 0x10}
		done = disk_probe_write(&n.disk, f.path, i64(at + len(name) + 4), b[:], true)
		if hurt == .Record_No_Index {
			idx := strings.concatenate({f.path[:len(f.path) - 4], ".idx"}, context.temp_allocator)
			n.disk.probe += 1
			done &&= prim.remove(disk_vfs(&n.disk), idx) == .None
			n.disk.probe -= 1
		}
	}
	return done
}

@(private = "file")
_sd_run :: proc(w: ^World, op: Sd_Op, hurt: Sd_Hurt) {
	what := fmt.aprintf("%v, %v", op, hurt, allocator = w.allocator)
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "%s: node start", what)
		return
	}
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "damaged")
		if err == .None {
			eng.space_open(&n.e, space)
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		if err != .None {
			world_fail(w, "%s: setup: %v", what, err)
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
	for d in 0 ..< 4 {
		prim.mkdir_all(vfs, fmt.tprintf("%s/d%d", SD_ROOT, d), 0o755)
	}
	for i in 0 ..< SD_FILES {
		name := strings.clone(_sd_name(i), w.allocator)
		want[name] = fmt.aprintf("file %d\nsecond line\n", i, allocator = w.allocator)
		_sd_write(vfs, fmt.tprintf("%s/%s", SD_ROOT, name), want[name])
	}
	if err := node_mount(w, n, len(m.objs) - 1, SD_ROOT); err != .None {
		world_fail(w, "%s: mount: %v", what, err)
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	ids := make(map[string]fstree.Inode_Id, w.allocator)
	{
		context = instance_context(&n.inst)
		for name in prim.unordered(want) {
			if id, ok := _sd_inode(n, name); ok {
				ids[name] = id
			}
		}
	}
	if len(ids) != SD_FILES {
		world_fail(w, "%s: CONTROL: %d of %d files ingested before the damage", what, len(ids), SD_FILES)
		return
	}
	target := strings.clone(_sd_name(SD_TARGET), w.allocator)
	abs := fmt.aprintf("%s/%s", SD_ROOT, target, allocator = w.allocator)
	moved := strings.clone("d2/moved.txt", w.allocator)
	node_crash_now(n, .Process, u64(op) * 8 + u64(hurt))
	if hurt != .None && !_sd_damage(w, n, target, hurt) {
		world_fail(w, "%s: the damage did not reach the disk", what)
		return
	}
	n.disk.probe += 1
	switch op {
	case .Unchanged:
	case .Edited:
		want[target] = "file 13\nedited while down\nsecond line\n"
		_sd_write(vfs, abs, want[target])
	case .Deleted:
		prim.remove(vfs, abs)
		delete_key(&want, target)
	case .Renamed:
		prim.rename(vfs, abs, fmt.tprintf("%s/%s", SD_ROOT, moved))
		want[moved] = want[target]
		ids[moved] = ids[target]
		delete_key(&want, target)
	}
	n.disk.probe -= 1
	run_until(w, w.now + 5_000_000_000, true)
	if n.alive && _sd_mount(n) == nil {
		if err := node_mount(w, n, len(m.objs) - 1, SD_ROOT); err != .None {
			world_fail(w, "%s: REMOUNT: %v", what, err)
			return
		}
	}
	run_until(w, w.now + 60_000_000_000, true)
	if !n.alive || !n.e_open || _sd_mount(n) == nil {
		world_fail(w, "%s: DOWN: alive %v engine %v mounted %v", what, n.alive, n.e_open, _sd_mount(n) != nil)
		return
	}
	_sd_check(w, n, tree, want, ids, what)
	if len(w.failures) > 0 {
		return
	}
	last := strings.clone(_sd_name(21), w.allocator)
	{
		context = instance_context(&n.inst)
		base: fs.Version
		_, rerr := eng.tree_read(&n.e, tree, last, context.temp_allocator, {}, "", nil, &base)
		werr := eng.tree_write(&n.e, tree, last, transmute([]u8)string("written after\n"), base) if rerr == .None else rerr
		node_after(n)
		if werr != .None {
			world_fail(w, "%s: AFTER: an engine write fails: %v", what, werr)
			return
		}
	}
	want[last] = "written after\n"
	run_until(w, w.now + 30_000_000_000, true)
	_sd_check(w, n, tree, want, ids, fmt.tprintf("%s, after one more write", what))
}

@(private = "file")
_sd_check :: proc(w: ^World, n: ^Node, tree: eng.Object, want: map[string]string, ids: map[string]fstree.Inode_Id, what: string) {
	vfs := disk_vfs(&n.disk)
	names := make([dynamic]string, context.temp_allocator)
	for k in prim.unordered(want) {
		append(&names, k)
	}
	for k in names {
		n.disk.probe += 1
		disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", SD_ROOT, k), context.temp_allocator)
		n.disk.probe -= 1
		if derr != .None || string(disk) != want[k] {
			world_fail(w, "%s: DISK %s is %q (%v), want %q", what, k, string(disk), derr, want[k])
		}
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	for d in 0 ..< 4 {
		list, lerr := eng.tree_list(&n.e, tree, fmt.tprintf("d%d", d), context.temp_allocator)
		if lerr != .None {
			world_fail(w, "%s: LIST d%d: %v", what, d, lerr)
			continue
		}
		expect := 0
		for k in names {
			expect += int(strings.has_prefix(k, fmt.tprintf("d%d/", d)))
		}
		if len(list) != expect {
			world_fail(w, "%s: TREE d%d lists %d entries, want %d", what, d, len(list), expect)
		}
	}
	reborn := 0
	for k in names {
		data, rerr := eng.tree_read(&n.e, tree, k, context.temp_allocator)
		if rerr != .None || string(data) != want[k] {
			world_fail(w, "%s: TREE %s is %q (%v), want %q", what, k, string(data), rerr, want[k])
		}
		id, found := _sd_inode(n, k)
		if found && id != ids[k] {
			reborn += 1
		}
	}
	if reborn > 0 {
		world_fail(w, "%s: REBORN: %d files are new inodes, their history is cut off", what, reborn)
	}
}

@(test)
shadow_damage :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for op in Sd_Op {
		for hurt in Sd_Hurt {
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
			_sd_run(w, op, hurt)
			for f, i in w.failures {
				if i < int(env_u64("SD_MAX", 4)) {
					fmt.eprintf("shadow_damage: %s\n", f)
				}
			}
			if len(w.failures) > int(env_u64("SD_MAX", 4)) {
				fmt.eprintf("shadow_damage: %v, %v: %d more\n", op, hurt, len(w.failures) - int(env_u64("SD_MAX", 4)))
			}
			fmt.eprintf("shadow_damage: %v, %v: %d failures\n", op, hurt, len(w.failures))
			testing.expect(t, len(w.failures) == 0, "shadow_damage failed")
			world_destroy(w)
			free(w)
		}
	}
}

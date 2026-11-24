package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
AN_ROOT :: "/work/absent-n0-git"

@(private = "file")
AN_PEER :: "/work/absent-n1"

@(private = "file")
AN_FEATURE :: "git:refs/heads/feature"

@(private = "file")
An_Case :: enum u8 {
	Shown_Own_Remove,
	Shown_Own_Rename,
	Shown_Remote_Remove,
	Shown_Remote_Rename,
	Absent_Checkout,
	Absent_Real_Name,
}

@(private = "file")
_an_put :: proc(n: ^Node, name: string, data: string) {
	abs := fmt.tprintf("%s/%s", AN_ROOT, name)
	if err := _disk_write(disk_vfs(&n.disk), abs, transmute([]u8)data, false); err != .None {
		world_fail(n.w, "absent name: write %s: %v", name, err)
	}
}

@(private = "file")
_an_settle :: proc(w: ^World) {
	for _ in 0 ..< 6 {
		run_until(w, w.now + 5_000_000_000, true)
	}
}

@(private = "file")
_an_disk :: proc(n: ^Node, name: string) -> (string, bool) {
	data, _, ok := disk_probe_read(&n.disk, fmt.tprintf("%s/%s", AN_ROOT, name))
	return string(data), ok
}

@(private = "file")
_an_names :: proc(n: ^Node) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(&n.disk, &files)
	for f in files {
		if strings.has_prefix(f.path, AN_ROOT + "/") {
			rel := f.path[len(AN_ROOT) + 1:]
			if !strings.has_prefix(rel, ".git/") && !fs.path_internal(rel) {
				append(&out, rel)
			}
		}
	}
	return out[:]
}

@(private = "file")
_an_tree :: proc(n: ^Node, o: eng.Object) -> (text: string) {
	context = instance_context(&n.inst)
	defer node_after(n)
	b := strings.builder_make(n.w.allocator)
	names, _ := eng.tree_list(&n.e, o, "", context.temp_allocator, {}, "main")
	for nm in names {
		data, err := eng.tree_read(&n.e, o, nm, context.temp_allocator, {}, "main")
		fmt.sbprintf(&b, "%s=%q(%v) ", nm, string(data), err)
	}
	return strings.to_string(b)
}

@(private = "file")
_an_run :: proc(w: ^World, c: An_Case) -> (shaped: bool) {
	if !relay_start(&w.relay) {
		world_fail(w, "absent name: relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "absent name: node start")
		return
	}
	tree: eng.Object
	{
		context = instance_context(&a.inst)
		space, err := eng.space_create(&a.e, "absent", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, space) != .None {
			world_fail(w, "absent name: space: %v", err)
			return
		}
		proof, perr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "absent name: member_add: %v", perr)
			return
		}
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "absent name: tree_create: %v", err)
			return
		}
		node_after(a)
		context = instance_context(&b.inst)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "absent", "relay", w.relay.public); jerr != .None {
			world_fail(w, "absent name: join: %v", jerr)
			return
		}
		if oerr := eng.space_open(&b.e, space); oerr != .None {
			world_fail(w, "absent name: space_open: %v", oerr)
			return
		}
		node_after(b)
	}
	m := &w.model
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	when_s := clock_wall(&a.clock) / 1_000_000_000
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("main a\n")}}
	if err := git_checkout_create(disk_vfs(&a.disk), AN_ROOT, files[:], when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "absent name: git checkout: %v", err)
		return
	}
	feature := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(disk_vfs(&a.disk), AN_ROOT, "feature", feature[:], nil, when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "absent name: branch commit: %v", err)
		return
	}
	if err := node_mount(w, a, oi, AN_ROOT); err != .None {
		world_fail(w, "absent name: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = a.idx, oi = oi, root = strings.clone(AN_ROOT, w.allocator)})
	_an_settle(w)
	sm: ^Sim_Mount
	for &x in a.mounts {
		if x.root == AN_ROOT && x.m != nil {
			sm = &x
		}
	}
	if sm == nil {
		world_fail(w, "absent name: mount missing")
		return
	}
	_an_tree(b, tree)
	_an_settle(w)
	if c == .Absent_Real_Name {
		_an_put(a, "c.txt~deadbeef-0", "real\n")
	}
	_an_put(a, "c.txt", "from a\n")
	{
		context = instance_context(&a.inst)
		fs.mount_sync(sm.m)
		node_after(a)
	}
	{
		context = instance_context(&b.inst)
		v, _ := eng.tree_version(&b.e, tree, "main", context.temp_allocator)
		if err := eng.tree_write(&b.e, tree, "c.txt", transmute([]u8)string("from b\n"), v, "main"); err != .None && err != .Pending {
			world_fail(w, "absent name: n1 tree_write: %v", err)
			return
		}
		node_after(b)
	}
	_an_settle(w)
	loser := ""
	for nm in _an_names(a) {
		if strings.has_prefix(nm, "c.txt~") && nm != "c.txt~deadbeef-0" {
			loser = strings.clone(nm, w.allocator)
		}
	}
	lost, lok := _an_disk(a, loser)
	_, kok := _an_disk(a, "c.txt")
	if loser == "" || !lok || !kok {
		world_note(w, "absent name: no collision: %v, tree %s", _an_names(a), _an_tree(a, tree))
		return
	}
	lost_text := strings.clone(lost, w.allocator)
	shaped = true
	if c == .Absent_Checkout || c == .Absent_Real_Name {
		{
			context = instance_context(&a.inst)
			if err := fs.mount_line_switch(sm.m, AN_FEATURE); err != .None {
				world_fail(w, "absent name: switch to feature: %v", err)
				return
			}
			node_after(a)
		}
		_an_settle(w)
		if got, _ := _an_disk(a, "c.txt"); got != "feature c\n" {
			world_fail(w, "absent name: on feature c.txt is %q", got)
			return
		}
	}
	#partial switch c {
	case .Shown_Own_Remove:
		prim.remove(disk_vfs(&a.disk), AN_ROOT + "/c.txt")
		context = instance_context(&a.inst)
		fs.mount_sync(sm.m)
		node_after(a)
	case .Shown_Own_Rename:
		prim.rename(disk_vfs(&a.disk), AN_ROOT + "/c.txt", AN_ROOT + "/d.txt")
		context = instance_context(&a.inst)
		fs.mount_sync(sm.m)
		node_after(a)
	case .Shown_Remote_Remove:
		context = instance_context(&b.inst)
		if err := eng.tree_remove(&b.e, tree, "c.txt", "main"); err != .None && err != .Pending {
			world_fail(w, "absent name: n1 tree_remove: %v", err)
		}
		node_after(b)
	case .Shown_Remote_Rename:
		if err := node_mount(w, b, oi, AN_PEER); err != .None {
			world_fail(w, "absent name: n1 mount: %v", err)
			return
		}
		_an_settle(w)
		if rerr := prim.rename(disk_vfs(&b.disk), AN_PEER + "/c.txt", AN_PEER + "/d.txt"); rerr != .None {
			world_fail(w, "absent name: n1 rename: %v", rerr)
			return
		}
		context = instance_context(&b.inst)
		for &x in b.mounts {
			if x.m != nil {
				fs.mount_sync(x.m)
			}
		}
		node_after(b)
	case:
	}
	_an_settle(w)
	if c == .Absent_Checkout || c == .Absent_Real_Name {
		changes := make([dynamic]Git_Change, context.temp_allocator)
		res, err := git_checkout(disk_vfs(&a.disk), AN_ROOT, "main", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &changes)
		if res != .Done || err != .None {
			world_fail(w, "absent name: checkout main: %v %v", res, err)
			return
		}
		context = instance_context(&a.inst)
		node_after(a)
	}
	_an_settle(w)
	if mismatch := make([dynamic]string, context.temp_allocator); sm.m != nil {
		context = instance_context(&a.inst)
		a.disk.quiet = true
		fs.mount_synced_mismatches(sm.m, &mismatch, context.temp_allocator)
		a.disk.quiet = false
		for x in mismatch {
			world_fail(w, "absent name %v: synced is not what is on disk: %s", c, x)
		}
	}
	on_tree := _an_tree(a, tree)
	all := strings.builder_make(w.allocator)
	for nm in _an_names(a) {
		data, _ := _an_disk(a, nm)
		fmt.sbprintf(&all, "%s=%q ", nm, data)
	}
	on_disk := strings.to_string(all)
	if !strings.contains(on_tree, fmt.tprintf("c.txt=%q", lost_text)) {
		world_fail(w, "absent name %v: the other device's file is not c.txt in the tree: %s(disk %s)", c, on_tree, on_disk)
	}
	if got, ok := _an_disk(a, "c.txt"); !ok || got != lost_text {
		world_fail(w, "absent name %v: c.txt on disk is %q (found %v), the tree's is %q; tree %s, disk %s", c, got, ok, lost_text, on_tree, on_disk)
	}
	if c == .Absent_Real_Name {
		if got, _ := _an_disk(a, "c.txt~deadbeef-0"); got != "real\n" {
			world_fail(w, "absent name %v: the person's own c.txt~deadbeef-0 is %q", c, got)
		}
	}
	return
}

absent_name_run :: proc(seed: u64, c: An_Case) -> (shaped: bool, failures: [dynamic]string) {
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
	cfg.storage = .Auto
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	shaped = _an_run(w, c)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(test)
absent_name :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	shapes: [An_Case]int
	for c in An_Case {
		for seed in u64(1) ..= 4 {
			shaped, failures := absent_name_run(seed, c)
			shapes[c] += int(shaped)
			for f in failures {
				fmt.eprintf("absent_name %v seed %d: %s\n", c, seed, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "absent_name %v seed %d failed", c, seed)
			delete(failures)
		}
		testing.expectf(t, shapes[c] > 0, "absent_name %v never made the collision", c)
	}
	free_all(context.temp_allocator)
}

package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
NV_ROOT :: "/work/named-edit-n0-git"

@(private = "file")
NV_BASE :: "base line\n"

@(private = "file")
NV_KEPT :: "kept line\n"

@(private = "file")
NV_TOOL :: "tool line\n"

@(private = "file")
NV_EDIT :: "edit line\n"

Named_Edit_Arm :: struct {
	elsewhere: bool,
	edit:      bool,
	named:     bool,
}

Named_Edit_Result :: struct {
	named: bool,
	behind: bool,
}

named_edit_run :: proc(seed: u64, arm: Named_Edit_Arm) -> (failures: [dynamic]string, res: Named_Edit_Result) {
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
	res = _named_edit(w, arm)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_nv_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == NV_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_nv_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_nv_scoped :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, scope: ^fs.Scope, data: string) -> bool {
	fs.mount_observe_begin(sm.m, "a.txt", scope)
	_writer_set(w, n, NV_ROOT + "/a.txt", Writer_Info{scope = scope, agent = true})
	if _nv_write(disk_vfs(&n.disk), NV_ROOT + "/a.txt", data) != .None {
		return false
	}
	fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	return true
}

@(private = "file")
_named_edit :: proc(w: ^World, arm: Named_Edit_Arm) -> (res: Named_Edit_Result) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "named edit: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "named-edit")
		if err != .None {
			world_fail(w, "named edit: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "named edit: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(NV_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, NV_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "named edit: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, NV_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "named edit: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, NV_ROOT); err != .None {
		world_fail(w, "named edit: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(NV_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	pin: {
		context = instance_context(&n.inst)
		sm := _nv_mount(n)
		if sm == nil {
			world_fail(w, "named edit: mount missing")
			return
		}
		open :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount) -> ^fs.Scope {
			return fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		}
		if arm.named {
			hold := open(w, n, sm)
			fs.scope_write_begin(hold, "a.txt")
		}
		reader := open(w, n, sm)
		fs.scope_read_base(reader, "a.txt", transmute([]u8)string(NV_BASE))
		if !fs.scope_pinned(reader, "a.txt") {
			world_fail(w, "named edit: the reader did not pin a.txt")
			return
		}
		if arm.named && !_nv_scoped(w, n, sm, open(w, n, sm), NV_BASE + NV_KEPT) {
			world_fail(w, "named edit: the other agent's write")
			return
		}
		if !_nv_scoped(w, n, sm, reader, NV_BASE + NV_TOOL) {
			world_fail(w, "named edit: the reader's write")
			return
		}
		e, found, err := fs.shadow_get(&sm.m.shadow, "a.txt")
		res.named = err == .None && found && e.ver != 0
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	if arm.elsewhere {
		if _nv_write(vfs, NV_ROOT + "/b.txt", "main b\nraised\n") != .None {
			world_fail(w, "named edit: b.txt")
			return
		}
		other: {
			context = instance_context(&n.inst)
			node_after(n)
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	disk: string
	look: {
		context = instance_context(&n.inst)
		n.disk.probe += 1
		have, _ := prim.read_file(vfs, NV_ROOT + "/a.txt", context.temp_allocator)
		n.disk.probe -= 1
		disk = strings.clone(string(have), w.allocator)
		line, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
		res.behind = strings.contains(string(line), NV_KEPT) && strings.contains(string(line), NV_TOOL) && !strings.contains(disk, NV_KEPT)
	}
	if arm.edit {
		if _nv_write(vfs, NV_ROOT + "/a.txt", strings.concatenate({disk, NV_EDIT}, w.allocator)) != .None {
			world_fail(w, "named edit: the person's edit")
			return
		}
		typed: {
			context = instance_context(&n.inst)
			node_after(n)
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	data, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if rerr != .None {
		world_fail(w, "named edit: tree_read: %v", rerr)
		return
	}
	for line in ([]string{NV_BASE, NV_KEPT, NV_TOOL, NV_EDIT}) {
		want := 1
		if (line == NV_KEPT && !arm.named) || (line == NV_EDIT && !arm.edit) {
			want = 0
		}
		if c := strings.count(string(data), line); c != want {
			world_fail(w, "named edit: %v: %q appears %d times in a.txt on main, want %d (%q)", arm, strings.trim_space(line), c, want, string(data))
		}
	}
	return
}

@(test)
named_version_edit :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for bits in 0 ..< 8 {
		arm := Named_Edit_Arm{elsewhere = bits & 1 != 0, edit = bits & 2 != 0, named = bits & 4 != 0}
		named, behind, bad := 0, 0, 0
		for seed in u64(1) ..= 20 {
			failures, res := named_edit_run(seed, arm)
			for f in failures {
				fmt.eprintf("named_version_edit seed %d: %s\n", seed, f)
				delete(f)
			}
			bad += 1 if len(failures) > 0 else 0
			testing.expect(t, len(failures) == 0, fmt.tprintf("named_version_edit seed %d %v failed", seed, arm))
			delete(failures)
			named += 1 if res.named else 0
			behind += 1 if res.behind else 0
		}
		fmt.eprintf("named_version_edit: elsewhere=%v edit=%v named=%v: %d of 20 named, %d behind, %d failed\n", arm.elsewhere, arm.edit, arm.named, named, behind, bad)
		testing.expect(t, !arm.named || (named > 0 && behind > 0), fmt.tprintf("named_version_edit %v: no run had a named version with the disk behind", arm))
	}
}

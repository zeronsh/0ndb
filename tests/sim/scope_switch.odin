package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

SCOPE_SWITCH_ROOT :: "/work/scope-switch-n0-git"

@(private = "file")
_scope_switch :: proc(w: ^World) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "scope switch: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "scope-switch")
		if err != .None {
			world_fail(w, "scope switch: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "scope switch: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("main a\n")}}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, SCOPE_SWITCH_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "scope switch: git checkout: %v", err)
		return
	}
	feature := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("feature a\n")}}
	if err := git_branch_commit(vfs, SCOPE_SWITCH_ROOT, "feature", feature[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "scope switch: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, SCOPE_SWITCH_ROOT); err != .None {
		world_fail(w, "scope switch: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SCOPE_SWITCH_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	sm: ^Sim_Mount
	for &x in n.mounts {
		if x.root == SCOPE_SWITCH_ROOT && x.m != nil {
			sm = &x
		}
	}
	if sm == nil {
		world_fail(w, "scope switch: mount missing")
		return
	}
	abs := SCOPE_SWITCH_ROOT + "/a.txt"
	for key in ([]string{"git:refs/heads/feature", "git:refs/heads/main"}) {
		{
			context = instance_context(&n.inst)
			defer node_after(n)
			if err := fs.mount_line_switch(sm.m, key); err != .None {
				world_fail(w, "scope switch: switch to %s: %v", key, err)
				return
			}
		}
		run_until(w, w.now + 20_000_000_000, true)
	}
	if err := _scope_switch_write(vfs, abs, transmute([]u8)string("main a\nmain edit\n")); err != .None {
		world_fail(w, "scope switch: main edit: %v", err)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	{
		context = instance_context(&n.inst)
		fs.mount_sync(sm.m)
		node_after(n)
	}
	scope: ^fs.Scope
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		if err := fs.mount_line_switch(sm.m, "git:refs/heads/feature"); err != .None {
			world_fail(w, "scope switch: line switch: %v", err)
			return
		}
		if _, pending := fs.mount_switch_pending(sm.m); !pending {
			return
		}
		actor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		scope = fs.scope_open(n.reg, sm.m, sid, actor)
		base, _ := prim.read_file(vfs, abs, context.temp_allocator)
		fs.scope_read_base(scope, "a.txt", base)
	}
	run_until(w, w.now + 20_000_000_000, true)
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		if to, pending := fs.mount_switch_pending(sm.m); pending {
			world_fail(w, "scope switch: the switch to %s did not complete", to)
			return
		}
		n.writers[strings.clone(abs, w.allocator)] = Writer_Info{scope = scope, agent = true}
		if err := _scope_switch_write(vfs, abs, transmute([]u8)string("main a\nmain edit\nagent line\n")); err != .None {
			world_fail(w, "scope switch: write: %v", err)
			return
		}
		if err := fs.scope_close(n.reg, scope); err != .None {
			world_fail(w, "scope switch: scope_close after the switch: %v", err)
		}
		key, _ := delete_key(&n.writers, abs)
		delete(key, w.allocator)
	}
	run_until(w, w.now + 2_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	got, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line_eng(line_norm("git:refs/heads/feature")))
	disk, _ := prim.read_file(vfs, abs, context.temp_allocator)
	if string(got) != string(disk) {
		world_fail(w, "scope switch: feature's a.txt is %q but the disk holds %q", string(got), string(disk))
	}
	if string(disk) != "main a\nmain edit\nagent line\n" {
		world_fail(w, "scope switch: feature's a.txt is %q", string(got))
	}
	main, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if string(main) != "main a\nmain edit\n" {
		world_fail(w, "scope switch: main's a.txt is %q", string(main))
	}
}

@(private = "file")
_scope_switch_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(test)
scope_across_switch :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	ran := 0
	for seed in u64(1) ..= 8 {
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
		w := new(World)
		world_init(w, cfg)
		_scope_switch(w)
		for f in w.failures {
			fmt.eprintf("scope_across_switch seed %d: %s\n", seed, f)
		}
		testing.expect(t, len(w.failures) == 0, fmt.tprintf("scope_across_switch seed %d failed", seed))
		world_destroy(w)
		free(w)
		ran += 1
	}
	fmt.eprintf("scope_across_switch: %d seeds\n", ran)
}

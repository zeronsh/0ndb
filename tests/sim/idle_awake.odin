package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"

@(private = "file")
_ia_case :: proc(w: ^World, mounts: int) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "idle awake: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	when_s := clock_wall(&n.clock) / 1_000_000_000
	for k in 0 ..< mounts {
		tree: eng.Object
		{
			context = instance_context(&n.inst)
			space, err := eng.space_create(&n.e, "idle")
			if err != .None {
				world_fail(w, "idle awake: space_create: %v", err)
				return
			}
			eng.space_open(&n.e, space)
			if tree, err = eng.tree_create(&n.e, space, "work"); err != .None {
				world_fail(w, "idle awake: tree_create: %v", err)
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
		root := fmt.aprintf("/work/idle%d-n0-git", k, allocator = w.allocator)
		files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("main a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
		if err := git_checkout_create(vfs, root, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
			world_fail(w, "idle awake: git create: %v", err)
			return
		}
		other := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("other b\n")}}
		if err := git_branch_commit(vfs, root, "other", other[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
			world_fail(w, "idle awake: git branch: %v", err)
			return
		}
		if err := node_mount(w, n, oi, root); err != .None {
			world_fail(w, "idle awake: mount: %v", err)
			return
		}
		append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(root, w.allocator)})
	}
	if !run_until(w, w.now + 600_000_000_000, true) {
		world_fail(w, "idle awake: never idle after mounting")
	}
	check_idle(w)
	for k in 0 ..< mounts {
		root := fmt.aprintf("/work/idle%d-n0-git", k, allocator = w.allocator)
		changes := make([dynamic]Git_Change, context.temp_allocator)
		if res, err := git_checkout(vfs, root, "other", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
			world_fail(w, "idle awake: checkout: %v %v", res, err)
			return
		}
	}
	{
		context = instance_context(&n.inst)
		node_after(n)
	}
	if !run_until(w, w.now + 600_000_000_000, true) {
		world_fail(w, "idle awake: never idle after the checkout")
	}
	check_idle(w)
	for &sm in n.mounts {
		if sm.m != nil && sm.m.awake {
			world_fail(w, "idle awake: %s is awake after a checkout and 600 s", sm.root)
		}
	}
}

@(private = "file")
_ia_sub :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
}

@(private = "file")
_ia_subscribe :: proc(w: ^World) {
	_ia_case(w, 1)
	n := w.nodes[0]
	if len(w.failures) > 0 || len(n.mounts) != 1 || n.mounts[0].m == nil {
		return
	}
	m := n.mounts[0].m
	tree := w.model.objs[len(w.model.objs) - 1].o
	if m.awake || m.history.awake {
		world_fail(w, "idle subscribe: the mount (%v) or its history (%v) is awake before the subscription", m.awake, m.history.awake)
		return
	}
	sub: eng.Sub_Id
	{
		context = instance_context(&n.inst)
		err: eng.Error
		sub, err = eng.subscribe(&n.e, tree, .File_Tree, _ia_sub, w)
		if err != .None {
			world_fail(w, "idle subscribe: %v", err)
			return
		}
		if !m.history.awake {
			world_fail(w, "idle subscribe: the subscription did not wake the history, so it does not reach the own length")
		}
		node_after(n)
	}
	if !run_until(w, w.now + 600_000_000_000, true) {
		world_fail(w, "idle subscribe: never idle")
	}
	check_idle(w)
	if m.history.awake {
		world_fail(w, "idle subscribe: the history is still awake 600 s after the subscription")
	}
	context = instance_context(&n.inst)
	eng.unsubscribe(&n.e, sub)
	node_after(n)
}

@(private = "file")
_ia_config :: proc(seed: u64) -> Config {
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
	return cfg
}

@(test)
idle_wakes :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 6 {
		w := new(World)
		world_init(w, _ia_config(seed))
		_ia_subscribe(w)
		for f in w.failures {
			fmt.eprintf("idle_wakes subscribe seed %d: %s\n", seed, f)
		}
		testing.expectf(t, len(w.failures) == 0, "idle_wakes subscribe seed %d failed", seed)
		world_destroy(w)
		free(w)
	}
}

@(test)
idle_awake :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for storage in ([]eng.Storage_Mode{.Auto, .Device_Until_Run}) {
		for seed in u64(1) ..= 12 {
			for mounts in 1 ..= 3 {
				cfg := _ia_config(seed)
				cfg.storage = storage
				w := new(World)
				world_init(w, cfg)
				_ia_case(w, mounts)
				for f in w.failures {
					fmt.eprintf("idle_awake %v seed %d mounts %d: %s\n", storage, seed, mounts, f)
				}
				testing.expectf(t, len(w.failures) == 0, "idle_awake %v seed %d mounts %d failed", storage, seed, mounts)
				world_destroy(w)
				free(w)
			}
		}
	}
}

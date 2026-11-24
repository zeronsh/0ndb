package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
RT_ROOT :: "/work/replay-n0"

@(private = "file")
RT_FILE :: RT_ROOT + "/b.txt"

@(private = "file")
_rt_settle :: proc(w: ^World, secs: i64) {
	run_until(w, w.now + secs * 1_000_000_000, true)
}

@(private = "file")
_rt_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == RT_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_rt_scope :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, actor: prim.Id) -> ^fs.Scope {
	return fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), actor)
}

@(private = "file")
_rt_write :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, scope: ^fs.Scope, data: string) -> bool {
	_writer_set(w, n, RT_FILE, Writer_Info{scope = scope, agent = true})
	if err := fs.mount_observe_begin(sm.m, "b.txt", scope); err != .None {
		world_fail(w, "replay twice: observe: %v", err)
		return false
	}
	if err := _disk_write(disk_vfs(&n.disk), RT_FILE, transmute([]u8)data, false); err != .None {
		world_fail(w, "replay twice: write: %v", err)
		return false
	}
	err := fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	if err != .None {
		world_fail(w, "replay twice: scope close: %v", err)
		return false
	}
	return true
}

@(private = "file")
_rt_text :: proc(n: ^Node, tree: eng.Object) -> string {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, _ := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator)
	return strings.clone(string(data), n.w.allocator)
}

@(private = "file")
_rt_run :: proc(w: ^World, cut: u64) -> (cuts: int) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "replay twice: node start")
		return
	}
	m := &w.model
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "replay")
		if err == .None {
			err = eng.space_open(&n.e, space)
		}
		if err == .None {
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		if err != .None {
			world_fail(w, "replay twice: setup: %v", err)
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
	prim.mkdir_all(disk_vfs(&n.disk), RT_ROOT, 0o755)
	_disk_write(disk_vfs(&n.disk), RT_FILE, transmute([]u8)string("base\n"), false)
	if err := node_mount(w, n, oi, RT_ROOT); err != .None {
		world_fail(w, "replay twice: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(RT_ROOT, w.allocator)})
	_rt_settle(w, 10)
	sm := _rt_mount(n)
	if sm == nil {
		world_fail(w, "replay twice: mount missing")
		return
	}
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		hold := _rt_scope(w, n, sm, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		fs.scope_write_begin(hold, "b.txt")
		ractor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		reader := _rt_scope(w, n, sm, ractor)
		fs.scope_read_base(reader, "b.txt", transmute([]u8)string("base\n"))
		if !fs.scope_pinned(hold, "b.txt") || !fs.scope_pinned(reader, "b.txt") {
			world_fail(w, "replay twice: the scopes pinned nothing")
			return
		}
		v: fs.Version
		if _, err := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator, {}, "", nil, &v); err != .None {
			world_fail(w, "replay twice: read: %v", err)
			return
		}
		if err := eng.tree_write(&n.e, tree, "b.txt", transmute([]u8)string("base\nkept\n"), v); err != .None && err != .Pending {
			world_fail(w, "replay twice: tree_write: %v", err)
			return
		}
		other := _rt_scope(w, n, sm, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		if !_rt_write(w, n, sm, other, "base\nother agent\n") {
			return
		}
		before := _line_heads(sm.m, w.allocator)
		if !_rt_write(w, n, sm, reader, "base\nreader one\nreader two\n") {
			return
		}
		after := _line_heads(sm.m, w.allocator)
		if err := fs.mount_revert(sm.m, fs.Version(before), fs.Version(after), ractor); err != .None {
			world_fail(w, "replay twice: revert: %v", err)
			return
		}
	}
	want := ""
	for _ in 0 ..< 200 {
		run_until(w, w.now + 5_000_000, false)
		if n.durable >= eng.pending_seq(&n.e) {
			break
		}
	}
	want = _rt_text(n, tree)
	if !strings.contains(want, "other agent") || !strings.contains(want, "kept") || strings.contains(want, "reader") {
		world_fail(w, "replay twice: before any cut the tree holds %q", want)
		return
	}
	node_crash_now(n, .Power, 1)
	if cut > 0 {
		n.disk.crash_at = n.disk.stats.ops + cut
	}
	crashes := w.stats.crashes
	for _ in 0 ..< 60 {
		run_until(w, w.now + 1_000_000_000, false)
		if n.alive && n.disk.crash_at == 0 {
			break
		}
	}
	n.disk.crash_at = 0
	cuts = int(w.stats.crashes - crashes)
	_rt_settle(w, 30)
	if !n.alive || _rt_mount(n) == nil {
		world_fail(w, "replay twice: n0 is not mounted after the cuts")
		return
	}
	got := _rt_text(n, tree)
	if !strings.contains(got, "other agent") {
		world_fail(w, "replay twice: cut %d: an acked agent line is gone from the tree: %q, before the cuts %q", cut, got, want)
	}
	if !strings.contains(got, "kept") {
		world_fail(w, "replay twice: cut %d: an acked tree_write line is gone from the tree: %q, before the cuts %q", cut, got, want)
	}
	if strings.contains(got, "reader") {
		world_fail(w, "replay twice: cut %d: a rewound turn came back: %q", cut, got)
	}
	disk, _, _ := disk_probe_read(&n.disk, RT_FILE)
	if string(disk) != got {
		world_fail(w, "replay twice: cut %d: the disk holds %q, the tree %q", cut, string(disk), got)
	}
	return
}

@(private = "file")
_rt_case :: proc(seed: u64, cut: u64) -> (cuts: int, failures: [dynamic]string) {
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
	cuts = _rt_run(w, cut)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(test)
replay_twice :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	second, bad := 0, 0
	from := env_u64("RT_FROM", 0)
	to := env_u64("RT_TO", 4000)
	for seed in u64(1) ..= 2 {
		for cut := from; cut <= to; cut += 1 {
			cuts, failures := _rt_case(seed, cut)
			second += int(cuts > 0)
			for f in failures {
				if bad < int(env_u64("RT_PRINT", 20)) {
					fmt.eprintf("replay_twice seed %d cut %d: %s\n", seed, cut, f)
				}
				delete(f)
			}
			bad += len(failures)
			delete(failures)
			if cut > 0 && cuts == 0 {
				break
			}
		}
	}
	fmt.eprintf("replay_twice: %d runs cut twice, %d failed\n", second, bad)
	testing.expectf(t, bad == 0, "replay_twice: %d failures", bad)
	testing.expectf(t, second > 0, "replay_twice never cut twice")
	free_all(context.temp_allocator)
}

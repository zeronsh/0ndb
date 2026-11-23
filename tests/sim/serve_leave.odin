package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
SL_ROOT :: "/work/serve-n1"

@(private = "file")
_sl_case :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_sl_run(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_sl_rows :: proc(n: ^Node, space: prim.Id) -> int {
	context = instance_context(&n.inst)
	defer node_after(n)
	rows, err := eng.serve_rows(&n.e, context.temp_allocator)
	if err != .None {
		return -1
	}
	k := 0
	for r in rows {
		if r.space == space {
			k += 1
		}
	}
	return k
}

@(private = "file")
_sl_run :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "serve-leave: relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "serve-leave: node start")
		return
	}
	space: prim.Id
	tree: eng.Object
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		if space, err = eng.space_create(&a.e, "serve-leave", "relay", w.relay.public); err != .None {
			world_fail(w, "serve-leave: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "serve-leave: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "serve-leave: tree_create: %v", err)
			return
		}
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "serve-leave: member_add: %v", err)
			return
		}
	}
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "serve-leave", "relay", w.relay.public); err != .None {
			world_fail(w, "serve-leave: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "serve-leave: n1 space_open: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		vfs := disk_vfs(&b.disk)
		if b.reg == nil {
			reg, rerr := eng.registry(&b.e)
			if rerr != .None {
				world_fail(w, "serve-leave: registry: %v", rerr)
				return
			}
			b.reg = reg
		}
		if prim.mkdir_all(vfs, SL_ROOT, 0o755) != .None {
			world_fail(w, "serve-leave: mkdir")
			return
		}
		if _, err := eng.tree_mount(&b.e, tree, SL_ROOT); err != .None {
			world_fail(w, "serve-leave: n1 tree_mount: %v", err)
			return
		}
		data := make([]u8, 4096, context.temp_allocator)
		x := w.cfg.seed * 0x9e37_79b9_7f4a_7c15 + 1
		for i in 0 ..< len(data) {
			x ~= x << 13
			x ~= x >> 7
			x ~= x << 17
			data[i] = u8(x)
		}
		data[0] = 0
		fd, oerr := prim.open_file(vfs, SL_ROOT + "/a.bin", {.Write, .Create, .Truncate}, 0o644)
		if oerr != .None {
			world_fail(w, "serve-leave: open a.bin: %v", oerr)
			return
		}
		werr := prim.write_at(vfs, fd, data, 0)
		if werr == .None {
			werr = prim.datasync(vfs, fd)
		}
		prim.close_file(vfs, fd)
		if werr != .None {
			world_fail(w, "serve-leave: write a.bin: %v", werr)
			return
		}
	}
	run_until(w, w.now + 10_000_000_000, true)
	if k := _sl_rows(b, space); k <= 0 {
		world_fail(w, "serve-leave: n1 holds no serve row for the blob it wrote before leaving (%d)", k)
		return
	}
	leave: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_leave(&b.e, space); err != .None {
			world_fail(w, "serve-leave: space_leave: %v", err)
			return
		}
	}
	run_until(w, w.now + 30_000_000_000, true)
	check_serve_rows(w)
}

@(test)
serve_leave :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 2 {
		failures := _sl_case(seed)
		for f in failures {
			fmt.eprintf("serve_leave seed %d: %s\n", seed, f)
			delete(f)
		}
		testing.expectf(t, len(failures) == 0, "serve_leave seed %d failed", seed)
		delete(failures)
	}
	free_all(context.temp_allocator)
}

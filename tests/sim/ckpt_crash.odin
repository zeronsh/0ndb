package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
CC_ROOT :: "/work/ckpt-n0"

@(private = "file")
_cc_case :: proc(seed: u64, k: u64, storage: eng.Storage_Mode) -> (crashed: bool, failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 3
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.storage = storage
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	crashed = _cc_run(w, k)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_cc_data :: proc(seed: u64) -> []u8 {
	data := make([]u8, 4096, context.temp_allocator)
	x := seed * 0x9e37_79b9_7f4a_7c15 + 7
	for i in 0 ..< len(data) {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		data[i] = u8(x)
	}
	data[0] = 0
	return data
}

@(private = "file")
_cc_join :: proc(w: ^World, a, b: ^Node, space: prim.Id) -> bool {
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		p, err := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if err != .None {
			world_fail(w, "ckpt-crash: member_add %s: %v", b.name, err)
			return false
		}
		proof = p
	}
	context = instance_context(&b.inst)
	defer node_after(b)
	if _, err := eng.space_join_enrollment(&b.e, space, proof, "ckpt-crash", "relay", w.relay.public); err != .None {
		world_fail(w, "ckpt-crash: %s space_join_enrollment: %v", b.name, err)
		return false
	}
	if err := eng.space_open(&b.e, space); err != .None {
		world_fail(w, "ckpt-crash: %s space_open: %v", b.name, err)
		return false
	}
	return true
}

@(private = "file")
_cc_run :: proc(w: ^World, k: u64) -> (crashed: bool) {
	if !relay_start(&w.relay) {
		world_fail(w, "ckpt-crash: relay start")
		return
	}
	a, c := w.nodes[0], w.nodes[2]
	if !node_start(a) {
		world_fail(w, "ckpt-crash: node start")
		return
	}
	space: prim.Id
	tree: eng.Object
	data := _cc_data(w.cfg.seed)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		if space, err = eng.space_create(&a.e, "ckpt-crash", "relay", w.relay.public); err != .None {
			world_fail(w, "ckpt-crash: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "ckpt-crash: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "ckpt-crash: tree_create: %v", err)
			return
		}
		if a.reg == nil {
			reg, rerr := eng.registry(&a.e)
			if rerr != .None {
				world_fail(w, "ckpt-crash: registry: %v", rerr)
				return
			}
			a.reg = reg
		}
		vfs := disk_vfs(&a.disk)
		if prim.mkdir_all(vfs, CC_ROOT, 0o755) != .None {
			world_fail(w, "ckpt-crash: mkdir")
			return
		}
		if _, err = eng.tree_mount(&a.e, tree, CC_ROOT); err != .None {
			world_fail(w, "ckpt-crash: tree_mount: %v", err)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	a.partitioned = true
	for x in a.conns {
		conn_reset(x, true)
	}
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		vfs := disk_vfs(&a.disk)
		fd, oerr := prim.open_file(vfs, CC_ROOT + "/a.bin", {.Write, .Create, .Truncate}, 0o644)
		if oerr != .None {
			world_fail(w, "ckpt-crash: open a.bin: %v", oerr)
			return
		}
		werr := prim.write_at(vfs, fd, data, 0)
		if werr == .None {
			werr = prim.datasync(vfs, fd)
		}
		prim.close_file(vfs, fd)
		if werr != .None {
			world_fail(w, "ckpt-crash: write a.bin: %v", werr)
			return
		}
	}
	run_until(w, w.now + 2_000_000_000, true)
	crashes := w.stats.crashes
	{
		context = instance_context(&a.inst)
		a.disk.crash_at = a.disk.stats.ops + k
		eng.object_promote_run(&a.e, tree)
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	a.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	for _ in 0 ..< 40 {
		if a.alive && a.e_open {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !a.alive || !a.e_open {
		world_fail(w, "ckpt-crash: n0 did not restart after the crash at op %d", k)
		return
	}
	a.partitioned = false
	run_until(w, w.now + 20_000_000_000, true)
	if !node_start(c) || !_cc_join(w, a, c, space) {
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	a.partitioned = true
	for x in a.conns {
		conn_reset(x, true)
	}
	croot :: "/work/ckpt-n2"
	{
		context = instance_context(&c.inst)
		defer node_after(c)
		if c.reg == nil {
			reg, rerr := eng.registry(&c.e)
			if rerr != .None {
				world_fail(w, "ckpt-crash: n2 registry: %v", rerr)
				return
			}
			c.reg = reg
		}
		if prim.mkdir_all(disk_vfs(&c.disk), croot, 0o755) != .None {
			world_fail(w, "ckpt-crash: n2 mkdir")
			return
		}
		if _, err := eng.tree_mount(&c.e, tree, croot); err != .None {
			world_fail(w, "ckpt-crash: n2 tree_mount: %v", err)
			return
		}
	}
	got: []u8
	for _ in 0 ..< 12 {
		run_until(w, w.now + 60_000_000_000, true)
		d, rerr := prim.read_file(disk_vfs(&c.disk), croot + "/a.bin", context.temp_allocator)
		if rerr == .None && string(d) == string(data) {
			got = d
			break
		}
	}
	if string(got) != string(data) {
		world_fail(w, "ckpt-crash: after a crash at op %d of n0's promotion, a fresh n2 cannot materialize a.bin with n0 offline", k)
	}
	a.partitioned = false
	return
}

@(test)
ckpt_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	only := env_u64("SIM_CC_K", 0)
	for storage in ([]eng.Storage_Mode{.Auto}) do for seed in u64(1) ..= 2 {
		for k := max(only, 1); k < 4000; k += 1 {
			crashed, failures := _cc_case(seed, k, storage)
			for f in failures {
				fmt.eprintf("ckpt_crash %v seed %d crash %d: %s\n", storage, seed, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "ckpt_crash %v seed %d crash at op %d failed", storage, seed, k)
			n := len(failures)
			delete(failures)
			if !crashed || n > 0 || only != 0 {
				break
			}
		}
	}
	free_all(context.temp_allocator)
}

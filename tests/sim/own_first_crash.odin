package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
_ofc_case :: proc(seed: u64, k: u64) -> (crashed: bool, failures: [dynamic]string) {
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
	crashed = _ofc_run(w, k)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ofc_run :: proc(w: ^World, k: u64) -> (crashed: bool) {
	if !relay_start(&w.relay) {
		world_fail(w, "own-first: relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "own-first: node start")
		return
	}
	space: prim.Id
	tree: eng.Object
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		if space, err = eng.space_create(&a.e, "own-first", "relay", w.relay.public); err != .None {
			world_fail(w, "own-first: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "own-first: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "own-first: tree_create: %v", err)
			return
		}
		if err = eng.tree_write(&a.e, tree, "a.txt", transmute([]u8)string("one\n")); err != .None {
			world_fail(w, "own-first: n0 tree_write: %v", err)
			return
		}
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "own-first: member_add: %v", err)
			return
		}
	}
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "own-first", "relay", w.relay.public); err != .None {
			world_fail(w, "own-first: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "own-first: n1 space_open: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	crashes := w.stats.crashes
	{
		context = instance_context(&b.inst)
		b.disk.crash_at = b.disk.stats.ops + k
		eng.tree_write(&b.e, tree, "a.txt", transmute([]u8)string("two\n"))
		node_after(b)
	}
	run_until(w, w.now + 5_000_000_000, true)
	b.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	for _ in 0 ..< 40 {
		if b.alive && b.e_open {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !b.alive || !b.e_open {
		world_fail(w, "own-first: n1 did not restart after the crash at op %d", k)
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	check_own_marked(w)
	check_uploaded(w)
	check_derived(b, fmt.tprintf("own-first crash at op %d", k))
	return
}

@(test)
own_first_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 2 {
		for k := u64(1); k < 4000; k += 1 {
			crashed, failures := _ofc_case(seed, k)
			for f in failures {
				fmt.eprintf("own_first_crash seed %d crash %d: %s\n", seed, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "own_first_crash seed %d crash at op %d failed", seed, k)
			n := len(failures)
			delete(failures)
			if !crashed || n > 0 {
				break
			}
		}
	}
	free_all(context.temp_allocator)
}

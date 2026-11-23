package sim

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
_md_case :: proc(seed: u64, k: u64) -> (crashed: bool, failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
	cfg.spaces = 1
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
	crashed = _md_run(w, k)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_md_run :: proc(w: ^World, k: u64) -> (crashed: bool) {
	ok := relay_start(&w.relay)
	for n in w.nodes {
		ok = ok && node_start(n)
	}
	if !ok || !setup_spaces(w) {
		world_fail(w, "mount durable: world start")
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	a := w.nodes[0]
	crashes := w.stats.crashes
	a.disk.crash_at = a.disk.stats.ops + k
	op_git_mount(w, a)
	run_until(w, w.now + 5_000_000_000, true)
	a.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	if !crashed {
		acked := false
		for mm in w.model.mounts {
			acked ||= mm.node == a.idx
		}
		if !acked {
			world_fail(w, "mount durable: with no crash, n0's git checkout mount was never acknowledged")
		}
		return
	}
	for _ in 0 ..< 40 {
		if a.alive {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !a.alive {
		world_fail(w, "mount durable: n0 did not restart after the crash at op %d", k)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	return
}

@(test)
mount_durable :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 2 {
		for k := u64(1); k < 6000; k += 1 {
			crashed, failures := _md_case(seed, k)
			for f in failures {
				fmt.eprintf("mount_durable seed %d crash %d: %s\n", seed, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "mount_durable seed %d crash at op %d failed", seed, k)
			n := len(failures)
			delete(failures)
			if !crashed || n > 0 {
				break
			}
		}
	}
	free_all(context.temp_allocator)
}

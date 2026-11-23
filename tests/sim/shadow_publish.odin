package sim

import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/fs"
import "../../src/fstree"

@(private = "file")
SP_DIR :: "/data/publish/shadow"

@(private = "file")
SP_NAMES :: [?]string{"a.txt", "b.txt", "c.txt"}

@(private = "file")
_sp_case :: proc(k: u64, mode: Crash_Mode, stick: bool) -> (hit: bool, failures: [dynamic]string) {
	failures = make([dynamic]string)
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
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	hit = _sp_run(w, k, mode, stick)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_sp_run :: proc(w: ^World, k: u64, mode: Crash_Mode, stick: bool) -> (hit: bool) {
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "shadow publish: node start")
		return
	}
	vfs := disk_vfs(&a.disk)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		s := new(fs.Shadow)
		if err := fs.shadow_open(s, vfs, SP_DIR, .Sha1); err != .None {
			world_fail(w, "shadow publish: shadow_open: %v", err)
			return
		}
		names := SP_NAMES
		for name, i in names {
			e := fs.Entry{inode = fstree.Inode_Id{1, u64(i + 1)}, kind = .File}
			e.oid[0] = u8(i + 1)
			if err := fs.shadow_put(s, name, e); err != .None {
				world_fail(w, "shadow publish: shadow_put %s: %v", name, err)
				return
			}
		}
		if err := fs.shadow_persist(s); err != .None {
			world_fail(w, "shadow publish: shadow_persist: %v", err)
			return
		}
		injected := a.disk.stats.injected
		a.disk.fail_root = SP_DIR
		a.disk.fail_nth = k
		a.disk.fail_stick = stick
		cerr := fs.shadow_compact(s)
		hit = a.disk.stats.injected > injected
		a.disk.fail_nth = 0
		a.disk.fail_stick = false
		a.disk.fail_stuck = false
		a.disk.fail_root = ""
		if !hit {
			if cerr != .None {
				world_fail(w, "shadow publish: a compaction with no injected fault failed: %v", cerr)
			}
			fs.shadow_close(s)
			return
		}
	}
	node_crash_now(a, mode, k)
	for _ in 0 ..< 40 {
		if a.alive {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !a.alive {
		world_fail(w, "shadow publish: n0 did not restart after the cut at compaction op %d", k)
		return
	}
	context = instance_context(&a.inst)
	defer node_after(a)
	s: fs.Shadow
	if err := fs.shadow_open(&s, vfs, SP_DIR, .Sha1); err != .None {
		world_fail(w, "shadow publish: reopen after a compaction failed at shadow op %d (sticky %v) and a %v crash: %v", k, stick, mode, err)
		return
	}
	defer fs.shadow_close(&s)
	names := SP_NAMES
	for name, i in names {
		e, found, gerr := fs.shadow_get(&s, name)
		if gerr != .None || !found || e.inode != (fstree.Inode_Id{1, u64(i + 1)}) {
			world_fail(w, "shadow publish: after a compaction failed at shadow op %d (sticky %v) and a %v crash, the reopened shadow lost %s (found %v, %v, inode %v)", k, stick, mode, name, found, gerr, e.inode)
		}
	}
	return
}

@(test)
shadow_publish :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for stick in ([]bool{false, true}) {
		for mode in Crash_Mode {
			for k := u64(1); k < 400; k += 1 {
				hit, failures := _sp_case(k, mode, stick)
				for f in failures {
					fmt.eprintf("shadow_publish %v sticky=%v op %d: %s\n", mode, stick, k, f)
					delete(f)
				}
				testing.expectf(t, len(failures) == 0, "shadow_publish %v sticky=%v op %d failed", mode, stick, k)
				n := len(failures)
				delete(failures)
				if !hit || n > 0 {
					break
				}
			}
		}
	}
	free_all(context.temp_allocator)
}

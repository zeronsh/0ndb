package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import dl "../../src/dlog"
import "../../src/prim"

@(private = "file")
DL_DIR :: "/dl"
@(private = "file")
DL_PATH :: "/dl/buffer-deletes"

@(private = "file")
_dl_entry :: proc(k: int, seed: u64) -> dl.Entry {
	spans := make([]dl.Span, 1 + k % 3, context.temp_allocator)
	for &s, i in spans {
		s.actor[0] = u8(k + 1)
		s.actor[15] = u8(seed)
		s.seq = u64(k * 100 + i * 7) + seed
		s.len = 1 + (k + i) % 13
	}
	x := dl.Entry {
		kind  = u8(1 + k % 2),
		line  = "main" if k % 2 == 0 else "",
		spans = spans,
	}
	x.space[0] = 9
	x.object[0] = u8(10 + k)
	x.inode_actor[1] = u8(k)
	x.inode_seq = u64(k)
	x.actor[2] = u8(k + 3)
	return x
}

@(private = "file")
_dl_same :: proc(a, b: dl.Entry) -> bool {
	if a.space != b.space || a.object != b.object || a.kind != b.kind || a.inode_actor != b.inode_actor || a.inode_seq != b.inode_seq || a.actor != b.actor || a.line != b.line || len(a.spans) != len(b.spans) {
		return false
	}
	for s, i in a.spans {
		if s != b.spans[i] {
			return false
		}
	}
	return true
}

@(private = "file")
_dl_case :: proc(mode: Crash_Mode, crash: u64, seed: u64) -> (crashed: bool, msg: string) {
	d: Disk
	disk_init(&d, "dlog", runtime.heap_allocator())
	defer disk_destroy(&d)
	vfs := disk_vfs(&d)
	if prim.mkdir_all(vfs, DL_DIR, 0o700) != .None {
		return false, "setup: mkdir failed"
	}
	if prim.sync_dir(vfs, "/") != .None {
		return false, "setup: the directory did not sync"
	}
	a := runtime.heap_allocator()
	l: dl.Log
	if dl.open(&l, vfs, DL_PATH, a) != .None {
		return false, "setup: the log did not open"
	}
	N :: 3
	want: [N]dl.Entry
	ids: [N]u64
	added, done, tried: [N]bool
	for k in 0 ..< N {
		want[k] = _dl_entry(k, seed)
	}
	d.crash_at = d.stats.ops + crash
	run: {
		for k in 0 ..< N {
			id, err := dl.add(&l, want[k])
			if err != .None || d.dead {
				break run
			}
			ids[k], added[k] = id, true
		}
		for k in 0 ..< N {
			j := (k + int(seed)) % N
			tried[j] = true
			if dl.done(&l, ids[j]) != .None || d.dead {
				break run
			}
			done[j] = true
		}
	}
	crashed = d.dead
	d.crash_at = 0
	l.open = false
	dl.close(&l)
	if !crashed {
		if prim.exists(vfs, DL_PATH) {
			return false, "settled: the log file stayed after its last delete was done"
		}
		return false, ""
	}
	rng: Rng
	rng_init(&rng, seed, crash)
	disk_crash(&d, mode, &rng)
	l2: dl.Log
	if dl.open(&l2, vfs, DL_PATH, a) != .None {
		return true, "recovery: the log did not reopen"
	}
	defer dl.close(&l2)
	for x in l2.live {
		k := -1
		for i in 0 ..< N {
			if _dl_same(x, want[i]) {
				k = i
			}
		}
		if k < 0 {
			return true, fmt.tprintf("recovery: a replayed entry matches nothing written (%v)", x)
		}
		if done[k] {
			return true, fmt.tprintf("recovery: entry %d came back after its done was durable", k)
		}
	}
	for k in 0 ..< N {
		if !added[k] || tried[k] {
			continue
		}
		found := false
		for x in l2.live {
			found ||= _dl_same(x, want[k])
		}
		if !found {
			return true, fmt.tprintf("recovery: entry %d was durable and not done, but did not replay (%d live)", k, len(l2.live))
		}
	}
	extra := _dl_entry(7, seed)
	if _, err := dl.add(&l2, extra); err != .None {
		return true, "recovery: the log refused an add after recovery"
	}
	dl.close(&l2)
	l2 = {}
	l3: dl.Log
	if dl.open(&l3, vfs, DL_PATH, a) != .None {
		return true, "recovery: the log did not reopen after a post-recovery add"
	}
	defer dl.close(&l3)
	got := false
	for x in l3.live {
		got ||= _dl_same(x, extra)
	}
	if !got {
		return true, "recovery: an add after recovery did not replay"
	}
	return true, ""
}

@(test)
dlog_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	cases, crashes := 0, 0
	for mode in Crash_Mode {
		for seed in u64(1) ..= 3 {
			for k := u64(1); ; k += 1 {
				crashed, msg := _dl_case(mode, k, seed)
				cases += 1
				if len(msg) > 0 {
					testing.expectf(t, false, "buffer delete log, %v crash at op %d (seed %d): %s", mode, k, seed, msg)
					return
				}
				free_all(context.temp_allocator)
				if !crashed {
					break
				}
				crashes += 1
			}
		}
	}
	fmt.eprintfln("dlog_crash: %d runs, %d crash points, all recovered", cases, crashes)
}

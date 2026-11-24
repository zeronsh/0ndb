package sim

import "base:runtime"
import "core:fmt"
import "core:testing"
import "../../src/prim"

@(private = "file")
_barrier_fill :: proc(b: u8) -> []u8 {
	x := make([]u8, SECTOR, context.temp_allocator)
	for i in 0 ..< SECTOR {
		x[i] = b
	}
	return x
}

@(private = "file")
_barrier_has :: proc(data: []u8, off: int, b: u8) -> (all, some: bool) {
	all = len(data) >= off + SECTOR
	for i in off ..< off + SECTOR {
		if i < len(data) && data[i] == b {
			some = true
		} else {
			all = false
		}
	}
	return
}

@(private = "file")
_barrier_case :: proc(seed: u64, flush: bool) -> (first, second: bool, msg: string) {
	d: Disk
	disk_init(&d, "barrier", runtime.heap_allocator())
	defer disk_destroy(&d)
	v := disk_vfs(&d)
	if prim.mkdir_all(v, "/b", 0o700) != .None || prim.sync_dir(v, "/b") != .None {
		return false, false, "setup: mkdir"
	}
	fd, oerr := prim.open_file(v, "/b/a", {.Write, .Create}, 0o600)
	if oerr != .None || prim.datasync(v, fd) != .None || prim.sync_dir(v, "/b") != .None {
		return false, false, "setup: open a"
	}
	other, cerr := prim.open_file(v, "/b/c", {.Write, .Create}, 0o600)
	if cerr != .None || prim.datasync(v, other) != .None || prim.sync_dir(v, "/b") != .None {
		return false, false, "setup: open c"
	}
	if prim.write_at(v, fd, _barrier_fill('a'), 0) != .None || prim.barrier(v, fd) != .None {
		return false, false, "the fenced write failed"
	}
	if prim.write_at(v, fd, _barrier_fill('b'), SECTOR) != .None || prim.write_at(v, other, _barrier_fill('c'), 0) != .None {
		return false, false, "the later writes failed"
	}
	if flush && prim.datasync(v, other) != .None {
		return false, false, "the other file's sync failed"
	}
	rng: Rng
	rng_init(&rng, seed, 7)
	disk_crash(&d, .Power, &rng)
	data, rerr := prim.read_file(v, "/b/a", context.temp_allocator)
	if rerr != .None {
		return false, false, fmt.tprintf("a did not read back: %v", rerr)
	}
	a_all, _ := _barrier_has(data, 0, 'a')
	_, b_some := _barrier_has(data, SECTOR, 'b')
	return a_all, b_some, ""
}

@(test)
disk_barrier :: proc(t: ^testing.T) {
	lost_first, kept_second := 0, 0
	for seed in u64(1) ..= 300 {
		first, second, msg := _barrier_case(seed, false)
		if msg != "" {
			testing.expectf(t, false, "barrier seed %d: %s", seed, msg)
			return
		}
		testing.expectf(t, first || !second, "barrier seed %d: a write issued after a barrier survived a crash that lost the write before it", seed)
		if !first {
			lost_first += 1
		}
		if second {
			kept_second += 1
		}
		flushed, _, fmsg := _barrier_case(seed, true)
		testing.expectf(t, fmsg == "" && flushed, "barrier seed %d: a fenced write was lost after another file's full sync (%s)", seed, fmsg)
	}
	testing.expectf(t, lost_first > 0, "a barrier alone made its write durable in every crash")
	testing.expectf(t, kept_second > 0, "no write issued after a barrier ever survived a crash")
}

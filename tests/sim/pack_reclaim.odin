package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
RC_PACK :: "/data/pack"

@(private = "file")
RC_WINDOW :: 1 << 20

@(private = "file")
RC_CONTAINER :: 2 << 20

@(private = "file")
RC_FILE :: 64 << 10

@(private = "file")
RC_FILES :: 64

@(private = "file")
RC_KEEP :: 3000

@(private = "file")
RC_LIMIT :: u64(14 << 20)

@(private = "file")
RC_IDLE :: u64(8 << 20)

@(private = "file")
Rc_Rig :: struct {
	pk:  pack.Pack,
	job: bool,
}

@(private = "file")
_rc_fill :: proc(seed: u32, n: int) -> []u8 {
	b := make([]u8, n, context.temp_allocator)
	x := seed * 2654435761 + 1
	for i in 0 ..< n {
		x ~= x << 13
		x ~= x >> 17
		x ~= x << 5
		b[i] = u8(x)
	}
	return b
}

@(private = "file")
_rc_open :: proc(d: ^Disk) -> (r: ^Rc_Rig, ok: bool) {
	r = new(Rc_Rig, runtime.heap_allocator())
	v := disk_vfs(d)
	if prim.mkdir_all(v, RC_PACK, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = RC_CONTAINER
	opts.log_window = RC_WINDOW
	opts.mem_budget = 256 << 10
	opts.worker = pack.Worker_Hook{data = r, submit = proc(data: rawptr) {
		(^Rc_Rig)(data).job = true
	}}
	opts.wake = proc(data: rawptr) {}
	opts.wake_data = r
	return r, pack.open(&r.pk, v, RC_PACK, opts, runtime.heap_allocator()) == .None
}

@(private = "file")
_rc_finish :: proc(r: ^Rc_Rig) -> prim.Error {
	if r.job {
		r.job = false
		pack.worker_run(&r.pk)
	}
	return pack.poll(&r.pk)
}

@(private = "file")
_rc_attempt :: proc(r: ^Rc_Rig, d: ^Disk, n: int, peak: ^u64) -> (done: bool) {
	v := pack.vfs(&r.pk)
	for i in 0 ..< RC_FILES {
		pb: [64]u8
		path := fmt.bprintf(pb[:], "%s/s/t%d", RC_PACK, i)
		fd, err := prim.open_file(v, path, {.Write, .Create, .Truncate, .Group_Visible}, 0o600)
		if err != .None {
			return false
		}
		werr := prim.write_at(v, fd, _rc_fill(u32(n * 1000 + i), RC_FILE), 0)
		prim.close_file(v, fd)
		peak^ = max(peak^, disk_bytes(d))
		free_all(context.temp_allocator)
		if werr != .None {
			return false
		}
	}
	return true
}

@(private = "file")
_rc_idle :: proc(r: ^Rc_Rig) -> (turns: int, ok: bool) {
	if _, e := pack.step(&r.pk); e != .None {
		return 0, false
	}
	for turns = 0; r.job && turns < 4000; turns += 1 {
		if _rc_finish(r) != .None {
			return turns, false
		}
	}
	if r.job {
		return turns, false
	}
	more, e := pack.step(&r.pk)
	return turns, e == .None && !more && !r.job
}

@(private = "file")
_rc_keep :: proc(r: ^Rc_Rig, write: bool) -> bool {
	v := pack.vfs(&r.pk)
	want := _rc_fill(7, RC_KEEP)
	if write {
		fd, err := prim.open_file(v, RC_PACK + "/s/keep", {.Write, .Create}, 0o600)
		if err != .None {
			return false
		}
		defer prim.close_file(v, fd)
		return prim.write_at(v, fd, want, 0) == .None && prim.datasync(v, fd) == .None
	}
	fd, err := prim.open_file(v, RC_PACK + "/s/keep", {}, 0)
	if err != .None {
		return false
	}
	defer prim.close_file(v, fd)
	got := make([]u8, RC_KEEP, context.temp_allocator)
	n, rerr := prim.read_at(v, fd, got, 0)
	return rerr == .None && n == RC_KEEP && string(got) == string(want)
}

@(private = "file")
_rc_case :: proc(attempts: int, k: u64) -> (msg: string, crashed: bool, reclaimed: u64) {
	d: Disk
	disk_init(&d, "reclaim", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _rc_open(&d)
	defer free(r, runtime.heap_allocator())
	if !ok || prim.mkdir_all(pack.vfs(&r.pk), RC_PACK + "/s", 0o700) != .None || !_rc_keep(r, true) || pack.sync(&r.pk) != .None {
		return "setup", false, 0
	}
	if k > 0 {
		d.crash_at = d.stats.ops + k
	}
	peak: u64
	logged: u64
	for n in 0 ..< attempts {
		pack.batch_begin(&r.pk)
		_rc_attempt(r, &d, n, &peak)
		pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r)
		if _rc_finish(r) != .None {
			break
		}
		if _, e := pack.step(&r.pk); e != .None {
			break
		}
		peak = max(peak, disk_bytes(&d))
		if d.dead {
			break
		}
	}
	logged = pack.stats(&r.pk).log_bytes
	if !d.dead {
		if peak > RC_LIMIT {
			return fmt.tprintf("the disk reached %d bytes while abandoned writers logged %d; the bound is %d", peak, logged, RC_LIMIT), false, 0
		}
		turns, done := _rc_idle(r)
		if !d.dead {
			if !done {
				return fmt.tprintf("compaction stopped or was still running with work left after %d completions and no writer", turns), false, 0
			}
			if b := disk_bytes(&d); b > RC_IDLE {
				return fmt.tprintf("idle: the disk holds %d bytes after the last job finished; the bound is %d (%d jobs followed)", b, RC_IDLE, turns), false, 0
			}
		}
	}
	reclaimed = pack.stats(&r.pk).compact_conts
	pack.close(&r.pk)
	if d.dead {
		crashed = true
		rng: Rng
		rng_init(&rng, 1, k)
		disk_crash(&d, .Power, &rng)
	}
	d.crash_at = 0
	r2, ok2 := _rc_open(&d)
	defer free(r2, runtime.heap_allocator())
	if !ok2 {
		return "the pack did not reopen", crashed, reclaimed
	}
	defer pack.close(&r2.pk)
	if !_rc_keep(r2, false) {
		return "the synced file lost its content", crashed, reclaimed
	}
	turns, done := _rc_idle(r2)
	if !done {
		return fmt.tprintf("after reopening, compaction was still running after %d completions", turns), crashed, reclaimed
	}
	if b := disk_bytes(&d); b > RC_IDLE {
		return fmt.tprintf("after reopening and going idle the disk holds %d bytes; the bound is %d", b, RC_IDLE), crashed, reclaimed
	}
	if !_rc_keep(r2, false) {
		return "compaction lost the synced file's content", crashed, reclaimed
	}
	if env_u64("SIM_RECLAIM_DUMP", 0) > 0 && k == 0 {
		fmt.eprintfln("peak %d logged %d compacted %d idle turns %d disk %d", peak, logged, reclaimed, turns, disk_bytes(&d))
	}
	return "", crashed, reclaimed
}

@(test)
pack_reclaim :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	msg, _, reclaimed := _rc_case(int(env_u64("SIM_RECLAIM_N", 40)), 0)
	testing.expectf(t, len(msg) == 0, "abandoned writers: %s", msg)
	testing.expectf(t, len(msg) > 0 || reclaimed > 0, "nothing was reclaimed, so the check proves nothing")
	if len(msg) > 0 {
		return
	}
	free_all(context.temp_allocator)
	points := 0
	for k in u64(1) ..< 4000 {
		m, crashed, _ := _rc_case(8, k)
		if len(m) > 0 {
			testing.expectf(t, false, "crash at disk op %d: %s", k, m)
			return
		}
		free_all(context.temp_allocator)
		if !crashed {
			break
		}
		points += 1
	}
	testing.expectf(t, points > 20, "only %d crash points were swept", points)
}

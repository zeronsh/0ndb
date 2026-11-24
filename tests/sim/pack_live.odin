package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
LV_PACK :: "/data/pack"

@(private = "file")
Lv_Rig :: struct {
	pk:  pack.Pack,
	job: bool,
}

@(private = "file")
_lv_open :: proc(d: ^Disk) -> (r: ^Lv_Rig, ok: bool) {
	r = new(Lv_Rig, runtime.heap_allocator())
	v := disk_vfs(d)
	if prim.mkdir_all(v, LV_PACK, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = 1 << 20
	opts.log_window = 1 << 20
	opts.mem_budget = 256 << 10
	opts.worker = pack.Worker_Hook{data = r, submit = proc(data: rawptr) {
		(^Lv_Rig)(data).job = true
	}}
	opts.wake = proc(data: rawptr) {}
	opts.wake_data = r
	return r, pack.open(&r.pk, v, LV_PACK, opts, runtime.heap_allocator()) == .None
}

@(private = "file")
_lv_round :: proc(r: ^Lv_Rig, n: int) -> bool {
	v := pack.vfs(&r.pk)
	pack.batch_begin(&r.pk)
	for i in 0 ..< 10 {
		pb: [64]u8
		fd, err := prim.open_file(v, fmt.bprintf(pb[:], "%s/s/f%d", LV_PACK, (n * 3 + i) % 16), {.Write, .Create, .Truncate}, 0o600)
		if err != .None {
			return false
		}
		b := make([]u8, 24 << 10, context.temp_allocator)
		for &x, k in b {
			x = u8(k * 7 + n * 31 + i)
		}
		werr := prim.write_at(v, fd, b, 0)
		prim.close_file(v, fd)
		if werr != .None {
			return false
		}
	}
	if pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r) != .None {
		return false
	}
	for _ in 0 ..< 1 + n % 5 {
		if r.job {
			r.job = false
			pack.worker_run(&r.pk)
		}
		if pack.poll(&r.pk) != .None {
			return false
		}
		if _, e := pack.step(&r.pk); e != .None {
			return false
		}
	}
	return true
}

@(private = "file")
_lv_wrong :: proc(p: ^pack.Pack) -> string {
	v := pack.vfs(p)
	live: i64
	for i in 0 ..< 16 {
		pb: [64]u8
		fd, err := prim.open_file(v, fmt.bprintf(pb[:], "%s/s/f%d", LV_PACK, i), {}, 0)
		if err != .None {
			continue
		}
		st, serr := prim.fstat(v, fd)
		prim.close_file(v, fd)
		if serr != .None {
			return "a file did not stat"
		}
		live += st.size
	}
	counted: i64
	for c in p.conts {
		counted += c.live
	}
	if counted != live {
		return fmt.tprintf("the containers count %d live bytes and the files hold %d", counted, live)
	}
	return ""
}

@(private = "file")
_lv_case :: proc(k: u64) -> (msg: string, crashed: bool) {
	d: Disk
	disk_init(&d, "live", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _lv_open(&d)
	defer free(r, runtime.heap_allocator())
	if !ok || prim.mkdir_all(pack.vfs(&r.pk), LV_PACK + "/s", 0o700) != .None || pack.sync(&r.pk) != .None {
		return "setup", false
	}
	d.crash_at = d.stats.ops + k
	for n in 0 ..< 24 {
		if !_lv_round(r, n) || d.dead {
			break
		}
	}
	pack.close(&r.pk)
	if d.dead {
		crashed = true
		rng: Rng
		rng_init(&rng, 1, k)
		disk_crash(&d, .Power, &rng)
	}
	d.crash_at = 0
	for n in 0 ..< 2 {
		r2, ok2 := _lv_open(&d)
		defer free(r2, runtime.heap_allocator())
		if !ok2 {
			return "the pack did not reopen", crashed
		}
		defer pack.close(&r2.pk)
		if m := _lv_wrong(&r2.pk); len(m) > 0 {
			return fmt.tprintf("open %d: %s", n, m), crashed
		}
		_, e := pack.step(&r2.pk)
		for r2.job && e == .None {
			r2.job = false
			pack.worker_run(&r2.pk)
			e = pack.poll(&r2.pk)
		}
		if e != .None {
			return "a job failed after reopening", crashed
		}
		if m := _lv_wrong(&r2.pk); len(m) > 0 {
			return fmt.tprintf("idle after open %d: %s", n, m), crashed
		}
	}
	return "", crashed
}

@(test)
pack_live :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	points := 0
	for k := u64(1); k < 4000; k += 5 {
		msg, crashed := _lv_case(k)
		if len(msg) > 0 {
			testing.expectf(t, false, "crash at disk op %d: %s", k, msg)
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

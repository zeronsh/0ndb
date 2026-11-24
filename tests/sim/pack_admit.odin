package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
AD_PACK :: "/data/pack"

@(private = "file")
AD_WINDOW :: 256 << 10

@(private = "file")
AD_FILE :: 64 << 10

@(private = "file")
AD_FILES :: 40

@(private = "file")
Ad_Rig :: struct {
	pk:  pack.Pack,
	job: bool,
}

@(private = "file")
_ad_open :: proc(d: ^Disk) -> (r: ^Ad_Rig, ok: bool) {
	r = new(Ad_Rig, runtime.heap_allocator())
	v := disk_vfs(d)
	if prim.mkdir_all(v, AD_PACK, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = 1 << 20
	opts.log_window = AD_WINDOW
	opts.mem_budget = 256 << 10
	opts.worker = pack.Worker_Hook{data = r, submit = proc(data: rawptr) {
		(^Ad_Rig)(data).job = true
	}}
	opts.wake = proc(data: rawptr) {}
	opts.wake_data = r
	return r, pack.open(&r.pk, v, AD_PACK, opts, runtime.heap_allocator()) == .None
}

@(private = "file")
_ad_turn :: proc(r: ^Ad_Rig) -> bool {
	for r.job {
		r.job = false
		pack.worker_run(&r.pk)
		if pack.poll(&r.pk) != .None {
			return false
		}
	}
	return true
}

@(private = "file")
_ad_chunk :: proc(tag: int, i: int) -> []u8 {
	b := make([]u8, AD_FILE, context.temp_allocator)
	for k in 0 ..< AD_FILE {
		b[k] = u8(k * 13 + tag * 7 + i * 31)
	}
	return b
}

@(private = "file")
_ad_tmp :: proc(buf: []u8, i: int) -> string {
	return fmt.bprintf(buf, "%s/s/t%d", AD_PACK, i)
}

@(private = "file")
_ad_rebuild :: proc(r: ^Ad_Rig, tag: int, peak: ^i64) -> (begun: bool, err: prim.Error) {
	v := pack.vfs(&r.pk)
	if prim.op_begin(v, AD_FILES * AD_FILE) != .None {
		return false, .Would_Block
	}
	begun = true
	defer prim.op_end(v)
	for i in 0 ..< AD_FILES {
		pb: [64]u8
		fd := prim.open_file(v, _ad_tmp(pb[:], i), {.Write, .Create, .Truncate}, 0o600) or_return
		werr := prim.write_at(v, fd, _ad_chunk(tag, i), 0)
		prim.close_file(v, fd)
		if werr != .None {
			return true, werr
		}
		peak^ = max(peak^, r.pk.log_since_ck + r.pk.buf_base + i64(len(r.pk.buf)) - r.pk.group_start)
		free_all(context.temp_allocator)
	}
	fd := prim.open_file(v, AD_PACK + "/s/mark.tmp", {.Write, .Create, .Truncate}, 0o600) or_return
	mb := [1]u8{u8(tag)}
	prim.write_at(v, fd, mb[:], 0) or_return
	prim.close_file(v, fd)
	prim.rename(v, AD_PACK + "/s/mark.tmp", AD_PACK + "/s/mark") or_return
	return true, .None
}

@(private = "file")
_ad_check :: proc(r: ^Ad_Rig) -> string {
	v := pack.vfs(&r.pk)
	fd, err := prim.open_file(v, AD_PACK + "/s/mark", {}, 0)
	if err != .None {
		return "the mark file is missing"
	}
	b: [1]u8
	prim.read_at(v, fd, b[:], 0)
	prim.close_file(v, fd)
	for i in 0 ..< AD_FILES {
		pb: [64]u8
		tf, terr := prim.open_file(v, _ad_tmp(pb[:], i), {}, 0)
		if terr != .None {
			return fmt.tprintf("file %d of the marked operation is missing", i)
		}
		got := make([]u8, AD_FILE, context.temp_allocator)
		n, rerr := prim.read_at(v, tf, got, 0)
		prim.close_file(v, tf)
		if rerr != .None || n != AD_FILE || string(got) != string(_ad_chunk(int(b[0]), i)) {
			return fmt.tprintf("file %d of the marked operation is not whole", i)
		}
	}
	return ""
}

@(private = "file")
_ad_case :: proc(k: u64) -> (msg: string, crashed: bool) {
	d: Disk
	disk_init(&d, "admit", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _ad_open(&d)
	defer free(r, runtime.heap_allocator())
	if !ok || prim.mkdir_all(pack.vfs(&r.pk), AD_PACK + "/s", 0o700) != .None || pack.sync(&r.pk) != .None {
		return "setup", false
	}
	peak: i64
	if k > 0 {
		d.crash_at = d.stats.ops + k
	}
	pack.batch_begin(&r.pk)
	begun, err := _ad_rebuild(r, 1, &peak)
	if k == 0 && (!begun || err != .None) {
		return fmt.tprintf("an admitted operation of %d bytes failed at %v", AD_FILES * AD_FILE, err), false
	}
	if k == 0 && peak > AD_WINDOW * 4 + 2 * AD_FILE {
		return fmt.tprintf("the log grew to %d bytes during an admitted operation; the bound is %d", peak, AD_WINDOW * 4 + 2 * AD_FILE), false
	}
	pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r)
	if k == 0 && !_ad_turn(r) {
		return "a job failed", false
	}
	if k == 0 {
		pack.batch_begin(&r.pk)
		pack.op_begin(&r.pk, 0)
		for i in 0 ..< 4 {
			pb: [64]u8
			fd, oerr := prim.open_file(pack.vfs(&r.pk), fmt.bprintf(pb[:], "%s/s/p%d", AD_PACK, i), {.Write, .Create}, 0o600)
			if oerr == .None {
				prim.write_at(pack.vfs(&r.pk), fd, _ad_chunk(9, i), 0)
				prim.close_file(pack.vfs(&r.pk), fd)
			}
		}
		pack.op_end(&r.pk)
		pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r)
		for i in 0 ..< 40 {
			pb: [64]u8
			fd, oerr := prim.open_file(pack.vfs(&r.pk), fmt.bprintf(pb[:], "%s/s/q%d", AD_PACK, i), {.Write, .Create}, 0o600)
			if oerr == .None {
				prim.write_at(pack.vfs(&r.pk), fd, _ad_chunk(5, i), 0)
				prim.close_file(pack.vfs(&r.pk), fd)
			}
			if !r.job {
				break
			}
		}
		if r.job && pack.op_begin(&r.pk, AD_WINDOW * 8) != .Would_Block {
			return "an operation that does not fit was admitted while a job was in flight", false
		}
		if r.job && pack.op_begin(&r.pk, 0) == .Would_Block && !pack.pressure(&r.pk) {
			return "a refused operation did not raise pressure", false
		}
		if !_ad_turn(r) {
			return "a job failed", false
		}
		if pack.op_begin(&r.pk, AD_WINDOW * 100) != .None {
			return "an operation larger than the budget was refused with nothing in flight", false
		}
		pack.op_end(&r.pk)
		pack.batch_begin(&r.pk)
		pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r)
		if !_ad_turn(r) {
			return "a job failed", false
		}
	}
	pack.close(&r.pk)
	if d.dead {
		crashed = true
		rng: Rng
		rng_init(&rng, 4, k)
		disk_crash(&d, .Power, &rng)
	}
	d.crash_at = 0
	r2, ok2 := _ad_open(&d)
	defer free(r2, runtime.heap_allocator())
	if !ok2 {
		return "the pack did not reopen", crashed
	}
	defer pack.close(&r2.pk)
	mf, merr := prim.open_file(pack.vfs(&r2.pk), AD_PACK + "/s/mark", {}, 0)
	if merr == .None {
		prim.close_file(pack.vfs(&r2.pk), mf)
		if m := _ad_check(r2); len(m) > 0 {
			return m, crashed
		}
	}
	return "", crashed
}

@(test)
pack_admit :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	msg, _ := _ad_case(0)
	testing.expectf(t, len(msg) == 0, "%s", msg)
	if len(msg) > 0 {
		return
	}
	free_all(context.temp_allocator)
	points := 0
	for k := u64(1); k < 4000; k += 2 {
		m, crashed := _ad_case(k)
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
	testing.expectf(t, points > 10, "only %d crash points were swept", points)
}

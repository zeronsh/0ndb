package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
AB_PACK :: "/data/pack"

@(private = "file")
AB_SLOTS :: 12 << 10

@(private = "file")
AB_INDEX :: AB_SLOTS * 16

@(private = "file")
AB_PUTS :: 43000

@(private = "file")
Ab_Rig :: struct {
	pk:  pack.Pack,
	job: bool,
}

@(private = "file")
_ab_open :: proc(d: ^Disk) -> (r: ^Ab_Rig, ok: bool) {
	r = new(Ab_Rig, runtime.heap_allocator())
	a := runtime.heap_allocator()
	v := disk_vfs(d)
	if prim.mkdir_all(v, AB_PACK, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = 4 << 20
	opts.log_window = 4 << 20
	opts.mem_budget = 256 << 10
	opts.worker = pack.Worker_Hook{data = r, submit = proc(data: rawptr) {
		(^Ab_Rig)(data).job = true
	}}
	opts.wake = proc(data: rawptr) {}
	opts.wake_data = r
	return r, pack.open(&r.pk, v, AB_PACK, opts, a) == .None
}

@(private = "file")
_ab_free :: proc(r: ^Ab_Rig) {
	free(r, runtime.heap_allocator())
}

@(private = "file")
_ab_attempt :: proc(r: ^Ab_Rig) -> (wrote: int, err: prim.Error) {
	v := pack.vfs(&r.pk)
	fd := prim.open_file(v, AB_PACK + "/s/idx.tmp", {.Write, .Create, .Truncate, .Group_Visible}, 0o600) or_return
	defer prim.close_file(v, fd)
	x := u32(1)
	slot: [16]u8
	zero := make([]u8, AB_INDEX, context.temp_allocator)
	prim.write_at(v, fd, zero, 0) or_return
	for i in 0 ..< AB_PUTS {
		x = x * 1664525 + 1013904223
		at := i64((x >> 8) % AB_SLOTS) * 16
		for k in 0 ..< 16 {
			slot[k] = u8(x >> u32(k & 7)) + u8(i)
		}
		prim.write_at(v, fd, slot[:], at) or_return
		wrote = i + 1
	}
	return wrote, .None
}

@(private = "file")
_ab_turn :: proc(r: ^Ab_Rig) -> bool {
	if r.job {
		r.job = false
		pack.worker_run(&r.pk)
	}
	if pack.poll(&r.pk) != .None {
		return false
	}
	_, e := pack.step(&r.pk)
	return e == .None
}

@(test)
pack_abandon :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	d: Disk
	disk_init(&d, "abandon", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _ab_open(&d)
	defer _ab_free(r)
	testing.expect(t, ok, "setup")
	v := pack.vfs(&r.pk)
	prim.mkdir_all(v, AB_PACK + "/s", 0o700)
	for n in 0 ..< int(env_u64("SIM_ABANDON_N", 24)) {
		before := pack.stats(&r.pk).log_bytes
		pack.batch_begin(&r.pk)
		wrote, err := _ab_attempt(r)
		pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r)
		turns := int(env_u64("SIM_ABANDON_TURNS", 1))
		for _ in 0 ..< turns {
			if !_ab_turn(r) {
				fmt.eprintln("turn failed")
			}
		}
		st := pack.stats(&r.pk)
		fmt.eprintfln("attempt %2d wrote %5d of %d puts err %v; log +%.1f MB total %.1f MB; containers %d disk %.1f MB flushes %d compacted %d pressure %v job %v", n, wrote, AB_PUTS, err, f64(st.log_bytes - before) / 1e6, f64(st.log_bytes) / 1e6, st.containers, f64(disk_bytes(&d)) / 1e6, st.flushes, st.compact_conts, pack.pressure(&r.pk), r.job)
		if err == .None {
			break
		}
		free_all(context.temp_allocator)
	}
}

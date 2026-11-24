package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
IF_PACK :: "/data/pack"

@(private = "file")
IF_FILES :: 4

@(private = "file")
IF_MAX :: 300 << 10

@(private = "file")
If_Rig :: struct {
	pk:  pack.Pack,
	job: bool,
}

@(private = "file")
_if_open :: proc(d: ^Disk) -> (r: ^If_Rig, ok: bool) {
	r = new(If_Rig, runtime.heap_allocator())
	v := disk_vfs(d)
	if prim.mkdir_all(v, IF_PACK, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = 512 << 10
	opts.log_window = 1 << 20
	opts.mem_budget = 512 << 10
	opts.worker = pack.Worker_Hook{data = r, submit = proc(data: rawptr) {
		(^If_Rig)(data).job = true
	}}
	opts.wake = proc(data: rawptr) {}
	opts.wake_data = r
	return r, pack.open(&r.pk, v, IF_PACK, opts, runtime.heap_allocator()) == .None
}

@(private = "file")
_if_turn :: proc(r: ^If_Rig) -> bool {
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
_if_case :: proc(seed: u64, ops: int) -> string {
	d: Disk
	disk_init(&d, "image-fuzz", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _if_open(&d)
	defer free(r, runtime.heap_allocator())
	if !ok || prim.mkdir_all(pack.vfs(&r.pk), IF_PACK + "/s", 0o700) != .None || pack.sync(&r.pk) != .None {
		return "setup"
	}
	v := pack.vfs(&r.pk)
	models: [IF_FILES][]u8
	sizes: [IF_FILES]int
	fds: [IF_FILES]prim.Fd
	for i in 0 ..< IF_FILES {
		models[i] = make([]u8, IF_MAX, runtime.heap_allocator())
		pb: [64]u8
		fd, err := prim.open_file(v, fmt.bprintf(pb[:], "%s/s/f%d", IF_PACK, i), {.Write, .Create}, 0o600)
		if err != .None {
			return "setup: open"
		}
		fds[i] = fd
	}
	defer for i in 0 ..< IF_FILES {
		delete(models[i], runtime.heap_allocator())
	}
	rng: Rng
	rng_init(&rng, u64(0x9e37), seed)
	pack.batch_begin(&r.pk)
	for op in 0 ..< ops {
		f := int(rng_u64(&rng) % u64(IF_FILES))
		k := rng_u64(&rng) % 100
		if k < 70 {
			n := int(rng_u64(&rng) % 64) + 1
			if rng_u64(&rng) % 20 == 0 {
				n = int(rng_u64(&rng) % 8192) + 1
			}
			at := int(rng_u64(&rng) % u64(256 << 10))
			if rng_u64(&rng) % 4 == 0 && sizes[f] > 0 {
				at = int(rng_u64(&rng) % u64(sizes[f]))
			}
			b: [8192]u8
			for i in 0 ..< n {
				b[i] = u8(rng_u64(&rng))
			}
			if prim.write_at(v, fds[f], b[:n], i64(at)) != .None {
				return fmt.tprintf("op %d: write failed", op)
			}
			copy(models[f][at:], b[:n])
			sizes[f] = max(sizes[f], at + n)
		} else if k < 85 {
			at := int(rng_u64(&rng) % u64(IF_MAX))
			n := int(rng_u64(&rng) % 2048) + 1
			got: [2048]u8
			rn, rerr := prim.read_at(v, fds[f], got[:n], i64(at))
			if rerr != .None {
				return fmt.tprintf("op %d: read failed %v", op, rerr)
			}
			want := clamp(sizes[f] - at, 0, n)
			if rn != want || string(got[:rn]) != string(models[f][at:][:rn]) {
				return fmt.tprintf("op %d: file %d at %d wanted %d bytes of the model, read %d and they differ", op, f, at, want, rn)
			}
		} else if k < 90 {
			size := int(rng_u64(&rng) % u64(IF_MAX))
			if prim.truncate(v, fds[f], i64(size)) != .None {
				return fmt.tprintf("op %d: truncate failed", op)
			}
			for i in size ..< sizes[f] {
				models[f][i] = 0
			}
			sizes[f] = size
		} else if k < 93 {
			at := int(rng_u64(&rng) % u64(IF_MAX))
			n := int(rng_u64(&rng) % 4096) + 1
			if at < sizes[f] {
				if prim.punch_hole(v, fds[f], i64(at), i64(n)) != .None {
					return fmt.tprintf("op %d: punch failed", op)
				}
				for i in at ..< min(at + n, sizes[f]) {
					models[f][i] = 0
				}
			}
		} else if k < 97 {
			if pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r) != .None || !_if_turn(r) {
				return fmt.tprintf("op %d: commit failed", op)
			}
			pack.batch_begin(&r.pk)
		} else {
			if _, e := pack.compact_all(&r.pk); e != .None {
				return fmt.tprintf("op %d: compact %v", op, e)
			}
		}
		for i in 0 ..< IF_FILES {
			st, serr := prim.fstat(v, fds[i])
			if serr != .None || int(st.size) != sizes[i] {
				return fmt.tprintf("op %d: file %d size %d, the model has %d", op, i, int(st.size), sizes[i])
			}
		}
		free_all(context.temp_allocator)
	}
	for i in 0 ..< IF_FILES {
		prim.close_file(v, fds[i])
	}
	if pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r) != .None || !_if_turn(r) {
		return "final commit failed"
	}
	pack.close(&r.pk)
	r2, ok2 := _if_open(&d)
	defer free(r2, runtime.heap_allocator())
	if !ok2 {
		return "reopen failed"
	}
	defer pack.close(&r2.pk)
	for i in 0 ..< IF_FILES {
		pb: [64]u8
		fd, err := prim.open_file(pack.vfs(&r2.pk), fmt.bprintf(pb[:], "%s/s/f%d", IF_PACK, i), {}, 0)
		if err != .None {
			return fmt.tprintf("reopen: file %d %v", i, err)
		}
		got := make([]u8, sizes[i], context.temp_allocator)
		n, rerr := prim.read_at(pack.vfs(&r2.pk), fd, got, 0)
		prim.close_file(pack.vfs(&r2.pk), fd)
		if rerr != .None || n != sizes[i] {
			return fmt.tprintf("reopen: file %d has %d bytes of %d (%v)", i, n, sizes[i], rerr)
		}
		for x in 0 ..< n {
			if got[x] != models[i][x] {
				return fmt.tprintf("reopen: file %d differs at %d", i, x)
			}
		}
	}
	return ""
}

@(test)
pack_image_fuzz :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 20 {
		msg := _if_case(seed, 400)
		testing.expectf(t, len(msg) == 0, "seed %d: %s", seed, msg)
		if len(msg) > 0 {
			return
		}
		free_all(context.temp_allocator)
	}
}

package sim

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
DF_PACK :: "/data/pack"

@(private = "file")
DF_FILE :: DF_PACK + "/s/idx"

@(private = "file")
DF_SIZE :: 192 << 10

@(private = "file")
DF_WRITE :: 16

@(private = "file")
DF_WRITES :: 2511

@(private = "file")
DF_GROUPS :: 12

@(private = "file")
DF_PER_GROUP :: 60

@(private = "file")
Df_Rig :: struct {
	pk:  pack.Pack,
	job: bool,
}

@(private = "file")
_df_open :: proc(d: ^Disk, compact: bool) -> (r: ^Df_Rig, ok: bool) {
	r = new(Df_Rig, runtime.heap_allocator())
	v := disk_vfs(d)
	if prim.mkdir_all(v, DF_PACK, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.container_size = 4 << 20
	opts.log_window = 4 << 20
	opts.mem_budget = 512 << 10
	if !compact {
		opts.compact_ratio = 0
		opts.container_size = 64 << 20
		opts.log_window = 64 << 20
		opts.mem_budget = 32 << 20
	}
	opts.worker = pack.Worker_Hook{data = r, submit = proc(data: rawptr) {
		(^Df_Rig)(data).job = true
	}}
	opts.wake = proc(data: rawptr) {}
	opts.wake_data = r
	return r, pack.open(&r.pk, v, DF_PACK, opts, runtime.heap_allocator()) == .None
}

@(private = "file")
_df_turn :: proc(r: ^Df_Rig) -> bool {
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
_df_put :: proc(r: ^Df_Rig, fd: prim.Fd, model: []u8, x: ^u32, tag: int) -> bool {
	x^ = x^ * 1664525 + 1013904223
	at := i64((x^ >> 8) % (DF_SIZE / DF_WRITE)) * DF_WRITE
	b: [DF_WRITE]u8
	for i in 0 ..< DF_WRITE {
		b[i] = u8(x^ >> u32(i & 15)) + u8(tag)
	}
	if prim.write_at(pack.vfs(&r.pk), fd, b[:], at) != .None {
		return false
	}
	copy(model[at:], b[:])
	return true
}

@(private = "file")
_df_commit :: proc(r: ^Df_Rig) -> bool {
	if pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {}, r) != .None {
		return false
	}
	if !_df_turn(r) {
		return false
	}
	pack.batch_begin(&r.pk)
	return true
}

@(private = "file")
_df_read :: proc(r: ^Df_Rig) -> (u64, bool) {
	v := pack.vfs(&r.pk)
	fd, err := prim.open_file(v, DF_FILE, {}, 0)
	if err != .None {
		return 0, false
	}
	defer prim.close_file(v, fd)
	buf := make([]u8, DF_SIZE, context.temp_allocator)
	n, rerr := prim.read_at(v, fd, buf, 0)
	if rerr != .None || n != DF_SIZE {
		return 0, false
	}
	return xxhash.XXH3_64_default(buf), true
}

@(private = "file")
_df_case :: proc(k: u64, bound_only: bool) -> (msg: string, crashed: bool) {
	d: Disk
	disk_init(&d, "defrag", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _df_open(&d, !bound_only)
	defer free(r, runtime.heap_allocator())
	if !ok || prim.mkdir_all(pack.vfs(&r.pk), DF_PACK + "/s", 0o700) != .None || pack.sync(&r.pk) != .None {
		return "setup", false
	}
	v := pack.vfs(&r.pk)
	model := make([]u8, DF_SIZE, context.temp_allocator)
	hashes := make([dynamic]u64, context.temp_allocator)
	append(&hashes, xxhash.XXH3_64_default(model))
	x := u32(7)
	if bound_only {
		fd, oerr := prim.open_file(v, DF_FILE, {.Write, .Create, .Truncate}, 0o600)
		if oerr != .None {
			return "setup: open", false
		}
		pack.batch_begin(&r.pk)
		before := pack.stats(&r.pk).log_bytes
		if prim.write_at(v, fd, model, 0) != .None {
			return "setup: zeros", false
		}
		for i in 0 ..< DF_WRITES {
			if !_df_put(r, fd, model, &x, i) {
				return "a write failed", false
			}
		}
		if !_df_commit(r) {
			return "the commit failed", false
		}
		prim.close_file(v, fd)
		logged := pack.stats(&r.pk).log_bytes - before
		limit := u64(DF_SIZE * 2 + DF_WRITES * DF_WRITE + (64 << 10))
		if logged > limit {
			return fmt.tprintf("%d small writes logged %d bytes; the bound is %d (the file twice plus what was written)", DF_WRITES, logged, limit), false
		}
		return "", false
	}
	d.crash_at = d.stats.ops + k
	fd, oerr := prim.open_file(v, DF_FILE, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return "setup: open", false
	}
	if prim.write_at(v, fd, model, 0) != .None {
		if d.dead {
			crashed = true
		} else {
			return "setup: zeros", false
		}
	}
	ok2 := true
	pack.batch_begin(&r.pk)
	if !d.dead {
		ok2 = _df_commit(r)
		append(&hashes, xxhash.XXH3_64_default(model))
	}
	for g := 0; ok2 && !d.dead && g < DF_GROUPS; g += 1 {
		for i in 0 ..< DF_PER_GROUP {
			if !_df_put(r, fd, model, &x, g * 1000 + i) {
				break
			}
			if d.dead {
				break
			}
		}
		append(&hashes, xxhash.XXH3_64_default(model))
		if d.dead || !_df_commit(r) {
			break
		}
	}
	prim.close_file(v, fd)
	pack.close(&r.pk)
	if d.dead {
		crashed = true
		rng: Rng
		rng_init(&rng, 3, k)
		disk_crash(&d, .Power, &rng)
	}
	d.crash_at = 0
	r2, ok3 := _df_open(&d, true)
	defer free(r2, runtime.heap_allocator())
	if !ok3 {
		return "the pack did not reopen", crashed
	}
	defer pack.close(&r2.pk)
	h, rok := _df_read(r2)
	if !rok {
		return "", crashed
	}
	for x in hashes {
		if x == h {
			return "", crashed
		}
	}
	return "the reopened file is not the content after any committed group", crashed
}

@(test)
pack_defrag :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	msg, _ := _df_case(0, true)
	testing.expectf(t, len(msg) == 0, "%s", msg)
	free_all(context.temp_allocator)
	points := 0
	for k in u64(1) ..< 4000 {
		m, crashed := _df_case(k, false)
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

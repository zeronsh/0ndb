package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
TI_ROOT :: "/relay"

@(private = "file")
TI_PACK :: "/relay/spaces"

@(private = "file")
TI_OBJECTS :: "/relay/objects"

@(private = "file")
TI_CHUNK :: 1024

@(private = "file")
TI_BOUND :: u64(4096)

@(private = "file")
Ti_Rig :: struct {
	arena: virtual.Arena,
	loop:  prim.Loop,
	pk:    pack.Pack,
	fs:    osync.File_Store,
	objs:  osync.Dir_Object_Store,
	ts:    osync.Tier_Store,
	store: osync.Relay_Storage,
	on:    bool,
}

@(private = "file")
Ti_Done :: struct {
	fired:  bool,
	result: osync.Error,
}

@(private = "file")
_ti_space :: proc() -> (id: osync.Space_Id) {
	for i in 0 ..< len(id) {
		id[i] = u8(0x40 + i)
	}
	return
}

@(private = "file")
_ti_stream :: proc(i: int) -> (id: osync.Stream_Id) {
	x := u64(i / 2) * 0x9E3779B97F4A7C15 + 0x1234
	for k in 0 ..< 16 {
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		id[k] = u8(x)
	}
	id[0] = u8(i / 2)
	y := u64(i % 2) * 0xBF58476D1CE4E5B9 + 0x5678
	for k in 16 ..< 32 {
		y ~= y << 13
		y ~= y >> 7
		y ~= y << 17
		id[k] = u8(y)
	}
	return
}

@(private = "file")
_ti_open :: proc(d: ^Disk) -> (r: ^Ti_Rig, ok: bool) {
	r = new(Ti_Rig, runtime.heap_allocator())
	if virtual.arena_init_growing(&r.arena) != nil {
		return r, false
	}
	a := virtual.arena_allocator(&r.arena)
	vfs := disk_vfs(d)
	if prim.mkdir_all(vfs, TI_PACK, 0o700) != .None || prim.mkdir_all(vfs, TI_OBJECTS, 0o700) != .None {
		return r, false
	}
	if prim.loop_init(&r.loop, a) != .None {
		return r, false
	}
	if pack.open(&r.pk, vfs, TI_PACK, pack.DEFAULT_OPTIONS, a) != .None {
		return r, false
	}
	lay := osync.LAYOUT_COMPACT
	lay.exact = true
	group := osync.Group_Commit {
		data = &r.pk,
		begin = proc(data: rawptr) {
			pack.batch_begin((^pack.Pack)(data))
		},
		end = proc(data: rawptr) -> osync.Error {
			return .None if pack.batch_end((^pack.Pack)(data)) == .None else .Io
		},
	}
	if osync.file_store_init(&r.fs, &r.loop, pack.vfs(&r.pk), TI_ROOT, 0, lay, group, {}, {}, a) != .None {
		return r, false
	}
	r.fs.pack = &r.pk
	r.on = true
	r.objs = osync.Dir_Object_Store{vfs = vfs, root = TI_OBJECTS}
	tc := osync.Tier_Config{objects = osync.dir_object_store(&r.objs), window_ms = 1000, max_ms = 5000, hot = 256}
	if osync.tier_store_init(&r.ts, &r.loop, osync.file_store(&r.fs), tc, {}, a) != .None {
		return r, false
	}
	r.store = osync.tier_store(&r.ts)
	return r, true
}

@(private = "file")
_ti_close :: proc(r: ^Ti_Rig, clean: bool) {
	if r.on {
		if clean {
			for _ in 0 ..< 4000 {
				prim.loop_step(&r.loop, false)
			}
			osync.file_store_destroy(&r.fs)
			pack.close(&r.pk)
		} else {
			osync.worker_destroy(&r.fs.worker)
		}
		osync.tier_store_destroy(&r.ts)
		prim.loop_destroy(&r.loop)
	}
	virtual.arena_destroy(&r.arena)
	free(r, runtime.heap_allocator())
}

@(private = "file")
_ti_on_done :: proc(ctx: rawptr, result: osync.Error, value: i64) {
	x := (^Ti_Done)(ctx)
	x.fired = true
	x.result = result
}

@(private = "file")
_ti_steps :: proc(r: ^Ti_Rig, d: ^Disk, n: int) {
	for _ in 0 ..< n {
		if d.dead {
			return
		}
		prim.loop_step(&r.loop, false)
	}
}

@(private = "file")
_ti_append :: proc(r: ^Ti_Rig, d: ^Disk, ns: rawptr, id: osync.Stream_Id, seed: u8) -> bool {
	s, length, err := r.store.stream_open(r.store.data, ns, id, true)
	if err != .None {
		return false
	}
	defer r.store.stream_close(r.store.data, s)
	body := make([]u8, TI_CHUNK, context.temp_allocator)
	for i in 0 ..< TI_CHUNK {
		body[i] = u8((i64(i) + length) * 7 + i64(seed))
	}
	w, berr := r.store.append_begin(r.store.data, s, length, TI_CHUNK)
	if berr != .None {
		return false
	}
	if r.store.append_write(r.store.data, w, body) != .None {
		r.store.append_abort(r.store.data, w)
		return false
	}
	done: Ti_Done
	r.store.append_commit(r.store.data, w, _ti_on_done, &done)
	for k := 0; k < 10_000 && !done.fired && !d.dead; k += 1 {
		prim.loop_step(&r.loop, false)
	}
	return done.fired && done.result == .None
}

@(private = "file")
_ti_round :: proc(r: ^Ti_Rig, d: ^Disk, streams: int, seed: u8) -> bool {
	ns, _, err := r.store.namespace_open(r.store.data, _ti_space())
	if err != .None {
		return false
	}
	defer r.store.namespace_close(r.store.data, ns)
	for i in 0 ..< streams {
		if !_ti_append(r, d, ns, _ti_stream(i), seed) {
			return false
		}
	}
	osync.tier_store_flush_all(&r.ts)
	_ti_steps(r, d, 4000)
	return !d.dead
}

@(private = "file")
_ti_open_cost :: proc(r: ^Ti_Rig, d: ^Disk, id: osync.Stream_Id) -> (cost: u64, ok: bool) {
	before := r.ts.man_read_bytes + r.ts.index_read_bytes
	ns, _, err := r.store.namespace_open(r.store.data, _ti_space())
	if err != .None {
		return 0, false
	}
	s, _, serr := r.store.stream_open(r.store.data, ns, id, false)
	if serr != .None {
		r.store.namespace_close(r.store.data, ns)
		return 0, false
	}
	buf: [64]u8
	r.store.stream_read(r.store.data, s, 0, buf[:])
	r.store.stream_close(r.store.data, s)
	r.store.namespace_close(r.store.data, ns)
	_ti_steps(r, d, 2000)
	return r.ts.man_read_bytes + r.ts.index_read_bytes - before, true
}

@(private = "file")
_ti_bound_case :: proc() -> string {
	d: Disk
	disk_init(&d, "tierindex", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _ti_open(&d)
	defer _ti_close(r, true)
	if !ok {
		return "setup: the tier store did not open"
	}
	STREAMS :: 96
	for round in 0 ..< 3 {
		if !_ti_round(r, &d, STREAMS, u8(round)) {
			return fmt.aprintf("setup: round %d did not complete", round)
		}
	}
	if r.ts.evictions == 0 {
		return "no segment was evicted, so the check proves nothing"
	}
	if m := osync.tier_index_verify(&r.ts, _ti_space()); len(m) > 0 {
		return fmt.aprintf("after the rounds: %s", m)
	}
	worst := u64(0)
	for i in 0 ..< 8 {
		c, cok := _ti_open_cost(r, &d, _ti_stream(i * 11))
		if !cok {
			return fmt.aprintf("stream %d did not open", i * 11)
		}
		worst = max(worst, c)
	}
	if worst > TI_BOUND {
		return fmt.aprintf("opening one stream of %d read %d bytes of the cold manifest and index (bound %d)", STREAMS, worst, TI_BOUND)
	}
	return ""
}

@(private = "file")
_ti_crash_case :: proc(k: u64) -> (msg: string, crashed: bool) {
	d: Disk
	disk_init(&d, "tiercrash", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _ti_open(&d)
	if !ok {
		_ti_close(r, true)
		return "setup: the tier store did not open", false
	}
	STREAMS :: 6
	for round in 0 ..< 2 {
		if !_ti_round(r, &d, STREAMS, u8(round)) {
			_ti_close(r, true)
			return fmt.aprintf("setup: round %d did not complete", round), false
		}
	}
	d.crash_at = d.stats.ops + k
	_ti_round(r, &d, STREAMS, 7)
	if !d.dead {
		d.crash_at = 0
		_ti_close(r, true)
	} else {
		crashed = true
		_ti_close(r, false)
		rng: Rng
		rng_init(&rng, 3, k)
		disk_crash(&d, .Power, &rng)
	}
	r2, ok2 := _ti_open(&d)
	defer _ti_close(r2, true)
	if !ok2 {
		return "recovery: the tier store did not reopen", crashed
	}
	if m := osync.tier_index_verify(&r2.ts, _ti_space()); len(m) > 0 {
		return fmt.aprintf("on reopen: %s", m), crashed
	}
	ns, _, nerr := r2.store.namespace_open(r2.store.data, _ti_space())
	if nerr != .None {
		return "recovery: the space did not open", crashed
	}
	_ti_steps(r2, &d, 4000)
	m := osync.tier_index_verify(&r2.ts, _ti_space(), true)
	r2.store.namespace_close(r2.store.data, ns)
	if len(m) > 0 {
		return fmt.aprintf("after catch-up: %s", m), crashed
	}
	if !_ti_round(r2, &d, STREAMS, 9) {
		return "recovery: a round after the crash did not complete", crashed
	}
	if m2 := osync.tier_index_verify(&r2.ts, _ti_space()); len(m2) > 0 {
		return fmt.aprintf("after a later round: %s", m2), crashed
	}
	return "", crashed
}

@(test)
tier_index :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	if m := _ti_bound_case(); len(m) > 0 {
		testing.expectf(t, false, "tier index: %s", m)
		return
	}
	free_all(context.temp_allocator)
	points := 0
	for k in u64(1) ..< 20_000 {
		msg, crashed := _ti_crash_case(k)
		free_all(context.temp_allocator)
		if len(msg) > 0 {
			testing.expectf(t, false, "tier index: crash at disk op %d of a flush and its indexing: %s", k, msg)
			return
		}
		if !crashed {
			break
		}
		points += 1
	}
	testing.expectf(t, points > 0, "tier index: no crash point was swept, so the check proves nothing")
}

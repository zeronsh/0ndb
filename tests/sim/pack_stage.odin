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
STAGE_ROOT :: "/relay"
@(private = "file")
STAGE_PACK :: "/relay/spaces"
@(private = "file")
STAGE_REC :: 1600

@(private = "file")
Stage_Rig :: struct {
	arena: virtual.Arena,
	loop:  prim.Loop,
	pk:    pack.Pack,
	fs:    osync.File_Store,
	store: osync.Relay_Storage,
	on:    bool,
}

@(private = "file")
Stage_Done :: struct {
	fired:  bool,
	result: osync.Error,
	value:  i64,
}

@(private = "file")
Stage_Stream :: struct {
	space: osync.Space_Id,
	id:    osync.Stream_Id,
	seed:  u8,
	ns:    rawptr,
	s:     rawptr,
}

@(private = "file")
_stage_byte :: #force_inline proc "contextless" (seed: u8, off: i64) -> u8 {
	return u8((off * 7 + i64(seed) * 31 + off / 251) & 0xff)
}

@(private = "file")
_stage_fill :: proc(seed: u8, at: i64, n: int) -> []u8 {
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n {
		b[i] = _stage_byte(seed, at + i64(i))
	}
	return b
}

@(private = "file")
_rig_open :: proc(d: ^Disk) -> (r: ^Stage_Rig, ok: bool) {
	r = new(Stage_Rig, runtime.heap_allocator())
	if virtual.arena_init_growing(&r.arena) != nil {
		return r, false
	}
	a := virtual.arena_allocator(&r.arena)
	vfs := disk_vfs(d)
	if prim.mkdir_all(vfs, STAGE_PACK, 0o700) != .None {
		return r, false
	}
	if prim.loop_init(&r.loop, a) != .None {
		return r, false
	}
	if pack.open(&r.pk, vfs, STAGE_PACK, pack.DEFAULT_OPTIONS, a) != .None {
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
	if osync.file_store_init(&r.fs, &r.loop, pack.vfs(&r.pk), STAGE_ROOT, 0, lay, group, {}, {}, a) != .None {
		return r, false
	}
	r.fs.pack = &r.pk
	r.store = osync.file_store(&r.fs)
	r.on = true
	return r, true
}

@(private = "file")
_rig_kill :: proc(r: ^Stage_Rig) {
	if r.on {
		osync.worker_destroy(&r.fs.worker)
		prim.loop_destroy(&r.loop)
	}
	virtual.arena_destroy(&r.arena)
	free(r, runtime.heap_allocator())
}

@(private = "file")
_rig_close :: proc(r: ^Stage_Rig, streams: []^Stage_Stream) {
	for x in streams {
		if x.s != nil {
			r.store.stream_close(r.store.data, x.s)
			x.s = nil
		}
		if x.ns != nil {
			r.store.namespace_close(r.store.data, x.ns)
			x.ns = nil
		}
	}
	osync.file_store_destroy(&r.fs)
	pack.close(&r.pk)
	prim.loop_destroy(&r.loop)
	r.on = false
	_rig_kill(r)
}

@(private = "file")
_stage_on_done :: proc(ctx: rawptr, result: osync.Error, value: i64) {
	sd := (^Stage_Done)(ctx)
	sd.fired = true
	sd.result = result
	sd.value = value
}

@(private = "file")
_stage_drive :: proc(r: ^Stage_Rig, d: ^Disk, sd: ^Stage_Done) -> bool {
	for _ in 0 ..< 10_000 {
		if d.dead {
			return false
		}
		if sd.fired {
			return sd.result == .None
		}
		prim.loop_step(&r.loop, false)
	}
	return false
}

@(private = "file")
_stage_open :: proc(r: ^Stage_Rig, x: ^Stage_Stream, create: bool) -> (length: i64, ok: bool) {
	ns, _, nerr := r.store.namespace_open(r.store.data, x.space)
	if nerr != .None {
		return 0, false
	}
	x.ns = ns
	s, n, serr := r.store.stream_open(r.store.data, ns, x.id, create)
	if serr != .None {
		return 0, false
	}
	x.s = s
	return n, true
}

@(private = "file")
_stage_append :: proc(r: ^Stage_Rig, d: ^Disk, x: ^Stage_Stream, at: i64, n: int, sd: ^Stage_Done) -> bool {
	w, err := r.store.append_begin(r.store.data, x.s, at, i64(n))
	if err != .None || d.dead {
		return false
	}
	if r.store.append_write(r.store.data, w, _stage_fill(x.seed, at, n)) != .None {
		r.store.append_abort(r.store.data, w)
		return false
	}
	r.store.append_commit(r.store.data, w, _stage_on_done, sd)
	return _stage_drive(r, d, sd)
}

@(private = "file")
_stage_verify :: proc(r: ^Stage_Rig, x: ^Stage_Stream, allowed: []i64) -> (msg: string) {
	n, ok := _stage_open(r, x, false)
	if !ok {
		return fmt.tprintf("stream %x cannot be opened after the crash", x.id[0])
	}
	hit := false
	for a in allowed {
		hit ||= a == n
	}
	if !hit {
		return fmt.tprintf("stream %x has length %d after the crash, allowed %v", x.id[0], n, allowed)
	}
	buf := make([]u8, int(n), context.temp_allocator)
	got, rerr := r.store.stream_read(r.store.data, x.s, 0, buf)
	if rerr != .None || i64(got) != n {
		return fmt.tprintf("stream %x reads %d of %d bytes (%v)", x.id[0], got, n, rerr)
	}
	for i in 0 ..< int(n) {
		if buf[i] != _stage_byte(x.seed, i64(i)) {
			return fmt.tprintf("stream %x differs at byte %d of %d", x.id[0], i, n)
		}
	}
	return ""
}

@(private = "file")
Stage_Case :: struct {
	base_a: int,
	crash:  u64,
	mode:   Crash_Mode,
	seed:   u64,
}

@(private = "file")
_stage_case :: proc(c: Stage_Case) -> (crashed: bool, msg: string) {
	d: Disk
	disk_init(&d, "stage", runtime.heap_allocator())
	defer disk_destroy(&d)
	sa := Stage_Stream{space = osync.Space_Id{0 = 1}, id = osync.Stream_Id{0 = 0xa1}, seed = 3}
	sb := Stage_Stream{space = osync.Space_Id{0 = 2}, id = osync.Stream_Id{0 = 0xb2}, seed = 9}
	all := []^Stage_Stream{&sa, &sb}
	r, ok := _rig_open(&d)
	if !ok {
		_rig_kill(r)
		return false, "setup: the pack and store did not open"
	}
	_stage_open(r, &sa, true)
	_stage_open(r, &sb, true)
	setup: Stage_Done
	if !_stage_append(r, &d, &sa, 0, c.base_a, &setup) {
		_rig_kill(r)
		return false, "setup: the base append of space A failed"
	}
	setup = {}
	if !_stage_append(r, &d, &sb, 0, STAGE_REC, &setup) {
		_rig_kill(r)
		return false, "setup: the base append of space B failed"
	}
	a0 := i64(c.base_a)
	b0 := i64(STAGE_REC)
	a_issued, b_acked, b_issued := false, b0, b0
	a_acked := a0
	d.crash_at = d.stats.ops + c.crash
	run: {
		wa, aerr := r.store.append_begin(r.store.data, sa.s, a0, STAGE_REC)
		if aerr != .None || d.dead {
			break run
		}
		half := STAGE_REC / 2
		if r.store.append_write(r.store.data, wa, _stage_fill(sa.seed, a0, half)) != .None || d.dead {
			r.store.append_abort(r.store.data, wa)
			break run
		}
		for k in 0 ..< 2 {
			at := b0 + i64(k * STAGE_REC)
			b_issued = at + STAGE_REC
			sd: Stage_Done
			if !_stage_append(r, &d, &sb, at, STAGE_REC, &sd) {
				r.store.append_abort(r.store.data, wa)
				break run
			}
			b_acked = b_issued
		}
		if r.store.append_write(r.store.data, wa, _stage_fill(sa.seed, a0 + i64(half), STAGE_REC - half)) != .None || d.dead {
			r.store.append_abort(r.store.data, wa)
			break run
		}
		a_issued = true
		sd: Stage_Done
		r.store.append_commit(r.store.data, wa, _stage_on_done, &sd)
		if _stage_drive(r, &d, &sd) {
			a_acked = a0 + STAGE_REC
		}
	}
	crashed = d.dead
	d.crash_at = 0
	if !crashed {
		_rig_close(r, all)
		return false, ""
	}
	_rig_kill(r)
	rng: Rng
	rng_init(&rng, c.seed, c.crash)
	disk_crash(&d, c.mode, &rng)
	sa.ns, sa.s, sb.ns, sb.s = nil, nil, nil, nil
	r2, ok2 := _rig_open(&d)
	if !ok2 {
		_rig_kill(r2)
		return true, "recovery: the pack and store did not reopen"
	}
	defer _rig_close(r2, all)
	allowed_a := make([dynamic]i64, context.temp_allocator)
	append(&allowed_a, a_acked)
	if a_issued && a_acked == a0 {
		append(&allowed_a, a0 + STAGE_REC)
	}
	allowed_b := make([dynamic]i64, context.temp_allocator)
	for v := b_acked; v <= b_issued; v += STAGE_REC {
		append(&allowed_b, v)
	}
	if m := _stage_verify(r2, &sa, allowed_a[:]); len(m) > 0 {
		return true, m
	}
	if m := _stage_verify(r2, &sb, allowed_b[:]); len(m) > 0 {
		return true, m
	}
	return true, ""
}

@(test)
staged_append_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	cases, crashes := 0, 0
	for base in ([]int{STAGE_REC, 300 * 1024}) {
		for mode in Crash_Mode {
			for seed in u64(1) ..= (u64(1) if mode == .Process else 3) {
				for k := u64(1); ; k += 1 {
					crashed, msg := _stage_case(Stage_Case{base_a = base, crash = k, mode = mode, seed = seed})
					cases += 1
					if len(msg) > 0 {
						testing.expectf(t, false, "staged append, A base %d, %v crash at op %d (seed %d): %s", base, mode, k, seed, msg)
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
	}
	fmt.eprintfln("staged_append_crash: %d runs, %d crash points, all recovered", cases, crashes)
}

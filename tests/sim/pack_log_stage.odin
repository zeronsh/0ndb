package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:testing"
import "../../src/pack"
import "../../src/prim"

@(private = "file")
LS_ROOT :: "/ls"
@(private = "file")
LS_FILE :: "/ls/f"
@(private = "file")
LS_BATCHES :: 4

@(private = "file")
Ls_Rig :: struct {
	arena:   virtual.Arena,
	pk:      pack.Pack,
	fd:      prim.Fd,
	pending: bool,
	open:    bool,
}

@(private = "file")
Ls_Ack :: struct {
	fired: bool,
	err:   pack.Error,
}

@(private = "file")
_ls_byte :: #force_inline proc "contextless" (seed: u64, off: int) -> u8 {
	return u8((u64(off) * 13 + seed * 101 + u64(off) / 97) & 0xff)
}

@(private = "file")
_ls_open :: proc(d: ^Disk, create: bool) -> (r: ^Ls_Rig, ok: bool) {
	r = new(Ls_Rig, runtime.heap_allocator())
	r.fd = prim.INVALID_FD
	if virtual.arena_init_growing(&r.arena) != nil {
		return r, false
	}
	a := virtual.arena_allocator(&r.arena)
	vfs := disk_vfs(d)
	if prim.mkdir_all(vfs, LS_ROOT, 0o700) != .None {
		return r, false
	}
	opts := pack.DEFAULT_OPTIONS
	opts.spill = 512
	opts.wake = proc(data: rawptr) {}
	opts.worker = pack.Worker_Hook {
		data = r,
		submit = proc(data: rawptr) {
			(^Ls_Rig)(data).pending = true
		},
	}
	if pack.open(&r.pk, vfs, LS_ROOT, opts, a) != .None {
		return r, false
	}
	r.open = true
	flags := prim.Open_Flags{.Write, .Create} if create else prim.Open_Flags{.Write}
	fd, err := prim.open_file(pack.vfs(&r.pk), LS_FILE, flags, 0o600)
	if err != .None {
		return r, false
	}
	r.fd = fd
	return r, true
}

@(private = "file")
_ls_close :: proc(r: ^Ls_Rig) {
	if r.open {
		if r.fd >= 0 {
			prim.close_file(pack.vfs(&r.pk), r.fd)
		}
		pack.close(&r.pk)
	}
	virtual.arena_destroy(&r.arena)
	free(r, runtime.heap_allocator())
}

@(private = "file")
_ls_read_all :: proc(r: ^Ls_Rig) -> (data: []u8, ok: bool) {
	fv := pack.vfs(&r.pk)
	size, serr := prim.file_size(fv, r.fd)
	if serr != .None {
		return nil, false
	}
	buf := make([]u8, int(size), context.temp_allocator)
	got := 0
	for got < len(buf) {
		n, err := prim.read_at(fv, r.fd, buf[got:], i64(got))
		if err != .None || n <= 0 {
			return nil, false
		}
		got += n
	}
	return buf, true
}

@(private = "file")
_ls_check :: proc(r: ^Ls_Rig, want: []u8, d: ^Disk, at: string) -> string {
	if d.dead {
		return ""
	}
	got, ok := _ls_read_all(r)
	if !ok {
		return "" if d.dead else fmt.tprintf("%s: reading the file failed", at)
	}
	if string(got) != string(want) {
		return fmt.tprintf("%s: read %d bytes but %d were written (first difference at %d)", at, len(got), len(want), _ls_diff(got, want))
	}
	return ""
}

@(private = "file")
_ls_diff :: proc(a, b: []u8) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if a[i] != b[i] {
			return i
		}
	}
	return min(len(a), len(b))
}

@(private = "file")
_ls_run_job :: proc(r: ^Ls_Rig) {
	if r.pending {
		r.pending = false
		pack.worker_run(&r.pk)
	}
	pack.poll(&r.pk)
}

@(private = "file")
_ls_case :: proc(mode: Crash_Mode, crash: u64, seed: u64) -> (crashed: bool, msg: string) {
	d: Disk
	disk_init(&d, "logstage", runtime.heap_allocator())
	defer disk_destroy(&d)
	r, ok := _ls_open(&d, true)
	if !ok {
		_ls_close(r)
		return false, "setup: the pack did not open"
	}
	if pack.sync(&r.pk) != .None {
		_ls_close(r)
		return false, "setup: the first sync failed"
	}
	want := make([dynamic]u8, context.temp_allocator)
	bounds := make([dynamic]int, context.temp_allocator)
	append(&bounds, 0)
	acks: [LS_BATCHES]Ls_Ack
	sizes := [3]int{700, 333, 1300}
	d.crash_at = d.stats.ops + crash
	fv := pack.vfs(&r.pk)
	run: for i in 0 ..< LS_BATCHES {
		pack.batch_begin(&r.pk)
		for k in 0 ..< len(sizes) {
			n := sizes[(k + i + int(seed)) % len(sizes)]
			chunk := make([]u8, n, context.temp_allocator)
			for j in 0 ..< n {
				chunk[j] = _ls_byte(seed, len(want) + j)
			}
			if prim.write_at(fv, r.fd, chunk, i64(len(want))) != .None {
				break run
			}
			append(&want, ..chunk)
			if m := _ls_check(r, want[:], &d, fmt.tprintf("batch %d chunk %d", i, k)); len(m) > 0 {
				_ls_close(r)
				return d.dead, m
			}
		}
		append(&bounds, len(want))
		ack := &acks[i]
		if pack.batch_end_async(&r.pk, proc(data: rawptr, err: pack.Error) {
			x := (^Ls_Ack)(data)
			x.fired = true
			x.err = err
		}, ack) != .None {
			break run
		}
		if d.dead {
			break run
		}
		if m := _ls_check(r, want[:], &d, fmt.tprintf("batch %d staged", i)); len(m) > 0 {
			_ls_close(r)
			return d.dead, m
		}
		if i % 2 == 1 {
			_ls_run_job(r)
			_ls_run_job(r)
			if m := _ls_check(r, want[:], &d, fmt.tprintf("batch %d after its job", i)); len(m) > 0 {
				_ls_close(r)
				return d.dead, m
			}
		}
	}
	for _ in 0 ..< 4 {
		if d.dead {
			break
		}
		_ls_run_job(r)
	}
	crashed = d.dead
	d.crash_at = 0
	if !crashed {
		m := _ls_check(r, want[:], &d, "settled")
		for a, i in acks {
			if !a.fired || a.err != .None {
				m = fmt.tprintf("batch %d never became durable (fired %v, %v)", i, a.fired, a.err)
			}
		}
		_ls_close(r)
		return false, m
	}
	acked := 0
	for a, i in acks {
		if a.fired && a.err == .None {
			acked = i + 1
		}
	}
	r.open = false
	r.fd = prim.INVALID_FD
	_ls_close(r)
	rng: Rng
	rng_init(&rng, seed, crash)
	disk_crash(&d, mode, &rng)
	r2, ok2 := _ls_open(&d, false)
	defer _ls_close(r2)
	if !ok2 {
		return true, "recovery: the pack or the file did not reopen"
	}
	got, rok := _ls_read_all(r2)
	if !rok {
		return true, "recovery: reading the file failed"
	}
	for b, j in bounds {
		if j >= acked && len(got) == b && string(got) == string(want[:b]) {
			return true, ""
		}
	}
	return true, fmt.tprintf("recovery: %d bytes are not a whole batch at or after the %d acknowledged (boundaries %v, first difference at %d)", len(got), acked, bounds[:], _ls_diff(got, want[:]))
}

@(test)
pack_log_stage_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	cases, crashes := 0, 0
	for mode in Crash_Mode {
		for seed in u64(1) ..= (u64(1) if mode == .Process else 3) {
			for k := u64(1); ; k += 1 {
				crashed, msg := _ls_case(mode, k, seed)
				cases += 1
				if len(msg) > 0 {
					testing.expectf(t, false, "pack log staging, %v crash at op %d (seed %d): %s", mode, k, seed, msg)
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
	fmt.eprintfln("pack_log_stage_crash: %d runs, %d crash points, all recovered", cases, crashes)
}

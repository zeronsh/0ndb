package pack

import "base:runtime"
import "core:hash/xxhash"
import "core:sync"
import "core:thread"
import "../prim"

@(private)
Job_Kind :: enum u8 {
	Commit,
	Flush,
	Merge,
	Super,
	Delete,
}

@(private)
Zero_Job :: struct {
	fd:     prim.Fd,
	cont:   u32,
	off:    i64,
	len:    i64,
	urgent: bool,
}

@(private)
Scan :: struct {
	inum: u64,
	lo:   i64,
	hi:   i64,
}

@(private)
Cont_Fd :: struct {
	fd:   prim.Fd,
	cont: u32,
}

@(private)
Snap :: struct {
	gen:        u64,
	ck_cont:    u32,
	ck_off:     i64,
	ck_seq:     u64,
	next_ino:   u64,
	next_cont:  u32,
	next_run:   u32,
	compacting: u32,
	cpos:       i64,
	clean:      bool,
	runs:       [dynamic]Run,
	conts:      [dynamic]Cont,
}

@(private)
Inflight :: struct {
	on:       bool,
	kind:     Job_Kind,
	wrote:    bool,
	seq:      u64,
	cont:     u32,
	start:    i64,
	end:      i64,
	fd:       prim.Fd,
	fds:      [dynamic]Job_Fd,
	zjobs:    [dynamic]Zero_Job,
	syncs:    [dynamic]Cont_Fd,
	newc_fd:  prim.Fd,
	dirsync:  bool,
	crec:     [REC_HDR + COMMIT_BODY]u8,
	crec_off: i64,
	ccont:    u32,
	cpos:     i64,
	scans:    [dynamic]Scan,
	scan_fd:  prim.Fd,
	del_id:   u32,
	del_path: prim.Path_Buf,
	del_len:  int,
	busy:     [dynamic]u32,
	imm:      ^Mem,
	drop:     bool,
	run_fd:   prim.Fd,
	run_id:   u32,
	run:      Run,
	built:    bool,
	snap:     Snap,
	has_snap: bool,
	super_fd: prim.Fd,
	root:     string,
	merge:    ^Merge,
	base:     prim.Vfs,
	nsync:    u64,
}

@(private)
Job_Fd :: struct {
	fd:    prim.Fd,
	inum:  u64,
	owned: bool,
}

@(private)
Worker :: struct {
	th:        ^thread.Thread,
	req:       sync.Sema,
	done:      sync.Sema,
	quit:      bool,
	finished:  i32,
	job:       ^Inflight,
	err:       Error,
	wake:      proc(data: rawptr),
	wake_data: rawptr,
}

@(private)
_snap_take :: proc(p: ^Pack, s: ^Snap) {
	s^ = {
		gen        = p.gen,
		ck_cont    = p.ck_cont,
		ck_off     = p.ck_off,
		ck_seq     = p.ck_seq,
		next_ino   = p.next_ino,
		next_cont  = p.next_cont,
		next_run   = p.next_run,
		compacting = p.compacting,
		cpos       = p.compact_resume,
		clean      = p.closing,
	}
	s.runs = make([dynamic]Run, 0, len(p.runs) + 1, p.allocator)
	for r in p.runs {
		append(&s.runs, r^)
	}
	s.conts = make([dynamic]Cont, 0, len(p.conts), p.allocator)
	append(&s.conts, ..p.conts[:])
}

@(private)
_snap_free :: proc(s: ^Snap) {
	delete(s.runs)
	delete(s.conts)
	s.runs = nil
	s.conts = nil
}

@(private)
_snap_encode :: proc(s: ^Snap, out: ^[dynamic]u8) -> bool {
	clear(out)
	w := prim.writer(out)
	prim.write_u32le(&w, 0)
	prim.write_u64le(&w, 0)
	prim.write_u64le(&w, SUPER_MAGIC)
	prim.write_u32le(&w, VERSION)
	prim.write_u64le(&w, s.gen)
	prim.write_u32le(&w, s.ck_cont)
	prim.write_u64le(&w, u64(s.ck_off))
	prim.write_u64le(&w, s.ck_seq)
	prim.write_u64le(&w, s.next_ino)
	prim.write_u32le(&w, s.next_cont)
	prim.write_u32le(&w, s.next_run)
	prim.write_u32le(&w, s.compacting)
	prim.write_u64le(&w, u64(max(s.cpos, 0)))
	prim.write_u8(&w, 1 if s.clean else 0)
	prim.write_uvarint(&w, u64(len(s.runs)))
	for r in s.runs {
		prim.write_u32le(&w, r.id)
		prim.write_u8(&w, r.level)
		prim.write_u8(&w, r.depth)
		prim.write_u32le(&w, r.root)
		prim.write_u32le(&w, r.nblocks)
		prim.write_u64le(&w, r.nentries)
	}
	prim.write_uvarint(&w, u64(len(s.conts)))
	for c in s.conts {
		prim.write_u32le(&w, c.id)
		prim.write_uvarint(&w, u64(max(c.live, 0)))
	}
	if w.err != .None || len(out) > SUPER_SLOT {
		return false
	}
	prim.put_u32le(out[0:4], u32(len(out)))
	prim.put_u64le(out[4:12], xxhash.XXH3_64_with_seed(out[12:], SUPER_MAGIC))
	return true
}

@(private)
_snap_write :: proc(base: prim.Vfs, fd: prim.Fd, s: ^Snap, nsync: ^u64) -> Error {
	buf := make([dynamic]u8, runtime.heap_allocator())
	defer delete(buf)
	if !_snap_encode(s, &buf) {
		return .Too_Large
	}
	prim.write_at(base, fd, buf[:], i64(s.gen % 2) * SUPER_SLOT) or_return
	nsync^ += 1
	return prim.datasync(base, fd)
}

@(private)
_zero_range :: proc(base: prim.Vfs, fd: prim.Fd, off: i64, size: i64) -> Error {
	lo := (off + BLOCK - 1) / BLOCK * BLOCK
	hi := (off + size) / BLOCK * BLOCK
	if hi - lo >= 4 * BLOCK {
		if prim.punch_hole(base, fd, lo, hi - lo) == .None {
			_zero_bytes(base, fd, off, lo - off) or_return
			return _zero_bytes(base, fd, hi, off + size - hi)
		}
	}
	return _zero_bytes(base, fd, off, size)
}

@(private)
_zero_bytes :: proc(base: prim.Vfs, fd: prim.Fd, off: i64, size: i64) -> Error {
	zeros: [BLOCK]u8
	pos := off
	end := off + size
	for pos < end {
		n := min(end - pos, BLOCK)
		prim.write_at(base, fd, zeros[:n], pos) or_return
		pos += n
	}
	return .None
}

@(private)
_build_run :: proc(base: prim.Vfs, fd: prim.Fd, imm: ^Mem, drop: bool) -> (run: Run, err: Error) {
	order := _mem_sorted(imm, nil, nil, runtime.heap_allocator())
	defer delete(order, runtime.heap_allocator())
	bd: Builder
	_builder_init(&bd, base, fd) or_return
	defer _builder_destroy(&bd)
	for off in order {
		r := _mem_rec(imm, off)
		tomb := r.flags & MEM_TOMB != 0
		if tomb && drop {
			continue
		}
		_builder_add(&bd, r.key, r.val, tomb)
	}
	if bd.nentries == 0 {
		_builder_add(&bd, []u8{0}, nil, true)
	}
	return _builder_finish(&bd, 0)
}

@(private)
_job_exec :: proc(fl: ^Inflight) -> Error {
	base := fl.base
	for j in fl.fds {
		fl.nsync += 1
		prim.datasync(base, j.fd) or_return
	}
	if fl.newc_fd >= 0 {
		fl.nsync += 1
		prim.datasync(base, fl.newc_fd) or_return
	}
	if fl.dirsync {
		fl.nsync += 1
		prim.sync_dir(base, fl.root) or_return
	}
	if fl.wrote {
		prim.write_at(base, fl.fd, fl.crec[:], fl.crec_off) or_return
		fl.nsync += 1
		prim.datasync(base, fl.fd) or_return
	}
	for z in fl.zjobs {
		_zero_range(base, z.fd, z.off, z.len) or_return
	}
	for c in fl.syncs {
		fl.nsync += 1
		prim.datasync(base, c.fd) or_return
	}
	if fl.scan_fd >= 0 && len(fl.scans) > 0 {
		_scan_erase(base, fl.scan_fd, fl.scans[:]) or_return
		fl.nsync += 1
		prim.datasync(base, fl.scan_fd) or_return
	}
	switch fl.kind {
	case .Commit:
	case .Super:
		return _snap_write(base, fl.super_fd, &fl.snap, &fl.nsync)
	case .Delete:
		if e := prim.remove(base, string(fl.del_path[:fl.del_len])); e != .None && e != .Not_Found {
			return e
		}
		fl.nsync += 1
		return prim.sync_dir(base, fl.root)
	case .Flush:
		if fl.imm != nil && fl.imm.count > 0 {
			run := _build_run(base, fl.run_fd, fl.imm, fl.drop) or_return
			run.id = fl.run_id
			fl.nsync += 2
			prim.datasync(base, fl.run_fd) or_return
			prim.sync_dir(base, fl.root) or_return
			fl.run = run
			fl.built = true
			append(&fl.snap.runs, run)
		}
		return _snap_write(base, fl.super_fd, &fl.snap, &fl.nsync)
	case .Merge:
		fl.nsync += 2
		prim.datasync(base, fl.merge.fd) or_return
		prim.sync_dir(base, fl.root) or_return
		return _snap_write(base, fl.super_fd, &fl.snap, &fl.nsync)
	}
	return .None
}

@(private)
_worker_main :: proc(t: ^thread.Thread) {
	w := (^Worker)(t.data)
	for {
		sync.sema_wait(&w.req)
		if sync.atomic_load(&w.quit) {
			return
		}
		w.err = _job_exec(w.job)
		sync.atomic_store_explicit(&w.finished, 1, .Release)
		sync.sema_post(&w.done)
		if w.wake != nil {
			w.wake(w.wake_data)
		}
	}
}

@(private)
_submit :: proc(p: ^Pack) -> Error {
	p.fl.on = true
	p.fl.base = p.base
	p.fl.nsync = 0
	p.fl.root = p.root
	p.fl.super_fd = p.super_fd
	if p.opts.worker.submit != nil {
		p.hook_ran = false
		p.opts.worker.submit(p.opts.worker.data)
		return .None
	}
	if p.opts.wake == nil {
		return .None
	}
	if p.worker == nil {
		w := new(Worker, p.allocator)
		if w == nil {
			return _poison(p, .No_Memory)
		}
		w.wake = p.opts.wake
		w.wake_data = p.opts.wake_data
		t := thread.create(_worker_main)
		if t == nil {
			free(w, p.allocator)
			return _poison(p, .No_Memory)
		}
		t.data = w
		w.th = t
		p.worker = w
		thread.start(t)
	}
	p.worker.job = &p.fl
	p.worker.err = .None
	sync.sema_post(&p.worker.req)
	return .None
}

@(private)
_worker_wait :: proc(p: ^Pack) -> Error {
	if p.worker == nil {
		if p.hook_ran {
			p.hook_ran = false
			return p.hook_err
		}
		return _job_exec(&p.fl)
	}
	for sync.atomic_exchange_explicit(&p.worker.finished, 0, .Acquire) != 1 {
		sync.sema_wait(&p.worker.done)
	}
	return p.worker.err
}

@(private)
_worker_try :: proc(p: ^Pack) -> (done: bool, err: Error) {
	if p.worker == nil {
		if p.opts.worker.submit == nil {
			return true, _job_exec(&p.fl)
		}
		if !p.hook_ran {
			return false, .None
		}
		p.hook_ran = false
		return true, p.hook_err
	}
	if sync.atomic_exchange_explicit(&p.worker.finished, 0, .Acquire) != 1 {
		return false, .None
	}
	return true, p.worker.err
}

worker_run :: proc(p: ^Pack) -> bool {
	if p.opts.worker.submit == nil || !p.fl.on || p.hook_ran {
		return false
	}
	p.hook_err = _job_exec(&p.fl)
	p.hook_ran = true
	if p.opts.wake != nil {
		p.opts.wake(p.opts.wake_data)
	}
	return true
}

@(private)
_polled :: proc "contextless" (p: ^Pack) -> bool {
	return p.worker == nil && p.opts.worker.submit == nil
}

@(private)
_worker_stop :: proc(p: ^Pack) {
	w := p.worker
	if w == nil {
		return
	}
	sync.atomic_store(&w.quit, true)
	sync.sema_post(&w.req)
	thread.join(w.th)
	thread.destroy(w.th)
	free(w, p.allocator)
	p.worker = nil
}

@(private)
_scan_erase :: proc(base: prim.Vfs, fd: prim.Fd, scans: []Scan) -> Error {
	size := prim.file_size(base, fd) or_return
	CHUNK :: 1 << 20
	buf := make([]u8, CHUNK + MAX_RECORD, runtime.heap_allocator())
	defer delete(buf, runtime.heap_allocator())
	start: i64 = 0
	have := 0
	pos: i64 = CONT_HDR
	for pos + REC_HDR <= size {
		if pos < start || pos + REC_HDR > start + i64(have) {
			n, err := prim.read_at(base, fd, buf[:CHUNK], pos)
			if err != .None {
				return err
			}
			start = pos
			have = n
			if have < REC_HDR {
				break
			}
		}
		h := buf[pos - start:]
		ln := i64(prim.get_u32le(h[0:4]))
		kind := h[4]
		if ln > MAX_RECORD || pos + REC_HDR + ln > size {
			break
		}
		if kind == R_DATA {
			if pos + REC_HDR + ln > start + i64(have) {
				n, err := prim.read_at(base, fd, buf[:REC_HDR + int(ln)], pos)
				if err != .None {
					return err
				}
				if n < REC_HDR + int(ln) {
					break
				}
				start = pos
				have = n
			}
			body := buf[pos - start + REC_HDR:][:ln]
			inum, n1 := prim.get_uvarint(body)
			foff, n2 := prim.get_uvarint(body[max(n1, 0):])
			if n1 <= 0 || n2 <= 0 {
				break
			}
			plen := ln - i64(n1 + n2)
			pstart := pos + REC_HDR + i64(n1 + n2)
			for s in scans {
				if s.inum != inum {
					continue
				}
				lo := max(s.lo, i64(foff))
				hi := min(s.hi, i64(foff) + plen)
				if lo < hi {
					_zero_range(base, fd, pstart + (lo - i64(foff)), hi - lo) or_return
				}
			}
		} else if kind != R_PUT && kind != R_DEL && kind != R_NEXT && kind != R_COMMIT {
			break
		}
		pos += REC_HDR + ln
	}
	return .None
}

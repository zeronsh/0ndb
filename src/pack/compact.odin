package pack

import "core:fmt"
import "core:mem/virtual"
import "../prim"

@(private)
Compact :: struct {
	on:    bool,
	cont:  u32,
	pos:   i64,
	lr:    Log_Reader,
	moved: i64,
}

@(private)
_compact_reset :: proc(p: ^Pack) {
	c := &p.compact
	if c.lr.own && c.lr.fd >= 0 {
		prim.close_file(p.base, c.lr.fd)
	}
	delete(c.lr.buf)
	c^ = {}
}

@(private)
_compact_pick :: proc(p: ^Pack, all: bool) -> (id: u32, ok: bool) {
	best := -1.0
	for &c, i in p.conts {
		if i == p.active || c.id >= p.ck_cont || (all && c.id >= p.horizon) {
			continue
		}
		if c.size <= 0 {
			fd, err := _cont_fd(p, c.id)
			if err != .None {
				continue
			}
			size, serr := prim.file_size(p.base, fd)
			if serr != .None {
				continue
			}
			c.size = size
		}
		data := f64(max(c.size - CONT_HDR, 1))
		garbage := 1.0 - f64(max(c.live, 0)) / data
		if (all || garbage >= p.opts.compact_ratio) && garbage > best {
			best = garbage
			id = c.id
			ok = true
		}
	}
	return
}

@(private)
_compact_blocked :: proc "contextless" (p: ^Pack) -> bool {
	if p.opts.compact_ratio <= 0 {
		return false
	}
	for c, i in p.conts {
		if i == p.active || c.id < p.ck_cont || c.size <= CONT_HDR {
			continue
		}
		if 1.0 - f64(max(c.live, 0)) / f64(c.size - CONT_HDR) >= p.opts.compact_ratio {
			return true
		}
	}
	return false
}

@(private)
RECLAIM_WINDOWS :: 2

@(private)
RECLAIM_SLICE :: i64(256 * 1024)

@(private)
RECLAIM_SLICES :: 64

@(private)
_reclaim_owed :: proc "contextless" (p: ^Pack) -> bool {
	if p.opts.compact_ratio <= 0 {
		return false
	}
	owed: i64
	for c, i in p.conts {
		if i == p.active || c.id >= p.ck_cont {
			continue
		}
		data := c.size - CONT_HDR
		dead := data - max(c.live, 0)
		if data > 0 && f64(dead) >= p.opts.compact_ratio * f64(data) {
			owed += dead
		}
	}
	return owed >= p.opts.log_window * RECLAIM_WINDOWS
}

@(private)
_relocate :: proc(p: ^Pack, inum: u64, ino: ^Inode, src: Phys, src_bytes: []u8) -> Error {
	if ino.kind != .File || ino.n == 0 {
		return .None
	}
	from := ino.ext[0].off
	to := ino.ext[ino.n - 1].off + ino.ext[ino.n - 1].len
	resize(&p.work, int(to - from))
	buf := p.work[:]
	pos := from
	if ino.n == 1 && ino.ext[0].cont == src.cont && ino.ext[0].coff >= src.off && ino.ext[0].coff + ino.ext[0].len <= src.off + src.len {
		copy(buf, src_bytes[ino.ext[0].coff - src.off:][:ino.ext[0].len])
		pos = to
	}
	for e in ino.ext[:ino.n] {
		if pos >= to {
			break
		}
		if e.off > pos {
			_zero(buf[pos - from:e.off - from])
		}
		_phys_read(p, Phys{cont = e.cont, off = e.coff, len = e.len}, buf[e.off - from:][:e.len]) or_return
		pos = e.off + e.len
	}
	old := ino^
	ph := _log_data(p, inum, from, buf) or_return
	ino.n = 1
	ino.ext[0] = Extent{off = from, len = to - from, cont = ph.cont, coff = ph.off}
	_inode_store(p, inum, &old, ino) or_return
	p.stats.compact_moved += u64(to - from)
	p.compact.moved += to - from
	return _maybe_flush(p)
}

@(private)
_compact_work :: proc(p: ^Pack, budget: i64, all: bool) -> (more: bool, err: Error) {
	c := &p.compact
	if !c.on {
		id: u32
		ok: bool
		resume: i64 = CONT_HDR
		if p.compacting != 0 && _cont_index(p, p.compacting) >= 0 && p.compacting < p.ck_cont {
			id, ok = p.compacting, true
			resume = max(p.compact_resume, CONT_HDR)
		} else {
			p.compacting = 0
			id, ok = _compact_pick(p, all)
		}
		if !ok {
			return false, .None
		}
		if p.compacting != id {
			if _async(p) {
				if p.fl.on {
					return true, .None
				}
				p.compacting = id
				p.compact_resume = resume
				p.gen += 1
				_snap_take(p, &p.fl.snap)
				p.fl.has_snap = true
				p.fl.kind = .Super
				_submit(p) or_return
			} else {
				p.compacting = id
				p.compact_resume = resume
				if e := _super_write(p); e != .None {
					return false, _poison(p, e)
				}
			}
		}
		p.compact_resume = resume
		c.on = true
		c.cont = id
		c.pos = resume
		c.moved = 0
		c.lr.buf = make([dynamic]u8, p.allocator)
		if !_open_lr(p, &c.lr, id, true) {
			_compact_reset(p)
			return false, .Io
		}
		if c.pos > c.lr.size {
			c.pos = CONT_HDR
		}
	}
	if _cont_index(p, c.cont) < 0 {
		_compact_reset(p)
		return true, .None
	}
	spent: i64
	for spent < budget {
		h, ok := _lr_get(&c.lr, c.pos, REC_HDR)
		if !ok {
			break
		}
		ln := prim.get_u32le(h[0:4])
		if ln > _max_rec(p) {
			break
		}
		rec, rok := _lr_get(&c.lr, c.pos, REC_HDR + int(ln))
		if !rok {
			break
		}
		kind := rec[4]
		if kind == R_DATA {
			body := rec[REC_HDR:]
			inum, n1 := prim.get_uvarint(body)
			foff, n2 := prim.get_uvarint(body[n1:])
			if n1 <= 0 || n2 <= 0 {
				break
			}
			ph := Phys{cont = c.cont, off = c.pos + REC_HDR + i64(n1 + n2), len = i64(ln) - i64(n1 + n2), foff = i64(foff)}
			ino: Inode
			live, lerr := _phys_live(p, inum, ph, &ino)
			if lerr != .None {
				return false, lerr
			}
			if live {
				_relocate(p, inum, &ino, ph, rec[REC_HDR + n1 + n2:]) or_return
				spent += ph.len
			}
			_stale_prune(p, inum, ph.foff, ph.len, ph.cont, ph.off) or_return
		} else if kind != R_PUT && kind != R_DEL && kind != R_NEXT && kind != R_COMMIT {
			break
		}
		spent += i64(REC_HDR) + i64(ln) / 8
		c.pos += REC_HDR + i64(ln)
		if c.pos >= c.lr.size {
			break
		}
	}
	if c.pos < c.lr.size {
		if spent >= budget {
			return true, .None
		}
		_compact_reset(p)
		return false, .Io
	}
	if p.fl.on {
		if _async(p) {
			return true, .None
		}
		_drain(p) or_return
	}
	id := c.cont
	_compact_reset(p)
	p.force = true
	wrote := _commit_write(p) or_return
	_collect_zeros(p, p.seq - 1 if wrote else p.durable_seq) or_return
	pb: prim.Path_Buf
	path := _phys_path(p, &pb, 'c', u64(id))
	p.fl.del_len = copy(p.fl.del_path[:], path)
	p.fl.del_id = id
	p.fl.kind = .Delete
	_submit(p) or_return
	if !_async(p) {
		_drain(p) or_return
	}
	return true, .None
}

@(private)
_phys_live :: proc(p: ^Pack, inum: u64, ph: Phys, ino: ^Inode) -> (live: bool, err: Error) {
	found := _inode_load(p, inum, ino) or_return
	if !found || ino.kind != .File {
		return false, .None
	}
	for e in ino.ext[:ino.n] {
		if e.cont == ph.cont && e.coff < ph.off + ph.len && ph.off < e.coff + e.len {
			return true, .None
		}
	}
	return false, .None
}

DBG_N: int

step :: proc(p: ^Pack, budget: i64 = 4 * 1024 * 1024) -> (more: bool, err: Error) {
	DBG_N += 1
	if DBG_N > 200 && DBG_N % 20000 == 0 {
		n := 0
		for c in p.conts {
			if c.id < p.ck_cont {
				n += 1
			}
		}
		fmt.eprintln("DBGSTEP", DBG_N, "fl", p.fl.on, "owed", _reclaim_owed(p), "blocked", _compact_blocked(p), "compacting", p.compacting, "con", p.compact.on, "ck", p.ck_cont, "act", _active_id(p), "below", n, "nrec", p.nrec, "dirty", len(p.dirty), "mem", _mem_bytes(&p.mem), "lsck", p.log_since_ck, "imgs", len(p.imgs), "want", p.want_flush, "rcd", p.reclaimed, "pressure", p.pressure, "batch", p.batch)
	}
	if p.poisoned {
		return false, .Io
	}
	if p.batch > 0 {
		return false, .None
	}
	_release_lent(p)
	poll(p) or_return
	if p.fl.on {
		return !_async(p) || _polled(p), .None
	}
	if _reclaim_owed(p) {
		if _async(p) && !_polled(p) {
			_reclaim(p) or_return
		} else {
			_compact_work(p, budget, false) or_return
		}
		return true, .None
	}
	if _mem_bytes(&p.mem) >= p.opts.mem_budget / 8 || p.log_since_ck >= p.opts.log_window / 8 || _compact_blocked(p) {
		if _async(p) {
			_flush_start(p) or_return
		} else {
			_flush(p) or_return
		}
		return true, .None
	}
	if p.nrec > 0 || len(p.dirty) > 0 || p.img_dirty > 0 {
		if _async(p) {
			_start_async(p) or_return
			return _polled(p), .None
		}
		_sync_all(p) or_return
	}
	m := _merge_step(p, budget) or_return
	if m {
		return true, .None
	}
	c := _compact_work(p, budget, false) or_return
	if c {
		return true, .None
	}
	_shrink(p)
	return false, .None
}

compact_all :: proc(p: ^Pack, budget: i64 = 4 * 1024 * 1024) -> (more: bool, err: Error) {
	if p.poisoned {
		return false, .Io
	}
	if p.horizon == 0 {
		if p.mem.count > 0 || p.nrec > 0 || p.img_dirty > 0 {
			_flush(p) or_return
		}
		p.horizon = p.ck_cont
	}
	more = _compact_work(p, budget, true) or_return
	if !more {
		p.horizon = 0
	}
	return more, .None
}

@(private)
_shrink :: proc(p: ^Pack) {
	if len(p.buf) == 0 && cap(p.buf) > 0 {
		delete(p.buf)
		p.buf = make([dynamic]u8, p.allocator)
	}
	if !p.fl.on && len(p.fl.data) == 0 && cap(p.fl.data) > 0 {
		delete(p.fl.data)
		p.fl.data = make([dynamic]u8, p.allocator)
	}
	if cap(p.scratch) > 0 {
		delete(p.scratch)
		p.scratch = make([dynamic]u8, p.allocator)
	}
	if cap(p.work) > 0 {
		delete(p.work)
		p.work = make([dynamic]u8, p.allocator)
	}
	if cap(p.vbuf) > 0 {
		delete(p.vbuf)
		p.vbuf = make([dynamic]u8, p.allocator)
	}
	if len(p.dirty) == 0 && cap(p.dirty) > 0 {
		delete(p.dirty)
		p.dirty = make([dynamic]u32, p.allocator)
	}
	if p.mem.count == 0 {
		_mem_reset(&p.mem)
	}
	if p.bcache != nil {
		virtual.release(raw_data(p.bcache), uint(BCACHE * size_of(Bc_Entry)))
		p.bcache = nil
	}
	for r in p.runs {
		_run_filter_drop(p, r)
	}
	p.filters_cold = true
	for &c, i in p.conts {
		if i != p.active && c.fd >= 0 && !c.dirty && !c.lent {
			prim.close_file(p.base, c.fd)
			c.fd = prim.INVALID_FD
		}
	}
}

@(private)
_release_lent :: proc(p: ^Pack) {
	for &c in p.conts {
		c.lent = false
	}
	for fd in p.graveyard {
		prim.close_file(p.base, fd)
	}
	clear(&p.graveyard)
}

package pack

import "core:hash/xxhash"
import "core:slice"
import "../prim"

@(private)
REC_HDR :: 5
@(private)
R_DATA :: u8(1)
@(private)
R_PUT :: u8(2)
@(private)
R_DEL :: u8(3)
@(private)
R_NEXT :: u8(4)
@(private)
R_COMMIT :: u8(5)
@(private)
COMMIT_BODY :: 36
@(private)
COMMIT_SEED :: u64(0x7469_6d6d_6f63)
@(private)
MAX_META_REC :: 16 * 1024

@(private)
_active_id :: #force_inline proc "contextless" (p: ^Pack) -> u32 {
	return p.conts[p.active].id
}

@(private)
_log_tail :: #force_inline proc "contextless" (p: ^Pack) -> i64 {
	return p.buf_base + i64(len(p.buf))
}

@(private)
_log_spill :: proc(p: ^Pack) -> Error {
	if len(p.buf) == 0 {
		return .None
	}
	c := &p.conts[p.active]
	if e := prim.write_at(p.base, c.fd, p.buf[:], p.buf_base); e != .None {
		return _poison(p, e)
	}
	p.buf_base += i64(len(p.buf))
	c.size = p.buf_base
	clear(&p.buf)
	return .None
}

@(private)
_log_alloc :: proc(p: ^Pack, n: int) -> (pos: int, err: Error) {
	if len(p.buf) > 0 && len(p.buf) + n > p.opts.spill {
		_log_spill(p) or_return
	}
	pos = len(p.buf)
	if resize(&p.buf, pos + n) != nil {
		return 0, .No_Memory
	}
	return pos, .None
}

@(private)
_log_data :: proc(p: ^Pack, inum: u64, off: i64, payload: []u8) -> (ph: Phys, err: Error) {
	meta: [20]u8
	m := prim.put_uvarint(meta[:], inum)
	m += prim.put_uvarint(meta[m:], u64(off))
	hdr := REC_HDR + m
	pos := _log_alloc(p, hdr + len(payload)) or_return
	b := p.buf[pos:]
	prim.put_u32le(b[0:4], u32(m + len(payload)))
	b[4] = R_DATA
	copy(b[REC_HDR:], meta[:m])
	copy(b[hdr:], payload)
	p.hh = xxhash.XXH3_64_with_seed(b[:hdr], p.hh)
	p.dh = xxhash.XXH3_64_with_seed(payload, p.dh)
	p.nrec += 1
	return Phys{cont = _active_id(p), off = p.buf_base + i64(pos + hdr), len = i64(len(payload))}, .None
}

@(private)
_log_meta :: proc(p: ^Pack, kind: u8, key: []u8, val: []u8) -> Error {
	kl: [10]u8
	kn := prim.put_uvarint(kl[:], u64(len(key)))
	body := kn + len(key) + len(val)
	pos := _log_alloc(p, REC_HDR + body) or_return
	b := p.buf[pos:]
	prim.put_u32le(b[0:4], u32(body))
	b[4] = kind
	copy(b[REC_HDR:], kl[:kn])
	copy(b[REC_HDR + kn:], key)
	copy(b[REC_HDR + kn + len(key):], val)
	p.hh = xxhash.XXH3_64_with_seed(b[:REC_HDR + body], p.hh)
	p.nrec += 1
	return .None
}

@(private)
_log_raw :: proc(p: ^Pack, kind: u8, body: []u8) -> Error {
	pos := _log_alloc(p, REC_HDR + len(body)) or_return
	b := p.buf[pos:]
	prim.put_u32le(b[0:4], u32(len(body)))
	b[4] = kind
	copy(b[REC_HDR:], body)
	p.hh = xxhash.XXH3_64_with_seed(b[:REC_HDR + len(body)], p.hh)
	p.nrec += 1
	return .None
}

@(private)
_commit_record :: proc(b: []u8, seq: u64, nrec: int, hh: u64, dh: u64) {
	prim.put_u32le(b[0:4], COMMIT_BODY)
	b[4] = R_COMMIT
	prim.put_u64le(b[5:13], seq)
	prim.put_u32le(b[13:17], u32(nrec))
	prim.put_u64le(b[17:25], hh)
	prim.put_u64le(b[25:33], dh)
	prim.put_u64le(b[33:41], xxhash.XXH3_64_with_seed(b[:33], COMMIT_SEED))
}

@(private)
_phys_read :: proc(p: ^Pack, ph: Phys, dst: []u8) -> Error {
	n := i64(len(dst))
	if p.active >= 0 && ph.cont == _active_id(p) && ph.off + n > p.buf_base {
		head := max(p.buf_base - ph.off, 0)
		if head > 0 {
			_phys_read(p, Phys{cont = ph.cont, off = ph.off, len = head}, dst[:head]) or_return
		}
		if ph.off + n > p.buf_base + i64(len(p.buf)) {
			return .Io
		}
		copy(dst[head:], p.buf[ph.off + head - p.buf_base:][:n - head])
		return .None
	}
	fd := _cont_fd(p, ph.cont) or_return
	got, err := prim.read_at(p.base, fd, dst, ph.off)
	if err != .None {
		return err
	}
	if i64(got) != n {
		return .Io
	}
	return .None
}

@(private)
_emit_dirty :: proc(p: ^Pack) -> Error {
	for off in p.dirty {
		rec := _mem_rec(&p.mem, off)
		cur, ok := _mem_get(&p.mem, rec.key)
		if !ok || cur.flags & MEM_DIRTY == 0 {
			continue
		}
		kind := R_DEL if cur.flags & MEM_TOMB != 0 else R_PUT
		_log_meta(p, kind, cur.key, cur.val) or_return
		_mem_clear_dirty(&p.mem, cur.off)
	}
	clear(&p.dirty)
	return .None
}

@(private)
_new_container :: proc(p: ^Pack) -> (idx: int, err: Error) {
	id := p.next_cont
	p.next_cont += 1
	pb: prim.Path_Buf
	path := _phys_path(p, &pb, 'c', u64(id))
	fd := prim.open_file(p.base, path, {.Write, .Create, .Exclusive}, 0o600) or_return
	hdr: [CONT_HDR]u8
	prim.put_u64le(hdr[0:8], CONT_MAGIC)
	prim.put_u32le(hdr[8:12], VERSION)
	prim.put_u32le(hdr[12:16], id)
	prim.put_u64le(hdr[CONT_HDR - 8:], xxhash.XXH3_64_with_seed(hdr[:CONT_HDR - 8], CONT_MAGIC))
	if e := prim.write_at(p.base, fd, hdr[:], 0); e != .None {
		prim.close_file(p.base, fd)
		return -1, e
	}
	if e := _sync(p, fd); e != .None {
		prim.close_file(p.base, fd)
		return -1, e
	}
	if e := _sync_root(p); e != .None {
		prim.close_file(p.base, fd)
		return -1, e
	}
	append(&p.conts, Cont{id = id, fd = fd, size = CONT_HDR, used = p.tick})
	return len(p.conts) - 1, .None
}

Sync_Done :: proc(data: rawptr, err: Error)

@(private)
Waiter :: struct {
	seq:  u64,
	done: Sync_Done,
	data: rawptr,
}

@(private)
_commit_write :: proc(p: ^Pack) -> (wrote: bool, err: Error) {
	if p.poisoned {
		return false, .Io
	}
	_emit_dirty(p) or_return
	if p.nrec == 0 && !p.force {
		return false, .None
	}
	p.force = false
	next := -1
	if _log_tail(p) + 64 >= p.opts.container_size {
		idx, nerr := _new_container(p)
		if nerr != .None {
			return false, _poison(p, nerr)
		}
		next = idx
		nb: [4]u8
		prim.put_u32le(nb[:], p.conts[idx].id)
		_log_raw(p, R_NEXT, nb[:]) or_return
	}
	pos := _log_alloc(p, REC_HDR + COMMIT_BODY) or_return
	_commit_record(p.buf[pos:], p.seq, p.nrec, p.hh, p.dh)
	start := p.group_start
	_log_spill(p) or_return
	c := &p.conts[p.active]
	c.busy = true
	append(&p.fl.busy, c.id)
	p.fl.wrote = true
	p.fl.seq = p.seq
	p.fl.cont = c.id
	p.fl.start = start
	p.fl.end = p.buf_base
	p.fl.fd = c.fd
	p.stats.commits += 1
	p.stats.log_bytes += u64(p.buf_base - start)
	p.log_since_ck += p.buf_base - start
	p.seq += 1
	p.nrec = 0
	p.hh = p.seq
	p.dh = p.seq
	if next >= 0 {
		p.active = next
		p.buf_base = CONT_HDR
	}
	p.group_start = p.buf_base
	return true, .None
}

@(private)
_job_complete :: proc(p: ^Pack, err: Error) -> Error {
	fl := &p.fl
	for j in fl.fds {
		if j.owned {
			prim.close_file(p.base, j.fd)
		} else {
			_unpin_real(p, j.fd)
		}
	}
	clear(&fl.fds)
	clear(&fl.zjobs)
	clear(&fl.syncs)
	for id in fl.busy {
		ci := _cont_index(p, id)
		if ci >= 0 {
			p.conts[ci].busy = false
			if err == .None {
				p.conts[ci].dirty = false
			}
		}
	}
	clear(&fl.busy)
	p.stats.fsyncs += fl.nsync
	fl.on = false
	kind := fl.kind
	wrote := fl.wrote
	fl.kind = .Commit
	fl.wrote = false
	imm := fl.imm
	fl.imm = nil
	m := fl.merge
	fl.merge = nil
	built := fl.built
	fl.built = false
	snap := fl.snap
	has_snap := fl.has_snap
	fl.has_snap = false
	fl.snap = {}
	defer if has_snap {
		_snap_free(&snap)
	}
	defer if imm != nil {
		_mem_destroy(imm)
		free(imm, p.allocator)
	}
	if err != .None {
		if kind == .Flush && fl.run_fd >= 0 {
			prim.close_file(p.base, fl.run_fd)
			fl.run_fd = prim.INVALID_FD
		}
		if kind == .Merge && m != nil {
			prim.close_file(p.base, m.fd)
			free(m, p.allocator)
		}
		return _poison(p, err)
	}
	if wrote {
		p.last_cont = fl.cont
		p.last_start = fl.start
		p.durable_seq = fl.seq
	}
	switch kind {
	case .Commit:
	case .Flush:
		p.ck_cont = snap.ck_cont
		p.ck_off = snap.ck_off
		p.ck_seq = snap.ck_seq
		if built {
			nr := new(Run, p.allocator)
			nr^ = fl.run
			nr.fd = fl.run_fd
			nr.root_buf = nil
			if e := _run_load(p, nr); e != .None {
				_run_close(p, nr)
				free(nr, p.allocator)
				return _poison(p, e)
			}
			append(&p.runs, nr)
		} else if fl.run_fd >= 0 {
			prim.close_file(p.base, fl.run_fd)
			pb: prim.Path_Buf
			prim.remove(p.base, _phys_path(p, &pb, 'r', u64(fl.run_id)))
		}
		fl.run_fd = prim.INVALID_FD
		p.stats.flushes += 1
	case .Merge:
		_merge_installed(p, m) or_return
	}
	_apply_zeros(p) or_return
	_apply_unlinks(p) or_return
	return .None
}

@(private)
_drain :: proc(p: ^Pack) -> Error {
	if !p.fl.on {
		return .None
	}
	err := _worker_wait(p)
	return _job_complete(p, err)
}

@(private)
_commit :: proc(p: ^Pack) -> Error {
	_drain(p) or_return
	wrote := _commit_write(p) or_return
	if !wrote {
		return .None
	}
	p.fl.kind = .Commit
	_submit(p) or_return
	return _drain(p)
}

@(private)
_apply_zeros :: proc(p: ^Pack) -> Error {
	ready := make([dynamic]Zero, p.allocator)
	defer delete(ready)
	i := 0
	for i < len(p.zeros) {
		z := p.zeros[i]
		if z.need > p.durable_seq {
			i += 1
			continue
		}
		append(&ready, z)
		unordered_remove(&p.zeros, i)
	}
	if len(ready) == 0 {
		return .None
	}
	slice.sort_by(ready[:], proc(a, b: Zero) -> bool {
		if a.phys.cont != b.phys.cont {
			return a.phys.cont < b.phys.cont
		}
		return a.phys.off < b.phys.off
	})
	urgent := false
	k := 0
	for k < len(ready) {
		z := ready[k]
		lo := z.phys.off
		hi := z.phys.off + z.phys.len
		u := z.urgent
		k += 1
		for k < len(ready) && ready[k].phys.cont == z.phys.cont && ready[k].phys.off <= hi {
			hi = max(hi, ready[k].phys.off + ready[k].phys.len)
			u ||= ready[k].urgent
			k += 1
		}
		fd, err := _cont_fd(p, z.phys.cont)
		if err == .Not_Found {
			continue
		}
		if err != .None {
			return _poison(p, err)
		}
		if e := _zero_phys(p, fd, lo, hi - lo); e != .None {
			return _poison(p, e)
		}
		p.stats.zeroed_bytes += u64(hi - lo)
		p.conts[_cont_index(p, z.phys.cont)].dirty = true
		urgent ||= u
	}
	if urgent {
		_sync_dirty_conts(p) or_return
	}
	return .None
}

@(private)
_zero_phys :: proc(p: ^Pack, fd: prim.Fd, off: i64, size: i64) -> Error {
	lo := (off + BLOCK - 1) / BLOCK * BLOCK
	hi := (off + size) / BLOCK * BLOCK
	if hi - lo >= 4 * BLOCK {
		if prim.punch_hole(p.base, fd, lo, hi - lo) == .None {
			_zero_write(p, fd, off, lo - off) or_return
			return _zero_write(p, fd, hi, off + size - hi)
		}
	}
	return _zero_write(p, fd, off, size)
}

@(private)
_zero_write :: proc(p: ^Pack, fd: prim.Fd, off: i64, size: i64) -> Error {
	zeros: [BLOCK]u8
	pos := off
	end := off + size
	for pos < end {
		n := min(end - pos, BLOCK)
		prim.write_at(p.base, fd, zeros[:n], pos) or_return
		pos += n
	}
	return .None
}

@(private)
_sync_dirty_conts :: proc(p: ^Pack) -> Error {
	for &c in p.conts {
		if !c.dirty || c.fd < 0 {
			continue
		}
		if e := _sync(p, c.fd); e != .None {
			return _poison(p, e)
		}
		c.dirty = false
	}
	return .None
}

@(private)
_has_urgent :: proc "contextless" (p: ^Pack) -> bool {
	for z in p.zeros {
		if z.urgent {
			return true
		}
	}
	return false
}

@(private)
_apply_unlinks :: proc(p: ^Pack) -> Error {
	i := 0
	for i < len(p.unlinks) {
		u := p.unlinks[i]
		if u.need > p.durable_seq {
			i += 1
			continue
		}
		pb: prim.Path_Buf
		if e := prim.remove(p.base, _phys_path(p, &pb, 'x', u.inum)); e != .None && e != .Not_Found {
			return _poison(p, e)
		}
		unordered_remove(&p.unlinks, i)
	}
	return .None
}

@(private)
_sync_externals :: proc(p: ^Pack) -> Error {
	for _, oi in p.open_inodes {
		if oi.dirty && oi.real_fd >= 0 {
			if e := _sync(p, oi.real_fd); e != .None {
				return _poison(p, e)
			}
			oi.dirty = false
		}
	}
	for inum in p.ext_dirty {
		pb: prim.Path_Buf
		fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'x', inum), {.Write})
		if err == .Not_Found {
			continue
		}
		if err != .None {
			return _poison(p, err)
		}
		e := _sync(p, fd)
		prim.close_file(p.base, fd)
		if e != .None {
			return _poison(p, e)
		}
	}
	clear(&p.ext_dirty)
	return .None
}

sync :: proc(p: ^Pack) -> Error {
	if p.batch > 0 {
		return .None
	}
	return _sync_all(p)
}

@(private)
_sync_all :: proc(p: ^Pack) -> Error {
	_drain(p) or_return
	_sync_externals(p) or_return
	_commit(p) or_return
	if _has_urgent(p) {
		for p.compacting != 0 {
			_compact_work(p, max(i64), false) or_return
		}
		p.force = true
		_commit(p) or_return
		_apply_zeros(p) or_return
	} else {
		for z in p.zeros {
			if z.need > p.durable_seq {
				p.force = true
				_commit(p) or_return
				break
			}
		}
	}
	if p.log_since_ck >= p.opts.log_window || _mem_bytes(&p.mem) >= p.opts.mem_budget {
		_flush(p) or_return
	}
	_fire_waiters(p)
	return .None
}

sync_async :: proc(p: ^Pack, done: Sync_Done, data: rawptr) -> Error {
	if p.poisoned {
		return .Io
	}
	if (p.opts.wake == nil && !p.opts.deferred_sync) || _has_urgent(p) {
		err := _sync_all(p)
		if done != nil {
			done(data, err)
		}
		return .None
	}
	pending := p.nrec > 0 || len(p.dirty) > 0 || len(p.ext_dirty) > 0 || _ext_open_dirty(p)
	target := p.seq if pending else (p.fl.seq if p.fl.on else 0)
	if target == 0 || target <= p.durable_seq {
		if done != nil {
			done(data, .None)
		}
		return .None
	}
	append(&p.waiters, Waiter{seq = target, done = done, data = data})
	if !p.fl.on {
		_start_async(p) or_return
	}
	return .None
}

@(private)
_ext_open_dirty :: proc(p: ^Pack) -> bool {
	for _, oi in p.open_inodes {
		if oi.dirty && oi.real_fd >= 0 {
			return true
		}
	}
	return false
}

@(private)
_start_async :: proc(p: ^Pack) -> Error {
	if p.fl.on {
		return .None
	}
	clear(&p.fl.fds)
	exts := make([dynamic]Job_Fd, context.temp_allocator)
	for _, oi in p.open_inodes {
		if oi.dirty && oi.real_fd >= 0 {
			append(&exts, Job_Fd{fd = oi.real_fd})
			oi.dirty = false
			oi.pinned += 1
		}
	}
	for inum in p.ext_dirty {
		pb: prim.Path_Buf
		fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'x', inum), {.Write})
		if err == .Not_Found {
			continue
		}
		if err != .None {
			return _poison(p, err)
		}
		append(&exts, Job_Fd{fd = fd, owned = true})
	}
	clear(&p.ext_dirty)
	if len(exts) > 0 {
		p.force = true
	}
	wrote, err := _commit_write(p)
	if err != .None {
		for j in exts {
			if j.owned {
				prim.close_file(p.base, j.fd)
			}
		}
		return err
	}
	if !wrote {
		for j in exts {
			if j.owned {
				prim.close_file(p.base, j.fd)
			} else {
				_unpin_real(p, j.fd)
			}
		}
		return .None
	}
	append(&p.fl.fds, ..exts[:])
	p.fl.kind = .Commit
	return _submit(p)
}

poll :: proc(p: ^Pack) -> Error {
	if !p.fl.on {
		return .None
	}
	done, err := _worker_try(p)
	if !done {
		return .None
	}
	if e := _job_complete(p, err); e != .None {
		_fail_waiters(p, e)
		return e
	}
	_fire_waiters(p)
	if _over_budget(p, 1) {
		if e := _flush_start(p); e != .None {
			_fail_waiters(p, e)
			return e
		}
		return .None
	}
	if len(p.runs) > p.opts.max_runs || (p.merge != nil && len(p.runs) > p.opts.max_runs / 2) {
		if _, e := _merge_step(p, i64(p.opts.mem_budget) / 8); e != .None {
			_fail_waiters(p, e)
			return e
		}
		if p.fl.on {
			return .None
		}
	}
	for w in p.waiters {
		if w.seq > p.durable_seq {
			if e := _start_async(p); e != .None {
				_fail_waiters(p, e)
				return e
			}
			break
		}
	}
	return .None
}

@(private)
_over_budget :: proc(p: ^Pack, factor: int) -> bool {
	return _mem_bytes(&p.mem) >= p.opts.mem_budget * factor || p.log_since_ck + _log_tail(p) - p.group_start >= p.opts.log_window * i64(factor)
}

@(private)
_async :: #force_inline proc "contextless" (p: ^Pack) -> bool {
	return p.opts.wake != nil || p.opts.deferred_sync
}

@(private)
_fire_waiters :: proc(p: ^Pack) {
	i := 0
	for i < len(p.waiters) {
		w := p.waiters[i]
		if w.seq <= p.durable_seq {
			ordered_remove(&p.waiters, i)
			if w.done != nil {
				w.done(w.data, .None)
			}
			continue
		}
		i += 1
	}
}

@(private)
_fail_waiters :: proc(p: ^Pack, err: Error) {
	ws := p.waiters
	p.waiters = make([dynamic]Waiter, p.allocator)
	for w in ws {
		if w.done != nil {
			w.done(w.data, err)
		}
	}
	delete(ws)
}

@(private)
_unpin_real :: proc(p: ^Pack, fd: prim.Fd) {
	for _, oi in p.open_inodes {
		if oi.real_fd == fd && oi.pinned > 0 {
			oi.pinned -= 1
			return
		}
	}
}

batch_begin :: proc(p: ^Pack) {
	if p.batch == 0 {
		_release_lent(p)
	}
	p.batch += 1
}

batch_end :: proc(p: ^Pack) -> Error {
	if p.batch > 0 {
		p.batch -= 1
	}
	if p.batch > 0 {
		return .None
	}
	return _sync_all(p)
}

@(private)
_flush :: proc(p: ^Pack) -> Error {
	_flush_start(p) or_return
	_drain(p) or_return
	if len(p.runs) > p.opts.max_runs || (p.merge != nil && len(p.runs) > p.opts.max_runs / 2) {
		_merge_step(p, i64(p.opts.mem_budget) * i64(p.opts.merge_fanout) * 2) or_return
		_drain(p) or_return
	}
	return .None
}

@(private)
_flush_start :: proc(p: ^Pack) -> Error {
	_drain(p) or_return
	if p.poisoned {
		return .Io
	}
	wrote := _commit_write(p) or_return
	fl_seq := p.seq - 1 if wrote else p.durable_seq
	for z in p.zeros {
		if z.need > fl_seq {
			if wrote {
				p.fl.kind = .Commit
				_submit(p) or_return
				_drain(p) or_return
			}
			p.force = true
			_commit(p) or_return
			wrote = false
			fl_seq = p.durable_seq
			break
		}
	}
	fl := &p.fl
	i := 0
	for i < len(p.zeros) {
		z := p.zeros[i]
		if z.need > fl_seq {
			i += 1
			continue
		}
		fd, err := _cont_fd(p, z.phys.cont)
		if err == .None {
			append(&fl.zjobs, Zero_Job{fd = fd, off = z.phys.off, len = z.phys.len})
			ci := _cont_index(p, z.phys.cont)
			if !p.conts[ci].busy {
				p.conts[ci].busy = true
				append(&fl.busy, z.phys.cont)
			}
			p.stats.zeroed_bytes += u64(z.phys.len)
		} else if err != .Not_Found {
			return _poison(p, err)
		}
		unordered_remove(&p.zeros, i)
	}
	for &c in p.conts {
		if c.dirty && c.fd >= 0 {
			append(&fl.syncs, c.fd)
			if !c.busy {
				c.busy = true
				append(&fl.busy, c.id)
			}
		}
	}
	for zj in fl.zjobs {
		dup := false
		for fd in fl.syncs {
			if fd == zj.fd {
				dup = true
			}
		}
		if !dup {
			append(&fl.syncs, zj.fd)
		}
	}
	for _, oi in p.open_inodes {
		if oi.dirty && oi.real_fd >= 0 {
			append(&fl.fds, Job_Fd{fd = oi.real_fd})
			oi.dirty = false
			oi.pinned += 1
		}
	}
	for inum in p.ext_dirty {
		pb: prim.Path_Buf
		fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'x', inum), {.Write})
		if err == .Not_Found {
			continue
		}
		if err != .None {
			return _poison(p, err)
		}
		append(&fl.fds, Job_Fd{fd = fd, owned = true})
	}
	clear(&p.ext_dirty)
	fl.run_fd = prim.INVALID_FD
	if p.mem.count > 0 {
		imm := new(Mem, p.allocator)
		if imm == nil {
			return _poison(p, .No_Memory)
		}
		imm^ = p.mem
		_mem_init(&p.mem, p.allocator)
		fl.imm = imm
		fl.drop = len(p.runs) == 0
		fl.run_id = p.next_run
		p.next_run += 1
		pb: prim.Path_Buf
		fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'r', u64(fl.run_id)), {.Write, .Create, .Truncate}, 0o600)
		if err != .None {
			return _poison(p, err)
		}
		fl.run_fd = fd
	}
	clear(&p.dirty)
	p.gen += 1
	_snap_take(p, &fl.snap)
	fl.snap.ck_cont = _active_id(p)
	fl.snap.ck_off = p.buf_base
	fl.snap.ck_seq = p.seq
	fl.has_snap = true
	fl.super_fd = p.super_fd
	fl.root = p.root
	p.log_since_ck = 0
	if cap(p.buf) > p.opts.spill * 2 && len(p.buf) == 0 {
		delete(p.buf)
		p.buf = make([dynamic]u8, p.allocator)
	}
	fl.kind = .Flush
	return _submit(p)
}

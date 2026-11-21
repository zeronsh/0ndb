package pack

import "core:hash/xxhash"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../prim"

open :: proc(p: ^Pack, base: prim.Vfs, root: string, opts := DEFAULT_OPTIONS, allocator := context.allocator) -> Error {
	o := opts
	o.promote_size = clamp(o.promote_size, 4096, MAX_RECORD - MAX_META_REC)
	p^ = {
		base      = base,
		opts      = o,
		allocator = allocator,
		lock_fd   = prim.INVALID_FD,
		super_fd  = prim.INVALID_FD,
		active    = -1,
	}
	r := root
	for len(r) > 1 && r[len(r) - 1] == '/' {
		r = r[:len(r) - 1]
	}
	if len(r) == 0 || len(r) + 32 >= prim.PATH_MAX {
		return .Invalid
	}
	rs, aerr := strings.clone(r, allocator)
	if aerr != nil {
		return .No_Memory
	}
	p.root = rs
	p.conts = make([dynamic]Cont, allocator)
	p.buf = make([dynamic]u8, allocator)
	p.dirty = make([dynamic]u32, allocator)
	p.zeros = make([dynamic]Zero, allocator)
	p.unlinks = make([dynamic]Pending_Unlink, allocator)
	p.waiters = make([dynamic]Waiter, allocator)
	p.fl.fds = make([dynamic]Job_Fd, allocator)
	p.fl.zjobs = make([dynamic]Zero_Job, allocator)
	p.fl.syncs = make([dynamic]prim.Fd, allocator)
	p.fl.busy = make([dynamic]u32, allocator)
	p.fl.run_fd = prim.INVALID_FD
	p.ext_dirty = make([dynamic]u64, allocator)
	p.graveyard = make([dynamic]prim.Fd, allocator)
	p.runs = make([dynamic]^Run, allocator)
	p.handles = make([dynamic]Handle, allocator)
	p.free_handles = make([dynamic]int, allocator)
	p.open_inodes = make(map[u64]^Open_Inode, allocator)
	p.scratch = make([dynamic]u8, allocator)
	p.vbuf = make([dynamic]u8, allocator)
	p.work = make([dynamic]u8, allocator)
	_mem_init(&p.mem, allocator)
	if err := _open(p); err != .None {
		_release(p)
		return err
	}
	return .None
}

close :: proc(p: ^Pack) -> Error {
	err: Error
	if !p.poisoned {
		p.batch = 0
		err = _flush(p)
		if err == .None {
			_fire_waiters(p)
		}
	}
	_release(p)
	return err
}

@(private)
_release :: proc(p: ^Pack) {
	if p.fl.on {
		_job_complete(p, _worker_wait(p))
	}
	_worker_stop(p)
	delete(p.fl.fds)
	delete(p.fl.zjobs)
	delete(p.fl.syncs)
	delete(p.fl.busy)
	if len(p.waiters) > 0 {
		_fail_waiters(p, .Io)
	}
	delete(p.waiters)
	if p.merge != nil {
		_merge_abort(p)
	}
	_compact_reset(p)
	for oi in p.open_inodes {
		o := p.open_inodes[oi]
		if o.real_fd >= 0 {
			prim.close_file(p.base, o.real_fd)
		}
		free(o, p.allocator)
	}
	delete(p.open_inodes)
	for &c in p.conts {
		if c.fd >= 0 {
			prim.close_file(p.base, c.fd)
		}
	}
	for r in p.runs {
		_run_close(p, r)
		free(r, p.allocator)
	}
	delete(p.conts)
	delete(p.runs)
	delete(p.buf)
	delete(p.dirty)
	delete(p.zeros)
	delete(p.unlinks)
	delete(p.ext_dirty)
	for fd in p.graveyard {
		prim.close_file(p.base, fd)
	}
	delete(p.graveyard)
	delete(p.handles)
	delete(p.free_handles)
	delete(p.scratch)
	delete(p.vbuf)
	delete(p.work)
	_mem_destroy(&p.mem)
	if p.super_fd >= 0 {
		prim.close_file(p.base, p.super_fd)
	}
	if p.lock_fd >= 0 {
		prim.close_file(p.base, p.lock_fd)
	}
	if len(p.root) > 0 {
		delete(p.root, p.allocator)
	}
	p^ = {}
	p.lock_fd = prim.INVALID_FD
	p.super_fd = prim.INVALID_FD
	p.active = -1
}

@(private)
_run_close :: proc(p: ^Pack, r: ^Run) {
	if r.fd >= 0 {
		prim.close_file(p.base, r.fd)
		r.fd = prim.INVALID_FD
	}
	if r.root_buf != nil {
		delete(r.root_buf, p.allocator)
		r.root_buf = nil
	}
}

@(private)
_open :: proc(p: ^Pack) -> Error {
	prim.mkdir_all(p.base, p.root) or_return
	pb: prim.Path_Buf
	n := copy(pb[:], p.root)
	n += copy(pb[n:], "/LOCK")
	p.lock_fd = prim.lock_file(p.base, string(pb[:n])) or_return
	n = copy(pb[:], p.root)
	n += copy(pb[n:], "/super")
	super_path := string(pb[:n])
	fresh := false
	fd, err := prim.open_file(p.base, super_path, {.Write})
	if err == .Not_Found {
		fd, err = prim.open_file(p.base, super_path, {.Write, .Create, .Exclusive}, 0o600)
		fresh = true
	}
	if err != .None {
		return err
	}
	p.super_fd = fd
	sb: Super
	sb.runs.allocator = context.temp_allocator
	sb.lives.allocator = context.temp_allocator
	if fresh || !_super_read(p, &sb) {
		size, _ := prim.file_size(p.base, fd)
		if !fresh && size > 0 {
			return .Io
		}
		return _init_fresh(p)
	}
	if sb.version != VERSION {
		return .Unsupported
	}
	p.gen = sb.gen
	p.ck_cont = sb.ck_cont
	p.ck_off = sb.ck_off
	p.ck_seq = sb.ck_seq
	p.next_ino = sb.next_ino
	p.next_cont = sb.next_cont
	p.next_run = sb.next_run
	p.compacting = sb.compacting
	return _recover(p, &sb)
}

@(private)
_init_fresh :: proc(p: ^Pack) -> Error {
	p.next_ino = ROOT_INO + 1
	p.next_cont = 1
	p.next_run = 1
	p.seq = 1
	p.hh = 1
	p.dh = 1
	idx := _new_container(p) or_return
	p.active = idx
	p.buf_base = CONT_HDR
	p.group_start = CONT_HDR
	p.ck_cont = p.conts[idx].id
	p.ck_off = CONT_HDR
	p.ck_seq = 1
	p.last_cont = p.ck_cont
	p.last_start = CONT_HDR
	_super_write(p) or_return
	return _sync_root(p)
}

@(private)
_recover :: proc(p: ^Pack, sb: ^Super) -> Error {
	d: prim.Dir
	prim.dir_open(p.base, &d, p.root, context.temp_allocator) or_return
	cont_ids := make([dynamic]u32, context.temp_allocator)
	run_ids := make([dynamic]u32, context.temp_allocator)
	ext_ids := make([dynamic]u64, context.temp_allocator)
	for {
		ent, ok, derr := prim.dir_next(p.base, &d)
		if derr != .None {
			prim.dir_close(p.base, &d)
			return derr
		}
		if !ok {
			break
		}
		prefix, id, pok := _parse_phys_name(ent.name)
		if !pok {
			continue
		}
		switch prefix {
		case 'c':
			append(&cont_ids, u32(id))
		case 'r':
			append(&run_ids, u32(id))
		case 'x':
			append(&ext_ids, id)
		}
	}
	prim.dir_close(p.base, &d)
	slice.sort(cont_ids[:])
	for id in cont_ids {
		p.next_cont = max(p.next_cont, id + 1)
	}
	for id in run_ids {
		p.next_run = max(p.next_run, id + 1)
	}
	for id in cont_ids {
		c := Cont {
			id = id,
			fd = prim.INVALID_FD,
		}
		for l in sb.lives {
			if l.id == id {
				c.live = l.live
			}
		}
		append(&p.conts, c)
	}
	removed_any := false
	for id in run_ids {
		listed := false
		for r in sb.runs {
			if r.id == id {
				listed = true
			}
		}
		if !listed {
			pb: prim.Path_Buf
			prim.remove(p.base, _phys_path(p, &pb, 'r', u64(id)))
			removed_any = true
		}
	}
	for r in sb.runs {
		run := r
		pb: prim.Path_Buf
		fd, err := prim.open_file(p.base, _phys_path(p, &pb, 'r', u64(r.id)))
		if err != .None {
			return .Io
		}
		run.fd = fd
		nr := new(Run, p.allocator)
		nr^ = run
		append(&p.runs, nr)
		if e := _run_load(p, nr); e != .None {
			return e
		}
	}
	if _cont_index(p, p.ck_cont) < 0 {
		return .Io
	}
	_replay(p) or_return
	for i := len(p.conts) - 1; i >= 0; i -= 1 {
		if p.conts[i].id > _active_id(p) {
			pb: prim.Path_Buf
			if p.conts[i].fd >= 0 {
				prim.close_file(p.base, p.conts[i].fd)
			}
			prim.remove(p.base, _phys_path(p, &pb, 'c', u64(p.conts[i].id)))
			ordered_remove(&p.conts, i)
			removed_any = true
		}
	}
	for i in 0 ..< len(p.conts) {
		if p.conts[i].id == _active_id(p) {
			p.active = i
		}
	}
	if removed_any {
		_sync_root(p) or_return
	}
	if len(p.zeros) > 0 {
		p.force = true
		_commit(p) or_return
		p.recovering = false
		for &z in p.zeros {
			z.need = 0
		}
		_apply_zeros(p) or_return
		_sync_dirty_conts(p) or_return
	}
	p.recovering = false
	if p.compacting != 0 && _cont_index(p, p.compacting) < 0 {
		p.compacting = 0
	}
	_reap_orphans(p) or_return
	for id in ext_ids {
		ino: Inode
		found := _inode_load(p, id, &ino) or_return
		if !found || ino.kind != .External {
			pb: prim.Path_Buf
			prim.remove(p.base, _phys_path(p, &pb, 'x', id))
		}
	}
	return .None
}

@(private)
Log_Reader :: struct {
	p:     ^Pack,
	own:   bool,
	fd:    prim.Fd,
	size:  i64,
	buf:   [dynamic]u8,
	start: i64,
}

@(private)
_lr_get :: proc(lr: ^Log_Reader, off: i64, n: int) -> ([]u8, bool) {
	if n < 0 || off < 0 || off + i64(n) > lr.size {
		return nil, false
	}
	if off >= lr.start && off + i64(n) <= lr.start + i64(len(lr.buf)) {
		return lr.buf[off - lr.start:][:n], true
	}
	want := int(min(max(i64(n), 1 << 20), lr.size - off))
	if resize(&lr.buf, want) != nil {
		return nil, false
	}
	got, err := prim.read_at(lr.p.base, lr.fd, lr.buf[:], off)
	if err != .None || got < n {
		return nil, false
	}
	resize(&lr.buf, got)
	lr.start = off
	return lr.buf[:n], true
}

@(private)
Group :: struct {
	cont:  u32,
	start: i64,
	end:   i64,
	seq:   u64,
	dh:    u64,
	next:  u32,
}

MAX_RECORD :: 16 * 1024 * 1024

@(private)
_max_rec :: proc "contextless" (p: ^Pack) -> u32 {
	return MAX_RECORD
}

@(private)
_parse_group :: proc(p: ^Pack, lr: ^Log_Reader, cont: u32, off: i64, seq: u64) -> (g: Group, ok: bool) {
	hh := seq
	nrec := 0
	pos := off
	g = Group {
		cont  = cont,
		start = off,
		seq   = seq,
	}
	for {
		h := _lr_get(lr, pos, REC_HDR) or_return
		ln := prim.get_u32le(h[0:4])
		kind := h[4]
		if ln > _max_rec(p) {
			return g, false
		}
		rec := _lr_get(lr, pos, REC_HDR + int(ln)) or_return
		switch kind {
		case R_DATA:
			_, n1 := prim.get_uvarint(rec[REC_HDR:])
			if n1 <= 0 {
				return g, false
			}
			_, n2 := prim.get_uvarint(rec[REC_HDR + n1:])
			if n2 <= 0 {
				return g, false
			}
			hh = xxhash.XXH3_64_with_seed(rec[:REC_HDR + n1 + n2], hh)
		case R_PUT, R_DEL:
			hh = xxhash.XXH3_64_with_seed(rec, hh)
		case R_NEXT:
			if ln != 4 {
				return g, false
			}
			g.next = prim.get_u32le(rec[REC_HDR:])
			hh = xxhash.XXH3_64_with_seed(rec, hh)
		case R_COMMIT:
			if ln != COMMIT_BODY {
				return g, false
			}
			if prim.get_u64le(rec[33:41]) != xxhash.XXH3_64_with_seed(rec[:33], COMMIT_SEED) {
				return g, false
			}
			if prim.get_u64le(rec[5:13]) != seq || int(prim.get_u32le(rec[13:17])) != nrec || prim.get_u64le(rec[17:25]) != hh {
				return g, false
			}
			g.dh = prim.get_u64le(rec[25:33])
			g.end = pos + REC_HDR + COMMIT_BODY
			return g, true
		case:
			return g, false
		}
		nrec += 1
		pos += REC_HDR + i64(ln)
	}
}

@(private)
_group_data_ok :: proc(p: ^Pack, lr: ^Log_Reader, g: Group) -> bool {
	dh := g.seq
	pos := g.start
	for pos < g.end {
		h, ok := _lr_get(lr, pos, REC_HDR)
		if !ok {
			return false
		}
		ln := prim.get_u32le(h[0:4])
		rec, rok := _lr_get(lr, pos, REC_HDR + int(ln))
		if !rok {
			return false
		}
		if rec[4] == R_DATA {
			_, n1 := prim.get_uvarint(rec[REC_HDR:])
			_, n2 := prim.get_uvarint(rec[REC_HDR + n1:])
			dh = xxhash.XXH3_64_with_seed(rec[REC_HDR + n1 + n2:], dh)
		}
		pos += REC_HDR + i64(ln)
	}
	return dh == g.dh
}

@(private)
_open_lr :: proc(p: ^Pack, lr: ^Log_Reader, cont: u32, own := false) -> bool {
	if lr.own && lr.fd >= 0 {
		prim.close_file(p.base, lr.fd)
		lr.fd = prim.INVALID_FD
	}
	fd: prim.Fd
	err: Error
	if own {
		pb: prim.Path_Buf
		fd, err = prim.open_file(p.base, _phys_path(p, &pb, 'c', u64(cont)))
	} else {
		fd, err = _cont_fd(p, cont)
	}
	if err != .None {
		return false
	}
	size, serr := prim.file_size(p.base, fd)
	if serr != .None {
		if own {
			prim.close_file(p.base, fd)
		}
		return false
	}
	ci := _cont_index(p, cont)
	p.conts[ci].size = size
	clear(&lr.buf)
	lr^ = {
		p    = p,
		own  = own,
		fd   = fd,
		size = size,
		buf  = lr.buf,
	}
	if size < CONT_HDR {
		return false
	}
	h, ok := _lr_get(lr, 0, CONT_HDR)
	if !ok || prim.get_u64le(h[0:8]) != CONT_MAGIC || prim.get_u32le(h[8:12]) != VERSION || prim.get_u32le(h[12:16]) != cont {
		return false
	}
	return prim.get_u64le(h[CONT_HDR - 8:]) == xxhash.XXH3_64_with_seed(h[:CONT_HDR - 8], CONT_MAGIC)
}

@(private)
_replay :: proc(p: ^Pack) -> Error {
	p.recovering = true
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	lr: Log_Reader
	lr.buf = make([dynamic]u8, p.allocator)
	defer delete(lr.buf)
	groups := make([dynamic]Group, p.allocator)
	defer delete(groups)
	cont := p.ck_cont
	off := p.ck_off
	seq := p.ck_seq
	if !_open_lr(p, &lr, cont) {
		return .Io
	}
	for {
		g, ok := _parse_group(p, &lr, cont, off, seq)
		if !ok {
			break
		}
		append(&groups, g)
		seq += 1
		if g.next != 0 {
			if _cont_index(p, g.next) < 0 || !_open_lr(p, &lr, g.next) {
				pop(&groups)
				seq -= 1
				break
			}
			cont = g.next
			off = CONT_HDR
		} else {
			off = g.end
		}
	}
	if len(groups) > 0 {
		last := groups[len(groups) - 1]
		_open_lr(p, &lr, last.cont)
		if !_group_data_ok(p, &lr, last) {
			pop(&groups)
			seq -= 1
		}
	}
	end_cont := p.ck_cont
	end_off := p.ck_off
	p.last_cont = p.ck_cont
	p.last_start = p.ck_off
	if len(groups) > 0 {
		last := groups[len(groups) - 1]
		p.last_cont = last.cont
		p.last_start = last.start
		if last.next != 0 {
			end_cont = last.next
			end_off = CONT_HDR
		} else {
			end_cont = last.cont
			end_off = last.end
		}
	}
	datas := make([dynamic]Replay_Data, p.allocator)
	defer delete(datas)
	cur := u32(0)
	for g in groups {
		virtual.arena_free_all(&arena)
		if g.cont != cur {
			if !_open_lr(p, &lr, g.cont) {
				return .Io
			}
			cur = g.cont
		}
		clear(&datas)
		pos := g.start
		for pos < g.end {
			h, _ := _lr_get(&lr, pos, REC_HDR)
			ln := prim.get_u32le(h[0:4])
			rec, _ := _lr_get(&lr, pos, REC_HDR + int(ln))
			body := rec[REC_HDR:]
			switch rec[4] {
			case R_DATA:
				inum, n1 := prim.get_uvarint(body)
				_, n2 := prim.get_uvarint(body[n1:])
				append(&datas, Replay_Data{inum = inum, phys = Phys{cont = g.cont, off = pos + REC_HDR + i64(n1 + n2), len = i64(ln) - i64(n1 + n2)}})
			case R_PUT, R_DEL:
				kl, kn := prim.get_uvarint(body)
				if kn <= 0 || kl > u64(len(body) - kn) {
					return .Io
				}
				key := body[kn:][:kl]
				val := body[kn + int(kl):]
				kc := make([]u8, len(key), context.temp_allocator)
				copy(kc, key)
				vc := make([]u8, len(val), context.temp_allocator)
				copy(vc, val)
				_replay_put(p, kc, vc, rec[4] == R_DEL) or_return
			}
			pos += REC_HDR + i64(ln)
		}
		for d in datas {
			ino: Inode
			found := _inode_load(p, d.inum, &ino) or_return
			refs, garbage: Phys_List
			if found {
				_phys_of(&ino, &refs)
			}
			_phys_diff([]Phys{d.phys}, refs.a[:refs.n], &garbage)
			for ph in garbage.a[:garbage.n] {
				_defer_zero(p, ph, false)
			}
		}
		p.stats.replayed += 1
	}
	ci := _cont_index(p, end_cont)
	if ci < 0 {
		return .Io
	}
	p.active = ci
	fd := _cont_fd(p, end_cont) or_return
	size := prim.file_size(p.base, fd) or_return
	if size != end_off {
		if e := prim.truncate(p.base, fd, end_off); e != .None {
			return e
		}
		_sync(p, fd) or_return
	}
	p.conts[ci].size = end_off
	p.buf_base = end_off
	p.group_start = end_off
	p.seq = seq
	p.durable_seq = seq - 1
	p.hh = seq
	p.dh = seq
	return .None
}

@(private)
Replay_Data :: struct {
	inum: u64,
	phys: Phys,
}

@(private)
_replay_put :: proc(p: ^Pack, key: []u8, val: []u8, tomb: bool) -> Error {
	if len(key) == 9 && key[0] == K_INODE {
		inum := _get_be64(key[1:9])
		p.next_ino = max(p.next_ino, inum + 1)
		old: Inode
		has_old := _inode_load(p, inum, &old) or_return
		new: Inode
		has_new := !tomb && _inode_decode(val, &new)
		if !tomb && !has_new {
			return .Io
		}
		olds, news, removed, added: Phys_List
		if has_old {
			_phys_of(&old, &olds)
		}
		if has_new {
			_phys_of(&new, &news)
		}
		_phys_diff(olds.a[:olds.n], news.a[:news.n], &removed)
		_phys_diff(news.a[:news.n], olds.a[:olds.n], &added)
		for ph in removed.a[:removed.n] {
			_live_add(p, ph, -1)
			_defer_zero(p, ph, false)
		}
		for ph in added.a[:added.n] {
			_live_add(p, ph, 1)
		}
	} else if len(key) == 21 && key[0] == K_STALE && tomb {
		if f, err := _get(p, key, &p.vbuf); err == .None && f {
			foff, n1 := prim.get_uvarint(p.vbuf[:])
			ln, n2 := prim.get_uvarint(p.vbuf[max(n1, 0):])
			if n1 > 0 && n2 > 0 {
				_ = foff
				cont := u32(key[9]) << 24 | u32(key[10]) << 16 | u32(key[11]) << 8 | u32(key[12])
				_defer_zero(p, Phys{cont = cont, off = i64(_get_be64(key[13:21])), len = i64(ln)}, false)
			}
		}
	} else if len(key) > 9 && key[0] == K_DIR && !tomb {
		inum, n := prim.get_uvarint(val)
		if n > 0 {
			p.next_ino = max(p.next_ino, inum + 1)
		}
	}
	return _put(p, key, val, tomb)
}

@(private)
_reap_orphans :: proc(p: ^Pack) -> Error {
	lo := []u8{K_ORPHAN}
	hi := []u8{K_ORPHAN + 1}
	list := make([dynamic]u64, context.temp_allocator)
	it: Merge_Iter
	_miter_init(&it, p, lo, hi) or_return
	defer _miter_destroy(&it)
	for {
		key, _, ok := _miter_next(&it)
		if !ok {
			break
		}
		if len(key) == 9 {
			append(&list, _get_be64(key[1:9]))
		}
	}
	if it.err != .None {
		return it.err
	}
	if len(list) == 0 {
		return .None
	}
	for inum in list {
		_destroy_inode(p, inum, true) or_return
	}
	return _sync_all(p)
}

@(private)
_destroy_inode :: proc(p: ^Pack, inum: u64, orphan: bool) -> Error {
	ino: Inode
	found := _inode_load(p, inum, &ino) or_return
	kb: [16]u8
	if found {
		if ino.kind == .External {
			append(&p.unlinks, Pending_Unlink{inum = inum, need = p.seq})
		}
		_inode_store(p, inum, &ino, nil) or_return
	}
	if !orphan {
		return .None
	}
	return _put(p, _ikey(kb[:], K_ORPHAN, inum), nil, true)
}

package pack

import "../prim"

VFD_BASE :: prim.Fd(0x4000_0000)
@(private)
DIR_MARK :: prim.Fd(0x7fff_fff0)
@(private)
DIR_BATCH :: 64

@(rodata)
PACK_PROCS := prim.Vfs_Procs {
	open       = _v_open,
	close      = _v_close,
	read_at    = _v_read_at,
	write_at   = _v_write_at,
	datasync   = _v_sync,
	fullsync   = _v_sync,
	truncate   = _v_truncate,
	punch_hole = _v_punch_hole,
	lock       = _v_lock,
	fstat      = _v_fstat,
	stat       = _v_stat,
	rename     = _v_rename,
	unlink     = _v_unlink,
	rmdir      = _v_rmdir,
	mkdir      = _v_mkdir,
	symlink    = _v_symlink,
	readlink   = _v_readlink,
	fchmod     = _v_fchmod,
	set_times  = _v_set_times,
	dir_open   = _v_dir_open,
	dir_next   = _v_dir_next,
	dir_close  = _v_dir_close,
	caps       = _v_caps,
}

@(private)
_v_caps :: proc(data: rawptr, fd: prim.Fd) -> prim.Vfs_Caps {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.file_caps(p.base, fd)
	}
	h := _handle(p, fd)
	if h == nil {
		return {}
	}
	if h.dir || h.oi.ino.kind == .External {
		return {.Durable_Dir_Ops_With_Data}
	}
	return {.Durable_Dir_Ops_With_Data, .Atomic_Group_Commit}
}

vfs :: proc(p: ^Pack) -> prim.Vfs {
	return prim.Vfs{procs = &PACK_PROCS, data = p}
}

@(private)
_now :: proc(p: ^Pack) -> i64 {
	return prim.clock_wall_ns(p.opts.clock)
}

@(private)
_rel :: proc "contextless" (p: ^Pack, path: string) -> (rel: string, inside: bool) {
	r := p.root
	if len(path) < len(r) || path[:len(r)] != r {
		return "", false
	}
	if len(path) == len(r) {
		return "", true
	}
	if path[len(r)] != '/' {
		return "", false
	}
	return path[len(r) + 1:], true
}

@(private)
_next_component :: proc "contextless" (s: string, i: ^int) -> (string, bool) {
	for i^ < len(s) && s[i^] == '/' {
		i^ += 1
	}
	if i^ >= len(s) {
		return "", false
	}
	j := i^
	for j < len(s) && s[j] != '/' {
		j += 1
	}
	c := s[i^:j]
	i^ = j
	return c, true
}

@(private)
_dval :: proc "contextless" (buf: []u8, inum: u64, kind: Kind) -> []u8 {
	n := prim.put_uvarint(buf, inum)
	buf[n] = u8(kind)
	return buf[:n + 1]
}

@(private)
_lookup :: proc(p: ^Pack, parent: u64, name: string) -> (inum: u64, kind: Kind, found: bool, err: Error) {
	if len(name) > MAX_NAME {
		return 0, .None, false, .Name_Too_Long
	}
	h := (parent * 0x9e37_79b9_7f4a_7c15 ~ u64(len(name))) % DCACHE
	if len(name) > 0 {
		h = (h + u64(name[0]) + u64(name[len(name) - 1]) * 31) % DCACHE
	}
	e := &p.dcache[h]
	if e.ino != 0 && e.parent == parent && e.nlen == len(name) && string(e.name[:e.nlen]) == name {
		return e.ino, .Dir, true, .None
	}
	kb: [MAX_KEY]u8
	f := _get(p, _dkey(kb[:], parent, name), &p.vbuf) or_return
	if !f {
		return 0, .None, false, .None
	}
	v, n := prim.get_uvarint(p.vbuf[:])
	if n <= 0 || n >= len(p.vbuf) {
		return 0, .None, false, .Io
	}
	kind = Kind(p.vbuf[n])
	if kind == .Dir {
		e.parent = parent
		e.ino = v
		e.nlen = copy(e.name[:], name)
	}
	return v, kind, true, .None
}

@(private)
_dcache_clear :: proc "contextless" (p: ^Pack) {
	for &e in p.dcache {
		e.ino = 0
	}
}

@(private)
_walk :: proc(p: ^Pack, rel: string) -> (parent: u64, name: string, err: Error) {
	stack: [64]u64
	depth := 0
	cur := ROOT_INO
	i := 0
	comp, ok := _next_component(rel, &i)
	if !ok {
		return 0, "", .None
	}
	for {
		nxt, more := _next_component(rel, &i)
		if !more {
			if comp == ".." {
				return 0, "", .Invalid
			}
			if comp == "." {
				if depth == 0 && cur == ROOT_INO {
					return 0, "", .None
				}
				return 0, "", .Invalid
			}
			return cur, comp, .None
		}
		switch comp {
		case ".":
		case "..":
			if depth > 0 {
				depth -= 1
				cur = stack[depth]
			}
		case:
			inum, kind, found := _lookup(p, cur, comp) or_return
			if !found {
				return 0, "", .Not_Found
			}
			if kind != .Dir {
				return 0, "", .Not_Dir
			}
			if depth >= len(stack) {
				return 0, "", .Name_Too_Long
			}
			stack[depth] = cur
			depth += 1
			cur = inum
		}
		comp = nxt
	}
}

@(private)
_handle :: proc "contextless" (p: ^Pack, fd: prim.Fd) -> ^Handle {
	i := int(fd - VFD_BASE)
	if fd < VFD_BASE || i >= len(p.handles) || !p.handles[i].used {
		return nil
	}
	return &p.handles[i]
}

@(private)
_new_handle :: proc(p: ^Pack) -> (int, Error) {
	if n := len(p.free_handles); n > 0 {
		i := p.free_handles[n - 1]
		pop(&p.free_handles)
		return i, .None
	}
	if len(p.handles) >= int(DIR_MARK - VFD_BASE) {
		return -1, .Too_Many_Files
	}
	append(&p.handles, Handle{})
	return len(p.handles) - 1, .None
}

@(private)
_oi_acquire :: proc(p: ^Pack, inum: u64) -> (oi: ^Open_Inode, err: Error) {
	if o, ok := p.open_inodes[inum]; ok {
		o.refs += 1
		return o, .None
	}
	o := new(Open_Inode, p.allocator)
	if o == nil {
		return nil, .No_Memory
	}
	o.inum = inum
	o.real_fd = prim.INVALID_FD
	found, lerr := _inode_load(p, inum, &o.ino)
	if lerr != .None || !found {
		free(o, p.allocator)
		return nil, lerr if lerr != .None else .Io
	}
	if o.ino.kind == .External {
		pb: prim.Path_Buf
		fd, ferr := prim.open_file(p.base, _phys_path(p, &pb, 'x', inum), {.Write})
		if ferr != .None {
			free(o, p.allocator)
			return nil, .Io
		}
		o.real_fd = fd
	}
	o.refs = 1
	p.open_inodes[inum] = o
	return o, .None
}

@(private)
_oi_release :: proc(p: ^Pack, oi: ^Open_Inode) -> Error {
	oi.refs -= 1
	if oi.refs > 0 {
		return .None
	}
	err: Error
	if oi.real_fd >= 0 {
		if oi.pinned > 0 && p.fl.on {
			for &j in p.fl.fds {
				if j.fd == oi.real_fd {
					j.owned = true
				}
			}
		} else {
			prim.close_file(p.base, oi.real_fd)
		}
		oi.real_fd = prim.INVALID_FD
	}
	inum := oi.inum
	unlinked := oi.unlinked
	if oi.dirty && !unlinked {
		append(&p.ext_dirty, inum)
	}
	delete_key(&p.open_inodes, inum)
	free(oi, p.allocator)
	if unlinked {
		err = _destroy_inode(p, inum, true)
		if err == .None {
			err = _maybe_flush(p)
		}
	}
	return err
}

@(private)
_maybe_flush :: proc(p: ^Pack) -> Error {
	if !_over_budget(p, 1) {
		return .None
	}
	if !_async(p) {
		return _flush(p)
	}
	if p.fl.on {
		p.pressure = true
		return .None
	}
	return _flush_start(p)
}

@(private)
_admit :: proc(p: ^Pack) -> Error {
	if p.poisoned {
		return .Io
	}
	if _async(p) && p.fl.on && _over_budget(p, 4) {
		p.pressure = true
		return .Would_Block
	}
	return .None
}

pressure :: proc "contextless" (p: ^Pack) -> bool {
	return p.pressure
}

@(private)
_create :: proc(p: ^Pack, parent: u64, name: string, ino: ^Inode) -> (inum: u64, err: Error) {
	if len(name) > MAX_NAME {
		return 0, .Name_Too_Long
	}
	inum = p.next_ino
	p.next_ino += 1
	_inode_store(p, inum, nil, ino) or_return
	kb: [MAX_KEY]u8
	vb: [16]u8
	_put(p, _dkey(kb[:], parent, name), _dval(vb[:], inum, ino.kind), false) or_return
	return inum, .None
}

@(private)
_v_open :: proc(data: rawptr, path: string, flags: prim.Open_Flags, mode: u32) -> (prim.Fd, Error) {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.open_file(p.base, path, flags, mode)
	}
	if p.poisoned {
		return prim.INVALID_FD, .Io
	}
	if .Create in flags || .Truncate in flags {
		if e := _admit(p); e != .None {
			return prim.INVALID_FD, e
		}
	}
	return _open_rel(p, path, rel, flags, mode, 0)
}

@(private)
_open_rel :: proc(p: ^Pack, path: string, rel: string, flags: prim.Open_Flags, mode: u32, depth: int) -> (ofd: prim.Fd, rerr: Error) {
	parent, name, werr := _walk(p, rel)
	if werr != .None {
		return prim.INVALID_FD, werr
	}
	inum := ROOT_INO
	kind := Kind.Dir
	found := true
	if parent != 0 {
		ok: bool
		lerr: Error
		inum, kind, ok, lerr = _lookup(p, parent, name)
		if lerr != .None {
			return prim.INVALID_FD, lerr
		}
		found = ok
	}
	if found && .Create in flags && .Exclusive in flags {
		return prim.INVALID_FD, .Exists
	}
	if found && kind == .Symlink {
		return _follow(p, path, inum, flags, mode, depth)
	}
	if found && kind == .Dir {
		if .Write in flags {
			return prim.INVALID_FD, .Is_Dir
		}
		idx := _new_handle(p) or_return
		p.handles[idx] = Handle{used = true, dir = true, inum = inum}
		return VFD_BASE + prim.Fd(idx), .None
	}
	if .Directory in flags {
		return prim.INVALID_FD, .Not_Found if !found else .Not_Dir
	}
	if !found {
		if .Create not_in flags {
			return prim.INVALID_FD, .Not_Found
		}
		ino: Inode
		ino.kind = .File
		ino.mode = 0o100000 | (mode & 0o7777)
		ino.mtime = _now(p)
		n, cerr := _create(p, parent, name, &ino)
		if cerr != .None {
			return prim.INVALID_FD, cerr
		}
		inum = n
	}
	oi, oerr := _oi_acquire(p, inum)
	if oerr != .None {
		return prim.INVALID_FD, oerr
	}
	idx, herr := _new_handle(p)
	if herr != .None {
		_oi_release(p, oi)
		return prim.INVALID_FD, herr
	}
	p.handles[idx] = Handle{used = true, write = .Write in flags, oi = oi, inum = inum}
	fd := VFD_BASE + prim.Fd(idx)
	if found && .Truncate in flags && .Write in flags {
		if e := _truncate(p, &p.handles[idx], 0); e != .None {
			_v_close(p, fd)
			return prim.INVALID_FD, e
		}
	}
	if e := _maybe_flush(p); e != .None {
		_v_close(p, fd)
		return prim.INVALID_FD, e
	}
	return fd, .None
}

@(private)
_follow :: proc(p: ^Pack, path: string, inum: u64, flags: prim.Open_Flags, mode: u32, depth: int) -> (prim.Fd, Error) {
	if depth >= 8 {
		return prim.INVALID_FD, .Invalid
	}
	target, terr := _symlink_target(p, path, inum)
	if terr != .None {
		return prim.INVALID_FD, terr
	}
	rel, inside := _rel(p, target)
	if !inside {
		return prim.open_file(p.base, target, flags, mode)
	}
	return _open_rel(p, target, rel, flags, mode, depth + 1)
}

@(private)
_symlink_target :: proc(p: ^Pack, path: string, inum: u64) -> (target: string, terr: Error) {
	ino: Inode
	found := _inode_load(p, inum, &ino) or_return
	if !found || ino.kind != .Symlink {
		return "", .Io
	}
	t := string(ino.target[:ino.tlen])
	if prim.is_abs(t) || (len(t) > 0 && (t[0] == '/' || t[0] == '\\')) {
		out := make([]u8, len(t), context.temp_allocator)
		copy(out, t)
		return string(out), .None
	}
	dir := prim.dir_name(path)
	out := make([]u8, len(dir) + 1 + len(t), context.temp_allocator)
	n := copy(out, dir)
	out[n] = '/'
	copy(out[n + 1:], t)
	return string(out), .None
}

@(private)
_v_close :: proc(data: rawptr, fd: prim.Fd) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.close_file(p.base, fd)
	}
	h := _handle(p, fd)
	if h == nil {
		return .Invalid
	}
	idx := int(fd - VFD_BASE)
	oi := h.oi
	if oi != nil && oi.locked == idx + 1 {
		oi.locked = 0
	}
	p.handles[idx] = {}
	append(&p.free_handles, idx)
	if oi != nil {
		return _oi_release(p, oi)
	}
	return .None
}

@(private)
_v_read_at :: proc(data: rawptr, fd: prim.Fd, buf: []u8, off: i64) -> (int, Error) {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.read_at(p.base, fd, buf, off)
	}
	h := _handle(p, fd)
	if h == nil || off < 0 {
		return 0, .Invalid
	}
	if h.dir {
		return 0, .Is_Dir
	}
	oi := h.oi
	if oi.ino.kind == .External {
		return prim.read_at(p.base, oi.real_fd, buf, off)
	}
	if oi.ino.kind != .File {
		return 0, .Io
	}
	if off >= oi.ino.size {
		return 0, .None
	}
	n := int(min(i64(len(buf)), oi.ino.size - off))
	out := buf[:n]
	end := off + i64(n)
	pos := off
	for e in oi.ino.ext[:oi.ino.n] {
		e_end := e.off + e.len
		if e_end <= off || e.off >= end {
			continue
		}
		lo := max(e.off, off)
		hi := min(e_end, end)
		if lo > pos {
			_zero(out[pos - off:lo - off])
		}
		ph := Phys{cont = e.cont, off = e.coff + (lo - e.off), len = hi - lo}
		if err := _phys_read(p, ph, out[lo - off:hi - off]); err != .None {
			return 0, err
		}
		pos = hi
	}
	if pos < end {
		_zero(out[pos - off:])
	}
	return n, .None
}

@(private)
_zero :: proc "contextless" (b: []u8) {
	for &x in b {
		x = 0
	}
}

@(private)
_v_write_at :: proc(data: rawptr, fd: prim.Fd, src: []u8, off: i64) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.write_at(p.base, fd, src, off)
	}
	h := _handle(p, fd)
	if h == nil || off < 0 || !h.write || h.dir {
		return .Invalid
	}
	_admit(p) or_return
	if len(src) == 0 {
		return .None
	}
	oi := h.oi
	if oi.ino.kind == .File && off + i64(len(src)) > p.opts.promote_size {
		_promote(p, oi) or_return
	}
	if oi.ino.kind == .External {
		before := _ext_before(p, oi) or_return
		oi.dirty = true
		prim.write_at(p.base, oi.real_fd, src, off) or_return
		_pend_note(p, oi.inum, before, max(before, off + i64(len(src))))
		return .None
	}
	old := oi.ino
	_pend_note(p, oi.inum, old.size, max(old.size, off + i64(len(src))))
	ph := _log_data(p, oi.inum, off, src) or_return
	nw := &oi.ino
	scratch: Phys_List
	_ext_remove(nw, off, off + i64(len(src)), &scratch)
	if !_ext_insert(nw, Extent{off = off, len = i64(len(src)), cont = ph.cont, coff = ph.off}) {
		oi.ino = old
		return .Io
	}
	nw.size = max(nw.size, off + i64(len(src)))
	nw.mtime = _now(p)
	if nw.n > MAX_EXTENTS {
		if e := _defrag(p, oi, MAX_EXTENTS * 3 / 4); e != .None {
			oi.ino = old
			return e
		}
	}
	_inode_store(p, oi.inum, &old, nw) or_return
	return _maybe_flush(p)
}

@(private)
_defrag :: proc(p: ^Pack, oi: ^Open_Inode, keep: int) -> Error {
	ino := &oi.ino
	for ino.n > max(keep, 1) {
		best, best_w := -1, 0
		best_cost: i64
		for i in 0 ..< ino.n - 1 {
			for w in 2 ..= min(ino.n - i, MAX_EXTENTS) {
				last := ino.ext[i + w - 1]
				cost := last.off + last.len - ino.ext[i].off
				if best < 0 || cost * i64(best_w - 1) < best_cost * i64(w - 1) {
					best, best_w, best_cost = i, w, cost
				}
			}
		}
		if best < 0 {
			return .None
		}
		from := ino.ext[best].off
		to := from + best_cost
		resize(&p.work, int(to - from))
		buf := p.work[:]
		pos := from
		for e in ino.ext[best:best + best_w] {
			if e.off > pos {
				_zero(buf[pos - from:e.off - from])
			}
			_phys_read(p, Phys{cont = e.cont, off = e.coff, len = e.len}, buf[e.off - from:][:e.len]) or_return
			pos = e.off + e.len
		}
		ph := _log_data(p, oi.inum, from, buf) or_return
		scratch: Phys_List
		_ext_remove(ino, from, to, &scratch)
		if !_ext_insert(ino, Extent{off = from, len = to - from, cont = ph.cont, coff = ph.off}) {
			return .Io
		}
	}
	return .None
}

@(private)
_promote :: proc(p: ^Pack, oi: ^Open_Inode) -> Error {
	pb: prim.Path_Buf
	path := _phys_path(p, &pb, 'x', oi.inum)
	fd := prim.open_file(p.base, path, {.Write, .Create, .Truncate}, 0o600) or_return
	ok := false
	defer if !ok {
		prim.close_file(p.base, fd)
		prim.remove(p.base, path)
	}
	for e in oi.ino.ext[:oi.ino.n] {
		buf := make([]u8, int(e.len), context.temp_allocator)
		_phys_read(p, Phys{cont = e.cont, off = e.coff, len = e.len}, buf) or_return
		prim.write_at(p.base, fd, buf, e.off) or_return
	}
	prim.truncate(p.base, fd, oi.ino.size) or_return
	old := oi.ino
	oi.ino.kind = .External
	oi.ino.n = 0
	oi.ino.size = 0
	_inode_store(p, oi.inum, &old, &oi.ino) or_return
	oi.real_fd = fd
	oi.dirty = true
	p.dirsync_pending = true
	ok = true
	p.stats.promotions += 1
	return .None
}

@(private)
_truncate :: proc(p: ^Pack, h: ^Handle, size: i64) -> Error {
	oi := h.oi
	if oi.ino.kind == .File && size > p.opts.promote_size {
		_promote(p, oi) or_return
	}
	if oi.ino.kind == .External {
		before := _ext_before(p, oi) or_return
		oi.dirty = true
		prim.truncate(p.base, oi.real_fd, size) or_return
		_pend_note(p, oi.inum, before, size)
		return .None
	}
	if size == oi.ino.size {
		return .None
	}
	old := oi.ino
	_pend_note(p, oi.inum, old.size, size)
	scratch: Phys_List
	_ext_remove(&oi.ino, size, max(i64), &scratch)
	oi.ino.size = size
	oi.ino.mtime = _now(p)
	return _inode_store(p, oi.inum, &old, &oi.ino)
}

@(private)
_v_truncate :: proc(data: rawptr, fd: prim.Fd, size: i64) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.truncate(p.base, fd, size)
	}
	h := _handle(p, fd)
	if h == nil || size < 0 || !h.write || h.dir {
		return .Invalid
	}
	_admit(p) or_return
	_truncate(p, h, size) or_return
	return _maybe_flush(p)
}

@(private)
_v_punch_hole :: proc(data: rawptr, fd: prim.Fd, off: i64, size: i64) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.punch_hole(p.base, fd, off, size)
	}
	h := _handle(p, fd)
	if h == nil || off < 0 || size < 0 || !h.write || h.dir {
		return .Invalid
	}
	_admit(p) or_return
	if size == 0 {
		return .None
	}
	oi := h.oi
	if oi.ino.kind == .External {
		oi.dirty = true
		fsize, serr := prim.file_size(p.base, oi.real_fd)
		if serr != .None {
			return _poison(p, serr)
		}
		if n := min(off + size, fsize) - off; n > 0 {
			if e := prim.zero_range(p.base, oi.real_fd, off, n); e != .None {
				return _poison(p, e)
			}
		}
		if !oi.ino.stale {
			return .None
		}
		_erase_stale(p, oi.inum, off, off + size, true) or_return
		if p.compacting != 0 {
			append(&p.cscan, Scan{inum = oi.inum, lo = off, hi = off + size})
		}
		return _maybe_flush(p)
	}
	old := oi.ino
	scratch: Phys_List
	_ext_remove(&oi.ino, off, off + size, &scratch)
	if scratch.n == 0 && !old.stale {
		return .None
	}
	_inode_store(p, oi.inum, &old, &oi.ino, Erase{on = true, lo = off, hi = off + size}) or_return
	return _maybe_flush(p)
}

@(private)
_v_sync :: proc(data: rawptr, fd: prim.Fd) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.datasync(p.base, fd)
	}
	h := _handle(p, fd)
	if h == nil {
		return .Invalid
	}
	if p.batch > 0 && !h.dir && h.oi.ino.kind == .External && h.oi.real_fd >= 0 {
		if p.poisoned {
			return .Io
		}
		if !h.oi.dirty && h.oi.pinned == 0 {
			return .None
		}
		h.oi.dirty = false
		if e := _sync(p, h.oi.real_fd); e != .None {
			_suspect_record(p, []u64{h.oi.inum})
			return _poison(p, e)
		}
		_pend_synced(p, h.oi.inum)
		return .None
	}
	return sync(p)
}

@(private)
_v_lock :: proc(data: rawptr, fd: prim.Fd) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return p.base.procs.lock(p.base.data, fd)
	}
	h := _handle(p, fd)
	if h == nil || h.dir {
		return .Invalid
	}
	idx := int(fd - VFD_BASE)
	if h.oi.locked != 0 && h.oi.locked != idx + 1 {
		return .Busy
	}
	h.oi.locked = idx + 1
	return .None
}

@(private)
_stat_of :: proc(p: ^Pack, inum: u64, ino: ^Inode, real_fd: prim.Fd) -> (st: prim.Stat, err: Error) {
	st.ino = inum
	st.dev = 0x306e_6462
	st.nlink = 1
	st.mode = ino.mode
	st.mtime_ns = ino.mtime
	st.ctime_ns = ino.mtime
	switch ino.kind {
	case .File:
		st.kind = .File
		st.size = ino.size
	case .Dir:
		st.kind = .Dir
		st.mode = 0o040000 | (ino.mode & 0o7777)
	case .Symlink:
		st.kind = .Symlink
		st.size = i64(ino.tlen)
		st.mode = 0o120000 | (ino.mode & 0o7777)
	case .External:
		st.kind = .File
		fd := real_fd
		owned := false
		if fd < 0 {
			pb: prim.Path_Buf
			fd = prim.open_file(p.base, _phys_path(p, &pb, 'x', inum)) or_return
			owned = true
		}
		rs, rerr := prim.fstat(p.base, fd)
		if owned {
			prim.close_file(p.base, fd)
		}
		if rerr != .None {
			return st, rerr
		}
		st.size = rs.size
		st.mtime_ns = rs.mtime_ns
		st.ctime_ns = rs.ctime_ns
	case .None:
		return st, .Io
	}
	return st, .None
}

@(private)
_v_fstat :: proc(data: rawptr, fd: prim.Fd) -> (rst: prim.Stat, rerr: Error) {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.fstat(p.base, fd)
	}
	h := _handle(p, fd)
	if h == nil {
		return {}, .Invalid
	}
	if h.dir {
		ino: Inode
		found := _inode_load(p, h.inum, &ino) or_return
		if !found {
			return {}, .Not_Found
		}
		return _stat_of(p, h.inum, &ino, prim.INVALID_FD)
	}
	st, err := _stat_of(p, h.inum, &h.oi.ino, h.oi.real_fd)
	if h.oi.unlinked {
		st.nlink = 0
	}
	return st, err
}

@(private)
_resolve :: proc(p: ^Pack, rel: string) -> (parent: u64, name: string, inum: u64, kind: Kind, err: Error) {
	parent, name = _walk(p, rel) or_return
	if parent == 0 {
		return 0, "", ROOT_INO, .Dir, .None
	}
	found: bool
	inum, kind, found = _lookup(p, parent, name) or_return
	if !found {
		return parent, name, 0, .None, .Not_Found
	}
	return parent, name, inum, kind, .None
}

@(private)
_v_stat :: proc(data: rawptr, path: string, follow: bool) -> (rst: prim.Stat, rerr: Error) {
	p := (^Pack)(data)
	cur := path
	for depth in 0 ..< 9 {
		rel, inside := _rel(p, cur)
		if !inside {
			return p.base.procs.stat(p.base.data, cur, follow)
		}
		_, _, inum, kind := _resolve(p, rel) or_return
		if kind == .Symlink && follow {
			if depth == 8 {
				return {}, .Invalid
			}
			cur = _symlink_target(p, cur, inum) or_return
			continue
		}
		ino: Inode
		found := _inode_load(p, inum, &ino) or_return
		if !found {
			return {}, .Not_Found
		}
		rfd := prim.INVALID_FD
		if oi, ok := p.open_inodes[inum]; ok {
			rfd = oi.real_fd
		}
		return _stat_of(p, inum, &ino, rfd)
	}
	return {}, .Invalid
}

@(private)
_dir_empty :: proc(p: ^Pack, inum: u64) -> (empty: bool, err: Error) {
	lo: [9]u8
	hi: [9]u8
	lo[0] = K_DIR
	_put_be64(lo[1:9], inum)
	hi[0] = K_DIR
	_put_be64(hi[1:9], inum + 1)
	it: Merge_Iter
	if e := _miter_init(&it, p, lo[:], hi[:]); e != .None {
		_miter_destroy(&it)
		return false, e
	}
	defer _miter_destroy(&it)
	_, _, ok := _miter_next(&it)
	return !ok, it.err
}

@(private)
_drop_inode :: proc(p: ^Pack, inum: u64) -> Error {
	if oi, ok := p.open_inodes[inum]; ok {
		oi.unlinked = true
		kb: [16]u8
		return _put(p, _ikey(kb[:], K_ORPHAN, inum), nil, false)
	}
	return _destroy_inode(p, inum, false)
}

@(private)
_v_unlink :: proc(data: rawptr, path: string) -> Error {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.remove(p.base, path)
	}
	_admit(p) or_return
	parent, name, inum, kind := _resolve(p, rel) or_return
	if parent == 0 || kind == .Dir {
		return .Is_Dir
	}
	kb: [MAX_KEY]u8
	_put(p, _dkey(kb[:], parent, name), nil, true) or_return
	_drop_inode(p, inum) or_return
	return _maybe_flush(p)
}

@(private)
_v_rmdir :: proc(data: rawptr, path: string) -> Error {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.remove_dir(p.base, path)
	}
	_admit(p) or_return
	parent, name, inum, kind := _resolve(p, rel) or_return
	if parent == 0 {
		return .Busy
	}
	if kind != .Dir {
		return .Not_Dir
	}
	empty := _dir_empty(p, inum) or_return
	if !empty {
		return .Not_Empty
	}
	_dcache_clear(p)
	kb: [MAX_KEY]u8
	_put(p, _dkey(kb[:], parent, name), nil, true) or_return
	_destroy_inode(p, inum, false) or_return
	return _maybe_flush(p)
}

@(private)
_v_mkdir :: proc(data: rawptr, path: string, mode: u32) -> Error {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.mkdir(p.base, path, mode)
	}
	_admit(p) or_return
	parent, name := _walk(p, rel) or_return
	if parent == 0 {
		return .Exists
	}
	_, _, found := _lookup(p, parent, name) or_return
	if found {
		return .Exists
	}
	ino: Inode
	ino.kind = .Dir
	ino.mode = 0o040000 | (mode & 0o7777)
	ino.mtime = _now(p)
	_create(p, parent, name, &ino) or_return
	return _maybe_flush(p)
}

@(private)
_v_symlink :: proc(data: rawptr, target: string, path: string) -> Error {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.symlink(p.base, target, path)
	}
	_admit(p) or_return
	if len(target) > MAX_SYMLINK || len(target) == 0 {
		return .Name_Too_Long if len(target) > 0 else .Invalid
	}
	parent, name := _walk(p, rel) or_return
	if parent == 0 {
		return .Exists
	}
	_, _, found := _lookup(p, parent, name) or_return
	if found {
		return .Exists
	}
	ino: Inode
	ino.kind = .Symlink
	ino.mode = 0o120777
	ino.mtime = _now(p)
	ino.tlen = copy(ino.target[:], target)
	_create(p, parent, name, &ino) or_return
	return _maybe_flush(p)
}

@(private)
_v_readlink :: proc(data: rawptr, path: string, buf: []u8) -> (rn: int, rerr: Error) {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.readlink(p.base, path, buf)
	}
	_, _, inum, kind := _resolve(p, rel) or_return
	if kind != .Symlink {
		return 0, .Invalid
	}
	ino: Inode
	found := _inode_load(p, inum, &ino) or_return
	if !found {
		return 0, .Io
	}
	n := copy(buf, ino.target[:ino.tlen])
	if ino.tlen >= len(buf) {
		return ino.tlen, .Too_Large
	}
	return n, .None
}

@(private)
_set_meta :: proc(p: ^Pack, inum: u64, mode: u32, set_mode: bool, mtime: i64) -> Error {
	_admit(p) or_return
	if inum == ROOT_INO {
		return .None
	}
	ino: Inode
	found := _inode_load(p, inum, &ino) or_return
	if !found {
		return .Not_Found
	}
	old := ino
	if set_mode {
		ino.mode = (ino.mode & ~u32(0o7777)) | (mode & 0o7777)
	} else {
		ino.mtime = mtime
	}
	if oi, ok := p.open_inodes[inum]; ok {
		oi.ino.mode = ino.mode
		oi.ino.mtime = ino.mtime
	}
	_inode_store(p, inum, &old, &ino) or_return
	return _maybe_flush(p)
}

@(private)
_v_fchmod :: proc(data: rawptr, fd: prim.Fd, mode: u32) -> Error {
	p := (^Pack)(data)
	if fd < VFD_BASE {
		return prim.fchmod(p.base, fd, mode)
	}
	h := _handle(p, fd)
	if h == nil {
		return .Invalid
	}
	return _set_meta(p, h.inum, mode, true, 0)
}

@(private)
_v_set_times :: proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> Error {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return prim.set_times(p.base, path, atime_ns, mtime_ns)
	}
	if mtime_ns < 0 || atime_ns < 0 {
		return .Invalid
	}
	_, _, inum, _ := _resolve(p, rel) or_return
	return _set_meta(p, inum, 0, false, mtime_ns)
}

@(private)
_v_rename :: proc(data: rawptr, old: string, new: string) -> Error {
	p := (^Pack)(data)
	orel, oin := _rel(p, old)
	nrel, nin := _rel(p, new)
	if !oin && !nin {
		return prim.rename(p.base, old, new)
	}
	if oin != nin {
		return .Unsupported
	}
	_admit(p) or_return
	sp, sname, sinum, skind := _resolve(p, orel) or_return
	if sp == 0 {
		return .Busy
	}
	dp, dname := _walk(p, nrel) or_return
	if dp == 0 {
		return .Busy
	}
	if sp == dp && sname == dname {
		return .None
	}
	if skind == .Dir && len(nrel) > len(orel) && nrel[:len(orel)] == orel && nrel[len(orel)] == '/' {
		return .Invalid
	}
	dinum, dkind, dfound := _lookup(p, dp, dname) or_return
	if dfound {
		if dkind == .Dir {
			if skind != .Dir {
				return .Is_Dir
			}
			empty := _dir_empty(p, dinum) or_return
			if !empty {
				return .Not_Empty
			}
		} else if skind == .Dir {
			return .Not_Dir
		}
	}
	_dcache_clear(p)
	kb: [MAX_KEY]u8
	vb: [16]u8
	_put(p, _dkey(kb[:], dp, dname), _dval(vb[:], sinum, skind), false) or_return
	_put(p, _dkey(kb[:], sp, sname), nil, true) or_return
	if dfound && dinum != sinum {
		_drop_inode(p, dinum) or_return
	}
	return _maybe_flush(p)
}

@(private)
Dir_State :: struct {
	inum:   u64,
	last:   [MAX_NAME]u8,
	llen:   int,
	names:  [dynamic]u8,
	ents:   [dynamic]Dir_Ent,
	pos:    int,
	eof:    bool,
	cur:    [MAX_NAME]u8,
}

@(private)
Dir_Ent :: struct {
	off:  int,
	len:  int,
	ino:  u64,
	kind: Kind,
}

@(private)
_v_dir_open :: proc(data: rawptr, d: ^prim.Dir, path: string) -> Error {
	p := (^Pack)(data)
	rel, inside := _rel(p, path)
	if !inside {
		return p.base.procs.dir_open(p.base.data, d, path)
	}
	_, _, inum, kind := _resolve(p, rel) or_return
	if kind != .Dir {
		return .Not_Dir
	}
	s := new(Dir_State, p.allocator)
	if s == nil {
		return .No_Memory
	}
	s.inum = inum
	s.names = make([dynamic]u8, p.allocator)
	s.ents = make([dynamic]Dir_Ent, p.allocator)
	d.fd = DIR_MARK
	d.handle = s
	return .None
}

@(private)
_dir_fill :: proc(p: ^Pack, s: ^Dir_State) -> Error {
	clear(&s.names)
	clear(&s.ents)
	s.pos = 0
	lo: [MAX_KEY]u8
	n := len(_dkey(lo[:], s.inum, string(s.last[:s.llen])))
	if s.llen > 0 {
		lo[n] = 0
		n += 1
	}
	hi: [9]u8
	hi[0] = K_DIR
	_put_be64(hi[1:9], s.inum + 1)
	it: Merge_Iter
	if e := _miter_init(&it, p, lo[:n], hi[:]); e != .None {
		_miter_destroy(&it)
		return e
	}
	defer _miter_destroy(&it)
	for len(s.ents) < DIR_BATCH {
		key, val, ok := _miter_next(&it)
		if !ok {
			s.eof = true
			break
		}
		inum, vn := prim.get_uvarint(val)
		if vn <= 0 || vn >= len(val) {
			return .Io
		}
		name := key[9:]
		append(&s.ents, Dir_Ent{off = len(s.names), len = len(name), ino = inum, kind = Kind(val[vn])})
		append(&s.names, ..name)
		s.llen = copy(s.last[:], name)
	}
	return it.err
}

@(private)
_v_dir_next :: proc(data: rawptr, d: ^prim.Dir) -> (rent: prim.Dir_Entry, rok: bool, rerr: Error) {
	p := (^Pack)(data)
	if d.fd != DIR_MARK {
		return p.base.procs.dir_next(p.base.data, d)
	}
	s := (^Dir_State)(d.handle)
	if s == nil {
		return {}, false, .None
	}
	if s.pos >= len(s.ents) {
		if s.eof {
			return {}, false, .None
		}
		_dir_fill(p, s) or_return
		if len(s.ents) == 0 {
			return {}, false, .None
		}
	}
	e := s.ents[s.pos]
	s.pos += 1
	n := copy(s.cur[:], s.names[e.off:][:e.len])
	kind: prim.File_Kind
	switch e.kind {
	case .File, .External:
		kind = .File
	case .Dir:
		kind = .Dir
	case .Symlink:
		kind = .Symlink
	case .None:
		kind = .Unknown
	}
	return prim.Dir_Entry{name = string(s.cur[:n]), ino = e.ino, kind = kind}, true, .None
}

@(private)
_v_dir_close :: proc(data: rawptr, d: ^prim.Dir) {
	p := (^Pack)(data)
	if d.fd != DIR_MARK {
		p.base.procs.dir_close(p.base.data, d)
		return
	}
	s := (^Dir_State)(d.handle)
	if s != nil {
		delete(s.names)
		delete(s.ents)
		free(s, p.allocator)
	}
	d.handle = nil
	d.fd = prim.INVALID_FD
}

Phys_Range :: struct {
	fd:  prim.Fd,
	off: i64,
	len: i64,
}

extent :: proc(p: ^Pack, fd: prim.Fd, off: i64, n: i64) -> (r: Phys_Range, ok: bool) {
	h := _handle(p, fd)
	if h == nil || h.dir || off < 0 || n <= 0 || p.poisoned {
		return
	}
	oi := h.oi
	if oi.ino.kind == .External {
		st, err := prim.fstat(p.base, oi.real_fd)
		if err != .None || off >= st.size {
			return
		}
		return Phys_Range{fd = oi.real_fd, off = off, len = min(n, st.size - off)}, true
	}
	if oi.ino.kind != .File || off >= oi.ino.size {
		return
	}
	for e in oi.ino.ext[:oi.ino.n] {
		if off < e.off || off >= e.off + e.len {
			continue
		}
		l := min(n, e.off + e.len - off, oi.ino.size - off)
		ph := e.coff + (off - e.off)
		if p.active >= 0 && e.cont == _active_id(p) {
			if ph >= p.buf_base {
				return
			}
			l = min(l, p.buf_base - ph)
		}
		cfd, err := _cont_fd(p, e.cont)
		if err != .None {
			return
		}
		p.conts[_cont_index(p, e.cont)].lent = true
		return Phys_Range{fd = cfd, off = ph, len = l}, true
	}
	return
}

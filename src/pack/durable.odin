package pack

import "../prim"

@(private)
Pend :: struct {
	base:  i64,
	steps: [dynamic]Pend_Step,
}

@(private)
Pend_Step :: struct {
	seq:  u64,
	size: i64,
}

durable_size :: proc(p: ^Pack, path: string) -> (size: i64, err: Error) {
	rel, inside := _rel(p, path)
	if !inside {
		return 0, .Invalid
	}
	_, _, inum, kind, rerr := _resolve(p, rel)
	if rerr != .None {
		return 0, rerr
	}
	if kind != .File && kind != .External {
		return 0, .Invalid
	}
	if pd, ok := p.pend[inum]; ok {
		return _pend_durable(p, pd), .None
	}
	return _current_size(p, inum)
}

@(private)
_current_size :: proc(p: ^Pack, inum: u64) -> (size: i64, err: Error) {
	if oi, ok := p.open_inodes[inum]; ok {
		if oi.ino.kind == .External && oi.real_fd >= 0 {
			return _perr_size(prim.file_size(p.base, oi.real_fd))
		}
		return oi.ino.size, .None
	}
	ino: Inode
	found := _inode_load(p, inum, &ino) or_return
	if !found {
		return 0, .Not_Found
	}
	if ino.kind == .External && ino.size >= 0 {
		return ino.size, .None
	}
	if ino.kind == .External {
		pb: prim.Path_Buf
		st := prim.stat(p.base, _phys_path(p, &pb, 'x', inum)) or_return
		return st.size, .None
	}
	return ino.size, .None
}

@(private)
_perr_size :: proc(size: i64, err: prim.Error) -> (i64, Error) {
	return size, err
}

@(private)
_pend_durable :: proc "contextless" (p: ^Pack, pd: ^Pend) -> i64 {
	d := pd.base
	for s in pd.steps {
		if s.seq > p.durable_seq {
			break
		}
		d = s.size
	}
	return d
}

@(private)
_pend_note :: proc(p: ^Pack, inum: u64, before: i64, after: i64) {
	pd, ok := p.pend[inum]
	if !ok {
		pd = new(Pend, p.allocator)
		pd.base = before
		pd.steps = make([dynamic]Pend_Step, p.allocator)
		p.pend[inum] = pd
	}
	n := len(pd.steps)
	if n > 0 && pd.steps[n - 1].seq == p.seq {
		pd.steps[n - 1].size = after
	} else {
		append(&pd.steps, Pend_Step{p.seq, after})
	}
	if after < before {
		pd.base = min(pd.base, after)
		for &s in pd.steps {
			s.size = min(s.size, after)
		}
	}
}

@(private)
_pend_synced :: proc(p: ^Pack, inum: u64) {
	if pd, ok := p.pend[inum]; ok {
		_pend_free(p, pd)
		delete_key(&p.pend, inum)
	}
}

@(private)
_pend_trim :: proc(p: ^Pack) {
	done := make([dynamic]u64, context.temp_allocator)
	for inum, pd in p.pend {
		k := 0
		for k < len(pd.steps) && pd.steps[k].seq <= p.durable_seq {
			pd.base = pd.steps[k].size
			k += 1
		}
		if k == len(pd.steps) {
			append(&done, inum)
		} else if k > 0 {
			remove_range(&pd.steps, 0, k)
		}
	}
	for inum in done {
		_pend_free(p, p.pend[inum])
		delete_key(&p.pend, inum)
	}
}

@(private)
_pend_free :: proc(p: ^Pack, pd: ^Pend) {
	delete(pd.steps)
	free(pd, p.allocator)
}

@(private)
_pend_release :: proc(p: ^Pack) {
	for _, pd in p.pend {
		_pend_free(p, pd)
	}
	delete(p.pend)
}

@(private)
_ext_before :: proc(p: ^Pack, oi: ^Open_Inode) -> (i64, Error) {
	if pd, ok := p.pend[oi.inum]; ok {
		n := len(pd.steps)
		return pd.steps[n - 1].size if n > 0 else pd.base, .None
	}
	return _perr_size(prim.file_size(p.base, oi.real_fd))
}

@(private)
_mark_visible :: proc(p: ^Pack, oi: ^Open_Inode) -> Error {
	old := oi.ino
	oi.ino.visible = true
	if oi.ino.kind == .External {
		oi.ino.size = _perr_size(prim.file_size(p.base, oi.real_fd)) or_return
	}
	return _inode_store(p, oi.inum, &old, &oi.ino)
}

@(private)
_ext_commit_size :: proc(p: ^Pack, oi: ^Open_Inode, size: i64) -> Error {
	if oi.ino.size == size {
		return .None
	}
	old := oi.ino
	oi.ino.size = size
	oi.ino.mtime = _now(p)
	return _inode_store(p, oi.inum, &old, &oi.ino)
}

@(private)
_ext_trim :: proc(p: ^Pack, inum: u64) -> Error {
	ino: Inode
	found := _inode_load(p, inum, &ino) or_return
	if !found || ino.kind != .External || !ino.visible || ino.size < 0 {
		return .None
	}
	pb: prim.Path_Buf
	fd, oerr := prim.open_file(p.base, _phys_path(p, &pb, 'x', inum), {.Write})
	if oerr == .Not_Found {
		return .None if ino.size == 0 else .Io
	}
	if oerr != .None {
		return oerr
	}
	defer prim.close_file(p.base, fd)
	size := prim.file_size(p.base, fd) or_return
	if size < ino.size {
		return .Io
	}
	if size > ino.size {
		prim.truncate(p.base, fd, ino.size) or_return
		_sync(p, fd) or_return
	}
	return .None
}

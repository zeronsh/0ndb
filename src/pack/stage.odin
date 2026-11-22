package pack

import "../prim"

@(private)
Stage :: struct {
	data:   [dynamic]u8,
	writes: [dynamic]Stage_Write,
	hi:     i64,
}

@(private)
Stage_Write :: struct {
	off: i64,
	pos: int,
	len: int,
}

stage :: proc(p: ^Pack, fd: prim.Fd) -> (sfd: prim.Fd, err: Error) {
	h := _handle(p, fd)
	if h == nil || h.dir || !h.write || h.stage != nil {
		return prim.INVALID_FD, .Invalid
	}
	if p.poisoned {
		return prim.INVALID_FD, .Io
	}
	oi := h.oi
	inum := h.inum
	st := new(Stage, p.allocator)
	if st == nil {
		return prim.INVALID_FD, .No_Memory
	}
	st.data = make([dynamic]u8, p.allocator)
	st.writes = make([dynamic]Stage_Write, p.allocator)
	idx, herr := _new_handle(p)
	if herr != .None {
		_stage_free(p, st)
		return prim.INVALID_FD, herr
	}
	oi.refs += 1
	p.handles[idx] = Handle{used = true, write = true, oi = oi, inum = inum, stage = st}
	return VFD_BASE + prim.Fd(idx), .None
}

@(private)
_stage_free :: proc(p: ^Pack, st: ^Stage) {
	delete(st.data)
	delete(st.writes)
	free(st, p.allocator)
}

@(private)
_stage_write :: proc(p: ^Pack, h: ^Handle, src: []u8, off: i64) -> Error {
	st := h.stage
	oi := h.oi
	end := off + i64(len(src))
	if oi.ino.kind == .File && end > p.opts.promote_size {
		_promote(p, oi, true) or_return
		_stage_spill(p, h) or_return
	}
	if oi.ino.kind == .External {
		if e := prim.write_at(p.base, oi.real_fd, src, off); e != .None {
			return _poison(p, e)
		}
		st.hi = max(st.hi, end)
		return .None
	}
	if oi.ino.kind != .File {
		return .Io
	}
	pos := len(st.data)
	if resize(&st.data, pos + len(src)) != nil {
		return .No_Memory
	}
	copy(st.data[pos:], src)
	if _, aerr := append(&st.writes, Stage_Write{off = off, pos = pos, len = len(src)}); aerr != nil {
		resize(&st.data, pos)
		return .No_Memory
	}
	st.hi = max(st.hi, end)
	return .None
}

@(private)
_stage_spill :: proc(p: ^Pack, h: ^Handle) -> Error {
	st := h.stage
	oi := h.oi
	for w in st.writes {
		if e := prim.write_at(p.base, oi.real_fd, st.data[w.pos:][:w.len], w.off); e != .None {
			return _poison(p, e)
		}
	}
	clear(&st.writes)
	clear(&st.data)
	return .None
}

@(private)
_stage_sync :: proc(p: ^Pack, h: ^Handle) -> Error {
	if p.poisoned {
		return .Io
	}
	st := h.stage
	oi := h.oi
	if oi.ino.kind == .External {
		_stage_spill(p, h) or_return
	} else {
		for w in st.writes {
			_write(p, oi, st.data[w.pos:][:w.len], w.off, true) or_return
		}
		clear(&st.writes)
		clear(&st.data)
	}
	if oi.ino.kind == .External && st.hi > 0 {
		if e := _sync(p, oi.real_fd); e != .None {
			_suspect_record(p, []u64{oi.inum})
			return _poison(p, e)
		}
		size := max(oi.ino.size if oi.ino.sized else oi.ext_base, st.hi)
		if !oi.ino.sized || size != oi.ino.size {
			old := oi.ino
			oi.ino.sized = true
			oi.ino.size = size
			_inode_store(p, oi.inum, &old, &oi.ino) or_return
		}
	}
	st.hi = 0
	if p.batch > 0 {
		return .None
	}
	return sync(p)
}

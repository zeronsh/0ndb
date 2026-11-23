package pack

import "core:hash/xxhash"
import "../prim"

@(private)
HEADROOM_CHUNK :: i64(1 << 20)
@(private)
INODE_META_MAX :: i64(4 * 1024 + 512)
@(private)
META_FIXED :: i64(4 * 1024)
@(private)
RUN_SLACK :: i64(64 * 1024)

@(private)
_meta_need :: proc "contextless" (p: ^Pack, extra_inodes: int) -> i64 {
	return META_FIXED + i64(len(p.dirty) + extra_inodes) * INODE_META_MAX
}

@(private)
_prealloc :: proc(p: ^Pack, fd: prim.Fd, from, to: i64) -> Error {
	if p.no_prealloc || to <= from {
		return .None
	}
	e := prim.preallocate(p.base, fd, from, to - from)
	if e == .Unsupported || e == .Invalid {
		p.no_prealloc = true
		return .None
	}
	return e
}

@(private)
_headroom :: proc(p: ^Pack, extra: i64, extra_inodes: int) -> Error {
	if p.active < 0 || p.no_prealloc {
		return .None
	}
	need := _log_tail(p) + p.reserved + extra + _meta_need(p, extra_inodes)
	if need <= p.alloc_end {
		return .None
	}
	c := &p.conts[p.active]
	if c.fd < 0 {
		return .None
	}
	from := max(p.alloc_end, c.size)
	if _prealloc(p, c.fd, from, need + HEADROOM_CHUNK) == .None {
		p.alloc_end = max(p.alloc_end, need + HEADROOM_CHUNK)
		return .None
	}
	_prealloc(p, c.fd, from, need) or_return
	p.alloc_end = max(p.alloc_end, need)
	return .None
}

@(private)
_spare_ensure :: proc(p: ^Pack) -> Error {
	if p.has_spare {
		return .None
	}
	id := p.next_cont
	pb: prim.Path_Buf
	path := _phys_path(p, &pb, 'c', u64(id))
	fd := prim.open_file(p.base, path, {.Write, .Create, .Exclusive}, 0o600) or_return
	if e := _prealloc(p, fd, 0, CONT_HDR + HEADROOM_CHUNK); e != .None {
		prim.close_file(p.base, fd)
		prim.remove(p.base, path)
		return e
	}
	hdr: [CONT_HDR]u8
	prim.put_u64le(hdr[0:8], CONT_MAGIC)
	prim.put_u32le(hdr[8:12], VERSION)
	prim.put_u32le(hdr[12:16], id)
	prim.put_u64le(hdr[CONT_HDR - 8:], xxhash.XXH3_64_with_seed(hdr[:CONT_HDR - 8], CONT_MAGIC))
	if e := prim.write_at(p.base, fd, hdr[:], 0); e != .None {
		prim.close_file(p.base, fd)
		prim.remove(p.base, path)
		return e
	}
	p.next_cont += 1
	p.spare = Cont{id = id, fd = fd, size = CONT_HDR, used = p.tick}
	p.spare_alloc = CONT_HDR + HEADROOM_CHUNK
	p.has_spare = true
	return .None
}

@(private)
_spare_drop :: proc(p: ^Pack) {
	if !p.has_spare {
		return
	}
	pb: prim.Path_Buf
	prim.close_file(p.base, p.spare.fd)
	prim.remove(p.base, _phys_path(p, &pb, 'c', u64(p.spare.id)))
	p.has_spare = false
	p.spare = {}
}

reserve :: proc(p: ^Pack, n: i64) -> Error {
	if p.poisoned {
		return .Io
	}
	if p.fl_retry {
		return p.fl_err
	}
	if n < 0 || n > p.opts.container_size - _meta_need(p, 8) {
		return .Too_Large
	}
	_headroom(p, n, 1) or_return
	if _log_tail(p) + p.reserved + n + _meta_need(p, 1) >= p.opts.container_size {
		_spare_ensure(p) or_return
	}
	p.reserved += n + INODE_META_MAX
	return .None
}

scope_begin :: proc(p: ^Pack) {
	p.op_depth += 1
}

scope_end :: proc(p: ^Pack) {
	if p.op_depth > 0 {
		p.op_depth -= 1
	}
}

reserve_clear :: proc(p: ^Pack) {
	if p.op_depth == 0 {
		p.reserved = 0
	}
}

@(private)
_room :: proc(p: ^Pack, n: int) -> Error {
	if p.committing {
		return .None
	}
	if p.op_depth > 0 && p.reserved > 0 {
		p.reserved = max(p.reserved - i64(n), 0)
		return _headroom(p, i64(n), 0)
	}
	return _headroom(p, i64(n), 1)
}

@(private)
_retry :: proc(p: ^Pack) -> Error {
	if !p.fl_retry || p.fl.on {
		return .None
	}
	if _resync_job(p) != .None {
		return .None
	}
	p.fl_retry = false
	return _submit(p)
}

@(private)
_resync_job :: proc(p: ^Pack) -> Error {
	fl := &p.fl
	seen := make([dynamic]prim.Fd, context.temp_allocator)
	visit :: proc(p: ^Pack, seen: ^[dynamic]prim.Fd, fd: prim.Fd) -> Error {
		if fd < 0 {
			return .None
		}
		for x in seen {
			if x == fd {
				return .None
			}
		}
		append(seen, fd)
		return prim.resync_fd(p.base, fd)
	}
	if len(fl.data) > 0 {
		visit(p, &seen, fl.data_fd) or_return
	}
	if fl.wrote {
		visit(p, &seen, fl.fd) or_return
	}
	visit(p, &seen, fl.newc_fd) or_return
	for j in fl.fds {
		visit(p, &seen, j.fd) or_return
	}
	for c in fl.syncs {
		visit(p, &seen, c.fd) or_return
	}
	for z in fl.zjobs {
		visit(p, &seen, z.fd) or_return
	}
	visit(p, &seen, fl.scan_fd) or_return
	if fl.kind == .Flush {
		visit(p, &seen, fl.run_fd) or_return
	}
	return .None
}

stalled :: proc "contextless" (p: ^Pack) -> Error {
	return p.fl_err if p.fl_retry else .None
}

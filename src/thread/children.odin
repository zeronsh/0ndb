package thread

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

@(private)
CHILD_MAGIC :: 0x646c_6863_6264_6e30
@(private)
CHILD_VERSION :: 1
@(private)
CHILD_HEADER :: 4096
@(private)
CHILD_SLOT :: 32
@(private)
CHILD_MIN_SLOTS :: 1024
@(private)
CHILD_SEED :: 0x6b69_6473
@(private)
CHILD_COPY :: 2048

Children :: struct {
	fd:        prim.Fd,
	path:      string,
	thread:    prim.Id,
	slots:     u64,
	used:      u64,
	covered:   i64,
	synced:    i64,
	allocator: runtime.Allocator,
}

@(private)
Slot :: struct {
	key:   u64,
	child: i64,
	seal:  i64,
}

children_open :: proc(c: ^Children, path: string, thread: prim.Id, allocator := context.allocator, write := true) -> Error {
	c^ = {
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	fd, oerr := prim.open_file(path, {.Write} if write else {}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	c.fd = fd
	if err := _children_set_path(c, path); err != .None {
		children_close(c)
		return err
	}
	h: [64]u8
	n, rerr := prim.read_at(fd, h[:], 0)
	if rerr != .None {
		children_close(c)
		return _perr(rerr)
	}
	size, serr := prim.file_size(fd)
	if serr != .None {
		children_close(c)
		return _perr(serr)
	}
	ok := n == 64 && prim.get_u64le(h[0:8]) == CHILD_MAGIC && prim.get_u32le(h[8:12]) == CHILD_VERSION
	ok = ok && xxhash.XXH3_64_with_seed(h[0:56], CHILD_SEED) == prim.get_u64le(h[56:64])
	if !ok {
		children_close(c)
		return .Corrupt
	}
	copy(c.thread[:], h[16:32])
	c.slots = prim.get_u64le(h[32:40])
	c.used = prim.get_u64le(h[40:48])
	cov := prim.get_u64le(h[48:56])
	pow2 := c.slots >= CHILD_MIN_SLOTS && c.slots & (c.slots - 1) == 0 && c.slots <= 1 << 40
	if !pow2 || c.thread != thread || cov > u64(max(i64)) || i64(CHILD_HEADER + c.slots * CHILD_SLOT) != size || c.used > c.slots {
		children_close(c)
		return .Corrupt
	}
	c.covered = i64(cov)
	c.synced = c.covered
	return .None
}

children_create :: proc(c: ^Children, path: string, thread: prim.Id, allocator := context.allocator) -> Error {
	c^ = {
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	fd, err := _children_fresh(path, thread, CHILD_MIN_SLOTS)
	if err != .None {
		return err
	}
	c.fd = fd
	if perr := _children_set_path(c, path); perr != .None {
		children_close(c)
		return perr
	}
	c.thread = thread
	c.slots = CHILD_MIN_SLOTS
	return .None
}

children_close :: proc(c: ^Children) {
	if c.fd >= 0 {
		prim.close(c.fd)
	}
	if len(c.path) > 0 {
		delete(c.path, c.allocator)
	}
	c^ = {
		fd = prim.INVALID_FD,
	}
}

children_get :: proc(c: ^Children, msg: i64) -> (child: i64, seal: i64, err: Error) {
	key := u64(msg) + 1
	mask := c.slots - 1
	i := _child_hash(key) & mask
	for _ in 0 ..< c.slots {
		s, empty := _slot_read(c.fd, i) or_return
		if empty {
			return 0, 0, .None
		}
		if s.key == key {
			return s.child, s.seal, .None
		}
		i = (i + 1) & mask
	}
	return 0, 0, .None
}

children_put :: proc(c: ^Children, msg: i64, child: i64, seal: i64) -> Error {
	if (c.used + 1) * 2 > c.slots {
		_children_grow(c) or_return
	}
	key := u64(msg) + 1
	for {
		mask := c.slots - 1
		i := _child_hash(key) & mask
		for _ in 0 ..< c.slots {
			s, empty := _slot_read(c.fd, i) or_return
			if empty {
				_slot_write(c.fd, i, Slot{key, max(child, 0), max(seal, 0)}) or_return
				c.used += 1
				return .None
			}
			if s.key == key {
				next := Slot{key, max(s.child, child), seal if seal > 0 else s.seal}
				if next != s {
					_slot_write(c.fd, i, next) or_return
				}
				return .None
			}
			i = (i + 1) & mask
		}
		_children_grow(c) or_return
	}
}

children_sync :: proc(c: ^Children) -> Error {
	if c.covered == c.synced {
		return .None
	}
	if err := prim.datasync(c.fd); err != .None {
		return _perr(err)
	}
	if err := _header_write(c.fd, c.thread, c.slots, c.used, c.covered); err != .None {
		return err
	}
	if err := prim.datasync(c.fd); err != .None {
		return _perr(err)
	}
	c.synced = c.covered
	return .None
}

@(private)
_children_set_path :: proc(c: ^Children, path: string) -> Error {
	p, err := make([]u8, len(path), c.allocator)
	if err != nil {
		return .No_Memory
	}
	copy(p, path)
	c.path = string(p)
	return .None
}

@(private)
_child_hash :: proc "contextless" (key: u64) -> u64 {
	h := key * 0x9e37_79b9_7f4a_7c15
	h ~= h >> 29
	h *= 0xbf58_476d_1ce4_e5b9
	h ~= h >> 32
	return h
}

@(private)
_slot_check :: proc(b: []u8, i: u64) -> u64 {
	return xxhash.XXH3_64_with_seed(b[0:24], CHILD_SEED ~ (i + 1) * 0x9e37_79b9)
}

@(private)
_slot_decode :: proc(b: []u8, i: u64) -> (s: Slot, empty: bool, err: Error) {
	zero := true
	for x in b[:CHILD_SLOT] {
		if x != 0 {
			zero = false
			break
		}
	}
	if zero {
		return {}, true, .None
	}
	if _slot_check(b, i) != prim.get_u64le(b[24:32]) {
		return {}, false, .Corrupt
	}
	s.key = prim.get_u64le(b[0:8])
	child := prim.get_u64le(b[8:16])
	seal := prim.get_u64le(b[16:24])
	if s.key == 0 || child > u64(max(i64)) || seal > u64(max(i64)) {
		return {}, false, .Corrupt
	}
	s.child = i64(child)
	s.seal = i64(seal)
	return s, false, .None
}

@(private)
_slot_read :: proc(fd: prim.Fd, i: u64) -> (s: Slot, empty: bool, err: Error) {
	b: [CHILD_SLOT]u8
	n, rerr := prim.read_at(fd, b[:], i64(CHILD_HEADER + i * CHILD_SLOT))
	if rerr != .None {
		return {}, false, _perr(rerr)
	}
	if n != CHILD_SLOT {
		return {}, false, .Corrupt
	}
	return _slot_decode(b[:], i)
}

@(private)
_slot_write :: proc(fd: prim.Fd, i: u64, s: Slot) -> Error {
	b: [CHILD_SLOT]u8
	prim.put_u64le(b[0:8], s.key)
	prim.put_u64le(b[8:16], u64(s.child))
	prim.put_u64le(b[16:24], u64(s.seal))
	prim.put_u64le(b[24:32], _slot_check(b[:], i))
	return _perr(prim.write_at(fd, b[:], i64(CHILD_HEADER + i * CHILD_SLOT)))
}

@(private)
_header_write :: proc(fd: prim.Fd, thread: prim.Id, slots, used: u64, covered: i64) -> Error {
	h: [64]u8
	prim.put_u64le(h[0:8], CHILD_MAGIC)
	prim.put_u32le(h[8:12], CHILD_VERSION)
	t := thread
	copy(h[16:32], t[:])
	prim.put_u64le(h[32:40], slots)
	prim.put_u64le(h[40:48], used)
	prim.put_u64le(h[48:56], u64(covered))
	prim.put_u64le(h[56:64], xxhash.XXH3_64_with_seed(h[0:56], CHILD_SEED))
	return _perr(prim.write_at(fd, h[:], 0))
}

@(private)
_tmp_path :: proc(path: string, buf: ^prim.Path_Buf) -> (string, Error) {
	if len(path) + 4 >= len(buf) {
		return "", .Invalid
	}
	n := copy(buf[:], path)
	n += copy(buf[n:], ".new")
	return string(buf[:n]), .None
}

@(private)
_children_fresh :: proc(path: string, thread: prim.Id, slots: u64) -> (fd: prim.Fd, err: Error) {
	buf: prim.Path_Buf
	tmp := _tmp_path(path, &buf) or_return
	fd = _children_blank(tmp, thread, slots, 0) or_return
	if e := prim.datasync(fd); e != .None {
		prim.close(fd)
		return prim.INVALID_FD, _perr(e)
	}
	if e := prim.rename(tmp, path); e != .None {
		prim.close(fd)
		return prim.INVALID_FD, _perr(e)
	}
	if e := prim.sync_dir(prim.dir_name(path)); e != .None {
		prim.close(fd)
		return prim.INVALID_FD, _perr(e)
	}
	return fd, .None
}

@(private)
_children_blank :: proc(path: string, thread: prim.Id, slots: u64, covered: i64) -> (fd: prim.Fd, err: Error) {
	f, oerr := prim.open_file(path, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return prim.INVALID_FD, _perr(oerr)
	}
	if e := prim.truncate(f, i64(CHILD_HEADER + slots * CHILD_SLOT)); e != .None {
		prim.close(f)
		return prim.INVALID_FD, _perr(e)
	}
	if e := _header_write(f, thread, slots, 0, covered); e != .None {
		prim.close(f)
		return prim.INVALID_FD, e
	}
	return f, .None
}

@(private)
_children_grow :: proc(c: ^Children) -> Error {
	buf: prim.Path_Buf
	tmp := _tmp_path(c.path, &buf) or_return
	slots := c.slots * 2
	if slots > 1 << 40 {
		return .Limit
	}
	nfd := _children_blank(tmp, c.thread, slots, c.covered) or_return
	ok := false
	defer if !ok {
		prim.close(nfd)
		prim.remove(tmp)
	}
	chunk: [CHILD_COPY]u8
	used: u64
	mask := slots - 1
	for base: u64 = 0; base < c.slots; base += CHILD_COPY / CHILD_SLOT {
		count := min(CHILD_COPY / CHILD_SLOT, c.slots - base)
		want := int(count * CHILD_SLOT)
		n, rerr := prim.read_at(c.fd, chunk[:want], i64(CHILD_HEADER + base * CHILD_SLOT))
		if rerr != .None {
			return _perr(rerr)
		}
		if n != want {
			return .Corrupt
		}
		for k in 0 ..< count {
			s, empty := _slot_decode(chunk[k * CHILD_SLOT:][:CHILD_SLOT], base + k) or_return
			if empty {
				continue
			}
			i := _child_hash(s.key) & mask
			for {
				_, e := _slot_read(nfd, i) or_return
				if e {
					break
				}
				i = (i + 1) & mask
			}
			_slot_write(nfd, i, s) or_return
			used += 1
		}
	}
	if e := _header_write(nfd, c.thread, slots, used, c.covered); e != .None {
		return e
	}
	if e := prim.datasync(nfd); e != .None {
		return _perr(e)
	}
	if e := prim.rename(tmp, c.path); e != .None {
		return _perr(e)
	}
	ok = true
	prim.close(c.fd)
	c.fd = nfd
	c.slots = slots
	c.used = used
	c.synced = c.covered
	if e := prim.sync_dir(prim.dir_name(c.path)); e != .None {
		return _perr(e)
	}
	return .None
}

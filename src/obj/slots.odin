package obj

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

@(private)
SLOT_MAGIC :: 0x646c_6863_6264_6e30
@(private)
SLOT_VERSION :: 1
@(private)
SLOT_HEADER :: 4096
@(private)
SLOT_SLOT :: 32
@(private)
SLOT_MIN_SLOTS :: 1024
@(private)
SLOT_SEED :: 0x6b69_6473
@(private)
SLOT_COPY :: 2048
@(private)
SLOT_DIRTY :: max(i64)

Slots :: struct {
	vfs:       prim.Vfs,
	fd:        prim.Fd,
	path:      string,
	owner:     prim.Id,
	slots:     u64,
	used:      u64,
	covered:   i64,
	synced:    i64,
	marked:    bool,
	owed:      bool,
	allocator: runtime.Allocator,
}

@(private)
Slot :: struct {
	key:   u64,
	child: i64,
	seal:  i64,
}

slots_open :: proc(c: ^Slots, vfs: prim.Vfs, path: string, owner: prim.Id, allocator := context.allocator, write := true) -> Error {
	c^ = {
		vfs       = vfs,
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	fd, oerr := prim.open_file(c.vfs, path, {.Write} if write else {}, 0o600)
	if oerr != .None {
		return perr(oerr)
	}
	c.fd = fd
	if err := _slots_set_path(c, path); err != .None {
		slots_close(c)
		return err
	}
	h: [64]u8
	n, rerr := prim.read_at(c.vfs, fd, h[:], 0)
	if rerr != .None {
		slots_close(c)
		return perr(rerr)
	}
	size, serr := prim.file_size(c.vfs, fd)
	if serr != .None {
		slots_close(c)
		return perr(serr)
	}
	ok := n == 64 && prim.get_u64le(h[0:8]) == SLOT_MAGIC && prim.get_u32le(h[8:12]) == SLOT_VERSION
	ok = ok && xxhash.XXH3_64_with_seed(h[0:56], SLOT_SEED) == prim.get_u64le(h[56:64])
	if !ok {
		slots_close(c)
		return .Corrupt
	}
	copy(c.owner[:], h[16:32])
	c.slots = prim.get_u64le(h[32:40])
	c.used = prim.get_u64le(h[40:48])
	cov := prim.get_u64le(h[48:56])
	pow2 := c.slots >= SLOT_MIN_SLOTS && c.slots & (c.slots - 1) == 0 && c.slots <= 1 << 40
	if !pow2 || c.owner != owner || cov > u64(max(i64)) || i64(SLOT_HEADER + c.slots * SLOT_SLOT) != size || c.used > c.slots {
		slots_close(c)
		return .Corrupt
	}
	c.covered = i64(cov)
	c.synced = c.covered
	c.marked = c.covered == SLOT_DIRTY
	return .None
}

slots_create :: proc(c: ^Slots, vfs: prim.Vfs, path: string, owner: prim.Id, allocator := context.allocator) -> Error {
	c^ = {
		vfs       = vfs,
		fd        = prim.INVALID_FD,
		allocator = allocator,
	}
	fd, err := _slots_fresh(vfs, path, owner, SLOT_MIN_SLOTS)
	if err != .None {
		return err
	}
	c.fd = fd
	if perr := _slots_set_path(c, path); perr != .None {
		slots_close(c)
		return perr
	}
	c.owner = owner
	c.slots = SLOT_MIN_SLOTS
	return .None
}

slots_close :: proc(c: ^Slots) {
	if c.fd >= 0 {
		prim.close_file(c.vfs, c.fd)
	}
	if len(c.path) > 0 {
		delete(c.path, c.allocator)
	}
	c^ = {
		fd = prim.INVALID_FD,
	}
}

slots_get :: proc(c: ^Slots, key: u64) -> (child: i64, seal: i64, err: Error) {
	if key == 0 {
		return 0, 0, .Invalid
	}
	mask := c.slots - 1
	i := hash64(key) & mask
	for _ in 0 ..< c.slots {
		s, empty := _slot_read(c.vfs, c.fd, i) or_return
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

slots_put :: proc(c: ^Slots, key: u64, child: i64, seal: i64) -> Error {
	if key == 0 {
		return .Invalid
	}
	if (c.used + 1) * 2 > c.slots {
		_slots_mark(c) or_return
		_slots_grow(c) or_return
	}
	for {
		mask := c.slots - 1
		i := hash64(key) & mask
		for _ in 0 ..< c.slots {
			s, empty := _slot_read(c.vfs, c.fd, i) or_return
			if empty {
				_slots_mark(c) or_return
				_slot_write(c.vfs, c.fd, i, Slot{key, max(child, 0), max(seal, 0)}) or_return
				c.used += 1
				return .None
			}
			if s.key == key {
				next := Slot{key, max(s.child, child), seal if seal > 0 else s.seal}
				if next != s {
					_slots_mark(c) or_return
					_slot_write(c.vfs, c.fd, i, next) or_return
				}
				return .None
			}
			i = (i + 1) & mask
		}
		_slots_mark(c) or_return
		_slots_grow(c) or_return
	}
}

slots_sync :: proc(c: ^Slots) -> Error {
	if c.covered == c.synced && !c.marked {
		return .None
	}
	if err := prim.sync_owed(c.vfs, c.fd, &c.owed); err != .None {
		return perr(err)
	}
	if err := _header_write(c.vfs, c.fd, c.owner, c.slots, c.used, c.covered); err != .None {
		return err
	}
	if err := prim.sync_owed(c.vfs, c.fd, &c.owed); err != .None {
		return perr(err)
	}
	c.synced = c.covered
	c.marked = false
	return .None
}

@(private)
_slots_mark :: proc(c: ^Slots) -> Error {
	if c.marked {
		return .None
	}
	_header_write(c.vfs, c.fd, c.owner, c.slots, c.used, SLOT_DIRTY) or_return
	if err := prim.datasync(c.vfs, c.fd); err != .None {
		return perr(err)
	}
	c.marked = true
	return .None
}

@(private)
_slots_set_path :: proc(c: ^Slots, path: string) -> Error {
	p, err := make([]u8, len(path), c.allocator)
	if err != nil {
		return .No_Memory
	}
	copy(p, path)
	c.path = string(p)
	return .None
}

@(private)
hash64 :: proc "contextless" (key: u64) -> u64 {
	h := key * 0x9e37_79b9_7f4a_7c15
	h ~= h >> 29
	h *= 0xbf58_476d_1ce4_e5b9
	h ~= h >> 32
	return h
}

@(private)
_slot_check :: proc(b: []u8, i: u64) -> u64 {
	return xxhash.XXH3_64_with_seed(b[0:24], SLOT_SEED ~ (i + 1) * 0x9e37_79b9)
}

@(private)
_slot_decode :: proc(b: []u8, i: u64) -> (s: Slot, empty: bool, err: Error) {
	zero := true
	for x in b[:SLOT_SLOT] {
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
_slot_read :: proc(vfs: prim.Vfs, fd: prim.Fd, i: u64) -> (s: Slot, empty: bool, err: Error) {
	b: [SLOT_SLOT]u8
	n, rerr := prim.read_at(vfs, fd, b[:], i64(SLOT_HEADER + i * SLOT_SLOT))
	if rerr != .None {
		return {}, false, perr(rerr)
	}
	if n != SLOT_SLOT {
		return {}, false, .Corrupt
	}
	return _slot_decode(b[:], i)
}

@(private)
_slot_write :: proc(vfs: prim.Vfs, fd: prim.Fd, i: u64, s: Slot) -> Error {
	b: [SLOT_SLOT]u8
	prim.put_u64le(b[0:8], s.key)
	prim.put_u64le(b[8:16], u64(s.child))
	prim.put_u64le(b[16:24], u64(s.seal))
	prim.put_u64le(b[24:32], _slot_check(b[:], i))
	return perr(prim.write_at(vfs, fd, b[:], i64(SLOT_HEADER + i * SLOT_SLOT)))
}

@(private)
_header_write :: proc(vfs: prim.Vfs, fd: prim.Fd, owner: prim.Id, slots, used: u64, covered: i64) -> Error {
	h: [64]u8
	prim.put_u64le(h[0:8], SLOT_MAGIC)
	prim.put_u32le(h[8:12], SLOT_VERSION)
	t := owner
	copy(h[16:32], t[:])
	prim.put_u64le(h[32:40], slots)
	prim.put_u64le(h[40:48], used)
	prim.put_u64le(h[48:56], u64(covered))
	prim.put_u64le(h[56:64], xxhash.XXH3_64_with_seed(h[0:56], SLOT_SEED))
	return perr(prim.write_at(vfs, fd, h[:], 0))
}

@(private)
_slots_tmp_path :: proc(path: string, buf: ^prim.Path_Buf) -> (string, Error) {
	if len(path) + 4 >= len(buf) {
		return "", .Invalid
	}
	n := copy(buf[:], path)
	n += copy(buf[n:], ".new")
	return string(buf[:n]), .None
}

@(private)
_slots_fresh :: proc(vfs: prim.Vfs, path: string, owner: prim.Id, slots: u64) -> (fd: prim.Fd, err: Error) {
	buf: prim.Path_Buf
	tmp := _slots_tmp_path(path, &buf) or_return
	fd = _slots_blank(vfs, tmp, owner, slots, 0) or_return
	if e := prim.datasync(vfs, fd); e != .None {
		prim.close_file(vfs, fd)
		return prim.INVALID_FD, perr(e)
	}
	if e := prim.rename(vfs, tmp, path); e != .None {
		prim.close_file(vfs, fd)
		return prim.INVALID_FD, perr(e)
	}
	if e := prim.sync_dir(vfs, prim.dir_name(path)); e != .None {
		prim.close_file(vfs, fd)
		return prim.INVALID_FD, perr(e)
	}
	return fd, .None
}

@(private)
_slots_blank :: proc(vfs: prim.Vfs, path: string, owner: prim.Id, slots: u64, covered: i64) -> (fd: prim.Fd, err: Error) {
	f, oerr := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return prim.INVALID_FD, perr(oerr)
	}
	if e := prim.truncate(vfs, f, i64(SLOT_HEADER + slots * SLOT_SLOT)); e != .None {
		prim.close_file(vfs, f)
		return prim.INVALID_FD, perr(e)
	}
	if e := _header_write(vfs, f, owner, slots, 0, covered); e != .None {
		prim.close_file(vfs, f)
		return prim.INVALID_FD, e
	}
	return f, .None
}

@(private)
_slots_grow :: proc(c: ^Slots) -> Error {
	buf: prim.Path_Buf
	tmp := _slots_tmp_path(c.path, &buf) or_return
	slots := c.slots * 2
	if slots > 1 << 40 {
		return .Limit
	}
	nfd := _slots_blank(c.vfs, tmp, c.owner, slots, SLOT_DIRTY) or_return
	ok := false
	defer if !ok {
		prim.close_file(c.vfs, nfd)
		prim.remove(c.vfs, tmp)
	}
	chunk: [SLOT_COPY]u8
	used: u64
	mask := slots - 1
	for base: u64 = 0; base < c.slots; base += SLOT_COPY / SLOT_SLOT {
		count := min(SLOT_COPY / SLOT_SLOT, c.slots - base)
		want := int(count * SLOT_SLOT)
		n, rerr := prim.read_at(c.vfs, c.fd, chunk[:want], i64(SLOT_HEADER + base * SLOT_SLOT))
		if rerr != .None {
			return perr(rerr)
		}
		if n != want {
			return .Corrupt
		}
		for k in 0 ..< count {
			s, empty := _slot_decode(chunk[k * SLOT_SLOT:][:SLOT_SLOT], base + k) or_return
			if empty {
				continue
			}
			i := hash64(s.key) & mask
			for {
				_, e := _slot_read(c.vfs, nfd, i) or_return
				if e {
					break
				}
				i = (i + 1) & mask
			}
			_slot_write(c.vfs, nfd, i, s) or_return
			used += 1
		}
	}
	if e := _header_write(c.vfs, nfd, c.owner, slots, used, SLOT_DIRTY); e != .None {
		return e
	}
	if e := prim.datasync(c.vfs, nfd); e != .None {
		return perr(e)
	}
	if e := prim.rename(c.vfs, tmp, c.path); e != .None {
		return perr(e)
	}
	ok = true
	prim.close_file(c.vfs, c.fd)
	c.fd = nfd
	c.slots = slots
	c.used = used
	c.synced = c.covered
	if e := prim.sync_dir(c.vfs, prim.dir_name(c.path)); e != .None {
		return perr(e)
	}
	return .None
}

slots_each :: proc(c: ^Slots, data: rawptr, visit: proc(data: rawptr, key: u64, child, seal: i64) -> bool) -> Error {
	for i in 0 ..< c.slots {
		s, empty := _slot_read(c.vfs, c.fd, i) or_return
		if empty {
			continue
		}
		if !visit(data, s.key, s.child, s.seal) {
			return .None
		}
	}
	return .None
}

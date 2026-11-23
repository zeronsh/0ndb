package odb

import "core:encoding/endian"
import "core:io"
import "../prim"

@(private)
IDX_HEADER :: 8 + 256 * 4

@(private)
MAX_DELTA_DEPTH :: 4096

@(private)
OBJ_OFS_DELTA :: 6

@(private)
OBJ_REF_DELTA :: 7

@(private)
Pack :: struct {
	id:         u32,
	hsz:        int,
	base:       string,
	idx:        []u8,
	idx_mapped: bool,
	data:       []u8,
	fd:         prim.Fd,
	size:       i64,
	opened:     bool,
	count:      int,
	names:      int,
	crcs:       int,
	offs32:     int,
	offs64:     int,
	n64:        int,
	failed:     bool,
	present:    bool,
	freshened:  bool,
	staged:     bool,
	data_tmp:   bool,
	data_at:    string,
}

@(private)
Entry_Header :: struct {
	kind:     u8,
	size:     i64,
	start:    i64,
	base_off: i64,
	base_oid: Oid,
}

@(private)
pack_validate_idx :: proc(p: ^Pack) -> bool {
	idx := p.idx
	hsz := p.hsz
	if len(idx) < IDX_HEADER + 2 * hsz {
		return false
	}
	if idx[0] != 0xff || idx[1] != 't' || idx[2] != 'O' || idx[3] != 'c' {
		return false
	}
	if endian.unchecked_get_u32be(idx[4:]) != 2 {
		return false
	}
	prev: u32
	for i in 0 ..< 256 {
		v := endian.unchecked_get_u32be(idx[8 + i * 4:])
		if v < prev {
			return false
		}
		prev = v
	}
	count := int(prev)
	end := len(idx) - 2 * hsz
	if count > (end - IDX_HEADER) / (hsz + 8) {
		return false
	}
	p.count = count
	p.names = IDX_HEADER
	p.crcs = p.names + hsz * count
	p.offs32 = p.crcs + 4 * count
	p.offs64 = p.offs32 + 4 * count
	rest := end - p.offs64
	if rest < 0 || rest % 8 != 0 {
		return false
	}
	p.n64 = rest / 8
	return true
}

@(private)
pack_fanout :: #force_inline proc(p: ^Pack, b: int) -> int {
	return int(endian.unchecked_get_u32be(p.idx[8 + b * 4:]))
}

@(private)
pack_find :: proc(p: ^Pack, oid: Oid) -> (pos: int, found: bool) #no_bounds_check {
	if p.failed {
		return 0, false
	}
	first := int(oid[0])
	lo := 0 if first == 0 else pack_fanout(p, first - 1)
	hi := pack_fanout(p, first)
	oid := oid
	hsz := p.hsz
	for lo < hi {
		mid := lo + (hi - lo) / 2
		name := p.idx[p.names + mid * hsz:][:hsz]
		c := 0
		for i in 0 ..< hsz {
			if name[i] != oid[i] {
				c = -1 if name[i] < oid[i] else 1
				break
			}
		}
		switch {
		case c == 0:
			return mid, true
		case c < 0:
			lo = mid + 1
		case:
			hi = mid
		}
	}
	return lo, false
}

@(private)
pack_oid_at :: proc(p: ^Pack, i: int) -> (oid: Oid) {
	copy(oid[:], p.idx[p.names + i * p.hsz:][:p.hsz])
	return
}

@(private)
pack_offset_at :: proc(p: ^Pack, i: int) -> (i64, Error) {
	v := endian.unchecked_get_u32be(p.idx[p.offs32 + i * 4:])
	if v & 0x8000_0000 == 0 {
		return i64(v), .None
	}
	j := int(v & 0x7fff_ffff)
	if j >= p.n64 {
		return 0, .Corrupt
	}
	off := endian.unchecked_get_u64be(p.idx[p.offs64 + j * 8:])
	if off > u64(max(i64)) {
		return 0, .Corrupt
	}
	return i64(off), .None
}

@(private)
pack_open_data :: proc(db: ^Odb, p: ^Pack) -> Error {
	if p.opened {
		return .None
	}
	if p.failed {
		return .Corrupt
	}
	buf: [PATH_MAX]u8
	path := p.data_at
	if !p.data_tmp {
		path = concat_into(buf[:], p.base, ".pack") or_return
	}
	if db.use_mmap && vfs_is_os(db.vfs) {
		data, merr := vfs_map_path(db.vfs, path)
		if merr != .None {
			p.failed = true
			return merr
		}
		p.data = data
		p.size = i64(len(data))
	} else {
		fd, e := prim.open_file(db.vfs, path)
		if e != .None {
			p.failed = true
			return perr(e)
		}
		size, serr := vfs_size(db.vfs, fd)
		if serr != .None {
			prim.close_file(db.vfs, fd)
			return serr
		}
		p.fd = fd
		p.size = size
	}
	p.opened = true
	head: [12]u8
	tail: [32]u8
	ok := p.size >= i64(12 + p.hsz)
	if ok {
		h, herr := pack_view(db, p, 0, 12, head[:], true)
		t, terr := pack_view(db, p, p.size - i64(p.hsz), p.hsz, tail[:], true)
		ok = herr == .None && terr == .None && len(h) == 12 && len(t) == p.hsz && string(h[:4]) == "PACK"
		if ok {
			version := endian.unchecked_get_u32be(h[4:])
			ok = (version == 2 || version == 3) && int(endian.unchecked_get_u32be(h[8:])) == p.count
			ok = ok && string(t) == string(p.idx[len(p.idx) - 2 * p.hsz:][:p.hsz])
		}
	}
	if !ok {
		pack_close(db, p)
		p.failed = true
		return .Corrupt
	}
	return .None
}

@(private)
pack_view :: proc(db: ^Odb, p: ^Pack, off: i64, n: int, buf: []u8, whole := false) -> ([]u8, Error) {
	end := p.size if whole else p.size - i64(p.hsz)
	if off < 0 || off > end {
		return nil, .Corrupt
	}
	k := int(min(i64(n), end - off))
	if p.data != nil {
		return p.data[off:off + i64(k)], .None
	}
	k = min(k, len(buf))
	got, e := prim.read_at(db.vfs, p.fd, buf[:k], off)
	if e != .None {
		return nil, perr(e)
	}
	return buf[:got], .None
}

@(private)
pack_close :: proc(db: ^Odb, p: ^Pack) {
	if p.data != nil {
		prim.unmap_file(p.data)
		p.data = nil
	}
	if p.opened && p.fd != prim.INVALID_FD && p.fd != 0 {
		prim.close_file(db.vfs, p.fd)
	}
	p.fd = prim.INVALID_FD
	p.opened = false
	if p.idx != nil {
		if p.idx_mapped {
			prim.unmap_file(p.idx)
		} else {
			delete(p.idx, db.allocator)
		}
		p.idx = nil
	}
}

@(private)
pack_entry_header :: proc(db: ^Odb, p: ^Pack, offset: i64) -> (h: Entry_Header, err: Error) #no_bounds_check {
	end := p.size - i64(p.hsz)
	if offset < 12 || offset >= end {
		return h, .Corrupt
	}
	buf: [96]u8
	d := pack_view(db, p, offset, len(buf), buf[:]) or_return
	pos := 0
	if pos >= len(d) {
		return h, .Corrupt
	}
	c := d[pos]
	pos += 1
	h.kind = (c >> 4) & 7
	size := u64(c & 15)
	shift: uint = 4
	for c & 0x80 != 0 {
		if pos >= len(d) || shift > 56 {
			return h, .Corrupt
		}
		c = d[pos]
		pos += 1
		size |= u64(c & 0x7f) << shift
		shift += 7
	}
	if size > u64(max(i64)) {
		return h, .Corrupt
	}
	h.size = i64(size)
	switch h.kind {
	case 1 ..= 4:
	case OBJ_OFS_DELTA:
		if pos >= len(d) {
			return h, .Corrupt
		}
		c = d[pos]
		pos += 1
		rel := u64(c & 0x7f)
		for c & 0x80 != 0 {
			if pos >= len(d) || rel >= 1 << 56 {
				return h, .Corrupt
			}
			c = d[pos]
			pos += 1
			rel = ((rel + 1) << 7) | u64(c & 0x7f)
		}
		if rel == 0 || rel >= u64(offset) {
			return h, .Corrupt
		}
		h.base_off = offset - i64(rel)
	case OBJ_REF_DELTA:
		if pos + p.hsz > len(d) {
			return h, .Corrupt
		}
		copy(h.base_oid[:p.hsz], d[pos:pos + p.hsz])
		pos += p.hsz
	case:
		return h, .Corrupt
	}
	h.start = offset + i64(pos)
	if h.start >= end {
		return h, .Corrupt
	}
	return h, .None
}

@(private)
pack_compressed_avail :: proc(p: ^Pack, h: Entry_Header) -> int {
	return int(p.size - i64(p.hsz) - h.start)
}

@(private)
Pack_Src :: struct {
	db:  ^Odb,
	p:   ^Pack,
	pos:  i64,
	buf:  []u8,
	full: []u8,
}

@(private)
pack_src_refill :: proc(data: rawptr) -> (chunk: []u8, err: Error) {
	ps := (^Pack_Src)(data)
	chunk = pack_view(ps.db, ps.p, ps.pos, len(ps.buf), ps.buf) or_return
	ps.pos += i64(len(chunk))
	if ps.full != nil {
		ps.buf = ps.full
	}
	return chunk, .None
}

@(private)
pack_inflate_exact :: proc(db: ^Odb, p: ^Pack, h: Entry_Header, out: []u8) -> Error {
	if p.data != nil {
		return inflate_exact(p.data[h.start:p.size - i64(p.hsz)], out)
	}
	buf: [IO_CHUNK]u8
	first := clamp(len(out) + 64, 256, IO_CHUNK)
	ps := Pack_Src{db, p, h.start, buf[:first], buf[:]}
	return inflate_exact(nil, out, pack_src_refill, &ps)
}

@(private)
pack_inflate_prefix :: proc(db: ^Odb, p: ^Pack, h: Entry_Header, out: []u8) -> (int, Error) {
	if p.data != nil {
		return inflate_prefix(p.data[h.start:p.size - i64(p.hsz)], out)
	}
	buf: [512]u8
	ps := Pack_Src{db, p, h.start, buf[:], nil}
	return inflate_prefix(nil, out, pack_src_refill, &ps)
}

@(private)
pack_inflate_to_writer :: proc(db: ^Odb, p: ^Pack, h: Entry_Header, w: io.Writer, window: []u8) -> Error {
	if p.data != nil {
		_, err := inflate_to_writer(p.data[h.start:p.size - i64(p.hsz)], nil, nil, w, h.size, window)
		return err
	}
	buf: [IO_CHUNK]u8
	ps := Pack_Src{db, p, h.start, buf[:], nil}
	_, err := inflate_to_writer(nil, pack_src_refill, &ps, w, h.size, window)
	return err
}

@(private)
delta_varint :: proc(d: []u8, pos: ^int) -> (v: u64, ok: bool) {
	shift: uint
	for {
		if pos^ >= len(d) || shift > 56 {
			return 0, false
		}
		c := d[pos^]
		pos^ += 1
		v |= u64(c & 0x7f) << shift
		shift += 7
		if c & 0x80 == 0 {
			return v, true
		}
	}
}

@(private)
delta_sizes :: proc(d: []u8) -> (base_size, result_size: i64, pos: int, err: Error) {
	b, b_ok := delta_varint(d, &pos)
	r, r_ok := delta_varint(d, &pos)
	if !b_ok || !r_ok || b > u64(max(i64)) || r > u64(max(i64)) {
		return 0, 0, 0, .Corrupt
	}
	return i64(b), i64(r), pos, .None
}

@(private)
apply_delta :: proc(base, delta, out: []u8, start: int) -> Error #no_bounds_check {
	p := start
	o := 0
	for p < len(delta) {
		c := delta[p]
		p += 1
		if c & 0x80 != 0 {
			off, size: int
			for bit in uint(0) ..< 4 {
				if c & (1 << bit) != 0 {
					if p >= len(delta) {
						return .Corrupt
					}
					off |= int(delta[p]) << (8 * bit)
					p += 1
				}
			}
			for bit in uint(0) ..< 3 {
				if c & (0x10 << bit) != 0 {
					if p >= len(delta) {
						return .Corrupt
					}
					size |= int(delta[p]) << (8 * bit)
					p += 1
				}
			}
			if size == 0 {
				size = 0x10000
			}
			if off + size > len(base) || o + size > len(out) {
				return .Corrupt
			}
			copy(out[o:o + size], base[off:off + size])
			o += size
		} else if c != 0 {
			n := int(c)
			if p + n > len(delta) || o + n > len(out) {
				return .Corrupt
			}
			copy(out[o:o + n], delta[p:p + n])
			o += n
			p += n
		} else {
			return .Corrupt
		}
	}
	return .None if o == len(out) else .Corrupt
}

package pack

import "../prim"

MAX_EXTENTS :: 32
@(private)
EXT_CAP :: MAX_EXTENTS * 2 + 8
MAX_SYMLINK :: 1024
MAX_NAME :: 255

Kind :: enum u8 {
	None,
	File,
	Dir,
	Symlink,
	External,
}

Extent :: struct {
	off:  i64,
	len:  i64,
	cont: u32,
	coff: i64,
}

@(private)
Phys :: struct {
	cont: u32,
	off:  i64,
	len:  i64,
	foff: i64,
}

Inode :: struct {
	kind:   Kind,
	stale:  bool,
	mode:   u32,
	mtime:  i64,
	size:   i64,
	n:      int,
	ext:    [EXT_CAP]Extent,
	tlen:   int,
	target: [MAX_SYMLINK]u8,
}

@(private)
_inode_encode :: proc(ino: ^Inode, out: ^[dynamic]u8) -> bool {
	clear(out)
	w := prim.writer(out)
	prim.write_u8(&w, u8(ino.kind))
	prim.write_u8(&w, 1 if ino.stale else 0)
	prim.write_uvarint(&w, u64(ino.mode))
	prim.write_uvarint(&w, u64(max(ino.mtime, 0)))
	#partial switch ino.kind {
	case .File:
		prim.write_uvarint(&w, u64(ino.size))
		prim.write_uvarint(&w, u64(ino.n))
		prev: i64
		for e in ino.ext[:ino.n] {
			prim.write_uvarint(&w, u64(e.off - prev))
			prim.write_uvarint(&w, u64(e.len))
			prim.write_uvarint(&w, u64(e.cont))
			prim.write_uvarint(&w, u64(e.coff))
			prev = e.off + e.len
		}
	case .Symlink:
		prim.write_bytes(&w, ino.target[:ino.tlen])
	}
	return w.err == .None
}

@(private)
_inode_decode :: proc(b: []u8, ino: ^Inode) -> bool {
	r := prim.reader(b)
	ino.kind = Kind(prim.read_u8(&r))
	flags := prim.read_u8(&r)
	if flags > 1 {
		return false
	}
	ino.stale = flags == 1
	mode := prim.read_uvarint(&r)
	mtime := prim.read_uvarint(&r)
	if r.err != .None || mode > u64(max(u32)) || mtime > u64(max(i64)) {
		return false
	}
	ino.mode = u32(mode)
	ino.mtime = i64(mtime)
	ino.size = 0
	ino.n = 0
	ino.tlen = 0
	switch ino.kind {
	case .File:
		size := prim.read_uvarint(&r)
		n := prim.read_uvarint(&r)
		if r.err != .None || size > u64(max(i64)) || n > EXT_CAP {
			return false
		}
		ino.size = i64(size)
		prev: i64
		for i in 0 ..< int(n) {
			gap := prim.read_uvarint(&r)
			l := prim.read_uvarint(&r)
			c := prim.read_uvarint(&r)
			o := prim.read_uvarint(&r)
			if r.err != .None || l == 0 || gap > u64(ino.size) || l > u64(ino.size) || c > u64(max(u32)) || o > u64(max(i64)) {
				return false
			}
			off := prev + i64(gap)
			if off + i64(l) > ino.size {
				return false
			}
			ino.ext[i] = Extent{off = off, len = i64(l), cont = u32(c), coff = i64(o)}
			prev = off + i64(l)
		}
		ino.n = int(n)
	case .Symlink:
		t := prim.read_bytes(&r)
		if r.err != .None || len(t) > MAX_SYMLINK {
			return false
		}
		ino.tlen = copy(ino.target[:], t)
	case .Dir, .External:
	case .None:
		return false
	}
	return prim.reader_done(&r)
}

@(private)
PHYS_CAP :: EXT_CAP * 2 + 8

@(private)
Phys_List :: struct {
	n: int,
	a: [PHYS_CAP]Phys,
}

@(private)
_pl_push :: proc "contextless" (l: ^Phys_List, ph: Phys) {
	if ph.len <= 0 || l.n >= PHYS_CAP {
		return
	}
	l.a[l.n] = ph
	l.n += 1
}

@(private)
_ext_remove :: proc "contextless" (ino: ^Inode, from, to: i64, removed: ^Phys_List) {
	if to <= from {
		return
	}
	out: [EXT_CAP]Extent
	k := 0
	for e in ino.ext[:ino.n] {
		e_end := e.off + e.len
		if e_end <= from || e.off >= to {
			out[k] = e
			k += 1
			continue
		}
		if e.off < from {
			out[k] = Extent{off = e.off, len = from - e.off, cont = e.cont, coff = e.coff}
			k += 1
		}
		cut_lo := max(e.off, from)
		cut_hi := min(e_end, to)
		_pl_push(removed, Phys{cont = e.cont, off = e.coff + (cut_lo - e.off), len = cut_hi - cut_lo, foff = cut_lo})
		if e_end > to {
			out[k] = Extent{off = to, len = e_end - to, cont = e.cont, coff = e.coff + (to - e.off)}
			k += 1
		}
	}
	copy(ino.ext[:], out[:k])
	ino.n = k
}

@(private)
_ext_insert :: proc "contextless" (ino: ^Inode, ne: Extent) -> bool {
	i := 0
	for i < ino.n && ino.ext[i].off < ne.off {
		i += 1
	}
	if i > 0 {
		p := &ino.ext[i - 1]
		if p.cont == ne.cont && p.off + p.len == ne.off && p.coff + p.len == ne.coff {
			p.len += ne.len
			if i < ino.n {
				q := ino.ext[i]
				if q.cont == p.cont && p.off + p.len == q.off && p.coff + p.len == q.coff {
					p.len += q.len
					copy(ino.ext[i:], ino.ext[i + 1:ino.n])
					ino.n -= 1
				}
			}
			return true
		}
	}
	if ino.n >= EXT_CAP {
		return false
	}
	copy(ino.ext[i + 1:], ino.ext[i:ino.n])
	ino.ext[i] = ne
	ino.n += 1
	return true
}

@(private)
_phys_of :: proc "contextless" (ino: ^Inode, out: ^Phys_List) {
	if ino.kind != .File {
		return
	}
	for e in ino.ext[:ino.n] {
		_pl_push(out, Phys{cont = e.cont, off = e.coff, len = e.len, foff = e.off})
	}
}

@(private)
_phys_diff :: proc "contextless" (old: []Phys, new: []Phys, out: ^Phys_List) {
	for o in old {
		cuts: [PHYS_CAP]Phys
		nc := 0
		for n in new {
			if n.cont == o.cont && n.off < o.off + o.len && o.off < n.off + n.len && nc < PHYS_CAP {
				j := nc
				for j > 0 && cuts[j - 1].off > n.off {
					cuts[j] = cuts[j - 1]
					j -= 1
				}
				cuts[j] = n
				nc += 1
			}
		}
		pos := o.off
		end := o.off + o.len
		for c in cuts[:nc] {
			if c.off > pos {
				_pl_push(out, Phys{cont = o.cont, off = pos, len = min(c.off, end) - pos, foff = o.foff + (pos - o.off)})
			}
			pos = max(pos, c.off + c.len)
			if pos >= end {
				break
			}
		}
		if pos < end {
			_pl_push(out, Phys{cont = o.cont, off = pos, len = end - pos, foff = o.foff + (pos - o.off)})
		}
	}
}

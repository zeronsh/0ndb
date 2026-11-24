package pack

@(private)
IMG_BLOCK :: 512

@(private)
Image :: struct {
	data:  []u8,
	dirty: []u64,
	any:   bool,
}

@(private)
_img_cost :: proc "contextless" (p: ^Pack) -> int {
	return int(p.opts.promote_size)
}

@(private)
_img_open :: proc(p: ^Pack, oi: ^Open_Inode) -> Error {
	if oi.img != nil {
		return .None
	}
	if p.img_bytes + _img_cost(p) > p.opts.mem_budget {
		_img_settle_all(p) or_return
	}
	img := new(Image, p.allocator)
	if img == nil {
		return .No_Memory
	}
	img.data = make([]u8, int(p.opts.promote_size), p.allocator)
	img.dirty = make([]u64, (int(p.opts.promote_size) / IMG_BLOCK + 64) / 64 + 1, p.allocator)
	if img.data == nil || img.dirty == nil {
		_img_free(p, img)
		return .No_Memory
	}
	for e in oi.ino.ext[:oi.ino.n] {
		if e.off >= i64(len(img.data)) {
			continue
		}
		n := min(e.len, i64(len(img.data)) - e.off)
		if err := _phys_read(p, Phys{cont = e.cont, off = e.coff, len = n}, img.data[e.off:][:n]); err != .None {
			_img_free(p, img)
			return err
		}
	}
	oi.img = img
	p.img_bytes += _img_cost(p)
	append(&p.imgs, oi)
	return .None
}

@(private)
_img_free :: proc(p: ^Pack, img: ^Image) {
	delete(img.data, p.allocator)
	delete(img.dirty, p.allocator)
	free(img, p.allocator)
}

@(private)
_img_drop :: proc(p: ^Pack, oi: ^Open_Inode) {
	if oi.img == nil {
		return
	}
	if oi.img.any {
		p.img_dirty -= 1
	}
	_img_free(p, oi.img)
	oi.img = nil
	p.img_bytes -= _img_cost(p)
	for x, i in p.imgs {
		if x == oi {
			ordered_remove(&p.imgs, i)
			break
		}
	}
}

@(private)
_img_write :: proc(p: ^Pack, oi: ^Open_Inode, src: []u8, off: i64) {
	img := oi.img
	copy(img.data[off:], src)
	if !img.any {
		img.any = true
		p.img_dirty += 1
	}
	first := int(off) / IMG_BLOCK
	last := (int(off) + len(src) - 1) / IMG_BLOCK
	for b in first ..= last {
		img.dirty[b / 64] |= 1 << u64(b % 64)
	}
	oi.ino.size = max(oi.ino.size, off + i64(len(src)))
}

@(private)
_img_dirty_at :: #force_inline proc "contextless" (img: ^Image, b: int) -> bool {
	return img.dirty[b / 64] & (1 << u64(b % 64)) != 0
}

@(private)
_img_next :: proc(img: ^Image, from: int, size: int) -> (lo: int, hi: int, ok: bool) {
	b := (from + IMG_BLOCK - 1) / IMG_BLOCK
	blocks := (size + IMG_BLOCK - 1) / IMG_BLOCK
	for b < blocks && !_img_dirty_at(img, b) {
		b += 1
	}
	if b >= blocks {
		return 0, 0, false
	}
	lo = b * IMG_BLOCK
	for b < blocks && _img_dirty_at(img, b) {
		b += 1
	}
	hi = min(b * IMG_BLOCK, size)
	return lo, hi, true
}

@(private)
_img_settle :: proc(p: ^Pack, oi: ^Open_Inode) -> Error {
	img := oi.img
	if img == nil {
		return .None
	}
	size := int(oi.ino.size)
	if !img.any || size == 0 {
		_img_drop(p, oi)
		return .None
	}
	old := oi.ino
	sim := old
	runs := 0
	whole := false
	scratch: Phys_List
	from := 0
	for {
		lo, hi, ok := _img_next(img, from, size)
		if !ok {
			break
		}
		if sim.n > EXT_CAP - 3 {
			whole = true
			break
		}
		_ext_remove(&sim, i64(lo), i64(hi), &scratch)
		if !_ext_insert(&sim, Extent{off = i64(lo), len = i64(hi - lo), cont = ~u32(0), coff = i64(runs) << 32}) {
			whole = true
			break
		}
		runs += 1
		from = hi
	}
	nw := &oi.ino
	if whole || sim.n > MAX_EXTENTS * 3 / 4 {
		ph := _log_data(p, oi.inum, 0, img.data[:size]) or_return
		nw.n = 1
		nw.ext[0] = Extent{off = 0, len = i64(size), cont = ph.cont, coff = ph.off}
	} else {
		at := 0
		for {
			lo, hi, ok := _img_next(img, at, size)
			if !ok {
				break
			}
			ph := _log_data(p, oi.inum, i64(lo), img.data[lo:hi]) or_return
			_ext_remove(nw, i64(lo), i64(hi), &scratch)
			if !_ext_insert(nw, Extent{off = i64(lo), len = i64(hi - lo), cont = ph.cont, coff = ph.off}) {
				oi.ino = old
				return .Io
			}
			at = hi
		}
	}
	nw.mtime = _now(p)
	_img_drop(p, oi)
	return _inode_store(p, oi.inum, &old, nw)
}

@(private)
_img_settle_all :: proc(p: ^Pack) -> Error {
	for len(p.imgs) > 0 {
		_img_settle(p, p.imgs[len(p.imgs) - 1]) or_return
	}
	return .None
}

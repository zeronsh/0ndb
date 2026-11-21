package pack

import "core:hash/xxhash"
import "core:mem/virtual"
import "../prim"

BLOCK :: 4096
@(private)
BLOCK_HDR :: 7
@(private)
RESTART :: 16
@(private)
MAX_RESTARTS :: BLOCK / 4
@(private)
BLOCK_END :: BLOCK - 4
@(private)
BT_DATA :: u8(1)
@(private)
BT_INDEX :: u8(2)
@(private)
BT_FOOTER :: u8(3)
@(private)
BT_FILTER :: u8(4)
@(private)
BT_FINDEX :: u8(5)
@(private)
FLINES :: 63
@(private)
FBYTES :: FLINES * 64
@(private)
FBITS_PER_KEY :: 10
@(private)
FKEYS :: FBYTES * 8 / FBITS_PER_KEY
@(private)
FPROBES :: 7
@(private)
RUN_MAGIC :: u64(0x6e75_726b_6370_6e30)
@(private)
MAX_DEPTH :: 8
@(private)
MAX_KEY :: 512
@(private)
OUT_BUF :: 64 * 1024

@(private)
Run :: struct {
	id:       u32,
	level:    u8,
	depth:    u8,
	root:     u32,
	nblocks:  u32,
	nentries: u64,
	fd:       prim.Fd,
	root_buf: []u8,
	fkeys:    [dynamic]u8,
	fents:    [dynamic]Fpart,
	fres:     []u8,
}

@(private)
Fpart :: struct {
	koff: u32,
	klen: u32,
	blk:  u32,
}

@(private)
Level_Builder :: struct {
	buf:     [BLOCK]u8,
	pos:     int,
	count:   int,
	last:    [MAX_KEY]u8,
	lastlen: int,
	emitted: int,
	rst:     [MAX_RESTARTS]u16,
	nr:      int,
}

@(private)
Builder :: struct {
	vfs:      prim.Vfs,
	fd:       prim.Fd,
	levels:   [MAX_DEPTH + 1]Level_Builder,
	out:      []u8,
	out_len:  int,
	out_base: i64,
	nblocks:  u32,
	nentries: u64,
	err:      Error,
	fh:       [FKEYS]u64,
	fn:       int,
	flast:    [MAX_KEY]u8,
	flastlen: int,
	fparts:   [dynamic]u8,
	nparts:   u32,
}

@(private)
_block_seal :: proc(b: []u8, kind: u8, count: int, end: int, rst: []u16) {
	b[0] = kind
	b[1] = u8(count)
	b[2] = u8(count >> 8)
	b[3] = u8(end)
	b[4] = u8(end >> 8)
	b[5] = u8(len(rst))
	b[6] = u8(len(rst) >> 8)
	p := end
	for r in rst {
		b[p] = u8(r)
		b[p + 1] = u8(r >> 8)
		p += 2
	}
	for i in p ..< BLOCK_END {
		b[i] = 0
	}
	prim.put_u32le(b[BLOCK_END:], u32(xxhash.XXH3_64_with_seed(b[:BLOCK_END], 0x626c6b)))
}

@(private)
_block_ok :: proc(b: []u8) -> bool {
	if len(b) != BLOCK {
		return false
	}
	if prim.get_u32le(b[BLOCK_END:]) != u32(xxhash.XXH3_64_with_seed(b[:BLOCK_END], 0x626c6b)) {
		return false
	}
	end := int(b[3]) | int(b[4]) << 8
	nr := int(b[5]) | int(b[6]) << 8
	return end >= BLOCK_HDR && end + 2 * nr <= BLOCK_END
}

@(private)
_builder_init :: proc(bd: ^Builder, vfs: prim.Vfs, fd: prim.Fd) -> Error {
	bd^ = {}
	bd.vfs = vfs
	bd.fd = fd
	out, err := make([]u8, OUT_BUF, context.allocator)
	if err != nil {
		return .No_Memory
	}
	bd.out = out
	for &l in bd.levels {
		l.pos = BLOCK_HDR
	}
	return .None
}

@(private)
_builder_destroy :: proc(bd: ^Builder) {
	if bd.out != nil {
		delete(bd.out)
		bd.out = nil
	}
	delete(bd.fparts)
	bd.fparts = nil
}

@(private)
_fline :: #force_inline proc "contextless" (h: u64) -> int {
	return int(((h >> 32) * FLINES) >> 32)
}

@(private)
_fset :: proc "contextless" (bits: []u8, h: u64) {
	line := bits[_fline(h) * 64:][:64]
	h1 := u32(h)
	h2 := u32(h >> 32) | 1
	for j in 0 ..< u32(FPROBES) {
		b := (h1 + j * h2) & 511
		line[b >> 3] |= 1 << (b & 7)
	}
}

@(private)
_ftest :: proc "contextless" (bits: []u8, h: u64) -> bool {
	line := bits[_fline(h) * 64:][:64]
	h1 := u32(h)
	h2 := u32(h >> 32) | 1
	for j in 0 ..< u32(FPROBES) {
		b := (h1 + j * h2) & 511
		if line[b >> 3] & (1 << (b & 7)) == 0 {
			return false
		}
	}
	return true
}

@(private)
_fhash :: #force_inline proc(key: []u8) -> u64 {
	return xxhash.XXH3_64_with_seed(key, 0x66696c74)
}

@(private)
_filter_flush :: proc(bd: ^Builder) {
	if bd.fn == 0 {
		return
	}
	blk: [BLOCK]u8
	bits := blk[BLOCK_HDR:][:FBYTES]
	for h in bd.fh[:bd.fn] {
		_fset(bits, h)
	}
	_block_seal(blk[:], BT_FILTER, bd.fn, BLOCK_HDR + FBYTES, nil)
	no := _builder_emit(bd, blk[:])
	vb: [10]u8
	n := prim.put_uvarint(vb[:], u64(bd.flastlen))
	append(&bd.fparts, ..vb[:n])
	append(&bd.fparts, ..bd.flast[:bd.flastlen])
	n = prim.put_uvarint(vb[:], u64(no))
	append(&bd.fparts, ..vb[:n])
	bd.nparts += 1
	bd.fn = 0
}

@(private)
_filter_index :: proc(bd: ^Builder) -> (first: u32, count: u32) {
	first = bd.nblocks
	blk: [BLOCK]u8
	pos := BLOCK_HDR
	cnt := 0
	r := prim.reader(bd.fparts[:])
	for prim.reader_remaining(&r) > 0 {
		start := r.pos
		kl := prim.read_uvarint(&r)
		prim.read_raw(&r, int(kl))
		prim.read_uvarint(&r)
		if r.err != .None {
			bd.err = .Io
			return
		}
		ent := bd.fparts[start:r.pos]
		if pos + len(ent) > BLOCK_END {
			_block_seal(blk[:], BT_FINDEX, cnt, pos, nil)
			_builder_emit(bd, blk[:])
			count += 1
			pos = BLOCK_HDR
			cnt = 0
		}
		copy(blk[pos:], ent)
		pos += len(ent)
		cnt += 1
	}
	if cnt > 0 {
		_block_seal(blk[:], BT_FINDEX, cnt, pos, nil)
		_builder_emit(bd, blk[:])
		count += 1
	}
	return
}

@(private)
_builder_emit :: proc(bd: ^Builder, block: []u8) -> u32 {
	if bd.out_len + BLOCK > len(bd.out) {
		_builder_drain(bd)
	}
	copy(bd.out[bd.out_len:], block)
	bd.out_len += BLOCK
	n := bd.nblocks
	bd.nblocks += 1
	return n
}

@(private)
_builder_drain :: proc(bd: ^Builder) {
	if bd.out_len == 0 {
		return
	}
	if bd.err == .None {
		if e := prim.write_at(bd.vfs, bd.fd, bd.out[:bd.out_len], bd.out_base); e != .None {
			bd.err = _perr(e)
		}
	}
	bd.out_base += i64(bd.out_len)
	bd.out_len = 0
}

@(private)
_entry_size :: proc "contextless" (shared, unshared, vlen: int, vword: u64) -> int {
	return prim.uvarint_len(u64(shared)) + prim.uvarint_len(u64(unshared)) + prim.uvarint_len(vword) + unshared + vlen
}

@(private)
_shared_prefix :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

@(private)
_level_add :: proc(bd: ^Builder, lvl: int, key: []u8, val: []u8, tomb: bool) {
	if lvl > MAX_DEPTH || len(key) > MAX_KEY {
		bd.err = .Invalid
		return
	}
	l := &bd.levels[lvl]
	vword := u64(len(val)) << 1 | (1 if tomb else 0)
	restart := l.count % RESTART == 0
	shared := 0 if restart else _shared_prefix(l.last[:l.lastlen], key)
	size := _entry_size(shared, len(key) - shared, len(val), vword)
	need := l.pos + size + 2 * (l.nr + (1 if restart else 0))
	if need > BLOCK_END && l.count > 0 {
		_level_finish(bd, lvl)
		restart = true
		shared = 0
		size = _entry_size(0, len(key), len(val), vword)
		need = l.pos + size + 2
	}
	if need > BLOCK_END || l.nr >= MAX_RESTARTS {
		bd.err = .Too_Large
		return
	}
	p := l.pos
	if restart {
		l.rst[l.nr] = u16(p)
		l.nr += 1
	}
	p += prim.put_uvarint(l.buf[p:], u64(shared))
	p += prim.put_uvarint(l.buf[p:], u64(len(key) - shared))
	p += prim.put_uvarint(l.buf[p:], vword)
	p += copy(l.buf[p:], key[shared:])
	p += copy(l.buf[p:], val)
	l.pos = p
	l.count += 1
	copy(l.last[:], key)
	l.lastlen = len(key)
}

@(private)
_level_finish :: proc(bd: ^Builder, lvl: int) -> u32 {
	l := &bd.levels[lvl]
	_block_seal(l.buf[:], BT_DATA if lvl == 0 else BT_INDEX, l.count, l.pos, l.rst[:l.nr])
	blk := _builder_emit(bd, l.buf[:])
	l.emitted += 1
	key: [MAX_KEY]u8
	n := l.lastlen
	copy(key[:], l.last[:n])
	l.pos = BLOCK_HDR
	l.count = 0
	l.lastlen = 0
	l.nr = 0
	vb: [10]u8
	vn := prim.put_uvarint(vb[:], u64(blk))
	if lvl < MAX_DEPTH {
		_level_add(bd, lvl + 1, key[:n], vb[:vn], false)
	}
	return blk
}

@(private)
_builder_add :: proc(bd: ^Builder, key: []u8, val: []u8, tomb: bool) {
	_level_add(bd, 0, key, val, tomb)
	bd.nentries += 1
	bd.fh[bd.fn] = _fhash(key)
	bd.fn += 1
	bd.flastlen = copy(bd.flast[:], key)
	if bd.fn == FKEYS {
		_filter_flush(bd)
	}
}

@(private)
_builder_finish :: proc(bd: ^Builder, level: u8) -> (r: Run, err: Error) {
	if bd.nentries == 0 {
		return {}, .Invalid
	}
	root: u32
	depth := 0
	if bd.levels[0].count > 0 {
		_level_finish(bd, 0)
	}
	for k in 1 ..= MAX_DEPTH {
		l := &bd.levels[k]
		above_empty := k == MAX_DEPTH || (bd.levels[k + 1].count == 0 && bd.levels[k + 1].emitted == 0)
		if above_empty && l.emitted == 0 {
			_block_seal(l.buf[:], BT_INDEX, l.count, l.pos, l.rst[:l.nr])
			root = _builder_emit(bd, l.buf[:])
			depth = k
			break
		}
		if l.count > 0 {
			_level_finish(bd, k)
		}
	}
	if depth == 0 {
		return {}, .Io
	}
	_filter_flush(bd)
	ffirst, fcount := _filter_index(bd)
	footer: [BLOCK]u8
	p := BLOCK_HDR
	prim.put_u64le(footer[p:], RUN_MAGIC)
	prim.put_u64le(footer[p + 8:], bd.nentries)
	prim.put_u32le(footer[p + 16:], root)
	footer[p + 20] = u8(depth)
	footer[p + 21] = level
	prim.put_u32le(footer[p + 22:], VERSION)
	prim.put_u32le(footer[p + 26:], ffirst)
	prim.put_u32le(footer[p + 30:], fcount)
	prim.put_u32le(footer[p + 34:], bd.nparts)
	_block_seal(footer[:], BT_FOOTER, 0, p + 38, nil)
	nb := bd.nblocks + 1
	_builder_emit(bd, footer[:])
	_builder_drain(bd)
	if bd.err != .None {
		return {}, bd.err
	}
	r = Run {
		level    = level,
		depth    = u8(depth),
		root     = root,
		nblocks  = nb,
		nentries = bd.nentries,
		fd       = prim.INVALID_FD,
	}
	return r, .None
}

@(private)
_run_read_block :: proc(p: ^Pack, r: ^Run, blk: u32, buf: []u8) -> (out: []u8, err: Error) {
	if blk >= r.nblocks {
		return nil, .Io
	}
	if p.bcache == nil {
		raw, aerr := virtual.reserve_and_commit(uint(BCACHE * size_of(Bc_Entry)))
		if aerr == nil {
			p.bcache = ([^]Bc_Entry)(raw_data(raw))[:BCACHE]
		}
	}
	dst := buf[:BLOCK]
	slot: ^Bc_Entry
	if p.bcache != nil {
		h := (u64(r.id) * 0x9e37_79b9_7f4a_7c15 ~ u64(blk) * 0xbf58_476d_1ce4_e5b9) >> 32
		slot = &p.bcache[h % BCACHE]
		if slot.valid && slot.run == r.id && slot.blk == blk {
			p.stats.cache_hits += 1
			return slot.data[:], .None
		}
		slot.valid = false
		dst = slot.data[:]
	}
	n, rerr := prim.read_at(p.base, r.fd, dst, i64(blk) * BLOCK)
	if rerr != .None {
		return nil, rerr
	}
	if n != BLOCK || !_block_ok(dst) {
		return nil, .Io
	}
	p.stats.run_reads += 1
	if slot != nil {
		slot.run = r.id
		slot.blk = blk
		slot.valid = true
	}
	return dst, .None
}

@(private)
_run_load :: proc(p: ^Pack, r: ^Run) -> Error {
	if r.root_buf == nil {
		b, aerr := make([]u8, BLOCK, p.allocator)
		if aerr != nil {
			return .No_Memory
		}
		r.root_buf = b
	}
	tmp: [BLOCK]u8
	if r.nblocks < 2 {
		return .Io
	}
	root := _run_read_block(p, r, r.root, tmp[:]) or_return
	copy(r.root_buf, root)
	if r.root_buf[0] != BT_INDEX {
		return .Io
	}
	footer := _run_read_block(p, r, r.nblocks - 1, tmp[:]) or_return
	q := BLOCK_HDR
	if footer[0] != BT_FOOTER || prim.get_u64le(footer[q:]) != RUN_MAGIC || prim.get_u64le(footer[q + 8:]) != r.nentries || prim.get_u32le(footer[q + 16:]) != r.root || footer[q + 20] != r.depth {
		return .Io
	}
	if prim.get_u32le(footer[q + 22:]) != VERSION {
		return .Unsupported
	}
	ffirst := prim.get_u32le(footer[q + 26:])
	fcount := prim.get_u32le(footer[q + 30:])
	nparts := prim.get_u32le(footer[q + 34:])
	if u64(ffirst) + u64(fcount) > u64(r.nblocks - 1) || u64(nparts) > r.nentries {
		return .Io
	}
	clear(&r.fkeys)
	clear(&r.fents)
	if r.fkeys == nil {
		r.fkeys = make([dynamic]u8, p.allocator)
		r.fents = make([dynamic]Fpart, p.allocator)
	}
	for b in ffirst ..< ffirst + fcount {
		blk := _run_read_block(p, r, b, tmp[:]) or_return
		if blk[0] != BT_FINDEX {
			return .Io
		}
		c: Block_Cursor
		_cursor_init(&c, blk)
		pos := BLOCK_HDR
		for _ in 0 ..< c.left {
			kl, n1 := prim.get_uvarint(blk[pos:c.end])
			if n1 <= 0 || kl > MAX_KEY || pos + n1 + int(kl) > c.end {
				return .Io
			}
			key := blk[pos + n1:][:kl]
			no, n2 := prim.get_uvarint(blk[pos + n1 + int(kl):c.end])
			if n2 <= 0 || no >= u64(r.nblocks) {
				return .Io
			}
			append(&r.fents, Fpart{koff = u32(len(r.fkeys)), klen = u32(kl), blk = u32(no)})
			append(&r.fkeys, ..key)
			pos += n1 + int(kl) + n2
		}
	}
	if u32(len(r.fents)) != nparts {
		return .Io
	}
	return .None
}

@(private)
_run_filter_bytes :: proc "contextless" (r: ^Run) -> int {
	return len(r.fents) * FBYTES
}

@(private)
_run_filter_load :: proc(p: ^Pack, r: ^Run) -> Error {
	if r.fres != nil || len(r.fents) == 0 {
		return .None
	}
	res, aerr := virtual.reserve_and_commit(uint(len(r.fents) * FBYTES))
	if aerr != nil {
		return .No_Memory
	}
	tmp: [BLOCK]u8
	for f, i in r.fents {
		n, err := prim.read_at(p.base, r.fd, tmp[:], i64(f.blk) * BLOCK)
		if err != .None || n != BLOCK || !_block_ok(tmp[:]) || tmp[0] != BT_FILTER {
			virtual.release(raw_data(res), uint(len(res)))
			return .Io if err == .None else err
		}
		copy(res[i * FBYTES:], tmp[BLOCK_HDR:][:FBYTES])
	}
	r.fres = res
	return .None
}

@(private)
_run_filter_drop :: proc(p: ^Pack, r: ^Run) {
	if r.fres != nil {
		virtual.release(raw_data(r.fres), uint(len(r.fres)))
		r.fres = nil
	}
}

@(private)
_run_may_contain :: proc(p: ^Pack, r: ^Run, key: []u8) -> (maybe: bool, err: Error) {
	n := len(r.fents)
	if n == 0 {
		return true, .None
	}
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		f := r.fents[mid]
		if _key_cmp(r.fkeys[f.koff:][:f.klen], key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == n {
		return false, .None
	}
	h := _fhash(key)
	if r.fres != nil {
		return _ftest(r.fres[lo * FBYTES:][:FBYTES], h), .None
	}
	tmp: [BLOCK]u8
	blk := _run_read_block(p, r, r.fents[lo].blk, tmp[:]) or_return
	if blk[0] != BT_FILTER {
		return false, .Io
	}
	p.stats.filter_reads += 1
	return _ftest(blk[BLOCK_HDR:][:FBYTES], h), .None
}

@(private)
Block_Cursor :: struct {
	b:    []u8,
	pos:  int,
	end:  int,
	left: int,
	nr:   int,
	key:  [MAX_KEY]u8,
	klen: int,
	val:  []u8,
	tomb: bool,
	bad:  bool,
}

@(private)
_cursor_init :: proc "contextless" (c: ^Block_Cursor, b: []u8) {
	c.b = b
	c.pos = BLOCK_HDR
	c.end = int(b[3]) | int(b[4]) << 8
	c.left = int(b[1]) | int(b[2]) << 8
	c.nr = int(b[5]) | int(b[6]) << 8
	c.klen = 0
	c.bad = false
}

@(private)
_restart_key :: proc "contextless" (c: ^Block_Cursor, i: int) -> (key: []u8, ok: bool) {
	o := int(c.b[c.end + 2 * i]) | int(c.b[c.end + 2 * i + 1]) << 8
	if o < BLOCK_HDR || o >= c.end {
		return nil, false
	}
	_, n1 := prim.get_uvarint(c.b[o:c.end])
	if n1 <= 0 {
		return nil, false
	}
	un, n2 := prim.get_uvarint(c.b[o + n1:c.end])
	if n2 <= 0 {
		return nil, false
	}
	_, n3 := prim.get_uvarint(c.b[o + n1 + n2:c.end])
	if n3 <= 0 || un > u64(c.end - o - n1 - n2 - n3) {
		return nil, false
	}
	s := o + n1 + n2 + n3
	return c.b[s:][:un], true
}

@(private)
_cursor_seek :: proc "contextless" (c: ^Block_Cursor, key: []u8) {
	if c.nr == 0 {
		return
	}
	lo, hi := 0, c.nr
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		k, ok := _restart_key(c, mid)
		if !ok {
			c.bad = true
			return
		}
		if _key_cmp(k, key) < 0 {
			lo = mid
		} else {
			hi = mid
		}
	}
	o := int(c.b[c.end + 2 * lo]) | int(c.b[c.end + 2 * lo + 1]) << 8
	total := int(c.b[1]) | int(c.b[2]) << 8
	c.pos = o
	c.klen = 0
	c.left = total - lo * RESTART
	if c.left < 0 {
		c.bad = true
	}
}

@(private)
_cursor_next :: proc "contextless" (c: ^Block_Cursor) -> bool {
	if c.left <= 0 || c.bad {
		return false
	}
	shared, n1 := prim.get_uvarint(c.b[c.pos:c.end])
	if n1 <= 0 {
		c.bad = true
		return false
	}
	c.pos += n1
	unshared, n2 := prim.get_uvarint(c.b[c.pos:c.end])
	if n2 <= 0 {
		c.bad = true
		return false
	}
	c.pos += n2
	vword, n3 := prim.get_uvarint(c.b[c.pos:c.end])
	if n3 <= 0 {
		c.bad = true
		return false
	}
	c.pos += n3
	vlen := vword >> 1
	if shared > u64(c.klen) || shared + unshared > MAX_KEY || unshared > u64(c.end - c.pos) || vlen > u64(c.end - c.pos) - unshared {
		c.bad = true
		return false
	}
	copy(c.key[shared:], c.b[c.pos:][:unshared])
	c.klen = int(shared + unshared)
	c.pos += int(unshared)
	c.val = c.b[c.pos:][:vlen]
	c.tomb = vword & 1 != 0
	c.pos += int(vlen)
	c.left -= 1
	return true
}

@(private)
_index_child :: proc(c: ^Block_Cursor, key: []u8) -> (child: u32, ok: bool, err: Error) {
	_cursor_seek(c, key)
	for _cursor_next(c) {
		if _key_cmp(c.key[:c.klen], key) >= 0 {
			v, n := prim.get_uvarint(c.val)
			if n <= 0 || v > u64(max(u32)) {
				return 0, false, .Io
			}
			return u32(v), true, .None
		}
	}
	if c.bad {
		return 0, false, .Io
	}
	return 0, false, .None
}

@(private)
_run_seek_leaf :: proc(p: ^Pack, r: ^Run, key: []u8, buf: []u8) -> (blk: u32, data: []u8, found: bool, err: Error) {
	cur := r.root_buf
	for d := int(r.depth); d > 0; d -= 1 {
		c: Block_Cursor
		_cursor_init(&c, cur)
		child, ok := _index_child(&c, key) or_return
		if !ok {
			return 0, nil, false, .None
		}
		cur = _run_read_block(p, r, child, buf) or_return
		want := BT_DATA if d == 1 else BT_INDEX
		if cur[0] != want {
			return 0, nil, false, .Io
		}
		blk = child
	}
	return blk, cur, true, .None
}

@(private)
_run_get :: proc(p: ^Pack, r: ^Run, key: []u8, out: ^[dynamic]u8) -> (found: bool, tomb: bool, err: Error) {
	buf: [BLOCK]u8
	_, data, ok := _run_seek_leaf(p, r, key, buf[:]) or_return
	if !ok {
		return false, false, .None
	}
	c: Block_Cursor
	_cursor_init(&c, data)
	_cursor_seek(&c, key)
	for _cursor_next(&c) {
		cmp := _key_cmp(c.key[:c.klen], key)
		if cmp == 0 {
			clear(out)
			append(out, ..c.val)
			return true, c.tomb, .None
		}
		if cmp > 0 {
			return false, false, .None
		}
	}
	if c.bad {
		return false, false, .Io
	}
	return false, false, .None
}

@(private)
Run_Iter :: struct {
	p:      ^Pack,
	r:      ^Run,
	rbuf:   []u8,
	rbase:  u32,
	rcount: u32,
	next:   u32,
	cur:    Block_Cursor,
	in_blk: bool,
	have:   bool,
	done:   bool,
	err:    Error,
}

@(private)
RUN_READAHEAD :: 16

@(private)
_run_iter_init :: proc(it: ^Run_Iter, p: ^Pack, r: ^Run, from: []u8) -> Error {
	it^ = {
		p = p,
		r = r,
	}
	buf, aerr := make([]u8, RUN_READAHEAD * BLOCK, p.allocator)
	if aerr != nil {
		return .No_Memory
	}
	it.rbuf = buf
	if from == nil {
		return .None
	}
	tmp: [BLOCK]u8
	blk, _, ok, err := _run_seek_leaf(p, r, from, tmp[:])
	if err != .None {
		return err
	}
	if !ok {
		it.done = true
		return .None
	}
	it.next = blk
	for {
		k, _, _, more := _run_iter_peek(it)
		if !more || _key_cmp(k, from) >= 0 {
			break
		}
		it.have = false
	}
	return it.err
}

@(private)
_run_iter_destroy :: proc(it: ^Run_Iter) {
	if it.rbuf != nil {
		delete(it.rbuf, it.p.allocator)
		it.rbuf = nil
	}
}

@(private)
_run_iter_block :: proc(it: ^Run_Iter) -> bool {
	for {
		if it.next + 1 >= it.r.nblocks {
			it.done = true
			return false
		}
		if it.next < it.rbase || it.next >= it.rbase + it.rcount {
			want := min(u32(RUN_READAHEAD), it.r.nblocks - 1 - it.next)
			n, err := prim.read_at(it.p.base, it.r.fd, it.rbuf[:int(want) * BLOCK], i64(it.next) * BLOCK)
			if err != .None || n != int(want) * BLOCK {
				it.err = _perr(err) if err != .None else .Io
				it.done = true
				return false
			}
			it.rbase = it.next
			it.rcount = want
			it.p.stats.run_reads += 1
		}
		b := it.rbuf[int(it.next - it.rbase) * BLOCK:][:BLOCK]
		it.next += 1
		if !_block_ok(b) {
			it.err = .Io
			it.done = true
			return false
		}
		if b[0] == BT_DATA {
			_cursor_init(&it.cur, b)
			it.in_blk = true
			return true
		}
	}
}

@(private)
_run_iter_peek :: proc(it: ^Run_Iter) -> (key: []u8, val: []u8, tomb: bool, ok: bool) {
	for !it.done {
		if it.have {
			return it.cur.key[:it.cur.klen], it.cur.val, it.cur.tomb, true
		}
		if it.in_blk {
			if _cursor_next(&it.cur) {
				it.have = true
				continue
			}
			if it.cur.bad {
				it.err = .Io
				it.done = true
				return
			}
			it.in_blk = false
			continue
		}
		if !_run_iter_block(it) {
			return
		}
	}
	return
}

@(private)
_run_iter_advance :: proc "contextless" (it: ^Run_Iter) {
	it.have = false
}

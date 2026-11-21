package search

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

SEG_MAGIC :: u64(0x6765_7368_6372_7330)
SEG_VERSION :: u64(3)
NFIELDS :: 36
FOOTER_SIZE :: (NFIELDS + 3) * 8
DIR_ENTRY :: 40
OUT_BUF :: 256 * 1024
SRC_ENTRY :: 24

Footer :: struct {
	lo:         u64,
	hi:         u64,
	store:      bool,
	text_off:   i64,
	text_len:   i64,
	docs_off:   i64,
	docs_len:   i64,
	post_off:   i64,
	post_len:   i64,
	dix_off:    i64,
	dix_len:    i64,
	n_dblocks:  u64,
	n_terms:    u64,
	src_off:    i64,
	src_len:    i64,
	tomb_off:   i64,
	tomb_len:   i64,
	kvf_off:    i64,
	kvf_len:    i64,
	kvf_ix_off: i64,
	kvf_ix_len: i64,
	kvs_off:    i64,
	kvs_len:    i64,
	kvs_ix_off: i64,
	kvs_ix_len: i64,
	max_hlc:    u64,
	total_len:  u64,
	meta_sum:   u64,
	dir_sum:    u64,
	vec_n:      u64,
	vec_dim:    u64,
	vids_off:   i64,
	vdata_off:  i64,
	ivf_off:    i64,
	ivf_len:    i64,
	cb_gen:     u64,
	sum:        u64,
}

Seg :: struct {
	vfs:  prim.Vfs,
	gen:  u64,
	fd:   prim.Fd,
	size: i64,
	f:    Footer,
}

Dir_Entry :: struct {
	doc_off:   i64,
	text_base: i64,
	min_hlc:   u64,
	max_hlc:   u64,
	pmax:      u64,
}

Term :: struct {
	count: u32,
	inl:   [INLINE]u32,
	off:   i64,
	plen:  i64,
	blen:  i64,
}

nblocks :: proc "contextless" (lo, hi: u64) -> u64 {
	if hi <= lo {
		return 0
	}
	return (hi - 1) / DOC_BLOCK - lo / DOC_BLOCK + 1
}

@(private)
_footer_fields :: proc "contextless" (f: ^Footer) -> [NFIELDS]u64 {
	return {
		f.lo,
		f.hi,
		1 if f.store else 0,
		u64(f.text_off),
		u64(f.text_len),
		u64(f.docs_off),
		u64(f.docs_len),
		u64(f.post_off),
		u64(f.post_len),
		u64(f.dix_off),
		u64(f.dix_len),
		f.n_dblocks,
		f.n_terms,
		u64(f.src_off),
		u64(f.src_len),
		u64(f.tomb_off),
		u64(f.tomb_len),
		u64(f.kvf_off),
		u64(f.kvf_len),
		u64(f.kvf_ix_off),
		u64(f.kvf_ix_len),
		u64(f.kvs_off),
		u64(f.kvs_len),
		u64(f.kvs_ix_off),
		u64(f.kvs_ix_len),
		f.max_hlc,
		f.total_len,
		f.meta_sum,
		f.dir_sum,
		f.vec_n,
		f.vec_dim,
		u64(f.vids_off),
		u64(f.vdata_off),
		u64(f.ivf_off),
		u64(f.ivf_len),
		f.cb_gen,
	}
}

footer_encode :: proc(f: ^Footer, out: ^[FOOTER_SIZE]u8) {
	prim.put_u64le(out[0:], SEG_MAGIC)
	prim.put_u64le(out[8:], SEG_VERSION)
	fields := _footer_fields(f)
	for v, i in fields {
		prim.put_u64le(out[16 + 8 * i:], v)
	}
	f.sum = xxhash.XXH3_64_default(out[:FOOTER_SIZE - 8])
	prim.put_u64le(out[FOOTER_SIZE - 8:], f.sum)
}

footer_decode :: proc(b: []u8, size: i64) -> (f: Footer, ok: bool) {
	if len(b) != FOOTER_SIZE {
		return
	}
	if prim.get_u64le(b[0:]) != SEG_MAGIC || prim.get_u64le(b[8:]) != SEG_VERSION {
		return
	}
	f.sum = prim.get_u64le(b[FOOTER_SIZE - 8:])
	if xxhash.XXH3_64_default(b[:FOOTER_SIZE - 8]) != f.sum {
		return
	}
	v: [NFIELDS]u64
	for i in 0 ..< NFIELDS {
		v[i] = prim.get_u64le(b[16 + 8 * i:])
	}
	f.lo, f.hi = v[0], v[1]
	f.store = v[2] == 1
	f.text_off, f.text_len = i64(v[3]), i64(v[4])
	f.docs_off, f.docs_len = i64(v[5]), i64(v[6])
	f.post_off, f.post_len = i64(v[7]), i64(v[8])
	f.dix_off, f.dix_len = i64(v[9]), i64(v[10])
	f.n_dblocks, f.n_terms = v[11], v[12]
	f.src_off, f.src_len = i64(v[13]), i64(v[14])
	f.tomb_off, f.tomb_len = i64(v[15]), i64(v[16])
	f.kvf_off, f.kvf_len = i64(v[17]), i64(v[18])
	f.kvf_ix_off, f.kvf_ix_len = i64(v[19]), i64(v[20])
	f.kvs_off, f.kvs_len = i64(v[21]), i64(v[22])
	f.kvs_ix_off, f.kvs_ix_len = i64(v[23]), i64(v[24])
	f.max_hlc, f.total_len = v[25], v[26]
	f.meta_sum, f.dir_sum = v[27], v[28]
	f.vec_n, f.vec_dim = v[29], v[30]
	f.vids_off, f.vdata_off = i64(v[31]), i64(v[32])
	f.ivf_off, f.ivf_len = i64(v[33]), i64(v[34])
	f.cb_gen = v[35]
	if f.vec_n > MAX_DOCS || f.vec_dim > MAX_DIM || (f.vec_n > 0 && f.vec_dim == 0) {
		return
	}
	vbytes := i64(f.vec_n) * i64(f.vec_dim) * 4
	if v[2] > 1 || f.hi < f.lo || f.hi > MAX_DOCS + 1 {
		return
	}
	limit := size - FOOTER_SIZE
	dir_len := i64(nblocks(f.lo, f.hi)) * DIR_ENTRY
	if dir_len > limit {
		return
	}
	spans := [?][2]i64 {
		{f.text_off, f.text_len},
		{f.docs_off, f.docs_len},
		{f.post_off, f.post_len},
		{f.dix_off, f.dix_len},
		{f.src_off, f.src_len},
		{f.tomb_off, f.tomb_len},
		{f.kvf_off, f.kvf_len},
		{f.kvf_ix_off, f.kvf_ix_len},
		{f.kvs_off, f.kvs_len},
		{f.kvs_ix_off, f.kvs_ix_len},
		{f.vids_off, i64(f.vec_n) * 4},
		{f.vdata_off, vbytes},
		{f.ivf_off, f.ivf_len},
	}
	for s in spans {
		if s[0] < dir_len || s[1] < 0 || s[0] > limit || s[1] > limit - s[0] {
			return
		}
	}
	if f.src_len % SRC_ENTRY != 0 {
		return
	}
	ok = true
	return
}

seg_open :: proc(s: ^Seg, vfs: prim.Vfs, path: string, gen: u64) -> Error {
	s^ = {
		vfs = vfs,
		gen = gen,
		fd  = prim.INVALID_FD,
	}
	fd, oerr := prim.open_file(vfs, path)
	if oerr != .None {
		return .Corrupt if oerr == .Not_Found else _perr(oerr)
	}
	s.fd = fd
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		return _perr(serr)
	}
	s.size = size
	if size < FOOTER_SIZE {
		return .Corrupt
	}
	fb: [FOOTER_SIZE]u8
	n, rerr := prim.read_at(vfs, fd, fb[:], size - FOOTER_SIZE)
	if rerr != .None {
		return _perr(rerr)
	}
	if n != FOOTER_SIZE {
		return .Corrupt
	}
	f, ok := footer_decode(fb[:], size)
	if !ok {
		return .Corrupt
	}
	s.f = f
	st: xxhash.XXH64_state
	xxhash.XXH64_reset_state(&st)
	sections := [?][2]i64{{f.dix_off, f.dix_len}, {f.src_off, f.src_len}, {f.tomb_off, f.tomb_len}, {f.kvf_ix_off, f.kvf_ix_len}, {f.kvs_ix_off, f.kvs_ix_len}, {f.vids_off, i64(f.vec_n) * 4}}
	buf := make([]u8, 64 * 1024, context.temp_allocator)
	for sec in sections {
		done := i64(0)
		for done < sec[1] {
			k := min(i64(len(buf)), sec[1] - done)
			got, e := prim.read_at(vfs, fd, buf[:k], sec[0] + done)
			if e != .None {
				return _perr(e)
			}
			if i64(got) != k {
				return .Corrupt
			}
			xxhash.XXH64_update(&st, buf[:k])
			done += k
		}
	}
	if xxhash.XXH64_digest(&st) != f.meta_sum {
		return .Corrupt
	}
	return .None
}

seg_close :: proc(s: ^Seg) {
	if s.fd != prim.INVALID_FD {
		prim.close_file(s.vfs, s.fd)
	}
	s.fd = prim.INVALID_FD
}

seg_dir :: proc(c: ^Cache, s: ^Seg, blk: u64) -> (d: Dir_Entry, err: Error) {
	first := s.f.lo / DOC_BLOCK
	if blk < first || blk - first >= nblocks(s.f.lo, s.f.hi) {
		return d, .Corrupt
	}
	b: [DIR_ENTRY]u8
	cache_read(c, s, i64(blk - first) * DIR_ENTRY, b[:]) or_return
	d.doc_off = i64(prim.get_u64le(b[0:]))
	d.text_base = i64(prim.get_u64le(b[8:]))
	d.min_hlc = prim.get_u64le(b[16:])
	d.max_hlc = prim.get_u64le(b[24:])
	d.pmax = prim.get_u64le(b[32:])
	return
}

seg_doc_span :: proc(c: ^Cache, s: ^Seg, blk: u64) -> (d: Dir_Entry, off: i64, n: i64, err: Error) {
	d = seg_dir(c, s, blk) or_return
	end := s.f.docs_off + s.f.docs_len
	if blk + 1 <= (s.f.hi - 1) / DOC_BLOCK {
		nx := seg_dir(c, s, blk + 1) or_return
		end = nx.doc_off
	}
	if d.doc_off < s.f.docs_off || end < d.doc_off || end > s.f.docs_off + s.f.docs_len {
		return d, 0, 0, .Corrupt
	}
	return d, d.doc_off, end - d.doc_off, .None
}

Out :: struct {
	vfs:  prim.Vfs,
	fd:   prim.Fd,
	buf:  [dynamic]u8,
	base: i64,
	err:  Error,
}

out_off :: proc "contextless" (o: ^Out) -> i64 {
	return o.base + i64(len(o.buf))
}

out_flush :: proc(o: ^Out) {
	if o.err != .None || len(o.buf) == 0 {
		return
	}
	if e := prim.write_at(o.vfs, o.fd, o.buf[:], o.base); e != .None {
		o.err = _perr(e)
		return
	}
	o.base += i64(len(o.buf))
	clear(&o.buf)
}

out_write :: proc(o: ^Out, data: []u8) {
	if o.err != .None {
		return
	}
	if len(o.buf) + len(data) > OUT_BUF {
		out_flush(o)
		if o.err != .None {
			return
		}
		if len(data) >= OUT_BUF {
			if e := prim.write_at(o.vfs, o.fd, data, o.base); e != .None {
				o.err = _perr(e)
				return
			}
			o.base += i64(len(data))
			return
		}
	}
	if _, e := append(&o.buf, ..data); e != nil {
		o.err = .No_Memory
	}
}

Seg_Writer :: struct {
	out:       Out,
	f:         Footer,
	first_blk: u64,
	nblk:      u64,
	dir_i:     u64,
	dirbuf:    [dynamic]u8,
	dir_st:    xxhash.XXH64_state,
	meta_st:   xxhash.XXH64_state,
	pmax:      u64,
	db:        [dynamic]u8,
	dn:        int,
	dpost:     i64,
	dprev:     [MAX_KEY]u8,
	dprev_len: int,
	dfirst:    [MAX_KEY]u8,
	dfirst_len: int,
	dix:       [dynamic]u8,
	dixo:      [dynamic]u8,
	tmp:       [dynamic]u8,
	allocator: runtime.Allocator,
}

sw_begin :: proc(sw: ^Seg_Writer, vfs: prim.Vfs, path: string, lo, hi: u64, store: bool, base_pmax: u64, allocator := context.allocator) -> Error {
	sw^ = {
		allocator = allocator,
		pmax      = base_pmax,
	}
	sw.out.fd = prim.INVALID_FD
	sw.out.vfs = vfs
	sw.f.lo = lo
	sw.f.hi = hi
	sw.f.store = store
	sw.first_blk = lo / DOC_BLOCK
	sw.nblk = nblocks(lo, hi)
	fd, err := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o600)
	if err != .None {
		return _perr(err)
	}
	sw.out.fd = fd
	sw.out.buf = make([dynamic]u8, 0, OUT_BUF, allocator)
	sw.dirbuf = make([dynamic]u8, 0, 64 * 1024, allocator)
	sw.db = make([dynamic]u8, 0, 16 * 1024, allocator)
	sw.dix = make([dynamic]u8, 0, 4096, allocator)
	sw.dixo = make([dynamic]u8, 0, 1024, allocator)
	sw.tmp = make([dynamic]u8, 0, 4096, allocator)
	sw.out.base = i64(sw.nblk) * DIR_ENTRY
	xxhash.XXH64_reset_state(&sw.dir_st)
	xxhash.XXH64_reset_state(&sw.meta_st)
	return .None
}

sw_destroy :: proc(sw: ^Seg_Writer) {
	if sw.out.fd != prim.INVALID_FD {
		prim.close_file(sw.out.vfs, sw.out.fd)
	}
	delete(sw.out.buf)
	delete(sw.dirbuf)
	delete(sw.db)
	delete(sw.dix)
	delete(sw.dixo)
	delete(sw.tmp)
	sw.out.fd = prim.INVALID_FD
}

sw_write :: proc(sw: ^Seg_Writer, data: []u8) {
	out_write(&sw.out, data)
}

sw_meta :: proc(sw: ^Seg_Writer, data: []u8) {
	xxhash.XXH64_update(&sw.meta_st, data)
	out_write(&sw.out, data)
}

sw_off :: proc "contextless" (sw: ^Seg_Writer) -> i64 {
	return out_off(&sw.out)
}

sw_dir :: proc(sw: ^Seg_Writer, d: Dir_Entry) {
	if sw.out.err != .None {
		return
	}
	if sw.dir_i >= sw.nblk {
		sw.out.err = .Invalid
		return
	}
	if d.max_hlc > sw.pmax {
		sw.pmax = d.max_hlc
	}
	b: [DIR_ENTRY]u8
	prim.put_u64le(b[0:], u64(d.doc_off))
	prim.put_u64le(b[8:], u64(d.text_base))
	prim.put_u64le(b[16:], d.min_hlc)
	prim.put_u64le(b[24:], d.max_hlc)
	prim.put_u64le(b[32:], sw.pmax)
	if d.max_hlc > sw.f.max_hlc {
		sw.f.max_hlc = d.max_hlc
	}
	xxhash.XXH64_update(&sw.dir_st, b[:])
	append(&sw.dirbuf, ..b[:])
	sw.dir_i += 1
	if len(sw.dirbuf) >= 64 * 1024 {
		_sw_dir_flush(sw)
	}
}

@(private)
_sw_dir_flush :: proc(sw: ^Seg_Writer) {
	if len(sw.dirbuf) == 0 || sw.out.err != .None {
		return
	}
	at := i64(sw.dir_i) * DIR_ENTRY - i64(len(sw.dirbuf))
	if e := prim.write_at(sw.out.vfs, sw.out.fd, sw.dirbuf[:], at); e != .None {
		sw.out.err = _perr(e)
	}
	clear(&sw.dirbuf)
}

sw_term :: proc(sw: ^Seg_Writer, key: []u8, count: u32, inl: []u32, plen, blen: i64) {
	if count == 0 {
		return
	}
	if sw.dn == 0 {
		sw.dpost = sw_off(sw) - plen
		clear(&sw.db)
		sw.dfirst_len = copy(sw.dfirst[:], key)
		sw.dprev_len = 0
	}
	shared := 0
	for shared < len(key) && shared < sw.dprev_len && key[shared] == sw.dprev[shared] {
		shared += 1
	}
	w := prim.writer(&sw.db)
	prim.write_u8(&w, u8(shared))
	prim.write_u8(&w, u8(len(key) - shared))
	prim.write_raw(&w, key[shared:])
	prim.write_uvarint(&w, u64(count))
	if count <= INLINE {
		prev := u32(0)
		for id, i in inl[:count] {
			prim.write_uvarint(&w, u64(id - prev) if i > 0 else u64(id))
			prev = id
		}
	} else {
		prim.write_uvarint(&w, u64(plen))
		prim.write_uvarint(&w, u64(blen))
	}
	if w.err != .None {
		sw.out.err = .No_Memory
	}
	sw.dprev_len = copy(sw.dprev[:], key)
	sw.dn += 1
	sw.f.n_terms += 1
	if sw.dn == DICT_BLOCK {
		sw_dict_flush(sw)
	}
}

sw_dict_flush :: proc(sw: ^Seg_Writer) {
	if sw.dn == 0 {
		return
	}
	clear(&sw.tmp)
	w := prim.writer(&sw.tmp)
	prim.write_u8(&w, u8(sw.dn))
	prim.write_uvarint(&w, u64(sw.dpost))
	prim.write_raw(&w, sw.db[:])
	prim.write_u32le(&w, xxhash.XXH32(sw.tmp[:]))
	if w.err != .None {
		sw.out.err = .No_Memory
		return
	}
	at := sw_off(sw)
	sw_write(sw, sw.tmp[:])
	ow := prim.writer(&sw.dixo)
	prim.write_u32le(&ow, u32(len(sw.dix)))
	iw := prim.writer(&sw.dix)
	prim.write_u8(&iw, u8(sw.dfirst_len))
	prim.write_raw(&iw, sw.dfirst[:sw.dfirst_len])
	prim.write_u64le(&iw, u64(at))
	prim.write_u32le(&iw, u32(len(sw.tmp)))
	if iw.err != .None || ow.err != .None || len(sw.dix) > int(max(u32)) {
		sw.out.err = .No_Memory
	}
	sw.f.n_dblocks += 1
	sw.dn = 0
}

sw_post_begin :: proc(sw: ^Seg_Writer) {
	sw.f.post_off = sw_off(sw)
}

sw_post_end :: proc(sw: ^Seg_Writer) {
	sw_dict_flush(sw)
	sw.f.post_len = sw_off(sw) - sw.f.post_off
	sw.f.dix_off = sw_off(sw)
	sw_meta(sw, sw.dix[:])
	sw_meta(sw, sw.dixo[:])
	sw.f.dix_len = sw_off(sw) - sw.f.dix_off
}

sw_finish :: proc(sw: ^Seg_Writer) -> (f: Footer, err: Error) {
	_sw_dir_flush(sw)
	if sw.out.err == .None && sw.dir_i != sw.nblk {
		sw.out.err = .Invalid
	}
	sw.f.dir_sum = xxhash.XXH64_digest(&sw.dir_st)
	sw.f.meta_sum = xxhash.XXH64_digest(&sw.meta_st)
	fb: [FOOTER_SIZE]u8
	footer_encode(&sw.f, &fb)
	out_write(&sw.out, fb[:])
	out_flush(&sw.out)
	if sw.out.err != .None {
		return sw.f, sw.out.err
	}
	if e := prim.datasync(sw.out.vfs, sw.out.fd); e != .None {
		return sw.f, _perr(e)
	}
	return sw.f, .None
}

Dix :: struct {
	c:    ^Cache,
	s:    ^Seg,
	n:    int,
	ents: i64,
}

dix_load :: proc(c: ^Cache, s: ^Seg, allocator: runtime.Allocator) -> (d: Dix, err: Error) {
	n := i64(s.f.n_dblocks)
	if n * 4 > s.f.dix_len {
		return d, .Corrupt
	}
	return Dix{c = c, s = s, n = int(n), ents = s.f.dix_len - n * 4}, .None
}

dix_entry :: proc(d: ^Dix, i: int, key: ^[MAX_KEY]u8) -> (k: []u8, off: i64, ln: u32, err: Error) {
	if i < 0 || i >= d.n {
		return nil, 0, 0, .Corrupt
	}
	ob: [4]u8
	cache_read(d.c, d.s, d.s.f.dix_off + d.ents + i64(i) * 4, ob[:]) or_return
	at := i64(prim.get_u32le(ob[:]))
	if at >= d.ents {
		return nil, 0, 0, .Corrupt
	}
	buf: [1 + MAX_KEY + 12]u8
	want := min(i64(len(buf)), d.ents - at)
	cache_read(d.c, d.s, d.s.f.dix_off + at, buf[:want]) or_return
	kl := int(buf[0])
	if kl == 0 || i64(1 + kl + 12) > want {
		return nil, 0, 0, .Corrupt
	}
	copy(key[:], buf[1:][:kl])
	off = i64(prim.get_u64le(buf[1 + kl:]))
	ln = prim.get_u32le(buf[1 + kl + 8:])
	if off < d.s.f.post_off || ln > 1 << 20 || off + i64(ln) > d.s.f.post_off + d.s.f.post_len {
		return nil, 0, 0, .Corrupt
	}
	return key[:kl], off, ln, .None
}

key_less :: proc "contextless" (a, b: []u8) -> bool {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

key_cmp :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return -1 if len(a) < len(b) else 1
}

dix_find :: proc(d: ^Dix, key: []u8) -> (idx: int, err: Error) {
	lo, hi := 0, d.n
	kb: [MAX_KEY]u8
	for lo < hi {
		mid := (lo + hi) / 2
		k, _, _ := dix_entry(d, mid, &kb) or_return
		if key_less(key, k) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo - 1, .None
}

Dict_Cursor :: struct {
	c:       ^Cache,
	s:       ^Seg,
	dix:     ^Dix,
	blk:     int,
	boff:    i64,
	data:    [dynamic]u8,
	pos:     int,
	left:    int,
	post:    i64,
	key:     [MAX_KEY]u8,
	key_len: int,
	term:    Term,
	err:     Error,
}

dc_init :: proc(dc: ^Dict_Cursor, c: ^Cache, s: ^Seg, dix: ^Dix, allocator: runtime.Allocator) {
	dc^ = {
		c   = c,
		s   = s,
		dix = dix,
		blk = -1,
	}
	dc.data = make([dynamic]u8, allocator)
}

dc_destroy :: proc(dc: ^Dict_Cursor) {
	delete(dc.data)
}

dc_load :: proc(dc: ^Dict_Cursor, blk: int) -> bool {
	if blk < 0 || blk >= dc.dix.n {
		dc.left = 0
		dc.blk = dc.dix.n
		return false
	}
	kb: [MAX_KEY]u8
	_, boff, blen, derr := dix_entry(dc.dix, blk, &kb)
	if derr != .None {
		dc.err = derr
		return false
	}
	dc.boff = boff
	n := int(blen)
	if n < 5 {
		dc.err = .Corrupt
		return false
	}
	if grow(&dc.data, n) != nil {
		dc.err = .No_Memory
		return false
	}
	if e := cache_read(dc.c, dc.s, boff, dc.data[:]); e != .None {
		dc.err = e
		return false
	}
	if xxhash.XXH32(dc.data[:n - 4]) != prim.get_u32le(dc.data[n - 4:]) {
		dc.err = .Corrupt
		return false
	}
	dc.blk = blk
	dc.left = int(dc.data[0])
	dc.pos = 1
	post, ok := uv(dc.data[:n - 4], &dc.pos)
	if !ok || dc.left == 0 || i64(post) < dc.s.f.post_off || i64(post) > boff {
		dc.err = .Corrupt
		return false
	}
	dc.post = i64(post)
	dc.key_len = 0
	return true
}

dc_next :: proc(dc: ^Dict_Cursor) -> bool {
	if dc.err != .None {
		return false
	}
	for dc.left == 0 {
		if !dc_load(dc, dc.blk + 1) {
			return false
		}
	}
	body := dc.data[:len(dc.data) - 4]
	p := dc.pos
	if len(body) - p < 2 {
		dc.err = .Corrupt
		return false
	}
	shared := int(body[p])
	sl := int(body[p + 1])
	p += 2
	if shared > dc.key_len || shared + sl > MAX_KEY || sl == 0 || len(body) - p < sl {
		dc.err = .Corrupt
		return false
	}
	copy(dc.key[shared:], body[p:][:sl])
	dc.key_len = shared + sl
	p += sl
	cnt, ok := uv32(body, &p)
	if !ok || cnt == 0 {
		dc.err = .Corrupt
		return false
	}
	t := Term {
		count = cnt,
	}
	if cnt <= INLINE {
		prev := u32(0)
		for i in 0 ..< int(cnt) {
			v, vok := uv32(body, &p)
			if !vok || (i > 0 && (v == 0 || u64(prev) + u64(v) > u64(max(u32)))) {
				dc.err = .Corrupt
				return false
			}
			prev = v if i == 0 else prev + v
			t.inl[i] = prev
		}
		t.off = dc.post
	} else {
		pl, ok1 := uv(body, &p)
		bl, ok2 := uv(body, &p)
		if !ok1 || !ok2 || bl > pl || i64(pl) > dc.boff - dc.post {
			dc.err = .Corrupt
			return false
		}
		t.off = dc.post
		t.plen = i64(pl)
		t.blen = i64(bl)
		dc.post += i64(pl)
	}
	dc.term = t
	dc.pos = p
	dc.left -= 1
	return true
}

dc_key :: proc "contextless" (dc: ^Dict_Cursor) -> []u8 {
	return dc.key[:dc.key_len]
}

dc_seek :: proc(dc: ^Dict_Cursor, key: []u8) -> bool {
	b, berr := dix_find(dc.dix, key)
	if berr != .None {
		dc.err = berr
		return false
	}
	if !dc_load(dc, max(b, 0)) {
		return false
	}
	for dc_next(dc) {
		if key_cmp(dc_key(dc), key) >= 0 {
			return true
		}
	}
	return false
}

term_lookup :: proc(dc: ^Dict_Cursor, key: []u8) -> (t: Term, found: bool, err: Error) {
	b := dix_find(dc.dix, key) or_return
	if b < 0 {
		return t, false, .None
	}
	if !dc_load(dc, b) {
		return t, false, dc.err
	}
	for dc_next(dc) {
		c := key_cmp(dc_key(dc), key)
		if c == 0 {
			return dc.term, true, .None
		}
		if c > 0 {
			return t, false, .None
		}
		if dc.left == 0 {
			break
		}
	}
	return t, false, dc.err
}

Plist :: struct {
	c:         ^Cache,
	s:         ^Seg,
	count:     u32,
	inl:       [INLINE]u32,
	ninl:      int,
	blk_off:   i64,
	skip_pos:  i64,
	skip_end:  i64,
	win:       [64]u8,
	win_at:    i64,
	win_len:   int,
	prev:      u32,
	started:   bool,
	ids:       [BLOCK]u32,
	n:         int,
	loaded:    bool,
	done:      bool,
	err:       Error,
	raw:       [BLOCK * 5 + 16]u8,
}

pl_init :: proc(p: ^Plist, c: ^Cache, s: ^Seg, t: Term) {
	p.c = c
	p.s = s
	p.count = t.count
	p.ninl = 0
	p.loaded = false
	p.done = false
	p.started = false
	p.err = .None
	p.win_len = 0
	if t.count <= INLINE {
		p.ninl = int(t.count)
		p.inl = t.inl
		for i in 0 ..< p.ninl {
			p.ids[i] = t.inl[i]
		}
		p.n = p.ninl
		p.loaded = p.ninl > 0
		p.skip_pos = 0
		p.skip_end = 0
		return
	}
	p.blk_off = t.off
	p.skip_pos = t.off + t.blen
	p.skip_end = t.off + t.plen
}

@(private)
_pl_uv :: proc(p: ^Plist) -> (v: u64, ok: bool) {
	rel := int(p.skip_pos - p.win_at)
	if p.win_len == 0 || rel < 0 || rel + 10 > p.win_len && p.win_at + i64(p.win_len) < p.skip_end {
		n := min(i64(len(p.win)), p.skip_end - p.skip_pos)
		if n <= 0 {
			return 0, false
		}
		if e := cache_read(p.c, p.s, p.skip_pos, p.win[:n]); e != .None {
			p.err = e
			return 0, false
		}
		p.win_at = p.skip_pos
		p.win_len = int(n)
		rel = 0
	}
	pos := rel
	v, ok = uv(p.win[:p.win_len], &pos)
	if !ok {
		p.err = .Corrupt
		return 0, false
	}
	p.skip_pos = p.win_at + i64(pos)
	return v, true
}

@(private)
_pl_find :: proc "contextless" (p: ^Plist, t: u32) -> u32 {
	lo, hi := 0, p.n
	for lo < hi {
		mid := (lo + hi) / 2
		if p.ids[mid] <= t {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return p.ids[lo - 1]
}

pl_seek :: proc(p: ^Plist, t: u32) -> (id: u32, ok: bool) {
	if p.loaded && p.n > 0 && t >= p.ids[0] {
		return _pl_find(p, t), true
	}
	if p.ninl > 0 || p.done || p.err != .None {
		p.done = true
		return 0, false
	}
	for p.skip_pos < p.skip_end {
		f, ok1 := _pl_uv(p)
		ln, ok2 := _pl_uv(p)
		if !ok1 || !ok2 {
			if p.err == .None {
				p.err = .Corrupt
			}
			break
		}
		first: u64
		if !p.started {
			first = f
		} else {
			if f == 0 || f > u64(p.prev) {
				p.err = .Corrupt
				break
			}
			first = u64(p.prev) - f
		}
		if first > u64(max(u32)) || ln == 0 || ln > len(p.raw) || i64(ln) > p.skip_end - p.blk_off {
			p.err = .Corrupt
			break
		}
		limit := p.prev
		had := p.started
		p.started = true
		p.prev = u32(first)
		at := p.blk_off
		p.blk_off += i64(ln)
		if u32(first) > t {
			continue
		}
		if e := cache_read(p.c, p.s, at, p.raw[:ln]); e != .None {
			p.err = e
			break
		}
		n, _, dok := pfor_decode(p.raw[:ln], u32(first), &p.ids)
		if !dok || (had && p.ids[n - 1] >= limit) {
			p.err = .Corrupt
			break
		}
		p.n = n
		p.loaded = true
		return _pl_find(p, t), true
	}
	p.done = true
	p.loaded = false
	return 0, false
}

Field_Bytes :: struct {
	name:  []u8,
	value: []u8,
}

Doc_Meta :: struct {
	id:          u32,
	flags:       u8,
	kind:        u8,
	object:      prim.Id,
	participant: prim.Id,
	hlc:         u64,
	ref:         []u8,
	part:        u32,
	chunk:       u64,
	len:         u32,
	fields:      []Field_Bytes,
	frame:       i64,
	frame_off:   u32,
}

DF_DELETED :: u8(1)
DF_FIELDS :: u8(2)
DF_TITLE :: u8(4)
DF_CHUNK :: u8(8)
DF_TEXT :: u8(16)

Doc_Block :: struct {
	gen:     u64,
	blk:     u64,
	n:       int,
	first:   u32,
	docs:    [DOC_BLOCK]Doc_Meta,
	raw:     [dynamic]u8,
	refs:    [dynamic]u8,
	fields:  [dynamic]Field_Bytes,
	strs:    [dynamic][]u8,
	objects: [dynamic]prim.Id,
	parts:   [dynamic]prim.Id,
	valid:   bool,
}

db_init :: proc(b: ^Doc_Block, allocator: runtime.Allocator) {
	b^ = {}
	b.raw = make([dynamic]u8, allocator)
	b.refs = make([dynamic]u8, allocator)
	b.fields = make([dynamic]Field_Bytes, allocator)
	b.strs = make([dynamic][]u8, allocator)
	b.objects = make([dynamic]prim.Id, allocator)
	b.parts = make([dynamic]prim.Id, allocator)
}

db_destroy :: proc(b: ^Doc_Block) {
	delete(b.raw)
	delete(b.refs)
	delete(b.fields)
	delete(b.strs)
	delete(b.objects)
	delete(b.parts)
}

doc_block_encode :: proc(w: ^prim.Writer, docs_in: []Doc_Meta) -> (text_base: i64) {
	start := len(w.buf)
	clean: [DOC_BLOCK]Doc_Meta
	for d, i in docs_in {
		clean[i] = d
		if d.flags & DF_DELETED != 0 {
			clean[i] = Doc_Meta {
				id          = d.id,
				flags       = DF_DELETED,
				object      = d.object,
				participant = d.participant,
				kind        = d.kind,
				hlc         = d.hlc,
				part        = d.part,
			}
		} else if text_base == 0 && d.flags & DF_TEXT != 0 {
			text_base = d.frame
		}
	}
	docs := clean[:len(docs_in)]
	base_hlc := docs[0].hlc
	for d in docs {
		base_hlc = min(base_hlc, d.hlc)
	}
	prim.write_u8(w, u8(len(docs) - 1))
	prim.write_u64le(w, base_hlc)
	objects: [DOC_BLOCK]prim.Id
	nob := 0
	oidx: [DOC_BLOCK]u32
	parts: [DOC_BLOCK]prim.Id
	npt := 0
	pidx: [DOC_BLOCK]u32
	for d, i in docs {
		oidx[i] = u32(_intern_id(objects[:], &nob, d.object))
		pidx[i] = u32(_intern_id(parts[:], &npt, d.participant))
	}
	prim.write_uvarint(w, u64(nob))
	for k in 0 ..< nob {
		prim.write_id(w, objects[k])
	}
	prim.write_uvarint(w, u64(npt))
	for k in 0 ..< npt {
		prim.write_id(w, parts[k])
	}
	strs := make(map[string]u32, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	for d in docs {
		for f in d.fields {
			_intern_str(&strs, &order, string(f.name))
			_intern_str(&strs, &order, string(f.value))
		}
	}
	prim.write_uvarint(w, u64(len(order)))
	for s in order {
		prim.write_str(w, s)
	}
	prev_hlc := base_hlc
	prev_ref: []u8
	prev_frame := text_base
	for d, i in docs {
		flags := d.flags
		if len(d.fields) == 0 {
			flags &~= DF_FIELDS
		} else {
			flags |= DF_FIELDS
		}
		prim.write_u8(w, flags)
		prim.write_uvarint(w, u64(oidx[i]))
		prim.write_uvarint(w, u64(pidx[i]))
		prim.write_u8(w, d.kind)
		prim.write_ivarint(w, i64(d.hlc - prev_hlc))
		prev_hlc = d.hlc
		shared := 0
		for shared < len(d.ref) && shared < len(prev_ref) && d.ref[shared] == prev_ref[shared] {
			shared += 1
		}
		prim.write_uvarint(w, u64(shared))
		prim.write_bytes(w, d.ref[shared:])
		prev_ref = d.ref
		prim.write_uvarint(w, u64(d.part))
		if flags & DF_CHUNK != 0 {
			prim.write_uvarint(w, d.chunk)
		}
		prim.write_uvarint(w, u64(d.len))
		if flags & DF_FIELDS != 0 {
			prim.write_uvarint(w, u64(len(d.fields)))
			for f in d.fields {
				prim.write_uvarint(w, u64(strs[string(f.name)]))
				prim.write_uvarint(w, u64(strs[string(f.value)]))
			}
		}
		if flags & DF_TEXT != 0 {
			prim.write_uvarint(w, u64(d.frame - prev_frame))
			prim.write_uvarint(w, u64(d.frame_off))
			prev_frame = d.frame
		}
	}
	if w.err == .None {
		prim.write_u32le(w, xxhash.XXH32(w.buf[start:]))
	}
	return
}

@(private)
_intern_id :: proc "contextless" (arr: []prim.Id, n: ^int, id: prim.Id) -> int {
	for i := n^ - 1; i >= 0; i -= 1 {
		if arr[i] == id {
			return i
		}
	}
	arr[n^] = id
	n^ += 1
	return n^ - 1
}

@(private)
_intern_str :: proc(m: ^map[string]u32, order: ^[dynamic]string, s: string) {
	if s in m {
		return
	}
	m[s] = u32(len(order))
	append(order, s)
}

doc_block_decode :: proc(b: ^Doc_Block, data: []u8, blk: u64, first: u32, max_n: int, text_base: i64) -> Error {
	b.valid = false
	if len(data) < 5 || xxhash.XXH32(data[:len(data) - 4]) != prim.get_u32le(data[len(data) - 4:]) {
		return .Corrupt
	}
	body := data[:len(data) - 4]
	r := prim.reader(body)
	n := int(prim.read_u8(&r)) + 1
	if n > max_n {
		return .Corrupt
	}
	base_hlc := prim.read_u64le(&r)
	nob := prim.read_uvarint(&r)
	if nob == 0 || nob > u64(n) {
		return .Corrupt
	}
	clear(&b.objects)
	for _ in 0 ..< nob {
		append(&b.objects, prim.read_id(&r))
	}
	npt := prim.read_uvarint(&r)
	if npt == 0 || npt > u64(n) {
		return .Corrupt
	}
	clear(&b.parts)
	for _ in 0 ..< npt {
		append(&b.parts, prim.read_id(&r))
	}
	nstr := prim.read_uvarint(&r)
	if nstr > u64(n * MAX_FIELDS * 2) {
		return .Corrupt
	}
	clear(&b.strs)
	for _ in 0 ..< nstr {
		append(&b.strs, prim.read_bytes(&r))
	}
	if r.err != .None {
		return .Corrupt
	}
	clear(&b.refs)
	clear(&b.fields)
	ref_at: [DOC_BLOCK][2]int
	field_at: [DOC_BLOCK][2]int
	prev_hlc := base_hlc
	prev_ref := [2]int{0, 0}
	frame := text_base
	for i in 0 ..< n {
		d := &b.docs[i]
		d^ = {}
		d.id = first + u32(i)
		d.flags = prim.read_u8(&r)
		oi := prim.read_uvarint(&r)
		pi := prim.read_uvarint(&r)
		if oi >= nob || pi >= npt {
			return .Corrupt
		}
		d.object = b.objects[oi]
		d.participant = b.parts[pi]
		d.kind = prim.read_u8(&r)
		d.hlc = prev_hlc + u64(prim.read_ivarint(&r))
		prev_hlc = d.hlc
		shared := int(prim.read_uvarint(&r))
		suffix := prim.read_bytes(&r)
		if r.err != .None || shared > prev_ref[1] || shared + len(suffix) > MAX_REF {
			return .Corrupt
		}
		start := len(b.refs)
		for k in 0 ..< shared {
			append(&b.refs, b.refs[prev_ref[0] + k])
		}
		append(&b.refs, ..suffix)
		ref_at[i] = {start, shared + len(suffix)}
		prev_ref = ref_at[i]
		part := prim.read_uvarint(&r)
		if part > u64(max(u32)) {
			return .Corrupt
		}
		d.part = u32(part)
		if d.flags & DF_CHUNK != 0 {
			d.chunk = prim.read_uvarint(&r)
		}
		ln := prim.read_uvarint(&r)
		if ln > CHUNK {
			return .Corrupt
		}
		d.len = u32(ln)
		field_at[i] = {len(b.fields), 0}
		if d.flags & DF_FIELDS != 0 {
			nf := prim.read_uvarint(&r)
			if nf > MAX_FIELDS {
				return .Corrupt
			}
			for _ in 0 ..< nf {
				k := prim.read_uvarint(&r)
				v := prim.read_uvarint(&r)
				if k >= nstr || v >= nstr {
					return .Corrupt
				}
				append(&b.fields, Field_Bytes{b.strs[k], b.strs[v]})
			}
			field_at[i][1] = int(nf)
		}
		if d.flags & DF_TEXT != 0 {
			fd := prim.read_uvarint(&r)
			fo := prim.read_uvarint(&r)
			if fd > 1 << 40 || fo > CHUNK + FRAME {
				return .Corrupt
			}
			frame += i64(fd)
			d.frame = frame
			d.frame_off = u32(fo)
		}
		if r.err != .None {
			return .Corrupt
		}
	}
	if !prim.reader_done(&r) {
		return .Corrupt
	}
	for i in 0 ..< n {
		b.docs[i].ref = b.refs[ref_at[i][0]:][:ref_at[i][1]]
		b.docs[i].fields = b.fields[field_at[i][0]:][:field_at[i][1]]
	}
	b.blk = blk
	b.n = n
	b.first = first
	b.valid = true
	return .None
}

doc_load :: proc(c: ^Cache, s: ^Seg, b: ^Doc_Block, blk: u64) -> Error {
	if b.valid && b.blk == blk && b.gen == s.gen {
		return .None
	}
	b.valid = false
	d, off, n := seg_doc_span(c, s, blk) or_return
	if n > 64 * 1024 * 1024 {
		return .Corrupt
	}
	if grow(&b.raw, int(n)) != nil {
		return .No_Memory
	}
	cache_read(c, s, off, b.raw[:]) or_return
	first := max(blk * DOC_BLOCK, s.f.lo)
	last := min(blk * DOC_BLOCK + DOC_BLOCK, s.f.hi)
	if e := doc_block_decode(b, b.raw[:], blk, u32(first), int(last - first), d.text_base); e != .None {
		return e
	}
	if u64(b.n) != last - first {
		b.valid = false
		return .Corrupt
	}
	b.gen = s.gen
	return .None
}

frame_write :: proc(w: ^prim.Writer, raw: []u8, table: ^[1 << LZ_HASH_BITS]i32, scratch: ^[dynamic]u8) {
	clear(scratch)
	cw := prim.writer(scratch)
	lz_compress(&cw, raw, table)
	prim.write_uvarint(w, u64(len(raw)))
	start: int
	if cw.err == .None && len(scratch) < len(raw) {
		prim.write_uvarint(w, u64(len(scratch)))
		start = len(w.buf)
		prim.write_raw(w, scratch[:])
	} else {
		prim.write_uvarint(w, 0)
		start = len(w.buf)
		prim.write_raw(w, raw)
	}
	if w.err == .None {
		prim.write_u32le(w, xxhash.XXH32(w.buf[start:]))
	}
}

frame_size :: proc(c: ^Cache, s: ^Seg, at: i64) -> (size: i64, err: Error) {
	end := s.f.text_off + s.f.text_len
	if at < s.f.text_off || at >= end {
		return 0, .Corrupt
	}
	hb: [20]u8
	hn := min(i64(len(hb)), end - at)
	cache_read(c, s, at, hb[:hn]) or_return
	pos := 0
	raw, ok1 := uv(hb[:hn], &pos)
	clen, ok2 := uv(hb[:hn], &pos)
	if !ok1 || !ok2 || raw > CHUNK + FRAME || clen > raw {
		return 0, .Corrupt
	}
	size = i64(pos) + i64(clen if clen > 0 else raw) + 4
	if at + size > end {
		return 0, .Corrupt
	}
	return size, .None
}

frame_read :: proc(c: ^Cache, s: ^Seg, at: i64, out: ^[dynamic]u8, scratch: ^[dynamic]u8) -> Error {
	if at < s.f.text_off || at >= s.f.text_off + s.f.text_len {
		return .Corrupt
	}
	end := s.f.text_off + s.f.text_len
	hb: [20]u8
	hn := min(i64(len(hb)), end - at)
	cache_read(c, s, at, hb[:hn]) or_return
	pos := 0
	raw, ok1 := uv(hb[:hn], &pos)
	clen, ok2 := uv(hb[:hn], &pos)
	if !ok1 || !ok2 || raw > CHUNK + FRAME || clen > raw {
		return .Corrupt
	}
	plen := i64(clen if clen > 0 else raw)
	if at + i64(pos) + plen + 4 > end {
		return .Corrupt
	}
	if grow(scratch, int(plen) + 4) != nil || grow(out, int(raw)) != nil {
		return .No_Memory
	}
	cache_read(c, s, at + i64(pos), scratch[:]) or_return
	payload := scratch[:plen]
	if xxhash.XXH32(payload) != prim.get_u32le(scratch[plen:]) {
		return .Corrupt
	}
	if clen == 0 {
		copy(out[:], payload)
	} else if !lz_decompress(out[:], payload) {
		return .Corrupt
	}
	return .None
}

src_lookup :: proc(c: ^Cache, s: ^Seg, id: prim.Id) -> (pos: i64, found: bool, err: Error) {
	n := s.f.src_len / SRC_ENTRY
	lo, hi := i64(0), n
	b: [SRC_ENTRY]u8
	for lo < hi {
		mid := (lo + hi) / 2
		cache_read(c, s, s.f.src_off + mid * SRC_ENTRY, b[:]) or_return
		want := id
		cmp := key_cmp(b[:16], want[:])
		if cmp == 0 {
			return i64(prim.get_u64le(b[16:])), true, .None
		}
		if cmp < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return 0, false, .None
}

tomb_load :: proc(s: ^Seg, out: ^[dynamic]u32) -> Error {
	if s.f.tomb_len == 0 {
		return .None
	}
	raw := make([]u8, int(s.f.tomb_len), context.temp_allocator)
	n, e := prim.read_at(s.vfs, s.fd, raw, s.f.tomb_off)
	if e != .None {
		return _perr(e)
	}
	if i64(n) != s.f.tomb_len {
		return .Corrupt
	}
	pos := 0
	cnt, ok := uv(raw, &pos)
	if !ok || cnt > u64(len(raw)) {
		return .Corrupt
	}
	prev := u64(0)
	for i in 0 ..< cnt {
		d, dok := uv(raw, &pos)
		if !dok || (i > 0 && d == 0) {
			return .Corrupt
		}
		prev += d
		if prev > u64(max(u32)) {
			return .Corrupt
		}
		append(out, u32(prev))
	}
	if pos != len(raw) {
		return .Corrupt
	}
	return .None
}

package search

import "base:runtime"
import "core:slice"
import "../prim"

MIN_LEVEL_SIZE :: 1024 * 1024
SMALL_LIST :: 8 * BLOCK
RS_BUF :: 64 * 1024

List_Writer :: struct {
	sw:      ^Seg_Writer,
	start:   i64,
	buf:     [BLOCK]u32,
	n:       int,
	count:   u32,
	emitted: bool,
	last:    u32,
	skips:   [dynamic][2]u64,
	scratch: [dynamic]u8,
	err:     Error,
}

lw_init :: proc(lw: ^List_Writer, sw: ^Seg_Writer, allocator: runtime.Allocator) {
	lw^ = {
		sw = sw,
	}
	lw.skips = make([dynamic][2]u64, allocator)
	lw.scratch = make([dynamic]u8, allocator)
}

lw_destroy :: proc(lw: ^List_Writer) {
	delete(lw.skips)
	delete(lw.scratch)
}

lw_begin :: proc(lw: ^List_Writer) {
	lw.start = sw_off(lw.sw)
	lw.n = 0
	lw.count = 0
	lw.emitted = false
	lw.err = .None
	clear(&lw.skips)
}

lw_push :: proc(lw: ^List_Writer, id: u32) {
	if lw.count > 0 && id >= lw.last {
		lw.err = .Corrupt
		return
	}
	lw.last = id
	lw.buf[lw.n] = id
	lw.n += 1
	lw.count += 1
	if lw.n == BLOCK {
		_lw_emit(lw)
	}
}

@(private)
_lw_emit :: proc(lw: ^List_Writer) {
	if lw.n == 0 {
		return
	}
	if !lw.emitted {
		lw.start = sw_off(lw.sw)
		lw.emitted = true
	}
	asc: [BLOCK]u32
	for i in 0 ..< lw.n {
		asc[i] = lw.buf[lw.n - 1 - i]
	}
	clear(&lw.scratch)
	w := prim.writer(&lw.scratch)
	pfor_encode(&w, asc[:lw.n])
	if w.err != .None {
		lw.err = .No_Memory
		return
	}
	sw_write(lw.sw, lw.scratch[:])
	append(&lw.skips, [2]u64{u64(asc[0]), u64(len(lw.scratch))})
	lw.n = 0
}

lw_end :: proc(lw: ^List_Writer) -> (count: u32, inl: [INLINE]u32, plen, blen: i64) {
	count = lw.count
	if count == 0 {
		return
	}
	if !lw.emitted && count <= INLINE {
		for i in 0 ..< lw.n {
			inl[i] = lw.buf[lw.n - 1 - i]
		}
		return
	}
	_lw_emit(lw)
	blen = sw_off(lw.sw) - lw.start
	clear(&lw.scratch)
	w := prim.writer(&lw.scratch)
	prev := u64(0)
	for sk, i in lw.skips {
		prim.write_uvarint(&w, sk[0] if i == 0 else prev - sk[0])
		prim.write_uvarint(&w, sk[1])
		prev = sk[0]
	}
	if w.err != .None {
		lw.err = .No_Memory
	}
	sw_write(lw.sw, lw.scratch[:])
	plen = sw_off(lw.sw) - lw.start
	return
}

Rstream :: struct {
	vfs:  prim.Vfs,
	fd:   prim.Fd,
	pos:  i64,
	end:  i64,
	buf:  []u8,
	bpos: int,
	blen: int,
	err:  Error,
}

rs_init :: proc(rs: ^Rstream, s: ^Seg, off, end: i64, buf: []u8) {
	rs^ = {
		vfs = s.vfs,
		fd  = s.fd,
		pos = off,
		end = end,
		buf = buf,
	}
}

rs_left :: proc "contextless" (rs: ^Rstream) -> i64 {
	return rs.end - rs.pos + i64(rs.blen - rs.bpos)
}

rs_need :: proc(rs: ^Rstream, n: int) -> bool {
	if rs.err != .None {
		return false
	}
	if rs.blen - rs.bpos >= n {
		return true
	}
	if n > len(rs.buf) {
		rs.err = .Corrupt
		return false
	}
	have := rs.blen - rs.bpos
	copy(rs.buf, rs.buf[rs.bpos:rs.blen])
	rs.bpos = 0
	rs.blen = have
	want := min(i64(len(rs.buf) - have), rs.end - rs.pos)
	if want > 0 {
		got, e := prim.read_at(rs.vfs, rs.fd, rs.buf[have:][:want], rs.pos)
		if e != .None {
			rs.err = _perr(e)
			return false
		}
		if i64(got) != want {
			rs.err = .Corrupt
			return false
		}
		rs.pos += want
		rs.blen += int(want)
	}
	return rs.blen >= n
}

rs_uv :: proc(rs: ^Rstream) -> (v: u64, ok: bool) {
	rs_need(rs, min(10, int(rs_left(rs))))
	if rs.err != .None {
		return 0, false
	}
	p := rs.bpos
	v, ok = uv(rs.buf[:rs.blen], &p)
	if !ok {
		rs.err = .Corrupt
		return 0, false
	}
	rs.bpos = p
	return v, true
}

rs_take :: proc(rs: ^Rstream, n: int) -> []u8 {
	if !rs_need(rs, n) {
		if rs.err == .None {
			rs.err = .Corrupt
		}
		return nil
	}
	out := rs.buf[rs.bpos:][:n]
	rs.bpos += n
	return out
}

rs_copy :: proc(rs: ^Rstream, sw: ^Seg_Writer, n: i64) {
	left := n
	for left > 0 && rs.err == .None {
		k := int(min(left, i64(len(rs.buf))))
		b := rs_take(rs, k)
		if b == nil {
			return
		}
		sw_write(sw, b)
		left -= i64(k)
	}
}

Merge_Phase :: enum u8 {
	Text,
	Docs,
	Post,
	Src,
	Tomb,
	Kv_Files,
	Kv_Scopes,
	Vec_Ids,
	Vec_Data,
	Vec_Encode,
	Ivf,
	Finish,
}

Merge :: struct {
	from:      int,
	to:        int,
	segs:      [dynamic]Seg,
	phase:     Merge_Phase,
	sw:        Seg_Writer,
	lo:        u64,
	hi:        u64,
	dead:      [dynamic]u32,
	keep:      [dynamic]u32,
	has_dead:  [dynamic]bool,
	shift:     [dynamic]i64,
	in_i:      int,
	rs:        Rstream,
	rs_buf:    []u8,
	rs2:       Rstream,
	rs2_buf:   []u8,
	started:   bool,
	blk:       u64,
	blocks:    [dynamic]Doc_Block,
	enc:       [dynamic]u8,
	metas:     [DOC_BLOCK]Doc_Meta,
	dixs:      [dynamic]Dix,
	dcs:       [dynamic]Dict_Cursor,
	live:      [dynamic]bool,
	lw:        List_Writer,
	pl:        Plist,
	src_rs:    [dynamic]Rstream,
	src_bufs:  [dynamic][]u8,
	src_cur:   [dynamic][SRC_ENTRY]u8,
	kvcs:      [dynamic]Kv_Cursor,
	dirty:     [dynamic][dynamic][3]i64,
	remap:     [dynamic][dynamic][2]i64,
	tpos:      i64,
	dk:        int,
	delta:     i64,
	fraw:      [dynamic]u8,
	fscratch:  [dynamic]u8,
	lz:        ^[1 << LZ_HASH_BITS]i32,
	vdead:     [dynamic][dynamic]u32,
	vbase:     [dynamic]u32,
	vdirs:     [dynamic][]u8,
	vin:       int,
	vpos:      int,
	vk:        int,
	ve:        int,
	cb:        ^Cb,
	venc:      [dynamic]Ivf_Entry,
	vcodes:    [dynamic]u8,
	vdir:      []u8,
	vbuf:      []u8,
	kw:        Kv_Writer,
	arena:     runtime.Arena,
	alloc:     runtime.Allocator,
}

merge_pick :: proc(ix: ^Index) -> (from, to: int, ok: bool) {
	n := len(ix.segs)
	f := ix.opts.merge_factor
	if n < 1 {
		return
	}
	level :: proc(size: i64, f: int) -> int {
		l := 0
		s := max(size, MIN_LEVEL_SIZE) / MIN_LEVEL_SIZE
		for s >= i64(f) {
			s /= i64(f)
			l += 1
		}
		return l
	}
	run_end := n
	for run_end > 0 && n >= 2 {
		lv := level(ix.segs[run_end - 1].size, f)
		run_start := run_end - 1
		for run_start > 0 && level(ix.segs[run_start - 1].size, f) == lv {
			run_start -= 1
		}
		if run_end - run_start >= f {
			return run_end - f, run_end, true
		}
		run_end = run_start
	}
	if ix.man.cb_gen != 0 {
		for s, i in ix.segs {
			if s.f.vec_n > 0 && s.f.cb_gen != ix.man.cb_gen {
				return i, i + 1, true
			}
		}
	}
	if n > 4 * f {
		best, best_size := -1, max(i64)
		for i in 0 ..= n - f {
			total := i64(0)
			for k in i ..< i + f {
				total += ix.segs[k].size
			}
			if total < best_size {
				best, best_size = i, total
			}
		}
		return best, best + f, true
	}
	return
}

merge_start :: proc(ix: ^Index, from, to: int) -> Error {
	m, aerr := new(Merge, ix.allocator)
	if aerr != nil {
		return .No_Memory
	}
	m.arena = {}
	if runtime.arena_init(&m.arena, 1024 * 1024, ix.allocator) != nil {
		free(m, ix.allocator)
		return .No_Memory
	}
	m.alloc = runtime.arena_allocator(&m.arena)
	ix.merge = m
	m.from = from
	m.to = to
	a := m.alloc
	m.segs = make([dynamic]Seg, a)
	for i in from ..< to {
		append(&m.segs, ix.segs[i])
	}
	m.lo = m.segs[0].f.lo
	m.hi = m.segs[len(m.segs) - 1].f.hi
	m.dead = make([dynamic]u32, a)
	m.keep = make([dynamic]u32, a)
	all := make([dynamic]u32, a)
	for &s in ix.segs {
		tomb_load(&s, &all) or_return
	}
	slice.sort(all[:])
	for d in slice.unique(all[:]) {
		if u64(d) >= m.lo && u64(d) < m.hi {
			append(&m.dead, d)
		}
	}
	mine := make([dynamic]u32, a)
	for &s in m.segs {
		tomb_load(&s, &mine) or_return
	}
	slice.sort(mine[:])
	for d in slice.unique(mine[:]) {
		if u64(d) < m.lo {
			purged, perr := doc_purged(ix, d)
			if perr != .None {
				return perr
			}
			if !purged {
				append(&m.keep, d)
			}
		}
	}
	m.has_dead = make([dynamic]bool, a)
	m.shift = make([dynamic]i64, a)
	for s in m.segs {
		hd := false
		for d in m.dead {
			if u64(d) >= s.f.lo && u64(d) < s.f.hi {
				hd = true
				break
			}
		}
		append(&m.has_dead, hd)
		append(&m.shift, 0)
	}
	m.dirty = make([dynamic][dynamic][3]i64, len(m.segs), a)
	m.remap = make([dynamic][dynamic][2]i64, len(m.segs), a)
	for i in 0 ..< len(m.segs) {
		m.dirty[i] = make([dynamic][3]i64, a)
		m.remap[i] = make([dynamic][2]i64, a)
		if !ix.man.store || !m.has_dead[i] {
			continue
		}
		s := &m.segs[i]
		b: Doc_Block
		db_init(&b, context.temp_allocator)
		for d in m.dead {
			if u64(d) < s.f.lo || u64(d) >= s.f.hi {
				continue
			}
			doc_load(&ix.cache, s, &b, u64(d) / DOC_BLOCK) or_return
			dm := &b.docs[d - b.first]
			if dm.flags & DF_DELETED == 0 && dm.flags & DF_TEXT != 0 && dm.len > 0 {
				append(&m.dirty[i], [3]i64{dm.frame, i64(dm.frame_off), i64(dm.len)})
			}
		}
		slice.sort_by(m.dirty[i][:], proc(x, y: [3]i64) -> bool {
			return x[0] < y[0] || (x[0] == y[0] && x[1] < y[1])
		})
	}
	m.rs_buf = make([]u8, RS_BUF, a)
	m.rs2_buf = make([]u8, RS_BUF, a)
	m.blocks = make([dynamic]Doc_Block, len(m.segs), a)
	for &b in m.blocks {
		db_init(&b, a)
	}
	m.enc = make([dynamic]u8, a)
	base_pmax := u64(0)
	for i in 0 ..< from {
		base_pmax = max(base_pmax, ix.segs[i].f.max_hlc)
	}
	buf: Name_Buf
	if e := sw_begin(&m.sw, ix.vfs, file_path(ix, "merge.tmp", &buf), m.lo, m.hi, ix.man.store, base_pmax, a); e != .None {
		return e
	}
	for s in m.segs {
		m.sw.f.total_len += s.f.total_len
	}
	m.sw.f.text_off = sw_off(&m.sw)
	m.phase = .Text
	m.in_i = 0
	m.started = false
	return .None
}

merge_abort :: proc(ix: ^Index) {
	m := ix.merge
	if m == nil {
		return
	}
	if m.sw.out.fd != prim.INVALID_FD {
		prim.close_file(m.sw.out.vfs, m.sw.out.fd)
		m.sw.out.fd = prim.INVALID_FD
	}
	_remove(ix, "merge.tmp")
	runtime.arena_destroy(&m.arena)
	free(m, ix.allocator)
	ix.merge = nil
}

merge_step :: proc(ix: ^Index, budget: i64) -> (more: bool, err: Error) {
	if ix.broken {
		return false, .Corrupt
	}
	if ix.merge == nil {
		from, to, ok := merge_pick(ix)
		if !ok {
			return false, .None
		}
		if e := merge_start(ix, from, to); e != .None {
			merge_abort(ix)
			return false, e
		}
	}
	m := ix.merge
	start := sw_off(&m.sw)
	for sw_off(&m.sw) - start < budget {
		done, e := _merge_work(ix, m)
		if e == .None && m.sw.out.err != .None {
			e = m.sw.out.err
		}
		if e != .None {
			merge_abort(ix)
			return false, e
		}
		if done {
			runtime.arena_destroy(&m.arena)
			free(m, ix.allocator)
			ix.merge = nil
			_, _, again := merge_pick(ix)
			return again, .None
		}
	}
	return true, .None
}

@(private)
_merge_work :: proc(ix: ^Index, m: ^Merge) -> (done: bool, err: Error) {
	switch m.phase {
	case .Text:
		if m.in_i >= len(m.segs) {
			m.sw.f.text_len = sw_off(&m.sw) - m.sw.f.text_off
			m.sw.f.docs_off = sw_off(&m.sw)
			m.phase = .Docs
			m.blk = m.lo / DOC_BLOCK
			return false, .None
		}
		return false, _merge_text(ix, m)
	case .Docs:
		if m.lo == m.hi || m.blk > (m.hi - 1) / DOC_BLOCK {
			m.sw.f.docs_len = sw_off(&m.sw) - m.sw.f.docs_off
			_merge_post_init(ix, m) or_return
			m.phase = .Post
			return false, .None
		}
		return false, _merge_block(ix, m)
	case .Post:
		fin := _merge_term(ix, m) or_return
		if fin {
			sw_post_end(&m.sw)
			_merge_src_init(m)
			m.sw.f.src_off = sw_off(&m.sw)
			m.phase = .Src
		}
		return false, .None
	case .Src:
		fin := _merge_src(m) or_return
		if fin {
			m.sw.f.src_len = sw_off(&m.sw) - m.sw.f.src_off
			m.phase = .Tomb
		}
		return false, .None
	case .Tomb:
		m.sw.f.tomb_off = sw_off(&m.sw)
		if len(m.keep) > 0 {
			clear(&m.enc)
			w := prim.writer(&m.enc)
			prim.write_uvarint(&w, u64(len(m.keep)))
			prev := u32(0)
			for d in m.keep {
				prim.write_uvarint(&w, u64(d - prev))
				prev = d
			}
			sw_meta(&m.sw, m.enc[:])
		}
		m.sw.f.tomb_len = sw_off(&m.sw) - m.sw.f.tomb_off
		_merge_kv_init(m, .Files) or_return
		m.phase = .Kv_Files
		return false, .None
	case .Kv_Files:
		fin := _merge_kv(m, .Files) or_return
		if fin {
			_merge_kv_init(m, .Scopes) or_return
			m.phase = .Kv_Scopes
		}
		return false, .None
	case .Kv_Scopes:
		fin := _merge_kv(m, .Scopes) or_return
		if fin {
			_merge_vec_init(ix, m) or_return
			m.phase = .Vec_Ids
		}
		return false, .None
	case .Vec_Ids, .Vec_Data, .Vec_Encode:
		return false, _merge_vec(m)
	case .Ivf:
		return false, _merge_ivf(m)
	case .Finish:
		f := sw_finish(&m.sw) or_return
		prim.close_file(m.sw.out.vfs, m.sw.out.fd)
		m.sw.out.fd = prim.INVALID_FD
		for s in m.segs {
			cache_drop(&ix.cache, s.gen)
		}
		if e := commit_segment(ix, "merge.tmp", m.from, m.to, &f); e != .None {
			_remove(ix, "merge.tmp")
			return false, e
		}
		return true, .None
	}
	return false, .Invalid
}

@(private)
_dead_in :: proc "contextless" (dead: []u32, lo, hi: u64) -> bool {
	l, h := 0, len(dead)
	for l < h {
		mid := (l + h) / 2
		if u64(dead[mid]) < lo {
			l = mid + 1
		} else {
			h = mid
		}
	}
	return l < len(dead) && u64(dead[l]) < hi
}

@(private)
_is_dead :: proc(dead: []u32, id: u32) -> bool {
	_, found := slice.binary_search(dead, id)
	return found
}

@(private)
_merge_block :: proc(ix: ^Index, m: ^Merge) -> Error {
	blk := m.blk
	m.blk += 1
	b_lo := max(blk * DOC_BLOCK, m.lo)
	b_hi := min(blk * DOC_BLOCK + DOC_BLOCK, m.hi)
	first_in, last_in := -1, -1
	for s, i in m.segs {
		if s.f.lo < s.f.hi && s.f.lo < b_hi && s.f.hi > b_lo {
			if first_in < 0 {
				first_in = i
			}
			last_in = i
		}
	}
	if first_in < 0 {
		return .Corrupt
	}
	dead := _dead_in(m.dead[:], b_lo, b_hi)
	if first_in == last_in && !dead && len(m.remap[first_in]) == 0 {
		s := &m.segs[first_in]
		d, off, n := seg_doc_span(&ix.cache, s, blk) or_return
		d.doc_off = sw_off(&m.sw)
		if ix.man.store {
			d.text_base += m.shift[first_in]
		}
		sw_dir(&m.sw, d)
		rs_init(&m.rs2, s, off, off + n, m.rs2_buf)
		rs_copy(&m.rs2, &m.sw, n)
		return m.rs2.err
	}
	n := 0
	mn, mx := max(u64), u64(0)
	for i in first_in ..= last_in {
		s := &m.segs[i]
		if s.f.lo == s.f.hi {
			continue
		}
		b := &m.blocks[i]
		b.valid = false
		doc_load(&ix.cache, s, b, blk) or_return
		for k in 0 ..< b.n {
			dm := b.docs[k]
			if ix.man.store && dm.flags & DF_TEXT != 0 {
				dm.frame = _remap(m, i, dm.frame)
			}
			if _is_dead(m.dead[:], dm.id) {
				dm.flags |= DF_DELETED
			}
			mn = min(mn, dm.hlc)
			mx = max(mx, dm.hlc)
			m.metas[n] = dm
			n += 1
		}
	}
	if u64(n) != b_hi - b_lo {
		return .Corrupt
	}
	clear(&m.enc)
	w := prim.writer(&m.enc)
	tb := doc_block_encode(&w, m.metas[:n])
	if w.err != .None {
		return .No_Memory
	}
	sw_dir(&m.sw, Dir_Entry{doc_off = sw_off(&m.sw), text_base = tb, min_hlc = mn, max_hlc = mx})
	sw_write(&m.sw, m.enc[:])
	return .None
}

@(private)
_merge_post_init :: proc(ix: ^Index, m: ^Merge) -> Error {
	a := m.alloc
	m.dixs = make([dynamic]Dix, a)
	m.dcs = make([dynamic]Dict_Cursor, len(m.segs), a)
	m.live = make([dynamic]bool, len(m.segs), a)
	for &s in m.segs {
		d := dix_load(&ix.cache, &s, a) or_return
		append(&m.dixs, d)
	}
	for i in 0 ..< len(m.segs) {
		dc_init(&m.dcs[i], &ix.cache, &m.segs[i], &m.dixs[i], a)
		m.live[i] = dc_next(&m.dcs[i])
		if m.dcs[i].err != .None {
			return m.dcs[i].err
		}
	}
	lw_init(&m.lw, &m.sw, a)
	sw_post_begin(&m.sw)
	return .None
}

@(private)
_merge_term :: proc(ix: ^Index, m: ^Merge) -> (fin: bool, err: Error) {
	best := -1
	for i in 0 ..< len(m.segs) {
		if !m.live[i] {
			continue
		}
		if best < 0 || key_less(dc_key(&m.dcs[i]), dc_key(&m.dcs[best])) {
			best = i
		}
	}
	if best < 0 {
		return true, .None
	}
	kb: [MAX_KEY]u8
	key := kb[:copy(kb[:], dc_key(&m.dcs[best]))]
	has: [64]bool
	terms: [64]Term
	total := u64(0)
	fast := true
	nin := len(m.segs)
	if nin > len(has) {
		return false, .Invalid
	}
	for i in 0 ..< nin {
		if m.live[i] && key_cmp(dc_key(&m.dcs[i]), key) == 0 {
			has[i] = true
			terms[i] = m.dcs[i].term
			total += u64(terms[i].count)
			if terms[i].count <= INLINE || m.has_dead[i] {
				fast = false
			}
		}
	}
	if total < SMALL_LIST {
		fast = false
	}
	if fast {
		start := sw_off(&m.sw)
		for i := nin - 1; i >= 0; i -= 1 {
			if !has[i] {
				continue
			}
			s := &m.segs[i]
			rs_init(&m.rs, s, terms[i].off, terms[i].off + terms[i].blen, m.rs_buf)
			rs_copy(&m.rs, &m.sw, terms[i].blen)
			if m.rs.err != .None {
				return false, m.rs.err
			}
		}
		blen := sw_off(&m.sw) - start
		prev := u64(0)
		any := false
		for i := nin - 1; i >= 0; i -= 1 {
			if !has[i] {
				continue
			}
			s := &m.segs[i]
			t := terms[i]
			rs_init(&m.rs, s, t.off + t.blen, t.off + t.plen, m.rs_buf)
			cur := u64(0)
			first := true
			for rs_left(&m.rs) > 0 {
				f, ok1 := rs_uv(&m.rs)
				ln, ok2 := rs_uv(&m.rs)
				if !ok1 || !ok2 {
					return false, .Corrupt
				}
				if first {
					cur = f
					first = false
				} else {
					if f == 0 || f > cur {
						return false, .Corrupt
					}
					cur -= f
				}
				b: [20]u8
				n := 0
				if !any {
					n += prim.put_uvarint(b[n:], cur)
				} else {
					if cur >= prev {
						return false, .Corrupt
					}
					n += prim.put_uvarint(b[n:], prev - cur)
				}
				n += prim.put_uvarint(b[n:], ln)
				sw_write(&m.sw, b[:n])
				any = true
				prev = cur
			}
		}
		plen := sw_off(&m.sw) - start
		if total > u64(max(u32)) {
			return false, .Corrupt
		}
		sw_term(&m.sw, key, u32(total), nil, plen, blen)
	} else {
		lw_begin(&m.lw)
		for i := nin - 1; i >= 0; i -= 1 {
			if !has[i] {
				continue
			}
			pl_init(&m.pl, &ix.cache, &m.segs[i], terms[i])
			t := u32(max(u32))
			for {
				_, ok := pl_seek(&m.pl, t)
				if !ok {
					break
				}
				for k := m.pl.n - 1; k >= 0; k -= 1 {
					id := m.pl.ids[k]
					if id > t {
						continue
					}
					if m.has_dead[i] && _is_dead(m.dead[:], id) {
						continue
					}
					lw_push(&m.lw, id)
				}
				if m.pl.ids[0] == 0 || m.pl.ninl > 0 {
					break
				}
				t = m.pl.ids[0] - 1
			}
			if m.pl.err != .None {
				return false, m.pl.err
			}
		}
		count, inl, plen, blen := lw_end(&m.lw)
		if m.lw.err != .None {
			return false, m.lw.err
		}
		sw_term(&m.sw, key, count, inl[:], plen, blen)
	}
	for i in 0 ..< nin {
		if has[i] {
			m.live[i] = dc_next(&m.dcs[i])
			if m.dcs[i].err != .None {
				return false, m.dcs[i].err
			}
		}
	}
	return false, .None
}

@(private)
_merge_src_init :: proc(m: ^Merge) {
	a := m.alloc
	n := len(m.segs)
	m.src_rs = make([dynamic]Rstream, n, a)
	m.src_bufs = make([dynamic][]u8, n, a)
	m.src_cur = make([dynamic][SRC_ENTRY]u8, n, a)
	m.live = make([dynamic]bool, n, a)
	for i in 0 ..< n {
		s := &m.segs[i]
		m.src_bufs[i] = make([]u8, 16 * 1024, a)
		rs_init(&m.src_rs[i], s, s.f.src_off, s.f.src_off + s.f.src_len, m.src_bufs[i])
		_src_advance(m, i)
	}
}

@(private)
_src_advance :: proc(m: ^Merge, i: int) {
	if rs_left(&m.src_rs[i]) < SRC_ENTRY {
		m.live[i] = false
		return
	}
	b := rs_take(&m.src_rs[i], SRC_ENTRY)
	if b == nil {
		m.live[i] = false
		return
	}
	copy(m.src_cur[i][:], b)
	m.live[i] = true
}

@(private)
_merge_src :: proc(m: ^Merge) -> (fin: bool, err: Error) {
	for _ in 0 ..< 1024 {
		best := -1
		for i in 0 ..< len(m.segs) {
			if m.src_rs[i].err != .None {
				return false, m.src_rs[i].err
			}
			if !m.live[i] {
				continue
			}
			if best < 0 || key_less(m.src_cur[i][:16], m.src_cur[best][:16]) {
				best = i
			}
		}
		if best < 0 {
			return true, .None
		}
		out := m.src_cur[best]
		pos := prim.get_u64le(out[16:])
		for i in 0 ..< len(m.segs) {
			if m.live[i] && string(m.src_cur[i][:16]) == string(out[:16]) {
				pos = max(pos, prim.get_u64le(m.src_cur[i][16:]))
				_src_advance(m, i)
			}
		}
		prim.put_u64le(out[16:], pos)
		sw_meta(&m.sw, out[:])
	}
	return false, .None
}

@(private)
_merge_kv_init :: proc(m: ^Merge, which: Kv) -> Error {
	a := m.alloc
	n := len(m.segs)
	m.kvcs = make([dynamic]Kv_Cursor, n, a)
	m.live = make([dynamic]bool, n, a)
	for i in 0 ..< n {
		kvc_init(&m.kvcs[i], &m.segs[i], which, a) or_return
		m.live[i] = kvc_next(&m.kvcs[i])
		if m.kvcs[i].err != .None {
			return m.kvcs[i].err
		}
	}
	kvw_begin(&m.kw, &m.sw, which, a)
	return .None
}

@(private)
_merge_kv :: proc(m: ^Merge, which: Kv) -> (fin: bool, err: Error) {
	for _ in 0 ..< 64 {
		best := -1
		for i in 0 ..< len(m.segs) {
			if !m.live[i] {
				continue
			}
			if best < 0 || key_less(m.kvcs[i].key[:], m.kvcs[best].key[:]) {
				best = i
			}
		}
		if best < 0 {
			kvw_end(&m.kw)
			return true, .None
		}
		newest := best
		for i in 0 ..< len(m.segs) {
			if m.live[i] && key_cmp(m.kvcs[i].key[:], m.kvcs[best].key[:]) == 0 && i > newest {
				newest = i
			}
		}
		kc := &m.kvcs[newest]
		if !(which == .Files && len(kc.val) == 0 && m.lo == 0) {
			kvw_put(&m.kw, kc.key[:], kc.val)
		}
		kb := make([]u8, len(m.kvcs[best].key), context.temp_allocator)
		copy(kb, m.kvcs[best].key[:])
		for i in 0 ..< len(m.segs) {
			if m.live[i] && key_cmp(m.kvcs[i].key[:], kb) == 0 {
				m.live[i] = kvc_next(&m.kvcs[i])
				if m.kvcs[i].err != .None {
					return false, m.kvcs[i].err
				}
			}
		}
	}
	return false, .None
}

@(private)
_remap :: proc(m: ^Merge, i: int, old: i64) -> i64 {
	r := m.remap[i][:]
	lo, hi := 0, len(r)
	for lo < hi {
		mid := (lo + hi) / 2
		if r[mid][0] < old {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	d := r[lo - 1][1] if lo > 0 else 0
	return old + m.shift[i] + d
}

@(private)
_merge_text :: proc(ix: ^Index, m: ^Merge) -> Error {
	s := &m.segs[m.in_i]
	end := s.f.text_off + s.f.text_len
	if !m.started {
		m.shift[m.in_i] = sw_off(&m.sw) - s.f.text_off
		m.tpos = s.f.text_off
		m.dk = 0
		m.delta = 0
		m.started = true
	}
	dirty := m.dirty[m.in_i][:]
	stop := end
	if m.dk < len(dirty) {
		stop = dirty[m.dk][0]
		if stop < m.tpos || stop >= end {
			return .Corrupt
		}
	}
	if m.tpos < stop {
		k := min(stop - m.tpos, RS_BUF)
		rs_init(&m.rs, s, m.tpos, m.tpos + k, m.rs_buf)
		rs_copy(&m.rs, &m.sw, k)
		if m.rs.err != .None {
			return m.rs.err
		}
		m.tpos += k
		return .None
	}
	if m.dk < len(dirty) {
		fp := dirty[m.dk][0]
		if m.fraw == nil {
			m.fraw = make([dynamic]u8, m.alloc)
			m.fscratch = make([dynamic]u8, m.alloc)
			m.lz = new([1 << LZ_HASH_BITS]i32, m.alloc)
		}
		size := frame_size(&ix.cache, s, fp) or_return
		frame_read(&ix.cache, s, fp, &m.fraw, &m.fscratch) or_return
		for m.dk < len(dirty) && dirty[m.dk][0] == fp {
			off, n := int(dirty[m.dk][1]), int(dirty[m.dk][2])
			if off + n > len(m.fraw) {
				return .Corrupt
			}
			for k in off ..< off + n {
				m.fraw[k] = 0
			}
			m.dk += 1
		}
		clear(&m.enc)
		w := prim.writer(&m.enc)
		frame_write(&w, m.fraw[:], m.lz, &m.fscratch)
		if w.err != .None {
			return .No_Memory
		}
		sw_write(&m.sw, m.enc[:])
		m.delta += i64(len(m.enc)) - size
		append(&m.remap[m.in_i], [2]i64{fp, m.delta})
		m.tpos = fp + size
		return .None
	}
	m.in_i += 1
	m.started = false
	return .None
}

doc_purged :: proc(ix: ^Index, id: u32) -> (purged: bool, err: Error) {
	for &s in ix.segs {
		if u64(id) >= s.f.lo && u64(id) < s.f.hi {
			b: Doc_Block
			db_init(&b, context.temp_allocator)
			doc_load(&ix.cache, &s, &b, u64(id) / DOC_BLOCK) or_return
			return b.docs[id - b.first].flags & DF_DELETED != 0, .None
		}
	}
	return true, .None
}

purge_pick :: proc(ix: ^Index) -> (from, to: int, ok: bool, err: Error) {
	all := make([dynamic]u32, context.temp_allocator)
	for &s in ix.segs {
		tomb_load(&s, &all) or_return
	}
	slice.sort(all[:])
	for d in slice.unique(all[:]) {
		purged := doc_purged(ix, d) or_return
		if purged {
			continue
		}
		for &s, i in ix.segs {
			if u64(d) >= s.f.lo && u64(d) < s.f.hi {
				return i, i + 1, true, .None
			}
		}
	}
	return 0, 0, false, .None
}

purge_step :: proc(ix: ^Index, budget: i64) -> (more: bool, err: Error) {
	if ix.merge == nil {
		from, to, ok := purge_pick(ix) or_return
		if !ok {
			return false, .None
		}
		if e := merge_start(ix, from, to); e != .None {
			merge_abort(ix)
			return false, e
		}
	}
	_ = merge_step(ix, budget) or_return
	if ix.merge != nil {
		return true, .None
	}
	_, _, again := purge_pick(ix) or_return
	return again, .None
}

@(private)
_merge_vec_init :: proc(ix: ^Index, m: ^Merge) -> Error {
	a := m.alloc
	n := len(m.segs)
	m.vdead = make([dynamic][dynamic]u32, n, a)
	m.vbase = make([dynamic]u32, n, a)
	m.vdirs = make([dynamic][]u8, n, a)
	total := u64(0)
	for i in 0 ..< n {
		s := &m.segs[i]
		m.vdead[i] = make([dynamic]u32, a)
		m.vbase[i] = u32(total)
		if s.f.vec_n == 0 {
			continue
		}
		if s.f.vec_dim != ix.man.dim {
			return .Corrupt
		}
		if m.has_dead[i] {
			ids := make([]u8, int(s.f.vec_n) * 4, context.temp_allocator)
			got, e := prim.read_at(s.vfs, s.fd, ids, s.f.vids_off)
			if e != .None {
				return _perr(e)
			}
			if got != len(ids) {
				return .Corrupt
			}
			for p in 0 ..< int(s.f.vec_n) {
				if _is_dead(m.dead[:], prim.get_u32le(ids[p * 4:])) {
					append(&m.vdead[i], u32(p))
				}
			}
		}
		total += s.f.vec_n - u64(len(m.vdead[i]))
	}
	m.sw.f.vec_n = total
	m.sw.f.vec_dim = ix.man.dim if total > 0 else 0
	m.sw.f.vids_off = sw_off(&m.sw)
	m.vin = 0
	m.vpos = 0
	m.venc = make([dynamic]Ivf_Entry, a)
	m.vcodes = make([dynamic]u8, a)
	if total > 0 && ix.man.cb_gen != 0 {
		m.cb = cb_load(ix, ix.man.cb_gen, a) or_return
		if u64(m.cb.dim) != ix.man.dim {
			return .Corrupt
		}
		for i in 0 ..< n {
			s := &m.segs[i]
			if s.f.vec_n == 0 || s.f.ivf_len == 0 || s.f.cb_gen != m.cb.gen {
				continue
			}
			d := make([]u8, m.cb.k * IVF_DIR, a)
			at := s.f.ivf_off + s.f.ivf_len - i64(len(d))
			got, e := prim.read_at(s.vfs, s.fd, d, at)
			if e != .None {
				return _perr(e)
			}
			if got != len(d) || at < s.f.ivf_off {
				return .Corrupt
			}
			m.vdirs[i] = d
		}
	}
	return .None
}

@(private)
_vdead_before :: proc "contextless" (dead: []u32, p: u32) -> (n: int, is_dead: bool) {
	lo, hi := 0, len(dead)
	for lo < hi {
		mid := (lo + hi) / 2
		if dead[mid] < p {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(dead) && dead[lo] == p
}

@(private)
_merge_vec :: proc(m: ^Merge) -> Error {
	dim := int(m.sw.f.vec_dim)
	if m.vin >= len(m.segs) || dim == 0 {
		m.vin = 0
		m.vpos = 0
		switch m.phase {
		case .Vec_Ids:
			m.sw.f.vdata_off = sw_off(&m.sw)
			m.phase = .Vec_Data
		case .Vec_Data:
			m.sw.f.ivf_off = sw_off(&m.sw)
			m.phase = .Vec_Encode if m.cb != nil else .Finish
		case .Vec_Encode:
			slice.sort_by(m.venc[:], proc(x, y: Ivf_Entry) -> bool {
				return x.list < y.list || (x.list == y.list && x.pos < y.pos)
			})
			m.vdir = make([]u8, m.cb.k * IVF_DIR, m.alloc)
			m.vk = 0
			m.ve = 0
			m.phase = .Ivf
		case .Text, .Docs, .Post, .Src, .Tomb, .Kv_Files, .Kv_Scopes, .Ivf, .Finish:
		}
		return .None
	}
	s := &m.segs[m.vin]
	n := int(s.f.vec_n)
	stale := m.cb != nil && (s.f.ivf_len == 0 || s.f.cb_gen != m.cb.gen)
	if m.vpos >= n || (m.phase == .Vec_Encode && !stale) {
		m.vin += 1
		m.vpos = 0
		return .None
	}
	unit := 4 if m.phase == .Vec_Ids else dim * 4
	per := max(1, (256 * 1024) / unit)
	c := min(per, n - m.vpos)
	if len(m.vbuf) < c * unit {
		m.vbuf = make([]u8, c * unit, m.alloc)
	}
	buf := m.vbuf[:c * unit]
	base := s.f.vids_off if m.phase == .Vec_Ids else s.f.vdata_off
	got, e := prim.read_at(s.vfs, s.fd, buf, base + i64(m.vpos) * i64(unit))
	if e != .None {
		return _perr(e)
	}
	if got != len(buf) {
		return .Corrupt
	}
	dead := m.vdead[m.vin][:]
	for k in 0 ..< c {
		p := u32(m.vpos + k)
		before, is_dead := _vdead_before(dead, p)
		if is_dead {
			continue
		}
		item := buf[k * unit:][:unit]
		switch m.phase {
		case .Vec_Ids:
			sw_meta(&m.sw, item)
		case .Vec_Data:
			sw_write(&m.sw, item)
		case .Vec_Encode:
			v := slice.reinterpret([]f32, item)
			out := m.vbase[m.vin] + p - u32(before)
			kk := cb_assign(m.cb, v)
			at := len(m.venc)
			if grow(&m.vcodes, (at + 1) * m.cb.m) != nil {
				return .No_Memory
			}
			cb_encode(m.cb, v, kk, m.vcodes[at * m.cb.m:][:m.cb.m])
			append(&m.venc, Ivf_Entry{u32(kk), out, u32(at)})
		case .Text, .Docs, .Post, .Src, .Tomb, .Kv_Files, .Kv_Scopes, .Ivf, .Finish:
		}
	}
	m.vpos += c
	return .None
}

@(private)
_merge_ivf :: proc(m: ^Merge) -> Error {
	cb := m.cb
	if m.vk >= cb.k {
		sw_write(&m.sw, m.vdir)
		m.sw.f.ivf_len = sw_off(&m.sw) - m.sw.f.ivf_off
		m.sw.f.cb_gen = cb.gen
		m.phase = .Finish
		return .None
	}
	k := m.vk
	m.vk += 1
	start := sw_off(&m.sw) - m.sw.f.ivf_off
	count := u32(0)
	stride := 4 + cb.m
	for i in 0 ..< len(m.segs) {
		d := m.vdirs[i]
		if d == nil {
			continue
		}
		s := &m.segs[i]
		off := i64(prim.get_u64le(d[k * IVF_DIR:]))
		cnt := int(prim.get_u32le(d[k * IVF_DIR + 8:]))
		if cnt == 0 {
			continue
		}
		nb := cnt * stride
		if off < 0 || off + i64(nb) > s.f.ivf_len - i64(len(d)) {
			return .Corrupt
		}
		if len(m.vbuf) < nb {
			m.vbuf = make([]u8, nb, m.alloc)
		}
		lst := m.vbuf[:nb]
		got, e := prim.read_at(s.vfs, s.fd, lst, s.f.ivf_off + off)
		if e != .None {
			return _perr(e)
		}
		if got != nb {
			return .Corrupt
		}
		dead := m.vdead[i][:]
		for x in 0 ..< cnt {
			ent := lst[x * stride:][:stride]
			p := prim.get_u32le(ent)
			if u64(p) >= s.f.vec_n {
				return .Corrupt
			}
			before, is_dead := _vdead_before(dead, p)
			if is_dead {
				continue
			}
			prim.put_u32le(ent, m.vbase[i] + p - u32(before))
			sw_write(&m.sw, ent)
			count += 1
		}
	}
	ent := make([]u8, stride, context.temp_allocator)
	for m.ve < len(m.venc) && int(m.venc[m.ve].list) == k {
		x := m.venc[m.ve]
		prim.put_u32le(ent, x.pos)
		copy(ent[4:], m.vcodes[int(x.at) * cb.m:][:cb.m])
		sw_write(&m.sw, ent)
		count += 1
		m.ve += 1
	}
	prim.put_u64le(m.vdir[k * IVF_DIR:], u64(start))
	prim.put_u32le(m.vdir[k * IVF_DIR + 8:], count)
	return .None
}

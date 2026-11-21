package search

import "core:slice"
import "../prim"

INS_BATCH :: 512
INS_DEG :: 56
L_INS :: 96
CONS_CAP :: 256
INS_EXTRA :: 16
INS_ALPHA :: f32(1.2)

@(private)
_gb_src :: proc "contextless" (m: ^Merge, o: int) -> (seg: int, pos: u32, ok: bool) {
	for i := len(m.segs) - 1; i >= 0; i -= 1 {
		vb := int(m.vbase[i])
		if vb > o {
			continue
		}
		dead := m.vdead[i][:]
		live := int(m.segs[i].f.vec_n) - len(dead)
		if o >= vb + live {
			continue
		}
		q := u32(o - vb)
		k := 0
		for {
			lo, hi := 0, len(dead)
			for lo < hi {
				mid := (lo + hi) / 2
				if dead[mid] <= q + u32(k) {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			if lo == k {
				break
			}
			k = lo
		}
		return i, q + u32(k), true
	}
	return 0, 0, false
}

@(private)
_gb_new_out :: #force_inline proc "contextless" (gb: ^Graph_Build, t: int) -> u32 {
	return u32(t if t < gb.bstart else t + gb.blive)
}

@(private)
_gb_perm :: proc "contextless" (gb: ^Graph_Build, k: int) -> int {
	return int((u64(k) * gb.perm) % u64(gb.nnew))
}

@(private)
_gcd :: proc "contextless" (a, b: u64) -> u64 {
	x, y := a, b
	for y != 0 {
		x, y = y, x % y
	}
	return x
}

@(private)
_gb_insert_init :: proc(ix: ^Index, m: ^Merge, base: int) -> Error {
	gb := m.gb
	a := gb.alloc
	gb.insert = true
	gb.base = base
	gb.bstart = int(m.vbase[base])
	gb.blive = int(m.segs[base].f.vec_n) - len(m.vdead[base])
	gb.nnew = gb.n - gb.blive
	if gb.nnew > 0 {
		p := (u64(0x9E3779B97F4A7C15) % u64(gb.nnew)) | 1
		for gb.nnew > 1 && _gcd(p, u64(gb.nnew)) != 1 {
			p += 2
		}
		gb.perm = p
	}
	gb.chunk = make([]f32, 2048 * gb.dim, a)
	gb.need = make([]bool, 2048, a)
	gb.rbuf = make([]u8, gb.rec, a)
	gb.dl = make([dynamic]u64, a)
	s := &m.segs[base]
	md, dead := _vm_out(m, base, u32(s.f.medoid))
	gb.medoid = md
	if dead {
		gb.medoid = u32(gb.bstart)
	}
	gb.phase = .ICodes
	return .None
}

@(private)
_gb_icodes :: proc(m: ^Merge) -> Error {
	gb := m.gb
	if gb.cursor >= gb.n {
		gb.cursor = 0
		gb.phase = .IWrite
		return .None
	}
	c := min(2048, gb.n - gb.cursor)
	enc := 0
	for i in 0 ..< c {
		o := gb.cursor + i
		si, p, ok := _gb_src(m, o)
		if !ok {
			return .Corrupt
		}
		s := &m.segs[si]
		gb.need[i] = false
		if s.f.vec_m == u64(gb.m) && s.f.cb_gen == gb.cb.gen {
			got, e := prim.read_at(s.vfs, s.fd, gb.codes[o * gb.m:][:gb.m], s.f.vcodes_off + i64(p) * i64(gb.m))
			if e != .None {
				return _perr(e)
			}
			if got != gb.m {
				return .Corrupt
			}
			continue
		}
		gb.need[i] = true
		enc += 1
		_gb_read_vec(m, o, gb.chunk[i * gb.dim:][:gb.dim]) or_return
	}
	if enc > 0 {
		gb.chunk_lo = gb.cursor
		_run_workers(gb, .Encode, c)
	}
	gb.cursor += c
	m.work += c * gb.m + enc * gb.dim * 16
	return .None
}

@(private)
_prune_vecs :: proc(w: ^Worker, p: u32, ids: []u32, sims: []f32, vecs: []f32, alpha: f32, limit: int) {
	d := w.gb.dim
	resize(&w.order, len(ids))
	order := w.order[:]
	for i in 0 ..< len(ids) {
		order[i] = i
	}
	Ctx :: struct {
		sims: []f32,
	}
	ctx := Ctx{sims}
	slice.sort_by_with_data(order, proc(x, y: int, dd: rawptr) -> bool {
			c := (^Ctx)(dd)
			return c.sims[x] > c.sims[y]
		}, &ctx)
	clear(&w.keep)
	clear(&w.c2)
	for a in ([2]f32{1, alpha}) {
		outer: for i in order {
			if len(w.keep) >= limit {
				break
			}
			c := ids[i]
			if c == p {
				continue
			}
			for r in w.keep {
				if r == c {
					continue outer
				}
			}
			dpc := _dist(sims[i])
			vc := vecs[i * d:][:d]
			for ri in w.c2 {
				if a * _dist(dot(vecs[int(ri) * d:][:d], vc)) <= dpc {
					continue outer
				}
			}
			append(&w.keep, c)
			append(&w.c2, u32(i))
		}
		if a >= alpha {
			break
		}
	}
}

@(private)
_rec_put :: proc(gb: ^Graph_Build, rec: []u8, ids: []u32) {
	ids_at := 4 + gb.dim * 4
	codes_at := ids_at + DEGREE * 4
	slice.fill(rec[ids_at:], 0)
	prim.put_u32le(rec, u32(len(ids)))
	for x, k in ids {
		prim.put_u32le(rec[ids_at + 4 * k:], x)
		copy(rec[codes_at + k * gb.m:], gb.codes[int(x) * gb.m:][:gb.m])
	}
}

@(private)
_rec_write :: proc(m: ^Merge, x: u32, rec: []u8) -> Error {
	if e := prim.write_at(m.sw.out.vfs, m.sw.out.fd, rec, m.sw.f.vdata_off + i64(x) * i64(m.gb.rec)); e != .None {
		return _perr(e)
	}
	return .None
}

@(private)
_gb_iwrite :: proc(ix: ^Index, m: ^Merge) -> Error {
	gb := m.gb
	if gb.cursor == 0 {
		pad := (REC_ALIGN - int(sw_off(&m.sw) % REC_ALIGN)) % REC_ALIGN
		if pad > 0 {
			zeros: [REC_ALIGN]u8
			sw_write(&m.sw, zeros[:pad])
		}
		m.sw.f.vdata_off = sw_off(&m.sw)
		m.sw.f.vrec = i64(gb.rec)
	}
	w := &gb.workers[0]
	end := min(gb.cursor + 256, gb.n)
	rec := gb.rbuf
	d := gb.dim
	ids_at := 4 + d * 4
	bs := &m.segs[gb.base]
	for o in gb.cursor ..< end {
		slice.fill(rec, 0)
		v := slice.reinterpret([]f32, rec[4:][:d * 4])
		if o < gb.bstart || o >= gb.bstart + gb.blive {
			_gb_read_vec(m, o, v) or_return
			sw_write(&m.sw, rec)
			continue
		}
		_, p, ok := _gb_src(m, o)
		if !ok {
			return .Corrupt
		}
		got, e := prim.read_at(bs.vfs, bs.fd, rec, bs.f.vdata_off + i64(p) * bs.f.vrec)
		if e != .None {
			return _perr(e)
		}
		if got != gb.rec {
			return .Corrupt
		}
		dg := int(prim.get_u32le(rec))
		if dg > DEGREE {
			return .Corrupt
		}
		clear(&w.cands)
		lost := false
		for k in 0 ..< dg {
			nb := prim.get_u32le(rec[ids_at + 4 * k:])
			if u64(nb) >= bs.f.vec_n {
				return .Corrupt
			}
			no, dead := _vm_out(m, gb.base, nb)
			if !dead {
				append(&w.cands, no)
				continue
			}
			lost = true
			_cons_hop(m, w, nb, u32(o)) or_return
		}
		if lost {
			_cons_prune(w, m, u32(o), v) or_return
			clear(&w.cands)
			append(&w.cands, ..w.keep[:])
		}
		_rec_put(gb, rec, w.cands[:])
		sw_write(&m.sw, rec)
	}
	m.work += (end - gb.cursor) * gb.rec
	gb.cursor = end
	if gb.cursor < gb.n {
		return m.sw.out.err
	}
	m.sw.f.vcodes_off = sw_off(&m.sw)
	m.sw.f.vec_m = u64(gb.m)
	m.sw.f.cb_gen = gb.cb.gen
	m.sw.f.medoid = u64(gb.medoid)
	out_flush(&m.sw.out)
	gb.cursor = 0
	gb.ins = 0
	gb.phase = .Insert if gb.nnew > 0 else .Indeg
	return m.sw.out.err
}

@(private)
_cons_hop :: proc(m: ^Merge, w: ^Worker, dead: u32, self: u32) -> Error {
	gb := m.gb
	bs := &m.segs[gb.base]
	at := bs.f.vdata_off + i64(dead) * bs.f.vrec
	hb: [4]u8
	got, e := prim.read_at(bs.vfs, bs.fd, hb[:], at)
	if e != .None {
		return _perr(e)
	}
	if got != 4 {
		return .Corrupt
	}
	dg := int(prim.get_u32le(hb[:]))
	if dg > DEGREE {
		return .Corrupt
	}
	ib: [DEGREE * 4]u8
	got2, e2 := prim.read_at(bs.vfs, bs.fd, ib[:dg * 4], at + 4 + i64(gb.dim) * 4)
	if e2 != .None {
		return _perr(e2)
	}
	if got2 != dg * 4 {
		return .Corrupt
	}
	for k in 0 ..< dg {
		if len(w.cands) >= CONS_CAP {
			break
		}
		nb := prim.get_u32le(ib[4 * k:])
		if u64(nb) >= bs.f.vec_n {
			return .Corrupt
		}
		no, nd := _vm_out(m, gb.base, nb)
		if !nd && no != self {
			append(&w.cands, no)
		}
	}
	return .None
}

@(private)
_cons_prune :: proc(w: ^Worker, m: ^Merge, p: u32, pv: []f32) -> Error {
	gb := w.gb
	d := gb.dim
	n := len(w.cands)
	if len(w.rv) < n * d {
		resize(&w.rv, n * d)
	}
	resize(&w.dists, n)
	for c, i in w.cands {
		x := w.rv[i * d:][:d]
		_gb_read_vec(m, int(c), x) or_return
		w.dists[i] = dot(pv, x)
	}
	_prune_vecs(w, p, w.cands[:], w.dists[:], w.rv[:], INS_ALPHA, INS_DEG)
	return .None
}

@(private)
_ins_seed :: #force_inline proc(w: ^Worker, x: u32) {
	gb := w.gb
	if int(x) >= gb.n || !visited_add(&w.vis, x) {
		return
	}
	pool_insert(&w.pool, L_INS, Pnode{sim = adc(w.lut, gb.codes[int(x) * gb.m:][:gb.m], gb.cb.ksub), pos = x})
}

@(private)
_ins_one :: proc(w: ^Worker, m: ^Merge, u: u32) -> Error {
	gb := w.gb
	d := gb.dim
	ids_at := 4 + d * 4
	codes_at := ids_at + DEGREE * 4
	_gb_rec_read(m, u, w.rec) or_return
	qv := slice.reinterpret([]f32, w.rec[4:][:d * 4])
	cb_lut(gb.cb, qv, w.lut)
	visited_clear(&w.vis)
	clear(&w.pool)
	clear(&w.cands)
	clear(&w.dists)
	clear(&w.evec)
	visited_add(&w.vis, u)
	_ins_seed(w, gb.medoid)
	own := min(int(prim.get_u32le(w.rec)), DEGREE)
	for k in 0 ..< own {
		_ins_seed(w, prim.get_u32le(w.rec[ids_at + 4 * k:]))
	}
	for {
		idx := -1
		for x, i in w.pool {
			if !x.done {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		w.pool[idx].done = true
		x := w.pool[idx].pos
		_gb_rec_read(m, x, w.rec2) or_return
		xv := slice.reinterpret([]f32, w.rec2[4:][:d * 4])
		append(&w.cands, x)
		append(&w.dists, dot(qv, xv))
		append(&w.evec, ..xv)
		dg := int(prim.get_u32le(w.rec2))
		if dg > DEGREE {
			continue
		}
		for k in 0 ..< dg {
			nb := prim.get_u32le(w.rec2[ids_at + 4 * k:])
			if int(nb) >= gb.n || !visited_add(&w.vis, nb) {
				continue
			}
			pool_insert(&w.pool, L_INS, Pnode{sim = adc(w.lut, w.rec2[codes_at + k * gb.m:][:gb.m], gb.cb.ksub), pos = nb})
		}
	}
	_ins_extra(w, m, u, qv) or_return
	_prune_vecs(w, u, w.cands[:], w.dists[:], w.evec[:], INS_ALPHA, INS_DEG)
	_rec_put(gb, w.rec, w.keep[:])
	_rec_write(m, u, w.rec) or_return
	for j in w.keep {
		append(&w.delta, u64(j) << 32 | u64(u))
	}
	return .None
}

@(private)
_ins_extra :: proc(w: ^Worker, m: ^Merge, u: u32, qv: []f32) -> Error {
	gb := w.gb
	d := gb.dim
	si, p, ok := _gb_src(m, int(u))
	if !ok {
		return .Corrupt
	}
	s := &m.segs[si]
	if s.f.vec_m == 0 {
		return .None
	}
	at := s.f.vdata_off + i64(p) * s.f.vrec
	hb: [4]u8
	got, e := prim.read_at(s.vfs, s.fd, hb[:], at)
	if e != .None {
		return _perr(e)
	}
	dg := int(prim.get_u32le(hb[:]))
	if got != 4 || dg > DEGREE {
		return .Corrupt
	}
	ib: [DEGREE * 4]u8
	got2, e2 := prim.read_at(s.vfs, s.fd, ib[:dg * 4], at + 4 + i64(d) * 4)
	if e2 != .None {
		return _perr(e2)
	}
	if got2 != dg * 4 {
		return .Corrupt
	}
	clear(&w.pool)
	for k in 0 ..< dg {
		nb := prim.get_u32le(ib[4 * k:])
		if u64(nb) >= s.f.vec_n {
			return .Corrupt
		}
		no, dead := _vm_out(m, si, nb)
		if dead || int(no) >= gb.n || !visited_add(&w.vis, no) {
			continue
		}
		pool_insert(&w.pool, INS_EXTRA, Pnode{sim = adc(w.lut, gb.codes[int(no) * gb.m:][:gb.m], gb.cb.ksub), pos = no})
	}
	for x in w.pool {
		xv := w.vec
		_gb_read_vec(m, int(x.pos), xv) or_return
		append(&w.cands, x.pos)
		append(&w.dists, dot(qv, xv))
		append(&w.evec, ..xv)
	}
	return .None
}

@(private)
_patch_one :: proc(w: ^Worker, m: ^Merge, j: u32, us: []u64) -> Error {
	gb := w.gb
	d := gb.dim
	ids_at := 4 + d * 4
	_gb_rec_read(m, j, w.rec) or_return
	dg := int(prim.get_u32le(w.rec))
	if dg > DEGREE {
		return .Corrupt
	}
	clear(&w.cands)
	for k in 0 ..< dg {
		append(&w.cands, prim.get_u32le(w.rec[ids_at + 4 * k:]))
	}
	outer: for x in us {
		u := u32(x)
		if u == j {
			continue
		}
		for c in w.cands {
			if c == u {
				continue outer
			}
		}
		append(&w.cands, u)
	}
	if len(w.cands) == dg {
		return .None
	}
	if len(w.cands) > DEGREE {
		jv := slice.reinterpret([]f32, w.rec[4:][:d * 4])
		_cons_prune(w, m, j, jv) or_return
		clear(&w.cands)
		append(&w.cands, ..w.keep[:])
	}
	_rec_put(gb, w.rec, w.cands[:])
	return _rec_write(m, j, w.rec)
}

@(private)
_ins_job :: proc(w: ^Worker) {
	gb := w.gb
	m := gb.merge
	for i in w.from ..< w.to {
		u := _gb_new_out(gb, _gb_perm(gb, gb.ins + i))
		if e := _ins_one(w, m, u); e != .None {
			w.err = e
			return
		}
	}
}

@(private)
_patch_job :: proc(w: ^Worker) {
	gb := w.gb
	m := gb.merge
	dl := gb.dl[:]
	a, b := w.from, w.to
	for a > 0 && a < len(dl) && dl[a] >> 32 == dl[a - 1] >> 32 {
		a += 1
	}
	for b > 0 && b < len(dl) && dl[b] >> 32 == dl[b - 1] >> 32 {
		b += 1
	}
	for a < b {
		j := dl[a] >> 32
		e := a + 1
		for e < len(dl) && dl[e] >> 32 == j {
			e += 1
		}
		if err := _patch_one(w, m, u32(j), dl[a:e]); err != .None {
			w.err = err
			return
		}
		a = e
	}
}

@(private)
_gb_workers_err :: proc(gb: ^Graph_Build) -> Error {
	for &w in gb.workers {
		if w.err != .None {
			e := w.err
			w.err = .None
			return e
		}
	}
	return .None
}

@(private)
_gb_insert_step :: proc(m: ^Merge) -> Error {
	gb := m.gb
	if gb.ins >= gb.nnew {
		gb.cursor = 0
		gb.phase = .Indeg
		return .None
	}
	c := min(INS_BATCH, gb.nnew - gb.ins)
	for &w in gb.workers {
		clear(&w.delta)
	}
	_run_workers(gb, .Insert, c)
	_gb_workers_err(gb) or_return
	clear(&gb.dl)
	for &w in gb.workers {
		append(&gb.dl, ..w.delta[:])
	}
	slice.sort(gb.dl[:])
	gb.ins += c
	gb.phase = .Patch
	m.work += c * INSERT_WORK
	return .None
}

@(private)
_gb_patch_step :: proc(m: ^Merge) -> Error {
	gb := m.gb
	_run_workers(gb, .Patch, len(gb.dl))
	_gb_workers_err(gb) or_return
	m.work += len(gb.dl) * 256
	clear(&gb.dl)
	gb.phase = .Insert
	return .None
}

@(private)
_gb_indeg :: proc(m: ^Merge) -> Error {
	gb := m.gb
	if gb.indeg == nil {
		gb.indeg = make([]u8, gb.n, gb.alloc)
	}
	per := 64
	if len(gb.out) < per * gb.rec {
		gb.out = make([]u8, per * gb.rec, gb.alloc)
	}
	c := min(per, gb.n - gb.cursor)
	if c > 0 {
		buf := gb.out[:c * gb.rec]
		got, e := prim.read_at(m.sw.out.vfs, m.sw.out.fd, buf, m.sw.f.vdata_off + i64(gb.cursor) * i64(gb.rec))
		if e != .None {
			return _perr(e)
		}
		if got != len(buf) {
			return .Corrupt
		}
		ids_at := 4 + gb.dim * 4
		for r in 0 ..< c {
			rec := buf[r * gb.rec:][:gb.rec]
			dg := int(prim.get_u32le(rec))
			if dg > DEGREE {
				return .Corrupt
			}
			for k in 0 ..< dg {
				x := prim.get_u32le(rec[ids_at + 4 * k:])
				if int(x) >= gb.n {
					return .Corrupt
				}
				if gb.indeg[x] < 255 {
					gb.indeg[x] += 1
				}
			}
		}
		gb.cursor += c
		m.work += c * gb.rec
	}
	if gb.cursor >= gb.n {
		gb.cursor = 0
		_gb_repair_init(m)
	}
	return .None
}

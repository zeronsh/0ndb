package search

import "base:intrinsics"
import "base:runtime"
import "core:hash/xxhash"
import "core:math"
import "core:slice"
import "../prim"

MAX_DIM :: 4096
KSUB :: 256
TRAIN_MIN :: 4096
TRAIN_SAMPLE :: 16384
TRAIN_GROWTH :: 8
TRAIN_ITERS :: 10
MAX_LISTS :: 4096
DEFAULT_NPROBE :: 32
RERANK_MIN :: 400
RERANK_FACTOR :: 20
CB_MAGIC :: u64(0x6276_6863_7273_6e30)
CB_VERSION :: u64(1)
CB_HEADER :: 7 * 8
IVF_DIR :: 12

V8 :: #simd[8]f32

dot :: proc "contextless" (a, b: []f32) -> f32 #no_bounds_check {
	n := min(len(a), len(b))
	acc0, acc1: V8
	i := 0
	for ; i + 16 <= n; i += 16 {
		acc0 += intrinsics.unaligned_load((^V8)(&a[i])) * intrinsics.unaligned_load((^V8)(&b[i]))
		acc1 += intrinsics.unaligned_load((^V8)(&a[i + 8])) * intrinsics.unaligned_load((^V8)(&b[i + 8]))
	}
	for ; i + 8 <= n; i += 8 {
		acc0 += intrinsics.unaligned_load((^V8)(&a[i])) * intrinsics.unaligned_load((^V8)(&b[i]))
	}
	s := intrinsics.simd_reduce_add_pairs(acc0 + acc1)
	for ; i < n; i += 1 {
		s += a[i] * b[i]
	}
	return s
}

l2 :: proc "contextless" (a, b: []f32) -> f32 #no_bounds_check {
	n := min(len(a), len(b))
	acc: V8
	i := 0
	for ; i + 8 <= n; i += 8 {
		d := intrinsics.unaligned_load((^V8)(&a[i])) - intrinsics.unaligned_load((^V8)(&b[i]))
		acc += d * d
	}
	s := intrinsics.simd_reduce_add_pairs(acc)
	for ; i < n; i += 1 {
		d := a[i] - b[i]
		s += d * d
	}
	return s
}

normalize :: proc "contextless" (v: []f32) -> bool {
	n := math.sqrt(dot(v, v))
	if !(n > 0) || math.is_inf(n) {
		return false
	}
	inv := 1 / n
	for &x in v {
		x *= inv
	}
	return true
}

Cb :: struct {
	gen:   u64,
	dim:   int,
	k:     int,
	m:     int,
	dsub:  int,
	ksub:  int,
	n:     u64,
	cent:  []f32,
	cnorm: []f32,
	pq:    []f32,
}

cb_path :: proc(ix: ^Index, gen: u64, buf: ^Name_Buf) -> string {
	name: [19]u8
	copy(name[:], "vq-")
	hex := HEX
	for i in 0 ..< 16 {
		name[3 + i] = hex[(gen >> u64(60 - 4 * i)) & 0xf]
	}
	return file_path(ix, string(name[:]), buf)
}

cb_load :: proc(ix: ^Index, gen: u64, allocator: runtime.Allocator) -> (cb: ^Cb, err: Error) {
	buf: Name_Buf
	data, rerr := prim.read_file(ix.vfs, cb_path(ix, gen, &buf), allocator)
	if rerr != .None {
		return nil, .Corrupt if rerr == .Not_Found else _perr(rerr)
	}
	if len(data) < CB_HEADER + 8 || xxhash.XXH3_64_default(data[:len(data) - 8]) != prim.get_u64le(data[len(data) - 8:]) {
		return nil, .Corrupt
	}
	h: [7]u64
	for i in 0 ..< 7 {
		h[i] = prim.get_u64le(data[8 * i:])
	}
	if h[0] != CB_MAGIC || h[1] != CB_VERSION || h[2] == 0 || h[2] > MAX_DIM || h[3] == 0 || h[3] > MAX_LISTS || h[4] == 0 || h[2] % h[4] != 0 || h[5] == 0 || h[5] > KSUB {
		return nil, .Corrupt
	}
	cb = new(Cb, allocator)
	cb.gen = gen
	cb.dim = int(h[2])
	cb.k = int(h[3])
	cb.m = int(h[4])
	cb.dsub = cb.dim / cb.m
	cb.ksub = int(h[5])
	cb.n = h[6]
	nc := cb.k * cb.dim
	np := cb.m * cb.ksub * cb.dsub
	if len(data) != CB_HEADER + (nc + np) * 4 + 8 {
		return nil, .Corrupt
	}
	cb.cent = make([]f32, nc, allocator)
	cb.pq = make([]f32, np, allocator)
	cb.cnorm = make([]f32, cb.k, allocator)
	copy(slice.to_bytes(cb.cent), data[CB_HEADER:][:nc * 4])
	copy(slice.to_bytes(cb.pq), data[CB_HEADER + nc * 4:][:np * 4])
	for k in 0 ..< cb.k {
		c := cb.cent[k * cb.dim:][:cb.dim]
		cb.cnorm[k] = dot(c, c)
	}
	return cb, .None
}

cb_assign :: proc "contextless" (cb: ^Cb, v: []f32) -> int {
	best, bs := 0, max(f32)
	for k in 0 ..< cb.k {
		d := cb.cnorm[k] - 2 * dot(v, cb.cent[k * cb.dim:][:cb.dim])
		if d < bs {
			best, bs = k, d
		}
	}
	return best
}

cb_encode :: proc "contextless" (cb: ^Cb, v: []f32, k: int, code: []u8) #no_bounds_check {
	r: [MAX_DIM]f32
	c := cb.cent[k * cb.dim:]
	for i in 0 ..< cb.dim {
		r[i] = v[i] - c[i]
	}
	for j in 0 ..< cb.m {
		sub := r[j * cb.dsub:][:cb.dsub]
		book := cb.pq[j * cb.ksub * cb.dsub:]
		best, bs := 0, max(f32)
		for t in 0 ..< cb.ksub {
			d := l2(sub, book[t * cb.dsub:][:cb.dsub])
			if d < bs {
				best, bs = t, d
			}
		}
		code[j] = u8(best)
	}
}

@(private)
_kmeans :: proc(data: []f32, n, d, k: int, iters: int, allocator: runtime.Allocator) -> []f32 {
	cent := make([]f32, k * d, allocator)
	for c in 0 ..< k {
		src := (c * n) / k
		copy(cent[c * d:][:d], data[src * d:][:d])
	}
	sums := make([]f64, k * d, context.temp_allocator)
	counts := make([]int, k, context.temp_allocator)
	norms := make([]f32, k, context.temp_allocator)
	for it in 0 ..< iters {
		for c in 0 ..< k {
			cc := cent[c * d:][:d]
			norms[c] = dot(cc, cc)
		}
		slice.fill(sums, 0)
		slice.fill(counts, 0)
		for i in 0 ..< n {
			x := data[i * d:][:d]
			best, bs := 0, max(f32)
			for c in 0 ..< k {
				dd := norms[c] - 2 * dot(x, cent[c * d:][:d])
				if dd < bs {
					best, bs = c, dd
				}
			}
			counts[best] += 1
			s := sums[best * d:][:d]
			for j in 0 ..< d {
				s[j] += f64(x[j])
			}
		}
		for c in 0 ..< k {
			if counts[c] == 0 {
				src := ((c * 7919 + it * 104729) % n)
				copy(cent[c * d:][:d], data[src * d:][:d])
				continue
			}
			inv := 1 / f64(counts[c])
			for j in 0 ..< d {
				cent[c * d + j] = f32(sums[c * d + j] * inv)
			}
		}
	}
	return cent
}

vec_total :: proc "contextless" (ix: ^Index) -> u64 {
	t := u64(0)
	for s in ix.segs {
		t += s.f.vec_n
	}
	return t
}

vec_maybe_train :: proc(ix: ^Index) -> (trained: bool, err: Error) {
	dim := ix.opts.embedder.dim
	if dim <= 0 {
		return false, .None
	}
	total := vec_total(ix)
	if total < TRAIN_MIN || (ix.man.cb_gen != 0 && total < TRAIN_GROWTH * ix.man.cb_n) {
		return false, .None
	}
	arena: runtime.Arena
	if runtime.arena_init(&arena, 1 << 20, ix.allocator) != nil {
		return false, .No_Memory
	}
	defer runtime.arena_destroy(&arena)
	a := runtime.arena_allocator(&arena)
	sn := int(min(total, TRAIN_SAMPLE))
	sample := make([]f32, sn * dim, a)
	for i in 0 ..< sn {
		g := u64(i) * total / u64(sn)
		for &s in ix.segs {
			if g < s.f.vec_n {
				dst := slice.to_bytes(sample[i * dim:][:dim])
				got, rerr := prim.read_at(s.vfs, s.fd, dst, s.f.vdata_off + i64(g) * i64(dim) * 4)
				if rerr != .None {
					return false, _perr(rerr)
				}
				if got != len(dst) {
					return false, .Corrupt
				}
				break
			}
			g -= s.f.vec_n
		}
	}
	k := 16
	for k * k < int(total) && k < MAX_LISTS {
		k *= 2
	}
	k = min(k, max(16, sn / 16))
	context.temp_allocator = a
	cent := _kmeans(sample, sn, dim, k, TRAIN_ITERS, a)
	cb := Cb {
		dim  = dim,
		k    = k,
		cent = cent,
	}
	cb.cnorm = make([]f32, k, a)
	for c in 0 ..< k {
		cc := cent[c * dim:][:dim]
		cb.cnorm[c] = dot(cc, cc)
	}
	cb.dsub = 8 if dim % 8 == 0 else (4 if dim % 4 == 0 else (2 if dim % 2 == 0 else 1))
	cb.m = dim / cb.dsub
	cb.ksub = min(KSUB, sn)
	resid := make([]f32, sn * dim, a)
	for i in 0 ..< sn {
		x := sample[i * dim:][:dim]
		c := cb_assign(&cb, x)
		for j in 0 ..< dim {
			resid[i * dim + j] = x[j] - cent[c * dim + j]
		}
	}
	cb.pq = make([]f32, cb.m * cb.ksub * cb.dsub, a)
	sub := make([]f32, sn * cb.dsub, a)
	for j in 0 ..< cb.m {
		for i in 0 ..< sn {
			copy(sub[i * cb.dsub:][:cb.dsub], resid[i * dim + j * cb.dsub:][:cb.dsub])
		}
		book := _kmeans(sub, sn, cb.dsub, cb.ksub, TRAIN_ITERS, a)
		copy(cb.pq[j * cb.ksub * cb.dsub:][:cb.ksub * cb.dsub], book)
	}
	gen := ix.man.next_gen
	out := make([dynamic]u8, 0, CB_HEADER + (len(cent) + len(cb.pq)) * 4 + 8, a)
	w := prim.writer(&out)
	for v in ([7]u64{CB_MAGIC, CB_VERSION, u64(dim), u64(k), u64(cb.m), u64(cb.ksub), total}) {
		prim.write_u64le(&w, v)
	}
	prim.write_raw(&w, slice.to_bytes(cent))
	prim.write_raw(&w, slice.to_bytes(cb.pq))
	prim.write_u64le(&w, xxhash.XXH3_64_default(out[:]))
	if w.err != .None {
		return false, .No_Memory
	}
	buf: Name_Buf
	if e := prim.replace_atomic(ix.vfs, cb_path(ix, gen, &buf), out[:]); e != .None {
		return false, _perr(e)
	}
	old_gen, old_n, old_next := ix.man.cb_gen, ix.man.cb_n, ix.man.next_gen
	ix.man.cb_gen = gen
	ix.man.cb_n = total
	ix.man.next_gen = gen + 1
	if e := manifest_write(ix); e != .None {
		ix.man.cb_gen, ix.man.cb_n, ix.man.next_gen = old_gen, old_n, old_next
		_ = prim.remove(ix.vfs, cb_path(ix, gen, &buf))
		return false, e
	}
	cb_gc(ix)
	return true, .None
}

cb_gc :: proc(ix: ^Index) {
	d: prim.Dir
	if prim.dir_open(ix.vfs, &d, ix.dir, context.temp_allocator) != .None {
		return
	}
	defer prim.dir_close(ix.vfs, &d)
	for {
		ent, ok, err := prim.dir_next(ix.vfs, &d)
		if err != .None || !ok {
			break
		}
		name := ent.name
		if len(name) != 19 || name[:3] != "vq-" {
			continue
		}
		g, gok := _parse_hex(name[3:])
		if !gok || g == ix.man.cb_gen {
			continue
		}
		used := false
		for s in ix.segs {
			if s.f.cb_gen == g {
				used = true
				break
			}
		}
		if !used {
			buf: Name_Buf
			_ = prim.remove(ix.vfs, file_path(ix, name, &buf))
		}
	}
}

@(private)
_parse_hex :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) != 16 {
		return 0, false
	}
	for c in transmute([]u8)s {
		n: u8
		switch c {
		case '0' ..= '9':
			n = c - '0'
		case 'a' ..= 'f':
			n = c - 'a' + 10
		case:
			return 0, false
		}
		v = v << 4 | u64(n)
	}
	return v, true
}

Ivf_Entry :: struct {
	list: u32,
	pos:  u32,
	at:   u32,
}

ivf_write :: proc(sw: ^Seg_Writer, cb: ^Cb, entries: []Ivf_Entry, codes: []u8, list_src: proc(data: rawptr, k: int, sw: ^Seg_Writer) -> (count: u32, err: Error) = nil, data: rawptr = nil) -> Error {
	slice.sort_by(entries, proc(x, y: Ivf_Entry) -> bool {
		return x.list < y.list || (x.list == y.list && x.pos < y.pos)
	})
	sw.f.ivf_off = sw_off(sw)
	dir := make([]u8, cb.k * IVF_DIR, context.temp_allocator)
	e := 0
	ent := make([]u8, 4 + cb.m, context.temp_allocator)
	for k in 0 ..< cb.k {
		start := sw_off(sw) - sw.f.ivf_off
		count := u32(0)
		if list_src != nil {
			c := list_src(data, k, sw) or_return
			count += c
		}
		for e < len(entries) && int(entries[e].list) == k {
			prim.put_u32le(ent, entries[e].pos)
			copy(ent[4:], codes[int(entries[e].at) * cb.m:][:cb.m])
			sw_write(sw, ent)
			count += 1
			e += 1
		}
		prim.put_u64le(dir[k * IVF_DIR:], u64(start))
		prim.put_u32le(dir[k * IVF_DIR + 8:], count)
	}
	sw_write(sw, dir)
	sw.f.ivf_len = sw_off(sw) - sw.f.ivf_off
	sw.f.cb_gen = cb.gen
	return sw.out.err
}

vec_flush :: proc(ix: ^Index, sw: ^Seg_Writer) -> Error {
	m := &ix.mem
	dim := ix.opts.embedder.dim
	sw.f.vids_off = sw_off(sw)
	sw.f.vdata_off = sw_off(sw)
	sw.f.ivf_off = sw_off(sw)
	if len(m.vids) == 0 || dim <= 0 {
		return .None
	}
	sw.f.vec_dim = u64(dim)
	live := make([dynamic]int, context.temp_allocator)
	for id, i in m.vids {
		if m.docs[u64(id) - m.base].flags & DF_DELETED == 0 {
			append(&live, i)
		}
	}
	sw.f.vec_n = u64(len(live))
	b: [4]u8
	for i in live {
		prim.put_u32le(b[:], m.vids[i])
		sw_meta(sw, b[:])
	}
	sw.f.vdata_off = sw_off(sw)
	for i in live {
		sw_write(sw, slice.to_bytes(m.vecs[i * dim:][:dim]))
	}
	sw.f.ivf_off = sw_off(sw)
	if ix.man.cb_gen == 0 || len(live) == 0 {
		return sw.out.err
	}
	cb := cb_load(ix, ix.man.cb_gen, context.temp_allocator) or_return
	if cb.dim != dim {
		return .Corrupt
	}
	entries := make([]Ivf_Entry, len(live), context.temp_allocator)
	codes := make([]u8, len(live) * cb.m, context.temp_allocator)
	for i, p in live {
		v := m.vecs[i * dim:][:dim]
		k := cb_assign(cb, v)
		cb_encode(cb, v, k, codes[p * cb.m:][:cb.m])
		entries[p] = {u32(k), u32(p), u32(p)}
	}
	return ivf_write(sw, cb, entries, codes)
}

Vhit :: struct {
	score: f32,
	id:    u32,
	seg:   int,
	pos:   u32,
}

@(private)
_vh_less :: proc "contextless" (a, b: Vhit) -> bool {
	if a.score != b.score {
		return a.score < b.score
	}
	return a.id < b.id
}

@(private)
_vheap_push :: proc(h: ^[dynamic]Vhit, cap_n: int, x: Vhit) {
	if math.is_nan(x.score) {
		return
	}
	if len(h) == cap_n {
		if !_vh_less(h[0], x) {
			return
		}
		h[0] = x
		i := 0
		for {
			l := 2 * i + 1
			if l >= len(h) {
				break
			}
			m := l
			if l + 1 < len(h) && _vh_less(h[l + 1], h[l]) {
				m = l + 1
			}
			if !_vh_less(h[m], h[i]) {
				break
			}
			h[i], h[m] = h[m], h[i]
			i = m
		}
		return
	}
	append(h, x)
	i := len(h) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !_vh_less(h[i], h[p]) {
			break
		}
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

Vec_Query :: struct {
	cbs:     map[u64]^Cb,
	cscore:  map[u64][]f32,
	lut:     map[u64][]f32,
	buf:     []u8,
	vbuf:    []f32,
}

@(private)
_vq_cb :: proc(e: ^Exec, vq: ^Vec_Query, gen: u64, q: []f32) -> (cb: ^Cb, cs: []f32, lut: []f32, err: Error) {
	if c, ok := vq.cbs[gen]; ok {
		return c, vq.cscore[gen], vq.lut[gen], .None
	}
	cb = cb_load(e.ix, gen, e.alloc) or_return
	if cb.dim != len(q) {
		return nil, nil, nil, .Corrupt
	}
	cs = make([]f32, cb.k, e.alloc)
	for k in 0 ..< cb.k {
		cs[k] = dot(q, cb.cent[k * cb.dim:][:cb.dim])
	}
	lut = make([]f32, cb.m * cb.ksub, e.alloc)
	for j in 0 ..< cb.m {
		qs := q[j * cb.dsub:][:cb.dsub]
		for t in 0 ..< cb.ksub {
			lut[j * cb.ksub + t] = dot(qs, cb.pq[(j * cb.ksub + t) * cb.dsub:][:cb.dsub])
		}
	}
	vq.cbs[gen] = cb
	vq.cscore[gen] = cs
	vq.lut[gen] = lut
	return cb, cs, lut, .None
}

vec_candidates :: proc(e: ^Exec, q: []f32, want: int, nprobe: int, rerank: int) -> (out: [dynamic]Vhit, err: Error) {
	a := e.alloc
	vq := Vec_Query{}
	vq.cbs = make(map[u64]^Cb, a)
	vq.cscore = make(map[u64][]f32, a)
	vq.lut = make(map[u64][]f32, a)
	dim := len(q)
	r := max(rerank, RERANK_MIN, RERANK_FACTOR * want)
	approx := make([dynamic]Vhit, 0, r, a)
	exact := make([dynamic]Vhit, 0, r, a)
	chunk := make([]f32, (1 << 20) / 4, a)
	for si in 0 ..< len(e.ix.segs) {
		s := &e.ix.segs[si]
		n := int(s.f.vec_n)
		if n == 0 {
			continue
		}
		if int(s.f.vec_dim) != dim {
			return out, .Corrupt
		}
		if s.f.ivf_len == 0 {
			per := len(chunk) / dim
			for p := 0; p < n; p += per {
				c := min(per, n - p)
				bytes := slice.to_bytes(chunk[:c * dim])
				got, rerr := prim.read_at(s.vfs, s.fd, bytes, s.f.vdata_off + i64(p) * i64(dim) * 4)
				if rerr != .None {
					return out, _perr(rerr)
				}
				if got != len(bytes) {
					return out, .Corrupt
				}
				for k in 0 ..< c {
					sc := dot(q, chunk[k * dim:][:dim])
					_vheap_push(&exact, r, Vhit{score = sc, seg = si, pos = u32(p + k)})
				}
			}
			continue
		}
		cb, cs, lut := _vq_cb(e, &vq, s.f.cb_gen, q) or_return
		order := make([]int, cb.k, context.temp_allocator)
		for k in 0 ..< cb.k {
			order[k] = k
		}
		Ctx :: struct {
			cs: []f32,
		}
		ctx := Ctx{cs}
		slice.sort_by_with_data(order, proc(x, y: int, d: rawptr) -> bool {
				c := (^Ctx)(d)
				return c.cs[x] > c.cs[y]
			}, &ctx)
		dir := make([]u8, cb.k * IVF_DIR, context.temp_allocator)
		dir_at := s.f.ivf_off + s.f.ivf_len - i64(len(dir))
		got, rerr := prim.read_at(s.vfs, s.fd, dir, dir_at)
		if rerr != .None {
			return out, _perr(rerr)
		}
		if got != len(dir) || dir_at < s.f.ivf_off {
			return out, .Corrupt
		}
		stride := 4 + cb.m
		for pi in 0 ..< min(nprobe, cb.k) {
			k := order[pi]
			off := i64(prim.get_u64le(dir[k * IVF_DIR:]))
			cnt := int(prim.get_u32le(dir[k * IVF_DIR + 8:]))
			if cnt == 0 {
				continue
			}
			nb := cnt * stride
			if off < 0 || off + i64(nb) > i64(dir_at - s.f.ivf_off) {
				return out, .Corrupt
			}
			if len(vq.buf) < nb {
				vq.buf = make([]u8, nb, a)
			}
			lst := vq.buf[:nb]
			g2, e2 := prim.read_at(s.vfs, s.fd, lst, s.f.ivf_off + off)
			if e2 != .None {
				return out, _perr(e2)
			}
			if g2 != nb {
				return out, .Corrupt
			}
			base := cs[k]
			for x in 0 ..< cnt {
				ent := lst[x * stride:]
				pos := prim.get_u32le(ent)
				sc := base
				codes := ent[4:][:cb.m]
				#no_bounds_check for j in 0 ..< cb.m {
					sc += lut[j * cb.ksub + int(codes[j])]
				}
				if u64(pos) >= s.f.vec_n {
					return out, .Corrupt
				}
				_vheap_push(&approx, r, Vhit{score = sc, seg = si, pos = pos})
			}
		}
	}
	v := make([]f32, dim, a)
	for h in approx {
		s := &e.ix.segs[h.seg]
		bytes := slice.to_bytes(v)
		got, rerr := prim.read_at(s.vfs, s.fd, bytes, s.f.vdata_off + i64(h.pos) * i64(dim) * 4)
		if rerr != .None {
			return out, _perr(rerr)
		}
		if got != len(bytes) {
			return out, .Corrupt
		}
		x := h
		x.score = dot(q, v)
		_vheap_push(&exact, r, x)
	}
	for &h in exact {
		s := &e.ix.segs[h.seg]
		b: [4]u8
		cache_read(&e.ix.cache, s, s.f.vids_off + i64(h.pos) * 4, b[:]) or_return
		h.id = prim.get_u32le(b[:])
		if u64(h.id) < s.f.lo || u64(h.id) >= s.f.hi {
			return out, .Corrupt
		}
	}
	slice.sort_by(exact[:], proc(x, y: Vhit) -> bool {
		return _vh_less(y, x)
	})
	return exact, .None
}

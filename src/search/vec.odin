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
DEGREE :: 48
DEG_CAP :: 64
L_BUILD :: 100
ALPHA :: f32(1.2)
DEFAULT_BEAM :: 128
GRAPH_MIN :: 2048
REC_ALIGN :: 4096
INSERT_WORK :: 16 * 1024
CB_MAGIC :: u64(0x6276_6863_7273_6e30)
CB_VERSION :: u64(2)
CB_HEADER :: 6 * 8

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
	gen:  u64,
	dim:  int,
	m:    int,
	dsub: int,
	ksub: int,
	n:    u64,
	pq:   []f32,
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
	h: [6]u64
	for i in 0 ..< 6 {
		h[i] = prim.get_u64le(data[8 * i:])
	}
	if h[0] != CB_MAGIC || h[1] != CB_VERSION || h[2] == 0 || h[2] > MAX_DIM || h[3] == 0 || h[2] % h[3] != 0 || h[4] == 0 || h[4] > KSUB {
		return nil, .Corrupt
	}
	cb = new(Cb, allocator)
	cb.gen = gen
	cb.dim = int(h[2])
	cb.m = int(h[3])
	cb.dsub = cb.dim / cb.m
	cb.ksub = int(h[4])
	cb.n = h[5]
	np := cb.m * cb.ksub * cb.dsub
	if len(data) != CB_HEADER + np * 4 + 8 {
		return nil, .Corrupt
	}
	cb.pq = make([]f32, np, allocator)
	copy(slice.to_bytes(cb.pq), data[CB_HEADER:][:np * 4])
	return cb, .None
}

cb_encode :: proc "contextless" (cb: ^Cb, v: []f32, code: []u8) #no_bounds_check {
	for j in 0 ..< cb.m {
		sub := v[j * cb.dsub:][:cb.dsub]
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

cb_lut :: proc "contextless" (cb: ^Cb, q: []f32, lut: []f32) #no_bounds_check {
	for j in 0 ..< cb.m {
		qs := q[j * cb.dsub:][:cb.dsub]
		for t in 0 ..< cb.ksub {
			lut[j * cb.ksub + t] = dot(qs, cb.pq[(j * cb.ksub + t) * cb.dsub:][:cb.dsub])
		}
	}
}

adc :: #force_inline proc "contextless" (lut: []f32, code: []u8, ksub: int) -> f32 #no_bounds_check {
	s: f32
	for j in 0 ..< len(code) {
		s += lut[j * ksub + int(code[j])]
	}
	return s
}

dot_i8 :: proc "contextless" (a, b: []i8) -> i32 #no_bounds_check {
	acc: #simd[16]i32
	i := 0
	n := min(len(a), len(b))
	for ; i + 16 <= n; i += 16 {
		x := cast(#simd[16]i16)intrinsics.unaligned_load((^#simd[16]i8)(&a[i]))
		y := cast(#simd[16]i16)intrinsics.unaligned_load((^#simd[16]i8)(&b[i]))
		acc += cast(#simd[16]i32)(x * y)
	}
	s := intrinsics.simd_reduce_add_pairs(acc)
	for ; i < n; i += 1 {
		s += i32(a[i]) * i32(b[i])
	}
	return s
}

quantize :: proc "contextless" (v: []f32, out: []i8) -> f32 {
	mx := f32(0)
	for x in v {
		mx = max(mx, abs(x))
	}
	if !(mx > 0) {
		for &o in out {
			o = 0
		}
		return 0
	}
	inv := 127 / mx
	for x, i in v {
		out[i] = i8(clamp(math.round(x * inv), -127, 127))
	}
	return mx / 127
}

rec_size :: proc "contextless" (dim, m: int) -> int {
	n := 4 + dim * 4 + DEGREE * (4 + m)
	return (n + REC_ALIGN - 1) / REC_ALIGN * REC_ALIGN
}

rec_vec_off :: proc "contextless" (s: ^Seg, pos: u64) -> i64 {
	return s.f.vdata_off + i64(pos) * s.f.vrec + (4 if s.f.vec_m > 0 else 0)
}

vec_total :: proc "contextless" (ix: ^Index) -> u64 {
	t := u64(0)
	for s in ix.segs {
		t += s.f.vec_n
	}
	return t
}

Vtrain_Phase :: enum u8 {
	Sample,
	Kmeans,
	Write,
}

Vtrain :: struct {
	phase:  Vtrain_Phase,
	arena:  runtime.Arena,
	alloc:  runtime.Allocator,
	dim:    int,
	m:      int,
	dsub:   int,
	ksub:   int,
	sn:     int,
	total:  u64,
	sample: []f32,
	sub:    []f32,
	pq:     []f32,
	cent:   []f32,
	sums:   []f64,
	counts: []int,
	j:      int,
	it:     int,
	si:     int,
}

TRAIN_CHUNK :: 2048

vec_maybe_train :: proc(ix: ^Index) -> (started: bool, err: Error) {
	dim := ix.opts.embedder.dim
	if dim <= 0 || ix.vtrain != nil {
		return false, .None
	}
	total := vec_total(ix)
	if total < TRAIN_MIN || (ix.man.cb_gen != 0 && total < TRAIN_GROWTH * ix.man.cb_n) {
		return false, .None
	}
	t, aerr := new(Vtrain, ix.allocator)
	if aerr != nil {
		return false, .No_Memory
	}
	if runtime.arena_init(&t.arena, 1 << 20, ix.allocator) != nil {
		free(t, ix.allocator)
		return false, .No_Memory
	}
	a := runtime.arena_allocator(&t.arena)
	t.alloc = a
	t.dim = dim
	t.total = total
	t.sn = int(min(total, TRAIN_SAMPLE))
	t.dsub = 8 if dim % 8 == 0 else (4 if dim % 4 == 0 else (2 if dim % 2 == 0 else 1))
	t.m = dim / t.dsub
	t.ksub = min(KSUB, t.sn)
	t.sample = make([]f32, t.sn * dim, a)
	t.sub = make([]f32, t.sn * t.dsub, a)
	t.pq = make([]f32, t.m * t.ksub * t.dsub, a)
	t.cent = make([]f32, t.ksub * t.dsub, a)
	t.sums = make([]f64, t.ksub * t.dsub, a)
	t.counts = make([]int, t.ksub, a)
	if t.sample == nil || t.pq == nil {
		runtime.arena_destroy(&t.arena)
		free(t, ix.allocator)
		return false, .No_Memory
	}
	ix.vtrain = t
	return true, .None
}

vtrain_abort :: proc(ix: ^Index) {
	if ix.vtrain == nil {
		return
	}
	runtime.arena_destroy(&ix.vtrain.arena)
	free(ix.vtrain, ix.allocator)
	ix.vtrain = nil
}

vtrain_step :: proc(ix: ^Index, budget: i64) -> (more: bool, err: Error) {
	t := ix.vtrain
	if t == nil {
		return false, .None
	}
	work := i64(0)
	for work < budget {
		w, done, e := _vtrain_work(ix, t)
		if e != .None {
			vtrain_abort(ix)
			return false, e
		}
		work += w
		if done {
			vtrain_abort(ix)
			return false, .None
		}
	}
	return true, .None
}

@(private)
_vtrain_work :: proc(ix: ^Index, t: ^Vtrain) -> (work: i64, done: bool, err: Error) {
	dim := t.dim
	switch t.phase {
	case .Sample:
		total := vec_total(ix)
		if total == 0 {
			return 0, true, .None
		}
		end := min(t.si + 1024, t.sn)
		for i in t.si ..< end {
			g := u64(i) * total / u64(t.sn)
			for &s in ix.segs {
				if g < s.f.vec_n {
					dst := slice.to_bytes(t.sample[i * dim:][:dim])
					got, rerr := prim.read_at(s.vfs, s.fd, dst, rec_vec_off(&s, g))
					if rerr != .None {
						return 0, false, _perr(rerr)
					}
					if got != len(dst) {
						return 0, false, .Corrupt
					}
					break
				}
				g -= s.f.vec_n
			}
		}
		work = i64(end - t.si) * i64(dim) * 4
		t.si = end
		if t.si == t.sn {
			t.phase = .Kmeans
			t.si = 0
			t.j = 0
			t.it = -1
		}
		return work, false, .None
	case .Kmeans:
		ds := t.dsub
		k := t.ksub
		if t.it < 0 {
			for i in 0 ..< t.sn {
				copy(t.sub[i * ds:][:ds], t.sample[i * dim + t.j * ds:][:ds])
			}
			for c in 0 ..< k {
				copy(t.cent[c * ds:][:ds], t.sub[((c * t.sn) / k) * ds:][:ds])
			}
			t.it = 0
			t.si = 0
			slice.fill(t.sums, 0)
			slice.fill(t.counts, 0)
			return i64(t.sn * ds), false, .None
		}
		end := min(t.si + TRAIN_CHUNK, t.sn)
		for i in t.si ..< end {
			x := t.sub[i * ds:][:ds]
			best, bs := 0, max(f32)
			for c in 0 ..< k {
				dd := l2(x, t.cent[c * ds:][:ds])
				if dd < bs {
					best, bs = c, dd
				}
			}
			t.counts[best] += 1
			sm := t.sums[best * ds:][:ds]
			for q in 0 ..< ds {
				sm[q] += f64(x[q])
			}
		}
		work = i64(end - t.si) * i64(k * ds)
		t.si = end
		if t.si < t.sn {
			return work, false, .None
		}
		for c in 0 ..< k {
			if t.counts[c] == 0 {
				src := (c * 7919 + t.it * 104729) % t.sn
				copy(t.cent[c * ds:][:ds], t.sub[src * ds:][:ds])
				continue
			}
			inv := 1 / f64(t.counts[c])
			for q in 0 ..< ds {
				t.cent[c * ds + q] = f32(t.sums[c * ds + q] * inv)
			}
		}
		t.it += 1
		t.si = 0
		slice.fill(t.sums, 0)
		slice.fill(t.counts, 0)
		if t.it == TRAIN_ITERS {
			copy(t.pq[t.j * k * ds:][:k * ds], t.cent)
			t.j += 1
			t.it = -1
			if t.j == t.m {
				t.phase = .Write
			}
		}
		return work, false, .None
	case .Write:
		gen := ix.man.next_gen
		out := make([dynamic]u8, 0, CB_HEADER + len(t.pq) * 4 + 8, t.alloc)
		w := prim.writer(&out)
		for v in ([6]u64{CB_MAGIC, CB_VERSION, u64(dim), u64(t.m), u64(t.ksub), t.total}) {
			prim.write_u64le(&w, v)
		}
		prim.write_raw(&w, slice.to_bytes(t.pq))
		prim.write_u64le(&w, xxhash.XXH3_64_default(out[:]))
		if w.err != .None {
			return 0, false, .No_Memory
		}
		buf: Name_Buf
		if e := prim.replace_atomic(ix.vfs, cb_path(ix, gen, &buf), out[:]); e != .None {
			return 0, false, _perr(e)
		}
		old_gen, old_n, old_next := ix.man.cb_gen, ix.man.cb_n, ix.man.next_gen
		ix.man.cb_gen = gen
		ix.man.cb_n = t.total
		ix.man.next_gen = gen + 1
		if e := manifest_write(ix); e != .None {
			ix.man.cb_gen, ix.man.cb_n, ix.man.next_gen = old_gen, old_n, old_next
			_ = prim.remove(ix.vfs, cb_path(ix, gen, &buf))
			return 0, false, e
		}
		cb_gc(ix)
		return i64(len(out)), true, .None
	}
	return 0, false, .Invalid
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
		if len(name) != 19 || (name[:3] != "vq-" && name[:3] != "zd-") {
			continue
		}
		g, gok := _parse_hex(name[3:])
		if !gok || g == ix.man.cb_gen || (name[:3] == "zd-" && g == ix.man.zd_gen) {
			continue
		}
		used := false
		if name[:3] == "vq-" {
			for s in ix.segs {
				if s.f.cb_gen == g {
					used = true
					break
				}
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

vec_flush :: proc(ix: ^Index, sw: ^Seg_Writer) -> Error {
	m := &ix.mem
	dim := ix.opts.embedder.dim
	sw.f.vids_off = sw_off(sw)
	sw.f.vdata_off = sw_off(sw)
	sw.f.vcodes_off = sw_off(sw)
	if len(m.vids) == 0 || dim <= 0 {
		return .None
	}
	live := make([dynamic]int, context.temp_allocator)
	for id, i in m.vids {
		if m.docs[u64(id) - m.base].flags & DF_DELETED == 0 {
			append(&live, i)
		}
	}
	if len(live) == 0 {
		return .None
	}
	sw.f.vec_dim = u64(dim)
	sw.f.vec_n = u64(len(live))
	sw.f.vrec = i64(dim) * 4
	b: [4]u8
	for i in live {
		prim.put_u32le(b[:], m.vids[i])
		sw_meta(sw, b[:])
	}
	sw.f.vdata_off = sw_off(sw)
	for i in live {
		sw_write(sw, slice.to_bytes(m.vecs[i * dim:][:dim]))
	}
	sw.f.vcodes_off = sw_off(sw)
	return sw.out.err
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

Pnode :: struct {
	sim:  f32,
	pos:  u32,
	done: bool,
}

Visited :: struct {
	slots: []u32,
	mask:  u32,
}

visited_init :: proc(v: ^Visited, n: int, allocator: runtime.Allocator) {
	size := 64
	for size < n * 2 {
		size *= 2
	}
	v.slots = make([]u32, size, allocator)
	v.mask = u32(size - 1)
}

visited_clear :: proc "contextless" (v: ^Visited) {
	slice.fill(v.slots, 0)
}

visited_add :: proc "contextless" (v: ^Visited, x: u32) -> bool #no_bounds_check {
	h := (x * 0x9E3779B1) & v.mask
	for {
		s := v.slots[h]
		if s == 0 {
			v.slots[h] = x + 1
			return true
		}
		if s == x + 1 {
			return false
		}
		h = (h + 1) & v.mask
	}
}

pool_insert :: proc(pool: ^[dynamic]Pnode, cap_n: int, x: Pnode) -> bool {
	n := len(pool)
	if n == cap_n && x.sim <= pool[n - 1].sim {
		return false
	}
	i := n
	for i > 0 && pool[i - 1].sim < x.sim {
		i -= 1
	}
	if n < cap_n {
		append_nothing(pool)
	}
	for k := len(pool) - 1; k > i; k -= 1 {
		pool[k] = pool[k - 1]
	}
	pool[i] = x
	return true
}

@(private)
_graph_search :: proc(e: ^Exec, si: int, s: ^Seg, cb: ^Cb, lut: []f32, q: []f32, beam: int, heap: ^[dynamic]Vhit, cap_n: int, vis: ^Visited, rec: []u8) -> Error {
	n := s.f.vec_n
	dim := int(s.f.vec_dim)
	m := int(s.f.vec_m)
	if m != cb.m || dim != cb.dim || n == 0 {
		return .Corrupt
	}
	pool := make([dynamic]Pnode, 0, beam + 1, e.alloc)
	visited_clear(vis)
	visited_add(vis, u32(s.f.medoid))
	append(&pool, Pnode{sim = max(f32), pos = u32(s.f.medoid)})
	vrec := int(s.f.vrec)
	ids_at := 4 + dim * 4
	codes_at := ids_at + DEGREE * 4
	for {
		idx := -1
		for p, i in pool {
			if !p.done {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		pool[idx].done = true
		pos := pool[idx].pos
		cache_read(&e.ix.cache, s, s.f.vdata_off + i64(pos) * i64(vrec), rec[:vrec]) or_return
		deg := int(prim.get_u32le(rec))
		if deg > DEGREE {
			return .Corrupt
		}
		v := slice.reinterpret([]f32, rec[4:][:dim * 4])
		_vheap_push(heap, cap_n, Vhit{score = dot(q, v), seg = si, pos = pos})
		for i in 0 ..< deg {
			nb := prim.get_u32le(rec[ids_at + 4 * i:])
			if u64(nb) >= n {
				return .Corrupt
			}
			if !visited_add(vis, nb) {
				continue
			}
			sim := adc(lut, rec[codes_at + i * m:][:m], cb.ksub)
			pool_insert(&pool, beam, Pnode{sim = sim, pos = nb})
		}
	}
	return .None
}

vec_candidates :: proc(e: ^Exec, q: []f32, want: int, beam: int) -> (out: [dynamic]Vhit, err: Error) {
	a := e.alloc
	dim := len(q)
	cap_n := max(want, 10)
	heap := make([dynamic]Vhit, 0, cap_n, a)
	chunk := make([]f32, (1 << 20) / 4, a)
	cbs := make(map[u64]^Cb, a)
	luts := make(map[u64][]f32, a)
	vis: Visited
	visited_init(&vis, max(beam, cap_n) * DEGREE * 8, a)
	rec: []u8
	for si in 0 ..< len(e.ix.segs) {
		s := &e.ix.segs[si]
		n := int(s.f.vec_n)
		if n == 0 {
			continue
		}
		if int(s.f.vec_dim) != dim {
			return out, .Corrupt
		}
		if s.f.vec_m == 0 {
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
					_vheap_push(&heap, cap_n, Vhit{score = dot(q, chunk[k * dim:][:dim]), seg = si, pos = u32(p + k)})
				}
			}
			continue
		}
		cb, ok := cbs[s.f.cb_gen]
		if !ok {
			cb = cb_load(e.ix, s.f.cb_gen, a) or_return
			if cb.dim != dim {
				return out, .Corrupt
			}
			lut := make([]f32, cb.m * cb.ksub, a)
			cb_lut(cb, q, lut)
			cbs[s.f.cb_gen] = cb
			luts[s.f.cb_gen] = lut
		}
		if len(rec) < int(s.f.vrec) {
			rec = make([]u8, int(s.f.vrec), a)
		}
		_graph_search(e, si, s, cb, luts[s.f.cb_gen], q, max(beam, cap_n), &heap, cap_n, &vis, rec) or_return
	}
	for &h in heap {
		s := &e.ix.segs[h.seg]
		b: [4]u8
		cache_read(&e.ix.cache, s, s.f.vids_off + i64(h.pos) * 4, b[:]) or_return
		h.id = prim.get_u32le(b[:])
		if u64(h.id) < s.f.lo || u64(h.id) >= s.f.hi {
			return out, .Corrupt
		}
	}
	m := &e.ix.mem
	for id, i in m.vids {
		x := Vhit{score = dot(q, m.vecs[i * dim:][:dim]), seg = len(e.ix.segs), id = id}
		_vheap_push(&heap, cap_n, x)
	}
	slice.sort_by(heap[:], proc(x, y: Vhit) -> bool {
		return _vh_less(y, x)
	})
	return heap, .None
}

Vmerge_Phase :: enum u8 {
	Load,
	Consolidate,
	Insert,
	Medoid,
	Prune,
	Repair,
	Write,
	Codes,
	Done,
}

Vmerge :: struct {
	phase:    Vmerge_Phase,
	graph:    bool,
	cb:       ^Cb,
	sq:       []i8,
	sqs:      []f32,
	n:        int,
	dim:      int,
	m:        int,
	rec:      int,
	base:     int,
	src:      []u64,
	codes:    []u8,
	adj:      []u32,
	deg:      []u8,
	repair:   []bool,
	inserted: []bool,
	dead_adj: map[u32][]u32,
	lost:     map[u32][dynamic]u32,
	in_i:     int,
	pos:      int,
	cursor:   int,
	entry:    u32,
	has_entry: bool,
	entry_fixed: bool,
	reach:    []bool,
	bfs:      [dynamic]u32,
	bfs_head: int,
	medoid:   u32,
	vis:      Visited,
	pool:     [dynamic]Pnode,
	cands:    [dynamic]u32,
	keep:     [dynamic]u32,
	dists:    [dynamic]f32,
	order:    [dynamic]int,
	c2:       [dynamic]u32,
	s2:       [dynamic]f32,
	nbrs:     [dynamic]u32,
	extra:    [dynamic]u32,
	vec:      []f32,
	lut:      []f32,
	buf:      []u8,
	out:      []u8,
}

@(private)
_vm_out :: proc "contextless" (m: ^Merge, i: int, p: u32) -> (o: u32, dead: bool) {
	before, is_dead := _vdead_before(m.vdead[i][:], p)
	return m.vbase[i] + p - u32(before), is_dead
}

@(private)
_vm_read_vec :: proc(m: ^Merge, o: int, out: []f32) -> Error {
	src := m.vm.src[o]
	s := &m.segs[int(src >> 32)]
	bytes := slice.to_bytes(out)
	got, e := prim.read_at(s.vfs, s.fd, bytes, rec_vec_off(s, src & 0xffff_ffff))
	if e != .None {
		return _perr(e)
	}
	if got != len(bytes) {
		return .Corrupt
	}
	return .None
}

@(private)
_sim :: #force_inline proc "contextless" (vm: ^Vmerge, a, b: u32) -> f32 {
	return vm.sqs[a] * vm.sqs[b] * f32(dot_i8(vm.sq[int(a) * vm.dim:][:vm.dim], vm.sq[int(b) * vm.dim:][:vm.dim]))
}

@(private)
_dist :: #force_inline proc "contextless" (sim: f32) -> f32 {
	return math.sqrt(max(0, 2 - 2 * sim))
}

@(private)
_prune :: proc(vm: ^Vmerge, p: u32, cands: []u32, sims: []f32, limit: int) {
	resize(&vm.order, len(cands))
	order := vm.order[:]
	for i in 0 ..< len(cands) {
		order[i] = i
	}
	Ctx :: struct {
		sims: []f32,
	}
	ctx := Ctx{sims}
	slice.sort_by_with_data(order, proc(x, y: int, d: rawptr) -> bool {
			c := (^Ctx)(d)
			return c.sims[x] > c.sims[y]
		}, &ctx)
	clear(&vm.keep)
	for i in order {
		c := cands[i]
		if c == p {
			continue
		}
		dup := false
		for r in vm.keep {
			if r == c {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		if len(vm.keep) >= limit {
			break
		}
		dpc := _dist(sims[i])
		ok := true
		for r in vm.keep {
			if ALPHA * _dist(_sim(vm, r, c)) <= dpc {
				ok = false
				break
			}
		}
		if ok {
			append(&vm.keep, c)
		}
	}
	if len(vm.keep) < limit {
		fill: for i in order {
			if len(vm.keep) >= limit {
				break
			}
			c := cands[i]
			if c == p {
				continue
			}
			for r in vm.keep {
				if r == c {
					continue fill
				}
			}
			append(&vm.keep, c)
		}
	}
	base := int(p) * DEG_CAP
	for r, i in vm.keep {
		vm.adj[base + i] = r
	}
	vm.deg[p] = u8(len(vm.keep))
}

@(private)
_prune_node :: proc(vm: ^Vmerge, p: u32, extra: []u32, limit: int) {
	clear(&vm.cands)
	clear(&vm.dists)
	base := int(p) * DEG_CAP
	for i in 0 ..< int(vm.deg[p]) {
		append(&vm.cands, vm.adj[base + i])
	}
	append(&vm.cands, ..extra)
	for c in vm.cands {
		append(&vm.dists, _sim(vm, p, c))
	}
	clear(&vm.c2)
	append(&vm.c2, ..vm.cands[:])
	clear(&vm.s2)
	append(&vm.s2, ..vm.dists[:])
	_prune(vm, p, vm.c2[:], vm.s2[:], limit)
}

@(private)
_vm_greedy :: proc(vm: ^Vmerge, p: u32) {
	visited_clear(&vm.vis)
	clear(&vm.pool)
	clear(&vm.cands)
	clear(&vm.dists)
	e := vm.entry
	visited_add(&vm.vis, e)
	pool_insert(&vm.pool, L_BUILD, Pnode{sim = _sim(vm, p, e), pos = e})
	for {
		idx := -1
		for x, i in vm.pool {
			if !x.done {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		vm.pool[idx].done = true
		x := vm.pool[idx]
		append(&vm.cands, x.pos)
		append(&vm.dists, x.sim)
		base := int(x.pos) * DEG_CAP
		for i in 0 ..< int(vm.deg[x.pos]) {
			nb := vm.adj[base + i]
			if !visited_add(&vm.vis, nb) {
				continue
			}
			pool_insert(&vm.pool, L_BUILD, Pnode{sim = _sim(vm, p, nb), pos = nb})
		}
	}
}

@(private)
_vm_insert :: proc(m: ^Merge, o: u32) -> Error {
	vm := m.vm
	if !vm.has_entry {
		vm.entry = o
		vm.has_entry = true
		vm.deg[o] = 0
		vm.inserted[o] = true
		return .None
	}
	_vm_greedy(vm, o)
	clear(&vm.c2)
	append(&vm.c2, ..vm.cands[:])
	clear(&vm.s2)
	append(&vm.s2, ..vm.dists[:])
	_prune(vm, o, vm.c2[:], vm.s2[:], DEGREE)
	vm.inserted[o] = true
	clear(&vm.nbrs)
	append(&vm.nbrs, ..vm.adj[int(o) * DEG_CAP:][:int(vm.deg[o])])
	nbrs := vm.nbrs[:]
	one := [1]u32{o}
	for j in nbrs {
		d := int(vm.deg[j])
		dup := false
		for i in 0 ..< d {
			if vm.adj[int(j) * DEG_CAP + i] == o {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		if d < DEG_CAP {
			vm.adj[int(j) * DEG_CAP + d] = o
			vm.deg[j] = u8(d + 1)
		} else {
			_prune_node(vm, j, one[:], DEGREE)
		}
	}
	return .None
}

vmerge_init :: proc(ix: ^Index, m: ^Merge) -> Error {
	a := m.alloc
	vm := new(Vmerge, a)
	m.vm = vm
	vm.n = int(m.sw.f.vec_n)
	vm.dim = int(ix.man.dim)
	vm.base = -1
	if vm.n == 0 {
		vm.phase = .Done
		return .None
	}
	if ix.man.cb_gen == 0 || vm.n < GRAPH_MIN {
		vm.graph = false
		vm.phase = .Write
		vm.rec = vm.dim * 4
		return .None
	}
	vm.graph = true
	vm.cb = cb_load(ix, ix.man.cb_gen, a) or_return
	if vm.cb.dim != vm.dim {
		return .Corrupt
	}
	vm.m = vm.cb.m
	vm.rec = rec_size(vm.dim, vm.m)
	k := vm.cb.ksub
	vm.sq = make([]i8, vm.n * vm.dim, a)
	vm.sqs = make([]f32, vm.n, a)
	vm.src = make([]u64, vm.n, a)
	vm.codes = make([]u8, vm.n * vm.m, a)
	vm.adj = make([]u32, vm.n * DEG_CAP, a)
	vm.deg = make([]u8, vm.n, a)
	vm.repair = make([]bool, vm.n, a)
	vm.inserted = make([]bool, vm.n, a)
	vm.dead_adj = make(map[u32][]u32, a)
	vm.lost = make(map[u32][dynamic]u32, a)
	if vm.src == nil || vm.codes == nil || vm.adj == nil || vm.sq == nil {
		return .No_Memory
	}
	best := u64(0)
	for s, i in m.segs {
		live := s.f.vec_n - u64(len(m.vdead[i]))
		if s.f.vec_m > 0 && s.f.vec_m == u64(vm.m) && live > best {
			best = live
			vm.base = i
		}
	}
	visited_init(&vm.vis, L_BUILD * DEG_CAP * 8, a)
	vm.pool = make([dynamic]Pnode, 0, L_BUILD + 1, a)
	vm.cands = make([dynamic]u32, a)
	vm.keep = make([dynamic]u32, a)
	vm.dists = make([dynamic]f32, a)
	vm.order = make([dynamic]int, a)
	vm.c2 = make([dynamic]u32, a)
	vm.s2 = make([dynamic]f32, a)
	vm.nbrs = make([dynamic]u32, a)
	vm.extra = make([dynamic]u32, a)
	vm.vec = make([]f32, vm.dim, a)
	vm.lut = make([]f32, vm.m * k, a)
	vm.phase = .Load
	return .None
}

vmerge_step :: proc(m: ^Merge) -> (done: bool, err: Error) {
	vm := m.vm
	switch vm.phase {
	case .Load:
		return false, _vm_load(m)
	case .Consolidate:
		for vm.cursor < vm.n {
			o := u32(vm.cursor)
			vm.cursor += 1
			if !vm.repair[o] {
				continue
			}
			clear(&vm.extra)
			extra := &vm.extra
			base := int(o) * DEG_CAP
			for i in 0 ..< int(vm.deg[o]) {
				append(extra, vm.adj[base + i])
			}
			for d in vm.lost[o] {
				for x in vm.dead_adj[d] or_else nil {
					if x != o {
						append(extra, x)
					}
				}
			}
			vm.deg[o] = 0
			_prune_node(vm, o, extra[:], DEGREE)
			m.work += INSERT_WORK
			return false, .None
		}
		vm.cursor = 0
		vm.phase = .Insert
		return false, .None
	case .Insert:
		for vm.cursor < vm.n {
			o := u32(vm.cursor)
			vm.cursor += 1
			if vm.inserted[o] {
				continue
			}
			_vm_insert(m, o) or_return
			m.work += INSERT_WORK
			return false, .None
		}
		vm.cursor = 0
		vm.phase = .Prune
		return false, .None
	case .Prune:
		end := min(vm.cursor + 1024, vm.n)
		for o in vm.cursor ..< end {
			if int(vm.deg[o]) > DEGREE {
				_prune_node(vm, u32(o), nil, DEGREE)
				m.work += INSERT_WORK / 4
			}
		}
		vm.cursor = end
		if vm.cursor == vm.n {
			vm.cursor = 0
			vm.reach = make([]bool, vm.n, m.alloc)
			vm.bfs = make([dynamic]u32, 0, vm.n, m.alloc)
			vm.reach[vm.entry] = true
			append(&vm.bfs, vm.entry)
			vm.bfs_head = 0
			vm.phase = .Repair
		}
		return false, .None
	case .Repair:
		_vm_bfs(vm)
		m.work += 4096
		for vm.cursor < vm.n {
			u := u32(vm.cursor)
			vm.cursor += 1
			if vm.reach[u] {
				continue
			}
			_vm_greedy(vm, u)
			best, bs := -1, min(f32)
			for c, i in vm.cands {
				if c != u && vm.dists[i] > bs {
					best, bs = int(c), vm.dists[i]
				}
			}
			if best < 0 {
				return false, .Corrupt
			}
			r := u32(best)
			d := int(vm.deg[r])
			if d < DEGREE {
				vm.adj[int(r) * DEG_CAP + d] = u
				vm.deg[r] = u8(d + 1)
			} else {
				vm.adj[int(r) * DEG_CAP + DEGREE - 1] = u
			}
			vm.reach[u] = true
			append(&vm.bfs, u)
			m.work += INSERT_WORK
			return false, .None
		}
		vm.cursor = 0
		vm.phase = .Write
		return false, .None
	case .Medoid:
		mean := make([]f32, vm.dim, context.temp_allocator)
		for o in 0 ..< vm.n {
			q := vm.sq[o * vm.dim:][:vm.dim]
			sc := vm.sqs[o]
			for d in 0 ..< vm.dim {
				mean[d] += sc * f32(q[d])
			}
		}
		mq := make([]i8, vm.dim, context.temp_allocator)
		quantize(mean, mq)
		best, bs := 0, min(i32)
		for o in 0 ..< vm.n {
			if vm.base >= 0 && !vm.inserted[o] {
				continue
			}
			s := dot_i8(mq, vm.sq[o * vm.dim:][:vm.dim])
			if s > bs {
				best, bs = o, s
			}
		}
		if vm.has_entry {
			vm.medoid = vm.entry
		} else {
			vm.medoid = u32(best)
			vm.entry = vm.medoid
			vm.has_entry = true
			vm.inserted[vm.medoid] = true
		}
		vm.cursor = 0
		vm.phase = .Consolidate if len(vm.dead_adj) > 0 else .Insert
		m.work += vm.n * 4
		return false, .None
	case .Write:
		return _vm_write(m)
	case .Codes:
		if vm.graph {
			left := vm.n * vm.m - vm.cursor
			c := min(left, 1 << 20)
			sw_write(&m.sw, vm.codes[vm.cursor:][:c])
			vm.cursor += c
			if vm.cursor < vm.n * vm.m {
				return false, m.sw.out.err
			}
		}
		vm.phase = .Done
		return false, .None
	case .Done:
		return true, .None
	}
	return false, .Invalid
}

@(private)
_vm_load :: proc(m: ^Merge) -> Error {
	vm := m.vm
	if vm.in_i >= len(m.segs) {
		vm.cursor = 0
		vm.phase = .Medoid
		return .None
	}
	i := vm.in_i
	s := &m.segs[i]
	n := int(s.f.vec_n)
	if vm.pos >= n {
		vm.in_i += 1
		vm.pos = 0
		return .None
	}
	is_base := i == vm.base
	graph_in := s.f.vec_m > 0
	same_codes := graph_in && s.f.cb_gen == vm.cb.gen && s.f.vec_m == u64(vm.m)
	vrec := int(s.f.vrec)
	c := min(max(1, (1 << 20) / vrec), n - vm.pos)
	want := c * vrec
	if len(vm.buf) < want {
		vm.buf = make([]u8, want, m.alloc)
	}
	got, e := prim.read_at(s.vfs, s.fd, vm.buf[:want], s.f.vdata_off + i64(vm.pos) * i64(vrec))
	if e != .None {
		return _perr(e)
	}
	if got != want {
		return .Corrupt
	}
	codes: []u8
	if same_codes {
		cw := c * vm.m
		if len(vm.out) < cw {
			vm.out = make([]u8, cw, m.alloc)
		}
		g2, e2 := prim.read_at(s.vfs, s.fd, vm.out[:cw], s.f.vcodes_off + i64(vm.pos) * i64(vm.m))
		if e2 != .None {
			return _perr(e2)
		}
		if g2 != cw {
			return .Corrupt
		}
		codes = vm.out[:cw]
	}
	dim := vm.dim
	voff := 4 if graph_in else 0
	for k in 0 ..< c {
		p := u32(vm.pos + k)
		o, dead := _vm_out(m, i, p)
		rec := vm.buf[k * vrec:][:vrec]
		if is_base {
			deg := int(prim.get_u32le(rec))
			if deg > DEGREE {
				return .Corrupt
			}
			ids_at := 4 + dim * 4
			if dead {
				lst := make([dynamic]u32, m.alloc)
				for x in 0 ..< deg {
					nb := prim.get_u32le(rec[ids_at + 4 * x:])
					if u64(nb) >= s.f.vec_n {
						return .Corrupt
					}
					no, nd := _vm_out(m, i, nb)
					if !nd {
						append(&lst, no)
					}
				}
				vm.dead_adj[p] = lst[:]
				if p == u32(s.f.medoid) && len(lst) > 0 {
					vm.entry = lst[0]
					vm.has_entry = true
					vm.entry_fixed = true
				}
				continue
			}
			nd_count := 0
			for x in 0 ..< deg {
				nb := prim.get_u32le(rec[ids_at + 4 * x:])
				if u64(nb) >= s.f.vec_n {
					return .Corrupt
				}
				no, nd := _vm_out(m, i, nb)
				if nd {
					vm.repair[o] = true
					lst := vm.lost[o] or_else make([dynamic]u32, m.alloc)
					append(&lst, nb)
					vm.lost[o] = lst
					continue
				}
				vm.adj[int(o) * DEG_CAP + nd_count] = no
				nd_count += 1
			}
			vm.deg[o] = u8(nd_count)
			vm.inserted[o] = true
			if !vm.entry_fixed && (!vm.has_entry || p == u32(s.f.medoid)) {
				vm.entry = o
				vm.has_entry = true
				vm.entry_fixed = p == u32(s.f.medoid)
			}
		}
		if dead {
			continue
		}
		vm.src[o] = u64(i) << 32 | u64(p)
		v := slice.reinterpret([]f32, rec[voff:][:dim * 4])
		vm.sqs[o] = quantize(v, vm.sq[int(o) * dim:][:dim])
		code := vm.codes[int(o) * vm.m:][:vm.m]
		if same_codes {
			copy(code, codes[k * vm.m:][:vm.m])
		} else {
			cb_encode(vm.cb, v, code)
			m.work += 2048
		}
	}
	vm.pos += c
	m.work += want
	return .None
}

@(private)
_vm_write :: proc(m: ^Merge) -> (done: bool, err: Error) {
	vm := m.vm
	if vm.cursor == 0 && !vm.graph && len(vm.src) == 0 {
		vm.src = make([]u64, vm.n, m.alloc)
		o := 0
		for s, i in m.segs {
			for p in 0 ..< int(s.f.vec_n) {
				_, dead := _vm_out(m, i, u32(p))
				if !dead {
					vm.src[o] = u64(i) << 32 | u64(p)
					o += 1
				}
			}
		}
		if o != vm.n {
			return false, .Corrupt
		}
	}
	if vm.cursor == 0 {
		if vm.graph {
			pad := (REC_ALIGN - int(sw_off(&m.sw) % REC_ALIGN)) % REC_ALIGN
			if pad > 0 {
				zeros: [REC_ALIGN]u8
				sw_write(&m.sw, zeros[:pad])
			}
		}
		m.sw.f.vdata_off = sw_off(&m.sw)
		m.sw.f.vrec = i64(vm.rec)
		if len(vm.out) < vm.rec {
			vm.out = make([]u8, vm.rec, m.alloc)
		}
	}
	end := min(vm.cursor + 256, vm.n)
	rec := vm.out[:vm.rec]
	for o in vm.cursor ..< end {
		slice.fill(rec, 0)
		if vm.graph {
			deg := min(int(vm.deg[o]), DEGREE)
			prim.put_u32le(rec, u32(deg))
			v := slice.reinterpret([]f32, rec[4:][:vm.dim * 4])
			_vm_read_vec(m, o, v) or_return
			ids_at := 4 + vm.dim * 4
			codes_at := ids_at + DEGREE * 4
			for x in 0 ..< deg {
				nb := vm.adj[o * DEG_CAP + x]
				prim.put_u32le(rec[ids_at + 4 * x:], nb)
				copy(rec[codes_at + x * vm.m:], vm.codes[int(nb) * vm.m:][:vm.m])
			}
		} else {
			v := slice.reinterpret([]f32, rec[:vm.dim * 4])
			_vm_read_vec(m, o, v) or_return
		}
		sw_write(&m.sw, rec)
	}
	vm.cursor = end
	if vm.cursor < vm.n {
		return false, m.sw.out.err
	}
	m.sw.f.vcodes_off = sw_off(&m.sw)
	if vm.graph {
		m.sw.f.vec_m = u64(vm.m)
		m.sw.f.cb_gen = vm.cb.gen
		m.sw.f.medoid = u64(vm.medoid)
	}
	vm.cursor = 0
	vm.phase = .Codes
	return false, m.sw.out.err
}

@(private)
_vm_bfs :: proc(vm: ^Vmerge) {
	for vm.bfs_head < len(vm.bfs) {
		x := vm.bfs[vm.bfs_head]
		vm.bfs_head += 1
		base := int(x) * DEG_CAP
		for k in 0 ..< int(vm.deg[x]) {
			nb := vm.adj[base + k]
			if !vm.reach[nb] {
				vm.reach[nb] = true
				append(&vm.bfs, nb)
			}
		}
	}
}

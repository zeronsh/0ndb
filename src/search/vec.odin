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
ALPHA :: f32(1.2)
DEFAULT_BEAM :: 128
MAX_BEAM :: 4096
GRAPH_MIN :: 2048
REC_ALIGN :: 4096
INSERT_WORK :: 16 * 1024
CB_MAGIC :: u64(0x6276_6863_7273_6e30)
CB_VERSION :: u64(4)
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
	if len(data) < CB_HEADER + np * 4 + 16 {
		return nil, .Corrupt
	}
	nid := int(prim.get_u64le(data[CB_HEADER + np * 4:]))
	if nid < 0 || len(data) != CB_HEADER + np * 4 + 8 + nid * 4 + 8 {
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
	ids:    []u32,
	dead:   []u32,
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
	if ix.cb_tainted && total < u64(ix.opts.train_min) {
		old := ix.man.cb_gen
		ix.man.cb_gen = 0
		if e := manifest_write(ix); e != .None {
			ix.man.cb_gen = old
			return false, e
		}
		ix.cb_tainted = false
		return false, .None
	}
	if total < u64(ix.opts.train_min) || (ix.man.cb_gen != 0 && total < TRAIN_GROWTH * ix.man.cb_n && !ix.cb_tainted) {
		return false, .None
	}
	dead := _dead_sorted(ix, ix.allocator) or_return
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
	t.m = pq_m(dim)
	t.dsub = dim / t.m
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
	t.ids = make([]u32, t.sn, a)
	t.dead = make([]u32, len(dead), a)
	copy(t.dead, dead)
	delete(dead, ix.allocator)
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
			g0 := u64(i) * total / u64(t.sn)
			found := false
			for step in u64(0) ..< min(total, 4096) {
				g := (g0 + step) % total
				for &s in ix.segs {
					if g < s.f.vec_n {
						vb: [4]u8
						cache_read(&ix.cache, &s, s.f.vids_off + i64(g) * 4, vb[:]) or_return
						id := prim.get_u32le(vb[:])
						if _, dead := slice.binary_search(t.dead, id); dead {
							break
						}
						dst := slice.to_bytes(t.sample[i * dim:][:dim])
						got, rerr := prim.read_at(s.vfs, s.fd, dst, rec_vec_off(&s, g))
						if rerr != .None {
							return 0, false, _perr(rerr)
						}
						if got != len(dst) {
							return 0, false, .Corrupt
						}
						t.ids[i] = id
						found = true
						break
					}
					g -= s.f.vec_n
				}
				if found {
					break
				}
			}
			if !found {
				if ix.cb_tainted {
					old := ix.man.cb_gen
					ix.man.cb_gen = 0
					if e := manifest_write(ix); e != .None {
						ix.man.cb_gen = old
						return 0, false, e
					}
					ix.cb_tainted = false
				}
				return 0, true, .None
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
		prim.write_u64le(&w, u64(len(t.ids)))
		for id in t.ids {
			prim.write_u32le(&w, id)
		}
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
		ix.cb_tainted = false
		ix.taint_check = true
		cb_gc(ix)
		return i64(len(out)), true, .None
	}
	return 0, false, .Invalid
}

cb_gc :: proc(ix: ^Index) {
	if !_dir_synced(ix) {
		return
	}
	d: prim.Dir
	if prim.dir_open(ix.vfs, &d, ix.dir, context.temp_allocator) != .None {
		return
	}
	drop := make([dynamic]string, context.temp_allocator)
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
		if !gok || (name[:3] == "vq-" && g == ix.man.cb_gen) || (name[:3] == "zd-" && g == ix.man.zd_gen) {
			continue
		}
		used := false
		for s in ix.segs {
			if (name[:3] == "vq-" && s.f.vec_m > 0 && s.f.cb_gen == g) || (name[:3] == "zd-" && s.f.zd_gen == g) {
				used = true
				break
			}
		}
		if !used {
			append(&drop, _clone_str(name, context.temp_allocator))
			if name[:3] == "zd-" {
				zstd_forget(&ix.zstd, g)
			}
		}
	}
	prim.dir_close(ix.vfs, &d)
	for name in drop {
		secure_remove(ix, name)
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

vec_candidates :: proc(e: ^Exec, q: []f32, want: int, beam: int, scale: int) -> (out: [dynamic]Vhit, err: Error) {
	a := e.alloc
	dim := len(q)
	cap_n := max(want, 10)
	heap := make([dynamic]Vhit, 0, cap_n, a)
	chunk := make([]f32, (1 << 20) / 4, a)
	cbs := make(map[u64]^Cb, a)
	luts := make(map[u64][]f32, a)
	vis: Visited
	vis_n := beam if beam > 0 else DEFAULT_BEAM
	for &sg in e.ix.segs {
		if beam <= 0 && sg.f.vbeam > 0 {
			vis_n = max(vis_n, int(sg.f.vbeam))
		}
	}
	visited_init(&vis, max(min(vis_n * scale, MAX_BEAM), cap_n) * DEGREE * 8, a)
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
		sb := beam if beam > 0 else (int(s.f.vbeam) if s.f.vbeam > 0 else DEFAULT_BEAM)
		_graph_search(e, si, s, cb, luts[s.f.cb_gen], q, max(min(sb * scale, MAX_BEAM), cap_n), &heap, cap_n, &vis, rec) or_return
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

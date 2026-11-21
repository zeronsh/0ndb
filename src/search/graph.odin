package search

import "base:runtime"
import "core:math"
import "core:slice"
import "core:sync"
import "core:thread"
import "../prim"

DEGREE :: 64
DEG_CAP :: 80
INIT_DEGREE :: 24
L_BUILD :: 96
BUILD_RAM :: 64 * 1024 * 1024
BUILD_THREADS :: 8
STEP_NODES :: 4096
NLOCKS :: 4096
PART_SAMPLE :: 8192
PART_ITERS :: 8
MAX_PARTS :: 1024
SHARD_REC :: 8 + DEGREE * 4
NONE_U16 :: u16(0xffff)
NONE_U32 :: u32(0xffff_ffff)

Gb_Phase :: enum u8 {
	Assign,
	Load,
	Build,
	Spill,
	Final,
	Repair,
	Codes,
	Done,
}

Shard :: struct {
	n:      int,
	ids:    [dynamic]u32,
	sq:     [dynamic]i8,
	sqs:    [dynamic]f32,
	adj:    [dynamic]u32,
	deg:    [dynamic]u8,
	locks:  []sync.Mutex,
	entry:  u32,
	alpha:  f32,
	dim:    int,
}

Job :: enum u8 {
	Encode,
	Build,
}

Worker :: struct {
	gb:     ^Graph_Build,
	job:    Job,
	from:   int,
	to:     int,
	arena:  runtime.Arena,
	vis:    Visited,
	pool:   [dynamic]Pnode,
	cands:  [dynamic]u32,
	dists:  [dynamic]f32,
	keep:   [dynamic]u32,
	order:  [dynamic]int,
	c2:     [dynamic]u32,
	s2:     [dynamic]f32,
	vec:    []f32,
}

Graph_Build :: struct {
	phase:    Gb_Phase,
	graph:    bool,
	cb:       ^Cb,
	n:        int,
	dim:      int,
	m:        int,
	rec:      int,
	k:        int,
	cap_s:    int,
	src:      []u64,
	codes:    []u8,
	parts:    []f32,
	assign:   [][2]u16,
	recidx:   [][2]u32,
	sh:       Shard,
	shard:    int,
	pass:     int,
	cursor:   int,
	medoid:   u32,
	best:     int,
	tmp_fd:   prim.Fd,
	tmp_n:    u32,
	chunk:    []f32,
	chunk_lo: int,
	chunk_n:  int,
	rbuf:     []u8,
	out:      []u8,
	reach:    []u64,
	queue:    [dynamic]u32,
	qh:       int,
	fallback: u32,
	indeg:    []u8,
	fixed:    int,
	rounds:   int,
	nthreads: int,
	workers:  []Worker,
	alloc:    runtime.Allocator,
}

@(private)
_vm_out :: proc "contextless" (m: ^Merge, i: int, p: u32) -> (o: u32, dead: bool) {
	before, is_dead := _vdead_before(m.vdead[i][:], p)
	return m.vbase[i] + p - u32(before), is_dead
}

@(private)
_gb_read_vec :: proc(m: ^Merge, o: int, out: []f32) -> Error {
	src := m.gb.src[o]
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

pq_m :: proc "contextless" (dim: int) -> int {
	for m := 32; m >= 1; m -= 1 {
		if dim % m == 0 {
			return m
		}
	}
	return 1
}

vmerge_init :: proc(ix: ^Index, m: ^Merge) -> Error {
	a := m.alloc
	gb := new(Graph_Build, a)
	m.gb = gb
	gb.alloc = a
	gb.n = int(m.sw.f.vec_n)
	gb.dim = int(ix.man.dim)
	gb.tmp_fd = prim.INVALID_FD
	if gb.n == 0 {
		gb.phase = .Done
		return .None
	}
	gb.src = make([]u64, gb.n, a)
	o := 0
	for s, i in m.segs {
		for p in 0 ..< int(s.f.vec_n) {
			_, dead := _vm_out(m, i, u32(p))
			if !dead {
				if o >= gb.n {
					return .Corrupt
				}
				gb.src[o] = u64(i) << 32 | u64(p)
				o += 1
			}
		}
	}
	if o != gb.n {
		return .Corrupt
	}
	if ix.man.cb_gen == 0 || gb.n < GRAPH_MIN {
		gb.graph = false
		gb.rec = gb.dim * 4
		gb.phase = .Final
		return .None
	}
	gb.graph = true
	gb.cb = cb_load(ix, ix.man.cb_gen, a) or_return
	if gb.cb.dim != gb.dim {
		return .Corrupt
	}
	gb.m = gb.cb.m
	gb.rec = rec_size(gb.dim, gb.m)
	gb.codes = make([]u8, gb.n * gb.m, a)
	gb.assign = make([][2]u16, gb.n, a)
	gb.recidx = make([][2]u32, gb.n, a)
	if gb.codes == nil || gb.assign == nil || gb.recidx == nil {
		return .No_Memory
	}
	for &r in gb.recidx {
		r = {NONE_U32, NONE_U32}
	}
	per := gb.dim + 4 + DEG_CAP * 4 + 1 + 4
	gb.cap_s = max(GRAPH_MIN, BUILD_RAM / per)
	gb.k = gb.n <= gb.cap_s ? 1 : min(MAX_PARTS, (2 * gb.n + gb.cap_s - 1) / gb.cap_s + 1)
	gb.nthreads = BUILD_THREADS
	gb.workers = make([]Worker, gb.nthreads, a)
	for &w in gb.workers {
		_worker_init(gb, &w, ix.allocator) or_return
	}
	if gb.k > 1 {
		_gb_partition(m) or_return
	}
	gb.chunk = make([]f32, 2048 * gb.dim, a)
	gb.sh.dim = gb.dim
	gb.sh.locks = make([]sync.Mutex, NLOCKS, a)
	gb.sh.ids = make([dynamic]u32, 0, gb.cap_s, ix.allocator)
	gb.sh.sq = make([dynamic]i8, 0, gb.cap_s * gb.dim, ix.allocator)
	gb.sh.sqs = make([dynamic]f32, 0, gb.cap_s, ix.allocator)
	gb.sh.adj = make([dynamic]u32, 0, gb.cap_s * DEG_CAP, ix.allocator)
	gb.sh.deg = make([dynamic]u8, 0, gb.cap_s, ix.allocator)
	buf: Name_Buf
	fd, oerr := prim.open_file(ix.vfs, file_path(ix, "graph.tmp", &buf), {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	gb.tmp_fd = fd
	gb.phase = .Assign
	return .None
}

vmerge_destroy :: proc(ix: ^Index, m: ^Merge) {
	gb := m.gb
	if gb == nil {
		return
	}
	if gb.tmp_fd != prim.INVALID_FD {
		prim.close_file(ix.vfs, gb.tmp_fd)
		gb.tmp_fd = prim.INVALID_FD
		_remove(ix, "graph.tmp")
	}
	for &w in gb.workers {
		runtime.arena_destroy(&w.arena)
	}
	delete(gb.sh.ids)
	delete(gb.sh.sq)
	delete(gb.sh.sqs)
	delete(gb.sh.adj)
	delete(gb.sh.deg)
	m.gb = nil
}

@(private)
_worker_init :: proc(gb: ^Graph_Build, w: ^Worker, backing: runtime.Allocator) -> Error {
	w.gb = gb
	if runtime.arena_init(&w.arena, 1 << 20, backing) != nil {
		return .No_Memory
	}
	a := runtime.arena_allocator(&w.arena)
	visited_init(&w.vis, L_BUILD * DEG_CAP * 8, a)
	w.pool = make([dynamic]Pnode, 0, L_BUILD + 1, a)
	w.cands = make([dynamic]u32, 0, 4096, a)
	w.dists = make([dynamic]f32, 0, 4096, a)
	w.keep = make([dynamic]u32, 0, DEG_CAP + 1, a)
	w.order = make([dynamic]int, 0, 4096, a)
	w.c2 = make([dynamic]u32, 0, 4096, a)
	w.s2 = make([dynamic]f32, 0, 4096, a)
	w.vec = make([]f32, gb.dim, a)
	return .None
}

@(private)
_gb_partition :: proc(m: ^Merge) -> Error {
	gb := m.gb
	a := gb.alloc
	sn := min(gb.n, PART_SAMPLE)
	sample := make([]f32, sn * gb.dim, a)
	for i in 0 ..< sn {
		_gb_read_vec(m, i * gb.n / sn, sample[i * gb.dim:][:gb.dim]) or_return
	}
	k := gb.k
	d := gb.dim
	gb.parts = make([]f32, k * d, a)
	for c in 0 ..< k {
		copy(gb.parts[c * d:][:d], sample[((c * sn) / k) * d:][:d])
	}
	sums := make([]f64, k * d, a)
	counts := make([]int, k, a)
	for it in 0 ..< PART_ITERS {
		slice.fill(sums, 0)
		slice.fill(counts, 0)
		for i in 0 ..< sn {
			x := sample[i * d:][:d]
			best, bs := 0, max(f32)
			for c in 0 ..< k {
				dd := l2(x, gb.parts[c * d:][:d])
				if dd < bs {
					best, bs = c, dd
				}
			}
			counts[best] += 1
			for j in 0 ..< d {
				sums[best * d + j] += f64(x[j])
			}
		}
		for c in 0 ..< k {
			if counts[c] == 0 {
				copy(gb.parts[c * d:][:d], sample[((c * 7919 + it * 104729) % sn) * d:][:d])
				continue
			}
			for j in 0 ..< d {
				gb.parts[c * d + j] = f32(sums[c * d + j] / f64(counts[c]))
			}
		}
	}
	return .None
}

@(private)
_run_workers :: proc(gb: ^Graph_Build, job: Job, n: int) {
	if n == 0 {
		return
	}
	t := min(gb.nthreads, max(1, n / 64))
	ths: [BUILD_THREADS]^thread.Thread
	for i in 0 ..< t {
		w := &gb.workers[i]
		w.job = job
		w.from = i * n / t
		w.to = (i + 1) * n / t
		if i == 0 {
			continue
		}
		th := thread.create(_worker_main)
		if th == nil {
			_worker_run(w)
			continue
		}
		th.data = w
		th.init_context = context
		thread.start(th)
		ths[i] = th
	}
	_worker_run(&gb.workers[0])
	for i in 1 ..< t {
		if ths[i] != nil {
			thread.join(ths[i])
			thread.destroy(ths[i])
		}
	}
}

@(private)
_worker_main :: proc(th: ^thread.Thread) {
	_worker_run((^Worker)(th.data))
}

@(private)
_worker_run :: proc(w: ^Worker) {
	gb := w.gb
	switch w.job {
	case .Encode:
		d := gb.dim
		for i in w.from ..< w.to {
			o := gb.chunk_lo + i
			v := gb.chunk[i * d:][:d]
			cb_encode(gb.cb, v, gb.codes[o * gb.m:][:gb.m])
			if gb.k > 1 {
				b0, b1 := 0, -1
				s0, s1 := max(f32), max(f32)
				for c in 0 ..< gb.k {
					dd := l2(v, gb.parts[c * d:][:d])
					if dd < s0 {
						b1, s1 = b0, s0
						b0, s0 = c, dd
					} else if dd < s1 {
						b1, s1 = c, dd
					}
				}
				gb.assign[o] = {u16(b0), u16(b1) if b1 >= 0 && b1 != b0 else NONE_U16}
			} else {
				gb.assign[o] = {0, NONE_U16}
			}
		}
	case .Build:
		for i in w.from ..< w.to {
			_sh_update(w, u32(gb.cursor + i))
		}
	}
}

@(private)
_ssim :: #force_inline proc "contextless" (sh: ^Shard, a, b: u32) -> f32 {
	d := sh.dim
	return sh.sqs[a] * sh.sqs[b] * f32(dot_i8(sh.sq[int(a) * d:][:d], sh.sq[int(b) * d:][:d]))
}

@(private)
_lock :: #force_inline proc "contextless" (sh: ^Shard, x: u32) -> ^sync.Mutex {
	return &sh.locks[x % NLOCKS]
}

@(private)
_sh_greedy :: proc(w: ^Worker, sh: ^Shard, p: u32) {
	visited_clear(&w.vis)
	clear(&w.pool)
	clear(&w.cands)
	clear(&w.dists)
	e := sh.entry
	visited_add(&w.vis, e)
	visited_add(&w.vis, p)
	pool_insert(&w.pool, L_BUILD, Pnode{sim = _ssim(sh, p, e), pos = e})
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
		x := w.pool[idx]
		append(&w.cands, x.pos)
		append(&w.dists, x.sim)
		base := int(x.pos) * DEG_CAP
		dg := min(int(sh.deg[x.pos]), DEG_CAP)
		for i in 0 ..< dg {
			nb := sh.adj[base + i]
			if int(nb) >= sh.n || !visited_add(&w.vis, nb) {
				continue
			}
			pool_insert(&w.pool, L_BUILD, Pnode{sim = _ssim(sh, p, nb), pos = nb})
		}
	}
}

@(private)
_sh_prune :: proc(w: ^Worker, sh: ^Shard, p: u32, cands: []u32, sims: []f32, alpha: f32, limit: int) {
	resize(&w.order, len(cands))
	order := w.order[:]
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
	clear(&w.keep)
	outer: for i in order {
		c := cands[i]
		if c == p {
			continue
		}
		for r in w.keep {
			if r == c {
				continue outer
			}
		}
		if len(w.keep) >= limit {
			break
		}
		dpc := _dist(sims[i])
		for r in w.keep {
			if alpha * _dist(_ssim(sh, r, c)) <= dpc {
				continue outer
			}
		}
		append(&w.keep, c)
	}
}

@(private)
_dist :: #force_inline proc "contextless" (sim: f32) -> f32 {
	return math.sqrt(max(0, 2 - 2 * sim))
}

@(private)
_sh_update :: proc(w: ^Worker, sh_p: u32) {
	gb := w.gb
	sh := &gb.sh
	p := sh_p
	_sh_greedy(w, sh, p)
	clear(&w.c2)
	clear(&w.s2)
	append(&w.c2, ..w.cands[:])
	append(&w.s2, ..w.dists[:])
	lk := _lock(sh, p)
	sync.mutex_lock(lk)
	base := int(p) * DEG_CAP
	for i in 0 ..< int(sh.deg[p]) {
		c := sh.adj[base + i]
		append(&w.c2, c)
		append(&w.s2, _ssim(sh, p, c))
	}
	sync.mutex_unlock(lk)
	_sh_prune(w, sh, p, w.c2[:], w.s2[:], sh.alpha, DEGREE)
	sync.mutex_lock(lk)
	for r, i in w.keep {
		sh.adj[base + i] = r
	}
	sh.deg[p] = u8(len(w.keep))
	sync.mutex_unlock(lk)
	clear(&w.cands)
	append(&w.cands, ..w.keep[:])
	for j in w.cands {
		jl := _lock(sh, j)
		sync.mutex_lock(jl)
		jb := int(j) * DEG_CAP
		d := int(sh.deg[j])
		dup := false
		for i in 0 ..< d {
			if sh.adj[jb + i] == p {
				dup = true
				break
			}
		}
		if !dup {
			if d < DEG_CAP {
				sh.adj[jb + d] = p
				sh.deg[j] = u8(d + 1)
			} else {
				clear(&w.c2)
				clear(&w.s2)
				for i in 0 ..< d {
					c := sh.adj[jb + i]
					append(&w.c2, c)
					append(&w.s2, _ssim(sh, j, c))
				}
				append(&w.c2, p)
				append(&w.s2, _ssim(sh, j, p))
				_sh_prune(w, sh, j, w.c2[:], w.s2[:], sh.alpha, DEGREE)
				for r, i in w.keep {
					sh.adj[jb + i] = r
				}
				sh.deg[j] = u8(len(w.keep))
			}
		}
		sync.mutex_unlock(jl)
	}
}

vmerge_step :: proc(ix: ^Index, m: ^Merge) -> (done: bool, err: Error) {
	gb := m.gb
	switch gb.phase {
	case .Assign:
		if gb.cursor >= gb.n {
			gb.cursor = 0
			gb.shard = 0
			gb.phase = .Load
			return false, .None
		}
		c := min(2048, gb.n - gb.cursor)
		for i in 0 ..< c {
			_gb_read_vec(m, gb.cursor + i, gb.chunk[i * gb.dim:][:gb.dim]) or_return
		}
		gb.chunk_lo = gb.cursor
		_run_workers(gb, .Encode, c)
		gb.cursor += c
		m.work += c * gb.dim * 16
		return false, .None
	case .Load:
		if gb.shard >= gb.k {
			gb.cursor = 0
			gb.phase = .Final
			return false, .None
		}
		_gb_load_shard(m) or_return
		if gb.sh.n == 0 {
			gb.shard += 1
			return false, .None
		}
		gb.pass = 0
		gb.cursor = 0
		gb.sh.alpha = 1.0
		gb.phase = .Build
		m.work += gb.sh.n * gb.dim
		return false, .None
	case .Build:
		sh := &gb.sh
		if gb.cursor >= sh.n {
			gb.pass += 1
			gb.cursor = 0
			sh.alpha = ALPHA
			if gb.pass == 2 {
				gb.phase = .Spill
			}
			return false, .None
		}
		c := min(STEP_NODES, sh.n - gb.cursor)
		_run_workers(gb, .Build, c)
		gb.cursor += c
		m.work += c * INSERT_WORK / gb.nthreads
		return false, .None
	case .Spill:
		_gb_spill(ix, m) or_return
		gb.shard += 1
		gb.phase = .Load
		return false, .None
	case .Final:
		return false, _gb_final(ix, m)
	case .Repair:
		return false, _gb_repair(ix, m)
	case .Codes:
		if gb.graph {
			left := gb.n * gb.m - gb.cursor
			c := min(left, 1 << 20)
			sw_write(&m.sw, gb.codes[gb.cursor:][:c])
			gb.cursor += c
			if gb.cursor < gb.n * gb.m {
				return false, m.sw.out.err
			}
		}
		gb.phase = .Done
		return false, .None
	case .Done:
		vmerge_destroy(ix, m)
		return true, .None
	}
	return false, .Invalid
}

@(private)
_gb_load_shard :: proc(m: ^Merge) -> Error {
	gb := m.gb
	sh := &gb.sh
	clear(&sh.ids)
	s := u16(gb.shard)
	for slot in 0 ..< 2 {
		for o in 0 ..< gb.n {
			if gb.assign[o][slot] == s {
				if slot == 1 && len(sh.ids) >= gb.cap_s {
					break
				}
				append(&sh.ids, u32(o))
			}
		}
	}
	slice.sort(sh.ids[:])
	n := len(sh.ids)
	sh.n = n
	if n == 0 {
		return .None
	}
	d := gb.dim
	resize(&sh.sq, n * d)
	resize(&sh.sqs, n)
	resize(&sh.adj, n * DEG_CAP)
	resize(&sh.deg, n)
	v := gb.workers[0].vec
	mean := make([]f32, d, context.temp_allocator)
	for i in 0 ..< n {
		_gb_read_vec(m, int(sh.ids[i]), v) or_return
		sh.sqs[i] = quantize(v, sh.sq[i * d:][:d])
		for j in 0 ..< d {
			mean[j] += v[j]
		}
	}
	mq := make([]i8, d, context.temp_allocator)
	quantize(mean, mq)
	best, bs := 0, min(i32)
	for i in 0 ..< n {
		x := dot_i8(mq, sh.sq[i * d:][:d])
		if x > bs {
			best, bs = i, x
		}
	}
	sh.entry = u32(best)
	r := Rng_State{u64(gb.shard) * 0x9E3779B97F4A7C15 + 17}
	k := min(INIT_DEGREE, n - 1)
	for i in 0 ..< n {
		base := i * DEG_CAP
		cnt := 0
		for cnt < k {
			x := u32(_rng(&r) % u64(n))
			if int(x) == i {
				continue
			}
			dup := false
			for t in 0 ..< cnt {
				if sh.adj[base + t] == x {
					dup = true
					break
				}
			}
			if !dup {
				sh.adj[base + cnt] = x
				cnt += 1
			}
		}
		sh.deg[i] = u8(cnt)
	}
	if n > gb.best {
		gb.best = n
		gb.medoid = sh.ids[best]
	}
	return .None
}

Rng_State :: struct {
	s: u64,
}

@(private)
_rng :: proc "contextless" (r: ^Rng_State) -> u64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(private)
_gb_spill :: proc(ix: ^Index, m: ^Merge) -> Error {
	gb := m.gb
	sh := &gb.sh
	if len(gb.out) < SHARD_REC * 256 {
		gb.out = make([]u8, SHARD_REC * 256, gb.alloc)
	}
	fill := 0
	for i in 0 ..< sh.n {
		o := sh.ids[i]
		r := gb.out[fill * SHARD_REC:][:SHARD_REC]
		slice.fill(r, 0)
		dg := min(int(sh.deg[i]), DEGREE)
		prim.put_u32le(r, o)
		prim.put_u32le(r[4:], u32(dg))
		for k in 0 ..< dg {
			prim.put_u32le(r[8 + 4 * k:], sh.ids[sh.adj[i * DEG_CAP + k]])
		}
		slot := 0 if gb.recidx[o][0] == NONE_U32 else 1
		gb.recidx[o][slot] = gb.tmp_n
		gb.tmp_n += 1
		fill += 1
		if fill == 256 || i == sh.n - 1 {
			at := i64(gb.tmp_n - u32(fill)) * SHARD_REC
			if e := prim.write_at(ix.vfs, gb.tmp_fd, gb.out[:fill * SHARD_REC], at); e != .None {
				return _perr(e)
			}
			fill = 0
		}
	}
	m.work += sh.n * SHARD_REC
	return .None
}

@(private)
_gb_neighbors :: proc(ix: ^Index, gb: ^Graph_Build, o: int, out: []u32) -> (n: int, err: Error) {
	lists: [2][DEGREE]u32
	cnt: [2]int
	ls := 0
	rb: [SHARD_REC]u8
	for slot in 0 ..< 2 {
		ri := gb.recidx[o][slot]
		if ri == NONE_U32 {
			continue
		}
		got, e := prim.read_at(ix.vfs, gb.tmp_fd, rb[:], i64(ri) * SHARD_REC)
		if e != .None {
			return 0, _perr(e)
		}
		if got != SHARD_REC || int(prim.get_u32le(rb[:])) != o {
			return 0, .Corrupt
		}
		dg := int(prim.get_u32le(rb[4:]))
		if dg > DEGREE {
			return 0, .Corrupt
		}
		for k in 0 ..< dg {
			lists[ls][k] = prim.get_u32le(rb[8 + 4 * k:])
		}
		cnt[ls] = dg
		ls += 1
	}
	i0, i1 := 0, 0
	turn := 0
	for n < DEGREE && (i0 < cnt[0] || i1 < cnt[1]) {
		x: u32
		if (turn == 0 && i0 < cnt[0]) || i1 >= cnt[1] {
			x = lists[0][i0]
			i0 += 1
		} else {
			x = lists[1][i1]
			i1 += 1
		}
		turn = 1 - turn
		if int(x) == o || int(x) >= gb.n {
			continue
		}
		dup := false
		for k in 0 ..< n {
			if out[k] == x {
				dup = true
				break
			}
		}
		if !dup {
			out[n] = x
			n += 1
		}
	}
	return n, .None
}

@(private)
_gb_final :: proc(ix: ^Index, m: ^Merge) -> Error {
	gb := m.gb
	if gb.cursor == 0 {
		if gb.graph {
			pad := (REC_ALIGN - int(sw_off(&m.sw) % REC_ALIGN)) % REC_ALIGN
			if pad > 0 {
				zeros: [REC_ALIGN]u8
				sw_write(&m.sw, zeros[:pad])
			}
		}
		m.sw.f.vdata_off = sw_off(&m.sw)
		m.sw.f.vrec = i64(gb.rec)
		gb.rbuf = make([]u8, gb.rec, gb.alloc)
		if gb.graph {
			gb.indeg = make([]u8, gb.n, gb.alloc)
		}
	}
	end := min(gb.cursor + 256, gb.n)
	rec := gb.rbuf
	nb: [DEGREE]u32
	for o in gb.cursor ..< end {
		slice.fill(rec, 0)
		if gb.graph {
			dg := _gb_neighbors(ix, gb, o, nb[:]) or_return
			prim.put_u32le(rec, u32(dg))
			v := slice.reinterpret([]f32, rec[4:][:gb.dim * 4])
			_gb_read_vec(m, o, v) or_return
			ids_at := 4 + gb.dim * 4
			codes_at := ids_at + DEGREE * 4
			for x in 0 ..< dg {
				if gb.indeg[nb[x]] < 255 {
					gb.indeg[nb[x]] += 1
				}
				prim.put_u32le(rec[ids_at + 4 * x:], nb[x])
				copy(rec[codes_at + x * gb.m:], gb.codes[int(nb[x]) * gb.m:][:gb.m])
			}
		} else {
			v := slice.reinterpret([]f32, rec[:gb.dim * 4])
			_gb_read_vec(m, o, v) or_return
		}
		sw_write(&m.sw, rec)
	}
	m.work += (end - gb.cursor) * gb.rec
	gb.cursor = end
	if gb.cursor < gb.n {
		return m.sw.out.err
	}
	m.sw.f.vcodes_off = sw_off(&m.sw)
	gb.cursor = 0
	if gb.graph {
		m.sw.f.vec_m = u64(gb.m)
		m.sw.f.cb_gen = gb.cb.gen
		m.sw.f.medoid = u64(gb.medoid)
		out_flush(&m.sw.out)
		gb.reach = make([]u64, (gb.n + 63) / 64, gb.alloc)
		gb.queue = make([dynamic]u32, 0, gb.n, gb.alloc)
		gb.reach[gb.medoid >> 6] |= u64(1) << (gb.medoid & 63)
		append(&gb.queue, gb.medoid)
		gb.fallback = gb.medoid
		gb.phase = .Repair
	} else {
		gb.phase = .Codes
	}
	return m.sw.out.err
}

@(private)
_gb_reached :: #force_inline proc "contextless" (gb: ^Graph_Build, x: u32) -> bool {
	return gb.reach[x >> 6] & (u64(1) << (x & 63)) != 0
}

@(private)
_gb_rec_read :: proc(m: ^Merge, x: u32, rec: []u8) -> Error {
	gb := m.gb
	got, e := prim.read_at(m.sw.out.vfs, m.sw.out.fd, rec, m.sw.f.vdata_off + i64(x) * i64(gb.rec))
	if e != .None {
		return _perr(e)
	}
	if got != len(rec) {
		return .Corrupt
	}
	return .None
}

@(private)
_gb_link :: proc(m: ^Merge, r: u32, u: u32, force: bool) -> (ok: bool, err: Error) {
	gb := m.gb
	rec := gb.rbuf
	_gb_rec_read(m, r, rec) or_return
	dg := int(prim.get_u32le(rec))
	if dg > DEGREE {
		return false, .Corrupt
	}
	ids_at := 4 + gb.dim * 4
	codes_at := ids_at + DEGREE * 4
	slot := dg
	if dg == DEGREE {
		slot = -1
		for k := DEGREE - 1; k >= 0; k -= 1 {
			x := prim.get_u32le(rec[ids_at + 4 * k:])
			if int(x) < gb.n && gb.indeg[x] >= 2 {
				slot = k
				break
			}
		}
		if slot < 0 {
			if !force {
				return false, .None
			}
			slot = DEGREE - 1
		}
		old := prim.get_u32le(rec[ids_at + 4 * slot:])
		if int(old) < gb.n && gb.indeg[old] > 0 && gb.indeg[old] < 255 {
			gb.indeg[old] -= 1
		}
	} else {
		prim.put_u32le(rec, u32(dg + 1))
	}
	if gb.indeg[u] < 255 {
		gb.indeg[u] += 1
	}
	prim.put_u32le(rec[ids_at + 4 * slot:], u)
	copy(rec[codes_at + slot * gb.m:], gb.codes[int(u) * gb.m:][:gb.m])
	if e := prim.write_at(m.sw.out.vfs, m.sw.out.fd, rec, m.sw.f.vdata_off + i64(r) * i64(gb.rec)); e != .None {
		return false, _perr(e)
	}
	return true, .None
}

@(private)
_gb_repair :: proc(ix: ^Index, m: ^Merge) -> Error {
	gb := m.gb
	rec := gb.rbuf
	ids_at := 4 + gb.dim * 4
	steps := 0
	for gb.qh < len(gb.queue) && steps < 4096 {
		x := gb.queue[gb.qh]
		gb.qh += 1
		steps += 1
		_gb_rec_read(m, x, rec) or_return
		dg := int(prim.get_u32le(rec))
		if dg > DEGREE {
			return .Corrupt
		}
		for k in 0 ..< dg {
			nb := prim.get_u32le(rec[ids_at + 4 * k:])
			if int(nb) >= gb.n {
				return .Corrupt
			}
			if !_gb_reached(gb, nb) {
				gb.reach[nb >> 6] |= u64(1) << (nb & 63)
				append(&gb.queue, nb)
			}
		}
	}
	m.work += steps * gb.rec
	if gb.qh < len(gb.queue) {
		return .None
	}
	for gb.cursor < gb.n {
		u := u32(gb.cursor)
		gb.cursor += 1
		if _gb_reached(gb, u) {
			continue
		}
		_gb_rec_read(m, u, rec) or_return
		dg := min(int(prim.get_u32le(rec)), DEGREE)
		cands: [DEGREE]u32
		nc := 0
		for k in 0 ..< dg {
			nb := prim.get_u32le(rec[ids_at + 4 * k:])
			if int(nb) < gb.n && _gb_reached(gb, nb) {
				cands[nc] = nb
				nc += 1
			}
		}
		linked := false
		for c in cands[:nc] {
			if _gb_link(m, c, u, false) or_return {
				linked = true
				break
			}
		}
		if !linked {
			_ = _gb_link(m, gb.fallback, u, true) or_return
			gb.fallback = u
		}
		gb.fixed += 1
		gb.reach[u >> 6] |= u64(1) << (u & 63)
		append(&gb.queue, u)
		m.work += INSERT_WORK
		return .None
	}
	if gb.fixed > 0 && gb.rounds < 8 {
		gb.rounds += 1
		gb.fixed = 0
		gb.cursor = 0
		slice.fill(gb.reach, 0)
		clear(&gb.queue)
		gb.qh = 0
		gb.reach[gb.medoid >> 6] |= u64(1) << (gb.medoid & 63)
		append(&gb.queue, gb.medoid)
		return .None
	}
	gb.cursor = 0
	gb.phase = .Codes
	return .None
}

package crdt

import "base:runtime"
import "core:slice"
import "../prim"

Graph_Entry :: struct {
	lv:        Lv,
	parents:   u32,
	n_parents: u32,
}

Assign :: struct {
	lv:      Lv,
	seq:     u64,
	lamport: u64,
	actor:   u32,
}

Seq_Run :: struct {
	seq: u64,
	lv:  Lv,
	len: int,
}

Walk_Span :: struct {
	lv:   Lv,
	len:  int,
	flag: u8,
}

FLAG_A :: u8(1)
FLAG_B :: u8(2)
FLAG_BOTH :: u8(3)

@(private)
Heap_Item :: struct {
	lv:   Lv,
	flag: u8,
}

Graph :: struct {
	allocator:   runtime.Allocator,
	actors:      [dynamic]prim.Id,
	actor_index: map[prim.Id]u32,
	seqs:        [dynamic][dynamic]Seq_Run,
	entries:     [dynamic]Graph_Entry,
	parent_pool: [dynamic]Lv,
	assign:      [dynamic]Assign,
	heads:       [dynamic]Lv,
	next:        Lv,
	heap:        [dynamic]Heap_Item,
	tmp:         [dynamic]Lv,
	walk:        [dynamic]Walk_Span,
	only_a:      [dynamic]Lv_Span,
	only_b:      [dynamic]Lv_Span,
	pieces:      [dynamic]Piece,
	last_actor:  prim.Id,
	last_ix:     u32,
	has_last:    bool,
}

graph_init :: proc(g: ^Graph, allocator := context.allocator) {
	g^ = {}
	g.allocator = allocator
	g.actors = make([dynamic]prim.Id, allocator)
	g.actor_index = make(map[prim.Id]u32, allocator)
	g.seqs = make([dynamic][dynamic]Seq_Run, allocator)
	g.entries = make([dynamic]Graph_Entry, allocator)
	g.parent_pool = make([dynamic]Lv, allocator)
	g.assign = make([dynamic]Assign, allocator)
	g.heads = make([dynamic]Lv, allocator)
	g.heap = make([dynamic]Heap_Item, allocator)
	g.tmp = make([dynamic]Lv, allocator)
	g.walk = make([dynamic]Walk_Span, allocator)
	g.only_a = make([dynamic]Lv_Span, allocator)
	g.only_b = make([dynamic]Lv_Span, allocator)
	g.pieces = make([dynamic]Piece, allocator)
}

graph_destroy :: proc(g: ^Graph) {
	for &s in g.seqs {
		delete(s)
	}
	delete(g.actors)
	delete(g.actor_index)
	delete(g.seqs)
	delete(g.entries)
	delete(g.parent_pool)
	delete(g.assign)
	delete(g.heads)
	delete(g.heap)
	delete(g.tmp)
	delete(g.walk)
	delete(g.only_a)
	delete(g.only_b)
	delete(g.pieces)
	g^ = {}
}

graph_actor :: proc(g: ^Graph, actor: prim.Id) -> (u32, bool) {
	if g.has_last && g.last_actor == actor {
		return g.last_ix, true
	}
	ix, ok := g.actor_index[actor]
	if ok {
		g.last_actor = actor
		g.last_ix = ix
		g.has_last = true
	}
	return ix, ok
}

graph_intern :: proc(g: ^Graph, actor: prim.Id) -> u32 {
	if ix, ok := graph_actor(g, actor); ok {
		return ix
	}
	ix := u32(len(g.actors))
	append(&g.actors, actor)
	append(&g.seqs, make([dynamic]Seq_Run, g.allocator))
	g.actor_index[actor] = ix
	return ix
}

graph_known :: proc(g: ^Graph, actor: prim.Id) -> u64 {
	ix, ok := graph_actor(g, actor)
	if !ok {
		return 0
	}
	return graph_known_ix(g, ix)
}

graph_known_ix :: proc "contextless" (g: ^Graph, ix: u32) -> u64 {
	runs := g.seqs[ix][:]
	if len(runs) == 0 {
		return 0
	}
	last := runs[len(runs) - 1]
	return last.seq + u64(last.len)
}

graph_lv :: proc(g: ^Graph, id: Op_Id) -> (Lv, bool) {
	ix, ok := graph_actor(g, id.actor)
	if !ok {
		return 0, false
	}
	return graph_lv_ix(g, ix, id.seq)
}

graph_lv_ix :: proc "contextless" (g: ^Graph, actor: u32, seq: u64) -> (Lv, bool) {
	runs := g.seqs[actor][:]
	if n := len(runs); n > 0 && runs[n - 1].seq <= seq {
		if seq < runs[n - 1].seq + u64(runs[n - 1].len) {
			return runs[n - 1].lv + int(seq - runs[n - 1].seq), true
		}
		return 0, false
	}
	lo, hi := 0, len(runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if runs[mid].seq + u64(runs[mid].len) <= seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(runs) && runs[lo].seq <= seq {
		return runs[lo].lv + int(seq - runs[lo].seq), true
	}
	return 0, false
}

@(private)
assign_index :: proc "contextless" (g: ^Graph, lv: Lv) -> int {
	a := g.assign[:]
	n := len(a)
	if n > 0 && a[n - 1].lv <= lv {
		return n - 1
	}
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if a[mid].lv <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

@(private)
entry_index :: proc "contextless" (g: ^Graph, lv: Lv) -> int {
	e := g.entries[:]
	n := len(e)
	if n > 0 && e[n - 1].lv <= lv {
		return n - 1
	}
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if e[mid].lv <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

graph_op :: proc "contextless" (g: ^Graph, lv: Lv) -> (actor: u32, seq: u64) {
	a := g.assign[assign_index(g, lv)]
	return a.actor, a.seq + u64(lv - a.lv)
}

graph_id :: proc "contextless" (g: ^Graph, lv: Lv) -> Op_Id {
	actor, seq := graph_op(g, lv)
	return Op_Id{g.actors[actor], seq}
}

graph_lamport :: proc "contextless" (g: ^Graph, lv: Lv) -> u64 {
	a := g.assign[assign_index(g, lv)]
	return a.lamport + u64(lv - a.lv)
}

graph_run_end :: proc "contextless" (g: ^Graph, lv: Lv) -> Lv {
	i := assign_index(g, lv)
	end := g.next
	if i + 1 < len(g.assign) {
		end = g.assign[i + 1].lv
	}
	e := entry_index(g, lv)
	if e + 1 < len(g.entries) {
		end = min(end, g.entries[e + 1].lv)
	}
	return end
}

graph_continues :: proc "contextless" (g: ^Graph, lv: Lv) -> bool {
	if lv <= 0 || lv >= g.next {
		return false
	}
	e := entry_index(g, lv)
	if g.entries[e].lv == lv {
		return false
	}
	return g.assign[assign_index(g, lv)].lv != lv
}

graph_parents :: proc "contextless" (g: ^Graph, lv: Lv, buf: ^[1]Lv) -> []Lv {
	e := g.entries[entry_index(g, lv)]
	if e.lv != lv {
		buf[0] = lv - 1
		return buf[:]
	}
	return g.parent_pool[e.parents:][:e.n_parents]
}

graph_add :: proc(g: ^Graph, b: ^Batch) -> (first: Lv, skip: int, err: Error) {
	n := 0
	for &op in b.ops {
		if op.len <= 0 || op.len > MAX_RUN || op.pos < -MAX_RUN || op.pos > MAX_POS {
			return 0, 0, .Invalid
		}
		if op.kind == .Insert && len(op.content) != op.len {
			return 0, 0, .Invalid
		}
		n += op.len
		if n > MAX_RUN {
			return 0, 0, .Invalid
		}
	}
	return graph_add_header(g, b.actor, b.seq, b.lamport, b.parents, n)
}

graph_valid :: proc "contextless" (g: ^Graph, v: []Lv) -> bool {
	for x in v {
		if x < 0 || x >= g.next {
			return false
		}
	}
	return true
}

graph_add_header :: proc(g: ^Graph, actor: prim.Id, seq: u64, lamport: u64, parents: []Op_Id, n: int) -> (first: Lv, skip: int, err: Error) {
	if n <= 0 || n > MAX_RUN || seq >= MAX_COUNTER - u64(n) || lamport == 0 || lamport >= MAX_COUNTER - u64(n) {
		return 0, 0, .Invalid
	}
	if g.next + n > MAX_LV {
		return 0, 0, .Too_Large
	}
	aix, have := graph_actor(g, actor)
	known := graph_known_ix(g, aix) if have else 0
	if seq + u64(n) <= known {
		lv, _ := graph_lv_ix(g, aix, seq)
		if graph_lamport(g, lv) != lamport {
			return 0, 0, .Mismatch
		}
		return lv + n, n, .None
	}
	if seq > known {
		return 0, 0, .Missing
	}
	ps := &g.tmp
	clear(ps)
	ts := lamport
	if seq < known {
		skip = int(known - seq)
		lv, _ := graph_lv_ix(g, aix, known - 1)
		if graph_lamport(g, lv) != lamport + u64(skip) - 1 {
			return 0, 0, .Mismatch
		}
		append(ps, lv)
		ts = lamport + u64(skip)
	} else {
		max_ts: u64
		for p in parents {
			lv, ok := graph_lv(g, p)
			if !ok {
				return 0, 0, .Missing
			}
			append(ps, lv)
			max_ts = max(max_ts, graph_lamport(g, lv))
		}
		if ts <= max_ts {
			return 0, 0, .Invalid
		}
		if len(ps) > 1 {
			slice.sort(ps[:])
			w := 0
			for i in 0 ..< len(ps) {
				if i == 0 || ps[i] != ps[w - 1] {
					ps[w] = ps[i]
					w += 1
				}
			}
			resize(ps, w)
			graph_reduce(g, ps)
		}
		if seq > 0 {
			prev, _ := graph_lv_ix(g, aix, seq - 1)
			if !graph_contains(g, ps[:], prev) {
				return 0, 0, .Invalid
			}
		}
	}
	first = g.next
	count := n - skip
	ix := graph_intern(g, actor)
	nseq := seq + u64(skip)
	if !(len(ps) == 1 && ps[0] == first - 1 && len(g.entries) > 0) {
		append(&g.entries, Graph_Entry{lv = first, parents = u32(len(g.parent_pool)), n_parents = u32(len(ps))})
		append(&g.parent_pool, ..ps[:])
	}
	extend := false
	if na := len(g.assign); na > 0 {
		last := g.assign[na - 1]
		l := Lv(first - last.lv)
		extend = last.actor == ix && last.seq + u64(l) == nseq && last.lamport + u64(l) == ts
	}
	if !extend {
		append(&g.assign, Assign{lv = first, seq = nseq, lamport = ts, actor = ix})
	}
	runs := &g.seqs[ix]
	if nr := len(runs); nr > 0 && runs[nr - 1].lv + runs[nr - 1].len == first && runs[nr - 1].seq + u64(runs[nr - 1].len) == nseq {
		runs[nr - 1].len += count
	} else {
		append(runs, Seq_Run{seq = nseq, lv = first, len = count})
	}
	frontier_advance(&g.heads, ps[:], first + count - 1)
	g.next = first + count
	return first, skip, .None
}

frontier_advance :: proc(f: ^[dynamic]Lv, parents: []Lv, last: Lv) {
	if len(f) == 1 && len(parents) == 1 && f[0] == parents[0] {
		f[0] = last
		return
	}
	w := 0
	for i in 0 ..< len(f) {
		v := f[i]
		drop := false
		for p in parents {
			if p == v {
				drop = true
				break
			}
		}
		if !drop {
			f[w] = v
			w += 1
		}
	}
	resize(f, w)
	append(f, last)
	slice.sort(f[:])
}

frontier_eq :: proc "contextless" (a, b: []Lv) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private)
heap_push :: proc(g: ^Graph, lv: Lv, flag: u8) {
	append(&g.heap, Heap_Item{lv, flag})
	h := g.heap[:]
	i := len(h) - 1
	for i > 0 {
		p := (i - 1) / 2
		if h[p].lv >= h[i].lv {
			break
		}
		h[p], h[i] = h[i], h[p]
		i = p
	}
}

@(private)
heap_pop :: proc(g: ^Graph) -> Heap_Item {
	h := g.heap[:]
	top := h[0]
	n := len(h) - 1
	h[0] = h[n]
	pop(&g.heap)
	h = h[:n]
	i := 0
	for {
		l := 2 * i + 1
		if l >= n {
			break
		}
		c := l
		if l + 1 < n && h[l + 1].lv > h[l].lv {
			c = l + 1
		}
		if h[i].lv >= h[c].lv {
			break
		}
		h[i], h[c] = h[c], h[i]
		i = c
	}
	return top
}

graph_contains :: proc(g: ^Graph, version: []Lv, lv: Lv) -> bool {
	if lv < 0 || lv >= g.next {
		return false
	}
	for v in version {
		if v == lv {
			return true
		}
	}
	clear(&g.heap)
	for v in version {
		if v >= lv {
			heap_push(g, v, 0)
		}
	}
	for len(g.heap) > 0 {
		v := heap_pop(g).lv
		if v == lv {
			return true
		}
		if v < lv {
			return false
		}
		e := g.entries[entry_index(g, v)]
		if e.lv <= lv {
			return true
		}
		for len(g.heap) > 0 && g.heap[0].lv >= e.lv {
			heap_pop(g)
		}
		for p in g.parent_pool[e.parents:][:e.n_parents] {
			if p >= lv {
				heap_push(g, p, 0)
			}
		}
	}
	return false
}

graph_contains_all :: proc(g: ^Graph, version: []Lv, lvs: []Lv) -> bool {
	for v in lvs {
		if !graph_contains(g, version, v) {
			return false
		}
	}
	return true
}

@(private)
graph_reduce :: proc(g: ^Graph, f: ^[dynamic]Lv) {
	if len(f) < 2 {
		return
	}
	keep := make([dynamic]Lv, 0, len(f), g.allocator)
	defer delete(keep)
	others := make([dynamic]Lv, 0, len(f), g.allocator)
	defer delete(others)
	for v, i in f {
		clear(&others)
		for u, j in f {
			if j != i {
				append(&others, u)
			}
		}
		if !graph_contains(g, others[:], v) {
			append(&keep, v)
		}
	}
	clear(f)
	append(f, ..keep[:])
}

version_union :: proc(g: ^Graph, a, b: []Lv, out: ^[dynamic]Lv) {
	clear(out)
	append(out, ..a)
	append(out, ..b)
	slice.sort(out[:])
	w := 0
	for i in 0 ..< len(out) {
		if i == 0 || out[i] != out[w - 1] {
			out[w] = out[i]
			w += 1
		}
	}
	resize(out, w)
	graph_reduce(g, out)
}

@(private)
heap_pop_merged :: proc(g: ^Graph, nonshared: ^int) -> (Lv, u8) {
	top := heap_pop(g)
	if top.flag != FLAG_BOTH {
		nonshared^ -= 1
	}
	f := top.flag
	for len(g.heap) > 0 && g.heap[0].lv == top.lv {
		x := heap_pop(g)
		if x.flag != FLAG_BOTH {
			nonshared^ -= 1
		}
		f |= x.flag
	}
	return top.lv, f
}

@(private)
walk_emit :: proc(out: ^[dynamic]Walk_Span, lv: Lv, n: int, flag: u8, shared: bool) {
	if n <= 0 || (flag == FLAG_BOTH && !shared) {
		return
	}
	if k := len(out); k > 0 && out[k - 1].flag == flag && out[k - 1].lv == lv + n {
		out[k - 1].lv = lv
		out[k - 1].len += n
		return
	}
	append(out, Walk_Span{lv, n, flag})
}

graph_walk :: proc(g: ^Graph, a, b: []Lv, out: ^[dynamic]Walk_Span, conflicting: bool, common: ^[dynamic]Lv) {
	clear(out)
	if common != nil {
		clear(common)
	}
	clear(&g.heap)
	nonshared := 0
	for v in a {
		heap_push(g, v, FLAG_A)
		nonshared += 1
	}
	for v in b {
		heap_push(g, v, FLAG_B)
		nonshared += 1
	}
	stop :: proc(conflicting: bool, f: u8, heap_len: int, nonshared: int) -> bool {
		if f != FLAG_BOTH {
			return false
		}
		return heap_len == 0 if conflicting else nonshared == 0
	}
	outer: for len(g.heap) > 0 {
		v, f := heap_pop_merged(g, &nonshared)
		if v < 0 {
			break
		}
		if stop(conflicting, f, len(g.heap), nonshared) {
			if conflicting && common != nil {
				append(common, v)
			}
			break
		}
		e := g.entries[entry_index(g, v)]
		hi := v
		for len(g.heap) > 0 && g.heap[0].lv >= e.lv {
			u, f2 := heap_pop_merged(g, &nonshared)
			walk_emit(out, u + 1, hi - u, f, conflicting)
			hi = u
			f |= f2
			if stop(conflicting, f, len(g.heap), nonshared) {
				if conflicting && common != nil {
					append(common, u)
				}
				break outer
			}
		}
		walk_emit(out, e.lv, hi - e.lv + 1, f, conflicting)
		if e.n_parents == 0 {
			heap_push(g, -1, f)
			if f != FLAG_BOTH {
				nonshared += 1
			}
		}
		for p in g.parent_pool[e.parents:][:e.n_parents] {
			heap_push(g, p, f)
			if f != FLAG_BOTH {
				nonshared += 1
			}
		}
	}
	slice.reverse(out[:])
}

graph_diff :: proc(g: ^Graph, a, b: []Lv, only_a, only_b: ^[dynamic]Lv_Span) {
	clear(only_a)
	clear(only_b)
	if len(a) <= 1 && len(b) <= 1 {
		x := a[0] if len(a) == 1 else -1
		y := b[0] if len(b) == 1 else -1
		if x == y {
			return
		}
		hi, lo := max(x, y), min(x, y)
		e := g.entries[entry_index(g, hi)]
		if e.lv <= lo || (lo < 0 && e.lv == 0) {
			append(only_b if y > x else only_a, Lv_Span{lo + 1, hi - lo})
			return
		}
	}
	graph_walk(g, a, b, &g.walk, false, nil)
	for s in g.walk {
		if s.flag == FLAG_A {
			append(only_a, Lv_Span{s.lv, s.len})
		} else if s.flag == FLAG_B {
			append(only_b, Lv_Span{s.lv, s.len})
		}
	}
}

graph_conflicting :: proc(g: ^Graph, a, b: []Lv, spans: ^[dynamic]Walk_Span, common: ^[dynamic]Lv) {
	graph_walk(g, a, b, spans, true, common)
}

graph_version_ids :: proc(g: ^Graph, v: []Lv, allocator := context.allocator) -> []Op_Id {
	out := make([]Op_Id, len(v), allocator)
	for x, i in v {
		out[i] = graph_id(g, x)
	}
	slice.sort_by(out, op_id_less)
	return out
}

graph_version_lvs :: proc(g: ^Graph, ids: []Op_Id, out: ^[dynamic]Lv) -> Error {
	clear(out)
	for id in ids {
		lv, ok := graph_lv(g, id)
		if !ok {
			return .Unknown
		}
		append(out, lv)
	}
	slice.sort(out[:])
	w := 0
	for i in 0 ..< len(out) {
		if i == 0 || out[i] != out[w - 1] {
			out[w] = out[i]
			w += 1
		}
	}
	resize(out, w)
	graph_reduce(g, out)
	return .None
}

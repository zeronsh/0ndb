package crdt

import "core:slice"

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
		if v >= lv && v < g.next {
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
		buf: [1]Lv
		start, ps := chain_parents(g, v, &buf)
		if start <= lv {
			return true
		}
		for len(g.heap) > 0 && g.heap[0].lv >= start {
			heap_pop(g)
		}
		for p in ps {
			if p >= lv && p < start {
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

@(private)
walk_stop :: #force_inline proc "contextless" (conflicting: bool, f: u8, heap_len: int, nonshared: int) -> bool {
	if f != FLAG_BOTH {
		return false
	}
	return heap_len == 0 if conflicting else nonshared == 0
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
	outer: for len(g.heap) > 0 {
		v, f := heap_pop_merged(g, &nonshared)
		if v < 0 {
			break
		}
		if walk_stop(conflicting, f, len(g.heap), nonshared) {
			if conflicting && common != nil {
				append(common, v)
			}
			break
		}
		buf: [1]Lv
		start, ps := chain_parents(g, v, &buf)
		hi := v
		for len(g.heap) > 0 && g.heap[0].lv >= start {
			u, f2 := heap_pop_merged(g, &nonshared)
			walk_emit(out, u + 1, hi - u, f, conflicting)
			hi = u
			f |= f2
			if walk_stop(conflicting, f, len(g.heap), nonshared) {
				if conflicting && common != nil {
					append(common, u)
				}
				break outer
			}
		}
		walk_emit(out, start, hi - start + 1, f, conflicting)
		pushed := 0
		for p in ps {
			if p >= 0 && p < start {
				heap_push(g, p, f)
				pushed += 1
			}
		}
		if pushed == 0 {
			heap_push(g, -1, f)
			pushed = 1
		}
		if f != FLAG_BOTH {
			nonshared += pushed
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
		chain := rec_at(g, hi).chain
		if chain <= lo || (lo < 0 && chain == 0) {
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

package crdt

RUN_CAP :: 32

Run_Leaf :: struct($E: typeid) {
	parent: u32,
	slot:   u8,
	n:      u8,
	items:  [RUN_CAP]E,
}

Span :: struct {
	len:   int,
	seq:   u64,
	actor: u32,
}

Ix :: struct {
	len:  int,
	leaf: u32,
}

Spans :: Tree(Run_Leaf(Span), 1)
Index :: Tree(Run_Leaf(Ix), 1)

@(private)
span_merge :: #force_inline proc "contextless" (a: ^Span, b: Span) -> bool {
	if a.actor == b.actor && a.seq + u64(a.len) == b.seq {
		a.len += b.len
		return true
	}
	return false
}

@(private)
span_split :: #force_inline proc "contextless" (e: Span, k: int) -> (Span, Span) {
	return Span{k, e.seq, e.actor}, Span{e.len - k, e.seq + u64(k), e.actor}
}

@(private)
ix_merge :: #force_inline proc "contextless" (a: ^Ix, b: Ix) -> bool {
	if a.leaf == b.leaf {
		a.len += b.len
		return true
	}
	return false
}

@(private)
ix_split :: #force_inline proc "contextless" (e: Ix, k: int) -> (Ix, Ix) {
	return Ix{k, e.leaf}, Ix{e.len - k, e.leaf}
}

@(private)
run_merge :: proc {
	span_merge,
	ix_merge,
}

@(private)
run_split :: proc {
	span_split,
	ix_split,
}

@(private)
run_leaf_split :: proc(t: ^Tree(Run_Leaf($E), 1), leaf: u32) {
	id := tree_new_leaf(t)
	l := &t.leaves[leaf]
	r := &t.leaves[id]
	h := int(l.n) / 2
	moved := 0
	for i in h ..< int(l.n) {
		r.items[i - h] = l.items[i]
		moved += l.items[i].len
	}
	r.n = l.n - u8(h)
	l.n = u8(h)
	tree_add(t, leaf, {-moved})
	tree_insert_after(t, leaf, true, id, {moved})
}

run_insert :: proc(t: ^Tree(Run_Leaf($E), 1), pos: int, e: E) {
	if e.len <= 0 {
		return
	}
	at := clamp(pos, 0, t.total[0])
	for {
		leaf, off := tree_find(t, 0, at, true)
		l := &t.leaves[leaf]
		n := int(l.n)
		i := 0
		for i < n && off > l.items[i].len {
			off -= l.items[i].len
			i += 1
		}
		if i < n && off == l.items[i].len {
			if run_merge(&l.items[i], e) {
				tree_add(t, leaf, {e.len})
				return
			}
			if i + 1 < n {
				x := e
				if run_merge(&x, l.items[i + 1]) {
					l.items[i + 1] = x
					tree_add(t, leaf, {e.len})
					return
				}
			}
			i += 1
			off = 0
		} else if i < n && off == 0 {
			x := e
			if run_merge(&x, l.items[i]) {
				l.items[i] = x
				tree_add(t, leaf, {e.len})
				return
			}
		}
		need := 1 if off == 0 else 2
		if n + need > RUN_CAP {
			run_leaf_split(t, leaf)
			continue
		}
		if off == 0 {
			copy(l.items[i + 1:n + 1], l.items[i:n])
			l.items[i] = e
			l.n += 1
		} else {
			a, b := run_split(l.items[i], off)
			copy(l.items[i + 3:n + 2], l.items[i + 1:n])
			l.items[i] = a
			l.items[i + 1] = e
			l.items[i + 2] = b
			l.n += 2
		}
		tree_add(t, leaf, {e.len})
		return
	}
}

run_delete :: proc(t: ^Tree(Run_Leaf($E), 1), pos: int, count: int) {
	at := clamp(pos, 0, t.total[0])
	rem := min(max(count, 0), t.total[0] - at)
	for rem > 0 {
		leaf, off := tree_find(t, 0, at, false)
		l := &t.leaves[leaf]
		n := int(l.n)
		i := 0
		for i < n && off >= l.items[i].len {
			off -= l.items[i].len
			i += 1
		}
		if i >= n {
			break
		}
		it := l.items[i]
		k := min(rem, it.len - off)
		if off == 0 && k == it.len {
			copy(l.items[i:n - 1], l.items[i + 1:n])
			l.n -= 1
		} else if off == 0 {
			_, b := run_split(it, k)
			l.items[i] = b
		} else if off + k == it.len {
			a, _ := run_split(it, off)
			l.items[i] = a
		} else {
			if n + 1 > RUN_CAP {
				run_leaf_split(t, leaf)
				continue
			}
			a, _ := run_split(it, off)
			_, b := run_split(it, off + k)
			copy(l.items[i + 2:n + 1], l.items[i + 1:n])
			l.items[i] = a
			l.items[i + 1] = b
			l.n += 1
		}
		tree_add(t, leaf, {-k})
		rem -= k
		if l.n == 0 && t.height > 0 {
			tree_remove(t, leaf, true)
		}
	}
	run_join(t, at)
}

@(private)
run_join :: proc(t: ^Tree(Run_Leaf($E), 1), at: int) {
	if at <= 0 || at >= t.total[0] {
		return
	}
	leaf, off := tree_find(t, 0, at, true)
	l := &t.leaves[leaf]
	n := int(l.n)
	i := 0
	for i < n && off > l.items[i].len {
		off -= l.items[i].len
		i += 1
	}
	if i + 1 < n && off == l.items[i].len {
		if run_merge(&l.items[i], l.items[i + 1]) {
			copy(l.items[i + 1:n - 1], l.items[i + 2:n])
			l.n -= 1
		}
	}
}

run_get :: proc(t: ^Tree(Run_Leaf($E), 1), pos: int) -> (e: E, off: int, ok: bool) {
	if pos < 0 || pos >= t.total[0] {
		return
	}
	leaf, o := tree_find(t, 0, pos, false)
	l := &t.leaves[leaf]
	for i in 0 ..< int(l.n) {
		if o < l.items[i].len {
			return l.items[i], o, true
		}
		o -= l.items[i].len
	}
	return
}

run_assign :: proc(t: ^Tree(Run_Leaf($E), 1), pos: int, e: E) {
	run_delete(t, pos, e.len)
	run_insert(t, pos, e)
}

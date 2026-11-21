package crdt

import "base:runtime"

ROPE_CAP :: 1016

Rope_Leaf :: struct {
	parent: u32,
	slot:   u8,
	len:    u16,
	data:   [ROPE_CAP]u8,
}

Rope :: Tree(Rope_Leaf, 2, int)

units :: proc "contextless" (b: []u8) -> int {
	n := 0
	for x in b {
		if x & 0xC0 != 0x80 {
			n += 2 if x >= 0xF0 else 1
		}
	}
	return n
}

rope_init :: proc(r: ^Rope, allocator: runtime.Allocator) {
	tree_init(r, allocator)
}

rope_len :: #force_inline proc "contextless" (r: ^Rope) -> int {
	return r.total[0]
}

@(private = "file")
rope_pull :: proc "contextless" (src: ^[3][]u8, dst: []u8) {
	n := 0
	for i in 0 ..< 3 {
		if n == len(dst) {
			return
		}
		c := copy(dst[n:], src[i])
		src[i] = src[i][c:]
		n += c
	}
}

rope_insert :: proc(r: ^Rope, pos: int, data: []u8) {
	if len(data) == 0 {
		return
	}
	at := clamp(pos, 0, r.total[0])
	leaf, off := tree_find(r, 0, at, true)
	l := &r.leaves[leaf]
	cur := int(l.len)
	if cur + len(data) <= ROPE_CAP {
		copy(l.data[off + len(data):cur + len(data)], l.data[off:cur])
		copy(l.data[off:], data)
		l.len = u16(cur + len(data))
		tree_add(r, leaf, {len(data), units(data)})
		return
	}
	tail_buf: [ROPE_CAP]u8
	head_buf: [ROPE_CAP]u8
	tail_n := copy(tail_buf[:], l.data[off:cur])
	total := cur + len(data)
	k := (total + ROPE_CAP - 1) / ROPE_CAP
	base := total / k
	extra := total % k
	first := base + (1 if extra > 0 else 0)
	keep := min(first, off)
	head_n := 0
	if keep < off {
		head_n = copy(head_buf[:], l.data[keep:off])
	}
	src := [3][]u8{head_buf[:head_n], data, tail_buf[:tail_n]}
	old_units := units(l.data[:cur])
	rope_pull(&src, l.data[keep:first])
	l.len = u16(first)
	tree_add(r, leaf, {first - cur, units(l.data[:first]) - old_units})
	prev := leaf
	for i in 1 ..< k {
		sz := base + (1 if i < extra else 0)
		id := tree_new_leaf(r)
		nl := &r.leaves[id]
		rope_pull(&src, nl.data[:sz])
		nl.len = u16(sz)
		tree_insert_after(r, prev, true, id, {sz, units(nl.data[:sz])})
		prev = id
	}
}

rope_delete :: proc(r: ^Rope, pos: int, n: int) {
	at := clamp(pos, 0, r.total[0])
	rem := min(max(n, 0), r.total[0] - at)
	for rem > 0 {
		leaf, off := tree_find(r, 0, at, false)
		l := &r.leaves[leaf]
		cur := int(l.len)
		k := min(rem, cur - off)
		if k <= 0 {
			break
		}
		gone := units(l.data[off:off + k])
		copy(l.data[off:cur - k], l.data[off + k:cur])
		l.len = u16(cur - k)
		tree_add(r, leaf, {-k, -gone})
		rem -= k
		if l.len == 0 && r.height > 0 {
			tree_remove(r, leaf, true)
		}
	}
	rope_compact(r, at)
}

@(private = "file")
rope_compact :: proc(r: ^Rope, at: int) {
	if r.height == 0 {
		return
	}
	leaf, _ := tree_find(r, 0, at, true)
	if int(r.leaves[leaf].len) >= ROPE_CAP / 2 {
		return
	}
	next := tree_next_leaf(r, leaf)
	if next == NIL || int(r.leaves[leaf].len) + int(r.leaves[next].len) > ROPE_CAP {
		prev := tree_prev_leaf(r, leaf)
		if prev == NIL || int(r.leaves[leaf].len) + int(r.leaves[prev].len) > ROPE_CAP {
			return
		}
		next = leaf
		leaf = prev
	}
	a := &r.leaves[leaf]
	b := &r.leaves[next]
	n := int(b.len)
	u := units(b.data[:n])
	copy(a.data[a.len:], b.data[:n])
	a.len += u16(n)
	b.len = 0
	tree_add(r, leaf, {n, u})
	tree_add(r, next, {-n, -u})
	tree_remove(r, next, true)
}

rope_read :: proc(r: ^Rope, pos: int, dst: []u8) -> int {
	if pos < 0 || pos >= r.total[0] {
		return 0
	}
	leaf, off := tree_find(r, 0, pos, false)
	n := 0
	for leaf != NIL && n < len(dst) {
		l := &r.leaves[leaf]
		n += copy(dst[n:], l.data[off:l.len])
		off = 0
		leaf = tree_next_leaf(r, leaf)
	}
	return n
}

rope_append :: proc(r: ^Rope, data: []u8) {
	rest := data
	for len(rest) > 0 {
		leaf := tree_last_leaf(r)
		l := &r.leaves[leaf]
		room := ROPE_CAP - int(l.len)
		if room > 0 {
			c := copy(l.data[l.len:], rest)
			l.len += u16(c)
			tree_add(r, leaf, {c, units(rest[:c])})
			rest = rest[c:]
			continue
		}
		id := tree_new_leaf(r)
		c := copy(r.leaves[id].data[:], rest)
		r.leaves[id].len = u16(c)
		tree_insert_after(r, leaf, true, id, {c, units(rest[:c])})
		rest = rest[c:]
	}
}

rope_fill :: proc(r: ^Rope, pos: int, n: int, b: u8) {
	at := clamp(pos, 0, r.total[0])
	rem := min(max(n, 0), r.total[0] - at)
	for rem > 0 {
		leaf, off := tree_find(r, 0, at, false)
		l := &r.leaves[leaf]
		k := min(rem, int(l.len) - off)
		if k <= 0 {
			return
		}
		before := units(l.data[off:][:k])
		for &x in l.data[off:][:k] {
			x = b
		}
		tree_add(r, leaf, {0, units(l.data[off:][:k]) - before})
		at += k
		rem -= k
	}
}

rope_units :: #force_inline proc "contextless" (r: ^Rope) -> int {
	return r.total[1]
}

rope_units_at :: proc(r: ^Rope, pos: int) -> int {
	at := clamp(pos, 0, r.total[0])
	if at == r.total[0] {
		return r.total[1]
	}
	leaf, off := tree_find(r, 0, at, false)
	return tree_leaf_pos(r, leaf)[1] + units(r.leaves[leaf].data[:off])
}

rope_byte_at :: proc(r: ^Rope, u: int) -> int {
	at := clamp(u, 0, r.total[1])
	if at == r.total[1] {
		return r.total[0]
	}
	leaf, off := tree_find(r, 1, at, false)
	base := tree_leaf_pos(r, leaf)[0]
	l := &r.leaves[leaf]
	n := 0
	i := 0
	for i < int(l.len) {
		x := l.data[i]
		w := 0 if x & 0xC0 == 0x80 else (2 if x >= 0xF0 else 1)
		if w > 0 && n + w > off {
			break
		}
		n += w
		i += 1
	}
	return base + i
}

package crdt

import "base:runtime"

NIL :: max(u32)
FANOUT :: 16

Node :: struct($M: int) {
	parent: u32,
	slot:   u8,
	n:      u8,
	child:  [FANOUT]u32,
	size:   [FANOUT][M]int,
}

Tree :: struct($L: typeid, $M: int) {
	leaves:      [dynamic]L,
	nodes:       [dynamic]Node(M),
	free_leaves: [dynamic]u32,
	free_nodes:  [dynamic]u32,
	root:        u32,
	height:      int,
	total:       [M]int,
	cache_leaf:  u32,
	cache_start: [M]int,
}

tree_init :: proc(t: ^Tree($L, $M), allocator: runtime.Allocator) {
	t^ = {}
	t.leaves = make([dynamic]L, allocator)
	t.nodes = make([dynamic]Node(M), allocator)
	t.free_leaves = make([dynamic]u32, allocator)
	t.free_nodes = make([dynamic]u32, allocator)
	t.root = tree_new_leaf(t)
	t.cache_leaf = NIL
}

tree_destroy :: proc(t: ^Tree($L, $M)) {
	delete(t.leaves)
	delete(t.nodes)
	delete(t.free_leaves)
	delete(t.free_nodes)
	t^ = {}
}

tree_clone :: proc(dst: ^Tree($L, $M), src: ^Tree(L, M), allocator: runtime.Allocator) {
	dst^ = src^
	dst.leaves = make([dynamic]L, len(src.leaves), allocator)
	copy(dst.leaves[:], src.leaves[:])
	dst.nodes = make([dynamic]Node(M), len(src.nodes), allocator)
	copy(dst.nodes[:], src.nodes[:])
	dst.free_leaves = make([dynamic]u32, len(src.free_leaves), allocator)
	copy(dst.free_leaves[:], src.free_leaves[:])
	dst.free_nodes = make([dynamic]u32, len(src.free_nodes), allocator)
	copy(dst.free_nodes[:], src.free_nodes[:])
}

tree_new_leaf :: proc(t: ^Tree($L, $M)) -> u32 {
	if n := len(t.free_leaves); n > 0 {
		id := t.free_leaves[n - 1]
		pop(&t.free_leaves)
		t.leaves[id] = {}
		t.leaves[id].parent = NIL
		return id
	}
	append(&t.leaves, L{parent = NIL})
	return u32(len(t.leaves) - 1)
}

tree_new_node :: proc(t: ^Tree($L, $M)) -> u32 {
	if n := len(t.free_nodes); n > 0 {
		id := t.free_nodes[n - 1]
		pop(&t.free_nodes)
		t.nodes[id] = {}
		t.nodes[id].parent = NIL
		return id
	}
	append(&t.nodes, Node(M){parent = NIL})
	return u32(len(t.nodes) - 1)
}

tree_parent :: #force_inline proc "contextless" (t: ^Tree($L, $M), id: u32, leaf: bool) -> (u32, int) {
	if leaf {
		return t.leaves[id].parent, int(t.leaves[id].slot)
	}
	return t.nodes[id].parent, int(t.nodes[id].slot)
}

tree_set_parent :: #force_inline proc "contextless" (t: ^Tree($L, $M), id: u32, leaf: bool, p: u32, s: int) {
	if leaf {
		t.leaves[id].parent = p
		t.leaves[id].slot = u8(s)
	} else {
		t.nodes[id].parent = p
		t.nodes[id].slot = u8(s)
	}
}

tree_bubble :: proc "contextless" (t: ^Tree($L, $M), parent: u32, slot: int, d: [M]int) {
	p, s := parent, slot
	for p != NIL {
		n := &t.nodes[p]
		n.size[s] += d
		s = int(n.slot)
		p = n.parent
	}
	t.total += d
}

tree_add :: proc "contextless" (t: ^Tree($L, $M), leaf: u32, d: [M]int) {
	if leaf != t.cache_leaf {
		t.cache_leaf = NIL
	}
	p, s := tree_parent(t, leaf, true)
	tree_bubble(t, p, s, d)
}

tree_leaf_size :: #force_inline proc "contextless" (t: ^Tree($L, $M), leaf: u32) -> [M]int {
	p, s := tree_parent(t, leaf, true)
	if p == NIL {
		return t.total
	}
	return t.nodes[p].size[s]
}

tree_find :: proc "contextless" (t: ^Tree($L, $M), m: int, pos: int, left: bool) -> (leaf: u32, off: int) {
	if c := t.cache_leaf; c != NIL {
		st := t.cache_start[m]
		end := st + tree_leaf_size(t, c)[m]
		if pos >= st && (left ? pos <= end : pos < end) {
			return c, pos - st
		}
	}
	id := t.root
	off = pos
	acc: [M]int
	for h := t.height; h > 0; h -= 1 {
		node := &t.nodes[id]
		last := int(node.n) - 1
		i := 0
		for ; i < last; i += 1 {
			s := node.size[i][m]
			if left ? off <= s : off < s {
				break
			}
			off -= s
			acc += node.size[i]
		}
		id = node.child[i]
	}
	t.cache_leaf = id
	t.cache_start = acc
	return id, off
}

tree_first_leaf :: proc "contextless" (t: ^Tree($L, $M)) -> u32 {
	id := t.root
	for _ in 0 ..< t.height {
		id = t.nodes[id].child[0]
	}
	return id
}

tree_last_leaf :: proc "contextless" (t: ^Tree($L, $M)) -> u32 {
	id := t.root
	for _ in 0 ..< t.height {
		id = t.nodes[id].child[t.nodes[id].n - 1]
	}
	return id
}

tree_next_leaf :: proc "contextless" (t: ^Tree($L, $M), leaf: u32) -> u32 {
	p, s := tree_parent(t, leaf, true)
	up := 0
	for p != NIL && s + 1 >= int(t.nodes[p].n) {
		s = int(t.nodes[p].slot)
		p = t.nodes[p].parent
		up += 1
	}
	if p == NIL {
		return NIL
	}
	id := t.nodes[p].child[s + 1]
	for _ in 0 ..< up {
		id = t.nodes[id].child[0]
	}
	return id
}

tree_prev_leaf :: proc "contextless" (t: ^Tree($L, $M), leaf: u32) -> u32 {
	p, s := tree_parent(t, leaf, true)
	up := 0
	for p != NIL && s == 0 {
		s = int(t.nodes[p].slot)
		p = t.nodes[p].parent
		up += 1
	}
	if p == NIL {
		return NIL
	}
	id := t.nodes[p].child[s - 1]
	for _ in 0 ..< up {
		id = t.nodes[id].child[t.nodes[id].n - 1]
	}
	return id
}

tree_leaf_pos :: proc "contextless" (t: ^Tree($L, $M), leaf: u32) -> (acc: [M]int) {
	p, s := tree_parent(t, leaf, true)
	for p != NIL {
		n := &t.nodes[p]
		for i in 0 ..< s {
			acc += n.size[i]
		}
		s = int(n.slot)
		p = n.parent
	}
	return
}

tree_insert_after :: proc(t: ^Tree($L, $M), sib: u32, leaf: bool, id: u32, size: [M]int) {
	t.cache_leaf = NIL
	parent, slot := tree_parent(t, sib, leaf)
	if parent == NIL {
		r := tree_new_node(t)
		node := &t.nodes[r]
		node.n = 2
		node.child[0] = sib
		node.child[1] = id
		node.size[0] = t.total
		node.size[1] = size
		tree_set_parent(t, sib, leaf, r, 0)
		tree_set_parent(t, id, leaf, r, 1)
		t.root = r
		t.height += 1
		t.total += size
		return
	}
	at := slot + 1
	if int(t.nodes[parent].n) < FANOUT {
		node := &t.nodes[parent]
		n := int(node.n)
		for i := n; i > at; i -= 1 {
			node.child[i] = node.child[i - 1]
			node.size[i] = node.size[i - 1]
			tree_set_parent(t, node.child[i], leaf, parent, i)
		}
		node.child[at] = id
		node.size[at] = size
		node.n += 1
		tree_set_parent(t, id, leaf, parent, at)
		tree_bubble(t, node.parent, int(node.slot), size)
		return
	}
	kids: [FANOUT + 1]u32
	sizes: [FANOUT + 1][M]int
	src := &t.nodes[parent]
	j := 0
	for i in 0 ..< FANOUT {
		if i == at {
			kids[j] = id
			sizes[j] = size
			j += 1
		}
		kids[j] = src.child[i]
		sizes[j] = src.size[i]
		j += 1
	}
	if at == FANOUT {
		kids[j] = id
		sizes[j] = size
	}
	right := tree_new_node(t)
	half := (FANOUT + 1) / 2
	sum_left, sum_right: [M]int
	ln := &t.nodes[parent]
	ln.n = u8(half)
	for i in 0 ..< half {
		ln.child[i] = kids[i]
		ln.size[i] = sizes[i]
		sum_left += sizes[i]
		tree_set_parent(t, kids[i], leaf, parent, i)
	}
	for i in half ..< FANOUT {
		ln.child[i] = 0
		ln.size[i] = {}
	}
	rn := &t.nodes[right]
	rn.n = u8(FANOUT + 1 - half)
	for i in half ..< FANOUT + 1 {
		rn.child[i - half] = kids[i]
		rn.size[i - half] = sizes[i]
		sum_right += sizes[i]
		tree_set_parent(t, kids[i], leaf, right, i - half)
	}
	gp := t.nodes[parent].parent
	if gp == NIL {
		r := tree_new_node(t)
		node := &t.nodes[r]
		node.n = 2
		node.child[0] = parent
		node.child[1] = right
		node.size[0] = sum_left
		node.size[1] = sum_right
		tree_set_parent(t, parent, false, r, 0)
		tree_set_parent(t, right, false, r, 1)
		t.root = r
		t.height += 1
		t.total += size
		return
	}
	gs := int(t.nodes[parent].slot)
	d := sum_left - t.nodes[gp].size[gs]
	t.nodes[gp].size[gs] = sum_left
	tree_bubble(t, t.nodes[gp].parent, int(t.nodes[gp].slot), d)
	tree_insert_after(t, parent, false, right, sum_right)
}

tree_remove :: proc(t: ^Tree($L, $M), id: u32, leaf: bool) {
	t.cache_leaf = NIL
	parent, slot := tree_parent(t, id, leaf)
	if parent == NIL {
		return
	}
	node := &t.nodes[parent]
	n := int(node.n)
	for i in slot ..< n - 1 {
		node.child[i] = node.child[i + 1]
		node.size[i] = node.size[i + 1]
		tree_set_parent(t, node.child[i], leaf, parent, i)
	}
	node.child[n - 1] = 0
	node.size[n - 1] = {}
	node.n -= 1
	if leaf {
		append(&t.free_leaves, id)
	} else {
		append(&t.free_nodes, id)
	}
	if t.nodes[parent].n == 0 {
		tree_remove(t, parent, false)
		return
	}
	if parent == t.root && t.nodes[parent].n == 1 {
		child := t.nodes[parent].child[0]
		tree_set_parent(t, child, t.height == 1, NIL, 0)
		t.root = child
		t.height -= 1
		append(&t.free_nodes, parent)
	}
}

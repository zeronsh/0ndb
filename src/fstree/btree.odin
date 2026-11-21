package fstree

DEFAULT_FANOUT :: 64

@(private)
MAX_HEIGHT :: 32

Key :: struct {
	name:  string,
	event: Event,
	inode: Inode_Id,
	low:   bool,
}

Item :: struct {
	key:   Key,
	entry: Entry,
}

@(private)
Path :: struct {
	ids:   [MAX_HEIGHT]u64,
	idx:   [MAX_HEIGHT]int,
	depth: int,
}

Iter :: struct {
	tree:  ^Tree,
	dir:   Inode_Id,
	path:  Path,
	leaf:  ^Node,
	pos:   int,
	done:  bool,
}

entry_name :: proc "contextless" (n: ^Node, e: Entry) -> string {
	return string(n.arena[e.name_off:][:e.name_len])
}

@(private)
sep_name :: proc "contextless" (n: ^Node, s: Sep) -> string {
	return string(n.arena[s.name_off:][:s.name_len])
}

@(private)
entry_key :: proc "contextless" (n: ^Node, i: int) -> Key {
	e := n.entries[i]
	return Key{name = entry_name(n, e), event = e.event, inode = e.inode}
}

@(private)
sep_key :: proc "contextless" (n: ^Node, i: int) -> Key {
	s := n.seps[i]
	return Key{name = sep_name(n, s), event = s.event, inode = s.inode}
}

key_cmp :: proc(t: ^Tree, a, b: Key) -> int {
	if a.name != b.name {
		return -1 if a.name < b.name else 1
	}
	if a.low || b.low {
		if a.low == b.low {
			return 0
		}
		return -1 if a.low else 1
	}
	if c := event_cmp(t, a.event, b.event); c != 0 {
		return c
	}
	return id_cmp(a.inode, b.inode)
}

@(private)
node_size :: proc "contextless" (n: ^Node) -> int {
	return len(n.entries) if n.leaf else len(n.kids)
}

@(private)
node_max :: proc "contextless" (t: ^Tree) -> int {
	return t.fanout
}

@(private)
child_index :: proc(t: ^Tree, n: ^Node, key: Key) -> int {
	lo, hi := 0, len(n.seps)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if key_cmp(t, sep_key(n, mid), key) <= 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
leaf_bound :: proc(t: ^Tree, n: ^Node, key: Key, strict: bool) -> int {
	lo, hi := 0, len(n.entries)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		c := key_cmp(t, entry_key(n, mid), key)
		if c < 0 || (strict && c == 0) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
valid_inner :: proc "contextless" (n: ^Node) -> bool {
	return len(n.kids) > 0 && len(n.seps) == len(n.kids) - 1
}

@(private)
descend :: proc(t: ^Tree, dir: Inode_Id, key: Key, leftmost := false) -> (path: Path, err: Error) {
	id: u64 = 0
	for level in 0 ..< MAX_HEIGHT {
		n := node_get(t, Node_Key{dir, id}) or_return
		path.ids[level] = id
		path.depth = level
		if n.leaf {
			return path, nil
		}
		if !valid_inner(n) {
			return path, .Corrupt
		}
		i := 0 if leftmost else child_index(t, n, key)
		path.idx[level] = i
		id = n.kids[i]
	}
	return path, .Corrupt
}

@(private)
leaf_put :: proc(n: ^Node, pos: int, name: string, e: Entry) -> Error {
	c := e
	c.name_off = u32(len(n.arena))
	c.name_len = u32(len(name))
	append(&n.arena, name) or_return
	inject_at(&n.entries, pos, c) or_return
	return nil
}

@(private)
sep_put :: proc(n: ^Node, pos: int, key: Key) -> Error {
	s := Sep {
		inode    = key.inode,
		event    = key.event,
		name_off = u32(len(n.arena)),
		name_len = u32(len(key.name)),
	}
	append(&n.arena, key.name) or_return
	inject_at(&n.seps, pos, s) or_return
	return nil
}

@(private)
btree_find :: proc(t: ^Tree, dir: Inode_Id, key: Key) -> (entry: Entry, found: bool, err: Error) {
	path := descend(t, dir, key) or_return
	leaf := node_get(t, Node_Key{dir, path.ids[path.depth]}) or_return
	pos := leaf_bound(t, leaf, key, false)
	if pos < len(leaf.entries) && key_cmp(t, entry_key(leaf, pos), key) == 0 {
		return leaf.entries[pos], true, nil
	}
	return
}

@(private)
btree_insert :: proc(t: ^Tree, dir: Inode_Id, key: Key, e: Entry) -> Error {
	path := descend(t, dir, key) or_return
	leaf := node_edit(t, Node_Key{dir, path.ids[path.depth]}) or_return
	pos := leaf_bound(t, leaf, key, false)
	if pos < len(leaf.entries) && key_cmp(t, entry_key(leaf, pos), key) == 0 {
		return .Corrupt
	}
	leaf_put(leaf, pos, key.name, e) or_return
	for level := path.depth; level >= 0; level -= 1 {
		n := node_edit(t, Node_Key{dir, path.ids[level]}) or_return
		if node_size(n) <= node_max(t) {
			return nil
		}
		if level == 0 {
			return split_root(t, dir, n)
		}
		rid, right := node_new(t, dir, n.leaf) or_return
		sep := split_into(n, right) or_return
		parent := node_edit(t, Node_Key{dir, path.ids[level - 1]}) or_return
		at := path.idx[level - 1]
		sep_put(parent, at, sep) or_return
		inject_at(&parent.kids, at + 1, rid) or_return
	}
	return nil
}

@(private)
copy_entries :: proc(dst: ^Node, src: ^Node, from, to: int) -> Error {
	for i in from ..< to {
		leaf_put(dst, len(dst.entries), entry_name(src, src.entries[i]), src.entries[i]) or_return
	}
	return nil
}

@(private)
copy_inner :: proc(dst: ^Node, src: ^Node, kid_from, kid_to: int) -> Error {
	for i in kid_from ..< kid_to {
		if i > kid_from {
			sep_put(dst, len(dst.seps), sep_key(src, i - 1)) or_return
		}
		append(&dst.kids, src.kids[i]) or_return
	}
	return nil
}

@(private)
split_into :: proc(n: ^Node, right: ^Node) -> (sep: Key, err: Error) {
	if n.leaf {
		half := len(n.entries) / 2
		copy_entries(right, n, half, len(n.entries)) or_return
		resize(&n.entries, half) or_return
		return entry_key(right, 0), nil
	}
	half := len(n.kids) / 2
	copy_inner(right, n, half, len(n.kids)) or_return
	sep = sep_key(n, half - 1)
	resize(&n.seps, half - 1) or_return
	resize(&n.kids, half) or_return
	return sep, nil
}

@(private)
split_root :: proc(t: ^Tree, dir: Inode_Id, root: ^Node) -> Error {
	lid, left := node_new(t, dir, root.leaf) or_return
	rid, right := node_new(t, dir, root.leaf) or_return
	sep: Key
	if root.leaf {
		half := len(root.entries) / 2
		copy_entries(left, root, 0, half) or_return
		copy_entries(right, root, half, len(root.entries)) or_return
		sep = entry_key(right, 0)
	} else {
		half := len(root.kids) / 2
		copy_inner(left, root, 0, half) or_return
		copy_inner(right, root, half, len(root.kids)) or_return
		sep = sep_key(root, half - 1)
	}
	arena := make([dynamic]u8, 0, len(sep.name) + MAX_NAME, t.allocator) or_return
	append(&arena, sep.name) or_return
	sep.name = string(arena[:len(sep.name)])
	delete(root.arena)
	root.arena = arena
	clear(&root.entries)
	clear(&root.seps)
	clear(&root.kids)
	root.leaf = false
	append(&root.seps, Sep{inode = sep.inode, event = sep.event, name_off = 0, name_len = u32(len(sep.name))}) or_return
	append(&root.kids, lid, rid) or_return
	return nil
}

@(private)
btree_delete :: proc(t: ^Tree, dir: Inode_Id, key: Key) -> (removed: Entry, err: Error) {
	path := descend(t, dir, key) or_return
	leaf := node_edit(t, Node_Key{dir, path.ids[path.depth]}) or_return
	pos := leaf_bound(t, leaf, key, false)
	if pos >= len(leaf.entries) || key_cmp(t, entry_key(leaf, pos), key) != 0 {
		return {}, .Corrupt
	}
	removed = leaf.entries[pos]
	ordered_remove(&leaf.entries, pos)
	for level := path.depth; level > 0; level -= 1 {
		merged := merge_child(t, dir, &path, level) or_return
		if !merged {
			break
		}
	}
	collapse_root(t, dir) or_return
	return removed, nil
}

@(private)
merge_child :: proc(t: ^Tree, dir: Inode_Id, path: ^Path, level: int) -> (merged: bool, err: Error) {
	n := node_get(t, Node_Key{dir, path.ids[level]}) or_return
	if node_size(n) >= max(node_max(t) / 4, 1) {
		return false, nil
	}
	parent := node_get(t, Node_Key{dir, path.ids[level - 1]}) or_return
	if len(parent.kids) < 2 {
		return false, nil
	}
	i := path.idx[level - 1]
	if i >= len(parent.kids) {
		return false, .Corrupt
	}
	li := i if i + 1 < len(parent.kids) else i - 1
	left_key := Node_Key{dir, parent.kids[li]}
	right_key := Node_Key{dir, parent.kids[li + 1]}
	left0 := node_get(t, left_key) or_return
	right0 := node_get(t, right_key) or_return
	if left0.leaf != right0.leaf {
		return false, .Corrupt
	}
	if node_size(left0) + node_size(right0) > node_max(t) {
		return false, nil
	}
	parent_w := node_edit(t, Node_Key{dir, path.ids[level - 1]}) or_return
	left := node_edit(t, left_key) or_return
	right := node_get(t, right_key) or_return
	if left.leaf {
		copy_entries(left, right, 0, len(right.entries)) or_return
	} else {
		sep_put(left, len(left.seps), sep_key(parent_w, li)) or_return
		copy_inner(left, right, 0, len(right.kids)) or_return
	}
	ordered_remove(&parent_w.seps, li)
	ordered_remove(&parent_w.kids, li + 1)
	node_drop(t, right_key) or_return
	return true, nil
}

@(private)
collapse_root :: proc(t: ^Tree, dir: Inode_Id) -> Error {
	for _ in 0 ..< MAX_HEIGHT {
		root := node_get(t, Node_Key{dir, 0}) or_return
		if root.leaf || len(root.kids) != 1 {
			return nil
		}
		child_key := Node_Key{dir, root.kids[0]}
		w := node_edit(t, Node_Key{dir, 0}) or_return
		child := node_get(t, child_key) or_return
		clear(&w.entries)
		clear(&w.seps)
		clear(&w.kids)
		clear(&w.arena)
		w.leaf = child.leaf
		if child.leaf {
			copy_entries(w, child, 0, len(child.entries)) or_return
		} else {
			copy_inner(w, child, 0, len(child.kids)) or_return
		}
		node_drop(t, child_key) or_return
	}
	return .Corrupt
}

@(private)
btree_update :: proc(t: ^Tree, dir: Inode_Id, key: Key, alive: bool, alive_lamport: u64, present: bool) -> (was: bool, err: Error) {
	path := descend(t, dir, key) or_return
	leaf_key := Node_Key{dir, path.ids[path.depth]}
	leaf := node_get(t, leaf_key) or_return
	pos := leaf_bound(t, leaf, key, false)
	if pos >= len(leaf.entries) || key_cmp(t, entry_key(leaf, pos), key) != 0 {
		return false, .Corrupt
	}
	e := leaf.entries[pos]
	if e.alive == alive && e.alive_lamport == alive_lamport && e.present == present {
		return e.present, nil
	}
	w := node_edit(t, leaf_key) or_return
	we := &w.entries[pos]
	was = we.present
	we.alive = alive
	we.alive_lamport = alive_lamport
	we.present = present
	return was, nil
}

iter_first :: proc(t: ^Tree, dir: Inode_Id) -> (it: Iter, err: Error) {
	it.tree = t
	it.dir = dir
	it.path = descend(t, dir, {}, true) or_return
	it.leaf = node_get(t, Node_Key{dir, it.path.ids[it.path.depth]}) or_return
	return it, nil
}

iter_seek :: proc(t: ^Tree, dir: Inode_Id, key: Key, strict: bool) -> (it: Iter, err: Error) {
	it.tree = t
	it.dir = dir
	it.path = descend(t, dir, key) or_return
	it.leaf = node_get(t, Node_Key{dir, it.path.ids[it.path.depth]}) or_return
	it.pos = leaf_bound(t, it.leaf, key, strict)
	return it, nil
}

iter_next :: proc(it: ^Iter) -> (item: Item, ok: bool, err: Error) {
	for !it.done {
		if it.pos < len(it.leaf.entries) {
			item = Item{entry_key(it.leaf, it.pos), it.leaf.entries[it.pos]}
			it.pos += 1
			return item, true, nil
		}
		level := it.path.depth - 1
		for level >= 0 {
			n := node_get(it.tree, Node_Key{it.dir, it.path.ids[level]}) or_return
			if it.path.idx[level] + 1 < len(n.kids) {
				it.path.idx[level] += 1
				break
			}
			level -= 1
		}
		if level < 0 {
			it.done = true
			break
		}
		parent := node_get(it.tree, Node_Key{it.dir, it.path.ids[level]}) or_return
		id := parent.kids[it.path.idx[level]]
		for lvl := level + 1; ; lvl += 1 {
			if lvl >= MAX_HEIGHT {
				return {}, false, .Corrupt
			}
			n := node_get(it.tree, Node_Key{it.dir, id}) or_return
			it.path.ids[lvl] = id
			if n.leaf {
				it.path.depth = lvl
				it.leaf = n
				it.pos = 0
				break
			}
			if !valid_inner(n) {
				return {}, false, .Corrupt
			}
			it.path.idx[lvl] = 0
			id = n.kids[0]
		}
	}
	return {}, false, nil
}

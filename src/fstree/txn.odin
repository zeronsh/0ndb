package fstree

import "../prim"

import "base:runtime"
import "core:strings"

@(private)
room :: proc(m: ^$M/map[$K]$V, extra: int) -> runtime.Allocator_Error {
	return reserve(m, (len(m) + extra) * 4 / 3 + 2)
}

@(private)
txn_begin :: proc(t: ^Tree) {
	t.txn.active = true
	t.txn.has_log = false
}

@(private)
txn_abort :: proc(t: ^Tree) {
	for _, n in prim.unordered(t.txn.inodes) {
		inode_free(t, n)
	}
	for _, n in prim.unordered(t.txn.nodes) {
		node_free(t, n)
	}
	clear(&t.txn.inodes)
	clear(&t.txn.nodes)
	t.txn.active = false
	t.txn.has_log = false
}

@(private)
txn_commit :: proc(t: ^Tree) -> Error {
	added_inodes := 0
	for id in t.txn.inodes {
		if !(id in t.inodes) {
			added_inodes += 1
		}
	}
	added_nodes := 0
	for key, n in t.txn.nodes {
		if n != nil && !(key in t.nodes) {
			added_nodes += 1
		}
	}
	err: runtime.Allocator_Error
	err = room(&t.inodes, added_inodes)
	if err == nil {
		err = room(&t.nodes, added_nodes)
	}
	if err == nil {
		err = room(&t.dirty_inodes, len(t.txn.inodes))
	}
	if err == nil {
		err = room(&t.dirty_nodes, len(t.txn.nodes))
	}
	if err == nil && t.txn.has_log {
		err = reserve(&t.log, len(t.log) + 1)
	}
	if err != nil {
		txn_abort(t)
		return err
	}
	for id in prim.sorted_keys(t.txn.inodes) {
		if id not_in t.txn.inodes {
			continue
		}
		n := t.txn.inodes[id]
		if old, ok := t.inodes[id]; ok && old != n {
			inode_free(t, old)
		}
		n.used = touch(t)
		t.inodes[id] = n
		t.dirty_inodes[id] = {}
	}
	for key in prim.sorted_keys(t.txn.nodes) {
		if key not_in t.txn.nodes {
			continue
		}
		n := t.txn.nodes[key]
		if old, ok := t.nodes[key]; ok && old != n {
			node_free(t, old)
		}
		if n == nil {
			delete_key(&t.nodes, key)
			t.dirty_nodes[key] = true
		} else {
			n.used = touch(t)
			t.nodes[key] = n
			t.dirty_nodes[key] = false
		}
	}
	if t.txn.has_log {
		inject_at(&t.log, t.txn.log_at, t.txn.log_ref)
	}
	clear(&t.txn.inodes)
	clear(&t.txn.nodes)
	t.txn.active = false
	t.txn.has_log = false
	return nil
}

@(private)
inode_clone :: proc(t: ^Tree, src: ^Inode) -> (dst: ^Inode, err: Error) {
	dst = new(Inode, t.allocator) or_return
	dst^ = src^
	dst.moves = {}
	dst.alive_log = {}
	dst.flag_log = {}
	dst.targets = {}
	defer if err != nil {
		inode_free(t, dst)
		dst = nil
	}
	dst.moves = make([dynamic]Move, 0, len(src.moves) + 1, t.allocator) or_return
	dst.alive_log = make([dynamic]Alive_Entry, 0, len(src.alive_log) + 1, t.allocator) or_return
	dst.flag_log = make([dynamic]Flag_Entry, 0, len(src.flag_log) + 1, t.allocator) or_return
	dst.targets = make([dynamic]Target_Entry, 0, len(src.targets) + 1, t.allocator) or_return
	for m in src.moves {
		c := m
		c.name = strings.clone(m.name, t.allocator) or_return
		append(&dst.moves, c)
	}
	append(&dst.alive_log, ..src.alive_log[:])
	append(&dst.flag_log, ..src.flag_log[:])
	for e in src.targets {
		c := e
		c.target = strings.clone(e.target, t.allocator) or_return
		append(&dst.targets, c)
	}
	return dst, nil
}

@(private)
edit :: proc(t: ^Tree, id: Inode_Id) -> (node: ^Inode, err: Error) {
	if n, ok := t.txn.inodes[id]; ok {
		return n, nil
	}
	if id == ROOT {
		return nil, .Root
	}
	src := get(t, id) or_return
	if src == nil {
		return nil, .Unknown_Inode
	}
	room(&t.txn.inodes, 1) or_return
	c := inode_clone(t, src) or_return
	t.txn.inodes[id] = c
	return c, nil
}

@(private)
adopt :: proc(t: ^Tree, n: ^Inode) -> Error {
	room(&t.txn.inodes, 1) or_return
	t.txn.inodes[n.id] = n
	return nil
}

@(private)
node_clone :: proc(t: ^Tree, src: ^Node) -> (dst: ^Node, err: Error) {
	dst = new(Node, t.allocator) or_return
	dst.leaf = src.leaf
	dst.next = src.next
	defer if err != nil {
		node_free(t, dst)
		dst = nil
	}
	bytes := 0
	for e in src.entries {
		bytes += int(e.name_len)
	}
	for s in src.seps {
		bytes += int(s.name_len)
	}
	dst.arena = make([dynamic]u8, 0, bytes + MAX_NAME, t.allocator) or_return
	dst.entries = make([dynamic]Entry, 0, len(src.entries) + 2, t.allocator) or_return
	dst.seps = make([dynamic]Sep, 0, len(src.seps) + 2, t.allocator) or_return
	dst.kids = make([dynamic]u64, 0, len(src.kids) + 2, t.allocator) or_return
	for e in src.entries {
		c := e
		c.name_off = u32(len(dst.arena))
		append(&dst.arena, entry_name(src, e))
		append(&dst.entries, c)
	}
	for s in src.seps {
		c := s
		c.name_off = u32(len(dst.arena))
		append(&dst.arena, sep_name(src, s))
		append(&dst.seps, c)
	}
	append(&dst.kids, ..src.kids[:])
	return dst, nil
}

@(private)
node_edit :: proc(t: ^Tree, key: Node_Key) -> (node: ^Node, err: Error) {
	if n, ok := t.txn.nodes[key]; ok {
		if n == nil {
			return nil, .Corrupt
		}
		return n, nil
	}
	src := node_get(t, key) or_return
	room(&t.txn.nodes, 1) or_return
	c := node_clone(t, src) or_return
	t.txn.nodes[key] = c
	return c, nil
}

@(private)
node_make :: proc(t: ^Tree, leaf: bool) -> (node: ^Node, err: Error) {
	n := new(Node, t.allocator) or_return
	n.leaf = leaf
	n.entries = make([dynamic]Entry, t.allocator)
	n.seps = make([dynamic]Sep, t.allocator)
	n.kids = make([dynamic]u64, t.allocator)
	n.arena = make([dynamic]u8, t.allocator)
	return n, nil
}

@(private)
node_new :: proc(t: ^Tree, dir: Inode_Id, leaf: bool) -> (id: u64, node: ^Node, err: Error) {
	root := node_edit(t, Node_Key{dir, 0}) or_return
	if root.next == 0 || root.next == max(u64) {
		return 0, nil, .Corrupt
	}
	key := Node_Key{dir, root.next}
	if key in t.txn.nodes {
		return 0, nil, .Corrupt
	}
	room(&t.txn.nodes, 1) or_return
	n := node_make(t, leaf) or_return
	root.next += 1
	t.txn.nodes[key] = n
	return key.node, n, nil
}

@(private)
node_drop :: proc(t: ^Tree, key: Node_Key) -> Error {
	room(&t.txn.nodes, 1) or_return
	if n, ok := t.txn.nodes[key]; ok {
		node_free(t, n)
	}
	t.txn.nodes[key] = nil
	return nil
}

@(private)
dir_create :: proc(t: ^Tree, dir: Inode_Id) -> Error {
	room(&t.txn.nodes, 1) or_return
	n := node_make(t, true) or_return
	n.next = 1
	key := Node_Key{dir, 0}
	if old, ok := t.txn.nodes[key]; ok {
		node_free(t, old)
	}
	t.txn.nodes[key] = n
	return nil
}

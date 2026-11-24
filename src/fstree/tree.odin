package fstree

import "base:runtime"
import "core:slice"
import "../prim"

Move :: struct {
	event:   Event,
	parent:  Inode_Id,
	name:    string,
	applied: bool,
}

Alive_Entry :: struct {
	event: Event,
	alive: bool,
}

Flag_Entry :: struct {
	event: Event,
	mask:  Flags,
	value: Flags,
}

Target_Entry :: struct {
	event:  Event,
	target: string,
}

Inode :: struct {
	id:               Inode_Id,
	kind:             Kind,
	alive:            bool,
	flags:            Flags,
	present_children: u32,
	cur:              int,
	listed:           int,
	moves:            [dynamic]Move,
	alive_log:        [dynamic]Alive_Entry,
	flag_log:         [dynamic]Flag_Entry,
	targets:          [dynamic]Target_Entry,
	used:             u64,
}

Entry :: struct {
	inode:         Inode_Id,
	event:         Event,
	alive_lamport: u64,
	name_off:      u32,
	name_len:      u32,
	kind:          Kind,
	alive:         bool,
	present:       bool,
}

Sep :: struct {
	inode:    Inode_Id,
	event:    Event,
	name_off: u32,
	name_len: u32,
}

Node :: struct {
	leaf:    bool,
	next:    u64,
	entries: [dynamic]Entry,
	seps:    [dynamic]Sep,
	kids:    [dynamic]u64,
	arena:   [dynamic]u8,
	used:    u64,
}

Txn :: struct {
	active:  bool,
	inodes:  map[Inode_Id]^Inode,
	nodes:   map[Node_Key]^Node,
	log_at:  int,
	log_ref: Move_Ref,
	has_log: bool,
}

Tree :: struct {
	allocator:    runtime.Allocator,
	source:       Source,
	root:         ^Inode,
	inodes:       map[Inode_Id]^Inode,
	nodes:        map[Node_Key]^Node,
	log:          [dynamic]Move_Ref,
	log_floor:    u64,
	max_lamport:  u64,
	dirty_inodes: map[Inode_Id]struct{},
	dirty_nodes:  map[Node_Key]bool,
	tick:         u64,
	fanout:       int,
	txn:          Txn,
}

MAX_DEPTH :: 1 << 16

init :: proc(t: ^Tree, source := Source{}, max_lamport: u64 = 0, fanout := DEFAULT_FANOUT, allocator := context.allocator) -> Error {
	t^ = Tree {
		allocator   = allocator,
		source      = source,
		log_floor   = max_lamport + 1,
		max_lamport = max_lamport,
		fanout      = clamp(fanout, 4, 4096),
	}
	t.inodes = make(map[Inode_Id]^Inode, allocator)
	t.nodes = make(map[Node_Key]^Node, allocator)
	t.log = make([dynamic]Move_Ref, allocator)
	t.dirty_inodes = make(map[Inode_Id]struct{}, allocator)
	t.dirty_nodes = make(map[Node_Key]bool, allocator)
	t.txn.inodes = make(map[Inode_Id]^Inode, allocator)
	t.txn.nodes = make(map[Node_Key]^Node, allocator)
	root := new(Inode, allocator) or_return
	root^ = Inode {
		id     = ROOT,
		kind   = .Dir,
		alive  = true,
		cur    = -1,
		listed = -1,
	}
	if _, err := map_insert(&t.inodes, ROOT, root); err != nil {
		free(root, allocator)
		destroy(t)
		return err
	}
	t.root = root
	return nil
}

destroy :: proc(t: ^Tree) {
	txn_abort(t)
	for _, n in prim.unordered(t.inodes) {
		inode_free(t, n)
	}
	for _, n in prim.unordered(t.nodes) {
		node_free(t, n)
	}
	delete(t.inodes)
	delete(t.nodes)
	delete(t.log)
	delete(t.dirty_inodes)
	delete(t.dirty_nodes)
	delete(t.txn.inodes)
	delete(t.txn.nodes)
	t^ = {}
}

@(private)
inode_free :: proc(t: ^Tree, n: ^Inode) {
	if n == nil {
		return
	}
	inode_destroy(n, t.allocator)
	free(n, t.allocator)
}

@(private)
node_free :: proc(t: ^Tree, n: ^Node) {
	if n == nil {
		return
	}
	node_destroy(n)
	free(n, t.allocator)
}

node_destroy :: proc(n: ^Node) {
	delete(n.entries)
	delete(n.seps)
	delete(n.kids)
	delete(n.arena)
	n^ = {}
}

inode_destroy :: proc(n: ^Inode, allocator := context.allocator) {
	for m in n.moves {
		delete(m.name, allocator)
	}
	for e in n.targets {
		delete(e.target, allocator)
	}
	delete(n.moves)
	delete(n.alive_log)
	delete(n.flag_log)
	delete(n.targets)
	n^ = {}
}

@(private)
actor_cmp :: proc(t: ^Tree, a, b: u32) -> int {
	if a == b {
		return 0
	}
	if t.source.actor != nil {
		ia := t.source.actor(t.source.data, a)
		ib := t.source.actor(t.source.data, b)
		for i in 0 ..< len(ia) {
			if ia[i] != ib[i] {
				return -1 if ia[i] < ib[i] else 1
			}
		}
	}
	return -1 if a < b else 1
}

event_cmp :: proc(t: ^Tree, a, b: Event) -> int {
	if a.lamport != b.lamport {
		return -1 if a.lamport < b.lamport else 1
	}
	if a.actor != b.actor {
		return actor_cmp(t, a.actor, b.actor)
	}
	if a.seq != b.seq {
		return -1 if a.seq < b.seq else 1
	}
	return 0
}

@(private)
id_cmp :: proc "contextless" (a, b: Inode_Id) -> int {
	if a.actor != b.actor {
		return -1 if a.actor < b.actor else 1
	}
	if a.seq != b.seq {
		return -1 if a.seq < b.seq else 1
	}
	return 0
}

actor_id :: proc(t: ^Tree, actor: u32) -> prim.Id {
	if t.source.actor == nil {
		return {}
	}
	return t.source.actor(t.source.data, actor)
}

@(private)
touch :: proc(t: ^Tree) -> u64 {
	t.tick += 1
	return t.tick
}

get :: proc(t: ^Tree, id: Inode_Id) -> (node: ^Inode, err: Error) {
	if t.txn.active {
		if n, ok := t.txn.inodes[id]; ok {
			return n, nil
		}
	}
	if n, ok := t.inodes[id]; ok {
		n.used = touch(t)
		return n, nil
	}
	if id == ROOT || t.source.load_inode == nil {
		return nil, nil
	}
	record, found := t.source.load_inode(t.source.data, id)
	if !found {
		return nil, nil
	}
	n := new(Inode, t.allocator) or_return
	decoded, derr := decode_inode(record, t.allocator)
	if derr == nil && decoded.id != id {
		inode_destroy(&decoded, t.allocator)
		derr = .Corrupt
	}
	if derr != nil {
		free(n, t.allocator)
		return nil, derr
	}
	n^ = decoded
	n.used = touch(t)
	if _, ierr := map_insert(&t.inodes, id, n); ierr != nil {
		inode_free(t, n)
		return nil, ierr
	}
	return n, nil
}

node_get :: proc(t: ^Tree, key: Node_Key) -> (node: ^Node, err: Error) {
	if t.txn.active {
		if n, ok := t.txn.nodes[key]; ok {
			if n == nil {
				return nil, .Corrupt
			}
			return n, nil
		}
	}
	if n, ok := t.nodes[key]; ok {
		n.used = touch(t)
		return n, nil
	}
	n := new(Node, t.allocator) or_return
	found := false
	if t.source.load_node != nil {
		record: []u8
		record, found = t.source.load_node(t.source.data, key)
		if found {
			if derr := decode_node_into(record, n, t.allocator); derr != nil {
				node_free(t, n)
				return nil, derr
			}
		}
	}
	if !found {
		if key.node != 0 {
			free(n, t.allocator)
			return nil, .Corrupt
		}
		n.leaf = true
		n.next = 1
	}
	n.used = touch(t)
	if _, ierr := map_insert(&t.nodes, key, n); ierr != nil {
		node_free(t, n)
		return nil, ierr
	}
	return n, nil
}

is_present :: proc "contextless" (n: ^Inode) -> bool {
	return n.id == ROOT || n.alive || (n.kind == .Dir && n.present_children > 0)
}

dirty :: proc(t: ^Tree, allocator := context.allocator) -> (inodes: []Inode_Id, nodes: []Node_State, err: runtime.Allocator_Error) {
	inodes = make([]Inode_Id, len(t.dirty_inodes), allocator) or_return
	i := 0
	for id in prim.unordered(t.dirty_inodes) {
		inodes[i] = id
		i += 1
	}
	nodes, err = make([]Node_State, len(t.dirty_nodes), allocator)
	if err != nil {
		delete(inodes, allocator)
		return nil, nil, err
	}
	i = 0
	for key, deleted in prim.unordered(t.dirty_nodes) {
		nodes[i] = Node_State{key, deleted}
		i += 1
	}
	slice.sort_by(inodes, proc(a, b: Inode_Id) -> bool {return id_cmp(a, b) < 0})
	slice.sort_by(nodes, proc(a, b: Node_State) -> bool {
		if a.key.dir != b.key.dir {
			return id_cmp(a.key.dir, b.key.dir) < 0
		}
		return a.key.node < b.key.node
	})
	return
}

mark_persisted :: proc(t: ^Tree) {
	clear(&t.dirty_inodes)
	clear(&t.dirty_nodes)
}

loaded_count :: proc "contextless" (t: ^Tree) -> (inodes: int, nodes: int) {
	return len(t.inodes), len(t.nodes)
}

@(private)
Aged :: struct {
	inode: Inode_Id,
	key:   Node_Key,
	used:  u64,
}

trim :: proc(t: ^Tree, keep: int) -> runtime.Allocator_Error {
	if t.txn.active || t.source.load_inode == nil || t.source.load_node == nil {
		return nil
	}
	aged := make([dynamic]Aged, 0, max(len(t.inodes), len(t.nodes)), context.temp_allocator) or_return
	for id in prim.try_sorted_keys(t.inodes) or_return {
		n := t.inodes[id]
		if id != ROOT && !(id in t.dirty_inodes) {
			append(&aged, Aged{inode = id, used = n.used})
		}
	}
	slice.sort_by(aged[:], proc(a, b: Aged) -> bool {return a.used > b.used})
	for a, i in aged {
		if i >= keep {
			if n, ok := t.inodes[a.inode]; ok {
				inode_free(t, n)
				delete_key(&t.inodes, a.inode)
			}
		}
	}
	clear(&aged)
	for key in prim.try_sorted_keys(t.nodes) or_return {
		n := t.nodes[key]
		if !(key in t.dirty_nodes) {
			append(&aged, Aged{key = key, used = n.used})
		}
	}
	slice.sort_by(aged[:], proc(a, b: Aged) -> bool {return a.used > b.used})
	for a, i in aged {
		if i >= keep {
			if n, ok := t.nodes[a.key]; ok {
				node_free(t, n)
				delete_key(&t.nodes, a.key)
			}
		}
	}
	if t.source.load_moves != nil {
		clear(&t.log)
		t.log_floor = t.max_lamport + 1
	}
	return nil
}

@(private)
ensure_log :: proc(t: ^Tree, from: u64) -> Error {
	if from >= t.log_floor {
		return nil
	}
	if t.source.load_moves == nil {
		t.log_floor = from
		return nil
	}
	loaded := make([dynamic]Move_Ref, context.temp_allocator)
	if !t.source.load_moves(t.source.data, from, &loaded) {
		return .Unavailable
	}
	count := 0
	for r in loaded {
		if r.event.lamport >= from && r.event.lamport < t.log_floor {
			count += 1
		}
	}
	reserve(&t.log, len(t.log) + count) or_return
	for r in loaded {
		if r.event.lamport >= from && r.event.lamport < t.log_floor {
			append(&t.log, r)
		}
	}
	sort_log(t)
	t.log_floor = from
	return nil
}

@(private)
sort_log :: proc(t: ^Tree) {
	context.user_ptr = t
	slice.sort_by(t.log[:], proc(a, b: Move_Ref) -> bool {
		tree := (^Tree)(context.user_ptr)
		return event_cmp(tree, a.event, b.event) < 0
	})
	w := 0
	for r, i in t.log {
		if i > 0 && r.event == t.log[w - 1].event {
			continue
		}
		t.log[w] = r
		w += 1
	}
	resize(&t.log, w)
}

@(private)
log_upper :: proc(t: ^Tree, e: Event) -> int {
	lo, hi := 0, len(t.log)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if event_cmp(t, t.log[mid].event, e) <= 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
log_lower_lamport :: proc(t: ^Tree, lamport: u64) -> int {
	lo, hi := 0, len(t.log)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if t.log[mid].event.lamport < lamport {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

descendants :: proc(t: ^Tree, dir: Inode_Id, allocator := context.allocator) -> (out: [dynamic]Inode_Id, err: Error) {
	out = make([dynamic]Inode_Id, allocator)
	defer if err != nil {
		delete(out)
		out = nil
	}
	if dir != ROOT {
		n := get(t, dir) or_return
		if n == nil || n.kind != .Dir {
			return
		}
	}
	stack := make([dynamic]Inode_Id, context.temp_allocator)
	seen := make(map[Inode_Id]struct{}, context.temp_allocator)
	append(&stack, dir) or_return
	for len(stack) > 0 {
		d := pop(&stack)
		if d in seen {
			continue
		}
		map_insert(&seen, d, struct{}{}) or_return
		it := iter_first(t, d) or_return
		for {
			item, ok := iter_next(&it) or_return
			if !ok {
				break
			}
			if !item.entry.present {
				continue
			}
			append(&out, item.entry.inode) or_return
			if item.entry.kind == .Dir {
				append(&stack, item.entry.inode) or_return
			}
		}
	}
	return
}

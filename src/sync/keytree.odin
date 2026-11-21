package osync

import "base:intrinsics"
import "base:runtime"
import "core:crypto"
import "core:crypto/blake2b"
import "../journal"
import "../prim"

KEY_TREE_DEPTH :: 44
KEY_TREE_SHIFT :: 4
KEY_TREE_LIMIT :: i64(1) << (KEY_TREE_DEPTH + KEY_TREE_SHIFT)

Tree_Node :: struct {
	start: u64,
	level: u8,
	seed:  [32]u8,
}

Key_Tree :: struct {
	version:   u64,
	nodes:     [dynamic]Tree_Node,
	path:      [KEY_TREE_DEPTH + 1][32]u8,
	path_node: int,
	path_cell: u64,
	path_ok:   bool,
	allocator: runtime.Allocator,
}

keytree_init :: proc(t: ^Key_Tree, root: [32]u8, allocator := context.allocator) -> Error {
	t^ = {
		allocator = allocator,
	}
	t.nodes = make([dynamic]Tree_Node, allocator)
	if _, e := append(&t.nodes, Tree_Node{start = 0, level = 0, seed = root}); e != nil {
		return .No_Memory
	}
	return .None
}

keytree_new :: proc(t: ^Key_Tree, allocator := context.allocator) -> Error {
	root: [32]u8
	crypto.rand_bytes(root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return keytree_init(t, root, allocator)
}

keytree_destroy :: proc(t: ^Key_Tree) {
	for &n in t.nodes {
		crypto.zero_explicit(&n.seed, size_of(n.seed))
	}
	delete(t.nodes)
	crypto.zero_explicit(&t.path, size_of(t.path))
	t^ = {}
}

keytree_seeds :: proc "contextless" (t: ^Key_Tree) -> int {
	return len(t.nodes)
}

keytree_key :: proc(t: ^Key_Tree, off: i64) -> (key: journal.Key, ok: bool) {
	if off < 0 || off >= KEY_TREE_LIMIT {
		return
	}
	cell := u64(off) >> KEY_TREE_SHIFT
	i := _keytree_find(t, cell)
	if i < 0 {
		return
	}
	n := &t.nodes[i]
	from := int(n.level)
	if t.path_ok && t.path_node == i {
		diff := cell ~ t.path_cell
		if diff == 0 {
			return t.path[KEY_TREE_DEPTH], true
		}
		high := 63 - int(intrinsics.count_leading_zeros(diff))
		from = max(KEY_TREE_DEPTH - 1 - high, int(n.level))
	} else {
		t.path[n.level] = n.seed
	}
	for l in from ..< KEY_TREE_DEPTH {
		bit := (cell >> u64(KEY_TREE_DEPTH - 1 - l)) & 1
		left, right := _ggm(&t.path[l])
		t.path[l + 1] = right if bit == 1 else left
		crypto.zero_explicit(&left, size_of(left))
		crypto.zero_explicit(&right, size_of(right))
	}
	t.path_node = i
	t.path_cell = cell
	t.path_ok = true
	return t.path[KEY_TREE_DEPTH], true
}

keytree_puncture :: proc(t: ^Key_Tree, from, to: i64) -> Error {
	if from < 0 || to <= from || to > KEY_TREE_LIMIT {
		return .Invalid
	}
	lo := u64(from) >> KEY_TREE_SHIFT
	hi := u64(to) >> KEY_TREE_SHIFT
	if hi <= lo {
		return .None
	}
	out := make([dynamic]Tree_Node, t.allocator)
	for &n in t.nodes {
		if e := _keytree_split(&out, n, lo, hi); e != .None {
			for &o in out {
				crypto.zero_explicit(&o.seed, size_of(o.seed))
			}
			delete(out)
			return e
		}
		crypto.zero_explicit(&n.seed, size_of(n.seed))
	}
	delete(t.nodes)
	t.nodes = out
	t.version += 1
	t.path_ok = false
	crypto.zero_explicit(&t.path, size_of(t.path))
	return .None
}

keytree_encode :: proc(t: ^Key_Tree, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, 1)
	prim.write_uvarint(&w, t.version)
	prim.write_uvarint(&w, u64(len(t.nodes)))
	for n in t.nodes {
		prim.write_uvarint(&w, n.start)
		prim.write_u8(&w, n.level)
		s := n.seed
		prim.write_raw(&w, s[:])
	}
	return .No_Memory if w.err != .None else .None
}

keytree_decode :: proc(t: ^Key_Tree, data: []u8, allocator := context.allocator) -> Error {
	r := prim.reader(data)
	if prim.read_u8(&r) != 1 {
		return .Corrupt
	}
	version := prim.read_uvarint(&r)
	count := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || count > u64(prim.reader_remaining(&r) / 34) {
		return .Corrupt
	}
	t^ = {
		allocator = allocator,
		version   = version,
	}
	t.nodes = make([dynamic]Tree_Node, 0, int(count), allocator)
	end: u64
	for _ in 0 ..< count {
		n: Tree_Node
		n.start = prim.read_uvarint(&r)
		n.level = prim.read_u8(&r)
		prim.read_fixed(&r, n.seed[:])
		span := _span(n.level)
		if !prim.reader_ok(&r) || n.level > KEY_TREE_DEPTH || n.start < end || n.start & (span - 1) != 0 || n.start + span > u64(1) << KEY_TREE_DEPTH {
			keytree_destroy(t)
			return .Corrupt
		}
		end = n.start + span
		append(&t.nodes, n)
	}
	if !prim.reader_done(&r) {
		keytree_destroy(t)
		return .Corrupt
	}
	return .None
}

keytree_seal_range :: proc(t: ^Key_Tree, data: []u8, off: i64) -> Error {
	return _from_journal(journal.seal_range(data, off, keytree_provider(t)))
}

keytree_open_record :: proc(t: ^Key_Tree, rec: []u8, off: i64) -> Error {
	return _from_journal(journal.open_record(rec, off, keytree_provider(t)))
}

static_provider :: proc(key: ^journal.Key) -> journal.Key_Provider {
	return journal.Key_Provider{data = key, key = _static_provide}
}

@(private)
_static_provide :: proc(data: rawptr, off: i64, out: ^journal.Key) -> bool {
	out^ = (cast(^journal.Key)data)^
	return true
}

@(private)
_span :: proc "contextless" (level: u8) -> u64 {
	return u64(1) << u64(KEY_TREE_DEPTH - int(level))
}

@(private)
_keytree_find :: proc(t: ^Key_Tree, cell: u64) -> int {
	lo, hi := 0, len(t.nodes)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.nodes[mid].start + _span(t.nodes[mid].level) <= cell {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(t.nodes) && t.nodes[lo].start <= cell {
		return lo
	}
	return -1
}

@(private)
_keytree_split :: proc(out: ^[dynamic]Tree_Node, n: Tree_Node, lo, hi: u64) -> Error {
	start := n.start
	end := n.start + _span(n.level)
	if end <= lo || start >= hi {
		if _, e := append(out, n); e != nil {
			return .No_Memory
		}
		return .None
	}
	if start >= lo && end <= hi {
		return .None
	}
	seed := n.seed
	left, right := _ggm(&seed)
	defer {
		crypto.zero_explicit(&left, size_of(left))
		crypto.zero_explicit(&right, size_of(right))
		crypto.zero_explicit(&seed, size_of(seed))
	}
	half := _span(n.level + 1)
	_keytree_split(out, Tree_Node{start = start, level = n.level + 1, seed = left}, lo, hi) or_return
	return _keytree_split(out, Tree_Node{start = start + half, level = n.level + 1, seed = right}, lo, hi)
}

@(private)
_ggm :: proc(seed: ^[32]u8) -> (left, right: [32]u8) {
	out: [64]u8
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, seed[:], 64)
	blake2b.update(&ctx, transmute([]u8)string("0ndb ggm"))
	blake2b.final(&ctx, out[:])
	copy(left[:], out[:32])
	copy(right[:], out[32:])
	crypto.zero_explicit(&out, size_of(out))
	return
}

keytree_provider :: proc(t: ^Key_Tree) -> journal.Key_Provider {
	return journal.Key_Provider{data = t, key = _keytree_provide}
}

@(private)
_keytree_provide :: proc(data: rawptr, off: i64, out: ^journal.Key) -> bool {
	k, ok := keytree_key(cast(^Key_Tree)data, off)
	if ok {
		out^ = k
		crypto.zero_explicit(&k, size_of(k))
	}
	return ok
}

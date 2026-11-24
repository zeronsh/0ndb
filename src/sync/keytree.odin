package osync

import "base:intrinsics"
import "core:slice"
import "base:runtime"
import "core:crypto"
import "core:crypto/blake2b"
import "../journal"
import "../prim"

KEYS_STREAM :: "keys/"
CHECKPOINT_STREAM :: "ckpt/"
KEYS_RECORD :: 2
KEYS_HEAD_STREAM :: "keyshead/"
KEYS_HEAD_RECORD :: 3

keys_head_name :: proc(keys_name: string, allocator := context.temp_allocator) -> (string, Error) {
	seg := keys_name[len(KEYS_STREAM):] if len(keys_name) >= len(KEYS_STREAM) && keys_name[:len(KEYS_STREAM)] == KEYS_STREAM else keys_name
	return _concat(allocator, KEYS_HEAD_STREAM, seg)
}

keys_stream_name :: proc(segment: string, allocator := context.temp_allocator) -> (string, Error) {
	return _concat(allocator, KEYS_STREAM, segment)
}

keys_record_decode :: proc(t: ^Key_Tree, body: []u8, allocator := context.allocator) -> Error {
	if len(body) < 1 || body[0] != KEYS_RECORD {
		return .Corrupt
	}
	return keytree_decode(t, body[1:], allocator)
}

KEY_TREE_DEPTH :: 44
KEY_TREE_SHIFT :: 4
OBJECT_TREE_DEPTH :: 64
KEY_TREE_MAX_DEPTH :: 64

Tree_Node :: struct {
	start: u64,
	level: u8,
	seed:  [32]u8,
}

EPOCH_TAG_LEN :: 12
KEYS_SEALED :: 4

Epoch_Tag :: [EPOCH_TAG_LEN]u8

Key_Tree :: struct {
	version:   u64,
	epoch:     Epoch_Tag,
	depth:     u8,
	shift:     u8,
	nodes:     [dynamic]Tree_Node,
	path:      [KEY_TREE_MAX_DEPTH + 1][32]u8,
	path_node: int,
	path_cell: u64,
	path_ok:   bool,
	allocator: runtime.Allocator,
}

keytree_init :: proc(t: ^Key_Tree, root: [32]u8, depth: u8 = KEY_TREE_DEPTH, shift: u8 = KEY_TREE_SHIFT, allocator := context.allocator) -> Error {
	if depth == 0 || depth > KEY_TREE_MAX_DEPTH || int(depth) + int(shift) > 64 {
		return .Invalid
	}
	t^ = {
		depth     = depth,
		shift     = shift,
		allocator = allocator,
	}
	t.nodes = make([dynamic]Tree_Node, allocator)
	if _, e := append(&t.nodes, Tree_Node{start = 0, level = 0, seed = root}); e != nil {
		return .No_Memory
	}
	return .None
}

keytree_new :: proc(t: ^Key_Tree, random := prim.Random{}, allocator := context.allocator) -> Error {
	root: [32]u8
	prim.random_fill(random, root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return keytree_init(t, root, KEY_TREE_DEPTH, KEY_TREE_SHIFT, allocator)
}

object_tree_new :: proc(t: ^Key_Tree, random := prim.Random{}, allocator := context.allocator) -> Error {
	root: [32]u8
	prim.random_fill(random, root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return keytree_init(t, root, OBJECT_TREE_DEPTH, 0, allocator)
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
	if off < 0 || int(t.depth) + int(t.shift) < 63 && off >= i64(1) << u64(t.depth + t.shift) {
		return
	}
	return keytree_leaf(t, u64(off) >> t.shift)
}

keytree_leaf :: proc(t: ^Key_Tree, cell: u64) -> (key: [32]u8, ok: bool) {
	if t.depth < 64 && cell >> t.depth != 0 {
		return
	}
	i := _keytree_find(t, cell)
	if i < 0 {
		return
	}
	n := &t.nodes[i]
	from := int(n.level)
	depth := int(t.depth)
	if t.path_ok && t.path_node == i {
		diff := cell ~ t.path_cell
		if diff == 0 {
			return t.path[depth], true
		}
		high := 63 - int(intrinsics.count_leading_zeros(diff))
		from = max(depth - 1 - high, int(n.level))
	} else {
		t.path[n.level] = n.seed
	}
	for l in from ..< depth {
		bit := (cell >> u64(depth - 1 - l)) & 1
		left, right := _ggm(&t.path[l])
		t.path[l + 1] = right if bit == 1 else left
		crypto.zero_explicit(&left, size_of(left))
		crypto.zero_explicit(&right, size_of(right))
	}
	t.path_node = i
	t.path_cell = cell
	t.path_ok = true
	return t.path[depth], true
}

keytree_puncture :: proc(t: ^Key_Tree, from, to: i64) -> Error {
	if from < 0 || to <= from {
		return .Invalid
	}
	lo := u64(from) >> t.shift
	hi := u64(to) >> t.shift
	if hi <= lo {
		return .None
	}
	return keytree_puncture_cells(t, lo, hi - 1)
}

keytree_puncture_except :: proc(t: ^Key_Tree, from, to: i64, keep: []i64) -> Error {
	if from < 0 || to <= from {
		return .Invalid
	}
	lo := u64(from) >> t.shift
	hi := u64(to) >> t.shift
	if hi <= lo {
		return .None
	}
	cells := make([dynamic]u64, 0, len(keep), context.temp_allocator)
	for k in keep {
		if k >= 0 {
			c := u64(k) >> t.shift
			if c >= lo && c < hi {
				append(&cells, c)
			}
		}
	}
	slice.sort(cells[:])
	start := lo
	for c in cells {
		if c > start {
			keytree_puncture_cells(t, start, c - 1) or_return
		}
		start = max(start, c + 1)
	}
	if start < hi {
		keytree_puncture_cells(t, start, hi - 1) or_return
	}
	return .None
}

keytree_puncture_cells :: proc(t: ^Key_Tree, lo, hi_incl: u64) -> Error {
	if hi_incl < lo || (t.depth < 64 && hi_incl >> t.depth != 0) {
		return .Invalid
	}
	out := make([dynamic]Tree_Node, t.allocator)
	for &n in t.nodes {
		if e := _keytree_split(t, &out, n, lo, hi_incl); e != .None {
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

keytree_apply :: proc(t: ^Key_Tree, other: ^Key_Tree) -> Error {
	if other.depth != t.depth || other.shift != t.shift {
		return .Invalid
	}
	pos: u64
	changed := false
	for n in other.nodes {
		if n.start > pos {
			keytree_puncture_cells(t, pos, n.start - 1) or_return
			changed = true
		}
		pos = _node_last(t, n) + 1
		if pos == 0 {
			break
		}
	}
	limit := _cell_limit(t)
	if pos != 0 && (t.depth == 64 || pos < limit) && len(other.nodes) > 0 {
		keytree_puncture_cells(t, pos, limit - 1) or_return
		changed = true
	} else if len(other.nodes) == 0 {
		keytree_puncture_cells(t, 0, limit - 1) or_return
		changed = true
	}
	if changed {
		t.version = max(t.version, other.version)
	}
	return .None
}

keytree_encode :: proc(t: ^Key_Tree, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, 3)
	prim.write_raw(&w, t.epoch[:])
	prim.write_u8(&w, t.depth)
	prim.write_u8(&w, t.shift)
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
	if prim.read_u8(&r) != 3 {
		return .Corrupt
	}
	tag: Epoch_Tag
	prim.read_fixed(&r, tag[:])
	depth := prim.read_u8(&r)
	shift := prim.read_u8(&r)
	version := prim.read_uvarint(&r)
	count := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || depth == 0 || depth > KEY_TREE_MAX_DEPTH || int(depth) + int(shift) > 64 || count > u64(prim.reader_remaining(&r) / 34) {
		return .Corrupt
	}
	t^ = {
		allocator = allocator,
		version   = version,
		epoch     = tag,
		depth     = depth,
		shift     = shift,
	}
	t.nodes = make([dynamic]Tree_Node, 0, int(count), allocator)
	next: u64
	done := false
	for _ in 0 ..< count {
		n: Tree_Node
		n.start = prim.read_uvarint(&r)
		n.level = prim.read_u8(&r)
		prim.read_fixed(&r, n.seed[:])
		if !prim.reader_ok(&r) || done || n.level > depth || n.start < next || !_aligned(t, n) {
			keytree_destroy(t)
			return .Corrupt
		}
		last := _node_last(t, n)
		next = last + 1
		done = next == 0 || (depth < 64 && next >= u64(1) << depth)
		append(&t.nodes, n)
	}
	if !prim.reader_done(&r) {
		keytree_destroy(t)
		return .Corrupt
	}
	return .None
}

keytree_reseed :: proc(t: ^Key_Tree, from: i64, epoch: Epoch_Tag, random := prim.Random{}) -> Error {
	if from < 0 {
		return .Invalid
	}
	lo := u64(from) >> t.shift
	limit := _cell_limit(t)
	if t.epoch == epoch {
		return .None
	}
	if t.depth < 64 && lo >= limit {
		t.epoch = epoch
		t.version += 1
		return .None
	}
	last := limit - 1 if t.depth < 64 else max(u64)
	keytree_puncture_cells(t, lo, last) or_return
	pos := lo
	for {
		level := u8(0)
		for l := u8(0); l <= t.depth; l += 1 {
			bits := u64(t.depth) - u64(l)
			size := u64(1) << bits if bits < 64 else 0
			if bits >= 64 {
				if pos == 0 {
					level = l
					break
				}
				continue
			}
			if pos & (size - 1) == 0 && (t.depth == 64 || pos + size <= limit) {
				level = l
				break
			}
		}
		n := Tree_Node{start = pos, level = level}
		prim.random_fill(random, n.seed[:])
		if _, e := append(&t.nodes, n); e != nil {
			crypto.zero_explicit(&n.seed, size_of(n.seed))
			return .No_Memory
		}
		crypto.zero_explicit(&n.seed, size_of(n.seed))
		next := _node_last(t, n) + 1
		if next == 0 || (t.depth < 64 && next >= limit) {
			break
		}
		pos = next
	}
	slice.sort_by(t.nodes[:], proc(a, b: Tree_Node) -> bool {
		return a.start < b.start
	})
	t.version += 1
	t.epoch = epoch
	t.path_ok = false
	crypto.zero_explicit(&t.path, size_of(t.path))
	return .None
}

keys_record_seal :: proc(t: ^Key_Tree, key: ^[32]u8, stream: Stream_Id, out: ^[dynamic]u8) -> Error {
	plain := make([dynamic]u8, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	keytree_encode(t, &plain) or_return
	append(out, KEYS_SEALED)
	append(out, ..t.epoch[:])
	k := _keys_record_key(key, stream, t.version)
	defer crypto.zero_explicit(&k, size_of(k))
	start := len(out)
	resize(out, start + len(plain) + 16)
	aead_seal(k[:], t.epoch[:], plain[:], out[start:])
	return .None
}

keys_record_tag :: proc(body: []u8) -> (tag: Epoch_Tag, sealed: bool) {
	if len(body) >= 1 + EPOCH_TAG_LEN + 16 && body[0] == KEYS_SEALED {
		copy(tag[:], body[1:][:EPOCH_TAG_LEN])
		return tag, true
	}
	return
}

keys_record_open :: proc(t: ^Key_Tree, body: []u8, key: ^[32]u8, stream: Stream_Id, version: u64, allocator := context.allocator) -> Error {
	tag, sealed := keys_record_tag(body)
	if !sealed {
		return keys_record_decode(t, body, allocator)
	}
	ct := body[1 + EPOCH_TAG_LEN:]
	plain := make([]u8, len(ct) - 16, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	k := _keys_record_key(key, stream, version)
	defer crypto.zero_explicit(&k, size_of(k))
	if !aead_open(k[:], tag[:], ct, plain) {
		return .Auth
	}
	keytree_decode(t, plain, allocator) or_return
	if t.epoch != tag || t.version != version {
		keytree_destroy(t)
		return .Corrupt
	}
	return .None
}

@(private)
_keys_record_key :: proc(key: ^[32]u8, stream: Stream_Id, version: u64) -> (k: [32]u8) {
	ctx: [32 + 8]u8
	s := stream
	copy(ctx[:32], s[:])
	prim.put_u64le(ctx[32:], version)
	_derive(key[:], "0ndb keys record", ctx[:], k[:])
	return
}

epoch_tag :: proc(number: u32, id: Record_Id) -> (t: Epoch_Tag) {
	prim.put_u32le(t[:4], number)
	x := id
	copy(t[4:], x[:8])
	return
}

epoch_tag_number :: proc(t: Epoch_Tag) -> u32 {
	x := t
	return prim.get_u32le(x[:4])
}

keytree_seal_range :: proc(t: ^Key_Tree, data: []u8, off: i64) -> Error {
	return _from_journal(journal.seal_range(data, off, keytree_provider(t)))
}

keytree_open_record :: proc(t: ^Key_Tree, rec: []u8, off: i64) -> Error {
	return _from_journal(journal.open_record(rec, off, keytree_provider(t)))
}

keytree_provider :: proc(t: ^Key_Tree) -> journal.Key_Provider {
	return journal.Key_Provider{data = t, key = _keytree_provide, loaded = _keytree_loaded, block = _keytree_block_provide, cover = _keytree_cover_provide}
}

static_provider :: proc(key: ^journal.Key) -> journal.Key_Provider {
	return journal.Key_Provider{data = key, key = _static_provide, block = _static_block, cover = _static_cover}
}

keytree_block :: proc(t: ^Key_Tree, cell: u64, bits: u8) -> (key: [32]u8, ok: bool) {
	if bits > t.depth || bits >= 63 {
		return
	}
	size := u64(1) << bits
	if cell & (size - 1) != 0 || (t.depth < 64 && (cell + size - 1) >> t.depth != 0) {
		return
	}
	i := _keytree_find(t, cell)
	if i < 0 {
		return
	}
	n := t.nodes[i]
	depth := int(t.depth)
	target := depth - int(bits)
	if int(n.level) > target || _node_last(t, n) < cell + size - 1 {
		return
	}
	key = n.seed
	for l in int(n.level) ..< target {
		bit := (cell >> u64(depth - 1 - l)) & 1
		left, right := _ggm(&key)
		key = right if bit == 1 else left
		crypto.zero_explicit(&left, size_of(left))
		crypto.zero_explicit(&right, size_of(right))
	}
	return key, true
}

keytree_cover :: proc(t: ^Key_Tree, lo, hi: u64, out: ^[dynamic]journal.Cell_Run) {
	if hi <= lo {
		return
	}
	for n in t.nodes {
		last := _node_last(t, n)
		if last < lo || n.start >= hi {
			continue
		}
		a := max(lo, n.start)
		b := hi if last >= hi - 1 else last + 1
		append(out, journal.Cell_Run{a, b})
	}
}

object_position :: proc(sc: ^Scope, oid: []u8) -> u64 {
	k := object_index(sc, oid)
	return prim.get_u64le(k[:8])
}

object_tree_key :: proc(t: ^Key_Tree, sc: ^Scope, oid: []u8) -> (key: [32]u8, ok: bool) {
	leaf, found := keytree_leaf(t, object_position(sc, oid))
	if !found {
		return
	}
	defer crypto.zero_explicit(&leaf, size_of(leaf))
	_derive(leaf[:], "0ndb object key", oid, key[:])
	return key, true
}

object_tree_shred :: proc(t: ^Key_Tree, sc: ^Scope, oid: []u8) -> Error {
	p := object_position(sc, oid)
	return keytree_puncture_cells(t, p, p)
}

@(private)
_keytree_block_provide :: proc(data: rawptr, cell: u64, bits: u8, out: ^journal.Key) -> bool {
	k, ok := keytree_block(cast(^Key_Tree)data, cell, bits)
	if ok {
		out^ = k
	}
	crypto.zero_explicit(&k, size_of(k))
	return ok
}

@(private)
_keytree_cover_provide :: proc(data: rawptr, lo, hi: u64, out: ^[dynamic]journal.Cell_Run) -> bool {
	keytree_cover(cast(^Key_Tree)data, lo, hi, out)
	return true
}

@(private)
_static_block :: proc(data: rawptr, cell: u64, bits: u8, out: ^journal.Key) -> bool {
	out^ = (cast(^journal.Key)data)^
	return true
}

@(private)
_static_cover :: proc(data: rawptr, lo, hi: u64, out: ^[dynamic]journal.Cell_Run) -> bool {
	if hi > lo {
		append(out, journal.Cell_Run{lo, hi})
	}
	return true
}

@(private)
_static_provide :: proc(data: rawptr, off: i64, out: ^journal.Key) -> bool {
	out^ = (cast(^journal.Key)data)^
	return true
}

@(private)
_keytree_loaded :: proc(data: rawptr) -> bool {
	return (cast(^Key_Tree)data).depth > 0
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

@(private)
_cell_limit :: proc "contextless" (t: ^Key_Tree) -> u64 {
	if t.depth >= 64 {
		return 0
	}
	return u64(1) << t.depth
}

@(private)
_node_last :: proc "contextless" (t: ^Key_Tree, n: Tree_Node) -> u64 {
	bits := u64(t.depth) - u64(n.level)
	if bits >= 64 {
		return max(u64)
	}
	return n.start + (u64(1) << bits) - 1
}

@(private)
_aligned :: proc "contextless" (t: ^Key_Tree, n: Tree_Node) -> bool {
	bits := u64(t.depth) - u64(n.level)
	if bits >= 64 {
		return n.start == 0
	}
	return n.start & ((u64(1) << bits) - 1) == 0
}

@(private)
_keytree_find :: proc(t: ^Key_Tree, cell: u64) -> int {
	lo, hi := 0, len(t.nodes)
	for lo < hi {
		mid := (lo + hi) / 2
		if _node_last(t, t.nodes[mid]) < cell {
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
_keytree_split :: proc(t: ^Key_Tree, out: ^[dynamic]Tree_Node, n: Tree_Node, lo, hi: u64) -> Error {
	first := n.start
	last := _node_last(t, n)
	if last < lo || first > hi {
		if _, e := append(out, n); e != nil {
			return .No_Memory
		}
		return .None
	}
	if first >= lo && last <= hi {
		return .None
	}
	seed := n.seed
	left, right := _ggm(&seed)
	defer {
		crypto.zero_explicit(&left, size_of(left))
		crypto.zero_explicit(&right, size_of(right))
		crypto.zero_explicit(&seed, size_of(seed))
	}
	half := u64(1) << (u64(t.depth) - u64(n.level) - 1)
	_keytree_split(t, out, Tree_Node{start = first, level = n.level + 1, seed = left}, lo, hi) or_return
	return _keytree_split(t, out, Tree_Node{start = first + half, level = n.level + 1, seed = right}, lo, hi)
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

draft_key :: proc(keys: journal.Key_Provider, msg: i64) -> (key: journal.Key, ok: bool) {
	if keys.key == nil || msg <= 0 {
		return
	}
	base: journal.Key
	if !keys.key(keys.data, (msg >> 4 + 1) << 4, &base) {
		return
	}
	defer crypto.zero_explicit(&base, size_of(base))
	m: [8]u8
	prim.put_u64le(m[:], u64(msg))
	_derive(base[:], "0ndb draft key", m[:], key[:])
	return key, true
}

buffer_live_key :: proc(keys: journal.Key_Provider, off: i64, boot: [16]u8) -> (key: journal.Key, ok: bool) {
	if keys.key == nil || off < 0 {
		return
	}
	base: journal.Key
	if !keys.key(keys.data, off, &base) {
		return
	}
	defer crypto.zero_explicit(&base, size_of(base))
	b := boot
	_derive(base[:], "0ndb buffer live key", b[:], key[:])
	return key, true
}

draft_puncture :: proc(t: ^Key_Tree, msg: i64) -> Error {
	if msg <= 0 {
		return .Invalid
	}
	cell := u64((msg >> 4 + 1) << 4) >> t.shift
	return keytree_puncture_cells(t, cell, cell)
}

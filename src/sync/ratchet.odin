package osync

import "base:intrinsics"
import "base:runtime"
import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/chacha20poly1305"
import "core:crypto/ecdh"
import "../prim"

SEALED_SECRET_LEN :: 32 + chacha20poly1305.TAG_SIZE
RATCHET_MAX_WIDTH :: 1 << 20

Ratchet_Node :: struct {
	present:  bool,
	pub:      Public_Key,
	sign:     Public_Key,
	unmerged: [dynamic]u32,
}

Ratchet_Tree :: struct {
	width:     u32,
	nodes:     [dynamic]Ratchet_Node,
	allocator: runtime.Allocator,
}

Path_Secret :: struct {
	node:   u32,
	secret: [32]u8,
}

Epoch_Keys :: struct {
	id:     Record_Id,
	number: u32,
	secret: [32]u8,
	path:   [dynamic]Path_Secret,
}

Commit_Set :: struct {
	leaf: u32,
	sign: Public_Key,
	box:  Public_Key,
}

Commit_Ct :: struct {
	target: u32,
	wrap:   []u8,
}

Commit_Path :: struct {
	node: u32,
	pub:  Public_Key,
	cts:  []Commit_Ct,
}

Commit_Back :: struct {
	epoch:  Record_Id,
	sealed: []u8,
}

Commit_Body :: struct {
	base:      Record_Id,
	number:    u32,
	history:   bool,
	width:     u32,
	blanks:    []u32,
	sets:      []Commit_Set,
	committer: u32,
	path:      []Commit_Path,
	naming:    [SEALED_SECRET_LEN]u8,
	backs:     []Commit_Back,
}

tree_init :: proc(t: ^Ratchet_Tree, width: u32 = 1, allocator := context.allocator) -> Error {
	if width == 0 || width & (width - 1) != 0 || width > RATCHET_MAX_WIDTH {
		return .Invalid
	}
	t.allocator = allocator
	t.width = width
	t.nodes = make([dynamic]Ratchet_Node, int(2 * width - 1), allocator)
	return .None
}

tree_destroy :: proc(t: ^Ratchet_Tree) {
	for &n in t.nodes {
		delete(n.unmerged)
	}
	delete(t.nodes)
	t^ = {}
}

tree_clone :: proc(dst: ^Ratchet_Tree, src: ^Ratchet_Tree, allocator := context.allocator) -> Error {
	tree_init(dst, src.width, allocator) or_return
	for n, i in src.nodes {
		dst.nodes[i].present = n.present
		dst.nodes[i].pub = n.pub
		dst.nodes[i].sign = n.sign
		if len(n.unmerged) > 0 {
			dst.nodes[i].unmerged = make([dynamic]u32, 0, len(n.unmerged), allocator)
			append(&dst.nodes[i].unmerged, ..n.unmerged[:])
		}
	}
	return .None
}

tree_root :: proc "contextless" (t: ^Ratchet_Tree) -> u32 {
	return t.width - 1
}

node_level :: proc "contextless" (x: u32) -> u32 {
	return u32(intrinsics.count_trailing_zeros(~x))
}

node_parent :: proc "contextless" (x: u32) -> u32 {
	k := node_level(x)
	if (x >> (k + 1)) & 1 == 0 {
		return x + (1 << k)
	}
	return x - (1 << k)
}

node_left :: proc "contextless" (x: u32) -> u32 {
	k := node_level(x)
	return x ~ (1 << (k - 1))
}

node_right :: proc "contextless" (x: u32) -> u32 {
	k := node_level(x)
	return x ~ (3 << (k - 1))
}

node_sibling :: proc "contextless" (x: u32) -> u32 {
	p := node_parent(x)
	l := node_left(p)
	return node_right(p) if l == x else l
}

node_covers :: proc "contextless" (x: u32, leaf: u32) -> bool {
	k := node_level(x)
	n := leaf * 2
	lo := x - ((1 << k) - 1)
	hi := x + ((1 << k) - 1)
	return n >= lo && n <= hi
}

tree_leaves :: proc "contextless" (t: ^Ratchet_Tree) -> int {
	n := 0
	for i := u32(0); i < t.width; i += 1 {
		if t.nodes[2 * i].present {
			n += 1
		}
	}
	return n
}

tree_find_leaf :: proc "contextless" (t: ^Ratchet_Tree, sign: Public_Key) -> (leaf: u32, ok: bool) {
	for i := u32(0); i < t.width; i += 1 {
		n := &t.nodes[2 * i]
		if n.present && n.sign == sign {
			return i, true
		}
	}
	return 0, false
}

tree_free_leaf :: proc(t: ^Ratchet_Tree, taken: []u32) -> u32 {
	outer: for i := u32(0); i < t.width; i += 1 {
		if t.nodes[2 * i].present {
			continue
		}
		for x in taken {
			if x == i {
				continue outer
			}
		}
		return i
	}
	w := t.width
	for x in taken {
		w = max(w, x + 1)
	}
	return w
}

tree_extend :: proc(t: ^Ratchet_Tree, leaves: u32) -> Error {
	if leaves > RATCHET_MAX_WIDTH {
		return .Too_Large
	}
	for t.width < leaves {
		old := len(t.nodes)
		t.width *= 2
		resize(&t.nodes, int(2 * t.width - 1))
		for i in old ..< len(t.nodes) {
			t.nodes[i] = {}
		}
	}
	return .None
}

tree_blank_leaf :: proc(t: ^Ratchet_Tree, leaf: u32) {
	if leaf >= t.width {
		return
	}
	x := leaf * 2
	t.nodes[x].present = false
	t.nodes[x].pub = {}
	t.nodes[x].sign = {}
	root := tree_root(t)
	for x != root {
		x = node_parent(x)
		t.nodes[x].present = false
		t.nodes[x].pub = {}
		clear(&t.nodes[x].unmerged)
	}
	for &n in t.nodes {
		for i := 0; i < len(n.unmerged); {
			if n.unmerged[i] == leaf {
				ordered_remove(&n.unmerged, i)
			} else {
				i += 1
			}
		}
	}
}

tree_set_leaf :: proc(t: ^Ratchet_Tree, leaf: u32, sign, box: Public_Key) -> Error {
	tree_extend(t, leaf + 1) or_return
	x := leaf * 2
	t.nodes[x].present = true
	t.nodes[x].pub = box
	t.nodes[x].sign = sign
	root := tree_root(t)
	for x != root {
		x = node_parent(x)
		n := &t.nodes[x]
		if !n.present {
			continue
		}
		found := false
		for u in n.unmerged {
			if u == leaf {
				found = true
			}
		}
		if !found {
			if n.unmerged == nil {
				n.unmerged = make([dynamic]u32, t.allocator)
			}
			append(&n.unmerged, leaf)
		}
	}
	return .None
}

tree_resolution :: proc(t: ^Ratchet_Tree, x: u32, out: ^[dynamic]u32) {
	n := &t.nodes[x]
	if n.present {
		append(out, x)
		for u in n.unmerged {
			append(out, u * 2)
		}
		return
	}
	if node_level(x) == 0 {
		return
	}
	tree_resolution(t, node_left(x), out)
	tree_resolution(t, node_right(x), out)
}

tree_hash :: proc(t: ^Ratchet_Tree) -> (h: [32]u8) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	w: [4]u8
	prim.put_u32le(w[:], t.width)
	blake2b.update(&ctx, w[:])
	for &n in t.nodes {
		if !n.present {
			blake2b.update(&ctx, {0})
			continue
		}
		blake2b.update(&ctx, {1})
		blake2b.update(&ctx, n.pub[:])
		blake2b.update(&ctx, n.sign[:])
		for u in n.unmerged {
			prim.put_u32le(w[:], u)
			blake2b.update(&ctx, w[:])
		}
	}
	blake2b.final(&ctx, h[:])
	return
}

epoch_keys_clear :: proc(k: ^Epoch_Keys) {
	for &p in k.path {
		crypto.zero_explicit(&p.secret, size_of(p.secret))
	}
	delete(k.path)
	crypto.zero_explicit(&k.secret, size_of(k.secret))
	k^ = {}
}

epoch_content_key :: proc(secret: ^[32]u8, number: u32) -> (k: Content_Key) {
	n: [4]u8
	prim.put_u32le(n[:], number)
	_derive(secret[:], "0ndb epoch content", n[:], k.key[:])
	k.epoch = number
	return
}

object_epoch_key :: proc(secret: ^[32]u8, number: u32, oid: []u8) -> (k: [32]u8) {
	c := epoch_content_key(secret, number)
	defer crypto.zero_explicit(&c, size_of(c))
	_derive(c.key[:], "0ndb object epoch", oid, k[:])
	return
}

aead_seal :: proc(key: []u8, aad: []u8, plain: []u8, out: []u8) {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key)
	defer chacha20poly1305.reset(&ctx)
	iv: [12]u8
	chacha20poly1305.seal(&ctx, out[:len(plain)], out[len(plain):][:16], iv[:], aad, plain)
}

aead_open :: proc(key: []u8, aad: []u8, sealed: []u8, out: []u8) -> bool {
	if len(sealed) != len(out) + 16 {
		return false
	}
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key)
	defer chacha20poly1305.reset(&ctx)
	iv: [12]u8
	return chacha20poly1305.open(&ctx, out, iv[:], aad, sealed[:len(out)], sealed[len(out):])
}

seal_secret :: proc(epoch_secret: ^[32]u8, label: string, ctx_bytes: []u8, secret: ^[32]u8) -> (out: [SEALED_SECRET_LEN]u8) {
	k: [32]u8
	defer crypto.zero_explicit(&k, size_of(k))
	_derive(epoch_secret[:], label, ctx_bytes, k[:])
	aead_seal(k[:], ctx_bytes, secret[:], out[:])
	return
}

open_secret :: proc(epoch_secret: ^[32]u8, label: string, ctx_bytes: []u8, sealed: []u8, secret: ^[32]u8) -> bool {
	k: [32]u8
	defer crypto.zero_explicit(&k, size_of(k))
	_derive(epoch_secret[:], label, ctx_bytes, k[:])
	return aead_open(k[:], ctx_bytes, sealed, secret[:])
}

commit_decode :: proc(payload: []u8, b: ^Commit_Body, allocator := context.temp_allocator) -> Error {
	r := prim.reader(payload)
	prim.read_fixed(&r, b.base[:])
	b.number = prim.read_u32le(&r)
	b.history = prim.read_bool(&r)
	b.width = prim.read_u32le(&r)
	if !prim.reader_ok(&r) || b.width == 0 || b.width & (b.width - 1) != 0 || b.width > RATCHET_MAX_WIDTH {
		return .Corrupt
	}
	nb := prim.read_uvarint(&r)
	if nb > u64(b.width) {
		return .Corrupt
	}
	b.blanks = make([]u32, int(nb), allocator)
	for i in 0 ..< int(nb) {
		b.blanks[i] = u32(prim.read_uvarint(&r))
	}
	ns := prim.read_uvarint(&r)
	if ns > u64(b.width) {
		return .Corrupt
	}
	b.sets = make([]Commit_Set, int(ns), allocator)
	for i in 0 ..< int(ns) {
		b.sets[i].leaf = u32(prim.read_uvarint(&r))
		prim.read_fixed(&r, b.sets[i].sign[:])
		prim.read_fixed(&r, b.sets[i].box[:])
		if b.sets[i].leaf >= b.width {
			return .Corrupt
		}
	}
	b.committer = u32(prim.read_uvarint(&r))
	np := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || np > 32 || b.committer >= b.width {
		return .Corrupt
	}
	b.path = make([]Commit_Path, int(np), allocator)
	for i in 0 ..< int(np) {
		p := &b.path[i]
		p.node = u32(prim.read_uvarint(&r))
		prim.read_fixed(&r, p.pub[:])
		nc := prim.read_uvarint(&r)
		if !prim.reader_ok(&r) || nc > u64(prim.reader_remaining(&r) / WRAP_LEN) || p.node >= 2 * b.width - 1 {
			return .Corrupt
		}
		p.cts = make([]Commit_Ct, int(nc), allocator)
		for j in 0 ..< int(nc) {
			p.cts[j].target = u32(prim.read_uvarint(&r))
			p.cts[j].wrap = prim.read_raw(&r, WRAP_LEN)
		}
	}
	prim.read_fixed(&r, b.naming[:])
	nk := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || nk > u64(prim.reader_remaining(&r) / (32 + SEALED_SECRET_LEN)) {
		return .Corrupt
	}
	b.backs = make([]Commit_Back, int(nk), allocator)
	for i in 0 ..< int(nk) {
		prim.read_fixed(&r, b.backs[i].epoch[:])
		b.backs[i].sealed = prim.read_raw(&r, SEALED_SECRET_LEN)
	}
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

commit_encode :: proc(b: ^Commit_Body, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_raw(&w, b.base[:])
	prim.write_u32le(&w, b.number)
	prim.write_bool(&w, b.history)
	prim.write_u32le(&w, b.width)
	prim.write_uvarint(&w, u64(len(b.blanks)))
	for x in b.blanks {
		prim.write_uvarint(&w, u64(x))
	}
	prim.write_uvarint(&w, u64(len(b.sets)))
	for &s in b.sets {
		prim.write_uvarint(&w, u64(s.leaf))
		prim.write_raw(&w, s.sign[:])
		prim.write_raw(&w, s.box[:])
	}
	prim.write_uvarint(&w, u64(b.committer))
	prim.write_uvarint(&w, u64(len(b.path)))
	for &p in b.path {
		prim.write_uvarint(&w, u64(p.node))
		prim.write_raw(&w, p.pub[:])
		prim.write_uvarint(&w, u64(len(p.cts)))
		for c in p.cts {
			prim.write_uvarint(&w, u64(c.target))
			prim.write_raw(&w, c.wrap)
		}
	}
	prim.write_raw(&w, b.naming[:])
	prim.write_uvarint(&w, u64(len(b.backs)))
	for &k in b.backs {
		prim.write_raw(&w, k.epoch[:])
		prim.write_raw(&w, k.sealed)
	}
	return .No_Memory if w.err != .None else .None
}

commit_apply_delta :: proc(t: ^Ratchet_Tree, b: ^Commit_Body) -> Error {
	if b.width < t.width {
		return .Corrupt
	}
	tree_extend(t, b.width) or_return
	for x in b.blanks {
		if x >= t.width {
			return .Corrupt
		}
		tree_blank_leaf(t, x)
	}
	for &s in b.sets {
		if t.nodes[2 * s.leaf].present {
			tree_blank_leaf(t, s.leaf)
		}
		tree_set_leaf(t, s.leaf, s.sign, s.box) or_return
	}
	if !t.nodes[2 * b.committer].present {
		return .Corrupt
	}
	return .None
}

commit_apply_path :: proc(t: ^Ratchet_Tree, b: ^Commit_Body) -> Error {
	x := b.committer * 2
	root := tree_root(t)
	i := 0
	for x != root {
		x = node_parent(x)
		if i >= len(b.path) || b.path[i].node != x {
			return .Corrupt
		}
		n := &t.nodes[x]
		n.present = true
		n.pub = b.path[i].pub
		n.sign = {}
		clear(&n.unmerged)
		i += 1
	}
	if i != len(b.path) {
		return .Corrupt
	}
	return .None
}

@(private)
_node_keypair :: proc(ps: ^[32]u8, priv: ^ecdh.Private_Key, pub: ^Public_Key) -> bool {
	seed: [32]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	_derive(ps[:], "0ndb node", nil, seed[:])
	if !ecdh.private_key_set_bytes(priv, .X25519, seed[:]) {
		return false
	}
	ecdh.private_key_public_bytes(priv, pub[:])
	return true
}

@(private)
_next_path :: proc(ps: ^[32]u8) -> (next: [32]u8) {
	_derive(ps[:], "0ndb path", nil, next[:])
	return
}

@(private)
_epoch_secret :: proc(root_ps: ^[32]u8, space: Space_Id, base: Record_Id, number: u32) -> (s: [32]u8) {
	ctx: [16 + 32 + 4]u8
	sp, bs := space, base
	copy(ctx[:16], sp[:])
	copy(ctx[16:48], bs[:])
	prim.put_u32le(ctx[48:], number)
	_derive(root_ps[:], "0ndb epoch", ctx[:], s[:])
	return
}

Commit_Input :: struct {
	space:     Space_Id,
	base:      Record_Id,
	number:    u32,
	history:   bool,
	blanks:    []u32,
	sets:      []Commit_Set,
	committer: u32,
	naming:    ^[32]u8,
	backs:     []Epoch_Keys,
	random:    prim.Random,
}

commit_create :: proc(t: ^Ratchet_Tree, in_: Commit_Input, out: ^[dynamic]u8, keys: ^Epoch_Keys, allocator := context.allocator) -> Error {
	b := Commit_Body {
		base      = in_.base,
		number    = in_.number,
		history   = in_.history,
		blanks    = in_.blanks,
		sets      = in_.sets,
		committer = in_.committer,
	}
	need := t.width
	for s in in_.sets {
		need = max(need, s.leaf + 1)
	}
	for need & (need - 1) != 0 {
		need += 1
	}
	b.width = max(t.width, need)
	commit_apply_delta(t, &b) or_return
	root := tree_root(t)
	path := make([dynamic]Commit_Path, 0, 32, context.temp_allocator)
	keys.path = make([dynamic]Path_Secret, 0, 32, allocator)
	ps: [32]u8
	defer crypto.zero_explicit(&ps, size_of(ps))
	prim.random_fill(in_.random, ps[:])
	x := in_.committer * 2
	res := make([dynamic]u32, 0, 64, context.temp_allocator)
	for x != root {
		child := x
		x = node_parent(x)
		cop := node_sibling(child)
		priv: ecdh.Private_Key
		p := Commit_Path{node = x}
		if !_node_keypair(&ps, &priv, &p.pub) {
			return .Invalid
		}
		ecdh.private_key_clear(&priv)
		clear(&res)
		tree_resolution(t, cop, &res)
		cts := make([]Commit_Ct, len(res), context.temp_allocator)
		for target, j in res {
			n := &t.nodes[target]
			rid := Identity{sign = n.sign, box = n.pub}
			ck := Content_Key{key = ps, epoch = x}
			wrap := new([WRAP_LEN]u8, context.temp_allocator)
			e := seal_key_to(&rid, &ck, wrap, in_.random)
			crypto.zero_explicit(&ck, size_of(ck))
			if e != .None {
				return e
			}
			cts[j] = Commit_Ct{target = target, wrap = wrap[:]}
		}
		p.cts = cts
		append(&path, p)
		append(&keys.path, Path_Secret{node = x, secret = ps})
		nx := _next_path(&ps)
		ps = nx
		crypto.zero_explicit(&nx, size_of(nx))
	}
	b.path = path[:]
	commit_apply_path(t, &b) or_return
	keys.number = in_.number
	keys.secret = _epoch_secret(&ps, in_.space, in_.base, in_.number)
	ctx := _naming_ctx(in_.space, in_.number)
	b.naming = seal_secret(&keys.secret, "0ndb naming", ctx[:], in_.naming)
	backs := make([]Commit_Back, len(in_.backs), context.temp_allocator)
	for &bk, i in in_.backs {
		s := new([SEALED_SECRET_LEN]u8, context.temp_allocator)
		s^ = seal_secret(&keys.secret, "0ndb back", bk.id[:], &bk.secret)
		backs[i] = Commit_Back{epoch = bk.id, sealed = s[:]}
	}
	b.backs = backs
	return commit_encode(&b, out)
}

Commit_Opener :: struct {
	keyring: ^Keyring,
	self:    Identity,
	base:    ^Epoch_Keys,
}

commit_open :: proc(t: ^Ratchet_Tree, b: ^Commit_Body, space: Space_Id, o: Commit_Opener, keys: ^Epoch_Keys, allocator := context.allocator) -> Error {
	commit_apply_delta(t, b) or_return
	mine, have := tree_find_leaf(t, o.self.sign)
	if !have {
		commit_apply_path(t, b) or_return
		return .Permission
	}
	if mine == b.committer {
		commit_apply_path(t, b) or_return
		return .Exists
	}
	lca := b.committer * 2
	for !node_covers(lca, mine) {
		lca = node_parent(lca)
	}
	pi := -1
	for p, i in b.path {
		if p.node == lca {
			pi = i
		}
	}
	if pi < 0 {
		return .Corrupt
	}
	ps: [32]u8
	defer crypto.zero_explicit(&ps, size_of(ps))
	got := false
	for c in b.path[pi].cts {
		if got {
			break
		}
		if !node_covers(c.target, mine) || c.target >= u32(len(t.nodes)) {
			continue
		}
		ck: Content_Key
		if c.target == mine * 2 {
			if o.keyring.unwrap(o.keyring.data, c.wrap, &ck) == .None && ck.epoch == lca {
				ps = ck.key
				got = true
			}
		} else if o.base != nil {
			for &s in o.base.path {
				if s.node != c.target {
					continue
				}
				priv: ecdh.Private_Key
				pub: Public_Key
				if _node_keypair(&s.secret, &priv, &pub) && pub == t.nodes[c.target].pub {
					nid := Identity{box = pub}
					if open_key_from(&nid, &priv, c.wrap, &ck) == .None && ck.epoch == lca {
						ps = ck.key
						got = true
					}
				}
				ecdh.private_key_clear(&priv)
			}
		}
		crypto.zero_explicit(&ck, size_of(ck))
	}
	if !got {
		commit_apply_path(t, b) or_return
		return .Auth
	}
	keys.path = make([dynamic]Path_Secret, 0, 32, allocator)
	if o.base != nil {
		for s in o.base.path {
			if !node_covers(s.node, b.committer) && t.nodes[s.node].present {
				append(&keys.path, s)
			}
		}
	}
	for i in pi ..< len(b.path) {
		priv: ecdh.Private_Key
		pub: Public_Key
		ok := _node_keypair(&ps, &priv, &pub)
		ecdh.private_key_clear(&priv)
		if !ok || pub != b.path[i].pub {
			epoch_keys_clear(keys)
			return .Corrupt
		}
		append(&keys.path, Path_Secret{node = b.path[i].node, secret = ps})
		nx := _next_path(&ps)
		ps = nx
		crypto.zero_explicit(&nx, size_of(nx))
	}
	commit_apply_path(t, b) or_return
	keys.number = b.number
	keys.secret = _epoch_secret(&ps, space, b.base, b.number)
	return .None
}

commit_naming :: proc(b: ^Commit_Body, space: Space_Id, keys: ^Epoch_Keys, naming: ^[32]u8) -> bool {
	ctx := _naming_ctx(space, b.number)
	return open_secret(&keys.secret, "0ndb naming", ctx[:], b.naming[:], naming)
}

commit_back :: proc(b: ^Commit_Body, keys: ^Epoch_Keys, epoch: Record_Id, out: ^[32]u8) -> bool {
	for &k in b.backs {
		if k.epoch == epoch {
			e := epoch
			return open_secret(&keys.secret, "0ndb back", e[:], k.sealed, out)
		}
	}
	return false
}

@(private)
_naming_ctx :: proc(space: Space_Id, number: u32) -> (ctx: [20]u8) {
	s := space
	copy(ctx[:16], s[:])
	prim.put_u32le(ctx[16:], number)
	return
}

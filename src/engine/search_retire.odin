package engine

import "core:crypto"
import "core:crypto/blake2b"
import omap "../map"
import "../prim"
import "../search"
import osync "../sync"

@(private)
SEARCH_KEY_SOURCE :: u8(0xf3)
@(private)
SEARCH_KEY_CHAIN :: u8(0xf4)
@(private)
SEARCH_KEY_RESTORE :: u8(0xf5)
@(private)
SEARCH_KEY_REDACT :: u8(0xf6)
@(private)
SEARCH_KEY_REBUILT :: u8(0xf7)
@(private)
SEARCH_KEY_ADVERTISED :: u8(0xf8)
@(private)
RETIRED_HISTORY :: "0ndb:search"
@(private)
RETIRED_DOMAIN :: "0ndb search snapshot v1"
@(private)
RETIRED_VERSION :: u8(1)

@(private)
_search_key :: proc(tag: u8, space: prim.Id) -> (k: [17]u8) {
	s := space
	k[0] = tag
	copy(k[1:], s[:])
	return
}

@(private)
_retired_dir :: proc(e: ^Engine, space: prim.Id) -> (string, Error) {
	hx := prim.id_hex(space)
	return _join(context.temp_allocator, e.pack_root, "search-snap", string(hx[:]))
}

@(private)
_retired_tree :: proc(sp: ^Space, t: ^osync.Key_Tree) -> Error {
	root: [32]u8
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, sp.scope.object_key[:], 32)
	blake2b.update(&ctx, transmute([]u8)string(RETIRED_DOMAIN))
	x := sp.id
	blake2b.update(&ctx, x[:])
	blake2b.final(&ctx, root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return _serr(osync.keytree_init(t, root, osync.OBJECT_TREE_DEPTH, 0))
}

@(private)
Retired_Chain :: struct {
	zeroed: i64,
	mine:   [dynamic][32]u8,
}

@(private)
_retired_chain :: proc(v: []u8) -> (c: Retired_Chain, ok: bool) {
	c.mine = make([dynamic][32]u8, context.temp_allocator)
	r := prim.reader(v)
	if prim.read_u8(&r) != RETIRED_VERSION {
		return c, false
	}
	prim.read_u8(&r)
	prim.read_u64le(&r)
	prim.read_u64le(&r)
	prim.read_u64le(&r)
	prim.read_u64le(&r)
	c.zeroed = i64(prim.read_u64le(&r))
	n := int(prim.read_u16le(&r))
	for _ in 0 ..< n {
		prim.read_u64le(&r)
		prim.read_u64le(&r)
		prim.read_u32le(&r)
		prim.read_u64le(&r)
		oid: [32]u8
		copy(oid[:], prim.read_raw(&r, 32))
		if prim.read_u8(&r) != 0 {
			append(&c.mine, oid)
		}
	}
	return c, prim.reader_ok(&r)
}

@(private)
_search_restore_interrupted :: proc(e: ^Engine) -> bool {
	found := false
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		(^bool)(data)^ = true
		return false
	}
	pfx := [1]u8{SEARCH_KEY_RESTORE}
	omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &found, visit)
	return found
}

@(private)
_search_drop_markers :: proc(e: ^Engine) -> Error {
	Collect :: struct {
		keys: [dynamic][]u8,
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		c := (^Collect)(data)
		k := make([]u8, len(key), context.temp_allocator)
		copy(k, key)
		append(&c.keys, k)
		return true
	}
	c := Collect{keys = make([dynamic][]u8, context.temp_allocator)}
	for tag in ([?]u8{SEARCH_KEY_RESTORE, SEARCH_KEY_REBUILT}) {
		pfx := [1]u8{tag}
		omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &c, visit)
	}
	if len(c.keys) == 0 {
		return .None
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	for k in c.keys {
		if _, err := omap.txn_delete(t, ROOT_SEARCH, k); err != .None {
			omap.txn_abort(t)
			return _oerr(err)
		}
	}
	return _reg_commit(e, t)
}

search_indexing :: proc(e: ^Engine) -> bool {
	context = context_for(e)
	if !e.index_open {
		return false
	}
	if len(e.index_dirty) > 0 || search.pending(&e.index) > 0 {
		return true
	}
	r := &e.remote
	return r.init && len(r.active) > 0
}

@(private)
_search_retire :: proc(e: ^Engine, sp: ^Space) {
	r := _remote(e)
	if r.retired[sp.id] || !sp.repl_on || !sp.connected || !sp.mem.have_naming {
		return
	}
	Collect :: struct {
		keys: [dynamic][]u8,
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		c := (^Collect)(data)
		k := make([]u8, len(key), context.temp_allocator)
		copy(k, key)
		append(&c.keys, k)
		return true
	}
	c := Collect{keys = make([dynamic][]u8, context.temp_allocator)}
	for tag in ([?]u8{SEARCH_KEY_SOURCE, SEARCH_KEY_CHAIN, SEARCH_KEY_REDACT}) {
		pfx := _search_key(tag, sp.id)
		omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &c, visit)
	}
	ck := _search_key(SEARCH_KEY_CHAIN, sp.id)
	if v, hit, err := omap.db_get(&e.reg.db, ROOT_SEARCH, ck[:], context.temp_allocator); err != .None {
		return
	} else if hit {
		chain, ok := _retired_chain(v)
		if ok && len(chain.mine) > 0 {
			tree: osync.Key_Tree
			if _retired_tree(sp, &tree) != .None {
				return
			}
			defer osync.keytree_destroy(&tree)
			for oid in chain.mine {
				o := oid
				osync.replicator_shred_object(&sp.repl, &sp.scope, &tree, o[:])
			}
		}
		n, lerr := osync.replicator_checkpoint_length(&sp.repl, &sp.scope, RETIRED_HISTORY)
		if lerr != .None {
			return
		}
		if ok && n > chain.zeroed {
			if osync.replicator_checkpoint_redact(&sp.repl, &sp.scope, RETIRED_HISTORY, chain.zeroed, n) != .None {
				return
			}
		}
	}
	dir, derr := _retired_dir(e, sp.id)
	if derr != .None || _erase_path(e.vfs, dir) != .None {
		return
	}
	if len(c.keys) > 0 {
		t, terr := omap.txn_begin(&e.reg.db)
		if terr != .None {
			return
		}
		for k in c.keys {
			if _, err := omap.txn_delete(t, ROOT_SEARCH, k); err != .None {
				omap.txn_abort(t)
				return
			}
		}
		if _reg_commit(e, t) != .None {
			return
		}
	}
	r.retired[sp.id] = true
}

@(private)
_search_retired_checkpoint :: proc(e: ^Engine, ev: ^osync.Repl_Event) -> bool {
	if ev.name != osync.CHECKPOINT_STREAM + RETIRED_HISTORY {
		return false
	}
	if ev.kind == .Checkpoint && len(ev.path) > 0 {
		prim.remove(e.vfs, ev.path)
	}
	return true
}

@(private)
_index_relay_zeroed :: proc(e: ^Engine, sp: ^Space, object: prim.Id, device: prim.Id, from, to: i64) {
	if !_full_on(e, sp) || !e.index_open {
		return
	}
	src := _source_id(object, device)
	pos, _ := search.position(&e.index, src)
	search.redact_span(&e.index, src, pos, object, device, u64(from), u64(to))
}

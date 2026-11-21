package engine

import "core:crypto"
import omap "../map"
import "../prim"
import osync "../sync"

@(private)
ROOT_GRANTS :: 5
SHARE_CARDS :: 16

Share :: struct {
	cards:   [SHARE_CARDS][osync.CARD_LEN]u8,
	ncards:  int,
	from:    prim.Id,
	access:  Access_Set,
	space:   prim.Id,
	object:  prim.Id,
	kind:    Kind,
	wrapped: [osync.WRAP_LEN]u8,
}

object_key :: proc(e: ^Engine, o: Object) -> (key: osync.Content_Key, err: Error) {
	sp := _space_open(e, o.space) or_return
	if g, ok := _grant_get(e, sp, o.id); ok {
		return g, .None
	}
	if o.id == sp.catalog {
		return sp.scope.content, .None
	}
	x := o.id
	k := osync.object_content_key(&sp.scope, x[:])
	return osync.Content_Key{key = k, epoch = 0}, .None
}

share_object :: proc(e: ^Engine, o: Object, recipient: osync.Identity, access := Access_Set{.Read, .Write}) -> (s: Share, err: Error) {
	key := object_key(e, o) or_return
	defer crypto.zero_explicit(&key, size_of(key))
	rec, found := _rec_get(e, o.id) or_return
	if !found {
		return s, .Not_Found
	}
	r := recipient
	_serr(e.keyring.wrap(e.keyring.data, &r, &key, &s.wrapped)) or_return
	s.from = e.self
	s.access = access
	s.space = o.space
	s.object = o.id
	s.kind = rec.kind
	if card, cerr := osync.keyring_card(&e.keyring); cerr == .None {
		s.cards[0] = card
		s.ncards = 1
	}
	for m in rec.members {
		if s.ncards >= SHARE_CARDS {
			break
		}
		k := _card_key(e.spaces[o.space], m.device) if o.space in e.spaces else [32]u8{}
		v, hit, gerr := omap.db_get(&e.reg.db, ROOT_CARDS, k[:], context.temp_allocator)
		if gerr == .None && hit && len(v) == osync.CARD_LEN {
			copy(s.cards[s.ncards][:], v)
			s.ncards += 1
		}
	}
	if sp, ok := e.spaces[o.space]; ok && sp.open {
		_card_publish_object(e, sp, o.id)
		_shared_follow(e, sp, o.id, rec.kind)
		for m in rec.members {
			_card_relay(e, sp, o.id, m.device)
		}
	}
	return s, .None
}

accept_share :: proc(e: ^Engine, share: Share) -> Error {
	s := share
	sp, ok := e.spaces[s.space]
	if !ok {
		return .Not_Found
	}
	key: osync.Content_Key
	_serr(e.keyring.unwrap(e.keyring.data, s.wrapped[:], &key)) or_return
	defer crypto.zero_explicit(&key, size_of(key))
	k := _grant_key(s.space, s.object)
	v: [2 + osync.WRAP_LEN]u8
	v[0] = u8(s.kind)
	v[1] = transmute(u8)s.access
	copy(v[2:], s.wrapped[:])
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	if err := omap.txn_put(t, ROOT_GRANTS, k[:], v[:]); err != .None {
		omap.txn_abort(t)
		return _oerr(err)
	}
	_oerr(omap.txn_commit(t)) or_return
	if sp.open {
		sp.grants[s.object] = key
		sp.grant_access[s.object] = s.access
		_card_publish_object(e, sp, s.object)
	}
	rec, found := _rec_get(e, s.object) or_return
	if !found {
		rec = Obj_Rec{space = s.space, kind = s.kind, members = make([dynamic]Member, context.temp_allocator)}
	}
	if s.from != e.self && _rec_member(&rec, s.from) < 0 {
		append(&rec.members, Member{device = s.from})
	}
	for i in 0 ..< min(s.ncards, SHARE_CARDS) {
		_card_store(e, sp, s.cards[i][:])
	}
	_rec_put(e, s.object, &rec) or_return
	if sp.open {
		_shared_follow(e, sp, s.object, s.kind)
	}
	return .None
}

@(private)
_grant_key :: proc(space: prim.Id, object: prim.Id) -> (k: [32]u8) {
	a, b := space, object
	copy(k[:16], a[:])
	copy(k[16:], b[:])
	return
}

@(private)
_grant_get :: proc(e: ^Engine, sp: ^Space, object: prim.Id) -> (key: osync.Content_Key, ok: bool) {
	if sp.open {
		key, ok = sp.grants[object]
	}
	return
}

@(private)
_grants_load :: proc(e: ^Engine, sp: ^Space) {
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		s := (^Space)(data)
		if len(key) != 32 || len(value) != 2 + osync.WRAP_LEN {
			return true
		}
		ck: osync.Content_Key
		if s.e.keyring.unwrap(s.e.keyring.data, value[2:], &ck) != .None {
			return true
		}
		id: prim.Id
		copy(id[:], key[16:])
		s.grants[id] = ck
		s.grant_access[id] = transmute(Access_Set)value[1]
		return true
	}
	a := sp.id
	omap.db_scan(&e.reg.db, ROOT_GRANTS, a[:], a[:], sp, visit)
}

space_join_shared :: proc(e: ^Engine, space: prim.Id, name := "", relay := "", relay_public: osync.Public_Key = {}) -> Error {
	if _, ok := e.spaces[space]; ok {
		return .Exists
	}
	sp := new(Space, e.allocator)
	sp.e = e
	sp.id = space
	sp.keyless = true
	sp.catalog = _catalog_id(space)
	sp.name = _clone(name, e.allocator) or_return
	sp.relay = _clone(relay, e.allocator) or_return
	sp.relay_public = relay_public
	e.spaces[space] = sp
	if err := _space_store(e, sp); err != .None {
		delete_key(&e.spaces, space)
		_space_free(e, sp)
		return err
	}
	return .None
}

@(private)
_shared_follow :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind) {
	if !sp.repl_on {
		return
	}
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	osync.replicator_follow_segments(&sp.repl, &sc, _seg_name(kind, id), 0, kind != .Conversation)
}

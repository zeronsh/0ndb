package engine

import "core:crypto"
import "core:crypto/ed25519"
import omap "../map"
import "../prim"
import osync "../sync"

@(private)
ROOT_GRANTS :: 5
@(private)
CAP_VERSION :: 1
@(private)
CAP_DOMAIN :: "0ndb-capability-v1"

Access :: enum u8 {
	Read,
	Write,
	Redact,
	Share,
}

Access_Set :: bit_set[Access;u8]

Capability :: struct {
	space:   prim.Id,
	grantee: prim.Id,
	object:  prim.Id,
	kind:    Kind,
	access:  Access_Set,
	expires: i64,
}

CAPABILITY_LEN :: 1 + 16 * 3 + 1 + 1 + 8 + 32 + 64

Share :: struct {
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

share_object :: proc(e: ^Engine, o: Object, recipient: osync.Identity) -> (s: Share, err: Error) {
	key := object_key(e, o) or_return
	defer crypto.zero_explicit(&key, size_of(key))
	rec, found := _rec_get(e, o.id) or_return
	if !found {
		return s, .Not_Found
	}
	r := recipient
	_serr(e.keyring.wrap(e.keyring.data, &r, &key, &s.wrapped)) or_return
	s.space = o.space
	s.object = o.id
	s.kind = rec.kind
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
	v: [1 + osync.WRAP_LEN]u8
	v[0] = u8(s.kind)
	copy(v[1:], s.wrapped[:])
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
	}
	rec, found := _rec_get(e, s.object) or_return
	if !found {
		rec = Obj_Rec{space = s.space, kind = s.kind, members = make([dynamic]Member, context.temp_allocator)}
		_rec_put(e, s.object, &rec) or_return
	}
	return .None
}

capability_issue :: proc(e: ^Engine, c: Capability, allocator := context.allocator) -> (token: []u8, err: Error) {
	sp := _space_open(e, c.space) or_return
	if c.space != sp.id {
		return nil, .Invalid
	}
	token = make([]u8, CAPABILITY_LEN, allocator)
	n := _cap_body(c, token)
	copy(token[n:], sp.keys.auth_public[:])
	n += 32
	ed25519.sign(&sp.keys.auth, token[:n], token[n:])
	return token, .None
}

capability_verify :: proc(token: []u8, now_ms: i64) -> (c: Capability, ok: bool) {
	if len(token) != CAPABILITY_LEN || token[0] != CAP_VERSION {
		return
	}
	r := prim.reader(token[1:])
	c.space = prim.read_id(&r)
	c.grantee = prim.read_id(&r)
	c.object = prim.read_id(&r)
	k := prim.read_u8(&r)
	a := prim.read_u8(&r)
	c.expires = i64(prim.read_u64le(&r))
	pub: osync.Public_Key
	prim.read_fixed(&r, pub[:])
	if !prim.reader_ok(&r) || k > u8(max(Kind)) {
		return {}, false
	}
	c.kind = Kind(k)
	c.access = transmute(Access_Set)a
	if osync.space_id(pub) != c.space {
		return {}, false
	}
	body := token[:CAPABILITY_LEN - 64]
	if !osync.signature_verify(pub, body, token[CAPABILITY_LEN - 64:]) {
		return {}, false
	}
	if c.expires != 0 && now_ms > c.expires {
		return {}, false
	}
	return c, true
}

@(private)
_cap_body :: proc(c: Capability, out: []u8) -> int {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, CAP_VERSION)
	prim.write_id(&w, c.space)
	prim.write_id(&w, c.grantee)
	prim.write_id(&w, c.object)
	prim.write_u8(&w, u8(c.kind))
	prim.write_u8(&w, transmute(u8)c.access)
	prim.write_u64le(&w, u64(c.expires))
	return copy(out, buf[:])
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
		if len(key) != 32 || len(value) != 1 + osync.WRAP_LEN {
			return true
		}
		ck: osync.Content_Key
		if s.e.keyring.unwrap(s.e.keyring.data, value[1:], &ck) != .None {
			return true
		}
		id: prim.Id
		copy(id[:], key[16:])
		s.grants[id] = ck
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

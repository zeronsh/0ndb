package osync

import "../arc"
import "base:runtime"
import "core:crypto/blake2b"
import "../prim"

CAP_TOKEN_VERSION :: u8(2)
CAP_TOKEN_LEN :: 1 + 16 * 3 + 1 + 1 + 8 + 32 + 32 + 64
CAP_CREDENTIAL :: u8(2)
CAP_CREDENTIALS :: u8(3)
CAP_TOKENS_MAX :: 16
CAP_PROBE_EPOCHS :: 8
CAP_KEYS_EPOCHS :: 256
CAP_CACHE :: 1024
CAP_READ :: u8(1)
CAP_WRITE :: u8(2)
CAP_REDACT :: u8(4)
CARD_STREAM :: "card"

Cap_Token :: struct {
	space:    prim.Id,
	grantee:  prim.Id,
	object:   prim.Id,
	kind:     u8,
	access:   u8,
	expires:  i64,
	name_key: [32]u8,
	issuer:   Public_Key,
}

object_segment_name :: proc(kind: u8, id: prim.Id, allocator := context.temp_allocator) -> string {
	b := make([]u8, 1 + prim.ID_HEX_LEN, allocator)
	switch kind {
	case 1:
		b[0] = 'c'
	case 2:
		b[0] = 'm'
	case 3:
		b[0] = 't'
	case:
		b[0] = 'f'
	}
	h := prim.id_hex(id)
	copy(b[1:], h[:])
	return string(b)
}

cap_token_body :: proc(t: Cap_Token, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, CAP_TOKEN_VERSION)
	prim.write_id(&w, t.space)
	prim.write_id(&w, t.grantee)
	prim.write_id(&w, t.object)
	prim.write_u8(&w, t.kind)
	prim.write_u8(&w, t.access)
	prim.write_u64le(&w, u64(t.expires))
	x := t
	prim.write_raw(&w, x.name_key[:])
	prim.write_raw(&w, x.issuer[:])
	return .No_Memory if w.err != .None else .None
}

cap_token_verify :: proc(token: []u8, now_ms: i64) -> (t: Cap_Token, ok: bool) {
	if len(token) != CAP_TOKEN_LEN || token[0] != CAP_TOKEN_VERSION {
		return
	}
	r := prim.reader(token[1:])
	t.space = prim.read_id(&r)
	t.grantee = prim.read_id(&r)
	t.object = prim.read_id(&r)
	t.kind = prim.read_u8(&r)
	t.access = prim.read_u8(&r)
	t.expires = i64(prim.read_u64le(&r))
	prim.read_fixed(&r, t.name_key[:])
	prim.read_fixed(&r, t.issuer[:])
	if !prim.reader_ok(&r) || t.kind < 1 || t.kind > 4 {
		return {}, false
	}
	if !signature_verify(t.issuer, token[:CAP_TOKEN_LEN - 64], token[CAP_TOKEN_LEN - 64:]) {
		return {}, false
	}
	if t.expires != 0 && now_ms > t.expires {
		return {}, false
	}
	return t, true
}

Cap_Class :: enum u8 {
	Segment,
	Keys,
	Checkpoint,
	Card,
	Grant_Keys,
	Archive,
	Restore,
}

Cap_Slot :: struct {
	class:  Cap_Class,
	access: u8,
}

@(private)
Cap_Grant :: struct {
	auth:     ^Cap_Authorizer,
	grantee:  prim.Id,
	access:   u8,
	key:      [32]u8,
	suffixes: map[[16]u8]Cap_Slot,
	used:     u64,
}

Cap_Authorizer :: struct {
	inner:         Authorizer,
	issuer_ok:     proc(data: rawptr, space: prim.Id, issuer: Public_Key) -> bool,
	issuer_data:   rawptr,
	default_quota: i64,
	clock:         prim.Clock,
	grants:        map[[32]u8]^Cap_Grant,
	tick:          u64,
	allocator:     runtime.Allocator,
}

cap_authorizer_init :: proc(a: ^Cap_Authorizer, inner: Authorizer, default_quota: i64, clock := prim.Clock{}, allocator := context.allocator) {
	a^ = {
		inner         = inner,
		default_quota = default_quota,
		clock         = clock,
		allocator     = allocator,
	}
	a.grants = make(map[[32]u8]^Cap_Grant, allocator)
}

cap_authorizer_destroy :: proc(a: ^Cap_Authorizer) {
	for _, g in a.grants {
		_cap_grant_free(a, g)
	}
	delete(a.grants)
	a^ = {}
}

cap_authorizer :: proc(a: ^Cap_Authorizer) -> Authorizer {
	return Authorizer{data = a, authorize = _cap_authorize, observe = cap_authorizer_observe}
}

cap_authorizer_observe :: proc(data: rawptr, space: Space_Id, id: Stream_Id, bytes: []u8, revoked: ^[dynamic]Device_Id) {
	a := (^Cap_Authorizer)(data)
	if a.inner.observe != nil {
		a.inner.observe(a.inner.data, space, id, bytes, revoked)
	}
}

@(private)
_cap_grant_free :: proc(a: ^Cap_Authorizer, g: ^Cap_Grant) {
	delete(g.suffixes)
	free(g, a.allocator)
}

@(private)
_cap_authorize :: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	a := (^Cap_Authorizer)(data)
	if len(credential) == 0 || (credential[0] != CAP_CREDENTIAL && credential[0] != CAP_CREDENTIALS) {
		if a.inner.authorize == nil {
			return .Auth
		}
		return a.inner.authorize(a.inner.data, credential, binding, local, p)
	}
	n := 1
	at := 1
	if credential[0] == CAP_CREDENTIALS {
		if len(credential) < 2 {
			return .Auth
		}
		n = int(credential[1])
		at = 2
		if n < 2 || n > CAP_TOKENS_MAX {
			return .Auth
		}
	}
	if len(credential) != at + n * CAP_TOKEN_LEN + 32 + 64 {
		return .Auth
	}
	tokens := credential[at:][:n * CAP_TOKEN_LEN]
	pub: Public_Key
	copy(pub[:], credential[at + n * CAP_TOKEN_LEN:][:32])
	sig := credential[at + n * CAP_TOKEN_LEN + 32:]
	toks: [CAP_TOKENS_MAX]Cap_Token
	now := prim.clock_wall_ms(a.clock)
	for i in 0 ..< n {
		t, ok := cap_token_verify(tokens[i * CAP_TOKEN_LEN:][:CAP_TOKEN_LEN], now)
		if !ok || device_id(pub) != t.grantee || (i > 0 && t.space != toks[0].space) {
			return .Auth
		}
		if a.issuer_ok == nil || !a.issuer_ok(a.issuer_data, t.space, t.issuer) {
			return .Auth
		}
		toks[i] = t
	}
	if !local && (len(binding) == 0 || !hello_verify(pub, sig, binding)) {
		return .Auth
	}
	key: [32]u8
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, tokens)
	blake2b.final(&ctx, key[:])
	g, found := a.grants[key]
	if !found {
		g = _cap_grant_new(a, toks[:n], key)
		if g == nil {
			return .Auth
		}
	}
	a.tick += 1
	g.used = a.tick
	p^ = Principal {
		namespace   = Space_Id(toks[0].space),
		participant = Device_Id(toks[0].grantee),
		quota       = a.default_quota,
		check       = _cap_check,
		data        = g,
	}
	return .None
}

@(private)
_cap_concat :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(private)
_cap_put :: proc(g: ^Cap_Grant, suffix: [16]u8, class: Cap_Class, access: u8) {
	slot := g.suffixes[suffix]
	slot.class = class
	slot.access |= access
	g.suffixes[suffix] = slot
}

@(private)
_cap_grant_new :: proc(a: ^Cap_Authorizer, toks: []Cap_Token, key: [32]u8) -> ^Cap_Grant {
	if len(a.grants) >= CAP_CACHE {
		oldest: [32]u8
		best := max(u64)
		for k, g in a.grants {
			if g.used < best {
				best = g.used
				oldest = k
			}
		}
		if g, ok := a.grants[oldest]; ok {
			delete_key(&a.grants, oldest)
			_cap_grant_free(a, g)
		}
	}
	g := new(Cap_Grant, a.allocator)
	g.auth = a
	g.grantee = toks[0].grantee
	g.key = key
	g.suffixes = make(map[[16]u8]Cap_Slot, a.allocator)
	for t in toks {
		g.access |= t.access
		sc: Scope
		sc.name_key = t.name_key
		name := object_segment_name(t.kind, t.object)
		cn := _cap_concat(CHECKPOINT_STREAM, name)
		an := _cap_concat(arc.STREAM_PREFIX, name)
		for ep in 0 ..= CAP_PROBE_EPOCHS {
			_cap_put(g, stream_suffix(&sc, name, u64(ep)), .Segment, t.access)
			_cap_put(g, stream_suffix(&sc, CARD_STREAM, u64(ep)), .Card, t.access)
			_cap_put(g, stream_suffix(&sc, cn, u64(ep)), .Checkpoint, t.access)
			_cap_put(g, stream_suffix(&sc, an, u64(ep)), .Archive, t.access)
		}
		_cap_put(g, stream_suffix(&sc, _cap_concat(arc.RESTORE_PREFIX, name), 0), .Restore, t.access)
		kn := _cap_concat(KEYS_STREAM, name)
		for ep in 0 ..< CAP_KEYS_EPOCHS + CAP_PROBE_EPOCHS {
			_cap_put(g, stream_suffix(&sc, kn, u64(ep)), .Keys, t.access)
		}
		_cap_put(g, stream_suffix(&sc, _cap_concat(KEYS_HEAD_STREAM, name), 0), .Keys, t.access)
		_cap_put(g, stream_suffix(&sc, grant_keys_name(t.object), 0), .Grant_Keys, t.access)
		scope_clear(&sc)
	}
	a.grants[key] = g
	return g
}

@(private)
_cap_check :: proc(data: rawptr, p: ^Principal, access: Access, id: [32]u8) -> bool {
	g := (^Cap_Grant)(data)
	switch access {
	case .Put, .Forget:
		return g.access & CAP_WRITE != 0
	case .Get:
		return g.access & CAP_READ != 0
	case .Fill:
		return false
	case .List, .Read, .Append, .Drop, .Redact:
	}
	if access == .List && id == {} {
		return g.access & CAP_READ != 0
	}
	x := id
	suffix: [16]u8
	copy(suffix[:], x[16:])
	slot, ok := g.suffixes[suffix]
	if !ok {
		return false
	}
	own := string(x[:16]) == string(g.grantee[:])
	#partial switch access {
	case .List, .Read:
		return slot.access & CAP_READ != 0
	case .Append, .Drop:
		return own && slot.access & CAP_WRITE != 0
	case .Redact:
		return slot.access & (CAP_REDACT | CAP_WRITE) != 0
	}
	return false
}

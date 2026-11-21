package engine

import "base:runtime"
import "core:crypto/blake2b"
import "../prim"
import osync "../sync"

@(private)
CAP_VERSION :: 2
@(private)
CAP_CREDENTIAL :: u8(2)
@(private)
CAP_KEYS_EPOCHS :: 256
@(private)
CAP_PROBE_EPOCHS :: 8
@(private)
CAP_CACHE :: 1024

Access :: enum u8 {
	Read,
	Write,
	Redact,
	Share,
}

Access_Set :: bit_set[Access;u8]

Capability :: struct {
	space:    prim.Id,
	grantee:  prim.Id,
	object:   prim.Id,
	kind:     Kind,
	access:   Access_Set,
	expires:  i64,
	name_key: [32]u8,
	issuer:   osync.Public_Key,
}

CAPABILITY_LEN :: 1 + 16 * 3 + 1 + 1 + 8 + 32 + 32 + 64
CAP_CREDENTIAL_LEN :: 1 + CAPABILITY_LEN + 32 + 64

capability_issue :: proc(e: ^Engine, c: Capability, allocator := context.allocator) -> (token: []u8, err: Error) {
	context = context_for(e)
	sp := _space_open(e, c.space) or_return
	if sp.keyless || !sp.mem.have_naming || sp.mem.removed {
		return nil, .Permission
	}
	x := c
	sc := _object_scope(sp, c.object)
	x.name_key = sc.name_key
	osync.scope_clear(&sc)
	token = make([]u8, CAPABILITY_LEN, allocator)
	n := _cap_body(x, token)
	copy(token[n:], e.identity.sign[:])
	n += 32
	sig: [64]u8
	if serr := e.keyring.sign(e.keyring.data, token[:n], &sig); serr != .None {
		delete(token, allocator)
		return nil, _serr(serr)
	}
	copy(token[n:], sig[:])
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
	prim.read_fixed(&r, c.name_key[:])
	pub: osync.Public_Key
	prim.read_fixed(&r, pub[:])
	if !prim.reader_ok(&r) || k < 1 || k > u8(max(Kind)) {
		return {}, false
	}
	c.kind = Kind(k)
	c.access = transmute(Access_Set)a
	c.issuer = pub
	if !osync.signature_verify(pub, token[:CAPABILITY_LEN - 64], token[CAPABILITY_LEN - 64:]) {
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
	nk := c.name_key
	prim.write_raw(&w, nk[:])
	return copy(out, buf[:])
}

Cap_Credentials :: struct {
	keyring: osync.Keyring,
	token:   [CAPABILITY_LEN]u8,
}

capability_credentials :: proc(cc: ^Cap_Credentials, keyring: osync.Keyring, token: []u8) -> (osync.Credentials, Error) {
	if len(token) != CAPABILITY_LEN {
		return {}, .Invalid
	}
	cc.keyring = keyring
	copy(cc.token[:], token)
	return osync.Credentials{data = cc, produce = _cap_produce}, .None
}

@(private)
_cap_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	cc := (^Cap_Credentials)(data)
	id := cc.keyring.identity(cc.keyring.data)
	buf: [16 + osync.HASH_LEN]u8
	msg := osync.hello_message(binding, &buf)
	sig: [64]u8
	if err := cc.keyring.sign(cc.keyring.data, msg, &sig); err != .None {
		return err
	}
	w := prim.writer(out)
	prim.write_u8(&w, CAP_CREDENTIAL)
	prim.write_raw(&w, cc.token[:])
	prim.write_raw(&w, id.sign[:])
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

@(private)
Cap_Class :: enum u8 {
	Segment,
	Keys,
	Checkpoint,
	Card,
}

@(private)
Cap_Grant :: struct {
	auth:     ^Cap_Authorizer,
	cap:      Capability,
	key:      [32]u8,
	suffixes: map[[16]u8]Cap_Class,
	used:     u64,
}

Cap_Authorizer :: struct {
	inner:         osync.Authorizer,
	issuer_ok:     proc(data: rawptr, space: prim.Id, issuer: osync.Public_Key) -> bool,
	issuer_data:   rawptr,
	default_quota: i64,
	clock:         prim.Clock,
	grants:        map[[32]u8]^Cap_Grant,
	tick:          u64,
	allocator:     runtime.Allocator,
}

cap_authorizer_init :: proc(a: ^Cap_Authorizer, inner: osync.Authorizer, default_quota: i64, clock := prim.Clock{}, allocator := context.allocator) {
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

cap_authorizer :: proc(a: ^Cap_Authorizer) -> osync.Authorizer {
	return osync.Authorizer{data = a, authorize = _cap_authorize, observe = cap_authorizer_observe}
}

cap_authorizer_observe :: proc(data: rawptr, space: osync.Space_Id, id: osync.Stream_Id, bytes: []u8, revoked: ^[dynamic]osync.Device_Id) {
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
_cap_authorize :: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^osync.Principal) -> osync.Code {
	a := (^Cap_Authorizer)(data)
	if len(credential) == 0 || credential[0] != CAP_CREDENTIAL {
		if a.inner.authorize == nil {
			return .Auth
		}
		return a.inner.authorize(a.inner.data, credential, binding, local, p)
	}
	if len(credential) != CAP_CREDENTIAL_LEN {
		return .Auth
	}
	token := credential[1:][:CAPABILITY_LEN]
	pub: osync.Public_Key
	copy(pub[:], credential[1 + CAPABILITY_LEN:][:32])
	sig := credential[1 + CAPABILITY_LEN + 32:]
	c, ok := capability_verify(token, prim.clock_wall_ms(a.clock))
	if !ok || osync.device_id(pub) != c.grantee {
		return .Auth
	}
	if a.issuer_ok == nil || !a.issuer_ok(a.issuer_data, c.space, c.issuer) {
		return .Auth
	}
	if !local && (len(binding) == 0 || !osync.hello_verify(pub, sig, binding)) {
		return .Auth
	}
	key: [32]u8
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, token)
	blake2b.final(&ctx, key[:])
	g, found := a.grants[key]
	if !found {
		g = _cap_grant_new(a, c, key)
		if g == nil {
			return .Auth
		}
	}
	a.tick += 1
	g.used = a.tick
	p^ = osync.Principal {
		namespace   = c.space,
		participant = c.grantee,
		quota       = a.default_quota,
		check       = _cap_check,
		data        = g,
	}
	return .None
}

@(private)
_cap_grant_new :: proc(a: ^Cap_Authorizer, c: Capability, key: [32]u8) -> ^Cap_Grant {
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
	g.cap = c
	g.key = key
	g.suffixes = make(map[[16]u8]Cap_Class, a.allocator)
	sc: osync.Scope
	sc.name_key = c.name_key
	name := _seg_name(c.kind, c.object)
	cn, cerr := _concat2(osync.CHECKPOINT_STREAM, name)
	for ep in 0 ..= CAP_PROBE_EPOCHS {
		g.suffixes[osync.stream_suffix(&sc, name, u64(ep))] = .Segment
		g.suffixes[osync.stream_suffix(&sc, CARD_STREAM, u64(ep))] = .Card
		if cerr == .None {
			g.suffixes[osync.stream_suffix(&sc, cn, u64(ep))] = .Checkpoint
		}
	}
	if kn, err := _concat2(osync.KEYS_STREAM, name); err == .None {
		for ep in 0 ..< CAP_KEYS_EPOCHS + CAP_PROBE_EPOCHS {
			g.suffixes[osync.stream_suffix(&sc, kn, u64(ep))] = .Keys
		}
	}
	osync.scope_clear(&sc)
	a.grants[key] = g
	return g
}

@(private)
_concat2 :: proc(a, b: string) -> (string, Error) {
	out, err := make([]u8, len(a) + len(b), context.temp_allocator)
	if err != nil {
		return "", .No_Memory
	}
	copy(out, a)
	copy(out[len(a):], b)
	return string(out), .None
}

@(private)
_cap_check :: proc(data: rawptr, p: ^osync.Principal, access: osync.Access, id: [32]u8) -> bool {
	g := (^Cap_Grant)(data)
	c := g.cap
	switch access {
	case .Put, .Forget:
		return .Write in c.access
	case .Get:
		return .Read in c.access
	case .Fill:
		return false
	case .List, .Read, .Append, .Drop, .Redact:
	}
	if access == .List && id == {} {
		return .Read in c.access
	}
	x := id
	suffix: [16]u8
	copy(suffix[:], x[16:])
	if _, ok := g.suffixes[suffix]; !ok {
		return false
	}
	own := string(x[:16]) == string(c.grantee[:])
	#partial switch access {
	case .List, .Read:
		return .Read in c.access
	case .Append, .Drop:
		return own && .Write in c.access
	case .Redact:
		return .Redact in c.access || .Write in c.access
	}
	return false
}

keyring :: proc "contextless" (e: ^Engine) -> osync.Keyring {
	return e.keyring
}

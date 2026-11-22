package engine

import "../prim"
import osync "../sync"

CAP_MULTI_MAX :: osync.CAP_TOKENS_MAX

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

CAPABILITY_LEN :: osync.CAP_TOKEN_LEN

capability_issue :: proc(e: ^Engine, c: Capability, allocator := context.allocator) -> (token: []u8, err: Error) {
	context = context_for(e)
	sp := _space_open(e, c.space) or_return
	if sp.keyless || !sp.mem.have_naming || sp.mem.removed {
		return nil, .Permission
	}
	sc := _object_scope(sp, c.object)
	t := osync.Cap_Token {
		space    = c.space,
		grantee  = c.grantee,
		object   = c.object,
		kind     = u8(c.kind),
		access   = transmute(u8)c.access,
		expires  = c.expires,
		name_key = sc.name_key,
		issuer   = e.identity.sign,
	}
	osync.scope_clear(&sc)
	body := make([dynamic]u8, context.temp_allocator)
	_serr(osync.cap_token_body(t, &body)) or_return
	sig: [64]u8
	_serr(e.keyring.sign(e.keyring.data, body[:], &sig)) or_return
	token = make([]u8, CAPABILITY_LEN, allocator)
	copy(token, body[:])
	copy(token[len(body):], sig[:])
	return token, .None
}

capability_verify :: proc(token: []u8, now_ms: i64) -> (c: Capability, ok: bool) {
	t, tok := osync.cap_token_verify(token, now_ms)
	if !tok {
		return {}, false
	}
	return Capability {
		space    = t.space,
		grantee  = t.grantee,
		object   = t.object,
		kind     = Kind(t.kind),
		access   = transmute(Access_Set)t.access,
		expires  = t.expires,
		name_key = t.name_key,
		issuer   = t.issuer,
	}, true
}

Cap_Credentials :: struct {
	keyring: osync.Keyring,
	tokens:  [CAP_MULTI_MAX][CAPABILITY_LEN]u8,
	count:   int,
}

capability_credentials :: proc(cc: ^Cap_Credentials, keyring: osync.Keyring, tokens: []u8) -> (osync.Credentials, Error) {
	n := len(tokens) / CAPABILITY_LEN
	if n < 1 || n > CAP_MULTI_MAX || len(tokens) != n * CAPABILITY_LEN {
		return {}, .Invalid
	}
	cc.keyring = keyring
	cc.count = n
	for i in 0 ..< n {
		copy(cc.tokens[i][:], tokens[i * CAPABILITY_LEN:][:CAPABILITY_LEN])
	}
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
	if cc.count == 1 {
		prim.write_u8(&w, osync.CAP_CREDENTIAL)
	} else {
		prim.write_u8(&w, osync.CAP_CREDENTIALS)
		prim.write_u8(&w, u8(cc.count))
	}
	for i in 0 ..< cc.count {
		prim.write_raw(&w, cc.tokens[i][:])
	}
	prim.write_raw(&w, id.sign[:])
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

keyring :: proc "contextless" (e: ^Engine) -> osync.Keyring {
	return e.keyring
}

package osync

import "../prim"

LEASE_TOKEN_VERSION :: u8(1)
LEASE_TOKEN_LEN :: 1 + 16 + 32 + 32 + 8 + 8 + 64
LEASE_SKEW_MS :: u64(60_000)
RENEWAL_REQUEST_VERSION :: u8(1)
RENEWAL_REQUEST_LEN :: 1 + CARD_LEN + 8 + 64

Lease_Token :: struct {
	space:   Space_Id,
	subject: Public_Key,
	pool:    Public_Key,
	issued:  u64,
	expires: u64,
}

@(private)
_lease_message :: proc(t: ^Lease_Token, buf: ^[dynamic]u8) -> []u8 {
	w := prim.writer(buf)
	prim.write_raw(&w, transmute([]u8)string("0ndb-lease-v1"))
	s, sub, p := t.space, t.subject, t.pool
	prim.write_raw(&w, s[:])
	prim.write_raw(&w, sub[:])
	prim.write_raw(&w, p[:])
	prim.write_u64le(&w, t.issued)
	prim.write_u64le(&w, t.expires)
	return buf[:]
}

lease_token_make :: proc(keyring: ^Keyring, t: Lease_Token, out: ^[dynamic]u8) -> Error {
	x := t
	msg := make([dynamic]u8, context.temp_allocator)
	sig: [64]u8
	keyring.sign(keyring.data, _lease_message(&x, &msg), &sig) or_return
	w := prim.writer(out)
	prim.write_u8(&w, LEASE_TOKEN_VERSION)
	s, sub, p := x.space, x.subject, x.pool
	prim.write_raw(&w, s[:])
	prim.write_raw(&w, sub[:])
	prim.write_raw(&w, p[:])
	prim.write_u64le(&w, x.issued)
	prim.write_u64le(&w, x.expires)
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

lease_token_parse :: proc(raw: []u8) -> (t: Lease_Token, ok: bool) {
	if len(raw) != LEASE_TOKEN_LEN || raw[0] != LEASE_TOKEN_VERSION {
		return {}, false
	}
	r := prim.reader(raw[1:])
	prim.read_fixed(&r, t.space[:])
	prim.read_fixed(&r, t.subject[:])
	prim.read_fixed(&r, t.pool[:])
	t.issued = prim.read_u64le(&r)
	t.expires = prim.read_u64le(&r)
	if !prim.reader_ok(&r) {
		return {}, false
	}
	msg := make([dynamic]u8, context.temp_allocator)
	return t, signature_verify(t.pool, _lease_message(&t, &msg), raw[len(raw) - 64:])
}

lease_admits :: proc(r: ^Roster, space: Space_Id, sign: Public_Key, raw: []u8, now_ms: u64) -> (until: u64, ok: bool) {
	t, tok := lease_token_parse(raw)
	if !tok || t.space != space || t.subject != sign {
		return 0, false
	}
	x := roster_find(r, sign)
	if x < 0 {
		return 0, false
	}
	m := &r.members[x]
	if m.removed || m.kind != .Runner || m.lease_ms == 0 || m.added_by != t.pool {
		return 0, false
	}
	pi := roster_find(r, t.pool)
	if pi < 0 || r.members[pi].kind != .Pool || !member_active(&r.members[pi], now_ms) {
		return 0, false
	}
	if t.expires <= now_ms || t.issued > now_ms + LEASE_SKEW_MS || t.expires > t.issued + m.lease_ms {
		return 0, false
	}
	return t.expires, true
}

@(private)
_renewal_message :: proc(card: []u8, ts: u64, buf: ^[dynamic]u8) -> []u8 {
	w := prim.writer(buf)
	prim.write_raw(&w, transmute([]u8)string("0ndb-renewal-v1"))
	prim.write_raw(&w, card)
	prim.write_u64le(&w, ts)
	return buf[:]
}

renewal_request_make :: proc(keyring: ^Keyring, ts: u64, out: ^[dynamic]u8) -> Error {
	card := keyring_card(keyring) or_return
	msg := make([dynamic]u8, context.temp_allocator)
	sig: [64]u8
	keyring.sign(keyring.data, _renewal_message(card[:], ts, &msg), &sig) or_return
	w := prim.writer(out)
	prim.write_u8(&w, RENEWAL_REQUEST_VERSION)
	prim.write_raw(&w, card[:])
	prim.write_u64le(&w, ts)
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

renewal_request_verify :: proc(raw: []u8, now_ms: u64) -> (runner: Identity, ok: bool) {
	if len(raw) != RENEWAL_REQUEST_LEN || raw[0] != RENEWAL_REQUEST_VERSION {
		return {}, false
	}
	card := raw[1:][:CARD_LEN]
	id, cerr := card_verify(card)
	if cerr != .None {
		return {}, false
	}
	ts := prim.get_u64le(raw[1 + CARD_LEN:])
	if ts + 10 * LEASE_SKEW_MS < now_ms || ts > now_ms + 10 * LEASE_SKEW_MS {
		return {}, false
	}
	msg := make([dynamic]u8, context.temp_allocator)
	return id, signature_verify(id.sign, _renewal_message(card, ts, &msg), raw[len(raw) - 64:])
}

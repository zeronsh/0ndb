package osync

import "core:crypto/blake2b"
import "../prim"

NOTICES_STREAM :: "notices"
NOTICE_HELLO :: u8(1)
NOTICE_JOIN :: u8(2)
NOTICE_REMOVED :: u8(3)

@(private)
NOTICE_SEAL_CONTEXT :: "0ndb notice"

Notice :: struct {
	kind:   u8,
	sign:   Public_Key,
	box:    Public_Key,
	cert:   [64]u8,
	target: Device_Id,
	space:  Space_Id,
	sealed: []u8,
	device: Device_Id,
}

Notice_Join :: struct {
	name:         string,
	relay:        string,
	relay_public: Public_Key,
	proof:        []u8,
}

notices_scope :: proc(account: Public_Key) -> (sc: Scope) {
	a := account
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb notices name"))
	blake2b.update(&ctx, a[:])
	blake2b.final(&ctx, sc.name_key[:])
	sc.mode = .Transparent
	return
}

notice_hello_encode :: proc(id: Identity, cert: [64]u8, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, NOTICE_HELLO)
	x := id
	prim.write_raw(&w, x.sign[:])
	prim.write_raw(&w, x.box[:])
	c := cert
	prim.write_raw(&w, c[:])
	return .No_Memory if w.err != .None else .None
}

notice_join_encode :: proc(target: Identity, space: Space_Id, j: Notice_Join, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	plain := make([dynamic]u8, context.temp_allocator)
	pw := prim.writer(&plain)
	prim.write_str(&pw, j.name)
	prim.write_str(&pw, j.relay)
	rp := j.relay_public
	prim.write_raw(&pw, rp[:])
	prim.write_bytes(&pw, j.proof)
	if pw.err != .None {
		return .No_Memory
	}
	sealed := make([dynamic]u8, context.temp_allocator)
	t := target
	seal_bundle_to(&t, plain[:], transmute([]u8)string(NOTICE_SEAL_CONTEXT), &sealed, random) or_return
	w := prim.writer(out)
	prim.write_u8(&w, NOTICE_JOIN)
	prim.write_raw(&w, t.id[:])
	s := space
	prim.write_raw(&w, s[:])
	prim.write_bytes(&w, sealed[:])
	return .No_Memory if w.err != .None else .None
}

notice_removed_encode :: proc(device: Device_Id, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, NOTICE_REMOVED)
	d := device
	prim.write_raw(&w, d[:])
	return .No_Memory if w.err != .None else .None
}

notice_decode :: proc(data: []u8, n: ^Notice) -> Error {
	n^ = {}
	r := prim.reader(data)
	n.kind = prim.read_u8(&r)
	switch n.kind {
	case NOTICE_HELLO:
		prim.read_fixed(&r, n.sign[:])
		prim.read_fixed(&r, n.box[:])
		prim.read_fixed(&r, n.cert[:])
	case NOTICE_JOIN:
		prim.read_fixed(&r, n.target[:])
		prim.read_fixed(&r, n.space[:])
		n.sealed = prim.read_bytes(&r)
	case NOTICE_REMOVED:
		prim.read_fixed(&r, n.device[:])
	case:
		return .Corrupt
	}
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

notice_join_open :: proc(n: ^Notice, keyring: ^Keyring, j: ^Notice_Join, allocator := context.allocator) -> Error {
	if len(n.sealed) <= WRAP_LEN + 16 {
		return .Corrupt
	}
	plain := make([]u8, len(n.sealed) - WRAP_LEN - 16, allocator)
	open_bundle(keyring, n.sealed, transmute([]u8)string(NOTICE_SEAL_CONTEXT), plain) or_return
	r := prim.reader(plain)
	j.name = prim.read_str(&r)
	j.relay = prim.read_str(&r)
	prim.read_fixed(&r, j.relay_public[:])
	j.proof = prim.read_bytes(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

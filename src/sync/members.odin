package osync

import "core:crypto"
import "core:crypto/blake2b"
import "core:crypto/ed25519"
import "../prim"

MEMBER_RECORD :: 0x4d
MEMBER_VERSION :: 1
MEMBERS_STREAM :: "members"
MEMBER_MAX :: 1 << 20
MEMBER_PARENTS_MAX :: 64

Record_Id :: distinct [32]u8

Member_Op :: enum u8 {
	Genesis = 1,
	Add     = 2,
	Remove  = 3,
	Commit  = 4,
	Update  = 5,
	Renew   = 6,
	Seal    = 7,
	Revoke  = 8,
}

Member_Kind :: enum u8 {
	Device,
	Account,
	Recovery,
	Custodian,
	Pool,
	Runner,
	Guest,
	Directory,
}

Role :: enum u8 {
	Owner,
	Admin,
	Member,
	Reader,
}

Enroll_Method :: enum u8 {
	Genesis,
	Approval,
	Recovery,
	Account,
	Custodian,
	Pool,
	Grant,
	Directory,
}

Member_Record :: struct {
	op:      Member_Op,
	space:   Space_Id,
	author:  Public_Key,
	lamport: u64,
	parents: []Record_Id,
	hlc:     u64,
	payload: []u8,
	sig:     [64]u8,
	id:      Record_Id,
	raw:     []u8,
}

Add_Body :: struct {
	sign:        Public_Key,
	box:         Public_Key,
	kind:        Member_Kind,
	role:        Role,
	method:      Enroll_Method,
	person:      Public_Key,
	expires:     u64,
	lease_ms:    u64,
	history:     bool,
	scope:       []prim.Id,
	label:       []u8,
	attestation: []u8,
	seal:        []u8,
}

Remove_Body :: struct {
	subject: Public_Key,
}

Update_Body :: struct {
	box: Public_Key,
}

Renew_Body :: struct {
	expires: u64,
}

Seal_Body :: struct {
	subject: Public_Key,
	epoch:   Record_Id,
	wrap:    []u8,
}

Revoke_Body :: struct {
	grant: Record_Id,
}

@(private)
MEMBER_SIG_CONTEXT :: "0ndb member v1\x00"

members_scope :: proc(space: Space_Id) -> (sc: Scope) {
	s := space
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb members name"))
	blake2b.update(&ctx, s[:])
	blake2b.final(&ctx, sc.name_key[:])
	sc.mode = .Transparent
	return
}

members_suffix :: proc(space: Space_Id) -> [16]u8 {
	sc := members_scope(space)
	return stream_suffix(&sc, MEMBERS_STREAM, 0)
}

members_stream :: proc(space: Space_Id, device: Device_Id) -> Stream_Id {
	sc := members_scope(space)
	return stream_id(&sc, device, MEMBERS_STREAM, 0)
}

space_id_of :: proc(genesis: Record_Id) -> (id: Space_Id) {
	g := genesis
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, transmute([]u8)string("0ndb space"))
	blake2b.update(&ctx, g[:])
	blake2b.final(&ctx, id[:])
	id[6] = (id[6] & 0x0f) | 0x80
	return
}

record_hash :: proc(raw: []u8) -> (id: Record_Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb member id"))
	blake2b.update(&ctx, raw)
	blake2b.final(&ctx, id[:])
	return
}

Member_Signer :: struct {
	data:   rawptr,
	public: Public_Key,
	sign:   proc(data: rawptr, msg: []u8, sig: ^[64]u8) -> Error,
}

keyring_member_signer :: proc(k: ^Keyring) -> Member_Signer {
	id := k.identity(k.data)
	return Member_Signer{data = k.data, public = id.sign, sign = k.sign}
}

Key_Signer :: struct {
	key: ed25519.Private_Key,
}

key_signer :: proc(k: ^Key_Signer) -> Member_Signer {
	s := Member_Signer{data = k, sign = _key_signer_sign}
	ed25519.private_key_public_bytes(&k.key, s.public[:])
	return s
}

key_signer_from_seed :: proc(k: ^Key_Signer, seed: []u8) -> bool {
	return ed25519.private_key_set_bytes(&k.key, seed)
}

key_signer_clear :: proc(k: ^Key_Signer) {
	ed25519.private_key_clear(&k.key)
}

@(private)
_key_signer_sign :: proc(data: rawptr, msg: []u8, sig: ^[64]u8) -> Error {
	k := cast(^Key_Signer)data
	ed25519.sign(&k.key, msg, sig[:])
	return .None
}

member_encode :: proc(op: Member_Op, space: Space_Id, signer: Member_Signer, lamport: u64, parents: []Record_Id, hlc: u64, payload: []u8, allocator := context.allocator) -> (raw: []u8, id: Record_Id, err: Error) {
	if len(parents) > MEMBER_PARENTS_MAX {
		return nil, {}, .Too_Large
	}
	buf := make([dynamic]u8, 0, 96 + 32 * len(parents) + len(payload) + 64, allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, MEMBER_RECORD)
	prim.write_u8(&w, MEMBER_VERSION)
	prim.write_u8(&w, u8(op))
	s := space
	prim.write_raw(&w, s[:])
	a := signer.public
	prim.write_raw(&w, a[:])
	prim.write_uvarint(&w, lamport)
	prim.write_uvarint(&w, u64(len(parents)))
	for p in parents {
		x := p
		prim.write_raw(&w, x[:])
	}
	prim.write_u64le(&w, hlc)
	prim.write_bytes(&w, payload)
	if w.err != .None {
		delete(buf)
		return nil, {}, .No_Memory
	}
	msg := make([]u8, len(MEMBER_SIG_CONTEXT) + len(buf), context.temp_allocator)
	copy(msg, MEMBER_SIG_CONTEXT)
	copy(msg[len(MEMBER_SIG_CONTEXT):], buf[:])
	sig: [64]u8
	if serr := signer.sign(signer.data, msg, &sig); serr != .None {
		delete(buf)
		return nil, {}, serr
	}
	prim.write_raw(&w, sig[:])
	if w.err != .None || len(buf) > MEMBER_MAX {
		delete(buf)
		return nil, {}, .Too_Large
	}
	raw = buf[:]
	return raw, record_hash(raw), .None
}

member_decode :: proc(raw: []u8, rec: ^Member_Record, verify := true, allocator := context.allocator) -> Error {
	if len(raw) < 3 + 16 + 32 + 2 + 8 + 1 + 64 || len(raw) > MEMBER_MAX {
		return .Corrupt
	}
	r := prim.reader(raw[:len(raw) - 64])
	if prim.read_u8(&r) != MEMBER_RECORD || prim.read_u8(&r) != MEMBER_VERSION {
		return .Corrupt
	}
	op := prim.read_u8(&r)
	if op < u8(Member_Op.Genesis) || op > u8(max(Member_Op)) {
		return .Corrupt
	}
	rec.op = Member_Op(op)
	prim.read_fixed(&r, rec.space[:])
	prim.read_fixed(&r, rec.author[:])
	rec.lamport = prim.read_uvarint(&r)
	np := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || np > MEMBER_PARENTS_MAX || np * 32 > u64(prim.reader_remaining(&r)) {
		return .Corrupt
	}
	rec.parents = make([]Record_Id, int(np), allocator)
	for i in 0 ..< int(np) {
		prim.read_fixed(&r, rec.parents[i][:])
	}
	rec.hlc = prim.read_u64le(&r)
	rec.payload = prim.read_bytes(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		delete(rec.parents, allocator)
		rec.parents = nil
		return .Corrupt
	}
	copy(rec.sig[:], raw[len(raw) - 64:])
	rec.raw = raw
	rec.id = record_hash(raw)
	if verify {
		msg := make([]u8, len(MEMBER_SIG_CONTEXT) + len(raw) - 64, context.temp_allocator)
		copy(msg, MEMBER_SIG_CONTEXT)
		copy(msg[len(MEMBER_SIG_CONTEXT):], raw[:len(raw) - 64])
		if !signature_verify(rec.author, msg, rec.sig[:]) {
			delete(rec.parents, allocator)
			rec.parents = nil
			return .Auth
		}
	}
	return .None
}

member_record_free :: proc(rec: ^Member_Record, allocator := context.allocator) {
	delete(rec.parents, allocator)
	rec.parents = nil
}

add_encode :: proc(b: Add_Body, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	x := b
	prim.write_raw(&w, x.sign[:])
	prim.write_raw(&w, x.box[:])
	prim.write_u8(&w, u8(b.kind))
	prim.write_u8(&w, u8(b.role))
	prim.write_u8(&w, u8(b.method))
	prim.write_raw(&w, x.person[:])
	prim.write_u64le(&w, b.expires)
	prim.write_uvarint(&w, b.lease_ms)
	prim.write_bool(&w, b.history)
	prim.write_uvarint(&w, u64(len(b.scope)))
	for s in b.scope {
		prim.write_id(&w, s)
	}
	prim.write_bytes(&w, b.label)
	prim.write_bytes(&w, b.attestation)
	prim.write_bytes(&w, b.seal)
	return .No_Memory if w.err != .None else .None
}

add_decode :: proc(payload: []u8, b: ^Add_Body, allocator := context.allocator) -> Error {
	r := prim.reader(payload)
	prim.read_fixed(&r, b.sign[:])
	prim.read_fixed(&r, b.box[:])
	k := prim.read_u8(&r)
	ro := prim.read_u8(&r)
	m := prim.read_u8(&r)
	prim.read_fixed(&r, b.person[:])
	b.expires = prim.read_u64le(&r)
	b.lease_ms = prim.read_uvarint(&r)
	b.history = prim.read_bool(&r)
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || k > u8(max(Member_Kind)) || ro > u8(max(Role)) || m > u8(max(Enroll_Method)) || n > u64(prim.reader_remaining(&r) / 16) {
		return .Corrupt
	}
	b.kind = Member_Kind(k)
	b.role = Role(ro)
	b.method = Enroll_Method(m)
	if n > 0 {
		b.scope = make([]prim.Id, int(n), allocator)
		for i in 0 ..< int(n) {
			b.scope[i] = prim.read_id(&r)
		}
	}
	b.label = prim.read_bytes(&r)
	b.attestation = prim.read_bytes(&r)
	b.seal = prim.read_bytes(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		delete(b.scope, allocator)
		b.scope = nil
		return .Corrupt
	}
	return .None
}

key32_encode :: proc(k: Public_Key, out: ^[dynamic]u8) -> Error {
	x := k
	_, e := append(out, ..x[:])
	return .No_Memory if e != nil else .None
}

key32_decode :: proc(payload: []u8) -> (k: Public_Key, err: Error) {
	if len(payload) != 32 {
		return k, .Corrupt
	}
	copy(k[:], payload)
	return k, .None
}

renew_encode :: proc(b: Renew_Body, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u64le(&w, b.expires)
	return .No_Memory if w.err != .None else .None
}

renew_decode :: proc(payload: []u8) -> (b: Renew_Body, err: Error) {
	if len(payload) != 8 {
		return b, .Corrupt
	}
	b.expires = prim.get_u64le(payload)
	return b, .None
}

seal_encode :: proc(b: Seal_Body, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	x := b
	prim.write_raw(&w, x.subject[:])
	prim.write_raw(&w, x.epoch[:])
	prim.write_bytes(&w, b.wrap)
	return .No_Memory if w.err != .None else .None
}

seal_decode :: proc(payload: []u8) -> (b: Seal_Body, err: Error) {
	r := prim.reader(payload)
	prim.read_fixed(&r, b.subject[:])
	prim.read_fixed(&r, b.epoch[:])
	b.wrap = prim.read_bytes(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return {}, .Corrupt
	}
	return b, .None
}

revoke_decode :: proc(payload: []u8) -> (b: Revoke_Body, err: Error) {
	if len(payload) != 32 {
		return b, .Corrupt
	}
	copy(b.grant[:], payload)
	return b, .None
}

identity_of :: proc(sign, box: Public_Key) -> Identity {
	return Identity{id = device_id(sign), sign = sign, box = box}
}

seal_bundle_to :: proc(recipient: ^Identity, secret: []u8, context_bytes: []u8, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	if len(secret) > 4096 {
		return .Too_Large
	}
	k: Content_Key
	prim.random_fill(random, k.key[:])
	defer crypto.zero_explicit(&k, size_of(k))
	wrap: [WRAP_LEN]u8
	seal_key_to(recipient, &k, &wrap, random) or_return
	_, ae := append(out, ..wrap[:])
	if ae != nil {
		return .No_Memory
	}
	start := len(out)
	resize(out, start + len(secret) + 16)
	aead_seal(k.key[:], context_bytes, secret, out[start:])
	return .None
}

open_bundle :: proc(keyring: ^Keyring, sealed: []u8, context_bytes: []u8, out: []u8) -> Error {
	if len(sealed) != WRAP_LEN + len(out) + 16 {
		return .Invalid
	}
	k: Content_Key
	defer crypto.zero_explicit(&k, size_of(k))
	keyring.unwrap(keyring.data, sealed[:WRAP_LEN], &k) or_return
	if !aead_open(k.key[:], context_bytes, sealed[WRAP_LEN:], out) {
		return .Auth
	}
	return .None
}

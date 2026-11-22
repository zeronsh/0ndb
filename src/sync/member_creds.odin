package osync

import "core:crypto/blake2b"
import "../prim"

MEMBER_CREDENTIAL :: u8(4)
REQUEST_CREDENTIAL :: u8(5)
ACCOUNT_CREDENTIAL :: u8(6)
ACCOUNT_NAMESPACE_QUOTA :: i64(4 << 20)
MEMBER_PROOFS_MAX :: 8

account_namespace :: proc(account: Public_Key) -> (id: Space_Id) {
	p := account
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, transmute([]u8)string("0ndb account namespace"))
	blake2b.update(&ctx, p[:])
	blake2b.final(&ctx, id[:])
	id[6] = (id[6] & 0x0f) | 0x80
	return
}

member_credential :: proc(space: Space_Id, keyring: ^Keyring, binding: []u8, proofs: [][]u8, out: ^[dynamic]u8) -> Error {
	id := keyring.identity(keyring.data)
	buf: [16 + HASH_LEN]u8
	msg := hello_message(binding, &buf)
	sig: [64]u8
	keyring.sign(keyring.data, msg, &sig) or_return
	w := prim.writer(out)
	prim.write_u8(&w, MEMBER_CREDENTIAL)
	s := space
	prim.write_raw(&w, s[:])
	prim.write_raw(&w, id.sign[:])
	prim.write_raw(&w, sig[:])
	n := min(len(proofs), MEMBER_PROOFS_MAX)
	prim.write_uvarint(&w, u64(n))
	for p in proofs[:n] {
		prim.write_bytes(&w, p)
	}
	if w.err != .None || len(out) > CREDENTIAL_MAX {
		return .Too_Large
	}
	return .None
}

request_credential :: proc(account: Public_Key, keyring: ^Keyring, binding: []u8, out: ^[dynamic]u8) -> Error {
	id := keyring.identity(keyring.data)
	buf: [16 + HASH_LEN]u8
	msg := hello_message(binding, &buf)
	sig: [64]u8
	keyring.sign(keyring.data, msg, &sig) or_return
	w := prim.writer(out)
	prim.write_u8(&w, REQUEST_CREDENTIAL)
	a := account
	prim.write_raw(&w, a[:])
	prim.write_raw(&w, id.sign[:])
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

account_credential :: proc(account: Public_Key, cert: [64]u8, keyring: ^Keyring, binding: []u8, out: ^[dynamic]u8) -> Error {
	id := keyring.identity(keyring.data)
	buf: [16 + HASH_LEN]u8
	msg := hello_message(binding, &buf)
	dsig: [64]u8
	keyring.sign(keyring.data, msg, &dsig) or_return
	w := prim.writer(out)
	prim.write_u8(&w, ACCOUNT_CREDENTIAL)
	a, c := account, cert
	prim.write_raw(&w, a[:])
	prim.write_raw(&w, c[:])
	prim.write_raw(&w, id.sign[:])
	prim.write_raw(&w, dsig[:])
	return .No_Memory if w.err != .None else .None
}

package osync

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/ecdh"
import "core:crypto/ed25519"
import "core:crypto/hkdf"
import "../prim"

WRAP_LEN :: 32 + 4 + 32 + chacha20poly1305.TAG_SIZE
CARD_LEN :: 32 + 32 + 64

Keyring :: struct {
	data:     rawptr,
	identity: proc(data: rawptr) -> Identity,
	sign:     proc(data: rawptr, msg: []u8, sig: ^[64]u8) -> Error,
	wrap:     proc(data: rawptr, recipient: ^Identity, key: ^Content_Key, out: ^[WRAP_LEN]u8) -> Error,
	unwrap:   proc(data: rawptr, wrapped: []u8, key: ^Content_Key) -> Error,
	verify:   proc(data: rawptr, signer: ^Identity, msg: []u8, sig: []u8) -> bool,
}

File_Keyring :: struct {
	device: Device,
	random: prim.Random,
}

file_keyring_open :: proc(k: ^File_Keyring, vfs: prim.Vfs, dir: string, random := prim.Random{}) -> Error {
	d, err := device_load_or_create(vfs, dir, random)
	if err != .None {
		return err
	}
	k.device = d
	k.random = random
	return .None
}

file_keyring_close :: proc(k: ^File_Keyring) {
	device_clear(&k.device)
}

file_keyring :: proc(k: ^File_Keyring) -> Keyring {
	return Keyring{data = k, identity = _fk_identity, sign = _fk_sign, wrap = _fk_wrap, unwrap = _fk_unwrap, verify = _fk_verify}
}

keyring_identity :: proc(k: ^Keyring) -> Identity {
	return k.identity(k.data)
}

keyring_card :: proc(k: ^Keyring) -> (card: [CARD_LEN]u8, err: Error) {
	id := k.identity(k.data)
	copy(card[0:32], id.sign[:])
	copy(card[32:64], id.box[:])
	msg := _card_message(id.box)
	sig: [64]u8
	k.sign(k.data, msg[:], &sig) or_return
	copy(card[64:], sig[:])
	return card, .None
}

card_verify :: proc(card: []u8) -> (id: Identity, err: Error) {
	if len(card) != CARD_LEN {
		return {}, .Invalid
	}
	copy(id.sign[:], card[0:32])
	copy(id.box[:], card[32:64])
	msg := _card_message(id.box)
	if !signature_verify(id.sign, msg[:], card[64:]) {
		return {}, .Auth
	}
	id.id = device_id(id.sign)
	return id, .None
}

seal_key_to :: proc(recipient: ^Identity, key: ^Content_Key, out: ^[WRAP_LEN]u8, random := prim.Random{}) -> Error {
	eph: ecdh.Private_Key
	if !x25519_generate(&eph, random) {
		return .Invalid
	}
	defer ecdh.private_key_clear(&eph)
	eph_pub: [32]u8
	ecdh.private_key_public_bytes(&eph, eph_pub[:])
	rp: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&rp, .X25519, recipient.box[:]) {
		return .Invalid
	}
	defer ecdh.public_key_clear(&rp)
	shared: [32]u8
	defer crypto.zero_explicit(&shared, size_of(shared))
	if !ecdh.ecdh(&eph, &rp, shared[:]) {
		return .Invalid
	}
	wk := _wrap_key(shared[:], eph_pub, recipient)
	defer crypto.zero_explicit(&wk, size_of(wk))
	plain: [36]u8
	defer crypto.zero_explicit(&plain, size_of(plain))
	prim.put_u32le(plain[0:4], key.epoch)
	copy(plain[4:], key.key[:])
	copy(out[0:32], eph_pub[:])
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, wk[:])
	defer chacha20poly1305.reset(&ctx)
	iv: [12]u8
	sign := recipient.sign
	chacha20poly1305.seal(&ctx, out[32:68], out[68:], iv[:], sign[:], plain[:])
	return .None
}

open_key_from :: proc(self: ^Identity, box_private: ^ecdh.Private_Key, wrapped: []u8, key: ^Content_Key) -> Error {
	if len(wrapped) != WRAP_LEN {
		return .Invalid
	}
	eph_pub: [32]u8
	copy(eph_pub[:], wrapped[0:32])
	ep: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&ep, .X25519, eph_pub[:]) {
		return .Corrupt
	}
	defer ecdh.public_key_clear(&ep)
	shared: [32]u8
	defer crypto.zero_explicit(&shared, size_of(shared))
	if !ecdh.ecdh(box_private, &ep, shared[:]) {
		return .Corrupt
	}
	wk := _wrap_key(shared[:], eph_pub, self)
	defer crypto.zero_explicit(&wk, size_of(wk))
	plain: [36]u8
	defer crypto.zero_explicit(&plain, size_of(plain))
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, wk[:])
	defer chacha20poly1305.reset(&ctx)
	iv: [12]u8
	sign := self.sign
	if !chacha20poly1305.open(&ctx, plain[:], iv[:], sign[:], wrapped[32:68], wrapped[68:]) {
		return .Auth
	}
	key.epoch = prim.get_u32le(plain[0:4])
	copy(key.key[:], plain[4:])
	return .None
}

@(private)
_card_message :: proc(box: Public_Key) -> (msg: [12 + 32]u8) {
	copy(msg[:], "0ndb card 1\x00")
	b := box
	copy(msg[12:], b[:])
	return
}

@(private)
_wrap_key :: proc(shared: []u8, eph_pub: [32]u8, recipient: ^Identity) -> (k: [32]u8) {
	info: [10 + 32 + 32 + 32]u8
	n := copy(info[:], "0ndb wrap\x00")
	e := eph_pub
	n += copy(info[n:], e[:])
	n += copy(info[n:], recipient.box[:])
	n += copy(info[n:], recipient.sign[:])
	hkdf.extract_and_expand(.SHA256, transmute([]u8)string(KDF_SALT), shared, info[:n], k[:])
	return
}

@(private)
_fk_verify :: proc(data: rawptr, signer: ^Identity, msg: []u8, sig: []u8) -> bool {
	return signature_verify(signer.sign, msg, sig)
}

@(private)
_fk_identity :: proc(data: rawptr) -> Identity {
	k := cast(^File_Keyring)data
	return device_identity(&k.device)
}

@(private)
_fk_sign :: proc(data: rawptr, msg: []u8, sig: ^[64]u8) -> Error {
	k := cast(^File_Keyring)data
	ed25519.sign(&k.device.sign, msg, sig[:])
	return .None
}

@(private)
_fk_wrap :: proc(data: rawptr, recipient: ^Identity, key: ^Content_Key, out: ^[WRAP_LEN]u8) -> Error {
	k := cast(^File_Keyring)data
	return seal_key_to(recipient, key, out, k.random)
}

@(private)
_fk_unwrap :: proc(data: rawptr, wrapped: []u8, key: ^Content_Key) -> Error {
	k := cast(^File_Keyring)data
	self := device_identity(&k.device)
	return open_key_from(&self, &k.device.noise, wrapped, key)
}

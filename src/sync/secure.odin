package osync

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/aes"
import "core:crypto/blake2b"
import "core:crypto/ecdh"
import "core:crypto/ed25519"
import "core:crypto/noise"

NOISE_PROTOCOL :: "Noise_IK_25519_ChaChaPoly_BLAKE2b"
NOISE_PROLOGUE :: "0ndb relay 1"
MSG1_LEN :: 96
MSG2_LEN :: 48
HASH_LEN :: 64

TLS_HEADER :: 5
TLS_TAG :: 16
TLS_MAX_PLAIN :: 16384
TLS_MAX_CIPHER :: TLS_MAX_PLAIN + 256
TLS_MAX_RECORD :: TLS_HEADER + TLS_MAX_CIPHER
TLS_OVERHEAD :: TLS_HEADER + 1 + TLS_TAG
TLS_APPLICATION :: 23

Traffic :: struct {
	key:  [32]u8,
	salt: [4]u8,
	iv:   [8]u8,
}

Session_Keys :: struct {
	tx:   Traffic,
	rx:   Traffic,
	hash: [HASH_LEN]u8,
}

Handshake :: struct {
	hs: noise.Handshake_State,
}

Tls_Dir :: struct {
	ctx: aes.Context_GCM,
	iv:  [12]u8,
	seq: u64,
	on:  bool,
}

handshake_initiate :: proc(h: ^Handshake, static: ^ecdh.Private_Key, relay_public: Public_Key, out: []u8) -> (n: int, err: Error) {
	if len(out) < MSG1_LEN {
		return 0, .Invalid
	}
	rs: ecdh.Public_Key
	rp := relay_public
	if !ecdh.public_key_set_bytes(&rs, .X25519, rp[:]) {
		return 0, .Invalid
	}
	defer ecdh.public_key_clear(&rs)
	if noise.handshake_init(&h.hs, true, transmute([]u8)string(NOISE_PROLOGUE), static, &rs, NOISE_PROTOCOL) != .Ok {
		noise.handshake_reset(&h.hs)
		return 0, .Invalid
	}
	msg, _, st := noise.handshake_initiator_step(&h.hs, nil, nil, out)
	if st != .Handshake_Pending || len(msg) != MSG1_LEN {
		noise.handshake_reset(&h.hs)
		return 0, .Protocol
	}
	return len(msg), .None
}

handshake_finish :: proc(h: ^Handshake, msg2: []u8) -> (keys: Session_Keys, err: Error) {
	defer noise.handshake_reset(&h.hs)
	if len(msg2) != MSG2_LEN {
		return {}, .Protocol
	}
	scratch: [64]u8
	_, _, st := noise.handshake_initiator_step(&h.hs, msg2, nil, scratch[:])
	if st != .Handshake_Complete {
		return {}, .Auth
	}
	return _session_keys(&h.hs, true)
}

handshake_respond :: proc(h: ^Handshake, relay: ^Relay_Key, msg1: []u8, out: []u8) -> (n: int, keys: Session_Keys, err: Error) {
	defer noise.handshake_reset(&h.hs)
	if len(msg1) != MSG1_LEN || len(out) < MSG2_LEN + 16 {
		return 0, {}, .Protocol
	}
	if noise.handshake_init(&h.hs, false, transmute([]u8)string(NOISE_PROLOGUE), &relay.private, nil, NOISE_PROTOCOL) != .Ok {
		return 0, {}, .Invalid
	}
	msg, _, st := noise.handshake_responder_step(&h.hs, msg1, nil, out)
	if st != .Handshake_Complete || len(msg) != MSG2_LEN {
		return 0, {}, .Auth
	}
	if &msg[0] != &out[0] {
		copy(out, msg)
	}
	keys, err = _session_keys(&h.hs, false)
	return MSG2_LEN, keys, err
}

session_keys_clear :: proc(k: ^Session_Keys) {
	crypto.zero_explicit(k, size_of(Session_Keys))
}

hello_message :: proc(binding: []u8, out: ^[16 + HASH_LEN]u8) -> []u8 {
	n := copy(out[:], "0ndb hello 1\x00\x00\x00\x00")
	if len(binding) == HASH_LEN {
		n += copy(out[n:], binding)
	} else {
		ctx: blake2b.Context
		blake2b.init(&ctx)
		blake2b.update(&ctx, binding)
		blake2b.final(&ctx, out[n:])
		n += HASH_LEN
	}
	return out[:n]
}

signature_verify :: proc(public: Public_Key, msg: []u8, sig: []u8) -> bool {
	pk: ed25519.Public_Key
	p := public
	if len(sig) != 64 || !ed25519.public_key_set_bytes(&pk, p[:]) {
		return false
	}
	return ed25519.verify(&pk, msg, sig)
}

hello_verify :: proc(public: Public_Key, sig: []u8, hash: []u8) -> bool {
	pk: ed25519.Public_Key
	p := public
	if len(sig) != 64 || !ed25519.public_key_set_bytes(&pk, p[:]) {
		return false
	}
	buf: [16 + HASH_LEN]u8
	msg := hello_message(hash, &buf)
	return ed25519.verify(&pk, msg, sig)
}

tls_dir_init :: proc(d: ^Tls_Dir, t: ^Traffic) {
	aes.init_gcm(&d.ctx, t.key[:])
	copy(d.iv[0:4], t.salt[:])
	copy(d.iv[4:12], t.iv[:])
	d.seq = 0
	d.on = true
}

tls_dir_reset :: proc(d: ^Tls_Dir) {
	if d.on {
		aes.reset_gcm(&d.ctx)
	}
	crypto.zero_explicit(d, size_of(Tls_Dir))
}

tls_seal :: proc(d: ^Tls_Dir, dst: []u8, plain: []u8) -> int {
	n := len(plain)
	inner := n + 1
	total := TLS_HEADER + inner + TLS_TAG
	dst[0] = TLS_APPLICATION
	dst[1] = 3
	dst[2] = 3
	dst[3] = u8((inner + TLS_TAG) >> 8)
	dst[4] = u8(inner + TLS_TAG)
	body := dst[TLS_HEADER:][:inner]
	copy(body, plain)
	body[n] = TLS_APPLICATION
	nonce := _tls_nonce(d)
	aes.seal_gcm(&d.ctx, body, dst[TLS_HEADER + inner:][:TLS_TAG], nonce[:], dst[:TLS_HEADER], body)
	d.seq += 1
	return total
}

tls_record_len :: proc "contextless" (head: []u8) -> (int, Error) {
	if head[0] != TLS_APPLICATION || head[1] != 3 || head[2] != 3 {
		return 0, .Protocol
	}
	n := int(head[3]) << 8 | int(head[4])
	if n < TLS_TAG + 1 || n > TLS_MAX_CIPHER {
		return 0, .Protocol
	}
	return TLS_HEADER + n, .None
}

tls_open :: proc(d: ^Tls_Dir, rec: []u8) -> ([]u8, Error) {
	ct := rec[TLS_HEADER:len(rec) - TLS_TAG]
	nonce := _tls_nonce(d)
	if !aes.open_gcm(&d.ctx, ct, nonce[:], rec[:TLS_HEADER], ct, rec[len(rec) - TLS_TAG:]) {
		return nil, .Corrupt
	}
	d.seq += 1
	end := len(ct)
	for end > 0 && ct[end - 1] == 0 {
		end -= 1
	}
	if end == 0 || ct[end - 1] != TLS_APPLICATION {
		return nil, .Protocol
	}
	return ct[:end - 1], .None
}

@(private)
_tls_nonce :: proc "contextless" (d: ^Tls_Dir) -> (nonce: [12]u8) {
	nonce = d.iv
	for i in 0 ..< 8 {
		nonce[11 - i] ~= u8(d.seq >> (8 * u64(i)))
	}
	return
}

@(private)
_session_keys :: proc(hs: ^noise.Handshake_State, initiator: bool) -> (keys: Session_Keys, err: Error) {
	h, hst := noise.handshake_hash(hs)
	if hst != .Ok || len(h) != HASH_LEN {
		return {}, .Protocol
	}
	copy(keys.hash[:], h)
	css: noise.Cipher_States
	defer noise.cipherstates_reset(&css)
	if noise.handshake_split(hs, &css) != .Ok {
		return {}, .Protocol
	}
	i2r := _traffic(&css.c1_i_to_r.ctx)
	r2i := _traffic(&css.c2_r_to_i.ctx)
	if initiator {
		keys.tx, keys.rx = i2r, r2i
	} else {
		keys.tx, keys.rx = r2i, i2r
	}
	crypto.zero_explicit(&i2r, size_of(Traffic))
	crypto.zero_explicit(&r2i, size_of(Traffic))
	return keys, .None
}

@(private)
_traffic :: proc(ctx: ^aead.Context) -> (t: Traffic) {
	zeros: [size_of(Traffic)]u8
	out: [size_of(Traffic)]u8
	tag: [16]u8
	iv: [12]u8
	for i in 4 ..< 12 {
		iv[i] = 0xff
	}
	aead.seal_ctx(ctx, out[:], tag[:], iv[:], nil, zeros[:])
	copy(t.key[:], out[0:32])
	copy(t.salt[:], out[32:36])
	copy(t.iv[:], out[36:44])
	crypto.zero_explicit(&out, size_of(out))
	return
}

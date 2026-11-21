package web

import "core:crypto"
import "core:crypto/ed25519"
import "../obj"
import "../prim"
import osync "../sync"

SHARE_PREFIX :: "0ndbshare1"
SHARE_VERSION :: 2
SHARE_EPOCHS :: 32
CAP_CREDENTIAL :: u8(2)
CAPABILITY_LEN :: 1 + 16 * 3 + 1 + 1 + 8 + 32 + 32 + 64

Share_Grant :: struct {
	object:  prim.Id,
	kind:    obj.Kind,
	key:     osync.Content_Key,
	epochs:  [SHARE_EPOCHS]Share_Epoch,
	nepochs: int,
}

Share_Epoch :: struct {
	tag: osync.Epoch_Tag,
	key: [32]u8,
}

share_epoch_key :: proc(s: ^Session, tag: osync.Epoch_Tag) -> (key: [32]u8, ok: bool) {
	for i in 0 ..< s.share.nepochs {
		if s.share.epochs[i].tag == tag {
			return s.share.epochs[i].key, true
		}
	}
	return
}

Cap_Credentials :: struct {
	s:     ^Session,
	token: [CAPABILITY_LEN]u8,
}

session_open_share :: proc(s: ^Session, code: string) -> osync.Error {
	if len(code) <= len(SHARE_PREFIX) || code[:len(SHARE_PREFIX)] != SHARE_PREFIX || (len(code) - len(SHARE_PREFIX)) % 2 != 0 {
		return .Invalid
	}
	raw := make([]u8, (len(code) - len(SHARE_PREFIX)) / 2, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	if !prim.hex_decode(raw, transmute([]u8)code[len(SHARE_PREFIX):]) {
		return .Invalid
	}
	r := prim.reader(raw)
	share := prim.read_bytes(&r)
	token := prim.read_bytes(&r)
	space := prim.read_id(&r)
	relay := prim.read_str(&r)
	rkey := prim.read_bytes(&r)
	if !prim.reader_done(&r) || len(token) != CAPABILITY_LEN || len(rkey) != 32 {
		return .Invalid
	}
	sr := prim.reader(share)
	if prim.read_u8(&sr) != SHARE_VERSION {
		return .Invalid
	}
	_ = prim.read_id(&sr)
	sspace := prim.read_id(&sr)
	object := prim.read_id(&sr)
	kind := prim.read_u8(&sr)
	wrapped: [osync.WRAP_LEN]u8
	prim.read_fixed(&sr, wrapped[:])
	ne := prim.read_uvarint(&sr)
	if !prim.reader_ok(&sr) || ne > SHARE_EPOCHS || sspace != space || kind < 1 || kind > 4 {
		return .Invalid
	}
	tags: [SHARE_EPOCHS]osync.Epoch_Tag
	wraps: [SHARE_EPOCHS][osync.WRAP_LEN]u8
	for i in 0 ..< int(ne) {
		prim.read_fixed(&sr, tags[i][:])
		prim.read_fixed(&sr, wraps[i][:])
	}
	if !prim.reader_done(&sr) {
		return .Invalid
	}
	self := osync.device_identity(&s.device)
	key: osync.Content_Key
	osync.open_key_from(&self, &s.device.noise, wrapped[:], &key) or_return
	s.shared = true
	s.space_id = space
	s.share = Share_Grant{object = object, kind = obj.Kind(kind), key = key}
	crypto.zero_explicit(&key, size_of(key))
	for i in 0 ..< int(ne) {
		ek: osync.Content_Key
		if osync.open_key_from(&self, &s.device.noise, wraps[i][:], &ek) == .None {
			s.share.epochs[s.share.nepochs] = Share_Epoch{tag = tags[i], key = ek.key}
			s.share.nepochs += 1
		}
		crypto.zero_explicit(&ek, size_of(ek))
	}
	copy(s.relay_pub[:], rkey)
	s.relay_addr = _clone(relay, s.allocator)
	s.cap_creds.s = s
	copy(s.cap_creds.token[:], token)
	s.creds = osync.Credentials{data = &s.cap_creds, produce = _cap_produce}
	_object_get(s, object, obj.Kind(kind))
	return .None
}

@(private)
_cap_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	cc := (^Cap_Credentials)(data)
	buf: [16 + osync.HASH_LEN]u8
	msg := osync.hello_message(binding, &buf)
	sig: [64]u8
	ed25519.sign(&cc.s.device.sign, msg, sig[:])
	w := prim.writer(out)
	prim.write_u8(&w, CAP_CREDENTIAL)
	prim.write_raw(&w, cc.token[:])
	prim.write_raw(&w, cc.s.device.public[:])
	prim.write_raw(&w, sig[:])
	return .No_Memory if w.err != .None else .None
}

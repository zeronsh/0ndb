package osync

import "core:crypto"
import "../prim"

GRANT_KEYS_STREAM :: "grantkeys/"
GRANT_WRAP :: u8(1)

@(private)
GRANT_SEAL_CONTEXT :: "0ndb grant key"

Grant_Wrap :: struct {
	grantee: Public_Key,
	tag:     Epoch_Tag,
	sealed:  []u8,
}

grant_keys_name :: proc(object: prim.Id, allocator := context.temp_allocator) -> string {
	h := prim.id_hex(object)
	out := make([]u8, len(GRANT_KEYS_STREAM) + len(h), allocator)
	copy(out, GRANT_KEYS_STREAM)
	copy(out[len(GRANT_KEYS_STREAM):], h[:])
	return string(out)
}

@(private)
_grant_ctx :: proc(object: prim.Id) -> (ctx: [len(GRANT_SEAL_CONTEXT) + 16]u8) {
	o := object
	copy(ctx[:], GRANT_SEAL_CONTEXT)
	copy(ctx[len(GRANT_SEAL_CONTEXT):], o[:])
	return
}

grant_wrap_encode :: proc(grantee: Identity, object: prim.Id, tag: Epoch_Tag, number: u32, key: [32]u8, out: ^[dynamic]u8, random := prim.Random{}) -> Error {
	plain: [4 + 32]u8
	prim.put_u32le(plain[:4], number)
	k := key
	copy(plain[4:], k[:])
	sealed := make([dynamic]u8, context.temp_allocator)
	g := grantee
	ctx := _grant_ctx(object)
	err := seal_bundle_to(&g, plain[:], ctx[:], &sealed, random)
	crypto.zero_explicit(&plain, size_of(plain))
	err or_return
	w := prim.writer(out)
	prim.write_u8(&w, GRANT_WRAP)
	prim.write_raw(&w, g.sign[:])
	t := tag
	prim.write_raw(&w, t[:])
	prim.write_bytes(&w, sealed[:])
	return .No_Memory if w.err != .None else .None
}

grant_wrap_decode :: proc(data: []u8, gw: ^Grant_Wrap) -> Error {
	r := prim.reader(data)
	if prim.read_u8(&r) != GRANT_WRAP {
		return .Corrupt
	}
	prim.read_fixed(&r, gw.grantee[:])
	prim.read_fixed(&r, gw.tag[:])
	gw.sealed = prim.read_bytes(&r)
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

grant_wrap_open :: proc(gw: ^Grant_Wrap, keyring: ^Keyring, object: prim.Id) -> (number: u32, key: [32]u8, err: Error) {
	plain: [4 + 32]u8
	defer crypto.zero_explicit(&plain, size_of(plain))
	ctx := _grant_ctx(object)
	open_bundle(keyring, gw.sealed, ctx[:], plain[:]) or_return
	number = prim.get_u32le(plain[:4])
	copy(key[:], plain[4:])
	return number, key, .None
}

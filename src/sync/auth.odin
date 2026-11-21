package osync

import "base:runtime"
import "core:crypto/ed25519"
import "../prim"

CREDENTIAL_MAX :: 8192
SPACE_CREDENTIAL_LEN :: 1 + 32 + 32 + 64 + 64

Credentials :: struct {
	data:    rawptr,
	produce: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> Error,
}

Access :: enum u8 {
	List,
	Read,
	Append,
	Drop,
	Put,
	Get,
	Redact,
}

Principal :: struct {
	namespace:   Space_Id,
	participant: Device_Id,
	quota:       i64,
	read_all:    bool,
	append_own:  bool,
	objects:     bool,
	check:       proc(data: rawptr, p: ^Principal, access: Access, id: [32]u8) -> bool,
	data:        rawptr,
}

Authorizer :: struct {
	data:      rawptr,
	authorize: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code,
}

Space_Credentials :: struct {
	space:   ^Space,
	keyring: Keyring,
}

Space_Authorizer :: struct {
	allow:         Allow,
	open:          bool,
	default_quota: i64,
	allocator:     runtime.Allocator,
}

space_credentials :: proc(c: ^Space_Credentials) -> Credentials {
	return Credentials{data = c, produce = _space_produce}
}

space_authorizer_init :: proc(a: ^Space_Authorizer, vfs: prim.Vfs, allow_path: string, open: bool, default_quota: i64, allocator := context.allocator) -> Error {
	a^ = {
		open          = open,
		default_quota = default_quota,
		allocator     = allocator,
	}
	path := _clone_string(allow_path, allocator) or_return
	allow_init(&a.allow, vfs, path, allocator)
	return .None
}

space_authorizer_destroy :: proc(a: ^Space_Authorizer) {
	if len(a.allow.path) > 0 {
		delete(a.allow.path, a.allocator)
	}
	allow_destroy(&a.allow)
}

space_authorizer :: proc(a: ^Space_Authorizer) -> Authorizer {
	return Authorizer{data = a, authorize = _space_authorize}
}

principal_allows :: proc(p: ^Principal, access: Access, id: [32]u8) -> bool {
	switch access {
	case .List, .Read:
		if p.read_all {
			return true
		}
	case .Append, .Drop, .Redact:
		if p.append_own {
			v := id
			pid := p.participant
			if string(v[:16]) == string(pid[:]) {
				return true
			}
		}
	case .Put, .Get:
		if p.objects {
			return true
		}
	}
	return p.check != nil && p.check(p.data, p, access, id)
}

@(private)
_space_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> Error {
	c := cast(^Space_Credentials)data
	id := c.keyring.identity(c.keyring.data)
	buf: [16 + HASH_LEN]u8
	msg := hello_message(binding, &buf)
	ssig: [64]u8
	ed25519.sign(&c.space.auth, msg, ssig[:])
	psig: [64]u8
	c.keyring.sign(c.keyring.data, msg, &psig) or_return
	w := prim.writer(out)
	prim.write_u8(&w, 1)
	prim.write_raw(&w, c.space.auth_public[:])
	prim.write_raw(&w, id.sign[:])
	prim.write_raw(&w, ssig[:])
	prim.write_raw(&w, psig[:])
	return .No_Memory if w.err != .None else .None
}

@(private)
_space_authorize :: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	a := cast(^Space_Authorizer)data
	if len(credential) != SPACE_CREDENTIAL_LEN || credential[0] != 1 {
		return .Auth
	}
	space_pub: Public_Key
	part_pub: Public_Key
	copy(space_pub[:], credential[1:33])
	copy(part_pub[:], credential[33:65])
	if !local {
		if len(binding) == 0 || !hello_verify(space_pub, credential[65:129], binding) || !hello_verify(part_pub, credential[129:193], binding) {
			return .Auth
		}
	}
	id := space_id(space_pub)
	quota, allowed := allow_lookup(&a.allow, id)
	if !allowed {
		if !a.open {
			return .Auth
		}
		quota = a.default_quota
	}
	p^ = Principal {
		namespace   = id,
		participant = device_id(part_pub),
		quota       = quota,
		read_all    = true,
		append_own  = true,
		objects     = true,
	}
	return .None
}

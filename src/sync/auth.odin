package osync

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
	Forget,
}

Principal :: struct {
	namespace:   Space_Id,
	participant: Device_Id,
	quota:       i64,
	max_conns:   int,
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

space_credentials :: proc(c: ^Space_Credentials) -> Credentials {
	return Credentials{data = c, produce = _space_produce}
}

principal_allows :: proc(p: ^Principal, access: Access, id: [32]u8) -> bool {
	switch access {
	case .List, .Read:
		if p.read_all {
			return true
		}
	case .Redact:
		if p.append_own {
			return true
		}
	case .Append, .Drop:
		if p.append_own {
			v := id
			pid := p.participant
			if string(v[:16]) == string(pid[:]) {
				return true
			}
		}
	case .Put, .Get, .Forget:
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


package api

import eng "../../engine"
import "../../prim"
import osync "../../sync"

MEMBER_KIND_NAMES := [8]string{"device", "account", "recovery", "custodian", "pool", "runner", "guest", "directory"}
MEMBER_ROLE_NAMES := [4]string{"owner", "admin", "member", "reader"}
ENROLL_NAMES := [8]string{"genesis", "approval", "recovery", "account", "custodian", "pool", "grant", "directory"}
LOGIN_PATH_NAMES := [5]string{"created", "passkey", "approval", "cross_device", "recovery"}
LOGIN_STATUS_NAMES := [3]string{"done", "waiting", "no_approver"}
POOL_ACCESS_NAMES := [4]string{"off", "everything", "workspace", "only_sent"}
ECOSYSTEM_NAMES := [9]string{"unknown", "apple", "google", "microsoft", "1password", "bitwarden", "security_key", "recovery", "test"}

@(private)
_attach_all :: proc(c: ^Call) {
	for sp in eng.space_list(c.api.e, context.temp_allocator) {
		_attach(c, sp.id)
	}
}

@(private)
_login_out :: proc(o: ^Out, r: eng.Login_Result) {
	o_enum(o, "path", u64(r.path), LOGIN_PATH_NAMES[:])
	o_enum(o, "status", u64(r.status), LOGIN_STATUS_NAMES[:])
	c := r.code
	o_str(o, "code", string(c[:]) if r.status == .Waiting else "")
	o_u64(o, "spaces", u64(r.spaces))
}

op_account_login :: proc(c: ^Call, o: ^Out) -> Status {
	rk, ok := _relay_key(c)
	if !ok {
		return .Invalid
	}
	r, err := eng.account_login(c.api.e, a_str(c, "subject"), a_str(c, "label"), a_str(c, "relay"), rk)
	if err != .None {
		return status_of(err)
	}
	_attach_all(c)
	_login_out(o, r)
	return .Ok
}

op_account_login_cross_device :: proc(c: ^Call, o: ^Out) -> Status {
	r, err := eng.account_login_cross_device(c.api.e, a_str(c, "subject"))
	if err != .None {
		return status_of(err)
	}
	_attach_all(c)
	_login_out(o, r)
	return .Ok
}

op_account_login_recovery :: proc(c: ^Call, o: ^Out) -> Status {
	r, err := eng.account_login_recovery(c.api.e, a_str(c, "subject"), a_str(c, "key"))
	if err != .None {
		return status_of(err)
	}
	_attach_all(c)
	_login_out(o, r)
	return .Ok
}

op_account_state :: proc(c: ^Call, o: ^Out) -> Status {
	a := eng.account_state(c.api.e)
	o_bool(o, "signed_in", a.have)
	o_bytes(o, "account", a.sign[:] if a.have else nil)
	o_str(o, "subject", a.subject if a.have else "")
	o_enum(o, "pool", u64(a.pool) if a.have else 0, POOL_ACCESS_NAMES[:])
	o_str(o, "relay", a.relay if a.have else "")
	waiting, code, failed := eng.login_waiting(c.api.e)
	o_bool(o, "waiting", waiting)
	o_str(o, "code", string(code[:]) if waiting else "")
	o_bool(o, "no_approver", failed)
	return .Ok
}

op_account_listen :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.account_listen(c.api.e))
}

op_approval_list :: proc(c: ^Call, o: ^Out) -> Status {
	list := eng.approvals_pending(c.api.e, context.temp_allocator)
	o_arr(o, "approvals", len(list))
	for &a in list {
		o_obj(o, "")
		o_id(o, "device", a.device)
		code := a.code
		o_str(o, "code", string(code[:]))
		o_str(o, "label", a.label)
		o_i64(o, "at", a.at)
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_approval_respond :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.approval_respond(c.api.e, a_str(c, "code"), a_bool(c, "approve")))
}

op_account_wrappers :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.account_wrappers(c.api.e, context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "passkeys", len(list))
	for &w in list {
		o_obj(o, "")
		o_bytes(o, "credential", w.credential)
		o_str(o, "label", w.label)
		o_enum(o, "ecosystem", u64(w.ecosystem), ECOSYSTEM_NAMES[:])
		o_id(o, "added_by", w.added_by)
		o_u64(o, "added_at", w.added_at)
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_account_wrapper_remove :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.account_wrapper_remove(c.api.e, a_bytes(c, "credential")))
}

op_account_recovery_key :: proc(c: ^Call, o: ^Out) -> Status {
	key, err := eng.account_recovery_key(c.api.e, context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_str(o, "key", key)
	return .Ok
}

op_account_devices :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.account_devices(c.api.e, context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "devices", len(list))
	for &d in list {
		o_obj(o, "")
		o_id(o, "device", d.device)
		o_enum(o, "kind", u64(d.kind), MEMBER_KIND_NAMES[:])
		o_enum(o, "method", u64(d.method), ENROLL_NAMES[:])
		o_u64(o, "spaces", u64(d.spaces))
		o_bool(o, "removed", d.removed)
		o_bool(o, "self", d.self)
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_account_pool :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.account_pool_set(c.api.e, osync.Pool_Access(min(a_u64(c, "access"), 3))))
}

op_device_remove :: proc(c: ^Call, o: ^Out) -> Status {
	n, err := eng.device_remove(c.api.e, a_id(c, "device"))
	if err != .None {
		return status_of(err)
	}
	o_u64(o, "spaces", u64(n))
	return .Ok
}

op_space_members :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.space_members(c.api.e, a_id(c, "space"), context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "members", len(list))
	for &m in list {
		o_obj(o, "")
		o_id(o, "device", m.device)
		o_enum(o, "kind", u64(m.kind), MEMBER_KIND_NAMES[:])
		o_enum(o, "role", u64(m.role), MEMBER_ROLE_NAMES[:])
		o_enum(o, "method", u64(m.method), ENROLL_NAMES[:])
		o_id(o, "added_by", m.added_by)
		o_u64(o, "added_at", m.added_at)
		o_u64(o, "expires", m.expires)
		o_bool(o, "removed", m.removed)
		o_bool(o, "in_epoch", m.in_tree)
		o_bool(o, "self", m.self)
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_space_members_status :: proc(c: ^Call, o: ^Out) -> Status {
	s, err := eng.space_members_status(c.api.e, a_id(c, "space"))
	if err != .None {
		return status_of(err)
	}
	o_u64(o, "epoch", u64(s.epoch))
	o_bool(o, "eligible", s.eligible)
	o_bool(o, "held", s.held)
	o_u64(o, "members", u64(s.members))
	o_u64(o, "records", u64(s.records))
	o_bool(o, "removed", s.removed)
	o_bool(o, "revoked", s.revoked)
	return .Ok
}

op_member_remove :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.member_remove(c.api.e, a_id(c, "space"), a_id(c, "device")))
}

op_member_add :: proc(c: ^Call, o: ^Out) -> Status {
	id, cerr := osync.card_verify(a_bytes(c, "card"))
	if cerr != .None {
		return .Invalid
	}
	kind := osync.Member_Kind(min(a_u64(c, "kind"), u64(max(osync.Member_Kind))))
	role := osync.Role(min(max(a_u64(c, "role"), 1), u64(max(osync.Role))))
	proof, err := eng.member_add(c.api.e, a_id(c, "space"), id, kind, role, .Approval, a_u64(c, "lease_ms"), context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_bytes(o, "proof", proof)
	return .Ok
}

op_space_rotate :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.space_rotate(c.api.e, a_id(c, "space")))
}

op_space_pool :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.space_pool_set(c.api.e, a_id(c, "space"), a_bool(c, "on")))
}

op_space_join_enrollment :: proc(c: ^Call, o: ^Out) -> Status {
	rk, ok := _relay_key(c)
	if !ok {
		return .Invalid
	}
	id, err := eng.space_join_enrollment(c.api.e, a_id(c, "space"), a_bytes(c, "proof"), a_str(c, "name"), a_str(c, "relay"), rk)
	if err != .None {
		return status_of(err)
	}
	_attach(c, id)
	o_id(o, "space", id)
	return .Ok
}

op_account_join_space :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.account_join_space(c.api.e, a_id(c, "space")))
}

op_pool_enroll :: proc(c: ^Call, o: ^Out) -> Status {
	en, err := eng.pool_enroll(c.api.e, a_bytes(c, "token"), a_bytes(c, "card"), a_bytes(c, "evidence"), context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_bytes(o, "enrollment", en)
	return .Ok
}

op_runner_enroll :: proc(c: ^Call, o: ^Out) -> Status {
	n, err := eng.runner_enroll(c.api.e, a_bytes(c, "enrollment"))
	if err != .None {
		return status_of(err)
	}
	_attach_all(c)
	o_u64(o, "spaces", u64(n))
	return .Ok
}

op_lease_renew :: proc(c: ^Call, o: ^Out) -> Status {
	o_u64(o, "renewed", u64(eng.lease_renew(c.api.e)))
	return .Ok
}

@(private)
_identity_arg :: proc(c: ^Call, name: string) -> (id: osync.Identity, ok: bool) {
	i, err := osync.card_verify(a_bytes(c, name))
	return i, err == .None
}

op_directory_add :: proc(c: ^Call, o: ^Out) -> Status {
	person, ok := _identity_arg(c, "person")
	if !ok {
		return .Invalid
	}
	cards := a_strs(c, "devices")
	devs := make([dynamic]osync.Identity, 0, len(cards), context.temp_allocator)
	for x in cards {
		raw := make([]u8, len(x) / 2, context.temp_allocator)
		if len(x) % 2 != 0 || !prim.hex_decode(raw, transmute([]u8)x) {
			return .Invalid
		}
		id, err := osync.card_verify(raw)
		if err != .None {
			return .Invalid
		}
		append(&devs, id)
	}
	role := osync.Role(min(max(a_u64(c, "role"), 1), u64(max(osync.Role))))
	return status_of(eng.directory_add(c.api.e, a_id(c, "space"), person, role, devs[:]))
}

op_directory_remove :: proc(c: ^Call, o: ^Out) -> Status {
	b := a_bytes(c, "person")
	if len(b) != 32 {
		return .Invalid
	}
	k: osync.Public_Key
	copy(k[:], b)
	return status_of(eng.directory_remove(c.api.e, a_id(c, "space"), k))
}

op_account_login_prf :: proc(c: ^Call, o: ^Out) -> Status {
	rk, ok := _relay_key(c)
	p := a_bytes(c, "prf")
	if !ok || len(p) != 32 {
		return .Invalid
	}
	prf: [32]u8
	copy(prf[:], p)
	r, err := eng.account_login_prf(c.api.e, a_str(c, "subject"), a_bytes(c, "credential"), prf, a_str(c, "label"), a_str(c, "relay"), rk)
	if err != .None {
		return status_of(err)
	}
	_attach_all(c)
	_login_out(o, r)
	return .Ok
}

op_account_passkey_add :: proc(c: ^Call, o: ^Out) -> Status {
	p := a_bytes(c, "prf")
	if len(p) == 0 {
		return status_of(eng.account_passkey_add(c.api.e, a_str(c, "label")))
	}
	if len(p) != 32 {
		return .Invalid
	}
	prf: [32]u8
	copy(prf[:], p)
	return status_of(eng.account_passkey_add_prf(c.api.e, a_bytes(c, "credential"), prf, a_str(c, "label")))
}

op_account_idp_salt :: proc(c: ^Call, o: ^Out) -> Status {
	salt := eng.account_idp_salt(a_str(c, "subject"))
	o_bytes(o, "salt", salt[:])
	return .Ok
}

op_account_sign_out :: proc(c: ^Call, o: ^Out) -> Status {
	n, err := eng.account_sign_out(c.api.e, !a_bool(c, "keep_relay"))
	if err != .None {
		return status_of(err)
	}
	o_u64(o, "spaces", u64(n))
	return .Ok
}

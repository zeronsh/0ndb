package capi

import eng "../engine"
import "../prim"
import osync "../sync"

ACCOUNT_RECORD_MAX :: 64 * 1024
ACCOUNT_ENTRIES_MAX :: 4 * 1024 * 1024
CREDENTIAL_MAX_LEN :: 1024

C_Unlock_Option :: struct {
	credential:     [^]u8,
	credential_len: uint,
	salt:           [32]u8,
}

C_Unlock :: struct {
	size:   u32,
	ud:     rawptr,
	unlock: proc "c" (ud: rawptr, rp_user: [^]u8, rp_user_len: uint, options: [^]C_Unlock_Option, count: uint, mode: i32, credential: [^]u8, cap: uint, len: ^uint, prf: ^[32]u8) -> i32,
	enroll: proc "c" (ud: rawptr, rp_user: [^]u8, rp_user_len: uint, label: [^]u8, label_len: uint, salt: ^[32]u8, credential: [^]u8, cap: uint, len: ^uint, prf: ^[32]u8, ecosystem: ^i32) -> i32,
}

C_Sealed_Store :: struct {
	size: u32,
	ud:   rawptr,
	get:  proc "c" (ud: rawptr, subject: [^]u8, subject_len: uint, record: [^]u8, record_cap: uint, record_len: ^uint, entries: [^]u8, entries_cap: uint, entries_len: ^uint) -> i32,
	put:  proc "c" (ud: rawptr, subject: [^]u8, subject_len: uint, record: [^]u8, record_len: uint, prev_seq: u64) -> i32,
	add:  proc "c" (ud: rawptr, subject: [^]u8, subject_len: uint, entry: [^]u8, entry_len: uint) -> i32,
}

C_Runner_Pool :: struct {
	size:     u32,
	ud:       rawptr,
	identity: proc "c" (ud: rawptr, out: ^C_Identity) -> i32,
	verify:   proc "c" (ud: rawptr, token: [^]u8, token_len: uint, runner: ^C_Identity, lease_ms: ^u64) -> i32,
	attest:   proc "c" (ud: rawptr, evidence: [^]u8, evidence_len: uint, runner: ^C_Identity) -> i32,
	joined:   proc "c" (ud: rawptr, space: ^[16]u8, name: [^]u8, name_len: uint, relay: [^]u8, relay_len: uint, relay_key: ^[32]u8, proof: [^]u8, proof_len: uint),
}

Account_Plugs :: struct {
	unlock: C_Unlock,
	store:  C_Sealed_Store,
	pool:   C_Runner_Pool,
}

@(private)
_status_err :: proc "contextless" (rc: i32) -> osync.Error {
	switch rc {
	case 0:
		return .None
	case 1:
		return .Not_Found
	case 2:
		return .Conflict
	case 3:
		return .Permission
	case 4:
		return .Unsupported
	}
	return .Io
}

account_plugs_setup :: proc(p: ^Account_Plugs, cfg: ^Config, ec: ^eng.Config) -> bool {
	if _has(cfg, offset_of(Config, unlock)) && cfg.unlock != nil {
		if !_copy_table(&p.unlock, cfg.unlock) || p.unlock.unlock == nil {
			return false
		}
		ec.unlock = osync.Unlock{data = &p.unlock, unlock = _c_unlock, register = _c_enroll if p.unlock.enroll != nil else nil}
	}
	if _has(cfg, offset_of(Config, sealed_store)) && cfg.sealed_store != nil {
		if !_copy_table(&p.store, cfg.sealed_store) || p.store.get == nil || p.store.put == nil || p.store.add == nil {
			return false
		}
		ec.sealed_store = osync.Sealed_Store{data = &p.store, get = _c_store_get, put = _c_store_put, add = _c_store_add}
	}
	if _has(cfg, offset_of(Config, runner_pool)) && cfg.runner_pool != nil {
		if !_copy_table(&p.pool, cfg.runner_pool) {
			return false
		}
		ec.runner_pool = eng.Runner_Pool {
			data     = &p.pool,
			identity = _c_pool_identity if p.pool.identity != nil else nil,
			verify   = _c_pool_verify if p.pool.verify != nil else nil,
			attest   = _c_pool_attest if p.pool.attest != nil else nil,
			joined   = _c_pool_joined if p.pool.joined != nil else nil,
		}
	}
	if _has(cfg, offset_of(Config, approver)) {
		ec.approver = cfg.approver != 0
	}
	return true
}

@(private)
_c_unlock :: proc(data: rawptr, rp_user: []u8, options: []osync.Unlock_Option, mode: osync.Unlock_Mode, credential: ^[dynamic]u8, prf: ^[32]u8) -> osync.Error {
	u := (^C_Unlock)(data)
	opts := make([]C_Unlock_Option, len(options), context.temp_allocator)
	for o, i in options {
		opts[i] = C_Unlock_Option{credential = raw_data(o.credential), credential_len = uint(len(o.credential)), salt = o.salt}
	}
	buf: [CREDENTIAL_MAX_LEN]u8
	n: uint
	rc := u.unlock(u.ud, raw_data(rp_user), uint(len(rp_user)), raw_data(opts), uint(len(opts)), i32(mode), raw_data(buf[:]), uint(len(buf)), &n, prf)
	if rc != 0 {
		return _status_err(rc)
	}
	if n > uint(len(buf)) {
		return .Too_Large
	}
	append(credential, ..buf[:n])
	return .None
}

@(private)
_c_enroll :: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, credential: ^[dynamic]u8, prf: ^[32]u8, ecosystem: ^osync.Ecosystem) -> osync.Error {
	u := (^C_Unlock)(data)
	buf: [CREDENTIAL_MAX_LEN]u8
	n: uint
	s := salt
	eco: i32
	rc := u.enroll(u.ud, raw_data(rp_user), uint(len(rp_user)), raw_data(label), uint(len(label)), &s, raw_data(buf[:]), uint(len(buf)), &n, prf, &eco)
	if rc != 0 {
		return _status_err(rc)
	}
	if n > uint(len(buf)) || eco < 0 || eco > i32(max(osync.Ecosystem)) {
		return .Invalid
	}
	append(credential, ..buf[:n])
	ecosystem^ = osync.Ecosystem(eco)
	return .None
}

@(private)
_c_store_get :: proc(data: rawptr, subject: []u8, record: ^[dynamic]u8, entries: ^[dynamic][]u8) -> osync.Error {
	st := (^C_Sealed_Store)(data)
	rbuf := make([]u8, ACCOUNT_RECORD_MAX, context.temp_allocator)
	ebuf := make([]u8, ACCOUNT_ENTRIES_MAX, context.temp_allocator)
	rn, en: uint
	rc := st.get(st.ud, raw_data(subject), uint(len(subject)), raw_data(rbuf), uint(len(rbuf)), &rn, raw_data(ebuf), uint(len(ebuf)), &en)
	if rc != 0 {
		return _status_err(rc)
	}
	if rn > uint(len(rbuf)) || en > uint(len(ebuf)) {
		return .Too_Large
	}
	append(record, ..rbuf[:rn])
	pos := 0
	for pos + 4 <= int(en) {
		n := int(prim.get_u32le(ebuf[pos:]))
		if pos + 4 + n > int(en) {
			return .Corrupt
		}
		append(entries, ebuf[pos + 4:][:n])
		pos += 4 + n
	}
	return .None
}

@(private)
_c_store_put :: proc(data: rawptr, subject: []u8, record: []u8, prev_seq: u64) -> osync.Error {
	st := (^C_Sealed_Store)(data)
	return _status_err(st.put(st.ud, raw_data(subject), uint(len(subject)), raw_data(record), uint(len(record)), prev_seq))
}

@(private)
_c_store_add :: proc(data: rawptr, subject: []u8, entry: []u8) -> osync.Error {
	st := (^C_Sealed_Store)(data)
	return _status_err(st.add(st.ud, raw_data(subject), uint(len(subject)), raw_data(entry), uint(len(entry))))
}

@(private)
_c_pool_identity :: proc(data: rawptr) -> osync.Identity {
	p := (^C_Runner_Pool)(data)
	c: C_Identity
	if p.identity(p.ud, &c) != 0 {
		return {}
	}
	return osync.identity_of(c.sign, c.box)
}

@(private)
_c_pool_verify :: proc(data: rawptr, token: []u8, runner: osync.Identity) -> (u64, osync.Error) {
	p := (^C_Runner_Pool)(data)
	c := _id_to_c(runner)
	lease: u64
	rc := p.verify(p.ud, raw_data(token), uint(len(token)), &c, &lease)
	return lease, _status_err(rc)
}

@(private)
_c_pool_attest :: proc(data: rawptr, evidence: []u8, runner: osync.Identity) -> osync.Error {
	p := (^C_Runner_Pool)(data)
	c := _id_to_c(runner)
	return _status_err(p.attest(p.ud, raw_data(evidence), uint(len(evidence)), &c))
}

@(private)
_c_pool_joined :: proc(data: rawptr, space: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, proof: []u8) {
	p := (^C_Runner_Pool)(data)
	s := ([16]u8)(space)
	rk := relay_public
	p.joined(p.ud, &s, raw_data(name), uint(len(name)), raw_data(relay), uint(len(relay)), &rk, raw_data(proof), uint(len(proof)))
}


package capi

import "base:runtime"
import "core:sync"
import "./api"
import eng "../engine"
import "../prim"
import osync "../sync"

C_Unlock_Option :: struct {
	credential:     [^]u8,
	credential_len: uint,
	salt:           [32]u8,
}

C_Plug_Reply :: struct {
	size:           u32,
	record:         [^]u8,
	record_len:     uint,
	entries:        [^]u8,
	entries_len:    uint,
	credential:     [^]u8,
	credential_len: uint,
	prf:            [32]u8,
	ecosystem:      i32,
	lease_ms:       u64,
}

C_Unlock :: struct {
	size:   u32,
	ud:     rawptr,
	unlock: proc "c" (ud: rawptr, rp_user: [^]u8, rp_user_len: uint, options: [^]C_Unlock_Option, count: uint, mode: i32, call: ^Plug_Call),
	enroll: proc "c" (ud: rawptr, rp_user: [^]u8, rp_user_len: uint, label: [^]u8, label_len: uint, salt: ^[32]u8, call: ^Plug_Call),
	cancel: proc "c" (ud: rawptr, call: ^Plug_Call),
}

C_Sealed_Store :: struct {
	size:   u32,
	ud:     rawptr,
	get:    proc "c" (ud: rawptr, subject: [^]u8, subject_len: uint, call: ^Plug_Call),
	put:    proc "c" (ud: rawptr, subject: [^]u8, subject_len: uint, record: [^]u8, record_len: uint, prev_seq: u64, call: ^Plug_Call),
	add:    proc "c" (ud: rawptr, subject: [^]u8, subject_len: uint, entry: [^]u8, entry_len: uint, call: ^Plug_Call),
	cancel: proc "c" (ud: rawptr, call: ^Plug_Call),
}

C_Runner_Pool :: struct {
	size:     u32,
	ud:       rawptr,
	identity: proc "c" (ud: rawptr, out: ^C_Identity) -> i32,
	verify:   proc "c" (ud: rawptr, token: [^]u8, token_len: uint, runner: ^C_Identity, call: ^Plug_Call),
	attest:   proc "c" (ud: rawptr, evidence: [^]u8, evidence_len: uint, runner: ^C_Identity, call: ^Plug_Call),
	joined:   proc "c" (ud: rawptr, space: ^[16]u8, name: [^]u8, name_len: uint, relay: [^]u8, relay_len: uint, relay_key: ^[32]u8, proof: [^]u8, proof_len: uint),
	cancel:   proc "c" (ud: rawptr, call: ^Plug_Call),
}

Plug_Kind :: enum u8 {
	Store,
	Unlock,
	Pool,
	Credentials,
}

Plug_State :: enum u8 {
	Inline,
	Done_Inline,
	Pending,
	Done_Posted,
	Cancelled,
	Cancelled_Done,
	Closed,
}

Plug_Call :: struct {
	h:          ^Handle,
	kind:       Plug_Kind,
	done:       osync.Plug_Done,
	state:      Plug_State,
	status:     i32,
	record:     []u8,
	entries:    []u8,
	credential: []u8,
	prf:        [32]u8,
	ecosystem:  i32,
	lease_ms:   u64,
}

Account_Plugs :: struct {
	h:      ^Handle,
	unlock: C_Unlock,
	store:  C_Sealed_Store,
	pool:   C_Runner_Pool,
	calls:  [dynamic]^Plug_Call,
}

@(private)
_plug_mu: sync.Mutex

@(private)
_c_status_err :: proc "contextless" (st: i32) -> osync.Error {
	if st < 0 || st > i32(max(api.Status)) {
		return .Io
	}
	#partial switch api.Status(st) {
	case .Ok:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Invalid, .Bad_Request:
		return .Invalid
	case .Permission:
		return .Permission
	case .Unsupported:
		return .Unsupported
	case .Conflict:
		return .Conflict
	case .Too_Large:
		return .Too_Large
	case .Busy:
		return .Busy
	case .Timeout:
		return .Timeout
	case .Offline, .Cancelled, .Closed:
		return .Closed
	}
	return .Io
}

@(private)
_heap_copy :: proc(p: [^]u8, n: uint) -> []u8 {
	if p == nil || n == 0 {
		return nil
	}
	out := make([]u8, int(n), runtime.heap_allocator())
	copy(out, p[:n])
	return out
}

@(private)
_pc_free :: proc(pc: ^Plug_Call) {
	a := runtime.heap_allocator()
	delete(pc.record, a)
	delete(pc.entries, a)
	delete(pc.credential, a)
	free(pc, a)
}

@(private)
_pc_new :: proc(p: ^Account_Plugs, kind: Plug_Kind, done: osync.Plug_Done) -> ^Plug_Call {
	pc := new(Plug_Call, runtime.heap_allocator())
	pc.h = p.h
	pc.kind = kind
	pc.done = done
	pc.state = .Inline
	return pc
}

@(private)
_pc_reply :: proc(pc: ^Plug_Call, reply: ^osync.Plug_Reply) -> osync.Error {
	err := _c_status_err(pc.status)
	if err != .None {
		return err
	}
	reply.record = make([]u8, len(pc.record), context.temp_allocator)
	copy(reply.record, pc.record)
	list := make([dynamic][]u8, context.temp_allocator)
	pos := 0
	for pos + 4 <= len(pc.entries) {
		n := int(prim.get_u32le(pc.entries[pos:]))
		if pos + 4 + n > len(pc.entries) {
			return .Corrupt
		}
		e := make([]u8, n, context.temp_allocator)
		copy(e, pc.entries[pos + 4:][:n])
		append(&list, e)
		pos += 4 + n
	}
	reply.entries = list[:]
	reply.credential = make([]u8, len(pc.credential), context.temp_allocator)
	copy(reply.credential, pc.credential)
	reply.prf = pc.prf
	if pc.ecosystem < 0 || pc.ecosystem > i32(max(osync.Ecosystem)) {
		return .Invalid
	}
	reply.ecosystem = osync.Ecosystem(pc.ecosystem)
	reply.lease_ms = pc.lease_ms
	return .None
}

@(private)
_pc_settle :: proc(p: ^Account_Plugs, pc: ^Plug_Call, reply: ^osync.Plug_Reply) -> osync.Error {
	sync.mutex_lock(&_plug_mu)
	if pc.state == .Done_Inline {
		sync.mutex_unlock(&_plug_mu)
		err := _pc_reply(pc, reply)
		_pc_free(pc)
		return err
	}
	pc.state = .Pending
	append(&p.calls, pc)
	sync.mutex_unlock(&_plug_mu)
	return .Pending
}

@(export, link_name = "ondb_plug_done")
ondb_plug_done :: proc "c" (pc: ^Plug_Call, status: i32, reply: ^C_Plug_Reply) -> i32 {
	if pc == nil {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	sync.mutex_lock(&_plug_mu)
	switch pc.state {
	case .Inline, .Pending:
		pc.status = status
		if status == 0 && reply != nil {
			sz := uintptr(reply.size)
			if sz >= offset_of(C_Plug_Reply, entries) {
				pc.record = _heap_copy(reply.record, reply.record_len)
			}
			if sz >= offset_of(C_Plug_Reply, credential) {
				pc.entries = _heap_copy(reply.entries, reply.entries_len)
			}
			if sz >= offset_of(C_Plug_Reply, prf) {
				pc.credential = _heap_copy(reply.credential, reply.credential_len)
			}
			if sz >= offset_of(C_Plug_Reply, ecosystem) {
				pc.prf = reply.prf
			}
			if sz >= offset_of(C_Plug_Reply, lease_ms) {
				pc.ecosystem = reply.ecosystem
			}
			if sz >= size_of(C_Plug_Reply) {
				pc.lease_ms = reply.lease_ms
			}
		}
		if pc.state == .Inline {
			pc.state = .Done_Inline
			sync.mutex_unlock(&_plug_mu)
			return 0
		}
		pc.state = .Done_Posted
		h := pc.h
		sync.mutex_unlock(&_plug_mu)
		if eng.post(&h.s.e, _pc_post, pc) != .None {
			sync.mutex_lock(&_plug_mu)
			pc.state = .Closed
			sync.mutex_unlock(&_plug_mu)
		}
		return 0
	case .Cancelled, .Closed:
		sync.mutex_unlock(&_plug_mu)
		_pc_free(pc)
		return 0
	case .Done_Inline, .Done_Posted, .Cancelled_Done:
	}
	sync.mutex_unlock(&_plug_mu)
	return i32(api.Status.Invalid)
}

@(private)
_pc_post :: proc(e: ^eng.Engine, data: rawptr) {
	pc := (^Plug_Call)(data)
	sync.mutex_lock(&_plug_mu)
	if pc.state != .Done_Posted {
		sync.mutex_unlock(&_plug_mu)
		_pc_free(pc)
		return
	}
	p := &pc.h.plugs.account
	for x, i in p.calls {
		if x == pc {
			unordered_remove(&p.calls, i)
			break
		}
	}
	sync.mutex_unlock(&_plug_mu)
	reply: osync.Plug_Reply
	err := _pc_reply(pc, &reply)
	done := pc.done
	_pc_free(pc)
	done.call(done.data, err, &reply)
}

@(private)
_pc_cancel :: proc(p: ^Account_Plugs, done: osync.Plug_Done) {
	sync.mutex_lock(&_plug_mu)
	target: ^Plug_Call
	for x, i in p.calls {
		if x.done.data == done.data {
			target = x
			unordered_remove(&p.calls, i)
			break
		}
	}
	if target == nil {
		sync.mutex_unlock(&_plug_mu)
		return
	}
	was := target.state
	target.state = .Cancelled if was == .Pending else .Cancelled_Done
	sync.mutex_unlock(&_plug_mu)
	if was != .Pending {
		return
	}
	switch target.kind {
	case .Store:
		if p.store.cancel != nil {
			p.store.cancel(p.store.ud, target)
		}
	case .Unlock:
		if p.unlock.cancel != nil {
			p.unlock.cancel(p.unlock.ud, target)
		}
	case .Pool:
		if p.pool.cancel != nil {
			p.pool.cancel(p.pool.ud, target)
		}
	case .Credentials:
		c := &p.h.plugs.credentials
		if c.cancel != nil {
			c.cancel(c.ud, target)
		}
	}
}

account_plugs_close :: proc(p: ^Account_Plugs) {
	sync.mutex_lock(&_plug_mu)
	for pc in p.calls {
		pc.state = .Closed if pc.state == .Pending else .Cancelled_Done
	}
	clear(&p.calls)
	sync.mutex_unlock(&_plug_mu)
	delete(p.calls)
}

account_plugs_setup :: proc(p: ^Account_Plugs, cfg: ^Config, ec: ^eng.Config) -> bool {
	p.calls = make([dynamic]^Plug_Call, runtime.heap_allocator())
	if _has(cfg, offset_of(Config, unlock)) && cfg.unlock != nil {
		if !_copy_table(&p.unlock, cfg.unlock) || p.unlock.unlock == nil {
			return false
		}
		ec.unlock = osync.Unlock{data = p, unlock = _c_unlock, register = _c_enroll if p.unlock.enroll != nil else nil, cancel = _c_plug_cancel}
	}
	if _has(cfg, offset_of(Config, sealed_store)) && cfg.sealed_store != nil {
		if !_copy_table(&p.store, cfg.sealed_store) || p.store.get == nil || p.store.put == nil || p.store.add == nil {
			return false
		}
		ec.sealed_store = osync.Sealed_Store{data = p, get = _c_store_get, put = _c_store_put, add = _c_store_add, cancel = _c_plug_cancel}
	}
	if _has(cfg, offset_of(Config, runner_pool)) && cfg.runner_pool != nil {
		if !_copy_table(&p.pool, cfg.runner_pool) {
			return false
		}
		ec.runner_pool = eng.Runner_Pool {
			data     = p,
			identity = _c_pool_identity if p.pool.identity != nil else nil,
			verify   = _c_pool_verify if p.pool.verify != nil else nil,
			attest   = _c_pool_attest if p.pool.attest != nil else nil,
			joined   = _c_pool_joined if p.pool.joined != nil else nil,
			cancel   = _c_plug_cancel,
		}
	}
	if _has(cfg, offset_of(Config, approver)) {
		ec.approver = cfg.approver != 0
	}
	return true
}

@(private)
_c_plug_cancel :: proc(data: rawptr, done: osync.Plug_Done) {
	_pc_cancel((^Account_Plugs)(data), done)
}

@(private)
_c_unlock :: proc(data: rawptr, rp_user: []u8, options: []osync.Unlock_Option, mode: osync.Unlock_Mode, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	opts := make([]C_Unlock_Option, len(options), context.temp_allocator)
	for o, i in options {
		opts[i] = C_Unlock_Option{credential = raw_data(o.credential), credential_len = uint(len(o.credential)), salt = o.salt}
	}
	pc := _pc_new(p, .Unlock, done)
	p.unlock.unlock(p.unlock.ud, raw_data(rp_user), uint(len(rp_user)), raw_data(opts), uint(len(opts)), i32(mode), pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_enroll :: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	s := salt
	pc := _pc_new(p, .Unlock, done)
	p.unlock.enroll(p.unlock.ud, raw_data(rp_user), uint(len(rp_user)), raw_data(label), uint(len(label)), &s, pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_store_get :: proc(data: rawptr, subject: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	pc := _pc_new(p, .Store, done)
	p.store.get(p.store.ud, raw_data(subject), uint(len(subject)), pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_store_put :: proc(data: rawptr, subject: []u8, record: []u8, prev_seq: u64, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	pc := _pc_new(p, .Store, done)
	p.store.put(p.store.ud, raw_data(subject), uint(len(subject)), raw_data(record), uint(len(record)), prev_seq, pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_store_add :: proc(data: rawptr, subject: []u8, entry: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	pc := _pc_new(p, .Store, done)
	p.store.add(p.store.ud, raw_data(subject), uint(len(subject)), raw_data(entry), uint(len(entry)), pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_pool_identity :: proc(data: rawptr) -> osync.Identity {
	p := (^Account_Plugs)(data)
	c: C_Identity
	if p.pool.identity(p.pool.ud, &c) != 0 {
		return {}
	}
	return osync.identity_of(c.sign, c.box)
}

@(private)
_c_pool_verify :: proc(data: rawptr, token: []u8, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	c := _id_to_c(runner)
	pc := _pc_new(p, .Pool, done)
	p.pool.verify(p.pool.ud, raw_data(token), uint(len(token)), &c, pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_pool_attest :: proc(data: rawptr, evidence: []u8, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Account_Plugs)(data)
	c := _id_to_c(runner)
	pc := _pc_new(p, .Pool, done)
	p.pool.attest(p.pool.ud, raw_data(evidence), uint(len(evidence)), &c, pc)
	return _pc_settle(p, pc, reply)
}

@(private)
_c_pool_joined :: proc(data: rawptr, space: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, proof: []u8) {
	p := (^Account_Plugs)(data)
	s := ([16]u8)(space)
	rk := relay_public
	p.pool.joined(p.pool.ud, &s, raw_data(name), uint(len(name)), raw_data(relay), uint(len(relay)), &rk, raw_data(proof), uint(len(proof)))
}

credentials_begin :: proc(p: ^Account_Plugs, space: [16]u8, binding: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	c := &p.h.plugs.credentials
	sp := space
	pc := _pc_new(p, .Credentials, done)
	c.produce(c.ud, &sp, raw_data(binding), uint(len(binding)), pc)
	err := _pc_settle(p, pc, reply)
	if err == .None && (len(reply.credential) == 0 || len(reply.credential) > osync.CREDENTIAL_MAX) {
		return .Auth
	}
	return err
}

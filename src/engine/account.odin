package engine

import "core:crypto"
import "../prim"
import osync "../sync"

@(private)
ACCOUNT_FILE :: "account"
@(private)
ACCOUNT_FILE_VERSION :: 1

Account_State :: struct {
	sign:         osync.Public_Key,
	box:          osync.Public_Key,
	pool:         osync.Pool_Access,
	pool_sign:    osync.Public_Key,
	pool_box:     osync.Public_Key,
	relay:        string,
	relay_public: osync.Public_Key,
	subject:      string,
	cert:         [64]u8,
	have:         bool,
}

Login_Path :: enum u8 {
	Created,
	Passkey,
	Approval,
	Cross_Device,
	Recovery,
}

Login_Status :: enum u8 {
	Done,
	Waiting,
	No_Approver,
}

Login_Result :: struct {
	path:   Login_Path,
	status: Login_Status,
	code:   [osync.APPROVE_CODE_LEN]u8,
	spaces: int,
}

Approval_Info :: struct {
	device: prim.Id,
	code:   [osync.APPROVE_CODE_LEN]u8,
	label:  string,
	at:     i64,
}

Wrapper_Info :: struct {
	credential: []u8,
	label:      string,
	ecosystem:  osync.Ecosystem,
	added_by:   prim.Id,
	added_at:   u64,
}

@(private)
Approval_Pending :: struct {
	from:  prim.Id,
	req:   osync.Approval_Request,
	label: string,
	code:  [osync.APPROVE_CODE_LEN]u8,
	at:    i64,
}

@(private)
Inbound :: struct {
	from: prim.Id,
	data: []u8,
	kind: osync.Repl_Event_Kind,
	up:   bool,
}

@(private)
Rv_Creds :: struct {
	requester: bool,
	account:   osync.Public_Key,
	cert:      [64]u8,
	keyring:   osync.Keyring,
}

Approvals :: struct {
	rv:        ^Space,
	creds:     Rv_Creds,
	requester: bool,
	waiting:   bool,
	failed:    bool,
	nonce:     [16]u8,
	code:      [osync.APPROVE_CODE_LEN]u8,
	label:     string,
	sent:      [dynamic]prim.Id,
	present:   [dynamic]prim.Id,
	inbox:     [dynamic]Inbound,
	pending:   [dynamic]Approval_Pending,
	enrolling: int,
	path:      Login_Path,
	lease_timer: prim.Timer,
}

@(private)
_account_path :: proc(e: ^Engine) -> (string, Error) {
	return _join(context.temp_allocator, e.pack_root, ACCOUNT_FILE)
}

@(private)
_account_load :: proc(e: ^Engine) {
	e.approvals.sent = make([dynamic]prim.Id, e.allocator)
	e.approvals.present = make([dynamic]prim.Id, e.allocator)
	e.approvals.inbox = make([dynamic]Inbound, e.allocator)
	e.approvals.pending = make([dynamic]Approval_Pending, e.allocator)
	path, perr := _account_path(e)
	if perr != .None {
		return
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None {
		return
	}
	r := prim.reader(data)
	if prim.read_u8(&r) != ACCOUNT_FILE_VERSION {
		return
	}
	a: Account_State
	prim.read_fixed(&r, a.sign[:])
	prim.read_fixed(&r, a.box[:])
	p := prim.read_u8(&r)
	prim.read_fixed(&r, a.pool_sign[:])
	prim.read_fixed(&r, a.pool_box[:])
	relay := prim.read_str(&r)
	prim.read_fixed(&r, a.relay_public[:])
	subject := prim.read_str(&r)
	prim.read_fixed(&r, a.cert[:])
	if !prim.reader_ok(&r) || p > u8(max(osync.Pool_Access)) {
		return
	}
	a.pool = osync.Pool_Access(p)
	a.relay, _ = _clone(relay, e.allocator)
	a.subject, _ = _clone(subject, e.allocator)
	a.have = true
	e.account = a
}

@(private)
_account_store :: proc(e: ^Engine) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	a := &e.account
	prim.write_u8(&w, ACCOUNT_FILE_VERSION)
	prim.write_raw(&w, a.sign[:])
	prim.write_raw(&w, a.box[:])
	prim.write_u8(&w, u8(a.pool))
	prim.write_raw(&w, a.pool_sign[:])
	prim.write_raw(&w, a.pool_box[:])
	prim.write_str(&w, a.relay)
	prim.write_raw(&w, a.relay_public[:])
	prim.write_str(&w, a.subject)
	prim.write_raw(&w, a.cert[:])
	if w.err != .None {
		return .No_Memory
	}
	path := _account_path(e) or_return
	return _perr(prim.replace_atomic(e.vfs, path, buf[:]))
}

@(private)
_account_close :: proc(e: ^Engine) {
	_rv_close(e)
	if e.approvals.lease_timer != 0 && e.loop != nil {
		prim.timer_cancel(e.loop, e.approvals.lease_timer)
	}
	for &p in e.approvals.pending {
		delete(p.label, e.allocator)
	}
	for x in e.approvals.inbox {
		delete(x.data, e.allocator)
	}
	delete(e.approvals.sent)
	delete(e.approvals.present)
	delete(e.approvals.inbox)
	delete(e.approvals.pending)
	delete(e.approvals.label, e.allocator)
	delete(e.account.relay, e.allocator)
	delete(e.account.subject, e.allocator)
	e.approvals = {}
	e.account = {}
}

account_state :: proc "contextless" (e: ^Engine) -> Account_State {
	return e.account
}

@(private)
_store_get :: proc(e: ^Engine, subject: string, rec: ^osync.Account_Record, entries: ^[dynamic][]u8) -> Error {
	if e.cfg.sealed_store.get == nil {
		return .Unsupported
	}
	raw := make([dynamic]u8, context.temp_allocator)
	err: osync.Error
	{
		context = _outer(e)
		err = e.cfg.sealed_store.get(e.cfg.sealed_store.data, transmute([]u8)subject, &raw, entries)
	}
	if err == .Not_Found {
		return .Not_Found
	}
	_serr(err) or_return
	return _serr(osync.account_record_decode(raw[:], rec, context.temp_allocator))
}

@(private)
_store_put :: proc(e: ^Engine, subject: string, rec: ^osync.Account_Record, a: ^osync.Account_Key, prev: u64) -> Error {
	out := make([dynamic]u8, context.temp_allocator)
	_serr(osync.account_record_encode(rec, a, &out)) or_return
	context = _outer(e)
	return _serr(e.cfg.sealed_store.put(e.cfg.sealed_store.data, transmute([]u8)subject, out[:], prev))
}

@(private)
_unlock_local :: proc(e: ^Engine, rec: ^osync.Account_Record, mode: osync.Unlock_Mode, a: ^osync.Account_Key) -> Error {
	if e.cfg.unlock.unlock == nil {
		return .Unsupported
	}
	opts := osync.account_unlock_options(rec)
	if len(opts) == 0 {
		return .Not_Found
	}
	cred := make([dynamic]u8, context.temp_allocator)
	prf: [32]u8
	defer crypto.zero_explicit(&prf, size_of(prf))
	err: osync.Error
	{
		context = _outer(e)
		err = e.cfg.unlock.unlock(e.cfg.unlock.data, rec.sign[:], opts, mode, &cred, &prf)
	}
	_serr(err) or_return
	return _serr(osync.account_open_with(rec, cred[:], prf[:], a, e.cfg.random))
}

@(private)
_register_wrapper :: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, label: string) -> Error {
	if e.cfg.unlock.register == nil {
		return .Unsupported
	}
	salt: [32]u8
	prim.random_fill(e.cfg.random, salt[:])
	cred := make([dynamic]u8, context.temp_allocator)
	prf: [32]u8
	defer crypto.zero_explicit(&prf, size_of(prf))
	eco: osync.Ecosystem
	err: osync.Error
	{
		context = _outer(e)
		err = e.cfg.unlock.register(e.cfg.unlock.data, rec.sign[:], label, salt, &cred, &prf, &eco)
	}
	_serr(err) or_return
	return _serr(osync.account_add_wrapper(rec, a, cred[:], label, eco, salt, prf[:], e.identity.sign, _now_ms(e), context.temp_allocator))
}

account_login :: proc(e: ^Engine, subject: string, label: string, relay := "", relay_public: osync.Public_Key = {}) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	rec: osync.Account_Record
	entries := make([dynamic][]u8, context.temp_allocator)
	gerr := _store_get(e, subject, &rec, &entries)
	if gerr == .Not_Found {
		return _account_create(e, subject, label, relay, relay_public)
	}
	gerr or_return
	a: osync.Account_Key
	defer osync.account_key_clear(&a)
	if _unlock_local(e, &rec, .Local, &a) == .None {
		res.path = .Passkey
		res.spaces = _account_adopt(e, subject, &rec, entries[:], &a, .Passkey) or_return
		res.status = .Done
		return res, .None
	}
	_approval_request(e, subject, &rec, label) or_return
	res.path = .Approval
	res.status = .Waiting
	res.code = e.approvals.code
	return res, .None
}

account_login_cross_device :: proc(e: ^Engine, subject: string) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	rec: osync.Account_Record
	entries := make([dynamic][]u8, context.temp_allocator)
	_store_get(e, subject, &rec, &entries) or_return
	a: osync.Account_Key
	defer osync.account_key_clear(&a)
	_unlock_local(e, &rec, .Cross_Device, &a) or_return
	_rv_close(e)
	e.approvals.waiting = false
	res.path = .Cross_Device
	res.spaces = _account_adopt(e, subject, &rec, entries[:], &a, .Cross_Device) or_return
	res.status = .Done
	return res, .None
}

account_login_recovery :: proc(e: ^Engine, subject: string, recovery: string) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	secret, derr := osync.recovery_decode(recovery)
	if derr != .None {
		return res, .Invalid
	}
	defer crypto.zero_explicit(&secret, size_of(secret))
	rec: osync.Account_Record
	entries := make([dynamic][]u8, context.temp_allocator)
	_store_get(e, subject, &rec, &entries) or_return
	a: osync.Account_Key
	defer osync.account_key_clear(&a)
	_serr(osync.account_open_recovery(&rec, secret, &a, e.cfg.random)) or_return
	res.path = .Recovery
	res.spaces = _account_adopt(e, subject, &rec, entries[:], &a, .Recovery) or_return
	res.status = .Done
	return res, .None
}

@(private)
_account_create :: proc(e: ^Engine, subject: string, label: string, relay: string, relay_public: osync.Public_Key) -> (res: Login_Result, err: Error) {
	if e.cfg.sealed_store.put == nil {
		return res, .Unsupported
	}
	a: osync.Account_Key
	defer osync.account_key_clear(&a)
	_serr(osync.account_key_new(&a, e.cfg.random)) or_return
	rec: osync.Account_Record
	osync.account_record_new(&rec, &a, relay, relay_public, context.temp_allocator)
	if e.cfg.runner_pool.identity != nil {
		id: osync.Identity
		{
			context = _outer(e)
			id = e.cfg.runner_pool.identity(e.cfg.runner_pool.data)
		}
		rec.pool = .Everything
		rec.pool_sign = id.sign
		rec.pool_box = id.box
	}
	_register_wrapper(e, &rec, &a, label) or_return
	_store_put(e, subject, &rec, &a, 0) or_return
	res.path = .Created
	res.spaces = _account_adopt(e, subject, &rec, nil, &a, .Created) or_return
	res.status = .Done
	return res, .None
}

@(private)
_account_adopt :: proc(e: ^Engine, subject: string, rec: ^osync.Account_Record, entries: [][]u8, a: ^osync.Account_Key, path: Login_Path) -> (spaces: int, err: Error) {
	delete(e.account.relay, e.allocator)
	delete(e.account.subject, e.allocator)
	e.account = Account_State {
		sign         = rec.sign,
		box          = rec.box,
		pool         = rec.pool,
		pool_sign    = rec.pool_sign,
		pool_box     = rec.pool_box,
		relay_public = rec.relay_public,
		cert         = osync.device_cert(a, e.identity.sign),
		have         = true,
	}
	e.account.relay = _clone(rec.relay, e.allocator) or_return
	e.account.subject = _clone(subject, e.allocator) or_return
	_account_store(e) or_return
	akr := osync.account_keyring(a)
	signer := osync.account_signer(a)
	e.approvals.path = path
	for raw in entries {
		me: osync.Manifest_Entry
		if osync.manifest_entry_decode(raw, rec.sign, &akr, &me, context.temp_allocator) != .None {
			continue
		}
		if sp, ok := e.spaces[prim.Id(me.space)]; ok && !sp.keyless {
			continue
		}
		b := osync.Add_Body{sign = e.identity.sign, box = e.identity.box, kind = .Device, role = .Admin, method = .Account, person = rec.sign, history = true}
		payload := make([dynamic]u8, context.temp_allocator)
		if osync.add_encode(b, &payload) != .None {
			continue
		}
		parents := []osync.Record_Id{me.anchor}
		proof, _, perr := osync.member_encode(.Add, me.space, signer, me.anchor_lamport + 1, parents, _now_ms(e), payload[:], context.temp_allocator)
		if perr != .None {
			continue
		}
		space_join_enrollment(e, prim.Id(me.space), proof, me.name, me.relay, me.relay_public) or_continue
		sp := e.spaces[prim.Id(me.space)]
		if sp.mem.enroll == nil {
			k := new(osync.Account_Key, e.allocator)
			osync.account_key_from_seed(k, a.seed, e.cfg.random)
			sp.mem.enroll = k
		}
		e.approvals.enrolling += 1
		spaces += 1
		space_open(e, sp.id)
	}
	if path == .Approval || path == .Cross_Device || path == .Recovery {
		prev := rec.seq
		rec.seq += 1
		if _register_wrapper(e, rec, a, "") == .None {
			if _store_put(e, subject, rec, a, prev) != .None {
				_log(e, .Warn, "passkey wrapper store failed")
			}
		}
	}
	_account_adopt_local(e)
	if spaces == 0 {
		_emit(e, Event{kind = .Login_Done, length = i64(path)})
	}
	if e.cfg.approver && e.approvals.rv == nil {
		_rv_open(e, e.account.sign, e.account.relay, e.account.relay_public, false)
	}
	_touch(e)
	return spaces, .None
}

@(private)
_account_enrolled :: proc(e: ^Engine, sp: ^Space) {
	if e.approvals.enrolling > 0 {
		e.approvals.enrolling -= 1
		if e.approvals.enrolling == 0 {
			_emit(e, Event{kind = .Login_Done, space = sp.id, length = i64(e.approvals.path)})
		}
	}
}

@(private)
_account_manifest_add :: proc(e: ^Engine, sp: ^Space) {
	if !e.account.have || e.cfg.sealed_store.add == nil {
		return
	}
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return
	}
	idx := osync.roster_find(&m.roster, e.account.sign)
	if idx < 0 {
		return
	}
	anchor := m.roster.members[idx].added
	ri, ok := m.ids[anchor]
	if !ok {
		return
	}
	me := osync.Manifest_Entry {
		space          = osync.Space_Id(sp.id),
		name           = sp.name,
		relay          = sp.relay,
		relay_public   = sp.relay_public,
		anchor         = anchor,
		anchor_lamport = m.records[ri].lamport,
	}
	out := make([dynamic]u8, context.temp_allocator)
	acc := osync.identity_of(e.account.sign, e.account.box)
	if osync.manifest_entry_encode(acc, &e.keyring, e.account.cert, me, &out, e.cfg.random) != .None {
		return
	}
	context = _outer(e)
	e.cfg.sealed_store.add(e.cfg.sealed_store.data, transmute([]u8)e.account.subject, out[:])
}

account_join_space :: proc(e: ^Engine, space: prim.Id) -> Error {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	if !e.account.have {
		return .Permission
	}
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	resolved := osync.membership_resolve(&m) == .None
	already := resolved && osync.roster_find(&m.roster, e.account.sign) >= 0
	osync.membership_destroy(&m)
	if !already {
		b := osync.Add_Body{sign = e.account.sign, box = e.account.box, kind = .Account, role = .Owner, method = .Account, person = e.account.sign, history = true}
		ac := Add_Ctx{body = b}
		build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
			c := (^Add_Ctx)(data)
			raw, err := osync.membership_add(m, osync.keyring_member_signer(&e.keyring), c.body, _now_ms(e))
			return raw, _serr(err)
		}
		_members_change(e, sp, build, &ac, true) or_return
		_account_manifest_add(e, sp)
	}
	return .None
}

account_wrappers :: proc(e: ^Engine, allocator := context.allocator) -> (out: []Wrapper_Info, err: Error) {
	context = context_for(e)
	if !e.account.have {
		return nil, .Permission
	}
	rec: osync.Account_Record
	entries := make([dynamic][]u8, context.temp_allocator)
	_store_get(e, e.account.subject, &rec, &entries) or_return
	list := make([dynamic]Wrapper_Info, 0, len(rec.wrappers), allocator)
	for &w in rec.wrappers {
		c := make([]u8, len(w.credential), allocator)
		copy(c, w.credential)
		l, _ := _clone(w.label, allocator)
		append(&list, Wrapper_Info{credential = c, label = l, ecosystem = w.ecosystem, added_by = osync.device_id(w.added_by), added_at = w.added_at})
	}
	return list[:], .None
}

@(private)
_with_account :: proc(e: ^Engine, fn: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, data: rawptr) -> Error, data: rawptr) -> Error {
	if !e.account.have {
		return .Permission
	}
	rec: osync.Account_Record
	entries := make([dynamic][]u8, context.temp_allocator)
	_store_get(e, e.account.subject, &rec, &entries) or_return
	a: osync.Account_Key
	defer osync.account_key_clear(&a)
	_unlock_local(e, &rec, .Local, &a) or_return
	prev := rec.seq
	fn(e, &rec, &a, data) or_return
	rec.seq = prev + 1
	return _store_put(e, e.account.subject, &rec, &a, prev)
}

account_wrapper_remove :: proc(e: ^Engine, credential: []u8) -> Error {
	context = context_for(e)
	fn :: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, data: rawptr) -> Error {
		c := (^[]u8)(data)
		left := 0
		for &w in rec.wrappers {
			if w.ecosystem != .Recovery && string(w.credential) != string(c^) {
				left += 1
			}
		}
		if left == 0 {
			return .Permission
		}
		return .None if osync.account_remove_wrapper(rec, c^) else .Not_Found
	}
	c := credential
	return _with_account(e, fn, &c)
}

account_recovery_key :: proc(e: ^Engine, allocator := context.allocator) -> (text: string, err: Error) {
	context = context_for(e)
	secret := osync.recovery_secret_new(e.cfg.random)
	defer crypto.zero_explicit(&secret, size_of(secret))
	fn :: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, data: rawptr) -> Error {
		s := (^[osync.RECOVERY_SECRET_LEN]u8)(data)
		return _serr(osync.account_add_recovery(rec, a, s^, e.identity.sign, _now_ms(e), e.cfg.random, context.temp_allocator))
	}
	_with_account(e, fn, &secret) or_return
	return osync.recovery_encode(secret, allocator), .None
}

account_pool_set :: proc(e: ^Engine, access: osync.Pool_Access) -> Error {
	context = context_for(e)
	fn :: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, data: rawptr) -> Error {
		rec.pool = (^osync.Pool_Access)(data)^
		if e.cfg.runner_pool.identity != nil {
			id: osync.Identity
			{
				context = _outer(e)
				id = e.cfg.runner_pool.identity(e.cfg.runner_pool.data)
			}
			rec.pool_sign = id.sign
			rec.pool_box = id.box
		}
		e.account.pool_sign = rec.pool_sign
		e.account.pool_box = rec.pool_box
		return .None
	}
	acc := access
	_with_account(e, fn, &acc) or_return
	e.account.pool = access
	_account_store(e)
	for id in _sorted_keys(e.spaces) {
		if !e.spaces[id].keyless {
			space_pool_set(e, id, access != .Off)
		}
	}
	return .None
}

space_pool_set :: proc(e: ^Engine, space: prim.Id, on: bool) -> Error {
	context = context_for(e)
	zero: osync.Public_Key
	if e.account.pool_sign == zero && on {
		account_pool_set(e, .Everything) or_return
	}
	if e.account.pool_sign == zero {
		return .Not_Found
	}
	sp := _space_open(e, space) or_return
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	resolved := osync.membership_resolve(&m) == .None
	idx := osync.roster_find(&m.roster, e.account.pool_sign) if resolved else -1
	active := idx >= 0 && osync.member_active(&m.roster.members[idx], _now_ms(e))
	osync.membership_destroy(&m)
	if on == active {
		return .None
	}
	if !on {
		return member_remove(e, space, osync.device_id(e.account.pool_sign))
	}
	ac := Add_Ctx{body = osync.Add_Body{sign = e.account.pool_sign, box = e.account.pool_box, kind = .Pool, role = .Member, method = .Pool, person = e.account.sign, history = true}}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> (out: []u8, berr: Error) {
		c := (^Add_Ctx)(data)
		raw, err := osync.membership_add(m, osync.keyring_member_signer(&e.keyring), c.body, _now_ms(e))
		return raw, _serr(err)
	}
	_members_change(e, sp, build, &ac, true) or_return
	_pool_notify(e, sp)
	return .None
}

Device_Info :: struct {
	device:  prim.Id,
	spaces:  int,
	method:  osync.Enroll_Method,
	kind:    osync.Member_Kind,
	removed: bool,
	self:    bool,
}

account_devices :: proc(e: ^Engine, allocator := context.allocator) -> (out: []Device_Info, err: Error) {
	context = context_for(e)
	list := make([dynamic]Device_Info, allocator)
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if sp.keyless {
			continue
		}
		ms, merr := space_members(e, id, context.temp_allocator)
		if merr != .None {
			continue
		}
		for x in ms {
			if x.kind != .Device && x.kind != .Runner && x.kind != .Pool {
				continue
			}
			if e.account.have && x.kind == .Device && x.person != e.account.sign {
				continue
			}
			found := false
			for &d in list {
				if d.device == x.device {
					d.spaces += 1
					d.removed = d.removed && x.removed
					found = true
				}
			}
			if !found {
				append(&list, Device_Info{device = x.device, spaces = 1, method = x.method, kind = x.kind, removed = x.removed, self = x.self})
			}
		}
	}
	return list[:], .None
}

device_remove :: proc(e: ^Engine, device: prim.Id) -> (removed: int, err: Error) {
	context = context_for(e)
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if sp.keyless {
			continue
		}
		if member_remove(e, id, device) == .None {
			removed += 1
		}
	}
	if removed == 0 {
		return 0, .Not_Found
	}
	return removed, .None
}

account_passkey_add :: proc(e: ^Engine, label: string) -> Error {
	context = context_for(e)
	fn :: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, data: rawptr) -> Error {
		return _register_wrapper(e, rec, a, (^string)(data)^)
	}
	l := label
	return _with_account(e, fn, &l)
}

account_login_prf :: proc(e: ^Engine, subject: string, credential: []u8, prf: [32]u8, label: string, relay := "", relay_public: osync.Public_Key = {}) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	p := prf
	defer crypto.zero_explicit(&p, size_of(p))
	rec: osync.Account_Record
	entries := make([dynamic][]u8, context.temp_allocator)
	gerr := _store_get(e, subject, &rec, &entries)
	if gerr == .Not_Found {
		a: osync.Account_Key
		defer osync.account_key_clear(&a)
		_serr(osync.account_key_new(&a, e.cfg.random)) or_return
		osync.account_record_new(&rec, &a, relay, relay_public, context.temp_allocator)
		if e.cfg.runner_pool.identity != nil {
			id: osync.Identity
			{
				context = _outer(e)
				id = e.cfg.runner_pool.identity(e.cfg.runner_pool.data)
			}
			rec.pool = .Everything
			rec.pool_sign = id.sign
			rec.pool_box = id.box
		}
		salt := osync.idp_salt(transmute([]u8)subject)
		_serr(osync.account_add_wrapper(&rec, &a, credential, label, .Unknown, salt, p[:], e.identity.sign, _now_ms(e), context.temp_allocator)) or_return
		_store_put(e, subject, &rec, &a, 0) or_return
		res.path = .Created
		res.spaces = _account_adopt(e, subject, &rec, nil, &a, .Created) or_return
		return res, .None
	}
	gerr or_return
	a: osync.Account_Key
	defer osync.account_key_clear(&a)
	if oerr := osync.account_open_with(&rec, credential, p[:], &a, e.cfg.random); oerr != .None {
		_approval_request(e, subject, &rec, label) or_return
		res.path = .Approval
		res.status = .Waiting
		res.code = e.approvals.code
		return res, .None
	}
	res.path = .Passkey
	res.spaces = _account_adopt(e, subject, &rec, entries[:], &a, .Passkey) or_return
	return res, .None
}

account_idp_salt :: proc(subject: string) -> [32]u8 {
	return osync.idp_salt(transmute([]u8)subject)
}

Idp_Wrapper :: struct {
	credential: []u8,
	prf:        [32]u8,
	label:      string,
}

account_passkey_add_prf :: proc(e: ^Engine, credential: []u8, prf: [32]u8, label: string) -> Error {
	context = context_for(e)
	w := Idp_Wrapper{credential = credential, prf = prf, label = label}
	defer crypto.zero_explicit(&w.prf, size_of(w.prf))
	fn :: proc(e: ^Engine, rec: ^osync.Account_Record, a: ^osync.Account_Key, data: rawptr) -> Error {
		x := (^Idp_Wrapper)(data)
		salt := osync.idp_salt(transmute([]u8)e.account.subject)
		return _serr(osync.account_add_wrapper(rec, a, x.credential, x.label, .Unknown, salt, x.prf[:], e.identity.sign, _now_ms(e), context.temp_allocator))
	}
	return _with_account(e, fn, &w)
}

directory_add :: proc(e: ^Engine, space: prim.Id, person: osync.Identity, role: osync.Role = .Member, devices: []osync.Identity = nil) -> Error {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	dc := Dir_Ctx{person = person, role = role, devices = devices}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> (out: []u8, berr: Error) {
		c := (^Dir_Ctx)(data)
		now := _now_ms(e)
		signer := osync.keyring_member_signer(&e.keyring)
		last: []u8
		if x := osync.roster_find(&m.roster, c.person.sign); x < 0 || m.roster.members[x].removed {
			b := osync.Add_Body{sign = c.person.sign, box = c.person.box, kind = .Account, role = c.role, method = .Directory, person = c.person.sign, history = true}
			b.seal = _dir_seal(e, m, c.person, now)
			raw, err := osync.membership_add(m, signer, b, now)
			_serr(err) or_return
			last = raw
		}
		for d in c.devices {
			if x := osync.roster_find(&m.roster, d.sign); x >= 0 && !m.roster.members[x].removed {
				continue
			}
			b := osync.Add_Body{sign = d.sign, box = d.box, kind = .Device, role = c.role, method = .Directory, person = c.person.sign, history = true}
			b.seal = _dir_seal(e, m, d, now)
			raw, err := osync.membership_add(m, signer, b, now)
			_serr(err) or_return
			last = raw
		}
		return last, .None
	}
	return _members_change_all(e, sp, build, &dc, false)
}

directory_remove :: proc(e: ^Engine, space: prim.Id, person: osync.Public_Key) -> Error {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	dc := Dir_Ctx{person = osync.Identity{sign = person}}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> (out: []u8, berr: Error) {
		c := (^Dir_Ctx)(data)
		now := _now_ms(e)
		signer := osync.keyring_member_signer(&e.keyring)
		subjects := make([dynamic]osync.Public_Key, context.temp_allocator)
		for &x in m.roster.members {
			if !x.removed && (x.sign == c.person.sign || x.person == c.person.sign) {
				append(&subjects, x.sign)
			}
		}
		if len(subjects) == 0 {
			return nil, .Not_Found
		}
		last: []u8
		for subj in subjects {
			raw, err := osync.membership_remove(m, signer, subj, now)
			_serr(err) or_return
			last = raw
		}
		return last, .None
	}
	return _members_change_all(e, sp, build, &dc, true)
}

@(private)
Dir_Ctx :: struct {
	person:  osync.Identity,
	role:    osync.Role,
	devices: []osync.Identity,
}

@(private)
_dir_seal :: proc(e: ^Engine, m: ^osync.Membership, who: osync.Identity, now: u64) -> []u8 {
	k := osync.membership_current(m, now)
	if k == nil {
		return nil
	}
	wrap := make([dynamic]u8, context.temp_allocator)
	id := osync.identity_of(who.sign, who.box)
	if osync.membership_bundle(m, k, id, &wrap, e.cfg.random) != .None {
		return nil
	}
	return wrap[:]
}

@(private)
_account_adopt_local :: proc(e: ^Engine) {
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if sp.keyless || sp.mem.enroll != nil {
			continue
		}
		if len(sp.relay) == 0 && len(e.account.relay) > 0 {
			space_set_relay(e, id, e.account.relay, e.account.relay_public)
		}
		if account_join_space(e, id) == .None && e.account.pool != .Off {
			space_pool_set(e, id, true)
		}
	}
}

account_sign_out :: proc(e: ^Engine, detach := true) -> (spaces: int, err: Error) {
	context = context_for(e)
	_rv_close(e)
	e.approvals.waiting = false
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if sp.keyless {
			continue
		}
		if detach && len(sp.relay) > 0 {
			space_set_relay(e, id, "", {})
		}
		spaces += 1
	}
	delete(e.account.relay, e.allocator)
	delete(e.account.subject, e.allocator)
	e.account = {}
	path := _account_path(e) or_return
	prim.remove(e.vfs, path)
	_touch(e)
	return spaces, .None
}

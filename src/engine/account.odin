package engine

import "../prim"
import osync "../sync"

@(private)
ACCOUNT_FILE :: "account"
@(private)
ACCOUNT_FILE_VERSION :: 2

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
	label:        string,
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
	jobs:      [dynamic]^Acct_Job,
	next_job:  u64,
	granting:  bool,
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
	e.approvals.jobs = make([dynamic]^Acct_Job, e.allocator)
	path, perr := _account_path(e)
	if perr != .None {
		return
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None {
		return
	}
	r := prim.reader(data)
	version := prim.read_u8(&r)
	if version != 1 && version != ACCOUNT_FILE_VERSION {
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
	label := prim.read_str(&r) if version >= 2 else ""
	if !prim.reader_ok(&r) || p > u8(max(osync.Pool_Access)) {
		return
	}
	a.pool = osync.Pool_Access(p)
	a.relay, _ = _clone(relay, e.allocator)
	a.subject, _ = _clone(subject, e.allocator)
	a.label, _ = _clone(label, e.allocator)
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
	prim.write_str(&w, a.label)
	if w.err != .None {
		return .No_Memory
	}
	path := _account_path(e) or_return
	return _perr(prim.replace_atomic(e.vfs, path, buf[:]))
}

@(private)
_account_close :: proc(e: ^Engine) {
	_jobs_close(e)
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
	delete(e.account.label, e.allocator)
	e.approvals = {}
	e.account = {}
}

account_state :: proc "contextless" (e: ^Engine) -> Account_State {
	return e.account
}

account_login :: proc(e: ^Engine, subject: string, label: string, relay := "", relay_public: osync.Public_Key = {}, done: Account_Done = {}) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	j := _job_new(e, .Login, done)
	if j == nil {
		return res, .No_Memory
	}
	j.subject = _job_str(j, subject)
	j.label = _job_str(j, label)
	j.relay = _job_str(j, relay)
	j.relay_public = relay_public
	return _login_finish(j)
}

@(private)
_login_finish :: proc(j: ^Acct_Job) -> (res: Login_Result, err: Error) {
	err = _job_begin(j)
	if err == .Pending {
		return res, .Pending
	}
	res = j.res.login
	_job_free(j)
	return
}

account_login_cross_device :: proc(e: ^Engine, subject: string, done: Account_Done = {}) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	j := _job_new(e, .Login_Cross, done)
	if j == nil {
		return res, .No_Memory
	}
	j.subject = _job_str(j, subject)
	return _login_finish(j)
}

account_login_recovery :: proc(e: ^Engine, subject: string, recovery: string, done: Account_Done = {}) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	j := _job_new(e, .Login_Recovery, done)
	if j == nil {
		return res, .No_Memory
	}
	j.subject = _job_str(j, subject)
	j.recovery = _job_str(j, recovery)
	return _login_finish(j)
}

@(private)
_account_adopt_begin :: proc(e: ^Engine, subject: string, label: string, rec: ^osync.Account_Record, entries: [][]u8, a: ^osync.Account_Key, path: Login_Path) -> (spaces: int, err: Error) {
	delete(e.account.relay, e.allocator)
	delete(e.account.subject, e.allocator)
	kept := e.account.label
	defer delete(kept, e.allocator)
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
	e.account.label = _clone(label if len(label) > 0 else kept, e.allocator) or_return
	_account_store(e) or_return
	akr := osync.account_keyring(a)
	signer := osync.account_signer(a)
	e.approvals.path = path
	decoded := make([dynamic]osync.Manifest_Entry, context.temp_allocator)
	last := make(map[prim.Id]int, context.temp_allocator)
	for raw in entries {
		me: osync.Manifest_Entry
		if osync.manifest_entry_decode(raw, rec.sign, &akr, &me, context.temp_allocator) != .None {
			continue
		}
		last[prim.Id(me.space)] = len(decoded)
		append(&decoded, me)
	}
	for me, i in decoded {
		if last[prim.Id(me.space)] != i || me.left || space_left(e, prim.Id(me.space)) {
			continue
		}
		if sp, ok := e.spaces[prim.Id(me.space)]; ok && !sp.keyless {
			_space_unrefuse(e, sp)
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
	return spaces, .None
}

@(private)
_account_adopt_end :: proc(e: ^Engine, path: Login_Path, spaces: int) {
	_account_adopt_local(e)
	e.notices.tried = false
	if spaces == 0 {
		_emit(e, Event{kind = .Login_Done, length = i64(path)})
	}
	if e.cfg.approver && e.approvals.rv == nil {
		_rv_open(e, e.account.sign, e.account.relay, e.account.relay_public, false)
	}
	account_resume(e)
	_touch(e)
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
	list := _manifest_pending_load(e)
	append(&list, out[:])
	_manifest_pending_store(e, list[:])
	_manifest_issue(e, out[:])
}

@(private)
_account_manifest_leave :: proc(e: ^Engine, sp: ^Space) {
	if !e.account.have || e.cfg.sealed_store.add == nil {
		return
	}
	me := osync.Manifest_Entry {
		space = osync.Space_Id(sp.id),
		left  = true,
	}
	out := make([dynamic]u8, context.temp_allocator)
	acc := osync.identity_of(e.account.sign, e.account.box)
	if osync.manifest_entry_encode(acc, &e.keyring, e.account.cert, me, &out, e.cfg.random) != .None {
		return
	}
	list := _manifest_pending_load(e)
	append(&list, out[:])
	_manifest_pending_store(e, list[:])
	_manifest_issue(e, out[:])
}

@(private)
MANIFEST_PENDING_FILE :: "account.pending"

@(private)
_manifest_pending_load :: proc(e: ^Engine) -> [dynamic][]u8 {
	list := make([dynamic][]u8, context.temp_allocator)
	path, perr := _join(context.temp_allocator, e.pack_root, MANIFEST_PENDING_FILE)
	if perr != .None {
		return list
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None {
		return list
	}
	r := prim.reader(data)
	for prim.reader_remaining(&r) > 0 {
		b := prim.read_bytes(&r)
		if !prim.reader_ok(&r) {
			break
		}
		append(&list, b)
	}
	return list
}

@(private)
_manifest_pending_store :: proc(e: ^Engine, list: [][]u8) {
	path, perr := _join(context.temp_allocator, e.pack_root, MANIFEST_PENDING_FILE)
	if perr != .None {
		return
	}
	if len(list) == 0 {
		prim.remove(e.vfs, path)
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	for b in list {
		prim.write_bytes(&w, b)
	}
	if err := prim.replace_atomic(e.vfs, path, buf[:]); err != .None {
		_store_err(e, _perr(err))
	}
}

@(private)
_manifest_pending_remove :: proc(e: ^Engine, entry: []u8) {
	list := _manifest_pending_load(e)
	for b, i in list {
		if string(b) == string(entry) {
			ordered_remove(&list, i)
			_manifest_pending_store(e, list[:])
			return
		}
	}
}

@(private)
_manifest_issue :: proc(e: ^Engine, entry: []u8) {
	for j in e.approvals.jobs {
		if j.kind == .Manifest && string(j.entry) == string(entry) {
			return
		}
	}
	j := _job_new(e, .Manifest, {})
	if j == nil {
		return
	}
	j.subject = _job_str(j, e.account.subject)
	j.entry = _job_bytes(j, entry)
	if _job_start(j) != .Pending {
		_job_free(j)
	}
}

account_resume :: proc(e: ^Engine) {
	context = context_for(e)
	if !e.account.have || e.cfg.sealed_store.add == nil {
		return
	}
	for b in _manifest_pending_load(e) {
		_manifest_issue(e, b)
	}
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

account_wrappers :: proc(e: ^Engine, allocator := context.allocator, done: Account_Done = {}) -> (out: []Wrapper_Info, err: Error) {
	context = context_for(e)
	j := _job_new(e, .Wrappers, done)
	if j == nil {
		return nil, .No_Memory
	}
	err = _job_begin(j)
	if err == .Pending {
		return nil, .Pending
	}
	if err == .None {
		out = wrappers_clone(j.res.wrappers, allocator)
	}
	_job_free(j)
	return
}

wrappers_clone :: proc(list: []Wrapper_Info, allocator := context.allocator) -> []Wrapper_Info {
	out := make([]Wrapper_Info, len(list), allocator)
	for w, i in list {
		c := make([]u8, len(w.credential), allocator)
		copy(c, w.credential)
		l, _ := _clone(w.label, allocator)
		out[i] = Wrapper_Info{credential = c, label = l, ecosystem = w.ecosystem, added_by = w.added_by, added_at = w.added_at}
	}
	return out
}

@(private)
_with_finish :: proc(j: ^Acct_Job) -> Error {
	err := _job_begin(j)
	if err != .Pending {
		_job_free(j)
	}
	return err
}

account_wrapper_remove :: proc(e: ^Engine, credential: []u8, done: Account_Done = {}) -> Error {
	context = context_for(e)
	j := _job_new(e, .With, done)
	if j == nil {
		return .No_Memory
	}
	j.with = .Wrapper_Remove
	j.credential = _job_bytes(j, credential)
	return _with_finish(j)
}

account_recovery_key :: proc(e: ^Engine, allocator := context.allocator, done: Account_Done = {}) -> (text: string, err: Error) {
	context = context_for(e)
	j := _job_new(e, .With, done)
	if j == nil {
		return "", .No_Memory
	}
	j.with = .Recovery_Key
	j.secret = osync.recovery_secret_new(e.cfg.random)
	err = _job_begin(j)
	if err == .Pending {
		return "", .Pending
	}
	if err == .None {
		text, _ = _clone(j.res.text, allocator)
	}
	_job_free(j)
	return
}

account_pool_set :: proc(e: ^Engine, access: osync.Pool_Access, done: Account_Done = {}) -> Error {
	context = context_for(e)
	j := _job_new(e, .With, done)
	if j == nil {
		return .No_Memory
	}
	j.with = .Pool_Set
	j.access = access
	return _with_finish(j)
}

space_pool_set :: proc(e: ^Engine, space: prim.Id, on: bool, done: Account_Done = {}) -> Error {
	context = context_for(e)
	zero: osync.Public_Key
	if e.account.pool_sign == zero && on {
		if e.cfg.runner_pool.identity == nil {
			return .Not_Found
		}
		return account_pool_set(e, .Everything, done)
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
	_notices_device_removed(e, device)
	if removed == 0 {
		return 0, .Not_Found
	}
	return removed, .None
}

account_passkey_add :: proc(e: ^Engine, label: string, done: Account_Done = {}) -> Error {
	context = context_for(e)
	j := _job_new(e, .With, done)
	if j == nil {
		return .No_Memory
	}
	j.with = .Passkey_Add
	j.label = _job_str(j, label)
	return _with_finish(j)
}

account_login_prf :: proc(e: ^Engine, subject: string, credential: []u8, prf: [32]u8, label: string, relay := "", relay_public: osync.Public_Key = {}, done: Account_Done = {}) -> (res: Login_Result, err: Error) {
	context = context_for(e)
	j := _job_new(e, .Login_Prf, done)
	if j == nil {
		return res, .No_Memory
	}
	j.subject = _job_str(j, subject)
	j.credential = _job_bytes(j, credential)
	j.prf = prf
	j.label = _job_str(j, label)
	j.relay = _job_str(j, relay)
	j.relay_public = relay_public
	return _login_finish(j)
}

account_idp_salt :: proc(subject: string) -> [32]u8 {
	return osync.idp_salt(transmute([]u8)subject)
}

account_passkey_add_prf :: proc(e: ^Engine, credential: []u8, prf: [32]u8, label: string, done: Account_Done = {}) -> Error {
	context = context_for(e)
	j := _job_new(e, .With, done)
	if j == nil {
		return .No_Memory
	}
	j.with = .Passkey_Add_Prf
	j.credential = _job_bytes(j, credential)
	j.prf = prf
	j.label = _job_str(j, label)
	return _with_finish(j)
}

directory_add :: proc(e: ^Engine, space: prim.Id, person: osync.Identity, role: osync.Role = .Member, devices: []osync.Identity = nil, ready: Ready = {}) -> Error {
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
	return _members_change_all(e, sp, build, &dc, false, ready)
}

directory_remove :: proc(e: ^Engine, space: prim.Id, person: osync.Public_Key, ready: Ready = {}) -> Error {
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
	return _members_change_all(e, sp, build, &dc, true, ready)
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
	delete(e.account.label, e.allocator)
	e.account = {}
	path := _account_path(e) or_return
	prim.remove(e.vfs, path)
	_touch(e)
	return spaces, .None
}

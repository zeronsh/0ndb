package engine

import "base:runtime"
import "core:crypto"
import "core:mem/virtual"
import "../prim"
import osync "../sync"

Account_Result :: struct {
	login:      Login_Result,
	text:       string,
	wrappers:   []Wrapper_Info,
	enrollment: []u8,
}

Account_Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, e: ^Engine, res: ^Account_Result, err: Error),
	job:  ^u64,
}

@(private)
Job_Kind :: enum u8 {
	Login,
	Login_Cross,
	Login_Recovery,
	Login_Prf,
	With,
	Wrappers,
	Respond,
	Grant,
	Manifest,
	Enroll,
	Renew,
}

@(private)
With_Kind :: enum u8 {
	Wrapper_Remove,
	Recovery_Key,
	Pool_Set,
	Passkey_Add,
	Passkey_Add_Prf,
}

@(private)
Plug_Call :: enum u8 {
	None,
	Get,
	Put,
	Add,
	Unlock,
	Register,
	Verify,
	Attest,
	Renew,
}

@(private)
STAGE_ADOPT :: 100

@(private)
Acct_Job :: struct {
	e:            ^Engine,
	id:           u64,
	kind:         Job_Kind,
	with:         With_Kind,
	stage:        int,
	arena:        virtual.Arena,
	alloc:        runtime.Allocator,
	subject:      string,
	label:        string,
	wlabel:       string,
	relay:        string,
	relay_public: osync.Public_Key,
	recovery:     string,
	credential:   []u8,
	prf:          [32]u8,
	secret:       [osync.RECOVERY_SECRET_LEN]u8,
	access:       osync.Pool_Access,
	token:        []u8,
	evidence:     []u8,
	runner:       osync.Identity,
	lease:        u64,
	entry:        []u8,
	approve:      bool,
	pending:      Approval_Pending,
	rec:          osync.Account_Record,
	entries:      [][]u8,
	key:          osync.Account_Key,
	have_key:     bool,
	put_raw:      []u8,
	prev:         u64,
	salt:         [32]u8,
	mode:         osync.Unlock_Mode,
	path:         Login_Path,
	spaces:       int,
	call:         Plug_Call,
	perr:         osync.Error,
	pcred:        []u8,
	pprf:         [32]u8,
	peco:         osync.Ecosystem,
	waiting:      bool,
	finished:     bool,
	inline:       bool,
	err:          Error,
	res:          Account_Result,
	done:         Account_Done,
}

@(private)
_job_new :: proc(e: ^Engine, kind: Job_Kind, done: Account_Done) -> ^Acct_Job {
	j := new(Acct_Job, e.allocator)
	j.e = e
	j.kind = kind
	j.done = done
	if virtual.arena_init_growing(&j.arena, 4096) != nil {
		free(j, e.allocator)
		return nil
	}
	j.alloc = virtual.arena_allocator(&j.arena)
	e.approvals.next_job += 1
	j.id = e.approvals.next_job
	append(&e.approvals.jobs, j)
	return j
}

@(private)
_job_str :: proc(j: ^Acct_Job, s: string) -> string {
	out, _ := _clone(s, j.alloc)
	return out
}

@(private)
_job_bytes :: proc(j: ^Acct_Job, b: []u8) -> []u8 {
	out := make([]u8, len(b), j.alloc)
	copy(out, b)
	return out
}

@(private)
_job_free :: proc(j: ^Acct_Job) {
	e := j.e
	for x, i in e.approvals.jobs {
		if x == j {
			ordered_remove(&e.approvals.jobs, i)
			break
		}
	}
	if j.have_key {
		osync.account_key_clear(&j.key)
	}
	crypto.zero_explicit(&j.prf, size_of(j.prf))
	crypto.zero_explicit(&j.pprf, size_of(j.pprf))
	crypto.zero_explicit(&j.secret, size_of(j.secret))
	virtual.arena_destroy(&j.arena)
	free(j, e.allocator)
}

@(private)
_job_finish :: proc(j: ^Acct_Job, err: Error) {
	j.err = err
	j.finished = true
}

@(private)
_job_start :: proc(j: ^Acct_Job) -> Error {
	j.inline = true
	_job_run(j)
	j.inline = false
	if !j.finished {
		return .Pending
	}
	return j.err
}

@(private)
_job_run :: proc(j: ^Acct_Job) {
	for !j.finished && !j.waiting {
		_job_step(j)
	}
	if j.finished && !j.inline {
		_job_complete(j)
	}
}

@(private)
_job_complete :: proc(j: ^Acct_Job) {
	e := j.e
	if j.kind == .Grant && j.err != .None && j.err != .Closed && j.stage >= STAGE_ADOPT {
		_emit(e, Event{kind = .Login_Failed, err = j.err})
	}
	if j.kind == .Grant {
		e.approvals.granting = false
	}
	if j.done.call != nil {
		context = _outer(e)
		j.done.call(j.done.data, e, &j.res, j.err)
	}
	_job_free(j)
	_touch(e)
}

@(private)
_job_plug_done :: proc(data: rawptr, err: osync.Error, reply: ^osync.Plug_Reply) {
	j := (^Acct_Job)(data)
	context = context_for(j.e)
	if !j.waiting {
		return
	}
	j.waiting = false
	_job_take(j, err, reply)
	_job_run(j)
}

@(private)
_job_plug :: proc(j: ^Acct_Job, call: Plug_Call) {
	e := j.e
	reply: osync.Plug_Reply
	done := osync.Plug_Done{data = j, call = _job_plug_done}
	j.call = call
	err := osync.Error.Unsupported
	{
		context = _outer(e)
		subject := transmute([]u8)j.subject
		switch call {
		case .Get:
			if e.cfg.sealed_store.get != nil {
				err = e.cfg.sealed_store.get(e.cfg.sealed_store.data, subject, &reply, done)
			}
		case .Put:
			if e.cfg.sealed_store.put != nil {
				err = e.cfg.sealed_store.put(e.cfg.sealed_store.data, subject, j.put_raw, j.prev, &reply, done)
			}
		case .Add:
			if e.cfg.sealed_store.add != nil {
				err = e.cfg.sealed_store.add(e.cfg.sealed_store.data, subject, j.entry, &reply, done)
			}
		case .Unlock:
			if e.cfg.unlock.unlock != nil {
				opts := osync.account_unlock_options(&j.rec, j.alloc)
				if len(opts) == 0 {
					err = .Not_Found
				} else {
					err = e.cfg.unlock.unlock(e.cfg.unlock.data, j.rec.sign[:], opts, j.mode, &reply, done)
				}
			}
		case .Register:
			if e.cfg.unlock.register != nil {
				err = e.cfg.unlock.register(e.cfg.unlock.data, j.rec.sign[:], j.wlabel, j.salt, &reply, done)
			}
		case .Verify:
			if e.cfg.runner_pool.verify != nil {
				err = e.cfg.runner_pool.verify(e.cfg.runner_pool.data, j.token, j.runner, &reply, done)
			}
		case .Attest:
			if e.cfg.runner_pool.attest != nil {
				err = e.cfg.runner_pool.attest(e.cfg.runner_pool.data, j.evidence, j.runner, &reply, done)
			}
		case .Renew:
			if e.cfg.runner_pool.renew != nil {
				err = e.cfg.runner_pool.renew(e.cfg.runner_pool.data, j.runner, &reply, done)
			}
		case .None:
			err = .None
		}
	}
	if err == .Pending {
		j.waiting = true
		return
	}
	_job_take(j, err, &reply)
}

@(private)
_job_take :: proc(j: ^Acct_Job, err: osync.Error, reply: ^osync.Plug_Reply) {
	j.perr = err
	if err != .None {
		return
	}
	#partial switch j.call {
	case .Get:
		raw := _job_bytes(j, reply.record)
		if osync.account_record_decode(raw, &j.rec, j.alloc) != .None {
			j.perr = .Corrupt
			return
		}
		list := make([][]u8, len(reply.entries), j.alloc)
		for x, i in reply.entries {
			list[i] = _job_bytes(j, x)
		}
		j.entries = list
	case .Unlock, .Register:
		if len(reply.credential) == 0 {
			j.perr = .Invalid
			return
		}
		j.pcred = _job_bytes(j, reply.credential)
		j.pprf = reply.prf
		j.peco = reply.ecosystem
	case .Verify, .Renew:
		j.lease = reply.lease_ms
	}
}

@(private)
_job_put :: proc(j: ^Acct_Job, prev: u64, next_stage: int) {
	out := make([dynamic]u8, j.alloc)
	if err := osync.account_record_encode(&j.rec, &j.key, &out); err != .None {
		_job_finish(j, _serr(err))
		return
	}
	j.put_raw = out[:]
	j.prev = prev
	j.stage = next_stage
	_job_plug(j, .Put)
}

@(private)
_job_register :: proc(j: ^Acct_Job, label: string, next_stage: int) {
	prim.random_fill(j.e.cfg.random, j.salt[:])
	j.wlabel = _job_str(j, label)
	j.stage = next_stage
	_job_plug(j, .Register)
}

@(private)
_job_add_wrapper :: proc(j: ^Acct_Job) -> Error {
	e := j.e
	return _serr(osync.account_add_wrapper(&j.rec, &j.key, j.pcred, j.wlabel, j.peco, j.salt, j.pprf[:], e.identity.sign, _now_ms(e), j.alloc))
}

@(private)
_job_pool_identity :: proc(j: ^Acct_Job) {
	e := j.e
	if e.cfg.runner_pool.identity == nil {
		return
	}
	id: osync.Identity
	{
		context = _outer(e)
		id = e.cfg.runner_pool.identity(e.cfg.runner_pool.data)
	}
	zero: osync.Public_Key
	if id.sign == zero {
		return
	}
	j.rec.pool = .Everything
	j.rec.pool_sign = id.sign
	j.rec.pool_box = id.box
}

@(private)
_job_new_account :: proc(j: ^Acct_Job) -> Error {
	e := j.e
	if e.cfg.sealed_store.put == nil {
		return .Unsupported
	}
	_serr(osync.account_key_new(&j.key, e.cfg.random)) or_return
	j.have_key = true
	osync.account_record_new(&j.rec, &j.key, j.relay, j.relay_public, j.alloc)
	_job_pool_identity(j)
	return .None
}

@(private)
_job_open :: proc(j: ^Acct_Job, credential: []u8, prf: []u8) -> Error {
	if err := osync.account_open_with(&j.rec, credential, prf, &j.key, j.e.cfg.random); err != .None {
		return _serr(err)
	}
	j.have_key = true
	return .None
}

@(private)
_job_waiting :: proc(j: ^Acct_Job) {
	e := j.e
	if err := _approval_request(e, j.subject, &j.rec, j.label); err != .None {
		_job_finish(j, err)
		return
	}
	j.res.login = Login_Result{path = .Approval, status = .Waiting, code = e.approvals.code}
	_job_finish(j, .None)
}

@(private)
_job_step :: proc(j: ^Acct_Job) {
	if j.stage >= STAGE_ADOPT {
		_job_adopt(j)
		return
	}
	switch j.kind {
	case .Login, .Login_Prf:
		_job_login(j)
	case .Login_Cross:
		_job_cross(j)
	case .Login_Recovery:
		_job_recovery(j)
	case .With:
		_job_with(j)
	case .Wrappers:
		_job_wrappers(j)
	case .Respond:
		_job_respond(j)
	case .Grant:
		_job_grant(j)
	case .Manifest:
		_job_manifest(j)
	case .Enroll:
		_job_enroll(j)
	case .Renew:
		_job_renew(j)
	}
}

@(private)
_job_login :: proc(j: ^Acct_Job) {
	switch j.stage {
	case 0:
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr == .Not_Found {
			if err := _job_new_account(j); err != .None {
				_job_finish(j, err)
				return
			}
			if j.kind == .Login_Prf {
				j.salt = osync.idp_salt(transmute([]u8)j.subject)
				j.pcred = j.credential
				j.pprf = j.prf
				j.peco = .Unknown
				j.wlabel = j.label
				if err := _job_add_wrapper(j); err != .None {
					_job_finish(j, err)
					return
				}
				_job_put(j, 0, 12)
				return
			}
			_job_register(j, j.label, 11)
			return
		}
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if j.kind == .Login_Prf {
			if _job_open(j, j.credential, j.prf[:]) == .None {
				j.path = .Passkey
				j.stage = STAGE_ADOPT
				return
			}
			_job_waiting(j)
			return
		}
		j.mode = .Local
		j.stage = 2
		_job_plug(j, .Unlock)
	case 2:
		if j.perr == .None && _job_open(j, j.pcred, j.pprf[:]) == .None {
			j.path = .Passkey
			j.stage = STAGE_ADOPT
			return
		}
		_job_waiting(j)
	case 11:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if err := _job_add_wrapper(j); err != .None {
			_job_finish(j, err)
			return
		}
		_job_put(j, 0, 12)
	case 12:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		j.path = .Created
		j.stage = STAGE_ADOPT
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_cross :: proc(j: ^Acct_Job) {
	switch j.stage {
	case 0:
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		j.mode = .Cross_Device
		j.stage = 2
		_job_plug(j, .Unlock)
	case 2:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if err := _job_open(j, j.pcred, j.pprf[:]); err != .None {
			_job_finish(j, err)
			return
		}
		_rv_close(j.e)
		j.e.approvals.waiting = false
		j.path = .Cross_Device
		j.stage = STAGE_ADOPT
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_recovery :: proc(j: ^Acct_Job) {
	switch j.stage {
	case 0:
		s, derr := osync.recovery_decode(j.recovery)
		if derr != .None {
			_job_finish(j, .Invalid)
			return
		}
		j.secret = s
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if err := osync.account_open_recovery(&j.rec, j.secret, &j.key, j.e.cfg.random); err != .None {
			_job_finish(j, _serr(err))
			return
		}
		j.have_key = true
		j.path = .Recovery
		j.stage = STAGE_ADOPT
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_adopt :: proc(j: ^Acct_Job) {
	e := j.e
	switch j.stage {
	case STAGE_ADOPT:
		n, err := _account_adopt_begin(e, j.subject, &j.rec, j.entries, &j.key, j.path)
		if err != .None {
			_job_finish(j, err)
			return
		}
		j.spaces = n
		if j.path == .Approval || j.path == .Cross_Device || j.path == .Recovery {
			j.prev = j.rec.seq
			j.rec.seq += 1
			_job_register(j, "", STAGE_ADOPT + 1)
			return
		}
		j.stage = STAGE_ADOPT + 3
	case STAGE_ADOPT + 1:
		if j.perr != .None || _job_add_wrapper(j) != .None {
			j.stage = STAGE_ADOPT + 3
			return
		}
		_job_put(j, j.prev, STAGE_ADOPT + 2)
	case STAGE_ADOPT + 2:
		if j.perr != .None {
			_log(e, .Warn, "passkey wrapper store failed")
		}
		j.stage = STAGE_ADOPT + 3
	case STAGE_ADOPT + 3:
		_account_adopt_end(e, j.path, j.spaces)
		j.res.login = Login_Result{path = j.path, status = .Done, spaces = j.spaces}
		_job_finish(j, .None)
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_with :: proc(j: ^Acct_Job) {
	e := j.e
	switch j.stage {
	case 0:
		if !e.account.have {
			_job_finish(j, .Permission)
			return
		}
		j.subject = _job_str(j, e.account.subject)
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		j.mode = .Local
		j.stage = 2
		_job_plug(j, .Unlock)
	case 2:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if err := _job_open(j, j.pcred, j.pprf[:]); err != .None {
			_job_finish(j, err)
			return
		}
		j.prev = j.rec.seq
		if j.with == .Passkey_Add {
			_job_register(j, j.label, 3)
			return
		}
		if err := _job_with_apply(j); err != .None {
			_job_finish(j, err)
			return
		}
		j.stage = 4
	case 3:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if err := _job_add_wrapper(j); err != .None {
			_job_finish(j, err)
			return
		}
		j.stage = 4
	case 4:
		j.rec.seq = j.prev + 1
		_job_put(j, j.prev, 5)
	case 5:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		#partial switch j.with {
		case .Recovery_Key:
			j.res.text = osync.recovery_encode(j.secret, j.alloc)
		case .Pool_Set:
			e.account.pool = j.access
			_account_store(e)
			for id in _sorted_keys(e.spaces) {
				if !e.spaces[id].keyless {
					space_pool_set(e, id, j.access != .Off)
				}
			}
		}
		_job_finish(j, .None)
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_with_apply :: proc(j: ^Acct_Job) -> Error {
	e := j.e
	switch j.with {
	case .Wrapper_Remove:
		left := 0
		for &w in j.rec.wrappers {
			if w.ecosystem != .Recovery && string(w.credential) != string(j.credential) {
				left += 1
			}
		}
		if left == 0 {
			return .Permission
		}
		return .None if osync.account_remove_wrapper(&j.rec, j.credential) else .Not_Found
	case .Recovery_Key:
		return _serr(osync.account_add_recovery(&j.rec, &j.key, j.secret, e.identity.sign, _now_ms(e), e.cfg.random, j.alloc))
	case .Pool_Set:
		j.rec.pool = j.access
		_job_pool_identity(j)
		j.rec.pool = j.access
		zero: osync.Public_Key
		if j.access != .Off && j.rec.pool_sign == zero {
			return .Not_Found
		}
		e.account.pool_sign = j.rec.pool_sign
		e.account.pool_box = j.rec.pool_box
		return .None
	case .Passkey_Add_Prf:
		j.salt = osync.idp_salt(transmute([]u8)j.subject)
		j.pcred = j.credential
		j.pprf = j.prf
		j.peco = .Unknown
		j.wlabel = j.label
		return _job_add_wrapper(j)
	case .Passkey_Add:
		return .Invalid
	}
	return .Invalid
}

@(private)
_job_wrappers :: proc(j: ^Acct_Job) {
	e := j.e
	switch j.stage {
	case 0:
		if !e.account.have {
			_job_finish(j, .Permission)
			return
		}
		j.subject = _job_str(j, e.account.subject)
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		list := make([]Wrapper_Info, len(j.rec.wrappers), j.alloc)
		for &w, i in j.rec.wrappers {
			list[i] = Wrapper_Info{credential = _job_bytes(j, w.credential), label = _job_str(j, w.label), ecosystem = w.ecosystem, added_by = osync.device_id(w.added_by), added_at = w.added_at}
		}
		j.res.wrappers = list
		_job_finish(j, .None)
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_respond :: proc(j: ^Acct_Job) {
	e := j.e
	switch j.stage {
	case 0:
		if !j.approve {
			_job_send(j, nil)
			return
		}
		j.subject = _job_str(j, e.account.subject)
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		j.mode = .Local
		j.stage = 2
		_job_plug(j, .Unlock)
	case 2:
		if j.perr != .None {
			_job_finish(j, _serr(j.perr))
			return
		}
		if err := _job_open(j, j.pcred, j.pprf[:]); err != .None {
			_job_finish(j, err)
			return
		}
		out := make([dynamic]u8, j.alloc)
		req := j.pending.req
		if err := osync.approval_grant_encode(&req, &j.key, &out, e.cfg.random); err != .None {
			_job_finish(j, _serr(err))
			return
		}
		_job_send(j, out[:])
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_send :: proc(j: ^Acct_Job, grant: []u8) {
	e := j.e
	sp := e.approvals.rv
	if sp == nil || !sp.repl_on {
		_job_finish(j, .Offline)
		return
	}
	out := grant
	if out == nil {
		out = []u8{osync.APPROVE_DENY}
	}
	_job_finish(j, _serr(osync.replicator_direct(&sp.repl, osync.Device_Id(j.pending.from), osync.APPROVE_TAG, out)))
}

@(private)
_job_grant :: proc(j: ^Acct_Job) {
	e := j.e
	switch j.stage {
	case 0:
		j.stage = 1
		_job_plug(j, .Get)
	case 1:
		if j.perr != .None || j.rec.sign != j.key.device.public || !e.approvals.waiting {
			_job_finish(j, _serr(j.perr) if j.perr != .None else .Permission)
			return
		}
		e.approvals.waiting = false
		_rv_close(e)
		j.path = .Approval
		j.stage = STAGE_ADOPT
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_manifest :: proc(j: ^Acct_Job) {
	switch j.stage {
	case 0:
		j.stage = 1
		_job_plug(j, .Add)
	case 1:
		if j.perr == .None {
			_manifest_pending_remove(j.e, j.entry)
		} else {
			_log(j.e, .Warn, "account manifest entry not stored yet; retried on the next resume")
		}
		_job_finish(j, _serr(j.perr))
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_enroll :: proc(j: ^Acct_Job) {
	e := j.e
	switch j.stage {
	case 0:
		j.stage = 1
		_job_plug(j, .Verify)
	case 1:
		if j.perr != .None || j.lease == 0 {
			_job_finish(j, .Permission)
			return
		}
		if e.cfg.runner_pool.attest == nil {
			j.stage = 3
			return
		}
		j.stage = 2
		_job_plug(j, .Attest)
	case 2:
		if j.perr != .None {
			_job_finish(j, .Permission)
			return
		}
		j.stage = 3
	case 3:
		en, err := _pool_enrollment(e, j.runner, j.lease, j.alloc)
		if err != .None {
			_job_finish(j, err)
			return
		}
		j.res.enrollment = en
		_job_finish(j, .None)
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_renew :: proc(j: ^Acct_Job) {
	switch j.stage {
	case 0:
		j.stage = 1
		_job_plug(j, .Renew)
	case 1:
		if j.perr != .None || j.lease == 0 {
			_job_finish(j, .Permission)
			return
		}
		en, err := _pool_renewal(j.e, j.runner, j.lease, j.alloc)
		if err != .None {
			_job_finish(j, err)
			return
		}
		j.res.enrollment = en
		_job_finish(j, .None)
	case:
		_job_finish(j, .Invalid)
	}
}

@(private)
_job_cancel_plug :: proc(j: ^Acct_Job) {
	e := j.e
	done := osync.Plug_Done{data = j, call = _job_plug_done}
	context = _outer(e)
	#partial switch j.call {
	case .Get, .Put, .Add:
		if e.cfg.sealed_store.cancel != nil {
			e.cfg.sealed_store.cancel(e.cfg.sealed_store.data, done)
		}
	case .Unlock, .Register:
		if e.cfg.unlock.cancel != nil {
			e.cfg.unlock.cancel(e.cfg.unlock.data, done)
		}
	case .Verify, .Attest:
		if e.cfg.runner_pool.cancel != nil {
			e.cfg.runner_pool.cancel(e.cfg.runner_pool.data, done)
		}
	}
}

account_job_cancel :: proc(e: ^Engine, id: u64, err: Error = .Closed) {
	context = context_for(e)
	for j in e.approvals.jobs {
		if j.id != id {
			continue
		}
		if j.waiting {
			j.waiting = false
			_job_cancel_plug(j)
		}
		if !j.finished {
			_job_finish(j, err)
		}
		if !j.inline {
			_job_complete(j)
		}
		return
	}
}

@(private)
_jobs_close :: proc(e: ^Engine) {
	for len(e.approvals.jobs) > 0 {
		j := e.approvals.jobs[len(e.approvals.jobs) - 1]
		account_job_cancel(e, j.id, .Closed)
	}
	delete(e.approvals.jobs)
}

@(private)
_job_begin :: proc(j: ^Acct_Job) -> Error {
	err := _job_start(j)
	if err == .Pending && j.done.job != nil {
		j.done.job^ = j.id
	}
	return err
}

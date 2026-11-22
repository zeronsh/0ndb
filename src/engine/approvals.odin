package engine

import "core:crypto"
import "../prim"
import osync "../sync"

@(private)
_rv_creds_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	c := cast(^Rv_Creds)data
	if c.requester {
		return osync.request_credential(c.account, &c.keyring, binding, out)
	}
	return osync.account_credential(c.account, c.cert, &c.keyring, binding, out)
}

@(private)
_rv_open :: proc(e: ^Engine, account: osync.Public_Key, relay: string, relay_public: osync.Public_Key, requester: bool) -> Error {
	if e.approvals.rv != nil {
		if e.approvals.creds.requester == requester {
			return .None
		}
		_rv_close(e)
	}
	if len(relay) == 0 && e.cfg.transport.open == nil {
		return .Offline
	}
	ns := osync.account_namespace(account)
	sp := new(Space, e.allocator)
	sp.e = e
	sp.id = prim.Id(ns)
	sp.keyless = true
	sp.relay = _clone(relay, e.allocator) or_return
	sp.relay_public = relay_public
	e.approvals.creds = Rv_Creds{requester = requester, account = account, cert = e.account.cert, keyring = e.keyring}
	hx := prim.id_hex(sp.id)
	dir := _join(context.temp_allocator, e.pack_root, "rv", string(hx[:])) or_return
	cfg := osync.Replicator_Config {
		vfs          = e.vfs,
		dir          = dir,
		relay        = sp.relay,
		relay_public = sp.relay_public,
		self         = e.self,
		filtered     = true,
		random       = e.cfg.random,
		kernel_tls   = e.cfg.kernel_tls,
		on_event     = _rv_on_event,
		user         = sp,
		durable      = _repl_durable,
		credentials  = osync.Credentials{data = &e.approvals.creds, produce = _rv_creds_produce},
	}
	if e.cfg.transport.open != nil {
		cfg.link = osync.Client_Link{data = sp, send = _link_send, close = _link_close}
	}
	if err := _serr(osync.replicator_init(&sp.repl, e.loop, cfg, e.allocator)); err != .None {
		delete(sp.relay, e.allocator)
		free(sp, e.allocator)
		return err
	}
	sp.repl_on = true
	sp.open = true
	append(&e.links, sp)
	sp.link = Link(len(e.links))
	e.approvals.rv = sp
	ms := osync.members_scope(osync.Space_Id(sp.id))
	osync.replicator_follow_segments(&sp.repl, &ms, osync.MEMBERS_STREAM, 0, false)
	if !requester {
		_notices_start(e)
	}
	if e.cfg.transport.open != nil {
		conn, err := _transport_open(e, sp)
		if err != .None {
			_link_schedule(e, sp)
		} else {
			sp.conn = conn
		}
	} else {
		osync.replicator_start(&sp.repl)
	}
	return .None
}

@(private)
_rv_close :: proc(e: ^Engine) {
	sp := e.approvals.rv
	if sp == nil {
		return
	}
	_notices_stop(e)
	e.approvals.rv = nil
	_repl_stop(e, sp)
	sp.open = false
	delete(sp.relay, e.allocator)
	free(sp, e.allocator)
	clear(&e.approvals.present)
	clear(&e.approvals.sent)
}

@(private)
_rv_on_event :: proc(user: rawptr, ev: ^osync.Repl_Event) {
	sp := (^Space)(user)
	e := sp.e
	context = context_for(e)
	if _notices_on_event(e, ev) {
		_touch(e)
		return
	}
	#partial switch ev.kind {
	case .Direct:
		if u64(ev.length) != osync.APPROVE_TAG {
			return
		}
		data := make([]u8, len(ev.meta), e.allocator)
		copy(data, ev.meta)
		append(&e.approvals.inbox, Inbound{from = prim.Id(ev.device), data = data, kind = .Direct})
	case .Presence:
		append(&e.approvals.inbox, Inbound{from = prim.Id(ev.device), kind = .Presence, up = ev.from == 1})
	case .Connected:
		sp.connected = true
		_notices_connected(e)
		append(&e.approvals.inbox, Inbound{kind = .Connected})
	case .Disconnected:
		sp.connected = false
		if ev.err == .Auth {
			e.approvals.failed = true
		}
	case:
		return
	}
	_touch(e)
}

@(private)
_approval_request :: proc(e: ^Engine, subject: string, rec: ^osync.Account_Record, label: string) -> Error {
	prim.random_fill(e.cfg.random, e.approvals.nonce[:])
	card, cerr := osync.keyring_card(&e.keyring)
	_serr(cerr) or_return
	e.approvals.code = osync.approval_code(card[:], e.approvals.nonce)
	delete(e.approvals.label, e.allocator)
	e.approvals.label = _clone(label, e.allocator) or_return
	e.approvals.requester = true
	e.approvals.waiting = true
	e.approvals.failed = false
	clear(&e.approvals.sent)
	delete(e.account.subject, e.allocator)
	e.account.subject = _clone(subject, e.allocator) or_return
	return _rv_open(e, rec.sign, rec.relay, rec.relay_public, true)
}

account_listen :: proc(e: ^Engine) -> Error {
	context = context_for(e)
	if !e.account.have {
		return .Permission
	}
	e.approvals.requester = false
	return _rv_open(e, e.account.sign, e.account.relay, e.account.relay_public, false)
}

approvals_pending :: proc(e: ^Engine, allocator := context.allocator) -> []Approval_Info {
	context = context_for(e)
	out := make([dynamic]Approval_Info, 0, len(e.approvals.pending), allocator)
	for &p in e.approvals.pending {
		l, _ := _clone(p.label, allocator)
		append(&out, Approval_Info{device = p.from, code = p.code, label = l, at = p.at})
	}
	return out[:]
}

login_waiting :: proc "contextless" (e: ^Engine) -> (waiting: bool, code: [osync.APPROVE_CODE_LEN]u8, no_approver: bool) {
	return e.approvals.waiting, e.approvals.code, e.approvals.failed
}

approval_respond :: proc(e: ^Engine, code: string, approve: bool, done: Account_Done = {}) -> Error {
	context = context_for(e)
	idx := -1
	for &p, i in e.approvals.pending {
		if _code_eq(p.code[:], code) {
			idx = i
		}
	}
	if idx < 0 {
		return .Not_Found
	}
	p := e.approvals.pending[idx]
	ordered_remove(&e.approvals.pending, idx)
	sp := e.approvals.rv
	if sp == nil || !sp.repl_on {
		delete(p.label, e.allocator)
		return .Offline
	}
	j := _job_new(e, .Respond, done)
	if j == nil {
		delete(p.label, e.allocator)
		return .No_Memory
	}
	j.pending = p
	j.pending.label = _job_str(j, p.label)
	delete(p.label, e.allocator)
	j.approve = approve
	err := _job_begin(j)
	if err != .Pending {
		_job_free(j)
	}
	return err
}

@(private)
_code_eq :: proc(code: []u8, text: string) -> bool {
	n := 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '-' || c == ' ' {
			continue
		}
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if n >= len(code) || code[n] != c {
			return false
		}
		n += 1
	}
	return n == len(code)
}

@(private)
_approvals_step :: proc(e: ^Engine) {
	_notices_step(e)
	if len(e.approvals.inbox) == 0 {
		_approvals_check(e)
		return
	}
	inbox := e.approvals.inbox
	e.approvals.inbox = make([dynamic]Inbound, e.allocator)
	defer {
		for x in inbox {
			delete(x.data, e.allocator)
		}
		delete(inbox)
	}
	for &x in inbox {
		#partial switch x.kind {
		case .Presence:
			_presence_note(e, x.from, x.up)
		case .Connected:
		case .Direct:
			_approvals_direct(e, x.from, x.data)
		}
	}
	_approvals_check(e)
}

@(private)
_presence_note :: proc(e: ^Engine, d: prim.Id, up: bool) {
	for x, i in e.approvals.present {
		if x == d {
			if !up {
				unordered_remove(&e.approvals.present, i)
			}
			return
		}
	}
	if up {
		append(&e.approvals.present, d)
	}
}

@(private)
_approvals_check :: proc(e: ^Engine) {
	if !e.approvals.requester || !e.approvals.waiting {
		return
	}
	sp := e.approvals.rv
	if sp == nil || !sp.repl_on || !sp.connected {
		return
	}
	req: osync.Approval_Request
	card, cerr := osync.keyring_card(&e.keyring)
	if cerr != .None {
		return
	}
	req.card = card
	req.nonce = e.approvals.nonce
	req.label = e.approvals.label
	msg := make([dynamic]u8, context.temp_allocator)
	if osync.approval_request_encode(&req, &msg) != .None {
		return
	}
	for d in e.approvals.present {
		if d == e.self {
			continue
		}
		known := false
		for s in e.approvals.sent {
			if s == d {
				known = true
			}
		}
		if known {
			continue
		}
		if osync.replicator_direct(&sp.repl, osync.Device_Id(d), osync.APPROVE_TAG, msg[:]) == .None {
			append(&e.approvals.sent, d)
		}
	}
	if len(e.approvals.sent) == 0 && osync.replicator_presence_settled(&sp.repl) && !e.approvals.failed {
		e.approvals.failed = true
		_emit(e, Event{kind = .Login_Failed, err = .Offline, detail = "no approver online"})
	}
}

@(private)
_approvals_direct :: proc(e: ^Engine, from: prim.Id, data: []u8) {
	if len(data) == 0 {
		return
	}
	switch data[0] {
	case osync.APPROVE_REQUEST:
		if e.approvals.requester {
			return
		}
		req: osync.Approval_Request
		if osync.approval_request_decode(data, &req) != .None {
			return
		}
		id, cerr := osync.card_verify(req.card[:])
		if cerr != .None || prim.Id(id.id) != from {
			return
		}
		for &p in e.approvals.pending {
			if p.from == from && p.req.nonce == req.nonce {
				return
			}
		}
		label, _ := _clone(req.label, e.allocator)
		req.label = label
		code := osync.approval_code(req.card[:], req.nonce)
		append(&e.approvals.pending, Approval_Pending{from = from, req = req, label = label, code = code, at = _wall_ms(e)})
		_emit(e, Event{kind = .Approval_Requested, device = from, detail = string(code[:])})
	case osync.APPROVE_GRANT:
		if !e.approvals.requester || !e.approvals.waiting {
			return
		}
		if e.approvals.granting {
			return
		}
		a: osync.Account_Key
		defer osync.account_key_clear(&a)
		if osync.approval_grant_open(data, e.approvals.nonce, &e.keyring, &a, e.cfg.random) != .None {
			return
		}
		j := _job_new(e, .Grant, {})
		if j == nil {
			return
		}
		j.subject = _job_str(j, e.account.subject)
		j.label = _job_str(j, e.approvals.label)
		if osync.account_key_from_seed(&j.key, a.seed, e.cfg.random) != .None {
			_job_free(j)
			return
		}
		j.have_key = true
		e.approvals.granting = true
		if _job_start(j) != .Pending {
			_job_complete(j)
		}
	case osync.APPROVE_DENY:
		if e.approvals.requester && e.approvals.waiting {
			e.approvals.waiting = false
			_emit(e, Event{kind = .Login_Failed, err = .Permission, detail = "denied"})
		}
	}
	crypto.zero_explicit(raw_data(data), len(data))
}

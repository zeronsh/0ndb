package web

import "core:crypto"
import "../journal"
import "../prim"
import osync "../sync"

Web_Epoch :: struct {
	number: u32,
	tag:    osync.Epoch_Tag,
	secret: [32]u8,
}

Web_Pending :: struct {
	from: prim.Id,
	req:  osync.Approval_Request,
	code: [osync.APPROVE_CODE_LEN]u8,
}

Member_State :: struct {
	on:        bool,
	approver:  bool,
	m:         osync.Membership,
	account:   ^osync.Account_Key,
	proof:     []u8,
	epochs:    [dynamic]Web_Epoch,
	have:      bool,
	seen:      map[prim.Id]i64,
	cert:      [64]u8,
	pending:   [dynamic]Web_Pending,
}

@(private)
_member_free :: proc(s: ^Session) {
	ms := &s.member
	if ms.on {
		osync.membership_destroy(&ms.m)
	}
	if ms.account != nil {
		osync.account_key_clear(ms.account)
		free(ms.account, s.allocator)
	}
	for &x in ms.epochs {
		crypto.zero_explicit(&x.secret, size_of(x.secret))
	}
	delete(ms.epochs)
	delete(ms.seen)
	delete(ms.proof, s.allocator)
	delete(ms.pending)
	s.member = {}
}

@(private)
_open_account :: proc(s: ^Session, record: []u8, credential: []u8, prf: ^[32]u8, rec: ^osync.Account_Record) -> osync.Error {
	osync.account_record_decode(record, rec, context.temp_allocator) or_return
	a := new(osync.Account_Key, s.allocator)
	if err := osync.account_open_with(rec, credential, prf[:], a); err != .None {
		free(a, s.allocator)
		return err
	}
	s.member.account = a
	return .None
}

session_open_account :: proc(s: ^Session, record: []u8, entries: []u8, credential: []u8, prf: [32]u8, space: prim.Id) -> osync.Error {
	p := prf
	defer crypto.zero_explicit(&p, size_of(p))
	rec: osync.Account_Record
	_open_account(s, record, credential, &p, &rec) or_return
	akr := osync.account_keyring(s.member.account)
	chosen: osync.Manifest_Entry
	found := false
	pos := 0
	for pos + 4 <= len(entries) {
		n := int(prim.get_u32le(entries[pos:]))
		if pos + 4 + n > len(entries) {
			return .Corrupt
		}
		me: osync.Manifest_Entry
		if osync.manifest_entry_decode(entries[pos + 4:][:n], rec.sign, &akr, &me, s.allocator) == .None {
			zero: prim.Id
			if !found && (space == zero || prim.Id(me.space) == space) {
				chosen = me
				found = true
			}
		}
		pos += 4 + n
	}
	if !found {
		return .Not_Found
	}
	b := osync.Add_Body{sign = s.device.public, box = s.device.noise_public, kind = .Device, role = .Reader, method = .Account, person = rec.sign, history = true}
	payload := make([dynamic]u8, context.temp_allocator)
	osync.add_encode(b, &payload) or_return
	signer := osync.account_signer(s.member.account)
	proof, _, perr := osync.member_encode(.Add, chosen.space, signer, chosen.anchor_lamport + 1, []osync.Record_Id{chosen.anchor}, u64(max(prim.now_ms(), 0)), payload[:], s.allocator)
	if perr != .None {
		return perr
	}
	s.member.proof = proof
	s.member.on = true
	s.member.epochs = make([dynamic]Web_Epoch, s.allocator)
	s.member.seen = make(map[prim.Id]i64, s.allocator)
	osync.membership_init(&s.member.m, chosen.space, s.allocator)
	s.space_id = prim.Id(chosen.space)
	s.catalog_id = catalog_id(s.space_id)
	s.relay_pub = chosen.relay_public
	s.relay_addr = _clone(chosen.relay, s.allocator)
	s.creds = osync.Credentials{data = s, produce = _member_produce}
	return .None
}

session_open_approver :: proc(s: ^Session, record: []u8, credential: []u8, prf: [32]u8) -> osync.Error {
	p := prf
	defer crypto.zero_explicit(&p, size_of(p))
	rec: osync.Account_Record
	_open_account(s, record, credential, &p, &rec) or_return
	s.member.approver = true
	s.member.pending = make([dynamic]Web_Pending, s.allocator)
	s.member.cert = osync.device_cert(s.member.account, s.device.public)
	s.space_id = prim.Id(osync.account_namespace(rec.sign))
	s.relay_pub = rec.relay_public
	s.relay_addr = _clone(rec.relay, s.allocator)
	s.creds = osync.Credentials{data = s, produce = _approver_produce}
	return .None
}

@(private)
_member_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	s := (^Session)(data)
	return osync.member_credential(osync.Space_Id(s.space_id), &s.keyring, binding, [][]u8{s.member.proof}, out)
}

@(private)
_approver_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	s := (^Session)(data)
	return osync.account_credential(s.member.account.device.public, s.member.cert, &s.keyring, binding, out)
}

members_pattern :: proc(s: ^Session) -> (p: osync.Feed_Pattern, ok: bool) {
	if !s.member.on {
		return
	}
	sfx := osync.members_suffix(osync.Space_Id(s.space_id))
	p.kind = .Suffix
	copy(p.bytes[:16], sfx[:])
	return p, true
}

members_seen :: proc(s: ^Session, id: osync.Stream_Id, length: i64) -> bool {
	if !s.member.on || osync.stream_id_suffix(id) != osync.members_suffix(osync.Space_Id(s.space_id)) {
		return false
	}
	ms := osync.members_scope(osync.Space_Id(s.space_id))
	dev := prim.Id(osync.stream_device(id))
	rm := _remote_get(s, .Members, &ms, dev, osync.MEMBERS_STREAM, 0)
	if length > rm.relay_len {
		rm.relay_len = length
		journal.replica_set_length(&rm.rep, length)
	}
	if !rm.follow {
		_remote_follow(s, rm, true)
	}
	return true
}

members_landed :: proc(s: ^Session, rm: ^Remote) {
	end := journal.replica_length(&rm.rep)
	rd: journal.Reader
	journal.replica_reader(&rm.rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	pos := s.member.seen[rm.device]
	fresh := false
	for pos < end {
		body, next, err := journal.record_at(&rd, pos)
		if err != .None {
			break
		}
		if len(body) > 0 && body[0] == osync.MEMBER_RECORD {
			if ok, _ := osync.membership_ingest(&s.member.m, body); ok {
				fresh = true
			}
		}
		pos = next
	}
	s.member.seen[rm.device] = pos
	if fresh {
		_members_settle(s)
	}
}

@(private)
_members_settle :: proc(s: ^Session) {
	m := &s.member.m
	if osync.membership_resolve(m) != .None {
		return
	}
	self := osync.device_identity(&s.device)
	kr := osync.Keyring{data = s, identity = _kr_identity, sign = _kr_sign, unwrap = _kr_unwrap}
	osync.membership_open(m, osync.Opener{keyring = &kr, self = self})
	osync.membership_open_seals(m, osync.Opener{keyring = &kr, self = self})
	if s.member.account != nil {
		akr := osync.account_keyring(s.member.account)
		osync.membership_open(m, osync.Opener{keyring = &akr, self = osync.account_identity(s.member.account)})
	}
	for &k in m.keys {
		tag := osync.epoch_tag(k.number, k.id)
		have := false
		for x in s.member.epochs {
			if x.tag == tag {
				have = true
			}
		}
		if !have {
			append(&s.member.epochs, Web_Epoch{number = k.number, tag = tag, secret = k.secret})
		}
	}
	if m.have_naming && !s.member.have {
		s.member.have = true
		names: osync.Content_Key
		osync.derive_key(m.naming[:], "0ndb space names", nil, names.key[:])
		s.scope = osync.scope_make(names)
		crypto.zero_explicit(&names, size_of(names))
		c := _object_get(s, s.catalog_id, .Map)
		c.catalog = true
		s.feed_dirty = true
	}
	for _, o in s.objects {
		o.changed = true
	}
}

epoch_key_for :: proc(s: ^Session, object: prim.Id, tag: osync.Epoch_Tag) -> (key: [32]u8, ok: bool) {
	for &x in s.member.epochs {
		if x.tag == tag {
			o := object
			return osync.object_epoch_key(&x.secret, x.number, o[:]), true
		}
	}
	return share_epoch_key(s, tag)
}

@(private)
_kr_unwrap :: proc(data: rawptr, wrapped: []u8, key: ^osync.Content_Key) -> osync.Error {
	s := (^Session)(data)
	self := osync.device_identity(&s.device)
	return osync.open_key_from(&self, &s.device.noise, wrapped, key)
}

approver_direct :: proc(s: ^Session, from: prim.Id, data: []u8) {
	if !s.member.approver || len(data) == 0 || data[0] != osync.APPROVE_REQUEST {
		return
	}
	req: osync.Approval_Request
	if osync.approval_request_decode(data, &req) != .None {
		return
	}
	id, err := osync.card_verify(req.card[:])
	if err != .None || prim.Id(id.id) != from {
		return
	}
	req.label = _clone(req.label, s.allocator)
	code := osync.approval_code(req.card[:], req.nonce)
	append(&s.member.pending, Web_Pending{from = from, req = req, code = code})
	payload := make([dynamic]u8, context.temp_allocator)
	append(&payload, ..code[:])
	append(&payload, ..transmute([]u8)req.label)
	_event(s, .Approval, 0, 0, payload[:])
}

session_approve :: proc(s: ^Session, code: string, approve: bool) -> osync.Error {
	for &p, i in s.member.pending {
		if string(p.code[:]) != code {
			continue
		}
		req := p.req
		from := p.from
		ordered_remove(&s.member.pending, i)
		out := make([dynamic]u8, context.temp_allocator)
		if approve {
			osync.approval_grant_encode(&req, s.member.account, &out) or_return
		} else {
			append(&out, osync.APPROVE_DENY)
		}
		osync.client_direct(&s.link.client, osync.Device_Id(from), osync.APPROVE_TAG, out[:]) or_return
		link_flush(&s.link)
		return .None
	}
	return .Not_Found
}

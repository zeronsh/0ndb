package osync

import "base:runtime"
import "../journal"
import "../prim"

@(private)
AUTH_SPACES_MAX :: 4096

Member_Authorizer :: struct {
	inner:         Authorizer,
	vfs:           prim.Vfs,
	dir:           string,
	clock:         prim.Clock,
	default_quota: i64,
	open:          bool,
	allow:         ^Allow,
	spaces:        map[Space_Id]^Auth_Space,
	tick:          u64,
	revoked:       [dynamic]Device_Id,
	store:         Relay_Storage,
	allocator:     runtime.Allocator,
}

member_authorizer_set_storage :: proc(a: ^Member_Authorizer, store: Relay_Storage) {
	a.store = store
}

@(private)
Auth_Space :: struct {
	id:      Space_Id,
	m:       Membership,
	devices: map[Device_Id]int,
	used:    u64,
	ok:      bool,
}

member_authorizer_init :: proc(a: ^Member_Authorizer, vfs: prim.Vfs, dir: string, inner: Authorizer = {}, open := true, default_quota: i64 = 0, clock := prim.Clock{}, allow: ^Allow = nil, allocator := context.allocator) -> Error {
	a^ = {
		inner         = inner,
		vfs           = vfs,
		clock         = clock,
		default_quota = default_quota,
		open          = open,
		allow         = allow,
		allocator     = allocator,
	}
	a.dir = _clone_string(dir, allocator) or_return
	a.spaces = make(map[Space_Id]^Auth_Space, allocator)
	a.revoked = make([dynamic]Device_Id, allocator)
	if len(dir) == 0 {
		return .None
	}
	if err := prim.mkdir_all(vfs, dir, 0o700); err != .None {
		return _from_prim(err)
	}
	return .None
}

member_authorizer_destroy :: proc(a: ^Member_Authorizer) {
	for _, s in a.spaces {
		_auth_space_free(a, s)
	}
	delete(a.spaces)
	delete(a.revoked)
	delete(a.dir, a.allocator)
	a^ = {}
}

member_authorizer :: proc(a: ^Member_Authorizer) -> Authorizer {
	return Authorizer{data = a, authorize = _member_authorize, observe = _member_observe}
}





member_authorizer_records :: proc(a: ^Member_Authorizer, space: Space_Id) -> int {
	s := _auth_space(a, space)
	if s == nil {
		return 0
	}
	return len(s.m.records)
}

@(private)
_member_authorize :: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	a := cast(^Member_Authorizer)data
	if len(credential) == 0 {
		return .Auth
	}
	switch credential[0] {
	case MEMBER_CREDENTIAL:
		return _authorize_member(a, credential, binding, local, p)
	case REQUEST_CREDENTIAL:
		return _authorize_request(a, credential, binding, local, p)
	case ACCOUNT_CREDENTIAL:
		return _authorize_account(a, credential, binding, local, p)
	}
	if a.inner.authorize == nil {
		return .Auth
	}
	return a.inner.authorize(a.inner.data, credential, binding, local, p)
}

@(private)
_now :: proc(a: ^Member_Authorizer) -> u64 {
	return u64(max(prim.clock_wall_ms(a.clock), 0))
}

@(private)
_authorize_member :: proc(a: ^Member_Authorizer, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	r := prim.reader(credential[1:])
	space: Space_Id
	sign: Public_Key
	sig: [64]u8
	prim.read_fixed(&r, space[:])
	prim.read_fixed(&r, sign[:])
	prim.read_fixed(&r, sig[:])
	np := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || np > MEMBER_PROOFS_MAX {
		return .Auth
	}
	if !local && (len(binding) == 0 || !hello_verify(sign, sig[:], binding)) {
		return .Auth
	}
	quota := a.default_quota
	if a.allow != nil {
		q, allowed := allow_lookup(a.allow, space)
		if !allowed && !a.open {
			return .Auth
		}
		if allowed {
			quota = q
		}
	} else if !a.open {
		return .Auth
	}
	s := _auth_space(a, space)
	if s == nil {
		return .Io
	}
	for _ in 0 ..< int(np) {
		proof := prim.read_bytes(&r)
		if !prim.reader_ok(&r) {
			return .Auth
		}
		if !_proof_admissible(a, s, proof) {
			continue
		}
		if ok, _ := _auth_ingest(a, s, proof); ok {
			_auth_settle(a, s)
		}
	}
	dev := device_id(sign)
	idx, found := s.devices[dev]
	if !found {
		return .Auth
	}
	m := &s.m.roster.members[idx]
	if m.sign != sign {
		return .Auth
	}
	until: u64
	if !member_active(m, _now(a)) {
		if prim.reader_remaining(&r) == 0 {
			return .Auth
		}
		lease := prim.read_bytes(&r)
		u, ok := lease_admits(&s.m.roster, space, sign, lease, _now(a))
		if !prim.reader_ok(&r) || !ok {
			return .Auth
		}
		until = u
	}
	p^ = Principal {
		namespace   = space,
		participant = dev,
		quota       = quota,
		check       = _member_check,
		data        = a,
		until       = until,
		lapsed      = _member_lapsed,
	}
	return .None
}

@(private)
_authorize_request :: proc(a: ^Member_Authorizer, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	if len(credential) != 1 + 32 + 32 + 64 {
		return .Auth
	}
	account, sign: Public_Key
	copy(account[:], credential[1:33])
	copy(sign[:], credential[33:65])
	if !local && (len(binding) == 0 || !hello_verify(sign, credential[65:129], binding)) {
		return .Auth
	}
	if !a.open {
		return .Auth
	}
	p^ = Principal {
		namespace   = account_namespace(account),
		participant = device_id(sign),
		quota       = 0,
		max_conns   = 2,
		check       = _request_check,
		data        = a,
	}
	return .None
}

@(private)
_authorize_account :: proc(a: ^Member_Authorizer, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	if len(credential) != 1 + 32 + 64 + 32 + 64 {
		return .Auth
	}
	account, sign: Public_Key
	copy(account[:], credential[1:33])
	copy(sign[:], credential[97:129])
	if !device_cert_verify(account, sign, credential[33:97]) {
		return .Auth
	}
	if !local && (len(binding) == 0 || !hello_verify(sign, credential[129:193], binding)) {
		return .Auth
	}
	if !a.open {
		return .Auth
	}
	p^ = Principal {
		namespace   = account_namespace(account),
		participant = device_id(sign),
		quota       = a.default_quota if a.default_quota > 0 else ACCOUNT_NAMESPACE_QUOTA,
		check       = _account_check,
		data        = a,
	}
	return .None
}

@(private)
_request_check :: proc(data: rawptr, p: ^Principal, access: Access, id: [32]u8) -> bool {
	return access == .List && id == {}
}

@(private)
_account_check :: proc(data: rawptr, p: ^Principal, access: Access, id: [32]u8) -> bool {
	#partial switch access {
	case .List, .Read, .Get:
		return true
	case .Append, .Drop:
		x := id
		pid := p.participant
		return string(x[:16]) == string(pid[:])
	}
	return false
}

@(private)
_member_lapsed :: proc(data: rawptr, p: ^Principal) -> bool {
	a := cast(^Member_Authorizer)data
	s := _auth_space(a, p.namespace)
	if s == nil {
		return false
	}
	idx, found := s.devices[p.participant]
	if !found {
		return false
	}
	m := &s.m.roster.members[idx]
	return m.kind == .Runner && !m.removed && !member_active(m, _now(a)) && p.until <= _now(a)
}

@(private)
_member_check :: proc(data: rawptr, p: ^Principal, access: Access, id: [32]u8) -> bool {
	a := cast(^Member_Authorizer)data
	s := _auth_space(a, p.namespace)
	if s == nil {
		return false
	}
	idx, found := s.devices[p.participant]
	if !found {
		return false
	}
	m := &s.m.roster.members[idx]
	if !member_active(m, _now(a)) && (m.removed || p.until <= _now(a)) {
		return false
	}
	switch access {
	case .List, .Read, .Get:
		return true
	case .Append, .Drop:
		x := id
		pid := p.participant
		return string(x[:16]) == string(pid[:]) && m.role != .Reader
	case .Redact:
		return m.role != .Reader
	case .Put, .Forget, .Fill:
		return m.role != .Reader
	}
	return false
}

@(private)
_member_observe :: proc(data: rawptr, space: Space_Id, id: Stream_Id, bytes: []u8, revoked: ^[dynamic]Device_Id) {
	a := cast(^Member_Authorizer)data
	suffix := stream_id_suffix(id)
	if suffix != members_suffix(space) {
		return
	}
	s := _auth_space(a, space)
	if s == nil {
		return
	}
	before := make(map[Device_Id]bool, context.temp_allocator)
	now := _now(a)
	for &m in s.m.roster.members {
		if member_active(&m, now) {
			before[m.device] = true
		}
	}
	fresh := false
	pos := 0
	for pos + journal.OVERHEAD <= len(bytes) {
		n := int(prim.get_u32le(bytes[pos:]))
		if n < 0 || pos + journal.OVERHEAD + n > len(bytes) {
			break
		}
		body := bytes[pos + journal.HEADER:][:n]
		if len(body) > 0 && body[0] == MEMBER_RECORD {
			if ok, _ := _auth_ingest(a, s, body); ok {
				fresh = true
			}
		}
		pos += journal.OVERHEAD + n
	}
	if !fresh {
		return
	}
	_auth_settle(a, s)
	for &m in s.m.roster.members {
		if before[m.device] && !member_active(&m, now) {
			append(revoked, m.device)
		}
	}
}

@(private)
_proof_admissible :: proc(a: ^Member_Authorizer, s: ^Auth_Space, raw: []u8) -> bool {
	rec: Member_Record
	if member_decode(raw, &rec, false, context.temp_allocator) != .None {
		return false
	}
	if rec.op == .Genesis {
		return space_id_of(rec.id) == s.id && len(s.m.records) == 0
	}
	if rec.space != s.id {
		return false
	}
	idx, found := s.devices[device_id(rec.author)]
	if !found {
		return false
	}
	return member_active(&s.m.roster.members[idx], _now(a))
}

@(private)
_auth_ingest :: proc(a: ^Member_Authorizer, s: ^Auth_Space, raw: []u8) -> (bool, Error) {
	fresh, err := membership_ingest(&s.m, raw)
	if err != .None || !fresh {
		return false, err
	}
	return true, _auth_persist(a, s, raw)
}

@(private)
_auth_settle :: proc(a: ^Member_Authorizer, s: ^Auth_Space) {
	membership_resolve(&s.m)
	clear(&s.devices)
	for &m, i in s.m.roster.members {
		s.devices[m.device] = i
	}
}

@(private)
_auth_path :: proc(a: ^Member_Authorizer, space: Space_Id) -> string {
	h := prim.id_hex(space)
	p, _ := prim.path_join(context.temp_allocator, a.dir, string(h[:]))
	return p
}

@(private)
_auth_persist :: proc(a: ^Member_Authorizer, s: ^Auth_Space, raw: []u8) -> Error {
	if len(a.dir) == 0 {
		return .None
	}
	path := _auth_path(a, s.id)
	fd, oerr := prim.open_file(a.vfs, path, {.Write, .Create}, 0o600)
	if oerr != .None {
		return _from_prim(oerr)
	}
	defer prim.close_file(a.vfs, fd)
	size, serr := prim.file_size(a.vfs, fd)
	if serr != .None {
		return _from_prim(serr)
	}
	hdr: [4]u8
	prim.put_u32le(hdr[:], u32(len(raw)))
	if err := prim.write_at(a.vfs, fd, hdr[:], size); err != .None {
		return _from_prim(err)
	}
	return _from_prim(prim.write_at(a.vfs, fd, raw, size + 4))
}

@(private)
_auth_space :: proc(a: ^Member_Authorizer, space: Space_Id) -> ^Auth_Space {
	a.tick += 1
	if s, ok := a.spaces[space]; ok {
		s.used = a.tick
		return s
	}
	if len(a.spaces) >= AUTH_SPACES_MAX {
		oldest: Space_Id
		best := max(u64)
		for k, v in a.spaces {
			if v.used < best {
				best = v.used
				oldest = k
			}
		}
		if v, ok := a.spaces[oldest]; ok {
			delete_key(&a.spaces, oldest)
			_auth_space_free(a, v)
		}
	}
	s := new(Auth_Space, a.allocator)
	s.id = space
	s.used = a.tick
	membership_init(&s.m, space, a.allocator)
	s.devices = make(map[Device_Id]int, a.allocator)
	data: []u8
	err := prim.Error.Not_Found
	if len(a.dir) > 0 {
		data, err = prim.read_file(a.vfs, _auth_path(a, space), context.temp_allocator)
	}
	if err == .None {
		pos := 0
		for pos + 4 <= len(data) {
			n := int(prim.get_u32le(data[pos:]))
			if pos + 4 + n > len(data) {
				break
			}
			membership_ingest(&s.m, data[pos + 4:][:n])
			pos += 4 + n
		}
	}
	_auth_settle(a, s)
	_auth_reconcile(a, s)
	a.spaces[space] = s
	return s
}

@(private)
_auth_reconcile :: proc(a: ^Member_Authorizer, s: ^Auth_Space) {
	if a.store.namespace_open == nil || a.store.list_begin == nil || a.store.stream_open == nil || a.store.stream_read == nil {
		return
	}
	ns, _, nerr := a.store.namespace_open(a.store.data, s.id)
	if nerr != .None {
		return
	}
	defer a.store.namespace_close(a.store.data, ns)
	it, _, lerr := a.store.list_begin(a.store.data, ns, 0)
	if lerr != .None {
		return
	}
	suffix := members_suffix(s.id)
	ids := make([dynamic]Stream_Id, context.temp_allocator)
	for {
		id, ok := a.store.list_next(a.store.data, it)
		if !ok {
			break
		}
		if stream_id_suffix(id) == suffix {
			append(&ids, id)
		}
	}
	a.store.list_end(a.store.data, it)
	fresh := false
	for id in ids {
		st, length, serr := a.store.stream_open(a.store.data, ns, id, false)
		if serr != .None || st == nil {
			continue
		}
		if length > 0 && length <= RELAY_OBSERVE_MAX * 16 {
			buf := make([]u8, int(length), context.temp_allocator)
			got := 0
			for got < len(buf) {
				n, rerr := a.store.stream_read(a.store.data, st, i64(got), buf[got:])
				if rerr != .None || n <= 0 {
					break
				}
				got += n
			}
			pos := 0
			for pos + journal.OVERHEAD <= got {
				n := int(prim.get_u32le(buf[pos:]))
				if n < 0 || pos + journal.OVERHEAD + n > got {
					break
				}
				body := buf[pos + journal.HEADER:][:n]
				if len(body) > 0 && body[0] == MEMBER_RECORD {
					if ok, _ := _auth_ingest(a, s, body); ok {
						fresh = true
					}
				}
				pos += journal.OVERHEAD + n
			}
		}
		a.store.stream_close(a.store.data, st)
	}
	if fresh {
		_auth_settle(a, s)
	}
}

@(private)
_auth_space_free :: proc(a: ^Member_Authorizer, s: ^Auth_Space) {
	membership_destroy(&s.m)
	delete(s.devices)
	free(s, a.allocator)
}

member_authorizer_active :: proc(a: ^Member_Authorizer, space: Space_Id, sign: Public_Key) -> bool {
	s := _auth_space(a, space)
	if s == nil {
		return false
	}
	idx, found := s.devices[device_id(sign)]
	if !found {
		return false
	}
	m := &s.m.roster.members[idx]
	return m.sign == sign && member_active(m, _now(a)) && m.role <= .Member && m.kind != .Runner && m.kind != .Guest
}

package engine

import "core:crypto"
import "../journal"
import "../obj"
import "../prim"
import osync "../sync"

@(private)
MEMBERS_DIR :: "members"
@(private)
ANOMALY_WINDOW_MS :: 60_000

Space_Epoch :: struct {
	number: u32,
	tag:    osync.Epoch_Tag,
	secret: [32]u8,
}

Member_Creds :: struct {
	space:   prim.Id,
	keyring: osync.Keyring,
	proofs:  [dynamic][]u8,
}

Space_Members :: struct {
	naming:      [32]u8,
	have_naming: bool,
	epochs:      [dynamic]Space_Epoch,
	current:     int,
	removed:     bool,
	revoked:     bool,
	me:          osync.Member_Kind,
	role:        osync.Role,
	seen:        map[prim.Id]i64,
	creds:       Member_Creds,
	enroll:      ^osync.Account_Key,
	records:     int,
	enrolls:     [dynamic]i64,
	lease_ms:    u64,
	expires:     u64,
	loaded:      bool,
	caught:      bool,
	deferred:    bool,
	want:        map[prim.Id]i64,
}

Member_Info :: struct {
	device:    prim.Id,
	sign:      osync.Public_Key,
	box:       osync.Public_Key,
	kind:      osync.Member_Kind,
	role:      osync.Role,
	method:    osync.Enroll_Method,
	person:    osync.Public_Key,
	added_by:  prim.Id,
	added_at:  u64,
	expires:   u64,
	removed:   bool,
	in_tree:   bool,
	self:      bool,
}

Members_Status :: struct {
	epoch:    u32,
	eligible: bool,
	held:     bool,
	members:  int,
	records:  int,
	removed:  bool,
	revoked:  bool,
}

@(private)
_members_dir :: proc(e: ^Engine, space: prim.Id, allocator := context.temp_allocator) -> (path: string, err: Error) {
	h := prim.id_hex(space)
	return _join(allocator, e.pack_root, MEMBERS_DIR, string(h[:]))
}

@(private)
_members_file :: proc(e: ^Engine, space: prim.Id, name: string) -> (path: string, err: Error) {
	d := _members_dir(e, space) or_return
	return _join(context.temp_allocator, d, name)
}

@(private)
_now_ms :: proc(e: ^Engine) -> u64 {
	return u64(max(_wall_ms(e), 0))
}

@(private)
_members_init :: proc(e: ^Engine, sp: ^Space) {
	sp.mem.current = -1
	sp.mem.epochs = make([dynamic]Space_Epoch, e.allocator)
	sp.mem.seen = make(map[prim.Id]i64, e.allocator)
	sp.mem.want = make(map[prim.Id]i64, e.allocator)
	sp.mem.creds.proofs = make([dynamic][]u8, e.allocator)
	sp.mem.enrolls = make([dynamic]i64, e.allocator)
	sp.mem.creds.space = sp.id
	sp.mem.creds.keyring = e.keyring
}

@(private)
_members_free :: proc(e: ^Engine, sp: ^Space) {
	for &ep in sp.mem.epochs {
		crypto.zero_explicit(&ep.secret, size_of(ep.secret))
	}
	delete(sp.mem.epochs)
	delete(sp.mem.seen)
	delete(sp.mem.want)
	for p in sp.mem.creds.proofs {
		delete(p, e.allocator)
	}
	delete(sp.mem.creds.proofs)
	delete(sp.mem.enrolls)
	if sp.mem.enroll != nil {
		osync.account_key_clear(sp.mem.enroll)
		free(sp.mem.enroll, e.allocator)
	}
	crypto.zero_explicit(&sp.mem.naming, size_of(sp.mem.naming))
	sp.mem = {}
}

@(private)
_members_load :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) -> Error {
	osync.membership_init(m, sp.id, context.temp_allocator)
	path := _members_file(e, sp.id, "log") or_return
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None && err != .Not_Found {
		return _perr(err)
	}
	pos := 0
	for pos + 4 <= len(data) {
		n := int(prim.get_u32le(data[pos:]))
		if pos + 4 + n > len(data) {
			break
		}
		osync.membership_ingest(m, data[pos + 4:][:n])
		pos += 4 + n
	}
	sp.mem.records = len(m.records)
	_members_secrets_load(e, sp, m)
	return .None
}

@(private)
_members_log_append :: proc(e: ^Engine, sp: ^Space, raw: []u8) -> Error {
	dir := _members_dir(e, sp.id) or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	path := _join(context.temp_allocator, dir, "log") or_return
	fd, oerr := prim.open_file(e.vfs, path, {.Write, .Create}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	defer prim.close_file(e.vfs, fd)
	size, serr := prim.file_size(e.vfs, fd)
	if serr != .None {
		return _perr(serr)
	}
	hdr: [4]u8
	prim.put_u32le(hdr[:], u32(len(raw)))
	_perr(prim.write_at(e.vfs, fd, hdr[:], size)) or_return
	_perr(prim.write_at(e.vfs, fd, raw, size + 4)) or_return
	return _perr(prim.datasync(e.vfs, fd))
}

@(private)
_members_stream_append :: proc(e: ^Engine, sp: ^Space, raws: [][]u8) -> Error {
	dir := _members_dir(e, sp.id) or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	path := _join(context.temp_allocator, dir, "stream") or_return
	j: journal.Journal
	_jerr(journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator)) or_return
	for raw in raws {
		if _, aerr := journal.journal_append(&j, raw); aerr != .None {
			journal.journal_close(&j)
			return _jerr(aerr)
		}
	}
	cerr := journal.journal_commit(&j)
	n := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	_jerr(cerr) or_return
	if sp.repl_on {
		ms := osync.members_scope(sp.id)
		osync.replicator_publish(&sp.repl, &ms, osync.MEMBERS_STREAM, 0, path, n)
	}
	return .None
}

@(private)
_members_publish :: proc(e: ^Engine, sp: ^Space) {
	if !sp.repl_on {
		return
	}
	path, perr := _members_file(e, sp.id, "stream")
	if perr != .None || !prim.exists(e.vfs, path) {
		return
	}
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator) != .None {
		return
	}
	n := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	ms := osync.members_scope(sp.id)
	osync.replicator_publish(&sp.repl, &ms, osync.MEMBERS_STREAM, 0, path, n)
}

@(private)
_members_emit :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, raws: [][]u8) -> Error {
	for raw in raws {
		_members_log_append(e, sp, raw) or_return
	}
	return _members_stream_append(e, sp, raws)
}

@(private)
_members_secrets_load :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	path, perr := _members_file(e, sp.id, "secrets")
	if perr != .None {
		return
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None || len(data) < osync.WRAP_LEN + 16 {
		return
	}
	defer crypto.zero_explicit(raw_data(data), len(data))
	k: osync.Content_Key
	defer crypto.zero_explicit(&k, size_of(k))
	if e.keyring.unwrap(e.keyring.data, data[:osync.WRAP_LEN], &k) != .None {
		return
	}
	plain := make([]u8, len(data) - osync.WRAP_LEN - 16, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	if !osync.aead_open(k.key[:], transmute([]u8)string("0ndb member secrets"), data[osync.WRAP_LEN:], plain) {
		return
	}
	osync.membership_secrets_decode(m, plain)
}

@(private)
_members_secrets_store :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) -> Error {
	plain := make([dynamic]u8, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	_serr(osync.membership_secrets_encode(m, &plain)) or_return
	k: osync.Content_Key
	defer crypto.zero_explicit(&k, size_of(k))
	prim.random_fill(e.cfg.random, k.key[:])
	out := make([]u8, osync.WRAP_LEN + len(plain) + 16, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(out), len(out))
	wrap: [osync.WRAP_LEN]u8
	id := e.identity
	_serr(e.keyring.wrap(e.keyring.data, &id, &k, &wrap)) or_return
	copy(out, wrap[:])
	osync.aead_seal(k.key[:], transmute([]u8)string("0ndb member secrets"), plain[:], out[osync.WRAP_LEN:])
	dir := _members_dir(e, sp.id) or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	path := _join(context.temp_allocator, dir, "secrets") or_return
	return _perr(prim.replace_atomic(e.vfs, path, out))
}

@(private)
_members_adopt :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	if m.have_naming && !sp.mem.have_naming && !sp.keyless {
		sp.mem.naming = m.naming
		sp.mem.have_naming = true
		_space_keys_from_naming(sp)
		if sp.open {
			_handles_sweep_space(e, sp)
			_catalog_table_close(sp)
		}
		_space_ready(e, sp)
	}
	added_epochs := false
	for &k in m.keys {
		tag := osync.epoch_tag(k.number, k.id)
		found := false
		for x in sp.mem.epochs {
			if x.tag == tag {
				found = true
				break
			}
		}
		if !found {
			append(&sp.mem.epochs, Space_Epoch{number = k.number, tag = tag, secret = k.secret})
			added_epochs = true
		}
	}
	if added_epochs {
		_members_unlock_trees(e, sp)
	}
	prev := sp.mem.current
	prev_tag: osync.Epoch_Tag
	if prev >= 0 {
		prev_tag = sp.mem.epochs[prev].tag
	}
	sp.mem.current = -1
	if cur := osync.membership_current(m, _now_ms(e)); cur != nil {
		tag := osync.epoch_tag(cur.number, cur.id)
		for x, i in sp.mem.epochs {
			if x.tag == tag {
				sp.mem.current = i
			}
		}
	}
	if sp.mem.current >= 0 {
		ck := osync.epoch_content_key(&sp.mem.epochs[sp.mem.current].secret, sp.mem.epochs[sp.mem.current].number)
		sp.keys.content = ck
		crypto.zero_explicit(&ck, size_of(ck))
		if prev < 0 || sp.mem.epochs[sp.mem.current].tag != prev_tag {
			_members_epoch_changed(e, sp)
		}
	}
	me := osync.roster_find(&m.roster, e.identity.sign)
	if me >= 0 {
		x := &m.roster.members[me]
		sp.mem.me = x.kind
		sp.mem.role = x.role
		sp.mem.lease_ms = x.lease_ms
		sp.mem.expires = x.expires
		was := sp.mem.removed
		sp.mem.removed = !osync.member_active(x, _now_ms(e))
		if sp.mem.removed && !was {
			_emit(e, Event{kind = .Access_Revoked, space = sp.id, device = e.self})
			_waiters_fail_space(e, sp.id, .Permission)
		}
	}
}

@(private)
_space_keys_from_naming :: proc(sp: ^Space) {
	osync.scope_clear(&sp.scope)
	names: osync.Content_Key
	osync.derive_key(sp.mem.naming[:], "0ndb space names", nil, names.key[:])
	sp.scope = osync.scope_make(names, sp.mode)
	crypto.zero_explicit(&names, size_of(names))
	sp.keys.secret = sp.mem.naming
	sp.keys.id = sp.id
}

@(private)
_members_epoch_changed :: proc(e: ^Engine, sp: ^Space) {
	for h in e.lru {
		if h.sp == sp && h.w_open && h.own_tree != nil {
			_own_tree_epoch(e, h)
		}
	}
	ep := sp.mem.epochs[sp.mem.current]
	_emit(e, Event{kind = .Epoch_Changed, space = sp.id, length = i64(ep.number)})
}

space_epoch_tag :: proc(sp: ^Space) -> (tag: osync.Epoch_Tag, ok: bool) {
	if sp.mem.current < 0 {
		return
	}
	return sp.mem.epochs[sp.mem.current].tag, true
}

@(private)
_epoch_secret_of :: proc(sp: ^Space, tag: osync.Epoch_Tag) -> (^[32]u8, u32) {
	for &x in sp.mem.epochs {
		if x.tag == tag {
			return &x.secret, x.number
		}
	}
	return nil, 0
}

@(private)
_object_epoch_key :: proc(sp: ^Space, object: prim.Id, tag: osync.Epoch_Tag) -> (key: [32]u8, ok: bool) {
	zero: osync.Epoch_Tag
	if tag == zero {
		return
	}
	if s, n := _epoch_secret_of(sp, tag); s != nil {
		o := object
		return osync.object_epoch_key(s, n, o[:]), true
	}
	if g, found := sp.grant_epochs[object]; found {
		for x in g {
			if x.tag == tag {
				return x.secret, true
			}
		}
	}
	return
}

@(private)
_own_tree_epoch :: proc(e: ^Engine, h: ^Handle) {
	sp := h.sp
	t := h.own_tree
	if t == nil || sp.mode != .End_To_End {
		return
	}
	tag, ok := space_epoch_tag(sp)
	if !ok {
		if g, found := sp.grant_epochs[h.id]; found && len(g) > 0 {
			tag = g[len(g) - 1].tag
			ok = true
		}
	}
	if !ok || t.tree.epoch == tag {
		return
	}
	from := _own_write_end(h)
	if osync.keytree_reseed(&t.tree, from, tag, e.cfg.random) != .None {
		return
	}
	t.dirty = true
	_dirty_keys(e, sp, h.id, h.kind, h.scope, t)
	_touch(e)
}

@(private)
_members_follow :: proc(e: ^Engine, sp: ^Space) {
	if !sp.repl_on {
		return
	}
	ms := osync.members_scope(sp.id)
	osync.replicator_follow_segments(&sp.repl, &ms, osync.MEMBERS_STREAM, 0, true)
	_members_publish(e, sp)
}

@(private)
_members_seen :: proc(e: ^Engine, sp: ^Space, device: prim.Id, length: i64) {
	if device == e.self || !sp.repl_on {
		return
	}
	if length > sp.mem.want[device] {
		sp.mem.want[device] = length
	}
	ms := osync.members_scope(sp.id)
	osync.replicator_follow(&sp.repl, &ms, device, osync.MEMBERS_STREAM, 0, true)
}

@(private)
_members_remote :: proc(e: ^Engine, sp: ^Space, device: prim.Id, length: i64) {
	if device == e.self || !sp.repl_on {
		return
	}
	if length > sp.mem.want[device] {
		sp.mem.want[device] = length
	}
	defer if sp.mem.deferred && _members_ready(sp) {
		_members_recheck(e, sp)
	}
	seen := sp.mem.seen[device]
	if length <= seen {
		return
	}
	ms := osync.members_scope(sp.id)
	rep, aerr := osync.replicator_acquire(&sp.repl, &ms, device, osync.MEMBERS_STREAM, 0)
	if aerr != .None {
		return
	}
	defer osync.replicator_release(&sp.repl, &ms, device, osync.MEMBERS_STREAM, 0)
	end := journal.replica_length(rep)
	rd: journal.Reader
	journal.replica_reader(rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	pos := seen
	fresh := make([dynamic][]u8, context.temp_allocator)
	for pos < end {
		body, next, rerr := journal.record_at(&rd, pos)
		if rerr == .Missing {
			osync.replicator_want(&sp.repl, &ms, device, osync.MEMBERS_STREAM, 0, []journal.Range{{pos, end}})
			break
		}
		if rerr != .None {
			break
		}
		if len(body) > 0 && body[0] == osync.MEMBER_RECORD {
			c := make([]u8, len(body), context.temp_allocator)
			copy(c, body)
			append(&fresh, c)
		}
		pos = next
	}
	sp.mem.seen[device] = pos
	if len(fresh) > 0 {
		_members_ingest(e, sp, fresh[:])
	}
}

@(private)
_members_ingest :: proc(e: ^Engine, sp: ^Space, raws: [][]u8) {
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	defer osync.membership_destroy(&m)
	added := 0
	for raw in raws {
		if fresh, err := osync.membership_ingest(&m, raw); fresh && err == .None {
			_members_log_append(e, sp, raw)
			added += 1
		}
	}
	if added == 0 {
		return
	}
	sp.mem.records = len(m.records)
	_members_settle(e, sp, &m)
}

@(private)
_members_settle :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	if osync.membership_resolve(m) != .None {
		return
	}
	before := len(m.keys)
	op := osync.Opener{keyring = &e.keyring, self = e.identity}
	osync.membership_open(m, op)
	osync.membership_open_seals(m, op)
	if sp.mem.enroll != nil {
		akr := osync.account_keyring(sp.mem.enroll)
		osync.membership_open(m, osync.Opener{keyring = &akr, self = osync.account_identity(sp.mem.enroll)})
	}
	_members_adopt(e, sp, m)
	_members_maybe_commit(e, sp, m)
	_members_runner_watch(e, sp, m)
	_pool_reseal(e, sp, m)
	if sp.mem.me == .Runner {
		_lease_arm(e)
	}
	osync.membership_prune_paths(m)
	if len(m.keys) != before || m.have_naming {
		_members_secrets_store(e, sp, m)
	}
	if sp.mem.enroll != nil && sp.mem.current >= 0 && _members_ready(sp) {
		if _members_in_effective(m, e.identity.sign, _now_ms(e)) {
			osync.account_key_clear(sp.mem.enroll)
			free(sp.mem.enroll, e.allocator)
			sp.mem.enroll = nil
			_account_enrolled(e, sp)
		}
	}
	_emit(e, Event{kind = .Members_Changed, space = sp.id, length = i64(len(m.roster.members))})
	_touch(e)
}

@(private)
_members_maybe_commit :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	now := _now_ms(e)
	me := osync.roster_find(&m.roster, e.identity.sign)
	if me < 0 || !osync.member_active(&m.roster.members[me], now) || !osync.member_leaf_kind(m.roster.members[me].kind) || len(m.roster.members[me].scope) > 0 {
		return
	}
	if !m.have_naming {
		return
	}
	if !_members_ready(sp) {
		sp.mem.deferred = true
		return
	}
	sp.mem.deferred = false
	st, err := osync.membership_status(m, now)
	if err != .None {
		return
	}
	need := st.epoch < 0 || !st.eligible
	if !need && st.epoch >= 0 {
		t: osync.Ratchet_Tree
		if osync.roster_leaves(&m.roster, st.epoch, &t, context.temp_allocator) == .None {
			if _, in_tree := osync.tree_find_leaf(&t, e.identity.sign); !in_tree {
				need = true
			}
		}
	}
	if !need {
		return
	}
	raw, cerr := osync.membership_commit(m, osync.keyring_member_signer(&e.keyring), e.identity, now, now, true, e.cfg.random)
	if cerr != .None {
		_log(e, .Warn, "membership commit failed")
		return
	}
	_members_emit(e, sp, m, [][]u8{raw})
	_members_adopt(e, sp, m)
}

@(private)
_members_runner_watch :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	now := i64(_now_ms(e))
	for &x in m.roster.members {
		if x.kind != .Runner || x.method != .Pool || x.removed {
			continue
		}
		at := i64(x.added_hlc)
		if now - at > ANOMALY_WINDOW_MS {
			continue
		}
		known := false
		for t in sp.mem.enrolls {
			if t == at {
				known = true
			}
		}
		if known {
			continue
		}
		append(&sp.mem.enrolls, at)
		_emit(e, Event{kind = .Runner_Enrolled, space = sp.id, device = x.device, length = at})
	}
	recent := 0
	for i := 0; i < len(sp.mem.enrolls); {
		if now - sp.mem.enrolls[i] > ANOMALY_WINDOW_MS {
			unordered_remove(&sp.mem.enrolls, i)
			continue
		}
		recent += 1
		i += 1
	}
	if e.cfg.runner_alarm > 0 && recent > e.cfg.runner_alarm {
		_emit(e, Event{kind = .Runner_Anomaly, space = sp.id, length = i64(recent)})
	}
}

@(private)
_members_restore :: proc(e: ^Engine, sp: ^Space) {
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return
	}
	_members_adopt(e, sp, &m)
	sp.mem.loaded = true
}

@(private)
_member_creds_produce :: proc(data: rawptr, binding: []u8, out: ^[dynamic]u8) -> osync.Error {
	c := cast(^Member_Creds)data
	ps := make([][]u8, len(c.proofs), context.temp_allocator)
	copy(ps, c.proofs[:])
	return osync.member_credential(osync.Space_Id(c.space), &c.keyring, binding, ps, out)
}

@(private)
_member_credentials :: proc(sp: ^Space) -> osync.Credentials {
	return osync.Credentials{data = &sp.mem.creds, produce = _member_creds_produce}
}

@(private)
_members_proof :: proc(e: ^Engine, sp: ^Space, raw: []u8) {
	c := make([]u8, len(raw), e.allocator)
	copy(c, raw)
	append(&sp.mem.creds.proofs, c)
	if len(sp.mem.creds.proofs) > osync.MEMBER_PROOFS_MAX {
		delete(sp.mem.creds.proofs[0], e.allocator)
		ordered_remove(&sp.mem.creds.proofs, 0)
	}
}

@(private)
_members_change :: proc(e: ^Engine, sp: ^Space, build: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error), data: rawptr, commit: bool) -> Error {
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return .Corrupt
	}
	osync.membership_open(&m, osync.Opener{keyring = &e.keyring, self = e.identity})
	raws := make([dynamic][]u8, context.temp_allocator)
	before := len(m.raws)
	build(e, sp, &m, data) or_return
	for raw in m.raws[before:] {
		c := make([]u8, len(raw), context.temp_allocator)
		copy(c, raw)
		append(&raws, c)
	}
	if commit {
		now := _now_ms(e)
		craw, cerr := osync.membership_commit(&m, osync.keyring_member_signer(&e.keyring), e.identity, now, now, true, e.cfg.random)
		if cerr != .None {
			return _serr(cerr)
		}
		append(&raws, craw)
	}
	_members_emit(e, sp, &m, raws[:]) or_return
	sp.mem.records = len(m.records)
	_members_adopt(e, sp, &m)
	_members_secrets_store(e, sp, &m)
	_emit(e, Event{kind = .Members_Changed, space = sp.id, length = i64(len(m.roster.members))})
	_touch(e)
	return .None
}

space_members :: proc(e: ^Engine, space: prim.Id, allocator := context.allocator) -> (out: []Member_Info, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return nil, .Not_Found
	}
	t: osync.Ratchet_Tree
	has_tree := false
	if st, serr := osync.membership_status(&m, _now_ms(e)); serr == .None && st.epoch >= 0 {
		has_tree = osync.roster_leaves(&m.roster, st.epoch, &t, context.temp_allocator) == .None
	}
	list := make([dynamic]Member_Info, 0, len(m.roster.members), allocator)
	for &x in m.roster.members {
		info := Member_Info {
			device   = x.device,
			sign     = x.sign,
			box      = x.box,
			kind     = x.kind,
			role     = x.role,
			method   = x.method,
			person   = x.person,
			added_by = osync.device_id(x.added_by),
			added_at = x.added_hlc,
			expires  = x.expires,
			removed  = !osync.member_active(&x, _now_ms(e)),
			self     = x.device == e.self,
		}
		if has_tree {
			_, info.in_tree = osync.tree_find_leaf(&t, x.sign)
		}
		append(&list, info)
	}
	return list[:], .None
}

space_members_status :: proc(e: ^Engine, space: prim.Id) -> (s: Members_Status, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return s, .Not_Found
	}
	st := osync.membership_status(&m, _now_ms(e)) or_else osync.Membership_Status{epoch = -1}
	s.epoch = st.number
	s.eligible = st.eligible
	s.held = st.held
	s.records = len(m.records)
	now := _now_ms(e)
	for &x in m.roster.members {
		if osync.member_active(&x, now) {
			s.members += 1
		}
	}
	s.removed = sp.mem.removed
	s.revoked = sp.mem.revoked
	return s, .None
}

@(private)
Remove_Ctx :: struct {
	subject: osync.Public_Key,
}

member_remove :: proc(e: ^Engine, space: prim.Id, device: prim.Id) -> Error {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	resolved := osync.membership_resolve(&m) == .None
	idx := osync.roster_find_device(&m.roster, device) if resolved else -1
	subject: osync.Public_Key
	if idx >= 0 {
		subject = m.roster.members[idx].sign
	}
	osync.membership_destroy(&m)
	if idx < 0 {
		return .Not_Found
	}
	rc := Remove_Ctx{subject = subject}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
		c := (^Remove_Ctx)(data)
		raw, err := osync.membership_remove(m, osync.keyring_member_signer(&e.keyring), c.subject, _now_ms(e))
		return raw, _serr(err)
	}
	return _members_change(e, sp, build, &rc, device != e.self)
}

space_rotate :: proc(e: ^Engine, space: prim.Id) -> Error {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
		return nil, .None
	}
	return _members_change(e, sp, build, nil, true)
}

@(private)
Add_Ctx :: struct {
	body: osync.Add_Body,
	seal: bool,
	out:  []u8,
}

member_add :: proc(e: ^Engine, space: prim.Id, subject: osync.Identity, kind: osync.Member_Kind, role: osync.Role, method: osync.Enroll_Method, lease_ms: u64 = 0, allocator := context.allocator) -> (proof: []u8, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	ac := Add_Ctx {
		body = osync.Add_Body{sign = subject.sign, box = subject.box, kind = kind, role = role, method = method, lease_ms = lease_ms, history = true, person = e.account.sign},
		seal = true,
	}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
		c := (^Add_Ctx)(data)
		b := c.body
		if c.seal {
			if k := osync.membership_current(m, _now_ms(e)); k != nil {
				wrap := make([dynamic]u8, context.temp_allocator)
				id := osync.identity_of(b.sign, b.box)
				if osync.membership_bundle(m, k, id, &wrap, e.cfg.random) == .None {
					b.seal = wrap[:]
				}
			}
		}
		raw, err := osync.membership_add(m, osync.keyring_member_signer(&e.keyring), b, _now_ms(e))
		c.out = raw
		if err == .None {
			cp := make([]u8, len(raw), context.temp_allocator)
			copy(cp, raw)
			c.out = cp
		}
		return raw, _serr(err)
	}
	_members_change(e, sp, build, &ac, false) or_return
	proof = make([]u8, len(ac.out), allocator)
	copy(proof, ac.out)
	return proof, .None
}

@(private)
_own_write_end :: proc(h: ^Handle) -> i64 {
	if !h.w_open {
		return 0
	}
	switch h.kind {
	case .Conversation:
		return obj.writer_len(&h.cw.core)
	case .Map:
		return obj.writer_len(&h.mw.core)
	case .Text, .File_Tree:
		if h.hist != nil {
			return journal.journal_len(&h.hist.journal)
		}
	}
	return 0
}

@(private)
_space_ready :: proc(e: ^Engine, sp: ^Space) {
	if !sp.repl_on || sp.keyless {
		return
	}
	_card_publish(e, sp)
	_owned_follow(e, sp)
	_content_resume(e, sp)
	_catalog_follow(e, sp)
	_held_follow(e, sp)
	_held_scan(e, sp)
	_pending_republish(e, sp)
}

@(private)
_members_unlock_trees :: proc(e: ^Engine, sp: ^Space) {
	if !sp.open || !sp.repl_on {
		return
	}
	for k in _sorted_keys(sp.remote_trees) {
		rt := sp.remote_trees[k]
		if rt.locked && !rt.loaded {
			rt.locked = false
			_remote_tree_load(e, sp, rt)
		}
	}
}

@(private)
_members_ready :: proc(sp: ^Space) -> bool {
	if !sp.repl_on {
		return true
	}
	if !sp.mem.caught {
		return false
	}
	for d, l in sp.mem.want {
		if sp.mem.seen[d] < l {
			return false
		}
	}
	return true
}

@(private)
_members_caught_up :: proc(e: ^Engine, sp: ^Space) {
	sp.mem.caught = true
	if sp.mem.deferred && _members_ready(sp) {
		_members_recheck(e, sp)
	}
}

@(private)
_members_recheck :: proc(e: ^Engine, sp: ^Space) {
	sp.mem.deferred = false
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	defer osync.membership_destroy(&m)
	_members_settle(e, sp, &m)
}

@(private)
_members_in_effective :: proc(m: ^osync.Membership, sign: osync.Public_Key, now: u64) -> bool {
	st, err := osync.membership_status(m, now)
	if err != .None || st.epoch < 0 || !st.held {
		return false
	}
	t: osync.Ratchet_Tree
	if osync.roster_leaves(&m.roster, st.epoch, &t, context.temp_allocator) != .None {
		return false
	}
	_, ok := osync.tree_find_leaf(&t, sign)
	return ok
}

@(private)
_waiters_fail_space :: proc(e: ^Engine, space: prim.Id, err: Error) {
	for i := 0; i < len(e.waiters); {
		w := e.waiters[i]
		if w.space != space {
			i += 1
			continue
		}
		ordered_remove(&e.waiters, i)
		if w.cmd != nil {
			_cmd_fail(e, w.cmd, err)
		} else if w.ready.call != nil {
			context = _outer(e)
			w.ready.call(w.ready.data, e, err)
		}
		free(w, e.allocator)
	}
}

@(private)
_tree_maybe_stale :: proc(sp: ^Space, rt: ^Remote_Tree) -> bool {
	if sp.mode != .End_To_End {
		return false
	}
	newest: u32
	tag: osync.Epoch_Tag
	for x in sp.mem.epochs {
		if x.number >= newest {
			newest = x.number
			tag = x.tag
		}
	}
	if id, _, ok := _object_of_name(rt.name); ok {
		if g, found := sp.grant_epochs[id]; found {
			for x in g {
				if x.number >= newest {
					newest = x.number
					tag = x.tag
				}
			}
		}
	}
	zero: osync.Epoch_Tag
	return rt.tree.epoch != zero && tag != zero && rt.tree.epoch != tag
}

@(private)
_members_change_all :: proc(e: ^Engine, sp: ^Space, build: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error), data: rawptr, commit: bool) -> Error {
	return _members_change(e, sp, build, data, commit)
}

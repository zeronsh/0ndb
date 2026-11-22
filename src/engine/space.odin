package engine

import "core:crypto"
import "core:crypto/blake2b"
import "../journal"
import omap "../map"
import "../prim"
import osync "../sync"

@(private)
ROOT_PENDING :: 2
@(private)
ROOT_CARDS :: 3
@(private)
SPACE_VERSION :: 2
@(private)
CARD_STREAM :: osync.CARD_STREAM

Space_Info :: struct {
	id:           prim.Id,
	name:         string,
	relay:        string,
	relay_public: osync.Public_Key,
	mode:         osync.Encryption_Mode,
	open:         bool,
	connected:    bool,
	catalog:      prim.Id,
	relay_usage:  i64,
	relay_quota:  i64,
}

Space :: struct {
	e:            ^Engine,
	members_owed: bool,
	id:           prim.Id,
	link:         Link,
	name:         string,
	relay:        string,
	relay_public: osync.Public_Key,
	mode:         osync.Encryption_Mode,
	keys:         osync.Space,
	mem:          Space_Members,
	grant_epochs: map[prim.Id][dynamic]Space_Epoch,
	grantkeys_seen: map[[32]u8]i64,
	granted:      map[prim.Id]bool,
	carded:       map[prim.Id]bool,
	scope:        osync.Scope,
	open:         bool,
	repl:         osync.Replicator,
	repl_on:      bool,
	connected:    bool,
	creds:        osync.Space_Credentials,
	conn:         rawptr,
	catalog:      prim.Id,
	identities:   map[prim.Id]osync.Identity,
	held:         [dynamic]Held,
	remote_trees: map[osync.Stream_Id]^Remote_Tree,
	table:        omap.Table,
	table_open:   bool,
	card_ok:      bool,
	keyless:      bool,
	grants:       map[prim.Id]osync.Content_Key,
	grant_access: map[prim.Id]Access_Set,
	events:       [dynamic]Repl_Ev,
	needs:        [dynamic]Need,
	ckpts:        [dynamic]^Ckpt_Wait,
	card_scopes:  map[osync.Stream_Id]osync.Scope,
	card_len:     map[osync.Stream_Id]i64,
	card_relay:   map[prim.Id][dynamic]prim.Id,
	reopen:       prim.Timer,
	backoff:      i64,
	refused:      bool,
	draining:     bool,
	refusals:     int,
	admitted:     bool,
	attempt:      bool,
	offline:      bool,
}

@(private)
Held :: struct {
	device: prim.Id,
	name:   string,
}

space_create :: proc(e: ^Engine, name: string, relay := "", relay_public: osync.Public_Key = {}, mode := osync.Encryption_Mode.End_To_End) -> (id: prim.Id, err: Error) {
	context = context_for(e)
	relay, relay_public := relay, relay_public
	if len(relay) == 0 && e.account.have {
		relay = e.account.relay
		relay_public = e.account.relay_public
	}
	now := _now_ms(e)
	m: osync.Membership
	signer := osync.keyring_member_signer(&e.keyring)
	self := osync.Add_Body{box = e.identity.box, kind = .Device, person = e.account.sign, history = true}
	_, sid, gerr := osync.genesis_create(&m, signer, self, now, e.cfg.random, context.temp_allocator)
	if gerr != .None {
		return {}, _serr(gerr)
	}
	defer osync.membership_destroy(&m)
	zero: osync.Public_Key
	if e.account.sign != zero {
		b := osync.Add_Body{sign = e.account.sign, box = e.account.box, kind = .Account, role = .Owner, method = .Account, person = e.account.sign, history = true}
		if _, aerr := osync.membership_add(&m, signer, b, now); aerr != .None {
			return {}, _serr(aerr)
		}
		if e.account.pool != .Off && e.account.pool_sign != zero {
			pb := osync.Add_Body{sign = e.account.pool_sign, box = e.account.pool_box, kind = .Pool, role = .Member, method = .Pool, person = e.account.sign, history = true}
			if _, perr := osync.membership_add(&m, signer, pb, now); perr != .None {
				return {}, _serr(perr)
			}
		}
	}
	if _, cerr := osync.membership_commit(&m, signer, e.identity, now, now, true, e.cfg.random); cerr != .None {
		return {}, _serr(cerr)
	}
	if existing, ok := e.spaces[osync.Space_Id(sid)]; ok {
		return existing.id, .Exists
	}
	sp := _space_register(e, prim.Id(sid), name, relay, relay_public, mode, false) or_return
	raws := make([][]u8, len(m.raws), context.temp_allocator)
	copy(raws, m.raws[:])
	_members_emit(e, sp, &m, raws) or_return
	_members_secrets_store(e, sp, &m) or_return
	_proof_stage(e, sp, m.raws[0])
	_account_manifest_add(e, sp)
	_pool_notify(e, sp)
	_emit(e, Event{kind = .Space_Joined, space = sp.id})
	return sp.id, .None
}

space_join_enrollment :: proc(e: ^Engine, space: prim.Id, proof: []u8, name := "", relay := "", relay_public: osync.Public_Key = {}, mode := osync.Encryption_Mode.End_To_End) -> (id: prim.Id, err: Error) {
	context = context_for(e)
	sp, ok := e.spaces[space]
	if !ok {
		sp = _space_register(e, space, name, relay, relay_public, mode, false) or_return
		_emit(e, Event{kind = .Space_Joined, space = sp.id})
	}
	if len(proof) > 0 {
		_members_log_append(e, sp, proof) or_return
		_members_stream_append(e, sp, [][]u8{proof}) or_return
		_proof_stage(e, sp, proof)
		if sp.open {
			_members_proof(e, sp, proof)
			_members_ingest(e, sp, [][]u8{proof})
		}
	}
	if _leave_cancel(e, sp.id) {
		_account_manifest_add(e, sp)
	}
	return sp.id, .None
}

space_secret_naming :: proc(e: ^Engine, id: prim.Id) -> (naming: [32]u8, err: Error) {
	context = context_for(e)
	sp := _space_open(e, id) or_return
	if !sp.mem.have_naming {
		return naming, .Permission
	}
	return sp.mem.naming, .None
}

space_open :: proc(e: ^Engine, id: prim.Id) -> Error {
	context = context_for(e)
	_, err := _space_open(e, id)
	return err
}

space_close :: proc(e: ^Engine, id: prim.Id) {
	context = context_for(e)
	sp, ok := e.spaces[id]
	if !ok || !sp.open {
		return
	}
	_space_unload(e, sp)
}

space_set_relay :: proc(e: ^Engine, id: prim.Id, relay: string, relay_public: osync.Public_Key) -> Error {
	context = context_for(e)
	sp, ok := e.spaces[id]
	if !ok {
		return .Not_Found
	}
	was := sp.open
	if was {
		_space_unload(e, sp)
	}
	delete(sp.relay, e.allocator)
	sp.relay = _clone(relay, e.allocator) or_return
	sp.relay_public = relay_public
	sp.refused = false
	sp.backoff = 0
	_space_store(e, sp) or_return
	if was {
		_, err := _space_open(e, id)
		return err
	}
	return .None
}

space_info :: proc(e: ^Engine, id: prim.Id) -> (info: Space_Info, err: Error) {
	context = context_for(e)
	sp, ok := e.spaces[id]
	if !ok {
		return info, .Not_Found
	}
	return _space_info(sp), .None
}

space_list :: proc(e: ^Engine, allocator := context.allocator) -> []Space_Info {
	context = context_for(e)
	out := make([dynamic]Space_Info, 0, len(e.spaces), allocator)
	for id in _sorted_keys(e.spaces) {
		append(&out, _space_info(e.spaces[id]))
	}
	return out[:]
}

space_catalog :: proc(e: ^Engine, id: prim.Id) -> Object {
	context = context_for(e)
	return Object{id, _catalog_id(id)}
}

space_relay_account :: proc(e: ^Engine, id: prim.Id, refresh: bool) -> (st: osync.Relay_Space_Stats, seen: bool, err: Error) {
	context = context_for(e)
	sp, ok := e.spaces[id]
	if !ok {
		return {}, false, .Not_Found
	}
	if !sp.repl_on {
		return {}, false, .None
	}
	if refresh {
		osync.replicator_account(&sp.repl)
	}
	return sp.repl.account, sp.repl.accounted, .None
}

@(private)
_space_info :: proc(sp: ^Space) -> Space_Info {
	info := Space_Info{id = sp.id, name = sp.name, relay = sp.relay, relay_public = sp.relay_public, mode = sp.mode, open = sp.open, connected = sp.connected, catalog = sp.catalog}
	if sp.repl_on {
		info.relay_usage = sp.repl.usage
		info.relay_quota = sp.repl.quota
	}
	return info
}

@(private)
_catalog_id :: proc(space: prim.Id) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	s := space
	blake2b.update(&ctx, transmute([]u8)string("0ndb-catalog-v1"))
	blake2b.update(&ctx, s[:])
	blake2b.final(&ctx, id[:])
	id[6] = (id[6] & 0x0f) | 0x80
	return
}

@(private)
_space_register :: proc(e: ^Engine, id: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, mode: osync.Encryption_Mode, keyless: bool) -> (sp: ^Space, err: Error) {
	sp = new(Space, e.allocator)
	sp.e = e
	sp.id = id
	sp.mode = mode
	sp.keyless = keyless
	sp.catalog = _catalog_id(id)
	sp.name = _clone(name, e.allocator) or_return
	sp.relay = _clone(relay, e.allocator) or_return
	sp.relay_public = relay_public
	e.spaces[sp.id] = sp
	if err = _space_store(e, sp); err != .None {
		delete_key(&e.spaces, sp.id)
		_space_free(e, sp)
		return nil, err
	}
	return sp, .None
}

@(private)
_proof_stage :: proc(e: ^Engine, sp: ^Space, proof: []u8) {
	path, perr := _members_file(e, sp.id, "proofs")
	if perr != .None {
		return
	}
	old, _ := prim.read_file(e.vfs, path, context.temp_allocator)
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, ..old)
	hdr: [4]u8
	prim.put_u32le(hdr[:], u32(len(proof)))
	append(&buf, ..hdr[:])
	append(&buf, ..proof)
	prim.replace_atomic(e.vfs, path, buf[:])
}

@(private)
_lease_load :: proc(e: ^Engine, sp: ^Space) {
	path, perr := _members_file(e, sp.id, "lease")
	if perr != .None {
		return
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None || len(data) != osync.LEASE_TOKEN_LEN {
		return
	}
	t, ok := osync.lease_token_parse(data)
	if !ok || t.space != sp.id || t.expires <= _now_ms(e) {
		return
	}
	copy(sp.mem.creds.lease[:], data)
	sp.mem.creds.until = t.expires
}

@(private)
_lease_store :: proc(e: ^Engine, sp: ^Space, token: []u8) {
	if path, perr := _members_file(e, sp.id, "lease"); perr == .None {
		prim.replace_atomic(e.vfs, path, token)
	}
}

@(private)
_proofs_load :: proc(e: ^Engine, sp: ^Space) {
	path, perr := _members_file(e, sp.id, "proofs")
	if perr != .None {
		return
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None {
		return
	}
	pos := 0
	for pos + 4 <= len(data) {
		n := int(prim.get_u32le(data[pos:]))
		if pos + 4 + n > len(data) {
			break
		}
		_members_proof(e, sp, data[pos + 4:][:n])
		pos += 4 + n
	}
}

@(private)
_space_store :: proc(e: ^Engine, sp: ^Space) -> Error {
	buf := make([dynamic]u8, e.allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, SPACE_VERSION)
	prim.write_bool(&w, sp.keyless)
	prim.write_u8(&w, u8(sp.mode))
	prim.write_str(&w, sp.name)
	prim.write_str(&w, sp.relay)
	prim.write_raw(&w, sp.relay_public[:])
	if w.err != .None {
		delete(buf)
		return .No_Memory
	}
	if old, ok := e.reg.sstaged[sp.id]; ok {
		delete(old, e.allocator)
	}
	e.reg.sstaged[sp.id] = buf[:]
	_touch(e)
	return .None
}

@(private)
_spaces_load :: proc(e: ^Engine) -> Error {
	Acc :: struct {
		e:   ^Engine,
		err: Error,
	}
	acc := Acc{e = e}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		r := prim.reader(value)
		if prim.read_u8(&r) != SPACE_VERSION || len(key) != 16 {
			return true
		}
		sp := new(Space, a.e.allocator)
		sp.e = a.e
		copy(sp.id[:], key)
		sp.keyless = prim.read_bool(&r)
		m := prim.read_u8(&r)
		name := prim.read_str(&r)
		relay := prim.read_str(&r)
		prim.read_fixed(&r, sp.relay_public[:])
		if !prim.reader_ok(&r) || m > u8(max(osync.Encryption_Mode)) {
			free(sp, a.e.allocator)
			return true
		}
		sp.mode = osync.Encryption_Mode(m)
		sp.catalog = _catalog_id(sp.id)
		sp.name, _ = _clone(name, a.e.allocator)
		sp.relay, _ = _clone(relay, a.e.allocator)
		a.e.spaces[sp.id] = sp
		return true
	}
	if err := omap.db_scan(&e.reg.db, ROOT_SPACES, nil, nil, &acc, visit); err != .None {
		return _oerr(err)
	}
	return acc.err
}

@(private)
_space_open :: proc(e: ^Engine, id: prim.Id) -> (sp: ^Space, err: Error) {
	ok: bool
	sp, ok = e.spaces[id]
	if !ok {
		return nil, .Not_Found
	}
	if sp.open {
		return sp, .None
	}
	if sp.keyless && e.cfg.credentials.produce == nil {
		return nil, .Permission
	}
	_members_init(e, sp)
	_proofs_load(e, sp)
	_lease_load(e, sp)
	if !sp.keyless {
		_members_restore(e, sp)
	}
	sp.grant_epochs = make(map[prim.Id][dynamic]Space_Epoch, e.allocator)
	sp.grantkeys_seen = make(map[[32]u8]i64, e.allocator)
	sp.granted = make(map[prim.Id]bool, e.allocator)
	sp.carded = make(map[prim.Id]bool, e.allocator)
	sp.grants = make(map[prim.Id]osync.Content_Key, e.allocator)
	sp.grant_access = make(map[prim.Id]Access_Set, e.allocator)
	_grants_load(e, sp)
	sp.identities = make(map[prim.Id]osync.Identity, e.allocator)
	sp.held = make([dynamic]Held, e.allocator)
	sp.remote_trees = make(map[osync.Stream_Id]^Remote_Tree, e.allocator)
	sp.events = make([dynamic]Repl_Ev, e.allocator)
	sp.needs = make([dynamic]Need, e.allocator)
	sp.ckpts = make([dynamic]^Ckpt_Wait, e.allocator)
	sp.card_scopes = make(map[osync.Stream_Id]osync.Scope, e.allocator)
	sp.card_len = make(map[osync.Stream_Id]i64, e.allocator)
	sp.card_relay = make(map[prim.Id][dynamic]prim.Id, e.allocator)
	sp.identities[e.self] = e.identity
	sp.open = true
	_cards_load(e, sp)
	if !sp.refused && len(sp.relay) > 0 {
		if rerr := _repl_start(e, sp); rerr != .None && !_store_err(e, rerr) {
			_log(e, .Warn, "replicator start failed")
		}
	}
	return sp, .None
}

@(private)
_space_unload :: proc(e: ^Engine, sp: ^Space, discard := false) {
	if !discard && !e.closing && !e.in_tick && e.pk_open {
		flush(e)
		_space_drain(e, sp)
	}
	_handles_close_space(e, sp)
	_catalog_table_close(sp)
	if sp.repl_on {
		_repl_stop(e, sp)
	}
	for _, rt in sp.remote_trees {
		_remote_tree_free(e, rt)
	}
	delete(sp.remote_trees)
	for hd in sp.held {
		delete(hd.name, e.allocator)
	}
	delete(sp.held)
	for ev in sp.events {
		delete(ev.name, e.allocator)
	}
	delete(sp.events)
	for n in sp.needs {
		delete(n.name, e.allocator)
	}
	delete(sp.needs)
	for w in sp.ckpts {
		_ckpt_wait_free(e, w)
	}
	delete(sp.ckpts)
	for _, &sc in sp.card_scopes {
		osync.scope_clear(&sc)
	}
	delete(sp.card_scopes)
	delete(sp.card_len)
	for _, l in sp.card_relay {
		delete(l)
	}
	delete(sp.card_relay)
	delete(sp.identities)
	for _, &g in sp.grants {
		crypto.zero_explicit(&g, size_of(g))
	}
	delete(sp.grants)
	delete(sp.grant_access)
	for _, g in sp.grant_epochs {
		for &x in g {
			crypto.zero_explicit(&x.secret, size_of(x.secret))
		}
		delete(g)
	}
	delete(sp.grant_epochs)
	delete(sp.grantkeys_seen)
	delete(sp.granted)
	delete(sp.carded)
	_members_free(e, sp)
	osync.space_clear(&sp.keys)
	osync.scope_clear(&sp.scope)
	sp.open = false
}

@(private)
_space_free :: proc(e: ^Engine, sp: ^Space, discard := false) {
	if sp.open {
		_space_unload(e, sp, discard)
	}
	delete(sp.name, e.allocator)
	delete(sp.relay, e.allocator)
	free(sp, e.allocator)
}

@(private)
_spaces_close_all :: proc(e: ^Engine) {
	for _, sp in e.spaces {
		_space_free(e, sp)
	}
	clear(&e.spaces)
	clear(&e.links)
}

@(private)
_spaces_settle :: proc(e: ^Engine) {
	for _, sp in e.spaces {
		if !sp.open {
			continue
		}
		_catalog_table_close(sp)
		for k, rt in sp.remote_trees {
			if rt.refs > 0 {
				continue
			}
			if rt.loaded || !(rt.locked || rt.requested) {
				delete_key(&sp.remote_trees, k)
				_remote_tree_free(e, rt)
				continue
			}
			rt.requested = false
			rt.absent = false
		}
	}
}

@(private)
_object_scope :: proc(sp: ^Space, id: prim.Id) -> osync.Scope {
	if g, ok := sp.grants[id]; ok {
		return osync.scope_make(g, sp.mode)
	}
	if id == sp.catalog {
		return sp.scope
	}
	x := id
	k := osync.object_content_key(&sp.scope, x[:])
	sc := osync.scope_make(osync.Content_Key{key = k, epoch = 0}, sp.mode)
	crypto.zero_explicit(&k, size_of(k))
	return sc
}

@(private)
_card_path :: proc(e: ^Engine, sp: ^Space, allocator := context.temp_allocator) -> (string, Error) {
	h := prim.id_hex(sp.id)
	return _join(allocator, e.pack_root, "cards", string(h[:]))
}

@(private)
_card_publish :: proc(e: ^Engine, sp: ^Space) -> Error {
	if sp.card_ok || !sp.repl_on {
		return .None
	}
	if !sp.keyless {
		path := _card_path(e, sp) or_return
		_card_publish_in(e, sp, &sp.scope, path) or_return
	}
	for id in _sorted_keys(sp.grants) {
		_card_publish_object(e, sp, id) or_return
	}
	sp.card_ok = true
	return .None
}

@(private)
_card_publish_object :: proc(e: ^Engine, sp: ^Space, id: prim.Id) -> Error {
	if !sp.repl_on {
		return .None
	}
	if sp.keyless {
		if a, ok := sp.grant_access[id]; !ok || .Write not_in a {
			return .None
		}
	}
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	base := _card_path(e, sp) or_return
	oh := prim.id_hex(id)
	path := _join(context.temp_allocator, prim.dir_name(base), string(oh[:])) or_return
	return _card_publish_in(e, sp, &sc, path)
}

@(private)
_card_publish_in :: proc(e: ^Engine, sp: ^Space, scope: ^osync.Scope, path: string) -> Error {
	dir := prim.dir_name(path)
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	j: journal.Journal
	_jerr(journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator)) or_return
	if journal.journal_len(&j) == 0 {
		card, cerr := osync.keyring_card(&e.keyring)
		if cerr != .None {
			journal.journal_close(&j)
			return _serr(cerr)
		}
		rec := osync.card_record(card[:])
		if _, aerr := journal.journal_append(&j, rec[:]); aerr != .None {
			journal.journal_close(&j)
			return _jerr(aerr)
		}
		if cerr2 := journal.journal_commit(&j); cerr2 != .None {
			journal.journal_close(&j)
			return _jerr(cerr2)
		}
		journal.journal_close(&j)
		flush(e)
		_jerr(journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator)) or_return
	}
	n := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	return _serr(osync.replicator_publish(&sp.repl, scope, CARD_STREAM, 0, path, n))
}

@(private)
_card_want :: proc(e: ^Engine, sp: ^Space, device: prim.Id, name: string) {
	if !sp.keyless {
		osync.replicator_want_tail(&sp.repl, &sp.scope, device, CARD_STREAM, 0, 4096)
	}
	id, _, ok := _object_of_name(name)
	if !ok || id == sp.catalog {
		return
	}
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	_card_watch(e, sp, &sc, device, sp.keyless)
	rec, found, _ := _rec_get(e, id)
	if found {
		for m in rec.members {
			if m.device != device && m.device != e.self && m.device in sp.identities {
				_card_watch(e, sp, &sc, m.device, true)
			}
		}
	}
}

@(private)
_card_watch :: proc(e: ^Engine, sp: ^Space, sc: ^osync.Scope, device: prim.Id, follow: bool) {
	stream := osync.stream_id(sc, device, CARD_STREAM, 0)
	if _, have := sp.card_scopes[stream]; !have {
		sp.card_scopes[stream] = sc^
	}
	if follow {
		osync.replicator_follow(&sp.repl, sc, device, CARD_STREAM, 0, true)
	} else {
		osync.replicator_want_tail(&sp.repl, sc, device, CARD_STREAM, 0, 4096)
	}
}

@(private)
_card_key :: proc(sp: ^Space, device: prim.Id) -> (k: [32]u8) {
	a, b := sp.id, device
	copy(k[:16], a[:])
	copy(k[16:], b[:])
	return
}

@(private)
_cards_load :: proc(e: ^Engine, sp: ^Space) {
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		s := (^Space)(data)
		id, err := osync.card_verify(value)
		if err == .None && len(key) == 32 {
			dev: prim.Id
			copy(dev[:], key[16:])
			if dev == id.id {
				s.identities[dev] = id
			}
		}
		return true
	}
	a := sp.id
	omap.db_scan(&e.reg.db, ROOT_CARDS, a[:], a[:], sp, visit)
}

@(private)
_card_learn :: proc(e: ^Engine, sp: ^Space, device: prim.Id, stream: osync.Stream_Id) {
	scope := sp.scope
	if x, ok := sp.card_scopes[stream]; ok {
		scope = x
	} else if sp.keyless {
		return
	} else if device in sp.identities {
		return
	}
	defer osync.scope_clear(&scope)
	rep, aerr := osync.replicator_acquire(&sp.repl, &scope, device, CARD_STREAM, 0)
	if aerr != .None {
		return
	}
	defer osync.replicator_release(&sp.repl, &scope, device, CARD_STREAM, 0)
	n := journal.replica_length(rep)
	if n == 0 || sp.card_len[stream] >= n {
		return
	}
	rd: journal.Reader
	journal.replica_reader(rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	sid := osync.stream_id(&scope, device, CARD_STREAM, 0)
	key := osync.stream_key(&scope, sid)
	defer crypto.zero_explicit(&key, size_of(key))
	if sp.mode == .End_To_End {
		journal.reader_set_keys(&rd, osync.static_provider(&key))
	}
	pos: i64
	first := true
	for pos < n {
		body, next, rerr := journal.record_at(&rd, pos)
		if rerr != .None {
			break
		}
		body = osync.card_record_body(body)
		id, cerr := osync.card_verify(body)
		if first && (cerr != .None || id.id != device) {
			return
		}
		first = false
		pos = next
		if cerr != .None || id.id in sp.identities {
			continue
		}
		_card_store(e, sp, body)
		_card_known(e, sp, id.id)
	}
	sp.card_len[stream] = pos
}

@(private)
_card_known :: proc(e: ^Engine, sp: ^Space, device: prim.Id) {
	_touch(e)
	_held_release(e, sp, device)
	for h in e.lru {
		if h.sp != sp {
			continue
		}
		for sg in h.segs {
			if sg.device == device && !sg.in_view {
				_handle_refresh(h)
				_object_changed(e, sp.id, h.id, .Keys)
				break
			}
		}
	}
	_space_waits_wake(e, sp.id, .Catalog)
	if objs, ok := sp.card_relay[device]; ok {
		delete_key(&sp.card_relay, device)
		for id in objs {
			_card_relay(e, sp, id, device)
		}
		delete(objs)
	}
}

@(private)
_card_relay :: proc(e: ^Engine, sp: ^Space, id: prim.Id, device: prim.Id) {
	if !sp.repl_on || device == e.self || id == sp.catalog {
		return
	}
	base, berr := _card_path(e, sp)
	if berr != .None {
		return
	}
	oh := prim.id_hex(id)
	path, perr := _join(context.temp_allocator, prim.dir_name(base), string(oh[:]))
	if perr != .None || !prim.exists(e.vfs, path) {
		return
	}
	if _, known := sp.identities[device]; !known {
		list := sp.card_relay[device]
		for x in list {
			if x == id {
				return
			}
		}
		if list == nil {
			list = make([dynamic]prim.Id, e.allocator)
		}
		append(&list, id)
		sp.card_relay[device] = list
		if !sp.keyless {
			_need_add(e, sp, .Card, device, _seg_name(.Map, sp.catalog))
		}
		return
	}
	k := _card_key(sp, device)
	card, found, gerr := omap.db_get(&e.reg.db, ROOT_CARDS, k[:], context.temp_allocator)
	if gerr != .None || !found {
		return
	}
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator) != .None {
		return
	}
	r: journal.Reader
	journal.journal_reader(&j, &r, context.temp_allocator)
	end := journal.journal_durable_len(&j)
	pos: i64
	for pos < end {
		body, next, rerr := journal.record_at(&r, pos)
		if rerr != .None {
			break
		}
		if string(osync.card_record_body(body)) == string(card) {
			journal.reader_close(&r)
			journal.journal_close(&j)
			return
		}
		pos = next
	}
	journal.reader_close(&r)
	rec := osync.card_record(card)
	_, aerr := journal.journal_append(&j, rec[:])
	if aerr == .None {
		aerr = journal.journal_commit(&j)
	}
	journal.journal_close(&j)
	if aerr != .None {
		return
	}
	append(&e.card_pubs, Card_Pub{space = sp.id, object = id})
	_touch(e)
}

@(private)
_card_pub_durable :: proc(e: ^Engine, c: Card_Pub) {
	sp, ok := e.spaces[c.space]
	if !ok || !sp.repl_on {
		return
	}
	base, berr := _card_path(e, sp)
	if berr != .None {
		return
	}
	oh := prim.id_hex(c.object)
	path, perr := _join(context.temp_allocator, prim.dir_name(base), string(oh[:]))
	if perr != .None {
		return
	}
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator) != .None {
		return
	}
	n := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	sc := _object_scope(sp, c.object)
	defer osync.scope_clear(&sc)
	osync.replicator_publish(&sp.repl, &sc, CARD_STREAM, 0, path, n)
}

@(private)
_held_add :: proc(e: ^Engine, sp: ^Space, device: prim.Id, name: string) {
	for hd in sp.held {
		if hd.device == device && hd.name == name {
			return
		}
	}
	n, err := _clone(name, e.allocator)
	if err != .None {
		return
	}
	append(&sp.held, Held{device, n})
}

@(private)
_held_release :: proc(e: ^Engine, sp: ^Space, device: prim.Id) {
	take := make([dynamic]Held, context.temp_allocator)
	i := 0
	for i < len(sp.held) {
		hd := sp.held[i]
		if hd.device != device {
			i += 1
			continue
		}
		unordered_remove(&sp.held, i)
		append(&take, hd)
	}
	for hd in take {
		if sp.repl_on {
			seg := hd.name
			if t, derived := osync.derived_target(hd.name); derived {
				seg = t
			}
			if id, _, ok := _object_of_name(seg); ok {
				sc := _object_scope(sp, id)
				osync.replicator_want(&sp.repl, &sc, hd.device, hd.name, 0, nil)
				osync.scope_clear(&sc)
			}
		}
		delete(hd.name, e.allocator)
	}
}

@(private)
_pending_key :: proc(space: prim.Id, object: prim.Id) -> (k: [32]u8) {
	a, b := space, object
	copy(k[:16], a[:])
	copy(k[16:], b[:])
	return
}

@(private)
_pending_set :: proc(e: ^Engine, space: prim.Id, object: prim.Id, length: i64) {
	_rlog_pend_set(e, _pending_key(space, object), length)
}

@(private)
_pending_clear :: proc(e: ^Engine, space: prim.Id, object: prim.Id, length: i64) {
	_rlog_pend_clear(e, _pending_key(space, object), length)
}

@(private)
_pending_recover :: proc(e: ^Engine, sp: ^Space) {
	if !e.pk_open || !e.reg.unclean[sp.id] || !sp.repl_on || !_rlog_ready(e) || e.rlog.scanned[sp.id] {
		return
	}
	e.rlog.scanned[sp.id] = true
	defer _unclean_settle(e, sp)
	Own :: struct {
		id:   prim.Id,
		kind: Kind,
	}
	Acc :: struct {
		e:    ^Engine,
		sp:   ^Space,
		list: [dynamic]Own,
	}
	acc := Acc{e = e, sp = sp, list = make([dynamic]Own, context.temp_allocator)}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) != 16 {
			return true
		}
		rec, err := _rec_decode(value, context.temp_allocator)
		if err != .None || rec.space != a.sp.id || !rec.own {
			return true
		}
		x: prim.Id
		copy(x[:], key)
		append(&a.list, Own{x, rec.kind})
		return true
	}
	for k, v in e.reg.staged {
		x := k
		visit(&acc, x[:], v)
	}
	omap.db_scan(&e.reg.db, ROOT_OBJECTS, nil, nil, &acc, visit)
	for o in acc.list {
		k := _pending_key(sp.id, o.id)
		if _, known := e.rlog.pend[k]; known {
			continue
		}
		path: string
		perr: Error
		if o.kind == .Text || o.kind == .File_Tree {
			d := _obj_dir(e, o.id) or_continue
			path, perr = _join(context.temp_allocator, d, "hist", "fs.journal")
		} else {
			path, perr = _seg_path(e, o.id)
		}
		if perr != .None {
			continue
		}
		st, serr := prim.stat(e.vfs, path)
		if serr != .None {
			continue
		}
		sc := _object_scope(sp, o.id)
		defer osync.scope_clear(&sc)
		name := _seg_name(o.kind, o.id)
		floor, ferr := osync.replicator_floor(&sp.repl, &sc, name, 0)
		if ferr != .None {
			continue
		}
		if st.size <= floor {
			t, terr := _own_tree_get(e, sp, o.id, o.kind, &sc, false)
			if terr != .None {
				continue
			}
			unconfirmed := _keys_unconfirmed(e, sp, &sc, name, t)
			_own_tree_unref(e, t)
			if !unconfirmed {
				continue
			}
		}
		_rlog_pend_set(e, k, RLOG_UNKNOWN)
	}
}

@(private)
_pending_republish :: proc(e: ^Engine, sp: ^Space) {
	Acc :: struct {
		e:    ^Engine,
		sp:   ^Space,
		list: [dynamic]prim.Id,
	}
	acc := Acc{e = e, sp = sp, list = make([dynamic]prim.Id, context.temp_allocator)}
	_pending_recover(e, sp)
	if !_rlog_ready(e) {
		return
	}
	s := sp.id
	for kk in e.rlog.pend {
		k := kk
		if string(k[:16]) == string(s[:]) {
			id: prim.Id
			copy(id[:], k[16:])
			append(&acc.list, id)
		}
	}
	for id in acc.list {
		_pending_republish_one(e, sp, id)
	}
}

@(private)
_pending_republish_one :: proc(e: ^Engine, sp: ^Space, id: prim.Id) {
	rec, found, err := _rec_get(e, id)
	if err != .None || !found || !rec.own {
		return
	}
	h, herr := _handle_get(e, Object{sp.id, id}, rec.kind)
	if herr != .None {
		return
	}
	path, perr := _own_path(e, h)
	if perr != .None {
		return
	}
	length, lerr := _own_stream_len(e, id, rec.kind)
	if lerr != .None {
		return
	}
	if length > 0 {
		_dirty_add(e, h, path, length)
	}
	if cur, ok := &e.rlog.pend[_pending_key(sp.id, id)]; ok && cur^ == RLOG_UNKNOWN {
		cur^ = length
	}
	_dirty_keys(e, sp, id, rec.kind, h.scope, h.own_tree)
}

@(private)
_card_store :: proc(e: ^Engine, sp: ^Space, card: []u8) {
	id, err := osync.card_verify(card)
	if err != .None {
		return
	}
	if sp.open {
		sp.identities[id.id] = id
	}
	k := _card_key(sp, id.id)
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	if omap.txn_put(t, ROOT_CARDS, k[:], card) != .None {
		omap.txn_abort(t)
		_reg_fail(e, .Io)
		return
	}
	_reg_commit(e, t)
}

@(private)
ROOT_OWNED :: 7

@(private)
_owned_add :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind) {
	k := _pending_key(sp.id, id)
	if old, found, gerr := omap.db_get(&e.reg.db, ROOT_OWNED, k[:], context.temp_allocator); gerr == .None && found && len(old) > 0 && old[0] == u8(kind) {
		return
	}
	for o in e.reg.owned {
		if o.key == k {
			return
		}
	}
	append(&e.reg.owned, Owned_Pend{key = k, kind = kind})
	_touch(e)
}

@(private)
_owned_follow :: proc(e: ^Engine, sp: ^Space) {
	if !sp.repl_on {
		return
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		s := (^Space)(data)
		if len(key) != 32 || len(value) != 1 && len(value) != 9 && len(value) != 17 || value[0] < 1 || value[0] > u8(max(Kind)) {
			return true
		}
		id: prim.Id
		copy(id[:], key[16:])
		if id == s.catalog {
			return true
		}
		kind := Kind(value[0])
		sc := _object_scope(s, id)
		defer osync.scope_clear(&sc)
		osync.replicator_follow_segments(&s.repl, &sc, _seg_name(kind, id), 0, kind != .Conversation)
		return true
	}
	a := sp.id
	omap.db_scan(&e.reg.db, ROOT_OWNED, a[:], a[:], sp, visit)
}

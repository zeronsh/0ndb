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
SPACE_VERSION :: 1
@(private)
CARD_STREAM :: "card"

Space_Info :: struct {
	id:           prim.Id,
	name:         string,
	relay:        string,
	relay_public: osync.Public_Key,
	mode:         osync.Encryption_Mode,
	open:         bool,
	connected:    bool,
	catalog:      prim.Id,
}

Space :: struct {
	e:            ^Engine,
	id:           prim.Id,
	link:         Link,
	name:         string,
	relay:        string,
	relay_public: osync.Public_Key,
	mode:         osync.Encryption_Mode,
	wrapped:      [osync.WRAP_LEN]u8,
	keys:         osync.Space,
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
	events:       [dynamic]Repl_Ev,
	needs:        [dynamic]Need,
	ckpts:        [dynamic]^Ckpt_Wait,
	card_scopes:  map[osync.Stream_Id]osync.Scope,
}

@(private)
Held :: struct {
	device: prim.Id,
	name:   string,
}

space_create :: proc(e: ^Engine, name: string, relay := "", relay_public: osync.Public_Key = {}, mode := osync.Encryption_Mode.End_To_End) -> (id: prim.Id, err: Error) {
	s, serr := osync.space_new(e.cfg.random)
	if serr != .None {
		return {}, _serr(serr)
	}
	defer osync.space_clear(&s)
	return _space_add(e, s.secret, name, relay, relay_public, mode)
}

space_join :: proc(e: ^Engine, secret: osync.Secret, name := "", relay := "", relay_public: osync.Public_Key = {}, mode := osync.Encryption_Mode.End_To_End) -> (id: prim.Id, err: Error) {
	return _space_add(e, secret, name, relay, relay_public, mode)
}

space_join_pairing :: proc(e: ^Engine, code: string, name := "") -> (id: prim.Id, err: Error) {
	p, perr := osync.pairing_decode(code)
	if perr != .None {
		return {}, _serr(perr)
	}
	defer crypto.zero_explicit(&p.secret, size_of(p.secret))
	return _space_add(e, p.secret, name, osync.pairing_addr(&p), p.relay_public, .End_To_End)
}

space_pairing :: proc(e: ^Engine, id: prim.Id, allocator := context.allocator) -> (code: string, err: Error) {
	sp := _space_open(e, id) or_return
	if sp.keyless {
		return "", .Permission
	}
	p, perr := osync.pairing_make(&sp.keys, sp.relay, sp.relay_public)
	if perr != .None {
		return "", _serr(perr)
	}
	defer crypto.zero_explicit(&p.secret, size_of(p.secret))
	c, cerr := osync.pairing_encode(&p, allocator)
	return c, _serr(cerr)
}

space_secret :: proc(e: ^Engine, id: prim.Id) -> (secret: osync.Secret, err: Error) {
	sp := _space_open(e, id) or_return
	if sp.keyless {
		return {}, .Permission
	}
	return sp.keys.secret, .None
}

space_open :: proc(e: ^Engine, id: prim.Id) -> Error {
	_, err := _space_open(e, id)
	return err
}

space_close :: proc(e: ^Engine, id: prim.Id) {
	sp, ok := e.spaces[id]
	if !ok || !sp.open {
		return
	}
	_space_unload(e, sp)
}

space_set_relay :: proc(e: ^Engine, id: prim.Id, relay: string, relay_public: osync.Public_Key) -> Error {
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
	_space_store(e, sp) or_return
	if was {
		_, err := _space_open(e, id)
		return err
	}
	return .None
}

space_info :: proc(e: ^Engine, id: prim.Id) -> (info: Space_Info, err: Error) {
	sp, ok := e.spaces[id]
	if !ok {
		return info, .Not_Found
	}
	return _space_info(sp), .None
}

space_list :: proc(e: ^Engine, allocator := context.allocator) -> []Space_Info {
	out := make([dynamic]Space_Info, 0, len(e.spaces), allocator)
	for id in _sorted_keys(e.spaces) {
		append(&out, _space_info(e.spaces[id]))
	}
	return out[:]
}

space_catalog :: proc(e: ^Engine, id: prim.Id) -> Object {
	return Object{id, _catalog_id(id)}
}

@(private)
_space_info :: proc(sp: ^Space) -> Space_Info {
	return Space_Info{id = sp.id, name = sp.name, relay = sp.relay, relay_public = sp.relay_public, mode = sp.mode, open = sp.open, connected = sp.connected, catalog = sp.catalog}
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
_space_add :: proc(e: ^Engine, secret: osync.Secret, name: string, relay: string, relay_public: osync.Public_Key, mode: osync.Encryption_Mode) -> (id: prim.Id, err: Error) {
	s, serr := osync.space_from_secret(secret)
	if serr != .None {
		return {}, _serr(serr)
	}
	defer osync.space_clear(&s)
	if existing, ok := e.spaces[s.id]; ok {
		return existing.id, .Exists
	}
	sp := new(Space, e.allocator)
	sp.e = e
	sp.id = s.id
	sp.mode = mode
	sp.catalog = _catalog_id(s.id)
	sp.name = _clone(name, e.allocator) or_return
	sp.relay = _clone(relay, e.allocator) or_return
	sp.relay_public = relay_public
	ck := osync.Content_Key{key = s.secret}
	if werr := e.keyring.wrap(e.keyring.data, &e.identity, &ck, &sp.wrapped); werr != .None {
		crypto.zero_explicit(&ck, size_of(ck))
		_space_free(e, sp)
		return {}, _serr(werr)
	}
	crypto.zero_explicit(&ck, size_of(ck))
	e.spaces[sp.id] = sp
	if err = _space_store(e, sp); err != .None {
		delete_key(&e.spaces, sp.id)
		_space_free(e, sp)
		return {}, err
	}
	_emit(e, Event{kind = .Space_Joined, space = sp.id})
	return sp.id, .None
}

@(private)
_space_store :: proc(e: ^Engine, sp: ^Space) -> Error {
	buf := make([dynamic]u8, e.allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, SPACE_VERSION)
	prim.write_bool(&w, sp.keyless)
	prim.write_raw(&w, sp.wrapped[:])
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
		prim.read_fixed(&r, sp.wrapped[:])
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
	if !sp.keyless {
		ck: osync.Content_Key
		if uerr := e.keyring.unwrap(e.keyring.data, sp.wrapped[:], &ck); uerr != .None {
			return nil, _serr(uerr)
		}
		s, serr := osync.space_from_secret(ck.key)
		crypto.zero_explicit(&ck, size_of(ck))
		if serr != .None {
			return nil, _serr(serr)
		}
		if s.id != sp.id {
			osync.space_clear(&s)
			return nil, .Corrupt
		}
		sp.keys = s
		sp.scope = osync.space_scope(&sp.keys, sp.mode)
	} else if e.cfg.credentials.produce == nil {
		return nil, .Permission
	}
	sp.grants = make(map[prim.Id]osync.Content_Key, e.allocator)
	_grants_load(e, sp)
	sp.identities = make(map[prim.Id]osync.Identity, e.allocator)
	sp.held = make([dynamic]Held, e.allocator)
	sp.remote_trees = make(map[osync.Stream_Id]^Remote_Tree, e.allocator)
	sp.events = make([dynamic]Repl_Ev, e.allocator)
	sp.needs = make([dynamic]Need, e.allocator)
	sp.ckpts = make([dynamic]^Ckpt_Wait, e.allocator)
	sp.card_scopes = make(map[osync.Stream_Id]osync.Scope, e.allocator)
	sp.identities[e.self] = e.identity
	sp.open = true
	_cards_load(e, sp)
	if len(sp.relay) > 0 || e.cfg.transport.open != nil {
		if rerr := _repl_start(e, sp); rerr != .None {
			_log(e, .Warn, "replicator start failed")
		}
	}
	return sp, .None
}

@(private)
_space_unload :: proc(e: ^Engine, sp: ^Space) {
	for h in e.lru {
		if h.sp == sp {
			h.pins = 0
		}
	}
	_handles_sweep_space(e, sp)
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
	delete(sp.identities)
	for _, &g in sp.grants {
		crypto.zero_explicit(&g, size_of(g))
	}
	delete(sp.grants)
	osync.space_clear(&sp.keys)
	osync.scope_clear(&sp.scope)
	sp.open = false
}

@(private)
_space_free :: proc(e: ^Engine, sp: ^Space) {
	if sp.open {
		_space_unload(e, sp)
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
			if rt.refs == 0 {
				delete_key(&sp.remote_trees, k)
				_remote_tree_free(e, rt)
			}
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
		if _, aerr := journal.journal_append(&j, card[:]); aerr != .None {
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
	stream := osync.stream_id(&sc, device, CARD_STREAM, 0)
	if _, have := sp.card_scopes[stream]; !have {
		sp.card_scopes[stream] = sc
	}
	osync.replicator_want_tail(&sp.repl, &sc, device, CARD_STREAM, 0, 4096)
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
	if device in sp.identities {
		return
	}
	scope := sp.scope
	if x, ok := sp.card_scopes[stream]; ok {
		scope = x
	} else if sp.keyless {
		return
	}
	defer osync.scope_clear(&scope)
	rep, aerr := osync.replicator_acquire(&sp.repl, &scope, device, CARD_STREAM, 0)
	if aerr != .None {
		return
	}
	defer osync.replicator_release(&sp.repl, &scope, device, CARD_STREAM, 0)
	if journal.replica_length(rep) == 0 {
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
	body, _, rerr := journal.record_at(&rd, 0)
	if rerr != .None {
		return
	}
	id, cerr := osync.card_verify(body)
	if cerr != .None || id.id != device {
		return
	}
	sp.identities[device] = id
	k := _card_key(sp, device)
	t, terr := omap.txn_begin(&e.reg.db)
	if terr == .None {
		if omap.txn_put(t, ROOT_CARDS, k[:], body) == .None {
			omap.txn_commit(t)
		} else {
			omap.txn_abort(t)
		}
	}
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
			if id, _, ok := _object_of_name(hd.name); ok {
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
	k := _pending_key(space, object)
	if cur, ok := e.reg.pending[k]; ok && cur >= length {
		return
	}
	e.reg.pending[k] = length
	_touch(e)
}

@(private)
_pending_clear :: proc(e: ^Engine, space: prim.Id, object: prim.Id, length: i64) {
	k := _pending_key(space, object)
	if cur, ok := e.reg.pending[k]; ok {
		if cur >= 0 && cur <= length {
			e.reg.pending[k] = -1
			_touch(e)
		}
		return
	}
	v, found, gerr := omap.db_get(&e.reg.db, ROOT_PENDING, k[:], context.temp_allocator)
	if gerr != .None || !found || len(v) != 8 || i64(prim.get_u64le(v)) > length {
		return
	}
	e.reg.pending[k] = -1
	_touch(e)
}

@(private)
_pending_republish :: proc(e: ^Engine, sp: ^Space) {
	Acc :: struct {
		e:    ^Engine,
		sp:   ^Space,
		list: [dynamic]prim.Id,
	}
	acc := Acc{e = e, sp = sp, list = make([dynamic]prim.Id, context.temp_allocator)}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) == 32 {
			id: prim.Id
			copy(id[:], key[16:])
			append(&a.list, id)
		}
		return true
	}
	s := sp.id
	omap.db_scan(&e.reg.db, ROOT_PENDING, s[:], s[:], &acc, visit)
	for id in acc.list {
		rec, found, err := _rec_get(e, id)
		if err != .None || !found || !rec.own {
			continue
		}
		h, herr := _handle_get(e, Object{sp.id, id}, rec.kind)
		if herr != .None {
			continue
		}
		path := _own_path(e, h) or_continue
		length := _own_len(h)
		if length > 0 {
			_dirty_add(e, h, path, length)
		}
		_dirty_keys(e, sp, id, rec.kind, h.scope, h.own_tree)
	}
}

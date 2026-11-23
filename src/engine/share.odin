package engine

import "core:crypto"
import "core:slice"
import omap "../map"
import "../prim"
import osync "../sync"

@(private)
ROOT_GRANTS :: 5
SHARE_CARDS :: 16
SHARE_EPOCHS :: 32
SHARE_VERSION :: 3

Share_Epoch :: struct {
	tag:     osync.Epoch_Tag,
	order:   u32,
	view:    u32,
	wrapped: [osync.WRAP_LEN]u8,
}

@(private)
GRANT_ENTRY :: osync.EPOCH_TAG_LEN + 8 + osync.WRAP_LEN

@(private)
_grant_entry_put :: proc(buf: ^[dynamic]u8, tag: osync.Epoch_Tag, order, view: u32, wrapped: []u8) {
	t := tag
	append(buf, ..t[:])
	n: [8]u8
	prim.put_u32le(n[:4], order)
	prim.put_u32le(n[4:], view)
	append(buf, ..n[:])
	append(buf, ..wrapped)
}

Share :: struct {
	cards:   [SHARE_CARDS][osync.CARD_LEN]u8,
	ncards:  int,
	from:    prim.Id,
	access:  Access_Set,
	space:   prim.Id,
	object:  prim.Id,
	kind:    Kind,
	wrapped: [osync.WRAP_LEN]u8,
	epochs:  [SHARE_EPOCHS]Share_Epoch,
	nepochs: int,
}

object_key :: proc(e: ^Engine, o: Object) -> (key: osync.Content_Key, err: Error) {
	context = context_for(e)
	sp := _space_open(e, o.space) or_return
	if g, ok := _grant_get(e, sp, o.id); ok {
		return g, .None
	}
	if o.id == sp.catalog {
		return sp.scope.content, .None
	}
	x := o.id
	k := osync.object_content_key(&sp.scope, x[:])
	return osync.Content_Key{key = k, epoch = 0}, .None
}

share_object :: proc(e: ^Engine, o: Object, recipient: osync.Identity, access := Access_Set{.Read, .Write}) -> (s: Share, err: Error) {
	context = context_for(e)
	key := object_key(e, o) or_return
	defer crypto.zero_explicit(&key, size_of(key))
	rec, found := _rec_get(e, o.id) or_return
	if !found {
		return s, .Not_Found
	}
	r := recipient
	_serr(e.keyring.wrap(e.keyring.data, &r, &key, &s.wrapped)) or_return
	if sp, ok := e.spaces[o.space]; ok && sp.open {
		_share_epochs(e, sp, o.id, &r, &s) or_return
	}
	s.from = e.self
	s.access = access
	s.space = o.space
	s.object = o.id
	s.kind = rec.kind
	if card, cerr := osync.keyring_card(&e.keyring); cerr == .None {
		s.cards[0] = card
		s.ncards = 1
	}
	for m in rec.members {
		if s.ncards >= SHARE_CARDS {
			break
		}
		k := _card_key(e.spaces[o.space], m.device) if o.space in e.spaces else [32]u8{}
		v, hit, gerr := omap.db_get(&e.reg.db, ROOT_CARDS, k[:], context.temp_allocator)
		if gerr == .None && hit && len(v) == osync.CARD_LEN {
			copy(s.cards[s.ncards][:], v)
			s.ncards += 1
		}
	}
	if sp, ok := e.spaces[o.space]; ok && sp.open {
		_grant_member_add(e, sp, r, o.id, access)
		_card_publish_object(e, sp, o.id)
		_shared_follow(e, sp, o.id, rec.kind)
		for m in rec.members {
			_card_relay(e, sp, o.id, m.device)
		}
	}
	return s, .None
}

accept_share :: proc(e: ^Engine, share: Share) -> Error {
	context = context_for(e)
	s := share
	sp, ok := e.spaces[s.space]
	if !ok {
		return .Not_Found
	}
	key: osync.Content_Key
	_serr(e.keyring.unwrap(e.keyring.data, s.wrapped[:], &key)) or_return
	defer crypto.zero_explicit(&key, size_of(key))
	k := _grant_key(s.space, s.object)
	v: [2 + osync.WRAP_LEN]u8
	v[0] = u8(s.kind)
	v[1] = transmute(u8)s.access
	copy(v[2:], s.wrapped[:])
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	if err := omap.txn_put(t, ROOT_GRANTS, k[:], v[:]); err != .None {
		omap.txn_abort(t)
		return _oerr(err)
	}
	_reg_commit(e, t) or_return
	_share_epochs_store(e, sp, &s) or_return
	_space_unrefuse(e, sp)
	reauth := sp.keyless && sp.open && sp.repl_on && len(sp.grants) > 0 && !(s.object in sp.grants)
	if sp.open {
		sp.grants[s.object] = key
		sp.grant_access[s.object] = s.access
		_grant_epochs_load(e, sp, s.object)
		_card_publish_object(e, sp, s.object)
	}
	rec, found := _rec_get(e, s.object) or_return
	if !found {
		rec = Obj_Rec{space = s.space, kind = s.kind, members = make([dynamic]Member, context.temp_allocator)}
	}
	if s.from != e.self && _rec_member(&rec, s.from) < 0 {
		append(&rec.members, Member{device = s.from})
	}
	for i in 0 ..< min(s.ncards, SHARE_CARDS) {
		_card_store(e, sp, s.cards[i][:])
	}
	_rec_put(e, s.object, &rec) or_return
	if reauth {
		_space_unload(e, sp)
		_, oerr := _space_open(e, s.space)
		return oerr
	} else if sp.open {
		_shared_follow(e, sp, s.object, s.kind)
		_grantkeys_follow(e, sp, s.object)
	}
	return .None
}

@(private)
_grant_key :: proc(space: prim.Id, object: prim.Id) -> (k: [32]u8) {
	a, b := space, object
	copy(k[:16], a[:])
	copy(k[16:], b[:])
	return
}

@(private)
_grant_get :: proc(e: ^Engine, sp: ^Space, object: prim.Id) -> (key: osync.Content_Key, ok: bool) {
	if sp.open {
		key, ok = sp.grants[object]
	}
	return
}

@(private)
_grants_load :: proc(e: ^Engine, sp: ^Space) {
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		s := (^Space)(data)
		if len(key) != 32 || len(value) != 2 + osync.WRAP_LEN {
			return true
		}
		ck: osync.Content_Key
		if s.e.keyring.unwrap(s.e.keyring.data, value[2:], &ck) != .None {
			return true
		}
		id: prim.Id
		copy(id[:], key[16:])
		s.grants[id] = ck
		s.grant_access[id] = transmute(Access_Set)value[1]
		_grant_epochs_load(s.e, s, id)
		return true
	}
	a := sp.id
	omap.db_scan(&e.reg.db, ROOT_GRANTS, a[:], a[:], sp, visit)
}

space_join_shared :: proc(e: ^Engine, space: prim.Id, name := "", relay := "", relay_public: osync.Public_Key = {}) -> Error {
	context = context_for(e)
	if _, ok := e.spaces[space]; ok {
		return .Exists
	}
	sp := new(Space, e.allocator)
	sp.e = e
	sp.id = space
	sp.keyless = true
	sp.catalog = _catalog_id(space)
	sp.name = _clone(name, e.allocator) or_return
	sp.relay = _clone(relay, e.allocator) or_return
	sp.relay_public = relay_public
	e.spaces[space] = sp
	if err := _space_store(e, sp); err != .None {
		delete_key(&e.spaces, space)
		_space_free(e, sp)
		return err
	}
	return .None
}

@(private)
_shared_follow :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind) {
	if !sp.repl_on {
		return
	}
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	osync.replicator_follow_segments(&sp.repl, &sc, _seg_name(kind, id), 0, kind != .Conversation)
}

@(private)
_share_epochs :: proc(e: ^Engine, sp: ^Space, object: prim.Id, recipient: ^osync.Identity, s: ^Share) -> Error {
	cur := sp.mem.current
	has_cur := cur >= 0 && cur < len(sp.mem.epochs)
	room := SHARE_EPOCHS - 1 if has_cur else SHARE_EPOCHS
	pick := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< len(sp.mem.epochs) {
		if i != cur {
			append(&pick, i)
		}
	}
	for i in 1 ..< len(pick) {
		for j := i; j > 0 && _epoch_after(sp.mem.epochs[pick[j]], sp.mem.epochs[pick[j - 1]]); j -= 1 {
			pick[j], pick[j - 1] = pick[j - 1], pick[j]
		}
	}
	if len(pick) > room {
		resize(&pick, room)
	}
	slice.reverse(pick[:])
	if has_cur {
		append(&pick, cur)
	}
	for i in pick {
		ep := &sp.mem.epochs[i]
		o := object
		ck := osync.Content_Key{key = osync.object_epoch_key(&ep.secret, ep.number, o[:]), epoch = ep.number}
		err := e.keyring.wrap(e.keyring.data, recipient, &ck, &s.epochs[s.nepochs].wrapped)
		crypto.zero_explicit(&ck, size_of(ck))
		_serr(err) or_return
		s.epochs[s.nepochs].tag = ep.tag
		s.epochs[s.nepochs].order = ep.order
		s.epochs[s.nepochs].view = ep.view
		s.nepochs += 1
	}
	if g, ok := sp.grant_epochs[object]; ok {
		for x in g {
			if s.nepochs >= SHARE_EPOCHS {
				break
			}
			ck := osync.Content_Key{key = x.secret, epoch = x.number}
			err := e.keyring.wrap(e.keyring.data, recipient, &ck, &s.epochs[s.nepochs].wrapped)
			crypto.zero_explicit(&ck, size_of(ck))
			_serr(err) or_return
			s.epochs[s.nepochs].tag = x.tag
			s.epochs[s.nepochs].order = x.order
			s.epochs[s.nepochs].view = x.view
			s.nepochs += 1
		}
	}
	return .None
}

@(private)
_grant_epochs_path :: proc(e: ^Engine, space: prim.Id, object: prim.Id) -> (path: string, err: Error) {
	h := prim.id_hex(object)
	d := _members_dir(e, space) or_return
	return _join(context.temp_allocator, d, "grants", string(h[:]))
}

@(private)
_share_epochs_store :: proc(e: ^Engine, sp: ^Space, s: ^Share) -> Error {
	if s.nepochs == 0 {
		return .None
	}
	path := _grant_epochs_path(e, sp.id, s.object) or_return
	_perr(prim.mkdir_all(e.vfs, prim.dir_name(path), 0o700)) or_return
	buf := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< min(s.nepochs, SHARE_EPOCHS) {
		_grant_entry_put(&buf, s.epochs[i].tag, s.epochs[i].order, s.epochs[i].view, s.epochs[i].wrapped[:])
	}
	return _perr(prim.replace_atomic(e.vfs, path, buf[:]))
}

@(private)
_grant_epochs_load :: proc(e: ^Engine, sp: ^Space, object: prim.Id) {
	path, perr := _grant_epochs_path(e, sp.id, object)
	if perr != .None {
		return
	}
	data, err := prim.read_file(e.vfs, path, context.temp_allocator)
	if err != .None {
		return
	}
	list := make([dynamic]Space_Epoch, e.allocator)
	for pos := 0; pos + GRANT_ENTRY <= len(data); pos += GRANT_ENTRY {
		ck: osync.Content_Key
		if e.keyring.unwrap(e.keyring.data, data[pos + osync.EPOCH_TAG_LEN + 8:][:osync.WRAP_LEN], &ck) != .None {
			continue
		}
		x := Space_Epoch{number = ck.epoch, secret = ck.key}
		copy(x.tag[:], data[pos:][:osync.EPOCH_TAG_LEN])
		x.order = prim.get_u32le(data[pos + osync.EPOCH_TAG_LEN:])
		x.view = prim.get_u32le(data[pos + osync.EPOCH_TAG_LEN + 4:])
		crypto.zero_explicit(&ck, size_of(ck))
		merged := false
		for &y in list {
			if y.tag == x.tag {
				if x.view > y.view {
					y.order = x.order
					y.view = x.view
				}
				merged = true
				break
			}
		}
		if merged {
			crypto.zero_explicit(&x.secret, size_of(x.secret))
			continue
		}
		append(&list, x)
	}
	if old, ok := sp.grant_epochs[object]; ok {
		for &x in old {
			crypto.zero_explicit(&x.secret, size_of(x.secret))
		}
		delete(old)
	}
	sp.grant_epochs[object] = list
}

share_encode :: proc(s: ^Share, out: ^[dynamic]u8) -> Error {
	w := prim.writer(out)
	prim.write_u8(&w, SHARE_VERSION)
	prim.write_id(&w, s.from)
	prim.write_id(&w, s.space)
	prim.write_id(&w, s.object)
	prim.write_u8(&w, u8(s.kind))
	prim.write_raw(&w, s.wrapped[:])
	prim.write_uvarint(&w, u64(s.nepochs))
	for i in 0 ..< min(s.nepochs, SHARE_EPOCHS) {
		prim.write_raw(&w, s.epochs[i].tag[:])
		prim.write_u32le(&w, s.epochs[i].order)
		prim.write_u32le(&w, s.epochs[i].view)
		prim.write_raw(&w, s.epochs[i].wrapped[:])
	}
	return .No_Memory if w.err != .None else .None
}

share_decode :: proc(data: []u8, s: ^Share) -> Error {
	r := prim.reader(data)
	if prim.read_u8(&r) != SHARE_VERSION {
		return .Invalid
	}
	s.from = prim.read_id(&r)
	s.space = prim.read_id(&r)
	s.object = prim.read_id(&r)
	k := prim.read_u8(&r)
	prim.read_fixed(&r, s.wrapped[:])
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || k < 1 || k > u8(max(Kind)) || n > SHARE_EPOCHS {
		return .Invalid
	}
	s.kind = Kind(k)
	s.nepochs = int(n)
	for i in 0 ..< s.nepochs {
		prim.read_fixed(&r, s.epochs[i].tag[:])
		s.epochs[i].order = prim.read_u32le(&r)
		s.epochs[i].view = prim.read_u32le(&r)
		prim.read_fixed(&r, s.epochs[i].wrapped[:])
	}
	if !prim.reader_ok(&r) || !prim.reader_done(&r) {
		return .Invalid
	}
	return .None
}

package engine

import "core:crypto"
import "core:strings"
import "../journal"
import "../prim"
import osync "../sync"

@(private)
Grant_Add_Ctx :: struct {
	body: osync.Add_Body,
}

@(private)
Grant_Scope_Ctx :: struct {
	subject: osync.Public_Key,
	object:  prim.Id,
	add:     bool,
}

@(private)
_grant_scope_change :: proc(e: ^Engine, sp: ^Space, subject: osync.Public_Key, object: prim.Id, add: bool) -> Error {
	sc := Grant_Scope_Ctx{subject = subject, object = object, add = add}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
		c := (^Grant_Scope_Ctx)(data)
		raw, err := osync.membership_scope(m, osync.keyring_member_signer(&e.keyring), c.subject, c.object, c.add, _now_ms(e))
		return raw, _serr(err)
	}
	return _members_change(e, sp, build, &sc, !add)
}

@(private)
_grant_member_add :: proc(e: ^Engine, sp: ^Space, recipient: osync.Identity, object: prim.Id, access: Access_Set) {
	if sp.keyless || !sp.open || !sp.mem.member || sp.mem.removed || sp.mem.revoked {
		return
	}
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	present, guest, scoped := false, false, false
	if osync.membership_resolve(&m) == .None {
		if x := osync.roster_find(&m.roster, recipient.sign); x >= 0 && !m.roster.members[x].removed {
			present = true
			guest = m.roster.members[x].kind == .Guest
			for o in m.roster.members[x].scope {
				scoped ||= o == object
			}
		}
	}
	osync.membership_destroy(&m)
	if present {
		if guest && !scoped {
			_grant_scope_change(e, sp, recipient.sign, object, true)
		}
		return
	}
	scope := make([]prim.Id, 1, context.temp_allocator)
	scope[0] = object
	ac := Grant_Add_Ctx {
		body = osync.Add_Body {
			sign    = recipient.sign,
			box     = recipient.box,
			kind    = .Guest,
			role    = .Member if .Write in access else .Reader,
			method  = .Grant,
			person  = recipient.sign,
			history = true,
			scope   = scope,
		},
	}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
		c := (^Grant_Add_Ctx)(data)
		raw, err := osync.membership_add(m, osync.keyring_member_signer(&e.keyring), c.body, _now_ms(e))
		return raw, _serr(err)
	}
	_members_change(e, sp, build, &ac, false)
}

share_revoke :: proc(e: ^Engine, o: Object, grantee: prim.Id) -> Error {
	context = context_for(e)
	sp := _space_open(e, o.space) or_return
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	subject: osync.Public_Key
	scoped, last := false, false
	if osync.membership_resolve(&m) == .None {
		if x := osync.roster_find_device(&m.roster, grantee); x >= 0 && !m.roster.members[x].removed && m.roster.members[x].kind == .Guest {
			subject = m.roster.members[x].sign
			for obj in m.roster.members[x].scope {
				scoped ||= obj == o.id
			}
			last = len(m.roster.members[x].scope) == 1
		}
	}
	osync.membership_destroy(&m)
	if !scoped {
		return .Not_Found
	}
	if last {
		return member_remove(e, o.space, grantee)
	}
	return _grant_scope_change(e, sp, subject, o.id, false)
}

@(private)
_grantkeys_path :: proc(e: ^Engine, space: prim.Id, object: prim.Id) -> (path: string, err: Error) {
	h := prim.id_hex(object)
	d := _members_dir(e, space) or_return
	return _join(context.temp_allocator, d, "grantkeys", string(h[:]))
}

@(private)
_grants_rewrap :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	sp.mem.rewrap_wait = false
	if sp.keyless || !sp.repl_on {
		return
	}
	now := _now_ms(e)
	me := osync.roster_find(&m.roster, e.identity.sign)
	if me < 0 || !osync.member_active(&m.roster.members[me], now) || !osync.member_leaf_kind(m.roster.members[me].kind) || len(m.roster.members[me].scope) > 0 {
		return
	}
	cur := osync.membership_current(m, now)
	if cur == nil {
		return
	}
	ei := osync.roster_epoch(&m.roster, cur.id)
	if ei < 0 {
		return
	}
	t: osync.Ratchet_Tree
	if osync.roster_leaves(&m.roster, ei, &t, context.temp_allocator) != .None {
		return
	}
	if _, in_tree := osync.tree_find_leaf(&t, e.identity.sign); !in_tree {
		return
	}
	guests := false
	for &x in m.roster.members {
		if x.kind == .Guest && len(x.scope) > 0 && osync.member_active(&x, now) {
			guests = true
		}
	}
	if !guests {
		return
	}
	if !_members_elected(e, sp, m, &t, now) {
		sp.mem.rewrap_wait = true
		return
	}
	tag := osync.epoch_tag(cur.number, cur.id)
	for &x in m.roster.members {
		if x.kind != .Guest || len(x.scope) == 0 || !osync.member_active(&x, now) {
			continue
		}
		for object in x.scope {
			_grantkeys_wrap(e, sp, object, osync.identity_of(x.sign, x.box), tag, cur)
		}
	}
}

@(private)
_grantkeys_wrap :: proc(e: ^Engine, sp: ^Space, object: prim.Id, grantee: osync.Identity, tag: osync.Epoch_Tag, cur: ^osync.Epoch_Keys) {
	path, perr := _grantkeys_path(e, sp.id, object)
	if perr != .None || prim.mkdir_all(e.vfs, prim.dir_name(path), 0o700) != .None {
		return
	}
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator) != .None {
		return
	}
	defer journal.journal_close(&j)
	rd: journal.Reader
	if journal.reader_open(&rd, e.vfs, path, context.temp_allocator) == .None {
		pos := i64(0)
		for {
			body, next, err := journal.record_at(&rd, pos)
			if err != .None {
				break
			}
			pos = next
			gw: osync.Grant_Wrap
			if osync.grant_wrap_decode(body, &gw) == .None && gw.grantee == grantee.sign && gw.tag == tag {
				journal.reader_close(&rd)
				return
			}
		}
		journal.reader_close(&rd)
	}
	o := object
	key := osync.object_epoch_key(&cur.secret, cur.number, o[:])
	defer crypto.zero_explicit(&key, size_of(key))
	body := make([dynamic]u8, context.temp_allocator)
	if osync.grant_wrap_encode(grantee, object, tag, cur.number, key, &body, e.cfg.random) != .None {
		return
	}
	if _, aerr := journal.journal_append(&j, body[:]); aerr != .None {
		return
	}
	if journal.journal_commit(&j) != .None {
		return
	}
	sc := _object_scope(sp, object)
	defer osync.scope_clear(&sc)
	osync.replicator_publish(&sp.repl, &sc, osync.grant_keys_name(object), 0, path, journal.journal_durable_len(&j))
}

@(private)
_grantkeys_publish_all :: proc(e: ^Engine, sp: ^Space) {
	if sp.keyless || !sp.repl_on {
		return
	}
	d, derr := _members_dir(e, sp.id)
	if derr != .None {
		return
	}
	dir, jerr := _join(context.temp_allocator, d, "grantkeys")
	if jerr != .None {
		return
	}
	dh: prim.Dir
	if prim.dir_open(e.vfs, &dh, dir, context.temp_allocator) != .None {
		return
	}
	defer prim.dir_close(e.vfs, &dh)
	for {
		ent, more, nerr := prim.dir_next(e.vfs, &dh)
		if nerr != .None || !more {
			break
		}
		object, ok := prim.id_parse(ent.name)
		if !ok {
			continue
		}
		path, perr := _join(context.temp_allocator, dir, ent.name)
		if perr != .None {
			continue
		}
		j: journal.Journal
		if journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator) != .None {
			continue
		}
		n := journal.journal_durable_len(&j)
		journal.journal_close(&j)
		sc := _object_scope(sp, object)
		osync.replicator_publish(&sp.repl, &sc, osync.grant_keys_name(object), 0, path, n)
		osync.scope_clear(&sc)
	}
}

@(private)
_grantkeys_follow :: proc(e: ^Engine, sp: ^Space, object: prim.Id) {
	if !sp.repl_on || !(object in sp.grants) {
		return
	}
	sc := _object_scope(sp, object)
	defer osync.scope_clear(&sc)
	osync.replicator_follow_segments(&sp.repl, &sc, osync.grant_keys_name(object), 0, true)
}

@(private)
_grantkeys_object :: proc(name: string) -> (object: prim.Id, ok: bool) {
	if !strings.has_prefix(name, osync.GRANT_KEYS_STREAM) {
		return {}, false
	}
	return prim.id_parse(name[len(osync.GRANT_KEYS_STREAM):])
}

@(private)
_grantkeys_seen :: proc(e: ^Engine, sp: ^Space, device: prim.Id, object: prim.Id) {
	if !sp.repl_on || !(object in sp.grants) {
		return
	}
	sc := _object_scope(sp, object)
	defer osync.scope_clear(&sc)
	osync.replicator_follow(&sp.repl, &sc, osync.Device_Id(device), osync.grant_keys_name(object), 0, true)
}

@(private)
_grantkeys_read :: proc(e: ^Engine, sp: ^Space, device: prim.Id, object: prim.Id) {
	if !sp.repl_on || !(object in sp.grants) {
		return
	}
	sc := _object_scope(sp, object)
	defer osync.scope_clear(&sc)
	name := osync.grant_keys_name(object)
	dev := osync.Device_Id(device)
	rep, aerr := osync.replicator_acquire(&sp.repl, &sc, dev, name, 0)
	if aerr != .None {
		return
	}
	defer osync.replicator_release(&sp.repl, &sc, dev, name, 0)
	k := _grant_key(device, object)
	pos := sp.grantkeys_seen[k]
	end := journal.replica_length(rep)
	if pos >= end {
		return
	}
	rd: journal.Reader
	journal.replica_reader(rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	sid := osync.stream_id(&sc, dev, name, 0)
	skey := osync.stream_key(&sc, sid)
	defer crypto.zero_explicit(&skey, size_of(skey))
	if sc.mode == .End_To_End {
		journal.reader_set_keys(&rd, osync.static_provider(&skey))
	}
	gained := false
	for pos < end {
		body, next, err := journal.record_at(&rd, pos)
		if err == .Missing {
			osync.replicator_want(&sp.repl, &sc, dev, name, 0, []journal.Range{{pos, end}})
			break
		}
		if err != .None {
			break
		}
		pos = next
		gw: osync.Grant_Wrap
		if osync.grant_wrap_decode(body, &gw) != .None || gw.grantee != e.identity.sign {
			continue
		}
		known := false
		if g, ok := sp.grant_epochs[object]; ok {
			for x in g {
				if x.tag == gw.tag {
					known = true
				}
			}
		}
		if known {
			continue
		}
		number, key, oerr := osync.grant_wrap_open(&gw, &e.keyring, object)
		if oerr != .None {
			continue
		}
		if _grant_epoch_append(e, sp, object, gw.tag, number, key) {
			gained = true
		}
		crypto.zero_explicit(&key, size_of(key))
	}
	sp.grantkeys_seen[k] = pos
	if gained {
		_grant_epochs_load(e, sp, object)
		_members_unlock_trees(e, sp)
	}
}

@(private)
_grant_epoch_append :: proc(e: ^Engine, sp: ^Space, object: prim.Id, tag: osync.Epoch_Tag, number: u32, key: [32]u8) -> bool {
	path, perr := _grant_epochs_path(e, sp.id, object)
	if perr != .None || prim.mkdir_all(e.vfs, prim.dir_name(path), 0o700) != .None {
		return false
	}
	old, _ := prim.read_file(e.vfs, path, context.temp_allocator)
	ck := osync.Content_Key{key = key, epoch = number}
	defer crypto.zero_explicit(&ck, size_of(ck))
	wrapped: [osync.WRAP_LEN]u8
	self := e.identity
	if e.keyring.wrap(e.keyring.data, &self, &ck, &wrapped) != .None {
		return false
	}
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, ..old)
	t := tag
	append(&buf, ..t[:])
	append(&buf, ..wrapped[:])
	return prim.replace_atomic(e.vfs, path, buf[:]) == .None
}

@(private)
_grant_cards :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	if sp.keyless || !sp.repl_on {
		return
	}
	now := _now_ms(e)
	clear(&sp.granted)
	for &x in m.roster.members {
		if x.kind != .Guest || len(x.scope) == 0 || !osync.member_active(&x, now) {
			continue
		}
		for o in x.scope {
			sp.granted[o] = true
		}
	}
	for o in _sorted_keys(sp.granted) {
		if o in sp.carded {
			continue
		}
		if rec, found, err := _rec_get(e, o); err == .None && found && rec.own {
			_grant_card_written(e, sp, o)
		}
	}
}

@(private)
_grant_card_written :: proc(e: ^Engine, sp: ^Space, object: prim.Id) {
	if sp.keyless || !(object in sp.granted) || object in sp.carded {
		return
	}
	if _card_publish_object(e, sp, object) == .None {
		sp.carded[object] = true
	}
}

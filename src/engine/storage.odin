package engine

import "../convo"
import omap "../map"
import "../obj"
import "../prim"
import osync "../sync"

Storage_Class :: enum u8 {
	Default = 0,
	Device  = 1,
	Stored  = 2,
}

Storage_Mode :: enum u8 {
	Auto,
	Stored,
	Device_Until_Run,
	Device,
}

Storage_Policy :: struct {
	data:     rawptr,
	classify: proc(data: rawptr, e: ^Engine, space: prim.Id, object: prim.Id, kind: Kind, recorded: Storage_Class) -> Storage_Class,
	budget:   proc(data: rawptr, e: ^Engine, space: prim.Id) -> i64,
}

Storage_Stats :: struct {
	notes:        u64,
	promotions:   int,
	promoted:     i64,
	served_bytes: i64,
	peer_reads:   int,
	unavailable:  int,
}

@(private)
_storage_class :: proc(e: ^Engine, sp: ^Space, object: prim.Id, kind: Kind) -> Storage_Class {
	if prim.id_is_zero(object) || kind == .Map || object == sp.catalog {
		return .Stored
	}
	if e.cfg.storage == .Auto && e.cfg.storage_policy.classify == nil {
		return .Stored
	}
	recorded := _storage_recorded(e, sp, object)
	if e.cfg.storage_policy.classify != nil {
		c: Storage_Class
		{
			context = _outer(e)
			c = e.cfg.storage_policy.classify(e.cfg.storage_policy.data, e, sp.id, object, kind, recorded)
		}
		return .Stored if c == .Default else c
	}
	switch e.cfg.storage {
	case .Auto, .Stored:
		return .Stored
	case .Device_Until_Run, .Device:
		return .Stored if recorded == .Stored || _promo_marked(e, sp.id, object) else .Device
	}
	return .Stored
}

@(private)
_storage_recorded :: proc(e: ^Engine, sp: ^Space, object: prim.Id) -> Storage_Class {
	h, err := _catalog_handle(e, sp)
	if err != .None {
		return .Default
	}
	c, found, gerr := omap.catalog_get(&h.table, object, context.temp_allocator)
	if gerr != .None || !found || c.storage > u8(max(Storage_Class)) {
		return .Default
	}
	return Storage_Class(c.storage)
}

storage_class :: proc(e: ^Engine, o: Object) -> (class: Storage_Class, err: Error) {
	context = context_for(e)
	sp := _space_open(e, o.space) or_return
	kind := Kind.Conversation
	if rec, found, _ := _rec_get(e, o.id); found {
		kind = rec.kind
	}
	return _storage_class(e, sp, o.id, kind), .None
}

availability :: proc(e: ^Engine, o: Object, allocator := context.allocator) -> (holders: []prim.Id, unavailable: bool) {
	context = context_for(e)
	list, ok := e.unavailable[o.id]
	if !ok || len(list) == 0 {
		return nil, false
	}
	out := make([]prim.Id, len(list), allocator)
	copy(out, list[:])
	return out, true
}

storage_stats :: proc(e: ^Engine) -> (st: Storage_Stats) {
	context = context_for(e)
	for _, sp in e.spaces {
		if !sp.repl_on {
			continue
		}
		n, up := osync.replicator_promotions(&sp.repl)
		st.promotions += n
		st.promoted += up
		st.served_bytes += sp.repl.served_bytes
	}
	st.unavailable = len(e.unavailable)
	return
}

@(private)
_promo_key :: proc(space, object: prim.Id) -> (k: [33]u8) {
	p := _pending_key(space, object)
	copy(k[:32], p[:])
	k[32] = 'p'
	return
}

@(private)
_promo_mark :: proc(e: ^Engine, space, object: prim.Id, from: i64, on: bool) {
	k := _promo_key(space, object)
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	v: [8]u8
	prim.put_u64le(v[:], u64(max(from, 0)))
	err: omap.Error
	if on {
		err = omap.txn_put(t, ROOT_OWNED, k[:], v[:])
	} else {
		_, err = omap.txn_delete(t, ROOT_OWNED, k[:])
	}
	if err != .None {
		omap.txn_abort(t)
		_reg_fail(e, .Io)
		return
	}
	_reg_commit(e, t)
}

@(private)
_promo_marked :: proc(e: ^Engine, space, object: prim.Id) -> bool {
	k := _promo_key(space, object)
	_, found, err := omap.db_get(&e.reg.db, ROOT_OWNED, k[:], context.temp_allocator)
	return err == .None && found
}

@(private)
_promo_resume :: proc(e: ^Engine, sp: ^Space) {
	Acc :: struct {
		ids:   [dynamic]prim.Id,
		froms: [dynamic]i64,
	}
	acc := Acc{ids = make([dynamic]prim.Id, context.temp_allocator), froms = make([dynamic]i64, context.temp_allocator)}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) == 33 && key[32] == 'p' && len(value) == 8 {
			id: prim.Id
			copy(id[:], key[16:32])
			append(&a.ids, id)
			append(&a.froms, i64(min(prim.get_u64le(value), u64(max(i64)))))
		}
		return true
	}
	s := sp.id
	omap.db_scan(&e.reg.db, ROOT_OWNED, s[:], s[:], &acc, visit)
	for id, i in acc.ids {
		object_promote(e, Object{sp.id, id}, acc.froms[i])
	}
}

@(private)
_promo_settled :: proc(e: ^Engine, sp: ^Space, object: prim.Id, kind: Kind) {
	sc := _object_scope(sp, object)
	defer osync.scope_clear(&sc)
	if osync.replicator_promoting(&sp.repl, &sc, _seg_name(kind, object)) {
		return
	}
	if _storage_recorded(e, sp, object) != .Stored {
		return
	}
	_promo_mark(e, sp.id, object, 0, false)
}

object_promote :: proc(e: ^Engine, o: Object, from: i64 = 0) -> Error {
	context = context_for(e)
	return _promote(e, o, from, nil)
}

object_promote_run :: proc(e: ^Engine, o: Object, msg: Rid = {}) -> Error {
	context = context_for(e)
	rec, found := _rec_get(e, o.id) or_return
	if !found {
		return .Not_Found
	}
	froms := make(map[prim.Id]i64, context.temp_allocator)
	#partial switch rec.kind {
	case .Conversation:
		if !obj.rid_none(msg) && _convo_needed(e, o, msg, &froms) != .None {
			clear(&froms)
		}
		for m in rec.members {
			if _, has := froms[m.device]; !has {
				froms[m.device] = max(i64)
			}
		}
		if _, has := froms[e.self]; !has {
			froms[e.self] = max(i64)
		}
	case .File_Tree, .Text:
		if h, ok := e.handles[o.id]; ok && h.w_open && h.hist != nil && h.sp.repl_on {
			n := _own_len(h)
			last, prev, had := _ckpt_get(e, h.id)
			if !had || last < n {
				if _checkpoint_write(e, h, n, prev, had) == .None {
					last = n
				}
			}
			if l2, _, ok2 := _ckpt_get(e, h.id); ok2 && l2 > 0 {
				froms[e.self] = l2
				_content_mark_put(e, h.sp.id, h.id, h.kind, min(_content_mark_get(e, h.sp, h.id), l2))
			}
		}
	}
	err := _promote(e, o, 0, froms)
	if err == .None && (rec.kind == .File_Tree || rec.kind == .Text) {
		_catalog_flush(e)
		if h, ok := e.handles[o.id]; ok && h.w_open {
			if mark, has := froms[e.self]; has {
				_content_mark_put(e, h.sp.id, h.id, h.kind, mark)
			}
			_content_publish(e, h)
		}
	}
	return err
}

@(private)
_convo_needed :: proc(e: ^Engine, o: Object, msg: Rid, froms: ^map[prim.Id]i64) -> Error {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None {
		return .Missing
	}
	pos := convo.Position{msg = msg}
	for _ in 0 ..< 1 << 16 {
		pg, perr := convo.page(&h.view, &t, pos, 256, context.temp_allocator)
		if perr != .None {
			return .Missing
		}
		for m in pg.messages {
			cur, has := froms[m.id.seg]
			if !has || m.id.off < cur {
				froms[m.id.seg] = m.id.off
			}
		}
		if !pg.more || len(pg.messages) == 0 {
			return .None
		}
		pos = pg.next
	}
	return .None
}

@(private)
_promote_from :: proc(froms: map[prim.Id]i64, device: prim.Id, from: i64, length: i64) -> i64 {
	if froms == nil {
		return from
	}
	f, has := froms[device]
	if !has {
		return 0
	}
	if f == max(i64) {
		return max(length - 1, 0)
	}
	return f
}

@(private)
_promote :: proc(e: ^Engine, o: Object, from: i64, froms: map[prim.Id]i64) -> Error {
	sp := _space_open(e, o.space) or_return
	rec, found := _rec_get(e, o.id) or_return
	if !found {
		return .Not_Found
	}
	if rec.kind == .Map {
		return .None
	}
	u := _catalog_q(e, o.space, o.id, rec.kind)
	if u != nil {
		u.set += {.Storage}
		u.storage = .Stored
	}
	_promo_mark(e, o.space, o.id, from, true)
	if !sp.repl_on {
		return .None
	}
	sc := _object_scope(sp, o.id)
	defer osync.scope_clear(&sc)
	name := _seg_name(rec.kind, o.id)
	if h, ok := e.handles[o.id]; ok && h.w_open {
		path := _own_path(e, h) or_return
		n := _own_len(h)
		if n > 0 {
			var_tree: ^osync.Key_Tree
			if h.own_tree != nil {
				var_tree = &h.own_tree.tree
			}
			if perr := osync.replicator_publish(&sp.repl, &sc, name, 0, path, n, var_tree, false); perr != .None {
				_store_err(e, _serr(perr))
			}
		}
	}
	if path, perr := _own_path_of(e, o.id, rec.kind); perr == .None && prim.exists(e.vfs, path) {
		own_len: i64
		if h, ok := e.handles[o.id]; ok && h.w_open {
			own_len = _own_len(h)
		}
		_serr(osync.replicator_promote(&sp.repl, &sc, e.self, name, 0, path, _promote_from(froms, e.self, from, own_len))) or_return
	}
	for m in rec.members {
		if m.device == e.self {
			continue
		}
		rl := osync.replicator_relay_length(&sp.repl, &sc, osync.Device_Id(m.device), name, 0)
		_serr(osync.replicator_promote(&sp.repl, &sc, m.device, name, 0, "", _promote_from(froms, m.device, from, rl))) or_return
	}
	_touch(e)
	return .None
}

@(private)
_own_path_of :: proc(e: ^Engine, id: prim.Id, kind: Kind) -> (path: string, err: Error) {
	if kind == .Text || kind == .File_Tree {
		d := _obj_dir(e, id, context.temp_allocator) or_return
		return _join(context.temp_allocator, d, "hist", "fs.journal")
	}
	return _seg_path(e, id)
}

@(private)
_repl_seal :: proc(user: rawptr, name: string, id: osync.Stream_Id, data: []u8, off: i64) -> osync.Error {
	sp := (^Space)(user)
	e := sp.e
	obj_id, kind, ok := _object_of_name(name)
	if !ok {
		return .Invalid
	}
	sc := _object_scope(sp, obj_id)
	defer osync.scope_clear(&sc)
	if sc.mode == .Transparent {
		return .None
	}
	t, err := _own_tree_get(e, sp, obj_id, kind, &sc, false)
	if err != .None {
		return .Not_Found if err == .Not_Found else .Io
	}
	defer _own_tree_unref(e, t)
	return osync.keytree_seal_range(&t.tree, data, off)
}

@(private)
_unavailable_note :: proc(e: ^Engine, sp: ^Space, ev: ^Repl_Ev) {
	id, _, ok := _object_of_name(ev.name)
	if !ok {
		return
	}
	list, has := e.unavailable[id]
	if !has {
		list = make([dynamic]prim.Id, e.allocator)
	}
	clear(&list)
	for d in ev.holders {
		append(&list, d)
	}
	e.unavailable[id] = list
	for d in ev.holders {
		_emit(e, Event{kind = .Unavailable, space = sp.id, object = id, device = d, length = ev.length})
	}
}

@(private)
_unavailable_clear :: proc(e: ^Engine, sp: ^Space, id: prim.Id) {
	list, has := e.unavailable[id]
	if !has {
		return
	}
	delete(list)
	delete_key(&e.unavailable, id)
	_emit(e, Event{kind = .Available, space = sp.id, object = id})
}

@(private)
_unavailable_destroy :: proc(e: ^Engine) {
	for _, list in e.unavailable {
		delete(list)
	}
	delete(e.unavailable)
}

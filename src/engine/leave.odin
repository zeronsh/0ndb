package engine

import "core:crypto"
import omap "../map"
import "../journal"
import "../prim"
import "../search"
import osync "../sync"

@(private)
LEFT_FILE :: "left"
@(private)
LEFT_VERSION :: u8(1)
@(private)
LEFT_LEAVING :: u8(1)
@(private)
LEFT_DONE :: u8(2)

@(private)
Left_Entry :: struct {
	space:  prim.Id,
	state:  u8,
	target: i64,
}

Leave_Result :: struct {
	removed: int,
	skipped: int,
}

@(private)
Leave_Ctx :: struct {
	subjects: [dynamic]osync.Public_Key,
}

space_leave :: proc(e: ^Engine, space: prim.Id, only_device := false) -> (res: Leave_Result, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	if sp.keyless {
		return res, .Unsupported
	}
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return res, .Corrupt
	}
	now := _now_ms(e)
	me := osync.roster_find(&m.roster, e.identity.sign)
	if me < 0 || !osync.member_active(&m.roster.members[me], now) {
		return res, .Not_Found
	}
	mine := m.roster.members[me]
	lc := Leave_Ctx{subjects = make([dynamic]osync.Public_Key, context.temp_allocator)}
	if !only_device {
		for &x in m.roster.members {
			if x.sign == mine.sign || x.kind != .Device || !_leave_mine(e, &x) || !osync.member_active(&x, now) {
				continue
			}
			if mine.role == .Owner || (mine.role == .Admin && x.role != .Owner) {
				append(&lc.subjects, x.sign)
			} else {
				res.skipped += 1
			}
		}
	}
	append(&lc.subjects, mine.sign)
	owners := 0
	for &x in m.roster.members {
		if x.role != .Owner || !osync.member_active(&x, now) {
			continue
		}
		gone := !only_device && (_leave_mine(e, &x) || (e.account.have && x.sign == e.account.sign))
		for s in lc.subjects {
			if s == x.sign {
				gone = true
			}
		}
		if !gone {
			owners += 1
		}
	}
	if owners == 0 {
		return res, .Permission
	}
	build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
		c := (^Leave_Ctx)(data)
		for s in c.subjects {
			if _, rerr := osync.membership_remove(m, osync.keyring_member_signer(&e.keyring), s, _now_ms(e)); rerr != .None {
				return nil, _serr(rerr)
			}
		}
		return nil, .None
	}
	_members_change(e, sp, build, &lc, false) or_return
	res.removed = len(lc.subjects)
	_left_set(e, Left_Entry{space = space, state = LEFT_LEAVING, target = _members_stream_len(e, sp)}) or_return
	if !only_device {
		_account_manifest_leave(e, sp)
	}
	_leave_check(e, sp)
	_touch(e)
	return res, .None
}

@(private)
_leave_mine :: proc(e: ^Engine, x: ^osync.Member) -> bool {
	if !e.account.have || x.person != e.account.sign {
		return false
	}
	return x.method == .Account || x.method == .Genesis || x.method == .Recovery
}

space_left :: proc(e: ^Engine, space: prim.Id) -> bool {
	context = context_for(e)
	_, ok := _left_get(e, space)
	return ok
}

@(private)
_members_stream_len :: proc(e: ^Engine, sp: ^Space) -> i64 {
	path, perr := _members_file(e, sp.id, "stream")
	if perr != .None {
		return 0
	}
	j: journal.Journal
	if journal.journal_open(&j, e.vfs, path, {}, context.temp_allocator) != .None {
		return 0
	}
	n := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	return n
}

@(private)
_leave_check :: proc(e: ^Engine, sp: ^Space) {
	ent, ok := _left_get(e, sp.id)
	if !ok || ent.state != LEFT_LEAVING {
		return
	}
	if sp.repl_on {
		ms := osync.members_scope(sp.id)
		if floor, ferr := osync.replicator_floor(&sp.repl, &ms, osync.MEMBERS_STREAM, 0); ferr != .None || floor < ent.target {
			return
		}
	} else if len(sp.relay) > 0 {
		return
	}
	for x in e.leave_ready {
		if x == sp.id {
			return
		}
	}
	append(&e.leave_ready, sp.id)
	_touch(e)
}

@(private)
_leave_uploaded :: proc(e: ^Engine, sp: ^Space, length: i64) {
	ent, ok := _left_get(e, sp.id)
	if ok && ent.state == LEFT_LEAVING && length >= ent.target {
		_leave_check(e, sp)
	}
}

@(private)
_leave_refused :: proc(e: ^Engine, sp: ^Space) -> bool {
	ent, ok := _left_get(e, sp.id)
	if !ok || ent.state != LEFT_LEAVING {
		return false
	}
	for x in e.leave_ready {
		if x == sp.id {
			return true
		}
	}
	append(&e.leave_ready, sp.id)
	_touch(e)
	return true
}

@(private)
_leave_resume :: proc(e: ^Engine) {
	for ent in _left_load(e) {
		if ent.state != LEFT_LEAVING {
			continue
		}
		if _, ok := e.spaces[ent.space]; !ok {
			continue
		}
		if sp, err := _space_open(e, ent.space); err == .None {
			_leave_check(e, sp)
		}
	}
}

@(private)
_leave_step :: proc(e: ^Engine) {
	for id in e.leave_ready {
		if sp, ok := e.spaces[id]; ok && sp.repl_on && _space_drain(e, sp) {
			_repl_stop(e, sp)
		}
	}
	if len(e.leave_ready) == 0 || len(e.batches) > 0 || len(e.dirty) > 0 {
		return
	}
	ids := make([]prim.Id, len(e.leave_ready), context.temp_allocator)
	copy(ids, e.leave_ready[:])
	clear(&e.leave_ready)
	for id in ids {
		if sp, ok := e.spaces[id]; ok {
			if err := _space_erase(e, sp); err != .None {
				_log(e, .Warn, "erasing a left space failed; retried on the next refusal or restart")
			}
		}
	}
}

@(private)
_space_erase :: proc(e: ^Engine, sp: ^Space) -> Error {
	id := sp.id
	objs := make(map[prim.Id]bool, context.temp_allocator)
	objs[sp.catalog] = true
	if sp.open && !sp.keyless {
		for archived in ([2]bool{false, true}) {
			cur: Map_Cursor
			for _ in 0 ..< 1 << 16 {
				rows, more, lerr := catalog_list(e, id, archived, &cur, 256, context.temp_allocator)
				if lerr != .None {
					break
				}
				for r in rows {
					objs[r.object] = true
				}
				if !more {
					break
				}
			}
			omap.cursor_destroy(&cur)
		}
	}
	for k, v in e.reg.staged {
		if rec, rerr := _rec_decode(v, context.temp_allocator); rerr == .None && rec.space == id {
			objs[k] = true
		}
	}
	Acc :: struct {
		space: prim.Id,
		objs:  ^map[prim.Id]bool,
	}
	acc := Acc{space = id, objs = &objs}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) != 16 {
			return true
		}
		if rec, err := _rec_decode(value, context.temp_allocator); err == .None && rec.space == a.space {
			x: prim.Id
			copy(x[:], key)
			a.objs[x] = true
		}
		return true
	}
	_oerr(omap.db_scan(&e.reg.db, ROOT_OBJECTS, nil, nil, &acc, visit)) or_return
	for i := len(e.plug.mounts) - 1; i >= 0; i -= 1 {
		mt := e.plug.mounts[i]
		if mt.object.space == id {
			tree_unmount(e, &mt.mount)
		}
	}
	_index_purge_ids(e, objs)
	if sp.open {
		_space_unload(e, sp, true)
	}
	for k, t in e.own_trees {
		if t.space == id {
			delete_key(&e.own_trees, k)
			_own_tree_free(e, t)
		}
	}
	for oid in objs {
		dir := _obj_dir(e, oid) or_return
		_erase_path(e.vfs, dir) or_return
	}
	if d, derr := _members_dir(e, id); derr == .None {
		_erase_path(e.vfs, d) or_return
	}
	if c, cerr := _card_path(e, sp); cerr == .None {
		_erase_path(e.vfs, c) or_return
	}
	hx := prim.id_hex(id)
	if s, serr := _join(context.temp_allocator, e.pack_root, "search-snap", string(hx[:])); serr == .None {
		_erase_path(e.vfs, s) or_return
	}
	for oid in objs {
		if v, ok := e.reg.staged[oid]; ok {
			delete(v, e.allocator)
			delete_key(&e.reg.staged, oid)
		}
		if v, ok := e.reg.kstaged[oid]; ok {
			crypto.zero_explicit(raw_data(v), len(v))
			delete(v, e.allocator)
			delete_key(&e.reg.kstaged, oid)
		}
	}
	for i := len(e.reg.owned) - 1; i >= 0; i -= 1 {
		if string(e.reg.owned[i].key[:16]) == string(id[:]) {
			ordered_remove(&e.reg.owned, i)
		}
	}
	if v, ok := e.reg.sstaged[id]; ok {
		delete(v, e.allocator)
		delete_key(&e.reg.sstaged, id)
	}
	_registry_drop_space(e, id, objs) or_return
	_oerr(omap.db_compact(&e.reg.db)) or_return
	delete_key(&e.spaces, id)
	delete_key(&e.reg.unclean, id)
	_space_free(e, sp, true)
	_waiters_fail_space(e, id, .Permission)
	_leave_waits_fail(e, id)
	ent, _ := _left_get(e, id)
	_left_set(e, Left_Entry{space = id, state = LEFT_DONE, target = ent.target}) or_return
	_emit(e, Event{kind = .Space_Left, space = id})
	return .None
}

@(private)
_leave_waits_fail :: proc(e: ^Engine, space: prim.Id) {
	fail := make([dynamic]Space_Wait, context.temp_allocator)
	for i := 0; i < len(e.space_waits); {
		w := e.space_waits[i]
		if w.space == space {
			ordered_remove(&e.space_waits, i)
			append(&fail, w)
			continue
		}
		i += 1
	}
	for w in fail {
		_space_wait_finish(e, w, .Permission)
	}
}

@(private)
_index_purge_ids :: proc(e: ^Engine, objs: map[prim.Id]bool) {
	if !e.cfg.search || _index_open(e) != .None {
		return
	}
	for object in objs {
		src := _source_id(object, e.self)
		pos, _ := search.position(&e.index, src)
		search.delete_object(&e.index, src, pos, object)
	}
	search.erase(&e.index)
}

@(private)
_registry_drop_space :: proc(e: ^Engine, space: prim.Id, objs: map[prim.Id]bool) -> Error {
	Keys :: struct {
		keys: [dynamic][]u8,
	}
	collect :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		k := (^Keys)(data)
		c := make([]u8, len(key), context.temp_allocator)
		copy(c, key)
		append(&k.keys, c)
		return true
	}
	_serve_drop_space(e, space)
	owned := Keys{keys = make([dynamic][]u8, context.temp_allocator)}
	grants := Keys{keys = make([dynamic][]u8, context.temp_allocator)}
	s := space
	_oerr(omap.db_scan(&e.reg.db, ROOT_OWNED, s[:], s[:], &owned, collect)) or_return
	_oerr(omap.db_scan(&e.reg.db, ROOT_GRANTS, s[:], s[:], &grants, collect)) or_return
	seals := Keys{keys = make([dynamic][]u8, context.temp_allocator)}
	for oid in objs {
		for tag in ([]u8{SEAL_KEY, SEAL_COVER}) {
			pfx: [17]u8
			o := oid
			pfx[0] = tag
			copy(pfx[1:], o[:])
			_oerr(omap.db_scan(&e.reg.db, ROOT_CKPT, pfx[:], pfx[:], &seals, collect)) or_return
		}
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	ok := true
	for oid in objs {
		k := oid
		if _, derr := omap.txn_delete(t, ROOT_OBJECTS, k[:]); derr != .None {
			ok = false
		}
		kk := _keys_key(oid)
		if _, derr := omap.txn_delete(t, ROOT_OBJECTS, kk[:]); derr != .None {
			ok = false
		}
	}
	for k in owned.keys {
		if _, derr := omap.txn_delete(t, ROOT_OWNED, k); derr != .None {
			ok = false
		}
	}
	for k in grants.keys {
		if _, derr := omap.txn_delete(t, ROOT_GRANTS, k); derr != .None {
			ok = false
		}
	}
	for k in seals.keys {
		if _, derr := omap.txn_delete(t, ROOT_CKPT, k); derr != .None {
			ok = false
		}
	}
	if _, derr := omap.txn_delete(t, ROOT_SPACES, s[:]); derr != .None {
		ok = false
	}
	uk := _unclean_key(s)
	if _, derr := omap.txn_delete(t, ROOT_SPACES, uk[:]); derr != .None {
		ok = false
	}
	if !ok {
		omap.txn_abort(t)
		return .Io
	}
	return _reg_commit(e, t)
}

@(private)
_erase_path :: proc(vfs: prim.Vfs, path: string) -> Error {
	st, serr := prim.lstat(vfs, path)
	if serr == .Not_Found {
		return .None
	}
	if serr != .None {
		return _perr(serr)
	}
	if st.kind == .Dir {
		names := make([dynamic]string, context.temp_allocator)
		d: prim.Dir
		_perr(prim.dir_open(vfs, &d, path, context.temp_allocator)) or_return
		for {
			ent, more, derr := prim.dir_next(vfs, &d)
			if derr != .None {
				prim.dir_close(vfs, &d)
				return _perr(derr)
			}
			if !more {
				break
			}
			if ent.name == "." || ent.name == ".." {
				continue
			}
			c, _ := _clone(ent.name, context.temp_allocator)
			append(&names, c)
		}
		prim.dir_close(vfs, &d)
		for n in names {
			p := _join(context.temp_allocator, path, n) or_return
			_erase_path(vfs, p) or_return
		}
		if rerr := prim.remove_dir(vfs, path); rerr != .None && rerr != .Not_Found {
			return _perr(rerr)
		}
		return .None
	}
	if st.kind == .File {
		fd, oerr := prim.open_file(vfs, path, {.Write})
		if oerr == .None {
			size, _ := prim.file_size(vfs, fd)
			zerr := prim.zero_range(vfs, fd, 0, size)
			if zerr == .None {
				zerr = prim.datasync(vfs, fd)
			}
			prim.close_file(vfs, fd)
			if zerr != .None {
				return _perr(zerr)
			}
		} else if oerr != .Not_Found {
			return _perr(oerr)
		}
	}
	if rerr := prim.remove(vfs, path); rerr != .None && rerr != .Not_Found {
		return _perr(rerr)
	}
	return .None
}

@(private)
_left_path :: proc(e: ^Engine) -> (string, Error) {
	return _join(context.temp_allocator, e.pack_root, LEFT_FILE)
}

@(private)
_left_load :: proc(e: ^Engine) -> [dynamic]Left_Entry {
	out := make([dynamic]Left_Entry, context.temp_allocator)
	path, perr := _left_path(e)
	if perr != .None {
		return out
	}
	data, rerr := prim.read_file(e.vfs, path, context.temp_allocator)
	if rerr != .None {
		return out
	}
	rd := prim.reader(data)
	if prim.read_u8(&rd) != LEFT_VERSION {
		return out
	}
	n := prim.read_uvarint(&rd)
	if n > u64(prim.reader_remaining(&rd)) {
		return out
	}
	for _ in 0 ..< n {
		x: Left_Entry
		x.space = prim.read_id(&rd)
		x.state = prim.read_u8(&rd)
		x.target = prim.read_ivarint(&rd)
		if !prim.reader_ok(&rd) {
			break
		}
		append(&out, x)
	}
	return out
}

@(private)
_left_get :: proc(e: ^Engine, space: prim.Id) -> (Left_Entry, bool) {
	for x in _left_load(e) {
		if x.space == space {
			return x, true
		}
	}
	return {}, false
}

@(private)
_left_set :: proc(e: ^Engine, ent: Left_Entry) -> Error {
	list := _left_load(e)
	found := false
	for &x in list {
		if x.space == ent.space {
			x = ent
			found = true
		}
	}
	if !found {
		append(&list, ent)
	}
	return _left_store(e, list[:])
}

@(private)
_leave_cancel :: proc(e: ^Engine, space: prim.Id) -> bool {
	for x, i in e.leave_ready {
		if x == space {
			ordered_remove(&e.leave_ready, i)
			break
		}
	}
	if _, ok := _left_get(e, space); !ok {
		return false
	}
	return _left_clear(e, space) == .None
}

@(private)
_left_clear :: proc(e: ^Engine, space: prim.Id) -> Error {
	list := _left_load(e)
	keep := make([dynamic]Left_Entry, context.temp_allocator)
	found := false
	for x in list {
		if x.space == space {
			found = true
			continue
		}
		append(&keep, x)
	}
	if !found {
		return .None
	}
	return _left_store(e, keep[:])
}

@(private)
_left_store :: proc(e: ^Engine, list: []Left_Entry) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, LEFT_VERSION)
	prim.write_uvarint(&w, u64(len(list)))
	for x in list {
		prim.write_id(&w, x.space)
		prim.write_u8(&w, x.state)
		prim.write_ivarint(&w, x.target)
	}
	if w.err != .None {
		return .No_Memory
	}
	path := _left_path(e) or_return
	tmp := _join(context.temp_allocator, e.pack_root, "left.tmp") or_return
	_perr(prim.mkdir_all(e.vfs, e.pack_root, 0o700)) or_return
	fd, oerr := prim.open_file(e.vfs, tmp, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	werr := _perr(prim.write_at(e.vfs, fd, buf[:], 0))
	if werr == .None {
		werr = _perr(prim.datasync(e.vfs, fd))
	}
	prim.close_file(e.vfs, fd)
	werr or_return
	_perr(prim.rename(e.vfs, tmp, path)) or_return
	return _perr(prim.sync_dir(e.vfs, e.pack_root))
}

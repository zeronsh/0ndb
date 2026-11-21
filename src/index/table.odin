package index

import "base:runtime"
import "core:mem/virtual"
import "../journal"
import "../prim"

ROOT_THREADS :: 0
ROOT_ACTIVITY :: 1
ROOT_WORKTREES :: 2
ROOT_DEVICES :: 3
ROOT_STREAMS :: 4
ROOT_CURSORS :: 5
ROOT_REJECTED :: 6

ACTIVITY_KEY :: 25
TXN_DIRTY_MAX :: 2048

Table :: struct {
	db:        Db,
	path:      string,
	allocator: runtime.Allocator,
}

List_Cursor :: struct {
	key:   [ACTIVITY_KEY]u8,
	valid: bool,
}

Device_Info :: struct {
	id:       prim.Id,
	hlc:      prim.Hlc,
	name:     string,
	platform: string,
}

Rejection :: struct {
	cmd:    prim.Id,
	host:   prim.Id,
	reason: Reject_Reason,
	detail: string,
	hlc:    prim.Hlc,
}

table_open :: proc(t: ^Table, path: string, allocator := context.allocator) -> Error {
	t^ = {
		allocator = allocator,
	}
	p, err := make([]u8, len(path), allocator)
	if err != nil {
		return .No_Memory
	}
	copy(p, path)
	t.path = string(p)
	e := db_open(&t.db, t.path, allocator)
	if e == .Corrupt {
		prim.remove(t.path)
		e = db_open(&t.db, t.path, allocator)
	}
	if e != .None {
		delete(t.path, allocator)
		t.path = ""
	}
	return e
}

table_close :: proc(t: ^Table) {
	db_close(&t.db)
	delete(t.path, t.allocator)
	t.path = ""
}

table_reset :: proc(t: ^Table) -> Error {
	db_close(&t.db)
	if e := prim.remove(t.path); e != .None && e != .Not_Found {
		return _perr(e)
	}
	return db_open(&t.db, t.path, t.allocator)
}

table_count :: proc "contextless" (t: ^Table) -> u64 {
	return db_count(&t.db, ROOT_ACTIVITY)
}

table_consumed :: proc(t: ^Table, device: prim.Id) -> (off: i64, err: Error) {
	d := device
	v, found := db_get(&t.db, ROOT_STREAMS, d[:], context.temp_allocator) or_return
	if !found {
		return 0, .None
	}
	x, ok := value_u64(v)
	if !ok || x > u64(max(i64)) {
		return 0, .Corrupt
	}
	return i64(x), .None
}

table_apply :: proc(t: ^Table, device: prim.Id, r: ^journal.Reader) -> (pos: i64, err: Error) {
	pos = table_consumed(t, device) or_return
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return pos, .No_Memory
	}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	txn := txn_begin(&t.db) or_return
	stop: Error
	for {
		body, next, e := journal.record_at(r, pos)
		if e == .Eof {
			break
		}
		if e != .None {
			stop = _jerr(e)
			break
		}
		if ae := _apply_record(txn, device, body); ae != .None {
			txn_abort(txn)
			return pos, ae
		}
		pos = next
		if txn_dirty(txn) >= TXN_DIRTY_MAX {
			if ce := _commit_consumed(txn, device, pos); ce != .None {
				return pos, ce
			}
			txn = txn_begin(&t.db) or_return
		}
		virtual.arena_free_all(&scratch)
	}
	if ce := _commit_consumed(txn, device, pos); ce != .None {
		return pos, ce
	}
	return pos, stop
}

table_session :: proc(t: ^Table, id: prim.Id, allocator := context.allocator) -> (s: Session, found: bool, err: Error) {
	k := id
	akey, hit := db_get(&t.db, ROOT_THREADS, k[:], context.temp_allocator) or_return
	if !hit {
		return s, false, .None
	}
	rec, ok := db_get(&t.db, ROOT_ACTIVITY, akey, context.temp_allocator) or_return
	if !ok {
		return s, false, .Corrupt
	}
	s = session_from(id, rec, allocator) or_return
	return s, true, .None
}

table_list :: proc(t: ^Table, archived: bool, after: List_Cursor, limit: int, allocator := context.allocator) -> (out: []Session, next: List_Cursor, more: bool, err: Error) {
	if limit <= 0 {
		return nil, after, true, .None
	}
	Lister :: struct {
		list:      [dynamic]Session,
		limit:     int,
		skip:      []u8,
		last:      [ACTIVITY_KEY]u8,
		more:      bool,
		err:       Error,
		allocator: runtime.Allocator,
	}
	prefix := [1]u8{1 if archived else 0}
	l := Lister{
		list      = make([dynamic]Session, 0, limit, allocator),
		limit     = limit,
		allocator = allocator,
	}
	start: []u8
	a := after
	if after.valid {
		start = a.key[:]
		l.skip = a.key[:]
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		l := (^Lister)(data)
		if l.skip != nil && string(key) == string(l.skip) {
			return true
		}
		if len(key) != ACTIVITY_KEY {
			l.err = .Corrupt
			return false
		}
		if len(l.list) == l.limit {
			l.more = true
			return false
		}
		id: prim.Id
		copy(id[:], key[9:])
		s, e := session_from(id, value, l.allocator)
		if e != .None {
			l.err = e
			return false
		}
		append(&l.list, s)
		copy(l.last[:], key)
		return true
	}
	db_scan(&t.db, ROOT_ACTIVITY, start, prefix[:], &l, visit) or_return
	if l.err != .None {
		return nil, after, false, l.err
	}
	next = after
	if len(l.list) > 0 {
		next = List_Cursor{l.last, true}
	}
	return l.list[:], next, l.more, .None
}

table_worktree :: proc(t: ^Table, id: prim.Id, allocator := context.allocator) -> (w: Worktree, found: bool, err: Error) {
	k := id
	v, hit := db_get(&t.db, ROOT_WORKTREES, k[:], context.temp_allocator) or_return
	if !hit {
		return w, false, .None
	}
	w = worktree_from(id, v, allocator) or_return
	return w, true, .None
}

table_device :: proc(t: ^Table, id: prim.Id, allocator := context.allocator) -> (d: Device_Info, found: bool, err: Error) {
	k := id
	v, hit := db_get(&t.db, ROOT_DEVICES, k[:], context.temp_allocator) or_return
	if !hit {
		return d, false, .None
	}
	r := prim.reader(v)
	d.id = id
	d.hlc = prim.Hlc(prim.read_u64le(&r))
	name := prim.read_str(&r)
	platform := prim.read_str(&r)
	if r.err != .None {
		return d, false, .Corrupt
	}
	d.name = _clone_str(name, allocator) or_return
	d.platform = _clone_str(platform, allocator) or_return
	return d, true, .None
}

table_cursor :: proc(t: ^Table, host: prim.Id, source: prim.Id) -> (off: i64, err: Error) {
	k := _pair_key(host, source)
	v, hit := db_get(&t.db, ROOT_CURSORS, k[:], context.temp_allocator) or_return
	if !hit {
		return 0, .None
	}
	x, ok := value_u64(v)
	if !ok || x > u64(max(i64)) {
		return 0, .Corrupt
	}
	return i64(x), .None
}

table_rejection :: proc(t: ^Table, cmd: prim.Id, allocator := context.allocator) -> (j: Rejection, found: bool, err: Error) {
	k := cmd
	v, hit := db_get(&t.db, ROOT_REJECTED, k[:], context.temp_allocator) or_return
	if !hit {
		return j, false, .None
	}
	j = _decode_rejection(cmd, v, allocator) or_return
	return j, true, .None
}

activity_key :: proc "contextless" (archived: bool, activity: u64, id: prim.Id) -> (k: [ACTIVITY_KEY]u8) {
	k[0] = 1 if archived else 0
	inv := ~activity
	for i in 0 ..< 8 {
		k[1 + i] = u8(inv >> (56 - 8 * u64(i)))
	}
	v := id
	copy(k[9:], v[:])
	return
}

@(private)
_pair_key :: proc "contextless" (a, b: prim.Id) -> (k: [32]u8) {
	x, y := a, b
	copy(k[:16], x[:])
	copy(k[16:], y[:])
	return
}

@(private)
_commit_consumed :: proc(txn: ^Txn, device: prim.Id, pos: i64) -> Error {
	d := device
	b: [10]u8
	n := prim.put_uvarint(b[:], u64(pos))
	if e := txn_put(txn, ROOT_STREAMS, d[:], b[:n]); e != .None {
		txn_abort(txn)
		return e
	}
	return txn_commit(txn)
}

@(private)
_apply_record :: proc(txn: ^Txn, device: prim.Id, body: []u8) -> Error {
	rec, derr := decode_record(body, context.temp_allocator)
	if derr == .No_Memory {
		return .No_Memory
	}
	if derr != .None {
		return .None
	}
	switch v in rec {
	case Device:
		return _apply_device(txn, device, v)
	case Thread_Entity:
		return _apply_thread(txn, device, Entity(v))
	case Worktree_Entity:
		k := v.id
		old, _ := txn_get(txn, ROOT_WORKTREES, k[:], context.temp_allocator) or_return
		merged, changed, me := merge(old, device, v.fields)
		if me == .Corrupt || me == .Limit {
			return .None
		}
		if me != .None {
			return me
		}
		if changed {
			return txn_put(txn, ROOT_WORKTREES, k[:], merged)
		}
	case Cursor:
		k := _pair_key(device, v.source)
		old, found := txn_get(txn, ROOT_CURSORS, k[:], context.temp_allocator) or_return
		if found {
			if x, ok := value_u64(old); ok && x >= u64(v.offset) {
				return .None
			}
		}
		b: [10]u8
		n := prim.put_uvarint(b[:], u64(v.offset))
		return txn_put(txn, ROOT_CURSORS, k[:], b[:n])
	case Rejected:
		k := v.cmd
		old, found := txn_get(txn, ROOT_REJECTED, k[:], context.temp_allocator) or_return
		if found {
			if j, e := _decode_rejection(v.cmd, old, context.temp_allocator); e == .None {
				if !field_wins(v.hlc, device, transmute([]u8)v.detail, j.hlc, j.host, transmute([]u8)j.detail) {
					return .None
				}
			}
		}
		buf := make([dynamic]u8, context.temp_allocator)
		w := prim.writer(&buf)
		prim.write_id(&w, device)
		prim.write_u8(&w, u8(v.reason))
		prim.write_str(&w, v.detail)
		prim.write_u64le(&w, u64(v.hlc))
		return txn_put(txn, ROOT_REJECTED, k[:], buf[:])
	}
	return .None
}

@(private)
_decode_rejection :: proc(cmd: prim.Id, v: []u8, allocator: runtime.Allocator) -> (j: Rejection, err: Error) {
	r := prim.reader(v)
	j.cmd = cmd
	j.host = prim.read_id(&r)
	j.reason = Reject_Reason(prim.read_u8(&r))
	detail := prim.read_str(&r)
	j.hlc = prim.Hlc(prim.read_u64le(&r))
	if r.err != .None {
		return j, .Corrupt
	}
	j.detail = _clone_str(detail, allocator) or_return
	return j, .None
}

@(private)
_apply_device :: proc(txn: ^Txn, device: prim.Id, d: Device) -> Error {
	k := device
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u64le(&w, u64(d.hlc))
	prim.write_str(&w, d.name)
	prim.write_str(&w, d.platform)
	old, found := txn_get(txn, ROOT_DEVICES, k[:], context.temp_allocator) or_return
	if found && len(old) >= 8 {
		oh := prim.Hlc(prim.get_u64le(old[0:8]))
		if !field_wins(d.hlc, device, buf[8:], oh, device, old[8:]) {
			return .None
		}
	}
	return txn_put(txn, ROOT_DEVICES, k[:], buf[:])
}

@(private)
_apply_thread :: proc(txn: ^Txn, device: prim.Id, e: Entity) -> Error {
	k := e.id
	akey, found := txn_get(txn, ROOT_THREADS, k[:], context.temp_allocator) or_return
	old: []u8
	if found {
		if len(akey) != ACTIVITY_KEY {
			return .Corrupt
		}
		rec, ok := txn_get(txn, ROOT_ACTIVITY, akey, context.temp_allocator) or_return
		if !ok {
			return .Corrupt
		}
		old = rec
	}
	merged, changed, me := merge(old, device, e.fields)
	if me == .Corrupt || me == .Limit {
		return .None
	}
	if me != .None {
		return me
	}
	if !changed {
		return .None
	}
	fields := decode_merged(merged) or_return
	archived := false
	activity: u64
	if v, ok := merged_get(fields, u8(Thread_Tag.Archived)); ok {
		archived, _ = value_bool(v)
	}
	if v, ok := merged_get(fields, u8(Thread_Tag.Activity)); ok {
		activity, _ = value_u64(v)
	}
	nkey := activity_key(archived, activity, e.id)
	if !found || string(akey) != string(nkey[:]) {
		if found {
			txn_delete(txn, ROOT_ACTIVITY, akey) or_return
		}
		txn_put(txn, ROOT_THREADS, k[:], nkey[:]) or_return
	}
	return txn_put(txn, ROOT_ACTIVITY, nkey[:], merged)
}

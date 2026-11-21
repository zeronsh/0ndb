package omap

import "base:runtime"
import "core:mem/virtual"
import "../journal"
import "../obj"
import "../prim"

ROOT_ENTRIES :: 0
ROOT_CONSUMED :: 1
ROOT_INDEX :: 2
MAX_INDEXES :: ROOTS - ROOT_INDEX
TXN_BYTES_MAX :: 64 * 1024 * 1024

Extract :: #type proc(data: rawptr, e: ^Entry, out: ^[dynamic]u8) -> bool

Index_Def :: struct {
	extract:  Extract,
	data:     rawptr,
	covering: bool,
}

Table :: struct {
	db:        Db,
	vfs:       prim.Vfs,
	path:      string,
	defs:      [MAX_INDEXES]Index_Def,
	ndefs:     int,
	allocator: runtime.Allocator,
}

Cursor :: struct {
	key:   [dynamic]u8,
	valid: bool,
}

Row :: struct {
	key:   []u8,
	entry: Entry,
}

table_open :: proc(t: ^Table, vfs: prim.Vfs, path: string, defs: []Index_Def = nil, allocator := context.allocator) -> Error {
	if len(defs) > MAX_INDEXES {
		return .Limit
	}
	t^ = {
		vfs       = vfs,
		allocator = allocator,
		ndefs     = len(defs),
	}
	copy(t.defs[:], defs)
	p, err := make([]u8, len(path), allocator)
	if err != nil {
		return .No_Memory
	}
	copy(p, path)
	t.path = string(p)
	e := db_open(&t.db, vfs, t.path, allocator)
	if e == .Corrupt {
		prim.remove(vfs, t.path)
		e = db_open(&t.db, vfs, t.path, allocator)
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
	if e := prim.remove(t.vfs, t.path); e != .None && e != .Not_Found {
		return obj.perr(e)
	}
	return db_open(&t.db, t.vfs, t.path, t.allocator)
}

table_count :: proc "contextless" (t: ^Table) -> u64 {
	return db_count(&t.db, ROOT_ENTRIES)
}

table_consumed :: proc(t: ^Table, seg: prim.Id) -> (off: i64, err: Error) {
	s := seg
	v, found := db_get(&t.db, ROOT_CONSUMED, s[:], context.temp_allocator) or_return
	if !found {
		return 0, .None
	}
	x, ok := value_u64(v)
	if !ok || x > u64(max(i64)) {
		return 0, .Corrupt
	}
	return i64(x), .None
}

table_apply :: proc(t: ^Table, seg: prim.Id, r: ^journal.Reader) -> (pos: i64, err: Error) {
	pos = table_consumed(t, seg) or_return
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
		if e == .Redacted {
			pos = next
			continue
		}
		if e != .None {
			stop = obj.jerr(e)
			break
		}
		if !obj.is_sig(body) && !obj.is_redacted(body) && obj.record_kind(body) >= obj.RECORD_KIND_FIRST {
			if ae := _apply_record(t, txn, seg, pos, body); ae != .None {
				txn_abort(txn)
				return pos, ae
			}
		}
		pos = next
		if txn_bytes(txn) >= TXN_BYTES_MAX {
			if ce := _commit_consumed(txn, seg, pos); ce != .None {
				return pos, ce
			}
			txn = txn_begin(&t.db) or_return
		}
		virtual.arena_free_all(&scratch)
	}
	if ce := _commit_consumed(txn, seg, pos); ce != .None {
		return pos, ce
	}
	return pos, stop
}

table_get :: proc(t: ^Table, key: []u8, allocator := context.allocator) -> (e: Entry, found: bool, err: Error) {
	v, hit := db_get(&t.db, ROOT_ENTRIES, key, allocator) or_return
	if !hit {
		return e, false, .None
	}
	k := obj.clone_bytes(key, allocator) or_return
	e = decode_entry(k, v, allocator) or_return
	if entry_empty(&e) {
		return {}, false, .None
	}
	return e, true, .None
}

table_scan :: proc(t: ^Table, index: int, prefix: []u8, after: ^Cursor, limit: int, allocator := context.allocator) -> (rows: []Row, more: bool, err: Error) {
	if index >= t.ndefs || limit <= 0 {
		return nil, false, .Invalid
	}
	root := ROOT_ENTRIES if index < 0 else ROOT_INDEX + index
	covering := index < 0 || t.defs[index].covering
	Ctx :: struct {
		t:         ^Table,
		list:      [dynamic]Row,
		limit:     int,
		skip:      []u8,
		more:      bool,
		err:       Error,
		index:     bool,
		covering:  bool,
		last:      ^[dynamic]u8,
		allocator: runtime.Allocator,
	}
	c := Ctx{
		t         = t,
		list      = make([dynamic]Row, 0, limit, allocator),
		limit     = limit,
		index     = index >= 0,
		covering  = covering,
		last      = &after.key,
		allocator = allocator,
	}
	start: []u8
	if after.valid {
		start = after.key[:]
		c.skip = after.key[:]
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		c := (^Ctx)(data)
		if c.skip != nil && string(key) == string(c.skip) {
			return true
		}
		if len(c.list) == c.limit {
			c.more = true
			return false
		}
		ek := key
		if c.index {
			if len(key) < 1 {
				c.err = .Corrupt
				return false
			}
			n := int(key[len(key) - 1])
			if n + 1 > len(key) {
				c.err = .Corrupt
				return false
			}
			ek = key[len(key) - 1 - n:len(key) - 1]
		}
		kc, e1 := obj.clone_bytes(ek, c.allocator)
		if e1 != .None {
			c.err = e1
			return false
		}
		row := Row{
			key = kc,
		}
		if c.covering {
			vc, e3 := obj.clone_bytes(value, c.allocator)
			if e3 != .None {
				c.err = e3
				return false
			}
			entry, e2 := decode_entry(kc, vc, c.allocator)
			if e2 != .None {
				c.err = e2
				return false
			}
			if entry_empty(&entry) {
				clear(c.last)
				append(c.last, ..key)
				return true
			}
			row.entry = entry
		}
		append(&c.list, row)
		clear(c.last)
		append(c.last, ..key)
		return true
	}
	if err = db_scan(&t.db, root, start, prefix, &c, visit); err != .None {
		return nil, false, err
	}
	if c.err != .None {
		return nil, false, c.err
	}
	if !covering {
		for &row in c.list {
			e, hit := table_get(t, row.key, allocator) or_return
			if !hit {
				return nil, false, .Corrupt
			}
			row.entry = e
		}
	}
	if len(c.list) > 0 {
		after.valid = true
	}
	return c.list[:], c.more, .None
}

cursor_destroy :: proc(c: ^Cursor) {
	delete(c.key)
	c^ = {}
}

@(private)
_commit_consumed :: proc(txn: ^Txn, seg: prim.Id, pos: i64) -> Error {
	s := seg
	b: [10]u8
	n := prim.put_uvarint(b[:], u64(pos))
	if e := txn_put(txn, ROOT_CONSUMED, s[:], b[:n]); e != .None {
		txn_abort(txn)
		return e
	}
	return txn_commit(txn)
}

@(private)
_index_key :: proc(t: ^Table, i: int, e: ^Entry, key: []u8) -> (out: []u8, ok: bool) {
	buf := make([dynamic]u8, context.temp_allocator)
	d := t.defs[i]
	if !d.extract(d.data, e, &buf) {
		return nil, false
	}
	append(&buf, ..key)
	append(&buf, u8(len(key)))
	if len(buf) > MAX_KEY {
		return nil, false
	}
	return buf[:], true
}

@(private)
_apply_record :: proc(t: ^Table, txn: ^Txn, seg: prim.Id, off: i64, body: []u8) -> Error {
	env, eerr := obj.decode_envelope(body, off)
	if eerr != .None {
		return .None
	}
	b, berr := decode_body(&env)
	if berr == .No_Memory {
		return .No_Memory
	}
	if berr != .None {
		return .None
	}
	key: []u8
	switch v in b {
	case Put:
		key = v.key
	case Add:
		key = v.key
	case Del:
		key = v.key
	}
	old, found := txn_get(txn, ROOT_ENTRIES, key, context.temp_allocator) or_return
	e := decode_entry(key, old if found else nil) or_return
	olds: [MAX_INDEXES][]u8
	oldok: [MAX_INDEXES]bool
	if found && !entry_empty(&e) {
		for i in 0 ..< t.ndefs {
			olds[i], oldok[i] = _index_key(t, i, &e, key)
		}
	}
	changed := apply(&e, seg, Rid{seg, off}, b)
	pruned := _prune(txn, &e, seg, off) or_return
	if !changed && !pruned {
		return .None
	}
	buf := make([dynamic]u8, context.temp_allocator)
	if len(e.registers) == 0 && len(e.elements) == 0 {
		if found {
			txn_delete(txn, ROOT_ENTRIES, key) or_return
		}
	} else {
		encode_entry(&buf, &e) or_return
		txn_put(txn, ROOT_ENTRIES, key, buf[:]) or_return
	}
	empty := entry_empty(&e)
	for i in 0 ..< t.ndefs {
		nk: []u8
		nok := false
		if !empty {
			nk, nok = _index_key(t, i, &e, key)
		}
		if oldok[i] && (!nok || string(nk) != string(olds[i])) {
			txn_delete(txn, ROOT_INDEX + i, olds[i]) or_return
		}
		if nok {
			txn_put(txn, ROOT_INDEX + i, nk, buf[:] if t.defs[i].covering else nil) or_return
		}
	}
	return .None
}

@(private)
_prune :: proc(txn: ^Txn, e: ^Entry, seg: prim.Id, off: i64) -> (changed: bool, err: Error) {
	Seen :: struct {
		seg: prim.Id,
		off: i64,
	}
	seen := make([dynamic]Seen, context.temp_allocator)
	applied :: proc(txn: ^Txn, seen: ^[dynamic]Seen, cur: prim.Id, at: i64, r: Rid) -> (yes: bool, err: Error) {
		if r.seg == cur {
			return r.off <= at, .None
		}
		for s in seen {
			if s.seg == r.seg {
				return r.off < s.off, .None
			}
		}
		k := r.seg
		v, found := txn_get(txn, ROOT_CONSUMED, k[:], context.temp_allocator) or_return
		c: i64
		if found {
			x, ok := value_u64(v)
			if !ok || x > u64(max(i64)) {
				return false, .Corrupt
			}
			c = i64(x)
		}
		append(seen, Seen{r.seg, c})
		return r.off < c, .None
	}
	n := 0
	for el in e.elements {
		x := el
		if len(el.dead) > 0 {
			dead := make([dynamic]Rid, 0, len(el.dead), context.temp_allocator)
			for r in el.dead {
				if done := applied(txn, &seen, seg, off, r) or_return; !done {
					append(&dead, r)
				}
			}
			changed ||= len(dead) != len(el.dead)
			x.dead = dead[:]
		}
		if len(x.live) > 0 || len(x.dead) > 0 {
			e.elements[n] = x
			n += 1
		}
	}
	e.elements = e.elements[:n]
	return changed, .None
}

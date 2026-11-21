package engine

import "../journal"
import omap "../map"
import "../pack"
import "../prim"

@(private)
RLOG_INTENT :: u8(1)
@(private)
RLOG_CLEAR :: u8(2)
@(private)
RLOG_PEND_ADD :: u8(3)
@(private)
RLOG_PEND_DEL :: u8(4)
@(private)
RLOG_CLEARS_MAX :: 256
@(private)
RLOG_UNKNOWN :: max(i64)

@(private)
Rlog_Key :: [57]u8

@(private)
Rlog_Entry :: struct {
	kind:   Kind,
	to:     i64,
	target: i64,
	done:   bool,
}

@(private)
Rlog :: struct {
	j:       journal.Journal,
	open:    bool,
	failed:  bool,
	live:    map[Rlog_Key]Rlog_Entry,
	clears:  [dynamic]Rlog_Key,
	pend:    map[[32]u8]i64,
	pdels:   [dynamic][32]u8,
	records: int,
	idle:    bool,
	scanned: map[prim.Id]bool,
}

@(private)
_rlog_key :: proc(key: []u8) -> (k: Rlog_Key) {
	n := copy(k[:56], key)
	k[56] = u8(n)
	return
}

@(private)
_rlog_bytes :: proc(k: ^Rlog_Key) -> []u8 {
	return k[:int(k[56])]
}

@(private)
_rlog_path :: proc(e: ^Engine) -> (string, Error) {
	return _join(context.temp_allocator, e.pack_root, "redactions")
}

@(private)
_rlog_ready :: proc(e: ^Engine) -> bool {
	l := &e.rlog
	if l.open {
		return true
	}
	if l.failed || !e.pk_open {
		return false
	}
	path, perr := _rlog_path(e)
	if perr != .None {
		return false
	}
	if journal.journal_open(&l.j, e.vfs, path, {}, e.allocator) != .None {
		l.failed = true
		return false
	}
	l.open = true
	l.live = make(map[Rlog_Key]Rlog_Entry, e.allocator)
	l.clears = make([dynamic]Rlog_Key, e.allocator)
	l.pend = make(map[[32]u8]i64, e.allocator)
	l.scanned = make(map[prim.Id]bool, e.allocator)
	l.pdels = make([dynamic][32]u8, e.allocator)
	rd: journal.Reader
	journal.journal_reader(&l.j, &rd, context.temp_allocator)
	end := journal.journal_durable_len(&l.j)
	pos: i64
	for pos < end {
		body, next, err := journal.record_at(&rd, pos)
		if err != .None {
			break
		}
		pos = next
		l.records += 1
		if len(body) == 33 && (body[0] == RLOG_PEND_ADD || body[0] == RLOG_PEND_DEL) {
			k: [32]u8
			copy(k[:], body[1:33])
			if body[0] == RLOG_PEND_ADD {
				l.pend[k] = RLOG_UNKNOWN
			} else {
				delete_key(&l.pend, k)
			}
			continue
		}
		r := prim.reader(body)
		op := prim.read_u8(&r)
		n := int(prim.read_u8(&r))
		if n > 56 || prim.reader_remaining(&r) < n {
			continue
		}
		k := _rlog_key(body[2:][:n])
		r.pos += n
		switch op {
		case RLOG_INTENT:
			x := Rlog_Entry{kind = Kind(prim.read_u8(&r)), to = i64(prim.read_u64le(&r)), target = i64(prim.read_u64le(&r))}
			if r.err == .None && x.kind >= Kind(1) && x.kind <= max(Kind) {
				l.live[k] = x
			}
		case RLOG_CLEAR:
			delete_key(&l.live, k)
		}
	}
	journal.reader_close(&rd)
	_rlog_migrate(e)
	_rlog_migrate_pending(e)
	return true
}

@(private)
_rlog_migrate_pending :: proc(e: ^Engine) {
	old := make([dynamic][32]u8, context.temp_allocator)
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		if len(key) == 32 {
			k: [32]u8
			copy(k[:], key)
			append((^[dynamic][32]u8)(data), k)
		}
		return true
	}
	omap.db_scan(&e.reg.db, ROOT_PENDING, nil, nil, &old, visit)
	if len(old) == 0 {
		return
	}
	for k in old {
		if _, ok := e.rlog.pend[k]; !ok {
			_rlog_pend_record(e, RLOG_PEND_ADD, k)
			e.rlog.pend[k] = RLOG_UNKNOWN
		}
	}
	if journal.journal_commit(&e.rlog.j) != .None {
		return
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return
	}
	for k in old {
		kk := k
		if _, derr := omap.txn_delete(t, ROOT_PENDING, kk[:]); derr != .None {
			omap.txn_abort(t)
			return
		}
	}
	omap.txn_commit(t)
}

@(private)
_rlog_pend_record :: proc(e: ^Engine, op: u8, k: [32]u8) {
	b: [33]u8
	b[0] = op
	kk := k
	copy(b[1:], kk[:])
	if _, err := journal.journal_append(&e.rlog.j, b[:]); err == .None {
		e.rlog.records += 1
	}
}

@(private)
_rlog_pend_set :: proc(e: ^Engine, k: [32]u8, length: i64) {
	if !_rlog_ready(e) {
		return
	}
	l := &e.rlog
	if cur, ok := &l.pend[k]; ok {
		if cur^ == RLOG_UNKNOWN || length > cur^ {
			cur^ = length
		}
		return
	}
	for x, i in l.pdels {
		if x == k {
			unordered_remove(&l.pdels, i)
			l.pend[k] = length
			return
		}
	}
	_rlog_pend_record(e, RLOG_PEND_ADD, k)
	journal.journal_commit(&l.j)
	l.pend[k] = length
}

@(private)
_rlog_pend_clear :: proc(e: ^Engine, k: [32]u8, length: i64) {
	if !_rlog_ready(e) {
		return
	}
	l := &e.rlog
	cur, ok := l.pend[k]
	if !ok || cur == RLOG_UNKNOWN || cur > length {
		return
	}
	delete_key(&l.pend, k)
	append(&l.pdels, k)
}

@(private)
_rlog_migrate :: proc(e: ^Engine) {
	Old :: struct {
		key: Rlog_Key,
		x:   Rlog_Entry,
	}
	old := make([dynamic]Old, context.temp_allocator)
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		l := (^[dynamic]Old)(data)
		if (len(key) != 40 && len(key) != 56) || (len(value) != 9 && len(value) != 17) || value[0] & 0x7f < 1 || value[0] & 0x7f > u8(max(Kind)) {
			return true
		}
		x := Rlog_Entry{kind = Kind(value[0] & 0x7f), to = i64(prim.get_u64le(value[1:9])), target = -1, done = value[0] & 0x80 != 0}
		if len(value) == 17 {
			x.target = i64(prim.get_u64le(value[9:17]))
		}
		append(l, Old{_rlog_key(key), x})
		return true
	}
	omap.db_scan(&e.reg.db, ROOT_REDACT, nil, nil, &old, visit)
	if len(old) == 0 {
		return
	}
	for &o in old {
		if _rlog_append_intent(e, &o.key, o.x) != .None {
			return
		}
		e.rlog.live[o.key] = o.x
	}
	if journal.journal_commit(&e.rlog.j) != .None {
		return
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return
	}
	for &o in old {
		if _, derr := omap.txn_delete(t, ROOT_REDACT, _rlog_bytes(&o.key)); derr != .None {
			omap.txn_abort(t)
			return
		}
	}
	omap.txn_commit(t)
}

@(private)
_rlog_append_intent :: proc(e: ^Engine, k: ^Rlog_Key, x: Rlog_Entry) -> Error {
	b: [2 + 56 + 17]u8
	key := _rlog_bytes(k)
	b[0] = RLOG_INTENT
	b[1] = u8(len(key))
	n := 2 + copy(b[2:], key)
	b[n] = u8(x.kind)
	prim.put_u64le(b[n + 1:], u64(x.to))
	prim.put_u64le(b[n + 9:], u64(x.target))
	if _, err := journal.journal_append(&e.rlog.j, b[:n + 17]); err != .None {
		return _jerr(err)
	}
	e.rlog.records += 1
	return .None
}

@(private)
_rlog_get :: proc(e: ^Engine, key: []u8) -> (x: Rlog_Entry, found: bool) {
	if !_rlog_ready(e) {
		return
	}
	return e.rlog.live[_rlog_key(key)]
}

@(private)
_rlog_intent :: proc(e: ^Engine, key: []u8, x: Rlog_Entry, durable: bool) -> Error {
	if !_rlog_ready(e) {
		return .Io
	}
	k := _rlog_key(key)
	_rlog_append_intent(e, &k, x) or_return
	_jerr(journal.journal_commit(&e.rlog.j)) or_return
	e.rlog.live[k] = x
	if durable {
		_perr(pack.batch_end(&e.pk)) or_return
		pack.batch_begin(&e.pk)
	}
	_touch(e)
	return .None
}

@(private)
_rlog_done :: proc(e: ^Engine, key: []u8) {
	if !_rlog_ready(e) {
		return
	}
	k := _rlog_key(key)
	if x, ok := &e.rlog.live[k]; ok {
		x.done = true
	}
}

@(private)
_rlog_clear :: proc(e: ^Engine, key: []u8) {
	if !_rlog_ready(e) {
		return
	}
	k := _rlog_key(key)
	if _, ok := e.rlog.live[k]; !ok {
		return
	}
	delete_key(&e.rlog.live, k)
	append(&e.rlog.clears, k)
}

@(private)
_rlog_settle :: proc(e: ^Engine, closing: bool) {
	l := &e.rlog
	idle := l.idle || closing
	l.idle = false
	dels := len(l.pdels) if idle || len(l.pdels) >= RLOG_CLEARS_MAX else 0
	empty := len(l.live) == 0 && len(l.pend) == 0
	if !l.open || (len(l.clears) == 0 && dels == 0 && (l.records == 0 || !empty || !idle)) {
		return
	}
	if !closing && !pack.pending(&e.pk) && len(l.clears) + dels < RLOG_CLEARS_MAX {
		return
	}
	if empty || l.records > 4 * (len(l.live) + len(l.pend)) + RLOG_CLEARS_MAX {
		_rlog_rewrite(e)
		return
	}
	if dels > 0 {
		for k in l.pdels {
			_rlog_pend_record(e, RLOG_PEND_DEL, k)
		}
		clear(&l.pdels)
	}
	for &k in l.clears {
		key := _rlog_bytes(&k)
		b: [2 + 56]u8
		b[0] = RLOG_CLEAR
		b[1] = u8(len(key))
		n := 2 + copy(b[2:], key)
		if _, err := journal.journal_append(&l.j, b[:n]); err != .None {
			return
		}
		l.records += 1
	}
	clear(&l.clears)
	journal.journal_commit(&l.j)
}

@(private)
_rlog_rewrite :: proc(e: ^Engine) {
	l := &e.rlog
	path, perr := _rlog_path(e)
	if perr != .None {
		return
	}
	journal.journal_close(&l.j)
	l.open = false
	prim.remove(e.vfs, path)
	if journal.journal_open(&l.j, e.vfs, path, {}, e.allocator) != .None {
		l.failed = true
		return
	}
	l.open = true
	l.records = 0
	clear(&l.clears)
	clear(&l.pdels)
	for kk, x in l.live {
		k := kk
		_rlog_append_intent(e, &k, x)
	}
	for k in l.pend {
		_rlog_pend_record(e, RLOG_PEND_ADD, k)
	}
	journal.journal_commit(&l.j)
}

@(private)
_rlog_close :: proc(e: ^Engine) {
	l := &e.rlog
	if !l.open {
		return
	}
	_rlog_settle(e, true)
	if l.open {
		journal.journal_close(&l.j)
	}
	l.open = false
	delete(l.live)
	delete(l.clears)
	delete(l.pend)
	delete(l.pdels)
	delete(l.scanned)
}

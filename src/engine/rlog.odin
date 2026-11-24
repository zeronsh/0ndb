package engine

import "../journal"
import omap "../map"
import "../pack"
import "../prim"

@(private)
RLOG_PEND_ADD :: u8(3)
@(private)
RLOG_PEND_DEL :: u8(4)
@(private)
RLOG_CLEARS_MAX :: 256
@(private)
RLOG_UNKNOWN :: max(i64)

@(private)
Rlog :: struct {
	j:       journal.Journal,
	open:    bool,
	failed:  bool,
	pend:    map[[32]u8]i64,
	pdels:   [dynamic][32]u8,
	records: int,
	idle:    bool,
	tick:    u64,
	scanned: map[prim.Id]bool,
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
		if len(body) != 33 || (body[0] != RLOG_PEND_ADD && body[0] != RLOG_PEND_DEL) {
			continue
		}
		k: [32]u8
		copy(k[:], body[1:33])
		if body[0] == RLOG_PEND_ADD {
			l.pend[k] = RLOG_UNKNOWN
		} else {
			delete_key(&l.pend, k)
		}
	}
	journal.reader_close(&rd)
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
	berr := pack.batch_end(&e.pk)
	pack.batch_begin(&e.pk)
	if berr != .None {
		return
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	for k in old {
		kk := k
		if _, derr := omap.txn_delete(t, ROOT_PENDING, kk[:]); derr != .None {
			omap.txn_abort(t)
			_reg_fail(e, .Io)
			return
		}
	}
	_reg_commit(e, t)
}

@(private)
_rlog_pend_record :: proc(e: ^Engine, op: u8, k: [32]u8) {
	b: [33]u8
	b[0] = op
	kk := k
	copy(b[1:], kk[:])
	if _, err := journal.journal_append(&e.rlog.j, b[:]); err != .None {
		_fatal(e, _jerr(err))
		return
	}
	e.rlog.records += 1
}

@(private)
_rlog_commit :: proc(e: ^Engine) {
	if err := journal.journal_commit(&e.rlog.j); err != .None {
		_fatal(e, _jerr(err))
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
	_rlog_commit(e)
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
_rlog_idle :: proc(e: ^Engine) {
	if e.tick == e.rlog.tick {
		return
	}
	e.rlog.tick = e.tick
	e.rlog.idle = true
	_rlog_ready(e)
}

@(private)
_rlog_settle :: proc(e: ^Engine, closing: bool) {
	l := &e.rlog
	idle := l.idle || closing
	l.idle = false
	dels := len(l.pdels) if idle || len(l.pdels) >= RLOG_CLEARS_MAX else 0
	empty := len(l.pend) == 0
	if !l.open || (dels == 0 && (l.records == 0 || !empty || !idle)) {
		return
	}
	if !closing && !pack.pending(&e.pk) && dels < RLOG_CLEARS_MAX {
		return
	}
	if empty || l.records > 4 * len(l.pend) + RLOG_CLEARS_MAX {
		_rlog_rewrite(e)
		return
	}
	if dels > 0 {
		for k in l.pdels {
			_rlog_pend_record(e, RLOG_PEND_DEL, k)
		}
		clear(&l.pdels)
	}
	_rlog_commit(e)
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
	clear(&l.pdels)
	for k in prim.sorted_keys(l.pend) {
		_rlog_pend_record(e, RLOG_PEND_ADD, k)
	}
	_rlog_commit(e)
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
	delete(l.pend)
	delete(l.pdels)
	delete(l.scanned)
}

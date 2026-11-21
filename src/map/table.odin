package omap

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "../journal"
import "../obj"
import "../prim"

ROOT_ENTRIES :: 0
ROOT_CONSUMED :: 1
ROOT_PENDING :: 2
ROOT_INDEX :: 3
MAX_INDEXES :: ROOTS - ROOT_INDEX
TXN_BYTES_MAX :: 64 * 1024 * 1024
REBUILD_MIN :: 4 * 1024 * 1024
RUN_BYTES :: 64 * 1024 * 1024
RUN_IO :: 1024 * 1024

Extract :: #type proc(data: rawptr, e: ^Entry, out: ^[dynamic]u8) -> bool
Project :: #type proc(data: rawptr, e: ^Entry, out: ^[dynamic]u8)

Index_Def :: struct {
	extract: Extract,
	project: Project,
	data:    rawptr,
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
	value: []u8,
}

Source :: struct {
	seg:    prim.Id,
	reader: ^journal.Reader,
}

table_open :: proc(t: ^Table, vfs: prim.Vfs, path: string, defs: []Index_Def = nil, allocator := context.allocator) -> Error {
	if len(defs) > MAX_INDEXES {
		return .Limit
	}
	for d in defs {
		if d.extract == nil {
			return .Invalid
		}
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
	if db_count(&t.db, ROOT_CONSUMED) == 0 && db_count(&t.db, ROOT_ENTRIES) == 0 && db_count(&t.db, ROOT_PENDING) == 0 && journal.reader_end(r) >= REBUILD_MIN {
		src := [1]Source{{seg, r}}
		table_rebuild(t, src[:]) or_return
		return journal.reader_end(r), .None
	}
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
	return e, true, .None
}

table_scan :: proc(t: ^Table, index: int, prefix: []u8, after: ^Cursor, limit: int, allocator := context.allocator) -> (rows: []Row, more: bool, err: Error) {
	if index >= t.ndefs || limit <= 0 {
		return nil, false, .Invalid
	}
	root := ROOT_ENTRIES if index < 0 else ROOT_INDEX + index
	Ctx :: struct {
		list:      [dynamic]Row,
		limit:     int,
		skip:      []u8,
		more:      bool,
		err:       Error,
		index:     bool,
		last:      ^[dynamic]u8,
		allocator: runtime.Allocator,
	}
	c := Ctx{
		list      = make([dynamic]Row, 0, limit, allocator),
		limit     = limit,
		index     = index >= 0,
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
		vc, e2 := obj.clone_bytes(value, c.allocator)
		if e2 != .None {
			c.err = e2
			return false
		}
		row := Row{
			key = kc,
		}
		if c.index {
			row.value = vc
		} else {
			entry, e3 := decode_entry(kc, vc, c.allocator)
			if e3 != .None {
				c.err = e3
				return false
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
	if index >= 0 && t.defs[index].project == nil {
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

table_rebuild :: proc(t: ^Table, sources: []Source) -> Error {
	for a, i in sources {
		if a.reader == nil {
			return .Invalid
		}
		for b in sources[i + 1:] {
			if a.seg == b.seg {
				return .Invalid
			}
		}
	}
	rb := Rebuild{
		t       = t,
		sources = sources,
	}
	defer _rebuild_cleanup(&rb)
	if virtual.arena_init_growing(&rb.batch) != nil || virtual.arena_init_growing(&rb.scratch) != nil {
		return .No_Memory
	}
	rb.ready = true
	for tag in ([2]string{".run", ".idx"}) {
		for n := 0; ; n += 1 {
			p := _run_path(&rb, tag, n) or_return
			e := prim.remove(t.vfs, p)
			delete(p, t.allocator)
			if e != .None {
				break
			}
		}
	}
	rb.items = make([dynamic]Run_Item, t.allocator)
	rb.runs = make([dynamic]string, t.allocator)
	rb.iruns = make([dynamic]string, t.allocator)
	rb.ends = make([]i64, len(sources), t.allocator)
	for s, i in sources {
		_rebuild_source(&rb, i, s) or_return
	}
	_spill_entries(&rb) or_return
	b: Builder
	builder_begin(&b, &t.db) or_return
	ok := false
	defer if !ok {
		builder_abort(&b)
	}
	_merge_entries(&rb, &b) or_return
	_spill_index(&rb) or_return
	_merge_index(&rb, &b) or_return
	order := make([]int, len(sources), context.temp_allocator)
	for i in 0 ..< len(sources) {
		order[i] = i
	}
	for i in 1 ..< len(order) {
		j := i
		for j > 0 && string(_id_bytes(&sources[order[j]].seg)) < string(_id_bytes(&sources[order[j - 1]].seg)) {
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		}
	}
	for i in order {
		v: [10]u8
		n := prim.put_uvarint(v[:], u64(rb.ends[i]))
		s := sources[i].seg
		builder_add(&b, ROOT_CONSUMED, s[:], v[:n]) or_return
	}
	builder_commit(&b) or_return
	ok = true
	return .None
}

@(private)
_id_bytes :: proc(id: ^prim.Id) -> []u8 {
	return id[:]
}

@(private)
Run_Item :: struct {
	key:  []u8,
	src:  int,
	off:  i64,
	body: Body,
	data: []u8,
}

@(private)
Rebuild :: struct {
	t:       ^Table,
	sources: []Source,
	ends:    []i64,
	batch:   virtual.Arena,
	scratch: virtual.Arena,
	ready:   bool,
	items:   [dynamic]Run_Item,
	runs:    [dynamic]string,
	iruns:   [dynamic]string,
}

@(private)
_rebuild_cleanup :: proc(rb: ^Rebuild) {
	if !rb.ready {
		return
	}
	for p in rb.runs {
		prim.remove(rb.t.vfs, p)
		delete(p, rb.t.allocator)
	}
	for p in rb.iruns {
		prim.remove(rb.t.vfs, p)
		delete(p, rb.t.allocator)
	}
	delete(rb.runs)
	delete(rb.iruns)
	delete(rb.items)
	delete(rb.ends, rb.t.allocator)
	virtual.arena_destroy(&rb.batch)
	virtual.arena_destroy(&rb.scratch)
}

@(private)
_rebuild_source :: proc(rb: ^Rebuild, i: int, s: Source) -> Error {
	pos: i64
	for {
		body, next, e := journal.record_at(s.reader, pos)
		if e == .Eof {
			break
		}
		if e == .Redacted {
			pos = next
			continue
		}
		if e != .None {
			return obj.jerr(e)
		}
		if !obj.is_sig(body) && !obj.is_redacted(body) && obj.record_kind(body) >= obj.RECORD_KIND_FIRST {
			a := virtual.arena_allocator(&rb.batch)
			own := obj.clone_bytes(body, a) or_return
			env, eerr := obj.decode_envelope(own, pos)
			if eerr == .None {
				b, berr := decode_body(&env, a)
				if berr == .No_Memory {
					return .No_Memory
				}
				if berr == .None {
					key: []u8
					switch v in b {
					case Put:
						key = v.key
					case Add:
						key = v.key
					case Del:
						key = v.key
					}
					if _, ae := append(&rb.items, Run_Item{key = key, src = i, off = pos, body = b}); ae != nil {
						return .No_Memory
					}
				}
			}
			if rb.batch.total_used >= RUN_BYTES {
				_spill_entries(rb) or_return
			}
		}
		pos = next
	}
	rb.ends[i] = pos
	return .None
}

@(private)
_run_path :: proc(rb: ^Rebuild, tag: string, n: int) -> (path: string, err: Error) {
	b := make([dynamic]u8, 0, len(rb.t.path) + 16, rb.t.allocator)
	append(&b, rb.t.path)
	append(&b, tag)
	x := n
	d: [20]u8
	k := len(d)
	for {
		k -= 1
		d[k] = u8('0' + x % 10)
		x /= 10
		if x == 0 {
			break
		}
	}
	append(&b, ..d[k:])
	if len(b) >= prim.PATH_MAX {
		delete(b)
		return "", .Invalid
	}
	return string(b[:]), .None
}

@(private)
_spill_entries :: proc(rb: ^Rebuild) -> Error {
	if len(rb.items) == 0 {
		return .None
	}
	slice.stable_sort_by(rb.items[:], proc(a, b: Run_Item) -> bool {
		return string(a.key) < string(b.key)
	})
	path := _run_path(rb, ".run", len(rb.runs)) or_return
	append(&rb.runs, path)
	w: Run_Writer
	_run_create(&w, rb.t.vfs, path, rb.t.allocator) or_return
	defer _run_close(&w)
	sa := virtual.arena_allocator(&rb.scratch)
	buf := make([dynamic]u8, rb.t.allocator)
	defer delete(buf)
	i := 0
	for i < len(rb.items) {
		j := i
		e := Entry{
			key = rb.items[i].key,
		}
		for j < len(rb.items) && string(rb.items[j].key) == string(e.key) {
			it := rb.items[j]
			seg := rb.sources[it.src].seg
			apply(&e, seg, Rid{seg, it.off}, it.body, sa)
			j += 1
		}
		clear(&buf)
		{
			context.temp_allocator = sa
			encode_entry(&buf, &e) or_return
		}
		_run_put(&w, e.key, buf[:]) or_return
		virtual.arena_free_all(&rb.scratch)
		i = j
	}
	_run_flush(&w) or_return
	clear(&rb.items)
	virtual.arena_free_all(&rb.batch)
	return .None
}

@(private)
_merge_runs :: proc(rb: ^Rebuild, paths: []string, data: rawptr, emit: proc(rb: ^Rebuild, data: rawptr, key: []u8, vals: [][]u8) -> Error) -> Error {
	readers := make([]Run_Reader, len(paths), rb.t.allocator)
	defer delete(readers, rb.t.allocator)
	opened := 0
	defer for i in 0 ..< opened {
		_run_reader_close(&readers[i])
	}
	for p, i in paths {
		_run_open(&readers[i], rb.t.vfs, p, rb.t.allocator) or_return
		opened += 1
		_run_next(&readers[i]) or_return
	}
	vals := make([dynamic][]u8, rb.t.allocator)
	defer delete(vals)
	key := make([dynamic]u8, rb.t.allocator)
	defer delete(key)
	for {
		best := -1
		for &r, i in readers {
			if r.done {
				continue
			}
			if best < 0 || string(r.key) < string(readers[best].key) {
				best = i
			}
		}
		if best < 0 {
			return .None
		}
		clear(&key)
		append(&key, ..readers[best].key)
		clear(&vals)
		a := virtual.arena_allocator(&rb.scratch)
		for &r in readers {
			for !r.done && string(r.key) == string(key[:]) {
				v := obj.clone_bytes(r.value, a) or_return
				append(&vals, v)
				_run_next(&r) or_return
			}
		}
		emit(rb, data, key[:], vals[:]) or_return
		virtual.arena_free_all(&rb.scratch)
	}
}

@(private)
_merge_entries :: proc(rb: ^Rebuild, b: ^Builder) -> Error {
	emit :: proc(rb: ^Rebuild, data: rawptr, key: []u8, vals: [][]u8) -> Error {
		b := (^Builder)(data)
		a := virtual.arena_allocator(&rb.scratch)
		context.temp_allocator = a
		e := decode_entry(key, vals[0], a) or_return
		for v in vals[1:] {
			x := decode_entry(key, v, a) or_return
			e = entry_join(&e, &x, a)
		}
		same := len(vals) == 1
		n := 0
		for el in e.elements {
			x := el
			if len(el.dead) > 0 {
				dead := make([dynamic]Rid, 0, len(el.dead), a)
				for r in el.dead {
					if !_rebuilt(rb, r) {
						append(&dead, r)
					}
				}
				same &&= len(dead) == len(el.dead)
				x.dead = dead[:]
			}
			if len(x.live) > 0 || len(x.dead) > 0 {
				e.elements[n] = x
				n += 1
			}
		}
		e.elements = e.elements[:n]
		if len(e.registers) == 0 && len(e.elements) == 0 {
			return .None
		}
		enc := vals[0]
		if !same {
			buf := make([dynamic]u8, a)
			encode_entry(&buf, &e) or_return
			enc = buf[:]
		}
		if entry_empty(&e) {
			return builder_add(b, ROOT_PENDING, key, enc)
		}
		builder_add(b, ROOT_ENTRIES, key, enc) or_return
		t := rb.t
		for i in 0 ..< t.ndefs {
			ik, ok := _index_key(t, i, &e, key)
			if !ok {
				continue
			}
			pv := make([dynamic]u8, a)
			if t.defs[i].project != nil {
				t.defs[i].project(t.defs[i].data, &e, &pv)
			}
			ba := virtual.arena_allocator(&rb.batch)
			k := make([]u8, len(ik) + 1, ba)
			k[0] = u8(i)
			copy(k[1:], ik)
			v := obj.clone_bytes(pv[:], ba) or_return
			if _, ae := append(&rb.items, Run_Item{key = k, data = v}); ae != nil {
				return .No_Memory
			}
		}
		if rb.batch.total_used >= RUN_BYTES {
			_spill_index(rb) or_return
		}
		return .None
	}
	return _merge_runs(rb, rb.runs[:], b, emit)
}

@(private)
_rebuilt :: proc(rb: ^Rebuild, r: Rid) -> bool {
	for s, i in rb.sources {
		if s.seg == r.seg {
			return r.off < rb.ends[i]
		}
	}
	return false
}

@(private)
_spill_index :: proc(rb: ^Rebuild) -> Error {
	if len(rb.items) == 0 {
		return .None
	}
	slice.sort_by(rb.items[:], proc(a, b: Run_Item) -> bool {
		return string(a.key) < string(b.key)
	})
	path := _run_path(rb, ".idx", len(rb.iruns)) or_return
	append(&rb.iruns, path)
	w: Run_Writer
	_run_create(&w, rb.t.vfs, path, rb.t.allocator) or_return
	defer _run_close(&w)
	for it in rb.items {
		_run_put(&w, it.key, it.data) or_return
	}
	_run_flush(&w) or_return
	clear(&rb.items)
	virtual.arena_free_all(&rb.batch)
	return .None
}

@(private)
_merge_index :: proc(rb: ^Rebuild, b: ^Builder) -> Error {
	emit :: proc(rb: ^Rebuild, data: rawptr, key: []u8, vals: [][]u8) -> Error {
		b := (^Builder)(data)
		if len(key) < 2 || int(key[0]) >= rb.t.ndefs {
			return .Corrupt
		}
		return builder_add(b, ROOT_INDEX + int(key[0]), key[1:], vals[0])
	}
	return _merge_runs(rb, rb.iruns[:], b, emit)
}

@(private)
Run_Writer :: struct {
	vfs: prim.Vfs,
	fd:  prim.Fd,
	buf: [dynamic]u8,
	off: i64,
}

@(private)
_run_create :: proc(w: ^Run_Writer, vfs: prim.Vfs, path: string, allocator: runtime.Allocator) -> Error {
	fd, e := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o600)
	if e != .None {
		return obj.perr(e)
	}
	w^ = {
		vfs = vfs,
		fd  = fd,
		buf = make([dynamic]u8, 0, RUN_IO, allocator),
	}
	return .None
}

@(private)
_run_put :: proc(w: ^Run_Writer, key: []u8, value: []u8) -> Error {
	p := prim.writer(&w.buf)
	prim.write_bytes(&p, key)
	prim.write_bytes(&p, value)
	if p.err != .None {
		return .No_Memory
	}
	if len(w.buf) >= RUN_IO {
		return _run_flush(w)
	}
	return .None
}

@(private)
_run_flush :: proc(w: ^Run_Writer) -> Error {
	if len(w.buf) == 0 {
		return .None
	}
	if e := prim.write_at(w.vfs, w.fd, w.buf[:], w.off); e != .None {
		return obj.perr(e)
	}
	w.off += i64(len(w.buf))
	clear(&w.buf)
	return .None
}

@(private)
_run_close :: proc(w: ^Run_Writer) {
	prim.close_file(w.vfs, w.fd)
	delete(w.buf)
}

@(private)
Run_Reader :: struct {
	vfs:   prim.Vfs,
	fd:    prim.Fd,
	buf:   [dynamic]u8,
	pos:   int,
	off:   i64,
	eof:   bool,
	done:  bool,
	key:   []u8,
	value: []u8,
}

@(private)
_run_open :: proc(r: ^Run_Reader, vfs: prim.Vfs, path: string, allocator: runtime.Allocator) -> Error {
	fd, e := prim.open_file(vfs, path)
	if e != .None {
		return obj.perr(e)
	}
	r^ = {
		vfs = vfs,
		fd  = fd,
		buf = make([dynamic]u8, 0, RUN_IO, allocator),
	}
	return .None
}

@(private)
_run_reader_close :: proc(r: ^Run_Reader) {
	prim.close_file(r.vfs, r.fd)
	delete(r.buf)
}

@(private)
_run_fill :: proc(r: ^Run_Reader, need: int) -> Error {
	if len(r.buf) - r.pos >= need || r.eof {
		return .None
	}
	rest := len(r.buf) - r.pos
	copy(r.buf[:], r.buf[r.pos:])
	resize(&r.buf, rest)
	r.pos = 0
	want := max(RUN_IO, need)
	if cap(r.buf) < want {
		reserve(&r.buf, want)
	}
	for len(r.buf) < need && !r.eof {
		n0 := len(r.buf)
		resize(&r.buf, cap(r.buf))
		n, e := prim.read_at(r.vfs, r.fd, r.buf[n0:], r.off)
		if e != .None {
			resize(&r.buf, n0)
			return obj.perr(e)
		}
		resize(&r.buf, n0 + n)
		r.off += i64(n)
		if n == 0 {
			r.eof = true
		}
	}
	return .None
}

@(private)
_run_next :: proc(r: ^Run_Reader) -> Error {
	_run_fill(r, 20) or_return
	if r.pos == len(r.buf) {
		r.done = true
		return .None
	}
	hdr := prim.reader(r.buf[r.pos:])
	kl := prim.read_uvarint(&hdr)
	if hdr.err != .None || kl > MAX_KEY {
		return .Corrupt
	}
	h1 := prim.uvarint_len(kl)
	_run_fill(r, h1 + int(kl) + 10) or_return
	hdr = prim.reader(r.buf[r.pos + h1 + int(kl):])
	vl := prim.read_uvarint(&hdr)
	if hdr.err != .None || vl > MAX_VALUE {
		return .Corrupt
	}
	h2 := prim.uvarint_len(vl)
	total := h1 + int(kl) + h2 + int(vl)
	_run_fill(r, total) or_return
	if len(r.buf) - r.pos < total {
		return .Corrupt
	}
	b := r.buf[r.pos:]
	r.key = b[h1:][:kl]
	r.value = b[h1 + int(kl) + h2:][:vl]
	r.pos += total
	return .None
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
	root := ROOT_ENTRIES
	old, found := txn_get(txn, ROOT_ENTRIES, key, context.temp_allocator) or_return
	if !found {
		old, found = txn_get(txn, ROOT_PENDING, key, context.temp_allocator) or_return
		root = ROOT_PENDING
	}
	e := decode_entry(key, old if found else nil) or_return
	olds: [MAX_INDEXES][]u8
	oldok: [MAX_INDEXES]bool
	if found && root == ROOT_ENTRIES {
		for i in 0 ..< t.ndefs {
			olds[i], oldok[i] = _index_key(t, i, &e, key)
		}
	}
	changed := apply(&e, seg, Rid{seg, off}, b)
	pruned := _prune(txn, &e, seg, off) or_return
	if !changed && !pruned {
		return .None
	}
	gone := len(e.registers) == 0 && len(e.elements) == 0
	empty := entry_empty(&e)
	dest := -1 if gone else (ROOT_PENDING if empty else ROOT_ENTRIES)
	if found && root != dest {
		txn_delete(txn, root, key) or_return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	if dest >= 0 {
		encode_entry(&buf, &e) or_return
		txn_put(txn, dest, key, buf[:]) or_return
	}
	for i in 0 ..< t.ndefs {
		nk: []u8
		nok := false
		if dest == ROOT_ENTRIES {
			nk, nok = _index_key(t, i, &e, key)
		}
		if oldok[i] && (!nok || string(nk) != string(olds[i])) {
			txn_delete(txn, ROOT_INDEX + i, olds[i]) or_return
		}
		if nok {
			pv := make([dynamic]u8, context.temp_allocator)
			if t.defs[i].project != nil {
				t.defs[i].project(t.defs[i].data, &e, &pv)
			}
			txn_put(txn, ROOT_INDEX + i, nk, pv[:]) or_return
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

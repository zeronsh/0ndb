package search

import "../prim"

position :: proc(ix: ^Index, source: prim.Id) -> (pos: i64, err: Error) {
	if v, ok := ix.mem.sources[source]; ok {
		return v, .None
	}
	for i := len(ix.segs) - 1; i >= 0; i -= 1 {
		p, found := src_lookup(&ix.cache, &ix.segs[i], source) or_return
		if found {
			return p, .None
		}
	}
	return 0, .None
}

pending :: proc "contextless" (ix: ^Index) -> int {
	return mem_bytes(&ix.mem)
}

TITLE_SLOT :: "\x00title"

add :: proc(ix: ^Index, source: prim.Id, pos: i64, doc: ^Doc) -> Error {
	_admit(ix) or_return
	if len(doc.slot) > 0 {
		_kill_slot(ix, doc.object, doc.slot) or_return
	}
	id := mem_add(ix, doc) or_return
	if len(doc.slot) > 0 {
		key: [MAX_KEY]u8
		n := slot_key(doc.object, doc.slot, &key)
		if v, found := &ix.mem.slots[string(key[:n])]; found {
			v^ = id
		} else {
			k := make([]u8, n, ix.mem.allocator)
			copy(k, key[:n])
			ix.mem.slots[string(k)] = id
		}
	}
	ix.mem.sources[source] = pos
	return _maybe_flush(ix)
}

advance :: proc(ix: ^Index, source: prim.Id, pos: i64) -> Error {
	_admit(ix) or_return
	ix.mem.sources[source] = pos
	return _maybe_flush(ix)
}

set_title :: proc(ix: ^Index, source: prim.Id, pos: i64, object: prim.Id, participant: prim.Id, hlc: prim.Hlc, kind: u8, title: string) -> Error {
	d := Doc {
		object      = object,
		participant = participant,
		kind        = kind,
		title       = true,
		slot        = transmute([]u8)string(TITLE_SLOT),
		hlc         = hlc,
		text        = transmute([]u8)title,
	}
	return add(ix, source, pos, &d)
}

delete_slot :: proc(ix: ^Index, source: prim.Id, pos: i64, object: prim.Id, slot: []u8) -> Error {
	_admit(ix) or_return
	_kill_slot(ix, object, slot) or_return
	ix.mem.sources[source] = pos
	return _maybe_flush(ix)
}

delete_object :: proc(ix: ^Index, source: prim.Id, pos: i64, object: prim.Id) -> Error {
	_admit(ix) or_return
	m := &ix.mem
	if oi, ok := m.id_map[object]; ok {
		for d, i in m.docs {
			if d.object == oi {
				mem_kill(m, u32(m.base) + u32(i))
			}
		}
	}
	key: [17]u8
	key[0] = NS_OBJECT
	o := object
	copy(key[1:], o[:])
	_kill_term(ix, key[:], nil) or_return
	m.sources[source] = pos
	return _maybe_flush(ix)
}

delete_content :: proc(ix: ^Index, source: prim.Id, pos: i64, object: prim.Id) -> Error {
	_admit(ix) or_return
	m := &ix.mem
	if oi, ok := m.id_map[object]; ok {
		for d, i in m.docs {
			if d.object == oi && d.flags & DF_TITLE == 0 {
				mem_kill(m, u32(m.base) + u32(i))
			}
		}
	}
	key: [17]u8
	key[0] = NS_OBJECT
	o := object
	copy(key[1:], o[:])
	_kill_term(ix, key[:], nil, true) or_return
	m.sources[source] = pos
	return _maybe_flush(ix)
}

delete_record :: proc(ix: ^Index, source: prim.Id, pos: i64, object: prim.Id, ref: []u8) -> Error {
	_admit(ix) or_return
	m := &ix.mem
	if oi, ok := m.id_map[object]; ok {
		for d, i in m.docs {
			if d.object == oi && string(m.refs[d.ref_off:][:d.ref_len]) == string(ref) {
				mem_kill(m, u32(m.base) + u32(i))
			}
		}
	}
	key: [17]u8
	key[0] = NS_OBJECT
	o := object
	copy(key[1:], o[:])
	_kill_term(ix, key[:], ref) or_return
	ix.taint_check = true
	m.sources[source] = pos
	return _maybe_flush(ix)
}

redact :: proc(ix: ^Index, source: prim.Id, pos: i64, object: prim.Id, ref: []u8) -> Error {
	delete_record(ix, source, pos, object, ref) or_return
	return erase(ix)
}

erase :: proc(ix: ^Index) -> Error {
	flush(ix) or_return
	for {
		more := purge_step(ix, max(i64)) or_return
		if !more {
			break
		}
	}
	for {
		more := redact_models(ix) or_return
		if !more {
			return .None
		}
		_ = _merge_step(ix, max(i64), false) or_return
	}
}

@(private)
_kill_slot :: proc(ix: ^Index, object: prim.Id, slot: []u8) -> Error {
	m := &ix.mem
	key: [MAX_KEY]u8
	n := slot_key(object, slot, &key)
	if old, ok := m.slots[string(key[:n])]; ok {
		mem_kill(m, old)
	}
	return _kill_term(ix, key[:n], nil)
}

set_spans :: proc(ix: ^Index, source: prim.Id, pos: i64, file: []u8, spans: []Span) -> Error {
	_admit(ix) or_return
	if len(file) == 0 || len(file) > MAX_FILE_KEY {
		return .Invalid
	}
	m := &ix.mem
	val := encode_spans(spans, m.allocator) or_return
	if old, ok := m.files[string(file)]; ok {
		m.kv_bytes -= len(old)
		delete(old, m.allocator)
		m.files[string(file)] = val
	} else {
		k := make([]u8, len(file), m.allocator)
		copy(k, file)
		m.files[string(k)] = val
		m.kv_bytes += len(k) + 64
	}
	m.kv_bytes += len(val)
	m.sources[source] = pos
	return _maybe_flush(ix)
}

add_scope :: proc(ix: ^Index, source: prim.Id, pos: i64, sc: Scope) -> Error {
	_admit(ix) or_return
	if len(sc.ref) > MAX_REF {
		return .Invalid
	}
	m := &ix.mem
	out := make([dynamic]u8, 0, 32 + len(sc.ref), m.allocator)
	w := prim.writer(&out)
	prim.write_id(&w, sc.object)
	prim.write_u64le(&w, u64(sc.hlc))
	prim.write_bytes(&w, sc.ref)
	if w.err != .None {
		delete(out)
		return .No_Memory
	}
	if old, ok := m.scopes[sc.id]; ok {
		m.kv_bytes -= len(old)
		delete(old, m.allocator)
	} else {
		m.kv_bytes += 64
	}
	m.scopes[sc.id] = out[:]
	m.kv_bytes += len(out)
	m.sources[source] = pos
	return _maybe_flush(ix)
}

flush :: proc(ix: ^Index) -> Error {
	if ix.broken {
		return .Corrupt
	}
	if mem_ahead(ix) {
		return .Busy
	}
	before := len(ix.segs)
	mem_flush(ix) or_return
	vec_maybe_train(ix) or_return
	if len(ix.segs) > before {
		size := ix.segs[len(ix.segs) - 1].size
		_, err := _merge_step(ix, size * i64(ix.opts.pace), false)
		return err
	}
	return .None
}

@(private)
_maybe_flush :: proc(ix: ^Index) -> Error {
	n := mem_bytes(&ix.mem)
	if n < ix.opts.budget {
		return .None
	}
	if mem_ahead(ix) {
		return .None
	}
	return flush(ix)
}

@(private)
_admit :: proc(ix: ^Index) -> Error {
	if mem_bytes(&ix.mem) >= AHEAD_LIMIT * ix.opts.budget && mem_ahead(ix) {
		return .Busy
	}
	return .None
}

AHEAD_LIMIT :: 4

mem_ahead :: proc(ix: ^Index) -> bool {
	if ix.opts.durable == nil {
		return false
	}
	for src, p in ix.mem.sources {
		if p > ix.opts.durable(ix.opts.durable_data, src) {
			return true
		}
	}
	return false
}

durable_advanced :: proc(ix: ^Index) -> Error {
	if mem_bytes(&ix.mem) >= ix.opts.budget && !mem_ahead(ix) {
		return flush(ix)
	}
	return .None
}

@(private)
_reconcile :: proc(ix: ^Index) -> (reset_needed: bool, err: Error) {
	if ix.opts.durable == nil {
		return false, .None
	}
	b: [SRC_ENTRY]u8
	for &s in ix.segs {
		n := s.f.src_len / SRC_ENTRY
		for k in 0 ..< n {
			cache_read(&ix.cache, &s, s.f.src_off + k * SRC_ENTRY, b[:]) or_return
			src: prim.Id
			copy(src[:], b[:16])
			if i64(prim.get_u64le(b[16:])) > ix.opts.durable(ix.opts.durable_data, src) {
				return true, .None
			}
		}
	}
	return false, .None
}

@(private)
_kill_term :: proc(ix: ^Index, key: []u8, ref: []u8, keep_titles := false) -> Error {
	blk: Doc_Block
	db_init(&blk, context.temp_allocator)
	for &s in ix.segs {
		dix := dix_load(&ix.cache, &s, context.temp_allocator) or_return
		dc: Dict_Cursor
		dc_init(&dc, &ix.cache, &s, &dix, context.temp_allocator)
		tt, found := term_lookup(&dc, key) or_return
		if !found {
			continue
		}
		a := new(Plist, context.temp_allocator)
		pl_init(a, &ix.cache, &s, tt)
		x := u32(max(u32))
		for {
			v, ok := pl_seek(a, x)
			if !ok {
				break
			}
			kill := true
			if ref != nil || keep_titles {
				doc_load(&ix.cache, &s, &blk, u64(v) / DOC_BLOCK) or_return
				dm := blk.docs[v - blk.first]
				kill = (ref == nil || string(dm.ref) == string(ref)) && (!keep_titles || dm.flags & DF_TITLE == 0)
			}
			if kill {
				mem_kill(&ix.mem, v)
			}
			if v == 0 {
				break
			}
			x = v - 1
		}
		if a.err != .None {
			return a.err
		}
	}
	return .None
}

encode_spans :: proc(spans: []Span, allocator := context.allocator) -> (val: []u8, err: Error) {
	scopes := make([dynamic]prim.Id, context.temp_allocator)
	idx := make([]u32, len(spans), context.temp_allocator)
	for sp, i in spans {
		found := -1
		for s, k in scopes {
			if s == sp.scope {
				found = k
				break
			}
		}
		if found < 0 {
			found = len(scopes)
			append(&scopes, sp.scope)
		}
		idx[i] = u32(found)
		if sp.byte_hi < sp.byte_lo || sp.line_hi < sp.line_lo {
			return nil, .Invalid
		}
	}
	out := make([dynamic]u8, allocator)
	if len(spans) == 0 {
		return out[:], .None
	}
	w := prim.writer(&out)
	prim.write_uvarint(&w, u64(len(scopes)))
	for s in scopes {
		prim.write_id(&w, s)
	}
	prim.write_uvarint(&w, u64(len(spans)))
	pb := u64(0)
	pl := i64(0)
	for sp, i in spans {
		prim.write_ivarint(&w, i64(sp.byte_lo) - i64(pb))
		prim.write_uvarint(&w, sp.byte_hi - sp.byte_lo)
		prim.write_ivarint(&w, i64(sp.line_lo) - pl)
		prim.write_uvarint(&w, u64(sp.line_hi - sp.line_lo))
		prim.write_uvarint(&w, u64(idx[i]))
		pb = sp.byte_hi
		pl = i64(sp.line_lo)
	}
	if w.err != .None {
		delete(out)
		return nil, .No_Memory
	}
	return out[:], .None
}

decode_spans :: proc(val: []u8, out: ^[dynamic]Span) -> Error {
	clear(out)
	if len(val) == 0 {
		return .None
	}
	r := prim.reader(val)
	ns := prim.read_uvarint(&r)
	if ns > u64(len(val)) {
		return .Corrupt
	}
	scopes := make([]prim.Id, int(ns), context.temp_allocator)
	for i in 0 ..< int(ns) {
		scopes[i] = prim.read_id(&r)
	}
	n := prim.read_uvarint(&r)
	if n > u64(len(val)) {
		return .Corrupt
	}
	pb := i64(0)
	pl := i64(0)
	for _ in 0 ..< n {
		blo := pb + prim.read_ivarint(&r)
		blen := prim.read_uvarint(&r)
		llo := pl + prim.read_ivarint(&r)
		llen := prim.read_uvarint(&r)
		si := prim.read_uvarint(&r)
		if r.err != .None || si >= ns || blo < 0 || llo < 0 || llo + i64(llen) > i64(max(u32)) || blen > 1 << 48 {
			return .Corrupt
		}
		append(out, Span{byte_lo = u64(blo), byte_hi = u64(blo) + blen, line_lo = u32(llo), line_hi = u32(llo + i64(llen)), scope = scopes[si]})
		pb = blo + i64(blen)
		pl = llo
	}
	if !prim.reader_done(&r) {
		return .Corrupt
	}
	return .None
}

Unit :: enum u8 {
	Lines,
	Bytes,
}

Wrote_Hit :: struct {
	scope:  prim.Id,
	object: prim.Id,
	ref:    []u8,
	hlc:    prim.Hlc,
	lo:     u64,
	hi:     u64,
	known:  bool,
}

wrote :: proc(ix: ^Index, file: []u8, unit: Unit, lo, hi: u64, allocator := context.allocator) -> (hits: []Wrote_Hit, err: Error) {
	val, found := ix.mem.files[string(file)]
	for i := len(ix.segs) - 1; i >= 0 && !found; i -= 1 {
		val, found = kv_get(&ix.segs[i], .Files, file, context.temp_allocator) or_return
	}
	if !found {
		return nil, .None
	}
	spans := make([dynamic]Span, context.temp_allocator)
	decode_spans(val, &spans) or_return
	out := make([dynamic]Wrote_Hit, allocator)
	for sp in spans {
		a, b: u64
		switch unit {
		case .Lines:
			a, b = u64(sp.line_lo), u64(sp.line_hi)
		case .Bytes:
			a, b = sp.byte_lo, sp.byte_hi
		}
		if b <= lo || a >= hi {
			continue
		}
		merged := false
		for &h in out {
			if h.scope == sp.scope {
				h.lo = min(h.lo, a)
				h.hi = max(h.hi, b)
				merged = true
				break
			}
		}
		if !merged {
			append(&out, Wrote_Hit{scope = sp.scope, lo = a, hi = b})
		}
	}
	for &h in out {
		sid := h.scope
		mv, mok := ix.mem.scopes[sid]
		for i := len(ix.segs); i >= 0; i -= 1 {
			v: []u8
			ok: bool
			if i == len(ix.segs) {
				v, ok = mv, mok
			} else {
				v, ok = kv_get(&ix.segs[i], .Scopes, sid[:], context.temp_allocator) or_return
			}
			if !ok {
				continue
			}
			r := prim.reader(v)
			h.object = prim.read_id(&r)
			h.hlc = prim.Hlc(prim.read_u64le(&r))
			ref := prim.read_bytes(&r)
			if !prim.reader_done(&r) {
				return out[:], .Corrupt
			}
			h.ref = make([]u8, len(ref), allocator)
			copy(h.ref, ref)
			h.known = true
			break
		}
	}
	return out[:], .None
}

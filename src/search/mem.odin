package search

import "base:runtime"
import "core:math"
import "core:slice"
import "../prim"

MCHUNK :: 32
MCHUNK_DATA :: MCHUNK - 4

Mem_Term :: struct {
	key:   u64,
	koff:  u32,
	last:  u32,
	prev:  u32,
	count: u32,
	head:  u32,
	tail:  u32,
	acc:   u16,
	used:  u8,
	klen:  u8,
}

Mem_Doc :: struct {
	hlc:        u64,
	chunk:      u64,
	frame:      u32,
	object:     u32,
	part_id:    u32,
	ref_off:    u32,
	part:       u32,
	len:        u32,
	fields_off: u32,
	frame_off:  u32,
	ref_len:    u8,
	nfields:    u8,
	kind:       u8,
	flags:      u8,
}

Mem :: struct {
	allocator: runtime.Allocator,
	base:      u64,
	terms:     [dynamic]Mem_Term,
	tfix:      []u32,
	tfix_n:    int,
	doc_words: [dynamic]u32,
	tlong:     []u32,
	tlong_n:   int,
	karena:    [dynamic]u8,
	chunks:    [dynamic]u8,
	docs:      [dynamic]Mem_Doc,
	refs:      [dynamic]u8,
	ids:       [dynamic]prim.Id,
	id_map:    map[prim.Id]u32,
	strs:      [dynamic][]u8,
	str_map:   map[string]u32,
	fidx:      [dynamic][2]u32,
	vids:      [dynamic]u32,
	vecs:      [dynamic]f32,
	slots:     map[string]u32,
	raw:       [dynamic]u8,
	frames:    [dynamic]u32,
	scratch:   [dynamic]u8,
	sources:   map[prim.Id]i64,
	dead:      [dynamic]u32,
	files:     map[string][]u8,
	scopes:    map[prim.Id][]u8,
	kv_bytes:  int,
	total_len: u64,
	fold:      [dynamic]u8,
}

mem_init :: proc(m: ^Mem, allocator: runtime.Allocator) -> Error {
	m^ = {
		allocator = allocator,
	}
	m.terms = make([dynamic]Mem_Term, allocator)
	m.doc_words = make([dynamic]u32, allocator)
	m.karena = make([dynamic]u8, allocator)
	m.chunks = make([dynamic]u8, allocator)
	m.docs = make([dynamic]Mem_Doc, allocator)
	m.refs = make([dynamic]u8, allocator)
	m.ids = make([dynamic]prim.Id, allocator)
	m.id_map = make(map[prim.Id]u32, allocator)
	m.strs = make([dynamic][]u8, allocator)
	m.str_map = make(map[string]u32, allocator)
	m.fidx = make([dynamic][2]u32, allocator)
	m.vids = make([dynamic]u32, allocator)
	m.vecs = make([dynamic]f32, allocator)
	m.slots = make(map[string]u32, allocator)
	m.raw = make([dynamic]u8, allocator)
	m.frames = make([dynamic]u32, allocator)
	m.scratch = make([dynamic]u8, allocator)
	m.sources = make(map[prim.Id]i64, allocator)
	m.dead = make([dynamic]u32, allocator)
	m.files = make(map[string][]u8, allocator)
	m.scopes = make(map[prim.Id][]u8, allocator)
	m.fold = make([dynamic]u8, allocator)
	return _mem_tables(m, 1 << 12, 1 << 8)
}

@(private)
_mem_tables :: proc(m: ^Mem, nfix, nlong: int) -> Error {
	delete(m.tfix, m.allocator)
	delete(m.tlong, m.allocator)
	err: runtime.Allocator_Error
	m.tfix, err = make([]u32, nfix, m.allocator)
	if err != nil {
		return .No_Memory
	}
	m.tlong, err = make([]u32, nlong, m.allocator)
	if err != nil {
		return .No_Memory
	}
	m.tfix_n = 0
	m.tlong_n = 0
	return .None
}

mem_destroy :: proc(m: ^Mem) {
	mem_reset(m, 0)
	delete(m.terms)
	delete(m.doc_words)
	delete(m.tfix, m.allocator)
	delete(m.tlong, m.allocator)
	delete(m.karena)
	delete(m.chunks)
	delete(m.docs)
	delete(m.refs)
	delete(m.ids)
	delete(m.id_map)
	delete(m.strs)
	delete(m.str_map)
	delete(m.fidx)
	delete(m.vids)
	delete(m.vecs)
	delete(m.slots)
	delete(m.raw)
	delete(m.frames)
	delete(m.scratch)
	delete(m.sources)
	delete(m.dead)
	delete(m.files)
	delete(m.scopes)
	delete(m.fold)
	m^ = {}
}

mem_reset :: proc(m: ^Mem, base: u64) {
	m.base = base
	clear(&m.terms)
	for &e in m.tfix {
		e = 0
	}
	for &e in m.tlong {
		e = 0
	}
	m.tfix_n = 0
	m.tlong_n = 0
	clear(&m.doc_words)
	clear(&m.karena)
	clear(&m.chunks)
	clear(&m.docs)
	clear(&m.refs)
	clear(&m.ids)
	clear(&m.id_map)
	for s in m.strs {
		delete(s, m.allocator)
	}
	clear(&m.strs)
	clear(&m.str_map)
	clear(&m.fidx)
	clear(&m.vids)
	clear(&m.vecs)
	for k in m.slots {
		delete(k, m.allocator)
	}
	clear(&m.slots)
	clear(&m.raw)
	clear(&m.frames)
	clear(&m.sources)
	clear(&m.dead)
	for k, v in m.files {
		delete(k, m.allocator)
		delete(v, m.allocator)
	}
	clear(&m.files)
	for _, v in m.scopes {
		delete(v, m.allocator)
	}
	clear(&m.scopes)
	m.kv_bytes = 0
	m.total_len = 0
	if cap(m.chunks) > 64 * 1024 * 1024 {
		shrink(&m.chunks, 0)
	}
}

mem_bytes :: proc "contextless" (m: ^Mem) -> int {
	return(
		len(m.chunks) +
		len(m.terms) * size_of(Mem_Term) +
		(len(m.tfix) + len(m.tlong)) * 4 +
		len(m.docs) * size_of(Mem_Doc) +
		len(m.refs) +
		len(m.karena) +
		len(m.raw) +
		len(m.frames) * 4 +
		len(m.fidx) * 8 +
		len(m.vids) * 4 +
		len(m.vecs) * 4 +
		len(m.slots) * 64 +
		len(m.ids) * 16 +
		m.kv_bytes \
	)
}

mem_empty :: proc "contextless" (m: ^Mem) -> bool {
	return len(m.docs) == 0 && len(m.sources) == 0 && len(m.dead) == 0 && len(m.files) == 0 && len(m.scopes) == 0
}

@(private)
_hash64 :: #force_inline proc "contextless" (k: u64) -> u32 {
	return u32((k * 0x9E3779B97F4A7C15) >> 32)
}

@(private)
_chain_put :: #force_inline proc(m: ^Mem, ti: u32, v: u64) -> Error #no_bounds_check {
	buf: [10]u8
	n := prim.put_uvarint(buf[:], v)
	t := &m.terms[ti]
	for k in 0 ..< n {
		if t.head == 0 && t.count == 0 || t.used == MCHUNK_DATA {
			at := u32(len(m.chunks) / MCHUNK)
			if grow(&m.chunks, len(m.chunks) + MCHUNK) != nil {
				return .No_Memory
			}
			t = &m.terms[ti]
			prim.put_u32le(m.chunks[int(at) * MCHUNK:], 0)
			if t.head == 0 && t.count == 0 {
				t.head = at + 1
			} else {
				prim.put_u32le(m.chunks[int(t.tail - 1) * MCHUNK:], at + 1)
			}
			t.tail = at + 1
			t.used = 0
		}
		m.chunks[int(t.tail - 1) * MCHUNK + 4 + int(t.used)] = buf[k]
		t.used += 1
	}
	return .None
}

@(private)
_post_term :: #force_inline proc(m: ^Mem, ti: u32, id: u32) -> Error #no_bounds_check {
	t := &m.terms[ti]
	if t.last == id + 1 {
		return .None
	}
	delta := id + 1 - t.last
	t.last = id + 1
	_chain_put(m, ti, u64(delta)) or_return
	m.terms[ti].count += 1
	return .None
}

@(private)
_post_word :: #force_inline proc(m: ^Mem, ti: u32, id: u32) -> Error #no_bounds_check {
	t := &m.terms[ti]
	if t.last == id + 1 {
		if t.acc < max(u16) {
			t.acc += 1
		}
		return .None
	}
	t.last = id + 1
	t.acc = 1
	if _, e := append(&m.doc_words, ti); e != nil {
		return .No_Memory
	}
	return .None
}

@(private)
_end_doc :: proc(m: ^Mem, id: u32) -> Error {
	for ti in m.doc_words {
		t := &m.terms[ti]
		delta := id + 1 - t.prev
		t.prev = id + 1
		acc := t.acc
		_chain_put(m, ti, u64(delta)) or_return
		_chain_put(m, ti, u64(acc)) or_return
		m.terms[ti].count += 1
	}
	clear(&m.doc_words)
	return .None
}

@(private)
_find_fix :: proc(m: ^Mem, key: u64) -> (ti: u32, found: bool) #no_bounds_check {
	mask := u32(len(m.tfix) - 1)
	h := _hash64(key) & mask
	for {
		e := m.tfix[h]
		if e == 0 {
			return 0, false
		}
		if m.terms[e - 1].key == key {
			return e - 1, true
		}
		h = (h + 1) & mask
	}
}

@(private)
_term_fix :: proc(m: ^Mem, key: u64) -> (ti: u32, err: Error) #no_bounds_check {
	mask := u32(len(m.tfix) - 1)
	h := _hash64(key) & mask
	for {
		e := m.tfix[h]
		if e == 0 {
			break
		}
		if m.terms[e - 1].key == key {
			return e - 1, .None
		}
		h = (h + 1) & mask
	}
	if (m.tfix_n + 1) * 2 > len(m.tfix) {
		_grow_fix(m) or_return
		return _term_fix(m, key)
	}
	ti = u32(len(m.terms))
	if _, e := append(&m.terms, Mem_Term{key = key}); e != nil {
		return 0, .No_Memory
	}
	m.tfix[h] = ti + 1
	m.tfix_n += 1
	return ti, .None
}

@(private)
_post_fix :: #force_inline proc(m: ^Mem, key: u64, id: u32) -> Error {
	ti := _term_fix(m, key) or_return
	return _post_term(m, ti, id)
}

@(private)
_grow_fix :: proc(m: ^Mem) -> Error {
	n := len(m.tfix) * 2
	nt, err := make([]u32, n, m.allocator)
	if err != nil {
		return .No_Memory
	}
	mask := u32(n - 1)
	for e in m.tfix {
		if e == 0 {
			continue
		}
		h := _hash64(m.terms[e - 1].key) & mask
		for nt[h] != 0 {
			h = (h + 1) & mask
		}
		nt[h] = e
	}
	delete(m.tfix, m.allocator)
	m.tfix = nt
	return .None
}

@(private)
_hash_bytes :: proc "contextless" (b: []u8) -> u32 {
	h := u64(0xcbf29ce484222325)
	for c in b {
		h = (h ~ u64(c)) * 0x100000001b3
	}
	return u32(h ~ (h >> 32))
}

@(private)
_long_key :: proc(m: ^Mem, t: ^Mem_Term) -> []u8 {
	return m.karena[t.koff:][:t.klen]
}

@(private)
_find_long :: proc(m: ^Mem, key: []u8) -> (ti: u32, found: bool) {
	mask := u32(len(m.tlong) - 1)
	h := _hash_bytes(key) & mask
	for {
		e := m.tlong[h]
		if e == 0 {
			return 0, false
		}
		if string(_long_key(m, &m.terms[e - 1])) == string(key) {
			return e - 1, true
		}
		h = (h + 1) & mask
	}
}

@(private)
_term_long :: proc(m: ^Mem, key: []u8) -> (ti: u32, err: Error) {
	mask := u32(len(m.tlong) - 1)
	h := _hash_bytes(key) & mask
	for {
		e := m.tlong[h]
		if e == 0 {
			break
		}
		if string(_long_key(m, &m.terms[e - 1])) == string(key) {
			return e - 1, .None
		}
		h = (h + 1) & mask
	}
	if (m.tlong_n + 1) * 2 > len(m.tlong) {
		n := len(m.tlong) * 2
		nt, aerr := make([]u32, n, m.allocator)
		if aerr != nil {
			return 0, .No_Memory
		}
		nmask := u32(n - 1)
		for e in m.tlong {
			if e == 0 {
				continue
			}
			hh := _hash_bytes(_long_key(m, &m.terms[e - 1])) & nmask
			for nt[hh] != 0 {
				hh = (hh + 1) & nmask
			}
			nt[hh] = e
		}
		delete(m.tlong, m.allocator)
		m.tlong = nt
		return _term_long(m, key)
	}
	ti = u32(len(m.terms))
	koff := u32(len(m.karena))
	if _, e := append(&m.karena, ..key); e != nil {
		return 0, .No_Memory
	}
	if _, e := append(&m.terms, Mem_Term{koff = koff, klen = u8(len(key))}); e != nil {
		return 0, .No_Memory
	}
	m.tlong[h] = ti + 1
	m.tlong_n += 1
	return ti, .None
}

@(private)
_post_long :: proc(m: ^Mem, key: []u8, id: u32) -> Error {
	ti := _term_long(m, key) or_return
	return _post_term(m, ti, id)
}

mem_term_key :: proc(m: ^Mem, t: ^Mem_Term, out: ^[MAX_KEY]u8) -> []u8 {
	if t.klen > 0 {
		n := copy(out[:], _long_key(m, t))
		return out[:n]
	}
	kb: [8]u8
	n := key64_bytes(t.key, &kb)
	copy(out[:], kb[:n])
	return out[:n]
}

mem_term_vk :: proc "contextless" (m: ^Mem, t: ^Mem_Term) -> u8 {
	if t.klen > 0 {
		return val_kind(m.karena[t.koff])
	}
	return val_kind(u8(t.key >> 56))
}

@(private)
_intern :: proc(m: ^Mem, id: prim.Id) -> (u32, Error) {
	if v, ok := m.id_map[id]; ok {
		return v, .None
	}
	i := u32(len(m.ids))
	if _, e := append(&m.ids, id); e != nil {
		return 0, .No_Memory
	}
	m.id_map[id] = i
	return i, .None
}

@(private)
_intern_bytes :: proc(m: ^Mem, s: []u8) -> (u32, Error) {
	if v, ok := m.str_map[string(s)]; ok {
		return v, .None
	}
	c, err := make([]u8, len(s), m.allocator)
	if err != nil {
		return 0, .No_Memory
	}
	copy(c, s)
	i := u32(len(m.strs))
	append(&m.strs, c)
	m.str_map[string(c)] = i
	m.kv_bytes += len(s) + 48
	return i, .None
}

@(private)
_frame_end :: proc "contextless" (m: ^Mem, k: int) -> int {
	return int(m.frames[k + 1]) if k + 1 < len(m.frames) else len(m.raw)
}

mem_add :: proc(ix: ^Index, d: ^Doc) -> (first: u32, err: Error) {
	m := &ix.mem
	if len(d.ref) > MAX_REF || len(d.fields) > MAX_FIELDS || len(d.slot) > MAX_SLOT {
		return 0, .Invalid
	}
	for f in d.fields {
		if len(f.name) == 0 || len(f.name) > MAX_NAME || len(f.value) > MAX_PATH {
			return 0, .Invalid
		}
	}
	vec: []f32
	if (d.vector != nil || d.embed) && !ix.bare {
		dim := ix.opts.embedder.dim
		if dim <= 0 || (d.vector != nil && len(d.vector) != dim) {
			return 0, .Invalid
		}
		v := make([]f32, dim, context.temp_allocator)
		if d.vector != nil {
			copy(v, d.vector)
		} else {
			t := d.text[:min(len(d.text), CHUNK)]
			if ix.opts.embedder.embed == nil || !ix.opts.embedder.embed(ix.opts.embedder.data, d.kind, t, v) {
				return 0, .Missing
			}
		}
		if !normalize(v) {
			return 0, .Invalid
		}
		vec = v
	}
	first = u32(m.base + u64(len(m.docs)))
	total := len(d.text)
	if total == 0 {
		_mem_chunk(ix, d, 0, nil, false) or_return
	} else {
		start := 0
		for start < total {
			end := min(start + CHUNK, total)
			_mem_chunk(ix, d, u64(start), d.text[start:end], total > CHUNK) or_return
			if end == total {
				break
			}
			start = end - MAX_TERM
		}
	}
	if d.embed || d.vector != nil {
		m.docs[u64(first) - m.base].flags |= DF_EMBED
	}
	if vec != nil {
		if _, e := append(&m.vids, first); e != nil {
			return 0, .No_Memory
		}
		if _, e := append(&m.vecs, ..vec); e != nil {
			return 0, .No_Memory
		}
	}
	return first, .None
}

substring_field :: proc(ix: ^Index, name: []u8) -> bool {
	for f in ix.opts.substring_fields {
		if len(f) == len(name) {
			eq := true
			for i in 0 ..< len(f) {
				if fold(f[i]) != fold(name[i]) {
					eq = false
					break
				}
			}
			if eq {
				return true
			}
		}
	}
	return false
}

field_key :: proc(ns: u8, name: []u8, value: []u8, out: ^[MAX_KEY]u8) -> (n: int, ok: bool) {
	if 2 + len(name) + len(value) > MAX_KEY {
		return 0, false
	}
	out[0] = ns
	n = 1
	for c in name {
		out[n] = fold(c)
		n += 1
	}
	out[n] = 0
	n += 1
	for c in value {
		out[n] = fold(c)
		n += 1
	}
	return n, true
}

slot_key :: proc(object: prim.Id, slot: []u8, out: ^[MAX_KEY]u8) -> int {
	out[0] = NS_SLOT
	o := object
	copy(out[1:], o[:])
	return 17 + copy(out[17:], slot)
}

@(private)
_mem_chunk :: proc(ix: ^Index, d: ^Doc, offset: u64, text: []u8, chunked: bool) -> Error {
	m := &ix.mem
	gid := m.base + u64(len(m.docs))
	if gid >= MAX_DOCS {
		return .Full
	}
	id := u32(gid)
	md := Mem_Doc {
		hlc     = u64(d.hlc),
		chunk   = offset,
		part    = d.part,
		len     = u32(len(text)),
		kind    = d.kind,
		ref_len = u8(len(d.ref)),
		ref_off = u32(len(m.refs)),
	}
	md.object = _intern(m, d.object) or_return
	md.part_id = _intern(m, d.participant) or_return
	if _, e := append(&m.refs, ..d.ref); e != nil {
		return .No_Memory
	}
	if chunked {
		md.flags |= DF_CHUNK
	}
	if len(d.slot) > 0 {
		md.flags |= DF_SLOT
	}
	if d.title {
		md.flags |= DF_TITLE
		if !ix.bare {
			_post_fix(m, key64(NS_TITLE, 1), id) or_return
		}
	}
	if len(d.fields) > 0 {
		md.flags |= DF_FIELDS
		md.fields_off = u32(len(m.fidx))
		md.nfields = u8(len(d.fields))
		for f in d.fields {
			nm := make([]u8, len(f.name), context.temp_allocator)
			fold_into(nm, transmute([]u8)f.name)
			ni := _intern_bytes(m, nm) or_return
			vi := _intern_bytes(m, transmute([]u8)f.value) or_return
			append(&m.fidx, [2]u32{ni, vi})
			if ix.bare {
				continue
			}
			key: [MAX_KEY]u8
			if n, ok := field_key(NS_FIELD, nm, transmute([]u8)f.value, &key); ok {
				_post_long(m, key[:n], id) or_return
			}
			v := f.value
			if len(v) >= 3 && substring_field(ix, nm) {
				fv := make([]u8, len(v), context.temp_allocator)
				fold_into(fv, transmute([]u8)v)
				base, _ := field_key(NS_FTRI, nm, nil, &key)
				for i in 0 ..< len(v) - 2 {
					key[base] = fv[i]
					key[base + 1] = fv[i + 1]
					key[base + 2] = fv[i + 2]
					_post_long(m, key[:base + 3], id) or_return
				}
			}
		}
	}
	if len(d.slot) > 0 && !ix.bare {
		key: [MAX_KEY]u8
		n := slot_key(d.object, d.slot, &key)
		_post_long(m, key[:n], id) or_return
	}
	if ix.opts.store_text {
		if len(text) >= 8 && md.flags & DF_UNSTABLE == 0 {
			ix.zd.eligible += u64(min(len(text), DICT_SAMPLE_PIECE))
		}
		md.flags |= DF_TEXT
		cur := len(m.frames) - 1
		if cur < 0 || (len(m.raw) > int(m.frames[cur]) && len(m.raw) - int(m.frames[cur]) + len(text) > FRAME) {
			append(&m.frames, u32(len(m.raw)))
			cur = len(m.frames) - 1
		}
		md.frame = u32(cur)
		md.frame_off = u32(len(m.raw) - int(m.frames[cur]))
		if _, e := append(&m.raw, ..text); e != nil {
			return .No_Memory
		}
	}
	if !ix.bare {
		idkey: [17]u8
		idkey[0] = NS_OBJECT
		ob := d.object
		copy(idkey[1:], ob[:])
		_post_long(m, idkey[:], id) or_return
		idkey[0] = NS_FROM
		pa := d.participant
		copy(idkey[1:], pa[:])
		_post_long(m, idkey[:], id) or_return
		_post_fix(m, key64(NS_KIND, u64(d.kind)), id) or_return
		_index_text(m, text, id) or_return
	}
	if _, e := append(&m.docs, md); e != nil {
		return .No_Memory
	}
	m.total_len += u64(len(text))
	return .None
}

@(private)
_index_text :: proc(m: ^Mem, text: []u8, id: u32) -> Error #no_bounds_check {
	n := len(text)
	if grow(&m.fold, n) != nil {
		return .No_Memory
	}
	f := m.fold[:n]
	fold_into(f, text)
	if n >= 3 {
		k := u64(f[0]) << 8 | u64(f[1])
		for i in 2 ..< n {
			k = (k << 8 | u64(f[i])) & 0xffffff
			_post_fix(m, u64(NS_TRI) << 56 | k, id) or_return
		}
	}
	w := Word_Iter{t = f}
	key: [MAX_KEY]u8
	for {
		s, e, ok := word_next(&w)
		if !ok {
			break
		}
		if e - s > MAX_WORD {
			continue
		}
		kn := word_key(f[s:e], &key)
		ti := _term_long(m, key[:kn]) or_return
		_post_word(m, ti, id) or_return
	}
	return _end_doc(m, id)
}

mem_kill :: proc(m: ^Mem, id: u32) {
	if u64(id) >= m.base && u64(id) < m.base + u64(len(m.docs)) {
		d := &m.docs[u64(id) - m.base]
		d.flags |= DF_DELETED
		if d.flags & DF_TEXT != 0 {
			at := int(m.frames[d.frame]) + int(d.frame_off)
			for k in at ..< at + int(d.len) {
				m.raw[k] = 0
			}
		}
		return
	}
	append(&m.dead, id)
}

mem_decode_chain :: proc(m: ^Mem, t: ^Mem_Term, words: bool, ids: ^[dynamic]u32, tfs: ^[dynamic]u16, keep_dead: bool) -> Error {
	clear(ids)
	clear(tfs)
	if t.count == 0 {
		return .None
	}
	c := t.head
	acc := u32(0)
	v: u64
	shift: u64
	want_tf := false
	cur := u32(0)
	left := t.count
	for left > 0 && c != 0 {
		base := int(c - 1) * MCHUNK
		limit := MCHUNK_DATA if c != t.tail else int(t.used)
		for i in 0 ..< limit {
			b := m.chunks[base + 4 + i]
			v |= u64(b & 0x7f) << shift
			if b >= 0x80 {
				shift += 7
				continue
			}
			x := v
			v = 0
			shift = 0
			if want_tf {
				want_tf = false
				if keep_dead || m.docs[u64(cur) - m.base].flags & DF_DELETED == 0 {
					append(ids, cur)
					append(tfs, u16(min(x, u64(max(u16)))))
				}
				left -= 1
				if left == 0 {
					break
				}
				continue
			}
			acc += u32(x)
			cur = acc - 1
			if u64(cur) < m.base || u64(cur) - m.base >= u64(len(m.docs)) {
				return .Corrupt
			}
			if words {
				want_tf = true
				continue
			}
			if keep_dead || m.docs[u64(cur) - m.base].flags & DF_DELETED == 0 {
				append(ids, cur)
			}
			left -= 1
			if left == 0 {
				break
			}
		}
		if left > 0 {
			c = prim.get_u32le(m.chunks[base:])
		}
	}
	return .None
}

impact :: proc "contextless" (tf: u16, dl: u32, avgdl: f64) -> u8 {
	t := f64(tf)
	norm := t * (K1 + 1) / (t + K1 * (1 - B + B * f64(dl) / avgdl))
	q := int(math.round(15 * norm / (K1 + 1)))
	return u8(clamp(q, 1, 15))
}

mem_flush :: proc(ix: ^Index) -> Error {
	m := &ix.mem
	if mem_empty(m) && len(m.vids) == 0 {
		return .None
	}
	store := ix.opts.store_text
	if store {
		zstd_train(ix) or_return
	}
	lo := m.base
	hi := m.base + u64(len(m.docs))
	base_pmax := u64(0)
	for &s in ix.segs {
		base_pmax = max(base_pmax, s.f.max_hlc)
	}
	nbuf: Name_Buf
	sw: Seg_Writer
	if e := sw_begin(&sw, ix.vfs, file_path(ix, "flush.tmp", &nbuf), lo, hi, store, base_pmax, m.allocator); e != .None {
		sw_destroy(&sw)
		return e
	}
	defer sw_destroy(&sw)
	sw.f.text_off = sw_off(&sw)
	fpos := make([]i64, len(m.frames), context.temp_allocator)
	fbuf := make([dynamic]u8, context.temp_allocator)
	for k in 0 ..< len(m.frames) {
		fpos[k] = sw_off(&sw)
		clear(&fbuf)
		fw := prim.writer(&fbuf)
		frame_write(ix, &fw, m.raw[m.frames[k]:_frame_end(m, k)], &m.scratch) or_return
		sw_write(&sw, fbuf[:])
	}
	sw.f.text_len = sw_off(&sw) - sw.f.text_off
	sw.f.docs_off = sw_off(&sw)
	sw.f.total_len = m.total_len
	sw.f.zd_gen = ix.man.zd_gen if store else 0
	metas: [DOC_BLOCK]Doc_Meta
	enc := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	field_scratch := make([dynamic]Field_Bytes, context.temp_allocator)
	id := lo
	for id < hi {
		blk := id / DOC_BLOCK
		end := min((blk + 1) * DOC_BLOCK, hi)
		n := int(end - id)
		clear(&field_scratch)
		for k in 0 ..< n {
			md := &m.docs[id - lo + u64(k)]
			for f in 0 ..< int(md.nfields) {
				fi := m.fidx[int(md.fields_off) + f]
				append(&field_scratch, Field_Bytes{m.strs[fi[0]], m.strs[fi[1]]})
			}
		}
		pp := 0
		mn, mx := max(u64), u64(0)
		for k in 0 ..< n {
			md := &m.docs[id - lo + u64(k)]
			dm := &metas[k]
			dm^ = Doc_Meta {
				id          = u32(id) + u32(k),
				flags       = md.flags,
				object      = m.ids[md.object],
				participant = m.ids[md.part_id],
				kind        = md.kind,
				hlc         = md.hlc,
				ref         = m.refs[md.ref_off:][:md.ref_len],
				part        = md.part,
				chunk       = md.chunk,
				len         = md.len,
				frame       = fpos[md.frame] if md.flags & DF_TEXT != 0 else 0,
				frame_off   = md.frame_off,
				fields      = field_scratch[pp:][:md.nfields],
			}
			pp += int(md.nfields)
			mn = min(mn, md.hlc)
			mx = max(mx, md.hlc)
		}
		clear(&enc)
		w := prim.writer(&enc)
		tb := doc_block_encode(&w, metas[:n])
		if w.err != .None {
			return .No_Memory
		}
		sw_dir(&sw, Dir_Entry{doc_off = sw_off(&sw), text_base = tb, min_hlc = mn, max_hlc = mx})
		sw_write(&sw, enc[:])
		id = end
	}
	sw.f.docs_len = sw_off(&sw) - sw.f.docs_off
	order := make([]u32, len(m.terms), context.temp_allocator)
	prefix := make([]u64, len(m.terms), context.temp_allocator)
	for i in 0 ..< len(m.terms) {
		order[i] = u32(i)
		kb: [MAX_KEY]u8
		k := mem_term_key(m, &m.terms[i], &kb)
		p: u64
		for j in 0 ..< 8 {
			p <<= 8
			if j < len(k) {
				p |= u64(k[j])
			}
		}
		prefix[i] = p
	}
	Sort_Ctx :: struct {
		m:      ^Mem,
		prefix: []u64,
	}
	sctx := Sort_Ctx{m, prefix}
	slice.sort_by_with_data(order, proc(a, b: u32, data: rawptr) -> bool {
			c := (^Sort_Ctx)(data)
			if c.prefix[a] != c.prefix[b] {
				return c.prefix[a] < c.prefix[b]
			}
			ka, kb: [MAX_KEY]u8
			return key_less(mem_term_key(c.m, &c.m.terms[a], &ka), mem_term_key(c.m, &c.m.terms[b], &kb))
		}, &sctx)
	sw_post_begin(&sw)
	ids := make([dynamic]u32, context.temp_allocator)
	tfs := make([dynamic]u16, context.temp_allocator)
	scratch := make([dynamic]u8, context.temp_allocator)
	avgdl := max(f64(ix.man.total_len + m.total_len) / max(f64(ix.man.next_doc + u64(len(m.docs))), 1), 1)
	lw: List_Writer
	lw_init(&lw, &sw, context.temp_allocator)
	vocab := make(map[u32][dynamic]u32, context.temp_allocator)
	word_ord := u32(0)
	vw: Vocab_Writer
	vocab_init(ix, &vw, "vt-flush.tmp", "vs-flush.tmp", context.temp_allocator) or_return
	defer vocab_destroy(ix, &vw)
	for ti in order {
		t := &m.terms[ti]
		vk := mem_term_vk(m, t)
		mem_decode_chain(m, t, vk != VAL_NONE, &ids, &tfs, false) or_return
		if len(ids) == 0 {
			continue
		}
		kb: [MAX_KEY]u8
		key := mem_term_key(m, t, &kb)
		lw_begin(&lw, vk)
		for k := len(ids) - 1; k >= 0; k -= 1 {
			v := u8(0)
			if vk == VAL_IMPACT {
				v = impact(tfs[k], m.docs[u64(ids[k]) - m.base].len, avgdl)
			}
			lw_push(&lw, ids[k], v)
		}
		lo := lw_end(&lw)
		if lw.err != .None {
			return lw.err
		}
		before := sw.f.n_terms
		sw_term(&sw, key, lo)
		if sw.out.err != .None {
			return sw.out.err
		}
		if vk == VAL_IMPACT && sw.f.n_terms > before {
			token_trigrams(key[1:], &vocab, word_ord, context.temp_allocator)
			vocab_add(&vw, &sw, key[1:])
			word_ord += 1
		}
	}
	vocab_lists(vocab, &sw, &lw) or_return
	sw_post_end(&sw)
	vocab_write(ix, &sw, &vw)
	src := make([dynamic]prim.Id, 0, len(m.sources), context.temp_allocator)
	for k in prim.sorted_keys(m.sources) {
		append(&src, k)
	}
	slice.sort_by(src[:], proc(a, b: prim.Id) -> bool {
		x, y := a, b
		return key_less(x[:], y[:])
	})
	sw.f.src_off = sw_off(&sw)
	for s in src {
		b: [SRC_ENTRY]u8
		v := s
		copy(b[:16], v[:])
		prim.put_u64le(b[16:], u64(m.sources[s]))
		sw_meta(&sw, b[:])
	}
	sw.f.src_len = sw_off(&sw) - sw.f.src_off
	slice.sort(m.dead[:])
	dead := slice.unique(m.dead[:])
	sw.f.tomb_off = sw_off(&sw)
	if len(dead) > 0 {
		clear(&scratch)
		w := prim.writer(&scratch)
		prim.write_uvarint(&w, u64(len(dead)))
		prev := u32(0)
		for d in dead {
			prim.write_uvarint(&w, u64(d - prev))
			prev = d
		}
		sw_meta(&sw, scratch[:])
	}
	sw.f.tomb_len = sw_off(&sw) - sw.f.tomb_off
	kv_write_map_str(&sw, &m.files, .Files)
	kv_write_map_id(&sw, &m.scopes, .Scopes)
	vec_flush(ix, &sw) or_return
	f, ferr := sw_finish(&sw)
	if ferr != .None {
		return ferr
	}
	prim.close_file(sw.out.vfs, sw.out.fd)
	sw.out.fd = prim.INVALID_FD
	if e := commit_segment(ix, "flush.tmp", len(ix.segs), len(ix.segs), &f); e != .None {
		return e
	}
	mem_reset(m, hi)
	return .None
}

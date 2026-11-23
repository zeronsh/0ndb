package search

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:hash/xxhash"
import "core:math"
import "core:slice"
import "../prim"

K1 :: 1.2
B :: 0.75
DEFAULT_LIMIT :: 20
MAX_LIMIT :: 1000
DEFAULT_HALF_LIFE :: i64(30 * 86400 * 1000)
SNIPPET :: 200
SNIPPET_LEAD :: 60
CURSOR_VERSION :: u8(3)
VCURSOR_VERSION :: u8(4)
MAX_CANDS :: 6
MAX_COLLAPSED :: 4096
RRF_K :: 60.0

Sort :: enum u8 {
	Relevance,
	Newest,
}

Request :: struct {
	limit:        int,
	cursor:       []u8,
	sort:         Sort,
	collapse:     bool,
	now:          prim.Hlc,
	half_life_ms: i64,
	participants: Participants,
	file_key:     File_Key,
	resolve_data: rawptr,
	vector:       []f32,
	semantic:     bool,
	embed_kind:   u8,
	beam:         int,
}

Match :: struct {
	start: u32,
	len:   u32,
}

Hit :: struct {
	space:       prim.Id,
	object:      prim.Id,
	participant: prim.Id,
	ref:         []u8,
	part:        u32,
	kind:        u8,
	title:       bool,
	fields:      []Field,
	hlc:         prim.Hlc,
	score:       f64,
	doc:         u32,
	snippet:     string,
	snippet_at:  u64,
	matches:     []Match,
}

Results :: struct {
	hits:       []Hit,
	cursor:     []u8,
	incomplete: bool,
	verified:   int,
}

Iter_Kind :: enum u8 {
	Empty,
	All,
	List,
	And,
	Or,
}

Iter :: struct {
	kind:  Iter_Kind,
	pl:    ^Plist,
	kids:  [dynamic]^Iter,
	heap:  [dynamic]^Iter,
	init:  bool,
	h:     Handle,
	sp:    ^Src_Plan,
	bm:    []u64,
	blo:   u32,
	bhi:   u32,
	lo:    u32,
	val:   u32,
	has:   bool,
	done:  bool,
	count: u32,
}

Handle :: struct {
	term: Term,
	ids:  []u32,
	vals: []u8,
	mem:  bool,
}

Atom_Src :: struct {
	kind:   Iter_Kind,
	cands:  [dynamic]Handle,
	checks: [dynamic]Handle,
	words:  []Handle,
	has:    []bool,
	exact:  int,
	exactu: bool,
	vunion: ^Iter,
	tris:   [dynamic]Handle,
	vtris:  []^Plist,
	est:    u64,
	title:  Handle,
	titled: bool,
	vcands: []^Plist,
	vwords: []^Plist,
	driven: bool,
	planned: bool,
}

Src_Plan :: struct {
	si:    int,
	seg:   ^Seg,
	lo:    u64,
	hi:    u64,
	dc:    ^Dict_Cursor,
	atoms: []Atom_Src,
	mdir:  Dir_Entry,
	dir:   Dir_Entry,
	ready: bool,
	empty: bool,
}

Entry :: struct {
	score: f64,
	hlc:   u64,
	id:    u32,
	seg:   int,
	obj:   prim.Id,
}

@(private)
Exec :: struct {
	ix:          ^Index,
	q:           ^Query,
	atoms:       [dynamic]^Atom,
	sort:        Sort,
	collapse:    bool,
	emitted:     [dynamic]prim.Id,
	now_ms:      i64,
	half_life:   i64,
	n_docs:      f64,
	bm25max:     f64,
	dead:        []u32,
	heap:        [dynamic]Entry,
	k:           int,
	has_cur:     bool,
	cur:         Entry,
	blk:         Doc_Block,
	mfields:     [dynamic]Field_Bytes,
	mmeta:       Doc_Meta,
	text:        [dynamic]u8,
	folded:      [dynamic]u8,
	frame:       [dynamic]u8,
	frame_at:    i64,
	frame_gen:   u64,
	fscratch:    [dynamic]u8,
	present:     [MAX_ATOMS]i8,
	occ:         [MAX_ATOMS]Occurrences,
	have_text:   bool,
	text_ok:     bool,
	after:       u64,
	before:      u64,
	incomplete:  bool,
	verified:    int,
	stop:        bool,
	err:         Error,
	srcs:        [dynamic]Src_Plan,
	alloc:       runtime.Allocator,
}

@(private)
_entry_less :: proc "contextless" (a, b: Entry) -> bool {
	if a.score != b.score {
		return a.score < b.score
	}
	if a.hlc != b.hlc {
		return a.hlc < b.hlc
	}
	return a.id < b.id
}

@(private)
_sift_down :: proc(h: []Entry, i0: int) {
	i := i0
	for {
		l := 2 * i + 1
		if l >= len(h) {
			return
		}
		m := l
		if l + 1 < len(h) && _entry_less(h[l + 1], h[l]) {
			m = l + 1
		}
		if !_entry_less(h[m], h[i]) {
			return
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

@(private)
_sift_up :: proc(h: []Entry, i0: int) {
	i := i0
	for i > 0 {
		p := (i - 1) / 2
		if !_entry_less(h[i], h[p]) {
			return
		}
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

@(private)
_heap_push :: proc(e: ^Exec, x: Entry) {
	h := &e.heap
	if e.collapse {
		for &y, i in h {
			if y.obj == x.obj {
				if _entry_less(y, x) {
					y = x
					_sift_down(h[:], i)
					_sift_up(h[:], i)
				}
				return
			}
		}
	}
	if len(h) == e.k {
		if !_entry_less(h[0], x) {
			return
		}
		h[0] = x
		_sift_down(h[:], 0)
		return
	}
	append(h, x)
	_sift_up(h[:], len(h) - 1)
}

@(private)
_decay :: proc "contextless" (e: ^Exec, hlc: u64) -> f64 {
	age := e.now_ms - i64(hlc >> 16)
	if age <= 0 {
		return 1
	}
	return math.pow(2, -f64(age) / f64(e.half_life))
}

@(private)
_is_text :: proc "contextless" (a: ^Atom) -> bool {
	#partial switch a.field {
	case .Any, .Title, .Body:
		return true
	}
	return false
}

search :: proc(ix: ^Index, query: string, req: Request, allocator := context.allocator) -> (res: Results, err: Error) {
	if ix.broken {
		return res, .Corrupt
	}
	arena: runtime.Arena
	if runtime.arena_init(&arena, 256 * 1024, ix.allocator) != nil {
		return res, .No_Memory
	}
	defer runtime.arena_destroy(&arena)
	a := runtime.arena_allocator(&arena)
	r := req
	e := new(Exec, a)
	e.ix = ix
	e.alloc = a
	e.sort = r.sort
	e.collapse = r.collapse
	e.emitted = make([dynamic]prim.Id, a)
	e.k = clamp(r.limit if r.limit > 0 else DEFAULT_LIMIT, 1, MAX_LIMIT) + 1
	e.half_life = r.half_life_ms if r.half_life_ms > 0 else DEFAULT_HALF_LIFE
	if r.now == 0 {
		prim.unrouted("a search clock read without a request time")
	}
	e.now_ms = i64(u64(r.now) >> 16) if r.now != 0 else prim.now_ms()
	e.n_docs = max(f64(ix.man.next_doc + u64(len(ix.mem.docs))), 1)
	e.heap = make([dynamic]Entry, 0, e.k, a)
	e.before = max(u64)
	db_init(&e.blk, a)
	e.mfields = make([dynamic]Field_Bytes, a)
	e.text = make([dynamic]u8, a)
	e.folded = make([dynamic]u8, a)
	e.frame = make([dynamic]u8, a)
	e.fscratch = make([dynamic]u8, a)
	e.frame_at = -1
	if len(r.cursor) >= 19 && r.cursor[0] == CURSOR_VERSION {
		e.now_ms = i64(prim.get_u64le(r.cursor[11:]))
	}
	q := parse(ix, query, &r, e.now_ms, a) or_return
	e.q = &q
	e.atoms = make([dynamic]^Atom, a)
	for &c in q.clauses {
		for &at in c.atoms {
			at.index = len(e.atoms)
			append(&e.atoms, &at)
		}
		if len(c.atoms) == 1 && !c.atoms[0].neg {
			#partial switch c.atoms[0].field {
			case .After:
				e.after = max(e.after, c.atoms[0].hlc)
			case .Before:
				e.before = min(e.before, c.atoms[0].hlc)
			}
		}
	}
	qhash := xxhash.XXH3_64_default(transmute([]u8)query) if len(query) > 0 else 0
	if r.vector == nil && !r.semantic && _contradiction(&q) {
		return res, .None
	}
	dead := make([dynamic]u32, a)
	for &s in ix.segs {
		tomb_load(&s, &dead) or_return
	}
	append(&dead, ..ix.mem.dead[:])
	slice.sort(dead[:])
	e.dead = slice.unique(dead[:])
	e.srcs = make([dynamic]Src_Plan, a)
	for si in 0 ..< len(ix.segs) {
		s := &ix.segs[si]
		append(&e.srcs, Src_Plan{si = si, seg = s, lo = s.f.lo, hi = s.f.hi})
	}
	if len(ix.mem.docs) > 0 {
		m := &ix.mem
		sp := Src_Plan {
			si = len(ix.segs),
			lo = m.base,
			hi = m.base + u64(len(m.docs)),
		}
		sp.mdir.min_hlc = max(u64)
		for &s in ix.segs {
			sp.mdir.pmax = max(sp.mdir.pmax, s.f.max_hlc)
		}
		for d in m.docs {
			sp.mdir.min_hlc = min(sp.mdir.min_hlc, d.hlc)
			sp.mdir.max_hlc = max(sp.mdir.max_hlc, d.hlc)
		}
		sp.mdir.pmax = max(sp.mdir.pmax, sp.mdir.max_hlc)
		append(&e.srcs, sp)
	}
	for &sp in e.srcs {
		_plan_words(e, &sp) or_return
	}
	qv := _query_vector(e, &r) or_return
	if len(r.cursor) > 0 && qv == nil {
		_cursor_decode(e, r.cursor, qhash) or_return
	} else {
		for at in e.atoms {
			if _is_text(at) && !at.neg {
				for &idf, j in at.tok_idf {
					df := 0.0
					for &sp in e.srcs {
						if sp.atoms[at.index].has[j] {
							df += f64(sp.atoms[at.index].words[j].term.count)
						}
					}
					d := clamp(df, 0, e.n_docs)
					idf = math.ln(1 + (e.n_docs - d + 0.5) / (d + 0.5)) if df > 0 else 0
				}
			}
		}
	}
	for at in e.atoms {
		if _is_text(at) && !at.neg {
			at.scored = true
			for idf in at.tok_idf {
				e.bm25max += idf * (K1 + 1)
			}
		}
	}
	if qv != nil {
		return _search_vector(e, qv, &r, qhash, allocator)
	}
	for i := len(e.srcs) - 1; i >= 0 && !e.stop; i -= 1 {
		_run_source(e, &e.srcs[i]) or_return
	}
	if e.err != .None {
		return res, e.err
	}
	slice.sort_by(e.heap[:], proc(x, y: Entry) -> bool {
		return _entry_less(y, x)
	})
	limit := e.k - 1
	n := min(len(e.heap), limit)
	hits := make([]Hit, n, allocator)
	for i in 0 ..< n {
		_make_hit(e, e.heap[i], &hits[i], allocator) or_return
	}
	res.hits = hits
	res.incomplete = e.incomplete
	res.verified = e.verified
	if len(e.heap) > limit {
		for i in 0 ..< n {
			append(&e.emitted, hits[i].object)
		}
		res.cursor = _cursor_encode(e, qhash, e.heap[limit - 1], allocator) or_return
	}
	return res, .None
}

@(private)
_contradiction :: proc(q: ^Query) -> bool {
	for &c in q.clauses {
		if len(c.atoms) != 1 || !c.atoms[0].neg {
			continue
		}
		x := &c.atoms[0]
		#partial switch x.field {
		case .Any, .Title, .Body, .Named, .Kind:
		case:
			continue
		}
		for &d in q.clauses {
			if len(d.atoms) != 1 || d.atoms[0].neg {
				continue
			}
			y := &d.atoms[0]
			if x.field == y.field && x.substr == y.substr && x.word == y.word && x.prefix == y.prefix && x.whole == y.whole && x.kind == y.kind && string(x.name) == string(y.name) && string(x.text) == string(y.text) {
				return true
			}
		}
	}
	return false
}

@(private)
_key_fix :: proc "contextless" (key: []u8) -> (k: u64, ok: bool) {
	if len(key) < 2 || len(key) > 8 {
		return 0, false
	}
	switch key[0] {
	case NS_TRI, NS_KIND, NS_TITLE:
	case:
		return 0, false
	}
	k = u64(key[0]) << 56
	for i in 1 ..< len(key) {
		k |= u64(key[i]) << u64(8 * (len(key) - 1 - i))
	}
	return k, true
}

@(private)
_mem_handle :: proc(e: ^Exec, ti: u32) -> (h: Handle, err: Error) {
	m := &e.ix.mem
	t := &m.terms[ti]
	vk := mem_term_vk(m, t)
	ids := make([dynamic]u32, e.alloc)
	tfs := make([dynamic]u16, e.alloc)
	mem_decode_chain(m, t, vk != VAL_NONE, &ids, &tfs, false) or_return
	h.mem = true
	h.ids = ids[:]
	h.term.count = u32(len(ids))
	h.term.vk = vk
	if vk != VAL_NONE {
		avgdl := max(f64(e.ix.man.total_len + m.total_len) / e.n_docs, 1)
		vals := make([]u8, len(ids), e.alloc)
		for id, i in ids {
			vals[i] = impact(tfs[i], m.docs[u64(id) - m.base].len, avgdl)
		}
		h.vals = vals
	}
	return h, .None
}

@(private)
_lookup :: proc(e: ^Exec, sp: ^Src_Plan, key: []u8) -> (h: Handle, found: bool, err: Error) {
	if sp.seg != nil {
		t, ok := term_lookup(sp.dc, key) or_return
		return Handle{term = t}, ok, .None
	}
	m := &e.ix.mem
	ti: u32
	ok: bool
	if k, fixed := _key_fix(key); fixed {
		ti, ok = _find_fix(m, k)
	} else {
		ti, ok = _find_long(m, key)
	}
	if !ok {
		return h, false, .None
	}
	h = _mem_handle(e, ti) or_return
	return h, h.term.count > 0, .None
}

@(private)
_range :: proc(e: ^Exec, sp: ^Src_Plan, p: ^Atom_Src, key: []u8, prefix: bool, nibbles: int) -> Error {
	if !prefix {
		h, found := _lookup(e, sp, key) or_return
		p.kind = .List if found else .Empty
		if found {
			append(&p.cands, h)
		}
		return .None
	}
	p.kind = .Empty
	full := nibbles / 2 if nibbles > 0 else 0
	match :: proc(k: []u8, key: []u8, nibbles: int, full: int) -> bool {
		if len(k) < len(key) || string(k[:len(key)]) != string(key) {
			return false
		}
		if nibbles % 2 == 1 && len(k) <= 1 + full {
			return false
		}
		return true
	}
	if sp.seg == nil {
		m := &e.ix.mem
		for &t, ti in m.terms {
			if t.klen == 0 || !match(_long_key(m, &t), key, nibbles, full) {
				continue
			}
			if len(p.cands) >= MAX_RANGE_TERMS {
				clear(&p.cands)
				p.kind = .All
				return .None
			}
			h := _mem_handle(e, u32(ti)) or_return
			if h.term.count > 0 {
				append(&p.cands, h)
				p.kind = .Or
			}
		}
		return .None
	}
	dc := sp.dc
	if !dc_seek(dc, key) {
		return dc.err
	}
	for {
		k := dc_key(dc)
		if len(k) < len(key) || string(k[:len(key)]) != string(key) {
			break
		}
		if match(k, key, nibbles, full) {
			if len(p.cands) >= MAX_RANGE_TERMS {
				clear(&p.cands)
				p.kind = .All
				return .None
			}
			append(&p.cands, Handle{term = dc.term})
			p.kind = .Or
		}
		if !dc_next(dc) {
			break
		}
	}
	return dc.err
}

@(private)
_plan_words :: proc(e: ^Exec, sp: ^Src_Plan) -> Error {
	a := e.alloc
	sp.atoms = make([]Atom_Src, len(e.atoms), a)
	if sp.seg != nil {
		dix := dix_load(&e.ix.cache, sp.seg, a) or_return
		pdix := new_clone(dix, a)
		sp.dc = new(Dict_Cursor, a)
		dc_init(sp.dc, &e.ix.cache, sp.seg, pdix, a)
	}
	for at, i in e.atoms {
		p := &sp.atoms[i]
		p.cands = make([dynamic]Handle, a)
		p.checks = make([dynamic]Handle, a)
		p.exact = -1
		p.kind = .All
		#partial switch at.field {
		case .Any, .Title, .Body:
			key: [MAX_KEY]u8
			p.words = make([]Handle, len(at.tokens), a)
			p.has = make([]bool, len(at.tokens), a)
			p.vwords = make([]^Plist, len(at.tokens), a)
			for tok, j in at.tokens {
				n := word_key(tok, &key)
				h, found := _lookup(e, sp, key[:n]) or_return
				p.words[j] = h
				p.has[j] = found
				if at.whole && j == 0 {
					p.exact = 0
				}
			}
		}
	}
	return .None
}

@(private)
_plan_source :: proc(e: ^Exec, sp: ^Src_Plan) -> Error {
	if sp.ready {
		return .None
	}
	sp.ready = true
	for &c in e.q.clauses {
		if len(c.atoms) != 1 || c.atoms[0].neg || _is_text(&c.atoms[0]) {
			continue
		}
		at := &c.atoms[0]
		_plan_atom(e, sp, at, at.index) or_return
		if sp.atoms[at.index].kind == .Empty {
			sp.empty = true
			return .None
		}
	}
	for at, i in e.atoms {
		if !sp.atoms[i].planned {
			_plan_atom(e, sp, at, i) or_return
		}
	}
	return .None
}

@(private)
_plan_atom :: proc(e: ^Exec, sp: ^Src_Plan, at: ^Atom, i: int) -> Error {
	a := e.alloc
	{
		p := &sp.atoms[i]
		p.planned = true
		key: [MAX_KEY]u8
		switch at.field {
		case .Any, .Title, .Body:
			if at.word {
				if p.exact >= 0 && p.has[0] {
					p.kind = .List
					append(&p.cands, p.words[0])
				} else if p.exact >= 0 {
					p.kind = .Empty
				}
			} else if at.whole && len(at.text) >= 3 {
				hs, ok := _vocab(e, sp, at.text) or_return
				if ok {
					p.exactu = true
					p.kind = .Or if len(hs) > 0 else .Empty
					append(&p.cands, ..hs[:])
					append(&p.checks, ..hs[:])
					p.tris = make([dynamic]Handle, a)
					for k in at.keys {
						kb: [8]u8
						n := key64_bytes(k, &kb)
						h, found := _lookup(e, sp, kb[:n]) or_return
						if found {
							append(&p.tris, h)
						}
					}
				} else {
					_tri_plan(e, sp, at, p) or_return
				}
			} else if len(at.keys) > 0 {
				_tri_plan(e, sp, at, p) or_return
			}
			if at.field == .Title && p.exactu && p.kind != .Empty {
				kb: [8]u8
				n := key64_bytes(key64(NS_TITLE, 1), &kb)
				h, found := _lookup(e, sp, kb[:n]) or_return
				if !found {
					p.kind = .Empty
				} else {
					p.title = h
					p.titled = true
				}
			}
			if at.field == .Title && p.kind == .List && !p.exactu {
				kb: [8]u8
				n := key64_bytes(key64(NS_TITLE, 1), &kb)
				h, found := _lookup(e, sp, kb[:n]) or_return
				if !found {
					p.kind = .Empty
				} else {
					append(&p.cands, h)
				}
			}
		case .Named:
			if at.substr {
				if len(at.text) >= 3 {
					base, _ := field_key(NS_FTRI, at.name, nil, &key)
					p.kind = .List
					for k in 0 ..< len(at.text) - 2 {
						key[base] = at.text[k]
						key[base + 1] = at.text[k + 1]
						key[base + 2] = at.text[k + 2]
						h, found := _lookup(e, sp, key[:base + 3]) or_return
						if !found {
							p.kind = .Empty
							clear(&p.cands)
							break
						}
						append(&p.cands, h)
					}
				}
			} else if n, ok := field_key(NS_FIELD, at.name, at.text, &key); ok {
				_range(e, sp, p, key[:n], at.prefix, 0) or_return
			}
		case .Kind:
			kb: [8]u8
			n := key64_bytes(key64(NS_KIND, u64(at.kind)), &kb)
			h, found := _lookup(e, sp, kb[:n]) or_return
			p.kind = .List if found else .Empty
			if found {
				append(&p.cands, h)
			}
		case .Object, .From, .Wrote:
			key[0] = NS_OBJECT if at.field != .From else NS_FROM
			if at.field == .Wrote || len(at.ids) > 0 || (at.field == .From && at.nibbles == 0) {
				p.kind = .Empty
				for id in at.ids {
					v := id
					copy(key[1:], v[:])
					h, found := _lookup(e, sp, key[:17]) or_return
					if found {
						append(&p.cands, h)
						p.kind = .Or
					}
				}
			} else {
				n := 1 + copy(key[1:], at.text[:at.nibbles / 2])
				_range(e, sp, p, key[:n], at.prefix, at.nibbles) or_return
			}
		case .After, .Before:
		}
		if len(p.checks) == 0 {
			append(&p.checks, ..p.cands[:])
		}
		p.vcands = make([]^Plist, len(p.checks), a)
		if len(p.vwords) != len(p.words) {
			p.vwords = make([]^Plist, len(p.words), a)
		}

		p.vtris = make([]^Plist, len(p.tris), a)

		for h in p.cands {
			p.est += u64(h.term.count)
		}
		if p.kind == .List && len(p.cands) > 0 {
			p.est = u64(p.cands[0].term.count)
		}
		if p.exactu && len(p.checks) > 0 {
			u := new(Iter, a)
			u.kind = .Or
			u.kids = make([dynamic]^Iter, a)
			for h in p.checks {
				append(&u.kids, _iter_list(e, sp, h))
			}
			p.vunion = u
		}
	}
	return .None
}

@(private)
_plist :: proc(e: ^Exec, sp: ^Src_Plan, h: Handle) -> ^Plist {
	p := new(Plist, e.alloc)
	if h.mem {
		pl_init_array(p, h.ids, h.vals, h.term.vk)
	} else {
		pl_init(p, &e.ix.cache, sp.seg, h.term)
	}
	return p
}

@(private)
_iter_list :: proc(e: ^Exec, sp: ^Src_Plan, h: Handle) -> ^Iter {
	it := new(Iter, e.alloc)
	it.kind = .List
	it.h = h
	it.sp = sp
	it.count = h.term.count
	it.blo, it.bhi = h.term.lo, h.term.hi
	if h.mem && len(h.ids) > 0 {
		it.blo, it.bhi = h.ids[0], h.ids[len(h.ids) - 1]
	}
	return it
}

@(private)
_iter_atom :: proc(e: ^Exec, sp: ^Src_Plan, p: ^Atom_Src) -> ^Iter {
	it := new(Iter, e.alloc)
	it.kind = p.kind
	it.lo = u32(sp.lo)
	switch p.kind {
	case .Empty, .All:
	case .List, .And:
		if len(p.cands) == 1 {
			return _iter_list(e, sp, p.cands[0])
		}
		it.kind = .And
		it.kids = make([dynamic]^Iter, e.alloc)
		for h in p.cands {
			append(&it.kids, _iter_list(e, sp, h))
		}
		slice.sort_by(it.kids[:], proc(x, y: ^Iter) -> bool {
			return x.count < y.count
		})
	case .Or:
		it.kids = make([dynamic]^Iter, e.alloc)
		for h in p.cands {
			append(&it.kids, _iter_list(e, sp, h))
		}
		if len(it.kids) == 0 {
			it.kind = .Empty
		}
	}
	if p.titled && it.kind != .Empty {
		w := new(Iter, e.alloc)
		w.kind = .And
		w.kids = make([dynamic]^Iter, e.alloc)
		append(&w.kids, _iter_list(e, sp, p.title))
		append(&w.kids, it)
		return w
	}
	return it
}

@(private)
_seek :: proc(e: ^Exec, it: ^Iter, t: u32) -> (u32, bool) {
	switch it.kind {
	case .Empty:
		return 0, false
	case .All:
		if t >= it.lo {
			return t, true
		}
		return 0, false
	case .List:
		if it.pl == nil {
			it.pl = _plist(e, it.sp, it.h)
		}
		v, ok := pl_seek(it.pl, t)
		if it.pl.err != .None && e.err == .None {
			e.err = it.pl.err
		}
		return v, ok
	case .And:
		x := t
		agree := 0
		i := 0
		n := len(it.kids)
		for agree < n {
			v, ok := _seek(e, it.kids[i], x)
			if !ok {
				return 0, false
			}
			if v == x {
				agree += 1
			} else {
				x = v
				agree = 1
			}
			i = (i + 1) % n
		}
		return x, true
	case .Or:
		if len(it.kids) > 8 {
			return _seek_union(e, it, t)
		}
		best := u32(0)
		found := false
		for kid in it.kids {
			if kid.done {
				continue
			}
			if !kid.has || kid.val > t {
				v, ok := _seek(e, kid, t)
				if !ok {
					kid.done = true
					kid.has = false
					continue
				}
				kid.val = v
				kid.has = true
			}
			if !found || kid.val > best {
				best = kid.val
				found = true
			}
		}
		return best, found
	}
	return 0, false
}

@(private)
_source_dir :: proc(e: ^Exec, sp: ^Src_Plan, blk: u64) -> (d: Dir_Entry, err: Error) {
	if sp.seg == nil {
		return sp.mdir, .None
	}
	return seg_dir(&e.ix.cache, sp.seg, blk)
}

@(private)
_remaining_bound :: proc(e: ^Exec, sp: ^Src_Plan) -> f64 {
	rem := 0.0
	for at in e.atoms {
		if !at.scored {
			continue
		}
		p := &sp.atoms[at.index]
		for idf, j in at.tok_idf {
			if j >= len(p.has) || !p.has[j] {
				continue
			}
			pl := p.vwords[j]
			sm := 15 if pl == nil else int(pl.smax)
			rem += idf * (K1 + 1) * f64(sm) / 15
		}
	}
	return rem
}

@(private)
_run_source :: proc(e: ^Exec, sp: ^Src_Plan) -> Error {
	if sp.hi == sp.lo {
		return .None
	}
	if len(e.heap) == e.k {
		if e.sort == .Relevance {
			for at in e.atoms {
				if !at.scored {
					continue
				}
				p := &sp.atoms[at.index]
				for _, j in at.tok_idf {
					if pl := _vw(e, sp, p, j); pl != nil {
						pl_seek(pl, u32(sp.hi - 1))
					}
				}
			}
		}
		act := _block_enter(e, sp, (sp.hi - 1) / DOC_BLOCK) or_return
		if act == .Stop || e.err != .None {
			return e.err
		}
	}
	_plan_source(e, sp) or_return
	if sp.empty {
		return .None
	}
	a := e.alloc
	root := new(Iter, a)
	root.kind = .And
	root.lo = u32(sp.lo)
	root.kids = make([dynamic]^Iter, a)
	ests := make([dynamic]u64, a)
	cis := make([dynamic]^Iter, a)
	cas := make([dynamic]^Atom, a)
	for &c in e.q.clauses {
		all := false
		est := u64(0)
		kids := make([dynamic]^Iter, a)
		for &at in c.atoms {
			p := &sp.atoms[at.index]
			if p.kind == .All || at.neg {
				all = true
				continue
			}
			if p.kind == .Empty {
				continue
			}
			est += max(p.est, 1)
			append(&kids, _iter_atom(e, sp, p))
		}
		if all {
			continue
		}
		if len(kids) == 0 {
			return .None
		}
		if len(kids) == 1 {
			append(&cis, kids[0])
			only: ^Atom
			for &at in c.atoms {
				p := &sp.atoms[at.index]
				if !at.neg && p.kind != .Empty && p.kind != .All {
					only = &at
				}
			}
			append(&cas, only)
		} else {
			ci := new(Iter, a)
			ci.kind = .Or
			ci.kids = kids
			append(&cis, ci)
			append(&cas, nil)
		}
		append(&ests, est)
	}
	if len(cis) > 0 {
		lo := ests[0]
		for x in ests {
			lo = min(lo, x)
		}
		for ci, i in cis {
			if ests[i] <= 4 * lo {
				append(&root.kids, ci)
				if cas[i] != nil {
					sp.atoms[cas[i].index].driven = true
				}
			}
		}
	}
	if len(root.kids) == 0 {
		root.kind = .All
	} else if len(root.kids) == 1 {
		root = root.kids[0]
	}
	excl := make([dynamic]^Atom, a)
	for &c in e.q.clauses {
		if len(c.atoms) == 1 && c.atoms[0].neg && c.atoms[0].field == .Any {
			append(&excl, &c.atoms[0])
		}
	}
	exact_neg := make([dynamic]Handle, a)
	for x in excl {
		p := &sp.atoms[x.index]
		switch {
		case p.kind == .Empty:
		case p.exactu:
			append(&exact_neg, ..p.checks[:])
		case x.word && p.exact >= 0 && p.has[p.exact]:
			append(&exact_neg, p.words[p.exact])
		case len(x.text) == 3 && p.kind == .List && len(p.cands) == 1:
			append(&exact_neg, p.cands[0])
		}
	}
	dense := root.kind == .And && len(root.kids) >= 2
	if dense {
		for ci, i in cis {
			if ci.kind != .Empty && ests[i] * 64 < (sp.hi - sp.lo) {
				dense = false
			}
		}
	}
	if (len(exact_neg) > 0 || dense) && sp.seg != nil {
		return _run_bitmap(e, sp, root, exact_neg[:], excl[:])
	}
	t := u32(sp.hi - 1)
	last_blk := max(u64)
	for {
		d, ok := _seek(e, root, t)
		if !ok || e.err != .None {
			break
		}
		blk := u64(d) / DOC_BLOCK
		if blk != last_blk {
			act := _block_enter(e, sp, blk) or_return
			switch act {
			case .Stop:
				return .None
			case .Skip:
				start := max(blk * DOC_BLOCK, sp.lo)
				if start == sp.lo || sp.seg == nil {
					return e.err
				}
				t = u32(start - 1)
				continue
			case .Go:
			}
			last_blk = blk
		}
		if f, skip := _bmw(e, sp, d); skip {
			if u64(f) <= sp.lo {
				break
			}
			t = f - 1
			continue
		}
		excluded := false
		for x in excl {
			if _verdict(e, sp, x, nil, d) > 0 {
				excluded = true
				break
			}
		}
		if !excluded {
			_consider(e, sp, d) or_return
		}
		if u64(d) == sp.lo {
			break
		}
		t = d - 1
	}
	return e.err
}

@(private)
_bmw :: proc(e: ^Exec, sp: ^Src_Plan, d: u32) -> (floor: u32, skip: bool) {
	if e.sort != .Relevance || e.bm25max <= 0 || len(e.heap) < e.k {
		return 0, false
	}
	bound := 0.0
	floor = u32(sp.lo)
	for at in e.atoms {
		if !at.scored {
			continue
		}
		p := &sp.atoms[at.index]
		for idf, j in at.tok_idf {
			if idf == 0 {
				continue
			}
			pl := _vw(e, sp, p, j)
			if pl == nil {
				continue
			}
			_, ok := pl_seek(pl, d)
			if pl.err != .None {
				if e.err == .None {
					e.err = pl.err
				}
				return 0, false
			}
			if !ok {
				continue
			}
			bm := 15
			if pl.arr == nil {
				bm = int(pl.bmax)
				if pl.ninl == 0 && pl.loaded && pl.n > 0 {
					floor = max(floor, pl.ids[0])
				}
			}
			bound += idf * (K1 + 1) * f64(bm) / 15
		}
	}
	return floor, (1 + bound) * _decay(e, sp.dir.pmax) < e.heap[0].score
}

@(private)
_dead :: proc(e: ^Exec, id: u32) -> bool {
	_, found := slice.binary_search(e.dead, id)
	return found
}

@(private)
_meta :: proc(e: ^Exec, sp: ^Src_Plan, d: u32) -> (dm: ^Doc_Meta, err: Error) {
	if sp.seg != nil {
		doc_load(&e.ix.cache, sp.seg, &e.blk, u64(d) / DOC_BLOCK) or_return
		return &e.blk.docs[d - e.blk.first], .None
	}
	m := &e.ix.mem
	if u64(d) < m.base || u64(d) - m.base >= u64(len(m.docs)) {
		return nil, .Corrupt
	}
	md := &m.docs[u64(d) - m.base]
	clear(&e.mfields)
	for f in 0 ..< int(md.nfields) {
		fi := m.fidx[int(md.fields_off) + f]
		append(&e.mfields, Field_Bytes{m.strs[fi[0]], m.strs[fi[1]]})
	}
	e.mmeta = Doc_Meta {
		id          = d,
		flags       = md.flags,
		kind        = md.kind,
		object      = m.ids[md.object],
		participant = m.ids[md.part_id],
		hlc         = md.hlc,
		ref         = m.refs[md.ref_off:][:md.ref_len],
		part        = md.part,
		chunk       = md.chunk,
		len         = md.len,
		fields      = e.mfields[:],
		frame       = i64(md.frame),
		frame_off   = md.frame_off,
	}
	return &e.mmeta, .None
}

@(private)
_fetch_text :: proc(e: ^Exec, sp: ^Src_Plan, dm: ^Doc_Meta) -> bool {
	if e.have_text {
		return e.text_ok
	}
	e.have_text = true
	e.text_ok = false
	n := int(dm.len)
	e.verified += 1
	if grow(&e.text, n) != nil || grow(&e.folded, n) != nil {
		e.err = .No_Memory
		return false
	}
	if n == 0 {
		e.text_ok = true
		return true
	}
	if e.ix.man.store && dm.flags & DF_TEXT == 0 {
		return false
	}
	if e.ix.man.store && sp.seg == nil {
		m := &e.ix.mem
		at := int(m.frames[dm.frame]) + int(dm.frame_off)
		if at + n > len(m.raw) {
			e.err = .Corrupt
			return false
		}
		copy(e.text[:], m.raw[at:][:n])
	} else if e.ix.man.store {
		s := sp.seg
		if e.frame_at != dm.frame || e.frame_gen != s.gen {
			e.frame_at = -1
			if err := frame_read(e.ix, s, dm.frame, &e.frame, &e.fscratch); err != .None {
				e.err = err
				return false
			}
			e.frame_at = dm.frame
			e.frame_gen = s.gen
		}
		if int(dm.frame_off) + n > len(e.frame) {
			e.err = .Corrupt
			return false
		}
		copy(e.text[:], e.frame[dm.frame_off:][:n])
	} else {
		tr := Text_Ref {
			object = dm.object,
			ref    = dm.ref,
			part   = dm.part,
			kind   = dm.kind,
			title  = dm.flags & DF_TITLE != 0,
			offset = dm.chunk,
			len    = dm.len,
		}
		if !e.ix.opts.fetch(e.ix.opts.fetch_data, &tr, e.text[:]) {
			e.incomplete = true
			return false
		}
	}
	fold_into(e.folded[:], e.text[:])
	e.text_ok = true
	return true
}

@(private)
_eval_meta :: proc(e: ^Exec, dm: ^Doc_Meta, at: ^Atom) -> bool {
	r := false
	#partial switch at.field {
	case .Named:
		for f in dm.fields {
			if string(f.name) != string(at.name) {
				continue
			}
			if at.substr {
				r = contains_fold(f.value, at.text)
			} else if at.prefix {
				r = len(f.value) >= len(at.text) && _fold_eq(f.value[:len(at.text)], at.text)
			} else {
				r = _fold_eq(f.value, at.text)
			}
			if r {
				break
			}
		}
	case .Kind:
		r = dm.kind == at.kind
	case .Object:
		r = id_matches(at, dm.object)
	case .From:
		r = id_matches(at, dm.participant)
	case .After:
		r = dm.hlc >= at.hlc
	case .Before:
		r = dm.hlc < at.hlc
	case .Wrote:
		for w in at.refs {
			if w.object == dm.object && string(w.ref) == string(dm.ref) {
				r = true
				break
			}
		}
	}
	return r != at.neg
}

@(private)
_verdict :: proc(e: ^Exec, sp: ^Src_Plan, at: ^Atom, dm: ^Doc_Meta, d: u32) -> i8 {
	if dm != nil {
		is_title := dm.flags & DF_TITLE != 0
		if (at.field == .Title && !is_title) || (at.field == .Body && is_title) {
			return -1
		}
	}
	p := &sp.atoms[at.index]
	switch p.kind {
	case .Empty:
		return -1
	case .All:
		return 0
	case .List, .And, .Or:
	}
	if p.driven && (p.exactu || (at.word && p.exact >= 0 && p.kind == .List)) {
		return 1
	}
	if p.exactu {
		if p.vunion == nil {
			return -1
		}
		if pl := _vw(e, sp, p, p.exact); pl != nil {
			v, ok := pl_seek(pl, d)
			if ok && v == d {
				return 1
			}
		}
		for j in 0 ..< len(p.tris) {
			pl := _vt(e, sp, p, j)
			v, ok := pl_seek(pl, d)
			if !ok || v != d {
				return -1
			}
		}
		v, ok := _seek(e, p.vunion, d)
		return 1 if ok && v == d else -1
	}
	if p.exact >= 0 {
		pl := _vw(e, sp, p, p.exact)
		if pl != nil {
			v, ok := pl_seek(pl, d)
			if ok && v == d {
				return 1
			}
		}
		if at.word {
			return -1
		}
	}
	for j in 0 ..< len(p.checks) {
		pl := _vc(e, sp, p, j)
		v, ok := pl_seek(pl, d)
		if !ok || v != d {
			return -1
		}
	}
	return 0
}

@(private)
_post_reject :: proc(e: ^Exec, sp: ^Src_Plan, at: ^Atom, d: u32) -> bool {
	if at.neg {
		return false
	}
	#partial switch at.field {
	case .Named, .Kind, .Object, .From:
	case:
		return false
	}
	p := &sp.atoms[at.index]
	switch p.kind {
	case .Empty:
		return true
	case .All:
		return false
	case .List, .And:
		for j in 0 ..< len(p.checks) {
			pl := _vc(e, sp, p, j)
			v, ok := pl_seek(pl, d)
			if !ok || v != d {
				return true
			}
		}
		return false
	case .Or:
		if len(p.checks) > 16 {
			return false
		}
		for j in 0 ..< len(p.checks) {
			pl := _vc(e, sp, p, j)
			v, ok := pl_seek(pl, d)
			if ok && v == d {
				return false
			}
		}
		return true
	}
	return false
}

@(private)
_text_present :: proc(e: ^Exec, sp: ^Src_Plan, dm: ^Doc_Meta, at: ^Atom) -> i8 {
	if !_fetch_text(e, sp, dm) {
		return -1
	}
	o := find_all(e.folded[:], at.text, at.word)
	e.occ[at.index] = o
	return 1 if o.count > 0 else -1
}

@(private)
_consider :: proc(e: ^Exec, sp: ^Src_Plan, d: u32) -> Error {
	for &c in e.q.clauses {
		decided := true
		ok := false
		for &at in c.atoms {
			if at.field != .Any {
				decided = false
				break
			}
			v := _verdict(e, sp, &at, nil, d)
			if v == 0 {
				decided = false
				break
			}
			if (v > 0) != at.neg {
				ok = true
				break
			}
		}
		if decided && !ok {
			return .None
		}
		if len(c.atoms) == 1 && _post_reject(e, sp, &c.atoms[0], d) {
			return .None
		}
	}
	bm := 0.0
	if e.sort == .Relevance && e.bm25max > 0 {
		for at in e.atoms {
			if !at.scored {
				continue
			}
			p := &sp.atoms[at.index]
			for idf, j in at.tok_idf {
				pl := _vw(e, sp, p, j)
				if pl == nil || idf == 0 {
					continue
				}
				v, ok := pl_seek(pl, d)
				if ok && v == d {
					bm += idf * (K1 + 1) * f64(pl_val(pl, d)) / 15
				}
			}
		}
		if len(e.heap) == e.k && (1 + bm) * _decay(e, sp.dir.max_hlc) < e.heap[0].score {
			return .None
		}
	}
	dm := _meta(e, sp, d) or_return
	if dm.flags & DF_DELETED != 0 || _dead(e, d) || dm.hlc < e.after || dm.hlc >= e.before {
		return .None
	}
	x := Entry {
		hlc = dm.hlc,
		id  = d,
		seg = sp.si,
		obj = dm.object,
	}
	if e.sort == .Relevance {
		x.score = (1 + bm) * _decay(e, dm.hlc)
	}
	if len(e.heap) == e.k && !_entry_less(e.heap[0], x) {
		return .None
	}
	if e.has_cur && !_entry_less(x, e.cur) {
		return .None
	}
	if e.collapse {
		for o in e.emitted {
			if o == dm.object {
				return .None
			}
		}
	}
	e.have_text = false
	for &c in e.q.clauses {
		ok := false
		pending := false
		for &at in c.atoms {
			e.present[at.index] = 0
			if _is_text(&at) {
				v := _verdict(e, sp, &at, dm, d)
				e.present[at.index] = v
				if v == 0 {
					pending = true
					continue
				}
				if (v > 0) != at.neg {
					ok = true
					break
				}
			} else if _eval_meta(e, dm, &at) {
				ok = true
				break
			}
		}
		if ok {
			continue
		}
		if !pending {
			return e.err
		}
		for &at in c.atoms {
			if !_is_text(&at) || e.present[at.index] != 0 {
				continue
			}
			v := _text_present(e, sp, dm, &at)
			if e.err != .None {
				return e.err
			}
			if (v > 0) != at.neg {
				ok = true
				break
			}
		}
		if !ok {
			return e.err
		}
	}
	_heap_push(e, x)
	return e.err
}

@(private)
_source :: proc(e: ^Exec, si: int) -> ^Src_Plan {
	for &sp in e.srcs {
		if sp.si == si {
			return &sp
		}
	}
	return nil
}

@(private)
_make_hit :: proc(e: ^Exec, x: Entry, h: ^Hit, allocator: runtime.Allocator) -> Error {
	sp := _source(e, x.seg)
	if sp == nil {
		return .Corrupt
	}
	dm := _meta(e, sp, x.id) or_return
	h.object = dm.object
	h.participant = dm.participant
	h.ref = make([]u8, len(dm.ref), allocator)
	copy(h.ref, dm.ref)
	h.part = dm.part
	h.kind = dm.kind
	h.title = dm.flags & DF_TITLE != 0
	h.fields = make([]Field, len(dm.fields), allocator)
	for f, k in dm.fields {
		nm := make([]u8, len(f.name), allocator)
		copy(nm, f.name)
		v := make([]u8, len(f.value), allocator)
		copy(v, f.value)
		h.fields[k] = Field{string(nm), string(v)}
	}
	h.hlc = prim.Hlc(dm.hlc)
	h.score = x.score
	h.doc = x.id
	e.have_text = false
	if !_fetch_text(e, sp, dm) {
		h.snippet_at = dm.chunk
		return .None
	}
	center := 0
	best := -1.0
	for at in e.atoms {
		if !_is_text(at) || at.neg {
			continue
		}
		o := find_all(e.folded[:], at.text, at.word)
		w := 0.0
		for idf in at.tok_idf {
			w += idf
		}
		if o.first >= 0 && w > best {
			best = w
			center = o.first
		}
	}
	text := e.text[:]
	start := max(0, center - SNIPPET_LEAD)
	for k := start; k > max(0, start - 16); k -= 1 {
		if _is_space(text[k - 1]) {
			start = k
			break
		}
	}
	for start < len(text) && start > 0 && text[start] & 0xc0 == 0x80 {
		start += 1
	}
	end := min(len(text), start + SNIPPET)
	for end < len(text) && end > start && text[end] & 0xc0 == 0x80 {
		end -= 1
	}
	snip := make([]u8, end - start, allocator)
	copy(snip, text[start:end])
	h.snippet = string(snip)
	h.snippet_at = dm.chunk + u64(start)
	ms := make([dynamic]Match, e.alloc)
	win := e.folded[start:end]
	for at in e.atoms {
		if !_is_text(at) || at.neg || len(at.text) == 0 {
			continue
		}
		p := 0
		for p + len(at.text) <= len(win) {
			o := find_all(win[p:], at.text, at.word)
			if o.first < 0 {
				break
			}
			append(&ms, Match{u32(p + o.first), u32(len(at.text))})
			p += o.first + len(at.text)
		}
	}
	slice.sort_by(ms[:], proc(x, y: Match) -> bool {
		return x.start < y.start
	})
	out := make([dynamic]Match, allocator)
	for m in ms {
		if len(out) > 0 && m.start < out[len(out) - 1].start + out[len(out) - 1].len {
			continue
		}
		append(&out, m)
	}
	h.matches = out[:]
	return .None
}

@(private)
_cursor_encode :: proc(e: ^Exec, qhash: u64, last: Entry, allocator: runtime.Allocator) -> ([]u8, Error) {
	if e.collapse && len(e.emitted) > MAX_COLLAPSED {
		return nil, .Too_Large
	}
	out := make([dynamic]u8, allocator)
	w := prim.writer(&out)
	prim.write_u8(&w, CURSOR_VERSION)
	prim.write_u8(&w, u8(e.sort))
	prim.write_u8(&w, 1 if e.collapse else 0)
	prim.write_u64le(&w, qhash)
	prim.write_u64le(&w, u64(e.now_ms))
	prim.write_u64le(&w, u64(e.half_life))
	prim.write_u64le(&w, transmute(u64)e.n_docs)
	n := 0
	for at in e.atoms {
		n += len(at.tok_idf)
	}
	prim.write_uvarint(&w, u64(n))
	for at in e.atoms {
		for idf in at.tok_idf {
			prim.write_u64le(&w, transmute(u64)idf)
		}
	}
	prim.write_u64le(&w, transmute(u64)last.score)
	prim.write_u64le(&w, last.hlc)
	prim.write_u32le(&w, last.id)
	prim.write_uvarint(&w, u64(len(e.emitted)) if e.collapse else 0)
	if e.collapse {
		for o in e.emitted {
			prim.write_id(&w, o)
		}
	}
	if w.err != .None {
		return nil, .No_Memory
	}
	return out[:], .None
}

@(private)
_cursor_decode :: proc(e: ^Exec, c: []u8, qhash: u64) -> Error {
	r := prim.reader(c)
	if prim.read_u8(&r) != CURSOR_VERSION {
		return .Invalid
	}
	if Sort(prim.read_u8(&r)) != e.sort || (prim.read_u8(&r) == 1) != e.collapse || prim.read_u64le(&r) != qhash {
		return .Invalid
	}
	e.now_ms = i64(prim.read_u64le(&r))
	e.half_life = i64(prim.read_u64le(&r))
	e.n_docs = transmute(f64)prim.read_u64le(&r)
	n := int(prim.read_uvarint(&r))
	total := 0
	for at in e.atoms {
		total += len(at.tok_idf)
	}
	if n != total || e.half_life <= 0 {
		return .Invalid
	}
	for at in e.atoms {
		for &idf in at.tok_idf {
			idf = transmute(f64)prim.read_u64le(&r)
			if math.is_nan(idf) || idf < 0 {
				return .Invalid
			}
		}
	}
	e.cur.score = transmute(f64)prim.read_u64le(&r)
	e.cur.hlc = prim.read_u64le(&r)
	e.cur.id = prim.read_u32le(&r)
	ne := prim.read_uvarint(&r)
	if ne > MAX_COLLAPSED {
		return .Invalid
	}
	for _ in 0 ..< ne {
		append(&e.emitted, prim.read_id(&r))
	}
	if !prim.reader_done(&r) {
		return .Invalid
	}
	e.has_cur = true
	return .None
}

@(private)
_fold_eq :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) || len(a) > MAX_PATH {
		return false
	}
	buf: [MAX_PATH]u8
	fold_into(buf[:len(a)], a)
	return string(buf[:len(a)]) == string(b)
}

@(private)
_query_vector :: proc(e: ^Exec, r: ^Request) -> (qv: []f32, err: Error) {
	dim := e.ix.opts.embedder.dim
	if r.vector != nil {
		if dim <= 0 || len(r.vector) != dim {
			return nil, .Invalid
		}
		qv = make([]f32, dim, e.alloc)
		copy(qv, r.vector)
	} else if r.semantic {
		if dim <= 0 || e.ix.opts.embedder.embed == nil {
			return nil, .Invalid
		}
		text := make([dynamic]u8, e.alloc)
		for at in e.atoms {
			if _is_text(at) && !at.neg {
				if len(text) > 0 {
					append(&text, ' ')
				}
				append(&text, ..at.text)
			}
		}
		if len(text) == 0 {
			return nil, .Syntax
		}
		qv = make([]f32, dim, e.alloc)
		if !e.ix.opts.embedder.embed(e.ix.opts.embedder.data, r.embed_kind, text[:], qv) {
			return nil, .Missing
		}
	} else {
		return nil, .None
	}
	if !normalize(qv) {
		return nil, .Invalid
	}
	return qv, .None
}

@(private)
_vec_ok :: proc(e: ^Exec, sp: ^Src_Plan, id: u32) -> (ok: bool, err: Error) {
	dm := _meta(e, sp, id) or_return
	if dm.flags & DF_DELETED != 0 || _dead(e, id) || dm.hlc < e.after || dm.hlc >= e.before {
		return false, .None
	}
	for &c in e.q.clauses {
		pass := false
		for &at in c.atoms {
			if _is_text(&at) || _eval_meta(e, dm, &at) {
				pass = true
				break
			}
		}
		if !pass {
			return false, .None
		}
	}
	return true, .None
}

HYBRID_DEPTH :: 100

@(private)
_search_vector :: proc(e: ^Exec, qv: []f32, r: ^Request, qhash: u64, allocator: runtime.Allocator) -> (res: Results, err: Error) {
	limit := e.k - 1
	has_cur := false
	cur: Entry
	if len(r.cursor) > 0 {
		c := prim.reader(r.cursor)
		if prim.read_u8(&c) != VCURSOR_VERSION || prim.read_u8(&c) != u8(e.sort) || prim.read_u64le(&c) != qhash {
			return res, .Invalid
		}
		cur.score = transmute(f64)prim.read_u64le(&c)
		cur.id = prim.read_u32le(&c)
		if !prim.reader_done(&c) {
			return res, .Invalid
		}
		has_cur = true
	}
	has_text := false
	for at in e.atoms {
		if at.scored {
			has_text = true
		}
	}
	vkey_less :: proc "contextless" (a, b: Entry) -> bool {
		if a.score != b.score {
			return a.score < b.score
		}
		return a.id < b.id
	}
	depth := max(HYBRID_DEPTH, 4 * limit) if has_text else limit + 1
	vl := make([dynamic]Entry, e.alloc)
	scale := 1
	need := depth
	for round in 0 ..< 5 {
		cand := vec_candidates(e, qv, need, r.beam, scale) or_return
		clear(&vl)
		for h in cand {
			x := Entry{score = f64(h.score), id = h.id, seg = h.seg}
			if !has_text && has_cur && !vkey_less(x, cur) {
				continue
			}
			sp := _source(e, h.seg)
			if sp == nil {
				continue
			}
			ok := _vec_ok(e, sp, h.id) or_return
			if !ok {
				continue
			}
			dm := _meta(e, sp, h.id) or_return
			x.obj = dm.object
			x.hlc = dm.hlc
			append(&vl, x)
			if len(vl) == depth {
				break
			}
		}
		if len(vl) >= depth || len(cand) < need || round == 4 {
			break
		}
		need *= 4
		scale *= 2
	}
	all := make([dynamic]Entry, e.alloc)
	if !has_text {
		append(&all, ..vl[:])
	} else {
		e.k = depth
		for i := len(e.srcs) - 1; i >= 0 && !e.stop; i -= 1 {
			_run_source(e, &e.srcs[i]) or_return
		}
		if e.err != .None {
			return res, e.err
		}
		slice.sort_by(e.heap[:], proc(x, y: Entry) -> bool {
			return _entry_less(y, x)
		})
		fused := make(map[u32]int, e.alloc)
		for x, rank in vl {
			fused[x.id] = len(all)
			y := x
			y.score = 1 / (RRF_K + f64(rank + 1))
			append(&all, y)
		}
		for x, rank in e.heap {
			add := 1 / (RRF_K + f64(rank + 1))
			if i, ok := fused[x.id]; ok {
				all[i].score += add
			} else {
				fused[x.id] = len(all)
				y := x
				y.score = add
				append(&all, y)
			}
		}
	}
	slice.sort_by(all[:], proc(x, y: Entry) -> bool {
		if x.score != y.score {
			return x.score > y.score
		}
		return x.id > y.id
	})
	kept := make([dynamic]Entry, e.alloc)
	seen := make(map[prim.Id]bool, e.alloc)
	for x in all {
		if has_text && has_cur && !vkey_less(x, cur) {
			continue
		}
		if e.collapse {
			if x.obj in seen {
				continue
			}
			seen[x.obj] = true
		}
		append(&kept, x)
	}
	n := min(len(kept), limit)
	hits := make([]Hit, n, allocator)
	for i in 0 ..< n {
		_make_hit(e, kept[i], &hits[i], allocator) or_return
	}
	res.hits = hits
	res.incomplete = e.incomplete
	res.verified = e.verified
	if len(kept) > limit {
		last := kept[limit - 1]
		out := make([dynamic]u8, allocator)
		w := prim.writer(&out)
		prim.write_u8(&w, VCURSOR_VERSION)
		prim.write_u8(&w, u8(e.sort))
		prim.write_u64le(&w, qhash)
		prim.write_u64le(&w, transmute(u64)last.score)
		prim.write_u32le(&w, last.id)
		res.cursor = out[:]
	}
	return res, .None
}

@(private)
_tri_plan :: proc(e: ^Exec, sp: ^Src_Plan, at: ^Atom, p: ^Atom_Src) -> Error {
	p.kind = .List
	for k in at.keys {
		kb: [8]u8
		n := key64_bytes(k, &kb)
		h, found := _lookup(e, sp, kb[:n]) or_return
		if !found {
			p.kind = .Empty
			clear(&p.cands)
			return .None
		}
		append(&p.cands, h)
	}
	slice.sort_by(p.cands[:], proc(x, y: Handle) -> bool {
		return x.term.count < y.term.count
	})
	append(&p.checks, ..p.cands[:])
	if len(p.cands) > MAX_CANDS {
		resize(&p.cands, MAX_CANDS)
	}
	return .None
}

@(private)
_vocab :: proc(e: ^Exec, sp: ^Src_Plan, text: []u8) -> (hs: [dynamic]Handle, ok: bool, err: Error) {
	hs = make([dynamic]Handle, e.alloc)
	if sp.seg == nil {
		m := &e.ix.mem
		for &t, ti in m.terms {
			if t.klen == 0 || m.karena[t.koff] != NS_WORD {
				continue
			}
			k := _long_key(m, &t)
			if !bytes.contains(k[1:], text) {
				continue
			}
			if len(hs) >= VOCAB_CAP {
				return hs, false, .None
			}
			h := _mem_handle(e, u32(ti)) or_return
			if h.term.count > 0 {
				append(&hs, h)
			}
		}
		return hs, true, .None
	}
	it := new(Iter, e.alloc)
	it.kind = .And
	it.kids = make([dynamic]^Iter, e.alloc)
	for i := 0; i + 3 <= len(text); i += 1 {
		key := [4]u8{NS_VTRI, text[i], text[i + 1], text[i + 2]}
		t, found := term_lookup(sp.dc, key[:]) or_return
		if !found {
			return hs, true, .None
		}
		append(&it.kids, _iter_list(e, sp, Handle{term = t}))
	}
	smallest := max(u32)
	for kid in it.kids {
		smallest = min(smallest, kid.count)
	}
	if smallest > VOCAB_SCAN {
		return hs, false, .None
	}
	slice.sort_by(it.kids[:], proc(x, y: ^Iter) -> bool {
		return x.count < y.count
	})
	ords := make([dynamic]u32, e.alloc)
	t := u32(max(u32))
	for {
		o, found := _seek(e, it, t)
		if !found || e.err != .None {
			break
		}
		if len(ords) >= VOCAB_SCAN {
			return hs, false, .None
		}
		append(&ords, o)
		if o == 0 {
			break
		}
		t = o - 1
	}
	slice.reverse(ords[:])
	matched := make([dynamic]u32, e.alloc)
	tb: [MAX_WORD]u8
	for o in ords {
		tok := vocab_token(&e.ix.cache, sp.seg, o, &tb) or_return
		if bytes.contains(tok, text) {
			if len(matched) >= VOCAB_CAP {
				return hs, false, .None
			}
			append(&matched, o)
		}
	}
	for o in matched {
		t := word_term(&e.ix.cache, sp.seg, o) or_return
		append(&hs, Handle{term = t})
	}
	return hs, true, e.err
}

@(private)
_seek_union :: proc(e: ^Exec, it: ^Iter, t: u32) -> (u32, bool) {
	h := &it.heap
	if !it.init {
		it.init = true
		it.heap = make([dynamic]^Iter, 0, len(it.kids), e.alloc)
		for kid in it.kids {
			if kid.kind == .List {
				kid.val = kid.bhi
				kid.has = false
			} else {
				v, ok := _seek(e, kid, t)
				if !ok {
					continue
				}
				kid.val = v
				kid.has = true
			}
			append(h, kid)
		}
		for i := len(h) / 2 - 1; i >= 0; i -= 1 {
			_iter_sift(h[:], i)
		}
	}
	for len(h) > 0 {
		top := h[0]
		if top.val <= t {
			return top.val, true
		}
		if !top.has && t < top.blo {
			h[0] = h[len(h) - 1]
			pop(h)
		} else {
			v, ok := _seek(e, top, t)
			if ok {
				top.val = v
				top.has = true
			} else {
				h[0] = h[len(h) - 1]
				pop(h)
			}
		}
		if len(h) > 0 {
			_iter_sift(h[:], 0)
		}
	}
	return 0, false
}

@(private)
_iter_sift :: proc(h: []^Iter, i0: int) {
	i := i0
	for {
		l := 2 * i + 1
		if l >= len(h) {
			return
		}
		m := l
		if l + 1 < len(h) && h[l + 1].val > h[l].val {
			m = l + 1
		}
		if h[m].val <= h[i].val {
			return
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

@(private)
_vc :: proc(e: ^Exec, sp: ^Src_Plan, p: ^Atom_Src, j: int) -> ^Plist {
	if p.vcands[j] == nil {
		for k in 0 ..< len(p.words) {
			if p.has[k] && _same_list(p.checks[j], p.words[k]) {
				p.vcands[j] = _vw(e, sp, p, k)
				return p.vcands[j]
			}
		}
		p.vcands[j] = _plist(e, sp, p.checks[j])
	}
	return p.vcands[j]
}

@(private)
_same_list :: proc "contextless" (a, b: Handle) -> bool {
	return a.mem == b.mem && a.term.off == b.term.off && a.term.count == b.term.count && a.term.hi == b.term.hi && a.term.lo == b.term.lo && a.term.inl == b.term.inl && a.term.vals == b.term.vals && raw_data(a.ids) == raw_data(b.ids)
}

@(private)
_vw :: proc(e: ^Exec, sp: ^Src_Plan, p: ^Atom_Src, j: int) -> ^Plist {
	if j < 0 || j >= len(p.has) || !p.has[j] {
		return nil
	}
	if p.vwords[j] == nil {
		for k in 0 ..< len(p.checks) {
			if p.vcands[k] != nil && _same_list(p.checks[k], p.words[j]) {
				p.vwords[j] = p.vcands[k]
				return p.vwords[j]
			}
		}
		p.vwords[j] = _plist(e, sp, p.words[j])
	}
	return p.vwords[j]
}

@(private)
_vt :: proc(e: ^Exec, sp: ^Src_Plan, p: ^Atom_Src, j: int) -> ^Plist {
	if p.vtris[j] == nil {
		p.vtris[j] = _plist(e, sp, p.tris[j])
	}
	return p.vtris[j]
}

Block_Act :: enum u8 {
	Go,
	Skip,
	Stop,
}

@(private)
_block_enter :: proc(e: ^Exec, sp: ^Src_Plan, blk: u64) -> (act: Block_Act, err: Error) {
	sp.dir = _source_dir(e, sp, blk) or_return
	if len(e.heap) == e.k {
		kth := e.heap[0]
		stop := false
		switch e.sort {
		case .Newest:
			stop = sp.dir.pmax <= kth.hlc
		case .Relevance:
			stop = (1 + _remaining_bound(e, sp)) * _decay(e, sp.dir.pmax) < kth.score
		}
		if stop {
			if e.sort == .Newest {
				e.stop = true
			}
			return .Stop, .None
		}
	}
	if sp.dir.max_hlc < e.after || sp.dir.min_hlc >= e.before {
		return .Skip, .None
	}
	return .Go, .None
}

BM_MIN :: 1 << 13
BM_MAX :: 1 << 16

@(private)
_bm :: proc(e: ^Exec, it: ^Iter, lo, hi: u32, out: []u64) {
	slice.fill(out, 0)
	switch it.kind {
	case .Empty:
	case .All:
		a := max(lo, it.lo)
		for x := a; x < hi; x += 1 {
			k := x - lo
			out[k >> 6] |= u64(1) << (k & 63)
		}
	case .List:
		if it.bhi < lo || (it.count > INLINE && it.blo >= hi) {
			return
		}
		if it.pl == nil {
			it.pl = _plist(e, it.sp, it.h)
		}
		pl_fill(it.pl, lo, hi, out)
		if it.pl.err != .None && e.err == .None {
			e.err = it.pl.err
		}
	case .Or:
		for kid in it.kids {
			if kid.kind == .List {
				if kid.bhi < lo || kid.blo >= hi {
					continue
				}
				if kid.pl == nil {
					kid.pl = _plist(e, kid.sp, kid.h)
				}
				pl_fill(kid.pl, lo, hi, out)
				continue
			}
			if kid.bm == nil {
				kid.bm = make([]u64, BM_MAX / 64, e.alloc)
			}
			_bm(e, kid, lo, hi, kid.bm[:len(out)])
			for w, i in kid.bm[:len(out)] {
				out[i] |= w
			}
		}
	case .And:
		for kid, k in it.kids {
			if kid.bm == nil {
				kid.bm = make([]u64, BM_MAX / 64, e.alloc)
			}
			if k == 0 {
				_bm(e, kid, lo, hi, out)
				continue
			}
			_bm(e, kid, lo, hi, kid.bm[:len(out)])
			any := u64(0)
			for w, i in kid.bm[:len(out)] {
				out[i] &= w
				any |= out[i]
			}
			if any == 0 {
				return
			}
		}
	}
}

@(private)
_covered :: proc(it: ^Iter, neg: []Handle) -> bool {
	switch it.kind {
	case .Empty:
		return true
	case .All:
		return false
	case .List:
		for h in neg {
			if _same_list(it.h, h) {
				return true
			}
		}
		return false
	case .Or:
		for kid in it.kids {
			if !_covered(kid, neg) {
				return false
			}
		}
		return len(it.kids) > 0
	case .And:
		for kid in it.kids {
			if _covered(kid, neg) {
				return true
			}
		}
		return false
	}
	return false
}

@(private)
_run_bitmap :: proc(e: ^Exec, sp: ^Src_Plan, root: ^Iter, neg: []Handle, excl: []^Atom) -> Error {
	a := e.alloc
	if _covered(root, neg) {
		return .None
	}
	pos := make([]u64, BM_MAX / 64, a)
	nb := make([]u64, BM_MAX / 64, a)
	negs := make([]^Iter, len(neg), a)
	for h, i in neg {
		negs[i] = _iter_list(e, sp, h)
		negs[i].blo, negs[i].bhi = h.term.lo, h.term.hi
		if h.mem && len(h.ids) > 0 {
			negs[i].blo, negs[i].bhi = h.ids[0], h.ids[len(h.ids) - 1]
		}
	}
	win := u32(BM_MIN)
	hi := u32(sp.hi)
	last_blk := max(u64)
	skip_blk := max(u64)
	skip_floor := u32(0)
	have_skip := false
	for u64(hi) > sp.lo {
		if have_skip && skip_floor < hi {
			if u64(skip_floor) <= sp.lo {
				break
			}
			hi = skip_floor
			have_skip = false
		}
		if len(e.heap) == e.k {
			act := _block_enter(e, sp, u64(hi - 1) / DOC_BLOCK) or_return
			if act == .Stop {
				return e.err
			}
			last_blk = max(u64)
		}
		w := min(win, hi - u32(sp.lo))
		lo := hi - w
		nw := int((w + 63) / 64)
		_bm(e, root, lo, hi, pos[:nw])
		if e.err != .None {
			return e.err
		}
		if len(negs) > 0 {
			slice.fill(nb[:nw], 0)
			for x in negs {
				if x.bhi < lo || x.blo >= hi {
					continue
				}
				if x.pl == nil {
					x.pl = _plist(e, x.sp, x.h)
				}
				pl_fill(x.pl, lo, hi, nb[:nw])
			}
			for i in 0 ..< nw {
				pos[i] &~= nb[i]
			}
		}
		for i := nw - 1; i >= 0; i -= 1 {
			word := pos[i]
			for word != 0 {
				b := 63 - intrinsics.count_leading_zeros(word)
				word &~= u64(1) << u64(b)
				d := lo + u32(i) * 64 + u32(b)
				blk := u64(d) / DOC_BLOCK
				if blk == skip_blk || (have_skip && d >= skip_floor) {
					continue
				}
				if blk != last_blk {
					act := _block_enter(e, sp, blk) or_return
					switch act {
					case .Stop:
						return .None
					case .Skip:
						skip_blk = blk
						continue
					case .Go:
					}
					last_blk = blk
				}
				if f, skip := _bmw(e, sp, d); skip {
					skip_floor = f
					have_skip = true
					continue
				}
				excluded := false
				for x in excl {
					if _verdict(e, sp, x, nil, d) > 0 {
						excluded = true
						break
					}
				}
				if !excluded {
					_consider(e, sp, d) or_return
				}
			}
		}
		hi = lo
		win = min(win * 4, BM_MAX)
	}
	return e.err
}

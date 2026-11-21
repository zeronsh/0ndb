package search

import "base:runtime"
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
CURSOR_VERSION :: u8(1)

Sort :: enum u8 {
	Relevance,
	Newest,
}

Request :: struct {
	limit:        int,
	cursor:       []u8,
	sort:         Sort,
	now:          prim.Hlc,
	half_life_ms: i64,
	participants: Participants,
	file_key:     File_Key,
	resolve_data: rawptr,
	vector:       []f32,
	semantic:     bool,
	embed_kind:   u8,
	nprobe:       int,
	rerank:       int,
}

Match :: struct {
	start: u32,
	len:   u32,
}

Hit :: struct {
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
	lo:    u32,
	val:   u32,
	has:   bool,
	done:  bool,
	count: u32,
}

Atom_Plan :: struct {
	kind:  Iter_Kind,
	terms: [dynamic]Term,
	extra: [dynamic]Term,
}

Entry :: struct {
	score: f64,
	hlc:   u64,
	id:    u32,
	seg:   int,
}

@(private)
Exec :: struct {
	ix:        ^Index,
	q:         ^Query,
	atoms:     [dynamic]^Atom,
	sort:      Sort,
	now_ms:    i64,
	half_life: i64,
	n_docs:    f64,
	avgdl:     f64,
	bm25max:   f64,
	dead:      []u32,
	heap:      [dynamic]Entry,
	k:         int,
	has_cur:   bool,
	cur:       Entry,
	blk:       Doc_Block,
	text:      [dynamic]u8,
	folded:    [dynamic]u8,
	frame:     [dynamic]u8,
	frame_at:  i64,
	frame_gen: u64,
	fscratch:  [dynamic]u8,
	occ:       [MAX_ATOMS]Occurrences,
	occ_done:  [MAX_ATOMS]bool,
	have_text: bool,
	text_ok:   bool,
	after:     u64,
	before:    u64,
	incomplete: bool,
	verified:  int,
	stop:      bool,
	err:       Error,
	alloc:     runtime.Allocator,
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
_heap_push :: proc(e: ^Exec, x: Entry) {
	h := &e.heap
	if len(h) == e.k {
		if !_entry_less(h[0], x) {
			return
		}
		h[0] = x
		i := 0
		for {
			l := 2 * i + 1
			if l >= len(h) {
				break
			}
			m := l
			if l + 1 < len(h) && _entry_less(h[l + 1], h[l]) {
				m = l + 1
			}
			if !_entry_less(h[m], h[i]) {
				break
			}
			h[i], h[m] = h[m], h[i]
			i = m
		}
		return
	}
	append(h, x)
	i := len(h) - 1
	for i > 0 {
		p := (i - 1) / 2
		if !_entry_less(h[i], h[p]) {
			break
		}
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

@(private)
_decay :: proc "contextless" (e: ^Exec, hlc: u64) -> f64 {
	age := e.now_ms - i64(hlc >> 16)
	if age <= 0 {
		return 1
	}
	return math.pow(2, -f64(age) / f64(e.half_life))
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
	e.k = clamp(r.limit if r.limit > 0 else DEFAULT_LIMIT, 1, MAX_LIMIT) + 1
	e.half_life = r.half_life_ms if r.half_life_ms > 0 else DEFAULT_HALF_LIFE
	e.now_ms = i64(u64(r.now) >> 16) if r.now != 0 else prim.now_ms()
	e.n_docs = max(f64(ix.man.next_doc), 1)
	e.avgdl = max(f64(ix.man.total_len) / e.n_docs, 1)
	e.heap = make([dynamic]Entry, 0, e.k, a)
	e.before = max(u64)
	db_init(&e.blk, a)
	e.text = make([dynamic]u8, a)
	e.folded = make([dynamic]u8, a)
	e.frame = make([dynamic]u8, a)
	e.fscratch = make([dynamic]u8, a)
	e.frame_at = -1
	if len(r.cursor) >= 18 && r.cursor[0] == CURSOR_VERSION {
		e.now_ms = i64(prim.get_u64le(r.cursor[10:]))
	}
	q := parse(ix, query, &r, e.now_ms, a) or_return
	e.q = &q
	e.atoms = make([dynamic]^Atom, a)
	for &c in q.clauses {
		for &at in c.atoms {
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
	dead := make([dynamic]u32, a)
	for &s in ix.segs {
		tomb_load(&s, &dead) or_return
	}
	append(&dead, ..ix.mem.dead[:])
	slice.sort(dead[:])
	e.dead = slice.unique(dead[:])
	nseg := len(ix.segs)
	plans := make([][]Atom_Plan, nseg, a)
	df := make([]f64, len(e.atoms), a)
	for si in 0 ..< nseg {
		plans[si] = _plan_segment(e, &ix.segs[si], df) or_return
	}
	qv := _query_vector(e, &r) or_return
	if len(r.cursor) > 0 && qv == nil {
		_cursor_decode(e, r.cursor, qhash) or_return
	} else {
		for at, i in e.atoms {
			if _is_text(at) && !at.neg {
				d := clamp(df[i], 0, e.n_docs)
				at.idf = math.ln(1 + (e.n_docs - d + 0.5) / (d + 0.5))
			}
		}
	}
	for at in e.atoms {
		if _is_text(at) && !at.neg {
			at.scored = true
			e.bm25max += at.idf * (K1 + 1)
		}
	}
	if qv != nil {
		return _search_vector(e, qv, plans, &r, qhash, allocator)
	}
	for si := nseg - 1; si >= 0 && !e.stop; si -= 1 {
		_run_segment(e, si, plans[si]) or_return
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
		res.cursor = _cursor_encode(e, qhash, e.heap[limit - 1], allocator)
	}
	return res, .None
}

@(private)
_is_text :: proc "contextless" (a: ^Atom) -> bool {
	#partial switch a.field {
	case .Any, .Title, .Body:
		return true
	}
	return false
}

@(private)
_plan_segment :: proc(e: ^Exec, s: ^Seg, df: []f64) -> (plans: []Atom_Plan, err: Error) {
	a := e.alloc
	plans = make([]Atom_Plan, len(e.atoms), a)
	dix := dix_load(&e.ix.cache, s, a) or_return
	pdix := new_clone(dix, a)
	dc := new(Dict_Cursor, a)
	dc_init(dc, &e.ix.cache, s, pdix, a)
	for at, i in e.atoms {
		p := &plans[i]
		p.terms = make([dynamic]Term, a)
		p.extra = make([dynamic]Term, a)
		p.kind = .All
		if at.neg {
			continue
		}
		key: [MAX_KEY]u8
		switch at.field {
		case .Any, .Title, .Body:
			t := at.text
			if len(t) >= 3 {
				p.kind = .List
				mn := f64(max(f64))
				for k in 0 ..< len(t) - 2 {
					kk := key32(NS_TRI, t[k], t[k + 1], t[k + 2])
					dup := false
					for j in 0 ..< k {
						if key32(NS_TRI, t[j], t[j + 1], t[j + 2]) == kk {
							dup = true
							break
						}
					}
					if dup {
						continue
					}
					kb: [4]u8
					n := key32_bytes(kk, &kb)
					term, found := term_lookup(dc, kb[:n]) or_return
					if !found {
						p.kind = .Empty
						mn = 0
						break
					}
					append(&p.terms, term)
					mn = min(mn, f64(term.count))
				}
				df[i] += mn
			} else if _word_only(t) {
				kb: [4]u8
				n := key32_bytes(word_key(t), &kb)
				term, found := term_lookup(dc, kb[:n]) or_return
				if found {
					p.kind = .List
					append(&p.terms, term)
					df[i] += f64(term.count)
				} else {
					p.kind = .Empty
				}
				at.word = true
			} else {
				df[i] += f64(s.f.hi - s.f.lo) / 2
			}
			if at.field == .Title && p.kind == .List {
				kb: [4]u8
				n := key32_bytes(key32(NS_TITLE, 1, 0, 0), &kb)
				term, found := term_lookup(dc, kb[:n]) or_return
				if !found {
					p.kind = .Empty
				} else {
					append(&p.terms, term)
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
						term, found := term_lookup(dc, key[:base + 3]) or_return
						if !found {
							p.kind = .Empty
							break
						}
						append(&p.terms, term)
					}
				}
			} else if n, ok := field_key(NS_FIELD, at.name, at.text, &key); ok {
				_range_terms(dc, p, key[:n], at.prefix, 0) or_return
			}
		case .Kind:
			kb: [4]u8
			n := key32_bytes(key32(NS_KIND, at.kind, 0, 0), &kb)
			term, found := term_lookup(dc, kb[:n]) or_return
			p.kind = .List if found else .Empty
			if found {
				append(&p.terms, term)
			}
		case .Object, .From, .Wrote:
			key[0] = NS_OBJECT if at.field != .From else NS_FROM
			if at.field == .Wrote || len(at.ids) > 0 || (at.field == .From && at.nibbles == 0) {
				p.kind = .Empty
				for id in at.ids {
					v := id
					copy(key[1:], v[:])
					term, found := term_lookup(dc, key[:17]) or_return
					if found {
						append(&p.terms, term)
						p.kind = .Or
					}
				}
			} else {
				n := 1 + copy(key[1:], at.text[:at.nibbles / 2])
				_range_terms(dc, p, key[:n], at.prefix, at.nibbles) or_return
			}
		case .After, .Before:
		}
	}
	return plans, .None
}

@(private)
_word_only :: proc "contextless" (t: []u8) -> bool {
	for c in t {
		if !is_word(c) {
			return false
		}
	}
	return len(t) > 0
}

@(private)
_range_terms :: proc(dc: ^Dict_Cursor, p: ^Atom_Plan, key: []u8, prefix: bool, nibbles: int) -> Error {
	if !prefix {
		term, found := term_lookup(dc, key) or_return
		p.kind = .List if found else .Empty
		if found {
			append(&p.terms, term)
		}
		return .None
	}
	p.kind = .Empty
	if !dc_seek(dc, key) {
		return dc.err
	}
	for {
		k := dc_key(dc)
		if len(k) < len(key) || string(k[:len(key)]) != string(key) {
			break
		}
		ok := true
		if nibbles % 2 == 1 {
			full := nibbles / 2
			if len(k) <= 1 + full {
				ok = false
			}
		}
		if ok {
			if len(p.terms) >= MAX_RANGE_TERMS {
				clear(&p.terms)
				p.kind = .All
				return .None
			}
			append(&p.terms, dc.term)
			p.kind = .Or
		}
		if !dc_next(dc) {
			break
		}
	}
	return dc.err
}

@(private)
_iter_list :: proc(e: ^Exec, s: ^Seg, t: Term) -> ^Iter {
	it := new(Iter, e.alloc)
	it.kind = .List
	it.pl = new(Plist, e.alloc)
	it.count = t.count
	pl_init(it.pl, &e.ix.cache, s, t)
	return it
}

@(private)
_iter_atom :: proc(e: ^Exec, s: ^Seg, p: ^Atom_Plan, at: ^Atom) -> ^Iter {
	it := new(Iter, e.alloc)
	it.kind = p.kind
	it.lo = u32(s.f.lo)
	switch p.kind {
	case .Empty, .All:
	case .List, .And:
		if len(p.terms) == 1 {
			return _iter_list(e, s, p.terms[0])
		}
		it.kind = .And
		it.kids = make([dynamic]^Iter, e.alloc)
		for t in p.terms {
			append(&it.kids, _iter_list(e, s, t))
		}
		slice.sort_by(it.kids[:], proc(x, y: ^Iter) -> bool {
			return x.count < y.count
		})
	case .Or:
		it.kids = make([dynamic]^Iter, e.alloc)
		for t in p.terms {
			append(&it.kids, _iter_list(e, s, t))
		}
		if len(it.kids) == 0 {
			it.kind = .Empty
		}
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
_run_segment :: proc(e: ^Exec, si: int, plans: []Atom_Plan) -> Error {
	s := &e.ix.segs[si]
	if s.f.hi == s.f.lo {
		return .None
	}
	a := e.alloc
	root := new(Iter, a)
	root.kind = .And
	root.lo = u32(s.f.lo)
	root.kids = make([dynamic]^Iter, a)
	idx := 0
	for &c in e.q.clauses {
		ci: ^Iter
		all := false
		empty := 0
		kids := make([dynamic]^Iter, a)
		for &at in c.atoms {
			p := &plans[idx]
			idx += 1
			if p.kind == .All {
				all = true
				continue
			}
			if p.kind == .Empty {
				empty += 1
				continue
			}
			append(&kids, _iter_atom(e, s, p, &at))
		}
		if all {
			continue
		}
		if len(kids) == 0 {
			return .None
		}
		if len(kids) == 1 {
			ci = kids[0]
		} else {
			ci = new(Iter, a)
			ci.kind = .Or
			ci.kids = kids
		}
		append(&root.kids, ci)
	}
	if len(root.kids) == 0 {
		root.kind = .All
	} else if len(root.kids) == 1 {
		root = root.kids[0]
	}
	t := u32(s.f.hi - 1)
	last_blk := max(u64)
	for {
		d, ok := _seek(e, root, t)
		if !ok || e.err != .None {
			break
		}
		blk := u64(d) / DOC_BLOCK
		if blk != last_blk {
			dir, derr := seg_dir(&e.ix.cache, s, blk)
			if derr != .None {
				return derr
			}
			if len(e.heap) == e.k && _bound_fails(e, dir.pmax) {
				e.stop = true
				return .None
			}
			if dir.max_hlc < e.after || dir.min_hlc >= e.before {
				start := max(blk * DOC_BLOCK, s.f.lo)
				if start == s.f.lo {
					break
				}
				t = u32(start - 1)
				continue
			}
			last_blk = blk
		}
		_consider(e, si, s, d) or_return
		if u64(d) == s.f.lo {
			break
		}
		t = d - 1
	}
	return e.err
}

@(private)
_bound_fails :: proc(e: ^Exec, pmax: u64) -> bool {
	kth := e.heap[0]
	switch e.sort {
	case .Newest:
		return pmax <= kth.hlc
	case .Relevance:
		return (1 + e.bm25max) * _decay(e, pmax) < kth.score
	}
	return false
}

@(private)
_dead :: proc(e: ^Exec, id: u32) -> bool {
	_, found := slice.binary_search(e.dead, id)
	return found
}

@(private)
_fetch_text :: proc(e: ^Exec, s: ^Seg, dm: ^Doc_Meta) -> bool {
	if e.have_text {
		return e.text_ok
	}
	e.have_text = true
	e.text_ok = false
	n := int(dm.len)
	if n == 0 {
		clear(&e.text)
		clear(&e.folded)
		e.text_ok = true
		return true
	}
	if e.ix.man.store {
		if dm.flags & DF_TEXT == 0 {
			return false
		}
		if e.frame_at != dm.frame || e.frame_gen != s.gen {
			e.frame_at = -1
			if err := frame_read(&e.ix.cache, s, dm.frame, &e.frame, &e.fscratch); err != .None {
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
		if grow(&e.text, n) != nil {
			e.err = .No_Memory
			return false
		}
		copy(e.text[:], e.frame[dm.frame_off:][:n])
	} else {
		if grow(&e.text, n) != nil {
			e.err = .No_Memory
			return false
		}
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
	if grow(&e.folded, n) != nil {
		e.err = .No_Memory
		return false
	}
	fold_into(e.folded[:], e.text[:])
	e.text_ok = true
	return true
}

@(private)
_eval :: proc(e: ^Exec, s: ^Seg, dm: ^Doc_Meta, at: ^Atom, i: int, defer_text: bool) -> (val: bool, needs_text: bool) {
	r := false
	switch at.field {
	case .Any, .Title, .Body:
		is_title := dm.flags & DF_TITLE != 0
		if at.field == .Title && !is_title {
			return at.neg, false
		}
		if at.field == .Body && is_title {
			return at.neg, false
		}
		if defer_text {
			return false, true
		}
		if !e.occ_done[i] {
			if !_fetch_text(e, s, dm) {
				e.occ[i] = {}
				e.occ[i].first = -1
			} else {
				e.occ[i] = find_all(e.folded[:], at.text, at.word)
			}
			e.occ_done[i] = true
		}
		r = e.occ[i].count > 0
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
	return r != at.neg, false
}

@(private)
_consider :: proc(e: ^Exec, si: int, s: ^Seg, d: u32) -> Error {
	blk := u64(d) / DOC_BLOCK
	doc_load(&e.ix.cache, s, &e.blk, blk) or_return
	dm := &e.blk.docs[d - e.blk.first]
	if dm.flags & DF_DELETED != 0 || _dead(e, d) {
		return .None
	}
	if dm.hlc < e.after || dm.hlc >= e.before {
		return .None
	}
	e.have_text = false
	for i in 0 ..< len(e.atoms) {
		e.occ_done[i] = false
		e.occ[i] = {}
	}
	idx := 0
	pending := false
	for &c in e.q.clauses {
		ok := false
		text_wait := false
		for &at, j in c.atoms {
			v, nt := _eval(e, s, dm, &at, idx + j, true)
			if nt {
				text_wait = true
			} else if v {
				ok = true
				break
			}
		}
		idx += len(c.atoms)
		if !ok && !text_wait {
			return .None
		}
		if !ok {
			pending = true
		}
	}
	e.verified += 1
	if pending {
		idx = 0
		for &c in e.q.clauses {
			ok := false
			for &at, j in c.atoms {
				v, _ := _eval(e, s, dm, &at, idx + j, false)
				if v {
					ok = true
					break
				}
			}
			idx += len(c.atoms)
			if !ok {
				return e.err
			}
		}
	}
	x := Entry {
		hlc = dm.hlc,
		id  = d,
		seg = si,
	}
	if e.sort == .Relevance {
		bm := 0.0
		dl := f64(dm.len)
		for at, i in e.atoms {
			if !at.scored {
				continue
			}
			if !e.occ_done[i] {
				v, _ := _eval(e, s, dm, at, i, false)
				_ = v
			}
			tf := e.occ[i].weight
			if tf > 0 {
				bm += at.idf * tf * (K1 + 1) / (tf + K1 * (1 - B + B * dl / e.avgdl))
			}
		}
		x.score = (1 + bm) * _decay(e, dm.hlc)
	}
	if e.has_cur && !_entry_less(x, e.cur) {
		return e.err
	}
	_heap_push(e, x)
	return e.err
}

@(private)
_make_hit :: proc(e: ^Exec, x: Entry, h: ^Hit, allocator: runtime.Allocator) -> Error {
	s := &e.ix.segs[x.seg]
	doc_load(&e.ix.cache, s, &e.blk, u64(x.id) / DOC_BLOCK) or_return
	dm := &e.blk.docs[x.id - e.blk.first]
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
	if !_fetch_text(e, s, dm) {
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
		if o.first >= 0 && at.idf > best {
			best = at.idf
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
	ms := make([dynamic]Match, allocator)
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
	delete(ms)
	h.matches = out[:]
	return .None
}

@(private)
_cursor_encode :: proc(e: ^Exec, qhash: u64, last: Entry, allocator: runtime.Allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	w := prim.writer(&out)
	prim.write_u8(&w, CURSOR_VERSION)
	prim.write_u8(&w, u8(e.sort))
	prim.write_u64le(&w, qhash)
	prim.write_u64le(&w, u64(e.now_ms))
	prim.write_u64le(&w, u64(e.half_life))
	prim.write_u64le(&w, transmute(u64)e.n_docs)
	prim.write_u64le(&w, transmute(u64)e.avgdl)
	prim.write_u8(&w, u8(len(e.atoms)))
	for at in e.atoms {
		prim.write_u64le(&w, transmute(u64)at.idf)
	}
	prim.write_u64le(&w, transmute(u64)last.score)
	prim.write_u64le(&w, last.hlc)
	prim.write_u32le(&w, last.id)
	return out[:]
}

@(private)
_cursor_decode :: proc(e: ^Exec, c: []u8, qhash: u64) -> Error {
	r := prim.reader(c)
	if prim.read_u8(&r) != CURSOR_VERSION {
		return .Invalid
	}
	if Sort(prim.read_u8(&r)) != e.sort || prim.read_u64le(&r) != qhash {
		return .Invalid
	}
	e.now_ms = i64(prim.read_u64le(&r))
	e.half_life = i64(prim.read_u64le(&r))
	e.n_docs = transmute(f64)prim.read_u64le(&r)
	e.avgdl = transmute(f64)prim.read_u64le(&r)
	n := int(prim.read_u8(&r))
	if n != len(e.atoms) || e.half_life <= 0 {
		return .Invalid
	}
	for at in e.atoms {
		at.idf = transmute(f64)prim.read_u64le(&r)
		if math.is_nan(at.idf) || at.idf < 0 {
			return .Invalid
		}
	}
	e.cur.score = transmute(f64)prim.read_u64le(&r)
	e.cur.hlc = prim.read_u64le(&r)
	e.cur.id = prim.read_u32le(&r)
	if !prim.reader_done(&r) {
		return .Invalid
	}
	e.has_cur = true
	return .None
}

@(private)
_fold_eq :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if fold(a[i]) != b[i] {
			return false
		}
	}
	return true
}

VCURSOR_VERSION :: u8(2)
RRF_K :: 60.0

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
_vec_ok :: proc(e: ^Exec, si: int, id: u32) -> (ok: bool, err: Error) {
	s := &e.ix.segs[si]
	doc_load(&e.ix.cache, s, &e.blk, u64(id) / DOC_BLOCK) or_return
	dm := &e.blk.docs[id - e.blk.first]
	if dm.flags & DF_DELETED != 0 || _dead(e, id) || dm.hlc < e.after || dm.hlc >= e.before {
		return false, .None
	}
	idx := 0
	for &c in e.q.clauses {
		pass := false
		for &at, j in c.atoms {
			if _is_text(&at) {
				pass = true
				break
			}
			v, _ := _eval(e, s, dm, &at, idx + j, true)
			if v {
				pass = true
				break
			}
		}
		idx += len(c.atoms)
		if !pass {
			return false, .None
		}
	}
	return true, .None
}

@(private)
_search_vector :: proc(e: ^Exec, qv: []f32, plans: [][]Atom_Plan, r: ^Request, qhash: u64, allocator: runtime.Allocator) -> (res: Results, err: Error) {
	offset := 0
	if len(r.cursor) > 0 {
		c := prim.reader(r.cursor)
		if prim.read_u8(&c) != VCURSOR_VERSION || prim.read_u8(&c) != u8(e.sort) || prim.read_u64le(&c) != qhash {
			return res, .Invalid
		}
		offset = int(prim.read_u32le(&c))
		if !prim.reader_done(&c) {
			return res, .Invalid
		}
	}
	limit := e.k - 1
	want := offset + limit + 1
	vl := make([dynamic]Entry, e.alloc)
	nprobe := r.nprobe if r.nprobe > 0 else DEFAULT_NPROBE
	need := want
	for round in 0 ..< 5 {
		cand := vec_candidates(e, qv, need, nprobe, r.rerank) or_return
		clear(&vl)
		for h in cand {
			ok := _vec_ok(e, h.seg, h.id) or_return
			if ok {
				append(&vl, Entry{score = f64(h.score), id = h.id, seg = h.seg})
				if len(vl) == want {
					break
				}
			}
		}
		if len(vl) >= want || (len(cand) < max(r.rerank, RERANK_MIN, RERANK_FACTOR * need) && nprobe >= MAX_LISTS) || round == 4 {
			break
		}
		need *= 4
		nprobe = min(nprobe * 4, MAX_LISTS)
	}
	has_text := false
	for at in e.atoms {
		if at.scored {
			has_text = true
		}
	}
	all := make([dynamic]Entry, e.alloc)
	if !has_text {
		append(&all, ..vl[:])
	} else {
		e.k = want
		for si := len(e.ix.segs) - 1; si >= 0 && !e.stop; si -= 1 {
			_run_segment(e, si, plans[si]) or_return
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
			append(&all, Entry{score = 1 / (RRF_K + f64(rank + 1)), id = x.id, seg = x.seg})
		}
		for x, rank in e.heap {
			add := 1 / (RRF_K + f64(rank + 1))
			if i, ok := fused[x.id]; ok {
				all[i].score += add
			} else {
				fused[x.id] = len(all)
				append(&all, Entry{score = add, id = x.id, seg = x.seg})
			}
		}
	}
	slice.sort_by(all[:], proc(x, y: Entry) -> bool {
		return _entry_less(y, x)
	})
	lo := min(offset, len(all))
	hi := min(offset + limit, len(all))
	hits := make([]Hit, hi - lo, allocator)
	for i in lo ..< hi {
		_make_hit(e, all[i], &hits[i - lo], allocator) or_return
	}
	res.hits = hits
	res.incomplete = e.incomplete
	res.verified = e.verified
	if len(all) > offset + limit {
		out := make([dynamic]u8, allocator)
		w := prim.writer(&out)
		prim.write_u8(&w, VCURSOR_VERSION)
		prim.write_u8(&w, u8(e.sort))
		prim.write_u64le(&w, qhash)
		prim.write_u32le(&w, u32(offset + limit))
		res.cursor = out[:]
	}
	return res, .None
}

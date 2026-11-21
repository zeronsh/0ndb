package crdt

import "../prim"

GRAPH_META_FORMAT :: u8(1)

Page_Key :: struct {
	actor: u32,
	page:  u32,
}

Graph_Source :: struct {
	data: rawptr,
	load: proc(data: rawptr, key: Page_Key, out: ^[dynamic]u8) -> bool,
}

Rec_Page :: struct {
	first:   Lv,
	count:   u32,
	recs:    [dynamic]Rec,
	parents: [dynamic]Lv,
	loaded:  bool,
	dirty:   bool,
}

Seq_Page :: struct {
	first:  u64,
	count:  u32,
	runs:   [dynamic]Seq_Run,
	loaded: bool,
	dirty:  bool,
}

Actor_Seqs :: struct {
	pages: [dynamic]Seq_Page,
	known: u64,
	red:   [dynamic]Seq_Range,
}

@(private)
rec_page_index :: proc "contextless" (g: ^Graph, lv: Lv) -> int {
	p := g.pages[:]
	n := len(p)
	if n > 0 && p[n - 1].first <= lv {
		return n - 1
	}
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if p[mid].first <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

@(private)
rec_page_at :: proc(g: ^Graph, lv: Lv) -> (Rec, ^Rec_Page) {
	pi := rec_page_index(g, lv)
	if pi < 0 || lv >= g.next {
		return Rec{lv = lv, chain = lv}, nil
	}
	p := &g.pages[pi]
	if !p.loaded && !rec_load(g, pi) {
		return Rec{lv = lv, chain = lv}, nil
	}
	recs := p.recs[:]
	n := len(recs)
	if n == 0 {
		return Rec{lv = lv, chain = lv}, nil
	}
	if recs[n - 1].lv <= lv {
		return recs[n - 1], p
	}
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if recs[mid].lv <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return Rec{lv = lv, chain = lv}, nil
	}
	return recs[lo - 1], p
}

@(private)
rec_at :: #force_inline proc(g: ^Graph, lv: Lv) -> Rec {
	r, _ := rec_page_at(g, lv)
	return r
}

@(private)
rec_last :: proc(g: ^Graph) -> Rec {
	return rec_at(g, g.next - 1)
}

@(private)
rec_append :: proc(g: ^Graph, r: Rec, parents: []Lv) {
	np := len(g.pages)
	if np > 0 && !g.pages[np - 1].loaded {
		rec_load(g, np - 1)
	}
	if np == 0 || int(g.pages[np - 1].count) >= g.page_size {
		append(&g.pages, Rec_Page{first = r.lv, recs = make([dynamic]Rec, g.allocator), parents = make([dynamic]Lv, g.allocator), loaded = true})
		np += 1
	}
	p := &g.pages[np - 1]
	x := r
	x.pi = u32(len(p.parents))
	append(&p.parents, ..parents)
	append(&p.recs, x)
	p.count += 1
	p.dirty = true
}

@(private)
seq_page_runs :: proc(g: ^Graph, actor: u32, seq: u64) -> []Seq_Run {
	pages := g.seqs[actor].pages[:]
	n := len(pages)
	pi := n - 1
	if n > 0 && pages[n - 1].first > seq {
		lo, hi := 0, n
		for lo < hi {
			mid := (lo + hi) / 2
			if pages[mid].first <= seq {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		pi = lo - 1
	}
	if pi < 0 {
		return nil
	}
	p := &g.seqs[actor].pages[pi]
	if !p.loaded && !seq_load(g, actor, pi) {
		return nil
	}
	return p.runs[:]
}

@(private)
seq_append :: proc(g: ^Graph, actor: u32, seq: u64, lv: Lv, count: int) {
	s := &g.seqs[actor]
	s.known = seq + u64(count)
	n := len(s.pages)
	if n > 0 {
		p := &s.pages[n - 1]
		if !p.loaded {
			seq_load(g, actor, n - 1)
		}
		if k := len(p.runs); k > 0 {
			r := &p.runs[k - 1]
			if r.lv + r.len == lv && r.seq + u64(r.len) == seq {
				r.len += count
				p.dirty = true
				return
			}
		}
	}
	if n == 0 || int(s.pages[n - 1].count) >= g.page_size {
		append(&s.pages, Seq_Page{first = seq, runs = make([dynamic]Seq_Run, g.allocator), loaded = true})
		n += 1
	}
	p := &s.pages[n - 1]
	append(&p.runs, Seq_Run{seq = seq, lv = lv, len = count})
	p.count += 1
	p.dirty = true
}

@(private)
fetch :: proc(g: ^Graph, key: Page_Key) -> ([]u8, bool) {
	if g.source.load == nil {
		g.failed = true
		return nil, false
	}
	clear(&g.io)
	if !g.source.load(g.source.data, key, &g.io) {
		g.failed = true
		return nil, false
	}
	return g.io[:], true
}

@(private)
rec_load :: proc(g: ^Graph, pi: int) -> bool {
	data, ok := fetch(g, Page_Key{NO_ACTOR, u32(pi)})
	if !ok {
		return false
	}
	p := &g.pages[pi]
	end := g.next if pi + 1 >= len(g.pages) else g.pages[pi + 1].first
	recs := make([dynamic]Rec, 0, int(p.count), g.allocator)
	parents := make([dynamic]Lv, g.allocator)
	r := prim.reader(data)
	n := prim.read_uvarint(&r)
	good := r.err == .None && n == u64(p.count) && n <= u64(len(data))
	prev := p.first
	for i in 0 ..< int(n) {
		if !good {
			break
		}
		x: Rec
		d := prim.read_uvarint(&r)
		x.seq = prim.read_uvarint(&r)
		x.lamport = prim.read_uvarint(&r)
		back := prim.read_uvarint(&r)
		x.actor = u32(prim.read_uvarint(&r))
		np := prim.read_uvarint(&r)
		if r.err != .None || d > u64(end - prev) || (i == 0) != (d == 0) || np > u64(prim.reader_remaining(&r)) + 1 {
			good = false
			break
		}
		x.lv = prev + int(d)
		prev = x.lv
		if x.lv >= end || back > u64(x.lv) || int(x.actor) >= len(g.actors) {
			good = false
			break
		}
		x.chain = x.lv - int(back)
		x.pi = u32(len(parents))
		if np == 0 {
			x.np = LINEAR
		} else {
			x.np = u32(np - 1)
			for _ in 0 ..< int(np - 1) {
				pd := prim.read_uvarint(&r)
				if pd == 0 || pd > u64(x.lv) {
					good = false
					break
				}
				append(&parents, x.lv - int(pd))
			}
		}
		append(&recs, x)
	}
	if !good || !prim.reader_done(&r) {
		delete(recs)
		delete(parents)
		g.failed = true
		return false
	}
	p.recs = recs
	p.parents = parents
	p.loaded = true
	return true
}

@(private)
seq_load :: proc(g: ^Graph, actor: u32, pi: int) -> bool {
	data, ok := fetch(g, Page_Key{actor, u32(pi)})
	if !ok {
		return false
	}
	p := &g.seqs[actor].pages[pi]
	runs := make([dynamic]Seq_Run, 0, int(p.count), g.allocator)
	r := prim.reader(data)
	n := prim.read_uvarint(&r)
	good := r.err == .None && n == u64(p.count) && n <= u64(len(data))
	next := p.first
	for _ in 0 ..< int(n) {
		if !good {
			break
		}
		d := prim.read_uvarint(&r)
		lv := prim.read_uvarint(&r)
		l := prim.read_uvarint(&r)
		if r.err != .None || lv >= u64(g.next) || l == 0 || l > u64(g.next) - lv || d > MAX_COUNTER - next {
			good = false
			break
		}
		x := Seq_Run{seq = next + d, lv = int(lv), len = int(l)}
		next = x.seq + l
		append(&runs, x)
	}
	if !good || !prim.reader_done(&r) {
		delete(runs)
		g.failed = true
		return false
	}
	p.runs = runs
	p.loaded = true
	return true
}

graph_dirty :: proc(g: ^Graph, out: ^[dynamic]Page_Key) {
	clear(out)
	for &p, i in g.pages {
		if p.dirty {
			append(out, Page_Key{NO_ACTOR, u32(i)})
		}
	}
	for &s, a in g.seqs {
		for &p, i in s.pages {
			if p.dirty {
				append(out, Page_Key{u32(a), u32(i)})
			}
		}
	}
}

graph_page_encode :: proc(g: ^Graph, key: Page_Key, buf: ^[dynamic]u8) -> Error {
	w := prim.writer(buf)
	if key.actor == NO_ACTOR {
		if int(key.page) >= len(g.pages) || !g.pages[key.page].loaded {
			return .Unknown
		}
		p := &g.pages[key.page]
		prim.write_uvarint(&w, u64(len(p.recs)))
		prev := p.first
		for x in p.recs {
			prim.write_uvarint(&w, u64(x.lv - prev))
			prev = x.lv
			prim.write_uvarint(&w, x.seq)
			prim.write_uvarint(&w, x.lamport)
			prim.write_uvarint(&w, u64(x.lv - x.chain))
			prim.write_uvarint(&w, u64(x.actor))
			if x.np == LINEAR {
				prim.write_uvarint(&w, 0)
				continue
			}
			prim.write_uvarint(&w, u64(x.np) + 1)
			for q in p.parents[x.pi:][:x.np] {
				prim.write_uvarint(&w, u64(x.lv - q))
			}
		}
	} else {
		if int(key.actor) >= len(g.seqs) || int(key.page) >= len(g.seqs[key.actor].pages) || !g.seqs[key.actor].pages[key.page].loaded {
			return .Unknown
		}
		p := &g.seqs[key.actor].pages[key.page]
		prim.write_uvarint(&w, u64(len(p.runs)))
		next := p.first
		for x in p.runs {
			prim.write_uvarint(&w, x.seq - next)
			prim.write_uvarint(&w, u64(x.lv))
			prim.write_uvarint(&w, u64(x.len))
			next = x.seq + u64(x.len)
		}
	}
	return .Too_Large if w.err != .None else .None
}

graph_page_clean :: proc(g: ^Graph, key: Page_Key) {
	if key.actor == NO_ACTOR {
		if int(key.page) < len(g.pages) {
			g.pages[key.page].dirty = false
		}
	} else if int(key.actor) < len(g.seqs) && int(key.page) < len(g.seqs[key.actor].pages) {
		g.seqs[key.actor].pages[key.page].dirty = false
	}
}

graph_trim :: proc(g: ^Graph) {
	if g.source.load == nil {
		return
	}
	keep := len(g.pages) - g.window
	for i in 0 ..< max(keep, 0) {
		p := &g.pages[i]
		if p.loaded && !p.dirty {
			delete(p.recs)
			delete(p.parents)
			p.recs = nil
			p.parents = nil
			p.loaded = false
		}
	}
	for &s in g.seqs {
		for i in 0 ..< len(s.pages) - 1 {
			p := &s.pages[i]
			if p.loaded && !p.dirty {
				delete(p.runs)
				p.runs = nil
				p.loaded = false
			}
		}
	}
	shrink(&g.heap)
	shrink(&g.walk)
	shrink(&g.only_a)
	shrink(&g.only_b)
	shrink(&g.pieces)
	shrink(&g.tmp)
	clear(&g.io)
	shrink(&g.io)
}

graph_memory :: proc(g: ^Graph) -> int {
	n := size_of(Graph) + cap(g.pages) * size_of(Rec_Page) + cap(g.actors) * size_of(prim.Id) + cap(g.seqs) * size_of(Actor_Seqs)
	n += len(g.actor_index) * (size_of(prim.Id) + size_of(u32) + 8)
	for &s in g.seqs {
		n += cap(s.red) * size_of(Seq_Range)
	}
	n += cap(g.copies) * size_of(Copy_Rec)
	for &p in g.pages {
		n += cap(p.recs) * size_of(Rec) + cap(p.parents) * size_of(Lv)
	}
	for &s in g.seqs {
		n += cap(s.pages) * size_of(Seq_Page)
		for &p in s.pages {
			n += cap(p.runs) * size_of(Seq_Run)
		}
	}
	n += cap(g.heads) * size_of(Lv) + cap(g.heap) * size_of(Heap_Item) + cap(g.tmp) * size_of(Lv) + cap(g.walk) * size_of(Walk_Span)
	n += cap(g.only_a) * size_of(Lv_Span) + cap(g.only_b) * size_of(Lv_Span) + cap(g.pieces) * size_of(Piece) + cap(g.io)
	return n
}

graph_meta_encode :: proc(g: ^Graph, buf: ^[dynamic]u8) -> Error {
	w := prim.writer(buf)
	prim.write_u8(&w, GRAPH_META_FORMAT)
	prim.write_uvarint(&w, u64(g.next))
	prim.write_uvarint(&w, u64(g.page_size))
	prim.write_uvarint(&w, u64(len(g.heads)))
	for h in g.heads {
		prim.write_uvarint(&w, u64(h))
	}
	prim.write_uvarint(&w, u64(len(g.actors)))
	for id, a in g.actors {
		prim.write_id(&w, id)
		s := &g.seqs[a]
		prim.write_uvarint(&w, s.known)
		prim.write_uvarint(&w, u64(len(s.pages)))
		for &p in s.pages {
			prim.write_uvarint(&w, p.first)
			prim.write_uvarint(&w, u64(p.count))
		}
		prim.write_uvarint(&w, u64(len(s.red)))
		end: u64
		for x in s.red {
			prim.write_uvarint(&w, x.seq - end)
			prim.write_uvarint(&w, u64(x.len))
			end = x.seq + u64(x.len)
		}
	}
	prim.write_uvarint(&w, u64(len(g.pages)))
	for &p in g.pages {
		prim.write_uvarint(&w, u64(p.first))
		prim.write_uvarint(&w, u64(p.count))
	}
	prim.write_uvarint(&w, u64(len(g.copies)))
	for c in g.copies {
		prim.write_uvarint(&w, u64(c.src))
		prim.write_uvarint(&w, c.src_seq)
		prim.write_uvarint(&w, u64(c.own))
		prim.write_uvarint(&w, c.own_seq)
		prim.write_uvarint(&w, u64(c.len))
	}
	return .Too_Large if w.err != .None else .None
}

graph_open :: proc(g: ^Graph, meta: []u8, source: Graph_Source, allocator := context.allocator, window := DEFAULT_WINDOW) -> Error {
	r := prim.reader(meta)
	if prim.read_u8(&r) != GRAPH_META_FORMAT {
		return .Corrupt
	}
	next := prim.read_uvarint(&r)
	page := prim.read_uvarint(&r)
	if r.err != .None || next > MAX_LV || page < 2 || page > 1 << 16 {
		return .Corrupt
	}
	graph_init(g, allocator, source, int(page), window)
	g.next = int(next)
	fail :: proc(g: ^Graph) -> Error {
		graph_destroy(g)
		return .Corrupt
	}
	nh := prim.read_uvarint(&r)
	if r.err != .None || nh > u64(prim.reader_remaining(&r)) {
		return fail(g)
	}
	for _ in 0 ..< int(nh) {
		h := prim.read_uvarint(&r)
		if h >= next {
			return fail(g)
		}
		append(&g.heads, int(h))
	}
	na := prim.read_uvarint(&r)
	if r.err != .None || na > u64(prim.reader_remaining(&r) / 16) || na >= u64(NO_ACTOR) {
		return fail(g)
	}
	for _ in 0 ..< int(na) {
		ix := graph_intern(g, prim.read_id(&r))
		s := &g.seqs[ix]
		s.known = prim.read_uvarint(&r)
		np := prim.read_uvarint(&r)
		if r.err != .None || np > u64(prim.reader_remaining(&r) / 2) {
			return fail(g)
		}
		prev: u64
		for i in 0 ..< int(np) {
			first := prim.read_uvarint(&r)
			count := prim.read_uvarint(&r)
			if r.err != .None || (i > 0 && first <= prev) || count == 0 || count > page {
				return fail(g)
			}
			prev = first
			append(&s.pages, Seq_Page{first = first, count = u32(count)})
		}
		nr := prim.read_uvarint(&r)
		if r.err != .None || nr > u64(prim.reader_remaining(&r) / 2) {
			return fail(g)
		}
		end: u64
		for _ in 0 ..< int(nr) {
			d := prim.read_uvarint(&r)
			l := prim.read_uvarint(&r)
			if r.err != .None || l == 0 || l > MAX_RUN || d > MAX_COUNTER - end || end + d >= MAX_COUNTER - l || (len(s.red) > 0 && d == 0) {
				return fail(g)
			}
			append(&s.red, Seq_Range{end + d, int(l)})
			end += d + l
		}
	}
	if len(g.actors) != int(na) {
		return fail(g)
	}
	np := prim.read_uvarint(&r)
	if r.err != .None || np > u64(prim.reader_remaining(&r) / 2) {
		return fail(g)
	}
	prev := -1
	for _ in 0 ..< int(np) {
		first := prim.read_uvarint(&r)
		count := prim.read_uvarint(&r)
		if r.err != .None || int(first) <= prev || first >= next || count == 0 || count > page || (prev < 0 && first != 0) {
			return fail(g)
		}
		prev = int(first)
		append(&g.pages, Rec_Page{first = int(first), count = u32(count)})
	}
	nc := prim.read_uvarint(&r)
	if r.err != .None || nc > u64(prim.reader_remaining(&r) / 5) {
		return fail(g)
	}
	for _ in 0 ..< int(nc) {
		c: Copy_Rec
		c.src = u32(prim.read_uvarint(&r))
		c.src_seq = prim.read_uvarint(&r)
		c.own = u32(prim.read_uvarint(&r))
		c.own_seq = prim.read_uvarint(&r)
		l := prim.read_uvarint(&r)
		if r.err != .None || int(c.src) >= len(g.actors) || int(c.own) >= len(g.actors) || l == 0 || l > MAX_RUN {
			return fail(g)
		}
		c.len = int(l)
		append(&g.copies, c)
	}
	if !prim.reader_done(&r) {
		return fail(g)
	}
	return .None
}

Copy_Rec :: struct {
	src_seq: u64,
	own_seq: u64,
	len:     int,
	src:     u32,
	own:     u32,
}

@(private)
Red_Work :: struct {
	actor: u32,
	seq:   u64,
	len:   int,
}

graph_redact :: proc(g: ^Graph, actor: prim.Id, seq: u64, n: int, added: ^[dynamic]Op_Span = nil) -> bool {
	if n <= 0 || n > MAX_RUN || seq >= MAX_COUNTER - u64(n) {
		return false
	}
	return redact_closure(g, graph_intern(g, actor), seq, n, added)
}

@(private)
redact_closure :: proc(g: ^Graph, actor: u32, seq: u64, n: int, added: ^[dynamic]Op_Span) -> bool {
	work := make([dynamic]Red_Work, g.allocator)
	defer delete(work)
	gaps := make([dynamic]Seq_Range, g.allocator)
	defer delete(gaps)
	append(&work, Red_Work{actor, seq, n})
	changed := false
	for len(work) > 0 {
		w := pop(&work)
		rs := &g.seqs[w.actor].red
		clear(&gaps)
		cur := w.seq
		end := w.seq + u64(w.len)
		for i := red_first(rs[:], cur); i < len(rs) && rs[i].seq < end && cur < end; i += 1 {
			if rs[i].seq > cur {
				append(&gaps, Seq_Range{cur, int(rs[i].seq - cur)})
			}
			cur = max(cur, rs[i].seq + u64(rs[i].len))
		}
		if cur < end {
			append(&gaps, Seq_Range{cur, int(end - cur)})
		}
		if len(gaps) == 0 {
			continue
		}
		red_insert(rs, w.seq, w.len)
		changed = true
		for gp in gaps {
			if added != nil {
				append(added, Op_Span{Op_Id{g.actors[w.actor], gp.seq}, gp.len})
			}
			ge := gp.seq + u64(gp.len)
			for i := copy_first(g, w.actor); i < len(g.copies) && g.copies[i].src == w.actor; i += 1 {
				c := g.copies[i]
				a := max(c.src_seq, gp.seq)
				b := min(c.src_seq + u64(c.len), ge)
				if b > a {
					append(&work, Red_Work{c.own, c.own_seq + (a - c.src_seq), int(b - a)})
				}
			}
		}
	}
	return changed
}

@(private)
red_insert :: proc(rs: ^[dynamic]Seq_Range, seq: u64, n: int) {
	lo := seq
	hi := seq + u64(n)
	i := red_first(rs[:], lo)
	j := i
	for j < len(rs) && rs[j].seq <= hi {
		lo = min(lo, rs[j].seq)
		hi = max(hi, rs[j].seq + u64(rs[j].len))
		j += 1
	}
	remove_range(rs, i, j)
	inject_at(rs, i, Seq_Range{lo, int(hi - lo)})
}

@(private)
copy_first :: proc "contextless" (g: ^Graph, src: u32) -> int {
	c := g.copies[:]
	lo, hi := 0, len(c)
	for lo < hi {
		mid := (lo + hi) / 2
		if c[mid].src < src {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
copy_register :: proc(g: ^Graph, c: Copy_Rec) {
	c_ := g.copies[:]
	lo, hi := 0, len(c_)
	for lo < hi {
		mid := (lo + hi) / 2
		if c_[mid].src < c.src || c_[mid].src == c.src && c_[mid].src_seq <= c.src_seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	inject_at(&g.copies, lo, c)
	graph_redacted(g, c.src, c.src_seq, c.len, &g.red)
	if len(g.red) == 0 {
		return
	}
	parts := make([dynamic]Seq_Range, 0, len(g.red), g.allocator)
	defer delete(parts)
	append(&parts, ..g.red[:])
	for r in parts {
		redact_closure(g, c.own, c.own_seq + (r.seq - c.src_seq), r.len, nil)
	}
}

@(private)
red_first :: proc "contextless" (rs: []Seq_Range, seq: u64) -> int {
	lo, hi := 0, len(rs)
	for lo < hi {
		mid := (lo + hi) / 2
		if rs[mid].seq + u64(rs[mid].len) < seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

graph_redacted :: proc(g: ^Graph, actor: u32, seq: u64, n: int, out: ^[dynamic]Seq_Range) {
	clear(out)
	if int(actor) >= len(g.seqs) {
		return
	}
	rs := g.seqs[actor].red[:]
	end := seq + u64(n)
	for i := red_first(rs, seq); i < len(rs) && rs[i].seq < end; i += 1 {
		a := max(rs[i].seq, seq)
		b := min(rs[i].seq + u64(rs[i].len), end)
		if b > a {
			append(out, Seq_Range{a, int(b - a)})
		}
	}
}

graph_is_redacted :: proc(g: ^Graph, id: Op_Id) -> bool {
	ix, ok := graph_actor(g, id.actor)
	if !ok {
		return false
	}
	rs := g.seqs[ix].red[:]
	i := red_first(rs, id.seq)
	return i < len(rs) && rs[i].seq <= id.seq && id.seq < rs[i].seq + u64(rs[i].len)
}

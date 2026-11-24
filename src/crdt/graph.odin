package crdt

import "base:runtime"
import "core:slice"
import "../prim"

LINEAR :: max(u32)
NO_ACTOR :: max(u32)

Rec :: struct {
	lv:      Lv,
	seq:     u64,
	lamport: u64,
	chain:   Lv,
	actor:   u32,
	np:      u32,
	pi:      u32,
}

Seq_Run :: struct {
	seq: u64,
	lv:  Lv,
	len: int,
}

Walk_Span :: struct {
	lv:   Lv,
	len:  int,
	flag: u8,
}

FLAG_A :: u8(1)
FLAG_B :: u8(2)
FLAG_BOTH :: u8(3)

@(private)
Heap_Item :: struct {
	lv:   Lv,
	flag: u8,
}

Graph :: struct {
	allocator:   runtime.Allocator,
	source:      Graph_Source,
	page_size:   int,
	window:      int,
	pages:       [dynamic]Rec_Page,
	actors:      [dynamic]prim.Id,
	seqs:        [dynamic]Actor_Seqs,
	actor_index: map[prim.Id]u32,
	heads:       [dynamic]Lv,
	next:        Lv,
	failed:      bool,
	heap:        [dynamic]Heap_Item,
	tmp:         [dynamic]Lv,
	red:         [dynamic]Seq_Range,
	copies:      [dynamic]Copy_Rec,
	walk:        [dynamic]Walk_Span,
	only_a:      [dynamic]Lv_Span,
	only_b:      [dynamic]Lv_Span,
	pieces:      [dynamic]Piece,
	io:          [dynamic]u8,
	last_actor:  prim.Id,
	last_ix:     u32,
	has_last:    bool,
}

DEFAULT_PAGE :: 512
DEFAULT_WINDOW :: 8

graph_init :: proc(g: ^Graph, allocator := context.allocator, source := Graph_Source{}, page_size := DEFAULT_PAGE, window := DEFAULT_WINDOW) {
	g^ = {}
	g.allocator = allocator
	g.source = source
	g.page_size = clamp(page_size, 2, 1 << 16)
	g.window = max(window, 1)
	g.pages = make([dynamic]Rec_Page, allocator)
	g.actors = make([dynamic]prim.Id, allocator)
	g.seqs = make([dynamic]Actor_Seqs, allocator)
	g.actor_index = make(map[prim.Id]u32, allocator)
	g.heads = make([dynamic]Lv, allocator)
	g.heap = make([dynamic]Heap_Item, allocator)
	g.tmp = make([dynamic]Lv, allocator)
	g.red = make([dynamic]Seq_Range, allocator)
	g.copies = make([dynamic]Copy_Rec, allocator)
	g.walk = make([dynamic]Walk_Span, allocator)
	g.only_a = make([dynamic]Lv_Span, allocator)
	g.only_b = make([dynamic]Lv_Span, allocator)
	g.pieces = make([dynamic]Piece, allocator)
	g.io = make([dynamic]u8, allocator)
}

graph_destroy :: proc(g: ^Graph) {
	for &p in g.pages {
		delete(p.recs)
		delete(p.parents)
	}
	for &s in g.seqs {
		for &p in s.pages {
			delete(p.runs)
		}
		delete(s.pages)
		delete(s.red)
	}
	delete(g.pages)
	delete(g.actors)
	delete(g.seqs)
	delete(g.actor_index)
	delete(g.heads)
	delete(g.heap)
	delete(g.tmp)
	delete(g.red)
	delete(g.copies)
	delete(g.walk)
	delete(g.only_a)
	delete(g.only_b)
	delete(g.pieces)
	delete(g.io)
	g^ = {}
}

graph_actor :: proc(g: ^Graph, actor: prim.Id) -> (u32, bool) {
	if g.has_last && g.last_actor == actor {
		return g.last_ix, true
	}
	ix, ok := g.actor_index[actor]
	if ok {
		g.last_actor = actor
		g.last_ix = ix
		g.has_last = true
	}
	return ix, ok
}

graph_intern :: proc(g: ^Graph, actor: prim.Id) -> u32 {
	if ix, ok := graph_actor(g, actor); ok {
		return ix
	}
	ix := u32(len(g.actors))
	append(&g.actors, actor)
	append(&g.seqs, Actor_Seqs{pages = make([dynamic]Seq_Page, g.allocator), red = make([dynamic]Seq_Range, g.allocator)})
	g.actor_index[actor] = ix
	return ix
}

graph_known :: proc(g: ^Graph, actor: prim.Id) -> u64 {
	ix, ok := graph_actor(g, actor)
	if !ok {
		return 0
	}
	return g.seqs[ix].known
}

graph_lv :: proc(g: ^Graph, id: Op_Id) -> (Lv, bool) {
	ix, ok := graph_actor(g, id.actor)
	if !ok {
		return 0, false
	}
	return graph_lv_ix(g, ix, id.seq)
}

graph_lv_ix :: proc(g: ^Graph, actor: u32, seq: u64) -> (Lv, bool) {
	lv, _, ok := graph_seq_span(g, actor, seq)
	return lv, ok
}

graph_seq_span :: proc(g: ^Graph, actor: u32, seq: u64) -> (lv: Lv, avail: int, ok: bool) {
	if int(actor) >= len(g.seqs) || seq >= g.seqs[actor].known {
		return 0, 0, false
	}
	runs := seq_page_runs(g, actor, seq)
	lo, hi := 0, len(runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if runs[mid].seq + u64(runs[mid].len) <= seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(runs) && runs[lo].seq <= seq {
		d := int(seq - runs[lo].seq)
		return runs[lo].lv + d, runs[lo].len - d, true
	}
	return 0, 0, false
}

graph_op :: proc(g: ^Graph, lv: Lv) -> (actor: u32, seq: u64) {
	r := rec_at(g, lv)
	return r.actor, r.seq + u64(lv - r.lv)
}

graph_id :: proc(g: ^Graph, lv: Lv) -> Op_Id {
	actor, seq := graph_op(g, lv)
	if int(actor) >= len(g.actors) {
		return {}
	}
	return Op_Id{g.actors[actor], seq}
}

graph_lamport :: proc(g: ^Graph, lv: Lv) -> u64 {
	r := rec_at(g, lv)
	return r.lamport + u64(lv - r.lv)
}

graph_continues :: proc(g: ^Graph, lv: Lv) -> bool {
	if lv <= 0 || lv >= g.next {
		return false
	}
	return rec_at(g, lv).lv != lv
}

graph_parents :: proc(g: ^Graph, lv: Lv, buf: ^[1]Lv) -> []Lv {
	r, page := rec_page_at(g, lv)
	if r.lv != lv || r.np == LINEAR {
		buf[0] = lv - 1
		return buf[:]
	}
	if page == nil || int(r.pi) + int(r.np) > len(page.parents) {
		return nil
	}
	return page.parents[r.pi:][:r.np]
}

@(private)
chain_parents :: proc(g: ^Graph, v: Lv, buf: ^[1]Lv) -> (start: Lv, ps: []Lv) {
	r := rec_at(g, v)
	start = clamp(r.chain, 0, v)
	return start, graph_parents(g, start, buf)
}

graph_valid :: proc "contextless" (g: ^Graph, v: []Lv) -> bool {
	for x in v {
		if x < 0 || x >= g.next {
			return false
		}
	}
	return true
}

graph_records :: proc "contextless" (g: ^Graph) -> int {
	n := 0
	for &p in g.pages {
		n += int(p.count)
	}
	return n
}

graph_add :: proc(g: ^Graph, b: ^Batch, redacted: ^[dynamic]Op_Span = nil) -> (first: Lv, skip: int, err: Error) {
	n, copies := batch_check_ops(b) or_return
	first, skip = graph_add_header(g, b.actor, b.seq, b.lamport, b.parents, n) or_return
	if skip >= n || !copies {
		return
	}
	own := graph_intern(g, b.actor)
	o := 0
	for &op in b.ops {
		lo := max(skip, o)
		hi := o + op.len
		if (op.kind == .Insert_Copy || op.kind == .Insert_Carry) && hi > lo {
			k := lo - o
			copy_register(g, Copy_Rec{src_seq = op.src.seq + u64(k), own_seq = b.seq + u64(lo), len = hi - lo, src = graph_intern(g, op.src.actor), own = own}, redacted)
		}
		o = hi
	}
	return
}

@(private)
batch_check_ops :: proc(b: ^Batch) -> (n: int, copies: bool, err: Error) {
	for &op in b.ops {
		if op.len <= 0 || op.len > MAX_RUN || op.pos < -MAX_RUN || op.pos > MAX_POS {
			return 0, false, .Invalid
		}
		if (op.kind == .Insert || op.kind == .Insert_Carry) && len(op.content) != op.len || op.kind == .Insert_Ref && (op.ref.offset < 0 || op.ref.offset > MAX_POS || op.ref.oid.len != 20 && op.ref.oid.len != 32) {
			return 0, false, .Invalid
		}
		copies ||= op.kind == .Insert_Copy || op.kind == .Insert_Carry
		if (op.kind == .Insert_Copy || op.kind == .Insert_Carry) && op.src.seq >= MAX_COUNTER - u64(op.len) {
			return 0, false, .Invalid
		}
		n += op.len
		if n > MAX_RUN {
			return 0, false, .Invalid
		}
	}
	return n, copies, .None
}

graph_check :: proc(g: ^Graph, b: ^Batch, parents: ^[dynamic]Lv) -> (skip: int, err: Error) {
	n, _ := batch_check_ops(b) or_return
	skip, _, err = check_header(g, b.actor, b.seq, b.lamport, b.parents, n)
	clear(parents)
	append(parents, ..g.tmp[:])
	if g.failed {
		return 0, .Corrupt
	}
	return
}

@(private)
check_header :: proc(g: ^Graph, actor: prim.Id, seq: u64, lamport: u64, parents: []Op_Id, n: int) -> (skip: int, ts: u64, err: Error) {
	clear(&g.tmp)
	if n <= 0 || n > MAX_RUN || seq >= MAX_COUNTER - u64(n) || lamport == 0 || lamport >= MAX_COUNTER - u64(n) {
		return 0, 0, .Invalid
	}
	if g.next + n > MAX_LV {
		return 0, 0, .Too_Large
	}
	aix, have := graph_actor(g, actor)
	known := g.seqs[aix].known if have else 0
	if seq + u64(n) <= known {
		lv, _ := graph_lv_ix(g, aix, seq)
		if graph_lamport(g, lv) != lamport {
			return 0, 0, .Mismatch
		}
		return n, lamport, .None
	}
	if seq > known {
		return 0, 0, .Missing
	}
	ps := &g.tmp
	ts = lamport
	if seq < known {
		skip = int(known - seq)
		lv, _ := graph_lv_ix(g, aix, known - 1)
		if graph_lamport(g, lv) != lamport + u64(skip) - 1 {
			return 0, 0, .Mismatch
		}
		append(ps, lv)
		return skip, lamport + u64(skip), .None
	}
	max_ts: u64
	for p in parents {
		lv, ok := graph_lv(g, p)
		if !ok {
			return 0, 0, .Missing
		}
		append(ps, lv)
		max_ts = max(max_ts, graph_lamport(g, lv))
	}
	if ts <= max_ts {
		return 0, 0, .Invalid
	}
	if len(ps) > 1 {
		slice.sort(ps[:])
		w := 0
		for i in 0 ..< len(ps) {
			if i == 0 || ps[i] != ps[w - 1] {
				ps[w] = ps[i]
				w += 1
			}
		}
		resize(ps, w)
		graph_reduce(g, ps)
	}
	if seq > 0 {
		prev, _ := graph_lv_ix(g, aix, seq - 1)
		if !graph_contains(g, ps[:], prev) {
			return 0, 0, .Invalid
		}
	}
	return 0, ts, .None
}

graph_add_header :: proc(g: ^Graph, actor: prim.Id, seq: u64, lamport: u64, parents: []Op_Id, n: int) -> (first: Lv, skip: int, err: Error) {
	ts: u64
	skip, ts, err = check_header(g, actor, seq, lamport, parents, n)
	if err == .None && g.failed {
		err = .Corrupt
	}
	if err != .None {
		return 0, 0, err
	}
	if skip >= n {
		return g.next, n, .None
	}
	first = g.next
	count := n - skip
	ix := graph_intern(g, actor)
	nseq := seq + u64(skip)
	ps := g.tmp[:]
	linear := len(ps) == 1 && ps[0] == first - 1
	extend := false
	chain := first
	if np := len(g.pages); np > 0 {
		last := rec_last(g)
		l := u64(first - last.lv)
		extend = linear && last.actor == ix && last.seq + l == nseq && last.lamport + l == ts
		if linear {
			chain = last.chain
		}
	}
	if !extend {
		rec_append(g, Rec{lv = first, seq = nseq, lamport = ts, chain = chain, actor = ix, np = LINEAR if linear else u32(len(ps))}, ps if !linear else nil)
	}
	seq_append(g, ix, nseq, first, count)
	frontier_advance(&g.heads, ps, first + count - 1)
	g.next = first + count
	return first, skip, .None
}

frontier_advance :: proc(f: ^[dynamic]Lv, parents: []Lv, last: Lv) {
	if len(f) == 1 && len(parents) == 1 && f[0] == parents[0] {
		f[0] = last
		return
	}
	w := 0
	for i in 0 ..< len(f) {
		v := f[i]
		drop := false
		for p in parents {
			if p == v {
				drop = true
				break
			}
		}
		if !drop {
			f[w] = v
			w += 1
		}
	}
	resize(f, w)
	append(f, last)
	slice.sort(f[:])
}

frontier_eq :: proc "contextless" (a, b: []Lv) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

graph_version_ids :: proc(g: ^Graph, v: []Lv, allocator := context.allocator) -> []Op_Id {
	out := make([]Op_Id, len(v), allocator)
	for x, i in v {
		out[i] = graph_id(g, x)
	}
	slice.sort_by(out, op_id_less)
	return out
}

graph_version_lvs :: proc(g: ^Graph, ids: []Op_Id, out: ^[dynamic]Lv) -> Error {
	clear(out)
	for id in ids {
		lv, ok := graph_lv(g, id)
		if !ok {
			return .Unknown
		}
		append(out, lv)
	}
	slice.sort(out[:])
	w := 0
	for i in 0 ..< len(out) {
		if i == 0 || out[i] != out[w - 1] {
			out[w] = out[i]
			w += 1
		}
	}
	resize(out, w)
	graph_reduce(g, out)
	return .None
}

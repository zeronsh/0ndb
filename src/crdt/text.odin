package crdt

import "base:runtime"
import "core:slice"

Text :: struct {
	allocator: runtime.Allocator,
	rope:      Rope,
	spans:     Spans,
	version:   [dynamic]Lv,
}

@(private)
Merge :: struct {
	t:         ^Text,
	g:         ^Graph,
	log:       ^Text_Log,
	target:    []Lv,
	conflicts: ^[dynamic]Conflict,
	first:     int,
}

@(private)
Walked :: struct {
	piece: Piece,
	flag:  u8,
}

text_init :: proc(t: ^Text, allocator := context.allocator) {
	t^ = {}
	t.allocator = allocator
	tree_init(&t.rope, allocator)
	tree_init(&t.spans, allocator)
	t.version = make([dynamic]Lv, allocator)
}

text_destroy :: proc(t: ^Text) {
	tree_destroy(&t.rope)
	tree_destroy(&t.spans)
	delete(t.version)
	t^ = {}
}

text_clone :: proc(dst: ^Text, src: ^Text, allocator := context.allocator) {
	text_init(dst, allocator)
	tree_destroy(&dst.rope)
	tree_destroy(&dst.spans)
	tree_clone(&dst.rope, &src.rope, allocator)
	tree_clone(&dst.spans, &src.spans, allocator)
	append(&dst.version, ..src.version[:])
}

text_len :: proc "contextless" (t: ^Text) -> int {
	return t.rope.total[0]
}

text_read :: proc(t: ^Text, pos: int, dst: []u8) -> int {
	return rope_read(&t.rope, pos, dst)
}

text_bytes :: proc(t: ^Text, allocator := context.allocator) -> []u8 {
	out := make([]u8, text_len(t), allocator)
	rope_read(&t.rope, 0, out)
	return out
}

text_version :: proc(t: ^Text, g: ^Graph, allocator := context.allocator) -> []Op_Id {
	return graph_version_ids(g, t.version[:], allocator)
}

text_spans :: proc(t: ^Text, g: ^Graph, allocator := context.allocator) -> []Author_Span {
	out := make([dynamic]Author_Span, allocator)
	prev: Span
	have := false
	for leaf := tree_first_leaf(&t.spans); leaf != NIL; leaf = tree_next_leaf(&t.spans, leaf) {
		l := &t.spans.leaves[leaf]
		for i in 0 ..< int(l.n) {
			s := l.items[i]
			if have && span_merge(&prev, s) {
				continue
			}
			if have {
				append(&out, Author_Span{Op_Id{g.actors[prev.actor], prev.seq}, prev.len})
			}
			prev = s
			have = true
		}
	}
	if have {
		append(&out, Author_Span{Op_Id{g.actors[prev.actor], prev.seq}, prev.len})
	}
	return out[:]
}

text_author :: proc(t: ^Text, g: ^Graph, pos: int) -> (Op_Id, bool) {
	s, off, ok := run_get(&t.spans, pos)
	if !ok {
		return {}, false
	}
	return Op_Id{g.actors[s.actor], s.seq + u64(off)}, true
}

text_from :: proc(t: ^Text, g: ^Graph, data: []u8, spans: []Author_Span, version: []Op_Id, allocator := context.allocator) -> Error {
	total := 0
	for s in spans {
		if s.len <= 0 || s.len > MAX_RUN {
			return .Corrupt
		}
		total += s.len
	}
	if total != len(data) {
		return .Corrupt
	}
	text_init(t, allocator)
	if err := graph_version_lvs(g, version, &t.version); err != .None {
		text_destroy(t)
		return err
	}
	rope_append(&t.rope, data)
	pos := 0
	for s in spans {
		ix := graph_intern(g, s.id.actor)
		run_insert(&t.spans, pos, Span{s.len, s.id.seq, ix})
		pos += s.len
	}
	return .None
}

@(private)
conflict_shift :: proc(m: ^Merge, insert: bool, pos: int, n: int) {
	if m.conflicts == nil {
		return
	}
	for &c in m.conflicts[m.first:] {
		if insert {
			if pos < c.start {
				c.start += n
				c.end += n
			} else if pos <= c.end {
				c.end += n
			}
		} else {
			c.start = shift_point(c.start, pos, n)
			c.end = shift_point(c.end, pos, n)
		}
	}
}

@(private)
shift_point :: proc "contextless" (x, pos, n: int) -> int {
	if x >= pos + n {
		return x - n
	}
	if x > pos {
		return pos
	}
	return x
}

@(private)
doc_insert :: proc(m: ^Merge, pos: int, data: []u8, actor: u32, seq: u64) {
	at := clamp(pos, 0, text_len(m.t))
	rope_insert(&m.t.rope, at, data)
	run_insert(&m.t.spans, at, Span{len(data), seq, actor})
	conflict_shift(m, true, at, len(data))
}

@(private)
doc_delete :: proc(m: ^Merge, pos: int, n: int) {
	at := clamp(pos, 0, text_len(m.t))
	k := min(n, text_len(m.t) - at)
	if k <= 0 {
		return
	}
	rope_delete(&m.t.rope, at, k)
	run_delete(&m.t.spans, at, k)
	conflict_shift(m, false, at, k)
}

@(private)
heads_within :: proc(g: ^Graph, heads: []Lv, ps: []Lv) -> bool {
	for h in heads {
		if !graph_contains(g, ps, h) {
			return false
		}
	}
	return true
}

@(private)
effect :: proc "contextless" (kind: Op_Kind, pos: int, n: int, size: int) -> (at: int, s: int, cnt: int) {
	switch kind {
	case .Insert:
		return clamp(pos, 0, size), 0, n
	case .Delete:
		if pos < 0 || pos >= size {
			return 0, 0, 0
		}
		return pos, 0, min(n, size - pos)
	case .Delete_Back:
		lo := max(0, pos - size + 1)
		hi := min(n - 1, pos)
		if pos < 0 || hi < lo {
			return 0, 0, 0
		}
		return pos - hi, lo, hi - lo + 1
	case .Opaque:
	}
	return 0, 0, 0
}

@(private)
piece_pos :: proc "contextless" (e: Log_Entry, k: int) -> int {
	#partial switch e.kind {
	case .Insert:
		return e.pos + k
	case .Delete_Back:
		return e.pos - k
	}
	return e.pos
}

@(private)
apply_direct :: proc(m: ^Merge, p: Piece) {
	e := m.log.entries[p.entry]
	k := p.lv - e.lv
	at, _, cnt := effect(e.kind, piece_pos(e, k), p.len, text_len(m.t))
	if cnt == 0 {
		return
	}
	if e.kind == .Insert {
		actor, seq := graph_op(m.g, p.lv)
		doc_insert(m, at, m.log.bytes[e.at + k:][:p.len], actor, seq)
	} else {
		doc_delete(m, at, cnt)
	}
}

text_merge :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, v: []Lv, conflicts: ^[dynamic]Conflict = nil) -> Error {
	m := Merge {
		t         = t,
		g         = g,
		log       = log,
		target    = v,
		conflicts = conflicts,
	}
	if conflicts != nil {
		m.first = len(conflicts)
	}
	if !graph_valid(g, v) || !graph_valid(g, t.version[:]) {
		return .Unknown
	}
	graph_diff(g, t.version[:], v, &g.only_a, &g.only_b)
	clear(&g.pieces)
	log_pieces(log, g.only_b[:], &g.pieces) or_return
	i := 0
	for i < len(g.pieces) {
		p := g.pieces[i]
		buf: [1]Lv
		ps := graph_parents(g, p.lv, &buf)
		if heads_within(g, t.version[:], ps) {
			apply_direct(&m, p)
			clear(&t.version)
			append(&t.version, p.lv + p.len - 1)
			i += 1
			continue
		}
		i = session(&m, i) or_return
	}
	return .None
}

text_checkout :: proc(base: ^Text, g: ^Graph, log: ^Text_Log, v: []Lv, allocator := context.allocator) -> (out: Text, err: Error) {
	if !graph_valid(g, v) || !graph_valid(g, base.version[:]) {
		return {}, .Unknown
	}
	if !heads_within(g, base.version[:], v) {
		return {}, .Not_Ancestor
	}
	text_clone(&out, base, allocator)
	if err = text_merge(&out, g, log, v); err != .None {
		text_destroy(&out)
		return {}, err
	}
	return out, .None
}

@(private)
walk_piece :: proc(m: ^Merge, tr: ^Tracker, heads: ^[dynamic]Lv, p: Piece, side: int, emit: bool) {
	g := m.g
	buf: [1]Lv
	ps := graph_parents(g, p.lv, &buf)
	tr_move(tr, g, m.log, ps)
	e := m.log.entries[p.entry]
	k := p.lv - e.lv
	size := tr.items.total[CUR] - tr.tail if emit else tr.items.total[CUR]
	out := m if emit else nil
	at, s, cnt := effect(e.kind, piece_pos(e, k), p.len, size)
	if cnt > 0 {
		switch e.kind {
		case .Insert:
			ep := tr_insert(tr, g, at, PH + p.lv, p.len)
			if emit {
				actor, seq := graph_op(g, p.lv)
				doc_insert(m, ep, m.log.bytes[e.at + k:][:p.len], actor, seq)
			}
		case .Delete:
			tr_delete(tr, at, cnt, p.lv, false, 0, side, out)
		case .Delete_Back:
			tr_delete(tr, at, cnt, 0, true, p.lv + s + cnt - 1, side, out)
		case .Opaque:
		}
	}
	last := p.lv + p.len - 1
	clear(&tr.version)
	append(&tr.version, last)
	w := 0
	for h in heads {
		if !graph_contains(g, ps, h) {
			heads[w] = h
			w += 1
		}
	}
	resize(heads, w)
	append(heads, last)
	slice.sort(heads[:])
}

@(private)
build_tracker :: proc(m: ^Merge, tr: ^Tracker, heads: ^[dynamic]Lv, walked: ^[dynamic]Walked, other: []Lv) -> Error {
	t := m.t
	spans := make([dynamic]Walk_Span, t.allocator)
	defer delete(spans)
	common := make([dynamic]Lv, t.allocator)
	defer delete(common)
	graph_conflicting(m.g, t.version[:], other, &spans, &common)
	for s in spans {
		if s.lv < m.log.floor {
			return .Missing_Ops
		}
	}
	tracker_init(tr, t.allocator)
	append(&tr.version, ..common[:])
	for s in spans {
		if s.flag & FLAG_A == 0 {
			continue
		}
		clear(&tr.pieces)
		log_pieces(m.log, []Lv_Span{{s.lv, s.len}}, &tr.pieces) or_return
		for p in tr.pieces {
			append(walked, Walked{p, s.flag})
		}
	}
	for w in walked {
		walk_piece(m, tr, heads, w.piece, 0, false)
	}
	tr.tail = tr.items.total[END] - text_len(t)
	return .None
}

@(private)
session :: proc(m: ^Merge, start: int) -> (next: int, err: Error) {
	t := m.t
	tr: Tracker
	heads := make([dynamic]Lv, t.allocator)
	defer delete(heads)
	walked := make([dynamic]Walked, t.allocator)
	defer delete(walked)
	if err = build_tracker(m, &tr, &heads, &walked, m.target); err != .None {
		tracker_destroy(&tr)
		return start, err
	}
	defer tracker_destroy(&tr)
	i := start
	pieces := m.g.pieces[:]
	for i < len(pieces) {
		p := pieces[i]
		if i > start {
			buf: [1]Lv
			if heads_within(m.g, heads[:], graph_parents(m.g, p.lv, &buf)) {
				break
			}
		}
		walk_piece(m, &tr, &heads, p, 1, true)
		i += 1
	}
	if m.conflicts != nil {
		collect_conflicts(m, &tr, walked[:], pieces[start:i])
	}
	clear(&t.version)
	append(&t.version, ..heads[:])
	return i, .None
}

@(private)
Mark :: struct {
	start: int,
	end:   int,
	side:  int,
	lv:    Lv,
	len:   int,
}

@(private)
mark_ids :: proc(tr: ^Tracker, marks: ^[dynamic]Mark, id: int, n: int, side: int, p: Piece, point: bool) {
	cur := id
	rem := n
	for rem > 0 {
		leaf, i, off, ok := tr_locate(tr, cur)
		if !ok {
			return
		}
		it := tr.items.leaves[leaf].items[i]
		k := min(rem, it.len - off)
		ep := tr_end_pos(tr, leaf, i)
		if it.ever || point {
			append(marks, Mark{ep, ep, side, p.lv, p.len})
		} else {
			append(marks, Mark{ep + off, ep + off + k, side, p.lv, p.len})
		}
		cur += k
		rem -= k
	}
}

@(private)
mark_piece :: proc(m: ^Merge, tr: ^Tracker, marks: ^[dynamic]Mark, p: Piece, side: int) {
	e := m.log.entries[p.entry]
	if e.kind == .Insert {
		mark_ids(tr, marks, PH + p.lv, p.len, side, p, false)
		return
	}
	recs := tr.dels[side][:]
	for j := rec_first(recs, p.lv); j < len(recs) && recs[j].lv < p.lv + p.len; j += 1 {
		r := recs[j]
		x := max(p.lv, r.lv)
		y := min(p.lv + p.len, r.lv + r.len)
		if y <= x {
			continue
		}
		lo := r.target + (x - r.lv)
		if r.back {
			lo = r.target - (y - 1 - r.lv)
		}
		mark_ids(tr, marks, lo, y - x, side, p, true)
	}
}

@(private)
collect_conflicts :: proc(m: ^Merge, tr: ^Tracker, walked: []Walked, theirs: []Piece) {
	marks := make([dynamic]Mark, m.t.allocator)
	defer delete(marks)
	for w in walked {
		if w.flag == FLAG_A {
			mark_piece(m, tr, &marks, w.piece, 0)
		}
	}
	if len(marks) == 0 {
		return
	}
	for p in theirs {
		mark_piece(m, tr, &marks, p, 1)
	}
	slice.sort_by(marks[:], proc(a, b: Mark) -> bool {
		if a.start != b.start {
			return a.start < b.start
		}
		return a.side < b.side
	})
	alloc := m.conflicts.allocator
	j := 0
	for j < len(marks) {
		hi := marks[j].end
		sides := 0
		k := j
		for k < len(marks) && marks[k].start <= hi {
			hi = max(hi, marks[k].end)
			sides |= 1 << uint(marks[k].side)
			k += 1
		}
		if sides == 3 {
			ours := make([dynamic]Op_Span, alloc)
			mine := make([dynamic]Op_Span, alloc)
			for x in marks[j:k] {
				list := &ours if x.side == 0 else &mine
				id := graph_id(m.g, x.lv)
				dup := false
				for s in list {
					if s.id == id {
						dup = true
						break
					}
				}
				if !dup {
					append(list, Op_Span{id, x.len})
				}
			}
			append(m.conflicts, Conflict{marks[j].start, hi, ours[:], mine[:]})
		}
		j = k
	}
}

anchor_at :: proc(t: ^Text, g: ^Graph, pos: int, bias: Bias) -> (Anchor, bool) {
	p := pos if bias == .Before else pos - 1
	s, off, ok := run_get(&t.spans, p)
	if !ok {
		return {}, false
	}
	return Anchor{Op_Id{g.actors[s.actor], s.seq + u64(off)}, 0, bias}, true
}

anchor_resolve :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, a: Anchor) -> (int, Error) {
	ix, known := g.actor_index[a.id.actor]
	if !known || a.offset < 0 {
		return 0, .Unknown
	}
	seq := a.id.seq + u64(a.offset)
	pos := 0
	for leaf := tree_first_leaf(&t.spans); leaf != NIL; leaf = tree_next_leaf(&t.spans, leaf) {
		l := &t.spans.leaves[leaf]
		for i in 0 ..< int(l.n) {
			s := l.items[i]
			if s.actor == ix && seq >= s.seq && seq < s.seq + u64(s.len) {
				return pos + int(seq - s.seq) + (1 if a.bias == .After else 0), .None
			}
			pos += s.len
		}
	}
	lv, ok := graph_lv_ix(g, ix, seq)
	if !ok || !graph_contains(g, t.version[:], lv) {
		return 0, .Unknown
	}
	i := log_find(log, lv)
	if i >= len(log.entries) || log.entries[i].lv > lv || log.entries[i].kind != .Insert {
		return 0, .Unknown
	}
	m := Merge {
		t   = t,
		g   = g,
		log = log,
	}
	buf: [1]Lv
	ps := graph_parents(g, lv, &buf)
	tr: Tracker
	heads := make([dynamic]Lv, t.allocator)
	defer delete(heads)
	walked := make([dynamic]Walked, t.allocator)
	defer delete(walked)
	if err := build_tracker(&m, &tr, &heads, &walked, ps); err != .None {
		tracker_destroy(&tr)
		return 0, err
	}
	defer tracker_destroy(&tr)
	leaf, k, off, found := tr_locate(&tr, PH + lv)
	if !found {
		return 0, .Unknown
	}
	p := tr_end_pos(&tr, leaf, k)
	if !tr.items.leaves[leaf].items[k].ever {
		p += off
	}
	return p, .None
}

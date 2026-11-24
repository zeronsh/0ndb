package crdt

import "base:runtime"
import "core:slice"
import "../prim"

Text :: struct {
	allocator: runtime.Allocator,
	rope:      Rope,
	spans:     Spans,
	version:   [dynamic]Lv,
	ids:       Index,
	ids_on:    bool,
	authors:   [dynamic]Override,
}

@(private)
Override :: struct {
	seq:    u64,
	aseq:   u64,
	len:    int,
	actor:  u32,
	aactor: u32,
}

@(private)
Merge :: struct {
	t:         ^Text,
	g:         ^Graph,
	log:       ^Text_Log,
	target:    []Lv,
	conflicts: ^[dynamic]Conflict,
	first:     int,
	err:       Error,
	sink:      Text_Sink,
}

Text_Sink :: struct {
	data:   rawptr,
	insert: proc(data: rawptr, pos: int, bytes: []u8, author: Op_Id),
	delete: proc(data: rawptr, pos: int, bytes: []u8),
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
	t.authors = make([dynamic]Override, allocator)
}

text_destroy :: proc(t: ^Text) {
	tree_destroy(&t.rope)
	tree_destroy(&t.spans)
	if t.ids_on {
		tree_destroy(&t.ids)
	}
	delete(t.version)
	delete(t.authors)
	t^ = {}
}

text_clone :: proc(dst: ^Text, src: ^Text, allocator := context.allocator) {
	text_init(dst, allocator)
	tree_destroy(&dst.rope)
	tree_destroy(&dst.spans)
	tree_clone(&dst.rope, &src.rope, allocator)
	tree_clone(&dst.spans, &src.spans, allocator)
	append(&dst.version, ..src.version[:])
	append(&dst.authors, ..src.authors[:])
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
				author_emit(t, g, prev, &out)
			}
			prev = s
			have = true
		}
	}
	if have {
		author_emit(t, g, prev, &out)
	}
	return out[:]
}

@(private)
override_first :: proc "contextless" (t: ^Text, actor: u32, seq: u64) -> int {
	o := t.authors[:]
	lo, hi := 0, len(o)
	for lo < hi {
		mid := (lo + hi) / 2
		if o[mid].actor < actor || o[mid].actor == actor && o[mid].seq + u64(o[mid].len) <= seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
override_add :: proc(t: ^Text, actor: u32, seq: u64, aactor: u32, aseq: u64, n: int) {
	if n <= 0 || (actor == aactor && seq == aseq) {
		return
	}
	i := override_first(t, actor, seq)
	if i < len(t.authors) && t.authors[i].actor == actor && t.authors[i].seq <= seq {
		return
	}
	if i > 0 {
		p := &t.authors[i - 1]
		if p.actor == actor && p.aactor == aactor && p.seq + u64(p.len) == seq && p.aseq + u64(p.len) == aseq {
			p.len += n
			return
		}
	}
	inject_at(&t.authors, i, Override{seq = seq, aseq = aseq, len = n, actor = actor, aactor = aactor})
}

@(private)
author_push :: proc(out: ^[dynamic]Author_Span, a: Author_Span) {
	if n := len(out); n > 0 {
		l := &out[n - 1]
		if l.redacted == a.redacted && l.op.actor == a.op.actor && l.id.actor == a.id.actor && l.op.seq + u64(l.len) == a.op.seq && l.id.seq + u64(l.len) == a.id.seq {
			l.len += a.len
			return
		}
	}
	append(out, a)
}

@(private)
author_emit :: proc(t: ^Text, g: ^Graph, s: Span, out: ^[dynamic]Author_Span) {
	own := g.actors[s.actor]
	cur := s.seq
	end := s.seq + u64(s.len)
	i := override_first(t, s.actor, cur) if len(t.authors) > 0 else 0
	for cur < end {
		if i < len(t.authors) && t.authors[i].actor == s.actor && t.authors[i].seq < end {
			o := t.authors[i]
			if o.seq > cur {
				author_push(out, Author_Span{id = Op_Id{own, cur}, op = Op_Id{own, cur}, len = int(o.seq - cur), redacted = s.red})
				cur = o.seq
			}
			b := min(end, o.seq + u64(o.len))
			author_push(out, Author_Span{id = Op_Id{g.actors[o.aactor], o.aseq + (cur - o.seq)}, op = Op_Id{own, cur}, len = int(b - cur), redacted = s.red})
			cur = b
			i += 1
		} else {
			author_push(out, Author_Span{id = Op_Id{own, cur}, op = Op_Id{own, cur}, len = int(end - cur), redacted = s.red})
			cur = end
		}
	}
}

text_author :: proc(t: ^Text, g: ^Graph, pos: int) -> (author: Op_Id, op: Op_Id, ok: bool) {
	s, off, found := run_get(&t.spans, pos)
	if !found {
		return {}, {}, false
	}
	seq := s.seq + u64(off)
	op = Op_Id{g.actors[s.actor], seq}
	author = op
	if i := override_first(t, s.actor, seq); i < len(t.authors) && t.authors[i].actor == s.actor && t.authors[i].seq <= seq {
		o := t.authors[i]
		author = Op_Id{g.actors[o.aactor], o.aseq + (seq - o.seq)}
	}
	return author, op, true
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
	parts := make([dynamic]Red_Part, t.allocator)
	defer delete(parts)
	for s in spans {
		sp := Span {
			len   = s.len,
			seq   = s.op.seq,
			actor = graph_intern(g, s.op.actor),
			red   = s.redacted,
		}
		run_insert(&t.spans, pos, sp)
		if s.id != s.op {
			override_add(t, sp.actor, sp.seq, graph_intern(g, s.id.actor), s.id.seq, s.len)
		}
		if s.redacted {
			append(&parts, Red_Part{pos, sp})
		} else {
			graph_redacted(g, sp.actor, sp.seq, sp.len, &g.red)
			for r in g.red {
				_, tail := span_split(sp, int(r.seq - sp.seq))
				piece, _ := span_split(tail, r.len)
				append(&parts, Red_Part{pos + int(r.seq - sp.seq), piece})
			}
		}
		pos += s.len
	}
	redact_parts(t, parts[:])
	return .None
}

@(private)
Red_Part :: struct {
	pos:  int,
	span: Span,
}

@(private)
redact_parts :: proc(t: ^Text, parts: []Red_Part) {
	ids := &t.ids if t.ids_on else nil
	for p in parts {
		x := p.span
		x.red = true
		rope_fill(&t.rope, p.pos, x.len, 0)
		run_delete(&t.spans, p.pos, x.len, ids)
		run_insert(&t.spans, p.pos, x, ids)
	}
}

text_redact :: proc(t: ^Text, g: ^Graph, actor: prim.Id, seq: u64, n: int) {
	ix, ok := graph_actor(g, actor)
	if !ok || n <= 0 || seq >= MAX_COUNTER - u64(n) {
		return
	}
	parts := make([dynamic]Red_Part, t.allocator)
	defer delete(parts)
	end := seq + u64(n)
	collect :: proc(parts: ^[dynamic]Red_Part, l: ^Run_Leaf(Span), base: int, actor: u32, seq, end: u64) {
		pos := base
		for i in 0 ..< int(l.n) {
			s := l.items[i]
			if s.actor == actor && !s.red {
				a := max(s.seq, seq)
				b := min(s.seq + u64(s.len), end)
				if b > a {
					_, tail := span_split(s, int(a - s.seq))
					piece, _ := span_split(tail, int(b - a))
					append(parts, Red_Part{pos + int(a - s.seq), piece})
				}
			}
			pos += s.len
		}
	}
	key, keyed := span_key(ix, seq, n)
	if !keyed {
		base := 0
		for leaf := tree_first_leaf(&t.spans); leaf != NIL; leaf = tree_next_leaf(&t.spans, leaf) {
			collect(&parts, &t.spans.leaves[leaf], base, ix, seq, end)
			base += tree_leaf_size(&t.spans, leaf)[0]
		}
	} else {
		text_index_ids(t)
		seen := make([dynamic]u32, t.allocator)
		defer delete(seen)
		cur := key
		for cur < key + i64(n) {
			e, off, found := run_get(&t.ids, cur)
			if !found {
				break
			}
			if e.leaf != NIL && int(e.leaf) < len(t.spans.leaves) && !slice.contains(seen[:], e.leaf) {
				append(&seen, e.leaf)
				collect(&parts, &t.spans.leaves[e.leaf], tree_leaf_pos(&t.spans, e.leaf)[0], ix, seq, end)
			}
			cur += e.len - off
		}
	}
	redact_parts(t, parts[:])
}

text_is_redacted :: proc(t: ^Text, pos: int) -> bool {
	s, _, ok := run_get(&t.spans, pos)
	return ok && s.red
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
doc_insert :: proc(m: ^Merge, pos: int, data: []u8, actor: u32, seq: u64, red := false, aactor := NO_ACTOR, aseq: u64 = 0) {
	at := clamp(pos, 0, text_len(m.t))
	rope_insert(&m.t.rope, at, data)
	run_insert(&m.t.spans, at, Span{len(data), seq, actor, red}, &m.t.ids if m.t.ids_on else nil)
	if aactor != NO_ACTOR {
		override_add(m.t, actor, seq, aactor, aseq, len(data))
	}
	conflict_shift(m, true, at, len(data))
	if m.sink.insert != nil {
		author := Op_Id{m.g.actors[actor], seq}
		if aactor != NO_ACTOR {
			author = Op_Id{m.g.actors[aactor], aseq}
		}
		m.sink.insert(m.sink.data, at, data, author)
	}
}

@(private)
doc_insert_piece :: proc(m: ^Merge, at: int, e: ^Log_Entry, k: int, n: int, lv: Lv) {
	actor, seq := graph_op(m.g, lv)
	if e.kind == .Insert && !e.red {
		doc_insert(m, at, m.log.bytes[e.at + k:][:n], actor, seq)
	} else if e.kind == .Insert_Copy {
		doc_insert_copy(m, at, e, k, n, actor, seq)
	} else {
		doc_insert_chunks(m, at, e, k, n, actor, seq)
	}
}

@(private)
doc_insert_copy :: proc(m: ^Merge, at: int, e: ^Log_Entry, k: int, n: int, actor: u32, seq: u64) {
	off := 0
	for a in m.log.authors[e.au:][:e.nau] {
		lo := max(off, k)
		hi := min(off + a.len, k + n)
		if hi > lo {
			d := lo - k
			doc_insert(m, at + d, m.log.bytes[e.at + lo:][:hi - lo], actor, seq + u64(d), e.red, a.actor, a.seq + u64(lo - off))
		}
		off += a.len
	}
}

@(private)
doc_insert_chunks :: proc(m: ^Merge, at: int, e: ^Log_Entry, k: int, n: int, actor: u32, seq: u64) {
	buf: [4096]u8
	done := 0
	for done < n {
		c := min(len(buf), n - done)
		chunk := buf[:c]
		if e.red {
			doc_insert(m, at + done, chunk, actor, seq + u64(done), true)
			done += c
			continue
		}
		ref := m.log.refs[e.at]
		src := m.log.content
		if src.read == nil || !src.read(src.data, ref.oid, ref.offset + k + done, chunk) {
			for &b in chunk {
				b = 0
			}
			m.err = .Missing_Content
		}
		doc_insert(m, at + done, chunk, actor, seq + u64(done))
		done += c
	}
}

@(private)
doc_delete :: proc(m: ^Merge, pos: int, n: int) {
	at := clamp(pos, 0, text_len(m.t))
	k := min(n, text_len(m.t) - at)
	if k <= 0 {
		return
	}
	if m.sink.delete != nil {
		gone := make([]u8, k, context.temp_allocator)
		rope_read(&m.t.rope, at, gone)
		m.sink.delete(m.sink.data, at, gone)
	}
	rope_delete(&m.t.rope, at, k)
	run_delete(&m.t.spans, at, k, &m.t.ids if m.t.ids_on else nil)
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
effect :: proc "contextless" (kind: Op_Kind, pos: i64, n: i64, size: i64) -> (at: i64, s: i64, cnt: i64) {
	switch kind {
	case .Insert, .Insert_Ref, .Insert_Copy, .Insert_Carry:
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
	case .Insert, .Insert_Ref, .Insert_Copy:
		return e.pos + k
	case .Delete_Back:
		return e.pos - k
	}
	return e.pos
}

@(private)
apply_direct :: proc(m: ^Merge, p: Piece) {
	e := &m.log.entries[p.entry]
	k := p.lv - e.lv
	at, _, cnt := effect(e.kind, i64(piece_pos(e^, k)), i64(p.len), i64(text_len(m.t)))
	if cnt == 0 {
		return
	}
	if is_insert(e.kind) {
		doc_insert_piece(m, int(at), e, k, p.len, p.lv)
	} else {
		doc_delete(m, int(at), int(cnt))
	}
}

text_merge :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, v: []Lv, conflicts: ^[dynamic]Conflict = nil, sink := Text_Sink{}) -> Error {
	m := Merge {
		t         = t,
		g         = g,
		log       = log,
		target    = v,
		conflicts = conflicts,
		sink      = sink,
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
	return m.err
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
	e := &m.log.entries[p.entry]
	k := p.lv - e.lv
	size := tr.items.total[CUR] - tr.tail if emit else tr.items.total[CUR]
	out := m if emit else nil
	at, s, cnt := effect(e.kind, i64(piece_pos(e^, k)), i64(p.len), size)
	if cnt > 0 {
		switch e.kind {
		case .Insert, .Insert_Ref, .Insert_Copy:
			ep := tr_insert(tr, g, at, PH + i64(p.lv), i64(p.len))
			if emit {
				doc_insert_piece(m, narrow(ep), e, k, p.len, p.lv)
			}
		case .Delete:
			tr_delete(tr, at, cnt, p.lv, false, 0, i64(side), out)
		case .Delete_Back:
			tr_delete(tr, at, cnt, 0, true, p.lv + Lv(s + cnt - 1), i64(side), out)
		case .Opaque, .Insert_Carry:
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
	tr.tail = tr.items.total[END] - i64(text_len(t))
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
mark_ids :: proc(tr: ^Tracker, marks: ^[dynamic]Mark, id: i64, n: i64, side: int, p: Piece, point: bool) {
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
			append(marks, Mark{narrow(ep), narrow(ep), side, p.lv, p.len})
		} else {
			append(marks, Mark{narrow(ep + off), narrow(ep + off + k), side, p.lv, p.len})
		}
		cur += k
		rem -= k
	}
}

@(private)
mark_piece :: proc(m: ^Merge, tr: ^Tracker, marks: ^[dynamic]Mark, p: Piece, side: int) {
	e := m.log.entries[p.entry]
	if is_insert(e.kind) {
		mark_ids(tr, marks, PH + i64(p.lv), i64(p.len), side, p, false)
		return
	}
	recs := tr.dels[side][:]
	for j := rec_first(recs, p.lv); j < len(recs) && recs[j].lv < p.lv + p.len; j += 1 {
		r := recs[j]
		x := max(p.lv, r.lv)
		y := min(p.lv + p.len, Lv(i64(r.lv) + r.len))
		if y <= x {
			continue
		}
		lo := r.target + i64(x - r.lv)
		if r.back {
			lo = r.target - i64(y - 1 - r.lv)
		}
		mark_ids(tr, marks, lo, i64(y - x), side, p, true)
	}
}

@(private)
collect_conflicts :: proc(m: ^Merge, tr: ^Tracker, walked: []Walked, theirs: []Piece) {
	marks := make([dynamic]Mark, m.t.allocator)
	defer delete(marks)
	for w in walked {
		if w.flag & FLAG_A != 0 {
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

text_index_ids :: proc(t: ^Text) {
	if t.ids_on {
		return
	}
	tree_init(&t.ids, t.allocator)
	run_insert(&t.ids, 0, Ix{ID_SPACE_KEYS, NIL})
	t.ids_on = true
	for leaf := tree_first_leaf(&t.spans); leaf != NIL; leaf = tree_next_leaf(&t.spans, leaf) {
		l := &t.spans.leaves[leaf]
		for i in 0 ..< int(l.n) {
			span_index(&t.ids, l.items[i], leaf)
		}
	}
}

@(private)
span_position :: proc(t: ^Text, actor: u32, seq: u64) -> (int, bool) {
	key, keyed := span_key(actor, seq, 1)
	if !keyed {
		pos := 0
		for leaf := tree_first_leaf(&t.spans); leaf != NIL; leaf = tree_next_leaf(&t.spans, leaf) {
			l := &t.spans.leaves[leaf]
			for i in 0 ..< int(l.n) {
				s := l.items[i]
				if s.actor == actor && seq >= s.seq && seq < s.seq + u64(s.len) {
					return pos + int(seq - s.seq), true
				}
				pos += s.len
			}
		}
		return 0, false
	}
	text_index_ids(t)
	e, _, ok := run_get(&t.ids, key)
	if !ok || e.leaf == NIL || int(e.leaf) >= len(t.spans.leaves) {
		return 0, false
	}
	l := &t.spans.leaves[e.leaf]
	pos := 0
	for i in 0 ..< int(l.n) {
		s := l.items[i]
		if s.actor == actor && seq >= s.seq && seq < s.seq + u64(s.len) {
			return tree_leaf_pos(&t.spans, e.leaf)[0] + pos + int(seq - s.seq), true
		}
		pos += s.len
	}
	return 0, false
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
	if p, found := span_position(t, ix, seq); found {
		return p + (1 if a.bias == .After else 0), .None
	}
	lv, ok := graph_lv_ix(g, ix, seq)
	if !ok || !graph_contains(g, t.version[:], lv) {
		return 0, .Unknown
	}
	i := log_find(log, lv)
	if i >= len(log.entries) || log.entries[i].lv > lv {
		return 0, .Missing_Ops
	}
	if !is_insert(log.entries[i].kind) {
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
	leaf, k, off, found := tr_locate(&tr, PH + i64(lv))
	if !found {
		return 0, .Unknown
	}
	p := tr_end_pos(&tr, leaf, k)
	if !tr.items.leaves[leaf].items[k].ever {
		p += off
	}
	return narrow(p), .None
}

text_length_at :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, v: []Lv) -> (int, Error) {
	if !graph_valid(g, v) || !graph_valid(g, t.version[:]) {
		return 0, .Unknown
	}
	if heads_within(g, t.version[:], v) {
		return text_len(t), .None
	}
	m := Merge {
		t   = t,
		g   = g,
		log = log,
	}
	tr: Tracker
	heads := make([dynamic]Lv, t.allocator)
	defer delete(heads)
	walked := make([dynamic]Walked, t.allocator)
	defer delete(walked)
	if err := build_tracker(&m, &tr, &heads, &walked, v); err != .None {
		tracker_destroy(&tr)
		return 0, err
	}
	defer tracker_destroy(&tr)
	tr_move(&tr, g, log, v)
	return narrow(tr.items.total[CUR] - tr.tail), .None
}

@(private)
run_valid :: proc "contextless" (r: Op_Run, size: int) -> int {
	switch r.kind {
	case .Insert, .Insert_Ref, .Insert_Copy, .Insert_Carry:
		return r.len if r.pos >= 0 && r.pos <= size else 0
	case .Delete:
		return clamp(size - r.pos, 0, r.len) if r.pos >= 0 else 0
	case .Delete_Back:
		return min(r.len, r.pos + 1) if r.pos >= 0 && r.pos < size else 0
	case .Opaque:
		return r.len
	}
	return 0
}

text_check :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, b: ^Batch, target: Op_Id, skip: int, parents: []Lv) -> (valid: int, err: Error) {
	size: int
	have := false
	rest := skip
	for &op in b.ops {
		if rest >= op.len {
			rest -= op.len
			continue
		}
		r := run_tail(op, rest)
		rest = 0
		if op.target != target || op.kind == .Opaque {
			valid += r.len
			continue
		}
		if !have {
			size = text_length_at(t, g, log, parents) or_return
			have = true
		}
		ok := run_valid(r, size)
		if r.kind == .Insert_Copy && ok > 0 {
			ok = min(ok, copy_valid(t, g, log, r, b.actor, b.seq + u64(valid), parents))
		}
		valid += ok
		if ok < r.len {
			return valid, .None
		}
		size += r.len if is_insert(r.kind) else -r.len
	}
	return valid, .None
}

@(private)
copy_valid :: proc(t: ^Text, g: ^Graph, log: ^Text_Log, r: Op_Run, actor: prim.Id, seq: u64, parents: []Lv) -> int {
	n := r.len
	ext := n
	if r.src.actor == actor {
		if r.src.seq >= seq {
			return 0
		}
		ext = min(n, int(seq - r.src.seq))
	} else {
		ix, known := graph_actor(g, r.src.actor)
		if !known {
			return 0
		}
		inside :: proc(g: ^Graph, ix: u32, s: u64, parents: []Lv) -> bool {
			lv, found := graph_lv_ix(g, ix, s)
			return found && graph_contains(g, parents, lv)
		}
		if !inside(g, ix, r.src.seq + u64(n) - 1, parents) {
			lo, hi := 0, n - 1
			for lo < hi {
				mid := (lo + hi + 1) / 2
				if inside(g, ix, r.src.seq + u64(mid) - 1, parents) {
					lo = mid
				} else {
					hi = mid - 1
				}
			}
			n = lo
			ext = lo
		}
	}
	if ext == 0 || log.copies.read == nil {
		return 0
	}
	buf := make([]u8, ext, t.allocator)
	defer delete(buf, t.allocator)
	authors := make([dynamic]Author_Span, t.allocator)
	defer delete(authors)
	got := clamp(log.copies.read(log.copies.data, Op_Id{r.src.actor, r.src.seq}, buf, &authors), 0, ext)
	return got if got < ext else n
}

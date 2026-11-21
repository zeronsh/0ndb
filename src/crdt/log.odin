package crdt

import "../prim"

Log_Entry :: struct {
	lv:   Lv,
	len:  int,
	pos:  int,
	at:   int,
	au:   u32,
	nau:  u32,
	kind: Op_Kind,
	red:  bool,
}

Copy_Author :: struct {
	len:   int,
	seq:   u64,
	actor: u32,
}

Text_Log :: struct {
	entries: [dynamic]Log_Entry,
	bytes:   [dynamic]u8,
	refs:    [dynamic]Content_Ref,
	authors: [dynamic]Copy_Author,
	floor:   Lv,
	content: Content_Source,
	copies:  Copy_Source,
	scratch: [dynamic]Author_Span,
}

Piece :: struct {
	lv:    Lv,
	len:   int,
	entry: int,
}

log_init :: proc(log: ^Text_Log, allocator := context.allocator, content := Content_Source{}, copies := Copy_Source{}) {
	log^ = {}
	log.entries = make([dynamic]Log_Entry, allocator)
	log.bytes = make([dynamic]u8, allocator)
	log.refs = make([dynamic]Content_Ref, allocator)
	log.authors = make([dynamic]Copy_Author, allocator)
	log.scratch = make([dynamic]Author_Span, allocator)
	log.content = content
	log.copies = copies
}

log_clone :: proc(dst: ^Text_Log, src: ^Text_Log, allocator := context.allocator) {
	log_init(dst, allocator, src.content, src.copies)
	append(&dst.entries, ..src.entries[:])
	append(&dst.bytes, ..src.bytes[:])
	append(&dst.refs, ..src.refs[:])
	append(&dst.authors, ..src.authors[:])
	dst.floor = src.floor
}

log_destroy :: proc(log: ^Text_Log) {
	delete(log.entries)
	delete(log.bytes)
	delete(log.refs)
	delete(log.authors)
	delete(log.scratch)
	log^ = {}
}

@(private)
log_store :: proc(log: ^Text_Log, g: ^Graph, lv: Lv, run: Op_Run) -> (e: Log_Entry, err: Error) {
	e = Log_Entry {
		lv   = lv,
		len  = run.len,
		pos  = run.pos,
		at   = -1,
		kind = run.kind,
	}
	#partial switch run.kind {
	case .Insert:
		e.at = len(log.bytes)
		append(&log.bytes, ..run.content[:run.len])
	case .Insert_Ref:
		append(&log.refs, run.ref)
		e.at = len(log.refs) - 1
	case .Insert_Copy:
		e.at = len(log.bytes)
		resize(&log.bytes, e.at + run.len)
		au := len(log.authors)
		err = copy_resolve(log, g, lv, run, log.bytes[e.at:][:run.len])
		e.au = u32(au)
		e.nau = u32(len(log.authors) - au)
	}
	return
}

@(private)
copy_resolve :: proc(log: ^Text_Log, g: ^Graph, lv: Lv, run: Op_Run, dst: []u8) -> Error {
	actor, seq := graph_op(g, lv)
	n := run.len
	start := len(log.authors)
	ext := n
	if int(actor) < len(g.actors) && g.actors[actor] == run.src.actor && run.src.seq < seq {
		ext = min(n, int(seq - run.src.seq))
	}
	got := 0
	clear(&log.scratch)
	if log.copies.read != nil {
		got = clamp(log.copies.read(log.copies.data, run.src, dst[:ext], &log.scratch), 0, ext)
	}
	err := Error.None
	if got < ext {
		for &b in dst[got:ext] {
			b = 0
		}
		err = .Missing_Content
	}
	covered := 0
	for x in log.scratch {
		k := min(x.len, ext - covered)
		if k <= 0 {
			break
		}
		copy_author_push(log, start, Copy_Author{k, x.id.seq, graph_intern(g, x.id.actor)})
		covered += k
	}
	if covered < ext {
		copy_author_push(log, start, Copy_Author{ext - covered, run.src.seq + u64(covered), graph_intern(g, run.src.actor)})
	}
	if ext < n {
		d := int(seq - run.src.seq)
		r := start
		o := ext - d
		for o >= log.authors[r].len {
			o -= log.authors[r].len
			r += 1
		}
		for i in ext ..< n {
			dst[i] = dst[i - d]
			a := log.authors[r]
			copy_author_push(log, start, Copy_Author{1, a.seq + u64(o), a.actor})
			o += 1
			if o >= log.authors[r].len {
				o = 0
				r += 1
			}
		}
	}
	return err
}

@(private)
copy_author_push :: proc(log: ^Text_Log, start: int, a: Copy_Author) {
	if n := len(log.authors); n > start {
		l := &log.authors[n - 1]
		if l.actor == a.actor && l.seq + u64(l.len) == a.seq {
			l.len += a.len
			return
		}
	}
	append(&log.authors, a)
}

@(private)
log_find :: proc "contextless" (log: ^Text_Log, lv: Lv) -> int {
	e := log.entries[:]
	if n := len(e); n > 0 && e[n - 1].lv <= lv {
		return n - 1 if lv < e[n - 1].lv + e[n - 1].len else n
	}
	lo, hi := 0, len(e)
	for lo < hi {
		mid := (lo + hi) / 2
		if e[mid].lv + e[mid].len <= lv {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

log_push :: proc(log: ^Text_Log, g: ^Graph, lv: Lv, run: Op_Run) -> Error {
	if run.kind == .Opaque || run.len <= 0 || lv < log.floor {
		return .None
	}
	n := len(log.entries)
	if n > 0 && lv < log.entries[n - 1].lv + log.entries[n - 1].len {
		i := log_find(log, lv)
		if i < n && log.entries[i].lv < lv + run.len {
			return .None
		}
		e, err := log_store(log, g, lv, run)
		inject_at(&log.entries, i, e)
		log_redact_new(log, g, lv, run.len)
		return err
	}
	if n > 0 {
		last := &log.entries[n - 1]
		if last.kind == run.kind && !last.red && last.lv + last.len == lv && graph_continues(g, lv) {
			switch run.kind {
			case .Insert:
				if run.pos == last.pos + last.len && last.at + last.len == len(log.bytes) {
					append(&log.bytes, ..run.content[:run.len])
					last.len += run.len
					log_redact_new(log, g, lv, run.len)
					return .None
				}
			case .Insert_Ref:
				r := log.refs[last.at]
				if run.pos == last.pos + last.len && run.ref.oid == r.oid && run.ref.offset == r.offset + last.len {
					last.len += run.len
					log_redact_new(log, g, lv, run.len)
					return .None
				}
			case .Delete:
				if run.pos == last.pos {
					last.len += run.len
					return .None
				}
			case .Delete_Back:
				if run.pos == last.pos - last.len {
					last.len += run.len
					return .None
				}
			case .Opaque, .Insert_Copy:
			}
		}
	}
	if run.kind == .Insert {
		at := len(log.bytes)
		append(&log.bytes, ..run.content[:run.len])
		append(&log.entries, Log_Entry{lv = lv, len = run.len, pos = run.pos, at = at, kind = .Insert})
		log_redact_new(log, g, lv, run.len)
		return .None
	}
	e, err := log_store(log, g, lv, run)
	append(&log.entries, e)
	log_redact_new(log, g, lv, run.len)
	return err
}

@(private)
log_redact_new :: proc(log: ^Text_Log, g: ^Graph, lv: Lv, n: int) {
	actor, seq := graph_op(g, lv)
	if int(actor) >= len(g.seqs) || len(g.seqs[actor].red) == 0 {
		return
	}
	graph_redacted(g, actor, seq, n, &g.red)
	for r in g.red {
		log_mark(log, lv + int(r.seq - seq), r.len)
	}
}

@(private)
log_split :: proc(log: ^Text_Log, lv: Lv) {
	i := log_find(log, lv)
	if i >= len(log.entries) {
		return
	}
	e := log.entries[i]
	if e.lv >= lv || e.lv + e.len <= lv {
		return
	}
	k := lv - e.lv
	right := e
	right.lv = lv
	right.len = e.len - k
	#partial switch e.kind {
	case .Insert:
		right.pos = e.pos + k
		right.at = e.at + k
	case .Insert_Ref:
		right.pos = e.pos + k
		ref := log.refs[e.at]
		ref.offset += k
		append(&log.refs, ref)
		right.at = len(log.refs) - 1
	case .Insert_Copy:
		right.pos = e.pos + k
		right.at = e.at + k
		right.au = u32(len(log.authors))
		off := 0
		cut := int(e.nau)
		for j in 0 ..< int(e.nau) {
			a := log.authors[int(e.au) + j]
			if off + a.len > k {
				d := max(k - off, 0)
				if cut == int(e.nau) {
					cut = j
				}
				append(&log.authors, Copy_Author{a.len - d, a.seq + u64(d), a.actor})
			}
			off += a.len
		}
		right.nau = u32(len(log.authors)) - right.au
		left := &log.entries[i]
		if cut < int(e.nau) {
			lead := k
			for j in 0 ..< cut {
				lead -= log.authors[int(e.au) + j].len
			}
			if lead > 0 {
				log.authors[int(e.au) + cut].len = lead
				cut += 1
			}
		}
		left.nau = u32(cut)
	case .Delete_Back:
		right.pos = e.pos - k
	}
	log.entries[i].len = k
	inject_at(&log.entries, i + 1, right)
}

@(private)
log_mark :: proc(log: ^Text_Log, lv: Lv, n: int) {
	log_split(log, lv)
	log_split(log, lv + n)
	for i := log_find(log, lv); i < len(log.entries) && log.entries[i].lv < lv + n; i += 1 {
		e := &log.entries[i]
		if !is_insert(e.kind) || e.red {
			continue
		}
		e.red = true
		if e.kind == .Insert || e.kind == .Insert_Copy {
			for &b in log.bytes[e.at:][:e.len] {
				b = 0
			}
		}
	}
}

log_redact :: proc(log: ^Text_Log, g: ^Graph, actor: prim.Id, seq: u64, n: int) {
	ix, ok := graph_actor(g, actor)
	if !ok || n <= 0 {
		return
	}
	end := seq + u64(n)
	cur := seq
	for cur < end {
		lv, avail, found := graph_seq_span(g, ix, cur)
		if !found {
			return
		}
		k := min(int(end - cur), avail)
		log_mark(log, lv, k)
		cur += u64(k)
	}
}


log_add_batch :: proc(log: ^Text_Log, g: ^Graph, b: ^Batch, target: Op_Id, first: Lv, skip: int) -> (err: Error) {
	lv := first
	rest := skip
	for &op in b.ops {
		if rest >= op.len {
			rest -= op.len
			continue
		}
		if op.target == target && op.kind != .Opaque {
			if e := log_push(log, g, lv, run_tail(op, rest)); e != .None {
				err = e
			}
		}
		lv += op.len - rest
		rest = 0
	}
	return
}

run_tail :: proc "contextless" (op: Op_Run, k: int) -> Op_Run {
	if k <= 0 {
		return op
	}
	r := op
	r.len = op.len - k
	switch op.kind {
	case .Insert:
		r.pos = op.pos + k
		r.content = op.content[k:]
	case .Insert_Ref:
		r.pos = op.pos + k
		r.ref.offset = op.ref.offset + k
	case .Insert_Copy:
		r.pos = op.pos + k
		r.src.seq = op.src.seq + u64(k)
	case .Delete:
	case .Delete_Back:
		r.pos = op.pos - k
	case .Opaque:
		r.content = nil
	}
	return r
}

run_head :: proc "contextless" (op: Op_Run, k: int) -> Op_Run {
	r := op
	r.len = k
	if op.kind == .Insert {
		r.content = op.content[:k]
	}
	return r
}

log_trim :: proc(log: ^Text_Log, floor: Lv) {
	i := 0
	for i < len(log.entries) && log.entries[i].lv + log.entries[i].len <= floor {
		i += 1
	}
	if i > 0 {
		remove_range(&log.entries, 0, i)
	}
	log.floor = max(log.floor, floor)
	keep := 0
	nrefs := 0
	nau := 0
	for &e in log.entries {
		#partial switch e.kind {
		case .Insert:
			keep += e.len
		case .Insert_Copy:
			keep += e.len
			nau += int(e.nau)
		case .Insert_Ref:
			nrefs += 1
		}
	}
	bytes := make([dynamic]u8, 0, keep, log.bytes.allocator)
	refs := make([dynamic]Content_Ref, 0, nrefs, log.refs.allocator)
	authors := make([dynamic]Copy_Author, 0, nau, log.authors.allocator)
	for &e in log.entries {
		#partial switch e.kind {
		case .Insert, .Insert_Copy:
			at := len(bytes)
			append(&bytes, ..log.bytes[e.at:e.at + e.len])
			e.at = at
			if e.kind == .Insert_Copy {
				au := len(authors)
				append(&authors, ..log.authors[e.au:][:e.nau])
				e.au = u32(au)
			}
		case .Insert_Ref:
			append(&refs, log.refs[e.at])
			e.at = len(refs) - 1
		}
	}
	delete(log.bytes)
	delete(log.refs)
	delete(log.authors)
	log.bytes = bytes
	log.refs = refs
	log.authors = authors
}

log_read :: proc(log: ^Text_Log, g: ^Graph, src: Op_Id, dst: []u8, authors: ^[dynamic]Author_Span) -> int {
	ix, ok := graph_actor(g, src.actor)
	if !ok {
		return 0
	}
	done := 0
	for done < len(dst) {
		lv, avail, found := graph_seq_span(g, ix, src.seq + u64(done))
		if !found {
			return done
		}
		want := min(avail, len(dst) - done)
		got := log_read_lv(log, g, lv, dst[done:][:want], authors)
		done += got
		if got < want {
			return done
		}
	}
	return done
}

@(private)
log_read_lv :: proc(log: ^Text_Log, g: ^Graph, lv: Lv, dst: []u8, authors: ^[dynamic]Author_Span) -> int {
	done := 0
	i := log_find(log, lv)
	for done < len(dst) && i < len(log.entries) {
		e := log.entries[i]
		at := lv + done
		if e.lv > at || !is_insert(e.kind) {
			break
		}
		k := at - e.lv
		n := min(e.len - k, len(dst) - done)
		out := dst[done:][:n]
		switch e.kind {
		case .Insert:
			copy(out, log.bytes[e.at + k:][:n])
		case .Insert_Copy:
			copy(out, log.bytes[e.at + k:][:n])
		case .Insert_Ref:
			ref := log.refs[e.at]
			src := log.content
			if e.red {
				for &b in out {
					b = 0
				}
			} else if src.read == nil || !src.read(src.data, ref.oid, ref.offset + k, out) {
				return done
			}
		case .Delete, .Delete_Back, .Opaque:
		}
		if e.kind == .Insert_Copy {
			off := 0
			for a in log.authors[e.au:][:e.nau] {
				lo := max(off, k)
				hi := min(off + a.len, k + n)
				if hi > lo {
					append(authors, Author_Span{id = Op_Id{g.actors[a.actor], a.seq + u64(lo - off)}, len = hi - lo})
				}
				off += a.len
			}
		} else {
			actor, seq := graph_op(g, at)
			append(authors, Author_Span{id = Op_Id{g.actors[actor], seq}, len = n})
		}
		done += n
		i += 1
	}
	return done
}

log_pieces :: proc(log: ^Text_Log, spans: []Lv_Span, out: ^[dynamic]Piece) -> Error {
	for s in spans {
		if s.lv < log.floor {
			return .Missing_Ops
		}
		i := log_find(log, s.lv)
		end := s.lv + s.len
		for i < len(log.entries) && log.entries[i].lv < end {
			e := log.entries[i]
			a := max(e.lv, s.lv)
			b := min(e.lv + e.len, end)
			if b > a {
				append(out, Piece{a, b - a, i})
			}
			i += 1
		}
	}
	return .None
}

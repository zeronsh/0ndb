package crdt

import "../prim"

Log_Entry :: struct {
	lv:   Lv,
	len:  int,
	pos:  int,
	at:   int,
	kind: Op_Kind,
	red:  bool,
}

Text_Log :: struct {
	entries: [dynamic]Log_Entry,
	bytes:   [dynamic]u8,
	refs:    [dynamic]Content_Ref,
	floor:   Lv,
	content: Content_Source,
}

Piece :: struct {
	lv:    Lv,
	len:   int,
	entry: int,
}

log_init :: proc(log: ^Text_Log, allocator := context.allocator, content := Content_Source{}) {
	log^ = {}
	log.entries = make([dynamic]Log_Entry, allocator)
	log.bytes = make([dynamic]u8, allocator)
	log.refs = make([dynamic]Content_Ref, allocator)
	log.content = content
}

log_destroy :: proc(log: ^Text_Log) {
	delete(log.entries)
	delete(log.bytes)
	delete(log.refs)
	log^ = {}
}

@(private)
log_store :: proc(log: ^Text_Log, run: Op_Run) -> int {
	#partial switch run.kind {
	case .Insert:
		at := len(log.bytes)
		append(&log.bytes, ..run.content[:run.len])
		return at
	case .Insert_Ref:
		append(&log.refs, run.ref)
		return len(log.refs) - 1
	}
	return -1
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

log_push :: proc(log: ^Text_Log, g: ^Graph, lv: Lv, run: Op_Run) {
	if run.kind == .Opaque || run.len <= 0 || lv < log.floor {
		return
	}
	n := len(log.entries)
	if n > 0 && lv < log.entries[n - 1].lv + log.entries[n - 1].len {
		i := log_find(log, lv)
		if i < n && log.entries[i].lv < lv + run.len {
			return
		}
		inject_at(&log.entries, i, Log_Entry{lv = lv, len = run.len, pos = run.pos, at = log_store(log, run), kind = run.kind})
		log_redact_new(log, g, lv, run.len)
		return
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
					return
				}
			case .Insert_Ref:
				r := log.refs[last.at]
				if run.pos == last.pos + last.len && run.ref.oid == r.oid && run.ref.offset == r.offset + last.len {
					last.len += run.len
					log_redact_new(log, g, lv, run.len)
					return
				}
			case .Delete:
				if run.pos == last.pos {
					last.len += run.len
					return
				}
			case .Delete_Back:
				if run.pos == last.pos - last.len {
					last.len += run.len
					return
				}
			case .Opaque:
			}
		}
	}
	append(&log.entries, Log_Entry{lv = lv, len = run.len, pos = run.pos, at = log_store(log, run), kind = run.kind})
	log_redact_new(log, g, lv, run.len)
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
		if e.kind == .Insert {
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


log_add_batch :: proc(log: ^Text_Log, g: ^Graph, b: ^Batch, target: Op_Id, first: Lv, skip: int) {
	lv := first
	rest := skip
	for op in b.ops {
		if rest >= op.len {
			rest -= op.len
			continue
		}
		if op.target == target && op.kind != .Opaque {
			log_push(log, g, lv, run_tail(op, rest))
		}
		lv += op.len - rest
		rest = 0
	}
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
	for &e in log.entries {
		if e.kind == .Insert {
			keep += e.len
		} else if e.kind == .Insert_Ref {
			nrefs += 1
		}
	}
	bytes := make([dynamic]u8, 0, keep, log.bytes.allocator)
	refs := make([dynamic]Content_Ref, 0, nrefs, log.refs.allocator)
	for &e in log.entries {
		if e.kind == .Insert {
			at := len(bytes)
			append(&bytes, ..log.bytes[e.at:e.at + e.len])
			e.at = at
		} else if e.kind == .Insert_Ref {
			append(&refs, log.refs[e.at])
			e.at = len(refs) - 1
		}
	}
	delete(log.bytes)
	delete(log.refs)
	log.bytes = bytes
	log.refs = refs
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

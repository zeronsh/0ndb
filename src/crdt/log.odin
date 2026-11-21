package crdt

Log_Entry :: struct {
	lv:   Lv,
	len:  int,
	pos:  int,
	at:   int,
	kind: Op_Kind,
}

Text_Log :: struct {
	entries: [dynamic]Log_Entry,
	bytes:   [dynamic]u8,
	floor:   Lv,
}

Piece :: struct {
	lv:    Lv,
	len:   int,
	entry: int,
}

log_init :: proc(log: ^Text_Log, allocator := context.allocator) {
	log^ = {}
	log.entries = make([dynamic]Log_Entry, allocator)
	log.bytes = make([dynamic]u8, allocator)
}

log_destroy :: proc(log: ^Text_Log) {
	delete(log.entries)
	delete(log.bytes)
	log^ = {}
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
		at := -1
		if run.kind == .Insert {
			at = len(log.bytes)
			append(&log.bytes, ..run.content[:run.len])
		}
		inject_at(&log.entries, i, Log_Entry{lv = lv, len = run.len, pos = run.pos, at = at, kind = run.kind})
		return
	}
	if n > 0 {
		last := &log.entries[n - 1]
		if last.kind == run.kind && last.lv + last.len == lv && graph_continues(g, lv) {
			switch run.kind {
			case .Insert:
				if run.pos == last.pos + last.len && last.at + last.len == len(log.bytes) {
					append(&log.bytes, ..run.content[:run.len])
					last.len += run.len
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
	at := -1
	if run.kind == .Insert {
		at = len(log.bytes)
		append(&log.bytes, ..run.content[:run.len])
	}
	append(&log.entries, Log_Entry{lv = lv, len = run.len, pos = run.pos, at = at, kind = run.kind})
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
	for &e in log.entries {
		if e.kind == .Insert {
			keep += e.len
		}
	}
	bytes := make([dynamic]u8, 0, keep, log.bytes.allocator)
	for &e in log.entries {
		if e.kind == .Insert {
			at := len(bytes)
			append(&bytes, ..log.bytes[e.at:e.at + e.len])
			e.at = at
		}
	}
	delete(log.bytes)
	log.bytes = bytes
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

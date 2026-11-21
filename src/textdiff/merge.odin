package textdiff

import "base:runtime"

DEFAULT_MARKER_SIZE :: 7

Merge_Style :: enum u8 {
	Merge,
	Diff3,
	Zdiff3,
}

Merge_Options :: struct {
	style:        Merge_Style,
	ours_label:   string,
	base_label:   string,
	theirs_label: string,
	marker_size:  int,
	algorithm:    Algorithm,
}

Merge_Result :: struct {
	data:      []u8,
	conflicts: int,
}

@(private)
Chunk_Mode :: enum u8 {
	Conflict,
	Ours,
	Theirs,
	Same,
}

@(private)
Chunk :: struct {
	mode:   Chunk_Mode,
	i0, c0: int,
	i1, c1: int,
	i2, c2: int,
}

@(private)
Merge_Input :: struct {
	base, ours, theirs: Lines,
}

merge3 :: proc(base, ours, theirs: []u8, opts := Merge_Options{}, allocator := context.allocator) -> (result: Merge_Result, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	in_ := Merge_Input {
		base   = split_lines(base, context.temp_allocator) or_return,
		ours   = split_lines(ours, context.temp_allocator) or_return,
		theirs = split_lines(theirs, context.temp_allocator) or_return,
	}
	dopts := Diff_Options {
		algorithm = opts.algorithm,
	}
	e1 := diff_lines(in_.base, in_.ours, dopts, context.temp_allocator) or_return
	e2 := diff_lines(in_.base, in_.theirs, dopts, context.temp_allocator) or_return
	chunks := make([dynamic]Chunk, 0, len(e1) + len(e2), context.temp_allocator) or_return
	combine(&chunks, &in_, e1, e2) or_return
	for &m in chunks {
		if m.mode == .Conflict && equal_bytes(lines_bytes(in_.ours, m.i1, m.c1), lines_bytes(in_.theirs, m.i2, m.c2)) {
			m.mode = .Same
		}
	}
	switch opts.style {
	case .Merge:
		chunks = refine(chunks[:], &in_, opts.algorithm) or_return
		simplify(&chunks, in_.ours)
	case .Zdiff3:
		trim_conflicts(chunks[:], &in_)
	case .Diff3:
	}
	for m in chunks {
		if m.mode == .Conflict {
			result.conflicts += 1
		}
	}
	o: Out
	fill_merge(&o, &in_, chunks[:], opts)
	o.buf = make([]u8, o.n, allocator) or_return
	o.n = 0
	fill_merge(&o, &in_, chunks[:], opts)
	result.data = o.buf
	return result, nil
}

@(private)
combine :: proc(chunks: ^[dynamic]Chunk, in_: ^Merge_Input, e1, e2: []Edit) -> Error {
	nb, no, nt := line_count(in_.base), line_count(in_.ours), line_count(in_.theirs)
	x, y := 0, 0
	for x < len(e1) && y < len(e2) {
		p, q := e1[x], e2[y]
		pa, pal, pb, pbl := int(p.a_start), int(p.a_len), int(p.b_start), int(p.b_len)
		qa, qal, qb, qbl := int(q.a_start), int(q.a_len), int(q.b_start), int(q.b_len)
		if pa + pal < qa {
			add_chunk(chunks, Chunk{.Ours, pa, pal, pb, pbl, qb - qa + pa, pal}) or_return
			x += 1
			continue
		}
		if qa + qal < pa {
			add_chunk(chunks, Chunk{.Theirs, qa, qal, pb - pa + qa, qal, qb, qbl}) or_return
			y += 1
			continue
		}
		if pa != qa || pal != qal || pbl != qbl || !equal_bytes(lines_bytes(in_.ours, pb, pbl), lines_bytes(in_.theirs, qb, qbl)) {
			off := pa - qa
			ffo := off + pal - qal
			i0, i1, i2 := pa, pb, qb
			if off > 0 {
				i0 -= off
				i1 -= off
			} else {
				i2 += off
			}
			c0, c1, c2 := pa + pal - i0, pb + pbl - i1, qb + qbl - i2
			if ffo < 0 {
				c0 -= ffo
				c1 -= ffo
			} else {
				c2 += ffo
			}
			add_chunk(chunks, Chunk{.Conflict, i0, c0, i1, c1, i2, c2}) or_return
		}
		end1, end2 := pa + pal, qa + qal
		if end1 >= end2 {
			y += 1
		}
		if end2 >= end1 {
			x += 1
		}
	}
	for ; x < len(e1); x += 1 {
		p := e1[x]
		pa, pal := int(p.a_start), int(p.a_len)
		add_chunk(chunks, Chunk{.Ours, pa, pal, int(p.b_start), int(p.b_len), pa + nt - nb, pal}) or_return
	}
	for ; y < len(e2); y += 1 {
		q := e2[y]
		qa, qal := int(q.a_start), int(q.a_len)
		add_chunk(chunks, Chunk{.Theirs, qa, qal, qa + no - nb, qal, int(q.b_start), int(q.b_len)}) or_return
	}
	return nil
}

@(private)
add_chunk :: proc(chunks: ^[dynamic]Chunk, c: Chunk) -> Error {
	if len(chunks) > 0 {
		m := &chunks[len(chunks) - 1]
		if c.i1 <= m.i1 + m.c1 || c.i2 <= m.i2 + m.c2 {
			if c.mode != m.mode {
				m.mode = .Conflict
			}
			m.c0 = c.i0 + c.c0 - m.i0
			m.c1 = c.i1 + c.c1 - m.i1
			m.c2 = c.i2 + c.c2 - m.i2
			return nil
		}
	}
	_, err := append(chunks, c)
	return err
}

@(private)
refine :: proc(chunks: []Chunk, in_: ^Merge_Input, algorithm: Algorithm) -> (out: [dynamic]Chunk, err: Error) {
	out = make([dynamic]Chunk, 0, len(chunks), context.temp_allocator) or_return
	for m in chunks {
		if m.mode != .Conflict || m.c1 == 0 || m.c2 == 0 {
			append(&out, m) or_return
			continue
		}
		edits := diff(lines_bytes(in_.ours, m.i1, m.c1), lines_bytes(in_.theirs, m.i2, m.c2), Diff_Options{algorithm = algorithm}, context.temp_allocator) or_return
		if len(edits) == 0 {
			r := m
			r.mode = .Same
			append(&out, r) or_return
			continue
		}
		for e in edits {
			r := m
			r.i1, r.c1 = m.i1 + int(e.a_start), int(e.a_len)
			r.i2, r.c2 = m.i2 + int(e.b_start), int(e.b_len)
			append(&out, r) or_return
		}
	}
	return out, nil
}

@(private)
trim_conflicts :: proc "contextless" (chunks: []Chunk, in_: ^Merge_Input) {
	for &m in chunks {
		if m.mode != .Conflict {
			continue
		}
		for m.c1 > 0 && m.c2 > 0 && equal_bytes(line(in_.ours, m.i1), line(in_.theirs, m.i2)) {
			m.i1 += 1
			m.i2 += 1
			m.c1 -= 1
			m.c2 -= 1
		}
		for m.c1 > 0 && m.c2 > 0 && equal_bytes(line(in_.ours, m.i1 + m.c1 - 1), line(in_.theirs, m.i2 + m.c2 - 1)) {
			m.c1 -= 1
			m.c2 -= 1
		}
	}
}

@(private)
simplify :: proc(chunks: ^[dynamic]Chunk, ours: Lines) {
	if len(chunks) == 0 {
		return
	}
	w := 0
	for r in 1 ..< len(chunks) {
		m := &chunks[w]
		next := chunks[r]
		begin, end := m.i1 + m.c1, next.i1
		if m.mode != .Conflict || next.mode != .Conflict || (end - begin > 3 && contains_alnum(lines_bytes(ours, begin, end - begin))) {
			w += 1
			chunks[w] = next
		} else {
			m.c1 = next.i1 + next.c1 - m.i1
			m.c2 = next.i2 + next.c2 - m.i2
		}
	}
	resize(chunks, w + 1)
}

@(private)
contains_alnum :: proc "contextless" (s: []u8) -> bool {
	for c in s {
		if c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' {
			return true
		}
	}
	return false
}

@(private)
fill_merge :: proc "contextless" (o: ^Out, in_: ^Merge_Input, chunks: []Chunk, opts: Merge_Options) {
	i := 0
	for m in chunks {
		switch m.mode {
		case .Same, .Ours:
			continue
		case .Theirs:
			put(o, lines_bytes(in_.ours, i, m.i1 - i))
			put(o, lines_bytes(in_.theirs, m.i2, m.c2))
		case .Conflict:
			put(o, lines_bytes(in_.ours, i, m.i1 - i))
			conflict_hunk(o, in_, m, opts)
		}
		i = m.i1 + m.c1
	}
	put(o, lines_bytes(in_.ours, i, line_count(in_.ours) - i))
}

@(private)
conflict_hunk :: proc "contextless" (o: ^Out, in_: ^Merge_Input, m: Chunk, opts: Merge_Options) {
	size := opts.marker_size > 0 ? opts.marker_size : DEFAULT_MARKER_SIZE
	cr := needs_cr(in_, m)
	marker(o, '<', size, opts.ours_label, cr)
	copy_lines(o, in_.ours, m.i1, m.c1, cr)
	if opts.style != .Merge {
		marker(o, '|', size, opts.base_label, cr)
		copy_lines(o, in_.base, m.i0, m.c0, cr)
	}
	marker(o, '=', size, "", cr)
	copy_lines(o, in_.theirs, m.i2, m.c2, cr)
	marker(o, '>', size, opts.theirs_label, cr)
}

@(private)
marker :: proc "contextless" (o: ^Out, c: u8, size: int, label: string, cr: bool) {
	put_repeat(o, c, size)
	if label != "" {
		put_byte(o, ' ')
		put_str(o, label)
	}
	if cr {
		put_byte(o, '\r')
	}
	put_byte(o, '\n')
}

@(private)
copy_lines :: proc "contextless" (o: ^Out, l: Lines, start, count: int, cr: bool) {
	if count < 1 {
		return
	}
	s := lines_bytes(l, start, count)
	put(o, s)
	if s[len(s) - 1] != '\n' {
		if cr {
			put_byte(o, '\r')
		}
		put_byte(o, '\n')
	}
}

@(private)
needs_cr :: proc "contextless" (in_: ^Merge_Input, m: Chunk) -> bool {
	v := eol_crlf(in_.ours, max(m.i1 - 1, 0))
	if v != 0 {
		v = eol_crlf(in_.theirs, max(m.i2 - 1, 0))
	}
	if v != 0 {
		v = eol_crlf(in_.base, 0)
	}
	return v > 0
}

@(private)
eol_crlf :: proc "contextless" (l: Lines, at: int) -> int {
	n := line_count(l)
	if n == 0 {
		return -1
	}
	i := min(at, n - 1)
	s := line(l, i)
	if i < n - 1 || (len(s) > 0 && s[len(s) - 1] == '\n') {
		return ends_crlf(s)
	}
	if i == 0 {
		return -1
	}
	return ends_crlf(line(l, i - 1))
}

@(private)
ends_crlf :: #force_inline proc "contextless" (s: []u8) -> int {
	return len(s) > 1 && s[len(s) - 2] == '\r' ? 1 : 0
}

package textdiff

import "base:runtime"

HEADING_MAX :: 80

Unified_Options :: struct {
	context_lines: int,
	a_label:       string,
	b_label:       string,
	headings:      bool,
	diff:          Diff_Options,
}

DEFAULT_UNIFIED :: Unified_Options {
	context_lines = 3,
	diff = DEFAULT_DIFF,
}

NO_NEWLINE_MARKER :: "\\ No newline at end of file\n"

unified :: proc(a, b: []u8, opts := DEFAULT_UNIFIED, allocator := context.allocator) -> (text: []u8, st: Stats, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	ta, tb := a, b
	if opts.context_lines <= 0 {
		ta, tb = trim_common_tail(a, b)
	}
	la := split_lines(ta, context.temp_allocator) or_return
	lb := split_lines(tb, context.temp_allocator) or_return
	edits := diff_lines(la, lb, opts.diff, context.temp_allocator) or_return
	text = render_unified(la, lb, edits, opts, allocator) or_return
	return text, stats(edits), nil
}

render_unified :: proc(a, b: Lines, edits: []Edit, opts := DEFAULT_UNIFIED, allocator := context.allocator) -> (text: []u8, err: Error) {
	if len(edits) == 0 {
		return nil, nil
	}
	o: Out
	emit_unified(&o, a, b, edits, opts)
	o.buf = make([]u8, o.n, allocator) or_return
	o.n = 0
	emit_unified(&o, a, b, edits, opts)
	return o.buf, nil
}

@(private)
TAIL_BLOCK :: 1024

@(private)
trim_common_tail :: proc "contextless" (a, b: []u8) -> ([]u8, []u8) {
	smaller := min(len(a), len(b))
	trimmed := 0
	for trimmed + TAIL_BLOCK <= smaller &&
	    equal_bytes(a[len(a) - trimmed - TAIL_BLOCK:len(a) - trimmed], b[len(b) - trimmed - TAIL_BLOCK:len(b) - trimmed]) {
		trimmed += TAIL_BLOCK
	}
	recovered := 0
	for recovered < trimmed {
		c := a[len(a) - trimmed + recovered]
		recovered += 1
		if c == '\n' {
			break
		}
	}
	cut := trimmed - recovered
	return a[:len(a) - cut], b[:len(b) - cut]
}

@(private)
Out :: struct {
	buf: []u8,
	n:   int,
}

@(private)
put :: #force_inline proc "contextless" (o: ^Out, s: []u8) {
	if o.buf != nil {
		copy(o.buf[o.n:], s)
	}
	o.n += len(s)
}

@(private)
put_str :: #force_inline proc "contextless" (o: ^Out, s: string) {
	put(o, transmute([]u8)s)
}

@(private)
put_byte :: #force_inline proc "contextless" (o: ^Out, c: u8) {
	if o.buf != nil {
		o.buf[o.n] = c
	}
	o.n += 1
}

@(private)
put_repeat :: proc "contextless" (o: ^Out, c: u8, count: int) {
	for _ in 0 ..< count {
		put_byte(o, c)
	}
}

@(private)
put_uint :: proc "contextless" (o: ^Out, v: int) {
	digits: [20]u8
	i := len(digits)
	x := u64(max(v, 0))
	for {
		i -= 1
		digits[i] = '0' + u8(x % 10)
		x /= 10
		if x == 0 {
			break
		}
	}
	put(o, digits[i:])
}

@(private)
put_record :: proc "contextless" (o: ^Out, prefix: u8, s: []u8) {
	put_byte(o, prefix)
	put(o, s)
	if len(s) == 0 || s[len(s) - 1] != '\n' {
		put_byte(o, '\n')
		put_str(o, NO_NEWLINE_MARKER)
	}
}

@(private)
put_range :: proc "contextless" (o: ^Out, start, count: int) {
	put_uint(o, count == 0 ? start : start + 1)
	if count != 1 {
		put_byte(o, ',')
		put_uint(o, count)
	}
}

@(private)
emit_unified :: proc "contextless" (o: ^Out, a, b: Lines, edits: []Edit, opts: Unified_Options) {
	ctx := max(opts.context_lines, 0)
	na, nb := line_count(a), line_count(b)
	if opts.a_label != "" || opts.b_label != "" {
		put_str(o, "--- ")
		put_str(o, opts.a_label)
		put_str(o, "\n+++ ")
		put_str(o, opts.b_label)
		put_byte(o, '\n')
	}
	heading: []u8
	heading_floor := -1
	i := 0
	for i < len(edits) {
		first, last := i, i
		for last + 1 < len(edits) && int(edits[last + 1].a_start) - int(edits[last].a_start + edits[last].a_len) <= 2 * ctx {
			last += 1
		}
		f, l := edits[first], edits[last]
		s1, s2 := max(int(f.a_start) - ctx, 0), max(int(f.b_start) - ctx, 0)
		end1, end2 := int(l.a_start + l.a_len), int(l.b_start + l.b_len)
		lctx := min(ctx, na - end1, nb - end2)
		e1, e2 := end1 + lctx, end2 + lctx
		if opts.headings {
			for k := s1 - 1; k > heading_floor; k -= 1 {
				if h, ok := heading_of(line(a, k)); ok {
					heading = h
					break
				}
			}
			heading_floor = s1 - 1
		}
		put_str(o, "@@ -")
		put_range(o, s1, e1 - s1)
		put_str(o, " +")
		put_range(o, s2, e2 - s2)
		put_str(o, " @@")
		if len(heading) > 0 {
			put_byte(o, ' ')
			put(o, heading)
		}
		put_byte(o, '\n')
		k2 := s2
		for e in edits[first:last + 1] {
			for ; k2 < int(e.b_start); k2 += 1 {
				put_record(o, ' ', line(b, k2))
			}
			for k in int(e.a_start) ..< int(e.a_start + e.a_len) {
				put_record(o, '-', line(a, k))
			}
			for ; k2 < int(e.b_start + e.b_len); k2 += 1 {
				put_record(o, '+', line(b, k2))
			}
		}
		for ; k2 < e2; k2 += 1 {
			put_record(o, ' ', line(b, k2))
		}
		i = last + 1
	}
}

@(private)
heading_of :: proc "contextless" (s: []u8) -> ([]u8, bool) {
	if len(s) == 0 {
		return nil, false
	}
	c := s[0]
	if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == '$') {
		return nil, false
	}
	h := s[:min(len(s), HEADING_MAX)]
	for len(h) > 0 && is_space(h[len(h) - 1]) {
		h = h[:len(h) - 1]
	}
	return h, true
}

@(private)
is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

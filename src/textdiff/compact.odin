package textdiff

@(private)
Side :: struct {
	chg:  []u8,
	l:    Lines,
	ids:  []u32,
	base: int,
	n:    int,
}

@(private)
Group :: struct {
	start, end: int,
}

@(private)
compact :: proc(d: ^Differ, swapped: bool, indent_heuristic: bool) {
	x := Side{d.chga, d.a, d.ida, d.a0, len(d.chga) - 2}
	o := Side{d.chgb, d.b, d.idb, d.b0, len(d.chgb) - 2}
	if swapped {
		x, o = o, x
	}
	lim_x, lim_o := last_changed(x.chg), last_changed(o.chg)
	start := min(first_changed(x.chg), first_changed(o.chg))
	g, go := group_at(&x, start), group_at(&o, start)
	for g.start < lim_x || go.start < lim_o {
		if g.end != g.start {
			size, earliest_end, end_matching_other := 0, 0, -1
			for {
				size = g.end - g.start
				end_matching_other = -1
				for slide_up(&x, &g) {
					if !group_previous(&o, &go) {
						return
					}
				}
				earliest_end = g.end
				if go.end > go.start {
					end_matching_other = g.end
				}
				for slide_down(&x, &g) {
					if !group_next(&o, &go) {
						return
					}
					if go.end > go.start {
						end_matching_other = g.end
					}
				}
				if size == g.end - g.start {
					break
				}
			}
			target := g.end
			if g.end != earliest_end && end_matching_other != -1 {
				target = end_matching_other
			} else if g.end != earliest_end && indent_heuristic {
				target = best_shift(&x, g.end, earliest_end, size)
			}
			for g.end > target {
				if !slide_up(&x, &g) || !group_previous(&o, &go) {
					return
				}
			}
		}
		if !group_next(&x, &g) || !group_next(&o, &go) {
			return
		}
	}
}

@(private)
MAX_INDENT :: 200
@(private)
MAX_BLANKS :: 20
@(private)
START_OF_FILE_PENALTY :: 1
@(private)
END_OF_FILE_PENALTY :: 21
@(private)
TOTAL_BLANK_WEIGHT :: -30
@(private)
POST_BLANK_WEIGHT :: 6
@(private)
RELATIVE_INDENT_PENALTY :: -4
@(private)
RELATIVE_INDENT_WITH_BLANK_PENALTY :: 10
@(private)
RELATIVE_OUTDENT_PENALTY :: 24
@(private)
RELATIVE_OUTDENT_WITH_BLANK_PENALTY :: 17
@(private)
RELATIVE_DEDENT_PENALTY :: 23
@(private)
RELATIVE_DEDENT_WITH_BLANK_PENALTY :: 17
@(private)
INDENT_WEIGHT :: 60
@(private)
INDENT_HEURISTIC_MAX_SLIDING :: 100

@(private)
Split_Measurement :: struct {
	end_of_file: bool,
	indent:      int,
	pre_blank:   int,
	pre_indent:  int,
	post_blank:  int,
	post_indent: int,
}

@(private)
Split_Score :: struct {
	effective_indent: int,
	penalty:          int,
}

@(private)
best_shift :: proc "contextless" (s: ^Side, end, earliest_end, size: int) -> int {
	shift := max(earliest_end, end - size - 1, end - INDENT_HEURISTIC_MAX_SLIDING)
	best := -1
	best_score: Split_Score
	for ; shift <= end; shift += 1 {
		score: Split_Score
		score_split(measure_split(s, shift), &score)
		score_split(measure_split(s, shift - size), &score)
		if best == -1 || score_cmp(score, best_score) <= 0 {
			best_score = score
			best = shift
		}
	}
	return best
}

@(private)
get_indent :: proc "contextless" (s: []u8) -> int {
	ret := 0
	for c in s {
		if !is_space(c) {
			return ret
		}
		if c == ' ' {
			ret += 1
		} else if c == '\t' {
			ret += 8 - ret % 8
		}
		if ret >= MAX_INDENT {
			return MAX_INDENT
		}
	}
	return -1
}

@(private)
measure_split :: proc "contextless" (s: ^Side, split: int) -> (m: Split_Measurement) {
	if split >= s.n {
		m.end_of_file = true
		m.indent = -1
	} else {
		m.indent = get_indent(line(s.l, split))
	}
	m.pre_indent = -1
	for i := split - 1; i >= 0; i -= 1 {
		m.pre_indent = get_indent(line(s.l, i))
		if m.pre_indent != -1 {
			break
		}
		m.pre_blank += 1
		if m.pre_blank == MAX_BLANKS {
			m.pre_indent = 0
			break
		}
	}
	m.post_indent = -1
	for i := split + 1; i < s.n; i += 1 {
		m.post_indent = get_indent(line(s.l, i))
		if m.post_indent != -1 {
			break
		}
		m.post_blank += 1
		if m.post_blank == MAX_BLANKS {
			m.post_indent = 0
			break
		}
	}
	return
}

@(private)
score_split :: proc "contextless" (m: Split_Measurement, s: ^Split_Score) {
	if m.pre_indent == -1 && m.pre_blank == 0 {
		s.penalty += START_OF_FILE_PENALTY
	}
	if m.end_of_file {
		s.penalty += END_OF_FILE_PENALTY
	}
	post_blank := m.indent == -1 ? 1 + m.post_blank : 0
	total_blank := m.pre_blank + post_blank
	s.penalty += TOTAL_BLANK_WEIGHT * total_blank
	s.penalty += POST_BLANK_WEIGHT * post_blank
	indent := m.indent != -1 ? m.indent : m.post_indent
	any_blanks := total_blank != 0
	s.effective_indent += indent
	if indent == -1 || m.pre_indent == -1 || indent == m.pre_indent {
		return
	}
	if indent > m.pre_indent {
		s.penalty += any_blanks ? RELATIVE_INDENT_WITH_BLANK_PENALTY : RELATIVE_INDENT_PENALTY
	} else if m.post_indent != -1 && m.post_indent > indent {
		s.penalty += any_blanks ? RELATIVE_OUTDENT_WITH_BLANK_PENALTY : RELATIVE_OUTDENT_PENALTY
	} else {
		s.penalty += any_blanks ? RELATIVE_DEDENT_WITH_BLANK_PENALTY : RELATIVE_DEDENT_PENALTY
	}
}

@(private)
score_cmp :: proc "contextless" (a, b: Split_Score) -> int {
	cmp := int(a.effective_indent > b.effective_indent) - int(a.effective_indent < b.effective_indent)
	return INDENT_WEIGHT * cmp + (a.penalty - b.penalty)
}

@(private)
rchg :: #force_inline proc "contextless" (s: ^Side, i: int) -> bool {
	return s.chg[i + 1] != 0
}

@(private)
same_line :: proc "contextless" (s: ^Side, i, j: int) -> bool {
	ri, rj := i - s.base, j - s.base
	if ri >= 0 && rj >= 0 && ri < len(s.ids) && rj < len(s.ids) {
		return s.ids[ri] == s.ids[rj]
	}
	return equal_bytes(line(s.l, i), line(s.l, j))
}

@(private)
group_at :: proc "contextless" (s: ^Side, start: int) -> (g: Group) {
	g = {start, start}
	for rchg(s, g.end) {
		g.end += 1
	}
	return
}

@(private)
group_next :: proc "contextless" (s: ^Side, g: ^Group) -> bool {
	if g.end == s.n {
		return false
	}
	g.start = g.end + 1
	g.end = g.start
	for rchg(s, g.end) {
		g.end += 1
	}
	return true
}

@(private)
group_previous :: proc "contextless" (s: ^Side, g: ^Group) -> bool {
	if g.start == 0 {
		return false
	}
	g.end = g.start - 1
	g.start = g.end
	for rchg(s, g.start - 1) {
		g.start -= 1
	}
	return true
}

@(private)
slide_down :: proc "contextless" (s: ^Side, g: ^Group) -> bool {
	if g.end < s.n && same_line(s, g.start, g.end) {
		s.chg[g.start + 1] = 0
		s.chg[g.end + 1] = 1
		g.start += 1
		g.end += 1
		for rchg(s, g.end) {
			g.end += 1
		}
		return true
	}
	return false
}

@(private)
slide_up :: proc "contextless" (s: ^Side, g: ^Group) -> bool {
	if g.start > 0 && same_line(s, g.start - 1, g.end - 1) {
		g.start -= 1
		g.end -= 1
		s.chg[g.start + 1] = 1
		s.chg[g.end + 1] = 0
		for rchg(s, g.start - 1) {
			g.start -= 1
		}
		return true
	}
	return false
}

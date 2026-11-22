package textdiff

import "base:runtime"
import "core:bytes"

BYTE_DIFF_CAP :: 8192

Byte_Edit :: struct {
	pos: u32,
	del: u32,
	ins: u32,
}

@(private)
Span :: struct {
	a0, a1, b0, b1: int,
}

byte_diff :: proc(old, new: []u8, allocator := context.allocator) -> (edits: []Byte_Edit, err: Error) {
	return hunk_edits(old, new, true, allocator)
}

line_edits :: proc(old, new: []u8, allocator := context.allocator) -> (edits: []Byte_Edit, err: Error) {
	return hunk_edits(old, new, false, allocator)
}

@(private)
hunk_edits :: proc(old, new: []u8, refine: bool, allocator: runtime.Allocator) -> (edits: []Byte_Edit, err: Error) {
	if len(old) > MAX_BYTES || len(new) > MAX_BYTES {
		return nil, .Too_Large
	}
	scratch_is_result := allocator.data == context.temp_allocator.data
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = scratch_is_result)
	p := common_prefix(old, new)
	if p == len(old) && p == len(new) {
		return nil, nil
	}
	s := common_suffix(old[p:], new[p:])
	ls := bytes.last_index_byte(old[:p], '\n') + 1
	la, lb := len(old) - s, len(new) - s
	if !at_line_start(old, la, ls) || !at_line_start(new, lb, ls) {
		k := bytes.index_byte(old[la:], '\n')
		if k < 0 {
			la, lb = len(old), len(new)
		} else {
			la += k + 1
			lb += k + 1
		}
	}
	out := make([dynamic]Byte_Edit, 0, 4, allocator) or_return
	ra := split_lines(old[ls:la], context.temp_allocator) or_return
	rb := split_lines(new[ls:lb], context.temp_allocator) or_return
	hunks := diff_lines(ra, rb, DEFAULT_DIFF, context.temp_allocator) or_return
	for h in hunks {
		hunk := Span {
			ls + int(ra.offs[h.a_start]),
			ls + int(ra.offs[h.a_start + h.a_len]),
			ls + int(rb.offs[h.b_start]),
			ls + int(rb.offs[h.b_start + h.b_len]),
		}
		if refine {
			refine_hunk(&out, old, new, hunk, scratch_is_result) or_return
		} else if at, del, ins, ok := single_edit(old[hunk.a0:hunk.a1], new[hunk.b0:hunk.b1]); ok {
			append(&out, Byte_Edit{u32(hunk.b0 + at), u32(del), u32(ins)}) or_return
		} else {
			append(&out, span_edit(hunk)) or_return
		}
	}
	shrink(&out) or_return
	return out[:], nil
}

@(private)
refine_hunk :: proc(out: ^[dynamic]Byte_Edit, old, new: []u8, hunk: Span, scratch_is_result: bool) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = scratch_is_result)
	sp := hunk
	p := common_prefix(old[sp.a0:sp.a1], new[sp.b0:sp.b1])
	sp.a0 += p
	sp.b0 += p
	s := common_suffix(old[sp.a0:sp.a1], new[sp.b0:sp.b1])
	sp.a1 -= s
	sp.b1 -= s
	if sp.a0 == sp.a1 && sp.b0 == sp.b1 {
		return nil
	}
	spans := make([dynamic]Span, 0, 8, context.temp_allocator) or_return
	if sp.a0 == sp.a1 || sp.b0 == sp.b1 || (sp.a1 - sp.a0) + (sp.b1 - sp.b0) > BYTE_DIFF_CAP {
		append(&spans, sp) or_return
	} else {
		byte_myers(&spans, old[sp.a0:sp.a1], new[sp.b0:sp.b1], sp.a0, sp.b0) or_return
		merge_short_equalities(&spans)
	}
	cur: Span
	have := false
	for i in 0 ..< len(spans) {
		x := spans[i]
		lo := have ? cur.a1 : hunk.a0
		hi := i + 1 < len(spans) ? spans[i + 1].a0 : hunk.a1
		for x.a0 > lo && (continuation(old, x.a0) || continuation(new, x.b0)) {
			x.a0 -= 1
			x.b0 -= 1
		}
		for x.a1 < hi && (continuation(old, x.a1) || continuation(new, x.b1)) {
			x.a1 += 1
			x.b1 += 1
		}
		if have && x.a0 <= cur.a1 {
			cur.a1, cur.b1 = x.a1, x.b1
			continue
		}
		if have {
			append(out, span_edit(cur)) or_return
		}
		cur, have = x, true
	}
	if have {
		append(out, span_edit(cur)) or_return
	}
	return nil
}

@(private)
span_edit :: #force_inline proc "contextless" (s: Span) -> Byte_Edit {
	return Byte_Edit{u32(s.b0), u32(s.a1 - s.a0), u32(s.b1 - s.b0)}
}

@(private)
continuation :: #force_inline proc "contextless" (data: []u8, i: int) -> bool {
	return i < len(data) && data[i] & 0xC0 == 0x80
}

@(private)
byte_myers :: proc(spans: ^[dynamic]Span, a, b: []u8, base_a, base_b: int) -> Error {
	d: Differ
	d.ida = make([]u32, len(a), context.temp_allocator) or_return
	d.idb = make([]u32, len(b), context.temp_allocator) or_return
	for c, i in a {
		d.ida[i] = u32(c)
	}
	for c, i in b {
		d.idb[i] = u32(c)
	}
	d.chga = make([]u8, len(a) + 2, context.temp_allocator) or_return
	d.chgb = make([]u8, len(b) + 2, context.temp_allocator) or_return
	myers(&d, Region{0, len(a), 0, len(b)}, .None) or_return
	compact(&d, false, false)
	compact(&d, true, false)
	edits := make([]Edit, walk_edits(&d, nil), context.temp_allocator) or_return
	walk_edits(&d, edits)
	for e in edits {
		a0, b0 := base_a + int(e.a_start), base_b + int(e.b_start)
		append(spans, Span{a0, a0 + int(e.a_len), b0, b0 + int(e.b_len)}) or_return
	}
	return nil
}

@(private)
merge_short_equalities :: proc(spans: ^[dynamic]Span) {
	w := 0
	for r in 0 ..< len(spans) {
		x := spans[r]
		for w > 0 {
			top := spans[w - 1]
			gap := x.a0 - top.a1
			if gap > max(top.a1 - top.a0, top.b1 - top.b0) || gap > max(x.a1 - x.a0, x.b1 - x.b0) {
				break
			}
			x = Span{top.a0, x.a1, top.b0, x.b1}
			w -= 1
		}
		spans[w] = x
		w += 1
	}
	resize(spans, w)
}

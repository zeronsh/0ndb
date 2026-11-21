package textdiff

import "base:runtime"

Revision :: struct {
	data: []u8,
	tag:  u64,
}

blame_step :: proc(prev_tags: []u64, old, new: []u8, tag: u64, allocator := context.allocator) -> (tags: []u64, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	lo := split_lines(old, context.temp_allocator) or_return
	if len(prev_tags) != line_count(lo) {
		return nil, .Tag_Count_Mismatch
	}
	ln := split_lines(new, context.temp_allocator) or_return
	edits := diff_lines(lo, ln, DEFAULT_DIFF, context.temp_allocator) or_return
	tags = make([]u64, line_count(ln), allocator) or_return
	carry_tags(prev_tags, edits, tag, tags)
	return tags, nil
}

blame :: proc(revisions: []Revision, allocator := context.allocator) -> (tags: []u64, err: Error) {
	if len(revisions) == 0 {
		return nil, nil
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	most := 0
	for r in revisions {
		if len(r.data) > MAX_BYTES {
			return nil, .Too_Large
		}
		most = max(most, count_newlines(r.data) + 1)
	}
	offs: [2][]u32
	buf: [2][]u64
	for k in 0 ..< 2 {
		offs[k] = make([]u32, most + 1, context.temp_allocator) or_return
		buf[k] = make([]u64, most, context.temp_allocator) or_return
	}
	cur := split_into(revisions[0].data, offs[0])
	cur_tags := buf[0][:line_count(cur)]
	for &t in cur_tags {
		t = revisions[0].tag
	}
	for r, i in revisions[1:] {
		k := (i + 1) & 1
		next := split_into(r.data, offs[k])
		next_tags := buf[k][:line_count(next)]
		{
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			edits := diff_lines(cur, next, DEFAULT_DIFF, context.temp_allocator) or_return
			carry_tags(cur_tags, edits, r.tag, next_tags)
		}
		cur, cur_tags = next, next_tags
	}
	tags = make([]u64, len(cur_tags), allocator) or_return
	copy(tags, cur_tags)
	return tags, nil
}

@(private)
split_into :: proc "contextless" (data: []u8, buf: []u32) -> Lines {
	n := count_newlines(data)
	if len(data) > 0 && data[len(data) - 1] != '\n' {
		n += 1
	}
	offs := buf[:n + 1]
	fill_offsets(data, offs)
	return Lines{data, offs}
}

@(private)
carry_tags :: proc "contextless" (prev: []u64, edits: []Edit, tag: u64, out: []u64) {
	i, j := 0, 0
	for e in edits {
		for ; j < int(e.b_start); j += 1 {
			out[j] = prev[i]
			i += 1
		}
		for ; j < int(e.b_start + e.b_len); j += 1 {
			out[j] = tag
		}
		i += int(e.a_len)
	}
	for ; j < len(out); j += 1 {
		out[j] = prev[i]
		i += 1
	}
}

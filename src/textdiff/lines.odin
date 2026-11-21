package textdiff

import "base:intrinsics"
import "base:runtime"
import "core:bytes"
import "core:simd"

MAX_BYTES :: 1 << 30
BINARY_SNIFF_BYTES :: 8000

Input_Error :: enum u8 {
	None,
	Too_Large,
	Tag_Count_Mismatch,
}

Error :: union #shared_nil {
	Input_Error,
	runtime.Allocator_Error,
}

Lines :: struct {
	data: []u8,
	offs: []u32,
}

line_count :: #force_inline proc "contextless" (l: Lines) -> int {
	return max(len(l.offs) - 1, 0)
}

line :: #force_inline proc "contextless" (l: Lines, i: int) -> []u8 {
	return l.data[l.offs[i]:l.offs[i + 1]]
}

lines_bytes :: #force_inline proc "contextless" (l: Lines, start, count: int) -> []u8 {
	return l.data[l.offs[start]:l.offs[start + count]]
}

is_binary :: proc "contextless" (data: []u8) -> bool {
	return bytes.index_byte(data[:min(len(data), BINARY_SNIFF_BYTES)], 0) >= 0
}

split_lines :: proc(data: []u8, allocator := context.allocator) -> (l: Lines, err: Error) {
	if len(data) > MAX_BYTES {
		return {}, .Too_Large
	}
	n := count_newlines(data)
	if len(data) > 0 && data[len(data) - 1] != '\n' {
		n += 1
	}
	offs := make([]u32, n + 1, allocator) or_return
	fill_offsets(data, offs)
	return Lines{data, offs}, nil
}

@(private)
newline_mask :: #force_inline proc "contextless" (p: [^]u8) -> u32 {
	nl: simd.u8x32 = '\n'
	v := intrinsics.unaligned_load((^simd.u8x32)(p))
	return transmute(u32)simd.extract_msbs(simd.lanes_eq(v, nl))
}

@(private)
count_newlines :: proc "contextless" (data: []u8) -> int {
	n, i := 0, 0
	p := raw_data(data)
	for ; i + 32 <= len(data); i += 32 {
		n += int(intrinsics.count_ones(newline_mask(p[i:])))
	}
	for ; i < len(data); i += 1 {
		if data[i] == '\n' {
			n += 1
		}
	}
	return n
}

@(private)
fill_offsets :: proc "contextless" (data: []u8, offs: []u32) {
	offs[0] = 0
	j, i := 1, 0
	p := raw_data(data)
	for ; i + 32 <= len(data); i += 32 {
		m := newline_mask(p[i:])
		for m != 0 {
			offs[j] = u32(i + int(intrinsics.count_trailing_zeros(m)) + 1)
			j += 1
			m &= m - 1
		}
	}
	for ; i < len(data); i += 1 {
		if data[i] == '\n' {
			offs[j] = u32(i + 1)
			j += 1
		}
	}
	offs[len(offs) - 1] = u32(len(data))
}

@(private)
equal_bytes :: #force_inline proc "contextless" (a, b: []u8) -> bool {
	return len(a) == len(b) && runtime.memory_equal(raw_data(a), raw_data(b), len(a))
}

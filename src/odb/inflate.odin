package odb

import "base:intrinsics"
import hashing "core:hash"
import "core:io"

@(private)
FAST_BITS :: 9

@(private)
FAST_MASK :: (1 << FAST_BITS) - 1

@(private)
WINDOW_SIZE :: 32 * 1024

@(private)
STREAM_BUFFER_SIZE :: WINDOW_SIZE + 64 * 1024

@(private)
Huffman :: struct {
	fast:         [1 << FAST_BITS]u16,
	first_code:   [16]u16,
	first_symbol: [16]u16,
	max_code:     [17]u32,
	size:         [288]u8,
	value:        [288]u16,
}

@(private)
Refill_Proc :: #type proc(data: rawptr) -> ([]u8, Error)

@(private)
Inflate_Status :: enum u8 {
	Done,
	Full,
}

@(private)
Inflater :: struct {
	src:         []u8,
	pos:         int,
	refill:      Refill_Proc,
	refill_data: rawptr,
	bits:        u64,
	nbits:       uint,
	pad:         int,
	out:         []u8,
	out_pos:     int,
	mark:        int,
	sink:        Maybe(io.Writer),
	limit:       i64,
	total:       i64,
	adler:       u32,
	err:         Error,
	lit:         Huffman,
	dist:        Huffman,
	codes:       Huffman,
}

@(private, rodata)
LENGTH_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}

@(private, rodata)
LENGTH_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}

@(private, rodata)
DIST_BASE := [30]u16 {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
	1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}

@(private, rodata)
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private, rodata)
CODE_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

@(private)
reverse_bits :: #force_inline proc "contextless" (v: u32, n: uint) -> u32 {
	return intrinsics.reverse_bits(v) >> (32 - n)
}

@(private)
huffman_build :: proc(h: ^Huffman, lengths: []u8) -> bool {
	counts: [16]int
	for l in lengths {
		if l > 15 {
			return false
		}
		counts[l] += 1
	}
	counts[0] = 0
	h.fast = {}
	next_code: [16]int
	code, k := 0, 0
	for i in 1 ..< 16 {
		if counts[i] > 1 << uint(i) {
			return false
		}
		next_code[i] = code
		h.first_code[i] = u16(code)
		h.first_symbol[i] = u16(k)
		code += counts[i]
		if counts[i] != 0 && code - 1 >= 1 << uint(i) {
			return false
		}
		h.max_code[i] = u32(code) << uint(16 - i)
		code <<= 1
		k += counts[i]
	}
	h.max_code[16] = 0x10000
	for l, sym in lengths {
		if l == 0 {
			continue
		}
		c := next_code[l] - int(h.first_code[l]) + int(h.first_symbol[l])
		h.size[c] = l
		h.value[c] = u16(sym)
		if l <= FAST_BITS {
			j := int(reverse_bits(u32(next_code[l]), uint(l)))
			for j < 1 << FAST_BITS {
				h.fast[j] = u16(l) << 9 | u16(sym)
				j += 1 << l
			}
		}
		next_code[l] += 1
	}
	return true
}

@(private)
inflate_next_chunk :: proc(s: ^Inflater) -> bool {
	if s.refill == nil || s.err != .None {
		return false
	}
	chunk, err := s.refill(s.refill_data)
	if err != .None {
		s.err = err
		return false
	}
	if len(chunk) == 0 {
		return false
	}
	s.src = chunk
	s.pos = 0
	return true
}

@(private)
inflate_fill :: proc(s: ^Inflater) #no_bounds_check {
	for s.nbits <= 56 {
		if s.pos + 8 <= len(s.src) {
			v := intrinsics.unaligned_load((^u64le)(&s.src[s.pos]))
			s.bits |= u64(v) << s.nbits
			used := (63 - s.nbits) >> 3
			s.pos += int(used)
			s.nbits += used * 8
			return
		}
		if s.pos < len(s.src) {
			s.bits |= u64(s.src[s.pos]) << s.nbits
			s.pos += 1
			s.nbits += 8
			continue
		}
		if inflate_next_chunk(s) {
			continue
		}
		s.pad += 1
		s.nbits += 8
	}
}

@(private)
inflate_bits :: #force_inline proc(s: ^Inflater, n: uint) -> u32 {
	if s.nbits < n {
		inflate_fill(s)
	}
	v := u32(s.bits & ((u64(1) << n) - 1))
	s.bits >>= n
	s.nbits -= n
	return v
}

@(private)
inflate_overrun :: #force_inline proc(s: ^Inflater) -> bool {
	return s.pad > 0 && uint(s.pad) * 8 > s.nbits
}

@(private)
inflate_decode :: proc(s: ^Inflater, h: ^Huffman) -> int #no_bounds_check {
	if s.nbits < 16 {
		inflate_fill(s)
	}
	f := h.fast[s.bits & FAST_MASK]
	if f != 0 {
		n := uint(f >> 9)
		s.bits >>= n
		s.nbits -= n
		return int(f & 511)
	}
	k := reverse_bits(u32(s.bits & 0xffff), 16)
	l := uint(FAST_BITS + 1)
	for k >= h.max_code[l] {
		l += 1
	}
	if l >= 16 {
		return -1
	}
	c := int(k >> (16 - l)) - int(h.first_code[l]) + int(h.first_symbol[l])
	if c < 0 || c >= 288 || uint(h.size[c]) != l {
		return -1
	}
	s.bits >>= l
	s.nbits -= l
	return int(h.value[c])
}

@(private)
inflate_flush :: proc(s: ^Inflater) -> bool {
	w, ok := s.sink.?
	if !ok {
		return false
	}
	chunk := s.out[s.mark:s.out_pos]
	if s.limit >= 0 && s.total + i64(len(chunk)) > s.limit {
		s.err = .Corrupt
		return false
	}
	if len(chunk) > 0 {
		s.adler = hashing.adler32(chunk, s.adler)
		if _, werr := io.write_full(w, chunk); werr != nil {
			s.err = .Io
			return false
		}
		s.total += i64(len(chunk))
	}
	keep := min(s.out_pos, WINDOW_SIZE)
	copy(s.out[:keep], s.out[s.out_pos - keep:s.out_pos])
	s.out_pos = keep
	s.mark = keep
	return true
}

@(private)
inflate_stored :: proc(s: ^Inflater) -> (status: Inflate_Status, err: Error) {
	drop := s.nbits & 7
	s.bits >>= drop
	s.nbits -= drop
	length := inflate_bits(s, 16)
	nlength := inflate_bits(s, 16)
	if inflate_overrun(s) {
		return .Done, .Corrupt
	}
	if length != ~nlength & 0xffff {
		return .Done, .Corrupt
	}
	remaining := int(length)
	for remaining > 0 && s.nbits >= 8 {
		if s.out_pos >= len(s.out) && !inflate_flush(s) {
			return .Full, s.err
		}
		if s.nbits <= uint(s.pad) * 8 {
			return .Done, .Corrupt
		}
		s.out[s.out_pos] = u8(s.bits)
		s.out_pos += 1
		s.bits >>= 8
		s.nbits -= 8
		remaining -= 1
	}
	if s.nbits == 0 {
		s.bits = 0
	}
	for remaining > 0 {
		if s.pos >= len(s.src) {
			if !inflate_next_chunk(s) {
				return .Done, s.err if s.err != .None else .Corrupt
			}
		}
		if s.out_pos >= len(s.out) && !inflate_flush(s) {
			return .Full, s.err
		}
		n := min(remaining, len(s.src) - s.pos, len(s.out) - s.out_pos)
		copy(s.out[s.out_pos:], s.src[s.pos:s.pos + n])
		s.out_pos += n
		s.pos += n
		remaining -= n
	}
	return .Done, .None
}

@(private)
inflate_dynamic_tables :: proc(s: ^Inflater) -> bool {
	hlit := int(inflate_bits(s, 5)) + 257
	hdist := int(inflate_bits(s, 5)) + 1
	hclen := int(inflate_bits(s, 4)) + 4
	if hlit > 286 || hdist > 30 {
		return false
	}
	code_lengths: [19]u8
	for i in 0 ..< hclen {
		code_lengths[CODE_ORDER[i]] = u8(inflate_bits(s, 3))
	}
	if inflate_overrun(s) || !huffman_build(&s.codes, code_lengths[:]) {
		return false
	}
	lengths: [286 + 30]u8
	total := hlit + hdist
	n := 0
	for n < total {
		sym := inflate_decode(s, &s.codes)
		if sym < 0 || inflate_overrun(s) {
			return false
		}
		switch sym {
		case 0 ..= 15:
			lengths[n] = u8(sym)
			n += 1
		case 16:
			if n == 0 {
				return false
			}
			prev := lengths[n - 1]
			rep := 3 + int(inflate_bits(s, 2))
			if n + rep > total {
				return false
			}
			for _ in 0 ..< rep {
				lengths[n] = prev
				n += 1
			}
		case 17, 18:
			rep := 3 + int(inflate_bits(s, 3)) if sym == 17 else 11 + int(inflate_bits(s, 7))
			if n + rep > total {
				return false
			}
			for _ in 0 ..< rep {
				lengths[n] = 0
				n += 1
			}
		case:
			return false
		}
	}
	if lengths[256] == 0 {
		return false
	}
	return huffman_build(&s.lit, lengths[:hlit]) && huffman_build(&s.dist, lengths[hlit:total])
}

@(private)
inflate_fixed_tables :: proc(s: ^Inflater) {
	lengths: [288]u8
	for i in 0 ..< 144 {
		lengths[i] = 8
	}
	for i in 144 ..< 256 {
		lengths[i] = 9
	}
	for i in 256 ..< 280 {
		lengths[i] = 7
	}
	for i in 280 ..< 288 {
		lengths[i] = 8
	}
	huffman_build(&s.lit, lengths[:])
	dist: [30]u8
	for i in 0 ..< 30 {
		dist[i] = 5
	}
	huffman_build(&s.dist, dist[:])
}

@(private)
inflate_codes :: proc(s: ^Inflater) -> (status: Inflate_Status, err: Error) #no_bounds_check {
	for {
		if s.pad > 8 {
			return .Done, .Corrupt
		}
		sym := inflate_decode(s, &s.lit)
		switch {
		case sym < 0:
			return .Done, .Corrupt
		case sym < 256:
			if s.out_pos >= len(s.out) && !inflate_flush(s) {
				return .Full, s.err
			}
			s.out[s.out_pos] = u8(sym)
			s.out_pos += 1
		case sym == 256:
			return .Done, .None
		case:
			idx := sym - 257
			if idx >= 29 {
				return .Done, .Corrupt
			}
			length := int(LENGTH_BASE[idx]) + int(inflate_bits(s, uint(LENGTH_EXTRA[idx])))
			dsym := inflate_decode(s, &s.dist)
			if dsym < 0 || dsym >= 30 {
				return .Done, .Corrupt
			}
			dist := int(DIST_BASE[dsym]) + int(inflate_bits(s, uint(DIST_EXTRA[dsym])))
			if s.out_pos + length > len(s.out) && !inflate_flush(s) {
				if s.err != .None {
					return .Done, s.err
				}
				if dist > s.out_pos {
					return .Done, .Corrupt
				}
				for s.out_pos < len(s.out) {
					s.out[s.out_pos] = s.out[s.out_pos - dist]
					s.out_pos += 1
				}
				return .Full, .None
			}
			if dist > s.out_pos {
				return .Done, .Corrupt
			}
			from := s.out_pos - dist
			if dist >= length {
				copy(s.out[s.out_pos:s.out_pos + length], s.out[from:from + length])
				s.out_pos += length
			} else {
				for _ in 0 ..< length {
					s.out[s.out_pos] = s.out[from]
					s.out_pos += 1
					from += 1
				}
			}
		}
	}
}

@(private)
inflate_run :: proc(s: ^Inflater) -> (status: Inflate_Status, err: Error) {
	s.adler = 1
	cmf := inflate_bits(s, 8)
	flg := inflate_bits(s, 8)
	if inflate_overrun(s) || cmf & 0x0f != 8 || cmf >> 4 > 7 || flg & 0x20 != 0 || (cmf << 8 | flg) % 31 != 0 {
		return .Done, .Corrupt
	}
	for {
		final := inflate_bits(s, 1)
		type := inflate_bits(s, 2)
		if inflate_overrun(s) {
			return .Done, .Corrupt
		}
		switch type {
		case 0:
			status = inflate_stored(s) or_return
		case 1:
			inflate_fixed_tables(s)
			status = inflate_codes(s) or_return
		case 2:
			if !inflate_dynamic_tables(s) {
				return .Done, s.err if s.err != .None else .Corrupt
			}
			status = inflate_codes(s) or_return
		case:
			return .Done, .Corrupt
		}
		if status == .Full {
			return .Full, .None
		}
		if inflate_overrun(s) {
			return .Done, s.err if s.err != .None else .Corrupt
		}
		if final == 1 {
			break
		}
	}
	drop := s.nbits & 7
	s.bits >>= drop
	s.nbits -= drop
	expected: u32
	for _ in 0 ..< 4 {
		expected = expected << 8 | inflate_bits(s, 8)
	}
	if inflate_overrun(s) {
		return .Done, s.err if s.err != .None else .Corrupt
	}
	if _, streaming := s.sink.?; streaming {
		if !inflate_flush(s) {
			return .Done, s.err if s.err != .None else .Io
		}
		if s.limit >= 0 && s.total != s.limit {
			return .Done, .Corrupt
		}
	} else {
		s.adler = hashing.adler32(s.out[:s.out_pos], 1)
	}
	if s.adler != expected {
		return .Done, .Corrupt
	}
	return .Done, .None
}

@(private)
inflate_prefix :: proc(src: []u8, out: []u8, refill: Refill_Proc = nil, refill_data: rawptr = nil) -> (n: int, err: Error) {
	s: Inflater
	s.src = src
	s.refill = refill
	s.refill_data = refill_data
	s.out = out
	s.limit = -1
	_, err = inflate_run(&s)
	return s.out_pos, err
}

@(private)
inflate_exact :: proc(src: []u8, out: []u8, refill: Refill_Proc = nil, refill_data: rawptr = nil) -> Error {
	s: Inflater
	s.src = src
	s.refill = refill
	s.refill_data = refill_data
	s.out = out
	s.limit = -1
	status, err := inflate_run(&s)
	if err != .None {
		return err
	}
	return .None if status == .Done && s.out_pos == len(out) else .Corrupt
}

@(private)
inflate_to_writer :: proc(src: []u8, refill: Refill_Proc, refill_data: rawptr, w: io.Writer, limit: i64, window: []u8) -> (total: i64, err: Error) {
	s: Inflater
	s.src = src
	s.refill = refill
	s.refill_data = refill_data
	s.out = window
	s.sink = w
	s.limit = limit
	_, err = inflate_run(&s)
	return s.total, err
}

@(private)
inflate_plausible :: proc "contextless" (size: i64, compressed: int) -> bool {
	return size <= i64(compressed) * 1032 + 1024
}

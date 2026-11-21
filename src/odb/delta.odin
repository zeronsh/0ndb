package odb

import "base:runtime"

@(private)
DELTA_BLOCK :: 16

@(private)
DELTA_PRIME :: u32(0x01000193)

@(private)
DELTA_PROBES :: 4

@(private)
Delta_Index :: struct {
	src:   []u8,
	table: []u32,
	mask:  u32,
	pow:   u32,
}

@(private)
delta_hash_block :: #force_inline proc "contextless" (p: []u8) -> u32 #no_bounds_check {
	h: u32
	for i in 0 ..< DELTA_BLOCK {
		h = h * DELTA_PRIME + u32(p[i])
	}
	return h
}

@(private)
delta_slot :: #force_inline proc "contextless" (h: u32, mask: u32) -> u32 {
	return (h * 0x9e3779b1) >> 7 & mask
}

@(private)
delta_index_init :: proc(idx: ^Delta_Index, src: []u8, allocator: runtime.Allocator) -> Error {
	idx^ = {src = src}
	pow := u32(1)
	for _ in 0 ..< DELTA_BLOCK - 1 {
		pow *= DELTA_PRIME
	}
	idx.pow = pow
	blocks := len(src) / DELTA_BLOCK
	if blocks == 0 {
		return .None
	}
	size := 64
	for size < blocks * 2 {
		size <<= 1
	}
	table, err := make([]u32, size, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	idx.table = table
	idx.mask = u32(size - 1)
	for b := blocks - 1; b >= 0; b -= 1 {
		off := b * DELTA_BLOCK
		slot := delta_slot(delta_hash_block(src[off:]), idx.mask)
		for _ in 0 ..< DELTA_PROBES {
			if table[slot] == 0 {
				table[slot] = u32(off + 1)
				break
			}
			slot = (slot + 1) & idx.mask
		}
	}
	return .None
}

@(private)
delta_index_destroy :: proc(idx: ^Delta_Index, allocator: runtime.Allocator) {
	delete(idx.table, allocator)
	idx^ = {}
}

@(private)
delta_put_varint :: proc(out: ^[dynamic]u8, v: int) {
	v := u64(v)
	for v >= 0x80 {
		append(out, u8(v) | 0x80)
		v >>= 7
	}
	append(out, u8(v))
}

@(private)
delta_flush_literal :: proc(out: ^[dynamic]u8, lit: []u8) {
	lit := lit
	for len(lit) > 0 {
		n := min(len(lit), 127)
		append(out, u8(n))
		append(out, ..lit[:n])
		lit = lit[n:]
	}
}

@(private)
delta_put_copy :: proc(out: ^[dynamic]u8, offset, size: int) {
	off := offset
	size := size
	for size > 0 {
		n := min(size, 0xffffff)
		hdr: [8]u8
		k := 1
		cmd: u8 = 0x80
		for i in uint(0) ..< 4 {
			b := u8(off >> (8 * i))
			if b != 0 {
				cmd |= 1 << i
				hdr[k] = b
				k += 1
			}
		}
		for i in uint(0) ..< 3 {
			b := u8(n >> (8 * i))
			if b != 0 {
				cmd |= 0x10 << i
				hdr[k] = b
				k += 1
			}
		}
		hdr[0] = cmd
		append(out, ..hdr[:k])
		off += n
		size -= n
	}
}

@(private)
delta_create :: proc(idx: ^Delta_Index, target: []u8, max_size: int, out: ^[dynamic]u8) -> bool #no_bounds_check {
	clear(out)
	src := idx.src
	if max_size <= 0 || len(src) >= 1 << 32 {
		return false
	}
	delta_put_varint(out, len(src))
	delta_put_varint(out, len(target))
	if idx.table == nil || len(target) < DELTA_BLOCK {
		delta_flush_literal(out, target)
		return len(out) <= max_size
	}
	pos := 0
	lit := 0
	h := delta_hash_block(target)
	for pos + DELTA_BLOCK <= len(target) {
		best_len, best_off := 0, 0
		slot := delta_slot(h, idx.mask)
		for _ in 0 ..< DELTA_PROBES {
			cand := int(idx.table[slot])
			if cand == 0 {
				break
			}
			cand -= 1
			l := 0
			limit := min(len(src) - cand, len(target) - pos)
			for l < limit && src[cand + l] == target[pos + l] {
				l += 1
			}
			if l > best_len {
				best_len, best_off = l, cand
			}
			slot = (slot + 1) & idx.mask
		}
		if best_len >= DELTA_BLOCK {
			for pos > lit && best_off > 0 && src[best_off - 1] == target[pos - 1] {
				pos -= 1
				best_off -= 1
				best_len += 1
			}
			delta_flush_literal(out, target[lit:pos])
			delta_put_copy(out, best_off, best_len)
			pos += best_len
			lit = pos
			if len(out) > max_size {
				return false
			}
			if pos + DELTA_BLOCK <= len(target) {
				h = delta_hash_block(target[pos:])
			}
			continue
		}
		if pos + DELTA_BLOCK < len(target) {
			h = (h - u32(target[pos]) * idx.pow) * DELTA_PRIME + u32(target[pos + DELTA_BLOCK])
		}
		pos += 1
		if pos - lit > max_size {
			return false
		}
	}
	delta_flush_literal(out, target[lit:])
	return len(out) <= max_size
}

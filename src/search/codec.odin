package search

import "base:intrinsics"
import "base:runtime"
import "../prim"

BLOCK :: 128

uv :: proc "contextless" (data: []u8, pos: ^int) -> (v: u64, ok: bool) {
	x, n := prim.get_uvarint(data[pos^:])
	if n <= 0 {
		return 0, false
	}
	pos^ += n
	return x, true
}

uv32 :: proc "contextless" (data: []u8, pos: ^int) -> (v: u32, ok: bool) {
	x := uv(data, pos) or_return
	if x > u64(max(u32)) {
		return 0, false
	}
	return u32(x), true
}

bits_of :: proc "contextless" (v: u32) -> int {
	return 32 - int(intrinsics.count_leading_zeros(v))
}

pfor_encode :: proc(w: ^prim.Writer, ids: []u32) {
	n := len(ids)
	prim.write_u8(w, u8(n - 1))
	if n <= 1 {
		return
	}
	m := n - 1
	gaps: [BLOCK]u32
	hist: [33]int
	for i in 1 ..< n {
		g := ids[i] - ids[i - 1] - 1
		gaps[i - 1] = g
		hist[bits_of(g)] += 1
	}
	best_b, best_cost := 32, max(int)
	for b in 0 ..= 32 {
		cost := (m * b + 7) / 8
		exc := 0
		for k in b + 1 ..= 32 {
			if hist[k] == 0 {
				continue
			}
			exc += hist[k]
			cost += hist[k] * (1 + (k - b + 6) / 7)
		}
		if exc > 0 {
			cost += 1
		}
		if cost < best_cost {
			best_b, best_cost = b, cost
		}
	}
	b := best_b
	exc := 0
	for k in b + 1 ..= 32 {
		exc += hist[k]
	}
	prim.write_u8(w, u8(b) | (0x80 if exc > 0 else 0))
	packed: [BLOCK * 4 + 8]u8
	nbytes := (m * b + 7) / 8
	if b > 0 {
		mask := u64(1) << u64(b) - 1
		acc: u64
		have: u64
		o := 0
		for i in 0 ..< m {
			acc |= (u64(gaps[i]) & mask) << have
			have += u64(b)
			for have >= 8 {
				packed[o] = u8(acc)
				o += 1
				acc >>= 8
				have -= 8
			}
		}
		if have > 0 {
			packed[o] = u8(acc)
		}
		prim.write_raw(w, packed[:nbytes])
	}
	if exc > 0 {
		prim.write_u8(w, u8(exc))
		for i in 0 ..< m {
			if bits_of(gaps[i]) > b {
				prim.write_u8(w, u8(i))
				prim.write_uvarint(w, u64(gaps[i]) >> u64(b))
			}
		}
	}
}

pfor_decode :: proc "contextless" (data: []u8, first: u32, out: ^[BLOCK]u32) -> (n: int, used: int, ok: bool) #no_bounds_check {
	if len(data) < 1 {
		return 0, 0, false
	}
	n = int(data[0]) + 1
	out[0] = first
	if n == 1 {
		return 1, 1, true
	}
	if len(data) < 2 {
		return 0, 0, false
	}
	m := n - 1
	b := int(data[1] & 0x7f)
	has_exc := data[1] & 0x80 != 0
	if b > 32 {
		return 0, 0, false
	}
	pos := 2
	nbytes := (m * b + 7) / 8
	if len(data) - pos < nbytes {
		return 0, 0, false
	}
	gaps: [BLOCK]u64
	packed := data[pos:][:nbytes]
	if b == 0 {
		for i in 0 ..< m {
			gaps[i] = 0
		}
	} else {
		mask := u64(1) << u64(b) - 1
		for i in 0 ..< m {
			bit := i * b
			byte_i := bit >> 3
			shift := u64(bit & 7)
			word: u64
			if byte_i + 8 <= nbytes {
				word = u64(intrinsics.unaligned_load((^u64le)(&packed[byte_i])))
			} else {
				for k in 0 ..< 8 {
					if byte_i + k < nbytes {
						word |= u64(packed[byte_i + k]) << u64(8 * k)
					}
				}
			}
			gaps[i] = (word >> shift) & mask
		}
	}
	pos += nbytes
	if has_exc {
		if pos >= len(data) {
			return 0, 0, false
		}
		cnt := int(data[pos])
		pos += 1
		for _ in 0 ..< cnt {
			if pos >= len(data) {
				return 0, 0, false
			}
			idx := int(data[pos])
			pos += 1
			if idx >= m {
				return 0, 0, false
			}
			hi, hok := uv(data, &pos)
			if !hok || hi > u64(max(u32)) {
				return 0, 0, false
			}
			gaps[idx] |= hi << u64(b)
		}
	}
	acc := u64(first)
	for i in 0 ..< m {
		acc += gaps[i] + 1
		if acc > u64(max(u32)) {
			return 0, 0, false
		}
		out[i + 1] = u32(acc)
	}
	return n, pos, true
}

grow :: proc(b: ^[dynamic]$T, n: int) -> runtime.Allocator_Error {
	if n > cap(b) {
		reserve(b, max(n, 2 * cap(b))) or_return
	}
	return resize(b, n)
}

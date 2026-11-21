package search

import "base:intrinsics"
import "base:runtime"
import "../prim"

BLOCK :: 128
LZ_MIN :: 4
LZ_HASH_BITS :: 14
LZ_MAX_OFF :: 65535

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

lz_compress :: proc(w: ^prim.Writer, src: []u8, table: ^[1 << LZ_HASH_BITS]i32) #no_bounds_check {
	for &t in table {
		t = -1
	}
	n := len(src)
	anchor := 0
	i := 0
	limit := n - 8
	step_count := 0
	for i < limit {
		seq := intrinsics.unaligned_load((^u32le)(&src[i]))
		h := (u32(seq) * 2654435761) >> (32 - LZ_HASH_BITS)
		cand := int(table[h])
		table[h] = i32(i)
		if cand < 0 || i - cand > LZ_MAX_OFF || intrinsics.unaligned_load((^u32le)(&src[cand])) != seq {
			step_count += 1
			i += 1 + (step_count >> 6)
			continue
		}
		step_count = 0
		for i > anchor && cand > 0 && src[i - 1] == src[cand - 1] {
			i -= 1
			cand -= 1
		}
		mlen := LZ_MIN
		for i + mlen < n - 5 && src[i + mlen] == src[cand + mlen] {
			mlen += 1
		}
		_lz_sequence(w, src[anchor:i], i - cand, mlen)
		i += mlen
		anchor = i
		if i < limit {
			s2 := intrinsics.unaligned_load((^u32le)(&src[i - 2]))
			table[(u32(s2) * 2654435761) >> (32 - LZ_HASH_BITS)] = i32(i - 2)
		}
	}
	_lz_sequence(w, src[anchor:], 0, 0)
}

@(private)
_lz_sequence :: proc(w: ^prim.Writer, lit: []u8, off: int, mlen: int) {
	ll := len(lit)
	ml := mlen - LZ_MIN if mlen > 0 else 0
	token := u8(min(ll, 15)) << 4 | u8(min(ml, 15))
	prim.write_u8(w, token)
	if ll >= 15 {
		_lz_len(w, ll - 15)
	}
	prim.write_raw(w, lit)
	if mlen == 0 {
		return
	}
	prim.write_u8(w, u8(off))
	prim.write_u8(w, u8(off >> 8))
	if ml >= 15 {
		_lz_len(w, ml - 15)
	}
}

@(private)
_lz_len :: proc(w: ^prim.Writer, v: int) {
	x := v
	for x >= 255 {
		prim.write_u8(w, 255)
		x -= 255
	}
	prim.write_u8(w, u8(x))
}

lz_decompress :: proc "contextless" (dst: []u8, src: []u8) -> bool #no_bounds_check {
	ip, op := 0, 0
	for ip < len(src) {
		token := src[ip]
		ip += 1
		ll := int(token >> 4)
		if ll == 15 {
			for {
				if ip >= len(src) {
					return false
				}
				c := src[ip]
				ip += 1
				ll += int(c)
				if ll > len(dst) {
					return false
				}
				if c != 255 {
					break
				}
			}
		}
		if ll > len(src) - ip || ll > len(dst) - op {
			return false
		}
		copy(dst[op:][:ll], src[ip:][:ll])
		ip += ll
		op += ll
		if ip == len(src) {
			return op == len(dst) && token & 0x0f == 0
		}
		if len(src) - ip < 2 {
			return false
		}
		off := int(src[ip]) | int(src[ip + 1]) << 8
		ip += 2
		ml := int(token & 0x0f)
		if ml == 15 {
			for {
				if ip >= len(src) {
					return false
				}
				c := src[ip]
				ip += 1
				ml += int(c)
				if ml > len(dst) {
					return false
				}
				if c != 255 {
					break
				}
			}
		}
		ml += LZ_MIN
		if off == 0 || off > op || ml > len(dst) - op {
			return false
		}
		from := op - off
		if off >= ml {
			copy(dst[op:][:ml], dst[from:][:ml])
		} else {
			for k in 0 ..< ml {
				dst[op + k] = dst[from + k]
			}
		}
		op += ml
	}
	return op == len(dst)
}

grow :: proc(b: ^[dynamic]$T, n: int) -> runtime.Allocator_Error {
	if n > cap(b) {
		reserve(b, max(n, 2 * cap(b))) or_return
	}
	return resize(b, n)
}

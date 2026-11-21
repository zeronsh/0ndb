package sim

import "../../src/prim"

Rng :: struct {
	s: [4]u64,
}

splitmix :: proc "contextless" (x: ^u64) -> u64 {
	x^ += 0x9e3779b97f4a7c15
	z := x^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

rng_init :: proc "contextless" (r: ^Rng, seed: u64, stream: u64 = 0) {
	x := seed ~ (stream * 0xd1b54a32d192ed03)
	for i in 0 ..< 4 {
		r.s[i] = splitmix(&x)
	}
	if r.s == {} {
		r.s[0] = 1
	}
}

rng_fork :: proc "contextless" (r: ^Rng, stream: u64) -> (out: Rng) {
	rng_init(&out, rng_u64(r), stream)
	return
}

rotl :: #force_inline proc "contextless" (x: u64, k: u64) -> u64 {
	return (x << k) | (x >> (64 - k))
}

rng_u64 :: proc "contextless" (r: ^Rng) -> u64 {
	res := rotl(r.s[1] * 5, 7) * 9
	t := r.s[1] << 17
	r.s[2] ~= r.s[0]
	r.s[3] ~= r.s[1]
	r.s[1] ~= r.s[2]
	r.s[0] ~= r.s[3]
	r.s[2] ~= t
	r.s[3] = rotl(r.s[3], 45)
	return res
}

rng_below :: proc "contextless" (r: ^Rng, n: u64) -> u64 {
	if n <= 1 {
		return 0
	}
	threshold := (0 - n) % n
	for {
		x := rng_u64(r)
		hi, lo := mul_full(x, n)
		if lo >= threshold {
			return hi
		}
	}
}

mul_full :: proc "contextless" (a, b: u64) -> (hi, lo: u64) {
	p := u128(a) * u128(b)
	return u64(p >> 64), u64(p)
}

rng_int :: proc "contextless" (r: ^Rng, n: int) -> int {
	return int(rng_below(r, u64(max(n, 1))))
}

rng_range :: proc "contextless" (r: ^Rng, lo, hi: i64) -> i64 {
	if hi <= lo {
		return lo
	}
	return lo + i64(rng_below(r, u64(hi - lo + 1)))
}

rng_chance :: proc "contextless" (r: ^Rng, num: u64, den: u64) -> bool {
	return rng_below(r, den) < num
}

rng_fill :: proc "contextless" (r: ^Rng, out: []u8) {
	i := 0
	for i < len(out) {
		x := rng_u64(r)
		for k in 0 ..< 8 {
			if i >= len(out) {
				break
			}
			out[i] = u8(x >> (8 * u64(k)))
			i += 1
		}
	}
}

rng_pick :: proc "contextless" (r: ^Rng, weights: []int) -> int {
	total := 0
	for w in weights {
		total += max(w, 0)
	}
	if total == 0 {
		return 0
	}
	x := rng_int(r, total)
	for w, i in weights {
		if x < max(w, 0) {
			return i
		}
		x -= max(w, 0)
	}
	return len(weights) - 1
}

rng_random :: proc(r: ^Rng) -> prim.Random {
	return prim.Random{data = r, fill = proc(data: rawptr, out: []u8) {
		rng_fill((^Rng)(data), out)
	}}
}

mix64 :: proc "contextless" (h: u64, x: u64) -> u64 {
	v := h ~ x
	v = (v ~ (v >> 33)) * 0xff51afd7ed558ccd
	v = (v ~ (v >> 33)) * 0xc4ceb9fe1a85ec53
	return v ~ (v >> 33)
}

mix_bytes :: proc "contextless" (h: u64, b: []u8) -> u64 {
	v := mix64(h, u64(len(b)))
	i := 0
	for i + 8 <= len(b) {
		w := u64(b[i]) | u64(b[i + 1]) << 8 | u64(b[i + 2]) << 16 | u64(b[i + 3]) << 24 | u64(b[i + 4]) << 32 | u64(b[i + 5]) << 40 | u64(b[i + 6]) << 48 | u64(b[i + 7]) << 56
		v = mix64(v, w)
		i += 8
	}
	tail: u64
	for k in i ..< len(b) {
		tail |= u64(b[k]) << (8 * u64(k - i))
	}
	return mix64(v, tail ~ 0x5bd1e995)
}

mix_str :: proc "contextless" (h: u64, s: string) -> u64 {
	return mix_bytes(h, transmute([]u8)s)
}

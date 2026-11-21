package osync

import "core:crypto"
import "core:crypto/blake2b"

PAIRING_PREFIX :: "0ndb"

@(private)
PAIRING_VERSION :: 1
@(private)
B32 :: "0123456789abcdefghjkmnpqrstvwxyz"

pairing_encode :: proc(p: ^Pairing, allocator := context.allocator) -> (code: string, err: Error) {
	raw: [1 + 32 + 32 + 1 + MAX_ADDR + 4]u8
	defer crypto.zero_explicit(&raw, size_of(raw))
	raw[0] = PAIRING_VERSION
	n := 1
	n += copy(raw[n:], p.secret[:])
	n += copy(raw[n:], p.relay_public[:])
	raw[n] = u8(p.addr_len)
	n += 1
	n += copy(raw[n:], p.relay_addr[:p.addr_len])
	sum := _pair_check(raw[:n])
	n += copy(raw[n:], sum[:])
	out_len := len(PAIRING_PREFIX) + (n * 8 + 4) / 5
	out, aerr := make([]u8, out_len, allocator)
	if aerr != nil {
		return "", .No_Memory
	}
	k := copy(out, PAIRING_PREFIX)
	alphabet := B32
	acc: u32
	bits: u32
	for b in raw[:n] {
		acc = acc << 8 | u32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			out[k] = alphabet[(acc >> bits) & 31]
			k += 1
		}
	}
	if bits > 0 {
		out[k] = alphabet[(acc << (5 - bits)) & 31]
		k += 1
	}
	return string(out[:k]), .None
}

pairing_decode :: proc(code: string) -> (p: Pairing, err: Error) {
	norm: [len(PAIRING_PREFIX) + ((1 + 32 + 32 + 1 + MAX_ADDR + 4) * 8 + 4) / 5]u8
	defer crypto.zero_explicit(&norm, size_of(norm))
	m := 0
	for i in 0 ..< len(code) {
		c := code[i]
		switch c {
		case ' ', '\t', '\n', '\r', '-', '_':
			continue
		case 'A' ..= 'Z':
			c += 'a' - 'A'
		}
		switch c {
		case 'o':
			c = '0'
		case 'i', 'l':
			c = '1'
		}
		if m >= len(norm) {
			return {}, .Invalid
		}
		norm[m] = c
		m += 1
	}
	if m < len(PAIRING_PREFIX) || string(norm[:len(PAIRING_PREFIX)]) != "0ndb" {
		return {}, .Invalid
	}
	raw: [1 + 32 + 32 + 1 + MAX_ADDR + 4]u8
	defer crypto.zero_explicit(&raw, size_of(raw))
	n := 0
	acc: u32
	bits: u32
	for c in norm[len(PAIRING_PREFIX):m] {
		v := _b32_value(c)
		if v < 0 {
			return {}, .Invalid
		}
		acc = acc << 5 | u32(v)
		bits += 5
		if bits >= 8 {
			bits -= 8
			if n >= len(raw) {
				return {}, .Invalid
			}
			raw[n] = u8(acc >> bits)
			n += 1
		}
	}
	if bits >= 5 || acc & ((1 << bits) - 1) != 0 {
		return {}, .Invalid
	}
	if n < 1 + 32 + 32 + 1 + 4 || raw[0] != PAIRING_VERSION {
		return {}, .Invalid
	}
	alen := int(raw[65])
	if 66 + alen + 4 != n {
		return {}, .Invalid
	}
	sum := _pair_check(raw[:66 + alen])
	if !_ct_eq(sum[:], raw[66 + alen:n]) {
		return {}, .Corrupt
	}
	copy(p.secret[:], raw[1:33])
	copy(p.relay_public[:], raw[33:65])
	p.addr_len = copy(p.relay_addr[:], raw[66:66 + alen])
	return p, .None
}

@(private)
_pair_check :: proc(data: []u8) -> (sum: [4]u8) {
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, transmute([]u8)string("0ndb pairing"), 4)
	blake2b.update(&ctx, data)
	blake2b.final(&ctx, sum[:])
	return
}

@(private)
_b32_value :: proc "contextless" (c: u8) -> int {
	alphabet := B32
	for i in 0 ..< len(alphabet) {
		if alphabet[i] == c {
			return i
		}
	}
	return -1
}

@(private)
_ct_eq :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	d: u8
	for i in 0 ..< len(a) {
		d |= a[i] ~ b[i]
	}
	return d == 0
}

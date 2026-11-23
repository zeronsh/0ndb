package prim

import "base:runtime"
import "core:strings"

Id :: distinct [16]u8

ID_HEX_LEN :: 32

@(private = "file")
HEX_DIGITS :: "0123456789abcdef"

id_new :: proc(loc := #caller_location) -> Id {
	unrouted("an id without a Clock and Random", loc)
	ns := now_ns()
	ms := u64(ns / 1_000_000)
	sub := u64(ns % 1_000_000) * 4096 / 1_000_000
	id: Id
	runtime.rand_bytes(id[8:])
	for i in 0 ..< 6 {
		id[i] = u8(ms >> (8 * u64(5 - i)))
	}
	id[6] = 0x70 | u8(sub >> 8)
	id[7] = u8(sub)
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

id_is_zero :: proc "contextless" (id: Id) -> bool {
	return id == Id{}
}

id_time_ms :: proc "contextless" (id: Id) -> i64 {
	ms: u64
	for i in 0 ..< 6 {
		ms = ms << 8 | u64(id[i])
	}
	return i64(ms)
}

id_hex :: proc "contextless" (id: Id) -> (out: [ID_HEX_LEN]u8) {
	src := id
	hex_encode(out[:], src[:])
	return
}

id_string :: proc(id: Id, allocator := context.allocator) -> (string, runtime.Allocator_Error) #optional_allocator_error {
	h := id_hex(id)
	return strings.clone(string(h[:]), allocator)
}

id_parse :: proc "contextless" (s: string) -> (id: Id, ok: bool) {
	if len(s) != ID_HEX_LEN {
		return
	}
	ok = hex_decode(id[:], transmute([]u8)s)
	if !ok {
		id = {}
	}
	return
}

hex_encode :: proc "contextless" (dst: []u8, src: []u8) -> int {
	digits := HEX_DIGITS
	n := min(len(src), len(dst) / 2)
	for i in 0 ..< n {
		b := src[i]
		dst[2 * i] = digits[b >> 4]
		dst[2 * i + 1] = digits[b & 0xf]
	}
	return 2 * n
}

hex_decode :: proc "contextless" (dst: []u8, src: []u8) -> bool {
	if len(src) != 2 * len(dst) {
		return false
	}
	for i in 0 ..< len(dst) {
		hi, ok_hi := _hex_value(src[2 * i])
		lo, ok_lo := _hex_value(src[2 * i + 1])
		if !ok_hi || !ok_lo {
			return false
		}
		dst[i] = hi << 4 | lo
	}
	return true
}

@(private)
_hex_value :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

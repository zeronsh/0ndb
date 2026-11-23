package prim

import "core:crypto"

Random :: struct {
	data: rawptr,
	fill: proc(data: rawptr, out: []u8),
}

strict_sources: bool

unrouted :: proc(what: string, loc := #caller_location) {
	if strict_sources {
		panic(what, loc)
	}
}

random_fill :: proc(r: Random, out: []u8, loc := #caller_location) {
	if r.fill != nil {
		r.fill(r.data, out)
		return
	}
	unrouted("randomness without a Random source", loc)
	crypto.rand_bytes(out)
}

id_new_with :: proc(clock: Clock, r: Random) -> Id {
	ns := clock_wall_ns(clock)
	ms := u64(ns / 1_000_000)
	sub := u64(ns % 1_000_000) * 4096 / 1_000_000
	id: Id
	random_fill(r, id[8:])
	for i in 0 ..< 6 {
		id[i] = u8(ms >> (8 * u64(5 - i)))
	}
	id[6] = 0x70 | u8(sub >> 8)
	id[7] = u8(sub)
	id[8] = (id[8] & 0x3f) | 0x80
	return id
}

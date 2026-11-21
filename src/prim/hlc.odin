package prim

Hlc :: distinct u64

HLC_LOGICAL_MAX :: 0xffff

hlc_make :: proc "contextless" (ms: i64, logical: u16) -> Hlc {
	return Hlc(u64(ms) << 16 | u64(logical))
}

hlc_ms :: proc "contextless" (h: Hlc) -> i64 {
	return i64(u64(h) >> 16)
}

hlc_logical :: proc "contextless" (h: Hlc) -> u16 {
	return u16(u64(h) & 0xffff)
}

hlc_now :: proc "contextless" (clock: ^Hlc) -> Hlc {
	return hlc_tick(clock, now_ms())
}

hlc_tick :: proc "contextless" (clock: ^Hlc, wall_ms: i64) -> Hlc {
	last := clock^
	next: Hlc
	if wall_ms > hlc_ms(last) {
		next = hlc_make(wall_ms, 0)
	} else {
		next = _hlc_bump(last)
	}
	clock^ = next
	return next
}

hlc_observe :: proc "contextless" (clock: ^Hlc, remote: Hlc) -> Hlc {
	return hlc_observe_at(clock, remote, now_ms())
}

hlc_observe_at :: proc "contextless" (clock: ^Hlc, remote: Hlc, wall_ms: i64) -> Hlc {
	last := clock^
	top := max(last, remote)
	next: Hlc
	if wall_ms > hlc_ms(top) {
		next = hlc_make(wall_ms, 0)
	} else {
		next = _hlc_bump(top)
	}
	clock^ = next
	return next
}

@(private)
_hlc_bump :: proc "contextless" (h: Hlc) -> Hlc {
	if hlc_logical(h) == HLC_LOGICAL_MAX {
		return hlc_make(hlc_ms(h) + 1, 0)
	}
	return h + 1
}

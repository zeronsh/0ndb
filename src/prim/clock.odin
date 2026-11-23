package prim

Clock :: struct {
	data:    rawptr,
	mono_ns: proc(data: rawptr) -> i64,
	wall_ns: proc(data: rawptr) -> i64,
}

clock_mono_ns :: proc(c: Clock, loc := #caller_location) -> i64 {
	if c.mono_ns != nil {
		return c.mono_ns(c.data)
	}
	unrouted("a monotonic clock read without a Clock", loc)
	return mono_ns()
}

clock_wall_ns :: proc(c: Clock, loc := #caller_location) -> i64 {
	if c.wall_ns != nil {
		return c.wall_ns(c.data)
	}
	unrouted("a wall clock read without a Clock", loc)
	return now_ns()
}

clock_wall_ms :: proc(c: Clock, loc := #caller_location) -> i64 {
	return clock_wall_ns(c, loc) / 1_000_000
}

hlc_now_with :: proc(h: ^Hlc, c: Clock) -> Hlc {
	return hlc_tick(h, clock_wall_ms(c))
}

hlc_observe_with :: proc(h: ^Hlc, remote: Hlc, c: Clock) -> Hlc {
	return hlc_observe_at(h, remote, clock_wall_ms(c))
}

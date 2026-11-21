package prim

import "core:sys/posix"

now_ns :: proc "contextless" () -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.REALTIME, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}

now_ms :: proc "contextless" () -> i64 {
	return now_ns() / 1_000_000
}

mono_ns :: proc "contextless" () -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}

Clock :: struct {
	data:    rawptr,
	mono_ns: proc(data: rawptr) -> i64,
	wall_ns: proc(data: rawptr) -> i64,
}

clock_mono_ns :: proc(c: Clock) -> i64 {
	if c.mono_ns != nil {
		return c.mono_ns(c.data)
	}
	return mono_ns()
}

clock_wall_ns :: proc(c: Clock) -> i64 {
	if c.wall_ns != nil {
		return c.wall_ns(c.data)
	}
	return now_ns()
}

clock_wall_ms :: proc(c: Clock) -> i64 {
	return clock_wall_ns(c) / 1_000_000
}

hlc_now_with :: proc(h: ^Hlc, c: Clock) -> Hlc {
	return hlc_tick(h, clock_wall_ms(c))
}

hlc_observe_with :: proc(h: ^Hlc, remote: Hlc, c: Clock) -> Hlc {
	return hlc_observe_at(h, remote, clock_wall_ms(c))
}

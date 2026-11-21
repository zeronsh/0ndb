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

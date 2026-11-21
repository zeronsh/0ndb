#+build js
package prim

import "core:time"

now_ns :: proc "contextless" () -> i64 {
	return time.time_to_unix_nano(time.now())
}

now_ms :: proc "contextless" () -> i64 {
	return now_ns() / 1_000_000
}

mono_ns :: proc "contextless" () -> i64 {
	return i64(time.tick_now()._nsec)
}

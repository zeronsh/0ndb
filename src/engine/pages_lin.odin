#+build linux
package engine

import "core:sys/linux"

@(private)
_pages_discard :: proc(p: rawptr, n: int) {
	linux.madvise(p, uint(n), .DONTNEED)
}

@(private)
_pages_reuse :: proc(p: rawptr, n: int) {
}

@(private)
PAGES_DEFAULT :: false

#+build darwin
package engine

foreign import libc_pages "system:System.framework"

@(private)
@(default_calling_convention = "c")
foreign libc_pages {
	madvise :: proc(addr: rawptr, len: uint, advice: i32) -> i32 ---
}

@(private)
MADV_FREE_REUSABLE :: 7
@(private)
MADV_FREE_REUSE :: 8

@(private)
_pages_discard :: proc(p: rawptr, n: int) {
	madvise(p, uint(n), MADV_FREE_REUSABLE)
}

@(private)
_pages_reuse :: proc(p: rawptr, n: int) {
	madvise(p, uint(n), MADV_FREE_REUSE)
}

@(private)
PAGES_DEFAULT :: true

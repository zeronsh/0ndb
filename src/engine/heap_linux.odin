package engine

import "base:runtime"

foreign import libc "system:c"

@(private)
@(default_calling_convention = "c")
foreign libc {
	malloc_trim :: proc(pad: uint) -> i32 ---
}

@(private)
_heap_release :: proc(e: ^Engine) {
	if e.allocator.procedure == runtime.heap_allocator_proc {
		malloc_trim(0)
	}
}

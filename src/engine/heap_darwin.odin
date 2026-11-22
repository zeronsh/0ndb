package engine

import "base:runtime"

foreign import libc "system:System.framework"

@(private)
@(default_calling_convention = "c")
foreign libc {
	malloc_zone_pressure_relief :: proc(zone: rawptr, goal: uint) -> uint ---
}

@(private)
_heap_release :: proc(e: ^Engine) {
	if e.allocator.procedure == runtime.heap_allocator_proc {
		malloc_zone_pressure_relief(nil, 0)
	}
}

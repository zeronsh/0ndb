package engine

import "base:runtime"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32 {
	HeapCompact :: proc(heap: win.HANDLE, flags: u32) -> uint ---
}

@(private)
_heap_release :: proc(e: ^Engine) {
	if e.allocator.procedure == runtime.heap_allocator_proc {
		HeapCompact(win.GetProcessHeap(), 0)
	}
}

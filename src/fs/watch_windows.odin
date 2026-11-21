package fs

import win "core:sys/windows"
import "../prim"

foreign import kernel32 "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32 {
	HeapCompact :: proc(heap: win.HANDLE, flags: u32) -> uint ---
}

_Registry_Os :: struct {
	full: bool,
}

@(private)
_registry_os_init :: proc(reg: ^Registry) -> Error {
	return .Unsupported
}

@(private)
_registry_os_destroy :: proc(reg: ^Registry) {
}

@(private)
_registry_os_attach :: proc(reg: ^Registry, loop: ^prim.Loop) -> Error {
	return .Unsupported
}

@(private)
_registry_wait :: proc(reg: ^Registry, ms: i32) -> bool {
	return false
}

@(private)
_watch_mount :: proc(reg: ^Registry, m: ^Mount) -> Error {
	return .Unsupported
}

@(private)
_unwatch_mount :: proc(reg: ^Registry, m: ^Mount) {
}

@(private)
_os_watch_dir :: proc(reg: ^Registry, m: ^Mount, rel: string, parent_wd: i32) -> (wd: i32, err: Error) {
	return -1, .Unsupported
}

@(private)
_registry_os_read :: proc(reg: ^Registry) -> Error {
	return .Unsupported
}

@(private)
_heap_release :: proc() {
	HeapCompact(win.GetProcessHeap(), 0)
}

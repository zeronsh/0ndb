package fs

import win "core:sys/windows"
import "../prim"

@(private)
disk_name_matches :: proc(vfs: prim.Vfs, abs: string) -> bool {
	if vfs.procs != prim.os_vfs().procs {
		return true
	}
	wide := win.utf8_to_wstring(abs, context.temp_allocator)
	if wide == nil {
		return true
	}
	data: win.WIN32_FIND_DATAW
	h := win.FindFirstFileW(wide, &data)
	if h == win.INVALID_HANDLE_VALUE {
		return true
	}
	win.FindClose(h)
	name, err := win.wstring_to_utf8(cstring16(&data.cFileName[0]), -1, context.temp_allocator)
	if err != nil {
		return true
	}
	return name == path_name(abs)
}

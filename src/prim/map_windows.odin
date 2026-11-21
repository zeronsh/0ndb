package prim

import win "core:sys/windows"

map_file :: proc "contextless" (fd: Fd, size: int, write: bool) -> ([]u8, Error) {
	if size <= 0 {
		return nil, .Invalid
	}
	protect: u32 = win.PAGE_READWRITE if write else win.PAGE_READONLY
	sz := u64(size)
	m := win.CreateFileMappingW(_h(fd), nil, protect, u32(sz >> 32), u32(sz), nil)
	if m == nil {
		return nil, _last()
	}
	access: u32 = win.FILE_MAP_WRITE | win.FILE_MAP_READ if write else win.FILE_MAP_READ
	p := win.MapViewOfFile(m, access, 0, 0, uint(size))
	err := _last() if p == nil else Error.None
	win.CloseHandle(m)
	if p == nil {
		return nil, err
	}
	return ([^]u8)(p)[:size], .None
}

unmap_file :: proc "contextless" (data: []u8) {
	if data != nil {
		win.UnmapViewOfFile(raw_data(data))
	}
}

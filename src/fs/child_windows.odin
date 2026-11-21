package fs

import win "core:sys/windows"
import "../prim"

@(private)
child_write_all :: proc(fd: prim.Fd, data: []u8) -> bool {
	prim.set_nonblocking(fd, false)
	h := fd_handle(fd)
	ev := win.CreateEventW(nil, true, false, nil)
	if ev == nil {
		return false
	}
	defer win.CloseHandle(ev)
	off := 0
	for off < len(data) {
		ov := win.OVERLAPPED {
			hEvent = ev,
		}
		n: u32
		chunk := u32(min(len(data) - off, 1 << 30))
		if !win.WriteFile(h, raw_data(data[off:]), chunk, nil, &ov) && win.GetLastError() != 997 {
			return false
		}
		if !win.GetOverlappedResult(h, &ov, &n, true) {
			return false
		}
		if n == 0 {
			return false
		}
		off += int(n)
	}
	return true
}

@(private)
child_read :: proc(fd: prim.Fd, buf: []u8) -> (int, prim.Error) {
	h := fd_handle(fd)
	ev := win.CreateEventW(nil, true, false, nil)
	if ev == nil {
		return 0, .Io
	}
	defer win.CloseHandle(ev)
	ov := win.OVERLAPPED {
		hEvent = ev,
	}
	n: u32
	if !win.ReadFile(h, raw_data(buf), u32(min(len(buf), 1 << 30)), nil, &ov) {
		code := win.GetLastError()
		if code == 109 || code == 233 {
			return 0, .None
		}
		if code != 997 {
			return 0, .Io
		}
	}
	if !win.GetOverlappedResult(h, &ov, &n, true) {
		code := win.GetLastError()
		if code == 109 || code == 233 {
			return 0, .None
		}
		return 0, .Io
	}
	return int(n), .None
}

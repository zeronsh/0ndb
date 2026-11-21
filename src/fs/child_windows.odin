package fs

import win "core:sys/windows"
import "../prim"

@(private)
child_write_all :: proc(fd: prim.Fd, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := prim.write(fd, data[off:])
		if err == .Would_Block {
			win.Sleep(1)
			continue
		}
		if err != .None || n <= 0 {
			return false
		}
		off += n
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
	if !win.ReadFile(h, raw_data(buf), u32(min(len(buf), 1 << 30)), &n, &ov) {
		code := win.GetLastError()
		if code == 109 || code == 233 {
			return 0, .None
		}
		if code != 997 {
			return 0, .Io
		}
		if !win.GetOverlappedResult(h, &ov, &n, true) {
			code = win.GetLastError()
			if code == 109 || code == 233 {
				return 0, .None
			}
			return 0, .Io
		}
	}
	return int(n), .None
}

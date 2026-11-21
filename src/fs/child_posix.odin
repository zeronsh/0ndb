#+build linux, darwin
package fs

import "core:sys/posix"
import "../prim"

@(private)
child_wait :: proc(fd: prim.Fd, write: bool) {
	p := [1]posix.pollfd{{fd = posix.FD(fd), events = {.OUT} if write else {.IN}}}
	posix.poll(&p[0], 1, -1)
}

@(private)
child_write_all :: proc(fd: prim.Fd, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := prim.write(fd, data[off:])
		if err == .Would_Block || err == .Interrupted {
			child_wait(fd, true)
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
	for {
		n, err := prim.read(fd, buf)
		if err == .Would_Block || err == .Interrupted {
			child_wait(fd, false)
			continue
		}
		return n, err
	}
}

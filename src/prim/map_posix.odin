#+build linux, darwin
package prim

import "core:sys/posix"

map_file :: proc "contextless" (fd: Fd, size: int, write: bool) -> ([]u8, Error) {
	if size <= 0 {
		return nil, .Invalid
	}
	prot: posix.Prot_Flags = {.READ}
	if write {
		prot += {.WRITE}
	}
	p := posix.mmap(nil, uint(size), prot, {.SHARED}, posix.FD(fd), 0)
	if p == posix.MAP_FAILED {
		#partial switch posix.errno() {
		case .ENOMEM:
			return nil, .No_Memory
		case .EACCES, .EPERM:
			return nil, .Permission
		case .EINVAL, .EBADF:
			return nil, .Invalid
		case .ENODEV:
			return nil, .Unsupported
		}
		return nil, .Io
	}
	return ([^]u8)(p)[:size], .None
}

unmap_file :: proc "contextless" (data: []u8) {
	if data != nil {
		posix.munmap(raw_data(data), uint(len(data)))
	}
}

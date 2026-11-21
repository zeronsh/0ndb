package prim

import "base:runtime"
import "core:sys/linux"

@(private)
_error :: proc "contextless" (e: linux.Errno) -> Error {
	#partial switch e {
	case .NONE:
		return .None
	case .ENOENT, .ESRCH, .ENXIO:
		return .Not_Found
	case .EEXIST:
		return .Exists
	case .EPERM, .EACCES, .EROFS:
		return .Permission
	case .EAGAIN:
		return .Would_Block
	case .EINTR:
		return .Interrupted
	case .EPIPE:
		return .Broken_Pipe
	case .EBUSY, .ETXTBSY:
		return .Busy
	case .EINVAL, .EBADF, .ESPIPE:
		return .Invalid
	case .ENOTDIR:
		return .Not_Dir
	case .EISDIR:
		return .Is_Dir
	case .ENOTEMPTY:
		return .Not_Empty
	case .ENOSPC, .EDQUOT:
		return .No_Space
	case .EMFILE, .ENFILE:
		return .Too_Many_Files
	case .ENAMETOOLONG:
		return .Name_Too_Long
	case .EFBIG, .E2BIG, .EOVERFLOW:
		return .Too_Large
	case .ENOSYS, .EOPNOTSUPP, .ENOTTY:
		return .Unsupported
	case .ENOMEM:
		return .No_Memory
	case .ECHILD:
		return .No_Child
	}
	return .Io
}

open_file :: proc(path: string, flags: Open_Flags = {}, mode: u32 = 0o644) -> (fd: Fd, err: Error) {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	f := linux.Open_Flags{.CLOEXEC}
	if .Write in flags {
		f += {.RDWR}
	}
	if .Create in flags {
		f += {.CREAT}
	}
	if .Truncate in flags {
		f += {.TRUNC}
	}
	if .Exclusive in flags {
		f += {.EXCL}
	}
	if .Append in flags {
		f += {.APPEND}
	}
	if .Nonblock in flags {
		f += {.NONBLOCK}
	}
	if .Directory in flags {
		f += {.DIRECTORY}
	}
	for {
		raw, errno := linux.open(p, f, transmute(linux.Mode)mode)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return INVALID_FD, _error(errno)
		}
		return Fd(raw), .None
	}
}

close :: proc "contextless" (fd: Fd) -> Error {
	if fd < 0 {
		return .None
	}
	errno := linux.close(linux.Fd(fd))
	if errno == .EINTR {
		return .None
	}
	return _error(errno)
}

read :: proc "contextless" (fd: Fd, buf: []u8) -> (int, Error) {
	for {
		n, errno := linux.read(linux.Fd(fd), buf)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return 0, _error(errno)
		}
		return n, .None
	}
}

write :: proc "contextless" (fd: Fd, data: []u8) -> (int, Error) {
	for {
		n, errno := linux.write(linux.Fd(fd), data)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return 0, _error(errno)
		}
		return n, .None
	}
}

write_all :: proc "contextless" (fd: Fd, data: []u8) -> Error {
	n := 0
	for n < len(data) {
		w, err := write(fd, data[n:])
		if err != .None {
			return err
		}
		if w == 0 {
			return .Io
		}
		n += w
	}
	return .None
}

read_at :: proc "contextless" (fd: Fd, buf: []u8, off: i64) -> (int, Error) {
	n := 0
	for n < len(buf) {
		r, errno := linux.pread(linux.Fd(fd), buf[n:], off + i64(n))
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return n, _error(errno)
		}
		if r == 0 {
			break
		}
		n += r
	}
	return n, .None
}

write_at :: proc "contextless" (fd: Fd, data: []u8, off: i64) -> Error {
	n := 0
	for n < len(data) {
		w, errno := linux.pwrite(linux.Fd(fd), data[n:], off + i64(n))
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return _error(errno)
		}
		if w == 0 {
			return .Io
		}
		n += w
	}
	return .None
}

datasync :: proc "contextless" (fd: Fd) -> Error {
	for {
		errno := linux.fdatasync(linux.Fd(fd))
		if errno == .EINTR {
			continue
		}
		return _error(errno)
	}
}

fullsync :: proc "contextless" (fd: Fd) -> Error {
	for {
		errno := linux.fsync(linux.Fd(fd))
		if errno == .EINTR {
			continue
		}
		return _error(errno)
	}
}

file_size :: proc "contextless" (fd: Fd) -> (i64, Error) {
	st: linux.Stat
	errno := linux.fstat(linux.Fd(fd), &st)
	if errno != .NONE {
		return 0, _error(errno)
	}
	return i64(st.size), .None
}

truncate :: proc "contextless" (fd: Fd, size: i64) -> Error {
	for {
		errno := linux.ftruncate(linux.Fd(fd), size)
		if errno == .EINTR {
			continue
		}
		return _error(errno)
	}
}

remove :: proc "contextless" (path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	return _error(linux.unlink(p))
}

remove_dir :: proc "contextless" (path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	return _error(linux.rmdir(p))
}

rename :: proc "contextless" (old, new: string) -> Error {
	a: Path_Buf = ---
	b: Path_Buf = ---
	pa := cpath(old, &a) or_return
	pb := cpath(new, &b) or_return
	return _error(linux.rename(pa, pb))
}

mkdir :: proc "contextless" (path: string, mode: u32 = 0o755) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	return _error(linux.mkdir(p, transmute(linux.Mode)mode))
}

is_dir :: proc "contextless" (path: string) -> bool {
	buf: Path_Buf = ---
	p, err := cpath(path, &buf)
	if err != .None {
		return false
	}
	st: linux.Stat
	if linux.stat(p, &st) != .NONE {
		return false
	}
	return transmute(u32)st.mode & 0o170000 == 0o040000
}

exists :: proc "contextless" (path: string) -> bool {
	buf: Path_Buf = ---
	p, err := cpath(path, &buf)
	if err != .None {
		return false
	}
	st: linux.Stat
	return linux.stat(p, &st) == .NONE
}

sync_dir :: proc "contextless" (path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	fd, errno := linux.open(p, {.CLOEXEC, .DIRECTORY})
	if errno != .NONE {
		return _error(errno)
	}
	err := fullsync(Fd(fd))
	linux.close(fd)
	return err
}

lock_file :: proc(path: string) -> (fd: Fd, err: Error) {
	fd = open_file(path, {.Write, .Create}, 0o600) or_return
	for {
		errno := linux.flock(linux.Fd(fd), {.EX, .NB})
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			close(fd)
			if errno == .EAGAIN {
				return INVALID_FD, .Busy
			}
			return INVALID_FD, _error(errno)
		}
		return fd, .None
	}
}

set_nonblocking :: proc "contextless" (fd: Fd, on: bool = true) -> Error {
	flags, errno := linux.fcntl(linux.Fd(fd), linux.F_GETFL)
	if errno != .NONE {
		return _error(errno)
	}
	if on {
		flags += {.NONBLOCK}
	} else {
		flags -= {.NONBLOCK}
	}
	return _error(linux.fcntl(linux.Fd(fd), linux.F_SETFL, flags))
}

@(private)
_is_exec_file :: proc "contextless" (p: cstring) -> bool {
	st: linux.Stat
	if linux.stat(p, &st) != .NONE {
		return false
	}
	if transmute(u32)st.mode & 0o170000 != 0o100000 {
		return false
	}
	return linux.access(p, {.IXOTH}) == .NONE
}

@(private)
_platform_data_dir :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	if xdg, ok := getenv("XDG_DATA_HOME"); ok {
		return path_join(allocator, xdg, "0ndb")
	}
	home := _home() or_return
	return path_join(allocator, home, ".local/share/0ndb")
}

package prim

import "base:runtime"
import "core:c"
import "core:sys/posix"

foreign import libc "system:System"

@(private)
LOCK_EX :: 2
@(private)
LOCK_NB :: 4
@(private)
F_FULLFSYNC :: 51

@(private)
foreign libc {
	flock :: proc(fd: posix.FD, op: c.int) -> c.int ---
}

@(private)
_error :: proc "contextless" (e: posix.Errno) -> Error {
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
	case .ENOSYS, .ENOTSUP, .ENOTTY:
		return .Unsupported
	case .ENOMEM:
		return .No_Memory
	case .ECHILD:
		return .No_Child
	}
	return .Io
}

@(private)
_errno :: proc "contextless" () -> Error {
	return _error(posix.errno())
}

@(private)
_mode :: proc "contextless" (mode: u32) -> posix.mode_t {
	return transmute(posix.mode_t)posix._mode_t(mode)
}

open_file :: proc(path: string, flags: Open_Flags = {}, mode: u32 = 0o644) -> (fd: Fd, err: Error) {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	f := posix.O_Flags{.CLOEXEC}
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
		raw := posix.open(p, f, _mode(mode))
		if raw < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return INVALID_FD, _error(e)
		}
		return Fd(raw), .None
	}
}

close :: proc "contextless" (fd: Fd) -> Error {
	if fd < 0 {
		return .None
	}
	if posix.close(posix.FD(fd)) != .OK {
		e := posix.errno()
		if e == .EINTR {
			return .None
		}
		return _error(e)
	}
	return .None
}

read :: proc "contextless" (fd: Fd, buf: []u8) -> (int, Error) {
	for {
		n := posix.read(posix.FD(fd), raw_data(buf), uint(len(buf)))
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return 0, _error(e)
		}
		return int(n), .None
	}
}

write :: proc "contextless" (fd: Fd, data: []u8) -> (int, Error) {
	for {
		n := posix.write(posix.FD(fd), raw_data(data), uint(len(data)))
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return 0, _error(e)
		}
		return int(n), .None
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
		rest := buf[n:]
		r := posix.pread(posix.FD(fd), raw_data(rest), uint(len(rest)), posix.off_t(off + i64(n)))
		if r < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return n, _error(e)
		}
		if r == 0 {
			break
		}
		n += int(r)
	}
	return n, .None
}

write_at :: proc "contextless" (fd: Fd, data: []u8, off: i64) -> Error {
	n := 0
	for n < len(data) {
		rest := data[n:]
		w := posix.pwrite(posix.FD(fd), raw_data(rest), uint(len(rest)), posix.off_t(off + i64(n)))
		if w < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return _error(e)
		}
		if w == 0 {
			return .Io
		}
		n += int(w)
	}
	return .None
}

datasync :: proc "contextless" (fd: Fd) -> Error {
	if posix.fcntl(posix.FD(fd), posix.FCNTL_Cmd(F_FULLFSYNC)) != -1 {
		return .None
	}
	return fullsync(fd)
}

fullsync :: proc "contextless" (fd: Fd) -> Error {
	for {
		if posix.fsync(posix.FD(fd)) == .OK {
			return .None
		}
		e := posix.errno()
		if e == .EINTR {
			continue
		}
		return _error(e)
	}
}

file_size :: proc "contextless" (fd: Fd) -> (i64, Error) {
	st: posix.stat_t
	if posix.fstat(posix.FD(fd), &st) != .OK {
		return 0, _errno()
	}
	return i64(st.st_size), .None
}

truncate :: proc "contextless" (fd: Fd, size: i64) -> Error {
	for {
		if posix.ftruncate(posix.FD(fd), posix.off_t(size)) == .OK {
			return .None
		}
		e := posix.errno()
		if e == .EINTR {
			continue
		}
		return _error(e)
	}
}

remove :: proc "contextless" (path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if posix.unlink(p) != .OK {
		return _errno()
	}
	return .None
}

remove_dir :: proc "contextless" (path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if posix.rmdir(p) != .OK {
		return _errno()
	}
	return .None
}

rename :: proc "contextless" (old, new: string) -> Error {
	a: Path_Buf = ---
	b: Path_Buf = ---
	pa := cpath(old, &a) or_return
	pb := cpath(new, &b) or_return
	if posix.rename(pa, pb) != 0 {
		return _errno()
	}
	return .None
}

mkdir :: proc "contextless" (path: string, mode: u32 = 0o755) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if posix.mkdir(p, _mode(mode)) != .OK {
		return _errno()
	}
	return .None
}

is_dir :: proc "contextless" (path: string) -> bool {
	buf: Path_Buf = ---
	p, err := cpath(path, &buf)
	if err != .None {
		return false
	}
	st: posix.stat_t
	if posix.stat(p, &st) != .OK {
		return false
	}
	return posix.S_ISDIR(st.st_mode)
}

exists :: proc "contextless" (path: string) -> bool {
	buf: Path_Buf = ---
	p, err := cpath(path, &buf)
	if err != .None {
		return false
	}
	st: posix.stat_t
	return posix.stat(p, &st) == .OK
}

sync_dir :: proc "contextless" (path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	fd := posix.open(p, {.CLOEXEC})
	if fd < 0 {
		return _errno()
	}
	err := fullsync(Fd(fd))
	posix.close(fd)
	return err
}

lock_file :: proc(path: string) -> (fd: Fd, err: Error) {
	fd = open_file(path, {.Write, .Create}, 0o600) or_return
	for {
		if flock(posix.FD(fd), LOCK_EX | LOCK_NB) == 0 {
			return fd, .None
		}
		e := posix.errno()
		if e == .EINTR {
			continue
		}
		close(fd)
		if e == .EAGAIN {
			return INVALID_FD, .Busy
		}
		return INVALID_FD, _error(e)
	}
}

set_nonblocking :: proc "contextless" (fd: Fd, on: bool = true) -> Error {
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 {
		return _errno()
	}
	set := transmute(posix.O_Flags)flags
	if on {
		set += {.NONBLOCK}
	} else {
		set -= {.NONBLOCK}
	}
	if posix.fcntl(posix.FD(fd), .SETFL, transmute(c.int)set) < 0 {
		return _errno()
	}
	return .None
}

@(private)
_set_cloexec :: proc "contextless" (fd: posix.FD) -> Error {
	if posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC)) < 0 {
		return _errno()
	}
	return .None
}

@(private)
_is_exec_file :: proc "contextless" (p: cstring) -> bool {
	st: posix.stat_t
	if posix.stat(p, &st) != .OK {
		return false
	}
	if !posix.S_ISREG(st.st_mode) {
		return false
	}
	return posix.access(p, {.X_OK}) == .OK
}

@(private)
_platform_data_dir :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	home := _home() or_return
	return path_join(allocator, home, "Library/Application Support/0ndb")
}

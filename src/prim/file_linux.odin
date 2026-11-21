package prim

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"

@(rodata)
OS_VFS_PROCS := Vfs_Procs {
	open       = _os_open,
	close      = _os_close,
	read_at    = _os_read_at,
	write_at   = _os_write_at,
	datasync   = _os_datasync,
	fullsync   = _os_fullsync,
	truncate   = _os_truncate,
	punch_hole = _os_punch_hole,
	lock       = _os_lock,
	fstat      = _os_fstat,
	stat       = _os_stat,
	rename     = _os_rename,
	unlink     = _os_unlink,
	rmdir      = _os_rmdir,
	mkdir      = _os_mkdir,
	symlink    = _os_symlink,
	readlink   = _os_readlink,
	fchmod     = _os_fchmod,
	dir_open   = _os_dir_open,
	dir_next   = _os_dir_next,
	dir_close  = _os_dir_close,
}

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
_os_open :: proc(data: rawptr, path: string, flags: Open_Flags, mode: u32) -> (Fd, Error) {
	buf: Path_Buf = ---
	p, perr := cpath(path, &buf)
	if perr != .None {
		return INVALID_FD, perr
	}
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

@(private)
_os_close :: proc(data: rawptr, fd: Fd) -> Error {
	return close(fd)
}

@(private)
_os_read_at :: proc(data: rawptr, fd: Fd, buf: []u8, off: i64) -> (int, Error) {
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

@(private)
_os_write_at :: proc(data: rawptr, fd: Fd, src: []u8, off: i64) -> Error {
	n := 0
	for n < len(src) {
		w, errno := linux.pwrite(linux.Fd(fd), src[n:], off + i64(n))
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

@(private)
_os_datasync :: proc(data: rawptr, fd: Fd) -> Error {
	for {
		errno := linux.fdatasync(linux.Fd(fd))
		if errno != .EINTR {
			return _error(errno)
		}
	}
}

@(private)
_os_fullsync :: proc(data: rawptr, fd: Fd) -> Error {
	for {
		errno := linux.fsync(linux.Fd(fd))
		if errno != .EINTR {
			return _error(errno)
		}
	}
}

@(private)
_os_truncate :: proc(data: rawptr, fd: Fd, size: i64) -> Error {
	for {
		errno := linux.ftruncate(linux.Fd(fd), size)
		if errno != .EINTR {
			return _error(errno)
		}
	}
}

@(private)
FALLOC_FL_KEEP_SIZE :: 0x01
@(private)
FALLOC_FL_PUNCH_HOLE :: 0x02

@(private)
_os_punch_hole :: proc(data: rawptr, fd: Fd, off: i64, size: i64) -> Error {
	if size <= 0 {
		return .None
	}
	for {
		ret := intrinsics.syscall(
			linux.SYS_fallocate,
			uintptr(fd),
			uintptr(FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE),
			uintptr(off),
			uintptr(size),
		)
		errno := linux.Errno(-int(ret)) if int(ret) < 0 else linux.Errno.NONE
		if errno != .EINTR {
			return _error(errno)
		}
	}
}

@(private)
_os_lock :: proc(data: rawptr, fd: Fd) -> Error {
	for {
		errno := linux.flock(linux.Fd(fd), {.EX, .NB})
		if errno == .EINTR {
			continue
		}
		if errno == .EAGAIN {
			return .Busy
		}
		return _error(errno)
	}
}

@(private)
_stat_from :: proc "contextless" (st: ^linux.Stat) -> Stat {
	mode := transmute(u32)st.mode
	return Stat {
		size = i64(st.size),
		mode = mode,
		kind = _kind_from_mode(mode),
		ino = u64(st.ino),
		dev = u64(st.dev),
		nlink = u64(st.nlink),
		mtime_ns = i64(st.mtime.time_sec) * 1_000_000_000 + i64(st.mtime.time_nsec),
		ctime_ns = i64(st.ctime.time_sec) * 1_000_000_000 + i64(st.ctime.time_nsec),
	}
}

@(private)
_os_fstat :: proc(data: rawptr, fd: Fd) -> (Stat, Error) {
	st: linux.Stat
	if errno := linux.fstat(linux.Fd(fd), &st); errno != .NONE {
		return {}, _error(errno)
	}
	return _stat_from(&st), .None
}

@(private)
_os_stat :: proc(data: rawptr, path: string, follow: bool) -> (Stat, Error) {
	buf: Path_Buf = ---
	p, perr := cpath(path, &buf)
	if perr != .None {
		return {}, perr
	}
	st: linux.Stat
	errno := linux.stat(p, &st) if follow else linux.lstat(p, &st)
	if errno != .NONE {
		return {}, _error(errno)
	}
	return _stat_from(&st), .None
}

@(private)
_os_rename :: proc(data: rawptr, old: string, new: string) -> Error {
	a: Path_Buf = ---
	b: Path_Buf = ---
	pa := cpath(old, &a) or_return
	pb := cpath(new, &b) or_return
	return _error(linux.rename(pa, pb))
}

@(private)
_os_unlink :: proc(data: rawptr, path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	return _error(linux.unlink(p))
}

@(private)
_os_rmdir :: proc(data: rawptr, path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	return _error(linux.rmdir(p))
}

@(private)
_os_mkdir :: proc(data: rawptr, path: string, mode: u32) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	return _error(linux.mkdir(p, transmute(linux.Mode)mode))
}

@(private)
_os_symlink :: proc(data: rawptr, target: string, path: string) -> Error {
	a: Path_Buf = ---
	b: Path_Buf = ---
	pa := cpath(target, &a) or_return
	pb := cpath(path, &b) or_return
	return _error(linux.symlink(pa, pb))
}

@(private)
_os_readlink :: proc(data: rawptr, path: string, buf: []u8) -> (int, Error) {
	pbuf: Path_Buf = ---
	p, perr := cpath(path, &pbuf)
	if perr != .None {
		return 0, perr
	}
	n, errno := linux.readlink(p, buf)
	if errno != .NONE {
		return 0, _error(errno)
	}
	if n >= len(buf) {
		return n, .Too_Large
	}
	return n, .None
}

@(private)
_os_fchmod :: proc(data: rawptr, fd: Fd, mode: u32) -> Error {
	return _error(linux.fchmod(linux.Fd(fd), transmute(linux.Mode)(mode & 0o7777)))
}

@(private)
DIR_BUF :: 32 * 1024

@(private)
_os_dir_open :: proc(data: rawptr, d: ^Dir, path: string) -> Error {
	fd, err := _os_open(data, path, {.Directory}, 0)
	if err != .None {
		return err
	}
	if d.allocator.procedure == nil {
		d.allocator = context.allocator
	}
	buf, aerr := make([]u8, DIR_BUF, d.allocator)
	if aerr != nil {
		close(fd)
		return .No_Memory
	}
	d.fd = fd
	d.buf = buf
	return .None
}

@(private)
_os_dir_next :: proc(data: rawptr, d: ^Dir) -> (Dir_Entry, bool, Error) {
	for {
		if d.pos >= d.len {
			if d.eof || d.fd < 0 {
				return {}, false, .None
			}
			n, errno := linux.getdents(linux.Fd(d.fd), d.buf)
			if errno == .EINTR {
				continue
			}
			if errno != .NONE {
				return {}, false, _error(errno)
			}
			if n == 0 {
				d.eof = true
				return {}, false, .None
			}
			d.pos = 0
			d.len = n
		}
		rec := d.buf[d.pos:d.len]
		if len(rec) < 19 {
			d.pos = d.len
			continue
		}
		reclen := int(u16(rec[16]) | u16(rec[17]) << 8)
		if reclen < 19 || reclen > len(rec) {
			d.pos = d.len
			continue
		}
		d.pos += reclen
		name := rec[19:reclen]
		for b, i in name {
			if b == 0 {
				name = name[:i]
				break
			}
		}
		if len(name) == 0 || (len(name) == 1 && name[0] == '.') || (len(name) == 2 && name[0] == '.' && name[1] == '.') {
			continue
		}
		kind: File_Kind
		switch rec[18] {
		case 8:
			kind = .File
		case 4:
			kind = .Dir
		case 10:
			kind = .Symlink
		case 0:
			kind = .Unknown
		case:
			kind = .Other
		}
		return Dir_Entry{name = string(name), ino = get_u64le(rec[0:8]), kind = kind}, true, .None
	}
}

@(private)
_os_dir_close :: proc(data: rawptr, d: ^Dir) {
	if d.fd >= 0 {
		close(d.fd)
		d.fd = INVALID_FD
	}
	if d.buf != nil {
		delete(d.buf, d.allocator)
		d.buf = nil
	}
	d.pos = 0
	d.len = 0
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
	return linux.access(p, linux.X_OK) == .NONE
}

@(private)
_platform_data_dir :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	if xdg, ok := getenv("XDG_DATA_HOME"); ok {
		return path_join(allocator, xdg, "0ndb")
	}
	home := _home() or_return
	return path_join(allocator, home, ".local/share/0ndb")
}

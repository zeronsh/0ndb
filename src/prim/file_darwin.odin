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
F_BARRIERFSYNC :: 85
@(private)
F_PUNCHHOLE :: 99

@(private)
Fpunchhole :: struct {
	fp_flags:  u32,
	reserved:  u32,
	fp_offset: posix.off_t,
	fp_length: posix.off_t,
}

@(private)
foreign libc {
	flock :: proc(fd: posix.FD, op: c.int) -> c.int ---
	renamex_np :: proc(from: cstring, to: cstring, flags: c.uint) -> c.int ---
}

@(private)
RENAME_SWAP :: 0x2

@(rodata)
OS_VFS_PROCS := Vfs_Procs {
	open       = _os_open,
	close      = _os_close,
	read_at    = _os_read_at,
	write_at   = _os_write_at,
	datasync   = _os_datasync,
	fullsync   = _os_fullsync,
	barrier    = _os_barrier,
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
	set_times  = _os_set_times,
	dir_open   = _os_dir_open,
	dir_next   = _os_dir_next,
	dir_close  = _os_dir_close,
	exchange   = _os_exchange,
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
	case .ENOTDIR, .ELOOP:
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
_os_open :: proc(data: rawptr, path: string, flags: Open_Flags, mode: u32) -> (Fd, Error) {
	buf: Path_Buf = ---
	p, perr := cpath(path, &buf)
	if perr != .None {
		return INVALID_FD, perr
	}
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

@(private)
_os_close :: proc(data: rawptr, fd: Fd) -> Error {
	return close(fd)
}

@(private)
_os_read_at :: proc(data: rawptr, fd: Fd, buf: []u8, off: i64) -> (int, Error) {
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

@(private)
_os_write_at :: proc(data: rawptr, fd: Fd, src: []u8, off: i64) -> Error {
	n := 0
	for n < len(src) {
		rest := src[n:]
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

@(private)
_os_datasync :: proc(data: rawptr, fd: Fd) -> Error {
	if posix.fcntl(posix.FD(fd), posix.FCNTL_Cmd(F_FULLFSYNC)) != -1 {
		return .None
	}
	return _os_fullsync(data, fd)
}

@(private)
_os_barrier :: proc(data: rawptr, fd: Fd) -> Error {
	if posix.fcntl(posix.FD(fd), posix.FCNTL_Cmd(F_BARRIERFSYNC)) != -1 {
		return .None
	}
	return _os_datasync(data, fd)
}

@(private)
_os_fullsync :: proc(data: rawptr, fd: Fd) -> Error {
	for {
		if posix.fsync(posix.FD(fd)) == .OK {
			return .None
		}
		e := posix.errno()
		if e != .EINTR {
			return _error(e)
		}
	}
}

@(private)
_os_truncate :: proc(data: rawptr, fd: Fd, size: i64) -> Error {
	for {
		if posix.ftruncate(posix.FD(fd), posix.off_t(size)) == .OK {
			return .None
		}
		e := posix.errno()
		if e != .EINTR {
			return _error(e)
		}
	}
}

@(private)
_os_punch_hole :: proc(data: rawptr, fd: Fd, off: i64, size: i64) -> Error {
	if size <= 0 {
		return .None
	}
	BLOCK :: 4096
	end := off + size
	a := (off + BLOCK - 1) / BLOCK * BLOCK
	b := end / BLOCK * BLOCK
	if b <= a {
		return .Unsupported
	}
	ph := Fpunchhole {
		fp_offset = posix.off_t(a),
		fp_length = posix.off_t(b - a),
	}
	if posix.fcntl(posix.FD(fd), posix.FCNTL_Cmd(F_PUNCHHOLE), &ph) == -1 {
		return _errno()
	}
	zeros: [BLOCK]u8
	if a > off {
		if err := _os_write_at(data, fd, zeros[:a - off], off); err != .None {
			return err
		}
	}
	if end > b {
		if err := _os_write_at(data, fd, zeros[:end - b], b); err != .None {
			return err
		}
	}
	return .None
}

@(private)
_os_lock :: proc(data: rawptr, fd: Fd) -> Error {
	for {
		if flock(posix.FD(fd), LOCK_EX | LOCK_NB) == 0 {
			return .None
		}
		e := posix.errno()
		if e == .EINTR {
			continue
		}
		if e == .EAGAIN {
			return .Busy
		}
		return _error(e)
	}
}

@(private)
_stat_from :: proc "contextless" (st: ^posix.stat_t) -> Stat {
	mode := u32(transmute(posix._mode_t)st.st_mode)
	return Stat {
		size = i64(st.st_size),
		mode = mode,
		kind = _kind_from_mode(mode),
		ino = u64(st.st_ino),
		dev = u64(st.st_dev),
		nlink = u64(st.st_nlink),
		mtime_ns = i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec),
		ctime_ns = i64(st.st_ctim.tv_sec) * 1_000_000_000 + i64(st.st_ctim.tv_nsec),
	}
}

@(private)
_os_fstat :: proc(data: rawptr, fd: Fd) -> (Stat, Error) {
	st: posix.stat_t
	if posix.fstat(posix.FD(fd), &st) != .OK {
		return {}, _errno()
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
	st: posix.stat_t
	r := posix.stat(p, &st) if follow else posix.lstat(p, &st)
	if r != .OK {
		return {}, _errno()
	}
	return _stat_from(&st), .None
}

@(private)
_os_rename :: proc(data: rawptr, old: string, new: string) -> Error {
	a: Path_Buf = ---
	b: Path_Buf = ---
	pa := cpath(old, &a) or_return
	pb := cpath(new, &b) or_return
	if posix.rename(pa, pb) != 0 {
		return _errno()
	}
	return .None
}

@(private)
_os_exchange :: proc(data: rawptr, a: string, b: string) -> Error {
	x: Path_Buf = ---
	y: Path_Buf = ---
	pa := cpath(a, &x) or_return
	pb := cpath(b, &y) or_return
	if renamex_np(pa, pb, RENAME_SWAP) != 0 {
		return _errno()
	}
	return .None
}

@(private)
_os_unlink :: proc(data: rawptr, path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if posix.unlink(p) != .OK {
		return _errno()
	}
	return .None
}

@(private)
_os_rmdir :: proc(data: rawptr, path: string) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if posix.rmdir(p) != .OK {
		return _errno()
	}
	return .None
}

@(private)
_os_mkdir :: proc(data: rawptr, path: string, mode: u32) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if posix.mkdir(p, _mode(mode)) != .OK {
		return _errno()
	}
	return .None
}

@(private)
_os_symlink :: proc(data: rawptr, target: string, path: string) -> Error {
	a: Path_Buf = ---
	b: Path_Buf = ---
	pa := cpath(target, &a) or_return
	pb := cpath(path, &b) or_return
	if posix.symlink(pa, pb) != .OK {
		return _errno()
	}
	return .None
}

@(private)
_os_readlink :: proc(data: rawptr, path: string, buf: []u8) -> (int, Error) {
	pbuf: Path_Buf = ---
	p, perr := cpath(path, &pbuf)
	if perr != .None {
		return 0, perr
	}
	n := posix.readlink(p, raw_data(buf), uint(len(buf)))
	if n < 0 {
		return 0, _errno()
	}
	if int(n) >= len(buf) {
		return int(n), .Too_Large
	}
	return int(n), .None
}

@(private)
_os_fchmod :: proc(data: rawptr, fd: Fd, mode: u32) -> Error {
	if posix.fchmod(posix.FD(fd), _mode(mode & 0o7777)) != .OK {
		return _errno()
	}
	return .None
}

@(private)
_os_dir_open :: proc(data: rawptr, d: ^Dir, path: string) -> Error {
	fd, err := _os_open(data, path, {.Directory}, 0)
	if err != .None {
		return err
	}
	h := posix.fdopendir(posix.FD(fd))
	if h == nil {
		e := _errno()
		close(fd)
		return e
	}
	d.fd = fd
	d.handle = rawptr(h)
	return .None
}

@(private)
_os_dir_next :: proc(data: rawptr, d: ^Dir) -> (Dir_Entry, bool, Error) {
	if d.handle == nil {
		return {}, false, .None
	}
	for {
		posix.set_errno(.NONE)
		ent := posix.readdir(posix.DIR(d.handle))
		if ent == nil {
			e := posix.errno()
			if e != .NONE {
				return {}, false, _error(e)
			}
			return {}, false, .None
		}
		n := min(int(ent.d_namelen), len(ent.d_name))
		name := string(([^]u8)(&ent.d_name[0])[:n])
		if n == 0 || name == "." || name == ".." {
			continue
		}
		kind: File_Kind
		#partial switch ent.d_type {
		case .REG:
			kind = .File
		case .DIR:
			kind = .Dir
		case .LNK:
			kind = .Symlink
		case .UNKNOWN:
			kind = .Unknown
		case:
			kind = .Other
		}
		return Dir_Entry{name = name, ino = u64(ent.d_ino), kind = kind}, true, .None
	}
}

@(private)
_os_dir_close :: proc(data: rawptr, d: ^Dir) {
	if d.handle != nil {
		posix.closedir(posix.DIR(d.handle))
		d.handle = nil
		d.fd = INVALID_FD
	}
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

@(private)
_os_set_times :: proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> Error {
	buf: Path_Buf = ---
	p := cpath(path, &buf) or_return
	if atime_ns < 0 || mtime_ns < 0 {
		return .Invalid
	}
	times := [2]posix.timespec{
		{tv_sec = posix.time_t(atime_ns / 1_000_000_000), tv_nsec = c.long(atime_ns % 1_000_000_000)},
		{tv_sec = posix.time_t(mtime_ns / 1_000_000_000), tv_nsec = c.long(mtime_ns % 1_000_000_000)},
	}
	if posix.utimensat(posix.AT_FDCWD, p, &times, {}) != .OK {
		return _errno()
	}
	return .None
}

#+build linux
package observe

import "base:intrinsics"
import "core:strconv"
import "core:sys/linux"
import "../prim"

@(private)
AT_FDCWD :: i32(-100)
@(private)
AT_SYMLINK_NOFOLLOW :: u64(0x100)
@(private)
AT_REMOVEDIR :: u64(0x200)
@(private)
AT_SYMLINK_FOLLOW :: u64(0x400)
@(private)
AT_EMPTY_PATH :: u64(0x1000)
@(private)
RENAME_EXCHANGE :: u64(2)
@(private)
RESOLVE_NO_SYMLINKS :: u64(0x04)
@(private)
RESOLVE_IN_ROOT :: u64(0x10)
@(private)
RESOLVE_MASK :: u64(0x1f)

@(private)
SYS_O_RDONLY :: uintptr(0)
@(private)
SYS_O_DIRECTORY :: uintptr(0o200000) when ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 else uintptr(0o40000)
@(private)
SYS_O_PATH :: uintptr(0o10000000)
@(private)
SYS_O_NOFOLLOW :: uintptr(0o400000) when ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 else uintptr(0o100000)
@(private)
SYS_O_CLOEXEC :: uintptr(0o2000000)
@(private)
SYS_O_NONBLOCK :: uintptr(0o4000)

@(private)
ENOENT :: 2
@(private)
EINTR :: 4
@(private)
EAGAIN :: 11
@(private)
EFAULT :: 14
@(private)
EINVAL :: 22
@(private)
ENAMETOOLONG :: 36

@(private)
Kstat :: struct {
	dev:  u64,
	ino:  u64,
	mode: u32,
}

@(private)
_errno :: #force_inline proc "contextless" (r: uintptr) -> int {
	v := int(r)
	if v < 0 && v > -4096 {
		return -v
	}
	return 0
}

@(private)
_sys_openat :: proc "contextless" (dirfd: i32, path: cstring, flags: uintptr) -> (i32, int) {
	r := intrinsics.syscall(linux.SYS_openat, uintptr(int(dirfd)), uintptr(rawptr(path)), flags, 0)
	if e := _errno(r); e != 0 {
		return -1, e
	}
	return i32(int(r)), 0
}

@(private)
Open_How :: struct {
	flags:   u64,
	mode:    u64,
	resolve: u64,
}

@(private)
_sys_openat2 :: proc "contextless" (dirfd: i32, path: cstring, how: ^Open_How) -> (i32, int) {
	r := intrinsics.syscall(linux.SYS_openat2, uintptr(int(dirfd)), uintptr(rawptr(path)), uintptr(how), size_of(Open_How))
	if e := _errno(r); e != 0 {
		return -1, e
	}
	return i32(int(r)), 0
}

@(private)
_sys_close :: proc "contextless" (fd: i32) {
	if fd >= 0 {
		intrinsics.syscall(linux.SYS_close, uintptr(int(fd)))
	}
}

@(private)
_sys_readlinkat :: proc "contextless" (dirfd: i32, path: cstring, buf: []u8) -> (int, int) {
	r := intrinsics.syscall(linux.SYS_readlinkat, uintptr(int(dirfd)), uintptr(rawptr(path)), uintptr(raw_data(buf)), uintptr(len(buf)))
	if e := _errno(r); e != 0 {
		return 0, e
	}
	return int(r), 0
}

@(private)
STATX_TYPE :: u32(0x1)
@(private)
STATX_INO :: u32(0x100)

@(private)
Statx :: struct {
	mask:            u32,
	blksize:         u32,
	attributes:      u64,
	nlink:           u32,
	uid:             u32,
	gid:             u32,
	mode:            u16,
	_spare0:         u16,
	ino:             u64,
	size:            u64,
	blocks:          u64,
	attributes_mask: u64,
	atime:           [16]u8,
	btime:           [16]u8,
	ctime:           [16]u8,
	mtime:           [16]u8,
	rdev_major:      u32,
	rdev_minor:      u32,
	dev_major:       u32,
	dev_minor:       u32,
	mnt_id:          u64,
	_rest:           [104]u8,
}

@(private)
_sys_statx :: proc "contextless" (dirfd: i32, path: cstring, flags: uintptr) -> (st: Kstat, err: int) {
	sx: Statx
	r := intrinsics.syscall(linux.SYS_statx, uintptr(int(dirfd)), uintptr(rawptr(path)), flags, uintptr(STATX_TYPE | STATX_INO), uintptr(&sx))
	if e := _errno(r); e != 0 {
		return {}, e
	}
	st.dev = _dev_of(sx.dev_major, sx.dev_minor)
	st.ino = sx.ino
	st.mode = u32(sx.mode)
	return st, 0
}

@(private)
_dev_of :: proc "contextless" (major: u32, minor: u32) -> u64 {
	return u64(major & 0xfffff000) << 32 | u64(major & 0xfff) << 8 | u64(minor & 0xffffff00) << 12 | u64(minor & 0xff)
}

@(private)
_is_link :: #force_inline proc "contextless" (mode: u32) -> bool {
	return mode & 0o170000 == 0o120000
}

@(private)
Iovec :: struct {
	base: rawptr,
	len:  uint,
}

@(private)
_sys_vm_read :: proc "contextless" (pid: i32, local: []Iovec, remote: []Iovec) -> (int, int) {
	r := intrinsics.syscall(linux.SYS_process_vm_readv, uintptr(int(pid)), uintptr(raw_data(local)), uintptr(len(local)), uintptr(raw_data(remote)), uintptr(len(remote)), 0)
	if e := _errno(r); e != 0 {
		return 0, e
	}
	return int(r), 0
}

@(private)
_sys_ioctl :: proc "contextless" (fd: i32, cmd: uintptr, arg: rawptr) -> int {
	r := intrinsics.syscall(linux.SYS_ioctl, uintptr(int(fd)), cmd, uintptr(arg))
	return _errno(r)
}

@(private)
Pollfd :: struct {
	fd:      i32,
	events:  i16,
	revents: i16,
}

@(private)
POLLIN :: i16(0x1)
@(private)
POLLERR :: i16(0x8)
@(private)
POLLHUP :: i16(0x10)
@(private)
POLLNVAL :: i16(0x20)

@(private)
_sys_poll :: proc "contextless" (fds: [^]Pollfd, n: int, timeout_ms: int) -> (int, int) {
	when ODIN_ARCH == .arm64 {
		ts: linux.Time_Spec
		tp: rawptr
		if timeout_ms >= 0 {
			ts = {time_sec = uint(timeout_ms / 1000), time_nsec = uint((timeout_ms % 1000) * 1_000_000)}
			tp = &ts
		}
		r := intrinsics.syscall(linux.SYS_ppoll, uintptr(fds), uintptr(n), uintptr(tp), 0, 0)
	} else {
		r := intrinsics.syscall(linux.SYS_poll, uintptr(fds), uintptr(n), uintptr(timeout_ms))
	}
	if e := _errno(r); e != 0 {
		return 0, e
	}
	return int(r), 0
}

@(private)
Proc_Path :: struct {
	buf: [80]u8,
	n:   int,
}

@(private)
_pp_reset :: proc "contextless" (p: ^Proc_Path) {
	p.n = 0
}

@(private)
_pp_str :: proc "contextless" (p: ^Proc_Path, s: string) {
	for i in 0 ..< len(s) {
		if p.n < len(p.buf) - 1 {
			p.buf[p.n] = s[i]
			p.n += 1
		}
	}
}

@(private)
_pp_int :: proc "contextless" (p: ^Proc_Path, v: i64) {
	digits: [24]u8
	n := 0
	x := v
	neg := x < 0
	if neg {
		x = -x
	}
	for {
		digits[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	if neg {
		_pp_str(p, "-")
	}
	for i := n - 1; i >= 0; i -= 1 {
		if p.n < len(p.buf) - 1 {
			p.buf[p.n] = digits[i]
			p.n += 1
		}
	}
}

@(private)
_pp_c :: proc "contextless" (p: ^Proc_Path) -> cstring {
	p.buf[p.n] = 0
	return cstring(raw_data(p.buf[:]))
}

@(private)
_pp_proc :: proc "contextless" (p: ^Proc_Path, pid: i64, tail: string) -> cstring {
	_pp_reset(p)
	_pp_str(p, "/proc/")
	_pp_int(p, pid)
	_pp_str(p, tail)
	return _pp_c(p)
}

@(private)
_pp_self_fd :: proc "contextless" (p: ^Proc_Path, fd: i32) -> cstring {
	_pp_reset(p)
	_pp_str(p, "/proc/self/fd/")
	_pp_int(p, i64(fd))
	return _pp_c(p)
}

@(private)
_readlink_fd :: proc "contextless" (fd: i32, out: []u8) -> (string, bool) {
	pp: Proc_Path
	n, e := _sys_readlinkat(AT_FDCWD, _pp_self_fd(&pp, fd), out)
	if e != 0 || n <= 0 || n >= len(out) {
		return "", false
	}
	return string(out[:n]), true
}

@(private)
_read_small :: proc "contextless" (path: cstring, buf: []u8) -> (int, bool) {
	fd, e := _sys_openat(AT_FDCWD, path, SYS_O_RDONLY | SYS_O_CLOEXEC)
	if e != 0 {
		return 0, false
	}
	total := 0
	for total < len(buf) {
		r := intrinsics.syscall(linux.SYS_read, uintptr(int(fd)), uintptr(raw_data(buf[total:])), uintptr(len(buf) - total))
		re := _errno(r)
		if re == EINTR {
			continue
		}
		if re != 0 {
			_sys_close(fd)
			return 0, false
		}
		if int(r) == 0 {
			break
		}
		total += int(r)
	}
	_sys_close(fd)
	return total, true
}

@(private)
_status_ids :: proc(tid: i32, buf: []u8) -> (tgid: prim.Pid, ppid: prim.Pid, ok: bool) {
	pp: Proc_Path
	fd, e := _sys_openat(AT_FDCWD, _pp_proc(&pp, i64(tid), "/status"), SYS_O_RDONLY | SYS_O_CLOEXEC)
	if e != 0 {
		return
	}
	r: uintptr
	for {
		r = intrinsics.syscall(linux.SYS_read, uintptr(int(fd)), uintptr(raw_data(buf)), uintptr(len(buf)))
		if _errno(r) != EINTR {
			break
		}
	}
	_sys_close(fd)
	if _errno(r) != 0 {
		return
	}
	n := int(r)
	s := string(buf[:n])
	got := 0
	for len(s) > 0 && got < 2 {
		line := s
		if i := _index_byte(s, '\n'); i >= 0 {
			line = s[:i]
			s = s[i + 1:]
		} else {
			s = ""
		}
		if len(line) > 5 && line[:5] == "Tgid:" {
			v, vok := strconv.parse_int(_trim(line[5:]), 10)
			if vok {
				tgid = prim.Pid(v)
				got += 1
			}
		} else if len(line) > 5 && line[:5] == "PPid:" {
			v, vok := strconv.parse_int(_trim(line[5:]), 10)
			if vok {
				ppid = prim.Pid(v)
				got += 1
			}
		}
	}
	return tgid, ppid, got == 2
}

@(private)
_stat_ppid :: proc(pid: prim.Pid, buf: []u8) -> (prim.Pid, bool) {
	pp: Proc_Path
	n, rok := _read_small(_pp_proc(&pp, i64(pid), "/stat"), buf[:min(len(buf), 1024)])
	if !rok {
		return 0, false
	}
	s := string(buf[:n])
	close := -1
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == ')' {
			close = i
			break
		}
	}
	if close < 0 || close + 4 >= len(s) {
		return 0, false
	}
	rest := s[close + 4:]
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
		end += 1
	}
	v, ok := strconv.parse_int(rest[:end], 10)
	if !ok {
		return 0, false
	}
	return prim.Pid(v), true
}

@(private)
_index_byte :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

@(private)
_trim :: proc "contextless" (s: string) -> string {
	a := 0
	b := len(s)
	for a < b && (s[a] == ' ' || s[a] == '\t') {
		a += 1
	}
	for b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r') {
		b -= 1
	}
	return s[a:b]
}

@(private)
_strip_firmlink :: proc "contextless" (p: string) -> string {
	return p
}

process_args :: proc(pid: prim.Pid, buf: []u8) -> ([]u8, bool) {
	pp: Proc_Path
	n, ok := _read_small(_pp_proc(&pp, i64(pid), "/cmdline"), buf)
	if !ok || n == 0 {
		return nil, false
	}
	for n > 0 && buf[n - 1] == 0 {
		n -= 1
	}
	return buf[:n], true
}

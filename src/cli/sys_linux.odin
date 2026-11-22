package main

import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "../prim"

Signals :: struct {
	fd: prim.Fd,
}

signals_open :: proc(s: ^Signals) -> bool {
	set: linux.Sig_Set
	for sig in ([]int{int(linux.Signal.SIGINT), int(linux.Signal.SIGTERM), int(linux.Signal.SIGHUP)}) {
		set[(sig - 1) / (8 * size_of(uint))] |= 1 << uint((sig - 1) % (8 * size_of(uint)))
	}
	if linux.rt_sigprocmask(.SIG_BLOCK, &set, nil) != .NONE {
		return false
	}
	SFD_NONBLOCK :: 0o4000
	SFD_CLOEXEC :: 0o2000000
	r := linux.syscall(linux.SYS_signalfd4, -1, uintptr(&set), size_of(linux.Sig_Set), SFD_NONBLOCK | SFD_CLOEXEC)
	if r < 0 {
		return false
	}
	s.fd = prim.Fd(r)
	return true
}

signals_read :: proc(s: ^Signals) -> (sig: int, ok: bool) {
	buf: [128]u8
	n, err := linux.read(linux.Fd(s.fd), buf[:])
	if err != .NONE || n < 4 {
		return 0, false
	}
	return int(prim.get_u32le(buf[:4])), true
}

signals_close :: proc(s: ^Signals) {
	if s.fd >= 0 {
		linux.close(linux.Fd(s.fd))
		s.fd = -1
	}
}

peer_is_self :: proc(fd: prim.Fd) -> bool {
	Ucred :: struct {
		pid: i32,
		uid: u32,
		gid: u32,
	}
	SOL_SOCKET :: 1
	SO_PEERCRED :: 17
	cred: Ucred
	size := u32(size_of(Ucred))
	r := linux.syscall(linux.SYS_getsockopt, uintptr(fd), SOL_SOCKET, SO_PEERCRED, uintptr(&cred), uintptr(&size))
	if int(r) < 0 || size < size_of(Ucred) {
		return false
	}
	return cred.uid == u32(posix.getuid())
}

rss_bytes :: proc() -> i64 {
	buf: [256]u8
	fd, oerr := linux.open("/proc/self/statm", {})
	if oerr != .NONE {
		return 0
	}
	n, rerr := linux.read(fd, buf[:])
	linux.close(fd)
	if rerr != .NONE || n <= 0 {
		return 0
	}
	data := buf[:n]
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	pages, ok := strconv.parse_i64(fields[1])
	if !ok {
		return 0
	}
	return pages * i64(posix.sysconf(._PAGESIZE))
}

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	malloc_trim :: proc(pad: uint) -> i32 ---
}

idle_release :: proc() {
	malloc_trim(0)
}

sys_hostname :: proc(allocator := context.allocator) -> string {
	buf: [256]u8
	if posix.gethostname(raw_data(buf[:]), len(buf) - 1) != .OK {
		return ""
	}
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}
	return strings.clone(string(buf[:n]), allocator)
}

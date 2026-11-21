package osync

import "core:c"
import "core:sys/posix"
import "../prim"

foreign import libc "system:System"

@(private)
foreign libc {
	@(link_name = "setsockopt")
	_c_setsockopt :: proc(fd: posix.FD, level: c.int, name: c.int, val: rawptr, len: u32) -> c.int ---
	@(link_name = "getsockopt")
	_c_getsockopt :: proc(fd: posix.FD, level: c.int, name: c.int, val: rawptr, len: ^u32) -> c.int ---
	@(link_name = "getpeereid")
	_c_getpeereid :: proc(fd: posix.FD, uid: ^u32, gid: ^u32) -> c.int ---
	@(link_name = "sendfile")
	_c_sendfile_raw :: proc(fd: posix.FD, s: posix.FD, offset: posix.off_t, length: ^posix.off_t, hdtr: rawptr, flags: c.int) -> c.int ---
}

@(private)
_Notifier :: struct {
	rfd: posix.FD,
	wfd: posix.FD,
}

@(private)
D_SOL_SOCKET :: 0xffff
@(private)
D_SO_REUSEADDR :: 0x0004
@(private)
D_SO_KEEPALIVE :: 0x0008
@(private)
D_SO_ERROR :: 0x1007
@(private)
D_SO_NOSIGPIPE :: 0x1022
@(private)
D_IPPROTO_TCP :: 6
@(private)
D_TCP_NODELAY :: 0x01
@(private)
D_TCP_KEEPALIVE :: 0x10
@(private)
D_TCP_KEEPINTVL :: 0x101
@(private)
D_TCP_KEEPCNT :: 0x102

@(private)
_errno_of :: proc "contextless" (e: posix.Errno) -> Error {
	#partial switch e {
	case .NONE:
		return .None
	case .EAGAIN, .EINPROGRESS:
		return .Would_Block
	case .EPIPE, .ECONNRESET, .ENOTCONN, .ECONNABORTED:
		return .Closed
	case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EADDRNOTAVAIL, .EADDRINUSE:
		return .Refused
	case .ETIMEDOUT:
		return .Timeout
	case .ENOENT:
		return .Not_Found
	case .EEXIST:
		return .Exists
	case .EACCES, .EPERM, .EROFS:
		return .Permission
	case .ENOSPC, .EDQUOT:
		return .No_Space
	case .ENOMEM, .ENOBUFS, .EMFILE, .ENFILE:
		return .No_Memory
	case .EBADMSG:
		return .Corrupt
	case .EMSGSIZE, .EFBIG, .EOVERFLOW:
		return .Too_Large
	case .ENOSYS, .ENOTSUP, .ENOPROTOOPT:
		return .Unsupported
	case .EINVAL, .EBADF, .ENOTSOCK:
		return .Invalid
	}
	return .Io
}

@(private)
_last :: proc "contextless" () -> Error {
	return _errno_of(posix.errno())
}

@(private)
_nonblock :: proc "contextless" (fd: posix.FD) -> bool {
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 {
		return false
	}
	if posix.fcntl(fd, .SETFL, flags | c.int(posix.O_Flags{.NONBLOCK})) < 0 {
		return false
	}
	return posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC)) >= 0
}

@(private)
_notifier_open :: proc(n: ^_Notifier) -> Error {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		n.rfd = -1
		n.wfd = -1
		return _last()
	}
	_nonblock(fds[0])
	_nonblock(fds[1])
	n.rfd = fds[0]
	n.wfd = fds[1]
	return .None
}

@(private)
_notifier_close :: proc(n: ^_Notifier) {
	if n.rfd >= 0 {
		posix.close(n.rfd)
	}
	if n.wfd >= 0 {
		posix.close(n.wfd)
	}
	n.rfd = -1
	n.wfd = -1
}

@(private)
_notifier_fd :: proc "contextless" (n: ^_Notifier) -> prim.Fd {
	return prim.Fd(n.rfd)
}

@(private)
_notifier_signal :: proc "contextless" (n: ^_Notifier) {
	b := [1]u8{1}
	for {
		if posix.write(n.wfd, &b[0], 1) >= 0 || posix.errno() != .EINTR {
			return
		}
	}
}

@(private)
_notifier_drain :: proc "contextless" (n: ^_Notifier) {
	b: [64]u8
	for {
		r := posix.read(n.rfd, &b[0], len(b))
		if r > 0 {
			continue
		}
		if r < 0 && posix.errno() == .EINTR {
			continue
		}
		return
	}
}

@(private)
_Sockaddr :: struct #raw_union {
	v4: posix.sockaddr_in,
	v6: posix.sockaddr_in6,
	un: posix.sockaddr_un,
}

@(private)
_sockaddr :: proc "contextless" (ep: ^Endpoint) -> (sa: _Sockaddr, n: u32, ok: bool) {
	switch ep.family {
	case .Ip4:
		sa.v4.sin_len = size_of(posix.sockaddr_in)
		sa.v4.sin_family = .INET
		sa.v4.sin_port = posix.in_port_t(u16be(ep.port))
		a := ep.addr
		sa.v4.sin_addr.s_addr = (^posix.in_addr_t)(&a[0])^
		return sa, size_of(posix.sockaddr_in), true
	case .Ip6:
		sa.v6.sin6_len = size_of(posix.sockaddr_in6)
		sa.v6.sin6_family = .INET6
		sa.v6.sin6_port = posix.in_port_t(u16be(ep.port))
		sa.v6.sin6_addr.s6_addr = ep.addr
		return sa, size_of(posix.sockaddr_in6), true
	case .Unix:
		if ep.path_len <= 0 || ep.path_len >= len(sa.un.sun_path) {
			return sa, 0, false
		}
		sa.un.sun_len = size_of(posix.sockaddr_un)
		sa.un.sun_family = .UNIX
		for i in 0 ..< ep.path_len {
			sa.un.sun_path[i] = c.char(ep.path[i])
		}
		return sa, size_of(posix.sockaddr_un), true
	case .None, .Host:
	}
	return sa, 0, false
}

@(private)
_socket :: proc "contextless" (ep: ^Endpoint) -> (posix.FD, Error) {
	af: posix.AF
	proto := posix.Protocol.TCP
	#partial switch ep.family {
	case .Ip4:
		af = .INET
	case .Ip6:
		af = .INET6
	case .Unix:
		af = .UNIX
		proto = .IP
	case:
		return -1, .Invalid
	}
	fd := posix.socket(af, .STREAM, proto)
	if fd < 0 {
		return -1, _last()
	}
	if !_nonblock(fd) {
		posix.close(fd)
		return -1, .Io
	}
	one: c.int = 1
	_c_setsockopt(fd, D_SOL_SOCKET, D_SO_NOSIGPIPE, &one, size_of(one))
	return fd, .None
}

@(private)
_listen :: proc(ep: ^Endpoint) -> (lfd: prim.Fd, err: Error) {
	sa, n, ok := _sockaddr(ep)
	if !ok {
		return prim.INVALID_FD, .Invalid
	}
	fd := _socket(ep) or_return
	if ep.family == .Unix {
		_unlink_stale(ep)
	} else {
		one: c.int = 1
		_c_setsockopt(fd, D_SOL_SOCKET, D_SO_REUSEADDR, &one, size_of(one))
	}
	if posix.bind(fd, (^posix.sockaddr)(&sa), posix.socklen_t(n)) != .OK {
		e := _last()
		posix.close(fd)
		return prim.INVALID_FD, e
	}
	if posix.listen(fd, 4096) != .OK {
		e := _last()
		posix.close(fd)
		return prim.INVALID_FD, e
	}
	return prim.Fd(fd), .None
}

@(private)
_unlink_stale :: proc(ep: ^Endpoint) {
	sa, n, ok := _sockaddr(ep)
	if !ok {
		return
	}
	fd := posix.socket(.UNIX, .STREAM, .IP)
	if fd < 0 {
		return
	}
	defer posix.close(fd)
	if posix.connect(fd, (^posix.sockaddr)(&sa), posix.socklen_t(n)) != .OK && posix.errno() == .ECONNREFUSED {
		prim.remove(prim.os_vfs(), string(ep.path[:ep.path_len]))
	}
}

@(private)
_accept :: proc "contextless" (lfd: prim.Fd) -> (prim.Fd, [16]u8, Error) {
	for {
		sa: _Sockaddr
		sl := posix.socklen_t(size_of(sa))
		fd := posix.accept(posix.FD(lfd), (^posix.sockaddr)(&sa), &sl)
		if fd < 0 {
			e := posix.errno()
			if e == .EINTR || e == .ECONNABORTED {
				continue
			}
			return prim.INVALID_FD, {}, _errno_of(e)
		}
		src: [16]u8
		#partial switch sa.v4.sin_family {
		case .INET:
			src[10] = 0xff
			src[11] = 0xff
			a := sa.v4.sin_addr.s_addr
			b := transmute([4]u8)a
			copy(src[12:], b[:])
		case .INET6:
			src = sa.v6.sin6_addr.s6_addr
		}
		if !_nonblock(fd) {
			posix.close(fd)
			continue
		}
		one: c.int = 1
		_c_setsockopt(fd, D_SOL_SOCKET, D_SO_NOSIGPIPE, &one, size_of(one))
		return prim.Fd(fd), src, .None
	}
}

@(private)
_connect :: proc(ep: ^Endpoint) -> (fd: prim.Fd, pending: bool, err: Error) {
	sa, n, ok := _sockaddr(ep)
	if !ok {
		return prim.INVALID_FD, false, .Invalid
	}
	s := _socket(ep) or_return
	if posix.connect(s, (^posix.sockaddr)(&sa), posix.socklen_t(n)) != .OK {
		e := posix.errno()
		if e == .EINPROGRESS || e == .EINTR || e == .EAGAIN {
			return prim.Fd(s), true, .None
		}
		posix.close(s)
		return prim.INVALID_FD, false, _errno_of(e)
	}
	return prim.Fd(s), false, .None
}

@(private)
_socket_error :: proc "contextless" (fd: prim.Fd) -> Error {
	v: c.int
	l := u32(size_of(v))
	if _c_getsockopt(posix.FD(fd), D_SOL_SOCKET, D_SO_ERROR, &v, &l) != 0 {
		return _last()
	}
	return _errno_of(posix.Errno(v))
}

@(private)
_tune_tcp :: proc "contextless" (fd: prim.Fd) {
	s := posix.FD(fd)
	one: c.int = 1
	idle: c.int = 120
	intvl: c.int = 30
	cnt: c.int = 4
	_c_setsockopt(s, D_IPPROTO_TCP, D_TCP_NODELAY, &one, size_of(one))
	_c_setsockopt(s, D_SOL_SOCKET, D_SO_KEEPALIVE, &one, size_of(one))
	_c_setsockopt(s, D_IPPROTO_TCP, D_TCP_KEEPALIVE, &idle, size_of(idle))
	_c_setsockopt(s, D_IPPROTO_TCP, D_TCP_KEEPINTVL, &intvl, size_of(intvl))
	_c_setsockopt(s, D_IPPROTO_TCP, D_TCP_KEEPCNT, &cnt, size_of(cnt))
}

@(private)
_send :: proc "contextless" (fd: prim.Fd, data: []u8, more: bool) -> (int, Error) {
	for {
		n := posix.send(posix.FD(fd), raw_data(data), c.size_t(len(data)), {})
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return 0, _errno_of(e)
		}
		return int(n), .None
	}
}

@(private)
_recv :: proc "contextless" (fd: prim.Fd, buf: []u8) -> (int, Error) {
	for {
		n := posix.recv(posix.FD(fd), raw_data(buf), c.size_t(len(buf)), {})
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return 0, _errno_of(e)
		}
		if n == 0 && len(buf) > 0 {
			return 0, .Closed
		}
		return int(n), .None
	}
}

@(private)
_sendfile :: proc "contextless" (out: prim.Fd, src: prim.Fd, off: i64, n: int) -> (int, Error) {
	for {
		length := posix.off_t(n)
		if _c_sendfile_raw(posix.FD(src), posix.FD(out), posix.off_t(off), &length, nil, 0) == 0 {
			if length == 0 && n > 0 {
				return 0, .Corrupt
			}
			return int(length), .None
		}
		e := posix.errno()
		if (e == .EAGAIN || e == .EINTR) && length > 0 {
			return int(length), .None
		}
		#partial switch e {
		case .EINTR:
			continue
		case .ENOTSOCK, .ENOTSUP, .EINVAL:
			return 0, .Unsupported
		}
		return 0, _errno_of(e)
	}
}

@(private)
_ktls_install :: proc "contextless" (fd: prim.Fd, keys: ^Session_Keys) -> (tx, rx: bool) {
	return false, false
}

@(private)
_peer_is_self :: proc "contextless" (fd: prim.Fd) -> bool {
	uid, gid: u32
	if _c_getpeereid(posix.FD(fd), &uid, &gid) != 0 {
		return false
	}
	return uid == u32(posix.geteuid())
}

@(private)
_shutdown :: proc "contextless" (fd: prim.Fd) {
	posix.shutdown(posix.FD(fd), .RDWR)
}

@(private)
_raise_nofile :: proc "contextless" () -> int {
	lim: posix.rlimit
	if posix.getrlimit(.NOFILE, &lim) != .OK {
		return 256
	}
	target := lim.rlim_max
	if target > 1 << 20 {
		target = 1 << 20
	}
	if lim.rlim_cur < target {
		lim.rlim_cur = target
		posix.setrlimit(.NOFILE, &lim)
		posix.getrlimit(.NOFILE, &lim)
	}
	return int(min(lim.rlim_cur, posix.rlim_t(max(i32))))
}


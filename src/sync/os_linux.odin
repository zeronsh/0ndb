package osync

import "core:sys/linux"
import "../prim"

@(private)
_Notifier :: struct {
	fd: linux.Fd,
}

@(private)
_Tls_Info :: struct #packed {
	version: u16,
	cipher:  u16,
	iv:      [8]u8,
	key:     [32]u8,
	salt:    [4]u8,
	rec_seq: [8]u8,
}

@(private)
_Ucred :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

@(private)
SOL_TCP :: 6
@(private)
TCP_ULP :: 31
@(private)
SOL_TLS :: 282
@(private)
TLS_TX :: 1
@(private)
TLS_RX :: 2
@(private)
TLS_RX_EXPECT_NO_PAD :: 4
@(private)
TLS_1_3_VERSION :: 0x0304
@(private)
TLS_CIPHER_AES_GCM_256 :: 52

@(private)
_errno :: proc "contextless" (e: linux.Errno) -> Error {
	#partial switch e {
	case .NONE:
		return .None
	case .EAGAIN, .EINPROGRESS:
		return .Would_Block
	case .EPIPE, .ECONNRESET, .ENOTCONN, .ESHUTDOWN, .ECONNABORTED:
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
	case .ENOSYS, .EOPNOTSUPP, .ENOPROTOOPT:
		return .Unsupported
	case .EINVAL, .EBADF, .ENOTSOCK:
		return .Invalid
	}
	return .Io
}

@(private)
_notifier_open :: proc(n: ^_Notifier) -> Error {
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		n.fd = -1
		return _errno(err)
	}
	n.fd = fd
	return .None
}

@(private)
_notifier_close :: proc(n: ^_Notifier) {
	if n.fd >= 0 {
		linux.close(n.fd)
	}
	n.fd = -1
}

@(private)
_notifier_fd :: proc "contextless" (n: ^_Notifier) -> prim.Fd {
	return prim.Fd(n.fd)
}

@(private)
_notifier_signal :: proc "contextless" (n: ^_Notifier) {
	one := u64(1)
	b := transmute([8]u8)one
	for {
		_, err := linux.write(n.fd, b[:])
		if err != .EINTR {
			return
		}
	}
}

@(private)
_notifier_drain :: proc "contextless" (n: ^_Notifier) {
	b: [8]u8
	for {
		_, err := linux.read(n.fd, b[:])
		if err != .EINTR {
			return
		}
	}
}

@(private)
_sockaddr :: proc "contextless" (ep: ^Endpoint) -> (sa: linux.Sock_Addr_Any, ok: bool) {
	switch ep.family {
	case .Ip4:
		sa.ipv4.sin_family = .INET
		sa.ipv4.sin_port = u16be(ep.port)
		copy(sa.ipv4.sin_addr[:], ep.addr[:4])
		return sa, true
	case .Ip6:
		sa.ipv6.sin6_family = .INET6
		sa.ipv6.sin6_port = u16be(ep.port)
		sa.ipv6.sin6_addr = ep.addr
		return sa, true
	case .Unix:
		if ep.path_len <= 0 || ep.path_len >= len(sa.uds.sun_path) {
			return sa, false
		}
		sa.uds.sun_family = .UNIX
		copy(sa.uds.sun_path[:], ep.path[:ep.path_len])
		return sa, true
	case .None, .Host:
	}
	return sa, false
}

@(private)
_socket :: proc "contextless" (ep: ^Endpoint) -> (linux.Fd, Error) {
	family: linux.Address_Family
	proto := linux.Protocol.TCP
	#partial switch ep.family {
	case .Ip4:
		family = .INET
	case .Ip6:
		family = .INET6
	case .Unix:
		family = .UNIX
		proto = .HOPOPT
	case:
		return -1, .Invalid
	}
	fd, err := linux.socket(family, .STREAM, {.CLOEXEC, .NONBLOCK}, proto)
	if err != .NONE {
		return -1, _errno(err)
	}
	return fd, .None
}

@(private)
_listen :: proc(ep: ^Endpoint) -> (lfd: prim.Fd, err: Error) {
	sa, ok := _sockaddr(ep)
	if !ok {
		return prim.INVALID_FD, .Invalid
	}
	fd := _socket(ep) or_return
	if ep.family == .Unix {
		_unlink_stale(ep)
	} else {
		one: i32 = 1
		linux.setsockopt(fd, linux.SOL_SOCKET, linux.Socket_Option.REUSEADDR, &one)
	}
	if err := _bind(fd, &sa, ep); err != .NONE {
		linux.close(fd)
		return prim.INVALID_FD, _errno(err)
	}
	if err := linux.listen(fd, 4096); err != .NONE {
		linux.close(fd)
		return prim.INVALID_FD, _errno(err)
	}
	return prim.Fd(fd), .None
}

@(private)
_bind :: proc "contextless" (fd: linux.Fd, sa: ^linux.Sock_Addr_Any, ep: ^Endpoint) -> linux.Errno {
	switch ep.family {
	case .Ip4:
		return linux.bind(fd, &sa.ipv4)
	case .Ip6:
		return linux.bind(fd, &sa.ipv6)
	case .Unix:
		return linux.bind(fd, &sa.uds)
	case .None, .Host:
	}
	return .EINVAL
}

@(private)
_unlink_stale :: proc(ep: ^Endpoint) {
	probe, ok := _sockaddr(ep)
	if !ok {
		return
	}
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE {
		return
	}
	defer linux.close(fd)
	if cerr := linux.connect(fd, &probe.uds); cerr == .ECONNREFUSED {
		prim.remove(prim.os_vfs(), string(ep.path[:ep.path_len]))
	}
}

@(private)
_accept :: proc "contextless" (lfd: prim.Fd) -> (prim.Fd, [16]u8, Error) {
	for {
		sa: linux.Sock_Addr_Any
		fd, err := linux.accept(linux.Fd(lfd), &sa, {.CLOEXEC, .NONBLOCK})
		if err == .EINTR || err == .ECONNABORTED {
			continue
		}
		if err != .NONE {
			return prim.INVALID_FD, {}, _errno(err)
		}
		src: [16]u8
		#partial switch sa.family {
		case .INET:
			src[10] = 0xff
			src[11] = 0xff
			copy(src[12:], sa.ipv4.sin_addr[:])
		case .INET6:
			src = sa.ipv6.sin6_addr
		}
		return prim.Fd(fd), src, .None
	}
}

@(private)
_connect :: proc(ep: ^Endpoint) -> (fd: prim.Fd, pending: bool, err: Error) {
	sa, ok := _sockaddr(ep)
	if !ok {
		return prim.INVALID_FD, false, .Invalid
	}
	s := _socket(ep) or_return
	cerr: linux.Errno
	switch ep.family {
	case .Ip4:
		cerr = linux.connect(s, &sa.ipv4)
	case .Ip6:
		cerr = linux.connect(s, &sa.ipv6)
	case .Unix:
		cerr = linux.connect(s, &sa.uds)
	case .None, .Host:
		cerr = .EINVAL
	}
	if cerr == .EINPROGRESS || cerr == .EAGAIN || cerr == .EINTR {
		return prim.Fd(s), true, .None
	}
	if cerr != .NONE {
		linux.close(s)
		return prim.INVALID_FD, false, _errno(cerr)
	}
	return prim.Fd(s), false, .None
}

@(private)
_socket_error :: proc "contextless" (fd: prim.Fd) -> Error {
	v: i32
	_, err := linux.getsockopt_base(linux.Fd(fd), int(linux.SOL_SOCKET), .ERROR, &v)
	if err != .NONE {
		return _errno(err)
	}
	return _errno(linux.Errno(v))
}

@(private)
_tune_tcp :: proc "contextless" (fd: prim.Fd) {
	s := linux.Fd(fd)
	one: i32 = 1
	linux.setsockopt_base(s, SOL_TCP, int(linux.Socket_TCP_Option.NODELAY), &one)
	linux.setsockopt(s, linux.SOL_SOCKET, linux.Socket_Option.KEEPALIVE, &one)
	idle: i32 = 120
	intvl: i32 = 30
	cnt: i32 = 4
	user_timeout: u32 = 240_000
	linux.setsockopt_base(s, SOL_TCP, int(linux.Socket_TCP_Option.KEEPIDLE), &idle)
	linux.setsockopt_base(s, SOL_TCP, int(linux.Socket_TCP_Option.KEEPINTVL), &intvl)
	linux.setsockopt_base(s, SOL_TCP, int(linux.Socket_TCP_Option.KEEPCNT), &cnt)
	linux.setsockopt_base(s, SOL_TCP, int(linux.Socket_TCP_Option.USER_TIMEOUT), &user_timeout)
}

@(private)
_send :: proc "contextless" (fd: prim.Fd, data: []u8, more: bool) -> (int, Error) {
	flags := linux.Socket_Msg{.NOSIGNAL}
	if more {
		flags += {.MORE}
	}
	for {
		n, err := linux.send(linux.Fd(fd), data, flags)
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return 0, _errno(err)
		}
		return n, .None
	}
}

@(private)
_recv :: proc "contextless" (fd: prim.Fd, buf: []u8) -> (int, Error) {
	for {
		n, err := linux.recv(linux.Fd(fd), buf, {})
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return 0, _errno(err)
		}
		if n == 0 && len(buf) > 0 {
			return 0, .Closed
		}
		return n, .None
	}
}

@(private)
_sendfile :: proc "contextless" (out: prim.Fd, src: prim.Fd, off: i64, n: int) -> (int, Error) {
	for {
		o := off
		w, err := linux.sendfile(linux.Fd(out), linux.Fd(src), &o, uint(n))
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return 0, _errno(err)
		}
		if w == 0 && n > 0 {
			return 0, .Corrupt
		}
		return w, .None
	}
}

@(private)
_ktls_install :: proc "contextless" (fd: prim.Fd, keys: ^Session_Keys) -> (tx, rx: bool) {
	s := linux.Fd(fd)
	ulp := [3]u8{'t', 'l', 's'}
	if linux.setsockopt_base(s, SOL_TCP, TCP_ULP, &ulp) != .NONE {
		return false, false
	}
	info := _tls_info(&keys.tx)
	tx = linux.setsockopt_base(s, SOL_TLS, TLS_TX, &info) == .NONE
	info = _tls_info(&keys.rx)
	rx = linux.setsockopt_base(s, SOL_TLS, TLS_RX, &info) == .NONE
	if rx {
		one: i32 = 1
		linux.setsockopt_base(s, SOL_TLS, TLS_RX_EXPECT_NO_PAD, &one)
	}
	info = {}
	return
}

@(private)
_tls_info :: proc "contextless" (t: ^Traffic) -> _Tls_Info {
	return _Tls_Info{version = TLS_1_3_VERSION, cipher = TLS_CIPHER_AES_GCM_256, iv = t.iv, key = t.key, salt = t.salt}
}

@(private)
_peer_is_self :: proc "contextless" (fd: prim.Fd) -> bool {
	cred: _Ucred
	_, err := linux.getsockopt_base(linux.Fd(fd), int(linux.SOL_SOCKET), .PEERCRED, &cred)
	if err != .NONE {
		return false
	}
	return cred.uid == u32(linux.geteuid())
}

@(private)
_shutdown :: proc "contextless" (fd: prim.Fd) {
	linux.shutdown(linux.Fd(fd), .RDWR)
}

@(private)
_raise_nofile :: proc "contextless" () -> int {
	lim: linux.RLimit
	if linux.getrlimit(.NOFILE, &lim) != .NONE {
		return 1024
	}
	if lim.cur < lim.max {
		lim.cur = lim.max
		linux.setrlimit(.NOFILE, &lim)
		linux.getrlimit(.NOFILE, &lim)
	}
	return int(min(lim.cur, uint(max(i32))))
}



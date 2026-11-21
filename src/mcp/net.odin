package mcp

import "core:c"
import "core:strings"
import "core:sys/posix"
import "../prim"

@(private)
_net_error :: proc "contextless" (e: posix.Errno) -> prim.Error {
	#partial switch e {
	case .EAGAIN:
		return .Would_Block
	case .EINTR:
		return .Interrupted
	case .EPIPE, .ECONNRESET:
		return .Broken_Pipe
	case .EACCES, .EPERM:
		return .Permission
	case .EADDRINUSE:
		return .Busy
	case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ETIMEDOUT:
		return .Not_Found
	case .EMFILE, .ENFILE:
		return .Too_Many_Files
	case .ENOMEM, .ENOBUFS:
		return .No_Memory
	case .EINVAL, .EAFNOSUPPORT:
		return .Invalid
	}
	return .Io
}

@(private)
_resolve :: proc(host: string, port: int, passive: bool) -> (^posix.addrinfo, prim.Error) {
	h := host
	if len(h) >= 2 && h[0] == '[' && h[len(h) - 1] == ']' {
		h = h[1:len(h) - 1]
	}
	chost := strings.clone_to_cstring(h, context.temp_allocator)
	pbuf: [16]u8
	pn := 0
	p := port
	if p == 0 {
		pbuf[0] = '0'
		pn = 1
	} else {
		digits: [16]u8
		dn := 0
		for p > 0 {
			digits[dn] = u8('0' + p % 10)
			dn += 1
			p /= 10
		}
		for k in 0 ..< dn {
			pbuf[k] = digits[dn - 1 - k]
		}
		pn = dn
	}
	cport := strings.clone_to_cstring(string(pbuf[:pn]), context.temp_allocator)
	hints: posix.addrinfo
	hints.ai_socktype = .STREAM
	hints.ai_flags = {.NUMERICHOST, .NUMERICSERV}
	if passive {
		hints.ai_flags += {.PASSIVE}
	}
	res: ^posix.addrinfo
	if posix.getaddrinfo(chost if len(h) > 0 else nil, cport, &hints, &res) == .NONE {
		return res, .None
	}
	hints.ai_flags = {.NUMERICSERV, .ADDRCONFIG}
	if passive {
		hints.ai_flags += {.PASSIVE}
	}
	if posix.getaddrinfo(chost if len(h) > 0 else nil, cport, &hints, &res) == .NONE {
		return res, .None
	}
	return nil, .Not_Found
}

@(private)
_cloexec_nonblock :: proc "contextless" (fd: posix.FD) {
	posix.fcntl(fd, .SETFD, c.int(posix.FD_CLOEXEC))
	prim.set_nonblocking(prim.Fd(fd))
}

net_connect :: proc(host: string, port: int) -> (fd: prim.Fd, pending: bool, err: prim.Error) {
	res, rerr := _resolve(host, port, false)
	if rerr != .None {
		return prim.INVALID_FD, false, rerr
	}
	defer posix.freeaddrinfo(res)
	last := prim.Error.Not_Found
	for ai := res; ai != nil; ai = ai.ai_next {
		s := posix.socket(ai.ai_family, .STREAM, .IP)
		if s < 0 {
			last = _net_error(posix.errno())
			continue
		}
		_cloexec_nonblock(s)
		one: c.int = 1
		if ai.ai_family == .INET || ai.ai_family == .INET6 {
			posix.setsockopt(s, c.int(posix.Protocol.TCP), posix.Sock_Option(posix.TCP_NODELAY), &one, size_of(one))
		}
		when ODIN_OS == .Darwin {
			posix.setsockopt(s, posix.SOL_SOCKET, posix.Sock_Option(0x1022), &one, size_of(one))
		}
		if posix.connect(s, ai.ai_addr, ai.ai_addrlen) == .OK {
			return prim.Fd(s), false, .None
		}
		e := posix.errno()
		if e == .EINPROGRESS || e == .EINTR {
			return prim.Fd(s), true, .None
		}
		last = _net_error(e)
		posix.close(s)
	}
	return prim.INVALID_FD, false, last
}

net_socket_error :: proc "contextless" (fd: prim.Fd) -> prim.Error {
	v: c.int
	l := posix.socklen_t(size_of(v))
	if posix.getsockopt(posix.FD(fd), posix.SOL_SOCKET, .ERROR, &v, &l) != .OK {
		return _net_error(posix.errno())
	}
	if v != 0 {
		return _net_error(posix.Errno(v))
	}
	return .None
}

net_listen :: proc(host: string, port: int) -> (fd: prim.Fd, bound: int, err: prim.Error) {
	res, rerr := _resolve(host, port, true)
	if rerr != .None {
		return prim.INVALID_FD, 0, rerr
	}
	defer posix.freeaddrinfo(res)
	last := prim.Error.Not_Found
	for ai := res; ai != nil; ai = ai.ai_next {
		s := posix.socket(ai.ai_family, .STREAM, .IP)
		if s < 0 {
			last = _net_error(posix.errno())
			continue
		}
		_cloexec_nonblock(s)
		one: c.int = 1
		posix.setsockopt(s, posix.SOL_SOCKET, .REUSEADDR, &one, size_of(one))
		if posix.bind(s, ai.ai_addr, ai.ai_addrlen) != .OK || posix.listen(s, 128) != .OK {
			last = _net_error(posix.errno())
			posix.close(s)
			continue
		}
		ss: posix.sockaddr_storage
		sl := posix.socklen_t(size_of(ss))
		posix.getsockname(s, (^posix.sockaddr)(&ss), &sl)
		if ai.ai_family == .INET {
			sin := (^posix.sockaddr_in)(&ss)
			bound = int(u16(sin.sin_port))
		} else if ai.ai_family == .INET6 {
			sin6 := (^posix.sockaddr_in6)(&ss)
			bound = int(u16(sin6.sin6_port))
		}
		return prim.Fd(s), bound, .None
	}
	return prim.INVALID_FD, 0, last
}

net_accept :: proc "contextless" (lfd: prim.Fd) -> (prim.Fd, prim.Error) {
	for {
		s := posix.accept(posix.FD(lfd), nil, nil)
		if s >= 0 {
			_cloexec_nonblock(s)
			one: c.int = 1
			posix.setsockopt(s, c.int(posix.Protocol.TCP), posix.Sock_Option(posix.TCP_NODELAY), &one, size_of(one))
			when ODIN_OS == .Darwin {
				posix.setsockopt(s, posix.SOL_SOCKET, posix.Sock_Option(0x1022), &one, size_of(one))
			}
			return prim.Fd(s), .None
		}
		e := posix.errno()
		if e == .EINTR || e == .ECONNABORTED {
			continue
		}
		return prim.INVALID_FD, _net_error(e)
	}
}

net_close :: proc "contextless" (fd: prim.Fd) {
	if fd != prim.INVALID_FD {
		prim.close(fd)
	}
}

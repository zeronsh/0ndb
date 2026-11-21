package mcp

import "core:strings"
import win "core:sys/windows"
import "../prim"

@(private)
_wsa_error :: proc "contextless" () -> prim.Error {
	switch win.WSAGetLastError() {
	case win.WSAEWOULDBLOCK:
		return .Would_Block
	case win.WSAEADDRINUSE:
		return .Busy
	case win.WSAEACCES:
		return .Permission
	case win.WSAEMFILE, win.WSAENOBUFS:
		return .Too_Many_Files
	case win.WSAEINVAL, win.WSAEAFNOSUPPORT:
		return .Invalid
	case win.WSAECONNRESET, win.WSAECONNABORTED:
		return .Broken_Pipe
	}
	return .Io
}

net_listen :: proc(host: string, port: int) -> (fd: prim.Fd, bound: int, err: prim.Error) {
	wsa: win.WSADATA
	if win.WSAStartup(0x0202, &wsa) != 0 {
		return prim.INVALID_FD, 0, .Unsupported
	}
	defer if err != .None {
		win.WSACleanup()
	}
	h := strings.clone_to_cstring(host if len(host) > 0 else "127.0.0.1", context.temp_allocator)
	p := strings.clone_to_cstring(fmt_port(port), context.temp_allocator)
	hints := win.ADDRINFOA {
		ai_flags    = win.AI_PASSIVE,
		ai_socktype = win.SOCK_STREAM,
		ai_protocol = win.IPPROTO_TCP,
	}
	res: ^win.ADDRINFOA
	if win.getaddrinfo(h, p, &hints, &res) != 0 {
		return prim.INVALID_FD, 0, .Not_Found
	}
	defer win.freeaddrinfo(res)
	last := prim.Error.Not_Found
	for ai := res; ai != nil; ai = ai.ai_next {
		s := win.WSASocketW(ai.ai_family, ai.ai_socktype, ai.ai_protocol, nil, 0, win.WSA_FLAG_OVERLAPPED | win.WSA_FLAG_NO_HANDLE_INHERIT)
		if s == win.INVALID_SOCKET {
			last = _wsa_error()
			continue
		}
		one: i32 = 1
		win.setsockopt(s, win.SOL_SOCKET, win.SO_EXCLUSIVEADDRUSE, &one, size_of(one))
		if win.bind(s, (^win.SOCKADDR_STORAGE_LH)(ai.ai_addr), i32(ai.ai_addrlen)) != 0 || win.listen(s, 128) != 0 {
			last = _wsa_error()
			win.closesocket(s)
			continue
		}
		ss: win.SOCKADDR_STORAGE_LH
		sl := i32(size_of(ss))
		win.getsockname(s, &ss, &sl)
		if ss.ss_family == u16(win.AF_INET) {
			bound = int((^win.sockaddr_in)(&ss).sin_port)
		} else if ss.ss_family == u16(win.AF_INET6) {
			bound = int((^win.sockaddr_in6)(&ss).sin6_port)
		}
		fd = prim.Fd(i32(int(uintptr(s))))
		prim.set_nonblocking(fd)
		return fd, bound, .None
	}
	return prim.INVALID_FD, 0, last
}

@(private)
fmt_port :: proc(port: int) -> string {
	buf: [8]u8
	n := len(buf)
	v := max(port, 0)
	for {
		n -= 1
		buf[n] = u8('0' + v % 10)
		v /= 10
		if v == 0 || n == 0 {
			break
		}
	}
	return strings.clone(string(buf[n:]), context.temp_allocator)
}

net_accept :: proc "contextless" (lfd: prim.Fd) -> (prim.Fd, prim.Error) {
	for {
		s := win.accept(win.SOCKET(uintptr(int(lfd))), nil, nil)
		if s != win.INVALID_SOCKET {
			fd := prim.Fd(i32(int(uintptr(s))))
			prim.set_nonblocking(fd)
			one: i32 = 1
			win.setsockopt(s, win.IPPROTO_TCP, win.TCP_NODELAY, &one, size_of(one))
			return fd, .None
		}
		if win.WSAGetLastError() == win.WSAECONNRESET {
			continue
		}
		return prim.INVALID_FD, _wsa_error()
	}
}

net_close :: proc "contextless" (fd: prim.Fd) {
	if fd != prim.INVALID_FD {
		prim.close(fd)
	}
}

package osync

import "base:runtime"
import win "core:sys/windows"
import "../prim"

foreign import ntdll_sync "system:ntdll.lib"
foreign import advapi_sync "system:Advapi32.lib"
foreign import kernel_sync "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel_sync {
	SetNamedPipeHandleState :: proc(pipe: win.HANDLE, mode: ^u32, max_collection: ^u32, timeout: ^u32) -> win.BOOL ---
}

@(private)
@(default_calling_convention = "system")
foreign ntdll_sync {
	NtCreateWaitCompletionPacket :: proc(handle: ^win.HANDLE, access: u32, attrs: rawptr) -> i32 ---
	NtAssociateWaitCompletionPacket :: proc(packet: win.HANDLE, port: win.HANDLE, target: win.HANDLE, key: rawptr, apc: rawptr, status: i32, info: uintptr, already: ^win.BOOLEAN) -> i32 ---
	NtCancelWaitCompletionPacket :: proc(packet: win.HANDLE, remove_signaled: win.BOOLEAN) -> i32 ---
}

@(private)
@(default_calling_convention = "system")
foreign advapi_sync {
	EqualSid :: proc(a: rawptr, b: rawptr) -> win.BOOL ---
}

@(private)
W_AF_UNIX :: 1
@(private)
W_AF_INET :: 2
@(private)
W_AF_INET6 :: 23
@(private)
W_SOCK_STREAM :: 1
@(private)
W_IPPROTO_TCP :: 6
@(private)
W_SOL_SOCKET :: 0xffff
@(private)
W_SO_KEEPALIVE :: 0x0008
@(private)
W_SO_ERROR :: 0x1007
@(private)
W_TCP_NODELAY :: 0x0001
@(private)
W_TCP_KEEPIDLE :: 3
@(private)
W_TCP_KEEPCNT :: 16
@(private)
W_TCP_KEEPINTVL :: 17
@(private)
W_FIONBIO :: 0x8004667e
@(private)
W_SIO_AF_UNIX_GETPEERPID :: 0x58000100
@(private)
W_WSA_IO_PENDING :: 997
@(private)
W_SOCK_NOTIFY_EVENT_OUT :: 0x02
@(private)
W_GENERIC_ALL :: 0x10000000
@(private)
W_STATUS_PENDING :: 0x103
@(private)
W_PROCESS_QUERY_LIMITED_INFORMATION :: 0x1000
@(private)
W_PIPE_ACCESS_INBOUND :: 0x1
@(private)
W_FILE_FLAG_FIRST_PIPE_INSTANCE :: 0x00080000
@(private)
W_PIPE_REJECT_REMOTE_CLIENTS :: 0x8
@(private)
W_PIPE_NOWAIT :: 0x1
@(private)
W_FILE_READ_ATTRIBUTES :: 0x0080

@(private)
_Notifier :: struct {
	rfd: prim.Fd,
	wfd: prim.Fd,
}

@(private)
_Tx :: struct {
	ov:     win.OVERLAPPED,
	event:  win.HANDLE,
	packet: win.HANDLE,
	busy:   bool,
}

@(private)
_Transport_Os :: struct {
	port: win.HANDLE,
	key:  u64,
	tx:   _Tx,
}

@(private)
_sock :: #force_inline proc "contextless" (fd: prim.Fd) -> win.SOCKET {
	return win.SOCKET(uintptr(int(fd)))
}

@(private)
_sfd :: #force_inline proc "contextless" (s: win.SOCKET) -> prim.Fd {
	return prim.Fd(i32(int(uintptr(s))))
}

@(private)
_wsa_of :: proc "contextless" (code: i32) -> Error {
	switch code {
	case 0:
		return .None
	case 10035, 10036, 10037:
		return .Would_Block
	case 10053, 10054, 10057, 10058, 10101, 64, 109, 232, 233:
		return .Closed
	case 10061, 10065, 10051, 10049, 10048, 10050, 10052:
		return .Refused
	case 10060:
		return .Timeout
	case 10013, 5:
		return .Permission
	case 10055, 10024, 8, 14:
		return .No_Memory
	case 10040:
		return .Too_Large
	case 10045, 10043, 10047, 10044, 10042, 10046, 50, 120:
		return .Unsupported
	case 10022, 10038, 10009, 6, 87:
		return .Invalid
	case 11001, 11002, 11003, 11004:
		return .Resolve
	}
	return .Io
}

@(private)
_last :: proc "contextless" () -> Error {
	return _wsa_of(win.WSAGetLastError())
}

@(private)
_nonblock :: proc "contextless" (s: win.SOCKET) -> bool {
	arg: u32 = 1
	if win.ioctlsocket(s, transmute(i32)u32(W_FIONBIO), &arg) != 0 {
		return false
	}
	win.SetHandleInformation(win.HANDLE(uintptr(s)), win.HANDLE_FLAG_INHERIT, 0)
	return true
}

@(private)
_notifier_open :: proc(n: ^_Notifier) -> Error {
	n.rfd = prim.INVALID_FD
	n.wfd = prim.INVALID_FD
	rnd: [8]u8
	runtime.rand_bytes(rnd[:])
	name: [80]u16
	prefix := "\\\\.\\pipe\\0ndb-sync-"
	k := 0
	for ch in transmute([]u8)prefix {
		name[k] = u16(ch)
		k += 1
	}
	hex := "0123456789abcdef"
	pid := win.GetCurrentProcessId()
	for s := 28; s >= 0; s -= 4 {
		name[k] = u16(hex[(pid >> u32(s)) & 0xF])
		k += 1
	}
	name[k] = '-'
	k += 1
	for b in rnd {
		name[k] = u16(hex[b >> 4])
		name[k + 1] = u16(hex[b & 0xF])
		k += 2
	}
	name[k] = 0
	wname := win.wstring(&name[0])
	r := win.CreateNamedPipeW(wname, W_PIPE_ACCESS_INBOUND | win.FILE_FLAG_OVERLAPPED | W_FILE_FLAG_FIRST_PIPE_INSTANCE, win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | W_PIPE_REJECT_REMOTE_CLIENTS, 1, 512, 512, 0, nil)
	if r == win.INVALID_HANDLE_VALUE {
		return .Io
	}
	w := win.CreateFileW(wname, win.GENERIC_WRITE | W_FILE_READ_ATTRIBUTES, 0, nil, win.OPEN_EXISTING, 0, nil)
	if w == win.INVALID_HANDLE_VALUE {
		win.CloseHandle(r)
		return .Io
	}
	mode: u32 = win.PIPE_READMODE_BYTE | W_PIPE_NOWAIT
	if !SetNamedPipeHandleState(w, &mode, nil, nil) {
		win.CloseHandle(r)
		win.CloseHandle(w)
		return .Io
	}
	n.rfd = prim.Fd(i32(int(uintptr(r))))
	n.wfd = prim.Fd(i32(int(uintptr(w))))
	return .None
}

@(private)
_notifier_close :: proc(n: ^_Notifier) {
	if n.rfd != prim.INVALID_FD {
		prim.close(n.rfd)
	}
	if n.wfd != prim.INVALID_FD {
		prim.close(n.wfd)
	}
	n.rfd = prim.INVALID_FD
	n.wfd = prim.INVALID_FD
}

@(private)
_notifier_fd :: proc "contextless" (n: ^_Notifier) -> prim.Fd {
	return n.rfd
}

@(private)
_notifier_signal :: proc "contextless" (n: ^_Notifier) {
	b := [1]u8{1}
	wrote: u32
	win.WriteFile(win.HANDLE(uintptr(int(n.wfd))), &b[0], 1, &wrote, nil)
}

@(private)
_notifier_drain :: proc "contextless" (n: ^_Notifier) {
	b: [64]u8
	for {
		got, err := prim.read(n.rfd, b[:])
		if err != .None || got <= 0 {
			return
		}
	}
}

@(private)
_Sockaddr :: struct #raw_union {
	raw: [128]u8,
	fam: u16,
}

@(private)
_sockaddr :: proc "contextless" (ep: ^Endpoint) -> (sa: _Sockaddr, n: i32, ok: bool) {
	switch ep.family {
	case .Ip4:
		sa.fam = W_AF_INET
		sa.raw[2] = u8(ep.port >> 8)
		sa.raw[3] = u8(ep.port)
		copy(sa.raw[4:8], ep.addr[:4])
		return sa, 16, true
	case .Ip6:
		sa.fam = W_AF_INET6
		sa.raw[2] = u8(ep.port >> 8)
		sa.raw[3] = u8(ep.port)
		copy(sa.raw[8:24], ep.addr[:])
		return sa, 28, true
	case .Unix:
		if ep.path_len <= 0 || ep.path_len >= 108 {
			return sa, 0, false
		}
		sa.fam = W_AF_UNIX
		for i in 0 ..< ep.path_len {
			c := ep.path[i]
			sa.raw[2 + i] = '\\' if c == '/' else c
		}
		return sa, 110, true
	case .None, .Host:
	}
	return sa, 0, false
}

@(private)
_socket :: proc "contextless" (ep: ^Endpoint) -> (win.SOCKET, Error) {
	af: i32
	proto: i32 = W_IPPROTO_TCP
	#partial switch ep.family {
	case .Ip4:
		af = W_AF_INET
	case .Ip6:
		af = W_AF_INET6
	case .Unix:
		af = W_AF_UNIX
		proto = 0
	case:
		return win.INVALID_SOCKET, .Invalid
	}
	s := win.WSASocketW(af, W_SOCK_STREAM, proto, nil, 0, win.WSA_FLAG_OVERLAPPED | win.WSA_FLAG_NO_HANDLE_INHERIT)
	if s == win.INVALID_SOCKET {
		return s, _last()
	}
	if !_nonblock(s) {
		e := _last()
		win.closesocket(s)
		return win.INVALID_SOCKET, e
	}
	return s, .None
}

@(private)
_listen :: proc(ep: ^Endpoint) -> (lfd: prim.Fd, err: Error) {
	sa, n, ok := _sockaddr(ep)
	if !ok {
		return prim.INVALID_FD, .Invalid
	}
	if ep.family == .Unix {
		_unlink_stale(ep)
	}
	s := _socket(ep) or_return
	if win.bind(s, (^win.SOCKADDR_STORAGE_LH)(&sa), n) != 0 {
		e := _last()
		win.closesocket(s)
		return prim.INVALID_FD, e
	}
	if win.listen(s, win.SOMAXCONN) != 0 {
		e := _last()
		win.closesocket(s)
		return prim.INVALID_FD, e
	}
	return _sfd(s), .None
}

@(private)
_unlink_stale :: proc(ep: ^Endpoint) {
	sa, n, ok := _sockaddr(ep)
	if !ok {
		return
	}
	s := win.WSASocketW(W_AF_UNIX, W_SOCK_STREAM, 0, nil, 0, win.WSA_FLAG_NO_HANDLE_INHERIT)
	if s == win.INVALID_SOCKET {
		return
	}
	defer win.closesocket(s)
	if win.connect(s, (^win.SOCKADDR_STORAGE_LH)(&sa), n) != 0 && win.WSAGetLastError() == 10061 {
		prim.remove(prim.os_vfs(), string(ep.path[:ep.path_len]))
	}
}

@(private)
_accept :: proc "contextless" (lfd: prim.Fd) -> (prim.Fd, [16]u8, Error) {
	for {
		sa: _Sockaddr
		sl: i32 = size_of(sa)
		s := win.accept(_sock(lfd), (^win.SOCKADDR_STORAGE_LH)(&sa), &sl)
		if s == win.INVALID_SOCKET {
			code := win.WSAGetLastError()
			if code == 10054 || code == 10004 {
				continue
			}
			return prim.INVALID_FD, {}, _wsa_of(code)
		}
		src: [16]u8
		switch sa.fam {
		case W_AF_INET:
			src[10] = 0xff
			src[11] = 0xff
			copy(src[12:], sa.raw[4:8])
		case W_AF_INET6:
			copy(src[:], sa.raw[8:24])
		}
		if !_nonblock(s) {
			win.closesocket(s)
			continue
		}
		return _sfd(s), src, .None
	}
}

@(private)
_connect :: proc(ep: ^Endpoint) -> (fd: prim.Fd, pending: bool, err: Error) {
	sa, n, ok := _sockaddr(ep)
	if !ok {
		return prim.INVALID_FD, false, .Invalid
	}
	s := _socket(ep) or_return
	if win.connect(s, (^win.SOCKADDR_STORAGE_LH)(&sa), n) != 0 {
		code := win.WSAGetLastError()
		if code == 10035 || code == 10036 || code == 10037 {
			return _sfd(s), true, .None
		}
		win.closesocket(s)
		return prim.INVALID_FD, false, _wsa_of(code)
	}
	return _sfd(s), false, .None
}

@(private)
_socket_error :: proc "contextless" (fd: prim.Fd) -> Error {
	v: i32
	l: i32 = size_of(v)
	if win.getsockopt(_sock(fd), W_SOL_SOCKET, W_SO_ERROR, ([^]u8)(&v), &l) != 0 {
		return _last()
	}
	return _wsa_of(v)
}

@(private)
_tune_tcp :: proc "contextless" (fd: prim.Fd) {
	s := _sock(fd)
	one: i32 = 1
	idle: i32 = 120
	intvl: i32 = 30
	cnt: i32 = 4
	win.setsockopt(s, W_IPPROTO_TCP, W_TCP_NODELAY, &one, size_of(one))
	win.setsockopt(s, W_SOL_SOCKET, W_SO_KEEPALIVE, &one, size_of(one))
	win.setsockopt(s, W_IPPROTO_TCP, W_TCP_KEEPIDLE, &idle, size_of(idle))
	win.setsockopt(s, W_IPPROTO_TCP, W_TCP_KEEPINTVL, &intvl, size_of(intvl))
	win.setsockopt(s, W_IPPROTO_TCP, W_TCP_KEEPCNT, &cnt, size_of(cnt))
}

@(private)
_send :: proc "contextless" (fd: prim.Fd, data: []u8, more: bool) -> (int, Error) {
	n := win.send(_sock(fd), raw_data(data), i32(min(len(data), int(max(i32)))), 0)
	if n < 0 {
		return 0, _last()
	}
	return int(n), .None
}

@(private)
_recv :: proc "contextless" (fd: prim.Fd, buf: []u8) -> (int, Error) {
	n := win.recv(_sock(fd), raw_data(buf), i32(min(len(buf), int(max(i32)))), 0)
	if n < 0 {
		return 0, _last()
	}
	if n == 0 && len(buf) > 0 {
		return 0, .Closed
	}
	return int(n), .None
}

@(private)
_t_attach :: proc "contextless" (t: ^Transport, l: ^prim.Loop, w: prim.Watch) {
	t.os.port = win.HANDLE(uintptr(int(prim.loop_fd(l))))
	t.os.key = u64(w)
}

@(private)
_tx_done :: #force_inline proc "contextless" (tx: ^_Tx) -> bool {
	return uintptr(tx.ov.Internal) != W_STATUS_PENDING
}

@(private)
_t_sendfile :: proc(t: ^Transport, src: prim.Fd, off: i64, n: int) -> (int, Error) {
	o := &t.os
	if o.port == nil || o.key == 0 {
		return 0, .Unsupported
	}
	tx := &o.tx
	if tx.busy {
		if !_tx_done(tx) {
			return 0, .Would_Block
		}
		tx.busy = false
		if st := i32(uintptr(tx.ov.Internal)); st < 0 {
			return 0, .Closed
		}
	}
	if tx.event == nil {
		tx.event = win.CreateEventW(nil, true, false, nil)
		if tx.event == nil {
			return 0, .Unsupported
		}
	}
	if tx.packet == nil {
		if NtCreateWaitCompletionPacket(&tx.packet, W_GENERIC_ALL, nil) < 0 {
			tx.packet = nil
			return 0, .Unsupported
		}
	}
	NtCancelWaitCompletionPacket(tx.packet, true)
	win.ResetEvent(tx.event)
	k := min(n, 1 << 30)
	tx.ov = {}
	tx.ov.Offset = u32(u64(off) & 0xffff_ffff)
	tx.ov.OffsetHigh = u32(u64(off) >> 32)
	tx.ov.hEvent = tx.event
	if win.TransmitFile(_sock(t.fd), win.HANDLE(uintptr(int(src))), u32(k), 0, &tx.ov, nil, 0) {
		return k, .None
	}
	code := win.WSAGetLastError()
	if code != W_WSA_IO_PENDING {
		e := _wsa_of(code)
		if e == .Invalid || e == .Io {
			e = .Unsupported
		}
		return 0, e
	}
	tx.busy = true
	already: win.BOOLEAN
	NtAssociateWaitCompletionPacket(tx.packet, o.port, tx.event, rawptr(uintptr(o.key)), nil, 0, W_SOCK_NOTIFY_EVENT_OUT, &already)
	return k, .None
}

@(private)
_t_os_close :: proc "contextless" (t: ^Transport) {
	tx := &t.os.tx
	if tx.busy && !_tx_done(tx) && t.fd >= 0 {
		h := win.HANDLE(uintptr(int(t.fd)))
		win.CancelIoEx(h, &tx.ov)
		got: u32
		win.GetOverlappedResult(h, &tx.ov, &got, true)
	}
	tx.busy = false
	if tx.packet != nil {
		NtCancelWaitCompletionPacket(tx.packet, true)
		win.CloseHandle(tx.packet)
		tx.packet = nil
	}
	if tx.event != nil {
		win.CloseHandle(tx.event)
		tx.event = nil
	}
	t.os.port = nil
	t.os.key = 0
}

@(private)
_ktls_install :: proc "contextless" (fd: prim.Fd, keys: ^Session_Keys) -> (tx, rx: bool) {
	return false, false
}

@(private)
_token_user :: proc "contextless" (process: win.HANDLE, buf: []u8) -> (rawptr, bool) {
	tok: win.HANDLE
	if !win.OpenProcessToken(process, win.TOKEN_QUERY, &tok) {
		return nil, false
	}
	defer win.CloseHandle(tok)
	got: u32
	if !win.GetTokenInformation(tok, .TokenUser, raw_data(buf), u32(len(buf)), &got) {
		return nil, false
	}
	return (^win.TOKEN_USER)(raw_data(buf)).User.Sid, true
}

@(private)
_peer_is_self :: proc "contextless" (fd: prim.Fd) -> bool {
	pid: u32
	got: u32
	if win.WSAIoctl(_sock(fd), W_SIO_AF_UNIX_GETPEERPID, nil, 0, &pid, size_of(pid), &got, nil, nil) != 0 || pid == 0 {
		return false
	}
	if pid == win.GetCurrentProcessId() {
		return true
	}
	p := win.OpenProcess(W_PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if p == nil {
		return false
	}
	defer win.CloseHandle(p)
	theirs_buf: [256]u8
	ours_buf: [256]u8
	theirs, tok := _token_user(p, theirs_buf[:])
	if !tok {
		return false
	}
	ours, ook := _token_user(win.GetCurrentProcess(), ours_buf[:])
	if !ook {
		return false
	}
	return bool(EqualSid(theirs, ours))
}

@(private)
_shutdown :: proc "contextless" (fd: prim.Fd) {
	win.shutdown(_sock(fd), win.SD_BOTH)
}

@(private)
_raise_nofile :: proc "contextless" () -> int {
	return 16 * 1024 * 1024
}

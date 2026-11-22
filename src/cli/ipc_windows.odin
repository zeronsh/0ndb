package main

import "base:runtime"
import "core:os"
import "core:strconv"
import win "core:sys/windows"
import "core:thread"
import "../prim"

foreign import kernel_cli "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel_cli {
	InitializeProcThreadAttributeList :: proc(list: rawptr, count: u32, flags: u32, size: ^uint) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: u32, attribute: uintptr, value: rawptr, size: uint, prev: rawptr, ret: ^uint) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
	SetNamedPipeHandleState :: proc(pipe: win.HANDLE, mode: ^u32, max_collection: ^u32, timeout: ^u32) -> win.BOOL ---
	HeapCompact :: proc(heap: win.HANDLE, flags: u32) -> uint ---
}

Sock :: prim.Fd

NO_SOCK :: prim.INVALID_FD

Io_State :: enum u8 {
	Ok,
	Again,
	Eof,
	Fail,
}

@(private)
AF_UNIX_W :: 1
@(private)
FIONBIO_W :: 0x8004667e
@(private)
WSAEWOULDBLOCK_W :: 10035
@(private)
PROC_THREAD_ATTRIBUTE_HANDLE_LIST_W :: 0x20002
@(private)
EXTENDED_STARTUPINFO_PRESENT_W :: 0x80000
@(private)
CREATE_NO_WINDOW_W :: 0x08000000
@(private)
CREATE_NEW_PROCESS_GROUP_W :: 0x200
@(private)
CREATE_UNICODE_ENVIRONMENT_W :: 0x400
@(private)
STARTF_USESTDHANDLES_W :: 0x100

@(private)
_Sun :: struct {
	family: u16,
	path:   [108]u8,
}

@(private)
_Startup_Ex :: struct {
	si:    win.STARTUPINFOW,
	attrs: rawptr,
}

@(private)
_s :: #force_inline proc "contextless" (fd: Sock) -> win.SOCKET {
	return win.SOCKET(uintptr(int(fd)))
}

@(private)
_h :: #force_inline proc "contextless" (fd: Sock) -> win.HANDLE {
	return win.HANDLE(uintptr(int(fd)))
}

@(private)
_fd :: #force_inline proc "contextless" (s: uintptr) -> Sock {
	return Sock(i32(int(s)))
}

@(private)
_wsa_up :: proc "contextless" () {
	wsa: win.WSADATA
	win.WSAStartup(0x0202, &wsa)
}

@(private)
_sun :: proc(path: string) -> (sa: _Sun, ok: bool) {
	if len(path) == 0 || len(path) >= len(sa.path) {
		return sa, false
	}
	sa.family = AF_UNIX_W
	for i in 0 ..< len(path) {
		sa.path[i] = '\\' if path[i] == '/' else path[i]
	}
	return sa, true
}

@(private)
_unix_socket :: proc "contextless" (flags: u32) -> win.SOCKET {
	_wsa_up()
	return win.WSASocketW(AF_UNIX_W, win.SOCK_STREAM, 0, nil, 0, flags | win.WSA_FLAG_NO_HANDLE_INHERIT)
}

sock_connect :: proc(path: string) -> (Sock, bool) {
	sa, ok := _sun(path)
	if !ok {
		return NO_SOCK, false
	}
	s := _unix_socket(win.WSA_FLAG_OVERLAPPED)
	if s == win.INVALID_SOCKET {
		return NO_SOCK, false
	}
	if win.connect(s, (^win.SOCKADDR_STORAGE_LH)(&sa), size_of(sa)) != 0 {
		win.closesocket(s)
		return NO_SOCK, false
	}
	return _fd(uintptr(s)), true
}

@(private)
_nonblock :: proc "contextless" (s: win.SOCKET) -> bool {
	arg: u32 = 1
	if win.ioctlsocket(s, transmute(i32)u32(FIONBIO_W), &arg) != 0 {
		return false
	}
	win.SetHandleInformation(win.HANDLE(uintptr(s)), win.HANDLE_FLAG_INHERIT, 0)
	return true
}

sock_listen :: proc(path: string) -> (Sock, bool) {
	sa, ok := _sun(path)
	if !ok {
		return NO_SOCK, false
	}
	prim.remove(prim.os_vfs(), path)
	s := _unix_socket(win.WSA_FLAG_OVERLAPPED)
	if s == win.INVALID_SOCKET {
		return NO_SOCK, false
	}
	if win.bind(s, (^win.SOCKADDR_STORAGE_LH)(&sa), size_of(sa)) != 0 || win.listen(s, 128) != 0 || !_nonblock(s) {
		win.closesocket(s)
		return NO_SOCK, false
	}
	return _fd(uintptr(s)), true
}

sock_accept :: proc(l: Sock) -> (Sock, bool) {
	for {
		s := win.accept(_s(l), nil, nil)
		if s == win.INVALID_SOCKET {
			if win.WSAGetLastError() == 10054 {
				continue
			}
			return NO_SOCK, false
		}
		if !_nonblock(s) {
			win.closesocket(s)
			continue
		}
		return _fd(uintptr(s)), true
	}
}

sock_read :: proc(fd: Sock, buf: []u8) -> (int, Io_State) {
	n := win.recv(_s(fd), raw_data(buf), i32(min(len(buf), int(max(i32)))), 0)
	if n > 0 {
		return int(n), .Ok
	}
	if n == 0 {
		return 0, .Eof
	}
	if win.WSAGetLastError() == WSAEWOULDBLOCK_W {
		return 0, .Again
	}
	return 0, .Fail
}

sock_write :: proc(fd: Sock, data: []u8) -> (int, Io_State) {
	n := win.send(_s(fd), raw_data(data), i32(min(len(data), int(max(i32)))), 0)
	if n >= 0 {
		return int(n), .Ok
	}
	if win.WSAGetLastError() == WSAEWOULDBLOCK_W {
		return 0, .Again
	}
	return 0, .Fail
}

sock_write_all :: proc(fd: Sock, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, st := sock_write(fd, data[off:])
		if st == .Again {
			sock_wait_writable(fd)
			continue
		}
		if st != .Ok {
			return false
		}
		off += n
	}
	return true
}

@(private)
sock_wait_writable :: proc(fd: Sock) {
	p := win.WSA_POLLFD {
		fd     = _s(fd),
		events = win.POLLWRNORM,
	}
	win.WSAPoll(&p, 1, -1)
}

sock_wait :: proc(fd: Sock, timeout_ms: i64) -> bool {
	p := win.WSA_POLLFD {
		fd     = _s(fd),
		events = win.POLLRDNORM,
	}
	return win.WSAPoll(&p, 1, i32(min(timeout_ms, i64(max(i32))))) != 0
}

sock_close :: proc(fd: Sock) {
	if fd != NO_SOCK {
		win.closesocket(_s(fd))
	}
}

sock_unlink :: proc(path: string) {
	prim.remove(prim.os_vfs(), path)
}

sock_dup :: proc(fd: Sock) -> (Sock, bool) {
	return fd, true
}

self_pid :: proc() -> u64 {
	return u64(win.GetCurrentProcessId())
}

pid_running :: proc(pid: u64) -> bool {
	if pid == 0 {
		return false
	}
	p := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, u32(pid))
	if p == nil {
		return false
	}
	defer win.CloseHandle(p)
	return win.WaitForSingleObject(p, 0) == win.WAIT_TIMEOUT
}

ignore_broken_pipes :: proc() {
}

watch_fd :: #force_inline proc "contextless" (s: Sock) -> prim.Fd {
	return s
}

@(private)
_wide :: proc(s: string) -> win.wstring {
	return win.utf8_to_wstring(s, context.temp_allocator)
}

@(private)
_quote_arg :: proc(b: ^[dynamic]u8, arg: string) {
	append(b, '"')
	slashes := 0
	for i in 0 ..< len(arg) {
		ch := arg[i]
		if ch == '\\' {
			slashes += 1
			continue
		}
		for _ in 0 ..< (2 * slashes + 1 if ch == '"' else slashes) {
			append(b, '\\')
		}
		append(b, ch)
		slashes = 0
	}
	for _ in 0 ..< 2 * slashes {
		append(b, '\\')
	}
	append(b, '"')
}

spawn_daemon :: proc(exe: string, log_path: string, extra: []string = nil) -> bool {
	sa := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	rd, wr: win.HANDLE
	if !win.CreatePipe(&rd, &wr, &sa, 0) {
		return false
	}
	defer win.CloseHandle(rd)
	win.SetHandleInformation(rd, win.HANDLE_FLAG_INHERIT, 0)
	log := win.CreateFileW(_wide(log_path), win.FILE_APPEND_DATA | win.SYNCHRONIZE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, &sa, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	nul := win.CreateFileW(_wide("NUL"), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, &sa, win.OPEN_EXISTING, 0, nil)
	defer {
		if log != win.INVALID_HANDLE_VALUE {
			win.CloseHandle(log)
		}
		if nul != win.INVALID_HANDLE_VALUE {
			win.CloseHandle(nul)
		}
	}
	if nul == win.INVALID_HANDLE_VALUE {
		win.CloseHandle(wr)
		return false
	}
	out := log if log != win.INVALID_HANDLE_VALUE else nul
	inherit := [3]win.HANDLE{nul, out, wr}
	ninherit: uint = 3 if out != nul else 2
	if out == nul {
		inherit[1] = wr
	}
	size: uint
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	attrs := make([]u8, int(size), context.temp_allocator)
	if !InitializeProcThreadAttributeList(raw_data(attrs), 1, 0, &size) {
		win.CloseHandle(wr)
		return false
	}
	defer DeleteProcThreadAttributeList(raw_data(attrs))
	UpdateProcThreadAttribute(raw_data(attrs), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST_W, &inherit[0], ninherit * size_of(win.HANDLE), nil, nil)
	six := _Startup_Ex {
		si = {
			cb         = size_of(_Startup_Ex),
			dwFlags    = STARTF_USESTDHANDLES_W,
			hStdInput  = nul,
			hStdOutput = out,
			hStdError  = out,
		},
		attrs = raw_data(attrs),
	}
	cmd := make([dynamic]u8, context.temp_allocator)
	_quote_arg(&cmd, exe)
	append(&cmd, " daemon")
	for x in extra {
		append(&cmd, ' ')
		_quote_arg(&cmd, x)
	}
	cmdw := _wide(string(cmd[:]))
	val: [24]u8
	win.SetEnvironmentVariableW(_wide("ONDB_READY_FD"), _wide(strconv.write_uint(val[:], u64(uintptr(wr)), 10)))
	cwd := prim.dir_name(log_path)
	pi: win.PROCESS_INFORMATION
	flags: u32 = CREATE_NO_WINDOW_W | CREATE_NEW_PROCESS_GROUP_W | EXTENDED_STARTUPINFO_PRESENT_W | CREATE_UNICODE_ENVIRONMENT_W
	ok := win.CreateProcessW(_wide(exe), cmdw, nil, nil, true, flags | win.CREATE_BREAKAWAY_FROM_JOB, nil, _wide(cwd), &six.si, &pi)
	if !ok && win.GetLastError() == win.ERROR_ACCESS_DENIED {
		ok = win.CreateProcessW(_wide(exe), cmdw, nil, nil, true, flags, nil, _wide(cwd), &six.si, &pi)
	}
	win.SetEnvironmentVariableW(_wide("ONDB_READY_FD"), nil)
	win.CloseHandle(wr)
	if !ok {
		return false
	}
	win.CloseHandle(pi.hThread)
	defer win.CloseHandle(pi.hProcess)
	deadline := prim.mono_ns() + 15_000_000_000
	for prim.mono_ns() < deadline {
		avail: u32
		if !win.PeekNamedPipe(rd, nil, 0, nil, &avail, nil) {
			return false
		}
		if avail > 0 {
			b: [1]u8
			got: u32
			return bool(win.ReadFile(rd, &b[0], 1, &got, nil)) && got == 1 && b[0] == '1'
		}
		if win.WaitForSingleObject(pi.hProcess, 10) == win.WAIT_OBJECT_0 {
			return false
		}
	}
	return false
}

ready_notify :: proc() {
	v, ok := os.lookup_env("ONDB_READY_FD", context.temp_allocator)
	if !ok {
		return
	}
	win.SetEnvironmentVariableW(_wide("ONDB_READY_FD"), nil)
	n, nok := strconv.parse_u64(v)
	if !nok {
		return
	}
	h := win.HANDLE(uintptr(n))
	b := [1]u8{'1'}
	got: u32
	win.WriteFile(h, &b[0], 1, &got, nil)
	win.CloseHandle(h)
}

@(private)
_Bridge_In :: struct {
	sock: Sock,
	src:  win.HANDLE,
}

@(private)
_bridge_read :: proc(h: win.HANDLE, buf: []u8, ov: ^win.OVERLAPPED) -> int {
	got: u32
	if ov == nil {
		if !win.ReadFile(h, raw_data(buf), u32(len(buf)), &got, nil) {
			return -2 if win.GetLastError() == win.ERROR_INVALID_PARAMETER else -1
		}
		return int(got)
	}
	ov.Offset = 0
	ov.OffsetHigh = 0
	if !win.ReadFile(h, raw_data(buf), u32(len(buf)), &got, ov) {
		if win.GetLastError() != win.ERROR_IO_PENDING {
			return -1
		}
		if !win.GetOverlappedResult(h, ov, &got, true) {
			return -1
		}
	}
	return int(got)
}

@(private)
_bridge_in :: proc(b: _Bridge_In) {
	buf: [65536]u8
	ov: win.OVERLAPPED
	ovp: ^win.OVERLAPPED
	for {
		n := _bridge_read(b.src, buf[:], ovp)
		if n == -2 && ovp == nil {
			ov.hEvent = win.CreateEventW(nil, true, false, nil)
			ovp = &ov
			continue
		}
		if n <= 0 || !sock_write_all(b.sock, buf[:n]) {
			break
		}
	}
	win.shutdown(_s(b.sock), win.SD_SEND)
}

mcp_bridge :: proc(sock: Sock) -> int {
	src := win.GetStdHandle(win.STD_INPUT_HANDLE)
	dst := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	t := thread.create_and_start_with_poly_data(_Bridge_In{sock, src}, _bridge_in)
	_ = t
	buf: [65536]u8
	for {
		n := win.recv(_s(sock), raw_data(buf[:]), len(buf), 0)
		if n <= 0 {
			return 0
		}
		off: i32 = 0
		for off < n {
			w: u32
			if !win.WriteFile(dst, &buf[off], u32(n - off), &w, nil) {
				return 0
			}
			off += i32(w)
		}
	}
}

@(private)
_heap_compact :: proc "contextless" () {
	HeapCompact(win.GetProcessHeap(), 0)
}

@(private)
_pipe_pair :: proc() -> (r: win.HANDLE, w: win.HANDLE, ok: bool) {
	rnd: [8]u8
	runtime.rand_bytes(rnd[:])
	hex := "0123456789abcdef"
	name := make([dynamic]u8, context.temp_allocator)
	append(&name, `\\.\pipe\0ndb-cli-`)
	pid := win.GetCurrentProcessId()
	for s := 28; s >= 0; s -= 4 {
		append(&name, hex[(pid >> u32(s)) & 0xF])
	}
	append(&name, '-')
	for x in rnd {
		append(&name, hex[x >> 4], hex[x & 0xF])
	}
	wname := _wide(string(name[:]))
	r = win.CreateNamedPipeW(wname, 0x1 | win.FILE_FLAG_OVERLAPPED | 0x00080000, win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | 0x8, 1, 512, 512, 0, nil)
	if r == win.INVALID_HANDLE_VALUE {
		return nil, nil, false
	}
	w = win.CreateFileW(wname, win.GENERIC_WRITE | 0x80, 0, nil, win.OPEN_EXISTING, 0, nil)
	if w == win.INVALID_HANDLE_VALUE {
		win.CloseHandle(r)
		return nil, nil, false
	}
	mode: u32 = win.PIPE_READMODE_BYTE | 0x1
	SetNamedPipeHandleState(w, &mode, nil, nil)
	return r, w, true
}

Poll_Item :: struct {
	fd:    Sock,
	write: bool,
	ready: bool,
}

sock_poll :: proc(items: []Poll_Item, timeout_ms: i64) -> bool {
	pfds := make([]win.WSA_POLLFD, len(items), context.temp_allocator)
	for it, i in items {
		pfds[i] = win.WSA_POLLFD {
			fd     = _s(it.fd),
			events = win.POLLRDNORM | win.POLLWRNORM if it.write else win.POLLRDNORM,
		}
	}
	if win.WSAPoll(raw_data(pfds), u32(len(pfds)), i32(clamp(timeout_ms, 0, i64(max(i32))))) < 0 {
		return false
	}
	for &it, i in items {
		it.ready = pfds[i].revents != 0
	}
	return true
}

signals_sock :: proc(s: ^Signals) -> (Sock, bool) {
	return NO_SOCK, false
}

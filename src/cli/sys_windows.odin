package main

import "base:intrinsics"
import "core:strings"
import win "core:sys/windows"
import "../prim"

foreign import advapi_cli "system:Advapi32.lib"

@(default_calling_convention = "system")
foreign advapi_cli {
	EqualSid :: proc(a: rawptr, b: rawptr) -> win.BOOL ---
}

Signals :: struct {
	fd:   prim.Fd,
	w:    win.HANDLE,
	done: win.HANDLE,
}

@(private = "file")
_ctrl: struct {
	w:    win.HANDLE,
	done: win.HANDLE,
}

@(private = "file")
_ctrl_handler :: proc "system" (ev: u32) -> win.BOOL {
	w := intrinsics.atomic_load_explicit(&_ctrl.w, .Acquire)
	if w == nil {
		return false
	}
	b := [1]u8{u8(ev) + 1}
	got: u32
	win.WriteFile(w, &b[0], 1, &got, nil)
	switch ev {
	case win.CTRL_CLOSE_EVENT, win.CTRL_LOGOFF_EVENT, win.CTRL_SHUTDOWN_EVENT:
		if done := intrinsics.atomic_load_explicit(&_ctrl.done, .Acquire); done != nil {
			win.WaitForSingleObject(done, 4500)
		}
	}
	return true
}

signals_open :: proc(s: ^Signals) -> bool {
	r, w, ok := _pipe_pair()
	if !ok {
		return false
	}
	s.fd = prim.Fd(i32(int(uintptr(r))))
	s.w = w
	s.done = win.CreateEventW(nil, true, false, nil)
	intrinsics.atomic_store_explicit(&_ctrl.done, s.done, .Release)
	intrinsics.atomic_store_explicit(&_ctrl.w, w, .Release)
	if !win.SetConsoleCtrlHandler(_ctrl_handler, true) {
		signals_close(s)
		return false
	}
	return true
}

signals_read :: proc(s: ^Signals) -> (sig: int, ok: bool) {
	b: [1]u8
	n, err := prim.read(s.fd, b[:])
	if err != .None || n != 1 {
		return 0, false
	}
	return int(b[0]) - 1, true
}

signals_close :: proc(s: ^Signals) {
	if s.w == nil {
		return
	}
	win.SetConsoleCtrlHandler(_ctrl_handler, false)
	intrinsics.atomic_store_explicit(&_ctrl.w, nil, .Release)
	if s.done != nil {
		win.SetEvent(s.done)
	}
	win.CloseHandle(s.w)
	s.w = nil
	if s.fd != prim.INVALID_FD {
		prim.close(s.fd)
		s.fd = prim.INVALID_FD
	}
}

@(private = "file")
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

peer_is_self :: proc(fd: prim.Fd) -> bool {
	SIO_AF_UNIX_GETPEERPID :: 0x58000100
	pid, got: u32
	if win.WSAIoctl(win.SOCKET(uintptr(int(fd))), SIO_AF_UNIX_GETPEERPID, nil, 0, &pid, size_of(pid), &got, nil, nil) != 0 || pid == 0 {
		return false
	}
	if pid == win.GetCurrentProcessId() {
		return true
	}
	p := win.OpenProcess(0x1000, false, pid)
	if p == nil {
		return false
	}
	defer win.CloseHandle(p)
	a, b: [256]u8
	theirs, tok := _token_user(p, a[:])
	ours, ook := _token_user(win.GetCurrentProcess(), b[:])
	return tok && ook && bool(EqualSid(theirs, ours))
}

rss_bytes :: proc() -> i64 {
	pmc: win.PROCESS_MEMORY_COUNTERS
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), &pmc, size_of(pmc)) {
		return 0
	}
	return i64(pmc.WorkingSetSize)
}

idle_release :: proc() {
	_heap_compact()
	win.SetProcessWorkingSetSizeEx(win.GetCurrentProcess(), ~uint(0), ~uint(0), 0)
}

sys_hostname :: proc(allocator := context.allocator) -> string {
	v, ok := prim.getenv("COMPUTERNAME")
	if !ok {
		return ""
	}
	return strings.clone(v, allocator)
}

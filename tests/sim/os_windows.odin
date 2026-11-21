package sim

import "core:fmt"
import "core:strconv"
import win "core:sys/windows"
import "../../src/prim"

os_region_map :: proc(base: uintptr, size: uint) -> bool {
	ptr := win.VirtualAlloc(rawptr(base), size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
	if ptr == nil {
		return false
	}
	if uintptr(ptr) != base {
		win.VirtualFree(ptr, 0, win.MEM_RELEASE)
		return false
	}
	return true
}

os_region_unmap :: proc(base: uintptr, size: uint) {
	win.VirtualFree(rawptr(base), 0, win.MEM_RELEASE)
}

os_region_discard :: proc(base: uintptr, used: uint) {
}

loop_ready :: proc(l: ^prim.Loop) -> bool {
	return prim.loop_has_ready(l)
}

os_stats_write :: proc(fd: u64, data: []u8) {
	h := win.HANDLE(uintptr(fd))
	off := 0
	for off < len(data) {
		n: u32
		if !win.WriteFile(h, &data[off], u32(len(data) - off), &n, nil) || n == 0 {
			return
		}
		off += int(n)
	}
}

os_child_run :: proc(env_in: []string, buf: []u8) -> (got: int, sig: i32, code: i32, err: string) {
	sa := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	rd, wr: win.HANDLE
	if !win.CreatePipe(&rd, &wr, &sa, 0) {
		return 0, 0, 0, "pipe failed"
	}
	win.SetHandleInformation(rd, win.HANDLE_FLAG_INHERIT, 0)
	block := make([dynamic]u16, context.temp_allocator)
	put :: proc(b: ^[dynamic]u16, s: string) {
		w := win.utf8_to_utf16(s, context.temp_allocator)
		append(b, ..w)
		append(b, 0)
	}
	for kv in env_in {
		put(&block, kv)
	}
	val: [24]u8
	put(&block, fmt.tprintf("SIM_STATS_FD=%s", strconv.write_uint(val[:], u64(uintptr(wr)), 10)))
	append(&block, 0)
	exe: [32768]u16
	n := win.GetModuleFileNameW(nil, &exe[0], u32(len(exe)))
	if n == 0 || int(n) >= len(exe) {
		win.CloseHandle(rd)
		win.CloseHandle(wr)
		return 0, 0, 0, "cannot resolve the test executable"
	}
	cmd := make([dynamic]u16, context.temp_allocator)
	append(&cmd, '"')
	append(&cmd, ..exe[:n])
	append(&cmd, '"', 0)
	si := win.STARTUPINFOW {
		cb = size_of(win.STARTUPINFOW),
	}
	pi: win.PROCESS_INFORMATION
	ok := win.CreateProcessW(win.wstring(&exe[0]), win.wstring(raw_data(cmd)), nil, nil, true, win.CREATE_UNICODE_ENVIRONMENT, raw_data(block), nil, &si, &pi)
	win.CloseHandle(wr)
	if !ok {
		win.CloseHandle(rd)
		return 0, 0, 0, "spawn failed"
	}
	win.CloseHandle(pi.hThread)
	limit := u32(env_u64("SIM_CHILD_TIMEOUT", 300) * 1000)
	if win.WaitForSingleObject(pi.hProcess, limit) != win.WAIT_OBJECT_0 {
		win.TerminateProcess(pi.hProcess, 1)
		win.WaitForSingleObject(pi.hProcess, win.INFINITE)
		win.CloseHandle(rd)
		win.CloseHandle(pi.hProcess)
		return 0, 0, 0, fmt.tprintf("HUNG: no result after %d s (killed)", limit / 1000)
	}
	for got < len(buf) {
		r: u32
		if !win.ReadFile(rd, &buf[got], u32(len(buf) - got), &r, nil) || r == 0 {
			break
		}
		got += int(r)
	}
	win.CloseHandle(rd)
	win.WaitForSingleObject(pi.hProcess, win.INFINITE)
	status: u32
	win.GetExitCodeProcess(pi.hProcess, &status)
	win.CloseHandle(pi.hProcess)
	if status & 0xC000_0000 == 0xC000_0000 {
		return got, i32(status), 0, ""
	}
	return got, 0, i32(status & 0xff), ""
}

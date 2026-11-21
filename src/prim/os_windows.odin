package prim

import "base:runtime"
import win "core:sys/windows"

now_ns :: proc "contextless" () -> i64 {
	ft: win.FILETIME
	win.GetSystemTimePreciseAsFileTime(&ft)
	return _filetime_ns(i64(ft.dwHighDateTime) << 32 | i64(ft.dwLowDateTime))
}

now_ms :: proc "contextless" () -> i64 {
	return now_ns() / 1_000_000
}

mono_ns :: proc "contextless" () -> i64 {
	c, f: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&c)
	win.QueryPerformanceFrequency(&f)
	q := i64(c) / i64(f)
	r := i64(c) % i64(f)
	return q * 1_000_000_000 + r * 1_000_000_000 / i64(f)
}

os_vfs :: proc "contextless" () -> Vfs {
	return Vfs{procs = &OS_VFS_PROCS}
}

read_full :: proc(fd: Fd, buf: []u8) -> (int, Error) {
	n := 0
	for n < len(buf) {
		r, err := read(fd, buf[n:])
		if err != .None {
			return n, err
		}
		if r == 0 {
			break
		}
		n += r
	}
	return n, .None
}

getenv :: proc "contextless" (key: cstring) -> (string, bool) {
	context = runtime.default_context()
	k := string(key)
	if v, ok := _utf8_env(k, context.temp_allocator); ok {
		return v, true
	}
	if k == "HOME" {
		return _utf8_env("USERPROFILE", context.temp_allocator)
	}
	return "", false
}

data_dir :: proc(allocator := context.allocator) -> (string, Error) {
	if home, ok := _utf8_env("ONDB_HOME", context.temp_allocator); ok {
		return _clone(_slashes(home), allocator)
	}
	return _platform_data_dir(allocator)
}

runtime_dir :: proc(allocator := context.allocator) -> (dir: string, err: Error) {
	if explicit, ok := _utf8_env("ONDB_RUNTIME_DIR", context.temp_allocator); ok {
		return _clone(_slashes(explicit), allocator)
	}
	if home, ok := _utf8_env("ONDB_HOME", context.temp_allocator); ok {
		return path_join(allocator, _slashes(home), "run")
	}
	base := _platform_data_dir(context.temp_allocator) or_return
	return path_join(allocator, base, "run")
}

@(private)
_home :: proc() -> (string, Error) {
	home, ok := _utf8_env("USERPROFILE", context.temp_allocator)
	if !ok {
		return "", .Not_Found
	}
	return _slashes(home), .None
}

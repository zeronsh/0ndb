#+build linux, darwin
package prim

import "core:c/libc"
import "core:sys/posix"

now_ns :: proc "contextless" () -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.REALTIME, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}

now_ms :: proc "contextless" () -> i64 {
	return now_ns() / 1_000_000
}

mono_ns :: proc "contextless" () -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
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
	v := libc.getenv(key)
	if v == nil {
		return "", false
	}
	s := string(v)
	return s, len(s) > 0
}

data_dir :: proc(allocator := context.allocator) -> (string, Error) {
	if home, ok := getenv("ONDB_HOME"); ok {
		return _clone(home, allocator)
	}
	return _platform_data_dir(allocator)
}

runtime_dir :: proc(allocator := context.allocator) -> (dir: string, err: Error) {
	if explicit, ok := getenv("ONDB_RUNTIME_DIR"); ok {
		return _clone(explicit, allocator)
	}
	if home, ok := getenv("ONDB_HOME"); ok {
		return path_join(allocator, home, "run")
	}
	when ODIN_OS == .Linux {
		if xdg, ok := getenv("XDG_RUNTIME_DIR"); ok {
			return path_join(allocator, xdg, "0ndb")
		}
	}
	base := _platform_data_dir(context.temp_allocator) or_return
	return path_join(allocator, base, "run")
}

@(private)
_home :: proc "contextless" () -> (string, Error) {
	home, ok := getenv("HOME")
	if !ok {
		return "", .Not_Found
	}
	return home, .None
}


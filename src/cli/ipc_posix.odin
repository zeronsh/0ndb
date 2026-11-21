#+build linux, darwin
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "../prim"

Sock :: posix.FD

NO_SOCK :: Sock(-1)

Io_State :: enum u8 {
	Ok,
	Again,
	Eof,
	Fail,
}

sock_connect :: proc(path: string) -> (fd: Sock, ok: bool) {
	fd = posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, false
	}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		posix.close(fd)
		return -1, false
	}
	copy(addr.sun_path[:], path)
	if posix.connect(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

sock_listen :: proc(path: string) -> (Sock, bool) {
	posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return -1, false
	}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(path) >= len(addr.sun_path) {
		posix.close(fd)
		return -1, false
	}
	copy(addr.sun_path[:], path)
	old := posix.umask({.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	bok := posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK
	posix.umask(old)
	if !bok || posix.listen(fd, 128) != .OK {
		posix.close(fd)
		return -1, false
	}
	_nonblock(fd)
	return fd, true
}

sock_accept :: proc(l: Sock) -> (Sock, bool) {
	cfd := posix.accept(l, nil, nil)
	if cfd < 0 {
		return -1, false
	}
	_nonblock(cfd)
	return cfd, true
}

@(private)
_nonblock :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
}

sock_read :: proc(fd: Sock, buf: []u8) -> (int, Io_State) {
	for {
		n := posix.read(fd, raw_data(buf), len(buf))
		if n > 0 {
			return n, .Ok
		}
		if n == 0 {
			return 0, .Eof
		}
		e := posix.errno()
		if e == .EINTR {
			continue
		}
		if e == .EAGAIN || e == .EWOULDBLOCK {
			return 0, .Again
		}
		return 0, .Fail
	}
}

sock_write :: proc(fd: Sock, data: []u8) -> (int, Io_State) {
	for {
		n := posix.write(fd, raw_data(data), uint(len(data)))
		if n >= 0 {
			return n, .Ok
		}
		e := posix.errno()
		if e == .EINTR {
			continue
		}
		if e == .EAGAIN || e == .EWOULDBLOCK {
			return 0, .Again
		}
		return 0, .Fail
	}
}

sock_write_all :: proc(fd: Sock, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, st := sock_write(fd, data[off:])
		if st != .Ok {
			return false
		}
		off += n
	}
	return true
}

sock_wait :: proc(fd: Sock, timeout_ms: i64) -> bool {
	pfd := posix.pollfd{fd = fd, events = {.IN}}
	for {
		r := posix.poll(&pfd, 1, i32(min(timeout_ms, i64(max(i32)))))
		if r < 0 && posix.errno() == .EINTR {
			continue
		}
		return r != 0
	}
}

sock_close :: proc(fd: Sock) {
	if fd >= 0 {
		posix.close(fd)
	}
}

sock_unlink :: proc(path: string) {
	posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
}

sock_dup :: proc(fd: Sock) -> (Sock, bool) {
	out := posix.dup(fd)
	if out < 0 {
		return -1, false
	}
	posix.fcntl(out, .SETFD, posix.FD_CLOEXEC)
	return out, true
}

self_pid :: proc() -> u64 {
	return u64(posix.getpid())
}

ignore_broken_pipes :: proc() {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

spawn_daemon :: proc(exe: string, log_path: string) -> bool {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return false
	}
	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		return false
	}
	if pid == 0 {
		posix.close(fds[0])
		posix.setsid()
		null := posix.open("/dev/null", {.RDWR})
		logfd := posix.open(strings.clone_to_cstring(log_path, context.temp_allocator), {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR})
		if null >= 0 {
			posix.dup2(null, 0)
		}
		if logfd >= 0 {
			posix.dup2(logfd, 1)
			posix.dup2(logfd, 2)
		}
		posix.setenv("ONDB_READY_FD", strings.clone_to_cstring(fmt.tprintf("%d", fds[1]), context.temp_allocator), true)
		argv := [3]cstring{strings.clone_to_cstring(exe, context.temp_allocator), "daemon", nil}
		posix.execv(argv[0], raw_data(argv[:]))
		posix._exit(127)
	}
	posix.close(fds[1])
	pfd := posix.pollfd{fd = fds[0], events = {.IN}}
	ready := false
	for {
		r := posix.poll(&pfd, 1, 15_000)
		if r < 0 && posix.errno() == .EINTR {
			continue
		}
		if r > 0 {
			b: [1]u8
			n := posix.read(fds[0], raw_data(b[:]), 1)
			ready = n == 1 && b[0] == '1'
		}
		break
	}
	posix.close(fds[0])
	status: i32
	posix.waitpid(pid, &status, {.NOHANG})
	return ready
}

ready_notify :: proc() {
	v, ok := os.lookup_env("ONDB_READY_FD", context.temp_allocator)
	if !ok {
		return
	}
	n, nok := strconv.parse_int(v)
	if !nok {
		return
	}
	b := [1]u8{'1'}
	posix.write(posix.FD(n), raw_data(b[:]), 1)
	posix.close(posix.FD(n))
	posix.unsetenv("ONDB_READY_FD")
}

mcp_bridge :: proc(sock: Sock) -> int {
	fds := [2]posix.pollfd{{fd = 0, events = {.IN}}, {fd = sock, events = {.IN}}}
	buf: [65536]u8
	in_open := true
	for {
		fds[0].fd = 0 if in_open else -1
		if posix.poll(raw_data(fds[:]), 2, -1) < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return 1
		}
		if fds[0].revents != {} {
			n := posix.read(0, raw_data(buf[:]), len(buf))
			if n <= 0 {
				in_open = false
				posix.shutdown(sock, .WR)
			} else if !sock_write_all(sock, buf[:n]) {
				return 0
			}
		}
		if fds[1].revents != {} {
			n := posix.read(sock, raw_data(buf[:]), len(buf))
			if n <= 0 {
				return 0
			}
			if !sock_write_all(1, buf[:n]) {
				return 0
			}
		}
	}
}

watch_fd :: #force_inline proc "contextless" (s: Sock) -> prim.Fd {
	return prim.Fd(s)
}

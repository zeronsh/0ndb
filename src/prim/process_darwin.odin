package prim

import "core:c"
import "core:strings"
import "core:sys/posix"

spawn :: proc(
	argv: []string,
	cwd := "",
	env: []string = nil,
	new_process_group := false,
	pipes := ALL_PIPES,
) -> (
	child: Child,
	err: Error,
) {
	child = {
		stdin  = INVALID_FD,
		stdout = INVALID_FD,
		stderr = INVALID_FD,
		group  = new_process_group,
	}
	if len(argv) == 0 {
		return child, .Invalid
	}
	ta := context.temp_allocator
	path := _resolve_exec(argv[0], env, ta) or_return
	cargv := _cstrings(argv, ta) or_return
	cenv := posix.environ
	if env != nil {
		cenv = _cstrings(env, ta) or_return
	}
	ccwd: cstring
	if len(cwd) > 0 {
		cs, aerr := strings.clone_to_cstring(cwd, ta)
		if aerr != nil {
			return child, .No_Memory
		}
		ccwd = cs
	}

	inner := [3]posix.FD{-1, -1, -1}
	outer := [3]posix.FD{-1, -1, -1}
	report := [2]posix.FD{-1, -1}
	null_fd: posix.FD = -1
	defer {
		for fd in inner {
			if fd >= 0 && fd != null_fd {
				posix.close(fd)
			}
		}
		if null_fd >= 0 {
			posix.close(null_fd)
		}
		if report[0] >= 0 {
			posix.close(report[0])
		}
		if report[1] >= 0 {
			posix.close(report[1])
		}
		if err != .None {
			for fd in outer {
				if fd >= 0 {
					posix.close(fd)
				}
			}
		}
	}

	for i in 0 ..< 3 {
		if Pipe(i) in pipes {
			p: [2]posix.FD
			if posix.pipe(&p) != .OK {
				return child, _errno()
			}
			_set_cloexec(p[0])
			_set_cloexec(p[1])
			if i == 0 {
				inner[i], outer[i] = p[0], p[1]
			} else {
				inner[i], outer[i] = p[1], p[0]
			}
		} else {
			if null_fd < 0 {
				fd := posix.open("/dev/null", {.RDWR, .CLOEXEC})
				if fd < 0 {
					return child, _errno()
				}
				null_fd = fd
			}
			inner[i] = null_fd
		}
	}
	if posix.pipe(&report) != .OK {
		return child, _errno()
	}
	_set_cloexec(report[0])
	_set_cloexec(report[1])

	pid := posix.fork()
	if pid < 0 {
		return child, _errno()
	}
	if pid == 0 {
		_child_exec(path, cargv, cenv, ccwd, inner, report[1], new_process_group)
	}

	if new_process_group {
		posix.setpgid(pid, pid)
	}
	posix.close(report[1])
	report[1] = -1
	code: i32
	got := 0
	for got < 4 {
		b := ([^]u8)(&code)[got:4]
		n := posix.read(report[0], raw_data(b), uint(len(b)))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			break
		}
		got += int(n)
	}
	if got == 4 {
		st: c.int
		for posix.waitpid(pid, &st, {}) < 0 && posix.errno() == .EINTR {
		}
		err = _error(posix.Errno(code))
		if err == .None {
			err = .Io
		}
		return child, err
	}

	for fd in outer {
		if fd >= 0 {
			set_nonblocking(Fd(fd))
		}
	}
	child.pid = Pid(pid)
	child.stdin = Fd(outer[0])
	child.stdout = Fd(outer[1])
	child.stderr = Fd(outer[2])
	return child, .None
}

@(private)
_child_exec :: proc "contextless" (
	path: cstring,
	argv: [^]cstring,
	envp: [^]cstring,
	cwd: cstring,
	inner: [3]posix.FD,
	report: posix.FD,
	group: bool,
) -> ! {
	if group {
		posix.setpgid(0, 0)
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)
	moved: [3]posix.FD
	for i in 0 ..< 3 {
		moved[i] = posix.FD(posix.fcntl(inner[i], .DUPFD_CLOEXEC, c.int(3)))
		if moved[i] < 0 {
			_child_fail(report)
		}
	}
	for i in 0 ..< 3 {
		if posix.dup2(moved[i], posix.FD(i)) < 0 {
			_child_fail(report)
		}
	}
	if cwd != nil {
		if posix.chdir(cwd) != .OK {
			_child_fail(report)
		}
	}
	posix.execve(path, argv, envp)
	_child_fail(report)
}

@(private)
_child_fail :: proc "contextless" (report: posix.FD) -> ! {
	code := i32(posix.errno())
	b := transmute([4]u8)code
	posix.write(report, &b[0], 4)
	posix._exit(127)
}

kill_process :: proc "contextless" (pid: Pid, sig := Signal.Terminate) -> Error {
	if pid <= 0 {
		return .Invalid
	}
	if posix.kill(posix.pid_t(pid), posix.Signal(sig)) != .OK {
		return _errno()
	}
	return .None
}

kill_group :: proc "contextless" (pid: Pid, sig := Signal.Terminate) -> Error {
	if pid <= 0 {
		return .Invalid
	}
	if posix.kill(posix.pid_t(-pid), posix.Signal(sig)) != .OK {
		return _errno()
	}
	return .None
}

reap :: proc "contextless" (pid: Pid, block := false) -> (status: Exit_Status, done: bool, err: Error) {
	opts: posix.Wait_Flags
	if !block {
		opts += {.NOHANG}
	}
	st: c.int
	for {
		r := posix.waitpid(posix.pid_t(pid), &st, opts)
		if r < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			return {}, false, _error(e)
		}
		if r == 0 {
			return {}, false, .None
		}
		break
	}
	return _decode_wait(u32(st)), true, .None
}

package prim

import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

spawn :: proc(
	argv: []string,
	cwd := "",
	env: []string = nil,
	new_process_group := false,
	pipes := ALL_PIPES,
	pre_exec := Pre_Exec{},
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
		c, aerr := strings.clone_to_cstring(cwd, ta)
		if aerr != nil {
			return child, .No_Memory
		}
		ccwd = c
	}

	inner := [3]linux.Fd{-1, -1, -1}
	outer := [3]linux.Fd{-1, -1, -1}
	report := [2]linux.Fd{-1, -1}
	null_fd: linux.Fd = -1
	defer {
		for fd in inner {
			if fd >= 0 && fd != null_fd {
				linux.close(fd)
			}
		}
		if null_fd >= 0 {
			linux.close(null_fd)
		}
		if report[0] >= 0 {
			linux.close(report[0])
		}
		if report[1] >= 0 {
			linux.close(report[1])
		}
		if err != .None {
			for fd in outer {
				if fd >= 0 {
					linux.close(fd)
				}
			}
		}
	}

	for i in 0 ..< 3 {
		if Pipe(i) in pipes {
			p: [2]linux.Fd
			if errno := linux.pipe2(&p, {.CLOEXEC}); errno != .NONE {
				return child, _error(errno)
			}
			if i == 0 {
				inner[i], outer[i] = p[0], p[1]
			} else {
				inner[i], outer[i] = p[1], p[0]
			}
		} else {
			if null_fd < 0 {
				fd, errno := linux.open("/dev/null", {.RDWR, .CLOEXEC})
				if errno != .NONE {
					return child, _error(errno)
				}
				null_fd = fd
			}
			inner[i] = null_fd
		}
	}
	if errno := linux.pipe2(&report, {.CLOEXEC}); errno != .NONE {
		return child, _error(errno)
	}

	pid, ferr := linux.fork()
	if ferr != .NONE {
		return child, _error(ferr)
	}
	if pid == 0 {
		_child_exec(path, cargv, cenv, ccwd, inner, report[1], new_process_group, pre_exec)
	}

	if new_process_group {
		linux.setpgid(pid, pid)
	}
	linux.close(report[1])
	report[1] = -1
	code: i32
	got := 0
	for got < 4 {
		b := ([^]u8)(&code)[got:4]
		n, errno := linux.read(report[0], b)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE || n == 0 {
			break
		}
		got += n
	}
	if got == 4 {
		st: u32
		for {
			_, werr := linux.wait4(pid, &st, {}, nil)
			if werr != .EINTR {
				break
			}
		}
		err = _error(linux.Errno(code))
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
	inner: [3]linux.Fd,
	report: linux.Fd,
	group: bool,
	pre_exec: Pre_Exec,
) -> ! {
	errno: linux.Errno
	if group {
		linux.setpgid(0, 0)
	}
	act: linux.Sig_Action
	act.special = .SIG_DFL
	linux.rt_sigaction(.SIGPIPE, &act, nil)
	moved: [3]linux.Fd
	for i in 0 ..< 3 {
		moved[i], errno = linux.fcntl(inner[i], linux.F_DUPFD_CLOEXEC, 3)
		if errno != .NONE {
			_child_fail(report, errno)
		}
	}
	for i in 0 ..< 3 {
		if _, derr := linux.dup2(moved[i], linux.Fd(i)); derr != .NONE {
			_child_fail(report, derr)
		}
	}
	if cwd != nil {
		if cerr := linux.chdir(cwd); cerr != .NONE {
			_child_fail(report, cerr)
		}
	}
	if pre_exec.run != nil {
		if code := pre_exec.run(pre_exec.data); code != 0 {
			_child_fail(report, linux.Errno(code))
		}
	}
	errno = linux.execve(path, argv, envp)
	_child_fail(report, errno)
}

@(private)
_child_fail :: proc "contextless" (report: linux.Fd, errno: linux.Errno) -> ! {
	code := i32(errno)
	b := transmute([4]u8)code
	linux.write(report, b[:])
	linux.exit_group(127)
}

kill_process :: proc "contextless" (pid: Pid, sig := Signal.Terminate) -> Error {
	if pid <= 0 {
		return .Invalid
	}
	return _error(linux.kill(linux.Pid(pid), linux.Signal(sig)))
}

kill_group :: proc "contextless" (pid: Pid, sig := Signal.Terminate) -> Error {
	if pid <= 0 {
		return .Invalid
	}
	return _error(linux.kill(linux.Pid(-pid), linux.Signal(sig)))
}

reap :: proc "contextless" (pid: Pid, block := false) -> (status: Exit_Status, done: bool, err: Error) {
	opts: linux.Wait_Options
	if !block {
		opts += {.WNOHANG}
	}
	st: u32
	for {
		r, errno := linux.wait4(linux.Pid(pid), &st, opts, nil)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return {}, false, _error(errno)
		}
		if r == 0 {
			return {}, false, .None
		}
		break
	}
	return _decode_wait(st), true, .None
}

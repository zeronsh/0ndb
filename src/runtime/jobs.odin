package rt

import eng "../engine"
import "../fs"
import "../prim"
import "core:sys/posix"

Job_Done :: #type proc(j: ^Job, status: prim.Exit_Status)

Job :: struct {
	r:       ^Runtime,
	child:   prim.Child,
	w_out:   prim.Watch,
	w_err:   prim.Watch,
	w_in:    prim.Watch,
	cw:      prim.Child_Watch,
	timer:   prim.Timer,
	stdin:   [dynamic]u8,
	out:     [dynamic]u8,
	err:     [dynamic]u8,
	limit:   int,
	data:    rawptr,
	done:    Job_Done,
	exited:  bool,
	status:  prim.Exit_Status,
	out_eof: bool,
	err_eof: bool,
	killed:  bool,
	token:   u64,
}

JOB_OUTPUT_LIMIT :: 1 << 20

job_start :: proc(r: ^Runtime, req: ^Spawn_Request, stdin: []u8, data: rawptr, done: Job_Done, timeout_ms: i64 = 0, limit := JOB_OUTPUT_LIMIT) -> (j: ^Job, err: Error) {
	child, serr := r.cfg.spawner.spawn(r.cfg.spawner.data, req)
	if serr != .None {
		return nil, .Spawn
	}
	r.stats.spawns += 1
	j = new(Job, r.allocator)
	j.r = r
	j.child = child
	j.data = data
	j.done = done
	j.limit = limit
	j.out = make([dynamic]u8, r.allocator)
	j.err = make([dynamic]u8, r.allocator)
	j.stdin = make([dynamic]u8, r.allocator)
	append(&j.stdin, ..stdin)
	append(&r.jobs, j)
	l := eng.loop(r.e)
	if child.stdout >= 0 {
		prim.set_nonblocking(child.stdout)
		j.w_out, _ = prim.watch(l, child.stdout, {.Read}, j, _job_on_out)
	} else {
		j.out_eof = true
	}
	if child.stderr >= 0 {
		prim.set_nonblocking(child.stderr)
		j.w_err, _ = prim.watch(l, child.stderr, {.Read}, j, _job_on_err)
	} else {
		j.err_eof = true
	}
	if child.stdin >= 0 {
		if len(j.stdin) > 0 {
			prim.set_nonblocking(child.stdin)
			j.w_in, _ = prim.watch(l, child.stdin, {.Write}, j, _job_on_in)
		} else {
			prim.child_close_stdin(&j.child)
		}
	}
	j.cw, _ = prim.child_watch(l, child.pid, j, _job_on_exit)
	if timeout_ms > 0 {
		j.timer = prim.timer(l, timeout_ms, j, _job_on_timeout)
	}
	return j, .None
}

job_kill :: proc(j: ^Job) {
	if !j.exited && !j.killed {
		j.killed = true
		prim.child_kill(&j.child, .Kill)
	}
}

@(private)
_job_read :: proc(j: ^Job, fd: prim.Fd, dst: ^[dynamic]u8) -> bool {
	buf: [16384]u8
	for {
		n, err := prim.read(fd, buf[:])
		if err == .Would_Block || err == .Interrupted {
			return false
		}
		if err != .None || n == 0 {
			return true
		}
		room := j.limit - len(dst)
		if room > 0 {
			append(dst, ..buf[:min(n, room)])
		}
	}
}

@(private)
_job_on_out :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	j := (^Job)(data)
	if _job_read(j, fd, &j.out) {
		prim.unwatch(l, j.w_out)
		j.w_out = 0
		j.out_eof = true
		_job_check(j)
	}
}

@(private)
_job_on_err :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	j := (^Job)(data)
	if _job_read(j, fd, &j.err) {
		prim.unwatch(l, j.w_err)
		j.w_err = 0
		j.err_eof = true
		_job_check(j)
	}
}

@(private)
_job_on_in :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	j := (^Job)(data)
	for len(j.stdin) > 0 {
		n, err := prim.write(fd, j.stdin[:])
		if err == .Would_Block || err == .Interrupted {
			return
		}
		if err != .None || n <= 0 {
			clear(&j.stdin)
			break
		}
		remove_range(&j.stdin, 0, n)
	}
	prim.unwatch(l, j.w_in)
	j.w_in = 0
	prim.child_close_stdin(&j.child)
}

@(private)
_job_on_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	j := (^Job)(data)
	j.exited = true
	j.cw = 0
	j.status = status
	if !j.out_eof && j.child.stdout >= 0 {
		_job_read(j, j.child.stdout, &j.out)
	}
	if !j.err_eof && j.child.stderr >= 0 {
		_job_read(j, j.child.stderr, &j.err)
	}
	j.out_eof = true
	j.err_eof = true
	_job_check(j)
}

@(private)
_job_on_timeout :: proc(l: ^prim.Loop, data: rawptr) {
	j := (^Job)(data)
	j.timer = 0
	job_kill(j)
}

@(private)
_job_check :: proc(j: ^Job) {
	if !j.exited || !j.out_eof || !j.err_eof {
		return
	}
	if j.done != nil {
		j.done(j, j.status)
	}
	_job_free(j, false)
}

@(private)
_job_free :: proc(j: ^Job, kill: bool) {
	r := j.r
	l := eng.loop(r.e)
	if kill && !j.exited {
		prim.child_kill(&j.child, .Kill)
	}
	if j.w_out != 0 {
		prim.unwatch(l, j.w_out)
	}
	if j.w_err != 0 {
		prim.unwatch(l, j.w_err)
	}
	if j.w_in != 0 {
		prim.unwatch(l, j.w_in)
	}
	if j.cw != 0 {
		prim.child_unwatch(l, j.cw)
	}
	if j.timer != 0 {
		prim.timer_cancel(l, j.timer)
	}
	prim.child_close(&j.child)
	delete(j.out)
	delete(j.err)
	delete(j.stdin)
	for x, i in r.jobs {
		if x == j {
			ordered_remove(&r.jobs, i)
			break
		}
	}
	free(j, r.allocator)
}

run_blocking :: proc(r: ^Runtime, argv: []string, cwd: string) -> (status: prim.Exit_Status, out: []u8, err: Error) {
	req := Spawn_Request {
		argv = argv,
		cwd  = cwd,
		env  = r.cfg.env,
	}
	child, serr := r.cfg.spawner.spawn(r.cfg.spawner.data, &req)
	if serr != .None {
		return {}, nil, .Spawn
	}
	r.stats.spawns += 1
	defer prim.child_close(&child)
	prim.child_close_stdin(&child)
	buf := make([dynamic]u8, context.temp_allocator)
	tmp: [16384]u8
	fds: [2]posix.pollfd
	nfd := 0
	if child.stdout >= 0 {
		fds[nfd] = posix.pollfd{fd = posix.FD(child.stdout), events = {.IN}}
		nfd += 1
	}
	if child.stderr >= 0 {
		fds[nfd] = posix.pollfd{fd = posix.FD(child.stderr), events = {.IN}}
		nfd += 1
	}
	open_fds := nfd
	for open_fds > 0 {
		if posix.poll(raw_data(fds[:]), posix.nfds_t(nfd), -1) < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			break
		}
		for k in 0 ..< nfd {
			if fds[k].fd < 0 || fds[k].revents == {} {
				continue
			}
			n, rerr := prim.read(prim.Fd(fds[k].fd), tmp[:])
			if rerr == .Interrupted || rerr == .Would_Block {
				continue
			}
			if rerr != .None || n <= 0 {
				fds[k].fd = -1
				open_fds -= 1
				continue
			}
			if prim.Fd(fds[k].fd) == child.stdout && len(buf) < JOB_OUTPUT_LIMIT {
				append(&buf, ..tmp[:min(n, JOB_OUTPUT_LIMIT - len(buf))])
			}
		}
	}
	st, _, rerr := prim.reap(child.pid, true)
	if rerr != .None {
		return {}, buf[:], .Io
	}
	return st, buf[:], .None
}

fs_spawner :: proc(r: ^Runtime) -> fs.Spawner {
	return fs.Spawner{data = r, run = _fs_run}
}

@(private)
_fs_run :: proc(data: rawptr, argv: []string, cwd: string) -> fs.Error {
	r := (^Runtime)(data)
	st, _, err := run_blocking(r, argv, cwd)
	if err != .None {
		return .Io
	}
	if st.code != 0 || st.signal != 0 {
		return .Io
	}
	return .None
}

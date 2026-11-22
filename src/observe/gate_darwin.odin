#+build darwin
package observe

import "base:runtime"
import "core:c"
import "core:sys/posix"
import "../prim"

@(private)
SSTOP :: u32(4)

SUSP_GATE_MAX_MS :: 5_000

@(private)
SUSP_HELD_MAX :: 4096

@(private)
SUSP_STOP :: u32(1)

@(private)
SUSP_CONT :: u32(2)

@(private)
Susp_Rec :: struct {
	kind:      u32,
	pid:       i32,
	start_sec: u64,
	start_us:  u64,
}

@(private)
Susp_Gate :: struct {
	id:   u32,
	recs: [dynamic]Susp_Rec,
}

@(private)
Susp_Gates :: struct {
	gates:     [dynamic]Susp_Gate,
	next:      u32,
	ctl:       posix.FD,
	keeper_on: bool,
	spawns:    u64,
}

@(private)
_susp_info :: proc "contextless" (pid: i32) -> (info: Bsd_Info, ok: bool) {
	return info, proc_pidinfo(c.int(pid), PROC_PIDTBSDINFO, 0, &info, size_of(Bsd_Info)) == size_of(Bsd_Info)
}

@(private)
_susp_same :: proc "contextless" (r: Susp_Rec) -> (stopped: bool, same: bool) {
	info, ok := _susp_info(r.pid)
	if !ok || info.start_sec != r.start_sec || info.start_us != r.start_us {
		return false, false
	}
	return info.status == SSTOP, true
}

@(private)
_susp_read_full :: proc "contextless" (fd: posix.FD, r: ^Susp_Rec) -> bool {
	p := ([^]u8)(r)
	got := 0
	for got < size_of(Susp_Rec) {
		n := posix.read(fd, &p[got], uint(size_of(Susp_Rec) - got))
		if n > 0 {
			got += int(n)
			continue
		}
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		return false
	}
	return true
}

@(private)
_susp_keeper_main :: proc "contextless" (ctl: posix.FD, fd_max: posix.FD) -> ! {
	posix.setsid()
	for fd in posix.FD(0) ..< fd_max {
		if fd != ctl {
			posix.close(fd)
		}
	}
	mem := posix.mmap(nil, uint(SUSP_HELD_MAX * size_of(Susp_Rec)), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, -1, 0)
	if mem == posix.MAP_FAILED {
		posix._exit(1)
	}
	held := ([^]Susp_Rec)(mem)
	n := 0
	for {
		r: Susp_Rec
		if !_susp_read_full(ctl, &r) {
			break
		}
		if r.kind == SUSP_STOP && n < SUSP_HELD_MAX {
			held[n] = r
			n += 1
		} else if r.kind == SUSP_CONT {
			for i in 0 ..< n {
				if held[i].pid == r.pid && held[i].start_sec == r.start_sec && held[i].start_us == r.start_us {
					held[i] = held[n - 1]
					n -= 1
					break
				}
			}
		}
	}
	for i in 0 ..< n {
		if stopped, same := _susp_same(held[i]); same && stopped {
			posix.kill(posix.pid_t(held[i].pid), .SIGCONT)
		}
	}
	posix._exit(0)
}

@(private)
_susp_keeper_ensure :: proc(g: ^Susp_Gates) -> bool {
	if g.keeper_on {
		return true
	}
	fd_max := posix.FD(4096)
	lim: posix.rlimit
	if posix.getrlimit(.NOFILE, &lim) == .OK && lim.rlim_cur > 4096 {
		fd_max = posix.FD(min(lim.rlim_cur, 65536))
	}
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, {}, &fds) != .OK {
		return false
	}
	posix.fcntl(fds[0], .SETFD, c.int(posix.FD_CLOEXEC))
	posix.fcntl(fds[1], .SETFD, c.int(posix.FD_CLOEXEC))
	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		return false
	}
	if pid == 0 {
		if posix.fork() == 0 {
			_susp_keeper_main(fds[1], fd_max)
		}
		posix._exit(0)
	}
	posix.close(fds[1])
	st: c.int
	for posix.waitpid(pid, &st, {}) < 0 && posix.errno() == .EINTR {
	}
	g.ctl = fds[0]
	g.keeper_on = true
	g.spawns += 1
	for sg in g.gates {
		for r in sg.recs {
			if !_susp_send(g, SUSP_STOP, r) {
				return false
			}
		}
	}
	return true
}

@(private)
_susp_send :: proc(g: ^Susp_Gates, kind: u32, r: Susp_Rec) -> bool {
	if !g.keeper_on {
		return false
	}
	m := r
	m.kind = kind
	p := ([^]u8)(&m)
	sent := 0
	for sent < size_of(Susp_Rec) {
		n := posix.write(g.ctl, &p[sent], uint(size_of(Susp_Rec) - sent))
		if n > 0 {
			sent += int(n)
			continue
		}
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		posix.close(g.ctl)
		g.keeper_on = false
		return false
	}
	return true
}

@(private)
_susp_hold :: proc(g: ^Susp_Gates, r: Susp_Rec) -> bool {
	if _susp_send(g, SUSP_STOP, r) {
		return true
	}
	return _susp_keeper_ensure(g) && _susp_send(g, SUSP_STOP, r)
}

@(private)
_susp_gate :: proc(g: ^Susp_Gates, roots: []prim.Pid, root: string, exempt: []prim.Pid, allocator: runtime.Allocator) -> (id: u32, ok: bool) {
	if !_susp_keeper_ensure(g) {
		return 0, false
	}
	self := prim.Pid(getpid())
	sg := Susp_Gate{recs = make([dynamic]Susp_Rec, allocator)}
	queue := make([dynamic]prim.Pid, context.temp_allocator)
	kids: [512]c.int
	cb: [MAXPATHLEN]u8
	for root_pid in roots {
		if !_path_under(_cwd_of(root_pid, cb[:]), root) {
			continue
		}
		clear(&queue)
		append(&queue, root_pid)
		walk: for len(queue) > 0 {
			p := pop(&queue)
			if p <= 1 || p == self {
				continue
			}
			for e in exempt {
				if e == p {
					continue walk
				}
			}
			info, iok := _susp_info(i32(p))
			if !iok {
				continue
			}
			if info.status != SSTOP {
				r := Susp_Rec{pid = i32(p), start_sec = info.start_sec, start_us = info.start_us}
				if _susp_hold(g, r) {
					if posix.kill(posix.pid_t(p), .SIGSTOP) == .OK {
						append(&sg.recs, r)
					} else {
						_susp_send(g, SUSP_CONT, r)
					}
				}
			}
			n := proc_listchildpids(c.int(p), &kids[0], c.int(size_of(kids)))
			for i in 0 ..< max(int(n), 0) {
				if i < len(kids) && kids[i] > 1 {
					append(&queue, prim.Pid(kids[i]))
				}
			}
		}
	}
	g.next += 1
	if g.next == 0 {
		g.next = 1
	}
	sg.id = g.next
	if g.gates == nil {
		g.gates = make([dynamic]Susp_Gate, allocator)
	}
	append(&g.gates, sg)
	return sg.id, true
}

@(private)
_susp_ungate :: proc(g: ^Susp_Gates, id: u32) {
	for &sg, i in g.gates {
		if sg.id != id {
			continue
		}
		for r in sg.recs {
			if stopped, same := _susp_same(r); same && stopped {
				posix.kill(posix.pid_t(r.pid), .SIGCONT)
			}
			_susp_send(g, SUSP_CONT, r)
		}
		delete(sg.recs)
		unordered_remove(&g.gates, i)
		return
	}
}

@(private)
_susp_close :: proc(g: ^Susp_Gates) {
	for len(g.gates) > 0 {
		_susp_ungate(g, g.gates[0].id)
	}
	delete(g.gates)
	if g.keeper_on {
		posix.close(g.ctl)
		g.keeper_on = false
	}
}

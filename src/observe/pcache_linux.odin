#+build linux
package observe

import "base:intrinsics"
import "core:sys/linux"
import "../prim"

PCACHE_MAX :: 512
TCACHE_MAX :: 4096

@(private)
ESRCH :: 3

@(private)
Pentry :: struct {
	pidfd:     i32,
	cwd:       i32,
	chdir_tid: i32,
	nocwd:     bool,
	n:         int,
	lineage:   [MAX_LINEAGE]prim.Pid,
}

@(private)
Pcache :: struct {
	procs:   map[prim.Pid]^Pentry,
	threads: map[prim.Pid]prim.Pid,
}

@(private)
_pcache_init :: proc(s: ^Supervisor) {
	s.pc.procs = make(map[prim.Pid]^Pentry, s.allocator)
	s.pc.threads = make(map[prim.Pid]prim.Pid, s.allocator)
}

@(private)
_pentry_free :: proc(s: ^Supervisor, e: ^Pentry) {
	_sys_close(e.pidfd)
	_sys_close(e.cwd)
	free(e, s.allocator)
}

@(private)
_pcache_destroy :: proc(s: ^Supervisor) {
	for _, e in s.pc.procs {
		_pentry_free(s, e)
	}
	delete(s.pc.procs)
	delete(s.pc.threads)
}

@(private)
_alive :: proc "contextless" (pidfd: i32) -> bool {
	p := Pollfd{fd = pidfd, events = POLLIN}
	n, e := _sys_poll(&p, 1, 0)
	return e == 0 && (n == 0 || p.revents & POLLIN == 0)
}

@(private)
_tgid_of :: proc(s: ^Supervisor, tid: i32) -> (prim.Pid, bool) {
	if _errno(intrinsics.syscall(linux.SYS_tgkill, uintptr(int(tid)), uintptr(int(tid)), 0)) != ESRCH {
		return prim.Pid(tid), true
	}
	if g, ok := s.pc.threads[prim.Pid(tid)]; ok {
		if _errno(intrinsics.syscall(linux.SYS_tgkill, uintptr(int(g)), uintptr(int(tid)), 0)) != ESRCH {
			return g, true
		}
	}
	tgid, _, ok := _status_ids(tid, s.sc.file[:])
	if !ok {
		return 0, false
	}
	if len(s.pc.threads) >= TCACHE_MAX {
		clear(&s.pc.threads)
	}
	s.pc.threads[prim.Pid(tid)] = tgid
	return tgid, true
}

@(private)
_pcache_trim :: proc(s: ^Supervisor) {
	if len(s.pc.procs) < PCACHE_MAX {
		return
	}
	pfds := make([]Pollfd, len(s.pc.procs), context.temp_allocator)
	keys := make([]prim.Pid, len(s.pc.procs), context.temp_allocator)
	i := 0
	for k, e in s.pc.procs {
		pfds[i] = Pollfd{fd = e.pidfd, events = POLLIN}
		keys[i] = k
		i += 1
	}
	_sys_poll(raw_data(pfds), len(pfds), 0)
	for p, j in pfds {
		if p.revents & POLLIN != 0 {
			_pentry_free(s, s.pc.procs[keys[j]])
			delete_key(&s.pc.procs, keys[j])
		}
	}
	if len(s.pc.procs) >= PCACHE_MAX {
		for _, e in s.pc.procs {
			_pentry_free(s, e)
		}
		clear(&s.pc.procs)
	}
}

@(private)
_pentry :: proc(s: ^Supervisor, pid: prim.Pid, root: prim.Pid, depth: int) -> ^Pentry {
	if e, ok := s.pc.procs[pid]; ok {
		if _alive(e.pidfd) {
			return e
		}
		_pentry_free(s, e)
		delete_key(&s.pc.procs, pid)
	}
	_pcache_trim(s)
	r := intrinsics.syscall(linux.SYS_pidfd_open, uintptr(int(pid)), 0)
	if _errno(r) != 0 {
		return nil
	}
	pidfd := i32(int(r))
	ppid, pok := _stat_ppid(pid, s.sc.file[:])
	if !pok || !_alive(pidfd) {
		_sys_close(pidfd)
		return nil
	}
	parent: ^Pentry
	if pid != root && ppid > 1 && ppid != s.self && depth < MAX_LINEAGE - 1 {
		parent = _pentry(s, ppid, root, depth + 1)
	}
	e, aerr := new(Pentry, s.allocator)
	if aerr != nil {
		_sys_close(pidfd)
		return nil
	}
	e.pidfd = pidfd
	e.cwd = -1
	e.lineage[0] = pid
	e.n = 1
	if parent != nil {
		k := min(parent.n, MAX_LINEAGE - 1)
		copy(e.lineage[1:], parent.lineage[:k])
		e.n += k
	}
	s.pc.procs[pid] = e
	return e
}

@(private)
_pcache_lineage :: proc(s: ^Supervisor, tgid: prim.Pid, root: prim.Pid) -> ([]prim.Pid, ^Pentry) {
	l := s.sc.lineage[:]
	e := _pentry(s, tgid, root, 0)
	n := 0
	if e != nil {
		n = min(e.n, len(l) - 1)
		copy(l, e.lineage[:n])
	} else {
		l[0] = tgid
		n = 1
	}
	if l[n - 1] != root {
		l[n] = root
		n += 1
	}
	return l[:n], e
}

@(private)
_pcache_drop_cwds :: proc(s: ^Supervisor) {
	for _, e in s.pc.procs {
		_sys_close(e.cwd)
		e.cwd = -1
	}
}

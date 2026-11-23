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
	exec_tid:  i32,
	args:      []u8,
	args_ok:   bool,
	git:       i8,
	n:         int,
	lineage:   [MAX_LINEAGE]prim.Pid,
}

@(private)
Pcache :: struct {
	procs:   map[prim.Pid]^Pentry,
	threads: map[prim.Pid]prim.Pid,
}

@(private)
_pcache_init :: proc(t: ^Tree) {
	t.pc.procs = make(map[prim.Pid]^Pentry, t.alloc)
	t.pc.threads = make(map[prim.Pid]prim.Pid, t.alloc)
	t.wbuf = make([dynamic]u8, t.alloc)
}

@(private)
_pentry_free :: proc(t: ^Tree, e: ^Pentry) {
	_sys_close(e.pidfd)
	_sys_close(e.cwd)
	if e.args != nil {
		delete(e.args, t.alloc)
	}
	free(e, t.alloc)
}

@(private)
_pcache_destroy :: proc(t: ^Tree) {
	for mk2_ in prim.sorted_keys(t.pc.procs) {
		if mk2_ not_in t.pc.procs {
			continue
		}
		e := t.pc.procs[mk2_]
		_pentry_free(t, e)
	}
	delete(t.pc.procs)
	delete(t.pc.threads)
	delete(t.wbuf)
}

@(private)
_alive :: proc "contextless" (pidfd: i32) -> bool {
	p := Pollfd{fd = pidfd, events = POLLIN}
	n, e := _sys_poll(&p, 1, 0)
	return e == 0 && (n == 0 || p.revents & POLLIN == 0)
}

@(private)
_tgid_of :: proc(t: ^Tree, tid: i32) -> (prim.Pid, bool) {
	if _errno(intrinsics.syscall(linux.SYS_tgkill, uintptr(int(tid)), uintptr(int(tid)), 0)) != ESRCH {
		return prim.Pid(tid), true
	}
	if g, ok := t.pc.threads[prim.Pid(tid)]; ok {
		if _errno(intrinsics.syscall(linux.SYS_tgkill, uintptr(int(g)), uintptr(int(tid)), 0)) != ESRCH {
			return g, true
		}
	}
	tgid, _, ok := _status_ids(tid, t.sc.file[:])
	if !ok {
		return 0, false
	}
	if len(t.pc.threads) >= TCACHE_MAX {
		clear(&t.pc.threads)
	}
	t.pc.threads[prim.Pid(tid)] = tgid
	return tgid, true
}

@(private)
_pcache_trim :: proc(t: ^Tree) {
	if len(t.pc.procs) < PCACHE_MAX {
		return
	}
	pfds := make([]Pollfd, len(t.pc.procs), context.temp_allocator)
	keys := make([]prim.Pid, len(t.pc.procs), context.temp_allocator)
	i := 0
	for k, e in prim.unordered(t.pc.procs) {
		pfds[i] = Pollfd{fd = e.pidfd, events = POLLIN}
		keys[i] = k
		i += 1
	}
	_sys_poll(raw_data(pfds), len(pfds), 0)
	for p, j in pfds {
		if p.revents & POLLIN != 0 {
			_pentry_free(t, t.pc.procs[keys[j]])
			delete_key(&t.pc.procs, keys[j])
		}
	}
	if len(t.pc.procs) >= PCACHE_MAX {
		for mk1_ in prim.sorted_keys(t.pc.procs) {
			if mk1_ not_in t.pc.procs {
				continue
			}
			e := t.pc.procs[mk1_]
			_pentry_free(t, e)
		}
		clear(&t.pc.procs)
	}
}

@(private)
_pentry :: proc(t: ^Tree, pid: prim.Pid, root: prim.Pid, depth: int) -> ^Pentry {
	s := t.sup
	if e, ok := t.pc.procs[pid]; ok {
		if _alive(e.pidfd) {
			return e
		}
		_pentry_free(t, e)
		delete_key(&t.pc.procs, pid)
	}
	_pcache_trim(t)
	r := intrinsics.syscall(linux.SYS_pidfd_open, uintptr(int(pid)), 0)
	if _errno(r) != 0 {
		return nil
	}
	pidfd := i32(int(r))
	ppid, pok := _stat_ppid(pid, t.sc.file[:])
	if !pok || !_alive(pidfd) {
		_sys_close(pidfd)
		return nil
	}
	parent: ^Pentry
	if pid != root && ppid > 1 && ppid != s.self && depth < MAX_LINEAGE - 1 {
		parent = _pentry(t, ppid, root, depth + 1)
	}
	e, aerr := new(Pentry, t.alloc)
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
	t.pc.procs[pid] = e
	return e
}

@(private)
_pcache_lineage :: proc(t: ^Tree, tgid: prim.Pid, root: prim.Pid) -> ([]prim.Pid, ^Pentry) {
	l := t.sc.lineage[:]
	e := _pentry(t, tgid, root, 0)
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
_pcache_drop_cwds :: proc(t: ^Tree) {
	for mk1_ in prim.sorted_keys(t.pc.procs) {
		if mk1_ not_in t.pc.procs {
			continue
		}
		e := t.pc.procs[mk1_]
		_sys_close(e.cwd)
		e.cwd = -1
	}
}

@(private)
_pcache_git :: proc(t: ^Tree, lineage: []prim.Pid) -> bool {
	for pid in lineage {
		if pid == t.root {
			continue
		}
		e := t.pc.procs[pid]
		if e != nil && e.git != 0 && e.exec_tid == 0 {
			if e.git > 0 {
				return true
			}
			continue
		}
		pp: Proc_Path
		buf: [32]u8
		n, ok := _read_small(_pp_proc(&pp, i64(pid), "/comm"), buf[:])
		if !ok {
			continue
		}
		for n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == 0) {
			n -= 1
		}
		is_git := string(buf[:n]) == "git"
		if e != nil && e.exec_tid == 0 {
			e.git = 1 if is_git else -1
		}
		if is_git {
			return true
		}
	}
	return false
}

@(private)
_pcache_args :: proc(t: ^Tree, lineage: []prim.Pid) -> []u8 {
	n := len(lineage)
	if n < 2 || lineage[n - 1] != t.root || lineage[0] == t.root {
		return nil
	}
	child := lineage[n - 2]
	e := t.pc.procs[child]
	if e != nil && e.args_ok && e.exec_tid == 0 {
		return e.args
	}
	args, ok := process_args(child, t.sc.args[:])
	if !ok {
		return nil
	}
	if e == nil || e.exec_tid != 0 {
		return args
	}
	c, err := make([]u8, len(args), t.alloc)
	if err != nil {
		return args
	}
	copy(c, args)
	e.args = c
	e.args_ok = true
	return c
}

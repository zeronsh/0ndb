package fs

import "../prim"

Git_Proc :: struct {
	pid:    prim.Pid,
	holder: bool,
}

@(private)
Lock_Watch :: struct {
	pid: prim.Pid,
	cw:  prim.Child_Watch,
}

mount_git_lock :: proc(m: ^Mount, held: bool) {
	if !m.has_git || m.reg == nil {
		return
	}
	if !held {
		m.lock_stale = false
		_lock_lift(m)
		return
	}
	if m.git_locked {
		return
	}
	lock, jerr := path_join(m.git.dir, "index.lock", context.temp_allocator)
	if jerr != nil {
		return
	}
	roots := []string{m.root, m.git.dir, m.git.common}
	procs := git_lock_procs(lock, roots)
	obs := m.reg.observer
	if len(procs) == 0 && obs.lock_procs != nil {
		procs = obs.lock_procs(obs.data, lock, roots, context.temp_allocator)
	}
	if len(procs) == 0 {
		m.lock_stale = true
		return
	}
	m.lock_stale = false
	if m.reg.loop == nil {
		return
	}
	if m.lock_watches == nil {
		m.lock_watches = make([dynamic]Lock_Watch, m.allocator)
	}
	for p in procs {
		cw, werr := prim.child_watch(m.reg.loop, p.pid, m, _lock_creator_exit)
		if werr == .None {
			append(&m.lock_watches, Lock_Watch{pid = p.pid, cw = cw})
		}
	}
	if len(m.lock_watches) == 0 {
		return
	}
	m.git_locked = true
	m.lock_first = true
	mount_schedule(m, 0)
}

mount_lock_held :: proc "contextless" (m: ^Mount) -> bool {
	return m.git_locked && !m.lock_first
}

mount_lock_stale :: proc "contextless" (m: ^Mount) -> bool {
	return m.lock_stale
}

mount_unlock :: proc(m: ^Mount) {
	for w in m.lock_watches {
		prim.child_unwatch(m.reg.loop, w.cw)
	}
	clear(&m.lock_watches)
	m.git_locked = false
	m.lock_first = false
}

@(private)
_lock_lift :: proc(m: ^Mount) {
	if !m.git_locked {
		return
	}
	mount_unlock(m)
	mount_schedule(m, m.opts.settle_ms)
}

@(private)
_lock_creator_exit :: proc(l: ^prim.Loop, pid: prim.Pid, status: prim.Exit_Status, data: rawptr) {
	m := (^Mount)(data)
	for w, i in m.lock_watches {
		if w.pid == pid {
			unordered_remove(&m.lock_watches, i)
			break
		}
	}
	if len(m.lock_watches) > 0 {
		return
	}
	_lock_lift(m)
	if lock, jerr := path_join(m.git.dir, "index.lock", context.temp_allocator); jerr == nil && prim.exists(m.vfs, lock) {
		m.lock_stale = true
	}
}

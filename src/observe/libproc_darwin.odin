#+build darwin
package observe

import "base:runtime"
import "core:c"
import "../fs"
import "../prim"

Libproc :: struct {
	allocator: runtime.Allocator,
	router:    Router,
	sink:      Sink,
	roots:     [dynamic]prim.Pid,
	decider:   Decider,
	pids:      [MAX_LINEAGE]prim.Pid,
	stats:     Stats,
	susp:      Susp_Gates,
}

libproc_init :: proc(l: ^Libproc, allocator := context.allocator) {
	l^ = {
		allocator = allocator,
	}
	router_init(&l.router, allocator)
	l.roots = make([dynamic]prim.Pid, allocator)
}

libproc_destroy :: proc(l: ^Libproc) {
	_susp_close(&l.susp)
	router_destroy(&l.router)
	delete(l.roots)
	l^ = {}
}

libproc_set_sink :: proc(l: ^Libproc, sink: Sink) {
	l.sink = sink
}

libproc_add_root :: proc(l: ^Libproc, pid: prim.Pid) {
	for p in l.roots {
		if p == pid {
			return
		}
	}
	append(&l.roots, pid)
}

libproc_remove_root :: proc(l: ^Libproc, pid: prim.Pid) {
	for p, i in l.roots {
		if p == pid {
			unordered_remove(&l.roots, i)
			return
		}
	}
}

@(private)
_libproc_lock_procs :: proc(data: rawptr, lock: string, roots: []string, allocator: runtime.Allocator) -> []fs.Git_Proc {
	return _darwin_lock_procs(lock, roots, allocator)
}

libproc_observer :: proc(l: ^Libproc) -> fs.Write_Observer {
	return fs.Write_Observer{data = l, start = _libproc_start, stop = _libproc_stop, changed = _libproc_hook, fence = _libproc_fence, gate = _libproc_gate, ungate = _libproc_ungate, gate_max_ms = SUSP_GATE_MAX_MS, lock_procs = _libproc_lock_procs}
}

@(private)
_libproc_gate :: proc(data: rawptr, root: string, exempt: []prim.Pid) -> (u32, bool) {
	l := (^Libproc)(data)
	return _susp_gate(&l.susp, l.roots[:], root, exempt, l.allocator)
}

@(private)
_libproc_ungate :: proc(data: rawptr, id: u32) {
	l := (^Libproc)(data)
	_susp_ungate(&l.susp, id)
}

@(private)
_libproc_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	l := (^Libproc)(data)
	router_bind(&l.router, reg)
	return .None
}

@(private)
_libproc_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	l := (^Libproc)(data)
	if l.router.reg == reg {
		router_bind(&l.router, nil)
	}
}

Decider :: struct {
	data:   rawptr,
	decide: proc(data: rawptr, m: ^fs.Mount, w: ^Write) -> (^fs.Scope, bool),
}

libproc_set_decider :: proc(l: ^Libproc, d: Decider) {
	l.decider = d
}

libproc_changed :: proc(l: ^Libproc, m: ^fs.Mount, rel: string) -> (scope: ^fs.Scope, found: bool) {
	router_refresh(&l.router)
	base := ""
	for root in l.router.roots {
		if root.mount == m {
			base = root.real
			break
		}
	}
	if len(base) == 0 {
		return nil, false
	}
	full := make([]u8, len(base) + 1 + len(rel), context.temp_allocator)
	copy(full, base)
	full[len(base)] = '/'
	copy(full[len(base) + 1:], rel)
	w := Write {
		op   = .Write,
		path = string(full),
	}
	pid, flags, ok := libproc_writer(l, string(full))
	if ok {
		parent, _ := _parent_of(pid)
		n := _walk_lineage(pid, parent, l.pids[:])
		w.op = .Truncate if flags & O_TRUNC_DARWIN != 0 else .Write
		w.pid = pid
		w.tid = pid
		w.lineage = l.pids[:n]
		w.flags = flags
		w.exact = true
		for p in w.lineage {
			for r in l.roots {
				if p == r {
					w.tree = r
				}
			}
		}
		l.stats.reported += 1
	} else {
		if !_any_alive(l) {
			return nil, false
		}
		w.window = true
		l.stats.inexact += 1
	}
	if l.decider.decide != nil {
		return l.decider.decide(l.decider.data, m, &w)
	}
	if w.exact {
		return scope_of(l.router.reg, w.lineage), true
	}
	return nil, false
}

@(private)
_any_alive :: proc(l: ^Libproc) -> bool {
	for p in l.roots {
		if _, ok := _parent_of(p); ok {
			return true
		}
	}
	return false
}

libproc_writer :: proc(l: ^Libproc, path: string) -> (pid: prim.Pid, flags: u32, ok: bool) {
	l.stats.notifications += 1
	seen := make([dynamic]prim.Pid, context.temp_allocator)
	stack := make([dynamic]prim.Pid, context.temp_allocator)
	for p in l.roots {
		append(&stack, p)
	}
	if l.router.reg != nil {
		for s in l.router.reg.scopes {
			for p in s.pids {
				append(&stack, p)
			}
		}
	}
	kids := make([]c.int, 4096, context.temp_allocator)
	for len(stack) > 0 {
		cur := pop(&stack)
		dup := false
		for x in seen {
			if x == cur {
				dup = true
				break
			}
		}
		if dup || cur <= 1 {
			continue
		}
		append(&seen, cur)
		if f, hit := _has_open_for_write(cur, path); hit {
			return cur, f, true
		}
		n := proc_listchildpids(c.int(cur), raw_data(kids), c.int(len(kids) * size_of(c.int)))
		for i in 0 ..< int(max(n, 0)) {
			if i < len(kids) && kids[i] > 0 {
				append(&stack, prim.Pid(kids[i]))
			}
		}
	}
	l.stats.failed += 1
	return 0, 0, false
}

@(private)
_has_open_for_write :: proc(pid: prim.Pid, path: string) -> (u32, bool) {
	size := proc_pidinfo(c.int(pid), PROC_PIDLISTFDS, 0, nil, 0)
	if size <= 0 {
		return 0, false
	}
	count := int(size) / size_of(Proc_Fdinfo) + 16
	fds := make([]Proc_Fdinfo, count, context.temp_allocator)
	got := proc_pidinfo(c.int(pid), PROC_PIDLISTFDS, 0, raw_data(fds), c.int(count * size_of(Proc_Fdinfo)))
	if got <= 0 {
		return 0, false
	}
	vp: Vnode_Fdinfo_With_Path
	for fi in fds[:int(got) / size_of(Proc_Fdinfo)] {
		if fi.type != PROX_FDTYPE_VNODE {
			continue
		}
		if proc_pidfdinfo(c.int(pid), fi.fd, PROC_PIDFDVNODEPATHINFO, &vp, size_of(vp)) != size_of(vp) {
			continue
		}
		if vp.pfi.openflags & FWRITE == 0 {
			continue
		}
		nl := 0
		for nl < len(vp.path) && vp.path[nl] != 0 {
			nl += 1
		}
		if _strip_firmlink(string(vp.path[:nl])) == path {
			return vp.pfi.openflags, true
		}
	}
	return 0, false
}

@(private)
_libproc_hook :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	return libproc_changed((^Libproc)(data), m, rel)
}

@(private)
_libproc_fence :: proc(data: rawptr, reg: ^fs.Registry, done: proc(data: rawptr), done_data: rawptr) {
	done(done_data)
}

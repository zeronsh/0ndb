package observe

import "base:runtime"
import win "core:sys/windows"
import "../fs"
import "../prim"

@(private)
WINDOW_PROCESS_ACCESS :: 0x00100000 | 0x1000

Decider :: struct {
	data:   rawptr,
	decide: proc(data: rawptr, m: ^fs.Mount, w: ^Write) -> (^fs.Scope, bool),
}

@(private)
Window_Root :: struct {
	pid:    prim.Pid,
	handle: win.HANDLE,
}

Window :: struct {
	allocator: runtime.Allocator,
	router:    Router,
	sink:      Sink,
	roots:     [dynamic]Window_Root,
	decider:   Decider,
	stats:     Stats,
	susp:      Win_Gates,
}

window_init :: proc(w: ^Window, allocator := context.allocator) {
	w^ = {
		allocator = allocator,
	}
	router_init(&w.router, allocator)
	w.roots = make([dynamic]Window_Root, allocator)
}

window_destroy :: proc(w: ^Window) {
	for len(w.susp.gates) > 0 {
		_win_ungate(&w.susp, w.susp.gates[0].id)
	}
	delete(w.susp.gates)
	for r in w.roots {
		win.CloseHandle(r.handle)
	}
	router_destroy(&w.router)
	delete(w.roots)
	w^ = {}
}

window_set_sink :: proc(w: ^Window, sink: Sink) {
	w.sink = sink
}

window_set_decider :: proc(w: ^Window, d: Decider) {
	w.decider = d
}

window_add_root :: proc(w: ^Window, pid: prim.Pid) {
	_window_prune(w)
	for r in w.roots {
		if r.pid == pid {
			return
		}
	}
	h := win.OpenProcess(WINDOW_PROCESS_ACCESS, false, u32(pid))
	if h == nil {
		return
	}
	append(&w.roots, Window_Root{pid = pid, handle = h})
}

window_remove_root :: proc(w: ^Window, pid: prim.Pid) {
	for r, i in w.roots {
		if r.pid == pid {
			win.CloseHandle(r.handle)
			unordered_remove(&w.roots, i)
			return
		}
	}
}

window_live :: proc(w: ^Window) -> int {
	_window_prune(w)
	return len(w.roots)
}

window_observer :: proc(w: ^Window) -> fs.Write_Observer {
	return fs.Write_Observer{data = w, start = _window_start, stop = _window_stop, changed = _window_hook, fence = _window_fence, gate = _window_gate, ungate = _window_ungate, lock_procs = _window_lock_procs}
}

window_changed :: proc(w: ^Window, m: ^fs.Mount, rel: string) -> (scope: ^fs.Scope, found: bool) {
	w.stats.notifications += 1
	if window_live(w) == 0 {
		w.stats.ignored += 1
		return nil, false
	}
	router_refresh(&w.router)
	base := ""
	for root in w.router.roots {
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
	wr := Write {
		op     = .Write,
		path   = string(full),
		window = true,
	}
	w.stats.inexact += 1
	if w.decider.decide != nil {
		return w.decider.decide(w.decider.data, m, &wr)
	}
	return nil, false
}

@(private)
_window_prune :: proc(w: ^Window) {
	i := 0
	for i < len(w.roots) {
		if win.WaitForSingleObject(w.roots[i].handle, 0) == win.WAIT_OBJECT_0 {
			win.CloseHandle(w.roots[i].handle)
			unordered_remove(&w.roots, i)
			continue
		}
		i += 1
	}
}

@(private)
_window_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	w := (^Window)(data)
	router_bind(&w.router, reg)
	return .None
}

@(private)
_window_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	w := (^Window)(data)
	if w.router.reg == reg {
		router_bind(&w.router, nil)
	}
}

@(private)
_window_hook :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	return window_changed((^Window)(data), m, rel)
}

@(private)
_window_fence :: proc(data: rawptr, reg: ^fs.Registry, done: proc(data: rawptr), done_data: rawptr) {
	done(done_data)
}

@(private)
_window_gate :: proc(data: rawptr, root: string, exempt: []prim.Pid) -> (u32, bool) {
	w := (^Window)(data)
	pids := make([dynamic]prim.Pid, context.temp_allocator)
	for r in w.roots {
		append(&pids, r.pid)
	}
	return _win_gate(&w.susp, pids[:], exempt, w.allocator)
}

@(private)
_window_ungate :: proc(data: rawptr, id: u32) {
	w := (^Window)(data)
	_win_ungate(&w.susp, id)
}

@(private)
_window_lock_procs :: proc(data: rawptr, lock: string, roots: []string, allocator: runtime.Allocator) -> []fs.Git_Proc {
	return _win_lock_procs(lock, roots, allocator)
}

package rt

import eng "../engine"
import "../fs"
import "../observe"
import "../prim"

@(private)
Libproc_Spawn :: struct {
	r:        ^Runtime,
	l:        ^observe.Libproc,
	fallback: Spawner,
}

libproc_spawner :: proc(r: ^Runtime, l: ^observe.Libproc) -> Spawner {
	s := new(Libproc_Spawn, r.allocator)
	s.r = r
	s.l = l
	s.fallback = engine_spawner(r.e)
	observe.libproc_set_decider(l, libproc_decider(r))
	return Spawner{data = s, spawn = _libproc_spawn}
}

libproc_spawner_free :: proc(r: ^Runtime, sp: Spawner) {
	if sp.spawn == _libproc_spawn && sp.data != nil {
		s := (^Libproc_Spawn)(sp.data)
		if s.l.decider.data == r {
			observe.libproc_set_decider(s.l, {})
		}
		free(s, r.allocator)
	}
}

libproc_decider :: proc(r: ^Runtime) -> observe.Decider {
	return observe.Decider{data = r, decide = _libproc_decide}
}

@(private)
_libproc_spawn :: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	context = eng.context_for((^Libproc_Spawn)(data).r.e)
	s := (^Libproc_Spawn)(data)
	child, err := s.fallback.spawn(s.fallback.data, req)
	if err == .None && req.observe {
		observe.libproc_add_root(s.l, child.pid)
	}
	return child, err
}

@(private)
_libproc_decide :: proc(data: rawptr, m: ^fs.Mount, w: ^observe.Write) -> (^fs.Scope, bool) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	for run in r.runs {
		if !_run_has_mount(run, m) {
			continue
		}
		calls, idx := _open_calls(run)
		if w.exact {
			pid := prim.Pid(0)
			if run.proc_ != nil && run.proc_.child.pid > 0 {
				pid = run.proc_.child.pid
			}
			inside := pid > 0 && w.pid == pid
			for p in w.lineage {
				inside ||= pid > 0 && p == pid
			}
			if !inside {
				continue
			}
			k, ambiguous := observe.attribute(calls, w, pid)
			if s := _run_scope(run, m, idx[k] if k >= 0 && !ambiguous else -1); s != nil {
				return s, true
			}
			continue
		}
	}
	if w.exact {
		if s := observe.scope_of(m.reg if m != nil else nil, w.lineage); s != nil && s.mount == m {
			return s, true
		}
	}
	return nil, false
}

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
	return window_decide((^Runtime)(data), m, w)
}

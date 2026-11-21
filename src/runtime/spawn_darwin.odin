package rt

import "../observe"
import "../prim"

@(private)
Libproc_Spawn :: struct {
	l:        ^observe.Libproc,
	fallback: Spawner,
}

libproc_spawner :: proc(r: ^Runtime, l: ^observe.Libproc) -> Spawner {
	s := new(Libproc_Spawn, r.allocator)
	s.l = l
	s.fallback = engine_spawner(r.e)
	return Spawner{data = s, spawn = _libproc_spawn}
}

libproc_spawner_free :: proc(r: ^Runtime, sp: Spawner) {
	if sp.spawn == _libproc_spawn && sp.data != nil {
		free((^Libproc_Spawn)(sp.data), r.allocator)
	}
}

@(private)
_libproc_spawn :: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	s := (^Libproc_Spawn)(data)
	child, err := s.fallback.spawn(s.fallback.data, req)
	if err == .None && req.observe {
		observe.libproc_add_root(s.l, child.pid)
	}
	return child, err
}

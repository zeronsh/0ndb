package rt

import "../observe"
import "../prim"

@(private)
Supervised :: struct {
	sup:      ^observe.Supervisor,
	fallback: Spawner,
}

supervised_spawner :: proc(r: ^Runtime, sup: ^observe.Supervisor) -> Spawner {
	s := new(Supervised, r.allocator)
	s.sup = sup
	s.fallback = engine_spawner(r.e)
	return Spawner{data = s, spawn = _supervised_spawn}
}

supervised_spawner_free :: proc(r: ^Runtime, sp: Spawner) {
	if sp.spawn == _supervised_spawn && sp.data != nil {
		free((^Supervised)(sp.data), r.allocator)
	}
}

@(private)
_supervised_spawn :: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	s := (^Supervised)(data)
	opts := observe.Spawn_Options {
		cwd               = req.cwd,
		env               = _env_merge(req.env),
		new_process_group = req.new_group,
		pipes             = prim.ALL_PIPES,
		observation       = .Observed if req.observe else .Unobserved,
	}
	child, err := observe.spawn_with(s.sup, req.argv, opts)
	if err == .Permission || err == .Unsupported || err == .Invalid {
		opts.observation = .Unobserved
		return observe.spawn_with(s.sup, req.argv, opts)
	}
	return child, err
}

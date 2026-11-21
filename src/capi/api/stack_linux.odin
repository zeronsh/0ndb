package api

import "../../fs"
import "../../observe"
import rt "../../runtime"

Observer :: observe.Supervisor

@(private)
_observer_init :: proc(s: ^Stack) -> bool {
	return observe.supervisor_init(&s.obs, &s.loop, observe.DEFAULT_SUPERVISOR, s.allocator) == .None
}

@(private)
_observer_plug :: proc(s: ^Stack) -> fs.Write_Observer {
	return observe.write_observer(&s.obs)
}

@(private)
_observer_spawner :: proc(s: ^Stack) -> rt.Spawner {
	return rt.supervised_spawner(&s.r, &s.obs)
}

@(private)
_observer_sink :: proc(s: ^Stack) {
	observe.supervisor_set_sink(&s.obs, rt.observe_sink(&s.r))
}

@(private)
_observer_destroy :: proc(s: ^Stack) {
	observe.supervisor_destroy(&s.obs)
}

@(private)
_observer_spawner_free :: proc(s: ^Stack) {
	rt.supervised_spawner_free(&s.r, s.spawner)
}

@(private)
_observer_unsink :: proc(s: ^Stack) {
	observe.supervisor_set_sink(&s.obs, {})
}

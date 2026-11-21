package api

import "../../fs"
import "../../observe"
import rt "../../runtime"

Observer :: observe.Libproc

@(private)
_observer_init :: proc(s: ^Stack) -> bool {
	observe.libproc_init(&s.obs, s.allocator)
	return true
}

@(private)
_observer_plug :: proc(s: ^Stack) -> fs.Write_Observer {
	return observe.libproc_observer(&s.obs)
}

@(private)
_observer_spawner :: proc(s: ^Stack) -> rt.Spawner {
	return rt.libproc_spawner(&s.r, &s.obs)
}

@(private)
_observer_sink :: proc(s: ^Stack) {
	observe.libproc_set_sink(&s.obs, rt.observe_sink(&s.r))
}

@(private)
_observer_destroy :: proc(s: ^Stack) {
	observe.libproc_destroy(&s.obs)
}

@(private)
_observer_spawner_free :: proc(s: ^Stack) {
	rt.libproc_spawner_free(&s.r, s.spawner)
}

@(private)
_observer_unsink :: proc(s: ^Stack) {
	observe.libproc_set_sink(&s.obs, {})
}

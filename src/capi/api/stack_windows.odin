package api

import "../../fs"
import "../../observe"
import rt "../../runtime"

Observer :: struct {
	win: observe.Window,
}

@(private)
_observer_init :: proc(s: ^Stack) -> bool {
	observe.window_init(&s.obs.win, s.allocator)
	return true
}

@(private)
_observer_plug :: proc(s: ^Stack) -> fs.Write_Observer {
	return observe.window_observer(&s.obs.win)
}

@(private)
_observer_spawner :: proc(s: ^Stack) -> rt.Spawner {
	return rt.window_spawner(&s.r, &s.obs.win)
}

@(private)
_observer_sink :: proc(s: ^Stack) {
	observe.window_set_sink(&s.obs.win, rt.observe_sink(&s.r))
}

@(private)
_observer_destroy :: proc(s: ^Stack) {
	observe.window_destroy(&s.obs.win)
}

@(private)
_observer_spawner_free :: proc(s: ^Stack) {
	rt.window_spawner_free(&s.r, s.spawner)
}

@(private)
_observer_unsink :: proc(s: ^Stack) {
	observe.window_set_sink(&s.obs.win, {})
}

package api

import "../../fs"
import "../../observe"
import rt "../../runtime"

Observer :: struct {
	lp:    observe.Libproc,
	es:    observe.Endpoint,
	es_on: bool,
}

@(private)
_observer_init :: proc(s: ^Stack) -> bool {
	observe.libproc_init(&s.obs.lp, s.allocator)
	if observe.endpoint_init(&s.obs.es, &s.loop, s.allocator) == .None {
		s.obs.es_on = true
		observe.endpoint_set_fallback(&s.obs.es, &s.obs.lp)
	}
	return true
}

@(private)
_observer_plug :: proc(s: ^Stack) -> fs.Write_Observer {
	if s.obs.es_on {
		return observe.endpoint_observer(&s.obs.es)
	}
	return observe.libproc_observer(&s.obs.lp)
}

@(private)
_observer_spawner :: proc(s: ^Stack) -> rt.Spawner {
	return rt.libproc_spawner(&s.r, &s.obs.lp)
}

@(private)
_observer_sink :: proc(s: ^Stack) {
	sink := rt.observe_sink(&s.r)
	observe.libproc_set_sink(&s.obs.lp, sink)
	if s.obs.es_on {
		observe.endpoint_set_sink(&s.obs.es, sink)
	}
}

@(private)
_observer_destroy :: proc(s: ^Stack) {
	if s.obs.es_on {
		observe.endpoint_destroy(&s.obs.es)
		s.obs.es_on = false
	}
	observe.libproc_destroy(&s.obs.lp)
}

@(private)
_observer_spawner_free :: proc(s: ^Stack) {
	rt.libproc_spawner_free(&s.r, s.spawner)
}

@(private)
_observer_unsink :: proc(s: ^Stack) {
	observe.libproc_set_sink(&s.obs.lp, {})
	if s.obs.es_on {
		observe.endpoint_set_sink(&s.obs.es, {})
	}
}

package api

import "../../fs"
import rt "../../runtime"

Observer :: struct {}

@(private)
_observer_init :: proc(s: ^Stack) -> bool {
	return false
}

@(private)
_observer_plug :: proc(s: ^Stack) -> fs.Write_Observer {
	return {}
}

@(private)
_observer_spawner :: proc(s: ^Stack) -> rt.Spawner {
	return {}
}

@(private)
_observer_sink :: proc(s: ^Stack) {
}

@(private)
_observer_destroy :: proc(s: ^Stack) {
}

@(private)
_observer_spawner_free :: proc(s: ^Stack) {
}

@(private)
_observer_unsink :: proc(s: ^Stack) {
}

package sim

import "../../src/prim"

@(init)
_sources_init :: proc "contextless" () {
	register_world(-1000, _sources_on, _sources_off)
}

@(private = "file")
_sources_on :: proc(w: ^World) {
	prim.strict_sources = true
}

@(private = "file")
_sources_off :: proc(w: ^World) {
	prim.strict_sources = false
}

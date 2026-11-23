package sim

import eng "../../src/engine"

check_own_marked :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		list, err := eng.own_unmarked(&n.e, context.temp_allocator)
		if err != .None {
			continue
		}
		for x in list {
			world_fail(w, "own: %s holds %d durable bytes of its own %v %s that its registry does not mark own, so they are never uploaded", n.name, x.durable, x.kind, id_short(x.object))
		}
	}
}

@(init)
_own_marked_hooks :: proc "contextless" () {
	register_final_check(7, check_own_marked)
}

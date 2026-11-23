package sim

import eng "../../src/engine"

@(init)
_epochs_init :: proc "contextless" () {
	register_final_check(121, check_epochs)
}

check_epochs :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		notes, err := eng.verify_epochs(&n.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "epochs: %s verify failed: %v", n.name, err)
		}
		for x in notes {
			world_fail(w, "%s %s", n.name, x)
		}
		node_after(n)
	}
}

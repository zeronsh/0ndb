package sim

import "../../src/fs"

check_served_text :: proc(w: ^World) {
	for n in w.nodes {
		served_text_scan(w, n, "at the final check")
	}
}

served_text_scan :: proc(w: ^World, n: ^Node, when_: string) {
	if !n.alive || !n.e_open {
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	n.disk.quiet = true
	defer n.disk.quiet = false
	for id, h in n.e.handles {
		if h.hist == nil {
			continue
		}
		out := make([dynamic]string, context.temp_allocator)
		if fs.history_file_mismatches(h.hist, &out, context.temp_allocator) != .None {
			continue
		}
		for x in out {
			world_fail(w, "served text: %s history of %s %s: %s", n.name, id_short(id), when_, x)
		}
	}
}

@(init)
_served_text_hooks :: proc "contextless" () {
	register_final_check(3, check_served_text)
	register_restarted(60, proc(w: ^World, n: ^Node) {
		served_text_scan(w, n, "after a restart")
	})
}

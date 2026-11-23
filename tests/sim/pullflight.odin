package sim

import osync "../../src/sync"

check_pull_flights :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for _, sp in n.e.spaces {
			if !sp.repl_on {
				continue
			}
			check_pull_flights_repl(w, n, &sp.repl)
		}
	}
}

check_pull_flights_repl :: proc(w: ^World, n: ^Node, r: ^osync.Replicator) {
	why := "was never answered after the settle" if r.phase == .Ready else "outlived its connection"
	for _, rm in r.remotes {
		for p in rm.pulls {
			world_fail(w, "pull flight: %s pull of %s device %s %d..%d from holder %s tag %d %s (phase %v)", n.name, rm.name, id_short(rm.device), p.from, p.to, id_short(p.holder), p.tag, why, r.phase)
		}
	}
	for tag, j in r.objs.pulls {
		world_fail(w, "pull flight: %s object pipe pull tag %d from holder %s at %d %s (phase %v)", n.name, tag, id_short(j.p_holder), j.p_at, why, r.phase)
	}
}

@(init)
_pull_flight_hooks :: proc "contextless" () {
	register_final_check(4, check_pull_flights)
}

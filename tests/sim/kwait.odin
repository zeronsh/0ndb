package sim

import "../../src/journal"
import osync "../../src/sync"

check_kwait :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for _, sp in n.e.spaces {
			if !sp.repl_on {
				continue
			}
			check_kwait_repl(w, n, &sp.repl)
		}
	}
}

check_kwait_repl :: proc(w: ^World, n: ^Node, r: ^osync.Replicator) {
	for _, rm in r.remotes {
		if !rm.keys_wait || rm.kwait_head == {} || rm.quarantined {
			continue
		}
		head, ok := r.remotes[rm.kwait_head]
		if !ok {
			world_fail(w, "kwait: %s waits on keys for %s device %s through a keys head it no longer holds", n.name, rm.name, id_short(rm.device))
			continue
		}
		if !head.kfollow || journal.replica_length(&head.rep) <= 0 {
			continue
		}
		if _, kok := r.remotes[head.kstream]; head.kstream == {} || !kok {
			world_fail(w, "kwait: %s holds the keys head %s of device %s (%d bytes) but no keys stream remote while %s waits on keys", n.name, head.name, id_short(head.device), journal.replica_length(&head.rep), rm.name)
		}
	}
}

@(init)
_kwait_hooks :: proc "contextless" () {
	register_final_check(5, check_kwait)
}

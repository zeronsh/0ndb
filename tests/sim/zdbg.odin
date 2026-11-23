package sim

import "core:fmt"
import "../../src/journal"

check_zdbg :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for _, h in n.e.handles {
			if (h.kind != .File_Tree && h.kind != .Text) || h.hist == nil {
				continue
			}
			segs := ""
			for s in h.segs {
				segs = fmt.tprintf("%s [%s in_view %v follow %v]", segs, id_short(s.device), s.in_view, s.follow)
			}
			ap := fmt.tprintf("%v", h.hist.applied[:]) if h.hist.awake else "asleep"
			ids := ""
			if h.hist.awake {
				for id in h.hist.stream_ids {
					ids = fmt.tprintf("%s %s", ids, id_short(id))
				}
			}
			world_note(w, "DBGT %s %v %s awake %v published %d segs%s applied %s ids%s", n.name, h.kind, id_short(h.id), h.hist.awake, h.published, segs, ap, ids)
		}
		for _, sp in n.e.spaces {
			for _, rm in sp.repl.remotes {
				have := journal.replica_have(&rm.rep)
				got := i64(0)
				if len(have) > 0 && have[0].from == 0 {
					got = have[0].to
				}
				world_note(w, "DBGZ %s remote %s dev %s relay_len %d contiguous %d short %v have %v wants %v inflight %v pulls %v base %d pulled %d", n.name, rm.name, id_short(rm.device), rm.relay_len, got, rm.relay_len > got, have, rm.wants[:], rm.inflight[:], rm.pulls[:], rm.base, rm.pulled)
			}
		}
	}
}

@(init)
_zdbg :: proc "contextless" () {
	register_final_check(0, check_zdbg)
}

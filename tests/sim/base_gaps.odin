package sim

import "../../src/journal"
import osync "../../src/sync"

@(init)
_base_gaps_init :: proc "contextless" () {
	register_final_check(93, check_base_gaps)
}

check_base_gaps :: proc(w: ^World) {
	if w.aborted || len(w.failures) > 0 {
		return
	}
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		for _, sp in n.e.spaces {
			for _, rm in sp.repl.remotes {
				if !rm.full || !(rm.follow || rm.kfollow) || rm.quarantined || rm.base <= 0 {
					continue
				}
				have := journal.replica_have(&rm.rep)
				c := have[0].to if len(have) > 0 && have[0].from == 0 else 0
				if c >= rm.base || _gap_asked(rm, c, rm.base) {
					continue
				}
				world_fail(w, "base gap: %s follows %s's %s whole but holds only [0, %d) below base %d and nothing wants, pulls or reads the gap (trimmed %v)", n.name, id_short(rm.device), rm.name, c, rm.base, rm.trimmed)
			}
		}
		node_after(n)
	}
}

@(private = "file")
_gap_asked :: proc(rm: ^osync.Remote, from, to: i64) -> bool {
	for g in rm.wants {
		if g.from < to && from < g.to {
			return true
		}
	}
	for f in rm.inflight {
		if f.from < 0 || (f.from < to && from < f.to) {
			return true
		}
	}
	for p in rm.pulls {
		if p.from < to && from < p.to {
			return true
		}
	}
	return rm.arc != nil && len(rm.arc.wants) > 0
}

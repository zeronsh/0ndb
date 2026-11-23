package sim

import eng "../../src/engine"
import "../../src/journal"
import osync "../../src/sync"

check_replica_align :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for _, sp in n.e.spaces {
			if !sp.repl_on {
				continue
			}
			for id, rm in sp.repl.remotes {
				if rm.quarantined || len(journal.replica_have(&rm.rep)) == 0 {
					continue
				}
				wn: ^Node
				for x in w.nodes {
					if x.alive && x.e_open && x.identity.id == rm.device {
						wn = x
					}
				}
				if wn == nil {
					continue
				}
				bounds, end, ok := _align_bounds(wn, id)
				context = instance_context(&n.inst)
				if !ok {
					continue
				}
				for g in journal.replica_have(&rm.rep) {
					if !bounds[g.from] || !bounds[g.to] || g.to > end {
						world_fail(w, "replica: %s holds [%d,%d) of %s's %s, which is not a run of the writer's records (they end at %d; boundary at start %v, at end %v)", n.name, g.from, g.to, wn.name, rm.name, end, bounds[g.from], bounds[g.to])
					}
				}
			}
		}
	}
}

@(private = "file")
_align_bounds :: proc(wn: ^Node, id: osync.Stream_Id) -> (bounds: map[i64]bool, end: i64, ok: bool) {
	context = instance_context(&wn.inst)
	own, err := eng.own_lengths(&wn.e, context.temp_allocator)
	if err != .None {
		return
	}
	path := ""
	durable := i64(0)
	for o in own {
		if o.stream == id {
			path = o.path
			durable = o.durable
		}
	}
	if path == "" {
		return
	}
	rd: journal.Reader
	if journal.reader_open(&rd, wn.e.vfs, path, context.temp_allocator) != .None {
		return
	}
	defer journal.reader_close(&rd)
	bounds = make(map[i64]bool, context.temp_allocator)
	bounds[0] = true
	for {
		_, nxt, rerr := journal.record_at(&rd, end)
		if rerr != .None && rerr != .Redacted {
			break
		}
		end = nxt
		bounds[end] = true
	}
	return bounds, end, end == durable
}

@(init)
_replica_align_hooks :: proc "contextless" () {
	register_final_check(7, check_replica_align)
}

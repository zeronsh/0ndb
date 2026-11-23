package sim

import "../../src/fs"

STAT_PERSIST_OUTAGES: Stat
STAT_DEFERRED_CLOSES: Stat
EV_PERSIST_OUTAGE_END: Ev_Kind

@(init)
_persist_outage_init :: proc "contextless" () {
	register_op(14, "persist_outage", proc(w: ^World) -> int {return 1 if w.cfg.persist_fault else 0}, op_persist_outage)
	EV_PERSIST_OUTAGE_END = register_event(_persist_outage_end)
	register_final_check(12, check_applied_cursors)
	register_stat_line(54, "persist_outage")
	STAT_PERSIST_OUTAGES = register_stat(54, 0, "outages")
	STAT_DEFERRED_CLOSES = register_stat(54, 1, "deferred_closes")
}

op_persist_outage :: proc(w: ^World, n: ^Node) {
	if n.persist_outage || !n.alive {
		return
	}
	idx := -1
	for x, i in w.nodes {
		if x == n {
			idx = i
		}
	}
	if idx < 0 {
		return
	}
	n.persist_outage = true
	stat_add(w, STAT_PERSIST_OUTAGES)
	ms := rng_range(&w.fault_rng, 5_000, 120_000)
	world_note(w, "%s history persists fail for %d ms (injected)", n.name, ms)
	schedule(w, Sim_Event{at = w.now + ms * 1_000_000, kind = EV_PERSIST_OUTAGE_END, node = idx})
}

_persist_outage_end :: proc(w: ^World, ev: ^Sim_Event) {
	n := w.nodes[ev.node]
	n.persist_outage = false
	world_note(w, "%s history persists recover", n.name)
	_check_node_cursors(w, n)
}

check_applied_cursors :: proc(w: ^World) {
	for n in w.nodes {
		_check_node_cursors(w, n)
	}
}

_check_node_cursors :: proc(w: ^World, n: ^Node) {
	if !n.alive || n.disk.dead {
		return
	}
	context = instance_context(&n.inst)
	for id, h in n.e.handles {
		if h.hist == nil || !h.hist.awake {
			continue
		}
		for s in h.segs {
			if !s.in_view {
				continue
			}
			off, gap, _ := fs.history_applied_gap(h.hist, s.device, &s.jr)
			if gap {
				world_fail(w, "%s history of %s: applied cursor of stream %s is past record %d, which is not in the graph", n.name, id_short(id), id_short(s.device), off)
			}
		}
	}
	node_after(n)
}

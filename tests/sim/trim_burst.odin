package sim

import eng "../../src/engine"

STAT_TRIM_BUSY: Stat

@(init)
_trim_burst_init :: proc "contextless" () {
	register_final_check(92, check_trim_burst)
	STAT_TRIM_BUSY = register_stat(77, 15, "trims_refused_busy")
}

check_trim_burst :: proc(w: ^World) {
	if w.aborted || len(w.failures) > 0 || w.cfg.archive_min <= 0 || !w.relay.alive {
		return
	}
	m := &w.model
	n: ^Node
	oi := -1
	for op in m.ops {
		if op.kind != .Send || op.status != .Done || op.obj < 0 || !obj_exists(m, op.obj) {
			continue
		}
		cand := w.nodes[op.node]
		if _burst_online(cand) {
			n, oi = cand, op.obj
			break
		}
	}
	if n == nil {
		return
	}
	busy0 := w.relay.r.stats.trim_busy
	count := min(int(4 * w.cfg.archive_min / 48) + 16, 800)
	world_note(w, "trim burst: %s sends %d messages on %s to cut several archive groups while its uploads are in flight", n.name, count, id_short(m.objs[oi].o.id))
	o := m.objs[oi].o
	for _ in 0 ..< count {
		if !_burst_online(n) || len(w.failures) > 0 || w.aborted {
			return
		}
		send: {
			context = instance_context(&n.inst)
			op := new_op(m, .Send, n, oi)
			op.token = new_token(m, n, "m")
			rid, err := eng.convo_send(&n.e, o, msg_body(op.token), {}, nil, op_done_handle(op))
			if err != .Pending {
				op.rid = rid
			}
			op_result(op, n, err)
			node_after(n)
		}
		run_until(w, w.now + 3_000_000, false)
	}
	for _ in 0 ..< 4 {
		run_until(w, w.now + 60_000_000_000, true)
		if len(w.failures) > 0 || w.aborted {
			return
		}
	}
	stat_add(w, STAT_TRIM_BUSY, w.relay.r.stats.trim_busy - busy0)
}

@(private = "file")
_burst_online :: proc(n: ^Node) -> bool {
	return n.alive && n.e_open && !n.partitioned
}

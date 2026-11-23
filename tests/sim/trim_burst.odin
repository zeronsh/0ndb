package sim

import "../../src/arc"
import eng "../../src/engine"
import osync "../../src/sync"

STAT_TRIM_BUSY: Stat
STAT_TRIM_HELD: Stat

@(private = "file")
Burst_Hold :: struct {
	on:   bool,
	id:   osync.Stream_Id,
	from: i64,
}

@(private = "file")
@(thread_local)
_hold: Burst_Hold

@(init)
_trim_burst_init :: proc "contextless" () {
	register_final_check(92, check_trim_burst)
	register_world(70, proc(w: ^World) {
		_hold = {}
	})
	register_relay_commit_hold(10, proc(w: ^World, id: osync.Stream_Id, at: i64) -> bool {
		return _hold.on && id == _hold.id && at >= _hold.from
	})
	STAT_TRIM_BUSY = register_stat(77, 15, "trims_refused_busy")
	STAT_TRIM_HELD = register_stat(77, 16, "trim_holds")
}

check_trim_burst :: proc(w: ^World) {
	if w.aborted || len(w.failures) > 0 || w.cfg.archive_min <= 0 || !w.relay.alive {
		return
	}
	m := &w.model
	n: ^Node
	oi := -1
	for op in m.ops {
		if op.kind != .Send || (op.status != .Done && op.status != .Acked && op.status != .Observed) || op.obj < 0 || !obj_exists(m, op.obj) {
			continue
		}
		if cand := w.nodes[op.node]; _burst_online(cand) {
			n, oi = cand, op.obj
			break
		}
	}
	if n == nil {
		return
	}
	busy0 := w.relay.r.stats.trim_busy
	o := m.objs[oi].o
	count := min(int(4 * w.cfg.archive_min / 48) + 16, 800)
	world_note(w, "trim burst: %s sends %d messages on %s to cut several archive groups", n.name, count, id_short(o.id))
	for _ in 0 ..< count {
		if !_burst_send(w, n, oi) {
			return
		}
		run_until(w, w.now + 3_000_000, false)
	}
	if !_burst_settle(w) {
		return
	}
	seg, aid, ok := _burst_ids(n, o)
	if !ok {
		stat_add(w, STAT_TRIM_BUSY, w.relay.r.stats.trim_busy - busy0)
		return
	}
	step := i64(0)
	prev, _, _, _ := relay_stream_state(w, o.space, seg)
	for _ in 0 ..< 4 * count {
		length, _, _, _ := relay_stream_state(w, o.space, seg)
		sealed, _ := relay_last_seal(w, o.space, aid)
		if step > 0 && length - sealed + step >= w.cfg.archive_min {
			break
		}
		if !_burst_send(w, n, oi) || !_burst_settle(w) {
			return
		}
		now, _, _, _ := relay_stream_state(w, o.space, seg)
		step = max(step, now - prev)
		prev = now
	}
	if !_burst_send(w, n, oi) {
		return
	}
	target := prev + step
	for _ in 0 ..< 2000 {
		length, _, _, _ := relay_stream_state(w, o.space, seg)
		if length >= target - step / 2 {
			break
		}
		run_until(w, w.now + 1_000_000, false)
	}
	at, _, _, _ := relay_stream_state(w, o.space, seg)
	_hold = {on = true, id = seg, from = at}
	stat_add(w, STAT_TRIM_HELD)
	world_note(w, "trim burst: %s's segment commits from %d are held while its archive trims", n.name, at)
	if !_burst_send(w, n, oi) {
		return
	}
	run_until(w, w.now + 2_000_000_000, false)
	_hold = {}
	_burst_settle(w)
	stat_add(w, STAT_TRIM_BUSY, w.relay.r.stats.trim_busy - busy0)
}

@(private = "file")
_burst_send :: proc(w: ^World, n: ^Node, oi: int) -> bool {
	if !_burst_online(n) || len(w.failures) > 0 || w.aborted {
		return false
	}
	m := &w.model
	context = instance_context(&n.inst)
	defer node_after(n)
	op := new_op(m, .Send, n, oi)
	op.token = new_token(m, n, "m")
	rid, err := eng.convo_send(&n.e, m.objs[oi].o, msg_body(op.token), {}, nil, op_done_handle(op))
	if err != .Pending {
		op.rid = rid
	}
	op_result(op, n, err)
	return true
}

@(private = "file")
_burst_settle :: proc(w: ^World) -> bool {
	for _ in 0 ..< 4 {
		run_until(w, w.now + 60_000_000_000, true)
		if len(w.failures) > 0 || w.aborted {
			return false
		}
	}
	return true
}

@(private = "file")
_burst_ids :: proc(n: ^Node, o: eng.Object) -> (seg, aid: osync.Stream_Id, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	eng.convo_status(&n.e, o)
	h, hok := n.e.handles[o.id]
	if !hok {
		return
	}
	aname, nerr := arc.stream_name(h.name, context.temp_allocator)
	if nerr != .None {
		return
	}
	seg = osync.stream_id(&h.scope, eng.self(&n.e), h.name, 0)
	aid = osync.stream_id(&h.scope, eng.self(&n.e), aname, 0)
	return seg, aid, true
}

@(private = "file")
_burst_online :: proc(n: ^Node) -> bool {
	return n.alive && n.e_open && !n.partitioned
}

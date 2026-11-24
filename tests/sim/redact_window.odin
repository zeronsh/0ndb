package sim

import eng "../../src/engine"
import "../../src/prim"

STAT_REDACT_WINDOW: Stat

@(init)
_redact_window_hooks :: proc "contextless" () {
	register_final_check(89, check_redact_window)
	STAT_REDACT_WINDOW = register_stat(77, 18, "redact_windows")
}

check_redact_window :: proc(w: ^World) {
	if w.aborted || len(w.failures) > 0 || w.cfg.archive_min < 0 || w.cfg.byzantine || env_u64("SIM_REDACT_WINDOW", 1) == 0 {
		return
	}
	p, prev, ok := _redact_window_pick(w)
	if !ok {
		return
	}
	m := &w.model
	ob := &m.objs[p.oi]
	ol, found := _redact_window_length(p.wn, ob.o.id)
	if !found {
		return
	}
	stat_add(w, STAT_REDACT_WINDOW)
	at := prev.rid.off + 5
	damage := env_u64("SIM_REDACT_WINDOW", 1) != 2
	world_note(w, "redact window: %s damages=%v its own message %s at %d and redacts its neighbour %s at %d of %s, below its trimmed base %d", p.wn.name, damage, prev.token, prev.rid.off, p.t.token, p.t.rid.off, id_short(ob.o.id), p.base)
	if damage && !_redact_window_flip(w, p.wn, ol, at) {
		return
	}
	op := new_op(m, .Redact_Msg, p.wn, p.oi)
	op.target = p.t.idx
	snapshot_search_models(w, p.wn, op)
	{
		context = instance_context(&p.wn.inst)
		err := eng.convo_redact(&p.wn.e, ob.o, p.t.rid, op_done_handle(op))
		op_result(op, p.wn, err)
		node_after(p.wn)
	}
	run_until(w, w.now + 120_000_000_000, true)
	if len(w.failures) > 0 || w.aborted {
		return
	}
	got := digest_object(w, p.rn, p.oi)
	if !got.complete {
		world_fail(w, "redact window: %s cannot read Convo %s once %s redacted %s beside a damaged record (%s)", p.rn.name, id_short(ob.o.id), p.wn.name, p.t.token, got.why)
	} else {
		delete(got.text, w.allocator)
		_forget_reread(w, p)
	}
	if damage && p.wn.alive && p.wn.e_open {
		_redact_window_flip(w, p.wn, ol, at)
	}
}

@(private = "file")
_redact_window_flip :: proc(w: ^World, n: ^Node, ol: eng.Own_Length, at: i64) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	return _bitrot_write(w, n, ol, at, 1)
}

@(private = "file")
_redact_window_length :: proc(n: ^Node, id: prim.Id) -> (ol: eng.Own_Length, found: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	own, err := eng.own_lengths(&n.e, context.temp_allocator)
	if err != .None {
		return
	}
	for x in own {
		if x.object == id && x.kind == .Conversation && !x.device {
			return x, true
		}
	}
	return
}

@(private = "file")
_redact_window_pick :: proc(w: ^World) -> (p: Restore_Pick, prev: ^M_Op, ok: bool) {
	p, ok = _restore_pick(w)
	if !ok {
		return
	}
	ok = false
	gap := max(i64)
	for t in w.model.ops {
		if !_redact_window_cand(w, p, t) {
			continue
		}
		for u in w.model.ops {
			if u != t && _redact_window_cand(w, p, u) && u.rid.off < t.rid.off && t.rid.off - u.rid.off < gap {
				gap = t.rid.off - u.rid.off
				p.t = t
				prev = u
				ok = true
			}
		}
	}
	return
}

@(private = "file")
_redact_window_cand :: proc(w: ^World, p: Restore_Pick, t: ^M_Op) -> bool {
	if t.obj != p.oi || t.kind != .Send || t.node != p.wn.idx || t.rid.seg != p.dev || t.rid.off >= p.base {
		return false
	}
	return (t.status == .Done || t.status == .Acked || t.status == .Observed) && !_msg_redacted(&w.model, t.idx)
}

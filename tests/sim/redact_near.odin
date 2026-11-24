package sim

import "core:fmt"
import eng "../../src/engine"
import "../../src/obj"

REDACT_NEAR_OFF :: 0
REDACT_NEAR_NEIGHBOUR :: 1
REDACT_NEAR_OFFLINE :: 2
REDACT_NEAR_TARGET :: 3
REDACT_NEAR_CONTROL :: 4

STAT_REDACT_NEAR: Stat

@(init)
_redact_near_hooks :: proc "contextless" () {
	register_final_check(1008, check_redact_near)
	register_stat_line(61, "redact_near")
	STAT_REDACT_NEAR = register_stat(61, 0, "runs")
}

check_redact_near :: proc(w: ^World) {
	mode := env_u64("SIM_REDACT_NEAR", REDACT_NEAR_OFF)
	if mode == REDACT_NEAR_OFF || w.aborted || len(w.failures) > 0 || w.cfg.byzantine {
		return
	}
	t, prev := _redact_near_pick(w)
	if t == nil {
		return
	}
	n := w.nodes[t.node]
	o := w.model.objs[t.obj].o
	ol, found := _redact_near_length(n, t.obj, w)
	if !found {
		return
	}
	if _, there := disk_contains(&n.disk, transmute([]u8)t.token); !there {
		return
	}
	stat_add(w, STAT_REDACT_NEAR)
	if mode == REDACT_NEAR_OFFLINE {
		n.partitioned = true
		for c in n.conns {
			conn_reset(c, true)
		}
		run_until(w, w.now + 5_000_000_000, true)
	}
	damaged := t if mode == REDACT_NEAR_TARGET else prev
	if mode != REDACT_NEAR_CONTROL {
		context = instance_context(&n.inst)
		_bitrot_write(w, n, ol, damaged.rid.off + 5, 1)
		node_after(n)
	}
	world_note(w, "redact near: mode %d, %s redacts its message %s at %d of %s; damaged %s at %d (device-only %v)", mode, n.name, t.token, t.rid.off, id_short(o.id), damaged.token, damaged.rid.off, ol.device)
	op := new_op(&w.model, .Redact_Msg, n, t.obj)
	op.target = t.idx
	context = instance_context(&n.inst)
	err := eng.convo_redact(&n.e, o, t.rid, op_done_handle(op))
	node_after(n)
	context = w.ctx
	if err == .Corrupt {
		world_fail(w, "redact near: mode %d, %s was refused the redaction of %s beside damage: Corrupt", mode, n.name, t.token)
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	if path, there := disk_contains(&n.disk, transmute([]u8)t.token); there {
		world_fail(w, "redact near: mode %d, %s still has %s on disk in %s 10 s after its redaction (%v, op %v)", mode, n.name, t.token, path, err, op.status)
	}
	for k in 0 ..< 5 {
		path, there := disk_contains(&n.disk, transmute([]u8)t.token)
		fmt.eprintf("DT t=+%ds there=%v %s\n", k * 60, there, path)
		run_until(w, w.now + 60_000_000_000, false)
	}
	if mode == REDACT_NEAR_OFFLINE {
		n.partitioned = false
		for _ in 0 ..< 6 {
			run_until(w, w.now + 120_000_000_000, true)
		}
	}
}

@(private = "file")
_redact_near_length :: proc(n: ^Node, oi: int, w: ^World) -> (ol: eng.Own_Length, found: bool) {
	id := w.model.objs[oi].o.id
	context = instance_context(&n.inst)
	defer node_after(n)
	own, err := eng.own_lengths(&n.e, context.temp_allocator)
	if err != .None {
		return
	}
	for x in own {
		if x.object == id && x.kind == .Conversation {
			return x, true
		}
	}
	return
}

@(private = "file")
_redact_near_pick :: proc(w: ^World) -> (best, prev: ^M_Op) {
	m := &w.model
	for t in m.ops {
		if !_redact_near_cand(w, t) {
			continue
		}
		for u in m.ops {
			if u == t || !_redact_near_cand(w, u) || u.obj != t.obj || u.node != t.node || u.rid.off >= t.rid.off {
				continue
			}
			if best == nil || t.rid.off - u.rid.off < best.rid.off - prev.rid.off {
				best, prev = t, u
			}
		}
	}
	return
}

@(private = "file")
_redact_near_cand :: proc(w: ^World, t: ^M_Op) -> bool {
	if t.kind != .Send || obj.rid_none(t.rid) || !obj_exists(&w.model, t.obj) {
		return false
	}
	n := w.nodes[t.node]
	if !n.alive || !n.e_open || t.rid.seg != n.identity.id {
		return false
	}
	for x in w.model.ops {
		if x.kind == .Redact_Msg && x.target == t.idx {
			return false
		}
	}
	return true
}

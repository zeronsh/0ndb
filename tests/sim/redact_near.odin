package sim

import "core:strings"
import eng "../../src/engine"
import "../../src/obj"
import "../../src/prim"

REDACT_NEAR_OFF :: 0
REDACT_NEAR_NEIGHBOUR :: 1
REDACT_NEAR_OFFLINE :: 2
REDACT_NEAR_TARGET :: 3
REDACT_NEAR_CONTROL :: 4
REDACT_NEAR_HEADER :: 5
REDACT_NEAR_REMOTE :: 6

STAT_REDACT_NEAR: Stat
STAT_REDACT_NEAR_OPS: Stat
STAT_REDACT_NEAR_CRASHED: Stat

@(init)
_redact_near_hooks :: proc "contextless" () {
	register_final_check(1008, check_redact_near)
	register_stat_line(61, "redact_near")
	STAT_REDACT_NEAR = register_stat(61, 0, "runs")
	STAT_REDACT_NEAR_OPS = register_stat(61, 1, "ops", true)
	STAT_REDACT_NEAR_CRASHED = register_stat(61, 2, "crashed")
}

check_redact_near :: proc(w: ^World) {
	mode := env_u64("SIM_REDACT_NEAR", REDACT_NEAR_OFF)
	crash := env_u64("SIM_REDACT_NEAR_CRASH", 0)
	if mode == REDACT_NEAR_OFF || w.aborted || len(w.failures) > 0 || w.cfg.byzantine {
		return
	}
	n, writer, t, prev := _redact_near_pick(w, mode == REDACT_NEAR_REMOTE)
	if t == nil {
		return
	}
	o := w.model.objs[t.obj].o
	if mode == REDACT_NEAR_REMOTE {
		_ = digest_object(w, n, t.obj)
	}
	if _, there := disk_contains(&n.disk, transmute([]u8)t.token); !there {
		return
	}
	stat_add(w, STAT_REDACT_NEAR)
	if mode == REDACT_NEAR_OFFLINE || mode == REDACT_NEAR_REMOTE {
		cut := writer if mode == REDACT_NEAR_REMOTE else n
		cut.partitioned = true
		for c in cut.conns {
			conn_reset(c, true)
		}
		run_until(w, w.now + 5_000_000_000, true)
	}
	damaged := t if mode == REDACT_NEAR_TARGET || mode == REDACT_NEAR_HEADER else prev
	if mode != REDACT_NEAR_CONTROL && !_redact_near_damage(n, writer, o.id, damaged, t.token, mode == REDACT_NEAR_TARGET) {
		return
	}
	world_note(w, "redact near: mode %d crash %d, %s redacts %s's message %s at %d of %s; damaged %s at %d", mode, crash, n.name, writer.name, t.token, t.rid.off, id_short(o.id), damaged.token, damaged.rid.off)
	op := new_op(&w.model, .Redact_Msg, n, t.obj)
	op.target = t.idx
	crashes := w.stats.crashes
	ops0 := n.disk.stats.ops
	if crash > 0 {
		n.disk.crash_at = n.disk.stats.ops + crash
	}
	err: eng.Error
	redact: {
		context = instance_context(&n.inst)
		err = eng.convo_redact(&n.e, o, t.rid, op_done_handle(op))
		if n.disk.dead {
			break redact
		}
		node_after(n)
	}
	context = w.ctx
	if n.disk.dead {
		node_crashed(n)
	} else if err == .Corrupt {
		world_fail(w, "redact near: mode %d, %s was refused the redaction of %s beside damage: Corrupt", mode, n.name, t.token)
		return
	}
	run_until(w, w.now + 10_000_000_000, true)
	stat_max(w, STAT_REDACT_NEAR_OPS, n.disk.stats.ops - ops0)
	n.disk.crash_at = 0
	crashed := w.stats.crashes > crashes
	if crashed {
		stat_add(w, STAT_REDACT_NEAR_CRASHED)
		run_until(w, w.now + 20_000_000_000, true)
	} else if path, there := disk_contains(&n.disk, transmute([]u8)t.token); there {
		world_fail(w, "redact near: mode %d, %s still has %s on disk in %s 10 s after its redaction (%v, op %v)", mode, n.name, t.token, path, err, op.status)
	}
	if mode == REDACT_NEAR_OFFLINE || mode == REDACT_NEAR_REMOTE {
		cut := writer if mode == REDACT_NEAR_REMOTE else n
		cut.partitioned = false
	}
	for _ in 0 ..< 6 {
		run_until(w, w.now + 120_000_000_000, true)
	}
	if len(w.failures) > 0 || w.aborted {
		return
	}
	if !n.alive || !n.e_open {
		world_fail(w, "redact near: %s did not come back after its redaction (crash %d)", n.name, crash)
		return
	}
	got := digest_object(w, n, t.obj)
	readable := got.complete && strings.contains(got.text, t.token)
	if got.complete {
		delete(got.text, w.allocator)
	}
	_, on_disk := disk_contains(&n.disk, transmute([]u8)t.token)
	context = instance_context(&n.inst)
	damage, _ := eng.scrub(&n.e)
	owed := eng.redactions_owed(&n.e, context.temp_allocator)
	any_owed := false
	plan := 0
	for x in owed {
		if x.object != o.id {
			continue
		}
		any_owed = true
		world_note(w, "redact near: %s still owes %v of %s at %d (damage left %d)", n.name, x.part, id_short(o.id), x.from, damage)
		if x.part == .Plan {
			plan += 1
		}
	}
	node_after(n)
	context = w.ctx
	accepted := !crashed && (err == .None || err == .Pending)
	if (accepted || any_owed) && (readable || on_disk) {
		world_fail(w, "redact near: mode %d crash %d, %s still has %s (readable %v, on disk %v) after its redaction settled (%v, owed %v)", mode, crash, n.name, t.token, readable, on_disk, err, any_owed)
	}
	if plan > 0 && damage == 0 {
		world_fail(w, "redact near: mode %d, %s still owes the plan of %s with no damage left", mode, n.name, t.token)
	}
}

@(private = "file")
_redact_near_damage :: proc(n, writer: ^Node, oid: prim.Id, d: ^M_Op, token: string, in_token: bool) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	fd := prim.INVALID_FD
	close := false
	if n == writer {
		own, err := eng.own_lengths(&n.e, context.temp_allocator)
		if err != .None {
			return false
		}
		for x in own {
			if x.kind == .Conversation && x.object == oid {
				f, oerr := prim.open_file(n.e.vfs, x.path, {.Write})
				if oerr != .None {
					return false
				}
				fd, close = f, true
				break
			}
		}
	} else if h, ok := n.e.handles[oid]; ok {
		for s in h.segs {
			if s.device == writer.identity.id && s.rep != nil {
				fd = s.rep.fd
			}
		}
	}
	if fd == prim.INVALID_FD {
		return false
	}
	defer if close {
		prim.close_file(n.e.vfs, fd)
	}
	at := d.rid.off + 5
	if in_token {
		buf := make([]u8, 1 << 16, context.temp_allocator)
		got, rerr := prim.read_at(n.e.vfs, fd, buf, d.rid.off)
		if rerr != .None {
			return false
		}
		found := false
		for i in 0 ..< max(got - len(token) + 1, 0) {
			if string(buf[i:][:len(token)]) == token {
				at = d.rid.off + i64(i) + 1
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	b: [1]u8
	if k, rerr := prim.read_at(n.e.vfs, fd, b[:], at); rerr != .None || k != 1 {
		return false
	}
	b[0] ~= 1
	return prim.write_at(n.e.vfs, fd, b[:], at) == .None
}

@(private = "file")
_redact_near_pick :: proc(w: ^World, remote: bool) -> (n, writer: ^Node, best, prev: ^M_Op) {
	m := &w.model
	for t in m.ops {
		if !_redact_near_cand(w, t) {
			continue
		}
		for u in m.ops {
			if u == t || !_redact_near_cand(w, u) || u.obj != t.obj || u.node != t.node || u.rid.off >= t.rid.off {
				continue
			}
			if best != nil && t.rid.off - u.rid.off >= best.rid.off - prev.rid.off {
				continue
			}
			actor := w.nodes[t.node]
			if remote {
				actor = nil
				for ri in readers_of(w, t.obj) {
					r := w.nodes[ri]
					if ri != t.node && r.alive && r.e_open && !r.partitioned {
						actor = r
						break
					}
				}
				if actor == nil {
					continue
				}
			}
			best, prev, n, writer = t, u, actor, w.nodes[t.node]
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

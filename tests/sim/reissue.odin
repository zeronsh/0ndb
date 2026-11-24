package sim

import eng "../../src/engine"
import "../../src/crdt"
import "../../src/fs"
import "../../src/pack"
import "../../src/prim"

Reissue_Batch :: struct {
	id:     crdt.Op_Id,
	n:      int,
	digest: u64,
}

@(private = "file")
_batch_digest :: proc(b: ^crdt.Batch) -> u64 {
	mix_id :: proc(h: u64, id: crdt.Op_Id) -> u64 {
		x := id
		return mix64(mix_bytes(h, x.actor[:]), x.seq)
	}
	h := mix_id(0, crdt.Op_Id{b.actor, b.seq})
	h = mix64(h, b.lamport)
	for p in b.parents {
		h = mix_id(h, p)
	}
	for op in b.ops {
		h = mix_id(h, op.target)
		h = mix64(h, u64(op.kind))
		h = mix64(h, u64(op.pos))
		h = mix64(h, u64(op.len))
		h = mix_bytes(h, op.content)
		ref := op.ref
		h = mix_bytes(h, ref.oid.bytes[:])
	}
	return h
}

reissue_batches :: proc(n: ^Node, o: eng.Object, out: ^[dynamic]Reissue_Batch, wake: bool, text := false) -> (ok: bool) {
	if !n.alive || !n.e_open {
		return false
	}
	dead := n.disk.dead
	n.disk.dead = false
	n.disk.probe += 1
	defer {
		n.disk.probe -= 1
		n.disk.dead = dead
	}
	context = instance_context(&n.inst)
	if !dead {
		if text {
			eng.text_read(&n.e, o, context.temp_allocator)
		} else {
			eng.tree_read(&n.e, o, "a.txt", context.temp_allocator)
		}
	}
	h, held := n.e.handles[o.id]
	if !held || h.hist == nil || (!wake && !h.hist.awake) {
		return false
	}
	if !h.hist.awake && fs.history_wake(h.hist) != .None {
		return false
	}
	for lv := crdt.Lv(0); lv < h.hist.g.next; {
		first, cnt, stream, off, found := fs.history_batch_at(h.hist, lv)
		if !found {
			return false
		}
		b, err := fs.history_read_batch(h.hist, stream, off, context.temp_allocator)
		if err != .None {
			return false
		}
		append(out, Reissue_Batch{id = crdt.Op_Id{b.actor, b.seq}, n = crdt.batch_len(&b), digest = _batch_digest(&b)})
		lv = first + crdt.Lv(cnt)
	}
	return true
}

reissue_note :: proc(seen: ^[dynamic]Reissue_Batch, now: []Reissue_Batch) {
	for x in now {
		old := false
		for y in seen {
			if y == x {
				old = true
				break
			}
		}
		if !old {
			append(seen, x)
		}
	}
}

reissue_count :: proc(seen, final: []Reissue_Batch) -> (lost, changed: int) {
	for x in seen {
		kept, over := false, false
		for y in final {
			if x == y {
				kept = true
			} else if x.id.actor == y.id.actor && x.id.seq < y.id.seq + u64(y.n) && y.id.seq < x.id.seq + u64(x.n) {
				over = true
			}
		}
		if !kept {
			lost += 1
			if over {
				changed += 1
			}
		}
	}
	return
}

reissue_compare :: proc(w: ^World, what: string, a, b: []Reissue_Batch) {
	for x in a {
		for y in b {
			if x.id.actor == y.id.actor && x.id.seq < y.id.seq + u64(y.n) && y.id.seq < x.id.seq + u64(x.n) && x != y {
				ax, bx := prim.id_hex(x.id.actor), prim.id_hex(y.id.actor)
				world_fail(w, "%s: the devices hold different operations under one id: %s:%d+%d and %s:%d+%d", what, string(ax[:]), x.id.seq, x.n, string(bx[:]), y.id.seq, y.n)
			}
		}
	}
	if len(a) != len(b) {
		world_fail(w, "%s: the devices hold %d and %d batches", what, len(a), len(b))
	}
}

reissue_watch :: proc(w: ^World, n: ^Node, o: eng.Object, seen: ^[dynamic]Reissue_Batch, limit: i64, text := false) {
	for w.now < limit && n.alive && reissue_going(w) {
		t, ok := next_time(w)
		if !ok || t > limit {
			break
		}
		run_until(w, t, false)
		reissue_see(w, n, o, seen, text)
	}
}

reissue_see :: proc(w: ^World, n: ^Node, o: eng.Object, seen: ^[dynamic]Reissue_Batch, text := false) {
	context.allocator = w.allocator
	now := make([dynamic]Reissue_Batch)
	if reissue_batches(n, o, &now, false, text) {
		reissue_note(seen, now[:])
	}
}

reissue_settle :: proc(w: ^World, what: string, a, b: ^Node, o: eng.Object, seen: []Reissue_Batch, text := false) -> (lost, changed: int) {
	context.allocator = w.allocator
	xs := make([dynamic]Reissue_Batch)
	ys := make([dynamic]Reissue_Batch)
	if !reissue_batches(a, o, &xs, true, text) || !reissue_batches(b, o, &ys, true, text) {
		world_fail(w, "%s: a device's batches are unreadable", what)
		return
	}
	reissue_compare(w, what, xs[:], ys[:])
	check_own_tails(w)
	return reissue_count(seen, ys[:])
}

REISSUE_HOLD :: i64(2_000_000_000)

reissue_hold :: proc(n: ^Node, cfg: ^eng.Config) {
	if n.idx == 1 && cfg.durability == .Async {
		cfg.pack_options.worker = pack.Worker_Hook{data = n, submit = proc(data: rawptr) {
			n := (^Node)(data)
			schedule(n.w, Sim_Event{at = n.w.now + REISSUE_HOLD, kind = .Pack_Job, node = n.idx, gen = u64(n.incarnation)})
		}}
	}
}

reissue_restarted :: proc(w: ^World, n: ^Node) -> bool {
	for limit := w.now + 60_000_000_000; w.now < limit && !(n.alive && n.e_open) && reissue_going(w); {
		t, ok := next_time(w)
		if !ok {
			break
		}
		run_until(w, t, false)
	}
	if !n.alive || !n.e_open {
		return false
	}
	n.disk.probe += 1
	check_own_tail(w, n)
	n.disk.probe -= 1
	return true
}

reissue_going :: proc(w: ^World) -> bool {
	return !w.aborted && len(w.failures) < 20
}

package sim

import "core:strings"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
STAT_DUET_KEYS: Stat
@(private = "file")
STAT_DUET_OPS: Stat
@(private = "file")
STAT_DUET_SHOWN: Stat
@(private = "file")
STAT_DUET_TRANSFORMED: Stat

@(private = "file")
_type_at :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer, pos: int) -> (tok: string, err: eng.Error) {
	m := &w.model
	op := new_op(m, .Buffer_Type, n, b.oi)
	op.actor = b.actor
	op.path = strings.clone(b.path, w.allocator)
	tok = new_token(m, n, "b")
	append(&op.tokens, tok)
	w.buf_group += 1
	err = _edit(w, n, b, pos, 0, tok, w.buf_group)
	world_note(w, "%s buffer %d duet type %s at %d rev %d -> %v", n.name, b.id, tok, pos, b.rev, err)
	op_result(op, n, err)
	if err == .None {
		append(&b.groups, tok)
	} else if err == .Conflict {
		b.dead = true
	}
	return
}

@(private = "file")
_duet_partner :: proc(w: ^World, a: ^Sim_Buffer) -> ^Sim_Buffer {
	for y in w.bufs {
		if y.node != a.node && y.oi == a.oi && _probe_ready(w, y) {
			return y
		}
	}
	return nil
}

@(private = "file")
_duet_weight :: proc(w: ^World) -> int {
	for x in w.bufs {
		if _probe_ready(w, x) && _duet_partner(w, x) != nil {
			return 4
		}
	}
	return 0
}

@(private = "file")
op_duet :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open {
		return
	}
	for a in _live(w, n) {
		if !_probe_ready(w, a) {
			continue
		}
		y := _duet_partner(w, a)
		if y == nil {
			continue
		}
		buffers_deliver(w, a, len(a.inbox))
		if a.dead || len(a.pending) > 0 {
			return
		}
		_type_at(w, n, a, 0 if a.node < y.node else len(a.doc))
		stat_add(w, STAT_DUET_OPS)
		return
	}
}

@(private = "file")
_duet_open :: proc(w: ^World, n: ^Node, oi: int) -> ^Sim_Buffer {
	nb := _new_buffer(w, n, oi, "", rng_chance(&w.rng, 1, 2))
	actor: prim.Id
	for k in 0 ..< 16 {
		actor[k] = u8(rng_int(&w.rng, 256))
	}
	context = instance_context(&n.inst)
	info, err := eng.buffer_open(&n.e, w.model.objs[oi].o, eng.Buffer_Options{units = .Utf16 if nb.utf16 else .Bytes, actor = actor, cb = _on_buffer, data = nb}, context.temp_allocator)
	if err != .None {
		return nil
	}
	_keep(w, nb, &info)
	return nb
}

check_live_duet :: proc(w: ^World) {
	if len(w.failures) > 0 {
		return
	}
	a, b: ^Sim_Buffer
	found: for x in w.bufs {
		if !_probe_ready(w, x) {
			continue
		}
		for n in w.nodes {
			if n.idx == x.node || !n.alive || !n.e_open {
				continue
			}
			a = _duet_open(w, w.nodes[x.node], x.oi)
			if a == nil {
				continue
			}
			b = _duet_open(w, n, x.oi)
			if b == nil {
				a = nil
				continue
			}
			break found
		}
	}
	if a == nil {
		return
	}
	na, nb := w.nodes[a.node], w.nodes[b.node]
	pair := []^Sim_Buffer{a, b}
	if !_probe_settle(w, pair) || string(a.doc[:]) != string(b.doc[:]) {
		return
	}
	wa, ea := _type_at(w, na, a, 0)
	node_after(na)
	wb, eb := _type_at(w, nb, b, len(b.doc))
	node_after(nb)
	if ea != .None || eb != .None {
		return
	}
	warm := false
	for _ in 0 ..< 8 {
		if !_probe_settle(w, pair) {
			return
		}
		if strings.contains(string(a.doc[:]), wb) && strings.contains(string(b.doc[:]), wa) {
			warm = true
			break
		}
	}
	if !warm {
		return
	}
	sa0, sb0 := eng.buffer_live_shown(&na.e, a.id), eng.buffer_live_shown(&nb.e, b.id)
	rx0a, rx0b, sk0a, sk0b := na.e.stats.buffer_live_received, nb.e.stats.buffer_live_received, na.e.stats.buffer_live_skipped, nb.e.stats.buffer_live_skipped
	tx0a, tx0b := na.e.stats.buffer_live_sent, nb.e.stats.buffer_live_sent
	kl0 := na.e.stats.buffer_live_keyless + nb.e.stats.buffer_live_keyless
	tr0 := na.e.stats.buffer_live_transformed + nb.e.stats.buffer_live_transformed
	toks := make([dynamic]string, w.allocator)
	defer delete(toks)
	ROUNDS :: 24
	for _ in 0 ..< ROUNDS {
		buffers_deliver(w, a, len(a.inbox))
		if len(a.pending) == 0 && !a.dead {
			if t, err := _type_at(w, na, a, 0); err == .None {
				append(&toks, t)
			}
		}
		node_after(na)
		buffers_deliver(w, b, len(b.inbox))
		if len(b.pending) == 0 && !b.dead {
			if t, err := _type_at(w, nb, b, len(b.doc)); err == .None {
				append(&toks, t)
			}
		}
		node_after(nb)
		run_until(w, w.now + i64(500_000 + rng_int(&w.rng, 3_000_000)), false)
	}
	for _ in 0 ..< 8 {
		if !_probe_settle(w, pair) {
			return
		}
		done := true
		for t in toks {
			if strings.count(string(a.doc[:]), t) != 1 || strings.count(string(b.doc[:]), t) != 1 {
				done = false
			}
		}
		if done {
			break
		}
	}
	for x in pair {
		n := w.nodes[x.node]
		context = instance_context(&n.inst)
		text, _, err := eng.buffer_text(&n.e, x.id, context.temp_allocator)
		if err != .None {
			continue
		}
		for t in toks {
			if c := strings.count(string(text), t); c != 1 {
				world_fail(w, "buffer: duet: %s typed while both devices typed at once appears %d times in %s's buffer", t, c, n.name)
			}
			if c := strings.count(string(x.doc[:]), t); c != 1 {
				world_fail(w, "buffer: duet: %s appears %d times in %s's client document", t, c, n.name)
			}
		}
		if string(x.doc[:]) != string(text) {
			world_fail(w, "buffer: duet: %s's client document differs from its buffer after settle", n.name)
		}
	}
	sa, sb := eng.buffer_live_shown(&na.e, a.id) - sa0, eng.buffer_live_shown(&nb.e, b.id) - sb0
	shown := sa + sb
	tr := na.e.stats.buffer_live_transformed + nb.e.stats.buffer_live_transformed - tr0
	stat_add(w, STAT_DUET_KEYS, u64(len(toks)))
	stat_add(w, STAT_DUET_SHOWN, shown)
	stat_add(w, STAT_DUET_TRANSFORMED, tr)
	world_note(w, "duet: %d keystrokes, %d shown live (%s sent %d, shown %d of %d received, %d skipped; %s sent %d, shown %d of %d received, %d skipped), %d transformed, %d keyless", len(toks), shown, na.name, na.e.stats.buffer_live_sent - tx0a, sa, na.e.stats.buffer_live_received - rx0a, na.e.stats.buffer_live_skipped - sk0a, nb.name, nb.e.stats.buffer_live_sent - tx0b, sb, nb.e.stats.buffer_live_received - rx0b, nb.e.stats.buffer_live_skipped - sk0b, tr, na.e.stats.buffer_live_keyless + nb.e.stats.buffer_live_keyless - kl0)
	_probe_converge(w, a.oi)
}

@(init)
_buffer_duet_register :: proc "contextless" () {
	register_final_check(1001, check_live_duet)
	register_op(220, "buffer_duet", _duet_weight, op_duet)
	register_stat_line(33, "duet")
	STAT_DUET_KEYS = register_stat(33, 0, "keys")
	STAT_DUET_SHOWN = register_stat(33, 1, "shown_live")
	STAT_DUET_TRANSFORMED = register_stat(33, 2, "transformed")
	STAT_DUET_OPS = register_stat(33, 3, "workload_keys")
}

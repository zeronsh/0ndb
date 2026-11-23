package sim

import "core:fmt"
import "core:strings"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
Di_Buf :: struct {
	rev: u64,
}

@(private = "file")
STAT_DI_RUNS: Stat
@(private = "file")
STAT_DI_REACHED: Stat
@(private = "file")
STAT_DI_BAD_GONE: Stat
@(private = "file")
STAT_DI_REPLAYED: Stat
@(private = "file")
STAT_DI_FIRST: Stat

@(private = "file")
_di_cb :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	if ev.kind == .Delta {
		(^Di_Buf)(data).rev = ev.rev
	}
}

@(private = "file")
_di_units :: proc(s: string, utf16: bool) -> int {
	if !utf16 {
		return len(s)
	}
	n := 0
	for r in s {
		n += 2 if r >= 0x10000 else 1
	}
	return n
}

@(private = "file")
_di_pair :: proc(w: ^World) -> (oi: int, a, b: ^Node) {
	m := &w.model
	for &ob, i in m.objs {
		if ob.kind != .Text || !obj_exists(m, i) {
			continue
		}
		rs := readers_of(w, i)
		got: [2]^Node
		k := 0
		for idx in rs {
			n := w.nodes[idx]
			if n.alive && n.e_open && k < 2 {
				got[k] = n
				k += 1
			}
		}
		if k == 2 {
			return i, got[0], got[1]
		}
	}
	return -1, nil, nil
}

@(private = "file")
_di_settle :: proc(w: ^World, oi: int) {
	for _ in 0 ..< 8 {
		run_until(w, w.now + 30_000_000_000, true)
		ref: string
		have, same := false, true
		for idx in readers_of(w, oi) {
			n := w.nodes[idx]
			if !n.alive || !n.e_open {
				same = false
				continue
			}
			context = instance_context(&n.inst)
			t, err := eng.text_read(&n.e, w.model.objs[oi].o, context.temp_allocator)
			if err != .None {
				same = false
				continue
			}
			if !have {
				ref, have = strings.clone(string(t), context.temp_allocator), true
			} else if string(t) != ref {
				same = false
			}
		}
		if same && have {
			return
		}
	}
}

@(private = "file")
_di_open :: proc(w: ^World, n: ^Node, oi: int, utf16: bool, actor: prim.Id, st: ^Di_Buf) -> (id: eng.Buffer_Id, ok: bool) {
	context = instance_context(&n.inst)
	info, err := eng.buffer_open(&n.e, w.model.objs[oi].o, eng.Buffer_Options{units = .Utf16 if utf16 else .Bytes, actor = actor, cb = _di_cb, data = st}, context.temp_allocator)
	if err != .None {
		return 0, false
	}
	st.rev = info.rev
	return info.id, true
}

@(private = "file")
_di_close :: proc(n: ^Node, id: eng.Buffer_Id) {
	if n.alive && n.e_open {
		context = instance_context(&n.inst)
		eng.buffer_close(&n.e, id)
	}
}

@(private = "file")
_di_text :: proc(n: ^Node, id: eng.Buffer_Id) -> string {
	context = instance_context(&n.inst)
	t, _, err := eng.buffer_text(&n.e, id, context.temp_allocator)
	if err != .None {
		return ""
	}
	return string(t)
}

@(private = "file")
_di_shown :: proc(w: ^World, na, nb: ^Node, ia, ib: eng.Buffer_Id, sa: ^Di_Buf, tok: string, utf16: bool) -> (shown: bool) {
	text := _di_text(na, ia)
	pos := _di_units(text, utf16)
	{
		context = instance_context(&na.inst)
		if _, _, err := eng.buffer_edit(&na.e, ia, sa.rev, []eng.Buffer_Edit{{pos, 0, transmute([]u8)tok}}, 0, {}); err != .None {
			return false
		}
	}
	for _ in 0 ..< 4000 {
		run_until(w, w.now + 1_000_000, false)
		if !na.alive || !nb.alive || !nb.e_open {
			return false
		}
		context = instance_context(&nb.inst)
		k := eng.buffer_overlay(&nb.e, ib)
		has := strings.contains(_di_text(nb, ib), tok)
		if has {
			return k > 0
		}
	}
	return false
}

@(private = "file")
_di_absent :: proc(w: ^World, oi: int, tok: string, parts: []string, what: string) {
	for idx in readers_of(w, oi) {
		n := w.nodes[idx]
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		t, err := eng.text_read(&n.e, w.model.objs[oi].o, context.temp_allocator)
		if err != .None {
			continue
		}
		for p in parts {
			if strings.contains(string(t), p) {
				world_fail(w, "buffer: delete intent (%s): the delete of %s did not hold: %q is still on %s", what, tok, p, n.name)
				break
			}
		}
	}
}

@(private = "file")
_di_actor :: proc(w: ^World) -> (id: prim.Id) {
	for i in 0 ..< 2 {
		x := rng_u64(&w.rng)
		for j in 0 ..< 8 {
			id[i * 8 + j] = u8(x >> (8 * u64(j)))
		}
	}
	id[0] |= 1
	return
}

check_delete_intent_crash :: proc(w: ^World) {
	if len(w.failures) > 0 {
		return
	}
	oi, na, nb := _di_pair(w)
	if oi < 0 {
		return
	}
	stat_add(w, STAT_DI_RUNS)
	_di_settle(w, oi)
	if !na.alive || !nb.alive || !na.e_open || !nb.e_open {
		return
	}
	sa, sb := new(Di_Buf, w.allocator), new(Di_Buf, w.allocator)
	ia, aok := _di_open(w, na, oi, false, {}, sa)
	if !aok {
		return
	}
	ib, bok := _di_open(w, nb, oi, false, {}, sb)
	if !bok {
		_di_close(na, ia)
		return
	}
	run_until(w, w.now + 30_000_000_000, true)
	tok := new_token(&w.model, na, "q")
	if !_di_shown(w, na, nb, ia, ib, sa, tok, false) {
		_di_close(na, ia)
		_di_close(nb, ib)
		return
	}
	for c in na.conns {
		conn_reset(c, true)
	}
	text := _di_text(nb, ib)
	at := strings.index(text, tok)
	tick: u64
	{
		context = instance_context(&nb.inst)
		if _, _, err := eng.buffer_edit(&nb.e, ib, sb.rev, []eng.Buffer_Edit{{at, len(tok), nil}}, 0, {}); err != .None {
			world_fail(w, "buffer: delete intent (crash): %s's delete of %s over its live overlay failed: %v", nb.name, tok, err)
			return
		}
		tick = eng.pending_seq(&nb.e)
		eng.buffer_close(&nb.e, ib)
	}
	inc := nb.incarnation
	for _ in 0 ..< 4000 {
		if !nb.alive || nb.incarnation != inc || nb.durable >= tick {
			break
		}
		run_until(w, w.now + 1_000_000, false)
	}
	if !nb.alive || nb.incarnation != inc || nb.durable < tick {
		_di_close(na, ia)
		return
	}
	stat_add(w, STAT_DI_REACHED)
	if len(nb.e.dlog.live) > 0 {
		stat_add(w, STAT_DI_REPLAYED)
	}
	world_note(w, "%s deleted live %s over a dropped overlay, closed the buffer, and crashes once the delete is durable", nb.name, tok)
	node_crash_now(nb, .Process, 77)
	_di_close(na, ia)
	_di_settle(w, oi)
	_di_absent(w, oi, tok, []string{tok[:len(tok) - 1], tok[1:]}, "close and crash")
}

check_delete_intent_first :: proc(w: ^World) {
	if len(w.failures) > 0 {
		return
	}
	oi, na, nb := _di_pair(w)
	if oi < 0 {
		return
	}
	_di_settle(w, oi)
	if !na.alive || !nb.alive || !na.e_open || !nb.e_open {
		return
	}
	sa, sb := new(Di_Buf, w.allocator), new(Di_Buf, w.allocator)
	ia, aok := _di_open(w, na, oi, true, _di_actor(w), sa)
	if !aok {
		return
	}
	ib, bok := _di_open(w, nb, oi, true, {}, sb)
	if !bok {
		_di_close(na, ia)
		return
	}
	run_until(w, w.now + 30_000_000_000, true)
	base := new_token(&w.model, na, "f")
	tok := fmt.aprintf("%sééé€€😀>", base[:len(base) - 1], allocator = w.allocator)
	if !_di_shown(w, na, nb, ia, ib, sa, tok, true) {
		_di_close(na, ia)
		_di_close(nb, ib)
		return
	}
	text := _di_text(nb, ib)
	at := _di_units(text[:strings.index(text, tok)], true)
	seen := sb.rev
	mark := "<m>"
	{
		context = instance_context(&nb.inst)
		if _, _, err := eng.buffer_edit(&nb.e, ib, seen, []eng.Buffer_Edit{{0, 0, transmute([]u8)mark}}, 0, {}); err != .None {
			world_fail(w, "buffer: delete intent (first write): %s's edit over its live overlay failed: %v", nb.name, err)
			return
		}
		if _, _, err := eng.buffer_edit(&nb.e, ib, seen, []eng.Buffer_Edit{{at + _di_units(mark, true), _di_units(tok, true), nil}}, 0, {}); err != .None {
			world_fail(w, "buffer: delete intent (first write): %s's delete of %s failed: %v", nb.name, tok, err)
			return
		}
	}
	stat_add(w, STAT_DI_FIRST)
	world_note(w, "%s deleted %s, the first write of a fresh actor, after a dropped overlay", nb.name, tok)
	_di_settle(w, oi)
	_di_close(na, ia)
	_di_close(nb, ib)
	_di_settle(w, oi)
	_di_absent(w, oi, tok, []string{base[:len(base) - 1], "é", "€", "😀"}, "first write")
}

@(private = "file")
_di_step :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open || n.e.stats.buffer_live_bad_gone == 0 {
		return
	}
	stat_add(w, STAT_DI_BAD_GONE, n.e.stats.buffer_live_bad_gone)
	world_fail(w, "buffer: %s built a correction naming %d bytes of ops that are not overlay ops", n.name, n.e.stats.buffer_live_bad_gone)
	n.e.stats.buffer_live_bad_gone = 0
}

@(init)
_delete_intent_register :: proc "contextless" () {
	register_final_check(1002, check_delete_intent_crash)
	register_final_check(1003, check_delete_intent_first)
	register_step(42, _di_step)
	register_stat_line(31)
	STAT_DI_RUNS = register_stat(31, 0, "delete_intent_runs")
	STAT_DI_REACHED = register_stat(31, 1, "delete_intent_reached")
	STAT_DI_REPLAYED = register_stat(31, 2, "delete_intent_replayed")
	STAT_DI_FIRST = register_stat(31, 3, "delete_intent_first")
	STAT_DI_BAD_GONE = register_stat(31, 4, "bad_gone", true)
}

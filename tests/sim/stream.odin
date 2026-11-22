package sim

import "core:fmt"
import "core:strings"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/prim"

M_Stream :: struct {
	op:      int,
	node:    int,
	inc:     int,
	obj:     int,
	msg:     eng.Rid,
	rng:     Rng,
	steps:   int,
	cur:     u32,
	blocks:  [dynamic][dynamic]u8,
	kinds:   [dynamic]convo.Block_Kind,
	done:    bool,
	crashed: bool,
	sealed:  bool,
	failed:  bool,
	written: int,
	reseal:  bool,
}

Watch :: struct {
	w:    ^World,
	node: int,
	inc:  int,
	obj:  int,
	sub:  eng.Sub_Id,
	dead: bool,
	accs: [dynamic]Acc,
}

Acc :: struct {
	by:      prim.Id,
	msg:     i64,
	rid:     eng.Rid,
	index:   u32,
	text:    [dynamic]u8,
	started: bool,
	drafted: int,
	dup:     bool,
}

@(private = "file")
WORDS := [?]string{"alpha ", "beta ", "gamma ", "delta ", "streaming ", "token ", "draft ", "seal ", "relay ", "nonce ", "x", "yz ", "\n"}

@(private = "file")
_words :: proc(r: ^Rng, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for strings.builder_len(b) < n {
		strings.write_string(&b, WORDS[rng_int(r, len(WORDS))])
	}
	return strings.to_string(b)
}

op_stream :: proc(w: ^World, n: ^Node, oi: int) {
	m := &w.model
	o := m.objs[oi].o
	op := new_op(m, .Stream, n, oi)
	op.token = new_token(m, n, "d")
	st := new(M_Stream, w.allocator)
	st.op = op.idx
	st.node = n.idx
	st.inc = n.incarnation
	st.obj = oi
	st.blocks = make([dynamic][dynamic]u8, w.allocator)
	st.kinds = make([dynamic]convo.Block_Kind, w.allocator)
	rng_init(&st.rng, w.cfg.seed, 7_000_000 + u64(op.idx))
	st.steps = 3 + rng_int(&st.rng, 40)
	for x in w.nodes {
		if x.alive && obj_reader(m, oi, x.idx) {
			watch_start(w, x, oi)
		}
	}
	context = instance_context(&n.inst)
	wr, err := eng.convo_writer(&n.e, o)
	if err != .None {
		world_note(w, "%s stream %s on %s: writer %v", n.name, op.token, id_short(o.id), err)
		op_result(op, n, err)
		free(st, w.allocator)
		return
	}
	msg, merr := convo.writer_message(wr, convo.Msg_Spec{role = .Assistant})
	world_note(w, "%s stream %s on %s -> %s %v (%d steps)", n.name, op.token, id_short(o.id), rid_str(msg), merr, st.steps)
	if merr != .None {
		op_result(op, n, .Invalid if merr != .Io else .Io)
		free(st, w.allocator)
		return
	}
	op.rid = msg
	st.msg = msg
	eng.pin(&n.e, o)
	append(&w.streams, st)
	op_result(op, n, .None)
	_stream_write(w, n, st, wr, true)
	schedule(w, Sim_Event{at = w.now + rng_range(&st.rng, 1, 40) * 1_000_000, kind = .Stream_Step, arg = u64(len(w.streams) - 1)})
}

@(private = "file")
_stream_write :: proc(w: ^World, n: ^Node, st: ^M_Stream, wr: ^convo.Writer, first: bool) -> bool {
	text := _words(&st.rng, 1 + rng_int(&st.rng, 48) if !rng_chance(&st.rng, 1, 12) else 2000 + rng_int(&st.rng, 9000))
	if first {
		text = fmt.tprintf("%s %s", w.model.ops[st.op].token, text)
	}
	if first || rng_chance(&st.rng, 1, 7) {
		kind := convo.Block_Kind.Text if rng_chance(&st.rng, 3, 4) else .Reasoning
		idx, err := convo.writer_block(wr, st.msg, kind, transmute([]u8)text)
		if err != .None {
			world_note(w, "%s stream %s block: %v", n.name, w.model.ops[st.op].token, err)
			return false
		}
		st.cur = idx
		b := make([dynamic]u8, w.allocator)
		append(&b, text)
		append(&st.blocks, b)
		append(&st.kinds, kind)
	} else {
		if err := convo.writer_chunk(wr, st.msg, st.cur, transmute([]u8)text); err != .None {
			world_note(w, "%s stream %s chunk: %v", n.name, w.model.ops[st.op].token, err)
			return false
		}
		append(&st.blocks[len(st.blocks) - 1], text)
	}
	st.written += len(text)
	stat_add(w, STAT_STREAM_BYTES, u64(len(text)))
	return true
}

stream_step :: proc(w: ^World, si: int) {
	if si < 0 || si >= len(w.streams) {
		return
	}
	st := w.streams[si]
	if st.done {
		return
	}
	n := w.nodes[st.node]
	if !n.alive || n.incarnation != st.inc {
		return
	}
	m := &w.model
	o := m.objs[st.obj].o
	context = instance_context(&n.inst)
	wr, err := eng.convo_writer(&n.e, o)
	ok := err == .None
	if ok && st.steps > 0 {
		ok = _stream_write(w, n, st, wr, false)
		st.steps -= 1
	}
	if !ok || st.steps == 0 {
		serr := convo.Error.Invalid
		if err == .None {
			_, serr = convo.writer_seal(wr, st.msg, .Done)
		}
		st.done = true
		st.sealed = serr == .None
		st.failed = !ok
		eng.unpin(&n.e, o)
		world_note(w, "%s stream %s sealed %v (%d bytes)", n.name, m.ops[st.op].token, serr, st.written)
		node_after(n)
		return
	}
	node_after(n)
	schedule(w, Sim_Event{at = w.now + rng_range(&st.rng, 1, 40) * 1_000_000, kind = .Stream_Step, arg = u64(si)})
}

stream_after_restart :: proc(w: ^World, n: ^Node) {
	m := &w.model
	for st in w.streams {
		if st.node != n.idx || st.inc >= n.incarnation {
			continue
		}
		first := false
		if !st.done {
			st.done = true
			st.crashed = true
			first = true
		} else if !st.crashed && !st.reseal {
			if !st.sealed || m.ops[st.op].status == .Lost {
				continue
			}
			st.reseal = true
			first = true
		}
		if !st.crashed && !st.reseal {
			continue
		}
		if !n.alive {
			return
		}
		if m.ops[st.op].status == .Lost {
			if first {
				world_note(w, "%s stream %s lost in the crash: its message never became durable", n.name, m.ops[st.op].token)
			}
			continue
		}
		context = instance_context(&n.inst)
		wr, err := eng.convo_writer(&n.e, m.objs[st.obj].o)
		if err != .None {
			world_note(w, "%s stream %s recovery: writer %v", n.name, m.ops[st.op].token, err)
			node_after(n)
			continue
		}
		count, ierr := convo.writer_interrupt_open(wr, i64(1) << 62)
		if st.reseal || rng_chance(&st.rng, 1, 2) {
			list, k := convo.writer_revivable(wr)
			for r in list[:k] {
				convo.writer_decline(wr, r)
			}
		}
		if first || count > 0 {
			world_note(w, "%s stream %s interrupted after %s: %d open, %v", n.name, m.ops[st.op].token, "a crash" if first else "another crash", count, ierr)
		}
		node_after(n)
	}
	for x in w.watches {
		if x.node == n.idx && x.inc < n.incarnation && !x.dead {
			x.dead = true
			watch_start(w, n, x.obj)
		}
	}
}

watch_start :: proc(w: ^World, n: ^Node, oi: int) {
	for x in w.watches {
		if x.node == n.idx && x.obj == oi && x.inc == n.incarnation && !x.dead {
			return
		}
	}
	if !n.alive {
		return
	}
	x := new(Watch, w.allocator)
	x.w = w
	x.node = n.idx
	x.inc = n.incarnation
	x.obj = oi
	x.accs = make([dynamic]Acc, w.allocator)
	context = instance_context(&n.inst)
	sub, err := eng.subscribe(&n.e, w.model.objs[oi].o, .Conversation, _watch_cb, x)
	if err != .None {
		delete(x.accs)
		free(x, w.allocator)
		node_after(n)
		return
	}
	x.sub = sub
	append(&w.watches, x)
	node_after(n)
}

watches_node_killed :: proc(w: ^World, n: ^Node) {
	for x in w.watches {
		if x.node == n.idx {
			x.dead = true
		}
	}
}

@(private = "file")
_watch_cb :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	x := (^Watch)(data)
	w := x.w
	if x.dead {
		return
	}
	for d in deltas {
		if d.kind != .Block && d.kind != .Chunk {
			continue
		}
		a: ^Acc
		for &y in x.accs {
			if y.rid == d.msg && y.index == d.index {
				a = &y
				break
			}
		}
		if a == nil {
			append(&x.accs, Acc{by = d.msg.seg, msg = d.msg.off, rid = d.msg, index = d.index, text = make([dynamic]u8, w.allocator)})
			a = &x.accs[len(x.accs) - 1]
		}
		if d.kind == .Block {
			if a.started || len(a.text) > 0 {
				a.dup = true
			}
			a.started = true
		}
		append(&a.text, ..d.text)
		if d.draft {
			a.drafted += len(d.text)
			stat_add(w, STAT_DRAFT_DELTAS)
			stat_add(w, STAT_DRAFT_DELTA_BYTES, u64(len(d.text)))
			if !d.local {
				stat_add(w, STAT_REMOTE_DRAFT_BYTES, u64(len(d.text)))
			}
		} else {
			stat_add(w, STAT_SEG_DELTA_BYTES, u64(len(d.text)))
		}
	}
}

check_streams :: proc(w: ^World) {
	m := &w.model
	ready := eng.Ready{data = nil, call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}}
	for x in w.watches {
		n := w.nodes[x.node]
		if x.dead || !n.alive || n.incarnation != x.inc {
			continue
		}
		o := m.objs[x.obj].o
		for &a in x.accs {
			if a.dup {
				world_fail(w, "draft: %s received a second Block delta for block %d of %s:%d", n.name, a.index, id_short(a.by), a.msg)
				continue
			}
			context = instance_context(&n.inst)
			msg, merr := eng.convo_message(&n.e, o, convo.Position{msg = a.rid}, context.temp_allocator, ready)
			if merr != .None || msg.redacted {
				if a.drafted > 0 && merr != .None && merr != .Pending && !_stream_redacted(m, a.by, a.msg) {
					world_fail(w, "draft: %s saw %d draft bytes of %s:%d, which has no durable message (%v)", n.name, a.drafted, id_short(a.by), a.msg, merr)
				}
				continue
			}
			final: []u8
			found := false
			for b in msg.blocks {
				if b.index == a.index {
					final = b.text
					found = true
				}
			}
			if !found {
				if len(a.text) > 0 {
					world_fail(w, "draft: %s saw %q for block %d of %s:%d, which the sealed message lacks", n.name, _clip(a.text[:]), a.index, id_short(a.by), a.msg)
				}
				continue
			}
			ok := string(final) == string(a.text[:]) if a.started else strings.has_suffix(string(final), string(a.text[:]))
			if !ok {
				world_fail(w, "draft: %s saw %q (%d draft bytes, started=%v) for block %d of %s:%d but the block is %q (status %v)", n.name, _clip(a.text[:]), a.drafted, a.started, a.index, id_short(a.by), a.msg, _clip(final), msg.status)
			}
			stat_add(w, STAT_DRAFT_CHECKED)
		}
		node_after(n)
	}
	for st in w.streams {
		n := w.nodes[st.node]
		if !n.alive {
			continue
		}
		op := m.ops[st.op]
		if op.status == .Lost || _stream_redacted(m, st.msg.seg, st.msg.off) {
			continue
		}
		context = instance_context(&n.inst)
		msg, merr := eng.convo_message(&n.e, m.objs[st.obj].o, convo.Position{msg = st.msg}, context.temp_allocator, ready)
		if merr == .None && st.reseal && msg.status == .Interrupted {
			st.crashed = true
		}
		if merr != .None {
			if !st.crashed {
				world_fail(w, "stream: %s lost stream %s (%v) without a crash", n.name, op.token, merr)
			}
			node_after(n)
			continue
		}
		if msg.role != .Assistant || msg.author != op.actor {
			if !st.crashed {
				world_fail(w, "stream: %s stream %s message replaced", n.name, op.token)
			}
			node_after(n)
			continue
		}
		if len(msg.blocks) > len(st.blocks) {
			world_fail(w, "stream: %s stream %s has %d blocks, wrote %d", n.name, op.token, len(msg.blocks), len(st.blocks))
		}
		for b, i in msg.blocks {
			if i >= len(st.blocks) {
				break
			}
			want := string(st.blocks[i][:])
			got := string(b.text)
			if b.index != u32(i) || b.kind != st.kinds[i] || !strings.has_prefix(want, got) {
				world_fail(w, "stream: %s stream %s block %d is %q, wrote %q", n.name, op.token, i, _clip(b.text), _clip(st.blocks[i][:]))
			} else if st.sealed && !st.crashed && msg.status == .Done && got != want {
				world_fail(w, "stream: %s sealed stream %s block %d is %q, wrote %q", n.name, op.token, i, _clip(b.text), _clip(st.blocks[i][:]))
			}
		}
		if st.sealed && !st.crashed && msg.status == .Done && len(msg.blocks) != len(st.blocks) {
			world_fail(w, "stream: %s sealed stream %s has %d blocks, wrote %d", n.name, op.token, len(msg.blocks), len(st.blocks))
		}
		if st.crashed && (msg.status != .Interrupted || (msg.open && msg.open_state != .Revive)) {
			world_fail(w, "stream: %s crashed stream %s ended %v (open=%v state=%v), not Interrupted", n.name, op.token, msg.status, msg.open, msg.open_state)
		}
		if msg.open && msg.open_state == .Running && (st.sealed || st.crashed) {
			world_fail(w, "stream: %s stream %s still running after it ended (crashed=%v)", n.name, op.token, st.crashed)
		}
		node_after(n)
	}
}

@(private = "file")
_stream_redacted :: proc(m: ^Model, by: prim.Id, msg: i64) -> bool {
	for op in m.ops {
		if op.kind != .Redact_Msg || op.target < 0 || op.status == .Failed {
			continue
		}
		t := m.ops[op.target]
		if t.rid.seg == by && t.rid.off == msg {
			return true
		}
	}
	return false
}

@(private = "file")
_clip :: proc(b: []u8) -> string {
	if len(b) <= 160 {
		return string(b)
	}
	return fmt.tprintf("%s…%s", string(b[:80]), string(b[len(b) - 60:]))
}

streams_destroy :: proc(w: ^World) {
	for st in w.streams {
		for b in st.blocks {
			delete(b)
		}
		delete(st.blocks)
		delete(st.kinds)
		free(st, w.allocator)
	}
	delete(w.streams)
	for x in w.watches {
		for a in x.accs {
			delete(a.text)
		}
		delete(x.accs)
		free(x, w.allocator)
	}
	delete(w.watches)
}

STAT_STREAM_BYTES: Stat
STAT_DRAFT_FRAMES: Stat
STAT_DRAFT_DELTAS: Stat
STAT_DRAFT_DELTA_BYTES: Stat
STAT_REMOTE_DRAFT_BYTES: Stat
STAT_SEG_DELTA_BYTES: Stat
STAT_DRAFT_CHECKED: Stat

@(init)
_stream_stats :: proc "contextless" () {
	register_restarted(40, stream_after_restart)
	register_final_check(20, check_streams)
	register_stat_line(70)
	STAT_STREAM_BYTES = register_stat(70, 0, "streamed")
	STAT_DRAFT_FRAMES = register_stat(70, 1, "draft_frames")
	STAT_DRAFT_DELTAS = register_stat(70, 2, "draft_deltas")
	STAT_DRAFT_DELTA_BYTES = register_stat(70, 3, "draft_delta_bytes")
	STAT_REMOTE_DRAFT_BYTES = register_stat(70, 4, "remote_draft_bytes")
	STAT_SEG_DELTA_BYTES = register_stat(70, 5, "segment_delta_bytes")
	STAT_DRAFT_CHECKED = register_stat(70, 6, "draft_blocks_checked")
}

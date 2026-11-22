package sim

import "core:strings"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/prim"

Buf_Pending :: struct {
	seq: u64,
	ops: []crdt.Delta_Op,
}

Buf_In :: struct {
	ack:    u64,
	is_ack: bool,
	rev:    u64,
	ops:    []crdt.Delta_Op,
	closed: bool,
}

Sim_Buffer :: struct {
	w:       ^World,
	node:    int,
	inc:     int,
	oi:      int,
	path:    string,
	id:      eng.Buffer_Id,
	utf16:   bool,
	actor:   prim.Id,
	doc:     [dynamic]u8,
	rev:     u64,
	seq:     u64,
	pending: [dynamic]Buf_Pending,
	inbox:   [dynamic]Buf_In,
	groups:  [dynamic]string,
	dead:    bool,
}

Sim_Anchor :: struct {
	oi:     int,
	path:   string,
	anchor: eng.Anchor,
	token:  string,
	node:   int,
}

@(private = "file")
_ops_copy :: proc(w: ^World, ops: []crdt.Delta_Op) -> []crdt.Delta_Op {
	out := make([]crdt.Delta_Op, len(ops), w.allocator)
	for o, i in ops {
		out[i] = o
		if len(o.text) > 0 {
			out[i].text = transmute([]u8)strings.clone(string(o.text), w.allocator)
		}
	}
	return out
}

@(private = "file")
_on_buffer :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	b := (^Sim_Buffer)(data)
	w := b.w
	switch ev.kind {
	case .Delta:
		append(&b.inbox, Buf_In{ack = ev.ack, rev = ev.rev, ops = _ops_copy(w, ev.ops)})
	case .Closed:
		append(&b.inbox, Buf_In{closed = true})
	case .Cursors:
	}
}

@(private = "file")
_doc_apply :: proc(b: ^Sim_Buffer, ops: []crdt.Delta_Op) -> bool {
	at := 0
	for o in ops {
		switch o.kind {
		case .Retain:
			at += o.n
			if at > len(b.doc) {
				return false
			}
		case .Delete:
			if at + o.n > len(b.doc) {
				return false
			}
			remove_range(&b.doc, at, at + o.n)
		case .Insert:
			inject_at(&b.doc, at, ..o.text)
			at += len(o.text)
		}
	}
	return true
}

@(private = "file")
_receive :: proc(w: ^World, b: ^Sim_Buffer, x: Buf_In) {
	if x.closed {
		b.dead = true
		return
	}
	k := 0
	for k < len(b.pending) && b.pending[k].seq <= x.ack {
		k += 1
	}
	remove_range(&b.pending, 0, k)
	if x.is_ack {
		return
	}
	d := x.ops
	for &p in b.pending {
		a2 := make([dynamic]crdt.Delta_Op, w.allocator)
		b2 := make([dynamic]crdt.Delta_Op, context.temp_allocator)
		crdt.delta_transform(p.ops, d, b.utf16, &a2, &b2)
		p.ops = a2[:]
		d = b2[:]
	}
	if !_doc_apply(b, d) {
		world_fail(w, "buffer: %s buffer %d delta rev %d does not fit the client document (%d bytes)", w.nodes[b.node].name, b.id, x.rev, len(b.doc))
		b.dead = true
		return
	}
	b.rev = x.rev
}

buffers_deliver :: proc(w: ^World, b: ^Sim_Buffer, n: int) {
	k := 0
	for k < n && len(b.inbox) > 0 && !b.dead {
		x := b.inbox[0]
		ordered_remove(&b.inbox, 0)
		_receive(w, b, x)
		k += 1
	}
}

buffers_drop :: proc(w: ^World, n: ^Node) {
	i := 0
	for i < len(w.bufs) {
		if w.bufs[i].node == n.idx {
			unordered_remove(&w.bufs, i)
			continue
		}
		i += 1
	}
}

@(private = "file")
_live :: proc(w: ^World, n: ^Node) -> []^Sim_Buffer {
	out := make([dynamic]^Sim_Buffer, context.temp_allocator)
	for b in w.bufs {
		if b.node == n.idx && b.inc == n.incarnation && !b.dead {
			append(&out, b)
		}
	}
	return out[:]
}

op_buffer :: proc(w: ^World, n: ^Node, k: Op_Kind) {
	if !n.alive || !n.e_open {
		return
	}
	bs := _live(w, n)
	if k == .Buffer_Open || len(bs) == 0 {
		if len(bs) < 3 {
			_open(w, n)
		}
		return
	}
	b := bs[rng_int(&w.rng, len(bs))]
	buffers_deliver(w, b, rng_int(&w.rng, len(b.inbox) + 1))
	if b.dead {
		return
	}
	#partial switch k {
	case .Buffer_Burst:
		_burst(w, n, b)
	case .Buffer_Type:
		_type(w, n, b)
	case .Buffer_Delete:
		_delete(w, n, b)
	case .Buffer_Undo:
		_undo(w, n, b)
	case .Buffer_Anchor:
		_anchor(w, n, b)
	case .Buffer_Sync:
		buffers_deliver(w, b, len(b.inbox))
		_check_client(w, n, b)
	}
}

@(private = "file")
_new_buffer :: proc(w: ^World, n: ^Node, oi: int, path: string, utf16: bool) -> ^Sim_Buffer {
	b := new(Sim_Buffer, w.allocator)
	b^ = Sim_Buffer{w = w, node = n.idx, inc = n.incarnation, oi = oi, path = path, utf16 = utf16}
	b.doc = make([dynamic]u8, w.allocator)
	b.pending = make([dynamic]Buf_Pending, w.allocator)
	b.inbox = make([dynamic]Buf_In, w.allocator)
	b.groups = make([dynamic]string, w.allocator)
	return b
}

@(private = "file")
_keep :: proc(w: ^World, b: ^Sim_Buffer, info: ^eng.Buffer_Info) {
	b.id = info.id
	b.actor = info.actor
	append(&b.doc, ..info.page)
	if w.bufs == nil {
		w.bufs = make([dynamic]^Sim_Buffer, w.allocator)
	}
	append(&w.bufs, b)
	w.stats.buffers += 1
}

@(private = "file")
_open :: proc(w: ^World, n: ^Node) {
	m := &w.model
	kind := M_Kind.Text if rng_chance(&w.rng, 2, 3) else M_Kind.Tree
	oi := pick_obj(w, n, kind)
	if oi < 0 {
		return
	}
	path := ""
	if kind == .Tree {
		paths := TREE_PATHS
		path = paths[rng_int(&w.rng, len(paths))]
	}
	b := _new_buffer(w, n, oi, path, rng_chance(&w.rng, 1, 2))
	context = instance_context(&n.inst)
	info, err := eng.buffer_open(&n.e, m.objs[oi].o, eng.Buffer_Options{path = path, units = .Utf16 if b.utf16 else .Bytes, page = 0, cb = _on_buffer, data = b}, context.temp_allocator)
	world_note(w, "%s buffer open %s %q -> %v (buffer %d)", n.name, id_short(m.objs[oi].o.id), path, err, info.id)
	if err != .None {
		return
	}
	_keep(w, b, &info)
}

@(private = "file")
_edit :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer, pos: int, del: int, ins: string, group: u64) -> eng.Error {
	ops := make([dynamic]crdt.Delta_Op, w.allocator)
	crdt.delta_push(&ops, crdt.Delta_Op{kind = .Retain, n = pos})
	crdt.delta_push(&ops, crdt.Delta_Op{kind = .Delete, n = del})
	if len(ins) > 0 {
		crdt.delta_push(&ops, crdt.Delta_Op{kind = .Insert, n = len(ins), text = transmute([]u8)strings.clone(ins, w.allocator)})
	}
	crdt.delta_trim(&ops)
	context = instance_context(&n.inst)
	ack, applied, err := eng.buffer_edit(&n.e, b.id, b.rev, []eng.Buffer_Edit{{pos, del, transmute([]u8)ins}}, group)
	if err != .None {
		return err
	}
	seen := b.rev
	for x in b.inbox {
		if !x.is_ack && !x.closed {
			seen = x.rev
		}
	}
	if applied != seen {
		world_fail(w, "buffer: %s buffer %d edit result names rev %d but the deltas before it end at rev %d", n.name, b.id, applied, seen)
	}
	_doc_apply(b, ops[:])
	b.seq += 1
	if ack != b.seq {
		world_fail(w, "buffer: %s buffer %d acked %d for edit %d", n.name, b.id, ack, b.seq)
	}
	append(&b.pending, Buf_Pending{b.seq, ops[:]})
	append(&b.inbox, Buf_In{ack = ack, is_ack = true})
	return .None
}

@(private = "file")
_type :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer) {
	m := &w.model
	toks := parse_tokens(b.doc[:])
	pos := len(b.doc)
	if len(toks) > 0 && rng_chance(&w.rng, 2, 3) {
		t := toks[rng_int(&w.rng, len(toks))]
		pos = t.pos if rng_chance(&w.rng, 1, 2) else t.pos + len(t.text)
	} else if rng_chance(&w.rng, 1, 3) {
		pos = 0
	}
	op := new_op(m, .Buffer_Type, n, b.oi)
	op.actor = b.actor
	op.path = strings.clone(b.path, w.allocator)
	tok := new_token(m, n, "b")
	append(&op.tokens, tok)
	w.buf_group += 1
	err := _edit(w, n, b, pos, 0, tok, w.buf_group)
	world_note(w, "%s buffer %d type %s at %d rev %d -> %v", n.name, b.id, tok, pos, b.rev, err)
	op_result(op, n, err)
	if err == .None {
		append(&b.groups, tok)
	} else if err == .Conflict {
		b.dead = true
	}
}

@(private = "file")
_delete :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer) {
	m := &w.model
	toks := parse_tokens(b.doc[:])
	if len(toks) == 0 {
		return
	}
	t := toks[rng_int(&w.rng, len(toks))]
	op := new_op(m, .Buffer_Delete, n, b.oi)
	op.actor = b.actor
	op.path = strings.clone(b.path, w.allocator)
	append(&op.deletes, strings.clone(t.text, w.allocator))
	w.buf_group += 1
	err := _edit(w, n, b, t.pos, len(t.text), "", w.buf_group)
	world_note(w, "%s buffer %d delete %s at %d rev %d -> %v", n.name, b.id, t.text, t.pos, b.rev, err)
	op_result(op, n, err)
	if err == .None {
		append(&b.groups, "")
	} else if err == .Conflict {
		b.dead = true
	}
}

@(private = "file")
_undo :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer) {
	if len(b.groups) == 0 || len(b.groups[len(b.groups) - 1]) == 0 {
		return
	}
	buffers_deliver(w, b, len(b.inbox))
	if len(b.pending) > 0 || b.dead {
		return
	}
	tok := pop(&b.groups)
	op := new_op(&w.model, .Buffer_Undo, n, b.oi)
	op.actor = b.actor
	op.path = strings.clone(b.path, w.allocator)
	append(&op.deletes, strings.clone(tok, w.allocator))
	context = instance_context(&n.inst)
	done, err := eng.buffer_undo(&n.e, b.id)
	world_note(w, "%s buffer %d undo %s -> %v %v", n.name, b.id, tok, done, err)
	if err == .None && !done {
		world_fail(w, "buffer: %s buffer %d had nothing to undo for %s", n.name, b.id, tok)
	}
	op_result(op, n, err)
}

@(private = "file")
_anchor :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer) {
	buffers_deliver(w, b, len(b.inbox))
	if len(b.pending) > 0 || b.dead || w.model.objs[b.oi].kind != .Text {
		return
	}
	toks := parse_tokens(b.doc[:])
	if len(toks) == 0 {
		return
	}
	t := toks[rng_int(&w.rng, len(toks))]
	context = instance_context(&n.inst)
	list, err := eng.buffer_anchors(&n.e, b.id, b.rev, []int{t.pos}, .Before, context.temp_allocator)
	if err != .None {
		return
	}
	pos, _, _, rerr := eng.buffer_resolve(&n.e, b.id, b.rev, list, context.temp_allocator)
	if rerr == .None && pos[0] != t.pos {
		world_fail(w, "anchor: %s buffer %d anchor for %s at %d resolves to %d", n.name, b.id, t.text, t.pos, pos[0])
	}
	if w.anchors == nil {
		w.anchors = make([dynamic]Sim_Anchor, w.allocator)
	}
	append(&w.anchors, Sim_Anchor{oi = b.oi, path = strings.clone(b.path, w.allocator), anchor = list[0], token = strings.clone(t.text, w.allocator), node = n.idx})
}

@(private = "file")
_burst :: proc(w: ^World, n: ^Node, a: ^Sim_Buffer) {
	if w.model.objs[a.oi].kind != .Text {
		return
	}
	other: ^Sim_Buffer
	for x in _live(w, n) {
		if x != a && x.oi == a.oi && x.actor != a.actor {
			other = x
		}
	}
	if other == nil {
		ob := _new_buffer(w, n, a.oi, "", !a.utf16)
		actor: prim.Id
		for i in 0 ..< 16 {
			actor[i] = u8(rng_int(&w.rng, 256))
		}
		context = instance_context(&n.inst)
		info, err := eng.buffer_open(&n.e, w.model.objs[a.oi].o, eng.Buffer_Options{units = .Utf16 if ob.utf16 else .Bytes, actor = actor, cb = _on_buffer, data = ob}, context.temp_allocator)
		if err != .None {
			return
		}
		_keep(w, ob, &info)
		other = ob
	}
	rounds := 200 + rng_int(&w.rng, 200)
	world_note(w, "%s buffer burst of %d edits on buffers %d and %d", n.name, rounds, a.id, other.id)
	for i in 0 ..< rounds {
		b := a if i % 2 == 0 else other
		buffers_deliver(w, b, rng_int(&w.rng, len(b.inbox) + 1))
		if b.dead || a.dead || other.dead || !n.alive {
			return
		}
		if rng_chance(&w.rng, 1, 10) {
			_delete(w, n, b)
		} else {
			_type(w, n, b)
		}
		node_after(n)
		if !n.alive {
			return
		}
	}
	buffers_deliver(w, a, len(a.inbox))
	buffers_deliver(w, other, len(other.inbox))
	_check_client(w, n, a)
	_check_client(w, n, other)
	w.stats.bursts += 1
}

@(private = "file")
_check_client :: proc(w: ^World, n: ^Node, b: ^Sim_Buffer) {
	if len(b.pending) > 0 || len(b.inbox) > 0 || b.dead {
		return
	}
	context = instance_context(&n.inst)
	text, rev, err := eng.buffer_text(&n.e, b.id, context.temp_allocator)
	if err != .None || rev != b.rev {
		return
	}
	if string(text) != string(b.doc[:]) {
		world_fail(w, "buffer: %s buffer %d client document diverged from its view at rev %d:\n--- client\n%s\n--- view\n%s", n.name, b.id, b.rev, string(b.doc[:]), string(text))
	}
}

check_buffers :: proc(w: ^World) {
	m := &w.model
	for b in w.bufs {
		n := w.nodes[b.node]
		if !n.alive || b.inc != n.incarnation || b.dead {
			continue
		}
		buffers_deliver(w, b, len(b.inbox))
		if b.dead {
			continue
		}
		_check_client(w, n, b)
		if m.objs[b.oi].kind == .Text && obj_exists(m, b.oi) {
			context = instance_context(&n.inst)
			view, _, verr := eng.buffer_text(&n.e, b.id, context.temp_allocator)
			truth, terr := eng.text_read(&n.e, m.objs[b.oi].o, context.temp_allocator)
			if verr == .None && terr == .None && string(view) != string(truth) {
				world_fail(w, "buffer: %s buffer %d view differs from the converged text:\n--- view\n%s\n--- text\n%s", n.name, b.id, string(view), string(truth))
			}
		}
		node_after(n)
	}
	Seen :: struct {
		node: string,
		text: string,
		pos:  int,
	}
	for a in w.anchors {
		if !obj_exists(m, a.oi) {
			continue
		}
		seen := make([dynamic]Seen, context.temp_allocator)
		for idx in readers_of(w, a.oi) {
			n := w.nodes[idx]
			if !n.alive || !n.e_open {
				continue
			}
			context = instance_context(&n.inst)
			info, err := eng.buffer_open(&n.e, m.objs[a.oi].o, eng.Buffer_Options{path = a.path, page = 0}, context.temp_allocator)
			if err != .None {
				node_after(n)
				continue
			}
			pos, _, _, rerr := eng.buffer_resolve(&n.e, info.id, info.rev, []eng.Anchor{a.anchor}, context.temp_allocator)
			text := strings.clone(string(info.page), w.allocator)
			eng.buffer_close(&n.e, info.id)
			node_after(n)
			if rerr != .None {
				delete(text, w.allocator)
				continue
			}
			p := pos[0]
			at := strings.index(text, a.token)
			if at >= 0 && p < 0 {
				world_fail(w, "anchor: %s for %s is present on %s but its anchor does not resolve", a.token, id_short(m.objs[a.oi].o.id), n.name)
			}
			if at >= 0 && p >= 0 && p != at {
				world_fail(w, "anchor: %s for %s resolves to %d on %s but the token is at %d", a.token, id_short(m.objs[a.oi].o.id), p, n.name, at)
			}
			for x in seen {
				if x.text == text && x.pos != p {
					world_fail(w, "anchor: %s for %s resolves to %d on %s but %d on %s, which shows the same text", a.token, id_short(m.objs[a.oi].o.id), p, n.name, x.pos, x.node)
					break
				}
			}
			append(&seen, Seen{n.name, text, p})
			w.stats.anchors_checked += 1
		}
		for x in seen {
			delete(x.text, w.allocator)
		}
	}
}

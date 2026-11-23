package convo

import "base:runtime"
import "core:mem"
import "core:slice"
import "../obj"
import "../prim"

Tail :: struct {
	self:        int,
	head:        Vref,
	head_hlc:    prim.Hlc,
	position:    Vref,
	browsing:    bool,
	head_status: Seal_Status,
	queued:      int,
	waiting:     int,
	held:        int,
	intents:     int,
	running:     bool,
	awaiting:    bool,
	revive:      bool,
	status:      Status,
	virtual:     [dynamic]Entry,
	tips:        [dynamic]Pos,
}

Position :: struct {
	msg:        Rid,
	seal:       Rid,
	seal_known: bool,
}

Block_View :: struct {
	index:  u32,
	kind:   Block_Kind,
	failed: bool,
	id:     string,
	name:   string,
	text:   []u8,
	is_ref: bool,
	blob:   Blob,
	off:    i64,
}

Message :: struct {
	id:          Rid,
	role:        Role,
	author:      prim.Id,
	parent:      Rid,
	depth:       i64,
	runner:      prim.Id,
	hlc:         prim.Hlc,
	files:       []File_Delta,
	provider:    string,
	model:       string,
	native:      string,
	native_msg:  string,
	intent:      Rid,
	parent_seal: Rid,
	status:      Seal_Status,
	open:        bool,
	open_state:  Open_State,
	hold_reason: Hold_Reason,
	hold_line:   string,
	seal:        Rid,
	last_block:  i64,
	usage:       Usage,
	seal_native: string,
	blocks:      []Block_View,
	redacted:    bool,
	sibling:     int,
	siblings:    int,
	superseded:  bool,
	landed:      bool,
	landed_as:   Seal_Status,
	claim:       Rid,
	lines:       []Line,
}

Page :: struct {
	messages: []Message,
	next:     Position,
	more:     bool,
}

Intent :: struct {
	item:        Rid,
	latest:      Rid,
	kind:        Kind,
	by:          prim.Id,
	stamp:       prim.Hlc,
	text:        string,
	attachments: []Attachment,
	target:      Rid,
	allow:       bool,
	tasks:       []prim.Id,
	condition:   Condition,
	deadline:    prim.Hlc,
	key:         string,
	expr:        string,
}

Unsealed :: struct {
	msg:     Rid,
	state:   Open_State,
	attempt: u8,
}

Compaction :: struct {
	at:      Rid,
	from:    Rid,
	to:      Rid,
	summary: string,
	blob:    Blob,
	stamp:   prim.Hlc,
}

@(private)
Pend :: struct {
	item:         Vref,
	latest:       Vref,
	kind:         Kind,
	stamp:        prim.Hlc,
	latest_stamp: prim.Hlc,
}

@(private)
Chunk :: struct {
	off:   i64,
	index: u32,
	flags: Block_Flags,
	kind:  Block_Kind,
	id:    string,
	name:  string,
	data:  []u8,
	blob:  Blob,
}

view_position :: proc(v: ^obj.View, self: prim.Id) -> (pos: Pos, head: Pos, browsing: bool, err: Error) {
	pos, head, browsing, _ = _positions(v, self) or_return
	return
}

@(private)
_positions :: proc(v: ^obj.View, self: prim.Id) -> (pos: Pos, head: Pos, browsing: bool, literal: Pos, err: Error) {
	missing := false
	for s in 0 ..< len(v.segs) {
		sum, ok, e := _tail(v, s)
		if e == .Missing {
			missing = true
			continue
		}
		if e != .None {
			return pos, head, false, pos, e
		}
		if ok && sum.tip != 0 {
			id := v.segs[s].id
			if obj.vref_none(head.at) || sum.tip_hlc > head.hlc || (sum.tip_hlc == head.hlc && obj.id_less(head.by, id)) {
				head = Pos{Vref{s, sum.tip}, sum.tip_hlc, id}
			}
		}
	}
	if missing {
		return pos, head, false, pos, .Missing
	}
	pos = head
	literal = head
	me := obj.view_find(v, self) if !prim.id_is_zero(self) else -1
	if me < 0 {
		return pos, head, false, literal, .None
	}
	sum, ok := _tail(v, me) or_return
	if !ok || obj.ref_none(sum.leaf) || sum.leaf_hlc <= sum.tip_hlc {
		return pos, head, false, literal, .None
	}
	l := obj.resolve(v, me, sum.leaf) or_return
	literal = Pos{l, sum.leaf_hlc, v.segs[me].id}
	if !obj.vref_none(head.at) {
		if up := is_ancestor(v, l, head.at) or_return; up && head.hlc > sum.leaf_hlc {
			return head, head, false, literal, .None
		}
	}
	return literal, head, true, literal, .None
}

view_tail :: proc(v: ^obj.View, self: prim.Id = {}, allocator := context.allocator) -> (t: Tail, err: Error) {
	t.self = obj.view_find(v, self) if !prim.id_is_zero(self) else -1
	t.virtual = make([dynamic]Entry, allocator)
	t.tips = make([dynamic]Pos, allocator)
	pos, head, browsing := view_position(v, self) or_return
	t.head = head.at
	t.head_hlc = head.hlc
	t.position = pos.at
	t.browsing = browsing
	missing := false
	for s in 0 ..< len(v.segs) {
		sum, ok := _tail(v, s) or_return
		if !ok {
			continue
		}
		for o in summary_open(&sum) {
			moved, merr := _open_reassigned(v, s, o.msg)
			if merr == .Missing {
				missing = true
			} else if merr != .None {
				return t, merr
			}
			if moved {
				if t.head == (Vref{s, o.msg}) {
					t.running = true
				}
				continue
			}
			if o.state != .Running {
				t.revive = true
				continue
			}
			t.running = true
			if o.last == 0 {
				continue
			}
			b, _, e := obj.get(v, s, o.last)
			if e == .Missing {
				missing = true
				continue
			}
			if e != .None {
				return t, e
			}
			if obj.is_redacted(b) {
				continue
			}
			rec := decode_record(b, o.last, v.scratch) or_return
			if blk, isb := rec.body.(Block); isb && .Start in blk.flags && (blk.kind == .Permission || blk.kind == .Question) {
				t.awaiting = true
			}
		}
	}
	if !obj.vref_none(t.head) {
		msg := Message{}
		hs := Vref{}
		if _, e := _seal_info(v, t.head, {}, false, &msg, &hs); e == .Missing {
			missing = true
		} else if e != .None {
			return t, e
		}
		t.head_status = msg.status
	}
	pend := make([dynamic]Pend, v.scratch)
	if e := _pending(v, &pend); e == .Missing {
		missing = true
	} else if e != .None {
		return t, e
	}
	for p in pend {
		t.intents += 1
		#partial switch p.kind {
		case .Queue, .Steer:
			t.queued += 1
		case .Await:
			t.waiting += 1
		case .Hold:
			t.held += 1
		}
	}
	if e := _virtual(v, &t); e == .Missing {
		missing = true
	} else if e != .None {
		return t, e
	}
	if missing {
		return t, .Missing
	}
	t.status = derive_status(&t)
	return t, .None
}

@(private)
_open_reassigned :: proc(v: ^obj.View, s: int, msg: i64) -> (moved: bool, err: Error) {
	n := _node(v, Vref{s, msg}) or_return
	if obj.vref_none(n.parent) {
		return false, .None
	}
	p := _node(v, n.parent) or_return
	st: Structure
	structure_load(v, nil, p.hlc, &st) or_return
	winner := assignee_of(&st, n.parent, p.runner)
	return !prim.id_is_zero(winner) && winner != v.segs[s].id, .None
}

tail_destroy :: proc(t: ^Tail) {
	delete(t.virtual)
	delete(t.tips)
	t^ = {}
}

derive_status :: proc "contextless" (t: ^Tail) -> Status {
	switch {
	case t.running && t.awaiting:
		return .Awaiting_Permission
	case t.running:
		return .Running
	case t.queued > 0:
		return .Queued
	case t.waiting > 0:
		return .Waiting
	case t.held > 0:
		return .Held
	case t.revive:
		return .Reviving
	case t.head_status == .Failed:
		return .Failed
	case t.head_status == .Interrupted:
		return .Interrupted
	}
	return .Idle
}

tail_head :: proc(v: ^obj.View, t: ^Tail) -> (Rid, Error) {
	return obj.rid(v, t.head)
}

tail_position :: proc(v: ^obj.View, t: ^Tail) -> (Rid, Error) {
	return obj.rid(v, t.position)
}

unsealed :: proc(v: ^obj.View, allocator := context.allocator) -> (out: []Unsealed, err: Error) {
	list := make([dynamic]Unsealed, allocator)
	for s in 0 ..< len(v.segs) {
		sum, ok := _tail(v, s) or_return
		if !ok {
			continue
		}
		for o in summary_open(&sum) {
			r := obj.rid(v, Vref{s, o.msg}) or_return
			append(&list, Unsealed{r, o.state, o.attempt})
		}
	}
	return list[:], .None
}

Direction :: enum u8 {
	Older,
	Newer,
}

Window :: struct {
	messages:   []Message,
	anchor:     int,
	older:      Position,
	newer:      Position,
	more_older: bool,
	more_newer: bool,
	leaf:       Rid,
}

page :: proc(v: ^obj.View, t: ^Tail, from: Position, limit: int, allocator := context.allocator, dir := Direction.Older, leaf := Rid{}) -> (p: Page, err: Error) {
	if dir == .Newer {
		return _page_newer(v, t, from, limit, leaf, allocator)
	}
	return _page_older(v, t, from, limit, allocator)
}

page_around :: proc(v: ^obj.View, t: ^Tail, anchor: Rid, before: int, after: int, leaf := Rid{}, allocator := context.allocator) -> (w: Window, err: Error) {
	if obj.rid_none(anchor) || before < 0 || after < 0 {
		return w, .Invalid
	}
	older, oe := _page_older(v, t, Position{msg = anchor}, before + 1, allocator)
	newer, ne := _page_newer(v, t, Position{msg = anchor}, after, leaf, allocator)
	if oe != .None && oe != .Missing {
		return w, oe
	}
	if ne != .None && ne != .Missing {
		return w, ne
	}
	if oe == .Missing || ne == .Missing {
		return w, .Missing
	}
	list := make([]Message, len(older.messages) + len(newer.messages), allocator)
	for m, i in older.messages {
		list[len(older.messages) - 1 - i] = m
	}
	copy(list[len(older.messages):], newer.messages)
	w.messages = list
	w.anchor = len(older.messages) - 1
	w.older = older.next
	w.more_older = older.more
	w.newer = newer.next
	w.more_newer = newer.more
	w.leaf = leaf
	if obj.rid_none(leaf) {
		w.leaf = obj.rid(v, t.position) or_return
	}
	return w, .None
}

switch_window :: proc(v: ^obj.View, t: ^Tail, sibling: Rid, before: int, after: int, allocator := context.allocator) -> (leaf: Rid, w: Window, err: Error) {
	le: Error
	leaf, le = switch_target(v, t, sibling)
	if le == .Missing {
		_page_older(v, t, Position{msg = sibling}, before + 1, allocator)
	}
	if le != .None {
		return {}, w, le
	}
	w = page_around(v, t, sibling, before, after, leaf, allocator) or_return
	return leaf, w, .None
}

@(private)
_page_newer :: proc(v: ^obj.View, t: ^Tail, from: Position, limit: int, leaf: Rid, allocator: runtime.Allocator) -> (p: Page, err: Error) {
	lv := t.position
	if !obj.rid_none(leaf) {
		lv = _msg_at(v, leaf) or_return
	}
	p.next = from
	if obj.vref_none(lv) || limit < 0 {
		return p, .Invalid if limit < 0 else .None
	}
	ln, le := _node(v, lv)
	fv := Vref{}
	fd: i64
	floor: prim.Hlc
	fe := Error.None
	if !obj.rid_none(from.msg) {
		fv = _msg_at(v, from.msg) or_return
		fn: Node
		fn, fe = _node(v, fv)
		if fe == .Missing {
			_prefetch_structure(v, t, fv)
		}
		fd = fn.depth
		floor = fn.hlc
	}
	if le != .None {
		return p, le
	}
	if fe != .None {
		return p, fe
	}
	if fd >= ln.depth {
		return p, .None
	}
	top := min(fd + i64(limit), ln.depth)
	st: Structure
	if se := structure_load(v, t, floor, &st); se != .None {
		return p, se
	}
	e := Entry{
		leaf        = lv,
		leaf_depth  = ln.depth,
		child_depth = 1,
	}
	missing := false
	if fd > 0 {
		at, ae := chain_at(v, &st, e, fd)
		if ae == .Missing {
			missing = true
		} else if ae != .None {
			return p, ae
		} else if at != fv {
			return p, .Invalid
		}
	}
	topv := lv
	if top < ln.depth {
		at, ae := chain_at(v, &st, e, top)
		if ae == .Missing {
			missing = true
		} else if ae != .None {
			return p, ae
		}
		topv = at
	}
	if limit == 0 {
		p.more = fd < ln.depth
		return p, .Missing if missing else .None
	}
	if missing {
		_spine_prefetch(v, t, fd + 1, top, floor)
		return p, .Missing
	}
	top_rid := obj.rid(v, topv) or_return
	older := _page_older(v, t, Position{msg = top_rid}, int(top - fd), allocator) or_return
	list := make([]Message, len(older.messages), allocator)
	for m, i in older.messages {
		list[len(older.messages) - 1 - i] = m
	}
	p.messages = list
	p.next = Position{msg = top_rid}
	p.more = top < ln.depth
	return p, .None
}

@(private)
_page_older :: proc(v: ^obj.View, t: ^Tail, from: Position, limit: int, allocator := context.allocator) -> (p: Page, err: Error) {
	cur := Vref{}
	seal := Vref{}
	known := false
	next := from
	if obj.rid_none(from.msg) {
		cur = t.position
		next = Position{msg = obj.rid(v, cur) or_return}
	} else {
		cur = _msg_at(v, from.msg) or_return
		known = from.seal_known
		if known && !obj.rid_none(from.seal) {
			seal = obj.vref(v, from.seal) or_return
		}
	}
	if limit <= 0 || obj.vref_none(cur) {
		p.next = next
		p.more = !obj.vref_none(cur)
		return p, .None
	}
	out := make([dynamic]Message, 0, limit, allocator)
	missing := false
	prev_depth: i64 = -1
	floor := max(prim.Hlc)
	open_parent := false
	for !obj.vref_none(cur) && len(out) < limit {
		msg := Message{}
		below := obj.end(v, cur.seg)
		re := _resolve_body(v, cur, seal, known, &msg, &below, allocator)
		if re != .None && re != .Missing && re != .Unknown_Segment {
			return p, re
		}
		body, _, e := obj.get_before(v, cur.seg, cur.off, below)
		if e == .Missing {
			obj.want_chain(v, cur.seg, 0, cur.off + obj.MSG_GUESS)
			if len(out) == 0 {
				_prefetch_structure(v, t, cur)
			} else {
				_spine_prefetch(v, t, prev_depth - i64(limit - len(out)), prev_depth - 1, floor)
			}
			missing = true
			break
		}
		if e != .None {
			return p, e
		}
		if re != .None {
			missing = true
		}
		m := _decode_msg(body, cur.off) or_return
		if prev_depth >= 0 && prev_depth != m.depth + 1 {
			return p, .Corrupt
		}
		if fe := _fill_message(v, cur, body, &m, &msg, allocator); fe != .None {
			if fe != .Missing {
				return p, fe
			}
			missing = true
			break
		}
		here := Position{msg.id, msg.seal if known && !obj.vref_none(seal) else {}, known}
		if open_parent {
			out[len(out) - 1].parent = here.msg
			out[len(out) - 1].parent_seal = here.seal
			open_parent = false
		}
		next = here
		floor = min(floor, m.hlc)
		prev_depth = m.depth
		parent, pe := obj.resolve(v, cur.seg, m.parent)
		pseal, pse := obj.resolve(v, cur.seg, m.parent_seal)
		append(&out, msg)
		if pe != .None || pse != .None {
			missing = true
			cur = {}
			next = {}
			break
		}
		cur = parent
		seal = pseal
		known = obj.vref_none(parent) || !obj.vref_none(pseal)
		open_parent = !obj.vref_none(parent)
		if !open_parent {
			next = Position{{}, {}, known}
		}
	}
	if open_parent && len(out) > 0 {
		last := &out[len(out) - 1]
		pr, pre := obj.rid(v, cur)
		ps: Rid
		pse := Error.None
		if pre == .None && known && !obj.vref_none(seal) {
			ps, pse = obj.rid(v, seal)
		}
		switch {
		case pre == .None && pse == .None:
			last.parent = pr
			last.parent_seal = ps
			next = Position{pr, ps, known}
		case pre == .Missing || pse == .Missing:
			missing = true
			pop(&out)
			cur = {}
		case:
			return p, pre if pre != .None else pse
		}
	}
	if !obj.vref_none(cur) && len(out) > 0 {
		if n, e := _node(v, cur); e == .None {
			floor = min(floor, n.hlc)
		} else if e == .Missing {
			missing = true
		} else {
			return p, e
		}
	} else if len(out) > 0 && obj.vref_none(cur) {
		floor = 0
	}
	if len(out) > 0 && !missing {
		if se := _page_siblings(v, t, out[:], floor, allocator); se == .Missing {
			missing = true
		} else if se != .None {
			return p, se
		}
	}
	p.messages = out[:]
	p.next = next
	p.more = !obj.rid_none(next.msg)
	if missing {
		return p, .Missing
	}
	return p, .None
}

message :: proc(v: ^obj.View, t: ^Tail, pos: Position, allocator := context.allocator) -> (msg: Message, err: Error) {
	pg := page(v, t, pos, 1, allocator) or_return
	if len(pg.messages) == 0 {
		return msg, .Not_Found
	}
	return pg.messages[0], .None
}

siblings :: proc(v: ^obj.View, t: ^Tail, msg: Rid, allocator := context.allocator) -> (list: []Rid, pos: int, err: Error) {
	x := _msg_at(v, msg) or_return
	n, ne := _node(v, x)
	if ne == .Missing {
		_prefetch_structure(v, t, x)
	}
	if ne != .None {
		return nil, 0, ne
	}
	floor: prim.Hlc
	if !obj.vref_none(n.parent) {
		pn := _node(v, n.parent) or_return
		floor = pn.hlc
	}
	st: Structure
	structure_load(v, t, floor, &st) or_return
	one := []Kid_Set{{at = x, parent = n.parent, depth = n.depth, hlc = n.hlc}}
	_collect_siblings(v, &st, one) or_return
	kids := one[0].kids[:]
	out := make([]Rid, len(kids), allocator)
	for k, i in kids {
		out[i] = obj.rid(v, k.child) or_return
		if k.child == x {
			pos = i + 1
		}
	}
	return out, pos, .None
}

switch_target :: proc(v: ^obj.View, t: ^Tail, s: Rid) -> (leaf: Rid, err: Error) {
	sv := _msg_at(v, s) or_return
	ns, ne := _node(v, sv)
	if ne == .Missing {
		_prefetch_structure(v, t, sv)
	}
	if ne != .None {
		return {}, ne
	}
	st: Structure
	structure_load(v, t, ns.hlc, &st) or_return
	list := make([dynamic]Entry, v.scratch)
	for e in chains(&st) {
		if e.child_depth - 1 > ns.depth || e.leaf_depth < ns.depth {
			continue
		}
		append(&list, e)
	}
	slice.sort_by(list[:], proc(a, b: Entry) -> bool {
		if a.leaf_hlc != b.leaf_hlc {
			return a.leaf_hlc > b.leaf_hlc
		}
		return obj.id_less(b.leaf_by, a.leaf_by)
	})
	missing := false
	for e in list {
		at, ae := chain_at(v, &st, e, ns.depth)
		if ae == .Missing {
			missing = true
			continue
		}
		if ae != .None {
			return {}, ae
		}
		if at == sv {
			if missing {
				return {}, .Missing
			}
			return obj.rid(v, e.leaf)
		}
	}
	if missing {
		return {}, .Missing
	}
	return obj.rid(v, sv)
}

assignee :: proc(v: ^obj.View, t: ^Tail, msg: Rid) -> (runner: prim.Id, err: Error) {
	x := _msg_at(v, msg) or_return
	n := _node(v, x) or_return
	st: Structure
	structure_load(v, t, n.hlc, &st) or_return
	return assignee_of(&st, x, n.runner), .None
}

mounts :: proc(v: ^obj.View, allocator := context.allocator) -> (out: []Mount_Entry, err: Error) {
	st: Structure
	structure_load(v, nil, 0, &st) or_return
	set := mount_set(&st, v.scratch)
	res := make([]Mount_Entry, len(set), allocator)
	for m, i in set {
		res[i] = m
		res[i].name = obj.clone_str(m.name, allocator) or_return
		res[i].path = obj.clone_str(m.path, allocator) or_return
	}
	return res, .None
}

files_at :: proc(v: ^obj.View, msg: Rid, allocator := context.allocator) -> (out: []File_Delta, err: Error) {
	x := obj.vref(v, msg) or_return
	names := make([dynamic]string, v.scratch)
	ms := mounts(v, v.scratch) or_return
	for m in ms {
		append(&names, m.name)
	}
	if len(names) == 0 {
		return nil, .None
	}
	return _files_walk(v, x, names[:], allocator)
}

@(private)
_files_walk :: proc(v: ^obj.View, x: Vref, names: []string, allocator: runtime.Allocator) -> (out: []File_Delta, err: Error) {
	list := make([dynamic]File_Delta, allocator)
	Walk_Ctx :: struct {
		list:      ^[dynamic]File_Delta,
		wanted:    map[string]bool,
		seen:      map[string]bool,
		all:       bool,
		allocator: runtime.Allocator,
	}
	c := Walk_Ctx{
		list      = &list,
		wanted    = make(map[string]bool, v.scratch),
		seen      = make(map[string]bool, v.scratch),
		all       = names == nil,
		allocator = allocator,
	}
	for nm in names {
		c.wanted[nm] = true
	}
	take :: proc(c: ^Walk_Ctx, files: []File_Delta) -> Error {
		for f in files {
			if (!c.all && f.mount not_in c.wanted) || f.mount in c.seen {
				continue
			}
			cl := f
			cl.mount = obj.clone_str(f.mount, c.allocator) or_return
			cl.version = obj.clone_bytes(f.version, c.allocator) or_return
			c.seen[cl.mount] = true
			append(c.list, cl)
		}
		return .None
	}
	cur := x
	for !obj.vref_none(cur) {
		if !c.all && len(list) == len(c.wanted) {
			break
		}
		body, _ := obj.get(v, cur.seg, cur.off) or_return
		m := _decode_msg(body, cur.off) or_return
		take(&c, m.files) or_return
		if len(m.files) > 0 && m.files_run == 0 {
			take(&c, m.files_base) or_return
			more := m.files_more
			for more != 0 && (c.all || len(list) < len(c.wanted)) {
				fb, _ := obj.get(v, cur.seg, more) or_return
				fr := decode_record(fb, more, v.scratch) or_return
				chunk, ok := fr.body.(Files)
				if !ok || (chunk.next != 0 && chunk.next >= more) {
					return nil, .Corrupt
				}
				take(&c, chunk.files) or_return
				more = chunk.next
			}
			break
		}
		cur = obj.resolve(v, cur.seg, m.files_prev) or_return
	}
	return list[:], .None
}

compactions :: proc(v: ^obj.View, floor: prim.Hlc, allocator := context.allocator) -> (out: []Compaction, err: Error) {
	Acc :: struct {
		list:      [dynamic]Compaction,
		v:         ^obj.View,
		allocator: runtime.Allocator,
	}
	acc := Acc{make([dynamic]Compaction, allocator), v, allocator}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		a := (^Acc)(data)
		if env.kind != u8(Kind.Compact) {
			return false, .None
		}
		rec := decode_env(env, a.v.scratch) or_return
		c := rec.body.(Compact)
		from := obj.resolve(a.v, s, c.from) or_return
		to := obj.resolve(a.v, s, c.to) or_return
		item := Compaction{
			at    = obj.rid(a.v, Vref{s, off}) or_return,
			from  = obj.rid(a.v, from) or_return,
			to    = obj.rid(a.v, to) or_return,
			stamp = rec.stamp,
		}
		item.summary = obj.clone_str(c.summary, a.allocator) or_return
		item.blob.oid = obj.clone_bytes(c.blob.oid, a.allocator) or_return
		item.blob.size = c.blob.size
		item.blob.preview = obj.clone_bytes(c.blob.preview, a.allocator) or_return
		append(&a.list, item)
		return false, .None
	}
	for s in 0 ..< len(v.segs) {
		obj.walk_events(v, s, floor, &acc, visit) or_return
	}
	slice.sort_by(acc.list[:], proc(a, b: Compaction) -> bool {
		return a.stamp < b.stamp
	})
	return acc.list[:], .None
}

intents :: proc(v: ^obj.View, allocator := context.allocator) -> (items: []Intent, err: Error) {
	pend := make([dynamic]Pend, v.scratch)
	_pending(v, &pend) or_return
	out := make([]Intent, len(pend), allocator)
	for p, i in pend {
		it := &out[i]
		it.item = obj.rid(v, p.item) or_return
		it.latest = obj.rid(v, p.latest) or_return
		it.kind = p.kind
		it.by = obj.seg_id(v, p.item)
		it.stamp = p.stamp
		body, _ := obj.get(v, p.latest.seg, p.latest.off) or_return
		if obj.is_redacted(body) {
			continue
		}
		rec := decode_record(body, p.latest.off, v.scratch) or_return
		#partial switch r in rec.body {
		case Queue:
			it.text = obj.clone_str(r.text, allocator) or_return
			it.attachments = _clone_atts(r.attachments, allocator) or_return
		case Steer:
			it.text = obj.clone_str(r.text, allocator) or_return
			it.attachments = _clone_atts(r.attachments, allocator) or_return
			if t, e := obj.resolve(v, p.latest.seg, r.msg); e == .None {
				it.target = obj.rid(v, t) or_return
			}
		case Edit_Queued:
			it.text = obj.clone_str(r.text, allocator) or_return
			it.attachments = _clone_atts(r.attachments, allocator) or_return
		case Interrupt:
			if t, e := obj.resolve(v, p.latest.seg, r.msg); e == .None {
				it.target = obj.rid(v, t) or_return
			}
		case Answer:
			it.allow = r.allow
			it.text = obj.clone_str(r.text, allocator) or_return
			if t, e := obj.resolve(v, p.latest.seg, r.request); e == .None {
				it.target = obj.rid(v, t) or_return
			}
		case Hold:
			it.key = obj.clone_str(r.key, allocator) or_return
			it.text = obj.clone_str(r.reason, allocator) or_return
		case Await:
			it.condition = r.condition
			it.deadline = r.deadline
			it.expr = obj.clone_str(r.expr, allocator) or_return
			if len(r.tasks) > 0 {
				it.tasks = make([]prim.Id, len(r.tasks), allocator)
				copy(it.tasks, r.tasks)
			}
		}
	}
	return out, .None
}

@(private)
_clone_atts :: proc(atts: []Attachment, allocator: runtime.Allocator) -> (out: []Attachment, err: Error) {
	if len(atts) == 0 {
		return nil, .None
	}
	out = make([]Attachment, len(atts), allocator)
	for a, k in atts {
		out[k].name = obj.clone_str(a.name, allocator) or_return
		out[k].mime = obj.clone_str(a.mime, allocator) or_return
		out[k].oid = obj.clone_bytes(a.oid, allocator) or_return
		out[k].size = a.size
	}
	return out, .None
}

@(private)
Pending_Ctx :: struct {
	v:       ^obj.View,
	out:     ^[dynamic]Pend,
	removed: ^[dynamic]Vref,
	missing: bool,
}

@(private)
_pending :: proc(v: ^obj.View, out: ^[dynamic]Pend) -> Error {
	missing := false
	for s in 0 ..< len(v.segs) {
		sum, ok, e := _tail(v, s)
		if e == .Missing {
			missing = true
			continue
		}
		if e != .None {
			return e
		}
		if !ok {
			continue
		}
		for pe in summary_pending(&sum) {
			item, ie := obj.resolve(v, s, pe.item)
			if ie == .Missing {
				missing = true
				continue
			}
			if ie != .None {
				return ie
			}
			dup := false
			for o in out {
				if o.item == item {
					dup = true
				}
			}
			if !dup {
				append(out, Pend{item = item, latest = item})
			}
		}
	}
	if missing {
		return .Missing
	}
	if len(out) == 0 {
		return .None
	}
	floor := max(prim.Hlc)
	for &p in out {
		env, red, e := obj.envelope(v, p.item.seg, p.item.off)
		if e == .Missing {
			missing = true
			continue
		}
		if e != .None {
			return e
		}
		if red {
			continue
		}
		p.kind = Kind(env.kind)
		p.stamp = env.links.stamp
		p.latest_stamp = env.links.stamp
		floor = min(floor, env.links.stamp)
	}
	if missing {
		return .Missing
	}
	removed := make([dynamic]Vref, v.scratch)
	ctx := Pending_Ctx{v, out, &removed, false}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		c := (^Pending_Ctx)(data)
		k := Kind(env.kind)
		if k != .Unqueue && k != .Cancel && k != .Edit_Queued {
			return false, .None
		}
		rec := decode_env(env, c.v.scratch) or_return
		item: Ref
		#partial switch r in rec.body {
		case Unqueue:
			item = r.item
		case Cancel:
			item = r.item
		case Edit_Queued:
			item = r.item
		}
		it, re := obj.resolve(c.v, s, item)
		if re == .Missing {
			c.missing = true
			return false, .None
		}
		if re != .None {
			return false, re
		}
		if k == .Edit_Queued {
			for &p in c.out {
				if p.item == it && (rec.stamp > p.latest_stamp || (rec.stamp == p.latest_stamp && obj.vref_less(c.v, p.latest, Vref{s, off}))) {
					p.latest = Vref{s, off}
					p.latest_stamp = rec.stamp
				}
			}
		} else {
			append(c.removed, it)
		}
		return false, .None
	}
	for s in 0 ..< len(v.segs) {
		if e := obj.walk_events(v, s, floor, &ctx, visit); e == .Missing {
			missing = true
		} else if e != .None {
			return e
		}
	}
	if missing || ctx.missing {
		return .Missing
	}
	n := 0
	for p in out {
		gone := false
		for r in removed {
			if r == p.item {
				gone = true
				break
			}
		}
		if !gone {
			out[n] = p
			n += 1
		}
	}
	resize(out, n)
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && _pend_less(v, out[j], out[j - 1]) {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return .None
}

@(private)
_pend_less :: proc(v: ^obj.View, a, b: Pend) -> bool {
	if a.stamp != b.stamp {
		return a.stamp < b.stamp
	}
	return obj.vref_less(v, a.item, b.item)
}

@(private)
_fill_message :: proc(v: ^obj.View, at: Vref, body: []u8, m: ^Msg, msg: ^Message, allocator: runtime.Allocator) -> Error {
	msg.id = obj.rid_body(v, at, body)
	msg.role = m.role
	msg.author = m.author
	msg.depth = m.depth
	msg.runner = m.runner
	msg.hlc = m.hlc
	msg.provider = obj.clone_str(m.provider, allocator) or_return
	msg.model = obj.clone_str(m.model, allocator) or_return
	msg.native = obj.clone_str(m.native, allocator) or_return
	msg.native_msg = obj.clone_str(m.native_msg, allocator) or_return
	if len(m.files) > 0 {
		files := make([]File_Delta, len(m.files), allocator)
		for f, i in m.files {
			files[i] = f
			files[i].mount = obj.clone_str(f.mount, allocator) or_return
			files[i].version = obj.clone_bytes(f.version, allocator) or_return
		}
		msg.files = files
	}
	if p, e := obj.resolve(v, at.seg, m.intent); e == .None {
		msg.intent = obj.rid(v, p) or_return
	}
	if m.claim != 0 {
		msg.claim = obj.rid(v, Vref{at.seg, m.claim}) or_return
	}
	msg.sibling = 1
	msg.siblings = 1
	return .None
}

@(private)
_seal_info :: proc(v: ^obj.View, at: Vref, seal: Vref, seal_known: bool, msg: ^Message, seal_at: ^Vref, allocator := context.temp_allocator) -> (last: i64, err: Error) {
	s := at.seg
	sum, _ := _tail(v, s) or_return
	if seal_known && !obj.vref_none(seal) {
		sv := seal
		if sv.seg == s && sv.off > at.off {
			body, _ := obj.get(v, s, sv.off) or_return
			_apply_seal(body, sv.off, at.off, msg, allocator) or_return
			msg.seal = obj.rid_body(v, sv, body)
			seal_at^ = sv
			return msg.last_block, .None
		}
	}
	if i := summary_find(&sum, at.off); i >= 0 {
		o := sum.open[i]
		msg.open = o.state == .Running
		msg.open_state = o.state
		msg.status = .Open if o.state == .Running else .Interrupted
		return o.last, .None
	}
	if sum.last_seal > at.off {
		c := _cache(v) or_return
		key := Vref{s, sum.last_seal}
		mo, known := c.seals[key]
		if !known || mo == at.off {
			body, _ := obj.get(v, s, sum.last_seal) or_return
			mo = -1
			if !obj.is_redacted(body) {
				rec := decode_record(body, sum.last_seal, v.scratch) or_return
				#partial switch r in rec.body {
				case Seal:
					mo = r.msg
				case Interrupted:
					mo = r.msg
				}
			}
			c.seals[key] = mo
			if mo == at.off {
				_apply_seal(body, sum.last_seal, at.off, msg, allocator) or_return
				seal_at^ = Vref{s, sum.last_seal}
				msg.seal = obj.rid_body(v, seal_at^, body)
				return msg.last_block, .None
			}
		}
	}
	so, l := _scan_seal(v, s, at.off) or_return
	if so == 0 {
		msg.open = true
		return l, .None
	}
	body, _ := obj.get(v, s, so) or_return
	_apply_seal(body, so, at.off, msg, allocator) or_return
	seal_at^ = Vref{s, so}
	msg.seal = obj.rid_body(v, seal_at^, body)
	return msg.last_block, .None
}

@(private)
_apply_seal :: proc(body: []u8, off: i64, m: i64, msg: ^Message, allocator: runtime.Allocator) -> Error {
	rec := decode_record(body, off) or_return
	#partial switch r in rec.body {
	case Seal:
		if r.msg != m {
			return .Corrupt
		}
		msg.status = r.status
		msg.usage = r.usage
		msg.last_block = r.last_block
		msg.seal_native = obj.clone_str(r.native_msg, allocator) or_return
		return .None
	case Interrupted:
		if r.msg != m {
			return .Corrupt
		}
		msg.status = .Interrupted
		msg.last_block = r.last_block
		if r.reason != .None {
			msg.open_state = .Held
			msg.hold_reason = r.reason
			msg.hold_line = obj.clone_str(r.line, allocator) or_return
		} else if r.revive {
			msg.open_state = .Revive
		}
		return .None
	}
	return .Corrupt
}

@(private)
_scan_seal :: proc(v: ^obj.View, s: int, m: i64) -> (seal: i64, last: i64, err: Error) {
	end := obj.end(v, s)
	_, pos := obj.get(v, s, m) or_return
	for pos < end {
		body, next, e := obj.get(v, s, pos, -1, min(end, pos + obj.TAIL_GUESS))
		if e != .None {
			return 0, 0, e
		}
		k := obj.record_kind(body)
		if k == u8(Kind.Block) {
			if bm, ok := block_msg(body, pos); ok {
				if bm == m {
					last = pos
				}
				pos = next
				continue
			}
		}
		if !obj.is_redacted(body) && (k == u8(Kind.Block) || k == u8(Kind.Seal) || k == u8(Kind.Interrupted)) {
			rec := decode_record(body, pos, v.scratch) or_return
			#partial switch r in rec.body {
			case Block:
				if r.msg == m {
					last = pos
				}
			case Seal:
				if r.msg == m {
					return pos, r.last_block, .None
				}
			case Interrupted:
				if r.msg == m {
					return pos, r.last_block, .None
				}
			}
		}
		pos = next
	}
	return 0, last, .None
}

@(private)
_resolve_body :: proc(v: ^obj.View, at: Vref, seal: Vref, known: bool, msg: ^Message, below: ^i64, allocator: runtime.Allocator) -> Error {
	seal_at := Vref{}
	last := _seal_info(v, at, seal, known, msg, &seal_at, allocator) or_return
	if !obj.vref_none(seal_at) {
		below^ = min(below^, seal_at.off)
	}
	if last == 0 {
		return .None
	}
	blocks, first, red, err := _blocks(v, at, last, below^, allocator)
	msg.blocks = blocks
	msg.redacted = red
	if err == .None && first != 0 {
		below^ = min(below^, first)
	}
	return err
}

@(private)
_blocks :: proc(v: ^obj.View, at: Vref, last: i64, after: i64, allocator: runtime.Allocator) -> (out: []Block_View, first: i64, redacted: bool, err: Error) {
	s := at.seg
	chunks := make([dynamic]Chunk, v.scratch)
	off := last
	above := after if after > last else obj.end(v, s)
	for off != 0 {
		body, _, e := obj.get_before(v, s, off, above, at.off)
		if e != .None {
			return nil, 0, false, e
		}
		if obj.is_redacted(body) {
			redacted = true
			clear(&chunks)
			first = 0
			_, pos := obj.get(v, s, at.off) or_return
			end := last + 1
			for pos < end {
				b, next := obj.get(v, s, pos) or_return
				if !obj.is_redacted(b) && obj.record_kind(b) == u8(Kind.Block) {
					rec := decode_record(b, pos, v.scratch) or_return
					blk := rec.body.(Block)
					if blk.msg == at.off {
						_push_chunk(&chunks, pos, &blk, v.scratch) or_return
						if first == 0 {
							first = pos
						}
					}
				}
				pos = next
			}
			slice.reverse(chunks[:])
			break
		}
		rec := decode_record(body, off, v.scratch) or_return
		b, ok := rec.body.(Block)
		if !ok || b.msg != at.off {
			return nil, 0, false, .Corrupt
		}
		_push_chunk(&chunks, off, &b, v.scratch) or_return
		first = off
		above = off
		off = b.prev
	}
	slice.reverse(chunks[:])
	slice.stable_sort_by(chunks[:], proc(a, b: Chunk) -> bool {
		return a.index < b.index
	})
	views := make([dynamic]Block_View, allocator)
	i := 0
	for i < len(chunks) {
		j := i
		size := 0
		for j < len(chunks) && chunks[j].index == chunks[i].index {
			size += len(chunks[j].data)
			j += 1
		}
		head := &chunks[i]
		if .Start not_in head.flags {
			if redacted {
				i = j
				continue
			}
			return nil, 0, false, .Corrupt
		}
		bv := Block_View{
			index  = head.index,
			kind   = head.kind,
			failed = .Failed in head.flags,
			off    = head.off,
		}
		bv.id = obj.clone_str(head.id, allocator) or_return
		bv.name = obj.clone_str(head.name, allocator) or_return
		if .Ref in head.flags {
			bv.is_ref = true
			bv.blob.oid = obj.clone_bytes(head.blob.oid, allocator) or_return
			bv.blob.size = head.blob.size
			bv.blob.preview = obj.clone_bytes(head.blob.preview, allocator) or_return
		} else if size > 0 {
			text, aerr := make([]u8, size, allocator)
			if aerr != nil {
				return nil, 0, false, .No_Memory
			}
			n := 0
			for k in i ..< j {
				n += copy(text[n:], chunks[k].data)
			}
			bv.text = text
		}
		append(&views, bv)
		i = j
	}
	return views[:], first, redacted, .None
}

@(private)
_push_chunk :: proc(chunks: ^[dynamic]Chunk, off: i64, b: ^Block, scratch: runtime.Allocator) -> Error {
	c := Chunk{
		off   = off,
		index = b.index,
		flags = b.flags,
		kind  = b.kind,
	}
	c.id = obj.clone_str(b.id, scratch) or_return
	c.name = obj.clone_str(b.name, scratch) or_return
	c.data = obj.clone_bytes(b.data, scratch) or_return
	c.blob.oid = obj.clone_bytes(b.blob.oid, scratch) or_return
	c.blob.size = b.blob.size
	c.blob.preview = obj.clone_bytes(b.blob.preview, scratch) or_return
	if _, e := append(chunks, c); e != nil {
		return .No_Memory
	}
	return .None
}

@(private)
Kid_Set :: struct {
	at:     Vref,
	parent: Vref,
	depth:  i64,
	hlc:    prim.Hlc,
	kids:   [dynamic]Entry,
}

@(private)
_collect_siblings :: proc(v: ^obj.View, st: ^Structure, set: []Kid_Set) -> Error {
	if len(set) == 0 {
		return .None
	}
	hi := set[0].depth
	lo := set[len(set) - 1].depth
	path := make([]Vref, hi - lo + 2, v.scratch)
	path[0] = set[len(set) - 1].parent
	for &k in set {
		path[k.depth - lo + 1] = k.at
		k.kids = make([dynamic]Entry, v.scratch)
		append(&k.kids, Entry{parent = k.parent, child = k.at, child_hlc = k.hlc})
	}
	add :: proc(k: ^Kid_Set, e: Entry) {
		for o in k.kids {
			if o.child == e.child {
				return
			}
		}
		append(&k.kids, e)
	}
	for &k in set {
		for e in st.entries {
			if e.parent == k.parent && !obj.vref_none(e.child) {
				add(&k, Entry{parent = e.parent, child = e.child, child_hlc = e.child_hlc})
			}
		}
	}
	missing := false
	for e in chains(st) {
		err := _chain_sibling(v, st, e, set, path, lo, hi)
		if err == .Missing {
			missing = true
		} else if err != .None {
			return err
		}
	}
	if missing {
		return .Missing
	}
	for &k in set {
		sort_children(k.kids[:], v)
	}
	return .None
}

@(private)
_chain_sibling :: proc(v: ^obj.View, st: ^Structure, e: Entry, set: []Kid_Set, path: []Vref, lo, hi: i64) -> Error {
	at :: proc(path: []Vref, lo, d: i64) -> Vref {
		return path[d - lo + 1]
	}
	if e.leaf_depth < lo || e.child_depth > hi {
		return .None
	}
	a := max(lo - 1, e.child_depth - 1)
	b := min(hi - 1, e.leaf_depth - 1)
	if a > b {
		return .None
	}
	top := chain_at(v, st, e, b) or_return
	l := b
	if top != at(path, lo, b) {
		first := chain_at(v, st, e, a) or_return
		if first != at(path, lo, a) {
			return .None
		}
		l = a
		r := b - 1
		for l < r {
			mid := (l + r + 1) / 2
			c := chain_at(v, st, e, mid) or_return
			if c == at(path, lo, mid) {
				l = mid
			} else {
				r = mid - 1
			}
		}
	}
	d := l + 1
	c := chain_at(v, st, e, d) or_return
	if obj.vref_none(c) || c == at(path, lo, d) {
		return .None
	}
	k := &set[hi - d]
	chlc := e.child_hlc
	if c != e.child || chlc == 0 {
		cn := _node(v, c) or_return
		chlc = cn.hlc
	}
	for o in k.kids {
		if o.child == c {
			return .None
		}
	}
	append(&k.kids, Entry{parent = k.parent, child = c, child_hlc = chlc})
	return .None
}

@(private)
_page_siblings :: proc(v: ^obj.View, t: ^Tail, msgs: []Message, floor: prim.Hlc, allocator: runtime.Allocator) -> Error {
	st: Structure
	structure_load(v, t, floor, &st) or_return
	set := make([]Kid_Set, len(msgs), v.scratch)
	for m, i in msgs {
		x := obj.vref_pos(v, m.id) or_return
		par := Vref{}
		if !obj.rid_none(m.parent) {
			par = obj.vref_pos(v, m.parent) or_return
		}
		set[i] = Kid_Set{at = x, parent = par, depth = m.depth, hlc = m.hlc}
	}
	_collect_siblings(v, &st, set) or_return
	for &m, i in msgs {
		x := set[i].at
		par := set[i].parent
		kids := set[i].kids[:]
		m.siblings = len(kids)
		for k, ki in kids {
			if k.child == x {
				m.sibling = ki + 1
			}
		}
		if obj.rid_none(m.claim) {
			continue
		}
		c := obj.vref_pos(v, m.claim) or_return
		m.landed, m.landed_as = is_landed(&st, c)
		m.superseded = is_superseded(&st, c)
		env, red := obj.envelope(v, c.seg, c.off) or_return
		if !red {
			rec := decode_env(&env, v.scratch) or_return
			if cl, ok := rec.body.(Claim); ok && len(cl.lines) > 0 {
				lines := make([]Line, len(cl.lines), allocator)
				for l, li in cl.lines {
					lines[li] = Line{obj.clone_str(l.mount, allocator) or_return, l.line}
				}
				m.lines = lines
			}
		}
		if m.superseded || m.role != .Assistant || len(kids) < 2 || obj.vref_none(par) {
			continue
		}
		pn := _node(v, par) or_return
		win := assignee_of(&st, par, pn.runner)
		if obj.seg_id(v, x) == win {
			continue
		}
		mine := _claim_window(v, c) or_return
		for k in kids {
			if k.child == x || obj.seg_id(v, k.child) != win {
				continue
			}
			kn := _node(v, k.child) or_return
			if kn.role != .Assistant || obj.vref_none(kn.claim) {
				continue
			}
			theirs := _claim_window(v, kn.claim) or_return
			if mine[0] < theirs[1] && theirs[0] < mine[1] {
				m.superseded = true
				break
			}
		}
	}
	return .None
}

@(private)
_claim_window :: proc(v: ^obj.View, c: Vref) -> (w: [2]i64, err: Error) {
	env, red := obj.envelope(v, c.seg, c.off) or_return
	if red {
		return {0, max(i64)}, .None
	}
	rec := decode_env(&env, v.scratch) or_return
	cl, ok := rec.body.(Claim)
	if !ok {
		return w, .Corrupt
	}
	start := prim.hlc_ms(rec.stamp)
	return {start, start + i64(min(cl.lease, u64(max(i64) / 2)))}, .None
}

@(private)
_prefetch_structure :: proc(v: ^obj.View, t: ^Tail, at: Vref) {
	sum, ok, e := _tail(v, at.seg)
	if e != .None || !ok || sum.digest == 0 || at.off >= sum.digest {
		return
	}
	obj.want(v, at.seg, max(at.off - obj.TAIL_GUESS / 2, 0), min(at.off + obj.TAIL_GUESS / 2, obj.end(v, at.seg)))
	st: Structure
	structure_load(v, t, 0, &st)
}

@(private)
_spine_prefetch :: proc(v: ^obj.View, t: ^Tail, lo, hi: i64, floor: prim.Hlc) {
	if hi < 1 {
		return
	}
	st: Structure
	if structure_load(v, t, floor, &st) != .None {
		return
	}
	a := max(lo, 1)
	for e in chains(&st) {
		if e.branch <= 0 || e.leaf_depth < lo || e.child_depth > hi {
			continue
		}
		b := st.branches[e.branch - 1]
		if b.bseg < 0 {
			continue
		}
		k0 := e.child_depth / SPINE_SPAN
		for k := (max(a, e.child_depth + 1) - 1) / SPINE_SPAN; k <= (min(hi, b.covered) - 1) / SPINE_SPAN; k += 1 {
			if k - k0 >= 0 && k - k0 < i64(len(b.blocks)) {
				rec := b.blocks[k - k0]
				bs := b.bsegs[k - k0]
				obj.want(v, bs, rec, min(rec + obj.MSG_GUESS, obj.end(v, bs)))
			}
		}
	}
	for s in 0 ..< len(st.spines) {
		sp, e := _spine_get(v, &st, s)
		if e != .None || sp == nil || !sp.ready {
			continue
		}
		for k := (a - 1) / SPINE_SPAN; k <= (hi - 1) / SPINE_SPAN && k < i64(len(sp.blocks)); k += 1 {
			rec := sp.blocks[k]
			if rec == 0 {
				continue
			}
			from := rec - obj.TAIL_GUESS
			if k > 0 && sp.blocks[k - 1] < rec {
				from = sp.blocks[k - 1] - obj.TAIL_GUESS / 8
			}
			obj.want(v, s, max(from, 0), min(rec + obj.MSG_GUESS, obj.end(v, s)))
		}
		if hi > sp.c {
			obj.want(v, s, sp.start, min(sp.start + 4 * obj.TAIL_GUESS, obj.end(v, s)))
		}
		for e2 in chains(&st) {
			if e2.leaf_depth < lo || e2.child_depth > hi || e2.leaf == sp.target || e2.leaf_depth > sp.c {
				continue
			}
			rec := sp.blocks[(e2.leaf_depth - 1) / SPINE_SPAN]
			if rec != 0 {
				obj.want(v, s, rec, min(rec + obj.MSG_GUESS, obj.end(v, s)))
			}
		}
	}
}

Activity :: struct {
	seg: prim.Id,
	hlc: prim.Hlc,
}

segment_activity :: proc(v: ^obj.View, s: int) -> (hlc: prim.Hlc, err: Error) {
	sum, ok := _tail(v, s) or_return
	if !ok {
		return 0, .None
	}
	hlc = max(sum.tip_hlc, sum.leaf_hlc)
	sg := &v.segs[s]
	if e := sg.links.event; e != 0 {
		if e == sg.last {
			hlc = max(hlc, sg.links.stamp)
		} else {
			env, red := obj.envelope(v, s, e) or_return
			if !red {
				hlc = max(hlc, env.links.stamp)
			}
		}
	}
	return hlc, .None
}

activity :: proc(v: ^obj.View, allocator := context.allocator) -> (out: []Activity, err: Error) {
	list := make([dynamic]Activity, 0, len(v.segs), allocator)
	missing := false
	for s in 0 ..< len(v.segs) {
		h, e := segment_activity(v, s)
		if e == .Missing {
			missing = true
			continue
		}
		if e != .None {
			return nil, e
		}
		append(&list, Activity{v.segs[s].id, h})
	}
	if missing {
		return list[:], .Missing
	}
	return list[:], .None
}

Undo_State :: struct {
	id:     prim.Id,
	msg:    Rid,
	redo:   prim.Id,
	phase:  Undo_Phase,
	staged: Rid,
	fenced: bool,
	set:    []Undo_Line,
	stamp:  prim.Hlc,
	cause:  Move_Cause,
	from:   Rid,
	to:     Rid,
}

Undone_State :: struct {
	at:      Rid,
	undo:    prim.Id,
	msg:     Rid,
	leaves:  []Undone_Leaf,
	reverts: []Undone_Revert,
	kept:    []Line_Bind,
	hidden:  []prim.Id,
	stamp:   prim.Hlc,
}

Notice_State :: struct {
	at:     Rid,
	notice: Notice,
	stamp:  prim.Hlc,
}

undo_before :: proc(a, b: Undo_State) -> bool {
	if a.stamp != b.stamp {
		return a.stamp < b.stamp
	}
	x, y := a.staged.seg, b.staged.seg
	return mem.compare(x[:], y[:]) < 0
}

undos :: proc(v: ^obj.View, allocator := context.allocator, floor: prim.Hlc = 0) -> (out: []Undo_State, err: Error) {
	Acc :: struct {
		list:      [dynamic]Undo_State,
		v:         ^obj.View,
		allocator: runtime.Allocator,
	}
	acc := Acc{make([dynamic]Undo_State, allocator), v, allocator}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		a := (^Acc)(data)
		if env.kind != u8(Kind.Undo) {
			return false, .None
		}
		rec := decode_env(env, a.v.scratch) or_return
		u := rec.body.(Undo)
		at := obj.rid(a.v, Vref{s, off}) or_return
		x := -1
		for st, i in a.list {
			if st.id == u.id {
				x = i
				break
			}
		}
		if x < 0 {
			append(&a.list, Undo_State{id = u.id, stamp = rec.stamp})
			x = len(a.list) - 1
		}
		st := &a.list[x]
		st.stamp = min(st.stamp, rec.stamp)
		if u.phase == .Staged && obj.rid_none(st.staged) {
			m := obj.resolve(a.v, s, u.msg) or_return
			st.msg = obj.rid(a.v, m) or_return
			st.redo = u.redo
			st.staged = at
			st.cause = u.cause
			if !obj.ref_none(u.from) {
				f := obj.resolve(a.v, s, u.from) or_return
				st.from = obj.rid(a.v, f) or_return
			}
			if !obj.ref_none(u.to) {
				t := obj.resolve(a.v, s, u.to) or_return
				st.to = obj.rid(a.v, t) or_return
			}
		}
		if u.phase == .Fenced && !st.fenced {
			st.fenced = true
			set := make([]Undo_Line, len(u.set), a.allocator)
			for l, i in u.set {
				set[i].tree = l.tree
				set[i].line = obj.clone_str(l.line, a.allocator) or_return
				set[i].base = obj.clone_bytes(l.base, a.allocator) or_return
				set[i].actors = make([]prim.Id, len(l.actors), a.allocator)
				copy(set[i].actors, l.actors)
				set[i].park = obj.clone_bytes(l.park, a.allocator) or_return
			}
			st.set = set
		}
		st.phase = max(st.phase, u.phase)
		return false, .None
	}
	for s in 0 ..< len(v.segs) {
		obj.walk_events(v, s, floor, &acc, visit) or_return
	}
	n := 0
	for st in acc.list {
		if !obj.rid_none(st.staged) {
			acc.list[n] = st
			n += 1
		}
	}
	resize(&acc.list, n)
	slice.sort_by(acc.list[:], proc(a, b: Undo_State) -> bool {
		return undo_before(a, b)
	})
	return acc.list[:], .None
}

undones :: proc(v: ^obj.View, allocator := context.allocator) -> (out: []Undone_State, err: Error) {
	Acc :: struct {
		list:      [dynamic]Undone_State,
		v:         ^obj.View,
		allocator: runtime.Allocator,
	}
	acc := Acc{make([dynamic]Undone_State, allocator), v, allocator}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		a := (^Acc)(data)
		if env.kind != u8(Kind.Undone) {
			return false, .None
		}
		rec := decode_env(env, a.v.scratch) or_return
		u := rec.body.(Undone)
		for st in a.list {
			if st.undo == u.undo {
				return false, .None
			}
		}
		m := obj.resolve(a.v, s, u.msg) or_return
		st := Undone_State {
			at    = obj.rid(a.v, Vref{s, off}) or_return,
			undo  = u.undo,
			msg   = obj.rid(a.v, m) or_return,
			stamp = rec.stamp,
		}
		st.leaves = make([]Undone_Leaf, len(u.leaves), a.allocator)
		copy(st.leaves, u.leaves)
		st.reverts = make([]Undone_Revert, len(u.reverts), a.allocator)
		for r, i in u.reverts {
			st.reverts[i] = r
			st.reverts[i].line = obj.clone_str(r.line, a.allocator) or_return
		}
		st.kept = make([]Line_Bind, len(u.kept), a.allocator)
		for k, i in u.kept {
			st.kept[i] = k
			st.kept[i].mount = obj.clone_str(k.mount, a.allocator) or_return
			st.kept[i].line = obj.clone_str(k.line, a.allocator) or_return
		}
		st.hidden = make([]prim.Id, len(u.hidden), a.allocator)
		copy(st.hidden, u.hidden)
		append(&a.list, st)
		return false, .None
	}
	for s in 0 ..< len(v.segs) {
		obj.walk_events(v, s, 0, &acc, visit) or_return
	}
	slice.sort_by(acc.list[:], proc(a, b: Undone_State) -> bool {
		return a.stamp < b.stamp
	})
	return acc.list[:], .None
}

notices :: proc(v: ^obj.View, floor: prim.Hlc = 0, allocator := context.allocator) -> (out: []Notice_State, err: Error) {
	Acc :: struct {
		list:      [dynamic]Notice_State,
		v:         ^obj.View,
		allocator: runtime.Allocator,
	}
	acc := Acc{make([dynamic]Notice_State, allocator), v, allocator}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		a := (^Acc)(data)
		if env.kind != u8(Kind.Notice) {
			return false, .None
		}
		rec := decode_env(env, a.v.scratch) or_return
		n := rec.body.(Notice)
		st := Notice_State {
			at     = obj.rid(a.v, Vref{s, off}) or_return,
			notice = n,
			stamp  = rec.stamp,
		}
		st.notice.line = obj.clone_str(n.line, a.allocator) or_return
		st.notice.paths = make([]string, len(n.paths), a.allocator)
		for p, i in n.paths {
			st.notice.paths[i] = obj.clone_str(p, a.allocator) or_return
		}
		append(&a.list, st)
		return false, .None
	}
	for s in 0 ..< len(v.segs) {
		obj.walk_events(v, s, floor, &acc, visit) or_return
	}
	slice.sort_by(acc.list[:], proc(a, b: Notice_State) -> bool {
		return a.stamp < b.stamp
	})
	return acc.list[:], .None
}

scope_actors :: proc(v: ^obj.View, allocator := context.allocator) -> (out: []prim.Id, err: Error) {
	list := make([dynamic]prim.Id, allocator)
	for s in 0 ..< len(v.segs) {
		end := obj.end(v, s)
		pos := i64(0)
		for pos < end {
			body, next, e := obj.get(v, s, pos, -1, min(end, pos + obj.TAIL_GUESS))
			if e != .None {
				return nil, e
			}
			if !obj.is_redacted(body) && !obj.is_sig(body) && obj.record_kind(body) == u8(Kind.Scope) {
				rec := decode_record(body, pos, v.scratch) or_return
				a := rec.body.(Scope).actor
				if a != {} && !slice.contains(list[:], a) {
					append(&list, a)
				}
			}
			pos = next
		}
	}
	return list[:], .None
}

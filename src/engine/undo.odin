package engine

import "base:runtime"
import "core:slice"
import "core:strings"
import "../convo"
import "../fs"
import "../obj"
import "../prim"

Undo_Hooks :: struct {
	data:    rawptr,
	hold:    proc(data: rawptr, e: ^Engine, convs: []Object, undo: prim.Id) -> Error,
	mounts:  proc(data: rawptr, e: ^Engine, conv: Object, allocator: runtime.Allocator) -> []prim.Id,
	rewind:  proc(data: rawptr, e: ^Engine, conv: Object, head: Rid) -> Error,
	checkouts: proc(data: rawptr, e: ^Engine, conv: Object, allocator: runtime.Allocator) -> []convo.Line_Bind,
	release: proc(data: rawptr, e: ^Engine, convs: []Object, undo: prim.Id) -> Error,
	pending: proc(data: rawptr, e: ^Engine, conv: Object, undo: prim.Id),
}

MOVE_SETTLE_WINDOW_MS :: 600_000

@(private)
Move_Wait :: struct {
	o:     Object,
	move:  prim.Id,
	ready: Ready,
}

convo_move_on_disk :: proc(e: ^Engine, o: Object, move: prim.Id, ready: Ready = {}) -> Error {
	context = context_for(e)
	done := _cu_on_disk(e, o, move) or_return
	if done {
		return .None
	}
	if ready.call == nil {
		return .Pending
	}
	append(&e.move_waits, Move_Wait{o = o, move = move, ready = ready})
	return .Pending
}

@(private)
_move_waits_run :: proc(e: ^Engine) {
	if len(e.move_waits) == 0 {
		return
	}
	fire := make([dynamic]Move_Wait, context.temp_allocator)
	for i := 0; i < len(e.move_waits); {
		mw := e.move_waits[i]
		done, err := _cu_on_disk(e, mw.o, mw.move)
		if err != .None || done {
			ordered_remove(&e.move_waits, i)
			append(&fire, Move_Wait{o = mw.o, move = mw.move, ready = Ready{data = mw.ready.data, call = mw.ready.call, fresh = err == .None}})
			continue
		}
		i += 1
	}
	for mw in fire {
		if mw.ready.call != nil {
			context = _outer(e)
			mw.ready.call(mw.ready.data, e, .None if mw.ready.fresh else .Io)
		}
	}
}

@(private)
_cu_on_disk :: proc(e: ^Engine, o: Object, move: prim.Id) -> (done: bool, err: Error) {
	st, found := _cu_undo_state(e, o, move) or_return
	if !found {
		return false, .Not_Found
	}
	if st.phase != .Released {
		return false, .None
	}
	u, uerr := _cu_undone_of(e, o, move)
	if uerr == .Not_Found {
		return true, .None
	} else if uerr != .None {
		return false, uerr
	}
	if !e.plug.reg_on {
		return true, .None
	}
	for r in u.reverts {
		for mt in e.plug.mounts {
			ml := mt.mount.line if len(mt.mount.line) > 0 else "main"
			if mt.object.id != r.tree || ml != r.line {
				continue
			}
			m := &mt.mount
			if m.history == nil {
				continue
			}
			has, herr := fs.history_version_has(m.history, fs.mount_synced(m), r.revert)
			if herr == .Not_Found {
				return false, .None
			} else if herr != .None {
				return false, _ferr(herr)
			}
			if !has {
				return false, .None
			}
		}
	}
	return true, .None
}

@(private)
Undo_Conv :: struct {
	o:      Object,
	hidden: bool,
	gone:   bool,
}

@(private)
Cu_Paths :: struct {
	old_only: []Rid,
	new_only: []Rid,
	fork:     Rid,
}

undo_hooks_set :: proc(e: ^Engine, hooks: Undo_Hooks) {
	e.undo_hooks = hooks
}

convo_line_key :: proc(id: prim.Id, allocator := context.temp_allocator) -> string {
	if prim.id_is_zero(id) {
		return "main"
	}
	h := prim.id_hex(id)
	return strings.concatenate({"l/", string(h[:])}, allocator)
}

convo_undo :: proc(e: ^Engine, o: Object, msg: Rid) -> (undo: prim.Id, err: Error) {
	context = context_for(e)
	from := _cu_position(e, o) or_return
	undo = new_id(e)
	_cu_undo_write(e, o, undo, msg, .Staged, nil, {}, {cause = .Undo, from = from}) or_return
	return undo, _cu_drive_new(e, o, undo)
}

convo_redo :: proc(e: ^Engine, o: Object, of: prim.Id) -> (redo: prim.Id, err: Error) {
	context = context_for(e)
	u := _cu_undone_of(e, o, of) or_return
	us, found := _cu_undo_state(e, o, of) or_return
	redo = new_id(e)
	if found && !obj.rid_none(us.from) {
		from := _cu_position(e, o) or_return
		_cu_undo_write(e, o, redo, u.msg, .Staged, nil, of, {cause = .Redo, from = from, to = us.from}) or_return
	} else {
		_cu_undo_write(e, o, redo, u.msg, .Staged, nil, of, {cause = .Redo}) or_return
	}
	return redo, _cu_drive_new(e, o, redo)
}

@(private)
_cu_switch :: proc(e: ^Engine, o: Object, sibling: Rid) -> (move: prim.Id, leaf: Rid, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None {
		return {}, {}, _oerr(terr)
	}
	target, serr := convo.switch_target(&h.view, &t, sibling)
	if serr != .None {
		return {}, {}, _oerr(serr)
	}
	move, err = convo_move(e, o, .Switch, target)
	return move, target, err
}

convo_move :: proc(e: ^Engine, o: Object, cause: convo.Move_Cause, to: Rid, of: prim.Id = {}) -> (move: prim.Id, err: Error) {
	context = context_for(e)
	if obj.rid_none(to) {
		return {}, .Invalid
	}
	from := _cu_position(e, o) or_return
	if from == to && cause != .Rebase {
		return {}, .None
	}
	p := _cu_paths(e, o, from, to) or_return
	msg := to
	if len(p.old_only) > 0 {
		msg = p.old_only[len(p.old_only) - 1]
	} else if len(p.new_only) > 0 {
		msg = p.new_only[len(p.new_only) - 1]
	}
	move = new_id(e)
	_cu_undo_write(e, o, move, msg, .Staged, nil, of, {cause = cause, from = from, to = to}) or_return
	return move, _cu_drive_new(e, o, move)
}

@(private)
_cu_edit :: proc(e: ^Engine, o: Object, parent: Rid, root: bool) -> (move: prim.Id, err: Error) {
	from := _cu_position(e, o) or_return
	if obj.rid_none(from) {
		return {}, .None
	}
	if !root && !(_cu_descends(e, o, from, parent) or_return) {
		return convo_move(e, o, .Switch, parent)
	}
	child := from
	for {
		p := _cu_parent(e, o, child) or_return
		if obj.rid_none(p) || (!root && p == parent) {
			break
		}
		child = p
	}
	move = new_id(e)
	_cu_undo_write(e, o, move, child, .Staged, nil, {}, {cause = .Edit, from = from, to = {} if root else parent}) or_return
	return move, _cu_drive_new(e, o, move)
}

@(private)
_moves_settle_step :: proc(e: ^Engine) {
	if len(e.changed) == 0 {
		return
	}
	list := make([dynamic]Object, context.temp_allocator)
	for id, c in e.changed {
		if .Data not_in c.kinds {
			continue
		}
		if h, ok := e.handles[id]; ok && h.kind == .Conversation {
			append(&list, Object{c.space, id})
		}
	}
	for o in list {
		convo_moves_settle(e, o)
	}
}

convo_moves_settle :: proc(e: ^Engine, o: Object) -> Error {
	context = context_for(e)
	now := hlc_now(e)
	floor := prim.hlc_make(max(prim.hlc_ms(now) - MOVE_SETTLE_WINDOW_MS, 0), 0)
	list := convo_undos(e, o, context.temp_allocator, floor) or_return
	if len(list) == 0 {
		return .None
	}
	for u in list {
		if u.staged.seg == e.self && u.phase != .Released {
			return .None
		}
	}
	w := list[len(list) - 1]
	if w.phase != .Released {
		return .None
	}
	if w.staged.seg != e.self {
		target := w.to
		if obj.rid_none(target) && w.cause == .Undo {
			target = _cu_parent(e, o, w.msg) or_return
		}
		if obj.rid_none(target) {
			return .None
		}
		pos := _cu_position(e, o) or_return
		if !(_cu_descends(e, o, pos, target) or_return) {
			return _cu_set_leaf(e, o, target)
		}
		return .None
	}
	if len(list) < 2 || !_cu_switch_like(w) {
		return .None
	}
	stale := false
	pos := _cu_position(e, o) or_return
	if !(_cu_descends(e, o, pos, w.to) or_return) {
		stale = true
	}
	for x in list[:len(list) - 1] {
		if stale {
			break
		}
		if x.phase < .Reverted {
			return .None
		}
		xu, xerr := _cu_undone_of(e, o, x.id)
		if xerr == .Not_Found {
			continue
		} else if xerr != .None {
			return xerr
		}
		for r in xu.reverts {
			park: []u8
			for l in w.set {
				if l.tree == r.tree && l.line == r.line {
					park = l.park
				}
			}
			if park == nil {
				continue
			}
			v, derr := fs.decode_version(park, context.temp_allocator)
			if derr != .None {
				return .Corrupt
			}
			th := _handle_get(e, Object{o.space, r.tree}, .File_Tree) or_return
			_hist_ready(e, th) or_return
			has, herr := fs.history_version_has(th.hist, v, r.revert)
			if herr == .Not_Found {
				return .None
			} else if herr != .None {
				return _ferr(herr)
			}
			if !has {
				stale = true
				break
			}
		}
	}
	if !stale {
		return .None
	}
	_, err := convo_move(e, o, .Rebase, w.to, w.id)
	return err
}

convo_undos :: proc(e: ^Engine, o: Object, allocator := context.allocator, floor: prim.Hlc = 0) -> (out: []convo.Undo_State, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	u, uerr := convo.undos(&h.view, allocator, floor)
	return u, _oerr(uerr)
}

@(private)
_cu_drive_new :: proc(e: ^Engine, o: Object, move: prim.Id) -> Error {
	err := convo_undo_drive(e, o, move)
	if err == .Pending && e.undo_hooks.pending != nil {
		e.undo_hooks.pending(e.undo_hooks.data, e, o, move)
	}
	return err
}

convo_undo_drive :: proc(e: ^Engine, o: Object, undo: prim.Id) -> Error {
	context = context_for(e)
	for _ in 0 ..< int(max(convo.Undo_Phase)) + 1 {
		st, found := _cu_undo_state(e, o, undo) or_return
		if !found {
			return .Not_Found
		}
		if st.phase == .Released {
			return .None
		}
		_cu_undo_step(e, o, &st) or_return
	}
	return .None
}

@(private)
_cu_undo_state :: proc(e: ^Engine, o: Object, undo: prim.Id) -> (st: convo.Undo_State, found: bool, err: Error) {
	list := convo_undos(e, o, context.temp_allocator) or_return
	for u in list {
		if u.id == undo {
			return u, true, .None
		}
	}
	return {}, false, .None
}

@(private)
_cu_undone_of :: proc(e: ^Engine, o: Object, undo: prim.Id) -> (u: convo.Undone_State, err: Error) {
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	list, lerr := convo.undones(&h.view, context.temp_allocator)
	if lerr != .None {
		return u, _oerr(lerr)
	}
	for x in list {
		if x.undo == undo {
			return x, .None
		}
	}
	return u, .Not_Found
}

@(private)
_cu_undo_write :: proc(e: ^Engine, o: Object, undo: prim.Id, msg: Rid, phase: convo.Undo_Phase, set: []convo.Undo_Line, redo: prim.Id, move: convo.Move_Spec = {}) -> Error {
	h := _convo_writable(e, o) or_return
	if _, x := convo.writer_undo(&h.cw, undo, msg, phase, set, redo, move); x != .None {
		return _oerr(x)
	}
	return _cu_durable(e, h)
}

@(private)
_cu_durable :: proc(e: ^Engine, h: ^Handle) -> Error {
	_oerr(convo.writer_commit(&h.cw)) or_return
	_handle_mark(h)
	return .None
}

@(private)
_cu_switch_like :: proc(st: convo.Undo_State) -> bool {
	return st.cause == .Switch || st.cause == .Rebase || (st.cause == .Redo && !obj.rid_none(st.to))
}

@(private)
_cu_position :: proc(e: ^Engine, o: Object) -> (at: Rid, err: Error) {
	st := convo_status(e, o) or_return
	return st.position if st.browsing else st.head, .None
}

@(private)
_cu_parent :: proc(e: ^Engine, o: Object, at: Rid) -> (parent: Rid, err: Error) {
	m := convo_message(e, o, {msg = at}, context.temp_allocator) or_return
	return m.parent, .None
}

@(private)
_cu_paths :: proc(e: ^Engine, o: Object, from, to: Rid) -> (p: Cu_Paths, err: Error) {
	anc := make(map[Rid]bool, context.temp_allocator)
	for at := to; !obj.rid_none(at); {
		anc[at] = true
		at = _cu_parent(e, o, at) or_return
	}
	old := make([dynamic]Rid, context.temp_allocator)
	at := from
	for !obj.rid_none(at) && !anc[at] {
		append(&old, at)
		at = _cu_parent(e, o, at) or_return
	}
	p.fork = at
	nw := make([dynamic]Rid, context.temp_allocator)
	for x := to; x != p.fork && !obj.rid_none(x); {
		append(&nw, x)
		x = _cu_parent(e, o, x) or_return
	}
	p.old_only = old[:]
	p.new_only = nw[:]
	return p, .None
}

@(private)
_cu_descends :: proc(e: ^Engine, o: Object, at, of: Rid) -> (yes: bool, err: Error) {
	for x := at; !obj.rid_none(x); {
		if x == of {
			return true, .None
		}
		x = _cu_parent(e, o, x) or_return
	}
	return false, .None
}

@(private)
_cu_undo_step :: proc(e: ^Engine, o: Object, st: ^convo.Undo_State) -> Error {
	convs := _cu_move_tree(e, o, st) or_return
	visible := make([dynamic]Object, context.temp_allocator)
	for c in convs {
		if !c.hidden {
			append(&visible, c.o)
		}
	}
	hk := e.undo_hooks
	switch st.phase {
	case .Staged:
		if hk.hold != nil {
			hk.hold(hk.data, e, visible[:], st.id) or_return
		}
		return _cu_undo_write(e, o, st.id, st.msg, .Held, nil, st.redo)
	case .Held:
		_cu_undo_fence(e, convs)
		set: []convo.Undo_Line
		if _cu_switch_like(st^) {
			set = _cu_switch_set(e, o, st, convs) or_return
		} else if st.redo != {} {
			set = _cu_redo_set(e, o, st.redo) or_return
		} else {
			set = _cu_undo_set(e, o, st.msg, convs) or_return
		}
		_cu_park(e, o.space, set) or_return
		return _cu_undo_write(e, o, st.id, st.msg, .Fenced, set, st.redo)
	case .Fenced:
		for l in st.set {
			_cu_undo_line(e, o.space, st.id, o.id, l) or_return
		}
		_cu_undo_undone(e, o, st, convs) or_return
		return _cu_undo_write(e, o, st.id, st.msg, .Reverted, nil, st.redo)
	case .Reverted:
		if st.cause == .Undo && st.redo == {} {
			_cu_undo_unmount(e, o, st.msg) or_return
		}
		return _cu_undo_write(e, o, st.id, st.msg, .Moved, nil, st.redo)
	case .Moved:
		_cu_undo_leaves(e, o, st, convs) or_return
		return _cu_undo_write(e, o, st.id, st.msg, .Leaves, nil, st.redo)
	case .Leaves:
		if hk.rewind != nil {
			for c in visible {
				st_c := convo_status(e, c) or_return
				hk.rewind(hk.data, e, c, st_c.position) or_return
			}
		}
		return _cu_undo_write(e, o, st.id, st.msg, .Rewound, nil, st.redo)
	case .Rewound:
		if hk.release != nil {
			hk.release(hk.data, e, visible[:], st.id) or_return
		}
		return _cu_undo_write(e, o, st.id, st.msg, .Released, nil, st.redo)
	case .Released:
	}
	return .None
}

@(private)
_cu_move_tree :: proc(e: ^Engine, o: Object, st: ^convo.Undo_State) -> (out: []Undo_Conv, err: Error) {
	if !_cu_switch_like(st^) {
		return _cu_undo_tree(e, o, st.msg)
	}
	p := _cu_paths(e, o, st.from, st.to) or_return
	old := make(map[Rid]bool, context.temp_allocator)
	for m in p.old_only {
		old[m] = true
	}
	return _cu_undo_tree(e, o, st.msg, &old)
}

@(private)
_cu_undo_tree :: proc(e: ^Engine, o: Object, msg: Rid, old: ^map[Rid]bool = nil) -> (out: []Undo_Conv, err: Error) {
	t := convo_message(e, o, {msg = msg}, context.temp_allocator) or_return
	list := make([dynamic]Undo_Conv, context.temp_allocator)
	append(&list, Undo_Conv{o = o})
	rows := make([dynamic]Catalog_Row, context.temp_allocator)
	for archived in ([2]bool{false, true}) {
		cur: Map_Cursor
		for {
			page, more := catalog_list(e, o.space, archived, &cur, 256, context.temp_allocator) or_return
			append(&rows, ..page)
			if !more {
				break
			}
		}
	}
	for grew := true; grew; {
		grew = false
		for r in rows {
			if r.kind != .Conversation {
				continue
			}
			parent := -1
			seen := false
			for c, i in list {
				if c.o.id == r.object {
					seen = true
				}
				if c.o.id == r.parent.object {
					parent = i
				}
			}
			if seen || parent < 0 {
				continue
			}
			if old != nil {
				if parent == 0 && !old[r.parent.rid] {
					continue
				}
				append(&list, Undo_Conv{o = Object{o.space, r.object}, gone = true})
				grew = true
				continue
			}
			hidden := list[parent].hidden
			if !hidden {
				pm, perr := convo_message(e, Object{o.space, r.parent.object}, {msg = r.parent.rid}, context.temp_allocator)
				hidden = perr != .None || pm.hlc >= t.hlc
			}
			append(&list, Undo_Conv{o = Object{o.space, r.object}, hidden = hidden})
			grew = true
		}
	}
	return list[:], .None
}

@(private)
_cu_undo_fence :: proc(e: ^Engine, convs: []Undo_Conv) {
	for c in convs {
		ms, merr := convo_mounts(e, c.o, context.temp_allocator)
		if merr != .None {
			continue
		}
		for m in ms {
			th, herr := _handle_get(e, Object{c.o.space, m.tree}, .File_Tree)
			if herr != .None || th.hist == nil {
				continue
			}
			for fm in e.plug.reg.mounts {
				if fm != nil && fm.history == th.hist {
					fs.mount_sync(fm)
				}
			}
		}
	}
}

@(private)
_cu_first_reply_after :: proc(e: ^Engine, o: Object, hlc: prim.Hlc) -> (reply: Rid, err: Error) {
	st := convo_status(e, o) or_return
	at := st.head
	for !obj.rid_none(at) {
		m := convo_message(e, o, {msg = at}, context.temp_allocator) or_return
		if m.hlc < hlc {
			break
		}
		if m.role == .Assistant {
			reply = at
		}
		at = m.parent
	}
	return reply, .None
}

@(private)
_cu_head_before :: proc(e: ^Engine, o: Object, hlc: prim.Hlc) -> (head: Rid, err: Error) {
	st := convo_status(e, o) or_return
	at := st.head
	for !obj.rid_none(at) {
		m := convo_message(e, o, {msg = at}, context.temp_allocator) or_return
		if m.hlc < hlc {
			return at, .None
		}
		at = m.parent
	}
	return {}, .None
}

@(private)
_cu_put_line :: proc(lines: ^[dynamic]convo.Undo_Line, tree: prim.Id, line: string, base: []u8) {
	for l in lines {
		if l.tree == tree && l.line == line {
			return
		}
	}
	append(lines, convo.Undo_Line{tree = tree, line = line, base = base})
}

@(private)
_cu_undo_set :: proc(e: ^Engine, o: Object, msg: Rid, convs: []Undo_Conv) -> (set: []convo.Undo_Line, err: Error) {
	t := convo_message(e, o, {msg = msg}, context.temp_allocator) or_return
	lines := make([dynamic]convo.Undo_Line, context.temp_allocator)
	for c in convs {
		if c.hidden {
			continue
		}
		at := _cu_first_reply_after(e, c.o, t.hlc) or_return
		if obj.rid_none(at) {
			continue
		}
		named := make(map[string]bool, context.temp_allocator)
		{
			fd := convo_files_at(e, c.o, at, context.temp_allocator) or_return
			for d in fd {
				rd := prim.reader(d.version)
				vb := prim.read_bytes(&rd)
				if !prim.reader_ok(&rd) {
					return nil, .Corrupt
				}
				_cu_put_line(&lines, d.tree, convo_line_key(d.line), vb)
				named[d.mount] = true
			}
		}
		ms := convo_mounts(e, c.o, context.temp_allocator) or_return
		for m in ms {
			if !m.removed && !named[m.name] {
				_cu_put_line(&lines, m.tree, convo_line_key(m.line), nil)
			}
		}
	}
	_cu_fill_actors(e, o, convs, lines[:]) or_return
	return lines[:], .None
}

@(private)
_cu_switch_set :: proc(e: ^Engine, o: Object, st: ^convo.Undo_State, convs: []Undo_Conv) -> (set: []convo.Undo_Line, err: Error) {
	lines := make([dynamic]convo.Undo_Line, context.temp_allocator)
	list := convo_undos(e, o, context.temp_allocator) or_return
	if st.cause == .Rebase {
		for u in list {
			if u.id == st.redo {
				for l in u.set {
					_cu_put_line(&lines, l.tree, l.line, l.base)
				}
			}
		}
	} else {
		p := _cu_paths(e, o, st.from, st.to) or_return
		cands := p.new_only
		if len(cands) == 0 {
			one := make([]Rid, 1, context.temp_allocator)
			one[0] = st.to
			cands = one
		}
		best := -1
		for u, i in list {
			if u.id == st.id || !u.fenced || obj.rid_none(u.from) {
				continue
			}
			for c in cands {
				if u.from == c {
					best = i
				}
			}
		}
		if best >= 0 {
			for l in list[best].set {
				if len(l.park) > 0 {
					_cu_put_line(&lines, l.tree, l.line, l.park)
				}
			}
		} else {
			at := _cu_reply_on(e, o, p.new_only) or_return
			if obj.rid_none(at) {
				at = _cu_reply_on(e, o, p.old_only) or_return
			}
			if !obj.rid_none(at) {
				fd := convo_files_at(e, o, at, context.temp_allocator) or_return
				for d in fd {
					rd := prim.reader(d.version)
					vb := prim.read_bytes(&rd)
					if !prim.reader_ok(&rd) {
						return nil, .Corrupt
					}
					_cu_put_line(&lines, d.tree, convo_line_key(d.line), vb)
				}
			}
		}
	}
	_cu_fill_actors(e, o, convs, lines[:]) or_return
	return lines[:], .None
}

@(private)
_cu_reply_on :: proc(e: ^Engine, o: Object, path: []Rid) -> (reply: Rid, err: Error) {
	for i := len(path) - 1; i >= 0; i -= 1 {
		m := convo_message(e, o, {msg = path[i]}, context.temp_allocator) or_return
		if m.role == .Assistant {
			return path[i], .None
		}
	}
	return {}, .None
}

@(private)
_cu_park :: proc(e: ^Engine, space: prim.Id, set: []convo.Undo_Line) -> Error {
	for &l in set {
		v := tree_version(e, Object{space, l.tree}, l.line, context.temp_allocator) or_return
		vb := make([dynamic]u8, context.temp_allocator)
		fs.encode_version(&vb, v)
		l.park = vb[:]
	}
	return .None
}

@(private)
_cu_fill_actors :: proc(e: ^Engine, o: Object, convs: []Undo_Conv, lines: []convo.Undo_Line) -> Error {
	actors := make([dynamic]prim.Id, context.temp_allocator)
	add :: proc(list: ^[dynamic]prim.Id, a: prim.Id) {
		if a != {} && !slice.contains(list[:], a) {
			append(list, a)
		}
	}
	mids := make([dynamic]prim.Id, context.temp_allocator)
	for c in convs {
		h := _handle_get(e, c.o, .Conversation) or_return
		_handle_refresh(h)
		sa, serr := convo.scope_actors(&h.view, context.temp_allocator)
		if serr != .None {
			return _oerr(serr)
		}
		for a in sa {
			add(&actors, a)
		}
		ud, uerr := convo.undones(&h.view, context.temp_allocator)
		if uerr != .None {
			return _oerr(uerr)
		}
		for u in ud {
			for r in u.reverts {
				add(&actors, r.revert)
			}
		}
		if e.undo_hooks.mounts != nil {
			for mid in e.undo_hooks.mounts(e.undo_hooks.data, e, c.o, context.temp_allocator) {
				add(&mids, mid)
			}
		}
	}
	owners := make([dynamic]prim.Id, context.temp_allocator)
	for c in convs {
		append(&owners, c.o.id)
	}
	for &l in lines {
		own := make([dynamic]prim.Id, context.temp_allocator)
		append(&own, ..actors[:])
		th := _handle_get(e, Object{o.space, l.tree}, .File_Tree) or_return
		_hist_ready(e, th) or_return
		oa, oerr := fs.history_owned_actors(th.hist, owners[:], context.temp_allocator)
		if oerr != .None {
			return _ferr(oerr)
		}
		for a in oa {
			add(&own, a)
		}
		if len(mids) > 0 {
			keys := make([dynamic]string, context.temp_allocator)
			for x in lines {
				if x.tree == l.tree {
					append(&keys, x.line)
				}
			}
			ma, merr := fs.history_mount_actors(th.hist, mids[:], keys[:], context.temp_allocator)
			if merr != .None {
				return _ferr(merr)
			}
			for a in ma {
				add(&own, a)
			}
		}
		l.actors = own[:]
	}
	return .None
}

@(private)
_cu_redo_set :: proc(e: ^Engine, o: Object, of: prim.Id) -> (set: []convo.Undo_Line, err: Error) {
	u := _cu_undone_of(e, o, of) or_return
	lines := make([dynamic]convo.Undo_Line, context.temp_allocator)
	for r in u.reverts {
		th := _handle_get(e, Object{o.space, r.tree}, .File_Tree) or_return
		_hist_ready(e, th) or_return
		before, ferr := fs.revert_parents(th.hist, r.revert, context.temp_allocator)
		if ferr != .None {
			return nil, _ferr(ferr)
		}
		vb := make([dynamic]u8, context.temp_allocator)
		fs.encode_version(&vb, before)
		actors := make([]prim.Id, 1, context.temp_allocator)
		actors[0] = r.revert
		append(&lines, convo.Undo_Line{tree = r.tree, line = r.line, base = vb[:], actors = actors})
	}
	return lines[:], .None
}

@(private)
_cu_undo_line :: proc(e: ^Engine, space: prim.Id, undo: prim.Id, owner: prim.Id, l: convo.Undo_Line) -> Error {
	if len(l.actors) == 0 {
		return .None
	}
	tree := Object{space, l.tree}
	if _, found := tree_undo_revert(e, tree, undo, l.line) or_return; found {
		return .None
	}
	base, derr := fs.decode_version(l.base, context.temp_allocator)
	if derr != .None {
		return .Corrupt
	}
	if r := tree_revert_set(e, tree, base, l.actors, l.line, undo, owner) or_return; r != {} {
		_mounts_wake_now(e, l.tree)
	}
	return .None
}

@(private)
_cu_undo_undone :: proc(e: ^Engine, o: Object, st: ^convo.Undo_State, convs: []Undo_Conv) -> Error {
	if _, uerr := _cu_undone_of(e, o, st.id); uerr == .None {
		return .None
	} else if uerr != .Not_Found {
		return uerr
	}
	leaves := make([dynamic]convo.Undone_Leaf, context.temp_allocator)
	hidden := make([dynamic]prim.Id, context.temp_allocator)
	for c in convs {
		if c.hidden || c.gone {
			append(&hidden, c.o.id)
			continue
		}
		cs := convo_status(e, c.o) or_return
		append(&leaves, convo.Undone_Leaf{conv = c.o.id, leaf = cs.position if cs.browsing else {}})
	}
	reverts := make([dynamic]convo.Undone_Revert, context.temp_allocator)
	for l in st.set {
		if r, found := tree_undo_revert(e, Object{o.space, l.tree}, st.id, l.line) or_return; found {
			append(&reverts, convo.Undone_Revert{tree = l.tree, line = l.line, revert = r})
		}
	}
	kept := make([dynamic]convo.Line_Bind, context.temp_allocator)
	if e.undo_hooks.checkouts != nil {
		for c in convs {
			if !c.hidden {
				append(&kept, ..e.undo_hooks.checkouts(e.undo_hooks.data, e, c.o, context.temp_allocator))
			}
		}
	}
	h := _convo_writable(e, o) or_return
	if _, x := convo.writer_undone(&h.cw, st.id, st.msg, leaves[:], reverts[:], kept[:], hidden[:]); x != .None {
		return _oerr(x)
	}
	for k in kept {
		if _, x := convo.writer_notice(&h.cw, convo.Notice{undo = st.id, from = o.id, kind = .Checkout, tree = k.tree, line = k.line, paths = []string{k.mount}}); x != .None {
			return _oerr(x)
		}
	}
	return _cu_durable(e, h)
}

@(private)
_cu_undo_unmount :: proc(e: ^Engine, o: Object, msg: Rid) -> Error {
	t := convo_message(e, o, {msg = msg}, context.temp_allocator) or_return
	at := _cu_first_reply_after(e, o, t.hlc) or_return
	if obj.rid_none(at) {
		return .None
	}
	fd := convo_files_at(e, o, at, context.temp_allocator) or_return
	ms := convo_mounts(e, o, context.temp_allocator) or_return
	h := _convo_writable(e, o) or_return
	for m in ms {
		if m.removed {
			continue
		}
		at := false
		for d in fd {
			at ||= d.mount == m.name
		}
		if !at {
			if _, x := convo.writer_unmount(&h.cw, m.name); x != .None {
				return _oerr(x)
			}
		}
	}
	_oerr(convo.writer_commit(&h.cw)) or_return
	_handle_mark(h)
	return .None
}

@(private)
_cu_undo_leaves :: proc(e: ^Engine, o: Object, st: ^convo.Undo_State, convs: []Undo_Conv) -> Error {
	if _cu_switch_like(st^) {
		if st.cause == .Redo {
			u := _cu_undone_of(e, o, st.redo) or_return
			own := false
			for l in u.leaves {
				_cu_set_leaf(e, Object{o.space, l.conv}, l.leaf) or_return
				own ||= l.conv == o.id
			}
			if own {
				return .None
			}
		}
		return _cu_set_leaf(e, o, st.to)
	}
	if st.redo != {} {
		u := _cu_undone_of(e, o, st.redo) or_return
		for l in u.leaves {
			_cu_set_leaf(e, Object{o.space, l.conv}, l.leaf) or_return
		}
		return .None
	}
	t := convo_message(e, o, {msg = st.msg}, context.temp_allocator) or_return
	for c, i in convs {
		if c.hidden {
			continue
		}
		target := t.parent
		if i > 0 {
			target = _cu_head_before(e, c.o, t.hlc) or_return
		}
		if obj.rid_none(target) {
			continue
		}
		_cu_set_leaf(e, c.o, target) or_return
	}
	return .None
}

@(private)
_cu_set_leaf :: proc(e: ^Engine, o: Object, leaf: Rid) -> Error {
	st := convo_status(e, o) or_return
	if (st.browsing && st.position == leaf) || (!st.browsing && obj.rid_none(leaf)) {
		return .None
	}
	h := _convo_writable(e, o) or_return
	if _, x := convo.writer_set_leaf(&h.cw, leaf); x != .None {
		return _oerr(x)
	}
	return _cu_durable(e, h)
}

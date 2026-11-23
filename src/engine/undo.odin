package engine

import "core:fmt"

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
}

@(private)
Undo_Conv :: struct {
	o:      Object,
	hidden: bool,
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
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU convo_undo: %v", err) }
	context = context_for(e)
	undo = new_id(e)
	_cu_undo_write(e, o, undo, msg, .Staged, nil, {}) or_return
	return undo, convo_undo_drive(e, o, undo)
}

convo_redo :: proc(e: ^Engine, o: Object, of: prim.Id) -> (redo: prim.Id, err: Error) {
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU convo_redo: %v", err) }
	context = context_for(e)
	u := _cu_undone_of(e, o, of) or_return
	redo = new_id(e)
	_cu_undo_write(e, o, redo, u.msg, .Staged, nil, of) or_return
	return redo, convo_undo_drive(e, o, redo)
}

convo_undos :: proc(e: ^Engine, o: Object, allocator := context.allocator) -> (out: []convo.Undo_State, err: Error) {
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU convo_undos: %v", err) }
	context = context_for(e)
	h := _handle_get(e, o, .Conversation) or_return
	_handle_refresh(h)
	u, uerr := convo.undos(&h.view, allocator)
	return u, _oerr(uerr)
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
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_undo_state: %v", err) }
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
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_undone_of: %v", err) }
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
_cu_undo_write :: proc(e: ^Engine, o: Object, undo: prim.Id, msg: Rid, phase: convo.Undo_Phase, set: []convo.Undo_Line, redo: prim.Id) -> Error {
	h := _convo_writable(e, o) or_return
	if _, x := convo.writer_undo(&h.cw, undo, msg, phase, set, redo); x != .None {
		return _oerr(x)
	}
	return _cu_durable(e, h)
}

@(private)
_cu_durable :: proc(e: ^Engine, h: ^Handle) -> Error {
	_oerr(convo.writer_commit(&h.cw)) or_return
	_handle_mark(h)
	if e.in_tick {
		return .None
	}
	return flush(e)
}

@(private)
_cu_undo_step :: proc(e: ^Engine, o: Object, st: ^convo.Undo_State) -> Error {
	convs := _cu_undo_tree(e, o, st.msg) or_return
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
		if st.redo != {} {
			set = _cu_redo_set(e, o, st.redo) or_return
		} else {
			set = _cu_undo_set(e, o, st.msg, convs) or_return
		}
		return _cu_undo_write(e, o, st.id, st.msg, .Fenced, set, st.redo)
	case .Fenced:
		for l in st.set {
			_cu_undo_line(e, o.space, st.id, o.id, l) or_return
		}
		_cu_undo_undone(e, o, st, convs) or_return
		return _cu_undo_write(e, o, st.id, st.msg, .Reverted, nil, st.redo)
	case .Reverted:
		if st.redo == {} {
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
_cu_undo_tree :: proc(e: ^Engine, o: Object, msg: Rid) -> (out: []Undo_Conv, err: Error) {
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_undo_tree: %v", err) }
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
			if true {
				fmt.eprintfln("DBGU row %x kind %v parent %x", r.object, r.kind, r.parent.object)
			}
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
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_first_reply_after: %v", err) }
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
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_head_before: %v", err) }
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
_cu_undo_set :: proc(e: ^Engine, o: Object, msg: Rid, convs: []Undo_Conv) -> (set: []convo.Undo_Line, err: Error) {
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_undo_set: %v", err) }
	t := convo_message(e, o, {msg = msg}, context.temp_allocator) or_return
	actors := make([dynamic]prim.Id, context.temp_allocator)
	add :: proc(list: ^[dynamic]prim.Id, a: prim.Id) {
		if a != {} && !slice.contains(list[:], a) {
			append(list, a)
		}
	}
	mids := make([dynamic]prim.Id, context.temp_allocator)
	for c in convs {
		fmt.eprintfln("DBGU conv %x hidden %v", c.o.id, c.hidden)
		h := _handle_get(e, c.o, .Conversation) or_return
		_handle_refresh(h)
		sa, serr := convo.scope_actors(&h.view, context.temp_allocator)
		if serr != .None {
			return nil, _oerr(serr)
		}
		for a in sa {
			add(&actors, a)
		}
		ud, uerr := convo.undones(&h.view, context.temp_allocator)
		if uerr != .None {
			return nil, _oerr(uerr)
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
	lines := make([dynamic]convo.Undo_Line, context.temp_allocator)
	put :: proc(lines: ^[dynamic]convo.Undo_Line, tree: prim.Id, line: string, base: []u8) {
		for l in lines {
			if l.tree == tree && l.line == line {
				return
			}
		}
		append(lines, convo.Undo_Line{tree = tree, line = line, base = base})
	}
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
				fmt.eprintfln("DBGU files_at tree %x mount %q line %q", d.tree, d.mount, d.line)
				put(&lines, d.tree, convo_line_key(d.line), vb)
				named[d.mount] = true
			}
		}
		ms := convo_mounts(e, c.o, context.temp_allocator) or_return
		for m in ms {
			fmt.eprintfln("DBGU mount tree %x name %q line %q removed %v", m.tree, m.name, m.line, m.removed)
			if !m.removed && !named[m.name] {
				put(&lines, m.tree, convo_line_key(m.line), nil)
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
		fmt.eprintfln("DBGU line tree %x line %q", l.tree, l.line)
		th := _handle_get(e, Object{o.space, l.tree}, .File_Tree) or_return
		_hist_ready(e, th) or_return
		oa, oerr := fs.history_owned_actors(th.hist, owners[:], context.temp_allocator)
		if oerr != .None {
			return nil, _ferr(oerr)
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
				return nil, _ferr(merr)
			}
			for a in ma {
				add(&own, a)
			}
		}
		l.actors = own[:]
	}
	return lines[:], .None
}

@(private)
_cu_redo_set :: proc(e: ^Engine, o: Object, of: prim.Id) -> (set: []convo.Undo_Line, err: Error) {
	defer if err != .None && err != .Pending { fmt.eprintfln("DBGU _cu_redo_set: %v", err) }
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
	_ = tree_revert_set(e, tree, base, l.actors, l.line, undo, owner) or_return
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
		if c.hidden {
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

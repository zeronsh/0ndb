package rt

import "base:runtime"
import "../convo"
import eng "../engine"
import "../fs"
import "../prim"

HOLD_UNDO :: "undo"
KEY_UNDO_RUN :: "undo/run/"
KEY_UNDO_PAUSED :: "undo/paused/"
UNDO_RETRY_MS :: 2000

Undo_Pending :: struct {
	o:  Object,
	id: prim.Id,
}

undo_hooks_install :: proc(r: ^Runtime) {
	eng.undo_hooks_set(r.e, eng.Undo_Hooks{data = r, hold = _undo_hold, mounts = _undo_mounts, release = _undo_release, checkouts = _undo_checkouts})
}

runtime_undo :: proc(r: ^Runtime, o: Object, msg: Rid) -> (undo: prim.Id, err: eng.Error) {
	context = eng.context_for(r.e)
	undo, err = eng.convo_undo(r.e, o, msg)
	_undo_track(r, o, undo, err)
	return
}

runtime_redo :: proc(r: ^Runtime, o: Object, of: prim.Id) -> (redo: prim.Id, err: eng.Error) {
	context = eng.context_for(r.e)
	redo, err = eng.convo_redo(r.e, o, of)
	_undo_track(r, o, redo, err)
	return
}

runtime_undo_resume :: proc(r: ^Runtime, o: Object) -> (resumed: int) {
	context = eng.context_for(r.e)
	id := o.id
	map_clear(r, state_w(r, o.space), key_of(KEY_UNDO_PAUSED, id[:]), 1)
	for c in _undo_tree_objects(r, o) {
		w, werr := eng.convo_writer(r.e, c)
		if werr != .None {
			continue
		}
		if n, _ := hold_release(r, c, w, HOLD_UNDO); n > 0 {
			resumed += 1
			_queue_eval(r, c)
		}
	}
	return
}

undo_paused :: proc(r: ^Runtime, o: Object) -> bool {
	id := o.id
	_, found := map_read(r, state_object(r, o.space), key_of(KEY_UNDO_PAUSED, id[:]))
	return found
}

undo_attach :: proc(r: ^Runtime, space: prim.Id) {
	rows := map_rows(r, state_object(r, space), transmute([]u8)string(KEY_UNDO_RUN))
	for &row in rows {
		if len(row.key) != len(KEY_UNDO_RUN) + 32 || !entry_live(&row.entry) {
			continue
		}
		p := Undo_Pending{o = Object{space = space}}
		copy(p.o.id[:], row.key[len(KEY_UNDO_RUN):][:16])
		copy(p.id[:], row.key[len(KEY_UNDO_RUN) + 16:][:16])
		_undo_pending_add(r, p)
	}
	if len(r.undo_pending) > 0 {
		undo_kick(r)
	}
}

undo_kick :: proc(r: ^Runtime) {
	if r.closing || len(r.undo_pending) == 0 || r.undo_timer != 0 {
		return
	}
	r.undo_timer = prim.timer(eng.loop(r.e), 0, r, _undo_fire)
}

undo_close :: proc(r: ^Runtime) {
	if r.undo_timer != 0 {
		prim.timer_cancel(eng.loop(r.e), r.undo_timer)
		r.undo_timer = 0
	}
	delete(r.undo_pending)
	r.undo_pending = nil
}

@(private)
_undo_fire :: proc(l: ^prim.Loop, data: rawptr) {
	r := (^Runtime)(data)
	context = eng.context_for(r.e)
	r.undo_timer = 0
	i := 0
	for i < len(r.undo_pending) {
		p := r.undo_pending[i]
		err := eng.convo_undo_drive(r.e, p.o, p.id)
		if err == .Pending {
			i += 1
			continue
		}
		ordered_remove(&r.undo_pending, i)
		_undo_untrack(r, p)
	}
	if len(r.undo_pending) > 0 && !r.closing {
		r.undo_timer = prim.timer(l, UNDO_RETRY_MS, r, _undo_fire)
	}
}

@(private)
_undo_track :: proc(r: ^Runtime, o: Object, undo: prim.Id, err: eng.Error) {
	if err != .Pending || undo == {} {
		return
	}
	id, u := o.id, undo
	map_put(r, state_w(r, o.space), key_of(KEY_UNDO_RUN, id[:], u[:]), field_bytes(1, []u8{1}))
	_undo_pending_add(r, Undo_Pending{o = o, id = undo})
	undo_kick(r)
}

@(private)
_undo_untrack :: proc(r: ^Runtime, p: Undo_Pending) {
	id, u := p.o.id, p.id
	map_clear(r, state_w(r, p.o.space), key_of(KEY_UNDO_RUN, id[:], u[:]), 1)
}

@(private)
_undo_pending_add :: proc(r: ^Runtime, p: Undo_Pending) {
	for x in r.undo_pending {
		if x == p {
			return
		}
	}
	if r.undo_pending == nil {
		r.undo_pending = make([dynamic]Undo_Pending, r.allocator)
	}
	append(&r.undo_pending, p)
}

@(private)
_undo_held :: proc(r: ^Runtime, o: Object) -> bool {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return false
	}
	hs, herr := convo.holds(v, context.temp_allocator)
	if herr != .None {
		return false
	}
	for h in hs {
		if h.key == HOLD_UNDO {
			return true
		}
	}
	return false
}

@(private)
_undo_hold :: proc(data: rawptr, e: ^eng.Engine, convs: []Object, undo: prim.Id) -> eng.Error {
	r := (^Runtime)(data)
	busy := false
	for c in convs {
		if !_undo_held(r, c) {
			w, werr := eng.convo_writer(e, c)
			if werr != .None {
				return werr
			}
			if hold_set(r, c, w, HOLD_UNDO, "undo") != .None {
				return .Io
			}
		}
		if run := run_find(r, c); run != nil && run.state != .Finished {
			run_hold_request(run, .Undo, "")
			busy = true
			continue
		}
		st, serr := eng.convo_status(e, c)
		if serr != .None {
			return serr
		}
		busy ||= st.running
	}
	return .Pending if busy else .None
}

@(private)
_undo_release :: proc(data: rawptr, e: ^eng.Engine, convs: []Object, undo: prim.Id) -> eng.Error {
	r := (^Runtime)(data)
	if len(convs) == 0 {
		return .None
	}
	a := convs[0]
	for c in convs {
		if ent, found := state_run_get(r, c); found && convo.Hold_Reason(ent.hold) == .Undo {
			_undo_unbind(r, c, ent)
			if cw, cwerr := eng.convo_writer(e, c); cwerr == .None {
				convo.writer_decline(cw, ent.reply)
				eng.touched(e, c)
			}
			state_run_clear(r, c)
		}
	}
	w, werr := eng.convo_writer(e, a)
	if werr != .None {
		return werr
	}
	if _, rerr := hold_release(r, a, w, HOLD_UNDO); rerr != .None {
		return .Io
	}
	if len(convs) > 1 {
		id := a.id
		map_put(r, state_w(r, a.space), key_of(KEY_UNDO_PAUSED, id[:]), field_bytes(1, []u8{1}))
	}
	return .None
}

@(private)
_undo_mounts :: proc(data: rawptr, e: ^eng.Engine, conv: Object, allocator: runtime.Allocator) -> []prim.Id {
	r := (^Runtime)(data)
	return fork_mount_ids(r, conv, allocator)
}

fork_dir :: proc(r: ^Runtime, o: Object, m: convo.Mount_Entry, single: bool) -> string {
	id := o.id
	base := concat(r.cfg.work_root, "/", hex(id))
	sub := m.path if len(m.path) > 0 else m.name
	return base if single && len(m.path) == 0 else concat(base, "/", sub)
}

fork_mount_id :: proc(tree: prim.Id, dir: string) -> prim.Id {
	clean := fs.clean_path(dir, context.temp_allocator)
	id := tree
	return derive_id("0ndb-fork-mount-v1", id[:], transmute([]u8)clean)
}

fork_mount_ids :: proc(r: ^Runtime, o: Object, allocator := context.allocator) -> []prim.Id {
	ms, merr := eng.convo_mounts(r.e, o, context.temp_allocator)
	if merr != .None {
		return nil
	}
	out := make([dynamic]prim.Id, 0, len(ms), allocator)
	for m in ms {
		append(&out, fork_mount_id(m.tree, fork_dir(r, o, m, len(ms) == 1)))
	}
	return out[:]
}

@(private)
_undo_tree_objects :: proc(r: ^Runtime, o: Object) -> []Object {
	list := make([dynamic]Object, context.temp_allocator)
	append(&list, o)
	rows := make([dynamic]eng.Catalog_Row, context.temp_allocator)
	for archived in ([2]bool{false, true}) {
		cur: eng.Map_Cursor
		for {
			page, more, err := eng.catalog_list(r.e, o.space, archived, &cur, 256, context.temp_allocator)
			if err != .None {
				break
			}
			append(&rows, ..page)
			if !more {
				break
			}
		}
	}
	for grew := true; grew; {
		grew = false
		for row in rows {
			if row.kind != .Conversation {
				continue
			}
			parent, seen := false, false
			for c in list {
				seen ||= c.id == row.object
				parent ||= c.id == row.parent.object
			}
			if parent && !seen {
				append(&list, Object{o.space, row.object})
				grew = true
			}
		}
	}
	return list[:]
}

@(private)
_undo_unbind :: proc(r: ^Runtime, o: Object, ent: Run_Entry) {
	reg, rerr := eng.registry(r.e)
	if rerr != .None {
		return
	}
	ms, merr := eng.convo_mounts(r.e, o, context.temp_allocator)
	if merr != .None {
		return
	}
	for l in lines_decode(ent.lines) {
		run_line := line_name(l.line)
		conv := ""
		for me in ms {
			if me.name == l.mount && !me.removed {
				conv = line_name(me.line)
			}
		}
		if len(conv) == 0 || conv == run_line {
			continue
		}
		for m in reg.mounts {
			if m != nil && m.line == run_line {
				_member_switch(m, conv)
				fs.mount_materialize(m)
			}
		}
	}
}

@(private)
_undo_checkouts :: proc(data: rawptr, e: ^eng.Engine, conv: Object, allocator: runtime.Allocator) -> []convo.Line_Bind {
	r := (^Runtime)(data)
	reg, rerr := eng.registry(e)
	if rerr != .None {
		return nil
	}
	ms, merr := eng.convo_mounts(e, conv, context.temp_allocator)
	if merr != .None {
		return nil
	}
	out := make([dynamic]convo.Line_Bind, allocator)
	for me in ms {
		if me.removed {
			continue
		}
		home, ok := _tree_home(r, me.tree)
		if !ok {
			continue
		}
		clean := fs.clean_path(home, context.temp_allocator)
		want := line_name(me.line)
		for m in reg.mounts {
			if m != nil && m.root == clean && m.line != want && !_line_is_run(r, conv, m.line) {
				append(&out, convo.Line_Bind{mount = clone(me.name, allocator), tree = me.tree, line = clone(m.line, allocator)})
			}
		}
	}
	return out[:]
}

@(private)
_line_is_run :: proc(r: ^Runtime, conv: Object, line: string) -> bool {
	if ent, found := state_run_get(r, conv); found {
		for l in lines_decode(ent.lines) {
			if line_name(l.line) == line {
				return true
			}
		}
	}
	for run in r.runs {
		for l in run.lines {
			if line_name(l.line) == line {
				return true
			}
		}
	}
	return false
}

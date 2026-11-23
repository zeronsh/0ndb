package engine

import "core:mem/virtual"
import "../crdt"
import dl "../dlog"
import "../fs"
import "../prim"

@(private)
_dlog_path :: proc(e: ^Engine) -> (string, Error) {
	return _join(context.temp_allocator, e.pack_root, "buffer-deletes")
}

@(private)
_dlog_open :: proc(e: ^Engine) {
	if e.dlog_open || !e.pk_open {
		return
	}
	path, perr := _dlog_path(e)
	if perr != .None {
		return
	}
	stored, serr := _clone(path, e.allocator)
	if serr != .None {
		return
	}
	if dl.open(&e.dlog, e.vfs, stored, e.allocator) != .None {
		delete(stored, e.allocator)
		_log(e, .Warn, "the buffer delete log did not open")
		return
	}
	e.dlog_path = stored
	e.dlog_open = true
	for x in e.dlog.live {
		_object_changed(e, x.space, x.object, .Local)
	}
}

@(private)
_dlog_close :: proc(e: ^Engine) {
	if !e.dlog_open {
		return
	}
	dl.close(&e.dlog)
	delete(e.dlog_path, e.allocator)
	e.dlog_path = ""
	e.dlog_open = false
}

@(private)
_dlog_record :: proc(e: ^Engine, b: ^Buffer, hits: []crdt.Op_Span) -> Error {
	_dlog_open(e)
	if !e.dlog_open {
		return .Io
	}
	inode := fs.inode_op(b.hist, b.inode)
	spans := make([]dl.Span, len(hits), context.temp_allocator)
	for g, i in hits {
		spans[i] = dl.Span{g.id.actor, g.id.seq, g.len}
	}
	x := dl.Entry {
		space       = b.object.space,
		object      = b.object.id,
		kind        = u8(b.kind),
		inode_actor = inode.actor,
		inode_seq   = inode.seq,
		actor       = b.actor,
		line        = b.line,
		spans       = spans,
	}
	if _, err := dl.add(&e.dlog, x); err != .None {
		return .Io if err == .Io else .Invalid
	}
	e.stats.buffer_live_intents += u64(len(hits))
	_object_changed(e, b.object.space, b.object.id, .Local)
	return .None
}

@(private)
_dlog_tick :: proc(e: ^Engine) {
	if !e.dlog_open || len(e.dlog.live) == 0 || len(e.changed) == 0 {
		return
	}
	scratch := virtual.arena_temp_begin(&e.temp)
	defer virtual.arena_temp_end(scratch)
	due := make([dynamic]u64, context.temp_allocator)
	for x in e.dlog.live {
		if _, ok := e.changed[x.object]; ok {
			append(&due, x.id)
		}
	}
	for id in due {
		if !e.dlog_open {
			return
		}
		at := -1
		for x, i in e.dlog.live {
			if x.id == id {
				at = i
				break
			}
		}
		if at < 0 || !_dlog_apply(e, e.dlog.live[at]) {
			continue
		}
		if dl.done(&e.dlog, id) != .None {
			_log(e, .Warn, "the buffer delete log did not record an applied delete")
			continue
		}
		e.stats.buffer_live_intents_applied += 1
	}
}

@(private)
_dlog_apply :: proc(e: ^Engine, x: dl.Entry) -> bool {
	kind := Kind(x.kind)
	if kind != .Text && kind != .File_Tree {
		return true
	}
	o := Object{x.space, x.object}
	h, err := _handle_get(e, o, kind)
	if err != .None {
		return err == .Not_Found
	}
	if _hist_ready(e, h) != .None || _hist_caught_up(e, h) != .None {
		return false
	}
	hist := h.hist
	if hist == nil || hist.own_wait {
		return false
	}
	for s in x.spans {
		if _, ok := crdt.graph_lv(&hist.g, crdt.Op_Id{s.actor, s.seq + u64(s.len) - 1}); !ok {
			return false
		}
	}
	b := new(Buffer, e.allocator)
	defer _buffer_free(e, b)
	b.object = o
	b.kind = kind
	b.inode = fs.op_inode(hist, crdt.Op_Id{x.inode_actor, x.inode_seq})
	b.units = .Bytes
	b.hist = hist
	b.actor = x.actor
	line, lerr := _clone(x.line, e.allocator)
	if lerr != .None {
		return false
	}
	b.line = line
	b.version = make([dynamic]crdt.Op_Id, e.allocator)
	target, terr := _buffer_target(b, h)
	if terr != .None {
		return false
	}
	v := _dlog_chain(hist, target, x.actor)
	view, verr := fs.history_view_open(hist, b.inode, v)
	if verr != .None {
		return false
	}
	b.view = view
	append(&b.version, ..v)
	g := Undo_Group {
		inserts = make([dynamic]crdt.Op_Span, context.temp_allocator),
		deletes = make([dynamic]Undo_Del, context.temp_allocator),
	}
	for s in x.spans {
		append(&g.inserts, crdt.Op_Span{crdt.Op_Id{s.actor, s.seq}, s.len})
	}
	if _, aerr := _undo_apply(e, b, h, &g); aerr != .None {
		_log(e, .Warn, "a recorded buffer delete did not apply")
		return false
	}
	return true
}

@(private)
_dlog_chain :: proc(hist: ^fs.History, target: fs.Version, actor: prim.Id) -> fs.Version {
	next := fs.history_next_seq(hist, actor)
	if next == 0 {
		return target
	}
	latest := [1]crdt.Op_Id{{actor, next - 1}}
	if fs.history_contains(hist, target, latest[0]) {
		return target
	}
	out := make([dynamic]crdt.Op_Id, 0, len(target) + 1, context.temp_allocator)
	for id in target {
		if !fs.history_contains(hist, latest[:], id) {
			append(&out, id)
		}
	}
	append(&out, latest[0])
	return out[:]
}

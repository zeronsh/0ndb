package engine

import "../fs"
import "../prim"

tree_revert_set :: proc(e: ^Engine, o: Object, base: fs.Version, actors: []prim.Id, line := "") -> (revert: prim.Id, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	at := _tree_at(e, h, line, nil) or_return
	cur := at.version if !at.head else fs.history_heads(h.hist, context.temp_allocator)
	r, ferr := fs.history_revert_set(h.hist, at.line, base, cur, actors)
	if ferr != .None {
		return {}, _ferr(ferr)
	}
	if r != {} {
		_mounts_wake(e, h.id)
		_handle_mark(h)
	}
	return r, .None
}

tree_unrevert :: proc(e: ^Engine, o: Object, revert: prim.Id, line := "") -> (again: prim.Id, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_hist_ready(e, h) or_return
	before, ferr := fs.revert_parents(h.hist, revert, context.temp_allocator)
	if ferr != .None {
		return {}, _ferr(ferr)
	}
	return tree_revert_set(e, o, before, []prim.Id{revert}, line)
}

tree_version :: proc(e: ^Engine, o: Object, line := "", allocator := context.allocator) -> (v: fs.Version, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_hist_ready(e, h) or_return
	_hist_catch_up(e, h)
	at := _tree_at(e, h, line, nil) or_return
	cur := at.version if !at.head else fs.history_heads(h.hist, context.temp_allocator)
	out := make(fs.Version, len(cur), allocator)
	copy(out, cur)
	return out, .None
}

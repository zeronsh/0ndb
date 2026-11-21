package fs

import "../crdt"
import "../fshist"
import "../fstree"
import "../textdiff"

Text_View :: struct {
	inode:    fstree.Inode_Id,
	using st: fshist.Text_State,
	stale:    bool,
	full:     bool,
	cp:       [dynamic]crdt.Op_Id,
}

history_view_open :: proc(h: ^History, inode: fstree.Inode_Id, v: Version) -> (view: ^Text_View, err: Error) {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v, &lvs) != .None {
		return nil, .Not_Found
	}
	view = new(Text_View, h.allocator)
	view.inode = inode
	if err = view_load(h, view, lvs[:]); err != .None {
		free(view, h.allocator)
		return nil, err
	}
	if h.views == nil {
		h.views = make([dynamic]^Text_View, h.allocator)
	}
	append(&h.views, view)
	return view, .None
}

history_view_close :: proc(h: ^History, view: ^Text_View) {
	for x, i in h.views {
		if x == view {
			unordered_remove(&h.views, i)
			break
		}
	}
	fshist.text_drop(&view.st)
	delete(view.cp)
	free(view, h.allocator)
}

history_op_content :: proc(h: ^History, src: crdt.Op_Id, dst: []u8) -> int {
	authors := make([dynamic]crdt.Author_Span, context.temp_allocator)
	return copy_read_depth(h, src, dst, &authors, 0)
}

history_view_version :: proc(h: ^History, view: ^Text_View, allocator := context.allocator) -> Version {
	return crdt.graph_version_ids(&h.g, view.text.version[:], allocator)
}

@(private)
views_stale :: proc(h: ^History, inode: Maybe(fstree.Inode_Id) = nil) {
	only, one := inode.?
	for v in h.views {
		if !one || v.inode == only {
			v.stale = true
		}
	}
}

@(private)
views_feed :: proc(h: ^History, ino: fstree.Inode_Id, b: ^crdt.Batch, target: crdt.Op_Id, first: crdt.Lv, skip: int) {
	for v in h.views {
		if v.inode != ino || !v.loaded || v.stale {
			continue
		}
		if v.from_cp && !view_descends(h, v, b) {
			v.stale = true
			v.full = true
			continue
		}
		crdt.log_add_batch(&v.log, &h.g, b, target, first, skip)
	}
}

@(private)
view_descends :: proc(h: ^History, v: ^Text_View, b: ^crdt.Batch) -> bool {
	cpv := make([dynamic]crdt.Lv, context.temp_allocator)
	ps := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, v.cp[:], &cpv) != .None || crdt.graph_version_lvs(&h.g, b.parents, &ps) != .None {
		return false
	}
	return crdt.graph_contains_all(&h.g, ps[:], cpv[:])
}

@(private)
view_load :: proc(h: ^History, view: ^Text_View, lvs: []crdt.Lv) -> Error {
	fshist.text_drop(&view.st)
	full := view.full
	view.stale = false
	view.full = false
	if view.cp == nil {
		view.cp = make([dynamic]crdt.Op_Id, h.allocator)
	}
	clear(&view.cp)
	if f, ok := h.files[view.inode]; ok && f.loaded && !full && crdt.frontier_eq(f.text.version[:], lvs) {
		append(&view.cp, ..f.rec.cp_version[:])
		if !f.dirty && len(f.new_refs) == 0 {
			view.st = f.st
			f.st = {}
			file_free(h, f)
			delete_key(&h.files, view.inode)
			return .None
		}
		crdt.text_clone(&view.text, &f.text, h.allocator)
		crdt.log_clone(&view.log, &f.log, h.allocator)
		view.loaded = true
		view.from_cp = f.from_cp
		return .None
	}
	tmp: File_State
	tmp.inode = view.inode
	owned := false
	if f, ok := h.files[view.inode]; ok {
		tmp.rec = f.rec
		tmp.new_refs = f.new_refs
	} else {
		owned = true
		if err := read_file_record(h, view.inode, &tmp.rec); err != .None {
			delete(tmp.rec.cp_version)
			delete(tmp.rec.cp_spans)
			return err
		}
	}
	defer if owned {
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	if err := load_text(h, &tmp, lvs, full); err != .None {
		fshist.text_drop(&tmp.st)
		return err
	}
	if tmp.from_cp {
		append(&view.cp, ..tmp.rec.cp_version[:])
	}
	view.st = tmp.st
	return .None
}

history_view_advance :: proc(h: ^History, view: ^Text_View, target: Version, sink: crdt.Text_Sink) -> Error {
	_, err := history_view_advance_ex(h, view, target, sink)
	return err
}

history_view_advance_ex :: proc(h: ^History, view: ^Text_View, target: Version, sink: crdt.Text_Sink) -> (reloaded: bool, err: Error) {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, target, &lvs) != .None {
		return false, .Not_Found
	}
	if view.loaded && !view.stale {
		if crdt.frontier_eq(view.text.version[:], lvs[:]) {
			return false, .None
		}
		if crdt.graph_contains_all(&h.g, lvs[:], view.text.version[:]) {
			merr := crdt.text_merge(&view.text, &h.g, &view.log, lvs[:], nil, sink)
			if merr == .None || merr == .Missing_Content {
				return false, .None
			}
		}
	}
	old: []u8
	if view.loaded {
		old = crdt.text_bytes(&view.text, context.temp_allocator)
	}
	if lerr := view_load(h, view, lvs[:]); lerr != .None {
		return true, lerr
	}
	if sink.insert != nil && sink.delete != nil {
		nw := crdt.text_bytes(&view.text, context.temp_allocator)
		view_diff_feed(h, view, old, nw, sink)
	}
	return true, .None
}

@(private)
view_diff_feed :: proc(h: ^History, view: ^Text_View, old, nw: []u8, sink: crdt.Text_Sink) {
	insert :: proc(h: ^History, view: ^Text_View, sink: crdt.Text_Sink, pos: int, nw: []u8, n: int) {
		i := 0
		for i < n {
			a, _, ok := crdt.text_author(&view.text, &h.g, pos + i)
			j := i + 1
			for j < n {
				b, _, bok := crdt.text_author(&view.text, &h.g, pos + j)
				if bok != ok || b.actor != a.actor {
					break
				}
				j += 1
			}
			sink.insert(sink.data, pos + i, nw[pos + i:pos + j], a)
			i = j
		}
	}
	edits, derr := textdiff.byte_diff(old, nw, context.temp_allocator)
	if derr != nil {
		if len(old) > 0 {
			sink.delete(sink.data, 0, old)
		}
		insert(h, view, sink, 0, nw, len(nw))
		return
	}
	shift := 0
	for e in edits {
		at := int(e.pos)
		from := at - shift
		if e.del > 0 {
			sink.delete(sink.data, at, old[from:from + int(e.del)])
		}
		if e.ins > 0 {
			insert(h, view, sink, at, nw, int(e.ins))
		}
		shift += int(e.ins) - int(e.del)
	}
}

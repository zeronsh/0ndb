package fs

import "core:slice"
import "../crdt"
import "../fshist"
import "../fstree"
import "../prim"
import "../textdiff"

Text_View :: struct {
	inode:    fstree.Inode_Id,
	using st: fshist.Text_State,
	stale:    bool,
	full:     bool,
	cp:       [dynamic]crdt.Op_Id,
	prev:     [dynamic]crdt.Author_Span,
	has_prev: bool,
	missing:  Maybe(Content_Ref),
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

history_view_anchor_full :: proc(h: ^History, view: ^Text_View, a: crdt.Anchor) -> (pos: int, err: Error) {
	tmp: File_State
	tmp.inode = view.inode
	owned := false
	if f, ok := h.files[view.inode]; ok {
		tmp.rec = f.rec
		tmp.new_refs = f.new_refs
	} else {
		owned = true
		if rerr := read_file_record(h, view.inode, &tmp.rec); rerr != .None {
			delete(tmp.rec.cp_version)
			delete(tmp.rec.cp_spans)
			return 0, rerr
		}
	}
	defer if owned {
		delete(tmp.rec.cp_version)
		delete(tmp.rec.cp_spans)
	}
	defer fshist.text_drop(&tmp.st)
	load_text(h, &tmp, view.text.version[:], true) or_return
	p, aerr := crdt.anchor_resolve(&tmp.text, &h.g, &tmp.log, a)
	if aerr != .None {
		return 0, .Not_Found
	}
	return p, .None
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
	delete(view.prev)
	free(view, h.allocator)
}

history_owns :: proc(h: ^History, id: crdt.Op_Id) -> bool {
	lv, ok := crdt.graph_lv(&h.g, id)
	if !ok {
		return false
	}
	_, _, stream, _, found := history_batch_at(h, lv)
	return found && stream == 0
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
			view_mark_stale(h, v)
		}
	}
}

@(private)
view_mark_stale :: proc(h: ^History, v: ^Text_View) {
	if !v.stale && v.loaded && !v.has_prev {
		if v.prev == nil {
			v.prev = make([dynamic]crdt.Author_Span, h.allocator)
		}
		clear(&v.prev)
		append(&v.prev, ..crdt.text_spans(&v.text, &h.g, context.temp_allocator))
		v.has_prev = true
	}
	v.stale = true
}

@(private)
views_feed :: proc(h: ^History, ino: fstree.Inode_Id, b: ^crdt.Batch, target: crdt.Op_Id, first: crdt.Lv, skip: int) {
	for v in h.views {
		if v.inode != ino || !v.loaded || v.stale {
			continue
		}
		if v.from_cp && !view_descends(h, v, b) {
			view_mark_stale(h, v)
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
	full := view.full
	if view.cp == nil {
		view.cp = make([dynamic]crdt.Op_Id, h.allocator)
	}
	if f, ok := h.files[view.inode]; ok && f.loaded && !full && crdt.frontier_eq(f.text.version[:], lvs) {
		fshist.text_drop(&view.st)
		view.stale = false
		clear(&view.cp)
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
	fshist.text_drop(&view.st)
	view.stale = false
	view.full = false
	clear(&view.cp)
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
	h.unread = nil
	view.missing = nil
	defer if err != .None {
		view.missing = h.unread
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, target, &lvs) != .None {
		return false, .Not_Found
	}
	if view.loaded && !view.stale {
		if crdt.frontier_eq(view.text.version[:], lvs[:]) {
			return false, .None
		}
		if crdt.graph_contains_all(&h.g, lvs[:], view.text.version[:]) {
			if crdt.text_ready(&view.text, &h.g, &view.log, lvs[:]) == .Missing_Content {
				return false, .Not_Found
			}
			merr := crdt.text_merge(&view.text, &h.g, &view.log, lvs[:], nil, sink)
			if merr == .None {
				return false, .None
			}
			if merr == .Missing_Content {
				return false, .Corrupt
			}
		}
	}
	old: []u8
	if view.loaded {
		old = crdt.text_bytes(&view.text, context.temp_allocator)
	}
	if lerr := view_load(h, view, lvs[:]); lerr != .None {
		return false, lerr
	}
	if sink.insert != nil && sink.delete != nil {
		nw := crdt.text_bytes(&view.text, context.temp_allocator)
		if view.has_prev {
			view_identity_feed(h, view, old, view.prev[:], nw, sink)
		} else {
			view_diff_feed(h, view, old, nw, sink)
		}
	}
	view.has_prev = false
	clear(&view.prev)
	return true, .None
}

@(private)
Id_Run :: struct {
	seq: u64,
	len: int,
}

@(private)
id_index :: proc(spans: []crdt.Author_Span) -> map[prim.Id][dynamic]Id_Run {
	m := make(map[prim.Id][dynamic]Id_Run, 16, context.temp_allocator)
	for sp in spans {
		list, ok := m[sp.op.actor]
		if !ok {
			list = make([dynamic]Id_Run, context.temp_allocator)
		}
		append(&list, Id_Run{sp.op.seq, sp.len})
		m[sp.op.actor] = list
	}
	for mk1_ in prim.sorted_keys(m) {
		if mk1_ not_in m {
			continue
		}
		list := &m[mk1_]
		slice.sort_by(list[:], proc(a, b: Id_Run) -> bool {
			return a.seq < b.seq
		})
	}
	return m
}

@(private)
id_presence :: proc(m: ^map[prim.Id][dynamic]Id_Run, id: crdt.Op_Id, limit: int) -> (present: bool, n: int) {
	list, ok := m[id.actor]
	if !ok {
		return false, limit
	}
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].seq + u64(list[mid].len) <= id.seq {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(list) && list[lo].seq <= id.seq {
		return true, min(limit, int(list[lo].seq + u64(list[lo].len) - id.seq))
	}
	if lo < len(list) {
		return false, min(limit, int(list[lo].seq - id.seq))
	}
	return false, limit
}

@(private)
view_identity_feed :: proc(h: ^History, view: ^Text_View, old: []u8, prev: []crdt.Author_Span, nw: []u8, sink: crdt.Text_Sink) {
	cur := crdt.text_spans(&view.text, &h.g, context.temp_allocator)
	in_new := id_index(cur)
	in_old := id_index(prev)
	oi, oo, ob := 0, 0, 0
	ni, no, nb := 0, 0, 0
	p := 0
	for oi < len(prev) || ni < len(cur) {
		if oi < len(prev) {
			sp := prev[oi]
			id := crdt.Op_Id{sp.op.actor, sp.op.seq + u64(oo)}
			present, k := id_presence(&in_new, id, sp.len - oo)
			if !present {
				sink.delete(sink.data, p, old[ob:ob + k])
				ob += k
				oo += k
				if oo == sp.len {
					oi += 1
					oo = 0
				}
				continue
			}
		}
		if ni < len(cur) {
			sp := cur[ni]
			id := crdt.Op_Id{sp.op.actor, sp.op.seq + u64(no)}
			present, k := id_presence(&in_old, id, sp.len - no)
			if !present {
				author := crdt.Op_Id{sp.id.actor, sp.id.seq + u64(no)}
				sink.insert(sink.data, p, nw[nb:nb + k], author)
				p += k
				nb += k
				no += k
				if no == sp.len {
					ni += 1
					no = 0
				}
				continue
			}
		}
		if oi >= len(prev) || ni >= len(cur) {
			break
		}
		a := prev[oi]
		c := cur[ni]
		k := min(a.len - oo, c.len - no)
		if a.op.actor != c.op.actor || a.op.seq + u64(oo) != c.op.seq + u64(no) {
			sink.delete(sink.data, p, old[ob:ob + k])
			ob += k
			oo += k
			if oo == a.len {
				oi += 1
				oo = 0
			}
			continue
		}
		t := 0
		for t < k {
			same := old[ob + t] == nw[nb + t]
			u := t + 1
			for u < k && (old[ob + u] == nw[nb + u]) == same {
				u += 1
			}
			if !same {
				sink.delete(sink.data, p, old[ob + t:ob + u])
				sink.insert(sink.data, p, nw[nb + t:nb + u], crdt.Op_Id{c.id.actor, c.id.seq + u64(no + t)})
			}
			p += u - t
			t = u
		}
		ob += k
		nb += k
		oo += k
		no += k
		if oo == a.len {
			oi += 1
			oo = 0
		}
		if no == c.len {
			ni += 1
			no = 0
		}
	}
	if ob < len(old) {
		sink.delete(sink.data, p, old[ob:])
	}
	if nb < len(nw) {
		sink.insert(sink.data, p, nw[nb:], {})
	}
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

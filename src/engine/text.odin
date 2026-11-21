package engine

import "../crdt"
import "../fs"
import "../fstree"
import "../journal"
import "../odb"
import "../prim"
import osync "../sync"

@(private)
TEXT_NAME :: "text"

text_create :: proc(e: ^Engine, space: prim.Id, title := "", initial := "") -> (o: Object, err: Error) {
	o = Object{space, prim.id_new()}
	h := _handle_get(e, o, .Text) or_return
	_handle_create_writer(h) or_return
	_hist_tree_op(e, h, fstree.Op_Create{parent = fstree.ROOT, name = TEXT_NAME, kind = .File}, initial) or_return
	_handle_mark(h)
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

tree_create :: proc(e: ^Engine, space: prim.Id, title := "") -> (o: Object, err: Error) {
	o = Object{space, prim.id_new()}
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_handle_mark(h)
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

text_read :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (data: []u8, err: Error) {
	h := _handle_get(e, o, .Text) or_return
	_hist_ready(e, h) or_return
	_hist_catch_up(e, h)
	inode, found := _text_inode(h) or_return
	if !found {
		return nil, _pending_result(e, h, .Missing, ready)
	}
	f := _ferr2(fs.history_file(h.hist, inode)) or_return
	return crdt.text_bytes(&f.text, allocator), .None
}

text_spans :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (spans: []crdt.Author_Span, err: Error) {
	h := _handle_get(e, o, .Text) or_return
	_hist_ready(e, h) or_return
	_hist_catch_up(e, h)
	inode, found := _text_inode(h) or_return
	if !found {
		return nil, _pending_result(e, h, .Missing, ready)
	}
	f := _ferr2(fs.history_file(h.hist, inode)) or_return
	return crdt.text_spans(&f.text, &h.hist.g, allocator), .None
}

tree_read :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}) -> (data: []u8, err: Error) {
	h := _handle_get(e, o, .File_Tree) or_return
	_hist_ready(e, h) or_return
	_hist_catch_up(e, h)
	snap := fstree.current(&h.hist.tree)
	id, ok, lerr := fstree.lookup(&snap, path)
	if lerr != nil {
		return nil, .Corrupt
	}
	if !ok {
		return nil, .Not_Found
	}
	f := _ferr2(fs.history_file(h.hist, id)) or_return
	return crdt.text_bytes(&f.text, allocator), .None
}

tree_list :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}) -> (names: []string, err: Error) {
	h := _handle_get(e, o, .File_Tree) or_return
	_hist_ready(e, h) or_return
	_hist_catch_up(e, h)
	snap := fstree.current(&h.hist.tree)
	dir := fstree.ROOT
	if len(path) > 0 && path != "/" {
		id, ok, lerr := fstree.lookup(&snap, path)
		if lerr != nil {
			return nil, .Corrupt
		}
		if !ok {
			return nil, .Not_Found
		}
		dir = id
	}
	kids, cerr := fstree.children(&snap, dir, nil, 0, context.temp_allocator)
	if cerr != nil {
		return nil, .Corrupt
	}
	out := make([]string, len(kids), allocator)
	for k, i in kids {
		out[i] = _clone(k.name, allocator) or_return
	}
	return out, .None
}

tree_write :: proc(e: ^Engine, o: Object, path: string, data: []u8) -> Error {
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	snap := fstree.current(&h.hist.tree)
	id, ok, lerr := fstree.lookup(&snap, path)
	if lerr != nil {
		return .Corrupt
	}
	if !ok {
		parent := fstree.ROOT
		name := path
		for i := len(path) - 1; i >= 0; i -= 1 {
			if path[i] == '/' {
				pid, pok, perr := fstree.lookup(&snap, path[:i])
				if perr != nil {
					return .Corrupt
				}
				if !pok {
					return .Not_Found
				}
				parent = pid
				name = path[i + 1:]
				break
			}
		}
		_hist_tree_op(e, h, fstree.Op_Create{parent = parent, name = name, kind = .File}, string(data)) or_return
		_handle_mark(h)
		return .None
	}
	f := _ferr2(fs.history_file(h.hist, id)) or_return
	cur := crdt.text_len(&f.text)
	_hist_text_edit(e, h, id, 0, cur, string(data)) or_return
	_handle_mark(h)
	return .None
}

tree_remove :: proc(e: ^Engine, o: Object, path: string) -> Error {
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	snap := fstree.current(&h.hist.tree)
	id, ok, lerr := fstree.lookup(&snap, path)
	if lerr != nil {
		return .Corrupt
	}
	if !ok {
		return .Not_Found
	}
	_hist_tree_op(e, h, fstree.Op_Remove{inode = id}, "") or_return
	_handle_mark(h)
	return .None
}

tree_history :: proc(e: ^Engine, o: Object) -> (hist: ^fs.History, err: Error) {
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	h.pins += 1
	_handle_mark(h)
	return h.hist, .None
}

tree_release :: proc(e: ^Engine, o: Object) {
	if h, ok := e.handles[o.id]; ok {
		_handle_mark(h)
		if h.pins > 0 {
			h.pins -= 1
		}
	}
}

device_odb :: proc(e: ^Engine) -> (db: ^odb.Odb, err: Error) {
	if !e.db_open {
		dir := _join(context.temp_allocator, e.dir, "objects") or_return
		_perr(prim.mkdir_all(e.base, dir, 0o700)) or_return
		if oerr := odb.open_store(&e.db, e.base, dir, nil, .Sha1, e.allocator); oerr != .None {
			return nil, _derr(oerr)
		}
		e.db_open = true
	}
	return &e.db, .None
}

@(private)
odb_barrier :: proc(e: ^Engine) -> odb.Error {
	return odb.barrier(&e.db)
}

@(private)
_derr :: proc "contextless" (err: odb.Error) -> Error {
	return _ferr(fs.from_odb(err))
}

@(private)
_ferr2 :: proc(v: $T, err: fs.Error) -> (T, Error) {
	return v, _ferr(err)
}

@(private)
_hist_open :: proc(h: ^Handle) -> Error {
	if h.hist != nil {
		return .None
	}
	e := h.e
	dir := _obj_dir(e, h.id) or_return
	hdir := _join(context.temp_allocator, dir, "hist") or_return
	db := device_odb(e) or_return
	hist := new(fs.History, e.allocator)
	src := fs.Stream_Source{data = h, read = _hist_read}
	if err := fs.history_open(hist, e.vfs, hdir, h.id, e.self, db, src, e.allocator); err != .None {
		free(hist, e.allocator)
		return _ferr(err)
	}
	h.hist = hist
	return .None
}

@(private)
_hist_ready :: proc(e: ^Engine, h: ^Handle) -> Error {
	if h.hist == nil {
		_hist_open(h) or_return
	}
	if !h.hist.awake {
		_ferr(fs.history_wake(h.hist)) or_return
	}
	return .None
}

@(private)
_hist_read :: proc(data: rawptr, stream: prim.Id, off: i64, out: ^[dynamic]u8) -> bool {
	h := (^Handle)(data)
	for s in h.segs {
		if s.device != stream || !s.in_view {
			continue
		}
		body, _, err := journal.record_at(&s.jr, off)
		if err != .None {
			return false
		}
		clear(out)
		append(out, ..body)
		return true
	}
	return false
}

@(private)
_text_inode :: proc(h: ^Handle) -> (id: fstree.Inode_Id, found: bool, err: Error) {
	snap := fstree.current(&h.hist.tree)
	i, ok, lerr := fstree.lookup(&snap, TEXT_NAME)
	if lerr != nil {
		return {}, false, .Corrupt
	}
	return i, ok, .None
}

@(private)
_hist_batch :: proc(e: ^Engine, h: ^Handle, ops: []crdt.Op_Run) -> Error {
	hist := h.hist
	heads := fs.history_heads(hist, context.temp_allocator)
	b := crdt.Batch {
		actor   = e.self,
		seq     = fs.history_next_seq(hist, e.self),
		lamport = fs.history_lamport_after(hist, heads),
		parents = heads,
		ops     = ops,
	}
	_, err := fs.history_commit_local(hist, &b)
	return _ferr(err)
}

@(private)
_hist_tree_op :: proc(e: ^Engine, h: ^Handle, op: fstree.Op, content: string) -> Error {
	_hist_ready(e, h) or_return
	hist := h.hist
	seq := fs.history_next_seq(hist, e.self)
	buf := make([dynamic]u8, context.temp_allocator)
	fs.encode_tree_op(hist, &buf, op, fs.Local_Actor{ix = fs.history_actor_ix(hist, e.self), actor = e.self, on = true})
	ops := make([dynamic]crdt.Op_Run, context.temp_allocator)
	append(&ops, crdt.Op_Run{kind = .Opaque, len = 1, content = buf[:]})
	if len(content) > 0 {
		if _, is_create := op.(fstree.Op_Create); is_create {
			c := make([]u8, len(content), context.temp_allocator)
			copy(c, content)
			append(&ops, crdt.Op_Run{target = crdt.Op_Id{e.self, seq}, kind = .Insert, pos = 0, len = len(c), content = c})
		}
	}
	return _hist_batch(e, h, ops[:])
}

@(private)
_hist_text_edit :: proc(e: ^Engine, h: ^Handle, inode: fstree.Inode_Id, pos: int, remove: int, insert: string) -> Error {
	hist := h.hist
	f := _ferr2(fs.history_file(hist, inode)) or_return
	n := crdt.text_len(&f.text)
	if pos < 0 || remove < 0 || pos > n || pos + remove > n {
		return .Invalid
	}
	target := fs.inode_op(hist, inode)
	ops := make([dynamic]crdt.Op_Run, context.temp_allocator)
	if remove > 0 {
		append(&ops, crdt.Op_Run{target = target, kind = .Delete, pos = pos, len = remove})
	}
	if len(insert) > 0 {
		c := make([]u8, len(insert), context.temp_allocator)
		copy(c, insert)
		append(&ops, crdt.Op_Run{target = target, kind = .Insert, pos = pos, len = len(c), content = c})
	}
	if len(ops) == 0 {
		return .None
	}
	return _hist_batch(e, h, ops[:])
}

@(private)
_text_edit :: proc(e: ^Engine, h: ^Handle, pos: int, remove: int, insert: string) -> Error {
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	inode, found := _text_inode(h) or_return
	if !found {
		return .Missing
	}
	return _hist_text_edit(e, h, inode, pos, remove, insert)
}

@(private)
_hist_catch_up :: proc(e: ^Engine, h: ^Handle) {
	if h.kind != .Text && h.kind != .File_Tree {
		return
	}
	if _hist_ready(e, h) != .None {
		return
	}
	_handle_refresh(h)
	hist := h.hist
	for s in h.segs {
		_follow(e, h, s, true)
	}
	for {
		progress := false
		for s in h.segs {
			if !s.in_view {
				continue
			}
			applied: i64
			for id, i in hist.stream_ids {
				if id == s.device && i < len(hist.applied) {
					applied = hist.applied[i]
				}
			}
			pos: i64
			if applied > 0 {
				_, next, rerr := journal.record_at(&s.jr, applied - 1)
				if rerr != .None && rerr != .Redacted {
					continue
				}
				pos = next
			}
			end := journal.reader_end(&s.jr)
			for pos < end {
				body, next, rerr := journal.record_at(&s.jr, pos)
				if rerr == .Redacted {
					pos = next
					continue
				}
				if rerr == .Missing {
					r := [1]journal.Range{{pos, end}}
					if h.sp.repl_on {
						osync.replicator_want(&h.sp.repl, &h.scope, s.device, h.name, 0, r[:])
					}
					break
				}
				if rerr != .None {
					break
				}
				_, aerr := fs.history_admit(hist, s.device, pos, body)
				if aerr == .Not_Found {
					break
				}
				if aerr != .None {
					_log(e, .Warn, "history admit failed")
					break
				}
				progress = true
				pos = next
			}
		}
		if !progress {
			break
		}
	}
}

package engine

import "base:runtime"
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
	context = context_for(e)
	o = Object{space, new_id(e)}
	h := _handle_get(e, o, .Text) or_return
	_handle_create_writer(h) or_return
	_hist_tree_op(e, h, fstree.Op_Create{parent = fstree.ROOT, name = TEXT_NAME, kind = .File}, initial) or_return
	_handle_mark(h)
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

tree_create :: proc(e: ^Engine, space: prim.Id, title := "") -> (o: Object, err: Error) {
	context = context_for(e)
	o = Object{space, new_id(e)}
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_handle_mark(h)
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

text_read :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (data: []u8, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Text) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	_hist_catch_up(e, h)
	inode, found := _text_inode(h) or_return
	if !found {
		return nil, _pending_result(e, h, .Missing, ready)
	}
	f := _ferr2(fs.history_file(h.hist, inode)) or_return
	return crdt.text_bytes(&f.text, allocator), .None
}

text_spans :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (spans: []crdt.Author_Span, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Text) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	_hist_catch_up(e, h)
	inode, found := _text_inode(h) or_return
	if !found {
		return nil, _pending_result(e, h, .Missing, ready)
	}
	f := _ferr2(fs.history_file(h.hist, inode)) or_return
	out := crdt.text_spans(&f.text, &h.hist.g, allocator)
	fs.history_present_spans(h.hist, out)
	return out, .None
}

tree_read :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}) -> (data: []u8, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
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
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
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
	context = context_for(e)
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
	context = context_for(e)
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
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	h.pins += 1
	_handle_mark(h)
	return h.hist, .None
}

tree_release :: proc(e: ^Engine, o: Object) {
	context = context_for(e)
	if h, ok := e.handles[o.id]; ok {
		_handle_mark(h)
		if h.pins > 0 {
			h.pins -= 1
		}
	}
}

device_odb :: proc(e: ^Engine) -> (db: ^odb.Odb, err: Error) {
	context = context_for(e)
	if !e.db_open {
		dir := _join(context.temp_allocator, e.dir, "objects") or_return
		_perr(prim.mkdir_all(e.base, dir, 0o700)) or_return
		if oerr := odb.open_store(&e.db, e.base, dir, nil, .Sha1, e.allocator, e.cfg.clock, e.cfg.random); oerr != .None {
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
	for mt in e.plug.mounts {
		if mt.object.id != h.id || mt.mount.history == nil {
			continue
		}
		hist := mt.mount.history
		if h.own_tree == nil {
			if t, terr := _own_tree_get(e, h.sp, h.id, h.kind, &h.scope, false); terr == .None {
				h.own_tree = t
			}
		}
		fs.history_retain(hist)
		h.hist = hist
		h.hist_chain = h.own_tree != nil
		for x in e.plug.mounts {
			if x.object.id == h.id {
				h.pins += 1
			}
		}
		return _ferr(fs.history_rebind(hist, fs.Stream_Source{data = h, read = _hist_read}, _hist_options(h)))
	}
	if _ckpt_waiting(h) || _ckpt_fetch_start(e, h) {
		return .Missing
	}
	dir := _obj_dir(e, h.id) or_return
	hdir := _join(context.temp_allocator, dir, "hist") or_return
	db := device_odb(e) or_return
	src := fs.Stream_Source{data = h, read = _hist_read}
	if h.own_tree == nil {
		if t, terr := _own_tree_get(e, h.sp, h.id, h.kind, &h.scope, false); terr == .None {
			h.own_tree = t
		}
	}
	hist, err := fs.history_create(e.vfs, hdir, h.id, e.self, db, src, e.allocator, _hist_options(h))
	if err != .None {
		return _ferr(err)
	}
	h.hist = hist
	h.hist_chain = h.own_tree != nil
	return .None
}

@(private)
_hist_options :: proc(h: ^Handle) -> fs.History_Options {
	e := h.e
	o := fs.History_Options{clock = _fs_clock(e), random = e.cfg.random}
	if h.sp.repl_on {
		o.keep_at_least, _ = osync.replicator_floor(&h.sp.repl, &h.scope, h.name, 0)
	}
	if h.own_tree != nil {
		o.chain = journal.Chain {
			seed   = osync.chain_seed(osync.stream_id(&h.scope, e.self, h.name, 0)),
			keys   = osync.keytree_provider(&h.own_tree.tree),
			signer = osync.keyring_signer(&e.keyring),
		}
		h.own_tree.refs += 1
		o.hold = fs.Hold{data = h.own_tree, drop = _own_tree_drop}
	}
	return o
}

@(private)
_own_tree_drop :: proc(data: rawptr) {
	t := (^Own_Tree)(data)
	if t.refs > 0 {
		t.refs -= 1
	}
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
		if err == .Redacted {
			synth, st := _hist_replacement(h, s, off)
			if st != .Found {
				return false
			}
			clear(out)
			append(out, ..synth)
			return true
		}
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
	if _, err := fs.history_commit_local(hist, &b); err != .None {
		return _ferr(err)
	}
	if h.kind == .File_Tree {
		n := crdt.batch_len(&b)
		head := [1]crdt.Op_Id{{e.self, b.seq + u64(n) - 1}}
		_ferr(fs.history_set_line(hist, fs.DEFAULT_MOUNT.line, head[:])) or_return
		_mounts_wake(e, h.id)
	}
	return .None
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
	positions := make(map[prim.Id]i64, 8, context.temp_allocator)
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
		positions[s.device] = pos
	}
	for {
		progress := false
		for s in h.segs {
			pos, ok := positions[s.device]
			if !ok {
				continue
			}
			end := journal.reader_end(&s.jr)
			for pos < end {
				body, next, rerr := journal.record_at(&s.jr, pos)
				if rerr == .Redacted {
					if _hist_admit_redacted(e, h, s, pos) == .Not_Found {
						break
					}
					pos = next
					progress = true
					continue
				}
				if rerr == .Missing {
					r := [1]journal.Range{s.jr.missing}
					if h.sp.repl_on {
						osync.replicator_want(&h.sp.repl, &h.scope, s.device, h.name, 0, r[:])
					}
					break
				}
				if rerr != .None {
					break
				}
				if journal.is_sig(body) {
					pos = next
					progress = true
					continue
				}
				owned := make([]u8, len(body), context.temp_allocator)
				copy(owned, body)
				if _content_missing(e, h, s.device, owned) {
					break
				}
				_, aerr := fs.history_admit(hist, s.device, pos, owned)
				if aerr == .None && len(owned) > 0 && owned[0] == fs.REC_REDACT {
					_hist_redact_own(e, h, owned)
				}
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
			positions[s.device] = pos
		}
		if !progress {
			break
		}
	}
	if rerr := fs.history_resume(hist); rerr != .None {
		_log(e, .Warn, "history replay failed")
	}
}

@(private)
_hist_redact_own :: proc(e: ^Engine, h: ^Handle, body: []u8) {
	rd := prim.reader(body[1:])
	n := prim.read_uvarint(&rd)
	if n > u64(len(body)) {
		return
	}
	own := make([dynamic]crdt.Op_Span, context.temp_allocator)
	for _ in 0 ..< n {
		a := prim.read_id(&rd)
		seq := prim.read_uvarint(&rd)
		l := prim.read_uvarint(&rd)
		if !prim.reader_ok(&rd) || l == 0 || l > crdt.MAX_RUN {
			return
		}
		if a == e.self {
			append(&own, crdt.Op_Span{crdt.Op_Id{a, seq}, int(l)})
		}
	}
	if len(own) == 0 || !h.w_open {
		_index_purge_object(e, h)
		_index_item_add(e, h.sp.id, h.id, h.kind)
		return
	}
	ctx := Text_Plan{e = e, h = h}
	res, err := fs.history_redact(h.hist, own[:], context.temp_allocator, _text_plan(&ctx))
	if err != .None {
		_log(e, .Warn, "own history redaction failed")
		return
	}
	for r in res.ranges {
		_own_redacted(e, h, r.from, r.to)
	}
	_handle_mark(h)
	_index_purge_object(e, h)
	_index_item_add(e, h.sp.id, h.id, h.kind)
}

Tree_Conflict :: struct {
	path:   string,
	start:  int,
	end:    int,
	ours:   []crdt.Op_Span,
	theirs: []crdt.Op_Span,
}

tree_conflicts :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (out: []Tree_Conflict, err: Error) {
	context = context_for(e)
	return _conflicts(e, o, .File_Tree, allocator, ready)
}

text_conflicts :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (out: []Tree_Conflict, err: Error) {
	context = context_for(e)
	return _conflicts(e, o, .Text, allocator, ready)
}

@(private)
_conflicts :: proc(e: ^Engine, o: Object, kind: Kind, allocator: runtime.Allocator, ready: Ready) -> (out: []Tree_Conflict, err: Error) {
	h := _handle_get(e, o, kind) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	_hist_catch_up(e, h)
	list := make([dynamic]fs.Text_Conflict, context.temp_allocator)
	_ferr(fs.history_text_conflicts(h.hist, &list, allocator)) or_return
	snap := fstree.current(&h.hist.tree)
	out = make([]Tree_Conflict, len(list), allocator)
	for c, i in list {
		p, ok, perr := fstree.last_path(&snap, c.inode, context.temp_allocator)
		if perr == nil && ok {
			out[i].path = _clone(p, allocator) or_return
		}
		out[i].start = c.start
		out[i].end = c.end
		out[i].ours = c.ours
		out[i].theirs = c.theirs
		for &x in out[i].ours {
			if o, owned := fs.history_actor_owner(h.hist, x.id.actor); owned {
				x.id.actor = o
			}
		}
		for &x in out[i].theirs {
			if o, owned := fs.history_actor_owner(h.hist, x.id.actor); owned {
				x.id.actor = o
			}
		}
	}
	return out, .None
}

conflicts_clear :: proc(e: ^Engine, o: Object, kind: Kind) -> Error {
	context = context_for(e)
	if kind != .File_Tree && kind != .Text {
		return .Invalid
	}
	h := _handle_get(e, o, kind) or_return
	_hist_ready(e, h) or_return
	return _ferr(fs.history_text_conflicts_clear(h.hist))
}

package engine

import "base:runtime"
import "core:slice"
import "core:crypto/blake2b"
import "core:mem/virtual"
import "core:strings"
import "../crdt"
import "../fs"
import "../fshist"
import "../fstree"
import "../journal"
import "../odb"
import "../pack"
import "../prim"
import "../textdiff"
import osync "../sync"

@(private)
TEXT_NAME :: "text"

text_create :: proc(e: ^Engine, space: prim.Id, title := "", initial := "") -> (o: Object, err: Error) {
	context = context_for(e)
	o = Object{space, new_id(e)}
	h := _handle_get(e, o, .Text) or_return
	if err = _handle_create_writer(h); err != .None {
		h.create_err = err
		return
	}
	_hist_tree_op(e, h, fstree.Op_Create{parent = fstree.ROOT, name = TEXT_NAME, kind = .File}, initial) or_return
	_handle_mark(h)
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

tree_create :: proc(e: ^Engine, space: prim.Id, title := "") -> (o: Object, err: Error) {
	context = context_for(e)
	o = Object{space, new_id(e)}
	h := _handle_get(e, o, .File_Tree) or_return
	if err = _handle_create_writer(h); err != .None {
		h.create_err = err
		return
	}
	_handle_mark(h)
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

text_read :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (data: []u8, err: Error) {
	context = context_for(e)
	data, err = _text_read(e, o, allocator, ready)
	return data, _damage_read(e, o, err, ready)
}

@(private)
_text_read :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (data: []u8, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Text) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	blocked := _hist_catch_up(e, h) || _handle_waiting(h, ready.fresh)
	inode, found := _text_inode(h) or_return
	if !found {
		return nil, _pending_result(e, h, .Missing, ready)
	}
	f, ferr := _hist_file(e, h, inode)
	if ferr != .None {
		return nil, _pending_result(e, h, ferr, ready)
	}
	data = crdt.text_bytes(&f.text, allocator)
	if blocked && ready.call != nil {
		return data, _wait(e, h, ready)
	}
	return data, .None
}

text_spans :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (spans: []crdt.Author_Span, err: Error) {
	context = context_for(e)
	spans, err = _text_spans(e, o, allocator, ready)
	return spans, _damage_read(e, o, err, ready)
}

@(private)
_text_spans :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (spans: []crdt.Author_Span, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Text) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	blocked := _hist_catch_up(e, h) || _handle_waiting(h, ready.fresh)
	inode, found := _text_inode(h) or_return
	if !found {
		return nil, _pending_result(e, h, .Missing, ready)
	}
	f, ferr := _hist_file(e, h, inode)
	if ferr != .None {
		return nil, _pending_result(e, h, ferr, ready)
	}
	spans = crdt.text_spans(&f.text, &h.hist.g, allocator)
	fs.history_present_spans(h.hist, spans)
	if blocked && ready.call != nil {
		return spans, _wait(e, h, ready)
	}
	return spans, .None
}

tree_read :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}, line := "", version: []u8 = nil, base: ^fs.Version = nil) -> (data: []u8, err: Error) {
	context = context_for(e)
	data, err = _tree_read(e, o, path, allocator, ready, line, version, base)
	return data, _damage_read(e, o, err, ready)
}

@(private)
_tree_read :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}, line := "", version: []u8 = nil, base: ^fs.Version = nil) -> (data: []u8, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	blocked := _hist_catch_up(e, h) || _handle_waiting(h, ready.fresh)
	at, aerr := _tree_at(e, h, line, version)
	if aerr != .None {
		return nil, aerr
	}
	if base != nil {
		base^ = slice.clone(at.version, allocator) or_else nil
	}
	id, ok, lerr := fstree.lookup(&at.snap, path)
	if lerr != nil {
		return nil, .Corrupt
	}
	if !ok {
		if blocked && ready.call != nil {
			return nil, _wait(e, h, ready)
		}
		return nil, .Not_Found
	}
	if info, iok, ierr := fstree.info(&at.snap, id, context.temp_allocator); ierr == nil && iok && info.kind == .Dir {
		return nil, .Invalid
	}
	text, ferr := _tree_text(e, h, &at, id)
	if ferr != .None {
		return nil, _pending_result(e, h, ferr, ready)
	}
	data = _clone_bytes(text, allocator) or_return
	if blocked && ready.call != nil {
		return data, _wait(e, h, ready)
	}
	return data, .None
}

Tree_Entry :: struct {
	name: string,
	kind: fstree.Kind,
	size: i64,
	mode: u32,
}

tree_list :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}, line := "", version: []u8 = nil) -> (names: []string, err: Error) {
	context = context_for(e)
	entries, lerr := _tree_entries(e, o, path, context.temp_allocator, ready, line, version, false)
	out := make([]string, len(entries), allocator)
	for x, i in entries {
		out[i] = _clone(x.name, allocator) or_return
	}
	return out, _damage_read(e, o, lerr, ready)
}

tree_entries :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, ready: Ready = {}, line := "", version: []u8 = nil, base: ^fs.Version = nil) -> (entries: []Tree_Entry, err: Error) {
	context = context_for(e)
	entries, err = _tree_entries(e, o, path, allocator, ready, line, version, true, base)
	return entries, _damage_read(e, o, err, ready)
}

@(private)
_tree_entries :: proc(e: ^Engine, o: Object, path: string, allocator: runtime.Allocator, ready: Ready, line: string, version: []u8, sizes: bool, base: ^fs.Version = nil) -> (entries: []Tree_Entry, err: Error) {
	h := _handle_get(e, o, .File_Tree) or_return
	if rerr := _hist_ready(e, h); rerr != .None {
		return nil, _pending_result(e, h, rerr, ready)
	}
	blocked := _hist_catch_up(e, h) || _handle_waiting(h, ready.fresh)
	at, aerr := _tree_at(e, h, line, version)
	if aerr != .None {
		return nil, aerr
	}
	if base != nil {
		base^ = slice.clone(at.version, allocator) or_else nil
	}
	dir := fstree.ROOT
	if len(path) > 0 && path != "/" {
		id, ok, lerr := fstree.lookup(&at.snap, path)
		if lerr != nil {
			return nil, .Corrupt
		}
		if !ok {
			if blocked && ready.call != nil {
				return nil, _wait(e, h, ready)
			}
			return nil, .Not_Found
		}
		if info, iok, ierr := fstree.info(&at.snap, id, context.temp_allocator); ierr == nil && iok && info.kind != .Dir {
			return nil, .Invalid
		}
		dir = id
	}
	kids, cerr := fstree.children(&at.snap, dir, nil, 0, context.temp_allocator)
	if cerr != nil {
		return nil, .Corrupt
	}
	out := make([]Tree_Entry, len(kids), allocator)
	for k, i in kids {
		x := Tree_Entry{kind = k.kind}
		x.name = _clone(k.name, allocator) or_return
		info, iok, ierr := fstree.info(&at.snap, k.inode, context.temp_allocator)
		if ierr != nil {
			return nil, .Corrupt
		}
		switch k.kind {
		case .Dir:
			x.mode = 0o755
		case .Symlink:
			x.mode = 0o777
			if iok {
				x.size = i64(len(info.target))
			}
		case .File:
			x.mode = 0o755 if iok && .Exec in info.flags else 0o644
			if sizes {
				text, terr := _tree_text(e, h, &at, k.inode)
				if terr != .None {
					return nil, _pending_result(e, h, terr, ready)
				}
				x.size = i64(len(text))
			}
		}
		out[i] = x
	}
	if blocked && ready.call != nil {
		return out, _wait(e, h, ready)
	}
	return out, .None
}

@(private)
_tree_dirs :: proc(e: ^Engine, h: ^Handle, at: ^Tree_At, dir: string) -> (id: fstree.Inode_Id, err: Error) {
	id = fstree.ROOT
	start := 0
	for i in 0 ..= len(dir) {
		if i < len(dir) && dir[i] != '/' {
			continue
		}
		part := dir[start:i]
		start = i + 1
		if len(part) == 0 || part == "." {
			continue
		}
		if part == ".." {
			return id, .Invalid
		}
		next, found, lerr := fstree.lookup_child(&at.snap, id, part)
		if lerr != nil {
			return id, .Corrupt
		}
		if !found {
			_hist_tree_op(e, h, fstree.Op_Create{parent = id, name = part, kind = .Dir}, "", at) or_return
			next, found, lerr = fstree.lookup_child(&at.snap, id, part)
			if lerr != nil || !found {
				return id, .Corrupt
			}
		}
		n, gerr := fstree.get(&h.hist.tree, next)
		if gerr != nil || n == nil {
			return id, .Corrupt
		}
		if n.kind != .Dir {
			return id, .Invalid
		}
		id = next
	}
	return id, .None
}

tree_write :: proc(e: ^Engine, o: Object, path: string, data: []u8, base: fs.Version, line := "") -> Error {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	at := _tree_at(e, h, line, nil) or_return
	hist := h.hist
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&hist.g, base, &bl) != .None {
		return .Invalid
	}
	bsnap := _ferr2(fs.version_snapshot(hist, bl[:])) or_return
	bat := Tree_At{line = at.line, version = base, snap = bsnap}
	defer fstree.snapshot_destroy(&bat.snap)
	id, ok, lerr := fstree.lookup(&bat.snap, path)
	if lerr != nil {
		return .Corrupt
	}
	if info, iok, ierr := fstree.info(&bat.snap, id, context.temp_allocator); ok && ierr == nil && iok && info.kind != .File {
		return .Invalid
	}
	if !ok {
		parent := fstree.ROOT
		name := path
		for i := len(path) - 1; i >= 0; i -= 1 {
			if path[i] == '/' {
				parent = _tree_dirs(e, h, &at, path[:i]) or_return
				name = path[i + 1:]
				break
			}
		}
		if len(name) == 0 || name == "." || name == ".." {
			return .Invalid
		}
		_hist_tree_op(e, h, fstree.Op_Create{parent = parent, name = name, kind = .File}, string(data), &at) or_return
		_handle_mark(h)
		return .None
	}
	old := _ferr2(fs.history_text_at(hist, id, base, context.temp_allocator)) or_return
	target := fs.inode_op(hist, id)
	edits, derr := textdiff.line_edits(old, data, context.temp_allocator)
	if derr != nil {
		ops := make([dynamic]crdt.Op_Run, context.temp_allocator)
		if len(old) > 0 {
			append(&ops, crdt.Op_Run{target = target, kind = .Delete, pos = 0, len = len(old)})
		}
		if len(data) > 0 {
			append(&ops, crdt.Op_Run{target = target, kind = .Insert, pos = 0, len = len(data), content = data})
		}
		if len(ops) > 0 {
			_hist_batch(e, h, ops[:], &bat) or_return
		}
		_handle_mark(h)
		return .None
	}
	if len(edits) == 0 {
		return .None
	}
	ops := make([dynamic]crdt.Op_Run, 0, 2 * len(edits), context.temp_allocator)
	for ed in edits {
		at := int(ed.pos)
		if ed.del > 0 {
			append(&ops, crdt.Op_Run{target = target, kind = .Delete, pos = at, len = int(ed.del)})
		}
		if ed.ins > 0 {
			append(&ops, crdt.Op_Run{target = target, kind = .Insert, pos = at, len = int(ed.ins), content = data[at:at + int(ed.ins)]})
		}
	}
	_hist_batch(e, h, ops[:], &bat) or_return
	_handle_mark(h)
	return .None
}

tree_remove :: proc(e: ^Engine, o: Object, path: string, line := "") -> Error {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	at := _tree_at(e, h, line, nil) or_return
	id, ok, lerr := fstree.lookup(&at.snap, path)
	if lerr != nil {
		return .Corrupt
	}
	if !ok {
		return .Not_Found
	}
	_hist_tree_op(e, h, fstree.Op_Remove{inode = id}, "", &at) or_return
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
		odb.sweep_temps(&e.db)
		e.db.deferred = true
		e.db.scrub_hook = odb.Scrub_Hook{data = e, call = _serve_scrubbed}
		e.db_open = true
		if odb.scrub_pending(&e.db) {
			if left, lerr := odb.scrub_targets(&e.db, context.temp_allocator); lerr == .None {
				_serve_drop_oids(e, left)
			}
			rstats, serr := odb.scrub_resume(&e.db, context.temp_allocator)
			_redact_report(e, {}, {}, rstats.unreached)
			if serr != .None {
				_log(e, .Warn, "a pending object scrub did not finish; it stays for the next open")
			}
		}
	}
	return &e.db, .None
}

@(private)
_odb_queue_pending :: proc(e: ^Engine) -> bool {
	b, terr := odb.install_take(&e.db)
	if terr != .None {
		return false
	}
	if b != nil {
		pack.queue_install(&e.pk, pack.Install_Hook{run = _odb_install_run, done = _odb_install_done, data = b})
	}
	return true
}

@(private)
_odb_install_run :: proc(data: rawptr) -> (nsync: u64, err: pack.Error) {
	b := (^odb.Install)(data)
	ierr := odb.install_run(b)
	return b.nsync, .None if ierr == .None else .Io
}

@(private)
_odb_install_done :: proc(data: rawptr, ok: bool) {
	odb.install_done((^odb.Install)(data), ok)
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
_hist_file :: proc(e: ^Engine, h: ^Handle, inode: fstree.Inode_Id) -> (f: ^fs.File_State, err: Error) {
	ff, ferr := fs.history_file(h.hist, inode)
	if ferr == .Not_Found {
		_hist_fetch_full(e, h)
		return nil, .Missing
	}
	return ff, _ferr(ferr)
}

@(private)
_hist_fetch_full :: proc(e: ^Engine, h: ^Handle) {
	if !h.sp.repl_on {
		return
	}
	for sg in h.segs {
		osync.replicator_follow(&h.sp.repl, &h.scope, sg.device, h.name, 0, true)
	}
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
		hist.on_offered = _on_offered
		hist.offered_data = h
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
	hist.on_offered = _on_offered
	hist.offered_data = h
	h.hist_chain = h.own_tree != nil
	return .None
}

@(private)
_on_offered :: proc(data: rawptr, hist: ^fs.History, dest: fstree.Inode_Id, source: fstree.Inode_Id) {
	h := (^Handle)(data)
	e := h.e
	if e == nil || h.sp == nil {
		return
	}
	snap := fstree.current(&hist.tree)
	from, _, _ := fstree.last_path(&snap, source, context.temp_allocator)
	to, _, _ := fstree.last_path(&snap, dest, context.temp_allocator)
	detail := strings.concatenate({from, "\n", to}, context.temp_allocator)
	_emit(e, Event{kind = .Rename_Offered, space = h.sp.id, object = h.id, detail = detail})
}

@(private)
_hist_options :: proc(h: ^Handle) -> fs.History_Options {
	e := h.e
	o := fs.History_Options{clock = _fs_clock(e), random = e.cfg.random, fault = e.cfg.history_fault}
	o.redacted = fs.Redacted_Hook{data = h, call = _hist_redacted}
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
_hist_batch :: proc(e: ^Engine, h: ^Handle, ops: []crdt.Op_Run, at: ^Tree_At = nil) -> Error {
	hist := h.hist
	heads := at.version if at != nil else fs.history_heads(hist, context.temp_allocator)
	actor := _tree_actor(e, h, at) or_return
	b := crdt.Batch {
		actor   = actor,
		seq     = fs.history_next_seq(hist, actor),
		lamport = fs.history_lamport_after(hist, heads),
		parents = heads,
		ops     = ops,
	}
	if _, err := fs.history_commit_local(hist, &b); err != .None {
		return _ferr(err)
	}
	if h.kind == .File_Tree {
		n := crdt.batch_len(&b)
		lname := at.line if at != nil else fs.DEFAULT_MOUNT.line
		head := [1]crdt.Op_Id{{actor, b.seq + u64(n) - 1}}
		next := head[:]
		cur, found, lerr := fs.history_line(hist, lname, context.temp_allocator)
		if lerr != .None {
			return _ferr(lerr)
		}
		if found {
			cl := make([dynamic]crdt.Lv, context.temp_allocator)
			hl := make([dynamic]crdt.Lv, context.temp_allocator)
			if crdt.graph_version_lvs(&hist.g, cur, &cl) == .None && crdt.graph_version_lvs(&hist.g, head[:], &hl) == .None {
				both := make([dynamic]crdt.Lv, context.temp_allocator)
				crdt.version_union(&hist.g, cl[:], hl[:], &both)
				next = crdt.graph_version_ids(&hist.g, both[:], context.temp_allocator)
			}
		}
		_ferr(fs.history_set_line(hist, lname, next)) or_return
		_mounts_wake(e, h.id)
		if at != nil {
			at^ = _tree_at(e, h, at.line, nil) or_return
		}
	}
	return .None
}

@(private)
_hist_tree_op :: proc(e: ^Engine, h: ^Handle, op: fstree.Op, content: string, at: ^Tree_At = nil) -> Error {
	_hist_ready(e, h) or_return
	hist := h.hist
	actor := _tree_actor(e, h, at) or_return
	seq := fs.history_next_seq(hist, actor)
	buf := make([dynamic]u8, context.temp_allocator)
	fs.encode_tree_op(hist, &buf, op, fs.Local_Actor{ix = fs.history_actor_ix(hist, actor), actor = actor, on = true})
	ops := make([dynamic]crdt.Op_Run, context.temp_allocator)
	append(&ops, crdt.Op_Run{kind = .Opaque, len = 1, content = buf[:]})
	if len(content) > 0 {
		if _, is_create := op.(fstree.Op_Create); is_create {
			c := make([]u8, len(content), context.temp_allocator)
			copy(c, content)
			append(&ops, crdt.Op_Run{target = crdt.Op_Id{actor, seq}, kind = .Insert, pos = 0, len = len(c), content = c})
		}
	}
	return _hist_batch(e, h, ops[:], at)
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
CATCH_UP_LAZY :: 32

@(private)
_hist_catch_up :: proc(e: ^Engine, h: ^Handle) -> (blocked: bool) {
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
	rec: virtual.Arena
	defer virtual.arena_destroy(&rec)
	admitted := 0
	for {
		progress := false
		for s in h.segs {
			pos, ok := positions[s.device]
			if !ok {
				continue
			}
			end := journal.reader_end(&s.jr)
			for pos < end {
				virtual.arena_free_all(&rec)
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
					blocked = true
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
				owned := make([]u8, len(body), virtual.arena_allocator(&rec))
				copy(owned, body)
				if _content_missing(e, h, s.device, owned) {
					blocked = true
					break
				}
				admitted += 1
				if admitted == CATCH_UP_LAZY {
					fs.history_unload_unviewed(hist)
				}
				merge_scratch := virtual.arena_temp_begin(&e.temp)
				_, aerr := fs.history_admit(hist, s.device, pos, owned)
				virtual.arena_temp_end(merge_scratch)
				if aerr == .None && len(owned) > 0 && owned[0] == fs.REC_REDACT {
					_hist_redact_own(e, h, owned)
				}
				if aerr == .Not_Found {
					blocked = true
					break
				}
				if aerr != .None {
					if !_store_err(e, _ferr(aerr)) {
						_log(e, .Warn, "history admit failed")
					}
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
	if rerr := fs.history_resume(hist); rerr != .None && !_store_err(e, _ferr(rerr)) {
		_log(e, .Warn, "history replay failed")
	}
	return
}

@(private)
_hist_redacted :: proc(data: rawptr, list: []odb.Unreached) {
	h := (^Handle)(data)
	_ckpt_purge(h.e, h)
	_redact_report(h.e, h.sp.id, h.id, list)
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
		if a == e.self || fs.history_owns(h.hist, crdt.Op_Id{a, seq}) {
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
	for r in res.ranges {
		_own_redacted(e, h, r.from, r.to)
	}
	if err != .None {
		if !_store_err(e, _ferr(err)) {
			_log(e, .Warn, "own history redaction failed")
		}
		return
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
	kind:   fs.Conflict_Kind,
	source: string,
	raw:    fs.Text_Conflict,
}

tree_conflicts :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (out: []Tree_Conflict, err: Error) {
	context = context_for(e)
	out, err = _conflicts(e, o, .File_Tree, allocator, ready)
	return out, _damage_read(e, o, err, ready)
}

text_conflicts :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (out: []Tree_Conflict, err: Error) {
	context = context_for(e)
	out, err = _conflicts(e, o, .Text, allocator, ready)
	return out, _damage_read(e, o, err, ready)
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
	if kind == .File_Tree {
		view := _tree_at(e, h, "", nil) or_return
		version := view.version if !view.head else fs.history_heads(h.hist, context.temp_allocator)
		_ferr(fs.history_offers(h.hist, version, &view.snap, &list, allocator)) or_return
	}
	snap := fstree.current(&h.hist.tree)
	out = make([]Tree_Conflict, len(list), allocator)
	for c, i in list {
		p, ok, perr := fstree.last_path(&snap, c.inode, context.temp_allocator)
		if perr == nil && ok {
			out[i].path = _clone(p, allocator) or_return
		}
		out[i].start = c.start
		out[i].end = c.end
		ours, oerr := slice.clone(c.ours, allocator)
		theirs, terr := slice.clone(c.theirs, allocator)
		if oerr != nil || terr != nil {
			return nil, .No_Memory
		}
		out[i].ours = ours
		out[i].theirs = theirs
		out[i].kind = c.kind
		out[i].raw = c
		if c.kind == .Offered {
			if sp, sok, serr := fstree.last_path(&snap, c.source, context.temp_allocator); serr == nil && sok {
				out[i].source = _clone(sp, allocator) or_return
			}
		}
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

tree_conflict_accept :: proc(e: ^Engine, o: Object, c: Tree_Conflict) -> Error {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	at := _tree_at(e, h, "", nil) or_return
	ops := make([dynamic]crdt.Op_Run, context.temp_allocator)
	version := at.version if !at.head else fs.history_heads(h.hist, context.temp_allocator)
	_ferr(fs.conflict_accept_ops(h.hist, c.raw, version, &ops)) or_return
	if len(ops) == 0 {
		return .None
	}
	_hist_batch(e, h, ops[:], &at) or_return
	_handle_mark(h)
	return .None
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

@(private)
Tree_At :: struct {
	line:    string,
	version: fs.Version,
	head:    bool,
	snap:    fstree.Snapshot,
}

tree_line :: proc(e: ^Engine, o: Object, line := "") -> string {
	return _tree_line_id(e, o.id, line)
}

@(private)
_tree_line_id :: proc(e: ^Engine, id: prim.Id, line: string) -> string {
	if len(line) > 0 {
		return line
	}
	for mt in e.plug.mounts {
		if mt.object.id == id {
			return mt.mount.line
		}
	}
	return fs.DEFAULT_MOUNT.line
}

@(private)
_tree_at :: proc(e: ^Engine, h: ^Handle, line: string, version: []u8) -> (at: Tree_At, err: Error) {
	hist := h.hist
	at.line = _tree_line_id(e, h.id, line)
	if len(version) > 0 {
		rd := prim.reader(version)
		vb := prim.read_bytes(&rd)
		prim.read_str(&rd)
		prim.read_str(&rd)
		if !prim.reader_ok(&rd) {
			return at, .Invalid
		}
		v, derr := fs.decode_version(vb, context.temp_allocator)
		if derr != .None {
			return at, .Invalid
		}
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&hist.g, v, &lvs) != .None {
			return at, .Missing
		}
		at.version = v
		if crdt.frontier_eq(lvs[:], hist.g.heads[:]) {
			at.head = true
			at.snap = fstree.current(&hist.tree)
			return at, .None
		}
		at.snap = _ferr2(fs.version_snapshot(hist, lvs[:])) or_return
		return at, .None
	}
	v, found, lerr := fs.history_line(hist, at.line, context.temp_allocator)
	if lerr != .None {
		return at, _ferr(lerr)
	}
	if found {
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&hist.g, v, &lvs) == .None && !crdt.frontier_eq(lvs[:], hist.g.heads[:]) {
			at.version = v
			at.snap = _ferr2(fs.version_snapshot(hist, lvs[:])) or_return
			return at, .None
		}
	}
	at.head = true
	at.version = fs.history_heads(hist, context.temp_allocator)
	at.snap = fstree.current(&hist.tree)
	return at, .None
}

@(private)
_tree_text :: proc(e: ^Engine, h: ^Handle, at: ^Tree_At, inode: fstree.Inode_Id) -> (text: []u8, err: Error) {
	if at.head {
		f := _hist_file(e, h, inode) or_return
		return crdt.text_bytes(&f.text, context.temp_allocator), .None
	}
	view := _ferr2(fs.history_view_open(h.hist, inode, at.version)) or_return
	defer fs.history_view_close(h.hist, view)
	return crdt.text_bytes(&view.text, context.temp_allocator), .None
}

tree_blame :: proc(e: ^Engine, o: Object, path: string, allocator := context.allocator, line := "") -> (data: []u8, spans: []crdt.Author_Span, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .File_Tree) or_return
	_hist_ready(e, h) or_return
	_hist_catch_up(e, h)
	at := _tree_at(e, h, line, nil) or_return
	id, ok, lerr := fstree.lookup(&at.snap, path)
	if lerr != nil {
		return nil, nil, .Corrupt
	}
	if !ok {
		return nil, nil, .Not_Found
	}
	if at.head {
		f := _hist_file(e, h, id) or_return
		data = crdt.text_bytes(&f.text, allocator)
		spans = crdt.text_spans(&f.text, &h.hist.g, allocator)
	} else {
		view := _ferr2(fs.history_view_open(h.hist, id, at.version)) or_return
		defer fs.history_view_close(h.hist, view)
		data = crdt.text_bytes(&view.text, allocator)
		spans = crdt.text_spans(&view.text, &h.hist.g, allocator)
	}
	fs.history_present_spans(h.hist, spans)
	return data, spans, .None
}

@(private)
_tree_actor :: proc(e: ^Engine, h: ^Handle, at: ^Tree_At) -> (actor: prim.Id, err: Error) {
	if at == nil || at.line == fs.DEFAULT_MOUNT.line {
		return e.self, .None
	}
	mount := _line_mount_id(at.line)
	actor = fshist.ingestion_actor(e.self, mount)
	_ferr(fs.history_register_actor(h.hist, actor, mount)) or_return
	return actor, .None
}

@(private)
_line_mount_id :: proc(line: string) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb api line"
	blake2b.update(&ctx, transmute([]u8)tag)
	blake2b.update(&ctx, transmute([]u8)line)
	blake2b.final(&ctx, id[:])
	return
}

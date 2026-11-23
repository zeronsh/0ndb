package engine

import "core:crypto"
import "core:crypto/blake2b"
import "../fs"
import "../journal"
import omap "../map"
import "../odb"
import "../prim"
import osync "../sync"

@(private)
ROOT_CKPT :: 6
@(private)
CKPT_MIN_BYTES :: 256 * 1024
@(private)
CKPT_FS :: u8(1)
@(private)
CKPT_OBJECT :: u8(2)
@(private)
CKPT_REMOTE :: u8(3)
@(private)
CKPT_DOMAIN :: "0ndb checkpoint tree v1"

@(private)
Ckpt_Wait :: struct {
	object: prim.Id,
	kind:   Kind,
	name:   string,
	scope:  osync.Scope,
	tree:   osync.Key_Tree,
	dest:   string,
	need:   [dynamic]odb.Oid,
}

@(private)
Ckpt_Sink :: struct {
	e:    ^Engine,
	fd:   prim.Fd,
	pos:  i64,
	hash: blake2b.Context,
	err:  fs.Error,
	db:   ^odb.Odb,
	tr:   ^Tree_Reach,
}

@(private)
Ckpt_Source :: struct {
	e:   ^Engine,
	fd:  prim.Fd,
	pos: i64,
	end: i64,
	db:  ^odb.Odb,
}

@(private)
_ckpt_tree :: proc(scope: ^osync.Scope, id: prim.Id, t: ^osync.Key_Tree) -> Error {
	root: [32]u8
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, scope.object_key[:], 32)
	blake2b.update(&ctx, transmute([]u8)string(CKPT_DOMAIN))
	x := id
	blake2b.update(&ctx, x[:])
	blake2b.final(&ctx, root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return _serr(osync.keytree_init(t, root, osync.OBJECT_TREE_DEPTH, 0))
}

@(private)
_ckpt_get :: proc(e: ^Engine, id: prim.Id) -> (length: i64, oid: [32]u8, found: bool) {
	k := id
	v, hit, err := omap.db_get(&e.reg.db, ROOT_CKPT, k[:], context.temp_allocator)
	if err != .None || !hit || len(v) != 40 {
		return
	}
	copy(oid[:], v[8:])
	return i64(prim.get_u64le(v[:8])), oid, true
}

@(private)
_ckpt_put :: proc(e: ^Engine, id: prim.Id, length: i64, oid: [32]u8) {
	k := id
	v: [40]u8
	prim.put_u64le(v[:8], u64(length))
	o := oid
	copy(v[8:], o[:])
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	if omap.txn_put(t, ROOT_CKPT, k[:], v[:]) != .None {
		omap.txn_abort(t)
		_reg_fail(e, .Io)
		return
	}
	_reg_commit(e, t)
	e.reg.meta = true
}

@(private)
_ckpt_hook :: proc(e: ^Engine, h: ^Handle, stage: Checkpoint_Stage, oid: [32]u8) {
	if hk := e.cfg.checkpoint_hook; hk.at != nil {
		context = _outer(e)
		hk.at(hk.data, e, Object{space = h.sp.id, id = h.id}, stage, &h.scope, oid)
	}
}

checkpoint_tree :: proc(scope: ^osync.Scope, id: prim.Id, t: ^osync.Key_Tree) -> Error {
	return _ckpt_tree(scope, id, t)
}

@(private)
_ckpt_del :: proc(e: ^Engine, id: prim.Id) {
	k := id
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	if _, derr := omap.txn_delete(t, ROOT_CKPT, k[:]); derr != .None {
		omap.txn_abort(t)
		_reg_fail(e, .Io)
		return
	}
	_reg_commit(e, t)
	e.reg.meta = true
}

@(private)
_ckpt_purge :: proc(e: ^Engine, h: ^Handle) {
	dir, derr := _obj_dir(e, h.id)
	if derr != .None {
		return
	}
	if p, jerr := _join(context.temp_allocator, dir, "bundle.tmp"); jerr == .None {
		prim.remove(e.vfs, p)
	}
	if !_ckpt_waiting(h) {
		if p, jerr := _join(context.temp_allocator, dir, "bundle.in"); jerr == .None {
			prim.remove(e.vfs, p)
		}
	}
	_, oid, found := _ckpt_get(e, h.id)
	if !found {
		return
	}
	if oid != {} {
		ph := _oid_name(oid)
		if p, jerr := _join(context.temp_allocator, dir, string(ph[:])); jerr == .None {
			prim.remove(e.vfs, p)
		}
		if h.sp.repl_on {
			tree: osync.Key_Tree
			if _ckpt_tree(&h.scope, h.id, &tree) == .None {
				o := oid
				osync.replicator_shred_object(&h.sp.repl, &h.scope, &tree, o[:])
				osync.keytree_destroy(&tree)
			}
		}
	}
	_ckpt_del(e, h.id)
}

@(private)
_checkpoints_write :: proc(e: ^Engine) {
	for h in e.lru {
		if (h.kind != .Text && h.kind != .File_Tree) || !h.w_open || h.hist == nil || !h.hist.awake || !h.sp.repl_on || !h.sp.connected {
			continue
		}
		n := _own_len(h)
		last, prev, had := _ckpt_get(e, h.id)
		if n - max(last, 0) < CKPT_MIN_BYTES {
			continue
		}
		if _storage_class(e, h.sp, h.id, h.kind) == .Device {
			continue
		}
		if err := _checkpoint_write(e, h, n, prev, had); err != .None {
			_log(e, .Warn, "checkpoint write failed")
		}
	}
}

@(private)
_checkpoint_write :: proc(e: ^Engine, h: ^Handle, length: i64, prev: [32]u8, had_prev: bool) -> Error {
	_hist_ready(e, h) or_return
	dir := _obj_dir(e, h.id) or_return
	tmp := _join(context.temp_allocator, dir, "bundle.tmp") or_return
	fd, oerr := prim.open_file(e.vfs, tmp, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	gen := fs.history_redactions(h.hist)
	tr := _tree_reach(e, h)
	sink := Ckpt_Sink{e = e, fd = fd, db = h.hist.db}
	if tr.ok {
		sink.tr = &tr
	}
	blake2b.init(&sink.hash, 32)
	werr := fs.history_persist(h.hist)
	if werr == .None {
		werr = fs.history_bundle_objects(h.hist, &sink, _ckpt_sink_object)
	}
	if werr == .None {
		werr = sink.err
	}
	if werr == .None {
		werr = fs.history_bundle_write(h.hist, fs.Bundle_Sink{data = &sink, write = _ckpt_sink_fs})
	}
	oid: [32]u8
	blake2b.final(&sink.hash, oid[:])
	prim.close_file(e.vfs, fd)
	if werr != .None {
		prim.remove(e.vfs, tmp)
		return _ferr(werr)
	}
	_ckpt_hook(e, h, .Bundled, oid)
	if fs.history_redactions(h.hist) != gen {
		prim.remove(e.vfs, tmp)
		return .None
	}
	hx := _oid_name(oid)
	final := _join(context.temp_allocator, dir, string(hx[:])) or_return
	_perr(prim.rename(e.vfs, tmp, final)) or_return
	_ckpt_hook(e, h, .Installed, oid)
	if fs.history_redactions(h.hist) != gen {
		prim.remove(e.vfs, final)
		return .None
	}
	tree: osync.Key_Tree
	_ckpt_tree(&h.scope, h.id, &tree) or_return
	defer osync.keytree_destroy(&tree)
	meta: [8]u8
	prim.put_u64le(meta[:], u64(length))
	perr := osync.replicator_publish_checkpoint(&h.sp.repl, &h.scope, &tree, h.name, u64(hlc_now(e)), oid[:], meta[:], nil, final)
	if perr != .None {
		prim.remove(e.vfs, final)
		return _serr(perr)
	}
	_ckpt_hook(e, h, .Published, oid)
	if had_prev && prev != oid && prev != {} {
		p := prev
		osync.replicator_shred_object(&h.sp.repl, &h.scope, &tree, p[:])
		ph := _oid_name(p)
		if old, jerr := _join(context.temp_allocator, dir, string(ph[:])); jerr == .None {
			prim.remove(e.vfs, old)
		}
	}
	_ckpt_put(e, h.id, length, oid)
	return .None
}

@(private)
_ckpt_emit :: proc(s: ^Ckpt_Sink, tag: u8, payload: []u8) -> fs.Error {
	if s.err != .None {
		return s.err
	}
	head: [5]u8
	head[0] = tag
	prim.put_u32le(head[1:], u32(len(payload)))
	blake2b.update(&s.hash, head[:])
	blake2b.update(&s.hash, payload)
	if err := prim.write_at(s.e.vfs, s.fd, head[:], s.pos); err != .None {
		s.err = fs.from_prim(err)
		return s.err
	}
	s.pos += 5
	if err := prim.write_at(s.e.vfs, s.fd, payload, s.pos); err != .None {
		s.err = fs.from_prim(err)
		return s.err
	}
	s.pos += i64(len(payload))
	return .None
}

@(private)
_ckpt_sink_fs :: proc(data: rawptr, frame: []u8) -> fs.Error {
	return _ckpt_emit((^Ckpt_Sink)(data), CKPT_FS, frame)
}

@(private)
_ckpt_sink_object :: proc(data: rawptr, oid: odb.Oid) {
	s := (^Ckpt_Sink)(data)
	if s.err != .None || s.db == nil {
		return
	}
	if s.tr != nil && fs.remote_reach_has(&s.tr.reach, oid) {
		o := oid
		_ckpt_emit(s, CKPT_REMOTE, o[:odb.oid_size(s.db.format)])
		return
	}
	t, body, err := odb.read(s.db, oid, context.temp_allocator)
	if err != .None {
		return
	}
	buf := make([]u8, 1 + len(body), context.temp_allocator)
	buf[0] = u8(t)
	copy(buf[1:], body)
	_ckpt_emit(s, CKPT_OBJECT, buf)
}

@(private)
_ckpt_fetch_start :: proc(e: ^Engine, h: ^Handle) -> bool {
	sp := h.sp
	if !sp.repl_on || h.own {
		return false
	}
	dir, derr := _obj_dir(e, h.id)
	if derr != .None {
		return false
	}
	hdir, herr := _join(context.temp_allocator, dir, "hist")
	if herr != .None || prim.exists(e.vfs, hdir) {
		return false
	}
	for w in sp.ckpts {
		if w.object == h.id {
			return true
		}
	}
	if _, _, done := _ckpt_get(e, h.id); done {
		return false
	}
	w := new(Ckpt_Wait, e.allocator)
	w.object = h.id
	w.kind = h.kind
	w.scope = h.scope
	w.name, _ = _clone(h.name, e.allocator)
	if prim.mkdir_all(e.vfs, dir, 0o700) != .None || _ckpt_tree(&w.scope, h.id, &w.tree) != .None {
		_ckpt_wait_free(e, w)
		return false
	}
	w.dest, _ = _join(e.allocator, dir, "bundle.in")
	if osync.replicator_fetch_checkpoint(&sp.repl, &w.scope, &w.tree, w.name, w.dest) != .None {
		_ckpt_wait_free(e, w)
		return false
	}
	append(&sp.ckpts, w)
	e.stats.fetches += 1
	return true
}

@(private)
_ckpt_wait_free :: proc(e: ^Engine, w: ^Ckpt_Wait) {
	osync.keytree_destroy(&w.tree)
	osync.scope_clear(&w.scope)
	delete(w.need)
	delete(w.name, e.allocator)
	delete(w.dest, e.allocator)
	free(w, e.allocator)
}

@(private)
_ckpt_waiting :: proc(h: ^Handle) -> bool {
	for w in h.sp.ckpts {
		if w.object == h.id {
			return true
		}
	}
	return false
}

@(private)
_ckpt_arrived :: proc(e: ^Engine, sp: ^Space, name: string, ok: bool) {
	seg := name
	if len(seg) > len(osync.CHECKPOINT_STREAM) && seg[:len(osync.CHECKPOINT_STREAM)] == osync.CHECKPOINT_STREAM {
		seg = seg[len(osync.CHECKPOINT_STREAM):]
	}
	for w, i in sp.ckpts {
		if w.name != seg || w.need != nil {
			continue
		}
		if ok && _ckpt_hold(e, sp, w) {
			return
		}
		ordered_remove(&sp.ckpts, i)
		_ckpt_finish(e, sp, w, ok)
		return
	}
}

@(private)
_ckpt_finish :: proc(e: ^Engine, sp: ^Space, w: ^Ckpt_Wait, ok: bool) {
	loaded := false
	if ok {
		if err := _ckpt_load(e, sp, w); err != .None {
			_log(e, .Warn, "checkpoint load failed")
		} else {
			loaded = true
		}
	}
	if !loaded {
		_ckpt_put(e, w.object, -1, {})
	}
	prim.remove(e.vfs, w.dest)
	if h, hok := e.handles[w.object]; hok {
		_hist_catch_up(e, h)
	}
	_object_changed(e, sp.id, w.object, .Data)
	_ckpt_wait_free(e, w)
}

@(private)
_ckpt_hold :: proc(e: ^Engine, sp: ^Space, w: ^Ckpt_Wait) -> bool {
	db, derr := device_odb(e)
	if derr != .None {
		return false
	}
	fd, oerr := prim.open_file(e.vfs, w.dest)
	if oerr != .None {
		return false
	}
	defer prim.close_file(e.vfs, fd)
	size, serr := prim.file_size(e.vfs, fd)
	if serr != .None {
		return false
	}
	need := make([dynamic]odb.Oid, e.allocator)
	pos: i64
	for pos + 5 <= size {
		head: [5]u8
		n, rerr := prim.read_at(e.vfs, fd, head[:], pos)
		if rerr != .None || n != 5 {
			break
		}
		k := i64(prim.get_u32le(head[1:]))
		if head[0] == CKPT_REMOTE && (k == 20 || k == 32) {
			oid: odb.Oid
			if got, gerr := prim.read_at(e.vfs, fd, oid[:k], pos + 5); gerr == .None && i64(got) == k && !odb.exists(db, oid) {
				append(&need, oid)
			}
		}
		pos += 5 + k
	}
	h, hok := e.handles[w.object]
	if len(need) == 0 || !hok {
		delete(need)
		return false
	}
	w.need = need
	for oid in need {
		_content_fetch(e, h, fs.Content_Ref{oid = oid, len = odb.oid_size(db.format)})
	}
	return true
}

@(private)
_ckpt_content :: proc(e: ^Engine, space: prim.Id, object: prim.Id) {
	sp, ok := e.spaces[space]
	if !ok {
		return
	}
	db, derr := device_odb(e)
	if derr != .None {
		return
	}
	for i := 0; i < len(sp.ckpts); i += 1 {
		w := sp.ckpts[i]
		if w.object != object || w.need == nil {
			continue
		}
		for j := 0; j < len(w.need); {
			if odb.exists(db, w.need[j]) {
				unordered_remove(&w.need, j)
				continue
			}
			j += 1
		}
		if len(w.need) > 0 {
			continue
		}
		ordered_remove(&sp.ckpts, i)
		_ckpt_finish(e, sp, w, true)
		return
	}
}

@(private)
_ckpt_load :: proc(e: ^Engine, sp: ^Space, w: ^Ckpt_Wait) -> Error {
	db := device_odb(e) or_return
	fd, oerr := prim.open_file(e.vfs, w.dest)
	if oerr != .None {
		return _perr(oerr)
	}
	defer prim.close_file(e.vfs, fd)
	size, serr := prim.file_size(e.vfs, fd)
	if serr != .None {
		return _perr(serr)
	}
	dir := _obj_dir(e, w.object) or_return
	hdir := _join(context.temp_allocator, dir, "hist") or_return
	src := Ckpt_Source{e = e, fd = fd, end = size, db = db}
	h, hok := e.handles[w.object]
	streams := fs.Stream_Source{data = h, read = _hist_read} if hok else fs.Stream_Source{}
	opts := fs.History_Options{clock = _fs_clock(e), random = e.cfg.random}
	if hok {
		opts = _hist_options(h)
	}
	hist, lerr := fs.history_bundle_create(e.vfs, hdir, w.object, e.self, db, streams, fs.Bundle_Source{data = &src, read = _ckpt_source_read}, e.allocator, opts)
	if lerr != .None {
		_ckpt_discard(e, hdir)
		return _ferr(lerr)
	}
	if hok && h.hist == nil {
		h.hist = hist
		h.hist_chain = h.own_tree != nil
	} else {
		fs.history_release(hist)
	}
	_ckpt_put(e, w.object, 0, {})
	return .None
}

@(private)
_ckpt_discard :: proc(e: ^Engine, hdir: string) {
	for name in ([]string{"fs.journal", "lv.idx"}) {
		if p, err := _join(context.temp_allocator, hdir, name); err == .None {
			journal.journal_remove(e.vfs, p)
		}
	}
}

@(private)
_ckpt_source_read :: proc(data: rawptr, out: ^[dynamic]u8) -> (ok: bool, err: fs.Error) {
	s := (^Ckpt_Source)(data)
	for s.pos + 5 <= s.end {
		head: [5]u8
		n, rerr := prim.read_at(s.e.vfs, s.fd, head[:], s.pos)
		if rerr != .None || n != 5 {
			return false, .Corrupt
		}
		size := i64(prim.get_u32le(head[1:]))
		if size > journal.MAX_BODY || s.pos + 5 + size > s.end {
			return false, .Corrupt
		}
		clear(out)
		resize(out, int(size))
		if size > 0 {
			got, gerr := prim.read_at(s.e.vfs, s.fd, out[:], s.pos + 5)
			if gerr != .None || i64(got) != size {
				return false, .Corrupt
			}
		}
		s.pos += 5 + size
		switch head[0] {
		case CKPT_FS:
			return true, .None
		case CKPT_REMOTE:
			if len(out) != 20 && len(out) != 32 {
				return false, .Corrupt
			}
		case CKPT_OBJECT:
			if len(out) < 1 || out[0] == 0 || out[0] > u8(max(odb.Object_Type)) {
				return false, .Corrupt
			}
			if _, werr := odb.write(s.db, odb.Object_Type(out[0]), out[1:]); werr != .None {
				return false, fs.from_odb(werr)
			}
		case:
			return false, .Corrupt
		}
	}
	return false, .None
}

@(private)
_oid_name :: proc(oid: [32]u8) -> [prim.ID_HEX_LEN]u8 {
	id: prim.Id
	o := oid
	copy(id[:], o[:16])
	return prim.id_hex(id)
}

checkpoint_info :: proc(e: ^Engine, o: Object) -> (length: i64, loaded: bool, found: bool) {
	context = context_for(e)
	n, oid, ok := _ckpt_get(e, o.id)
	return n, ok && n == 0 && oid == {}, ok
}

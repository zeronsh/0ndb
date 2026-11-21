package engine

import "core:crypto"
import "../journal"
import "../prim"
import osync "../sync"

Own_Tree :: struct {
	space:       prim.Id,
	object:      prim.Id,
	kind:        Kind,
	stream:      osync.Stream_Id,
	tree:        osync.Key_Tree,
	path:        string,
	refs:        int,
	upload_refs: int,
	uploading:   i64,
	dirty:       bool,
	stored:      i64,
}

Remote_Tree :: struct {
	device:    prim.Id,
	name:      string,
	keys_name: string,
	scope:     osync.Scope,
	epoch:     u64,
	tree:      osync.Key_Tree,
	loaded:    bool,
	requested: bool,
	absent:    bool,
	refs:      int,
}

@(private)
_keys_path :: proc(e: ^Engine, object: prim.Id, allocator := context.temp_allocator) -> (path: string, err: Error) {
	d := _obj_dir(e, object, context.temp_allocator) or_return
	return _join(allocator, d, "keys")
}

@(private)
_own_tree_get :: proc(e: ^Engine, sp: ^Space, object: prim.Id, kind: Kind, scope: ^osync.Scope, create: bool) -> (t: ^Own_Tree, err: Error) {
	stream := osync.stream_id(scope, e.self, _seg_name(kind, object), 0)
	if x, ok := e.own_trees[stream]; ok {
		x.refs += 1
		return x, .None
	}
	path := _keys_path(e, object) or_return
	data, rerr := prim.read_file(e.vfs, path, context.temp_allocator)
	if rerr != .None && rerr != .Not_Found {
		return nil, _perr(rerr)
	}
	if rerr == .Not_Found && !create {
		return nil, .Not_Found
	}
	x := new(Own_Tree, e.allocator)
	x.space = sp.id
	x.object = object
	x.kind = kind
	x.stream = stream
	pc, cerr := _clone(path, e.allocator)
	if cerr != .None {
		free(x, e.allocator)
		return nil, cerr
	}
	x.path = pc
	if rerr == .None {
		derr := osync.keytree_decode(&x.tree, data, e.allocator)
		crypto.zero_explicit(raw_data(data), len(data))
		if derr != .None {
			delete(x.path, e.allocator)
			free(x, e.allocator)
			return nil, .Corrupt
		}
		x.stored = i64(len(data))
	} else {
		if kerr := osync.keytree_new(&x.tree, e.cfg.random, e.allocator); kerr != .None {
			delete(x.path, e.allocator)
			free(x, e.allocator)
			return nil, _serr(kerr)
		}
		x.dirty = true
		_touch(e)
	}
	t = x
	t.refs = 1
	e.own_trees[stream] = t
	return t, .None
}

@(private)
_own_tree_ref :: proc(e: ^Engine, h: ^Handle) -> ^Own_Tree {
	if h.own_tree == nil {
		return nil
	}
	h.own_tree.refs += 1
	return h.own_tree
}

@(private)
_own_tree_unref :: proc(e: ^Engine, t: ^Own_Tree) {
	if t.refs > 0 {
		t.refs -= 1
	}
}

@(private)
_own_tree_uploaded :: proc(e: ^Engine, stream: osync.Stream_Id, length: i64) {
	t, ok := e.own_trees[stream]
	if !ok || length < t.uploading {
		return
	}
	for t.upload_refs > 0 {
		t.upload_refs -= 1
		_own_tree_unref(e, t)
	}
}

@(private)
_own_tree_puncture :: proc(e: ^Engine, t: ^Own_Tree, from, to: i64, keep: []i64) -> Error {
	_serr(osync.keytree_puncture_except(&t.tree, from, to, keep)) or_return
	t.dirty = true
	_touch(e)
	return .None
}

@(private)
_trees_persist :: proc(e: ^Engine) {
	for k in _sorted_keys(e.own_trees) {
		t := e.own_trees[k]
		if !t.dirty {
			continue
		}
		if err := _own_tree_store(e, t); err != .None {
			if err != .Busy {
				_fatal(e, err)
			}
			continue
		}
		t.dirty = false
	}
}

@(private)
_own_tree_store :: proc(e: ^Engine, t: ^Own_Tree) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(buf), len(buf))
	_serr(osync.keytree_encode(&t.tree, &buf)) or_return
	dir := prim.dir_name(t.path)
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	tmp := _join(context.temp_allocator, dir, "keys.tmp") or_return
	fd, oerr := prim.open_file(e.vfs, tmp, {.Write, .Create}, 0o600)
	if oerr != .None {
		return _perr(oerr)
	}
	werr := _key_file_write(e, fd, buf[:])
	cerr := prim.close_file(e.vfs, fd)
	if werr == .None {
		werr = _perr(cerr)
	}
	if werr == .None {
		werr = _perr(prim.rename(e.vfs, tmp, t.path))
	}
	if werr != .None {
		return werr
	}
	t.stored = i64(len(buf))
	return _perr(prim.sync_dir(e.vfs, dir))
}

@(private)
_key_file_write :: proc(e: ^Engine, fd: prim.Fd, data: []u8) -> Error {
	size, serr := prim.file_size(e.vfs, fd)
	if serr != .None {
		return _perr(serr)
	}
	if size > 0 {
		_perr(prim.zero_range(e.vfs, fd, 0, size)) or_return
		_perr(prim.truncate(e.vfs, fd, 0)) or_return
	}
	_perr(prim.write_at(e.vfs, fd, data, 0)) or_return
	return _perr(prim.datasync(e.vfs, fd))
}

@(private)
_own_tree_free :: proc(e: ^Engine, t: ^Own_Tree) {
	osync.keytree_destroy(&t.tree)
	delete(t.path, e.allocator)
	free(t, e.allocator)
}

@(private)
_trees_release :: proc(e: ^Engine) {
	for k, t in e.own_trees {
		if t.refs == 0 && t.upload_refs == 0 && !t.dirty {
			delete_key(&e.own_trees, k)
			_own_tree_free(e, t)
		}
	}
}

@(private)
_trees_free_all :: proc(e: ^Engine) {
	_trees_persist(e)
	for _, t in e.own_trees {
		_own_tree_free(e, t)
	}
	clear(&e.own_trees)
}

@(private)
_remote_tree_get :: proc(e: ^Engine, sp: ^Space, scope: ^osync.Scope, device: prim.Id, name: string, epoch: u64) -> (rt: ^Remote_Tree, err: Error) {
	stream := osync.stream_id(scope, device, name, 0)
	if x, ok := sp.remote_trees[stream]; ok {
		if epoch > x.epoch {
			x.epoch = epoch
			if x.loaded {
				osync.keytree_destroy(&x.tree)
				x.loaded = false
			}
			x.requested = false
		}
		if !x.loaded {
			_remote_tree_load(e, sp, x)
		}
		return x, .None
	}
	rt = new(Remote_Tree, e.allocator)
	rt.device = device
	rt.epoch = epoch
	rt.scope = scope^
	rt.name = _clone(name, e.allocator) or_return
	kn, kerr := osync.keys_stream_name(name, e.allocator)
	if kerr != .None {
		delete(rt.name, e.allocator)
		free(rt, e.allocator)
		return nil, _serr(kerr)
	}
	rt.keys_name = kn
	sp.remote_trees[stream] = rt
	_remote_tree_load(e, sp, rt)
	return rt, .None
}

@(private)
_remote_tree_load :: proc(e: ^Engine, sp: ^Space, rt: ^Remote_Tree) {
	if rt.loaded || !sp.repl_on {
		return
	}
	rep, aerr := osync.replicator_acquire(&sp.repl, &rt.scope, rt.device, rt.keys_name, rt.epoch)
	if aerr != .None {
		return
	}
	defer osync.replicator_release(&sp.repl, &rt.scope, rt.device, rt.keys_name, rt.epoch)
	end := journal.replica_length(rep)
	if end == 0 {
		if rt.requested && osync.replicator_relay_length(&sp.repl, &rt.scope, rt.device, rt.keys_name, rt.epoch) <= 0 {
			rt.absent = true
		}
		if !rt.requested {
			rt.requested = true
			osync.replicator_want_tail(&sp.repl, &rt.scope, rt.device, rt.keys_name, rt.epoch, 4096)
			e.stats.fetches += 1
		}
		return
	}
	rd: journal.Reader
	journal.replica_reader(rep, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	sid := osync.stream_id(&rt.scope, rt.device, rt.keys_name, rt.epoch)
	key := osync.stream_key(&rt.scope, sid)
	defer crypto.zero_explicit(&key, size_of(key))
	if rt.scope.mode == .End_To_End {
		journal.reader_set_keys(&rd, osync.static_provider(&key))
	}
	body, _, rerr := journal.record_before(&rd, end)
	if rerr == .Missing {
		if !rt.requested {
			rt.requested = true
			osync.replicator_want_tail(&sp.repl, &rt.scope, rt.device, rt.keys_name, rt.epoch, 4096)
		}
		return
	}
	if rerr != .None {
		return
	}
	if osync.keys_record_decode(&rt.tree, body, e.allocator) != .None {
		return
	}
	rt.loaded = true
	rt.absent = false
	_held_release(e, sp, rt.device)
	osync.replicator_keys_ready(&sp.repl, &rt.scope, rt.device, rt.name, 0)
}

@(private)
_remote_tree_free :: proc(e: ^Engine, rt: ^Remote_Tree) {
	if rt.loaded {
		osync.keytree_destroy(&rt.tree)
	}
	osync.scope_clear(&rt.scope)
	delete(rt.name, e.allocator)
	delete(rt.keys_name, e.allocator)
	free(rt, e.allocator)
}

@(private)
_remote_tree_by_keys :: proc(sp: ^Space, device: prim.Id, keys_name: string) -> ^Remote_Tree {
	for _, rt in sp.remote_trees {
		if rt.device == device && rt.keys_name == keys_name {
			return rt
		}
	}
	return nil
}

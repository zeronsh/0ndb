package engine

import "core:crypto"
import "../journal"
import omap "../map"
import "../prim"
import osync "../sync"

Own_Tree :: struct {
	space:       prim.Id,
	object:      prim.Id,
	kind:        Kind,
	stream:      osync.Stream_Id,
	tree:        osync.Key_Tree,
	refs:        int,
	upload_refs: int,
	uploading:   i64,
	dirty:       bool,
	after:       u64,
	stored:      i64,
	keys_ok:     u64,
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
	locked:    bool,
	refs:      int,
}

@(private)
_keys_path :: proc(e: ^Engine, object: prim.Id, allocator := context.temp_allocator) -> (path: string, err: Error) {
	d := _obj_dir(e, object, context.temp_allocator) or_return
	return _join(allocator, d, "keys")
}

@(private)
_keys_key :: proc(object: prim.Id) -> (k: [17]u8) {
	o := object
	copy(k[:16], o[:])
	k[16] = 'k'
	return
}

@(private)
_own_tree_bytes :: proc(e: ^Engine, object: prim.Id) -> (data: []u8, found: bool, legacy: bool, err: Error) {
	if v, ok := e.reg.kstaged[object]; ok {
		return v, true, false, .None
	}
	key := _keys_key(object)
	v, hit, gerr := omap.db_get(&e.reg.db, ROOT_OBJECTS, key[:], context.temp_allocator)
	if gerr != .None {
		return nil, false, false, _oerr(gerr)
	}
	if hit {
		return v, true, false, .None
	}
	path := _keys_path(e, object) or_return
	f, rerr := prim.read_file(e.vfs, path, context.temp_allocator)
	if rerr == .Not_Found {
		return nil, false, false, .None
	}
	if rerr != .None {
		return nil, false, false, _perr(rerr)
	}
	return f, true, true, .None
}

@(private)
_own_tree_get :: proc(e: ^Engine, sp: ^Space, object: prim.Id, kind: Kind, scope: ^osync.Scope, create: bool) -> (t: ^Own_Tree, err: Error) {
	stream := osync.stream_id(scope, e.self, _seg_name(kind, object), 0)
	if x, ok := e.own_trees[stream]; ok {
		x.refs += 1
		return x, .None
	}
	data, found, legacy := _own_tree_bytes(e, object) or_return
	if !found && !create {
		return nil, .Not_Found
	}
	x := new(Own_Tree, e.allocator)
	x.space = sp.id
	x.object = object
	x.kind = kind
	x.stream = stream
	if found {
		derr := osync.keytree_decode(&x.tree, data, e.allocator)
		if legacy {
			crypto.zero_explicit(raw_data(data), len(data))
		}
		if derr != .None {
			free(x, e.allocator)
			return nil, .Corrupt
		}
		x.stored = i64(len(data))
		if legacy {
			if serr := _own_tree_store(e, x); serr != .None {
				osync.keytree_destroy(&x.tree)
				free(x, e.allocator)
				return nil, serr
			}
		}
		_own_tree_legacy_drop(e, object)
	} else {
		if kerr := osync.keytree_new(&x.tree, e.cfg.random, e.allocator); kerr != .None {
			free(x, e.allocator)
			return nil, _serr(kerr)
		}
		if tag, ok := space_epoch_tag(sp); ok {
			x.tree.epoch = tag
		} else if g, gfound := sp.grant_epochs[object]; gfound && len(g) > 0 {
			x.tree.epoch = g[len(g) - 1].tag
		} else if sp.mode == .End_To_End {
			osync.keytree_destroy(&x.tree)
			free(x, e.allocator)
			return nil, .Permission
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
_own_tree_legacy_drop :: proc(e: ^Engine, object: prim.Id) {
	path, perr := _keys_path(e, object)
	if perr != .None {
		return
	}
	fd, oerr := prim.open_file(e.vfs, path, {.Write})
	if oerr != .None {
		return
	}
	if size, serr := prim.file_size(e.vfs, fd); serr == .None && size > 0 {
		zerr := prim.zero_range(e.vfs, fd, 0, size)
		if zerr == .None {
			zerr = prim.datasync(e.vfs, fd)
		}
		if zerr != .None {
			_store_err(e, _perr(zerr))
		}
	}
	prim.close_file(e.vfs, fd)
	prim.remove(e.vfs, path)
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
		if !t.dirty || t.after > e.durable_seq {
			continue
		}
		if err := _own_tree_stage(e, t); err != .None {
			_fatal(e, err)
			continue
		}
		t.dirty = false
		t.after = 0
	}
}

@(private)
_own_tree_stage :: proc(e: ^Engine, t: ^Own_Tree) -> Error {
	buf := make([dynamic]u8, e.allocator)
	if err := osync.keytree_encode(&t.tree, &buf); err != .None {
		crypto.zero_explicit(raw_data(buf), len(buf))
		delete(buf)
		return _serr(err)
	}
	if old, ok := e.reg.kstaged[t.object]; ok {
		crypto.zero_explicit(raw_data(old), len(old))
		delete(old, e.allocator)
	}
	e.reg.kstaged[t.object] = buf[:]
	t.stored = i64(len(buf))
	_touch(e)
	return .None
}

@(private)
_own_tree_punctured :: proc(e: ^Engine, t: ^Own_Tree) {
	t.dirty = true
	t.after = max(t.after, e.batch_seq + 1)
	_touch(e)
}

@(private)
_trees_waiting :: proc(e: ^Engine) -> bool {
	for _, t in e.own_trees {
		if t.dirty && t.after > 0 {
			return true
		}
	}
	return false
}

@(private)
_own_tree_store :: proc(e: ^Engine, t: ^Own_Tree) -> Error {
	_own_tree_stage(e, t) or_return
	return _registry_flush(e)
}

@(private)
_own_tree_free :: proc(e: ^Engine, t: ^Own_Tree) {
	osync.keytree_destroy(&t.tree)
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
	if tag, sealed := osync.keys_record_tag(body); sealed {
		oid, _, ok := _object_of_name(rt.name)
		if !ok {
			return
		}
		ok_key: bool
		okey: [32]u8
		okey, ok_key = _object_epoch_key(sp, oid, tag)
		defer crypto.zero_explicit(&okey, size_of(okey))
		if !ok_key {
			rt.locked = true
			return
		}
		if osync.keys_record_open(&rt.tree, body, &okey, sid, rt.epoch, e.allocator) != .None {
			return
		}
		rt.locked = false
	} else if osync.keys_record_decode(&rt.tree, body, e.allocator) != .None {
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

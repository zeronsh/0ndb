package engine

import "base:runtime"
import "core:crypto"
import "core:slice"
import "core:strings"
import "../fs"
import "../journal"
import omap "../map"
import "../obj"
import "../pack"
import "../prim"
import "../search"
import osync "../sync"

@(private)
ROOT_OBJECTS :: 0
@(private)
ROOT_SPACES :: 1
@(private)
REC_VERSION :: 1

Member :: struct {
	device:     prim.Id,
	keys_epoch: u64,
	scanned:    i64,
}

Obj_Rec :: struct {
	space:   prim.Id,
	kind:    Kind,
	own:     bool,
	created: prim.Hlc,
	members: [dynamic]Member,
}

@(private)
Registry :: struct {
	db:      omap.Db,
	open:    bool,
	staged:  map[prim.Id][]u8,
	sstaged: map[prim.Id][]u8,
	meta:    bool,
}

@(private)
Dirty_Seg :: struct {
	space:  prim.Id,
	object: prim.Id,
	kind:   Kind,
	scope:  osync.Scope,
	name:   string,
	path:   string,
	length: i64,
	tree:   ^Own_Tree,
	keys:   bool,
}

@(private)
Durable_Batch :: struct {
	e:     ^Engine,
	tick:  u64,
	segs:  [dynamic]Dirty_Seg,
	meta:  bool,
	cards: [dynamic]Card_Pub,
	marks: [dynamic]Hist_Mark,
	drafts: [dynamic]Draft_Pub,
}

@(private)
Hist_Mark :: struct {
	object: prim.Id,
	mark:   u64,
}

@(private)
Card_Pub :: struct {
	space:  prim.Id,
	object: prim.Id,
}

@(private)
_registry_open :: proc(e: ^Engine) -> Error {
	path := _join(context.temp_allocator, e.pack_root, "registry") or_return
	_oerr(omap.db_open(&e.reg.db, e.vfs, path, e.allocator)) or_return
	e.reg.open = true
	e.reg.staged = make(map[prim.Id][]u8, e.allocator)
	e.reg.sstaged = make(map[prim.Id][]u8, e.allocator)
	return .None
}

@(private)
_registry_close :: proc(e: ^Engine) {
	_rlog_close(e)
	if !e.reg.open {
		return
	}
	_registry_flush(e)
	for _, v in e.reg.staged {
		delete(v, e.allocator)
	}
	for _, v in e.reg.sstaged {
		delete(v, e.allocator)
	}
	delete(e.reg.staged)
	delete(e.reg.sstaged)
	omap.db_close(&e.reg.db)
	e.reg.open = false
}

@(private)
_registry_flush :: proc(e: ^Engine) -> Error {
	if !e.reg.open || (len(e.reg.staged) == 0 && len(e.reg.sstaged) == 0) {
		return .None
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	for k in _sorted_keys(e.reg.staged) {
		v := e.reg.staged[k]
		key := k
		if err := omap.txn_put(t, ROOT_OBJECTS, key[:], v); err != .None {
			omap.txn_abort(t)
			return _oerr(err)
		}
	}
	for k in _sorted_keys(e.reg.sstaged) {
		v := e.reg.sstaged[k]
		key := k
		if err := omap.txn_put(t, ROOT_SPACES, key[:], v); err != .None {
			omap.txn_abort(t)
			return _oerr(err)
		}
	}
	if err := omap.txn_commit(t); err != .None {
		return _oerr(err)
	}
	e.reg.meta = true
	for _, v in e.reg.staged {
		delete(v, e.allocator)
	}
	for _, v in e.reg.sstaged {
		delete(v, e.allocator)
	}
	clear(&e.reg.staged)
	clear(&e.reg.sstaged)
	return .None
}

@(private)
_rec_get :: proc(e: ^Engine, id: prim.Id, allocator := context.temp_allocator) -> (rec: Obj_Rec, found: bool, err: Error) {
	if v, ok := e.reg.staged[id]; ok {
		rec = _rec_decode(v, allocator) or_return
		return rec, true, .None
	}
	key := id
	v, hit, gerr := omap.db_get(&e.reg.db, ROOT_OBJECTS, key[:], context.temp_allocator)
	if gerr != .None {
		return rec, false, _oerr(gerr)
	}
	if !hit {
		return rec, false, .None
	}
	rec = _rec_decode(v, allocator) or_return
	return rec, true, .None
}

@(private)
_rec_put :: proc(e: ^Engine, id: prim.Id, rec: ^Obj_Rec) -> Error {
	buf := _rec_encode(rec, e.allocator) or_return
	if old, ok := e.reg.staged[id]; ok {
		delete(old, e.allocator)
	}
	e.reg.staged[id] = buf
	_touch(e)
	return .None
}

@(private)
_rec_encode :: proc(rec: ^Obj_Rec, allocator: runtime.Allocator) -> (out: []u8, err: Error) {
	buf := make([dynamic]u8, allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, REC_VERSION)
	prim.write_id(&w, rec.space)
	prim.write_u8(&w, u8(rec.kind))
	prim.write_bool(&w, rec.own)
	prim.write_u64le(&w, u64(rec.created))
	prim.write_uvarint(&w, u64(len(rec.members)))
	for m in rec.members {
		prim.write_id(&w, m.device)
		prim.write_uvarint(&w, m.keys_epoch)
		prim.write_uvarint(&w, u64(max(m.scanned, 0)))
	}
	if w.err != .None {
		delete(buf)
		return nil, .No_Memory
	}
	return buf[:], .None
}

@(private)
_rec_decode :: proc(v: []u8, allocator: runtime.Allocator) -> (rec: Obj_Rec, err: Error) {
	r := prim.reader(v)
	if prim.read_u8(&r) != REC_VERSION {
		return rec, .Corrupt
	}
	rec.space = prim.read_id(&r)
	k := prim.read_u8(&r)
	rec.own = prim.read_bool(&r)
	rec.created = prim.Hlc(prim.read_u64le(&r))
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || k < 1 || k > u8(max(Kind)) || n > u64(prim.reader_remaining(&r)) {
		return rec, .Corrupt
	}
	rec.kind = Kind(k)
	rec.members = make([dynamic]Member, 0, int(n), allocator)
	for _ in 0 ..< n {
		m: Member
		m.device = prim.read_id(&r)
		m.keys_epoch = prim.read_uvarint(&r)
		m.scanned = i64(min(prim.read_uvarint(&r), u64(max(i64))))
		append(&rec.members, m)
	}
	if !prim.reader_done(&r) {
		return rec, .Corrupt
	}
	return rec, .None
}

@(private)
_rec_member :: proc(rec: ^Obj_Rec, device: prim.Id) -> int {
	for m, i in rec.members {
		if m.device == device {
			return i
		}
	}
	return -1
}

@(private)
_seg_name :: proc(kind: Kind, id: prim.Id, allocator := context.temp_allocator) -> string {
	b := make([]u8, 1 + prim.ID_HEX_LEN, allocator)
	switch kind {
	case .Conversation:
		b[0] = 'c'
	case .Map:
		b[0] = 'm'
	case .Text:
		b[0] = 't'
	case .File_Tree:
		b[0] = 'f'
	}
	h := prim.id_hex(id)
	copy(b[1:], h[:])
	return string(b)
}

@(private)
_seg_kind :: proc "contextless" (name: string) -> (kind: Kind, ok: bool) {
	if len(name) != 1 + prim.ID_HEX_LEN {
		return
	}
	switch name[0] {
	case 'c':
		return .Conversation, true
	case 'm':
		return .Map, true
	case 't':
		return .Text, true
	case 'f':
		return .File_Tree, true
	}
	return
}

@(private)
_obj_dir :: proc(e: ^Engine, id: prim.Id, allocator := context.temp_allocator) -> (path: string, err: Error) {
	h := prim.id_hex(id)
	return _join(allocator, e.pack_root, "o", string(h[0:2]), string(h[:]))
}

@(private)
_seg_path :: proc(e: ^Engine, id: prim.Id, allocator := context.temp_allocator) -> (path: string, err: Error) {
	d := _obj_dir(e, id, context.temp_allocator) or_return
	return _join(allocator, d, "seg")
}

@(private)
_dirty_add :: proc(e: ^Engine, h: ^Handle, path: string, length: i64) {
	for &d in e.dirty {
		if d.object == h.id {
			d.length = max(d.length, length)
			if len(d.path) == 0 {
				d.path = _clone(path, e.allocator) or_else ""
			}
			if d.tree == nil {
				d.tree = _own_tree_ref(e, h)
			}
			d.keys ||= _keys_unconfirmed(e, h.sp, &h.scope, h.name, d.tree)
			return
		}
	}
	tr := _own_tree_ref(e, h)
	append(&e.dirty, Dirty_Seg{space = h.sp.id, object = h.id, kind = h.kind, scope = h.scope, name = _clone(h.name, e.allocator) or_else "", path = _clone(path, e.allocator) or_else "", length = length, tree = tr, keys = _keys_unconfirmed(e, h.sp, &h.scope, h.name, tr)})
	_touch(e)
}

@(private)
_keys_unconfirmed :: proc(e: ^Engine, sp: ^Space, scope: ^osync.Scope, name: string, t: ^Own_Tree) -> bool {
	if t == nil || !sp.repl_on {
		return false
	}
	if t.keys_ok == t.tree.version + 1 {
		return false
	}
	if osync.replicator_keys_published(&sp.repl, scope, name, &t.tree) {
		t.keys_ok = t.tree.version + 1
		return false
	}
	return true
}

@(private)
_dirty_drop :: proc(e: ^Engine) {
	for &d in e.dirty {
		if d.tree != nil {
			_own_tree_unref(e, d.tree)
		}
		osync.scope_clear(&d.scope)
		delete(d.name, e.allocator)
		delete(d.path, e.allocator)
	}
	clear(&e.dirty)
}

@(private)
_dirty_keys :: proc(e: ^Engine, sp: ^Space, object: prim.Id, kind: Kind, scope: osync.Scope, tr: ^Own_Tree) {
	if tr == nil {
		return
	}
	for &d in e.dirty {
		if d.object == object {
			d.keys = true
			if d.tree == nil {
				tr.refs += 1
				d.tree = tr
			}
			return
		}
	}
	tr.refs += 1
	append(&e.dirty, Dirty_Seg{space = sp.id, object = object, kind = kind, scope = scope, name = _clone(_seg_name(kind, object), e.allocator) or_else "", keys = true, tree = tr})
	_touch(e)
}

@(private)
_durable_begin :: proc(e: ^Engine) {
	if !e.pk_open {
		return
	}
	if err := _registry_flush(e); err != .None {
		if err == .Busy {
			_touch(e)
		} else {
			_fatal(e, err)
		}
		return
	}
	_trees_persist(e)
	_rlog_settle(e, false)
	_keys_stage(e)
	b := new(Durable_Batch, e.allocator)
	b.e = e
	b.tick = e.tick
	b.segs = e.dirty
	b.meta = e.reg.meta
	e.reg.meta = false
	b.cards = e.card_pubs
	e.card_pubs = make([dynamic]Card_Pub, e.allocator)
	b.marks = make([dynamic]Hist_Mark, e.allocator)
	for h in e.lru {
		if h.hist != nil && fs.history_durable_mark(h.hist) > h.hist.durable {
			append(&b.marks, Hist_Mark{h.id, fs.history_mark_take(h.hist)})
		}
	}
	e.dirty = make([dynamic]Dirty_Seg, e.allocator)
	b.drafts = e.draft_dirty
	e.draft_dirty = make([dynamic]Draft_Pub, e.allocator)
	append(&e.batches, b)
	e.stats.commits += 1
	err := pack.batch_end_async(&e.pk, _batch_cb, b)
	if err == .None {
		_pack_step(e)
	}
	pack.batch_begin(&e.pk)
	if err != .None {
		if err == .Would_Block {
			for i := len(e.batches) - 1; i >= 0; i -= 1 {
				if e.batches[i] == b {
					ordered_remove(&e.batches, i)
					break
				}
			}
			for d in e.dirty {
				append(&b.segs, d)
			}
			delete(e.dirty)
			e.dirty = b.segs
			for x in e.draft_dirty {
				append(&b.drafts, x)
			}
			delete(e.draft_dirty)
			e.draft_dirty = b.drafts
			e.reg.meta ||= b.meta
			for c in e.card_pubs {
				append(&b.cards, c)
			}
			delete(e.card_pubs)
			e.card_pubs = b.cards
			delete(b.marks)
			free(b, e.allocator)
			return
		}
		_batch_complete(e, b, _perr(err))
		return
	}
	if e.cfg.durability == .Deferred {
		_pack_poll(e)
	}
}

@(private)
_pack_step :: proc(e: ^Engine) {
	more, err := pack.step(&e.pk)
	if err != .None {
		_fatal(e, _perr(err))
		return
	}
	e.pack_more = more
}

@(private)
_batch_cb :: proc(data: rawptr, err: pack.Error) {
	b := (^Durable_Batch)(data)
	context = context_for(b.e)
	_batch_complete(b.e, b, _perr(err))
}

@(private)
_batches_done :: proc(e: ^Engine, err: Error) {
	for len(e.batches) > 0 {
		_batch_complete(e, e.batches[0], err)
	}
}

@(private)
_batch_complete :: proc(e: ^Engine, b: ^Durable_Batch, err: Error) {
	idx := -1
	for x, i in e.batches {
		if x == b {
			idx = i
			break
		}
	}
	if idx < 0 {
		return
	}
	ordered_remove(&e.batches, idx)
	if err != .None {
		_fatal(e, err)
	} else {
		e.durable_tick = max(e.durable_tick, b.tick)
		e.stats.durable += 1
		for p in b.drafts {
			_draft_publish(e, p)
		}
		for &d in b.segs {
			_publish(e, &d)
			if d.kind == .Conversation && d.length > 0 {
				_draft_settle(e, d.object, d.length)
			}
		}
		for _, sp in e.spaces {
			if sp.repl_on {
				osync.replicator_durable(&sp.repl)
			}
		}
		if rv := e.approvals.rv; rv != nil && rv.repl_on {
			osync.replicator_durable(&rv.repl)
		}
		for c in b.cards {
			_card_pub_durable(e, c)
		}
		for m in b.marks {
			if h, ok := e.handles[m.object]; ok && h.hist != nil {
				if derr := fs.history_durable(h.hist, m.mark); derr != .None {
					_log(e, .Warn, "mount state persist failed")
				}
			}
		}
		if len(b.segs) > 0 || b.meta {
			_emit(e, Event{kind = .Durable, tick = b.tick})
		}
	}
	for &d in b.segs {
		if d.tree != nil {
			_own_tree_unref(e, d.tree)
		}
		osync.scope_clear(&d.scope)
		delete(d.name, e.allocator)
		delete(d.path, e.allocator)
	}
	delete(b.segs)
	delete(b.cards)
	delete(b.marks)
	delete(b.drafts)
	free(b, e.allocator)
	if len(e.settles) > 0 {
		_touch(e)
	}
}

@(private)
_keys_stage :: proc(e: ^Engine) {
	for &d in e.dirty {
		if !d.keys || d.tree == nil || d.tree.dirty {
			continue
		}
		sp, ok := e.spaces[d.space]
		if !ok || !sp.repl_on {
			continue
		}
		okey, sealed := _object_epoch_key(sp, d.object, d.tree.tree.epoch)
		if sp.mode != .End_To_End || sealed {
			osync.replicator_stage_keys(&sp.repl, &d.scope, d.name, &d.tree.tree, &okey if sealed else nil)
		}
		crypto.zero_explicit(&okey, size_of(okey))
	}
}

@(private)
_publish :: proc(e: ^Engine, d: ^Dirty_Seg) {
	sp, ok := e.spaces[d.space]
	if !ok || !sp.repl_on {
		return
	}
	if d.tree != nil && d.tree.dirty {
		_publish_later(e, d)
		return
	}
	if d.keys && d.tree != nil {
		okey, sealed := _object_epoch_key(sp, d.object, d.tree.tree.epoch)
		seal: ^[32]u8 = &okey if sealed else nil
		if sp.mode == .End_To_End && !sealed {
			_log(e, .Warn, "keys publish without epoch key")
		} else if err := osync.replicator_publish_keys(&sp.repl, &d.scope, d.name, &d.tree.tree, seal); err == .Conflict {
			d.tree.tree.version += 1
			d.tree.dirty = true
			_dirty_keys(e, sp, d.object, d.kind, d.scope, d.tree)
		} else if err != .None {
			_log(e, .Warn, "keys publish failed")
		}
		crypto.zero_explicit(&okey, size_of(okey))
	}
	if d.length > 0 && len(d.path) > 0 {
		var_tree: ^osync.Key_Tree = nil
		if d.tree != nil {
			var_tree = &d.tree.tree
			d.tree.uploading = max(d.tree.uploading, d.length)
			d.tree.upload_refs += 1
			d.tree.refs += 1
		}
		hollow := _storage_class(e, sp, d.object, d.kind) == .Device
		err := osync.replicator_publish(&sp.repl, &d.scope, d.name, 0, d.path, d.length, var_tree, hollow)
		if err != .None {
			if d.tree != nil {
				d.tree.upload_refs -= 1
				_own_tree_unref(e, d.tree)
			}
			_log(e, .Warn, "publish failed")
		}
	}
}

@(private)
_index_item_add :: proc(e: ^Engine, space: prim.Id, object: prim.Id, kind: Kind) {
	for it in e.index_dirty {
		if it.object == object {
			return
		}
	}
	append(&e.index_dirty, Index_Item{space = space, object = object, kind = kind})
}

@(private)
_clone :: proc(s: string, allocator: runtime.Allocator) -> (string, Error) {
	out, err := strings.clone(s, allocator)
	if err != nil {
		return "", .No_Memory
	}
	return out, .None
}

@(private)
_clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> ([]u8, Error) {
	if len(b) == 0 {
		return nil, .None
	}
	out, err := make([]u8, len(b), allocator)
	if err != nil {
		return nil, .No_Memory
	}
	copy(out, b)
	return out, .None
}

@(private)
_join :: proc(allocator: runtime.Allocator, parts: ..string) -> (string, Error) {
	s, err := prim.path_join(allocator, ..parts)
	return s, _perr(err)
}

@(private)
_perr :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Permission:
		return .Permission
	case .Busy, .Would_Block:
		return .Busy
	case .Invalid, .Not_Dir, .Is_Dir, .Name_Too_Long:
		return .Invalid
	case .No_Space:
		return .No_Space
	case .No_Memory, .Too_Many_Files:
		return .No_Memory
	case .Too_Large:
		return .Too_Large
	case .Unsupported:
		return .Unsupported
	}
	return .Io
}

@(private)
_oerr :: proc "contextless" (e: obj.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Missing:
		return .Missing
	case .Corrupt:
		return .Corrupt
	case .Invalid:
		return .Invalid
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Busy:
		return .Busy
	case .Limit:
		return .Limit
	case .Too_Large:
		return .Too_Large
	case .Unsupported:
		return .Unsupported
	case .Not_Assigned:
		return .Not_Assigned
	case .Unknown_Segment:
		return .Missing
	case .Forged:
		return .Forged
	case .Permission:
		return .Permission
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Io:
		return .Io
	}
	return .Io
}

@(private)
_jerr :: proc "contextless" (e: journal.Error) -> Error {
	return _oerr(obj.jerr(e))
}

@(private)
_serr :: proc "contextless" (e: osync.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid, .Protocol:
		return .Invalid
	case .Corrupt:
		return .Corrupt
	case .Auth, .Permission:
		return .Permission
	case .Closed, .Timeout, .Resolve, .Refused:
		return .Offline
	case .Would_Block, .Busy:
		return .Busy
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .No_Space, .Quota:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Too_Large:
		return .Too_Large
	case .Conflict:
		return .Forged
	case .Unsupported:
		return .Unsupported
	case .Io:
		return .Io
	case .Pending:
		return .Pending
	}
	return .Io
}

@(private)
_ferr :: proc "contextless" (e: fs.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Permission:
		return .Permission
	case .Busy:
		return .Busy
	case .Invalid, .Not_Dir, .Is_Dir, .Not_Empty, .Name_Too_Long, .Changed, .Not_Repository, .Conflicts:
		return .Invalid
	case .Corrupt:
		return .Corrupt
	case .No_Space:
		return .No_Space
	case .No_Memory, .Too_Many_Files:
		return .No_Memory
	case .Too_Large:
		return .Too_Large
	case .Unsupported:
		return .Unsupported
	case .Redacted:
		return .Missing
	}
	return .Io
}

@(private)
_xerr :: proc "contextless" (e: search.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Corrupt:
		return .Corrupt
	case .Invalid, .Syntax:
		return .Invalid
	case .Full, .Too_Large:
		return .Too_Large
	case .Busy:
		return .Busy
	case .Not_Found:
		return .Not_Found
	case .Missing:
		return .Missing
	case .Permission:
		return .Permission
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Io:
		return .Io
	}
	return .Io
}

@(private)
_sorted_keys :: proc(m: map[$K]$V) -> []K {
	keys := make([]K, len(m), context.temp_allocator)
	i := 0
	for k in m {
		keys[i] = k
		i += 1
	}
	slice.sort_by(keys, proc(a, b: K) -> bool {
		x, y := a, b
		return runtime.memory_compare(&x, &y, size_of(K)) < 0
	})
	return keys
}

durable_len :: proc(e: ^Engine, path: string) -> (size: i64, err: Error) {
	context = context_for(e)
	if !e.pk_open {
		return 0, .Invalid
	}
	n, perr := pack.durable_size(&e.pk, path)
	return n, _perr(perr)
}

@(private)
_pack_before_commit :: proc(data: rawptr) -> pack.Error {
	e := (^Engine)(data)
	context = context_for(e)
	if !e.db_open {
		return .None
	}
	if err := odb_barrier(e); err != .None {
		return .Io
	}
	return .None
}

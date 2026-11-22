package engine

import "core:crypto"
import "core:fmt"
import "core:crypto/blake2b"
import omap "../map"
import "../prim"
import "../search"
import osync "../sync"

@(private)
SEARCH_KEY_SOURCE :: u8(0xf3)
@(private)
SEARCH_KEY_CHAIN :: u8(0xf4)
@(private)
SEARCH_KEY_RESTORE :: u8(0xf5)
@(private)
SEARCH_KEY_REDACT :: u8(0xf6)
@(private)
SEARCH_KEY_REBUILT :: u8(0xf7)
@(private)
SEARCH_KEY_ADVERTISED :: u8(0xf8)
@(private)
SNAP_HISTORY :: "0ndb:search"
@(private)
SNAP_DOMAIN :: "0ndb search snapshot v1"
@(private)
SNAP_VERSION :: u8(1)
@(private)
SNAP_MIN_TEXT :: 16 * 1024
@(private)
SNAP_PIECE :: u64(32 * 1024 * 1024)
@(private)
SNAP_MAX :: 1024
@(private)
SNAP_DIRTY :: u8(1)
@(private)
SNAP_ENTRY :: 61

Snapshot_Info :: struct {
	entries:    int,
	docs:       u64,
	text:       u64,
	cursor:     u64,
	restoring:  bool,
	restored:   int,
	restore_ms: i64,
}

@(private)
Snap_Entry :: struct {
	lo:   u64,
	hi:   u64,
	docs: u32,
	text: u64,
	oid:  [32]u8,
	mine: bool,
}

@(private)
Snap_Chain :: struct {
	flags:   u8,
	cursor:  u64,
	text_at: u64,
	rec_end: i64,
	zero_to: i64,
	zeroed:  i64,
	entries: [dynamic]Snap_Entry,
}

@(private)
Snap_Source :: struct {
	object: prim.Id,
	device: prim.Id,
	pos:    i64,
	at:     u64,
}

@(private)
Snap_Restore :: struct {
	e:         ^Engine,
	space:     prim.Id,
	tree:      osync.Key_Tree,
	dir:       string,
	importing: bool,
	oids:      [dynamic][32]u8,
	paths:     [dynamic]string,
	pending:   int,
	next:      int,
	cur_lo:    u64,
	started:   i64,
	sources:   [dynamic]Snap_Source,
	local:     map[prim.Id]bool,
	chain:     [dynamic]Snap_Entry,
	docs:      int,
	head:      bool,
	head_ok:   bool,
	head_meta: []u8,
	head_path: string,
	head_oid:  []u8,
	failed:    bool,
}

@(private)
Snap_Keep :: struct {
	e:       ^Engine,
	space:   prim.Id,
	last:    prim.Id,
	last_ok: bool,
	have:    bool,
}

@(private)
_snap_key :: proc(tag: u8, space: prim.Id) -> (k: [17]u8) {
	s := space
	k[0] = tag
	copy(k[1:], s[:])
	return
}

@(private)
_snap_source_key :: proc(space, object, device: prim.Id) -> (k: [49]u8) {
	s, o, d := space, object, device
	k[0] = SEARCH_KEY_SOURCE
	copy(k[1:17], s[:])
	copy(k[17:33], o[:])
	copy(k[33:], d[:])
	return
}

@(private)
_snap_dir :: proc(e: ^Engine, space: prim.Id, leaf: string) -> (string, Error) {
	hx := prim.id_hex(space)
	return _join(context.temp_allocator, e.pack_root, "search-snap", string(hx[:]), leaf)
}

@(private)
_snap_out :: proc(e: ^Engine, space: prim.Id, oid: [32]u8) -> (path: string, err: Error) {
	o := oid
	hx: [64]u8
	prim.hex_encode(hx[:], o[:])
	dir := _snap_dir(e, space, "out") or_return
	return _join(context.temp_allocator, dir, string(hx[:]))
}

@(private)
_snap_tree :: proc(sp: ^Space, t: ^osync.Key_Tree) -> Error {
	root: [32]u8
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, sp.scope.object_key[:], 32)
	blake2b.update(&ctx, transmute([]u8)string(SNAP_DOMAIN))
	x := sp.id
	blake2b.update(&ctx, x[:])
	blake2b.final(&ctx, root[:])
	defer crypto.zero_explicit(&root, size_of(root))
	return _serr(osync.keytree_init(t, root, osync.OBJECT_TREE_DEPTH, 0))
}

@(private)
_chain_load :: proc(e: ^Engine, space: prim.Id) -> (c: Snap_Chain, found: bool) {
	k := _snap_key(SEARCH_KEY_CHAIN, space)
	v, hit, err := omap.db_get(&e.reg.db, ROOT_SEARCH, k[:], context.temp_allocator)
	c.entries = make([dynamic]Snap_Entry, context.temp_allocator)
	if err != .None || !hit {
		return c, false
	}
	r := prim.reader(v)
	if prim.read_u8(&r) != SNAP_VERSION {
		return c, false
	}
	c.flags = prim.read_u8(&r)
	c.cursor = prim.read_u64le(&r)
	c.text_at = prim.read_u64le(&r)
	c.rec_end = i64(prim.read_u64le(&r))
	c.zero_to = i64(prim.read_u64le(&r))
	c.zeroed = i64(prim.read_u64le(&r))
	n := int(prim.read_u16le(&r))
	for _ in 0 ..< n {
		en: Snap_Entry
		en.lo = prim.read_u64le(&r)
		en.hi = prim.read_u64le(&r)
		en.docs = prim.read_u32le(&r)
		en.text = prim.read_u64le(&r)
		copy(en.oid[:], prim.read_raw(&r, 32))
		en.mine = prim.read_u8(&r) != 0
		append(&c.entries, en)
	}
	if !prim.reader_ok(&r) {
		clear(&c.entries)
		return c, false
	}
	return c, true
}

@(private)
_chain_bytes :: proc(c: ^Snap_Chain) -> []u8 {
	buf := make([dynamic]u8, 0, 48 + SNAP_ENTRY * len(c.entries), context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, SNAP_VERSION)
	prim.write_u8(&w, c.flags)
	prim.write_u64le(&w, c.cursor)
	prim.write_u64le(&w, c.text_at)
	prim.write_u64le(&w, u64(c.rec_end))
	prim.write_u64le(&w, u64(c.zero_to))
	prim.write_u64le(&w, u64(c.zeroed))
	prim.write_u16le(&w, u16(len(c.entries)))
	for en in c.entries {
		prim.write_u64le(&w, en.lo)
		prim.write_u64le(&w, en.hi)
		prim.write_u32le(&w, en.docs)
		prim.write_u64le(&w, en.text)
		o := en.oid
		prim.write_raw(&w, o[:])
		prim.write_u8(&w, 1 if en.mine else 0)
	}
	return buf[:]
}

@(private)
_chain_save :: proc(e: ^Engine, space: prim.Id, c: ^Snap_Chain, sources: []Snap_Source = nil, drop_marker := false) -> Error {
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return _oerr(terr)
	}
	k := _snap_key(SEARCH_KEY_CHAIN, space)
	if err := omap.txn_put(t, ROOT_SEARCH, k[:], _chain_bytes(c)); err != .None {
		omap.txn_abort(t)
		return _oerr(err)
	}
	for s in sources {
		sk := _snap_source_key(space, s.object, s.device)
		v: [16]u8
		prim.put_u64le(v[:8], u64(s.pos))
		prim.put_u64le(v[8:], s.at)
		if err := omap.txn_put(t, ROOT_SEARCH, sk[:], v[:]); err != .None {
			omap.txn_abort(t)
			return _oerr(err)
		}
	}
	if drop_marker {
		mk := _snap_key(SEARCH_KEY_RESTORE, space)
		if _, err := omap.txn_delete(t, ROOT_SEARCH, mk[:]); err != .None {
			omap.txn_abort(t)
			return _oerr(err)
		}
	}
	return _reg_commit(e, t)
}

@(private)
_snap_meta :: proc(entries: []Snap_Entry) -> []u8 {
	buf := make([dynamic]u8, 0, 3 + 44 * len(entries), context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, SNAP_VERSION)
	prim.write_u16le(&w, u16(len(entries)))
	for en in entries {
		o := en.oid
		prim.write_raw(&w, o[:])
		prim.write_u32le(&w, en.docs)
		prim.write_u64le(&w, en.text)
	}
	return buf[:]
}

@(private)
_snap_hash :: proc(e: ^Engine, path: string) -> (oid: [32]u8, err: Error) {
	fd, oerr := prim.open_file(e.vfs, path)
	if oerr != .None {
		return oid, _perr(oerr)
	}
	defer prim.close_file(e.vfs, fd)
	ctx: blake2b.Context
	blake2b.init(&ctx, 32)
	buf := make([]u8, 256 * 1024, context.temp_allocator)
	at := i64(0)
	for {
		n, rerr := prim.read_at(e.vfs, fd, buf, at)
		if rerr != .None {
			return oid, _perr(rerr)
		}
		if n <= 0 {
			break
		}
		blake2b.update(&ctx, buf[:n])
		at += i64(n)
	}
	blake2b.final(&ctx, oid[:])
	return oid, .None
}

@(private)
_snap_source :: proc(e: ^Engine, h: ^Handle, device: prim.Id) {
	if h.kind != .Conversation && h.id != h.sp.catalog {
		return
	}
	if !_full_on(e, h.sp) {
		return
	}
	k := _snap_source_key(h.sp.id, h.id, device)
	_, found, err := omap.db_get(&e.reg.db, ROOT_SEARCH, k[:], context.temp_allocator)
	if err != .None || found {
		return
	}
	v: [16]u8
	_reg_put(e, ROOT_SEARCH, k[:], v[:])
}

@(private)
_snap_keep :: proc(data: rawptr, object: prim.Id, kind: u8, title: bool) -> bool {
	k := (^Snap_Keep)(data)
	if kind != u8(Kind.Conversation) {
		return false
	}
	if k.have && k.last == object {
		return k.last_ok
	}
	rec, found, _ := _rec_get(k.e, object)
	k.have = true
	k.last = object
	k.last_ok = found && rec.space == k.space && rec.kind == .Conversation
	return k.last_ok
}

@(private)
_snap_dirty :: proc(e: ^Engine, sp: ^Space) {
	if sp == nil {
		return
	}
	c, found := _chain_load(e, sp.id)
	if !found || c.flags & SNAP_DIRTY != 0 || len(c.entries) == 0 {
		return
	}
	c.flags |= SNAP_DIRTY
	_chain_save(e, sp.id, &c)
}

@(private)
_snap_redaction_seen :: proc(e: ^Engine, sp: ^Space, stream: osync.Stream_Id, from, to: i64) {
	if !_full_on(e, sp) || to <= from {
		return
	}
	k: [57]u8
	k[0] = SEARCH_KEY_REDACT
	s := sp.id
	copy(k[1:17], s[:])
	st := stream
	copy(k[17:49], st[:])
	prim.put_u64le(k[49:], u64(from))
	v: [8]u8
	prim.put_u64le(v[:], u64(to))
	_reg_put(e, ROOT_SEARCH, k[:], v[:])
}

@(private)
_snap_relay_zeroed :: proc(e: ^Engine, sp: ^Space, object: prim.Id, device: prim.Id, from, to: i64) {
	if !_full_on(e, sp) || !e.index_open {
		return
	}
	src := _source_id(object, device)
	pos, _ := search.position(&e.index, src)
	if search.redact_span(&e.index, src, pos, object, device, u64(from), u64(to)) == .None {
		_snap_dirty(e, sp)
	}
}

@(private)
_snap_settle :: proc(e: ^Engine, sp: ^Space) {
	if !e.index_open || !sp.repl_on || !sp.connected || !sp.mem.have_naming {
		return
	}
	r := _remote(e)
	if sp.id in r.restores {
		return
	}
	for a in r.active {
		if a.space == sp.id {
			return
		}
	}
	c, found := _chain_load(e, sp.id)
	if !found {
		_snap_restore_maybe(e, sp)
		return
	}
	if c.zeroed < c.zero_to {
		if osync.replicator_checkpoint_redact(&sp.repl, &sp.scope, SNAP_HISTORY, c.zeroed, c.zero_to) == .None {
			c.zeroed = c.zero_to
			_chain_save(e, sp.id, &c)
		}
	}
	if c.flags & SNAP_DIRTY != 0 {
		if _snap_rebuild(e, sp, &c) {
			_touch(e)
			return
		}
		c.flags &~= SNAP_DIRTY
		_chain_save(e, sp.id, &c)
	}
	next := search.next_doc(&e.index)
	if next <= c.cursor {
		return
	}
	total := search.text_total(&e.index)
	if total < c.text_at {
		c.text_at = total
	}
	chain_text := u64(0)
	for en in c.entries {
		chain_text += en.text
	}
	min_text := u64(e.cfg.search_snapshot_min if e.cfg.search_snapshot_min > 0 else SNAP_MIN_TEXT)
	if total - c.text_at < max(min_text, chain_text / 8) {
		return
	}
	if _snap_extend(e, sp, &c, next, total) {
		_touch(e)
	}
}

@(private)
_snap_extend :: proc(e: ^Engine, sp: ^Space, c: ^Snap_Chain, next: u64, total: u64) -> (more: bool) {
	dir, derr := _snap_dir(e, sp.id, "x")
	if derr != .None {
		return
	}
	keep := Snap_Keep{e = e, space = sp.id}
	x: search.Export
	if search.export_begin(&x, e.vfs, dir, e.allocator) != .None {
		return
	}
	defer search.export_end(&x)
	stop, xerr := search.export_range(&x, &e.index, c.cursor, next, SNAP_PIECE, _snap_keep, &keep)
	if xerr != .None {
		_log(e, .Warn, "search snapshot export failed")
		return
	}
	k := len(c.entries)
	if stop == next {
		sum := x.text
		for k > 0 && c.entries[k - 1].text <= 2 * sum && c.entries[k - 1].text + sum <= SNAP_PIECE {
			sum += c.entries[k - 1].text
			k -= 1
		}
		if len(c.entries) - (len(c.entries) - k) >= SNAP_MAX && k == len(c.entries) && k > 0 {
			k -= 1
		}
	} else if len(c.entries) >= SNAP_MAX {
		return
	}
	lo := c.cursor
	if k < len(c.entries) {
		search.export_end(&x)
		if search.export_begin(&x, e.vfs, dir, e.allocator) != .None {
			return
		}
		lo = c.entries[k].lo
		keep = Snap_Keep{e = e, space = sp.id}
		stop, xerr = search.export_range(&x, &e.index, lo, next, 0, _snap_keep, &keep)
		if xerr != .None {
			return
		}
	}
	updates := make([dynamic]Snap_Source, context.temp_allocator)
	if stop == next {
		Scan :: struct {
			e:       ^Engine,
			x:       ^search.Export,
			lo:      u64,
			replaced: []Snap_Entry,
			updates: ^[dynamic]Snap_Source,
		}
		visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
			s := (^Scan)(data)
			if len(key) != 49 || len(value) != 16 {
				return true
			}
			object, device: prim.Id
			copy(object[:], key[17:33])
			copy(device[:], key[33:])
			snap := i64(prim.get_u64le(value[:8]))
			at := prim.get_u64le(value[8:])
			pos, _ := search.position(&s.e.index, _source_id(object, device))
			moved := false
			for en in s.replaced {
				if en.lo == at {
					moved = true
				}
			}
			if pos > snap || (moved && snap > 0) {
				search.export_source(s.x, object, device, max(pos, snap))
				append(s.updates, Snap_Source{object = object, device = device, pos = max(pos, snap), at = s.lo})
			}
			return true
		}
		sc := Scan{e = e, x = &x, lo = lo, replaced = c.entries[k:], updates = &updates}
		pfx := _snap_key(SEARCH_KEY_SOURCE, sp.id)
		omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &sc, visit)
	}
	if x.docs == 0 && len(updates) == 0 && k == len(c.entries) {
		c.cursor = stop
		if stop == next {
			c.text_at = total
		}
		_chain_save(e, sp.id, c)
		return stop < next
	}
	buf: search.Name_Buf
	path, ferr := search.export_finish(&x, &buf)
	if ferr != .None {
		return
	}
	en := Snap_Entry{lo = lo, hi = stop, docs = u32(x.docs), text = x.text, mine = true}
	if !_snap_ship(e, sp, path, &en) {
		return
	}
	replaced := make([dynamic]Snap_Entry, context.temp_allocator)
	append(&replaced, ..c.entries[k:])
	resize(&c.entries, k)
	append(&c.entries, en)
	if _snap_publish(e, sp, c, en.oid) != .None {
		if out, oerr := _snap_out(e, sp.id, en.oid); oerr == .None {
			prim.remove(e.vfs, out)
		}
		return
	}
	for old in replaced {
		if old.mine && old.oid != en.oid {
			_snap_shred(e, sp, old.oid)
		}
	}
	c.cursor = stop
	if stop == next {
		c.text_at = total
	}
	_chain_save(e, sp.id, c, updates[:])
	return stop < next
}

@(private)
_snap_ship :: proc(e: ^Engine, sp: ^Space, path: string, en: ^Snap_Entry) -> bool {
	oid, herr := _snap_hash(e, path)
	if herr != .None {
		return false
	}
	en.oid = oid
	dir, derr := _snap_dir(e, sp.id, "out")
	if derr != .None || prim.mkdir_all(e.vfs, dir, 0o700) != .None {
		return false
	}
	out, oerr := _snap_out(e, sp.id, oid)
	if oerr != .None {
		return false
	}
	return prim.rename(e.vfs, path, out) == .None
}

@(private)
_snap_publish :: proc(e: ^Engine, sp: ^Space, c: ^Snap_Chain, oid: [32]u8) -> Error {
	tree: osync.Key_Tree
	_snap_tree(sp, &tree) or_return
	defer osync.keytree_destroy(&tree)
	if c.rec_end == 0 {
		n, lerr := osync.replicator_checkpoint_length(&sp.repl, &sp.scope, SNAP_HISTORY)
		if lerr != .None {
			return _serr(lerr)
		}
		c.rec_end = n
	}
	out := _snap_out(e, sp.id, oid) or_return
	o := oid
	before := c.rec_end
	_serr(osync.replicator_publish_checkpoint(&sp.repl, &sp.scope, &tree, SNAP_HISTORY, u64(hlc_now(e)), o[:], _snap_meta(c.entries[:]), nil, out)) or_return
	after, lerr := osync.replicator_checkpoint_length(&sp.repl, &sp.scope, SNAP_HISTORY)
	if lerr != .None {
		return _serr(lerr)
	}
	c.zero_to = max(c.zero_to, before)
	c.rec_end = after
	_log(e, .Info, fmt.tprintf("search snapshot published: %d entries", len(c.entries)))
	return .None
}

@(private)
_snap_shred :: proc(e: ^Engine, sp: ^Space, oid: [32]u8) {
	tree: osync.Key_Tree
	if _snap_tree(sp, &tree) != .None {
		return
	}
	defer osync.keytree_destroy(&tree)
	o := oid
	osync.replicator_shred_object(&sp.repl, &sp.scope, &tree, o[:])
	if out, err := _snap_out(e, sp.id, oid); err == .None {
		prim.remove(e.vfs, out)
	}
}

@(private)
_snap_rebuild :: proc(e: ^Engine, sp: ^Space, c: ^Snap_Chain) -> bool {
	for i in 0 ..< len(c.entries) {
		old := c.entries[i]
		keep := Snap_Keep{e = e, space = sp.id}
		live, cerr := search.export_count(&e.index, old.lo, old.hi, _snap_keep, &keep)
		if cerr != .None || live >= int(old.docs) {
			continue
		}
		dir, derr := _snap_dir(e, sp.id, "x")
		if derr != .None {
			return false
		}
		x: search.Export
		if search.export_begin(&x, e.vfs, dir, e.allocator) != .None {
			return false
		}
		defer search.export_end(&x)
		keep = Snap_Keep{e = e, space = sp.id}
		if _, xerr := search.export_range(&x, &e.index, old.lo, old.hi, 0, _snap_keep, &keep); xerr != .None {
			return false
		}
		Scan :: struct {
			x:  ^search.Export,
			lo: u64,
		}
		visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
			s := (^Scan)(data)
			if len(key) != 49 || len(value) != 16 || prim.get_u64le(value[8:]) != s.lo {
				return true
			}
			object, device: prim.Id
			copy(object[:], key[17:33])
			copy(device[:], key[33:])
			search.export_source(s.x, object, device, i64(prim.get_u64le(value[:8])))
			return true
		}
		sc := Scan{x = &x, lo = old.lo}
		pfx := _snap_key(SEARCH_KEY_SOURCE, sp.id)
		omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &sc, visit)
		en := Snap_Entry{lo = old.lo, hi = old.hi, docs = u32(x.docs), text = x.text, mine = true}
		buf: search.Name_Buf
		path, ferr := search.export_finish(&x, &buf)
		if ferr == .Not_Found {
			ordered_remove(&c.entries, i)
		} else if ferr != .None || !_snap_ship(e, sp, path, &en) {
			return false
		} else {
			c.entries[i] = en
		}
		if len(c.entries) > 0 {
			if _snap_publish(e, sp, c, c.entries[len(c.entries) - 1].oid) != .None {
				return false
			}
		}
		if en.oid != old.oid {
			_snap_shred(e, sp, old.oid)
		}
		_chain_save(e, sp.id, c)
		return true
	}
	return false
}

@(private)
_snap_kick :: proc(e: ^Engine, sp: ^Space) {
	if !_full_on(e, sp) || !sp.repl_on {
		return
	}
	r := _remote(e)
	if rs, ok := r.restores[sp.id]; ok && !rs.importing {
		delete_key(&r.restores, sp.id)
		_snap_restore_free(e, rs)
	}
	c, found := _chain_load(e, sp.id)
	if !found {
		_snap_restore_maybe(e, sp)
		return
	}
	tree: osync.Key_Tree
	if _snap_tree(sp, &tree) != .None {
		return
	}
	defer osync.keytree_destroy(&tree)
	for en in c.entries {
		if !en.mine {
			continue
		}
		out, err := _snap_out(e, sp.id, en.oid)
		if err == .None && prim.exists(e.vfs, out) {
			o := en.oid
			osync.replicator_put_object_file(&sp.repl, &sp.scope, &tree, o[:], out)
		}
	}
}

@(private)
_snap_object_event :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) -> bool {
	if len(ev.oid) != 32 {
		return false
	}
	oid: [32]u8
	copy(oid[:], ev.oid)
	if ev.kind == .Object_Stored {
		if out, err := _snap_out(e, sp.id, oid); err == .None && prim.exists(e.vfs, out) {
			prim.remove(e.vfs, out)
		}
		return false
	}
	r := &e.remote
	if !r.init {
		return false
	}
	rs, ok := r.restores[sp.id]
	if !ok || rs.importing {
		return false
	}
	for o, i in rs.oids {
		if o != oid || len(rs.paths[i]) > 0 {
			continue
		}
		if ev.kind != .Object_Fetched {
			rs.failed = true
			_touch(e)
			return true
		}
		rs.paths[i], _ = _clone(ev.path, e.allocator)
		rs.pending -= 1
		if rs.pending == 0 {
			rs.importing = true
			_touch(e)
		}
		return true
	}
	return false
}

@(private)
_snap_catalog_fresh :: proc(e: ^Engine, sp: ^Space) -> bool {
	if !e.index_open {
		return false
	}
	if pos, _ := search.position(&e.index, _source_id(sp.catalog, e.self)); pos > 0 {
		return false
	}
	rec, found, _ := _rec_get(e, sp.catalog)
	if !found {
		return true
	}
	for m in rec.members {
		if pos, _ := search.position(&e.index, _source_id(sp.catalog, m.device)); pos > 0 {
			return false
		}
	}
	return true
}

@(private)
_snap_restore_maybe :: proc(e: ^Engine, sp: ^Space) {
	if !_full_on(e, sp) || !sp.repl_on || !sp.connected || !sp.mem.have_naming || _index_open(e) != .None {
		return
	}
	r := _remote(e)
	if sp.id in r.restores {
		return
	}
	if _, found := _chain_load(e, sp.id); found {
		r.decided[sp.id] = true
		return
	}
	mk := _snap_key(SEARCH_KEY_RESTORE, sp.id)
	if _, hit, _ := omap.db_get(&e.reg.db, ROOT_SEARCH, mk[:], context.temp_allocator); hit {
		_snap_recover(e, sp)
	}
	if !r.rebuilt && !_snap_catalog_fresh(e, sp) {
		c := Snap_Chain{entries = make([dynamic]Snap_Entry, context.temp_allocator)}
		if _chain_save(e, sp.id, &c) == .None {
			r.decided[sp.id] = true
			_snap_unpark(e, sp.id)
		}
		return
	}
	rs := new(Snap_Restore, e.allocator)
	rs.e = e
	rs.space = sp.id
	rs.oids = make([dynamic][32]u8, e.allocator)
	rs.paths = make([dynamic]string, e.allocator)
	rs.sources = make([dynamic]Snap_Source, e.allocator)
	rs.local = make(map[prim.Id]bool, e.allocator)
	rs.chain = make([dynamic]Snap_Entry, e.allocator)
	rs.started = prim.clock_mono_ns(e.cfg.clock) / 1_000_000
	dir, derr := _snap_dir(e, sp.id, "in")
	head: string
	herr: Error
	if derr == .None {
		rs.dir, _ = _clone(dir, e.allocator)
		head, herr = _join(context.temp_allocator, dir, "head")
	}
	if derr != .None || herr != .None || prim.mkdir_all(e.vfs, dir, 0o700) != .None || _snap_tree(sp, &rs.tree) != .None {
		_snap_restore_free(e, rs)
		return
	}
	if osync.replicator_fetch_checkpoint(&sp.repl, &sp.scope, &rs.tree, SNAP_HISTORY, head) != .None {
		_snap_restore_free(e, rs)
		return
	}
	r.restores[sp.id] = rs
	e.stats.fetches += 1
	_log(e, .Info, "search snapshot restore started")
}

@(private)
_snap_restore_free :: proc(e: ^Engine, rs: ^Snap_Restore) {
	if sp, ok := e.spaces[rs.space]; ok && sp.repl_on {
		osync.replicator_cancel_checkpoint(&sp.repl, &rs.tree)
	}
	osync.keytree_destroy(&rs.tree)
	for p in rs.paths {
		if len(p) > 0 {
			prim.remove(e.vfs, p)
			delete(p, e.allocator)
		}
	}
	delete(rs.oids)
	delete(rs.paths)
	delete(rs.sources)
	delete(rs.local)
	delete(rs.chain)
	delete(rs.dir, e.allocator)
	delete(rs.head_meta, e.allocator)
	delete(rs.head_oid, e.allocator)
	delete(rs.head_path, e.allocator)
	free(rs, e.allocator)
}

@(private)
_snap_checkpoint_event :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) -> bool {
	want := osync.CHECKPOINT_STREAM + SNAP_HISTORY
	if ev.name != want {
		return false
	}
	r := &e.remote
	if !r.init {
		return true
	}
	rs, found := r.restores[sp.id]
	if !found || rs.head || rs.importing || len(rs.oids) > 0 {
		if ev.kind == .Checkpoint && len(ev.path) > 0 {
			prim.remove(e.vfs, ev.path)
		}
		return true
	}
	rs.head = true
	rs.head_ok = ev.kind == .Checkpoint
	rs.head_meta = make([]u8, len(ev.meta), e.allocator)
	copy(rs.head_meta, ev.meta)
	rs.head_oid = make([]u8, len(ev.oid), e.allocator)
	copy(rs.head_oid, ev.oid)
	rs.head_path, _ = _clone(ev.path, e.allocator)
	_touch(e)
	return true
}

@(private)
_snap_on_head :: proc(e: ^Engine, sp: ^Space, rs: ^Snap_Restore) {
	ok := rs.head_ok
	path := rs.head_path
	if !ok {
		_snap_restore_end(e, sp, rs, false, "no snapshot published")
		return
	}
	rd := prim.reader(rs.head_meta)
	ver := prim.read_u8(&rd)
	n := int(prim.read_u16le(&rd))
	if ver != SNAP_VERSION || n == 0 || n > SNAP_MAX || !prim.reader_ok(&rd) {
		prim.remove(e.vfs, path)
		_snap_restore_end(e, sp, rs, false, "snapshot record unreadable")
		return
	}
	for _ in 0 ..< n {
		o: [32]u8
		copy(o[:], prim.read_raw(&rd, 32))
		_ = prim.read_u32le(&rd)
		_ = prim.read_u64le(&rd)
		append(&rs.oids, o)
		append(&rs.paths, "")
	}
	if !prim.reader_ok(&rd) {
		prim.remove(e.vfs, path)
		_snap_restore_end(e, sp, rs, false, "snapshot record unreadable")
		return
	}
	head: [32]u8
	copy(head[:], rs.head_oid)
	head_used := false
	for o, i in rs.oids {
		if o == head && len(rs.head_oid) == 32 && !head_used {
			rs.paths[i], _ = _clone(path, e.allocator)
			head_used = true
			continue
		}
		dest, derr := _join(context.temp_allocator, rs.dir, _snap_part_name(i))
		if derr != .None {
			_snap_restore_end(e, sp, rs, false, "snapshot path")
			return
		}
		oo := o
		if osync.replicator_get_object(&sp.repl, &sp.scope, &rs.tree, oo[:], dest) != .None {
			_snap_restore_end(e, sp, rs, false, "snapshot fetch could not start")
			return
		}
		rs.pending += 1
	}
	if !head_used {
		prim.remove(e.vfs, path)
	}
	if rs.pending == 0 {
		rs.importing = true
		_touch(e)
	}
}

@(private)
_snap_part_name :: proc(i: int) -> string {
	buf := make([]u8, 12, context.temp_allocator)
	buf[0] = 'p'
	n := 1
	v := i
	digits: [10]u8
	k := 0
	for {
		digits[k] = '0' + u8(v % 10)
		k += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	for k > 0 {
		k -= 1
		buf[n] = digits[k]
		n += 1
	}
	return string(buf[:n])
}

@(private)
_snap_import_step :: proc(e: ^Engine, sp: ^Space, rs: ^Snap_Restore) {
	if rs.next == 0 {
		mk := _snap_key(SEARCH_KEY_RESTORE, sp.id)
		v: [10]u8
		prim.put_u64le(v[:8], search.next_doc(&e.index))
		v[8] = u8(len(rs.paths))
		v[9] = u8(len(rs.paths) >> 8)
		if _reg_put(e, ROOT_SEARCH, mk[:], v[:]) != .None {
			_snap_restore_end(e, sp, rs, false, "marker write failed")
			return
		}
	}
	i := rs.next
	rs.cur_lo = search.next_doc(&e.index)
	res, err := search.import_segment(&e.index, rs.paths[i], _snap_import_keep, _snap_import_source, rs)
	if err != .None {
		_log(e, .Warn, "search snapshot import failed")
		_snap_recover(e, sp)
		_snap_restore_end(e, sp, rs, false, "import failed")
		return
	}
	append(&rs.chain, Snap_Entry{lo = res.first, hi = res.next, docs = u32(res.docs), text = res.text, oid = rs.oids[i]})
	rs.docs += res.docs
	rs.next += 1
	if rs.next < len(rs.paths) {
		_touch(e)
		return
	}
	_snap_sweep(e, sp, rs)
	if ferr := search.flush(&e.index); ferr != .None && ferr != .Busy {
		_snap_recover(e, sp)
		_snap_restore_end(e, sp, rs, false, "index flush failed")
		return
	}
	c := Snap_Chain{entries = make([dynamic]Snap_Entry, context.temp_allocator)}
	append(&c.entries, ..rs.chain[:])
	c.cursor = search.next_doc(&e.index)
	c.text_at = search.text_total(&e.index)
	if _chain_save(e, sp.id, &c, rs.sources[:], true) != .None {
		_snap_recover(e, sp)
		_snap_restore_end(e, sp, rs, false, "registry write failed")
		return
	}
	r := _remote(e)
	r.restore_ms = prim.clock_mono_ns(e.cfg.clock) / 1_000_000 - rs.started
	r.restore_docs = rs.docs
	_snap_restore_end(e, sp, rs, true)
}

@(private)
_snap_local :: proc(rs: ^Snap_Restore, object: prim.Id) -> bool {
	if v, ok := rs.local[object]; ok {
		return v
	}
	found, _ := search.has_content(&rs.e.index, object)
	rs.local[object] = found
	return found
}

@(private)
_snap_import_keep :: proc(data: rawptr, object: prim.Id, kind: u8, title: bool) -> bool {
	rs := (^Snap_Restore)(data)
	if kind != u8(Kind.Conversation) {
		return false
	}
	return title || !_snap_local(rs, object)
}

@(private)
_snap_import_source :: proc(data: rawptr, object: prim.Id, device: prim.Id, pos: i64) {
	rs := (^Snap_Restore)(data)
	e := rs.e
	if object != e.spaces[rs.space].catalog && _snap_local(rs, object) {
		return
	}
	src := _source_id(object, device)
	cur, _ := search.position(&e.index, src)
	if pos > cur {
		search.advance(&e.index, src, pos)
	}
	append(&rs.sources, Snap_Source{object = object, device = device, pos = pos, at = rs.cur_lo})
}

@(private)
_snap_sweep :: proc(e: ^Engine, sp: ^Space, rs: ^Snap_Restore) {
	streams := make(map[osync.Stream_Id]Snap_Source, context.temp_allocator)
	for s in rs.sources {
		if s.object == sp.catalog {
			continue
		}
		sc := _object_scope(sp, s.object)
		streams[osync.stream_id(&sc, s.device, _seg_name(.Conversation, s.object), 0)] = s
		osync.scope_clear(&sc)
	}
	Sweep :: struct {
		e:       ^Engine,
		streams: ^map[osync.Stream_Id]Snap_Source,
		hits:    [dynamic][3]u64,
		srcs:    [dynamic]Snap_Source,
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		w := (^Sweep)(data)
		if len(key) != 57 || len(value) != 8 {
			return true
		}
		st: osync.Stream_Id
		copy(st[:], key[17:49])
		s, ok := w.streams[st]
		if !ok {
			return true
		}
		append(&w.hits, [3]u64{prim.get_u64le(key[49:]), prim.get_u64le(value), 0})
		append(&w.srcs, s)
		return true
	}
	w := Sweep{e = e, streams = &streams, hits = make([dynamic][3]u64, context.temp_allocator), srcs = make([dynamic]Snap_Source, context.temp_allocator)}
	pfx := _snap_key(SEARCH_KEY_REDACT, sp.id)
	omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &w, visit)
	for h, i in w.hits {
		s := w.srcs[i]
		src := _source_id(s.object, s.device)
		pos, _ := search.position(&e.index, src)
		search.redact_span(&e.index, src, pos, s.object, s.device, h[0], h[1])
	}
}

@(private)
_snap_recover :: proc(e: ^Engine, sp: ^Space) {
	mk := _snap_key(SEARCH_KEY_RESTORE, sp.id)
	v, hit, err := omap.db_get(&e.reg.db, ROOT_SEARCH, mk[:], context.temp_allocator)
	if err != .None || !hit || len(v) != 10 || !e.index_open {
		return
	}
	start := prim.get_u64le(v[:8])
	n := int(v[8]) | int(v[9]) << 8
	dir, derr := _snap_dir(e, sp.id, "in")
	if derr != .None {
		return
	}
	Undo :: struct {
		e:     ^Engine,
		space: prim.Id,
		ok:    bool,
	}
	undo :: proc(data: rawptr, object: prim.Id, device: prim.Id, pos: i64) {
		u := (^Undo)(data)
		src := _source_id(object, device)
		search.delete_object(&u.e.index, src, 0, object)
		_index_item_add(u.e, u.space, object, .Conversation)
	}
	u := Undo{e = e, space = sp.id, ok = true}
	paths := make([dynamic]string, context.temp_allocator)
	if head, herr := _join(context.temp_allocator, dir, "head"); herr == .None {
		append(&paths, head)
	}
	for i in 0 ..< n {
		if p, perr := _join(context.temp_allocator, dir, _snap_part_name(i)); perr == .None {
			append(&paths, p)
		}
	}
	for p in paths {
		if prim.exists(e.vfs, p) {
			if search.segment_sources(&e.index, p, undo, &u) != .None {
				u.ok = false
			}
		}
	}
	search.kill_range(&e.index, start, search.next_doc(&e.index))
	if !u.ok {
		search.reset(&e.index)
		_snap_forget_all(e)
		_index_all(e)
	}
	search.erase(&e.index)
	for p in paths {
		prim.remove(e.vfs, p)
	}
	_reg_del(e, ROOT_SEARCH, mk[:])
}

@(private)
_snap_restore_end :: proc(e: ^Engine, sp: ^Space, rs: ^Snap_Restore, ok: bool, why := "") {
	r := _remote(e)
	delete_key(&r.restores, sp.id)
	if ok {
		_log(e, .Info, fmt.tprintf("search snapshot restored: %d entries, %d docs in %d ms", len(rs.chain), rs.docs, prim.clock_mono_ns(e.cfg.clock) / 1_000_000 - rs.started))
	} else {
		_log(e, .Info, fmt.tprintf("search snapshot restore abandoned (%s); indexing from the announce feed", why))
	}
	if !ok {
		c := Snap_Chain{entries = make([dynamic]Snap_Entry, context.temp_allocator)}
		_chain_save(e, sp.id, &c)
	}
	r.decided[sp.id] = true
	_snap_restore_free(e, rs)
	_snap_unpark(e, sp.id)
	_full_kick(e, sp)
	_touch(e)
}

@(private)
_snap_unpark :: proc(e: ^Engine, space: prim.Id) {
	r := &e.remote
	if !r.init {
		return
	}
	for i := 0; i < len(r.parked); {
		if r.parked[i].space == space {
			append(&e.index_dirty, r.parked[i])
			unordered_remove(&r.parked, i)
			continue
		}
		i += 1
	}
	_touch(e)
}

@(private)
_snap_park :: proc(e: ^Engine, it: Index_Item) -> bool {
	if !e.cfg.search {
		return false
	}
	if !e.index_open {
		_index_open(e)
	}
	r := _remote(e)
	if it.space in r.restores {
		append(&r.parked, it)
		return true
	}
	if !r.rebuilt || r.decided[it.space] {
		return false
	}
	sp, ok := e.spaces[it.space]
	if !ok || !_full_on(e, sp) || !sp.repl_on {
		return false
	}
	if _, found := _chain_load(e, it.space); found {
		r.decided[it.space] = true
		return false
	}
	append(&r.parked, it)
	return true
}

@(private)
_snap_forget_all :: proc(e: ^Engine) {
	Collect :: struct {
		keys: [dynamic][]u8,
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		c := (^Collect)(data)
		if len(key) > 0 && (key[0] == SEARCH_KEY_SOURCE || key[0] == SEARCH_KEY_CHAIN || key[0] == SEARCH_KEY_RESTORE) {
			k := make([]u8, len(key), context.temp_allocator)
			copy(k, key)
			append(&c.keys, k)
		}
		return true
	}
	c := Collect{keys = make([dynamic][]u8, context.temp_allocator)}
	for tag in ([?]u8{SEARCH_KEY_SOURCE, SEARCH_KEY_CHAIN, SEARCH_KEY_RESTORE}) {
		pfx := [1]u8{tag}
		omap.db_scan(&e.reg.db, ROOT_SEARCH, pfx[:], pfx[:], &c, visit)
	}
	if len(c.keys) == 0 {
		return
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		_reg_fail(e, _oerr(terr))
		return
	}
	for k in c.keys {
		if _, err := omap.txn_delete(t, ROOT_SEARCH, k); err != .None {
			omap.txn_abort(t)
			_reg_fail(e, .Io)
			return
		}
	}
	_reg_commit(e, t)
}

@(private)
_snap_step :: proc(e: ^Engine) {
	r := &e.remote
	if !r.init || len(r.restores) == 0 {
		return
	}
	for sid in _sorted_keys(r.restores) {
		rs := r.restores[sid]
		sp, ok := e.spaces[sid]
		if !ok || !sp.open {
			delete_key(&r.restores, sid)
			_snap_restore_free(e, rs)
			continue
		}
		if rs.failed {
			_snap_restore_end(e, sp, rs, false, "a snapshot object was missing")
			continue
		}
		if rs.head && len(rs.oids) == 0 && !rs.importing {
			_snap_on_head(e, sp, rs)
			continue
		}
		if rs.importing && _index_open(e) == .None {
			_snap_import_step(e, sp, rs)
		}
	}
}

search_snapshot_info :: proc(e: ^Engine, space: prim.Id) -> (info: Snapshot_Info) {
	context = context_for(e)
	c, found := _chain_load(e, space)
	if found {
		info.entries = len(c.entries)
		info.cursor = c.cursor
		for en in c.entries {
			info.docs += u64(en.docs)
			info.text += en.text
		}
	}
	r := &e.remote
	if r.init {
		_, info.restoring = r.restores[space]
		info.restored = r.restore_docs
		info.restore_ms = r.restore_ms
	}
	return
}

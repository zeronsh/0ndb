package engine

import "core:crypto/blake2b"
import "core:mem/virtual"
import "core:strings"
import "../convo"
import omap "../map"
import "../obj"
import "../pack"
import "../prim"
import osync "../sync"

Map_Field :: omap.Field
Map_Entry :: omap.Entry
Map_Row :: omap.Row
Map_Cursor :: omap.Cursor
Catalog_Entry :: omap.Catalog_Entry
Catalog_Row :: omap.Catalog_Row

@(private)
Catalog_Update :: struct {
	space:       prim.Id,
	kind:        Kind,
	set:         Catalog_Fields,
	created:     bool,
	activity:    bool,
	status:      bool,
	participant: bool,
	title:       string,
	archived:    bool,
	pinned:      bool,
	parent:      obj.Xref,
	workspace:   prim.Id,
	agent:       prim.Id,
	usage:       convo.Usage,
	has_usage:   bool,
	role:        string,
	storage:     Storage_Class,
	remote:      string,
	set_remote:  bool,
	takeover:    Takeover,
	lines:       []u8,
	set_lines:   bool,
}

CATALOG_ROLE :: u32(32)

named_id :: proc(space: prim.Id, name: string, parent: prim.Id = {}) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	blake2b.update(&ctx, transmute([]u8)string("0ndb-named-v1"))
	s, p := space, parent
	blake2b.update(&ctx, s[:])
	blake2b.update(&ctx, p[:])
	blake2b.update(&ctx, transmute([]u8)name)
	blake2b.final(&ctx, id[:])
	id[6] = (id[6] & 0x0f) | 0x80
	return
}

map_named :: proc(e: ^Engine, space: prim.Id, name: string, parent: Object = {}, create := true) -> (o: Object, err: Error) {
	context = context_for(e)
	if len(name) == 0 {
		return o, .Invalid
	}
	o = Object{space, named_id(space, name, parent.id)}
	h := _handle_get(e, o, .Map) or_return
	if !create || h.own {
		return o, .None
	}
	_handle_create_writer(h) or_return
	xref: obj.Xref
	xref.object = parent.id
	_catalog_created(e, h, name, xref, {}, {})
	if u := _catalog_q(e, space, o.id, .Map); u != nil {
		delete(u.role, e.allocator)
		u.role = _clone(name, e.allocator) or_return
	}
	return o, .None
}

catalog_role :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (role: string, err: Error) {
	context = context_for(e)
	sp := _space_open(e, o.space) or_return
	h := _catalog_handle(e, sp) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return "", _wait(e, h, ready)
		}
		return "", merr
	}
	kb: [16]u8
	en, found, gerr := omap.table_get(&h.table, omap.catalog_key(o.id, &kb), context.temp_allocator)
	if gerr != .None {
		return "", _oerr(gerr)
	}
	if !found {
		if (merr == .Missing || _handle_waiting(h, ready.fresh)) && ready.call != nil {
			return "", _wait(e, h, ready)
		}
		return "", .Not_Found
	}
	if v, ok := omap.entry_register(&en, CATALOG_ROLE); ok {
		return _clone(string(v), allocator)
	}
	return "", .None
}

map_create :: proc(e: ^Engine, space: prim.Id, title := "", settings: []u8 = nil) -> (o: Object, err: Error) {
	context = context_for(e)
	o = Object{space, new_id(e)}
	h := _handle_get(e, o, .Map) or_return
	if err = _handle_create_writer(h, {}, settings); err != .None {
		h.create_err = err
		return
	}
	_catalog_created(e, h, title, {}, {}, {})
	return o, .None
}

map_open :: proc(e: ^Engine, o: Object) -> Error {
	context = context_for(e)
	_, err := _handle_get(e, o, .Map)
	return err
}

map_writer :: proc(e: ^Engine, o: Object) -> (w: ^omap.Writer, err: Error) {
	context = context_for(e)
	h := _map_writable(e, o) or_return
	_handle_mark(h)
	return &h.mw, .None
}

map_reapply :: proc(e: ^Engine, o: Object) -> Error {
	context = context_for(e)
	h := _handle_get(e, o, .Map) or_return
	_map_table(e, h) or_return
	_oerr(omap.table_rewind(&h.table)) or_return
	merr := _map_sync(e, h)
	return _damage_busy(e, o.id, merr if merr != .Missing else .None)
}

map_get :: proc(e: ^Engine, o: Object, key: []u8, allocator := context.allocator, ready: Ready = {}) -> (entry: Map_Entry, found: bool, err: Error) {
	context = context_for(e)
	entry, found, err = _map_get(e, o, key, allocator, ready)
	return entry, found, _damage_read(e, o, err, ready)
}

@(private)
_map_get :: proc(e: ^Engine, o: Object, key: []u8, allocator := context.allocator, ready: Ready = {}) -> (entry: Map_Entry, found: bool, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Map) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return entry, false, _wait(e, h, ready)
		}
		return entry, false, merr
	}
	entry, found = _oerr2(omap.table_get(&h.table, key, allocator)) or_return
	if merr == .Missing || _handle_waiting(h, ready.fresh) {
		if ready.call != nil {
			return entry, found, _wait(e, h, ready)
		}
	}
	return entry, found, .None
}

map_scan :: proc(e: ^Engine, o: Object, prefix: []u8, after: ^Map_Cursor, limit: int, allocator := context.allocator, ready: Ready = {}) -> (rows: []Map_Row, more: bool, err: Error) {
	context = context_for(e)
	rows, more, err = _map_scan(e, o, prefix, after, limit, allocator, ready)
	return rows, more, _damage_read(e, o, err, ready)
}

@(private)
_map_scan :: proc(e: ^Engine, o: Object, prefix: []u8, after: ^Map_Cursor, limit: int, allocator := context.allocator, ready: Ready = {}) -> (rows: []Map_Row, more: bool, err: Error) {
	context = context_for(e)
	h := _handle_get(e, o, .Map) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return nil, false, _wait(e, h, ready)
		}
		return nil, false, merr
	}
	r, m, serr := omap.table_scan(&h.table, -1, prefix, after, limit, allocator)
	if serr != .None {
		return nil, false, _oerr(serr)
	}
	if (merr == .Missing || _handle_waiting(h, ready.fresh)) && ready.call != nil {
		return r, m, _wait(e, h, ready)
	}
	return r, m, .None
}

catalog_get :: proc(e: ^Engine, o: Object, allocator := context.allocator, ready: Ready = {}) -> (c: Catalog_Entry, found: bool, err: Error) {
	context = context_for(e)
	sp := _space_open(e, o.space) or_return
	if ready.call != nil && _space_settling(e, sp) {
		return c, false, _space_wait(e, sp, ready, nil)
	}
	if !e.in_tick {
		_catalog_flush(e)
	}
	h := _catalog_handle(e, sp) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return c, false, _wait(e, h, ready)
		}
		return c, false, merr
	}
	c, found = _oerr2(omap.catalog_get(&h.table, o.id, allocator)) or_return
	if !found && (merr == .Missing || _handle_waiting(h, ready.fresh)) && ready.call != nil {
		return c, false, _wait(e, h, ready)
	}
	return c, found, .None
}

catalog_list :: proc(e: ^Engine, space: prim.Id, archived: bool, after: ^Map_Cursor, limit: int, allocator := context.allocator, ready: Ready = {}) -> (rows: []Catalog_Row, more: bool, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	if ready.call != nil && _space_settling(e, sp) {
		return nil, false, _space_wait(e, sp, ready, nil)
	}
	if !e.in_tick {
		_catalog_flush(e)
	}
	h := _catalog_handle(e, sp) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return nil, false, _wait(e, h, ready)
		}
		return nil, false, merr
	}
	r, m, lerr := omap.catalog_list(&h.table, archived, after, limit, allocator)
	if lerr != .None {
		return nil, false, _oerr(lerr)
	}
	if len(r) == 0 && (merr == .Missing || _handle_waiting(h, ready.fresh)) && ready.call != nil {
		return r, m, _wait(e, h, ready)
	}
	return r, m, .None
}

catalog_find :: proc(e: ^Engine, space: prim.Id, text: string, allocator := context.allocator, ready: Ready = {}) -> (rows: []Catalog_Row, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	if ready.call != nil && _space_settling(e, sp) {
		return nil, _space_wait(e, sp, ready, nil)
	}
	if !e.in_tick {
		_catalog_flush(e)
	}
	h := _catalog_handle(e, sp) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return nil, _wait(e, h, ready)
		}
		return nil, merr
	}
	part := strings.to_lower(text, context.temp_allocator)
	out := make([dynamic]Catalog_Row, allocator)
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return nil, .No_Memory
	}
	defer virtual.arena_destroy(&scratch)
	for archived in ([]bool{false, true}) {
		cur: Map_Cursor
		for {
			page, more, lerr := omap.catalog_list(&h.table, archived, &cur, 4096, virtual.arena_allocator(&scratch))
			if lerr != .None {
				return nil, _oerr(lerr)
			}
			for &r in page {
				hx := prim.id_hex(r.object)
				x := string(hx[:])
				if (len(part) > 0 && (strings.has_prefix(x, part) || strings.has_suffix(x, part))) || (len(text) > 0 && r.title == text) {
					m := r
					m.title = strings.clone(r.title, allocator)
					append(&out, m)
				}
			}
			virtual.arena_free_all(&scratch)
			if !more {
				break
			}
		}
	}
	if len(out) == 0 && ready.call != nil && _catalog_behind(e, sp, h, ready.fresh) {
		return nil, _space_wait_on(e, sp, ready, .Catalog)
	}
	return out[:], .None
}

@(private)
_catalog_behind :: proc(e: ^Engine, sp: ^Space, h: ^Handle, fresh: bool) -> bool {
	if !sp.repl_on || !sp.connected {
		return false
	}
	if !osync.replicator_caught_up(&sp.repl) || _handle_waiting(h, fresh) {
		return true
	}
	known := make([dynamic]prim.Id, context.temp_allocator)
	for d in osync.replicator_segments(&sp.repl, &h.scope, h.name, 0) {
		append(&known, prim.Id(d))
	}
	if rec, found, err := _rec_get(e, h.id); err == .None && found {
		for m in rec.members {
			append(&known, m.device)
		}
	}
	for d in known {
		if d == e.self {
			continue
		}
		seg: ^Seg
		for s in h.segs {
			if s.device == d {
				seg = s
			}
		}
		n := osync.replicator_relay_length(&sp.repl, &h.scope, osync.Device_Id(d), h.name, 0)
		if seg == nil || n < 0 {
			return true
		}
		if n > 0 && (!seg.in_view || seg.rep == nil || !_replica_covers(seg.rep, n)) {
			return true
		}
	}
	return false
}

catalog_lines :: proc(e: ^Engine, o: Object, lines: []u8) {
	context = context_for(e)
	u := _catalog_q(e, o.space, o.id, .Conversation)
	if u == nil {
		return
	}
	delete(u.lines, e.allocator)
	u.lines = nil
	if len(lines) > 0 {
		b, aerr := make([]u8, len(lines), e.allocator)
		if aerr != nil {
			return
		}
		copy(b, lines)
		u.lines = b
	}
	u.set_lines = true
}

catalog_status_changed :: proc(e: ^Engine, o: Object) {
	context = context_for(e)
	if u := _catalog_q(e, o.space, o.id, .Conversation); u != nil {
		u.status = true
	}
}

catalog_usage :: proc(e: ^Engine, o: Object, usage: convo.Usage) {
	context = context_for(e)
	u := _catalog_q(e, o.space, o.id, .Conversation)
	if u == nil {
		return
	}
	u.usage.input += usage.input
	u.usage.output += usage.output
	u.usage.cache_read += usage.cache_read
	u.usage.cache_write += usage.cache_write
	u.has_usage = true
	u.activity = true
}

@(private)
_oerr2 :: proc(a: $A, b: $B, err: obj.Error) -> (A, B, Error) {
	return a, b, _oerr(err)
}

@(private)
_map_writable :: proc(e: ^Engine, o: Object) -> (h: ^Handle, err: Error) {
	h = _handle_get(e, o, .Map) or_return
	_handle_refresh(h)
	if err = _handle_create_writer(h); err != .None {
		return h, err
	}
	return h, .None
}

@(private)
_by_key :: proc(data: rawptr, en: ^omap.Entry, out: ^[dynamic]u8) -> bool {
	append(out, ..en.key)
	return true
}

@(private)
_map_table :: proc(e: ^Engine, h: ^Handle) -> Error {
	if h.table_open {
		return .None
	}
	dir := _obj_dir(e, h.id) or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	path := _join(context.temp_allocator, dir, "table") or_return
	if h.id == h.sp.catalog {
		defs := omap.catalog_defs()
		_oerr(omap.table_open(&h.table, e.vfs, path, defs[:], e.allocator)) or_return
	} else {
		_oerr(omap.table_open(&h.table, e.vfs, path, nil, e.allocator)) or_return
	}
	h.table.db.tag_of = _table_tag
	h.table.db.tag_data = e
	h.table_open = true
	return .None
}

@(private)
_table_tag :: proc(data: rawptr) -> u64 {
	e := (^Engine)(data)
	return e.batch_seq + 1
}

@(private)
_table_publish :: proc(e: ^Engine, h: ^Handle) {
	if !h.table_open || !omap.db_pending(&h.table.db) {
		return
	}
	if err := omap.db_publish(&h.table.db, e.durable_seq); err != .None && err != .Busy {
		_fatal(e, _oerr(err))
	}
}

@(private)
_map_own_source :: proc(e: ^Engine, h: ^Handle) -> (src: omap.Source, err: Error) {
	if h.w_open {
		return omap.Source{seg = e.self, reader = &h.mw.core.jr}, .None
	}
	return omap.Source{seg = e.self, upto = _own_stream_len(e, h.id, .Map) or_return}, .None
}

@(private)
_map_own_check :: proc(e: ^Engine, h: ^Handle) -> Error {
	_map_table(e, h) or_return
	own := _map_own_source(e, h) or_return
	sources := [1]omap.Source{own}
	return _oerr(omap.table_prepare(&h.table, sources[:]))
}

@(private)
_map_sync :: proc(e: ^Engine, h: ^Handle) -> Error {
	_map_table(e, h) or_return
	_handle_refresh(h)
	if h.own && !h.w_open {
		h.damaged = !_damage_lost(e, h)
		return .Corrupt
	}
	if h.w_open {
		if cerr := omap.writer_commit(&h.mw); cerr != .None && cerr != .Busy {
			return _oerr(cerr)
		}
	}
	sources := make([dynamic]omap.Source, context.temp_allocator)
	append(&sources, _map_own_source(e, h) or_return)
	for s in h.segs {
		if s.in_view {
			append(&sources, omap.Source{seg = s.device, reader = &s.jr})
		}
	}
	own_bad := false
	for _ in 0 ..< 2 {
		_oerr(omap.table_prepare(&h.table, sources[:])) or_return
		missing := false
		for s in h.segs {
			if !s.in_view {
				missing = true
			}
		}
		for src, i in sources {
			if src.reader == nil {
				continue
			}
			at, err := omap.table_apply(&h.table, src.seg, src.reader)
			if err == .Missing {
				missing = true
				if h.sp.repl_on {
					for s in h.segs {
						if s.device == src.seg {
							_follow(e, h, s, true)
						}
					}
				}
			} else if err != .None {
				if i == 0 && err == .Corrupt {
					own_bad = true
					_damage_note(e, h.sp.id, h.id, .Map, at)
					break
				}
				if h.w_open && i == 0 && !omap.table_poisoned(&h.table) {
					return _oerr(err)
				}
				if !_store_err(e, _oerr(err)) {
					_log(e, .Warn, "map apply failed")
				}
			}
		}
		if own_bad {
			h.damaged = !_damage_lost(e, h)
			_oerr(omap.table_reset(&h.table)) or_return
			return .Corrupt
		}
		if !omap.table_poisoned(&h.table) {
			h.damaged = false
			return .Missing if missing else .None
		}
	}
	return .Io
}

@(private)
_map_put :: proc(e: ^Engine, h: ^Handle, key: []u8, fields: []omap.Field) -> (off: i64, err: Error) {
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		return 0, merr
	}
	en, found, gerr := omap.table_get(&h.table, key, context.temp_allocator)
	if gerr != .None {
		return 0, _oerr(gerr)
	}
	if found {
		omap.observe_entry(&h.mw, &en)
	}
	o, x := omap.put(&h.mw, key, fields)
	return o, _oerr(x)
}

@(private)
_map_observed :: proc(e: ^Engine, h: ^Handle, key: []u8, tag: u32, element: []u8) -> (observed: []omap.Dot, err: Error) {
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		return nil, merr
	}
	en, found, gerr := omap.table_get(&h.table, key, context.temp_allocator)
	if gerr != .None {
		return nil, _oerr(gerr)
	}
	if !found {
		return nil, .None
	}
	for el in en.elements {
		if el.tag == tag && string(el.value) == string(element) {
			return el.live, .None
		}
	}
	return nil, .None
}

@(private)
_follow :: proc(e: ^Engine, h: ^Handle, s: ^Seg, full: bool) {
	if s.follow || !h.sp.repl_on {
		return
	}
	s.follow = true
	osync.replicator_follow(&h.sp.repl, &h.scope, s.device, h.name, 0, full)
}

@(private)
_catalog_handle :: proc(e: ^Engine, sp: ^Space) -> (h: ^Handle, err: Error) {
	h = _handle_get(e, Object{sp.id, sp.catalog}, .Map) or_return
	_map_table(e, h) or_return
	return h, .None
}

@(private)
_catalog_follow :: proc(e: ^Engine, sp: ^Space) {
	name := _seg_name(.Map, sp.catalog)
	osync.replicator_follow_segments(&sp.repl, &sp.scope, name, 0, true)
}

@(private)
_catalog_table_close :: proc(sp: ^Space) {
	e := sp.e
	if h, ok := e.handles[sp.catalog]; ok && h.pins == 0 && h.table_open {
		omap.table_close(&h.table)
		h.table_open = false
	}
}

@(private)
_catalog_q :: proc(e: ^Engine, space: prim.Id, id: prim.Id, kind: Kind) -> ^Catalog_Update {
	if sp, ok := e.spaces[space]; ok && (sp.catalog == id || !_catalog_writable(sp)) {
		return nil
	}
	if u, ok := e.catalog_q[id]; ok {
		return u
	}
	u := new(Catalog_Update, e.allocator)
	u.space = space
	u.kind = kind
	e.catalog_q[id] = u
	_touch(e)
	return u
}

@(private)
_catalog_created :: proc(e: ^Engine, h: ^Handle, title: string, parent: obj.Xref, workspace: prim.Id, agent: prim.Id) {
	u := _catalog_q(e, h.sp.id, h.id, h.kind)
	if u == nil {
		return
	}
	u.created = true
	u.activity = true
	u.participant = true
	u.status = h.kind == .Conversation
	if len(title) > 0 {
		delete(u.title, e.allocator)
		u.title, _ = _clone(title, e.allocator)
		u.set += {.Title}
	}
	if !prim.id_is_zero(parent.object) {
		u.parent = parent
		u.set += {.Parent}
	}
	if !prim.id_is_zero(workspace) {
		u.workspace = workspace
		u.set += {.Workspace}
	}
	if !prim.id_is_zero(agent) {
		u.agent = agent
		u.set += {.Agent}
	}
}

@(private)
_catalog_activity :: proc(e: ^Engine, h: ^Handle) {
	u := _catalog_q(e, h.sp.id, h.id, h.kind)
	if u == nil {
		return
	}
	u.activity = true
	u.status = h.kind == .Conversation
}

@(private)
_catalog_writable :: proc(sp: ^Space) -> bool {
	if !sp.keyless {
		return true
	}
	a, ok := sp.grant_access[sp.catalog]
	return ok && .Write in a
}

@(private)
_catalog_participant :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind) {
	u := _catalog_q(e, sp.id, id, kind)
	if u == nil {
		return
	}
	u.participant = true
}

@(private)
_catalog_set :: proc(e: ^Engine, c: Cmd_Catalog_Set) -> Error {
	_space_open(e, c.object.space) or_return
	kind := Kind.Conversation
	if rec, found, _ := _rec_get(e, c.object.id); found {
		kind = rec.kind
	}
	u := _catalog_q(e, c.object.space, c.object.id, kind)
	if u == nil {
		return .Invalid
	}
	u.set += c.set
	if .Title in c.set {
		delete(u.title, e.allocator)
		u.title = _clone(c.title, e.allocator) or_return
	}
	if .Archived in c.set {
		u.archived = c.archived
	}
	if .Pinned in c.set {
		u.pinned = c.pinned
	}
	if .Parent in c.set {
		u.parent = c.parent
	}
	if .Workspace in c.set {
		u.workspace = c.workspace
	}
	if .Agent in c.set {
		u.agent = c.agent
	}
	if .Storage in c.set {
		u.storage = c.storage
	}
	if .Takeover in c.set {
		u.takeover = c.takeover
	}
	return .None
}

@(private)
_catalog_flush :: proc(e: ^Engine) {
	if len(e.catalog_q) == 0 {
		return
	}
	q := e.catalog_q
	e.catalog_q = make(map[prim.Id]^Catalog_Update, e.allocator)
	defer delete(q)
	for id in _sorted_keys(q) {
		u := q[id]
		err := _catalog_write(e, id, u)
		if err == .Busy {
			if _, dup := e.catalog_q[id]; !dup {
				e.catalog_q[id] = u
				continue
			}
		} else if err == .Corrupt {
			if _, dup := e.catalog_parked[id]; !dup {
				e.catalog_parked[id] = u
				continue
			}
		} else if err == .Permission {
			e.stats.catalog_refused += 1
		} else if err != .None {
			_fatal(e, err)
		}
		_catalog_update_free(e, u)
	}
}

@(private)
_catalog_unpark :: proc(e: ^Engine) {
	if len(e.catalog_parked) == 0 {
		return
	}
	for id, u in e.catalog_parked {
		if _, dup := e.catalog_q[id]; dup {
			_catalog_update_free(e, u)
		} else {
			e.catalog_q[id] = u
		}
	}
	clear(&e.catalog_parked)
	_touch(e)
}

@(private)
_catalog_update_free :: proc(e: ^Engine, u: ^Catalog_Update) {
	delete(u.title, e.allocator)
	delete(u.role, e.allocator)
	delete(u.remote, e.allocator)
	delete(u.lines, e.allocator)
	free(u, e.allocator)
}

@(private)
_catalog_reconcile :: proc(e: ^Engine) {
	if !e.pk_open || !pack.unclean(&e.pk) || !e.reg.open {
		return
	}
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if e.reg.cat_done[id] || !sp.open || sp.keyless {
			continue
		}
		e.reg.cat_done[id] = true
		_catalog_reconcile_space(e, sp)
	}
}

@(private)
_catalog_reconcile_space :: proc(e: ^Engine, sp: ^Space) {
	objects, err := _reg_collect(e, ROOT_OBJECTS)
	if err != .None {
		_fatal(e, err)
		return
	}
	h: ^Handle
	for &f in objects {
		if f.klen != 16 {
			continue
		}
		rec, derr := _rec_decode(f.value, context.temp_allocator)
		if derr != .None || !rec.own || rec.space != sp.id {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[:16])
		if id == sp.catalog {
			continue
		}
		if _, queued := e.catalog_q[id]; queued {
			continue
		}
		if n, lerr := _own_stream_len(e, id, rec.kind); lerr != .None || n == 0 {
			continue
		}
		if h == nil {
			hh, herr := _catalog_handle(e, sp)
			if herr != .None {
				return
			}
			if merr := _map_sync(e, hh); merr != .None && merr != .Missing {
				return
			}
			h = hh
		}
		_, found, gerr := omap.catalog_get(&h.table, id, context.temp_allocator)
		if gerr != .None || found {
			continue
		}
		u := _catalog_q(e, sp.id, id, rec.kind)
		if u == nil {
			continue
		}
		u.created = true
		u.participant = true
		u.status = rec.kind == .Conversation
	}
}

@(private)
_catalog_write :: proc(e: ^Engine, id: prim.Id, u: ^Catalog_Update) -> Error {
	sp := _space_open(e, u.space) or_return
	h := _catalog_handle(e, sp) or_return
	_handle_create_writer(h) or_return
	fields := make([dynamic]omap.Field, context.temp_allocator)
	if u.created {
		append(&fields, omap.field_u64(u32(omap.Catalog_Tag.Kind), u64(u.kind)))
		append(&fields, omap.field_bool(u32(omap.Catalog_Tag.Archived), false))
		append(&fields, omap.field_bool(u32(omap.Catalog_Tag.Pinned), false))
	}
	if .Title in u.set {
		append(&fields, omap.field_str(u32(omap.Catalog_Tag.Title), u.title))
	}
	if .Parent in u.set {
		b := make([dynamic]u8, context.temp_allocator)
		w := prim.writer(&b)
		prim.write_id(&w, u.parent.object)
		prim.write_id(&w, u.parent.rid.seg)
		prim.write_uvarint(&w, u64(max(u.parent.rid.off, 0)))
		prim.write_uvarint(&w, u.parent.rid.gen)
		append(&fields, omap.Field{tag = u32(omap.Catalog_Tag.Parent), value = b[:]})
	}
	if .Workspace in u.set {
		append(&fields, omap.field_id(u32(omap.Catalog_Tag.Workspace), u.workspace))
	}
	if .Agent in u.set {
		append(&fields, omap.field_id(u32(omap.Catalog_Tag.Agent), u.agent))
	}
	if .Archived in u.set {
		append(&fields, omap.field_bool(u32(omap.Catalog_Tag.Archived), u.archived))
	}
	if .Pinned in u.set {
		append(&fields, omap.field_bool(u32(omap.Catalog_Tag.Pinned), u.pinned))
	}
	if .Storage in u.set {
		append(&fields, omap.field_u64(u32(omap.Catalog_Tag.Storage), u64(u.storage)))
	}
	if .Takeover in u.set {
		append(&fields, omap.field_u64(u32(omap.Catalog_Tag.Takeover), u64(u.takeover)))
	}
	if u.activity {
		append(&fields, omap.field_u64(u32(omap.Catalog_Tag.Activity), u64(_wall_ms(e))))
	}
	if len(u.role) > 0 {
		append(&fields, omap.field_str(CATALOG_ROLE, u.role))
	}
	if u.set_remote {
		append(&fields, omap.field_str(CATALOG_REMOTE, u.remote))
	}
	if u.set_lines {
		append(&fields, omap.Field{tag = u32(omap.Catalog_Tag.Lines), value = u.lines})
	}
	cur: omap.Catalog_Entry
	found := false
	if u.participant || (u.status && u.kind == .Conversation) {
		_map_sync(e, h)
		cur, found, _ = omap.catalog_get(&h.table, id, context.temp_allocator)
	}
	if u.status && u.kind == .Conversation {
		if ch, err := _handle_get(e, Object{u.space, id}, .Conversation); err == .None {
			_handle_refresh(ch)
			t, terr := convo.view_tail(&ch.view, e.self, context.temp_allocator)
			if terr == .None {
				if !found || cur.status != u64(t.status) {
					append(&fields, omap.field_u64(u32(omap.Catalog_Tag.Status), u64(t.status)))
				}
				if prov, waiting, pok := _catalog_provider(e, Object{u.space, id}, ch, &t); pok {
					if prov != cur.provider {
						append(&fields, omap.field_str(u32(omap.Catalog_Tag.Provider), prov))
					}
					if waiting != cur.unanswered {
						append(&fields, omap.field_bool(u32(omap.Catalog_Tag.Unanswered), waiting))
					}
				}
			}
		}
	}
	kb: [16]u8
	key := omap.catalog_key(id, &kb)
	if len(fields) > 0 {
		_map_put(e, h, key, fields[:]) or_return
	}
	if u.has_usage {
		parts := [4]u64{u.usage.input, u.usage.output, u.usage.cache_read, u.usage.cache_write}
		for v, i in parts {
			if v > 0 {
				_oerr2b(omap.count(&h.mw, key, USAGE_TAG + u32(i), i64(min(v, u64(max(i64)))))) or_return
			}
		}
	}
	if u.participant {
		present := false
		if found {
			for p in cur.participants {
				present ||= p == e.self
			}
		}
		if !present {
			s := e.self
			_, aerr := omap.add(&h.mw, key, u32(omap.Catalog_Tag.Participants), s[:])
			_oerr(aerr) or_return
		}
	}
	_handle_mark(h)
	return .None
}

@(private)
_catalog_provider :: proc(e: ^Engine, o: Object, h: ^Handle, t: ^convo.Tail) -> (provider: string, unanswered: bool, ok: bool) {
	if head, herr := convo.tail_head(&h.view, t); herr == .None && !obj.rid_none(head) {
		m, merr := convo.message(&h.view, t, convo.Position{msg = head}, context.temp_allocator)
		if merr != .None {
			return "", false, false
		}
		if m.role == .User || m.role == .System {
			unanswered = !m.open && m.status == .Done
			if len(m.provider) > 0 {
				return m.provider, unanswered, true
			}
		}
	}
	s, serr := convo_settings(e, o, context.temp_allocator)
	if serr != .None {
		return "", false, false
	}
	return s.provider, unanswered, true
}

USAGE_TAG :: u32(64)

catalog_usage_get :: proc(e: ^Engine, o: Object, ready: Ready = {}) -> (u: convo.Usage, err: Error) {
	context = context_for(e)
	sp := _space_open(e, o.space) or_return
	h := _catalog_handle(e, sp) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		if merr == .Corrupt && h.damaged && ready.call != nil {
			return u, _wait(e, h, ready)
		}
		return u, merr
	}
	kb: [16]u8
	en, found, gerr := omap.table_get(&h.table, omap.catalog_key(o.id, &kb), context.temp_allocator)
	if gerr != .None {
		return u, _oerr(gerr)
	}
	if !found {
		return u, .Not_Found
	}
	vals: [4]u64
	for i in 0 ..< 4 {
		v, _ := omap.counter_value(&en, USAGE_TAG + u32(i))
		vals[i] = u64(max(v, 0))
	}
	return convo.Usage{input = vals[0], output = vals[1], cache_read = vals[2], cache_write = vals[3]}, .None
}

@(private)
_catalog_members :: proc(e: ^Engine, h: ^Handle) {
	sp := h.sp
	if h.id == sp.catalog {
		return
	}
	ch, err := _catalog_handle(e, sp)
	if err != .None {
		return
	}
	_map_sync(e, ch)
	c, found, gerr := omap.catalog_get(&ch.table, h.id, context.temp_allocator)
	if gerr != .None || !found {
		return
	}
	h.cat_known = true
	for p in c.participants {
		if p != e.self {
			_member_seen(e, sp, h.id, h.kind, p)
			_handle_add_member(h, p, 0)
		}
	}
}

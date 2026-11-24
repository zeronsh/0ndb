package engine

import "../journal"
import "../pack"
import "../prim"
import osync "../sync"

@(private)
Damaged :: struct {
	space:  prim.Id,
	object: prim.Id,
	kind:   Kind,
	stream: osync.Stream_Id,
	at:     i64,
}

@(private)
Check :: struct {
	object:   prim.Id,
	space:    prim.Id,
	tree:     ^Own_Tree,
	done:     bool,
	restored: bool,
	peer:     bool,
	at:       i64,
	to:       i64,
	kind:     Kind,
}

@(private)
Restore :: struct {
	space:  prim.Id,
	object: prim.Id,
	stream: osync.Stream_Id,
}

@(private)
_on_damage :: proc(data: rawptr, at: i64) {
	h := (^Handle)(data)
	_damage_note(h.e, h.sp.id, h.id, h.kind, at)
}

@(private)
_damage_note :: proc(e: ^Engine, space, object: prim.Id, kind: Kind, at: i64) {
	sp, ok := e.spaces[space]
	if !ok {
		return
	}
	sc := _object_scope(sp, object)
	stream := osync.stream_id(&sc, e.self, _seg_name(kind, object), 0)
	osync.scope_clear(&sc)
	if _, busy := e.checks[stream]; busy {
		return
	}
	for &d in e.damaged {
		if d.stream == stream {
			d.at = min(d.at, at)
			return
		}
	}
	e.stats.damaged += 1
	append(&e.damaged, Damaged{space, object, kind, stream, at})
	_touch(e)
}

scrub :: proc(e: ^Engine) -> (found: int, err: Error) {
	context = context_for(e)
	own := own_lengths(e, context.temp_allocator) or_return
	for o in own {
		at := _first_damage(e, o.object, o.kind, o.durable) or_return
		if at >= 0 {
			found += 1
			if c, ok := e.checks[o.stream]; ok && c.done {
				delete_key(&e.checks, o.stream)
			}
			_damage_note(e, o.space, o.object, o.kind, at)
		}
	}
	return
}

@(private)
_first_damage :: proc(e: ^Engine, object: prim.Id, kind: Kind, durable: i64) -> (at: i64, err: Error) {
	path := _own_stream_path(e, object, kind) or_return
	fd, oerr := prim.open_file(e.vfs, path)
	if oerr != .None {
		return -1, .None
	}
	defer prim.close_file(e.vfs, fd)
	head: [journal.HEADER]u8
	off: i64
	for off < durable {
		if durable - off < journal.OVERHEAD {
			return off, .None
		}
		if n, rerr := prim.read_at(e.vfs, fd, head[:], off); rerr != .None || n != len(head) {
			return off, .None
		}
		size := i64(prim.get_u32le(head[:])) + journal.OVERHEAD
		if size > durable - off || size > journal.MAX_BODY + journal.OVERHEAD {
			return off, .None
		}
		rec := make([]u8, int(size), context.temp_allocator)
		if n, rerr := prim.read_at(e.vfs, fd, rec, off); rerr != .None || i64(n) != size {
			return off, .None
		}
		kind := journal.classify(rec, off)
		delete(rec, context.temp_allocator)
		if kind != .Plain && kind != .Redacted {
			return off, .None
		}
		off += size
	}
	return -1, .None
}

@(private)
_damage_end :: proc(e: ^Engine, object: prim.Id, kind: Kind, at: i64, durable: i64) -> i64 {
	limit := min(durable, at + 256 << 10)
	path, perr := _own_stream_path(e, object, kind)
	if perr != .None {
		return limit
	}
	fd, oerr := prim.open_file(e.vfs, path)
	if oerr != .None {
		return limit
	}
	defer prim.close_file(e.vfs, fd)
	head: [journal.HEADER]u8
	if n, rerr := prim.read_at(e.vfs, fd, head[:], at); rerr != .None || n != len(head) {
		return limit
	}
	size := i64(prim.get_u32le(head[:])) + journal.OVERHEAD
	if size <= journal.OVERHEAD || size > durable - at || size > 256 << 10 {
		return limit
	}
	return at + size
}

@(private)
_damage_step :: proc(e: ^Engine) {
	if len(e.damaged) == 0 {
		return
	}
	list := e.damaged
	e.damaged = make([dynamic]Damaged, e.allocator)
	defer delete(list)
	for d in list {
		sp, ok := e.spaces[d.space]
		if !ok || !sp.open || !sp.repl_on || sp.keyless {
			continue
		}
		path, perr := _own_stream_path(e, d.object, d.kind)
		if perr != .None {
			e.checks[d.stream] = Check{object = d.object, space = d.space, done = true}
			continue
		}
		durable, derr := pack.durable_size(&e.pk, path)
		at := i64(-1)
		if derr == .None {
			at, _ = _first_damage(e, d.object, d.kind, durable)
		}
		if at < 0 {
			e.checks[d.stream] = Check{object = d.object, space = d.space, done = true}
			continue
		}
		sc := _object_scope(sp, d.object)
		c := Check{object = d.object, space = d.space, kind = d.kind, at = at, to = _damage_end(e, d.object, d.kind, at, durable)}
		if _storage_class(e, sp, d.object, d.kind) == .Device {
			c.peer = true
			_log(e, .Warn, "own stream damaged on disk; asking the devices that hold it")
		} else {
			_log(e, .Warn, "own stream damaged on disk; checking it against the relay copy")
		}
		if sp.mode != .Transparent {
			if t, terr := _own_tree_get(e, sp, d.object, d.kind, &sc, false); terr == .None {
				c.tree = t
			}
		}
		e.checks[d.stream] = c
		tree := &c.tree.tree if c.tree != nil else nil
		err: osync.Error
		if c.peer {
			err = osync.replicator_recheck_peers(&sp.repl, &sc, _seg_name(d.kind, d.object), 0, path, c.at, c.to, tree)
		} else {
			err = osync.replicator_recheck(&sp.repl, &sc, _seg_name(d.kind, d.object), 0, path, at, tree)
		}
		if err != .None {
			_log(e, .Warn, "own stream recheck failed")
			_check_release(e, d.stream)
		}
		osync.scope_clear(&sc)
	}
}

@(private)
_check_release :: proc(e: ^Engine, stream: osync.Stream_Id) {
	c, ok := &e.checks[stream]
	if !ok || c.done {
		return
	}
	if !c.restored && !c.peer {
		if sp, sok := e.spaces[c.space]; sok && sp.open && sp.repl_on {
			c.peer = true
			path, perr := _own_stream_path(e, c.object, c.kind)
			sc := _object_scope(sp, c.object)
			defer osync.scope_clear(&sc)
			if perr == .None && osync.replicator_recheck_peers(&sp.repl, &sc, _seg_name(c.kind, c.object), 0, path, c.at, c.to, &c.tree.tree if c.tree != nil else nil) == .None {
				_log(e, .Warn, "own stream not restored from the relay copy; asking the devices that hold it")
				return
			}
		}
	}
	if c.tree != nil {
		_own_tree_unref(e, c.tree)
		c.tree = nil
	}
	if c.restored {
		delete_key(&e.checks, stream)
		return
	}
	c.done = true
	for mk3_ in prim.sorted_keys(e.handles) {
		if mk3_ not_in e.handles {
			continue
		}
		h := e.handles[mk3_]
		if h.damaged && osync.stream_id(&h.scope, e.self, h.name, 0) == stream {
			h.damaged = false
		}
	}
	_object_changed(e, c.space, c.object, .Data)
}

@(private)
_damage_pending :: proc(e: ^Engine, object: prim.Id) -> bool {
	for d in e.damaged {
		if d.object == object {
			return true
		}
	}
	for mk2_ in prim.sorted_keys(e.checks) {
		if mk2_ not_in e.checks {
			continue
		}
		c := e.checks[mk2_]
		if c.object == object && !c.done {
			return true
		}
	}
	return false
}

@(private)
_damage_busy :: proc(e: ^Engine, object: prim.Id, err: Error) -> Error {
	if err == .Corrupt && _damage_pending(e, object) {
		return .Busy
	}
	return err
}

@(private)
_damage_read :: proc(e: ^Engine, o: Object, err: Error, ready: Ready) -> Error {
	if (err != .Corrupt && err != .Not_Found) || !_damage_pending(e, o.id) {
		return err
	}
	if ready.call == nil {
		return .Busy
	}
	w := new(Waiter, e.allocator)
	w.space = o.space
	w.object = o.id
	w.ready = ready
	w.tick = e.tick
	append(&e.waiters, w)
	return .Pending
}

@(private)
_damage_park :: proc(e: ^Engine, o: Object, p: ^Pending_Cmd, tries: int) -> bool {
	if !_damage_pending(e, o.id) {
		return false
	}
	w := new(Waiter, e.allocator)
	w.space = o.space
	w.object = o.id
	w.cmd = p
	w.tries = tries
	w.tick = e.tick
	append(&e.waiters, w)
	return true
}

@(private)
_damage_lost :: proc(e: ^Engine, h: ^Handle) -> bool {
	c, ok := e.checks[osync.stream_id(&h.scope, e.self, h.name, 0)]
	return ok && c.done && !c.restored
}

@(private)
_local_restore :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	err := _restore_record(e, sp, ev)
	if err != .None {
		_log(e, .Error, "own stream record could not be restored from the relay copy")
		osync.replicator_restored(&sp.repl, ev.stream, .Corrupt)
		return
	}
	_log(e, .Warn, "own stream record restored from the relay copy")
	e.stats.restored += 1
	if c, ok := &e.checks[ev.stream]; ok {
		c.restored = true
	}
	id, _, _ := _object_of_name(ev.name)
	append(&e.restores, Restore{sp.id, id, ev.stream})
	_touch(e)
}

@(private)
_restore_record :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) -> Error {
	id, kind, ok := _object_of_name(ev.name)
	if !ok || !e.pk_open {
		return .Corrupt
	}
	if journal.classify(ev.meta, ev.from) != .Redacted && _redaction_known(e, sp.id, id, ev.from) {
		_jerr(journal.redact_bytes(ev.meta, ev.from)) or_return
	}
	if h, hok := e.handles[id]; hok && h.w_open && h.sp == sp {
		if j := _own_journal(h); j != nil {
			return _jerr(journal.journal_restore(j, ev.from, ev.meta))
		}
	}
	path := _own_stream_path(e, id, kind) or_return
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	floor, ferr := osync.replicator_floor(&sp.repl, &sc, _seg_name(kind, id), 0)
	if ferr != .None {
		return _serr(ferr)
	}
	j: journal.Journal
	_jerr(journal.journal_open(&j, e.vfs, path, journal.Options{keep_at_least = floor}, context.allocator)) or_return
	rerr := journal.journal_restore(&j, ev.from, ev.meta)
	journal.journal_close(&j)
	if h, hok := e.handles[id]; hok && h.sp == sp {
		if hj := _own_journal(h); hj != nil {
			hj.version += 1
		}
	}
	return _jerr(rerr)
}

@(private)
_redaction_known :: proc(e: ^Engine, space, object: prim.Id, off: i64) -> bool {
	if !_rlog_ready(e) {
		return false
	}
	s, o := space, object
	for kk in prim.sorted_keys(e.rlog.live) {
		if kk not_in e.rlog.live {
			continue
		}
		x := e.rlog.live[kk]
		k := kk
		if int(k[56]) != 40 || string(k[:16]) != string(s[:]) || string(k[16:32]) != string(o[:]) {
			continue
		}
		from := i64(prim.get_u64le(k[32:40]))
		if from <= off && off < x.to {
			return true
		}
	}
	return false
}

@(private)
_own_journal :: proc(h: ^Handle) -> ^journal.Journal {
	if !h.w_open {
		return nil
	}
	#partial switch h.kind {
	case .Conversation:
		return &h.cw.core.j
	case .Map:
		return &h.mw.core.j
	case .Text, .File_Tree:
		if h.hist != nil {
			return &h.hist.journal
		}
	}
	return nil
}

@(private)
_restore_redrive :: proc(e: ^Engine, x: Restore) {
	sp, ok := e.spaces[x.space]
	if !ok || !sp.open {
		return
	}
	if sp.repl_on {
		_pending_republish_one(e, sp, x.object)
	}
	rec, found, err := _rec_get(e, x.object)
	if err != .None || !found || (rec.kind != .Map && rec.kind != .Conversation) {
		return
	}
	if h, herr := _handle_get(e, Object{sp.id, x.object}, rec.kind); herr == .None {
		_derived_purge(e, h)
	}
}

@(private)
_restores_durable :: proc(e: ^Engine, list: []Restore) {
	if len(list) > 0 {
		_catalog_unpark(e)
	}
	for x in list {
		if sp, ok := e.spaces[x.space]; ok && sp.repl_on {
			osync.replicator_restored(&sp.repl, x.stream, .None)
		}
		if h, ok := e.handles[x.object]; ok {
			h.damaged = false
		}
		_restore_redrive(e, x)
		_object_changed(e, x.space, x.object, .Data)
	}
}

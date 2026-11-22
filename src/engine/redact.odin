package engine

import "core:crypto"
import "../convo"
import "../crdt"
import "../fs"
import "../journal"
import omap "../map"
import "../obj"
import "../odb"
import "../prim"
import "../search"
import osync "../sync"

@(private)
ROOT_REDACT :: 4

text_redact :: proc(e: ^Engine, o: Object, pos: int, n: int) -> Error {
	context = context_for(e)
	h := _handle_get(e, o, .Text) or_return
	_handle_create_writer(h) or_return
	_hist_catch_up(e, h)
	inode, found := _text_inode(h) or_return
	if !found {
		return .Missing
	}
	f := _ferr2(fs.history_file(h.hist, inode)) or_return
	spans := crdt.text_spans(&f.text, &h.hist.g, context.temp_allocator)
	ops := make([dynamic]crdt.Op_Span, context.temp_allocator)
	at := 0
	for s in spans {
		end := at + s.len
		lo := max(at, pos)
		hi := min(end, pos + n)
		if lo < hi {
			append(&ops, crdt.Op_Span{id = crdt.Op_Id{s.op.actor, s.op.seq + u64(lo - at)}, len = hi - lo})
		}
		at = end
	}
	if len(ops) == 0 {
		return .None
	}
	ctx := Text_Plan{e = e, h = h}
	res, rerr := fs.history_redact(h.hist, ops[:], context.temp_allocator, _text_plan(&ctx))
	_ferr(rerr) or_return
	for r in res.ranges {
		_own_redacted(e, h, r.from, r.to)
	}
	_handle_mark(h)
	_object_changed(e, o.space, o.id, .Redacted)
	_index_purge_object(e, h)
	_index_item_add(e, o.space, o.id, .Text)
	return .None
}

map_redact :: proc(e: ^Engine, o: Object, key: []u8) -> Error {
	context = context_for(e)
	h := _map_writable(e, o) or_return
	w := &h.mw.core
	jr := &w.jr
	pos: i64
	end := journal.reader_end(jr)
	targets := make([dynamic][2]i64, context.temp_allocator)
	for pos < end {
		body, next, je := journal.record_at(jr, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			return _jerr(je)
		}
		at := pos
		pos = next
		if obj.is_sig(body) || obj.record_kind(body) < obj.RECORD_KIND_FIRST {
			continue
		}
		env := obj.decode_envelope(body, at) or_continue
		b := omap.decode_body(&env) or_continue
		k: []u8
		switch v in b {
		case omap.Put:
			k = v.key
		case omap.Add:
			k = v.key
		case omap.Del:
			k = v.key
		case omap.Count:
			k = v.key
		}
		if string(k) == string(key) {
			append(&targets, [2]i64{at, next})
		}
	}
	for t in targets {
		_redact_intent(e, h, e.self, t[0], t[1]) or_return
		from := obj.Vref{w.seg, t[0]}
		_oerr2b(obj.writer_redact(w, from, t[1], {})) or_return
		_own_redacted(e, h, t[0], t[1])
	}
	_handle_mark(h)
	if len(targets) > 0 {
		_derived_purge(e, h)
	}
	_object_changed(e, o.space, o.id, .Redacted)
	return .None
}

@(private)
_derived_purge :: proc(e: ^Engine, h: ^Handle) {
	#partial switch h.kind {
	case .Map:
		if _map_table(e, h) == .None && omap.table_reset(&h.table) != .None {
			omap.table_close(&h.table)
			h.table_open = false
		}
		_index_reindex(e, h)
	case .Conversation:
		_index_reindex(e, h)
	}
}

@(private)
_relay_zeroed :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind, device: prim.Id, from, to: i64) {
	if kind != .Map && kind != .Conversation {
		return
	}
	if _, known := e.handles[id]; !known {
		if _, found, err := _rec_get(e, id); err != .None || !found {
			return
		}
	}
	h, err := _handle_get(e, Object{sp.id, id}, kind)
	if err != .None {
		return
	}
	if kind == .Map {
		_derived_purge(e, h)
		return
	}
	_index_purge_messages(e, h, _sealed_in(h, device, from, to))
}

@(private)
_sealed_in :: proc(h: ^Handle, device: prim.Id, from, to: i64) -> []Rid {
	out := make([dynamic]Rid, context.temp_allocator)
	for s in h.segs {
		if s.device != device || s.rep == nil {
			continue
		}
		for g in journal.replica_have(s.rep) {
			if g.to <= to {
				continue
			}
			pos := max(g.from, to)
			for pos < g.to {
				body, next, je := journal.record_at(&s.jr, pos)
				if je == .Redacted {
					pos = next
					continue
				}
				if je != .None {
					break
				}
				at := pos
				pos = next
				if obj.is_sig(body) || obj.record_kind(body) != u8(convo.Kind.Seal) {
					continue
				}
				rec, derr := convo.decode_record(body, at, context.temp_allocator)
				if derr != .None {
					continue
				}
				if seal, ok := rec.body.(convo.Seal); ok && seal.last_block >= from && seal.last_block < to {
					append(&out, Rid{device, seal.msg})
				}
			}
		}
	}
	return out[:]
}

@(private)
_index_reindex :: proc(e: ^Engine, h: ^Handle) {
	if !e.cfg.search {
		return
	}
	if _index_open(e) != .None {
		return
	}
	search.delete_content(&e.index, _source_id(h.id, e.self), 0, h.id)
	for s in h.segs {
		search.advance(&e.index, _source_id(h.id, s.device), 0)
	}
	search.erase(&e.index)
	_snap_dirty(e, h.sp)
	_index_item_add(e, h.sp.id, h.id, h.kind)
}

@(private)
_oerr2b :: proc(a: $A, err: obj.Error) -> Error {
	return _oerr(err)
}

@(private)
_redact_message :: proc(e: ^Engine, h: ^Handle, msg: Rid) -> Error {
	t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
	if terr != .None {
		return _oerr(terr)
	}
	m, merr := convo.message(&h.view, &t, convo.Position{msg = msg}, context.temp_allocator)
	if merr != .None {
		return _oerr(merr)
	}
	plan, perr := convo.writer_redact_plan(&h.cw, msg, context.temp_allocator)
	if perr != .None {
		return _oerr(perr)
	}
	for r in plan {
		_redact_intent(e, h, r.seg, r.from, r.to, msg.off) or_return
	}
	ranges, rerr := convo.writer_redact(&h.cw, msg)
	if rerr != .None {
		return _oerr(rerr)
	}
	for r in ranges {
		if r.seg == e.self {
			_own_redacted(e, h, r.from, r.to)
		} else if h.sp.repl_on {
			osync.replicator_zero_replica(&h.sp.repl, &h.scope, r.seg, h.name, 0, r.from, r.to)
			if i := obj.view_find(&h.view, r.seg); i >= 0 {
				h.view.segs[i].tail_end = -1
			}
			_relay_redact_add(e, h, r.seg, r.from, r.to)
		}
	}
	oids := make([dynamic]odb.Oid, context.temp_allocator)
	for b in m.blocks {
		if b.is_ref && len(b.blob.oid) == 20 {
			x: odb.Oid
			copy(x[:], b.blob.oid)
			append(&oids, x)
		}
	}
	if len(oids) > 0 && e.db_open {
		odb.redact(&e.db, oids[:], "refs/0ndb/", nil, true, context.temp_allocator)
	}
	_index_purge_message(e, h, msg)
	_purge_message(e, h, msg, &m)
	_handle_mark(h)
	_object_changed(e, h.sp.id, h.id, .Redacted)
	return .None
}

@(private)
_redact_intent :: proc(e: ^Engine, h: ^Handle, device: prim.Id, from, to: i64, target: i64 = -1) -> Error {
	return _redact_intent_at(e, h.sp.id, h.id, h.kind, device, from, to, target)
}

@(private)
_redact_intent_at :: proc(e: ^Engine, space: prim.Id, object: prim.Id, kind: Kind, device: prim.Id, from, to: i64, target: i64 = -1) -> Error {
	k, n := _relay_key(e, space, object, device, from)
	if _, found := _rlog_get(e, k[:n]); found && target < 0 {
		return .None
	}
	return _rlog_intent(e, k[:n], Rlog_Entry{kind = kind, to = to, target = target}, !_zero_atomic(e, object, device))
}

@(private)
_zero_atomic :: proc(e: ^Engine, object: prim.Id, device: prim.Id) -> bool {
	h, ok := e.handles[object]
	if !ok {
		return false
	}
	fd := prim.INVALID_FD
	if device == e.self {
		#partial switch h.kind {
		case .Conversation:
			fd = h.cw.core.j.fd if h.w_open else prim.INVALID_FD
		case .Map:
			fd = h.mw.core.j.fd if h.w_open else prim.INVALID_FD
		case .Text, .File_Tree:
			fd = h.hist.journal.fd if h.hist != nil else prim.INVALID_FD
		}
	} else {
		for s in h.segs {
			if s.device == device && s.rep != nil {
				fd = s.rep.fd
			}
		}
	}
	return fd >= 0 && .Atomic_Group_Commit in prim.file_caps(e.vfs, fd)
}

@(private)
_key_live :: proc(t: ^Own_Tree, off: i64) -> bool {
	p := osync.keytree_provider(&t.tree)
	k: journal.Key
	ok := p.key(p.data, off, &k)
	crypto.zero_explicit(&k, size_of(k))
	return ok
}

@(private)
_own_puncture :: proc(e: ^Engine, h: ^Handle, from, to: i64) {
	t := h.own_tree
	if t == nil || !_key_live(t, from) {
		return
	}
	r := _own_journal_reader(h)
	if r == nil {
		return
	}
	keep := make([dynamic]i64, context.temp_allocator)
	pos := from
	for pos < to {
		body, next, je := journal.record_at(r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			_log(e, .Warn, "redaction range unreadable; puncture deferred")
			return
		}
		if journal.is_sig(body) {
			append(&keep, pos)
		}
		pos = next
	}
	if _own_tree_puncture(e, t, from, to, keep[:]) != .None {
		return
	}
	if err := _own_tree_store(e, t); err == .None {
		t.dirty = false
	} else if err != .Busy {
		_fatal(e, err)
	}
	_dirty_keys(e, h.sp, h.id, h.kind, h.scope, t)
}

@(private)
Text_Plan :: struct {
	e: ^Engine,
	h: ^Handle,
}

@(private)
_text_plan :: proc(ctx: ^Text_Plan) -> fs.Redact_Plan {
	call :: proc(data: rawptr, ranges: []journal.Range) -> fs.Error {
		c := (^Text_Plan)(data)
		for r in ranges {
			if _redact_intent(c.e, c.h, c.e.self, r.from, r.to) != .None {
				return .Io
			}
		}
		return .None
	}
	return fs.Redact_Plan{data = ctx, call = call}
}

@(private)
_redact_recover :: proc(e: ^Engine) {
	Pending :: struct {
		space:  prim.Id,
		object: prim.Id,
		kind:   Kind,
		from:   i64,
		to:     i64,
		target: i64,
	}
	list := make([dynamic]Pending, context.temp_allocator)
	if !_rlog_ready(e) {
		return
	}
	for kk, x in e.rlog.live {
		k := kk
		if k[56] != 40 || x.done {
			continue
		}
		p := Pending{kind = x.kind, from = i64(prim.get_u64le(k[32:40])), to = x.to, target = x.target}
		copy(p.space[:], k[:16])
		copy(p.object[:], k[16:32])
		append(&list, p)
	}
	for p in list {
		if _, ok := e.spaces[p.space]; !ok {
			continue
		}
		h, err := _handle_get(e, Object{p.space, p.object}, p.kind)
		if err != .None || !h.w_open {
			continue
		}
		_redact_finish(e, h, p.from, p.to, p.target)
	}
}

@(private)
_redact_settle :: proc(e: ^Engine) {
	if e.tick == e.redact_tick {
		return
	}
	e.redact_tick = e.tick
	e.rlog.idle = true
	_redact_recover(e)
}

@(private)
_redact_mark_done :: proc(e: ^Engine, key: []u8) {
	_rlog_done(e, key)
}

@(private)
_own_journal_reader :: proc(h: ^Handle) -> ^journal.Reader {
	#partial switch h.kind {
	case .Conversation:
		return &h.cw.core.jr if h.w_open else nil
	case .Map:
		return &h.mw.core.jr if h.w_open else nil
	case .Text, .File_Tree:
		if h.hist == nil || fs.history_wake(h.hist) != .None {
			return nil
		}
		x := new(journal.Reader, context.temp_allocator)
		journal.journal_reader(&h.hist.journal, x, context.temp_allocator)
		return x
	}
	return nil
}

@(private)
_redact_finish :: proc(e: ^Engine, h: ^Handle, from, to: i64, target: i64) {
	r := _own_journal_reader(h)
	if r == nil {
		return
	}
	_, _, je := journal.record_at(r, from)
	if je == .Redacted {
		_own_puncture(e, h, from, to)
		k, n := _relay_key(e, h.sp.id, h.id, e.self, from)
		_redact_mark_done(e, k[:n])
		return
	}
	if je != .None {
		return
	}
	#partial switch h.kind {
	case .Conversation:
		w := &h.cw.core
		tv := obj.Vref{w.seg, target} if target >= 0 else obj.Vref{}
		if convo.writer_redact_range(&h.cw, obj.Vref{w.seg, from}, to, tv) == .None {
			_own_redacted(e, h, from, to)
			_handle_mark(h)
			_derived_purge(e, h)
		}
	case .Map:
		w := &h.mw.core
		if _, werr := obj.writer_redact(w, obj.Vref{w.seg, from}, to, {}); werr == .None {
			_own_redacted(e, h, from, to)
			_handle_mark(h)
			_derived_purge(e, h)
		}
	case:
		_relay_redact_done(e, h.sp, h.id, e.self, from)
	}
}

@(private)
_own_redacted :: proc(e: ^Engine, h: ^Handle, from, to: i64) {
	_own_puncture(e, h, from, to)
	_relay_redact_add(e, h, e.self, from, to)
}

@(private)
_relay_key :: proc(e: ^Engine, space: prim.Id, object: prim.Id, device: prim.Id, from: i64) -> (k: [56]u8, n: int) {
	a, b := space, object
	copy(k[:16], a[:])
	copy(k[16:32], b[:])
	prim.put_u64le(k[32:40], u64(from))
	if device == e.self {
		return k, 40
	}
	d := device
	copy(k[40:56], d[:])
	return k, 56
}

@(private)
_relay_redact_add :: proc(e: ^Engine, h: ^Handle, device: prim.Id, from, to: i64) {
	k, n := _relay_key(e, h.sp.id, h.id, device, from)
	if _, found := _rlog_get(e, k[:n]); !found {
		_redact_intent(e, h, device, from, to)
	}
	if device == e.self {
		_redact_mark_done(e, k[:n])
	}
	if h.sp.repl_on && h.sp.connected {
		osync.replicator_redact(&h.sp.repl, &h.scope, device, h.name, 0, from, to)
	}
	_object_changed(e, h.sp.id, h.id, .Redacted)
}

@(private)
_relay_redact_resend :: proc(e: ^Engine, sp: ^Space, object: prim.Id = {}) {
	if !sp.repl_on || !sp.connected || !_rlog_ready(e) {
		return
	}
	s := sp.id
	o := object
	for kk, x in e.rlog.live {
		k := kk
		n := int(k[56])
		if (n != 40 && n != 56) || (n == 40 && !x.done) || string(k[:16]) != string(s[:]) {
			continue
		}
		if !prim.id_is_zero(object) && string(k[16:32]) != string(o[:]) {
			continue
		}
		id: prim.Id
		copy(id[:], k[16:32])
		device := e.self
		if n == 56 {
			copy(device[:], k[40:56])
		}
		from := i64(prim.get_u64le(k[32:40]))
		sc := _object_scope(sp, id)
		osync.replicator_redact(&sp.repl, &sc, device, _seg_name(x.kind, id), 0, from, x.to)
		osync.scope_clear(&sc)
	}
}

@(private)
_relay_redact_done :: proc(e: ^Engine, sp: ^Space, id: prim.Id, device: prim.Id, from: i64) {
	k, n := _relay_key(e, sp.id, id, device, from)
	_rlog_clear(e, k[:n])
}

@(private)
_stream_object :: proc(e: ^Engine, sp: ^Space, stream: osync.Stream_Id) -> (id: prim.Id, kind: Kind, epoch: u64, found: bool) {
	device := osync.stream_device(stream)
	if device != e.self {
		if rm, ok := sp.repl.remotes[stream]; ok {
			id, kind, found = _object_of_name(rm.name)
			return id, kind, rm.epoch, found
		}
	}
	for x, h in e.handles {
		if h.sp == sp && osync.stream_id(&h.scope, device, h.name, 0) == stream {
			return x, h.kind, 0, true
		}
	}
	Acc :: struct {
		e:      ^Engine,
		sp:     ^Space,
		stream: osync.Stream_Id,
		device: prim.Id,
		id:     prim.Id,
		kind:   Kind,
		found:  bool,
	}
	acc := Acc{e = e, sp = sp, stream = stream, device = device}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) != 16 {
			return true
		}
		rec, err := _rec_decode(value, context.temp_allocator)
		if err != .None || rec.space != a.sp.id {
			return true
		}
		if a.device == a.e.self ? !rec.own : _rec_member(&rec, a.device) < 0 {
			return true
		}
		x: prim.Id
		copy(x[:], key)
		sc := _object_scope(a.sp, x)
		defer osync.scope_clear(&sc)
		if osync.stream_id(&sc, a.device, _seg_name(rec.kind, x), 0) != a.stream {
			return true
		}
		a.id, a.kind, a.found = x, rec.kind, true
		return false
	}
	for k, v in e.reg.staged {
		x := k
		if !visit(&acc, x[:], v) {
			break
		}
	}
	if !acc.found {
		omap.db_scan(&e.reg.db, ROOT_OBJECTS, nil, nil, &acc, visit)
	}
	return acc.id, acc.kind, 0, acc.found
}

@(private)
_relay_redacted_event :: proc(e: ^Engine, sp: ^Space, stream: osync.Stream_Id, from, to: i64) {
	_snap_redaction_seen(e, sp, stream, from, to)
	id, kind, epoch, found := _stream_object(e, sp, stream)
	if !found {
		return
	}
	device := osync.stream_device(stream)
	_relay_redact_done(e, sp, id, device, from)
	if device == e.self {
		return
	}
	if kind == .Conversation {
		_snap_relay_zeroed(e, sp, id, device, from, to)
	}
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	osync.replicator_zero_replica(&sp.repl, &sc, device, _seg_name(kind, id), epoch, from, to)
	_relay_zeroed(e, sp, id, kind, device, from, to)
	_object_changed(e, sp.id, id, .Redacted)
}

@(private)
_local_redacted :: proc(e: ^Engine, sp: ^Space, stream: osync.Stream_Id, from, to: i64) {
	_snap_redaction_seen(e, sp, stream, from, to)
	id, kind, _, found := _stream_object(e, sp, stream)
	if !found || (kind != .Conversation && kind != .Map) {
		return
	}
	if _redact_intent_at(e, sp.id, id, kind, e.self, from, to) != .None {
		return
	}
	h, herr := _handle_get(e, Object{sp.id, id}, kind)
	if herr != .None || !h.w_open {
		return
	}
	w := &h.cw.core if kind == .Conversation else &h.mw.core
	if journal.journal_commit(&w.j) != .None {
		return
	}
	body, _, je := journal.record_at(&w.jr, from)
	if je == .Redacted {
		_relay_redact_done(e, sp, id, e.self, from)
		return
	}
	if je != .None {
		return
	}
	fv := obj.Vref{w.seg, from}
	target: obj.Vref
	if kind == .Conversation {
		if rec, derr := convo.decode_record(body, from, context.temp_allocator); derr == .None {
			if b, ok := rec.body.(convo.Block); ok {
				target = obj.Vref{w.seg, b.msg}
			}
		}
		msg := Rid{e.self, target.off}
		if !obj.vref_none(target) {
			if t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator); terr == .None {
				if m, merr := convo.message(&h.view, &t, convo.Position{msg = msg}, context.temp_allocator); merr == .None {
					_purge_message(e, h, msg, &m)
				}
			}
		}
		if _redact_intent(e, h, e.self, from, to, target.off if !obj.vref_none(target) else -1) != .None {
			return
		}
		if convo.writer_redact_range(&h.cw, fv, to, target) != .None {
			return
		}
		if !obj.vref_none(target) {
			_index_purge_message(e, h, msg)
		} else {
			_derived_purge(e, h)
		}
	} else {
		if _redact_intent(e, h, e.self, from, to) != .None {
			return
		}
		if _, werr := obj.writer_redact(w, fv, to, {}); werr != .None {
			return
		}
		_derived_purge(e, h)
	}
	_own_redacted(e, h, from, to)
	_handle_mark(h)
	_object_changed(e, sp.id, id, .Redacted)
}

@(private)
_apply_remote_redact :: proc(e: ^Engine, h: ^Handle, vs: int, env: ^obj.Envelope) -> Error {
	r, err := obj.decode_redact(env)
	if err != .None {
		return .None
	}
	from, rerr := obj.resolve(&h.view, vs, r.from)
	if rerr == .Missing || rerr == .Unknown_Segment {
		return .Missing
	}
	if rerr != .None {
		return .None
	}
	dev := obj.seg_id(&h.view, from)
	target_rid: Rid
	target, terr := obj.resolve(&h.view, vs, r.target)
	if terr != .None {
		target = {}
	}
	if !obj.vref_none(target) && h.kind == .Conversation {
		target_rid = obj.rid(&h.view, target)
		if t, tt := convo.view_tail(&h.view, e.self, context.temp_allocator); tt == .None {
			if m, merr := convo.message(&h.view, &t, convo.Position{msg = target_rid}, context.temp_allocator); merr == .None {
				_purge_message(e, h, target_rid, &m)
			}
		}
	}
	if dev == e.self {
		if _redact_intent(e, h, e.self, from.off, r.to, target.off if !obj.vref_none(target) && target.seg == from.seg else -1) != .None {
			return .None
		}
		if !h.w_open {
			return .None
		}
		w: ^obj.Writer
		#partial switch h.kind {
		case .Conversation:
			w = &h.cw.core
		case .Map:
			w = &h.mw.core
		}
		if w == nil {
			return .None
		}
		if journal.journal_commit(&w.j) != .None {
			return .None
		}
		if _, _, je := journal.record_at(&w.jr, from.off); je != .Redacted {
			werr: obj.Error
			if h.kind == .Conversation {
				werr = convo.writer_redact_range(&h.cw, from, r.to, target)
			} else {
				_, werr = obj.writer_redact(w, from, r.to, target)
			}
			if werr != .None {
				return .None
			}
			_own_redacted(e, h, from.off, r.to)
		}
		_handle_mark(h)
	} else if h.sp.repl_on {
		osync.replicator_zero_replica(&h.sp.repl, &h.scope, dev, h.name, 0, from.off, r.to)
		h.view.segs[from.seg].tail_end = -1
	}
	if !obj.rid_none(target_rid) {
		_index_purge_message(e, h, target_rid)
	}
	if h.kind == .Map {
		_derived_purge(e, h)
	}
	_object_changed(e, h.sp.id, h.id, .Redacted)
	return .None
}

@(private)
PURGED_KEEP :: 1024

@(private)
_purge_message :: proc(e: ^Engine, h: ^Handle, msg: Rid, m: ^convo.Message) {
	if e.cfg.purge.purge == nil {
		return
	}
	for x in e.purged {
		if x == msg {
			return
		}
	}
	if len(e.purged) >= PURGED_KEEP {
		ordered_remove(&e.purged, 0)
	}
	append(&e.purged, msg)
	ids := make([dynamic]string, context.temp_allocator)
	for s in ([]string{m.native_msg, m.seal_native}) {
		if len(s) > 0 {
			append(&ids, s)
		}
	}
	texts := make([dynamic]string, context.temp_allocator)
	bodies := make([dynamic]string, context.temp_allocator)
	for b in m.blocks {
		if len(b.id) > 0 {
			append(&ids, b.id)
		}
		if len(b.text) > 0 {
			append(&texts, string(b.text))
			append(&bodies, string(b.text))
		}
	}
	if len(ids) == 0 && len(texts) == 0 && len(m.native) == 0 && obj.rid_none(m.claim) {
		return
	}
	req := Purge_Request{object = Object{h.sp.id, h.id}, msg = msg, role = m.role, provider = m.provider, native = m.native, ids = ids[:], texts = texts[:], bodies = bodies[:], claim = m.claim}
	{
		context = _outer(e)
		e.cfg.purge.purge(e.cfg.purge.data, e, &req)
	}
}

@(private)
_index_purge_message :: proc(e: ^Engine, h: ^Handle, msg: Rid) {
	if !e.cfg.search {
		return
	}
	if _index_open(e) != .None {
		return
	}
	ref := _rid_ref(msg)
	src := _source_id(h.id, msg.seg)
	pos, _ := search.position(&e.index, src)
	search.redact(&e.index, src, pos, h.id, ref[:])
	_snap_dirty(e, h.sp)
}

@(private)
_index_purge_messages :: proc(e: ^Engine, h: ^Handle, msgs: []Rid) {
	if len(msgs) == 0 || !e.cfg.search {
		return
	}
	if _index_open(e) != .None {
		return
	}
	for msg in msgs {
		ref := _rid_ref(msg)
		src := _source_id(h.id, msg.seg)
		pos, _ := search.position(&e.index, src)
		search.delete_record(&e.index, src, pos, h.id, ref[:])
	}
	search.erase(&e.index)
	_snap_dirty(e, h.sp)
}

@(private)
_index_purge_object :: proc(e: ^Engine, h: ^Handle) {
	if !e.cfg.search {
		return
	}
	if _index_open(e) != .None {
		return
	}
	src := _source_id(h.id, e.self)
	pos, _ := search.position(&e.index, src)
	search.delete_content(&e.index, src, pos, h.id)
	search.erase(&e.index)
	_snap_dirty(e, h.sp)
}

@(private)
Replacement :: enum u8 {
	Found,
	Absent,
	Missing,
}

@(private)
_hist_replacement :: proc(h: ^Handle, s: ^Seg, off: i64) -> (synth: []u8, st: Replacement) {
	end := journal.reader_end(&s.jr)
	_, pos, ferr := journal.record_at(&s.jr, off)
	if ferr != .Redacted {
		return nil, .Absent
	}
	for pos < end {
		body, next, rerr := journal.record_at(&s.jr, pos)
		if rerr == .Missing {
			if h.sp.repl_on {
				r := [1]journal.Range{{pos, end}}
				osync.replicator_want(&h.sp.repl, &h.scope, s.device, h.name, 0, r[:])
			}
			return nil, .Missing
		}
		if rerr != .None && rerr != .Redacted {
			return nil, .Absent
		}
		pos = next
		if rerr == .Redacted || journal.is_sig(body) || len(body) < 3 || body[0] != fs.REC_REPLACE {
			continue
		}
		rp, ok := fs.replace_decode(body)
		if !ok || !fs.replace_supersedes(rp, u64(off)) {
			continue
		}
		kind := fs.REC_BATCH if rp.kind == fs.REC_REPLACE else rp.kind
		if kind != fs.REC_BATCH && kind != fs.REC_IMPORT {
			return nil, .Absent
		}
		out := make([]u8, 1 + len(rp.payload), context.temp_allocator)
		out[0] = kind
		copy(out[1:], rp.payload)
		return out, .Found
	}
	if h.sp.repl_on && osync.replicator_relay_length(&h.sp.repl, &h.scope, s.device, h.name, 0) > end {
		r := [1]journal.Range{{end, osync.replicator_relay_length(&h.sp.repl, &h.scope, s.device, h.name, 0)}}
		osync.replicator_want(&h.sp.repl, &h.scope, s.device, h.name, 0, r[:])
	}
	return nil, .Missing
}

@(private)
_hist_admit_redacted :: proc(e: ^Engine, h: ^Handle, s: ^Seg, off: i64) -> fs.Error {
	synth, st := _hist_replacement(h, s, off)
	switch st {
	case .Missing:
		return .Not_Found
	case .Absent:
		return .None
	case .Found:
	}
	if _, err := fs.history_admit(h.hist, s.device, off, synth); err == .Not_Found {
		return .Not_Found
	}
	return .None
}

@(private)
_publish_later :: proc(e: ^Engine, d: ^Dirty_Seg) {
	for &x in e.dirty {
		if x.object == d.object {
			x.keys ||= d.keys
			x.length = max(x.length, d.length)
			if len(x.path) == 0 && len(d.path) > 0 {
				x.path = _clone(d.path, e.allocator) or_else ""
			}
			if x.tree == nil && d.tree != nil {
				d.tree.refs += 1
				x.tree = d.tree
			}
			_touch(e)
			return
		}
	}
	if d.tree != nil {
		d.tree.refs += 1
	}
	append(&e.dirty, Dirty_Seg{space = d.space, object = d.object, kind = d.kind, scope = d.scope, name = _clone(d.name, e.allocator) or_else "", path = _clone(d.path, e.allocator) or_else "", length = d.length, tree = d.tree, keys = d.keys})
	_touch(e)
}

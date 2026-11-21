package engine

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
	res, rerr := fs.history_redact(h.hist, ops[:], context.temp_allocator)
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
_relay_zeroed_stream :: proc(e: ^Engine, sp: ^Space, stream: osync.Stream_Id, from, to: i64) {
	device := osync.stream_device(stream)
	id: prim.Id
	kind: Kind
	epoch: u64
	found := false
	if rm, ok := sp.repl.remotes[stream]; ok {
		id, kind, found = _object_of_name(rm.name)
		epoch = rm.epoch
	} else {
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
			if err != .None || rec.space != a.sp.id || (rec.kind != .Map && rec.kind != .Conversation) || _rec_member(&rec, a.device) < 0 {
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
		id, kind, found = acc.id, acc.kind, acc.found
	}
	if !found {
		return
	}
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	osync.replicator_zero_replica(&sp.repl, &sc, device, _seg_name(kind, id), epoch, from, to)
	_relay_zeroed(e, sp, id, kind)
	_object_changed(e, sp.id, id, .Redacted)
}

@(private)
_relay_zeroed :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind) {
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
	_derived_purge(e, h)
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
_own_redacted :: proc(e: ^Engine, h: ^Handle, from, to: i64) {
	if h.own_tree != nil {
		if err := _own_tree_puncture(e, h.own_tree, from, to); err == .None {
			_dirty_keys(e, h.sp, h.id, h.kind, h.scope, h.own_tree)
		}
	}
	_relay_redact_add(e, h, from, to)
}

@(private)
_relay_key :: proc(space: prim.Id, object: prim.Id, from: i64) -> (k: [40]u8) {
	a, b := space, object
	copy(k[:16], a[:])
	copy(k[16:32], b[:])
	prim.put_u64le(k[32:], u64(from))
	return
}

@(private)
_relay_redact_add :: proc(e: ^Engine, h: ^Handle, from, to: i64) {
	k := _relay_key(h.sp.id, h.id, from)
	v: [9]u8
	v[0] = u8(h.kind)
	prim.put_u64le(v[1:], u64(to))
	t, terr := omap.txn_begin(&e.reg.db)
	if terr == .None {
		if omap.txn_put(t, ROOT_REDACT, k[:], v[:]) == .None {
			omap.txn_commit(t)
		} else {
			omap.txn_abort(t)
		}
	}
	if h.sp.repl_on && h.sp.connected {
		osync.replicator_redact(&h.sp.repl, &h.scope, e.self, h.name, 0, from, to)
	}
	_object_changed(e, h.sp.id, h.id, .Redacted)
}

@(private)
_relay_redact_resend :: proc(e: ^Engine, sp: ^Space, object: prim.Id = {}) {
	Acc :: struct {
		e:      ^Engine,
		sp:     ^Space,
		object: prim.Id,
	}
	acc := Acc{e, sp, object}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(key) != 40 || len(value) != 9 || value[0] < 1 || value[0] > u8(max(Kind)) {
			return true
		}
		id: prim.Id
		copy(id[:], key[16:32])
		from := i64(prim.get_u64le(key[32:]))
		to := i64(prim.get_u64le(value[1:]))
		sc := _object_scope(a.sp, id)
		defer osync.scope_clear(&sc)
		name := _seg_name(Kind(value[0]), id)
		osync.replicator_redact(&a.sp.repl, &sc, a.e.self, name, 0, from, to)
		return true
	}
	if !sp.repl_on || !sp.connected {
		return
	}
	prefix := make([]u8, 32 if !prim.id_is_zero(object) else 16, context.temp_allocator)
	s := sp.id
	copy(prefix[:16], s[:])
	if !prim.id_is_zero(object) {
		o := object
		copy(prefix[16:], o[:])
	}
	omap.db_scan(&e.reg.db, ROOT_REDACT, prefix, prefix, &acc, visit)
}

@(private)
_relay_redact_done :: proc(e: ^Engine, sp: ^Space, stream: osync.Stream_Id, from: i64) {
	for _, h in e.handles {
		if h.sp != sp || osync.stream_id(&h.scope, e.self, h.name, 0) != stream {
			continue
		}
		k := _relay_key(sp.id, h.id, from)
		t, terr := omap.txn_begin(&e.reg.db)
		if terr == .None {
			omap.txn_delete(t, ROOT_REDACT, k[:])
			omap.txn_commit(t)
		}
		return
	}
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
		}
		_own_redacted(e, h, from.off, r.to)
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
	for b in m.blocks {
		if len(b.id) > 0 {
			append(&ids, b.id)
		}
		if len(b.text) > 0 {
			append(&texts, string(b.text))
		}
		if len(b.name) > 0 && b.kind == .Tool_Call {
			append(&texts, b.name)
		}
	}
	if len(ids) == 0 && len(texts) == 0 && len(m.native) == 0 {
		return
	}
	req := Purge_Request{object = Object{h.sp.id, h.id}, msg = msg, role = m.role, provider = m.provider, native = m.native, ids = ids[:], texts = texts[:]}
	e.cfg.purge.purge(e.cfg.purge.data, e, &req)
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
		old, n := prim.get_uvarint(body[1:])
		if n <= 0 || 1 + n + 1 > len(body) || old != u64(off) {
			continue
		}
		kind := body[1 + n]
		if kind != fs.REC_BATCH && kind != fs.REC_IMPORT {
			return nil, .Absent
		}
		out := make([]u8, len(body) - n - 1, context.temp_allocator)
		out[0] = kind
		copy(out[1:], body[1 + n + 1:])
		return out, .Found
	}
	return nil, .Absent
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

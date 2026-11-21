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
	_object_changed(e, o.space, o.id, .Redacted)
	return .None
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
	if e.cfg.purge.purge != nil && len(m.native) > 0 {
		ids := make([dynamic]string, context.temp_allocator)
		if len(m.native_msg) > 0 {
			append(&ids, m.native_msg)
		}
		if len(m.seal_native) > 0 {
			append(&ids, m.seal_native)
		}
		req := Purge_Request{object = Object{h.sp.id, h.id}, msg = msg, provider = m.provider, native = m.native, ids = ids[:]}
		e.cfg.purge.purge(e.cfg.purge.data, e, &req)
	}
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
_apply_remote_redact :: proc(e: ^Engine, h: ^Handle, vs: int, env: ^obj.Envelope) {
	r, err := obj.decode_redact(env)
	if err != .None {
		return
	}
	from, rerr := obj.resolve(&h.view, vs, r.from)
	if rerr != .None {
		return
	}
	dev := obj.seg_id(&h.view, from)
	if dev == e.self {
		if !h.w_open {
			return
		}
		w: ^obj.Writer
		#partial switch h.kind {
		case .Conversation:
			w = &h.cw.core
		case .Map:
			w = &h.mw.core
		}
		if w == nil {
			return
		}
		if journal.journal_commit(&w.j) != .None {
			return
		}
		if journal.journal_redact(&w.j, from.off, r.to) != .None {
			return
		}
		w.v.segs[w.seg].tail_end = -1
		_own_redacted(e, h, from.off, r.to)
		_handle_mark(h)
	} else if h.sp.repl_on {
		osync.replicator_zero_replica(&h.sp.repl, &h.scope, dev, h.name, 0, from.off, r.to)
		h.view.segs[from.seg].tail_end = -1
	}
	if !obj.vref_none(obj.Vref{vs, 0}) {
		target, terr := obj.resolve(&h.view, vs, r.target)
		if terr == .None && !obj.vref_none(target) && h.kind == .Conversation {
			_index_purge_message(e, h, obj.rid(&h.view, target))
		}
	}
	_object_changed(e, h.sp.id, h.id, .Redacted)
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
	search.delete_object(&e.index, src, pos, h.id)
	search.flush(&e.index)
}

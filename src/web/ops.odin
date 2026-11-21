package web

import "../convo"
import "../journal"
import omap "../map"
import "../obj"
import "../prim"
import osync "../sync"

Op :: enum u8 {
	None        = 0,
	Catalog     = 1,
	Status      = 2,
	Page        = 3,
	Message     = 4,
	Siblings    = 5,
	Map_Get     = 6,
	Map_Scan    = 7,
	Subscribe   = 8,
	Unsubscribe = 9,
	Text        = 10,
	Catalog_Get = 11,
	Close       = 12,
}

STATUS_UNSUPPORTED :: 254
STATUS_BAD_ARGS :: 253
MAX_TRIES :: 16

request_submit :: proc(s: ^Session, op: Op, args: []u8) -> u32 {
	s.next_id += 1
	id := s.next_id
	r := new(Request, s.allocator)
	r.id = id
	r.op = op
	r.args = make([]u8, len(args), s.allocator)
	copy(r.args, args)
	status := _request_bind(s, r)
	switch {
	case status != 0:
		_request_done(s, r, status)
	case r.op == .Unsubscribe:
		_unsubscribe(s, prim.get_u32le(r.args[:4]))
		_request_done(s, r, 0)
	case r.op == .Close:
		oid: prim.Id
		copy(oid[:], r.args[:16])
		if o, ok := s.objects[oid]; ok && !o.catalog {
			_object_close(s, o)
		}
		_request_done(s, r, 0)
	case:
		append(&s.requests, r)
		if _request_run(s, r) {
			_request_remove(s, r)
		}
	}
	if s.feed_dirty && s.ready {
		_feed_subscribe(s, s.feed_cursor)
	}
	link_flush(&s.link)
	return id
}

@(private)
_request_bind :: proc(s: ^Session, r: ^Request) -> u8 {
	ok := true
	switch r.op {
	case .None:
		return STATUS_BAD_ARGS
	case .Catalog, .Catalog_Get:
		if s.shared {
			return u8(obj.Error.Permission)
		}
		if (r.op == .Catalog && len(r.args) < 5) || (r.op == .Catalog_Get && len(r.args) != 16) {
			return STATUS_BAD_ARGS
		}
		r.object = s.objects[s.catalog_id]
	case .Status, .Page, .Message, .Siblings:
		need := 16
		#partial switch r.op {
		case .Page:
			need = 16 + 24 + 24 + 1 + 4
		case .Message, .Siblings:
			need = 16 + 24
		}
		if len(r.args) != need {
			return STATUS_BAD_ARGS
		}
		r.object, ok = _bind_object(s, r.args[:16], .Conversation)
	case .Map_Get, .Map_Scan:
		if len(r.args) < (16 if r.op == .Map_Get else 24) {
			return STATUS_BAD_ARGS
		}
		r.object, ok = _bind_object(s, r.args[:16], .Map)
	case .Subscribe:
		if len(r.args) != 17 || r.args[16] < 1 || r.args[16] > 2 {
			return STATUS_BAD_ARGS
		}
		r.object, ok = _bind_object(s, r.args[:16], obj.Kind(r.args[16]))
	case .Unsubscribe:
		return 0 if len(r.args) == 4 else STATUS_BAD_ARGS
	case .Close:
		return 0 if len(r.args) == 16 else STATUS_BAD_ARGS
	case .Text:
		return STATUS_UNSUPPORTED if len(r.args) == 16 else STATUS_BAD_ARGS
	}
	if !ok {
		return u8(obj.Error.Permission) if s.shared else STATUS_BAD_ARGS
	}
	return 0 if r.object != nil else STATUS_BAD_ARGS
}

@(private)
_bind_object :: proc(s: ^Session, raw: []u8, kind: obj.Kind) -> (o: ^Object, ok: bool) {
	id: prim.Id
	copy(id[:], raw)
	if s.shared && id != s.share.object {
		return nil, false
	}
	if x, found := s.objects[id]; found {
		return x, x.kind == kind
	}
	return _object_get(s, id, kind), true
}

@(private)
_request_remove :: proc(s: ^Session, r: ^Request) {
	for x, i in s.requests {
		if x == r {
			ordered_remove(&s.requests, i)
			break
		}
	}
	delete(r.args, s.allocator)
	free(r, s.allocator)
}

@(private)
_request_done :: proc(s: ^Session, r: ^Request, status: u8) {
	_event(s, .Result, r.id, status, nil)
	delete(r.args, s.allocator)
	free(r, s.allocator)
}

@(private)
_unsubscribe :: proc(s: ^Session, id: u32) {
	for sb, i in s.subs {
		if sb.id == id {
			ordered_remove(&s.subs, i)
			free(sb, s.allocator)
			return
		}
	}
}

@(private)
_retry :: proc(s: ^Session) {
	i := 0
	for i < len(s.requests) {
		r := s.requests[i]
		if !s.ready || r.object == nil || !r.object.changed {
			i += 1
			continue
		}
		if _request_run(s, r) {
			_request_remove(s, r)
			continue
		}
		i += 1
	}
}

@(private)
_request_run :: proc(s: ^Session, r: ^Request) -> bool {
	o := r.object
	if !s.ready {
		return _request_offline(s, r)
	}
	if _object_waiting(s, o) || !_members_known(s, o) {
		return false
	}
	if (o.kind == .Map) && !_map_ready(s, o) {
		return false
	}
	if !s.shared && !o.catalog && len(o.segs) == 0 {
		_event(s, .Result, r.id, u8(obj.Error.Not_Found), nil)
		return true
	}
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	out: Out
	out_init(&out, &buf)
	err := _exec(s, r, &out)
	if err == .Missing || err == .Unknown_Segment {
		issued := _object_wants(s, o)
		r.tries += 1
		if issued || _object_waiting(s, o) {
			return false
		}
		if r.tries < MAX_TRIES && len(o.segs) > 0 {
			return false
		}
		_event(s, .Result, r.id, u8(obj.Error.Missing), nil)
		return true
	}
	if err != .None {
		_event(s, .Result, r.id, u8(err), nil)
		return true
	}
	_event(s, .Result, r.id, 0, out_finish(&out))
	return true
}

@(private)
_request_offline :: proc(s: ^Session, r: ^Request) -> bool {
	o := r.object
	if o.table_ok {
		if omap.table_count(&o.table) == 0 {
			return false
		}
	} else {
		if len(o.segs) == 0 {
			return false
		}
		for sg in o.segs {
			if !sg.in_view {
				return false
			}
		}
	}
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	out: Out
	out_init(&out, &buf)
	err := _exec(s, r, &out)
	obj.view_reset(&o.view)
	if err == .Missing || err == .Unknown_Segment {
		return false
	}
	if err != .None {
		_event(s, .Result, r.id, u8(err), nil)
		return true
	}
	_event(s, .Result, r.id, 0, out_finish(&out))
	return true
}

@(private)
_members_known :: proc(s: ^Session, o: ^Object) -> bool {
	if s.shared {
		return s.announced
	}
	if o.catalog {
		return s.announced && len(o.segs) > 0
	}
	c := s.objects[s.catalog_id]
	return len(o.segs) > 0 || (_map_ready(s, c) && len(c.segs) > 0)
}

@(private)
_map_ready :: proc(s: ^Session, o: ^Object) -> bool {
	if !s.announced {
		return false
	}
	for sg in o.segs {
		if !sg.in_view || sg.data.relay_len < 0 || _contiguous(sg.data) < sg.data.relay_len {
			return false
		}
	}
	return true
}

@(private)
_rid_arg :: proc(b: []u8) -> (r: obj.Rid) {
	copy(r.seg[:], b[:16])
	r.off = i64(prim.get_u64le(b[16:24]))
	return
}

@(private)
_exec :: proc(s: ^Session, r: ^Request, out: ^Out) -> obj.Error {
	o := r.object
	a := r.args
	switch r.op {
	case .None, .Text:
		return .Invalid
	case .Catalog:
		archived := a[0] != 0
		limit := int(prim.get_u32le(a[1:5]))
		cur: omap.Cursor
		cur.key = make([dynamic]u8, context.temp_allocator)
		if len(a) > 5 {
			append(&cur.key, ..a[5:])
			cur.valid = true
		}
		rows, more := omap.catalog_list(&o.table, archived, &cur, max(limit, 1), context.temp_allocator) or_return
		o_arr(out, "rows")
		for &row in rows {
			emit_catalog_row(out, &row)
		}
		o_end(out)
		o_bytes(out, "cursor", cur.key[:])
		o_bool(out, "more", more)
	case .Catalog_Get:
		id: prim.Id
		copy(id[:], a[:16])
		e, found := omap.catalog_get(&o.table, id, context.temp_allocator) or_return
		if !found {
			return .Not_Found
		}
		emit_catalog_entry(out, "entry", &e)
	case .Status:
		t := convo.view_tail(&o.view, {}, context.temp_allocator) or_return
		emit_tail(out, &o.view, &t)
	case .Page:
		from := convo.Position {
			msg        = _rid_arg(a[16:40]),
			seal       = _rid_arg(a[40:64]),
			seal_known = a[64] != 0,
		}
		limit := int(prim.get_u32le(a[65:69]))
		t := convo.view_tail(&o.view, {}, context.temp_allocator) or_return
		p := convo.page(&o.view, &t, from, max(limit, 1), context.temp_allocator) or_return
		emit_tail(out, &o.view, &t)
		o_arr(out, "messages")
		for &m in p.messages {
			emit_message(out, "", &m)
		}
		o_end(out)
		emit_position(out, "next", p.next)
		o_bool(out, "more", p.more)
	case .Message:
		t := convo.view_tail(&o.view, {}, context.temp_allocator) or_return
		m := convo.message(&o.view, &t, convo.Position{msg = _rid_arg(a[16:40])}, context.temp_allocator) or_return
		emit_message(out, "message", &m)
	case .Siblings:
		t := convo.view_tail(&o.view, {}, context.temp_allocator) or_return
		list, at := convo.siblings(&o.view, &t, _rid_arg(a[16:40]), context.temp_allocator) or_return
		o_arr(out, "siblings")
		for x in list {
			o_rid(out, "", x)
		}
		o_end(out)
		o_int(out, "at", at)
	case .Map_Get:
		e, found := omap.table_get(&o.table, a[16:], context.temp_allocator) or_return
		if !found {
			return .Not_Found
		}
		emit_entry(out, "entry", &e)
	case .Map_Scan:
		limit := int(prim.get_u32le(a[16:20]))
		plen := int(prim.get_u32le(a[20:24]))
		if 24 + plen > len(a) {
			return .Invalid
		}
		cur: omap.Cursor
		cur.key = make([dynamic]u8, context.temp_allocator)
		if len(a) > 24 + plen {
			append(&cur.key, ..a[24 + plen:])
			cur.valid = true
		}
		rows, more := omap.table_scan(&o.table, -1, a[24:24 + plen], &cur, max(limit, 1), context.temp_allocator) or_return
		o_arr(out, "rows")
		for &row in rows {
			emit_entry(out, "", &row.entry)
		}
		o_end(out)
		o_bytes(out, "cursor", cur.key[:])
		o_bool(out, "more", more)
	case .Subscribe:
		sb := new(Sub, s.allocator)
		sb.id = r.id
		sb.object = o
		append(&s.subs, sb)
		for sg in o.segs {
			_cursor_prime(sg)
		}
		o_u64(out, "sub", u64(r.id))
	case .Unsubscribe, .Close:
		return .Invalid
	}
	return .None
}

@(private)
_cursor_prime :: proc(sg: ^Seg) {
	if !sg.cursor_ok && sg.data.relay_len >= 0 {
		sg.cursor = sg.data.relay_len
		sg.cursor_ok = true
	}
}

@(private)
_deltas :: proc(s: ^Session) {
	for sb in s.subs {
		o := sb.object
		if !o.changed {
			continue
		}
		buf := make([dynamic]u8, 0, 1024, context.temp_allocator)
		out: Out
		out_init(&out, &buf, true)
		n := 0
		if o.rekeyed {
			o_obj(&out, "")
			o_str(&out, "kind", "redacted")
			o_object(&out, "object", s.space_id, o.id)
			o_end(&out)
			n += 1
		}
		for sg in o.segs {
			if !sg.in_view {
				continue
			}
			_cursor_prime(sg)
			if !sg.cursor_ok {
				continue
			}
			n += _seg_deltas(s, o, sg, &out)
		}
		if n > 0 {
			_event(s, .Deltas, sb.id, 0, out_finish(&out))
		}
	}
}

@(private)
_seg_deltas :: proc(s: ^Session, o: ^Object, sg: ^Seg, out: ^Out) -> (n: int) {
	end := journal.replica_length(&sg.data.rep)
	vs := obj.view_find(&o.view, sg.device)
	for sg.cursor < end {
		body, next, je := journal.record_at(&sg.jr, sg.cursor)
		if je == .Redacted {
			sg.cursor = next
			continue
		}
		if je == .Missing {
			_remote_fetch(s, sg.data, sg.cursor, end)
			return
		}
		if je != .None {
			return
		}
		at := sg.cursor
		sg.cursor = next
		if obj.is_sig(body) || obj.is_redacted(body) {
			continue
		}
		k := obj.record_kind(body)
		rid := obj.Rid{sg.device, at}
		if k == obj.RECORD_REDACT {
			_redact_seen(s, o, vs, body, at)
			o_obj(out, "")
			o_str(out, "kind", "redacted")
			o_object(out, "object", s.space_id, o.id)
			o_rid(out, "rid", rid)
			o_id(out, "by", sg.device)
			o_end(out)
			n += 1
			continue
		}
		if k < obj.RECORD_KIND_FIRST {
			continue
		}
		if o.kind == .Conversation {
			n += _delta_convo(s, o, vs, sg.device, at, body, out)
		} else {
			n += _delta_map(s, o, sg.device, at, body, out)
		}
	}
	return
}

@(private)
_redact_seen :: proc(s: ^Session, o: ^Object, vs: int, body: []u8, at: i64) {
	if vs < 0 {
		return
	}
	env, err := obj.decode_envelope(body, at)
	if err != .None {
		return
	}
	r, rerr := obj.decode_redact(&env)
	if rerr != .None {
		return
	}
	from, ferr := obj.resolve(&o.view, vs, r.from)
	if ferr != .None {
		return
	}
	dev := obj.seg_id(&o.view, from)
	tg := _seg_find(o, dev)
	if tg == nil {
		return
	}
	hi := min(r.to, journal.replica_length(&tg.data.rep))
	if hi > from.off {
		keys: journal.Key_Provider
		if tg.tree_ok {
			keys = osync.keytree_provider(&tg.tree)
		}
		journal.replica_redact(&tg.data.rep, from.off, hi, keys)
	}
	o.view.segs[from.seg].tail_end = -1
	_seg_probe(s, o, tg, tg.next.epoch if tg.next != nil else tg.epoch)
}

@(private)
_resolve :: proc(o: ^Object, vs: int, r: obj.Ref) -> obj.Rid {
	if obj.ref_none(r) || vs < 0 {
		return {}
	}
	v, err := obj.resolve(&o.view, vs, r)
	if err != .None {
		return {}
	}
	return obj.rid(&o.view, v)
}

@(private)
_delta_head :: proc(s: ^Session, o: ^Object, out: ^Out, kind: string, rid: obj.Rid, by: prim.Id, record: u8, hlc: prim.Hlc) {
	o_obj(out, "")
	o_str(out, "kind", kind)
	o_object(out, "object", s.space_id, o.id)
	o_rid(out, "rid", rid)
	o_id(out, "by", by)
	o_u64(out, "record", u64(record))
	o_u64(out, "hlc", u64(hlc))
}

@(private)
_delta_convo :: proc(s: ^Session, o: ^Object, vs: int, device: prim.Id, at: i64, body: []u8, out: ^Out) -> int {
	rec, err := convo.decode_record(body, at, context.temp_allocator)
	if err != .None {
		return 0
	}
	rid := obj.Rid{device, at}
	switch b in rec.body {
	case convo.Msg:
		_delta_head(s, o, out, "message", rid, device, rec.env.kind, b.hlc)
		o_rid(out, "msg", rid)
		o_enum(out, "role", u64(b.role), ROLE_NAMES[:])
		o_rid(out, "parent", _resolve(o, vs, b.parent))
	case convo.Block:
		_delta_head(s, o, out, "block" if .Start in b.flags else "chunk", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", obj.Rid{device, b.msg})
		o_u64(out, "index", u64(b.index))
		o_enum(out, "block", u64(b.kind), BLOCK_NAMES[:])
		o_text(out, "text", b.data)
	case convo.Seal:
		_delta_head(s, o, out, "seal", rid, device, rec.env.kind, b.hlc)
		o_rid(out, "msg", obj.Rid{device, b.msg})
		o_enum(out, "seal", u64(b.status), SEAL_NAMES[:])
		emit_usage(out, "usage", b.usage)
	case convo.Interrupted:
		_delta_head(s, o, out, "seal", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", obj.Rid{device, b.msg})
		o_str(out, "seal", "interrupted")
	case convo.Leaf:
		_delta_head(s, o, out, "leaf", rid, device, rec.env.kind, b.hlc)
		o_rid(out, "msg", _resolve(o, vs, b.msg))
	case convo.Queue:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
		o_str(out, "text", b.text)
	case convo.Steer:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
		o_str(out, "text", b.text)
		o_rid(out, "msg", _resolve(o, vs, b.msg))
	case convo.Edit_Queued:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
		o_str(out, "text", b.text)
		o_rid(out, "msg", _resolve(o, vs, b.item))
	case convo.Cancel:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.item))
	case convo.Interrupt:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.msg))
	case convo.Answer:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
		o_str(out, "text", b.text)
		o_rid(out, "msg", _resolve(o, vs, b.request))
	case convo.Await:
		_delta_head(s, o, out, "intent", rid, device, rec.env.kind, rec.stamp)
	case convo.Assign:
		_delta_head(s, o, out, "run", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.msg))
	case convo.Claim:
		_delta_head(s, o, out, "run", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.msg))
	case convo.Unqueue:
		_delta_head(s, o, out, "run", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.item))
	case convo.Superseded:
		_delta_head(s, o, out, "run", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.run))
	case convo.Landed:
		_delta_head(s, o, out, "run", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", _resolve(o, vs, b.run))
	case convo.Revived:
		_delta_head(s, o, out, "run", rid, device, rec.env.kind, rec.stamp)
		o_rid(out, "msg", obj.Rid{device, b.msg})
	case convo.Mount:
		_delta_head(s, o, out, "mount", rid, device, rec.env.kind, rec.stamp)
		o_str(out, "text", b.name)
	case convo.Unmount:
		_delta_head(s, o, out, "mount", rid, device, rec.env.kind, rec.stamp)
		o_str(out, "text", b.name)
		o_bool(out, "removed", true)
	case convo.Fork, convo.Remember, convo.Forks, convo.Compact, convo.Scope, convo.Recorded, convo.Spine, convo.Files:
		_delta_head(s, o, out, "record", rid, device, rec.env.kind, rec.stamp)
	case:
		_delta_head(s, o, out, "record", rid, device, rec.env.kind, rec.stamp)
	}
	o_end(out)
	return 1
}

@(private)
_delta_map :: proc(s: ^Session, o: ^Object, device: prim.Id, at: i64, body: []u8, out: ^Out) -> (n: int) {
	env, err := obj.decode_envelope(body, at)
	if err != .None {
		return 0
	}
	b, berr := omap.decode_body(&env, context.temp_allocator)
	if berr != .None {
		return 0
	}
	rid := obj.Rid{device, at}
	switch v in b {
	case omap.Put:
		if o.catalog {
			_delta_head(s, o, out, "catalog", rid, device, env.kind, env.links.stamp)
			o_bytes(out, "key", v.key)
			o_end(out)
			return 1
		}
		for f in v.fields {
			_delta_head(s, o, out, "field", rid, device, env.kind, f.hlc)
			o_bytes(out, "key", v.key)
			o_u64(out, "tag", u64(f.tag))
			o_bytes(out, "value", f.value)
			o_end(out)
			n += 1
		}
	case omap.Add:
		_delta_head(s, o, out, "catalog" if o.catalog else "element", rid, device, env.kind, env.links.stamp)
		o_bytes(out, "key", v.key)
		o_u64(out, "tag", u64(v.tag))
		o_bytes(out, "value", v.element)
		o_end(out)
		n += 1
	case omap.Del:
		_delta_head(s, o, out, "catalog" if o.catalog else "element", rid, device, env.kind, env.links.stamp)
		o_bytes(out, "key", v.key)
		o_u64(out, "tag", u64(v.tag))
		o_bytes(out, "value", v.element)
		o_bool(out, "removed", true)
		o_end(out)
		n += 1
	case omap.Count:
		_delta_head(s, o, out, "catalog" if o.catalog else "counter", rid, device, env.kind, env.links.stamp)
		o_bytes(out, "key", v.key)
		o_u64(out, "tag", u64(v.tag))
		o_i64(out, "length", v.delta)
		o_end(out)
		n += 1
	}
	return
}

package api

import "../../convo"
import eng "../../engine"
import "../../prim"
import rt "../../runtime"

Sub_Proc :: #type proc(data: rawptr, id: u64, payload: []u8)

Raw_Sub_Proc :: #type proc(data: rawptr, id: u64, deltas: []eng.Delta)

Sub :: struct {
	api:    ^Api,
	id:     u64,
	engine: eng.Sub_Id,
	json:   bool,
	cb:     Sub_Proc,
	raw:    Raw_Sub_Proc,
	data:   rawptr,
	catalog: bool,
	object: Object,
}

subscribe_raw :: proc(a: ^Api, req: []u8, json_form: bool, raw: Raw_Sub_Proc, data: rawptr) -> (id: u64, catalog: bool, object: Object, status: Status) {
	if raw == nil {
		return 0, false, {}, .Invalid
	}
	id, status = _subscribe(a, req, json_form, nil, raw, data)
	for s in a.subs {
		if s.id == id {
			catalog = s.catalog
			object = s.object
		}
	}
	return
}

subscribe :: proc(a: ^Api, req: []u8, json_form: bool, cb: Sub_Proc, data: rawptr) -> (id: u64, status: Status) {
	if cb == nil {
		return 0, .Invalid
	}
	return _subscribe(a, req, json_form, cb, nil, data)
}

@(private)
_subscribe :: proc(a: ^Api, req: []u8, json_form: bool, cb: Sub_Proc, raw: Raw_Sub_Proc, data: rawptr) -> (id: u64, status: Status) {
	c: Call
	c.api = a
	c.json = json_form
	if st := _decode(a, &c, req, context.temp_allocator); st != .Ok {
		return 0, st
	}
	catalog := false
	switch c.op.name {
	case "subscribe":
	case "subscribe.catalog":
		catalog = true
	case:
		return 0, .Bad_Request
	}
	s := new(Sub, a.allocator)
	s.api = a
	s.json = json_form
	s.cb = cb
	s.raw = raw
	s.catalog = catalog
	s.data = data
	err: eng.Error
	if catalog {
		s.engine, err = eng.subscribe_catalog(a.e, a_id(&c, "space"), _on_deltas, s)
	} else {
		kind := eng.Kind(a_u64(&c, "kind"))
		if kind < .Conversation || kind > .File_Tree {
			free(s, a.allocator)
			return 0, .Invalid
		}
		s.object = a_object(&c, "object")
		s.engine, err = eng.subscribe(a.e, s.object, kind, _on_deltas, s)
	}
	if err != .None {
		free(s, a.allocator)
		return 0, status_of(err)
	}
	a.next_sub += 1
	s.id = a.next_sub
	append(&a.subs, s)
	return s.id, .Ok
}

unsubscribe :: proc(a: ^Api, id: u64) {
	for s, i in a.subs {
		if s.id == id {
			ordered_remove(&a.subs, i)
			eng.unsubscribe(a.e, s.engine)
			free(s, a.allocator)
			return
		}
	}
}

@(private)
_on_deltas :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	s := (^Sub)(data)
	if s.raw != nil {
		s.raw(s.data, s.id, deltas)
		return
	}
	s.cb(s.data, s.id, encode_deltas(deltas, s.json))
}

encode_deltas :: proc(deltas: []eng.Delta, json_form: bool, allocator := context.temp_allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, json_form)
	o_arr(&o, "deltas", len(deltas))
	for &d in deltas {
		emit_delta(&o, &d)
	}
	o_end(&o)
	return out_finish(&o)
}

encode_event :: proc(ev: ^eng.Event, json_form: bool, allocator := context.temp_allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, json_form)
	o_enum(&o, "kind", event_code(ev.kind), EVENT_NAMES[:])
	o_id(&o, "space", ev.space)
	o_id(&o, "object", ev.object)
	o_id(&o, "device", ev.device)
	o_u64(&o, "tick", ev.tick)
	o_i64(&o, "length", ev.length)
	o_enum(&o, "status", u64(status_of(ev.err)), STATUS_NAMES[:])
	o_str(&o, "detail", ev.detail)
	emit_placement(&o, &rt.Placement_Info{})
	return out_finish(&o)
}

encode_placement_event :: proc(ob: Object, info: rt.Placement_Info, json_form: bool, allocator := context.temp_allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, json_form)
	o_enum(&o, "kind", EVENT_PLACEMENT, EVENT_NAMES[:])
	o_id(&o, "space", ob.space)
	o_id(&o, "object", ob.id)
	o_id(&o, "device", {})
	o_u64(&o, "tick", 0)
	o_i64(&o, "length", 0)
	o_enum(&o, "status", 0, STATUS_NAMES[:])
	o_str(&o, "detail", "")
	x := info
	emit_placement(&o, &x)
	return out_finish(&o)
}

encode_deltas_compact :: proc(deltas: []eng.Delta, sub_object: Object, allocator := context.temp_allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	o: Out
	out_init(&o, &buf, true)
	o_arr(&o, "deltas", len(deltas))
	for &d in deltas {
		o_obj(&o, "")
		o_enum(&o, "kind", u64(d.kind), DELTA_NAMES[:])
		if d.object != sub_object {
			o_object(&o, "object", d.object)
		}
		if !prim.id_is_zero(d.rid.seg) {
			o_rid(&o, "rid", d.rid)
		}
		if !prim.id_is_zero(d.msg.seg) {
			o_rid(&o, "msg", d.msg)
		}
		if d.record != 0 {
			o_u64(&o, "record", u64(d.record))
		}
		if !prim.id_is_zero(d.by) {
			o_id(&o, "by", d.by)
		}
		if d.local {
			o_bool(&o, "local", true)
		}
		if d.hlc != 0 {
			o_u64(&o, "hlc", u64(d.hlc))
		}
		if d.role != convo.Role(0) {
			o_enum(&o, "role", u64(d.role), ROLE_NAMES[:])
		}
		if d.index != 0 {
			o_u64(&o, "index", u64(d.index))
		}
		if d.block != convo.Block_Kind(0) {
			o_enum(&o, "block", u64(d.block), BLOCK_NAMES[:])
		}
		if d.seal != convo.Seal_Status(0) {
			o_enum(&o, "seal", u64(d.seal), SEAL_NAMES[:])
		}
		if d.status != convo.Status(0) {
			o_enum(&o, "status", u64(d.status), CONVO_STATUS_NAMES[:])
		}
		if d.usage != {} {
			emit_usage(&o, "usage", d.usage)
		}
		if len(d.text) > 0 {
			o_text(&o, "text", d.text)
		}
		if len(d.key) > 0 {
			o_bytes(&o, "key", d.key)
		}
		if d.tag != 0 {
			o_u64(&o, "tag", u64(d.tag))
		}
		if d.removed {
			o_bool(&o, "removed", true)
		}
		if d.length != 0 {
			o_i64(&o, "length", d.length)
		}
		o_end(&o)
	}
	o_end(&o)
	return out_finish(&o)
}

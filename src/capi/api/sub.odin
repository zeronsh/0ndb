package api

import eng "../../engine"
import rt "../../runtime"

Sub_Proc :: #type proc(data: rawptr, id: u64, payload: []u8)

Sub :: struct {
	api:    ^Api,
	id:     u64,
	engine: eng.Sub_Id,
	json:   bool,
	cb:     Sub_Proc,
	data:   rawptr,
}

subscribe :: proc(a: ^Api, req: []u8, json_form: bool, cb: Sub_Proc, data: rawptr) -> (id: u64, status: Status) {
	if cb == nil {
		return 0, .Invalid
	}
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
		s.engine, err = eng.subscribe(a.e, a_object(&c, "object"), kind, _on_deltas, s)
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
	buf := make([dynamic]u8, context.temp_allocator)
	o: Out
	out_init(&o, &buf, s.json)
	o_arr(&o, "deltas", len(deltas))
	for &d in deltas {
		emit_delta(&o, &d)
	}
	o_end(&o)
	s.cb(s.data, s.id, out_finish(&o))
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

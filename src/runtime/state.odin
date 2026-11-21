package rt

import eng "../engine"
import omap "../map"
import "../prim"

@(private)
KEY_RUN :: "run/"
@(private)
KEY_CLAIMED :: "m/"
@(private)
KEY_AWAIT :: "aw/"

Run_Entry :: struct {
	object: Object,
	user:   Rid,
	reply:  Rid,
	claim:  Rid,
	agent:  prim.Id,
	lines:  []u8,
}

Named :: struct {
	space:  prim.Id,
	name:   string,
	parent: prim.Id,
}

named_obj :: proc(n: Named) -> Object {
	return Object{n.space, eng.named_id(n.space, n.name, n.parent)}
}

named_w :: proc(r: ^Runtime, n: Named) -> Object {
	o, err := eng.map_named(r.e, n.space, n.name, Object{n.space, n.parent}, true)
	if err != .None {
		return named_obj(n)
	}
	return o
}

runners_named :: proc(space: prim.Id) -> Named {
	return Named{space, "0ndb:runners", {}}
}

schedules_named :: proc(space: prim.Id) -> Named {
	return Named{space, "0ndb:schedules", {}}
}

routes_named :: proc(space: prim.Id) -> Named {
	return Named{space, "0ndb:routes", {}}
}

state_named :: proc(r: ^Runtime, space: prim.Id) -> Named {
	return Named{space, concat("0ndb:runner-state:", hex(r.self)), {}}
}

meta_named :: proc(o: Object) -> Named {
	return Named{o.space, "0ndb:meta", o.id}
}

memory_named :: proc(space: prim.Id) -> Named {
	return Named{space, "0ndb:memory", {}}
}

runners_object :: proc(space: prim.Id) -> Object {
	return named_obj(runners_named(space))
}

schedules_object :: proc(space: prim.Id) -> Object {
	return named_obj(schedules_named(space))
}

routes_object :: proc(space: prim.Id) -> Object {
	return named_obj(routes_named(space))
}

state_object :: proc(r: ^Runtime, space: prim.Id) -> Object {
	return named_obj(state_named(r, space))
}

meta_object :: proc(o: Object) -> Object {
	return named_obj(meta_named(o))
}

meta_w :: proc(r: ^Runtime, o: Object) -> Object {
	return named_w(r, meta_named(o))
}

state_w :: proc(r: ^Runtime, space: prim.Id) -> Object {
	return named_w(r, state_named(r, space))
}

key_of :: proc(prefix: string, parts: ..[]u8) -> []u8 {
	b := make([dynamic]u8, 0, len(prefix) + 48, context.temp_allocator)
	append(&b, prefix)
	for p in parts {
		append(&b, ..p)
	}
	return b[:]
}

rid_bytes :: proc(rid: Rid) -> []u8 {
	out := make([]u8, 24, context.temp_allocator)
	s := rid.seg
	copy(out, s[:])
	prim.put_u64le(out[16:], u64(rid.off))
	return out
}

rid_from_bytes :: proc(b: []u8) -> (rid: Rid, ok: bool) {
	if len(b) != 24 {
		return {}, false
	}
	copy(rid.seg[:], b[:16])
	rid.off = i64(prim.get_u64le(b[16:]))
	return rid, true
}

field_rid :: proc(tag: u32, rid: Rid) -> omap.Field {
	return omap.Field{tag = tag, value = rid_bytes(rid)}
}

field_bytes :: proc(tag: u32, b: []u8) -> omap.Field {
	return omap.Field{tag = tag, value = b}
}

entry_rid :: proc(en: ^omap.Entry, tag: u32) -> Rid {
	if v, ok := omap.entry_register(en, tag); ok {
		if rid, rok := rid_from_bytes(v); rok {
			return rid
		}
	}
	return {}
}

entry_str :: proc(en: ^omap.Entry, tag: u32) -> string {
	if v, ok := omap.entry_register(en, tag); ok {
		return string(v)
	}
	return ""
}

entry_bytes :: proc(en: ^omap.Entry, tag: u32) -> []u8 {
	if v, ok := omap.entry_register(en, tag); ok {
		return v
	}
	return nil
}

entry_u64 :: proc(en: ^omap.Entry, tag: u32) -> u64 {
	if v, ok := omap.entry_register(en, tag); ok {
		x, _ := omap.value_u64(v)
		return x
	}
	return 0
}

entry_bool :: proc(en: ^omap.Entry, tag: u32) -> bool {
	if v, ok := omap.entry_register(en, tag); ok {
		x, _ := omap.value_bool(v)
		return x
	}
	return false
}

entry_id :: proc(en: ^omap.Entry, tag: u32) -> prim.Id {
	if v, ok := omap.entry_register(en, tag); ok {
		x, _ := omap.value_id(v)
		return x
	}
	return {}
}

entry_live :: proc(en: ^omap.Entry) -> bool {
	for r in en.registers {
		if len(r.value) > 0 {
			return true
		}
	}
	for e in en.elements {
		if len(e.live) > 0 {
			return true
		}
	}
	return false
}

map_put :: proc(r: ^Runtime, o: Object, key: []u8, fields: ..omap.Field) -> Error {
	_, err := eng.map_set(r.e, o, key, fields)
	return _eerr(err)
}

map_clear :: proc(r: ^Runtime, o: Object, key: []u8, tags: ..u32) -> Error {
	return _eerr(eng.map_delete(r.e, o, key, tags))
}

map_read :: proc(r: ^Runtime, o: Object, key: []u8) -> (en: omap.Entry, found: bool) {
	e, f, err := eng.map_get(r.e, o, key, context.temp_allocator)
	if err != .None && err != .Pending {
		return {}, false
	}
	if !f || !entry_live(&e) {
		return {}, false
	}
	return e, true
}

map_rows :: proc(r: ^Runtime, o: Object, prefix: []u8, limit := 4096) -> []omap.Row {
	out := make([dynamic]omap.Row, context.temp_allocator)
	cur: eng.Map_Cursor
	for {
		rows, more, err := eng.map_scan(r.e, o, prefix, &cur, min(limit - len(out), 512), context.temp_allocator)
		if err != .None && err != .Pending {
			break
		}
		for &row in rows {
			if entry_live(&row.entry) {
				append(&out, row)
			}
		}
		if !more || len(rows) == 0 || len(out) >= limit {
			break
		}
		clear(&cur.key)
		append(&cur.key, ..rows[len(rows) - 1].key)
		cur.valid = true
	}
	delete(cur.key)
	return out[:]
}

@(private)
_eerr :: proc "contextless" (err: eng.Error) -> Error {
	#partial switch err {
	case .None, .Pending:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Invalid:
		return .Invalid
	case .Busy:
		return .Busy
	case .Not_Assigned:
		return .Not_Assigned
	case .Permission:
		return .Permission
	case .Limit, .Too_Large:
		return .Limit
	case .Closed:
		return .Closed
	case .Unsupported:
		return .Unsupported
	}
	return .Engine
}

state_run_put :: proc(r: ^Runtime, ent: Run_Entry) -> Error {
	so := state_w(r, ent.object.space)
	id := ent.object.id
	return map_put(r, so, key_of(KEY_RUN, id[:]), field_rid(1, ent.user), field_rid(2, ent.reply), field_rid(3, ent.claim), omap.field_id(4, ent.agent), field_bytes(5, ent.lines))
}

state_run_get :: proc(r: ^Runtime, o: Object) -> (ent: Run_Entry, found: bool) {
	id := o.id
	en, ok := map_read(r, state_object(r, o.space), key_of(KEY_RUN, id[:]))
	if !ok {
		return {}, false
	}
	ent.object = o
	ent.user = entry_rid(&en, 1)
	ent.reply = entry_rid(&en, 2)
	ent.claim = entry_rid(&en, 3)
	ent.agent = entry_id(&en, 4)
	ent.lines = entry_bytes(&en, 5)
	return ent, !prim.id_is_zero(ent.reply.seg)
}

state_run_clear :: proc(r: ^Runtime, o: Object) {
	id := o.id
	map_clear(r, state_object(r, o.space), key_of(KEY_RUN, id[:]), 1, 2, 3, 4, 5)
}

state_runs :: proc(r: ^Runtime, space: prim.Id) -> []Run_Entry {
	rows := map_rows(r, state_object(r, space), transmute([]u8)string(KEY_RUN))
	out := make([dynamic]Run_Entry, 0, len(rows), context.temp_allocator)
	for &row in rows {
		if len(row.key) != len(KEY_RUN) + 16 {
			continue
		}
		ent: Run_Entry
		copy(ent.object.id[:], row.key[len(KEY_RUN):])
		ent.object.space = space
		ent.user = entry_rid(&row.entry, 1)
		ent.reply = entry_rid(&row.entry, 2)
		ent.claim = entry_rid(&row.entry, 3)
		ent.agent = entry_id(&row.entry, 4)
		ent.lines = entry_bytes(&row.entry, 5)
		if !prim.id_is_zero(ent.reply.seg) {
			append(&out, ent)
		}
	}
	return out[:]
}

state_claimed :: proc(r: ^Runtime, o: Object, msg: Rid) -> bool {
	id := o.id
	_, ok := map_read(r, state_object(r, o.space), key_of(KEY_CLAIMED, id[:], rid_bytes(msg)))
	return ok
}

state_mark_claimed :: proc(r: ^Runtime, o: Object, msg: Rid, claim: Rid) {
	id := o.id
	map_put(r, state_w(r, o.space), key_of(KEY_CLAIMED, id[:], rid_bytes(msg)), field_rid(1, claim))
}

runner_known :: proc(r: ^Runtime, space: prim.Id, device: prim.Id) -> bool {
	if device == r.self {
		return r.cfg.runner
	}
	d := device
	en, ok := map_read(r, runners_object(space), d[:])
	if !ok {
		return false
	}
	return entry_u64(&en, 1) > 0
}

@(private)
_advertise :: proc(r: ^Runtime, space: prim.Id) {
	me := r.self
	en, ok := map_read(r, runners_object(space), me[:])
	if ok && entry_u64(&en, 1) == u64(r.cfg.capacity) {
		return
	}
	map_put(r, named_w(r, runners_named(space)), me[:], omap.field_u64(1, u64(r.cfg.capacity)))
}

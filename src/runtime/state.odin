package rt

import "core:slice"
import "core:strings"
import eng "../engine"
import omap "../map"
import "../obj"
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
	bound:  []u8,
	hold:   u8,
	hold_line: string,
	hold_commit: string,
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
	out := make([]u8, 32, context.temp_allocator)
	s := rid.seg
	copy(out, s[:])
	prim.put_u64le(out[16:24], u64(rid.off))
	prim.put_u64le(out[24:32], rid.gen)
	return out
}

rid_key :: proc(rid: Rid) -> []u8 {
	return rid_bytes(rid)[:24]
}

rid_from_bytes :: proc(b: []u8) -> (rid: Rid, ok: bool) {
	if len(b) != 24 && len(b) != 32 {
		return {}, false
	}
	copy(rid.seg[:], b[:16])
	rid.off = i64(prim.get_u64le(b[16:24]))
	if len(b) == 32 {
		rid.gen = prim.get_u64le(b[24:32])
	}
	return rid, true
}

rid_bytes_match :: proc(stored: []u8, rid: Rid) -> bool {
	full := rid_bytes(rid)
	switch len(stored) {
	case 24:
		return string(stored) == string(full[:24])
	case 32:
		return string(stored) == string(full)
	}
	return false
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
	return map_put(r, so, key_of(KEY_RUN, id[:]), field_rid(1, ent.user), field_rid(2, ent.reply), field_rid(3, ent.claim), omap.field_id(4, ent.agent), field_bytes(5, ent.lines), field_bytes(6, ent.bound), field_bytes(7, []u8{ent.hold}), field_bytes(8, transmute([]u8)ent.hold_line), field_bytes(9, transmute([]u8)ent.hold_commit))
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
	ent.bound = entry_bytes(&en, 6)
	if hb := entry_bytes(&en, 7); len(hb) == 1 {
		ent.hold = hb[0]
	}
	ent.hold_line = string(entry_bytes(&en, 8))
	ent.hold_commit = string(entry_bytes(&en, 9))
	return ent, !prim.id_is_zero(ent.reply.seg)
}

state_run_clear :: proc(r: ^Runtime, o: Object) {
	id := o.id
	map_clear(r, state_object(r, o.space), key_of(KEY_RUN, id[:]), 1, 2, 3, 4, 5, 6, 7, 8, 9)
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
		ent.bound = entry_bytes(&row.entry, 6)
		if hb := entry_bytes(&row.entry, 7); len(hb) == 1 {
			ent.hold = hb[0]
		}
		ent.hold_line = string(entry_bytes(&row.entry, 8))
		ent.hold_commit = string(entry_bytes(&row.entry, 9))
		if !prim.id_is_zero(ent.reply.seg) {
			append(&out, ent)
		}
	}
	return out[:]
}

state_claimed :: proc(r: ^Runtime, o: Object, msg: Rid) -> bool {
	id := o.id
	_, ok := map_read(r, state_object(r, o.space), key_of(KEY_CLAIMED, id[:], rid_key(msg)))
	return ok
}

state_mark_claimed :: proc(r: ^Runtime, o: Object, msg: Rid, claim: Rid) {
	id := o.id
	map_put(r, state_w(r, o.space), key_of(KEY_CLAIMED, id[:], rid_key(msg)), field_rid(1, claim))
}

runner_known :: proc(r: ^Runtime, space: prim.Id, device: prim.Id) -> bool {
	return runner_live(r, space, device, "")
}

PROVIDER_NATIVE :: "native"

placement_provider :: proc(a: ^Agent_Info) -> string {
	if len(a.provider) == 0 {
		return ""
	}
	if a.kind == .Native {
		return PROVIDER_NATIVE
	}
	return a.provider
}

runner_live :: proc(r: ^Runtime, space: prim.Id, device: prim.Id, provider: string) -> bool {
	if prim.id_is_zero(device) {
		return false
	}
	if device == r.self {
		return r.cfg.runner && !r.closing && (len(provider) == 0 || _list_has(_providers_local(r), provider))
	}
	if !runner_present(r, space, device) {
		return false
	}
	d := device
	en, ok := map_read(r, runners_object(space), d[:])
	if !ok {
		return false
	}
	return _advert_ok(&en, provider)
}

runner_present :: proc(r: ^Runtime, space: prim.Id, device: prim.Id) -> bool {
	if device == r.self {
		return true
	}
	up, _, known := eng.presence(r.e, space, device)
	return up || !known
}

runner_gone :: proc(r: ^Runtime, space: prim.Id, device: prim.Id) -> bool {
	if device == r.self || prim.id_is_zero(device) {
		return false
	}
	if !runner_present(r, space, device) {
		return true
	}
	d := device
	en, ok := map_read(r, runners_object(space), d[:])
	return ok && entry_u64(&en, 1) == 0
}

runners_loaded :: proc(r: ^Runtime, o: Object, wait: bool) -> bool {
	ready := _wait_ready(r, o) if wait else eng.Ready{}
	if wait && ready.call == nil {
		return false
	}
	cur: eng.Map_Cursor
	_, _, err := eng.map_scan(r.e, runners_object(o.space), nil, &cur, 1, context.temp_allocator, ready)
	delete(cur.key)
	if err == .Pending {
		return false
	}
	_wait_drop(r, ready)
	return true
}

runners_live :: proc(r: ^Runtime, space: prim.Id, provider: string) -> []prim.Id {
	out := make([dynamic]prim.Id, context.temp_allocator)
	for &row in map_rows(r, runners_object(space), nil) {
		if len(row.key) != 16 {
			continue
		}
		id: prim.Id
		copy(id[:], row.key)
		if id == r.self {
			if runner_live(r, space, id, provider) {
				append(&out, id)
			}
			continue
		}
		if _advert_ok(&row.entry, provider) && runner_present(r, space, id) {
			append(&out, id)
		}
	}
	return out[:]
}

@(private)
_advert_ok :: proc(en: ^omap.Entry, provider: string) -> bool {
	if entry_u64(en, 1) == 0 {
		return false
	}
	if len(provider) == 0 {
		return true
	}
	list, has := omap.entry_register(en, 2)
	if !has {
		return true
	}
	return _list_has(string(list), provider)
}

@(private)
_list_has :: proc(list: string, item: string) -> bool {
	rest := list
	for len(rest) > 0 {
		n := strings.index_byte(rest, '\n')
		cur := rest if n < 0 else rest[:n]
		if cur == item {
			return true
		}
		if n < 0 {
			break
		}
		rest = rest[n + 1:]
	}
	return false
}

@(private)
_providers_local :: proc(r: ^Runtime) -> string {
	ids := make([dynamic]string, context.temp_allocator)
	append(&ids, PROVIDER_NATIVE)
	for d in r.registry.list {
		desc, ok := _descriptor(r, d.id)
		if ok && len(desc.argv) > 0 && _exe_found(r, desc.argv[0]) {
			append(&ids, d.id)
		}
	}
	slice.sort(ids[:])
	return strings.join(ids[:], "\n", context.temp_allocator)
}

@(private)
_exe_found :: proc(r: ^Runtime, name: string) -> bool {
	when ODIN_OS == .Windows {
		env: []string
		for kv in r.cfg.env {
			if len(kv) > 5 && strings.equal_fold(kv[:5], "PATH=") {
				env = r.cfg.env
			}
		}
		_, _, err := prim.resolve_executable(name, env, context.temp_allocator)
		return err == .None
	}
	vfs := prim.os_vfs()
	if strings.index_byte(name, '/') >= 0 {
		return prim.exists(vfs, name)
	}
	path := ""
	found := false
	for kv in r.cfg.env {
		if strings.has_prefix(kv, "PATH=") {
			path = kv[5:]
			found = true
		}
	}
	if !found {
		path, _ = prim.getenv("PATH")
	}
	rest := path
	for len(rest) > 0 {
		n := strings.index_byte(rest, ':')
		dir := rest if n < 0 else rest[:n]
		if len(dir) > 0 && prim.exists(vfs, concat(dir, "/", name)) {
			return true
		}
		if n < 0 {
			break
		}
		rest = rest[n + 1:]
	}
	return false
}

@(private)
_advertise :: proc(r: ^Runtime, space: prim.Id, capacity: int) {
	me := r.self
	provs := _providers_local(r)
	pool := u64(1) if r.cfg.pool else 0
	signed := _providers_signed_in(r, provs)
	pool_id := _pool_of(r, space)
	name := runner_name(r)
	en, found, gerr := eng.map_get(r.e, runners_object(space), me[:], context.temp_allocator)
	if gerr == .Pending {
		return
	}
	ok := gerr == .None && found && entry_live(&en)
	if ok && entry_u64(&en, 1) == u64(capacity) && entry_str(&en, 2) == provs && entry_u64(&en, 3) == pool && entry_str(&en, 4) == signed && entry_str(&en, 5) == name && entry_id(&en, 6) == pool_id {
		return
	}
	if !ok && capacity == 0 {
		return
	}
	map_put(r, named_w(r, runners_named(space)), me[:], omap.field_u64(1, u64(capacity)), field_bytes(2, transmute([]u8)provs), omap.field_u64(3, pool), field_bytes(4, transmute([]u8)signed), omap.field_str(5, name), omap.field_id(6, pool_id))
}

runner_pool :: proc(r: ^Runtime, space: prim.Id, device: prim.Id) -> bool {
	if device == r.self {
		return r.cfg.pool
	}
	d := device
	en, ok := map_read(r, runners_object(space), d[:])
	return ok && entry_u64(&en, 3) != 0
}

@(private)
_promote_for_run :: proc(r: ^Runtime, o: Object, msg: Rid, runner: prim.Id) {
	if !runner_pool(r, o.space, runner) {
		return
	}
	if c, err := eng.storage_class(r.e, o); err != .None || c != .Device {
		return
	}
	eng.object_promote_run(r.e, o, msg)
	if ms, err := eng.convo_mounts(r.e, o, context.temp_allocator); err == .None {
		for m in ms {
			if !m.removed {
				eng.object_promote_run(r.e, Object{o.space, m.tree})
			}
		}
	}
}

pending_named :: proc(space: prim.Id) -> Named {
	return Named{space, "0ndb:pending", {}}
}

pending_object :: proc(space: prim.Id) -> Object {
	return named_obj(pending_named(space))
}

Pending_Entry :: struct {
	msg:      Rid,
	provider: string,
	since_ms: i64,
	runner:   prim.Id,
	assigned: bool,
	idle:     bool,
}

pending_get :: proc(r: ^Runtime, o: Object) -> (p: Pending_Entry, ok: bool) {
	id := o.id
	en, found := map_read(r, pending_object(o.space), id[:])
	if !found {
		return {}, false
	}
	p.msg = entry_rid(&en, 1)
	if obj.rid_none(p.msg) {
		return {}, false
	}
	p.provider = entry_str(&en, 2)
	p.since_ms = i64(entry_u64(&en, 3))
	p.runner = entry_id(&en, 4)
	p.assigned = entry_bool(&en, 5)
	p.idle = entry_bool(&en, 6)
	return p, true
}

@(private)
_pending_put :: proc(r: ^Runtime, o: Object, p: Pending_Entry) -> bool {
	if old, ok := pending_get(r, o); ok && old.msg == p.msg && old.provider == p.provider && old.runner == p.runner && old.assigned == p.assigned && old.idle == p.idle {
		return false
	}
	id := o.id
	map_put(r, named_w(r, pending_named(o.space)), id[:], field_rid(1, p.msg), field_bytes(2, transmute([]u8)p.provider), omap.field_u64(3, u64(p.since_ms)), omap.field_id(4, p.runner), omap.field_bool(5, p.assigned), omap.field_bool(6, p.idle))
	return true
}

@(private)
_pending_clear :: proc(r: ^Runtime, o: Object) {
	_asks_drop(r, o)
	if _, ok := pending_get(r, o); !ok {
		return
	}
	id := o.id
	map_clear(r, named_w(r, pending_named(o.space)), id[:], 1, 2, 3, 4, 5, 6)
}

@(private)
_pending_scan :: proc(r: ^Runtime, space: prim.Id, runner: prim.Id = {}) {
	po := pending_object(space)
	ready := _wait_ready(r, po)
	cur: eng.Map_Cursor
	_, _, err := eng.map_scan(r.e, po, nil, &cur, 1, context.temp_allocator, ready)
	delete(cur.key)
	if err == .Pending {
		return
	}
	_wait_drop(r, ready)
	for &row in map_rows(r, po, nil) {
		if len(row.key) != 16 || obj.rid_none(entry_rid(&row.entry, 1)) {
			continue
		}
		if !prim.id_is_zero(runner) && entry_id(&row.entry, 4) != runner {
			continue
		}
		id: prim.Id
		copy(id[:], row.key)
		_queue_eval(r, Object{space, id})
	}
}

@(private)
_on_runners :: proc(data: rawptr, e: ^eng.Engine, sub: eng.Sub_Id, deltas: []eng.Delta) {
	context = eng.context_for((^Runtime)(data).e)
	r := (^Runtime)(data)
	for d in deltas {
		_asks_forget(r, d.object.space)
		readvertise(r, d.object.space)
		_runners_changed(r, d.object.space)
		_pending_scan(r, d.object.space)
		return
	}
}

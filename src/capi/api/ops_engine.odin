package api

import "../../convo"
import eng "../../engine"
import omap "../../map"
import "../../obj"
import "../../prim"
import "../../search"
import rt "../../runtime"
import osync "../../sync"

op_identity :: proc(c: ^Call, o: ^Out) -> Status {
	emit_identity(o, eng.identity(c.api.e))
	return .Ok
}

op_card :: proc(c: ^Call, o: ^Out) -> Status {
	kr := eng.keyring(c.api.e)
	card, err := osync.keyring_card(&kr)
	if err != .None {
		return .Io
	}
	o_bytes(o, "card", card[:])
	return .Ok
}

op_stats :: proc(c: ^Call, o: ^Out) -> Status {
	s := eng.stats(c.api.e)
	o_u64(o, "ticks", s.ticks)
	o_u64(o, "commits", s.commits)
	o_u64(o, "durable", s.durable)
	o_int(o, "handles", s.handles)
	o_u64(o, "opened", s.opened)
	o_u64(o, "evicted", s.evicted)
	o_int(o, "pending", s.pending)
	o_int(o, "subs", s.subs)
	o_u64(o, "fetches", s.fetches)
	o_u64(o, "indexed", s.indexed)
	o_u64(o, "wakeups", s.wakeups)
	o_int(o, "calls", len(c.api.calls))
	o_int(o, "mounts", len(c.api.mounts))
	o_u64(o, "fetched_bytes", s.fetched_bytes)
	o_u64(o, "base_merged", s.base_merged)
	o_u64(o, "base_current", s.base_current)
	o_u64(o, "base_mismatch", s.base_mismatch)
	o_u64(o, "base_not_text", s.base_not_text)
	return .Ok
}

op_flush :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.flush(c.api.e))
}

op_describe :: proc(c: ^Call, o: ^Out) -> Status {
	b := describe(c.api, c.json, context.temp_allocator)
	if c.json {
		o_raw_json(o, "description", string(b))
	} else {
		o_bytes(o, "description", b)
	}
	return .Ok
}

@(private)
_relay_key :: proc(c: ^Call) -> (k: osync.Public_Key, ok: bool) {
	b := a_bytes(c, "relay_key")
	if len(b) == 0 {
		return k, true
	}
	if len(b) != len(k) {
		return k, false
	}
	copy(k[:], b)
	return k, true
}

op_space_create :: proc(c: ^Call, o: ^Out) -> Status {
	rk, ok := _relay_key(c)
	if !ok {
		return .Invalid
	}
	id, err := eng.space_create(c.api.e, a_str(c, "name"), a_str(c, "relay"), rk, osync.Encryption_Mode(min(a_u64(c, "mode"), 1)))
	if err != .None {
		return status_of(err)
	}
	_attach(c, id)
	o_id(o, "space", id)
	return .Ok
}

op_space_list :: proc(c: ^Call, o: ^Out) -> Status {
	list := eng.space_list(c.api.e, context.temp_allocator)
	o_arr(o, "spaces", len(list))
	for &s in list {
		emit_space(o, &s)
	}
	o_end(o)
	return .Ok
}

op_space_info :: proc(c: ^Call, o: ^Out) -> Status {
	s, err := eng.space_info(c.api.e, a_id(c, "space"))
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "space", 1)
	emit_space(o, &s)
	o_end(o)
	return .Ok
}

op_space_set_relay :: proc(c: ^Call, o: ^Out) -> Status {
	rk, ok := _relay_key(c)
	if !ok {
		return .Invalid
	}
	return status_of(eng.space_set_relay(c.api.e, a_id(c, "space"), a_str(c, "relay"), rk))
}

op_space_relay_account :: proc(c: ^Call, o: ^Out) -> Status {
	s, seen, err := eng.space_relay_account(c.api.e, a_id(c, "space"), a_bool(c, "refresh"))
	if err != .None {
		return status_of(err)
	}
	o_bool(o, "accounted", seen)
	o_u64(o, "stored", u64(max(s.stored, 0)))
	o_u64(o, "quota", u64(max(s.quota, 0)))
	o_u64(o, "appends", s.appends)
	o_u64(o, "bytes_in", s.bytes_in)
	o_u64(o, "notes", s.notes)
	o_u64(o, "fills", s.fills)
	o_u64(o, "pulls", s.pulls)
	o_u64(o, "piped_bytes", s.piped_bytes)
	o_u64(o, "store_writes", s.store.writes)
	o_u64(o, "store_bytes", s.store.write_bytes)
	o_u64(o, "pending", u64(max(s.store.pending, 0)))
	o_u64(o, "day", u64(max(s.store.day, 0)))
	o_u64(o, "day_bytes", s.store.day_bytes)
	o_u64(o, "total_bytes", s.store.total_bytes)
	return .Ok
}

op_space_open :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.space_open(c.api.e, a_id(c, "space")))
}

op_space_close :: proc(c: ^Call, o: ^Out) -> Status {
	eng.space_close(c.api.e, a_id(c, "space"))
	return .Ok
}

op_space_join_shared :: proc(c: ^Call, o: ^Out) -> Status {
	rk, ok := _relay_key(c)
	if !ok {
		return .Invalid
	}
	err := eng.space_join_shared(c.api.e, a_id(c, "space"), a_str(c, "name"), a_str(c, "relay"), rk)
	if err != .None && err != .Exists {
		return status_of(err)
	}
	_attach(c, a_id(c, "space"))
	return .Ok
}

op_convo_create :: proc(c: ^Call, o: ^Out) -> Status {
	s := eng.Convo_Settings {
		title     = a_str(c, "title"),
		agent     = a_id(c, "agent"),
		workspace = a_id(c, "workspace"),
		parent    = obj.Xref{object = a_object(c, "parent").id, rid = a_rid(c, "parent_msg")},
		provider  = a_str(c, "provider"),
		model     = a_str(c, "model"),
	}
	ob, err := eng.convo_create(c.api.e, a_id(c, "space"), s, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_convo_status :: proc(c: ^Call, o: ^Out) -> Status {
	st, err := eng.convo_status(c.api.e, a_object(c, "object"), ready(c))
	if err != .None {
		return pend(c, err)
	}
	emit_status(o, &st)
	return .Ok
}

op_convo_page :: proc(c: ^Call, o: ^Out) -> Status {
	from := convo.Position{msg = a_rid(c, "from"), seal = a_rid(c, "from_seal"), seal_known = a_bool(c, "from_known")}
	limit := a_int(c, "limit", 32)
	if limit <= 0 {
		limit = 32
	}
	dir := convo.Direction(min(a_u64(c, "dir"), 1))
	leaf := a_rid(c, "leaf")
	if has(c, "cursor") {
		cur, ok := cursor_decode(a_bytes(c, "cursor"))
		if !ok {
			return .Invalid
		}
		if cur.end {
			empty: convo.Page
			emit_page(o, &empty, cur.dir, cur.leaf)
			return .Ok
		}
		from, dir, leaf = cur.pos, cur.dir, cur.leaf
	}
	p, err := eng.convo_page(c.api.e, a_object(c, "object"), from, min(limit, 4096), context.temp_allocator, ready(c), dir, leaf)
	if err != .None {
		return pend(c, err)
	}
	emit_page(o, &p, dir, leaf)
	return .Ok
}

op_convo_window :: proc(c: ^Call, o: ^Out) -> Status {
	w, err := eng.convo_window(c.api.e, a_object(c, "object"), a_rid(c, "anchor"), min(a_int(c, "before", 16), 4096), min(a_int(c, "after", 16), 4096), a_rid(c, "leaf"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	emit_window(o, &w)
	return .Ok
}

op_convo_peek_switch :: proc(c: ^Call, o: ^Out) -> Status {
	_, w, err := eng.convo_peek_switch(c.api.e, a_object(c, "object"), a_rid(c, "sibling"), min(a_int(c, "before", 16), 4096), min(a_int(c, "after", 16), 4096), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	emit_window(o, &w)
	return .Ok
}

op_convo_message :: proc(c: ^Call, o: ^Out) -> Status {
	m, err := eng.convo_message(c.api.e, a_object(c, "object"), convo.Position{msg = a_rid(c, "msg")}, context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	emit_message(o, "message", &m)
	return .Ok
}

op_convo_siblings :: proc(c: ^Call, o: ^Out) -> Status {
	list, at, err := eng.convo_siblings(c.api.e, a_object(c, "object"), a_rid(c, "msg"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "siblings", len(list))
	for r in list {
		o_rid(o, "", r)
	}
	o_end(o)
	o_int(o, "at", at)
	return .Ok
}

op_convo_intents :: proc(c: ^Call, o: ^Out) -> Status {
	items, err := eng.convo_intents(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "intents", len(items))
	for &it in items {
		emit_intent(o, &it)
	}
	o_end(o)
	return .Ok
}

op_convo_mounts :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.convo_mounts(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "mounts", len(list))
	for &m in list {
		emit_mount_entry(o, &m)
	}
	o_end(o)
	return .Ok
}

op_convo_settings :: proc(c: ^Call, o: ^Out) -> Status {
	s, err := eng.convo_settings(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_str(o, "title", s.title)
	o_id(o, "agent", s.agent)
	o_id(o, "workspace", s.workspace)
	emit_xref(o, "parent", s.parent.rid, s.parent.object)
	o_str(o, "provider", s.provider)
	o_str(o, "model", s.model)
	return .Ok
}

op_convo_files_at :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.convo_files_at(c.api.e, a_object(c, "object"), a_rid(c, "msg"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "files", len(list))
	for &f in list {
		emit_file_delta(o, &f)
	}
	o_end(o)
	return .Ok
}

op_convo_compactions :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.convo_compactions(c.api.e, a_object(c, "object"), prim.Hlc(a_u64(c, "floor")), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "compactions", len(list))
	for x in list {
		o_obj(o, "")
		o_rid(o, "at", x.at)
		o_rid(o, "from", x.from)
		o_rid(o, "to", x.to)
		o_str(o, "summary", x.summary)
		emit_blob(o, "blob", x.blob)
		o_u64(o, "stamp", u64(x.stamp))
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_convo_unsealed :: proc(c: ^Call, o: ^Out) -> Status {
	list, err := eng.convo_unsealed(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "unsealed", len(list))
	for x in list {
		o_obj(o, "")
		o_rid(o, "msg", x.msg)
		o_enum(o, "state", u64(x.state), OPEN_STATE_NAMES[:])
		o_u64(o, "attempt", u64(x.attempt))
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_send :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Send{object = a_object(c, "object"), text = a_str(c, "text"), parent = a_rid(c, "parent"), role = convo.Role(a_u64(c, "role")), attachments = a_attachments(c, "attachments"), provider = a_str(c, "provider"), model = a_str(c, "model")})
}

op_queue :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Queue{object = a_object(c, "object"), text = a_str(c, "text"), attachments = a_attachments(c, "attachments")})
}

op_steer :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Steer{object = a_object(c, "object"), text = a_str(c, "text"), msg = a_rid(c, "msg"), attachments = a_attachments(c, "attachments")})
}

op_edit :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Edit{object = a_object(c, "object"), item = a_rid(c, "item"), text = a_str(c, "text"), attachments = a_attachments(c, "attachments")})
}

op_cancel :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Cancel{object = a_object(c, "object"), item = a_rid(c, "item")})
}

op_interrupt :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Interrupt{object = a_object(c, "object"), msg = a_rid(c, "msg")})
}

op_answer :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Answer{object = a_object(c, "object"), request = a_rid(c, "request"), allow = a_bool(c, "allow"), text = a_str(c, "text")})
}

op_switch :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Switch{object = a_object(c, "object"), sibling = a_rid(c, "sibling")})
}

op_back :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Back{object = a_object(c, "object"), msg = a_rid(c, "msg")})
}

op_follow :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Follow{object = a_object(c, "object")})
}

op_mount :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Mount{object = a_object(c, "object"), name = a_str(c, "name"), tree = a_id(c, "tree"), line = a_id(c, "line"), path = a_str(c, "path")})
}

op_unmount :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Unmount{object = a_object(c, "object"), name = a_str(c, "name")})
}

op_await :: proc(c: ^Call, o: ^Out) -> Status {
	cond := convo.Condition(a_u64(c, "condition"))
	if cond != .Any && cond != .All {
		cond = .All
	}
	return exec(c, o, eng.Cmd_Await{object = a_object(c, "object"), tasks = a_ids(c, "tasks"), condition = cond, deadline = prim.Hlc(a_u64(c, "deadline")), expr = a_str(c, "expr")})
}

op_assign :: proc(c: ^Call, o: ^Out) -> Status {
	if obj.rid_none(a_rid(c, "msg")) && c.api.r != nil {
		err := rt.resume(c.api.r, a_object(c, "object"), a_id(c, "runner"))
		if err == .Pending {
			eng.convo_status(c.api.e, a_object(c, "object"), ready(c))
			if c.waiting {
				return .Pending
			}
			return .Missing
		}
		return _rterr(err)
	}
	return exec(c, o, eng.Cmd_Assign{object = a_object(c, "object"), msg = a_rid(c, "msg"), runner = a_id(c, "runner")})
}

op_redact :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Redact{object = a_object(c, "object"), msg = a_rid(c, "msg")})
}

op_map_create :: proc(c: ^Call, o: ^Out) -> Status {
	ob, err := eng.map_create(c.api.e, a_id(c, "space"), a_str(c, "title"), a_bytes(c, "settings"))
	if err != .None {
		return status_of(err)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_map_get :: proc(c: ^Call, o: ^Out) -> Status {
	en, found, err := eng.map_get(c.api.e, a_object(c, "object"), a_bytes(c, "key"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_bool(o, "found", found)
	emit_entry(o, "entry", &en)
	return .Ok
}

@(private)
_cursor :: proc(b: []u8) -> (cur: omap.Cursor) {
	cur.key = make([dynamic]u8, context.temp_allocator)
	append(&cur.key, ..b)
	cur.valid = len(b) > 0
	return cur
}

op_map_scan :: proc(c: ^Call, o: ^Out) -> Status {
	cur := _cursor(a_bytes(c, "after"))
	limit := a_int(c, "limit", 64)
	if limit <= 0 {
		limit = 64
	}
	pc := &cur
	rows, more, err := eng.map_scan(c.api.e, a_object(c, "object"), a_bytes(c, "prefix"), pc, min(limit, 4096), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "rows", len(rows))
	for &r in rows {
		emit_entry(o, "", &r.entry)
	}
	o_end(o)
	o_bool(o, "more", more)
	o_bytes(o, "next", cur.key[:] if cur.valid else nil)
	return .Ok
}

op_map_set :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Map_Set{object = a_object(c, "object"), key = a_bytes(c, "key"), fields = a_fields(c, "fields")})
}

op_map_delete :: proc(c: ^Call, o: ^Out) -> Status {
	src := a_u64s(c, "tags")
	tags := make([]u32, len(src), context.temp_allocator)
	for t, i in src {
		tags[i] = u32(t)
	}
	return exec(c, o, eng.Cmd_Map_Delete{object = a_object(c, "object"), key = a_bytes(c, "key"), tags = tags})
}

op_map_add :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Map_Add{object = a_object(c, "object"), key = a_bytes(c, "key"), tag = u32(a_u64(c, "tag")), element = a_bytes(c, "element")})
}

op_map_remove :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Map_Remove{object = a_object(c, "object"), key = a_bytes(c, "key"), tag = u32(a_u64(c, "tag")), element = a_bytes(c, "element")})
}

op_map_redact :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.map_redact(c.api.e, a_object(c, "object"), a_bytes(c, "key")))
}

op_text_create :: proc(c: ^Call, o: ^Out) -> Status {
	ob, err := eng.text_create(c.api.e, a_id(c, "space"), a_str(c, "title"), a_str(c, "initial"))
	if err != .None {
		return status_of(err)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_text_read :: proc(c: ^Call, o: ^Out) -> Status {
	data, err := eng.text_read(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_text(o, "text", data)
	return .Ok
}

op_text_spans :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	data, derr := eng.text_read(c.api.e, ob, context.temp_allocator, ready(c))
	if derr != .None {
		return pend(c, derr)
	}
	spans, err := eng.text_spans(c.api.e, ob, context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	emit_spans(o, data, spans)
	return .Ok
}

op_text_edit :: proc(c: ^Call, o: ^Out) -> Status {
	return exec(c, o, eng.Cmd_Text_Edit{object = a_object(c, "object"), pos = a_int(c, "pos"), remove = a_int(c, "remove"), insert = a_str(c, "insert")})
}

op_text_redact :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.text_redact(c.api.e, a_object(c, "object"), a_int(c, "pos"), a_int(c, "len")))
}

op_tree_create :: proc(c: ^Call, o: ^Out) -> Status {
	ob, err := eng.tree_create(c.api.e, a_id(c, "space"), a_str(c, "title"))
	if err != .None {
		return status_of(err)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_tree_read :: proc(c: ^Call, o: ^Out) -> Status {
	data, err := eng.tree_read(c.api.e, a_object(c, "object"), a_str(c, "path"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_text(o, "text", data)
	return .Ok
}

op_tree_list :: proc(c: ^Call, o: ^Out) -> Status {
	names, err := eng.tree_list(c.api.e, a_object(c, "object"), a_str(c, "path"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "names", len(names))
	for n in names {
		o_str(o, "", n)
	}
	o_end(o)
	return .Ok
}

op_tree_write :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.tree_write(c.api.e, a_object(c, "object"), a_str(c, "path"), a_bytes(c, "text")))
}

op_tree_remove :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.tree_remove(c.api.e, a_object(c, "object"), a_str(c, "path")))
}

op_catalog_get :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	en, found, err := eng.catalog_get(c.api.e, ob, context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_bool(o, "found", found)
	emit_catalog_entry(o, "entry", ob.space, &en)
	return .Ok
}

op_catalog_list :: proc(c: ^Call, o: ^Out) -> Status {
	cur := _cursor(a_bytes(c, "after"))
	limit := a_int(c, "limit", 64)
	if limit <= 0 {
		limit = 64
	}
	pc := &cur
	space := a_id(c, "space")
	rows, more, err := eng.catalog_list(c.api.e, space, a_bool(c, "archived"), pc, min(limit, 4096), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "rows", len(rows))
	for &r in rows {
		emit_catalog_row(o, space, &r)
	}
	o_end(o)
	o_bool(o, "more", more)
	o_bytes(o, "next", cur.key[:] if cur.valid else nil)
	return .Ok
}

op_catalog_find :: proc(c: ^Call, o: ^Out) -> Status {
	space := a_id(c, "space")
	rows, err := eng.catalog_find(c.api.e, space, a_str(c, "text"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_arr(o, "rows", len(rows))
	for &r in rows {
		emit_catalog_row(o, space, &r)
	}
	o_end(o)
	return .Ok
}

op_object_uploaded :: proc(c: ^Call, o: ^Out) -> Status {
	up, err := eng.upload_wait(c.api.e, a_object(c, "object"), ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_bool(o, "uploaded", up)
	o_bool(o, "dropped", !up && c.tries > 0)
	return .Ok
}

op_catalog_usage :: proc(c: ^Call, o: ^Out) -> Status {
	u, err := eng.catalog_usage_get(c.api.e, a_object(c, "object"), ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_u64(o, "input", u.input)
	o_u64(o, "output", u.output)
	o_u64(o, "cache_read", u.cache_read)
	o_u64(o, "cache_write", u.cache_write)
	return .Ok
}

CATALOG_SET_ARGS := [eng.Catalog_Field]string {
	.Title     = "title",
	.Archived  = "archived",
	.Pinned    = "pinned",
	.Parent    = "parent",
	.Workspace = "workspace",
	.Agent     = "agent",
	.Storage   = "storage",
	.Takeover  = "takeover",
}

op_catalog_set :: proc(c: ^Call, o: ^Out) -> Status {
	set := transmute(eng.Catalog_Fields)u8(a_u64(c, "set"))
	if !has(c, "set") {
		for name, f in CATALOG_SET_ARGS {
			if has(c, name) {
				set += {f}
			}
		}
	}
	cmd := eng.Cmd_Catalog_Set {
		object    = a_object(c, "object"),
		set       = set,
		title     = a_str(c, "title"),
		archived  = a_bool(c, "archived"),
		pinned    = a_bool(c, "pinned"),
		parent    = obj.Xref{object = a_object(c, "parent").id, rid = a_rid(c, "parent_msg")},
		workspace = a_id(c, "workspace"),
		agent     = a_id(c, "agent"),
		storage   = eng.Storage_Class(min(a_u64(c, "storage"), u64(max(eng.Storage_Class)))),
		takeover  = eng.Takeover(min(a_u64(c, "takeover"), u64(max(eng.Takeover)))),
	}
	return exec(c, o, cmd)
}

op_search :: proc(c: ^Call, o: ^Out) -> Status {
	limit := a_int(c, "limit", 20)
	if limit <= 0 {
		limit = 20
	}
	req := search.Request {
		limit    = min(limit, 1000),
		cursor   = a_bytes(c, "cursor"),
		sort     = search.Sort(min(a_u64(c, "sort"), 1)),
		semantic = a_bool(c, "semantic"),
		collapse = a_bool(c, "collapse"),
		now      = eng.hlc_now(c.api.e),
	}
	space := a_id(c, "space")
	if space == {} || req.semantic || req.collapse {
		res, err := eng.search_query(c.api.e, a_str(c, "query"), req, context.temp_allocator)
		if err != .None {
			return status_of(err)
		}
		emit_results(o, &res)
		return .Ok
	}
	if c.stage == 0 {
		scope := eng.Search_Scope(min(a_u64(c, "scope"), 2))
		id, err := eng.search_everywhere(c.api.e, space, a_str(c, "query"), req, scope, done(c))
		if err != .None {
			return status_of(err)
		}
		c.scratch[0] = id
		c.in_exec = true
		return .Pending
	}
	r := eng.search_result(c.api.e, c.scratch[0])
	if r == nil {
		return status_of(c.err) if c.err != .None else .Io
	}
	emit_search(o, r)
	return .Ok
}

op_search_mode :: proc(c: ^Call, o: ^Out) -> Status {
	space := a_id(c, "space")
	if has(c, "mode") {
		if err := eng.space_search_set(c.api.e, space, eng.Search_Mode(min(a_u64(c, "mode"), 2))); err != .None {
			return status_of(err)
		}
	}
	o_enum(o, "mode", u64(eng.space_search_mode(c.api.e, space)), SEARCH_MODE_NAMES[:])
	return .Ok
}

op_search_wrote :: proc(c: ^Call, o: ^Out) -> Status {
	hits, err := eng.search_wrote(c.api.e, a_id(c, "tree"), a_str(c, "path"), search.Unit(min(a_u64(c, "unit"), 1)), a_u64(c, "lo"), a_u64(c, "hi", max(u64)), context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "hits", len(hits))
	for h in hits {
		o_obj(o, "")
		o_id(o, "scope", h.scope)
		o_id(o, "object", h.object)
		o_bytes(o, "ref", h.ref)
		o_u64(o, "hlc", u64(h.hlc))
		o_u64(o, "lo", h.lo)
		o_u64(o, "hi", h.hi)
		o_bool(o, "known", h.known)
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_share_object :: proc(c: ^Call, o: ^Out) -> Status {
	recipient, cerr := osync.card_verify(a_bytes(c, "card"))
	if cerr != .None {
		return .Invalid
	}
	s, err := eng.share_object(c.api.e, a_object(c, "object"), recipient)
	if err != .None {
		return status_of(err)
	}
	buf := make([dynamic]u8, context.temp_allocator)
	if eng.share_encode(&s, &buf) != .None {
		return .No_Memory
	}
	o_bytes(o, "share", buf[:])
	return .Ok
}

op_share_accept :: proc(c: ^Call, o: ^Out) -> Status {
	s: eng.Share
	if eng.share_decode(a_bytes(c, "share"), &s) != .None {
		return .Invalid
	}
	if err := eng.accept_share(c.api.e, s); err != .None {
		return status_of(err)
	}
	o_object(o, "object", Object{s.space, s.object})
	return .Ok
}

op_capability_issue :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	kind := eng.Kind.Conversation
	if en, found, err := eng.catalog_get(c.api.e, ob, context.temp_allocator); err == .None && found && en.kind != eng.Kind(0) {
		kind = en.kind
	}
	cap := eng.Capability {
		space   = ob.space,
		grantee = a_id(c, "grantee"),
		object  = ob.id,
		kind    = kind,
		access  = transmute(eng.Access_Set)u8(a_u64(c, "access", 1)),
		expires = a_i64(c, "expires"),
	}
	token, err := eng.capability_issue(c.api.e, cap, context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_bytes(o, "token", token)
	return .Ok
}

op_workspace_create :: proc(c: ^Call, o: ^Out) -> Status {
	def := eng.Workspace_Def {
		name     = a_str(c, "name"),
		agent    = a_id(c, "agent"),
		provider = a_str(c, "provider"),
		model    = a_str(c, "model"),
		setup    = a_str(c, "setup"),
	}
	ob, err := eng.workspace_create(c.api.e, a_id(c, "space"), def)
	if err != .None {
		return status_of(err)
	}
	if merr := eng.catalog_set(c.api.e, eng.Cmd_Catalog_Set{object = ob, set = {.Workspace}, workspace = ob.id}); merr != .None && merr != .Pending {
		return status_of(merr)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_workspace_get :: proc(c: ^Call, o: ^Out) -> Status {
	def, err := eng.workspace_get(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_str(o, "name", def.name)
	o_id(o, "agent", def.agent)
	o_str(o, "provider", def.provider)
	o_str(o, "model", def.model)
	o_bytes(o, "runner_policy", def.runner_policy)
	o_str(o, "setup", def.setup)
	o_bytes(o, "access", def.access)
	o_arr(o, "members", len(def.members))
	for m in def.members {
		o_obj(o, "")
		o_id(o, "object", m.object)
		o_enum(o, "kind", u64(m.kind), KIND_NAMES[:])
		o_enum(o, "role", u64(m.role), ROLE_MEMBER_NAMES[:])
		o_str(o, "mount", m.mount)
		o_str(o, "path", m.path)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "linked", len(def.linked))
	for l in def.linked {
		o_str(o, "", l)
	}
	o_end(o)
	o_enum(o, "takeover", u64(def.takeover), TAKEOVER_NAMES[:])
	return .Ok
}

@(private)
_member :: proc(c: ^Call) -> (m: eng.Workspace_Member, ok: bool) {
	k := a_u64(c, "kind", 4)
	r := a_u64(c, "role", 1)
	if k < 1 || k > 4 || r < 1 || r > 3 {
		return m, false
	}
	return eng.Workspace_Member{object = a_id(c, "member"), kind = eng.Kind(k), role = eng.Member_Role(r), mount = a_str(c, "mount"), path = a_str(c, "path")}, true
}

op_workspace_add_member :: proc(c: ^Call, o: ^Out) -> Status {
	m, ok := _member(c)
	if !ok {
		return .Invalid
	}
	return status_of(eng.workspace_add_member(c.api.e, a_object(c, "object"), m))
}

op_workspace_remove_member :: proc(c: ^Call, o: ^Out) -> Status {
	m, ok := _member(c)
	if !ok {
		return .Invalid
	}
	return status_of(eng.workspace_remove_member(c.api.e, a_object(c, "object"), m))
}

@(private)
_agent_def :: proc(c: ^Call) -> eng.Agent_Def {
	return eng.Agent_Def {
		name         = a_str(c, "name"),
		instructions = a_str(c, "instructions"),
		driver       = a_str(c, "driver"),
		provider     = a_str(c, "provider"),
		model        = a_str(c, "model"),
		workspace    = a_id(c, "workspace"),
		options      = a_bytes(c, "options"),
		budget       = a_bytes(c, "budget"),
	}
}

op_agent_create :: proc(c: ^Call, o: ^Out) -> Status {
	ob, err := eng.agent_create(c.api.e, a_id(c, "space"), _agent_def(c))
	if err != .None {
		return status_of(err)
	}
	if merr := eng.catalog_set(c.api.e, eng.Cmd_Catalog_Set{object = ob, set = {.Agent}, agent = ob.id}); merr != .None && merr != .Pending {
		return status_of(merr)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_agent_get :: proc(c: ^Call, o: ^Out) -> Status {
	def, err := eng.agent_get(c.api.e, a_object(c, "object"), context.temp_allocator, ready(c))
	if err != .None {
		return pend(c, err)
	}
	o_str(o, "name", def.name)
	o_str(o, "instructions", def.instructions)
	o_str(o, "driver", def.driver)
	o_str(o, "provider", def.provider)
	o_str(o, "model", def.model)
	o_bytes(o, "options", def.options)
	o_bytes(o, "budget", def.budget)
	o_id(o, "workspace", def.workspace)
	o_bytes(o, "runner_policy", def.runner_policy)
	o_arr(o, "tools", len(def.tools))
	for t in def.tools {
		o_bytes(o, "", t)
	}
	o_end(o)
	o_arr(o, "memory", len(def.memory))
	for m in def.memory {
		o_id(o, "", m)
	}
	o_end(o)
	o_arr(o, "triggers", len(def.triggers))
	for t in def.triggers {
		o_bytes(o, "", t)
	}
	o_end(o)
	o_enum(o, "takeover", u64(def.takeover), TAKEOVER_NAMES[:])
	return .Ok
}

op_agent_set :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.agent_set(c.api.e, a_object(c, "object"), _agent_def(c)))
}

op_agent_add :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.agent_add(c.api.e, a_object(c, "object"), eng.Agent_Tag(a_u64(c, "tag")), a_bytes(c, "element")))
}

op_agent_remove :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.agent_remove(c.api.e, a_object(c, "object"), eng.Agent_Tag(a_u64(c, "tag")), a_bytes(c, "element")))
}

@(private)
_attach :: proc(c: ^Call, space: prim.Id) {
	if c.api.r != nil {
		rt.attach(c.api.r, space)
	}
}

op_storage_availability :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	holders, unavailable := eng.availability(c.api.e, ob, context.temp_allocator)
	class, _ := eng.storage_class(c.api.e, ob)
	o_bool(o, "unavailable", unavailable)
	o_arr(o, "holders", len(holders))
	for h in holders {
		o_id(o, "", h)
	}
	o_end(o)
	o_u64(o, "class", u64(class))
	return .Ok
}

op_storage_stats :: proc(c: ^Call, o: ^Out) -> Status {
	st := eng.storage_stats(c.api.e)
	o_u64(o, "promotions", u64(st.promotions))
	o_u64(o, "promoted", u64(max(st.promoted, 0)))
	o_u64(o, "served", u64(max(st.served_bytes, 0)))
	o_u64(o, "unavailable", u64(st.unavailable))
	return .Ok
}

op_object_promote :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.object_promote(c.api.e, a_object(c, "object"), i64(min(a_u64(c, "from"), u64(max(i64))))))
}

op_takeover_get :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	level := eng.Takeover_Level(min(a_u64(c, "level"), u64(max(eng.Takeover_Level))))
	p, err := eng.takeover_get(c.api.e, ob, level, ready(c))
	if err != .None {
		return pend(c, err)
	}
	eff := p
	if level == .Conversation && c.api.r != nil {
		a, _ := rt.agent_resolve(c.api.r, ob, "", "", context.temp_allocator)
		eff = a.takeover
	}
	o_enum(o, "policy", u64(p), TAKEOVER_NAMES[:])
	o_enum(o, "effective", u64(eff), TAKEOVER_NAMES[:])
	return .Ok
}

op_takeover_set :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	level := eng.Takeover_Level(min(a_u64(c, "level"), u64(max(eng.Takeover_Level))))
	err := eng.takeover_set(c.api.e, ob, level, eng.Takeover(min(a_u64(c, "policy"), u64(max(eng.Takeover)))))
	if err != .None {
		return status_of(err)
	}
	if c.api.r != nil && level == .Conversation {
		rt.wake(c.api.r, ob)
	}
	return .Ok
}

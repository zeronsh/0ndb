package api

import "core:os"
import "core:strings"
import "../../convo"
import eng "../../engine"
import "../../fs"
import "../../model"
import "../../prim"
import rt "../../runtime"

API_NAMES := [3]string{"anthropic", "openai_responses", "openai_chat"}
PROTOCOL_NAMES := [5]string{"claude_stream_json", "codex_app_server", "pi_rpc", "muse", "acp"}
DRIVER_NAMES := [2]string{"harness", "native"}
RECEIPT_NAMES := [4]string{"", "recorded", "duplicate", "superseded"}
HOLD_REASON_NAMES := [4]string{"", "branch_changed", "branch_deleted", "undo"}

RUNTIME_OPS := []Op {
	{119, "runtime.attach", {SPACE}, "", op_runtime_attach},
	{120, "runtime.detach", {SPACE}, "", op_runtime_detach},
	{121, "runtime.stats", {}, "RuntimeStats", op_runtime_stats},
	{122, "models", {{"live", .Bool, nil}, {"refresh", .Bool, nil}}, "Models", op_models},
	{123, "agent.resolve", {OBJ, {"provider", .Str, nil}, {"model", .Str, nil}}, "AgentInfo", op_agent_resolve},
	{124, "record", {OBJ, {"source", .Str, nil}, {"external_id", .Str, nil}, {"sequence", .U64, nil}, {"role", .Enum, ROLE_NAMES[:]}, {"parent", .Rid, nil}, {"blocks", .Blocks, nil}, {"status", .Enum, SEAL_NAMES[:]}, {"input", .U64, nil}, {"output", .U64, nil}, {"cache_read", .U64, nil}, {"cache_write", .U64, nil}, {"provider", .Str, nil}, {"model", .Str, nil}, {"native", .Str, nil}}, "receipt:enum msg:rid", op_record},
	{125, "task.status", {OBJ}, "TaskStatus", op_task_status},
	{126, "task.children", {OBJ, {"limit", .U64, nil}}, "children:[CatalogRow]", op_task_children},
	{127, "task.changes", {OBJ, {"caller", .Object, nil}, {"diff", .Bool, nil}, {"max_chars", .U64, nil}}, "changes:[Change] diff:str", op_task_changes},
	{128, "schedule.create", {{"owner", .Object, nil}, {"id", .Str, nil}, {"prompt", .Str, nil}, {"cron", .Str, nil}, {"at", .I64, nil}, {"tz", .Str, nil}, {"conversation", .Object, nil}, {"fresh", .Bool, nil}}, "", op_schedule_create},
	{129, "schedule.list", {SPACE}, "schedules:[Schedule]", op_schedule_list},
	{130, "schedule.remove", {{"owner", .Object, nil}, {"id", .Str, nil}}, "found:bool", op_schedule_remove},
	{131, "land", {{"tree", .Object, nil}, {"from", .Str, nil}, {"into", .Str, nil}, {"dry", .Bool, nil}}, "landed:bool files:uvarint conflicts:strs", op_land},
	{134, "channel.deliver", {SPACE, {"channel", .Str, nil}, {"key", .Str, nil}, TEXT, {"sender", .Str, nil}, {"title", .Str, nil}, {"agent", .Id, nil}, {"workspace", .Id, nil}}, "object:object", op_channel_deliver},
	{135, "event.deliver", {SPACE, {"agent", .Id, nil}, {"name", .Str, nil}, {"payload", .Str, nil}}, "", op_event_deliver},
	{136, "trigger.watch", {OBJ}, "", op_trigger_watch},
	{137, "agent.actor", {{"agent", .Id, nil}}, "actor:id", op_agent_actor},
	{138, "wake", {OBJ}, "", op_wake},
	{139, "placement", {OBJ}, "Placement", op_placement},
	{162, "runners", {SPACE, OBJ}, "Runners", op_runners},
	{163, "subscribe.runners", {SPACE, OBJ}, "Runners", nil},
	{171, "line.hold", {{"tree", .Object, nil}, {"line", .Str, nil}, {"reason", .Enum, HOLD_REASON_NAMES[:]}, {"wait", .Bool, nil}}, "held:uvarint sealed:bool", op_line_hold},
	{172, "line.resume", {{"tree", .Object, nil}, {"line", .Str, nil}}, "resumed:uvarint", op_line_resume},
	{173, "line.switch", {{"tree", .Object, nil}, {"line", .Str, nil}, {"root", .Str, nil}}, "line:str held:uvarint", op_line_switch},
	{174, "undo", {OBJ, MSG}, "undo:id done:bool", op_undo},
	{175, "redo", {OBJ, {"undo", .Id, nil}}, "undo:id done:bool", op_redo},
	{176, "undo.resume", {OBJ}, "resumed:uvarint", op_undo_resume},
	{177, "regenerate", {OBJ, MSG}, "undo:id done:bool", op_regenerate},
	{143, "subscribe.fork_diff", {OBJ, {"caller", .Object, nil}, {"diff", .Bool, nil}, {"max_chars", .U64, nil}}, "changes:[Change] diff:str", nil},
}

op_line_hold :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	if c.stage == 1 {
		o_int(o, "held", int(c.scratch[0]))
		o_bool(o, "sealed", c.scratch[1] == 1)
		return .Ok
	}
	line := a_str(c, "line")
	if len(line) == 0 {
		return .Invalid
	}
	reason := convo.Hold_Reason(min(a_u64(c, "reason"), u64(max(convo.Hold_Reason))))
	if reason == .None {
		reason = .Branch_Changed
	}
	if !a_bool(c, "wait") {
		o_int(o, "held", rt.runtime_hold_line(r, a_object(c, "tree").id, line, reason))
		return .Ok
	}
	c.scratch[2] = 1
	c.in_exec = true
	c.scratch[0] = u64(rt.runtime_hold_line(r, a_object(c, "tree").id, line, reason, _line_hold_done, c))
	c.scratch[2] = 0
	if c.stage == 1 {
		c.in_exec = false
		o_int(o, "held", int(c.scratch[0]))
		o_bool(o, "sealed", c.scratch[1] == 1)
		return .Ok
	}
	return .Pending
}

@(private)
_line_hold_done :: proc(data: rawptr, ok: bool) {
	c := (^Call)(data)
	c.scratch[1] = 1 if ok else 0
	c.stage = 1
	if c.scratch[2] == 1 {
		return
	}
	c.in_exec = false
	if c.orphan {
		_call_free(c)
		return
	}
	_rerun(c)
}

op_line_switch :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	ob := a_object(c, "tree")
	to := a_str(c, "line")
	if len(to) == 0 {
		return .Invalid
	}
	m := mount_find(c.api, ob, strings.trim_right(a_str(c, "root"), "/"))
	if m == nil {
		if c.stage >= 2 {
			c.in_exec = false
		}
		return .Not_Found
	}
	context = eng.context_for(c.api.e)
	if c.stage == 0 {
		from := fs.mount_line(m.mount)
		c.scratch[3] = 0
		if from == to {
			o_str(o, "from", from)
			o_str(o, "line", to)
			o_int(o, "held", 0)
			return .Ok
		}
		c.scratch[2] = 1
		c.in_exec = true
		c.scratch[0] = u64(rt.runtime_hold_line(r, ob.id, from, .Branch_Changed, _line_hold_done, c))
		c.scratch[2] = 0
		if c.stage != 1 {
			return .Pending
		}
		c.in_exec = false
	}
	if c.stage == 1 {
		if c.scratch[1] != 1 {
			return .Closed
		}
		c.scratch[3] = 0x100 if fs.mount_hold_writes(m.mount) else 0
		c.stage = 3
		c.in_exec = true
		c.scratch[2] = 1
		serr := fs.mount_line_switch(m.mount, to, _line_switch_done, c)
		c.scratch[2] = 0
		if err := serr; err != .None {
			c.in_exec = false
			if c.scratch[3] & 0x100 != 0 {
				fs.mount_release_writes(m.mount)
			}
			return _switch_status(err)
		}
		if c.stage != 2 {
			return .Pending
		}
		c.in_exec = false
	}
	if c.scratch[3] & 0x100 != 0 {
		fs.mount_release_writes(m.mount)
		c.scratch[3] &~= 0x100
	}
	if err := fs.Error(c.scratch[3] & 0xff); err != .None {
		return _switch_status(err)
	}
	rt.runtime_resume_line(r, ob.id, to)
	eng.touched(c.api.e, m.object)
	o_str(o, "line", to)
	o_int(o, "held", int(c.scratch[0]))
	return .Ok
}

@(private)
_line_switch_done :: proc(m: ^fs.Mount, err: fs.Error, data: rawptr) {
	c := (^Call)(data)
	c.scratch[3] = (c.scratch[3] & 0x100) | u64(err)
	was := c.stage
	c.stage = 2
	if was != 3 || !c.in_exec || c.scratch[2] == 1 {
		return
	}
	c.in_exec = false
	if c.orphan {
		_call_free(c)
		return
	}
	_rerun(c)
}

@(private)
_switch_status :: proc(err: fs.Error) -> Status {
	#partial switch err {
	case .Not_Found:
		return .Not_Found
	case .Unsupported:
		return .Unsupported
	case .Busy:
		return .Busy
	case .Conflicts:
		return .Conflict
	}
	return .Io
}

op_line_resume :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	line := a_str(c, "line")
	if len(line) == 0 {
		return .Invalid
	}
	o_int(o, "resumed", rt.runtime_resume_line(r, a_object(c, "tree").id, line))
	return .Ok
}

@(private)
_rt :: proc(c: ^Call) -> ^rt.Runtime {
	return c.api.r
}

@(private)
_rterr :: proc(err: rt.Error) -> Status {
	switch err {
	case .None:
		return .Ok
	case .Invalid:
		return .Invalid
	case .Not_Found:
		return .Not_Found
	case .Busy:
		return .Busy
	case .Pending:
		return .Pending
	case .Unsupported:
		return .Unsupported
	case .Closed:
		return .Closed
	case .Limit:
		return .Limit
	case .Io, .Engine:
		return .Io
	case .Spawn:
		return .Spawn
	case .Permission:
		return .Permission
	case .Conflict:
		return .Conflict
	case .Cancelled:
		return .Cancelled
	case .Budget:
		return .Budget
	case .Not_Assigned:
		return .Not_Assigned
	}
	return .Io
}

op_runtime_attach :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	return _rterr(rt.attach(r, a_id(c, "space")))
}

op_runtime_detach :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	rt.detach(r, a_id(c, "space"))
	return .Ok
}

op_runtime_stats :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	s := rt.stats(r)
	o_bool(o, "runner", r.cfg.runner)
	o_int(o, "active_runs", rt.active_runs(r))
	o_int(o, "warm_processes", rt.warm_processes(r))
	o_u64(o, "runs_started", s.runs_started)
	o_u64(o, "runs_finished", s.runs_finished)
	o_u64(o, "runs_held", s.runs_held)
	o_u64(o, "runs_resumed", s.runs_resumed)
	o_u64(o, "evaluations", s.evaluations)
	o_u64(o, "spawns", s.spawns)
	o_u64(o, "warm_hits", s.warm_hits)
	o_u64(o, "raw_lines", s.raw_lines)
	o_u64(o, "tool_calls", s.tool_calls)
	o_u64(o, "schedules", s.schedules)
	o_int(o, "timers", s.timers)
	return .Ok
}

@(private)
_on_path :: proc(name: string) -> bool {
	when ODIN_OS == .Windows {
		_, _, err := prim.resolve_executable(name, nil, context.temp_allocator)
		return err == .None
	}
	if strings.contains_rune(name, '/') {
		return os.exists(name)
	}
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path, ":") {
		if len(dir) == 0 {
			continue
		}
		if os.exists(strings.concatenate({dir, "/", name}, context.temp_allocator)) {
			return true
		}
	}
	return false
}

op_models :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	a := c.api
	live := a_bool(c, "live") if has(c, "live") else true
	if live && !c.final && (!_models_fresh(a) || (a_bool(c, "refresh") && c.stage == 0)) {
		c.stage = 1
		if len(a.models.probes) == 0 {
			a.models.at_ms = 0
			_models_start(a, r)
		}
		if len(a.models.probes) > 0 {
			append(&a.models.waiters, c.id)
			c.waiting = true
			return .Pending
		}
	}
	list := r.registry.list[:]
	o_arr(o, "providers", len(list))
	for &d in list {
		o_obj(o, "")
		o_str(o, "id", d.id)
		o_str(o, "name", d.name)
		o_str(o, "command", d.argv[0] if len(d.argv) > 0 else "")
		o_enum(o, "protocol", u64(d.protocol), PROTOCOL_NAMES[:])
		o_bool(o, "available", len(d.argv) > 0 && _on_path(d.argv[0]))
		o_bool(o, "signed_in", rt.provider_signed_in(r, d.id))
		o_str(o, "login", d.login)
		lp: ^Live_Provider
		for &x in a.models.providers {
			if x.id == d.id {
				lp = &x
			}
		}
		o_bool(o, "listed", lp != nil && lp.ok)
		o_str(o, "error", lp.error if lp != nil else "")
		n := len(lp.models) if lp != nil else 0
		o_arr(o, "models", n)
		for i in 0 ..< n {
			mm := lp.models[i]
			o_obj(o, "")
			o_str(o, "id", mm.id)
			o_str(o, "name", mm.name)
			o_bool(o, "default", mm.is_default)
			o_end(o)
		}
		o_end(o)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "models", len(model.MODELS))
	for s in model.MODELS {
		o_obj(o, "")
		o_str(o, "id", s.id)
		o_enum(o, "api", u64(s.api), API_NAMES[:])
		o_u64(o, "context_window", s.context_window)
		o_end(o)
	}
	o_end(o)
	o_str(o, "default_provider", r.cfg.default_provider)
	o_str(o, "default_model", r.cfg.default_model)
	o_i64(o, "listed_at", a.models.at_ms)
	return .Ok
}

op_agent_resolve :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	a, ok := rt.agent_resolve(r, a_object(c, "object"), a_str(c, "provider"), a_str(c, "model"), context.temp_allocator)
	if !ok {
		return .Not_Found
	}
	o_object(o, "agent", a.object)
	o_str(o, "name", a.name)
	o_enum(o, "driver", u64(a.kind), DRIVER_NAMES[:])
	o_str(o, "provider", a.provider)
	o_str(o, "model", a.model)
	o_str(o, "effort", a.effort)
	o_bool(o, "ask_permissions", a.ask_permissions)
	o_bool(o, "observe", a.observe)
	o_id(o, "workspace", a.workspace)
	o_str(o, "instructions", a.instructions)
	o_u64(o, "budget_tokens", a.budget.tokens)
	o_f64(o, "budget_usd", a.budget.usd)
	o_int(o, "budget_turns", a.budget.turns)
	o_i64(o, "budget_seconds", a.budget.seconds)
	return .Ok
}

op_record :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	src := a_blocks(c, "blocks")
	blocks := make([]rt.Record_Block, len(src), context.temp_allocator)
	for b, i in src {
		blocks[i] = rt.Record_Block{kind = b.kind, text = b.text, id = b.id, name = b.name, failed = b.failed}
	}
	role := convo.Role(a_u64(c, "role"))
	if role < .User || role > .Tool {
		role = .Assistant
	}
	up := rt.Record_Update {
		role     = role,
		parent   = a_rid(c, "parent"),
		blocks   = blocks,
		status   = convo.Seal_Status(min(a_u64(c, "status"), 4)),
		usage    = convo.Usage{input = a_u64(c, "input"), output = a_u64(c, "output"), cache_read = a_u64(c, "cache_read"), cache_write = a_u64(c, "cache_write")},
		provider = a_str(c, "provider"),
		model    = a_str(c, "model"),
		native   = a_str(c, "native"),
	}
	receipt, msg, err := rt.record(r, a_object(c, "object"), a_str(c, "source"), a_str(c, "external_id"), a_u64(c, "sequence"), up)
	if err != .None {
		return _rterr(err)
	}
	o_enum(o, "receipt", u64(receipt), RECEIPT_NAMES[:])
	o_rid(o, "msg", msg)
	return .Ok
}

op_task_status :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	ob := a_object(c, "object")
	st, summary, ok := rt.task_status(r, ob)
	if !ok {
		eng.convo_status(c.api.e, ob, ready(c))
		if c.waiting {
			return .Pending
		}
	}
	t, _ := rt.task_get(r, ob)
	names := rt.TASK_STATUS_NAMES
	o_str(o, "status", names[st])
	o_str(o, "summary", summary)
	o_bool(o, "cancelled", t.cancelled)
	o_str(o, "reason", t.reason)
	o_u64(o, "budget_tokens", t.budget.tokens)
	o_f64(o, "budget_usd", t.budget.usd)
	o_enum(o, "isolate", u64(t.isolate), ISOLATE_NAMES[:])
	o_arr(o, "conflicts", len(t.conflicts))
	for x in t.conflicts {
		o_str(o, "", x)
	}
	o_end(o)
	return .Ok
}

op_task_children :: proc(c: ^Call, o: ^Out) -> Status {
	parent := a_object(c, "object")
	limit := a_int(c, "limit", 1000)
	kids := make([dynamic]eng.Catalog_Row, context.temp_allocator)
	cur := _cursor(nil)
	for {
		rows, more, err := eng.catalog_list(c.api.e, parent.space, false, &cur, 512, context.temp_allocator, ready(c))
		if err != .None {
			return pend(c, err)
		}
		for row in rows {
			if row.parent.object == parent.id {
				append(&kids, row)
			}
		}
		if !more || len(kids) >= limit {
			break
		}
	}
	o_arr(o, "children", min(len(kids), limit))
	for &k, i in kids {
		if i >= limit {
			break
		}
		emit_catalog_row(o, parent.space, &k)
	}
	o_end(o)
	return .Ok
}

op_task_changes :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	ob := a_object(c, "object")
	caller := a_object(c, "caller")
	if prim.id_is_zero(caller.id) {
		if s, err := eng.convo_settings(c.api.e, ob, context.temp_allocator); err == .None {
			caller = Object{ob.space, s.parent.object}
		}
	}
	list, diff := rt.task_changes(r, caller, ob, a_bool(c, "diff"), a_int(c, "max_chars", 200_000))
	emit_changes(o, list, diff)
	return .Ok
}

emit_changes :: proc(o: ^Out, list: []rt.File_Change, diff: string) {
	o_arr(o, "changes", len(list))
	for ch in list {
		o_obj(o, "")
		o_str(o, "mount", ch.mount)
		o_str(o, "path", ch.path)
		o_str(o, "change", ch.change)
		o_end(o)
	}
	o_end(o)
	o_str(o, "diff", diff)
}

op_schedule_create :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	id := a_str(c, "id")
	if len(id) == 0 {
		h := prim.id_hex(rt.new_id(r))
		id = strings.clone(string(h[:]), context.temp_allocator)
	}
	err := rt.schedule_create(r, a_object(c, "owner"), id, a_str(c, "prompt"), a_str(c, "cron"), a_i64(c, "at"), a_str(c, "tz"), a_object(c, "conversation"), a_bool(c, "fresh"))
	if err != .None {
		return _rterr(err)
	}
	o_str(o, "id", id)
	return .Ok
}

op_schedule_list :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	space := a_id(c, "space")
	rows := rt.map_rows(r, rt.schedules_object(space), nil)
	list := make([dynamic]rt.Schedule, context.temp_allocator)
	for row in rows {
		if len(row.key) <= 16 {
			continue
		}
		owner: prim.Id
		copy(owner[:], row.key[:16])
		if s, found := rt.schedule_get(r, Object{space, owner}, string(row.key[16:])); found {
			append(&list, s)
		}
	}
	o_arr(o, "schedules", len(list))
	for s in list {
		o_obj(o, "")
		o_str(o, "id", s.id)
		o_object(o, "owner", s.owner)
		o_str(o, "prompt", s.prompt)
		o_str(o, "cron", s.cron)
		o_i64(o, "at", s.at)
		o_str(o, "tz", s.tz)
		o_id(o, "conversation", s.conversation)
		o_bool(o, "fresh", s.fresh)
		o_i64(o, "next", s.next)
		o_i64(o, "last", s.last)
		o_id(o, "creator", s.creator)
		o_id(o, "agent", s.agent)
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_schedule_remove :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	o_bool(o, "found", rt.schedule_remove(r, a_object(c, "owner"), a_str(c, "id")))
	return .Ok
}

op_land :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	into := a_str(c, "into")
	if len(into) == 0 {
		into = "main"
	}
	landed, files, conflicts := rt.merge_line(r, a_object(c, "tree"), a_str(c, "from"), into, a_bool(c, "dry"))
	o_bool(o, "landed", landed)
	o_int(o, "files", files)
	o_arr(o, "conflicts", len(conflicts))
	for x in conflicts {
		o_str(o, "", x)
	}
	o_end(o)
	return .Ok
}

op_channel_deliver :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	m := rt.Channel_Message {
		channel   = a_str(c, "channel"),
		key       = a_str(c, "key"),
		text      = a_str(c, "text"),
		sender    = a_str(c, "sender"),
		title     = a_str(c, "title"),
		agent     = a_id(c, "agent"),
		workspace = a_id(c, "workspace"),
	}
	ob, err := rt.channel_deliver(r, a_id(c, "space"), m)
	if err != .None {
		return _rterr(err)
	}
	o_object(o, "object", ob)
	return .Ok
}

op_event_deliver :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	return _rterr(rt.event_deliver(r, a_id(c, "space"), a_id(c, "agent"), a_str(c, "name"), a_str(c, "payload")))
}

op_trigger_watch :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	return _rterr(rt.trigger_watch(r, a_object(c, "object")))
}

op_agent_actor :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	o_id(o, "actor", rt.agent_actor(r, a_id(c, "agent")))
	return .Ok
}

PLACEMENT_NAMES := [6]string{"none", "assigned", "running", "waiting_runner", "idle", "placing"}

emit_placement :: proc(o: ^Out, info: ^rt.Placement_Info) {
	o_enum(o, "state", u64(info.state), PLACEMENT_NAMES[:])
	o_rid(o, "msg", info.msg)
	o_id(o, "runner", info.runner)
	o_str(o, "provider", info.provider)
	o_i64(o, "since_ms", info.since_ms)
	o_id(o, "last_runner", info.last_runner)
}

emit_runners :: proc(o: ^Out, list: []rt.Runner_Entry) {
	o_arr(o, "runners", len(list))
	for &x in list {
		o_obj(o, "")
		o_id(o, "device", x.device)
		o_str(o, "name", x.name)
		o_enum(o, "kind", u64(x.kind), RUNNER_KIND_NAMES[:])
		o_enum(o, "state", u64(x.state), RUNNER_STATE_NAMES[:])
		_emit_lines(o, "providers", x.providers)
		_emit_lines(o, "signed_in", x.signed_in)
		o_bool(o, "current", x.current)
		o_bool(o, "last", x.last)
		o_end(o)
	}
	o_end(o)
}

@(private)
_emit_lines :: proc(o: ^Out, name: string, list: string) {
	parts := strings.split(list, "\n", context.temp_allocator) if len(list) > 0 else nil
	o_arr(o, name, len(parts))
	for p in parts {
		o_str(o, "", p)
	}
	o_end(o)
}

runners_space :: proc(c: ^Call) -> (space: prim.Id, ob: Object) {
	ob = a_object(c, "object")
	space = a_id(c, "space")
	if prim.id_is_zero(space) {
		space = ob.space
	}
	if ob.space != space {
		ob = {}
	}
	return
}

op_runners :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	space, ob := runners_space(c)
	if prim.id_is_zero(space) {
		return .Invalid
	}
	emit_runners(o, rt.runner_directory(r, space, ob, context.temp_allocator))
	return .Ok
}

op_placement :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	ob := a_object(c, "object")
	info, err := rt.placement_status(r, ob)
	if err == .Pending {
		eng.convo_status(c.api.e, ob, ready(c))
		if c.waiting {
			return .Pending
		}
		return .Missing
	}
	if err != .None {
		return _rterr(err)
	}
	emit_placement(o, &info)
	return .Ok
}

op_wake :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	rt.wake(r, a_object(c, "object"))
	return .Ok
}

op_undo :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	ob := a_object(c, "object")
	id, err := rt.runtime_undo(r, ob, a_rid(c, "msg"))
	if err != .None && err != .Pending {
		return status_of(err)
	}
	o_id(o, "undo", id)
	o_bool(o, "done", err == .None)
	return .Ok
}

op_redo :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	ob := a_object(c, "object")
	id, err := rt.runtime_redo(r, ob, a_id(c, "undo"))
	if err != .None && err != .Pending {
		return status_of(err)
	}
	o_id(o, "undo", id)
	o_bool(o, "done", err == .None)
	return .Ok
}

op_regenerate :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	id, err := rt.runtime_regenerate(r, a_object(c, "object"), a_rid(c, "msg"))
	if err != .None && err != .Pending {
		return status_of(err)
	}
	o_id(o, "undo", id)
	o_bool(o, "done", err == .None)
	return .Ok
}

op_undo_resume :: proc(c: ^Call, o: ^Out) -> Status {
	r := _rt(c)
	if r == nil {
		return .Unsupported
	}
	o_int(o, "resumed", rt.runtime_undo_resume(r, a_object(c, "object")))
	return .Ok
}

package rt

import "core:encoding/json"
import "core:strings"
import "../convo"
import "../crdt"
import eng "../engine"
import "../fs"
import "../fstree"
import omap "../map"
import "../mcp"
import "../obj"
import "../prim"
import "../search"
import "../textdiff"

@(private)
KEY_TASK :: "task"

HOLD_LAND :: "land"

Task_Info :: struct {
	budget:    Budget,
	cancelled: bool,
	reason:    string,
	isolate:   Isolate,
	conflicts: []string,
}

Await_Wait :: struct {
	r:         ^Runtime,
	caller:    Object,
	item:      Rid,
	tasks:     []prim.Id,
	all:       bool,
	statuses:  bit_set[Task_Status;u8],
	rep:       Reply,
	rep_id:    string,
	token:     u64,
	timer:     prim.Timer,
}

Task_Status :: enum u8 {
	Queued,
	Running,
	Waiting,
	Completed,
	Failed,
	Cancelled,
	Held,
}

TASK_STATUS_NAMES := [Task_Status]string {
	.Queued    = "queued",
	.Running   = "running",
	.Waiting   = "waiting",
	.Completed = "completed",
	.Failed    = "failed",
	.Cancelled = "cancelled",
	.Held      = "held",
}

task_get :: proc(r: ^Runtime, o: Object) -> (t: Task_Info, found: bool) {
	context = eng.context_for(r.e)
	en, ok := map_read(r, meta_object(o), transmute([]u8)string(KEY_TASK))
	if !ok {
		return {}, false
	}
	t.budget = budget_parse(entry_bytes(&en, 1))
	t.cancelled = entry_bool(&en, 2)
	t.reason = entry_str(&en, 3)
	t.isolate = Isolate(min(entry_u64(&en, 4), u64(max(Isolate))))
	if c := entry_str(&en, 5); len(c) > 0 {
		t.conflicts = strings.split(c, "\n", context.temp_allocator)
	}
	return t, true
}

task_cancelled :: proc(r: ^Runtime, o: Object) -> bool {
	t, ok := task_get(r, o)
	return ok && t.cancelled
}

task_status :: proc(r: ^Runtime, o: Object) -> (s: Task_Status, summary: string, ok: bool) {
	context = eng.context_for(r.e)
	if task_cancelled(r, o) {
		return .Cancelled, _last_reply_text(r, o, 600), true
	}
	st, err := eng.convo_status(r.e, o)
	if err != .None {
		return .Queued, "", false
	}
	switch st.status {
	case .Running, .Awaiting_Permission:
		return .Running, "", true
	case .Queued:
		return .Queued, "", true
	case .Waiting:
		return .Waiting, "", true
	case .Failed:
		return .Failed, _last_reply_text(r, o, 600), true
	case .Reviving:
		return .Running, "", true
	case .Interrupted:
		return .Failed, _last_reply_text(r, o, 600), true
	case .Held:
		return .Held, hold_reason(r, o), true
	case .Idle:
	}
	if obj.rid_none(st.head) {
		return .Queued, "", true
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return .Queued, "", false
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return .Queued, "", false
	}
	m, merr := convo.message(v, &t, convo.Position{msg = st.head}, context.temp_allocator)
	if merr != .None {
		return .Queued, "", false
	}
	if m.role == .User || m.role == .System {
		return .Queued, "", true
	}
	if m.status == .Failed {
		return .Failed, _blocks_text(m.blocks, 600), true
	}
	if m.status == .Cancelled {
		return .Cancelled, _blocks_text(m.blocks, 600), true
	}
	return .Completed, _blocks_text(m.blocks, 600), true
}

@(private)
_blocks_text :: proc(blocks: []convo.Block_View, limit: int) -> string {
	b := make(Buf, context.temp_allocator)
	for blk in blocks {
		if blk.kind != .Text {
			continue
		}
		if len(b) > 0 {
			append(&b, '\n')
		}
		append(&b, ..blk.text)
	}
	s, cut := utf8_clip(string(b[:]), limit)
	if cut {
		return concat(s, "…")
	}
	return s
}

@(private)
_last_reply_text :: proc(r: ^Runtime, o: Object, limit: int) -> string {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return ""
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return ""
	}
	head, herr := convo.tail_head(v, &t)
	if herr != .None || obj.rid_none(head) {
		return ""
	}
	m, merr := convo.message(v, &t, convo.Position{msg = head}, context.temp_allocator)
	if merr != .None {
		return ""
	}
	return _blocks_text(m.blocks, limit)
}

orch_call :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, tool: mcp.Catalog_Tool, input: string, rep: Reply) -> u64 {
	v, ok := json_parse(input)
	if !ok {
		reply_done(r, rep, "the input is not valid JSON", "", true)
		return 0
	}
	switch tool {
	case .Spawn:
		_orch_spawn(r, caller, a, v, rep)
	case .Send:
		_orch_send(r, caller, v, rep)
	case .Wait:
		return _orch_wait(r, caller, v, rep)
	case .List:
		_orch_list(r, caller, v, rep)
	case .Cancel:
		_orch_cancel(r, caller, v, rep)
	case .Result:
		_orch_result(r, caller, v, rep)
	case .Merge:
		_orch_merge(r, caller, v, rep)
	case .Memory_Search:
		memory_search(r, caller, a, v, rep)
	case .Memory_Read:
		memory_read(r, caller, a, v, rep)
	case .Memory_Write:
		memory_write(r, caller, a, v, rep)
	case .Schedule:
		schedule_tool(r, caller, a, v, rep)
	case .History_Search:
		_orch_history(r, caller, v, rep)
	case .Redact:
		_orch_redact(r, caller, v, rep)
	}
	return 0
}

@(private)
_obj_arg :: proc(v: json.Value, key: string, space: prim.Id) -> (o: Object, ok: bool) {
	id, iok := prim.id_parse(jstr(v, key))
	if !iok {
		return {}, false
	}
	return Object{space, id}, true
}

@(private)
_orch_spawn :: proc(r: ^Runtime, caller: Object, a: ^Agent_Info, v: json.Value, rep: Reply) {
	settings, _ := eng.convo_settings(r.e, caller, context.temp_allocator)
	goal := jstr(v, "goal")
	if len(goal) == 0 {
		reply_done(r, rep, "goal is required", "", true)
		return
	}
	title := jstr(v, "title")
	if len(title) == 0 {
		title, _ = utf8_clip(strings.trim_space(goal), 80)
		if i := strings.index_byte(title, '\n'); i >= 0 {
			title = title[:i]
		}
	}
	agent_id := settings.agent
	if s := jstr(v, "agent"); len(s) > 0 {
		if id, iok := prim.id_parse(s); iok {
			agent_id = id
		} else if id2, fok := _agent_by_name(r, caller.space, s); fok {
			agent_id = id2
		} else {
			reply_done(r, rep, concat("unknown agent: ", s), "", true)
			return
		}
	}
	ws := settings.workspace
	if s := jstr(v, "workspace"); len(s) > 0 {
		if id, iok := prim.id_parse(s); iok {
			ws = id
		}
	}
	parent := obj.Xref{object = caller.id}
	provider := jstr(v, "provider")
	model := jstr(v, "model")
	from := a
	if run := run_find(r, caller); run != nil {
		parent.rid = run.reply
		from = &run.ai
	}
	if len(provider) == 0 && prim.id_is_zero(agent_id) && !_ws_runs(r, caller.space, ws) && len(r.cfg.default_provider) == 0 {
		if from == nil || len(from.provider) == 0 {
			reply_done(r, rep, "the task has nothing to run on: pass an agent or a provider (the calling conversation has neither)", "", true)
			return
		}
		provider = from.provider
		if len(model) == 0 {
			model = from.model
		}
	}
	child, cerr := eng.convo_create(r.e, caller.space, eng.Convo_Settings{title = title, agent = agent_id, workspace = ws, parent = parent, provider = provider, model = model})
	if cerr != .None {
		reply_done(r, rep, "the task could not be created", "", true)
		return
	}
	iso := Isolate.Unset
	if jhas(v, "isolate") {
		iso = .Yes if jbool(v, "isolate") else .No
	} else if ca, cok := agent_resolve(r, child, "", "", context.temp_allocator); cok {
		iso = ca.isolate
	}
	mounts, _ := eng.convo_mounts(r.e, caller, context.temp_allocator)
	wanted := jarr(v, "mounts")
	for m in mounts {
		share := false
		path := m.path
		if wanted != nil {
			found := false
			for w in wanted {
				if jstr(w, "name") == m.name {
					found = true
					share = jbool(w, "share")
					if jhas(w, "path") {
						path = jstr(w, "path")
					}
				}
			}
			if !found {
				continue
			}
		}
		switch iso {
		case .Yes:
			share = false
		case .No:
			share = true
		case .Unset:
		}
		line := m.line
		if !share {
			line = new_id(r)
			if !_fork_line(r, caller, m, line) {
				continue
			}
		}
		eng.convo_mount(r.e, child, m.name, m.tree, line, path)
	}
	for w in wanted {
		tid, tok := prim.id_parse(jstr(w, "tree"))
		if !tok {
			continue
		}
		name := jstr(w, "name")
		dup := false
		for m in mounts {
			dup ||= m.name == name
		}
		if !dup {
			eng.convo_mount(r.e, child, name, tid, {}, jstr(w, "path"))
		}
	}
	budget := budget_parse(transmute([]u8)json_text(jget(v, "budget")))
	if t, tok := task_get(r, caller); tok {
		budget = budget_min(budget, _remaining(r, caller, t.budget))
	} else if a != nil {
		budget = budget_min(budget, a.budget)
	}
	map_put(r, meta_w(r, child), transmute([]u8)string(KEY_TASK), field_bytes(1, budget_encode(budget)), omap.field_bool(2, false), omap.field_u64(4, u64(iso)))
	text := goal
	if c := jstr(v, "context"); len(c) > 0 {
		text = concat(goal, "\n\n", c)
	}
	msg, serr := eng.convo_send(r.e, child, text)
	if serr != .None && serr != .Pending {
		reply_done(r, rep, "the goal could not be written", "", true)
		return
	}
	if s := jstr(v, "runner"); len(s) > 0 {
		if rid, rok := prim.id_parse(s); rok {
			eng.exec(r.e, eng.Cmd_Assign{object = child, msg = msg, runner = rid})
		}
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "task", hex(child.id))
	jw_kstr(&b, "title", title)
	jw_kstr(&b, "status", "queued")
	append(&b, '}')
	reply_done(r, rep, concat("spawned task ", hex(child.id)), string(b[:]), false)
}

@(private)
_ws_runs :: proc(r: ^Runtime, space, ws: prim.Id) -> bool {
	if prim.id_is_zero(ws) {
		return false
	}
	w, err := eng.workspace_get(r.e, Object{space, ws}, context.temp_allocator)
	return err == .None && (len(w.provider) > 0 || !prim.id_is_zero(w.agent))
}

@(private)
_agent_by_name :: proc(r: ^Runtime, space: prim.Id, name: string) -> (id: prim.Id, ok: bool) {
	cur: eng.Map_Cursor
	defer delete(cur.key)
	for _ in 0 ..< 64 {
		rows, more, err := eng.catalog_list(r.e, space, false, &cur, 256, context.temp_allocator)
		if err != .None {
			return {}, false
		}
		for row in rows {
			if row.kind == .Map && row.title == name {
				if role, rerr := eng.catalog_role(r.e, Object{space, row.object}, context.temp_allocator); rerr == .None && len(role) > 0 {
					continue
				}
				if def, derr := eng.agent_get(r.e, Object{space, row.object}, context.temp_allocator); derr == .None && len(def.name) > 0 {
					return row.object, true
				}
			}
		}
		if !more {
			break
		}
	}
	return {}, false
}

@(private)
_fork_line :: proc(r: ^Runtime, caller: Object, m: convo.Mount_Entry, line: prim.Id) -> bool {
	tree := Object{caller.space, m.tree}
	h, herr := eng.tree_history(r.e, tree)
	if herr != .None {
		return false
	}
	defer eng.tree_release(r.e, tree)
	src := line_name(m.line)
	if run := run_find(r, caller); run != nil && run.ws != nil {
		for mb in run.ws.members {
			if mb.name == m.name && mb.m != nil {
				fs.mount_sync(mb.m)
				src = line_name(mb.run_line)
			}
		}
	}
	cur, found, verr := fs.history_line(h, src, context.temp_allocator)
	if verr != .None {
		return false
	}
	if !found {
		cur = fs.history_heads(h, context.temp_allocator)
	}
	return fs.history_set_line(h, line_name(line), cur) == .None
}

@(private)
_remaining :: proc(r: ^Runtime, o: Object, b: Budget) -> Budget {
	if b == {} {
		return b
	}
	out := b
	c, found, err := eng.catalog_get(r.e, o, context.temp_allocator)
	if err != .None || !found || len(c.usage) == 0 {
		return out
	}
	rd := prim.reader(c.usage)
	u := convo.decode_usage(&rd)
	used := u.input + u.output + u.cache_read + u.cache_write
	if out.tokens > 0 {
		out.tokens = out.tokens - min(out.tokens - 1, used)
	}
	return out
}

@(private)
_orch_send :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	o, ok := _obj_arg(v, "task", caller.space)
	if !ok {
		reply_done(r, rep, "task must be a conversation id", "", true)
		return
	}
	text := jstr(v, "message")
	mode := jstr(v, "mode")
	item: Rid
	err: eng.Error
	switch mode {
	case "steer":
		item, err = eng.convo_steer(r.e, o, text)
	case "interrupt":
		_, err = eng.convo_interrupt(r.e, o)
		if err == .None || err == .Pending {
			item, err = eng.convo_queue(r.e, o, text)
		}
	case:
		mode = "queue"
		item, err = eng.convo_queue(r.e, o, text)
	}
	if err != .None && err != .Pending {
		reply_done(r, rep, "the message could not be written", "", true)
		return
	}
	s, _, _ := task_status(r, o)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "task", hex(o.id))
	jw_kstr(&b, "message", rid_text(item))
	jw_kstr(&b, "status", TASK_STATUS_NAMES[s])
	append(&b, '}')
	reply_done(r, rep, concat("sent (", mode, ")"), string(b[:]), false)
}

@(private)
_children :: proc(r: ^Runtime, parent: Object, recursive: bool, limit: int) -> []prim.Id {
	out := make([dynamic]prim.Id, context.temp_allocator)
	frontier := make([dynamic]prim.Id, context.temp_allocator)
	append(&frontier, parent.id)
	seen := make(map[prim.Id]bool, context.temp_allocator)
	for len(frontier) > 0 && len(out) < limit {
		want := make(map[prim.Id]bool, context.temp_allocator)
		for f in frontier {
			want[f] = true
		}
		clear(&frontier)
		archived_opts := [2]bool{false, true}
		for archived in archived_opts {
			cur: eng.Map_Cursor
			for {
				rows, more, err := eng.catalog_list(r.e, parent.space, archived, &cur, 512, context.temp_allocator)
				if err != .None {
					break
				}
				for row in rows {
					if row.kind == .Conversation && want[row.parent.object] && !seen[row.object] {
						seen[row.object] = true
						append(&out, row.object)
						if recursive {
							append(&frontier, row.object)
						}
					}
				}
				if !more || len(rows) == 0 {
					break
				}
			}
			delete(cur.key)
		}
		if !recursive {
			break
		}
	}
	return out[:]
}

@(private)
_status_set :: proc(list: []string) -> (s: bit_set[Task_Status;u8]) {
	for x in list {
		for t in Task_Status {
			if TASK_STATUS_NAMES[t] == x {
				s += {t}
			}
		}
	}
	return
}

@(private)
_orch_wait :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) -> u64 {
	tasks := make([dynamic]prim.Id, context.temp_allocator)
	for s in jstrs(v, "tasks") {
		if id, ok := prim.id_parse(s); ok {
			append(&tasks, id)
		}
	}
	if len(tasks) == 0 {
		append(&tasks, .._children(r, caller, false, 10_000))
	}
	all := jstr(v, "condition") != "any"
	statuses := _status_set(jstrs(v, "statuses"))
	if statuses == {} {
		statuses = {.Completed, .Failed, .Cancelled, .Held}
	}
	cond: convo.Condition = .All if all else .Any
	timeout := jint(v, "timeout_seconds", -1)
	deadline: prim.Hlc
	if timeout > 0 {
		deadline = prim.hlc_make(wall_ms(r) + timeout * 1000, 0)
	}
	item := _await_existing(r, caller, tasks[:], cond)
	if obj.rid_none(item) {
		res, err := eng.exec(r.e, eng.Cmd_Await{object = caller, tasks = tasks[:], condition = cond, deadline = deadline})
		if err != .None && err != .Pending {
			reply_done(r, rep, "the wait could not be recorded", "", true)
			return 0
		}
		item = res.item
	}
	w := new(Await_Wait, r.allocator)
	w.r = r
	w.caller = caller
	w.item = item
	w.tasks = make([]prim.Id, len(tasks), r.allocator)
	copy(w.tasks, tasks[:])
	w.all = all
	w.statuses = statuses
	w.rep = rep
	w.rep_id = clone(rep.id, r.allocator)
	w.rep.id = w.rep_id
	r.next_token += 1
	w.token = r.next_token
	append(&r.awaits, w)
	if _await_check(r, w, timeout == 0) {
		return 0
	}
	if timeout > 0 {
		w.timer = prim.timer(eng.loop(r.e), timeout * 1000, w, _await_on_timeout)
	}
	return w.token
}

@(private)
_await_existing :: proc(r: ^Runtime, caller: Object, tasks: []prim.Id, cond: convo.Condition) -> Rid {
	items, err := eng.convo_intents(r.e, caller, context.temp_allocator)
	if err != .None {
		return {}
	}
	for it in items {
		if it.kind != .Await || it.by != r.self || it.condition != cond || len(it.tasks) != len(tasks) {
			continue
		}
		same := true
		for t in tasks {
			found := false
			for x in it.tasks {
				found ||= x == t
			}
			same &&= found
		}
		if same {
			return it.item
		}
	}
	return {}
}

@(private)
_await_on_timeout :: proc(l: ^prim.Loop, data: rawptr) {
	context = eng.context_for((^Await_Wait)(data).r.e)
	w := (^Await_Wait)(data)
	w.timer = 0
	_await_check(w.r, w, true)
}

_await_touched :: proc(r: ^Runtime, o: Object) {
	if len(r.awaits) == 0 {
		return
	}
	list := make([dynamic]^Await_Wait, context.temp_allocator)
	for w in r.awaits {
		for t in w.tasks {
			if t == o.id && w.caller.space == o.space {
				append(&list, w)
				break
			}
		}
	}
	for w in list {
		alive := false
		for x in r.awaits {
			alive ||= x == w
		}
		if alive {
			_await_check(r, w, false)
		}
	}
}

@(private)
_await_check :: proc(r: ^Runtime, w: ^Await_Wait, final: bool) -> bool {
	settled := 0
	b := make(Buf, context.temp_allocator)
	append(&b, `{"tasks":[`)
	for t, i in w.tasks {
		o := Object{w.caller.space, t}
		s, summary, _ := task_status(r, o)
		if s in w.statuses {
			settled += 1
		}
		if i > 0 {
			append(&b, ',')
		}
		append(&b, '{')
		jw_kstr(&b, "task", hex(t))
		if c, found, _ := eng.catalog_get(r.e, o, context.temp_allocator); found {
			jw_kstr(&b, "title", c.title)
			if len(c.usage) > 0 {
				_usage_json(&b, c.usage)
			}
		}
		jw_kstr(&b, "status", TASK_STATUS_NAMES[s])
		if len(summary) > 0 {
			jw_kstr(&b, "summary", summary)
		}
		append(&b, '}')
	}
	append(&b, ']')
	satisfied := settled == len(w.tasks) if w.all else settled > 0
	if len(w.tasks) == 0 {
		satisfied = true
	}
	if !satisfied && !final {
		return false
	}
	jw_kbool(&b, "satisfied", satisfied)
	jw_kbool(&b, "timed_out", !satisfied)
	append(&b, '}')
	if cw := _convo_w(r, w.caller); cw != nil && !obj.rid_none(w.item) {
		convo.writer_unqueue(cw, w.item, .Applied if satisfied else .Rejected)
		eng.touched(r.e, w.caller)
	}
	rep := w.rep
	rep.id = clone(w.rep_id, context.temp_allocator)
	text := "the tasks settled" if satisfied else "the wait timed out"
	structured := clone(string(b[:]), context.temp_allocator)
	_await_free(r, w)
	reply_done(r, rep, text, structured, false)
	return true
}

_await_free :: proc(r: ^Runtime, w: ^Await_Wait) {
	if w.timer != 0 {
		prim.timer_cancel(eng.loop(r.e), w.timer)
	}
	for x, i in r.awaits {
		if x == w {
			ordered_remove(&r.awaits, i)
			break
		}
	}
	delete(w.tasks, r.allocator)
	delete(w.rep_id, r.allocator)
	free(w, r.allocator)
}

@(private)
_usage_json :: proc(b: ^Buf, raw: []u8) {
	rd := prim.reader(raw)
	u := convo.decode_usage(&rd)
	jw_kopen(b, "usage")
	jw_kint(b, "input", i64(u.input))
	jw_kint(b, "output", i64(u.output))
	jw_kint(b, "cache_read", i64(u.cache_read))
	jw_kint(b, "cache_write", i64(u.cache_write))
	jw_close(b)
}

@(private)
_iso_ms :: proc(ms: i64) -> string {
	return rfc3339(ms)
}

@(private)
_orch_list :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	parent := caller
	if p, ok := _obj_arg(v, "parent", caller.space); ok {
		parent = p
	}
	limit := int(jint(v, "limit", 50))
	statuses := _status_set(jstrs(v, "statuses"))
	kids := _children(r, parent, jbool(v, "recursive"), 100_000)
	skip := 0
	if c := jstr(v, "cursor"); len(c) > 0 {
		n := 0
		for ch in c {
			if ch >= '0' && ch <= '9' {
				n = n * 10 + int(ch - '0')
			}
		}
		skip = n
	}
	b := make(Buf, context.temp_allocator)
	append(&b, `{"tasks":[`)
	shown := 0
	i := skip
	for i < len(kids) && shown < limit {
		id := kids[i]
		i += 1
		o := Object{caller.space, id}
		s, _, _ := task_status(r, o)
		if statuses != {} && s not_in statuses {
			continue
		}
		c, found, _ := eng.catalog_get(r.e, o, context.temp_allocator)
		jw_open(&b)
		jw_kstr(&b, "task", hex(id))
		if found {
			if !prim.id_is_zero(c.parent.object) {
				jw_kstr(&b, "parent", hex(c.parent.object))
			}
			jw_kstr(&b, "title", c.title)
			if !prim.id_is_zero(c.agent) {
				jw_kstr(&b, "agent", hex(c.agent))
			}
			if c.activity > 0 {
				jw_kstr(&b, "updated", _iso_ms(i64(c.activity)))
			}
			if len(c.usage) > 0 {
				_usage_json(&b, c.usage)
			}
		}
		jw_kstr(&b, "status", TASK_STATUS_NAMES[s])
		jw_close(&b)
		shown += 1
	}
	append(&b, ']')
	if i < len(kids) {
		nb := make(Buf, context.temp_allocator)
		jw_int(&nb, i64(i))
		jw_kstr(&b, "next_cursor", string(nb[:]))
	}
	append(&b, '}')
	reply_done(r, rep, "", string(b[:]), false)
}

@(private)
_orch_cancel :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	recursive := jbool(v, "recursive", true)
	reason := jstr(v, "reason")
	cancelled := make([dynamic]prim.Id, context.temp_allocator)
	settled := make([dynamic]prim.Id, context.temp_allocator)
	list := make([dynamic]prim.Id, context.temp_allocator)
	for s in jstrs(v, "tasks") {
		if id, ok := prim.id_parse(s); ok {
			append(&list, id)
			if recursive {
				append(&list, .._children(r, Object{caller.space, id}, true, 100_000))
			}
		}
	}
	for id in list {
		o := Object{caller.space, id}
		s, _, _ := task_status(r, o)
		if s == .Completed || s == .Failed || s == .Cancelled {
			append(&settled, id)
			continue
		}
		t, _ := task_get(r, o)
		map_put(r, meta_w(r, o), transmute([]u8)string(KEY_TASK), field_bytes(1, budget_encode(t.budget)), omap.field_bool(2, true), omap.field_str(3, reason))
		eng.convo_interrupt(r.e, o)
		append(&cancelled, id)
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_karr(&b, "cancelled")
	for id in cancelled {
		jw_item_str(&b, hex(id))
	}
	jw_end(&b)
	jw_karr(&b, "already_settled")
	for id in settled {
		jw_item_str(&b, hex(id))
	}
	jw_end(&b)
	append(&b, '}')
	reply_done(r, rep, "", string(b[:]), false)
}

@(private)
_orch_result :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	o, ok := _obj_arg(v, "task", caller.space)
	if !ok {
		reply_done(r, rep, "task must be a conversation id", "", true)
		return
	}
	max_chars := int(jint(v, "max_chars", 20000))
	s, _, _ := task_status(r, o)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "task", hex(o.id))
	jw_kstr(&b, "status", TASK_STATUS_NAMES[s])
	result := _last_reply_text(r, o, max_chars)
	jw_kstr(&b, "result", result)
	truncated := len(result) >= max_chars
	diff := jbool(v, "diff")
	files, diff_text := task_changes(r, caller, o, diff, max_chars)
	jw_karr(&b, "files")
	for f in files {
		jw_open(&b)
		jw_kstr(&b, "mount", f.mount)
		jw_kstr(&b, "path", f.path)
		jw_kstr(&b, "change", f.change)
		jw_close(&b)
	}
	jw_end(&b)
	if diff {
		jw_kstr(&b, "diff", diff_text)
	}
	if n := int(jint(v, "messages")); n > 0 {
		jw_karr(&b, "messages")
		ev, verr := eng.convo_view(r.e, o)
		if verr == .None {
			if t, terr := convo.view_tail(ev, r.self, context.temp_allocator); terr == .None {
				pg, _ := convo.page(ev, &t, {}, n, context.temp_allocator)
				for i := len(pg.messages) - 1; i >= 0; i -= 1 {
					m := pg.messages[i]
					jw_open(&b)
					jw_kstr(&b, "role", _role_name(m.role))
					jw_kstr(&b, "text", _blocks_text(m.blocks, max_chars))
					jw_close(&b)
				}
			}
		}
		jw_end(&b)
	}
	if c, found, _ := eng.catalog_get(r.e, o, context.temp_allocator); found && len(c.usage) > 0 {
		_usage_json(&b, c.usage)
	}
	if t, tok := task_get(r, o); tok && len(t.conflicts) > 0 {
		jw_karr(&b, "land_conflicts")
		for c in t.conflicts {
			jw_item_str(&b, c)
		}
		jw_end(&b)
	}
	jw_kbool(&b, "truncated", truncated)
	append(&b, '}')
	reply_done(r, rep, result, string(b[:]), false)
}

@(private)
_role_name :: proc(role: convo.Role) -> string {
	switch role {
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .System:
		return "system"
	case .Tool:
		return "tool"
	}
	return "user"
}

File_Change :: struct {
	mount:  string,
	path:   string,
	change: string,
}

task_changes :: proc(r: ^Runtime, caller: Object, task: Object, want_diff: bool, max_chars: int) -> (out: []File_Change, diff: string) {
	context = eng.context_for(r.e)
	fd, err := fork_diff_open(r, caller, task, want_diff, max_chars)
	if err != .None {
		return nil, ""
	}
	defer fork_diff_close(fd)
	return fork_diff_result(fd, context.temp_allocator)
}

@(private)
_spans_touched :: proc(h: ^fs.History, spans: []crdt.Lv_Span, out: ^map[fstree.Inode_Id]bool) {
	for span in spans {
		lv := span.lv
		end := span.lv + span.len
		for lv < end {
			first, n, stream, off, ok := fs.history_batch_at(h, lv)
			if !ok {
				return
			}
			b, berr := fs.history_read_batch(h, stream, off, context.temp_allocator)
			if berr == .None {
				x := first
				for op in b.ops {
					lo := x
					hi := x + op.len
					x = hi
					if hi <= lv || lo >= min(end, first + n) {
						continue
					}
					if op.kind != .Opaque {
						out[fs.op_inode(h, op.target)] = true
						continue
					}
					rd := prim.reader(op.content)
					tag := prim.read_u8(&rd)
					switch tag {
					case fs.TOP_CREATE:
						_, seq := crdt.graph_op(&h.g, lo)
						out[fstree.Inode_Id{crdt.graph_intern(&h.g, b.actor), seq}] = true
					case fs.TOP_MOVE, fs.TOP_REMOVE, fs.TOP_RESTORE, fs.TOP_FLAGS, fs.TOP_TARGET, fs.TOP_CONTENT:
						a := prim.read_id(&rd)
						s := prim.read_uvarint(&rd)
						if prim.reader_ok(&rd) {
							out[fs.op_inode(h, crdt.Op_Id{a, s})] = true
						}
					}
				}
			}
			lv = first + n
		}
	}
}

@(private)
_orch_merge :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	task, ok := _obj_arg(v, "task", caller.space)
	if !ok {
		reply_done(r, rep, "task must be a conversation id", "", true)
		return
	}
	dry := jbool(v, "dry_run")
	only := jstrs(v, "mounts")
	if t, tok := task_get(r, task); tok && len(t.conflicts) > 0 {
		b := make(Buf, context.temp_allocator)
		append(&b, '{')
		jw_kbool(&b, "landed", false)
		jw_kbool(&b, "held", true)
		jw_karr(&b, "conflicts")
		for c in t.conflicts {
			jw_open(&b)
			jw_kstr(&b, "path", c)
			jw_close(&b)
		}
		jw_end(&b)
		jw_karr(&b, "mounts")
		jw_end(&b)
		append(&b, '}')
		reply_done(r, rep, "the task is held with land conflicts in its fork; resolve them there first", string(b[:]), false)
		return
	}
	kms, _ := eng.convo_mounts(r.e, task, context.temp_allocator)
	cms, _ := eng.convo_mounts(r.e, caller, context.temp_allocator)
	b := make(Buf, context.temp_allocator)
	append(&b, `{"mounts":[`)
	all_landed := true
	for km in kms {
		if len(only) > 0 {
			want := false
			for x in only {
				want ||= x == km.name
			}
			if !want {
				continue
			}
		}
		target := ""
		for cm in cms {
			if cm.name == km.name && cm.tree == km.tree {
				target = line_name(cm.line)
			}
		}
		if len(target) == 0 || target == line_name(km.line) {
			continue
		}
		if run := run_find(r, caller); run != nil && run.ws != nil {
			for mb in run.ws.members {
				if mb.name == km.name {
					target = line_name(mb.run_line)
				}
			}
		}
		landed, nfiles, conflicts := merge_line(r, Object{caller.space, km.tree}, line_name(km.line), target, dry)
		all_landed &&= landed
		jw_open(&b)
		jw_kstr(&b, "mount", km.name)
		jw_kbool(&b, "landed", landed)
		jw_kint(&b, "files", i64(nfiles))
		jw_karr(&b, "conflicts")
		for c in conflicts {
			jw_open(&b)
			jw_kstr(&b, "path", c)
			jw_close(&b)
		}
		jw_end(&b)
		jw_close(&b)
	}
	append(&b, ']')
	jw_kbool(&b, "landed", all_landed && !dry)
	append(&b, '}')
	reply_done(r, rep, "", string(b[:]), false)
}

merge_line :: proc(r: ^Runtime, tree: Object, from: string, into: string, dry: bool) -> (landed: bool, files: int, conflicts: []string) {
	context = eng.context_for(r.e)
	h, herr := eng.tree_history(r.e, tree)
	if herr != .None {
		return false, 0, nil
	}
	defer eng.tree_release(r.e, tree)
	theirs, f1, _ := fs.history_line(h, from, context.temp_allocator)
	ours, f2, _ := fs.history_line(h, into, context.temp_allocator)
	if !f1 || !f2 {
		return false, 0, nil
	}
	ol := make([dynamic]crdt.Lv, context.temp_allocator)
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, ours, &ol) != .None || crdt.graph_version_lvs(&h.g, theirs, &tl) != .None {
		return false, 0, nil
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, ol[:], tl[:], &only_a, &only_b)
	a_set := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	b_set := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	_spans_touched(h, only_a[:], &a_set)
	_spans_touched(h, only_b[:], &b_set)
	files = len(b_set)
	common := make([dynamic]crdt.Lv, context.temp_allocator)
	walk := make([dynamic]crdt.Walk_Span, context.temp_allocator)
	crdt.graph_conflicting(&h.g, ol[:], tl[:], &walk, &common)
	base := crdt.graph_version_ids(&h.g, common[:], context.temp_allocator)
	cl := make([dynamic]string, context.temp_allocator)
	snap, serr := fs.version_snapshot(h, tl[:])
	if serr == .None {
		defer fstree.snapshot_destroy(&snap)
		for ino in _sorted_inodes(b_set) {
			if !a_set[ino] {
				continue
			}
			bt, e1 := fs.history_text_at(h, ino, base, context.temp_allocator)
			ot, e2 := fs.history_text_at(h, ino, ours, context.temp_allocator)
			tt, e3 := fs.history_text_at(h, ino, theirs, context.temp_allocator)
			if e1 != .None || e2 != .None || e3 != .None {
				continue
			}
			res, merr := textdiff.merge3(bt, ot, tt, {style = .Diff3, ours_label = into, base_label = "base", theirs_label = from}, context.temp_allocator)
			if merr == nil && res.conflicts > 0 {
				p, _, _ := fstree.path(&snap, ino, context.temp_allocator)
				append(&cl, p)
			}
		}
	}
	if len(cl) > 0 || dry {
		return false, files, cl[:]
	}
	union_lv := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, ol[:], tl[:], &union_lv)
	merged := crdt.graph_version_ids(&h.g, union_lv[:], context.temp_allocator)
	if fs.history_set_line(h, into, merged) != .None {
		return false, files, nil
	}
	reg, rerr := eng.registry(r.e)
	if rerr == .None {
		for m in reg.mounts {
			if m != nil && m.history == h && m.line == into {
				fs.mount_materialize(m)
			}
		}
	}
	return true, files, nil
}

@(private)
_orch_history :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	q := jstr(v, "query")
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, q)
	if c := jstr(v, "conversation"); len(c) == 32 {
		append(&parts, concat("object:", c))
	}
	if !strings.has_prefix(q, "wrote:") {
		append(&parts, "kind:conversation")
	}
	if s := jstr(v, "since"); len(s) > 0 {
		append(&parts, concat("after:", s))
	}
	if s := jstr(v, "until"); len(s) > 0 {
		append(&parts, concat("before:", s))
	}
	query := strings.join(parts[:], " ", context.temp_allocator)
	fk := File_Key_Ctx{r = r, caller = caller}
	req := search.Request {
		limit        = int(jint(v, "limit", 20)),
		file_key     = _file_key,
		resolve_data = &fk,
		semantic     = jstr(v, "mode") == "semantic",
	}
	if c := jstr(v, "cursor"); len(c) > 0 {
		req.cursor = transmute([]u8)c
	}
	res, err := eng.search_query(r.e, query, req, context.temp_allocator)
	if err != .None {
		reply_done(r, rep, "search is unavailable", "", true)
		return
	}
	b := make(Buf, context.temp_allocator)
	append(&b, `{"hits":[`)
	for h in res.hits {
		jw_open(&b)
		jw_kstr(&b, "conversation", hex(h.object))
		if c, found, _ := eng.catalog_get(r.e, Object{caller.space, h.object}, context.temp_allocator); found {
			jw_kstr(&b, "title", c.title)
		}
		if len(h.ref) == 32 {
			if rid, rok := rid_from_bytes(h.ref); rok {
				jw_kstr(&b, "message", rid_text(rid))
			}
		} else {
			jw_kstr(&b, "message", "")
		}
		jw_kstr(&b, "author", hex(h.participant))
		jw_kstr(&b, "time", rfc3339(prim.hlc_ms(h.hlc)))
		jw_kstr(&b, "snippet", h.snippet)
		jw_kf64(&b, "score", h.score)
		jw_close(&b)
	}
	append(&b, ']')
	if len(res.cursor) > 0 {
		jw_kstr(&b, "next_cursor", string(res.cursor))
	}
	append(&b, '}')
	reply_done(r, rep, "", string(b[:]), false)
}

@(private)
File_Key_Ctx :: struct {
	r:      ^Runtime,
	caller: Object,
}

@(private)
_file_key :: proc(data: rawptr, path: string, out: ^[dynamic]u8) -> bool {
	context = eng.context_for((^File_Key_Ctx)(data).r.e)
	c := (^File_Key_Ctx)(data)
	ms, err := eng.convo_mounts(c.r.e, c.caller, context.temp_allocator)
	if err != .None {
		return false
	}
	p := strings.trim_prefix(path, "/")
	for m in ms {
		rel := p
		prefix := m.path if len(m.path) > 0 else m.name
		if len(ms) > 1 {
			if !strings.has_prefix(p, concat(prefix, "/")) {
				continue
			}
			rel = p[len(prefix) + 1:]
		}
		h := prim.id_hex(m.tree)
		append(out, string(h[:]))
		append(out, '/')
		append(out, rel)
		return true
	}
	return false
}

@(private)
_orch_redact :: proc(r: ^Runtime, caller: Object, v: json.Value, rep: Reply) {
	if !jbool(v, "confirm") {
		reply_done(r, rep, "confirm must be true", "", true)
		return
	}
	o, ok := _obj_arg(v, "object", caller.space)
	if !ok {
		reply_done(r, rep, "object must be an id", "", true)
		return
	}
	c, found, _ := eng.catalog_get(r.e, o, context.temp_allocator)
	if !found {
		reply_done(r, rep, "unknown object", "", true)
		return
	}
	count := 0
	err: eng.Error
	#partial switch c.kind {
	case .Conversation:
		if m := jstr(v, "message"); len(m) > 0 {
			rid, rok := parse_rid(m)
			if !rok {
				reply_done(r, rep, "message must be a record id", "", true)
				return
			}
			err = eng.convo_redact(r.e, o, rid)
			count = 1
		} else {
			ev, verr := eng.convo_view(r.e, o)
			if verr != .None {
				reply_done(r, rep, "the conversation could not be read", "", true)
				return
			}
			t, terr := convo.view_tail(ev, r.self, context.temp_allocator)
			if terr != .None {
				reply_done(r, rep, "the conversation is not fully replicated", "", true)
				return
			}
			pg, _ := convo.page(ev, &t, {}, 1_000_000, context.temp_allocator)
			for m in pg.messages {
				if e2 := eng.convo_redact(r.e, o, m.id); e2 == .None || e2 == .Pending {
					count += 1
				} else {
					err = e2
				}
			}
		}
	case .Text:
		if jhas(v, "range") {
			rg := jget(v, "range")
			s := int(jint(rg, "start"))
			e := int(jint(rg, "end"))
			if e < s {
				reply_done(r, rep, "range end precedes start", "", true)
				return
			}
			err = eng.text_redact(r.e, o, s, e - s)
		} else {
			data, rerr := eng.text_read(r.e, o, context.temp_allocator)
			if rerr != .None {
				reply_done(r, rep, "the text could not be read", "", true)
				return
			}
			err = eng.text_redact(r.e, o, 0, len(data))
		}
		count = 1
	case:
		reply_done(r, rep, "redaction of this object kind is done per key or range", "", true)
		return
	}
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kbool(&b, "redacted", err == .None || err == .Pending)
	jw_kint(&b, "records", i64(count))
	append(&b, '}')
	reply_done(r, rep, "", string(b[:]), err != .None && err != .Pending)
}

@(private)
_sorted_inodes :: proc(set: map[fstree.Inode_Id]bool) -> []fstree.Inode_Id {
	out := make([dynamic]fstree.Inode_Id, 0, len(set), context.temp_allocator)
	for ino in set {
		append(&out, ino)
	}
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && (out[j].actor < out[j - 1].actor || (out[j].actor == out[j - 1].actor && out[j].seq < out[j - 1].seq)) {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return out[:]
}

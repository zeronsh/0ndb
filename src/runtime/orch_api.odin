package rt

import eng "../engine"
import "../mcp"
import "../prim"

Spawn_Mount :: struct {
	name:  string,
	tree:  prim.Id,
	path:  string,
	share: bool,
}

Spawn_Args :: struct {
	goal:      string,
	title:     string,
	extra:     string,
	agent:     prim.Id,
	workspace: prim.Id,
	provider:  string,
	model:     string,
	mounts:    []Spawn_Mount,
	budget:    Budget,
	runner:    prim.Id,
}

Send_Mode :: enum u8 {
	Queue,
	Steer,
	Interrupt,
}

Task_Statuses :: bit_set[Task_Status;u8]

@(private)
_api_call :: proc(r: ^Runtime, caller: Object, tool: mcp.Catalog_Tool, input: []u8, data: rawptr, done: Orch_Done) -> u64 {
	a, ok := agent_resolve(r, caller, "", "", context.temp_allocator)
	ap: ^Agent_Info = &a if ok else nil
	return orch_call(r, caller, ap, tool, string(input), Reply{kind = .Callback, o = caller, done = done, data = data})
}

@(private)
_w_ids :: proc(b: ^Buf, key: string, ids: []prim.Id) {
	jw_karr(b, key)
	for id in ids {
		jw_item_str(b, hex(id))
	}
	jw_end(b)
}

@(private)
_w_statuses :: proc(b: ^Buf, key: string, s: Task_Statuses) {
	if s == {} {
		return
	}
	jw_karr(b, key)
	for t in Task_Status {
		if t in s {
			jw_item_str(b, TASK_STATUS_NAMES[t])
		}
	}
	jw_end(b)
}

task_spawn :: proc(r: ^Runtime, caller: Object, args: Spawn_Args, data: rawptr, done: Orch_Done) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "goal", args.goal)
	if len(args.title) > 0 {
		jw_kstr(&b, "title", args.title)
	}
	if len(args.extra) > 0 {
		jw_kstr(&b, "context", args.extra)
	}
	if !prim.id_is_zero(args.agent) {
		jw_kstr(&b, "agent", hex(args.agent))
	}
	if !prim.id_is_zero(args.workspace) {
		jw_kstr(&b, "workspace", hex(args.workspace))
	}
	if len(args.provider) > 0 {
		jw_kstr(&b, "provider", args.provider)
	}
	if len(args.model) > 0 {
		jw_kstr(&b, "model", args.model)
	}
	if args.mounts != nil {
		jw_karr(&b, "mounts")
		for m in args.mounts {
			jw_open(&b)
			jw_kstr(&b, "name", m.name)
			if !prim.id_is_zero(m.tree) {
				jw_kstr(&b, "tree", hex(m.tree))
			}
			if len(m.path) > 0 {
				jw_kstr(&b, "path", m.path)
			}
			jw_kbool(&b, "share", m.share)
			jw_close(&b)
		}
		jw_end(&b)
	}
	if bj := budget_encode(args.budget); len(bj) > 0 {
		jw_kraw(&b, "budget", string(bj))
	}
	if !prim.id_is_zero(args.runner) {
		jw_kstr(&b, "runner", hex(args.runner))
	}
	append(&b, '}')
	_api_call(r, caller, .Spawn, b[:], data, done)
}

task_send :: proc(r: ^Runtime, caller: Object, task: prim.Id, message: string, mode: Send_Mode, data: rawptr, done: Orch_Done) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "task", hex(task))
	jw_kstr(&b, "message", message)
	jw_kstr(&b, "mode", "steer" if mode == .Steer else ("interrupt" if mode == .Interrupt else "queue"))
	append(&b, '}')
	_api_call(r, caller, .Send, b[:], data, done)
}

task_wait :: proc(r: ^Runtime, caller: Object, tasks: []prim.Id, all: bool, statuses: Task_Statuses, timeout_seconds: i64, data: rawptr, done: Orch_Done) -> (token: u64) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	if len(tasks) > 0 {
		_w_ids(&b, "tasks", tasks)
	}
	jw_kstr(&b, "condition", "all" if all else "any")
	_w_statuses(&b, "statuses", statuses)
	if timeout_seconds >= 0 {
		jw_kint(&b, "timeout_seconds", timeout_seconds)
	}
	append(&b, '}')
	return _api_call(r, caller, .Wait, b[:], data, done)
}

task_wait_cancel :: proc(r: ^Runtime, token: u64) {
	context = eng.context_for(r.e)
	tool_abort(r, token)
}

task_list :: proc(r: ^Runtime, caller: Object, parent: prim.Id, recursive: bool, statuses: Task_Statuses, limit: int, cursor: string, data: rawptr, done: Orch_Done) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	if !prim.id_is_zero(parent) {
		jw_kstr(&b, "parent", hex(parent))
	}
	jw_kbool(&b, "recursive", recursive)
	_w_statuses(&b, "statuses", statuses)
	if limit > 0 {
		jw_kint(&b, "limit", i64(limit))
	}
	if len(cursor) > 0 {
		jw_kstr(&b, "cursor", cursor)
	}
	append(&b, '}')
	_api_call(r, caller, .List, b[:], data, done)
}

task_cancel :: proc(r: ^Runtime, caller: Object, tasks: []prim.Id, recursive: bool, reason: string, data: rawptr, done: Orch_Done) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	_w_ids(&b, "tasks", tasks)
	jw_kbool(&b, "recursive", recursive)
	if len(reason) > 0 {
		jw_kstr(&b, "reason", reason)
	}
	append(&b, '}')
	_api_call(r, caller, .Cancel, b[:], data, done)
}

task_result :: proc(r: ^Runtime, caller: Object, task: prim.Id, messages: int, diff: bool, max_chars: int, data: rawptr, done: Orch_Done) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "task", hex(task))
	jw_kint(&b, "messages", i64(messages))
	jw_kbool(&b, "diff", diff)
	if max_chars > 0 {
		jw_kint(&b, "max_chars", i64(max_chars))
	}
	append(&b, '}')
	_api_call(r, caller, .Result, b[:], data, done)
}

task_merge :: proc(r: ^Runtime, caller: Object, task: prim.Id, mounts: []string, dry_run: bool, data: rawptr, done: Orch_Done) {
	context = eng.context_for(r.e)
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	jw_kstr(&b, "task", hex(task))
	if len(mounts) > 0 {
		jw_karr(&b, "mounts")
		for m in mounts {
			jw_item_str(&b, m)
		}
		jw_end(&b)
	}
	jw_kbool(&b, "dry_run", dry_run)
	append(&b, '}')
	_api_call(r, caller, .Merge, b[:], data, done)
}

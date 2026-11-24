package rt

import "core:strings"
import eng "../engine"
import "../fs"
import "../mcp"
import "../model"
import "../prim"

TOOL_OUTPUT_MAX :: 64 * 1024

Reply_Kind :: enum u8 {
	Native,
	Server,
	Callback,
}

Orch_Done :: #type proc(data: rawptr, r: ^Runtime, result: string, is_error: bool)

Reply :: struct {
	kind: Reply_Kind,
	o:    Object,
	id:   string,
	ref:  mcp.Ref,
	done: Orch_Done,
	data: rawptr,
}

@(private)
FILE_TOOLS :: [?]model.Tool_Def {
	{name = "read_file", description = "Read a text file in the working directory. Returns numbered lines; use offset and limit for large files.", schema = `{"type":"object","properties":{"path":{"type":"string","minLength":1},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"],"additionalProperties":false}`},
	{name = "write_file", description = "Create or replace a file in the working directory with the given content.", schema = `{"type":"object","properties":{"path":{"type":"string","minLength":1},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}`},
	{name = "edit_file", description = "Replace an exact string in a file. old_string must occur exactly once unless replace_all is true.", schema = `{"type":"object","properties":{"path":{"type":"string","minLength":1},"old_string":{"type":"string","minLength":1},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"],"additionalProperties":false}`},
	{name = "list_files", description = "List the entries of a directory in the working directory.", schema = `{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}`},
}

@(private)
SHELL_TOOL :: model.Tool_Def {
	name        = "shell",
	description = "Run a shell command in the working directory and return its combined output and exit status.",
	schema      = `{"type":"object","properties":{"command":{"type":"string","minLength":1},"timeout_seconds":{"type":"integer","minimum":1,"maximum":3600}},"required":["command"],"additionalProperties":false}`,
}

builtin_defs :: proc(r: ^Runtime, a: ^Agent_Info, out: ^[dynamic]model.Tool_Def, allocator := context.allocator) {
	if .Files in a.builtins {
		for t in FILE_TOOLS {
			append(out, t)
		}
	}
	if .Shell in a.builtins {
		append(out, SHELL_TOOL)
	}
	tools: mcp.Catalog_Tools
	if .Orchestration in a.builtins {
		tools += mcp.ORCHESTRATION_TOOLS
	}
	if .Memory in a.builtins {
		tools += mcp.MEMORY_TOOLS
	}
	if .Schedule in a.builtins {
		tools += {.Schedule}
	}
	if .History in a.builtins {
		tools += {.History_Search}
	}
	if .Redact in a.builtins {
		tools += {.Redact}
	}
	for t in mcp.Catalog_Tool {
		if t in tools {
			e := mcp.catalog_entry(t)
			append(out, model.Tool_Def{name = e.name, description = e.description, schema = e.input_schema})
		}
	}
}

tool_dispatch :: proc(r: ^Runtime, run: ^Run, n: ^Native, call: ^Tool_Call) -> u64 {
	rep := Reply {
		kind = .Native,
		o    = run.o,
		id   = call.id,
	}
	if t, ok := mcp.catalog_lookup(call.name); ok {
		return orch_call(r, run.o, &run.ai, t, call.input, rep)
	}
	switch call.name {
	case "read_file", "write_file", "edit_file", "list_files":
		text, is_error := file_tool(r, run, call.name, call.input, call.id)
		reply_done(r, rep, text, "", is_error)
		return 0
	case "shell":
		return shell_tool(r, run, call, rep)
	}
	if strings.has_prefix(call.name, "mcp__") {
		for c in n.conns {
			if token, ok := mcp_conn_call(c, call.name, call.input, rep); ok {
				return token
			}
		}
	}
	if r.cfg.tools.call != nil {
		r.next_token += 1
		call.token = r.next_token
		if r.cfg.tools.call(r.cfg.tools.data, r, call) {
			return call.token
		}
	}
	reply_done(r, rep, concat("unknown tool: ", call.name), "", true)
	return 0
}

tool_result :: proc(r: ^Runtime, call: ^Tool_Call, text: string, is_error := false) {
	context = eng.context_for(r.e)
	reply_done(r, Reply{kind = .Native, o = call.object, id = call.id}, text, "", is_error)
}

tool_abort :: proc(r: ^Runtime, token: u64) {
	if token == 0 {
		return
	}
	for j in r.jobs {
		if j.token == token {
			job_kill(j)
			return
		}
	}
	for w in r.awaits {
		if w.token == token {
			_await_free(r, w)
			return
		}
	}
	for c in r.clients {
		if mcp_conn_abort(c, token) {
			return
		}
	}
	if r.cfg.tools.abort != nil {
		r.cfg.tools.abort(r.cfg.tools.data, r, token)
	}
}

reply_done :: proc(r: ^Runtime, rep: Reply, text: string, structured: string, is_error: bool) {
	switch rep.kind {
	case .Native:
		run := run_find(r, rep.o)
		if run == nil || run.native == nil {
			return
		}
		body := text
		if len(structured) > 0 {
			body = structured if len(text) == 0 else concat(text, "\n", structured)
		}
		clipped, cut := utf8_clip(body, TOOL_OUTPUT_MAX)
		if cut {
			clipped = concat(clipped, "\n[output truncated]")
		}
		native_tool_result(run.native, rep.id, clipped, is_error)
	case .Server:
		serve_reply(r, rep.ref, text, structured, is_error)
	case .Callback:
		if rep.done != nil {
			rep.done(rep.data, r, structured if len(structured) > 0 else text, is_error)
		}
	}
}

@(private)
_resolve_path :: proc(run: ^Run, path: string) -> (abs: string, ok: bool) {
	if run.ws == nil {
		return "", false
	}
	root := run.ws.root
	p := path
	if fs.path_is_abs(fs.clean_path(p, context.temp_allocator)) {
		if rel, in_root := observe_under(fs.clean_path(p, context.temp_allocator), root); in_root {
			p = rel
		} else {
			return "", false
		}
	}
	clean := fs.clean_path(concat(root, "/", p), context.temp_allocator)
	if _, in_root := observe_under(clean, root); !in_root {
		return "", false
	}
	return clean, true
}

observe_under :: proc(path: string, root: string) -> (rel: string, ok: bool) {
	if path == root {
		return "", true
	}
	if len(path) > len(root) && strings.has_prefix(path, root) && path[len(root)] == '/' {
		return path[len(root) + 1:], true
	}
	return "", false
}

file_tool :: proc(r: ^Runtime, run: ^Run, name: string, input: string, call_id := "") -> (text: string, is_error: bool) {
	v, ok := json_parse(input)
	if !ok {
		return "the input is not valid JSON", true
	}
	if run.ws == nil {
		return "this conversation has no file trees mounted", true
	}
	path, pok := _resolve_path(run, jstr(v, "path") if jhas(v, "path") else ".")
	if !pok {
		return "the path is outside the working directory", true
	}
	vfs := r.e.base
	switch name {
	case "read_file":
		data, err := prim.read_file(vfs, path, context.temp_allocator)
		if err != .None {
			return concat("cannot read ", jstr(v, "path")), true
		}
		off := max(int(jint(v, "offset", 1)), 1)
		limit := int(jint(v, "limit", 2000))
		b := make(Buf, context.temp_allocator)
		line := 1
		rest := string(data)
		for len(rest) > 0 && line < off + limit {
			nl := strings.index_byte(rest, '\n')
			cur := rest if nl < 0 else rest[:nl]
			rest = "" if nl < 0 else rest[nl + 1:]
			if line >= off {
				jw_int(&b, i64(line))
				append(&b, '\t')
				append(&b, cur)
				append(&b, '\n')
			}
			line += 1
		}
		return string(b[:]), false
	case "write_file":
		content := jstr(v, "content")
		prim.mkdir_all(vfs, prim.dir_name(path), 0o755)
		if prim.replace_atomic(vfs, path, transmute([]u8)content) != .None {
			return concat("cannot write ", jstr(v, "path")), true
		}
		_mark_written(run, path, call_id)
		return concat("wrote ", jstr(v, "path")), false
	case "edit_file":
		data, err := prim.read_file(vfs, path, context.temp_allocator)
		if err != .None {
			return concat("cannot read ", jstr(v, "path")), true
		}
		old := jstr(v, "old_string")
		new_s := jstr(v, "new_string")
		count := strings.count(string(data), old)
		if count == 0 {
			return "old_string was not found", true
		}
		if count > 1 && !jbool(v, "replace_all") {
			return "old_string occurs more than once; give more context or set replace_all", true
		}
		res, _ := strings.replace(string(data), old, new_s, -1 if jbool(v, "replace_all") else 1, context.temp_allocator)
		if prim.replace_atomic(vfs, path, transmute([]u8)res) != .None {
			return concat("cannot write ", jstr(v, "path")), true
		}
		_mark_written(run, path, call_id)
		return concat("edited ", jstr(v, "path")), false
	case "list_files":
		d: prim.Dir
		if prim.dir_open(vfs, &d, path, context.temp_allocator) != .None {
			return concat("cannot list ", jstr(v, "path")), true
		}
		defer prim.dir_close(vfs, &d)
		names := make([dynamic]string, context.temp_allocator)
		for {
			e, more, derr := prim.dir_next(vfs, &d)
			if derr != .None || !more {
				break
			}
			if e.name == "." || e.name == ".." || fs.path_internal(e.name) {
				continue
			}
			nm := e.name
			if e.kind == .Dir {
				nm = concat(e.name, "/")
			}
			append(&names, clone(nm, context.temp_allocator))
		}
		_sort_strings(names[:])
		return strings.join(names[:], "\n", context.temp_allocator), false
	}
	return "unknown file tool", true
}

@(private)
_mark_written :: proc(run: ^Run, path: string, call_id: string) {
	ws := run.ws
	if ws == nil {
		return
	}
	scope: ^fs.Scope
	tool := -1
	for t in run.tools {
		if t.id == call_id && t.scope >= 0 && t.scope < len(ws.tools) && ws.tools[t.scope].open {
			tool = t.scope
		}
	}
	for mb, i in ws.members {
		if mb.m == nil {
			continue
		}
		rel, ok := observe_under(path, mb.m.root)
		if !ok {
			continue
		}
		scope = mb.turn
		if tool >= 0 && tool < len(ws.tools) {
			scope = ws.tools[tool].scopes[i]
		}
		fs.mount_mark(mb.m, rel, scope)
	}
}

@(private)
Shell_Ctx :: struct {
	r:   ^Runtime,
	rep: Reply,
}

shell_tool :: proc(r: ^Runtime, run: ^Run, call: ^Tool_Call, rep: Reply) -> u64 {
	v, ok := json_parse(call.input)
	if !ok {
		reply_done(r, rep, "the input is not valid JSON", "", true)
		return 0
	}
	cmd := jstr(v, "command")
	cwd := run.ws.root if run.ws != nil else concat(r.cfg.work_root, "/", hex(run.o.id))
	prim.mkdir_all(r.e.base, cwd, 0o755)
	argv := shell_argv(cmd)
	req := Spawn_Request {
		argv      = argv,
		cwd       = cwd,
		env       = r.cfg.env,
		new_group = true,
		observe   = run.ai.observe,
	}
	ctx := new(Shell_Ctx, r.allocator)
	ctx.r = r
	ctx.rep = rep
	ctx.rep.id = clone(call.id, r.allocator)
	timeout := jint(v, "timeout_seconds", 600) * 1000
	j, err := job_start(r, &req, nil, ctx, _shell_done, timeout, TOOL_OUTPUT_MAX * 4)
	if err != .None {
		delete(ctx.rep.id, r.allocator)
		free(ctx, r.allocator)
		reply_done(r, rep, "the command could not be started", "", true)
		return 0
	}
	r.next_token += 1
	j.token = r.next_token
	if run.ws != nil {
		for &t in run.tools {
			if t.id == call.id && t.scope >= 0 && t.scope < len(run.ws.tools) {
				for s in run.ws.tools[t.scope].scopes {
					if s != nil {
						fs.scope_add_pid(s, j.child.pid)
					}
				}
			}
		}
	}
	return j.token
}

@(private)
_shell_done :: proc(j: ^Job, status: prim.Exit_Status) {
	ctx := (^Shell_Ctx)(j.data)
	r := ctx.r
	b := make(Buf, context.temp_allocator)
	append(&b, ..j.out[:])
	if len(j.err) > 0 {
		if len(b) > 0 && b[len(b) - 1] != '\n' {
			append(&b, '\n')
		}
		append(&b, ..j.err[:])
	}
	if j.killed {
		append(&b, "\n[killed]")
	}
	append(&b, "\n[exit ")
	jw_int(&b, i64(status.code))
	if status.signal != 0 {
		append(&b, " signal ")
		jw_int(&b, i64(status.signal))
	}
	append(&b, "]")
	rep := ctx.rep
	rep.id = clone(rep.id, context.temp_allocator)
	delete(ctx.rep.id, r.allocator)
	free(ctx, r.allocator)
	reply_done(r, rep, string(b[:]), "", status.code != 0 || status.signal != 0)
}

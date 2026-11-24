package agent

import "core:encoding/json"
import "core:strconv"
import "core:strings"

@(private)
claude_launch :: proc(d: ^Driver, argv: ^[dynamic]string, b: ^[dynamic]u8) {
	base_argv(d, argv)
	append(
		argv,
		"-p",
		"--input-format",
		"stream-json",
		"--output-format",
		"stream-json",
		"--verbose",
		"--include-partial-messages",
		"--replay-user-messages",
		"--permission-prompt-tool",
		"stdio",
		"--permission-mode",
	)
	switch d.req.access {
	case .Plan:
		append(argv, "plan")
	case .Edit:
		append(argv, "acceptEdits")
	case .Full:
		append(argv, d.req.ask_permissions ? "default" : "bypassPermissions")
	}
	if d.req.model != "" {
		append(argv, "--model", d.req.model)
	}
	if d.req.effort != "" {
		append(argv, "--effort", d.req.effort)
	}
	if len(d.req.mcp) > 0 {
		append(argv, "--mcp-config", claude_mcp_config(d))
	}
	t := d.req.rewind
	if t.session != "" {
		if t.after != "" {
			append(argv, "--resume", t.session, "--resume-session-at", t.after, "--fork-session")
		}
	} else if d.req.resume != "" {
		append(argv, "--resume", d.req.resume)
	}
	d.ready = true
	for &p in d.prompts {
		claude_write_prompt(b, &p)
		p.sent = true
	}
}

@(private)
claude_write_prompt :: proc(b: ^[dynamic]u8, p: ^Prompt) {
	notes := make([dynamic]string, context.temp_allocator)
	for f in p.files {
		if !(is_image(f) && len(f.data) > 0) && !is_pdf(f) && !(is_text(f) && len(f.data) > 0) {
			append(&notes, attachment_note(f, false))
		}
	}
	append(b, '{')
	f_str(b, "type", "user")
	f_str(b, "uuid", p.id)
	f_str(b, "session_id", "")
	f_raw(b, "parent_tool_use_id", "null")
	f_obj(b, "message")
	f_str(b, "role", "user")
	f_arr(b, "content")
	for f in p.files {
		switch {
		case is_image(f) && len(f.data) > 0:
			open(b)
			f_str(b, "type", "image")
			f_obj(b, "source")
			f_str(b, "type", "base64")
			f_str(b, "media_type", f.mime)
			f_str(b, "data", b64(f.data))
			append(b, "}}")
		case is_pdf(f):
			open(b)
			f_str(b, "type", "document")
			f_obj(b, "source")
			f_str(b, "type", "base64")
			f_str(b, "media_type", "application/pdf")
			f_str(b, "data", b64(f.data))
			close_obj(b)
			f_str(b, "title", file_name(f))
			close_obj(b)
		case is_text(f) && len(f.data) > 0:
			open(b)
			f_str(b, "type", "document")
			f_obj(b, "source")
			f_str(b, "type", "text")
			f_str(b, "media_type", "text/plain")
			f_str(b, "data", string(f.data))
			close_obj(b)
			f_str(b, "title", file_name(f))
			close_obj(b)
		}
	}
	open(b)
	f_str(b, "type", "text")
	f_str(b, "text", with_notes(p.text, notes[:]))
	close_obj(b)
	append(b, "]}}\n")
}

@(private)
claude_control :: proc(d: ^Driver, b: ^[dynamic]u8, kind: Request, subtype: string, ref := "") -> i64 {
	id := request(d, kind, ref)
	append(b, `{"type":"control_request","request_id":"ondb-`)
	w_int(b, id)
	append(b, `","request":{`)
	f_str(b, "subtype", subtype)
	return id
}

@(private)
claude_submit :: proc(d: ^Driver, p: ^Prompt, o: ^Output) {
	claude_write_prompt(&o.bytes, p)
	p.sent = true
	wrote(o, p.id)
}

@(private)
claude_interrupt :: proc(d: ^Driver, o: ^Output) {
	if !d.running {
		return
	}
	d.interrupted = true
	for p in d.prompts {
		claude_cancel_queued(d, &o.bytes, p.id)
	}
	claude_control(d, &o.bytes, .Interrupt, "interrupt")
	append(&o.bytes, "}}\n")
}

@(private)
claude_cancel_queued :: proc(d: ^Driver, b: ^[dynamic]u8, uuid: string) {
	for p in d.pending {
		if p.kind == .Cancel_Queued && p.ref == uuid {
			return
		}
	}
	claude_control(d, b, .Cancel_Queued, "cancel_async_message", uuid)
	f_str(b, "message_uuid", uuid)
	append(b, "}}\n")
}

@(private)
claude_rewind :: proc(d: ^Driver, o: ^Output) {
	if d.req.rewind.after == "" {
		set(d, &d.req.resume, "")
	}
	o.restart = true
}

@(private)
claude_list_models :: proc(d: ^Driver, o: ^Output) {
	claude_control(d, &o.bytes, .Models, "list_models")
	append(&o.bytes, "}}\n")
}

@(private)
claude_answer :: proc(d: ^Driver, p: ^Perm, decision: Decision, o: ^Output) {
	claude_permission_reply(&o.bytes, p.raw_id, p.extra, decision)
}

@(private)
claude_permission_reply :: proc(b: ^[dynamic]u8, request_id, input: string, decision: Decision) {
	append(b, '{')
	f_str(b, "type", "control_response")
	f_obj(b, "response")
	f_str(b, "subtype", "success")
	f_str(b, "request_id", request_id)
	f_obj(b, "response")
	if decision == .Deny {
		f_str(b, "behavior", "deny")
		f_str(b, "message", "The user denied this action.")
	} else {
		f_str(b, "behavior", "allow")
		f_raw(b, "updatedInput", input != "" ? input : "{}")
	}
	append(b, "}}}\n")
}

@(private)
claude_feed :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	switch get_str(v, "type") {
	case "system":
		claude_system(d, v, o)
	case "command_lifecycle":
		if get_str(v, "state") == "started" && !d.running {
			start_turn(d, o, get_str(v, "command_uuid"))
		}
	case "stream_event":
		if !is_null(get(v, "parent_tool_use_id")) {
			return
		}
		claude_stream(d, get(v, "event"), o)
	case "assistant":
		parent := get_str(v, "parent_tool_use_id")
		if !d.running {
			start_turn(d, o, "")
		}
		if u := get_str(v, "uuid"); u != "" && parent == "" {
			set(d, &d.checkpoint, u)
		}
		if parent == "" && get_str(v, "error") == "authentication_failed" {
			d.auth_failed = true
		}
		for c in get_arr(get(v, "message"), "content") {
			if get_str(c, "type") == "tool_use" {
				emit(
					o,
					Tool_Started {
						id = dup(o, get_str(c, "id")),
						name = dup(o, get_str(c, "name")),
						input = dup(o, to_json(get(c, "input"))),
						parent = dup(o, parent),
					},
				)
				if path := claude_write_path(c); path != "" {
					emit(o, File_Write_Begin{tool = dup(o, get_str(c, "id")), path = dup(o, path)})
				}
			}
		}
	case "user":
		parent := get_str(v, "parent_tool_use_id")
		u := get_str(v, "uuid")
		if u != "" && parent == "" {
			set(d, &d.checkpoint, u)
		}
		if get_bool(v, "isReplay") && parent == "" {
			if !d.running {
				start_turn(d, o, u)
			}
			accept_prompt(d, o, u, u)
			return
		}
		based := false
		for c in get_arr(get(v, "message"), "content") {
			if get_str(c, "type") == "tool_result" {
				if !based {
					based = true
					claude_file_base(get_str(c, "tool_use_id"), get(v, "tool_use_result"), o)
				}
				emit(
					o,
					Tool_Finished {
						id = dup(o, get_str(c, "tool_use_id")),
						output = dup(o, text_of(get(c, "content"))),
						is_error = get_bool(c, "is_error"),
						parent = dup(o, parent),
					},
				)
			}
		}
	case "result":
		claude_result(d, v, o)
	case "control_request":
		claude_control_request(d, v, o)
	case "control_response":
		claude_control_response(d, get(v, "response"), o)
	case "rate_limit_event":
		info := get(v, "rate_limit_info")
		if s := get_str(info, "status"); s != "" && s != "allowed" {
			notice(o, .Warning, strings.concatenate({"rate limit: ", s}, context.temp_allocator))
		}
	}
}

@(private)
is_null :: proc(v: json.Value) -> bool {
	#partial switch _ in v {
	case nil, json.Null:
		return true
	}
	return false
}

@(private)
claude_system :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	switch get_str(v, "subtype") {
	case "init":
		open_session(d, o, get_str(v, "session_id"))
	case "api_retry":
		msg := get_str(v, "error")
		if msg == "" {
			msg = "retrying the model request"
		}
		notice(o, .Warning, msg)
	case "compact_boundary":
		notice(o, .Info, "conversation compacted")
	}
}

@(private)
claude_stream :: proc(d: ^Driver, e: json.Value, o: ^Output) {
	switch get_str(e, "type") {
	case "message_start":
		if !d.running {
			start_turn(d, o, "")
		}
		emit(o, Message_Started{native_id = dup(o, get_str(get(e, "message"), "id"))})
	case "content_block_delta":
		delta := get(e, "delta")
		switch get_str(delta, "type") {
		case "text_delta":
			if t := get_str(delta, "text"); t != "" {
				emit(o, Text_Delta{text = dup(o, t)})
			}
		case "thinking_delta":
			if t := get_str(delta, "thinking"); t != "" {
				emit(o, Reasoning_Delta{text = dup(o, t)})
			}
		}
	}
}

@(private)
claude_result :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	if !d.running {
		start_turn(d, o, "")
	}
	u := get(v, "usage")
	if is_object(u) {
		add_usage(
			d,
			Usage {
				input_tokens = get_u64(u, "input_tokens"),
				output_tokens = get_u64(u, "output_tokens"),
				cache_read_tokens = get_u64(u, "cache_read_input_tokens"),
				cache_write_tokens = get_u64(u, "cache_creation_input_tokens"),
				cost_usd = num(get(v, "total_cost_usd")),
			},
		)
	}
	subtype := get_str(v, "subtype")
	if subtype == "success" && !get_bool(v, "is_error") {
		finish_turn(d, o, .Done)
		return
	}
	if strings.has_prefix(get_str(v, "terminal_reason"), "aborted") || d.interrupted {
		finish_turn(d, o, .Interrupted)
		return
	}
	msg := get_str(v, "result")
	if msg == "" {
		msg = text_of(get(v, "errors"))
	}
	if msg == "" {
		msg = subtype != "" ? subtype : "the turn failed"
	}
	fail_turn(d, o, msg)
}

@(private)
claude_control_request :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	rid := get_str(v, "request_id")
	r := get(v, "request")
	if get_str(r, "subtype") != "can_use_tool" {
		b := &o.bytes
		append(b, '{')
		f_str(b, "type", "control_response")
		f_obj(b, "response")
		f_str(b, "subtype", "error")
		f_str(b, "request_id", rid)
		f_str(b, "error", "not supported by this client")
		append(b, "}}\n")
		return
	}
	tool := get_str(r, "tool_name")
	title := get_str(r, "description")
	if title == "" {
		title = get_str(r, "display_name")
	}
	input := to_json(get(r, "input"))
	if !d.req.ask_permissions {
		claude_permission_reply(&o.bytes, rid, input, auto_decision(d.req.access, false))
		emit(o, Permission_Request{id = dup(o, rid), tool = dup(o, tool), title = dup(o, title), input = dup(o, input), answered = true})
		return
	}
	append(&d.perms, Perm{id = own(d, rid), raw_id = own(d, rid), kind = own(d, "can_use_tool"), extra = own(d, input)})
	emit(o, Permission_Request{id = dup(o, rid), tool = dup(o, tool), title = dup(o, title), input = dup(o, input)})
}

@(private)
claude_control_response :: proc(d: ^Driver, r: json.Value, o: ^Output) {
	rid := get_str(r, "request_id")
	if !strings.has_prefix(rid, "ondb-") {
		return
	}
	n, ok := strconv.parse_i64(rid[5:])
	if !ok {
		return
	}
	p, found := take_pending(d, n)
	if !found {
		return
	}
	defer delete(p.ref, d.allocator)
	if get_str(r, "subtype") == "error" {
		if p.kind != .Cancel_Queued {
			notice(o, .Warning, get_str(r, "error"))
		}
		return
	}
	body := get(r, "response")
	#partial switch p.kind {
	case .Interrupt:
		for q in get_arr(body, "still_queued") {
			if uuid := str(q); uuid != "" {
				claude_cancel_queued(d, &o.bytes, uuid)
			}
		}
	case .Cancel_Queued:
		if get_bool(body, "cancelled") {
			drop_prompt(d, o, p.ref)
		}
	case .Models:
		list := make([dynamic]Model, context.temp_allocator)
		for m in get_arr(body, "models") {
			id := get_str(m, "value")
			if id == "" {
				continue
			}
			name := get_str(m, "displayName")
			append(&list, Model{id = id, name = name != "" ? name : id, is_default = id == "default"})
		}
		emit_models(o, list[:])
	}
}

@(private)
claude_mcp_config :: proc(d: ^Driver) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, '{')
	f_obj(&b, "mcpServers")
	for m in d.req.mcp {
		f_obj(&b, m.name)
		if m.url != "" {
			f_str(&b, "type", "http")
			f_str(&b, "url", m.url)
			f_kv_object(&b, "headers", m.headers, ':')
		} else {
			f_str(&b, "type", "stdio")
			f_str(&b, "command", m.command)
			f_str_array(&b, "args", m.args)
			f_kv_object(&b, "env", m.env, '=')
		}
		close_obj(&b)
	}
	append(&b, "}}")
	return string(b[:])
}

@(private)
claude_write_path :: proc(c: json.Value) -> string {
	switch get_str(c, "name") {
	case "Edit", "Write", "MultiEdit":
		return get_str(get(c, "input"), "file_path")
	case "NotebookEdit":
		return get_str(get(c, "input"), "notebook_path")
	}
	return ""
}

@(private)
claude_file_base :: proc(tool: string, r: json.Value, o: ^Output) {
	if tool == "" {
		return
	}
	if orig, ok := get(r, "originalFile").(json.String); ok {
		if path := get_str(r, "filePath"); path != "" {
			emit(o, File_Base{tool = dup(o, tool), path = dup(o, path), base = dup(o, string(orig)), kind = .Write})
		}
		return
	}
	f := get(r, "file")
	content, cok := get(f, "content").(json.String)
	path := get_str(f, "filePath")
	if get_str(r, "type") != "text" || !cok || path == "" {
		return
	}
	if get_u64(f, "startLine") > 1 || get_u64(f, "numLines") < get_u64(f, "totalLines") {
		return
	}
	emit(o, File_Base{tool = dup(o, tool), path = dup(o, path), base = dup(o, string(content)), kind = .Read})
}

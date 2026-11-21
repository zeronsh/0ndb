package agent

import "core:encoding/json"
import "core:strings"

@(private)
codex_launch :: proc(d: ^Driver, argv: ^[dynamic]string, b: ^[dynamic]u8) {
	append(argv, program(d, "codex"), "app-server")
	rpc_request(b, request(d, .Initialize), "initialize", false)
	f_obj(b, "clientInfo")
	f_str(b, "name", "ondb")
	f_raw(b, "title", "null")
	f_str(b, "version", "0.1.0")
	close_obj(b)
	f_raw(b, "capabilities", "null")
	rpc_end(b)
	append(b, `{"method":"initialized"}`)
	end_line(b)
	codex_open(d, b)
}

@(private)
codex_config :: proc(d: ^Driver, b: ^[dynamic]u8) {
	if d.req.cwd != "" {
		f_str(b, "cwd", d.req.cwd)
	}
	if d.req.model != "" {
		f_str(b, "model", d.req.model)
	}
	f_str(b, "approvalPolicy", d.req.ask_permissions ? "on-request" : "never")
	switch d.req.access {
	case .Plan:
		f_str(b, "sandbox", "read-only")
	case .Edit:
		f_str(b, "sandbox", "workspace-write")
	case .Full:
		f_str(b, "sandbox", "danger-full-access")
	}
}

@(private)
codex_open :: proc(d: ^Driver, b: ^[dynamic]u8) {
	d.ready = false
	t := d.req.rewind
	switch {
	case t.session != "" && t.after != "":
		rpc_request(b, request(d, .Open), "thread/fork", false)
		f_str(b, "threadId", t.session)
		f_str(b, "lastTurnId", t.after)
		codex_config(d, b)
		f_bool(b, "excludeTurns", true)
	case t.session == "" && d.req.resume != "":
		rpc_request(b, request(d, .Open), "thread/resume", false)
		f_str(b, "threadId", d.req.resume)
		codex_config(d, b)
		f_bool(b, "excludeTurns", true)
	case:
		rpc_request(b, request(d, .Open), "thread/start", false)
		codex_config(d, b)
	}
	rpc_end(b)
}

@(private)
codex_input :: proc(d: ^Driver, b: ^[dynamic]u8, p: ^Prompt) {
	f_str(b, "threadId", d.session)
	f_str(b, "clientUserMessageId", p.id)
	notes := make([dynamic]string, context.temp_allocator)
	for f in p.files {
		if !is_image(f) {
			append(&notes, attachment_note(f, true))
		}
	}
	f_arr(b, "input")
	open(b)
	f_str(b, "type", "text")
	f_str(b, "text", with_notes(p.text, notes[:]))
	f_raw(b, "text_elements", "[]")
	close_obj(b)
	for f in p.files {
		if !is_image(f) {
			continue
		}
		open(b)
		if f.path != "" {
			f_str(b, "type", "localImage")
			f_str(b, "path", f.path)
		} else {
			f_str(b, "type", "image")
			f_str(b, "url", strings.concatenate({"data:", f.mime, ";base64,", b64(f.data)}, context.temp_allocator))
		}
		close_obj(b)
	}
	close_arr(b)
}

@(private)
codex_write_prompt :: proc(d: ^Driver, b: ^[dynamic]u8, p: ^Prompt, force_start := false) {
	p.sent = true
	if p.steer && d.running && d.turn != "" && !force_start {
		rpc_request(b, request(d, .Steer, p.id), "turn/steer", false)
		codex_input(d, b, p)
		f_str(b, "expectedTurnId", d.turn)
		rpc_end(b)
		return
	}
	kind: Request = .Turn
	if p.steer && d.running && !force_start {
		kind = .Steer
	}
	rpc_request(b, request(d, kind, p.id), "turn/start", false)
	codex_input(d, b, p)
	if d.req.effort != "" {
		f_str(b, "effort", d.req.effort)
	}
	rpc_end(b)
}

@(private)
codex_submit :: proc(d: ^Driver, p: ^Prompt, o: ^Output) {
	if d.ready {
		codex_write_prompt(d, &o.bytes, p)
	}
}

@(private)
codex_flush :: proc(d: ^Driver, o: ^Output) {
	for &p in d.prompts {
		if !p.sent {
			codex_write_prompt(d, &o.bytes, &p)
		}
	}
}

@(private)
codex_interrupt :: proc(d: ^Driver, o: ^Output) {
	if !d.running {
		return
	}
	d.interrupted = true
	if d.turn == "" {
		return
	}
	b := &o.bytes
	rpc_request(b, request(d, .Interrupt), "turn/interrupt", false)
	f_str(b, "threadId", d.session)
	f_str(b, "turnId", d.turn)
	rpc_end(b)
}

@(private)
codex_rewind :: proc(d: ^Driver, o: ^Output) {
	codex_open(d, &o.bytes)
}

@(private)
codex_list_models :: proc(d: ^Driver, o: ^Output) {
	b := &o.bytes
	rpc_request(b, request(d, .Models), "model/list", false)
	f_int(b, "limit", 200)
	rpc_end(b)
}

@(private)
codex_answer :: proc(d: ^Driver, p: ^Perm, decision: Decision, o: ^Output) {
	codex_approval_reply(&o.bytes, p.raw_id, p.kind, decision)
}

@(private)
codex_approval_reply :: proc(b: ^[dynamic]u8, raw_id, method: string, decision: Decision) {
	legacy := method == "execCommandApproval" || method == "applyPatchApproval"
	if method == "item/permissions/requestApproval" {
		rpc_error(b, raw_id, -32000, "permission escalation is not granted by this client", false)
		return
	}
	value: string
	switch decision {
	case .Allow:
		value = legacy ? "approved" : "accept"
	case .Allow_Always:
		value = legacy ? "approved_for_session" : "acceptForSession"
	case .Deny:
		value = legacy ? "denied" : "decline"
	}
	r := make([dynamic]u8, context.temp_allocator)
	append(&r, '{')
	f_str(&r, "decision", value)
	close_obj(&r)
	rpc_result(b, raw_id, string(r[:]), false)
}

@(private)
codex_feed :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	method := get_str(v, "method")
	if method == "" {
		codex_response(d, v, o)
		return
	}
	if has(v, "id") {
		codex_server_request(d, v, method, o)
		return
	}
	p := get(v, "params")
	switch method {
	case "turn/started":
		if !d.running {
			start_turn(d, o, "")
		}
		codex_set_turn(d, o, get_str(get(p, "turn"), "id"))
	case "turn/completed":
		codex_turn_completed(d, get(p, "turn"), o)
	case "item/started":
		codex_item_started(d, get(p, "item"), o)
	case "item/completed":
		codex_item_completed(d, get(p, "item"), o)
	case "item/agentMessage/delta":
		text_delta(d, o, get_str(p, "itemId"), get_str(p, "delta"))
	case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
		if t := get_str(p, "delta"); t != "" {
			emit(o, Reasoning_Delta{text = dup(o, t)})
		}
	case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
		if t := get_str(p, "delta"); t != "" {
			emit(o, Tool_Updated{id = dup(o, get_str(p, "itemId")), output = dup(o, t), append = true})
		}
	case "thread/tokenUsage/updated":
		if d.running && get_str(p, "turnId") == d.turn {
			u := get(get(p, "tokenUsage"), "last")
			add_usage(
				d,
				Usage {
					input_tokens = get_u64(u, "inputTokens"),
					output_tokens = get_u64(u, "outputTokens"),
					cache_read_tokens = get_u64(u, "cachedInputTokens"),
					cache_write_tokens = get_u64(u, "cacheWriteInputTokens"),
					reasoning_tokens = get_u64(u, "reasoningOutputTokens"),
				},
			)
		}
	case "error":
		msg := get_str(get(p, "error"), "message")
		if get_bool(p, "willRetry") {
			notice(o, .Warning, msg)
		} else {
			set(d, &d.last_error, msg)
		}
	case "warning", "configWarning", "deprecationNotice", "guardianWarning":
		msg := get_str(p, "message")
		if msg == "" {
			msg = to_json(p)
		}
		notice(o, .Warning, msg)
	case "model/rerouted":
		notice(o, .Info, to_json(p))
	}
}

@(private)
codex_set_turn :: proc(d: ^Driver, o: ^Output, turn: string) {
	if turn == "" || turn == d.turn {
		return
	}
	set(d, &d.turn, turn)
	if d.interrupted {
		b := &o.bytes
		rpc_request(b, request(d, .Interrupt), "turn/interrupt", false)
		f_str(b, "threadId", d.session)
		f_str(b, "turnId", turn)
		rpc_end(b)
	}
}

@(private)
codex_response :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	n, ok := id_int(get(v, "id"))
	if !ok {
		return
	}
	p, found := take_pending(d, n)
	if !found {
		return
	}
	defer delete(p.ref, d.allocator)
	failed := has(v, "error")
	result := get(v, "result")
	#partial switch p.kind {
	case .Initialize:
		if failed {
			emit(o, Session_Failed{message = dup(o, rpc_error_message(v))})
		}
	case .Open:
		if failed {
			if d.rewinding && take_fallback(d) {
				notice(o, .Warning, rpc_error_message(v))
				drop_target(d, &d.req.rewind)
				set(d, &d.req.resume, "")
				codex_open(d, &o.bytes)
			} else if d.rewinding {
				rewind_failed(d, o, rpc_error_message(v))
				codex_flush(d, o)
			} else {
				emit(o, Session_Failed{message = dup(o, rpc_error_message(v))})
			}
			return
		}
		open_session(d, o, get_str(get(result, "thread"), "id"))
		d.ready = true
		codex_flush(d, o)
	case .Turn:
		if failed {
			if i := find_prompt(d, p.ref); i >= 0 {
				remove_prompt(d, i)
			}
			start_turn(d, o, p.ref)
			fail_turn(d, o, rpc_error_message(v))
			return
		}
		start_turn(d, o, p.ref)
		codex_set_turn(d, o, get_str(get(result, "turn"), "id"))
	case .Steer:
		if !failed {
			return
		}
		i := find_prompt(d, p.ref)
		if i < 0 {
			return
		}
		if d.running && d.turn != "" {
			notice(o, .Warning, rpc_error_message(v))
		}
		codex_write_prompt(d, &o.bytes, &d.prompts[i], true)
	case .Models:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
			return
		}
		list := make([dynamic]Model, context.temp_allocator)
		for m in get_arr(result, "data") {
			if get_bool(m, "hidden") {
				continue
			}
			id := get_str(m, "model")
			if id == "" {
				id = get_str(m, "id")
			}
			if id == "" {
				continue
			}
			name := get_str(m, "displayName")
			append(&list, Model{id = id, name = name != "" ? name : id, is_default = get_bool(m, "isDefault")})
		}
		emit_models(o, list[:])
	case .Interrupt:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
		}
	}
}

@(private)
codex_server_request :: proc(d: ^Driver, v: json.Value, method: string, o: ^Output) {
	raw := id_text(get(v, "id"))
	p := get(v, "params")
	switch method {
	case "item/commandExecution/requestApproval", "execCommandApproval", "item/fileChange/requestApproval", "applyPatchApproval", "item/permissions/requestApproval":
		edit := method == "item/fileChange/requestApproval" || method == "applyPatchApproval"
		tool := edit ? "apply_patch" : "shell"
		if method == "item/permissions/requestApproval" {
			tool = "permissions"
		}
		title := get_str(p, "reason")
		input := get_str(p, "command")
		if input == "" {
			input = to_json(p)
		}
		if title == "" {
			title = input
		}
		if !d.req.ask_permissions {
			codex_approval_reply(&o.bytes, raw, method, auto_decision(d.req.access, edit))
			emit(o, Permission_Request{id = dup(o, raw), tool = dup(o, tool), title = dup(o, title), input = dup(o, input), answered = true})
			return
		}
		append(&d.perms, Perm{id = own(d, raw), raw_id = own(d, raw), kind = own(d, method)})
		emit(o, Permission_Request{id = dup(o, raw), tool = dup(o, tool), title = dup(o, title), input = dup(o, input)})
	case:
		rpc_error(&o.bytes, raw, -32601, "not supported by this client", false)
		notice(o, .Info, method)
	}
}

@(private)
codex_tool_name :: proc(item: json.Value) -> string {
	switch get_str(item, "type") {
	case "commandExecution":
		return "shell"
	case "fileChange":
		return "apply_patch"
	case "mcpToolCall":
		return strings.concatenate({get_str(item, "server"), "/", get_str(item, "tool")}, context.temp_allocator)
	case "dynamicToolCall", "collabAgentToolCall":
		return get_str(item, "tool")
	case "webSearch":
		return "web_search"
	case "imageGeneration":
		return "image_generation"
	case "imageView":
		return "view_image"
	}
	return ""
}

@(private)
codex_item_started :: proc(d: ^Driver, item: json.Value, o: ^Output) {
	kind := get_str(item, "type")
	id := get_str(item, "id")
	switch kind {
	case "userMessage":
		if c := get_str(item, "clientId"); c != "" {
			accept_prompt(d, o, c, id)
		}
		return
	case "agentMessage":
		emit(o, Message_Started{native_id = dup(o, id)})
		return
	}
	name := codex_tool_name(item)
	if name == "" {
		return
	}
	input: string
	switch kind {
	case "commandExecution":
		b := make([dynamic]u8, context.temp_allocator)
		append(&b, '{')
		f_str(&b, "command", get_str(item, "command"))
		f_str(&b, "cwd", get_str(item, "cwd"))
		close_obj(&b)
		input = string(b[:])
	case "fileChange":
		input = to_json(get(item, "changes"))
	case "mcpToolCall", "dynamicToolCall":
		input = to_json(get(item, "arguments"))
	case:
		input = to_json(item)
	}
	emit(o, Tool_Started{id = dup(o, id), name = dup(o, name), input = dup(o, input)})
}

@(private)
codex_item_completed :: proc(d: ^Driver, item: json.Value, o: ^Output) {
	kind := get_str(item, "type")
	id := get_str(item, "id")
	status := get_str(item, "status")
	switch kind {
	case "agentMessage":
		if d.stream_item != id {
			text_delta(d, o, id, get_str(item, "text"))
		}
		return
	case "commandExecution":
		failed := status != "completed"
		if code, ok := get(item, "exitCode").(json.Integer); ok && code != 0 {
			failed = true
		}
		emit(o, Tool_Finished{id = dup(o, id), output = dup(o, get_str(item, "aggregatedOutput")), is_error = failed})
		return
	case "fileChange":
		b := make([dynamic]u8, context.temp_allocator)
		for c in get_arr(item, "changes") {
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, get_str(c, "path"))
		}
		emit(o, Tool_Finished{id = dup(o, id), output = dup(o, string(b[:])), is_error = status != "completed"})
		return
	case "mcpToolCall":
		out := text_of(get(get(item, "result"), "content"))
		if e := get(item, "error"); is_object(e) {
			out = get_str(e, "message")
		}
		emit(o, Tool_Finished{id = dup(o, id), output = dup(o, out), is_error = status == "failed"})
		return
	case "dynamicToolCall":
		failed := false
		if s, ok := get(item, "success").(json.Boolean); ok {
			failed = !s
		}
		emit(o, Tool_Finished{id = dup(o, id), output = dup(o, text_of(get(item, "contentItems"))), is_error = failed})
		return
	}
	if codex_tool_name(item) != "" {
		emit(o, Tool_Finished{id = dup(o, id), is_error = status == "failed"})
	}
}

@(private)
codex_turn_completed :: proc(d: ^Driver, turn: json.Value, o: ^Output) {
	if !d.running {
		start_turn(d, o, "")
	}
	if id := get_str(turn, "id"); id != "" {
		set(d, &d.checkpoint, id)
	}
	switch get_str(turn, "status") {
	case "completed":
		finish_turn(d, o, .Done)
	case "interrupted":
		finish_turn(d, o, .Interrupted)
	case:
		msg := get_str(get(turn, "error"), "message")
		if msg == "" {
			msg = d.last_error
		}
		if msg == "" {
			msg = "the turn failed"
		}
		fail_turn(d, o, strings.clone(msg, context.temp_allocator))
	}
	codex_flush(d, o)
}

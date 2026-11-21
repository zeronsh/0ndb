package agent

import "core:encoding/json"
import "core:strconv"
import "core:strings"

@(private)
acp_launch :: proc(d: ^Driver, argv: ^[dynamic]string, b: ^[dynamic]u8) {
	base_argv(d, argv)
	switch d.desc.steer {
	case .Auto, .Cancel:
		d.steer_mode = .Cancel
	case .Concurrent:
		d.steer_mode = .Concurrent
	case .Supersede:
		d.steer_mode = .Supersede
	case .Command:
		d.steer_mode = .Command
	}
	d.has_undo = d.desc.undo
	rpc_request(b, request(d, .Initialize), "initialize")
	f_int(b, "protocolVersion", 1)
	f_obj(b, "clientCapabilities")
	f_obj(b, "fs")
	f_bool(b, "readTextFile", false)
	f_bool(b, "writeTextFile", false)
	close_obj(b)
	f_bool(b, "terminal", false)
	if len(d.desc.client_meta) > 0 {
		f_obj(b, "_meta")
		for k in d.desc.client_meta {
			f_bool(b, k, true)
		}
		close_obj(b)
	}
	close_obj(b)
	f_obj(b, "clientInfo")
	f_str(b, "name", "ondb")
	f_str(b, "version", "0.1.0")
	close_obj(b)
	rpc_end(b)
}

@(private)
acp_session_params :: proc(d: ^Driver, b: ^[dynamic]u8) {
	f_str(b, "cwd", d.req.cwd)
	f_raw(b, "mcpServers", "[]")
}

@(private)
acp_open_session :: proc(d: ^Driver, o: ^Output, method, session: string) {
	b := &o.bytes
	d.replaying = method == "session/load" || method == "session/fork" || method == "session/resume"
	rpc_request(b, request(d, .Open, session), method)
	if session != "" {
		f_str(b, "sessionId", session)
	}
	acp_session_params(d, b)
	rpc_end(b)
}

@(private)
acp_seeded :: proc(d: ^Driver, o: ^Output, reason: string) {
	if d.rewinding && take_fallback(d) {
		notice(o, .Info, reason)
		drop_target(d, &d.req.rewind)
		set(d, &d.req.resume, "")
		acp_open_session(d, o, "session/new", "")
		return
	}
	rewind_failed(d, o, reason)
	acp_flush(d, o)
}

@(private)
acp_open :: proc(d: ^Driver, o: ^Output) {
	d.ready = false
	t := d.req.rewind
	if t.session == "" {
		switch {
		case d.req.resume != "" && d.can_resume:
			acp_open_session(d, o, "session/resume", d.req.resume)
		case d.req.resume != "" && d.can_load:
			acp_open_session(d, o, "session/load", d.req.resume)
		case:
			if d.req.resume != "" {
				notice(o, .Warning, "this agent cannot resume sessions; starting a new one")
			}
			acp_open_session(d, o, "session/new", "")
		}
		return
	}
	if t.after == "" {
		d.turns = 0
		set(d, &d.checkpoint, "")
		acp_open_session(d, o, "session/new", "")
		return
	}
	head := checkpoint_turns(t.head)
	after := checkpoint_turns(t.after)
	at_end := t.head == t.after || (t.head == "" && t.before == "")
	switch {
	case at_end && d.can_fork:
		d.turns = after
		acp_open_session(d, o, "session/fork", t.session)
	case at_end && t.session != d.session && (d.can_resume || d.can_load):
		d.turns = after
		acp_open_session(d, o, d.can_resume ? "session/resume" : "session/load", t.session)
	case at_end && t.session == d.session:
		open_session(d, o, d.session)
		d.ready = true
		acp_flush(d, o)
	case d.has_undo && d.can_fork && t.head != "" && head > after:
		d.undo = head - after
		d.turns = after
		d.rewind_path = .Native_Undo
		acp_open_session(d, o, "session/fork", t.session)
	case d.can_revert && t.before != "":
		b := &o.bytes
		rpc_request(b, request(d, .Revert_Steps, t.before), "_cognition.ai/revert/listSteps")
		f_str(b, "sessionId", t.session)
		rpc_end(b)
	case:
		acp_seeded(d, o, "this agent cannot rewind to that message natively; continuing in a new session seeded with the transcript")
	}
}

@(private)
acp_write_prompt :: proc(d: ^Driver, b: ^[dynamic]u8, kind: Request, id, text: string, files: []Attachment) {
	notes := make([dynamic]string, context.temp_allocator)
	for f in files {
		switch {
		case is_image(f) && len(f.data) > 0 && d.can_image:
		case len(f.data) > 0 && d.can_embed:
		case f.path != "":
		case:
			append(&notes, attachment_note(f, true))
		}
	}
	rpc_request(b, request(d, kind, id), "session/prompt")
	f_str(b, "sessionId", d.session)
	f_str(b, "messageId", id)
	f_arr(b, "prompt")
	open(b)
	f_str(b, "type", "text")
	f_str(b, "text", with_notes(text, notes[:]))
	close_obj(b)
	for f in files {
		switch {
		case is_image(f) && len(f.data) > 0 && d.can_image:
			open(b)
			f_str(b, "type", "image")
			f_str(b, "mimeType", f.mime)
			f_str(b, "data", b64(f.data))
			if f.path != "" {
				f_str(b, "uri", file_uri(f.path))
			}
			close_obj(b)
		case len(f.data) > 0 && d.can_embed:
			open(b)
			f_str(b, "type", "resource")
			f_obj(b, "resource")
			f_str(b, "uri", f.path != "" ? file_uri(f.path) : strings.concatenate({"attachment:", file_name(f)}, context.temp_allocator))
			f_str(b, "mimeType", mime_or(f))
			if is_text(f) {
				f_str(b, "text", string(f.data))
			} else {
				f_str(b, "blob", b64(f.data))
			}
			append(b, "}}")
		case f.path != "":
			open(b)
			f_str(b, "type", "resource_link")
			f_str(b, "uri", file_uri(f.path))
			f_str(b, "name", file_name(f))
			if f.mime != "" {
				f_str(b, "mimeType", f.mime)
			}
			close_obj(b)
		}
	}
	close_arr(b)
	rpc_end(b)
}

@(private)
acp_start :: proc(d: ^Driver, o: ^Output, i: int) {
	id := strings.clone(d.prompts[i].id, context.temp_allocator)
	start_turn(d, o, id)
	d.in_flight += 1
	acp_write_prompt(d, &o.bytes, .Turn, id, d.prompts[i].text, d.prompts[i].files)
	accept_prompt(d, o, id, id)
}

@(private)
acp_submit :: proc(d: ^Driver, p: ^Prompt, o: ^Output) {
	i := len(d.prompts) - 1
	if !d.ready || (d.running && !p.steer) {
		return
	}
	if !d.running {
		acp_start(d, o, i)
		return
	}
	id := strings.clone(p.id, context.temp_allocator)
	switch d.steer_mode {
	case .Concurrent, .Supersede:
		d.in_flight += 1
		acp_write_prompt(d, &o.bytes, .Steer, id, p.text, p.files)
		accept_prompt(d, o, id, id)
	case .Command:
		line := strings.concatenate({"/steer ", p.text}, context.temp_allocator)
		acp_write_prompt(d, &o.bytes, .Steer_Command, id, line, p.files)
		p.sent = true
	case .Cancel:
		waiting := false
		for q, j in d.prompts {
			if j != i && q.steer && !q.sent {
				waiting = true
			}
		}
		if !waiting {
			rpc_notify(&o.bytes, "session/cancel")
			f_str(&o.bytes, "sessionId", d.session)
			rpc_end(&o.bytes)
		}
	}
}

@(private)
acp_resteer :: proc(d: ^Driver, o: ^Output) -> bool {
	b := make([dynamic]u8, context.temp_allocator)
	ids := make([dynamic]string, context.temp_allocator)
	files := make([dynamic]Attachment, context.temp_allocator)
	for p in d.prompts {
		if p.steer && !p.sent {
			if len(b) > 0 {
				append(&b, "\n\n")
			}
			append(&b, p.text)
			append(&ids, strings.clone(p.id, context.temp_allocator))
			append(&files, ..p.files)
		}
	}
	if len(ids) == 0 {
		return false
	}
	d.in_flight += 1
	acp_write_prompt(d, &o.bytes, .Steer, ids[0], string(b[:]), files[:])
	for id in ids {
		accept_prompt(d, o, id, ids[0])
	}
	return true
}

@(private)
acp_flush :: proc(d: ^Driver, o: ^Output) {
	if !d.ready {
		return
	}
	for len(d.prompts) > 0 && !d.running {
		if d.prompts[0].sent {
			return
		}
		acp_start(d, o, 0)
	}
}

@(private)
acp_interrupt :: proc(d: ^Driver, o: ^Output) {
	if !d.running {
		return
	}
	d.interrupted = true
	for i := len(d.prompts) - 1; i >= 0; i -= 1 {
		if d.prompts[i].steer && !d.prompts[i].sent {
			drop_prompt(d, o, strings.clone(d.prompts[i].id, context.temp_allocator))
		}
	}
	rpc_notify(&o.bytes, "session/cancel")
	f_str(&o.bytes, "sessionId", d.session)
	rpc_end(&o.bytes)
}

@(private)
acp_rewind :: proc(d: ^Driver, o: ^Output) {
	acp_open(d, o)
}

@(private)
acp_list_models :: proc(d: ^Driver, o: ^Output) {
	if len(d.models) > 0 {
		emit_models(o, d.models[:])
	} else if !d.ready {
		notice(o, .Info, "models are listed when the session opens")
	} else {
		emit_models(o, nil)
	}
}

@(private)
acp_close :: proc(d: ^Driver, o: ^Output) {
	if d.can_close && d.session != "" {
		rpc_request(&o.bytes, request(d, .Other), "session/close")
		f_str(&o.bytes, "sessionId", d.session)
		rpc_end(&o.bytes)
	}
}

@(private)
acp_answer :: proc(d: ^Driver, p: ^Perm, decision: Decision, o: ^Output) {
	option: string
	switch decision {
	case .Allow:
		option = p.allow != "" ? p.allow : p.allow_always
	case .Allow_Always:
		option = p.allow_always != "" ? p.allow_always : p.allow
	case .Deny:
		option = p.deny
	}
	acp_permission_reply(&o.bytes, p.raw_id, option)
}

@(private)
acp_permission_reply :: proc(b: ^[dynamic]u8, raw_id, option: string) {
	r := make([dynamic]u8, context.temp_allocator)
	append(&r, '{')
	f_obj(&r, "outcome")
	if option != "" {
		f_str(&r, "outcome", "selected")
		f_str(&r, "optionId", option)
	} else {
		f_str(&r, "outcome", "cancelled")
	}
	append(&r, "}}")
	rpc_result(b, raw_id, string(r[:]))
}

@(private)
acp_feed :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	method := get_str(v, "method")
	if method == "" {
		acp_response(d, v, o)
		return
	}
	p := get(v, "params")
	if has(v, "id") {
		raw := id_text(get(v, "id"))
		if method == "session/request_permission" {
			acp_permission(d, raw, p, o)
		} else {
			rpc_error(&o.bytes, raw, -32601, "not supported by this client")
		}
		return
	}
	if method != "session/update" || d.replaying {
		return
	}
	if sid := get_str(p, "sessionId"); sid != "" && sid != d.session {
		return
	}
	acp_update(d, get(p, "update"), o)
}

@(private)
acp_permission :: proc(d: ^Driver, raw: string, p: json.Value, o: ^Output) {
	call := get(p, "toolCall")
	allow, always, deny: string
	for opt in get_arr(p, "options") {
		id := get_str(opt, "optionId")
		switch get_str(opt, "kind") {
		case "allow_once":
			allow = id
		case "allow_always":
			always = id
		case "reject_once":
			deny = id
		case "reject_always":
			if deny == "" {
				deny = id
			}
		}
	}
	tool := get_str(call, "kind")
	title := get_str(call, "title")
	input := to_json(get(call, "rawInput"))
	if !d.req.ask_permissions {
		decision: Decision = .Deny
		switch d.req.access {
		case .Full:
			decision = .Allow
		case .Edit:
			switch tool {
			case "read", "edit", "delete", "move", "search", "think":
				decision = .Allow
			}
		case .Plan:
			switch tool {
			case "read", "search", "think":
				decision = .Allow
			}
		}
		option := deny
		if decision == .Allow {
			option = allow != "" ? allow : always
		}
		acp_permission_reply(&o.bytes, raw, option)
		emit(o, Permission_Request{id = dup(o, raw), tool = dup(o, tool), title = dup(o, title), input = dup(o, input), answered = true})
		return
	}
	append(&d.perms, Perm{id = own(d, raw), raw_id = own(d, raw), allow = own(d, allow), allow_always = own(d, always), deny = own(d, deny)})
	emit(o, Permission_Request{id = dup(o, raw), tool = dup(o, tool), title = dup(o, title), input = dup(o, input)})
}

@(private)
acp_tool_output :: proc(u: json.Value) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	for c in get_arr(u, "content") {
		part: string
		switch get_str(c, "type") {
		case "content":
			part = text_of(get(c, "content"))
		case "diff":
			part = strings.concatenate({"edited ", get_str(c, "path")}, context.temp_allocator)
		case "terminal":
			part = strings.concatenate({"terminal ", get_str(c, "terminalId")}, context.temp_allocator)
		}
		if part == "" {
			continue
		}
		if len(b) > 0 {
			append(&b, '\n')
		}
		append(&b, part)
	}
	if len(b) == 0 {
		raw := get(u, "rawOutput")
		if out := get_str(raw, "output"); out != "" {
			return out
		}
		if !is_null(raw) {
			return text_of(raw)
		}
	}
	return string(b[:])
}

@(private)
acp_update :: proc(d: ^Driver, u: json.Value, o: ^Output) {
	switch get_str(u, "sessionUpdate") {
	case "agent_message_chunk":
		c := get(u, "content")
		if get_str(c, "type") != "text" {
			return
		}
		mid := get_str(u, "messageId")
		if mid == "" && (pending_kind(d, .Steer_Command) || pending_kind(d, .Undo)) {
			notice(o, .Info, get_str(c, "text"))
			return
		}
		if mid != "" && mid != d.stream_item {
			emit(o, Message_Started{native_id = dup(o, mid)})
		}
		text_delta(d, o, mid, get_str(c, "text"))
	case "agent_thought_chunk":
		c := get(u, "content")
		if t := get_str(c, "text"); t != "" {
			emit(o, Reasoning_Delta{text = dup(o, t)})
		}
	case "tool_call":
		id := get_str(u, "toolCallId")
		name := get_str(u, "title")
		if name == "" {
			name = get_str(u, "kind")
		}
		input: string
		if raw := get(u, "rawInput"); !is_null(raw) {
			input = to_json(raw)
		} else {
			b := make([dynamic]u8, context.temp_allocator)
			append(&b, '{')
			f_str(&b, "title", get_str(u, "title"))
			if c := acp_tool_output(u); c != "" {
				f_str(&b, "content", c)
			}
			close_obj(&b)
			input = string(b[:])
		}
		emit(o, Tool_Started{id = dup(o, id), name = dup(o, name), input = dup(o, input)})
		acp_tool_status(u, id, o)
	case "tool_call_update":
		id := get_str(u, "toolCallId")
		status := get_str(u, "status")
		if status == "completed" || status == "failed" {
			acp_tool_status(u, id, o)
			return
		}
		upd := Tool_Updated {
			id = dup(o, id),
		}
		if raw := get(u, "rawInput"); !is_null(raw) {
			upd.input = dup(o, to_json(raw))
		}
		if has(u, "content") {
			upd.output = dup(o, acp_tool_output(u))
		}
		if upd.input != "" || upd.output != "" {
			emit(o, upd)
		}
	case "available_commands_update":
		for c in get_arr(u, "availableCommands") {
			switch get_str(c, "name") {
			case "steer":
				if d.steer_mode == .Cancel {
					d.steer_mode = .Command
				}
			case "undo":
				d.has_undo = true
			}
		}
	case "usage_update":
		cost := get(u, "cost")
		if c := get(cost, "amount"); !is_null(c) {
			cur := get_str(cost, "currency")
			if cur == "" || cur == "USD" {
				d.cost_seen = num(c)
			}
		}
		if size := get_u64(u, "size"); size > 0 {
			add_usage(d, Usage{context_tokens = get_u64(u, "used"), context_window = size})
		}
	}
}

@(private)
acp_tool_status :: proc(u: json.Value, id: string, o: ^Output) {
	status := get_str(u, "status")
	if status == "completed" || status == "failed" {
		emit(o, Tool_Finished{id = dup(o, id), output = dup(o, acp_tool_output(u)), is_error = status == "failed"})
	}
}

@(private)
acp_session_opened :: proc(d: ^Driver, p: Pending, result: json.Value, o: ^Output) {
	sid := get_str(result, "sessionId")
	if sid == "" {
		sid = p.ref
	}
	if sid == "" {
		emit(o, Session_Failed{message = dup(o, "the agent returned no session id")})
		return
	}
	open_session(d, o, sid)
	acp_configure(d, result, o)
	if d.undo > 0 {
		buf: [32]u8
		line := strings.concatenate({"/undo ", strconv.write_int(buf[:], i64(d.undo), 10)}, context.temp_allocator)
		acp_write_prompt(d, &o.bytes, .Undo, new_uuid(), line, nil)
		return
	}
	if !pending_kind(d, .Configure) {
		d.ready = true
		acp_flush(d, o)
	}
}

@(private)
acp_ready_check :: proc(d: ^Driver, o: ^Output) {
	if !d.ready && d.session != "" && !pending_kind(d, .Configure) && !pending_kind(d, .Open) && !pending_kind(d, .Undo) {
		d.ready = true
		acp_flush(d, o)
	}
}

@(private)
acp_configure :: proc(d: ^Driver, result: json.Value, o: ^Output) {
	list := make([dynamic]Model, context.temp_allocator)
	model_config := ""
	current := ""
	plan_config := ""
	effort_config := ""
	for opt in get_arr(result, "configOptions") {
		id := get_str(opt, "id")
		cat := get_str(opt, "category")
		switch {
		case cat == "model" || id == "model":
			if model_config != "" {
				continue
			}
			model_config = id
			current = get_str(opt, "currentValue")
			for c in get_arr(opt, "options") {
				val := get_str(c, "value")
				if val == "" {
					continue
				}
				name := get_str(c, "name")
				append(&list, Model{id = val, name = name != "" ? name : val, is_default = val == current})
			}
		case cat == "mode":
			for c in get_arr(opt, "options") {
				if get_str(c, "value") == "plan" {
					plan_config = id
				}
			}
		case cat == "thought_level" || cat == "effort":
			for c in get_arr(opt, "options") {
				if d.req.effort != "" && get_str(c, "value") == d.req.effort {
					effort_config = id
				}
			}
		}
	}
	use_set_model := false
	if model_config == "" {
		m := get(result, "models")
		current = get_str(m, "currentModelId")
		for e in get_arr(m, "availableModels") {
			id := get_str(e, "modelId")
			if id == "" {
				continue
			}
			name := get_str(e, "name")
			append(&list, Model{id = id, name = name != "" ? name : id, is_default = id == current})
			use_set_model = true
		}
	}
	if len(list) > 0 {
		store_models(d, list[:])
		emit_models(o, list[:])
	}
	b := &o.bytes
	if d.req.model != "" && d.req.model != current {
		if model_config != "" {
			rpc_request(b, request(d, .Configure), "session/set_config_option")
			f_str(b, "sessionId", d.session)
			f_str(b, "configId", model_config)
			f_str(b, "value", d.req.model)
			rpc_end(b)
		} else if use_set_model {
			rpc_request(b, request(d, .Configure), "session/set_model")
			f_str(b, "sessionId", d.session)
			f_str(b, "modelId", d.req.model)
			rpc_end(b)
		}
	}
	if effort_config != "" {
		rpc_request(b, request(d, .Configure), "session/set_config_option")
		f_str(b, "sessionId", d.session)
		f_str(b, "configId", effort_config)
		f_str(b, "value", d.req.effort)
		rpc_end(b)
	}
	if d.req.access == .Plan {
		if plan_config != "" {
			rpc_request(b, request(d, .Configure), "session/set_config_option")
			f_str(b, "sessionId", d.session)
			f_str(b, "configId", plan_config)
			f_str(b, "value", "plan")
			rpc_end(b)
		} else {
			for m in get_arr(get(result, "modes"), "availableModes") {
				if get_str(m, "id") == "plan" {
					rpc_request(b, request(d, .Configure), "session/set_mode")
					f_str(b, "sessionId", d.session)
					f_str(b, "modeId", "plan")
					rpc_end(b)
					break
				}
			}
		}
	}
}

@(private)
acp_response :: proc(d: ^Driver, v: json.Value, o: ^Output) {
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
			return
		}
		caps := get(result, "agentCapabilities")
		sc := get(caps, "sessionCapabilities")
		d.can_load = get_bool(caps, "loadSession")
		d.can_resume = has(sc, "resume")
		d.can_fork = has(sc, "fork")
		d.can_close = has(sc, "close")
		pc := get(caps, "promptCapabilities")
		d.can_image = get_bool(pc, "image")
		d.can_embed = get_bool(pc, "embeddedContext")
		meta := get(caps, "_meta")
		if get_bool(meta, "cognition.ai/midTurnPrompts") {
			d.steer_mode = .Concurrent
		}
		d.can_revert = get_bool(meta, "cognition.ai/revert")
		acp_open(d, o)
	case .Open:
		d.replaying = false
		if failed {
			msg := rpc_error_message(v)
			if d.rewinding {
				d.undo = 0
				acp_seeded(d, o, msg)
			} else {
				emit(o, Session_Failed{message = dup(o, msg)})
			}
			return
		}
		acp_session_opened(d, p, result, o)
	case .Configure:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
		}
		acp_ready_check(d, o)
	case .Undo:
		d.undo = 0
		if failed || get_str(result, "stopReason") == "refusal" {
			acp_seeded(d, o, failed ? rpc_error_message(v) : "undo was refused")
			return
		}
		buf: [32]u8
		set(d, &d.checkpoint, strconv.write_int(buf[:], i64(d.turns), 10))
		finish_rewind(d, o)
		acp_ready_check(d, o)
	case .Revert_Steps:
		step := ""
		for st in get_arr(result, "steps") {
			if get_str(st, "userMessageId") == p.ref || get_str(st, "stepId") == p.ref {
				step = get_str(st, "stepId")
			}
		}
		if failed || step == "" {
			acp_seeded(d, o, failed ? rpc_error_message(v) : "the message is not a revert step of this session")
			return
		}
		b := &o.bytes
		rpc_request(b, request(d, .Revert_Fork), "_cognition.ai/revert/forkFromStep")
		f_str(b, "sessionId", d.req.rewind.session)
		f_str(b, "stepId", step)
		rpc_end(b)
	case .Revert_Fork:
		sid := ""
		for k in ([]string{"sessionId", "forkedSessionId", "newSessionId", "targetSessionId"}) {
			if sid == "" {
				sid = get_str(result, k)
			}
		}
		if failed || sid == "" {
			acp_seeded(d, o, failed ? rpc_error_message(v) : "the fork returned no session")
			return
		}
		d.turns = 0
		acp_open_session(d, o, d.can_resume ? "session/resume" : "session/load", sid)
	case .Other:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
		}
	case .Steer_Command:
		if failed {
			drop_prompt(d, o, p.ref)
			notice(o, .Warning, rpc_error_message(v))
			return
		}
		accept_prompt(d, o, p.ref, p.ref)
	case .Turn, .Steer:
		acp_prompt_done(d, p, v, o)
	}
}

@(private)
acp_prompt_done :: proc(d: ^Driver, p: Pending, v: json.Value, o: ^Output) {
	d.in_flight = max(d.in_flight - 1, 0)
	result := get(v, "result")
	if u := get(result, "usage"); is_object(u) {
		add_usage(
			d,
			Usage {
				input_tokens = get_u64(u, "inputTokens"),
				output_tokens = get_u64(u, "outputTokens"),
				cache_read_tokens = get_u64(u, "cachedReadTokens"),
				cache_write_tokens = get_u64(u, "cachedWriteTokens"),
				reasoning_tokens = get_u64(u, "thoughtTokens"),
			},
		)
	}
	failed := has(v, "error")
	if failed && p.kind == .Steer {
		emit(o, Prompt_Dropped{id = dup(o, p.ref)})
		notice(o, .Warning, rpc_error_message(v))
	}
	if !failed {
		d.turns += 1
	}
	if d.in_flight > 0 {
		return
	}
	if !d.interrupted && acp_resteer(d, o) {
		return
	}
	if spent := d.cost_seen - d.cost_base; spent > 0 {
		add_usage(d, Usage{cost_usd = spent})
	}
	buf: [32]u8
	set(d, &d.checkpoint, strconv.write_int(buf[:], i64(d.turns), 10))
	reason := get_str(result, "stopReason")
	switch {
	case failed && p.kind == .Turn:
		fail_turn(d, o, rpc_error_message(v))
	case reason == "cancelled":
		finish_turn(d, o, .Interrupted)
	case reason == "refusal":
		fail_turn(d, o, "the model refused")
	case:
		if reason == "max_tokens" || reason == "max_turn_requests" {
			notice(o, .Warning, reason)
		}
		finish_turn(d, o, .Done)
	}
	acp_flush(d, o)
}

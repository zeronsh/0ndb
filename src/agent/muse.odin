package agent

import "core:encoding/json"
import "core:strings"

@(private)
muse_launch :: proc(d: ^Driver, argv: ^[dynamic]string, b: ^[dynamic]u8) {
	append(argv, program(d, "muse"), "serve")
	rpc_request(b, request(d, .Initialize), "initialize")
	f_obj(b, "clientInfo")
	f_str(b, "name", "ondb")
	f_str(b, "version", "0.1.0")
	close_obj(b)
	rpc_end(b)
	append(b, `{"jsonrpc":"2.0","method":"initialized"}`)
	end_line(b)
	muse_open(d, b)
}

@(private)
muse_command :: proc(d: ^Driver, b: ^[dynamic]u8, kind: Request, method: string, ref := "", command := "") {
	rpc_request(b, request(d, kind, ref), method)
	f_str(b, "commandId", command != "" ? command : new_uuid())
}

@(private)
muse_open :: proc(d: ^Driver, b: ^[dynamic]u8) {
	d.ready = false
	t := d.req.rewind
	switch {
	case t.session != "" && t.after != "":
		muse_command(d, b, .Open, "session/fork")
		f_str(b, "sessionId", t.session)
		f_obj(b, "cutPoint")
		f_str(b, "lastTurnId", t.after)
		close_obj(b)
		f_bool(b, "excludeItems", true)
	case t.session == "" && d.req.resume != "":
		muse_command(d, b, .Open, "session/resume")
		f_str(b, "sessionId", d.req.resume)
		f_bool(b, "excludeItems", true)
		if d.req.model != "" {
			f_str(b, "modelId", d.req.model)
		}
	case:
		muse_command(d, b, .Open, "session/start")
		if d.req.cwd != "" {
			f_str(b, "workspaceRoot", d.req.cwd)
		}
		if d.req.model != "" {
			f_str(b, "modelId", d.req.model)
		}
		mode: string
		switch d.req.access {
		case .Full:
			mode = d.req.ask_permissions ? "promptUnmatched" : "allowAll"
		case .Edit:
			mode = "promptUnmatched"
		case .Plan:
			mode = d.req.ask_permissions ? "promptUnmatched" : "denyUnmatched"
		}
		f_str(b, "approvalMode", mode)
	}
	rpc_end(b)
}

@(private)
is_uuid7 :: proc(s: string) -> bool {
	if len(s) != 36 || s[14] != '7' {
		return false
	}
	for c, i in s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !strings.contains_rune("0123456789abcdefABCDEF", c) {
			return false
		}
	}
	return true
}

@(private)
muse_write_prompt :: proc(d: ^Driver, b: ^[dynamic]u8, p: ^Prompt) {
	muse_command(d, b, p.steer ? .Steer : .Turn, "turn/start", p.id, p.cmd)
	f_str(b, "sessionId", d.session)
	notes := make([dynamic]string, context.temp_allocator)
	for f in p.files {
		if !(is_image(f) && len(f.data) > 0) {
			append(&notes, attachment_note(f, true))
		}
	}
	f_arr(b, "input")
	open(b)
	f_str(b, "type", "text")
	f_str(b, "text", with_notes(p.text, notes[:]))
	close_obj(b)
	for f in p.files {
		if is_image(f) && len(f.data) > 0 {
			open(b)
			f_str(b, "type", "image")
			f_str(b, "mediaType", f.mime)
			f_str(b, "base64Data", b64(f.data))
			close_obj(b)
		}
	}
	close_arr(b)
	f_str(b, "ifBusy", p.steer ? "steer" : "queue")
	if d.req.effort != "" {
		f_str(b, "reasoningEffort", d.req.effort)
	}
	rpc_end(b)
	p.sent = true
}

@(private)
muse_submit :: proc(d: ^Driver, p: ^Prompt, o: ^Output) {
	set(d, &p.cmd, is_uuid7(p.id) ? p.id : new_uuid())
	if d.ready {
		muse_write_prompt(d, &o.bytes, p)
	}
}

@(private)
muse_prompt_by_cmd :: proc(d: ^Driver, cmd: string) -> string {
	for p in d.prompts {
		if p.cmd == cmd {
			return strings.clone(p.id, context.temp_allocator)
		}
	}
	return ""
}

@(private)
muse_interrupt :: proc(d: ^Driver, o: ^Output) {
	if !d.running {
		return
	}
	d.interrupted = true
	b := &o.bytes
	muse_command(d, b, .Interrupt, "turn/interrupt")
	f_str(b, "sessionId", d.session)
	if d.turn != "" {
		f_str(b, "turnId", d.turn)
	}
	rpc_end(b)
}

@(private)
muse_rewind :: proc(d: ^Driver, o: ^Output) {
	muse_open(d, &o.bytes)
}

@(private)
muse_list_models :: proc(d: ^Driver, o: ^Output) {
	rpc_request(&o.bytes, request(d, .Models), "model/list")
	rpc_end(&o.bytes)
}

@(private)
muse_answer :: proc(d: ^Driver, p: ^Perm, decision: Decision, o: ^Output) {
	choice: string
	switch decision {
	case .Allow:
		choice = p.allow
	case .Allow_Always:
		choice = p.allow_always != "" ? p.allow_always : p.allow
	case .Deny:
		choice = p.deny
	}
	if choice == "" {
		notice(o, .Warning, "the approval offered no matching choice")
		return
	}
	b := &o.bytes
	muse_command(d, b, .Other, "approval/decide")
	f_str(b, "sessionId", d.session)
	f_str(b, "approvalId", p.raw_id)
	f_raw(b, "requirementId", p.extra)
	f_str(b, "choiceId", choice)
	rpc_end(b)
}

@(private)
muse_feed :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	method := get_str(v, "method")
	if method == "" {
		muse_response(d, v, o)
		return
	}
	p := get(v, "params")
	if has(v, "id") {
		raw := id_text(get(v, "id"))
		if method == "approval/request" || method == "userInput/request" {
			rpc_result(&o.bytes, raw, "{}")
		} else {
			rpc_error(&o.bytes, raw, -32601, "not supported by this client")
		}
	}
	switch method {
	case "turn/started":
		if !d.running {
			start_turn(d, o, muse_prompt_by_cmd(d, get_str(p, "commandId")))
		}
		set(d, &d.turn, get_str(p, "turnId"))
	case "turn/completed":
		muse_turn_completed(d, p, o)
	case "turn/unqueued", "turn/retracted":
		if id := muse_prompt_by_cmd(d, get_str(p, "commandId")); id != "" {
			drop_prompt(d, o, id)
		}
	case "turn/retryScheduled", "turn/modelRetryScheduled":
		notice(o, .Warning, "retrying the model request")
	case "item/started":
		item := get(p, "item")
		id := get_str(item, "itemId")
		switch get_str(item, "kind") {
		case "agentMessage":
			emit(o, Message_Started{native_id = dup(o, id)})
		case "reasoning":
			set(d, &d.reason_item, id)
		case "toolCall", "webSearch", "subagent":
			name := get_str(item, "tool")
			if name == "" {
				name = get_str(get(item, "displayLabel"), "neutral")
			}
			if name == "" {
				name = get_str(item, "kind")
			}
			emit(o, Tool_Started{id = dup(o, id), name = dup(o, name), input = dup(o, get_str(item, "args"))})
		}
	case "item/delta":
		id := get_str(p, "itemId")
		t := get_str(p, "delta")
		field := get_str(p, "field")
		switch {
		case t == "":
		case id == d.reason_item || strings.has_prefix(field, "summary"):
			emit(o, Reasoning_Delta{text = dup(o, t)})
		case field == "" || field == "text":
			text_delta(d, o, id, t)
		case:
			emit(o, Tool_Updated{id = dup(o, id), output = dup(o, t), append = true})
		}
	case "item/completed":
		muse_item_completed(d, get(p, "item"), o)
	case "approval/requested", "approval/request":
		muse_approval(d, p, o)
	case "userInput/requested":
		notice(o, .Warning, "the agent asked a question this client cannot answer")
	}
}

@(private)
muse_item_completed :: proc(d: ^Driver, item: json.Value, o: ^Output) {
	id := get_str(item, "itemId")
	status := get_str(item, "status")
	switch get_str(item, "kind") {
	case "userMessage":
		if pid := muse_prompt_by_cmd(d, get_str(item, "commandId")); pid != "" {
			accept_prompt(d, o, pid, id)
		}
	case "agentMessage":
		if d.stream_item != id {
			text_delta(d, o, id, get_str(item, "text"))
		}
	case "toolCall", "webSearch", "subagent":
		out := get_str(item, "visibleOutput")
		if out == "" {
			out = get_str(item, "text")
		}
		if out == "" {
			out = get_str(item, "failureReason")
		}
		emit(o, Tool_Finished{id = dup(o, id), output = dup(o, out), is_error = status != "completed"})
	}
}

@(private)
muse_turn_completed :: proc(d: ^Driver, p: json.Value, o: ^Output) {
	if !d.running {
		start_turn(d, o, "")
	}
	if id := get_str(p, "turnId"); id != "" {
		set(d, &d.checkpoint, id)
	}
	u := get(p, "usage")
	if is_object(u) {
		add_usage(
			d,
			Usage {
				input_tokens = get_u64(u, "inputTokens"),
				output_tokens = get_u64(u, "outputTokens"),
				cache_read_tokens = get_u64(u, "cacheReadTokens") + get_u64(u, "cachedTokens"),
				cache_write_tokens = get_u64(u, "cacheWriteTokens"),
				reasoning_tokens = get_u64(u, "reasoningTokens"),
			},
		)
	}
	switch get_str(p, "terminal") {
	case "completed":
		finish_turn(d, o, .Done)
	case "cancelled":
		finish_turn(d, o, .Interrupted)
	case:
		msg := get_str(get(p, "error"), "message")
		if msg == "" {
			msg = get_str(p, "reason")
		}
		fail_turn(d, o, msg != "" ? msg : "the turn failed")
	}
}

@(private)
muse_approval :: proc(d: ^Driver, p: json.Value, o: ^Output) {
	aid := get_str(p, "approvalId")
	for q in d.perms {
		if q.id == aid {
			return
		}
	}
	allow, always, deny: string
	for c in get_arr(p, "availableChoices") {
		cid := get_str(c, "choiceId")
		switch get_str(c, "decision") {
		case "approved":
			allow = cid
		case "approvedForSession":
			always = cid
		case "denied":
			deny = cid
		}
	}
	tool := get_str(p, "toolName")
	input := get_str(p, "rawArgs")
	title := get_str(p, "reviewerReason")
	if title == "" {
		title = tool
	}
	perm := Perm {
		id           = own(d, aid),
		raw_id       = own(d, aid),
		kind         = own(d, tool),
		allow        = own(d, allow),
		allow_always = own(d, always),
		deny         = own(d, deny),
		extra        = own(d, to_json(get(p, "currentRequirementId"))),
	}
	if !d.req.ask_permissions {
		edit := strings.contains(tool, "edit") || strings.contains(tool, "write") || strings.contains(tool, "patch")
		muse_answer(d, &perm, auto_decision(d.req.access, edit), o)
		drop_perm(d, &perm)
		emit(o, Permission_Request{id = dup(o, aid), tool = dup(o, tool), title = dup(o, title), input = dup(o, input), answered = true})
		return
	}
	append(&d.perms, perm)
	emit(o, Permission_Request{id = dup(o, aid), tool = dup(o, tool), title = dup(o, title), input = dup(o, input)})
}

@(private)
muse_response :: proc(d: ^Driver, v: json.Value, o: ^Output) {
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
			msg := rpc_error_message(v)
			if d.rewinding && take_fallback(d) {
				notice(o, .Warning, msg)
				drop_target(d, &d.req.rewind)
				set(d, &d.req.resume, "")
				muse_open(d, &o.bytes)
			} else if d.rewinding {
				rewind_failed(d, o, msg)
				for &q in d.prompts {
					if !q.sent {
						muse_write_prompt(d, &o.bytes, &q)
					}
				}
			} else {
				emit(o, Session_Failed{message = dup(o, msg)})
			}
			return
		}
		open_session(d, o, get_str(get(result, "session"), "sessionId"))
		d.ready = true
		for &q in d.prompts {
			if !q.sent {
				muse_write_prompt(d, &o.bytes, &q)
			}
		}
	case .Turn, .Steer:
		if failed {
			i := find_prompt(d, p.ref)
			if i < 0 {
				return
			}
			if p.kind == .Steer && d.running {
				drop_prompt(d, o, p.ref)
				notice(o, .Warning, rpc_error_message(v))
				return
			}
			remove_prompt(d, i)
			start_turn(d, o, p.ref)
			fail_turn(d, o, rpc_error_message(v))
			return
		}
		switch get_str(result, "disposition") {
		case "started":
			start_turn(d, o, p.ref)
			set(d, &d.turn, get_str(result, "turnId"))
		case "steered":
			accept_prompt(d, o, p.ref, "")
		}
	case .Interrupt:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
		}
	case .Models:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
			return
		}
		list := make([dynamic]Model, context.temp_allocator)
		for m in get_arr(result, "models") {
			id := get_str(m, "modelId")
			if id == "" {
				continue
			}
			name := get_str(m, "displayLabel")
			append(&list, Model{id = id, name = name != "" ? name : id, is_default = get_bool(m, "isDefault")})
		}
		emit_models(o, list[:])
	case .Other:
		if failed {
			notice(o, .Warning, rpc_error_message(v))
		}
	}
}

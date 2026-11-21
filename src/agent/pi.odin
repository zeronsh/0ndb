package agent

import "core:encoding/json"
import "core:strconv"
import "core:strings"

@(private)
pi_launch :: proc(d: ^Driver, argv: ^[dynamic]string, b: ^[dynamic]u8, files: ^[dynamic]Launch_File) {
	base_argv(d, argv)
	append(argv, "--mode", "rpc", "--no-themes")
	if d.req.model != "" {
		append(argv, "--model", d.req.model)
	}
	if d.req.effort != "" {
		append(argv, "--thinking", d.req.effort)
	}
	switch d.req.access {
	case .Plan:
		append(argv, "--tools", "read,grep,find,ls")
	case .Edit:
		append(argv, "--exclude-tools", "bash")
	case .Full:
	}
	if len(d.req.mcp) > 0 && d.req.scratch != "" {
		path := strings.concatenate({d.req.scratch, "/ondb-mcp.mjs"}, context.temp_allocator)
		append(files, Launch_File{path = path, data = transmute([]u8)pi_mcp_extension(d)})
		append(argv, "--extension", path)
	}
	if d.req.rewind.session != "" {
		append(argv, "--session", d.req.rewind.session)
	} else if d.req.resume != "" {
		append(argv, "--session", d.req.resume)
	}
	if d.req.rewind.session != "" {
		pi_rewind_step(d, b)
	} else {
		pi_command(d, b, .State, "get_state")
		pi_end(b)
	}
}

@(private)
pi_command :: proc(d: ^Driver, b: ^[dynamic]u8, kind: Request, type: string, ref := "") {
	id := request(d, kind, ref)
	append(b, `{"id":"ondb-`)
	w_int(b, id)
	append(b, `"`)
	f_str(b, "type", type)
}

@(private)
pi_end :: proc(b: ^[dynamic]u8) {
	append(b, "}\n")
}

@(private)
pi_rewind_step :: proc(d: ^Driver, b: ^[dynamic]u8) {
	d.ready = false
	t := d.req.rewind
	switch {
	case t.before != "":
		pi_command(d, b, .Fork, "fork")
		f_str(b, "entryId", t.before)
	case t.after == "":
		pi_command(d, b, .Fork, "new_session")
	case:
		pi_command(d, b, .Rewind_Lookup, "get_entries")
	}
	pi_end(b)
}

@(private)
pi_text :: proc(p: ^Prompt) -> string {
	notes := make([dynamic]string, context.temp_allocator)
	for f in p.files {
		if !(is_image(f) && len(f.data) > 0) {
			append(&notes, attachment_note(f, true))
		}
	}
	return with_notes(p.text, notes[:])
}

@(private)
pi_write_prompt :: proc(d: ^Driver, b: ^[dynamic]u8, p: ^Prompt) {
	p.sent = true
	pi_command(d, b, .Turn, "prompt", p.id)
	f_str(b, "message", pi_text(p))
	images := false
	for f in p.files {
		if !(is_image(f) && len(f.data) > 0) {
			continue
		}
		if !images {
			f_arr(b, "images")
			images = true
		}
		open(b)
		f_str(b, "type", "image")
		f_str(b, "data", b64(f.data))
		f_str(b, "mimeType", f.mime)
		close_obj(b)
	}
	if images {
		close_arr(b)
	}
	f_str(b, "streamingBehavior", p.steer ? "steer" : "followUp")
	pi_end(b)
}

@(private)
pi_submit :: proc(d: ^Driver, p: ^Prompt, o: ^Output) {
	if d.ready {
		pi_write_prompt(d, &o.bytes, p)
		wrote(o, p.id)
	}
}

@(private)
pi_ready :: proc(d: ^Driver, o: ^Output) {
	d.ready = true
	for &p in d.prompts {
		if !p.sent {
			pi_write_prompt(d, &o.bytes, &p)
			wrote(o, p.id)
		}
	}
}

@(private)
pi_entry_text :: proc(m: json.Value) -> string {
	c := get(m, "content")
	if s, ok := c.(json.String); ok {
		return s
	}
	b := make([dynamic]u8, context.temp_allocator)
	for part in get_arr(m, "content") {
		if get_str(part, "type") == "text" {
			append(&b, get_str(part, "text"))
		}
	}
	return string(b[:])
}

@(private)
pi_match_entries :: proc(d: ^Driver, o: ^Output, entries: json.Array) {
	unmatched := make([dynamic]json.Value, context.temp_allocator)
	for e in entries {
		m := get(e, "message")
		if get_str(e, "type") != "message" || get_str(m, "role") != "user" {
			continue
		}
		text := pi_entry_text(m)
		hit := ""
		for &q in d.prompts {
			if q.sent && (q.text == text || pi_text(&q) == text) {
				hit = strings.clone(q.id, context.temp_allocator)
				break
			}
		}
		if hit != "" {
			accept_prompt(d, o, hit, get_str(e, "id"))
		} else {
			append(&unmatched, e)
		}
	}
	for e in unmatched {
		for q in d.prompts {
			if q.sent && strings.has_prefix(q.text, "/") {
				accept_prompt(d, o, strings.clone(q.id, context.temp_allocator), get_str(e, "id"))
				break
			}
		}
	}
}


@(private)
pi_interrupt :: proc(d: ^Driver, o: ^Output) {
	if !d.running {
		return
	}
	d.interrupted = true
	pi_command(d, &o.bytes, .Clear_Queue, "clear_queue")
	pi_end(&o.bytes)
	pi_command(d, &o.bytes, .Interrupt, "abort")
	pi_end(&o.bytes)
}

@(private)
pi_rewind :: proc(d: ^Driver, o: ^Output) {
	t := d.req.rewind
	if t.session != "" && t.session != d.session {
		d.ready = false
		pi_command(d, &o.bytes, .Switch, "switch_session")
		f_str(&o.bytes, "sessionPath", t.session)
		pi_end(&o.bytes)
		return
	}
	pi_rewind_step(d, &o.bytes)
}

@(private)
pi_list_models :: proc(d: ^Driver, o: ^Output) {
	pi_command(d, &o.bytes, .Model_State, "get_state")
	pi_end(&o.bytes)
	pi_command(d, &o.bytes, .Models, "get_available_models")
	pi_end(&o.bytes)
}

@(private)
pi_answer :: proc(d: ^Driver, p: ^Perm, decision: Decision, o: ^Output) {
	pi_ui_reply(&o.bytes, p.raw_id, p.kind, p.allow, decision)
}

@(private)
pi_ui_reply :: proc(b: ^[dynamic]u8, id, method, first_option: string, decision: Decision) {
	append(b, '{')
	f_str(b, "type", "extension_ui_response")
	f_str(b, "id", id)
	switch {
	case method == "confirm":
		f_bool(b, "confirmed", decision != .Deny)
	case method == "select" && decision != .Deny && first_option != "":
		f_str(b, "value", first_option)
	case:
		f_bool(b, "cancelled", true)
	}
	pi_end(b)
}

@(private)
pi_feed :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	switch get_str(v, "type") {
	case "response":
		pi_response(d, v, o)
	case "agent_start":
		if !d.running {
			id := ""
			for p in d.prompts {
				if p.sent {
					id = p.id
					break
				}
			}
			start_turn(d, o, id)
		}
	case "message_start":
		if get_str(get(v, "message"), "role") == "assistant" {
			emit(o, Message_Started{})
		}
	case "message_update":
		e := get(v, "assistantMessageEvent")
		t := get_str(e, "delta")
		if t == "" {
			return
		}
		switch get_str(e, "type") {
		case "text_delta":
			emit(o, Text_Delta{text = dup(o, t)})
		case "thinking_delta":
			emit(o, Reasoning_Delta{text = dup(o, t)})
		}
	case "message_end":
		m := get(v, "message")
		if get_str(m, "role") != "assistant" {
			return
		}
		switch get_str(m, "stopReason") {
		case "error":
			msg := get_str(m, "errorMessage")
			set(d, &d.last_error, msg != "" ? msg : "the model call failed")
		case "aborted":
			d.interrupted = true
		case:
			set(d, &d.last_error, "")
		}
		u := get(m, "usage")
		if is_object(u) {
			add_usage(
				d,
				Usage {
					input_tokens = get_u64(u, "input"),
					output_tokens = get_u64(u, "output"),
					cache_read_tokens = get_u64(u, "cacheRead"),
					cache_write_tokens = get_u64(u, "cacheWrite"),
					cost_usd = num(get(get(u, "cost"), "total")),
				},
			)
		}
	case "tool_execution_start":
		emit(
			o,
			Tool_Started {
				id = dup(o, get_str(v, "toolCallId")),
				name = dup(o, get_str(v, "toolName")),
				input = dup(o, to_json(get(v, "args"))),
			},
		)
	case "tool_execution_update":
		emit(
			o,
			Tool_Updated {
				id = dup(o, get_str(v, "toolCallId")),
				output = dup(o, text_of(get(get(v, "partialResult"), "content"))),
			},
		)
	case "tool_execution_end":
		emit(
			o,
			Tool_Finished {
				id = dup(o, get_str(v, "toolCallId")),
				output = dup(o, text_of(get(get(v, "result"), "content"))),
				is_error = get_bool(v, "isError"),
			},
		)
	case "auto_retry_start":
		notice(o, .Warning, get_str(v, "errorMessage"))
	case "compaction_start":
		notice(o, .Info, "conversation compacting")
	case "extension_error":
		notice(o, .Warning, get_str(v, "error"))
	case "agent_settled":
		if get_bool(v, "aborted") {
			d.interrupted = true
		}
		if !d.running {
			start_turn(d, o, "")
		}
		pi_command(d, &o.bytes, .Entries_Turn, "get_entries")
		if d.checkpoint != "" {
			f_str(&o.bytes, "since", d.checkpoint)
		}
		pi_end(&o.bytes)
	case "extension_ui_request":
		pi_ui_request(d, v, o)
	}
}

@(private)
pi_ui_request :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	method := get_str(v, "method")
	switch method {
	case "select", "confirm", "input", "editor":
	case "notify":
		notice(o, get_str(v, "notifyType") == "error" ? .Error : .Info, get_str(v, "message"))
		return
	case:
		return
	}
	id := get_str(v, "id")
	title := get_str(v, "title")
	first := ""
	if opts := get_arr(v, "options"); len(opts) > 0 {
		first = str(opts[0])
	}
	input := to_json(v)
	if !d.req.ask_permissions {
		pi_ui_reply(&o.bytes, id, method, first, auto_decision(d.req.access, false))
		emit(o, Permission_Request{id = dup(o, id), tool = dup(o, method), title = dup(o, title), input = dup(o, input), answered = true})
		return
	}
	append(&d.perms, Perm{id = own(d, id), raw_id = own(d, id), kind = own(d, method), allow = own(d, first)})
	emit(o, Permission_Request{id = dup(o, id), tool = dup(o, method), title = dup(o, title), input = dup(o, input)})
}

@(private)
pi_response :: proc(d: ^Driver, v: json.Value, o: ^Output) {
	rid := get_str(v, "id")
	if !strings.has_prefix(rid, "ondb-") {
		if !get_bool(v, "success") {
			notice(o, .Warning, get_str(v, "error"))
		}
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
	success := get_bool(v, "success")
	msg := get_str(v, "error")
	data := get(v, "data")
	#partial switch p.kind {
	case .State:
		if !success {
			emit(o, Session_Failed{message = dup(o, msg)})
			return
		}
		file := get_str(data, "sessionFile")
		if file == "" {
			file = get_str(data, "sessionId")
		}
		set(d, &d.native_path, get_str(data, "sessionFile"))
		open_session(d, o, file)
		if d.checkpoint == "" && get_u64(data, "messageCount") > 0 {
			pi_command(d, &o.bytes, .Entries, "get_entries")
			pi_end(&o.bytes)
		}
		pi_ready(d, o)
	case .Switch:
		if !success || get_bool(data, "cancelled") {
			pi_rewind_fallback(d, o, msg != "" ? msg : "session switch was cancelled")
			return
		}
		pi_rewind_step(d, &o.bytes)
	case .Fork:
		if !success || get_bool(data, "cancelled") {
			pi_rewind_fallback(d, o, msg != "" ? msg : "fork was cancelled")
			return
		}
		after := strings.clone(d.req.rewind.after, context.temp_allocator)
		drop_target(d, &d.req.rewind)
		set(d, &d.checkpoint, after)
		pi_command(d, &o.bytes, .State, "get_state")
		pi_end(&o.bytes)
	case .Rewind_Lookup:
		after := d.req.rewind.after
		target := ""
		for e in get_arr(data, "entries") {
			if get_str(e, "type") == "message" && get_str(e, "parentId") == after && get_str(get(e, "message"), "role") == "user" {
				target = get_str(e, "id")
			}
		}
		if target != "" {
			set(d, &d.req.rewind.before, target)
			pi_rewind_step(d, &o.bytes)
			return
		}
		if !success || get_str(data, "leafId") != after {
			pi_rewind_fallback(d, o, "the checkpoint is not in this session")
			return
		}
		drop_target(d, &d.req.rewind)
		pi_command(d, &o.bytes, .State, "get_state")
		pi_end(&o.bytes)
	case .Entries:
		if leaf := get_str(data, "leafId"); success && leaf != "" {
			set(d, &d.checkpoint, leaf)
		}
	case .Entries_Turn:
		if success {
			pi_match_entries(d, o, get_arr(data, "entries"))
			if leaf := get_str(data, "leafId"); leaf != "" {
				set(d, &d.checkpoint, leaf)
			}
		} else {
			notice(o, .Warning, msg)
		}
		switch {
		case d.interrupted:
			finish_turn(d, o, .Interrupted)
		case d.last_error != "":
			fail_turn(d, o, strings.clone(d.last_error, context.temp_allocator))
		case:
			finish_turn(d, o, .Done)
		}
	case .Turn:
		if !success {
			i := find_prompt(d, p.ref)
			steered := i >= 0 && d.prompts[i].steer
			if steered && d.running {
				drop_prompt(d, o, p.ref)
				notice(o, .Warning, msg)
				return
			}
			if i >= 0 {
				remove_prompt(d, i)
			}
			start_turn(d, o, p.ref)
			fail_turn(d, o, msg != "" ? msg : "the prompt was refused")
			return
		}
		if get_str(data, "disposition") == "handled" {
			accept_prompt(d, o, p.ref, "")
			if !d.running {
				start_turn(d, o, p.ref)
				finish_turn(d, o, .Done)
			}
		}
	case .Clear_Queue:
		for kind in ([]string{"steering", "followUp"}) {
			for t in get_arr(data, kind) {
				text := str(t)
				for q, i in d.prompts {
					if q.sent && q.text == text {
						id := strings.clone(q.id, context.temp_allocator)
						remove_prompt(d, i)
						emit(o, Prompt_Dropped{id = dup(o, id)})
						break
					}
				}
			}
		}
	case .Model_State:
		m := get(data, "model")
		set(d, &d.model_opt, strings.concatenate({get_str(m, "provider"), "/", get_str(m, "id")}, context.temp_allocator))
	case .Models:
		list := make([dynamic]Model, context.temp_allocator)
		for m in get_arr(data, "models") {
			prov := get_str(m, "provider")
			mid := get_str(m, "id")
			if prov == "" || mid == "" {
				continue
			}
			id := strings.concatenate({prov, "/", mid}, context.temp_allocator)
			name := get_str(m, "name")
			if name == "" {
				name = mid
			}
			append(&list, Model{id = id, name = strings.concatenate({name, " (", prov, ")"}, context.temp_allocator), is_default = id == d.model_opt})
		}
		emit_models(o, list[:])
	}
}

@(private)
pi_rewind_fallback :: proc(d: ^Driver, o: ^Output, message: string) {
	if d.rewinding && take_fallback(d) {
		notice(o, .Warning, message)
		drop_target(d, &d.req.rewind)
		pi_command(d, &o.bytes, .Fork, "new_session")
		pi_end(&o.bytes)
		return
	}
	rewind_failed(d, o, message)
	pi_command(d, &o.bytes, .State, "get_state")
	pi_end(&o.bytes)
}

@(private)
pi_mcp_extension :: proc(d: ^Driver) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, "const servers = ")
	append(&b, '{')
	for m in d.req.mcp {
		f_obj(&b, m.name)
		if m.url != "" {
			f_str(&b, "url", m.url)
			f_kv_object(&b, "headers", m.headers, ':')
		} else {
			f_str(&b, "command", m.command)
			f_str_array(&b, "args", m.args)
			f_kv_object(&b, "env", m.env, '=')
		}
		close_obj(&b)
	}
	append(&b, "};\nexport default function (pi) {\n\tfor (const name of Object.keys(servers)) pi.registerMcpServer(name, servers[name]);\n}\n")
	return string(b[:])
}

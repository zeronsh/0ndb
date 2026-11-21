package model

responses_model :: proc() -> Model {
	return Model {
		api = .OpenAI_Responses,
		encode = responses_encode,
		head = responses_head,
		tail = json_tail,
		parse = responses_parse,
		finish = responses_finish,
		classify = openai_classify,
		marker = no_marker,
		auth = openai_auth,
		trigger = responses_trigger,
		compacted = responses_compacted,
		state_code = responses_state_code,
	}
}

@(private)
no_marker :: proc(m: ^Model, cfg: ^Config) -> string {
	return ""
}

@(private)
openai_auth :: proc(m: ^Model, cfg: ^Config, opts: ^Request_Opts, dst: ^[dynamic]Header) {
	if cfg.api_key != "" {
		append(dst, Header{OPENAI_AUTH_HEADER, concat({BEARER_PREFIX, cfg.api_key})})
	}
}

@(private)
responses_head :: proc(m: ^Model, cfg: ^Config, ctx: ^Context, opts: ^Request_Opts, dst: ^[dynamic]u8) {
	b := dst
	w_raw(b, `{"model":`)
	w_str(b, cfg.spec.id)
	w_raw(b, opts.op == .None ? `,"stream":true,"store":false,` : `,"stream":true,"store":true,`)
	if opts.op == .Continue {
		w_raw(b, `"previous_response_id":`)
		w_str(b, opts.prev)
		w_byte(b, ',')
	}
	w_raw(b, OPENAI_INCLUDE_REASONING)
	w_raw(b, `,"max_output_tokens":`)
	w_uint(b, max_tokens(cfg))
	if cfg.spec.thinking != .None {
		w_raw(b, `,"reasoning":{`)
		first := true
		if cfg.effort != .Default {
			w_raw(b, `"effort":`)
			w_str(b, effort_name(cfg.effort))
			first = false
		}
		if cfg.display != .Omitted {
			if !first {
				w_byte(b, ',')
			}
			w_raw(b, `"summary":"auto"`)
		}
		w_byte(b, '}')
	}
	if cfg.cache_key != "" {
		w_raw(b, `,"prompt_cache_key":`)
		w_str(b, cfg.cache_key)
	}
	if cfg.cache_ttl == .Long {
		if cfg.spec.explicit_cache {
			w_raw(b, `,"prompt_cache_options":{"ttl":"12h"}`)
		} else {
			w_raw(b, `,"prompt_cache_retention":"24h"`)
		}
	}
	if len(ctx.tools) > 0 {
		w_raw(b, `,"parallel_tool_calls":`)
		w_raw(b, cfg.serial_tools ? "false" : "true")
		w_raw(b, `,"tools":[`)
		for t, i in ctx.tools {
			if i > 0 {
				w_byte(b, ',')
			}
			w_raw(b, `{"type":"function","name":`)
			w_str(b, t.name)
			if t.description != "" {
				w_raw(b, `,"description":`)
				w_str(b, t.description)
			}
			w_raw(b, `,"parameters":`)
			w_raw(b, schema_or_default(t.schema))
			w_raw(b, t.strict ? `,"strict":true}` : `,"strict":false}`)
		}
		w_byte(b, ']')
	}
	w_raw(b, `,"input":[`)
	if ctx.system != "" && opts.op != .Continue {
		w_raw(b, `{"role":"developer","content":[{"type":"input_text","text":`)
		w_str(b, ctx.system)
		w_raw(b, `}]},`)
	}
}

@(private)
responses_encode :: proc(m: ^Model, cfg: ^Config, msg: ^Message, t: ^Transcript) {
	if msg.native != "" && msg.native_api == .OpenAI_Responses {
		it, ok := j_array(transmute([]u8)msg.native)
		if ok {
			for el in j_next(&it) {
				item_begin(t)
				append(&t.buf, ..el)
				t.text_bytes += len(el)
				t.positions += 1
			}
			t.last_role = msg.role
			t.has_last = true
			return
		}
	}
	b := &t.buf
	if msg.role == .Assistant {
		open := false
		for &blk in msg.blocks {
			#partial switch v in blk {
			case Text:
				if v.text == "" {
					continue
				}
				if !open {
					item_begin(t)
					w_raw(b, `{"type":"message","role":"assistant","content":[`)
					open = true
				} else {
					w_byte(b, ',')
				}
				w_raw(b, `{"type":"output_text","text":`)
				w_str(b, v.text)
				w_byte(b, '}')
				t.text_bytes += len(v.text)
			case Tool_Use:
				if open {
					w_raw(b, `]}`)
					open = false
				}
				item_begin(t)
				w_raw(b, `{"type":"function_call","call_id":`)
				w_str(b, v.id)
				w_raw(b, `,"name":`)
				w_str(b, v.name)
				w_raw(b, `,"arguments":`)
				w_str(b, v.input != "" ? v.input : "{}")
				w_byte(b, '}')
				t.text_bytes += len(v.input)
			}
		}
		if open {
			w_raw(b, `]}`)
		}
		t.positions += 1
		t.last_role = .Assistant
		t.has_last = true
		return
	}
	for &blk in msg.blocks {
		if v, ok := blk.(Tool_Result); ok {
			item_begin(t)
			w_raw(b, `{"type":"function_call_output","call_id":`)
			w_str(b, v.id)
			w_raw(b, `,"output":`)
			responses_output(t, v)
			w_byte(b, '}')
		}
	}
	open := false
	for &blk in msg.blocks {
		before := len(b)
		#partial switch v in blk {
		case Text, Image, Document:
			if !open {
				item_begin(t)
				w_raw(b, `{"role":"user","content":[`)
				open = true
			} else {
				w_byte(b, ',')
			}
			if !responses_part(t, &blk) {
				resize(b, before)
			}
		}
	}
	if open {
		w_raw(b, `]}`)
	}
	t.positions += 1
	t.last_role = .User
	t.has_last = true
}

@(private)
responses_output :: proc(t: ^Transcript, r: Tool_Result) {
	b := &t.buf
	simple := true
	for &c in r.content {
		if _, ok := c.(Text); !ok {
			simple = false
		}
	}
	if simple {
		w_byte(b, '"')
		if r.is_error {
			w_raw(b, "Error: ")
		}
		for &c in r.content {
			tx := c.(Text)
			w_escaped(b, transmute([]u8)tx.text)
			t.text_bytes += len(tx.text)
		}
		w_byte(b, '"')
		return
	}
	w_byte(b, '[')
	n := 0
	for &c in r.content {
		before := len(b)
		if n > 0 {
			w_byte(b, ',')
		}
		if !responses_part(t, &c) {
			resize(b, before)
			continue
		}
		n += 1
	}
	w_byte(b, ']')
}

@(private)
responses_part :: proc(t: ^Transcript, blk: ^Block) -> bool {
	b := &t.buf
	#partial switch v in blk {
	case Text:
		if v.text == "" {
			return false
		}
		w_raw(b, `{"type":"input_text","text":`)
		w_str(b, v.text)
		w_byte(b, '}')
		t.text_bytes += len(v.text)
		return true
	case Image:
		w_raw(b, `{"type":"input_image","image_url":`)
		if v.url != "" {
			w_str(b, v.url)
		} else {
			w_raw(b, `"data:`)
			w_raw(b, v.mime != "" ? v.mime : "image/png")
			w_raw(b, `;base64,`)
			w_base64(b, v.data)
			w_byte(b, '"')
		}
		w_byte(b, '}')
		t.media += 1
		t.media_tok += 1600
		return true
	case Document:
		if v.text != "" && len(v.data) == 0 && v.url == "" {
			w_raw(b, `{"type":"input_text","text":`)
			w_str(b, v.text)
			w_byte(b, '}')
			t.text_bytes += len(v.text)
			return true
		}
		w_raw(b, `{"type":"input_file"`)
		if v.url != "" {
			w_raw(b, `,"file_url":`)
			w_str(b, v.url)
		} else {
			w_raw(b, `,"filename":`)
			w_str(b, v.title != "" ? v.title : "document.pdf")
			w_raw(b, `,"file_data":"data:`)
			w_raw(b, v.mime != "" ? v.mime : "application/pdf")
			w_raw(b, `;base64,`)
			w_base64(b, v.data)
			w_byte(b, '"')
		}
		w_byte(b, '}')
		t.media += 1
		t.media_tok += u64(len(v.data)) / 1000
		return true
	}
	return false
}

@(private)
responses_parse :: proc(m: ^Model, s: ^Stream, chunk: []u8, out: ^[dynamic]Delta) {
	sse_feed(&s.sse, chunk)
	for {
		ev, ok := sse_next(&s.sse)
		if !ok {
			break
		}
		clear(&s.scratch)
		responses_event(s, ev, out)
	}
	if s.sse.overflow {
		stream_fail(s, out, .Malformed, "overflow", "stream event exceeds the size limit")
	}
}

@(private)
responses_event :: proc(s: ^Stream, ev: Sse_Event, out: ^[dynamic]Delta) {
	d := ev.data
	ty := j_get_raw_str(d, "type")
	if ty == "" {
		if !j_is_object(d) {
			stream_fail(s, out, .Malformed, "malformed", "malformed stream event")
		}
		return
	}
	switch ty {
	case OPENAI_EVENT_CREATED:
		r, _ := j_get(d, "response")
		set_bytes(&s.msg_id, j_get_raw_str(r, "id"))
		set_bytes(&s.model, j_get_raw_str(r, "model"))
		s.started = true
		append(out, Delta{kind = .Start, id = string(s.msg_id[:]), name = string(s.model[:])})
	case OPENAI_EVENT_ITEM_ADDED:
		idx := j_int(j_get_or(d, "output_index"))
		item, _ := j_get(d, "item")
		a := acc_at(s, idx)
		if a == nil {
			stream_fail(s, out, .Malformed, "malformed", "bad output_index")
			return
		}
		it := j_get_raw_str(item, "type")
		set_bytes(&a.type, it)
		switch it {
		case "message":
			a.kind = .Text
			append(out, Delta{kind = .Block_Start, block = .Text, index = idx})
		case "reasoning":
			a.kind = .Thinking
			append(out, Delta{kind = .Block_Start, block = .Thinking, index = idx})
		case "function_call":
			a.kind = .Tool_Call
			set_bytes(&a.id, j_get_raw_str(item, "call_id"))
			set_bytes(&a.name, j_get_str(item, "name", &s.scratch))
			append(out, Delta{kind = .Block_Start, block = .Tool_Call, index = idx, id = string(a.id[:]), name = string(a.name[:])})
		case:
			a.kind = .Other
			append(out, Delta{kind = .Block_Start, block = .Other, index = idx, name = string(a.type[:])})
		}
	case OPENAI_EVENT_TEXT_DELTA, OPENAI_EVENT_REFUSAL_DELTA:
		idx := j_int(j_get_or(d, "output_index"))
		a := acc_at(s, idx)
		if a == nil {
			return
		}
		if ty == OPENAI_EVENT_REFUSAL_DELTA {
			s.stop = .Refusal
		}
		txt := j_get_str(d, "delta", &s.scratch)
		append(&a.text, txt)
		append(out, Delta{kind = .Text, index = idx, text = txt})
	case OPENAI_EVENT_SUMMARY_DELTA, OPENAI_EVENT_REASONING_DELTA:
		idx := j_int(j_get_or(d, "output_index"))
		a := acc_at(s, idx)
		if a == nil {
			return
		}
		txt := j_get_str(d, "delta", &s.scratch)
		append(&a.text, txt)
		if txt != "" {
			append(out, Delta{kind = .Thinking, index = idx, text = txt})
		}
	case "response.reasoning_summary_part.added":
		idx := j_int(j_get_or(d, "output_index"))
		a := acc_at(s, idx)
		if a != nil && len(a.text) > 0 {
			append(&a.text, "\n\n")
			append(out, Delta{kind = .Thinking, index = idx, text = "\n\n"})
		}
	case OPENAI_EVENT_ARGS_DELTA:
		idx := j_int(j_get_or(d, "output_index"))
		a := acc_at(s, idx)
		if a == nil {
			return
		}
		txt := j_get_str(d, "delta", &s.scratch)
		append(&a.text, txt)
		append(out, Delta{kind = .Tool_Input, index = idx, text = txt})
	case OPENAI_EVENT_ITEM_DONE:
		idx := j_int(j_get_or(d, "output_index"))
		item, ok := j_get(d, "item")
		a := acc_at(s, idx)
		if !ok || a == nil {
			stream_fail(s, out, .Malformed, "malformed", "malformed output_item.done")
			return
		}
		clear(&a.raw)
		append(&a.raw, ..item)
		if a.kind == .Tool_Call {
			args := j_get_str(item, "arguments", &s.scratch)
			set_bytes(&a.text, args)
			if len(a.id) == 0 {
				set_bytes(&a.id, j_get_raw_str(item, "call_id"))
			}
		}
		a.complete = true
		append(out, Delta{kind = .Block_Stop, block = a.kind, index = idx, id = string(a.id[:]), text = string(a.text[:])})
	case OPENAI_EVENT_COMPLETED, OPENAI_EVENT_INCOMPLETE:
		r, _ := j_get(d, "response")
		if u, ok := j_get(r, "usage"); ok && !j_is_null(u) {
			responses_usage(s, u, out)
		}
		if ty == OPENAI_EVENT_INCOMPLETE {
			reason := ""
			if det, ok := j_get(r, "incomplete_details"); ok {
				reason = j_get_raw_str(det, "reason")
			}
			s.stop = reason == "content_filter" ? .Refusal : .Max_Tokens
		} else if s.stop != .Refusal {
			s.stop = .End_Turn
			for i in 0 ..< s.used {
				if s.blocks[i].kind == .Tool_Call && s.blocks[i].complete {
					s.stop = .Tool_Use
					break
				}
			}
		}
		append(out, Delta{kind = .Stop, stop = s.stop})
		s.done = true
	case OPENAI_EVENT_FAILED:
		r, _ := j_get(d, "response")
		e, _ := j_get(r, "error")
		code := j_get_raw_str(e, "code")
		msg := j_get_str(e, "message", &s.scratch)
		stream_fail(s, out, openai_code_class(code, msg, .Server), code, msg)
	case OPENAI_EVENT_ERROR:
		code := j_get_raw_str(d, "code")
		msg := j_get_str(d, "message", &s.scratch)
		if e, ok := j_get(d, "error"); ok {
			code = j_get_raw_str(e, "code")
			msg = j_get_str(e, "message", &s.scratch)
		}
		stream_fail(s, out, openai_code_class(code, msg, .Server), code, msg)
	}
}

@(private)
responses_usage :: proc(s: ^Stream, u: []u8, out: ^[dynamic]Delta) {
	total := j_get_u64(u, "input_tokens")
	cu := Call_Usage {
		output = j_get_u64(u, "output_tokens"),
	}
	if det, ok := j_get(u, "input_tokens_details"); ok && !j_is_null(det) {
		cu.cache_read = j_get_u64(det, "cached_tokens")
		writes := j_get_u64(det, "cache_write_tokens")
		if wd, wok := j_get(det, "cache_write_tokens_details"); wok && !j_is_null(wd) {
			cu.cache_long = j_get_u64(wd, "ttl_12h_tokens")
			cu.cache_write = j_get_u64(wd, "ttl_30m_tokens")
		} else {
			cu.cache_write = writes
		}
	}
	used := cu.cache_read + cu.cache_write + cu.cache_long
	cu.input = total > used ? total - used : 0
	if od, ok := j_get(u, "output_tokens_details"); ok && !j_is_null(od) {
		cu.reasoning = j_get_u64(od, "reasoning_tokens")
	}
	usage_merge(&s.usage, cu)
	append(out, Delta{kind = .Usage, usage = s.usage})
}

@(private)
openai_code_class :: proc(code, msg: string, fallback: Failure_Class) -> Failure_Class {
	switch code {
	case "context_length_exceeded", "string_above_max_length":
		return .Too_Long
	case "rate_limit_exceeded", "slow_down":
		return .Rate_Limited
	case "server_is_overloaded", "server_overloaded":
		return .Overloaded
	case "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded", "organization_usage_limit_exceeded":
		return .Quota
	case "invalid_api_key", "invalid_authentication":
		return .Auth
	case "server_error", "internal_error":
		return .Server
	case "invalid_prompt", "invalid_request_error", "invalid_value":
		return .Invalid
	}
	if contains_fold(msg, "context length") || contains_fold(msg, "context window") || contains_fold(msg, "maximum context") {
		return .Too_Long
	}
	return fallback
}

@(private)
openai_classify :: proc(m: ^Model, status: int, headers: []Header, body: []u8) -> Failure {
	f := Failure {
		status = status,
		class  = status_class(status),
	}
	scratch := make([dynamic]u8, context.temp_allocator)
	if e, ok := j_get(body, "error"); ok {
		f.code = j_get_raw_str(e, "code")
		if f.code == "" {
			f.code = j_get_raw_str(e, "type")
		}
		f.message = j_get_str(e, "message", &scratch)
		f.class = openai_code_class(f.code, f.message, f.class)
	} else if len(body) > 0 {
		f.message = string(body[:min(len(body), 512)])
	}
	f.retry_after = retry_after_ms(headers)
	f.should_retry = should_retry_header(headers)
	if f.class == .Quota {
		f.should_retry = -1
	}
	return f
}

@(private)
responses_finish :: proc(m: ^Model, s: ^Stream, t: ^Transcript, partial: bool) -> bool {
	b := &t.buf
	committed := 0
	last_commit := -1
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		if responses_keep(a, partial, i == s.used - 1) && a.kind != .Thinking {
			last_commit = i
		}
	}
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		if !responses_keep(a, partial, i == s.used - 1) {
			continue
		}
		if a.kind == .Thinking && i > last_commit {
			continue
		}
		item_begin(t)
		if a.kind == .Thinking {
			a.kept = true
		}
		if a.complete && len(a.raw) > 0 {
			append(b, ..a.raw[:])
		} else {
			w_raw(b, `{"type":"message","role":"assistant","content":[{"type":"output_text","text":`)
			w_str(b, string(a.text[:]))
			w_raw(b, `}]}`)
		}
		t.text_bytes += len(a.raw) + len(a.text)
		committed += 1
	}
	if committed > 0 {
		t.positions += 1
		t.last_role = .Assistant
		t.has_last = true
	}
	return committed > 0
}

@(private)
responses_keep :: proc(a: ^Acc, partial: bool, last: bool) -> bool {
	switch a.kind {
	case .Text:
		if a.complete {
			return true
		}
		return len(a.text) > 0 && (partial || last)
	case .Thinking:
		return a.complete
	case .Tool_Call:
		return a.complete && !partial
	case .Other:
		return a.complete && !partial
	}
	return false
}

@(private)
responses_trigger :: proc(m: ^Model, cfg: ^Config, t: ^Transcript) {
	item_begin(t)
	w_raw(&t.buf, OPENAI_COMPACTION_TRIGGER)
}

@(private)
responses_compacted :: proc(m: ^Model, s: ^Stream, t: ^Transcript, summary: ^[dynamic]u8) -> bool {
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		if a.kind != .Other || !a.complete || string(a.type[:]) != OPENAI_COMPACTION_ITEM {
			continue
		}
		item_begin(t)
		append(&t.buf, ..a.raw[:])
		item_begin(t)
		w_raw(&t.buf, `{"role":"user","content":[{"type":"input_text","text":`)
		w_str(&t.buf, COMPACT_RESUME_TEXT)
		w_raw(&t.buf, `}]}`)
		t.positions += 2
		t.text_bytes += len(a.raw) + len(COMPACT_RESUME_TEXT)
		t.compaction = true
		t.last_role = .User
		t.has_last = true
		return true
	}
	return false
}

@(private)
responses_state_code :: proc(m: ^Model, f: Failure) -> State_Fault {
	for c in OPENAI_STATE_RESET_CODES {
		if f.code == c {
			return .Replay
		}
	}
	if f.code == "" && contains_fold(f.message, "previous_response") {
		return .Replay
	}
	return .None
}

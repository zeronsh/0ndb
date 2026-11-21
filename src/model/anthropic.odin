package model

anthropic_model :: proc() -> Model {
	return Model {
		api = .Anthropic,
		encode = anthropic_encode,
		head = anthropic_head,
		tail = json_tail,
		next = anthropic_next,
		finish = anthropic_finish,
		classify = anthropic_classify,
		marker = anthropic_marker,
		auth = anthropic_auth,
		compacted = anthropic_compacted,
		state_code = anthropic_state_code,
		warm_usage = anthropic_warm_usage,
		warm_tail = anthropic_warm_tail,
	}
}

@(private)
json_tail :: proc(m: ^Model, cfg: ^Config, kind: Request_Kind, dst: ^[dynamic]u8) {
	append(dst, "]}")
}

@(private)
item_begin :: proc(t: ^Transcript) {
	if t.items > 0 {
		append(&t.buf, ',')
	}
	t.items += 1
}

@(private)
anthropic_marker :: proc(m: ^Model, cfg: ^Config) -> string {
	if cfg.cache_ttl == .Long {
		return `,"cache_control":{"type":"ephemeral","ttl":"1h"}`
	}
	return `,"cache_control":{"type":"ephemeral"}`
}

@(private)
anthropic_auth :: proc(m: ^Model, cfg: ^Config, opts: ^Request_Opts, dst: ^[dynamic]Header) {
	betas := make([dynamic]u8, context.temp_allocator)
	add :: proc(b: ^[dynamic]u8, v: string) {
		if len(b) > 0 {
			append(b, ',')
		}
		append(b, v)
	}
	if cfg.bearer {
		append(dst, Header{OPENAI_AUTH_HEADER, concat({BEARER_PREFIX, cfg.api_key})})
		add(&betas, "oauth-2025-04-20")
	} else if cfg.api_key != "" {
		append(dst, Header{ANTHROPIC_KEY_HEADER, cfg.api_key})
	}
	append(dst, Header{ANTHROPIC_VERSION_HEADER, ANTHROPIC_VERSION})
	if anthropic_fallback(cfg) && opts.kind != .Keepalive {
		add(&betas, ANTHROPIC_FALLBACK_BETA)
	}
	if opts.op != .None {
		add(&betas, ANTHROPIC_THREAD_BETA)
	}
	if opts.compaction || opts.server_compact {
		add(&betas, ANTHROPIC_COMPACT_BETA)
	}
	if len(betas) > 0 {
		append(dst, Header{ANTHROPIC_BETA_HEADER, string(betas[:])})
	}
}

@(private)
concat :: proc(parts: []string) -> string {
	n := 0
	for p in parts {
		n += len(p)
	}
	b := make([]u8, n, context.temp_allocator)
	i := 0
	for p in parts {
		copy(b[i:], p)
		i += len(p)
	}
	return string(b)
}

@(private)
anthropic_fallback :: proc(cfg: ^Config) -> bool {
	return cfg.spec.server_fallback && !cfg.no_fallback
}

@(private)
anthropic_head :: proc(m: ^Model, cfg: ^Config, ctx: ^Context, opts: ^Request_Opts, dst: ^[dynamic]u8) {
	b := dst
	keep := opts.kind == .Keepalive
	w_raw(b, `{"model":`)
	w_str(b, cfg.spec.id)
	w_raw(b, `,"max_tokens":`)
	w_uint(b, keep ? 0 : max_tokens(cfg))
	if !keep {
		w_raw(b, `,"stream":true`)
	}
	sp := cfg.spec
	if sp.thinking == .Adaptive_Always || sp.thinking == .Adaptive {
		switch cfg.display {
		case .Default:
			if sp.thinking == .Adaptive {
				w_raw(b, `,"thinking":{"type":"adaptive"}`)
			}
		case .Summarized:
			w_raw(b, `,"thinking":{"type":"adaptive","display":"summarized"}`)
		case .Omitted:
			w_raw(b, `,"thinking":{"type":"adaptive","display":"omitted"}`)
		}
		if cfg.effort != .Default && cfg.effort != .None && cfg.effort != .Minimal {
			w_raw(b, `,"output_config":{"effort":`)
			w_str(b, effort_name(cfg.effort))
			w_byte(b, '}')
		}
	}
	if anthropic_fallback(cfg) && !keep {
		w_byte(b, ',')
		w_raw(b, ANTHROPIC_FALLBACK_FIELD)
	}
	if !cfg.explicit_cache && !keep {
		w_byte(b, ',')
		w_raw(b, cfg.cache_ttl == .Long ? ANTHROPIC_AUTO_CACHE_LONG : ANTHROPIC_AUTO_CACHE_SHORT)
	}
	switch opts.op {
	case .None:
	case .Create:
		w_byte(b, ',')
		w_raw(b, ANTHROPIC_THREAD_CREATE)
	case .Continue:
		w_byte(b, ',')
		w_raw(b, ANTHROPIC_THREAD_CONTINUE)
		w_str(b, opts.prev)
		w_byte(b, '}')
	}
	if opts.server_compact {
		w_byte(b, ',')
		w_raw(b, ANTHROPIC_COMPACT_FIELD)
		w_str(b, COMPACT_PROMPT)
		w_byte(b, '}')
	}
	if opts.op == .Continue {
		w_raw(b, `,"messages":[`)
		return
	}
	marker := anthropic_marker(m, cfg)
	if ctx.system != "" {
		w_raw(b, `,"system":[{"type":"text","text":`)
		w_str(b, ctx.system)
		w_raw(b, marker)
		w_raw(b, `}]`)
	}
	if len(ctx.tools) > 0 {
		w_raw(b, `,"tools":[`)
		for t, i in ctx.tools {
			if i > 0 {
				w_byte(b, ',')
			}
			w_raw(b, `{"name":`)
			w_str(b, t.name)
			if t.description != "" {
				w_raw(b, `,"description":`)
				w_str(b, t.description)
			}
			w_raw(b, `,"input_schema":`)
			w_raw(b, schema_or_default(t.schema))
			if t.strict {
				w_raw(b, `,"strict":true`)
			}
			if t.eager {
				w_raw(b, `,"eager_input_streaming":true`)
			}
			if ctx.system == "" && i == len(ctx.tools) - 1 {
				w_raw(b, marker)
			}
			w_byte(b, '}')
		}
		w_byte(b, ']')
	}
	w_raw(b, `,"messages":[`)
}

@(private)
schema_or_default :: proc(s: string) -> string {
	if s == "" || !j_valid(transmute([]u8)s) {
		return `{"type":"object","properties":{}}`
	}
	return s
}

max_tokens :: proc(cfg: ^Config) -> u64 {
	if cfg.max_tokens > 0 {
		return cfg.max_tokens
	}
	if cfg.spec.max_output > 0 {
		return cfg.spec.max_output
	}
	return 32_000
}

@(private)
anthropic_encode :: proc(m: ^Model, cfg: ^Config, msg: ^Message, t: ^Transcript) {
	if msg.native != "" && msg.native_api == .Anthropic {
		if it, ok := j_array(transmute([]u8)msg.native); ok {
			for el in j_next(&it) {
				item_begin(t)
				base := len(t.buf)
				append(&t.buf, ..el)
				anthropic_scan_native(t, base, msg.role)
			}
			return
		}
	}
	start := len(t.buf)
	items := t.items
	positions := t.positions
	mark := t.mark
	item_begin(t)
	b := &t.buf
	w_raw(b, `{"role":`)
	w_raw(b, msg.role == .User ? `"user"` : `"assistant"`)
	w_raw(b, `,"content":[`)
	n := 0
	prev: typeid
	for &blk in msg.blocks {
		before := len(b)
		if n > 0 {
			w_byte(b, ',')
		}
		markable := anthropic_block(t, &blk, msg.role)
		if len(b) == before + (n > 0 ? 1 : 0) {
			resize(b, before)
			continue
		}
		n += 1
		cur := block_typeid(&blk)
		if !(cur == prev && (cur == typeid_of(Tool_Use) || cur == typeid_of(Tool_Result))) {
			t.positions += 1
		}
		prev = cur
		if markable {
			t.mark = len(b) - 1
		}
	}
	if n == 0 {
		resize(b, start)
		t.items = items
		t.positions = positions
		t.mark = mark
		return
	}
	w_raw(b, `]}`)
	t.last_role = msg.role
	t.has_last = true
}

@(private)
block_typeid :: proc(b: ^Block) -> typeid {
	switch _ in b {
	case Text:
		return Text
	case Image:
		return Image
	case Document:
		return Document
	case Tool_Use:
		return Tool_Use
	case Tool_Result:
		return Tool_Result
	case Thinking:
		return Thinking
	}
	return nil
}

@(private)
anthropic_block :: proc(t: ^Transcript, blk: ^Block, role: Role) -> bool {
	b := &t.buf
	switch v in blk {
	case Text:
		if v.text == "" {
			return false
		}
		w_raw(b, `{"type":"text","text":`)
		w_str(b, v.text)
		w_byte(b, '}')
		t.text_bytes += len(v.text)
		return true
	case Image:
		anthropic_media(t, "image", v.mime, v.data, v.url, "", "")
		t.media += 1
		t.media_tok += 1600
		return true
	case Document:
		anthropic_media(t, "document", v.mime, v.data, v.url, v.text, v.title)
		t.media += 1
		t.media_tok += u64(len(v.data)) / 1000 + u64(len(v.text)) / CHARS_PER_TOKEN
		return true
	case Tool_Use:
		w_raw(b, `{"type":"tool_use","id":`)
		w_str(b, v.id)
		w_raw(b, `,"name":`)
		w_str(b, v.name)
		w_raw(b, `,"input":`)
		input := transmute([]u8)v.input
		if j_is_object(input) && j_valid(input) {
			w_raw(b, v.input)
		} else {
			w_raw(b, "{}")
		}
		w_byte(b, '}')
		t.text_bytes += len(v.input)
		return true
	case Tool_Result:
		w_raw(b, `{"type":"tool_result","tool_use_id":`)
		w_str(b, v.id)
		w_raw(b, `,"content":[`)
		k := 0
		for &c in v.content {
			before := len(b)
			if k > 0 {
				w_byte(b, ',')
			}
			#partial switch cv in c {
			case Text:
				if cv.text == "" {
					resize(b, before)
					continue
				}
				w_raw(b, `{"type":"text","text":`)
				w_str(b, cv.text)
				w_byte(b, '}')
				t.text_bytes += len(cv.text)
			case Image:
				anthropic_media(t, "image", cv.mime, cv.data, cv.url, "", "")
				t.media += 1
				t.media_tok += 1600
			case Document:
				anthropic_media(t, "document", cv.mime, cv.data, cv.url, cv.text, cv.title)
				t.media += 1
				t.media_tok += u64(len(cv.data)) / 1000 + u64(len(cv.text)) / CHARS_PER_TOKEN
			case:
				resize(b, before)
				continue
			}
			k += 1
		}
		if k == 0 {
			w_raw(b, `{"type":"text","text":"(no output)"}`)
		}
		w_byte(b, ']')
		if v.is_error {
			w_raw(b, `,"is_error":true`)
		}
		w_byte(b, '}')
		return true
	case Thinking:
		if role != .Assistant {
			return false
		}
		if v.redacted != "" {
			w_raw(b, `{"type":"redacted_thinking","data":`)
			w_str(b, v.redacted)
			w_byte(b, '}')
			return false
		}
		if v.signature == "" {
			return false
		}
		w_raw(b, `{"type":"thinking","thinking":`)
		w_str(b, v.text)
		w_raw(b, `,"signature":`)
		w_str(b, v.signature)
		w_byte(b, '}')
		return false
	}
	return false
}

@(private)
anthropic_media :: proc(t: ^Transcript, kind, mime: string, data: []u8, url, text, title: string) {
	b := &t.buf
	w_raw(b, `{"type":`)
	w_str(b, kind)
	w_raw(b, `,"source":{"type":`)
	if url != "" {
		w_raw(b, `"url","url":`)
		w_str(b, url)
	} else if text != "" && len(data) == 0 {
		w_raw(b, `"text","media_type":"text/plain","data":`)
		w_str(b, text)
	} else {
		w_raw(b, `"base64","media_type":`)
		w_str(b, mime != "" ? mime : (kind == "document" ? "application/pdf" : "image/png"))
		w_raw(b, `,"data":"`)
		w_base64(b, data)
		w_byte(b, '"')
	}
	w_byte(b, '}')
	if title != "" {
		w_raw(b, `,"title":`)
		w_str(b, title)
	}
	w_byte(b, '}')
}

@(private)
anthropic_scan_native :: proc(t: ^Transcript, base: int, role: Role) {
	obj := t.buf[base:]
	t.text_bytes += len(obj)
	content, ok := j_get(obj, "content")
	if !ok {
		t.positions += 1
		return
	}
	it, aok := j_array(content)
	if !aok {
		t.positions += 1
		return
	}
	content_off := int(uintptr(raw_data(content)) - uintptr(raw_data(t.buf[:])))
	prev := ""
	for el in j_next(&it) {
		ty := j_get_raw_str(el, "type")
		if !(ty == prev && (ty == "tool_use" || ty == "tool_result")) {
			t.positions += 1
		}
		prev = ty
		if ty == ANTHROPIC_COMPACTION_BLOCK {
			t.compaction = true
		}
		switch ty {
		case "text", "image", "document", "tool_use", "tool_result":
			el_off := int(uintptr(raw_data(el)) - uintptr(raw_data(content))) + content_off
			t.mark = el_off + len(el) - 1
		}
	}
	t.last_role = role
	t.has_last = true
}

@(private)
anthropic_next :: proc(m: ^Model, s: ^Stream, out: ^[dynamic]Delta) -> bool {
	for {
		ev, ok := sse_next(&s.sse)
		if !ok {
			if s.sse.overflow && s.failure.class == .None {
				stream_fail(s, out, .Malformed, "overflow", "stream event exceeds the size limit")
				return true
			}
			return false
		}
		clear(&s.scratch)
		reserve(&s.scratch, len(ev.data))
		anthropic_event(s, ev, out)
		if len(out) > 0 {
			return true
		}
	}
}

@(private)
anthropic_event :: proc(s: ^Stream, ev: Sse_Event, out: ^[dynamic]Delta) {
	d := ev.data
	ty := j_get_raw_str(d, "type")
	if ty == "" {
		ty = ev.name
		if ty == "" {
			return
		}
		if !j_is_object(d) {
			stream_fail(s, out, .Malformed, "malformed", "malformed stream event")
			return
		}
	}
	switch ty {
	case ANTHROPIC_EVENT_PING:
		return
	case ANTHROPIC_EVENT_MESSAGE_START:
		msg, _ := j_get(d, "message")
		set_bytes(&s.msg_id, j_get_raw_str(msg, "id"))
		set_bytes(&s.model, j_get_raw_str(msg, "model"))
		s.started = true
		append(out, Delta{kind = .Start, id = string(s.msg_id[:]), name = string(s.model[:])})
		if u, ok := j_get(msg, "usage"); ok {
			anthropic_usage(s, u, out)
		}
	case ANTHROPIC_EVENT_BLOCK_START:
		idx := j_int(j_get_or(d, "index"))
		blk, ok := j_get(d, "content_block")
		a := acc_at(s, idx)
		if !ok || a == nil {
			stream_fail(s, out, .Malformed, "malformed", "malformed content_block_start")
			return
		}
		bt := j_get_raw_str(blk, "type")
		set_bytes(&a.type, bt)
		clear(&a.raw)
		append(&a.raw, ..blk)
		switch bt {
		case "text":
			a.kind = .Text
			if v, vok := j_get(blk, "text"); vok {
				txt := j_str(v, &s.scratch)
				append(&a.text, txt)
			}
			append(out, Delta{kind = .Block_Start, block = .Text, index = idx})
			if len(a.text) > 0 {
				append(out, Delta{kind = .Text, index = idx, text = string(a.text[:])})
			}
		case "thinking":
			a.kind = .Thinking
			append(out, Delta{kind = .Block_Start, block = .Thinking, index = idx})
		case "tool_use":
			a.kind = .Tool_Call
			set_bytes(&a.id, j_get_raw_str(blk, "id"))
			set_bytes(&a.name, j_get_str(blk, "name", &s.scratch))
			append(out, Delta{kind = .Block_Start, block = .Tool_Call, index = idx, id = string(a.id[:]), name = string(a.name[:])})
		case:
			a.kind = .Other
			append(out, Delta{kind = .Block_Start, block = .Other, index = idx, name = string(a.type[:])})
		}
	case ANTHROPIC_EVENT_BLOCK_DELTA:
		idx := j_int(j_get_or(d, "index"))
		a := acc_at(s, idx)
		delta, ok := j_get(d, "delta")
		if !ok || a == nil {
			stream_fail(s, out, .Malformed, "malformed", "malformed content_block_delta")
			return
		}
		dt := j_get_raw_str(delta, "type")
		switch dt {
		case ANTHROPIC_DELTA_TEXT:
			txt := j_get_str(delta, "text", &s.scratch)
			append(&a.text, txt)
			append(out, Delta{kind = .Text, index = idx, text = txt})
		case ANTHROPIC_DELTA_THINKING:
			txt := j_get_str(delta, "thinking", &s.scratch)
			append(&a.text, txt)
			if txt != "" {
				append(out, Delta{kind = .Thinking, index = idx, text = txt})
			}
		case ANTHROPIC_DELTA_SIGNATURE:
			append(&a.sig, j_get_str(delta, "signature", &s.scratch))
		case ANTHROPIC_DELTA_INPUT:
			txt := j_get_str(delta, "partial_json", &s.scratch)
			append(&a.text, txt)
			if a.kind == .Tool_Call {
				append(out, Delta{kind = .Tool_Input, index = idx, text = txt})
			}
		case ANTHROPIC_DELTA_CITATIONS:
			if c, cok := j_get(delta, "citation"); cok {
				if len(a.sig) > 0 {
					append(&a.sig, ',')
				}
				append(&a.sig, ..c)
			}
		}
	case ANTHROPIC_EVENT_BLOCK_STOP:
		idx := j_int(j_get_or(d, "index"))
		a := acc_at(s, idx)
		if a == nil {
			return
		}
		a.complete = true
		append(out, Delta{kind = .Block_Stop, block = a.kind, index = idx, id = string(a.id[:]), text = string(a.text[:])})
	case ANTHROPIC_EVENT_MESSAGE_DELTA:
		if delta, ok := j_get(d, "delta"); ok {
			if r, rok := j_get(delta, "stop_reason"); rok && !j_is_null(r) {
				rs, _ := j_raw_str(r)
				s.stop = anthropic_stop(rs)
				if det, dok := j_get(delta, "stop_details"); dok && !j_is_null(det) {
					clear(&s.detail)
					append(&s.detail, ..det)
				}
				append(out, Delta{kind = .Stop, stop = s.stop})
			}
		}
		if u, ok := j_get(d, "usage"); ok {
			anthropic_usage(s, u, out)
		}
	case ANTHROPIC_EVENT_MESSAGE_STOP:
		s.done = true
	case ANTHROPIC_EVENT_ERROR:
		e, _ := j_get(d, "error")
		et := j_get_raw_str(e, "type")
		msg := j_get_str(e, "message", &s.scratch)
		stream_fail(s, out, anthropic_error_class(et, msg), et, msg)
	}
}

@(private)
j_get_or :: proc "contextless" (obj: []u8, key: string) -> []u8 {
	v, _ := j_get(obj, key)
	return v
}

@(private)
anthropic_usage :: proc(s: ^Stream, u: []u8, out: ^[dynamic]Delta) {
	cu, fell := anthropic_usage_of(u)
	if fell {
		s.fell_back = true
	}
	usage_merge(&s.usage, cu)
	append(out, Delta{kind = .Usage, usage = s.usage})
}

@(private)
anthropic_warm_usage :: proc(m: ^Model, body: []u8) -> Call_Usage {
	u, ok := j_get(body, "usage")
	if !ok {
		return {}
	}
	cu, _ := anthropic_usage_of(u)
	return cu
}

@(private)
anthropic_usage_of :: proc(u: []u8) -> (Call_Usage, bool) {
	cu := Call_Usage {
		input      = j_get_u64(u, "input_tokens"),
		output     = j_get_u64(u, "output_tokens"),
		cache_read = j_get_u64(u, "cache_read_input_tokens"),
	}
	created := j_get_u64(u, "cache_creation_input_tokens")
	if cc, ok := j_get(u, "cache_creation"); ok && !j_is_null(cc) {
		long := j_get_u64(cc, "ephemeral_1h_input_tokens")
		cu.cache_long = long
		cu.cache_write = created > long ? created - long : j_get_u64(cc, "ephemeral_5m_input_tokens")
	} else {
		cu.cache_write = created
	}
	if od, ok := j_get(u, "output_tokens_details"); ok && !j_is_null(od) {
		cu.reasoning = j_get_u64(od, "thinking_tokens")
	}
	fell := false
	if its, ok := j_get(u, "iterations"); ok {
		if it, aok := j_array(its); aok {
			sum: Call_Usage
			for el in j_next(&it) {
				if j_get_raw_str(el, "type") == "fallback_message" {
					fell = true
				}
				sum.input += j_get_u64(el, "input_tokens")
				sum.output += j_get_u64(el, "output_tokens")
				sum.cache_read += j_get_u64(el, "cache_read_input_tokens")
				sum.cache_write += j_get_u64(el, "cache_creation_input_tokens")
			}
			if cu.input + cu.output + cu.cache_read + cu.cache_write == 0 {
				cu.input = sum.input
				cu.output = sum.output
				cu.cache_read = sum.cache_read
				cu.cache_write = sum.cache_write
			}
		}
	}
	return cu, fell
}

@(private)
anthropic_stop :: proc(r: string) -> Stop_Reason {
	switch r {
	case "end_turn":
		return .End_Turn
	case "tool_use":
		return .Tool_Use
	case "max_tokens":
		return .Max_Tokens
	case "stop_sequence":
		return .Stop_Sequence
	case "pause_turn":
		return .Pause_Turn
	case "refusal":
		return .Refusal
	case "model_context_window_exceeded":
		return .Context_Exceeded
	case "compaction":
		return .Compaction
	}
	return .Other
}

@(private)
anthropic_error_class :: proc(et, msg: string) -> Failure_Class {
	switch et {
	case "overloaded_error":
		return .Overloaded
	case "api_error", "timeout_error":
		return .Server
	case "rate_limit_error":
		return .Rate_Limited
	case "authentication_error", "permission_error":
		return .Auth
	case "billing_error":
		return .Quota
	case "request_too_large":
		return .Invalid
	case "invalid_request_error":
		if contains_fold(msg, "prompt is too long") || contains_fold(msg, "context window") || contains_fold(msg, "too many tokens") {
			return .Too_Long
		}
		return .Invalid
	}
	return .Server
}

@(private)
anthropic_classify :: proc(m: ^Model, status: int, headers: []Header, body: []u8) -> Failure {
	f := Failure {
		status = status,
		class  = status_class(status),
	}
	scratch := make([dynamic]u8, context.temp_allocator)
	if e, ok := j_get(body, "error"); ok {
		et := j_get_raw_str(e, "type")
		f.message = j_get_str(e, "message", &scratch)
		f.code = et
		cls := anthropic_error_class(et, f.message)
		if cls == .Too_Long {
			f.class = .Too_Long
		}
		if det, dok := j_get(e, "details"); dok {
			code := j_get_raw_str(det, "error_code")
			if code != "" {
				f.code = code
			}
			if code == ANTHROPIC_SPEND_CAP_CODE {
				f.class = .Quota
			}
		}
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
anthropic_finish :: proc(m: ^Model, s: ^Stream, t: ^Transcript, partial: bool) -> bool {
	start := len(t.buf)
	items := t.items
	positions := t.positions
	mark := t.mark
	item_begin(t)
	b := &t.buf
	w_raw(b, `{"role":"assistant","content":[`)
	n := 0
	prev := Block_Kind.Other
	last := s.used - 1
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		before := len(b)
		if n > 0 {
			w_byte(b, ',')
		}
		markable := false
		switch a.kind {
		case .Text:
			if len(a.text) == 0 || (!a.complete && !partial && i != last) {
				resize(b, before)
				continue
			}
			w_raw(b, `{"type":"text","text":`)
			w_str(b, string(a.text[:]))
			if len(a.sig) > 0 {
				w_raw(b, `,"citations":[`)
				append(b, ..a.sig[:])
				w_byte(b, ']')
			}
			w_byte(b, '}')
			markable = true
			t.text_bytes += len(a.text)
		case .Thinking:
			if !a.complete || len(a.sig) == 0 {
				resize(b, before)
				continue
			}
			w_raw(b, `{"type":"thinking","thinking":`)
			w_str(b, string(a.text[:]))
			w_raw(b, `,"signature":`)
			w_str(b, string(a.sig[:]))
			w_byte(b, '}')
			a.kept = true
			t.text_bytes += len(a.text) + len(a.sig)
		case .Tool_Call:
			if partial || !a.complete {
				resize(b, before)
				continue
			}
			splice_input(b, a.raw[:], a.text[:])
			markable = true
			t.text_bytes += len(a.raw) + len(a.text)
		case .Other:
			if partial || !a.complete {
				resize(b, before)
				continue
			}
			if len(a.text) > 0 {
				splice_input(b, a.raw[:], a.text[:])
			} else {
				append(b, ..a.raw[:])
			}
			if string(a.type[:]) == ANTHROPIC_COMPACTION_BLOCK {
				t.compaction = true
			}
			t.text_bytes += len(a.raw) + len(a.text)
		}
		n += 1
		if !(a.kind == .Tool_Call && prev == .Tool_Call) {
			t.positions += 1
		}
		prev = a.kind
		if markable {
			t.mark = len(b) - 1
		}
	}
	if n == 0 {
		resize(b, start)
		t.items = items
		t.positions = positions
		t.mark = mark
		return false
	}
	w_raw(b, `]}`)
	t.last_role = .Assistant
	t.has_last = true
	return true
}

@(private)
splice_input :: proc(b: ^[dynamic]u8, raw: []u8, input: []u8) {
	v, ok := j_get(raw, "input")
	in_ok := len(input) > 0 && j_valid(input) && j_is_object(input)
	if !ok {
		append(b, ..raw)
		return
	}
	off := int(uintptr(raw_data(v)) - uintptr(raw_data(raw)))
	append(b, ..raw[:off])
	if in_ok {
		append(b, ..input)
	} else if len(input) == 0 {
		append(b, ..v)
	} else {
		append(b, "{}")
	}
	append(b, ..raw[off + len(v):])
}

@(private)
anthropic_compacted :: proc(m: ^Model, s: ^Stream, t: ^Transcript, summary: ^[dynamic]u8) -> bool {
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		if a.kind != .Other || !a.complete || string(a.type[:]) != ANTHROPIC_COMPACTION_BLOCK {
			continue
		}
		scratch := make([dynamic]u8, context.temp_allocator)
		append(summary, j_get_str(a.raw[:], "content", &scratch))
		item_begin(t)
		b := &t.buf
		w_raw(b, `{"role":"user","content":[`)
		append(b, ..a.raw[:])
		w_raw(b, `,{"type":"text","text":`)
		w_str(b, COMPACT_RESUME_TEXT)
		w_byte(b, '}')
		t.mark = len(b) - 1
		w_raw(b, `]}`)
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
anthropic_state_code :: proc(m: ^Model, f: Failure) -> State_Fault {
	for c in ANTHROPIC_STATE_RESET_CODES {
		if f.code == c {
			return .Replay
		}
	}
	for c in ANTHROPIC_STATE_OFF_CODES {
		if f.code == c {
			return .Disable
		}
	}
	return .None
}

anthropic_warm_tail :: proc(t: ^Transcript, dst: ^[dynamic]u8) {
	if t.items > 0 {
		append(dst, ',')
	}
	w_raw(dst, `{"role":"user","content":[{"type":"text","text":`)
	w_str(dst, ANTHROPIC_KEEPALIVE_TEXT)
	w_raw(dst, `}]}`)
}

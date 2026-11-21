package model

CHAT_TEXT_INDEX :: 0
CHAT_THINK_INDEX :: 1
CHAT_TOOL_BASE :: 2

chat_model :: proc() -> Model {
	return Model {
		api = .OpenAI_Chat,
		encode = chat_encode,
		head = chat_head,
		tail = json_tail,
		next = chat_next,
		finish = chat_finish,
		classify = openai_classify,
		marker = no_marker,
		auth = openai_auth,
	}
}

@(private)
chat_head :: proc(m: ^Model, cfg: ^Config, ctx: ^Context, opts: ^Request_Opts, dst: ^[dynamic]u8) {
	b := dst
	w_raw(b, `{"model":`)
	w_str(b, cfg.spec.id)
	w_raw(b, `,"stream":true,"stream_options":{"include_usage":true},"max_completion_tokens":`)
	w_uint(b, max_tokens(cfg))
	if cfg.effort != .Default {
		w_raw(b, `,"reasoning_effort":`)
		w_str(b, effort_name(cfg.effort))
	}
	if cfg.cache_key != "" {
		w_raw(b, `,"prompt_cache_key":`)
		w_str(b, cfg.cache_key)
	}
	if len(ctx.tools) > 0 {
		w_raw(b, `,"parallel_tool_calls":`)
		w_raw(b, cfg.serial_tools ? "false" : "true")
		w_raw(b, `,"tools":[`)
		for t, i in ctx.tools {
			if i > 0 {
				w_byte(b, ',')
			}
			w_raw(b, `{"type":"function","function":{"name":`)
			w_str(b, t.name)
			if t.description != "" {
				w_raw(b, `,"description":`)
				w_str(b, t.description)
			}
			w_raw(b, `,"parameters":`)
			w_raw(b, schema_or_default(t.schema))
			if t.strict {
				w_raw(b, `,"strict":true`)
			}
			w_raw(b, `}}`)
		}
		w_byte(b, ']')
	}
	w_raw(b, `,"messages":[`)
	if ctx.system != "" {
		w_raw(b, `{"role":"system","content":`)
		w_str(b, ctx.system)
		w_raw(b, `},`)
	}
}

@(private)
chat_encode :: proc(m: ^Model, cfg: ^Config, msg: ^Message, t: ^Transcript) {
	if msg.native != "" && msg.native_api == .OpenAI_Chat {
		it, ok := j_array(transmute([]u8)msg.native)
		if ok {
			for el in j_next(&it) {
				item_begin(t)
				append(&t.buf, ..el)
				t.text_bytes += len(el)
			}
			t.positions += 1
			t.last_role = msg.role
			t.has_last = true
			return
		}
	}
	b := &t.buf
	if msg.role == .Assistant {
		text_n := 0
		tool_n := 0
		for &blk in msg.blocks {
			#partial switch v in blk {
			case Text:
				if v.text != "" {
					text_n += 1
				}
			case Tool_Use:
				tool_n += 1
			}
		}
		if text_n == 0 && tool_n == 0 {
			return
		}
		item_begin(t)
		w_raw(b, `{"role":"assistant","content":`)
		if text_n == 0 {
			w_raw(b, "null")
		} else {
			w_byte(b, '"')
			for &blk in msg.blocks {
				if v, ok := blk.(Text); ok {
					w_escaped(b, transmute([]u8)v.text)
					t.text_bytes += len(v.text)
				}
			}
			w_byte(b, '"')
		}
		if tool_n > 0 {
			w_raw(b, `,"tool_calls":[`)
			k := 0
			for &blk in msg.blocks {
				if v, ok := blk.(Tool_Use); ok {
					if k > 0 {
						w_byte(b, ',')
					}
					w_raw(b, `{"id":`)
					w_str(b, v.id)
					w_raw(b, `,"type":"function","function":{"name":`)
					w_str(b, v.name)
					w_raw(b, `,"arguments":`)
					w_str(b, v.input != "" ? v.input : "{}")
					w_raw(b, `}}`)
					t.text_bytes += len(v.input)
					k += 1
				}
			}
			w_byte(b, ']')
		}
		w_byte(b, '}')
		t.positions += 1
		t.last_role = .Assistant
		t.has_last = true
		return
	}
	for &blk in msg.blocks {
		if v, ok := blk.(Tool_Result); ok {
			item_begin(t)
			w_raw(b, `{"role":"tool","tool_call_id":`)
			w_str(b, v.id)
			w_raw(b, `,"content":"`)
			if v.is_error {
				w_raw(b, "Error: ")
			}
			for &c in v.content {
				if tx, tok := c.(Text); tok {
					w_escaped(b, transmute([]u8)tx.text)
					t.text_bytes += len(tx.text)
				}
			}
			w_raw(b, `"}`)
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
			if !chat_part(t, &blk) {
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
chat_part :: proc(t: ^Transcript, blk: ^Block) -> bool {
	b := &t.buf
	#partial switch v in blk {
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
		w_raw(b, `{"type":"image_url","image_url":{"url":`)
		if v.url != "" {
			w_str(b, v.url)
		} else {
			w_raw(b, `"data:`)
			w_raw(b, v.mime != "" ? v.mime : "image/png")
			w_raw(b, `;base64,`)
			w_base64(b, v.data)
			w_byte(b, '"')
		}
		w_raw(b, `}}`)
		t.media += 1
		t.media_tok += 1600
		return true
	case Document:
		if len(v.data) == 0 {
			if v.text == "" {
				return false
			}
			w_raw(b, `{"type":"text","text":`)
			w_str(b, v.text)
			w_byte(b, '}')
			t.text_bytes += len(v.text)
			return true
		}
		w_raw(b, `{"type":"file","file":{"filename":`)
		w_str(b, v.title != "" ? v.title : "document.pdf")
		w_raw(b, `,"file_data":"data:`)
		w_raw(b, v.mime != "" ? v.mime : "application/pdf")
		w_raw(b, `;base64,`)
		w_base64(b, v.data)
		w_raw(b, `"}}`)
		t.media += 1
		t.media_tok += u64(len(v.data)) / 1000
		return true
	}
	return false
}

@(private)
chat_next :: proc(m: ^Model, s: ^Stream, out: ^[dynamic]Delta) -> bool {
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
		chat_event(s, ev, out)
		if len(out) > 0 {
			return true
		}
	}
}

@(private)
chat_open :: proc(s: ^Stream, out: ^[dynamic]Delta, idx: int, kind: Block_Kind) -> ^Acc {
	a := acc_at(s, idx)
	if a == nil {
		return nil
	}
	bit := 1 << uint(min(idx, 62))
	if s.chat_open & bit == 0 {
		s.chat_open |= bit
		a.kind = kind
		a.index = idx
		if kind != .Tool_Call {
			append(out, Delta{kind = .Block_Start, block = kind, index = idx})
		}
	}
	return a
}

@(private)
chat_event :: proc(s: ^Stream, ev: Sse_Event, out: ^[dynamic]Delta) {
	d := ev.data
	if string(d) == OPENAI_CHAT_DONE {
		chat_close(s, out)
		s.done = true
		return
	}
	if !j_is_object(d) {
		stream_fail(s, out, .Malformed, "malformed", "malformed stream chunk")
		return
	}
	if e, ok := j_get(d, "error"); ok && !j_is_null(e) {
		code := j_get_raw_str(e, "code")
		if code == "" {
			code = j_get_raw_str(e, "type")
		}
		msg := j_get_str(e, "message", &s.scratch)
		stream_fail(s, out, openai_code_class(code, msg, .Server), code, msg)
		return
	}
	if !s.started {
		s.started = true
		set_bytes(&s.msg_id, j_get_raw_str(d, "id"))
		set_bytes(&s.model, j_get_raw_str(d, "model"))
		append(out, Delta{kind = .Start, id = string(s.msg_id[:]), name = string(s.model[:])})
	}
	if choices, ok := j_get(d, "choices"); ok {
		it, aok := j_array(choices)
		if aok {
			if ch, has := j_next(&it); has {
				chat_choice(s, ch, out)
			}
		}
	}
	if u, ok := j_get(d, "usage"); ok && !j_is_null(u) {
		prompt := j_get_u64(u, "prompt_tokens")
		cu := Call_Usage {
			output = j_get_u64(u, "completion_tokens"),
		}
		if det, dok := j_get(u, "prompt_tokens_details"); dok && !j_is_null(det) {
			cu.cache_read = j_get_u64(det, "cached_tokens")
		}
		if det, dok := j_get(u, "completion_tokens_details"); dok && !j_is_null(det) {
			cu.reasoning = j_get_u64(det, "reasoning_tokens")
		}
		cu.input = prompt > cu.cache_read ? prompt - cu.cache_read : 0
		usage_merge(&s.usage, cu)
		append(out, Delta{kind = .Usage, usage = s.usage})
	}
}

@(private)
chat_choice :: proc(s: ^Stream, ch: []u8, out: ^[dynamic]Delta) {
	if delta, ok := j_get(ch, "delta"); ok && !j_is_null(delta) {
		if v, vok := j_get(delta, "reasoning_content"); vok && !j_is_null(v) {
			chat_think(s, out, j_str(v, &s.scratch))
		} else if v2, v2ok := j_get(delta, "reasoning"); v2ok && !j_is_null(v2) {
			chat_think(s, out, j_str(v2, &s.scratch))
		}
		if v, vok := j_get(delta, "content"); vok && !j_is_null(v) {
			txt := j_str(v, &s.scratch)
			if txt != "" {
				a := chat_open(s, out, CHAT_TEXT_INDEX, .Text)
				append(&a.text, txt)
				append(out, Delta{kind = .Text, index = CHAT_TEXT_INDEX, text = txt})
			}
		}
		if v, vok := j_get(delta, "refusal"); vok && !j_is_null(v) {
			txt := j_str(v, &s.scratch)
			s.stop = .Refusal
			if txt != "" {
				a := chat_open(s, out, CHAT_TEXT_INDEX, .Text)
				append(&a.text, txt)
				append(out, Delta{kind = .Text, index = CHAT_TEXT_INDEX, text = txt})
			}
		}
		if calls, cok := j_get(delta, "tool_calls"); cok && !j_is_null(calls) {
			it, aok := j_array(calls)
			for aok {
				c, more := j_next(&it)
				if !more {
					break
				}
				ti := j_int(j_get_or(c, "index"))
				if ti < 0 || ti > 4096 {
					continue
				}
				idx := CHAT_TOOL_BASE + ti
				a := acc_at(s, idx)
				if a == nil {
					continue
				}
				fresh := s.chat_open & (1 << uint(min(idx, 62))) == 0
				chat_open(s, out, idx, .Tool_Call)
				if id := j_get_raw_str(c, "id"); id != "" {
					set_bytes(&a.id, id)
				}
				f, _ := j_get(c, "function")
				if name, nok := j_get(f, "name"); nok && !j_is_null(name) {
					set_bytes(&a.name, j_str(name, &s.scratch))
				}
				if fresh {
					append(out, Delta{kind = .Block_Start, block = .Tool_Call, index = idx, id = string(a.id[:]), name = string(a.name[:])})
				}
				if args, aok2 := j_get(f, "arguments"); aok2 && !j_is_null(args) {
					txt := j_str(args, &s.scratch)
					if txt != "" {
						append(&a.text, txt)
						append(out, Delta{kind = .Tool_Input, index = idx, text = txt})
					}
				}
			}
		}
	}
	if fr, ok := j_get(ch, "finish_reason"); ok && !j_is_null(fr) {
		r, _ := j_raw_str(fr)
		switch r {
		case "stop":
			if s.stop != .Refusal {
				s.stop = .End_Turn
			}
		case "length":
			s.stop = .Max_Tokens
		case "tool_calls", "function_call":
			s.stop = .Tool_Use
		case "content_filter":
			s.stop = .Refusal
		case:
			s.stop = .Other
		}
		chat_close(s, out)
		append(out, Delta{kind = .Stop, stop = s.stop})
	}
}

@(private)
chat_think :: proc(s: ^Stream, out: ^[dynamic]Delta, txt: string) {
	if txt == "" {
		return
	}
	a := chat_open(s, out, CHAT_THINK_INDEX, .Thinking)
	append(&a.text, txt)
	append(out, Delta{kind = .Thinking, index = CHAT_THINK_INDEX, text = txt})
}

@(private)
chat_close :: proc(s: ^Stream, out: ^[dynamic]Delta) {
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		if s.chat_open & (1 << uint(min(i, 62))) != 0 && !a.complete {
			a.complete = true
			append(out, Delta{kind = .Block_Stop, block = a.kind, index = i, id = string(a.id[:]), text = string(a.text[:])})
		}
	}
	if s.stop == .None {
		s.stop = .End_Turn
		for i in CHAT_TOOL_BASE ..< s.used {
			if s.blocks[i].kind == .Tool_Call && s.blocks[i].complete {
				s.stop = .Tool_Use
			}
		}
	}
	if s.stop != .None {
		s.done = true
	}
}

@(private)
chat_finish :: proc(m: ^Model, s: ^Stream, t: ^Transcript, partial: bool) -> bool {
	text: []u8
	if s.used > CHAT_TEXT_INDEX && s.blocks[CHAT_TEXT_INDEX].kind == .Text {
		text = s.blocks[CHAT_TEXT_INDEX].text[:]
	}
	tools := 0
	if !partial {
		for i in CHAT_TOOL_BASE ..< max(s.used, CHAT_TOOL_BASE) {
			a := &s.blocks[i]
			if a.kind == .Tool_Call && a.complete && len(a.id) > 0 {
				tools += 1
			}
		}
	}
	if len(text) == 0 && tools == 0 {
		return false
	}
	b := &t.buf
	item_begin(t)
	w_raw(b, `{"role":"assistant","content":`)
	if len(text) == 0 {
		w_raw(b, "null")
	} else {
		w_byte(b, '"')
		w_escaped(b, text)
		w_byte(b, '"')
		t.text_bytes += len(text)
	}
	if tools > 0 {
		w_raw(b, `,"tool_calls":[`)
		k := 0
		for i in CHAT_TOOL_BASE ..< s.used {
			a := &s.blocks[i]
			if a.kind != .Tool_Call || !a.complete || len(a.id) == 0 {
				continue
			}
			if k > 0 {
				w_byte(b, ',')
			}
			w_raw(b, `{"id":`)
			w_str(b, string(a.id[:]))
			w_raw(b, `,"type":"function","function":{"name":`)
			w_str(b, string(a.name[:]))
			w_raw(b, `,"arguments":`)
			w_str(b, len(a.text) > 0 ? string(a.text[:]) : "{}")
			w_raw(b, `}}`)
			t.text_bytes += len(a.text)
			k += 1
		}
		w_byte(b, ']')
	}
	w_byte(b, '}')
	t.positions += 1
	t.last_role = .Assistant
	t.has_last = true
	return true
}

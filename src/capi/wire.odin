package capi

import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "./api"
import "../http"
import "../model"

C_Wire_Event :: struct {
	kind:        u32,
	block:       u32,
	index:       i32,
	id:          cstring,
	id_len:      uint,
	name:        cstring,
	name_len:    uint,
	text:        cstring,
	text_len:    uint,
	input:       u64,
	output:      u64,
	cache_read:  u64,
	cache_write: u64,
	reasoning:   u64,
	stop:        u32,
	failure:     u32,
	retry_after: i64,
}

C_Wire :: struct {
	size:     u32,
	ud:       rawptr,
	head:     proc "c" (ud: rawptr, request: [^]u8, len: uint, out: ^Sink) -> i32,
	message:  proc "c" (ud: rawptr, message: [^]u8, len: uint, out: ^Sink) -> i32,
	tail:     proc "c" (ud: rawptr, kind: u32, out: ^Sink) -> i32,
	headers:  proc "c" (ud: rawptr, api_key: cstring, key_len: uint, out: ^Sink) -> i32,
	parse:    proc "c" (ud: rawptr, stream: u64, event: cstring, event_len: uint, data: [^]u8, data_len: uint, emit: ^Emit) -> i32,
	classify: proc "c" (ud: rawptr, status: i32, body: [^]u8, len: uint, retry_after: ^i64) -> i32,
}

Sink :: struct {
	buf: ^[dynamic]u8,
}

Emit :: struct {
	s:   ^model.Stream,
	out: ^[dynamic]model.Delta,
}

Wire_Ctx :: struct {
	w: C_Wire,
}

@(export, link_name = "ondb_sink_write")
ondb_sink_write :: proc "c" (sink: ^Sink, data: [^]u8, len: uint) -> i32 {
	if sink == nil || sink.buf == nil || (data == nil && len > 0) {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	if len > 0 {
		append(sink.buf, ..data[:len])
	}
	return 0
}

@(export, link_name = "ondb_wire_emit")
ondb_wire_emit :: proc "c" (emit: ^Emit, ev: ^C_Wire_Event) -> i32 {
	if emit == nil || ev == nil || ev.kind > u32(max(model.Delta_Kind)) {
		return i32(api.Status.Invalid)
	}
	context = _ctx()
	s := emit.s
	d := model.Delta {
		kind  = model.Delta_Kind(ev.kind),
		block = model.Block_Kind(min(ev.block, u32(max(model.Block_Kind)))),
		index = int(ev.index),
		id    = strings.clone(_cslice(ev.id, ev.id_len), context.temp_allocator),
		name  = strings.clone(_cslice(ev.name, ev.name_len), context.temp_allocator),
		text  = strings.clone(_cslice(ev.text, ev.text_len), context.temp_allocator),
	}
	switch d.kind {
	case .Start:
		s.started = true
		if len(d.id) > 0 {
			clear(&s.msg_id)
			append(&s.msg_id, d.id)
		}
	case .Block_Start:
		if d.index < 0 || d.index > 4096 {
			return i32(api.Status.Invalid)
		}
		for s.used <= d.index {
			if s.used == len(s.blocks) {
				append(&s.blocks, model.Acc{})
			}
			_acc_clear(&s.blocks[s.used])
			s.blocks[s.used].index = s.used
			s.used += 1
		}
		a := &s.blocks[d.index]
		a.kind = d.block
		clear(&a.id)
		append(&a.id, d.id)
		clear(&a.name)
		append(&a.name, d.name)
	case .Text, .Thinking, .Tool_Input:
		if d.index < 0 || d.index >= s.used {
			return i32(api.Status.Invalid)
		}
		append(&s.blocks[d.index].text, d.text)
	case .Block_Stop:
		if d.index < 0 || d.index >= s.used {
			return i32(api.Status.Invalid)
		}
		s.blocks[d.index].complete = true
	case .Usage:
		u := model.Call_Usage{input = ev.input, output = ev.output, cache_read = ev.cache_read, cache_write = ev.cache_write, reasoning = ev.reasoning}
		s.usage.input = max(s.usage.input, u.input)
		s.usage.output = max(s.usage.output, u.output)
		s.usage.cache_read = max(s.usage.cache_read, u.cache_read)
		s.usage.cache_write = max(s.usage.cache_write, u.cache_write)
		s.usage.reasoning = max(s.usage.reasoning, u.reasoning)
		d.usage = u
	case .Stop:
		d.stop = model.Stop_Reason(min(ev.stop, u32(max(model.Stop_Reason))))
		s.stop = d.stop
		s.done = true
	case .Error:
		cls := model.Failure_Class(min(ev.failure, u32(max(model.Failure_Class))))
		model.stream_fail(s, emit.out, cls if cls != .None else .Server, "wire", d.text)
		s.failure.retry_after = ev.retry_after
		return 0
	}
	append(emit.out, d)
	return 0
}

wire_model :: proc(h: ^Handle, w: ^C_Wire, a: model.Api) -> (m: model.Model, ok: bool) {
	tmp: C_Wire
	if !_copy_table(&tmp, w) || tmp.head == nil || tmp.message == nil || tmp.tail == nil || tmp.parse == nil {
		return {}, false
	}
	ctx: ^Wire_Ctx
	for x in h.rt.wires {
		if x.w == tmp {
			ctx = x
		}
	}
	if ctx == nil {
		ctx = new(Wire_Ctx, h.allocator)
		ctx.w = tmp
		append(&h.rt.wires, ctx)
	}
	return model.Model {
		data       = ctx,
		api        = a,
		encode     = _wire_encode,
		head       = _wire_head,
		tail       = _wire_tail,
		next       = _wire_next,
		finish     = _wire_finish,
		classify   = _wire_classify,
		marker     = _wire_marker,
		auth       = _wire_auth,
	}, true
}

@(private)
_wire :: proc(m: ^model.Model) -> ^C_Wire {
	return &(^Wire_Ctx)(m.data).w
}

@(private)
_wire_head :: proc(m: ^model.Model, cfg: ^model.Config, mc: ^model.Context, opts: ^model.Request_Opts, dst: ^[dynamic]u8) {
	w := _wire(m)
	b := make([dynamic]u8, context.temp_allocator)
	put :: proc(b: ^[dynamic]u8, parts: ..string) {
		for p in parts {
			append(b, p)
		}
	}
	nb: [32]u8
	mt := cfg.max_tokens if cfg.max_tokens > 0 else cfg.spec.max_output
	put(&b, `{"model":`)
	api.json_string(&b, cfg.spec.id)
	put(&b, `,"max_tokens":`, strconv.write_uint(nb[:], mt, 10), `,"kind":`)
	api.json_string(&b, KIND_WIRE[opts.kind] if int(opts.kind) < len(KIND_WIRE) else "normal")
	put(&b, `,"system":`)
	api.json_string(&b, mc.system)
	put(&b, `,"tools":[`)
	for t, i in mc.tools {
		if i > 0 {
			append(&b, ',')
		}
		put(&b, `{"name":`)
		api.json_string(&b, t.name)
		put(&b, `,"description":`)
		api.json_string(&b, t.description)
		put(&b, `,"schema":`, t.schema if len(t.schema) > 0 else `{"type":"object"}`, "}")
	}
	put(&b, "]}")
	sink := Sink{dst}
	w.head(w.ud, raw_data(b), uint(len(b)), &sink)
}

KIND_WIRE := [3]string{"normal", "compact", "keepalive"}

@(private)
_wire_tail :: proc(m: ^model.Model, cfg: ^model.Config, kind: model.Request_Kind, dst: ^[dynamic]u8) {
	w := _wire(m)
	sink := Sink{dst}
	w.tail(w.ud, u32(kind), &sink)
}

@(private)
_wire_block :: proc(b: ^[dynamic]u8, blk: ^model.Block) {
	str :: proc(b: ^[dynamic]u8, k: string, v: string) {
		append(b, ',')
		api.json_string(b, k)
		append(b, ':')
		api.json_string(b, v)
	}
	switch v in blk {
	case model.Text:
		append(b, `{"type":"text"`)
		str(b, "text", v.text)
	case model.Image:
		append(b, `{"type":"image"`)
		str(b, "mime", v.mime)
		str(b, "data", base64.encode(v.data, allocator = context.temp_allocator) if len(v.data) > 0 else "")
		str(b, "url", v.url)
	case model.Document:
		append(b, `{"type":"document"`)
		str(b, "mime", v.mime)
		str(b, "title", v.title)
		str(b, "text", v.text)
		str(b, "data", base64.encode(v.data, allocator = context.temp_allocator) if len(v.data) > 0 else "")
		str(b, "url", v.url)
	case model.Tool_Use:
		append(b, `{"type":"tool_use"`)
		str(b, "id", v.id)
		str(b, "name", v.name)
		str(b, "input", v.input if len(v.input) > 0 else "{}")
	case model.Tool_Result:
		append(b, `{"type":"tool_result"`)
		str(b, "id", v.id)
		append(b, `,"is_error":`)
		append(b, "true" if v.is_error else "false")
		append(b, `,"content":[`)
		for &c, i in v.content {
			if i > 0 {
				append(b, ',')
			}
			_wire_block(b, &c)
		}
		append(b, ']')
	case model.Thinking:
		append(b, `{"type":"thinking"`)
		str(b, "text", v.text)
		str(b, "signature", v.signature)
	}
	append(b, '}')
}

@(private)
_wire_encode :: proc(m: ^model.Model, cfg: ^model.Config, msg: ^model.Message, t: ^model.Transcript) {
	w := _wire(m)
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, `{"role":"`)
	append(&b, "assistant" if msg.role == .Assistant else "user")
	append(&b, `","blocks":[`)
	for &blk, i in msg.blocks {
		if i > 0 {
			append(&b, ',')
		}
		_wire_block(&b, &blk)
	}
	append(&b, "]}")
	item := make([dynamic]u8, context.temp_allocator)
	sink := Sink{&item}
	if w.message(w.ud, raw_data(b), uint(len(b)), &sink) != 0 || len(item) == 0 {
		return
	}
	if t.items > 0 {
		append(&t.buf, ',')
	}
	t.items += 1
	append(&t.buf, ..item[:])
	t.text_bytes += len(item)
	t.positions += 1
	t.last_role = msg.role
	t.has_last = true
}

@(private)
_wire_next :: proc(m: ^model.Model, s: ^model.Stream, out: ^[dynamic]model.Delta) -> bool {
	w := _wire(m)
	for {
		ev, ok := http.sse_next(&s.sse)
		if !ok {
			if s.sse.overflow && s.failure.class == .None {
				model.stream_fail(s, out, .Malformed, "overflow", "stream event exceeds the size limit")
				return true
			}
			return false
		}
		e := Emit{s, out}
		ep, en := _cstr(ev.name)
		if w.parse(w.ud, u64(uintptr(s)), ep, en, raw_data(ev.data), uint(len(ev.data)), &e) != 0 && s.failure.class == .None {
			model.stream_fail(s, out, .Malformed, "wire", "the wire plug could not parse a stream event")
		}
		if len(out) > 0 {
			return true
		}
	}
}

@(private)
_wire_finish :: proc(m: ^model.Model, s: ^model.Stream, t: ^model.Transcript, partial: bool) -> bool {
	blocks := make([dynamic]model.Block, context.temp_allocator)
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		switch a.kind {
		case .Text:
			if len(a.text) > 0 {
				append(&blocks, model.Text{text = string(a.text[:])})
			}
		case .Thinking:
			if len(a.text) > 0 {
				append(&blocks, model.Thinking{text = string(a.text[:]), signature = string(a.sig[:])})
			}
		case .Tool_Call:
			if a.complete && len(a.id) > 0 && !partial {
				append(&blocks, model.Tool_Use{id = string(a.id[:]), name = string(a.name[:]), input = string(a.text[:])})
			}
		case .Other:
		}
	}
	if len(blocks) == 0 {
		return false
	}
	msg := model.Message{role = .Assistant, blocks = blocks[:]}
	_wire_encode(m, nil, &msg, t)
	return true
}

@(private)
_wire_classify :: proc(m: ^model.Model, status: int, headers: []model.Header, body: []u8) -> model.Failure {
	w := _wire(m)
	f := model.Failure{status = status, message = string(body[:min(len(body), 2000)])}
	if v, ok := http.header_find(headers, "retry-after"); ok {
		if n, nok := strconv.parse_i64(strings.trim_space(v)); nok {
			f.retry_after = n * 1000
		}
	}
	if w.classify != nil {
		ra := f.retry_after
		c := w.classify(w.ud, i32(status), raw_data(body), uint(len(body)), &ra)
		if c > 0 && c <= i32(max(model.Failure_Class)) {
			f.class = model.Failure_Class(c)
			f.retry_after = ra
			return f
		}
	}
	switch {
	case status == 401 || status == 403:
		f.class = .Auth
	case status == 429:
		f.class = .Rate_Limited
	case status == 413:
		f.class = .Too_Long
	case status == 529:
		f.class = .Overloaded
	case status >= 500 || status == 408:
		f.class = .Server
	case status == 402:
		f.class = .Quota
	case:
		f.class = .Invalid
	}
	return f
}

@(private)
_wire_marker :: proc(m: ^model.Model, cfg: ^model.Config) -> string {
	return ""
}

@(private)
_wire_auth :: proc(m: ^model.Model, cfg: ^model.Config, opts: ^model.Request_Opts, dst: ^[dynamic]model.Header) {
	w := _wire(m)
	if w.headers == nil {
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	sink := Sink{&buf}
	kp, kn := _cstr(cfg.api_key)
	w.headers(w.ud, kp, kn, &sink)
	text := string(buf[:])
	for line in strings.split_lines_iterator(&text) {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		append(dst, model.Header{name = strings.trim_space(line[:colon]), value = strings.trim_space(line[colon + 1:])})
	}
}

@(private)
_acc_clear :: proc(a: ^model.Acc) {
	clear(&a.id)
	clear(&a.name)
	clear(&a.type)
	clear(&a.text)
	clear(&a.sig)
	clear(&a.raw)
	a.complete = false
	a.kept = false
	a.emitted = false
	a.kind = .Other
}

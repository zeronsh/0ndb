package model

import "base:runtime"
import "core:strings"
import "../agent"

Phase :: enum u8 {
	Idle,
	Calling,
	Waiting,
	Tools,
	Done,
}

Pending_Tool :: struct {
	id:       string,
	name:     string,
	input:    string,
	content:  []Block,
	is_error: bool,
	done:     bool,
	run:      bool,
}

Steer_Item :: struct {
	id:    string,
	text:  string,
	files: []agent.Attachment,
}

Run :: struct {
	allocator:   runtime.Allocator,
	cfg:         Config,
	model:       Model,
	ctx:         Context,
	t:           Transcript,
	head:        [dynamic]u8,
	tailbuf:     [dynamic]u8,
	extra:       [dynamic]u8,
	segs:        [dynamic][]u8,
	stream:      Stream,
	deltas:      [dynamic]Delta,
	err_body:    [dynamic]u8,
	request_id:  [dynamic]u8,
	pending:     [dynamic]Pending_Tool,
	steer:       [dynamic]Steer_Item,
	started:     [dynamic]int,
	turn:        string,
	phase:       Phase,
	kind:        Request_Kind,
	status:      int,
	not_sse:     bool,
	retry_after: i64,
	should:      i8,
	emitted:     bool,
	announced:   bool,
	attempt:     int,
	resumes:     int,
	retry_at:    i64,
	deadline:    i64,
	began:       i64,
	steps:       int,
	total:       Call_Usage,
	cost:        f64,
	last_ctx:    u64,
	last_text:   int,
	last_media:  u64,
	compacted:   bool,
	last_status: int,
	last_reason: string,
}

RUN_MAX_ERROR_BODY :: 1 << 20
RUN_TRIM_BYTES :: 64 << 10

run_init :: proc(r: ^Run, cfg: Config, model: Model, allocator := context.allocator) {
	r^ = {}
	r.allocator = allocator
	context.allocator = allocator
	r.cfg = cfg
	r.cfg.url = strings.clone(cfg.url)
	r.cfg.api_key = strings.clone(cfg.api_key)
	r.cfg.cache_key = strings.clone(cfg.cache_key)
	r.cfg.spec.id = strings.clone(cfg.spec.id)
	hs := make([]string, len(cfg.headers))
	for h, i in cfg.headers {
		hs[i] = strings.clone(h)
	}
	r.cfg.headers = hs
	r.model = model
	r.t.buf = make([dynamic]u8)
	r.head = make([dynamic]u8)
	r.tailbuf = make([dynamic]u8)
	r.extra = make([dynamic]u8)
	r.segs = make([dynamic][]u8)
	r.deltas = make([dynamic]Delta)
	r.err_body = make([dynamic]u8)
	r.request_id = make([dynamic]u8)
	r.pending = make([dynamic]Pending_Tool)
	r.steer = make([dynamic]Steer_Item)
	r.started = make([dynamic]int)
	stream_init(&r.stream, allocator)
}

run_destroy :: proc(r: ^Run) {
	context.allocator = r.allocator
	delete(r.cfg.url)
	delete(r.cfg.api_key)
	delete(r.cfg.cache_key)
	delete(r.cfg.spec.id)
	for h in r.cfg.headers {
		delete(h)
	}
	delete(r.cfg.headers)
	drop_context(r)
	delete(r.t.buf)
	delete(r.head)
	delete(r.tailbuf)
	delete(r.extra)
	delete(r.segs)
	delete(r.deltas)
	delete(r.err_body)
	delete(r.request_id)
	clear_pending(r)
	delete(r.pending)
	clear_steer(r)
	delete(r.steer)
	delete(r.started)
	delete(r.turn)
	stream_destroy(&r.stream)
	r^ = {}
}

run_footprint :: proc(r: ^Run) -> int {
	n := size_of(Run) + cap(r.t.buf) + cap(r.head) + cap(r.tailbuf) + cap(r.extra) + cap(r.err_body)
	n += cap(r.segs) * size_of([]u8) + cap(r.deltas) * size_of(Delta) + cap(r.pending) * size_of(Pending_Tool)
	n += len(r.ctx.system)
	for t in r.ctx.tools {
		n += size_of(Tool_Def) + len(t.name) + len(t.description) + len(t.schema)
	}
	return n + stream_footprint(&r.stream)
}

run_active :: proc(r: ^Run) -> bool {
	return r.phase != .Idle && r.phase != .Done
}

run_transcript :: proc(r: ^Run) -> []u8 {
	return r.t.buf[:]
}

run_start :: proc(r: ^Run, ctx: ^Context, turn: string, now: i64, out: ^Output) {
	context.allocator = r.allocator
	drop_context(r)
	r.ctx.system = strings.clone(ctx.system)
	tools := make([]Tool_Def, len(ctx.tools))
	for t, i in ctx.tools {
		tools[i] = Tool_Def {
			name        = strings.clone(t.name),
			description = strings.clone(t.description),
			schema      = strings.clone(t.schema),
			strict      = t.strict,
			eager       = t.eager,
		}
	}
	r.ctx.tools = tools
	delete(r.turn)
	r.turn = strings.clone(turn)
	clear(&r.t.buf)
	r.t = Transcript {
		buf = r.t.buf,
	}
	for &m in ctx.messages {
		r.model.encode(&r.model, &r.cfg, &m, &r.t)
	}
	r.t.prev_mark = r.t.mark
	r.t.prev_pos = r.t.positions
	r.began = now
	r.deadline = r.cfg.budget.wall_ms > 0 ? now + r.cfg.budget.wall_ms * 1_000_000 : 0
	r.steps = 0
	r.total = {}
	r.cost = 0
	r.attempt = 0
	r.resumes = 0
	r.last_ctx = 0
	r.compacted = false
	emit(out, agent.Turn_Started{id = dup(out, turn)})
	if r.t.items == 0 {
		finish_failed(r, out, "the conversation has no messages")
		return
	}
	call(r, now, .Normal, out)
}

run_on_head :: proc(r: ^Run, status: int, headers: []Header, now: i64, out: ^Output) {
	if r.phase != .Calling {
		return
	}
	r.status = status
	r.retry_after = retry_after_ms(headers)
	r.should = should_retry_header(headers)
	clear(&r.request_id)
	if v, ok := header_find(headers, HEADER_REQUEST_ID); ok {
		append(&r.request_id, v)
	} else if v2, ok2 := header_find(headers, HEADER_X_REQUEST_ID); ok2 {
		append(&r.request_id, v2)
	}
	r.not_sse = false
	if status == 200 {
		if ct, ok := header_find(headers, HEADER_CONTENT_TYPE); ok && !contains_fold(ct, SSE_MEDIA_TYPE) {
			r.not_sse = true
		}
	}
}

run_on_body :: proc(r: ^Run, chunk: []u8, now: i64, out: ^Output) -> bool {
	if r.phase != .Calling {
		return false
	}
	raw := make([]u8, len(chunk), out.allocator)
	copy(raw, chunk)
	emit(out, Raw{bytes = raw})
	if r.status != 200 || r.not_sse {
		room := RUN_MAX_ERROR_BODY - len(r.err_body)
		if room > 0 {
			append(&r.err_body, ..chunk[:min(room, len(chunk))])
		}
		return true
	}
	clear(&r.deltas)
	r.model.parse(&r.model, &r.stream, chunk, &r.deltas)
	for &d in r.deltas {
		on_delta(r, &d, out)
	}
	if r.stream.failure.class != .None {
		f := r.stream.failure
		f.message = dup(out, f.message)
		f.code = dup(out, f.code)
		fail_call(r, f, now, out)
		return false
	}
	return true
}

run_on_done :: proc(r: ^Run, err: Http_Error, detail: string, now: i64, out: ^Output) {
	if r.phase != .Calling {
		return
	}
	if r.status == 0 {
		fail_call(r, Failure{class = err == .Tls ? .Fatal : .Network, message = detail != "" ? dup(out, detail) : http_error_text(err)}, now, out)
		return
	}
	if r.status != 200 || r.not_sse {
		hs := [3]Header{}
		f := r.model.classify(&r.model, r.status, hs[:0], r.err_body[:])
		f.retry_after = r.retry_after
		f.should_retry = f.class == .Quota ? -1 : r.should
		f.message = dup(out, f.message)
		f.code = dup(out, f.code)
		if r.status == 200 {
			f.class = .Malformed
			f.message = "the response was not an event stream"
		}
		fail_call(r, f, now, out)
		return
	}
	if err != .None {
		fail_call(r, Failure{class = .Network, status = 200, message = detail != "" ? dup(out, detail) : http_error_text(err)}, now, out)
		return
	}
	if !r.stream.done {
		f := r.stream.failure
		if f.class == .None {
			f = Failure {
				class   = .Network,
				status  = 200,
				message = "the stream ended before the response completed",
			}
		}
		fail_call(r, f, now, out)
		return
	}
	complete(r, now, out)
}

run_tool_done :: proc(r: ^Run, id: string, content: []Block, is_error: bool, now: i64, out: ^Output) {
	context.allocator = r.allocator
	for &p in r.pending {
		if p.id != id || p.done {
			continue
		}
		p.done = true
		p.is_error = is_error
		p.content = clone_blocks(content)
		emit(out, agent.Tool_Finished{id = dup(out, id), output = blocks_text(content, out.allocator), is_error = is_error})
		break
	}
	if r.phase == .Tools && all_done(r) {
		send_results(r, now, out)
	}
}

run_steer :: proc(r: ^Run, id: string, text: string, files: []agent.Attachment, now: i64, out: ^Output) -> bool {
	if !run_active(r) {
		return false
	}
	context.allocator = r.allocator
	fs := make([]agent.Attachment, len(files))
	for f, i in files {
		data := make([]u8, len(f.data))
		copy(data, f.data)
		fs[i] = agent.Attachment{path = strings.clone(f.path), name = strings.clone(f.name), mime = strings.clone(f.mime), data = data}
	}
	append(&r.steer, Steer_Item{id = strings.clone(id), text = strings.clone(text), files = fs})
	return true
}

run_interrupt :: proc(r: ^Run, now: i64, out: ^Output) {
	if !run_active(r) {
		return
	}
	stop_active(r, now, "interrupted", out)
	finish(r, .Interrupted, out)
}

run_tick :: proc(r: ^Run, now: i64, out: ^Output) {
	if !run_active(r) {
		return
	}
	if r.deadline > 0 && now >= r.deadline {
		emit(out, Budget_Exceeded{kind = .Wall})
		stop_active(r, now, "the wall-time budget ran out", out)
		finish(r, .Interrupted, out)
		return
	}
	if r.phase == .Waiting && now >= r.retry_at {
		call(r, now, r.kind, out)
	}
}

run_deadline :: proc(r: ^Run) -> i64 {
	if !run_active(r) {
		return 0
	}
	d: i64 = 0
	if r.phase == .Waiting {
		d = r.retry_at
	}
	if r.deadline > 0 && (d == 0 || r.deadline < d) {
		d = r.deadline
	}
	return d
}

@(private)
stop_active :: proc(r: ^Run, now: i64, why: string, out: ^Output) {
	context.allocator = r.allocator
	switch r.phase {
	case .Calling:
		append(&out.actions, Http_Abort{})
		account(r, out)
		if r.kind == .Normal && r.emitted {
			commit_partial(r, out)
		}
		close_started(r, out, why)
	case .Tools:
		for &p in r.pending {
			if p.done {
				continue
			}
			if p.run {
				append(&out.actions, Tool_Abort{id = dup(out, p.id)})
			}
			p.done = true
			p.is_error = true
			msg := concat({"The tool call was stopped: ", why, "."})
			blocks := make([]Block, 1)
			blocks[0] = Text {
				text = strings.clone(msg),
			}
			p.content = blocks
			emit(out, agent.Tool_Finished{id = dup(out, p.id), output = dup(out, msg), is_error = true})
		}
		commit_results(r, false, out)
	case .Waiting, .Idle, .Done:
	}
}

@(private)
emit :: proc(out: ^Output, e: Event) {
	append(&out.events, e)
}

@(private)
dup :: proc(out: ^Output, s: string) -> string {
	if s == "" {
		return ""
	}
	c, _ := strings.clone(s, out.allocator)
	return c
}

@(private)
http_error_text :: proc(err: Http_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Cancelled:
		return "the request was cancelled"
	case .Dns:
		return "the host name could not be resolved"
	case .Connect:
		return "the connection could not be established"
	case .Tls:
		return "the TLS handshake failed"
	case .Timeout:
		return "the request timed out"
	case .Stalled:
		return "the stream stalled"
	case .Reset:
		return "the connection was reset"
	case .Protocol:
		return "the server violated the HTTP protocol"
	case .Too_Large:
		return "the response was too large"
	case .No_Memory:
		return "out of memory"
	case .Other:
		return "the request failed"
	}
	return "the request failed"
}

@(private)
drop_context :: proc(r: ^Run) {
	context.allocator = r.allocator
	delete(r.ctx.system)
	for t in r.ctx.tools {
		delete(t.name)
		delete(t.description)
		delete(t.schema)
	}
	delete(r.ctx.tools)
	r.ctx = {}
}

@(private)
clear_pending :: proc(r: ^Run) {
	context.allocator = r.allocator
	for &p in r.pending {
		delete(p.id)
		delete(p.name)
		delete(p.input)
		free_blocks(p.content)
	}
	clear(&r.pending)
}

@(private)
clear_steer :: proc(r: ^Run) {
	context.allocator = r.allocator
	for &s in r.steer {
		delete(s.id)
		delete(s.text)
		for f in s.files {
			delete(f.path)
			delete(f.name)
			delete(f.mime)
			delete(f.data)
		}
		delete(s.files)
	}
	clear(&r.steer)
}

@(private)
all_done :: proc(r: ^Run) -> bool {
	for p in r.pending {
		if !p.done {
			return false
		}
	}
	return true
}

@(private)
compact_limit :: proc(r: ^Run) -> u64 {
	if r.cfg.compact_tokens > 0 {
		return r.cfg.compact_tokens
	}
	w := r.cfg.spec.context_window
	if w == 0 {
		return 0
	}
	mt := min(max_tokens(&r.cfg), w / 2)
	frac := r.cfg.compact_at > 0 ? r.cfg.compact_at : 0.9
	return u64(f64(w - mt) * frac)
}

context_estimate :: proc(r: ^Run) -> u64 {
	text_delta := r.t.text_bytes - r.last_text
	if r.last_ctx > 0 && text_delta >= 0 && r.t.media_tok >= r.last_media {
		return r.last_ctx + u64(text_delta) / CHARS_PER_TOKEN + (r.t.media_tok - r.last_media)
	}
	sys := len(r.ctx.system)
	for t in r.ctx.tools {
		sys += len(t.name) + len(t.description) + len(t.schema)
	}
	return u64(sys + r.t.text_bytes) / CHARS_PER_TOKEN + r.t.media_tok
}

@(private)
over_budget :: proc(r: ^Run, now: i64) -> (Budget_Kind, bool) {
	b := r.cfg.budget
	if b.steps > 0 && r.steps >= b.steps {
		return .Steps, true
	}
	if b.tokens > 0 && usage_total(r.total) >= b.tokens {
		return .Tokens, true
	}
	if b.cost_usd > 0 && r.cost >= b.cost_usd {
		return .Cost, true
	}
	if r.deadline > 0 && now >= r.deadline {
		return .Wall, true
	}
	return .Tokens, false
}

@(private)
call :: proc(r: ^Run, now: i64, kind: Request_Kind, out: ^Output) {
	context.allocator = r.allocator
	k := kind
	if k == .Normal {
		if bk, over := over_budget(r, now); over {
			emit(out, Budget_Exceeded{kind = bk})
			finish(r, .Interrupted, out)
			return
		}
		limit := compact_limit(r)
		if limit > 0 && !r.compacted && r.t.items > 1 && context_estimate(r) >= limit {
			k = .Compact
		}
	}
	r.kind = k
	clear(&r.head)
	r.model.head(&r.model, &r.cfg, &r.ctx, k, &r.head)
	clear(&r.tailbuf)
	r.model.tail(&r.model, &r.cfg, k, &r.tailbuf)
	clear(&r.extra)
	if k == .Compact {
		saved := r.t
		r.t.buf = r.extra
		r.t.items = 1
		msg := Message {
			role   = .User,
			blocks = []Block{Text{text = COMPACT_PROMPT}},
		}
		r.model.encode(&r.model, &r.cfg, &msg, &r.t)
		r.extra = r.t.buf
		r.t = saved
	}
	clear(&r.segs)
	append(&r.segs, r.head[:])
	marker := r.model.marker(&r.model, &r.cfg)
	buf := r.t.buf[:]
	marks: [2]int
	nm := 0
	if marker != "" {
		if r.t.positions - r.t.prev_pos > 15 && r.t.prev_mark > 0 && r.t.prev_mark != r.t.mark {
			marks[nm] = r.t.prev_mark
			nm += 1
		}
		if (r.cfg.explicit_cache || k == .Compact) && r.t.mark > 0 {
			marks[nm] = r.t.mark
			nm += 1
		}
	}
	at := 0
	for i in 0 ..< nm {
		m := marks[i]
		if m <= at || m >= len(buf) {
			continue
		}
		append(&r.segs, buf[at:m])
		append(&r.segs, transmute([]u8)marker)
		at = m
	}
	append(&r.segs, buf[at:])
	if len(r.extra) > 0 {
		append(&r.segs, r.extra[:])
	}
	append(&r.segs, r.tailbuf[:])
	if k == .Normal {
		r.t.prev_mark = r.t.mark
		r.t.prev_pos = r.t.positions
		r.steps += 1
	}
	headers := make([dynamic]string, out.allocator)
	append(&headers, CONTENT_TYPE_JSON, ACCEPT_SSE)
	r.model.auth(&r.model, &r.cfg, &headers)
	for h in r.cfg.headers {
		append(&headers, h)
	}
	url := r.cfg.url
	if url == "" {
		switch r.model.api {
		case .Anthropic:
			url = ANTHROPIC_URL
		case .OpenAI_Responses:
			url = OPENAI_RESPONSES_URL
		case .OpenAI_Chat:
			url = OPENAI_CHAT_URL
		}
	}
	stall := r.cfg.stall_ms > 0 ? r.cfg.stall_ms : 120_000
	connect := r.cfg.connect_ms > 0 ? r.cfg.connect_ms : 15_000
	append(&out.actions, Http_Start{req = Http_Request{method = "POST", url = url, headers = headers[:], body = r.segs[:], connect_ms = connect, stall_ms = stall}})
	stream_reset(&r.stream)
	clear(&r.err_body)
	clear(&r.started)
	r.status = 0
	r.not_sse = false
	r.retry_after = 0
	r.should = 0
	r.emitted = false
	r.announced = false
	r.phase = .Calling
}

@(private)
on_delta :: proc(r: ^Run, d: ^Delta, out: ^Output) {
	if r.kind == .Compact {
		return
	}
	switch d.kind {
	case .Start:
		if !r.announced {
			r.announced = true
			emit(out, agent.Message_Started{native_id = dup(out, d.id)})
		}
	case .Block_Start:
		if d.block == .Tool_Call {
			append(&r.started, d.index)
			r.emitted = true
			emit(out, agent.Tool_Started{id = dup(out, d.id), name = dup(out, d.name)})
		}
	case .Text:
		if d.text != "" {
			r.emitted = true
			emit(out, agent.Text_Delta{text = dup(out, d.text)})
		}
	case .Thinking:
		if d.text != "" {
			emit(out, agent.Reasoning_Delta{text = dup(out, d.text)})
		}
	case .Tool_Input:
		if d.text != "" {
			a := &r.stream.blocks[d.index]
			emit(out, agent.Tool_Updated{id = dup(out, string(a.id[:])), input = dup(out, d.text), append = true})
		}
	case .Block_Stop, .Usage, .Stop, .Error:
	}
}

@(private)
account :: proc(r: ^Run, out: ^Output) {
	u := r.stream.usage
	if u == {} {
		return
	}
	usage_add(&r.total, u)
	c := cost_usd(r.cfg.spec, u)
	r.cost += c
	emit(out, agent.Usage{input_tokens = u.input, output_tokens = u.output, cache_read_tokens = u.cache_read, cache_write_tokens = u.cache_write + u.cache_long, reasoning_tokens = u.reasoning, context_tokens = usage_total(u), context_window = r.cfg.spec.context_window, cost_usd = c})
	r.stream.usage = {}
}

@(private)
commit :: proc(r: ^Run, start_len: int, start_items: int, reset: bool, out: ^Output) {
	if len(r.t.buf) <= start_len && !reset {
		return
	}
	body := r.t.buf[start_len:]
	if len(body) > 0 && body[0] == ',' {
		body = body[1:]
	}
	native := make([]u8, len(body) + 2, out.allocator)
	native[0] = '['
	copy(native[1:], body)
	native[len(native) - 1] = ']'
	emit(out, Transcript_Item{role = r.t.last_role, native = string(native), api = r.model.api, reset = reset})
}

@(private)
commit_partial :: proc(r: ^Run, out: ^Output) -> bool {
	start := len(r.t.buf)
	items := r.t.items
	if !r.model.finish(&r.model, &r.stream, &r.t, true) {
		return false
	}
	commit(r, start, items, false, out)
	return true
}

@(private)
close_started :: proc(r: ^Run, out: ^Output, why: string) {
	for idx in r.started {
		if idx >= r.stream.used {
			continue
		}
		a := &r.stream.blocks[idx]
		emit(out, agent.Tool_Finished{id = dup(out, string(a.id[:])), output = dup(out, concat({"The tool call was not run: ", why, "."})), is_error = true})
	}
	clear(&r.started)
}

@(private)
fail_call :: proc(r: ^Run, f: Failure, now: i64, out: ^Output) {
	context.allocator = r.allocator
	account(r, out)
	r.last_status = f.status
	if r.kind == .Normal && f.class == .Too_Long && !r.compacted && r.t.items > 1 {
		call(r, now, .Compact, out)
		return
	}
	retry := r.cfg.retry
	max_attempts := retry.attempts > 0 ? retry.attempts : 10
	max_wait := retry.max_wait_ms > 0 ? retry.max_wait_ms : 600_000
	max_resumes := retry.resumes > 0 ? retry.resumes : 5
	resumed := false
	if r.kind == .Normal && r.emitted {
		if r.resumes >= max_resumes {
			close_started(r, out, "the response stream failed")
			commit_partial(r, out)
			finish_failed(r, out, failure_text(f, out))
			return
		}
		close_started(r, out, "the response stream failed")
		if commit_partial(r, out) {
			start := len(r.t.buf)
			items := r.t.items
			msg := Message {
				role   = .User,
				blocks = []Block{Text{text = RESUME_PROMPT}},
			}
			r.model.encode(&r.model, &r.cfg, &msg, &r.t)
			commit(r, start, items, false, out)
			resumed = true
			r.resumes += 1
		}
	} else {
		close_started(r, out, "the response stream failed")
	}
	if failure_retryable(f) && r.attempt < max_attempts && f.retry_after <= max_wait {
		r.attempt += 1
		delay := backoff_ms(retry, r.attempt, f.retry_after)
		if r.deadline > 0 && now + delay * 1_000_000 >= r.deadline {
			emit(out, Budget_Exceeded{kind = .Wall})
			finish(r, .Interrupted, out)
			return
		}
		r.retry_at = now + delay * 1_000_000
		r.phase = .Waiting
		emit(out, Retrying{attempt = r.attempt, delay_ms = delay, resumed = resumed, status = f.status, reason = failure_text(f, out)})
		return
	}
	finish_failed(r, out, failure_text(f, out))
}

@(private)
failure_text :: proc(f: Failure, out: ^Output) -> string {
	b := make([dynamic]u8, out.allocator)
	if f.status > 0 {
		append(&b, "HTTP ")
		w_uint(&b, u64(f.status))
		append(&b, ": ")
	}
	if f.code != "" {
		append(&b, f.code)
		append(&b, ": ")
	}
	append(&b, f.message != "" ? f.message : "request failed")
	return string(b[:])
}

@(private)
complete :: proc(r: ^Run, now: i64, out: ^Output) {
	context.allocator = r.allocator
	u := r.stream.usage
	account(r, out)
	r.attempt = 0
	s := &r.stream
	if r.kind == .Compact {
		summary := make([dynamic]u8, out.allocator)
		for i in 0 ..< s.used {
			a := &s.blocks[i]
			if a.kind == .Text && len(a.text) > 0 {
				if len(summary) > 0 {
					append(&summary, "\n\n")
				}
				append(&summary, ..a.text[:])
			}
		}
		if len(summary) == 0 {
			finish_failed(r, out, "compaction produced no summary")
			return
		}
		emit(out, Compacted{summary = string(summary[:]), items = r.t.items})
		clear(&r.t.buf)
		r.t = Transcript {
			buf = r.t.buf,
		}
		text := concat({COMPACT_PREAMBLE, string(summary[:]), COMPACT_RESUME})
		msg := Message {
			role   = .User,
			blocks = []Block{Text{text = text}},
		}
		r.model.encode(&r.model, &r.cfg, &msg, &r.t)
		commit(r, 0, 0, true, out)
		r.t.prev_mark = r.t.mark
		r.t.prev_pos = r.t.positions
		r.last_ctx = 0
		r.compacted = true
		call(r, now, .Normal, out)
		return
	}
	start := len(r.t.buf)
	items := r.t.items
	if r.model.finish(&r.model, s, &r.t, false) {
		commit(r, start, items, false, out)
	}
	r.last_ctx = u != {} ? usage_total(u) : 0
	r.last_text = r.t.text_bytes
	r.last_media = r.t.media_tok
	r.compacted = false
	clear(&r.started)
	switch s.stop {
	case .Tool_Use, .Max_Tokens:
		n := collect_tools(r, out)
		if n > 0 {
			r.phase = .Tools
			if all_done(r) {
				send_results(r, now, out)
			}
			return
		}
		if s.stop == .Max_Tokens {
			emit(out, agent.Notice{level = .Warning, text = "the response reached max_tokens"})
		}
		after_turn(r, now, out)
	case .Pause_Turn:
		call(r, now, .Normal, out)
	case .Context_Exceeded:
		call(r, now, .Compact, out)
	case .Refusal:
		detail := string(s.detail[:])
		emit(out, agent.Notice{level = .Warning, text = concat({"the model declined to continue", detail != "" ? ": " : "", detail})})
		finish(r, .Done, out)
	case .End_Turn, .Stop_Sequence, .Other, .None:
		after_turn(r, now, out)
	}
}

@(private)
after_turn :: proc(r: ^Run, now: i64, out: ^Output) {
	if len(r.steer) > 0 {
		start := len(r.t.buf)
		items := r.t.items
		blocks := make([dynamic]Block, context.temp_allocator)
		steer_blocks(r, &blocks)
		msg := Message {
			role   = .User,
			blocks = blocks[:],
		}
		r.model.encode(&r.model, &r.cfg, &msg, &r.t)
		commit(r, start, items, false, out)
		accept_steer(r, out)
		call(r, now, .Normal, out)
		return
	}
	finish(r, .Done, out)
}

@(private)
steer_blocks :: proc(r: ^Run, blocks: ^[dynamic]Block) {
	for s in r.steer {
		if s.text != "" {
			append(blocks, Text{text = s.text})
		}
		for f in s.files {
			if strings.has_prefix(f.mime, "image/") {
				append(blocks, Image{mime = f.mime, data = f.data})
			} else if f.mime == "application/pdf" {
				append(blocks, Document{mime = f.mime, data = f.data, title = f.name})
			} else {
				append(blocks, Document{text = string(f.data), title = f.name})
			}
		}
	}
}

@(private)
accept_steer :: proc(r: ^Run, out: ^Output) {
	for s in r.steer {
		emit(out, agent.Prompt_Accepted{id = dup(out, s.id), steer = true})
	}
	clear_steer(r)
}

@(private)
collect_tools :: proc(r: ^Run, out: ^Output) -> int {
	context.allocator = r.allocator
	clear_pending(r)
	s := &r.stream
	n := 0
	for i in 0 ..< s.used {
		a := &s.blocks[i]
		if a.kind != .Tool_Call {
			continue
		}
		if !a.complete {
			emit(out, agent.Tool_Finished{id = dup(out, string(a.id[:])), output = "The tool call was cut off before its input was complete.", is_error = true})
			continue
		}
		input := a.text[:]
		p := Pending_Tool {
			id    = strings.clone(string(a.id[:])),
			name  = strings.clone(string(a.name[:])),
			input = strings.clone(string(input)),
		}
		if len(input) == 0 {
			delete(p.input)
			p.input = strings.clone("{}")
		} else if !j_valid(input) || !j_is_object(input) {
			p.done = true
			p.is_error = true
			msg := "INVALID_JSON: the tool input was not a complete JSON object; call the tool again with valid input."
			blocks := make([]Block, 1)
			blocks[0] = Text {
				text = strings.clone(msg),
			}
			p.content = blocks
			emit(out, agent.Tool_Finished{id = dup(out, p.id), output = msg, is_error = true})
		}
		append(&r.pending, p)
		n += 1
	}
	for &p in r.pending {
		if !p.done {
			p.run = true
			append(&out.actions, Tool_Run{id = dup(out, p.id), name = dup(out, p.name), input = dup(out, p.input)})
		}
	}
	return n
}

@(private)
commit_results :: proc(r: ^Run, with_steer: bool, out: ^Output) {
	if len(r.pending) == 0 {
		return
	}
	blocks := make([dynamic]Block, context.temp_allocator)
	for &p in r.pending {
		append(&blocks, Tool_Result{id = p.id, content = p.content, is_error = p.is_error})
	}
	if with_steer {
		steer_blocks(r, &blocks)
	}
	start := len(r.t.buf)
	items := r.t.items
	msg := Message {
		role   = .User,
		blocks = blocks[:],
	}
	r.model.encode(&r.model, &r.cfg, &msg, &r.t)
	commit(r, start, items, false, out)
	if with_steer {
		accept_steer(r, out)
	}
	clear_pending(r)
}

@(private)
send_results :: proc(r: ^Run, now: i64, out: ^Output) {
	commit_results(r, true, out)
	call(r, now, .Normal, out)
}

@(private)
finish :: proc(r: ^Run, status: agent.Turn_Status, out: ^Output) {
	for s in r.steer {
		emit(out, agent.Prompt_Dropped{id = dup(out, s.id)})
	}
	clear_steer(r)
	clear_pending(r)
	emit(out, agent.Turn_Finished{status = status})
	settle(r)
}

@(private)
finish_failed :: proc(r: ^Run, out: ^Output, message: string) {
	for s in r.steer {
		emit(out, agent.Prompt_Dropped{id = dup(out, s.id)})
	}
	clear_steer(r)
	clear_pending(r)
	emit(out, agent.Turn_Failed{message = dup(out, message)})
	settle(r)
}

@(private)
settle :: proc(r: ^Run) {
	r.phase = .Done
	stream_trim(&r.stream, RUN_TRIM_BYTES)
	if cap(r.err_body) > RUN_TRIM_BYTES {
		delete(r.err_body)
		r.err_body = make([dynamic]u8, r.allocator)
	}
}

@(private)
clone_blocks :: proc(src: []Block) -> []Block {
	out := make([]Block, len(src))
	for &b, i in src {
		switch v in b {
		case Text:
			out[i] = Text{text = strings.clone(v.text)}
		case Image:
			out[i] = Image{mime = strings.clone(v.mime), data = clone_bytes(v.data), url = strings.clone(v.url)}
		case Document:
			out[i] = Document{mime = strings.clone(v.mime), data = clone_bytes(v.data), url = strings.clone(v.url), title = strings.clone(v.title), text = strings.clone(v.text)}
		case Tool_Use:
			out[i] = Tool_Use{id = strings.clone(v.id), name = strings.clone(v.name), input = strings.clone(v.input)}
		case Tool_Result:
			out[i] = Tool_Result{id = strings.clone(v.id), content = clone_blocks(v.content), is_error = v.is_error}
		case Thinking:
			out[i] = Thinking{text = strings.clone(v.text), signature = strings.clone(v.signature), redacted = strings.clone(v.redacted)}
		}
	}
	return out
}

@(private)
clone_bytes :: proc(b: []u8) -> []u8 {
	if len(b) == 0 {
		return nil
	}
	c := make([]u8, len(b))
	copy(c, b)
	return c
}

@(private)
free_blocks :: proc(bs: []Block) {
	for &b in bs {
		switch v in b {
		case Text:
			delete(v.text)
		case Image:
			delete(v.mime)
			delete(v.data)
			delete(v.url)
		case Document:
			delete(v.mime)
			delete(v.data)
			delete(v.url)
			delete(v.title)
			delete(v.text)
		case Tool_Use:
			delete(v.id)
			delete(v.name)
			delete(v.input)
		case Tool_Result:
			delete(v.id)
			free_blocks(v.content)
		case Thinking:
			delete(v.text)
			delete(v.signature)
			delete(v.redacted)
		}
	}
	delete(bs)
}

@(private)
blocks_text :: proc(bs: []Block, allocator: runtime.Allocator) -> string {
	b := make([dynamic]u8, allocator)
	for &x in bs {
		#partial switch v in x {
		case Text:
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, v.text)
		case Image:
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, "[image]")
		case Document:
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, "[document]")
		}
	}
	return string(b[:])
}

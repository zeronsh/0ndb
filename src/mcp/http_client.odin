package mcp

import "base:runtime"
import "core:strings"
import "../prim"

Http_Client_Config :: struct {
	url:             string,
	headers:         []Header,
	http:            Http,
	head_timeout_ms: i64,
	max_body:        int,
}

DEFAULT_HEAD_TIMEOUT_MS :: 30_000
DEFAULT_MAX_BODY :: 64 << 20

@(private)
Http_Stream_Kind :: enum u8 {
	Request,
	Message,
	Get,
	Old_Sse,
	Resume,
}

@(private)
Http_Stream :: struct {
	hc:        ^Http_Client,
	handle:    Http_Handle,
	kind:      Http_Stream_Kind,
	id:        i64,
	status:    int,
	sse:       bool,
	body:      Buf,
	parser:    Sse_Parser,
	init:      bool,
	www_auth:  string,
	head_seen: bool,
	json:      bool,
	too_big:   bool,
	dead:      bool,
}

Http_Client :: struct {
	client:       Client,
	loop:         ^prim.Loop,
	allocator:    runtime.Allocator,
	http:         Http,
	url:          string,
	endpoint:     string,
	headers:      [dynamic]Header,
	session:      string,
	old_sse:      bool,
	streams:      [dynamic]^Http_Stream,
	get:          ^Http_Stream,
	get_t:        prim.Timer,
	get_backoff:  i64,
	get_disabled: bool,
	get_last_id:  string,
	timer:        prim.Timer,
	timer_at:     i64,
	reconnect_t:  prim.Timer,
	backoff:      i64,
	auth_wait:    [dynamic]i64,
	handler:      Event_Handler,
	head_timeout: i64,
	max_body:     int,
	closing:      bool,
	down:         bool,
}

http_client_open :: proc(hc: ^Http_Client, loop: ^prim.Loop, cfg: Http_Client_Config, client_cfg: Client_Config, handler: Event_Handler, allocator := context.allocator) {
	hc^ = {}
	hc.loop = loop
	hc.allocator = allocator
	hc.http = cfg.http
	hc.url = strings.clone(cfg.url, allocator)
	hc.endpoint = strings.clone(cfg.url, allocator)
	hc.headers = make([dynamic]Header, allocator)
	for h in cfg.headers {
		append(&hc.headers, Header{strings.clone(h.name, allocator), strings.clone(h.value, allocator)})
	}
	hc.streams = make([dynamic]^Http_Stream, allocator)
	hc.auth_wait = make([dynamic]i64, allocator)
	hc.handler = handler
	hc.head_timeout = cfg.head_timeout_ms if cfg.head_timeout_ms > 0 else DEFAULT_HEAD_TIMEOUT_MS
	hc.max_body = cfg.max_body if cfg.max_body > 0 else DEFAULT_MAX_BODY
	hc.backoff = RESTART_MIN_MS
	hc.get_backoff = 1000
	ccfg := client_cfg
	ccfg.transport = .Http
	client_init(&hc.client, ccfg, Client_Sink{data = hc, send = _hc_send, event = _hc_event}, allocator)
	client_start(&hc.client)
	_hc_arm(hc)
}

http_client_set_header :: proc(hc: ^Http_Client, name: string, value: string) {
	for &h in hc.headers {
		if _ascii_equal_fold(h.name, name) {
			delete(h.value, hc.allocator)
			h.value = strings.clone(value, hc.allocator)
			return
		}
	}
	append(&hc.headers, Header{strings.clone(name, hc.allocator), strings.clone(value, hc.allocator)})
}

http_client_retry_auth :: proc(hc: ^Http_Client) {
	ids := make([dynamic]i64, context.temp_allocator)
	append(&ids, ..hc.auth_wait[:])
	clear(&hc.auth_wait)
	for id in ids {
		if !client_retransmit(&hc.client, id) && client_awaiting(&hc.client, id) {
			client_transport_lost(&hc.client, "authorization renewed")
			_hc_schedule_reconnect(hc, 0)
			return
		}
	}
	if hc.client.state == .Idle && !hc.closing {
		_hc_schedule_reconnect(hc, 0)
	}
}

@(private)
_hc_event :: proc(data: rawptr, c: ^Client, e: ^Event) {
	hc := (^Http_Client)(data)
	if e.kind == .Ready {
		hc.backoff = RESTART_MIN_MS
		if c.era == .Legacy && !hc.old_sse && !hc.get_disabled && hc.get == nil {
			_hc_open_get(hc, false)
		}
	}
	if hc.handler.event != nil {
		hc.handler.event(hc.handler.data, c, e)
	}
}

@(private)
_hc_base_headers :: proc(hc: ^Http_Client, out: ^[dynamic]Header, accept: string) {
	append(out, Header{"Accept", accept})
	if hc.session != "" {
		append(out, Header{"Mcp-Session-Id", hc.session})
	}
	for h in hc.headers {
		append(out, h)
	}
}

@(private)
_hc_new_stream :: proc(hc: ^Http_Client, kind: Http_Stream_Kind, id: i64) -> ^Http_Stream {
	s := new(Http_Stream, hc.allocator)
	s.hc = hc
	s.kind = kind
	s.id = id
	s.body = make(Buf, hc.allocator)
	append(&hc.streams, s)
	return s
}

@(private)
_hc_free_stream :: proc(hc: ^Http_Client, s: ^Http_Stream) {
	for x, i in hc.streams {
		if x == s {
			ordered_remove(&hc.streams, i)
			break
		}
	}
	if hc.get == s {
		hc.get = nil
	}
	delete(s.body)
	if s.sse {
		sse_destroy(&s.parser)
	}
	delete(s.www_auth, hc.allocator)
	free(s, hc.allocator)
}

@(private)
_hc_sink :: proc(s: ^Http_Stream) -> Http_Sink {
	return Http_Sink{data = s, head = _hc_on_head, body = _hc_on_body, done = _hc_on_done}
}

@(private)
_hc_send :: proc(data: rawptr, c: ^Client, m: ^Outgoing) {
	hc := (^Http_Client)(data)
	switch m.kind {
	case .Abort:
		for s in hc.streams {
			if (s.kind == .Request || s.kind == .Resume) && s.id == m.id {
				if hc.http.cancel != nil {
					hc.http.cancel(hc.http.data, s.handle)
				}
				_hc_free_stream(hc, s)
				break
			}
		}
		return
	case .Fallback_Sse:
		hc.old_sse = true
		_hc_open_get(hc, true)
		return
	case .Request, .Notification, .Response:
	}
	if hc.old_sse && hc.endpoint == hc.url && hc.get != nil {
		return
	}
	headers := make([dynamic]Header, context.temp_allocator)
	_hc_base_headers(hc, &headers, "application/json, text/event-stream")
	append(&headers, Header{"Content-Type", "application/json"})
	v := version_parse(m.version)
	if v >= .V2025_06_18 && !hc.old_sse {
		append(&headers, Header{"MCP-Protocol-Version", m.version})
	}
	if version_modern(v) {
		if m.method != "" {
			append(&headers, Header{"Mcp-Method", m.method})
		}
		if m.name != "" {
			append(&headers, Header{"Mcp-Name", header_value_encode(m.name)})
		}
		for h in m.headers {
			append(&headers, h)
		}
	}
	kind := Http_Stream_Kind.Request if m.kind == .Request else Http_Stream_Kind.Message
	s := _hc_new_stream(hc, kind, m.id)
	s.init = m.initialize
	req := Http_Request {
		method     = "POST",
		url        = hc.endpoint,
		headers    = headers[:],
		body       = m.body,
		timeout_ms = hc.head_timeout,
	}
	s.handle = hc.http.start(hc.http.data, &req, _hc_sink(s))
	_hc_arm(hc)
}

@(private)
_hc_open_get :: proc(hc: ^Http_Client, old: bool) {
	if hc.get != nil || hc.closing {
		return
	}
	headers := make([dynamic]Header, context.temp_allocator)
	_hc_base_headers(hc, &headers, "text/event-stream")
	if !old {
		if v := hc.client.version; v >= .V2025_06_18 {
			append(&headers, Header{"MCP-Protocol-Version", version_name(v)})
		}
		if hc.get_last_id != "" {
			append(&headers, Header{"Last-Event-ID", hc.get_last_id})
		}
	}
	s := _hc_new_stream(hc, .Old_Sse if old else .Get, 0)
	hc.get = s
	req := Http_Request {
		method     = "GET",
		url        = hc.url,
		headers    = headers[:],
		timeout_ms = hc.head_timeout,
	}
	s.handle = hc.http.start(hc.http.data, &req, _hc_sink(s))
}

@(private)
_hc_open_resume :: proc(hc: ^Http_Client, id: i64, last_id: string) {
	headers := make([dynamic]Header, context.temp_allocator)
	_hc_base_headers(hc, &headers, "text/event-stream")
	if v := hc.client.version; v >= .V2025_06_18 {
		append(&headers, Header{"MCP-Protocol-Version", version_name(v)})
	}
	append(&headers, Header{"Last-Event-ID", last_id})
	s := _hc_new_stream(hc, .Resume, id)
	req := Http_Request {
		method     = "GET",
		url        = hc.url,
		headers    = headers[:],
		timeout_ms = hc.head_timeout,
	}
	s.handle = hc.http.start(hc.http.data, &req, _hc_sink(s))
}

@(private)
_hc_on_head :: proc(data: rawptr, status: int, headers: []Header) {
	s := (^Http_Stream)(data)
	hc := s.hc
	s.status = status
	s.head_seen = true
	if sid, ok := http_header(headers, "mcp-session-id"); ok && s.init && status >= 200 && status < 300 && hc.client.era != .Modern {
		delete(hc.session, hc.allocator)
		hc.session = strings.clone(sid, hc.allocator)
	}
	if wa, ok := http_header(headers, "www-authenticate"); ok {
		s.www_auth = strings.clone(wa, hc.allocator)
	}
	ct, _ := http_header(headers, "content-type")
	s.json = strings.has_prefix(strings.to_lower(ct, context.temp_allocator), "application/json")
	if status >= 200 && status < 300 && strings.has_prefix(strings.to_lower(ct, context.temp_allocator), "text/event-stream") {
		s.sse = true
		sse_init(&s.parser, hc.allocator)
		if s.kind == .Get {
			hc.get_backoff = 1000
		}
	}
}

@(private)
_hc_on_body :: proc(data: rawptr, chunk: []u8) {
	s := (^Http_Stream)(data)
	hc := s.hc
	if s.sse {
		if !sse_feed(&s.parser, chunk, s, _hc_on_sse) {
			s.too_big = true
		}
		return
	}
	if len(s.body) + len(chunk) > hc.max_body {
		s.too_big = true
		return
	}
	append(&s.body, ..chunk)
}

@(private)
_hc_on_sse :: proc(data: rawptr, e: ^Sse_Event) {
	s := (^Http_Stream)(data)
	hc := s.hc
	if s.kind == .Get && e.id != "" {
		delete(hc.get_last_id, hc.allocator)
		hc.get_last_id = strings.clone(e.id, hc.allocator)
	}
	if s.kind == .Old_Sse && e.event == "endpoint" {
		ep := url_resolve(hc.url, strings.trim_space(e.data), hc.allocator)
		if u, ok := url_parse(ep); ok {
			b, _ := url_parse(hc.url)
			if u.origin != b.origin {
				delete(ep, hc.allocator)
				client_close(&hc.client, "HTTP+SSE endpoint is on a different origin")
				return
			}
		}
		delete(hc.endpoint, hc.allocator)
		hc.endpoint = ep
		client_sse_ready(&hc.client)
		_hc_arm(hc)
		return
	}
	if e.event != "message" {
		return
	}
	text := json_trim(e.data)
	if len(text) == 0 {
		return
	}
	related: i64 = 0
	if s.kind == .Request || s.kind == .Resume {
		related = s.id
	}
	client_receive(&hc.client, transmute([]u8)text, related)
	_hc_arm(hc)
}

@(private)
_hc_on_done :: proc(data: rawptr, err: Http_Error) {
	s := (^Http_Stream)(data)
	hc := s.hc
	c := &hc.client
	defer _hc_arm(hc)
	kind, id, status := s.kind, s.id, s.status
	if s.too_big {
		_hc_free_stream(hc, s)
		if kind == .Request {
			client_fail_request(c, id, JSONRPC_INTERNAL_ERROR, "response too large")
		}
		return
	}
	if hc.closing {
		_hc_free_stream(hc, s)
		return
	}
	if err != .None && !s.head_seen {
		_hc_free_stream(hc, s)
		switch kind {
		case .Request, .Resume:
			if client_awaiting(c, id) {
				_hc_transport_down(hc, "connection failed")
			}
		case .Message:
		case .Get:
			_hc_schedule_get(hc)
		case .Old_Sse:
			_hc_transport_down(hc, "HTTP+SSE stream failed")
		}
		return
	}
	if status == 401 || status == 403 {
		e := Event{kind = .Auth_Required, code = i64(status), message = s.www_auth}
		if kind == .Request {
			append(&hc.auth_wait, id)
		}
		_hc_free_stream(hc, s)
		_hc_event(hc, c, &e)
		return
	}
	if status == 404 && hc.session != "" && c.era == .Legacy && kind != .Old_Sse {
		_hc_free_stream(hc, s)
		delete(hc.session, hc.allocator)
		hc.session = ""
		_hc_close_get(hc)
		client_session_expired(c)
		return
	}
	switch kind {
	case .Request:
		if status < 200 || status >= 300 {
			body := make([]u8, len(s.body), context.temp_allocator)
			copy(body, s.body[:])
			_hc_free_stream(hc, s)
			client_http_failed(c, id, status, body)
			return
		}
		if !s.sse {
			if len(s.body) > 0 && s.json && status != 202 {
				client_receive(c, s.body[:], id)
			}
			_hc_free_stream(hc, s)
			if client_awaiting(c, id) && !hc.old_sse && status != 202 {
				client_stream_lost(c, id)
			}
			return
		}
		last := strings.clone(sse_last_id(&s.parser), context.temp_allocator)
		_hc_free_stream(hc, s)
		if client_awaiting(c, id) {
			if c.era == .Legacy && last != "" {
				_hc_open_resume(hc, id, last)
				return
			}
			client_stream_lost(c, id)
		}
	case .Resume:
		last := strings.clone(sse_last_id(&s.parser), context.temp_allocator) if s.sse else ""
		ok := s.sse && status >= 200 && status < 300
		_hc_free_stream(hc, s)
		if client_awaiting(c, id) {
			if ok && last != "" {
				_hc_open_resume(hc, id, last)
				return
			}
			client_stream_lost(c, id)
		}
	case .Message:
		if status < 200 || status >= 300 {
			msg := strings.clone(string(s.body[:]), context.temp_allocator)
			_hc_free_stream(hc, s)
			e := Event{kind = .Warning, code = i64(status), message = "server rejected a message", data = msg}
			_hc_event(hc, c, &e)
			return
		}
		_hc_free_stream(hc, s)
	case .Get:
		_hc_free_stream(hc, s)
		if status == 405 || (status >= 400 && status < 500) {
			hc.get_disabled = true
			return
		}
		_hc_schedule_get(hc)
	case .Old_Sse:
		_hc_free_stream(hc, s)
		if status < 200 || status >= 300 {
			client_close(c, "server supports neither Streamable HTTP nor HTTP+SSE")
			return
		}
		_hc_transport_down(hc, "HTTP+SSE stream closed")
	}
}

@(private)
_hc_close_get :: proc(hc: ^Http_Client) {
	if hc.get != nil {
		if hc.http.cancel != nil {
			hc.http.cancel(hc.http.data, hc.get.handle)
		}
		_hc_free_stream(hc, hc.get)
	}
	if hc.get_t != 0 {
		prim.timer_cancel(hc.loop, hc.get_t)
		hc.get_t = 0
	}
}

@(private)
_hc_schedule_get :: proc(hc: ^Http_Client) {
	if hc.closing || hc.get_disabled || hc.client.state != .Ready || hc.client.era != .Legacy || hc.old_sse || hc.get_t != 0 {
		return
	}
	delay := hc.get_backoff
	hc.get_backoff = min(hc.get_backoff * 2, RESTART_MAX_MS)
	hc.get_t = prim.timer(hc.loop, delay, hc, proc(l: ^prim.Loop, data: rawptr) {
		hc := (^Http_Client)(data)
		hc.get_t = 0
		if hc.client.state == .Ready {
			_hc_open_get(hc, false)
		}
	})
}

@(private)
_hc_transport_down :: proc(hc: ^Http_Client, reason: string) {
	if hc.down || hc.closing {
		return
	}
	hc.down = true
	for len(hc.streams) > 0 {
		s := hc.streams[len(hc.streams) - 1]
		if hc.http.cancel != nil {
			hc.http.cancel(hc.http.data, s.handle)
		}
		_hc_free_stream(hc, s)
	}
	_hc_close_get(hc)
	if hc.old_sse {
		delete(hc.endpoint, hc.allocator)
		hc.endpoint = strings.clone(hc.url, hc.allocator)
	}
	client_transport_lost(&hc.client, reason)
	delay := hc.backoff
	hc.backoff = min(hc.backoff * 2, RESTART_MAX_MS)
	_hc_schedule_reconnect(hc, delay)
}

@(private)
_hc_schedule_reconnect :: proc(hc: ^Http_Client, delay: i64) {
	if hc.reconnect_t != 0 || hc.closing {
		return
	}
	hc.reconnect_t = prim.timer(hc.loop, delay, hc, proc(l: ^prim.Loop, data: rawptr) {
		hc := (^Http_Client)(data)
		hc.reconnect_t = 0
		hc.down = false
		if hc.client.state == .Closed {
			return
		}
		if hc.old_sse {
			_hc_open_get(hc, true)
			return
		}
		client_start(&hc.client)
		_hc_arm(hc)
	})
}

@(private)
_hc_arm :: proc(hc: ^Http_Client) {
	deadline, ok := client_next_deadline(&hc.client)
	if !ok || hc.closing {
		if hc.timer != 0 {
			prim.timer_cancel(hc.loop, hc.timer)
			hc.timer = 0
		}
		return
	}
	if hc.timer != 0 && prim.timer_pending(hc.loop, hc.timer) && hc.timer_at <= deadline {
		return
	}
	if hc.timer != 0 {
		prim.timer_cancel(hc.loop, hc.timer)
	}
	hc.timer_at = deadline
	hc.timer = prim.timer_at(hc.loop, deadline * 1_000_000, hc, proc(l: ^prim.Loop, data: rawptr) {
		hc := (^Http_Client)(data)
		hc.timer = 0
		client_tick(&hc.client)
		_hc_arm(hc)
	})
}

http_client_close :: proc(hc: ^Http_Client) {
	if hc.closing {
		return
	}
	client_close(&hc.client, "client closed")
	hc.closing = true
	for len(hc.streams) > 0 {
		s := hc.streams[len(hc.streams) - 1]
		if hc.http.cancel != nil {
			hc.http.cancel(hc.http.data, s.handle)
		}
		_hc_free_stream(hc, s)
	}
	_hc_close_get(hc)
	for t in ([]prim.Timer{hc.timer, hc.reconnect_t}) {
		if t != 0 {
			prim.timer_cancel(hc.loop, t)
		}
	}
	hc.timer = 0
	hc.reconnect_t = 0
	if hc.session != "" && hc.http.start != nil {
		headers := make([dynamic]Header, context.temp_allocator)
		_hc_base_headers(hc, &headers, "application/json, text/event-stream")
		if v := hc.client.version; v >= .V2025_06_18 {
			append(&headers, Header{"MCP-Protocol-Version", version_name(v)})
		}
		req := Http_Request {
			method     = "DELETE",
			url        = hc.url,
			headers    = headers[:],
			timeout_ms = hc.head_timeout,
		}
		hc.http.start(hc.http.data, &req, {})
	}
}

http_client_destroy :: proc(hc: ^Http_Client) {
	http_client_close(hc)
	client_destroy(&hc.client)
	delete(hc.url, hc.allocator)
	delete(hc.endpoint, hc.allocator)
	delete(hc.session, hc.allocator)
	delete(hc.get_last_id, hc.allocator)
	for h in hc.headers {
		delete(h.name, hc.allocator)
		delete(h.value, hc.allocator)
	}
	delete(hc.headers)
	delete(hc.streams)
	delete(hc.auth_wait)
	hc^ = {}
}

package mcp

import "base:runtime"
import "core:encoding/base64"
import "core:strconv"
import "core:strings"
import "../prim"

Transport_Kind :: enum u8 {
	Stdio,
	Http,
}

Era :: enum u8 {
	Unknown,
	Modern,
	Legacy,
}

Client_State :: enum u8 {
	Idle,
	Probing,
	Initializing,
	Ready,
	Closed,
}

Call :: distinct u64

Input :: distinct u64

Op :: enum u8 {
	Raw,
	Discover,
	Initialize,
	Tools_List,
	Tools_Call,
	Resources_List,
	Resource_Templates_List,
	Resources_Read,
	Prompts_List,
	Prompts_Get,
	Complete,
	Subscribe,
	Unsubscribe,
	Listen,
	Set_Level,
	Ping,
}

Watch_Flag :: enum u8 {
	Tools,
	Prompts,
	Resources,
}

Watch_Flags :: bit_set[Watch_Flag;u8]

Header :: struct {
	name:  string,
	value: string,
}

Outgoing_Kind :: enum u8 {
	Request,
	Notification,
	Response,
	Abort,
	Fallback_Sse,
}

Outgoing :: struct {
	kind:        Outgoing_Kind,
	id:          i64,
	body:        []u8,
	method:      string,
	name:        string,
	version:     string,
	headers:     []Header,
	long_lived:  bool,
	initialize:  bool,
	related:     i64,
}

Event_Kind :: enum u8 {
	Ready,
	Disconnected,
	Closed,
	Result,
	Error,
	Progress,
	Log,
	Input_Request,
	Input_Cancelled,
	Tools_Changed,
	Prompts_Changed,
	Resources_Changed,
	Resource_Updated,
	Elicitation_Complete,
	Subscribed,
	Notification,
	Stderr,
	Auth_Required,
	Warning,
}

Event :: struct {
	kind:      Event_Kind,
	call:      Call,
	input:     Input,
	op:        Op,
	local:     bool,
	code:      i64,
	message:   string,
	data:      string,
	method:    string,
	params:    string,
	result:    string,
	progress:  f64,
	total:     f64,
	has_total: bool,
	level:     Log_Level,
	logger:    string,
	key:       string,
}

Client_Sink :: struct {
	data:  rawptr,
	send:  proc(data: rawptr, c: ^Client, m: ^Outgoing),
	event: proc(data: rawptr, c: ^Client, e: ^Event),
	now:   proc(data: rawptr) -> i64,
}

Client_Config :: struct {
	info:               Implementation,
	capabilities:       Client_Capabilities,
	versions:           Versions,
	transport:          Transport_Kind,
	era:                Era,
	probe_timeout_ms:   i64,
	request_timeout_ms: i64,
	call_timeout_ms:    i64,
	call_max_ms:        i64,
	max_attempts:       int,
	max_pages:          int,
	watch:              Watch_Flags,
	log_level:          Log_Level,
}

DEFAULT_PROBE_TIMEOUT_MS :: 30_000
DEFAULT_REQUEST_TIMEOUT_MS :: 60_000
DEFAULT_CALL_TIMEOUT_MS :: 600_000
DEFAULT_CALL_MAX_MS :: 3_600_000
DEFAULT_MAX_ATTEMPTS :: 3
DEFAULT_MAX_PAGES :: 1000

Server_Info :: struct {
	impl:         string,
	name:         string,
	version_text: string,
	capabilities: Server_Capabilities,
	instructions: string,
	supported:    Versions,
}

@(private)
Input_Slot :: struct {
	id:       Input,
	key:      string,
	method:   string,
	params:   string,
	response: string,
	answered: bool,
}

@(private)
Pending :: struct {
	id:          i64,
	call:        Call,
	op:          Op,
	method:      string,
	params:      string,
	name:        string,
	progress:    bool,
	log:         Log_Level,
	timeout_ms:  i64,
	deadline:    i64,
	hard:        i64,
	attempts:    int,
	pages:       int,
	sent:        bool,
	state:       string,
	has_state:   bool,
	inputs:      [dynamic]Input_Slot,
	accum:       Buf,
	ttl:         i64,
	private:     bool,
	last_cursor: string,
	retry_url:   bool,
	refresh:     Call,
	waiting:     bool,
}

@(private)
Server_Request :: struct {
	input:   Input,
	id:      string,
	method:  string,
	related: i64,
}

@(private)
Header_Param :: struct {
	header: string,
	path:   []string,
}

@(private)
Tool_Headers :: struct {
	name:   string,
	params: []Header_Param,
}

@(private)
List_Cache :: struct {
	json:    string,
	expires: i64,
	valid:   bool,
}

Client :: struct {
	allocator:     runtime.Allocator,
	cfg:           Client_Config,
	sink:          Client_Sink,
	state:         Client_State,
	era:           Era,
	version:       Version,
	server:        Server_Info,
	next_id:       i64,
	next_call:     u64,
	next_input:    u64,
	pending:       [dynamic]^Pending,
	server_reqs:   [dynamic]Server_Request,
	roots:         string,
	roots_set:     bool,
	tool_headers:  [dynamic]Tool_Headers,
	caches:        [Op]List_Cache,
	sub_uris:      [dynamic]string,
	listen_id:     i64,
	listen_acked:  bool,
	listen_retry:  i64,
	listen_wanted: bool,
	legacy_level:  Log_Level,
	probe_tried:   Versions,
	internal:      [dynamic]Call,
}

client_init :: proc(c: ^Client, cfg: Client_Config, sink: Client_Sink, allocator := context.allocator) {
	c^ = {}
	c.allocator = allocator
	c.cfg = cfg
	c.sink = sink
	if c.cfg.versions == {} {
		c.cfg.versions = ALL_VERSIONS
	}
	if c.cfg.probe_timeout_ms <= 0 {
		c.cfg.probe_timeout_ms = DEFAULT_PROBE_TIMEOUT_MS
	}
	if c.cfg.request_timeout_ms <= 0 {
		c.cfg.request_timeout_ms = DEFAULT_REQUEST_TIMEOUT_MS
	}
	if c.cfg.call_timeout_ms <= 0 {
		c.cfg.call_timeout_ms = DEFAULT_CALL_TIMEOUT_MS
	}
	if c.cfg.call_max_ms <= 0 {
		c.cfg.call_max_ms = DEFAULT_CALL_MAX_MS
	}
	if c.cfg.max_attempts <= 0 {
		c.cfg.max_attempts = DEFAULT_MAX_ATTEMPTS
	}
	if c.cfg.max_pages <= 0 {
		c.cfg.max_pages = DEFAULT_MAX_PAGES
	}
	c.era = cfg.era
	c.next_id = 1
	c.next_call = 1
	c.next_input = 1
	c.pending = make([dynamic]^Pending, allocator)
	c.server_reqs = make([dynamic]Server_Request, allocator)
	c.tool_headers = make([dynamic]Tool_Headers, allocator)
	c.sub_uris = make([dynamic]string, allocator)
	c.internal = make([dynamic]Call, allocator)
}

client_destroy :: proc(c: ^Client) {
	for p in c.pending {
		_pending_free(c, p)
	}
	delete(c.pending)
	for &r in c.server_reqs {
		_server_req_free(c, &r)
	}
	delete(c.server_reqs)
	_tool_headers_clear(c)
	delete(c.tool_headers)
	for u in c.sub_uris {
		delete(u, c.allocator)
	}
	delete(c.sub_uris)
	delete(c.internal)
	for &lc in c.caches {
		delete(lc.json, c.allocator)
	}
	delete(c.roots, c.allocator)
	_server_info_clear(c)
	c^ = {}
}

client_ready :: proc "contextless" (c: ^Client) -> bool {
	return c.state == .Ready
}

client_era :: proc "contextless" (c: ^Client) -> Era {
	return c.era
}

client_version :: proc "contextless" (c: ^Client) -> Version {
	return c.version
}

client_server :: proc "contextless" (c: ^Client) -> ^Server_Info {
	return &c.server
}

@(private)
_now :: proc(c: ^Client) -> i64 {
	if c.sink.now != nil {
		return c.sink.now(c.sink.data)
	}
	return prim.mono_ns() / 1_000_000
}

@(private)
_emit :: proc(c: ^Client, e: Event) {
	if e.call != 0 && (e.kind == .Result || e.kind == .Error) {
		for x, i in c.internal {
			if x == e.call {
				unordered_remove(&c.internal, i)
				return
			}
		}
	}
	ev := e
	if c.sink.event != nil {
		c.sink.event(c.sink.data, c, &ev)
	}
}

@(private)
_clone :: proc(c: ^Client, s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	out, _ := strings.clone(s, c.allocator)
	return out
}

@(private)
_pending_free :: proc(c: ^Client, p: ^Pending) {
	delete(p.params, c.allocator)
	delete(p.name, c.allocator)
	delete(p.state, c.allocator)
	delete(p.last_cursor, c.allocator)
	for &s in p.inputs {
		_input_slot_free(c, &s)
	}
	delete(p.inputs)
	delete(p.accum)
	free(p, c.allocator)
}

@(private)
_input_slot_free :: proc(c: ^Client, s: ^Input_Slot) {
	delete(s.key, c.allocator)
	delete(s.method, c.allocator)
	delete(s.params, c.allocator)
	delete(s.response, c.allocator)
	s^ = {}
}

@(private)
_server_req_free :: proc(c: ^Client, r: ^Server_Request) {
	delete(r.id, c.allocator)
	delete(r.method, c.allocator)
	r^ = {}
}

@(private)
_server_info_clear :: proc(c: ^Client) {
	delete(c.server.impl, c.allocator)
	delete(c.server.name, c.allocator)
	delete(c.server.version_text, c.allocator)
	delete(c.server.instructions, c.allocator)
	delete(c.server.capabilities.extensions, c.allocator)
	delete(c.server.capabilities.experimental, c.allocator)
	c.server = {}
}

@(private)
_tool_headers_clear :: proc(c: ^Client) {
	for &t in c.tool_headers {
		delete(t.name, c.allocator)
		for &hp in t.params {
			delete(hp.header, c.allocator)
			for s in hp.path {
				delete(s, c.allocator)
			}
			delete(hp.path, c.allocator)
		}
		delete(t.params, c.allocator)
	}
	clear(&c.tool_headers)
}

@(private)
_find :: proc(c: ^Client, id: i64) -> (int, ^Pending) {
	for p, i in c.pending {
		if p.id == id && p.sent {
			return i, p
		}
	}
	return -1, nil
}

@(private)
_find_call :: proc(c: ^Client, call: Call) -> (int, ^Pending) {
	for p, i in c.pending {
		if p.call == call {
			return i, p
		}
	}
	return -1, nil
}

@(private)
_detach :: proc(c: ^Client, p: ^Pending) {
	for q, i in c.pending {
		if q == p {
			ordered_remove(&c.pending, i)
			return
		}
	}
}

client_start :: proc(c: ^Client) {
	if c.state == .Closed {
		return
	}
	c.listen_id = 0
	c.listen_acked = false
	c.probe_tried = {}
	c.legacy_level = .None
	switch c.era {
	case .Legacy:
		_send_initialize(c)
	case .Modern, .Unknown:
		v := version_best(c.cfg.versions, true)
		if v == .None {
			c.era = .Legacy
			_send_initialize(c)
			return
		}
		_send_discover(c, v)
	}
}

@(private)
_send_discover :: proc(c: ^Client, v: Version) {
	c.state = .Probing
	c.version = v
	c.probe_tried += {v}
	p := new(Pending, c.allocator)
	p.op = .Discover
	p.method = "server/discover"
	p.timeout_ms = c.cfg.probe_timeout_ms
	append(&c.pending, p)
	_transmit(c, p)
}

@(private)
_send_initialize :: proc(c: ^Client) {
	c.state = .Initializing
	v := version_best(c.cfg.versions, false)
	if v == .None {
		_close(c, "no legacy protocol version is enabled")
		return
	}
	c.version = v
	p := new(Pending, c.allocator)
	p.op = .Initialize
	p.method = "initialize"
	p.timeout_ms = c.cfg.request_timeout_ms
	b := make(Buf, context.temp_allocator)
	f_str(&b, "protocolVersion", version_name(v))
	w_key(&b, "capabilities")
	write_client_capabilities(&b, c.cfg.capabilities, v)
	w_key(&b, "clientInfo")
	write_implementation(&b, c.cfg.info)
	p.params = _clone(c, string(b[:]))
	append(&c.pending, p)
	_transmit(c, p)
}

@(private)
_close :: proc(c: ^Client, reason: string) {
	if c.state == .Closed {
		return
	}
	c.state = .Closed
	for len(c.pending) > 0 {
		p := pop(&c.pending)
		if p.call != 0 {
			_emit(c, Event{kind = .Error, call = p.call, op = p.op, local = true, code = JSONRPC_INTERNAL_ERROR, message = reason})
		}
		_pending_free(c, p)
	}
	_emit(c, Event{kind = .Closed, message = reason})
}

client_close :: proc(c: ^Client, reason := "client closed") {
	_close(c, reason)
}

client_transport_lost :: proc(c: ^Client, reason: string) {
	if c.state == .Closed {
		return
	}
	c.state = .Idle
	c.listen_id = 0
	c.listen_acked = false
	for &r in c.server_reqs {
		_emit(c, Event{kind = .Input_Cancelled, input = r.input, method = r.method, message = reason})
		_server_req_free(c, &r)
	}
	clear(&c.server_reqs)
	i := 0
	for i < len(c.pending) {
		p := c.pending[i]
		if p.op == .Discover || p.op == .Initialize || p.op == .Listen || p.op == .Set_Level || p.op == .Ping {
			ordered_remove(&c.pending, i)
			_pending_free(c, p)
			continue
		}
		if p.sent {
			p.sent = false
			p.attempts += 1
			if p.attempts >= c.cfg.max_attempts {
				ordered_remove(&c.pending, i)
				call, op := p.call, p.op
				_pending_free(c, p)
				_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = JSONRPC_INTERNAL_ERROR, message = reason})
				continue
			}
		}
		i += 1
	}
	_emit(c, Event{kind = .Disconnected, message = reason})
}

client_session_expired :: proc(c: ^Client) {
	if c.state == .Closed {
		return
	}
	client_transport_lost(c, "session expired")
	c.era = .Legacy
	client_start(c)
}

client_set_era :: proc(c: ^Client, era: Era) {
	c.era = era
}

@(private)
_write_meta :: proc(c: ^Client, b: ^Buf, p: ^Pending) {
	modern := version_modern(c.version)
	if !modern && !p.progress {
		return
	}
	f_obj(b, "_meta")
	if p.progress {
		f_int(b, "progressToken", p.id)
	}
	if modern {
		f_str(b, META_PROTOCOL_VERSION, version_name(c.version))
		w_key(b, META_CLIENT_INFO)
		write_implementation(b, c.cfg.info)
		w_key(b, META_CLIENT_CAPABILITIES)
		write_client_capabilities(b, c.cfg.capabilities, c.version)
		lvl := p.log if p.log != .None else c.cfg.log_level
		if lvl != .None && .Logging in c.server.capabilities.caps {
			f_str(b, META_LOG_LEVEL, LOG_LEVEL_NAMES[lvl])
		}
	}
	w_close(b)
}

@(private)
_transmit :: proc(c: ^Client, p: ^Pending) {
	p.id = c.next_id
	c.next_id += 1
	p.sent = true
	now := _now(c)
	if p.timeout_ms > 0 {
		p.deadline = now + p.timeout_ms
	} else {
		p.deadline = 0
	}
	if p.op == .Tools_Call && p.hard == 0 {
		p.hard = now + c.cfg.call_max_ms
	}
	b := make(Buf, 0, 256 + len(p.params), context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0","id":`)
	w_int(&b, p.id)
	append(&b, `,"method":`)
	w_str(&b, p.method)
	append(&b, `,"params":{`)
	if len(p.params) > 0 {
		append(&b, p.params)
	}
	if p.op == .Tools_List || p.op == .Resources_List || p.op == .Resource_Templates_List || p.op == .Prompts_List {
		if p.pages > 0 {
			f_raw(&b, "cursor", p.last_cursor)
		}
	}
	if len(p.inputs) > 0 {
		f_obj(&b, "inputResponses")
		for s in p.inputs {
			if s.answered {
				w_key(&b, s.key)
				append(&b, s.response)
			}
		}
		w_close(&b)
	}
	if p.has_state {
		f_str(&b, "requestState", p.state)
	}
	_write_meta(c, &b, p)
	append(&b, "}}")
	headers := make([dynamic]Header, context.temp_allocator)
	if c.cfg.transport == .Http && p.op == .Tools_Call {
		_tool_param_headers(c, p, &headers)
	}
	m := Outgoing {
		kind       = .Request,
		id         = p.id,
		body       = b[:],
		method     = p.method,
		name       = p.name,
		headers    = headers[:],
		long_lived = p.op == .Listen,
		initialize = p.op == .Initialize,
	}
	if p.op != .Initialize {
		m.version = version_name(c.version)
	}
	if c.sink.send != nil {
		c.sink.send(c.sink.data, c, &m)
	}
}

@(private)
_notify :: proc(c: ^Client, method: string, params: string) {
	b := make(Buf, context.temp_allocator)
	write_notification(&b, method, params)
	m := Outgoing {
		kind    = .Notification,
		body    = b[:],
		method  = method,
		version = version_name(c.version),
	}
	if c.sink.send != nil {
		c.sink.send(c.sink.data, c, &m)
	}
}

@(private)
_respond :: proc(c: ^Client, id: string, result: string, related: i64) {
	b := make(Buf, context.temp_allocator)
	write_response_result(&b, id, result)
	m := Outgoing {
		kind    = .Response,
		body    = b[:],
		version = version_name(c.version),
		related = related,
	}
	if c.sink.send != nil {
		c.sink.send(c.sink.data, c, &m)
	}
}

@(private)
_respond_error :: proc(c: ^Client, id: string, code: i64, message: string, related: i64) {
	b := make(Buf, context.temp_allocator)
	write_response_error(&b, id, code, message)
	m := Outgoing {
		kind    = .Response,
		body    = b[:],
		version = version_name(c.version),
		related = related,
	}
	if c.sink.send != nil {
		c.sink.send(c.sink.data, c, &m)
	}
}

@(private)
_begin :: proc(c: ^Client, op: Op, method: string, params: string, name := "", progress := false, log := Log_Level.None, timeout_ms: i64 = 0) -> Call {
	if c.state == .Closed {
		call := Call(c.next_call)
		c.next_call += 1
		_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = JSONRPC_INTERNAL_ERROR, message = "client closed"})
		return call
	}
	p := new(Pending, c.allocator)
	p.call = Call(c.next_call)
	c.next_call += 1
	p.op = op
	p.method = method
	p.params = _clone(c, params)
	p.name = _clone(c, name)
	p.progress = progress
	p.log = log
	p.timeout_ms = timeout_ms
	if p.timeout_ms == 0 {
		p.timeout_ms = c.cfg.call_timeout_ms if op == .Tools_Call else c.cfg.request_timeout_ms
	}
	if op == .Listen {
		p.timeout_ms = -1
	}
	append(&c.pending, p)
	if c.state == .Ready {
		_dispatch(c, p)
	}
	return p.call
}

@(private)
_capable :: proc(c: ^Client, op: Op) -> bool {
	caps := c.server.capabilities.caps
	switch op {
	case .Tools_List, .Tools_Call:
		return .Tools in caps
	case .Resources_List, .Resource_Templates_List, .Resources_Read, .Unsubscribe:
		return .Resources in caps
	case .Subscribe:
		return .Resources_Subscribe in caps
	case .Prompts_List, .Prompts_Get:
		return .Prompts in caps
	case .Complete:
		return .Completions in caps || c.version < .V2025_03_26
	case .Raw, .Discover, .Initialize, .Listen, .Set_Level, .Ping:
	}
	return true
}

@(private)
_dispatch :: proc(c: ^Client, p: ^Pending) {
	if p.call != 0 && !_capable(c, p.op) {
		call, op := p.call, p.op
		_detach(c, p)
		_pending_free(c, p)
		_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = JSONRPC_METHOD_NOT_FOUND, message = "server does not declare the capability for this request"})
		return
	}
	_transmit(c, p)
}

@(private)
_cached :: proc(c: ^Client, op: Op) -> (string, bool) {
	lc := &c.caches[op]
	if lc.valid && _now(c) < lc.expires {
		return lc.json, true
	}
	return "", false
}

@(private)
_list :: proc(c: ^Client, op: Op, method: string, fresh: bool) -> Call {
	if !fresh {
		if j, ok := _cached(c, op); ok {
			call := Call(c.next_call)
			c.next_call += 1
			_emit(c, Event{kind = .Result, call = call, op = op, result = j})
			return call
		}
	}
	return _begin(c, op, method, "")
}

client_list_tools :: proc(c: ^Client, fresh := false) -> Call {
	return _list(c, .Tools_List, "tools/list", fresh)
}

client_list_resources :: proc(c: ^Client, fresh := false) -> Call {
	return _list(c, .Resources_List, "resources/list", fresh)
}

client_list_resource_templates :: proc(c: ^Client, fresh := false) -> Call {
	return _list(c, .Resource_Templates_List, "resources/templates/list", fresh)
}

client_list_prompts :: proc(c: ^Client, fresh := false) -> Call {
	return _list(c, .Prompts_List, "prompts/list", fresh)
}

Call_Options :: struct {
	progress:   bool,
	log_level:  Log_Level,
	timeout_ms: i64,
}

client_call_tool :: proc(c: ^Client, name: string, arguments: string, opts := Call_Options{}) -> Call {
	b := make(Buf, context.temp_allocator)
	f_str(&b, "name", name)
	args := json_trim(arguments)
	if len(args) > 0 && json_kind(args) == .Object {
		f_raw(&b, "arguments", args)
	} else {
		f_raw(&b, "arguments", "{}")
	}
	return _begin(c, .Tools_Call, "tools/call", string(b[:]), name, opts.progress, opts.log_level, opts.timeout_ms)
}

client_read_resource :: proc(c: ^Client, uri: string, opts := Call_Options{}) -> Call {
	b := make(Buf, context.temp_allocator)
	f_str(&b, "uri", uri)
	return _begin(c, .Resources_Read, "resources/read", string(b[:]), uri, opts.progress, opts.log_level, opts.timeout_ms)
}

client_get_prompt :: proc(c: ^Client, name: string, arguments: string, opts := Call_Options{}) -> Call {
	b := make(Buf, context.temp_allocator)
	f_str(&b, "name", name)
	args := json_trim(arguments)
	if len(args) > 0 && json_kind(args) == .Object {
		f_raw(&b, "arguments", args)
	}
	return _begin(c, .Prompts_Get, "prompts/get", string(b[:]), name, opts.progress, opts.log_level, opts.timeout_ms)
}

client_complete :: proc(c: ^Client, ref: string, argument: string, value: string, context_arguments := "") -> Call {
	b := make(Buf, context.temp_allocator)
	f_raw(&b, "ref", json_trim(ref))
	f_obj(&b, "argument")
	f_str(&b, "name", argument)
	f_str(&b, "value", value)
	w_close(&b)
	if ctx := json_trim(context_arguments); len(ctx) > 0 && json_kind(ctx) == .Object {
		f_obj(&b, "context")
		f_raw(&b, "arguments", ctx)
		w_close(&b)
	}
	return _begin(c, .Complete, "completion/complete", string(b[:]))
}

client_request :: proc(c: ^Client, method: string, params_members: string, opts := Call_Options{}) -> Call {
	return _begin(c, .Raw, method, params_members, "", opts.progress, opts.log_level, opts.timeout_ms)
}

client_notify :: proc(c: ^Client, method: string, params: string) {
	if c.state != .Ready {
		return
	}
	_notify(c, method, params)
}

client_set_log_level :: proc(c: ^Client, level: Log_Level) {
	c.cfg.log_level = level
	if c.state == .Ready && c.era == .Legacy {
		_legacy_set_level(c)
	}
}

@(private)
_legacy_set_level :: proc(c: ^Client) {
	if .Logging not_in c.server.capabilities.caps || c.cfg.log_level == .None || c.cfg.log_level == c.legacy_level {
		return
	}
	c.legacy_level = c.cfg.log_level
	b := make(Buf, context.temp_allocator)
	f_str(&b, "level", LOG_LEVEL_NAMES[c.cfg.log_level])
	p := new(Pending, c.allocator)
	p.op = .Set_Level
	p.method = "logging/setLevel"
	p.params = _clone(c, string(b[:]))
	p.timeout_ms = c.cfg.request_timeout_ms
	append(&c.pending, p)
	_transmit(c, p)
}

client_set_roots :: proc(c: ^Client, roots: string) {
	r := json_trim(roots)
	if json_kind(r) != .Array {
		r = "[]"
	}
	changed := !c.roots_set || c.roots != r
	delete(c.roots, c.allocator)
	c.roots = _clone(c, r)
	c.roots_set = true
	if changed && c.state == .Ready && c.era == .Legacy && .Roots_List_Changed in c.cfg.capabilities.caps {
		_notify(c, "notifications/roots/list_changed", "")
	}
}

client_watch :: proc(c: ^Client, flags: Watch_Flags) {
	if c.cfg.watch == flags {
		return
	}
	c.cfg.watch = flags
	_resubscribe(c)
}

client_subscribe :: proc(c: ^Client, uri: string) -> Call {
	for u in c.sub_uris {
		if u == uri {
			return 0
		}
	}
	append(&c.sub_uris, _clone(c, uri))
	if c.era == .Legacy {
		if c.state != .Ready {
			return 0
		}
		b := make(Buf, context.temp_allocator)
		f_str(&b, "uri", uri)
		return _begin(c, .Subscribe, "resources/subscribe", string(b[:]), uri)
	}
	_resubscribe(c)
	return 0
}

client_unsubscribe :: proc(c: ^Client, uri: string) -> Call {
	found := false
	for u, i in c.sub_uris {
		if u == uri {
			delete(u, c.allocator)
			ordered_remove(&c.sub_uris, i)
			found = true
			break
		}
	}
	if !found {
		return 0
	}
	if c.era == .Legacy {
		if c.state != .Ready {
			return 0
		}
		b := make(Buf, context.temp_allocator)
		f_str(&b, "uri", uri)
		return _begin(c, .Unsubscribe, "resources/unsubscribe", string(b[:]), uri)
	}
	_resubscribe(c)
	return 0
}

@(private)
_want_listen :: proc(c: ^Client) -> bool {
	caps := c.server.capabilities.caps
	if .Tools in c.cfg.watch && .Tools_List_Changed in caps {
		return true
	}
	if .Prompts in c.cfg.watch && .Prompts_List_Changed in caps {
		return true
	}
	if .Resources in c.cfg.watch && .Resources_List_Changed in caps {
		return true
	}
	return len(c.sub_uris) > 0 && .Resources_Subscribe in caps
}

@(private)
_resubscribe :: proc(c: ^Client) {
	if c.state != .Ready || c.era != .Modern {
		return
	}
	if c.listen_id != 0 {
		_, p := _find(c, c.listen_id)
		c.listen_id = 0
		c.listen_acked = false
		if p != nil {
			_abort(c, p, "subscription replaced")
			_detach(c, p)
			_pending_free(c, p)
		}
	}
	if !_want_listen(c) {
		return
	}
	caps := c.server.capabilities.caps
	b := make(Buf, context.temp_allocator)
	f_obj(&b, "notifications")
	if .Tools in c.cfg.watch && .Tools_List_Changed in caps {
		f_bool(&b, "toolsListChanged", true)
	}
	if .Prompts in c.cfg.watch && .Prompts_List_Changed in caps {
		f_bool(&b, "promptsListChanged", true)
	}
	if .Resources in c.cfg.watch && .Resources_List_Changed in caps {
		f_bool(&b, "resourcesListChanged", true)
	}
	if len(c.sub_uris) > 0 && .Resources_Subscribe in caps {
		f_arr(&b, "resourceSubscriptions")
		for u in c.sub_uris {
			w_item_str(&b, u)
		}
		w_close_arr(&b)
	}
	w_close(&b)
	p := new(Pending, c.allocator)
	p.op = .Listen
	p.method = "subscriptions/listen"
	p.params = _clone(c, string(b[:]))
	p.timeout_ms = -1
	append(&c.pending, p)
	_transmit(c, p)
	c.listen_id = p.id
	c.listen_acked = false
}

@(private)
_abort :: proc(c: ^Client, p: ^Pending, reason: string) {
	if !p.sent {
		return
	}
	if c.cfg.transport == .Http && c.era == .Modern {
		m := Outgoing {
			kind = .Abort,
			id   = p.id,
		}
		if c.sink.send != nil {
			c.sink.send(c.sink.data, c, &m)
		}
		return
	}
	b := make(Buf, context.temp_allocator)
	f_int(&b, "requestId", p.id)
	if reason != "" {
		f_str(&b, "reason", reason)
	}
	params := strings.concatenate({"{", string(b[:]), "}"}, context.temp_allocator)
	_notify(c, "notifications/cancelled", params)
	if c.cfg.transport == .Http {
		m := Outgoing {
			kind = .Abort,
			id   = p.id,
		}
		if c.sink.send != nil {
			c.sink.send(c.sink.data, c, &m)
		}
	}
}

client_cancel :: proc(c: ^Client, call: Call, reason := "") -> bool {
	_, p := _find_call(c, call)
	if p == nil {
		return false
	}
	_abort(c, p, reason)
	_detach(c, p)
	_pending_free(c, p)
	return true
}

client_answer :: proc(c: ^Client, input: Input, result: string) -> bool {
	r := json_trim(result)
	if json_kind(r) != .Object {
		return false
	}
	for &sr, i in c.server_reqs {
		if sr.input == input {
			id := strings.clone(sr.id, context.temp_allocator)
			related := sr.related
			_server_req_free(c, &sr)
			ordered_remove(&c.server_reqs, i)
			_respond(c, id, r, related)
			return true
		}
	}
	for p in c.pending {
		for &s in p.inputs {
			if s.id == input && !s.answered {
				s.response = _clone(c, r)
				s.answered = true
				_maybe_retry(c, p)
				return true
			}
		}
	}
	return false
}

client_reject :: proc(c: ^Client, input: Input, code: i64 = -1, message := "rejected") -> bool {
	for &sr, i in c.server_reqs {
		if sr.input == input {
			id := strings.clone(sr.id, context.temp_allocator)
			related := sr.related
			_server_req_free(c, &sr)
			ordered_remove(&c.server_reqs, i)
			_respond_error(c, id, code, message, related)
			return true
		}
	}
	for p in c.pending {
		for s in p.inputs {
			if s.id == input {
				call, op := p.call, p.op
				_detach(c, p)
				_pending_free(c, p)
				_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = code, message = message})
				return true
			}
		}
	}
	return false
}

@(private)
_maybe_retry :: proc(c: ^Client, p: ^Pending) {
	if !p.waiting || p.refresh != 0 {
		return
	}
	for s in p.inputs {
		if !s.answered {
			return
		}
	}
	p.waiting = false
	if c.state == .Ready {
		_transmit(c, p)
	} else {
		p.sent = false
	}
}

client_next_deadline :: proc(c: ^Client) -> (deadline: i64, ok: bool) {
	for p in c.pending {
		if !p.sent || p.waiting {
			continue
		}
		if p.deadline > 0 && (!ok || p.deadline < deadline) {
			deadline = p.deadline
			ok = true
		}
		if p.hard > 0 && (!ok || p.hard < deadline) {
			deadline = p.hard
			ok = true
		}
	}
	if c.listen_retry > 0 && (!ok || c.listen_retry < deadline) {
		deadline = c.listen_retry
		ok = true
	}
	return
}

client_tick :: proc(c: ^Client) {
	now := _now(c)
	if c.listen_retry > 0 && now >= c.listen_retry {
		c.listen_retry = 0
		_resubscribe(c)
	}
	for {
		var_p: ^Pending
		for p in c.pending {
			if !p.sent || p.waiting {
				continue
			}
			if (p.deadline > 0 && now >= p.deadline) || (p.hard > 0 && now >= p.hard) {
				var_p = p
				break
			}
		}
		if var_p == nil {
			return
		}
		p := var_p
		if p.op == .Discover {
			_detach(c, p)
			_pending_free(c, p)
			c.era = .Legacy
			_send_initialize(c)
			continue
		}
		_abort(c, p, "timeout")
		_detach(c, p)
		call, op := p.call, p.op
		_pending_free(c, p)
		if op == .Initialize {
			_close(c, "initialize timed out")
			return
		}
		if call != 0 {
			_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = JSONRPC_INTERNAL_ERROR, message = "request timed out"})
		}
	}
}

client_receive :: proc(c: ^Client, raw: []u8, related: i64 = 0) {
	if c.state == .Closed {
		return
	}
	m, ok := message_parse(string(raw))
	if !ok {
		_emit(c, Event{kind = .Warning, message = "invalid JSON from server", data = string(raw)})
		return
	}
	switch m.kind {
	case .Invalid:
		_emit(c, Event{kind = .Warning, message = "invalid JSON-RPC message from server", data = string(raw)})
	case .Result, .Error:
		_on_response(c, &m)
	case .Notification:
		_on_notification(c, &m)
	case .Request:
		_on_server_request(c, &m, related)
	}
}

@(private)
_response_id :: proc(m: ^Message) -> (i64, bool) {
	if m.id == "" || json_kind(m.id) != .Number {
		return 0, false
	}
	return json_int(m.id)
}

@(private)
_on_response :: proc(c: ^Client, m: ^Message) {
	id, ok := _response_id(m)
	if !ok {
		if m.kind == .Error {
			_emit(c, Event{kind = .Warning, message = error_message(m.error), data = m.error})
		}
		return
	}
	_, p := _find(c, id)
	if p == nil {
		return
	}
	if m.kind == .Error {
		_on_error(c, p, m.error)
		return
	}
	_on_result(c, p, m.result)
}

@(private)
_is_modern_error :: proc(code: i64) -> bool {
	return code == MCP_HEADER_MISMATCH || code == MCP_MISSING_CLIENT_CAPABILITY || code == MCP_UNSUPPORTED_VERSION
}

@(private)
_pick_supported :: proc(c: ^Client, data: string) -> (Version, Versions) {
	set: Versions
	if arr, ok := json_get_array(data, "supported"); ok {
		it, _ := json_array(arr)
		for v in json_next_item(&it) {
			s, sok := json_string(v)
			if !sok {
				continue
			}
			ver := version_parse(s)
			if ver != .None {
				set += {ver}
			}
		}
	}
	common := set & c.cfg.versions
	if v := version_best(common, true); v != .None {
		return v, set
	}
	return version_best(common, false), set
}

@(private)
_on_error :: proc(c: ^Client, p: ^Pending, err: string) {
	code := error_code(err)
	data, _ := json_get(err, "data")
	switch p.op {
	case .Discover:
		_detach(c, p)
		_pending_free(c, p)
		if code == MCP_UNSUPPORTED_VERSION {
			c.era = .Modern
			v, _ := _pick_supported(c, data)
			if v == .None {
				_close(c, "server supports no common protocol version")
				return
			}
			if !version_modern(v) {
				c.era = .Legacy
				_send_initialize(c)
				return
			}
			if v in c.probe_tried {
				_close(c, "server rejected every common protocol version")
				return
			}
			_send_discover(c, v)
			return
		}
		if _is_modern_error(code) {
			c.era = .Modern
			_server_info_clear(c)
			c.server.capabilities.caps = ~Server_Caps{}
			_become_ready(c)
			return
		}
		c.era = .Legacy
		_send_initialize(c)
		return
	case .Initialize:
		msg := error_message(err)
		_detach(c, p)
		_pending_free(c, p)
		if code == MCP_UNSUPPORTED_VERSION || (code == JSONRPC_INVALID_PARAMS && json_has(data, "supported")) {
			v, _ := _pick_supported(c, data)
			if version_modern(v) && c.era != .Modern {
				c.era = .Modern
				_send_discover(c, v)
				return
			}
		}
		_close(c, strings.concatenate({"initialize failed: ", msg}, context.temp_allocator))
		return
	case .Listen:
		_detach(c, p)
		_pending_free(c, p)
		c.listen_id = 0
		c.listen_acked = false
		_emit(c, Event{kind = .Warning, code = code, message = error_message(err), data = data})
		return
	case .Set_Level, .Ping:
		_detach(c, p)
		_pending_free(c, p)
		return
	case .Raw, .Tools_List, .Tools_Call, .Resources_List, .Resource_Templates_List, .Resources_Read, .Prompts_List, .Prompts_Get, .Complete, .Subscribe, .Unsubscribe:
	}
	if code == MCP_UNSUPPORTED_VERSION && c.era == .Modern && p.attempts + 1 < c.cfg.max_attempts {
		v, _ := _pick_supported(c, data)
		if version_modern(v) && v != c.version {
			c.version = v
			p.attempts += 1
			_transmit(c, p)
			return
		}
	}
	if code == MCP_LEGACY_URL_ELICITATION_REQUIRED && c.era == .Legacy && .Elicitation_Url in c.cfg.capabilities.caps {
		if arr, ok := json_get_array(data, "elicitations"); ok {
			_clear_inputs(c, p)
			it, _ := json_array(arr)
			for e in json_next_item(&it) {
				key := strings.concatenate({"url-", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(len(p.inputs)), 10)}, context.temp_allocator)
				_add_input(c, p, key, "elicitation/create", e)
			}
			if len(p.inputs) > 0 {
				p.has_state = false
				p.waiting = true
				_emit_inputs(c, p)
				return
			}
		}
	}
	if code == MCP_HEADER_MISMATCH && p.op == .Tools_Call && p.attempts + 1 < c.cfg.max_attempts && !p.retry_url {
		p.retry_url = true
		p.attempts += 1
		c.caches[.Tools_List].valid = false
		p.waiting = true
		p.refresh = _begin(c, .Tools_List, "tools/list", "")
		if _, q := _find_call(c, p.refresh); q != nil {
			append(&c.internal, p.refresh)
		}
		return
	}
	if (p.op == .Tools_List || p.op == .Resources_List || p.op == .Resource_Templates_List || p.op == .Prompts_List) && p.pages > 0 && code == JSONRPC_INVALID_PARAMS && p.attempts + 1 < c.cfg.max_attempts {
		p.attempts += 1
		p.pages = 0
		clear(&p.accum)
		_transmit(c, p)
		return
	}
	call, op := p.call, p.op
	_detach(c, p)
	_pending_free(c, p)
	if call != 0 {
		_emit(c, Event{kind = .Error, call = call, op = op, code = code, message = error_message(err), data = data})
		_refresh_done(c, call)
	}
}

@(private)
_refresh_done :: proc(c: ^Client, call: Call) {
	waiting := make([dynamic]^Pending, context.temp_allocator)
	for p in c.pending {
		if p.refresh == call && p.waiting {
			append(&waiting, p)
		}
	}
	for p in waiting {
		for q in c.pending {
			if q == p {
				p.refresh = 0
				p.waiting = false
				if c.state == .Ready {
					_transmit(c, p)
				} else {
					p.sent = false
				}
				break
			}
		}
	}
}

@(private)
_clear_inputs :: proc(c: ^Client, p: ^Pending) {
	for &s in p.inputs {
		_input_slot_free(c, &s)
	}
	clear(&p.inputs)
}

@(private)
_add_input :: proc(c: ^Client, p: ^Pending, key: string, method: string, params: string) {
	s := Input_Slot {
		id     = Input(c.next_input),
		key    = _clone(c, key),
		method = _clone(c, method),
		params = _clone(c, json_trim(params)),
	}
	c.next_input += 1
	append(&p.inputs, s)
}

@(private)
_emit_inputs :: proc(c: ^Client, p: ^Pending) {
	call := p.call
	ids := make([dynamic]Input, context.temp_allocator)
	for s in p.inputs {
		append(&ids, s.id)
	}
	for id in ids {
		_, q := _find_call(c, call)
		if q == nil {
			return
		}
		for &s in q.inputs {
			if s.id != id || s.answered {
				continue
			}
			if s.method == "roots/list" && c.roots_set {
				b := make(Buf, context.temp_allocator)
				append(&b, `{"roots":`)
				append(&b, c.roots)
				append(&b, '}')
				s.response = _clone(c, string(b[:]))
				s.answered = true
				break
			}
			method := strings.clone(s.method, context.temp_allocator)
			params := strings.clone(s.params, context.temp_allocator)
			key := strings.clone(s.key, context.temp_allocator)
			_emit(c, Event{kind = .Input_Request, call = call, input = id, op = q.op, method = method, params = params, key = key})
			break
		}
	}
	_, q := _find_call(c, call)
	if q != nil {
		_maybe_retry(c, q)
	}
}

@(private)
_input_allowed :: proc(c: ^Client, method: string, params: string) -> bool {
	caps := c.cfg.capabilities.caps
	switch method {
	case "roots/list":
		return .Roots in caps
	case "sampling/createMessage":
		return .Sampling in caps
	case "elicitation/create":
		mode, _ := json_get_string(params, "mode")
		if mode == "url" {
			return .Elicitation_Url in caps
		}
		return .Elicitation_Form in caps
	}
	return false
}

@(private)
_on_result :: proc(c: ^Client, p: ^Pending, result: string) {
	if json_kind(result) != .Object {
		_fail(c, p, "result is not an object")
		return
	}
	rt := "complete"
	if v, ok := json_get(result, "resultType"); ok {
		s, sok := json_string(v)
		if !sok {
			_fail(c, p, "invalid resultType")
			return
		}
		rt = s
	}
	switch p.op {
	case .Discover:
		_on_discover(c, p, result)
		return
	case .Initialize:
		_on_initialize(c, p, result)
		return
	case .Listen:
		_detach(c, p)
		_pending_free(c, p)
		if c.listen_id != 0 {
			c.listen_id = 0
			c.listen_acked = false
			c.listen_retry = _now(c) + 1000
		}
		return
	case .Set_Level, .Ping:
		_detach(c, p)
		_pending_free(c, p)
		return
	case .Raw, .Tools_List, .Tools_Call, .Resources_List, .Resource_Templates_List, .Resources_Read, .Prompts_List, .Prompts_Get, .Complete, .Subscribe, .Unsubscribe:
	}
	if rt == "input_required" {
		if p.op != .Tools_Call && p.op != .Prompts_Get && p.op != .Resources_Read && p.op != .Raw {
			_fail(c, p, "input_required is not allowed for this request")
			return
		}
		_on_input_required(c, p, result)
		return
	}
	if rt != "complete" {
		_fail(c, p, "unrecognized resultType")
		return
	}
	switch p.op {
	case .Tools_List:
		_on_page(c, p, result, "tools")
		return
	case .Resources_List:
		_on_page(c, p, result, "resources")
		return
	case .Resource_Templates_List:
		_on_page(c, p, result, "resourceTemplates")
		return
	case .Prompts_List:
		_on_page(c, p, result, "prompts")
		return
	case .Raw, .Discover, .Initialize, .Tools_Call, .Resources_Read, .Prompts_Get, .Complete, .Subscribe, .Unsubscribe, .Listen, .Set_Level, .Ping:
	}
	call, op := p.call, p.op
	_detach(c, p)
	_pending_free(c, p)
	if call != 0 {
		_emit(c, Event{kind = .Result, call = call, op = op, result = result})
	}
}

@(private)
_fail :: proc(c: ^Client, p: ^Pending, msg: string) {
	call, op := p.call, p.op
	_detach(c, p)
	_pending_free(c, p)
	if call != 0 {
		_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = JSONRPC_INTERNAL_ERROR, message = msg})
	}
}

@(private)
_on_input_required :: proc(c: ^Client, p: ^Pending, result: string) {
	reqs, has_reqs := json_get_object(result, "inputRequests")
	state_raw, has_state := json_get(result, "requestState")
	if !has_reqs && !has_state {
		_fail(c, p, "input_required result carries neither inputRequests nor requestState")
		return
	}
	delete(p.state, c.allocator)
	p.state = ""
	p.has_state = false
	if has_state {
		s, ok := json_string(state_raw)
		if !ok {
			_fail(c, p, "invalid requestState")
			return
		}
		p.state = _clone(c, s)
		p.has_state = true
	}
	_clear_inputs(c, p)
	if has_reqs {
		it, _ := json_object(reqs)
		for k, v in json_next_member(&it) {
			key, kok := json_string(k)
			method, mok := json_get_string(v, "method")
			params, _ := json_get(v, "params")
			if !kok || !mok {
				_fail(c, p, "invalid input request")
				return
			}
			if !_input_allowed(c, method, params) {
				_fail(c, p, strings.concatenate({"server requested undeclared capability: ", method}, context.temp_allocator))
				return
			}
			_add_input(c, p, key, method, params if params != "" else "{}")
		}
	}
	p.attempts = 0
	if len(p.inputs) == 0 {
		_transmit(c, p)
		return
	}
	p.waiting = true
	_emit_inputs(c, p)
}

@(private)
_on_page :: proc(c: ^Client, p: ^Pending, result: string, field: string) {
	arr, ok := json_get_array(result, field)
	if !ok {
		_fail(c, p, "list result is missing its array")
		return
	}
	it, _ := json_array(arr)
	for item in json_next_item(&it) {
		if p.op == .Tools_List && c.cfg.transport == .Http && c.era == .Modern {
			if reason, valid := _tool_header_check(c, item); !valid {
				name, _ := json_get_string(item, "name")
				_emit(c, Event{kind = .Warning, message = reason, data = name})
				continue
			}
		}
		w_item_raw(&p.accum, json_trim(item))
	}
	ttl: i64 = 0
	if t, tok := json_get_int(result, "ttlMs"); tok && t > 0 {
		ttl = t
	}
	if p.pages == 0 || ttl < p.ttl {
		p.ttl = ttl
	}
	if s, _ := json_get_string(result, "cacheScope"); s == "private" {
		p.private = true
	}
	p.pages += 1
	if cur, has := json_get(result, "nextCursor"); has && json_kind(cur) == .String {
		if p.pages >= c.cfg.max_pages {
			_fail(c, p, "too many pages")
			return
		}
		delete(p.last_cursor, c.allocator)
		p.last_cursor = _clone(c, json_trim(cur))
		_transmit(c, p)
		return
	}
	b := make(Buf, 0, len(p.accum) + len(field) + 8, context.temp_allocator)
	append(&b, '{')
	w_str(&b, field)
	append(&b, ":[")
	append(&b, ..p.accum[:])
	append(&b, "]}")
	out := string(b[:])
	if p.op == .Tools_List {
		_store_tool_headers(c, out)
	}
	lc := &c.caches[p.op]
	delete(lc.json, c.allocator)
	lc.json = _clone(c, out)
	lc.expires = _now(c) + p.ttl
	lc.valid = true
	call, op := p.call, p.op
	_detach(c, p)
	_pending_free(c, p)
	if call != 0 {
		_emit(c, Event{kind = .Result, call = call, op = op, result = out})
		_refresh_done(c, call)
	}
}

client_cached_tools :: proc(c: ^Client) -> (string, bool) {
	lc := &c.caches[.Tools_List]
	return lc.json, lc.valid
}

@(private)
_read_server_info :: proc(c: ^Client, impl: string) {
	if json_kind(impl) != .Object {
		return
	}
	c.server.impl = _clone(c, json_trim(impl))
	name, _ := json_get_string(impl, "name")
	ver, _ := json_get_string(impl, "version")
	c.server.name = _clone(c, name)
	c.server.version_text = _clone(c, ver)
}

@(private)
_read_caps :: proc(c: ^Client, raw: string) {
	sc := read_server_capabilities(raw)
	sc.extensions = _clone(c, sc.extensions)
	sc.experimental = _clone(c, sc.experimental)
	c.server.capabilities = sc
}

@(private)
_on_discover :: proc(c: ^Client, p: ^Pending, result: string) {
	_detach(c, p)
	_pending_free(c, p)
	c.era = .Modern
	_server_info_clear(c)
	set: Versions
	if arr, ok := json_get_array(result, "supportedVersions"); ok {
		it, _ := json_array(arr)
		for v in json_next_item(&it) {
			if s, sok := json_string(v); sok {
				if ver := version_parse(s); ver != .None {
					set += {ver}
				}
			}
		}
	}
	c.server.supported = set
	common := set & c.cfg.versions
	v := version_best(common, true)
	if v == .None {
		if version_best(common, false) != .None {
			c.era = .Legacy
			_send_initialize(c)
			return
		}
		_close(c, "server supports no common protocol version")
		return
	}
	if caps, ok := json_get_object(result, "capabilities"); ok {
		_read_caps(c, caps)
	}
	if meta, ok := json_get_object(result, "_meta"); ok {
		if impl, iok := json_get(meta, META_SERVER_INFO); iok {
			_read_server_info(c, impl)
		}
	}
	if ins, ok := json_get_string(result, "instructions"); ok {
		c.server.instructions = _clone(c, ins)
	}
	if v != c.version {
		c.version = v
	}
	_become_ready(c)
}

@(private)
_on_initialize :: proc(c: ^Client, p: ^Pending, result: string) {
	_detach(c, p)
	_pending_free(c, p)
	vs, _ := json_get_string(result, "protocolVersion")
	v := version_parse(vs)
	if v == .None || v not_in c.cfg.versions || version_modern(v) {
		_close(c, strings.concatenate({"server chose unsupported protocol version ", vs}, context.temp_allocator))
		return
	}
	c.era = .Legacy
	c.version = v
	_server_info_clear(c)
	c.server.supported = {v}
	if caps, ok := json_get_object(result, "capabilities"); ok {
		_read_caps(c, caps)
	}
	if impl, ok := json_get(result, "serverInfo"); ok {
		_read_server_info(c, impl)
	}
	if ins, ok := json_get_string(result, "instructions"); ok {
		c.server.instructions = _clone(c, ins)
	}
	_notify(c, "notifications/initialized", "")
	_become_ready(c)
}

@(private)
_become_ready :: proc(c: ^Client) {
	c.state = .Ready
	for &lc in c.caches {
		lc.valid = false
	}
	_emit(c, Event{kind = .Ready, message = version_name(c.version)})
	if c.state != .Ready {
		return
	}
	if c.era == .Legacy {
		_legacy_set_level(c)
		if .Resources_Subscribe in c.server.capabilities.caps {
			for u in c.sub_uris {
				b := make(Buf, context.temp_allocator)
				f_str(&b, "uri", u)
				p := new(Pending, c.allocator)
				p.op = .Subscribe
				p.method = "resources/subscribe"
				p.params = _clone(c, string(b[:]))
				p.timeout_ms = c.cfg.request_timeout_ms
				append(&c.pending, p)
				_transmit(c, p)
			}
		}
	}
	queued := make([dynamic]^Pending, context.temp_allocator)
	for p in c.pending {
		if !p.sent && !p.waiting {
			append(&queued, p)
		}
	}
	for p in queued {
		still := false
		for q in c.pending {
			if q == p {
				still = true
				break
			}
		}
		if still && !p.sent {
			_dispatch(c, p)
		}
	}
	_resubscribe(c)
}

@(private)
_on_notification :: proc(c: ^Client, m: ^Message) {
	params := m.params if m.params != "" else "{}"
	if c.era == .Modern {
		if meta, ok := json_get_object(params, "_meta"); ok {
			if sid, sok := json_get(meta, META_SUBSCRIPTION_ID); sok {
				id, iok := json_int(sid)
				if !iok || id != c.listen_id || c.listen_id == 0 {
					return
				}
				if m.method == "notifications/subscriptions/acknowledged" {
					c.listen_acked = true
					filt, _ := json_get_object(params, "notifications")
					_emit(c, Event{kind = .Subscribed, params = filt})
					return
				}
				if !c.listen_acked {
					return
				}
			}
		}
	}
	switch m.method {
	case "notifications/progress":
		tok, ok := json_get(params, "progressToken")
		if !ok {
			return
		}
		id, iok := json_int(tok)
		if !iok {
			return
		}
		_, p := _find(c, id)
		if p == nil || !p.progress {
			return
		}
		pr, _ := json_get(params, "progress")
		prog, pok := json_number(pr)
		if !pok {
			return
		}
		e := Event{kind = .Progress, call = p.call, op = p.op, progress = prog}
		if t, tok2 := json_get(params, "total"); tok2 {
			e.total, e.has_total = json_number(t)
		}
		e.message, _ = json_get_string(params, "message")
		if p.timeout_ms > 0 {
			p.deadline = _now(c) + p.timeout_ms
		}
		_emit(c, e)
	case "notifications/message":
		lv, _ := json_get_string(params, "level")
		e := Event{kind = .Log, level = log_level_parse(lv)}
		e.logger, _ = json_get_string(params, "logger")
		e.data, _ = json_get(params, "data")
		e.data = json_trim(e.data)
		_emit(c, e)
	case "notifications/cancelled":
		rid, ok := json_get(params, "requestId")
		if !ok {
			return
		}
		if c.era == .Modern {
			id, iok := json_int(rid)
			if iok && id == c.listen_id && c.listen_id != 0 {
				_, p := _find(c, id)
				if p != nil {
					_detach(c, p)
					_pending_free(c, p)
				}
				c.listen_id = 0
				c.listen_acked = false
				c.listen_retry = _now(c) + 1000
			}
			return
		}
		key := json_trim(rid)
		for &sr, i in c.server_reqs {
			if sr.id == key {
				input, method := sr.input, strings.clone(sr.method, context.temp_allocator)
				_server_req_free(c, &sr)
				ordered_remove(&c.server_reqs, i)
				reason, _ := json_get_string(params, "reason")
				_emit(c, Event{kind = .Input_Cancelled, input = input, method = method, message = reason})
				return
			}
		}
	case "notifications/tools/list_changed":
		c.caches[.Tools_List].valid = false
		_emit(c, Event{kind = .Tools_Changed})
	case "notifications/prompts/list_changed":
		c.caches[.Prompts_List].valid = false
		_emit(c, Event{kind = .Prompts_Changed})
	case "notifications/resources/list_changed":
		c.caches[.Resources_List].valid = false
		c.caches[.Resource_Templates_List].valid = false
		_emit(c, Event{kind = .Resources_Changed})
	case "notifications/resources/updated":
		uri, _ := json_get_string(params, "uri")
		_emit(c, Event{kind = .Resource_Updated, message = uri})
	case "notifications/elicitation/complete":
		eid, _ := json_get_string(params, "elicitationId")
		_emit(c, Event{kind = .Elicitation_Complete, message = eid})
	case:
		_emit(c, Event{kind = .Notification, method = m.method, params = params})
	}
}

@(private)
_on_server_request :: proc(c: ^Client, m: ^Message, related: i64) {
	params := m.params if m.params != "" else "{}"
	if c.era == .Modern {
		_respond_error(c, m.id, JSONRPC_INVALID_REQUEST, "servers must not send requests in this protocol version", related)
		return
	}
	switch m.method {
	case "ping":
		_respond(c, m.id, "{}", related)
		return
	case "roots/list":
		if .Roots not_in c.cfg.capabilities.caps {
			_respond_error(c, m.id, JSONRPC_METHOD_NOT_FOUND, "roots not supported", related)
			return
		}
		if c.roots_set {
			b := make(Buf, context.temp_allocator)
			append(&b, `{"roots":`)
			append(&b, c.roots)
			append(&b, '}')
			_respond(c, m.id, string(b[:]), related)
			return
		}
	case "sampling/createMessage", "elicitation/create":
		if !_input_allowed(c, m.method, params) {
			_respond_error(c, m.id, JSONRPC_METHOD_NOT_FOUND, "capability not declared", related)
			return
		}
	case:
		_respond_error(c, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", related)
		return
	}
	for sr in c.server_reqs {
		if sr.id == m.id {
			_respond_error(c, m.id, JSONRPC_INVALID_REQUEST, "duplicate request id", related)
			return
		}
	}
	input := Input(c.next_input)
	c.next_input += 1
	append(&c.server_reqs, Server_Request{input = input, id = _clone(c, m.id), method = _clone(c, m.method), related = related})
	call: Call
	if related != 0 {
		if _, p := _find(c, related); p != nil {
			call = p.call
		}
	}
	_emit(c, Event{kind = .Input_Request, call = call, input = input, method = m.method, params = params})
}

client_ping :: proc(c: ^Client) {
	if c.state != .Ready || c.era != .Legacy {
		return
	}
	p := new(Pending, c.allocator)
	p.op = .Ping
	p.method = "ping"
	p.timeout_ms = c.cfg.request_timeout_ms
	append(&c.pending, p)
	_transmit(c, p)
}

client_http_failed :: proc(c: ^Client, id: i64, status: int, body: []u8) {
	_, p := _find(c, id)
	if p == nil {
		return
	}
	m, ok := message_parse(string(body))
	modern_err := ok && m.kind == .Error && _is_modern_error(error_code(m.error))
	if p.op == .Discover {
		if ok && m.kind == .Error && (modern_err || (status == 404 && error_code(m.error) == JSONRPC_METHOD_NOT_FOUND && c.era == .Modern)) {
			_on_error(c, p, m.error)
			return
		}
		_detach(c, p)
		_pending_free(c, p)
		c.era = .Legacy
		_send_initialize(c)
		return
	}
	if p.op == .Initialize {
		if ok && m.kind == .Error {
			if modern_err {
				_on_error(c, p, m.error)
				return
			}
		}
		if status == 400 || status == 404 || status == 405 {
			_detach(c, p)
			_pending_free(c, p)
			c.state = .Initializing
			out := Outgoing {
				kind = .Fallback_Sse,
			}
			if c.sink.send != nil {
				c.sink.send(c.sink.data, c, &out)
			}
			return
		}
	}
	if ok && m.kind == .Error {
		_on_error(c, p, m.error)
		return
	}
	msg := strings.concatenate({"HTTP status ", strconv.write_int(make([]u8, 24, context.temp_allocator), i64(status), 10)}, context.temp_allocator)
	if p.op == .Initialize {
		_detach(c, p)
		_pending_free(c, p)
		_close(c, msg)
		return
	}
	_fail(c, p, msg)
}

client_sse_ready :: proc(c: ^Client) {
	c.era = .Legacy
	_send_initialize(c)
}

client_stream_lost :: proc(c: ^Client, id: i64) {
	_, p := _find(c, id)
	if p == nil {
		return
	}
	if p.op == .Listen {
		_detach(c, p)
		_pending_free(c, p)
		if c.listen_id == id {
			c.listen_id = 0
			c.listen_acked = false
			c.listen_retry = _now(c) + 1000
		}
		return
	}
	if p.op == .Discover {
		_detach(c, p)
		_pending_free(c, p)
		c.era = .Legacy
		_send_initialize(c)
		return
	}
	p.attempts += 1
	if p.attempts >= c.cfg.max_attempts || p.op == .Initialize {
		if p.op == .Initialize {
			_detach(c, p)
			_pending_free(c, p)
			_close(c, "initialize stream lost")
			return
		}
		_fail(c, p, "response stream lost")
		return
	}
	_transmit(c, p)
}

@(private)
_tchar :: proc "contextless" (ch: u8) -> bool {
	switch ch {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return true
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

@(private)
_Header_Scan :: struct {
	names:  [dynamic]string,
	params: [dynamic]Header_Param,
	reason: string,
	path:   [dynamic]string,
}

@(private)
_type_primitive :: proc(schema: string) -> bool {
	t, ok := json_get(schema, "type")
	if !ok {
		return false
	}
	check :: proc(s: string, allow_null: bool) -> (bool, bool) {
		switch s {
		case "string", "integer", "boolean":
			return true, true
		case "null":
			return allow_null, false
		}
		return false, false
	}
	if json_kind(t) == .String {
		s, _ := json_string(t)
		good, _ := check(s, false)
		return good
	}
	if json_kind(t) == .Array {
		it, _ := json_array(t)
		any_prim := false
		for v in json_next_item(&it) {
			s, sok := json_string(v)
			if !sok {
				return false
			}
			good, prim_ := check(s, true)
			if !good {
				return false
			}
			any_prim = any_prim || prim_
		}
		return any_prim
	}
	return false
}

@(private)
_scan_schema :: proc(sc: ^_Header_Scan, node: string, static: bool, is_property: bool) {
	if sc.reason != "" {
		return
	}
	switch json_kind(node) {
	case .Array:
		it, _ := json_array(node)
		for v in json_next_item(&it) {
			_scan_schema(sc, v, false, false)
		}
		return
	case .Object:
	case .Invalid, .Null, .False, .True, .Number, .String:
		return
	}
	it, _ := json_object(node)
	for k, v in json_next_member(&it) {
		if sc.reason != "" {
			return
		}
		switch {
		case json_key_is(k, "x-mcp-header"):
			if !static || !is_property {
				sc.reason = "x-mcp-header is not statically reachable through properties"
				return
			}
			name, ok := json_string(v)
			if !ok || len(name) == 0 {
				sc.reason = "x-mcp-header must be a non-empty string"
				return
			}
			for i in 0 ..< len(name) {
				if !_tchar(name[i]) {
					sc.reason = "x-mcp-header is not an HTTP token"
					return
				}
			}
			for n in sc.names {
				if strings.equal_fold(n, name) {
					sc.reason = "duplicate x-mcp-header"
					return
				}
			}
			if !_type_primitive(node) {
				sc.reason = "x-mcp-header on a non-primitive parameter"
				return
			}
			append(&sc.names, name)
			path := make([]string, len(sc.path), context.temp_allocator)
			copy(path, sc.path[:])
			append(&sc.params, Header_Param{header = name, path = path})
		case json_key_is(k, "properties") && static && json_kind(v) == .Object:
			pit, _ := json_object(v)
			for pk, pv in json_next_member(&pit) {
				pname, _ := json_string(pk)
				append(&sc.path, pname)
				_scan_schema(sc, pv, true, true)
				pop(&sc.path)
				if sc.reason != "" {
					return
				}
			}
		case:
			kind := json_kind(v)
			if kind == .Object || kind == .Array {
				_scan_schema(sc, v, false, false)
			}
		}
	}
}

@(private)
_tool_header_check :: proc(c: ^Client, tool: string) -> (string, bool) {
	schema, ok := json_get_object(tool, "inputSchema")
	if !ok {
		return "", true
	}
	sc := _Header_Scan {
		names  = make([dynamic]string, context.temp_allocator),
		params = make([dynamic]Header_Param, context.temp_allocator),
		path   = make([dynamic]string, context.temp_allocator),
	}
	_scan_schema(&sc, schema, true, false)
	if sc.reason != "" {
		return sc.reason, false
	}
	return "", true
}

@(private)
_store_tool_headers :: proc(c: ^Client, list: string) {
	_tool_headers_clear(c)
	if c.cfg.transport != .Http {
		return
	}
	arr, _ := json_get_array(list, "tools")
	it, _ := json_array(arr)
	for tool in json_next_item(&it) {
		schema, ok := json_get_object(tool, "inputSchema")
		if !ok {
			continue
		}
		sc := _Header_Scan {
			names  = make([dynamic]string, context.temp_allocator),
			params = make([dynamic]Header_Param, context.temp_allocator),
			path   = make([dynamic]string, context.temp_allocator),
		}
		_scan_schema(&sc, schema, true, false)
		if sc.reason != "" || len(sc.params) == 0 {
			continue
		}
		name, _ := json_get_string(tool, "name")
		th := Tool_Headers {
			name   = _clone(c, name),
			params = make([]Header_Param, len(sc.params), c.allocator),
		}
		for hp, i in sc.params {
			th.params[i].header = _clone(c, hp.header)
			th.params[i].path = make([]string, len(hp.path), c.allocator)
			for s, j in hp.path {
				th.params[i].path[j] = _clone(c, s)
			}
		}
		append(&c.tool_headers, th)
	}
}

header_value_encode :: proc(value: string, allocator := context.temp_allocator) -> string {
	safe := len(value) > 0
	for i in 0 ..< len(value) {
		ch := value[i]
		if !(ch == '\t' || (ch >= 0x20 && ch <= 0x7e)) {
			safe = false
			break
		}
	}
	if len(value) == 0 {
		safe = true
	}
	if safe && len(value) > 0 {
		first, last := value[0], value[len(value) - 1]
		if first == ' ' || first == '\t' || last == ' ' || last == '\t' {
			safe = false
		}
	}
	if safe && strings.has_prefix(value, "=?base64?") && strings.has_suffix(value, "?=") {
		safe = false
	}
	if safe {
		return value
	}
	enc, _ := base64.encode(transmute([]u8)value, allocator = allocator)
	return strings.concatenate({"=?base64?", enc, "?="}, allocator)
}

header_value_decode :: proc(value: string, allocator := context.temp_allocator) -> (string, bool) {
	if strings.has_prefix(value, "=?base64?") && strings.has_suffix(value, "?=") && len(value) >= 11 {
		inner := value[9:len(value) - 2]
		out, err := base64.decode(inner, allocator = allocator)
		if err != nil {
			return "", false
		}
		return string(out), true
	}
	for i in 0 ..< len(value) {
		ch := value[i]
		if !(ch == '\t' || (ch >= 0x20 && ch <= 0x7e)) {
			return "", false
		}
	}
	return value, true
}

header_scalar :: proc(raw: string) -> (string, bool) {
	v := json_trim(raw)
	switch json_kind(v) {
	case .String:
		return json_string(v)
	case .Number:
		return v, true
	case .True:
		return "true", true
	case .False:
		return "false", true
	case .Invalid, .Null, .Array, .Object:
	}
	return "", false
}

@(private)
_tool_param_headers :: proc(c: ^Client, p: ^Pending, out: ^[dynamic]Header) {
	if c.era != .Modern {
		return
	}
	for &th in c.tool_headers {
		if th.name != p.name {
			continue
		}
		args, ok := json_get_object(strings.concatenate({"{", p.params, "}"}, context.temp_allocator), "arguments")
		if !ok {
			return
		}
		for hp in th.params {
			node := args
			found := true
			for seg in hp.path {
				v, vok := json_get(node, seg)
				if !vok {
					found = false
					break
				}
				node = v
			}
			if !found {
				continue
			}
			s, sok := header_scalar(node)
			if !sok {
				continue
			}
			append(out, Header{name = strings.concatenate({"Mcp-Param-", hp.header}, context.temp_allocator), value = header_value_encode(s)})
		}
		return
	}
}

client_awaiting :: proc(c: ^Client, id: i64) -> bool {
	_, p := _find(c, id)
	return p != nil
}

client_retransmit :: proc(c: ^Client, id: i64) -> bool {
	_, p := _find(c, id)
	if p == nil || c.state != .Ready {
		return false
	}
	_transmit(c, p)
	return true
}

client_fail_request :: proc(c: ^Client, id: i64, code: i64, message: string, data := "") {
	_, p := _find(c, id)
	if p == nil {
		return
	}
	if p.op == .Discover || p.op == .Initialize {
		_detach(c, p)
		_pending_free(c, p)
		_close(c, message)
		return
	}
	call, op := p.call, p.op
	_detach(c, p)
	_pending_free(c, p)
	if call != 0 {
		_emit(c, Event{kind = .Error, call = call, op = op, local = true, code = code, message = message, data = data})
	}
}

package mcp

import "base:runtime"
import "core:encoding/base64"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../jsonschema"

Ref :: distinct u64

Conn_Id :: distinct u64

Stream_Id :: distinct u64

Request :: struct {
	ref:             Ref,
	conn:            Conn_Id,
	method:          string,
	params:          string,
	name:            string,
	arguments:       string,
	uri:             string,
	cursor:          string,
	has_cursor:      bool,
	version:         Version,
	modern:          bool,
	client:          Client_Capabilities,
	client_info:     string,
	log_level:       Log_Level,
	progress:        bool,
	input_responses: string,
	request_state:   string,
	has_state:       bool,
	meta:            string,
	authorization:   string,
}

Request_Handler :: #type proc(data: rawptr, s: ^Server, req: ^Request)

Tool_Def :: struct {
	name:          string,
	title:         string,
	description:   string,
	input_schema:  string,
	output_schema: string,
	annotations:   string,
	icons:         string,
	meta:          string,
	handler:       Request_Handler,
	data:          rawptr,
	param_headers: bool,
	schema:        jsonschema.Schema,
	validate:      bool,
}

Server_Handlers :: struct {
	data:                    rawptr,
	resources_list:          Request_Handler,
	resource_templates_list: Request_Handler,
	resources_read:          Request_Handler,
	prompts_list:            Request_Handler,
	prompts_get:             Request_Handler,
	complete:                Request_Handler,
	other:                   Request_Handler,
	cancel:                  proc(data: rawptr, s: ^Server, ref: Ref),
	notification:            proc(data: rawptr, s: ^Server, conn: Conn_Id, method: string, params: string),
	subscribed:              proc(data: rawptr, s: ^Server, uri: string, on: bool),
}

Server_Config :: struct {
	info:               Implementation,
	instructions:       string,
	versions:           Versions,
	page_size:          int,
	list_ttl_ms:        i64,
	discover_ttl_ms:    i64,
	private_cache:      bool,
	logging:            bool,
	tools_list_changed: bool,
	resources_subscribe: bool,
	resources_list_changed: bool,
	prompts_list_changed: bool,
	omit_server_info:   bool,
	tasks:              bool,
	task_ttl_ms:        i64,
	task_poll_ms:       i64,
	max_tasks:          int,
	no_validation:      bool,
	extensions:         string,
	experimental:       string,
	handlers:           Server_Handlers,
}

Server_Sink :: struct {
	data: rawptr,
	send: proc(data: rawptr, s: ^Server, conn: Conn_Id, stream: Stream_Id, body: []u8, final: bool, status: int),
}

@(private)
Active_Kind :: enum u8 {
	Call,
	Listen,
}

@(private)
Active :: struct {
	ref:        Ref,
	kind:       Active_Kind,
	conn:       Conn_Id,
	stream:     Stream_Id,
	id:         string,
	method:     string,
	params:     string,
	progress:   string,
	last_prog:  f64,
	has_prog:   bool,
	log_level:  Log_Level,
	modern:     bool,
	version:    Version,
	caps:       Client_Capabilities,
	client_info: string,
	handler:    Request_Handler,
	hdata:      rawptr,
	collecting: int,
	responses:  Buf,
	state:      string,
	has_state:  bool,
	failed:     bool,
	authz:      string,
	sub_tools:  bool,
	sub_prompts: bool,
	sub_resources: bool,
	sub_uris:   [dynamic]string,
	in_handler: bool,
	done:       bool,
	task:       ^Server_Task,
	in_batch:   bool,
	sub_tasks:  [dynamic]string,
	tool_input: string,
}

@(private)
Out_Req :: struct {
	id:   i64,
	ref:  Ref,
	key:  string,
}

@(private)
Conn :: struct {
	id:          Conn_Id,
	legacy:      bool,
	initialized: bool,
	version:     Version,
	caps:        Client_Capabilities,
	client_info: string,
	log_level:   Log_Level,
	subs:        [dynamic]string,
	next_req:    i64,
	out_reqs:    [dynamic]Out_Req,
	http:        bool,
	sink:        Server_Sink,
}

Server :: struct {
	allocator: runtime.Allocator,
	cfg:       Server_Config,
	tools:     [dynamic]Tool_Def,
	actives:   [dynamic]^Active,
	conns:     [dynamic]^Conn,
	next_ref:  u64,
	next_conn: u64,
	caps:      Server_Capabilities,
	tasks:     [dynamic]^Server_Task,
	ext_buf:   string,
	schemas:   jsonschema.Registry,
	reg_ready: bool,
	dead:      int,
	batching:  bool,
}

Feed_Result :: enum u8 {
	Request,
	Accepted,
	Rejected,
}

Http_Meta :: struct {
	headers: []Header,
}

server_init :: proc(s: ^Server, cfg: Server_Config, allocator := context.allocator) {
	s^ = {}
	s.allocator = allocator
	s.cfg = cfg
	if s.cfg.versions == {} {
		s.cfg.versions = ALL_VERSIONS
	}
	if s.cfg.discover_ttl_ms <= 0 {
		s.cfg.discover_ttl_ms = 300_000
	}
	s.tools = make([dynamic]Tool_Def, allocator)
	s.actives = make([dynamic]^Active, allocator)
	s.conns = make([dynamic]^Conn, allocator)
	s.next_ref = 1
	s.next_conn = 1
	s.tasks = make([dynamic]^Server_Task, allocator)
	if s.cfg.task_ttl_ms == 0 {
		s.cfg.task_ttl_ms = 3_600_000
	}
	if s.cfg.task_poll_ms <= 0 {
		s.cfg.task_poll_ms = 1000
	}
	if s.cfg.max_tasks <= 0 {
		s.cfg.max_tasks = 10_000
	}
	_server_caps(s)
}

@(private)
_server_caps :: proc(s: ^Server) {
	c: Server_Caps
	h := s.cfg.handlers
	c += {.Tools}
	if s.cfg.tools_list_changed {
		c += {.Tools_List_Changed}
	}
	if h.resources_list != nil || h.resources_read != nil || h.resource_templates_list != nil {
		c += {.Resources}
		if s.cfg.resources_subscribe {
			c += {.Resources_Subscribe}
		}
		if s.cfg.resources_list_changed {
			c += {.Resources_List_Changed}
		}
	}
	if h.prompts_list != nil || h.prompts_get != nil {
		c += {.Prompts}
		if s.cfg.prompts_list_changed {
			c += {.Prompts_List_Changed}
		}
	}
	if h.complete != nil {
		c += {.Completions}
	}
	if s.cfg.logging {
		c += {.Logging}
	}
	ext := s.cfg.extensions
	if s.cfg.tasks {
		b := make(Buf, s.allocator)
		inner := json_trim(ext)
		append(&b, '{')
		w_str(&b, TASKS_EXTENSION)
		append(&b, ":{}")
		if len(inner) > 2 && inner[0] == '{' {
			append(&b, ',')
			append(&b, inner[1:len(inner) - 1])
		}
		append(&b, '}')
		s.ext_buf = string(b[:])
		ext = s.ext_buf
	}
	s.caps = Server_Capabilities{caps = c, extensions = ext, experimental = s.cfg.experimental}
}

server_destroy :: proc(s: ^Server) {
	for t in s.tasks {
		_task_free(s, t)
	}
	delete(s.tasks)
	delete(s.ext_buf, s.allocator)
	if s.reg_ready {
		jsonschema.registry_destroy(&s.schemas)
	}
	for a in s.actives {
		_active_free(s, a)
	}
	delete(s.actives)
	for c in s.conns {
		_conn_free(s, c)
	}
	delete(s.conns)
	for &t in s.tools {
		_tool_free(s, &t)
	}
	delete(s.tools)
	s^ = {}
}

@(private)
_sclone :: proc(s: ^Server, v: string) -> string {
	if len(v) == 0 {
		return ""
	}
	out, _ := strings.clone(v, s.allocator)
	return out
}

@(private)
_tool_free :: proc(s: ^Server, t: ^Tool_Def) {
	delete(t.name, s.allocator)
	delete(t.title, s.allocator)
	delete(t.description, s.allocator)
	delete(t.input_schema, s.allocator)
	delete(t.output_schema, s.allocator)
	delete(t.annotations, s.allocator)
	delete(t.icons, s.allocator)
	delete(t.meta, s.allocator)
}

@(private)
_active_free :: proc(s: ^Server, a: ^Active) {
	delete(a.id, s.allocator)
	delete(a.method, s.allocator)
	delete(a.params, s.allocator)
	delete(a.progress, s.allocator)
	delete(a.client_info, s.allocator)
	delete(a.responses)
	delete(a.state, s.allocator)
	delete(a.authz, s.allocator)
	for u in a.sub_uris {
		delete(u, s.allocator)
	}
	delete(a.sub_uris)
	for u in a.sub_tasks {
		delete(u, s.allocator)
	}
	delete(a.sub_tasks)
	free(a, s.allocator)
}

@(private)
_conn_free :: proc(s: ^Server, c: ^Conn) {
	delete(c.client_info, s.allocator)
	delete(c.caps.extensions, s.allocator)
	delete(c.caps.experimental, s.allocator)
	for u in c.subs {
		delete(u, s.allocator)
	}
	delete(c.subs)
	for r in c.out_reqs {
		delete(r.key, s.allocator)
	}
	delete(c.out_reqs)
	free(c, s.allocator)
}

server_add_tool :: proc(s: ^Server, t: Tool_Def) -> bool {
	if len(t.name) == 0 {
		return false
	}
	schema := json_trim(t.input_schema)
	if schema == "" {
		schema = `{"type":"object","additionalProperties":false}`
	}
	if json_kind(schema) != .Object || !json_valid(schema) {
		return false
	}
	if t.output_schema != "" && (json_kind(t.output_schema) != .Object || !json_valid(t.output_schema)) {
		return false
	}
	sc := _Header_Scan {
		names  = make([dynamic]string, context.temp_allocator),
		params = make([dynamic]Header_Param, context.temp_allocator),
		path   = make([dynamic]string, context.temp_allocator),
	}
	_scan_schema(&sc, schema, true, false)
	if sc.reason != "" {
		return false
	}
	for &x in s.tools {
		if x.name == t.name {
			_tool_free(s, &x)
			s.dead += 1
			x = _tool_clone(s, t, schema)
			if !_tool_compile(s, &x) {
				return false
			}
			_tools_changed(s)
			return true
		}
	}
	nt := _tool_clone(s, t, schema)
	if !_tool_compile(s, &nt) {
		_tool_free(s, &nt)
		return false
	}
	idx, _ := slice.binary_search_by(s.tools[:], nt.name, proc(a: Tool_Def, name: string) -> slice.Ordering {
		return slice.cmp(a.name, name)
	})
	inject_at(&s.tools, idx, nt)
	_tools_changed(s)
	return true
}

@(private)
_tool_clone :: proc(s: ^Server, t: Tool_Def, schema: string) -> Tool_Def {
	return Tool_Def {
		name = _sclone(s, t.name),
		title = _sclone(s, t.title),
		description = _sclone(s, t.description),
		input_schema = _sclone(s, schema),
		output_schema = _sclone(s, json_trim(t.output_schema)),
		annotations = _sclone(s, json_trim(t.annotations)),
		icons = _sclone(s, json_trim(t.icons)),
		meta = _sclone(s, json_trim(t.meta)),
		handler = t.handler,
		data = t.data,
		param_headers = strings.contains(schema, `"x-mcp-header"`),
	}
}

server_remove_tool :: proc(s: ^Server, name: string) -> bool {
	for &t, i in s.tools {
		if t.name == name {
			_tool_free(s, &t)
			ordered_remove(&s.tools, i)
			s.dead += 1
			_tools_changed(s)
			return true
		}
	}
	return false
}

@(private)
_tools_changed :: proc(s: ^Server) {
	if .Tools_List_Changed in s.caps.caps {
		server_list_changed(s, .Tools)
	}
}

server_list_changed :: proc(s: ^Server, what: Watch_Flag) {
	method: string
	switch what {
	case .Tools:
		method = "notifications/tools/list_changed"
	case .Prompts:
		method = "notifications/prompts/list_changed"
	case .Resources:
		method = "notifications/resources/list_changed"
	}
	listens := make([dynamic]Ref, context.temp_allocator)
	for a in s.actives {
		if a.kind != .Listen || a.done {
			continue
		}
		want := false
		switch what {
		case .Tools:
			want = a.sub_tools
		case .Prompts:
			want = a.sub_prompts
		case .Resources:
			want = a.sub_resources
		}
		if want {
			append(&listens, a.ref)
		}
	}
	for r in listens {
		a := _active(s, r)
		if a == nil {
			continue
		}
		b := make(Buf, context.temp_allocator)
		_write_sub_notification(&b, method, a.id, "")
		_send(s, a.conn, a.stream, b[:], false, 200)
	}
	conns := make([dynamic]Conn_Id, context.temp_allocator)
	for c in s.conns {
		if c.legacy && c.initialized {
			append(&conns, c.id)
		}
	}
	for id in conns {
		b := make(Buf, context.temp_allocator)
		write_notification(&b, method, "")
		_send(s, id, 0, b[:], false, 200)
	}
}

server_resource_updated :: proc(s: ^Server, uri: string) {
	params := make(Buf, context.temp_allocator)
	targets := make([dynamic]Ref, context.temp_allocator)
	for a in s.actives {
		if a.kind != .Listen || a.done {
			continue
		}
		for u in a.sub_uris {
			if u == uri {
				append(&targets, a.ref)
				break
			}
		}
	}
	for r in targets {
		a := _active(s, r)
		if a == nil {
			continue
		}
		clear(&params)
		f_str(&params, "uri", uri)
		b := make(Buf, context.temp_allocator)
		_write_sub_notification(&b, "notifications/resources/updated", a.id, string(params[:]))
		_send(s, a.conn, a.stream, b[:], false, 200)
	}
	conns := make([dynamic]Conn_Id, context.temp_allocator)
	for c in s.conns {
		if !c.legacy || !c.initialized {
			continue
		}
		for u in c.subs {
			if u == uri {
				append(&conns, c.id)
				break
			}
		}
	}
	for id in conns {
		b := make(Buf, context.temp_allocator)
		p := make(Buf, context.temp_allocator)
		append(&p, '{')
		f_str(&p, "uri", uri)
		append(&p, '}')
		write_notification(&b, "notifications/resources/updated", string(p[:]))
		_send(s, id, 0, b[:], false, 200)
	}
}

@(private)
_write_sub_notification :: proc(b: ^Buf, method: string, sub_id: string, members: string) {
	append(b, `{"jsonrpc":"2.0","method":`)
	w_str(b, method)
	append(b, `,"params":{`)
	if members != "" {
		append(b, members)
		append(b, ',')
	}
	append(b, `"_meta":{"`)
	append(b, META_SUBSCRIPTION_ID)
	append(b, `":`)
	append(b, sub_id)
	append(b, "}}}")
}

@(private)
_send :: proc(s: ^Server, conn: Conn_Id, stream: Stream_Id, body: []u8, final: bool, status: int) {
	c := _conn(s, conn)
	if c != nil && c.sink.send != nil {
		c.sink.send(c.sink.data, s, conn, stream, body, final, status)
	}
}

server_conn_open :: proc(s: ^Server, sink: Server_Sink, http := false) -> Conn_Id {
	c := new(Conn, s.allocator)
	c.id = Conn_Id(s.next_conn)
	s.next_conn += 1
	c.subs = make([dynamic]string, s.allocator)
	c.out_reqs = make([dynamic]Out_Req, s.allocator)
	c.next_req = 1
	c.http = http
	c.sink = sink
	append(&s.conns, c)
	return c.id
}

server_conn_legacy :: proc(s: ^Server, id: Conn_Id) -> bool {
	c := _conn(s, id)
	return c != nil && c.legacy
}

server_conn_version :: proc(s: ^Server, id: Conn_Id) -> Version {
	c := _conn(s, id)
	if c == nil || !c.legacy {
		return .None
	}
	return c.version
}

server_conn_initialized :: proc(s: ^Server, id: Conn_Id) -> bool {
	c := _conn(s, id)
	return c != nil && c.legacy && c.initialized
}

server_conn_close :: proc(s: ^Server, id: Conn_Id) {
	refs := make([dynamic]Ref, context.temp_allocator)
	for a in s.actives {
		if a.conn == id {
			append(&refs, a.ref)
		}
	}
	for r in refs {
		_cancel_active(s, r, false)
	}
	for c, i in s.conns {
		if c.id == id {
			if s.cfg.handlers.subscribed != nil {
				for u in c.subs {
					s.cfg.handlers.subscribed(s.cfg.handlers.data, s, u, false)
				}
			}
			ordered_remove(&s.conns, i)
			_conn_free(s, c)
			return
		}
	}
}

server_stream_closed :: proc(s: ^Server, conn: Conn_Id, stream: Stream_Id) {
	refs := make([dynamic]Ref, context.temp_allocator)
	for a in s.actives {
		if a.conn == conn && a.stream == stream && stream != 0 && a.task == nil {
			append(&refs, a.ref)
		}
	}
	for r in refs {
		a := _active(s, r)
		if a != nil && (a.modern || a.kind == .Listen) {
			_cancel_active(s, r, false)
		}
	}
}

server_shutdown :: proc(s: ^Server) {
	listens := make([dynamic]Ref, context.temp_allocator)
	for a in s.actives {
		if a.kind == .Listen && !a.done {
			append(&listens, a.ref)
		}
	}
	for r in listens {
		a := _active(s, r)
		if a == nil {
			continue
		}
		c := _conn(s, a.conn)
		if c != nil && !c.http {
			b := make(Buf, context.temp_allocator)
			append(&b, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":`)
			append(&b, a.id)
			append(&b, `,"reason":"server shutting down"}}`)
			_send(s, a.conn, a.stream, b[:], false, 200)
		}
		b := make(Buf, context.temp_allocator)
		append(&b, `{"jsonrpc":"2.0","id":`)
		append(&b, a.id)
		append(&b, `,"result":{"resultType":"complete","_meta":{"`)
		append(&b, META_SUBSCRIPTION_ID)
		append(&b, `":`)
		append(&b, a.id)
		append(&b, "}}}")
		_send(s, a.conn, a.stream, b[:], true, 200)
		_remove_active(s, a)
	}
}

@(private)
_conn :: proc(s: ^Server, id: Conn_Id) -> ^Conn {
	for c in s.conns {
		if c.id == id {
			return c
		}
	}
	return nil
}

@(private)
_active :: proc(s: ^Server, ref: Ref) -> ^Active {
	for a in s.actives {
		if a.ref == ref {
			return a
		}
	}
	return nil
}

@(private)
_remove_active :: proc(s: ^Server, a: ^Active) {
	for x, i in s.actives {
		if x == a {
			ordered_remove(&s.actives, i)
			break
		}
	}
	if a.in_handler {
		a.done = true
		return
	}
	_active_free(s, a)
}

@(private)
_cancel_active :: proc(s: ^Server, ref: Ref, notify_client: bool) {
	a := _active(s, ref)
	if a == nil {
		return
	}
	is_call := a.kind == .Call
	c := _conn(s, a.conn)
	if c != nil {
		i := 0
		for i < len(c.out_reqs) {
			if c.out_reqs[i].ref == ref {
				delete(c.out_reqs[i].key, s.allocator)
				ordered_remove(&c.out_reqs, i)
				continue
			}
			i += 1
		}
	}
	conn, stream, in_batch := a.conn, a.stream, a.in_batch
	_remove_active(s, a)
	if in_batch && stream != 0 {
		_send(s, conn, stream, nil, true, 200)
	}
	if is_call && s.cfg.handlers.cancel != nil {
		s.cfg.handlers.cancel(s.cfg.handlers.data, s, ref)
	}
}

server_batch_responses :: proc(raw: string) -> int {
	if json_kind(raw) != .Array {
		return 0
	}
	n := 0
	it, _ := json_array(raw)
	for item in json_next_item(&it) {
		m, ok := message_parse(item)
		if !ok || m.kind == .Request || m.kind == .Invalid {
			n += 1
		}
	}
	if n == 0 && json_trim(raw) == "[]" {
		return 1
	}
	return n
}

@(private)
_feed_batch :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, raw: string, authorization: string) -> Feed_Result {
	it, _ := json_array(raw)
	first, has := json_next_item(&it)
	if !has {
		_reply_error(s, c.id, stream, "null", JSONRPC_INVALID_REQUEST, "empty batch", "", 400)
		return .Rejected
	}
	_ = first
	if !c.legacy {
		_reply_error(s, c.id, stream, "null", JSONRPC_INVALID_REQUEST, "batches are not part of this protocol version", "", 400)
		return .Rejected
	}
	conn := c.id
	items := make([dynamic]string, context.temp_allocator)
	it2, _ := json_array(raw)
	for item in json_next_item(&it2) {
		append(&items, strings.clone(item, context.temp_allocator))
	}
	requests := false
	for item in items {
		if _conn(s, conn) == nil {
			break
		}
		m, ok := message_parse(item)
		if !ok || m.kind == .Request || m.kind == .Invalid {
			requests = true
		}
		if json_kind(item) == .Array {
			_reply_error(s, conn, stream, "null", JSONRPC_INVALID_REQUEST, "nested batch", "", 400)
			continue
		}
		s.batching = true
		server_feed(s, conn, stream, transmute([]u8)item, nil, authorization)
		s.batching = false
	}
	return .Request if requests else .Accepted
}

server_is_live :: proc(s: ^Server, ref: Ref) -> bool {
	return _active(s, ref) != nil
}

@(private)
_reply_error :: proc(s: ^Server, conn: Conn_Id, stream: Stream_Id, id: string, code: i64, message: string, data := "", status := 200) {
	b := make(Buf, context.temp_allocator)
	write_response_error(&b, id, code, message, data)
	_send(s, conn, stream, b[:], true, status)
}

@(private)
_unsupported_version_data :: proc(s: ^Server, requested: string, modern_only: bool) -> string {
	b := make(Buf, context.temp_allocator)
	append(&b, `{"supported":[`)
	first := true
	for i := int(max(Version)); i > 0; i -= 1 {
		v := Version(i)
		if v not_in s.cfg.versions || (modern_only && !version_modern(v)) {
			continue
		}
		if !first {
			append(&b, ',')
		}
		first = false
		w_str(&b, version_name(v))
	}
	append(&b, `],"requested":`)
	w_str(&b, requested)
	append(&b, '}')
	return string(b[:])
}

server_feed :: proc(s: ^Server, conn: Conn_Id, stream: Stream_Id, raw: []u8, http: ^Http_Meta = nil, authorization := "") -> Feed_Result {
	m, ok := message_parse(string(raw))
	c := _conn(s, conn)
	if c == nil {
		return .Rejected
	}
	if !ok {
		_reply_error(s, conn, stream, "null", JSONRPC_PARSE_ERROR, "parse error", "", 400)
		return .Rejected
	}
	if json_kind(string(raw)) == .Array {
		return _feed_batch(s, c, stream, string(raw), authorization)
	}
	switch m.kind {
	case .Invalid:
		id := m.id if m.id != "" else "null"
		_reply_error(s, conn, stream, id, JSONRPC_INVALID_REQUEST, "invalid request", "", 400)
		return .Rejected
	case .Notification:
		return _on_client_notification(s, c, &m)
	case .Result, .Error:
		return _on_client_response(s, c, &m)
	case .Request:
	}
	_on_client_request(s, c, stream, &m, http, authorization)
	return .Request
}

@(private)
_on_client_response :: proc(s: ^Server, c: ^Conn, m: ^Message) -> Feed_Result {
	if json_kind(m.id) != .Number {
		return .Accepted
	}
	id, ok := json_int(m.id)
	if !ok {
		return .Accepted
	}
	for r, i in c.out_reqs {
		if r.id != id {
			continue
		}
		ref, key := r.ref, strings.clone(r.key, context.temp_allocator)
		delete(r.key, s.allocator)
		ordered_remove(&c.out_reqs, i)
		a := _active(s, ref)
		if a == nil {
			return .Accepted
		}
		if m.kind == .Error {
			msg := strings.concatenate({"client failed ", key, ": ", error_message(m.error)}, context.temp_allocator)
			_finish_error(s, a, JSONRPC_INTERNAL_ERROR, msg, "")
			return .Accepted
		}
		w_key(&a.responses, key)
		append(&a.responses, m.result)
		a.collecting -= 1
		if a.collecting == 0 {
			_reinvoke(s, a)
		}
		return .Accepted
	}
	return .Accepted
}

@(private)
_on_client_notification :: proc(s: ^Server, c: ^Conn, m: ^Message) -> Feed_Result {
	params := m.params if m.params != "" else "{}"
	switch m.method {
	case "notifications/initialized":
		if c.legacy {
			c.initialized = true
		}
		return .Accepted
	case "notifications/cancelled":
		rid, ok := json_get(params, "requestId")
		if !ok {
			return .Accepted
		}
		key := json_trim(rid)
		for a in s.actives {
			if a.conn == c.id && a.id == key {
				_cancel_active(s, a.ref, false)
				break
			}
		}
		return .Accepted
	case "notifications/progress":
		return .Accepted
	}
	if s.cfg.handlers.notification != nil {
		s.cfg.handlers.notification(s.cfg.handlers.data, s, c.id, m.method, params)
	}
	return .Accepted
}

@(private)
_header_check :: proc(s: ^Server, http: ^Http_Meta, m: ^Message, version: string, name_src: string, tool: ^Tool_Def) -> (string, bool) {
	hv, has_v := http_header(http.headers, "mcp-protocol-version")
	if !has_v {
		return "missing MCP-Protocol-Version header", false
	}
	if hv != version {
		return "MCP-Protocol-Version header does not match the request body", false
	}
	hm, has_m := http_header(http.headers, "mcp-method")
	if !has_m {
		return "missing Mcp-Method header", false
	}
	if hm != m.method {
		return "Mcp-Method header does not match the request body", false
	}
	needs_name := m.method == "tools/call" || m.method == "resources/read" || m.method == "prompts/get" || m.method == "tasks/get" || m.method == "tasks/update" || m.method == "tasks/cancel"
	hn, has_n := http_header(http.headers, "mcp-name")
	if needs_name && !has_n {
		return "missing Mcp-Name header", false
	}
	if has_n {
		dn, dok := header_value_decode(hn)
		if !dok {
			return "Mcp-Name header has invalid characters", false
		}
		if needs_name && dn != name_src {
			return "Mcp-Name header does not match the request body", false
		}
	}
	if tool == nil || !tool.param_headers {
		return "", true
	}
	sc := _Header_Scan {
		names  = make([dynamic]string, context.temp_allocator),
		params = make([dynamic]Header_Param, context.temp_allocator),
		path   = make([dynamic]string, context.temp_allocator),
	}
	_scan_schema(&sc, tool.input_schema, true, false)
	if sc.reason != "" || len(sc.params) == 0 {
		return "", true
	}
	args, _ := json_get_object(m.params, "arguments")
	for hp in sc.params {
		hname := strings.concatenate({"mcp-param-", hp.header}, context.temp_allocator)
		hval, has_h := http_header(http.headers, hname)
		node := args
		found := args != ""
		for seg in hp.path {
			if !found {
				break
			}
			v, vok := json_get(node, seg)
			if !vok {
				found = false
				break
			}
			node = v
		}
		value, vok := "", false
		if found {
			value, vok = header_scalar(node)
		}
		if !vok {
			if has_h {
				return "unexpected Mcp-Param header", false
			}
			continue
		}
		if !has_h {
			return strings.concatenate({"missing Mcp-Param-", hp.header, " header"}, context.temp_allocator), false
		}
		dv, dok := header_value_decode(hval)
		if !dok {
			return "Mcp-Param header has invalid characters", false
		}
		if dv != value {
			return strings.concatenate({"Mcp-Param-", hp.header, " header does not match the request body"}, context.temp_allocator), false
		}
	}
	return "", true
}

@(private)
_find_tool :: proc(s: ^Server, name: string) -> ^Tool_Def {
	idx, found := slice.binary_search_by(s.tools[:], name, proc(a: Tool_Def, name: string) -> slice.Ordering {
		return slice.cmp(a.name, name)
	})
	if !found {
		return nil
	}
	return &s.tools[idx]
}

@(private)
_on_client_request :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, http: ^Http_Meta, authorization: string) {
	params := m.params if m.params != "" else "{}"
	if json_kind(params) != .Object {
		_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "params must be an object", "", 400)
		return
	}
	for a in s.actives {
		if a.conn == c.id && a.id == m.id && (!c.http || c.legacy) {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_REQUEST, "duplicate request id", "", 400)
			return
		}
	}
	meta, _ := json_get_object(params, "_meta")
	pv_raw, modern := "", false
	if meta != "" {
		pv_raw, modern = json_get(meta, META_PROTOCOL_VERSION)
	}
	if m.method == "initialize" {
		_on_initialize_request(s, c, stream, m, params)
		return
	}
	req := Request {
		conn          = c.id,
		method        = m.method,
		params        = params,
		meta          = meta,
		authorization = authorization,
	}
	if modern {
		pv, pok := json_string(pv_raw)
		v := version_parse(pv) if pok else .None
		if v == .None || v not_in s.cfg.versions || !version_modern(v) {
			if !pok {
				_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "invalid protocol version", "", 400)
				return
			}
			_reply_error(s, c.id, stream, m.id, MCP_UNSUPPORTED_VERSION, "Unsupported protocol version", _unsupported_version_data(s, pv, false), 400)
			return
		}
		caps_raw, has_caps := json_get(meta, META_CLIENT_CAPABILITIES)
		if !has_caps || json_kind(caps_raw) != .Object {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "missing io.modelcontextprotocol/clientCapabilities", "", 400)
			return
		}
		req.version = v
		req.modern = true
		req.client = read_client_capabilities(caps_raw)
		if ci, ok := json_get(meta, META_CLIENT_INFO); ok {
			req.client_info = json_trim(ci)
		}
		if lv, ok := json_get(meta, META_LOG_LEVEL); ok {
			ls, _ := json_string(lv)
			req.log_level = log_level_parse(ls)
			if req.log_level == .None {
				_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "invalid log level", "", 400)
				return
			}
		}
	} else if c.legacy {
		req.version = c.version
		req.client = c.caps
		req.client_info = c.client_info
		req.log_level = c.log_level
	} else if m.method == "ping" {
		b := make(Buf, context.temp_allocator)
		write_response_result(&b, m.id, "{}")
		_send(s, c.id, stream, b[:], true, 200)
		return
	} else {
		data := _unsupported_version_data(s, "", false)
		_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "missing io.modelcontextprotocol/protocolVersion in _meta; send initialize or per-request metadata", data, 400)
		return
	}
	if tok, ok := json_get(meta, "progressToken"); ok && (json_kind(tok) == .String || json_kind(tok) == .Number) {
		req.progress = true
	}
	switch m.method {
	case "tools/call", "prompts/get":
		req.name, _ = json_get_string(params, "name")
		if a, ok := json_get(params, "arguments"); ok {
			req.arguments = json_trim(a)
		}
	case "resources/read", "resources/subscribe", "resources/unsubscribe":
		req.uri, _ = json_get_string(params, "uri")
	case "tools/list", "resources/list", "resources/templates/list", "prompts/list":
		if cur, ok := json_get(params, "cursor"); ok && json_kind(cur) == .String {
			req.cursor, _ = json_string(cur)
			req.has_cursor = true
		}
	}
	if req.modern && http != nil {
		tool: ^Tool_Def
		if m.method == "tools/call" {
			tool = _find_tool(s, req.name)
		}
		name_src := req.uri if m.method == "resources/read" else req.name
		if strings.has_prefix(m.method, "tasks/") {
			name_src, _ = json_get_string(req.params, "taskId")
		}
		if reason, ok := _header_check(s, http, m, version_name(req.version), name_src, tool); !ok {
			_reply_error(s, c.id, stream, m.id, MCP_HEADER_MISMATCH, reason, "", 400)
			return
		}
	}
	if ir, ok := json_get(params, "inputResponses"); ok {
		if json_kind(ir) != .Object {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "inputResponses must be an object", "", 400)
			return
		}
		req.input_responses = json_trim(ir)
	}
	if rs, ok := json_get(params, "requestState"); ok {
		st, sok := json_string(rs)
		if !sok {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "requestState must be a string", "", 400)
			return
		}
		req.request_state = st
		req.has_state = true
	}
	_dispatch_request(s, c, stream, m, &req)
}

@(private)
_dispatch_request :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, req: ^Request) {
	modern := req.modern
	status_nf := 404 if modern && c.http else 200
	h := s.cfg.handlers
	switch m.method {
	case "server/discover":
		if !modern {
			_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
			return
		}
		b := make(Buf, context.temp_allocator)
		append(&b, `{"supportedVersions":[`)
		first := true
		for i := int(max(Version)); i > 0; i -= 1 {
			v := Version(i)
			if v in s.cfg.versions {
				if !first {
					append(&b, ',')
				}
				first = false
				w_str(&b, version_name(v))
			}
		}
		append(&b, ']')
		w_key(&b, "capabilities")
		write_server_capabilities(&b, s.caps, req.version)
		if s.cfg.instructions != "" {
			f_str(&b, "instructions", s.cfg.instructions)
		}
		f_int(&b, "ttlMs", s.cfg.discover_ttl_ms)
		f_str(&b, "cacheScope", "private" if s.cfg.private_cache else "public")
		_write_result_tail(s, &b, true)
		_send_result(s, c.id, stream, m.id, string(b[:]))
		return
	case "ping":
		if modern {
			_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
			return
		}
		_send_result(s, c.id, stream, m.id, "{}")
		return
	case "logging/setLevel":
		if modern || .Logging not_in s.caps.caps {
			_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
			return
		}
		lv, _ := json_get_string(req.params, "level")
		l := log_level_parse(lv)
		if l == .None {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "invalid log level")
			return
		}
		c.log_level = l
		_send_result(s, c.id, stream, m.id, "{}")
		return
	case "resources/subscribe", "resources/unsubscribe":
		if modern || .Resources_Subscribe not_in s.caps.caps {
			_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
			return
		}
		on := m.method == "resources/subscribe"
		found := -1
		for u, i in c.subs {
			if u == req.uri {
				found = i
			}
		}
		if on && found < 0 {
			append(&c.subs, _sclone(s, req.uri))
			if h.subscribed != nil {
				h.subscribed(h.data, s, req.uri, true)
			}
		} else if !on && found >= 0 {
			delete(c.subs[found], s.allocator)
			ordered_remove(&c.subs, found)
			if h.subscribed != nil {
				h.subscribed(h.data, s, req.uri, false)
			}
		}
		_send_result(s, c.id, stream, m.id, "{}")
		return
	case "tasks/get", "tasks/update", "tasks/cancel":
		if !modern || !s.cfg.tasks {
			_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
			return
		}
		_on_task_request(s, c, stream, m, req)
		return
	case "subscriptions/listen":
		if !modern {
			_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
			return
		}
		_on_listen(s, c, stream, m, req)
		return
	case "tools/list":
		_list_tools(s, c, stream, m, req)
		return
	case "tools/call":
		tool := _find_tool(s, req.name)
		if tool == nil || tool.handler == nil {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, strings.concatenate({"Unknown tool: ", req.name}, context.temp_allocator))
			return
		}
		if req.arguments != "" && json_kind(req.arguments) != .Object {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "arguments must be an object")
			return
		}
		if req.arguments == "" {
			req.arguments = "{}"
		}
		if ok, why := _tool_validate(s, tool, req.arguments); !ok {
			b := make(Buf, context.temp_allocator)
			append(&b, `{"content":[{"type":"text","text":`)
			w_str(&b, strings.concatenate({"Invalid arguments for tool ", req.name, ": ", why}, context.temp_allocator))
			append(&b, `}],"isError":true`)
			_write_result_tail(s, &b, modern)
			_send_result(s, c.id, stream, m.id, string(b[:]))
			return
		}
		_start(s, c, stream, m, req, tool.handler, tool.data)
		return
	}
	handler: Request_Handler
	switch m.method {
	case "resources/list":
		handler = h.resources_list
	case "resources/templates/list":
		handler = h.resource_templates_list
	case "resources/read":
		handler = h.resources_read
	case "prompts/list":
		handler = h.prompts_list
	case "prompts/get":
		handler = h.prompts_get
	case "completion/complete":
		handler = h.complete
	case:
		handler = h.other
	}
	if handler == nil {
		_reply_error(s, c.id, stream, m.id, JSONRPC_METHOD_NOT_FOUND, "method not found", "", status_nf)
		return
	}
	_start(s, c, stream, m, req, handler, h.data)
}

@(private)
_write_result_tail :: proc(s: ^Server, b: ^Buf, modern: bool) {
	if modern {
		f_str(b, "resultType", "complete")
		if !s.cfg.omit_server_info {
			f_obj(b, "_meta")
			w_key(b, META_SERVER_INFO)
			write_implementation(b, s.cfg.info)
			w_close(b)
		}
	}
	append(b, '}')
}

@(private)
_send_result :: proc(s: ^Server, conn: Conn_Id, stream: Stream_Id, id: string, result: string) {
	b := make(Buf, 0, len(result) + 64, context.temp_allocator)
	write_response_result(&b, id, result)
	_send(s, conn, stream, b[:], true, 200)
}

@(private)
_on_initialize_request :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, params: string) {
	if c.legacy && c.initialized && !c.http {
		_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_REQUEST, "already initialized")
		return
	}
	pv, _ := json_get_string(params, "protocolVersion")
	v := version_parse(pv)
	if v == .None || version_modern(v) || v not_in s.cfg.versions {
		v = version_best(s.cfg.versions, false)
	}
	if v == .None {
		_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "Unsupported protocol version; this server speaks only per-request metadata versions", _unsupported_version_data(s, pv, true), 400)
		return
	}
	c.legacy = true
	c.initialized = false
	c.version = v
	caps_raw, _ := json_get_object(params, "capabilities")
	delete(c.caps.extensions, s.allocator)
	delete(c.caps.experimental, s.allocator)
	c.caps = read_client_capabilities(caps_raw)
	c.caps.extensions = _sclone(s, c.caps.extensions)
	c.caps.experimental = _sclone(s, c.caps.experimental)
	if v < .V2025_11_25 && .Elicitation_Form not_in c.caps.caps && json_has(caps_raw, "elicitation") {
		c.caps.caps += {.Elicitation_Form}
	}
	delete(c.client_info, s.allocator)
	ci, _ := json_get(params, "clientInfo")
	c.client_info = _sclone(s, json_trim(ci))
	b := make(Buf, context.temp_allocator)
	append(&b, '{')
	f_str(&b, "protocolVersion", version_name(v))
	w_key(&b, "capabilities")
	write_server_capabilities(&b, s.caps, v)
	w_key(&b, "serverInfo")
	info := s.cfg.info
	if v < .V2025_06_18 {
		info.title = ""
	}
	if v < .V2025_11_25 {
		info.icons = ""
		info.website_url = ""
		info.description = ""
	}
	write_implementation(&b, info)
	if s.cfg.instructions != "" && v >= .V2025_03_26 {
		f_str(&b, "instructions", s.cfg.instructions)
	}
	append(&b, '}')
	_send_result(s, c.id, stream, m.id, string(b[:]))
	if c.http {
		c.initialized = true
	}
}

@(private)
_start :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, req: ^Request, handler: Request_Handler, hdata: rawptr) {
	a := new(Active, s.allocator)
	a.ref = Ref(s.next_ref)
	s.next_ref += 1
	a.kind = .Call
	a.conn = c.id
	a.stream = stream
	a.id = _sclone(s, m.id)
	a.method = _sclone(s, m.method)
	a.params = _sclone(s, req.params)
	a.modern = req.modern
	a.version = req.version
	a.caps = req.client
	a.client_info = _sclone(s, req.client_info)
	a.log_level = req.log_level
	a.handler = handler
	a.hdata = hdata
	a.authz = _sclone(s, req.authorization)
	a.in_batch = s.batching
	a.sub_uris = make([dynamic]string, s.allocator)
	if req.progress {
		tok, _ := json_get(req.meta, "progressToken")
		a.progress = _sclone(s, json_trim(tok))
	}
	append(&s.actives, a)
	req.ref = a.ref
	a.in_handler = true
	handler(hdata, s, req)
	a.in_handler = false
	if a.done {
		_active_free(s, a)
	}
}

@(private)
_reinvoke :: proc(s: ^Server, a: ^Active) {
	append(&a.responses, '}')
	responses := strings.clone(string(a.responses[:]), context.temp_allocator)
	clear(&a.responses)
	state := strings.clone(a.state, context.temp_allocator)
	has_state := a.has_state
	req := Request {
		ref             = a.ref,
		conn            = a.conn,
		method          = a.method,
		params          = a.params,
		version         = a.version,
		modern          = false,
		client          = a.caps,
		client_info     = a.client_info,
		log_level       = a.log_level,
		progress        = a.progress != "",
		input_responses = responses,
		request_state   = state,
		has_state       = has_state,
		authorization   = a.authz,
	}
	req.meta, _ = json_get_object(a.params, "_meta")
	switch a.method {
	case "tools/call", "prompts/get":
		req.name, _ = json_get_string(a.params, "name")
		if x, ok := json_get(a.params, "arguments"); ok {
			req.arguments = json_trim(x)
		} else if a.method == "tools/call" {
			req.arguments = "{}"
		}
	case "resources/read":
		req.uri, _ = json_get_string(a.params, "uri")
	}
	a.in_handler = true
	a.handler(a.hdata, s, &req)
	a.in_handler = false
	if a.done {
		_active_free(s, a)
	}
}

@(private)
_list_tools :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, req: ^Request) {
	start := 0
	if req.has_cursor {
		dec, err := base64.decode(req.cursor, allocator = context.temp_allocator)
		n, ok := strconv.parse_int(string(dec), 10)
		if err != nil || !ok || n < 0 || n > len(s.tools) {
			_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "invalid cursor")
			return
		}
		start = n
	}
	end := len(s.tools)
	if s.cfg.page_size > 0 {
		end = min(end, start + s.cfg.page_size)
	}
	b := make(Buf, context.temp_allocator)
	append(&b, `{"tools":[`)
	for i in start ..< end {
		t := &s.tools[i]
		w_open(&b)
		f_str(&b, "name", t.name)
		if t.title != "" && req.version >= .V2025_06_18 {
			f_str(&b, "title", t.title)
		}
		if t.description != "" {
			f_str(&b, "description", t.description)
		}
		f_raw(&b, "inputSchema", t.input_schema)
		if t.output_schema != "" && req.version >= .V2025_06_18 {
			f_raw(&b, "outputSchema", t.output_schema)
		}
		if t.annotations != "" && req.version >= .V2025_03_26 {
			f_raw(&b, "annotations", t.annotations)
		}
		if t.icons != "" && req.version >= .V2025_11_25 {
			f_raw(&b, "icons", t.icons)
		}
		if t.meta != "" && req.version >= .V2025_06_18 {
			f_raw(&b, "_meta", t.meta)
		}
		w_close(&b)
	}
	append(&b, ']')
	if end < len(s.tools) {
		buf: [24]u8
		cur, _ := base64.encode(transmute([]u8)strconv.write_int(buf[:], i64(end), 10), allocator = context.temp_allocator)
		f_str(&b, "nextCursor", cur)
	}
	if req.modern {
		f_int(&b, "ttlMs", max(s.cfg.list_ttl_ms, 0))
		f_str(&b, "cacheScope", "private" if s.cfg.private_cache else "public")
	}
	_write_result_tail(s, &b, req.modern)
	_send_result(s, c.id, stream, m.id, string(b[:]))
}

@(private)
_on_listen :: proc(s: ^Server, c: ^Conn, stream: Stream_Id, m: ^Message, req: ^Request) {
	filt, ok := json_get_object(req.params, "notifications")
	if !ok {
		_reply_error(s, c.id, stream, m.id, JSONRPC_INVALID_PARAMS, "notifications filter is required", "", 400)
		return
	}
	a := new(Active, s.allocator)
	a.ref = Ref(s.next_ref)
	s.next_ref += 1
	a.kind = .Listen
	a.conn = c.id
	a.stream = stream
	a.id = _sclone(s, m.id)
	a.method = _sclone(s, m.method)
	a.modern = true
	a.version = req.version
	a.sub_uris = make([dynamic]string, s.allocator)
	caps := s.caps.caps
	a.sub_tools = json_get_bool(filt, "toolsListChanged") && .Tools_List_Changed in caps
	a.sub_prompts = json_get_bool(filt, "promptsListChanged") && .Prompts_List_Changed in caps
	a.sub_resources = json_get_bool(filt, "resourcesListChanged") && .Resources_List_Changed in caps
	a.sub_tasks = make([dynamic]string, s.allocator)
	if ids, iok := json_get_array(filt, "taskIds"); iok {
		if !s.cfg.tasks || !client_has_tasks(req.client) {
			_active_free(s, a)
			_reply_error(s, c.id, stream, m.id, MCP_MISSING_CLIENT_CAPABILITY, "Missing required client capability", TASKS_REQUIRED_DATA, 400 if c.http else 200)
			return
		}
		it, _ := json_array(ids)
		for v in json_next_item(&it) {
			tid, tok := json_string(v)
			if tok && _task_visible(s, tid, req.authorization) != nil {
				append(&a.sub_tasks, _sclone(s, tid))
			}
		}
	}
	if arr, aok := json_get_array(filt, "resourceSubscriptions"); aok && .Resources_Subscribe in caps {
		it, _ := json_array(arr)
		for v in json_next_item(&it) {
			if u, uok := json_string(v); uok {
				append(&a.sub_uris, _sclone(s, u))
			}
		}
	}
	append(&s.actives, a)
	b := make(Buf, context.temp_allocator)
	append(&b, `"notifications":{`)
	first := true
	add := proc(b: ^Buf, first: ^bool, k: string) {
		if !first^ {
			append(b, ',')
		}
		first^ = false
		w_str(b, k)
		append(b, ":true")
	}
	if a.sub_tools {
		add(&b, &first, "toolsListChanged")
	}
	if a.sub_prompts {
		add(&b, &first, "promptsListChanged")
	}
	if a.sub_resources {
		add(&b, &first, "resourcesListChanged")
	}
	if len(a.sub_tasks) > 0 {
		if !first {
			append(&b, ',')
		}
		first = false
		append(&b, `"taskIds":[`)
		for u, i in a.sub_tasks {
			if i > 0 {
				append(&b, ',')
			}
			w_str(&b, u)
		}
		append(&b, ']')
	}
	if len(a.sub_uris) > 0 {
		if !first {
			append(&b, ',')
		}
		append(&b, `"resourceSubscriptions":[`)
		for u, i in a.sub_uris {
			if i > 0 {
				append(&b, ',')
			}
			w_str(&b, u)
		}
		append(&b, ']')
	}
	append(&b, '}')
	n := make(Buf, context.temp_allocator)
	_write_sub_notification(&n, "notifications/subscriptions/acknowledged", a.id, string(b[:]))
	_send(s, c.id, stream, n[:], false, 200)
	if s.cfg.handlers.subscribed != nil {
		ref := a.ref
		for i := 0; ; i += 1 {
			x := _active(s, ref)
			if x == nil || i >= len(x.sub_uris) {
				break
			}
			u := strings.clone(x.sub_uris[i], context.temp_allocator)
			s.cfg.handlers.subscribed(s.cfg.handlers.data, s, u, true)
		}
	}
}

@(private)
_finish_raw :: proc(s: ^Server, a: ^Active, body: []u8) {
	conn, stream := a.conn, a.stream
	_remove_active(s, a)
	_send(s, conn, stream, body, true, 200)
}

@(private)
_finish_error :: proc(s: ^Server, a: ^Active, code: i64, message: string, data: string) {
	if a.task != nil {
		_task_fail(s, a, code, message, data)
		return
	}
	b := make(Buf, context.temp_allocator)
	write_response_error(&b, a.id, code, message, data)
	status := 200
	if a.modern && code == MCP_MISSING_CLIENT_CAPABILITY {
		c := _conn(s, a.conn)
		if c != nil && c.http {
			status = 400
		}
	}
	conn, stream := a.conn, a.stream
	_remove_active(s, a)
	_send(s, conn, stream, b[:], true, status)
}

server_result :: proc(s: ^Server, ref: Ref, members: string) -> bool {
	a := _active(s, ref)
	if a == nil || a.kind != .Call {
		return false
	}
	if a.task != nil {
		return _task_complete(s, a, members)
	}
	b := make(Buf, 0, len(members) + 128, context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0","id":`)
	append(&b, a.id)
	append(&b, `,"result":{`)
	m := json_trim(members)
	if len(m) >= 2 && m[0] == '{' {
		m = m[1:len(m) - 1]
	}
	append(&b, m)
	if a.modern {
		switch a.method {
		case "resources/list", "resources/templates/list", "prompts/list", "resources/read":
			whole := strings.concatenate({"{", m, "}"}, context.temp_allocator)
			if !json_has(whole, "ttlMs") {
				f_int(&b, "ttlMs", max(s.cfg.list_ttl_ms, 0))
			}
			if !json_has(whole, "cacheScope") {
				f_str(&b, "cacheScope", "private" if s.cfg.private_cache else "public")
			}
		}
		w_sep(&b)
		_write_result_tail(s, &b, true)
	} else {
		append(&b, '}')
	}
	append(&b, '}')
	_finish_raw(s, a, b[:])
	return true
}

server_cacheable_result :: proc(s: ^Server, ref: Ref, members: string, ttl_ms: i64, private := false) -> bool {
	a := _active(s, ref)
	if a == nil {
		return false
	}
	if !a.modern {
		return server_result(s, ref, members)
	}
	b := make(Buf, context.temp_allocator)
	m := json_trim(members)
	if len(m) >= 2 && m[0] == '{' {
		m = m[1:len(m) - 1]
	}
	append(&b, m)
	f_int(&b, "ttlMs", max(ttl_ms, 0))
	f_str(&b, "cacheScope", "private" if private || s.cfg.private_cache else "public")
	return server_result(s, ref, string(b[:]))
}

server_tool_result :: proc(s: ^Server, ref: Ref, content: string, structured := "", is_error := false) -> bool {
	b := make(Buf, context.temp_allocator)
	ct := json_trim(content)
	if json_kind(ct) != .Array {
		ct = "[]"
	}
	f_raw(&b, "content", ct)
	if st := json_trim(structured); st != "" {
		a := _active(s, ref)
		if a != nil && a.version >= .V2025_06_18 {
			f_raw(&b, "structuredContent", st)
		}
	}
	if is_error {
		f_bool(&b, "isError", true)
	}
	return server_result(s, ref, string(b[:]))
}

server_tool_text :: proc(s: ^Server, ref: Ref, text: string, is_error := false, structured := "") -> bool {
	b := make(Buf, context.temp_allocator)
	append(&b, `[{"type":"text","text":`)
	w_str(&b, text)
	append(&b, "}]")
	return server_tool_result(s, ref, string(b[:]), structured, is_error)
}

server_error :: proc(s: ^Server, ref: Ref, code: i64, message: string, data := "") -> bool {
	a := _active(s, ref)
	if a == nil || a.kind != .Call {
		return false
	}
	if a.task != nil {
		return _task_fail(s, a, code, message, json_trim(data))
	}
	_finish_error(s, a, code, message, json_trim(data))
	return true
}

server_input_required :: proc(s: ^Server, ref: Ref, input_requests: string, request_state := "", has_state := false) -> bool {
	a := _active(s, ref)
	if a == nil || a.kind != .Call {
		return false
	}
	reqs := json_trim(input_requests)
	if reqs != "" && json_kind(reqs) != .Object {
		_finish_error(s, a, JSONRPC_INTERNAL_ERROR, "invalid input requests", "")
		return false
	}
	if a.method != "tools/call" && a.method != "prompts/get" && a.method != "resources/read" {
		_finish_error(s, a, JSONRPC_INTERNAL_ERROR, "input_required is not allowed for this request", "")
		return false
	}
	missing: Client_Caps
	count := 0
	if reqs != "" {
		it, _ := json_object(reqs)
		for _, v in json_next_member(&it) {
			count += 1
			method, _ := json_get_string(v, "method")
			params, _ := json_get(v, "params")
			switch method {
			case "roots/list":
				if .Roots not_in a.caps.caps {
					missing += {.Roots}
				}
			case "sampling/createMessage":
				if .Sampling not_in a.caps.caps {
					missing += {.Sampling}
				}
			case "elicitation/create":
				mode, _ := json_get_string(params, "mode")
				if mode == "url" {
					if .Elicitation_Url not_in a.caps.caps {
						missing += {.Elicitation_Url}
					}
				} else if .Elicitation_Form not_in a.caps.caps {
					missing += {.Elicitation_Form}
				}
			case:
				_finish_error(s, a, JSONRPC_INTERNAL_ERROR, "unsupported input request method", "")
				return false
			}
		}
	}
	if count == 0 && !has_state {
		_finish_error(s, a, JSONRPC_INTERNAL_ERROR, "input_required needs inputRequests or requestState", "")
		return false
	}
	if a.task != nil {
		if missing != {} {
			return _task_fail(s, a, MCP_MISSING_CLIENT_CAPABILITY, "Missing required client capability", "")
		}
		return _task_input(s, a, reqs, request_state, has_state)
	}
	if missing != {} {
		d := make(Buf, context.temp_allocator)
		append(&d, `{"requiredCapabilities":`)
		write_client_capabilities(&d, Client_Capabilities{caps = missing}, max(a.version, .V2025_11_25))
		append(&d, '}')
		if a.modern {
			_finish_error(s, a, MCP_MISSING_CLIENT_CAPABILITY, "Missing required client capability", string(d[:]))
		} else {
			_finish_error(s, a, JSONRPC_INVALID_REQUEST, "client did not declare a capability this request needs", string(d[:]))
		}
		return false
	}
	if a.modern {
		b := make(Buf, context.temp_allocator)
		append(&b, `{"jsonrpc":"2.0","id":`)
		append(&b, a.id)
		append(&b, `,"result":{"resultType":"input_required"`)
		if count > 0 {
			f_raw(&b, "inputRequests", reqs)
		}
		if has_state {
			f_str(&b, "requestState", request_state)
		}
		if !s.cfg.omit_server_info {
			f_obj(&b, "_meta")
			w_key(&b, META_SERVER_INFO)
			write_implementation(&b, s.cfg.info)
			w_close(&b)
		}
		append(&b, "}}")
		_finish_raw(s, a, b[:])
		return true
	}
	c := _conn(s, a.conn)
	if c == nil {
		_remove_active(s, a)
		return false
	}
	delete(a.state, s.allocator)
	a.state = _sclone(s, request_state)
	a.has_state = has_state
	clear(&a.responses)
	append(&a.responses, '{')
	a.collecting = count
	if count == 0 {
		_reinvoke(s, a)
		return true
	}
	it, _ := json_object(reqs)
	for k, v in json_next_member(&it) {
		key, _ := json_string(k)
		method, _ := json_get_string(v, "method")
		params, has_params := json_get(v, "params")
		id := c.next_req
		c.next_req += 1
		append(&c.out_reqs, Out_Req{id = id, ref = a.ref, key = _sclone(s, key)})
		b := make(Buf, context.temp_allocator)
		append(&b, `{"jsonrpc":"2.0","id":`)
		w_int(&b, id)
		append(&b, `,"method":`)
		w_str(&b, method)
		if has_params {
			append(&b, `,"params":`)
			append(&b, json_trim(params))
		}
		append(&b, '}')
		_send(s, a.conn, a.stream, b[:], false, 200)
	}
	return true
}

server_progress :: proc(s: ^Server, ref: Ref, progress: f64, total: f64 = -1, message := "") -> bool {
	a := _active(s, ref)
	if a == nil || a.progress == "" || a.task != nil {
		return false
	}
	if a.has_prog && progress <= a.last_prog {
		return false
	}
	a.has_prog = true
	a.last_prog = progress
	b := make(Buf, context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":`)
	append(&b, a.progress)
	f_num(&b, "progress", progress)
	if total >= 0 {
		f_num(&b, "total", total)
	}
	if message != "" && a.version >= .V2025_03_26 {
		f_str(&b, "message", message)
	}
	append(&b, "}}")
	_send(s, a.conn, a.stream, b[:], false, 200)
	return true
}

server_log :: proc(s: ^Server, ref: Ref, level: Log_Level, data: string, logger := "") -> bool {
	if .Logging not_in s.caps.caps || level == .None {
		return false
	}
	a := _active(s, ref)
	if a == nil || a.task != nil {
		return false
	}
	threshold := a.log_level
	if !a.modern {
		if c := _conn(s, a.conn); c != nil {
			threshold = c.log_level
		}
		if threshold == .None {
			threshold = .Debug
		}
	}
	if threshold == .None || level < threshold {
		return false
	}
	b := make(Buf, context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0","method":"notifications/message","params":{"level":`)
	w_str(&b, LOG_LEVEL_NAMES[level])
	if logger != "" {
		f_str(&b, "logger", logger)
	}
	d := json_trim(data)
	if d == "" || !json_valid(d) {
		f_str(&b, "data", data)
	} else {
		f_raw(&b, "data", d)
	}
	append(&b, "}}")
	_send(s, a.conn, a.stream, b[:], false, 200)
	return true
}

server_request_client :: proc(s: ^Server, ref: Ref) -> (caps: Client_Capabilities, version: Version, ok: bool) {
	a := _active(s, ref)
	if a == nil {
		return
	}
	return a.caps, a.version, true
}

@(private)
_tool_compile :: proc(s: ^Server, t: ^Tool_Def) -> bool {
	t.validate = false
	if s.cfg.no_validation {
		return true
	}
	if s.reg_ready && s.dead > 16 && s.dead > len(s.tools) {
		jsonschema.registry_destroy(&s.schemas)
		s.reg_ready = false
		s.dead = 0
		for &x in s.tools {
			if &x != t {
				x.validate = false
				if !s.reg_ready {
					if jsonschema.registry_init(&s.schemas) != .None {
						return false
					}
					s.reg_ready = true
				}
				x.schema, x.validate = _schema_compile(&s.schemas, x.input_schema)
			}
		}
	}
	if !s.reg_ready {
		if jsonschema.registry_init(&s.schemas) != .None {
			return false
		}
		s.reg_ready = true
	}
	compiled, ok := _schema_compile(&s.schemas, t.input_schema)
	if !ok {
		return false
	}
	t.schema = compiled
	t.validate = true
	return true
}

@(private)
_tool_validate :: proc(s: ^Server, t: ^Tool_Def, arguments: string) -> (bool, string) {
	if !t.validate {
		return true, ""
	}
	return _schema_check(t.schema, arguments)
}

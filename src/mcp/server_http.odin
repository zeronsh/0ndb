package mcp

import "core:crypto"
import "core:strings"
import "../prim"

Http_Server_Config :: struct {
	host:              string,
	port:              int,
	path:              string,
	allowed_origins:   []string,
	authorize:         proc(data: rawptr, headers: []Header) -> int,
	auth_data:         rawptr,
	resource_metadata: string,
	max_body:          int,
	max_sessions:      int,
}

@(private)
Hs_Session :: struct {
	id:       string,
	conn:     Conn_Id,
	used:     i64,
	get:      ^Hs_Conn,
}

@(private)
Hs_State :: enum u8 {
	Reading,
	Waiting,
	Streaming,
	Finishing,
	Closing,
}

@(private)
Hs_Conn :: struct {
	hs:          ^Http_Server,
	fd:          prim.Fd,
	w:           prim.Watch,
	parser:      Http_Parser,
	body:        Buf,
	pending:     Buf,
	outq:        Out_Queue,
	state:       Hs_State,
	mcp:         Conn_Id,
	stream:      Stream_Id,
	keep_alive:  bool,
	too_big:     bool,
	session_hdr: string,
	is_get:      bool,
	closed:      bool,
	needs_next:  bool,
}

Http_Server :: struct {
	server:    ^Server,
	loop:      ^prim.Loop,
	cfg:       Http_Server_Config,
	lfd:       prim.Fd,
	lw:        prim.Watch,
	port:      int,
	conns:     [dynamic]^Hs_Conn,
	sessions:  [dynamic]Hs_Session,
	modern:    Conn_Id,
	next_stream: u64,
	loopback:  bool,
	dead:      [dynamic]^Hs_Conn,
	kick:      prim.Timer,
}

http_server_open :: proc(hs: ^Http_Server, s: ^Server, loop: ^prim.Loop, cfg: Http_Server_Config) -> prim.Error {
	hs^ = {}
	hs.server = s
	hs.loop = loop
	hs.cfg = cfg
	if hs.cfg.host == "" {
		hs.cfg.host = "127.0.0.1"
	}
	if hs.cfg.path == "" {
		hs.cfg.path = "/mcp"
	}
	if hs.cfg.max_body <= 0 {
		hs.cfg.max_body = DEFAULT_MAX_BODY
	}
	if hs.cfg.max_sessions <= 0 {
		hs.cfg.max_sessions = 256
	}
	h := hs.cfg.host
	hs.loopback = h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
	fd, port, err := net_listen(hs.cfg.host, hs.cfg.port)
	if err != .None {
		return err
	}
	hs.lfd = fd
	hs.port = port
	w, werr := prim.watch(loop, fd, {.Read}, hs, _hs_on_accept)
	if werr != .None {
		net_close(fd)
		return werr
	}
	hs.lw = w
	hs.conns = make([dynamic]^Hs_Conn, s.allocator)
	hs.dead = make([dynamic]^Hs_Conn, s.allocator)
	hs.sessions = make([dynamic]Hs_Session, s.allocator)
	hs.modern = server_conn_open(s, Server_Sink{data = hs, send = _hs_sink}, true)
	hs.next_stream = 1
	return .None
}

http_server_port :: proc "contextless" (hs: ^Http_Server) -> int {
	return hs.port
}

http_server_close :: proc(hs: ^Http_Server) {
	if hs.lw != 0 {
		prim.unwatch(hs.loop, hs.lw)
		hs.lw = 0
	}
	net_close(hs.lfd)
	hs.lfd = prim.INVALID_FD
	server_shutdown(hs.server)
	for len(hs.conns) > 0 {
		_hs_close_conn(hs.conns[len(hs.conns) - 1])
	}
	for s in hs.sessions {
		server_conn_close(hs.server, s.conn)
		delete(s.id, hs.server.allocator)
	}
	clear(&hs.sessions)
	if hs.modern != 0 {
		server_conn_close(hs.server, hs.modern)
		hs.modern = 0
	}
	if hs.kick != 0 {
		prim.timer_cancel(hs.loop, hs.kick)
		hs.kick = 0
	}
	_hs_reap(hs)
	delete(hs.conns)
	delete(hs.sessions)
	delete(hs.dead)
	hs.conns = nil
	hs.sessions = nil
	hs.dead = nil
}

@(private)
_hs_reap :: proc(hs: ^Http_Server) {
	for tc in hs.dead {
		free(tc, hs.server.allocator)
	}
	clear(&hs.dead)
}

@(private)
_hs_kick :: proc(hs: ^Http_Server) {
	if hs.kick != 0 {
		return
	}
	hs.kick = prim.timer(hs.loop, 0, hs, proc(l: ^prim.Loop, data: rawptr) {
		hs := (^Http_Server)(data)
		hs.kick = 0
		for {
			var_tc: ^Hs_Conn
			for tc in hs.conns {
				if tc.needs_next {
					var_tc = tc
					break
				}
			}
			if var_tc == nil {
				break
			}
			var_tc.needs_next = false
			_hs_next(var_tc)
		}
		_hs_reap(hs)
	})
}

@(private)
_hs_finish :: proc(tc: ^Hs_Conn) {
	tc.state = .Finishing
	tc.stream = 0
	tc.needs_next = true
	_hs_kick(tc.hs)
}

@(private)
_hs_on_accept :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	hs := (^Http_Server)(data)
	for {
		cfd, err := net_accept(fd)
		if err != .None {
			return
		}
		tc := new(Hs_Conn, hs.server.allocator)
		tc.hs = hs
		tc.fd = cfd
		tc.outq.base = {.Read}
		http_parser_init(&tc.parser, true, hs.server.allocator)
		tc.body = make(Buf, hs.server.allocator)
		tc.pending = make(Buf, hs.server.allocator)
		w, werr := prim.watch(l, cfd, {.Read}, tc, _hs_on_io)
		if werr != .None {
			net_close(cfd)
			http_parser_destroy(&tc.parser)
			delete(tc.body)
			delete(tc.pending)
			free(tc, hs.server.allocator)
			continue
		}
		tc.w = w
		append(&hs.conns, tc)
	}
}

@(private)
_hs_close_conn :: proc(tc: ^Hs_Conn) {
	if tc.closed {
		return
	}
	tc.closed = true
	hs := tc.hs
	for x, i in hs.conns {
		if x == tc {
			ordered_remove(&hs.conns, i)
			break
		}
	}
	for &s in hs.sessions {
		if s.get == tc {
			s.get = nil
		}
	}
	if tc.w != 0 {
		prim.unwatch(hs.loop, tc.w)
		tc.w = 0
	}
	net_close(tc.fd)
	if (tc.state == .Waiting || tc.state == .Streaming) && tc.stream != 0 {
		server_stream_closed(hs.server, tc.mcp, tc.stream)
	}
	out_destroy(&tc.outq)
	http_parser_destroy(&tc.parser)
	delete(tc.body)
	delete(tc.pending)
	delete(tc.session_hdr, hs.server.allocator)
	tc.session_hdr = ""
	append(&hs.dead, tc)
	_hs_kick(hs)
}

@(private)
_hs_on_io :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	tc := (^Hs_Conn)(data)
	if .Write in events && out_pending(&tc.outq) > 0 {
		if err := out_flush(&tc.outq, l, tc.w, fd); err != .None {
			_hs_close_conn(tc)
			return
		}
		if tc.state == .Closing && out_pending(&tc.outq) == 0 {
			_hs_close_conn(tc)
			return
		}
	}
	buf: [16 * 1024]u8
	for !tc.closed {
		n, err := prim.read(fd, buf[:])
		if err == .Interrupted {
			continue
		}
		if err == .Would_Block {
			break
		}
		if err != .None || n == 0 {
			_hs_close_conn(tc)
			return
		}
		if tc.state != .Reading {
			if len(tc.pending) + n > tc.hs.cfg.max_body {
				_hs_close_conn(tc)
				return
			}
			append(&tc.pending, ..buf[:n])
			continue
		}
		if !_hs_consume(tc, buf[:n]) {
			return
		}
	}
}

@(private)
_hs_consume :: proc(tc: ^Hs_Conn, data: []u8) -> bool {
	chunk := data
	for len(chunk) > 0 && !tc.closed {
		if tc.state != .Reading {
			append(&tc.pending, ..chunk)
			return true
		}
		used, ev, body := http_feed(&tc.parser, chunk)
		chunk = chunk[used:]
		switch ev {
		case .Error:
			_hs_simple(tc, 400, "", false)
			return false
		case .Body:
			if len(tc.body) + len(body) > tc.hs.cfg.max_body {
				tc.too_big = true
			} else if !tc.too_big {
				append(&tc.body, ..body)
			}
		case .Head, .Need_More, .Done:
			if used == 0 && ev == .Need_More {
				return true
			}
		}
		if tc.parser.state == .Done {
			_hs_request(tc)
			if tc.closed {
				return false
			}
		}
	}
	return true
}

@(private)
_hs_next :: proc(tc: ^Hs_Conn) {
	http_parser_reset(&tc.parser)
	clear(&tc.body)
	tc.too_big = false
	tc.stream = 0
	tc.mcp = 0
	tc.is_get = false
	tc.state = .Reading
	if !tc.keep_alive {
		tc.state = .Closing
		if out_pending(&tc.outq) == 0 {
			_hs_close_conn(tc)
		}
		return
	}
	if len(tc.pending) > 0 {
		rest := make([]u8, len(tc.pending), context.temp_allocator)
		copy(rest, tc.pending[:])
		clear(&tc.pending)
		_hs_consume(tc, rest)
	}
}

@(private)
_hs_write :: proc(tc: ^Hs_Conn, parts: ..[]u8) {
	if tc.closed {
		return
	}
	if err := out_write(&tc.outq, tc.hs.loop, tc.w, tc.fd, ..parts); err != .None {
		_hs_close_conn(tc)
	}
}

@(private)
_hs_head :: proc(b: ^Buf, status: int) {
	append(b, "HTTP/1.1 ")
	w_int(b, i64(status))
	append(b, ' ')
	append(b, http_status_text(status))
	append(b, "\r\n")
}

@(private)
_hs_simple :: proc(tc: ^Hs_Conn, status: int, body: string, keep := true, extra: []Header = nil) {
	tc.keep_alive = keep && tc.parser.keep_alive
	b := make(Buf, context.temp_allocator)
	_hs_head(&b, status)
	for h in extra {
		append(&b, h.name)
		append(&b, ": ")
		append(&b, h.value)
		append(&b, "\r\n")
	}
	if len(body) > 0 {
		append(&b, "Content-Type: application/json\r\n")
	}
	if status != 204 && status != 304 {
		append(&b, "Content-Length: ")
		w_int(&b, i64(len(body)))
		append(&b, "\r\n")
	}
	if !tc.keep_alive {
		append(&b, "Connection: close\r\n")
	}
	append(&b, "\r\n")
	append(&b, body)
	_hs_write(tc, b[:])
	if !tc.closed {
		_hs_finish(tc)
	}
}

@(private)
_hs_error_body :: proc(code: i64, message: string, id := "") -> string {
	b := make(Buf, context.temp_allocator)
	write_response_error(&b, id, code, message)
	return string(b[:])
}

@(private)
_hs_origin_ok :: proc(hs: ^Http_Server, origin: string) -> bool {
	for o in hs.cfg.allowed_origins {
		if o == origin || o == "*" {
			return true
		}
	}
	if !hs.loopback {
		return false
	}
	u, ok := url_parse(origin)
	if !ok {
		return false
	}
	h := u.host
	return h == "localhost" || h == "127.0.0.1" || h == "[::1]"
}

@(private)
_hs_session :: proc(hs: ^Http_Server, id: string) -> ^Hs_Session {
	for &s in hs.sessions {
		if s.id == id {
			return &s
		}
	}
	return nil
}

@(private)
_hs_new_session :: proc(hs: ^Http_Server) -> ^Hs_Session {
	if len(hs.sessions) >= hs.cfg.max_sessions {
		oldest := 0
		for s, i in hs.sessions {
			if s.used < hs.sessions[oldest].used {
				oldest = i
			}
		}
		_hs_drop_session(hs, oldest)
	}
	raw: [16]u8
	crypto.rand_bytes(raw[:])
	hex: [32]u8
	prim.hex_encode(hex[:], raw[:])
	id := strings.clone(string(hex[:]), hs.server.allocator)
	conn := server_conn_open(hs.server, Server_Sink{data = hs, send = _hs_sink}, true)
	append(&hs.sessions, Hs_Session{id = id, conn = conn, used = prim.mono_ns()})
	return &hs.sessions[len(hs.sessions) - 1]
}

@(private)
_hs_drop_session :: proc(hs: ^Http_Server, i: int) {
	s := hs.sessions[i]
	ordered_remove(&hs.sessions, i)
	if s.get != nil {
		_hs_close_conn(s.get)
	}
	server_conn_close(hs.server, s.conn)
	delete(s.id, hs.server.allocator)
}

@(private)
_hs_request :: proc(tc: ^Hs_Conn) {
	hs := tc.hs
	p := &tc.parser
	tc.keep_alive = p.keep_alive
	target := p.target
	if q := strings.index_byte(target, '?'); q >= 0 {
		target = target[:q]
	}
	if target != hs.cfg.path {
		_hs_simple(tc, 404, "")
		return
	}
	headers := p.headers[:]
	if origin, ok := http_header(headers, "origin"); ok && !_hs_origin_ok(hs, origin) {
		_hs_simple(tc, 403, _hs_error_body(JSONRPC_INVALID_REQUEST, "origin not allowed"))
		return
	}
	if hs.cfg.authorize != nil {
		if st := hs.cfg.authorize(hs.cfg.auth_data, headers); st != 0 {
			extra := make([dynamic]Header, context.temp_allocator)
			if st == 401 {
				v := "Bearer"
				if hs.cfg.resource_metadata != "" {
					v = strings.concatenate({`Bearer resource_metadata="`, hs.cfg.resource_metadata, `"`}, context.temp_allocator)
				}
				append(&extra, Header{"WWW-Authenticate", v})
			}
			_hs_simple(tc, st, _hs_error_body(JSONRPC_INVALID_REQUEST, "unauthorized"), true, extra[:])
			return
		}
	}
	authz, _ := http_header(headers, "authorization")
	sid, has_sid := http_header(headers, "mcp-session-id")
	switch p.method {
	case "POST":
	case "GET":
		if !has_sid {
			_hs_simple(tc, 405, "", true, {{"Allow", "POST"}})
			return
		}
		sess := _hs_session(hs, sid)
		if sess == nil {
			_hs_simple(tc, 404, _hs_error_body(JSONRPC_INVALID_REQUEST, "session not found"))
			return
		}
		accept, _ := http_header(headers, "accept")
		if !http_token_has(accept, "text/event-stream") && !http_token_has(accept, "*/*") {
			_hs_simple(tc, 406, "")
			return
		}
		if sess.get != nil {
			_hs_simple(tc, 409, _hs_error_body(JSONRPC_INVALID_REQUEST, "a stream is already open for this session"))
			return
		}
		sess.used = prim.mono_ns()
		sess.get = tc
		tc.is_get = true
		tc.mcp = sess.conn
		tc.stream = 0
		tc.state = .Streaming
		_hs_sse_head(tc)
		return
	case "DELETE":
		if !has_sid {
			_hs_simple(tc, 405, "", true, {{"Allow", "POST"}})
			return
		}
		for s, i in hs.sessions {
			if s.id == sid {
				_hs_drop_session(hs, i)
				if !tc.closed {
					_hs_simple(tc, 200, "")
				}
				return
			}
		}
		_hs_simple(tc, 404, "")
		return
	case:
		_hs_simple(tc, 405, "", true, {{"Allow", "GET, POST, DELETE"}})
		return
	}
	if tc.too_big {
		_hs_simple(tc, 413, _hs_error_body(JSONRPC_INVALID_REQUEST, "request too large"), false)
		return
	}
	ct, _ := http_header(headers, "content-type")
	if !http_token_has(ct, "application/json") {
		_hs_simple(tc, 415, _hs_error_body(JSONRPC_INVALID_REQUEST, "Content-Type must be application/json"))
		return
	}
	if accept, ok := http_header(headers, "accept"); ok {
		if !http_token_has(accept, "application/json") && !http_token_has(accept, "text/event-stream") && !http_token_has(accept, "*/*") && !http_token_has(accept, "application/*") {
			_hs_simple(tc, 406, _hs_error_body(JSONRPC_INVALID_REQUEST, "client must accept application/json and text/event-stream"))
			return
		}
	}
	body := string(tc.body[:])
	m, parse_ok := message_parse(body)
	if !parse_ok {
		_hs_simple(tc, 400, _hs_error_body(JSONRPC_PARSE_ERROR, "parse error"))
		return
	}
	is_modern := false
	if m.kind == .Request || m.kind == .Notification {
		if meta, mok := json_get_object(m.params, "_meta"); mok {
			is_modern = json_has(meta, META_PROTOCOL_VERSION)
		}
	}
	conn := hs.modern
	new_session: ^Hs_Session
	if m.kind == .Request && m.method == "initialize" && !is_modern {
		new_session = _hs_new_session(hs)
		conn = new_session.conn
	} else if has_sid && !is_modern {
		sess := _hs_session(hs, sid)
		if sess == nil {
			_hs_simple(tc, 404, _hs_error_body(JSONRPC_INVALID_REQUEST, "session not found"))
			return
		}
		sess.used = prim.mono_ns()
		conn = sess.conn
		if pv, pok := http_header(headers, "mcp-protocol-version"); pok {
			v := version_parse(pv)
			if v == .None || v not_in hs.server.cfg.versions {
				_hs_simple(tc, 400, _hs_error_body(JSONRPC_INVALID_REQUEST, "unsupported MCP-Protocol-Version"))
				return
			}
		}
	} else if !is_modern && m.kind != .Result && m.kind != .Error {
		if !(m.kind == .Request && m.method == "ping") {
			if m.kind == .Request {
				_hs_simple(tc, 400, _hs_error_body(JSONRPC_INVALID_PARAMS, "missing io.modelcontextprotocol/protocolVersion in _meta and no session; send initialize or per-request metadata", m.id))
			} else {
				_hs_simple(tc, 400, _hs_error_body(JSONRPC_INVALID_REQUEST, "missing session"))
			}
			return
		}
	}
	if is_modern {
		if pv, pok := http_header(headers, "mcp-protocol-version"); pok && version_parse(pv) == .None {
			if meta, mok := json_get_object(m.params, "_meta"); mok {
				bv, _ := json_get_string(meta, META_PROTOCOL_VERSION)
				if bv != pv {
					_hs_simple(tc, 400, _hs_error_body(MCP_HEADER_MISMATCH, "MCP-Protocol-Version header does not match the request body", m.id))
					return
				}
			}
		}
	}
	tc.mcp = conn
	tc.stream = Stream_Id(hs.next_stream)
	hs.next_stream += 1
	if new_session != nil {
		delete(tc.session_hdr, hs.server.allocator)
		tc.session_hdr = strings.clone(new_session.id, hs.server.allocator)
	}
	tc.state = .Waiting
	meta := Http_Meta{headers = headers}
	res := server_feed(hs.server, conn, tc.stream, tc.body[:], &meta if is_modern else nil, authz)
	if tc.closed {
		return
	}
	if res == .Accepted && tc.state == .Waiting {
		tc.stream = 0
		_hs_simple(tc, 202, "")
	} else if res == .Rejected && tc.state == .Waiting {
		tc.stream = 0
		_hs_simple(tc, 400, "")
	}
}

@(private)
_hs_sse_head :: proc(tc: ^Hs_Conn) {
	b := make(Buf, context.temp_allocator)
	_hs_head(&b, 200)
	append(&b, "Content-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\nX-Accel-Buffering: no\r\nTransfer-Encoding: chunked\r\n")
	if tc.session_hdr != "" {
		append(&b, "Mcp-Session-Id: ")
		append(&b, tc.session_hdr)
		append(&b, "\r\n")
	}
	append(&b, "\r\n")
	_hs_write(tc, b[:])
}

@(private)
_hs_find :: proc(hs: ^Http_Server, conn: Conn_Id, stream: Stream_Id) -> ^Hs_Conn {
	if stream == 0 {
		for s in hs.sessions {
			if s.conn == conn {
				return s.get
			}
		}
		return nil
	}
	for tc in hs.conns {
		if tc.mcp == conn && tc.stream == stream && (tc.state == .Waiting || tc.state == .Streaming) {
			return tc
		}
	}
	return nil
}

@(private)
_hs_sink :: proc(data: rawptr, s: ^Server, conn: Conn_Id, stream: Stream_Id, body: []u8, final: bool, status: int) {
	hs := (^Http_Server)(data)
	tc := _hs_find(hs, conn, stream)
	if tc == nil || tc.closed {
		return
	}
	if tc.state == .Waiting && final {
		b := make(Buf, context.temp_allocator)
		_hs_head(&b, status)
		append(&b, "Content-Type: application/json\r\nContent-Length: ")
		w_int(&b, i64(len(body)))
		append(&b, "\r\n")
		if tc.session_hdr != "" {
			append(&b, "Mcp-Session-Id: ")
			append(&b, tc.session_hdr)
			append(&b, "\r\n")
		}
		if !tc.keep_alive {
			append(&b, "Connection: close\r\n")
		}
		append(&b, "\r\n")
		_hs_write(tc, b[:], body)
		if !tc.closed {
			_hs_finish(tc)
		}
		return
	}
	if tc.state == .Waiting {
		tc.state = .Streaming
		_hs_sse_head(tc)
	}
	ev := make(Buf, 0, len(body) + 32, context.temp_allocator)
	append(&ev, "event: message\ndata: ")
	append(&ev, ..body)
	append(&ev, "\n\n")
	frame := make(Buf, 0, len(ev) + 16, context.temp_allocator)
	http_write_chunk(&frame, ev[:])
	if final && !tc.is_get {
		append(&frame, "0\r\n\r\n")
		_hs_write(tc, frame[:])
		if !tc.closed {
			_hs_finish(tc)
		}
		return
	}
	_hs_write(tc, frame[:])
}

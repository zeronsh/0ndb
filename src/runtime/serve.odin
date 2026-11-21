package rt

import "core:strings"
import eng "../engine"
import "../http"
import "../mcp"
import "../prim"

Serve :: struct {
	on:      bool,
	server:  mcp.Server,
	http:    mcp.Http_Server,
	http_on: bool,
	url:     string,
	stdio:   [dynamic]^Stdio_Session,
	tokens:  [dynamic]Serve_Token,
	pending: [dynamic]Serve_Pending,
}

Stdio_Session :: struct {
	r:      ^Runtime,
	ss:     mcp.Stdio_Server,
	caller: Object,
	closed: bool,
}

@(private)
Serve_Token :: struct {
	token: string,
	o:     Object,
}

@(private)
Serve_Pending :: struct {
	ref:   mcp.Ref,
	token: u64,
}

@(private)
_serve_ensure :: proc(r: ^Runtime) {
	s := &r.serve
	if s.on {
		return
	}
	s.stdio = make([dynamic]^Stdio_Session, r.allocator)
	s.tokens = make([dynamic]Serve_Token, r.allocator)
	s.pending = make([dynamic]Serve_Pending, r.allocator)
	cfg := mcp.Server_Config {
		info = mcp.Implementation{name = "0ndb", version = "1"},
		instructions = mcp.CATALOG_INSTRUCTIONS,
		handlers = mcp.Server_Handlers{data = r, cancel = _serve_cancel},
	}
	mcp.server_init(&s.server, cfg, r.allocator)
	mcp.catalog_register(&s.server, mcp.ALL_CATALOG_TOOLS, _serve_tool, r)
	s.on = true
}

serve_http_token :: proc(r: ^Runtime, o: Object) -> (url: string, token: string, ok: bool) {
	_serve_ensure(r)
	s := &r.serve
	if !s.http_on {
		cfg := mcp.Http_Server_Config {
			host      = "127.0.0.1",
			port      = r.cfg.mcp_port,
			path      = "/mcp",
			authorize = _serve_authorize,
			auth_data = r,
		}
		if mcp.http_server_open(&s.http, &s.server, eng.loop(r.e), cfg) != .None {
			return "", "", false
		}
		s.http_on = true
		b := make(Buf, r.allocator)
		append(&b, "http://127.0.0.1:")
		jw_int(&b, i64(mcp.http_server_port(&s.http)))
		append(&b, "/mcp")
		s.url = string(b[:])
	}
	raw: [16]u8
	eng.random_fill(r.e, raw[:])
	hx := prim.id_hex(prim.Id(raw))
	t := clone(string(hx[:]), r.allocator)
	append(&s.tokens, Serve_Token{token = t, o = o})
	return s.url, t, true
}

serve_revoke :: proc(r: ^Runtime, token: string) {
	s := &r.serve
	if !s.on {
		return
	}
	for t, i in s.tokens {
		if t.token == token {
			delete(t.token, r.allocator)
			ordered_remove(&s.tokens, i)
			break
		}
	}
	if len(s.tokens) == 0 && s.http_on {
		mcp.http_server_close(&s.http)
		s.http_on = false
		delete(s.url, r.allocator)
		s.url = ""
	}
}

serve_stdio :: proc(r: ^Runtime, caller: Object, in_fd: prim.Fd, out_fd: prim.Fd) -> (sess: ^Stdio_Session, err: Error) {
	_serve_ensure(r)
	sess = new(Stdio_Session, r.allocator)
	sess.r = r
	sess.caller = caller
	if mcp.stdio_server_open(&sess.ss, &r.serve.server, eng.loop(r.e), in_fd, out_fd, _serve_stdio_closed, sess) != .None {
		free(sess, r.allocator)
		return nil, .Io
	}
	append(&r.serve.stdio, sess)
	return sess, .None
}

@(private)
_serve_stdio_closed :: proc(data: rawptr, ss: ^mcp.Stdio_Server) {
	sess := (^Stdio_Session)(data)
	sess.closed = true
}

serve_close :: proc(r: ^Runtime) {
	s := &r.serve
	if !s.on {
		return
	}
	for sess in s.stdio {
		mcp.stdio_server_destroy(&sess.ss)
		free(sess, r.allocator)
	}
	delete(s.stdio)
	if s.http_on {
		mcp.http_server_close(&s.http)
		s.http_on = false
	}
	for t in s.tokens {
		delete(t.token, r.allocator)
	}
	delete(s.tokens)
	delete(s.pending)
	delete(s.url, r.allocator)
	mcp.server_destroy(&s.server)
	s^ = {}
}

@(private)
_serve_authorize :: proc(data: rawptr, headers: []mcp.Header) -> int {
	r := (^Runtime)(data)
	for h in headers {
		if !http.ascii_ieq(h.name, "authorization") {
			continue
		}
		if _, ok := _serve_caller(r, h.value); ok {
			return 0
		}
	}
	return 401
}

@(private)
_serve_caller :: proc(r: ^Runtime, authorization: string) -> (o: Object, ok: bool) {
	tok := strings.trim_space(authorization)
	if strings.has_prefix(tok, "Bearer ") || strings.has_prefix(tok, "bearer ") {
		tok = strings.trim_space(tok[7:])
	}
	for t in r.serve.tokens {
		if len(tok) > 0 && t.token == tok {
			return t.o, true
		}
	}
	return {}, false
}

@(private)
_serve_tool :: proc(data: rawptr, s: ^mcp.Server, req: ^mcp.Request) {
	r := (^Runtime)(data)
	caller, ok := _serve_caller(r, req.authorization)
	if !ok {
		for sess in r.serve.stdio {
			if sess.ss.conn == req.conn {
				caller = sess.caller
				ok = true
			}
		}
	}
	if !ok {
		mcp.server_tool_text(s, req.ref, "unauthorized", true)
		return
	}
	tool, known := mcp.catalog_lookup(req.name)
	if !known {
		mcp.server_tool_text(s, req.ref, "unknown tool", true)
		return
	}
	a, aok := agent_resolve(r, caller, "", "", context.temp_allocator)
	ap: ^Agent_Info = &a if aok else nil
	rep := Reply {
		kind = .Server,
		o    = caller,
		ref  = req.ref,
	}
	token := orch_call(r, caller, ap, tool, req.arguments, rep)
	if token != 0 && mcp.server_is_live(s, req.ref) {
		append(&r.serve.pending, Serve_Pending{ref = req.ref, token = token})
	}
}

@(private)
_serve_cancel :: proc(data: rawptr, s: ^mcp.Server, ref: mcp.Ref) {
	r := (^Runtime)(data)
	for p, i in r.serve.pending {
		if p.ref == ref {
			ordered_remove(&r.serve.pending, i)
			tool_abort(r, p.token)
			return
		}
	}
}

serve_reply :: proc(r: ^Runtime, ref: mcp.Ref, text: string, structured: string, is_error: bool) {
	s := &r.serve
	if !s.on {
		return
	}
	for p, i in s.pending {
		if p.ref == ref {
			ordered_remove(&s.pending, i)
			break
		}
	}
	body := text
	if len(body) == 0 {
		body = structured
	}
	mcp.server_tool_text(&s.server, ref, body, is_error, structured)
}

package rt

import "base:runtime"
import "core:strings"
import eng "../engine"
import "../mcp"
import "../model"
import "../prim"

Mcp_Conn :: struct {
	r:         ^Runtime,
	name:      string,
	stdio:     mcp.Stdio_Client,
	httpc:     mcp.Http_Client,
	is_stdio:  bool,
	is_http:   bool,
	ready:     bool,
	done:      bool,
	error:     string,
	tools:     string,
	list:      mcp.Call,
	allow:     []string,
	calls:     [dynamic]Mcp_Pending,
	on_ready:  proc(data: rawptr, c: ^Mcp_Conn),
	data:      rawptr,
	stopping:  bool,
}

@(private)
Mcp_Pending :: struct {
	call:  mcp.Call,
	token: u64,
	rep:   Reply,
}

mcp_conn_open :: proc(r: ^Runtime, spec: ^Mcp_Spec, cwd: string, data: rawptr, on_ready: proc(data: rawptr, c: ^Mcp_Conn)) -> (c: ^Mcp_Conn, err: Error) {
	c = new(Mcp_Conn, r.allocator)
	c.r = r
	c.name = clone(spec.name, r.allocator)
	c.data = data
	c.on_ready = on_ready
	c.calls = make([dynamic]Mcp_Pending, r.allocator)
	if len(spec.allow) > 0 {
		c.allow = make([]string, len(spec.allow), r.allocator)
		for s, i in spec.allow {
			c.allow[i] = clone(s, r.allocator)
		}
	}
	append(&r.clients, c)
	ccfg := mcp.Client_Config {
		info = mcp.Implementation{name = "0ndb", version = "1"},
	}
	handler := mcp.Event_Handler{data = c, event = _mcp_event}
	if len(spec.argv) > 0 {
		cfg := mcp.Stdio_Config {
			argv    = spec.argv,
			env     = _env_merge(spec.env),
			cwd     = spec.cwd if len(spec.cwd) > 0 else cwd,
			spawner = mcp.Spawner{data = r, spawn = _mcp_spawn},
		}
		if mcp.stdio_client_open(&c.stdio, eng.loop(r.e), cfg, ccfg, handler, r.allocator) != .None {
			_mcp_conn_free(c)
			return nil, .Spawn
		}
		c.is_stdio = true
		return c, .None
	}
	hc, herr := eng.http_client(r.e)
	if herr != .None {
		_mcp_conn_free(c)
		return nil, .Unsupported
	}
	hdrs := make([dynamic]mcp.Header, context.temp_allocator)
	for i := 0; i + 1 < len(spec.headers); i += 2 {
		append(&hdrs, mcp.Header{name = spec.headers[i], value = spec.headers[i + 1]})
	}
	mcp.http_client_open(&c.httpc, eng.loop(r.e), mcp.Http_Client_Config{url = spec.url, headers = hdrs[:], http = hc^}, ccfg, handler, r.allocator)
	c.is_http = true
	return c, .None
}

@(private)
_mcp_spawn :: proc(data: rawptr, argv: []string, env: []string, cwd: string) -> (prim.Child, prim.Error) {
	r := (^Runtime)(data)
	req := Spawn_Request {
		argv      = argv,
		env       = env,
		cwd       = cwd,
		new_group = true,
		observe   = true,
	}
	r.stats.spawns += 1
	return r.cfg.spawner.spawn(r.cfg.spawner.data, &req)
}

@(private)
_mcp_client :: proc(c: ^Mcp_Conn) -> ^mcp.Client {
	if c.is_stdio {
		return &c.stdio.client
	}
	return &c.httpc.client
}

@(private)
_mcp_notify :: proc(c: ^Mcp_Conn) {
	if c.done {
		return
	}
	c.done = true
	if c.on_ready != nil {
		c.on_ready(c.data, c)
	}
}

@(private)
_mcp_event :: proc(data: rawptr, cl: ^mcp.Client, e: ^mcp.Event) {
	c := (^Mcp_Conn)(data)
	r := c.r
	#partial switch e.kind {
	case .Ready:
		if c.list == 0 && !c.ready {
			c.list = mcp.client_list_tools(cl)
		}
	case .Result:
		if e.call == c.list && c.list != 0 {
			c.tools = clone(e.result, r.allocator)
			c.ready = true
			_mcp_notify(c)
			return
		}
		for p, i in c.calls {
			if p.call != e.call {
				continue
			}
			ordered_remove(&c.calls, i)
			text, is_error := _mcp_result_text(e.result)
			rep := p.rep
			rep.id = clone(p.rep.id, context.temp_allocator)
			delete(p.rep.id, r.allocator)
			reply_done(r, rep, text, "", is_error)
			return
		}
	case .Error:
		if e.call == c.list && c.list != 0 {
			c.error = clone(e.message, r.allocator)
			_mcp_notify(c)
			return
		}
		for p, i in c.calls {
			if p.call != e.call {
				continue
			}
			ordered_remove(&c.calls, i)
			rep := p.rep
			rep.id = clone(p.rep.id, context.temp_allocator)
			delete(p.rep.id, r.allocator)
			reply_done(r, rep, e.message if len(e.message) > 0 else "the MCP call failed", "", true)
			return
		}
	case .Disconnected, .Closed:
		if !c.ready {
			if len(c.error) == 0 {
				c.error = clone(e.message if len(e.message) > 0 else "disconnected", r.allocator)
			}
			_mcp_notify(c)
		}
	}
}

@(private)
_mcp_result_text :: proc(result: string) -> (string, bool) {
	v, ok := json_parse(result)
	if !ok {
		return result, false
	}
	b := make(Buf, context.temp_allocator)
	for item in jarr(v, "content") {
		switch jstr(item, "type") {
		case "text":
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, jstr(item, "text"))
		case:
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, json_text(item))
		}
	}
	if len(b) == 0 {
		if sc := jget(v, "structuredContent"); sc != nil {
			append(&b, json_text(sc))
		}
	}
	return string(b[:]), jbool(v, "isError")
}

mcp_conn_defs :: proc(c: ^Mcp_Conn, out: ^[dynamic]model.Tool_Def, allocator: runtime.Allocator) {
	if !c.ready {
		return
	}
	v, ok := json_parse(c.tools)
	if !ok {
		return
	}
	for t in jarr(v, "tools") {
		name := jstr(t, "name")
		if len(name) == 0 {
			continue
		}
		if len(c.allow) > 0 {
			allowed := false
			for a in c.allow {
				allowed ||= a == name
			}
			if !allowed {
				continue
			}
		}
		schema := "{\"type\":\"object\"}"
		if s := jget(t, "inputSchema"); s != nil {
			schema = json_text(s)
		}
		append(out, model.Tool_Def{name = clone(concat("mcp__", c.name, "__", name), allocator), description = clone(jstr(t, "description"), allocator), schema = clone(schema, allocator)})
	}
}

mcp_conn_call :: proc(c: ^Mcp_Conn, full: string, input: string, rep: Reply) -> (token: u64, ok: bool) {
	prefix := concat("mcp__", c.name, "__")
	if !c.ready || !strings.has_prefix(full, prefix) {
		return 0, false
	}
	r := c.r
	call := mcp.client_call_tool(_mcp_client(c), full[len(prefix):], input if len(input) > 0 else "{}")
	if call == 0 {
		reply_done(r, rep, "the MCP server is not ready", "", true)
		return 0, true
	}
	r.next_token += 1
	p := Mcp_Pending {
		call  = call,
		token = r.next_token,
		rep   = rep,
	}
	p.rep.id = clone(rep.id, r.allocator)
	append(&c.calls, p)
	return p.token, true
}

mcp_conn_abort :: proc(c: ^Mcp_Conn, token: u64) -> bool {
	for p, i in c.calls {
		if p.token == token {
			mcp.client_cancel(_mcp_client(c), p.call, "cancelled")
			delete(p.rep.id, c.r.allocator)
			ordered_remove(&c.calls, i)
			return true
		}
	}
	return false
}

_mcp_conn_free :: proc(c: ^Mcp_Conn) {
	r := c.r
	for p in c.calls {
		delete(p.rep.id, r.allocator)
	}
	delete(c.calls)
	if c.is_stdio {
		mcp.stdio_client_destroy(&c.stdio)
	}
	if c.is_http {
		mcp.http_client_close(&c.httpc)
		mcp.http_client_destroy(&c.httpc)
	}
	for s in c.allow {
		delete(s, r.allocator)
	}
	delete(c.allow, r.allocator)
	delete(c.name, r.allocator)
	delete(c.tools, r.allocator)
	delete(c.error, r.allocator)
	for x, i in r.clients {
		if x == c {
			ordered_remove(&r.clients, i)
			break
		}
	}
	free(c, r.allocator)
}

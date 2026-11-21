package mcp

import "base:runtime"
import "core:strconv"
import "core:strings"
import "../prim"

Http_Error :: enum u8 {
	None,
	Connect,
	Tls,
	Timeout,
	Reset,
	Protocol,
	Cancelled,
	Too_Large,
	Unsupported,
}

Http_Handle :: distinct u64

Http_Request :: struct {
	method:     string,
	url:        string,
	headers:    []Header,
	body:       []u8,
	timeout_ms: i64,
}

Http_Sink :: struct {
	data: rawptr,
	head: proc(data: rawptr, status: int, headers: []Header),
	body: proc(data: rawptr, chunk: []u8),
	done: proc(data: rawptr, err: Http_Error),
}

Http :: struct {
	data:   rawptr,
	start:  proc(data: rawptr, req: ^Http_Request, sink: Http_Sink) -> Http_Handle,
	cancel: proc(data: rawptr, h: Http_Handle),
}

Url :: struct {
	scheme: string,
	host:   string,
	port:   int,
	target: string,
	origin: string,
}

url_parse :: proc(raw: string, allocator := context.temp_allocator) -> (u: Url, ok: bool) {
	sep := strings.index(raw, "://")
	if sep <= 0 {
		return
	}
	u.scheme = raw[:sep]
	rest := raw[sep + 3:]
	slash := len(rest)
	for i in 0 ..< len(rest) {
		if rest[i] == '/' || rest[i] == '?' || rest[i] == '#' {
			slash = i
			break
		}
	}
	authority := rest[:slash]
	u.target = rest[slash:]
	if hash := strings.index_byte(u.target, '#'); hash >= 0 {
		u.target = u.target[:hash]
	}
	if len(u.target) == 0 || u.target[0] != '/' {
		u.target = strings.concatenate({"/", u.target}, allocator)
	}
	if at := strings.last_index_byte(authority, '@'); at >= 0 {
		authority = authority[at + 1:]
	}
	hostport := authority
	u.port = 443 if _ascii_equal_fold(u.scheme, "https") else 80
	if len(hostport) > 0 && hostport[0] == '[' {
		close := strings.index_byte(hostport, ']')
		if close < 0 {
			return
		}
		u.host = hostport[:close + 1]
		if close + 1 < len(hostport) {
			if hostport[close + 1] != ':' {
				return
			}
			p, pok := strconv.parse_int(hostport[close + 2:], 10)
			if !pok || p <= 0 || p > 65535 {
				return
			}
			u.port = p
		}
	} else if colon := strings.last_index_byte(hostport, ':'); colon >= 0 {
		u.host = hostport[:colon]
		if colon + 1 < len(hostport) {
			p, pok := strconv.parse_int(hostport[colon + 1:], 10)
			if !pok || p <= 0 || p > 65535 {
				return
			}
			u.port = p
		}
	} else {
		u.host = hostport
	}
	if len(u.host) == 0 {
		return
	}
	u.origin = raw[:sep + 3 + slash]
	return u, true
}

url_resolve :: proc(base: string, ref: string, allocator := context.allocator) -> string {
	if strings.contains(ref, "://") {
		return strings.clone(ref, allocator)
	}
	b, ok := url_parse(base)
	if !ok {
		return strings.clone(ref, allocator)
	}
	if strings.has_prefix(ref, "//") {
		return strings.concatenate({b.scheme, ":", ref}, allocator)
	}
	if strings.has_prefix(ref, "/") {
		return strings.concatenate({b.origin, ref}, allocator)
	}
	path := b.target
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}
	if strings.has_prefix(ref, "?") {
		return strings.concatenate({b.origin, path, ref}, allocator)
	}
	dir := path[:strings.last_index_byte(path, '/') + 1]
	return strings.concatenate({b.origin, dir, ref}, allocator)
}

Plain_Http :: struct {
	loop:      ^prim.Loop,
	allocator: runtime.Allocator,
	reqs:      [dynamic]^Plain_Req,
	idle:      [dynamic]^Plain_Conn,
	next:      u64,
}

@(private)
Plain_Conn :: struct {
	ph:  ^Plain_Http,
	key: string,
	fd:  prim.Fd,
	w:   prim.Watch,
}

@(private)
Plain_Req_State :: enum u8 {
	Connecting,
	Active,
	Finished,
}

@(private)
Plain_Req :: struct {
	ph:        ^Plain_Http,
	handle:    Http_Handle,
	sink:      Http_Sink,
	key:       string,
	host:      string,
	port:      int,
	fd:        prim.Fd,
	w:         prim.Watch,
	state:     Plain_Req_State,
	outq:      Out_Queue,
	request:   Buf,
	parser:    Http_Parser,
	timer:     prim.Timer,
	reused:    bool,
	got_bytes: bool,
	in_cb:     bool,
	dead:      bool,
	head_done: bool,
	fail_t:    prim.Timer,
	fail_err:  Http_Error,
}

plain_http_init :: proc(ph: ^Plain_Http, loop: ^prim.Loop, allocator := context.allocator) {
	ph^ = {}
	ph.loop = loop
	ph.allocator = allocator
	ph.reqs = make([dynamic]^Plain_Req, allocator)
	ph.idle = make([dynamic]^Plain_Conn, allocator)
	ph.next = 1
}

plain_http_destroy :: proc(ph: ^Plain_Http) {
	for len(ph.reqs) > 0 {
		r := ph.reqs[0]
		r.sink = {}
		_plain_finish(r, .Cancelled, false)
	}
	for c in ph.idle {
		prim.unwatch(ph.loop, c.w)
		net_close(c.fd)
		delete(c.key, ph.allocator)
		free(c, ph.allocator)
	}
	delete(ph.reqs)
	delete(ph.idle)
	ph^ = {}
}

plain_http :: proc(ph: ^Plain_Http) -> Http {
	return Http{data = ph, start = _plain_start, cancel = _plain_cancel}
}

@(private)
_plain_start :: proc(data: rawptr, req: ^Http_Request, sink: Http_Sink) -> Http_Handle {
	ph := (^Plain_Http)(data)
	r := new(Plain_Req, ph.allocator)
	r.ph = ph
	r.handle = Http_Handle(ph.next)
	ph.next += 1
	r.sink = sink
	r.fd = prim.INVALID_FD
	r.outq.base = {.Read}
	http_parser_init(&r.parser, false, ph.allocator)
	r.request = make(Buf, ph.allocator)
	append(&ph.reqs, r)
	u, ok := url_parse(req.url)
	if !ok || !_ascii_equal_fold(u.scheme, "http") {
		_plain_fail_soon(r, .Unsupported if ok else .Protocol)
		return r.handle
	}
	if req.method == "HEAD" {
		http_parser_no_body(&r.parser)
	}
	r.host = strings.clone(u.host, ph.allocator)
	r.port = u.port
	r.key = strings.concatenate({u.host, ":", strconv.write_int(make([]u8, 16, context.temp_allocator), i64(u.port), 10)}, ph.allocator)
	b := &r.request
	append(b, req.method)
	append(b, ' ')
	append(b, u.target)
	append(b, " HTTP/1.1\r\nHost: ")
	append(b, u.host)
	if u.port != 80 {
		append(b, ':')
		w_int(b, i64(u.port))
	}
	append(b, "\r\n")
	has_ua := false
	for h in req.headers {
		if _ascii_equal_fold(h.name, "host") || _ascii_equal_fold(h.name, "content-length") || _ascii_equal_fold(h.name, "transfer-encoding") || _ascii_equal_fold(h.name, "connection") {
			continue
		}
		if _ascii_equal_fold(h.name, "user-agent") {
			has_ua = true
		}
		append(b, h.name)
		append(b, ": ")
		append(b, h.value)
		append(b, "\r\n")
	}
	if !has_ua {
		append(b, "User-Agent: ondb-mcp\r\n")
	}
	if len(req.body) > 0 || req.method == "POST" || req.method == "PUT" {
		append(b, "Content-Length: ")
		w_int(b, i64(len(req.body)))
		append(b, "\r\n")
	}
	append(b, "\r\n")
	append(b, ..req.body)
	if req.timeout_ms > 0 {
		r.timer = prim.timer(ph.loop, req.timeout_ms, r, _plain_on_timeout)
	}
	_plain_connect(r)
	return r.handle
}

@(private)
_plain_connect :: proc(r: ^Plain_Req) {
	ph := r.ph
	r.reused = false
	for c, i in ph.idle {
		if c.key == r.key {
			ordered_remove(&ph.idle, i)
			prim.unwatch(ph.loop, c.w)
			r.fd = c.fd
			delete(c.key, ph.allocator)
			free(c, ph.allocator)
			r.reused = true
			break
		}
	}
	pending := false
	if !r.reused {
		fd, p, err := net_connect(r.host, r.port)
		if err != .None {
			_plain_fail_soon(r, .Connect)
			return
		}
		r.fd = fd
		pending = p
	}
	w, err := prim.watch(ph.loop, r.fd, {.Read, .Write} if pending else {.Read}, r, _plain_on_io)
	if err != .None {
		net_close(r.fd)
		r.fd = prim.INVALID_FD
		_plain_fail_soon(r, .Connect)
		return
	}
	r.w = w
	if pending {
		r.state = .Connecting
		return
	}
	r.state = .Active
	_plain_send(r)
}

@(private)
_plain_send :: proc(r: ^Plain_Req) {
	if err := out_write(&r.outq, r.ph.loop, r.w, r.fd, r.request[:]); err != .None {
		_plain_io_failed(r)
	}
}

@(private)
_plain_io_failed :: proc(r: ^Plain_Req) {
	if r.reused && !r.got_bytes {
		prim.unwatch(r.ph.loop, r.w)
		r.w = 0
		net_close(r.fd)
		r.fd = prim.INVALID_FD
		out_destroy(&r.outq)
		r.outq.base = {.Read}
		http_parser_reset(&r.parser)
		r.reused = false
		fd, p, err := net_connect(r.host, r.port)
		if err != .None {
			_plain_finish(r, .Connect, false)
			return
		}
		r.fd = fd
		w, werr := prim.watch(r.ph.loop, fd, {.Read, .Write} if p else {.Read}, r, _plain_on_io)
		if werr != .None {
			_plain_finish(r, .Connect, false)
			return
		}
		r.w = w
		if p {
			r.state = .Connecting
			return
		}
		r.state = .Active
		_plain_send(r)
		return
	}
	_plain_finish(r, .Reset if r.head_done || r.got_bytes else .Connect, false)
}

@(private)
_plain_fail_soon :: proc(r: ^Plain_Req, err: Http_Error) {
	r.fail_err = err
	r.fail_t = prim.timer(r.ph.loop, 0, r, proc(l: ^prim.Loop, data: rawptr) {
		r := (^Plain_Req)(data)
		r.fail_t = 0
		_plain_finish(r, r.fail_err, false)
	})
}

@(private)
_plain_on_timeout :: proc(l: ^prim.Loop, data: rawptr) {
	r := (^Plain_Req)(data)
	r.timer = 0
	_plain_finish(r, .Timeout, false)
}

@(private)
_plain_find :: proc(ph: ^Plain_Http, h: Http_Handle) -> (int, ^Plain_Req) {
	for r, i in ph.reqs {
		if r.handle == h {
			return i, r
		}
	}
	return -1, nil
}

@(private)
_plain_cancel :: proc(data: rawptr, h: Http_Handle) {
	ph := (^Plain_Http)(data)
	_, r := _plain_find(ph, h)
	if r == nil {
		return
	}
	r.sink = {}
	if r.in_cb {
		r.dead = true
		return
	}
	_plain_finish(r, .Cancelled, false)
}

@(private)
_plain_finish :: proc(r: ^Plain_Req, err: Http_Error, keep: bool) {
	ph := r.ph
	i, _ := _plain_find(ph, r.handle)
	if i < 0 {
		return
	}
	ordered_remove(&ph.reqs, i)
	if r.timer != 0 {
		prim.timer_cancel(ph.loop, r.timer)
		r.timer = 0
	}
	if r.fail_t != 0 {
		prim.timer_cancel(ph.loop, r.fail_t)
		r.fail_t = 0
	}
	if r.w != 0 {
		prim.unwatch(ph.loop, r.w)
		r.w = 0
	}
	if r.fd != prim.INVALID_FD {
		if keep && out_pending(&r.outq) == 0 {
			c := new(Plain_Conn, ph.allocator)
			c.ph = ph
			c.key = strings.clone(r.key, ph.allocator)
			c.fd = r.fd
			w, werr := prim.watch(ph.loop, c.fd, {.Read}, c, _plain_idle_io)
			if werr == .None {
				c.w = w
				append(&ph.idle, c)
			} else {
				net_close(c.fd)
				delete(c.key, ph.allocator)
				free(c, ph.allocator)
			}
		} else {
			net_close(r.fd)
		}
		r.fd = prim.INVALID_FD
	}
	sink := r.sink
	out_destroy(&r.outq)
	http_parser_destroy(&r.parser)
	delete(r.request)
	delete(r.key, ph.allocator)
	delete(r.host, ph.allocator)
	free(r, ph.allocator)
	if sink.done != nil {
		sink.done(sink.data, err)
	}
}

@(private)
_plain_idle_io :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	c := (^Plain_Conn)(data)
	ph := c.ph
	for x, i in ph.idle {
		if x == c {
			ordered_remove(&ph.idle, i)
			break
		}
	}
	prim.unwatch(l, c.w)
	net_close(c.fd)
	delete(c.key, ph.allocator)
	free(c, ph.allocator)
}

@(private)
_plain_on_io :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	r := (^Plain_Req)(data)
	h := r.handle
	ph := r.ph
	if r.state == .Connecting {
		if .Write not_in events && .Error not_in events && .Hangup not_in events {
			return
		}
		if err := net_socket_error(fd); err != .None {
			_plain_finish(r, .Connect, false)
			return
		}
		r.state = .Active
		prim.watch_modify(l, r.w, {.Read})
		_plain_send(r)
		if _, still := _plain_find(ph, h); still == nil {
			return
		}
	}
	if .Write in events && out_pending(&r.outq) > 0 {
		if err := out_flush(&r.outq, l, r.w, fd); err != .None {
			_plain_io_failed(r)
			return
		}
	}
	buf: [16 * 1024]u8
	for {
		n, err := prim.read(fd, buf[:])
		if err == .Interrupted {
			continue
		}
		if err == .Would_Block {
			return
		}
		if err != .None {
			_plain_io_failed(r)
			return
		}
		if n == 0 {
			if http_parser_eof(&r.parser) {
				_plain_finish(r, .None, false)
			} else {
				_plain_io_failed(r)
			}
			return
		}
		r.got_bytes = true
		chunk := buf[:n]
		for len(chunk) > 0 {
			used, ev, body := http_feed(&r.parser, chunk)
			chunk = chunk[used:]
			switch ev {
			case .Error:
				_plain_finish(r, .Protocol, false)
				return
			case .Head:
				r.head_done = true
				if r.timer != 0 {
					prim.timer_cancel(l, r.timer)
					r.timer = 0
				}
				if r.sink.head != nil {
					r.in_cb = true
					r.sink.head(r.sink.data, r.parser.status, r.parser.headers[:])
					r.in_cb = false
					if r.dead {
						_plain_finish(r, .Cancelled, false)
						return
					}
				}
			case .Body:
				if r.sink.body != nil {
					r.in_cb = true
					r.sink.body(r.sink.data, body)
					r.in_cb = false
					if r.dead {
						_plain_finish(r, .Cancelled, false)
						return
					}
				}
			case .Done:
				_plain_finish(r, .None, r.parser.keep_alive && len(chunk) == 0)
				return
			case .Need_More:
				if used == 0 {
					chunk = nil
				}
			}
			if r.parser.state == .Done {
				_plain_finish(r, .None, r.parser.keep_alive && len(chunk) == 0)
				return
			}
		}
	}
}

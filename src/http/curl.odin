#+build linux, darwin, freebsd, openbsd, netbsd
package http

import "base:runtime"
import "core:c"
import "core:strings"
import curl "vendor:curl"
import "../prim"

Curl :: struct {
	loop:      ^prim.Loop,
	multi:     ^curl.CURLM,
	timer:     prim.Timer,
	ctx:       runtime.Context,
	allocator: runtime.Allocator,
	live:      map[Id]^Curl_Transfer,
	pool:      [dynamic]^curl.CURL,
	adds:      [dynamic]^Curl_Transfer,
	kills:     [dynamic]^Curl_Transfer,
	next:      u64,
	depth:     int,
	pool_max:  int,
	sockets:   int,
	ca_file:   cstring,
	recv_buf:  int,
	send_buf:  int,
}

@(private)
Curl_Transfer :: struct {
	owner:     ^Curl,
	id:        Id,
	easy:      ^curl.CURL,
	sink:      Sink,
	body:      [][]u8,
	reader:    Body_Reader,
	paused:    bool,
	seg:       int,
	seg_off:   int,
	slist:     ^curl.slist,
	url:       cstring,
	status:    int,
	head_buf:  [dynamic]u8,
	head_idx:  [dynamic][4]u32,
	head_sent: bool,
	dead:      bool,
	added:     bool,
	errbuf:    [curl.ERROR_SIZE]u8,
}

curl_init :: proc(h: ^Curl, l: ^prim.Loop, allocator := context.allocator) -> bool {
	h^ = {}
	h.loop = l
	h.allocator = allocator
	h.ctx = context
	h.ctx.allocator = allocator
	h.pool_max = 16
	h.recv_buf = 0
	h.send_buf = 16384
	if curl.global_init(3) != .E_OK {
		return false
	}
	h.multi = curl.multi_init()
	if h.multi == nil {
		return false
	}
	h.live = make(map[Id]^Curl_Transfer, allocator)
	h.pool = make([dynamic]^curl.CURL, allocator)
	h.adds = make([dynamic]^Curl_Transfer, allocator)
	h.kills = make([dynamic]^Curl_Transfer, allocator)
	curl.multi_setopt(h.multi, .SOCKETFUNCTION, curl_on_socket)
	curl.multi_setopt(h.multi, .SOCKETDATA, rawptr(h))
	curl.multi_setopt(h.multi, .TIMERFUNCTION, curl_on_timer)
	curl.multi_setopt(h.multi, .TIMERDATA, rawptr(h))
	curl.multi_setopt(h.multi, .PIPELINING, c.long(curl.PIPE_MULTIPLEX))
	curl.multi_setopt(h.multi, .MAX_CONCURRENT_STREAMS, c.long(100))
	return true
}

curl_ca_file :: proc(h: ^Curl, path: string) {
	if h.ca_file != nil {
		delete(h.ca_file, h.allocator)
		h.ca_file = nil
	}
	if path != "" {
		h.ca_file = strings.clone_to_cstring(path, h.allocator)
	}
}

curl_destroy :: proc(h: ^Curl) {
	ids := make([dynamic]Id, context.temp_allocator)
	for id in h.live {
		append(&ids, id)
	}
	for id in ids {
		curl_cancel(h, id)
	}
	curl_flush(h)
	for e in h.pool {
		curl.easy_cleanup(e)
	}
	if h.timer != 0 {
		prim.timer_cancel(h.loop, h.timer)
		h.timer = 0
	}
	if h.multi != nil {
		curl.multi_cleanup(h.multi)
	}
	delete(h.live)
	delete(h.pool)
	delete(h.adds)
	delete(h.kills)
	if h.ca_file != nil {
		delete(h.ca_file, h.allocator)
	}
	h^ = {}
}

curl_client :: proc(h: ^Curl) -> Client {
	return Client{data = h, start = curl_start_proc, cancel = curl_cancel_proc, resume = curl_resume_proc}
}

curl_active :: proc(h: ^Curl) -> int {
	return len(h.live)
}

curl_sockets :: proc(h: ^Curl) -> int {
	return h.sockets
}

@(private)
curl_start_proc :: proc(data: rawptr, req: ^Request, sink: Sink) -> (Id, Error) {
	return curl_start((^Curl)(data), req, sink)
}

@(private)
curl_cancel_proc :: proc(data: rawptr, id: Id) {
	curl_cancel((^Curl)(data), id)
}

@(private)
curl_resume_proc :: proc(data: rawptr, id: Id) {
	curl_resume((^Curl)(data), id)
}

curl_resume :: proc(h: ^Curl, id: Id) {
	t, ok := h.live[id]
	if !ok || !t.paused || !t.added {
		return
	}
	t.paused = false
	curl.easy_pause(t.easy, curl.PAUSE_CONT)
}

curl_start :: proc(h: ^Curl, req: ^Request, sink: Sink) -> (Id, Error) {
	context = h.ctx
	t := new(Curl_Transfer, h.allocator)
	if t == nil {
		return 0, .No_Memory
	}
	h.next += 1
	t.owner = h
	t.id = Id(h.next)
	t.sink = sink
	t.body = req.body
	t.reader = req.reader
	t.head_buf = make([dynamic]u8, h.allocator)
	t.head_idx = make([dynamic][4]u32, h.allocator)
	e: ^curl.CURL
	if len(h.pool) > 0 {
		e = pop(&h.pool)
	} else {
		e = curl.easy_init()
	}
	if e == nil {
		curl_free_transfer(h, t)
		return 0, .No_Memory
	}
	t.easy = e
	t.url = strings.clone_to_cstring(req.url, h.allocator)
	sl: ^curl.slist
	for hd in req.headers {
		cs := strings.clone_to_cstring(strings.concatenate({hd.name, ": ", hd.value}, context.temp_allocator), context.temp_allocator)
		nl := curl.slist_append(sl, cs)
		if nl == nil {
			curl.slist_free_all(sl)
			curl_free_transfer(h, t)
			return 0, .No_Memory
		}
		sl = nl
	}
	has_body := len(req.body) > 0 || req.reader.read != nil || req.method == "POST" || req.method == "PUT" || req.method == "PATCH"
	if has_body {
		nl := curl.slist_append(sl, "Expect:")
		if nl != nil {
			sl = nl
		}
	}
	t.slist = sl
	curl.easy_setopt(e, .URL, t.url)
	curl.easy_setopt(e, .HTTPHEADER, sl)
	curl.easy_setopt(e, .PRIVATE, rawptr(t))
	curl.easy_setopt(e, .NOSIGNAL, c.long(1))
	switch req.version {
	case .Auto, .Http2:
		curl.easy_setopt(e, .HTTP_VERSION, c.long(curl.HTTP_VERSION_2TLS))
	case .Http1:
		curl.easy_setopt(e, .HTTP_VERSION, c.long(curl.HTTP_VERSION_1_1))
	case .Http2_Prior_Knowledge:
		curl.easy_setopt(e, .HTTP_VERSION, c.long(curl.HTTP_VERSION_2_PRIOR_KNOWLEDGE))
	}
	if req.timeout_ms > 0 {
		curl.easy_setopt(e, .TIMEOUT_MS, c.long(req.timeout_ms))
	}
	if req.follow {
		curl.easy_setopt(e, .FOLLOWLOCATION, c.long(1))
		curl.easy_setopt(e, .MAXREDIRS, c.long(10))
	}
	curl.easy_setopt(e, .PIPEWAIT, c.long(1))
	curl.easy_setopt(e, .TCP_KEEPALIVE, c.long(1))
	curl.easy_setopt(e, .TCP_KEEPIDLE, c.long(30))
	curl.easy_setopt(e, .TCP_KEEPINTVL, c.long(15))
	curl.easy_setopt(e, .ERRORBUFFER, rawptr(&t.errbuf[0]))
	if h.ca_file != nil {
		curl.easy_setopt(e, .CAINFO, h.ca_file)
	}
	if h.recv_buf > 0 {
		curl.easy_setopt(e, .BUFFERSIZE, c.long(h.recv_buf))
	}
	if h.send_buf > 0 {
		curl.easy_setopt(e, .UPLOAD_BUFFERSIZE, c.long(h.send_buf))
	}
	curl.easy_setopt(e, .WRITEFUNCTION, curl_on_write)
	curl.easy_setopt(e, .WRITEDATA, rawptr(t))
	curl.easy_setopt(e, .HEADERFUNCTION, curl_on_header)
	curl.easy_setopt(e, .HEADERDATA, rawptr(t))
	if req.connect_ms > 0 {
		curl.easy_setopt(e, .CONNECTTIMEOUT_MS, c.long(req.connect_ms))
	}
	if req.stall_ms > 0 {
		curl.easy_setopt(e, .LOW_SPEED_LIMIT, c.long(1))
		curl.easy_setopt(e, .LOW_SPEED_TIME, c.long(max(req.stall_ms / 1000, 1)))
	}
	if has_body {
		curl.easy_setopt(e, .POST, c.long(1))
		curl.easy_setopt(e, .READFUNCTION, curl_on_read)
		curl.easy_setopt(e, .READDATA, rawptr(t))
		if req.reader.read == nil {
			curl.easy_setopt(e, .SEEKFUNCTION, curl_on_seek)
			curl.easy_setopt(e, .SEEKDATA, rawptr(t))
			curl.easy_setopt(e, .POSTFIELDSIZE_LARGE, i64(body_len(req.body)))
		} else {
			curl.easy_setopt(e, .POSTFIELDSIZE_LARGE, req.body_len > 0 ? req.body_len : i64(-1))
		}
	}
	if req.method != "" && req.method != "GET" && req.method != "POST" {
		curl.easy_setopt(e, .CUSTOMREQUEST, strings.clone_to_cstring(req.method, context.temp_allocator))
	} else if req.method == "GET" && has_body {
		curl.easy_setopt(e, .CUSTOMREQUEST, cstring("GET"))
	}
	h.live[t.id] = t
	if h.depth > 0 {
		append(&h.adds, t)
	} else if !curl_add(h, t) {
		delete_key(&h.live, t.id)
		curl_free_transfer(h, t)
		return 0, .Other
	}
	return t.id, .None
}

curl_cancel :: proc(h: ^Curl, id: Id) {
	context = h.ctx
	t, ok := h.live[id]
	if !ok {
		return
	}
	delete_key(&h.live, id)
	t.dead = true
	if h.depth > 0 {
		append(&h.kills, t)
		return
	}
	curl_retire(h, t)
}

@(private)
curl_add :: proc(h: ^Curl, t: ^Curl_Transfer) -> bool {
	if curl.multi_add_handle(h.multi, t.easy) != .OK {
		return false
	}
	t.added = true
	return true
}

@(private)
curl_retire :: proc(h: ^Curl, t: ^Curl_Transfer) {
	if t.added {
		curl.multi_remove_handle(h.multi, t.easy)
		t.added = false
	}
	curl_free_transfer(h, t)
}

@(private)
curl_free_transfer :: proc(h: ^Curl, t: ^Curl_Transfer) {
	if t.easy != nil {
		if len(h.pool) < h.pool_max {
			curl.easy_reset(t.easy)
			append(&h.pool, t.easy)
		} else {
			curl.easy_cleanup(t.easy)
		}
	}
	if t.slist != nil {
		curl.slist_free_all(t.slist)
	}
	delete(t.url, h.allocator)
	delete(t.head_buf)
	delete(t.head_idx)
	free(t, h.allocator)
}

@(private)
curl_flush :: proc(h: ^Curl) {
	for len(h.kills) > 0 || len(h.adds) > 0 {
		for len(h.kills) > 0 {
			t := pop(&h.kills)
			for a, i in h.adds {
				if a == t {
					unordered_remove(&h.adds, i)
					break
				}
			}
			curl_retire(h, t)
		}
		for len(h.adds) > 0 {
			t := h.adds[0]
			ordered_remove(&h.adds, 0)
			if t.dead {
				continue
			}
			if !curl_add(h, t) {
				delete_key(&h.live, t.id)
				sink := t.sink
				id := t.id
				curl_free_transfer(h, t)
				if sink.done != nil {
					sink.done(sink.data, id, .Other, "curl_multi_add_handle failed")
				}
			}
		}
	}
}

@(private)
curl_drive :: proc(h: ^Curl, fd: curl.socket_t, flags: c.int) {
	running: c.int
	h.depth += 1
	curl.multi_socket_action(h.multi, fd, flags, &running)
	h.depth -= 1
	curl_reap(h)
	curl_flush(h)
}

@(private)
curl_reap :: proc(h: ^Curl) {
	for {
		left: c.int
		msg := curl.multi_info_read(h.multi, &left)
		if msg == nil {
			break
		}
		if msg.msg != .DONE {
			continue
		}
		tp: rawptr
		curl.easy_getinfo(msg.easy_handle, .PRIVATE, &tp)
		t := (^Curl_Transfer)(tp)
		if t == nil {
			continue
		}
		result := msg.data.result
		curl.multi_remove_handle(h.multi, t.easy)
		t.added = false
		if t.dead {
			continue
		}
		delete_key(&h.live, t.id)
		if !t.head_sent && result == .E_OK {
			curl_send_head(t)
		}
		err, detail := curl_error(t, result)
		sink := t.sink
		id := t.id
		detail_copy := strings.clone(detail, context.temp_allocator)
		curl_free_transfer(h, t)
		if sink.done != nil {
			sink.done(sink.data, id, err, detail_copy)
		}
	}
}

@(private)
curl_error :: proc(t: ^Curl_Transfer, r: curl.code) -> (Error, string) {
	msg := string(cstring(&t.errbuf[0]))
	if msg == "" && r != .E_OK {
		msg = string(curl.easy_strerror(r))
	}
	#partial switch r {
	case .E_OK:
		return .None, ""
	case .E_COULDNT_RESOLVE_HOST, .E_COULDNT_RESOLVE_PROXY:
		return .Dns, msg
	case .E_COULDNT_CONNECT:
		return .Connect, msg
	case .E_OPERATION_TIMEDOUT:
		if t.head_sent {
			return .Stalled, msg
		}
		return .Timeout, msg
	case .E_SSL_CONNECT_ERROR, .E_PEER_FAILED_VERIFICATION, .E_SSL_CERTPROBLEM, .E_SSL_CIPHER, .E_SSL_CACERT_BADFILE:
		return .Tls, msg
	case .E_GOT_NOTHING, .E_SEND_ERROR, .E_RECV_ERROR, .E_PARTIAL_FILE, .E_HTTP2_STREAM:
		return .Reset, msg
	case .E_HTTP2, .E_WEIRD_SERVER_REPLY, .E_BAD_CONTENT_ENCODING:
		return .Protocol, msg
	case .E_OUT_OF_MEMORY:
		return .No_Memory, msg
	case .E_READ_ERROR, .E_ABORTED_BY_CALLBACK:
		if t.reader.read != nil {
			return .Body, msg
		}
		return .Cancelled, msg
	case .E_UNSUPPORTED_PROTOCOL, .E_URL_MALFORMAT:
		return .Unsupported, msg
	case .E_WRITE_ERROR:
		return .Cancelled, msg
	}
	return .Other, msg
}

@(private)
curl_send_head :: proc(t: ^Curl_Transfer) {
	t.head_sent = true
	if t.status == 0 {
		code: c.long
		curl.easy_getinfo(t.easy, .RESPONSE_CODE, &code)
		t.status = int(code)
	}
	if t.sink.head == nil {
		return
	}
	hs := make([]Header, len(t.head_idx), context.temp_allocator)
	for x, i in t.head_idx {
		hs[i] = Header {
			name  = string(t.head_buf[x[0]:x[1]]),
			value = string(t.head_buf[x[2]:x[3]]),
		}
	}
	t.sink.head(t.sink.data, t.id, t.status, hs)
}

@(private)
curl_on_write :: proc "c" (ptr: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	t := (^Curl_Transfer)(userdata)
	n := size * nmemb
	if t.dead {
		return 0
	}
	context = t.owner.ctx
	if !t.head_sent {
		curl_send_head(t)
		if t.dead {
			return 0
		}
	}
	if t.sink.body != nil && n > 0 {
		if !t.sink.body(t.sink.data, t.id, ptr[:n]) {
			if !t.dead {
				delete_key(&t.owner.live, t.id)
				t.dead = true
				append(&t.owner.kills, t)
			}
			return 0
		}
		if t.dead {
			return 0
		}
	}
	return n
}

@(private)
curl_on_header :: proc "c" (ptr: [^]u8, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	t := (^Curl_Transfer)(userdata)
	n := int(size * nmemb)
	if t.dead {
		return 0
	}
	context = t.owner.ctx
	line := ptr[:n]
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == '\r') {
		line = line[:len(line) - 1]
	}
	if len(line) >= 5 && string(line[:5]) == "HTTP/" {
		clear(&t.head_buf)
		clear(&t.head_idx)
		sp := 0
		for sp < len(line) && line[sp] != ' ' {
			sp += 1
		}
		code := 0
		k := sp + 1
		for k < len(line) && line[k] >= '0' && line[k] <= '9' {
			code = code * 10 + int(line[k] - '0')
			k += 1
		}
		t.status = code
		return c.size_t(n)
	}
	if len(line) == 0 || t.status < 200 {
		return c.size_t(n)
	}
	colon := -1
	for b, i in line {
		if b == ':' {
			colon = i
			break
		}
	}
	if colon <= 0 || len(t.head_buf) + len(line) > 1 << 20 {
		return c.size_t(n)
	}
	value := line[colon + 1:]
	for len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
		value = value[1:]
	}
	base := u32(len(t.head_buf))
	append(&t.head_buf, ..line[:colon])
	vstart := u32(len(t.head_buf))
	append(&t.head_buf, ..value)
	append(&t.head_idx, [4]u32{base, base + u32(colon), vstart, u32(len(t.head_buf))})
	return c.size_t(n)
}

@(private)
curl_on_read :: proc "c" (buffer: [^]u8, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
	t := (^Curl_Transfer)(userdata)
	if t.dead {
		return curl.READFUNC_ABORT
	}
	room := int(size * nitems)
	if t.reader.read != nil {
		context = t.owner.ctx
		n, st := t.reader.read(t.reader.data, t.id, buffer[:room])
		switch st {
		case .Data:
			if n == 0 {
				t.paused = true
				return curl.READFUNC_PAUSE
			}
			return c.size_t(min(n, room))
		case .Wait:
			if n > 0 {
				return c.size_t(min(n, room))
			}
			t.paused = true
			return curl.READFUNC_PAUSE
		case .End:
			return c.size_t(min(n, room))
		case .Fail:
			return curl.READFUNC_ABORT
		}
	}
	w := 0
	for w < room && t.seg < len(t.body) {
		src := t.body[t.seg][t.seg_off:]
		k := min(len(src), room - w)
		runtime.mem_copy_non_overlapping(&buffer[w], raw_data(src), k)
		w += k
		t.seg_off += k
		if t.seg_off >= len(t.body[t.seg]) {
			t.seg += 1
			t.seg_off = 0
		}
	}
	return c.size_t(w)
}

@(private)
curl_on_seek :: proc "c" (userdata: rawptr, offset: curl.off_t, origin: c.int) -> c.int {
	t := (^Curl_Transfer)(userdata)
	if origin != 0 || offset < 0 {
		return curl.SEEKFUNC_CANTSEEK
	}
	rest := int(offset)
	for i in 0 ..< len(t.body) {
		if rest < len(t.body[i]) {
			t.seg = i
			t.seg_off = rest
			return curl.SEEKFUNC_OK
		}
		rest -= len(t.body[i])
	}
	if rest == 0 {
		t.seg = len(t.body)
		t.seg_off = 0
		return curl.SEEKFUNC_OK
	}
	return curl.SEEKFUNC_FAIL
}

@(private)
curl_on_socket :: proc "c" (easy: ^curl.CURL, s: curl.socket_t, what: c.int, userp: rawptr, socketp: rawptr) -> c.int {
	h := (^Curl)(userp)
	context = h.ctx
	w := prim.Watch(uintptr(socketp))
	if what == curl.POLL_REMOVE {
		if w != 0 {
			prim.unwatch(h.loop, w)
			h.sockets -= 1
		}
		curl.multi_assign(h.multi, s, nil)
		return 0
	}
	ev: prim.Events
	if what == curl.POLL_IN || what == curl.POLL_INOUT {
		ev += {.Read}
	}
	if what == curl.POLL_OUT || what == curl.POLL_INOUT {
		ev += {.Write}
	}
	if w == 0 {
		nw, err := prim.watch(h.loop, prim.Fd(s), ev, h, curl_on_ready)
		if err != .None {
			return -1
		}
		h.sockets += 1
		curl.multi_assign(h.multi, s, rawptr(uintptr(nw)))
	} else {
		prim.watch_modify(h.loop, w, ev)
	}
	return 0
}

@(private)
curl_on_ready :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	h := (^Curl)(data)
	flags: c.int
	if .Read in events || .Hangup in events {
		flags |= curl.CSELECT_IN
	}
	if .Write in events {
		flags |= curl.CSELECT_OUT
	}
	if .Error in events {
		flags |= curl.CSELECT_ERR
	}
	curl_drive(h, curl.socket_t(fd), flags)
}

@(private)
curl_on_timer :: proc "c" (multi: ^curl.CURLM, timeout_ms: c.long, userp: rawptr) -> c.int {
	h := (^Curl)(userp)
	context = h.ctx
	if h.timer != 0 {
		prim.timer_cancel(h.loop, h.timer)
		h.timer = 0
	}
	if timeout_ms >= 0 {
		h.timer = prim.timer(h.loop, i64(timeout_ms), h, curl_on_tick)
	}
	return 0
}

@(private)
curl_on_tick :: proc(l: ^prim.Loop, data: rawptr) {
	h := (^Curl)(data)
	h.timer = 0
	curl_drive(h, curl.SOCKET_TIMEOUT, 0)
}

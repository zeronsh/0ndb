package http

Id :: distinct u64

Error :: enum u8 {
	None,
	Cancelled,
	Dns,
	Connect,
	Tls,
	Timeout,
	Stalled,
	Reset,
	Protocol,
	Too_Large,
	Unsupported,
	Body,
	No_Memory,
	Other,
}

Header :: struct {
	name:  string,
	value: string,
}

Version :: enum u8 {
	Auto,
	Http1,
	Http2,
	Http2_Prior_Knowledge,
}

Read_State :: enum u8 {
	Data,
	Wait,
	End,
	Fail,
}

Body_Reader :: struct {
	data: rawptr,
	read: proc(data: rawptr, id: Id, dst: []u8) -> (n: int, state: Read_State),
}

Request :: struct {
	method:     string,
	url:        string,
	headers:    []Header,
	body:       [][]u8,
	reader:     Body_Reader,
	body_len:   i64,
	version:    Version,
	connect_ms: i64,
	stall_ms:   i64,
	timeout_ms: i64,
	follow:     bool,
}

Sink :: struct {
	data: rawptr,
	head: proc(data: rawptr, id: Id, status: int, headers: []Header),
	body: proc(data: rawptr, id: Id, chunk: []u8) -> bool,
	done: proc(data: rawptr, id: Id, err: Error, detail: string),
}

Client :: struct {
	data:   rawptr,
	start:  proc(data: rawptr, req: ^Request, sink: Sink) -> (Id, Error),
	cancel: proc(data: rawptr, id: Id),
	resume: proc(data: rawptr, id: Id),
}

start :: proc(c: ^Client, req: ^Request, sink: Sink) -> (Id, Error) {
	return c.start(c.data, req, sink)
}

cancel :: proc(c: ^Client, id: Id) {
	c.cancel(c.data, id)
}

resume :: proc(c: ^Client, id: Id) {
	if c.resume != nil {
		c.resume(c.data, id)
	}
}

body_len :: proc "contextless" (body: [][]u8) -> int {
	n := 0
	for b in body {
		n += len(b)
	}
	return n
}

header_find :: proc "contextless" (headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if ascii_ieq(h.name, name) {
			return h.value, true
		}
	}
	return "", false
}

ascii_ieq :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x := a[i]
		y := b[i]
		if x >= 'A' && x <= 'Z' {
			x += 32
		}
		if y >= 'A' && y <= 'Z' {
			y += 32
		}
		if x != y {
			return false
		}
	}
	return true
}

error_text :: proc "contextless" (err: Error) -> string {
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
	case .Unsupported:
		return "the request is not supported"
	case .Body:
		return "the request body could not be produced"
	case .No_Memory:
		return "out of memory"
	case .Other:
		return "the request failed"
	}
	return "the request failed"
}

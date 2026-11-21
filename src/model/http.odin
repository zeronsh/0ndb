package model

Http_Id :: distinct u64

Http_Error :: enum u8 {
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
	No_Memory,
	Other,
}

Header :: struct {
	name:  string,
	value: string,
}

Http_Request :: struct {
	method:        string,
	url:           string,
	headers:       []string,
	body:          [][]u8,
	connect_ms:    i64,
	stall_ms:      i64,
	max_body:      int,
}

Http_Sink :: struct {
	data: rawptr,
	head: proc(data: rawptr, id: Http_Id, status: int, headers: []Header),
	body: proc(data: rawptr, id: Http_Id, chunk: []u8) -> bool,
	done: proc(data: rawptr, id: Http_Id, err: Http_Error, detail: string),
}

Http :: struct {
	data:   rawptr,
	start:  proc(data: rawptr, req: ^Http_Request, sink: Http_Sink) -> (Http_Id, Http_Error),
	cancel: proc(data: rawptr, id: Http_Id),
}

http_start :: proc(h: ^Http, req: ^Http_Request, sink: Http_Sink) -> (Http_Id, Http_Error) {
	return h.start(h.data, req, sink)
}

http_cancel :: proc(h: ^Http, id: Http_Id) {
	h.cancel(h.data, id)
}

body_len :: proc "contextless" (body: [][]u8) -> int {
	n := 0
	for b in body {
		n += len(b)
	}
	return n
}

header_find :: proc(headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if ascii_ieq(h.name, name) {
			return h.value, true
		}
	}
	return "", false
}

@(private)
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

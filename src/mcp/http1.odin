package mcp

import "core:strconv"
import "core:strings"

Http_Parse_State :: enum u8 {
	Head,
	Length,
	Chunk_Size,
	Chunk_Data,
	Chunk_Crlf,
	Trailers,
	Until_Close,
	Done,
	Error,
}

Http_Parse_Event :: enum u8 {
	Need_More,
	Head,
	Body,
	Done,
	Error,
}

Http_Parser :: struct {
	request:      bool,
	state:        Http_Parse_State,
	head:         Buf,
	headers:      [dynamic]Header,
	method:       string,
	target:       string,
	status:       int,
	minor:        int,
	length:       i64,
	remaining:    i64,
	chunked:      bool,
	keep_alive:   bool,
	no_body:      bool,
	max_head:     int,
	trailer_line: int,
	chunk_line:   [32]u8,
	chunk_len:    int,
	chunk_ext:    bool,
}

HTTP_MAX_HEAD :: 64 * 1024

http_parser_init :: proc(p: ^Http_Parser, request: bool, allocator := context.allocator) {
	p^ = {}
	p.request = request
	p.max_head = HTTP_MAX_HEAD
	p.head = make(Buf, allocator)
	p.headers = make([dynamic]Header, allocator)
	p.length = -1
}

http_parser_reset :: proc(p: ^Http_Parser) {
	clear(&p.head)
	clear(&p.headers)
	if cap(p.head) > HTTP_MAX_HEAD {
		delete(p.head)
		p.head = nil
	}
	p.state = .Head
	p.method = ""
	p.target = ""
	p.status = 0
	p.minor = 0
	p.length = -1
	p.remaining = 0
	p.chunked = false
	p.keep_alive = false
	p.no_body = false
	p.trailer_line = 0
	p.chunk_len = 0
	p.chunk_ext = false
}

http_parser_destroy :: proc(p: ^Http_Parser) {
	delete(p.head)
	delete(p.headers)
	p^ = {}
}

http_header :: proc "contextless" (headers: []Header, name: string) -> (string, bool) {
	for h in headers {
		if _ascii_equal_fold(h.name, name) {
			return h.value, true
		}
	}
	return "", false
}

http_header_count :: proc "contextless" (headers: []Header, name: string) -> int {
	n := 0
	for h in headers {
		if _ascii_equal_fold(h.name, name) {
			n += 1
		}
	}
	return n
}

@(private)
_ascii_lower :: proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

@(private)
_ascii_equal_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if _ascii_lower(a[i]) != _ascii_lower(b[i]) {
			return false
		}
	}
	return true
}

http_token_has :: proc "contextless" (value: string, token: string) -> bool {
	start := 0
	for i in 0 ..= len(value) {
		if i < len(value) && value[i] != ',' {
			continue
		}
		part := value[start:i]
		start = i + 1
		a, b := 0, len(part)
		for a < b && (part[a] == ' ' || part[a] == '\t') {
			a += 1
		}
		semi := a
		for semi < b && part[semi] != ';' {
			semi += 1
		}
		b = semi
		for b > a && (part[b - 1] == ' ' || part[b - 1] == '\t') {
			b -= 1
		}
		if _ascii_equal_fold(part[a:b], token) {
			return true
		}
	}
	return false
}

@(private)
_find_head_end :: proc "contextless" (b: []u8, from: int) -> int {
	i := max(from, 0)
	for i < len(b) {
		if b[i] == '\n' {
			if i + 1 < len(b) && b[i + 1] == '\n' {
				return i + 2
			}
			if i + 2 < len(b) && b[i + 1] == '\r' && b[i + 2] == '\n' {
				return i + 3
			}
		}
		i += 1
	}
	return -1
}

@(private)
_parse_head :: proc(p: ^Http_Parser) -> bool {
	text := string(p.head[:])
	first := true
	for line_raw in strings.split_lines_iterator(&text) {
		line := strings.trim_right(line_raw, "\r")
		if first {
			first = false
			if p.request {
				sp1 := strings.index_byte(line, ' ')
				if sp1 <= 0 {
					return false
				}
				rest := line[sp1 + 1:]
				sp2 := strings.last_index_byte(rest, ' ')
				if sp2 <= 0 {
					return false
				}
				p.method = line[:sp1]
				p.target = rest[:sp2]
				ver := rest[sp2 + 1:]
				if !strings.has_prefix(ver, "HTTP/1.") || len(ver) != 8 {
					return false
				}
				p.minor = int(ver[7] - '0')
			} else {
				if !strings.has_prefix(line, "HTTP/1.") || len(line) < 12 {
					return false
				}
				p.minor = int(line[7] - '0')
				code, ok := strconv.parse_int(line[9:12], 10)
				if !ok {
					return false
				}
				p.status = code
			}
			continue
		}
		if len(line) == 0 {
			break
		}
		if line[0] == ' ' || line[0] == '\t' {
			return false
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return false
		}
		name := line[:colon]
		for i in 0 ..< len(name) {
			if !_tchar(name[i]) {
				return false
			}
		}
		value := strings.trim(line[colon + 1:], " \t")
		append(&p.headers, Header{name = name, value = value})
	}
	p.keep_alive = p.minor >= 1
	if c, ok := http_header(p.headers[:], "connection"); ok {
		if http_token_has(c, "close") {
			p.keep_alive = false
		} else if http_token_has(c, "keep-alive") {
			p.keep_alive = true
		}
	}
	if te, ok := http_header(p.headers[:], "transfer-encoding"); ok {
		if !http_token_has(te, "chunked") {
			return false
		}
		p.chunked = true
	}
	if !p.chunked {
		if http_header_count(p.headers[:], "content-length") > 1 {
			v0, _ := http_header(p.headers[:], "content-length")
			for h in p.headers {
				if _ascii_equal_fold(h.name, "content-length") && h.value != v0 {
					return false
				}
			}
		}
		if cl, ok := http_header(p.headers[:], "content-length"); ok {
			for i in 0 ..< len(cl) {
				if cl[i] < '0' || cl[i] > '9' {
					return false
				}
			}
			n, nok := strconv.parse_i64(cl)
			if !nok || n < 0 {
				return false
			}
			p.length = n
		}
	}
	return true
}

http_parser_no_body :: proc "contextless" (p: ^Http_Parser) {
	p.no_body = true
}

http_feed :: proc(p: ^Http_Parser, data: []u8) -> (used: int, ev: Http_Parse_Event, body: []u8) {
	switch p.state {
	case .Head:
		old := len(p.head)
		search := max(old - 3, 0)
		room := p.max_head - old
		take := min(len(data), max(room, 0))
		append(&p.head, ..data[:take])
		end := _find_head_end(p.head[:], search)
		if end < 0 {
			if take < len(data) || len(p.head) >= p.max_head {
				p.state = .Error
				return take, .Error, nil
			}
			return take, .Need_More, nil
		}
		used = end - old
		resize(&p.head, end)
		for len(p.head) > 0 && (p.head[0] == '\r' || p.head[0] == '\n') {
			ordered_remove(&p.head, 0)
		}
		if !_parse_head(p) {
			p.state = .Error
			return used, .Error, nil
		}
		switch {
		case !p.request && (p.status < 200 || p.status == 204 || p.status == 304):
			if p.status >= 100 && p.status < 200 {
				http_parser_reset(p)
				return used, .Need_More, nil
			}
			p.state = .Done
		case p.no_body:
			p.state = .Done
		case p.chunked:
			p.state = .Chunk_Size
		case p.length >= 0:
			p.remaining = p.length
			p.state = .Length if p.length > 0 else .Done
		case p.request:
			p.state = .Done
		case:
			p.state = .Until_Close
			p.keep_alive = false
		}
		return used, .Head, nil
	case .Length:
		n := int(min(i64(len(data)), p.remaining))
		p.remaining -= i64(n)
		if p.remaining == 0 {
			p.state = .Done
		}
		if n == 0 {
			return 0, .Need_More, nil
		}
		return n, .Body, data[:n]
	case .Until_Close:
		if len(data) == 0 {
			return 0, .Need_More, nil
		}
		return len(data), .Body, data
	case .Chunk_Size:
		i := 0
		for i < len(data) {
			c := data[i]
			i += 1
			if c == '\n' {
				line := strings.trim(string(p.chunk_line[:p.chunk_len]), " \t\r")
				p.chunk_len = 0
				p.chunk_ext = false
				p.trailer_line = 0
				size, ok := strconv.parse_i64_of_base(line, 16)
				if !ok || size < 0 || len(line) == 0 {
					p.state = .Error
					return i, .Error, nil
				}
				if size == 0 {
					p.state = .Trailers
					p.trailer_line = 0
				} else {
					p.remaining = size
					p.state = .Chunk_Data
				}
				return i, .Need_More, nil
			}
			if c == ';' {
				p.chunk_ext = true
			}
			if p.chunk_ext {
				p.trailer_line += 1
				if p.trailer_line > p.max_head {
					p.state = .Error
					return i, .Error, nil
				}
				continue
			}
			if p.chunk_len >= len(p.chunk_line) {
				p.state = .Error
				return i, .Error, nil
			}
			p.chunk_line[p.chunk_len] = c
			p.chunk_len += 1
		}
		return i, .Need_More, nil
	case .Chunk_Data:
		n := int(min(i64(len(data)), p.remaining))
		p.remaining -= i64(n)
		if p.remaining == 0 {
			p.state = .Chunk_Crlf
		}
		if n == 0 {
			return 0, .Need_More, nil
		}
		return n, .Body, data[:n]
	case .Chunk_Crlf:
		i := 0
		for i < len(data) {
			c := data[i]
			i += 1
			if c == '\n' {
				p.state = .Chunk_Size
				return i, .Need_More, nil
			}
			if c != '\r' {
				p.state = .Error
				return i, .Error, nil
			}
		}
		return i, .Need_More, nil
	case .Trailers:
		i := 0
		for i < len(data) {
			c := data[i]
			i += 1
			if c == '\n' {
				if p.trailer_line == 0 {
					p.state = .Done
					return i, .Done, nil
				}
				p.trailer_line = 0
			} else if c != '\r' {
				p.trailer_line += 1
				if p.trailer_line > p.max_head {
					p.state = .Error
					return i, .Error, nil
				}
			}
		}
		return i, .Need_More, nil
	case .Done:
		return 0, .Done, nil
	case .Error:
		return 0, .Error, nil
	}
	return 0, .Error, nil
}

http_parser_eof :: proc "contextless" (p: ^Http_Parser) -> bool {
	if p.state == .Until_Close {
		p.state = .Done
		return true
	}
	return p.state == .Done
}

http_write_chunk :: proc(b: ^Buf, data: []u8) {
	if len(data) == 0 {
		return
	}
	hex: [32]u8
	append(b, strconv.write_uint(hex[:], u64(len(data)), 16))
	append(b, "\r\n")
	append(b, ..data)
	append(b, "\r\n")
}

http_status_text :: proc "contextless" (code: int) -> string {
	switch code {
	case 200:
		return "OK"
	case 202:
		return "Accepted"
	case 204:
		return "No Content"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 406:
		return "Not Acceptable"
	case 413:
		return "Content Too Large"
	case 415:
		return "Unsupported Media Type"
	case 500:
		return "Internal Server Error"
	case 503:
		return "Service Unavailable"
	}
	return "Status"
}

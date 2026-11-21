package mcp

Sse_Event :: struct {
	event: string,
	data:  string,
	id:    string,
	retry: i64,
}

Sse_Parser :: struct {
	line:       Buf,
	data:       Buf,
	event:      Buf,
	last_id:    Buf,
	retry:      i64,
	has_data:   bool,
	skip_lf:    bool,
	started:    bool,
	max_event:  int,
	overflow:   bool,
}

SSE_MAX_EVENT :: 64 << 20

sse_init :: proc(p: ^Sse_Parser, allocator := context.allocator) {
	p^ = {}
	p.line = make(Buf, allocator)
	p.data = make(Buf, allocator)
	p.event = make(Buf, allocator)
	p.last_id = make(Buf, allocator)
	p.max_event = SSE_MAX_EVENT
}

sse_destroy :: proc(p: ^Sse_Parser) {
	delete(p.line)
	delete(p.data)
	delete(p.event)
	delete(p.last_id)
	p^ = {}
}

sse_reset_stream :: proc(p: ^Sse_Parser) {
	clear(&p.line)
	clear(&p.data)
	clear(&p.event)
	p.has_data = false
	p.skip_lf = false
	p.started = false
	p.overflow = false
}

sse_last_id :: proc "contextless" (p: ^Sse_Parser) -> string {
	return string(p.last_id[:])
}

Sse_Sink :: #type proc(data: rawptr, e: ^Sse_Event)

sse_feed :: proc(p: ^Sse_Parser, chunk: []u8, data: rawptr, sink: Sse_Sink) -> bool {
	i := 0
	for i < len(chunk) {
		c := chunk[i]
		if p.skip_lf {
			p.skip_lf = false
			if c == '\n' {
				i += 1
				continue
			}
		}
		if c == '\r' || c == '\n' {
			p.skip_lf = c == '\r'
			_sse_line(p, data, sink)
			clear(&p.line)
			i += 1
			continue
		}
		j := i
		for j < len(chunk) && chunk[j] != '\r' && chunk[j] != '\n' {
			j += 1
		}
		if len(p.line) + (j - i) > p.max_event {
			p.overflow = true
			return false
		}
		append(&p.line, ..chunk[i:j])
		i = j
	}
	return true
}

@(private)
_sse_line :: proc(p: ^Sse_Parser, data: rawptr, sink: Sse_Sink) {
	line := string(p.line[:])
	if !p.started {
		p.started = true
		if len(line) >= 3 && line[:3] == "\xef\xbb\xbf" {
			line = line[3:]
		}
	}
	if len(line) == 0 {
		if p.has_data {
			ev := Sse_Event {
				event = string(p.event[:]) if len(p.event) > 0 else "message",
				data  = string(p.data[:]),
				id    = string(p.last_id[:]),
				retry = p.retry,
			}
			sink(data, &ev)
		}
		clear(&p.data)
		clear(&p.event)
		p.has_data = false
		return
	}
	if line[0] == ':' {
		return
	}
	field := line
	value := ""
	for k in 0 ..< len(line) {
		if line[k] == ':' {
			field = line[:k]
			value = line[k + 1:]
			if len(value) > 0 && value[0] == ' ' {
				value = value[1:]
			}
			break
		}
	}
	switch field {
	case "data":
		if p.has_data {
			append(&p.data, '\n')
		}
		append(&p.data, value)
		p.has_data = true
		if len(p.data) > p.max_event {
			p.overflow = true
			clear(&p.data)
			p.has_data = false
		}
	case "event":
		clear(&p.event)
		append(&p.event, value)
	case "id":
		nul := false
		for k in 0 ..< len(value) {
			if value[k] == 0 {
				nul = true
			}
		}
		if !nul {
			clear(&p.last_id)
			append(&p.last_id, value)
		}
	case "retry":
		v: i64 = 0
		ok := len(value) > 0
		for k in 0 ..< len(value) {
			if value[k] < '0' || value[k] > '9' {
				ok = false
				break
			}
			v = v * 10 + i64(value[k] - '0')
			if v > 1 << 40 {
				ok = false
				break
			}
		}
		if ok {
			p.retry = v
		}
	}
}

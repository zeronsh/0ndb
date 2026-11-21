package http

import "core:bytes"

Sse_Event :: struct {
	name: string,
	data: []u8,
	id:   string,
}

Sse :: struct {
	input:     []u8,
	pos:       int,
	pending:   [dynamic]u8,
	data_buf:  [dynamic]u8,
	name_buf:  [dynamic]u8,
	id_buf:    [dynamic]u8,
	data:      []u8,
	name:      []u8,
	data_own:  bool,
	name_own:  bool,
	has_data:  bool,
	last_cr:   bool,
	started:   bool,
	overflow:  bool,
	retry_ms:  int,
	max_event: int,
	events:    int,
}

SSE_DEFAULT_MAX_EVENT :: 64 << 20

sse_init :: proc(s: ^Sse, allocator := context.allocator, max_event := SSE_DEFAULT_MAX_EVENT) {
	s^ = {}
	s.pending = make([dynamic]u8, allocator)
	s.data_buf = make([dynamic]u8, allocator)
	s.name_buf = make([dynamic]u8, allocator)
	s.id_buf = make([dynamic]u8, allocator)
	s.max_event = max_event
	s.retry_ms = -1
}

sse_reset :: proc(s: ^Sse) {
	clear(&s.pending)
	clear(&s.data_buf)
	clear(&s.name_buf)
	clear(&s.id_buf)
	s.input = nil
	s.pos = 0
	s.data = nil
	s.name = nil
	s.data_own = false
	s.name_own = false
	s.has_data = false
	s.last_cr = false
	s.started = false
	s.overflow = false
	s.retry_ms = -1
	s.events = 0
}

sse_destroy :: proc(s: ^Sse) {
	delete(s.pending)
	delete(s.data_buf)
	delete(s.name_buf)
	delete(s.id_buf)
	s^ = {}
}

sse_feed :: proc(s: ^Sse, chunk: []u8) {
	s.input = chunk
	s.pos = 0
}

sse_footprint :: proc(s: ^Sse) -> int {
	return cap(s.pending) + cap(s.data_buf) + cap(s.name_buf) + cap(s.id_buf)
}

sse_next :: proc(s: ^Sse) -> (ev: Sse_Event, ok: bool) {
	for {
		line, got := sse_line(s)
		if !got {
			sse_own(s)
			return {}, false
		}
		if s.overflow {
			return {}, false
		}
		if len(line) == 0 {
			if !s.has_data {
				s.name = nil
				s.name_own = false
				continue
			}
			ev = Sse_Event {
				name = string(s.name),
				data = s.data,
				id   = string(s.id_buf[:]),
			}
			s.has_data = false
			s.data = nil
			s.data_own = false
			s.name = nil
			s.name_own = false
			s.events += 1
			return ev, true
		}
		sse_field(s, line)
	}
}

@(private)
sse_line :: proc(s: ^Sse) -> ([]u8, bool) {
	if s.last_cr && s.pos < len(s.input) {
		if s.input[s.pos] == '\n' {
			s.pos += 1
		}
		s.last_cr = false
	}
	rest := s.input[s.pos:]
	if !s.started && len(rest) > 0 {
		whole := len(s.pending) + len(rest)
		if whole < 3 {
			append(&s.pending, ..rest)
			s.pos = len(s.input)
			return nil, false
		}
		if len(s.pending) > 0 {
			append(&s.pending, ..rest)
			s.pos = len(s.input)
			if s.pending[0] == 0xef && s.pending[1] == 0xbb && s.pending[2] == 0xbf {
				remove_range(&s.pending, 0, 3)
			}
			s.started = true
			tmp := make([dynamic]u8, 0, len(s.pending), context.temp_allocator)
			append(&tmp, ..s.pending[:])
			clear(&s.pending)
			s.input = tmp[:]
			s.pos = 0
			rest = s.input
		} else {
			if rest[0] == 0xef && rest[1] == 0xbb && rest[2] == 0xbf {
				s.pos += 3
				rest = rest[3:]
			}
			s.started = true
		}
	}
	if len(rest) == 0 {
		return nil, false
	}
	nl := bytes.index_byte(rest, '\n')
	scan := rest if nl < 0 else rest[:nl]
	cr := bytes.index_byte(scan, '\r')
	term := -1
	skip := 1
	if cr >= 0 {
		term = cr
		if cr + 1 < len(rest) {
			if rest[cr + 1] == '\n' {
				skip = 2
			}
		} else {
			s.last_cr = true
		}
	} else if nl >= 0 {
		term = nl
	}
	if term < 0 {
		if len(s.pending) + len(rest) > s.max_event {
			s.overflow = true
			return nil, true
		}
		append(&s.pending, ..rest)
		s.pos = len(s.input)
		return nil, false
	}
	line := rest[:term]
	s.pos += term + skip
	if len(s.pending) > 0 {
		append(&s.pending, ..line)
		owned := make([]u8, len(s.pending), context.temp_allocator)
		copy(owned, s.pending[:])
		clear(&s.pending)
		return owned, true
	}
	return line, true
}

@(private)
sse_field :: proc(s: ^Sse, line: []u8) {
	if line[0] == ':' {
		return
	}
	colon := bytes.index_byte(line, ':')
	name := line
	value: []u8
	if colon >= 0 {
		name = line[:colon]
		value = line[colon + 1:]
		if len(value) > 0 && value[0] == ' ' {
			value = value[1:]
		}
	}
	switch string(name) {
	case "data":
		if !s.has_data {
			s.has_data = true
			s.data = value
			s.data_own = false
			return
		}
		if !s.data_own {
			clear(&s.data_buf)
			append(&s.data_buf, ..s.data)
			s.data_own = true
		}
		if len(s.data_buf) + len(value) + 1 > s.max_event {
			s.overflow = true
			return
		}
		append(&s.data_buf, '\n')
		append(&s.data_buf, ..value)
		s.data = s.data_buf[:]
	case "event":
		s.name = value
		s.name_own = false
	case "id":
		if bytes.index_byte(value, 0) < 0 {
			clear(&s.id_buf)
			append(&s.id_buf, ..value)
		}
	case "retry":
		n := 0
		for c in value {
			if c < '0' || c > '9' {
				return
			}
			n = n * 10 + int(c - '0')
		}
		if len(value) > 0 {
			s.retry_ms = n
		}
	}
}

@(private)
sse_own :: proc(s: ^Sse) {
	if s.has_data && !s.data_own {
		clear(&s.data_buf)
		append(&s.data_buf, ..s.data)
		s.data = s.data_buf[:]
		s.data_own = true
	}
	if s.name != nil && !s.name_own {
		if !slice_within(s.name, s.name_buf[:]) {
			clear(&s.name_buf)
			append(&s.name_buf, ..s.name)
			s.name = s.name_buf[:]
		}
		s.name_own = true
	}
}

@(private)
slice_within :: proc "contextless" (a, b: []u8) -> bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	pa := uintptr(raw_data(a))
	pb := uintptr(raw_data(b))
	return pa >= pb && pa + uintptr(len(a)) <= pb + uintptr(len(b))
}

package model

import "core:math/rand"

stream_init :: proc(s: ^Stream, allocator := context.allocator) {
	s^ = {}
	sse_init(&s.sse, allocator)
	s.blocks = make([dynamic]Acc, allocator)
	s.scratch = make([dynamic]u8, allocator)
	s.msg_id = make([dynamic]u8, allocator)
	s.model = make([dynamic]u8, allocator)
	s.detail = make([dynamic]u8, allocator)
	s.fail_msg = make([dynamic]u8, allocator)
}

stream_reset :: proc(s: ^Stream) {
	sse_reset(&s.sse)
	for i in 0 ..< s.used {
		acc_clear(&s.blocks[i])
	}
	s.used = 0
	clear(&s.scratch)
	clear(&s.msg_id)
	clear(&s.model)
	clear(&s.detail)
	clear(&s.fail_msg)
	s.stop = .None
	s.usage = {}
	s.done = false
	s.started = false
	s.failure = {}
	s.chat_open = 0
}

stream_trim :: proc(s: ^Stream, keep: int) {
	for &a in s.blocks {
		acc_trim(&a, keep)
	}
	if cap(s.scratch) > keep {
		delete(s.scratch)
		s.scratch = make([dynamic]u8, s.blocks.allocator)
	}
	if cap(s.sse.data_buf) > keep {
		delete(s.sse.data_buf)
		s.sse.data_buf = make([dynamic]u8, s.blocks.allocator)
	}
	if cap(s.sse.pending) > keep {
		delete(s.sse.pending)
		s.sse.pending = make([dynamic]u8, s.blocks.allocator)
	}
}

stream_destroy :: proc(s: ^Stream) {
	sse_destroy(&s.sse)
	for &a in s.blocks {
		acc_free(&a)
	}
	delete(s.blocks)
	delete(s.scratch)
	delete(s.msg_id)
	delete(s.model)
	delete(s.detail)
	delete(s.fail_msg)
	s^ = {}
}

stream_footprint :: proc(s: ^Stream) -> int {
	n := sse_footprint(&s.sse) + cap(s.scratch) + cap(s.blocks) * size_of(Acc)
	for &a in s.blocks {
		n += cap(a.id) + cap(a.name) + cap(a.type) + cap(a.text) + cap(a.sig) + cap(a.raw)
	}
	return n
}

@(private)
acc_clear :: proc(a: ^Acc) {
	clear(&a.id)
	clear(&a.name)
	clear(&a.type)
	clear(&a.text)
	clear(&a.sig)
	clear(&a.raw)
	a.complete = false
	a.kind = .Other
	a.index = 0
}

@(private)
acc_trim :: proc(a: ^Acc, keep: int) {
	trim :: proc(b: ^[dynamic]u8, keep: int) {
		if cap(b) > keep {
			al := b.allocator
			delete(b^)
			b^ = make([dynamic]u8, al)
		}
	}
	trim(&a.text, keep)
	trim(&a.raw, keep)
	trim(&a.sig, keep)
}

@(private)
acc_free :: proc(a: ^Acc) {
	delete(a.id)
	delete(a.name)
	delete(a.type)
	delete(a.text)
	delete(a.sig)
	delete(a.raw)
}

acc_at :: proc(s: ^Stream, index: int) -> ^Acc {
	if index < 0 || index > 1 << 16 {
		return nil
	}
	for len(s.blocks) <= index {
		al := s.blocks.allocator
		append(&s.blocks, Acc{id = make([dynamic]u8, al), name = make([dynamic]u8, al), type = make([dynamic]u8, al), text = make([dynamic]u8, al), sig = make([dynamic]u8, al), raw = make([dynamic]u8, al)})
	}
	if index >= s.used {
		for i in s.used ..< index + 1 {
			acc_clear(&s.blocks[i])
			s.blocks[i].index = i
		}
		s.used = index + 1
	}
	return &s.blocks[index]
}

@(private)
set_bytes :: proc(dst: ^[dynamic]u8, s: string) {
	clear(dst)
	append(dst, s)
}

stream_fail :: proc(s: ^Stream, out: ^[dynamic]Delta, class: Failure_Class, code: string, msg: string) {
	if s.failure.class != .None {
		return
	}
	set_bytes(&s.fail_msg, msg)
	s.failure = Failure {
		class   = class,
		code    = code,
		message = string(s.fail_msg[:]),
	}
	append(out, Delta{kind = .Error, failure = s.failure})
}

usage_merge :: proc(dst: ^Call_Usage, src: Call_Usage) {
	dst.input = max(dst.input, src.input)
	dst.output = max(dst.output, src.output)
	dst.cache_read = max(dst.cache_read, src.cache_read)
	dst.cache_write = max(dst.cache_write, src.cache_write)
	dst.cache_long = max(dst.cache_long, src.cache_long)
	dst.reasoning = max(dst.reasoning, src.reasoning)
}

usage_add :: proc(dst: ^Call_Usage, src: Call_Usage) {
	dst.input += src.input
	dst.output += src.output
	dst.cache_read += src.cache_read
	dst.cache_write += src.cache_write
	dst.cache_long += src.cache_long
	dst.reasoning += src.reasoning
}

usage_prompt :: proc "contextless" (u: Call_Usage) -> u64 {
	return u.input + u.cache_read + u.cache_write + u.cache_long
}

usage_total :: proc "contextless" (u: Call_Usage) -> u64 {
	return usage_prompt(u) + u.output
}

cost_usd :: proc "contextless" (spec: Spec, u: Call_Usage) -> f64 {
	p := spec.price
	if spec.long_threshold > 0 && usage_prompt(u) > spec.long_threshold {
		p = spec.long_price
	}
	total := f64(u.input) * p.input + f64(u.cache_read) * p.cache_read + f64(u.cache_write) * p.cache_write + f64(u.cache_long) * p.cache_write2 + f64(u.output) * p.output
	return total / 1_000_000
}

retry_after_ms :: proc(headers: []Header) -> i64 {
	if v, ok := header_find(headers, HEADER_RETRY_AFTER_MS); ok {
		ms, good := parse_decimal_ms(v, 1)
		if good {
			return ms
		}
	}
	if v, ok := header_find(headers, HEADER_RETRY_AFTER); ok {
		ms, good := parse_decimal_ms(v, 1000)
		if good {
			return ms
		}
	}
	return 0
}

@(private)
parse_decimal_ms :: proc(v: string, scale: i64) -> (i64, bool) {
	whole: i64
	frac: i64
	frac_div: i64 = 1
	seen := false
	dot := false
	for c in transmute([]u8)v {
		switch c {
		case '0' ..= '9':
			seen = true
			if dot {
				if frac_div < 1_000_000 {
					frac = frac * 10 + i64(c - '0')
					frac_div *= 10
				}
			} else {
				if whole > 1 << 40 {
					return 0, false
				}
				whole = whole * 10 + i64(c - '0')
			}
		case '.':
			if dot {
				return 0, false
			}
			dot = true
		case ' ', '\t':
		case:
			return 0, false
		}
	}
	if !seen {
		return 0, false
	}
	return whole * scale + frac * scale / frac_div, true
}

should_retry_header :: proc(headers: []Header) -> i8 {
	if v, ok := header_find(headers, HEADER_SHOULD_RETRY); ok {
		if ascii_ieq(v, "true") {
			return 1
		}
		if ascii_ieq(v, "false") {
			return -1
		}
	}
	return 0
}

status_class :: proc(status: int) -> Failure_Class {
	switch status {
	case 401, 403:
		return .Auth
	case 402:
		return .Quota
	case 429:
		return .Rate_Limited
	case 503, 529:
		return .Overloaded
	case 413:
		return .Invalid
	case 408, 409, 425:
		return .Server
	}
	if status >= 500 {
		return .Server
	}
	if status >= 400 {
		return .Invalid
	}
	return .Malformed
}

failure_retryable :: proc(f: Failure) -> bool {
	if f.should_retry < 0 {
		return false
	}
	if f.should_retry > 0 {
		return true
	}
	#partial switch f.class {
	case .Network, .Server, .Overloaded, .Rate_Limited, .Malformed:
		return true
	}
	return false
}

backoff_ms :: proc(r: Retry, attempt: int, retry_after: i64) -> i64 {
	base := r.base_ms > 0 ? r.base_ms : 500
	cap_ms := r.max_ms > 0 ? r.max_ms : 32_000
	d := base
	for _ in 1 ..< attempt {
		d *= 2
		if d >= cap_ms {
			d = cap_ms
			break
		}
	}
	d = min(d, cap_ms)
	jittered := d / 2 + i64(rand.int63_max(max(d / 2, 1)))
	return max(jittered, retry_after)
}

contains_fold :: proc(hay, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	for i in 0 ..= len(hay) - len(needle) {
		if ascii_ieq(hay[i:i + len(needle)], needle) {
			return true
		}
	}
	return false
}

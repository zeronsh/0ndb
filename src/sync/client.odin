package osync

import "base:runtime"
import "core:crypto/ecdh"
import "../prim"

Client_State :: enum u8 {
	Idle,
	Handshake,
	Hello,
	Ready,
	Failed,
}

Event_Kind :: enum u8 {
	Welcome,
	Listing,
	Appended,
	Conflict,
	Data,
	Stored,
	Object,
	Missing,
	Length,
	Created,
	Dropped,
	Refused,
	Error,
	Redacted,
	Announce,
}

Event :: struct {
	kind:    Event_Kind,
	id:      [32]u8,
	at:      i64,
	length:  i64,
	total:   i64,
	data:    []u8,
	first:   bool,
	last:    bool,
	code:    Code,
	time:    i64,
	usage:   i64,
	quota:   i64,
	cursor:  i64,
	more:    bool,
	entries: []u8,
}

Client_Handler :: #type proc(user: rawptr, ev: ^Event) -> Error

Follow_Entry :: struct {
	stream: Stream_Id,
	offset: u64,
}

Client :: struct {
	state:     Client_State,
	unix:      bool,
	hs:        Handshake,
	hs_buf:    [2 + MSG2_LEN]u8,
	hs_have:   int,
	keys:      Session_Keys,
	binding:   [HASH_LEN]u8,
	bind_len:  int,
	out:       [dynamic]u8,
	out_pos:   int,
	held:      [dynamic]u8,
	streaming: bool,
	parser:    Parser,
	bulk:      Event,
	allocator: runtime.Allocator,
}

client_init :: proc(c: ^Client, allocator := context.allocator) {
	c^ = {
		allocator = allocator,
	}
	c.out = make([dynamic]u8, allocator)
	c.held = make([dynamic]u8, allocator)
	parser_init(&c.parser, false, allocator)
}

client_destroy :: proc(c: ^Client) {
	client_reset(c)
	delete(c.out)
	delete(c.held)
	parser_destroy(&c.parser)
	c^ = {}
}

client_reset :: proc(c: ^Client) {
	session_keys_clear(&c.keys)
	clear(&c.out)
	clear(&c.held)
	if cap(c.out) > 1 << 20 {
		delete(c.out)
		c.out = make([dynamic]u8, c.allocator)
	}
	if cap(c.held) > 1 << 20 {
		delete(c.held)
		c.held = make([dynamic]u8, c.allocator)
	}
	c.out_pos = 0
	c.streaming = false
	c.hs_have = 0
	c.state = .Idle
	c.bulk = {}
	parser_reset(&c.parser)
	parser_release(&c.parser)
}

client_begin_plain :: proc(c: ^Client, binding: []u8 = nil) {
	client_reset(c)
	c.unix = true
	c.state = .Hello
	c.bind_len = copy(c.binding[:], binding)
	if len(binding) > HASH_LEN {
		buf: [16 + HASH_LEN]u8
		m := hello_message(binding, &buf)
		c.bind_len = copy(c.binding[:], m[16:])
	}
}

client_begin :: proc(c: ^Client, static: ^ecdh.Private_Key, relay_public: Public_Key, out: []u8) -> (n: int, err: Error) {
	client_reset(c)
	c.unix = false
	if len(out) < 2 + MSG1_LEN {
		return 0, .Invalid
	}
	m := handshake_initiate(&c.hs, static, relay_public, out[2:]) or_return
	out[0] = u8(m)
	out[1] = u8(m >> 8)
	c.state = .Handshake
	return 2 + m, .None
}

client_handshake_need :: proc "contextless" (c: ^Client) -> int {
	if c.state != .Handshake {
		return 0
	}
	if c.hs_have < 2 {
		return 2 - c.hs_have
	}
	return 2 + MSG2_LEN - c.hs_have
}

client_handshake_feed :: proc(c: ^Client, data: []u8) -> (done: bool, err: Error) {
	if c.state != .Handshake || len(data) > client_handshake_need(c) {
		return false, .Protocol
	}
	copy(c.hs_buf[c.hs_have:], data)
	c.hs_have += len(data)
	if c.hs_have >= 2 && int(c.hs_buf[0]) | int(c.hs_buf[1]) << 8 != MSG2_LEN {
		c.state = .Failed
		return false, .Protocol
	}
	if c.hs_have < 2 + MSG2_LEN {
		return false, .None
	}
	keys, ferr := handshake_finish(&c.hs, c.hs_buf[2:])
	if ferr != .None {
		c.state = .Failed
		return false, ferr
	}
	c.keys = keys
	c.bind_len = copy(c.binding[:], keys.hash[:])
	session_keys_clear(&keys)
	c.state = .Hello
	return true, .None
}

client_keys :: proc(c: ^Client) -> ^Session_Keys {
	return &c.keys
}

client_hello :: proc(c: ^Client, creds: ^Credentials) -> Error {
	if c.state != .Hello {
		return .Protocol
	}
	start := frame_begin(&c.out, .Hello) or_return
	w := prim.writer(&c.out)
	prim.write_u8(&w, PROTOCOL_VERSION)
	if w.err != .None {
		resize(&c.out, start)
		return .No_Memory
	}
	if err := creds.produce(creds.data, c.binding[:c.bind_len], &c.out); err != .None {
		resize(&c.out, start)
		return err
	}
	if len(c.out) - start - FRAME_HEADER - 1 > CREDENTIAL_MAX {
		resize(&c.out, start)
		return .Too_Large
	}
	session_keys_clear(&c.keys)
	frame_end(&c.out, start, &w) or_return
	c.state = .Ready
	return .None
}

client_pending :: proc "contextless" (c: ^Client) -> []u8 {
	return c.out[c.out_pos:]
}

client_consumed :: proc(c: ^Client, n: int) {
	c.out_pos += n
	if c.out_pos >= len(c.out) {
		clear(&c.out)
		c.out_pos = 0
		if !c.streaming && len(c.held) > 0 {
			append(&c.out, ..c.held[:])
			clear(&c.held)
		}
		if len(c.out) == 0 && cap(c.out) > 1 << 20 {
			delete(c.out)
			c.out = make([dynamic]u8, c.allocator)
		}
	} else if c.out_pos > 1 << 20 && c.out_pos > len(c.out) / 2 {
		rest := len(c.out) - c.out_pos
		copy(c.out[:rest], c.out[c.out_pos:])
		resize(&c.out, rest)
		c.out_pos = 0
	}
}

client_queued :: proc "contextless" (c: ^Client) -> int {
	return len(c.out) - c.out_pos + len(c.held)
}

@(private)
_client_buf :: proc(c: ^Client) -> ^[dynamic]u8 {
	return &c.held if c.streaming else &c.out
}

client_list :: proc(c: ^Client, since: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .List) or_return
	w := prim.writer(b)
	prim.write_u64le(&w, u64(since))
	return frame_end(b, start, &w)
}

client_read :: proc(c: ^Client, id: Stream_Id, from, to: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Read) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(from, 0)))
	prim.write_u64le(&w, u64(max(to, from, 0)))
	return frame_end(b, start, &w)
}

client_tail :: proc(c: ^Client, id: Stream_Id, n: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Tail) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(n, 0)))
	return frame_end(b, start, &w)
}

client_follow :: proc(c: ^Client, entries: []Follow_Entry, watch: bool) -> Error {
	rest := entries
	for {
		n := min(len(rest), FOLLOW_BATCH)
		b := _client_buf(c)
		start := frame_begin(b, .Follow) or_return
		w := prim.writer(b)
		prim.write_u8(&w, FOLLOW_WATCH if watch else 0)
		prim.write_u16le(&w, u16(n))
		for e in rest[:n] {
			put_id(&w, cast([32]u8)e.stream)
			prim.write_u64le(&w, e.offset)
		}
		frame_end(b, start, &w) or_return
		rest = rest[n:]
		if len(rest) == 0 {
			return .None
		}
	}
}

client_unfollow :: proc(c: ^Client, ids: []Stream_Id) -> Error {
	rest := ids
	for len(rest) > 0 {
		n := min(len(rest), FOLLOW_BATCH)
		b := _client_buf(c)
		start := frame_begin(b, .Unfollow) or_return
		w := prim.writer(b)
		prim.write_u16le(&w, u16(n))
		for id in rest[:n] {
			put_id(&w, cast([32]u8)id)
		}
		frame_end(b, start, &w) or_return
		rest = rest[n:]
	}
	return .None
}

client_get :: proc(c: ^Client, keys: []Object_Key) -> Error {
	rest := keys
	for len(rest) > 0 {
		n := min(len(rest), GET_BATCH)
		b := _client_buf(c)
		start := frame_begin(b, .Get) or_return
		w := prim.writer(b)
		prim.write_u16le(&w, u16(n))
		for k in rest[:n] {
			put_id(&w, cast([32]u8)k)
		}
		frame_end(b, start, &w) or_return
		rest = rest[n:]
	}
	return .None
}

client_redact :: proc(c: ^Client, id: Stream_Id, from, to: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Redact) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(from, 0)))
	prim.write_u64le(&w, u64(max(to, from, 0)))
	return frame_end(b, start, &w)
}

client_feed_follow :: proc(c: ^Client, from: u64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Feed) or_return
	w := prim.writer(b)
	prim.write_u64le(&w, from)
	return frame_end(b, start, &w)
}

client_drop :: proc(c: ^Client, id: Stream_Id) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Drop) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	return frame_end(b, start, &w)
}

client_append_reserve :: proc(c: ^Client, id: Stream_Id, at: i64, n: int) -> (dst: []u8, err: Error) {
	if n < 0 || n > APPEND_MAX {
		return nil, .Too_Large
	}
	b := _client_buf(c)
	start := len(b)
	if rerr := resize(b, start + FRAME_HEADER + APPEND_FIXED + n); rerr != nil {
		resize(b, start)
		return nil, .No_Memory
	}
	frame_header(b[start:], .Append, APPEND_FIXED + n)
	sid := id
	copy(b[start + FRAME_HEADER:], sid[:])
	prim.put_u64le(b[start + FRAME_HEADER + 32:], u64(at))
	return b[start + FRAME_HEADER + APPEND_FIXED:], .None
}

client_append_commit :: proc(c: ^Client, reserved: int, used: int) {
	b := _client_buf(c)
	start := len(b) - reserved - FRAME_HEADER - APPEND_FIXED
	if used <= 0 {
		resize(b, start)
		return
	}
	prim.put_u32le(b[start:start + 4], u32(APPEND_FIXED + used))
	resize(b, len(b) - (reserved - used))
}

client_put_begin :: proc(c: ^Client, key: Object_Key, total: i64) -> Error {
	if total < 0 || total > i64(OBJECT_MAX) || c.streaming {
		return .Too_Large if total > i64(OBJECT_MAX) else .Invalid
	}
	start := len(c.out)
	if rerr := resize(&c.out, start + FRAME_HEADER + PUT_FIXED); rerr != nil {
		resize(&c.out, start)
		return .No_Memory
	}
	frame_header(c.out[start:], .Put, PUT_FIXED + int(total))
	k := key
	copy(c.out[start + FRAME_HEADER:], k[:])
	c.streaming = true
	return .None
}

client_put_reserve :: proc(c: ^Client, n: int) -> (dst: []u8, err: Error) {
	if !c.streaming {
		return nil, .Invalid
	}
	start := len(c.out)
	if rerr := resize(&c.out, start + n); rerr != nil {
		resize(&c.out, start)
		return nil, .No_Memory
	}
	return c.out[start:], .None
}

client_put_end :: proc(c: ^Client) {
	c.streaming = false
	if len(c.held) > 0 {
		append(&c.out, ..c.held[:])
		clear(&c.held)
	}
}

client_streaming :: proc "contextless" (c: ^Client) -> bool {
	return c.streaming
}

listing_entry :: proc(ev: ^Event, i: int) -> (l: Listed) {
	e := ev.entries[i * 40:][:40]
	copy(l.stream[:], e[:32])
	v := prim.get_u64le(e[32:])
	l.length = i64(min(v, u64(max(i64))))
	return
}

listing_count :: proc "contextless" (ev: ^Event) -> int {
	return len(ev.entries) / 40
}

client_feed :: proc(c: ^Client, data: []u8, handler: Client_Handler, user: rawptr) -> Error {
	pos := 0
	for {
		it, used, err := parser_next(&c.parser, data[pos:])
		pos += used
		if err != .None {
			c.state = .Failed
			return err
		}
		if it.kind == .None {
			break
		}
		if e := _client_item(c, &it, handler, user); e != .None {
			c.state = .Failed
			return e
		}
		if c.state == .Idle {
			return .None
		}
	}
	parser_release(&c.parser)
	return .None
}

@(private)
_client_item :: proc(c: ^Client, it: ^Item, handler: Client_Handler, user: rawptr) -> Error {
	switch it.kind {
	case .None:
		return .None
	case .Bulk_Begin:
		r := prim.reader(it.data)
		ev := Event {
			first = true,
			total = i64(it.total),
		}
		ev.id = get_id32(&r)
		#partial switch it.frame {
		case .Data:
			ev.kind = .Data
			ev.at = get_i64(&r)
			ev.length = get_i64(&r)
		case .Object:
			ev.kind = .Object
		case:
			return .Protocol
		}
		if !prim.reader_done(&r) {
			return .Protocol
		}
		c.bulk = ev
		c.bulk.first = false
		return handler(user, &ev)
	case .Bulk_Data:
		ev := c.bulk
		ev.data = it.data
		c.bulk.at += i64(len(it.data))
		return handler(user, &ev)
	case .Bulk_End:
		ev := c.bulk
		ev.last = true
		c.bulk = {}
		return handler(user, &ev)
	case .Control:
		return _client_control(c, it, handler, user)
	}
	return .None
}

@(private)
_client_control :: proc(c: ^Client, it: ^Item, handler: Client_Handler, user: rawptr) -> Error {
	r := prim.reader(it.data)
	ev: Event
	#partial switch it.frame {
	case .Welcome:
		ev.kind = .Welcome
		if prim.read_u8(&r) != PROTOCOL_VERSION {
			return .Protocol
		}
		ev.time = get_i64(&r)
		ev.usage = get_i64(&r)
		ev.quota = get_i64(&r)
	case .Listing:
		ev.kind = .Listing
		ev.cursor = i64(prim.read_u64le(&r))
		ev.more = prim.read_bool(&r)
		n := int(prim.read_u16le(&r))
		ev.entries = prim.read_raw(&r, n * 40)
	case .Appended, .Conflict, .Created:
		ev.kind = .Appended if it.frame == .Appended else .Conflict if it.frame == .Conflict else .Created
		ev.id = get_id32(&r)
		ev.length = get_i64(&r)
	case .Stored, .Missing, .Dropped:
		ev.kind = .Stored if it.frame == .Stored else .Missing if it.frame == .Missing else .Dropped
		ev.id = get_id32(&r)
	case .Refused:
		ev.kind = .Refused
		ev.code = Code(prim.read_u8(&r))
		ev.id = get_id32(&r)
	case .Error:
		ev.kind = .Error
		ev.code = Code(prim.read_u8(&r))
	case .Announce:
		ev.kind = .Announce
		ev.at = get_i64(&r)
		ev.length = get_i64(&r)
		n := int(prim.read_u16le(&r))
		ev.entries = prim.read_raw(&r, n * FEED_ENTRY)
	case .Redacted:
		ev.kind = .Redacted
		ev.id = get_id32(&r)
		ev.at = get_i64(&r)
		ev.length = get_i64(&r)
	case .Length:
		n := int(prim.read_u16le(&r))
		if prim.reader_remaining(&r) != n * 40 {
			return .Protocol
		}
		for _ in 0 ..< n {
			e := Event {
				kind = .Length,
			}
			e.id = get_id32(&r)
			e.length = get_i64(&r)
			if !prim.reader_ok(&r) {
				return .Protocol
			}
			handler(user, &e) or_return
		}
		return .None
	case:
		return .Protocol
	}
	if !prim.reader_done(&r) {
		return .Protocol
	}
	return handler(user, &ev)
}

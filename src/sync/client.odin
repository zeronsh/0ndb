package osync

import "core:crypto/ecdh"
import "base:runtime"
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
	Forgotten,
	Probed,
	Presence,
	Direct,
	Undelivered,
	Noted,
	Hollow,
	Pulled,
	Served,
	Unserved,
	Accounted,
	Lived,
	Watched,
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
	final:   bool,
	code:    Code,
	time:    i64,
	usage:   i64,
	quota:   i64,
	cursor:  i64,
	more:    bool,
	entries: []u8,
	device:  Device_Id,
	tag:     u64,
	base:    i64,
	trimmed: bool,
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
	frame_at:  int,
	held:      [dynamic]u8,
	streaming: bool,
	parser:    Parser,
	bulk:      Event,
	awaiting:  map[[32]u8]_Await,
	await_n:   int,
	epoch:     u64,
	sent_mark: u64,
	feed_on:   bool,
	put_key:   [32]u8,
	allocator: runtime.Allocator,
}

@(private)
_Await :: struct {
	count: int,
	mark:  u64,
}

@(private)
AWAIT_HELLO :: [32]u8{0 = 0xff, 1 = 0xfe}

client_init :: proc(c: ^Client, allocator := context.allocator) {
	c^ = {
		allocator = allocator,
	}
	c.out = make([dynamic]u8, allocator)
	c.held = make([dynamic]u8, allocator)
	c.awaiting = make(map[[32]u8]_Await, allocator)
	parser_init(&c.parser, false, allocator)
}

client_destroy :: proc(c: ^Client) {
	client_reset(c)
	delete(c.out)
	delete(c.held)
	delete(c.awaiting)
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
	c.frame_at = 0
	c.streaming = false
	c.hs_have = 0
	c.state = .Idle
	clear(&c.awaiting)
	c.await_n = 0
	c.feed_on = false
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

client_begin :: proc(c: ^Client, static: ^ecdh.Private_Key, relay_public: Public_Key, out: []u8, random := prim.Random{}) -> (n: int, err: Error) {
	client_reset(c)
	c.unix = false
	if len(out) < 2 + MSG1_LEN {
		return 0, .Invalid
	}
	m := handshake_initiate(&c.hs, static, relay_public, out[2:], random) or_return
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
	_await_add(c, AWAIT_HELLO)
	return .None
}

client_binding :: proc(c: ^Client) -> []u8 {
	return c.binding[:c.bind_len]
}

client_hello_finish :: proc(c: ^Client, credential: []u8) -> Error {
	if c.state != .Hello {
		return .Protocol
	}
	if len(credential) > CREDENTIAL_MAX {
		return .Too_Large
	}
	start := frame_begin(&c.out, .Hello) or_return
	w := prim.writer(&c.out)
	prim.write_u8(&w, PROTOCOL_VERSION)
	prim.write_raw(&w, credential)
	if w.err != .None {
		resize(&c.out, start)
		return .No_Memory
	}
	session_keys_clear(&c.keys)
	frame_end(&c.out, start, &w) or_return
	c.state = .Ready
	_await_add(c, AWAIT_HELLO)
	return .None
}

client_awaiting :: proc "contextless" (c: ^Client) -> int {
	return c.await_n
}

client_deadline_tick :: proc(c: ^Client) -> (stalled: bool) {
	moving := client_queued(c) > 0 && c.sent_mark + 1 >= c.epoch
	if !moving {
		for _, a in c.awaiting {
			if a.count > 0 && a.mark + 1 < c.epoch {
				stalled = true
				break
			}
		}
	}
	c.epoch += 1
	return
}

@(private)
_await_add :: proc(c: ^Client, id: [32]u8, n := 1) {
	a := c.awaiting[id]
	a.count += n
	a.mark = c.epoch
	c.awaiting[id] = a
	c.await_n += n
}

@(private)
_await_done :: proc(c: ^Client, id: [32]u8) {
	a, ok := c.awaiting[id]
	if !ok {
		return
	}
	a.count -= 1
	c.await_n -= 1
	if a.count <= 0 {
		delete_key(&c.awaiting, id)
		return
	}
	a.mark = c.epoch
	c.awaiting[id] = a
}

@(private)
_await_progress :: proc(c: ^Client, id: [32]u8) {
	if a, ok := &c.awaiting[id]; ok {
		a.mark = c.epoch
	}
}

client_pending :: proc "contextless" (c: ^Client) -> []u8 {
	return c.out[c.out_pos:]
}

client_consumed :: proc(c: ^Client, n: int) {
	if n > 0 {
		c.sent_mark = c.epoch
	}
	c.out_pos += n
	for c.frame_at + FRAME_HEADER <= len(c.out) {
		size := FRAME_HEADER + int(prim.get_u32le(c.out[c.frame_at:]))
		if c.frame_at + size > c.out_pos {
			break
		}
		c.frame_at += size
	}
	if c.out_pos >= len(c.out) {
		clear(&c.out)
		c.out_pos = 0
		c.frame_at = 0
		if !c.streaming && len(c.held) > 0 {
			append(&c.out, ..c.held[:])
			clear(&c.held)
		}
		if len(c.out) == 0 && cap(c.out) > 1 << 20 {
			delete(c.out)
			c.out = make([dynamic]u8, c.allocator)
		}
	} else if c.frame_at > 1 << 20 && c.frame_at > len(c.out) / 2 {
		rest := len(c.out) - c.frame_at
		copy(c.out[:rest], c.out[c.frame_at:])
		resize(&c.out, rest)
		c.out_pos -= c.frame_at
		c.frame_at = 0
	}
}

client_cancel_appends :: proc(c: ^Client, id: Stream_Id) -> (removed: int) {
	start := c.frame_at
	if start < c.out_pos && start + FRAME_HEADER <= len(c.out) {
		start += FRAME_HEADER + int(prim.get_u32le(c.out[start:]))
	}
	removed += _cancel_frames(&c.out, start, cast([32]u8)id)
	removed += _cancel_frames(&c.held, 0, cast([32]u8)id)
	for _ in 0 ..< removed {
		_await_done(c, cast([32]u8)id)
	}
	return
}

@(private)
_cancel_frames :: proc(buf: ^[dynamic]u8, from: int, id: [32]u8) -> (removed: int) {
	key := id
	pos := from
	for pos + FRAME_HEADER <= len(buf) {
		size := FRAME_HEADER + int(prim.get_u32le(buf[pos:]))
		if pos + size > len(buf) {
			break
		}
		if Kind(buf[pos + 4]) == .Append && size >= FRAME_HEADER + 32 && string(buf[pos + FRAME_HEADER:][:32]) == string(key[:]) {
			rest := len(buf) - pos - size
			copy(buf[pos:], buf[pos + size:])
			resize(buf, pos + rest)
			removed += 1
			continue
		}
		pos += size
	}
	return
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
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)reserved_id(LIST_TAG, 0))
	return .None
}

client_read :: proc(c: ^Client, id: Stream_Id, from, to: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Read) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(from, 0)))
	prim.write_u64le(&w, u64(max(to, from, 0)))
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)id)
	return .None
}

client_tail :: proc(c: ^Client, id: Stream_Id, n: i64) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Tail) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	prim.write_u64le(&w, u64(max(n, 0)))
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)id)
	return .None
}

client_probe :: proc(c: ^Client, ids: []Stream_Id) -> Error {
	rest := ids
	for len(rest) > 0 {
		n := min(len(rest), FOLLOW_BATCH)
		b := _client_buf(c)
		start := frame_begin(b, .Probe) or_return
		w := prim.writer(b)
		prim.write_u16le(&w, u16(n))
		for id in rest[:n] {
			put_id(&w, cast([32]u8)id)
		}
		frame_end(b, start, &w) or_return
		for id in rest[:n] {
			_await_add(c, cast([32]u8)id)
		}
		rest = rest[n:]
	}
	return .None
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
		for e in rest[:n] {
			_await_add(c, cast([32]u8)e.stream)
		}
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
		for k in rest[:n] {
			_await_add(c, cast([32]u8)k)
		}
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
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)id)
	return .None
}

client_feed_follow :: proc(c: ^Client, from: u64, patterns: []Feed_Pattern = nil, filtered := false, additive := false, presence := false) -> Error {
	if len(patterns) > FEED_PATTERNS_MAX {
		return .Too_Large
	}
	rest := patterns
	first := true
	for first || len(rest) > 0 {
		n := min(len(rest), FEED_PATTERNS_FRAME)
		b := _client_buf(c)
		start := frame_begin(b, .Feed) or_return
		w := prim.writer(b)
		prim.write_u64le(&w, from)
		if filtered || len(patterns) > 0 {
			prim.write_u8(&w, FEED_FILTERED | (FEED_ADD if additive || !first else 0) | (FEED_PRESENCE if presence else 0))
			prim.write_u16le(&w, u16(n))
			for p in rest[:n] {
				prim.write_u8(&w, u8(p.kind))
				k := p.bytes
				prim.write_raw(&w, k[:32] if p.kind == .Exact else k[:16])
			}
		} else if presence {
			prim.write_u8(&w, FEED_PRESENCE)
		}
		frame_end(b, start, &w) or_return
		if !((additive || !first) && c.feed_on) {
			_await_add(c, cast([32]u8)reserved_id(FEED_TAG, 0))
		}
		c.feed_on = true
		rest = rest[n:]
		first = false
	}
	return .None
}

client_forget :: proc(c: ^Client, keys: []Object_Key) -> Error {
	rest := keys
	for len(rest) > 0 {
		n := min(len(rest), GET_BATCH)
		b := _client_buf(c)
		start := frame_begin(b, .Forget) or_return
		w := prim.writer(b)
		prim.write_u16le(&w, u16(n))
		for k in rest[:n] {
			put_id(&w, cast([32]u8)k)
		}
		frame_end(b, start, &w) or_return
		for k in rest[:n] {
			_await_add(c, cast([32]u8)k)
		}
		rest = rest[n:]
	}
	return .None
}

client_account :: proc(c: ^Client) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Account) or_return
	w := prim.writer(b)
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)reserved_id(ACCOUNT_TAG, 0))
	return .None
}

client_drop :: proc(c: ^Client, id: Stream_Id) -> Error {
	b := _client_buf(c)
	start := frame_begin(b, .Drop) or_return
	w := prim.writer(b)
	put_id(&w, cast([32]u8)id)
	frame_end(b, start, &w) or_return
	_await_add(c, cast([32]u8)id)
	return .None
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
	id: [32]u8
	copy(id[:], b[start + FRAME_HEADER:][:32])
	resize(b, len(b) - (reserved - used))
	_await_add(c, id)
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
	c.put_key = cast([32]u8)key
	_await_add(c, c.put_key)
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
	_await_progress(c, c.put_key)
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
		if it.frame != .Served {
			ev.id = get_id32(&r)
		}
		if it.frame == .Lived {
			ev.kind = .Lived
			ev.tag = prim.read_u64le(&r)
			ev.at = get_i64(&r)
			if !prim.reader_done(&r) {
				return .Protocol
			}
			c.bulk = ev
			c.bulk.first = false
			return handler(user, &ev)
		}
		#partial switch it.frame {
		case .Data:
			ev.kind = .Data
			ev.at = get_i64(&r)
			raw := prim.read_u64le(&r)
			ev.final = raw & DATA_FINAL != 0
			ev.length = i64(raw & ~DATA_FINAL)
		case .Object:
			ev.kind = .Object
		case .Served:
			ev.kind = .Served
			prim.read_fixed(&r, ev.device[:])
			ev.tag = prim.read_u64le(&r)
			ev.id = get_id32(&r)
			ev.at = get_i64(&r)
			raw := prim.read_u64le(&r)
			ev.final = raw & SERVE_FINAL != 0
			ev.length = i64(raw & SERVE_LEN_MASK)
		case:
			return .Protocol
		}
		if !prim.reader_done(&r) {
			return .Protocol
		}
		c.bulk = ev
		c.bulk.first = false
		if ev.kind != .Served {
			_await_progress(c, ev.id)
		}
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
		if ev.kind == .Served || ev.kind == .Lived {
			return handler(user, &ev)
		}
		if ev.kind == .Object || ev.final {
			_await_done(c, ev.id)
		} else {
			_await_progress(c, ev.id)
		}
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
		_await_done(c, AWAIT_HELLO)
		ev.time = get_i64(&r)
		ev.usage = get_i64(&r)
		ev.quota = get_i64(&r)
		if prim.reader_remaining(&r) >= 8 {
			ev.tag = prim.read_u64le(&r)
		}
	case .Listing:
		ev.kind = .Listing
		ev.cursor = i64(prim.read_u64le(&r))
		ev.more = prim.read_bool(&r)
		n := int(prim.read_u16le(&r))
		ev.entries = prim.read_raw(&r, n * 40)
		if ev.more {
			_await_progress(c, cast([32]u8)reserved_id(LIST_TAG, 0))
		} else {
			_await_done(c, cast([32]u8)reserved_id(LIST_TAG, 0))
		}
	case .Appended, .Conflict, .Created:
		ev.kind = .Appended if it.frame == .Appended else .Conflict if it.frame == .Conflict else .Created
		ev.id = get_id32(&r)
		ev.length = get_i64(&r)
		if it.frame != .Created {
			_await_done(c, ev.id)
		}
	case .Stored, .Missing, .Dropped, .Forgotten:
		ev.kind = .Stored if it.frame == .Stored else .Missing if it.frame == .Missing else .Dropped if it.frame == .Dropped else .Forgotten
		ev.id = get_id32(&r)
		_await_done(c, ev.id)
	case .Refused:
		ev.kind = .Refused
		ev.code = Code(prim.read_u8(&r))
		ev.id = get_id32(&r)
		_await_done(c, ev.id)
	case .Error:
		ev.kind = .Error
		ev.code = Code(prim.read_u8(&r))
	case .Announce:
		ev.kind = .Announce
		ev.at = get_i64(&r)
		ev.length = get_i64(&r)
		_await_done(c, cast([32]u8)reserved_id(FEED_TAG, 0))
		n := int(prim.read_u16le(&r))
		ev.entries = prim.read_raw(&r, n * FEED_ENTRY)
	case .Redacted:
		ev.kind = .Redacted
		ev.id = get_id32(&r)
		_await_done(c, ev.id)
		ev.at = get_i64(&r)
		ev.length = get_i64(&r)
	case .Directed, .Undelivered:
		return _client_direct_event(it, handler, user)
	case .Watched:
		ev.kind = .Watched
		ev.id = get_id32(&r)
		ev.final = prim.read_u8(&r) != 0
	case .Noted, .Hollow, .Trimmed:
		ev.kind = .Noted if it.frame == .Noted else .Hollow
		ev.trimmed = it.frame == .Trimmed
		ev.id = get_id32(&r)
		ev.base = get_i64(&r)
		ev.length = get_i64(&r)
		if it.frame == .Noted {
			_await_done(c, ev.id)
		}
	case .Pulled:
		ev.kind = .Pulled
		prim.read_fixed(&r, ev.device[:])
		ev.tag = prim.read_u64le(&r)
		ev.id = get_id32(&r)
		from := prim.read_u64le(&r)
		if from & PULL_DRAFT == 0 && from > u64(max(i64)) {
			return .Protocol
		}
		ev.at = cast(i64)from
		ev.length = get_i64(&r)
	case .Accounted:
		ev.kind = .Accounted
		if len(it.data) < ACCOUNTED_LEN {
			return .Protocol
		}
		ev.data = it.data
		_await_done(c, cast([32]u8)reserved_id(ACCOUNT_TAG, 0))
	case .Unserved:
		ev.kind = .Unserved
		prim.read_fixed(&r, ev.device[:])
		ev.tag = prim.read_u64le(&r)
		ev.id = get_id32(&r)
	case .Presence:
		flags := prim.read_u8(&r)
		n := int(prim.read_u16le(&r))
		if !prim.reader_ok(&r) || prim.reader_remaining(&r) != n * PRESENCE_ENTRY {
			return .Protocol
		}
		snapshot := flags & PRESENCE_SNAPSHOT != 0
		if snapshot {
			e := Event{kind = .Presence, first = true, at = -1}
			handler(user, &e) or_return
		}
		for _ in 0 ..< n {
			e := Event{kind = .Presence}
			prim.read_fixed(&r, e.id[:16])
			e.at = i64(prim.read_u8(&r))
			e.length = get_i64(&r)
			handler(user, &e) or_return
		}
		if snapshot {
			e := Event{kind = .Presence, last = true, at = -1}
			handler(user, &e) or_return
		}
		return .None
	case .Length, .Probed:
		n := int(prim.read_u16le(&r))
		if prim.reader_remaining(&r) != n * 40 {
			return .Protocol
		}
		for _ in 0 ..< n {
			e := Event {
				kind = .Length if it.frame == .Length else .Probed,
			}
			e.id = get_id32(&r)
			e.length = get_i64(&r)
			if !prim.reader_ok(&r) {
				return .Protocol
			}
			_await_done(c, e.id)
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

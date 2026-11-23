package osync

import "../prim"

Pipe :: struct {
	requester: Conn_Ref,
	holder:    Conn_Ref,
	from:      Device_Id,
	tag:       u64,
	id:        Stream_Id,
}

@(private)
_reply_hollow :: proc(c: ^Conn, k: Kind, id: [32]u8, base, length: i64) {
	b: [FRAME_HEADER + NOTED_LEN]u8
	frame_header(b[:], k, NOTED_LEN)
	v := id
	copy(b[FRAME_HEADER:], v[:])
	prim.put_u64le(b[FRAME_HEADER + 32:], u64(max(base, 0)))
	prim.put_u64le(b[FRAME_HEADER + 40:], u64(max(length, 0)))
	_push_small(c, b[:])
}

@(private)
_on_note :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	length := get_i64(rd)
	if !prim.reader_done(rd) || length < 0 || length > REDACT_LIMIT {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .Append, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	sp := c.space
	st, err := _stream_get(r, sp, id, true)
	if err != .None {
		_reply_refused(c, .Io, cast([32]u8)id)
		return
	}
	if st.busy {
		_reply_refused(c, .Busy, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	if st.dropped || st.base != st.length || length <= st.length {
		_reply_hollow(c, .Noted, cast([32]u8)id, st.base, _live_len(st))
		_stream_maybe_release(r, st)
		return
	}
	p := _pending_new(c, .Note, st, 0, cast([32]u8)id)
	if p == nil {
		_reply_refused(c, .Io, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	p.length = length
	st.busy = true
	r.store.note(r.store.data, st.h, length, _relay_done, p)
}

@(private)
_on_fill_begin :: proc(c: ^Conn, rd: ^prim.Reader, total: i64) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	at_raw := prim.read_u64le(rd)
	c.op = Op {
		kind  = .Discard,
		id    = cast([32]u8)id,
		total = total,
	}
	if !prim.reader_ok(rd) || at_raw > u64(max(i64)) {
		_fail(c, .Protocol)
		return
	}
	at := i64(at_raw)
	sp := c.space
	if !_can(c, .Fill, cast([32]u8)id) {
		c.op.reply, c.op.code = .Refused, .Not_Owner
		return
	}
	if sp.quota > 0 && sp.usage + sp.reserved + total > sp.quota {
		c.op.reply, c.op.code = .Refused, .Quota
		return
	}
	st, err := _stream_get(r, sp, id, false)
	if err != .None {
		c.op.reply, c.op.code = .Refused, .Io
		return
	}
	if st.h == nil || st.dropped {
		c.op.reply, c.op.code = .Refused, .Not_Found
		_stream_maybe_release(r, st)
		return
	}
	if st.busy {
		c.op.reply, c.op.code = .Refused, .Busy
		_stream_maybe_release(r, st)
		return
	}
	if total <= 0 || at + total != st.base || st.trimmed {
		c.op.reply, c.op.len = .Noted, _live_len(st)
		c.op.base = st.base
		_stream_maybe_release(r, st)
		return
	}
	redact := _red_overlaps(r, sp, id, at, at + total)
	if redact && total > FILL_REDACT_MAX {
		c.op.reply, c.op.code = .Refused, .Too_Large
		_stream_maybe_release(r, st)
		return
	}
	w, werr := r.store.fill_begin(r.store.data, st.h, at, total)
	if werr != .None {
		c.op.reply, c.op.len = .Noted, _live_len(st)
		c.op.base = st.base
		if werr != .Conflict {
			c.op.reply, c.op.code = .Refused, .Io
		}
		_stream_maybe_release(r, st)
		return
	}
	sp.reserved += total
	st.busy = true
	_stream_ref(st)
	c.op.kind = .Fill
	c.op.stream = st
	c.op.w = w
	c.op.at = at
	if redact {
		c.op.buf = make([]u8, int(total), r.allocator)
	}
}

@(private)
_fill_end :: proc(c: ^Conn, op: ^Op) {
	r := c.relay
	st := op.stream
	if op.buf != nil {
		ok := op.pos == len(op.buf) && _red_fill_apply(c.space, Stream_Id(op.id), op.at, op.buf)
		r.stats.redacted_in += 1
		if !ok {
			r.stats.refused_in += 1
		}
		if ok && op.failed == .None {
			op.failed = r.store.append_write(r.store.data, op.w, op.buf)
		}
		delete(op.buf, r.allocator)
		op.buf = nil
		if !ok {
			r.store.append_abort(r.store.data, op.w)
			c.space.reserved -= op.total
			st.busy = false
			_stream_unref(r, st)
			_reply_refused(c, .Protocol, op.id)
			_stream_maybe_release(r, st)
			return
		}
	}
	p := _pending_new(c, .Fill, st, op.total, op.id)
	_stream_unref(r, st)
	if p == nil {
		r.store.append_abort(r.store.data, op.w)
		c.space.reserved -= op.total
		st.busy = false
		st.poisoned = true
		_reply_refused(c, .Io, op.id)
		_stream_maybe_release(r, st)
		return
	}
	r.store.append_commit(r.store.data, op.w, _relay_done, p)
}

@(private)
_hollow_done :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn, p: ^Pending, result: Error, value: i64) -> (handed: bool) {
	st := p.stream
	st.busy = false
	if p.kind == .Fill {
		sp.reserved -= p.total
	}
	if result != .None {
		st.poisoned = true
		if c != nil {
			if result == .Conflict {
				_reply_hollow(c, .Noted, p.id, st.base, _live_len(st))
			} else {
				_reply_refused(c, .Quota if result == .No_Space else .Io, p.id)
			}
		}
		return false
	}
	st.length = value
	st.base = r.store.stream_base(r.store.data, st.h)
	p.from = st.base
	p.length = st.length
	if p.kind == .Fill {
		sp.usage += p.total
		r.stats.fills += 1
		sp.count.fills += 1
		sp.count.bytes_in += u64(p.total)
		if c != nil {
			_reply_hollow(c, .Noted, p.id, st.base, st.length)
		}
		return false
	}
	r.stats.notes += 1
	sp.count.notes += 1
	for f in st.followers {
		if f != c {
			_reply_hollow(f, .Hollow, p.id, st.base, st.length)
			_conn_kick(f)
		}
	}
	_feed_wait(r, sp, p, u64(st.length) | FEED_HOLLOW)
	return true
}

@(private)
_reply_unserved :: proc(c: ^Conn, holder: Device_Id, tag: u64, id: Stream_Id) {
	b: [FRAME_HEADER + UNSERVED_LEN]u8
	frame_header(b[:], .Unserved, UNSERVED_LEN)
	h := holder
	copy(b[FRAME_HEADER:], h[:])
	prim.put_u64le(b[FRAME_HEADER + 16:], tag)
	v := id
	copy(b[FRAME_HEADER + 24:], v[:])
	_push_small(c, b[:])
	_conn_kick(c)
}

@(private)
_holder_conn :: proc(sp: ^Space_State, d: Device_Id, not: ^Conn) -> ^Conn {
	for f in sp.live {
		if f != not && !f.dead && !f.closing && f.state == .Ready && f.principal.participant == d {
			return f
		}
	}
	return nil
}

@(private)
_on_pull :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	holder: Device_Id
	prim.read_fixed(rd, holder[:])
	tag := prim.read_u64le(rd)
	id := Stream_Id(get_id32(rd))
	from := prim.read_u64le(rd)
	to := prim.read_u64le(rd)
	draft := from & PULL_DRAFT != 0
	if !prim.reader_done(rd) || (draft && (from &~ PULL_DRAFT >= DRAFT_MSG_MAX || to >= DRAFT_MSG_MAX)) || (!draft && (from > u64(max(i64)) || to > u64(max(i64)) || to < from)) {
		_fail(c, .Protocol)
		return
	}
	sp := c.space
	if !_can(c, .Read, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	n := 0
	for pp in sp.pipes {
		if pp.requester == c.ref {
			n += 1
		}
	}
	h := _holder_conn(sp, holder, c)
	if h == nil || n >= PIPES_MAX || holder == c.principal.participant {
		_reply_unserved(c, holder, tag, id)
		return
	}
	for &pp in sp.pipes {
		if pp.requester == c.ref && pp.tag == tag {
			_reply_unserved(c, holder, tag, id)
			return
		}
	}
	if _, e := append(&sp.pipes, Pipe{requester = c.ref, holder = h.ref, from = c.principal.participant, tag = tag, id = id}); e != nil {
		_conn_close(c)
		return
	}
	b: [FRAME_HEADER + PULL_LEN]u8
	frame_header(b[:], .Pulled, PULL_LEN)
	me := c.principal.participant
	copy(b[FRAME_HEADER:], me[:])
	prim.put_u64le(b[FRAME_HEADER + 16:], tag)
	v := id
	copy(b[FRAME_HEADER + 24:], v[:])
	prim.put_u64le(b[FRAME_HEADER + 56:], from)
	prim.put_u64le(b[FRAME_HEADER + 64:], to)
	_push_small(h, b[:])
	_conn_kick(h)
	r.stats.pulls += 1
	sp.count.pulls += 1
}

@(private)
_pipe_find :: proc(sp: ^Space_State, holder: ^Conn, requester: Device_Id, tag: u64, id: Stream_Id) -> int {
	for pp, i in sp.pipes {
		if pp.holder == holder.ref && pp.from == requester && pp.tag == tag && pp.id == id {
			return i
		}
	}
	return -1
}

@(private)
_on_serve_begin :: proc(c: ^Conn, rd: ^prim.Reader, total: i64) {
	r := c.relay
	requester: Device_Id
	prim.read_fixed(rd, requester[:])
	tag := prim.read_u64le(rd)
	id := Stream_Id(get_id32(rd))
	at := prim.read_u64le(rd)
	word := prim.read_u64le(rd)
	c.op = Op{kind = .Discard, total = total}
	if !prim.reader_ok(rd) || at > u64(max(i64)) || (word & SERVE_NONE != 0 && total != 0) {
		_fail(c, .Protocol)
		return
	}
	sp := c.space
	i := _pipe_find(sp, c, requester, tag, id)
	if i < 0 {
		return
	}
	buf, aerr := make([]u8, FRAME_HEADER + SERVE_FIXED + int(total), r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	frame_header(buf, .Served, SERVE_FIXED + int(total))
	me := c.principal.participant
	copy(buf[FRAME_HEADER:], me[:])
	prim.put_u64le(buf[FRAME_HEADER + 16:], tag)
	v := id
	copy(buf[FRAME_HEADER + 24:], v[:])
	prim.put_u64le(buf[FRAME_HEADER + 56:], at)
	prim.put_u64le(buf[FRAME_HEADER + 64:], word)
	c.op.kind = .Serve
	c.op.buf = buf
	c.op.pos = FRAME_HEADER + SERVE_FIXED
	c.op.pipe = sp.pipes[i]
	c.op.len = i64(word)
}

@(private)
_serve_end :: proc(c: ^Conn, op: ^Op) {
	r := c.relay
	sp := c.space
	buf := op.buf
	word := u64(op.len)
	i := _pipe_find(sp, c, op.pipe.from, op.pipe.tag, op.pipe.id)
	q := _conn_lookup(r, op.pipe.requester)
	if i < 0 || q == nil || op.pos != len(buf) {
		delete(buf, r.allocator)
		if i >= 0 && q == nil {
			unordered_remove(&sp.pipes, i)
		}
		return
	}
	if word & (SERVE_FINAL | SERVE_NONE) != 0 {
		unordered_remove(&sp.pipes, i)
	}
	if word & SERVE_NONE != 0 {
		delete(buf, r.allocator)
		_reply_unserved(q, c.principal.participant, op.pipe.tag, op.pipe.id)
		return
	}
	data := buf[FRAME_HEADER + SERVE_FIXED:]
	at := i64(prim.get_u64le(buf[FRAME_HEADER + 56:]))
	if len(data) > 0 && _red_overlaps(r, sp, op.pipe.id, at, at + i64(len(data))) {
		r.stats.redacted_in += 1
	}
	if len(data) > 0 && _red_overlaps(r, sp, op.pipe.id, at, at + i64(len(data))) && !_red_fill_apply(sp, op.pipe.id, at, data) {
		r.stats.refused_in += 1
		delete(buf, r.allocator)
		if word & SERVE_FINAL == 0 {
			if j := _pipe_find(sp, c, op.pipe.from, op.pipe.tag, op.pipe.id); j >= 0 {
				unordered_remove(&sp.pipes, j)
			}
		}
		_reply_unserved(q, c.principal.participant, op.pipe.tag, op.pipe.id)
		return
	}
	o: Out
	o.kind = .Bytes
	o.buf = buf
	o.piped = true
	if !_push(q, o) {
		delete(buf, r.allocator)
		return
	}
	q.piped += i64(len(buf))
	r.stats.served += 1
	r.stats.piped_bytes += u64(len(buf))
	sp.count.piped_bytes += u64(len(buf))
	_conn_kick(q)
	if q.piped >= PIPE_HIGH && !q.dead {
		c.pipe_wait = true
		c.pipe_on = q.ref
	}
}

@(private)
_pipe_drained :: proc(c: ^Conn, n: int) {
	c.piped = max(c.piped - i64(n), 0)
	if c.piped >= PIPE_HIGH || c.space == nil {
		return
	}
	_pipe_release_holders(c.relay, c.space, c)
}

@(private)
_pipe_release_holders :: proc(r: ^Relay_Core, sp: ^Space_State, q: ^Conn) {
	for h in sp.live {
		if h.pipe_wait && h.pipe_on == q.ref && !h.dead {
			h.pipe_wait = false
			_conn_kick(h)
		}
	}
}

@(private)
_pipes_conn_closed :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn) {
	if c.pipe_wait {
		c.pipe_wait = false
	}
	_pipe_release_holders(r, sp, c)
	for i := 0; i < len(sp.pipes); {
		pp := sp.pipes[i]
		if pp.requester == c.ref {
			unordered_remove(&sp.pipes, i)
			continue
		}
		if pp.holder == c.ref {
			if q := _conn_lookup(r, pp.requester); q != nil {
				_reply_unserved(q, c.principal.participant, pp.tag, pp.id)
			}
			unordered_remove(&sp.pipes, i)
			continue
		}
		i += 1
	}
}

@(private)
_store_trimmed :: proc(r: ^Relay_Core, h: rawptr) -> bool {
	return h != nil && r.store.stream_trimmed != nil && r.store.stream_trimmed(r.store.data, h)
}

@(private)
_base_kind :: proc "contextless" (st: ^Stream_State) -> Kind {
	return .Trimmed if st.trimmed else .Hollow
}

@(private)
_on_trim :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	base := get_i64(rd)
	if !prim.reader_done(rd) || base < 0 || base > REDACT_LIMIT {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .Append, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	if r.store.trim == nil {
		_fail(c, .Protocol)
		return
	}
	st, err := _stream_get(r, c.space, id, false)
	if err != .None {
		_reply_refused(c, .Io, cast([32]u8)id)
		return
	}
	if st.h == nil || st.dropped {
		_reply_refused(c, .Not_Found, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	if st.busy {
		_reply_refused(c, .Busy, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	if base >= st.length && base > st.base {
		_reply_refused(c, .Protocol, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	if base < st.base || (base == st.base && (st.trimmed || base == 0)) {
		_reply_hollow(c, .Noted, cast([32]u8)id, st.base, _live_len(st))
		_stream_maybe_release(r, st)
		return
	}
	p := _pending_new(c, .Trim, st, 0, cast([32]u8)id)
	if p == nil {
		_reply_refused(c, .Io, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	p.from = base
	st.busy = true
	r.store.trim(r.store.data, st.h, base, _relay_done, p)
}

@(private)
_trim_done :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn, p: ^Pending, result: Error, value: i64) {
	st := p.stream
	st.busy = false
	if result != .None {
		st.poisoned = true
		if c != nil {
			_reply_refused(c, .Io, p.id)
		}
		return
	}
	sp.usage = max(sp.usage - value, 0)
	st.base = r.store.stream_base(r.store.data, st.h)
	flipped := !st.trimmed
	st.trimmed = true
	r.stats.trims += 1
	r.stats.trimmed += u64(max(value, 0))
	if c != nil {
		_reply_hollow(c, .Noted, p.id, st.base, st.length)
	}
	for f in st.followers {
		for &sub in f.subs {
			if sub.stream == st && (sub.offset < st.base || flipped) {
				sub.offset = max(sub.offset, st.base)
				if f != c {
					_reply_hollow(f, .Trimmed, p.id, st.base, st.length)
				}
				_conn_kick(f)
			}
		}
	}
}

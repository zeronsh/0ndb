package osync

import "../prim"

FEED_COMPACT_DEFAULT :: 64 * 1024 * 1024

Listing :: struct {
	pos:    i64,
	end:    i64,
	cursor: i64,
}

reserved_id :: proc "contextless" (tag: u8, epoch: u64) -> (id: Stream_Id) {
	for i in 0 ..< 16 {
		id[i] = 0xff
	}
	id[16] = tag
	prim.put_u64le(id[24:], epoch)
	return
}

@(private)
_reserved :: proc "contextless" (id: [32]u8) -> bool {
	for i in 0 ..< 16 {
		if id[i] != 0xff {
			return false
		}
	}
	return true
}

@(private)
_owned_streams :: proc "contextless" (sp: ^Space_State) -> int {
	n := 0
	if sp.feed != nil {
		n += 1
	}
	if sp.meta != nil {
		n += 1
	}
	return n
}

@(private)
_pin :: proc(r: ^Relay, sp: ^Space_State, id: Stream_Id) -> (st: ^Stream_State, err: Error) {
	st = _stream_get(r, sp, id, true) or_return
	st.refs += 1
	return st, .None
}

@(private)
_feed_open :: proc(r: ^Relay, sp: ^Space_State) -> Error {
	if sp.feed_ready {
		if sp.feed.poisoned && !sp.feed.busy {
			_stream_get(r, sp, sp.feed.id, true) or_return
			sp.feed_len = sp.feed.length
		}
		return .None
	}
	meta := _pin(r, sp, reserved_id(FEED_META_TAG, 0)) or_return
	sp.meta = meta
	if meta.length >= 16 {
		b: [16]u8
		got, err := r.store.stream_read(r.store.data, meta.h, meta.length - 16, b[:])
		if err != .None || got != 16 {
			return .Corrupt
		}
		sp.feed_epoch = prim.get_u64le(b[0:8])
		sp.feed_base = i64(prim.get_u64le(b[8:16]))
	}
	feed := _pin(r, sp, reserved_id(FEED_TAG, sp.feed_epoch)) or_return
	sp.feed = feed
	sp.feed_len = feed.length
	sp.feed_ready = true
	return .None
}

@(private)
_feed_end :: proc "contextless" (sp: ^Space_State) -> i64 {
	return sp.feed_base + sp.feed_len
}

@(private)
_feed_add :: proc(r: ^Relay, sp: ^Space_State, id: [32]u8, length: u64) -> i64 {
	e: [FEED_ENTRY]u8
	v := id
	copy(e[:32], v[:])
	prim.put_u64le(e[32:], length)
	append(&sp.feed_q, ..e[:])
	need := _feed_end(sp) + i64(len(sp.feed_flight) + len(sp.feed_q))
	_feed_flush(r, sp)
	return need
}

@(private)
_feed_wait :: proc(r: ^Relay, sp: ^Space_State, p: ^Pending, length: u64) {
	p.need = _feed_add(r, sp, p.id, length)
	append(&sp.feed_wait, p)
	_feed_release(r, sp)
}

@(private)
_feed_flush :: proc(r: ^Relay, sp: ^Space_State) {
	if sp.feed_busy || sp.compacting || len(sp.feed_q) == 0 && len(sp.feed_flight) == 0 {
		return
	}
	if _feed_open(r, sp) != .None {
		return
	}
	if len(sp.feed_flight) == 0 {
		sp.feed_flight, sp.feed_q = sp.feed_q, sp.feed_flight
	}
	st := sp.feed
	w, err := r.store.append_begin(r.store.data, st.h, st.length, i64(len(sp.feed_flight)))
	if err == .None {
		err = r.store.append_write(r.store.data, w, sp.feed_flight[:])
		if err != .None {
			r.store.append_abort(r.store.data, w)
		}
	}
	if err != .None {
		st.poisoned = true
		return
	}
	p, aerr := new(Pending, r.allocator)
	if aerr != nil {
		r.store.append_abort(r.store.data, w)
		return
	}
	p^ = {
		relay = r,
		kind  = .Feed,
		space = sp,
	}
	sp.jobs += 1
	sp.feed_busy = true
	st.busy = true
	r.store.append_commit(r.store.data, w, _relay_done, p)
}

@(private)
_feed_done :: proc(r: ^Relay, sp: ^Space_State, kind: Pending_Kind, result: Error, value: i64) {
	#partial switch kind {
	case .Feed:
		sp.feed_busy = false
		sp.feed.busy = false
		if result == .None {
			sp.feed_len = value
			sp.feed.length = value
			clear(&sp.feed_flight)
			for f in sp.feeders {
				f.feed_hint = true
				_conn_kick(f)
			}
			_feed_release(r, sp)
			if r.cfg.feed_compact > 0 && sp.feed_len >= r.cfg.feed_compact {
				_feed_compact(r, sp)
			}
		} else {
			sp.feed.poisoned = true
		}
	case .Compact:
		sp.next_feed.busy = false
		if result != .None {
			_compact_abort(r, sp)
			return
		}
		sp.next_feed.length = value
		sp.next_len = value
		m: [16]u8
		prim.put_u64le(m[0:8], sp.feed_epoch + 1)
		prim.put_u64le(m[8:16], u64(_feed_end(sp)))
		w, err := r.store.append_begin(r.store.data, sp.meta.h, sp.meta.length, 16)
		if err == .None {
			err = r.store.append_write(r.store.data, w, m[:])
		}
		if err != .None {
			_compact_abort(r, sp)
			return
		}
		_feed_job(r, sp, .Meta, w, sp.meta)
		return
	case .Meta:
		sp.meta.busy = false
		if result != .None {
			sp.meta.poisoned = true
			_compact_abort(r, sp)
			return
		}
		sp.meta.length = value
		_compact_switch(r, sp)
	}
	_feed_flush(r, sp)
}

@(private)
_feed_job :: proc(r: ^Relay, sp: ^Space_State, kind: Pending_Kind, w: rawptr, st: ^Stream_State) {
	p, aerr := new(Pending, r.allocator)
	if aerr != nil {
		r.store.append_abort(r.store.data, w)
		_compact_abort(r, sp)
		return
	}
	p^ = {
		relay = r,
		kind  = kind,
		space = sp,
	}
	sp.jobs += 1
	st.busy = true
	r.store.append_commit(r.store.data, w, _relay_done, p)
}

@(private)
_feed_release :: proc(r: ^Relay, sp: ^Space_State) {
	end := _feed_end(sp)
	for i := 0; i < len(sp.feed_wait); {
		p := sp.feed_wait[i]
		if p.need > end {
			i += 1
			continue
		}
		ordered_remove(&sp.feed_wait, i)
		c := _conn_lookup(r, p.conn)
		if c != nil {
			if p.kind == .Drop {
				_reply_id(c, .Dropped, p.id)
			} else {
				_reply_len(c, .Appended, p.id, p.length)
			}
			c.inflight -= 1
			_conn_kick(c)
		}
		if p.stream != nil {
			_stream_unref(r, p.stream)
		}
		sp.jobs -= 1
		free(p, r.allocator)
	}
}

@(private)
_feed_compact :: proc(r: ^Relay, sp: ^Space_State) {
	if sp.compacting || sp.feed_busy {
		return
	}
	epoch := sp.feed_epoch + 1
	next, err := _pin(r, sp, reserved_id(FEED_TAG, epoch))
	if err != .None {
		return
	}
	if next.length > 0 {
		next.refs -= 1
		_stream_maybe_release(r, next)
		return
	}
	count := 0
	it, _, lerr := r.store.list_begin(r.store.data, sp.ns, 0)
	if lerr != .None {
		next.refs -= 1
		_stream_maybe_release(r, next)
		return
	}
	for {
		id, ok := r.store.list_next(r.store.data, it)
		if !ok {
			break
		}
		if !_reserved(cast([32]u8)id) {
			count += 1
		}
	}
	r.store.list_end(r.store.data, it)
	sp.compacting = true
	sp.next_feed = next
	w, werr := r.store.append_begin(r.store.data, next.h, 0, i64(count * FEED_ENTRY))
	if werr != .None {
		_compact_abort(r, sp)
		return
	}
	it, _, lerr = r.store.list_begin(r.store.data, sp.ns, 0)
	batch := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	written := 0
	for lerr == .None && written < count {
		id, ok := r.store.list_next(r.store.data, it)
		if !ok {
			break
		}
		if _reserved(cast([32]u8)id) {
			continue
		}
		length := u64(FEED_DROPPED)
		if st, sok := sp.streams[id]; sok && st.h != nil && !st.dropped {
			length = u64(st.length)
		} else if l, exists, perr := r.store.stream_probe(r.store.data, sp.ns, id); perr == .None && exists {
			length = u64(l)
		}
		e: [FEED_ENTRY]u8
		v := id
		copy(e[:32], v[:])
		prim.put_u64le(e[32:], length)
		append(&batch, ..e[:])
		written += 1
		if len(batch) >= 64 * 1024 - FEED_ENTRY {
			r.store.append_write(r.store.data, w, batch[:])
			clear(&batch)
		}
	}
	if lerr == .None {
		r.store.list_end(r.store.data, it)
	}
	for written < count {
		e: [FEED_ENTRY]u8
		prim.put_u64le(e[32:], FEED_DROPPED)
		for i in 0 ..< 16 {
			e[i] = 0xff
		}
		append(&batch, ..e[:])
		written += 1
	}
	if len(batch) > 0 {
		r.store.append_write(r.store.data, w, batch[:])
	}
	_feed_job(r, sp, .Compact, w, next)
}

@(private)
_compact_abort :: proc(r: ^Relay, sp: ^Space_State) {
	if sp.next_feed != nil {
		sp.next_feed.busy = false
		sp.next_feed.refs -= 1
		_stream_maybe_release(r, sp.next_feed)
		sp.next_feed = nil
	}
	sp.compacting = false
	_feed_flush(r, sp)
}

@(private)
_compact_switch :: proc(r: ^Relay, sp: ^Space_State) {
	old := sp.feed
	old_end := _feed_end(sp)
	sp.feed = sp.next_feed
	sp.next_feed = nil
	sp.feed_epoch += 1
	sp.feed_base = old_end
	sp.feed_len = sp.next_len
	sp.compacting = false
	for f in sp.feeders {
		if f.feed_off >= old_end {
			f.feed_off = _feed_end(sp)
		} else {
			f.feed_off = sp.feed_base
		}
		f.feed_hint = true
		_conn_kick(f)
	}
	old.refs -= 1
	if old.h != nil && !old.busy {
		p, aerr := new(Pending, r.allocator)
		if aerr == nil {
			p^ = {
				relay  = r,
				kind   = .Drop,
				space  = sp,
				stream = old,
				id     = cast([32]u8)old.id,
			}
			old.busy = true
			old.refs += 1
			sp.jobs += 1
			p.conn = {max(u32), 0}
			r.store.drop(r.store.data, sp.ns, old.id, _relay_done, p)
			return
		}
	}
	_stream_maybe_release(r, old)
}

@(private)
_on_feed :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	from := prim.read_u64le(rd)
	if !prim.reader_done(rd) {
		_fail(c, .Protocol)
		return
	}
	sp := c.space
	if _feed_open(r, sp) != .None {
		_reply_refused(c, .Io, cast([32]u8)reserved_id(FEED_TAG, 0))
		return
	}
	end := _feed_end(sp)
	off: i64
	switch {
	case from == FEED_DROPPED || from > u64(end):
		off = end
	case i64(from) < sp.feed_base:
		off = sp.feed_base
	case:
		off = i64(from) - (i64(from) - sp.feed_base) % FEED_ENTRY
	}
	if !c.feed_on {
		if _, e := append(&sp.feeders, c); e != nil {
			_conn_close(c)
			return
		}
	}
	c.feed_on = true
	c.feed_off = off
	c.feed_hint = true
	_announce(c, off, off, nil)
}

@(private)
_announce :: proc(c: ^Conn, from, next: i64, entries: []u8) {
	r := c.relay
	n := len(entries) / FEED_ENTRY
	buf, aerr := make([]u8, FRAME_HEADER + 18 + len(entries), r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	frame_header(buf, .Announce, 18 + len(entries))
	prim.put_u64le(buf[FRAME_HEADER:], u64(from))
	prim.put_u64le(buf[FRAME_HEADER + 8:], u64(next))
	buf[FRAME_HEADER + 16] = u8(n)
	buf[FRAME_HEADER + 17] = u8(n >> 8)
	copy(buf[FRAME_HEADER + 18:], entries)
	_push_buf(c, buf)
}

@(private)
_feed_read :: proc(c: ^Conn, pos: i64, end: i64) -> (raw: []u8, ok: bool) {
	r := c.relay
	sp := c.space
	want := min(end - pos, FEED_BATCH * FEED_ENTRY)
	if want <= 0 {
		return nil, false
	}
	buf, aerr := make([]u8, int(want), context.temp_allocator)
	if aerr != nil {
		return nil, false
	}
	got, err := r.store.stream_read(r.store.data, sp.feed.h, pos - sp.feed_base, buf)
	if err != .None || i64(got) != want {
		return nil, false
	}
	return buf, true
}

@(private)
_produce_feed :: proc(c: ^Conn) -> bool {
	sp := c.space
	if !sp.feed_ready || sp.feed.h == nil {
		return false
	}
	if c.feed_off < sp.feed_base {
		c.feed_off = sp.feed_base
	}
	raw, ok := _feed_read(c, c.feed_off, _feed_end(sp))
	if !ok {
		return false
	}
	keep := 0
	for i := 0; i + FEED_ENTRY <= len(raw); i += FEED_ENTRY {
		id: [32]u8
		copy(id[:], raw[i:i + 32])
		if !_reserved(id) && principal_allows(&c.principal, .Read, id) {
			if keep != i {
				copy(raw[keep:], raw[i:i + FEED_ENTRY])
			}
			keep += FEED_ENTRY
		}
	}
	from := c.feed_off
	c.feed_off += i64(len(raw))
	_announce(c, from, c.feed_off, raw[:keep])
	return true
}

@(private)
_on_list :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	since := i64(prim.read_u64le(rd))
	if !prim.reader_done(rd) {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .List, {}) {
		_reply_refused(c, .Not_Owner, {})
		return
	}
	sp := c.space
	if _feed_open(r, sp) != .None {
		_reply_refused(c, .Io, {})
		return
	}
	ls, aerr := new(Listing, r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	end := _feed_end(sp)
	ls.end = end
	ls.cursor = end
	ls.pos = clamp(since, sp.feed_base, end)
	ls.pos -= (ls.pos - sp.feed_base) % FEED_ENTRY
	c.listing = ls
}

@(private)
_listing_end :: proc(c: ^Conn) {
	free(c.listing, c.relay.allocator)
	c.listing = nil
}

@(private)
_produce_listing :: proc(c: ^Conn) -> bool {
	r := c.relay
	sp := c.space
	ls := c.listing
	if ls.pos < sp.feed_base {
		ls.pos = sp.feed_base
	}
	head := FRAME_HEADER + 8 + 1 + 2
	buf, aerr := make([]u8, head + FEED_BATCH * FEED_ENTRY, r.allocator)
	if aerr != nil {
		_conn_close(c)
		return false
	}
	raw, ok := _feed_read(c, ls.pos, ls.end)
	count := 0
	if ok {
		seen := make(map[Stream_Id]bool, len(raw) / FEED_ENTRY, context.temp_allocator)
		for i := len(raw) - FEED_ENTRY; i >= 0; i -= FEED_ENTRY {
			id: Stream_Id
			copy(id[:], raw[i:i + 32])
			if id in seen || _reserved(cast([32]u8)id) || !_can(c, .Read, cast([32]u8)id) {
				continue
			}
			seen[id] = true
			length: i64
			if st, sok := sp.streams[id]; sok && st.h != nil && !st.dropped && !st.poisoned {
				length = st.length
			} else {
				l, exists, perr := r.store.stream_probe(r.store.data, sp.ns, id)
				if perr != .None || !exists {
					continue
				}
				length = l
			}
			if length <= 0 {
				continue
			}
			e := buf[head + count * FEED_ENTRY:]
			v := id
			copy(e[:32], v[:])
			prim.put_u64le(e[32:], u64(length))
			count += 1
		}
		ls.pos += i64(len(raw))
	}
	done := !ok || ls.pos >= ls.end
	payload := 8 + 1 + 2 + count * FEED_ENTRY
	frame_header(buf, .Listing, payload)
	prim.put_u64le(buf[FRAME_HEADER:], u64(ls.cursor))
	buf[FRAME_HEADER + 8] = 0 if done else 1
	buf[FRAME_HEADER + 9] = u8(count)
	buf[FRAME_HEADER + 10] = u8(count >> 8)
	_push_buf(c, buf[:FRAME_HEADER + payload])
	if done {
		_listing_end(c)
	}
	return true
}

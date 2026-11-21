#+build linux, darwin, windows
package osync

import "base:runtime"

import "../prim"

FEED_COMPACT_DEFAULT :: 64 * 1024 * 1024
COMPACT_BATCH :: FEED_BATCH * FEED_ENTRY
COMPACT_SLICE_NS :: 1_000_000
COMPACT_TAIL :: 64 * FEED_ENTRY
COMPACT_COPY :: FEED_BATCH * FEED_ENTRY

Compact_Phase :: enum u8 {
	Idle,
	Snapshot,
	Redlog,
	Tail,
	Meta,
}

Listing :: struct {
	pos:    i64,
	end:    i64,
	cursor: i64,
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
	if sp.redlog != nil {
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
_feed_add_redaction :: proc(r: ^Relay, sp: ^Space_State, id: [32]u8, from, to: i64) -> i64 {
	e: [2 * FEED_ENTRY]u8
	v := id
	copy(e[:32], v[:])
	prim.put_u64le(e[32:], FEED_REDACT | u64(from))
	copy(e[FEED_ENTRY:][:32], v[:])
	prim.put_u64le(e[FEED_ENTRY + 32:], FEED_REDACT | FEED_REDACT_END | u64(to))
	append(&sp.feed_q, ..e[:])
	need := _feed_end(sp) + i64(len(sp.feed_flight) + len(sp.feed_q))
	_feed_flush(r, sp)
	return need
}


@(private)
_redlog_open :: proc(r: ^Relay, sp: ^Space_State) -> Error {
	if sp.redlog != nil {
		if sp.redlog.poisoned && !sp.redlog.busy {
			_stream_get(r, sp, sp.redlog.id, true) or_return
		}
		return .None
	}
	sp.redlog = _pin(r, sp, reserved_id(REDLOG_TAG, 0)) or_return
	return .None
}

@(private)
_redlog_add :: proc(r: ^Relay, sp: ^Space_State, p: ^Pending) {
	rec: [REDLOG_RECORD]u8
	copy(rec[:32], p.id[:])
	prim.put_u64le(rec[32:], u64(p.from))
	prim.put_u64le(rec[40:], u64(p.total))
	append(&sp.redlog_q, ..rec[:])
	append(&sp.redlog_qp, p)
	_redlog_flush(r, sp)
}

@(private)
_redlog_fail :: proc(r: ^Relay, sp: ^Space_State, ps: ^[dynamic]^Pending) {
	for p in ps {
		if c := _conn_lookup(r, p.conn); c != nil {
			_reply_refused(c, .Io, p.id)
			c.inflight -= 1
			_conn_kick(c)
		}
		if p.stream != nil {
			_stream_unref(r, p.stream)
		}
		sp.jobs -= 1
		free(p, r.allocator)
	}
	clear(ps)
}

@(private)
_redlog_flush :: proc(r: ^Relay, sp: ^Space_State) {
	if sp.redlog_busy || len(sp.redlog_q) == 0 {
		return
	}
	if _redlog_open(r, sp) != .None {
		clear(&sp.redlog_q)
		_redlog_fail(r, sp, &sp.redlog_qp)
		return
	}
	sp.redlog_flight, sp.redlog_q = sp.redlog_q, sp.redlog_flight
	sp.redlog_fp, sp.redlog_qp = sp.redlog_qp, sp.redlog_fp
	st := sp.redlog
	w, err := r.store.append_begin(r.store.data, st.h, st.length, i64(len(sp.redlog_flight)))
	if err == .None {
		err = r.store.append_write(r.store.data, w, sp.redlog_flight[:])
		if err != .None {
			r.store.append_abort(r.store.data, w)
		}
	}
	job: ^Pending
	if err == .None {
		aerr: runtime.Allocator_Error
		job, aerr = new(Pending, r.allocator)
		if aerr != nil {
			r.store.append_abort(r.store.data, w)
			err = .No_Memory
		}
	}
	if err != .None {
		st.poisoned = true
		clear(&sp.redlog_flight)
		_redlog_fail(r, sp, &sp.redlog_fp)
		return
	}
	job^ = {
		relay = r,
		kind  = .Redlog,
		space = sp,
	}
	sp.jobs += 1
	sp.redlog_busy = true
	st.busy = true
	r.store.append_commit(r.store.data, w, _relay_done, job)
}

@(private)
_redlog_done :: proc(r: ^Relay, sp: ^Space_State, result: Error, value: i64) {
	sp.redlog_busy = false
	st := sp.redlog
	st.busy = false
	if result != .None {
		st.poisoned = true
		clear(&sp.redlog_flight)
		_redlog_fail(r, sp, &sp.redlog_fp)
	} else {
		st.length = value
		clear(&sp.redlog_flight)
		for p in sp.redlog_fp {
			p.need = _feed_add_redaction(r, sp, p.id, p.from, p.total)
			append(&sp.feed_wait, p)
		}
		clear(&sp.redlog_fp)
		_feed_release(r, sp)
	}
	_redlog_flush(r, sp)
}

@(private)
_feed_wait :: proc(r: ^Relay, sp: ^Space_State, p: ^Pending, length: u64) {
	p.need = _feed_add(r, sp, p.id, length)
	append(&sp.feed_wait, p)
	_feed_release(r, sp)
}

@(private)
_feed_flush :: proc(r: ^Relay, sp: ^Space_State) {
	if sp.feed_busy || sp.freeze || len(sp.feed_q) == 0 && len(sp.feed_flight) == 0 {
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
			#partial switch p.kind {
			case .Drop:
				_reply_id(c, .Dropped, p.id)
			case .Redact:
				_reply_redacted(c, p.id, p.from, p.total)
			case .Note:
				_reply_hollow(c, .Noted, p.id, p.from, p.length)
			case:
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
_on_feed :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	from := prim.read_u64le(rd)
	if !prim.reader_ok(rd) {
		_fail(c, .Protocol)
		return
	}
	flags: u8
	if prim.reader_remaining(rd) > 0 {
		flags = prim.read_u8(rd)
	}
	if flags & FEED_ADD == 0 {
		_filter_free(c)
	}
	if flags & FEED_FILTERED != 0 {
		count := int(prim.read_u16le(rd))
		f := c.filter
		if f == nil {
			nf, aerr := new(Feed_Filter, r.allocator)
			if aerr != nil {
				_conn_close(c)
				return
			}
			nf.prefix = make(map[[16]u8]bool, r.allocator)
			nf.suffix = make(map[[16]u8]bool, r.allocator)
			nf.exact = make(map[[32]u8]bool, r.allocator)
			c.filter = nf
			f = nf
		}
		for _ in 0 ..< count {
			kind := Feed_Pattern_Kind(prim.read_u8(rd))
			#partial switch kind {
			case .Prefix, .Suffix:
				k: [16]u8
				prim.read_fixed(rd, k[:])
				if kind == .Prefix {
					f.prefix[k] = true
				} else {
					f.suffix[k] = true
				}
			case .Exact:
				k: [32]u8
				prim.read_fixed(rd, k[:])
				f.exact[k] = true
			case:
				_fail(c, .Protocol)
				return
			}
		}
		if !prim.reader_done(rd) || len(f.prefix) + len(f.suffix) + len(f.exact) > FEED_PATTERNS_MAX {
			_fail(c, .Protocol)
			return
		}
		if flags & FEED_ADD != 0 && c.feed_on {
			c.feed_hint = true
			return
		}
	} else if !prim.reader_done(rd) {
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
	c.feed_told = off
	c.feed_hint = true
	if flags & FEED_PRESENCE != 0 && _can(c, .List, {}) {
		c.presence = true
		_presence_snapshot(r, sp, c)
	}
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
		if c.feed_told < c.feed_off {
			from := c.feed_told
			c.feed_told = c.feed_off
			_announce(c, from, c.feed_off, nil)
			return true
		}
		return false
	}
	if n := len(raw); n >= FEED_ENTRY {
		if _, end, red := feed_redaction(prim.get_u64le(raw[n - 8:])); red && !end {
			if n == FEED_ENTRY {
				return false
			}
			raw = raw[:n - FEED_ENTRY]
		}
	}
	keep := 0
	for i := 0; i + FEED_ENTRY <= len(raw); i += FEED_ENTRY {
		id: [32]u8
		copy(id[:], raw[i:i + 32])
		_, _, red := feed_redaction(prim.get_u64le(raw[i + 32:]))
		if !_reserved(id) && (red || _filter_match(c.filter, id)) && principal_allows(&c.principal, .Read, id) {
			if keep != i {
				copy(raw[keep:], raw[i:i + FEED_ENTRY])
			}
			keep += FEED_ENTRY
		}
	}
	c.feed_off += i64(len(raw))
	if keep == 0 && c.feed_off - c.feed_told < FEED_SKIP_REPORT {
		return true
	}
	from := c.feed_told
	c.feed_told = c.feed_off
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
		_reply_refused(c, .Not_Owner, cast([32]u8)reserved_id(LIST_TAG, 0))
		return
	}
	sp := c.space
	if _feed_open(r, sp) != .None {
		_reply_refused(c, .Io, cast([32]u8)reserved_id(LIST_TAG, 0))
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
				l, _, exists, perr := r.store.stream_probe(r.store.data, sp.ns, id)
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
			if sp.phase == .Idle && r.cfg.feed_compact > 0 && sp.feed_len >= r.cfg.feed_compact {
				_compact_start(r, sp)
			}
		} else {
			sp.feed.poisoned = true
		}
		_compact_step(r, sp)
	case .Compact:
		sp.compact_busy = false
		sp.next_feed.busy = false
		if result != .None {
			_compact_abort(r, sp)
			return
		}
		sp.next_feed.length = value
		_compact_step(r, sp)
	case .Meta:
		sp.compact_busy = false
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
_feed_job :: proc(r: ^Relay, sp: ^Space_State, kind: Pending_Kind, st: ^Stream_State, data: []u8) -> bool {
	w, err := r.store.append_begin(r.store.data, st.h, st.length, i64(len(data)))
	if err == .None {
		err = r.store.append_write(r.store.data, w, data)
		if err != .None {
			r.store.append_abort(r.store.data, w)
		}
	}
	if err != .None {
		return false
	}
	p, aerr := new(Pending, r.allocator)
	if aerr != nil {
		r.store.append_abort(r.store.data, w)
		return false
	}
	p^ = {
		relay = r,
		kind  = kind,
		space = sp,
	}
	sp.jobs += 1
	sp.compact_busy = true
	st.busy = true
	r.store.append_commit(r.store.data, w, _relay_done, p)
	return true
}

@(private)
_compact_start :: proc(r: ^Relay, sp: ^Space_State) {
	for e in sp.feed_epoch + 1 ..< sp.feed_epoch + 9 {
		next, err := _pin(r, sp, reserved_id(FEED_TAG, e))
		if err != .None {
			return
		}
		if next.length == 0 {
			it, _, lerr := r.store.list_begin(r.store.data, sp.ns, 0)
			if lerr != .None {
				next.refs -= 1
				_stream_maybe_release(r, next)
				return
			}
			sp.next_feed = next
			sp.next_epoch = e
			sp.compact_it = it
			sp.compact_copied = _feed_end(sp)
			sp.phase = .Snapshot
			return
		}
		next.refs -= 1
		_stream_maybe_release(r, next)
	}
}

@(private)
_compact_step :: proc(r: ^Relay, sp: ^Space_State) {
	for sp.phase != .Idle && !sp.compact_busy {
		switch sp.phase {
		case .Idle:
			return
		case .Snapshot:
			if sp.compact_timer != 0 {
				return
			}
			deadline := prim.clock_mono_ns(r.cfg.clock) + COMPACT_SLICE_NS
			for len(sp.compact_buf) < COMPACT_BATCH {
				if prim.clock_mono_ns(r.cfg.clock) >= deadline {
					sp.compact_timer = prim.timer(r.loop, 0, sp, _compact_resume)
					return
				}
				id, ok := r.store.list_next(r.store.data, sp.compact_it)
				if !ok {
					r.store.list_end(r.store.data, sp.compact_it)
					sp.compact_it = nil
					sp.phase = .Redlog
					sp.compact_red = 0
					sp.compact_red_end = 0
					if _redlog_open(r, sp) == .None {
						sp.compact_red_end = sp.redlog.length
					}
					break
				}
				if _reserved(cast([32]u8)id) {
					continue
				}
				length, base: i64
				if st, sok := sp.streams[id]; sok && st.h != nil && !st.dropped {
					length, base = st.length, st.base
				} else {
					l, b, exists := r.store.stream_hint(r.store.data, sp.ns, id)
					if !exists || l <= 0 {
						continue
					}
					length, base = l, b
				}
				e: [FEED_ENTRY]u8
				v := id
				copy(e[:32], v[:])
				prim.put_u64le(e[32:], u64(length) | (FEED_HOLLOW if base == length else 0))
				append(&sp.compact_buf, ..e[:])
			}
			if len(sp.compact_buf) > 0 {
				ok := _feed_job(r, sp, .Compact, sp.next_feed, sp.compact_buf[:])
				clear(&sp.compact_buf)
				if !ok {
					_compact_abort(r, sp)
				}
				return
			}
		case .Redlog:
			if sp.compact_red >= sp.compact_red_end {
				sp.phase = .Tail
				continue
			}
			n := min(sp.compact_red_end - sp.compact_red, i64(COMPACT_COPY / (2 * FEED_ENTRY)) * REDLOG_RECORD)
			n -= n % REDLOG_RECORD
			raw := make([]u8, int(n), context.temp_allocator)
			got, err := r.store.stream_read(r.store.data, sp.redlog.h, sp.compact_red, raw)
			if err != .None || i64(got) != n {
				_compact_abort(r, sp)
				return
			}
			buf := make([]u8, int(n / REDLOG_RECORD) * 2 * FEED_ENTRY, context.temp_allocator)
			for k in 0 ..< int(n / REDLOG_RECORD) {
				rec := raw[k * REDLOG_RECORD:][:REDLOG_RECORD]
				e := buf[k * 2 * FEED_ENTRY:]
				copy(e[:32], rec[:32])
				prim.put_u64le(e[32:], FEED_REDACT | prim.get_u64le(rec[32:]))
				copy(e[FEED_ENTRY:][:32], rec[:32])
				prim.put_u64le(e[FEED_ENTRY + 32:], FEED_REDACT | FEED_REDACT_END | prim.get_u64le(rec[40:]))
			}
			if !_feed_job(r, sp, .Compact, sp.next_feed, buf) {
				_compact_abort(r, sp)
				return
			}
			sp.compact_red += n
			return
		case .Tail:
			avail := _feed_end(sp) - sp.compact_copied
			if avail > COMPACT_TAIL || (avail > 0 && sp.freeze) {
				want := min(avail, COMPACT_COPY)
				buf := make([]u8, int(want), context.temp_allocator)
				got, err := r.store.stream_read(r.store.data, sp.feed.h, sp.compact_copied - sp.feed_base, buf)
				if err != .None || i64(got) != want || !_feed_job(r, sp, .Compact, sp.next_feed, buf) {
					_compact_abort(r, sp)
					return
				}
				sp.compact_copied += want
				return
			}
			if !sp.freeze {
				if sp.feed_busy {
					return
				}
				sp.freeze = true
				continue
			}
			sp.phase = .Meta
			m: [16]u8
			prim.put_u64le(m[0:8], sp.next_epoch)
			prim.put_u64le(m[8:16], u64(_feed_end(sp)))
			if !_feed_job(r, sp, .Meta, sp.meta, m[:]) {
				_compact_abort(r, sp)
			}
			return
		case .Meta:
			return
		}
	}
}

@(private)
_compact_resume :: proc(l: ^prim.Loop, data: rawptr) {
	sp := cast(^Space_State)data
	sp.compact_timer = 0
	r := sp.relay
	_compact_step(r, sp)
	_feed_flush(r, sp)
	_reap(r)
}

@(private)
_compact_abort :: proc(r: ^Relay, sp: ^Space_State) {
	if sp.compact_timer != 0 {
		prim.timer_cancel(r.loop, sp.compact_timer)
		sp.compact_timer = 0
	}
	clear(&sp.compact_buf)
	if sp.compact_it != nil {
		r.store.list_end(r.store.data, sp.compact_it)
		sp.compact_it = nil
	}
	if sp.next_feed != nil {
		sp.next_feed.busy = false
		sp.next_feed.refs -= 1
		_stream_maybe_release(r, sp.next_feed)
		sp.next_feed = nil
	}
	sp.phase = .Idle
	sp.freeze = false
	_feed_flush(r, sp)
}

@(private)
_compact_switch :: proc(r: ^Relay, sp: ^Space_State) {
	old := sp.feed
	old_end := _feed_end(sp)
	sp.feed = sp.next_feed
	sp.next_feed = nil
	sp.feed_epoch = sp.next_epoch
	sp.feed_base = old_end
	sp.feed_len = sp.feed.length
	sp.phase = .Idle
	sp.freeze = false
	for f in sp.feeders {
		if f.feed_off >= old_end {
			f.feed_off = _feed_end(sp)
		} else {
			f.feed_off = sp.feed_base
		}
		f.feed_told = f.feed_off
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
				conn   = {max(u32), 0},
			}
			old.busy = true
			old.refs += 1
			sp.jobs += 1
			r.store.drop(r.store.data, sp.ns, old.id, _relay_done, p)
			return
		}
	}
	_stream_maybe_release(r, old)
}

Feed_Filter :: struct {
	prefix: map[[16]u8]bool,
	suffix: map[[16]u8]bool,
	exact:  map[[32]u8]bool,
}

@(private)
_filter_free :: proc(c: ^Conn) {
	if c.filter == nil {
		return
	}
	delete(c.filter.prefix)
	delete(c.filter.suffix)
	delete(c.filter.exact)
	free(c.filter, c.relay.allocator)
	c.filter = nil
}

@(private)
_filter_match :: proc(f: ^Feed_Filter, id: [32]u8) -> bool {
	if f == nil {
		return true
	}
	v := id
	if id in f.exact {
		return true
	}
	p: [16]u8
	copy(p[:], v[:16])
	if p in f.prefix {
		return true
	}
	copy(p[:], v[16:])
	return p in f.suffix
}

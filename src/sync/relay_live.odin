package osync

import "../prim"

@(private)
LIVE_OUT_HIGH :: 128

@(private)
_on_follow_live :: proc(c: ^Conn, rd: ^prim.Reader, count: int) {
	r := c.relay
	sp := c.space
	for _ in 0 ..< count {
		id := Stream_Id(get_id32(rd))
		off := prim.read_u64le(rd)
		if off == FOLLOW_END {
			_live_unfollow(c, id)
			continue
		}
		if off == LIVE_INTEREST || off == LIVE_INTEREST_END {
			_live_interest(c, id, off == LIVE_INTEREST)
			continue
		}
		if !_can(c, .Read, cast([32]u8)id) {
			_reply_refused(c, .Not_Owner, cast([32]u8)id)
			continue
		}
		found := false
		for x in c.lives {
			if x == id {
				found = true
				break
			}
		}
		if found {
			continue
		}
		if len(c.subs) + len(c.lives) + len(c.interests) >= r.cfg.max_follows {
			_reply_refused(c, .Limit, cast([32]u8)id)
			continue
		}
		was := _live_watched(sp, id)
		if _, e := append(&c.lives, id); e != nil {
			_conn_close(c)
			return
		}
		l, ok := sp.livers[id]
		if !ok {
			l = make([dynamic]^Conn, r.allocator)
		}
		if _, e := append(&l, c); e != nil {
			pop(&c.lives)
			if len(l) == 0 {
				delete(l)
			} else {
				sp.livers[id] = l
			}
			_conn_close(c)
			return
		}
		sp.livers[id] = l
		if !was && _live_watched(sp, id) {
			_interest_notify(sp, id, true)
		}
	}
}

@(private)
_live_watched :: proc(sp: ^Space_State, id: Stream_Id) -> bool {
	l, ok := sp.livers[id]
	if !ok {
		return false
	}
	w := sp.interest[id]
	outer: for f in l {
		for x in w {
			if x == f {
				continue outer
			}
		}
		return true
	}
	return false
}

@(private)
_reply_watched :: proc(c: ^Conn, id: Stream_Id, on: bool) {
	b: [FRAME_HEADER + WATCHED_LEN]u8
	frame_header(b[:], .Watched, WATCHED_LEN)
	v := id
	copy(b[FRAME_HEADER:], v[:])
	b[FRAME_HEADER + 32] = 1 if on else 0
	_push_small(c, b[:])
}

@(private)
_interest_notify :: proc(sp: ^Space_State, id: Stream_Id, on: bool) {
	for f in sp.interest[id] {
		if f.dead || f.closing {
			continue
		}
		_reply_watched(f, id, on)
		_conn_kick(f)
	}
}

@(private)
_live_interest :: proc(c: ^Conn, id: Stream_Id, on: bool) {
	sp := c.space
	if !on {
		_interest_remove(sp, id, c)
		for i := 0; i < len(c.interests); i += 1 {
			if c.interests[i] == id {
				unordered_remove(&c.interests, i)
				break
			}
		}
		return
	}
	if !_can(c, .Append, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	for x in c.interests {
		if x == id {
			_reply_watched(c, id, _live_watched(sp, id))
			return
		}
	}
	if len(c.subs) + len(c.lives) + len(c.interests) >= c.relay.cfg.max_follows {
		_reply_refused(c, .Limit, cast([32]u8)id)
		return
	}
	if _, e := append(&c.interests, id); e != nil {
		_conn_close(c)
		return
	}
	l, ok := sp.interest[id]
	if !ok {
		l = make([dynamic]^Conn, c.relay.allocator)
	}
	if _, e := append(&l, c); e != nil {
		pop(&c.interests)
		if len(l) == 0 {
			delete(l)
		} else {
			sp.interest[id] = l
		}
		_conn_close(c)
		return
	}
	sp.interest[id] = l
	_reply_watched(c, id, _live_watched(sp, id))
}

@(private)
_interest_remove :: proc(sp: ^Space_State, id: Stream_Id, c: ^Conn) {
	l, ok := &sp.interest[id]
	if !ok {
		return
	}
	_remove_conn(l, c)
	if len(l) == 0 {
		delete(l^)
		delete_key(&sp.interest, id)
	}
}

@(private)
_live_unfollow :: proc(c: ^Conn, id: Stream_Id) {
	for i := 0; i < len(c.lives); i += 1 {
		if c.lives[i] == id {
			unordered_remove(&c.lives, i)
			_liver_remove(c.space, id, c)
			return
		}
	}
}

@(private)
_liver_remove :: proc(sp: ^Space_State, id: Stream_Id, c: ^Conn) {
	l, ok := &sp.livers[id]
	if !ok {
		return
	}
	was := _live_watched(sp, id)
	_remove_conn(l, c)
	if len(l) == 0 {
		delete(l^)
		delete_key(&sp.livers, id)
	}
	if was && !_live_watched(sp, id) {
		_interest_notify(sp, id, false)
	}
}

@(private)
_lives_conn_closed :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn) {
	for id in c.lives {
		_liver_remove(sp, id, c)
	}
	clear(&c.lives)
	for id in c.interests {
		_interest_remove(sp, id, c)
	}
	clear(&c.interests)
}

@(private)
_on_live_begin :: proc(c: ^Conn, rd: ^prim.Reader, total: i64) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	msg := prim.read_u64le(rd)
	at := prim.read_u64le(rd)
	c.op = Op{kind = .Discard, total = total}
	if !prim.reader_ok(rd) || msg >= DRAFT_MSG_MAX || at >= DRAFT_MSG_MAX {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .Append, cast([32]u8)id) {
		c.op.reply = .Refused
		c.op.code = .Not_Owner
		c.op.id = cast([32]u8)id
		return
	}
	l, ok := c.space.livers[id]
	if !ok || len(l) == 0 || (len(l) == 1 && l[0] == c) {
		return
	}
	buf, aerr := make([]u8, FRAME_HEADER + LIVE_FIXED + int(total), r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	frame_header(buf, .Lived, LIVE_FIXED + int(total))
	v := id
	copy(buf[FRAME_HEADER:], v[:])
	prim.put_u64le(buf[FRAME_HEADER + 32:], msg)
	prim.put_u64le(buf[FRAME_HEADER + 40:], at)
	c.op.kind = .Live
	c.op.buf = buf
	c.op.pos = FRAME_HEADER + LIVE_FIXED
	c.op.id = cast([32]u8)id
}

@(private)
_live_end :: proc(c: ^Conn, op: ^Op) {
	r := c.relay
	buf := op.buf
	if op.pos != len(buf) || c.space == nil {
		delete(buf, r.allocator)
		return
	}
	id := Stream_Id(op.id)
	l, ok := c.space.livers[id]
	if !ok {
		delete(buf, r.allocator)
		return
	}
	targets := make([dynamic]^Conn, context.temp_allocator)
	for f in l {
		if f == c || f.dead || f.closing || f.state != .Ready || len(f.out) - f.out_head >= LIVE_OUT_HIGH {
			continue
		}
		if !_can(f, .Read, cast([32]u8)id) {
			continue
		}
		append(&targets, f)
	}
	for f, i in targets {
		b := buf
		if i + 1 < len(targets) {
			x, e := make([]u8, len(buf), r.allocator)
			if e != nil {
				continue
			}
			copy(x, buf)
			b = x
		}
		_push_buf(f, b)
		_conn_kick(f)
		r.stats.lived += 1
		r.stats.lived_bytes += u64(len(b))
	}
	if len(targets) == 0 {
		delete(buf, r.allocator)
	}
}

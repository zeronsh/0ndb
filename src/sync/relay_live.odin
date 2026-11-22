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
		if len(c.subs) + len(c.lives) >= r.cfg.max_follows {
			_reply_refused(c, .Limit, cast([32]u8)id)
			continue
		}
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
	_remove_conn(l, c)
	if len(l) == 0 {
		delete(l^)
		delete_key(&sp.livers, id)
	}
}

@(private)
_lives_conn_closed :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn) {
	for id in c.lives {
		_liver_remove(sp, id, c)
	}
	clear(&c.lives)
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

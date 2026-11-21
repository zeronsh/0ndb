package osync

import "core:crypto"
import "core:hash/xxhash"
import "../journal"
import "../prim"

KEYS_STREAM :: "keys/"
PADDING_KIND :: 0xff
KEYS_RECORD :: 2

padme :: proc "contextless" (n: i64) -> i64 {
	if n < 2 {
		return n
	}
	e := 63 - i64(_clz64(u64(n)))
	s := 64 - i64(_clz64(u64(e)))
	z := e - s
	if z <= 0 {
		return n
	}
	mask := (i64(1) << u64(z)) - 1
	return (n + mask) & ~mask
}

padding_filler :: proc "contextless" (pending: i64) -> int {
	if pending <= 0 {
		return 0
	}
	target := padme(pending + journal.OVERHEAD + 1)
	return int(target - pending - journal.OVERHEAD)
}

keys_stream_name :: proc(segment: string, allocator := context.temp_allocator) -> (string, Error) {
	return _concat(allocator, KEYS_STREAM, segment)
}

keys_record_decode :: proc(t: ^Key_Tree, body: []u8, allocator := context.allocator) -> Error {
	if len(body) < 1 || body[0] != KEYS_RECORD {
		return .Corrupt
	}
	return keytree_decode(t, body[1:], allocator)
}

replicator_publish_keys :: proc(r: ^Replicator, scope: ^Scope, segment: string, tree: ^Key_Tree) -> Error {
	_enter(r)
	defer _leave(r)
	name := keys_stream_name(segment) or_return
	epoch := tree.version
	id := stream_id(scope, r.cfg.self, name, epoch)
	pbuf: prim.Path_Buf = ---
	path := _keys_path(r, &pbuf, id)
	body := make([dynamic]u8, context.temp_allocator)
	append(&body, KEYS_RECORD)
	keytree_encode(tree, &body) or_return
	defer crypto.zero_explicit(raw_data(body), len(body))
	journal.journal_remove(r.vfs, path)
	j: journal.Journal
	if jerr := journal.journal_open(&j, r.vfs, path, {}, context.allocator); jerr != .None {
		return _from_journal(jerr)
	}
	_, aerr := journal.journal_append(&j, body[:])
	if aerr == .None {
		aerr = journal.journal_commit(&j)
	}
	durable := journal.journal_durable_len(&j)
	journal.journal_close(&j)
	if aerr != .None {
		return _from_journal(aerr)
	}
	replicator_publish(r, scope, name, epoch, path, durable) or_return
	if epoch == 0 {
		return .None
	}
	l := r.locals[id]
	prev := stream_id(scope, r.cfg.self, name, epoch - 1)
	l.drop_id = prev
	l.dropping = true
	pb: prim.Path_Buf = ---
	l.drop_path = _clone_string(_keys_path(r, &pb, prev), r.allocator) or_return
	return .None
}

replicator_redact :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, from, to: i64) -> Error {
	_enter(r)
	defer _leave(r)
	if r.phase != .Ready {
		return .Closed
	}
	client_redact(&r.client, stream_id(scope, device, name, epoch), from, to) or_return
	_repl_flush(r)
	return .None
}

replicator_zero_replica :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, from, to: i64) -> Error {
	_enter(r)
	defer _leave(r)
	rm := _remote_get(r, scope, device, name, epoch) or_return
	defer _remote_maybe_free(r, rm)
	hi := min(to, journal.replica_length(&rm.rep))
	if hi <= from {
		return .None
	}
	return _from_journal(journal.replica_redact(&rm.rep, from, hi))
}

@(private)
_keys_path :: proc(r: ^Replicator, buf: ^prim.Path_Buf, id: Stream_Id) -> string {
	n := copy(buf[:], r.dir)
	n += copy(buf[n:], "/ckpt/k")
	sid := id
	n += prim.hex_encode(buf[n:], sid[:])
	return string(buf[:n])
}

@(private)
_verdict :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) -> (v: Verdict, lo, hi: i64) {
	if rm.quarantined {
		return .Equivocation, 0, 0
	}
	if r.cfg.verify == nil {
		return .Accept, 0, 0
	}
	need: journal.Range
	state: _Align
	lo, hi, need, state = _aligned_range(r, rm, from, to)
	switch state {
	case .Bad:
		return .Equivocation, 0, 0
	case .Need:
		_fetch_gap(r, rm, need)
		return .Hold, 0, 0
	case .Ready:
	}
	if hi <= lo {
		return .Accept, 0, 0
	}
	before := rm.span
	req := Verify_Request {
		device  = rm.device,
		name    = rm.name,
		epoch   = rm.epoch,
		stream  = rm.id,
		replica = &rm.rep,
		from    = lo,
		to      = hi,
		span    = &rm.span,
		span_ok = &rm.span_ok,
	}
	v = r.cfg.verify(r.cfg.user, &req)
	switch v {
	case .Accept:
		_verified_add(rm, lo, hi)
	case .Hold:
		hi = req.done if req.done > lo && req.done <= hi else lo
		_verified_add(rm, lo, hi)
	case .Equivocation:
		return v, 0, 0
	}
	if rm.span_ok && (rm.span.off != before.off || rm.span.head != before.head) {
		_span_save(r, rm)
	}
	return v, lo, hi
}

@(private)
_verified_add :: proc(rm: ^Remote, lo, hi: i64) {
	if hi <= lo {
		return
	}
	i := 0
	for i < len(rm.verified) && rm.verified[i].to < lo {
		i += 1
	}
	j := i
	g := journal.Range{lo, hi}
	for j < len(rm.verified) && rm.verified[j].from <= hi {
		g.from = min(g.from, rm.verified[j].from)
		g.to = max(g.to, rm.verified[j].to)
		j += 1
	}
	if j > i {
		remove_range(&rm.verified, i + 1, j)
		rm.verified[i] = g
		return
	}
	inject_at(&rm.verified, i, g)
}

@(private)
_frame_u32 :: proc(r: ^Replicator, rm: ^Remote, at: i64) -> (v: i64, have: bool, valid: bool) {
	if at < 0 || !journal.replica_covers(&rm.rep, at, at + 4) {
		return
	}
	b: [4]u8
	if n, err := prim.read_at(r.vfs, rm.rep.fd, b[:], at); err != .None || n != 4 {
		return
	}
	v = i64(prim.get_u32le(b[:]))
	return v, true, v <= journal.MAX_BODY
}

@(private)
_Align :: enum u8 {
	Ready,
	Need,
	Bad,
}

@(private)
_aligned_range :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) -> (lo, hi: i64, need: journal.Range, state: _Align) {
	f, t := from, to
	for v in rm.verified {
		if v.from <= f && v.to > f {
			f = v.to
		}
		if v.from < t && v.to >= t {
			t = v.from
		}
	}
	if t <= f {
		return
	}
	lower := i64(0)
	upper := i64(-1)
	if rm.relay_len >= t {
		upper = rm.relay_len
	}
	for v in rm.verified {
		for b in ([2]i64{v.from, v.to}) {
			if b <= f {
				lower = max(lower, b)
			}
			if b >= t && (upper < 0 || b < upper) {
				upper = b
			}
		}
	}
	gap_below, miss_below := journal.replica_missing(&rm.rep, lower, f)
	gap_above := journal.Range{}
	miss_above := true
	if upper >= 0 {
		gap_above, miss_above = journal.replica_missing(&rm.rep, t, upper)
	}
	forward := !miss_below
	backward := !miss_above
	if forward && backward {
		forward = t - lower <= upper - f
		backward = !forward
	}
	switch {
	case forward:
		pos := lower
		for pos < t {
			n, have, valid := _frame_u32(r, rm, pos)
			if !have {
				break
			}
			if !valid {
				return lower, t, {}, .Ready
			}
			next := pos + n + journal.OVERHEAD
			if !journal.replica_covers(&rm.rep, pos, next) {
				break
			}
			pos = next
		}
		return lower, pos, {}, .Ready
	case backward:
		pos := upper
		for pos > f {
			n, have, valid := _frame_u32(r, rm, pos - 4)
			if !have {
				break
			}
			start := pos - n - journal.OVERHEAD
			if !valid || start < 0 {
				return 0, 0, {}, .Bad
			}
			if !journal.replica_covers(&rm.rep, start, pos) {
				break
			}
			if head, _, _ := _frame_u32(r, rm, start); head != n {
				return 0, 0, {}, .Bad
			}
			pos = start
		}
		return pos, upper, {}, .Ready
	}
	if upper >= 0 && gap_above.to - gap_above.from <= gap_below.to - gap_below.from {
		return 0, 0, gap_above, .Need
	}
	return 0, 0, gap_below, .Need
}

@(private)
_quarantine :: proc(r: ^Replicator, rm: ^Remote, at: i64) {
	if rm.quarantined {
		return
	}
	rm.quarantined = true
	clear(&rm.wants)
	clear(&rm.inflight)
	rm.tail = 0
	if rm.follow && r.phase == .Ready {
		ids := [1]Stream_Id{rm.id}
		client_unfollow(&r.client, ids[:])
	}
	_emit(r, Repl_Event{kind = .Quarantined, err = .Conflict, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = at, length = rm.relay_len})
}

@(private)
_stage_write :: proc(rm: ^Remote, at: i64, data: []u8) -> journal.Error {
	end := at + i64(len(data))
	pos := at
	have := journal.replica_have(&rm.rep)
	pieces: [dynamic]journal.Range
	pieces.allocator = context.temp_allocator
	for h in have {
		if h.to <= pos {
			continue
		}
		if h.from >= end {
			break
		}
		if h.from > pos {
			append(&pieces, journal.Range{pos, h.from})
		}
		pos = max(pos, h.to)
	}
	if pos < end {
		append(&pieces, journal.Range{pos, end})
	}
	for p in pieces {
		journal.replica_write(&rm.rep, p.from, data[p.from - at:p.to - at]) or_return
	}
	return .None
}

@(private)
_all_zero :: proc "contextless" (b: []u8) -> bool {
	acc: u8
	for x in b {
		acc |= x
	}
	return acc == 0
}

@(private)
_clz64 :: proc "contextless" (v: u64) -> u64 {
	n: u64 = 0
	x := v
	if x == 0 {
		return 64
	}
	for x & (u64(1) << 63) == 0 {
		x <<= 1
		n += 1
	}
	return n
}



@(private)
_feed_cursor_load :: proc(r: ^Replicator) {
	pbuf: prim.Path_Buf = ---
	n := copy(pbuf[:], r.dir)
	n += copy(pbuf[n:], "/feed")
	path := string(pbuf[:n])
	fd, err := prim.open_file(r.vfs, path, {.Write}, 0o600)
	if err == .Not_Found {
		fd, err = prim.open_file(r.vfs, path, {.Write, .Create}, 0o600)
	}
	if err != .None {
		return
	}
	r.feed_fd = fd
	newest, _, count, serr := slots_read(r.vfs, fd)
	if serr == .None && count > 0 {
		r.feed_cursor = newest.value
		r.feed_seq = newest.seq
	}
}

@(private)
_on_announce :: proc(r: ^Replicator, ev: ^Event) {
	for i in 0 ..< listing_count(ev) {
		e := ev.entries[i * FEED_ENTRY:][:FEED_ENTRY]
		id: Stream_Id
		copy(id[:], e[:32])
		length := prim.get_u64le(e[32:])
		if length == FEED_DROPPED {
			if rm, ok := r.remotes[id]; ok {
				_emit(r, Repl_Event{kind = .Dropped, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
			}
			continue
		}
		if length > u64(max(i64)) {
			continue
		}
		_seen_stream(r, id, i64(length))
		if rm, ok := r.remotes[id]; ok {
			_remote_pull(r, rm)
		}
	}
	if ev.length > r.feed_cursor {
		r.feed_cursor = ev.length
		if r.feed_fd >= 0 {
			r.feed_seq += 1
			slot_write(r.vfs, r.feed_fd, Slot{seq = r.feed_seq, value = r.feed_cursor, start = 0})
		}
	}
	_fetch_check(r)
}

@(private)
SPAN_REC :: 128

@(private)
_span_load :: proc(r: ^Replicator, rm: ^Remote, replica_path: string) {
	path, err := _concat(context.temp_allocator, replica_path, ".span")
	if err != .None {
		return
	}
	fd, oerr := prim.open_file(r.vfs, path, {.Write}, 0o600)
	if oerr == .Not_Found {
		fd, oerr = prim.open_file(r.vfs, path, {.Write, .Create}, 0o600)
	}
	if oerr != .None {
		return
	}
	rm.span_fd = fd
	b: [2 * SPAN_REC]u8
	n, rerr := prim.read_at(r.vfs, fd, b[:], 0)
	if rerr != .None {
		return
	}
	best: u64
	for i in 0 ..< 2 {
		if (i + 1) * SPAN_REC > n {
			break
		}
		rec := b[i * SPAN_REC:][:SPAN_REC]
		if xxhash.XXH3_64_with_seed(rec[:112], SPAN_SEED) != prim.get_u64le(rec[112:]) {
			continue
		}
		seq := prim.get_u64le(rec[0:])
		if seq <= best {
			continue
		}
		best = seq
		rm.span_seq = seq
		rm.span.off = i64(prim.get_u64le(rec[8:]))
		rm.span.end = i64(prim.get_u64le(rec[16:]))
		rm.span.range_start = i64(prim.get_u64le(rec[24:]))
		copy(rm.span.prev_head[:], rec[32:64])
		copy(rm.span.head[:], rec[64:96])
		rm.span_ok = true
	}
}

@(private)
SPAN_SEED :: 0x7370_616e

@(private)
_span_save :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.span_fd < 0 {
		return
	}
	rm.span_seq += 1
	rec: [SPAN_REC]u8
	prim.put_u64le(rec[0:], rm.span_seq)
	prim.put_u64le(rec[8:], u64(rm.span.off))
	prim.put_u64le(rec[16:], u64(rm.span.end))
	prim.put_u64le(rec[24:], u64(rm.span.range_start))
	copy(rec[32:64], rm.span.prev_head[:])
	copy(rec[64:96], rm.span.head[:])
	prim.put_u64le(rec[112:], xxhash.XXH3_64_with_seed(rec[:112], SPAN_SEED))
	if prim.write_at(r.vfs, rm.span_fd, rec[:], i64(rm.span_seq & 1) * SPAN_REC) == .None {
		prim.datasync(r.vfs, rm.span_fd)
	}
}

@(private)
_feed_subscribe :: proc(r: ^Replicator, from_start: bool) {
	pats := make([dynamic]Feed_Pattern, context.temp_allocator)
	for id, rm in r.remotes {
		if rm.follow && !rm.grouped {
			append(&pats, Feed_Pattern{kind = .Exact, bytes = cast([32]u8)id})
		}
	}
	for suffix in r.groups {
		p := Feed_Pattern{kind = .Suffix}
		sfx := suffix
		copy(p.bytes[:16], sfx[:])
		append(&pats, p)
	}
	from := u64(0) if from_start || r.feed_cursor < 0 else u64(r.feed_cursor)
	client_feed_follow(&r.client, from, pats[:], true)
}

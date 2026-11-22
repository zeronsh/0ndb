#+build linux, darwin, windows
package osync

import "core:crypto"
import "core:slice"
import "core:mem"
import "core:hash/xxhash"
import "../journal"
import "../prim"

PADDING_KIND :: 0xff

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

replicator_publish_keys :: proc(r: ^Replicator, scope: ^Scope, segment: string, tree: ^Key_Tree, seal: ^[32]u8 = nil) -> Error {
	_enter(r)
	defer _leave(r)
	name := keys_stream_name(segment) or_return
	epoch := tree.version
	id := stream_id(scope, r.cfg.self, name, epoch)
	pbuf: prim.Path_Buf = ---
	path := _keys_path(r, &pbuf, id)
	durable := _keys_write(r, scope, name, epoch, id, path, tree, seal) or_return
	if epoch > 0 {
		l, ok := r.locals[id]
		if !ok {
			l = _local_open(r, scope, name, epoch, id, path) or_return
		}
		prev := stream_id(scope, r.cfg.self, name, epoch - 1)
		if old, found := r.locals[prev]; found && old != l {
			_local_supersede(r, old)
		}
		pb: prim.Path_Buf = ---
		drop_path := _clone_string(_keys_path(r, &pb, prev), r.allocator) or_return
		if len(l.drop_path) > 0 {
			delete(l.drop_path, r.allocator)
		}
		l.drop_id = prev
		l.drop_path = drop_path
		l.dropping = true
	}
	replicator_publish(r, scope, name, epoch, path, durable) or_return
	return _keys_head_publish(r, scope, name, epoch)
}

replicator_stage_keys :: proc(r: ^Replicator, scope: ^Scope, segment: string, tree: ^Key_Tree, seal: ^[32]u8 = nil) -> Error {
	_enter(r)
	defer _leave(r)
	name := keys_stream_name(segment) or_return
	epoch := tree.version
	id := stream_id(scope, r.cfg.self, name, epoch)
	pbuf: prim.Path_Buf = ---
	path := _keys_path(r, &pbuf, id)
	_keys_write(r, scope, name, epoch, id, path, tree, seal) or_return
	hpb: prim.Path_Buf = ---
	_, _ = _keys_head_write(r, scope, name, epoch, &hpb) or_return
	return .None
}

@(private)
_keys_write :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, id: Stream_Id, path: string, tree: ^Key_Tree, seal: ^[32]u8) -> (durable: i64, err: Error) {
	body := make([dynamic]u8, context.temp_allocator)
	if seal != nil {
		keys_record_seal(tree, seal, id, &body) or_return
	} else {
		append(&body, KEYS_RECORD)
		keytree_encode(tree, &body) or_return
	}
	defer crypto.zero_explicit(raw_data(body), len(body))
	floor := replicator_floor(r, scope, name, epoch) or_return
	same := false
	rd: journal.Reader
	if journal.reader_open(&rd, r.vfs, path, context.temp_allocator) == .None {
		c := journal.cursor(&rd, 0)
		if b, _, ok := journal.next(&c); ok {
			same = _keys_same(b, tree, seal, id, body[:])
		}
		journal.reader_close(&rd)
	}
	if !same {
		if floor > 0 {
			return 0, .Conflict
		}
		journal.journal_remove(r.vfs, path)
	}
	j: journal.Journal
	if jerr := journal.journal_open(&j, r.vfs, path, {}, context.allocator); jerr != .None {
		return 0, _from_journal(jerr)
	}
	aerr: journal.Error
	if journal.journal_durable_len(&j) == 0 {
		_, aerr = journal.journal_append(&j, body[:])
		if aerr == .None {
			aerr = journal.journal_commit(&j)
		}
	}
	durable = journal.journal_durable_len(&j)
	journal.journal_close(&j)
	if aerr != .None {
		return 0, _from_journal(aerr)
	}
	return durable, .None
}

@(private)
_keys_head_publish :: proc(r: ^Replicator, scope: ^Scope, keys_name: string, epoch: u64) -> Error {
	pbuf: prim.Path_Buf = ---
	hname, durable := _keys_head_write(r, scope, keys_name, epoch, &pbuf) or_return
	hid := stream_id(scope, r.cfg.self, hname, 0)
	return replicator_publish(r, scope, hname, 0, _keys_path(r, &pbuf, hid), durable)
}

@(private)
_keys_head_write :: proc(r: ^Replicator, scope: ^Scope, keys_name: string, epoch: u64, pbuf: ^prim.Path_Buf) -> (hname: string, durable: i64, err: Error) {
	hname = keys_head_name(keys_name) or_return
	hid := stream_id(scope, r.cfg.self, hname, 0)
	path := _keys_path(r, pbuf, hid)
	j: journal.Journal
	if jerr := journal.journal_open(&j, r.vfs, path, {}, context.allocator); jerr != .None {
		return hname, 0, _from_journal(jerr)
	}
	rec: [9]u8
	rec[0] = KEYS_HEAD_RECORD
	prim.put_u64le(rec[1:], epoch)
	have := false
	if end := journal.journal_durable_len(&j); end > 0 {
		rd: journal.Reader
		journal.journal_reader(&j, &rd, context.temp_allocator)
		if b, _, berr := journal.record_before(&rd, end); berr == .None {
			have = string(b) == string(rec[:])
		}
		journal.reader_close(&rd)
	}
	aerr: journal.Error
	if !have {
		_, aerr = journal.journal_append(&j, rec[:])
		if aerr == .None {
			aerr = journal.journal_commit(&j)
		}
	}
	durable = journal.journal_durable_len(&j)
	journal.journal_close(&j)
	if aerr != .None {
		return hname, 0, _from_journal(aerr)
	}
	return hname, durable, .None
}

replicator_keys_published :: proc(r: ^Replicator, scope: ^Scope, segment: string, tree: ^Key_Tree) -> bool {
	name, nerr := keys_stream_name(segment)
	if nerr != .None {
		return false
	}
	if floor, ferr := replicator_floor(r, scope, name, tree.version); ferr != .None || floor <= 0 {
		return false
	}
	hname, herr := keys_head_name(name)
	if herr != .None {
		return false
	}
	hfloor, hferr := replicator_floor(r, scope, hname, 0)
	if hferr != .None || hfloor <= 0 {
		return false
	}
	pbuf: prim.Path_Buf = ---
	st, serr := prim.stat(r.vfs, _keys_path(r, &pbuf, stream_id(scope, r.cfg.self, hname, 0)))
	return serr == .None && hfloor >= st.size
}

replicator_redact :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, from, to: i64) -> Error {
	_enter(r)
	defer _leave(r)
	if r.phase != .Ready {
		return .Closed
	}
	id := stream_id(scope, device, name, epoch)
	if device == r.cfg.self {
		client_redact(&r.client, id, from, to) or_return
		l, ok := r.locals[id]
		opened := false
		if !ok {
			l, opened = _arc_own_open(r, scope, name, epoch, id)
		}
		if l != nil {
			_arc_redact_own(r, l, from, to)
			if opened {
				_local_maybe_free(r, l)
			}
		}
	} else {
		queued := false
		if _arc_on(r) {
			if rm, rerr := _remote_get(r, scope, device, name, epoch); rerr == .None {
				queued = _arc_redact_remote(r, rm, from, to)
				_remote_maybe_free(r, rm)
			}
		}
		if !queued {
			client_redact(&r.client, id, from, to) or_return
		}
	}
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
	keys, known := _remote_keys(r, rm)
	if !known {
		_pending_add(r, rm.path, from, hi)
		return .None
	}
	return _from_journal(journal.replica_redact(&rm.rep, from, hi, keys))
}

@(private)
_remote_keys :: proc(r: ^Replicator, rm: ^Remote) -> (keys: journal.Key_Provider, known: bool) {
	if rm.plain {
		return {}, true
	}
	if r.cfg.keys != nil {
		sealing, tree := r.cfg.keys(r.cfg.user, rm.device, rm.name, rm.epoch, rm.id)
		switch sealing {
		case .Unknown:
			return {}, false
		case .Key_Tree, .Key_Tree_Stale:
			return tree, true
		case .Stream_Key:
		}
	}
	return static_provider(&rm.skey), true
}

@(private)
_pending_path :: proc(buf: ^prim.Path_Buf, replica_path: string) -> string {
	n := copy(buf[:], replica_path)
	n += copy(buf[n:], ".pending")
	return string(buf[:n])
}

@(private)
_pending_add :: proc(r: ^Replicator, replica_path: string, from, to: i64) {
	pbuf: prim.Path_Buf = ---
	path := _pending_path(&pbuf, replica_path)
	fd, err := prim.open_file(r.vfs, path, {.Write, .Create}, 0o600)
	if err != .None {
		return
	}
	defer prim.close_file(r.vfs, fd)
	size, _ := prim.file_size(r.vfs, fd)
	rec: [16]u8
	prim.put_u64le(rec[0:8], u64(from))
	prim.put_u64le(rec[8:16], u64(to))
	if prim.write_at(r.vfs, fd, rec[:], size - size % 16) == .None {
		prim.datasync(r.vfs, fd)
	}
}

@(private)
_pending_apply :: proc(r: ^Replicator, rm: ^Remote) {
	pbuf: prim.Path_Buf = ---
	path := _pending_path(&pbuf, rm.path)
	data, err := prim.read_file(r.vfs, path, context.temp_allocator)
	if err != .None {
		return
	}
	keys, known := _remote_keys(r, rm)
	if !known {
		return
	}
	done := true
	for i := 0; i + 16 <= len(data); i += 16 {
		from := i64(prim.get_u64le(data[i:]))
		to := min(i64(prim.get_u64le(data[i + 8:])), journal.replica_length(&rm.rep))
		if to > from && from >= 0 {
			if e := journal.replica_redact(&rm.rep, from, to, keys); e != .None && e != .Missing {
				done = false
			}
		}
	}
	if done {
		prim.remove(r.vfs, path)
	}
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
	case .Tampered:
		done := req.done if req.done > lo && req.done <= hi else lo
		_verified_add(rm, lo, done)
		return v, done, hi
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
	rm.pushed = false
	if _following(rm) && r.phase == .Ready {
		ids := [1]Stream_Id{rm.id}
		client_unfollow(&r.client, ids[:])
	}
	_kwait_release(r, rm)
	_emit(r, Repl_Event{kind = .Quarantined, err = .Conflict, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = at, length = rm.relay_len})
}

@(private)
_stage_write :: proc(r: ^Replicator, rm: ^Remote, at: i64, data: []u8) -> journal.Error {
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
		r.fetched_bytes += u64(p.to - p.from)
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
		r.feed_seq = newest.seq
		if newest.hash == u64(_relay_tag(r)) {
			r.feed_cursor = newest.value
		}
	}
}

@(private)
_relay_tag :: proc(r: ^Replicator) -> i64 {
	k := r.cfg.relay_public
	return i64(prim.get_u64le(k[:8]) >> 1)
}

@(private)
_on_announce :: proc(r: ^Replicator, ev: ^Event) {
	red_id: Stream_Id
	red_from := i64(-1)
	for i in 0 ..< listing_count(ev) {
		e := ev.entries[i * FEED_ENTRY:][:FEED_ENTRY]
		id: Stream_Id
		copy(id[:], e[:32])
		length := prim.get_u64le(e[32:])
		if at, end, red := feed_redaction(length); red {
			if !end {
				red_id, red_from = id, at
			} else if red_from >= 0 && red_id == id {
				_replica_redacted(r, id, red_from, at)
				red_from = -1
			}
			continue
		}
		red_from = -1
		if length == FEED_DROPPED {
			if rm, ok := r.remotes[id]; ok {
				_emit(r, Repl_Event{kind = .Dropped, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
			}
			continue
		}
		n, hollow, lok := feed_length(length)
		if !lok {
			continue
		}
		if hollow {
			_remote_hollow_seen(r, id, n)
		}
		_seen_stream(r, id, n)
		if rm, ok := r.remotes[id]; ok {
			_remote_pull(r, rm)
		}
	}
	if ev.length > r.feed_cursor {
		r.feed_cursor = ev.length
		if r.feed_fd >= 0 {
			r.feed_seq += 1
			slot_write(r.vfs, r.feed_fd, Slot{seq = r.feed_seq, value = r.feed_cursor, hash = u64(_relay_tag(r))})
		}
	}
	_fetch_check(r)
}

@(private)
_replica_redacted :: proc(r: ^Replicator, id: Stream_Id, from, to: i64) {
	dev := stream_device(id)
	if to <= from {
		return
	}
	if dev == r.cfg.self {
		ev := Repl_Event{kind = .Local_Redacted, device = dev, stream = id, from = from, to = to}
		if l, ok := r.locals[id]; ok {
			ev.name, ev.epoch = l.name, l.epoch
		}
		_emit(r, ev)
		return
	}
	if rm, ok := r.remotes[id]; ok {
		_arc_invalidate(r, rm)
		_arc_wipe_remote(r, rm, from, to)
		hi := min(to, journal.replica_length(&rm.rep))
		if hi > from {
			keys, known := _remote_keys(r, rm)
			if !known {
				_pending_add(r, rm.path, from, hi)
			} else if e := journal.replica_redact(&rm.rep, from, hi, keys); e != .None && e != .Missing {
				_pending_add(r, rm.path, from, hi)
			}
		}
		_emit(r, Repl_Event{kind = .Redacted, device = rm.device, name = rm.name, epoch = rm.epoch, stream = id, from = from, to = to})
		return
	}
	pbuf: prim.Path_Buf = ---
	path := _replica_path(r, &pbuf, id)
	if _, serr := prim.stat(r.vfs, path); serr != .None {
		return
	}
	rep: journal.Replica
	if journal.replica_open(&rep, r.vfs, path, r.allocator) != .None {
		return
	}
	hi := min(to, journal.replica_length(&rep))
	if hi > from {
		if e := journal.replica_redact(&rep, from, hi, {}); e != .None && e != .Missing {
			_pending_add(r, path, from, hi)
		}
	}
	journal.replica_close(&rep)
	_emit(r, Repl_Event{kind = .Redacted, device = dev, stream = id, from = from, to = to})
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
		rm.empty_ok = rec[96] & SPAN_EMPTY != 0
		if rec[96] & SPAN_NONE != 0 {
			rm.span = {}
			rm.span_ok = false
			continue
		}
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
SPAN_EMPTY :: u8(1)

@(private)
SPAN_NONE :: u8(2)

@(private)
_span_save :: proc(r: ^Replicator, rm: ^Remote, durable := true) {
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
	rec[96] = (SPAN_EMPTY if rm.empty_ok else 0) | (0 if rm.span_ok else SPAN_NONE)
	prim.put_u64le(rec[112:], xxhash.XXH3_64_with_seed(rec[:112], SPAN_SEED))
	if prim.write_at(r.vfs, rm.span_fd, rec[:], i64(rm.span_seq & 1) * SPAN_REC) == .None && durable {
		prim.datasync(r.vfs, rm.span_fd)
	}
}

@(private)
_feed_subscribe :: proc(r: ^Replicator, from_start: bool) {
	pats := make([dynamic]Feed_Pattern, context.temp_allocator)
	for id in prim.sorted_keys(r.remotes) {
		if id not_in r.remotes {
			continue
		}
		rm := r.remotes[id]
		if _following(rm) && !rm.grouped && !(id in r.answers) {
			append(&pats, Feed_Pattern{kind = .Exact, bytes = cast([32]u8)id})
		}
	}
	for id in prim.sorted_keys(r.answers) {
		append(&pats, Feed_Pattern{kind = .Exact, bytes = cast([32]u8)id})
	}
	for suffix in prim.sorted_keys(r.groups) {
		p := Feed_Pattern{kind = .Suffix}
		sfx := suffix
		copy(p.bytes[:16], sfx[:])
		append(&pats, p)
	}
	slice.sort_by(pats[:], proc(a, b: Feed_Pattern) -> bool {
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		x, y := a.bytes, b.bytes
		return mem.compare(x[:], y[:]) < 0
	})
	from := u64(0) if from_start || r.feed_cursor < 0 else u64(r.feed_cursor)
	client_feed_follow(&r.client, from, pats[:], true, false, true)
}

@(private)
_is_boundary :: proc(rm: ^Remote, x: i64) -> bool {
	for c in rm.claims {
		if c == x {
			return true
		}
	}
	return _proven_boundary(rm, x)
}

@(private)
_proven_boundary :: proc(rm: ^Remote, x: i64) -> bool {
	if x == 0 || x == rm.relay_len {
		return true
	}
	for h in journal.replica_have(&rm.rep) {
		if h.from == x || h.to == x {
			return true
		}
		if h.from > x {
			break
		}
	}
	return false
}

@(private)
_Check :: enum u8 {
	Ok,
	Bad,
	Unknown,
}

@(private)
_Checker :: struct {
	on:      bool,
	plain:   bool,
	skey:    journal.Key_Provider,
	tree:    journal.Key_Provider,
	known:   bool,
	scratch: [dynamic]u8,
}

@(private)
_record_check :: proc(k: ^_Checker, rec: []u8, off: i64) -> _Check {
	body, berr := journal.record_body(rec)
	if berr != .None {
		return .Bad
	}
	switch journal.classify(rec, off) {
	case .Invalid:
		return .Bad
	case .Redacted:
		return .Ok
	case .Plain:
		return .Ok if !k.on || k.plain else .Bad
	case .Sealed:
		if !k.on {
			return .Ok
		}
		if k.plain {
			return .Bad
		}
	}
	for kp, i in ([2]journal.Key_Provider{k.skey, k.tree}) {
		if kp.key == nil {
			continue
		}
		if journal.is_sig(body) {
			if tag, ok := journal.sig_tag(body, off, kp); ok && string(tag[:]) == string(rec[4:journal.HEADER]) {
				return .Ok
			}
		}
		resize(&k.scratch, len(rec))
		copy(k.scratch[:], rec)
		err := journal.open_record(k.scratch[:], off, kp)
		crypto.zero_explicit(raw_data(k.scratch[:]), len(k.scratch))
		if err == .None || (err == .No_Key && i == 1) {
			return .Ok
		}
	}
	return .Bad if k.known else .Unknown
}

@(private)
_stage_check :: proc(r: ^Replicator, rm: ^Remote, final: bool, stream_len: i64) -> (lo, hi, rest: int, bad: bool) {
	data := r.stage[:]
	at := r.stage_at
	k := _Checker {
		plain   = rm.plain,
		known   = true,
		scratch = make([dynamic]u8, context.temp_allocator),
	}
	if r.cfg.keys != nil {
		k.on = true
		k.skey = static_provider(&rm.skey)
		sealing, tree := r.cfg.keys(r.cfg.user, rm.device, rm.name, rm.epoch, rm.id)
		switch sealing {
		case .Unknown:
			k.known = false
		case .Stream_Key:
		case .Key_Tree:
			k.tree = tree
		case .Key_Tree_Stale:
			k.tree = tree
			k.known = false
		}
	}
	held := false
	probed := false
	if _is_boundary(rm, at) {
		claimed := !_proven_boundary(rm, at)
		pos := 0
		for len(data) - pos >= journal.OVERHEAD {
			n := int(prim.get_u32le(data[pos:]))
			size := n + journal.OVERHEAD
			if n > journal.MAX_BODY || (size <= len(data) - pos && int(prim.get_u32le(data[pos + size - 4:])) != n) {
				if pos == 0 && claimed {
					_unclaim(rm, at)
					return
				}
				return 0, pos, 0, true
			}
			if size > len(data) - pos {
				break
			}
			switch _record_check(&k, data[pos:][:size], at + i64(pos)) {
			case .Ok:
			case .Bad:
				if !_key_probe(r, rm, &k) {
					return 0, pos, 0, true
				}
				held = true
				probed = true
			case .Unknown:
				held = true
			}
			if held {
				break
			}
			pos += size
		}
		if held {
			if !probed {
				_keys_needed(r, rm)
			}
			return 0, pos, 0, false
		}
		if !final {
			rest = len(data) - pos
		}
		return 0, pos, rest, false
	}
	if !final {
		return 0, 0, len(data), false
	}
	end := at + i64(len(data))
	if end != stream_len && !_is_boundary(rm, end) {
		return
	}
	pos := len(data)
	for pos >= journal.OVERHEAD {
		n := int(prim.get_u32le(data[pos - 4:]))
		if n > journal.MAX_BODY {
			return pos, len(data), 0, true
		}
		start := pos - n - journal.OVERHEAD
		if start < 0 {
			break
		}
		if int(prim.get_u32le(data[start:])) != n {
			return pos, len(data), 0, true
		}
		switch _record_check(&k, data[start:pos], at + i64(start)) {
		case .Ok:
		case .Bad:
			if !_key_probe(r, rm, &k) {
				return pos, len(data), 0, true
			}
			return pos, len(data), 0, false
		case .Unknown:
			_keys_needed(r, rm)
			return pos, len(data), 0, false
		}
		pos = start
	}
	return pos, len(data), 0, false
}

@(private)
_key_probe :: proc(r: ^Replicator, rm: ^Remote, k: ^_Checker) -> (holding: bool) {
	if k.tree.data == nil || !k.known || rm.is_head {
		return false
	}
	v := (^Key_Tree)(k.tree.data).version
	if rm.key_seen && v <= rm.key_probe {
		if rm.key_wait {
			rm.keys_wait = true
			return true
		}
		return false
	}
	kn, kerr := keys_stream_name(rm.name)
	if kerr != .None {
		return false
	}
	hname, herr := keys_head_name(kn)
	if herr != .None {
		return false
	}
	rm.key_head = stream_id(&rm.scope, rm.device, hname, 0)
	rm.key_from = r.rx_holder
	rm.key_probe = v
	rm.key_seen = true
	rm.key_wait = true
	rm.keys_wait = true
	_keys_head_start(r, &rm.scope, rm.device, kn, v + 1)
	return true
}

@(private)
_key_probe_answered :: proc(r: ^Replicator, head: ^Remote, epoch: u64, ok: bool) {
	list := make([dynamic]^Remote, context.temp_allocator)
	for mk1_ in prim.sorted_keys(r.remotes) {
		if mk1_ not_in r.remotes {
			continue
		}
		rm := r.remotes[mk1_]
		if rm.key_wait && rm.key_head == head.id && !(ok && epoch > rm.key_probe) {
			append(&list, rm)
		}
	}
	for rm in list {
		rm.key_wait = false
		if !rm.keys_wait {
			continue
		}
		rm.keys_wait = false
		_kwait_release(r, rm)
		_key_held_report(r, rm)
		if r.phase == .Ready {
			_remote_pull(r, rm)
			_remote_settle(r, rm)
		}
	}
}

@(private)
_key_held_report :: proc(r: ^Replicator, rm: ^Remote) {
	if len(rm.kheld) == 0 {
		return
	}
	saved := r.stage
	saved_at := r.stage_at
	r.stage = rm.kheld
	r.stage_at = rm.kheld_at
	rm.kheld = make([dynamic]u8, r.allocator)
	lo, hi, _, bad := _stage_check(r, rm, true, rm.relay_len)
	if hi > lo {
		if err := _stage_write(r, rm, r.stage_at + i64(lo), r.stage[lo:hi]); err == .None {
			_remote_landed(r, rm, r.stage_at + i64(lo), r.stage_at + i64(hi), rm.relay_len)
		}
	}
	if bad {
		holder := r.rx_holder
		r.rx_holder = rm.key_from
		_tamper(r, rm)
		r.rx_holder = holder
	}
	delete(r.stage)
	r.stage = saved
	r.stage_at = saved_at
}

replicator_keys_ready :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) {
	_enter(r)
	defer _leave(r)
	id := stream_id(scope, device, name, epoch)
	rm, ok := r.remotes[id]
	if !ok {
		return
	}
	rm.key_wait = false
	if !rm.keys_wait {
		_pending_apply(r, rm)
		_tamper_release(r, rm)
		_repl_flush(r)
		return
	}
	_pending_apply(r, rm)
	rm.keys_wait = false
	rm.tamper_hold = false
	rm.tamper_retried = false
	_kwait_release(r, rm)
	_held_apply(r, rm)
	if r.phase == .Ready {
		_remote_pull(r, rm)
		_remote_settle(r, rm)
		_arc_drive(r, rm)
		_repl_flush(r)
	}
}

@(private)
_keys_same :: proc(existing: []u8, tree: ^Key_Tree, seal: ^[32]u8, id: Stream_Id, body: []u8) -> bool {
	if seal == nil {
		return string(existing) == string(body)
	}
	t: Key_Tree
	if keys_record_open(&t, existing, seal, id, tree.version) != .None {
		return false
	}
	defer keytree_destroy(&t)
	a := make([dynamic]u8, context.temp_allocator)
	b := make([dynamic]u8, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(a), len(a))
	defer crypto.zero_explicit(raw_data(b), len(b))
	if keytree_encode(&t, &a) != .None || keytree_encode(tree, &b) != .None {
		return false
	}
	return string(a[:]) == string(b[:])
}

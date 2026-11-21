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
	if r.phase != .Ready {
		return .Closed
	}
	client_redact(&r.client, stream_id(scope, device, name, epoch), from, to) or_return
	_repl_flush(r)
	return .None
}

replicator_zero_replica :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, from, to: i64) -> Error {
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
_verdict :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) -> Verdict {
	if rm.quarantined {
		return .Equivocation
	}
	if r.cfg.verify == nil {
		return .Accept
	}
	before := rm.span
	req := Verify_Request {
		device  = rm.device,
		name    = rm.name,
		epoch   = rm.epoch,
		stream  = rm.id,
		replica = &rm.rep,
		from    = from,
		to      = to,
		span    = &rm.span,
		span_ok = &rm.span_ok,
	}
	v := r.cfg.verify(r.cfg.user, &req)
	if v == .Accept && rm.span_ok && (rm.span.off != before.off || rm.span.head != before.head) {
		_span_save(r, rm)
	}
	return v
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

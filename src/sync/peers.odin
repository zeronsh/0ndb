#+build linux, darwin, windows
package osync

import "../journal"
import "../prim"

Pull_Flight :: struct {
	from:   i64,
	to:     i64,
	holder: Device_Id,
	tag:    u64,
}

Serve_Req :: struct {
	requester: Device_Id,
	tag:       u64,
	id:        Stream_Id,
	from:      i64,
	to:        i64,
}

@(private)
SERVES_INFLIGHT :: 4
@(private)
FLOOR_META_MAGIC :: 0x6174_656d_6264_6e30
@(private)
SERVE_SPAN_MAX :: 8 * 1024 * 1024

@(private)
_floor_meta_write :: proc(r: ^Replicator, fd: prim.Fd, name, path: string) {
	if len(name) > 0xffff || len(path) > 0xffff {
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u64le(&w, FLOOR_META_MAGIC)
	prim.write_u16le(&w, u16(len(name)))
	prim.write_raw(&w, transmute([]u8)name)
	prim.write_u16le(&w, u16(len(path)))
	prim.write_raw(&w, transmute([]u8)path)
	if w.err != .None {
		return
	}
	prim.write_at(r.vfs, fd, buf[:], SLOTS_SIZE)
}

@(private)
_floor_meta_read :: proc(r: ^Replicator, id: Stream_Id, allocator := context.temp_allocator) -> (name, path: string, floor: i64, ok: bool) {
	pbuf: prim.Path_Buf = ---
	fd, oerr := prim.open_file(r.vfs, _floor_path(r, &pbuf, id))
	if oerr != .None {
		return
	}
	defer prim.close_file(r.vfs, fd)
	newest, _, count, serr := slots_read(r.vfs, fd)
	if serr == .None && count > 0 {
		floor = newest.value
	}
	b: [8 + 2 + 0xffff + 2 + 0xffff]u8
	n, rerr := prim.read_at(r.vfs, fd, b[:], SLOTS_SIZE)
	if rerr != .None || n < 12 {
		return
	}
	rd := prim.reader(b[:n])
	if prim.read_u64le(&rd) != FLOOR_META_MAGIC {
		return
	}
	nl := int(prim.read_u16le(&rd))
	nb := prim.read_raw(&rd, nl)
	pl := int(prim.read_u16le(&rd))
	pb := prim.read_raw(&rd, pl)
	if !prim.reader_ok(&rd) {
		return
	}
	ne, e1 := _clone_string(string(nb), allocator)
	pe, e2 := _clone_string(string(pb), allocator)
	if e1 != .None || e2 != .None {
		return
	}
	return ne, pe, floor, true
}

@(private)
_local_note :: proc(r: ^Replicator, l: ^Local, limit: i64) {
	if client_note(&r.client, l.id, limit) != .None {
		return
	}
	l.inflight = limit - l.cursor
	l.noting = true
	r.uploading += 1
}

@(private)
_on_noted :: proc(r: ^Replicator, ev: ^Event) {
	id := Stream_Id(ev.id)
	if l, ok := r.locals[id]; ok && (l.noting || l.inflight > 0) {
		if l.inflight > 0 {
			r.uploading -= 1
		}
		l.inflight = 0
		l.noting = false
		if ev.length > l.durable {
			_local_fatal(r, l, .Conflict, ev.length)
			return
		}
		if ev.base < ev.length {
			l.hollow = false
		}
		if ev.length > l.cursor {
			if err := _local_advance(r, l, ev.length); err != .None {
				_local_fatal(r, l, err, ev.length)
				return
			}
		} else if ev.length < l.cursor && ev.base < ev.length {
			l.cursor = ev.length
		}
		_promote_on_noted(r, id, ev.base, ev.length)
		_local_pump(r, l)
		return
	}
	_promote_on_noted(r, id, ev.base, ev.length)
}

@(private)
_on_hollow :: proc(r: ^Replicator, ev: ^Event) {
	id := Stream_Id(ev.id)
	if l, lok := r.locals[id]; lok && l.verifying && ev.base > l.verify_at {
		_local_verify_hollow(r, l, ev.base)
	}
	rm, ok := r.remotes[id]
	if !ok {
		return
	}
	rm.trimmed = ev.trimmed
	_remote_base(r, rm, ev.base, ev.length)
	for x, i in rm.refused {
		if x == rm.device {
			unordered_remove(&rm.refused, i)
			rm.unavail = false
			break
		}
	}
	for i := 0; i < len(rm.inflight); {
		f := &rm.inflight[i]
		if f.from >= 0 && f.from < ev.base {
			if f.to <= ev.base {
				ordered_remove(&rm.inflight, i)
				continue
			}
			f.from = ev.base
		}
		i += 1
	}
	_remote_pull(r, rm)
	_remote_settle(r, rm)
}

@(private)
_local_verify_hollow :: proc(r: ^Replicator, l: ^Local, base: i64) {
	l.verifying = false
	clear(&l.verify)
	if r.rx_local == l {
		r.rx_local = nil
	}
	to := min(base, l.ahead)
	if to > l.cursor {
		if err := _local_advance(r, l, to); err != .None {
			_local_fatal(r, l, err, to)
			return
		}
	}
	_local_verify_next(r, l)
}

@(private)
_remote_base :: proc(r: ^Replicator, rm: ^Remote, base, length: i64) {
	if base != rm.base {
		rm.base_checked = false
	}
	rm.base = base
	if length > rm.relay_len {
		rm.relay_len = length
		if length > journal.replica_length(&rm.rep) {
			journal.replica_set_length(&rm.rep, length)
		}
	}
}

@(private)
_remote_hollow_seen :: proc(r: ^Replicator, id: Stream_Id, length: i64) {
	if rm, ok := r.remotes[id]; ok && length >= rm.base {
		rm.base = length
		rm.base_checked = false
	}
}

@(private)
_holder_ok :: proc(r: ^Replicator, rm: ^Remote, d: Device_Id) -> bool {
	if d == r.cfg.self {
		return false
	}
	for x in rm.refused {
		if x == d {
			return false
		}
	}
	p, ok := r.presence[d]
	return ok && p.up
}

@(private)
_holders :: proc(r: ^Replicator, rm: ^Remote, out: ^[dynamic]Device_Id) {
	append(out, rm.device)
	if g, ok := r.groups[stream_id_suffix(rm.id)]; ok {
		for m in g.members {
			dup := false
			for x in out {
				if x == m {
					dup = true
					break
				}
			}
			if !dup && m != r.cfg.self {
				append(out, m)
			}
		}
	}
}

@(private)
_pick_holder :: proc(r: ^Replicator, rm: ^Remote) -> (d: Device_Id, ok: bool) {
	cands := make([dynamic]Device_Id, context.temp_allocator)
	_holders(r, rm, &cands)
	best := -1
	load := max(int)
	for c, i in cands {
		if !_holder_ok(r, rm, c) {
			continue
		}
		n := 0
		for p in rm.pulls {
			if p.holder == c {
				n += 1
			}
		}
		if c == rm.suspect {
			n += 1 << 20
		}
		if n < load {
			best, load = i, n
		}
	}
	if best < 0 {
		return
	}
	return cands[best], true
}

@(private)
_pull_range :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) -> bool {
	if to <= from || r.phase != .Ready {
		return false
	}
	for p in rm.pulls {
		if p.from <= from && p.to >= to {
			return true
		}
	}
	holder, ok := _pick_holder(r, rm)
	if !ok {
		_unavailable(r, rm, from, to)
		return false
	}
	r.pull_tag += 1
	tag := r.pull_tag
	if client_pull(&r.client, holder, tag, rm.id, from, to) != .None {
		return false
	}
	append(&rm.pulls, Pull_Flight{from = from, to = to, holder = holder, tag = tag})
	rm.unavail = false
	r.read_reqs += 1
	return true
}

@(private)
PULL_WINDOW :: 4

@(private)
_pull_ahead :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	at := from
	for at < to && len(rm.pulls) < PULL_WINDOW {
		hi := min(to, at + STAGE_MAX)
		gap, missing := journal.replica_missing(&rm.rep, at, hi)
		if !missing {
			at = hi
			continue
		}
		if !_pull_range(r, rm, gap.from, min(gap.to, gap.from + STAGE_MAX)) {
			return
		}
		at = min(gap.to, gap.from + STAGE_MAX)
	}
}

@(private)
_unavailable :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	if !rm.base_checked {
		rm.base_checked = true
		if client_read(&r.client, rm.id, from, to) == .None {
			append(&rm.inflight, journal.Range{from, to})
		}
		return
	}
	if rm.unavail {
		return
	}
	rm.unavail = true
	cands := make([dynamic]Device_Id, context.temp_allocator)
	_holders(r, rm, &cands)
	meta := make([]u8, 16 * len(cands), context.temp_allocator)
	for c, i in cands {
		v := c
		copy(meta[i * 16:], v[:])
	}
	_emit(r, Repl_Event{kind = .Unavailable, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = from, to = to, length = rm.relay_len, meta = meta})
}

@(private)
_pull_drop :: proc(r: ^Replicator, rm: ^Remote, i: int) {
	ordered_remove(&rm.pulls, i)
}

@(private)
_on_unserved :: proc(r: ^Replicator, ev: ^Event) {
	if _pipe_on_unserved(r, ev) {
		_repl_flush(r)
		return
	}
	rm, ok := r.remotes[Stream_Id(ev.id)]
	if !ok {
		return
	}
	for p, i in rm.pulls {
		if p.tag == ev.tag && p.holder == ev.device {
			_pull_drop(r, rm, i)
			append(&rm.refused, ev.device)
			_remote_pull_retry(r, rm)
			return
		}
	}
}

@(private)
_remote_pull_retry :: proc(r: ^Replicator, rm: ^Remote) {
	_remote_pull(r, rm)
	_remote_settle(r, rm)
}

@(private)
_peers_presence :: proc(r: ^Replicator, d: Device_Id, up: bool) {
	for id in _sorted_ids(r.remotes) {
		rm, ok := r.remotes[id]
		if !ok {
			continue
		}
		touched := false
		if up {
			if rm.unavail || len(rm.refused) > 0 {
				clear(&rm.refused)
				rm.unavail = false
				rm.base_checked = false
				touched = true
			}
		} else {
			for i := 0; i < len(rm.pulls); {
				if rm.pulls[i].holder == d {
					_pull_drop(r, rm, i)
					touched = true
					continue
				}
				i += 1
			}
		}
		if touched {
			_remote_pull_retry(r, rm)
		}
	}
	_pipe_presence(r, d, up)
	_repl_flush(r)
}

@(private)
_peer_landed :: proc(rm: ^Remote, tag: u64, final: bool, to: i64) {
	for p, i in rm.pulls {
		if p.tag != tag {
			continue
		}
		if final {
			ordered_remove(&rm.pulls, i)
		}
		return
	}
}

@(private)
_read_range :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	if to <= from {
		return
	}
	if from < rm.base {
		lo, hi := from, min(to, rm.base)
		merged := false
		for &w in rm.wants {
			if w.from <= hi && lo <= w.to {
				w.from = min(w.from, lo)
				w.to = max(w.to, hi)
				merged = true
				break
			}
		}
		if !merged {
			append(&rm.wants, journal.Range{lo, hi})
		}
	}
	if to > rm.base {
		client_read(&r.client, rm.id, max(from, rm.base), to)
	}
}

@(private)
_on_served :: proc(r: ^Replicator, ev: ^Event) {
	if _pipe_on_served(r, ev) {
		return
	}
	rm, ok := r.remotes[Stream_Id(ev.id)]
	if ev.first {
		if !ok {
			r.rx_holder = {}
			r.rx_tag = 0
			r.rx_skip = true
			return
		}
		known := false
		for p in rm.pulls {
			if p.tag == ev.tag && p.holder == ev.device {
				known = true
				break
			}
		}
		r.rx_skip = !known
		if !known {
			return
		}
		r.rx_holder = ev.device
		r.rx_tag = ev.tag
	}
	if r.rx_skip {
		return
	}
	d := ev^
	d.kind = .Data
	if ok {
		d.length = max(d.length, rm.relay_len, ev.at)
	}
	_on_data(r, &d)
	if ev.last {
		if ok {
			_peer_landed(rm, ev.tag, ev.final, ev.at)
			if ev.final {
				_remote_settle(r, rm)
			}
		}
		r.rx_holder = {}
		r.rx_tag = 0
	}
}

@(private)
_peer_tampered :: proc(r: ^Replicator, rm: ^Remote) -> bool {
	if r.rx_holder == {} {
		return false
	}
	h := r.rx_holder
	rm.suspect = h
	rm.tamper_hold = true
	if r.retry == 0 {
		r.retry = prim.timer(r.loop, RETRY_MS, r, _on_retry)
	}
	for i := 0; i < len(rm.pulls); {
		if rm.pulls[i].holder == h {
			ordered_remove(&rm.pulls, i)
			continue
		}
		i += 1
	}
	r.peer_tampered += 1
	_emit(r, Repl_Event{kind = .Peer_Misbehaving, err = .Corrupt, device = h, name = rm.name, epoch = rm.epoch, stream = rm.id})
	return true
}

@(private)
_on_pulled :: proc(r: ^Replicator, ev: ^Event) {
	if len(r.serves) + len(r.parked) >= 4096 {
		_serve_none(r, Serve_Req{requester = ev.device, tag = ev.tag, id = Stream_Id(ev.id)})
		return
	}
	append(&r.serves, Serve_Req{requester = ev.device, tag = ev.tag, id = Stream_Id(ev.id), from = ev.at, to = ev.length})
}

@(private)
_serve_none :: proc(r: ^Replicator, q: Serve_Req) {
	dst, err := client_serve_reserve(&r.client, q.requester, q.tag, q.id, q.from, 0)
	if err != .None {
		return
	}
	_ = dst
	client_serve_commit(&r.client, 0, 0, SERVE_NONE | SERVE_FINAL)
}

@(private)
_serves_pump :: proc(r: ^Replicator) {
	if r.phase != .Ready {
		return
	}
	for i := 0; i < len(r.parked) && client_queued(&r.client) < OUT_HIGH; {
		q := r.parked[i]
		if _serve(r, q) == .Later {
			i += 1
			continue
		}
		ordered_remove(&r.parked, i)
	}
	for len(r.serves) > 0 && client_queued(&r.client) < OUT_HIGH {
		q := r.serves[0]
		ordered_remove(&r.serves, 0)
		if _serve(r, q) == .Later {
			append(&r.parked, q)
		}
	}
}

@(private)
Serve_Result :: enum u8 {
	Done,
	Later,
}

@(private)
_serve :: proc(r: ^Replicator, q: Serve_Req) -> Serve_Result {
	if q.to > q.from && q.to - q.from <= SERVE_SPAN_MAX {
		if stream_device(q.id) != r.cfg.self {
			if _serve_replica(r, q) || _serve_object(r, q) {
				return .Done
			}
		} else if l, has := r.locals[q.id]; has && q.from >= l.floor {
			if q.from < l.durable && !l.fatal && !l.superseded && !l.blocked {
				return .Later
			}
		} else if _serve_own(r, q) {
			return .Done
		}
	}
	_serve_none(r, q)
	return .Done
}

@(private)
_serve_replica :: proc(r: ^Replicator, q: Serve_Req) -> bool {
	rep: ^journal.Replica
	tmp: journal.Replica
	opened := false
	if rm, ok := r.remotes[q.id]; ok {
		rep = &rm.rep
	} else {
		pbuf: prim.Path_Buf = ---
		path := _replica_path(r, &pbuf, q.id)
		if !prim.exists(r.vfs, path) {
			return false
		}
		if journal.replica_open(&tmp, r.vfs, path, context.temp_allocator) != .None {
			return false
		}
		rep = &tmp
		opened = true
	}
	defer if opened {
		journal.replica_close(&tmp)
	}
	if !journal.replica_covers(rep, q.from, q.to) {
		return false
	}
	buf, aerr := make([]u8, int(q.to - q.from), context.temp_allocator)
	if aerr != nil {
		return false
	}
	got, rerr := prim.read_at(r.vfs, rep.fd, buf, q.from)
	if rerr != .None || i64(got) != q.to - q.from {
		return false
	}
	_serve_send(r, q, q.from, buf, journal.replica_length(rep))
	return true
}

@(private)
_serve_own :: proc(r: ^Replicator, q: Serve_Req) -> bool {
	name, path: string
	limit: i64
	l, has := r.locals[q.id]
	if has {
		name, path, limit = l.name, l.path, l.floor
	} else {
		ok: bool
		name, path, limit, ok = _floor_meta_read(r, q.id)
		if !ok {
			return false
		}
	}
	fd, oerr := prim.open_file(r.vfs, path)
	if oerr != .None {
		return false
	}
	defer prim.close_file(r.vfs, fd)
	to := min(q.to, limit)
	if to <= q.from {
		return false
	}
	start, end, ok := _record_span(r, fd, q.from, to, limit)
	if !ok {
		return false
	}
	buf, aerr := make([]u8, int(end - start), context.temp_allocator)
	if aerr != nil {
		return false
	}
	got, rerr := prim.read_at(r.vfs, fd, buf, start)
	if rerr != .None || i64(got) != end - start || journal.record_bounds(buf) != len(buf) {
		return false
	}
	if has {
		if _wire_form(l, buf, start) != .None {
			return false
		}
	} else if r.cfg.seal == nil || r.cfg.seal(r.cfg.user, name, q.id, buf, start) != .None {
		return false
	}
	_serve_send(r, q, start, buf, limit)
	return true
}

@(private)
_record_at :: proc(r: ^Replicator, fd: prim.Fd, at: i64, limit: i64) -> (size: i64, ok: bool) {
	head: [4]u8
	if n, err := prim.read_at(r.vfs, fd, head[:], at); err != .None || n < 4 {
		return
	}
	size = i64(prim.get_u32le(head[:])) + journal.OVERHEAD
	if size - journal.OVERHEAD > journal.MAX_BODY || at + size > limit {
		return
	}
	tail: [4]u8
	if n, err := prim.read_at(r.vfs, fd, tail[:], at + size - 4); err != .None || n < 4 || i64(prim.get_u32le(tail[:])) + journal.OVERHEAD != size {
		return
	}
	rec, aerr := make([]u8, int(size), context.temp_allocator)
	if aerr != nil {
		return
	}
	defer delete(rec, context.temp_allocator)
	if n, err := prim.read_at(r.vfs, fd, rec, at); err != .None || i64(n) != size {
		return
	}
	e := journal.check_record(rec, at)
	return size, e == .None || e == .Redacted
}

@(private)
_record_span :: proc(r: ^Replicator, fd: prim.Fd, from, to: i64, limit: i64) -> (start, end: i64, ok: bool) {
	{
		if sz, good := _record_at(r, fd, from, limit); good {
			start = from
			end = from + sz
			for end < to {
				n, g := _record_at(r, fd, end, limit)
				if !g {
					break
				}
				end += n
			}
			return start, end, true
		}
	}
	if first, found := _first_boundary(r, fd, from, min(to, limit), limit); found {
		start = first
		end = first
		for end < to {
			n, g := _record_at(r, fd, end, limit)
			if !g {
				break
			}
			end += n
		}
		if end > start {
			return start, end, true
		}
	}
	tail: [4]u8
	if to < journal.OVERHEAD {
		return
	}
	if n, err := prim.read_at(r.vfs, fd, tail[:], to - 4); err != .None || n < 4 {
		return
	}
	first := to - i64(prim.get_u32le(tail[:])) - journal.OVERHEAD
	if first < 0 {
		return
	}
	if sz, good := _record_at(r, fd, first, limit); !good || first + sz != to {
		return
	}
	start = first
	end = to
	for start > from {
		if start < journal.OVERHEAD {
			break
		}
		if n, err := prim.read_at(r.vfs, fd, tail[:], start - 4); err != .None || n < 4 {
			break
		}
		prev := start - i64(prim.get_u32le(tail[:])) - journal.OVERHEAD
		if prev < 0 {
			break
		}
		if sz, good := _record_at(r, fd, prev, limit); !good || prev + sz != start {
			break
		}
		start = prev
	}
	return start, end, true
}

@(private)
_first_boundary :: proc(r: ^Replicator, fd: prim.Fd, from, to: i64, limit: i64) -> (at: i64, ok: bool) {
	if to - from < journal.OVERHEAD {
		return
	}
	buf, aerr := make([]u8, int(to - from), context.temp_allocator)
	if aerr != nil {
		return
	}
	defer delete(buf, context.temp_allocator)
	got, rerr := prim.read_at(r.vfs, fd, buf, from)
	if rerr != .None || i64(got) != to - from {
		return
	}
	for p := 0; p + journal.OVERHEAD <= len(buf); p += 1 {
		n := int(prim.get_u32le(buf[p:]))
		if n > journal.MAX_BODY {
			continue
		}
		end := p + n + journal.OVERHEAD
		if end <= len(buf) {
			if int(prim.get_u32le(buf[end - 4:])) != n {
				continue
			}
			e := journal.check_record(buf[p:end], from + i64(p))
			if e == .None || e == .Redacted {
				return from + i64(p), true
			}
			continue
		}
		cand := from + i64(p)
		if cand + i64(n) + journal.OVERHEAD > limit {
			continue
		}
		tail: [4]u8
		if k, err := prim.read_at(r.vfs, fd, tail[:], cand + i64(n) + journal.OVERHEAD - 4); err != .None || k < 4 || int(prim.get_u32le(tail[:])) != n {
			continue
		}
		if _, good := _record_at(r, fd, cand, limit); good {
			return cand, true
		}
	}
	return
}

@(private)
_serve_send :: proc(r: ^Replicator, q: Serve_Req, at: i64, data: []u8, length: i64) {
	pos := 0
	for {
		n := min(len(data) - pos, SERVE_MAX)
		if pos + n < len(data) {
			k := journal.record_bounds(data[pos:pos + n])
			if k > 0 {
				n = k
			}
		}
		dst, err := client_serve_reserve(&r.client, q.requester, q.tag, q.id, at + i64(pos), n)
		if err != .None {
			return
		}
		copy(dst, data[pos:pos + n])
		pos += n
		word := u64(max(length, at + i64(pos))) & SERVE_LEN_MASK
		if pos >= len(data) {
			word |= SERVE_FINAL
		}
		client_serve_commit(&r.client, n, n, word)
		r.served_bytes += i64(n)
		if pos >= len(data) {
			return
		}
	}
}

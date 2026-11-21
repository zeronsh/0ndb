#+build linux, darwin, windows
package osync

import "../journal"
import "../prim"

Promotion_State :: enum u8 {
	Probe,
	Ready,
	Filling,
	Retry,
	Done,
}

Promotion :: struct {
	id:       Stream_Id,
	name:     string,
	epoch:    u64,
	device:   Device_Id,
	own:      bool,
	path:     string,
	target:   i64,
	base:     i64,
	length:   i64,
	state:    Promotion_State,
	sent:     i64,
	hollow:   bool,
	uploaded: i64,
}

@(private)
FILL_CHUNK :: 1024 * 1024

replicator_promote :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, path: string, from: i64) -> Error {
	_enter(r)
	defer _leave(r)
	id := stream_id(scope, device, name, epoch)
	for p in r.promos {
		if p.id == id {
			if from < p.target {
				p.target = max(from, 0)
				if p.state == .Done {
					p.state = .Probe
					p.sent = 0
				}
			}
			_promotions_pump(r)
			_repl_flush(r)
			return .None
		}
	}
	p, aerr := new(Promotion, r.allocator)
	if aerr != nil {
		return .No_Memory
	}
	p.id = id
	p.device = device
	p.epoch = epoch
	p.own = device == r.cfg.self
	p.target = max(from, 0)
	p.base = -1
	nerr, perr: Error
	p.name, nerr = _clone_string(name, r.allocator)
	if p.own {
		p.path, perr = _clone_string(path, r.allocator)
	} else {
		pbuf: prim.Path_Buf = ---
		p.path, perr = _clone_string(_replica_path(r, &pbuf, id), r.allocator)
	}
	if nerr != .None || perr != .None {
		_promotion_free(r, p)
		return .No_Memory
	}
	append(&r.promos, p)
	_promotions_pump(r)
	_repl_flush(r)
	return .None
}

replicator_promoting :: proc(r: ^Replicator, scope: ^Scope, name: string) -> bool {
	suffix := stream_suffix(scope, name, 0)
	for p in r.promos {
		if p.state != .Done && stream_id_suffix(p.id) == suffix {
			return true
		}
	}
	return false
}

replicator_promotions :: proc "contextless" (r: ^Replicator) -> (pending: int, uploaded: i64) {
	for p in r.promos {
		if p.state != .Done {
			pending += 1
		}
		uploaded += p.uploaded
	}
	return
}

@(private)
_promotion_free :: proc(r: ^Replicator, p: ^Promotion) {
	delete(p.name, r.allocator)
	delete(p.path, r.allocator)
	free(p, r.allocator)
}

@(private)
_promotion_find :: proc(r: ^Replicator, id: Stream_Id) -> (^Promotion, int) {
	for p, i in r.promos {
		if p.id == id {
			return p, i
		}
	}
	return nil, -1
}

@(private)
_promotions_reset :: proc(r: ^Replicator) {
	for p in r.promos {
		if p.state != .Done {
			p.state = .Probe
			p.base = -1
			p.sent = 0
		}
	}
}

@(private)
_promote_on_noted :: proc(r: ^Replicator, id: Stream_Id, base, length: i64) {
	p, _ := _promotion_find(r, id)
	if p == nil || p.state == .Done {
		return
	}
	p.hollow = true
	if p.state == .Filling && base < p.base {
		p.uploaded += p.base - base
	}
	p.base = base
	p.length = length
	p.state = .Ready
}

@(private)
_promote_on_probed :: proc(r: ^Replicator, id: Stream_Id, length: i64) {
	p, _ := _promotion_find(r, id)
	if p == nil || p.state != .Probe || p.sent != -1 {
		return
	}
	if !p.hollow {
		p.base = 0
		p.length = length
	}
	p.state = .Ready
}

@(private)
_promote_on_refused :: proc(r: ^Replicator, id: Stream_Id, code: Code) -> bool {
	p, _ := _promotion_find(r, id)
	if p == nil || p.state != .Filling {
		return false
	}
	if code == .Busy || code == .Io {
		p.state = .Retry
		if r.retry == 0 {
			r.retry = prim.timer(r.loop, RETRY_MS, r, _on_retry)
		}
		return true
	}
	_promotion_done(r, p, false)
	return true
}

@(private)
_promotion_done :: proc(r: ^Replicator, p: ^Promotion, ok: bool) {
	p.state = .Done
	_emit(r, Repl_Event{kind = .Promoted, err = .None if ok else .Refused, device = p.device, name = p.name, epoch = p.epoch, stream = p.id, from = p.base, to = p.length, length = p.uploaded})
}

@(private)
_promotions_pump :: proc(r: ^Replicator) {
	if r.phase != .Ready {
		return
	}
	for i := 0; i < len(r.promos); {
		p := r.promos[i]
		switch p.state {
		case .Probe:
			if p.sent != -1 {
				p.hollow = false
				ids := [1]Stream_Id{p.id}
				if client_probe(&r.client, ids[:]) == .None {
					p.sent = -1
				}
			}
		case .Retry:
			p.state = .Ready
			p.sent = 0
			_promote_step(r, p)
		case .Ready:
			_promote_step(r, p)
		case .Filling:
		case .Done:
			ordered_remove(&r.promos, i)
			_promotion_free(r, p)
			continue
		}
		i += 1
	}
}

@(private)
_promote_step :: proc(r: ^Replicator, p: ^Promotion) {
	if p.base <= p.target || p.base <= 0 {
		_promotion_done(r, p, true)
		return
	}
	if client_queued(&r.client) >= OUT_HIGH {
		return
	}
	if p.own {
		if l, ok := r.locals[p.id]; ok && (l.inflight > 0 || l.noting) {
			return
		}
	}
	fd, oerr := prim.open_file(r.vfs, p.path)
	if oerr != .None {
		_promotion_done(r, p, false)
		return
	}
	defer prim.close_file(r.vfs, fd)
	start, ok := _back_span(r, fd, p, p.base, max(p.target, p.base - FILL_CHUNK))
	if !ok || start >= p.base {
		_promotion_done(r, p, false)
		return
	}
	n := int(p.base - start)
	dst, err := client_fill_reserve(&r.client, p.id, start, n)
	if err != .None {
		return
	}
	got, rerr := prim.read_at(r.vfs, fd, dst, start)
	good := rerr == .None && got == n && journal.record_bounds(dst) == n
	if good && p.own {
		if l, has := r.locals[p.id]; has {
			good = _wire_form(l, dst, start) == .None
		} else {
			good = r.cfg.seal != nil && r.cfg.seal(r.cfg.user, p.name, p.id, dst, start) == .None
		}
	}
	if !good {
		client_fill_commit(&r.client, p.id, n, 0)
		_promotion_done(r, p, false)
		return
	}
	client_fill_commit(&r.client, p.id, n, n)
	p.state = .Filling
	p.sent = start
}

@(private)
_back_span :: proc(r: ^Replicator, fd: prim.Fd, p: ^Promotion, end: i64, lowest: i64) -> (start: i64, ok: bool) {
	floor := lowest
	if !p.own {
		rep: journal.Replica
		if journal.replica_open(&rep, r.vfs, p.path, context.temp_allocator) != .None {
			return
		}
		defer journal.replica_close(&rep)
		held := false
		for h in journal.replica_have(&rep) {
			if h.from < end && h.to >= end {
				floor = max(floor, h.from)
				held = true
			}
		}
		if !held {
			return
		}
	}
	start = end
	tail: [4]u8
	for start > floor {
		if start < journal.OVERHEAD {
			break
		}
		if n, err := prim.read_at(r.vfs, fd, tail[:], start - 4); err != .None || n < 4 {
			break
		}
		prev := start - i64(prim.get_u32le(tail[:])) - journal.OVERHEAD
		if prev < 0 || end - prev > APPEND_MAX {
			break
		}
		head: [4]u8
		if n, err := prim.read_at(r.vfs, fd, head[:], prev); err != .None || n < 4 || i64(prim.get_u32le(head[:])) + journal.OVERHEAD != start - prev {
			break
		}
		start = prev
	}
	return start, start < end
}

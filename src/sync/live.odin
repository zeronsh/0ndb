#+build linux, darwin, windows
package osync

import "../journal"

Live_Sub :: struct {
	device: Device_Id,
	name:   string,
	epoch:  u64,
}

@(private)
Draft_Flight :: struct {
	tag:    u64,
	id:     Stream_Id,
	device: Device_Id,
	msg:    i64,
}

@(private)
Live_Rx :: struct {
	on:     bool,
	kind:   Event_Kind,
	id:     Stream_Id,
	device: Device_Id,
	tag:    u64,
	msg:    i64,
	at:     i64,
	length: i64,
	final:  bool,
	buf:    [dynamic]u8,
}

replicator_live_on :: proc "contextless" (r: ^Replicator) -> bool {
	return r.phase == .Ready && r.features & FEATURE_LIVE != 0
}

replicator_live_follow :: proc(r: ^Replicator, sc: ^Scope, device: Device_Id, name: string, epoch: u64, on: bool) -> Error {
	_enter(r)
	defer _leave(r)
	if r.lives == nil {
		r.lives = make(map[Stream_Id]Live_Sub, r.allocator)
	}
	id := stream_id(sc, device, name, epoch)
	if !on {
		if s, ok := r.lives[id]; ok {
			delete(s.name, r.allocator)
			delete_key(&r.lives, id)
			if replicator_live_on(r) {
				ids := [1]Stream_Id{id}
				client_follow_live(&r.client, ids[:], false)
				_repl_flush(r)
			}
		}
		return .None
	}
	if _, ok := r.lives[id]; ok {
		return .None
	}
	nm, err := _live_clone(name, r)
	if err != .None {
		return err
	}
	r.lives[id] = Live_Sub{device = device, name = nm, epoch = epoch}
	if replicator_live_on(r) {
		ids := [1]Stream_Id{id}
		client_follow_live(&r.client, ids[:])
		_repl_flush(r)
	}
	return .None
}

replicator_live_watched :: proc(r: ^Replicator, sc: ^Scope, name: string, epoch: u64) -> bool {
	if !replicator_live_on(r) {
		return false
	}
	if r.features & FEATURE_LIVE_WATCH == 0 {
		return true
	}
	_enter(r)
	defer _leave(r)
	if r.interests == nil {
		r.interests = make(map[Stream_Id]bool, r.allocator)
	}
	id := stream_id(sc, r.cfg.self, name, epoch)
	if on, ok := r.interests[id]; ok {
		return on
	}
	r.interests[id] = false
	ids := [1]Stream_Id{id}
	client_live_interest(&r.client, ids[:])
	_repl_flush(r)
	return false
}

replicator_live_unwatch :: proc(r: ^Replicator, sc: ^Scope, name: string, epoch: u64) {
	if r.interests == nil {
		return
	}
	_enter(r)
	defer _leave(r)
	id := stream_id(sc, r.cfg.self, name, epoch)
	if _, ok := r.interests[id]; !ok {
		return
	}
	delete_key(&r.interests, id)
	if replicator_live_on(r) && r.features & FEATURE_LIVE_WATCH != 0 {
		ids := [1]Stream_Id{id}
		client_live_interest(&r.client, ids[:], false)
		_repl_flush(r)
	}
}

replicator_live_send :: proc(r: ^Replicator, sc: ^Scope, name: string, epoch: u64, msg, at: i64, data: []u8) -> bool {
	if !replicator_live_on(r) || client_queued(&r.client) >= OUT_HIGH {
		return false
	}
	_enter(r)
	defer _leave(r)
	id := stream_id(sc, r.cfg.self, name, epoch)
	pos := 0
	for pos < len(data) {
		n := min(len(data) - pos, LIVE_MAX)
		if pos + n < len(data) {
			if k := journal.record_bounds(data[pos:pos + n]); k > 0 {
				n = k
			}
		}
		if client_live(&r.client, id, msg, at + i64(pos), data[pos:pos + n]) != .None {
			return false
		}
		r.live_sent += i64(n)
		pos += n
	}
	_repl_flush(r)
	return true
}

replicator_draft_pull :: proc(r: ^Replicator, sc: ^Scope, device: Device_Id, name: string, epoch: u64, msg, from: i64) -> bool {
	if !replicator_live_on(r) || device == r.cfg.self {
		return false
	}
	_enter(r)
	defer _leave(r)
	id := stream_id(sc, device, name, epoch)
	for f in r.dflights {
		if f.id == id && f.msg == msg {
			return true
		}
	}
	r.pull_tag += 1
	tag := r.pull_tag
	if client_pull_draft(&r.client, device, tag, id, msg, from) != .None {
		return false
	}
	append(&r.dflights, Draft_Flight{tag = tag, id = id, device = device, msg = msg})
	_repl_flush(r)
	return true
}

replicator_draft_answer :: proc(r: ^Replicator, requester: Device_Id, tag: u64, id: Stream_Id, runs: []Live_Run, length: i64) {
	if r.phase != .Ready {
		return
	}
	_enter(r)
	defer _leave(r)
	total := 0
	for x in runs {
		total += len(x.data)
	}
	if total == 0 {
		dst, err := client_serve_reserve(&r.client, requester, tag, id, 0, 0)
		if err == .None {
			_ = dst
			client_serve_commit(&r.client, 0, 0, SERVE_NONE | SERVE_FINAL)
		}
		_repl_flush(r)
		return
	}
	for x, i in runs {
		pos := 0
		for pos < len(x.data) {
			n := min(len(x.data) - pos, SERVE_MAX)
			if pos + n < len(x.data) {
				if k := journal.record_bounds(x.data[pos:pos + n]); k > 0 {
					n = k
				}
			}
			dst, err := client_serve_reserve(&r.client, requester, tag, id, x.at + i64(pos), n)
			if err != .None {
				_repl_flush(r)
				return
			}
			copy(dst, x.data[pos:pos + n])
			pos += n
			word := u64(max(length, 0)) & SERVE_LEN_MASK
			if pos >= len(x.data) && i == len(runs) - 1 {
				word |= SERVE_FINAL
			}
			client_serve_commit(&r.client, n, n, word)
			r.served_bytes += i64(n)
		}
	}
	_repl_flush(r)
}

Live_Run :: struct {
	at:   i64,
	data: []u8,
}

@(private)
_live_clone :: proc(s: string, r: ^Replicator) -> (string, Error) {
	b, err := make([]u8, len(s), r.allocator)
	if err != nil {
		return "", .No_Memory
	}
	copy(b, s)
	return string(b), .None
}

@(private)
_lives_resend :: proc(r: ^Replicator) {
	if !replicator_live_on(r) {
		return
	}
	ids := make([dynamic]Stream_Id, context.temp_allocator)
	for id in r.lives {
		append(&ids, id)
	}
	if len(ids) > 0 {
		client_follow_live(&r.client, ids[:])
	}
	if r.features & FEATURE_LIVE_WATCH == 0 || len(r.interests) == 0 {
		return
	}
	clear(&ids)
	for id, &on in r.interests {
		on = false
		append(&ids, id)
	}
	client_live_interest(&r.client, ids[:])
}

@(private)
_lives_reset :: proc(r: ^Replicator) {
	clear(&r.dflights)
	r.live_rx.on = false
	clear(&r.live_rx.buf)
}

@(private)
_lives_destroy :: proc(r: ^Replicator) {
	delete(r.interests)
	for _, s in r.lives {
		delete(s.name, r.allocator)
	}
	delete(r.lives)
	delete(r.dflights)
	delete(r.live_rx.buf)
}

@(private)
_live_sub_of :: proc(r: ^Replicator, id: Stream_Id) -> (s: Live_Sub, ok: bool) {
	return r.lives[id]
}

@(private)
_draft_flight :: proc(r: ^Replicator, tag: u64, device: Device_Id, id: Stream_Id) -> int {
	for f, i in r.dflights {
		if f.tag == tag && f.device == device && f.id == id {
			return i
		}
	}
	return -1
}

@(private)
_on_lived :: proc(r: ^Replicator, ev: ^Event) {
	_live_rx(r, ev, i64(ev.tag), -1, false, {}, 0)
}

@(private)
_on_draft_served :: proc(r: ^Replicator, ev: ^Event) -> bool {
	if ev.first {
		i := _draft_flight(r, ev.tag, ev.device, Stream_Id(ev.id))
		if i < 0 {
			return false
		}
		r.live_rx.msg = r.dflights[i].msg
	} else if !r.live_rx.on || r.live_rx.kind != .Served || r.live_rx.tag != ev.tag || r.live_rx.device != ev.device {
		return false
	}
	_live_rx(r, ev, r.live_rx.msg, ev.length, ev.final, ev.device, ev.tag)
	return true
}

@(private)
_live_rx :: proc(r: ^Replicator, ev: ^Event, msg: i64, length: i64, final: bool, holder: Device_Id, tag: u64) {
	x := &r.live_rx
	if ev.first {
		x.on = true
		x.kind = ev.kind
		x.id = Stream_Id(ev.id)
		x.device = holder
		x.tag = tag
		x.msg = msg
		x.at = ev.at
		x.length = length
		x.final = final
		clear(&x.buf)
		if !ev.last {
			return
		}
	}
	if !x.on {
		return
	}
	append(&x.buf, ..ev.data)
	if !ev.last {
		return
	}
	x.on = false
	if len(x.buf) > LIVE_MAX + SERVE_MAX {
		return
	}
	writer := stream_device(x.id)
	name := ""
	epoch: u64
	if s, ok := r.lives[x.id]; ok {
		name = s.name
		epoch = s.epoch
	}
	done := false
	if x.kind == .Served && x.final {
		if i := _draft_flight(r, x.tag, x.device, x.id); i >= 0 {
			ordered_remove(&r.dflights, i)
		}
		done = true
	}
	if len(name) == 0 && !done && len(x.buf) == 0 {
		return
	}
	r.live_recv += i64(len(x.buf))
	_emit(r, Repl_Event{kind = .Draft, device = writer, name = name, epoch = epoch, stream = x.id, from = x.at, to = x.msg, length = x.length, meta = x.buf[:], usage = 1 if done else 0})
}

@(private)
_on_draft_unserved :: proc(r: ^Replicator, ev: ^Event) -> bool {
	i := _draft_flight(r, ev.tag, ev.device, Stream_Id(ev.id))
	if i < 0 {
		return false
	}
	f := r.dflights[i]
	ordered_remove(&r.dflights, i)
	name := ""
	epoch: u64
	if s, ok := r.lives[f.id]; ok {
		name = s.name
		epoch = s.epoch
	}
	_emit(r, Repl_Event{kind = .Draft, err = .Not_Found, device = f.device, name = name, epoch = epoch, stream = f.id, to = f.msg, usage = 1})
	return true
}

@(private)
_on_draft_pulled :: proc(r: ^Replicator, ev: ^Event) -> bool {
	from := u64(ev.at)
	if from & PULL_DRAFT == 0 {
		return false
	}
	id := Stream_Id(ev.id)
	if stream_device(id) != r.cfg.self {
		replicator_draft_answer(r, ev.device, ev.tag, id, nil, 0)
		return true
	}
	name := ""
	epoch: u64
	if l, ok := r.locals[id]; ok {
		name = l.name
		epoch = l.epoch
	}
	_emit(r, Repl_Event{kind = .Draft_Pulled, device = ev.device, name = name, epoch = epoch, stream = id, from = ev.length, to = i64(from &~ PULL_DRAFT), length = i64(ev.tag)})
	return true
}

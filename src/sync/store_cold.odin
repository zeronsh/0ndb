#+build linux, darwin, windows
package osync

import "core:slice"
import "../prim"

TIER_HOT_DEFAULT :: 256 << 10

@(private)
Tier_Rec :: struct {
	at:  i64,
	n:   i64,
	seq: u64,
	off: u32,
}

@(private)
Tier_Cold :: struct {
	refs: int,
	upto: i64,
	recs: [dynamic]Tier_Rec,
}

@(private)
Tier_Ev :: struct {
	id:   Stream_Id,
	upto: i64,
	thaw: ^Tier_Thaw,
	hold: Tier_Hold,
}

@(private)
Tier_Thaw :: struct {
	ts:    ^Tier_Stream,
	from:  i64,
	to:    i64,
	low:   i64,
	high:  i64,
	job:   ^Tier_Job,
	tries: int,
}

@(private)
Tier_Evicting :: struct {
	sp: ^Tier_Space,
	h:  rawptr,
	own: bool,
}

@(private)
_tier_hot :: proc "contextless" (t: ^Tier_Store) -> i64 {
	return t.cfg.hot if t.cfg.hot > 0 else TIER_HOT_DEFAULT
}

@(private)
_tier_cold_on :: proc "contextless" (t: ^Tier_Store) -> bool {
	return t.cfg.hot >= 0 && t.inner.evict != nil && t.inner.restore != nil && t.cfg.objects.read != nil
}

@(private)
_tier_cold_scan :: proc(raw: []u8, id: Stream_Id, c: ^Tier_Cold) {
	want := id
	for i := 0; i + TIER_RECORD <= len(raw); i += TIER_RECORD {
		r := raw[i:][:TIER_RECORD]
		if string(r[8:40]) != string(want[:]) {
			continue
		}
		#partial switch Tier_Kind(r[0]) {
		case .Seg:
			append(&c.recs, Tier_Rec{at = i64(prim.get_u64le(r[40:])), n = i64(prim.get_u64le(r[48:])), seq = prim.get_u64le(r[56:]), off = prim.get_u32le(r[4:])})
		case .Evict:
			c.upto = i64(prim.get_u64le(r[40:]))
		case .Drop:
			clear(&c.recs)
			c.upto = 0
		}
	}
}

@(private)
_tier_cold_ref :: proc(sp: ^Tier_Space, id: Stream_Id) -> ^Tier_Cold {
	t := sp.t
	if c, ok := sp.cold[id]; ok {
		c.refs += 1
		return c
	}
	raw, ok := _tier_stream_records(sp, id)
	if !ok {
		return nil
	}
	c := new(Tier_Cold, t.allocator)
	c.refs = 1
	c.recs = make([dynamic]Tier_Rec, t.allocator)
	_tier_cold_scan(raw, id, c)
	sp.cold[id] = c
	return c
}

@(private)
_tier_cold_unref :: proc(sp: ^Tier_Space, id: Stream_Id, c: ^Tier_Cold) {
	c.refs -= 1
	if c.refs > 0 {
		return
	}
	if cur, ok := sp.cold[id]; ok && cur == c {
		delete_key(&sp.cold, id)
	}
	delete(c.recs)
	free(c, sp.t.allocator)
}

@(private)
_tier_pinned :: proc "contextless" (sp: ^Tier_Space, id: Stream_Id) -> bool {
	return _reserved(cast([32]u8)id) || stream_id_suffix(id) == sp.pin
}

@(private)
_tier_cold_of :: proc(ts: ^Tier_Stream) -> ^Tier_Cold {
	if ts.cold == nil && _tier_cold_on(ts.sp.t) && !_reserved(cast([32]u8)ts.id) {
		ts.cold = _tier_cold_ref(ts.sp, ts.id)
	}
	return ts.cold
}

@(private)
_tier_cold_note :: proc(sp: ^Tier_Space, entries: []u8, segs: map[Stream_Id]Tier_Seg) {
	t := sp.t
	if !_tier_cold_on(t) {
		return
	}
	hi := make(map[Stream_Id]i64, context.temp_allocator)
	for i := 0; i + TIER_RECORD <= len(entries); i += TIER_RECORD {
		r := entries[i:][:TIER_RECORD]
		if Tier_Kind(r[0]) != .Seg {
			continue
		}
		id: Stream_Id
		copy(id[:], r[8:40])
		at := i64(prim.get_u64le(r[40:]))
		n := i64(prim.get_u64le(r[48:]))
		if c, ok := sp.cold[id]; ok {
			append(&c.recs, Tier_Rec{at = at, n = n, seq = prim.get_u64le(r[56:]), off = prim.get_u32le(r[4:])})
		}
		if !_tier_pinned(sp, id) && sp.thawing[id] == 0 && sp.redacting[id] == 0 && sp.rewriting[id] == 0 && len(segs[id].redacts) == 0 {
			hi[id] = max(hi[id], at + n)
		}
	}
	if len(hi) == 0 {
		return
	}
	ids := make([dynamic]Stream_Id, 0, len(hi), context.temp_allocator)
	for id in prim.sorted_keys(hi) {
		append(&ids, id)
	}
	slice.sort_by(ids[:], _mem_id_less)
	hot := _tier_hot(t)
	for id in ids {
		target := hi[id] - hot
		if target <= 0 {
			continue
		}
		c: Tier_Cold
		c.recs = make([dynamic]Tier_Rec, context.temp_allocator)
		raw, ok := _tier_stream_records(sp, id)
		if !ok {
			continue
		}
		_tier_cold_scan(raw, id, &c)
		_tier_cold_scan(entries, id, &c)
		if target <= c.upto {
			continue
		}
		_, base, exists, perr := t.inner.stream_probe(t.inner.data, sp.ns, id)
		if perr != .None || !exists {
			continue
		}
		slice.sort_by(c.recs[:], proc(a, b: Tier_Rec) -> bool {
			return a.at < b.at
		})
		covered := base
		for r in c.recs {
			if r.at > covered {
				break
			}
			covered = max(covered, r.at + r.n)
		}
		upto := min(target, covered)
		if upto <= max(c.upto, base) {
			continue
		}
		_tier_ev_queue(sp, id, upto, nil)
	}
}

@(private)
_tier_ev_queue :: proc(sp: ^Tier_Space, id: Stream_Id, upto: i64, thaw: ^Tier_Thaw) {
	r: [TIER_RECORD]u8
	r[0] = u8(Tier_Kind.Evict)
	v := id
	copy(r[8:40], v[:])
	prim.put_u64le(r[40:], u64(upto))
	prim.put_u64le(r[56:], sp.seq)
	append(&sp.man_q, ..r[:])
	append(&sp.ev_q, Tier_Ev{id = id, upto = upto, thaw = thaw})
}

@(private)
_tier_ev_done :: proc(sp: ^Tier_Space, result: Error) {
	t := sp.t
	evs := make([]Tier_Ev, len(sp.ev_fly), context.temp_allocator)
	copy(evs, sp.ev_fly[:])
	clear(&sp.ev_fly)
	for ev in evs {
		if ev.hold.done != nil {
			ev.hold.done(ev.hold.ctx, ev.hold.result if result == .None else .Io, ev.hold.value)
			continue
		}
		if ev.thaw != nil {
			_tier_thaw_lowered(ev.thaw, result)
			continue
		}
		if result != .None || _tier_pinned(sp, ev.id) || sp.thawing[ev.id] > 0 || sp.redacting[ev.id] > 0 || sp.rewriting[ev.id] > 0 {
			continue
		}
		if c, ok := sp.cold[ev.id]; ok {
			c.upto = max(c.upto, ev.upto)
		}
		e := new(Tier_Evicting, t.allocator)
		e.sp = sp
		if h, ok := sp.open[ev.id]; ok {
			e.h = h
		} else {
			nh, _, err := t.inner.stream_open(t.inner.data, sp.ns, ev.id, false)
			if err != .None {
				free(e, t.allocator)
				continue
			}
			e.h, e.own = nh, true
		}
		sp.evicting += 1
		t.evictions += 1
		t.inner.evict(t.inner.data, e.h, ev.upto, _tier_evicted, e)
	}
}

@(private)
_tier_evicted :: proc(ctx: rawptr, result: Error, value: i64) {
	e := cast(^Tier_Evicting)ctx
	sp := e.sp
	t := sp.t
	_tier_hold(sp)
	defer _tier_unhold(sp)
	if e.own {
		t.inner.stream_close(t.inner.data, e.h)
	}
	free(e, t.allocator)
	sp.evicting -= 1
}

@(private)
_tier_thaw_start :: proc(t: ^Tier_Store, ts: ^Tier_Stream, c: ^Tier_Cold, from, to: i64, job: ^Tier_Job) {
	sp := ts.sp
	_, base, _, perr := t.inner.stream_probe(t.inner.data, sp.ns, ts.id)
	low := max(from, base)
	if perr != .None || low >= c.upto {
		t.inner.redact(t.inner.data, ts.h, from, to, _tier_job_done, job)
		return
	}
	th := new(Tier_Thaw, t.allocator)
	th^ = {ts = ts, from = from, to = to, low = low, high = c.upto, job = job}
	sp.evicting += 1
	sp.thawing[ts.id] += 1
	t.thaws += 1
	_tier_cold_fetch(sp, c, low, c.upto - low, _tier_thaw_fetched, th)
}

@(private)
_tier_thaw_fetched :: proc(ctx: rawptr, rg: ^Tier_Range, err: Error) {
	th := cast(^Tier_Thaw)ctx
	sp := th.ts.sp
	t := sp.t
	_tier_hold(sp)
	defer _tier_unhold(sp)
	e := err
	bytes: []u8
	if e == .None {
		bytes = make([]u8, int(th.high - th.low), context.temp_allocator)
		if c := th.ts.cold; c != nil {
			e = _tier_cold_read(sp, c, th.low, bytes)
		} else {
			e = .Io
		}
	}
	_tier_range_end(rg)
	if e != .None {
		th.tries += 1
		if c := th.ts.cold; c != nil {
			if th.tries < TIER_TRIES {
				_tier_cold_fetch(sp, c, th.low, th.high - th.low, _tier_thaw_fetched, th)
			} else {
				_tier_thaw_park(t, th)
			}
			return
		}
		_tier_thaw_end(th, e if e != .Pending else .Io)
		return
	}
	t.park_ms = 0
	t.inner.restore(t.inner.data, th.ts.h, th.low, bytes, _tier_thaw_restored, th)
}

@(private)
_tier_thaw_restored :: proc(ctx: rawptr, result: Error, value: i64) {
	th := cast(^Tier_Thaw)ctx
	sp := th.ts.sp
	_tier_hold(sp)
	defer _tier_unhold(sp)
	if result != .None {
		_tier_thaw_end(th, result)
		return
	}
	_tier_ev_queue(sp, th.ts.id, th.low, th)
	_tier_man_flush(sp)
}

@(private)
_tier_thaw_lowered :: proc(th: ^Tier_Thaw, result: Error) {
	t := th.ts.sp.t
	if result != .None {
		_tier_thaw_end(th, result)
		return
	}
	if c := th.ts.cold; c != nil {
		c.upto = min(c.upto, th.low)
	}
	t.inner.redact(t.inner.data, th.ts.h, th.from, th.to, _tier_thaw_redacted, th)
}

@(private)
_tier_thaw_redacted :: proc(ctx: rawptr, result: Error, value: i64) {
	th := cast(^Tier_Thaw)ctx
	sp := th.ts.sp
	_tier_hold(sp)
	defer _tier_unhold(sp)
	_tier_thaw_end(th, result, value)
}

@(private)
_tier_thaw_end :: proc(th: ^Tier_Thaw, result: Error, value: i64 = 0) {
	sp := th.ts.sp
	t := sp.t
	job := th.job
	id := th.ts.id
	free(th, t.allocator)
	sp.thawing[id] -= 1
	if sp.thawing[id] <= 0 {
		delete_key(&sp.thawing, id)
	}
	assert(sp.holds > 0 || sp.refs > 0, "a tier thaw ended without its space held")
	_tier_job_done(job, result, value)
	sp.evicting -= 1
}

@(private)
_tier_cold_drop :: proc(sp: ^Tier_Space, id: Stream_Id) {
	if c, ok := sp.cold[id]; ok {
		clear(&c.recs)
		c.upto = 0
	}
}

TIER_PARK_MS :: 1000
TIER_PARK_MAX_MS :: 60_000

@(private)
_tier_thaw_park :: proc(t: ^Tier_Store, th: ^Tier_Thaw) {
	th.tries = 0
	append(&t.parked, th)
	t.parks += 1
	if t.park_timer == 0 {
		if t.park_ms <= 0 {
			t.park_ms = TIER_PARK_MS
		}
		t.park_timer = prim.timer(t.loop, t.park_ms, t, _tier_park_fire)
	}
}

@(private)
_tier_park_fire :: proc(l: ^prim.Loop, data: rawptr) {
	t := cast(^Tier_Store)data
	t.park_timer = 0
	t.park_ms = min(max(t.park_ms, TIER_PARK_MS) * 2, TIER_PARK_MAX_MS)
	_tier_unpark(t)
}

@(private)
_tier_unpark :: proc(t: ^Tier_Store) {
	if len(t.parked) == 0 {
		return
	}
	ths := make([]^Tier_Thaw, len(t.parked), context.temp_allocator)
	copy(ths, t.parked[:])
	clear(&t.parked)
	if t.park_timer != 0 {
		prim.timer_cancel(t.loop, t.park_timer)
		t.park_timer = 0
	}
	for th in ths {
		sp := th.ts.sp
		_tier_hold(sp)
		if c := th.ts.cold; c != nil {
			_tier_cold_fetch(sp, c, th.low, th.high - th.low, _tier_thaw_fetched, th)
		} else {
			_tier_thaw_end(th, .Io)
		}
		_tier_unhold(sp)
	}
}

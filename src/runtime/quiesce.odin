package rt

import "../convo"
import eng "../engine"
import omap "../map"
import "../obj"
import "../prim"

QUIESCE_LIFT_MS :: i64(180_000)

@(private)
KEY_HOLD :: "hold/"

Quiesce_Result :: enum u8 {
	Accepted,
	Run_Active,
	Queued,
	Relay,
}

Quiesce_Done :: struct {
	data: rawptr,
	call: proc(data: rawptr, r: ^Runtime, res: Quiesce_Result),
}

@(private)
Quiesce_State :: struct {
	on:       bool,
	timer:    prim.Timer,
	deferred: [dynamic]Object,
	waiters:  [dynamic]Quiesce_Done,
	settling: bool,
	seen:     [dynamic]Quiesce_Seen,
}

@(private)
Quiesce_Seen :: struct {
	space:    prim.Id,
	activity: u64,
}

@(private)
KEY_WAKE :: "quiesce/seen"


quiesced :: proc "contextless" (r: ^Runtime) -> bool {
	return r.quiesce.on
}

quiesce :: proc(r: ^Runtime, on: bool, lift_ms: i64 = QUIESCE_LIFT_MS, done: Quiesce_Done = {}) -> (res: Quiesce_Result, pending: bool) {
	context = eng.context_for(r.e)
	if !on {
		_quiesce_lift(r)
		return .Accepted, false
	}
	if why, busy := _quiesce_busy(r); busy {
		return why, false
	}
	r.quiesce.on = true
	r.stats.quiesces += 1
	for sw in r.spaces {
		seen: u64
		for x in r.quiesce.seen {
			if x.space == sw.space {
				seen = x.activity
			}
		}
		map_put(r, state_w(r, sw.space), transmute([]u8)string(KEY_WAKE), omap.field_u64(1, seen))
	}
	l := eng.loop(r.e)
	if r.quiesce.timer != 0 {
		prim.timer_cancel(l, r.quiesce.timer)
	}
	ms := lift_ms if lift_ms > 0 else QUIESCE_LIFT_MS
	r.quiesce.timer = prim.timer(l, ms, r, _on_quiesce_lift)
	if done.call == nil {
		return .Accepted, false
	}
	append(&r.quiesce.waiters, done)
	if !r.quiesce.settling {
		r.quiesce.settling = true
		eng.settle(r.e, eng.Settle_Done{data = r, call = _on_quiesce_settled})
	}
	return .Accepted, true
}

@(private)
_quiesce_busy :: proc(r: ^Runtime) -> (why: Quiesce_Result, busy: bool) {
	for run in r.runs {
		if run.state != .Finished {
			return .Run_Active, true
		}
	}
	if len(r.runs) > 0 {
		return .Run_Active, true
	}
	if len(r.pending) > 0 || len(r.revives) > 0 || len(r.waits) > 0 || len(r.quiesce.deferred) > 0 {
		return .Queued, true
	}
	for sw in r.spaces {
		for &row in map_rows(r, pending_object(sw.space), nil) {
			if len(row.key) != 16 || obj.rid_none(entry_rid(&row.entry, 1)) {
				continue
			}
			if entry_id(&row.entry, 4) == r.self {
				return .Queued, true
			}
		}
	}
	return .Accepted, false
}

@(private)
_quiesce_hold :: proc(r: ^Runtime, o: Object) -> bool {
	if !r.quiesce.on {
		return false
	}
	for x in r.quiesce.deferred {
		if x == o {
			return true
		}
	}
	append(&r.quiesce.deferred, o)
	r.stats.quiesce_held += 1
	id := o.id
	map_put(r, state_w(r, o.space), key_of(KEY_HOLD, id[:]), omap.field_u64(1, u64(max(wall_ms(r), 0))))
	_quiesce_note(r, o)
	return true
}

@(private)
_quiesce_seen :: proc(r: ^Runtime, space: prim.Id, activity: u64) {
	for &x in r.quiesce.seen {
		if x.space == space {
			x.activity = max(x.activity, activity)
			return
		}
	}
	append(&r.quiesce.seen, Quiesce_Seen{space, activity})
}

@(private)
_quiesce_wake_scan :: proc(r: ^Runtime, space: prim.Id) {
	en, ok := map_read(r, state_object(r, space), transmute([]u8)string(KEY_WAKE))
	if !ok {
		return
	}
	seen := entry_u64(&en, 1)
	ready := _wait_ready(r, eng.space_catalog(r.e, space))
	after: eng.Map_Cursor
	defer omap.cursor_destroy(&after)
	scan: for {
		rows, more, err := eng.catalog_list(r.e, space, false, &after, 256, context.temp_allocator, ready)
		if err == .Pending {
			return
		}
		ready = {}
		if err != .None {
			break
		}
		for row in rows {
			if row.activity < seen {
				break scan
			}
			if row.kind == .Conversation {
				_queue_eval(r, Object{space, row.object})
			}
		}
		if !more {
			break
		}
	}
	_wait_drop(r, ready)
	map_clear(r, state_object(r, space), transmute([]u8)string(KEY_WAKE), 1)
}

@(private)
_quiesce_holds_queue :: proc(r: ^Runtime, space: prim.Id) {
	for &row in map_rows(r, state_object(r, space), transmute([]u8)string(KEY_HOLD)) {
		if len(row.key) != len(KEY_HOLD) + 16 {
			continue
		}
		id: prim.Id
		copy(id[:], row.key[len(KEY_HOLD):])
		_queue_eval(r, Object{space, id})
	}
}

@(private)
_quiesce_unhold :: proc(r: ^Runtime, o: Object) {
	if r.quiesce.on {
		return
	}
	id := o.id
	k := key_of(KEY_HOLD, id[:])
	if _, ok := map_read(r, state_object(r, o.space), k); ok {
		map_clear(r, state_object(r, o.space), k, 1)
	}
}

@(private)
_quiesce_note :: proc(r: ^Runtime, o: Object) {
	msg: Rid
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		_pending_put(r, o, Pending_Entry{msg = Rid{seg = o.id, off = 1}, since_ms = wall_ms(r), runner = r.self})
		return
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		_pending_put(r, o, Pending_Entry{msg = Rid{seg = o.id, off = 1}, since_ms = wall_ms(r), runner = r.self})
		return
	}
	if items, ierr := convo.intents(v, context.temp_allocator); ierr == .None {
		for it in items {
			if it.kind == .Queue || it.kind == .Steer {
				msg = it.item
				break
			}
		}
	}
	if obj.rid_none(msg) {
		if head, herr := convo.tail_head(v, &t); herr == .None && !obj.rid_none(head) {
			msg = head
		} else {
			msg = Rid{seg = o.id, off = 1}
		}
	}
	if p, ok := pending_get(r, o); ok && p.runner == r.self {
		return
	}
	_pending_put(r, o, Pending_Entry{msg = msg, since_ms = wall_ms(r), runner = r.self})
}

@(private)
_on_quiesce_settled :: proc(data: rawptr, e: ^eng.Engine, res: eng.Settle_Result) {
	r := (^Runtime)(data)
	context = eng.context_for(e)
	r.quiesce.settling = false
	out := Quiesce_Result.Accepted
	if res == .Relay {
		out = .Relay
	} else if !r.quiesce.on {
		out = .Queued
	} else if len(r.runs) > 0 {
		out = .Run_Active
	}
	if out != .Accepted {
		_quiesce_lift(r)
	}
	list := r.quiesce.waiters
	r.quiesce.waiters = make([dynamic]Quiesce_Done, r.allocator)
	defer delete(list)
	for d in list {
		d.call(d.data, r, out)
	}
}

@(private)
_on_quiesce_lift :: proc(l: ^prim.Loop, data: rawptr) {
	r := (^Runtime)(data)
	context = eng.context_for(r.e)
	r.quiesce.timer = 0
	_quiesce_lift(r)
}

@(private)
_quiesce_lift :: proc(r: ^Runtime) {
	if r.quiesce.timer != 0 {
		prim.timer_cancel(eng.loop(r.e), r.quiesce.timer)
		r.quiesce.timer = 0
	}
	if !r.quiesce.on {
		return
	}
	r.quiesce.on = false
	held := r.quiesce.deferred
	r.quiesce.deferred = make([dynamic]Object, r.allocator)
	defer delete(held)
	for o in held {
		_queue_eval(r, o)
	}
	for w in r.revives {
		_queue_eval(r, w.object)
	}
	for sw in r.spaces {
		_pending_scan(r, sw.space)
		_quiesce_holds_queue(r, sw.space)
		if _, ok := map_read(r, state_object(r, sw.space), transmute([]u8)string(KEY_WAKE)); ok {
			map_clear(r, state_object(r, sw.space), transmute([]u8)string(KEY_WAKE), 1)
		}
	}
}

@(private)
_quiesce_destroy :: proc(r: ^Runtime) {
	if r.quiesce.timer != 0 {
		prim.timer_cancel(eng.loop(r.e), r.quiesce.timer)
		r.quiesce.timer = 0
	}
	list := r.quiesce.waiters
	r.quiesce.waiters = nil
	for d in list {
		d.call(d.data, r, .Relay)
	}
	delete(list)
	delete(r.quiesce.deferred)
	r.quiesce.deferred = nil
	delete(r.quiesce.seen)
	r.quiesce.seen = nil
	r.quiesce.on = false
}

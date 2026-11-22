package sim

import "core:mem/virtual"
import api "../../src/capi/api"
import eng "../../src/engine"
import "../../src/prim"

Live_Read :: struct {
	w:     ^World,
	node:  int,
	obj:   int,
	op:    string,
	start: i64,
	id:    u64,
}

live_start :: proc(n: ^Node) {
	context = instance_context(&n.inst)
	api.init(&n.api, &n.e, nil, {}, context.allocator)
	n.api_on = true
}

live_kill :: proc(n: ^Node) {
	if !n.api_on {
		return
	}
	for c in n.api.calls {
		virtual.arena_destroy(&c.arena)
	}
	n.api = {}
	n.api_on = false
	w := n.w
	i := 0
	for i < len(w.live) {
		r := w.live[i]
		if r.node == n.idx {
			ordered_remove(&w.live, i)
			free(r, w.allocator)
			stat_add(w, STAT_LIVE_DROPPED)
			continue
		}
		i += 1
	}
}

live_close :: proc(n: ^Node) {
	if !n.api_on {
		return
	}
	context = instance_context(&n.inst)
	api.destroy(&n.api)
	n.api = {}
	n.api_on = false
}

op_live_read :: proc(w: ^World, n: ^Node) {
	if !n.api_on {
		return
	}
	m := &w.model
	cands := make([dynamic]int, context.temp_allocator)
	for _, i in m.objs {
		if obj_reader(m, i, n.idx) {
			append(&cands, i)
		}
	}
	if len(cands) == 0 {
		return
	}
	oi := cands[rng_int(&w.rng, len(cands))]
	quarantined := make([dynamic]int, context.temp_allocator)
	for q in w.quarantines {
		if q.node != n.idx {
			continue
		}
		for c in cands {
			if m.objs[c].o.id == q.object {
				append(&quarantined, c)
			}
		}
	}
	if len(quarantined) > 0 && rng_chance(&w.rng, 1, 2) {
		oi = quarantined[rng_int(&w.rng, len(quarantined))]
	}
	ob := &m.objs[oi]
	name: string
	switch ob.kind {
	case .Convo:
		name = "convo.page"
	case .Map:
		name = "map.scan"
	case .Text:
		name = "text.read"
	case .Tree:
		name = "tree.list"
	}
	op := api.find_op(&n.api, name, 0)
	if op == nil {
		world_fail(w, "interactive read: capi has no %s", name)
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	wr := prim.writer(&buf)
	prim.write_u8(&wr, api.VERSION)
	prim.write_uvarint(&wr, u64(op.code))
	prim.write_id(&wr, ob.o.space)
	prim.write_id(&wr, ob.o.id)
	r := new(Live_Read, w.allocator)
	r^ = Live_Read{w = w, node = n.idx, obj = oi, op = name, start = w.now}
	stat_add(w, STAT_LIVE_READS)
	id: u64
	st: api.Status
	{
		context = instance_context(&n.inst)
		id, st, _ = api.call(&n.api, buf[:], false, _live_done, r, 0, context.temp_allocator)
	}
	if st == .Pending {
		r.id = id
		stat_add(w, STAT_LIVE_WAITED)
		append(&w.live, r)
		world_note(w, "%s interactive %s %s waits (call %d)", n.name, name, id_short(ob.o.id), id)
		return
	}
	world_note(w, "%s interactive %s %s -> %v", n.name, name, id_short(ob.o.id), st)
	_live_settled(w, r, st)
	free(r, w.allocator)
}

@(private = "file")
_live_done :: proc(data: rawptr, id: u64, status: api.Status, payload: []u8) {
	r := (^Live_Read)(data)
	w := r.w
	context = w.ctx
	for x, i in w.live {
		if x == r {
			ordered_remove(&w.live, i)
			break
		}
	}
	world_note(w, "%s interactive %s %s settled %v after %d ms", w.nodes[r.node].name, r.op, id_short(w.model.objs[r.obj].o.id), status, (w.now - r.start) / 1_000_000)
	stat_max(w, STAT_LIVE_WAIT_MS, u64((w.now - r.start) / 1_000_000))
	_live_settled(w, r, status)
	free(r, w.allocator)
}

@(private = "file")
_live_settled :: proc(w: ^World, r: ^Live_Read, st: api.Status) {
	#partial switch st {
	case .Ok:
		stat_add(w, STAT_LIVE_DATA)
	case .Missing, .Not_Found, .Permission, .Offline:
		stat_add(w, STAT_LIVE_ABSENT)
	case .Quarantined:
		stat_add(w, STAT_LIVE_QUARANTINED)
	case .Closed:
		stat_add(w, STAT_LIVE_CLOSED)
	case .Io, .No_Space, .Corrupt:
		if w.cfg.io_rate == 0 && !w.nodes[r.node].disk.dead {
			world_fail(w, "interactive read: %s %s on %s failed %v without injected I/O faults", r.op, id_short(w.model.objs[r.obj].o.id), w.nodes[r.node].name, st)
		}
		stat_add(w, STAT_LIVE_ABSENT)
	case:
		world_fail(w, "interactive read: %s %s on %s settled %v after %d ms", r.op, id_short(w.model.objs[r.obj].o.id), w.nodes[r.node].name, st, (w.now - r.start) / 1_000_000)
	}
}

check_live_reads :: proc(w: ^World) {
	for r in w.live {
		n := w.nodes[r.node]
		tries := -1
		if n.api_on {
			for c in n.api.calls {
				if c.id == r.id {
					tries = c.tries
				}
			}
		}
		pending := 0
		if n.e_open {
			context = instance_context(&n.inst)
			pending = eng.stats(&n.e).pending
		}
		world_fail(w, "interactive read: %s %s on %s never settled (%d ms, tries=%d, engine waiters=%d)", r.op, id_short(w.model.objs[r.obj].o.id), n.name, (w.now - r.start) / 1_000_000, tries, pending)
	}
}

STAT_LIVE_READS: Stat
STAT_LIVE_WAITED: Stat
STAT_LIVE_DATA: Stat
STAT_LIVE_ABSENT: Stat
STAT_LIVE_QUARANTINED: Stat
STAT_LIVE_CLOSED: Stat
STAT_LIVE_DROPPED: Stat
STAT_LIVE_WAIT_MS: Stat

@(init)
_reads_stats :: proc "contextless" () {
	register_stat_line(20)
	STAT_LIVE_READS = register_stat(20, 0, "interactive_reads")
	STAT_LIVE_WAITED = register_stat(20, 1, "waited")
	STAT_LIVE_DATA = register_stat(20, 2, "data")
	STAT_LIVE_ABSENT = register_stat(20, 3, "absent")
	STAT_LIVE_QUARANTINED = register_stat(20, 4, "quarantined")
	STAT_LIVE_CLOSED = register_stat(20, 5, "closed")
	STAT_LIVE_DROPPED = register_stat(20, 6, "dropped_by_crash")
	STAT_LIVE_WAIT_MS = register_stat(20, 7, "max_wait_ms", true)
}

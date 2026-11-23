package sim

import "core:fmt"
import "core:strings"
import eng "../../src/engine"
import omap "../../src/map"
import "../../src/odb"

@(private = "file")
CU_SERVE_ROOT :: 7

@(private = "file")
STAT_CU_RUNS: Stat
@(private = "file")
STAT_CU_REFUSED: Stat
@(private = "file")
STAT_CU_DONE: Stat

@(private = "file")
Cu_Row :: struct {
	key:   []u8,
	value: []u8,
}

@(private = "file")
_cu_rows :: proc(n: ^Node, oids: []odb.Oid) -> [dynamic]Cu_Row {
	Acc :: struct {
		oids: []odb.Oid,
		rows: [dynamic]Cu_Row,
	}
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		a := (^Acc)(data)
		if len(value) < 50 || value[0] != 1 {
			return true
		}
		k := int(value[49])
		if (k != 20 && k != 32) || len(value) != 50 + k {
			return true
		}
		oid: odb.Oid
		copy(oid[:k], value[50:])
		for o in a.oids {
			if o == oid {
				k2 := make([]u8, len(key), context.temp_allocator)
				copy(k2, key)
				v2 := make([]u8, len(value), context.temp_allocator)
				copy(v2, value)
				append(&a.rows, Cu_Row{k2, v2})
				break
			}
		}
		return true
	}
	a := Acc{oids = oids, rows = make([dynamic]Cu_Row, context.temp_allocator)}
	prefix := [4]u8{0xff, 's', 'r', 'v'}
	omap.db_scan(&n.e.reg.db, CU_SERVE_ROOT, prefix[:], prefix[:], &a, visit)
	return a.rows
}

@(private = "file")
_cu_apply :: proc(n: ^Node, rows: []Cu_Row, put: bool) -> bool {
	t, err := omap.txn_begin(&n.e.reg.db)
	if err != .None {
		return false
	}
	for r in rows {
		if put {
			if omap.txn_put(t, CU_SERVE_ROOT, r.key, r.value) != .None {
				omap.txn_abort(t)
				return false
			}
		} else if _, derr := omap.txn_delete(t, CU_SERVE_ROOT, r.key); derr != .None {
			omap.txn_abort(t)
			return false
		}
	}
	return omap.txn_commit(t) == .None && omap.db_sync(&n.e.reg.db) == .None
}

@(private = "file")
_cu_served :: proc(n: ^Node, allocator := context.temp_allocator) -> map[odb.Oid]bool {
	out := make(map[odb.Oid]bool, allocator)
	rows, err := eng.serve_rows(&n.e, context.temp_allocator)
	if err == .None {
		for r in rows {
			out[r.oid] = true
		}
	}
	return out
}

@(private = "file")
_cu_waiting :: proc(n: ^Node, oids: []odb.Oid) -> (waiting: bool, inflight: bool) {
	for x in eng.content_waits(&n.e, context.temp_allocator) {
		for o in oids {
			if x.oid == o {
				waiting = true
				inflight ||= x.inflight
			}
		}
	}
	return
}

check_content_unserved :: proc(w: ^World) {
	if len(w.failures) > 0 || w.cfg.byzantine || (w.cfg.storage != .Device && w.cfg.storage != .Device_Until_Run) {
		return
	}
	m := &w.model
	oi, hi, ri := -1, -1, -1
	pick: for &ob, i in m.objs {
		if ob.kind != .Tree || !obj_exists(m, i) {
			continue
		}
		si := space_index(m, ob.o.space)
		if si < 0 {
			continue
		}
		for a in w.nodes {
			if !a.alive || !a.e_open || a.partitioned || !space_member(&m.spaces[si], a.idx) || !obj_reader(m, i, a.idx) {
				continue
			}
			held: {
				context = instance_context(&a.inst)
				class, cerr := eng.storage_class(&a.e, ob.o)
				if cerr != .None || class != .Device {
					continue
				}
			}
			for b in w.nodes {
				if b.idx != a.idx && b.alive && b.e_open && !b.partitioned && obj_reader(m, i, b.idx) {
					oi, hi, ri = i, a.idx, b.idx
					break pick
				}
			}
		}
	}
	if oi < 0 {
		return
	}
	h, r := w.nodes[hi], w.nodes[ri]
	o := m.objs[oi].o
	stat_add(w, STAT_CU_RUNS)
	root := fmt.aprintf("%scu-%s-%s", WORK_PREFIX, id_short(o.id), h.name, allocator = w.allocator)
	if node_mount(w, h, oi, root) != .None {
		return
	}
	run_until(w, w.now + 30_000_000_000, true)
	before: map[odb.Oid]bool
	{
		context = instance_context(&h.inst)
		before = _cu_served(h, w.allocator)
	}
	r.partitioned = true
	defer r.partitioned = false
	for c in r.conns {
		conn_reset(c, true)
	}
	name := fmt.aprintf("cu-%s.txt", id_short(o.id), allocator = w.allocator)
	b := strings.builder_make(w.allocator)
	tok := new_token(m, h, "u")
	for strings.builder_len(b) < 6000 {
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	want := strings.to_string(b)
	{
		context = instance_context(&h.inst)
		werr := _disk_write(disk_vfs(&h.disk), strings.concatenate({root, "/", name}, context.temp_allocator), transmute([]u8)want, false)
		node_after(h)
		if werr != .None {
			return
		}
	}
	run_until(w, w.now + 30_000_000_000, true)
	fresh := make([dynamic]odb.Oid, w.allocator)
	{
		context = instance_context(&h.inst)
		got, gerr := eng.tree_read(&h.e, o, name, context.temp_allocator)
		if gerr != .None || string(got) != want {
			return
		}
		for k in _cu_served(h) {
			if k not_in before {
				append(&fresh, k)
			}
		}
	}
	if len(fresh) == 0 {
		return
	}
	rows: [dynamic]Cu_Row
	{
		context = instance_context(&h.inst)
		rows = _cu_rows(h, fresh[:])
		kept := make([dynamic]Cu_Row, w.allocator)
		for x in rows {
			k2 := make([]u8, len(x.key), w.allocator)
			copy(k2, x.key)
			v2 := make([]u8, len(x.value), w.allocator)
			copy(v2, x.value)
			append(&kept, Cu_Row{k2, v2})
		}
		rows = kept
		if len(rows) == 0 || !_cu_apply(h, rows[:], false) {
			return
		}
		left := _cu_served(h)
		for f in fresh {
			if f in left {
				world_fail(w, "content unserved: removing %s's serve rows did not take (registry root %d moved?)", h.name, CU_SERVE_ROOT)
				return
			}
		}
	}
	r.partitioned = false
	run_until(w, w.now + 30_000_000_000, true)
	if !r.alive || !r.e_open {
		return
	}
	refused := false
	for _ in 0 ..< 6 {
		{
			context = instance_context(&r.inst)
			_, rerr := eng.tree_read(&r.e, o, name, context.temp_allocator)
			if rerr == .None {
				return
			}
		}
		run_until(w, w.now + 30_000_000_000, true)
		context = instance_context(&r.inst)
		waiting, inflight := _cu_waiting(r, fresh[:])
		if waiting && inflight {
			world_fail(w, "content unserved: %s's wait on a blob of %s is still inflight after its only holder %s answered unserved", r.name, id_short(o.id), h.name)
			return
		}
		if waiting {
			refused = true
		}
	}
	if !refused {
		return
	}
	stat_add(w, STAT_CU_REFUSED)
	{
		context = instance_context(&h.inst)
		if !_cu_apply(h, rows[:], true) {
			return
		}
	}
	for _ in 0 ..< 6 {
		{
			context = instance_context(&r.inst)
			got, rerr := eng.tree_read(&r.e, o, name, context.temp_allocator)
			if rerr == .None {
				if string(got) != want {
					world_fail(w, "content unserved: %s read %d bytes of %s/%s, %d written", r.name, len(got), id_short(o.id), name, len(want))
				}
				stat_add(w, STAT_CU_DONE)
				return
			}
		}
		run_until(w, w.now + 30_000_000_000, true)
	}
	context = instance_context(&r.inst)
	_, inflight := _cu_waiting(r, fresh[:])
	world_fail(w, "content unserved: %s never read %s/%s after its only holder %s became servable (wait inflight %v)", r.name, id_short(o.id), name, h.name, inflight)
}

@(init)
_content_unserved_register :: proc "contextless" () {
	register_final_check(1006, check_content_unserved)
	register_stat_line(35, "content_unserved")
	STAT_CU_RUNS = register_stat(35, 0, "runs")
	STAT_CU_REFUSED = register_stat(35, 1, "refused")
	STAT_CU_DONE = register_stat(35, 2, "done")
}

package sim

import "core:fmt"
import "core:strings"
import eng "../../src/engine"
import "../../src/odb"

@(private = "file")
STAT_CU_RUNS: Stat
@(private = "file")
STAT_CU_REFUSED: Stat
@(private = "file")
STAT_CU_DONE: Stat

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
	if len(h.mounts) == 0 {
		return
	}
	line := line_eng(strings.clone(h.mounts[len(h.mounts) - 1].m.line, w.allocator))
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
		got, gerr := eng.tree_read(&h.e, o, name, context.temp_allocator, {}, line)
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
	rows := make([dynamic]eng.Serve_Row, w.allocator)
	{
		context = instance_context(&h.inst)
		all, serr := eng.serve_rows(&h.e, context.temp_allocator)
		if serr != .None {
			return
		}
		for x in all {
			for f in fresh {
				if x.oid == f {
					append(&rows, x)
					break
				}
			}
		}
		if len(rows) == 0 {
			return
		}
		eng.serve_withdraw(&h.e, fresh[:])
		node_after(h)
		left := _cu_served(h)
		for f in fresh {
			if f in left {
				world_fail(w, "content unserved: withdrawing %s's serve rows did not take", h.name)
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
			_, rerr := eng.tree_read(&r.e, o, name, context.temp_allocator, {}, line)
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
		if eng.serve_publish(&h.e, o, rows[:]) != .None {
			return
		}
		node_after(h)
	}
	for c in h.conns {
		conn_reset(c, true)
	}
	run_until(w, w.now + 30_000_000_000, true)
	for _ in 0 ..< 6 {
		{
			context = instance_context(&r.inst)
			got, rerr := eng.tree_read(&r.e, o, name, context.temp_allocator, {}, line)
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

package sim

import "base:runtime"
import "core:fmt"

MARK_DISKS :: 8

Ev_Mark :: struct {
	at:    i64,
	kind:  Ev_Kind,
	node:  int,
	conn:  u64,
	gen:   u64,
	len:   int,
	hash:  u64,
	arg:   u64,
	now:   i64,
	world: u64,
	rngs:  u64,
	disk:  [MARK_DISKS]u64,
	ops:   [MARK_DISKS]u64,
}

mark_begin :: proc(w: ^World, ev: ^Sim_Event) -> Ev_Mark {
	if !w.cfg.marks {
		return {}
	}
	return Ev_Mark {
		at = ev.at,
		kind = ev.kind,
		node = ev.node,
		conn = ev.conn.id if ev.conn != nil else 0,
		gen = ev.gen,
		len = len(ev.bytes),
		hash = mix_bytes(0, ev.bytes),
		arg = ev.arg,
	}
}

mark_end :: proc(w: ^World, m: ^Ev_Mark) {
	if !w.cfg.marks {
		return
	}
	if w.marks == nil {
		w.marks = make([dynamic]Ev_Mark, runtime.heap_allocator())
	}
	m.now = w.now
	m.world = w.trace
	for r in ([?]^Rng{&w.rng, &w.net_rng, &w.fault_rng, &w.sched_rng}) {
		m.rngs = mix_bytes(m.rngs, ([^]u8)(r)[:size_of(Rng)])
	}
	for n, i in w.nodes {
		if i < MARK_DISKS - 1 {
			m.disk[i] = n.disk.trace
			m.ops[i] = n.disk.stats.ops
		}
	}
	m.disk[MARK_DISKS - 1] = w.relay.disk.trace
	m.ops[MARK_DISKS - 1] = w.relay.disk.stats.ops
	append(&w.marks, m^)
}

marks_first_difference :: proc(a, b: []Ev_Mark) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return i
		}
	}
	return n if len(a) != len(b) else -1
}

marks_report :: proc(seed: u64, a, b: []Ev_Mark) {
	i := marks_first_difference(a, b)
	if i < 0 {
		fmt.eprintf("sim: seed %d: both runs' %d events have the same marks; the difference is outside an event\n", seed, len(a))
		return
	}
	fmt.eprintf("sim: seed %d: the runs first differ at event %d (of %d and %d)\n", seed, i, len(a), len(b))
	for j in max(i - 3, 0) ..< i {
		_mark_print("both  ", j, a[j])
	}
	if i < len(a) {
		_mark_print("first ", i, a[i])
	}
	if i < len(b) {
		_mark_print("second", i, b[i])
	}
	if i >= len(a) || i >= len(b) {
		return
	}
	x, y := a[i], b[i]
	if x.at != y.at || x.kind != y.kind || x.node != y.node || x.conn != y.conn || x.gen != y.gen || x.len != y.len || x.hash != y.hash || x.arg != y.arg {
		fmt.eprintf("  the event itself differs, so the split is in what scheduled it\n")
	}
	if x.rngs != y.rngs {
		fmt.eprintf("  the world's random streams differ\n")
	}
	for k in 0 ..< MARK_DISKS {
		if x.disk[k] != y.disk[k] {
			fmt.eprintf("  disk %s differs: ops %d vs %d, trace %x vs %x\n", "relay" if k == MARK_DISKS - 1 else fmt.tprintf("n%d", k), x.ops[k], y.ops[k], x.disk[k], y.disk[k])
		}
	}
}

@(private = "file")
_mark_print :: proc(label: string, i: int, m: Ev_Mark) {
	fmt.eprintf("  %s ev %d at=%d now=%d kind=%v node=%d conn=%d gen=%d len=%d hash=%x arg=%d world=%x rngs=%x\n", label, i, m.at, m.now, m.kind, m.node, m.conn, m.gen, m.len, m.hash, m.arg, m.world, m.rngs)
}

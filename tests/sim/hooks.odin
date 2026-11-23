package sim

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import eng "../../src/engine"
import "../../src/prim"

Final_Check :: proc(w: ^World)
Restart_Hook :: proc(w: ^World, n: ^Node)
Event_Hook :: proc(w: ^World, ev: ^Sim_Event)
Engine_Event_Hook :: proc(w: ^World, n: ^Node, ev: ^eng.Event)
Frame_Filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> (drop: bool)
World_Hook :: proc(w: ^World)
Collect_Hook :: proc(w: ^World, res: ^Run_Result)
Op_Weight :: proc(w: ^World) -> int
Op_Run :: proc(w: ^World, n: ^Node)
Step_Hook :: proc(w: ^World, n: ^Node)

STATS_MAX :: 256
EV_EXT_BASE :: 128

Stat :: distinct int

Stat_Def :: struct {
	line:  int,
	order: int,
	name:  string,
	max:   bool,
	at:    runtime.Source_Code_Location,
}

Stat_Line :: struct {
	order:  int,
	prefix: string,
	at:     runtime.Source_Code_Location,
}

@(private = "file")
Ordered :: struct($P: typeid) {
	order: int,
	call:  P,
	at:    runtime.Source_Code_Location,
}

@(private = "file")
Restart_Entry :: struct {
	order:    int,
	call:     Restart_Hook,
	quiesced: bool,
	at:       runtime.Source_Code_Location,
}

@(private = "file")
Ext_Op :: struct {
	order:  int,
	name:   string,
	weight: Op_Weight,
	run:    Op_Run,
	at:     runtime.Source_Code_Location,
}

@(private = "file")
Table :: struct($T: typeid, $N: int) {
	items: [N]T,
	n:     int,
}

@(private = "file")
_push :: proc "contextless" (t: ^Table($T, $N), x: T) -> int {
	if t.n >= N {
		return -1
	}
	t.items[t.n] = x
	t.n += 1
	return t.n - 1
}

@(private = "file")
Registry :: struct {
	final_checks: Table(Ordered(Final_Check), 128),
	restarted:    Table(Restart_Entry, 64),
	events:       Table(Event_Hook, 64),
	engine_events: Table(Ordered(Engine_Event_Hook), 64),
	filters:      Table(Ordered(Frame_Filter), 16),
	inits:        Table(Ordered(World_Hook), 64),
	destroys:     Table(Ordered(World_Hook), 64),
	collects:     Table(Ordered(Collect_Hook), 64),
	steps:        Table(Ordered(Step_Hook), 64),
	ops:          Table(Ext_Op, 64),
	stats:        Table(Stat_Def, STATS_MAX),
	lines:        Table(Stat_Line, 64),
	sorted:       bool,
	overflow:     bool,
}

@(private = "file")
reg: Registry

@(private = "file")
_sorted :: proc() {
	assert(!reg.overflow)
	if reg.sorted {
		return
	}
	reg.sorted = true
	by :: proc(a, b: Ordered($P)) -> bool {
		return a.order < b.order
	}
	slice.stable_sort_by(reg.final_checks.items[:reg.final_checks.n], by)
	slice.stable_sort_by(reg.inits.items[:reg.inits.n], by)
	slice.stable_sort_by(reg.destroys.items[:reg.destroys.n], by)
	slice.stable_sort_by(reg.collects.items[:reg.collects.n], by)
	slice.stable_sort_by(reg.steps.items[:reg.steps.n], by)
	slice.stable_sort_by(reg.engine_events.items[:reg.engine_events.n], by)
	slice.stable_sort_by(reg.filters.items[:reg.filters.n], by)
	slice.stable_sort_by(reg.restarted.items[:reg.restarted.n], proc(a, b: Restart_Entry) -> bool {
		return a.order < b.order
	})
	slice.stable_sort_by(reg.ops.items[:reg.ops.n], proc(a, b: Ext_Op) -> bool {
		return a.order < b.order
	})
	slice.stable_sort_by(reg.lines.items[:reg.lines.n], proc(a, b: Stat_Line) -> bool {
		return a.order < b.order
	})
	_unique("final check", reg.final_checks.items[:reg.final_checks.n])
	_unique("world init", reg.inits.items[:reg.inits.n])
	_unique("world destroy", reg.destroys.items[:reg.destroys.n])
	_unique("collect", reg.collects.items[:reg.collects.n])
	_unique("step", reg.steps.items[:reg.steps.n])
	_unique("engine event", reg.engine_events.items[:reg.engine_events.n])
	_unique("frame filter", reg.filters.items[:reg.filters.n])
	_unique("restarted", reg.restarted.items[:reg.restarted.n])
	_unique("op", reg.ops.items[:reg.ops.n])
	_unique("stat line", reg.lines.items[:reg.lines.n])
	stats := reg.stats.items[:reg.stats.n]
	for a, i in stats {
		for b in stats[i + 1:] {
			if a.line == b.line && a.order == b.order {
				fmt.panicf("sim hooks: stat line %d order %d is registered twice, at %s:%d and %s:%d", a.line, a.order, a.at.file_path, a.at.line, b.at.file_path, b.at.line)
			}
		}
	}
}

@(private = "file")
_unique :: proc(table: string, items: []$T) {
	for i in 1 ..< len(items) {
		if items[i].order == items[i - 1].order {
			fmt.panicf("sim hooks: %s order %d is registered twice, at %s:%d and %s:%d", table, items[i].order, items[i - 1].at.file_path, items[i - 1].at.line, items[i].at.file_path, items[i].at.line)
		}
	}
}

@(private = "file")
_add :: proc "contextless" (t: ^Table($T, $N), x: T) -> int {
	i := _push(t, x)
	if i < 0 {
		reg.overflow = true
	}
	reg.sorted = false
	return i
}

register_final_check :: proc "contextless" (order: int, check: Final_Check, loc := #caller_location) {
	_add(&reg.final_checks, Ordered(Final_Check){order = order, call = check, at = loc})
}

register_restarted :: proc "contextless" (order: int, hook: Restart_Hook, quiesced := true, loc := #caller_location) {
	_add(&reg.restarted, Restart_Entry{order = order, call = hook, quiesced = quiesced, at = loc})
}

register_world :: proc "contextless" (order: int, init: World_Hook = nil, destroy: World_Hook = nil, loc := #caller_location) {
	if init != nil {
		_add(&reg.inits, Ordered(World_Hook){order = order, call = init, at = loc})
	}
	if destroy != nil {
		_add(&reg.destroys, Ordered(World_Hook){order = order, call = destroy, at = loc})
	}
}

register_collect :: proc "contextless" (order: int, hook: Collect_Hook, loc := #caller_location) {
	_add(&reg.collects, Ordered(Collect_Hook){order = order, call = hook, at = loc})
}

register_step :: proc "contextless" (order: int, hook: Step_Hook, loc := #caller_location) {
	_add(&reg.steps, Ordered(Step_Hook){order = order, call = hook, at = loc})
}

register_event :: proc "contextless" (hook: Event_Hook) -> Ev_Kind {
	return Ev_Kind(EV_EXT_BASE + _add(&reg.events, hook))
}

register_engine_event :: proc "contextless" (order: int, hook: Engine_Event_Hook, loc := #caller_location) {
	_add(&reg.engine_events, Ordered(Engine_Event_Hook){order = order, call = hook, at = loc})
}

register_frame_filter :: proc "contextless" (order: int, filter: Frame_Filter, loc := #caller_location) {
	_add(&reg.filters, Ordered(Frame_Filter){order = order, call = filter, at = loc})
}

@(private = "file")
Filter_Buf :: struct {
	gen: u64,
	buf: [dynamic]u8,
}

@(private = "file")
_filtering: bool

@(private = "file")
_filter_bufs: map[^Conn]Filter_Buf

frame_filter_enable :: proc(on: bool) {
	_filtering = on
	if !on {
		for _, fb in _filter_bufs {
			delete(fb.buf)
		}
		delete(_filter_bufs)
		_filter_bufs = nil
	}
}

frame_filtering :: proc "contextless" () -> bool {
	return _filtering && reg.filters.n > 0
}

run_frame_filters :: proc(w: ^World, c: ^Conn, bytes: []u8) -> []u8 {
	_sorted()
	if _filter_bufs == nil {
		_filter_bufs = make(map[^Conn]Filter_Buf, runtime.heap_allocator())
	}
	fb, found := &_filter_bufs[c]
	if !found {
		_filter_bufs[c] = Filter_Buf{gen = c.gen, buf = make([dynamic]u8, runtime.heap_allocator())}
		fb = &_filter_bufs[c]
	}
	if fb.gen != c.gen {
		clear(&fb.buf)
		fb.gen = c.gen
	}
	append(&fb.buf, ..bytes)
	out := make([dynamic]u8, context.temp_allocator)
	pos := 0
	for len(fb.buf) - pos >= FRAME_HEADER {
		n := int(prim.get_u32le(fb.buf[pos:pos + 4]))
		if len(fb.buf) - pos < FRAME_HEADER + n {
			break
		}
		frame := fb.buf[pos:pos + FRAME_HEADER + n]
		pos += FRAME_HEADER + n
		drop := false
		for f in reg.filters.items[:reg.filters.n] {
			if f.call(w, c, frame[4], frame[FRAME_HEADER:]) {
				drop = true
				break
			}
		}
		if !drop {
			append(&out, ..frame)
		}
	}
	remove_range(&fb.buf, 0, pos)
	return out[:]
}

register_op :: proc "contextless" (order: int, name: string, weight: Op_Weight, run: Op_Run, loc := #caller_location) {
	_add(&reg.ops, Ext_Op{order = order, name = name, weight = weight, run = run, at = loc})
}

register_stat_line :: proc "contextless" (order: int, prefix := "", loc := #caller_location) {
	_add(&reg.lines, Stat_Line{order = order, prefix = prefix, at = loc})
}

register_stat :: proc "contextless" (line: int, order: int, name: string, max := false, loc := #caller_location) -> Stat {
	return Stat(_add(&reg.stats, Stat_Def{line = line, order = order, name = name, max = max, at = loc}))
}

stat_add :: proc(w: ^World, s: Stat, v: u64 = 1) {
	w.stats.extra[int(s)] += v
}

stat_max :: proc(w: ^World, s: Stat, v: u64) {
	w.stats.extra[int(s)] = max(w.stats.extra[int(s)], v)
}

stat_get :: proc(st: ^World_Stats, s: Stat) -> u64 {
	return st.extra[int(s)]
}

stats_merge :: proc(into: ^World_Stats, from: ^World_Stats) {
	for d, i in reg.stats.items[:reg.stats.n] {
		if d.max {
			into.extra[i] = max(into.extra[i], from.extra[i])
		} else {
			into.extra[i] += from.extra[i]
		}
	}
}

stats_print :: proc(st: ^World_Stats) {
	_sorted()
	for l in reg.lines.items[:reg.lines.n] {
		idx := make([dynamic]int, context.temp_allocator)
		for d, i in reg.stats.items[:reg.stats.n] {
			if d.line == l.order {
				append(&idx, i)
			}
		}
		if len(idx) == 0 {
			continue
		}
		slice.stable_sort_by(idx[:], proc(a, b: int) -> bool {
			return reg.stats.items[a].order < reg.stats.items[b].order
		})
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "sim:")
		if len(l.prefix) > 0 {
			fmt.sbprintf(&b, " %s", l.prefix)
		}
		for i in idx {
			fmt.sbprintf(&b, " %s=%d", reg.stats.items[i].name, st.extra[i])
		}
		fmt.eprintf("%s\n", strings.to_string(b))
	}
}

run_final_checks :: proc(w: ^World) {
	_sorted()
	for c in reg.final_checks.items[:reg.final_checks.n] {
		c.call(w)
	}
}

run_restarted :: proc(w: ^World, n: ^Node, quiesce: bool) {
	_sorted()
	for h in reg.restarted.items[:reg.restarted.n] {
		if !quiesce || h.quiesced {
			h.call(w, n)
		}
	}
}

run_world_init :: proc(w: ^World) {
	_sorted()
	for h in reg.inits.items[:reg.inits.n] {
		h.call(w)
	}
}

run_world_destroy :: proc(w: ^World) {
	_sorted()
	for h in reg.destroys.items[:reg.destroys.n] {
		h.call(w)
	}
}

run_collect :: proc(w: ^World, res: ^Run_Result) {
	_sorted()
	for h in reg.collects.items[:reg.collects.n] {
		h.call(w, res)
	}
}

run_step :: proc(w: ^World, n: ^Node) {
	if reg.steps.n == 0 {
		return
	}
	_sorted()
	for h in reg.steps.items[:reg.steps.n] {
		h.call(w, n)
	}
}

run_engine_event :: proc(w: ^World, n: ^Node, ev: ^eng.Event) {
	_sorted()
	for h in reg.engine_events.items[:reg.engine_events.n] {
		h.call(w, n, ev)
	}
}

run_event :: proc(w: ^World, ev: ^Sim_Event) -> bool {
	i := int(ev.kind) - EV_EXT_BASE
	if i < 0 || i >= reg.events.n {
		return false
	}
	reg.events.items[i](w, ev)
	return true
}

ext_op_weights :: proc(w: ^World, out: ^[dynamic]int) {
	if reg.ops.n == 0 {
		return
	}
	_sorted()
	disabled, _ := os.lookup_env("SIM_DISABLE", context.temp_allocator)
	parts := strings.split(disabled, ",", context.temp_allocator)
	for op in reg.ops.items[:reg.ops.n] {
		wt := op.weight(w)
		for p in parts {
			if strings.equal_fold(strings.trim_space(p), op.name) {
				wt = 0
			}
		}
		append(out, wt)
	}
}

ext_op_run :: proc(w: ^World, n: ^Node, i: int) {
	_sorted()
	reg.ops.items[i].run(w, n)
}

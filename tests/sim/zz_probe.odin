package sim

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "base:runtime"
import eng "../../src/engine"

probe_tok: string
probe_last: string
probe_init: bool

probe_after :: proc(w: ^World) {
	if w.cfg.quiet {
		return
	}
	if !probe_init {
		probe_init = true
		v, ok := os.lookup_env("SIM_PROBE", context.temp_allocator)
		if ok {
			probe_tok = strings.clone(v, runtime.heap_allocator())
		}
	}
	if len(probe_tok) == 0 {
		return
	}
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	b := strings.builder_make(runtime.heap_allocator())
	defer strings.builder_destroy(&b)
	for op in w.model.ops {
		for t in op.tokens {
			if t == probe_tok {
				fmt.sbprintf(&b, "op%d=%v tick=%d;", op.idx, op.status, op.tick)
			}
		}
	}
	for n in w.nodes {
		files := make([dynamic]Disk_File, context.temp_allocator)
		disk_walk(&n.disk, &files)
		for f in files {
			if pf := os.get_env("SIM_PROBE_FILE", context.temp_allocator); len(pf) > 0 && strings.has_suffix(f.path, pf) && !strings.contains(f.path, "/.git/") {
				fmt.sbprintf(&b, "\n    %s:%s cache=%q durable=%q\n   ", n.name, f.path, string(f.data), string(f.durable))
			}
			c := strings.contains(string(f.data), probe_tok)
			d := strings.contains(string(f.durable), probe_tok)
			if c || d {
				fmt.sbprintf(&b, " %s:%s[%s%s]", n.name, f.path, "C" if c else "", "D" if d else "")
			}
		}
	}
	if tn, tok_ok := os.lookup_env("SIM_PROBE_TREE", context.temp_allocator); tok_ok && len(tn) > 0 {
		f := strings.split(tn, ":", context.temp_allocator)
		for n in w.nodes {
			if n.name != f[0] || !n.alive || !n.e_open || n.disk.dead {
				continue
			}
			for &ob in w.model.objs {
				if ob.kind != .Tree || id_short(ob.o.id) != f[1] {
					continue
				}
				{
					context = instance_context(&n.inst)
					n.disk.probe += 1
					data, err := eng.tree_read(&n.e, ob.o, f[2], runtime.heap_allocator())
					n.disk.probe -= 1
					fmt.sbprintf(&b, "\n    TREE %s inc=%d durable=%d %v %q\n   ", n.name, n.incarnation, 0, err, string(data))
					delete(data, runtime.heap_allocator())
				}
			}
		}
	}
	s := strings.to_string(b)
	if s != probe_last {
		delete(probe_last, runtime.heap_allocator())
		probe_last = strings.clone(s, runtime.heap_allocator())
		n := w.nodes[0]
		fmt.eprintf("PROBE ev %d t=%d.%06d n0 inc=%d durable=%d | %s\n", w.stats.events, w.now / 1_000_000_000, w.now % 1_000_000_000 / 1000, n.incarnation, n.durable, s)
	}
}

dprobe :: proc(d: ^Disk, path: string) -> bool {
	v, ok := os.lookup_env("SIM_PROBE_FILE", context.temp_allocator)
	if !ok || len(v) == 0 || d.probe != 0 || strings.contains(path, "/.git/") {
		return false
	}
	at := strings.last_index_byte(v, '/')
	dir := v[:at]
	return strings.has_suffix(path, v) || (strings.contains(path, dir) && strings.contains(path, ".0ndb-tmp")) || strings.contains(path, "attrib.log")
}

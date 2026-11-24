package sim

import "core:fmt"
import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
STAT_OWNER_SPANS: Stat

@(init)
_blame_owner_init :: proc "contextless" () {
	register_final_check(1010, _blame_owner_check)
	register_stat_line(69, "blame_owner")
	STAT_OWNER_SPANS = register_stat(69, 0, "spans")
}

@(private = "file")
_owner_text :: proc(n: ^Node, o: eng.Object, path: string, line: string) -> (text: string, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	owners: []fs.Span_Owner
	data, spans, err := eng.tree_blame(&n.e, o, path, context.temp_allocator, line, &owners)
	if err != .None {
		return "", false
	}
	b := strings.builder_make(n.w.allocator)
	at := 0
	for sp, k in spans {
		w := owners[k]
		if w.kind == .Unresolved {
			fmt.sbprintf(&b, "%d+%d unresolved %s|", at, sp.len, id_short(sp.id.actor))
		} else {
			fmt.sbprintf(&b, "%d+%d %v %s %s|", at, sp.len, w.kind, id_short(w.conversation), id_short(w.device))
		}
		at += sp.len
	}
	if at != len(data) {
		fmt.sbprintf(&b, "covers %d of %d", at, len(data))
	}
	return strings.to_string(b), true
}

@(private = "file")
_blame_owner_check :: proc(w: ^World) {
	if w.cfg.byzantine || w.aborted {
		return
	}
	m := &w.model
	for ob, oi in m.objs {
		if ob.kind != .Tree || !obj_exists(m, oi) {
			continue
		}
		for line in obj_lines(m, oi) {
			ref: map[string]string
			refn := ""
			for idx in readers_of(w, oi) {
				n := w.nodes[idx]
				if !n.alive || !digest_object(w, n, oi).complete {
					continue
				}
				names, lerr := tree_walk(n, ob.o, {}, line_eng(line))
				if lerr != .None {
					continue
				}
				got := make(map[string]string, context.temp_allocator)
				for name in names {
					text, ok := _owner_text(n, ob.o, name, line_eng(line))
					if !ok {
						continue
					}
					stat_add(w, STAT_OWNER_SPANS, u64(strings.count(text, "|")))
					if strings.contains(text, "unresolved") || strings.contains(text, "covers") {
						world_fail(w, "blame owner: %s %s/%s on %s after convergence: %s", n.name, id_short(ob.o.id), name, line_eng(line), text)
					}
					got[name] = text
				}
				if refn == "" {
					ref = got
					refn = n.name
					continue
				}
				for name in prim.sorted_keys(ref) {
					text := ref[name]
					if other, has := got[name]; has && other != text {
						world_fail(w, "blame owner: %s/%s on %s: %s says %s, %s says %s", id_short(ob.o.id), name, line_eng(line), refn, text, n.name, other)
					}
				}
			}
		}
	}
}

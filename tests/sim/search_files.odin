package sim

import "core:math"
import "core:slice"
import "core:strings"
import eng "../../src/engine"
import "../../src/prim"
import "../../src/search"

EMBED_DIM :: 16

sim_embedder :: proc() -> search.Embedder {
	return search.Embedder{dim = EMBED_DIM, embed = _embed, data = nil}
}

@(private = "file")
_embed :: proc(data: rawptr, kind: u8, text: []u8, out: []f32) -> bool {
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	if len(out) == 0 {
		return false
	}
	for i in 0 ..< max(len(text) - 2, 0) {
		h := mix_bytes(0x5eed, text[i:i + 3])
		out[h % u64(len(out))] += 1 if (h >> 32) & 1 == 0 else -1
	}
	norm: f32
	for v in out {
		norm += v * v
	}
	if norm == 0 {
		out[0] = 1
		return true
	}
	inv := 1 / math.sqrt(norm)
	for &v in out {
		v *= inv
	}
	return true
}

search_dir :: proc(n: ^Node) -> string {
	return strings.concatenate({NODE_DIR, "/pack/search"}, context.temp_allocator)
}

search_model_files :: proc(n: ^Node, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	if !n.alive || !n.e_open {
		return out[:]
	}
	vfs := eng.vfs(&n.e)
	d: prim.Dir
	if prim.dir_open(vfs, &d, search_dir(n), context.temp_allocator) != .None {
		return out[:]
	}
	defer prim.dir_close(vfs, &d)
	for {
		ent, ok, err := prim.dir_next(vfs, &d)
		if !ok || err != .None {
			break
		}
		if strings.has_prefix(ent.name, "zd-") || strings.has_prefix(ent.name, "vq-") {
			append(&out, strings.clone(ent.name, allocator))
		}
	}
	slice.sort(out[:])
	return out[:]
}

snapshot_search_models :: proc(w: ^World, n: ^Node, op: ^M_Op) {
	context = instance_context(&n.inst)
	names := search_model_files(n, context.temp_allocator)
	for nm in names {
		append(&op.gens, strings.clone(nm, w.allocator))
	}
}

check_search_models :: proc(w: ^World, secrets: []string, owners: []int) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		vfs := eng.vfs(&n.e)
		names := search_model_files(n)
		w.stats.search_models += u64(len(names))
		if len(names) > 0 {
			world_note(w, "%s search models %v", n.name, names)
		}
		for nm in names {
			path := strings.concatenate({search_dir(n), "/", nm}, context.temp_allocator)
			data, err := prim.read_file(vfs, path, context.temp_allocator)
			if err != .None {
				continue
			}
			for s, i in secrets {
				if token_in(string(data), s) {
					redaction_finding(w, n, owners[i], "redaction: %s still contains %s in search %s %s", n.name, s, "dictionary" if strings.has_prefix(nm, "zd-") else "codebook", nm)
				}
			}
		}
		if n.e.index_open && len(names) > 0 {
			ix := &n.e.index
			ix.taint_check = true
			if terr := search.taint_refresh(ix); terr == .None {
				if ix.zd_tainted {
					redaction_finding(w, n, -1, "redaction: search dictionary on %s was trained on redacted content and not retrained (%v)", n.name, names)
				}
				if ix.cb_tainted {
					redaction_finding(w, n, -1, "redaction: search codebook on %s was trained on redacted content and not retrained (%v)", n.name, names)
				}
			} else {
				world_note(w, "%s search taint check: %v", n.name, terr)
			}
		}
		node_after(n)
	}
}

quarantined :: proc(w: ^World, n: ^Node, oi: int) -> bool {
	if oi < 0 {
		return false
	}
	id := w.model.objs[oi].o.id
	for q in w.quarantines {
		if q.node == n.idx && q.object == id {
			return true
		}
	}
	return false
}

redaction_finding :: proc(w: ^World, n: ^Node, oi: int, format: string, args: ..any) {
	if w.cfg.byzantine && quarantined(w, n, oi) {
		w.stats.stalls += 1
		world_note(w, format, ..args)
		return
	}
	world_fail(w, format, ..args)
}

package sim

import eng "../../src/engine"
import "../../src/odb"

check_serve_rows :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		rows, err := eng.serve_rows(&n.e, context.temp_allocator)
		if err != .None {
			continue
		}
		db, derr := eng.device_odb(&n.e)
		if derr != .None {
			continue
		}
		for r in rows {
			hb: [odb.MAX_HEX]u8
			hex := odb.oid_to_string(r.oid, .Sha1 if r.n == 20 else .Sha256, &hb)
			if _, joined := n.e.spaces[r.space]; !joined {
				world_fail(w, "serve: %s keeps a serve row for blob %s of space %s, which it no longer holds", n.name, hex, id_short(r.space))
			} else if !odb.exists(db, r.oid) {
				world_fail(w, "serve: %s keeps a serve row for blob %s, which is gone from its device store", n.name, hex)
			}
		}
	}
}

@(init)
_serve_rows_hooks :: proc "contextless" () {
	register_final_check(6, check_serve_rows)
}

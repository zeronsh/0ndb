package sim

import eng "../../src/engine"
import "../../src/odb"

check_content_parked :: proc(w: ^World) {
	if w.cfg.byzantine {
		return
	}
	for n in w.nodes {
		if !n.alive || !n.e_open || n.partitioned {
			continue
		}
		context = instance_context(&n.inst)
		waits := eng.content_waits(&n.e, context.temp_allocator)
		for x in waits {
			if x.inflight {
				hb: [odb.MAX_HEX]u8
				world_fail(w, "content: %s's wait on blob %s of %s is still inflight at quiesce, after every holder it asked has answered", n.name, odb.oid_to_string(x.oid, .Sha1 if x.n == 20 else .Sha256, &hb), id_short(x.object))
				continue
			}
			for o in w.nodes {
				if o == n || !o.alive || !o.e_open || o.partitioned {
					continue
				}
				if _, member := o.e.spaces[x.space]; !member {
					continue
				}
				context = instance_context(&o.inst)
				db, derr := eng.device_odb(&o.e)
				has := derr == .None && odb.exists(db, x.oid)
				context = instance_context(&n.inst)
				if has {
					hb: [odb.MAX_HEX]u8
					world_fail(w, "content: %s still waits on blob %s of %s (inflight %v) at quiesce while %s, online, holds it", n.name, odb.oid_to_string(x.oid, .Sha1 if x.n == 20 else .Sha256, &hb), id_short(x.object), x.inflight, o.name)
					break
				}
			}
		}
	}
}

@(init)
_content_parked_hooks :: proc "contextless" () {
	register_final_check(6, check_content_parked)
}

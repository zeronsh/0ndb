package sim

import "../../src/fs"

@(private = "file")
STAT_SS_MOUNTS: Stat

check_switch_settles :: proc(w: ^World) {
	if len(w.failures) > 0 {
		return
	}
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		for &sm in n.mounts {
			if sm.m == nil {
				continue
			}
			stat_add(w, STAT_SS_MOUNTS)
			if to, pending := fs.mount_switch_pending(sm.m); pending {
				world_fail(w, "switch: %s's switch of %s to %s is still pending in phase %d at quiesce", n.name, sm.root, to, sm.m.switch_phase)
			}
		}
	}
}

@(init)
_switch_settles_register :: proc "contextless" () {
	register_final_check(1007, check_switch_settles)
	register_stat_line(36, "switch_settles")
	STAT_SS_MOUNTS = register_stat(36, 0, "mounts")
}

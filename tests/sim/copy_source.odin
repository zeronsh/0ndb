package sim

STAT_COPY_HOLDS: Stat
STAT_COPY_STALLS: Stat

@(init)
_copy_source_init :: proc "contextless" () {
	register_stat_line(74, "copy_sources")
	STAT_COPY_HOLDS = register_stat(74, 0, "holds")
	STAT_COPY_STALLS = register_stat(74, 1, "stalls")
	register_final_check(122, check_copy_sources)
}

check_copy_sources :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		stat_add(w, STAT_COPY_HOLDS, n.e.stats.copy_source_holds)
		stat_add(w, STAT_COPY_STALLS, n.e.stats.copy_source_stalls)
		if n.e.stats.copy_source_stalls > 0 {
			world_fail(w, "copy sources: %s stalled %d times on a copy whose source is absent from every complete stream", n.name, n.e.stats.copy_source_stalls)
		}
	}
}

package sim

STAT_FENCE_CRASHES: Stat
STAT_FENCE_CUTS: Stat

@(init)
_fences_init :: proc "contextless" () {
	register_world(26, _fences_world)
	register_collect(26, _fences_collect)
	register_stat_line(64, "fences")
	STAT_FENCE_CRASHES = register_stat(64, 0, "crashes_after_barrier")
	STAT_FENCE_CUTS = register_stat(64, 1, "crashes_cutting_a_fence")
}

@(private = "file")
_fences_world :: proc(w: ^World) {
	if w.cfg.crash_rate == 0 || env_u64("SIM_FENCE_CRASH", 0) == 0 {
		return
	}
	for n in w.nodes {
		if rng_chance(&w.rng, 1, 4) {
			n.disk.fence_crash = u64(50 + rng_int(&w.rng, 400))
		}
	}
}

@(private = "file")
_fences_collect :: proc(w: ^World, res: ^Run_Result) {
	for n in w.nodes {
		res.stats.extra[int(STAT_FENCE_CRASHES)] += n.disk.fence_crashes
		res.stats.extra[int(STAT_FENCE_CUTS)] += n.disk.fence_cuts
	}
}

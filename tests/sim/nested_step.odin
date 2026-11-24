package sim

import "../../src/prim"

@(private = "file")
Nested :: struct {
	on:    bool,
	rng:   Rng,
	depth: int,
}

@(private = "file")
_nested: Nested

@(private = "file")
STAT_NESTED_STEPS: Stat

@(init)
_nested_step_init :: proc "contextless" () {
	register_world(66, _nested_world, nil)
	register_wait_point(10, _nested_wait)
	register_stat_line(66, "nested_step")
	STAT_NESTED_STEPS = register_stat(66, 0, "steps")
}

@(private = "file")
_nested_world :: proc(w: ^World) {
	_nested = {}
	_nested.on = env_u64("SIM_NESTED_STEP", 1 if mix64(w.cfg.seed, 0x6e657374) % 3 == 1 else 0) != 0
	rng_init(&_nested.rng, w.cfg.seed, 0x6e657374)
}

@(private = "file")
_nested_wait :: proc(w: ^World, n: ^Node) {
	if !_nested.on || _nested.depth > 0 || !n.inst.loop_on || !rng_chance(&_nested.rng, 1, 2) {
		return
	}
	_nested.depth += 1
	defer _nested.depth -= 1
	stat_add(w, STAT_NESTED_STEPS)
	prim.loop_nest(&n.inst.loop)
	defer prim.loop_unnest(&n.inst.loop)
	prim.loop_step(&n.inst.loop, false)
}

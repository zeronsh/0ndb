package sim

import eng "../../src/engine"
import "../../src/prim"

STAT_BITROT_FLIPS: Stat
STAT_BITROT_DAMAGED: Stat
STAT_BITROT_RESTORED: Stat
STAT_BITROT_SCRUBBED: Stat

BITROT_SETTLE :: i64(120_000_000_000)

bitrot_on :: proc(w: ^World) -> bool {
	return env_u64("SIM_BITROT", 1 if mix64(w.cfg.seed, 0x62697472) % 3 == 0 else 0) != 0
}

bitrot_weight :: proc(w: ^World) -> int {
	return 2 if bitrot_on(w) else 0
}

bitrot_flip :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open {
		return
	}
	context = instance_context(&n.inst)
	own, err := eng.own_lengths(&n.e, context.temp_allocator)
	if err != .None {
		return
	}
	cands := make([dynamic]eng.Own_Length, context.temp_allocator)
	for o in own {
		if !o.device && o.uploaded > 0 && (o.kind == .Conversation || o.kind == .Map) {
			append(&cands, o)
		}
	}
	if len(cands) == 0 {
		return
	}
	o := cands[rng_int(&w.rng, len(cands))]
	at := i64(rng_int(&w.rng, int(o.uploaded)))
	bit := u8(1) << u8(rng_int(&w.rng, 8))
	fd, oerr := prim.open_file(n.e.vfs, o.path, {.Write})
	if oerr != .None {
		return
	}
	defer prim.close_file(n.e.vfs, fd)
	b: [1]u8
	if k, rerr := prim.read_at(n.e.vfs, fd, b[:], at); rerr != .None || k != 1 {
		return
	}
	b[0] ~= bit
	if env_u64("SIM_BITROT_DRY", 0) != 0 {
		return
	}
	if werr := prim.write_at(n.e.vfs, fd, b[:], at); werr != .None {
		return
	}
	stat_add(w, STAT_BITROT_FLIPS)
	world_note(w, "%s bit rot: flipped a bit at %d of its own %v %s (uploaded %d)", n.name, at, o.kind, id_short(o.object), o.uploaded)
}

@(init)
_bitrot_hooks :: proc "contextless" () {
	register_op(90, "bitrot", bitrot_weight, bitrot_flip)
	register_stat_line(47, "bitrot")
	STAT_BITROT_FLIPS = register_stat(47, 0, "flips")
	STAT_BITROT_DAMAGED = register_stat(47, 1, "damaged")
	STAT_BITROT_RESTORED = register_stat(47, 2, "restored")
	STAT_BITROT_SCRUBBED = register_stat(47, 3, "left_for_scrub")
}

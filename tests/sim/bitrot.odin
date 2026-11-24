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
	node_after(n)
	length, base, exists := relay_probe(w, o.space, o.stream)
	context = instance_context(&n.inst)
	if !exists || at < base || at >= length {
		return
	}
	if _bitrot_write(w, n, o, at, bit) {
		world_note(w, "%s bit rot: flipped a bit at %d of its own %v %s (uploaded %d)", n.name, at, o.kind, id_short(o.object), o.uploaded)
	}
}

@(private = "file")
_bitrot_write :: proc(w: ^World, n: ^Node, o: eng.Own_Length, at: i64, bit: u8) -> bool {
	fd, oerr := prim.open_file(n.e.vfs, o.path, {.Write})
	if oerr != .None {
		return false
	}
	defer prim.close_file(n.e.vfs, fd)
	b: [1]u8
	if k, rerr := prim.read_at(n.e.vfs, fd, b[:], at); rerr != .None || k != 1 {
		return false
	}
	b[0] ~= bit
	if werr := prim.write_at(n.e.vfs, fd, b[:], at); werr != .None {
		return false
	}
	stat_add(w, STAT_BITROT_FLIPS)
	return true
}

bitrot_settle :: proc(w: ^World) {
	if !bitrot_on(w) {
		return
	}
	found := 0
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		k, _ := eng.scrub(&n.e)
		node_after(n)
		found += k
	}
	if found > 0 {
		run_until(w, w.now + BITROT_SETTLE, true)
	}
	if stat_get(&w.stats, STAT_BITROT_FLIPS) == 0 {
		return
	}
	for n in w.nodes {
		if n.alive && n.e_open && !n.partitioned {
			context = instance_context(&n.inst)
			check_derived(n, "bit rot settle")
			node_after(n)
		}
	}
}

check_bitrot :: proc(w: ^World) {
	if !bitrot_on(w) {
		return
	}
	found := 0
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		k, err := eng.scrub(&n.e)
		node_after(n)
		if err != .None {
			world_fail(w, "bitrot: %s scrub failed: %v", n.name, err)
		}
		found += k
	}
	stat_add(w, STAT_BITROT_SCRUBBED, u64(found))
	if found > 0 {
		run_until(w, w.now + BITROT_SETTLE, true)
	}
	for n in w.nodes {
		if !n.alive || !n.e_open {
			continue
		}
		context = instance_context(&n.inst)
		k, err := eng.scrub(&n.e)
		stat_add(w, STAT_BITROT_DAMAGED, n.e.stats.damaged)
		stat_add(w, STAT_BITROT_RESTORED, n.e.stats.restored)
		node_after(n)
		if err == .None && k > 0 {
			world_fail(w, "bitrot: %s still has %d own streams with a damaged record after a scrub", n.name, k)
		}
	}
}

@(init)
_bitrot_hooks :: proc "contextless" () {
	register_op(90, "bitrot", bitrot_weight, bitrot_flip)
	register_final_check(2, bitrot_settle)
	register_final_check(115, check_bitrot)
	register_stat_line(47, "bitrot")
	STAT_BITROT_FLIPS = register_stat(47, 0, "flips")
	STAT_BITROT_DAMAGED = register_stat(47, 1, "damaged")
	STAT_BITROT_RESTORED = register_stat(47, 2, "restored")
	STAT_BITROT_SCRUBBED = register_stat(47, 3, "left_for_scrub")
}

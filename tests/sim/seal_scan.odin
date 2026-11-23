package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
SEAL_MSGS :: 240

@(private = "file")
SEAL_REDACTS :: 24

@(private = "file")
SEAL_BOUND :: 96

seal_scan_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_seal_scan(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_seal_text :: proc(i: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "message %d of a long-lived conversation: ", i)
	for strings.builder_len(b) < 480 {
		fmt.sbprintf(&b, "filler %d ", strings.builder_len(b))
	}
	return strings.to_string(b)
}

@(private = "file")
_seal_held :: proc(n: ^Node, o: eng.Object, rid: eng.Rid) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	_, err := eng.convo_message(&n.e, o, convo.Position{msg = rid}, context.temp_allocator)
	return err == .None
}

@(private = "file")
_seal_scan :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	rids := make([dynamic]eng.Rid, w.allocator)
	defer delete(rids)
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "seals", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "seal scan: space setup: %v", err)
			return
		}
		space = id
		proof, perr := eng.member_add(&a.e, space, b.identity, .Device, .Member, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "seal scan: member_add: %v", perr)
			return
		}
		o, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "seals"})
		if err != .None {
			world_fail(w, "seal scan: convo_create: %v", err)
			return
		}
		node_after(a)
		context = instance_context(&b.inst)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "seals", "relay", w.relay.public); jerr != .None {
			world_fail(w, "seal scan: join: %v", jerr)
			return
		}
		eng.space_open(&b.e, space)
		node_after(b)
	}
	for i in 0 ..< SEAL_MSGS {
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			rid, err := eng.convo_send(&a.e, o, _seal_text(i))
			if err != .None && err != .Pending {
				world_fail(w, "seal scan: convo_send %d: %v", i, err)
				return
			}
			append(&rids, rid)
		}
		if i % 20 == 19 {
			run_until(w, w.now + 500_000_000, true)
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	held := false
	for i := 0; i < 120 && !held; i += 1 {
		held = _seal_held(b, o, rids[0]) && _seal_held(b, o, rids[len(rids) - 1])
		if !held {
			run_until(w, w.now + 500_000_000, false)
		}
	}
	if !held {
		world_fail(w, "seal scan: %s never read the first and last messages, so the check proves nothing", b.name)
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	lookups, rounds, worst, worst_round := u64(0), 0, u64(0), -1
	first := true
	for i in 0 ..< SEAL_REDACTS {
		l0, s0 := b.e.stats.seal_lookups, b.e.stats.seal_scanned
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			if err := eng.convo_redact(&a.e, o, rids[i]); err != .None && err != .Pending {
				world_fail(w, "seal scan: convo_redact %d: %v", i, err)
				return
			}
		}
		run_until(w, w.now + 10_000_000_000, true)
		dl, ds := b.e.stats.seal_lookups - l0, b.e.stats.seal_scanned - s0
		if dl == 0 {
			continue
		}
		lookups += dl
		rounds += 1
		if first {
			first = false
			continue
		}
		if per := ds / dl; per > worst {
			worst, worst_round = per, i
		}
	}
	if rounds < SEAL_REDACTS / 2 || lookups < u64(SEAL_REDACTS / 2) {
		world_fail(w, "seal scan: %s looked up seals for %d of %d redactions (%d lookups), so the check proves nothing", b.name, rounds, SEAL_REDACTS, lookups)
		return
	}
	if worst > SEAL_BOUND {
		world_fail(w, "seal scan: redacting message %d far behind the tail of a %d-message conversation made %s scan %d records per seal lookup (bound %d)", worst_round, SEAL_MSGS, b.name, worst, SEAL_BOUND)
	}
}

@(test)
seal_scan :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := seal_scan_run(1)
	for f in failures {
		fmt.eprintf("seal_scan: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "seal_scan failed")
	delete(failures)
}

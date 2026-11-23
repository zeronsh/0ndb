package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

@(private = "file")
TIE_ROUNDS :: 8

epoch_tie_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 3
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
	_epoch_tie(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_tie_epoch :: proc(n: ^Node, space: prim.Id) -> (u32, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	st, err := eng.space_members_status(&n.e, space)
	return st.epoch, err == .None
}

@(private = "file")
_tie_write :: proc(w: ^World, n: ^Node, o: eng.Object, text: string) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	cur, err := eng.text_read(&n.e, o, context.temp_allocator)
	if err != .None {
		world_fail(w, "epoch tie: %s text_read before its write: %v", n.name, err)
		return false
	}
	if eerr := eng.text_edit(&n.e, o, len(cur), 0, text); eerr != .None && eerr != .Pending {
		world_fail(w, "epoch tie: %s text_edit: %v", n.name, eerr)
		return false
	}
	return true
}

@(private = "file")
_tie_sees :: proc(w: ^World, n: ^Node, o: eng.Object, want: string, ms: i64) -> bool {
	for i: i64 = 0; i < ms / 500; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		context = instance_context(&n.inst)
		data, err := eng.text_read(&n.e, o, context.temp_allocator)
		node_after(n)
		if err == .None && strings.contains(string(data), want) {
			return true
		}
	}
	return false
}

@(private = "file")
_epoch_tie :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b, c := w.nodes[0], w.nodes[1], w.nodes[2]
	if !node_start(a) || !node_start(b) || !node_start(c) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	setup: {
		context = instance_context(&a.inst)
		id, err := eng.space_create(&a.e, "tie", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "epoch tie: space setup: %v", err)
			return
		}
		space = id
		info, _ := eng.space_info(&a.e, space)
		if info.mode != .End_To_End {
			world_fail(w, "epoch tie: the space is %v, not end to end, so the check proves nothing", info.mode)
			return
		}
		pb, berr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		pc, cerr := eng.member_add(&a.e, space, c.identity, .Device, .Member, .Approval, 0, w.allocator)
		if berr != .None || cerr != .None {
			world_fail(w, "epoch tie: member_add: %v %v", berr, cerr)
			return
		}
		o, err = eng.text_create(&a.e, space, "tie", "base\n")
		if err != .None {
			world_fail(w, "epoch tie: text_create: %v", err)
			return
		}
		node_after(a)
		for x in ([]struct {
				n: ^Node,
				p: []u8,
			}{{b, pb}, {c, pc}}) {
			context = instance_context(&x.n.inst)
			if _, jerr := eng.space_join_enrollment(&x.n.e, space, x.p, "tie", "relay", w.relay.public); jerr != .None {
				world_fail(w, "epoch tie: %s join: %v", x.n.name, jerr)
				return
			}
			if oerr := eng.space_open(&x.n.e, space); oerr != .None {
				world_fail(w, "epoch tie: %s space_open: %v", x.n.name, oerr)
				return
			}
			node_after(x.n)
		}
	}
	if !_tie_sees(w, c, o, "base", 30_000) {
		world_fail(w, "epoch tie: the reader never read the text, so the check proves nothing")
		return
	}
	ties := 0
	for round in 0 ..< TIE_ROUNDS {
		a.partitioned = true
		for cn in a.conns {
			conn_reset(cn, true)
		}
		run_until(w, w.now + 500_000_000, false)
		rotate_b: {
			context = instance_context(&b.inst)
			defer node_after(b)
			if err := eng.space_rotate(&b.e, space); err != .None {
				world_fail(w, "epoch tie: round %d: %s rotate: %v", round, b.name, err)
				return
			}
		}
		run_until(w, w.now + 3_000_000_000, false)
		rotate_a: {
			context = instance_context(&a.inst)
			defer node_after(a)
			if err := eng.space_rotate(&a.e, space); err != .None {
				world_fail(w, "epoch tie: round %d: %s rotate while partitioned: %v", round, a.name, err)
				return
			}
		}
		ea, aok := _tie_epoch(a, space)
		eb, bok := _tie_epoch(b, space)
		if aok && bok && ea == eb {
			ties += 1
		}
		before := fmt.aprintf("before-%d\n", round, allocator = w.allocator)
		defer delete(before, w.allocator)
		if !_tie_write(w, a, o, before) {
			return
		}
		run_until(w, w.now + 500_000_000, false)
		a.partitioned = false
		if !_tie_sees(w, c, o, before, 60_000) {
			world_fail(w, "epoch tie: round %d: the reader never read what the writer wrote under its own epoch %d while cut off", round, ea)
			return
		}
		after := fmt.aprintf("after-%d\n", round, allocator = w.allocator)
		defer delete(after, w.allocator)
		if !_tie_write(w, a, o, after) {
			return
		}
		if !_tie_sees(w, c, o, after, 60_000) {
			world_fail(w, "epoch tie: round %d: the reader never read the writer's text after two admins each made epoch %d concurrently and the writer re-keyed to the one the roster chose", round, ea)
			return
		}
		run_until(w, w.now + 2_000_000_000, false)
	}
	if ties == 0 {
		world_fail(w, "epoch tie: no round produced two epochs with the same number, so the check proves nothing")
	}
	for n in ([]^Node{a, b, c}) {
		if n.accused > 0 {
			world_fail(w, "epoch tie: %s accused the relay or a peer of tampering %d times while every device was honest", n.name, n.accused)
		}
	}
}

@(test)
epoch_tie :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := epoch_tie_run(1)
	for f in failures {
		fmt.eprintf("epoch_tie: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "epoch_tie failed")
	delete(failures)
}

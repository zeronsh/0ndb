package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/convo"
import "../../src/journal"
import "../../src/obj"
import "../../src/prim"

@(private = "file")
OP_N :: 24

Op_Shape :: enum u8 {
	Last,
	Middle,
	First,
}

Op_Arm :: struct {
	shape: Op_Shape,
	peer:  bool,
}

@(private = "file")
_op_run :: proc(seed: u64, arm: Op_Arm) -> (failures: [dynamic]string) {
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
	cfg.storage = .Device
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_op_restore(w, arm)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_op_flip :: proc(n: ^Node, path: string, near: i64) -> bool {
	fd, oerr := prim.open_file(n.e.vfs, path, {.Write})
	if oerr != .None {
		return false
	}
	defer prim.close_file(n.e.vfs, fd)
	head: [4]u8
	off: i64
	for {
		if k, rerr := prim.read_at(n.e.vfs, fd, head[:], off); rerr != .None || k != 4 {
			return false
		}
		size := i64(prim.get_u32le(head[:])) + journal.OVERHEAD
		if off + size > near {
			break
		}
		off += size
	}
	at := off + journal.HEADER + 1
	b: [1]u8
	if k, rerr := prim.read_at(n.e.vfs, fd, b[:], at); rerr != .None || k != 1 {
		return false
	}
	b[0] ~= 0x10
	if werr := prim.write_at(n.e.vfs, fd, b[:], at); werr != .None {
		return false
	}
	return prim.fullsync(n.e.vfs, fd) == .None
}

@(private = "file")
_op_read_all :: proc(n: ^Node, o: eng.Object) -> (count: int, err: eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	pg, perr := eng.convo_page(&n.e, o, {}, 64, context.temp_allocator)
	return len(pg.messages), perr
}

@(private = "file")
_op_restore :: proc(w: ^World, arm: Op_Arm) {
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
	proof: []u8
	o: eng.Object
	msgs: [OP_N]obj.Rid
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "restore", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "own restore: space: %v", err)
			return
		}
		space = id
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "own restore: member_add: %v", err)
			return
		}
		if o, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "restore"}); err != .None {
			world_fail(w, "own restore: convo_create: %v", err)
			return
		}
	}
	defer delete(proof, w.allocator)
	join: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "restore", "relay", w.relay.public); err != .None {
			world_fail(w, "own restore: join: %v", err)
			return
		}
		eng.space_open(&b.e, space)
	}
	run_until(w, w.now + 5_000_000_000, true)
	for i in 0 ..< OP_N {
		send: {
			context = instance_context(&a.inst)
			defer node_after(a)
			m, serr := eng.convo_send(&a.e, o, fmt.tprintf("message %d", i))
			if serr != .None && serr != .Pending {
				world_fail(w, "own restore: send %d: %v", i, serr)
				return
			}
			msgs[i] = m
		}
		run_until(w, w.now + 200_000_000, true)
	}
	run_until(w, w.now + 5_000_000_000, true)
	seen := 0
	for _ in 0 ..< 20 {
		c, _ := _op_read_all(b, o)
		seen = c
		if seen == OP_N {
			break
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	if seen != OP_N {
		world_fail(w, "own restore: the peer read only %d of %d messages before the damage, so the check proves nothing", seen, OP_N)
		return
	}
	damage: {
		context = instance_context(&a.inst)
		defer node_after(a)
		eng.flush(&a.e)
		own, err := eng.own_lengths(&a.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "own restore: own_lengths: %v", err)
			return
		}
		at := OP_N - 1 if arm.shape == .Last else 12 if arm.shape == .Middle else 0
		damaged := false
		for x in own {
			if x.object == o.id && x.kind == .Conversation {
				damaged = _op_flip(a, x.path, msgs[at].off)
			}
		}
		found, serr := eng.scrub(&a.e)
		if !damaged || serr != .None || found == 0 {
			world_fail(w, "own restore: no damage was made (flip %v, scrub %d %v)", damaged, found, serr)
			return
		}
	}
	if !arm.peer {
		peer_off: {
			context = instance_context(&b.inst)
			b.partitioned = true
			for c in b.conns {
				conn_reset(c, true)
			}
			node_after(b)
		}
	}
	run_until(w, w.now + 40_000_000_000, true)
	context = instance_context(&a.inst)
	defer node_after(a)
	pg, perr := eng.convo_page(&a.e, o, {}, 64, context.temp_allocator)
	if arm.peer {
		if perr != .None || len(pg.messages) != OP_N {
			world_fail(w, "own restore %v: with a peer holding the record, the conversation reads %d messages (%v), want %d", arm, len(pg.messages), perr, OP_N)
			return
		}
		for i in 0 ..< OP_N {
			m, merr := eng.convo_message(&a.e, o, convo.Position{msg = msgs[i]}, context.temp_allocator)
			if merr != .None || msg_text(m) != fmt.tprintf("message %d", i) {
				world_fail(w, "own restore %v: message %d reads %q (%v)", arm, i, strings.clone(msg_text(m), context.temp_allocator), merr)
				return
			}
		}
	} else if perr == .None && len(pg.messages) == OP_N {
		world_fail(w, "own restore %v: restored with no holder reachable, which would prove the check tests nothing", arm)
	}
}

@(test)
own_restore_peer :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for peer in ([]bool{false, true}) {
		for shape in Op_Shape {
			arm := Op_Arm{shape, peer}
			failures := _op_run(1, arm)
			for f in failures {
				fmt.eprintf("own_restore_peer: %s\n", f)
				delete(f)
			}
			fmt.eprintf("own_restore_peer: %v failures=%d\n", arm, len(failures))
			testing.expect(t, len(failures) == 0, fmt.tprintf("own_restore_peer %v failed", arm))
			delete(failures)
		}
	}
}

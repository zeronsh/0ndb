package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/convo"
import "../../src/journal"
import "../../src/obj"
import "../../src/prim"

@(private = "file")
Ur_Op :: enum u8 {
	Status,
	Page,
	Window,
	Peek_Switch,
	Message,
	Siblings,
	Intents,
	Mounts,
	Files_At,
	Compactions,
	Unsealed,
	Settings,
	Undos,
	Left,
	Regenerating,
	Send,
	Move,
	Switch,
	Undo,
	Redo,
	Regenerate,
}

@(private = "file")
UR_N :: 24

@(private = "file")
Ur_Shape :: enum u8 {
	None,
	Last,
	Middle,
	First,
}

@(private = "file")
Ur_Ids :: struct {
	msgs: [UR_N]obj.Rid,
	undo: prim.Id,
}

@(private = "file")
_ur_is_move :: proc(op: Ur_Op) -> bool {
	return op >= .Send
}

@(private = "file")
_ur_call :: proc(n: ^Node, o: eng.Object, op: Ur_Op, ids: ^Ur_Ids) -> eng.Error {
	e := &n.e
	a := context.temp_allocator
	mid := ids.msgs[12]
	err: eng.Error
	switch op {
	case .Status:
		_, err = eng.convo_status(e, o)
	case .Page:
		_, err = eng.convo_page(e, o, {}, 64, a)
	case .Window:
		_, err = eng.convo_window(e, o, mid, 4, 4, {}, a)
	case .Peek_Switch:
		_, _, err = eng.convo_peek_switch(e, o, mid, 4, 4, a)
	case .Message:
		_, err = eng.convo_message(e, o, convo.Position{msg = mid}, a)
	case .Siblings:
		_, _, err = eng.convo_siblings(e, o, mid, a)
	case .Intents:
		_, err = eng.convo_intents(e, o, a)
	case .Mounts:
		_, err = eng.convo_mounts(e, o, a)
	case .Files_At:
		_, err = eng.convo_files_at(e, o, ids.msgs[UR_N - 1], a)
	case .Compactions:
		_, err = eng.convo_compactions(e, o, 0, a)
	case .Unsealed:
		_, err = eng.convo_unsealed(e, o, a)
	case .Settings:
		_, err = eng.convo_settings(e, o, a)
	case .Undos:
		_, err = eng.convo_undos(e, o, a)
	case .Left:
		_, err = eng.convo_left(e, o, a)
	case .Regenerating:
		_, err = eng.convo_regenerating(e, o)
	case .Send:
		_, err = eng.convo_send(e, o, "after the damage")
	case .Move:
		_, err = eng.convo_move(e, o, .Switch, ids.msgs[5])
	case .Switch:
		_, err = eng.convo_switch(e, o, ids.msgs[5])
	case .Undo:
		_, err = eng.convo_undo(e, o, ids.msgs[UR_N - 1])
	case .Redo:
		_, err = eng.convo_redo(e, o, ids.undo)
	case .Regenerate:
		_, err = eng.convo_regenerate(e, o, ids.msgs[UR_N - 1])
	}
	return err
}

unrestorable_run :: proc(seed: u64, op: Ur_Op, shape: Ur_Shape) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 1
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
	_unrestorable(w, op, shape)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_unrestorable :: proc(w: ^World, op: Ur_Op, shape: Ur_Shape) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "node start")
		return
	}
	o: eng.Object
	ids: Ur_Ids
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "damaged")
		if err != .None || eng.space_open(&a.e, space) != .None || eng.space_set_relay(&a.e, space, "relay", w.relay.public) != .None {
			world_fail(w, "unrestorable: space: %v", err)
			return
		}
		o, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "damaged"})
		if err != .None {
			world_fail(w, "unrestorable: convo_create: %v", err)
			return
		}
	}
	for i in 0 ..< UR_N {
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			m, serr := eng.convo_send(&a.e, o, fmt.tprintf("message %d", i))
			if serr != .None && serr != .Pending {
				world_fail(w, "unrestorable: send %d: %v", i, serr)
				return
			}
			ids.msgs[i] = m
		}
		run_until(w, w.now + 200_000_000, true)
	}
	if op == .Redo {
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			u, uerr := eng.convo_undo(&a.e, o, ids.msgs[UR_N - 1])
			if uerr != .None && uerr != .Pending {
				world_fail(w, "unrestorable: the undo before the redo: %v", uerr)
				return
			}
			ids.undo = u
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	run_until(w, w.now + 5_000_000_000, true)
	first: eng.Error
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		eng.flush(&a.e)
		own, err := eng.own_lengths(&a.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "unrestorable: own_lengths: %v", err)
			return
		}
		at := UR_N - 1 if shape == .Last else 12 if shape == .Middle else 0
		damaged := shape == .None
		for x in own {
			if x.object == o.id && x.kind == .Conversation && shape != .None {
				damaged = _flip(a, x.path, ids.msgs[at].off)
			}
		}
		if !damaged {
			world_fail(w, "unrestorable: no damage was made")
			return
		}
		if env_u64("UR_STAGE", 0) != 0 {
			fmt.eprintf("UR %v %v before found: %v\n", shape, op, _ur_call(a, o, op, &ids))
		}
		found, serr := eng.scrub(&a.e)
		fmt.eprintf("UR %v %v scrub found %d %v\n", shape, op, found, serr)
		first = _ur_call(a, o, op, &ids)
	}
	run_until(w, w.now + 20_000_000_000, true)
	second: eng.Error
	pending: bool
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		second = _ur_call(a, o, op, &ids)
		pending = eng.convo_move_pending(&a.e, o)
	}
	run_until(w, w.now + 20_000_000_000, true)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		pg, perr := eng.convo_page(&a.e, o, {}, 64, context.temp_allocator)
		st, sterr := eng.convo_status(&a.e, o)
		_, snd := eng.convo_send(&a.e, o, "carry on")
		_, rd := eng.convo_message(&a.e, o, convo.Position{msg = ids.msgs[2]}, context.temp_allocator)
		fmt.eprintf("UR %v %v first %v later %v pending-after %v now-pending %v | page %v (%d) status %v head-status %v send %v msg2 %v\n", shape, op, first, second, pending, eng.convo_move_pending(&a.e, o), perr, len(pg.messages), sterr, st.head_status, snd, rd)
	}
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		_, serr := eng.space_create(&a.e, "other")
		fmt.eprintf("UR %v %v other space %v\n", shape, op, serr)
	}
}

@(private = "file")
_flip :: proc(n: ^Node, path: string, near: i64) -> bool {
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

@(test)
unrestorable :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for shape in Ur_Shape {
		for op in ([]Ur_Op{.Send, .Undo, .Move, .Switch, .Redo, .Regenerate, .Page}) {
			failures := unrestorable_run(1, op, shape)
			for f in failures {
				fmt.eprintf("unrestorable: %s\n", f)
				delete(f)
			}
			testing.expect(t, len(failures) == 0, fmt.tprintf("unrestorable %v %v failed", op, shape))
			delete(failures)
		}
	}
}

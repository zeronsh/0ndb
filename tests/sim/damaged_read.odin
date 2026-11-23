package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/convo"
import "../../src/journal"
import "../../src/obj"
import "../../src/prim"

damaged_read_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_damaged_read(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_damaged_read :: proc(w: ^World) {
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
	last: obj.Rid
	woke: int
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "damaged")
		if err != .None {
			world_fail(w, "damaged read: space_create: %v", err)
			return
		}
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "damaged read: space_open: %v", oerr)
			return
		}
		if rerr := eng.space_set_relay(&a.e, space, "relay", w.relay.public); rerr != .None {
			world_fail(w, "damaged read: space_set_relay: %v", rerr)
			return
		}
		o, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "damaged"})
		if err != .None {
			world_fail(w, "damaged read: convo_create: %v", err)
			return
		}
	}
	for i in 0 ..< 24 {
		text := fmt.tprintf("message %d", i)
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			m, serr := eng.convo_send(&a.e, o, text)
			if serr != .None && serr != .Pending {
				world_fail(w, "damaged read: send %s: %v", text, serr)
				return
			}
			last = m
		}
		run_until(w, w.now + 200_000_000, true)
	}
	run_until(w, w.now + 5_000_000_000, true)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		eng.flush(&a.e)
		own, err := eng.own_lengths(&a.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "damaged read: own_lengths: %v", err)
			return
		}
		damaged := false
		for x in own {
			if x.object != o.id || x.kind != .Conversation {
				continue
			}
			if x.uploaded < x.durable {
				world_fail(w, "damaged read: the conversation is not uploaded before the bit flip (%d of %d)", x.uploaded, x.durable)
				return
			}
			damaged = _flip(a, x.path, last.off)
		}
		if !damaged {
			world_fail(w, "damaged read: could not flip a bit in the conversation's own stream")
			return
		}
		found, serr := eng.scrub(&a.e)
		if serr != .None || found == 0 {
			world_fail(w, "damaged read: scrub found %d damaged streams (%v)", found, serr)
			return
		}
		_, merr := eng.convo_message(&a.e, o, convo.Position{msg = last}, context.temp_allocator)
		if merr == .Not_Found || merr == .Corrupt {
			world_fail(w, "damaged read: convo_message on a message in a damaged own record answers %v while its repair is pending", merr)
		}
		_, perr := eng.convo_page(&a.e, o, {}, 8, context.temp_allocator)
		if perr == .Not_Found || perr == .Corrupt {
			world_fail(w, "damaged read: convo_page over a damaged own record answers %v while its repair is pending", perr)
		}
		_, werr := eng.convo_page(&a.e, o, {}, 8, context.temp_allocator, eng.Ready{data = &woke, call = _woke})
		if werr != .Pending {
			world_fail(w, "damaged read: convo_page with a ready callback answers %v while the repair is pending, want Pending", werr)
		}
	}
	run_until(w, w.now + 10_000_000_000, true)
	if woke == 0 {
		world_fail(w, "damaged read: the restore did not wake a read waiting on it")
	}
	context = instance_context(&a.inst)
	defer node_after(a)
	msg, merr := eng.convo_message(&a.e, o, convo.Position{msg = last}, context.temp_allocator)
	if merr != .None {
		world_fail(w, "damaged read: after the repair the last message reads as %v", merr)
		return
	}
	if msg_text(msg) != "message 23" {
		world_fail(w, "damaged read: after the repair the last message is %q", msg_text(msg))
	}
}

@(private = "file")
_woke :: proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
	(^int)(data)^ += 1
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
damaged_read :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := damaged_read_run(1)
	for f in failures {
		fmt.eprintf("damaged_read: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "damaged_read failed")
	delete(failures)
}

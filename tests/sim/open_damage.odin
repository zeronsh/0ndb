package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/convo"
import "../../src/journal"
import "../../src/obj"
import "../../src/prim"
import rt "../../src/runtime"

open_damage_run :: proc(seed: u64, body: bool) -> (failures: [dynamic]string) {
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
	_open_damage(w, body)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
Own_Copy :: struct {
	object: prim.Id,
	kind:   eng.Kind,
	path:   string,
	bytes:  []u8,
}

@(private = "file")
_open_damage :: proc(w: ^World, body: bool) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	last: obj.Rid
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "open damage", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "open damage: space setup: %v", err)
			return
		}
		space = id
		o, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "open damage"})
		if err != .None {
			world_fail(w, "open damage: convo_create: %v", err)
			return
		}
	}
	for i in 0 ..< 8 {
		text := fmt.tprintf("message %d", i)
		{
			context = instance_context(&a.inst)
			defer node_after(a)
			m, serr := eng.convo_send(&a.e, o, text)
			if serr != .None && serr != .Pending {
				world_fail(w, "open damage: send %s: %v", text, serr)
				return
			}
			last = m
		}
		run_until(w, w.now + 200_000_000, true)
	}
	run_until(w, w.now + 5_000_000_000, true)
	catalog: eng.Object
	copies: [2]Own_Copy
	flip: {
		context = instance_context(&a.inst)
		defer node_after(a)
		eng.flush(&a.e)
		catalog = eng.space_catalog(&a.e, space)
		own, err := eng.own_lengths(&a.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "open damage: own_lengths: %v", err)
			return
		}
		n := 0
		for x in own {
			if x.object != catalog.id && x.object != o.id {
				continue
			}
			if x.uploaded < x.durable || x.durable <= 0 {
				world_fail(w, "open damage: %s is not uploaded before the bit flip (%d of %d)", id_short(x.object), x.uploaded, x.durable)
				return
			}
			b, ok := _read_prefix(a, x.path, x.durable)
			if !ok {
				world_fail(w, "open damage: could not read %s", x.path)
				return
			}
			if n == len(copies) {
				break
			}
			copies[n] = Own_Copy{x.object, x.kind, fmt.aprintf("%s", x.path, allocator = w.allocator), b}
			n += 1
			if !_flip_last(a, x.path, x.durable, body) {
				world_fail(w, "open damage: could not flip a bit in the last record of %s", id_short(x.object))
				return
			}
		}
		if n != 2 {
			world_fail(w, "open damage: found %d of the catalog and the conversation among the own streams", n)
			return
		}
		eng.flush(&a.e)
	}
	r := new(rt.Runtime, w.allocator)
	r_on := false
	defer if r_on && a.alive {
		_runtime_close(a, r)
	}
	node_kill(a)
	disk_crash(&a.disk, .Power, &w.fault_rng)
	a.boot += 1
	if !node_start(a) {
		world_fail(w, "open damage: restart after the power cut")
		return
	}
	attach: {
		context = instance_context(&a.inst)
		defer node_after(a)
		if err := rt.open(r, &a.e, rt.Config{runner = true, home_dir = NODE_DIR + "/home", work_root = NODE_DIR + "/work", capacity = 1}, context.allocator); err != .None {
			world_fail(w, "open damage: runtime open: %v", err)
			return
		}
		r_on = true
		if err := rt.attach(r, space); err != .None {
			world_fail(w, "open damage: attach over a damaged catalog answers %v, want it to wait for the restore", err)
			return
		}
		if _advertised(a, space) {
			world_fail(w, "open damage: the runner advertised before its damaged catalog was restored")
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	context = instance_context(&a.inst)
	defer node_after(a)
	if !_advertised(a, space) {
		world_fail(w, "open damage: attach never completed after the catalog's restore")
	}
	for c in copies {
		b, ok := _read_prefix(a, c.path, i64(len(c.bytes)))
		if !ok || string(b) != string(c.bytes) {
			world_fail(w, "open damage: %v %s is not byte-identical to its copy before the flip after the restore", c.kind, id_short(c.object))
		}
	}
	msg, merr := eng.convo_message(&a.e, o, convo.Position{msg = last}, context.temp_allocator)
	if merr != .None || msg_text(msg) != "message 7" {
		world_fail(w, "open damage: after the restore the last message reads %q (%v)", msg_text(msg), merr)
	}
	if _, serr := eng.convo_send(&a.e, o, "after the restore"); serr != .None && serr != .Pending {
		world_fail(w, "open damage: the conversation's writer did not reopen after the restore: %v", serr)
	}
}

@(private = "file")
_runtime_close :: proc(n: ^Node, r: ^rt.Runtime) {
	context = instance_context(&n.inst)
	rt.close(r)
	node_after(n)
}

@(private = "file")
_advertised :: proc(n: ^Node, space: prim.Id) -> bool {
	me := n.e.self
	_, found, err := eng.map_get(&n.e, rt.runners_object(space), me[:], context.temp_allocator)
	return err == .None && found
}

@(private = "file")
_read_prefix :: proc(n: ^Node, path: string, size: i64) -> ([]u8, bool) {
	fd, oerr := prim.open_file(n.e.vfs, path)
	if oerr != .None {
		return nil, false
	}
	defer prim.close_file(n.e.vfs, fd)
	b := make([]u8, int(size), n.w.allocator)
	k, rerr := prim.read_at(n.e.vfs, fd, b, 0)
	return b, rerr == .None && i64(k) == size
}

@(private = "file")
_flip_last :: proc(n: ^Node, path: string, durable: i64, body: bool) -> bool {
	fd, oerr := prim.open_file(n.e.vfs, path, {.Write})
	if oerr != .None {
		return false
	}
	defer prim.close_file(n.e.vfs, fd)
	at := durable - journal.TRAILER + 1
	if body {
		tail: [journal.TRAILER]u8
		if k, rerr := prim.read_at(n.e.vfs, fd, tail[:], durable - journal.TRAILER); rerr != .None || k != len(tail) {
			return false
		}
		at = durable - i64(prim.get_u32le(tail[:])) - journal.TRAILER + 1
	}
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
open_damage :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for body in ([]bool{false, true}) {
		failures := open_damage_run(1, body)
		for f in failures {
			fmt.eprintf("open_damage (sealed body %v): %s\n", body, f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0, "open_damage failed")
		delete(failures)
	}
}

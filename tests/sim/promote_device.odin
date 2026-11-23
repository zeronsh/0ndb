package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

promote_device_run :: proc(seed: u64, storage: eng.Storage_Mode) -> (failures: [dynamic]string) {
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
	cfg.storage = storage
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_promote_device(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_promote_device :: proc(w: ^World) {
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
	text: eng.Object
	from: i64
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "promote")
		if err != .None {
			world_fail(w, "promote device: space_create: %v", err)
			return
		}
		space = id
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "promote device: space_open: %v", oerr)
			return
		}
		if rerr := eng.space_set_relay(&a.e, space, "relay", w.relay.public); rerr != .None {
			world_fail(w, "promote device: space_set_relay: %v", rerr)
			return
		}
		text, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "promote device: tree_create: %v", err)
			return
		}
		if werr := eng.tree_write(&a.e, text, "a.txt", transmute([]u8)string("written before the checkpoint\n")); werr != .None {
			world_fail(w, "promote device: tree_write: %v", werr)
			return
		}
		if perr := eng.object_promote_run(&a.e, text); perr != .None {
			world_fail(w, "promote device: object_promote_run: %v", perr)
			return
		}
		length, _, found := eng.checkpoint_info(&a.e, text)
		from = length if found && length > 0 else 0
	}
	run_until(w, w.now + 2_000_000_000, true)
	for i in 0 ..< 3 {
		context = instance_context(&a.inst)
		if eerr := eng.tree_write(&a.e, text, fmt.tprintf("after-%d.txt", i), transmute([]u8)fmt.tprintf("written after the promotion %d\n", i)); eerr != .None {
			world_fail(w, "promote device: tree_write after: %v", eerr)
		}
		node_after(a)
		run_until(w, w.now + 1_000_000_000, true)
	}
	run_until(w, w.now + 5_000_000_000, true)
	context = instance_context(&a.inst)
	defer node_after(a)
	key, kerr := eng.object_key(&a.e, text)
	info, _ := eng.space_info(&a.e, space)
	if kerr != .None {
		world_fail(w, "promote device: object_key: %v", kerr)
		return
	}
	scope := osync.scope_make(key, info.mode)
	name := make([]u8, 1 + prim.ID_HEX_LEN, context.temp_allocator)
	name[0] = 'f'
	hx := prim.id_hex(text.id)
	copy(name[1:], hx[:])
	sid := osync.stream_id(&scope, a.identity.id, string(name), 0)
	length, base, exists := relay_probe(w, space, sid)
	if !exists || length == 0 {
		world_fail(w, "promote device: the promoted text's segment is not on the relay")
		return
	}
	if base > from {
		world_fail(w, "promote device: the promoted tree's segment is stored only from %d of %d (promoted from %d); writes after the promotion stayed device-only", base, length, from)
	}
}

@(test)
promote_device :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for storage in ([]eng.Storage_Mode{.Device, .Device_Until_Run}) {
		failures := promote_device_run(1, storage)
		for f in failures {
			fmt.eprintf("promote_device %v: %s\n", storage, f)
			delete(f)
		}
		testing.expectf(t, len(failures) == 0, "promote_device %v failed", storage)
		delete(failures)
	}
}

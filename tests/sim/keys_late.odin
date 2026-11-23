package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
LATE_EPOCHS :: 8

@(private = "file")
Late_World :: struct {
	node: int,
	drop: map[osync.Stream_Id]bool,
}

@(private = "file")
_late: ^Late_World

@(init)
_keys_late_init :: proc "contextless" () {
	register_world(61, _late_init, _late_destroy)
	register_frame_filter(10, _late_filter)
}

@(private = "file")
_late_init :: proc(w: ^World) {
	_late = new(Late_World, w.allocator)
	_late.node = -1
	_late.drop = make(map[osync.Stream_Id]bool, w.allocator)
}

@(private = "file")
_late_destroy :: proc(w: ^World) {
	if _late == nil {
		return
	}
	frame_filter_enable(false)
	delete(_late.drop)
	free(_late, w.allocator)
	_late = nil
}

@(private = "file")
_late_filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> bool {
	if _late == nil || c.node.idx != _late.node {
		return false
	}
	for id in _late.drop {
		x := id
		for i := 0; i + 32 <= len(payload); i += 1 {
			if string(payload[i:i + 32]) == string(x[:]) {
				return true
			}
		}
	}
	return false
}

keys_late_run :: proc(seed: u64, head_late: bool) -> (failures: [dynamic]string) {
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
	_keys_late(w, head_late)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_late_waiting :: proc(n: ^Node, space: prim.Id, name: string) -> bool {
	sp, ok := n.e.spaces[space]
	if !ok || !sp.repl_on {
		return false
	}
	for _, rm in sp.repl.remotes {
		if rm.name == name && rm.keys_wait {
			return true
		}
	}
	return false
}


@(private = "file")
_late_reset :: proc(n: ^Node) {
	for cn in n.conns {
		conn_reset(cn, true)
	}
}

@(private = "file")
_keys_late :: proc(w: ^World, head_late: bool) {
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
	text: eng.Object
	proof: []u8
	name: string
	keys_ids: [LATE_EPOCHS]osync.Stream_Id
	head_id: osync.Stream_Id
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "late", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "keys late: space setup: %v", err)
			return
		}
		space = id
		p, perr := eng.member_add(&a.e, space, b.identity, .Device, .Member, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "keys late: member_add: %v", perr)
			return
		}
		proof = p
		text, err = eng.text_create(&a.e, space, "late", "sealed\n")
		if err != .None {
			world_fail(w, "keys late: text_create: %v", err)
			return
		}
		info, ierr := eng.space_info(&a.e, space)
		key, kerr := eng.object_key(&a.e, eng.Object{space, info.catalog})
		if ierr != .None || kerr != .None {
			world_fail(w, "keys late: catalog key: %v %v", ierr, kerr)
			return
		}
		h := prim.id_hex(info.catalog)
		name = fmt.aprintf("m%s", string(h[:]), allocator = w.allocator)
		kn, nerr := osync.keys_stream_name(name)
		hn, herr := osync.keys_head_name(kn)
		if nerr != .None || herr != .None {
			world_fail(w, "keys late: stream names: %v %v", nerr, herr)
			return
		}
		sc := osync.scope_make(key, info.mode)
		for i in 0 ..< LATE_EPOCHS {
			keys_ids[i] = osync.stream_id(&sc, a.identity.id, kn, u64(i))
		}
		head_id = osync.stream_id(&sc, a.identity.id, hn, 0)
		osync.scope_clear(&sc)
	}
	defer delete(name, w.allocator)
	run_until(w, w.now + 5_000_000_000, true)
	_late.node = b.idx
	for id in keys_ids {
		_late.drop[id] = true
	}
	_late.drop[head_id] = true
	frame_filter_enable(true)
	join: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "late", "relay", w.relay.public); jerr != .None {
			world_fail(w, "keys late: join: %v", jerr)
			return
		}
		eng.space_open(&b.e, space)
	}
	waited := false
	for i := 0; i < 30_000 && !waited; i += 1 {
		waited = _late_waiting(b, space, name)
		if !waited {
			run_until(w, w.now + 1_000_000, false)
		}
	}
	if !waited {
		world_fail(w, "keys late: the reader never waited on the writer's catalog keys, so the check proves nothing")
		return
	}
	for _ in 0 ..< 4 {
		context = instance_context(&b.inst)
		eng.flush(&b.e)
		eng.scrub(&b.e)
		node_after(b)
		run_until(w, w.now + 10_000_000_000, false)
	}
	for id in keys_ids {
		delete_key(&_late.drop, id)
	}
	_late_reset(b)
	run_until(w, w.now + 20_000_000_000, false)
	if head_late {
		delete_key(&_late.drop, head_id)
		_late_reset(b)
	}
	run_until(w, w.now + 60_000_000_000, true)
	if _late_waiting(b, space, name) {
		world_fail(w, "keys late: the reader still waits on the writer's catalog keys it holds")
	}
	found := false
	for i := 0; i < 60 && !found; i += 1 {
		context = instance_context(&b.inst)
		_, f, cerr := eng.catalog_get(&b.e, text, context.temp_allocator)
		node_after(b)
		found = f
		if !found {
			run_until(w, w.now + 500_000_000, false)
		}
	}
	if !found {
		world_fail(w, "keys late: the reader never read the writer's catalog row after its keys arrived late")
	}
	frame_filter_enable(false)
	_late.node = -1
}

@(test)
keys_late :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for head_late in ([]bool{true, false}) {
		failures := keys_late_run(1, head_late)
		for f in failures {
			fmt.eprintf("keys_late head_late=%v: %s\n", head_late, f)
			delete(f)
		}
		testing.expectf(t, len(failures) == 0, "keys_late head_late=%v failed", head_late)
		delete(failures)
	}
}

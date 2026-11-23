package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import omap "../../src/map"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
LOST_KEY :: "k"

@(private = "file")
Lost_World :: struct {
	node:  int,
	drops: int,
	space: prim.Id,
	token: [eng.CAPABILITY_LEN]u8,
	ok:    bool,
	cc:    eng.Cap_Credentials,
}

@(private = "file")
_lost: ^Lost_World

@(init)
_probe_lost_init :: proc "contextless" () {
	register_world(62, _lost_init, _lost_destroy)
	register_frame_filter(11, _lost_filter)
}

@(private = "file")
_lost_init :: proc(w: ^World) {
	_lost = new(Lost_World, w.allocator)
	_lost.node = -1
}

@(private = "file")
_lost_destroy :: proc(w: ^World) {
	if _lost == nil {
		return
	}
	frame_filter_enable(false)
	free(_lost, w.allocator)
	_lost = nil
}

@(private = "file")
_lost_filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> bool {
	if _lost == nil || c.node.idx != _lost.node || kind != 0x91 || _lost.drops <= 0 {
		return false
	}
	_lost.drops -= 1
	world_note(w, "the relay drops a probe answer to %s", c.node.name)
	return true
}

@(private = "file")
_lost_cfg :: proc(n: ^Node, cfg: ^eng.Config) {
	if n.idx == 2 {
		cfg.credentials = eng.Credentials_Source{data = n, produce = _lost_credentials}
	}
}

@(private = "file")
_lost_credentials :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	n := (^Node)(data)
	if _lost == nil || !_lost.ok || space != _lost.space {
		return {}, false
	}
	c, err := eng.capability_credentials(&_lost.cc, osync.file_keyring(&n.keyring), _lost.token[:])
	return c, err == .None
}

probe_lost_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	w.node_cfg = _lost_cfg
	_probe_lost(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_lost_read :: proc(n: ^Node, mo: eng.Object, fresh: bool) -> (value: string, err: eng.Error) {
	context = instance_context(&n.inst)
	defer node_after(n)
	ready: eng.Ready
	if fresh {
		ready = eng.Ready{call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}, fresh = true}
	}
	en, found, gerr := eng.map_get(&n.e, mo, transmute([]u8)string(LOST_KEY), context.temp_allocator, ready)
	if gerr != .None {
		return "", gerr
	}
	if !found {
		return "", .Not_Found
	}
	v, _ := omap.entry_register(&en, 1)
	return fmt.tprintf("%s", string(v)), .None
}

@(private = "file")
_probe_lost :: proc(w: ^World) {
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
	mo: eng.Object
	proof: []u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "lost", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "probe lost: space setup: %v", err)
			return
		}
		space = id
		p, perr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "probe lost: member_add: %v", perr)
			return
		}
		proof = p
		mo, err = eng.map_create(&a.e, space, "lost")
		if err != .None {
			world_fail(w, "probe lost: map_create: %v", err)
			return
		}
		if _, serr := eng.map_set(&a.e, mo, transmute([]u8)string(LOST_KEY), []omap.Field{omap.field_str(1, "written")}); serr != .None && serr != .Pending {
			world_fail(w, "probe lost: map_set: %v", serr)
			return
		}
	}
	join: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "lost", "relay", w.relay.public); jerr != .None {
			world_fail(w, "probe lost: join: %v", jerr)
			return
		}
		if oerr := eng.space_open(&b.e, space); oerr != .None {
			world_fail(w, "probe lost: space_open: %v", oerr)
			return
		}
	}
	known := false
	for _ in 0 ..< 30 {
		run_until(w, w.now + 1_000_000_000, true)
		if v, err := _lost_read(b, mo, false); err == .None && v == "written" {
			known = true
			break
		}
	}
	if !known {
		world_fail(w, "probe lost: the member never read the map, so the check proves nothing")
		return
	}
	share: eng.Share
	sharing: {
		context = instance_context(&b.inst)
		defer node_after(b)
		s, serr := eng.share_object(&b.e, mo, c.identity, {.Read})
		tok, terr := eng.capability_issue(&b.e, eng.Capability{space = space, grantee = c.identity.id, object = mo.id, kind = .Map, access = {.Read}}, context.temp_allocator)
		if serr != .None || terr != .None {
			world_fail(w, "probe lost: share %v capability %v", serr, terr)
			return
		}
		share = s
		copy(_lost.token[:], tok)
		_lost.space = space
		_lost.ok = true
	}
	frame_filter_enable(true)
	_lost.node = c.idx
	_lost.drops = 1 << 20
	accept: {
		context = instance_context(&c.inst)
		defer node_after(c)
		if jerr := eng.space_join_shared(&c.e, space, "guest", "relay", w.relay.public); jerr != .None {
			world_fail(w, "probe lost: guest join: %v", jerr)
			return
		}
		eng.space_open(&c.e, space)
		if aerr := eng.accept_share(&c.e, share); aerr != .None {
			world_fail(w, "probe lost: accept_share: %v", aerr)
			return
		}
	}
	frame_filter_enable(true)
	_lost.node = c.idx
	_lost.drops = 1 << 20
	run_until(w, w.now + 10_000_000_000, false)
	links := c.connects
	pending := false
	for _ in 0 ..< 5 {
		_, err := _lost_read(c, mo, true)
		if err == .Pending {
			pending = true
		}
		run_until(w, w.now + 500_000_000, false)
	}
	if !pending || _lost.drops == 1 << 20 {
		world_fail(w, "probe lost: no fresh read waited on a dropped probe answer (pending %v), so the check proves nothing", pending)
		return
	}
	_lost.drops = 0
	done := false
	for _ in 0 ..< 10 {
		if v, err := _lost_read(c, mo, true); err == .None && v == "written" {
			done = true
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if c.connects != links {
		world_fail(w, "probe lost: the guest reconnected (%d to %d), so the check proves nothing", links, c.connects)
		return
	}
	if !done {
		world_fail(w, "probe lost: after its probe answers were lost, no later fresh read completed without a reconnect")
	}
}

@(test)
probe_lost :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := probe_lost_run(1)
	for f in failures {
		fmt.eprintf("probe_lost: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "probe_lost failed")
	delete(failures)
}

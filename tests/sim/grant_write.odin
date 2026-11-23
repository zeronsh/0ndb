package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
Grant_Writer :: struct {
	node:  int,
	space: prim.Id,
	token: [eng.CAPABILITY_LEN]u8,
	ok:    bool,
	cc:    eng.Cap_Credentials,
}

@(private = "file")
_gw: Grant_Writer

@(private = "file")
_gw_cfg :: proc(n: ^Node, cfg: ^eng.Config) {
	if n.idx == _gw.node {
		cfg.credentials = eng.Credentials_Source{data = n, produce = _gw_credentials}
	}
}

@(private = "file")
_gw_credentials :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	n := (^Node)(data)
	if !_gw.ok || space != _gw.space {
		return {}, false
	}
	c, err := eng.capability_credentials(&_gw.cc, osync.file_keyring(&n.keyring), _gw.token[:])
	return c, err == .None
}

grant_write_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_gw = Grant_Writer{node = 1}
	w.node_cfg = _gw_cfg
	_grant_write(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	_gw = {}
	return
}

@(private = "file")
_gw_reads :: proc(w: ^World, n: ^Node, o: eng.Object, want: string, ms: i64) -> bool {
	for i: i64 = 0; i < ms / 500; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		if !n.alive || !n.e_open {
			return false
		}
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
_grant_write :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, g := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(g) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	share: eng.Share
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "grant-write", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "grant write: space setup: %v", err)
			return
		}
		space = id
		o, err = eng.text_create(&a.e, space, "shared", "owner\n")
		if err != .None {
			world_fail(w, "grant write: text_create: %v", err)
			return
		}
		s, serr := eng.share_object(&a.e, o, g.identity, {.Read, .Write})
		tok, terr := eng.capability_issue(&a.e, eng.Capability{space = space, grantee = g.identity.id, object = o.id, kind = .Text, access = {.Read, .Write}}, context.temp_allocator)
		if serr != .None || terr != .None {
			world_fail(w, "grant write: share %v capability %v", serr, terr)
			return
		}
		share = s
		copy(_gw.token[:], tok)
		_gw.space = space
		_gw.ok = true
	}
	accept: {
		context = instance_context(&g.inst)
		defer node_after(g)
		if jerr := eng.space_join_shared(&g.e, space, "guest", "relay", w.relay.public); jerr != .None {
			world_fail(w, "grant write: guest join: %v", jerr)
			return
		}
		eng.space_open(&g.e, space)
		if aerr := eng.accept_share(&g.e, share); aerr != .None {
			world_fail(w, "grant write: accept_share: %v", aerr)
			return
		}
	}
	if !_gw_reads(w, g, o, "owner", 30_000) {
		world_fail(w, "grant write: the guest never read the shared text, so the check proves nothing")
		return
	}
	write: {
		context = instance_context(&g.inst)
		defer node_after(g)
		cur, rerr := eng.text_read(&g.e, o, context.temp_allocator)
		if rerr != .None {
			world_fail(w, "grant write: guest text_read: %v", rerr)
			return
		}
		if eerr := eng.text_edit(&g.e, o, len(cur), 0, "guest\n"); eerr != .None && eerr != .Pending {
			world_fail(w, "grant write: the guest's first write answers %v", eerr)
			return
		}
	}
	if !_gw_reads(w, a, o, "guest", 60_000) {
		world_fail(w, "grant write: the owner never read the guest's first write")
	}
	if !g.alive || !g.e_open {
		world_fail(w, "grant write: the guest's engine is down after its first write")
	}
}

@(test)
grant_write :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := grant_write_run(1)
	for f in failures {
		fmt.eprintf("grant_write: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "grant_write failed")
	delete(failures)
}

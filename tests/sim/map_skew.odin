package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import omap "../../src/map"
import "../../src/prim"

@(private = "file")
SKEW_KEY :: "k"

@(private = "file")
SKEW_TAG :: u32(1)

map_skew_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	w.nodes[0].clock.wall_off = 30_000_000_000
	w.nodes[1].clock.wall_off = -30_000_000_000
	_map_skew(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_skew_value :: proc(w: ^World, n: ^Node, mo: eng.Object) -> (string, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	en, found, err := eng.map_get(&n.e, mo, transmute([]u8)string(SKEW_KEY), context.temp_allocator)
	if err != .None || !found {
		return "", false
	}
	v, ok := omap.entry_register(&en, SKEW_TAG)
	return string(v), ok
}

@(private = "file")
_skew_title :: proc(w: ^World, n: ^Node, co: eng.Object) -> (string, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	c, found, err := eng.catalog_get(&n.e, co, context.temp_allocator)
	if err != .None || !found {
		return "", false
	}
	return c.title, true
}

@(private = "file")
_map_skew :: proc(w: ^World) {
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
	mo, co: eng.Object
	{
		context = instance_context(&a.inst)
		id, err := eng.space_create(&a.e, "skew", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "map skew: space setup: %v", err)
			return
		}
		space = id
		proof, perr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if perr != .None {
			world_fail(w, "map skew: member_add: %v", perr)
			return
		}
		mo, err = eng.map_create(&a.e, space, "skew")
		if err != .None {
			world_fail(w, "map skew: map_create: %v", err)
			return
		}
		if _, serr := eng.map_set(&a.e, mo, transmute([]u8)string(SKEW_KEY), []omap.Field{omap.field_str(SKEW_TAG, "ahead")}); serr != .None && serr != .Pending {
			world_fail(w, "map skew: map_set on the leading clock: %v", serr)
			return
		}
		co, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "ahead"})
		if err != .None {
			world_fail(w, "map skew: convo_create: %v", err)
			return
		}
		node_after(a)
		context = instance_context(&b.inst)
		if _, jerr := eng.space_join_enrollment(&b.e, space, proof, "skew", "relay", w.relay.public); jerr != .None {
			world_fail(w, "map skew: join: %v", jerr)
			return
		}
		if oerr := eng.space_open(&b.e, space); oerr != .None {
			world_fail(w, "map skew: space_open: %v", oerr)
			return
		}
		node_after(b)
	}
	for _ in 0 ..< 10 {
		run_until(w, w.now + 5_000_000_000, true)
		{
			context = instance_context(&b.inst)
			eng.map_open(&b.e, mo)
			eng.convo_open(&b.e, co)
			node_after(b)
		}
		if v, ok := _skew_value(w, b, mo); ok && v == "ahead" {
			break
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	if v, ok := _skew_value(w, b, mo); !ok || v != "ahead" {
		world_fail(w, "map skew: the lagging node never saw the leading write (%q, %v), so the check proves nothing", v, ok)
		return
	}
	if t, ok := _skew_title(w, b, co); !ok || t != "ahead" {
		world_fail(w, "map skew: the lagging node never saw the catalog row (%q, %v), so the check proves nothing", t, ok)
		return
	}
	behind: {
		context = instance_context(&b.inst)
		if _, serr := eng.map_set(&b.e, mo, transmute([]u8)string(SKEW_KEY), []omap.Field{omap.field_str(SKEW_TAG, "behind")}); serr != .None && serr != .Pending {
			world_fail(w, "map skew: map_set on the lagging clock: %v", serr)
			return
		}
		if cerr := eng.catalog_set(&b.e, eng.Cmd_Catalog_Set{object = co, set = {.Title}, title = "behind"}); cerr != .None && cerr != .Pending {
			world_fail(w, "map skew: catalog_set on the lagging clock: %v", cerr)
			return
		}
		node_after(b)
	}
	run_until(w, w.now + 20_000_000_000, true)
	for n in ([]^Node{a, b}) {
		if v, ok := _skew_value(w, n, mo); !ok || v != "behind" {
			world_fail(w, "map skew: %s reads %q (%v) after the lagging node overwrote the key it had seen: a put lost to a register it observed", n.name, v, ok)
		}
		if t, ok := _skew_title(w, n, co); !ok || t != "behind" {
			world_fail(w, "map skew: %s's catalog title is %q (%v) after the lagging node renamed it: a catalog write lost to a register it observed", n.name, t, ok)
		}
	}
}

@(test)
map_skew :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := map_skew_run(1)
	for f in failures {
		fmt.eprintf("map_skew: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "map_skew failed")
	delete(failures)
}

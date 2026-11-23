package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/obj"
import "../../src/prim"

catalog_parent_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_catalog_parent(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_catalog_parent :: proc(w: ^World) {
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
	parent, child: eng.Object
	msg: obj.Rid
	{
		context = instance_context(&a.inst)
		id, err := eng.space_create(&a.e, "parents")
		if err != .None {
			world_fail(w, "catalog parent: space_create: %v", err)
			return
		}
		space = id
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "catalog parent: space_open: %v", oerr)
			return
		}
		parent, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "parent"})
		if err != .None {
			world_fail(w, "catalog parent: convo_create parent: %v", err)
			return
		}
		m, serr := eng.convo_send(&a.e, parent, "the message a child task hangs off")
		if serr != .None && serr != .Pending {
			world_fail(w, "catalog parent: convo_send: %v", serr)
			return
		}
		msg = m
		child, err = eng.convo_create(&a.e, space, eng.Convo_Settings{title = "child", parent = obj.Xref{object = parent.id, rid = msg}})
		if err != .None {
			world_fail(w, "catalog parent: convo_create child: %v", err)
			return
		}
		node_after(a)
	}
	run_until(w, w.now + 2_000_000_000, true)
	context = instance_context(&a.inst)
	defer node_after(a)
	if msg.gen == 0 {
		world_fail(w, "catalog parent: the parent message %v has no generation, so the check proves nothing", msg)
		return
	}
	c, found, cerr := eng.catalog_get(&a.e, child, context.temp_allocator)
	if cerr != .None || !found {
		world_fail(w, "catalog parent: catalog_get child: %v found=%v", cerr, found)
		return
	}
	if c.parent.object != parent.id || c.parent.rid != msg {
		world_fail(w, "catalog parent: the child's catalog entry names parent %v, created with %v", c.parent, obj.Xref{object = parent.id, rid = msg})
	}
	cur: eng.Map_Cursor
	defer delete(cur.key)
	rows, _, lerr := eng.catalog_list(&a.e, space, false, &cur, 64, context.temp_allocator)
	if lerr != .None {
		world_fail(w, "catalog parent: catalog_list: %v", lerr)
		return
	}
	listed := false
	for row in rows {
		if row.object != child.id {
			continue
		}
		listed = true
		if row.parent.object != parent.id || row.parent.rid != msg {
			world_fail(w, "catalog parent: the child's catalog row names parent %v, created with %v", row.parent, obj.Xref{object = parent.id, rid = msg})
		}
	}
	if !listed {
		world_fail(w, "catalog parent: the child is not listed in the catalog")
	}
}

@(test)
catalog_parent :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := catalog_parent_run(1)
	for f in failures {
		fmt.eprintf("catalog_parent: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "catalog_parent failed")
	delete(failures)
}

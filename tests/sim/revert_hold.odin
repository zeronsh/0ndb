package sim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

REVERT_ROOT :: "/work/revert-n0"

revert_hold_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_revert_hold(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_revert_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == REVERT_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_revert_heads :: proc(n: ^Node, o: eng.Object) -> []crdt.Op_Id {
	hist, err := eng.tree_history(&n.e, o)
	if err != .None {
		return nil
	}
	defer eng.tree_release(&n.e, o)
	return slice.clone(crdt.graph_version_ids(&hist.g, hist.g.heads[:], context.temp_allocator))
}

@(private = "file")
_revert_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_revert_same :: proc(w: ^World, n: ^Node, tree: eng.Object, name: string, want_in, want_out: string) {
	vfs := disk_vfs(&n.disk)
	disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", REVERT_ROOT, name), context.temp_allocator)
	data, terr := eng.tree_read(&n.e, tree, name, context.temp_allocator)
	if derr != .None || terr != .None || string(disk) != string(data) {
		world_fail(w, "revert hold: %s on disk is %q (%v), in history %q (%v)", name, string(disk), derr, string(data), terr)
		return
	}
	if len(want_in) > 0 && !strings.contains(string(disk), want_in) {
		world_fail(w, "revert hold: %s lost %q: %q", name, want_in, string(disk))
	}
	if len(want_out) > 0 && strings.contains(string(disk), want_out) {
		world_fail(w, "revert hold: %s still has the reverted %q: %q", name, want_out, string(disk))
	}
}

@(private = "file")
_revert_hold :: proc(w: ^World) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "revert hold: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "revert")
		if err != .None {
			world_fail(w, "revert hold: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "revert hold: tree_create: %v", err)
			return
		}
		node_after(n)
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	prim.mkdir_all(vfs, REVERT_ROOT, 0o755)
	if err := node_mount(w, n, oi, REVERT_ROOT); err != .None {
		world_fail(w, "revert hold: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(REVERT_ROOT, w.allocator)})
	_revert_write(vfs, REVERT_ROOT + "/a.txt", "base a\n")
	_revert_write(vfs, REVERT_ROOT + "/b.txt", "base b\n")
	{
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	before, after: []crdt.Op_Id
	hold: ^fs.Scope
	{
		context = instance_context(&n.inst)
		sm := _revert_mount(n)
		if sm == nil {
			world_fail(w, "revert hold: mount missing")
			return
		}
		before = _revert_heads(n, tree)
		agent := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		if oerr := fs.mount_observe_begin(sm.m, "a.txt", agent); oerr != .None {
			world_fail(w, "revert hold: observe: %v", oerr)
			return
		}
		_revert_write(vfs, REVERT_ROOT + "/a.txt", "base a\nagent line\n")
		if serr := fs.scope_close(n.reg, agent); serr != .None {
			world_fail(w, "revert hold: agent scope close: %v", serr)
			return
		}
		after = _revert_heads(n, tree)
		hold = fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
		fs.scope_write_begin(hold, "a.txt")
		if !fs.scope_pinned(hold, "a.txt") {
			world_fail(w, "revert hold: the hold pinned nothing")
			return
		}
		if rerr := fs.mount_revert(sm.m, fs.Version(before), fs.Version(after), prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))); rerr != .None {
			world_fail(w, "revert hold: mount_revert: %v", rerr)
			return
		}
		node_after(n)
	}
	defer delete(before)
	defer delete(after)
	_revert_write(vfs, REVERT_ROOT + "/a.txt", "base a\nagent line\nperson a\n")
	_revert_write(vfs, REVERT_ROOT + "/b.txt", "base b\nperson b\n")
	{
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 5_000_000_000, true)
	{
		context = instance_context(&n.inst)
		_revert_same(w, n, tree, "b.txt", "person b", "")
		node_after(n)
	}
	{
		context = instance_context(&n.inst)
		fs.scope_close(n.reg, hold)
		node_after(n)
	}
	run_until(w, w.now + 5_000_000_000, true)
	{
		context = instance_context(&n.inst)
		_revert_same(w, n, tree, "a.txt", "person a", "agent line")
		_revert_same(w, n, tree, "b.txt", "person b", "")
		node_after(n)
	}
}

@(test)
revert_under_hold :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := revert_hold_run(1)
	for f in failures {
		fmt.eprintf("revert_under_hold: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "revert_under_hold failed")
	delete(failures)
}

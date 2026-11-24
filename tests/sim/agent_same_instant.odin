package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

SI_ROOT :: "/work/same-instant-n0"

@(private = "file")
Si_Crash :: enum u8 {
	None,
	Process,
	Power,
}

@(private = "file")
Si_Case :: struct {
	durability: eng.Durability,
	crash:      Si_Crash,
	wait_ms:    i64,
	undo_first: bool,
	seed:       u64,
}

@(private = "file")
_si_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_si_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == SI_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_si_agent :: proc(w: ^World, n: ^Node, actor: prim.Id, data: string) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	sm := _si_mount(n)
	if sm == nil {
		return false
	}
	vfs := disk_vfs(&n.disk)
	scope := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), actor)
	_writer_set(w, n, SI_ROOT + "/b.txt", Writer_Info{scope = scope, agent = true})
	if err := fs.mount_observe_begin(sm.m, "b.txt", scope); err != .None {
		world_fail(w, "same instant: observe_begin: %v", err)
		return false
	}
	if err := _si_write(vfs, SI_ROOT + "/b.txt", data); err != .None {
		world_fail(w, "same instant: write: %v", err)
		return false
	}
	if err := fs.scope_close(n.reg, scope); err != .None {
		world_fail(w, "same instant: scope_close: %v", err)
		return false
	}
	_forget_scope(w, n, scope)
	return true
}

@(private = "file")
_si_blame :: proc(w: ^World, n: ^Node, tree: eng.Object, tok: string, who: prim.Id, other: prim.Id, lax: bool) {
	data, spans, err := eng.tree_blame(&n.e, tree, "b.txt", context.temp_allocator)
	if err != .None {
		world_fail(w, "same instant: blame: %v", err)
		return
	}
	at := strings.index(string(data), tok)
	if at < 0 {
		world_fail(w, "same instant: token %s is missing from %q", tok, string(data))
		return
	}
	own, wrong, off := false, false, 0
	for s in spans {
		if off < at + len(tok) && off + s.len > at {
			own ||= s.id.actor == who
			wrong ||= s.id.actor == other
		}
		off += s.len
	}
	if wrong {
		world_fail(w, "same instant: token %s is credited to the other agent", tok)
	} else if !own && !lax {
		world_fail(w, "same instant: token %s is not credited to its writer", tok)
	}
}

@(private = "file")
_si_case :: proc(w: ^World, c: Si_Case) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "same instant: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "same")
		if err != .None {
			world_fail(w, "same instant: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "same instant: tree_create: %v", err)
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
	if prim.mkdir_all(vfs, SI_ROOT) != .None || _si_write(vfs, SI_ROOT + "/b.txt", "<base>\n") != .None {
		world_fail(w, "same instant: setup write")
		return
	}
	if err := node_mount(w, n, oi, SI_ROOT); err != .None {
		world_fail(w, "same instant: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SI_ROOT, w.allocator)})
	run_until(w, w.now + 5_000_000_000, true)
	base: fs.Version
	{
		context = instance_context(&n.inst)
		base, _ = eng.tree_version(&n.e, tree, "", w.allocator)
		node_after(n)
	}
	a := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	b := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	if !_si_agent(w, n, a, "<aa01>\n<aa02>\n") || !_si_agent(w, n, b, "<aa01>\n<bb01>\n") {
		return
	}
	run_until(w, w.now + c.wait_ms * 1_000_000, true)
	#partial switch c.crash {
	case .Process:
		node_crash_now(n, .Process, c.seed)
	case .Power:
		node_crash_now(n, .Power, c.seed)
	}
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive || _si_mount(n) == nil {
		world_fail(w, "same instant: the node or its mount did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	lax := c.crash != .None
	if data, err := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator); err != .None || string(data) != "<aa01>\n<bb01>\n" {
		world_fail(w, "same instant: the tree reads %q (%v)", string(data), err)
		return
	}
	_si_blame(w, n, tree, "<aa01>", a, b, lax)
	_si_blame(w, n, tree, "<bb01>", b, a, lax)
	if len(w.failures) > 0 || lax {
		return
	}
	if _, err := eng.tree_revert_set(&n.e, tree, base, []prim.Id{a if c.undo_first else b}); err != .None {
		world_fail(w, "same instant: revert: %v", err)
		return
	}
	data, err := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator)
	if !c.undo_first {
		if err != .None || string(data) != "<aa01>\n<aa02>\n" {
			world_fail(w, "same instant: undoing the second agent left %q (%v)", string(data), err)
		}
		return
	}
	if err != .None || string(data) != "<base>\n" {
		world_fail(w, "same instant: undoing the first agent left %q (%v)", string(data), err)
		return
	}
	list, lerr := eng.tree_conflicts(&n.e, tree, context.temp_allocator)
	offered := false
	for x in list {
		offered ||= x.kind == .Revert && x.path == "b.txt"
	}
	if lerr != .None || !offered {
		world_fail(w, "same instant: undoing the first agent dropped the second's rewrite without offering it (%v, %d conflicts)", lerr, len(list))
	}
}

@(private = "file")
_si_run :: proc(c: Si_Case) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(c.seed)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.durability = c.durability
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_si_case(w, c)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(test)
agent_same_instant :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad, total := 0, 0
	for d in ([]eng.Durability{.Deferred, .Async}) {
		for crash in Si_Crash {
			for wait in ([]i64{0, 1, 20, 346, 3000}) {
				for first in ([]bool{false, true}) {
					for seed in u64(1) ..= 4 {
						c := Si_Case{d, crash, wait, first, seed}
						failures := _si_run(c)
						total += 1
						for f in failures {
							if bad < 40 {
								fmt.eprintf("agent_same_instant %v: %s\n", c, f)
							}
							delete(f)
						}
						if len(failures) > 0 {
							bad += 1
						}
						delete(failures)
					}
				}
			}
		}
	}
	fmt.eprintf("agent_same_instant: %d cases, %d failed\n", total, bad)
	testing.expect(t, bad == 0, fmt.tprintf("agent_same_instant: %d of %d cases failed", bad, total))
}

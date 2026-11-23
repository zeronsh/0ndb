package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/crdt"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
RI_ROOT :: "/work/recover-n0"


@(private = "file")
Ri_Notes :: struct {
	merged: int,
	other:  int,
}

@(private = "file")
_ri_on_base :: proc(m: ^fs.Mount, rel: string, note: fs.Base_Note, data: rawptr) {
	notes := (^Ri_Notes)(data)
	if note == .Merged {
		notes.merged += 1
	} else {
		notes.other += 1
	}
}

@(private = "file")
_ri_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	return err
}

@(private = "file")
_ri_case :: proc(seed: u64, k: u64) -> (crashed: bool, failures: [dynamic]string) {
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
	crashed = _ri_run(w, k)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ri_run :: proc(w: ^World, k: u64) -> (crashed: bool) {
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "recover: node start")
		return
	}
	vfs := disk_vfs(&a.disk)
	tree: eng.Object
	m: ^fs.Mount
	notes := new(Ri_Notes, w.allocator)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "recover")
		if err != .None {
			world_fail(w, "recover: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "recover: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "recover: tree_create: %v", err)
			return
		}
		reg, rerr := eng.registry(&a.e)
		if rerr != .None {
			world_fail(w, "recover: registry: %v", rerr)
			return
		}
		a.reg = reg
		fs.registry_set_base_note(reg, _ri_on_base, notes)
		if prim.mkdir_all(vfs, RI_ROOT, 0o755) != .None {
			world_fail(w, "recover: mkdir")
			return
		}
		if m, err = eng.tree_mount(&a.e, tree, RI_ROOT); err != .None && !(err == .Pending && m != nil) {
			world_fail(w, "recover: tree_mount: %v", err)
			return
		}
		if _ri_write(vfs, RI_ROOT + "/a.txt", "one\ntwo\n") != .None || _ri_write(vfs, RI_ROOT + "/c.txt", "c\n") != .None {
			world_fail(w, "recover: setup write")
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	base: []u8
	scope: ^fs.Scope
	actor: prim.Id
	sid: prim.Id
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		b, berr := prim.read_file(vfs, RI_ROOT + "/a.txt", w.allocator)
		if berr != .None || string(b) != "one\ntwo\n" {
			world_fail(w, "recover: a.txt reads %q before the agent starts (%v)", string(b), berr)
			return
		}
		base = b
		sid = prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
		actor = prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
		scope = fs.scope_open(a.reg, m, sid, actor)
		fs.scope_read_base(scope, "a.txt", base)
		if err := eng.tree_write(&a.e, tree, "a.txt", transmute([]u8)string("zero\none\ntwo\n"), tree_base(&a.e, tree)); err != .None {
			world_fail(w, "recover: tree_write: %v", err)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	crashes := w.stats.crashes
	{
		context = instance_context(&a.inst)
		if !a.alive {
			world_fail(w, "recover: n0 died before the agent's write")
			return
		}
		if oerr := fs.mount_observe_begin(m, "a.txt", scope); oerr != .None {
			world_fail(w, "recover: mount_observe_begin: %v", oerr)
			return
		}
		if _ri_write(vfs, RI_ROOT + "/a.txt", fmt.tprintf("%sagent\n", string(base))) != .None || _ri_write(vfs, RI_ROOT + "/c.txt", "c\nperson\n") != .None {
			world_fail(w, "recover: the agent and person writes failed")
			return
		}
		a.disk.crash_at = a.disk.stats.ops + k
		fs.scope_close(a.reg, scope)
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	a.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	if !crashed {
		run_until(w, w.now + 5_000_000_000, true)
		if a.alive && (!_ri_check_synced(w, a, tree, m, actor, sid, k) || notes.merged == 0) {
			world_fail(w, "recover: the agent's write from its stale base was not merged (%d other base notes), so the pass never held two concurrent intents", notes.other)
		}
		return
	}
	for _ in 0 ..< 40 {
		if a.alive {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !a.alive {
		world_fail(w, "recover: n0 did not restart after the crash at op %d of the pass", k)
		return
	}
	if m2, ok := _ri_remount(w, a, tree, k); ok {
		run_until(w, w.now + 5_000_000_000, true)
		_ri_check_synced(w, a, tree, m2, actor, sid, k)
	}
	return
}

@(private = "file")
_ri_check_synced :: proc(w: ^World, a: ^Node, tree: eng.Object, m: ^fs.Mount, actor: prim.Id, sid: prim.Id, k: u64) -> (merged: bool) {
	context = instance_context(&a.inst)
	defer node_after(a)
	h, herr := eng.tree_history(&a.e, tree)
	if herr != .None {
		world_fail(w, "recover: tree_history after the crash at op %d: %v", k, herr)
		return
	}
	defer eng.tree_release(&a.e, tree)
	known := crdt.graph_known(&h.g, actor)
	if known == 0 {
		return false
	}
	lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{actor, known - 1})
	have := make([dynamic]crdt.Lv, context.temp_allocator)
	if !ok || crdt.graph_version_lvs(&h.g, m.synced[:], &have) != .None || !crdt.graph_contains(&h.g, have[:], lv) {
		world_fail(w, "recover: after a crash at op %d the mount's synced version %v misses the agent's own merged base, op %s:%d, which its history holds", k, m.synced[:], id_short(actor), known - 1)
	}
	if sc, found, _ := fs.history_scope_of(h, crdt.Op_Id{actor, known - 1}); !found || sc != sid {
		world_fail(w, "recover: after a crash at op %d the agent's merged write op %s:%d is attributed to scope %v (found %v), not its tool scope %v", k, id_short(actor), known - 1, sc, found, sid)
	}
	return true
}

@(private = "file")
_ri_remount :: proc(w: ^World, a: ^Node, tree: eng.Object, k: u64) -> (m: ^fs.Mount, ok: bool) {
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		if a.reg == nil {
			reg, rerr := eng.registry(&a.e)
			if rerr != .None {
				world_fail(w, "recover: registry after restart: %v", rerr)
				return nil, false
			}
			a.reg = reg
		}
		err: eng.Error
		if m, err = eng.tree_mount(&a.e, tree, RI_ROOT); err != .None && !(err == .Pending && m != nil) {
			world_fail(w, "recover: n0 could not remount after a crash at op %d of a pass that merged an agent base next to a person's edit: %v", k, err)
			return nil, false
		}
	}
	return m, true
}

@(test)
recover_intents :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 2 {
		for k := u64(1); k < 4000; k += 1 {
			crashed, failures := _ri_case(seed, k)
			for f in failures {
				fmt.eprintf("recover_intents seed %d crash %d: %s\n", seed, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "recover_intents seed %d crash at op %d failed", seed, k)
			n := len(failures)
			delete(failures)
			if !crashed || n > 0 {
				break
			}
		}
	}
	free_all(context.temp_allocator)
}

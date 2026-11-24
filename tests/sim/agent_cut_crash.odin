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

CUT_ROOT :: "/work/cut-n0"

agent_cut_run :: proc(seed: u64, crash_at: u64, process: bool, pass: bool) -> (failures: [dynamic]string, crashed: bool, undone: bool) {
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
	crashed, undone = _cut_crash(w, crash_at, process, pass)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_cut_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == CUT_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
Cut_Observed :: struct {
	done: bool,
	err:  fs.Error,
}

@(private = "file")
_cut_observed :: proc(ctx: rawptr, err: fs.Error) {
	o := cast(^Cut_Observed)ctx
	o.done = true
	o.err = err
}

@(private = "file")
_cut_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_cut_crash :: proc(w: ^World, crash_at: u64, process: bool, pass: bool) -> (crashed: bool, undone: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "cut: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "cut")
		if err != .None {
			world_fail(w, "cut: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "cut: tree_create: %v", err)
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
	if err := prim.mkdir_all(vfs, CUT_ROOT); err != .None {
		world_fail(w, "cut: mkdir: %v", err)
		return
	}
	if err := _cut_write(vfs, CUT_ROOT + "/a.txt", transmute([]u8)string("base line\n")); err != .None {
		world_fail(w, "cut: base write: %v", err)
		return
	}
	if err := node_mount(w, n, oi, CUT_ROOT); err != .None {
		world_fail(w, "cut: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(CUT_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	line := "agent line\n"
	before: []crdt.Op_Id
	crashes := w.stats.crashes
	n.disk.crash_at = n.disk.stats.ops + crash_at
	n.disk.force_process = process
	write: {
		context = instance_context(&n.inst)
		sm := _cut_mount(n)
		if sm == nil {
			world_fail(w, "cut: mount missing before the write")
			return
		}
		if pass {
			fs.mount_sync(sm.m)
			if n.disk.dead {
				break write
			}
		}
		before = slice.clone(_line_heads(sm.m), w.allocator)
		scope := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		obs := Cut_Observed{}
		if fs.mount_observe_begin(sm.m, "a.txt", scope, _cut_observed, &obs) != .None || n.disk.dead {
			break write
		}
		for !obs.done && !n.disk.dead && n.alive {
			run_until(w, w.now + 10_000_000, true)
			context = instance_context(&n.inst)
		}
		if !obs.done || obs.err != .None || n.disk.dead || !n.alive {
			break write
		}
		if _cut_mount(n) != sm {
			break write
		}
		_writer_set(w, n, CUT_ROOT + "/a.txt", Writer_Info{scope = scope, agent = true})
		if _cut_write(vfs, CUT_ROOT + "/a.txt", transmute([]u8)strings.concatenate({"base line\n", line}, context.temp_allocator)) != .None || n.disk.dead {
			break write
		}
		fs.scope_close(n.reg, scope)
		_forget_scope(w, n, scope)
	}
	if n.disk.dead {
		node_crashed(n)
	} else {
		ctx: {
			context = instance_context(&n.inst)
			node_after(n)
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "cut: node did not come back")
		return
	}
	if _cut_mount(n) == nil {
		world_fail(w, "cut: mount missing after recovery")
		return
	}
	want, mine := "", false
	credit: {
		context = instance_context(&n.inst)
		defer node_after(n)
		data, spans, berr := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator)
		if berr != .None {
			world_fail(w, "cut: blame a.txt: %v", berr)
			return
		}
		at := strings.index(string(data), line)
		if at < 0 {
			return
		}
		pos := 0
		mine = true
		for sp in spans {
			lo := max(pos, at)
			hi := min(pos + sp.len, at + len(line))
			if lo < hi && sp.id.actor != agent {
				if process || !fs.is_unattributed(sp.id.actor) {
					world_fail(w, "cut: %d bytes of the agent's line are credited to %s, not the agent %s (%v crash at disk op %d)", hi - lo, id_short(sp.id.actor), id_short(agent), "process" if process else "power", crash_at)
					return
				}
				mine = false
			}
			pos += sp.len
		}
		want = strings.clone(string(data), w.allocator)
	}
	if !mine {
		return
	}
	revert: prim.Id
	undo: {
		context = instance_context(&n.inst)
		defer node_after(n)
		rerr: fs.Error
		revert, rerr = fs.mount_revert_set(_cut_mount(n).m, fs.Version(before), []prim.Id{agent})
		if rerr != .None || revert == {} {
			world_fail(w, "cut: undo of the agent's write: revert %s, %v", id_short(revert), rerr)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	cut, _ := strings.remove_all(want, line, w.allocator)
	if !_cut_holds(w, n, tree, cut, "undo") {
		return
	}
	redo: {
		context = instance_context(&n.inst)
		defer node_after(n)
		if _, rerr := fs.mount_unrevert(_cut_mount(n).m, revert); rerr != .None {
			world_fail(w, "cut: redo of the agent's write: %v", rerr)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	undone = _cut_holds(w, n, tree, want, "redo")
	return
}

@(private = "file")
_cut_holds :: proc(w: ^World, n: ^Node, tree: eng.Object, want: string, what: string) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	stored, serr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator)
	n.disk.probe += 1
	disk, derr := prim.read_file(disk_vfs(&n.disk), CUT_ROOT + "/a.txt", context.temp_allocator)
	n.disk.probe -= 1
	if serr != .None || derr != .None || string(stored) != want || string(disk) != want {
		world_fail(w, "cut: after the %s a.txt is %q (%v) and on disk %q (%v), want %q", what, string(stored), serr, string(disk), derr, want)
		return false
	}
	return true
}

@(test)
agent_cut_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for pass in ([]bool{false, true}) {
		for process in ([]bool{true, false}) {
			points, undos := 0, 0
			for k in u64(1) ..= 4000 {
				failures, crashed, undone := agent_cut_run(1, k, process, pass)
				for f in failures {
					fmt.eprintf("agent_cut_crash at disk op %d (%s%s): %s\n", k, "process" if process else "power", ", after a pass" if pass else "", f)
					delete(f)
				}
				testing.expect(t, len(failures) == 0, fmt.tprintf("agent_cut_crash at disk op %d failed", k))
				delete(failures)
				undos += 1 if undone else 0
				if !crashed {
					points = int(k) - 1
					break
				}
			}
			fmt.eprintf("agent_cut_crash: %d %s crash points%s, %d undone and redone\n", points, "process" if process else "power", " after a pass" if pass else "", undos)
		}
	}
}

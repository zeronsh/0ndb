package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

RACE_ROOT :: "/work/race-n0"

Race_Case :: enum u8 {
	Marked_First,
	Unseen_First,
	Person_Before,
	Person_Other_Path,
}

tool_race_run :: proc(seed: u64, rc: Race_Case) -> (failures: [dynamic]string) {
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
	_race(w, rc)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_race_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == RACE_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_race_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_race_line_owner :: proc(w: ^World, n: ^Node, tree: eng.Object, path: string, line: string, agent: prim.Id, want_agent: bool, rc: Race_Case) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, spans, berr := eng.tree_blame(&n.e, tree, path, context.temp_allocator)
	if berr != .None {
		world_fail(w, "race %v: blame %s: %v", rc, path, berr)
		return
	}
	at := strings.index(string(data), line)
	if at < 0 {
		world_fail(w, "race %v: %q is not in %s (%q)", rc, line, path, string(data))
		return
	}
	pos := 0
	for sp in spans {
		lo := max(pos, at)
		hi := min(pos + sp.len, at + len(line))
		if lo < hi {
			if want_agent && sp.id.actor != agent {
				world_fail(w, "race %v: %d bytes of the tool's line in %s are credited to %s, not the tool scope %s", rc, hi - lo, path, id_short(sp.id.actor), id_short(agent))
				return
			}
			if !want_agent && sp.id.actor == agent {
				world_fail(w, "race %v: %d bytes of the person's line in %s are credited to the tool scope %s", rc, hi - lo, path, id_short(agent))
				return
			}
		}
		pos += sp.len
	}
}

@(private = "file")
_race_settle :: proc(w: ^World, n: ^Node) {
	mark: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 50_000_000, true)
}

@(private = "file")
_race :: proc(w: ^World, rc: Race_Case) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "race: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "race")
		if err != .None {
			world_fail(w, "race: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "race: tree_create: %v", err)
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
	a := RACE_ROOT + "/a.txt"
	b := RACE_ROOT + "/b.txt"
	if prim.mkdir_all(vfs, RACE_ROOT) != .None || _race_write(vfs, a, "base a\n") != .None || _race_write(vfs, b, "base b\n") != .None {
		world_fail(w, "race: setup writes")
		return
	}
	if err := node_mount(w, n, oi, RACE_ROOT); err != .None {
		world_fail(w, "race: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(RACE_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	turn: ^fs.Scope
	run_open: {
		context = instance_context(&n.inst)
		sm := _race_mount(n)
		if sm == nil {
			world_fail(w, "race: mount missing")
			return
		}
		turn = fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		node_after(n)
	}
	tool_line := "tool line\n"
	person_line := "person line\n"
	if rc == .Person_Before {
		if _race_write(vfs, a, strings.concatenate({"base a\n", person_line}, context.temp_allocator)) != .None {
			world_fail(w, "race: person write")
			return
		}
		_race_settle(w, n)
	}
	since := fs.Observe_Since{mono = prim.clock_mono_ns(n.e.cfg.clock), wall = prim.clock_wall_ns(n.e.cfg.clock)}
	run_until(w, w.now + 1_000_000, true)
	if rc == .Person_Other_Path {
		if _race_write(vfs, b, strings.concatenate({"base b\n", person_line}, context.temp_allocator)) != .None {
			world_fail(w, "race: person write")
			return
		}
		_race_settle(w, n)
	}
	before := "base a\n"
	if rc == .Person_Before {
		before = strings.concatenate({"base a\n", person_line}, context.temp_allocator)
	}
	if rc != .Person_Before {
		if _race_write(vfs, a, strings.concatenate({before, tool_line}, context.temp_allocator)) != .None {
			world_fail(w, "race: tool write")
			return
		}
		if rc != .Unseen_First {
			_race_settle(w, n)
		}
	}
	begin: {
		context = instance_context(&n.inst)
		sm := _race_mount(n)
		if sm == nil {
			world_fail(w, "race: mount missing")
			return
		}
		scope := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent, nil, since)
		fs.scope_write_begin(scope, "a.txt")
		if oerr := fs.mount_observe_begin(sm.m, "a.txt", scope, nil, nil, since); oerr != .None {
			world_fail(w, "race: observe: %v", oerr)
			return
		}
		if rc == .Person_Before {
			if _race_write(vfs, a, strings.concatenate({before, tool_line}, context.temp_allocator)) != .None {
				world_fail(w, "race: tool write")
				return
			}
		}
		fs.scope_write_end(scope, "a.txt")
		fs.scope_close(n.reg, scope)
		node_after(n)
	}
	run_until(w, w.now + 3_000_000_000, true)
	run_close: {
		context = instance_context(&n.inst)
		fs.scope_close(n.reg, turn)
		node_after(n)
	}
	run_until(w, w.now + 1_000_000_000, true)
	_race_line_owner(w, n, tree, "a.txt", tool_line, agent, true, rc)
	if rc == .Person_Before {
		_race_line_owner(w, n, tree, "a.txt", person_line, agent, false, rc)
	}
	if rc == .Person_Other_Path {
		_race_line_owner(w, n, tree, "b.txt", person_line, agent, false, rc)
	}
}

@(test)
tool_write_race :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for rc in Race_Case {
		for seed in u64(1) ..= 8 {
			failures := tool_race_run(seed, rc)
			for f in failures {
				fmt.eprintf("tool_write_race %v seed %d: %s\n", rc, seed, f)
				delete(f)
			}
			testing.expect(t, len(failures) == 0, fmt.tprintf("tool_write_race %v seed %d failed", rc, seed))
			delete(failures)
		}
	}
}

package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/odb"
import "../../src/prim"

SWITCH_ROOT :: "/work/switch-n0-git"

Switch_Outcome :: enum u8 {
	Completed,
	Stayed,
	Switched,
}

Switch_Step :: enum u8 {
	Before_Record,
	Ingest,
	Materialize_Before_Target,
	Materialize_Target_On_Disk,
	Read_Tree,
	Update_Index,
	Symbolic_Ref,
	Record_Clear,
}

@(private = "file", thread_local)
_probe: ^Switch_Probe

@(private = "file")
Switch_Probe :: struct {
	seen:  bool,
	step:  Switch_Step,
	stale: bool,
}

@(init, private = "file")
_switch_probe_init :: proc "contextless" () {
	register_restarted(65, _switch_probe, false)
}

@(private = "file")
_switch_probe :: proc(w: ^World, n: ^Node) {
	if _probe == nil || _probe.seen || !n.alive {
		return
	}
	context = instance_context(&n.inst)
	n.disk.probe += 1
	defer n.disk.probe -= 1
	for &x in n.mounts {
		if x.root != SWITCH_ROOT || x.m == nil {
			continue
		}
		_probe.seen = true
		vfs := disk_vfs(&n.disk)
		head, _ := prim.read_file(vfs, SWITCH_ROOT + "/.git/HEAD", context.temp_allocator)
		moved := strings.trim_space(string(head)) == "ref: refs/heads/feature"
		_, lerr := prim.stat(vfs, SWITCH_ROOT + "/.git/index.lock")
		_probe.stale = lerr == .None
		_, cerr := prim.stat(vfs, SWITCH_ROOT + "/c.txt")
		rows := git_index_oids(vfs, SWITCH_ROOT)
		_, indexed := rows["c.txt"]
		_, pending := fs.mount_switch_pending(x.m)
		switch {
		case !pending && moved:
			_probe.step = .Record_Clear
		case !pending:
			_probe.step = .Before_Record
		case x.m.switch_phase < fs.SWITCH_TARGET:
			_probe.step = .Ingest
		case x.m.switch_phase == fs.SWITCH_TARGET:
			_probe.step = .Materialize_Target_On_Disk if cerr == .None else .Materialize_Before_Target
		case moved:
			_probe.step = .Symbolic_Ref
		case indexed:
			_probe.step = .Update_Index
		case:
			_probe.step = .Read_Tree
		}
	}
}

switch_crash_run :: proc(seed: u64, crash_at: u64) -> (failures: [dynamic]string, outcome: Switch_Outcome, crashed: bool, probe: Switch_Probe) {
	failures = make([dynamic]string)
	_probe = &probe
	defer _probe = nil
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
	outcome, crashed = _switch_crash(w, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_switch_crash :: proc(w: ^World, crash_at: u64) -> (outcome: Switch_Outcome, crashed: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "switch: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "switch")
		if err != .None {
			world_fail(w, "switch: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "switch: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("main a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, SWITCH_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "switch: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}, {name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, SWITCH_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "switch: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, SWITCH_ROOT); err != .None {
		world_fail(w, "switch: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SWITCH_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if err := _switch_write(vfs, SWITCH_ROOT + "/a.txt", transmute([]u8)string("main a\nmain dirty\n")); err != .None {
		world_fail(w, "switch: dirty edit: %v", err)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	crashes := w.stats.crashes
	n.disk.crash_at = n.disk.stats.ops + crash_at
	serr: fs.Error
	{
		context = instance_context(&n.inst)
		sm := n.mounts[len(n.mounts) - 1]
		serr = fs.mount_line_switch(sm.m, "git:refs/heads/feature")
		node_after(n)
	}
	if serr != .None && !n.disk.dead && w.stats.crashes == crashes {
		world_fail(w, "switch: line_switch failed to start: %v", serr)
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "switch: node did not come back")
		return
	}
	sm: ^Sim_Mount
	for &x in n.mounts {
		if x.root == SWITCH_ROOT && x.m != nil {
			sm = &x
		}
	}
	if sm == nil {
		world_fail(w, "switch: mount missing after recovery")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	if to, pending := fs.mount_switch_pending(sm.m); pending {
		world_fail(w, "switch: the switch record to %s is still set after recovery", to)
	}
	line := fs.mount_line(sm.m)
	head, _ := prim.read_file(vfs, SWITCH_ROOT + "/.git/HEAD", context.temp_allocator)
	on_feature := line == "git:refs/heads/feature"
	if on_feature != (strings.trim_space(string(head)) == "ref: refs/heads/feature") {
		world_fail(w, "switch: line %s but HEAD %q", line, strings.trim_space(string(head)))
	}
	want := line_eng(line_norm(line)) if on_feature else "main"
	names, lerr := eng.tree_list(&n.e, tree, "", context.temp_allocator, {}, want)
	if lerr != .None {
		world_fail(w, "switch: cannot list line %s: %v", want, lerr)
		return
	}
	for nm in names {
		data, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator, {}, want)
		disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", SWITCH_ROOT, nm), context.temp_allocator)
		if derr != .None || string(disk) != string(data) {
			world_fail(w, "switch: %s on disk is %q (%v), line %s has %q", nm, string(disk), derr, want, string(data))
		}
	}
	if on_feature {
		if _, cerr := prim.read_file(vfs, SWITCH_ROOT + "/c.txt", context.temp_allocator); cerr != .None {
			world_fail(w, "switch: feature's c.txt is not on disk: %v", cerr)
		}
		rows := git_index_oids(vfs, SWITCH_ROOT)
		for f in branch_files {
			o, _ := odb.hash(.Sha1, .Blob, f.data)
			if rows[f.name] != o {
				world_fail(w, "switch: the index does not hold feature's %s", f.name)
			}
		}
		outcome = .Switched
	} else {
		outcome = .Stayed
	}
	main_a, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if !strings.contains(string(main_a), "main dirty") {
		world_fail(w, "switch: main's uncommitted edit was rewound: a.txt on main is %q", string(main_a))
	}
	if !crashed {
		outcome = .Completed
	}
	return
}

@(test)
line_switch_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	stayed, switched := 0, 0
	steps: [Switch_Step][2]int
	stale := 0
	for k in u64(1) ..= 4000 {
		failures, outcome, crashed, probe := switch_crash_run(1, k)
		for f in failures {
			fmt.eprintf("line_switch_crash at disk op %d: %s\n", k, f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0, fmt.tprintf("line_switch_crash at disk op %d failed", k))
		delete(failures)
		if !crashed {
			fmt.eprintf("line_switch_crash: %d crash points, %d stayed on main, %d rolled forward, %d left a stale index.lock\n", k - 1, stayed, switched, stale)
			for st in Switch_Step {
				fmt.eprintf("line_switch_crash: crashed in %v: %d stayed, %d rolled forward\n", st, steps[st][0], steps[st][1])
			}
			return
		}
		testing.expect(t, probe.seen, fmt.tprintf("line_switch_crash at disk op %d: the mount was not reopened", k))
		if probe.stale {
			stale += 1
		}
		if outcome == .Stayed {
			stayed += 1
			steps[probe.step][0] += 1
		} else {
			switched += 1
			steps[probe.step][1] += 1
		}
	}
	testing.expect(t, false, "line_switch_crash: the switch never completed without a crash")
}

@(private = "file")
_switch_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

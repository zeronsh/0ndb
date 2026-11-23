package sim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
SA_ROOT :: "/work/switch-after-n0-git"

@(private = "file")
SA_FEATURE :: "git:refs/heads/feature"


@(private = "file")
SA_REMOTE :: "main a\nremote\n"

Switch_After_Kind :: enum u8 {
	Line_Switch,
	Checkout,
	Commit_Checkout,
}

@(private = "file")
SA_COMMITTED :: "main b\ncommitted\n"

@(private = "file")
Sa_Lines :: struct {
	main:    map[string]string,
	feature: map[string]string,
}

@(private = "file")
_sa_world :: proc(seed: u64) -> ^World {
	cfg := default_config(seed)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.durability = .Async
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	return w
}

switch_after_run :: proc(seed: u64, kind: Switch_After_Kind, mode: Crash_Mode, crash_at: u64) -> (failures: [dynamic]string, crashed: bool) {
	failures = make([dynamic]string)
	w := _sa_world(seed)
	crashed = _switch_after(w, kind, mode, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_sa_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == SA_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_sa_line :: proc(w: ^World, n: ^Node, tree: eng.Object, line: string) -> (out: map[string]string, ok: bool) {
	context = instance_context(&n.inst)
	out = make(map[string]string, w.allocator)
	names, err := eng.tree_list(&n.e, tree, "", context.temp_allocator, {}, line)
	if err != .None {
		return out, false
	}
	for nm in names {
		data, rerr := eng.tree_read(&n.e, tree, nm, context.temp_allocator, {}, line)
		if rerr != .None {
			return out, false
		}
		out[strings.clone(nm, w.allocator)] = strings.clone(string(data), w.allocator)
	}
	return out, true
}

@(private = "file")
_sa_lines :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (l: Sa_Lines, ok: bool) {
	m_ok, f_ok: bool
	l.main, m_ok = _sa_line(w, n, tree, "main")
	l.feature, f_ok = _sa_line(w, n, tree, SA_FEATURE)
	return l, m_ok && f_ok
}

@(private = "file")
_sa_same :: proc(w: ^World, line: string, want, got: map[string]string, kind: Switch_After_Kind, mode: Crash_Mode, crash_at: u64) {
	keys := make([dynamic]string, context.temp_allocator)
	for k in want {
		append(&keys, k)
	}
	for k in got {
		if k not_in want {
			append(&keys, k)
		}
	}
	slice.sort(keys[:])
	for k in keys {
		a, had := want[k]
		b, has := got[k]
		if had != has || a != b {
			world_fail(w, "switch after: %v then a %v crash and a crash at reopen disk op %d changed line %s's %s from %q (%v) to %q (%v)", kind, mode, crash_at, line, k, a, had, b, has)
		}
	}
}

@(private = "file")
_sa_setup :: proc(w: ^World) -> (n: ^Node, tree: eng.Object, ok: bool) {
	n = w.nodes[0]
	if !node_start(n) {
		world_fail(w, "switch after: node start")
		return n, tree, false
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "switch-after")
		if err != .None {
			world_fail(w, "switch after: space_create: %v", err)
			return n, tree, false
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "switch after: tree_create: %v", err)
			return n, tree, false
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
	if err := git_checkout_create(vfs, SA_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "switch after: git checkout: %v", err)
		return n, tree, false
	}
	branch_files := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}, {name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, SA_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "switch after: branch commit: %v", err)
		return n, tree, false
	}
	if err := node_mount(w, n, oi, SA_ROOT); err != .None {
		world_fail(w, "switch after: mount: %v", err)
		return n, tree, false
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SA_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	return n, tree, true
}

@(private = "file")
_switch_after :: proc(w: ^World, kind: Switch_After_Kind, mode: Crash_Mode, crash_at: u64) -> (crashed: bool) {
	n, tree, sok := _sa_setup(w)
	if !sok {
		return
	}
	vfs := disk_vfs(&n.disk)
	sm0 := _sa_mount(n)
	if sm0 == nil {
		world_fail(w, "switch after: mount missing")
		return
	}
	home := strings.clone(fs.mount_line(sm0.m), w.allocator)
	if !_sa_switch(w, n, kind, SA_FEATURE, "feature") || !_sa_switch(w, n, kind, home, "main") {
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	{
		context = instance_context(&n.inst)
		base, _ := eng.tree_version(&n.e, tree, "main", context.temp_allocator)
		if err := eng.tree_write(&n.e, tree, "a.txt", transmute([]u8)string(SA_REMOTE), base, "main"); err != .None {
			world_fail(w, "switch after: tree_write on main: %v", err)
			return
		}
		node_after(n)
	}
	landed := false
	for limit := w.now + 20_000_000_000; w.now < limit && !landed; {
		t, ok := next_time(w)
		if !ok {
			break
		}
		run_until(w, t, false)
		n.disk.probe += 1
		data, _ := prim.read_file(vfs, SA_ROOT + "/a.txt", context.temp_allocator)
		n.disk.probe -= 1
		landed = string(data) == SA_REMOTE
	}
	if !landed {
		world_fail(w, "switch after: the write on main never reached the worktree")
		return
	}
	if kind == .Commit_Checkout {
		committed := [?]Git_File{{name = "b.txt", data = transmute([]u8)string(SA_COMMITTED)}}
		if err := _sa_write(vfs, SA_ROOT + "/b.txt", committed[0].data); err != .None {
			world_fail(w, "switch after: edit b.txt: %v", err)
			return
		}
		if err := git_branch_commit(vfs, SA_ROOT, "main", committed[:], nil, clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
			world_fail(w, "switch after: commit on main: %v", err)
			return
		}
	}
	if !_sa_switch(w, n, kind, SA_FEATURE, "feature") {
		return
	}
	before, ok := _sa_lines(w, n, tree)
	if !ok {
		world_fail(w, "switch after: cannot read the lines after the switch")
		return
	}
	crashes := w.stats.crashes
	node_crash_now(n, mode, crash_at)
	n.disk.crash_at = n.disk.stats.ops + crash_at
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes + 1
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "switch after: node did not come back")
		return
	}
	sm := _sa_mount(n)
	if sm == nil {
		world_fail(w, "switch after: mount missing after recovery")
		return
	}
	after, aok := _sa_lines(w, n, tree)
	if !aok {
		world_fail(w, "switch after: cannot read the lines after recovery")
		return
	}
	if kind == .Commit_Checkout && before.main["b.txt"] == SA_COMMITTED && after.main["b.txt"] != SA_COMMITTED {
		world_fail(w, "switch after: main's committed b.txt is %q after recovery", after.main["b.txt"])
	}
	_sa_same(w, "main", before.main, after.main, kind, mode, crash_at)
	_sa_same(w, SA_FEATURE, before.feature, after.feature, kind, mode, crash_at)
	context = instance_context(&n.inst)
	defer node_after(n)
	if to, pending := fs.mount_switch_pending(sm.m); pending {
		world_fail(w, "switch after: a switch to %s is pending after recovery", to)
	}
	if line := fs.mount_line(sm.m); line != SA_FEATURE || git_head_line(vfs, SA_ROOT) != SA_FEATURE {
		world_fail(w, "switch after: mount line %s, HEAD line %s after recovery", line, git_head_line(vfs, SA_ROOT))
	}
	n.disk.probe += 1
	defer n.disk.probe -= 1
	for nm, data in after.feature {
		disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", SA_ROOT, nm), context.temp_allocator)
		if derr != .None || string(disk) != data {
			world_fail(w, "switch after: %s on disk is %q (%v), line %s has %q", nm, string(disk), derr, SA_FEATURE, data)
		}
	}
	return
}

@(test)
line_switch_after_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for kind in Switch_After_Kind {
		for mode in Crash_Mode {
			points := 0
			for k in u64(1) ..= 3000 {
				failures, crashed := switch_after_run(1, kind, mode, k)
				for f in failures {
					fmt.eprintf("line_switch_after_crash: %s\n", f)
					delete(f)
				}
				testing.expect(t, len(failures) == 0, fmt.tprintf("line_switch_after_crash %v %v at reopen disk op %d failed", kind, mode, k))
				delete(failures)
				if !crashed {
					break
				}
				points += 1
			}
			fmt.eprintf("line_switch_after_crash: %v then %v crash: %d reopen crash points\n", kind, mode, points)
			testing.expect(t, points > 0, fmt.tprintf("line_switch_after_crash %v %v: the reopen never crashed", kind, mode))
		}
	}
}

@(private = "file")
SA_PRE :: "main a\npre\n"

Switch_Race_Kind :: enum u8 {
	Edit,
	Create,
	Create_Dir,
}

@(private = "file")
_sa_raced :: proc(kind: Switch_Race_Kind) -> (path: string, data: string) {
	switch kind {
	case .Edit:
		return "a.txt", "main a\npre\nraced\n"
	case .Create:
		return "c.txt", "raced c\n"
	case .Create_Dir:
		return "fresh/d.txt", "raced d\n"
	}
	return
}

switch_ingest_race_run :: proc(seed: u64, kind: Switch_Race_Kind) -> (failures: [dynamic]string, raced: bool) {
	failures = make([dynamic]string)
	w := _sa_world(seed)
	raced = _switch_ingest_race(w, kind)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_sa_step :: proc(w: ^World) -> bool {
	t, ok := next_time(w)
	if !ok {
		return false
	}
	run_until(w, t, false)
	return true
}

@(private = "file")
_switch_ingest_race :: proc(w: ^World, kind: Switch_Race_Kind) -> (raced: bool) {
	n, tree, ok := _sa_setup(w)
	if !ok {
		return
	}
	vfs := disk_vfs(&n.disk)
	if err := _sa_write(vfs, SA_ROOT + "/a.txt", transmute([]u8)string(SA_PRE)); err != .None {
		world_fail(w, "switch ingest race: pre write: %v", err)
		return
	}
	node_after(n)
	seen := false
	for limit := w.now + 20_000_000_000; w.now < limit && !seen; {
		if !_sa_step(w) {
			break
		}
		got, _ := _sa_line(w, n, tree, "main")
		seen = got["a.txt"] == SA_PRE
	}
	if !seen {
		world_fail(w, "switch ingest race: the pre write was never ingested")
		return
	}
	sm := _sa_mount(n)
	if sm == nil {
		world_fail(w, "switch ingest race: mount missing")
		return
	}
	start: {
		context = instance_context(&n.inst)
		err := fs.mount_line_switch(sm.m, SA_FEATURE)
		node_after(n)
		if err != .None {
			world_fail(w, "switch ingest race: line_switch: %v", err)
			return
		}
	}
	if _, pending := fs.mount_switch_pending(sm.m); !pending || sm.m.switch_phase != fs.SWITCH_INGEST || n.watch_scheduled {
		return
	}
	rpath, rdata := _sa_raced(kind)
	if kind == .Create_Dir {
		if err := prim.mkdir(vfs, SA_ROOT + "/fresh"); err != .None {
			world_fail(w, "switch ingest race: mkdir: %v", err)
			return
		}
	}
	if err := _sa_write(vfs, fmt.tprintf("%s/%s", SA_ROOT, rpath), transmute([]u8)rdata); err != .None {
		world_fail(w, "switch ingest race: raced write: %v", err)
		return
	}
	if n.watch_scheduled || len(n.disk.events) == 0 {
		return
	}
	n.watch_scheduled = true
	raced = true
	flipped := false
	for limit := w.now + 20_000_000_000; w.now < limit && !flipped; {
		if !_sa_step(w) {
			break
		}
		sm = _sa_mount(n)
		if sm == nil {
			world_fail(w, "switch ingest race: mount missing during the switch")
			return
		}
		_, pending := fs.mount_switch_pending(sm.m)
		flipped = !pending || sm.m.switch_phase >= fs.SWITCH_TARGET
	}
	if !flipped {
		world_fail(w, "switch ingest race: the switch never left ingest")
		return
	}
	n.watch_scheduled = false
	node_after(n)
	run_until(w, w.now + 20_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	on_main, _ := eng.tree_read(&n.e, tree, rpath, context.temp_allocator, {}, "main")
	on_feat, _ := eng.tree_read(&n.e, tree, rpath, context.temp_allocator, {}, SA_FEATURE)
	if string(on_main) != rdata || strings.contains(string(on_feat), "raced") {
		world_fail(w, "switch ingest race: a %v of %s made while the switch to %s was ingesting, its watch event delayed past the line flip, is %q on main and %q on the target", kind, rpath, SA_FEATURE, string(on_main), string(on_feat))
	}
	return
}

@(test)
line_switch_ingest_race :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for kind in Switch_Race_Kind {
		raced := 0
		for seed in u64(1) ..= 20 {
			failures, r := switch_ingest_race_run(seed, kind)
			for f in failures {
				fmt.eprintf("line_switch_ingest_race %v seed %d: %s\n", kind, seed, f)
				delete(f)
			}
			testing.expect(t, len(failures) == 0, fmt.tprintf("line_switch_ingest_race %v seed %d failed", kind, seed))
			delete(failures)
			if r {
				raced += 1
			}
		}
		fmt.eprintf("line_switch_ingest_race: %v: %d of 20 seeds raced into the ingest window\n", kind, raced)
		testing.expect(t, raced > 0, fmt.tprintf("line_switch_ingest_race %v: no seed opened the ingest window", kind))
	}
}

@(private = "file")
_sa_switch :: proc(w: ^World, n: ^Node, kind: Switch_After_Kind, to: string, branch: string) -> bool {
	vfs := disk_vfs(&n.disk)
	sm := _sa_mount(n)
	if sm == nil {
		world_fail(w, "switch after: mount missing")
		return false
	}
	switch kind {
	case .Line_Switch:
		context = instance_context(&n.inst)
		err := fs.mount_line_switch(sm.m, to)
		node_after(n)
		if err != .None {
			world_fail(w, "switch after: line_switch to %s: %v", to, err)
			return false
		}
	case .Checkout, .Commit_Checkout:
		changes := make([dynamic]Git_Change, context.temp_allocator)
		res, err := git_checkout(vfs, SA_ROOT, branch, kind == .Commit_Checkout, clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng), &changes)
		if err != .None || res != .Done {
			world_fail(w, "switch after: git checkout %s: %v %v", to, res, err)
			return false
		}
		node_after(n)
	}
	limit := w.now + 20_000_000_000
	for first := true; w.now < limit; first = false {
		if !first {
			t, ok := next_time(w)
			if !ok {
				break
			}
			run_until(w, t, false)
		}
		sm = _sa_mount(n)
		if sm == nil || !n.alive {
			world_fail(w, "switch after: the mount went away before the switch to %s completed", to)
			return false
		}
		line := fs.mount_line(sm.m)
		if _, pending := fs.mount_switch_pending(sm.m); !pending && line == to {
			return true
		}
	}
	world_fail(w, "switch after: %v never put the mount on %s (line %s)", kind, to, fs.mount_line(sm.m))
	return false
}

@(private = "file")
_sa_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

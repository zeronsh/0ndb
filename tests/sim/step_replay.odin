package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
SR_ROOT :: "/work/step-n0-git"

@(private = "file")
SR_FEATURE :: "git:refs/heads/feature"

@(private = "file")
SR_BASE :: "base line\n"

@(private = "file")
SR_KEPT :: "kept line\n"

@(private = "file")
SR_TOOL :: "tool line\n"

@(private = "file")
SR_OTHER :: "other line\n"

@(private = "file")
Step_Arm :: struct {
	process: bool,
	held:    bool,
}

@(private = "file")
Step_Turn :: struct {
	name:   string,
	text:   string,
	actors: [dynamic]prim.Id,
}

@(private = "file")
_sr_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == SR_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_sr_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_sr_checkout :: proc(w: ^World, n: ^Node, branch: string) -> bool {
	changes := make([dynamic]Git_Change, context.temp_allocator)
	res, err := git_checkout(disk_vfs(&n.disk), SR_ROOT, branch, false, clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng), &changes)
	return res == .Done && err == .None
}

@(private = "file")
_sr_owned :: proc(w: ^World, n: ^Node, owner: prim.Id, out: ^[dynamic]prim.Id) {
	sm := _sr_mount(n)
	append(out, owner)
	if sm == nil {
		return
	}
	owned, _ := fs.history_owned_actors(sm.m.history, []prim.Id{owner}, context.temp_allocator)
	for a in owned {
		append(out, a)
	}
}

@(private = "file")
_sr_without :: proc(text, line: string) -> string {
	i := strings.index(text, line)
	if i < 0 {
		return text
	}
	return strings.concatenate({text[:i], text[i + len(line):]}, context.temp_allocator)
}

@(private = "file")
_sr_undo :: proc(w: ^World, n: ^Node, tree: eng.Object, arm: Step_Arm, k: u64, turn: ^Step_Turn, line: string, base: fs.Version) {
	before, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	if rerr != .None {
		world_fail(w, "step: %v k=%d: read %s: %v", arm, k, line, rerr)
		return
	}
	revert, verr := eng.tree_revert_set(&n.e, tree, base, turn.actors[:], line)
	if verr != .None {
		world_fail(w, "step: %v k=%d: undo of %s on %s: %v", arm, k, turn.name, line, verr)
		return
	}
	after, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	if want := _sr_without(string(before), turn.text); string(after) != want {
		world_fail(w, "step: %v k=%d: undo of %s on %s leaves %q, want %q", arm, k, turn.name, line, string(after), want)
	}
	if revert == {} {
		return
	}
	if _, uerr := eng.tree_unrevert(&n.e, tree, revert, line); uerr != .None {
		world_fail(w, "step: %v k=%d: redo of %s on %s: %v", arm, k, turn.name, line, uerr)
		return
	}
	again, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	if string(again) != string(before) {
		world_fail(w, "step: %v k=%d: redo of %s on %s gives %q, want %q", arm, k, turn.name, line, string(again), string(before))
	}
}

@(private = "file")
_step_run :: proc(seed: u64, arm: Step_Arm, crash_at: u64) -> (failures: [dynamic]string, crashed: bool) {
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
	cfg.durability = .Async
	cfg.mem_max = 1500
	w := new(World)
	world_init(w, cfg)
	crashed = _step_crash(w, arm, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_step_crash :: proc(w: ^World, arm: Step_Arm, k: u64) -> (crashed: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "step: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "step")
		if err != .None {
			world_fail(w, "step: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "step: tree_create: %v", err)
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
	when_s := clock_wall(&n.clock) / 1_000_000_000
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(SR_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, SR_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "step: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, SR_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "step: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, SR_ROOT); err != .None {
		world_fail(w, "step: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SR_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	for b in ([]string{"feature", "main"}) {
		if !_sr_checkout(w, n, b) {
			world_fail(w, "step: round trip to %s", b)
			return
		}
		trip: {
			context = instance_context(&n.inst)
			node_after(n)
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	main_base, feature_base: fs.Version
	other_turn := Step_Turn{name = "W", text = SR_OTHER, actors = make([dynamic]prim.Id, w.allocator)}
	other: {
		context = instance_context(&n.inst)
		main_base, _ = eng.tree_version(&n.e, tree, "main", w.allocator)
		feature_base, _ = eng.tree_version(&n.e, tree, SR_FEATURE, w.allocator)
		if err := eng.tree_write(&n.e, tree, "a.txt", transmute([]u8)string(SR_BASE + SR_OTHER), feature_base, SR_FEATURE); err != .None {
			world_fail(w, "step: tree_write on feature: %v", err)
			return
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	written: {
		context = instance_context(&n.inst)
		after, _ := eng.tree_version(&n.e, tree, SR_FEATURE, context.temp_allocator)
		for id in after {
			append(&other_turn.actors, id.actor)
		}
	}
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	writer := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	holder := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	pin: {
		context = instance_context(&n.inst)
		sm := _sr_mount(n)
		if sm == nil {
			world_fail(w, "step: mount missing")
			return
		}
		if arm.held {
			hold := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), holder)
			fs.scope_write_begin(hold, "a.txt")
		}
		reader := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		fs.scope_read_base(reader, "a.txt", transmute([]u8)string(SR_BASE))
		if arm.held {
			ws := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), writer)
			fs.mount_observe_begin(sm.m, "a.txt", ws)
			_writer_set(w, n, SR_ROOT + "/a.txt", Writer_Info{scope = ws, agent = true})
			if err := _sr_write(vfs, SR_ROOT + "/a.txt", SR_BASE + SR_KEPT); err != .None {
				world_fail(w, "step: writer's write: %v", err)
				return
			}
			fs.scope_close(n.reg, ws)
			_forget_scope(w, n, ws)
		}
		fs.mount_observe_begin(sm.m, "a.txt", reader)
		_writer_set(w, n, SR_ROOT + "/a.txt", Writer_Info{scope = reader, agent = true})
		if err := _sr_write(vfs, SR_ROOT + "/a.txt", SR_BASE + SR_TOOL); err != .None {
			world_fail(w, "step: agent write: %v", err)
			return
		}
		fs.scope_close(n.reg, reader)
		_forget_scope(w, n, reader)
		node_after(n)
	}
	crashes := w.stats.crashes
	n.disk.force_process = arm.process
	n.disk.crash_at = n.disk.stats.ops + k
	_sr_write(vfs, SR_ROOT + "/b.txt", "main b\nraised\n")
	if !n.disk.dead {
		_sr_checkout(w, n, "feature")
	}
	after: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "step: node did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	turns := make([dynamic]Step_Turn, context.temp_allocator)
	append(&turns, other_turn)
	tool_turn := Step_Turn{name = "agent", text = SR_TOOL, actors = make([dynamic]prim.Id, context.temp_allocator)}
	_sr_owned(w, n, agent, &tool_turn.actors)
	append(&turns, tool_turn)
	if arm.held {
		kept_turn := Step_Turn{name = "writer", text = SR_KEPT, actors = make([dynamic]prim.Id, context.temp_allocator)}
		_sr_owned(w, n, writer, &kept_turn.actors)
		append(&turns, kept_turn)
	}
	lines := [2]string{"main", SR_FEATURE}
	bases := [2]fs.Version{main_base, feature_base}
	for &turn in turns {
		seen := 0
		for line in lines {
			data, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
			c := strings.count(string(data), turn.text)
			if c > 1 {
				world_fail(w, "step: %v k=%d: %s's line appears %d times on %s (%q)", arm, k, turn.name, c, line, string(data))
			}
			seen += c
		}
		if seen == 0 && turn.name != "W" {
			world_fail(w, "step: %v k=%d: %s's line is on no line", arm, k, turn.name)
		}
	}
	for &turn in turns {
		for line, i in lines {
			data, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
			if strings.count(string(data), turn.text) == 1 {
				_sr_undo(w, n, tree, arm, k, &turn, line, bases[i])
			}
		}
	}
	fdata, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, SR_FEATURE)
	if strings.count(string(fdata), SR_OTHER) != 1 {
		world_fail(w, "step: %v k=%d: W appears %d times on feature (%q)", arm, k, strings.count(string(fdata), SR_OTHER), string(fdata))
	}
	return
}

@(test)
step_replay :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	only := env_u64("STEP_OP", 0)
	for held in ([]bool{true, false}) {
		for process in ([]bool{false, true}) {
			arm := Step_Arm{process = process, held = held}
			points, bad := 0, 0
			for k in u64(1) ..= 4000 {
				if only != 0 && k != only {
					continue
				}
				failures, crashed := _step_run(1, arm, k)
				if len(failures) > 0 {
					bad += 1
				}
				for f in failures {
					fmt.eprintf("step_replay: %s\n", f)
					delete(f)
				}
				testing.expect(t, len(failures) == 0, fmt.tprintf("step_replay %v at disk op %d failed", arm, k))
				delete(failures)
				if !crashed {
					break
				}
				points += 1
			}
			fmt.eprintf("step_replay: held=%v process=%v: points=%d failed=%d\n", held, process, points, bad)
		}
	}
}

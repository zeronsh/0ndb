package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
SA_ROOT :: "/work/attack-n0-git"

@(private = "file")
SA_FEATURE :: "git:refs/heads/feature"

@(private = "file")
SA_BASE :: "base line\n"

@(private = "file")
SA_X :: "x line\n"

@(private = "file")
SA_Y :: "y line\n"

Attack_Kind :: enum u8 {
	Aba,
	Twins,
	Person,
	Typed,
	Undone,
	Open,
	Merge,
	Chain,
}

Attack_Arm :: struct {
	kind:     Attack_Kind,
	process:  bool,
	checkout: bool,
}

Attack_Out :: struct {
	crashed: bool,
	lines:   [2]string,
	undo:    [4][2]string,
	redo:    [4][2]string,
	turns:   int,
	disk:    string,
	moved:   bool,
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
_sa_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_sa_checkout :: proc(w: ^World, n: ^Node, branch: string) -> bool {
	changes := make([dynamic]Git_Change, context.temp_allocator)
	res, err := git_checkout(disk_vfs(&n.disk), SA_ROOT, branch, false, clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng), &changes)
	return res == .Done && err == .None
}

@(private = "file")
_sa_turn :: proc(w: ^World, n: ^Node, read, data: string) -> (who: prim.Id, ok: bool) {
	sm := _sa_mount(n)
	if sm == nil {
		world_fail(w, "attack: mount missing")
		return
	}
	who = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	s := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), who)
	if read != "" {
		fs.scope_read_base(s, "a.txt", transmute([]u8)read)
	}
	fs.mount_observe_begin(sm.m, "a.txt", s)
	_writer_set(w, n, SA_ROOT + "/a.txt", Writer_Info{scope = s, agent = true})
	if err := _sa_write(disk_vfs(&n.disk), SA_ROOT + "/a.txt", data); err != .None {
		world_fail(w, "attack: write: %v", err)
		return
	}
	fs.scope_close(n.reg, s)
	_forget_scope(w, n, s)
	return who, true
}

@(private = "file")
_sa_open_turn :: proc(w: ^World, n: ^Node, read, data: string) -> (who: prim.Id, fd: prim.Fd, ok: bool) {
	sm := _sa_mount(n)
	if sm == nil {
		world_fail(w, "attack: mount missing")
		return
	}
	who = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	s := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), who)
	if read != "" {
		fs.scope_read_base(s, "a.txt", transmute([]u8)read)
	}
	fs.mount_observe_begin(sm.m, "a.txt", s)
	_writer_set(w, n, SA_ROOT + "/a.txt", Writer_Info{scope = s, agent = true})
	vfs := disk_vfs(&n.disk)
	err: prim.Error
	fd, err = prim.open_file(vfs, SA_ROOT + "/a.txt", {.Write, .Create, .Truncate}, 0o644)
	if err == .None {
		err = prim.write_at(vfs, fd, transmute([]u8)data, 0)
	}
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	if err != .None {
		world_fail(w, "attack: open write: %v", err)
		return
	}
	return who, fd, true
}

@(private = "file")
_sa_read :: proc(n: ^Node, tree: eng.Object, line: string) -> string {
	data, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	return string(data)
}

attack_run :: proc(seed: u64, arm: Attack_Arm, crash_at: u64) -> (failures: [dynamic]string, out: Attack_Out) {
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
	out = _attack(w, arm, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	for &l in out.lines {
		l = strings.clone(l)
	}
	for i in 0 ..< out.turns {
		for j in 0 ..< 2 {
			out.undo[i][j] = strings.clone(out.undo[i][j])
			out.redo[i][j] = strings.clone(out.redo[i][j])
		}
	}
	out.disk = strings.clone(out.disk)
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_attack :: proc(w: ^World, arm: Attack_Arm, crash_at: u64) -> (out: Attack_Out) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "attack: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "attack")
		if err != .None {
			world_fail(w, "attack: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "attack: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(SA_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if git_checkout_create(vfs, SA_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)) != .None ||
	   git_branch_commit(vfs, SA_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)) != .None {
		world_fail(w, "attack: git setup")
		return
	}
	if err := node_mount(w, n, oi, SA_ROOT); err != .None {
		world_fail(w, "attack: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SA_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	base: fs.Version
	turns: [4]prim.Id
	count := 0
	started: {
		context = instance_context(&n.inst)
		base, _ = eng.tree_version(&n.e, tree, "main", w.allocator)
	}
	play: {
		context = instance_context(&n.inst)
		ok := true
		switch arm.kind {
		case .Aba:
			turns[0], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			if ok {
				turns[1], ok = _sa_turn(w, n, SA_BASE + SA_X, SA_BASE)
			}
			if ok {
				turns[2], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			}
			count = 3
		case .Twins:
			turns[0], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			if ok {
				turns[1], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			}
			count = 2
		case .Person, .Typed:
			turns[0], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			count = 1
		case .Undone:
			turns[0], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			count = 1
		case .Open:
			fd: prim.Fd
			turns[0], fd, ok = _sa_open_turn(w, n, SA_BASE, SA_BASE + SA_X)
			if ok {
				turns[1], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_Y)
			}
			prim.close_file(vfs, fd)
			count = 2
		case .Merge:
			turns[0], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			if ok {
				turns[1], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_Y)
			}
			count = 2
		case .Chain:
			turns[0], ok = _sa_turn(w, n, SA_BASE, SA_BASE + SA_X)
			if ok {
				_sa_write(vfs, SA_ROOT + "/a.txt", SA_BASE + SA_X + SA_Y)
				turns[1], ok = _sa_turn(w, n, SA_BASE + SA_X + SA_Y, SA_BASE + SA_X + SA_Y + SA_X)
			}
			count = 2
		}
		if !ok {
			return
		}
		node_after(n)
	}
	if arm.kind == .Undone {
		run_until(w, w.now + 2_000_000_000, true)
		undone: {
			context = instance_context(&n.inst)
			owned := make([dynamic]prim.Id, context.temp_allocator)
			append(&owned, turns[0])
			if sm := _sa_mount(n); sm != nil {
				o, _ := fs.history_owned_actors(sm.m.history, turns[:1], context.temp_allocator)
				append(&owned, ..o)
			}
			if _, err := eng.tree_revert_set(&n.e, tree, base, owned[:], "main"); err != .None {
				world_fail(w, "attack: undo before the crash: %v", err)
				return
			}
			node_after(n)
		}
		run_until(w, w.now + 2_000_000_000, true)
		_sa_write(vfs, SA_ROOT + "/a.txt", SA_BASE + SA_Y)
	}
	if arm.kind == .Person {
		_sa_write(vfs, SA_ROOT + "/a.txt", SA_BASE + SA_X + SA_Y)
	} else if arm.kind == .Typed {
		_sa_write(vfs, SA_ROOT + "/a.txt", SA_BASE + SA_X + SA_X)
	}
	crashes := w.stats.crashes
	n.disk.force_process = arm.process
	n.disk.crash_at = n.disk.stats.ops + crash_at
	_sa_write(vfs, SA_ROOT + "/b.txt", "main b\nraised\n")
	if arm.checkout && !n.disk.dead {
		_sa_checkout(w, n, "feature")
	}
	after: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	out.crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "attack: node did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	lines := [2]string{"main", SA_FEATURE}
	for line, i in lines {
		out.lines[i] = _sa_read(n, tree, line)
	}
	d, _ := prim.read_file(vfs, SA_ROOT + "/a.txt", context.temp_allocator)
	out.disk = string(d)
	hd, _ := prim.read_file(vfs, SA_ROOT + "/.git/HEAD", context.temp_allocator)
	out.moved = strings.contains(string(hd), "feature")
	out.turns = count
	for i in 0 ..< count {
		owned := make([dynamic]prim.Id, context.temp_allocator)
		append(&owned, turns[i])
		if sm := _sa_mount(n); sm != nil {
			o, _ := fs.history_owned_actors(sm.m.history, turns[i:i + 1], context.temp_allocator)
			append(&owned, ..o)
		}
		for line, j in lines {
			revert, err := eng.tree_revert_set(&n.e, tree, base, owned[:], line)
			if err != .None {
				world_fail(w, "attack: undo of turn %d on %s: %v", i, line, err)
				return
			}
			out.undo[i][j] = _sa_read(n, tree, line)
			if revert != {} {
				if _, uerr := eng.tree_unrevert(&n.e, tree, revert, line); uerr != .None {
					world_fail(w, "attack: redo of turn %d on %s: %v", i, line, uerr)
					return
				}
			}
			out.redo[i][j] = _sa_read(n, tree, line)
		}
	}
	return
}

@(test)
step_attack :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	if only := env_u64("SA_OP", 0); only != 0 {
		arm := Attack_Arm{kind = Attack_Kind(env_u64("SA_KIND", 0)), checkout = env_u64("SA_CHECKOUT", 0) != 0}
		failures, got := attack_run(1, arm, only)
		fmt.eprintf("step_attack: %v k=%d crashed=%v moved=%v main=%q feature=%q disk=%q undo=%q\n", arm, only, got.crashed, got.moved, got.lines[0], got.lines[1], got.disk, got.undo)
		for f in failures {
			fmt.eprintf("step_attack: %s\n", f)
			delete(f)
		}
		delete(failures)
		return
	}
	for kind in Attack_Kind {
		for checkout in ([]bool{false, true}) {
			for process in ([]bool{false, true}) {
				arm := Attack_Arm{kind = kind, process = process, checkout = checkout}
				_, away := attack_run(1, arm, 1_000_000)
				_, home := attack_run(1, Attack_Arm{kind = kind, process = process}, 1_000_000)
				want := away
				fmt.eprintf("step_attack: %v oracle main=%q feature=%q disk=%q undo=%q redo=%q\n", arm, want.lines[0], want.lines[1], want.disk, want.undo[0][0], want.redo[0][0])
				points, bad := 0, 0
				for k in u64(1) ..= 3000 {
					failures, got := attack_run(1, arm, k)
					wrong := len(failures) > 0
					for f in failures {
						fmt.eprintf("step_attack: %v k=%d: %s\n", arm, k, f)
						delete(f)
					}
					delete(failures)
					if !got.crashed {
						break
					}
					points += 1
					want = away if got.moved == away.moved else home
					for j in 0 ..< 2 {
						if got.lines[j] != want.lines[j] {
							wrong = true
							fmt.eprintf("step_attack: %v k=%d: line %d reads %q, want %q\n", arm, k, j, got.lines[j], want.lines[j])
						}
						for i in 0 ..< want.turns {
							if got.undo[i][j] != want.undo[i][j] || got.redo[i][j] != want.redo[i][j] {
								wrong = true
								fmt.eprintf("step_attack: %v k=%d: turn %d on line %d undoes to %q redoes to %q, want %q and %q\n", arm, k, i, j, got.undo[i][j], got.redo[i][j], want.undo[i][j], want.redo[i][j])
							}
						}
					}
					if wrong {
						bad += 1
					}
				}
				fmt.eprintf("step_attack: %v: points=%d wrong=%d\n", arm, points, bad)
				testing.expect(t, bad == 0, fmt.tprintf("step_attack %v: %d of %d points differ from the run with no crash", arm, bad, points))
			}
		}
	}
}

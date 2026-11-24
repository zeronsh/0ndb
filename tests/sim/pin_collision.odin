package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
PC_A :: "/work/coll-a"

@(private = "file")
PC_B :: "/work/coll-b"

@(private = "file")
PC_ONE :: "one line\n"

@(private = "file")
PC_TWO :: "two line\n"

@(private = "file")
PC_TOOL :: "tool line\n"

Pc_Arm :: struct {
	pin:    Pc_Pin,
	loser:  bool,
	kind:   Pc_Kind,
}

Pc_Kind :: enum u8 {
	Collide,
	Second_Write,
	Both_Texts,
	Nested,
}

@(private = "file")
PC_AGAIN :: "again line\n"

Pc_Pin :: enum u8 {
	None,
	Read,
	Hold,
}

@(private = "file")
_pc_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

pin_collision_run :: proc(seed: u64, arm: Pc_Arm) -> (failures: [dynamic]string, collided: bool) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
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
	collided = _pin_collision(w, arm)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_pc_step :: proc(w: ^World, ns: i64) {
	run_until(w, w.now + ns, true)
}

@(private = "file")
_pc_cut :: proc(w: ^World, cut: bool) {
	for n in w.nodes {
		n.partitioned = cut
		if cut {
			for c in n.conns {
				conn_reset(c, true)
			}
		}
	}
}

@(private = "file")
_pc_all :: proc(n: ^Node, tree: eng.Object) -> (text: string, files: string) {
	b := strings.builder_make(context.temp_allocator)
	f := strings.builder_make(context.temp_allocator)
	names, _ := tree_walk(n, tree, {}, "")
	for nm in names {
		d, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator)
		strings.write_string(&b, string(d))
		fmt.sbprintf(&f, "%s=%q ", nm, string(d))
	}
	return strings.to_string(b), strings.to_string(f)
}

@(private = "file")
_pc_check :: proc(w: ^World, n: ^Node, tree: eng.Object, root: string, arm: Pc_Arm, when_: string, tool: int) {
	text, files := _pc_all(n, tree)
	for line in ([]string{PC_ONE, PC_TWO, PC_TOOL, PC_AGAIN}) {
		want := tool if line == PC_TOOL else 1 if line == PC_ONE || line == PC_TWO else tool if arm.kind == .Second_Write else 0
		c := strings.count(text, line)
		if arm.kind == .Both_Texts && line == PC_TWO && c >= 1 {
			continue
		}
		if c != want {
			world_fail(w, "pin collision %v: %s on %s: %q appears %d times, want %d (%s)", arm, when_, n.name, strings.trim_space(line), c, want, files)
		}
	}
	names, _ := tree_walk(n, tree, {}, "")
	for nm in names {
		d, _ := eng.tree_read(&n.e, tree, nm, context.temp_allocator)
		n.disk.probe += 1
		got, gerr := prim.read_file(disk_vfs(&n.disk), strings.concatenate({root, "/", nm}, context.temp_allocator), context.temp_allocator)
		n.disk.probe -= 1
		if gerr != .None || string(got) != string(d) {
			world_fail(w, "pin collision %v: %s on %s: %s on disk is %q (%v), in the tree %q", arm, when_, n.name, nm, string(got), gerr, string(d))
		}
	}
}

@(private = "file")
_pin_collision :: proc(w: ^World, arm: Pc_Arm) -> (collided: bool) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	tree: eng.Object
	space: prim.Id
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "coll", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "pin collision: space: %v", err)
			return
		}
		space = id
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "pin collision: member_add: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "pin collision: tree_create: %v", err)
			return
		}
	}
	defer delete(proof, w.allocator)
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "coll", "relay", w.relay.public); err != .None {
			world_fail(w, "pin collision: join: %v", err)
			return
		}
		eng.space_open(&b.e, space)
	}
	_pc_step(w, 10_000_000_000)
	cop := new_op(&w.model, .Create, a, len(w.model.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&w.model.objs, ob)
	if err := node_mount(w, a, 0, PC_A); err != .None {
		world_fail(w, "pin collision: mount a: %v", err)
		return
	}
	_pc_step(w, 5_000_000_000)
	if err := node_mount(w, b, 0, PC_B); err != .None {
		world_fail(w, "pin collision: mount b: %v", err)
		return
	}
	_pc_step(w, 5_000_000_000)
	_pc_cut(w, true)
	_pc_step(w, 2_000_000_000)
	first, other := a, b
	froot, oroot := PC_A, PC_B
	join: {
		context = instance_context(&first.inst)
		defer node_after(first)
		if arm.kind == .Nested {
			prim.mkdir_all(disk_vfs(&first.disk), strings.concatenate({froot, "/d"}, context.temp_allocator), 0o755)
		}
		_pc_write(disk_vfs(&first.disk), strings.concatenate({froot, "/d/a.txt" if arm.kind == .Nested else "/a.txt"}, context.temp_allocator), PC_ONE)
	}
	_pc_step(w, 2_000_000_000)
	{
		context = instance_context(&other.inst)
		defer node_after(other)
		if arm.kind == .Nested {
			prim.mkdir_all(disk_vfs(&other.disk), strings.concatenate({oroot, "/d"}, context.temp_allocator), 0o755)
		}
		_pc_write(disk_vfs(&other.disk), strings.concatenate({oroot, "/d/a.txt" if arm.kind == .Nested else "/a.txt"}, context.temp_allocator), PC_TWO)
	}
	_pc_step(w, 2_000_000_000)
	n, mine, root := b, PC_TWO, PC_B
	path := "d/a.txt" if arm.kind == .Nested else "a.txt"
	if arm.loser {
		n, mine, root = a, PC_ONE, PC_A
	}
	sm: ^Sim_Mount
	scope: ^fs.Scope
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		for &x in n.mounts {
			if x.root == root {
				sm = &x
			}
		}
		if sm == nil || sm.m == nil {
			world_fail(w, "pin collision: no mount on %s", n.name)
			return
		}
		scope = fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		#partial switch arm.pin {
		case .Read:
			fs.scope_read_base(scope, path, transmute([]u8)mine)
		case .Hold:
			fs.scope_write_begin(scope, path)
		}
		if arm.pin != .None && !fs.scope_pinned(scope, path) {
			world_fail(w, "pin collision: the agent pinned nothing on %s", n.name)
			return
		}
	}
	_pc_cut(w, false)
	_pc_step(w, 20_000_000_000)
	{
		context = instance_context(&n.inst)
		names, _ := eng.tree_list(&n.e, tree, "", context.temp_allocator)
		collided = len(names) >= 2 || arm.kind == .Nested
		if !collided {
			world_fail(w, "pin collision: no collision on %s (%v), so the check proves nothing", n.name, names)
			node_after(n)
			return
		}
		abs := strings.concatenate({root, "/", path}, context.temp_allocator)
		_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
		fs.mount_observe_begin(sm.m, path, scope)
		_pc_write(disk_vfs(&n.disk), abs, strings.concatenate({mine, PC_TWO if arm.kind == .Both_Texts else "", PC_TOOL}, context.temp_allocator))
		if arm.pin == .Hold {
			fs.scope_write_base(scope, path, transmute([]u8)mine)
			fs.scope_write_end(scope, path)
		}
		fs.scope_close(n.reg, scope)
		_forget_scope(w, n, scope)
		node_after(n)
	}
	if arm.kind == .Second_Write {
		_pc_step(w, 20_000_000_000)
		context = instance_context(&n.inst)
		abs := strings.concatenate({root, "/", path}, context.temp_allocator)
		again := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		n.disk.probe += 1
		now, _ := prim.read_file(disk_vfs(&n.disk), abs, context.temp_allocator)
		n.disk.probe -= 1
		fs.scope_read_base(again, path, now)
		_writer_set(w, n, abs, Writer_Info{scope = again, agent = true})
		fs.mount_observe_begin(sm.m, path, again)
		_pc_write(disk_vfs(&n.disk), abs, strings.concatenate({string(now), PC_AGAIN}, context.temp_allocator))
		fs.scope_close(n.reg, again)
		_forget_scope(w, n, again)
		node_after(n)
	}
	_pc_step(w, 30_000_000_000)
	for x in ([]^Node{a, b}) {
		context = instance_context(&x.inst)
		defer node_after(x)
		_pc_check(w, x, tree, PC_A if x == a else PC_B, arm, "after the write", 1)
	}
	if len(w.failures) > 0 {
		return
	}
	act: {
		context = instance_context(&n.inst)
		defer node_after(n)
		if _, uerr := eng.tree_revert_set(&n.e, tree, nil, []prim.Id{agent}); uerr != .None {
			world_fail(w, "pin collision %v: undo: %v", arm, uerr)
		}
	}
	_pc_step(w, 30_000_000_000)
	for x in ([]^Node{a, b}) {
		context = instance_context(&x.inst)
		defer node_after(x)
		_pc_check(w, x, tree, PC_A if x == a else PC_B, arm, "after the undo", 0)
	}
	return
}

@(test)
pin_collision :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for kind in Pc_Kind {
		for pin in Pc_Pin {
			for loser in ([]bool{false, true}) {
				if pin == .None && loser || kind != .Collide && (pin == .None || !loser) {
					continue
				}
				arm := Pc_Arm{pin, loser, kind}
				failures, collided := pin_collision_run(1, arm)
				for f in failures {
					fmt.eprintf("pin_collision: %s\n", f)
					delete(f)
				}
				fmt.eprintf("pin_collision: %v collided=%v failures=%d\n", arm, collided, len(failures))
				testing.expect(t, len(failures) == 0, fmt.tprintf("pin_collision %v failed", arm))
				delete(failures)
		}
	}
	}
}

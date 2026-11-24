package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
LATE_CARRY_ROOT :: "/work/carry-late-git"

@(private = "file")
LATE_CARRY_FEATURE :: "git:refs/heads/feature"

@(private = "file")
LATE_CARRY_TEXT :: "from the third device\n"

@(private = "file")
Late_Carry_World :: struct {
	node: int,
	drop: osync.Stream_Id,
	on:   bool,
	hits: int,
}

@(private = "file")
_late_carry: ^Late_Carry_World

@(init)
_carry_late_init :: proc "contextless" () {
	register_world(67, _late_carry_init, _late_carry_destroy)
	register_frame_filter(13, _late_carry_filter)
}

@(private = "file")
_late_carry_init :: proc(w: ^World) {
	_late_carry = new(Late_Carry_World, w.allocator)
	_late_carry.node = -1
}

@(private = "file")
_late_carry_destroy :: proc(w: ^World) {
	if _late_carry == nil {
		return
	}
	frame_filter_enable(false)
	free(_late_carry, w.allocator)
	_late_carry = nil
}

@(private = "file")
_late_carry_filter :: proc(w: ^World, c: ^Conn, kind: u8, payload: []u8) -> bool {
	if _late_carry == nil || !_late_carry.on || c.node.idx != _late_carry.node || kind != 0x85 || len(payload) < 32 {
		return false
	}
	x := _late_carry.drop
	if string(payload[:32]) != string(x[:]) {
		return false
	}
	_late_carry.hits += 1
	return true
}

carry_late_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 3
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
	_carry_late(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_late_carry_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == LATE_CARRY_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_late_carry_read :: proc(n: ^Node, tree: eng.Object, line: string) -> (string, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, line)
	if err != .None {
		return fmt.aprintf("<%v>", err, allocator = n.w.allocator), false
	}
	return strings.clone(string(data), n.w.allocator), true
}

@(private = "file")
_late_carry_blame :: proc(n: ^Node, tree: eng.Object) -> string {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, spans, err := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, "main")
	if err != .None {
		return fmt.aprintf("error %v", err, allocator = n.w.allocator)
	}
	b := strings.builder_make(n.w.allocator)
	strings.write_string(&b, string(data))
	for sp in spans {
		fmt.sbprintf(&b, "|%s %d", id_short(sp.id.actor), sp.len)
	}
	return strings.to_string(b)
}

@(private = "file")
_carry_late :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b, c := w.nodes[0], w.nodes[1], w.nodes[2]
	for n in ([]^Node{a, b, c}) {
		if !node_start(n) {
			world_fail(w, "node start")
			return
		}
	}
	m := &w.model
	vfs := disk_vfs(&a.disk)
	space: prim.Id
	tree: eng.Object
	proofs: [2][]u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		id, err := eng.space_create(&a.e, "late", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "carry late: space setup: %v", err)
			return
		}
		space = id
		for n, i in ([]^Node{b, c}) {
			p, perr := eng.member_add(&a.e, space, n.identity, .Device, .Admin, .Approval, 0, w.allocator)
			if perr != .None {
				world_fail(w, "carry late: member_add: %v", perr)
				return
			}
			proofs[i] = p
		}
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "carry late: tree_create: %v", err)
			return
		}
	}
	for n, i in ([]^Node{b, c}) {
		context = instance_context(&n.inst)
		if _, jerr := eng.space_join_enrollment(&n.e, space, proofs[i], "late", "relay", w.relay.public); jerr != .None {
			world_fail(w, "carry late: join: %v", jerr)
			node_after(n)
			return
		}
		eng.space_open(&n.e, space)
		node_after(n)
	}
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("shared a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	when_s := clock_wall(&a.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, LATE_CARRY_ROOT, files[:], when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry late: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}}
	if err := git_branch_commit(vfs, LATE_CARRY_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry late: branch commit: %v", err)
		return
	}
	if err := node_mount(w, a, oi, LATE_CARRY_ROOT); err != .None {
		world_fail(w, "carry late: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = a.idx, oi = oi, root = strings.clone(LATE_CARRY_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, LATE_CARRY_ROOT, "feature", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "carry late: checkout feature: %v %v", res, err)
		return
	}
	tick: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	seen := false
	for _ in 0 ..< 30 {
		if d, rok := _late_carry_read(b, tree, LATE_CARRY_FEATURE); rok && len(d) > 0 {
			seen = true
			break
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	if !seen {
		world_fail(w, "carry late: the reader never read the tree, so the check proves nothing")
		return
	}
	ids: {
		name := osync.object_segment_name(u8(eng.Kind.File_Tree), tree.id, context.temp_allocator)
		sp, sok := b.e.spaces[space]
		if !sok {
			world_fail(w, "carry late: the reader has no space")
			return
		}
		found := false
		for _, rm in sp.repl.remotes {
			if rm.name == name && rm.device == a.identity.id {
				_late_carry.drop = osync.stream_id(&rm.scope, c.identity.id, name, 0)
				found = true
				break
			}
		}
		if !found {
			world_fail(w, "carry late: the reader has no remote for the mount's segment of the tree")
			return
		}
	}
	_late_carry.node = b.idx
	_late_carry.on = true
	frame_filter_enable(true)
	written := false
	for _ in 0 ..< 20 {
		context = instance_context(&c.inst)
		base: fs.Version
		cur, rerr := eng.tree_read(&c.e, tree, "a.txt", context.temp_allocator, {}, LATE_CARRY_FEATURE, nil, &base)
		if rerr == .None && string(cur) == "shared a\n" {
			next := strings.concatenate({string(cur), LATE_CARRY_TEXT}, context.temp_allocator)
			if werr := eng.tree_write(&c.e, tree, "a.txt", transmute([]u8)next, base, LATE_CARRY_FEATURE); werr == .None {
				written = true
			}
		}
		node_after(c)
		if written {
			break
		}
		run_until(w, w.now + 1_000_000_000, true)
	}
	if !written {
		world_fail(w, "carry late: the third device never wrote a.txt on feature, so the check proves nothing")
		return
	}
	on_disk := false
	for _ in 0 ..< 30 {
		run_until(w, w.now + 1_000_000_000, true)
		if d, _ := prim.read_file(vfs, LATE_CARRY_ROOT + "/a.txt", context.temp_allocator); strings.contains(string(d), LATE_CARRY_TEXT) {
			on_disk = true
			break
		}
	}
	if !on_disk {
		world_fail(w, "carry late: the third device's feature write never reached the mount's disk")
		return
	}
	back := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, LATE_CARRY_ROOT, "main", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &back); res != .Done || err != .None {
		world_fail(w, "carry late: checkout main: %v %v", res, err)
		return
	}
	step: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 20_000_000_000, true)
	main_a, ok := _late_carry_read(a, tree, "main")
	if !ok || !strings.contains(main_a, LATE_CARRY_TEXT) {
		world_fail(w, "carry late: git did not carry the third device's line onto main on the mount (%q), so the check proves nothing", main_a)
		return
	}
	if _late_carry.hits == 0 {
		world_fail(w, "carry late: no frame of the source stream was withheld, so the check proves nothing")
		return
	}
	if d, rok := _late_carry_read(b, tree, LATE_CARRY_FEATURE); rok && strings.contains(d, LATE_CARRY_TEXT) {
		world_fail(w, "carry late: the reader already holds the source on feature (%q), so the check proves nothing", d)
		return
	}
	early := _late_carry_blame(a, tree)
	credit := fmt.aprintf("|%s %d", id_short(c.identity.id), len(LATE_CARRY_TEXT), allocator = w.allocator)
	if !strings.contains(early, credit) {
		world_fail(w, "carry late: the mount's main a.txt %q does not credit the third device with its line (%q)", early, credit)
	}
	if got := _late_carry_blame(b, tree); got != early {
		world_fail(w, "carry late: without the source stream the reader's main a.txt is %q, the mount's %q", got, early)
	}
	_late_carry.on = false
	for cn in b.conns {
		conn_reset(cn, true)
	}
	run_until(w, w.now + 30_000_000_000, true)
	want := _late_carry_blame(a, tree)
	if got := _late_carry_blame(b, tree); got != want {
		world_fail(w, "carry late: after the carry's source arrived the reader's main a.txt is %q, the mount's %q", got, want)
	}
	redact: {
		context = instance_context(&a.inst)
		defer node_after(a)
		sm := _late_carry_mount(a)
		if sm == nil {
			world_fail(w, "carry late: mount missing")
			return
		}
		v, found, verr := fs.history_line(sm.m.history, LATE_CARRY_FEATURE, context.temp_allocator)
		if verr != .None || !found {
			world_fail(w, "carry late: feature line version: %v %v", verr, found)
			return
		}
		from := len("shared a\n")
		if _, rerr := fs.mount_redact_range(sm.m, "a.txt", v, from, from + len(LATE_CARRY_TEXT), context.temp_allocator); rerr != .None {
			world_fail(w, "carry late: redact the copied source: %v", rerr)
			return
		}
		eng.tree_unmount(&a.e, sm.m)
		for x, i in a.mounts {
			if x.root == LATE_CARRY_ROOT {
				ordered_remove(&a.mounts, i)
				break
			}
		}
		for x, i in m.mounts {
			if x.node == a.idx && x.root == LATE_CARRY_ROOT {
				ordered_remove(&m.mounts, i)
				break
			}
		}
	}
	run_until(w, w.now + 30_000_000_000, true)
	redacted := strings.concatenate({"shared a\n", strings.repeat("\x00", len(LATE_CARRY_TEXT), context.temp_allocator)}, context.temp_allocator)
	for n in ([]^Node{a, b, c}) {
		for line in ([]string{"", "main", LATE_CARRY_FEATURE}) {
			d, rok := _late_carry_read(n, tree, line)
			if strings.contains(d, LATE_CARRY_TEXT) {
				world_fail(w, "carry late: %s still reads the redacted source's bytes on %q: %q", n.name, line, d)
			} else if line != "" && (!rok || d != redacted) {
				world_fail(w, "carry late: %s reads a.txt on %q as %q (%v), want the carried range zero-filled in place", n.name, line, d, rok)
			}
		}
	}
}

@(test)
carry_late :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := carry_late_run(1)
	for f in failures {
		fmt.eprintf("carry_late: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "carry_late failed")
	delete(failures)
}

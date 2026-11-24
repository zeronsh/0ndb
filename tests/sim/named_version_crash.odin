package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fshist"
import "../../src/prim"

@(private = "file")
NV_ROOT :: "/work/named-n0-git"

@(private = "file")
NV_FEATURE :: "git:refs/heads/feature"

@(private = "file")
NV_BASE :: "base line\n"

@(private = "file")
NV_KEPT :: "kept line\n"

@(private = "file")
NV_TOOL :: "tool line\n"

Named_Kind :: enum u8 {
	Plain,
	Checkout_New,
	Checkout_Existing,
	Line_Switch,
}

Named_Arm :: struct {
	kind:    Named_Kind,
	process: bool,
	early:   bool,
	control: bool,
	clean:   bool,
	edit:    bool,
}

@(private = "file")
NV_EDIT :: "edit line\n"

@(private = "file")
NV_OTHER :: "other line\n"

Named_Result :: struct {
	crashed: bool,
	named:   bool,
	ahead:   bool,
	settled: bool,
	edited:  bool,
	wrong:   bool,
	awake:   bool,
	line:    string,
	kept_lost:  bool,
	other_lost: bool,
	undone:     int,
}

named_version_run :: proc(seed: u64, arm: Named_Arm, crash_at: u64) -> (failures: [dynamic]string, res: Named_Result) {
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
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	res = _named_crash(w, arm, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_nv_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == NV_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_nv_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_nv_checkout :: proc(w: ^World, n: ^Node, branch: string) -> bool {
	changes := make([dynamic]Git_Change, context.temp_allocator)
	res, err := git_checkout(disk_vfs(&n.disk), NV_ROOT, branch, false, clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng), &changes)
	return res == .Done && err == .None
}

@(private = "file")
_named_crash :: proc(w: ^World, arm: Named_Arm, crash_at: u64) -> (res: Named_Result) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "named: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "named")
		if err != .None {
			world_fail(w, "named: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "named: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(NV_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, NV_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "named: git checkout: %v", err)
		return
	}
	branch_files := [?]Git_File{{name = "c.txt", data = transmute([]u8)string("feature c\n")}}
	if err := git_branch_commit(vfs, NV_ROOT, "feature", branch_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "named: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, NV_ROOT); err != .None {
		world_fail(w, "named: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(NV_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	kind := arm.kind
	if kind == .Checkout_Existing {
		for b in ([]string{"feature", "main"}) {
			if !_nv_checkout(w, n, b) {
				world_fail(w, "named: round trip to %s", b)
				return
			}
			trip: {
				context = instance_context(&n.inst)
				node_after(n)
			}
			run_until(w, w.now + 2_000_000_000, true)
		}
		other: {
			context = instance_context(&n.inst)
			fbase, _ := eng.tree_version(&n.e, tree, NV_FEATURE, context.temp_allocator)
			if err := eng.tree_write(&n.e, tree, "a.txt", transmute([]u8)string(NV_BASE + NV_OTHER), fbase, NV_FEATURE); err != .None {
				world_fail(w, "named: tree_write on feature: %v", err)
				return
			}
			node_after(n)
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	pseudo := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	owner := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	agent: prim.Id
	before, before_feature: []u8
	holder := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	pin: {
		context = instance_context(&n.inst)
		sm := _nv_mount(n)
		if sm == nil {
			world_fail(w, "named: mount missing")
			return
		}
		agent = fshist.ingestion_actor(sm.m.history.self, pseudo)
		if err := fs.history_register_owned_actor(sm.m.history, agent, pseudo, owner); err != .None {
			world_fail(w, "named: register the agent: %v", err)
			return
		}
		before = _nv_version(w, n, tree, "main")
		before_feature = _nv_version(w, n, tree, NV_FEATURE)
		if !arm.control {
			hold := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), holder)
			fs.scope_write_begin(hold, "a.txt")
		}
		reader := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		fs.scope_read_base(reader, "a.txt", transmute([]u8)string(NV_BASE))
		if !fs.scope_pinned(reader, "a.txt") {
			world_fail(w, "named: the reader did not pin a.txt")
			return
		}
		if !arm.control {
			other := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
			fs.mount_observe_begin(sm.m, "a.txt", other)
			_writer_set(w, n, NV_ROOT + "/a.txt", Writer_Info{scope = other, agent = true})
			if err := _nv_write(vfs, NV_ROOT + "/a.txt", NV_BASE + NV_KEPT); err != .None {
				world_fail(w, "named: other scope's write: %v", err)
				return
			}
			fs.scope_close(n.reg, other)
			_forget_scope(w, n, other)
		}
		if arm.clean {
			fs.scope_close(n.reg, reader)
			break pin
		}
		fs.mount_observe_begin(sm.m, "a.txt", reader)
		_writer_set(w, n, NV_ROOT + "/a.txt", Writer_Info{scope = reader, agent = true})
		if err := _nv_write(vfs, NV_ROOT + "/a.txt", NV_BASE + NV_TOOL); err != .None {
			world_fail(w, "named: agent write: %v", err)
			return
		}
		fs.scope_close(n.reg, reader)
		_forget_scope(w, n, reader)
		res.named = _nv_named(n)
		node_after(n)
	}
	if !arm.early {
		run_until(w, w.now + 2_000_000_000, true)
	}
	seen: {
		context = instance_context(&n.inst)
		n.disk.probe += 1
		disk, _ := prim.read_file(vfs, NV_ROOT + "/a.txt", context.temp_allocator)
		n.disk.probe -= 1
		line, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
		res.settled = eng.durable_seq(&n.e) + 1 >= eng.pending_seq(&n.e) && strings.contains(string(line), NV_TOOL) && (arm.control || strings.contains(string(line), NV_KEPT))
		res.ahead = strings.contains(string(line), NV_KEPT) && strings.contains(string(line), NV_TOOL) && !strings.contains(string(disk), NV_KEPT)
	}
	crashes := w.stats.crashes
	n.disk.force_process = arm.process
	n.disk.crash_at = n.disk.stats.ops + crash_at
	_nv_write(vfs, NV_ROOT + "/b.txt", "main b\nraised\n")
	if !n.disk.dead {
		switch kind {
		case .Plain:
		case .Checkout_New, .Checkout_Existing:
			_nv_checkout(w, n, "feature")
		case .Line_Switch:
			context = instance_context(&n.inst)
			if sm := _nv_mount(n); sm != nil {
				fs.mount_line_switch(sm.m, NV_FEATURE)
			}
		}
	}
	after: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	if arm.edit {
		for limit := w.now + 20_000_000_000; w.now < limit && !res.edited; {
			t, ok := next_time(w)
			if !ok {
				break
			}
			run_until(w, t, false)
			if (w.stats.crashes > crashes || n.disk.crash_at > n.disk.stats.ops + 3000) && n.alive && n.e_open {
				res.edited, res.wrong, res.line = _nv_edit(w, n)
			}
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	n.disk.force_process = false
	res.crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "named: node did not come back")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	data, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
	if rerr != .None {
		world_fail(w, "named: tree_read: %v", rerr)
		return
	}
	on := "main"
	if sm := _nv_mount(n); sm != nil {
		l := fs.mount_line(sm.m)
		on = strings.clone("main" if l == "git:refs/heads/main" else l, context.temp_allocator)
	}
	disk_text := data
	if on != "main" {
		disk_text, _ = eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, on)
	}
	tools, tools_on := strings.count(string(data), NV_TOOL), strings.count(string(disk_text), NV_TOOL)
	for line in ([]string{NV_BASE, NV_KEPT, NV_TOOL}) {
		want := 0 if (arm.control && line == NV_KEPT) || (arm.clean && line == NV_TOOL) else 1
		c := strings.count(string(data), line)
		if arm.early && res.crashed && want == 1 {
			if line == NV_KEPT {
				res.kept_lost = c == 0
				want = c if c <= 1 else 1
			} else if line == NV_TOOL {
				if tools > 1 || tools_on > 1 || tools + tools_on == 0 {
					world_fail(w, "named: %v: the agent's line appears %d times on main (%q) and %d times on %s, the disk's line (%q), want once on either, at disk op %d", arm, tools, string(data), tools_on, on, string(disk_text), crash_at)
				}
				continue
			}
		}
		if want == 1 && line != NV_BASE && !arm.early && !res.settled {
			continue
		}
		if c != want {
			world_fail(w, "named: %v: %q appears %d times in a.txt on main, want %d (%q), at disk op %d", arm, strings.trim_space(line), c, want, string(data), crash_at)
		}
	}
	if sm := _nv_mount(n); sm != nil {
		res.awake = sm.m.awake
	}
	if res.edited {
		held := "main" if res.line == "git:refs/heads/main" else res.line
		edata, eerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, held)
		if c := strings.count(string(edata), NV_EDIT); eerr != .None || c != 1 {
			world_fail(w, "named: %v: %q appears %d times in a.txt on %s, the line the mount held (%v %q), at disk op %d", arm, strings.trim_space(NV_EDIT), c, held, eerr, string(edata), crash_at)
		}
		if c := strings.count(string(edata), NV_TOOL); c != 1 {
			world_fail(w, "named: %v: %q appears %d times in a.txt on %s after an edit (%q), at disk op %d", arm, strings.trim_space(NV_TOOL), c, held, string(edata), crash_at)
		}
	}
	if kind == .Checkout_Existing {
		fdata, ferr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, NV_FEATURE)
		if c := strings.count(string(fdata), NV_OTHER); ferr != .None || c != 1 {
			res.other_lost = true
		}
	}
	if arm.clean || len(w.failures) > 0 {
		return
	}
	set: []prim.Id
	if sm := _nv_mount(n); sm != nil {
		oa, oerr := fs.history_owned_actors(sm.m.history, []prim.Id{owner}, context.temp_allocator)
		if oerr != .None {
			world_fail(w, "named: owned actors: %v", oerr)
			return
		}
		set = oa
	}
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "main")
	if on != "main" {
		append(&lines, on)
	}
	for l in lines {
		was, werr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, l)
		if werr != .None || !strings.contains(string(was), NV_TOOL) {
			continue
		}
		at := before_feature if l == NV_FEATURE && len(before_feature) > 0 else before
		base, derr := fs.decode_version(at, context.temp_allocator)
		if derr != .None {
			world_fail(w, "named: decode the version before the turn: %v", derr)
			return
		}
		if _, uerr := eng.tree_revert_set(&n.e, tree, base, set, l); uerr != .None {
			world_fail(w, "named: %v: undo on %s: %v, at disk op %d", arm, l, uerr, crash_at)
			return
		}
		now, nerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, l)
		want, _ := strings.replace_all(string(was), NV_TOOL, "", context.temp_allocator)
		if nerr != .None || string(now) != want {
			world_fail(w, "named: %v: the turn's undo on %s left %q (%v), want %q, at disk op %d", arm, l, string(now), nerr, want, crash_at)
			return
		}
		res.undone += 1
	}
	return
}

@(private = "file")
_nv_version :: proc(w: ^World, n: ^Node, tree: eng.Object, line: string) -> []u8 {
	v, err := eng.tree_version(&n.e, tree, line, context.temp_allocator)
	if err != .None {
		return nil
	}
	b := make([dynamic]u8, w.allocator)
	fs.encode_version(&b, v)
	return b[:]
}

@(private = "file")
_nv_edit :: proc(w: ^World, n: ^Node) -> (edited: bool, wrong: bool, line: string) {
	context = instance_context(&n.inst)
	sm := _nv_mount(n)
	if sm == nil || !sm.m.awake || !fs.shadow_attached(&sm.m.shadow) {
		return
	}
	vfs := disk_vfs(&n.disk)
	n.disk.probe += 1
	have, rerr := prim.read_file(vfs, NV_ROOT + "/a.txt", context.temp_allocator)
	n.disk.probe -= 1
	if rerr != .None || strings.contains(string(have), NV_KEPT) || !strings.contains(string(have), NV_TOOL) {
		return
	}
	out := make([dynamic]string, context.temp_allocator)
	n.disk.quiet = true
	err := fs.mount_synced_mismatches(sm.m, &out, context.temp_allocator)
	n.disk.quiet = false
	if err != .None {
		return
	}
	for x in out {
		wrong ||= strings.has_prefix(x, "a.txt: disk")
	}
	line = strings.clone(fs.mount_line(sm.m), w.allocator)
	edited = _nv_write(vfs, NV_ROOT + "/a.txt", strings.concatenate({string(have), NV_EDIT}, context.temp_allocator)) == .None
	node_after(n)
	return
}

@(private = "file")
_nv_named :: proc(n: ^Node) -> bool {
	sm := _nv_mount(n)
	if sm == nil || !fs.shadow_attached(&sm.m.shadow) {
		return false
	}
	e, found, err := fs.shadow_get(&sm.m.shadow, "a.txt")
	return err == .None && found && e.ver != 0
}

@(test)
named_version_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for kind in Named_Kind {
		for bits in 0 ..< 10 {
			arm := Named_Arm{kind = kind, process = bits & 1 != 0, early = bits & 2 != 0, control = bits >= 4, clean = bits >= 8}
			points, named, ahead, settled, bad := 0, 0, 0, 0, 0
			undone, kept_lost, other_lost := 0, 0, 0
			for k in u64(1) ..= 4000 {
				failures, res := named_version_run(1, arm, k)
				if len(failures) > 0 {
					bad += 1
				}
				for f in failures {
					fmt.eprintf("named_version_crash: %s\n", f)
					delete(f)
				}
				testing.expect(t, len(failures) == 0, fmt.tprintf("named_version_crash %v at disk op %d failed", arm, k))
				delete(failures)
				named += 1 if res.named else 0
				ahead += 1 if res.ahead else 0
				settled += 1 if res.settled else 0
				undone += res.undone
				kept_lost += 1 if res.kept_lost else 0
				other_lost += 1 if res.other_lost else 0
				if !res.crashed {
					break
				}
				points += 1
			}
			fmt.eprintf("named_version_crash: %v process=%v early=%v control=%v clean=%v: points=%d named=%d ahead=%d settled=%d undone=%d kept_lost=%d other_lost=%d failed=%d\n", kind, arm.process, arm.early, arm.control, arm.clean, points, named, ahead, settled, undone, kept_lost, other_lost, bad)
			testing.expect(t, arm.clean || undone > 0, fmt.tprintf("named_version_crash %v: no run undid the turn", arm))
			testing.expect(t, arm.control || named > 0, fmt.tprintf("named_version_crash %v: no run had a named version in flight", arm))
		}
	}
	for kind in Named_Kind {
		for process in ([]bool{false, true}) {
			arm := Named_Arm{kind = kind, process = process, edit = true}
			points, named, edited, wrong, awake, bad := 0, 0, 0, 0, 0, 0
			for k in u64(1) ..= 4000 {
				failures, res := named_version_run(1, arm, k)
				lost := false
				for f in failures {
					lost ||= strings.contains(f, "appears") && !strings.contains(f, "other line")
					fmt.eprintf("named_version_crash: %s\n", f)
					delete(f)
				}
				bad += 1 if lost else 0
				delete(failures)
				named += 1 if res.named else 0
				edited += 1 if res.edited else 0
				wrong += 1 if res.wrong else 0
				awake += 1 if res.awake else 0
				if !res.crashed {
					break
				}
				points += 1
			}
			fmt.eprintf("named_version_crash: edit %v process=%v: points=%d named=%d edited=%d while_wrong=%d text_wrong=%d awake_at_end=%d\n", kind, process, points, named, edited, wrong, bad, awake)
			testing.expect(t, edited > 0, "named_version_crash: no run edited the disk's text")
			testing.expect(t, bad == 0 || kind == .Line_Switch, "named_version_crash: an edit after recovery lost or doubled text")
		}
	}
}

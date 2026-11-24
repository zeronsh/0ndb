package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
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
	fork_check: bool,
	two: bool,
}

@(private = "file")
NV_D_BASE :: "d base\n"

@(private = "file")
NV_D_TOOL :: "d tool line\n"

@(private = "file")
NV_D_KEPT :: "d kept line\n"

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
	forked:  bool,
	line:    string,
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
	two_files := [?]Git_File{files[0], files[1], {name = "d.txt", data = transmute([]u8)string(NV_D_BASE)}}
	if err := git_checkout_create(vfs, NV_ROOT, two_files[:] if arm.two else files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
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
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	holder := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	keeper := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	pin: {
		context = instance_context(&n.inst)
		sm := _nv_mount(n)
		if sm == nil {
			world_fail(w, "named: mount missing")
			return
		}
		if !arm.control {
			hold := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), holder)
			fs.scope_write_begin(hold, "a.txt")
			if arm.two {
				fs.scope_write_begin(hold, "d.txt")
			}
		}
		reader := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		fs.scope_read_base(reader, "a.txt", transmute([]u8)string(NV_BASE))
		if !fs.scope_pinned(reader, "a.txt") {
			world_fail(w, "named: the reader did not pin a.txt")
			return
		}
		if arm.two {
			first := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
			fs.scope_read_base(first, "d.txt", transmute([]u8)string(NV_D_BASE))
			second := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), keeper)
			fs.mount_observe_begin(sm.m, "d.txt", second)
			_writer_set(w, n, NV_ROOT + "/d.txt", Writer_Info{scope = second, agent = true})
			if err := _nv_write(vfs, NV_ROOT + "/d.txt", NV_D_BASE + NV_D_KEPT); err != .None {
				world_fail(w, "named: keeper write to d.txt: %v", err)
				return
			}
			fs.scope_close(n.reg, second)
			_forget_scope(w, n, second)
			fs.mount_observe_begin(sm.m, "d.txt", first)
			_writer_set(w, n, NV_ROOT + "/d.txt", Writer_Info{scope = first, agent = true})
			if err := _nv_write(vfs, NV_ROOT + "/d.txt", NV_D_BASE + NV_D_TOOL); err != .None {
				world_fail(w, "named: agent write to d.txt: %v", err)
				return
			}
			fs.scope_close(n.reg, first)
			_forget_scope(w, n, first)
			de, dfound, _ := fs.shadow_get(&sm.m.shadow, "d.txt")
			if !dfound || de.ver == 0 {
				world_fail(w, "named: d.txt's entry names no version, so the two-file arm proves nothing")
				return
			}
		}
		if !arm.control {
			other := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), keeper)
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
	for line in ([]string{NV_BASE, NV_KEPT, NV_TOOL}) {
		want := 0 if (arm.control && line == NV_KEPT) || (arm.clean && line == NV_TOOL) else 1
		if want == 1 && line != NV_BASE && !res.settled {
			continue
		}
		if c := strings.count(string(data), line); c != want {
			world_fail(w, "named: %v: %q appears %d times in a.txt on main, want %d (%q), at disk op %d", arm, strings.trim_space(line), c, want, string(data), crash_at)
		}
	}
	if sm := _nv_mount(n); sm != nil {
		res.awake = sm.m.awake
	}
	if res.edited {
		on := "main" if res.line == "git:refs/heads/main" else res.line
		edata, eerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, on)
		if c := strings.count(string(edata), NV_EDIT); eerr != .None || c != 1 {
			world_fail(w, "named: %v: %q appears %d times in a.txt on %s, the line the mount held (%v %q), at disk op %d", arm, strings.trim_space(NV_EDIT), c, on, eerr, string(edata), crash_at)
		}
		if c := strings.count(string(edata), NV_TOOL); c != 1 {
			world_fail(w, "named: %v: %q appears %d times in a.txt on %s after an edit (%q), at disk op %d", arm, strings.trim_space(NV_TOOL), c, on, string(edata), crash_at)
		}
	}
	if kind == .Checkout_New && arm.fork_check {
		_nv_authors(w, n, tree, arm, crash_at, "main", agent, keeper)
		if git_head_line(vfs, NV_ROOT) == NV_FEATURE {
			res.forked = true
			fdata, ferr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, NV_FEATURE)
			if ferr != .None {
				world_fail(w, "named fork: %v: a.txt unreadable on the new line: %v, at disk op %d", arm, ferr, crash_at)
			} else {
				for line in ([]string{NV_BASE, NV_KEPT, NV_TOOL}) {
					want := 0 if (arm.control && line == NV_KEPT) || (arm.clean && line == NV_TOOL) else 1
					if c := strings.count(string(fdata), line); c != want {
						world_fail(w, "named fork: %v: %q appears %d times in a.txt on the new line, want %d (%q), at disk op %d", arm, strings.trim_space(line), c, want, string(fdata), crash_at)
					}
				}
				_nv_authors(w, n, tree, arm, crash_at, NV_FEATURE, agent, keeper)
				if sm := _nv_mount(n); sm != nil && sm.m.fork_rejected > 0 {
					world_fail(w, "named fork: %v: the fork left out %d named versions the disk holds, at disk op %d", arm, sm.m.fork_rejected, crash_at)
				}
				if arm.two {
					ddata, derr := eng.tree_read(&n.e, tree, "d.txt", context.temp_allocator, {}, NV_FEATURE)
					for line in ([]string{NV_D_BASE, NV_D_KEPT, NV_D_TOOL}) {
						if c := strings.count(string(ddata), line); derr != .None || c != 1 {
							world_fail(w, "named fork: %v: %q appears %d times in d.txt on the new line (%v %q), at disk op %d", arm, strings.trim_space(line), c, derr, string(ddata), crash_at)
						}
					}
				}
			}
		}
	}
	if kind == .Checkout_Existing {
		fdata, ferr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, NV_FEATURE)
		if c := strings.count(string(fdata), NV_OTHER); ferr != .None || c != 1 {
			world_fail(w, "named: %v: %q appears %d times in a.txt on feature (%v %q), at disk op %d", arm, strings.trim_space(NV_OTHER), c, ferr, string(fdata), crash_at)
		}
	}
	return
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
_nv_authors :: proc(w: ^World, n: ^Node, tree: eng.Object, arm: Named_Arm, crash_at: u64, line: string, agent: prim.Id, keeper: prim.Id) {
	data, spans, err := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, line)
	if err != .None {
		world_fail(w, "named fork: %v: no blame for a.txt on %s: %v, at disk op %d", arm, line, err, crash_at)
		return
	}
	Want :: struct {
		text:  string,
		actor: prim.Id,
		skip:  bool,
	}
	for x in ([]Want{{NV_KEPT, keeper, arm.control}, {NV_TOOL, agent, arm.clean}}) {
		at := strings.index(string(data), x.text)
		if x.skip || at < 0 {
			continue
		}
		pos := 0
		for sp in spans {
			if pos < at + len(x.text) && pos + sp.len > at && sp.id.actor != x.actor {
				world_fail(w, "named fork: %v: %q on %s is credited to %s, not its writer %s, at disk op %d", arm, strings.trim_space(x.text), line, id_short(sp.id.actor), id_short(x.actor), crash_at)
				break
			}
			pos += sp.len
		}
	}
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
		if env_u64("NV_FORK", 0) != 0 {
			break
		}
		for bits in 0 ..< 10 {
			arm := Named_Arm{kind = kind, process = bits & 1 != 0, early = bits & 2 != 0, control = bits >= 4, clean = bits >= 8}
			points, named, ahead, settled, bad := 0, 0, 0, 0, 0
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
				if !res.crashed {
					break
				}
				points += 1
			}
			fmt.eprintf("named_version_crash: %v process=%v early=%v control=%v clean=%v: points=%d named=%d ahead=%d settled=%d failed=%d\n", kind, arm.process, arm.early, arm.control, arm.clean, points, named, ahead, settled, bad)
			testing.expect(t, arm.control || named > 0, fmt.tprintf("named_version_crash %v: no run had a named version in flight", arm))
		}
	}
	for bits in ([]int{0, 1, 4, 5, 8, 9, 16, 17}) {
		arm := Named_Arm{kind = .Checkout_New, process = bits & 1 != 0, control = bits >= 4 && bits < 16, clean = bits >= 8 && bits < 16, two = bits >= 16, fork_check = true}
		if env_u64("NV_FORK", 0) == 2 && !arm.two {
			continue
		}
		points, named, forked, bad := 0, 0, 0, 0
		for k in u64(1) ..= 4000 {
			failures, res := named_version_run(1, arm, k)
			if len(failures) > 0 {
				bad += 1
			}
			for f in failures {
				fmt.eprintf("named_version_crash: %s\n", f)
				delete(f)
			}
			testing.expect(t, len(failures) == 0, fmt.tprintf("named_version_crash fork %v at disk op %d failed", arm, k))
			delete(failures)
			named += 1 if res.named else 0
			forked += 1 if res.forked else 0
			if !res.crashed {
				break
			}
			points += 1
		}
		fmt.eprintf("named_version_crash: fork process=%v control=%v clean=%v two=%v: points=%d named=%d forked=%d failed=%d\n", arm.process, arm.control, arm.clean, arm.two, points, named, forked, bad)
		testing.expect(t, forked > 0, fmt.tprintf("named_version_crash fork %v: no run ended on the new line", arm))
	}
	for kind in Named_Kind {
		if env_u64("NV_FORK", 0) != 0 {
			break
		}
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
			testing.expect(t, bad == 0, "named_version_crash: an edit after recovery lost or doubled text")
		}
	}
}

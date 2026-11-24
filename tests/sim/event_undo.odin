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
EU_ROOT :: "/work/event-undo-n0-git"

@(private = "file")
EU_BASE :: "base line\n"

@(private = "file")
EU_KEPT :: "kept line\n"

@(private = "file")
EU_TOOL :: "tool line\n"

@(private = "file")
EU_ONE :: "edit one\n"

@(private = "file")
EU_TWO :: "edit two\n"

@(private = "file")
EU_TOUCH :: " touched"

Event_Undo_Arm :: struct {
	person:  bool,
	blocked: bool,
	outside: bool,
}

Event_Undo_Result :: struct {
	events:  u64,
	named:   bool,
	undone:  string,
	redone:  string,
	was:     string,
	blamed:  bool,
}

event_undo_run :: proc(seed: u64, arm: Event_Undo_Arm) -> (failures: [dynamic]string, res: Event_Undo_Result) {
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
	res = _event_undo(w, arm)
	res.undone = strings.clone(res.undone)
	res.redone = strings.clone(res.redone)
	res.was = strings.clone(res.was)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_eu_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == EU_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_eu_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_eu_open :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, actor: prim.Id) -> ^fs.Scope {
	return fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), actor)
}

@(private = "file")
_eu_scoped :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, scope: ^fs.Scope, path: string, data: string) -> bool {
	abs := strings.concatenate({EU_ROOT, "/", path}, context.temp_allocator)
	fs.mount_observe_begin(sm.m, path, scope)
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
	if _eu_write(disk_vfs(&n.disk), abs, data) != .None {
		return false
	}
	fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	return true
}

@(private = "file")
_eu_text :: proc(w: ^World, n: ^Node, tree: eng.Object, path: string) -> string {
	context = instance_context(&n.inst)
	t, err := eng.tree_read(&n.e, tree, path, context.temp_allocator, {}, "main")
	if err != .None {
		world_fail(w, "event undo: read %s: %v", path, err)
		return ""
	}
	return strings.clone(string(t), w.allocator)
}

@(private = "file")
_event_undo :: proc(w: ^World, arm: Event_Undo_Arm) -> (res: Event_Undo_Result) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "event undo: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	setup: {
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "event-undo")
		if err != .None {
			world_fail(w, "event undo: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "event undo: tree_create: %v", err)
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
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string(EU_BASE)}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	if err := git_checkout_create(vfs, EU_ROOT, files[:], clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "event undo: git checkout: %v", err)
		return
	}
	if err := node_mount(w, n, oi, EU_ROOT); err != .None {
		world_fail(w, "event undo: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(EU_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	owner := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	pseudo := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	agent: prim.Id
	before: fs.Version
	named: {
		context = instance_context(&n.inst)
		sm := _eu_mount(n)
		if sm == nil {
			world_fail(w, "event undo: mount missing")
			return
		}
		agent = fshist.ingestion_actor(sm.m.history.self, pseudo)
		if err := fs.history_register_owned_actor(sm.m.history, agent, pseudo, owner); err != .None {
			world_fail(w, "event undo: register: %v", err)
			return
		}
		other :: proc(w: ^World, n: ^Node) -> prim.Id {
			return prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		}
		hold := _eu_open(w, n, sm, other(w, n))
		fs.scope_write_begin(hold, "a.txt")
		reader := _eu_open(w, n, sm, other(w, n))
		fs.scope_read_base(reader, "a.txt", transmute([]u8)string(EU_BASE))
		if !fs.scope_pinned(reader, "a.txt") || !_eu_scoped(w, n, sm, _eu_open(w, n, sm, other(w, n)), "a.txt", EU_BASE + EU_KEPT) || !_eu_scoped(w, n, sm, reader, "a.txt", EU_BASE + EU_TOOL) {
			world_fail(w, "event undo: the named version")
			return
		}
		e, found, serr := fs.shadow_get(&sm.m.shadow, "a.txt")
		res.named = serr == .None && found && e.ver != 0
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	start: {
		context = instance_context(&n.inst)
		v, err := eng.tree_version(&n.e, tree, "main", w.allocator)
		if err != .None {
			world_fail(w, "event undo: version: %v", err)
			return
		}
		before = v
	}
	first := _eu_text(w, n, tree, "a.txt")
	if arm.blocked {
		block: {
			context = instance_context(&n.inst)
			sm := _eu_mount(n)
			ok := false
			if arm.person {
				ok = _eu_write(vfs, EU_ROOT + "/b.txt", "main b\nraised\n") == .None
			} else {
				ok = _eu_scoped(w, n, sm, _eu_open(w, n, sm, agent), "b.txt", "main b\nraised\n")
			}
			if !ok {
				world_fail(w, "event undo: b.txt")
				return
			}
			node_after(n)
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	edit: {
		context = instance_context(&n.inst)
		sm := _eu_mount(n)
		text := EU_BASE + EU_TOOL + EU_ONE + EU_TWO
		ok := false
		if arm.person {
			ok = _eu_write(vfs, EU_ROOT + "/a.txt", text) == .None
		} else {
			ok = _eu_scoped(w, n, sm, _eu_open(w, n, sm, agent), "a.txt", text)
		}
		if !ok {
			world_fail(w, "event undo: the edit")
			return
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	if arm.outside {
		outside: {
			context = instance_context(&n.inst)
			at, _ := eng.tree_version(&n.e, tree, "main", context.temp_allocator)
			t, _ := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
			now, _ := strings.replace(string(t), "edit one", "edit one" + EU_TOUCH, 1, context.temp_allocator)
			if err := eng.tree_write(&n.e, tree, "a.txt", transmute([]u8)now, at, "main"); err != .None {
				world_fail(w, "event undo: outside write: %v", err)
				return
			}
			node_after(n)
		}
		run_until(w, w.now + 2_000_000_000, true)
	}
	res.was = _eu_text(w, n, tree, "a.txt")
	b_was := _eu_text(w, n, tree, "b.txt")
	one_text := EU_ONE if !arm.outside else "edit one" + EU_TOUCH + "\n"
	for line in ([]string{EU_BASE, EU_KEPT, EU_TOOL, one_text, EU_TWO}) {
		if c := strings.count(res.was, line); c != 1 {
			world_fail(w, "event undo: %v: %q appears %d times before the undo (%q)", arm, strings.trim_space(line), c, res.was)
			return
		}
	}
	revert: prim.Id
	undo: {
		context = instance_context(&n.inst)
		sm := _eu_mount(n)
		res.events = sm.m.event_actors
		set: []prim.Id
		serr: fs.Error
		who := sm.m.actor
		if arm.person {
			set, serr = fs.history_mount_actors(sm.m.history, []prim.Id{sm.m.id}, []string{sm.m.line}, context.temp_allocator)
		} else {
			who = agent
			set, serr = fs.history_owned_actors(sm.m.history, []prim.Id{owner}, context.temp_allocator)
		}
		if serr != .None {
			world_fail(w, "event undo: the undo's actors: %v", serr)
			return
		}
		data, spans, berr := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, "main")
		want := fs.history_present_actor(sm.m.history, who)
		at := strings.index(string(data), EU_TWO)
		off := 0
		for sp in spans {
			if at >= off && at + len(EU_TWO) <= off + sp.len {
				res.blamed = sp.id.actor == want
			}
			off += sp.len
		}
		if berr != .None || !res.blamed {
			world_fail(w, "event undo: %v: the edit is not blamed on its base (%v)", arm, berr)
		}
		r, err := eng.tree_revert_set(&n.e, tree, before, set, "main")
		if err != .None {
			world_fail(w, "event undo: undo: %v", err)
			return
		}
		revert = r
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	res.undone = _eu_text(w, n, tree, "a.txt")
	if !arm.outside && res.undone != first {
		world_fail(w, "event undo: %v: after the undo a.txt is %q, want %q", arm, res.undone, first)
	}
	for line in ([]string{EU_BASE, EU_KEPT, EU_TOOL}) {
		if c := strings.count(res.undone, line); c != 1 {
			world_fail(w, "event undo: %v: %q appears %d times after the undo (%q)", arm, strings.trim_space(line), c, res.undone)
		}
	}
	if b := _eu_text(w, n, tree, "b.txt"); b != "main b\n" {
		world_fail(w, "event undo: %v: after the undo b.txt is %q", arm, b)
	}
	if revert == {} {
		return
	}
	again: {
		context = instance_context(&n.inst)
		if _, err := eng.tree_unrevert(&n.e, tree, revert, "main"); err != .None {
			world_fail(w, "event undo: redo: %v", err)
			return
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	res.redone = _eu_text(w, n, tree, "a.txt")
	if res.redone != res.was {
		world_fail(w, "event undo: %v: after the redo a.txt is %q, want %q", arm, res.redone, res.was)
	}
	if b := _eu_text(w, n, tree, "b.txt"); b != b_was {
		world_fail(w, "event undo: %v: after the redo b.txt is %q, want %q", arm, b, b_was)
	}
	return
}

@(test)
event_undo :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	plain: [4][21]string
	defer for row in plain {
		for x in row {
			delete(x)
		}
	}
	for bits in 0 ..< 8 {
		arm := Event_Undo_Arm{person = bits & 1 != 0, outside = bits & 2 != 0, blocked = bits & 4 != 0}
		named, events, bad := 0, 0, 0
		for seed in u64(1) ..= 20 {
			failures, res := event_undo_run(seed, arm)
			for f in failures {
				if bad == 0 {
					fmt.eprintf("event_undo seed %d: %s\n", seed, f)
				}
				delete(f)
			}
			bad += 1 if len(failures) > 0 else 0
			named += 1 if res.named else 0
			events += 1 if res.events > 0 else 0
			if !arm.blocked {
				plain[bits & 3][seed] = strings.clone(res.undone)
			}
			if arm.blocked && res.undone != plain[bits & 3][seed] {
				fmt.eprintf("event_undo seed %d: %v: the undo of an event actor's batch left %q, a plain one %q\n", seed, arm, res.undone, plain[bits & 3][seed])
				testing.expect(t, false, "event_undo: an event actor's batch is undone like a plain one")
			}
			if seed == 1 {
				fmt.eprintf("event_undo: %v undone %q redone %q\n", arm, res.undone, res.redone)
			}
			delete(failures)
			delete(res.undone)
			delete(res.redone)
			delete(res.was)
		}
		fmt.eprintf("event_undo: %v: %d of 20 named, %d with an event actor, %d failed\n", arm, named, events, bad)
		testing.expect(t, bad == 0, fmt.tprintf("event_undo %v failed", arm))
		testing.expect(t, named > 0, "event_undo: no run had a named version")
		testing.expect(t, arm.blocked == (events > 0), fmt.tprintf("event_undo %v: %d runs used an event actor", arm, events))
	}
}

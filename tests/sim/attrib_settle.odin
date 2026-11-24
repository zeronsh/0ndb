package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

SETTLE_ROOT :: "/work/settle-n0-git"
SETTLE_AGENT :: "agent line\n"
SETTLE_OTHER :: "other device line\n"

@(private = "file")
Settle_Run :: struct {
	failures: [dynamic]string,
	crashed:  bool,
	lost:     bool,
	recheck:  bool,
	pending:  bool,
}

@(private = "file")
_settle_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == SETTLE_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_settle_observed :: proc(ctx: rawptr, err: fs.Error) {
	(^bool)(ctx)^ = err == .None
}

@(private = "file")
_settle_write :: proc(vfs: prim.Vfs, path: string, data: string, sync: bool) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None && sync {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_settle_disk :: proc(n: ^Node) -> string {
	n.disk.quiet = true
	data, err := prim.read_file(disk_vfs(&n.disk), SETTLE_ROOT + "/a.txt", context.temp_allocator)
	n.disk.quiet = false
	return string(data) if err == .None else ""
}

@(private = "file")
_settle_run :: proc(crash_at: u64) -> (r: Settle_Run) {
	r.failures = make([dynamic]string)
	cfg := default_config(1)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.persist_fault = false
	cfg.storage = .Auto
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_settle(w, crash_at, &r)
	for f in w.failures {
		append(&r.failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_settle :: proc(w: ^World, crash_at: u64, r: ^Settle_Run) {
	a, b := w.nodes[0], w.nodes[1]
	if !relay_start(&w.relay) || !node_start(a) || !node_start(b) {
		world_fail(w, "settle: start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&a.disk)
	space: prim.Id
	tree: eng.Object
	proof: []u8
	setup: {
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		space, err = eng.space_create(&a.e, "settle", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, space) != .None {
			world_fail(w, "settle: space: %v", err)
			return
		}
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "settle: tree_create: %v", err)
			return
		}
		proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if err != .None {
			world_fail(w, "settle: member_add: %v", err)
			return
		}
	}
	join: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "settle", "relay", w.relay.public); err != .None {
			world_fail(w, "settle: join: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "settle: space_open: %v", err)
			return
		}
	}
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("base line\n")}}
	if err := git_checkout_create(vfs, SETTLE_ROOT, files[:], clock_wall(&a.clock) / 1_000_000_000, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "settle: git checkout: %v", err)
		return
	}
	if err := node_mount(w, a, oi, SETTLE_ROOT); err != .None {
		world_fail(w, "settle: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = a.idx, oi = oi, root = strings.clone(SETTLE_ROOT, w.allocator)})
	run_until(w, w.now + 10_000_000_000, true)
	held := false
	for i := 0; i < 400 && !held; i += 1 {
		run_until(w, w.now + 50_000_000, true)
		context = instance_context(&b.inst)
		defer node_after(b)
		data, rerr := eng.tree_read(&b.e, tree, "a.txt", context.temp_allocator)
		held = rerr == .None && string(data) == "base line\n"
	}
	if !held {
		world_fail(w, "settle: the other device never read the base")
		return
	}
	agent := prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
	crashes := w.stats.crashes
	write: {
		context = instance_context(&a.inst)
		sm := _settle_mount(a)
		if sm == nil {
			world_fail(w, "settle: mount missing before the write")
			return
		}
		scope := fs.scope_open(a.reg, sm.m, prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng)), agent)
		ok := false
		if fs.mount_observe_begin(sm.m, "a.txt", scope, _settle_observed, &ok) != .None {
			world_fail(w, "settle: observe")
			return
		}
		for i := 0; i < 200 && !ok; i += 1 {
			run_until(w, w.now + 10_000_000, true)
		}
		context = instance_context(&a.inst)
		if !ok || _settle_mount(a) != sm {
			world_fail(w, "settle: the observation was never durable")
			return
		}
		_writer_set(w, a, SETTLE_ROOT + "/a.txt", Writer_Info{scope = scope, agent = true})
		a.disk.crash_at = a.disk.stats.ops + crash_at
		if _settle_write(vfs, SETTLE_ROOT + "/a.txt", "base line\n" + SETTLE_AGENT, false) != .None || a.disk.dead {
			break write
		}
		fs.scope_close(a.reg, scope)
		if !a.disk.dead {
			_forget_scope(w, a, scope)
		}
	}
	before: u64
	if sm := _settle_mount(a); sm != nil && sm.m.history != nil {
		before = crdt.graph_known(&sm.m.history.g, agent)
	}
	if a.disk.dead {
		node_crashed(a)
	} else {
		after: {
			context = instance_context(&a.inst)
			node_after(a)
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	a.disk.crash_at = 0
	r.crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !a.alive || _settle_mount(a) == nil {
		world_fail(w, "settle: the mount did not come back")
		return
	}
	r.lost = r.crashed && _settle_disk(a) == "base line\n"
	if x, has := _settle_mount(a).m.attrib["a.txt"]; r.lost && has && !x.used && x.oid != {} {
		r.pending = true
	}
	replace: {
		context = instance_context(&b.inst)
		defer node_after(b)
		if err := eng.tree_remove(&b.e, tree, "a.txt"); err != .None {
			world_fail(w, "settle: the other device's remove: %v", err)
			return
		}
		v, _ := eng.tree_version(&b.e, tree, "", context.temp_allocator)
		if err := eng.tree_write(&b.e, tree, "a.txt", transmute([]u8)string(SETTLE_OTHER), v); err != .None {
			world_fail(w, "settle: the other device's write: %v", err)
			return
		}
	}
	for i := 0; i < 600 && _settle_disk(a) != SETTLE_OTHER; i += 1 {
		run_until(w, w.now + 50_000_000, true)
	}
	if _settle_disk(a) != SETTLE_OTHER {
		world_fail(w, "settle: the other device's file was never placed, disk %q", _settle_disk(a))
		return
	}
	recheck: {
		context = instance_context(&a.inst)
		defer node_after(a)
		sm := _settle_mount(a)
		if x, has := sm.m.attrib["a.txt"]; has && !x.used && (x.oid != {} || x.actor == agent) {
			world_fail(w, "settle: an unused entry of %s waits at a.txt for the file that replaced it (crash at disk op %d)", id_short(x.actor), crash_at)
		}
		if e, found, _ := fs.shadow_get(&sm.m.shadow, "a.txt"); found {
			r.recheck = e.racy
		}
		fs.mount_mark(sm.m, "a.txt")
		fs.mount_sync(sm.m)
	}
	run_until(w, w.now + 20_000_000_000, true)
	for n in ([]^Node{a, b}) {
		context = instance_context(&n.inst)
		defer node_after(n)
		data, spans, err := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator)
		if err != .None || string(data) != SETTLE_OTHER {
			world_fail(w, "settle: %s reads a.txt as %q (%v)", n.name, string(data), err)
			continue
		}
		for sp in spans {
			if sp.id.actor != b.identity.id {
				world_fail(w, "settle: %s credits %d bytes of the other device's line to %s (crash at disk op %d)", n.name, sp.len, id_short(sp.id.actor), crash_at)
			}
		}
	}
	if r.lost && before == 0 {
		sm := _settle_mount(a)
		if k := crdt.graph_known(&sm.m.history.g, agent); k != 0 {
			world_fail(w, "settle: the agent's lost write was replayed as %d ops (crash at disk op %d)", k, crash_at)
		}
	}
}

@(test)
attrib_settle :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	points, lost, rechecked, pending := 0, 0, 0, 0
	for k in u64(1) ..= 4000 {
		r := _settle_run(k)
		for f in r.failures {
			fmt.eprintf("attrib_settle at disk op %d: %s\n", k, f)
			delete(f)
		}
		testing.expect(t, len(r.failures) == 0, fmt.tprintf("attrib_settle at disk op %d failed", k))
		delete(r.failures)
		lost += int(r.lost)
		rechecked += int(r.lost && r.recheck)
		pending += int(r.pending)
		if !r.crashed {
			break
		}
		points += 1
	}
	testing.expect(t, lost > 0, "no crash point lost the agent's write, so the check proves nothing")
	testing.expect(t, rechecked > 0, "no lost write was followed by a racy recheck, so the check proves nothing")
	fmt.eprintf("attrib_settle: %d crash points, %d lost the write, %d of them rechecked racy, %d still held its content entry after recovery\n", points, lost, rechecked, pending)
}

package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

RIM_ROOT :: "/work/rim-n1"

@(private = "file")
_rim_case :: proc(seed: u64, k: u64) -> (crashed: bool, changed: int, failures: [dynamic]string) {
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
	cfg.durability = .Async
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	w.node_cfg = reissue_hold
	crashed, changed = _rim_run(w, k)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_rim_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == RIM_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
Rim_Observed :: struct {
	done: bool,
	err:  fs.Error,
}

@(private = "file")
_rim_observed :: proc(ctx: rawptr, err: fs.Error) {
	o := cast(^Rim_Observed)ctx
	o.done = true
	o.err = err
}

@(private = "file")
_rim_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
Rim_View :: struct {
	ok:    bool,
	data:  string,
	spans: string,
}

@(private = "file")
_rim_view :: proc(w: ^World, n: ^Node, tree: eng.Object) -> (v: Rim_View) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, spans, err := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator)
	if err != .None {
		return
	}
	b := strings.builder_make(w.allocator)
	for sp in spans {
		ax := prim.id_hex(sp.id.actor)
		fmt.sbprintf(&b, "%s:%d+%d ", string(ax[:]), sp.id.seq, sp.len)
	}
	v.ok = true
	v.data = strings.clone(string(data), w.allocator)
	v.spans = strings.to_string(b)
	return
}

@(private = "file")
_rim_agent :: proc(w: ^World, b: ^Node, tree: eng.Object, sid, agent: prim.Id, data: string, seen: ^[dynamic]Reissue_Batch) -> bool {
	context = instance_context(&b.inst)
	sm := _rim_mount(b)
	if sm == nil {
		return false
	}
	scope := sim_scope_open(w, b.reg, sm.m, sid, agent)
	obs := Rim_Observed{}
	if fs.mount_observe_begin(sm.m, "a.txt", scope, _rim_observed, &obs) != .None || b.disk.dead {
		return false
	}
	for limit := w.now + 10_000_000_000; !obs.done && !b.disk.dead && b.alive && w.now < limit && reissue_going(w); {
		run_until(w, w.now + 10_000_000, true)
		context = instance_context(&b.inst)
	}
	if !obs.done || obs.err != .None || b.disk.dead || !b.alive || _rim_mount(b) != sm {
		return false
	}
	_writer_set(w, b, RIM_ROOT + "/a.txt", Writer_Info{scope = scope, agent = true})
	if _rim_write(disk_vfs(&b.disk), RIM_ROOT + "/a.txt", transmute([]u8)data) != .None || b.disk.dead {
		return false
	}
	fs.scope_close(b.reg, scope)
	_forget_scope(w, b, scope)
	if seen != nil {
		reissue_see(w, b, tree, seen)
	}
	return true
}

@(private = "file")
_rim_run :: proc(w: ^World, k: u64) -> (crashed: bool, changed: int) {
	seen := make([dynamic]Reissue_Batch, w.allocator)
	if !relay_start(&w.relay) {
		world_fail(w, "reissue mount: relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "reissue mount: node start")
		return
	}
	m := &w.model
	space: prim.Id
	tree: eng.Object
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		if space, err = eng.space_create(&a.e, "reissue-mount", "relay", w.relay.public); err != .None {
			world_fail(w, "reissue mount: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "reissue mount: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "reissue mount: tree_create: %v", err)
			return
		}
		if err = eng.tree_write(&a.e, tree, "a.txt", transmute([]u8)string("base line\n"), tree_base(&a.e, tree)); err != .None {
			world_fail(w, "reissue mount: n0 tree_write: %v", err)
			return
		}
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "reissue mount: member_add: %v", err)
			return
		}
	}
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "reissue-mount", "relay", w.relay.public); err != .None {
			world_fail(w, "reissue mount: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "reissue mount: n1 space_open: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	cop := new_op(m, .Create, a, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = a.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	vfs := disk_vfs(&b.disk)
	if err := prim.mkdir_all(vfs, RIM_ROOT); err != .None {
		world_fail(w, "reissue mount: mkdir: %v", err)
		return
	}
	if err := node_mount(w, b, oi, RIM_ROOT); err != .None {
		world_fail(w, "reissue mount: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = b.idx, oi = oi, root = strings.clone(RIM_ROOT, w.allocator)})
	run_until(w, w.now + 5_000_000_000, true)
	agent := prim.id_new_with(node_clock(&b.clock), rng_random(&w.rng))
	sid := prim.id_new_with(node_clock(&b.clock), rng_random(&w.rng))
	crashes := w.stats.crashes
	b.disk.crash_at = b.disk.stats.ops + k
	_rim_agent(w, b, tree, sid, agent, "base line\nagent line\n", &seen)
	if b.disk.dead {
		node_crashed(b)
	} else {
		ctx: {
			context = instance_context(&b.inst)
			node_after(b)
		}
	}
	reissue_watch(w, b, tree, &seen, w.now + 20_000_000_000)
	b.disk.crash_at = 0
	if !b.alive {
		b.disk.probe += 1
		werr := _rim_write(vfs, RIM_ROOT + "/a.txt", transmute([]u8)string("base line\n"))
		b.disk.probe -= 1
		if werr != .None {
			world_fail(w, "reissue mount: edit while n1 is down: %v", werr)
			return
		}
	}
	crashed = w.stats.crashes > crashes
	if !reissue_restarted(w, b) {
		world_fail(w, "reissue mount: n1 did not restart after the crash at op %d", k)
		return
	}
	for _ in 0 ..< 40 {
		if _rim_mount(b) != nil {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !_rim_agent(w, b, tree, sid, agent, "base line\nlater agent line\n", nil) {
		world_fail(w, "reissue mount: crash at op %d: the agent could not write again", k)
		return
	}
	close: {
		context = instance_context(&b.inst)
		node_after(b)
	}
	run_until(w, w.now + 30_000_000_000, true)
	va := _rim_view(w, a, tree)
	vb := _rim_view(w, b, tree)
	if !va.ok || !vb.ok {
		world_fail(w, "reissue mount: crash at op %d: a.txt has no blame (n0 %v, n1 %v)", k, va.ok, vb.ok)
		return
	}
	if va.data != vb.data {
		world_fail(w, "reissue mount: crash at op %d: n0 reads %q but n1 reads %q", k, va.data, vb.data)
	} else if va.spans != vb.spans {
		world_fail(w, "reissue mount: crash at op %d: the same text carries different op ids: n0 %s, n1 %s", k, va.spans, vb.spans)
	}
	_, changed = reissue_settle(w, fmt.tprintf("reissue mount: crash at op %d", k), a, b, tree, seen[:])
	if !strings.contains(va.data, "later agent line") {
		world_fail(w, "reissue mount: crash at op %d: n0 reads %q without the agent's second write", k, va.data)
	}
	check_uploaded(w)
	check_derived(a, fmt.tprintf("reissue mount crash at op %d, n0", k))
	check_derived(b, fmt.tprintf("reissue mount crash at op %d, n1", k))
	return
}

@(test)
reissue_mount_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	points, changed_points := 0, 0
	for seed in u64(1) ..= 2 {
		for k := u64(1); k < 6000; k += 1 {
			crashed, changed, failures := _rim_case(seed, k)
			for f in failures {
				fmt.eprintf("reissue_mount_crash seed %d crash %d: %s\n", seed, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "reissue_mount_crash seed %d crash at op %d failed", seed, k)
			n := len(failures)
			delete(failures)
			if !crashed || n > 0 {
				break
			}
			points += 1
			changed_points += 1 if changed > 0 else 0
		}
	}
	testing.expect(t, changed_points > 0, "reissue_mount_crash never re-issued a sequence")
	fmt.eprintf("reissue_mount_crash: %d crash points, %d re-issued a lost sequence with other operations\n", points, changed_points)
	free_all(context.temp_allocator)
}

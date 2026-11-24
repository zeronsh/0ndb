package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/obj"
import "../../src/prim"

CARRY_UNDO_ROOT :: "/work/carry-undo-git"
CARRY_UNDO_AGENT :: "agent turn line\n"
CARRY_UNDO_PERSON :: "person later line\n"

@(private = "file")
_cu_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == CARRY_UNDO_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_cu_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_cu_msg :: proc(w: ^World, n: ^Node, conv: eng.Object, role: convo.Role, parent: obj.Rid, files: []convo.File_Delta) -> (msg: obj.Rid, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, conv)
	if werr != .None {
		world_fail(w, "carry undo: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = parent, files = files})
	if merr != .None {
		world_fail(w, "carry undo: writer_message: %v", merr)
		return
	}
	convo.writer_commit(wr)
	return m, true
}

carry_undo_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_carry_undo(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_carry_undo :: proc(w: ^World) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "carry undo: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree, conv: eng.Object
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "carry-undo")
		if err != .None {
			world_fail(w, "carry undo: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "carry undo: tree_create: %v", err)
			return
		}
		conv, err = eng.convo_create(&n.e, space, eng.Convo_Settings{title = "carry"})
		if err != .None {
			world_fail(w, "carry undo: convo_create: %v", err)
			return
		}
		if merr := eng.convo_mount(&n.e, conv, "work", tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "carry undo: convo_mount: %v", merr)
			return
		}
		eng.undo_hooks_set(&n.e, eng.Undo_Hooks{})
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	files := [?]Git_File{{name = "a.txt", data = transmute([]u8)string("shared a\n")}, {name = "b.txt", data = transmute([]u8)string("main b\n")}}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, CARRY_UNDO_ROOT, files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry undo: git checkout: %v", err)
		return
	}
	feature := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}}
	if err := git_branch_commit(vfs, CARRY_UNDO_ROOT, "feature", feature[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry undo: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, CARRY_UNDO_ROOT); err != .None {
		world_fail(w, "carry undo: mount: %v", err)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, CARRY_UNDO_ROOT, "feature", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "carry undo: checkout feature: %v %v", res, err)
		return
	}
	follow: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	base: [dynamic]u8
	main_base: {
		context = instance_context(&n.inst)
		defer node_after(n)
		v, verr := eng.tree_version(&n.e, tree, "main", context.temp_allocator)
		if verr != .None {
			world_fail(w, "carry undo: main version: %v", verr)
			return
		}
		vb := make([dynamic]u8, context.temp_allocator)
		fs.encode_version(&vb, v)
		base = make([dynamic]u8, w.allocator)
		bw := prim.writer(&base)
		prim.write_bytes(&bw, vb[:])
		prim.write_str(&bw, "")
		prim.write_str(&bw, "")
	}
	user, uok := _cu_msg(w, n, conv, .User, {}, nil)
	if !uok {
		return
	}
	delta := []convo.File_Delta{{mount = "work", tree = tree.id, version = base[:]}}
	reply, rok := _cu_msg(w, n, conv, .Assistant, user, delta)
	if !rok {
		return
	}
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	turn: {
		context = instance_context(&n.inst)
		defer node_after(n)
		sm := _cu_mount(n)
		if sm == nil || fs.mount_line(sm.m) != "git:refs/heads/feature" {
			world_fail(w, "carry undo: the mount did not follow feature")
			return
		}
		scope := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		if oerr := fs.mount_observe_begin(sm.m, "a.txt", scope); oerr != .None {
			world_fail(w, "carry undo: observe: %v", oerr)
			return
		}
		if werr := _cu_write(vfs, CARRY_UNDO_ROOT + "/a.txt", strings.concatenate({"shared a\n", CARRY_UNDO_AGENT}, context.temp_allocator)); werr != .None {
			world_fail(w, "carry undo: agent write: %v", werr)
			return
		}
		if serr := fs.scope_close(n.reg, scope); serr != .None {
			world_fail(w, "carry undo: scope close: %v", serr)
			return
		}
		wr, werr := eng.convo_writer(&n.e, conv)
		if werr != .None {
			world_fail(w, "carry undo: convo_writer: %v", werr)
			return
		}
		convo.writer_scope(wr, reply, .Turn, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent, nil, nil)
		if _, sealerr := convo.writer_seal(wr, reply, .Done); sealerr != .None {
			world_fail(w, "carry undo: writer_seal: %v", sealerr)
			return
		}
		convo.writer_commit(wr)
	}
	run_until(w, w.now + 2_000_000_000, true)
	back := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, CARRY_UNDO_ROOT, "main", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &back); res != .Done || err != .None {
		world_fail(w, "carry undo: checkout main: %v %v", res, err)
		return
	}
	carry: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	person: {
		if werr := _cu_write(vfs, CARRY_UNDO_ROOT + "/a.txt", strings.concatenate({"shared a\n", CARRY_UNDO_AGENT, CARRY_UNDO_PERSON}, context.temp_allocator)); werr != .None {
			world_fail(w, "carry undo: person write: %v", werr)
			return
		}
		context = instance_context(&n.inst)
		defer node_after(n)
		if sm := _cu_mount(n); sm != nil {
			fs.mount_sync(sm.m)
		}
	}
	run_until(w, w.now + 2_000_000_000, true)
	before: {
		context = instance_context(&n.inst)
		defer node_after(n)
		data, spans, berr := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, "main")
		if berr != .None {
			world_fail(w, "carry undo: blame before undo: %v", berr)
			return
		}
		lo := strings.index(string(data), CARRY_UNDO_AGENT)
		if lo < 0 {
			world_fail(w, "carry undo: main lacks the carried line before the undo: %q", string(data))
			return
		}
		at := 0
		for sp in spans {
			if at >= lo && at + sp.len <= lo + len(CARRY_UNDO_AGENT) && sp.id.actor != agent {
				world_fail(w, "carry undo: the carried line on main blames to %s, not the agent %s", id_short(sp.id.actor), id_short(agent))
			}
			at += sp.len
		}
	}
	undo: {
		context = instance_context(&n.inst)
		defer node_after(n)
		if _, err := eng.convo_undo(&n.e, conv, user); err != .None {
			world_fail(w, "carry undo: convo_undo: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	after: {
		context = instance_context(&n.inst)
		defer node_after(n)
		data, rerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main")
		if rerr != .None {
			world_fail(w, "carry undo: read after undo: %v", rerr)
			return
		}
		if strings.contains(string(data), CARRY_UNDO_AGENT) {
			world_fail(w, "carry undo: undoing the turn left its carried line on main: %q", string(data))
		}
		if !strings.contains(string(data), CARRY_UNDO_PERSON) {
			world_fail(w, "carry undo: undoing the turn removed the person's later line on main: %q", string(data))
		}
		disk, _ := prim.read_file(vfs, CARRY_UNDO_ROOT + "/a.txt", context.temp_allocator)
		if string(disk) != string(data) {
			world_fail(w, "carry undo: a.txt on disk is %q, main %q", string(disk), string(data))
		}
	}
}

@(test)
carry_undo :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := carry_undo_run(1)
	for f in failures {
		fmt.eprintf("carry_undo: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "carry_undo failed")
	delete(failures)
}

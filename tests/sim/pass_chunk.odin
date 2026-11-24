package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/crdt"
import "../../src/fs"
import "../../src/prim"

PASS_CHUNK_ROOT :: "/work/chunk-n0-git"

@(private = "file")
PC_DIRS :: 4

@(private = "file")
PC_PER_DIR :: 8

@(private = "file")
PC_BUDGET :: 6

@(private = "file")
Pc_Variant :: enum {
	Writes,
	Switch,
}

@(private = "file")
Pc_Park :: struct {
	w:     ^World,
	parks: int,
	at:    int,
}

@(private = "file")
_pc_name :: proc(d, i: int) -> string {
	return fmt.tprintf("f%d%02d.txt", d, i)
}

@(private = "file")
_pc_body :: proc(tag: string, d, i: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for j in 0 ..< 1 + (d + i) % 5 {
		fmt.sbprintf(&b, "%s %d/%02d line %d\n", tag, d, i, j)
	}
	return b.buf[:]
}

@(private = "file")
_pc_on_park :: proc(m: ^fs.Mount, data: rawptr) {
	pk := (^Pc_Park)(data)
	pk.parks += 1
	if pk.parks == pk.at {
		pk.w.pause = true
	}
}

@(private = "file")
_pc_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == PASS_CHUNK_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

pass_chunk_run :: proc(seed: u64, v: Pc_Variant) -> (failures: [dynamic]string) {
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
	cfg.pass_budget = PC_BUDGET
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_pc_case(w, v)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_pc_case :: proc(w: ^World, v: Pc_Variant) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "chunk: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "chunk")
		if err != .None {
			world_fail(w, "chunk: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "chunk: tree_create: %v", err)
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
	main_files := make([dynamic]Git_File, context.temp_allocator)
	other_files := make([dynamic]Git_File, context.temp_allocator)
	for d in 0 ..< PC_DIRS {
		for i in 0 ..< PC_PER_DIR {
			append(&main_files, Git_File{name = _pc_name(d, i), data = _pc_body("main", d, i)})
			append(&other_files, Git_File{name = _pc_name(d, i), data = _pc_body("other", d, i)})
		}
	}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, PASS_CHUNK_ROOT, main_files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "chunk: git checkout: %v", err)
		return
	}
	if err := git_branch_commit(vfs, PASS_CHUNK_ROOT, "other", other_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "chunk: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, PASS_CHUNK_ROOT); err != .None {
		world_fail(w, "chunk: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(PASS_CHUNK_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	sm := _pc_mount(n)
	if sm == nil {
		world_fail(w, "chunk: the mount is missing after its import")
		return
	}
	pk := new(Pc_Park, w.allocator)
	pk.w = w
	pk.at = 3
	fs.registry_set_park_note(n.reg, _pc_on_park, pk)
	turns0 := sm.m.pass_turns
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, PASS_CHUNK_ROOT, "other", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "chunk: checkout other: %v %v", res, err)
		return
	}
	after: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	if pk.parks < pk.at || !fs.mount_pass_parked(sm.m) {
		world_fail(w, "chunk: the checkout pass parked %d times and is parked %v, so nothing ran between its chunks", pk.parks, fs.mount_pass_parked(sm.m))
		return
	}
	agent_rel := strings.clone(_pc_name(PC_DIRS - 1, PC_PER_DIR - 1), w.allocator)
	person_rel := strings.clone(_pc_name(0, 0), w.allocator)
	agent_body := transmute([]u8)fmt.aprintf("%sagent line\n", string(_pc_body("other", PC_DIRS - 1, PC_PER_DIR - 1)), allocator = w.allocator)
	person_body := transmute([]u8)fmt.aprintf("%sperson line\n", string(_pc_body("other", 0, 0)), allocator = w.allocator)
	actor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	switch v {
	case .Writes:
		context = instance_context(&n.inst)
		scope := fs.scope_open(n.reg, sm.m, sid, actor)
		if oerr := fs.mount_observe_begin(sm.m, agent_rel, scope); oerr != .None {
			world_fail(w, "chunk: observe between chunks: %v", oerr)
			node_after(n)
			return
		}
		n.writers[fmt.aprintf("%s/%s", PASS_CHUNK_ROOT, agent_rel, allocator = w.allocator)] = Writer_Info{scope = scope, agent = true}
		if werr := _pc_write(vfs, fmt.tprintf("%s/%s", PASS_CHUNK_ROOT, agent_rel), agent_body); werr != .None {
			world_fail(w, "chunk: agent write: %v", werr)
			node_after(n)
			return
		}
		if serr := fs.scope_close(n.reg, scope); serr != .None {
			world_fail(w, "chunk: scope close between chunks: %v", serr)
			node_after(n)
			return
		}
		if !fs.mount_pass_parked(sm.m) {
			world_fail(w, "chunk: closing the agent's scope finished the parked pass in the same call")
		}
		if werr := _pc_write(vfs, fmt.tprintf("%s/%s", PASS_CHUNK_ROOT, person_rel), person_body); werr != .None {
			world_fail(w, "chunk: person write: %v", werr)
			node_after(n)
			return
		}
		node_after(n)
	case .Switch:
		context = instance_context(&n.inst)
		if err := fs.mount_line_switch(sm.m, "git:refs/heads/main"); err != .None {
			world_fail(w, "chunk: switch between chunks: %v", err)
			node_after(n)
			return
		}
		if !fs.mount_pass_parked(sm.m) {
			world_fail(w, "chunk: requesting a switch finished the parked pass in the same call")
		}
		node_after(n)
	}
	run_until(w, w.now + 40_000_000_000, true)
	if fs.mount_pass_parked(sm.m) {
		world_fail(w, "chunk: the checkout pass is still parked after 40 s")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	if sm.m.pass_turns - turns0 < 2 {
		world_fail(w, "chunk: the checkout pass ran in %d turns", sm.m.pass_turns - turns0)
	}
	if sm.m.pass_turn_max > PC_BUDGET + 16 {
		world_fail(w, "chunk: a turn of a budget-%d pass spent %d", PC_BUDGET, sm.m.pass_turn_max)
	}
	if v == .Switch {
		if to, pending := fs.mount_switch_pending(sm.m); pending {
			world_fail(w, "chunk: the switch to %s did not complete after the parked pass", to)
		}
	}
	for d in 0 ..< PC_DIRS {
		for i in 0 ..< PC_PER_DIR {
			rel := _pc_name(d, i)
			want := _pc_body("main" if v == .Switch else "other", d, i)
			if v == .Writes && rel == agent_rel {
				want = agent_body
			} else if v == .Writes && rel == person_rel {
				want = person_body
			}
			disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", PASS_CHUNK_ROOT, rel), context.temp_allocator)
			if derr != .None || string(disk) != string(want) {
				world_fail(w, "chunk %v: %s holds %q (%v), want %q", v, rel, string(disk), derr, string(want))
			}
			text, found, terr := fs.mount_synced_text(sm.m, rel, context.temp_allocator)
			if terr != .None || !found || string(text) != string(disk) {
				world_fail(w, "chunk %v: %s is synced as %q (found %v, %v), the work tree holds %q", v, rel, string(text), found, terr, string(disk))
			}
		}
	}
	if v == .Writes {
		h, herr := eng.tree_history(&n.e, tree)
		if herr != .None {
			world_fail(w, "chunk: tree_history: %v", herr)
			return
		}
		defer eng.tree_release(&n.e, tree)
		known := crdt.graph_known(&h.g, actor)
		if known == 0 {
			world_fail(w, "chunk: the agent's write between chunks was not credited to the agent")
			return
		}
		if sc, found, _ := fs.history_scope_of(h, crdt.Op_Id{actor, known - 1}); !found || sc != sid {
			world_fail(w, "chunk: the agent's write between chunks is attributed to scope %v (found %v), not its tool scope %v", sc, found, sid)
		}
	}
}

@(private = "file")
_pc_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(test)
pass_chunk_between :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for v in Pc_Variant {
		for seed in u64(1) ..= 3 {
			failures := pass_chunk_run(seed, v)
			for f in failures {
				fmt.eprintf("pass_chunk_between %v seed %d: %s\n", v, seed, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "pass_chunk_between %v seed %d failed", v, seed)
			delete(failures)
		}
	}
}

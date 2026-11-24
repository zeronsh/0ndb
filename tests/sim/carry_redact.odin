package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

CARRY_REDACT_ROOT :: "/work/carry-redact-git"
CARRY_REDACT_PLAIN :: "/work/carry-redact-plain"
CARRY_REDACT_LINE :: "agent secret line\n"

@(private = "file")
_cr_mount :: proc(n: ^Node, root: string) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == root && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_cr_cut :: proc(n: ^Node, cut: bool) {
	n.partitioned = cut
	if cut {
		for x in n.conns {
			conn_reset(x, true)
		}
	}
}

@(private = "file")
_cr_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

carry_redact_run :: proc(seed: u64, known: bool) -> (failures: [dynamic]string) {
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
	_carry_redact(w, known)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_carry_redact :: proc(w: ^World, known: bool) {
	a, b := w.nodes[0], w.nodes[1]
	if !relay_start(&w.relay) {
		world_fail(w, "carry redact: relay start")
		return
	}
	if !node_start(a) {
		world_fail(w, "carry redact: node start")
		return
	}
	m := &w.model
	va := disk_vfs(&a.disk)
	space: prim.Id
	tree: eng.Object
	setup: {
		context = instance_context(&a.inst)
		err: eng.Error
		space, err = eng.space_create(&a.e, "carry-redact", "relay", w.relay.public)
		if err != .None {
			world_fail(w, "carry redact: space_create: %v", err)
			return
		}
		eng.space_open(&a.e, space)
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "carry redact: tree_create: %v", err)
			return
		}
		node_after(a)
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
	if err := git_checkout_create(va, CARRY_REDACT_ROOT, files[:], when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry redact: git checkout: %v", err)
		return
	}
	feature := [?]Git_File{{name = "b.txt", data = transmute([]u8)string("feature b\n")}}
	if err := git_branch_commit(va, CARRY_REDACT_ROOT, "feature", feature[:], nil, when_s, node_clock(&a.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "carry redact: branch commit: %v", err)
		return
	}
	if err := node_mount(w, a, oi, CARRY_REDACT_ROOT); err != .None {
		world_fail(w, "carry redact: mount: %v", err)
		return
	}
	run_until(w, w.now + 2_000_000_000, true)
	if !node_start(b) {
		world_fail(w, "carry redact: second device start")
		return
	}
	join: {
		proof: []u8
		{
			context = instance_context(&a.inst)
			p, err := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
			node_after(a)
			if err != .None {
				world_fail(w, "carry redact: member_add: %v", err)
				return
			}
			proof = p
		}
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "carry-redact", "relay", w.relay.public); err != .None {
			world_fail(w, "carry redact: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "carry redact: space_open: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	prim.mkdir_all(disk_vfs(&b.disk), CARRY_REDACT_PLAIN, 0o755)
	if err := node_mount(w, b, oi, CARRY_REDACT_PLAIN); err != .None {
		world_fail(w, "carry redact: second mount: %v", err)
		return
	}
	run_until(w, w.now + 20_000_000_000, true)
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(va, CARRY_REDACT_ROOT, "feature", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "carry redact: checkout feature: %v %v", res, err)
		return
	}
	feature_step: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 2_000_000_000, true)
	agent := prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
	main_step: {
		context = instance_context(&a.inst)
		sm := _cr_mount(a, CARRY_REDACT_ROOT)
		if sm == nil || fs.mount_line(sm.m) != "git:refs/heads/feature" {
			world_fail(w, "carry redact: the mount did not follow feature")
			return
		}
		scope := fs.scope_open(a.reg, sm.m, prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng)), agent)
		if oerr := fs.mount_observe_begin(sm.m, "a.txt", scope); oerr != .None {
			world_fail(w, "carry redact: observe: %v", oerr)
			return
		}
		if werr := _cr_write(va, CARRY_REDACT_ROOT + "/a.txt", transmute([]u8)strings.concatenate({"shared a\n", CARRY_REDACT_LINE}, context.temp_allocator)); werr != .None {
			world_fail(w, "carry redact: agent write: %v", werr)
			return
		}
		if serr := fs.scope_close(a.reg, scope); serr != .None {
			world_fail(w, "carry redact: scope close: %v", serr)
			return
		}
		node_after(a)
	}
	run_until(w, w.now + 20_000_000_000, true)
	if !known {
		_cr_cut(a, true)
	}
	back := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(va, CARRY_REDACT_ROOT, "main", false, when_s, node_clock(&a.clock), rng_random(&w.rng), &back); res != .Done || err != .None {
		world_fail(w, "carry redact: checkout main: %v %v", res, err)
		return
	}
	agent_step: {
		context = instance_context(&a.inst)
		node_after(a)
	}
	run_until(w, w.now + 20_000_000_000, true)
	at_carry: [dynamic]u8
	carried: {
		context = instance_context(&a.inst)
		defer node_after(a)
		vc, verr := eng.tree_version(&a.e, tree, "main", context.temp_allocator)
		if verr != .None {
			world_fail(w, "carry redact: main version after the carry: %v", verr)
			return
		}
		vb := make([dynamic]u8, context.temp_allocator)
		fs.encode_version(&vb, vc)
		at_carry = make([dynamic]u8, w.allocator)
		tw := prim.writer(&at_carry)
		prim.write_bytes(&tw, vb[:])
		prim.write_str(&tw, "")
		prim.write_str(&tw, "")
		data, spans, berr := eng.tree_blame(&a.e, tree, "a.txt", context.temp_allocator, "main")
		if berr != .None {
			world_fail(w, "carry redact: blame a.txt on main: %v", berr)
			return
		}
		lo := strings.index(string(data), CARRY_REDACT_LINE)
		if lo < 0 {
			world_fail(w, "carry redact: main does not hold the carried line before the redaction: %q", string(data))
			return
		}
		at := 0
		for sp in spans {
			if at >= lo && at + sp.len <= lo + len(CARRY_REDACT_LINE) && sp.id.actor != agent {
				world_fail(w, "carry redact: the carried line on main blames to %s, not the agent %s", id_short(sp.id.actor), id_short(agent))
			}
			at += sp.len
		}
		if werr := _cr_write(va, CARRY_REDACT_ROOT + "/a.txt", transmute([]u8)string("shared a\nperson line\n")); werr != .None {
			world_fail(w, "carry redact: person rewrite: %v", werr)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	redact: {
		context = instance_context(&b.inst)
		defer node_after(b)
		sm := _cr_mount(b, CARRY_REDACT_PLAIN)
		if sm == nil {
			world_fail(w, "carry redact: second mount missing")
			return
		}
		v, verr := eng.tree_version(&b.e, tree, "git:refs/heads/feature", context.temp_allocator)
		if verr != .None {
			world_fail(w, "carry redact: feature version on the second device: %v", verr)
			return
		}
		data, rerr := eng.tree_read(&b.e, tree, "a.txt", context.temp_allocator, {}, "git:refs/heads/feature")
		lo := strings.index(string(data), CARRY_REDACT_LINE)
		if rerr != .None || lo < 0 {
			world_fail(w, "carry redact: the second device does not hold the agent's line on feature: %v %q", rerr, string(data))
			return
		}
		_ = v
		if err := eng.tree_redact(&b.e, tree, "a.txt", lo, lo + len(CARRY_REDACT_LINE), "git:refs/heads/feature"); err != .None {
			world_fail(w, "carry redact: redact on the second device: %v", err)
			return
		}
	}
	if !known {
		_cr_cut(a, false)
	}
	run_until(w, w.now + 60_000_000_000, true)
	secret := transmute([]u8)string(CARRY_REDACT_LINE[:len(CARRY_REDACT_LINE) - 1])
	for n in ([]^Node{a, b}) {
		context = instance_context(&n.inst)
		defer node_after(n)
		for line in ([]string{"main", "git:refs/heads/feature"}) {
			data, spans, berr := eng.tree_blame(&n.e, tree, "a.txt", context.temp_allocator, line)
			if berr != .None {
				world_fail(w, "carry redact: %s blame a.txt on %s: %v", n.name, line, berr)
				continue
			}
			if strings.contains(string(data), string(secret)) {
				world_fail(w, "carry redact: %s still reads the redacted line in a.txt on %s (known %v): %q", n.name, line, known, string(data))
			}
			at := 0
			for sp in spans {
				if !sp.redacted && at < len(data) && data[at] == 0 {
					world_fail(w, "carry redact: %s a.txt on %s holds zeroed bytes not marked redacted at %d", n.name, line, at)
				}
				at += sp.len
			}
		}
		old, oerr := eng.tree_read(&n.e, tree, "a.txt", context.temp_allocator, {}, "main", at_carry[:])
		if oerr != .None {
			world_fail(w, "carry redact: %s read a.txt at the carry: %v", n.name, oerr)
		} else if strings.contains(string(old), string(secret)) || !strings.has_prefix(string(old), "shared a\n") || len(old) != len("shared a\n") + len(CARRY_REDACT_LINE) {
			world_fail(w, "carry redact: %s reads a.txt at the carry as %q (known %v), not the carried line redacted", n.name, string(old), known)
		}
		stored := make([dynamic]Disk_File, context.temp_allocator)
		disk_walk(&n.disk, &stored)
		for f in stored {
			if !strings.has_prefix(f.path, "/data") || strings.has_prefix(f.path, "/data/objects/") {
				continue
			}
			if strings.contains(string(f.data), string(secret)) {
				world_fail(w, "carry redact: %s keeps the redacted line in %s (known %v)", n.name, f.path, known)
			}
		}
	}
}

@(test)
carry_redact :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for known in ([]bool{true, false}) {
		failures := carry_redact_run(1, known)
		for f in failures {
			fmt.eprintf("carry_redact (known %v): %s\n", known, f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0, fmt.tprintf("carry_redact (known %v) failed", known))
		delete(failures)
	}
}

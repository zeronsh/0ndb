package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/odb"
import "../../src/prim"

INDEX_TRUST_ROOT :: "/work/trust-n0-git"

@(private = "file")
it_files := 60

@(private = "file")
_it_name :: proc(i: int) -> string {
	return fmt.tprintf("f%03d.txt", i)
}

@(private = "file")
_it_racy :: proc(i: int) -> bool {
	return i % 3 == 0
}

@(private = "file")
_it_body :: proc(tag: string, i: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for j in 0 ..< 1 + i % 7 {
		fmt.sbprintf(&b, "%s %03d line %d\n", tag, i, j)
	}
	return b.buf[:]
}

index_trust_run :: proc(seed: u64, crash_at: u64, budget: int) -> (failures: [dynamic]string, crashed: bool) {
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
	cfg.index_trust = true
	cfg.pass_budget = budget
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	crashed = _it_case(w, crash_at)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_it_mount :: proc(n: ^Node) -> ^Sim_Mount {
	for &x in n.mounts {
		if x.root == INDEX_TRUST_ROOT && x.m != nil {
			return &x
		}
	}
	return nil
}

@(private = "file")
_it_case :: proc(w: ^World, crash_at: u64) -> (crashed: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "trust: node start")
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "trust")
		if err != .None {
			world_fail(w, "trust: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "trust: tree_create: %v", err)
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
	for i in 0 ..< it_files {
		append(&main_files, Git_File{name = _it_name(i), data = _it_body("main", i)})
		append(&other_files, Git_File{name = _it_name(i), data = _it_body("other", i)})
	}
	when_s := clock_wall(&n.clock) / 1_000_000_000
	if err := git_checkout_create(vfs, INDEX_TRUST_ROOT, main_files[:], when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "trust: git checkout: %v", err)
		return
	}
	if err := git_branch_commit(vfs, INDEX_TRUST_ROOT, "other", other_files[:], nil, when_s, node_clock(&n.clock), rng_random(&w.rng)); err != .None {
		world_fail(w, "trust: branch commit: %v", err)
		return
	}
	if err := node_mount(w, n, oi, INDEX_TRUST_ROOT); err != .None {
		world_fail(w, "trust: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(INDEX_TRUST_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _it_mount(n) == nil {
		world_fail(w, "trust: the mount is missing after its import")
		return
	}
	changes := make([dynamic]Git_Change, context.temp_allocator)
	if res, err := git_checkout(vfs, INDEX_TRUST_ROOT, "other", false, when_s, node_clock(&n.clock), rng_random(&w.rng), &changes); res != .Done || err != .None {
		world_fail(w, "trust: checkout other: %v %v", res, err)
		return
	}
	past := clock_wall(&n.clock) - 3_000_000_000
	for i in 0 ..< it_files {
		if !_it_racy(i) {
			if err := prim.set_times(vfs, fmt.tprintf("%s/%s", INDEX_TRUST_ROOT, _it_name(i)), past, past); err != .None {
				world_fail(w, "trust: set_times %s: %v", _it_name(i), err)
				return
			}
		}
	}
	if err := git_index_refresh(vfs, INDEX_TRUST_ROOT); err != .None {
		world_fail(w, "trust: index refresh: %v", err)
		return
	}
	for i in 0 ..< it_files {
		if _it_racy(i) {
			if err := _it_write(vfs, fmt.tprintf("%s/%s", INDEX_TRUST_ROOT, _it_name(i)), _it_body("OTHER", i)); err != .None {
				world_fail(w, "trust: racy rewrite %s: %v", _it_name(i), err)
				return
			}
		}
	}
	if !_it_precondition(w, n, vfs) {
		return
	}
	crashes := w.stats.crashes
	if crash_at > 0 {
		n.disk.crash_at = n.disk.stats.ops + crash_at
	}
	step: {
		context = instance_context(&n.inst)
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "trust: node did not come back after a crash at op %d of the pass", crash_at)
		return
	}
	sm := _it_mount(n)
	if sm == nil {
		world_fail(w, "trust: mount missing after a crash at op %d of the pass", crash_at)
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	if !crashed {
		racy := 0
		for i in 0 ..< it_files {
			if _it_racy(i) {
				racy += 1
			}
		}
		if sm.m.trust_reads < it_files - racy || sm.m.trust_refused < racy {
			world_fail(w, "trust: the pass after the checkout read %d files from the index (want %d) and refused %d (want %d racy)", sm.m.trust_reads, it_files - racy, sm.m.trust_refused, racy)
		}
	}
	for i in 0 ..< it_files {
		name := _it_name(i)
		disk, derr := prim.read_file(vfs, fmt.tprintf("%s/%s", INDEX_TRUST_ROOT, name), context.temp_allocator)
		text, found, terr := fs.mount_synced_text(sm.m, name, context.temp_allocator)
		want := _it_body("OTHER" if _it_racy(i) else "other", i)
		if derr == .None && string(disk) != string(want) {
			world_fail(w, "trust: after a crash at op %d (crashed %v) %s holds %q, not the %q git checked out", crash_at, crashed, name, string(disk), string(want))
		}
		if derr != .None || terr != .None || !found || string(text) != string(disk) {
			world_fail(w, "trust: after a crash at op %d (crashed %v) %s (racy %v) is synced as %q (found %v, %v), the work tree holds %q (%v)", crash_at, crashed, name, _it_racy(i), string(text), found, terr, string(disk), derr)
		}
	}
	return
}

@(private = "file")
_it_precondition :: proc(w: ^World, n: ^Node, vfs: prim.Vfs) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	r: fs.Index_Reader
	if err := fs.index_open(&r, vfs, INDEX_TRUST_ROOT + "/.git", .Sha1, context.temp_allocator); err != .None {
		world_fail(w, "trust: index open: %v", err)
		return false
	}
	defer fs.index_close(&r)
	index_mtime := fs.index_file_mtime_ns(&r)
	racy := make(map[string]bool, context.temp_allocator)
	for i in 0 ..< it_files {
		racy[_it_name(i)] = _it_racy(i)
	}
	seen := 0
	for {
		e, ok, err := fs.index_next(&r)
		if err != .None {
			world_fail(w, "trust: index read: %v", err)
			return false
		}
		if !ok {
			break
		}
		want_racy, known := racy[e.path]
		if !known {
			continue
		}
		seen += 1
		path := fmt.tprintf("%s/%s", INDEX_TRUST_ROOT, e.path)
		st, serr := prim.stat(vfs, path)
		data, derr := prim.read_file(vfs, path, context.temp_allocator)
		h, herr := odb.hash(.Sha1, .Blob, data)
		if serr != .None || derr != .None || herr != .None {
			world_fail(w, "trust: %s unreadable: %v %v %v", e.path, serr, derr, herr)
			return false
		}
		mtime := i64(e.mtime_s) * 1_000_000_000 + i64(e.mtime_ns)
		ctime := i64(e.ctime_s) * 1_000_000_000 + i64(e.ctime_ns)
		stats := mtime == st.mtime_ns && ctime == st.ctime_ns && u32(st.size) == e.size && u32(st.ino) == e.ino
		is_racy := mtime >= index_mtime
		if !stats || is_racy != want_racy || (h == e.oid) == want_racy {
			world_fail(w, "trust: %s is not set up as a %s entry: stats match %v, racy %v, content matches the index %v", e.path, "racy" if want_racy else "clean", stats, is_racy, h == e.oid)
			return false
		}
	}
	if seen != it_files {
		world_fail(w, "trust: the index holds %d of the %d files", seen, it_files)
		return false
	}
	return true
}

@(private = "file")
_it_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(test)
index_trust_pass :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for budget in ([]int{1024, 6}) {
		it_files = 60 if budget > 6 else 20
		done := false
		for k := u64(0); k <= 20000 && !done; k += 1 {
			failures, crashed := index_trust_run(1, k, budget)
			for f in failures {
				fmt.eprintf("index_trust_pass budget %d at disk op %d: %s\n", budget, k, f)
				delete(f)
			}
			testing.expect(t, len(failures) == 0, fmt.tprintf("index_trust_pass budget %d at disk op %d failed", budget, k))
			n := len(failures)
			delete(failures)
			if n > 0 {
				return
			}
			if k > 0 && !crashed {
				fmt.eprintf("index_trust_pass budget %d: %d crash points\n", budget, k - 1)
				done = true
			}
		}
		testing.expect(t, done, fmt.tprintf("index_trust_pass budget %d: the pass never completed without a crash", budget))
	}
}

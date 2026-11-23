package sim

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
BW_ROOT :: "/work/based-n0"

@(private = "file")
_bw_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	return err
}

@(private = "file")
_bw_case :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_bw_run(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_bw_run :: proc(w: ^World) {
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "based write: node start")
		return
	}
	vfs := disk_vfs(&a.disk)
	tree: eng.Object
	m: ^fs.Mount
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "based")
		if err != .None {
			world_fail(w, "based write: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "based write: space_open: %v", err)
			return
		}
		if tree, err = eng.tree_create(&a.e, space, "work"); err != .None {
			world_fail(w, "based write: tree_create: %v", err)
			return
		}
		reg, rerr := eng.registry(&a.e)
		if rerr != .None {
			world_fail(w, "based write: registry: %v", rerr)
			return
		}
		a.reg = reg
		if prim.mkdir_all(vfs, BW_ROOT, 0o755) != .None {
			world_fail(w, "based write: mkdir")
			return
		}
		if m, err = eng.tree_mount(&a.e, tree, BW_ROOT); err != .None && !(err == .Pending && m != nil) {
			world_fail(w, "based write: tree_mount: %v", err)
			return
		}
		if _bw_write(vfs, BW_ROOT + "/a.txt", "<p68>\n") != .None {
			world_fail(w, "based write: first person write")
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	base: fs.Version
	cur: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		rerr: eng.Error
		cur, rerr = eng.tree_read(&a.e, tree, "a.txt", w.allocator, {}, "", nil, &base)
		base = slice.clone(base, w.allocator) or_else nil
		if rerr != .None || string(cur) != "<p68>\n" {
			world_fail(w, "based write: a.txt reads %q (%v) after the first person write was ingested", string(cur), rerr)
			return
		}
		if _bw_write(vfs, BW_ROOT + "/a.txt", "<p96>\n") != .None || _bw_write(vfs, BW_ROOT + "/a.txt", "<p97>\n") != .None {
			world_fail(w, "based write: second person write")
			return
		}
	}
	defer delete(cur, w.allocator)
	defer delete(base, w.allocator)
	run_until(w, w.now + 1_000_000, false)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		if _, dirty := m.dirty["a.txt"]; !dirty {
			world_fail(w, "based write: the person's rewrite of a.txt is not dirty in the mount before the hold")
			return
		}
		scope := fs.scope_open(a.reg, m, prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng)), prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng)))
		fs.scope_write_begin(scope, "a.txt")
		if !fs.scope_pinned(scope, "a.txt") {
			world_fail(w, "based write: the hold pinned nothing")
			return
		}
		synced, found, serr := fs.mount_synced_text(m, "a.txt", context.temp_allocator)
		if serr != .None || !found || string(synced) != "<p97>\n" {
			world_fail(w, "based write: the hold's pin did not ingest the person's p97 before the write (synced %q, %v %v)", string(synced), found, serr)
			return
		}
		data := strings.concatenate({string(cur), "<k103>\n"}, context.temp_allocator)
		if werr := eng.tree_write(&a.e, tree, "a.txt", transmute([]u8)data, base); werr != .None {
			world_fail(w, "based write: tree_write: %v", werr)
			return
		}
		fs.scope_close(a.reg, scope)
	}
	run_until(w, w.now + 5_000_000_000, true)
	context = instance_context(&a.inst)
	defer node_after(a)
	got, gerr := eng.tree_read(&a.e, tree, "a.txt", context.temp_allocator)
	if gerr != .None {
		world_fail(w, "based write: final read: %v", gerr)
		return
	}
	text := string(got)
	if !strings.contains(text, "<p97>") || !strings.contains(text, "<k103>") || strings.contains(text, "<p68>") {
		world_fail(w, "based write: a write based on the read of p68 must keep the person's p97 ingested after that read, add k103 and not bring p68 back, but a.txt is %q", text)
	}
}

@(test)
based_write :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 4 {
		failures := _bw_case(seed)
		for f in failures {
			fmt.eprintf("based_write seed %d: %s\n", seed, f)
			delete(f)
		}
		testing.expectf(t, len(failures) == 0, "based_write seed %d failed", seed)
		delete(failures)
	}
	free_all(context.temp_allocator)
}

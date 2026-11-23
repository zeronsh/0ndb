package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"

LOCAL_FILES :: [?]string{"a.txt", "b.txt"}
LOCAL_ROOT :: "/work/local-n0"

local_first_run :: proc(seed: u64) -> (failures: [dynamic]string) {
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
	_local_first(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_local_first :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	tree, text: eng.Object
	{
		context = instance_context(&a.inst)
		id, err := eng.space_create(&a.e, "local")
		if err != .None {
			world_fail(w, "local: space_create: %v", err)
			return
		}
		space = id
		if oerr := eng.space_open(&a.e, space); oerr != .None {
			world_fail(w, "local: space_open: %v", oerr)
			return
		}
		tree, err = eng.tree_create(&a.e, space, "work")
		if err != .None {
			world_fail(w, "local: tree_create: %v", err)
			return
		}
		if a.reg == nil {
			reg, rerr := eng.registry(&a.e)
			if rerr != .None {
				world_fail(w, "local: registry: %v", rerr)
				return
			}
			a.reg = reg
		}
		vfs := disk_vfs(&a.disk)
		if merr := prim.mkdir_all(vfs, LOCAL_ROOT, 0o755); merr != .None {
			world_fail(w, "local: mkdir: %v", merr)
			return
		}
		if lm, merr := eng.tree_mount(&a.e, tree, LOCAL_ROOT); merr != .None && !(merr == .Pending && lm != nil) {
			world_fail(w, "local: tree_mount: %v", merr)
			return
		}
		for f in LOCAL_FILES {
			path := fmt.tprintf("%s/%s", LOCAL_ROOT, f)
			data := transmute([]u8)fmt.tprintf("written on disk local-only into %s\n", f)
			if werr := _local_write(vfs, path, data); werr != .None {
				world_fail(w, "local: disk write %s: %v", f, werr)
			}
		}
		text, err = eng.text_create(&a.e, space, "notes", "written local-only")
		if err != .None {
			world_fail(w, "local: text_create: %v", err)
			return
		}
		node_after(a)
	}
	run_until(w, w.now + 5_000_000_000, true)
	{
		context = instance_context(&a.inst)
		if err := eng.space_set_relay(&a.e, space, "relay", w.relay.public); err != .None {
			world_fail(w, "local: space_set_relay: %v", err)
			return
		}
		node_after(a)
	}
	proof: []u8
	{
		context = instance_context(&a.inst)
		p, err := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if err != .None {
			world_fail(w, "local: member_add: %v", err)
			return
		}
		proof = p
		node_after(a)
	}
	{
		context = instance_context(&b.inst)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "local", "relay", w.relay.public); err != .None {
			world_fail(w, "local: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "local: n1 space_open: %v", err)
			return
		}
		node_after(b)
	}
	want := make(map[string]string, 4, w.allocator)
	{
		context = instance_context(&a.inst)
		for f in LOCAL_FILES {
			data, err := eng.tree_read(&a.e, tree, f, w.allocator)
			if err != .None {
				world_fail(w, "local: n0 reads its own %s: %v", f, err)
				return
			}
			want[f] = string(data)
		}
		data, err := eng.text_read(&a.e, text, w.allocator)
		if err != .None {
			world_fail(w, "local: n0 reads its own text: %v", err)
			return
		}
		want["text"] = string(data)
		node_after(a)
	}
	got := make(map[string]string, 4, w.allocator)
	for _ in 0 ..< 120 {
		run_until(w, w.now + 2_000_000_000, false)
		context = instance_context(&b.inst)
		for f in LOCAL_FILES {
			if _, done := got[f]; done {
				continue
			}
			if data, err := eng.tree_read(&b.e, tree, f, w.allocator); err == .None {
				got[f] = string(data)
			}
		}
		if _, done := got["text"]; !done {
			if data, err := eng.text_read(&b.e, text, w.allocator); err == .None && len(data) > 0 {
				got["text"] = string(data)
			}
		}
		node_after(b)
		if len(got) == len(want) {
			break
		}
	}
	for k, v in want {
		g, ok := got[k]
		if !ok {
			world_fail(w, "local: n1 never read %s that n0 wrote before it had a relay", k)
		} else if g != v {
			world_fail(w, "local: n1 reads %s as %q, n0 wrote %q", k, g, v)
		}
	}
	run_until(w, w.now + 60_000_000_000, true)
	{
		context = instance_context(&a.inst)
		notes, err := eng.verify_uploaded(&a.e, context.temp_allocator)
		if err != .None {
			world_fail(w, "local: verify_uploaded: %v", err)
		}
		for x in notes {
			world_fail(w, "local: n0 %s", x)
		}
		node_after(a)
	}
	return
}

@(test)
local_first :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for seed in u64(1) ..= 3 {
		failures := local_first_run(seed)
		for f in failures {
			fmt.eprintf("local_first seed %d: %s\n", seed, f)
			delete(f)
		}
		testing.expect(t, len(failures) == 0, fmt.tprintf("local_first seed %d failed", seed))
		delete(failures)
	}
}

@(private = "file")
_local_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	if err != .None {
		return err
	}
	return prim.sync_dir(vfs, prim.dir_name(path))
}

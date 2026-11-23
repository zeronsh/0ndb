package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
MM_ROOT :: "/work/midway-n0"

@(private = "file")
MM_FILES :: [?]string{"a.txt", "b.txt", "c.txt", "d.txt", "e.txt"}

@(private = "file")
MM_NEW :: [?]string{"d3/n1.txt", "d3/n2.txt", "d4/n3.txt"}

@(private = "file")
MM_GONE :: [?]string{"d1/x.txt", "d1/y.txt"}

@(private = "file")
_mm_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	return err
}

@(private = "file")
Mm_Mode :: enum u8 {
	None,
	Process,
	Power,
	Hold,
	Dirs,
	Midcrash,
	Dirs_Power,
}

@(private = "file")
Mm_Case :: struct {
	seed: u64,
	k:    u64,
	mode: Mm_Mode,
}

@(private = "file")
_mm_case :: proc(c: Mm_Case) -> (failed_pass: bool, failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(c.seed)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 1
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	failed_pass = _mm_run(w, c)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_mm_run :: proc(w: ^World, c: Mm_Case) -> (failed_pass: bool) {
	a := w.nodes[0]
	if !node_start(a) {
		world_fail(w, "midway: node start")
		return
	}
	vfs := disk_vfs(&a.disk)
	files := MM_FILES
	tree: eng.Object
	m: ^fs.Mount
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		space, err := eng.space_create(&a.e, "midway")
		if err == .None {
			err = eng.space_open(&a.e, space)
		}
		if err == .None {
			tree, err = eng.tree_create(&a.e, space, "work")
		}
		if err != .None {
			world_fail(w, "midway: setup: %v", err)
			return
		}
		reg, rerr := eng.registry(&a.e)
		if rerr != .None {
			world_fail(w, "midway: registry: %v", rerr)
			return
		}
		a.reg = reg
		if prim.mkdir_all(vfs, MM_ROOT, 0o755) != .None {
			world_fail(w, "midway: mkdir")
			return
		}
		if m, err = eng.tree_mount(&a.e, tree, MM_ROOT); err != .None && err != .Pending {
			world_fail(w, "midway: tree_mount: %v", err)
			return
		}
		for f in files {
			if _mm_write(vfs, fmt.tprintf("%s/%s", MM_ROOT, f), fmt.tprintf("<o.%s>\n", f)) != .None {
				world_fail(w, "midway: setup write %s", f)
				return
			}
		}
		if c.mode == .Dirs || c.mode == .Dirs_Power {
			if prim.mkdir_all(vfs, MM_ROOT + "/d1", 0o755) != .None {
				world_fail(w, "midway: mkdir d1")
				return
			}
			for f in MM_GONE {
				if _mm_write(vfs, fmt.tprintf("%s/%s", MM_ROOT, f), fmt.tprintf("<o.%s>\n", f)) != .None {
					world_fail(w, "midway: setup write %s", f)
					return
				}
			}
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	typed := make(map[string]string, len(files), w.allocator)
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		for f in files {
			tok := fmt.aprintf("<t.%s>", f, allocator = w.allocator)
			typed[f] = tok
			if err := eng.tree_write(&a.e, tree, f, transmute([]u8)fmt.tprintf("<o.%s>\n%s\n", f, tok)); err != .None {
				world_fail(w, "midway: tree_write %s: %v", f, err)
				return
			}
		}
		if c.mode == .Dirs || c.mode == .Dirs_Power {
			for f in MM_NEW {
				tok := fmt.aprintf("<t.%s>", f, allocator = w.allocator)
				typed[f] = tok
				if err := eng.tree_write(&a.e, tree, f, transmute([]u8)fmt.tprintf("%s\n", tok)); err != .None {
					world_fail(w, "midway: tree_write %s: %v", f, err)
					return
				}
			}
			for f in MM_GONE {
				if err := eng.tree_remove(&a.e, tree, f); err != .None {
					world_fail(w, "midway: tree_remove %s: %v", f, err)
					return
				}
			}
		}
		a.disk.fail_root = MM_ROOT
		a.disk.fail_nth = c.k
		a.disk.fail_stick = c.mode == .Midcrash
	}
	injected := a.disk.stats.injected
	inc := a.incarnation
	for _ in 0 ..< 400 {
		if a.disk.stats.injected > injected {
			break
		}
		run_until(w, w.now + 1_000_000, false)
	}
	a.disk.fail_nth = 0
	a.disk.fail_stick = false
	failed_pass = a.disk.stats.injected > injected
	person := make(map[string]string, len(files), w.allocator)
	scope: ^fs.Scope
	held := ""
	if failed_pass && a.alive && c.mode == .Hold {
		context = instance_context(&a.inst)
		defer node_after(a)
		a.disk.quiet = true
		for f in files {
			cur, err := prim.read_file(vfs, fmt.tprintf("%s/%s", MM_ROOT, f), context.temp_allocator)
			if err == .None && strings.contains(string(cur), typed[f]) {
				held = f
				break
			}
		}
		a.disk.quiet = false
		if len(held) > 0 {
			sid := prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
			actor := prim.id_new_with(node_clock(&a.clock), rng_random(&w.rng))
			scope = fs.scope_open(a.reg, m, sid, actor)
			fs.scope_write_begin(scope, held)
		}
	}
	if failed_pass && a.alive && c.mode != .Midcrash && c.mode != .Dirs_Power {
		context = instance_context(&a.inst)
		defer node_after(a)
		a.disk.quiet = true
		for f in files {
			abs := fmt.tprintf("%s/%s", MM_ROOT, f)
			cur, err := prim.read_file(vfs, abs, context.temp_allocator)
			if err != .None || strings.contains(string(cur), typed[f]) {
				continue
			}
			tok := fmt.aprintf("<p.%s>", f, allocator = w.allocator)
			person[f] = tok
			a.disk.quiet = false
			_mm_write(vfs, abs, fmt.tprintf("%s%s\n", string(cur), tok))
			a.disk.quiet = true
		}
		a.disk.quiet = false
	}
	if failed_pass && a.alive && a.incarnation == inc && c.mode != .Midcrash && c.mode != .Hold && c.mode != .Dirs_Power {
		passes := m.passes
		for _ in 0 ..< 400 {
			if !a.alive || a.incarnation != inc {
				break
			}
			if m.passes != passes {
				passes = m.passes
				context = instance_context(&a.inst)
				out := make([dynamic]string, context.temp_allocator)
				a.disk.quiet = true
				merr := fs.mount_synced_mismatches(m, &out, context.temp_allocator)
				a.disk.quiet = false
				if merr == .None {
					for x in out {
						world_fail(w, "midway: at a pass after a materialize failed at op %d (%v) the synced version names what is neither on disk nor owed: %s", c.k, c.mode, x)
					}
				}
				if len(fs.mount_absent(m)) == 0 {
					break
				}
			}
			run_until(w, w.now + 1_000_000, false)
		}
	}
	if failed_pass && a.alive && (c.mode == .Process || c.mode == .Power || c.mode == .Midcrash || c.mode == .Dirs_Power) {
		node_crash_now(a, .Power if c.mode == .Power || c.mode == .Dirs_Power else .Process, c.k)
		if c.mode == .Midcrash {
			_mm_write(vfs, MM_ROOT + "/.0ndb-tmp-999", "left by a crashed pass\n")
			_mm_write(vfs, MM_ROOT + "/.0ndb-tmp-9x", "a user's file\n")
		}
	}
	a.disk.fail_stuck = false
	a.disk.fail_root = ""
	run_until(w, w.now + 10_000_000_000, true)
	if scope != nil && a.alive && a.incarnation == inc {
		context = instance_context(&a.inst)
		out := make([dynamic]string, context.temp_allocator)
		a.disk.quiet = true
		merr := fs.mount_synced_mismatches(m, &out, context.temp_allocator)
		a.disk.quiet = false
		if merr == .None {
			for x in out {
				world_fail(w, "midway: while %s is held after a materialize failed at op %d the synced version is not what is on disk: %s", held, c.k, x)
			}
		}
		fs.scope_close(a.reg, scope)
		node_after(a)
		run_until(w, w.now + 10_000_000_000, true)
	}
	for _ in 0 ..< 40 {
		if a.alive {
			break
		}
		run_until(w, w.now + 1_000_000_000, false)
	}
	if !a.alive {
		world_fail(w, "midway: n0 did not come back after the failed pass at op %d", c.k)
		return
	}
	context = instance_context(&a.inst)
	defer node_after(a)
	if a.incarnation != inc {
		if a.reg == nil {
			reg, rerr := eng.registry(&a.e)
			if rerr != .None {
				world_fail(w, "midway: registry after restart: %v", rerr)
				return
			}
			a.reg = reg
		}
		err: eng.Error
		if m, err = eng.tree_mount(&a.e, tree, MM_ROOT); err != .None && err != .Pending {
			world_fail(w, "midway: remount after the failed pass at op %d: %v", c.k, err)
			return
		}
		run_until(w, w.now + 10_000_000_000, true)
		context = instance_context(&a.inst)
	}
	for f in files {
		data, err := eng.tree_read(&a.e, tree, f, context.temp_allocator)
		if err != .None {
			world_fail(w, "midway: %s unreadable after the failed pass at op %d: %v", f, c.k, err)
			continue
		}
		want := []string{typed[f], person[f] if f in person else ""}
		for tok in want {
			if len(tok) == 0 {
				continue
			}
			if n := strings.count(string(data), tok); n != 1 {
				world_fail(w, "midway: %s holds %s %d times after a materialize failed at op %d (%v), want once: %q", f, tok, n, c.k, c.mode, string(data))
			}
		}
	}
	if c.mode == .Dirs || c.mode == .Dirs_Power {
		for f in MM_NEW {
			data, err := eng.tree_read(&a.e, tree, f, context.temp_allocator)
			if err != .None || strings.count(string(data), typed[f]) != 1 {
				world_fail(w, "midway: %s reads %q (%v) after a materialize that creates directories failed at op %d, want %s once", f, string(data), err, c.k, typed[f])
			}
		}
		for f in MM_GONE {
			if _, err := eng.tree_read(&a.e, tree, f, context.temp_allocator); err != .Not_Found {
				world_fail(w, "midway: %s is still in the tree (%v) after a materialize that removes it failed at op %d", f, err, c.k)
			}
		}
	}
	out := make([dynamic]string, context.temp_allocator)
	a.disk.quiet = true
	merr := fs.mount_synced_mismatches(m, &out, context.temp_allocator)
	d: prim.Dir
	lookalike := false
	if prim.dir_open(vfs, &d, MM_ROOT, context.temp_allocator) == .None {
		for {
			de, more, derr := prim.dir_next(vfs, &d)
			if derr != .None || !more {
				break
			}
			if fs.name_our_temp(de.name) {
				world_fail(w, "midway: %s/%s is left on disk after a materialize failed at op %d (%v)", MM_ROOT, de.name, c.k, c.mode)
			}
			if de.name == ".0ndb-tmp-9x" {
				lookalike = true
			}
		}
		prim.dir_close(vfs, &d)
	}
	a.disk.quiet = false
	if c.mode == .Midcrash && failed_pass && !lookalike {
		world_fail(w, "midway: the sweep after a crash at op %d removed %s/.0ndb-tmp-9x, which is not a temp of ours", c.k, MM_ROOT)
	}
	if merr == .None {
		for x in out {
			world_fail(w, "midway: after a materialize failed at op %d (%v) the synced version is not what is on disk: %s", c.k, c.mode, x)
		}
	}
	if owed := fs.mount_absent(m); len(owed) > 0 {
		world_fail(w, "midway: after a materialize failed at op %d (%v) and a clean pass, %d paths are still owed: %v", c.k, c.mode, len(owed), owed)
	}
	return
}

@(test)
materialize_midway :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for mode in Mm_Mode {
		for k := u64(1); k < 2000; k += 1 {
			failed, failures := _mm_case(Mm_Case{seed = 1, k = k, mode = mode})
			for f in failures {
				fmt.eprintf("materialize_midway %v op %d: %s\n", mode, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "materialize_midway %v op %d failed", mode, k)
			n := len(failures)
			delete(failures)
			if !failed || n > 0 {
				break
			}
		}
	}
	free_all(context.temp_allocator)
}

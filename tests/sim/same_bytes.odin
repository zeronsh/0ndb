package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
SB_ROOT :: "/work/same-bytes-n0"

@(private = "file")
Sb_Case :: enum u8 {
	Marked_Only,
	Same_Bytes,
	Full_Write_From_V0,
	Marked_Then_Full_Write,
	Replaced,
	Moved,
}

@(private = "file")
_sb_put :: proc(n: ^Node, data: string) {
	vfs := disk_vfs(&n.disk)
	fd, err := prim.open_file(vfs, SB_ROOT + "/b.txt", {.Write, .Create, .Truncate}, 0o644)
	if err == .None {
		err = prim.write_at(vfs, fd, transmute([]u8)data, 0)
		prim.close_file(vfs, fd)
	}
	if err != .None {
		world_fail(n.w, "same bytes: write b.txt: %v", err)
	}
}

@(private = "file")
_sb_run :: proc(w: ^World, c: Sb_Case, grain: i64) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "same bytes: node start")
		return
	}
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	m: ^fs.Mount
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "same-bytes")
		if err == .None {
			err = eng.space_open(&n.e, space)
		}
		if err == .None {
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		reg, rerr := eng.registry(&n.e)
		if err != .None || rerr != .None || prim.mkdir_all(vfs, SB_ROOT, 0o755) != .None {
			world_fail(w, "same bytes: setup: %v %v", err, rerr)
			return
		}
		n.reg = reg
		disk_set_grain(&n.disk, SB_ROOT, grain)
		_sb_put(n, "v0\n")
		if m, err = eng.tree_mount(&n.e, tree, SB_ROOT); err != .None && !(err == .Pending && m != nil) {
			world_fail(w, "same bytes: tree_mount: %v", err)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	scope: ^fs.Scope
	racy, same := false, false
	consumer: {
		context = instance_context(&n.inst)
		defer node_after(n)
		scope = fs.scope_open(n.reg, m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
		fs.scope_read_base(scope, "b.txt", transmute([]u8)string("v0\n"))
		base: fs.Version
		if _, err := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator, {}, "", nil, &base); err != .None {
			world_fail(w, "same bytes: tree_read: %v", err)
			return
		}
		if err := eng.tree_write(&n.e, tree, "b.txt", transmute([]u8)string("v0\nconsumer v1\n"), base); err != .None {
			world_fail(w, "same bytes: tree_write: %v", err)
			return
		}
	}
	run_until(w, w.now + 50_000_000, true)
	agent_acts: {
		context = instance_context(&n.inst)
		defer node_after(n)
		disk, _ := prim.read_file(vfs, SB_ROOT + "/b.txt", context.temp_allocator)
		if string(disk) != "v0\nconsumer v1\n" {
			world_fail(w, "same bytes: the consumer's write is not on disk (%q)", string(disk))
			return
		}
		if c == .Replaced || c == .Moved {
			to := SB_ROOT + "/b.txt" if c == .Replaced else SB_ROOT + "/c.txt"
			fs.mount_observe_begin(m, "b.txt", scope)
			if c == .Moved {
				fs.mount_observe_begin(m, "c.txt", scope)
			}
			from := SB_ROOT + "/b.txt"
			if c == .Replaced {
				from = SB_ROOT + "/b.tmp"
				if fd, err := prim.open_file(vfs, from, {.Write, .Create, .Truncate}, 0o755); err == .None {
					prim.write_at(vfs, fd, transmute([]u8)string("v0\nconsumer v1\n"), 0)
					prim.close_file(vfs, fd)
				}
			}
			if err := prim.rename(vfs, from, to); err != .None {
				world_fail(w, "same bytes %v: rename: %v", c, err)
			}
		}
		if c == .Same_Bytes || c == .Full_Write_From_V0 {
			fs.mount_observe_begin(m, "b.txt", scope)
			n.writers[strings.clone(SB_ROOT + "/b.txt", w.allocator)] = Writer_Info{scope = scope, agent = true}
			_sb_put(n, "v0\nconsumer v1\n" if c == .Same_Bytes else "v0\nagent text\n")
		}
		if e, found, serr := fs.shadow_get(&m.shadow, "b.txt"); serr == .None && found {
			racy = e.racy
			st, _ := prim.lstat(vfs, SB_ROOT + "/b.txt")
			same = st.size == e.stat.size && st.mtime_ns == e.stat.mtime_ns && st.ctime_ns == e.stat.ctime_ns && st.ino == e.stat.ino
		}
		fs.mount_mark(m, "b.txt", scope)
		if c == .Moved {
			fs.mount_mark(m, "c.txt", scope)
		}
		if c == .Marked_Then_Full_Write {
			fs.mount_sync(m)
			fs.mount_observe_begin(m, "b.txt", scope)
			_sb_put(n, "v0\nagent text\n")
			fs.mount_mark(m, "b.txt", scope)
		}
		fs.scope_close(n.reg, scope)
		if c == .Same_Bytes || c == .Full_Write_From_V0 {
			key, _ := delete_key(&n.writers, SB_ROOT + "/b.txt")
			delete(key, w.allocator)
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	context = instance_context(&n.inst)
	defer node_after(n)
	name := "c.txt" if c == .Moved else "b.txt"
	if c == .Moved {
		if _, gone := eng.tree_read(&n.e, tree, "b.txt", context.temp_allocator); gone != .Not_Found {
			world_fail(w, "same bytes Moved: b.txt is still in the tree (%v)", gone)
		}
	}
	if c == .Replaced {
		st, _ := prim.lstat(vfs, SB_ROOT + "/b.txt")
		fs.mount_sync(m)
		e, found, _ := fs.shadow_get(&m.shadow, "b.txt")
		if !found || e.stat.ino != st.ino || e.stat.mtime_ns != st.mtime_ns || e.stat.size != st.size || e.stat.mode != st.mode {
			world_fail(w, "same bytes Replaced: the entry was not refreshed (found %v, ino %v %v)", found, e.stat.ino, st.ino)
		}
	}
	data, spans, err := eng.tree_blame(&n.e, tree, name, context.temp_allocator)
	if err != .None {
		world_fail(w, "same bytes %v: blame: %v", c, err)
		return
	}
	text := string(data)
	if n := strings.count(text, "consumer v1\n"); n != 1 {
		world_fail(w, "same bytes %v: the consumer's text is in b.txt %d times (entry racy %v, stat equal %v, grain %d ms): %q", c, n, racy, same, grain / 1_000_000, text)
		return
	}
	if (c == .Full_Write_From_V0 || c == .Marked_Then_Full_Write) && strings.count(text, "agent text\n") != 1 {
		world_fail(w, "same bytes %v: the agent's text is not in b.txt once: %q", c, text)
	}
	at := strings.index(text, "consumer v1\n")
	pos := 0
	for sp in spans {
		if max(pos, at) < min(pos + sp.len, at + len("consumer v1\n")) && sp.id.actor == agent {
			world_fail(w, "same bytes %v: the consumer's text is credited to the agent (entry racy %v, stat equal %v, grain %d ms)", c, racy, same, grain / 1_000_000)
			return
		}
		pos += sp.len
	}
}

@(test)
same_bytes :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for c in Sb_Case {
		for grain in ([]i64{0, 1_000_000_000, 2_000_000_000}) {
			for seed in u64(1) ..= 3 {
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
				_sb_run(w, c, grain)
				for f in w.failures {
					fmt.eprintf("same_bytes %v seed %d: %s\n", c, seed, f)
				}
				testing.expect(t, len(w.failures) == 0, fmt.tprintf("same_bytes %v seed %d grain %d failed", c, seed, grain))
				world_destroy(w)
				free(w)
			}
		}
	}
	free_all(context.temp_allocator)
}

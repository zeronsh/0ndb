package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
SHELL_ROOT :: "/work/shell-n0"

@(private = "file")
Shell_Case :: enum u8 {
	Watch_First,
	Watch_Last,
	Two_Opens,
	Person_After,
	Person_Before,
}

@(private = "file")
_sw_write :: proc(vfs: prim.Vfs, path: string, data: string) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, transmute([]u8)data, 0)
	cerr := prim.close_file(vfs, fd)
	return err if err != .None else cerr
}

@(private = "file")
_sw_put :: proc(n: ^Node, vfs: prim.Vfs, path: string, data: string) {
	if err := _sw_write(vfs, path, data); err != .None {
		world_fail(n.w, "shell: write %s: %v", path, err)
	}
	context = instance_context(&n.inst)
	node_after(n)
}

@(private = "file")
_sw_owner :: proc(w: ^World, n: ^Node, tree: eng.Object, path, line: string, agent: prim.Id, want_agent: bool, c: Shell_Case) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, spans, berr := eng.tree_blame(&n.e, tree, path, context.temp_allocator)
	if berr != .None {
		world_fail(w, "shell %v: blame %s: %v", c, path, berr)
		return
	}
	at := strings.index(string(data), line)
	if at < 0 {
		world_fail(w, "shell %v: %q is not in %s (%q)", c, line, path, string(data))
		return
	}
	pos := 0
	for sp in spans {
		lo := max(pos, at)
		hi := min(pos + sp.len, at + len(line))
		if lo < hi && (sp.id.actor == agent) != want_agent {
			world_fail(w, "shell %v: %d bytes of %q in %s are credited to %s, the tool scope is %s", c, hi - lo, line, path, id_short(sp.id.actor), id_short(agent))
			return
		}
		pos += sp.len
	}
}

@(private = "file")
_sw_observe :: proc(w: ^World, n: ^Node, m: ^fs.Mount, scope: ^fs.Scope, rel: string, at: i64, c: Shell_Case) {
	context = instance_context(&n.inst)
	defer node_after(n)
	since := fs.mount_since(m, prim.clock_mono_ns(n.e.cfg.clock) - at)
	if err := fs.mount_observe_begin(m, rel, scope, nil, nil, since); err != .None {
		world_fail(w, "shell %v: observe %s: %v", c, rel, err)
		return
	}
	fs.mount_mark_written(m, rel, scope)
}

@(private = "file")
_sw_run :: proc(w: ^World, c: Shell_Case) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "shell: node start")
		return
	}
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	m: ^fs.Mount
	a := SHELL_ROOT + "/a.txt"
	b := SHELL_ROOT + "/b.txt"
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "shell")
		if err == .None {
			err = eng.space_open(&n.e, space)
		}
		if err == .None {
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		if err != .None {
			world_fail(w, "shell: setup: %v", err)
			return
		}
		reg, rerr := eng.registry(&n.e)
		if rerr != .None {
			world_fail(w, "shell: registry: %v", rerr)
			return
		}
		n.reg = reg
		if prim.mkdir_all(vfs, SHELL_ROOT, 0o755) != .None || _sw_write(vfs, b, "base b\n") != .None {
			world_fail(w, "shell: setup writes")
			return
		}
		if m, err = eng.tree_mount(&n.e, tree, SHELL_ROOT); err != .None && !(err == .Pending && m != nil) {
			world_fail(w, "shell: tree_mount: %v", err)
			return
		}
	}
	run_until(w, w.now + 3_000_000_000, true)
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	scope: ^fs.Scope
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		scope = fs.scope_open(n.reg, m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent)
	}
	if c == .Person_Before {
		_sw_put(n, vfs, b, "base b\nperson line\n")
		run_until(w, w.now + 5_000_000, false)
	}
	at: i64
	stamp: {
		context = instance_context(&n.inst)
		defer node_after(n)
		at = prim.clock_mono_ns(n.e.cfg.clock)
	}
	if c == .Watch_Last {
		_sw_observe(w, n, m, scope, "a.txt", at, c)
	}
	_sw_put(n, vfs, a, "tool line\n")
	if c == .Two_Opens {
		_sw_put(n, vfs, a, "tool line\nsecond line\n")
	}
	held := make([dynamic]Watch_Ev, context.temp_allocator)
	if c == .Watch_Last {
		for ev in n.disk.events {
			append(&held, Watch_Ev{path = strings.clone(ev.path, context.temp_allocator), closed = ev.closed})
		}
		disk_events_clear(&n.disk)
		if len(held) == 0 {
			world_fail(w, "shell %v: the write produced no watch event to hold back", c)
			return
		}
	} else {
		run_until(w, w.now + 2_000_000, false)
		if _, dirty := m.dirty["a.txt"]; !dirty || len(n.disk.events) != 0 {
			world_fail(w, "shell %v: the watcher has not reported a.txt before the observer", c)
			return
		}
		_sw_observe(w, n, m, scope, "a.txt", at, c)
		if c == .Two_Opens {
			_sw_observe(w, n, m, scope, "a.txt", at, c)
		}
	}
	if c == .Person_After {
		run_until(w, w.now + 1_000_000_000, true)
		_sw_put(n, vfs, a, "tool line\nperson line\n")
		run_until(w, w.now + 1_000_000_000, true)
	}
	if c == .Two_Opens {
		run_until(w, w.now + 1_000_000_000, true)
		_sw_put(n, vfs, a, "tool line\nsecond line\nperson line\n")
		run_until(w, w.now + 1_000_000_000, true)
	}
	finish: {
		context = instance_context(&n.inst)
		defer node_after(n)
		fs.scope_close(n.reg, scope)
		for ev in held {
			fs.registry_notify(n.reg, ev.path, .Closed if ev.closed else .Changed)
		}
	}
	run_until(w, w.now + 3_000_000_000, true)
	_sw_owner(w, n, tree, "a.txt", "tool line\n", agent, true, c)
	if c == .Person_After || c == .Two_Opens {
		_sw_owner(w, n, tree, "a.txt", "person line\n", agent, false, c)
	}
	if c == .Two_Opens {
		_sw_owner(w, n, tree, "a.txt", "second line\n", agent, true, c)
	}
	if c == .Person_Before {
		_sw_owner(w, n, tree, "b.txt", "person line\n", agent, false, c)
	}
}

@(test)
shell_write :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for c in Shell_Case {
		for seed in u64(1) ..= 8 {
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
			_sw_run(w, c)
			for f in w.failures {
				fmt.eprintf("shell_write %v seed %d: %s\n", c, seed, f)
			}
			testing.expect(t, len(w.failures) == 0, fmt.tprintf("shell_write %v seed %d failed", c, seed))
			world_destroy(w)
			free(w)
		}
	}
	free_all(context.temp_allocator)
}

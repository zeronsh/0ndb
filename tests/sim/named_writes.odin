package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/observe"
import "../../src/prim"

@(private = "file")
NW_ROOT :: "/work/named-n0"

@(private = "file")
Named_Case :: enum u8 {
	Write_Named,
	Shell_Named_After,
	Shell_Unnamed_After,
	Codex_Order,
	Person_During,
}

@(private = "file")
Nw_Open :: struct {
	call:  observe.Tool_Call,
	scope: ^fs.Scope,
	open:  bool,
}

@(private = "file")
_nw: ^Nw_Open

@(private = "file")
_nw_changed :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	if _nw == nil || !_nw.open {
		return nil, false
	}
	w := observe.Write {
		op     = .Write,
		path   = strings.concatenate({fs.mount_root(m), "/", rel}, context.temp_allocator),
		window = true,
	}
	calls := []observe.Tool_Call{_nw.call}
	if k, ambiguous := observe.attribute_window(calls, &w); k >= 0 && !ambiguous {
		return _nw.scope, true
	}
	return nil, false
}

@(private = "file")
_nw_put :: proc(n: ^Node, path, data: string) {
	vfs := disk_vfs(&n.disk)
	fd, err := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644)
	if err == .None {
		err = prim.write_at(vfs, fd, transmute([]u8)data, 0)
		prim.close_file(vfs, fd)
	}
	if err != .None {
		world_fail(n.w, "named: write %s: %v", path, err)
	}
	context = instance_context(&n.inst)
	node_after(n)
}

@(private = "file")
_nw_owner :: proc(w: ^World, n: ^Node, tree: eng.Object, path: string, agent: prim.Id, want_agent: bool, c: Named_Case) {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, spans, err := eng.tree_blame(&n.e, tree, path, context.temp_allocator)
	if err != .None || len(data) == 0 {
		world_fail(w, "named %v: blame %s: %v", c, path, err)
		return
	}
	for sp in spans {
		if (sp.id.actor == agent) != want_agent {
			world_fail(w, "named %v: %s is credited to %s, but it should be %s", c, path, id_short(sp.id.actor), "the tool's" if want_agent else "the person's")
			return
		}
	}
}

@(private = "file")
_nw_run :: proc(w: ^World, c: Named_Case) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "named: node start")
		return
	}
	vfs := disk_vfs(&n.disk)
	tree: eng.Object
	m: ^fs.Mount
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "named")
		if err == .None {
			err = eng.space_open(&n.e, space)
		}
		if err == .None {
			tree, err = eng.tree_create(&n.e, space, "work")
		}
		reg, rerr := eng.registry(&n.e)
		if err != .None || rerr != .None {
			world_fail(w, "named: setup: %v %v", err, rerr)
			return
		}
		n.reg = reg
		if prim.mkdir_all(vfs, NW_ROOT, 0o755) != .None {
			world_fail(w, "named: mkdir")
			return
		}
		if m, err = eng.tree_mount(&n.e, tree, NW_ROOT); err != .None && !(err == .Pending && m != nil) {
			world_fail(w, "named: tree_mount: %v", err)
			return
		}
		n.reg.observer.changed = _nw_changed
	}
	run_until(w, w.now + 3_000_000_000, true)
	file := "x.txt"
	input := ""
	switch c {
	case .Write_Named:
		input = fmt.tprintf(`{{"file_path":"%s/%s","content":"tool line\n"}}`, NW_ROOT, file)
	case .Shell_Named_After, .Codex_Order:
		input = fmt.tprintf(`{{"command":"printf 'tool line\\n' > %s","cwd":"%s"}}`, file, NW_ROOT)
	case .Shell_Unnamed_After, .Person_During:
		input = fmt.tprintf(`{{"command":"make generate","cwd":"%s"}}`, NW_ROOT)
	}
	agent := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	open := new(Nw_Open)
	defer free(open)
	_nw = open
	defer _nw = nil
	since: fs.Observe_Since
	stamp: {
		context = instance_context(&n.inst)
		defer node_after(n)
		since = fs.Observe_Since{mono = prim.clock_mono_ns(n.e.cfg.clock), wall = prim.clock_wall_ns(n.e.cfg.clock)}
	}
	path := strings.concatenate({NW_ROOT, "/", file}, context.temp_allocator)
	if c == .Codex_Order {
		_nw_put(n, path, "tool line\n")
		run_until(w, w.now + 3_000_000, false)
	}
	tool_open: {
		context = instance_context(&n.inst)
		defer node_after(n)
		observe.tool_call_init(&open.call, "t1", transmute([]u8)input, NW_ROOT, false, context.allocator)
		open.scope = fs.scope_open(n.reg, m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), agent, nil, since)
		observe.claim_named(m, &open.call, open.scope, since)
		open.open = true
	}
	defer observe.tool_call_destroy(&open.call)
	if c != .Codex_Order {
		_nw_put(n, path, "tool line\n" if c != .Person_During else "person line\n")
		run_until(w, w.now + 3_000_000, false)
	}
	tool_close: {
		context = instance_context(&n.inst)
		defer node_after(n)
		open.open = false
		fs.scope_close(n.reg, open.scope)
	}
	run_until(w, w.now + 3_000_000_000, true)
	_nw_owner(w, n, tree, file, agent, c != .Shell_Unnamed_After && c != .Person_During, c)
}

@(test)
named_writes :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for c in Named_Case {
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
			_nw_run(w, c)
			for f in w.failures {
				fmt.eprintf("named_writes %v seed %d: %s\n", c, seed, f)
			}
			testing.expect(t, len(w.failures) == 0, fmt.tprintf("named_writes %v seed %d failed", c, seed))
			world_destroy(w)
			free(w)
		}
	}
	free_all(context.temp_allocator)
}

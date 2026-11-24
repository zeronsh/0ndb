package sim

import "core:fmt"
import "core:os"
import "core:testing"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/observe"
import "../../src/prim"
import rt "../../src/runtime"

@(private = "file")
DC_ROOT :: "/work/decide-n0"

@(private = "file")
_dc_call :: proc(input: string) -> observe.Tool_Call {
	c: observe.Tool_Call
	observe.tool_call_init(&c, "t", transmute([]u8)input, DC_ROOT, false)
	return c
}

@(private = "file")
_dc_run :: proc(w: ^World) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "decide: node start")
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	vfs := disk_vfs(&n.disk)
	space, err := eng.space_create(&n.e, "decide")
	if err == .None {
		err = eng.space_open(&n.e, space)
	}
	tree: eng.Object
	if err == .None {
		tree, err = eng.tree_create(&n.e, space, "work")
	}
	reg, rerr := eng.registry(&n.e)
	if err != .None || rerr != .None || prim.mkdir_all(vfs, DC_ROOT, 0o755) != .None {
		world_fail(w, "decide: setup %v %v", err, rerr)
		return
	}
	m, merr := eng.tree_mount(&n.e, tree, DC_ROOT)
	if merr != .None && !(merr == .Pending && m != nil) {
		world_fail(w, "decide: mount %v", merr)
		return
	}
	other := new(fs.Mount)
	defer free(other)
	id := proc(w: ^World, n: ^Node) -> prim.Id {return prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))}
	turn := fs.scope_open(reg, m, id(w, n), id(w, n))
	one := fs.scope_open(reg, m, id(w, n), id(w, n))
	two := fs.scope_open(reg, m, id(w, n), id(w, n))
	defer fs.scope_close(reg, two)
	defer fs.scope_close(reg, one)
	defer fs.scope_close(reg, turn)
	r := new(rt.Runtime)
	defer free(r)
	r.e = &n.e
	r.runs = make([dynamic]^rt.Run)
	defer delete(r.runs)
	agent := rt.Proc{}
	agent.child.pid = 4242
	ws := new(rt.Worktree)
	defer free(ws)
	ws.r = r
	ws.members = make([dynamic]rt.Wt_Member)
	defer delete(ws.members)
	append(&ws.members, rt.Wt_Member{m = m, turn = turn})
	ws.tools = make([dynamic]rt.Wt_Tool)
	defer delete(ws.tools)
	s1 := []^fs.Scope{one}
	s2 := []^fs.Scope{two}
	append(&ws.tools, rt.Wt_Tool{scopes = s1, open = true}, rt.Wt_Tool{scopes = s2, open = true})
	run := new(rt.Run)
	defer free(run)
	run.ws = ws
	run.proc_ = &agent
	run.tools = make([dynamic]rt.Run_Tool)
	defer delete(run.tools)
	named := fmt.tprintf(`{{"command":"printf x > a.txt","cwd":"%s"}}`, DC_ROOT)
	unnamed := fmt.tprintf(`{{"command":"make generate","cwd":"%s"}}`, DC_ROOT)
	append(&r.runs, run)
	a := DC_ROOT + "/a.txt"
	b := DC_ROOT + "/b.txt"
	Case :: struct {
		name:    string,
		calls:   []string,
		write:   observe.Write,
		mount:   ^fs.Mount,
		want:    ^fs.Scope,
		found:   bool,
	}
	agent_line := []prim.Pid{5001, 4242, 1}
	stranger := []prim.Pid{7001, 1}
	argv := transmute([]u8)string("/bin/bash\x00-c\x00printf x > a.txt")
	other_argv := transmute([]u8)string("/usr/bin/python3\x00gen.py")
	cases := []Case {
		{"exact, agent's child running the tool's command", {named}, {op = .Write, path = a, pid = 5001, exact = true, lineage = agent_line, args = argv}, m, one, true},
		{"exact, agent's child with an unknown command", {named}, {op = .Write, path = b, pid = 5001, exact = true, lineage = agent_line, args = other_argv}, m, turn, true},
		{"exact, agent's child, unnamed", {unnamed}, {op = .Write, path = b, pid = 5001, exact = true, lineage = agent_line, args = other_argv}, m, turn, true},
		{"exact, a process outside the run", {named}, {op = .Write, path = a, pid = 7001, exact = true, lineage = stranger}, m, nil, false},
		{"window, named", {named}, {op = .Write, path = a, window = true}, m, one, true},
		{"window, unnamed", {unnamed}, {op = .Write, path = b, window = true}, m, nil, false},
		{"window, two open calls name it", {named, named}, {op = .Write, path = a, window = true}, m, turn, true},
		{"window, no open call", {}, {op = .Write, path = a, window = true}, m, nil, false},
		{"window, another mount", {named}, {op = .Write, path = a, window = true}, other, nil, false},
	}
	for c in cases {
		clear(&run.tools)
		for input, i in c.calls {
			append(&run.tools, rt.Run_Tool{id = "t", has_obs = true, scope = i, call = _dc_call(input)})
		}
		wr := c.write
		got, found := rt.window_decide(r, c.mount, &wr)
		if got != c.want || found != c.found {
			world_fail(w, "decide %s: got %v %v, want %v %v", c.name, got == one ? "tool" : got == two ? "second tool" : got == turn ? "turn" : got == nil ? "nil" : "other", found, c.want == one ? "tool" : c.want == turn ? "turn" : "nil", c.found)
		}
		for &t in run.tools {
			observe.tool_call_destroy(&t.call)
		}
	}
}

@(test)
window_decide :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	cfg := default_config(1)
	cfg.nodes = 1
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	w := new(World)
	world_init(w, cfg)
	_dc_run(w)
	for f in w.failures {
		fmt.eprintf("window_decide: %s\n", f)
	}
	testing.expect(t, len(w.failures) == 0, "window_decide failed")
	world_destroy(w)
	free(w)
	free_all(context.temp_allocator)
}

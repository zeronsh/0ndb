package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

SA_ROOT :: "/home/sim/scopes"

@(private = "file")
Sa_Ctx :: struct {
	w:      ^World,
	n:      ^Node,
	vfs:    prim.Vfs,
	tree:   eng.Object,
	conv:   prim.Id,
	shared: bool,
	fixed:  prim.Id,
}

@(private = "file")
_sa_mount :: proc(c: ^Sa_Ctx) -> ^fs.Mount {
	for &x in c.n.mounts {
		if x.root == SA_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_sa_actor :: proc(c: ^Sa_Ctx, m: ^fs.Mount) -> prim.Id {
	if c.shared {
		return c.fixed
	}
	actor, pseudo := eng.scope_actor(&c.n.e, c.conv, m.id, m.line)
	{
		context = eng.context_for(&c.n.e)
		fs.history_register_owned_actor(m.history, actor, pseudo, c.conv)
	}
	return actor
}

@(private = "file")
_sa_switch :: proc(c: ^Sa_Ctx, line: string, fork: bool) -> bool {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _sa_mount(c)
	if m == nil {
		return false
	}
	fs.mount_sync(m)
	if fork {
		v, found, _ := fs.history_line(m.history, m.line, context.temp_allocator)
		if !found {
			v = fs.mount_synced(m)
		}
		if fs.history_set_line(m.history, line, v) != .None {
			return false
		}
	}
	old := m.line
	m.line = strings.clone(line, m.allocator)
	delete(old, m.allocator)
	return fs.mount_materialize(m) == .None
}

@(private = "file")
_sa_open :: proc(c: ^Sa_Ctx, actor: prim.Id, name: string) -> (scope: ^fs.Scope) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _sa_mount(c)
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&c.w.rng))
	scope = sim_scope_open(c.w, n.reg, m, sid, actor)
	abs := strings.concatenate({SA_ROOT, "/", name}, context.temp_allocator)
	n.writers[strings.clone(abs, c.w.allocator)] = Writer_Info{scope = scope, agent = true}
	fs.mount_observe_begin(m, name, scope)
	return
}

@(private = "file")
_sa_write :: proc(c: ^Sa_Ctx, name: string, text: string) -> bool {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	abs := strings.concatenate({SA_ROOT, "/", name}, context.temp_allocator)
	old, _ := prim.read_file(c.vfs, abs, context.temp_allocator)
	data := strings.concatenate({string(old), text, "\n"}, context.temp_allocator)
	fd, err := prim.open_file(c.vfs, abs, {.Write, .Create, .Truncate}, 0o644)
	if err != .None {
		return false
	}
	prim.write_at(c.vfs, fd, transmute([]u8)data, 0)
	prim.datasync(c.vfs, fd)
	prim.close_file(c.vfs, fd)
	prim.sync_dir(c.vfs, SA_ROOT)
	return true
}

@(private = "file")
_sa_close :: proc(c: ^Sa_Ctx, scope: ^fs.Scope, name: string) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	fs.scope_close(n.reg, scope)
	abs := strings.concatenate({SA_ROOT, "/", name}, context.temp_allocator)
	if abs in n.writers {
		key, _ := delete_key(&n.writers, abs)
		delete(key, c.w.allocator)
	}
}

@(private = "file")
_sa_last :: proc(c: ^Sa_Ctx, actor: prim.Id) -> (id: crdt.Op_Id, ok: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _sa_mount(c)
	if m == nil {
		return
	}
	fs.mount_sync(m)
	k := crdt.graph_known(&m.history.g, actor)
	if k == 0 {
		return
	}
	return crdt.Op_Id{actor, k - 1}, true
}

@(private = "file")
_sa_scope_of :: proc(c: ^Sa_Ctx, op: crdt.Op_Id) -> (scope: prim.Id, found: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	s, ok, _ := eng.tree_scope_of(&n.e, c.tree, op)
	return s, ok
}

@(private = "file")
_sa_setup :: proc(w: ^World, shared: bool) -> (c: Sa_Ctx, ok: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "scope actor: node start")
		return
	}
	c.w = w
	c.n = n
	c.vfs = disk_vfs(&n.disk)
	c.shared = shared
	m := &w.model
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "scopes")
		if err != .None {
			world_fail(w, "scope actor: space_create: %v", err)
			node_after(n)
			return
		}
		eng.space_open(&n.e, space)
		c.tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "scope actor: tree_create: %v", err)
			node_after(n)
			return
		}
		node_after(n)
	}
	c.conv = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	c.fixed = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	prim.mkdir_all(c.vfs, SA_ROOT, 0o755)
	if err := node_mount(w, n, oi, SA_ROOT); err != .None {
		world_fail(w, "scope actor: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(SA_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _sa_mount(&c) == nil {
		world_fail(w, "scope actor: mount missing")
		return
	}
	return c, true
}

@(private = "file")
_sa_held :: proc(w: ^World, shared: bool) {
	c, ok := _sa_setup(w, shared)
	if !ok {
		return
	}
	if !_sa_switch(&c, "l/run1", true) {
		world_fail(w, "held turn: switch to run line 1")
		return
	}
	run_until(w, w.now + 1_000_000_000, true)
	a1 := _sa_actor(&c, _sa_mount(&c))
	s1 := _sa_open(&c, a1, "a.txt")
	_sa_write(&c, "a.txt", "turn one")
	run_until(w, w.now + 1_000_000_000, true)
	_sa_close(&c, s1, "a.txt")
	run_until(w, w.now + 1_000_000_000, true)
	if _, have := _sa_last(&c, a1); !have {
		world_fail(w, "held turn: turn 1's write was not committed under its scope actor")
		return
	}
	if !_sa_switch(&c, "main", false) {
		world_fail(w, "held turn: switch back to the conversation line")
		return
	}
	run_until(w, w.now + 1_000_000_000, true)
	if !_sa_switch(&c, "l/run2", true) {
		world_fail(w, "held turn: switch to run line 2")
		return
	}
	run_until(w, w.now + 1_000_000_000, true)
	a2 := _sa_actor(&c, _sa_mount(&c))
	before, _ := _sa_last(&c, a2)
	s2 := _sa_open(&c, a2, "b.txt")
	s2_id := s2.id
	_sa_write(&c, "b.txt", "turn two")
	run_until(w, w.now + 1_000_000_000, true)
	_sa_close(&c, s2, "b.txt")
	run_until(w, w.now + 2_000_000_000, true)
	last, have := _sa_last(&c, a2)
	if !have || (a2 == a1 && last == before) {
		world_fail(w, "held turn: the next turn's scope write after a held turn was not committed under its scope actor (actor shared with the held turn: %v)", a1 == a2)
		return
	}
	if sc, found := _sa_scope_of(&c, last); !found || sc != s2_id {
		world_fail(w, "held turn: the next turn's write is attributed to scope %v (found %v), not %v", sc, found, s2_id)
	}
}

@(private = "file")
_sa_tools :: proc(w: ^World) {
	c, ok := _sa_setup(w, false)
	if !ok {
		return
	}
	if !_sa_switch(&c, "l/run1", true) {
		world_fail(w, "two tools: switch to the run line")
		return
	}
	run_until(w, w.now + 1_000_000_000, true)
	a := _sa_actor(&c, _sa_mount(&c))
	t1 := _sa_open(&c, a, "x.txt")
	t2 := _sa_open(&c, a, "y.txt")
	t1_id, t2_id := t1.id, t2.id
	_sa_write(&c, "x.txt", "tool one")
	_sa_write(&c, "y.txt", "tool two")
	run_until(w, w.now + 2_000_000_000, true)
	_sa_close(&c, t1, "x.txt")
	_sa_close(&c, t2, "y.txt")
	run_until(w, w.now + 2_000_000_000, true)
	k := 0
	seen := [2]bool{}
	{
		n := c.n
		context = instance_context(&n.inst)
		m := _sa_mount(&c)
		fs.mount_sync(m)
		k = int(crdt.graph_known(&m.history.g, a))
		node_after(n)
	}
	if k == 0 {
		world_fail(w, "two tools: nothing committed under the agent actor")
		return
	}
	for seq in 0 ..< k {
		sc, found := _sa_scope_of(&c, crdt.Op_Id{a, u64(seq)})
		if !found {
			world_fail(w, "two tools: op %d of the agent actor has no scope", seq)
			continue
		}
		switch sc {
		case t1_id:
			seen[0] = true
		case t2_id:
			seen[1] = true
		case:
			world_fail(w, "two tools: op %d is attributed to an unknown scope %v", seq, sc)
		}
	}
	if !seen[0] || !seen[1] {
		world_fail(w, "two tools: the two tool scopes of one actor are not told apart (%v)", seen)
	}
}

@(private = "file")
_sa_put :: proc(c: ^Sa_Ctx, name: string, data: string) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	abs := strings.concatenate({SA_ROOT, "/", name}, context.temp_allocator)
	fd, err := prim.open_file(c.vfs, abs, {.Write, .Create, .Truncate}, 0o644)
	if err != .None {
		return
	}
	prim.write_at(c.vfs, fd, transmute([]u8)data, 0)
	prim.datasync(c.vfs, fd)
	prim.close_file(c.vfs, fd)
	prim.sync_dir(c.vfs, SA_ROOT)
}

@(private = "file")
_sa_check_last :: proc(c: ^Sa_Ctx, w: ^World, actor: prim.Id, want: prim.Id, label: string) {
	last, have := _sa_last(c, actor)
	if !have {
		world_fail(w, "%s: nothing committed under the agent actor", label)
		return
	}
	if sc, found := _sa_scope_of(c, last); !found || sc != want {
		world_fail(w, "%s: the agent's write is attributed to scope %v (found %v), not %v", label, sc, found, want)
	}
}

@(private = "file")
_sa_based :: proc(w: ^World) {
	c, ok := _sa_setup(w, false)
	if !ok {
		return
	}
	_sa_put(&c, "a.txt", "one\n")
	run_until(w, w.now + 2_000_000_000, true)
	a := _sa_actor(&c, _sa_mount(&c))
	n := c.n
	scope: ^fs.Scope
	sid: prim.Id
	{
		context = instance_context(&n.inst)
		sid = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		scope = sim_scope_open(c.w, n.reg, _sa_mount(&c), sid, a)
		fs.scope_read_base(scope, "a.txt", transmute([]u8)string("one\n"))
		node_after(n)
	}
	{
		context = instance_context(&n.inst)
		if err := eng.tree_write(&n.e, c.tree, "a.txt", transmute([]u8)string("zero\none\n"), tree_base(&n.e, c.tree)); err != .None {
			world_fail(w, "based write: tree_write: %v", err)
		}
		node_after(n)
	}
	run_until(w, w.now + 2_000_000_000, true)
	{
		context = instance_context(&n.inst)
		abs := strings.concatenate({SA_ROOT, "/a.txt"}, context.temp_allocator)
		n.writers[strings.clone(abs, w.allocator)] = Writer_Info{scope = scope, agent = true}
		fs.mount_observe_begin(_sa_mount(&c), "a.txt", scope)
		node_after(n)
	}
	_sa_put(&c, "a.txt", "one\nagent\n")
	run_until(w, w.now + 2_000_000_000, true)
	_sa_close(&c, scope, "a.txt")
	run_until(w, w.now + 2_000_000_000, true)
	k := 0
	{
		context = instance_context(&n.inst)
		m := _sa_mount(&c)
		fs.mount_sync(m)
		k = int(crdt.graph_known(&m.history.g, a))
		node_after(n)
	}
	if k == 0 {
		world_fail(w, "based write: nothing committed under the agent actor")
		return
	}
	for seq in 0 ..< k {
		if sc, found := _sa_scope_of(&c, crdt.Op_Id{a, u64(seq)}); !found || sc != sid {
			world_fail(w, "based write: op %d of the agent actor is attributed to scope %v (found %v), not %v", seq, sc, found, sid)
			return
		}
	}
}

@(private = "file")
_sa_replay :: proc(w: ^World) -> (credited: bool) {
	c, ok := _sa_setup(w, false)
	if !ok {
		return false
	}
	if !_sa_switch(&c, "l/run1", true) {
		world_fail(w, "replayed write: switch to the run line")
		return false
	}
	run_until(w, w.now + 1_000_000_000, true)
	a := _sa_actor(&c, _sa_mount(&c))
	s := _sa_open(&c, a, "r.txt")
	sid := s.id
	_sa_write(&c, "r.txt", "agent line")
	n := c.n
	run_until(w, w.now + 1_000_000_000, true)
	crashes := w.stats.crashes
	n.disk.crash_at = n.disk.stats.ops + 1
	_sa_close(&c, s, "r.txt")
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	run_until(w, w.now + 20_000_000_000, true)
	if w.stats.crashes == crashes {
		world_fail(w, "replayed write: the node did not crash")
		return false
	}
	if !n.alive || _sa_mount(&c) == nil {
		world_fail(w, "replayed write: the node or its mount did not come back")
		return false
	}
	last, have := _sa_last(&c, a)
	if !have {
		return false
	}
	if sc, found := _sa_scope_of(&c, last); !found || sc != sid {
		world_fail(w, "replayed write: the agent's replayed write is attributed to scope %v (found %v), not %v", sc, found, sid)
	}
	return true
}

@(private = "file")
_sa_world :: proc(seed: u64) -> ^World {
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
	return w
}

@(test)
scope_actors :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	shared := env_u64("SA_SHARED", 0) != 0
	bad := 0
	replayed := 0
	count := env_u64("SA_SEEDS", 20)
	for seed in u64(1) ..= count {
		for which in 0 ..< 4 {
			w := _sa_world(seed)
			switch which {
			case 0:
				_sa_held(w, shared)
			case 1:
				_sa_tools(w)
			case 2:
				_sa_based(w)
			case 3:
				if _sa_replay(w) {
					replayed += 1
				}
			}
			for f in w.failures {
				if bad < 20 {
					names := [4]string{"held", "tools", "based", "replay"}
					fmt.eprintf("scope_actors seed %d %s: %s\n", seed, names[which], f)
				}
			}
			if len(w.failures) > 0 {
				bad += 1
			}
			world_destroy(w)
			free(w)
		}
	}
	fmt.eprintf("scope_actors: %d seeds, %d replays credited to the agent, %d failed\n", count, replayed, bad)
	testing.expect(t, bad == 0, fmt.tprintf("scope_actors: %d failures", bad))
	testing.expect(t, replayed > 0, "scope_actors: no crash replay credited the agent, so the replay case proved nothing")
}

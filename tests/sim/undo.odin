package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/obj"
import "../../src/prim"

UR_ROOT :: "/home/sim/undo"

@(private = "file")
Ur_Ctx :: struct {
	w:      ^World,
	n:      ^Node,
	vfs:    prim.Vfs,
	tree:   eng.Object,
	conv:   eng.Object,
	agent:  prim.Id,
	tok:    int,
	turns:  [dynamic]obj.Rid,
	parent: obj.Rid,
	files:  map[string][dynamic]string,
	toks:   map[string]Ur_Tok,
	turn:   int,
	vstart: [dynamic]fs.Version,
	vend:   [dynamic]fs.Version,
	alloc:  runtime.Allocator,
	hooks:  Ur_Hooks,
	append_only: bool,
}

@(private = "file")
Ur_Tok :: struct {
	file:     string,
	agent:    bool,
	turn:     int,
	deleted:  bool,
	by_agent: bool,
	del_turn: int,
}

@(private = "file")
Ur_Hooks :: struct {
	held:     int,
	released: int,
	rewound:  int,
}

@(private = "file")
Ur_State :: struct {
	disk:     map[string]string,
	browsing: bool,
	position: obj.Rid,
}

@(private = "file")
_ur_mount :: proc(c: ^Ur_Ctx) -> ^fs.Mount {
	for &x in c.n.mounts {
		if x.root == UR_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_ur_version :: proc(c: ^Ur_Ctx) -> []u8 {
	m := _ur_mount(c)
	if m == nil {
		return nil
	}
	fs.mount_sync(m)
	vb := make([dynamic]u8, context.temp_allocator)
	fs.encode_version(&vb, fs.mount_synced(m))
	b := make([dynamic]u8, c.alloc)
	pw := prim.writer(&b)
	prim.write_bytes(&pw, vb[:])
	prim.write_str(&pw, "")
	prim.write_str(&pw, "")
	return b[:]
}

@(private = "file")
_ur_write :: proc(c: ^Ur_Ctx, agent: bool, name: string) -> bool {
	n := c.n
	c.tok += 1
	t := fmt.aprintf("<%c%d>", 'a' if agent else 'p', c.tok, allocator = c.alloc)
	if name not_in c.files {
		c.files[strings.clone(name, c.alloc)] = make([dynamic]string, c.alloc)
	}
	lines := &c.files[name]
	c.toks[t] = Ur_Tok{file = name, agent = agent, turn = c.turn}
	if agent && !c.append_only && len(lines) > 0 && rng_chance(&c.w.rng, 1, 3) {
		at := rng_int(&c.w.rng, len(lines))
		old := lines[at]
		x := &c.toks[old]
		x.deleted = true
		x.by_agent = true
		x.del_turn = c.turn
		lines[at] = t
		world_note(c.w, "undo edit by agent: %s %s -> %s", name, old, t)
	} else {
		append(lines, t)
		world_note(c.w, "undo edit by %s: %s += %s", "agent" if agent else "person", name, t)
	}
	abs := strings.concatenate({UR_ROOT, "/", name}, context.temp_allocator)
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _ur_mount(c)
	if m == nil {
		return false
	}
	scope: ^fs.Scope
	if agent {
		sid := prim.id_new_with(node_clock(&n.clock), rng_random(&c.w.rng))
		scope = fs.scope_open(n.reg, m, sid, c.agent)
		if abs in n.writers {
			n.writers[abs] = Writer_Info{scope = scope, agent = true}
		} else {
			n.writers[strings.clone(abs, c.w.allocator)] = Writer_Info{scope = scope, agent = true}
		}
		fs.mount_observe_begin(m, name, scope)
	}
	b := strings.builder_make(context.temp_allocator)
	for x in c.files[name] {
		strings.write_string(&b, x)
		strings.write_byte(&b, '\n')
	}
	err := _ur_disk_write(c.vfs, abs, transmute([]u8)strings.to_string(b))
	if scope != nil {
		fs.scope_close(n.reg, scope)
		if abs in n.writers {
			key, _ := delete_key(&n.writers, abs)
			delete(key, c.w.allocator)
		}
	} else {
		fs.mount_sync(m)
	}
	return err == .None && !n.disk.dead
}

@(private = "file")
_ur_disk_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	if err == .None {
		err = cerr
	}
	if err == .None {
		err = prim.sync_dir(vfs, prim.dir_name(path))
	}
	return err
}

@(private = "file")
_ur_disk :: proc(c: ^Ur_Ctx) -> map[string]string {
	out := make(map[string]string, c.alloc)
	n := c.n
	n.disk.probe += 1
	defer n.disk.probe -= 1
	names := make([dynamic]string, context.temp_allocator)
	d: prim.Dir
	if prim.dir_open(c.vfs, &d, UR_ROOT, context.temp_allocator) != .None {
		return out
	}
	for {
		e, more, derr := prim.dir_next(c.vfs, &d)
		if derr != .None || !more {
			break
		}
		append(&names, strings.clone(e.name, context.temp_allocator))
	}
	prim.dir_close(c.vfs, &d)
	for nm in names {
		if strings.has_prefix(nm, ".") {
			continue
		}
		data, rerr := prim.read_file(c.vfs, strings.concatenate({UR_ROOT, "/", nm}, context.temp_allocator), c.alloc)
		if rerr == .None {
			out[strings.clone(nm, c.alloc)] = string(data)
		}
	}
	return out
}

@(private = "file")
_ur_state :: proc(c: ^Ur_Ctx) -> (st: Ur_State, ok: bool) {
	st.disk = _ur_disk(c)
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	cs, err := eng.convo_status(&c.n.e, c.conv)
	if err != .None {
		world_fail(c.w, "undo: convo_status: %v", err)
		return st, false
	}
	st.browsing = cs.browsing
	st.position = cs.position
	return st, true
}

@(private = "file")
_ur_same :: proc(a, b: Ur_State) -> bool {
	if a.browsing != b.browsing || (a.browsing && a.position != b.position) || len(a.disk) != len(b.disk) {
		return false
	}
	for k, v in a.disk {
		if x, ok := b.disk[k]; !ok || x != v {
			return false
		}
	}
	return true
}

@(private = "file")
_ur_msg :: proc(c: ^Ur_Ctx, role: convo.Role, files: []convo.File_Delta, seal := true) -> (msg: obj.Rid, ok: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, c.conv)
	if werr != .None {
		world_fail(c.w, "undo: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = c.parent, files = files})
	if merr != .None {
		world_fail(c.w, "undo: writer_message: %v", merr)
		return
	}
	if role == .Assistant && seal {
		if _, serr := convo.writer_seal(wr, m, .Done); serr != .None {
			world_fail(c.w, "undo: writer_seal: %v", serr)
			return
		}
	}
	convo.writer_commit(wr)
	c.parent = m
	return m, true
}

@(private = "file")
_ur_turn :: proc(c: ^Ur_Ctx, person: bool, create: bool) -> bool {
	w := c.w
	files: []convo.File_Delta
	{
		context = instance_context(&c.n.inst)
		files = make([]convo.File_Delta, 1, c.alloc)
		files[0] = convo.File_Delta{mount = "work", tree = c.tree.id, version = _ur_version(c)}
		node_after(c.n)
	}
	{
		context = instance_context(&c.n.inst)
		if m := _ur_mount(c); m != nil {
			append(&c.vstart, slice.clone(fs.mount_synced(m), c.alloc))
		}
		node_after(c.n)
	}
	user, uok := _ur_msg(c, .User, nil)
	if !uok {
		return false
	}
	append(&c.turns, user)
	reply, pok := _ur_msg(c, .Assistant, files, false)
	if !pok {
		return false
	}
	names := []string{"a.txt", "b.txt"}
	for _ in 0 ..< 1 + rng_int(&w.rng, 3) {
		if !_ur_write(c, true, names[rng_int(&w.rng, len(names))]) {
			return false
		}
		run_until(w, w.now + 500_000_000, true)
	}
	if create && !_ur_write(c, true, "c.txt") {
		return false
	}
	if person {
		if !_ur_write(c, false, names[rng_int(&w.rng, len(names))]) {
			return false
		}
	}
	run_until(w, w.now + 1_000_000_000, true)
	{
		n := c.n
		context = instance_context(&n.inst)
		if m := _ur_mount(c); m != nil {
			fs.mount_sync(m)
			append(&c.vend, slice.clone(fs.mount_synced(m), c.alloc))
		}
		wr, werr := eng.convo_writer(&n.e, c.conv)
		if werr == .None {
			sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
			convo.writer_scope(wr, reply, .Turn, sid, c.agent, nil, nil)
			if _, serr := convo.writer_seal(wr, reply, .Done); serr != .None {
				world_fail(w, "undo: writer_seal: %v", serr)
				node_after(n)
				return false
			}
			convo.writer_commit(wr)
		}
		node_after(n)
	}
	run_until(w, w.now + 1_000_000_000, true)
	return true
}

@(private = "file")
_ur_hooks :: proc(c: ^Ur_Ctx) -> eng.Undo_Hooks {
	return eng.Undo_Hooks {
		data = &c.hooks,
		hold = proc(data: rawptr, e: ^eng.Engine, convs: []eng.Object, undo: prim.Id) -> eng.Error {
			(^Ur_Hooks)(data).held += 1
			return .None
		},
		rewind = proc(data: rawptr, e: ^eng.Engine, conv: eng.Object, head: obj.Rid) -> eng.Error {
			(^Ur_Hooks)(data).rewound += 1
			return .None
		},
		release = proc(data: rawptr, e: ^eng.Engine, convs: []eng.Object, undo: prim.Id) -> eng.Error {
			(^Ur_Hooks)(data).released += 1
			return .None
		},
	}
}

@(private = "file")
_ur_setup :: proc(w: ^World, alloc: runtime.Allocator) -> (c: ^Ur_Ctx, ok: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "undo: node start")
		return
	}
	c = new(Ur_Ctx, alloc)
	c.w = w
	c.n = n
	c.vfs = disk_vfs(&n.disk)
	c.alloc = alloc
	c.files = make(map[string][dynamic]string, alloc)
	c.toks = make(map[string]Ur_Tok, alloc)
	c.vstart = make([dynamic]fs.Version, alloc)
	c.vend = make([dynamic]fs.Version, alloc)
	c.turns = make([dynamic]obj.Rid, alloc)
	m := &w.model
	{
		context = instance_context(&n.inst)
		space, err := eng.space_create(&n.e, "undo")
		if err != .None {
			world_fail(w, "undo: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		c.tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "undo: tree_create: %v", err)
			return
		}
		c.conv, err = eng.convo_create(&n.e, space, eng.Convo_Settings{title = "undo"})
		if err != .None {
			world_fail(w, "undo: convo_create: %v", err)
			return
		}
		if merr := eng.convo_mount(&n.e, c.conv, "work", c.tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "undo: convo_mount: %v", merr)
			return
		}
		eng.undo_hooks_set(&n.e, _ur_hooks(c))
		node_after(n)
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	prim.mkdir_all(c.vfs, UR_ROOT, 0o755)
	for name in ([]string{"a.txt", "b.txt"}) {
		lines := make([dynamic]string, alloc)
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 2 {
			c.tok += 1
			t := fmt.aprintf("<b%d>", c.tok, allocator = alloc)
			append(&lines, t)
			c.toks[t] = Ur_Tok{file = name, turn = -1}
			strings.write_string(&b, t)
			strings.write_byte(&b, '\n')
		}
		c.files[strings.clone(name, alloc)] = lines
		_ur_disk_write(c.vfs, strings.concatenate({UR_ROOT, "/", name}, context.temp_allocator), transmute([]u8)strings.to_string(b))
	}
	if err := node_mount(w, n, oi, UR_ROOT); err != .None {
		world_fail(w, "undo: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(UR_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _ur_mount(c) == nil {
		world_fail(w, "undo: mount missing")
		return
	}
	c.agent = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	return c, true
}

@(private = "file")
Ur_Plan :: struct {
	turns:  int,
	at:     int,
	person: []bool,
	create: int,
	revert: bool,
}

@(private = "file")
_ur_plan :: proc(w: ^World, alloc: runtime.Allocator) -> (p: Ur_Plan) {
	p.turns = 2 + rng_int(&w.rng, 4)
	p.at = 1 + rng_int(&w.rng, p.turns - 1)
	p.person = make([]bool, p.turns, alloc)
	for i in 0 ..< p.turns {
		p.person[i] = rng_chance(&w.rng, 1, 3)
	}
	p.create = rng_int(&w.rng, p.turns + 1)
	p.revert = rng_chance(&w.rng, 1, 2)
	return
}

@(private = "file")
_ur_build :: proc(w: ^World, alloc: runtime.Allocator) -> (c: ^Ur_Ctx, p: Ur_Plan, at_state: Ur_State, ok: bool) {
	c = _ur_setup(w, alloc) or_return
	p = _ur_plan(w, alloc)
	for i in 0 ..< p.turns {
		if i == p.at {
			at_state = _ur_state(c) or_return
		}
		c.turn = i
		if !_ur_turn(c, p.person[i], i == p.create) {
			world_fail(w, "undo: turn %d failed", i)
			return
		}
	}
	if p.revert {
		last := p.turns - 1
		if last >= len(c.vstart) || last >= len(c.vend) {
			world_fail(w, "undo: no versions recorded for turn %d", last)
			return
		}
		n := c.n
		rerr: fs.Error
		{
			context = instance_context(&n.inst)
			m := _ur_mount(c)
			rerr = fs.mount_revert(m, c.vstart[last], c.vend[last], c.conv.id) if m != nil else .Not_Found
			node_after(n)
		}
		if rerr != .None {
			world_fail(w, "undo: the turn revert of turn %d failed: %v", last, rerr)
			return
		}
		world_note(w, "undo: reverted turn %d before the undo", last)
		run_until(w, w.now + 2_000_000_000, true)
	}
	return c, p, at_state, true
}

@(private = "file")
_ur_check_undo :: proc(c: ^Ur_Ctx, p: Ur_Plan, at: Ur_State, got: Ur_State, label: string) {
	w := c.w
	present := make(map[string]string, context.temp_allocator)
	for name, data in got.disk {
		for t in strings.split_lines(strings.trim_right(data, "\n"), context.temp_allocator) {
			present[t] = name
		}
	}
	for t, x in c.toks {
		after := x.agent && x.turn >= p.at
		want := !after && (!x.deleted || (x.by_agent && x.del_turn >= p.at))
		name, has := present[t]
		switch {
		case want && !has:
			world_fail(w, "undo %s: %s (agent %v, turn %d, deleted %v by agent %v in turn %d) in %s is missing after undoing turn %d", label, t, x.agent, x.turn, x.deleted, x.by_agent, x.del_turn, x.file, p.at)
		case !want && has:
			world_fail(w, "undo %s: %s (agent %v, turn %d, deleted %v by agent %v in turn %d) is in %s after undoing turn %d", label, t, x.agent, x.turn, x.deleted, x.by_agent, x.del_turn, name, p.at)
		case has && name != x.file:
			world_fail(w, "undo %s: %s belongs in %s, found in %s", label, t, x.file, name)
		}
	}
	for name, data in got.disk {
		seen := make(map[string]bool, context.temp_allocator)
		for t in strings.split_lines(strings.trim_right(data, "\n"), context.temp_allocator) {
			if seen[t] {
				world_fail(w, "undo %s: %s holds %s twice: %q", label, name, t, data)
			}
			seen[t] = true
		}
	}
	if _, had := at.disk["c.txt"]; !had && p.create >= p.at {
		if _, still := got.disk["c.txt"]; still {
			world_fail(w, "undo %s: c.txt the agent created after T is still on disk: %q", label, got.disk["c.txt"])
		}
	}
}

@(private = "file")
_ur_leaf_check :: proc(c: ^Ur_Ctx, p: Ur_Plan, got: Ur_State, label: string) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	t, err := eng.convo_message(&n.e, c.conv, {msg = c.turns[p.at]}, context.temp_allocator)
	if err != .None {
		world_fail(c.w, "undo %s: convo_message T: %v", label, err)
		return
	}
	if !got.browsing || got.position != t.parent {
		world_fail(c.w, "undo %s: A's leaf is %v (browsing %v), not T's parent %v", label, got.position, got.browsing, t.parent)
	}
	list, lerr := eng.convo_undos(&n.e, c.conv, context.temp_allocator)
	if lerr != .None || len(list) == 0 {
		world_fail(c.w, "undo %s: no undo record (%v)", label, lerr)
		return
	}
	for u in list {
		if u.phase != .Released {
			world_fail(c.w, "undo %s: undo %v stopped at phase %v", label, u.id, u.phase)
		}
	}
}

@(private = "file")
_ur_world :: proc(seed: u64) -> ^World {
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

@(private = "file")
_ur_resume :: proc(c: ^Ur_Ctx, at: obj.Rid, redo_of: prim.Id) -> eng.Error {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	eng.undo_hooks_set(&n.e, _ur_hooks(c))
	list, lerr := eng.convo_undos(&n.e, c.conv, context.temp_allocator)
	if lerr != .None {
		return lerr
	}
	for u in list {
		if u.phase != .Released {
			return eng.convo_undo_drive(&n.e, c.conv, u.id)
		}
	}
	want := 2 if redo_of != {} else 1
	if len(list) >= want {
		return .None
	}
	if redo_of != {} {
		_, err := eng.convo_redo(&n.e, c.conv, redo_of)
		return err
	}
	_, err := eng.convo_undo(&n.e, c.conv, at)
	return err
}

@(private = "file")
_ur_case :: proc(w: ^World, redo: bool, k: u64, arena: ^virtual.Arena) -> (pre, post: Ur_State, crashed: bool, ok: bool) {
	if virtual.arena_init_growing(arena, 1 << 20) != nil {
		return
	}
	alloc := virtual.arena_allocator(arena)
	c, p, at, bok := _ur_build(w, alloc)
	if !bok {
		return
	}
	n := c.n
	built := _ur_state(c) or_return
	undo: prim.Id
	if redo {
		{
			context = instance_context(&n.inst)
			u, err := eng.convo_undo(&n.e, c.conv, c.turns[p.at])
			node_after(n)
			if err != .None {
				world_fail(w, "undo: convo_undo: %v", err)
				return
			}
			undo = u
		}
		run_until(w, w.now + 5_000_000_000, true)
	}
	pre = _ur_state(c) or_return
	crashes := w.stats.crashes
	if k > 0 {
		n.disk.crash_at = n.disk.stats.ops + k
	}
	drive: {
		context = instance_context(&n.inst)
		if redo {
			eng.convo_redo(&n.e, c.conv, undo)
		} else {
			eng.convo_undo(&n.e, c.conv, c.turns[p.at])
		}
		node_after(n)
	}
	run_until(w, w.now + 20_000_000_000, true)
	n.disk.crash_at = 0
	crashed = w.stats.crashes > crashes
	run_until(w, w.now + 20_000_000_000, true)
	if !n.alive {
		world_fail(w, "undo: node did not come back")
		return
	}
	if crashed {
		if rerr := _ur_resume(c, c.turns[p.at], undo); rerr != .None {
			world_fail(w, "undo: resume after the crash: %v", rerr)
		}
		run_until(w, w.now + 10_000_000_000, true)
	}
	post = _ur_state(c) or_return
	if k == 0 {
		if redo {
			if !_ur_same(post, built) {
				world_fail(w, "undo reference: after the redo the tree holds %v (browsing %v), not %v (browsing %v) from before the undo", post.disk, post.browsing, built.disk, built.browsing)
			}
		} else {
			_ur_check_undo(c, p, at, post, "reference")
			_ur_leaf_check(c, p, post, "reference")
			if c.hooks.held == 0 || c.hooks.released == 0 || c.hooks.rewound == 0 {
				world_fail(w, "undo reference: the runtime hooks ran hold %d, rewind %d, release %d times", c.hooks.held, c.hooks.rewound, c.hooks.released)
			}
		}
	}
	return pre, post, crashed, true
}

@(test)
undo_seeds :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad := 0
	count := env_u64("UR_SEEDS", 40)
	for seed in env_u64("UR_FROM", 1) ..= count {
		for redo in ([2]bool{false, true}) {
			w := _ur_world(seed)
			a: virtual.Arena
			_, _, _, ok := _ur_case(w, redo, 0, &a)
			if !ok && len(w.failures) == 0 {
				world_fail(w, "undo: the case did not run")
			}
			for f in w.failures {
				if bad < 30 {
					fmt.eprintf("undo_seeds seed %d redo %v: %s\n", seed, redo, f)
				}
			}
			if len(w.failures) > 0 {
				bad += 1
			}
			world_destroy(w)
			free(w)
			virtual.arena_destroy(&a)
		}
	}
	fmt.eprintf("undo_seeds: %d seeds, %d failed\n", count, bad)
	testing.expect(t, bad == 0, fmt.tprintf("undo_seeds: %d failures", bad))
}

@(test)
undo_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	seeds := env_u64("UR_CRASH_SEEDS", 1)
	points := [2]int{}
	bad := 0
	for seed in env_u64("UR_CRASH_FROM", 1) ..= seeds {
		for redo in ([2]bool{false, true}) {
			rw := _ur_world(seed)
			ra: virtual.Arena
			_, ref, _, rok := _ur_case(rw, redo, 0, &ra)
			ref_disk := make(map[string]string, context.allocator)
			for name, data in ref.disk {
				ref_disk[strings.clone(name)] = strings.clone(data)
			}
			ref_browsing, ref_position := ref.browsing, ref.position
			for f in rw.failures {
				fmt.eprintf("undo_crash seed %d redo %v reference: %s\n", seed, redo, f)
			}
			ref_failed := len(rw.failures) > 0
			world_destroy(rw)
			free(rw)
			virtual.arena_destroy(&ra)
			if !rok || ref_failed {
				bad += 1
				continue
			}
			want := Ur_State{disk = ref_disk, browsing = ref_browsing, position = ref_position}
			only := env_u64("UR_CRASH_K", 0)
			for k in u64(1) ..= 6000 {
				if only != 0 && k != only {
					continue
				}
				w := _ur_world(seed)
				ca: virtual.Arena
				_, got, crashed, cok := _ur_case(w, redo, k, &ca)
				if cok && !_ur_same(got, want) {
					world_fail(w, "after a crash at disk op %d the tree holds %v (browsing %v at %v), not %v (browsing %v at %v)", k, got.disk, got.browsing, got.position, want.disk, want.browsing, want.position)
				}
				if !cok && len(w.failures) == 0 {
					world_fail(w, "the case did not run after a crash at disk op %d", k)
				}
				for f in w.failures {
					if bad < 30 {
						fmt.eprintf("undo_crash seed %d redo %v at disk op %d: %s\n", seed, redo, k, f)
					}
				}
				if len(w.failures) > 0 {
					bad += 1
				}
				world_destroy(w)
				free(w)
				virtual.arena_destroy(&ca)
				if !crashed || only != 0 {
					break
				}
				points[1 if redo else 0] += 1
			}
			for name, data in ref_disk {
				delete(name)
				delete(data)
			}
			delete(ref_disk)
		}
	}
	fmt.eprintf("undo_crash: %d crash points in undos, %d in redos, %d failed\n", points[0], points[1], bad)
	testing.expect(t, bad == 0, fmt.tprintf("undo_crash: %d failures", bad))
}

@(private = "file")
Ur_Side :: struct {
	conv:   eng.Object,
	agent:  prim.Id,
	parent: obj.Rid,
	turns:  [dynamic]obj.Rid,
	toks:   [dynamic]string,
	last:   [dynamic]string,
}

@(private = "file")
_ur_side_turn :: proc(c: ^Ur_Ctx, side: ^Ur_Side) -> bool {
	c.conv, c.agent, c.parent = side.conv, side.agent, side.parent
	clear(&c.turns)
	clear(&side.last)
	before := c.tok
	ok := _ur_turn(c, false, false)
	side.parent = c.parent
	append(&side.turns, ..c.turns[:])
	for t, x in c.toks {
		n := 0
		for d in t[2:len(t) - 1] {
			n = n * 10 + int(d - '0')
		}
		if x.agent && n > before {
			append(&side.toks, t)
			append(&side.last, t)
		}
	}
	return ok
}

@(private = "file")
_ur_two :: proc(w: ^World, alloc: runtime.Allocator) {
	c, ok := _ur_setup(w, alloc)
	if !ok {
		return
	}
	c.append_only = true
	n := c.n
	sides: [2]Ur_Side
	for &sd, i in sides {
		sd.turns = make([dynamic]obj.Rid, alloc)
		sd.toks = make([dynamic]string, alloc)
		sd.last = make([dynamic]string, alloc)
		context = instance_context(&n.inst)
		if i == 0 {
			sd.conv = c.conv
		} else {
			o, err := eng.convo_create(&n.e, c.tree.space, eng.Convo_Settings{title = "other"})
			if err != .None {
				world_fail(w, "undo two: convo_create: %v", err)
				node_after(n)
				return
			}
			sd.conv = o
			eng.convo_mount(&n.e, o, "work", c.tree.id, {})
		}
		actor, pseudo := eng.turn_actor(&n.e, sd.conv.id)
		sd.agent = actor
		if m := _ur_mount(c); m != nil {
			context = eng.context_for(&n.e)
			fs.history_register_owned_actor(m.history, actor, pseudo, sd.conv.id)
		}
		node_after(n)
	}
	run_until(w, w.now + 1_000_000_000, true)
	gone := make(map[string]bool, alloc)
	for step in 0 ..< 4 {
		if !_ur_side_turn(c, &sides[step % 2]) {
			world_fail(w, "undo two: turn %d failed", step)
			return
		}
		if step == 2 {
			for t in sides[0].last {
				gone[t] = true
			}
		}
	}
	a := &sides[0]
	b := &sides[1]
	{
		context = instance_context(&n.inst)
		_, err := eng.convo_undo(&n.e, a.conv, a.turns[1])
		node_after(n)
		if err != .None {
			world_fail(w, "undo two: convo_undo: %v", err)
			return
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	present := make(map[string]bool, alloc)
	for _, data in _ur_disk(c) {
		for t in strings.split_lines(strings.trim_right(data, "\n"), context.temp_allocator) {
			present[t] = true
		}
	}
	for t in a.toks {
		if gone[t] && present[t] {
			world_fail(w, "undo two: A's %s from the undone turn survives the undo", t)
		}
		if !gone[t] && !present[t] {
			world_fail(w, "undo two: A's %s from before the undone turn is gone", t)
		}
	}
	for t in b.toks {
		if !present[t] {
			world_fail(w, "undo two: the other conversation's %s is gone after undoing A's turn", t)
		}
	}
	if len(b.toks) == 0 || len(gone) == 0 {
		world_fail(w, "undo two: the case wrote nothing to check (A %d, B %d)", len(a.toks), len(b.toks))
	}
}

@(test)
undo_two_convos :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad := 0
	count := env_u64("UR_TWO_SEEDS", 40)
	for seed in u64(1) ..= count {
		w := _ur_world(seed)
		a: virtual.Arena
		if virtual.arena_init_growing(&a, 1 << 20) == nil {
			_ur_two(w, virtual.arena_allocator(&a))
		}
		for f in w.failures {
			if bad < 30 {
				fmt.eprintf("undo_two_convos seed %d: %s\n", seed, f)
			}
		}
		if len(w.failures) > 0 {
			bad += 1
		}
		world_destroy(w)
		free(w)
		virtual.arena_destroy(&a)
	}
	fmt.eprintf("undo_two_convos: %d seeds, %d failed\n", count, bad)
	testing.expect(t, bad == 0, fmt.tprintf("undo_two_convos: %d failures", bad))
}

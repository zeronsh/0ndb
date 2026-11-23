package sim

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/obj"
import "../../src/prim"

BR_ROOT :: "/home/sim/branch"
BR_SWITCHES :: 4

@(private = "file")
Br_Ctx :: struct {
	w:      ^World,
	n:      ^Node,
	vfs:    prim.Vfs,
	tree:   eng.Object,
	conv:   eng.Object,
	space:  prim.Id,
	oi:     int,
	agent:  prim.Id,
	parent: obj.Rid,
	r0:     obj.Rid,
	u_a:    obj.Rid,
	u_b:    obj.Rid,
	alloc:  runtime.Allocator,
}

@(private = "file")
Br_State :: struct {
	disk:     map[string]string,
	position: obj.Rid,
}

@(private = "file")
_br_mount :: proc(c: ^Br_Ctx) -> ^fs.Mount {
	for &x in c.n.mounts {
		if x.root == BR_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_br_disk_write :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
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
_br_write :: proc(c: ^Br_Ctx, agent: bool, name: string, data: string) -> bool {
	n := c.n
	abs := strings.concatenate({BR_ROOT, "/", name}, context.temp_allocator)
	context = instance_context(&n.inst)
	defer node_after(n)
	m := _br_mount(c)
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
	err: prim.Error
	if len(data) == 0 {
		err = prim.remove(c.vfs, abs)
		if err == .None {
			err = prim.sync_dir(c.vfs, BR_ROOT)
		}
	} else {
		err = _br_disk_write(c.vfs, abs, transmute([]u8)data)
	}
	if scope != nil {
		fs.scope_close(n.reg, scope)
		if abs in n.writers {
			key, _ := delete_key(&n.writers, abs)
			delete(key, c.w.allocator)
		}
	} else {
		fs.mount_sync(m)
	}
	world_note(c.w, "branch: %s writes %s = %q", "agent" if agent else "person", name, data)
	return err == .None && !n.disk.dead
}

@(private = "file")
_br_disk :: proc(c: ^Br_Ctx) -> map[string]string {
	out := make(map[string]string, c.alloc)
	n := c.n
	n.disk.probe += 1
	defer n.disk.probe -= 1
	names := make([dynamic]string, context.temp_allocator)
	d: prim.Dir
	if prim.dir_open(c.vfs, &d, BR_ROOT, context.temp_allocator) != .None {
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
		data, rerr := prim.read_file(c.vfs, strings.concatenate({BR_ROOT, "/", nm}, context.temp_allocator), c.alloc)
		if rerr == .None {
			out[strings.clone(nm, c.alloc)] = string(data)
		}
	}
	return out
}

@(private = "file")
_br_state :: proc(c: ^Br_Ctx) -> (st: Br_State, ok: bool) {
	st.disk = _br_disk(c)
	context = instance_context(&c.n.inst)
	defer node_after(c.n)
	cs, err := eng.convo_status(&c.n.e, c.conv)
	if err != .None {
		world_fail(c.w, "branch: convo_status: %v", err)
		return st, false
	}
	st.position = cs.position if cs.browsing else cs.head
	return st, true
}

@(private = "file")
_br_same_disk :: proc(a, b: map[string]string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for k, v in a {
		if x, ok := b[k]; !ok || x != v {
			return false
		}
	}
	return true
}

@(private = "file")
_br_version :: proc(c: ^Br_Ctx) -> []u8 {
	m := _br_mount(c)
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
_br_msg :: proc(c: ^Br_Ctx, role: convo.Role, files: []convo.File_Delta, seal: bool) -> (msg: obj.Rid, ok: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, c.conv)
	if werr != .None {
		world_fail(c.w, "branch: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = c.parent, files = files})
	if merr != .None {
		world_fail(c.w, "branch: writer_message: %v", merr)
		return
	}
	if seal {
		if _, serr := convo.writer_seal(wr, m, .Done); serr != .None {
			world_fail(c.w, "branch: writer_seal: %v", serr)
			return
		}
	}
	convo.writer_commit(wr)
	c.parent = m
	return m, true
}

@(private = "file")
Br_Write :: struct {
	name: string,
	data: string,
}

@(private = "file")
_br_turn :: proc(c: ^Br_Ctx, user: bool, writes: []Br_Write) -> (u: obj.Rid, reply: obj.Rid, ok: bool) {
	w := c.w
	if user {
		u = _br_msg(c, .User, nil, true) or_return
	}
	files: []convo.File_Delta
	{
		context = instance_context(&c.n.inst)
		files = make([]convo.File_Delta, 1, c.alloc)
		files[0] = convo.File_Delta{mount = "work", tree = c.tree.id, version = _br_version(c)}
		node_after(c.n)
	}
	reply = _br_msg(c, .Assistant, files, false) or_return
	for x in writes {
		if !_br_write(c, true, x.name, x.data) {
			return
		}
		run_until(w, w.now + 300_000_000, true)
	}
	run_until(w, w.now + 1_000_000_000, true)
	{
		n := c.n
		context = instance_context(&n.inst)
		if m := _br_mount(c); m != nil {
			fs.mount_sync(m)
		}
		wr, werr := eng.convo_writer(&n.e, c.conv)
		if werr == .None {
			sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
			convo.writer_scope(wr, reply, .Turn, sid, c.agent, nil, nil)
			if _, serr := convo.writer_seal(wr, reply, .Done); serr != .None {
				world_fail(w, "branch: writer_seal: %v", serr)
				node_after(n)
				return
			}
			convo.writer_commit(wr)
		}
		node_after(n)
	}
	run_until(w, w.now + 1_000_000_000, true)
	return u, reply, true
}

@(private = "file")
_br_hooks :: proc() -> eng.Undo_Hooks {
	return eng.Undo_Hooks {
		hold = proc(data: rawptr, e: ^eng.Engine, convs: []eng.Object, undo: prim.Id) -> eng.Error {
			return .None
		},
		release = proc(data: rawptr, e: ^eng.Engine, convs: []eng.Object, undo: prim.Id) -> eng.Error {
			return .None
		},
	}
}

@(private = "file")
_br_setup :: proc(w: ^World, alloc: runtime.Allocator, relay := false) -> (c: ^Br_Ctx, ok: bool) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "branch: node start")
		return
	}
	c = new(Br_Ctx, alloc)
	c.w = w
	c.n = n
	c.vfs = disk_vfs(&n.disk)
	c.alloc = alloc
	m := &w.model
	{
		context = instance_context(&n.inst)
		space: prim.Id
		err: eng.Error
		if relay {
			space, err = eng.space_create(&n.e, "branch", "relay", w.relay.public)
		} else {
			space, err = eng.space_create(&n.e, "branch")
		}
		c.space = space
		if err != .None {
			world_fail(w, "branch: space_create: %v", err)
			return
		}
		eng.space_open(&n.e, space)
		c.tree, err = eng.tree_create(&n.e, space, "work")
		if err != .None {
			world_fail(w, "branch: tree_create: %v", err)
			return
		}
		c.conv, err = eng.convo_create(&n.e, space, eng.Convo_Settings{title = "branch"})
		if err != .None {
			world_fail(w, "branch: convo_create: %v", err)
			return
		}
		if merr := eng.convo_mount(&n.e, c.conv, "work", c.tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "branch: convo_mount: %v", merr)
			return
		}
		eng.undo_hooks_set(&n.e, _br_hooks())
		node_after(n)
	}
	cop := new_op(m, .Create, n, len(m.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	c.oi = oi
	prim.mkdir_all(c.vfs, BR_ROOT, 0o755)
	_br_disk_write(c.vfs, BR_ROOT + "/a.txt", transmute([]u8)string("<b1>\n<b2>\n<b3>\n"))
	_br_disk_write(c.vfs, BR_ROOT + "/b.txt", transmute([]u8)string("<b4>\n<b5>\n"))
	if err := node_mount(w, n, oi, BR_ROOT); err != .None {
		world_fail(w, "branch: mount: %v", err)
		return
	}
	append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(BR_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	if _br_mount(c) == nil {
		world_fail(w, "branch: mount missing")
		return
	}
	c.agent = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	return c, true
}

@(private = "file")
_br_world :: proc(seed: u64) -> ^World {
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
_br_build :: proc(w: ^World, alloc: runtime.Allocator) -> (c: ^Br_Ctx, ok: bool) {
	c = _br_setup(w, alloc) or_return
	_, r0 := _br_turn(c, true, {{"b.txt", "<b4>\n<b5>\n<t0>\n"}}) or_return
	c.r0 = r0
	u_a, _ := _br_turn(c, true, {{"a.txt", "<b1>\n<A1>\n<b3>\n"}, {"x.txt", "<A2>\n"}, {"b.txt", ""}}) or_return
	c.u_a = u_a
	return c, true
}

@(private = "file")
_br_edit :: proc(c: ^Br_Ctx, at: obj.Rid) -> (u: obj.Rid, ok: bool) {
	n := c.n
	{
		context = instance_context(&n.inst)
		_, err := eng.convo_move(&n.e, c.conv, .Edit, at)
		node_after(n)
		if err != .None {
			world_fail(c.w, "branch: the edit's move to %v: %v", at, err)
			return
		}
	}
	run_until(c.w, c.w.now + 5_000_000_000, true)
	c.parent = at
	return _br_msg(c, .User, nil, true)
}

@(private = "file")
_br_switch :: proc(c: ^Br_Ctx, to: obj.Rid) -> eng.Error {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	if to == c.r0 {
		_, err := eng.convo_move(&n.e, c.conv, .Edit, to)
		return err
	}
	_, err := eng.convo_switch(&n.e, c.conv, to)
	return err
}

@(private = "file")
_br_resume :: proc(c: ^Br_Ctx, to: obj.Rid, moves: int) -> eng.Error {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	eng.undo_hooks_set(&n.e, _br_hooks())
	list, lerr := eng.convo_undos(&n.e, c.conv, context.temp_allocator)
	if lerr != .None {
		return lerr
	}
	for u in list {
		if u.phase != .Released {
			return eng.convo_undo_drive(&n.e, c.conv, u.id)
		}
	}
	if len(list) >= moves {
		return .None
	}
	if to == c.r0 {
		_, err := eng.convo_move(&n.e, c.conv, .Edit, to)
		return err
	}
	_, err := eng.convo_switch(&n.e, c.conv, to)
	return err
}

@(private = "file")
_br_case :: proc(w: ^World, crash_switch: int, k: u64, arena: ^virtual.Arena, want: ^[BR_SWITCHES]map[string]string, record: bool) -> (crashed: bool, ok: bool) {
	if virtual.arena_init_growing(arena, 1 << 20) != nil {
		return
	}
	alloc := virtual.arena_allocator(arena)
	c := _br_build(w, alloc) or_return
	n := c.n
	moves := 0
	for s in 0 ..< BR_SWITCHES {
		to := c.u_b if s % 2 == 0 else c.u_a
		if s == 0 {
			to = c.r0
		}
		if s == 1 {
			c.parent = c.r0
			u_b, uok := _br_msg(c, .User, nil, true)
			if !uok {
				return
			}
			c.u_b = u_b
			c.parent = c.u_b
			if _, _, tok := _br_turn(c, false, {{"a.txt", "<B1>\n<b2>\n<b3>\n"}, {"y.txt", "<B2>\n"}}); !tok {
				world_fail(w, "branch: the turn on B failed")
				return
			}
			disk := _br_disk(c)
			if !_br_write(c, false, "a.txt", strings.concatenate({disk["a.txt"], "<P1>\n"}, context.temp_allocator)) {
				world_fail(w, "branch: the person's edit failed")
				return
			}
			run_until(w, w.now + 2_000_000_000, true)
		}
		crashes := w.stats.crashes
		if s == crash_switch && k > 0 {
			n.disk.crash_at = n.disk.stats.ops + k
		}
		moves += 1
		_br_switch(c, to)
		run_until(w, w.now + 20_000_000_000, true)
		n.disk.crash_at = 0
		if w.stats.crashes > crashes {
			crashed = true
			run_until(w, w.now + 20_000_000_000, true)
			if !n.alive {
				world_fail(w, "branch: node did not come back")
				return
			}
			if rerr := _br_resume(c, to, moves); rerr != .None {
				world_fail(w, "branch: resume after the crash: %v", rerr)
			}
			run_until(w, w.now + 10_000_000_000, true)
		}
		st := _br_state(c) or_return
		if record {
			want[s] = make(map[string]string, context.allocator)
			for name, data in st.disk {
				want[s][strings.clone(name)] = strings.clone(data)
			}
		} else if !_br_same_disk(st.disk, want[s]) {
			world_fail(w, "branch: after switch %d (crash at disk op %d of switch %d) the tree holds %v, not %v", s, k, crash_switch, st.disk, want[s])
		}
		pos_check: {
			context = instance_context(&n.inst)
			cs, _ := eng.convo_status(&n.e, c.conv)
			node_after(n)
			pos := cs.position if cs.browsing else cs.head
			ok_pos := pos == to
			if !ok_pos {
				context = instance_context(&n.inst)
				m, merr := eng.convo_message(&n.e, c.conv, {msg = pos}, context.temp_allocator)
				node_after(n)
				ok_pos = merr == .None && m.parent == to
			}
			if !ok_pos {
				world_fail(w, "branch: after switch %d the position is %v, not on %v", s, pos, to)
			}
		}
	}
	{
		context = instance_context(&n.inst)
		list, _ := eng.convo_undos(&n.e, c.conv, context.temp_allocator)
		h, _ := eng.convo_view(&n.e, c.conv)
		ud, _ := convo.undones(h, context.temp_allocator)
		node_after(n)
		if len(list) != BR_SWITCHES || len(ud) != BR_SWITCHES {
			world_fail(w, "branch: %d moves and %d undone records after %d switches", len(list), len(ud), BR_SWITCHES)
		}
		for u in list {
			if u.phase != .Released {
				world_fail(w, "branch: move %v stopped at phase %v", u.id, u.phase)
			}
		}
	}
	return crashed, true
}

@(private = "file")
_br_map :: proc(pairs: ..[2]string) -> map[string]string {
	out := make(map[string]string)
	for p in pairs {
		out[p[0]] = p[1]
	}
	return out
}

@(private = "file")
_br_expect :: proc(w: ^World, want: ^[BR_SWITCHES]map[string]string) {
	at_r1 := _br_map({"a.txt", "<b1>\n<b2>\n<b3>\n"}, {"b.txt", "<b4>\n<b5>\n<t0>\n"})
	a := _br_map({"a.txt", "<b1>\n<A1>\n<b3>\n<P1>\n"}, {"x.txt", "<A2>\n"})
	b := _br_map({"a.txt", "<B1>\n<b2>\n<b3>\n<P1>\n"}, {"b.txt", "<b4>\n<b5>\n<t0>\n"}, {"y.txt", "<B2>\n"})
	defer delete(at_r1)
	defer delete(a)
	defer delete(b)
	refs := [BR_SWITCHES]map[string]string{at_r1, a, b, a}
	for s in 0 ..< BR_SWITCHES {
		if !_br_same_disk(want[s], refs[s]) {
			world_fail(w, "branch reference: after switch %d the tree holds %v, not %v", s, want[s], refs[s])
		}
	}
}

@(test)
branch_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	seed := env_u64("BR_SEED", 1)
	want: [BR_SWITCHES]map[string]string
	bad := 0
	{
		rw := _br_world(seed)
		ra: virtual.Arena
		_, rok := _br_case(rw, -1, 0, &ra, &want, true)
		if rok {
			_br_expect(rw, &want)
		}
		for f in rw.failures {
			fmt.eprintf("branch_crash reference: %s\n", f)
		}
		if !rok || len(rw.failures) > 0 {
			bad += 1
		}
		world_destroy(rw)
		free(rw)
		virtual.arena_destroy(&ra)
	}
	points := 0
	only_s := int(env_u64("BR_CRASH_SWITCH", 0)) - 1
	only_k := env_u64("BR_CRASH_K", 0)
	if bad == 0 {
		for s in 0 ..< BR_SWITCHES {
			if only_s >= 0 && s != only_s {
				continue
			}
			for k in u64(1) ..= 20000 {
				if only_k != 0 && k != only_k {
					continue
				}
				w := _br_world(seed)
				ca: virtual.Arena
				crashed, cok := _br_case(w, s, k, &ca, &want, false)
				if !cok && len(w.failures) == 0 {
					world_fail(w, "the case did not run after a crash at disk op %d of switch %d", k, s)
				}
				for f in w.failures {
					if bad < 30 {
						fmt.eprintf("branch_crash switch %d disk op %d: %s\n", s, k, f)
					}
				}
				if len(w.failures) > 0 {
					bad += 1
				}
				world_destroy(w)
				free(w)
				virtual.arena_destroy(&ca)
				if !crashed || only_k != 0 {
					break
				}
				points += 1
			}
		}
	}
	for s in 0 ..< BR_SWITCHES {
		for name, data in want[s] {
			delete(name)
			delete(data)
		}
		delete(want[s])
	}
	fmt.eprintf("branch_crash: %d crash points over %d switches, %d failed\n", points, BR_SWITCHES, bad)
	testing.expect(t, bad == 0, fmt.tprintf("branch_crash: %d failures", bad))
}

@(private = "file")
_br_disk_of :: proc(c: ^Br_Ctx, n: ^Node) -> map[string]string {
	saved_n, saved_vfs := c.n, c.vfs
	c.n, c.vfs = n, disk_vfs(&n.disk)
	defer {
		c.n, c.vfs = saved_n, saved_vfs
	}
	return _br_disk(c)
}

@(private = "file")
_br_position :: proc(c: ^Br_Ctx, n: ^Node) -> (pos: obj.Rid, ok: bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	cs, err := eng.convo_status(&n.e, c.conv)
	if err != .None {
		return {}, false
	}
	return cs.position if cs.browsing else cs.head, true
}

@(private = "file")
_br_cut :: proc(n: ^Node, cut: bool) {
	n.partitioned = cut
	if cut {
		for x in n.conns {
			conn_reset(x, true)
		}
	}
}

@(private = "file")
_br_concurrent :: proc(w: ^World, arena: ^virtual.Arena) {
	if virtual.arena_init_growing(arena, 1 << 20) != nil {
		return
	}
	alloc := virtual.arena_allocator(arena)
	if !relay_start(&w.relay) {
		world_fail(w, "branch concurrent: relay start")
		return
	}
	c, ok := _br_setup(w, alloc, true)
	if !ok {
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	_, r0, tok := _br_turn(c, true, {{"b.txt", "<b4>\n<b5>\n<t0>\n"}})
	if !tok {
		return
	}
	c.r0 = r0
	u_a, _, aok := _br_turn(c, true, {{"a.txt", "<b1>\n<A1>\n<b3>\n"}, {"x.txt", "<A2>\n"}, {"b.txt", ""}})
	if !aok {
		return
	}
	u_b, bok := _br_edit(c, r0)
	if !bok {
		return
	}
	if _, _, tok2 := _br_turn(c, false, {{"a.txt", "<B1>\n<b2>\n<b3>\n"}, {"y.txt", "<B2>\n"}}); !tok2 {
		return
	}
	u_c, cok := _br_edit(c, r0)
	if !cok {
		return
	}
	_br_switch(c, u_b)
	run_until(w, w.now + 5_000_000_000, true)
	c.parent = {}
	if !node_start(b) {
		world_fail(w, "branch concurrent: second device start")
		return
	}
	join: {
		proof: []u8
		{
			context = instance_context(&a.inst)
			p, err := eng.member_add(&a.e, c.space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
			node_after(a)
			if err != .None {
				world_fail(w, "branch concurrent: member_add: %v", err)
				return
			}
			proof = p
		}
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, c.space, proof, "branch", "relay", w.relay.public); err != .None {
			world_fail(w, "branch concurrent: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, c.space); err != .None {
			world_fail(w, "branch concurrent: space_open: %v", err)
			return
		}
		eng.undo_hooks_set(&b.e, _br_hooks())
	}
	run_until(w, w.now + 20_000_000_000, true)
	prim.mkdir_all(disk_vfs(&b.disk), BR_ROOT, 0o755)
	if err := node_mount(w, b, c.oi, BR_ROOT); err != .None {
		world_fail(w, "branch concurrent: second mount: %v", err)
		return
	}
	run_until(w, w.now + 30_000_000_000, true)
	want_b := _br_map({"a.txt", "<B1>\n<b2>\n<b3>\n"}, {"b.txt", "<b4>\n<b5>\n<t0>\n"}, {"y.txt", "<B2>\n"})
	defer delete(want_b)
	if got := _br_disk_of(c, b); !_br_same_disk(got, want_b) {
		world_fail(w, "branch concurrent: the second device holds %v before the switches, not branch B %v", got, want_b)
		return
	}
	pa, pb: obj.Rid
	for _ in 0 ..< 120 {
		pa, _ = _br_position(c, a)
		pb, _ = _br_position(c, b)
		if pa == pb {
			break
		}
		run_until(w, w.now + 500_000_000, true)
	}
	if pa != pb {
		world_fail(w, "branch concurrent: the devices sit at %v and %v before the switches", pa, pb)
		return
	}
	_br_cut(a, true)
	_br_cut(b, true)
	_br_switch(c, u_a)
	saved := c.n
	c.n = b
	_br_switch(c, u_c)
	c.n = saved
	run_until(w, w.now + 5_000_000_000, true)
	_br_cut(a, false)
	_br_cut(b, false)
	run_until(w, w.now + 60_000_000_000, true)
	list: []convo.Undo_State
	{
		context = instance_context(&a.inst)
		l, lerr := eng.convo_undos(&a.e, c.conv, alloc)
		node_after(a)
		if lerr != .None {
			world_fail(w, "branch concurrent: convo_undos: %v", lerr)
			return
		}
		list = l
	}
	winner := -1
	for u, i in list {
		if u.cause == .Switch {
			winner = i
		}
	}
	if winner < 0 {
		world_fail(w, "branch concurrent: the concurrent switches are missing from %v", list)
		return
	}
	to := list[winner].to
	want_a := _br_map({"a.txt", "<b1>\n<A1>\n<b3>\n"}, {"x.txt", "<A2>\n"})
	defer delete(want_a)
	want_c := _br_map({"a.txt", "<b1>\n<b2>\n<b3>\n"}, {"b.txt", "<b4>\n<b5>\n<t0>\n"})
	defer delete(want_c)
	want := want_c if to == u_c else want_a
	for n in ([2]^Node{a, b}) {
		got := _br_disk_of(c, n)
		if !_br_same_disk(got, want) {
			world_fail(w, "branch concurrent: %s holds %v after both switches, not the winner's branch (%s) %v", n.name, got, "C" if to == u_c else "A", want)
		}
		pos, pok := _br_position(c, n)
		if !pok {
			world_fail(w, "branch concurrent: %s has no position", n.name)
			continue
		}
		if pos != to {
			world_fail(w, "branch concurrent: %s sits at %v, not on the winner %v", n.name, pos, to)
		}
	}
	rebased := 0
	for u in list {
		if u.cause == .Rebase {
			rebased += 1
			if u.staged.seg != list[winner].staged.seg {
				world_fail(w, "branch concurrent: a rebase by %v, not by the winner's device %v", u.staged.seg, list[winner].staged.seg)
			}
		}
		if u.phase != .Released {
			world_fail(w, "branch concurrent: move %v (%v) stopped at %v", u.id, u.cause, u.phase)
		}
	}
	if rebased == 0 {
		world_fail(w, "branch concurrent: the winner never rebased over the concurrent switch")
	}
}

@(test)
branch_concurrent :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	bad := 0
	count := env_u64("BR_CONC_SEEDS", 10)
	for seed in u64(1) ..= count {
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
		a: virtual.Arena
		_br_concurrent(w, &a)
		for f in w.failures {
			if bad < 30 {
				fmt.eprintf("branch_concurrent seed %d: %s\n", seed, f)
			}
		}
		if len(w.failures) > 0 {
			bad += 1
		}
		world_destroy(w)
		free(w)
		virtual.arena_destroy(&a)
	}
	fmt.eprintf("branch_concurrent: %d seeds, %d failed\n", count, bad)
	testing.expect(t, bad == 0, fmt.tprintf("branch_concurrent: %d failures", bad))
}

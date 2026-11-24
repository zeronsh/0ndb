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

@(private = "file")
RB_ROOT :: "/work/read-between-n0"

@(private = "file")
Rb_Observer :: enum u8 {
	Names_Writer,
	Blind,
	None,
}

@(private = "file")
Rb_Ctx :: struct {
	w:      ^World,
	n:      ^Node,
	vfs:    prim.Vfs,
	tree:   eng.Object,
	conv:   eng.Object,
	agent:  prim.Id,
	parent: obj.Rid,
	r0:     obj.Rid,
	alloc:  runtime.Allocator,
}

@(private = "file")
_rb_blind :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	return nil, false
}

@(private = "file")
_rb_mount :: proc(c: ^Rb_Ctx) -> ^fs.Mount {
	for &x in c.n.mounts {
		if x.root == RB_ROOT && x.m != nil {
			return x.m
		}
	}
	return nil
}

@(private = "file")
_rb_put :: proc(c: ^Rb_Ctx, name, data: string) {
	vfs := c.vfs
	abs := strings.concatenate({RB_ROOT, "/", name}, context.temp_allocator)
	fd, err := prim.open_file(vfs, abs, {.Write, .Create, .Truncate}, 0o644)
	if err == .None {
		err = prim.write_at(vfs, fd, transmute([]u8)data, 0)
		if err == .None {
			err = prim.datasync(vfs, fd)
		}
		prim.close_file(vfs, fd)
	}
	if err != .None {
		world_fail(c.w, "read between: write %s: %v", name, err)
	}
	context = instance_context(&c.n.inst)
	node_after(c.n)
}

@(private = "file")
_rb_disk :: proc(c: ^Rb_Ctx) -> map[string]string {
	out := make(map[string]string, c.alloc)
	n := c.n
	n.disk.probe += 1
	defer n.disk.probe -= 1
	d: prim.Dir
	if prim.dir_open(c.vfs, &d, RB_ROOT, context.temp_allocator) != .None {
		return out
	}
	names := make([dynamic]string, context.temp_allocator)
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
		if data, rerr := prim.read_file(c.vfs, strings.concatenate({RB_ROOT, "/", nm}, context.temp_allocator), c.alloc); rerr == .None {
			out[strings.clone(nm, c.alloc)] = string(data)
		}
	}
	return out
}

@(private = "file")
_rb_expect :: proc(c: ^Rb_Ctx, label: string, want: map[string]string) {
	got := _rb_disk(c)
	same := len(got) == len(want)
	for k, v in want {
		if x, ok := got[k]; !ok || x != v {
			same = false
		}
	}
	if !same {
		world_fail(c.w, "read between %s: disk is %v, want %v", label, got, want)
	}
}

@(private = "file")
_rb_version :: proc(c: ^Rb_Ctx) -> []u8 {
	m := _rb_mount(c)
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
_rb_msg :: proc(c: ^Rb_Ctx, role: convo.Role, files: []convo.File_Delta, seal: bool) -> (msg: obj.Rid, ok: bool) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, c.conv)
	if werr != .None {
		world_fail(c.w, "read between: convo_writer: %v", werr)
		return
	}
	m, merr := convo.writer_message(wr, convo.Msg_Spec{role = role, parent = c.parent, files = files})
	if merr != .None {
		world_fail(c.w, "read between: writer_message: %v", merr)
		return
	}
	if seal {
		if _, serr := convo.writer_seal(wr, m, .Done); serr != .None {
			world_fail(c.w, "read between: writer_seal: %v", serr)
			return
		}
	}
	convo.writer_commit(wr)
	c.parent = m
	return m, true
}

@(private = "file")
_rb_seal :: proc(c: ^Rb_Ctx, reply: obj.Rid, sid: prim.Id) {
	n := c.n
	context = instance_context(&n.inst)
	defer node_after(n)
	wr, werr := eng.convo_writer(&n.e, c.conv)
	if werr != .None {
		world_fail(c.w, "read between: convo_writer: %v", werr)
		return
	}
	convo.writer_scope(wr, reply, .Turn, sid, c.agent, nil, nil)
	if _, serr := convo.writer_seal(wr, reply, .Done); serr != .None {
		world_fail(c.w, "read between: writer_seal: %v", serr)
	}
	convo.writer_commit(wr)
}

@(private = "file")
_rb_tool :: proc(c: ^Rb_Ctx, name, data: string, named: bool) {
	n := c.n
	m := _rb_mount(c)
	abs := strings.concatenate({RB_ROOT, "/", name}, c.alloc)
	tool: ^fs.Scope
	open: {
		context = instance_context(&n.inst)
		defer node_after(n)
		tool = fs.scope_open(n.reg, m, prim.id_new_with(node_clock(&n.clock), rng_random(&c.w.rng)), c.agent, nil, fs.Observe_Since{mono = prim.clock_mono_ns(n.e.cfg.clock), wall = prim.clock_wall_ns(n.e.cfg.clock)})
		if named {
			_writer_set(c.w, n, abs, Writer_Info{scope = tool, agent = true})
			fs.mount_observe_begin(m, name, tool)
		}
	}
	_rb_put(c, name, data)
	run_until(c.w, c.w.now + 3_000_000, false)
	close: {
		context = instance_context(&n.inst)
		defer node_after(n)
		fs.scope_close(n.reg, tool)
		if named {
			key, _ := delete_key(&n.writers, abs)
			delete(key, c.w.allocator)
		}
	}
}

@(private = "file")
_rb_run :: proc(w: ^World, model: Rb_Observer, step: int, alloc: runtime.Allocator) {
	n := w.nodes[0]
	if !node_start(n) {
		world_fail(w, "read between: node start")
		return
	}
	c := new(Rb_Ctx, alloc)
	c.w = w
	c.n = n
	c.vfs = disk_vfs(&n.disk)
	c.alloc = alloc
	mm := &w.model
	setup: {
		context = instance_context(&n.inst)
		defer node_after(n)
		space, err := eng.space_create(&n.e, "read-between")
		if err == .None {
			err = eng.space_open(&n.e, space)
		}
		if err == .None {
			c.tree, err = eng.tree_create(&n.e, space, "work")
		}
		if err == .None {
			c.conv, err = eng.convo_create(&n.e, space, eng.Convo_Settings{title = "read between"})
		}
		if err != .None {
			world_fail(w, "read between: setup: %v", err)
			return
		}
		if merr := eng.convo_mount(&n.e, c.conv, "work", c.tree.id, {}); merr != .None && merr != .Pending {
			world_fail(w, "read between: convo_mount: %v", merr)
			return
		}
		eng.undo_hooks_set(&n.e, eng.Undo_Hooks {
			hold = proc(data: rawptr, e: ^eng.Engine, convs: []eng.Object, undo: prim.Id) -> eng.Error {return .None},
			release = proc(data: rawptr, e: ^eng.Engine, convs: []eng.Object, undo: prim.Id) -> eng.Error {return .None},
		})
	}
	cop := new_op(mm, .Create, n, len(mm.objs))
	op_done(cop, 0, .None)
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx, o = c.tree}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	append(&mm.objs, ob)
	oi := len(mm.objs) - 1
	prim.mkdir_all(c.vfs, RB_ROOT, 0o755)
	_rb_put(c, "a.txt", "1\n2\n3\n")
	if err := node_mount(w, n, oi, RB_ROOT); err != .None {
		world_fail(w, "read between: mount: %v", err)
		return
	}
	append(&mm.mounts, M_Mount{node = n.idx, oi = oi, root = strings.clone(RB_ROOT, w.allocator)})
	run_until(w, w.now + 2_000_000_000, true)
	m := _rb_mount(c)
	if m == nil {
		world_fail(w, "read between: mount missing")
		return
	}
	switch model {
	case .Names_Writer:
	case .Blind:
		n.reg.observer.changed = _rb_blind
	case .None:
		n.reg.observer.changed = nil
		n.reg.observer.start = nil
	}
	own: {
		context = instance_context(&n.inst)
		defer node_after(n)
		pseudo: prim.Id
		c.agent, pseudo = eng.scope_actor(&n.e, c.conv.id, m.id, m.line)
		if err := fs.history_register_owned_actor(m.history, c.agent, pseudo, c.conv.id); err != .None {
			world_fail(w, "read between: register the turn's actor: %v", err)
			return
		}
	}
	c.r0 = _rb_msg(c, .User, nil, true) or_else {}
	_rb_msg(c, .Assistant, nil, true)
	c.r0 = c.parent
	u, uok := _rb_msg(c, .User, nil, true)
	if !uok {
		return
	}
	files := make([]convo.File_Delta, 1, alloc)
	files_set: {
		context = instance_context(&n.inst)
		defer node_after(n)
		files[0] = convo.File_Delta{mount = "work", tree = c.tree.id, version = _rb_version(c)}
	}
	reply, rok := _rb_msg(c, .Assistant, files, false)
	if !rok {
		return
	}
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	turn: ^fs.Scope
	turn_open: {
		context = instance_context(&n.inst)
		defer node_after(n)
		turn = fs.scope_open(n.reg, m, sid, c.agent)
	}
	read: {
		context = instance_context(&n.inst)
		defer node_after(n)
		r := fs.scope_open(n.reg, m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), c.agent, nil, fs.Observe_Since{mono = prim.clock_mono_ns(n.e.cfg.clock), wall = prim.clock_wall_ns(n.e.cfg.clock)})
		if err := fs.scope_read_base(r, "a.txt", transmute([]u8)string("1\n2\n3\n")); err != .None {
			world_fail(w, "between: scope_read_base: %v", err)
		}
		fs.scope_close(n.reg, r)
	}
	run_until(w, w.now + 100_000_000, false)
	api: {
		context = instance_context(&n.inst)
		defer node_after(n)
		if err := eng.tree_write(&n.e, c.tree, "a.txt", transmute([]u8)string("1\n2\nP\n"), tree_base(&n.e, c.tree)); err != .None {
			world_fail(w, "between: tree_write: %v", err)
		}
	}
	if step < 0 {
		run_until(w, w.now + 2_000_000_000, true)
		if d := _rb_disk(c)["a.txt"]; d != "1\n2\nP\n" {
			world_fail(w, "read between: the person's write never reached disk (%q)", d)
			return
		}
	}
	for _ in 0 ..< step {
		t, ok := next_time(w)
		if !ok {
			break
		}
		run_until(w, t, false)
	}
	was := _rb_disk(c)["a.txt"]
	_rb_tool(c, "a.txt", strings.concatenate({"A\n", was[2:]}, alloc), model == .Names_Writer)
	run_until(w, w.now + 500_000_000, true)
	turn_close: {
		context = instance_context(&n.inst)
		defer node_after(n)
		fs.scope_close(n.reg, turn)
	}
	_rb_seal(c, reply, sid)
	run_until(w, w.now + 1_000_000_000, true)
	blame: {
		context = instance_context(&n.inst)
		defer node_after(n)
		owners: []fs.Span_Owner
		data, spans, berr := eng.tree_blame(&n.e, c.tree, "a.txt", context.temp_allocator, "main", &owners)
		if berr != .None || len(owners) != len(spans) {
			world_fail(w, "read between: blame: %v", berr)
			return
		}
		pos := 0
		for sp, i in spans {
			text := string(data[pos:][:sp.len])
			pos += sp.len
			want := fs.Owner_Kind.Agent if strings.contains(text, "A") else .Person
			if owners[i].kind != want {
				world_fail(w, "read between: %q is credited to %v, want %v", text, owners[i].kind, want)
			}
		}
	}
	after := make(map[string]string, alloc)
	after["a.txt"] = "A\n2\nP\n"
	_rb_expect(c, "after the turn", after)
	undone := make(map[string]string, alloc)
	undone["a.txt"] = "1\n2\nP\n"
	undo: prim.Id
	do_undo: {
		context = instance_context(&n.inst)
		defer node_after(n)
		x, err := eng.convo_undo(&n.e, c.conv, u)
		if err != .None {
			world_fail(w, "between: convo_undo: %v", err)
		}
		undo = x
	}
	run_until(w, w.now + 5_000_000_000, true)
	_rb_expect(c, "after undoing the turn", undone)
	do_redo: {
		context = instance_context(&n.inst)
		defer node_after(n)
		if _, err := eng.convo_redo(&n.e, c.conv, undo); err != .None {
			world_fail(w, "between: convo_redo: %v", err)
		}
	}
	run_until(w, w.now + 5_000_000_000, true)
	_rb_expect(c, "after redoing it", after)
}

@(test)
read_between :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for model in Rb_Observer {
		for step in -1 ..< 40 {
			seed := u64(1)
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
			a: virtual.Arena
			if virtual.arena_init_growing(&a, 1 << 20) == nil {
				_rb_run(w, model, step, virtual.arena_allocator(&a))
			}
			for f in w.failures {
				fmt.eprintf("read_between %v step %d: %s\n", model, step, f)
			}
			testing.expect(t, len(w.failures) == 0, fmt.tprintf("read_between %v step %d failed", model, step))
			world_destroy(w)
			free(w)
			virtual.arena_destroy(&a)
		}
	}
}

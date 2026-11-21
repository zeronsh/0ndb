package sim

import "core:fmt"
import "core:slice"
import "core:strings"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fstree"
import "../../src/prim"

WORK_PREFIX :: "/work/"
WATCH_OVERFLOW :: 256

Sim_Mount :: struct {
	oi:   int,
	root: string,
	m:    ^fs.Mount,
}

M_Mount :: struct {
	node: int,
	oi:   int,
	root: string,
}

Writer_Info :: struct {
	scope: ^fs.Scope,
	agent: bool,
}

sim_watcher :: proc(n: ^Node) -> fs.Watcher {
	return fs.Watcher{data = n, start = _w_start, stop = _w_stop, poll = _w_poll, wait = _w_wait}
}

sim_observer :: proc(n: ^Node) -> fs.Write_Observer {
	return fs.Write_Observer{data = n, start = _o_start, changed = _o_changed}
}

@(private = "file")
_w_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	n := (^Node)(data)
	n.disk.watching = true
	n.disk.watch_prefix = WORK_PREFIX
	return .None
}

@(private = "file")
_w_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	n := (^Node)(data)
	n.disk.watching = false
	disk_events_clear(&n.disk)
}

@(private = "file")
_w_poll :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	watch_deliver((^Node)(data), reg)
	return .None
}

@(private = "file")
_w_wait :: proc(data: rawptr, reg: ^fs.Registry, ms: i32) -> bool {
	return watch_deliver((^Node)(data), reg) > 0
}

@(private = "file")
_o_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	return .None
}

@(private = "file")
_o_changed :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	n := (^Node)(data)
	abs := strings.concatenate({m.root, "/", rel}, context.temp_allocator)
	if info, ok := n.writers[abs]; ok {
		return info.scope, true
	}
	return nil, false
}

watch_deliver :: proc(n: ^Node, reg: ^fs.Registry) -> int {
	d := &n.disk
	if len(d.events) == 0 || reg == nil {
		return 0
	}
	if len(d.events) > WATCH_OVERFLOW {
		disk_events_clear(d)
		fs.registry_notify(reg, "", .Overflow)
		return 1
	}
	evs := make([]Watch_Ev, len(d.events), context.temp_allocator)
	for ev, i in d.events {
		evs[i] = Watch_Ev{path = strings.clone(ev.path, context.temp_allocator), closed = ev.closed}
	}
	disk_events_clear(d)
	for ev in evs {
		fs.registry_notify(reg, ev.path, .Closed if ev.closed else .Changed)
	}
	return len(evs)
}

watch_event :: proc(w: ^World, n: ^Node) {
	n.watch_scheduled = false
	if !n.alive || n.reg == nil {
		return
	}
	context = instance_context(&n.inst)
	watch_deliver(n, n.reg)
	node_after(n)
}

node_mount :: proc(w: ^World, n: ^Node, oi: int, root: string) -> eng.Error {
	context = instance_context(&n.inst)
	defer node_after(n)
	if n.reg == nil {
		reg, rerr := eng.registry(&n.e)
		if rerr != .None {
			return rerr
		}
		n.reg = reg
	}
	if err := prim.mkdir_all(disk_vfs(&n.disk), root, 0o755); err != .None {
		return .Io
	}
	m, err := eng.tree_mount(&n.e, w.model.objs[oi].o, root)
	if err != .None {
		return err
	}
	append(&n.mounts, Sim_Mount{oi = oi, root = strings.clone(root, w.allocator), m = m})
	return .None
}

node_mounts_drop :: proc(w: ^World, n: ^Node) {
	for sm in n.mounts {
		delete(sm.root, w.allocator)
	}
	clear(&n.mounts)
	for k in n.writers {
		delete(k, w.allocator)
	}
	clear(&n.writers)
	n.reg = nil
	n.watch_scheduled = false
}

node_remount :: proc(w: ^World, n: ^Node) {
	for mm in w.model.mounts {
		if mm.node != n.idx || !n.alive {
			continue
		}
		if err := node_mount(w, n, mm.oi, mm.root); err != .None && n.alive {
			if w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
				n.restart_pending = true
				context = instance_context(&n.inst)
				node_after(n)
				return
			}
			world_fail(w, "%s could not remount %s after restart: %v", n.name, mm.root, err)
		}
	}
}

op_mount :: proc(w: ^World, n: ^Node) {
	m := &w.model
	cands := make([dynamic]int, context.temp_allocator)
	for ob, i in m.objs {
		if ob.kind != .Tree || !obj_exists(m, i) {
			continue
		}
		si := space_index(m, ob.o.space)
		if si < 0 || !space_member(&m.spaces[si], n.idx) {
			continue
		}
		already := false
		for mm in m.mounts {
			already ||= mm.node == n.idx && mm.oi == i
		}
		if !already {
			append(&cands, i)
		}
	}
	if len(cands) == 0 {
		return
	}
	oi := cands[rng_int(&w.rng, len(cands))]
	{
		context = instance_context(&n.inst)
		_, found, err := eng.catalog_get(&n.e, m.objs[oi].o, context.temp_allocator)
		node_after(n)
		if err != .None || !found {
			return
		}
	}
	root := fmt.aprintf("%s%s-%s", WORK_PREFIX, id_short(m.objs[oi].o.id), n.name, allocator = w.allocator)
	op := new_op(m, .Mount_Tree, n, oi)
	op.path = root
	err := node_mount(w, n, oi, root)
	world_note(w, "%s mounts %s at %s -> %v", n.name, id_short(m.objs[oi].o.id), root, err)
	if err == .None {
		append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = root})
		op_done(op, 0, .None)
		op.status = .Acked
	} else if err == .Missing || err == .Pending {
		op.status = .Failed
	} else if n.alive {
		if w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
			op.status = .Failed
			n.restart_pending = true
			return
		}
		world_fail(w, "%s tree_mount failed: %v", n.name, err)
		op.status = .Failed
	}
}

@(private = "file")
_disk_write :: proc(vfs: prim.Vfs, path: string, data: []u8, atomic: bool) -> prim.Error {
	target := path
	if atomic {
		target = strings.concatenate({prim.dir_name(path), "/.", path[len(prim.dir_name(path)) + 1:], ".swp"}, context.temp_allocator)
	}
	fd := prim.open_file(vfs, target, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	prim.close_file(vfs, fd)
	if err != .None {
		return err
	}
	if atomic {
		prim.rename(vfs, target, path) or_return
	}
	return prim.sync_dir(vfs, prim.dir_name(path))
}

op_disk_edit :: proc(w: ^World, n: ^Node, agent: bool) {
	m := &w.model
	live := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil {
			append(&live, i)
		}
	}
	if len(live) == 0 {
		return
	}
	sm := n.mounts[live[rng_int(&w.rng, len(live))]]
	paths := TREE_PATHS
	name := paths[rng_int(&w.rng, len(paths))]
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	old, _ := prim.read_file(vfs, abs, context.temp_allocator)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	op := new_op(m, .Disk_Agent if agent else .Disk_Person, n, sm.oi)
	op.path = strings.clone(name, w.allocator)
	overwrite := len(old) == 0 || rng_chance(&w.rng, 1, 3)
	op.overwrite = overwrite && len(old) > 0
	b := strings.builder_make(context.temp_allocator)
	if overwrite {
		for t in parse_tokens(old) {
			append(&op.deletes, strings.clone(t.text, w.allocator))
		}
	} else {
		strings.write_bytes(&b, old)
	}
	for _ in 0 ..< 1 + rng_int(&w.rng, 2) {
		tok := new_token(m, n, "a" if agent else "p")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	context = instance_context(&n.inst)
	scope: ^fs.Scope
	if agent {
		sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		op.actor = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		scope = fs.scope_open(n.reg, sm.m, sid, op.actor)
	}
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = agent})
	atomic := !agent && rng_chance(&w.rng, 1, 2)
	if atomic {
		_writer_set(w, n, strings.concatenate({sm.root, "/.", name, ".swp"}, context.temp_allocator), Writer_Info{scope = scope, agent = agent})
	}
	err := _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), atomic)
	serr := fs.Error.None
	if agent && !n.disk.dead {
		serr = fs.scope_close(n.reg, scope)
		_forget_scope(w, n, scope)
	}
	world_note(w, "%s %s(actor %s) %s %s/%s replaced %v wrote %v -> %v %v", n.name, "agent" if agent else "person", id_short(op.actor), "overwrite" if overwrite else "append", id_short(m.objs[sm.oi].o.id), name, op.deletes[:], op.tokens[:], err, serr)
	if n.disk.dead {
		node_after(n)
		return
	}
	if err != .None {
		op.status = .Failed
		if w.cfg.io_rate > 0 {
			op.status = .Uncertain
			n.restart_pending = true
		} else {
			world_fail(w, "%s disk edit failed: %v", n.name, err)
		}
	} else {
		op_done(op, 0, .None)
		op.status = .Acked
		if serr != .None && w.cfg.io_rate == 0 {
			world_fail(w, "%s scope_close failed: %v", n.name, serr)
		}
	}
	node_after(n)
}

@(private = "file")
_forget_scope :: proc(w: ^World, n: ^Node, scope: ^fs.Scope) {
	keys := make([dynamic]string, context.temp_allocator)
	for k, v in n.writers {
		if v.scope == scope && scope != nil {
			append(&keys, k)
		}
	}
	for k in keys {
		owned, _ := delete_key(&n.writers, k)
		delete(owned, w.allocator)
	}
}

tree_file_spans :: proc(n: ^Node, o: eng.Object, path: string) -> []crdt_span {
	hist, err := eng.tree_history(&n.e, o)
	if err != .None {
		return nil
	}
	defer eng.tree_release(&n.e, o)
	snap := fstree.current(&hist.tree)
	id, ok, lerr := fstree.lookup(&snap, path)
	if lerr != nil || !ok {
		return nil
	}
	f, ferr := fs.history_file(hist, id)
	if ferr != .None {
		return nil
	}
	raw := crdt.text_spans(&f.text, &hist.g, context.temp_allocator)
	out := make([]crdt_span, len(raw), context.temp_allocator)
	for s, i in raw {
		out[i] = crdt_span{actor = s.id.actor, len = s.len}
	}
	return out
}

check_mounts :: proc(w: ^World) {
	for n in w.nodes {
		if !n.alive {
			continue
		}
		for sm in n.mounts {
			if sm.m == nil {
				continue
			}
			ob := &w.model.objs[sm.oi]
			context = instance_context(&n.inst)
			names, lerr := eng.tree_list(&n.e, ob.o, "", context.temp_allocator)
			if lerr != .None {
				world_fail(w, "mount: %s cannot list mounted tree %s: %v", n.name, id_short(ob.o.id), lerr)
				node_after(n)
				continue
			}
			slice.sort(names)
			want := strings.builder_make(context.temp_allocator)
			for nm in names {
				data, _ := eng.tree_read(&n.e, ob.o, nm, context.temp_allocator)
				fmt.sbprintf(&want, "%s=%q\n", nm, string(data))
			}
			have := strings.builder_make(context.temp_allocator)
			files := make([dynamic]Disk_File, context.temp_allocator)
			disk_walk(&n.disk, &files)
			prefix := strings.concatenate({sm.root, "/"}, context.temp_allocator)
			for f in files {
				if !strings.has_prefix(f.path, prefix) {
					continue
				}
				rel := f.path[len(prefix):]
				if fs.path_internal(rel) || strings.has_prefix(rel, ".") {
					continue
				}
				fmt.sbprintf(&have, "%s=%q\n", rel, string(f.data))
			}
			if strings.to_string(want) != strings.to_string(have) {
				world_fail(w, "mount: %s disk at %s differs from tree %s:\n--- tree\n%s--- disk\n%s", n.name, sm.root, id_short(ob.o.id), strings.to_string(want), strings.to_string(have))
			}
			node_after(n)
		}
	}
}

@(private = "file")
_writer_set :: proc(w: ^World, n: ^Node, path: string, info: Writer_Info) {
	if _, has := n.writers[path]; has {
		n.writers[path] = info
		return
	}
	n.writers[strings.clone(path, w.allocator)] = info
}

op_git_mount :: proc(w: ^World, n: ^Node) {
	m := &w.model
	cands := make([dynamic]int, context.temp_allocator)
	for &sp, i in m.spaces {
		if space_member(&sp, n.idx) {
			append(&cands, i)
		}
	}
	if len(cands) == 0 {
		return
	}
	space := m.spaces[cands[rng_int(&w.rng, len(cands))]].id
	cop := new_op(m, .Create, n, len(m.objs))
	cop.token = new_token(m, n, "t")
	ob := M_Obj{kind = .Tree, creator = n.idx, op = cop.idx}
	ob.removed = make(map[string]bool, w.allocator)
	ob.shared = make([dynamic]int, w.allocator)
	o: eng.Object
	err: eng.Error
	{
		context = instance_context(&n.inst)
		o, err = eng.tree_create(&n.e, space, cop.token)
		op_result(cop, n, err)
		node_after(n)
	}
	ob.o = o
	append(&m.objs, ob)
	oi := len(m.objs) - 1
	if err != .None || !n.alive {
		return
	}
	paths := TREE_PATHS
	files := make([dynamic]Git_File, context.temp_allocator)
	for p in paths {
		if len(files) > 0 && rng_chance(&w.rng, 1, 2) {
			continue
		}
		op := new_op(m, .Git_Mount, n, oi)
		op.path = strings.clone(p, w.allocator)
		b := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< 1 + rng_int(&w.rng, 2) {
			tok := new_token(m, n, "g")
			append(&op.tokens, tok)
			strings.write_string(&b, tok)
			strings.write_byte(&b, '\n')
		}
		append(&files, Git_File{name = p, data = transmute([]u8)strings.to_string(b)})
	}
	root := fmt.aprintf("%s%s-%s-git", WORK_PREFIX, id_short(o.id), n.name, allocator = w.allocator)
	vfs := disk_vfs(&n.disk)
	gerr := git_checkout_create(vfs, root, files[:], clock_wall(&n.clock) / 1_000_000_000, rng_u64(&w.rng), &n.clock)
	if n.disk.dead {
		context = instance_context(&n.inst)
		node_after(n)
		return
	}
	if gerr != .None {
		if w.cfg.io_rate > 0 {
			n.restart_pending = true
			context = instance_context(&n.inst)
			node_after(n)
			return
		}
		world_fail(w, "%s could not build git checkout %s: %v", n.name, root, gerr)
		return
	}
	merr := node_mount(w, n, oi, root)
	world_note(w, "%s git checkout %s mounted at %s -> %v", n.name, id_short(o.id), root, merr)
	for op in m.ops[cop.idx + 1:] {
		if op.kind == .Git_Mount && op.obj == oi {
			if merr == .None {
				op_done(op, 0, .None)
				op.status = .Acked
			} else {
				op.status = .Failed
			}
		}
	}
	if merr == .None {
		append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = root})
	} else if n.alive && !(w.cfg.io_rate > 0 && (merr == .Io || merr == .No_Space)) {
		world_fail(w, "%s mounting git checkout failed: %v", n.name, merr)
	}
}

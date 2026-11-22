package sim

import "core:fmt"
import "core:slice"
import "core:strings"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/fstree"
import "../../src/odb"
import "../../src/prim"

WORK_PREFIX :: "/work/"
WATCH_OVERFLOW :: 256

Sim_Mount :: struct {
	oi:      int,
	root:    string,
	m:       ^fs.Mount,
	checked: u64,
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
		fs.registry_set_base_note(reg, _on_base, n)
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
	m := &w.model
	i := 0
	for i < len(m.mounts) {
		mm := m.mounts[i]
		if mm.node != n.idx || !n.alive {
			i += 1
			continue
		}
		if err := node_mount(w, n, mm.oi, mm.root); err != .None && n.alive {
			if w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
				n.restart_pending = true
				context = instance_context(&n.inst)
				node_after(n)
				return
			}
			cop := m.ops[m.objs[mm.oi].op]
			if err == .Not_Found && cop.node == n.idx && !op_happened(cop) {
				world_note(w, "%s drops mount %s: its tree's creation was not acknowledged and did not survive", n.name, mm.root)
				delete(mm.root, w.allocator)
				ordered_remove(&m.mounts, i)
				continue
			}
			world_fail(w, "%s could not remount %s after restart: %v", n.name, mm.root, err)
		}
		i += 1
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

Agent_Pending :: struct {
	inc:   int,
	root:  string,
	oi:    int,
	name:  string,
	scope: ^fs.Scope,
	actor: prim.Id,
	base:  []u8,
	hold:  bool,
}

agent_pending_free :: proc(w: ^World, pa: Agent_Pending) {
	delete(pa.root, w.allocator)
	delete(pa.name, w.allocator)
	delete(pa.base, w.allocator)
}

@(private = "file")
_on_base :: proc(m: ^fs.Mount, rel: string, note: fs.Base_Note, data: rawptr) {
	n := (^Node)(data)
	w := n.w
	switch note {
	case .Merged:
		stat_add(w, STAT_BASE_MERGED)
	case .Current:
		stat_add(w, STAT_BASE_CURRENT)
	case .Mismatch:
		stat_add(w, STAT_BASE_MISMATCH)
	case .Not_Text:
		stat_add(w, STAT_BASE_OTHER)
	}
	world_note(w, "%s agent base for %s: %v", n.name, rel, note)
}

@(private = "file")
_agent_start :: proc(w: ^World, n: ^Node) -> bool {
	m := &w.model
	live := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil {
			append(&live, i)
		}
	}
	if len(live) == 0 {
		return false
	}
	sm := n.mounts[live[rng_int(&w.rng, len(live))]]
	paths := TREE_PATHS
	name := paths[rng_int(&w.rng, len(paths))]
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	base, berr := prim.read_file(vfs, abs, context.temp_allocator)
	if n.disk.dead {
		node_crashed(n)
		return true
	}
	if berr != .None || len(base) == 0 {
		return false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	o := m.objs[sm.oi].o
	cur, rerr := eng.tree_read(&n.e, o, name, context.temp_allocator)
	if rerr != .None {
		return false
	}
	hold := rng_chance(&w.rng, 1, 2)
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	actor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	scope := fs.scope_open(n.reg, sm.m, sid, actor)
	if hold {
		fs.scope_write_begin(scope, name)
		for other in paths {
			if other == name {
				continue
			}
			if data, oerr := prim.read_file(vfs, strings.concatenate({sm.root, "/", other}, context.temp_allocator), context.temp_allocator); oerr == .None && len(data) > 0 {
				fs.scope_read_base(scope, other, data)
				break
			}
		}
		if !fs.scope_pinned(scope, name) {
			world_note(w, "%s agent hold on %s/%s pinned nothing (not in the shadow)", n.name, id_short(o.id), name)
		} else if hist, herr := eng.tree_history(&n.e, o); herr == .None {
			obs := make([dynamic]fs.Observation, context.temp_allocator)
			if oerr := fs.history_observations(hist, 0, &obs, context.temp_allocator); oerr != .None {
				world_fail(w, "observe: %s cannot scan %s: %v", n.name, id_short(o.id), oerr)
			}
			found := false
			for x in obs {
				found ||= x.actor == actor && x.kind == .Write_Begin && x.path == name
			}
			eng.tree_release(&n.e, o)
			if !found {
				world_fail(w, "observe: %s has no write_begin record by %s for %s/%s", n.name, id_short(actor), id_short(o.id), name)
			}
		}
	} else {
		fs.scope_read_base(scope, name, base)
	}
	tok := ""
	kerr := eng.Error.None
	if fs.scope_pinned(scope, name) {
		kop := new_op(m, .Tree_Write, n, sm.oi)
		kop.path = strings.clone(name, w.allocator)
		b := strings.builder_make(context.temp_allocator)
		strings.write_bytes(&b, cur)
		if len(cur) > 0 && cur[len(cur) - 1] != '\n' {
			strings.write_byte(&b, '\n')
		}
		tok = new_token(m, n, "k")
		append(&kop.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
		kerr = eng.tree_write(&n.e, o, name, transmute([]u8)strings.to_string(b))
		op_result(kop, n, kerr)
	}
	if n.agent_pending == nil {
		n.agent_pending = make([dynamic]Agent_Pending, w.allocator)
	}
	append(&n.agent_pending, Agent_Pending{inc = n.incarnation, root = strings.clone(sm.root, w.allocator), oi = sm.oi, name = strings.clone(name, w.allocator), scope = scope, actor = actor, base = slice.clone(base, w.allocator), hold = hold})
	world_note(w, "%s agent(actor %s) %s %s/%s base %q; typed %s -> %v", n.name, id_short(actor), "holds" if hold else "reads", id_short(o.id), name, string(base), tok, kerr)
	return true
}

_agent_scope_close :: proc(w: ^World, n: ^Node, s: ^fs.Scope) -> fs.Error {
	if w.cfg.persist_fault && rng_chance(&w.fault_rng, 1, 3) {
		n.persist_fail = 1
	}
	err := fs.scope_close(n.reg, s)
	n.persist_fail = 0
	return err
}

agent_finish :: proc(w: ^World, n: ^Node) {
	m := &w.model
	pa := pop(&n.agent_pending)
	defer agent_pending_free(w, pa)
	if pa.inc != n.incarnation || n.reg == nil {
		return
	}
	sm: ^Sim_Mount
	for &x in n.mounts {
		if x.root == pa.root && x.m != nil && x.m == pa.scope.mount {
			sm = &x
		}
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	if sm == nil {
		fs.scope_close(n.reg, pa.scope)
		return
	}
	abs := strings.concatenate({pa.root, "/", pa.name}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	from := pa.base
	if pa.hold {
		cur, rerr := prim.read_file(vfs, abs, context.temp_allocator)
		if n.disk.dead {
			node_crashed(n)
			return
		}
		if rerr == .None {
			from = cur
		}
	}
	op := new_op(m, .Disk_Agent, n, pa.oi)
	op.path = strings.clone(pa.name, w.allocator)
	op.actor = pa.actor
	b := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&b, from)
	if len(from) > 0 && from[len(from) - 1] != '\n' {
		strings.write_byte(&b, '\n')
	}
	for _ in 0 ..< 1 + rng_int(&w.rng, 2) {
		tok := new_token(m, n, "a")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	_writer_set(w, n, abs, Writer_Info{scope = pa.scope, agent = true})
	if oerr := fs.mount_observe_begin(sm.m, pa.name, pa.scope); oerr != .None && !n.disk.dead && w.cfg.io_rate == 0 {
		world_fail(w, "%s mount_observe_begin failed: %v", n.name, oerr)
	}
	err := _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), false)
	if pa.hold && !n.disk.dead {
		fs.scope_write_base(pa.scope, pa.name, from)
		if rng_chance(&w.rng, 1, 2) {
			fs.scope_write_end(pa.scope, pa.name)
		}
	}
	pinned := !n.disk.dead && fs.scope_pinned(pa.scope, pa.name)
	notes := _base_notes(w)
	serr := fs.Error.None
	if !n.disk.dead {
		serr = _agent_scope_close(w, n, pa.scope)
		_forget_scope(w, n, pa.scope)
	}
	if pinned && err == .None && serr == .None && !n.disk.dead && _base_notes(w) == notes {
		world_fail(w, "agent base: %s pinned write to %s/%s reported no outcome", n.name, id_short(m.objs[pa.oi].o.id), pa.name)
	}
	world_note(w, "%s agent(actor %s) writes %s/%s from %s base, wrote %v -> %v %v", n.name, id_short(pa.actor), id_short(m.objs[pa.oi].o.id), pa.name, "current" if pa.hold else "read", op.tokens[:], err, serr)
	if n.disk.dead {
		return
	}
	if err != .None {
		op.status = .Uncertain if err == .Io else .Failed
		if w.cfg.io_rate > 0 {
			op.status = .Uncertain
			n.restart_pending = true
		} else {
			world_fail(w, "%s disk edit failed: %v", n.name, err)
		}
		return
	}
	op_done(op, eng.pending_seq(&n.e), .None)
	if serr != .None && w.cfg.io_rate == 0 {
		world_fail(w, "%s scope_close failed: %v", n.name, serr)
	}
}

op_disk_edit :: proc(w: ^World, n: ^Node, agent: bool) {
	if agent && len(n.agent_pending) > 0 {
		agent_finish(w, n)
		return
	}
	if agent && rng_chance(&w.rng, 1, 3) && _agent_start(w, n) {
		return
	}
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
	if agent {
		if oerr := fs.mount_observe_begin(sm.m, name, scope); oerr != .None && !n.disk.dead {
			if w.cfg.io_rate == 0 {
				world_fail(w, "%s mount_observe_begin failed: %v", n.name, oerr)
			}
		}
	}
	atomic := !agent && rng_chance(&w.rng, 1, 2)
	if atomic {
		_writer_set(w, n, strings.concatenate({sm.root, "/.", name, ".swp"}, context.temp_allocator), Writer_Info{scope = scope, agent = agent})
	}
	err := _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), atomic)
	serr := fs.Error.None
	if agent && !n.disk.dead {
		serr = _agent_scope_close(w, n, scope)
		_forget_scope(w, n, scope)
	}
	world_note(w, "%s %s(actor %s) %s %s/%s replaced %v wrote %v -> %v %v", n.name, "agent" if agent else "person", id_short(op.actor), "overwrite" if overwrite else "append", id_short(m.objs[sm.oi].o.id), name, op.deletes[:], op.tokens[:], err, serr)
	if n.disk.dead {
		node_after(n)
		return
	}
	if err != .None {
		op.status = .Uncertain if err == .Io else .Failed
		if w.cfg.io_rate > 0 {
			op.status = .Uncertain
			n.restart_pending = true
		} else {
			world_fail(w, "%s disk edit failed: %v", n.name, err)
		}
	} else {
		if agent {
			op_done(op, eng.pending_seq(&n.e), .None)
		} else {
			op_done(op, 0, .None)
			op.status = .Acked
		}
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
	fs.history_present_spans(hist, raw)
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
				if strings.has_prefix(nm, ".") {
					continue
				}
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
	remote := ""
	pushed := make([dynamic]odb.Oid, context.temp_allocator)
	if rng_chance(&w.remote.rng, 3, 4) && env_u64("SIM_REMOTE", 1) != 0 {
		remote = fmt.tprintf("%s%s", SIM_REMOTE_URL, id_short(o.id))
	}
	gerr := git_checkout_create(vfs, root, files[:], clock_wall(&n.clock) / 1_000_000_000, node_clock(&n.clock), rng_random(&w.rng), remote, &pushed if len(remote) > 0 else nil)
	if gerr == .None && len(pushed) > 0 && !n.disk.dead {
		remote_push(w, n, root, pushed[:])
	}
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
			} else if merr == .Io || merr == .No_Space {
				op.status = .Uncertain
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

check_synced_disk :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open || len(n.disk.events) > 0 || n.watch_scheduled || n.disk.dead {
		return
	}
	for &sm in n.mounts {
		if sm.m == nil || sm.m.passes == sm.checked {
			continue
		}
		sm.checked = sm.m.passes
		out := make([dynamic]string, context.temp_allocator)
		n.disk.quiet = true
		err := fs.mount_synced_mismatches(sm.m, &out, context.temp_allocator)
		n.disk.quiet = false
		if err != .None {
			continue
		}
		for x in out {
			world_fail(w, "mount: %s %s synced version is not what is on disk: %s", n.name, sm.root, x)
		}
	}
}

_base_notes :: proc(w: ^World) -> u64 {
	return stat_get(&w.stats, STAT_BASE_MERGED) + stat_get(&w.stats, STAT_BASE_CURRENT) + stat_get(&w.stats, STAT_BASE_MISMATCH) + stat_get(&w.stats, STAT_BASE_OTHER)
}

STAT_BASE_MERGED: Stat
STAT_BASE_CURRENT: Stat
STAT_BASE_MISMATCH: Stat
STAT_BASE_OTHER: Stat

@(init)
_mounts_stats :: proc "contextless" () {
	register_final_check(110, check_mounts)
	register_stat_line(50, "agent_bases")
	STAT_BASE_MERGED = register_stat(50, 0, "merged")
	STAT_BASE_CURRENT = register_stat(50, 1, "current")
	STAT_BASE_MISMATCH = register_stat(50, 2, "mismatch")
	STAT_BASE_OTHER = register_stat(50, 3, "other")
	register_op(10, "agent_chain", proc(w: ^World) -> int {return 3}, op_agent_chain)
}

op_agent_chain :: proc(w: ^World, n: ^Node) {
	m := &w.model
	live := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil {
			append(&live, i)
		}
	}
	if len(live) == 0 || n.reg == nil {
		return
	}
	sm := n.mounts[live[rng_int(&w.rng, len(live))]]
	paths := TREE_PATHS
	name := paths[rng_int(&w.rng, len(paths))]
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	context = instance_context(&n.inst)
	defer node_after(n)
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	actor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	scope := fs.scope_open(n.reg, sm.m, sid, actor)
	if oerr := fs.mount_observe_begin(sm.m, name, scope); oerr != .None || n.disk.dead {
		fs.scope_close(n.reg, scope)
		return
	}
	cur, rerr := prim.read_file(vfs, abs, context.temp_allocator)
	if rerr != .None || len(cur) == 0 || n.disk.dead {
		fs.scope_close(n.reg, scope)
		return
	}
	fs.scope_write_begin(scope, name)
	if !fs.scope_pinned(scope, name) {
		fs.scope_close(n.reg, scope)
		return
	}
	chained := false
	for other in paths {
		if other == name {
			continue
		}
		data, derr := prim.read_file(vfs, strings.concatenate({sm.root, "/", other}, context.temp_allocator), context.temp_allocator)
		if derr == .None && len(data) > 0 {
			fs.scope_read_base(scope, other, data)
			chained = fs.scope_pinned(scope, other)
			break
		}
	}
	op := new_op(m, .Disk_Agent, n, sm.oi)
	op.path = strings.clone(name, w.allocator)
	op.actor = actor
	b := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&b, cur)
	if cur[len(cur) - 1] != '\n' {
		strings.write_byte(&b, '\n')
	}
	for _ in 0 ..< 1 + rng_int(&w.rng, 2) {
		tok := new_token(m, n, "a")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
	err := _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), false)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	fs.scope_write_base(scope, name, cur)
	fs.scope_write_end(scope, name)
	good := stat_get(&w.stats, STAT_BASE_MERGED) + stat_get(&w.stats, STAT_BASE_CURRENT)
	bad := stat_get(&w.stats, STAT_BASE_MISMATCH) + stat_get(&w.stats, STAT_BASE_OTHER)
	serr := fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	world_note(w, "%s agent chain(actor %s) %s/%s chained=%v wrote %v -> %v %v", n.name, id_short(actor), id_short(m.objs[sm.oi].o.id), name, chained, op.tokens[:], err, serr)
	if n.disk.dead {
		return
	}
	if err != .None || serr != .None {
		op.status = .Uncertain
		n.restart_pending = true
		return
	}
	op_done(op, eng.pending_seq(&n.e), .None)
	gained := stat_get(&w.stats, STAT_BASE_MERGED) + stat_get(&w.stats, STAT_BASE_CURRENT) - good
	lost := stat_get(&w.stats, STAT_BASE_MISMATCH) + stat_get(&w.stats, STAT_BASE_OTHER) - bad
	if gained != 1 || lost != 0 {
		world_fail(w, "agent chain: %s write to %s/%s based on its own pin fell back (chained=%v, ok %d, fallback %d)", n.name, id_short(m.objs[sm.oi].o.id), name, chained, gained, lost)
	}
}

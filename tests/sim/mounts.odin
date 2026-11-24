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
	pending: bool,
	op:      int,
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
	return fs.Write_Observer{data = n, start = _o_start, changed = _o_changed, opened = _o_opened}
}

@(private = "file")
_o_opened :: proc(data: rawptr, m: ^fs.Mount) {
	n := (^Node)(data)
	out := make([dynamic]string, context.temp_allocator)
	if fs.mount_shadow_mismatches(m, &out, context.temp_allocator) != .None {
		return
	}
	for x in out {
		world_fail(n.w, "mount open: %s %s synced version and shadow disagree: %s", n.name, m.root, x)
	}
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
	n := (^Node)(data)
	run_wait_points(n.w, n)
	watch_deliver(n, reg)
	return .None
}

@(private = "file")
_w_wait :: proc(data: rawptr, reg: ^fs.Registry, ms: i32) -> bool {
	n := (^Node)(data)
	run_wait_points(n.w, n)
	return watch_deliver(n, reg) > 0
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

tree_base :: proc(e: ^eng.Engine, o: eng.Object) -> fs.Version {
	v, _ := eng.tree_version(e, o, "", context.temp_allocator)
	return v
}

node_mount :: proc(w: ^World, n: ^Node, oi: int, root: string, pending: ^bool = nil, op := -1) -> eng.Error {
	context = instance_context(&n.inst)
	defer node_after(n)
	if n.reg == nil {
		reg, rerr := eng.registry(&n.e)
		if rerr != .None {
			return rerr
		}
		n.reg = reg
		fs.registry_set_base_note(reg, _on_base, n)
		fs.registry_set_spawner(reg, sim_git_spawner(n))
	}
	if err := prim.mkdir_all(disk_vfs(&n.disk), root, 0o755); err != .None {
		return .Io
	}
	grains := [?]i64{0, 1_000_000_000, 2_000_000_000}
	disk_set_grain(&n.disk, root, grains[mix_bytes(w.cfg.seed, transmute([]u8)root) % len(grains)])
	mopts := fs.DEFAULT_MOUNT
	mopts.index_trust = w.cfg.index_trust || w.cfg.seed % 3 == 1
	m, err := eng.tree_mount(&n.e, w.model.objs[oi].o, root, mopts, eng.Mount_Done{data = n, call = _mount_durable})
	waiting := err == .Pending && m != nil
	if err != .None && !waiting {
		return err
	}
	append(&n.mounts, Sim_Mount{oi = oi, root = strings.clone(root, w.allocator), m = m, pending = waiting, op = op})
	if pending != nil {
		pending^ = waiting
	}
	return .None
}

@(private = "file")
_mount_durable :: proc(data: rawptr, e: ^eng.Engine, fm: ^fs.Mount, err: eng.Error) {
	n := (^Node)(data)
	w := n.w
	m := &w.model
	for &sm in n.mounts {
		if sm.m != fm || !sm.pending {
			continue
		}
		sm.pending = false
		world_note(w, "%s mount %s is durable -> %v", n.name, sm.root, err)
		for op in m.ops {
			if op.node != n.idx || op.inc != n.incarnation || op.status != .Issued {
				continue
			}
			if (op.kind == .Git_Mount && op.obj == sm.oi) || op.idx == sm.op {
				if err == .None {
					op_done(op, 0, .None)
					op.status = .Acked
				} else {
					op.status = .Uncertain
				}
			}
		}
		if err == .None {
			for mm in m.mounts {
				if mm.node == n.idx && mm.root == sm.root {
					return
				}
			}
			append(&m.mounts, M_Mount{node = n.idx, oi = sm.oi, root = strings.clone(sm.root, w.allocator)})
		}
		return
	}
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
		removed, stop := _remount_one(w, n, i, 0)
		if stop {
			return
		}
		if !removed {
			i += 1
		}
	}
}

@(private = "file")
EV_REMOUNT: Ev_Kind

@(private = "file")
REMOUNT_TRIES :: 60

@(init)
_remount_init :: proc "contextless" () {
	EV_REMOUNT = register_event(_remount_retry)
}

@(private = "file")
_remount_retry :: proc(w: ^World, ev: ^Sim_Event) {
	n := w.nodes[ev.node]
	if !n.alive || u64(n.incarnation) != ev.gen {
		return
	}
	oi := int(ev.arg & 0xffff_ffff)
	for mm, i in w.model.mounts {
		if mm.node == n.idx && mm.oi == oi {
			_remount_one(w, n, i, ev.arg >> 32)
			return
		}
	}
}

@(private = "file")
_remount_one :: proc(w: ^World, n: ^Node, i: int, tries: u64) -> (removed: bool, stop: bool) {
	m := &w.model
	mm := m.mounts[i]
	err := node_mount(w, n, mm.oi, mm.root)
	if err == .None || !n.alive {
		return false, false
	}
	if w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
		n.restart_pending = true
		context = instance_context(&n.inst)
		node_after(n)
		return false, true
	}
	cop := m.ops[m.objs[mm.oi].op]
	if err == .Not_Found && cop.node == n.idx && !op_happened(cop) {
		world_note(w, "%s drops mount %s: its tree's creation was not acknowledged and did not survive", n.name, mm.root)
		delete(mm.root, w.allocator)
		ordered_remove(&m.mounts, i)
		return true, false
	}
	if err == .Missing && tries < REMOUNT_TRIES {
		world_note(w, "%s remount of %s waits for its history (%v); retrying", n.name, mm.root, err)
		schedule(w, Sim_Event{at = w.now + 500_000_000, kind = EV_REMOUNT, node = n.idx, gen = u64(n.incarnation), arg = u64(mm.oi) | (tries + 1) << 32})
		return false, false
	}
	world_fail(w, "%s could not remount %s after restart: %v", n.name, mm.root, err)
	return false, false
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
	mount_obj(w, n, cands[rng_int(&w.rng, len(cands))])
}

mount_obj :: proc(w: ^World, n: ^Node, oi: int) -> bool {
	m := &w.model
	{
		context = instance_context(&n.inst)
		_, found, err := eng.catalog_get(&n.e, m.objs[oi].o, context.temp_allocator)
		node_after(n)
		if err != .None || !found {
			return false
		}
	}
	root := fmt.aprintf("%s%s-%s", WORK_PREFIX, id_short(m.objs[oi].o.id), n.name, allocator = w.allocator)
	op := new_op(m, .Mount_Tree, n, oi)
	op.path = root
	waiting := false
	err := node_mount(w, n, oi, root, &waiting, op.idx)
	world_note(w, "%s mounts %s at %s -> %v (durable %v)", n.name, id_short(m.objs[oi].o.id), root, err, !waiting)
	if err == .None && waiting {
		return true
	}
	if err == .None {
		append(&m.mounts, M_Mount{node = n.idx, oi = oi, root = root})
		op_done(op, 0, .None)
		op.status = .Acked
		return true
	} else if err == .Missing || err == .Pending {
		op.status = .Failed
	} else if n.alive {
		if w.cfg.io_rate > 0 && (err == .Io || err == .No_Space) {
			op.status = .Failed
			n.restart_pending = true
			return false
		}
		world_fail(w, "%s tree_mount failed: %v", n.name, err)
		op.status = .Failed
	}
	return false
}

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

_truncated_by_failure :: proc(w: ^World, op: ^M_Op, old: []u8) {
	for t in parse_tokens(old) {
		append(&op.deletes, strings.clone(t.text, w.allocator))
	}
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
	deferred_close_outcome(w, n, m.root, rel, note)
}

@(private = "file")
_agent_start :: proc(w: ^World, n: ^Node) -> bool {
	m := &w.model
	live := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil && !_switching(sm.m) {
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
	cbase: fs.Version
	cur, rerr := eng.tree_read(&n.e, o, name, context.temp_allocator, {}, "", nil, &cbase)
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
		kerr = eng.tree_write(&n.e, o, name, transmute([]u8)strings.to_string(b), cbase)
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
	oerr := fs.mount_observe_begin(sm.m, pa.name, pa.scope)
	if oerr != .None && !n.disk.dead && w.cfg.io_rate == 0 {
		world_fail(w, "%s mount_observe_begin failed: %v", n.name, oerr)
	}
	err := prim.Error.Io
	if oerr == .None {
		n.observed += 1
		_agent_path(w, n, abs, pa.actor)
		err = _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), false)
	}
	if pa.hold && !n.disk.dead {
		fs.scope_write_base(pa.scope, pa.name, from)
		if rng_chance(&w.rng, 1, 2) {
			fs.scope_write_end(pa.scope, pa.name)
		}
	}
	pinned := !n.disk.dead && fs.scope_pinned(pa.scope, pa.name)
	notes := _base_notes(w)
	injected := pinned && !pa.hold && err == .None && rng_chance(&w.rng, 1, 3)
	if injected {
		n.disk.fail_sync = 1
	}
	serr := fs.Error.None
	if !n.disk.dead {
		serr = _agent_scope_close(w, n, pa.scope)
		_forget_scope(w, n, pa.scope)
	}
	if injected {
		n.disk.fail_sync = 0
		if serr != .None {
			stat_add(w, STAT_BASE_CLOSE_FAILED)
		}
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
	if serr != .None && w.cfg.io_rate == 0 && !injected {
		world_fail(w, "%s scope_close failed: %v", n.name, serr)
	}
}

_check_ingested :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, name: string, wrote: []u8) {
	if sm.m == nil || n.disk.dead || name in sm.m.dirty || fs.mount_absent_has(sm.m, name) {
		return
	}
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	n.disk.quiet = true
	cur, rerr := prim.read_file(disk_vfs(&n.disk), abs, context.temp_allocator)
	n.disk.quiet = false
	if rerr != .None || string(cur) != string(wrote) {
		return
	}
	got, found, err := fs.mount_synced_text(sm.m, name, context.temp_allocator)
	if err != .None {
		return
	}
	if !found || string(got) != string(wrote) {
		world_fail(w, "ingest: %s wrote %q to %s/%s, which is still on disk after its scope closed, but the synced version holds %q (found %v)", n.name, string(wrote), sm.root, name, string(got), found)
	}
}

_rewrite_same_size :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, name: string, agent: bool, prior: []string) {
	m := &w.model
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	old, rerr := prim.read_file(vfs, abs, context.temp_allocator)
	if rerr != .None || n.disk.dead {
		return
	}
	toks := parse_tokens(old)
	if len(toks) == 0 {
		return
	}
	last := toks[len(toks) - 1]
	tok := new_token(m, n, "a" if agent else "p")
	if len(tok) != len(last.text) {
		return
	}
	data := make([]u8, len(old), context.temp_allocator)
	copy(data, old)
	copy(data[last.pos:], tok)
	op := new_op(m, .Disk_Agent if agent else .Disk_Person, n, sm.oi)
	op.path = strings.clone(name, w.allocator)
	append(&op.deletes, strings.clone(last.text, w.allocator))
	append(&op.tokens, tok)
	unseen := false
	if !agent {
		for t in prior {
			unseen ||= t == last.text
		}
	}
	line_start := last.pos
	for line_start > 0 && old[line_start - 1] != '\n' {
		line_start -= 1
	}
	for t in toks[:len(toks) - 1] {
		if t.pos >= line_start && !unseen {
			append(&op.tokens, strings.clone(t.text, w.allocator))
		}
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
		if oerr := fs.mount_observe_begin(sm.m, name, scope); oerr != .None && !n.disk.dead && w.cfg.io_rate == 0 {
			world_fail(w, "%s mount_observe_begin failed: %v", n.name, oerr)
		}
	}
	err := _disk_write(vfs, abs, data, false)
	serr := fs.Error.None
	if agent && !n.disk.dead {
		serr = _agent_scope_close(w, n, scope)
		_forget_scope(w, n, scope)
	}
	world_note(w, "%s %s(actor %s) same-size rewrite %s/%s replaced %s with %s -> %v %v", n.name, "agent" if agent else "person", id_short(op.actor), id_short(m.objs[sm.oi].o.id), name, last.text, tok, err, serr)
	if n.disk.dead {
		return
	}
	if err != .None {
		op.status = .Uncertain
		if w.cfg.io_rate > 0 {
			n.restart_pending = true
		} else {
			world_fail(w, "%s disk edit failed: %v", n.name, err)
		}
		return
	}
	if agent {
		op_done(op, eng.pending_seq(&n.e), .None)
		if serr == .None {
			_check_ingested(w, n, sm, name, data)
		}
	} else {
		op_done(op, 0, .None)
		op.status = .Acked
	}
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
	live := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil && !(agent && _switching(sm.m)) {
			append(&live, i)
		}
	}
	if len(live) == 0 {
		return
	}
	sm := &n.mounts[live[rng_int(&w.rng, len(live))]]
	paths := TREE_PATHS
	name := paths[rng_int(&w.rng, len(paths))]
	if agent && !w.attrib_chained && env_u64("SIM_ATTRIB_CHAIN", 0) != 0 && rng_chance(&w.rng, 1, 4) {
		world_note(w, "%s attribution chain on %s/%s: agent, agent, person (SIM_ATTRIB_CHAIN)", n.name, sm.root, name)
		for writer in ([]bool{true, true, false}) {
			if !n.alive || n.disk.dead || sm.m == nil {
				return
			}
			_disk_edit_at(w, n, sm, name, writer, true)
		}
		return
	}
	_disk_edit_at(w, n, sm, name, agent, false)
}

@(private = "file")
_disk_edit_at :: proc(w: ^World, n: ^Node, sm: ^Sim_Mount, name: string, agent: bool, append_only: bool) {
	m := &w.model
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	vfs := disk_vfs(&n.disk)
	old, _ := prim.read_file(vfs, abs, context.temp_allocator)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	op := new_op(m, .Disk_Agent if agent else .Disk_Person, n, sm.oi)
	op.path = strings.clone(name, w.allocator)
	op.line = strings.clone(mount_model_line(sm.m, vfs, sm.root), w.allocator)
	overwrite := len(old) == 0 || (!append_only && rng_chance(&w.rng, 1, 3))
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
	oerr := fs.Error.None
	if agent {
		oerr = fs.mount_observe_begin(sm.m, name, scope)
		if oerr != .None && !n.disk.dead {
			if w.cfg.io_rate == 0 {
				world_fail(w, "%s mount_observe_begin failed: %v", n.name, oerr)
			}
		} else if oerr == .None {
			n.observed += 1
			_agent_path(w, n, abs, op.actor)
		}
	}
	atomic := !agent && rng_chance(&w.rng, 1, 2)
	if atomic {
		_writer_set(w, n, strings.concatenate({sm.root, "/.", name, ".swp"}, context.temp_allocator), Writer_Info{scope = scope, agent = agent})
	}
	err := prim.Error.Io
	if oerr == .None {
		err = _disk_write(vfs, abs, transmute([]u8)strings.to_string(b), atomic)
		if atomic && (err != .None || n.disk.dead) {
			model_temp_write(m, sm.oi, strings.concatenate({".", name, ".swp"}, context.temp_allocator), op.actor, transmute([]u8)strings.to_string(b))
		}
		if !atomic && !overwrite && (err != .None || n.disk.dead) {
			_truncated_by_failure(w, op, old)
		}
	}
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
	if !agent && err == .None && len(n.agent_paths[abs]) >= 2 && !w.attrib_chained && env_u64("SIM_ATTRIB_CHAIN", 0) != 0 {
		w.attrib_chained = true
		world_note(w, "%s power loss after a person's edit of %s, which %d agents wrote since the last crash (SIM_ATTRIB_CHAIN)", n.name, abs, len(n.agent_paths[abs]))
		stat_add(w, STAT_ATTRIB_CHAIN)
		node_crash_now(n, .Power, 78)
		n.disk.crash_on_trunc = "attrib.log"
		return
	}
	if !agent && err == .None && n.observed >= 2 && !w.attrib_crashed && env_u64("SIM_ATTRIB_CRASH", 0) != 0 {
		w.attrib_crashed = true
		world_note(w, "%s power loss after a person's edit with %d observations in the attribution log (SIM_ATTRIB_CRASH)", n.name, n.observed)
		stat_add(w, STAT_ATTRIB_CRASH)
		node_crash_now(n, .Power, 77)
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
			if serr == .None {
				_check_ingested(w, n, sm, name, transmute([]u8)strings.to_string(b))
			}
		} else {
			op_done(op, 0, .None)
			op.status = .Acked
		}
		if serr != .None && w.cfg.io_rate == 0 {
			world_fail(w, "%s scope_close failed: %v", n.name, serr)
		}
		if serr == .None && !n.disk.dead && rng_chance(&w.rng, 1, 3) {
			_rewrite_same_size(w, n, sm, name, agent, op.tokens[:])
		}
	}
	node_after(n)
}

_forget_scope :: proc(w: ^World, n: ^Node, scope: ^fs.Scope) {
	keys := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(n.writers) {
		if k not_in n.writers {
			continue
		}
		v := n.writers[k]
		if v.scope == scope && scope != nil {
			append(&keys, k)
		}
	}
	for k in keys {
		owned, _ := delete_key(&n.writers, k)
		delete(owned, w.allocator)
	}
}

path_hidden :: proc(p: string) -> bool {
	rest := p
	for part in strings.split_iterator(&rest, "/") {
		if strings.has_prefix(part, ".") {
			return true
		}
	}
	return false
}

tree_walk :: proc(n: ^Node, o: eng.Object, ready: eng.Ready = {}, line := "") -> (files: []string, err: eng.Error) {
	out := make([dynamic]string, context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, "")
	for i := 0; i < len(dirs); i += 1 {
		dir := dirs[i]
		names, lerr := eng.tree_list(&n.e, o, dir, context.temp_allocator, ready, line)
		if lerr != .None && err == .None {
			err = lerr
		}
		for nm in names {
			p := nm if len(dir) == 0 else strings.concatenate({dir, "/", nm}, context.temp_allocator)
			if _tree_is_dir(n, o, p, line) {
				append(&dirs, p)
			} else {
				append(&out, p)
			}
		}
	}
	return out[:], err
}

@(private = "file")
_tree_is_dir :: proc(n: ^Node, o: eng.Object, path: string, line: string) -> bool {
	h, ok := n.e.handles[o.id]
	if !ok || h.hist == nil {
		return false
	}
	hist := h.hist
	snap := fstree.current(&hist.tree)
	v, found, verr := fs.history_line(hist, eng.tree_line(&n.e, o, line), context.temp_allocator)
	if verr != .None {
		return false
	}
	if found {
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&hist.g, v, &lvs) == .None && !crdt.frontier_eq(lvs[:], hist.g.heads[:]) {
			at, serr := fs.version_snapshot(hist, lvs[:])
			if serr != .None {
				return false
			}
			defer fstree.snapshot_destroy(&at)
			return _snap_is_dir(&at, path)
		}
	}
	return _snap_is_dir(&snap, path)
}

@(private = "file")
_snap_is_dir :: proc(s: ^fstree.Snapshot, path: string) -> bool {
	id, found, lerr := fstree.lookup(s, path)
	if lerr != nil || !found {
		return false
	}
	info, iok, ierr := fstree.info(s, id, context.temp_allocator)
	return ierr == nil && iok && info.kind == .Dir
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
			names, lerr := tree_walk(n, ob.o)
			if lerr != .None {
				world_fail(w, "mount: %s cannot list mounted tree %s: %v", n.name, id_short(ob.o.id), lerr)
				node_after(n)
				continue
			}
			tl := make([dynamic]string, context.temp_allocator)
			for nm in names {
				if path_hidden(nm) {
					continue
				}
				data, _ := eng.tree_read(&n.e, ob.o, nm, context.temp_allocator)
				append(&tl, fmt.tprintf("%s=%q\n", nm, string(data)))
			}
			slice.sort(tl[:])
			want := strings.builder_make(context.temp_allocator)
			for l in tl {
				strings.write_string(&want, l)
			}
			have := strings.builder_make(context.temp_allocator)
			files := make([dynamic]Disk_File, context.temp_allocator)
			disk_walk(&n.disk, &files)
			prefix := strings.concatenate({sm.root, "/"}, context.temp_allocator)
			lines := make([dynamic]string, context.temp_allocator)
			for f in files {
				if !strings.has_prefix(f.path, prefix) {
					continue
				}
				rel := f.path[len(prefix):]
				if fs.path_internal(rel) || path_hidden(rel) {
					continue
				}
				append(&lines, fmt.tprintf("%s=%q\n", rel, string(f.data)))
			}
			slice.sort(lines[:])
			for l in lines {
				strings.write_string(&have, l)
			}
			if strings.to_string(want) != strings.to_string(have) {
				world_fail(w, "mount: %s disk at %s differs from tree %s:\n--- tree\n%s--- disk\n%s", n.name, sm.root, id_short(ob.o.id), strings.to_string(want), strings.to_string(have))
			}
			node_after(n)
		}
	}
}

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
	if len(remote) > 0 {
		for f in files {
			oid, _ := odb.hash(.Sha1, .Blob, f.data)
			if _, has := w.remote.objects[oid]; !has {
				w.remote.objects[oid] = slice.clone(f.data, w.allocator)
			}
		}
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
	waiting := false
	merr := node_mount(w, n, oi, root, &waiting)
	world_note(w, "%s git checkout %s mounted at %s -> %v (durable %v)", n.name, id_short(o.id), root, merr, !waiting)
	if merr == .None && waiting {
		return
	}
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
STAT_BASE_CLOSE_FAILED: Stat

@(init)
_mounts_stats :: proc "contextless" () {
	register_final_check(110, check_mounts)
	register_stat_line(50, "agent_bases")
	STAT_BASE_MERGED = register_stat(50, 0, "merged")
	STAT_BASE_CURRENT = register_stat(50, 1, "current")
	STAT_BASE_MISMATCH = register_stat(50, 2, "mismatch")
	STAT_BASE_OTHER = register_stat(50, 3, "other")
	STAT_GIT_CHECKOUTS = register_stat(65, 0, "checkouts")
	STAT_GIT_REFUSED = register_stat(65, 1, "refused")
	register_stat_line(65, "git")
	register_op(200, "git_switch", _git_switch_weight, op_git_switch)
	register_op(210, "line_switch", _git_switch_weight, op_line_switch)
	STAT_LINE_SWITCHES = register_stat(65, 2, "line_switches")
	STAT_BASE_CLOSE_FAILED = register_stat(50, 4, "close_failed")
	register_op(10, "agent_chain", proc(w: ^World) -> int {return 3}, op_agent_chain)
}

STAT_LINE_SWITCHES: Stat

@(private = "file")
_end_held_agents :: proc(w: ^World, n: ^Node, root: string) {
	for i := len(n.agent_pending) - 1; i >= 0; i -= 1 {
		pa := n.agent_pending[i]
		if pa.root != root || pa.inc != n.incarnation {
			continue
		}
		fs.scope_close(n.reg, pa.scope)
		_forget_scope(w, n, pa.scope)
		world_note(w, "%s agent(actor %s) on %s is held for the branch switch; its scope ends", n.name, id_short(pa.actor), root)
		ordered_remove(&n.agent_pending, i)
		agent_pending_free(w, pa)
	}
}

op_line_switch :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open {
		return
	}
	cands := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil && sm.m.has_git {
			append(&cands, i)
		}
	}
	if len(cands) == 0 {
		return
	}
	sm := n.mounts[cands[rng_int(&w.rng, len(cands))]]
	vfs := disk_vfs(&n.disk)
	existing := git_branches_other(vfs, sm.root)
	if n.disk.dead {
		context = instance_context(&n.inst)
		node_after(n)
		return
	}
	if len(existing) == 0 {
		return
	}
	branch := existing[rng_int(&w.rng, len(existing))]
	key := "" if branch == "main" else strings.concatenate({"git:refs/heads/", branch}, context.temp_allocator)
	known := key == ""
	for l in w.model.objs[sm.oi].lines {
		known ||= l == key
	}
	files: map[string][]u8
	if !known {
		fok: bool
		n.disk.probe += 1
		files, fok = git_branch_files(n, vfs, sm.root, branch)
		n.disk.probe -= 1
		if !fok {
			return
		}
	}
	context = instance_context(&n.inst)
	_end_held_agents(w, n, sm.root)
	from := mount_model_line(sm.m, vfs, sm.root)
	base := make(map[string][]u8, context.temp_allocator)
	if !known {
		for p in TREE_PATHS {
			if d, terr := eng.tree_read(&n.e, w.model.objs[sm.oi].o, p, context.temp_allocator, {}, line_eng(from)); terr == .None {
				base[p] = d
			}
		}
	}
	err := fs.mount_line_switch(sm.m, line_eng(key))
	world_note(w, "%s 0ndb switch %s to %s -> %v", n.name, sm.root, branch, err)
	if err == .None {
		if !known {
			_line_import_ops(w, n, sm.oi, key, files, base)
		}
		obj_add_line(&w.model, sm.oi, key)
		stat_add(w, STAT_LINE_SWITCHES)
	} else if !n.disk.dead && !(w.cfg.io_rate > 0 && (err == .Io || err == .No_Space)) && err != .Busy {
		world_fail(w, "%s 0ndb switch to %s failed: %v", n.name, branch, err)
	} else if !n.disk.dead && w.cfg.io_rate > 0 {
		n.restart_pending = true
	}
	node_after(n)
}

@(private = "file")
_line_import_ops :: proc(w: ^World, n: ^Node, oi: int, key: string, files: map[string][]u8, base: map[string][]u8) {
	m := &w.model
	for p in TREE_PATHS {
		data, has := files[p]
		old, had := base[p]
		if (!has && !had) || (has && had && string(data) == string(old)) {
			continue
		}
		op := new_op(m, .Disk_Person if has else .Tree_Remove, n, oi)
		op.line = strings.clone(key, w.allocator)
		op.path = strings.clone(p, w.allocator)
		op.overwrite = has && had
		kept := make(map[string]bool, context.temp_allocator)
		for t in parse_tokens(data) {
			kept[t.text] = true
			append(&op.tokens, strings.clone(t.text, w.allocator))
		}
		for t in parse_tokens(old) {
			if !kept[t.text] {
				kept[t.text] = true
				append(&op.deletes, strings.clone(t.text, w.allocator))
			}
		}
		op.status = .Uncertain
	}
}

STAT_GIT_CHECKOUTS: Stat
STAT_GIT_REFUSED: Stat

@(private = "file")
_git_switch_weight :: proc(w: ^World) -> int {
	return 4 if env_u64("SIM_GIT_SWITCH", 1) != 0 else 0
}

@(private = "file")
_carry_token :: proc(w: ^World, n: ^Node, oi: int, line: string, path: string, tok: string, inserter: prim.Id) {
	m := &w.model
	#reverse for o in m.ops {
		if o.obj != oi {
			continue
		}
		for t in o.tokens {
			if t != tok {
				continue
			}
			c := new_op(m, o.kind, n, oi)
			c.actor = o.actor if inserter == {} else inserter
			c.line = strings.clone(line, w.allocator)
			c.path = strings.clone(path, w.allocator)
			append(&c.tokens, strings.clone(tok, w.allocator))
			op_done(c, 0, .None)
			c.status = .Acked
			return
		}
	}
}

op_git_switch :: proc(w: ^World, n: ^Node) {
	r := &w.rng
	if !n.alive || !n.e_open {
		return
	}
	cands := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m != nil && sm.m.has_git {
			append(&cands, i)
		}
	}
	if len(cands) == 0 {
		return
	}
	sm := n.mounts[cands[rng_int(r, len(cands))]]
	if _, pending := fs.mount_switch_pending(sm.m); pending {
		return
	}
	m := &w.model
	vfs := disk_vfs(&n.disk)
	git := strings.concatenate({sm.root, "/.git"}, context.temp_allocator)
	for name in ([]string{"index.lock", "HEAD.lock"}) {
		p := strings.concatenate({git, "/", name}, context.temp_allocator)
		if prim.exists(vfs, p) {
			prim.remove(vfs, p)
			world_note(w, "%s removes a stale %s in %s", n.name, name, sm.root)
		}
	}
	if n.disk.dead {
		context = instance_context(&n.inst)
		node_after(n)
		return
	}
	force := rng_chance(r, 1, 4)
	dirty := git_dirty_paths(vfs, sm.root)
	paths := TREE_PATHS
	when_s := clock_wall(&n.clock) / 1_000_000_000
	from_line := git_head_line(vfs, sm.root)
	existing := git_branches_other(vfs, sm.root)
	branch: string
	if len(existing) > 0 && rng_chance(r, 1, 3) {
		branch = existing[rng_int(r, len(existing))]
	} else {
		files := make([dynamic]Git_File, context.temp_allocator)
		removed := make([dynamic]string, context.temp_allocator)
		for p in paths {
			if !(rng_chance(r, 1, 2) || (force && dirty[p])) {
				continue
			}
			if rng_chance(r, 1, 6) && !(force && dirty[p]) {
				append(&removed, p)
				continue
			}
			b := strings.builder_make(context.temp_allocator)
			for _ in 0 ..< 1 + rng_int(r, 2) {
				strings.write_string(&b, new_token(m, n, "s"))
				strings.write_byte(&b, '\n')
			}
			append(&files, Git_File{name = p, data = transmute([]u8)strings.to_string(b)})
		}
		if len(files) == 0 && len(removed) == 0 {
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, new_token(m, n, "s"))
			strings.write_byte(&b, '\n')
			append(&files, Git_File{name = paths[rng_int(r, len(paths))], data = transmute([]u8)strings.to_string(b)})
		}
		branch = fmt.tprintf("sw%d", m.tok)
		pushed := make([dynamic]odb.Oid, context.temp_allocator)
		berr := git_branch_commit(vfs, sm.root, branch, files[:], removed[:], when_s, node_clock(&n.clock), rng_random(r), &pushed)
		if berr == .None && !n.disk.dead && prim.exists(vfs, strings.concatenate({git, "/refs/remotes/origin/main"}, context.temp_allocator)) {
			remote_push(w, n, sm.root, pushed[:])
		}
		if n.disk.dead || berr != .None {
			world_note(w, "%s git branch %s in %s -> %v", n.name, branch, sm.root, berr)
			context = instance_context(&n.inst)
			if !n.disk.dead && w.cfg.io_rate == 0 {
				world_fail(w, "%s could not commit git branch %s: %v", n.name, branch, berr)
			}
			node_after(n)
			return
		}
	}
	key := "" if branch == "main" else strings.concatenate({"git:refs/heads/", branch}, context.temp_allocator)
	base_line := key
	known := key == ""
	for l in m.objs[sm.oi].lines {
		known ||= l == key
	}
	if !known {
		base_line = from_line
	}
	old_disk := make(map[string][]u8, context.temp_allocator)
	base := make(map[string][]u8, context.temp_allocator)
	untracked := make(map[string]bool, context.temp_allocator)
	on_line := make(map[string]bool, context.temp_allocator)
	inserter: prim.Id
	{
		context = instance_context(&n.inst)
		if known {
			inserter = n.identity.id
		}
		_end_held_agents(w, n, sm.root)
		fs.mount_sync(sm.m)
		for p in paths {
			if d, derr := prim.read_file(vfs, strings.concatenate({sm.root, "/", p}, context.temp_allocator), context.temp_allocator); derr == .None {
				old_disk[p] = d
			}
			if d, terr := eng.tree_read(&n.e, m.objs[sm.oi].o, p, context.temp_allocator, {}, line_eng(base_line)); terr == .None {
				base[p] = d
				for t in parse_tokens(d) {
					on_line[t.text] = true
				}
			}
		}
		if names, lerr := eng.tree_list(&n.e, m.objs[sm.oi].o, "", context.temp_allocator, {}, line_eng(base_line)); lerr == .None {
			nl: for nm in names {
				for tp in paths {
					if nm == tp {
						continue nl
					}
				}
				if d, terr := eng.tree_read(&n.e, m.objs[sm.oi].o, nm, context.temp_allocator, {}, line_eng(base_line)); terr == .None {
					for t in parse_tokens(d) {
						untracked[t.text] = true
						on_line[t.text] = true
					}
				}
			}
		}
		node_after(n)
	}
	if n.disk.dead || !n.alive {
		return
	}
	changes := make([dynamic]Git_Change, context.temp_allocator)
	res, cerr := git_checkout(vfs, sm.root, branch, force, when_s, node_clock(&n.clock), rng_random(r), &changes)
	if res == .Done {
		stat_add(w, STAT_GIT_CHECKOUTS)
	} else if res == .Refused {
		stat_add(w, STAT_GIT_REFUSED)
	}
	names := make([dynamic]string, context.temp_allocator)
	for ch in changes {
		append(&names, strings.concatenate({"-" if ch.gone else "", ch.name}, context.temp_allocator))
	}
	world_note(w, "%s git checkout%s %s in %s -> %v %v changed %v", n.name, " -f" if force else "", branch, sm.root, res, cerr, names[:])
	if res != .Done {
		context = instance_context(&n.inst)
		node_after(n)
		return
	}
	obj_add_line(m, sm.oi, key)
	if cerr == .None && !n.disk.dead {
		git_gone := make(map[string]bool, context.temp_allocator)
		for ch in changes {
			if ch.gone {
				git_gone[ch.name] = true
			}
		}
		{
			files := make([dynamic]Disk_File, context.temp_allocator)
			disk_walk(&n.disk, &files)
			prefix := strings.concatenate({sm.root, "/"}, context.temp_allocator)
			tracked_names := TREE_PATHS
			fl: for f in files {
				if !strings.has_prefix(f.path, prefix) {
					continue
				}
				rel := f.path[len(prefix):]
				if strings.has_prefix(rel, ".git/") || fs.path_internal(rel) {
					continue
				}
				for tp in tracked_names {
					if rel == tp {
						continue fl
					}
				}
				for t in parse_tokens(f.data) {
					untracked[t.text] = true
					_carry_token(w, n, sm.oi, key, rel, t.text, {} if on_line[t.text] else inserter)
				}
			}
		}
		for ch in changes {
			got, gerr := prim.read_file(vfs, strings.concatenate({sm.root, "/", ch.name}, context.temp_allocator), context.temp_allocator)
			if ch.gone != (gerr == .Not_Found) || (!ch.gone && string(got) != string(ch.new)) {
				world_fail(w, "%s git checkout %s left %s as %q (%v), not %q", n.name, branch, ch.name, string(got), gerr, string(ch.new))
			}
		}
		for p in paths {
			after, aerr := prim.read_file(vfs, strings.concatenate({sm.root, "/", p}, context.temp_allocator), context.temp_allocator)
			had_base := p in base
			gone := aerr == .Not_Found
			if (gone && !had_base) || (!gone && had_base && string(after) == string(base[p])) || (gone && !git_gone[p]) {
				continue
			}
			op := new_op(m, .Tree_Remove if gone else .Disk_Person, n, sm.oi)
			op.line = strings.clone(key, w.allocator)
			op.path = strings.clone(p, w.allocator)
			op.overwrite = !gone && had_base
			kept := make(map[string]bool, context.temp_allocator)
			if !gone {
				carried := make(map[string]bool, context.temp_allocator)
				for t in parse_tokens(old_disk[p]) {
					carried[t.text] = true
				}
				for t in parse_tokens(after) {
					kept[t.text] = true
					if untracked[t.text] {
						continue
					}
					if carried[t.text] {
						_carry_token(w, n, sm.oi, key, p, t.text, {} if on_line[t.text] else inserter)
						continue
					}
					append(&op.tokens, strings.clone(t.text, w.allocator))
				}
			}
			for src in ([2][]u8{base[p], old_disk[p]}) {
				for t in parse_tokens(src) {
					if !kept[t.text] && !untracked[t.text] {
						kept[t.text] = true
						append(&op.deletes, strings.clone(t.text, w.allocator))
					}
				}
			}
			_writer_set(w, n, strings.concatenate({sm.root, "/", p}, context.temp_allocator), Writer_Info{})
			op_done(op, 0, .None)
			op.status = .Acked
		}
	} else {
		lines := make([dynamic]string, context.temp_allocator)
		if n.disk.dead {
			append(&lines, key)
			if from_line != key {
				append(&lines, from_line)
			}
		} else {
			append(&lines, git_head_line(vfs, sm.root))
		}
		for ln in lines {
			for ch in changes {
				op := new_op(m, .Tree_Remove if ch.gone else .Disk_Person, n, sm.oi)
				op.line = strings.clone(ln, w.allocator)
				op.path = strings.clone(ch.name, w.allocator)
				op.overwrite = !ch.gone && len(ch.old) > 0
				for t in parse_tokens(ch.old) {
					append(&op.deletes, strings.clone(t.text, w.allocator))
				}
				for t in parse_tokens(ch.new) {
					append(&op.tokens, strings.clone(t.text, w.allocator))
				}
				_writer_set(w, n, strings.concatenate({sm.root, "/", ch.name}, context.temp_allocator), Writer_Info{})
				if !n.disk.dead {
					op.status = .Uncertain
				}
			}
		}
	}
	context = instance_context(&n.inst)
	if cerr != .None && !n.disk.dead {
		if w.cfg.io_rate > 0 {
			n.restart_pending = true
		} else {
			world_fail(w, "%s git checkout %s failed: %v", n.name, branch, cerr)
		}
	}
	node_after(n)
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
	if err != .None || n.disk.dead {
		_truncated_by_failure(w, op, cur)
	}
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
	if gained == 0 && lost == 0 {
		deferred_close_note(w, n, sm.root, name)
		return
	}
	if gained != 1 || lost != 0 {
		world_fail(w, "agent chain: %s write to %s/%s based on its own pin fell back (chained=%v, ok %d, fallback %d)", n.name, id_short(m.objs[sm.oi].o.id), name, chained, gained, lost)
	}
}

STAT_ATTRIB_CRASH: Stat
STAT_ATTRIB_CHAIN: Stat

@(private = "file")
_agent_path :: proc(w: ^World, n: ^Node, abs: string, actor: prim.Id) {
	l, ok := &n.agent_paths[abs]
	if !ok {
		k := strings.clone(abs, w.allocator)
		n.agent_paths[k] = make([dynamic]prim.Id, w.allocator)
		l = &n.agent_paths[k]
	}
	for x in l {
		if x == actor {
			return
		}
	}
	append(l, actor)
}

agent_paths_clear :: proc(w: ^World, n: ^Node) {
	for k, l in n.agent_paths {
		delete(l)
		delete(k, w.allocator)
	}
	clear(&n.agent_paths)
}

@(init)
_attrib_crash_stat :: proc "contextless" () {
	register_stat_line(46)
	STAT_ATTRIB_CRASH = register_stat(46, 0, "attrib_crash")
	STAT_ATTRIB_CHAIN = register_stat(46, 1, "attrib_chain")
}

mount_model_line :: proc(m: ^fs.Mount, vfs: prim.Vfs, root: string) -> string {
	if _, pending := fs.mount_switch_pending(m); pending {
		return line_norm(m.line)
	}
	return git_head_line(vfs, root)
}

@(private = "file")
_switching :: proc(m: ^fs.Mount) -> bool {
	_, pending := fs.mount_switch_pending(m)
	return pending
}

_line_heads :: proc(m: ^fs.Mount, allocator := context.temp_allocator) -> []crdt.Op_Id {
	if v, found, err := fs.history_line(m.history, m.line, allocator); err == .None && found {
		return v
	}
	return slice.clone(fs.mount_synced(m), allocator)
}

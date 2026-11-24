package sim

import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

STAT_HELD_STARTED: Stat
STAT_HELD_THIRD: Stat
STAT_HELD_REVERT: Stat
STAT_HELD_POWER: Stat

@(init)
_agent_held_init :: proc "contextless" () {
	register_op(12, "agent_held", proc(w: ^World) -> int {return 2}, op_agent_held)
	register_stat_line(52, "agent_held")
	STAT_HELD_STARTED = register_stat(52, 0, "started")
	STAT_HELD_THIRD = register_stat(52, 1, "third")
	STAT_HELD_REVERT = register_stat(52, 2, "revert")
	STAT_HELD_POWER = register_stat(52, 3, "power")
}

@(private = "file")
_append_tokens :: proc(w: ^World, n: ^Node, op: ^M_Op, from: []u8, count: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&b, from)
	if len(from) > 0 && from[len(from) - 1] != '\n' {
		strings.write_byte(&b, '\n')
	}
	for _ in 0 ..< count {
		tok := new_token(&w.model, n, "a")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
_scoped_write :: proc(w: ^World, n: ^Node, sm: Sim_Mount, name: string, abs: string, scope: ^fs.Scope, op: ^M_Op, data: []u8) -> (err: prim.Error, serr: fs.Error) {
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
	fs.mount_observe_begin(sm.m, name, scope)
	err = disk_write_by(w, n, op, abs, data)
	if n.disk.dead {
		return
	}
	serr = fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	return
}

@(private = "file")
_still :: proc(w: ^World, n: ^Node, abs: string, want: []u8, after: string) {
	got, err := prim.read_file(disk_vfs(&n.disk), abs, context.temp_allocator)
	if n.disk.dead || err != .None {
		return
	}
	if string(got) != string(want) {
		world_fail(w, "agent held: %s %s moved under another scope's hold after %s: disk %q, written %q", n.name, abs, after, string(got), string(want))
	}
}

op_agent_held :: proc(w: ^World, n: ^Node) {
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
	base, berr := prim.read_file(disk_vfs(&n.disk), abs, context.temp_allocator)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	if berr != .None || len(base) == 0 {
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	o := m.objs[sm.oi].o
	hold := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)))
	fs.scope_write_begin(hold, name)
	if !fs.scope_pinned(hold, name) {
		fs.scope_close(n.reg, hold)
		return
	}
	ractor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	reader := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), ractor)
	fs.scope_read_base(reader, name, base)
	if !fs.scope_pinned(reader, name) {
		fs.scope_close(n.reg, reader)
		fs.scope_close(n.reg, hold)
		return
	}
	cbase: fs.Version
	if cur, rerr := eng.tree_read(&n.e, o, name, context.temp_allocator, {}, "", nil, &cbase); rerr == .None {
		kop := new_op(m, .Tree_Write, n, sm.oi)
		kop.path = strings.clone(name, w.allocator)
		tok := new_token(m, n, "k")
		append(&kop.tokens, tok)
		b := strings.builder_make(context.temp_allocator)
		strings.write_bytes(&b, cur)
		if len(cur) > 0 && cur[len(cur) - 1] != '\n' {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
		op_result(kop, n, eng.tree_write(&n.e, o, name, transmute([]u8)strings.to_string(b), cbase))
	}
	pop := new_op(m, .Disk_Agent, n, sm.oi)
	pop.path = strings.clone(name, w.allocator)
	pop.actor = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	other := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), pop.actor)
	moved := _append_tokens(w, n, pop, base, 1)
	perr, pserr := _scoped_write(w, n, sm, name, abs, other, pop, moved)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	if perr != .None || pserr != .None {
		pop.status = .Uncertain
		n.restart_pending = true
		return
	}
	op_done(pop, eng.pending_seq(&n.e), .None)
	before := _line_heads(sm.m)
	rop := new_op(m, .Disk_Agent, n, sm.oi)
	rop.path = strings.clone(name, w.allocator)
	rop.actor = ractor
	wrote := _append_tokens(w, n, rop, base, 2)
	err, serr := _scoped_write(w, n, sm, name, abs, reader, rop, wrote)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	if err != .None || serr != .None {
		rop.status = .Uncertain
		n.restart_pending = true
		return
	}
	op_done(rop, eng.pending_seq(&n.e), .None)
	stat_add(w, STAT_HELD_STARTED)
	_still(w, n, abs, wrote, "a read-based write")
	shape := rng_int(&w.rng, 3)
	switch shape {
	case 0:
		top := new_op(m, .Disk_Agent, n, sm.oi)
		top.path = strings.clone(name, w.allocator)
		top.actor = prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
		third := fs.scope_open(n.reg, sm.m, prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng)), top.actor)
		next := _append_tokens(w, n, top, wrote, 1 + rng_int(&w.rng, 2))
		terr, tserr := _scoped_write(w, n, sm, name, abs, third, top, next)
		if n.disk.dead {
			node_crashed(n)
			return
		}
		if terr != .None || tserr != .None {
			top.status = .Uncertain
			n.restart_pending = true
			return
		}
		op_done(top, eng.pending_seq(&n.e), .None)
		stat_add(w, STAT_HELD_THIRD)
		_still(w, n, abs, next, "a third writer's write")
	case 1:
		after := _line_heads(sm.m)
		rerr := fs.mount_revert(sm.m, fs.Version(before), fs.Version(after), ractor)
		if n.disk.dead {
			node_crashed(n)
			return
		}
		if rerr != .None {
			if w.cfg.io_rate == 0 {
				world_fail(w, "agent held: %s rewind of %s/%s failed: %v", n.name, id_short(o.id), name, rerr)
			}
			n.restart_pending = true
			return
		}
		dop := new_op(m, .Disk_Person, n, sm.oi)
		dop.path = strings.clone(name, w.allocator)
		for t in rop.tokens {
			append(&dop.deletes, strings.clone(t, w.allocator))
		}
		op_done(dop, 0, .None)
		dop.status = .Acked
		stat_add(w, STAT_HELD_REVERT)
		_still(w, n, abs, wrote, "a rewind of the agent's turn")
	case 2:
		stat_add(w, STAT_HELD_POWER)
		world_note(w, "%s agent held %s/%s: power cut while the entry names its own version", n.name, id_short(o.id), name)
		node_crash_now(n, .Power, u64(rop.idx))
		return
	}
	fs.scope_close(n.reg, hold)
	world_note(w, "%s agent held %s/%s shape %d wrote %v", n.name, id_short(o.id), name, shape, rop.tokens[:])
}

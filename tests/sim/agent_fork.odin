package sim

import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

STAT_FORK_TRIED: Stat
STAT_FORK_HELD: Stat
STAT_FORK_NAMED: Stat

@(init)
_agent_fork_init :: proc "contextless" () {
	register_op(205, "agent_fork", _agent_fork_weight, op_agent_fork)
	register_stat_line(73, "agent_fork")
	STAT_FORK_TRIED = register_stat(73, 0, "tried")
	STAT_FORK_HELD = register_stat(73, 1, "held")
	STAT_FORK_NAMED = register_stat(73, 2, "named")
}

@(private = "file")
_agent_fork_weight :: proc(w: ^World) -> int {
	for n in w.nodes {
		for sm in n.mounts {
			if sm.m != nil && sm.m.has_git {
				return int(env_u64("SIM_FORK", 8))
			}
		}
	}
	return 0
}

@(private = "file")
_fork_write :: proc(w: ^World, n: ^Node, sm: Sim_Mount, name: string, scope: ^fs.Scope, actor: prim.Id, base: []u8, count: int) -> bool {
	abs := strings.concatenate({sm.root, "/", name}, context.temp_allocator)
	op := new_op(&w.model, .Disk_Agent, n, sm.oi)
	op.path = strings.clone(name, w.allocator)
	op.actor = actor
	b := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&b, base)
	if len(base) > 0 && base[len(base) - 1] != '\n' {
		strings.write_byte(&b, '\n')
	}
	for _ in 0 ..< count {
		tok := new_token(&w.model, n, "a")
		append(&op.tokens, tok)
		strings.write_string(&b, tok)
		strings.write_byte(&b, '\n')
	}
	_writer_set(w, n, abs, Writer_Info{scope = scope, agent = true})
	fs.mount_observe_begin(sm.m, name, scope)
	err := _disk_write(disk_vfs(&n.disk), abs, transmute([]u8)strings.to_string(b), false)
	if n.disk.dead {
		node_crashed(n)
		return false
	}
	serr := fs.scope_close(n.reg, scope)
	_forget_scope(w, n, scope)
	if n.disk.dead {
		node_crashed(n)
		return false
	}
	if err != .None || serr != .None {
		op.status = .Uncertain
		n.restart_pending = true
		return false
	}
	op_done(op, eng.pending_seq(&n.e), .None)
	return true
}

op_agent_fork :: proc(w: ^World, n: ^Node) {
	if !n.alive || !n.e_open || n.reg == nil {
		return
	}
	live := make([dynamic]int, context.temp_allocator)
	for sm, i in n.mounts {
		if sm.m == nil || !sm.m.has_git {
			continue
		}
		if _, pending := fs.mount_switch_pending(sm.m); !pending {
			append(&live, i)
		}
	}
	if len(live) == 0 {
		return
	}
	sm := n.mounts[live[rng_int(&w.rng, len(live))]]
	paths := TREE_PATHS
	name := paths[rng_int(&w.rng, len(paths))]
	base, berr := prim.read_file(disk_vfs(&n.disk), strings.concatenate({sm.root, "/", name}, context.temp_allocator), context.temp_allocator)
	if n.disk.dead {
		node_crashed(n)
		return
	}
	if berr != .None || len(base) == 0 {
		return
	}
	stat_add(w, STAT_FORK_TRIED)
	id :: proc(w: ^World, n: ^Node) -> prim.Id {
		return prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	}
	hold: ^fs.Scope
	before := 0
	{
		context = instance_context(&n.inst)
		defer node_after(n)
		hold = fs.scope_open(n.reg, sm.m, id(w, n), id(w, n))
		fs.scope_write_begin(hold, name)
		ractor := id(w, n)
		reader := fs.scope_open(n.reg, sm.m, id(w, n), ractor)
		fs.scope_read_base(reader, name, base)
		if !fs.scope_pinned(hold, name) || !fs.scope_pinned(reader, name) {
			fs.scope_close(n.reg, reader)
			fs.scope_close(n.reg, hold)
			return
		}
		pactor := id(w, n)
		if !_fork_write(w, n, sm, name, fs.scope_open(n.reg, sm.m, id(w, n), pactor), pactor, base, 1) {
			return
		}
		if !_fork_write(w, n, sm, name, reader, ractor, base, 1 + rng_int(&w.rng, 2)) {
			return
		}
		e, found, _ := fs.shadow_get(&sm.m.shadow, name)
		if found && e.ver != 0 {
			stat_add(w, STAT_FORK_HELD)
		}
		before = sm.m.fork_named
	}
	inc := n.incarnation
	if n.alive && !n.disk.dead {
		git_switch_run(w, n, sm, name)
	}
	if !n.alive || n.disk.dead || n.incarnation != inc {
		return
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	fs.scope_close(n.reg, hold)
	if n.disk.dead {
		return
	}
	stat_add(w, STAT_FORK_NAMED, u64(sm.m.fork_named - before))
	world_note(w, "%s agent fork %s: the checkout forked %d named versions", n.name, name, sm.m.fork_named - before)
}

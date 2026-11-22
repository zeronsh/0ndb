package sim

import "core:slice"
import "core:strings"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

STAT_REMOVED_STARTED: Stat
STAT_REMOVED_REPLACED: Stat

@(init)
_agent_removed_init :: proc "contextless" () {
	register_op(11, "agent_removed", proc(w: ^World) -> int {return 3}, op_agent_removed)
	register_stat_line(51, "agent_removed")
	STAT_REMOVED_STARTED = register_stat(51, 0, "started")
	STAT_REMOVED_REPLACED = register_stat(51, 1, "replaced")
}

op_agent_removed :: proc(w: ^World, n: ^Node) {
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
	base, berr := prim.read_file(vfs, abs, context.temp_allocator)
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
	cur, rerr := eng.tree_read(&n.e, o, name, context.temp_allocator)
	if rerr != .None {
		return
	}
	sid := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	actor := prim.id_new_with(node_clock(&n.clock), rng_random(&w.rng))
	scope := fs.scope_open(n.reg, sm.m, sid, actor)
	fs.scope_read_base(scope, name, base)
	if !fs.scope_pinned(scope, name) {
		fs.scope_close(n.reg, scope)
		return
	}
	rop := new_op(m, .Tree_Remove, n, sm.oi)
	rop.path = strings.clone(name, w.allocator)
	for t in parse_tokens(cur) {
		append(&rop.deletes, strings.clone(t.text, w.allocator))
	}
	if !(name in m.objs[sm.oi].removed) {
		m.objs[sm.oi].removed[strings.clone(name, w.allocator)] = true
	}
	err := eng.tree_remove(&n.e, o, name)
	op_result(rop, n, err)
	tok := ""
	werr := eng.Error.None
	if err == .None && rng_chance(&w.rng, 1, 2) {
		kop := new_op(m, .Tree_Write, n, sm.oi)
		kop.path = strings.clone(name, w.allocator)
		tok = new_token(m, n, "k")
		append(&kop.tokens, tok)
		werr = eng.tree_write(&n.e, o, name, transmute([]u8)strings.concatenate({tok, "\n"}, context.temp_allocator))
		op_result(kop, n, werr)
		stat_add(w, STAT_REMOVED_REPLACED)
	}
	stat_add(w, STAT_REMOVED_STARTED)
	if n.agent_pending == nil {
		n.agent_pending = make([dynamic]Agent_Pending, w.allocator)
	}
	append(&n.agent_pending, Agent_Pending{inc = n.incarnation, root = strings.clone(sm.root, w.allocator), oi = sm.oi, name = strings.clone(name, w.allocator), scope = scope, actor = actor, base = slice.clone(base, w.allocator)})
	world_note(w, "%s agent(actor %s) reads %s/%s base %q, then tree_remove -> %v; recreated %s -> %v", n.name, id_short(actor), id_short(o.id), name, string(base), err, tok, werr)
}

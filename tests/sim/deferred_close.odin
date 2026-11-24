package sim

import "core:slice"
import "core:strings"
import "../../src/crdt"
import eng "../../src/engine"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
Deferred_Close :: struct {
	node:  int,
	inc:   int,
	root:  string,
	path:  string,
	actor: prim.Id,
	op:     int,
	line:   string,
	before: []crdt.Op_Id,
}

@(private = "file")
_closes: [dynamic]Deferred_Close

@(private = "file")
_resumed: [dynamic]Deferred_Close

STAT_CLOSE_DEFERRED: Stat
STAT_CLOSE_RESUMED: Stat
STAT_CLOSE_CRASHED: Stat
STAT_CLOSE_UNDONE: Stat
STAT_CLOSE_OTHER_LINE: Stat

@(private = "file")
EV_DC_UNDO: Ev_Kind


@(init)
_deferred_close_init :: proc "contextless" () {
	register_world(67, _closes_init, _closes_destroy)
	register_final_check(123, check_deferred_closes)
	EV_DC_UNDO = register_event(_deferred_undo)
	register_stat_line(72, "deferred_close")
	STAT_CLOSE_DEFERRED = register_stat(72, 0, "deferred")
	STAT_CLOSE_RESUMED = register_stat(72, 1, "resumed")
	STAT_CLOSE_CRASHED = register_stat(72, 2, "crashed")
	STAT_CLOSE_UNDONE = register_stat(72, 3, "undone")
	STAT_CLOSE_OTHER_LINE = register_stat(72, 4, "token_gone")
}

@(private = "file")
_closes_init :: proc(w: ^World) {
	_closes = make([dynamic]Deferred_Close, w.allocator)
	_resumed = make([dynamic]Deferred_Close, w.allocator)
}

@(private = "file")
_closes_destroy :: proc(w: ^World) {
	for c in _closes {
		delete(c.root, w.allocator)
		delete(c.path, w.allocator)
	}
	delete(_closes)
	_closes = nil
	delete(_resumed)
	_resumed = nil
}

deferred_close_note :: proc(w: ^World, n: ^Node, sm: Sim_Mount, op: ^M_Op, before: []crdt.Op_Id) {
	stat_add(w, STAT_CLOSE_DEFERRED)
	world_note(w, "%s a scope close on %s/%s is deferred; its base outcome is owed", n.name, sm.root, op.path)
	append(&_closes, Deferred_Close{n.idx, int(n.incarnation), strings.clone(sm.root, w.allocator), strings.clone(op.path, w.allocator), op.actor, op.idx, strings.clone(fs.mount_line(sm.m), w.allocator), slice.clone(before, w.allocator)})
}

deferred_close_outcome :: proc(w: ^World, n: ^Node, root: string, path: string, note: fs.Base_Note, actor: prim.Id) {
	for c, i in _closes {
		if c.node != n.idx || c.inc != int(n.incarnation) || c.root != root || c.path != path || c.actor != actor {
			continue
		}
		if note != .Merged && note != .Current {
			world_fail(w, "deferred close: %s write to %s/%s lost its base when its pass resumed (%v)", n.name, root, path, note)
		}
		stat_add(w, STAT_CLOSE_RESUMED)
		append(&_resumed, c)
		schedule(w, Sim_Event{at = w.now + 1_000_000, kind = EV_DC_UNDO, node = n.idx, arg = u64(len(_resumed) - 1)})
		ordered_remove(&_closes, i)
		return
	}
}

check_deferred_closes :: proc(w: ^World) {
	for c in _closes {
		n := w.nodes[c.node]
		if int(n.incarnation) != c.inc {
			stat_add(w, STAT_CLOSE_CRASHED)
			continue
		}
		world_fail(w, "deferred close: %s write to %s/%s never got a base outcome", n.name, c.root, c.path)
	}
}

@(private = "file")
_deferred_undo :: proc(w: ^World, ev: ^Sim_Event) {
	if len(w.failures) > 0 || int(ev.arg) >= len(_resumed) {
		return
	}
	c := _resumed[ev.arg]
	n := w.nodes[ev.node]
	if !n.alive || !n.e_open || int(n.incarnation) != c.inc {
		return
	}
	m := &w.model
	op := m.ops[c.op]
	context = instance_context(&n.inst)
	defer node_after(n)
	tree := m.objs[op.obj].o
	line := line_eng(strings.clone(op.line, context.temp_allocator))
	paths := TREE_PATHS
	was := make(map[string]string, context.temp_allocator)
	for p in paths {
		t, terr := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, line)
		if terr != .None && terr != .Not_Found {
			return
		}
		was[p] = strings.clone(string(t), context.temp_allocator)
	}
	for tok in op.tokens {
		if !strings.contains(was[c.path], tok) {
			stat_add(w, STAT_CLOSE_OTHER_LINE)
			return
		}
	}
	if _, rerr := eng.tree_revert_set(&n.e, tree, fs.Version(c.before), []prim.Id{op.actor}, line); rerr != .None {
		world_fail(w, "deferred close: undo of %s's turn on %s failed: %v", id_short(op.actor), c.root, rerr)
		return
	}
	for p in paths {
		t, terr := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, line)
		if terr != .None && terr != .Not_Found {
			world_fail(w, "deferred close: cannot read %s on %s after the undo: %v", p, line, terr)
			return
		}
		if p == c.path {
			for tok in op.tokens {
				if strings.contains(string(t), tok) {
					world_fail(w, "deferred close: undo of %s's turn on %s left its token %s in %s (%q)", id_short(op.actor), c.root, tok, p, string(t))
				}
			}
		}
		it := was[p]
		for l in strings.split_lines_iterator(&it) {
			if p == c.path && slice.contains(op.tokens[:], l) {
				continue
			}
			if len(l) > 0 && !strings.contains(string(t), l) {
				world_fail(w, "deferred close: undo of %s's turn on %s removed %q from %s (%q)", id_short(op.actor), c.root, l, p, string(t))
			}
		}
	}
	dop := new_op(m, .Disk_Person, n, op.obj)
	dop.path = strings.clone(c.path, w.allocator)
	delete(dop.line, w.allocator)
	dop.line = strings.clone(op.line, w.allocator)
	for tok in op.tokens {
		append(&dop.deletes, strings.clone(tok, w.allocator))
	}
	op_done(dop, eng.pending_seq(&n.e), .None)
	dop.status = .Acked
	stat_add(w, STAT_CLOSE_UNDONE)
}

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
	eline:  string,
	was:    map[string]string,
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
STAT_CLOSE_UNDO_ELSEWHERE: Stat

@(private = "file")
EV_DC_UNDO: Ev_Kind

@(private = "file")
EV_DC_CHECK: Ev_Kind

@(init)
_deferred_close_init :: proc "contextless" () {
	register_world(67, _closes_init, _closes_destroy)
	register_final_check(123, check_deferred_closes)
	EV_DC_UNDO = register_event(_deferred_undo)
	EV_DC_CHECK = register_event(_deferred_undo_check)
	register_stat_line(72, "deferred_close")
	STAT_CLOSE_DEFERRED = register_stat(72, 0, "deferred")
	STAT_CLOSE_RESUMED = register_stat(72, 1, "resumed")
	STAT_CLOSE_CRASHED = register_stat(72, 2, "crashed")
	STAT_CLOSE_UNDONE = register_stat(72, 3, "undone")
	STAT_CLOSE_OTHER_LINE = register_stat(72, 4, "other_line")
	STAT_CLOSE_UNDO_ELSEWHERE = register_stat(72, 5, "undo_after_switch")
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
	append(&_closes, Deferred_Close{n.idx, int(n.incarnation), strings.clone(sm.root, w.allocator), strings.clone(op.path, w.allocator), op.actor, op.idx, strings.clone(fs.mount_line(sm.m), w.allocator), slice.clone(before, w.allocator), "", nil})
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
	sm: ^Sim_Mount
	for &x in n.mounts {
		if x.root == c.root && x.m != nil {
			sm = &x
		}
	}
	if sm == nil {
		return
	}
	if fs.mount_line(sm.m) != c.line {
		stat_add(w, STAT_CLOSE_OTHER_LINE)
		return
	}
	m := &w.model
	op := m.ops[c.op]
	context = instance_context(&n.inst)
	tree := m.objs[sm.oi].o
	line := line_eng(strings.clone(op.line, context.temp_allocator))
	paths := TREE_PATHS
	was := make(map[string]string, w.allocator)
	for p in paths {
		t, terr := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, line)
		if terr != .None && terr != .Not_Found {
			return
		}
		was[p] = strings.clone(string(t), w.allocator)
	}
	for tok in op.tokens {
		if !strings.contains(was[c.path], tok) {
			return
		}
	}
	after := slice.clone(_line_heads(sm.m), context.temp_allocator)
	if rerr := fs.mount_revert(sm.m, fs.Version(c.before), fs.Version(after), op.actor); rerr != .None {
		world_fail(w, "deferred close: undo of %s's turn on %s/%s failed: %v", id_short(op.actor), c.root, c.path, rerr)
		return
	}
	_resumed[ev.arg].was = was
	_resumed[ev.arg].eline = strings.clone(line, w.allocator)
	schedule(w, Sim_Event{at = w.now + 2_000_000_000, kind = EV_DC_CHECK, node = n.idx, arg = ev.arg})
	node_after(n)
}

@(private = "file")
_deferred_undo_check :: proc(w: ^World, ev: ^Sim_Event) {
	if len(w.failures) > 0 || int(ev.arg) >= len(_resumed) {
		return
	}
	c := _resumed[ev.arg]
	n := w.nodes[ev.node]
	if !n.alive || !n.e_open || int(n.incarnation) != c.inc || c.was == nil {
		return
	}
	m := &w.model
	op := m.ops[c.op]
	context = instance_context(&n.inst)
	tree := m.objs[op.obj].o
	moved := false
	for &x in n.mounts {
		if x.root == c.root && x.m != nil {
			moved = fs.mount_line(x.m) != c.line
			if len(x.m.reverts) > 0 {
				return
			}
		}
	}
	if moved {
		stat_add(w, STAT_CLOSE_UNDO_ELSEWHERE)
		return
	}
	paths := TREE_PATHS
	for p in paths {
		t, terr := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, c.eline)
		if terr != .None && terr != .Not_Found {
			return
		}
		if p == c.path {
			for tok in op.tokens {
				if strings.contains(string(t), tok) {
					world_fail(w, "deferred close: undo of %s's turn on %s left its token %s in %s (%q)", id_short(op.actor), c.root, tok, p, string(t))
				}
			}
		}
		it := c.was[p]
		for line in strings.split_lines_iterator(&it) {
			if p == c.path && slice.contains(op.tokens[:], line) {
				continue
			}
			if len(line) > 0 && !strings.contains(string(t), line) {
				world_fail(w, "deferred close: undo of %s's turn on %s removed %q from %s (%q)", id_short(op.actor), c.root, line, p, string(t))
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

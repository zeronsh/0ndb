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
	tokens: []string,
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

@(init)
_deferred_close_init :: proc "contextless" () {
	register_world(67, _closes_init, _closes_destroy)
	register_final_check(123, check_deferred_closes)
	register_final_check(9000, check_deferred_undo)
	register_stat_line(72, "deferred_close")
	STAT_CLOSE_DEFERRED = register_stat(72, 0, "deferred")
	STAT_CLOSE_RESUMED = register_stat(72, 1, "resumed")
	STAT_CLOSE_CRASHED = register_stat(72, 2, "crashed")
	STAT_CLOSE_UNDONE = register_stat(72, 3, "undone")
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

deferred_close_note :: proc(w: ^World, n: ^Node, root: string, path: string, actor: prim.Id, tokens: []string, before: []crdt.Op_Id) {
	stat_add(w, STAT_CLOSE_DEFERRED)
	world_note(w, "%s a scope close on %s/%s is deferred; its base outcome is owed", n.name, root, path)
	append(&_closes, Deferred_Close{n.idx, int(n.incarnation), strings.clone(root, w.allocator), strings.clone(path, w.allocator), actor, slice.clone(tokens, w.allocator), slice.clone(before, w.allocator)})
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

check_deferred_undo :: proc(w: ^World) {
	if len(w.failures) > 0 {
		return
	}
	for c in _resumed {
		n := w.nodes[c.node]
		if !n.alive || !n.e_open || int(n.incarnation) != c.inc {
			continue
		}
		sm: ^Sim_Mount
		for &x in n.mounts {
			if x.root == c.root && x.m != nil {
				sm = &x
			}
		}
		if sm == nil {
			continue
		}
		context = instance_context(&n.inst)
		vfs := disk_vfs(&n.disk)
		tree := w.model.objs[sm.oi].o
		line := line_eng(mount_model_line(sm.m, vfs, sm.root))
		paths := TREE_PATHS
		was := make(map[string]string, context.temp_allocator)
		for p in paths {
			t, _ := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, line)
			was[p] = strings.clone(string(t), context.temp_allocator)
		}
		after := slice.clone(_line_heads(sm.m), context.temp_allocator)
		if rerr := fs.mount_revert(sm.m, fs.Version(c.before), fs.Version(after), c.actor); rerr != .None {
			world_fail(w, "deferred close: undo of %s's turn on %s/%s failed: %v", id_short(c.actor), c.root, c.path, rerr)
			continue
		}
		node_after(n)
		run_until(w, w.now + 20_000_000_000, true)
		context = instance_context(&n.inst)
		for p in paths {
			t, _ := eng.tree_read(&n.e, tree, p, context.temp_allocator, {}, line)
			want := was[p]
			if p == c.path {
				for tok in c.tokens {
					want, _ = strings.replace_all(want, strings.concatenate({tok, "\n"}, context.temp_allocator), "", context.temp_allocator)
				}
			}
			if string(t) != want {
				world_fail(w, "deferred close: undo of %s's turn on %s left %s as %q, want %q (its tokens %v)", id_short(c.actor), c.root, p, string(t), want, c.tokens)
			}
		}
		stat_add(w, STAT_CLOSE_UNDONE)
	}
}

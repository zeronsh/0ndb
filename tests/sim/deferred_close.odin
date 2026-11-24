package sim

import "core:strings"
import "../../src/fs"
import "../../src/prim"

@(private = "file")
Deferred_Close :: struct {
	node:  int,
	inc:   int,
	root:  string,
	path:  string,
	actor: prim.Id,
}

@(private = "file")
_closes: [dynamic]Deferred_Close

STAT_CLOSE_DEFERRED: Stat
STAT_CLOSE_RESUMED: Stat
STAT_CLOSE_CRASHED: Stat

@(init)
_deferred_close_init :: proc "contextless" () {
	register_world(67, _closes_init, _closes_destroy)
	register_final_check(123, check_deferred_closes)
	register_stat_line(72, "deferred_close")
	STAT_CLOSE_DEFERRED = register_stat(72, 0, "deferred")
	STAT_CLOSE_RESUMED = register_stat(72, 1, "resumed")
	STAT_CLOSE_CRASHED = register_stat(72, 2, "crashed")
}

@(private = "file")
_closes_init :: proc(w: ^World) {
	_closes = make([dynamic]Deferred_Close, w.allocator)
}

@(private = "file")
_closes_destroy :: proc(w: ^World) {
	for c in _closes {
		delete(c.root, w.allocator)
		delete(c.path, w.allocator)
	}
	delete(_closes)
	_closes = nil
}

deferred_close_note :: proc(w: ^World, n: ^Node, root: string, path: string, actor: prim.Id) {
	stat_add(w, STAT_CLOSE_DEFERRED)
	world_note(w, "%s a scope close on %s/%s is deferred; its base outcome is owed", n.name, root, path)
	append(&_closes, Deferred_Close{n.idx, int(n.incarnation), strings.clone(root, w.allocator), strings.clone(path, w.allocator), actor})
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
		delete(c.root, w.allocator)
		delete(c.path, w.allocator)
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

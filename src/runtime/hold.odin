package rt

import "../convo"
import eng "../engine"
import "../fs"
import "../prim"

runtime_hold_line :: proc(r: ^Runtime, tree: prim.Id, line: string, reason: convo.Hold_Reason) -> (held: int) {
	context = eng.context_for(r.e)
	if reason == .None {
		return 0
	}
	for run in r.runs {
		if run.state == .Finished || !run_bound_to(run, tree, line) {
			continue
		}
		if len(run.hold_commit) == 0 {
			run.hold_commit = clone(_line_commit(r, run.o, tree, line), run.alloc)
		}
		run_hold_request(run, reason, line)
		held += 1
	}
	return
}

runtime_resume_line :: proc(r: ^Runtime, tree: prim.Id, line: string) -> (resumed: int) {
	context = eng.context_for(r.e)
	for sw in r.spaces {
		for ent in state_runs(r, sw.space) {
			if ent.hold == 0 || run_find(r, ent.object) != nil {
				continue
			}
			binds := convo.binds_decode(ent.bound)
			if !binds_have(binds, tree, line) || _bound_elsewhere(r, ent.object, binds, tree) {
				continue
			}
			if _revive(r, ent, lines_decode(ent.lines)) == .None {
				resumed += 1
				r.stats.runs_resumed += 1
			}
		}
	}
	return
}

runtime_held_lines :: proc(r: ^Runtime, o: Object) -> (reason: convo.Hold_Reason, line: string, held: bool) {
	ent, found := state_run_get(r, o)
	if !found || ent.hold == 0 {
		return .None, "", false
	}
	return convo.Hold_Reason(ent.hold), ent.hold_line, true
}

@(private)
_bound_elsewhere :: proc(r: ^Runtime, o: Object, binds: []convo.Line_Bind, resumed: prim.Id) -> bool {
	for b in binds {
		if b.tree == resumed {
			continue
		}
		dir, ok := _tree_home(r, b.tree)
		if !ok {
			continue
		}
		if dir_line_key(eng.base_vfs(r.e), dir, b.line) != b.line {
			return true
		}
	}
	return false
}

@(private)
_tree_home :: proc(r: ^Runtime, tree: prim.Id) -> (dir: string, ok: bool) {
	if r.cfg.homes.home == nil {
		return "", false
	}
	return r.cfg.homes.home(r.cfg.homes.data, tree, context.temp_allocator)
}

@(private)
_line_commit :: proc(r: ^Runtime, o: Object, tree: prim.Id, line: string) -> string {
	if len(line) > len("git:detached:") && line[:len("git:detached:")] == "git:detached:" {
		return line[len("git:detached:"):]
	}
	if len(line) <= len("git:") || line[:len("git:")] != "git:" {
		return ""
	}
	dir, ok := _tree_home(r, tree)
	if !ok {
		return ""
	}
	vfs := eng.base_vfs(r.e)
	g, found := fs.git_locate(vfs, dir, context.temp_allocator)
	if !found {
		return ""
	}
	commit, _ := fs.git_resolve_ref(vfs, g, line[len("git:"):], context.temp_allocator)
	return commit
}

@(private)
_line_moved :: proc(r: ^Runtime, ent: Run_Entry) -> bool {
	if len(ent.hold_commit) == 0 {
		return false
	}
	for b in convo.binds_decode(ent.bound) {
		if b.line == ent.hold_line {
			return _line_commit(r, ent.object, b.tree, b.line) != ent.hold_commit
		}
	}
	return false
}

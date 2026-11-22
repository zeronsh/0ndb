package rt

import "core:strings"
import "../convo"
import eng "../engine"
import "../fs"
import omap "../map"
import "../prim"

@(private)
Land_Target :: struct {
	m:      ^fs.Mount,
	target: string,
}

task_land :: proc(r: ^Runtime, o: Object, ws: ^Worktree) -> (tried: bool, landed: bool, conflicts: []string) {
	settings, serr := eng.convo_settings(r.e, o, context.temp_allocator)
	if serr != .None || prim.id_is_zero(settings.parent.object) {
		return
	}
	parent := Object{o.space, settings.parent.object}
	cms, _ := eng.convo_mounts(r.e, parent, context.temp_allocator)
	prun := run_find(r, parent)
	list := make([dynamic]Land_Target, context.temp_allocator)
	for &mb in ws.members {
		if mb.m == nil {
			continue
		}
		target := ""
		for cm in cms {
			if cm.name == mb.name && cm.tree == mb.tree {
				target = line_name(cm.line)
			}
		}
		if prun != nil && prun.ws != nil {
			for pmb in prun.ws.members {
				if pmb.name == mb.name && pmb.tree == mb.tree && pmb.m != nil {
					target = line_name(pmb.run_line)
				}
			}
		}
		if len(target) == 0 || target == mb.m.line {
			continue
		}
		append(&list, Land_Target{mb.m, target})
	}
	if len(list) == 0 {
		return
	}
	tried = true
	found := make([dynamic]fs.Land_Conflict, context.temp_allocator)
	for x in list {
		if fs.mount_sync_from(x.m, x.target, &found, context.temp_allocator) != .None {
			return true, false, nil
		}
	}
	if len(found) > 0 {
		paths := make([]string, len(found), context.temp_allocator)
		for c, i in found {
			paths[i] = c.path
		}
		return true, false, paths
	}
	reg, rerr := eng.registry(r.e)
	for x in list {
		h := x.m.history
		v, vfound, verr := fs.history_line(h, x.m.line, context.temp_allocator)
		if verr != .None || !vfound || fs.history_set_line(h, x.target, v) != .None {
			return true, false, nil
		}
		if rerr != .None {
			continue
		}
		for m in reg.mounts {
			if m != nil && m != x.m && m.history == h && m.line == x.target {
				fs.mount_materialize(m)
			}
		}
	}
	return true, true, nil
}

land_note :: proc(r: ^Runtime, o: Object, w: ^convo.Writer, landed: bool, conflicts: []string) {
	if landed {
		map_clear(r, meta_w(r, o), transmute([]u8)string(KEY_TASK), 5)
		hold_release(r, o, w, HOLD_LAND)
		return
	}
	reason := "land failed"
	if len(conflicts) > 0 {
		map_put(r, meta_w(r, o), transmute([]u8)string(KEY_TASK), omap.field_str(5, strings.join(conflicts, "\n", context.temp_allocator)))
		reason = concat("land conflicts: ", strings.join(conflicts, ", ", context.temp_allocator))
	}
	hold_set(r, o, w, HOLD_LAND, reason)
}

hold_set :: proc(r: ^Runtime, o: Object, w: ^convo.Writer, key: string, reason: string) -> Error {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return _eerr(verr)
	}
	if _, herr := convo.writer_hold(w, v, key, reason); herr != .None {
		return .Engine
	}
	eng.catalog_status_changed(r.e, o)
	return .None
}

hold_release :: proc(r: ^Runtime, o: Object, w: ^convo.Writer, key: string) -> (released: int, err: Error) {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return 0, _eerr(verr)
	}
	n, rerr := convo.writer_release(w, v, key)
	if rerr != .None {
		return n, .Engine
	}
	if n > 0 {
		eng.catalog_status_changed(r.e, o)
	}
	return n, .None
}

hold_reason :: proc(r: ^Runtime, o: Object) -> string {
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return ""
	}
	list, lerr := convo.holds(v, context.temp_allocator)
	if lerr != .None || len(list) == 0 {
		return ""
	}
	for h in list {
		if h.key == HOLD_LAND {
			return h.text
		}
	}
	return list[0].text
}

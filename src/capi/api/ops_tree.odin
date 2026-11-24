package api

import "core:strings"
import "../../crdt"
import eng "../../engine"
import rt "../../runtime"
import "../../fs"
import "../../prim"

Mounted :: struct {
	object: Object,
	root:   string,
	mount:  ^fs.Mount,
}

@(private)
_mounts_close_all :: proc(a: ^Api) {
	for m in a.mounts {
		eng.tree_unmount(a.e, m.mount)
		delete(m.root, a.allocator)
		free(m, a.allocator)
	}
	clear(&a.mounts)
}

mount_find :: proc(a: ^Api, ob: Object, root: string) -> ^Mounted {
	for m in a.mounts {
		if m.object == ob && (len(root) == 0 || fs.path_same(m.root, root)) {
			return m
		}
	}
	return nil
}

mount_open :: proc(a: ^Api, ob: Object, root: string) -> (m: ^Mounted, st: Status) {
	if !prim.is_abs(root) {
		return nil, .Invalid
	}
	clean := strings.trim_right(root, "/")
	if len(clean) == 0 || (len(clean) == 2 && clean[1] == ':') {
		clean = root[:len(clean) + 1]
	}
	if x := mount_find(a, ob, clean); x != nil {
		return x, .Ok
	}
	for x in a.mounts {
		if fs.path_same(x.root, clean) {
			return nil, .Exists
		}
	}
	if perr := prim.mkdir_all(prim.os_vfs(), clean, 0o755); perr != .None {
		return nil, .Io
	}
	if a.r != nil {
		if reg, rerr := eng.registry(a.e); rerr == .None {
			fs.registry_set_spawner(reg, rt.fs_spawner(a.r))
		}
	}
	fm, err := eng.tree_mount(a.e, ob, clean)
	if err != .None && !(err == .Pending && fm != nil) {
		return nil, status_of(err)
	}
	m = new(Mounted, a.allocator)
	m.object = ob
	m.root = strings.clone(clean, a.allocator)
	m.mount = fm
	append(&a.mounts, m)
	return m, .Ok
}

mount_close :: proc(a: ^Api, m: ^Mounted) {
	for x, i in a.mounts {
		if x == m {
			ordered_remove(&a.mounts, i)
			break
		}
	}
	eng.tree_unmount(a.e, m.mount)
	delete(m.root, a.allocator)
	free(m, a.allocator)
}

mount_at :: proc(a: ^Api, path: string) -> (m: ^Mounted, rel: string) {
	best := -1
	for x in a.mounts {
		r := x.root
		if path == r || (strings.has_prefix(path, r) && (r == "/" || (len(path) > len(r) && path[len(r)] == '/'))) {
			if len(r) > best {
				best = len(r)
				m = x
			}
		}
	}
	if m == nil {
		return nil, ""
	}
	rel = path[len(m.root):]
	for len(rel) > 0 && rel[0] == '/' {
		rel = rel[1:]
	}
	return m, rel
}

op_tree_mount :: proc(c: ^Call, o: ^Out) -> Status {
	_, st := mount_open(c.api, a_object(c, "object"), a_str(c, "root"))
	return st
}

op_tree_unmount :: proc(c: ^Call, o: ^Out) -> Status {
	m := mount_find(c.api, a_object(c, "object"), strings.trim_right(a_str(c, "root"), "/"))
	if m == nil {
		return .Not_Found
	}
	mount_close(c.api, m)
	return .Ok
}

op_tree_mounts :: proc(c: ^Call, o: ^Out) -> Status {
	o_arr(o, "mounts", len(c.api.mounts))
	for m in c.api.mounts {
		o_obj(o, "")
		o_object(o, "object", m.object)
		o_str(o, "root", m.root)
		o_str(o, "line", m.mount.line)
		o_bool(o, "gated", fs.mount_gated(m.mount))
		o_u64(o, "gate_overruns", fs.mount_gate_overruns(m.mount))
		o_str(o, "status", "stale .git/index.lock" if fs.mount_lock_stale(m.mount) else "")
		o_end(o)
	}
	o_end(o)
	return .Ok
}

op_tree_sync :: proc(c: ^Call, o: ^Out) -> Status {
	m := mount_find(c.api, a_object(c, "object"), strings.trim_right(a_str(c, "root"), "/"))
	if m == nil {
		return .Not_Found
	}
	serr: fs.Error
	{
		context = eng.context_for(c.api.e)
		serr = fs.mount_sync(m.mount)
	}
	if serr != .None {
		return .Io
	}
	eng.touched(c.api.e, m.object)
	return .Ok
}

op_tree_find :: proc(c: ^Call, o: ^Out) -> Status {
	m, rel := mount_at(c.api, a_str(c, "path"))
	if m == nil {
		return .Not_Found
	}
	o_object(o, "object", m.object)
	o_str(o, "root", m.root)
	o_str(o, "rel", rel)
	return .Ok
}

emit_spans :: proc(o: ^Out, data: []u8, spans: []crdt.Author_Span, owners: []fs.Span_Owner = nil) {
	o_text(o, "text", data)
	o_arr(o, "spans", len(spans))
	at := 0
	line: u64 = 1
	for s, k in spans {
		lo := min(at, len(data))
		hi := min(at + s.len, len(data))
		l0 := line
		for i in lo ..< hi {
			if data[i] == '\n' {
				line += 1
			}
		}
		o_obj(o, "")
		o_u64(o, "lo", u64(lo))
		o_u64(o, "hi", u64(hi))
		o_u64(o, "line_lo", l0)
		o_u64(o, "line_hi", line)
		o_id(o, "actor", s.id.actor)
		o_u64(o, "seq", s.id.seq)
		o_id(o, "op_actor", s.op.actor)
		o_u64(o, "op_seq", s.op.seq)
		o_bool(o, "redacted", s.redacted)
		if owners != nil {
			w := owners[k]
			o_enum(o, "owner", u64(w.kind), OWNER_NAMES[:])
			o_id(o, "conversation", w.conversation)
			o_id(o, "scope", w.scope)
			o_id(o, "device", w.device)
		}
		o_end(o)
		at = hi
	}
	o_end(o)
}

op_tree_blame :: proc(c: ^Call, o: ^Out) -> Status {
	ob := a_object(c, "object")
	path := a_str(c, "path")
	line := a_str(c, "line")
	if m := mount_find(c.api, ob, ""); m != nil {
		context = eng.context_for(c.api.e)
		fs.mount_sync(m.mount)
	}
	owners: []fs.Span_Owner
	data, spans, err := eng.tree_blame(c.api.e, ob, path, context.temp_allocator, line, &owners)
	if err != .None {
		return status_of(err)
	}
	o_str(o, "line", eng.tree_line(c.api.e, ob, line))
	emit_spans(o, data, spans, owners)
	return .Ok
}

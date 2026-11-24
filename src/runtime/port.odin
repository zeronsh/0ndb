package rt

import "core:hash/xxhash"
import "core:strings"
import "../agent"
import eng "../engine"
import omap "../map"
import "../prim"

@(private)
KEY_FILE :: "nf/"
@(private)
TAIL_CHECK :: 4096

Port_Entry :: struct {
	key:  string,
	rel:  string,
	path: string,
}

port_env :: proc(r: ^Runtime, cwd: string) -> agent.Port_Env {
	return agent.Port_Env{home = r.cfg.home_dir, cwd = cwd, scratch = concat(r.cfg.work_root, "/.scratch"), env = r.cfg.env}
}

rid_uuid :: proc(rid: Rid, allocator := context.temp_allocator) -> string {
	seg := rid.seg
	off: [8]u8
	prim.put_u64le(off[:], u64(rid.off))
	id := derive_id("0ndb-native-uuid-v1", seg[:], off[:])
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	h := prim.id_hex(id)
	return concat(string(h[0:8]), "-", string(h[8:12]), "-", string(h[12:16]), "-", string(h[16:20]), "-", string(h[20:32]))
}

@(private)
_walk_files :: proc(r: ^Runtime, root: string, rel: string, out: ^[dynamic]Port_Entry, key: string, depth: int) {
	if depth > 16 || len(out) > 4096 {
		return
	}
	dir := root if len(rel) == 0 else concat(root, "/", rel)
	d: prim.Dir
	if prim.dir_open(r.e.base, &d, dir, context.temp_allocator) != .None {
		return
	}
	defer prim.dir_close(r.e.base, &d)
	for {
		e, more, err := prim.dir_next(r.e.base, &d)
		if err != .None || !more {
			return
		}
		if e.name == "." || e.name == ".." {
			continue
		}
		sub := e.name if len(rel) == 0 else concat(rel, "/", e.name)
		sub = clone(sub, context.temp_allocator)
		if e.kind == .Dir {
			_walk_files(r, root, sub, out, key, depth + 1)
		} else if e.kind == .File {
			append(out, Port_Entry{key = key, rel = sub, path = concat(root, "/", sub)})
		}
	}
}

@(private)
_match_file :: proc(r: ^Runtime, root: string, match: string) -> string {
	list := make([dynamic]Port_Entry, context.temp_allocator)
	_walk_files(r, root, "", &list, "", 0)
	for e in list {
		if strings.has_suffix(e.path, match) {
			return e.path
		}
	}
	return ""
}

port_export :: proc(r: ^Runtime, o: Object, desc: agent.Provider_Descriptor, ni: ^Native_Info, cwd: string) {
	if len(ni.session) == 0 {
		return
	}
	env := port_env(r, cwd)
	plan := agent.export_session(desc, env, ni.session, ni.native, context.temp_allocator)
	if plan.seeded {
		return
	}
	entries := make([dynamic]Port_Entry, context.temp_allocator)
	files := make([dynamic]agent.Port_File, context.temp_allocator)
	for f in plan.files {
		path := f.path
		if len(f.match) > 0 {
			path = _match_file(r, f.path, f.match)
			if len(path) == 0 {
				continue
			}
		}
		if f.dir {
			if !prim.exists(r.e.base, path) {
				continue
			}
			_walk_files(r, path, "", &entries, f.key, 0)
		} else {
			if !prim.exists(r.e.base, path) {
				continue
			}
			append(&entries, Port_Entry{key = f.key, path = path})
		}
		pf := f
		pf.path = path
		append(&files, pf)
	}
	for run in plan.runs {
		st, out, err := run_blocking(r, run.argv, run.cwd)
		if err != .None || st.code != 0 || len(run.stdout) == 0 {
			continue
		}
		_store_file(r, o, run.stdout, "", out, true)
	}
	for e in entries {
		_export_file(r, o, e)
	}
	ni.manifest = agent.export_manifest(desc, env, ni.session, files[:], context.temp_allocator)
	native_put(r, o, ni^)
}

@(private)
_nf_key :: proc(key: string, rel: string) -> []u8 {
	if len(rel) == 0 {
		return key_of(KEY_FILE, transmute([]u8)key)
	}
	return key_of(KEY_FILE, transmute([]u8)key, []u8{'/'}, transmute([]u8)rel)
}

@(private)
_export_file :: proc(r: ^Runtime, o: Object, e: Port_Entry) {
	vfs := r.e.base
	st, serr := prim.stat(vfs, e.path)
	if serr != .None || st.kind != .File {
		return
	}
	meta := meta_w(r, o)
	k := _nf_key(e.key, e.rel)
	en, found := map_read(r, meta, k)
	tid := entry_id(&en, 1) if found else prim.Id{}
	have := i64(entry_u64(&en, 2)) if found else 0
	sum := entry_u64(&en, 3) if found else 0
	if !prim.id_is_zero(tid) && have <= st.size && have > 0 {
		fd, oerr := prim.open_file(vfs, e.path)
		if oerr == .None {
			defer prim.close_file(vfs, fd)
			lo := max(have - TAIL_CHECK, 0)
			tail := make([]u8, have - lo, context.temp_allocator)
			n, rerr := prim.read_at(vfs, fd, tail, lo)
			if rerr == .None && i64(n) == have - lo && xxhash.XXH3_64_default(tail) == sum {
				if st.size == have {
					return
				}
				delta := make([]u8, st.size - have, context.temp_allocator)
				m, derr := prim.read_at(vfs, fd, delta, have)
				if derr == .None && i64(m) == st.size - have {
					to := Object{o.space, tid}
					if eng.text_edit(r.e, to, int(have), 0, string(delta)) == .None {
						lo2 := max(st.size - TAIL_CHECK, 0)
						full_tail := make([]u8, st.size - lo2, context.temp_allocator)
						prim.read_at(vfs, fd, full_tail, lo2)
						map_put(r, meta, k, omap.field_id(1, tid), omap.field_u64(2, u64(st.size)), omap.field_u64(3, xxhash.XXH3_64_default(full_tail)))
						return
					}
				}
			}
		}
	}
	data, rerr := prim.read_file(vfs, e.path, context.temp_allocator)
	if rerr != .None {
		return
	}
	_store_file(r, o, e.key, e.rel, data, false)
}

@(private)
_store_file :: proc(r: ^Runtime, o: Object, key: string, rel: string, data: []u8, replace: bool) {
	meta := meta_w(r, o)
	k := _nf_key(key, rel)
	en, found := map_read(r, meta, k)
	tid := entry_id(&en, 1) if found else prim.Id{}
	if prim.id_is_zero(tid) {
		t, err := eng.text_create(r.e, o.space, concat("session ", key), string(data))
		if err != .None {
			return
		}
		tid = t.id
	} else {
		to := Object{o.space, tid}
		cur, rerr := eng.text_read(r.e, to, context.temp_allocator)
		if rerr != .None {
			return
		}
		if eng.text_edit(r.e, to, 0, len(cur), string(data)) != .None {
			return
		}
	}
	lo := max(len(data) - TAIL_CHECK, 0)
	map_put(r, meta, k, omap.field_id(1, tid), omap.field_u64(2, u64(len(data))), omap.field_u64(3, xxhash.XXH3_64_default(data[lo:])))
}

port_import :: proc(r: ^Runtime, o: Object, desc: agent.Provider_Descriptor, ni: ^Native_Info, cwd: string) -> (session: string, ok: bool) {
	if len(ni.manifest) == 0 {
		return "", false
	}
	env := port_env(r, cwd)
	plan := agent.import_session(desc, ni.manifest, env, context.temp_allocator)
	if plan.seeded {
		return "", false
	}
	meta := meta_object(o)
	for f in plan.files {
		prefix := key_of(KEY_FILE, transmute([]u8)f.key)
		rows := map_rows(r, meta, prefix, 4096)
		wrote := false
		for &row in rows {
			rest := string(row.key[len(prefix):])
			dst := f.path
			if f.dir {
				if !strings.has_prefix(rest, "/") {
					continue
				}
				dst = concat(f.path, rest)
			} else if len(rest) > 0 {
				continue
			}
			tid := entry_id(&row.entry, 1)
			data, rerr := eng.text_read(r.e, Object{o.space, tid}, context.temp_allocator)
			if rerr != .None {
				return "", false
			}
			if f.rewrite {
				data = agent.apply_rewrites(plan, data, context.temp_allocator)
			}
			prim.mkdir_all(r.e.base, prim.dir_name(dst), 0o700)
			if prim.replace_atomic(r.e.base, dst, data) != .None {
				return "", false
			}
			wrote = true
		}
		if !wrote && !f.optional {
			return "", false
		}
	}
	outputs := make([dynamic]string, context.temp_allocator)
	for run in plan.runs {
		st, out, err := run_blocking(r, run.argv, run.cwd)
		if err != .None || st.code != 0 {
			return "", false
		}
		append(&outputs, string(out))
	}
	s := agent.import_result(desc, plan, outputs[:], context.temp_allocator)
	if len(s) == 0 {
		return "", false
	}
	ni.session = clone(s, context.temp_allocator)
	ni.runner = r.self
	ni.cwd = cwd
	ni.home = r.cfg.home_dir
	native_put(r, o, ni^)
	return ni.session, true
}

@(private)
_remove_tree :: proc(r: ^Runtime, path: string) {
	if len(path) == 0 {
		return
	}
	vfs := r.e.base
	st, err := prim.lstat(vfs, path)
	if err != .None {
		return
	}
	if st.kind == .Dir {
		d: prim.Dir
		if prim.dir_open(vfs, &d, path, context.temp_allocator) == .None {
			names := make([dynamic]string, context.temp_allocator)
			for {
				e, more, derr := prim.dir_next(vfs, &d)
				if derr != .None || !more {
					break
				}
				if e.name != "." && e.name != ".." {
					append(&names, concat(path, "/", e.name))
				}
			}
			prim.dir_close(vfs, &d)
			for n in names {
				_remove_tree(r, n)
			}
		}
		prim.remove_dir(vfs, path)
		return
	}
	prim.remove(vfs, path)
}

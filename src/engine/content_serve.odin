package engine

import "base:runtime"
import "core:crypto"
import "core:io"
import "../fs"
import omap "../map"
import "../odb"
import "../prim"
import osync "../sync"

@(private)
SERVE_CACHE_MIN :: 8 * 1024 * 1024

@(private)
_serve_key :: proc(key: osync.Object_Key) -> (k: [36]u8) {
	k[0] = 0xff
	k[1] = 's'
	k[2] = 'r'
	k[3] = 'v'
	x := key
	copy(k[4:], x[:])
	return
}

@(private)
_serve_register :: proc(e: ^Engine, h: ^Handle, refs: []fs.Content_Ref) {
	if len(refs) == 0 {
		return
	}
	db, derr := device_odb(e)
	if derr != .None {
		return
	}
	t, terr := omap.txn_begin(&e.reg.db)
	if terr != .None {
		return
	}
	for ref in refs {
		_, size, herr := odb.read_header(db, ref.oid)
		if herr != .None {
			continue
		}
		oid := ref.oid
		key := osync.object_index(&h.scope, oid[:ref.len])
		parts := i64(-1)
		if size > osync.OBJECT_INLINE_MAX {
			parts = (size + osync.OBJECT_PART - 1) / osync.OBJECT_PART
		}
		for p := i64(-1); p < max(parts, 0); p += 1 {
			buf: [96]u8
			buf[0] = 1
			sid := h.sp.id
			copy(buf[1:17], sid[:])
			oidb := h.id
			copy(buf[17:33], oidb[:])
			prim.put_u64le(buf[33:41], u64(size))
			prim.put_u64le(buf[41:49], u64(p))
			buf[49] = u8(ref.len)
			copy(buf[50:], oid[:ref.len])
			w := 50 + ref.len
			k := _serve_key(osync.object_part_index(key, p))
			if omap.txn_put(t, ROOT_OWNED, k[:], buf[:w]) != .None {
				omap.txn_abort(t)
				return
			}
		}
	}
	omap.txn_commit(t)
}

@(private)
_repl_object_source :: proc(user: rawptr, key: osync.Object_Key, allocator: runtime.Allocator) -> (src: osync.Object_Source, ok: bool) {
	sp := (^Space)(user)
	e := sp.e
	context = context_for(e)
	k := _serve_key(key)
	v, found, err := omap.db_get(&e.reg.db, ROOT_OWNED, k[:], context.temp_allocator)
	if err != .None || !found || len(v) < 50 || v[0] != 1 {
		return
	}
	n := int(v[49])
	if n != 20 && n != 32 || len(v) != 50 + n {
		return
	}
	space, object: prim.Id
	copy(space[:], v[1:17])
	copy(object[:], v[17:33])
	if space != sp.id {
		return
	}
	size := i64(prim.get_u64le(v[33:41]))
	part := i64(prim.get_u64le(v[41:49]))
	oid: odb.Oid
	copy(oid[:n], v[50:])
	db, derr := device_odb(e)
	if derr != .None {
		return
	}
	src.part = part
	src.size = size
	if size < SERVE_CACHE_MIN {
		t, data, rerr := odb.read(db, oid, allocator)
		if rerr != .None || t != .Blob || i64(len(data)) != size {
			return
		}
		src.data = data
	} else {
		p, cok := _serve_cache(e, db, oid, n, size)
		if !cok {
			return
		}
		src.path, _ = _clone(p, allocator)
	}
	scope := _object_scope(sp, object)
	defer osync.scope_clear(&scope)
	if scope.mode == .Transparent {
		src.plain = true
		return src, true
	}
	tree: osync.Key_Tree
	if _content_tree(&scope, &tree) != .None {
		return {}, false
	}
	defer osync.keytree_destroy(&tree)
	ck, kok := osync.object_tree_key(&tree, &scope, oid[:n])
	if !kok {
		return {}, false
	}
	src.ckey = ck
	crypto.zero_explicit(&ck, size_of(ck))
	return src, true
}

@(private)
Serve_Sink :: struct {
	vfs: prim.Vfs,
	fd:  prim.Fd,
	off: i64,
	bad: bool,
}

@(private)
_serve_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Serve_Sink)(data)
	#partial switch mode {
	case .Write:
		if prim.write_at(s.vfs, s.fd, p, s.off) != .None {
			s.bad = true
			return 0, .Unknown
		}
		s.off += i64(len(p))
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

@(private)
_serve_cache :: proc(e: ^Engine, db: ^odb.Odb, oid: odb.Oid, n: int, size: i64) -> (path: string, ok: bool) {
	hx: [64]u8
	o := oid
	prim.hex_encode(hx[:], o[:n])
	dir, jerr := _join(context.temp_allocator, e.dir, "serve")
	if jerr != .None || prim.mkdir_all(e.base, dir, 0o700) != .None {
		return
	}
	p, perr := _join(context.temp_allocator, dir, string(hx[:2 * n]))
	if perr != .None {
		return
	}
	if st, serr := prim.stat(e.base, p); serr == .None && st.size == size {
		return p, true
	}
	tmp, terr := _join(context.temp_allocator, dir, "fill.tmp")
	if terr != .None {
		return
	}
	fd, oerr := prim.open_file(e.base, tmp, {.Write, .Create, .Truncate}, 0o600)
	if oerr != .None {
		return
	}
	sink := Serve_Sink{vfs = e.base, fd = fd}
	t, got, serr := odb.stream(db, oid, io.Writer{procedure = _serve_sink_proc, data = &sink})
	prim.close_file(e.base, fd)
	if serr != .None || t != .Blob || got != size || sink.bad || prim.rename(e.base, tmp, p) != .None {
		prim.remove(e.base, tmp)
		return
	}
	return p, true
}

@(private)
_content_holders :: proc(e: ^Engine, sp: ^Space, object: prim.Id, allocator := context.temp_allocator) -> []osync.Device_Id {
	out := make([dynamic]osync.Device_Id, allocator)
	if rec, found, _ := _rec_get(e, object); found {
		for m in rec.members {
			if m.device != e.self {
				append(&out, osync.Device_Id(m.device))
			}
		}
	}
	for d in _holders_always_on(e, sp, context.temp_allocator) {
		dup := false
		for x in out {
			if x == osync.Device_Id(d) {
				dup = true
				break
			}
		}
		if !dup && d != e.self {
			append(&out, osync.Device_Id(d))
		}
	}
	return out[:]
}

@(private)
_content_unavailable :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	if len(ev.oid) != 20 && len(ev.oid) != 32 {
		return
	}
	oid: odb.Oid
	copy(oid[:], ev.oid)
	w, ok := e.content.waits[oid]
	if !ok {
		return
	}
	list, has := e.unavailable[w.object]
	if !has {
		list = make([dynamic]prim.Id, e.allocator)
	}
	clear(&list)
	for i := 0; i + 16 <= len(ev.meta); i += 16 {
		d: prim.Id
		copy(d[:], ev.meta[i:][:16])
		append(&list, d)
	}
	e.unavailable[w.object] = list
	for d in list {
		_emit(e, Event{kind = .Unavailable, space = sp.id, object = w.object, device = d})
	}
}

@(private)
_content_holders_changed :: proc(e: ^Engine, sp: ^Space) {
	for k in _sorted_keys(e.content.waits) {
		w := e.content.waits[k]
		if w.space != sp.id || w.stage != .Holders || !w.inflight {
			continue
		}
		oid := w.oid
		h, herr := _handle_get(e, Object{w.space, w.object}, .File_Tree)
		if herr != .None {
			continue
		}
		osync.replicator_object_holders(&sp.repl, &h.scope, oid[:w.n], _content_holders(e, sp, w.object))
	}
}

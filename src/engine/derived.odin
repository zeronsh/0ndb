package engine

import "core:fmt"
import "core:strings"
import "../crdt"
import "../fs"
import "../fstree"
import "../convo"
import "../journal"
import omap "../map"
import "../obj"
import "../pack"
import "../prim"

@(private)
_own_stream_path :: proc(e: ^Engine, id: prim.Id, kind: Kind) -> (path: string, err: Error) {
	if kind == .Text || kind == .File_Tree {
		d := _obj_dir(e, id) or_return
		return _join(context.temp_allocator, d, "hist", "fs.journal")
	}
	return _seg_path(e, id)
}

@(private)
_own_stream_len :: proc(e: ^Engine, id: prim.Id, kind: Kind) -> (n: i64, err: Error) {
	if h, ok := e.handles[id]; ok && h.w_open {
		return _own_len(h), .None
	}
	path := _own_stream_path(e, id, kind) or_return
	if !prim.exists(e.vfs, path) {
		return 0, .None
	}
	j: journal.Journal
	_jerr(journal.journal_open(&j, e.vfs, path, {}, e.allocator)) or_return
	n = journal.journal_durable_len(&j)
	journal.journal_close(&j)
	return n, .None
}

@(private)
_owns_segment :: proc "contextless" (kind: Kind) -> bool {
	return kind == .Conversation || kind == .Map
}

@(private)
_own_keyed :: proc(e: ^Engine, id: prim.Id) -> (keyed: bool, err: Error) {
	path := _keys_path(e, id) or_return
	return prim.exists(e.vfs, path), .None
}

@(private)
Reg_Fact :: struct {
	key:   [33]u8,
	klen:  int,
	value: []u8,
}

@(private)
_reg_collect :: proc(e: ^Engine, root: int) -> (facts: [dynamic]Reg_Fact, err: Error) {
	facts = make([dynamic]Reg_Fact, context.temp_allocator)
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		if len(key) > 33 {
			return true
		}
		f := Reg_Fact{klen = len(key)}
		copy(f.key[:], key)
		f.value = make([]u8, len(value), context.temp_allocator)
		copy(f.value, value)
		append((^[dynamic]Reg_Fact)(data), f)
		return true
	}
	_oerr(omap.db_scan(&e.reg.db, root, nil, nil, &facts, visit)) or_return
	return facts, .None
}

@(private)
Reg_Fix :: struct {
	root:  int,
	key:   [33]u8,
	klen:  int,
	value: []u8,
	del:   bool,
}

@(private)
_reg_kind :: proc(e: ^Engine, id: prim.Id) -> (kind: Kind, ok: bool) {
	rec, found, err := _rec_get(e, id)
	if err != .None || !found {
		return
	}
	return rec.kind, true
}

@(private)
_reg_audit :: proc(e: ^Engine, fixes: ^[dynamic]Reg_Fix, notes: ^[dynamic]string) -> Error {
	lens := make(map[prim.Id]i64, 64, context.temp_allocator)
	own_len :: proc(e: ^Engine, lens: ^map[prim.Id]i64, id: prim.Id, kind: Kind) -> (n: i64, err: Error) {
		if x, ok := lens[id]; ok {
			return x, .None
		}
		n = _own_stream_len(e, id, kind) or_return
		lens[id] = n
		return n, .None
	}
	objects := _reg_collect(e, ROOT_OBJECTS) or_return
	for &f in objects {
		if f.klen != 16 {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[:16])
		rec, derr := _rec_decode(f.value, context.temp_allocator)
		if derr != .None || !rec.own {
			continue
		}
		keyed := _own_keyed(e, id) or_return
		if keyed {
			if !_owns_segment(rec.kind) {
				continue
			}
			n := own_len(e, &lens, id, rec.kind) or_return
			if n > 0 {
				continue
			}
		}
		if notes != nil {
			what := "own segment" if keyed else "own key tree"
			append(notes, fmt.tprintf("registry: %v %s is marked own but its %s is absent", rec.kind, prim.id_hex(id), what))
		}
		if fixes != nil {
			rec.own = false
			v := _rec_encode(&rec, context.temp_allocator) or_return
			append(fixes, Reg_Fix{root = ROOT_OBJECTS, key = f.key, klen = 16, value = v})
		}
	}
	owned := _reg_collect(e, ROOT_OWNED) or_return
	for &f in owned {
		if f.klen != 32 && f.klen != 33 {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[16:32])
		if f.klen == 32 {
			if len(f.value) < 1 || f.value[0] < 1 || f.value[0] > u8(max(Kind)) {
				continue
			}
			kind := Kind(f.value[0])
			n := own_len(e, &lens, id, kind) or_return
			keyed := _own_keyed(e, id) or_return
			if !keyed || (_owns_segment(kind) && n == 0) {
				if notes != nil {
					what := "own segment" if keyed else "own key tree"
					append(notes, fmt.tprintf("registry: owned %v %s has no %s", kind, prim.id_hex(id), what))
				}
				if fixes != nil {
					append(fixes, Reg_Fix{root = ROOT_OWNED, key = f.key, klen = 32, del = true})
				}
				continue
			}
			if len(f.value) != 9 && len(f.value) != 17 {
				continue
			}
			mark := i64(min(prim.get_u64le(f.value[1:9]), u64(max(i64))))
			target := i64(-1)
			if len(f.value) == 17 {
				target = i64(min(prim.get_u64le(f.value[9:17]), u64(max(i64))))
			}
			if mark <= n && target <= n {
				continue
			}
			if notes != nil {
				append(notes, fmt.tprintf("registry: content mark %d/%d of %v %s is past its own stream's %d bytes", mark, target, kind, prim.id_hex(id), n))
			}
			if fixes != nil {
				v := make([]u8, 9, context.temp_allocator)
				v[0] = f.value[0]
				prim.put_u64le(v[1:], u64(min(mark, n)))
				append(fixes, Reg_Fix{root = ROOT_OWNED, key = f.key, klen = 32, value = v})
			}
		} else if f.key[32] == 'p' && len(f.value) == 8 {
			kind, ok := _reg_kind(e, id)
			if !ok {
				continue
			}
			n := own_len(e, &lens, id, kind) or_return
			from := i64(min(prim.get_u64le(f.value), u64(max(i64))))
			if from <= n {
				continue
			}
			if notes != nil {
				append(notes, fmt.tprintf("registry: promotion of %v %s resumes at %d past its own stream's %d bytes", kind, prim.id_hex(id), from, n))
			}
			if fixes != nil {
				v := make([]u8, 8, context.temp_allocator)
				prim.put_u64le(v, u64(n))
				append(fixes, Reg_Fix{root = ROOT_OWNED, key = f.key, klen = 33, value = v})
			}
		}
	}
	ckpts := _reg_collect(e, ROOT_CKPT) or_return
	for &f in ckpts {
		if f.klen != 16 || len(f.value) != 40 {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[:16])
		length := i64(prim.get_u64le(f.value[:8]))
		if length <= 0 {
			continue
		}
		kind, ok := _reg_kind(e, id)
		if !ok {
			continue
		}
		n := own_len(e, &lens, id, kind) or_return
		if length <= n {
			continue
		}
		if notes != nil {
			append(notes, fmt.tprintf("registry: checkpoint of %v %s covers %d bytes past its own stream's %d", kind, prim.id_hex(id), length, n))
		}
		if fixes != nil {
			append(fixes, Reg_Fix{root = ROOT_CKPT, key = f.key, klen = 16, del = true})
		}
	}
	return .None
}

@(private)
_registry_recover :: proc(e: ^Engine) -> Error {
	if !pack.unclean(&e.pk) {
		return .None
	}
	fixes := make([dynamic]Reg_Fix, context.temp_allocator)
	_reg_audit(e, &fixes, nil) or_return
	if len(fixes) == 0 {
		return .None
	}
	t := _oerr2_txn(omap.txn_begin(&e.reg.db)) or_return
	for &f in fixes {
		err: omap.Error
		if f.del {
			_, err = omap.txn_delete(t, f.root, f.key[:f.klen])
		} else {
			err = omap.txn_put(t, f.root, f.key[:f.klen], f.value)
		}
		if err != .None {
			omap.txn_abort(t)
			return _oerr(err)
		}
	}
	_oerr(omap.txn_commit(t)) or_return
	e.reg.meta = true
	return .None
}

@(private)
_oerr2_txn :: proc(t: ^omap.Txn, err: omap.Error) -> (^omap.Txn, Error) {
	return t, _oerr(err)
}

verify_derived :: proc(e: ^Engine, allocator := context.allocator) -> (notes: []string, err: Error) {
	context = context_for(e)
	out := make([dynamic]string, context.temp_allocator)
	_reg_audit(e, nil, &out) or_return
	objects := _reg_collect(e, ROOT_OBJECTS) or_return
	for &f in objects {
		if f.klen != 16 {
			continue
		}
		rec, derr := _rec_decode(f.value, context.temp_allocator)
		if derr != .None {
			continue
		}
		id: prim.Id
		copy(id[:], f.key[:16])
		if _, serr := _space_open(e, rec.space); serr != .None {
			continue
		}
		#partial switch rec.kind {
		case .Conversation:
			if !rec.own {
				continue
			}
			if verr := _convo_verify(e, Object{rec.space, id}, &out); verr != .None && verr != .Missing && verr != .Not_Found && verr != .Permission {
				return nil, verr
			}
		case .Text, .File_Tree:
			if verr := _hist_verify(e, Object{rec.space, id}, rec.kind, &out); verr != .None && verr != .Missing && verr != .Not_Found && verr != .Permission {
				return nil, verr
			}
		case .Map:
			if verr := _map_verify(e, Object{rec.space, id}, &out); verr != .None && verr != .Missing && verr != .Not_Found && verr != .Permission {
				return nil, verr
			}
		}
	}
	res := make([]string, len(out), allocator)
	for s, i in out {
		res[i] = _clone(s, allocator) or_return
	}
	return res, .None
}

@(private)
Kv_Pair :: struct {
	key:   []u8,
	value: []u8,
}

@(private)
_db_pairs :: proc(db: ^omap.Db, root: int) -> (out: [dynamic]Kv_Pair, err: Error) {
	out = make([dynamic]Kv_Pair, context.temp_allocator)
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		k := make([]u8, len(key), context.temp_allocator)
		copy(k, key)
		v := make([]u8, len(value), context.temp_allocator)
		copy(v, value)
		append((^[dynamic]Kv_Pair)(data), Kv_Pair{k, v})
		return true
	}
	_oerr(omap.db_scan(db, root, nil, nil, &out, visit)) or_return
	return out, .None
}

@(private)
_pairs_diff :: proc(a, b: []Kv_Pair) -> (key: []u8, differ: bool) {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if string(a[i].key) != string(b[i].key) || string(a[i].value) != string(b[i].value) {
			return a[i].key if string(a[i].key) <= string(b[i].key) else b[i].key, true
		}
	}
	if len(a) != len(b) {
		return a[n].key if len(a) > n else b[n].key, true
	}
	return nil, false
}

@(private)
_map_verify :: proc(e: ^Engine, o: Object, notes: ^[dynamic]string) -> Error {
	h := _handle_get(e, o, .Map) or_return
	merr := _map_sync(e, h)
	if merr != .None && merr != .Missing {
		return merr
	}
	srcs := make([dynamic]omap.Source, context.temp_allocator)
	if h.w_open {
		c, cerr := omap.table_consumed(&h.table, e.self)
		_oerr(cerr) or_return
		append(&srcs, omap.Source{e.self, &h.mw.core.jr, c})
	}
	for s in h.segs {
		c, cerr := omap.table_consumed(&h.table, s.device)
		_oerr(cerr) or_return
		append(&srcs, omap.Source{s.device, &s.jr, c})
	}
	cons := _db_pairs(&h.table.db, omap.ROOT_CONSUMED) or_return
	for c in cons {
		known := false
		for x in srcs {
			x := x
			if string(c.key) == string(x.seg[:]) {
				known = true
			}
		}
		if !known {
			append(notes, fmt.tprintf("map table %s consumed %x from segment %x it has no source for", prim.id_hex(o.id), c.value, c.key))
		}
	}
	dir := _join(context.temp_allocator, e.pack_root, "verify") or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	hx := prim.id_hex(o.id)
	path := _join(context.temp_allocator, dir, string(hx[:])) or_return
	prim.remove(e.vfs, path)
	t: omap.Table
	if o.id == h.sp.catalog {
		defs := omap.catalog_defs()
		_oerr(omap.table_open(&t, e.vfs, path, defs[:], e.allocator)) or_return
	} else {
		_oerr(omap.table_open(&t, e.vfs, path, nil, e.allocator)) or_return
	}
	defer {
		omap.table_close(&t)
		prim.remove(e.vfs, path)
	}
	_oerr(omap.table_rebuild(&t, srcs[:])) or_return
	roots := make([dynamic]int, context.temp_allocator)
	append(&roots, omap.ROOT_ENTRIES, omap.ROOT_PENDING)
	for i in 0 ..< h.table.ndefs {
		append(&roots, omap.ROOT_INDEX + i)
	}
	for r in roots {
		have := _db_pairs(&h.table.db, r) or_return
		want := _db_pairs(&t.db, r) or_return
		if k, differ := _pairs_diff(have[:], want[:]); differ {
			why := fmt.tprintf("map table %s root %d differs from a rebuild of its sources (%d vs %d rows, first at key %x)", prim.id_hex(o.id), r, len(have), len(want), k)
			for src in srcs {
				c, _ := omap.table_consumed(&h.table, src.seg)
				w, _ := omap.table_consumed(&t, src.seg)
				why = fmt.tprintf("%s; source %s consumed %d rebuilt %d end %d", why, prim.id_hex(src.seg), c, w, omap.durable_end(src.reader))
			}
			for x in have {
				if string(x.key) == string(k) {
					why = fmt.tprintf("%s; have %x", why, x.value)
				}
			}
			for x in want {
				if string(x.key) == string(k) {
					why = fmt.tprintf("%s; want %x", why, x.value)
				}
			}
			append(notes, why)
		}
	}
	return .None
}

@(private)
_convo_verify :: proc(e: ^Engine, o: Object, notes: ^[dynamic]string) -> Error {
	h := _handle_get(e, o, .Conversation) or_return
	if !h.w_open {
		return .None
	}
	problem := _oerr2_str(convo.writer_children_verify(&h.cw, context.temp_allocator)) or_return
	if len(problem) > 0 {
		append(notes, fmt.tprintf("conversation %s: %s", prim.id_hex(o.id), problem))
	}
	return .None
}

@(private)
_oerr2_str :: proc(s: string, err: obj.Error) -> (string, Error) {
	return s, _oerr(err)
}

@(private)
_tree_digest :: proc(hist: ^fs.History, out: ^strings.Builder) -> Error {
	snap := fstree.current(&hist.tree)
	walk :: proc(hist: ^fs.History, snap: ^fstree.Snapshot, dir: fstree.Inode_Id, prefix: string, out: ^strings.Builder) -> Error {
		kids, cerr := fstree.children(snap, dir, nil, 0, context.temp_allocator)
		if cerr != nil {
			return .Corrupt
		}
		for k in kids {
			p := fmt.tprintf("%s/%s", prefix, k.name)
			if k.kind == .Dir {
				fmt.sbprintf(out, "%s/\n", p)
				walk(hist, snap, k.inode, p, out) or_return
				continue
			}
			f := _ferr2(fs.history_file(hist, k.inode)) or_return
			fmt.sbprintf(out, "%s %v %x\n", p, k.kind, crdt.text_bytes(&f.text, context.temp_allocator))
		}
		return .None
	}
	return walk(hist, &snap, fstree.ROOT, "", out)
}

@(private)
_hist_verify :: proc(e: ^Engine, o: Object, kind: Kind, notes: ^[dynamic]string) -> Error {
	h := _handle_get(e, o, kind) or_return
	_hist_ready(e, h) or_return
	hist := h.hist
	if kept := _ferr2(fs.history_interning_kept(hist)) or_return; !kept {
		append(notes, fmt.tprintf("history %s: actor interning order differs from the order saved before its rebuild", prim.id_hex(o.id)))
	}
	if ahead := _ferr2(fs.history_derived_ahead(hist)) or_return; ahead {
		append(notes, fmt.tprintf("history %s: state or lv.idx is ahead of its own journal after open", prim.id_hex(o.id)))
		return .None
	}
	src := hist.dir
	vdir := _join(context.temp_allocator, e.pack_root, "verify") or_return
	hx := prim.id_hex(o.id)
	scratch := _join(context.temp_allocator, vdir, string(hx[:])) or_return
	_perr(prim.mkdir_all(e.vfs, scratch, 0o700)) or_return
	names := []string{"fs.journal", "fs.journal.redact"}
	for n in names {
		from := _join(context.temp_allocator, src, n) or_return
		to := _join(context.temp_allocator, scratch, n) or_return
		prim.remove(e.vfs, to)
		if !prim.exists(e.vfs, from) {
			continue
		}
		data := _perr2(prim.read_file(e.vfs, from, context.temp_allocator)) or_return
		if n == "fs.journal" {
			data = data[:min(i64(len(data)), journal.journal_durable_len(&hist.journal))]
		}
		_perr(prim.replace_atomic(e.vfs, to, data)) or_return
	}
	defer {
		d := prim.Dir{}
		if prim.dir_open(e.vfs, &d, scratch, context.temp_allocator) == .None {
			for {
				ent, more, derr := prim.dir_next(e.vfs, &d)
				if derr != .None || !more {
					break
				}
				if p, jerr := _join(context.temp_allocator, scratch, ent.name); jerr == .None {
					prim.remove(e.vfs, p)
				}
			}
			prim.dir_close(e.vfs, &d)
		}
		prim.remove_dir(e.vfs, scratch)
	}
	db := device_odb(e) or_return
	opts := _hist_options(h)
	opts.keep_at_least = 0
	re := _ferr2(fs.history_create(e.vfs, scratch, o.id, e.self, db, fs.Stream_Source{data = h, read = _hist_read}, e.allocator, opts)) or_return
	defer fs.history_release(re)
	limits := make(map[prim.Id]i64, 8, context.temp_allocator)
	for id, i in hist.stream_ids {
		if i > 0 && i < len(hist.applied) {
			limits[id] = hist.applied[i]
		}
	}
	positions := make(map[prim.Id]i64, 8, context.temp_allocator)
	for {
		progress := false
		for s in h.segs {
			limit := limits[s.device]
			pos := positions[s.device]
			for pos < limit {
				body, next, rerr := journal.record_at(&s.jr, pos)
				if rerr == .Redacted {
					return .None
				}
				if rerr != .None {
					return .None
				}
				if !journal.is_sig(body) {
					owned := make([]u8, len(body), context.temp_allocator)
					copy(owned, body)
					if _, aerr := fs.history_admit(re, s.device, pos, owned); aerr == .Not_Found {
						break
					} else if aerr != .None {
						return .None
					}
				}
				pos = next
				progress = true
			}
			positions[s.device] = pos
		}
		if !progress {
			break
		}
	}
	for id, limit in limits {
		if positions[id] < limit {
			return .None
		}
	}
	have := strings.builder_make(context.temp_allocator)
	want := strings.builder_make(context.temp_allocator)
	_tree_digest(hist, &have) or_return
	_tree_digest(re, &want) or_return
	if strings.to_string(have) != strings.to_string(want) {
		append(notes, fmt.tprintf("history %s differs from a rebuild of its journal and streams (applied %v/%v streams %v/%v journal %d/%d heads %v/%v dir %s):\n--- have\n%s--- rebuilt\n%s", prim.id_hex(o.id), hist.applied[:], re.applied[:], len(hist.stream_ids), len(re.stream_ids), journal.journal_durable_len(&hist.journal), journal.journal_durable_len(&re.journal), fs.history_heads(hist, context.temp_allocator), fs.history_heads(re, context.temp_allocator), src, strings.to_string(have), strings.to_string(want)))
	}
	return .None
}

@(private)
_perr2 :: proc(v: $T, err: prim.Error) -> (T, Error) {
	return v, _perr(err)
}

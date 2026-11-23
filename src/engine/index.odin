package engine

import "core:crypto/blake2b"
import "core:mem/virtual"
import "core:slice"
import "core:unicode/utf8"
import "../convo"
import "../crdt"
import "../fs"
import "../fstree"
import "../journal"
import omap "../map"
import "../obj"
import "../prim"
import "../search"
import osync "../sync"

@(private)
SCAN_BUDGET :: 4096
@(private)
TEXT_INDEX_MAX :: 4 << 20
@(private)
TREE_LV_CHUNK :: 4096
@(private)
SEARCH_STEP_BUDGET :: i64(4 << 20)
@(private)
TREE_LV_SOURCE :: prim.Id{0x74, 0x72, 0x65, 0x65, 0x2d, 0x6c, 0x76, 0, 0, 0, 0, 0, 0, 0, 0, 1}
@(private)
KIND_NAMES := [5]string{"", "conversation", "map", "text", "tree"}

@(private)
Index_Item :: struct {
	space:  prim.Id,
	object: prim.Id,
	kind:   Kind,
}

search_query :: proc(e: ^Engine, query: string, req: search.Request, allocator := context.allocator) -> (res: search.Results, err: Error) {
	context = context_for(e)
	if !e.cfg.search {
		return res, .Unsupported
	}
	_index_open(e) or_return
	r, serr := search.search(&e.index, query, req, allocator)
	r.hits = _hit_gens(e, r.hits, {}, allocator)
	return r, _xerr(serr)
}

search_wrote :: proc(e: ^Engine, tree: prim.Id, path: string, unit: search.Unit, lo, hi: u64, allocator := context.allocator) -> (hits: []search.Wrote_Hit, err: Error) {
	context = context_for(e)
	if !e.cfg.search {
		return nil, .Unsupported
	}
	_index_open(e) or_return
	key := _file_key(tree, path)
	h, werr := search.wrote(&e.index, key, unit, lo, hi, allocator)
	return h, _xerr(werr)
}

@(private)
_file_key :: proc(tree: prim.Id, path: string) -> []u8 {
	hx := prim.id_hex(tree)
	out := make([]u8, len(hx) + 1 + len(path), context.temp_allocator)
	copy(out, hx[:])
	out[len(hx)] = '/'
	copy(out[len(hx) + 1:], path)
	return out
}

@(private)
_index_open :: proc(e: ^Engine) -> Error {
	if e.index_open {
		return .None
	}
	dir := _join(context.temp_allocator, e.pack_root, "search") or_return
	_perr(prim.mkdir_all(e.vfs, dir, 0o700)) or_return
	opts := e.cfg.search_options
	opts.vfs = e.vfs
	opts.store_text = true
	opts.embedder = e.cfg.embedder
	opts.kind_names = KIND_NAMES[:]
	opts.budget = e.cfg.search_budget
	opts.durable = _index_durable
	opts.durable_data = e
	if opts.cache_pages == 0 {
		opts.cache_pages = 32
	}
	rebuilt, err := search.open(&e.index, dir, opts, e.allocator)
	if err != .None {
		return _xerr(err)
	}
	e.index_open = true
	if !rebuilt && _search_restore_interrupted(e) {
		search.reset(&e.index)
		rebuilt = true
	}
	if rebuilt {
		_index_all(e)
	}
	_search_drop_markers(e) or_return
	return .None
}

@(private)
_index_all :: proc(e: ^Engine) {
	visit :: proc(data: rawptr, key: []u8, value: []u8) -> bool {
		x := (^Engine)(data)
		if len(key) != 16 {
			return true
		}
		rec, err := _rec_decode(value, context.temp_allocator)
		if err != .None {
			return true
		}
		id: prim.Id
		copy(id[:], key)
		_index_item_add(x, rec.space, id, rec.kind)
		return true
	}
	for k, v in e.reg.staged {
		key := k
		visit(e, key[:], v)
	}
	omap.db_scan(&e.reg.db, ROOT_OBJECTS, nil, nil, e, visit)
	_touch(e)
}

@(private)
_index_close :: proc(e: ^Engine) -> bool {
	if !e.index_open {
		return true
	}
	if search.flush(&e.index) == .Busy && !e.closing {
		return false
	}
	search.close(&e.index)
	e.index_open = false
	return true
}

@(private)
_index_settle :: proc(e: ^Engine) {
	if e.index_open {
		more, merr := search.merge_step(&e.index, SEARCH_STEP_BUDGET)
		if merr == .None && more {
			if e.settle_timer == 0 {
				e.settle_timer = prim.timer(e.loop, 0, e, _on_settle)
			}
			return
		}
	}
	if !_index_close(e) && e.settle_timer == 0 {
		e.settle_timer = prim.timer(e.loop, e.cfg.settle_ms, e, _on_settle)
	}
}

@(private)
_ix_busy :: proc(e: ^Engine, err: search.Error) -> bool {
	if err == .Busy {
		e.index_busy = true
		return true
	}
	return false
}

@(private)
_index_durable :: proc(data: rawptr, source: prim.Id) -> i64 {
	return max(i64)
}

@(private)
_index_durable_advanced :: proc(e: ^Engine) {
	if e.index_open {
		search.durable_advanced(&e.index)
	}
}

@(private)
_tree_lv_source :: proc "contextless" (epoch: u64) -> prim.Id {
	id := TREE_LV_SOURCE
	prim.put_u64le(id[8:], prim.get_u64le(id[8:]) ~ epoch)
	return id
}

@(private)
_source_id :: proc(object: prim.Id, device: prim.Id) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	a, b := object, device
	blake2b.update(&ctx, a[:])
	blake2b.update(&ctx, b[:])
	blake2b.final(&ctx, id[:])
	return
}

@(private)
_rid_ref :: proc(r: Rid) -> (out: [24]u8) {
	return _pos_ref(r.seg, r.off)
}

@(private)
_pos_ref :: proc(seg: prim.Id, off: i64) -> (out: [24]u8) {
	s := seg
	copy(out[:16], s[:])
	prim.put_u64le(out[16:], u64(off))
	return
}

ref_rid :: proc "contextless" (ref: []u8) -> (r: Rid, ok: bool) {
	if len(ref) != 24 && len(ref) != 32 {
		return {}, false
	}
	copy(r.seg[:], ref[:16])
	r.off = i64(prim.get_u64le(ref[16:24]))
	if len(ref) == 32 {
		r.gen = prim.get_u64le(ref[24:32])
	}
	return r, r.off > 0
}

@(private)
_gen_ref :: proc(r: Rid, allocator := context.allocator) -> []u8 {
	out := make([]u8, 32, allocator)
	s := r.seg
	copy(out[:16], s[:])
	prim.put_u64le(out[16:24], u64(r.off))
	prim.put_u64le(out[24:32], r.gen)
	return out
}

@(private)
_hit_gens :: proc(e: ^Engine, hits: []search.Hit, space: prim.Id, allocator := context.allocator) -> []search.Hit {
	n := 0
	for h in hits {
		x := h
		sid, known := _hit_space(e, h.object)
		if !known || (!prim.id_is_zero(space) && sid != space) {
			continue
		}
		x.space = sid
		if len(h.ref) == 24 && h.kind == u8(Kind.Conversation) {
			pos, _ := ref_rid(h.ref)
			r, ok := _rid_in(e, h.object, .Conversation, pos.seg, pos.off)
			if !ok {
				continue
			}
			x.ref = _gen_ref(r, allocator)
		}
		hits[n] = x
		n += 1
	}
	return hits[:n]
}

@(private)
_hit_space :: proc(e: ^Engine, id: prim.Id) -> (space: prim.Id, ok: bool) {
	if rec, found, rerr := _rec_get(e, id); rerr == .None && found {
		return rec.space, true
	}
	for sid in _sorted_keys(e.spaces) {
		sp := e.spaces[sid]
		if sp.keyless {
			continue
		}
		ch, cerr := _catalog_handle(e, sp)
		if cerr != .None {
			continue
		}
		_map_sync(e, ch)
		if _, found, gerr := omap.catalog_get(&ch.table, id, context.temp_allocator); gerr == .None && found {
			return sid, true
		}
	}
	return {}, false
}

@(private)
_rid_in :: proc(e: ^Engine, id: prim.Id, kind: Kind, seg: prim.Id, off: i64) -> (r: Rid, ok: bool) {
	rec, found, rerr := _rec_get(e, id)
	if rerr != .None || !found {
		return
	}
	h, herr := _handle_get(e, Object{rec.space, id}, kind)
	if herr != .None {
		return
	}
	vs := obj.view_find(&h.view, seg)
	if vs < 0 {
		return
	}
	got, gerr := obj.rid(&h.view, obj.Vref{vs, off})
	return got, gerr == .None
}

@(private)
_index_step :: proc(e: ^Engine) {
	if len(e.index_dirty) == 0 {
		return
	}
	items := e.index_dirty
	e.index_dirty = make([dynamic]Index_Item, e.allocator)
	defer delete(items)
	budget := SCAN_BUDGET
	for it, i in items {
		if budget <= 0 {
			append(&e.index_dirty, ..items[i:])
			_touch(e)
			return
		}
		sp, ok := e.spaces[it.space]
		if !ok || !sp.open {
			continue
		}
		h, err := _handle_get(e, Object{it.space, it.object}, it.kind)
		if err != .None {
			continue
		}
		e.index_busy = false
		used, more := _scan_object(e, h, budget)
		budget -= used
		if e.index_busy {
			append(&e.index_dirty, ..items[i:])
			_touch(e)
			return
		}
		if more {
			append(&e.index_dirty, it)
			_touch(e)
		}
	}
}

@(private)
_scan_object :: proc(e: ^Engine, h: ^Handle, budget: int) -> (used: int, more: bool) {
	_handle_refresh(h)
	switch h.kind {
	case .Conversation, .Map:
		rec, found, rerr := _rec_get(e, h.id)
		if rerr != .None {
			return
		}
		dirty_rec := false
		for s in h.segs {
			if !s.in_view {
				continue
			}
			mi := _rec_member(&rec, s.device) if found else -1
			if mi < 0 {
				continue
			}
			vs := obj.view_find(&h.view, s.device)
			pos := rec.members[mi].scanned
			end := journal.reader_end(&s.jr)
			n := 0
			for pos < end && used < budget {
				body, next, je := journal.record_at(&s.jr, pos)
				if je == .Redacted {
					pos = next
					continue
				}
				if je == .Missing && h.sp.repl_on {
					if gap := s.jr.missing; gap.from < end {
						r := [1]journal.Range{{max(gap.from, pos), min(max(gap.to, gap.from + 1), end)}}
						osync.replicator_want(&h.sp.repl, &h.scope, s.device, h.name, 0, r[:])
					}
					if osync.replicator_relay_length(&h.sp.repl, &h.scope, s.device, h.name, 0) < 0 {
						osync.replicator_want_tail(&h.sp.repl, &h.scope, s.device, h.name, 0, 1)
					}
				}
				if je != .None {
					break
				}
				at := pos
				pos = next
				used += 1
				n += 1
				rk := obj.record_kind(body)
				if rk == obj.RECORD_REDACT {
					env, derr := obj.decode_envelope(body, at)
					if derr == .None && _apply_remote_redact(e, h, vs, &env) == .Missing {
						_handle_want(h)
						pos = at
						break
					}
				} else if h.kind == .Conversation && rk == u8(convo.Kind.Redact_Msg) {
					if _apply_remote_redact_msg(e, h, vs, body, at) == .Missing {
						_handle_want(h)
						pos = at
						break
					}
				} else if h.id == h.sp.catalog && rk == u8(omap.Kind.Put) {
					_full_catalog_record(e, h.sp, body, at)
				} else if h.id == h.sp.catalog && rk == u8(omap.Kind.Add) {
					env, derr := obj.decode_envelope(body, at)
					if derr == .None {
						if b, berr := omap.decode_body(&env, context.temp_allocator); berr == .None {
							if add, ok := b.(omap.Add); ok && add.tag == u32(omap.Catalog_Tag.Participants) {
								_catalog_participant_seen(e, h.sp, add.key, add.element)
							}
						}
					}
				}
			}
			if pos != rec.members[mi].scanned {
				rec.members[mi].scanned = pos
				dirty_rec = true
			}
			if pos < end && used >= budget {
				more = true
			}
		}
		if dirty_rec {
			_rec_put(e, h.id, &rec)
		}
		if e.cfg.search && _index_open(e) == .None {
			if r := _own_reader(h); r != nil {
				u, m := _index_segment(e, h, e.self, r, budget - used)
				used += u
				more ||= m
			}
			for s in h.segs {
				if s.in_view {
					u, m := _index_segment(e, h, s.device, &s.jr, budget - used)
					used += u
					more ||= m
				}
			}
		}
	case .Text:
		if e.cfg.search && _index_open(e) == .None {
			_index_text(e, h)
		}
		used += 1
	case .File_Tree:
		if e.cfg.search && _index_open(e) == .None {
			u, m := _index_tree(e, h, budget)
			used += u
			more ||= m
		}
	}
	return
}

@(private)
_index_scope :: proc(e: ^Engine, h: ^Handle, device: prim.Id, src: prim.Id, pos: i64, body: []u8, at: i64) {
	rec, derr := convo.decode_record(body, at, context.temp_allocator)
	if derr != .None {
		return
	}
	sc, ok := rec.body.(convo.Scope)
	if !ok {
		return
	}
	vs := obj.view_find(&h.view, device)
	if vs < 0 {
		return
	}
	vr, rerr := obj.resolve(&h.view, vs, sc.msg)
	if rerr != .None {
		return
	}
	ref := _pos_ref(h.view.segs[vr.seg].id, vr.off)
	search.add_scope(&e.index, src, pos, search.Scope{id = sc.actor, object = h.id, ref = ref[:], hlc = rec.stamp})
	if sc.id != sc.actor {
		search.add_scope(&e.index, src, pos, search.Scope{id = sc.id, object = h.id, ref = ref[:], hlc = rec.stamp})
	}
}

@(private)
_index_segment :: proc(e: ^Engine, h: ^Handle, device: prim.Id, r: ^journal.Reader, budget: int) -> (used: int, more: bool) {
	if budget <= 0 {
		return 0, true
	}
	src := _source_id(h.id, device)
	pos, perr := search.position(&e.index, src)
	if perr != .None {
		return
	}
	end := journal.reader_end(r)
	tail_ok := false
	t: convo.Tail
	for pos < end {
		if used >= budget {
			_ix_busy(e, search.advance(&e.index, src, pos))
			return used, true
		}
		body, next, je := journal.record_at(r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			break
		}
		at := pos
		pos = next
		used += 1
		k := obj.record_kind(body)
		if obj.is_sig(body) || k < obj.RECORD_KIND_FIRST {
			continue
		}
		if h.kind == .Conversation {
			if k == u8(convo.Kind.Scope) {
				_index_scope(e, h, device, src, pos, body, at)
				continue
			}
			if k != u8(convo.Kind.Seal) {
				continue
			}
			rec, derr := convo.decode_record(body, at, context.temp_allocator)
			if derr != .None {
				continue
			}
			seal, ok := rec.body.(convo.Seal)
			if !ok {
				continue
			}
			if !tail_ok {
				tt, terr := convo.view_tail(&h.view, e.self, context.temp_allocator)
				if terr != .None {
					return used, false
				}
				t = tt
				tail_ok = true
			}
			msg, rerr := obj.rid(&h.view, obj.Vref{obj.view_find(&h.view, device), seal.msg})
			if rerr != .None {
				continue
			}
			m, merr := convo.message(&h.view, &t, convo.Position{msg = msg}, context.temp_allocator)
			if merr != .None {
				continue
			}
			ref := _rid_ref(msg)
			for b in m.blocks {
				#partial switch b.kind {
				case .Text, .Reasoning, .Tool_Call, .Tool_Result, .Question, .Notice, .Error:
				case:
					continue
				}
				if len(b.text) == 0 || !utf8.valid_string(string(b.text)) {
					continue
				}
				doc := search.Doc {
					object      = h.id,
					ref         = ref[:],
					part        = b.index,
					kind        = u8(Kind.Conversation),
					participant = m.author,
					hlc         = m.hlc,
					text        = b.text,
					embed       = e.cfg.embedder.embed != nil && b.kind == .Text,
				}
				if _ix_busy(e, search.add(&e.index, src, at, &doc)) {
					return used, true
				}
			}
		} else {
			env, derr := obj.decode_envelope(body, at)
			if derr != .None {
				continue
			}
			b, berr := omap.decode_body(&env, context.temp_allocator)
			if berr != .None {
				continue
			}
			put, ok := b.(omap.Put)
			if !ok {
				continue
			}
			if h.id == h.sp.catalog {
				if id, iok := omap.value_id(put.key); iok {
					for f in put.fields {
						if f.tag == u32(omap.Catalog_Tag.Title) && utf8.valid_string(string(f.value)) {
							if _ix_busy(e, search.set_title(&e.index, src, at, id, device, f.hlc, u8(Kind.Conversation), string(f.value))) {
								return used, true
							}
						}
					}
				}
				continue
			}
			for f in put.fields {
				slot := make([]u8, len(put.key) + 4, context.temp_allocator)
				copy(slot, put.key)
				prim.put_u32le(slot[len(put.key):], f.tag)
				if len(f.value) == 0 || !utf8.valid_string(string(f.value)) {
					if _ix_busy(e, search.delete_slot(&e.index, src, at, h.id, slot)) {
						return used, true
					}
					continue
				}
				doc := search.Doc {
					object      = h.id,
					ref         = put.key,
					part        = f.tag,
					kind        = u8(Kind.Map),
					slot        = slot,
					participant = device,
					hlc         = f.hlc,
					text        = f.value,
				}
				if _ix_busy(e, search.add(&e.index, src, at, &doc)) {
					return used, true
				}
			}
		}
		e.stats.indexed += 1
	}
	if _ix_busy(e, search.advance(&e.index, src, pos)) {
		return used, true
	}
	return used, false
}

@(private)
_index_text :: proc(e: ^Engine, h: ^Handle) {
	if _hist_caught_up(e, h) != .None || h.hist == nil {
		return
	}
	inode, found, ierr := _text_inode(h)
	if ierr != .None || !found {
		return
	}
	f, ferr := fs.history_file(h.hist, inode)
	if ferr != .None {
		return
	}
	n := crdt.text_len(&f.text)
	if n > TEXT_INDEX_MAX {
		return
	}
	data := crdt.text_bytes(&f.text, context.temp_allocator)
	if !utf8.valid_string(string(data)) {
		return
	}
	src := _source_id(h.id, e.self)
	slot := transmute([]u8)string("text")
	doc := search.Doc {
		object      = h.id,
		ref         = slot,
		kind        = u8(Kind.Text),
		slot        = slot,
		participant = e.self,
		hlc         = hlc_now(e),
		text        = data,
		embed       = e.cfg.embedder.embed != nil,
	}
	_ix_busy(e, search.add(&e.index, src, _own_len(h), &doc))
}

@(private)
_index_tree :: proc(e: ^Engine, h: ^Handle, budget: int) -> (used: int, more: bool) {
	_hist_catch_up(e, h)
	if h.hist == nil || !h.hist.awake {
		return 0, false
	}
	src := _source_id(h.id, _tree_lv_source(fs.history_epoch(h.hist)))
	pos, perr := search.position(&e.index, src)
	if perr != .None {
		return 0, false
	}
	end := fs.history_lv_end(h.hist)
	if i64(end) <= pos {
		return 0, false
	}
	to := min(end, crdt.Lv(pos) + TREE_LV_CHUNK)
	if first, n, _, _, found := fs.history_batch_at(h.hist, to - 1); found {
		to = min(end, first + n)
	}
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	if fs.history_touched_between(h.hist, crdt.Lv(pos), to, &touched) != .None {
		return 1, false
	}
	ids := make([dynamic]fstree.Inode_Id, 0, len(touched), context.temp_allocator)
	for id in touched {
		append(&ids, id)
	}
	slice.sort_by(ids[:], proc(a, b: fstree.Inode_Id) -> bool {
		return a.actor < b.actor || a.actor == b.actor && a.seq < b.seq
	})
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return 1, false
	}
	defer virtual.arena_destroy(&scratch)
	sa := virtual.arena_allocator(&scratch)
	snap := fstree.current(&h.hist.tree)
	fs.history_scan_begin(h.hist)
	defer fs.history_scan_end(h.hist)
	for id in ids {
		defer virtual.arena_free_all(&scratch)
		used += 1
		path, ok, lerr := fstree.path(&snap, id, sa)
		if lerr != nil || !ok {
			continue
		}
		had := fs.history_file_loaded(h.hist, id)
		f, ferr := fs.history_file(h.hist, id)
		if ferr != .None {
			continue
		}
		defer if !had {
			fs.history_file_release(h.hist, id)
		}
		data := crdt.text_bytes(&f.text, sa)
		spans := crdt.text_spans(&f.text, &h.hist.g, sa)
		out := make([dynamic]search.Span, sa)
		at := 0
		line: u32 = 1
		for s in spans {
			lo := at
			hi := min(at + s.len, len(data))
			l0 := line
			for i in lo ..< hi {
				if data[i] == '\n' {
					line += 1
				}
			}
			append(&out, search.Span{byte_lo = u64(lo), byte_hi = u64(hi), line_lo = l0, line_hi = line, scope = s.id.actor})
			at = hi
		}
		if _ix_busy(e, search.set_spans(&e.index, src, pos, _file_key(h.id, path), out[:])) {
			return used, true
		}
	}
	if _ix_busy(e, search.advance(&e.index, src, i64(to))) {
		return used, true
	}
	return max(used, 1), to < end
}

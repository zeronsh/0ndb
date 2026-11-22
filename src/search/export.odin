package search

import "base:runtime"
import "core:slice"
import "../prim"

Export_Keep :: #type proc(data: rawptr, object: prim.Id, kind: u8, title: bool) -> bool

Export_Source :: #type proc(data: rawptr, object: prim.Id, device: prim.Id, pos: i64)

KIND_SOURCE :: u8(0xff)

Export :: struct {
	sx:   Index,
	open: bool,
	docs: int,
	text: u64,
}

Import_Result :: struct {
	first: u64,
	next:  u64,
	docs:  int,
	text:  u64,
}

@(private)
IMPORT_GEN :: max(u64) - 1

@(private)
Group :: struct {
	open:        bool,
	live:        bool,
	object:      prim.Id,
	participant: prim.Id,
	ref:         [MAX_REF]u8,
	ref_len:     int,
	part:        u32,
	kind:        u8,
	flags:       u8,
	hlc:         u64,
	fields:      [dynamic]Field,
	text:        [dynamic]u8,
}

@(private)
Walk :: struct {
	ix:        ^Index,
	dead:      []u32,
	blk:       Doc_Block,
	frame:     [dynamic]u8,
	fscratch:  [dynamic]u8,
	frame_at:  i64,
	frame_gen: u64,
	want_text: bool,
	keep:      Export_Keep,
	keep_data: rawptr,
	g:         Group,
	emit:      proc(w: ^Walk) -> Error,
	data:      rawptr,
	limit:     u64,
	taken:     u64,
	count:     int,
	stopped:   bool,
	stop:      u64,
	a:         runtime.Allocator,
}

next_doc :: proc "contextless" (ix: ^Index) -> u64 {
	return ix.mem.base + u64(len(ix.mem.docs))
}

text_total :: proc "contextless" (ix: ^Index) -> u64 {
	return ix.man.total_len + ix.mem.total_len
}

kill_range :: proc(ix: ^Index, lo, hi: u64) {
	ix.taint_check = true
	for d := lo; d < hi && d < MAX_DOCS; d += 1 {
		mem_kill(&ix.mem, u32(d))
	}
}

@(private)
_put :: proc(ix: ^Index, doc: ^Doc) -> Error {
	_admit(ix) or_return
	if len(doc.slot) > 0 {
		_kill_slot(ix, doc.object, doc.slot) or_return
	}
	id := mem_add(ix, doc) or_return
	if len(doc.slot) > 0 {
		key: [MAX_KEY]u8
		n := slot_key(doc.object, doc.slot, &key)
		if v, found := &ix.mem.slots[string(key[:n])]; found {
			v^ = id
		} else {
			k := make([]u8, n, ix.mem.allocator)
			copy(k, key[:n])
			ix.mem.slots[string(k)] = id
		}
	}
	return .None
}

@(private)
_walk_init :: proc(w: ^Walk, ix: ^Index, a: runtime.Allocator) {
	w.ix = ix
	w.a = a
	w.frame_at = -1
	db_init(&w.blk, a)
	w.frame = make([dynamic]u8, a)
	w.fscratch = make([dynamic]u8, a)
	w.g.fields = make([dynamic]Field, a)
	w.g.text = make([dynamic]u8, a)
}

@(private)
_walk_close :: proc(w: ^Walk) -> Error {
	if !w.g.open {
		return .None
	}
	w.g.open = false
	if !w.g.live {
		return .None
	}
	w.count += 1
	w.taken += u64(len(w.g.text))
	if w.emit != nil {
		return w.emit(w)
	}
	return .None
}

@(private)
_walk_doc :: proc(w: ^Walk, dm: ^Doc_Meta, dead: bool, s: ^Seg) -> Error {
	g := &w.g
	cont := g.open && dm.flags & DF_CHUNK != 0 && dm.chunk > 0 && dm.object == g.object && dm.part == g.part && string(dm.ref) == string(g.ref[:g.ref_len])
	if !cont {
		_walk_close(w) or_return
		if w.limit > 0 && w.taken >= w.limit {
			w.stopped = true
			w.stop = u64(dm.id)
			return .None
		}
		g.open = true
		g.live = !dead && dm.flags & DF_DELETED == 0 && !(dm.flags & DF_CHUNK != 0 && dm.chunk > 0)
		if g.live && dm.flags & DF_SLOT != 0 && dm.flags & DF_TITLE == 0 {
			g.live = false
		}
		if g.live && w.keep != nil && dm.kind != KIND_SOURCE && !w.keep(w.keep_data, dm.object, dm.kind, dm.flags & DF_TITLE != 0) {
			g.live = false
		}
		g.object = dm.object
		g.participant = dm.participant
		g.ref_len = copy(g.ref[:], dm.ref)
		g.part = dm.part
		g.kind = dm.kind
		g.flags = dm.flags
		g.hlc = dm.hlc
		clear(&g.fields)
		clear(&g.text)
		if g.live && w.want_text {
			for f in dm.fields {
				append(&g.fields, Field{name = _clone_str(string(f.name), w.a), value = _clone_str(string(f.value), w.a)})
			}
		}
	} else if dead || dm.flags & DF_DELETED != 0 {
		g.live = false
	}
	if !g.live || !w.want_text {
		return .None
	}
	if dm.flags & DF_TEXT == 0 {
		g.live = false
		return .None
	}
	text: []u8
	if s == nil {
		m := &w.ix.mem
		if int(dm.frame) >= len(m.frames) {
			return .Corrupt
		}
		at := int(m.frames[dm.frame]) + int(dm.frame_off)
		if at + int(dm.len) > len(m.raw) {
			return .Corrupt
		}
		text = m.raw[at:][:dm.len]
	} else {
		if w.frame_at != dm.frame || w.frame_gen != s.gen {
			w.frame_at = -1
			frame_read(w.ix, s, dm.frame, &w.frame, &w.fscratch) or_return
			w.frame_at = dm.frame
			w.frame_gen = s.gen
		}
		if int(dm.frame_off) + int(dm.len) > len(w.frame) {
			return .Corrupt
		}
		text = w.frame[dm.frame_off:][:dm.len]
	}
	have := u64(len(g.text))
	if dm.chunk > have {
		g.live = false
		return .None
	}
	skip := have - dm.chunk
	if skip < u64(len(text)) {
		append(&g.text, ..text[skip:])
	}
	return .None
}

@(private)
_walk_seg :: proc(w: ^Walk, s: ^Seg, lo, hi: u64) -> Error {
	a := max(lo, s.f.lo)
	b := min(hi, s.f.hi)
	for d := a; d < b && !w.stopped; d += 1 {
		doc_load(&w.ix.cache, s, &w.blk, d / DOC_BLOCK) or_return
		dm := &w.blk.docs[u32(d) - w.blk.first]
		_, dead := slice.binary_search(w.dead, u32(d))
		_walk_doc(w, dm, dead, s) or_return
	}
	return .None
}

@(private)
_walk_mem :: proc(w: ^Walk, lo, hi: u64) -> Error {
	m := &w.ix.mem
	a := max(lo, m.base)
	b := min(hi, m.base + u64(len(m.docs)))
	fields := make([dynamic]Field_Bytes, w.a)
	for d := a; d < b && !w.stopped; d += 1 {
		md := &m.docs[d - m.base]
		clear(&fields)
		for f in 0 ..< int(md.nfields) {
			fi := m.fidx[int(md.fields_off) + f]
			append(&fields, Field_Bytes{m.strs[fi[0]], m.strs[fi[1]]})
		}
		dm := Doc_Meta {
			id          = u32(d),
			flags       = md.flags,
			kind        = md.kind,
			object      = m.ids[md.object],
			participant = m.ids[md.part_id],
			hlc         = md.hlc,
			ref         = m.refs[md.ref_off:][:md.ref_len],
			part        = md.part,
			chunk       = md.chunk,
			len         = md.len,
			fields      = fields[:],
			frame       = i64(md.frame),
			frame_off   = md.frame_off,
		}
		_, dead := slice.binary_search(w.dead, u32(d))
		_walk_doc(w, &dm, dead, nil) or_return
	}
	return .None
}

@(private)
_walk_index :: proc(w: ^Walk, lo, hi: u64) -> Error {
	ix := w.ix
	w.dead = _dead_sorted(ix, w.a) or_return
	for &s in ix.segs {
		if w.stopped {
			return .None
		}
		if s.f.hi <= lo || s.f.lo >= hi {
			continue
		}
		_walk_seg(w, &s, lo, hi) or_return
	}
	if w.stopped {
		return .None
	}
	_walk_mem(w, lo, hi) or_return
	if w.stopped {
		return .None
	}
	return _walk_close(w)
}

@(private)
_walk_group_doc :: proc(w: ^Walk) -> Doc {
	g := &w.g
	d := Doc {
		object      = g.object,
		ref         = g.ref[:g.ref_len],
		part        = g.part,
		kind        = g.kind,
		title       = g.flags & DF_TITLE != 0,
		fields      = g.fields[:],
		participant = g.participant,
		hlc         = prim.Hlc(g.hlc),
		text        = g.text[:],
		embed       = g.flags & DF_EMBED != 0,
	}
	if d.title {
		d.slot = transmute([]u8)string(TITLE_SLOT)
	}
	return d
}

@(private)
_walk_arena :: proc(arena: ^runtime.Arena) -> (runtime.Allocator, Error) {
	if runtime.arena_init(arena, 256 * 1024, context.allocator) != nil {
		return {}, .No_Memory
	}
	return runtime.arena_allocator(arena), .None
}

export_count :: proc(ix: ^Index, lo, hi: u64, keep: Export_Keep, data: rawptr) -> (live: int, err: Error) {
	arena: runtime.Arena
	a := _walk_arena(&arena) or_return
	defer runtime.arena_destroy(&arena)
	w: Walk
	_walk_init(&w, ix, a)
	w.keep = keep
	w.keep_data = data
	_walk_index(&w, lo, hi) or_return
	return w.count, .None
}

export_begin :: proc(x: ^Export, vfs: prim.Vfs, dir: string, allocator := context.allocator) -> Error {
	x^ = {}
	opts := Options {
		vfs             = vfs,
		store_text      = true,
		budget          = max(int) / 8,
		cache_pages     = 8,
		train_min       = max(int),
		dict_sample_min = max(int),
	}
	_export_clean(vfs, dir)
	if _, err := open(&x.sx, dir, opts, allocator); err != .None {
		return err
	}
	x.sx.bare = true
	x.open = true
	return .None
}

export_range :: proc(x: ^Export, ix: ^Index, lo, hi: u64, limit: u64, keep: Export_Keep, data: rawptr) -> (stop: u64, err: Error) {
	arena: runtime.Arena
	a := _walk_arena(&arena) or_return
	defer runtime.arena_destroy(&arena)
	w: Walk
	_walk_init(&w, ix, a)
	w.want_text = true
	w.keep = keep
	w.keep_data = data
	w.data = x
	w.limit = limit
	w.emit = proc(w: ^Walk) -> Error {
		x := (^Export)(w.data)
		d := _walk_group_doc(w)
		_put(&x.sx, &d) or_return
		x.docs += 1
		x.text += u64(len(d.text))
		return .None
	}
	_walk_index(&w, lo, hi) or_return
	if w.stopped {
		return w.stop, .None
	}
	return hi, .None
}

export_source :: proc(x: ^Export, object: prim.Id, device: prim.Id, pos: i64) -> Error {
	if !x.open || pos < 0 {
		return .Invalid
	}
	d := Doc {
		object      = object,
		participant = device,
		kind        = KIND_SOURCE,
		hlc         = prim.Hlc(pos),
	}
	_, err := mem_add(&x.sx, &d)
	return err
}

export_finish :: proc(x: ^Export, buf: ^Name_Buf) -> (path: string, err: Error) {
	if !x.open {
		return "", .Invalid
	}
	before := len(x.sx.segs)
	mem_flush(&x.sx) or_return
	if len(x.sx.segs) != before + 1 {
		return "", .Not_Found
	}
	return seg_path(&x.sx, x.sx.segs[len(x.sx.segs) - 1].gen, buf), .None
}

export_end :: proc(x: ^Export) {
	if !x.open {
		return
	}
	dir := _clone_str(x.sx.dir, context.temp_allocator)
	vfs := x.sx.vfs
	close(&x.sx)
	x.open = false
	_export_clean(vfs, dir)
}

@(private)
_export_clean :: proc(vfs: prim.Vfs, dir: string) {
	tmp: Index
	tmp.vfs = vfs
	tmp.dir = dir
	buf: Name_Buf
	for n in ([?]string{"MANIFEST", "MANIFEST.tmp", "LOCK", "flush.tmp", "merge.tmp", "graph.tmp", "vt-flush.tmp", "vs-flush.tmp", "vt-merge.tmp", "vs-merge.tmp"}) {
		_ = prim.remove(vfs, file_path(&tmp, n, &buf))
	}
	for g in u64(0) ..< 4 {
		_ = prim.remove(vfs, seg_path(&tmp, g, &buf))
	}
	_ = prim.remove_dir(vfs, dir)
}

import_segment :: proc(ix: ^Index, path: string, keep: Export_Keep, on_source: Export_Source, data: rawptr) -> (res: Import_Result, err: Error) {
	s: Seg
	seg_open(&s, ix.vfs, path, IMPORT_GEN) or_return
	defer {
		seg_close(&s)
		cache_drop(&ix.cache, IMPORT_GEN)
	}
	if !s.f.store || s.f.zd_gen != 0 || s.f.hi < s.f.lo || s.f.hi - s.f.lo > MAX_DOCS {
		return res, .Corrupt
	}
	arena: runtime.Arena
	a := _walk_arena(&arena) or_return
	defer runtime.arena_destroy(&arena)
	Ctx :: struct {
		res:       ^Import_Result,
		on_source: Export_Source,
		data:      rawptr,
	}
	ctx := Ctx{&res, on_source, data}
	w: Walk
	_walk_init(&w, ix, a)
	w.want_text = true
	w.keep = keep
	w.keep_data = data
	w.data = &ctx
	dead := make([dynamic]u32, a)
	tomb_load(&s, &dead) or_return
	slice.sort(dead[:])
	w.dead = dead[:]
	w.emit = proc(w: ^Walk) -> Error {
		ctx := (^Ctx)(w.data)
		g := &w.g
		if g.kind == KIND_SOURCE {
			if ctx.on_source != nil {
				ctx.on_source(ctx.data, g.object, g.participant, i64(g.hlc))
			}
			return .None
		}
		d := _walk_group_doc(w)
		d.embed = d.embed && w.ix.opts.embedder.embed != nil && w.ix.opts.embedder.dim > 0
		err := _put(w.ix, &d)
		if err == .Missing && d.embed {
			d.embed = false
			err = _put(w.ix, &d)
		}
		if err != .None {
			return err
		}
		ctx.res.docs += 1
		ctx.res.text += u64(len(d.text))
		return _maybe_flush(w.ix)
	}
	res.first = next_doc(ix)
	_walk_seg(&w, &s, s.f.lo, s.f.hi) or_return
	_walk_close(&w) or_return
	res.next = next_doc(ix)
	return res, .None
}

has_content :: proc(ix: ^Index, object: prim.Id) -> (found: bool, err: Error) {
	m := &ix.mem
	if oi, ok := m.id_map[object]; ok {
		for d in m.docs {
			if d.object == oi && d.flags & (DF_TITLE | DF_DELETED) == 0 {
				return true, .None
			}
		}
	}
	key: [17]u8
	key[0] = NS_OBJECT
	o := object
	copy(key[1:], o[:])
	blk: Doc_Block
	db_init(&blk, context.temp_allocator)
	for &s in ix.segs {
		dix := dix_load(&ix.cache, &s, context.temp_allocator) or_return
		dc: Dict_Cursor
		dc_init(&dc, &ix.cache, &s, &dix, context.temp_allocator)
		t, hit := term_lookup(&dc, key[:]) or_return
		if !hit {
			continue
		}
		pl := new(Plist, context.temp_allocator)
		pl_init(pl, &ix.cache, &s, t)
		x := u32(max(u32))
		for {
			v, ok := pl_seek(pl, x)
			if !ok {
				break
			}
			doc_load(&ix.cache, &s, &blk, u64(v) / DOC_BLOCK) or_return
			if blk.docs[v - blk.first].flags & (DF_TITLE | DF_DELETED) == 0 {
				return true, .None
			}
			if v == 0 {
				break
			}
			x = v - 1
		}
		if pl.err != .None {
			return false, pl.err
		}
	}
	return false, .None
}

segment_sources :: proc(ix: ^Index, path: string, on_source: Export_Source, data: rawptr) -> Error {
	s: Seg
	seg_open(&s, ix.vfs, path, IMPORT_GEN) or_return
	defer {
		seg_close(&s)
		cache_drop(&ix.cache, IMPORT_GEN)
	}
	arena: runtime.Arena
	a := _walk_arena(&arena) or_return
	defer runtime.arena_destroy(&arena)
	Ctx :: struct {
		on_source: Export_Source,
		data:      rawptr,
	}
	ctx := Ctx{on_source, data}
	w: Walk
	_walk_init(&w, ix, a)
	w.data = &ctx
	w.emit = proc(w: ^Walk) -> Error {
		ctx := (^Ctx)(w.data)
		if w.g.kind == KIND_SOURCE {
			ctx.on_source(ctx.data, w.g.object, w.g.participant, i64(w.g.hlc))
		}
		return .None
	}
	_walk_seg(&w, &s, s.f.lo, s.f.hi) or_return
	return _walk_close(&w)
}

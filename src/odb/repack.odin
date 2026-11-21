package odb

import "core:c"
import "core:encoding/endian"
import hashing "core:hash"
import "core:io"
import "core:slice"
import "core:strings"
import "core:sync"
import zlib "vendor:zlib"
import "../prim"

Repack_Options :: struct {
	small_pack_bytes: i64,
	window:           int,
	depth:            int,
	level:            int,
	delta_max_size:   i64,
}

DEFAULT_REPACK :: Repack_Options {
	small_pack_bytes = 32 * 1024 * 1024,
	window           = 10,
	depth            = 50,
	level            = 6,
	delta_max_size   = 16 * 1024 * 1024,
}

Repack_Stats :: struct {
	objects:        int,
	deltas:         int,
	reused:         int,
	loose_removed:  int,
	packs_removed:  int,
	packed_dropped: int,
	loosened:       int,
	pinned_hits:    int,
	bytes_before:   i64,
	bytes_after:    i64,
}

@(private)
Repack_Object :: struct {
	oid:       Oid,
	type:      Object_Type,
	size:      i64,
	name_hash: u32,
	loose:     bool,
	written:   bool,
	src:       i32,
	src_pos:   u32,
	src_off:   i64,
	offset:    i64,
	depth:     i32,
}

@(private)
Rev_Entry :: struct {
	offset: i64,
	pos:    u32,
}

@(private)
Source :: struct {
	pack:  ^Pack,
	base:  string,
	mtime: i64,
	rev:   []Rev_Entry,
}

@(private)
Loosen :: struct {
	oid:   Oid,
	mtime: i64,
}

@(private)
Prune_Filter :: struct {
	reachable: ^map[Oid]struct{},
	drop:      ^map[Oid]struct{},
	cutoff:    i64,
}

@(private)
Window_Slot :: struct {
	obj:   int,
	data:  []u8,
	index: Delta_Index,
	used:  bool,
}

@(private)
Repack_State :: struct {
	db:         ^Odb,
	opts:       Repack_Options,
	filter:     ^Prune_Filter,
	objects:    [dynamic]Repack_Object,
	where_:     map[Oid]int,
	sources:    [dynamic]Source,
	loose_seen: map[Oid]struct{},
	drop_loose: [dynamic]Oid,
	loosen:     [dynamic]Loosen,
	b:          Pack_Builder,
	z:          zlib.z_stream,
	z_ready:    bool,
	zbuf:       []u8,
	window:     []Window_Slot,
	next:       int,
	delta:      [dynamic]u8,
	best:       [dynamic]u8,
	stats:      Repack_Stats,
}

@(private)
name_hash :: proc "contextless" (name: string) -> u32 {
	h: u32
	for i in 0 ..< len(name) {
		c := name[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			continue
		}
		h = (h >> 2) + u32(c) << 24
	}
	return h
}

repack :: proc(db: ^Odb, opts := DEFAULT_REPACK) -> (stats: Repack_Stats, err: Error) {
	return repack_run(db, opts, nil)
}

@(private)
repack_run :: proc(db: ^Odb, opts: Repack_Options, filter: ^Prune_Filter) -> (stats: Repack_Stats, err: Error) {
	if len(db.dirs) == 0 {
		return {}, .Invalid
	}
	a := db.allocator
	lock_buf: [PATH_MAX]u8
	lock_path := concat_into(lock_buf[:], db.dirs[0].path, "/info/0ndb-repack.lock") or_return
	prim.mkdir_all(db.vfs, parent_dir(lock_path))
	lock_fd, lerr := prim.lock_file(db.vfs, lock_path)
	if lerr != .None {
		return {}, perr(lerr)
	}
	defer prim.close_file(db.vfs, lock_fd)
	mapped := bulk_begin(db)
	defer bulk_end(db, mapped)

	s := Repack_State{db = db, opts = opts, filter = filter}
	s.opts.window = clamp(s.opts.window, 0, 256)
	s.opts.depth = clamp(s.opts.depth, 1, 4095)
	s.opts.level = clamp(s.opts.level, 0, 9)
	s.objects = make([dynamic]Repack_Object, a)
	s.where_ = make(map[Oid]int, a)
	s.sources = make([dynamic]Source, a)
	s.loose_seen = make(map[Oid]struct{}, a)
	s.drop_loose = make([dynamic]Oid, a)
	s.loosen = make([dynamic]Loosen, a)
	s.delta = make([dynamic]u8, a)
	s.best = make([dynamic]u8, a)
	defer repack_cleanup(&s)

	collect_loose(&s) or_return
	collect_packs(&s) or_return
	garbage := len(s.drop_loose) > 0 || s.stats.packed_dropped > 0 || len(s.loosen) > 0
	if !garbage && (len(s.objects) == 0 || (len(s.sources) <= 1 && !any_loose(&s) && !sources_stored(&s))) {
		return s.stats, .None
	}
	checksum: Oid
	if len(s.objects) > 0 {
		checksum = write_new_pack(&s) or_return
	}
	barrier(db) or_return
	if len(s.objects) > 0 {
		verify_new_pack(&s, checksum) or_return
	}
	loosen_young(&s) or_return
	barrier(db) or_return
	remove_replaced(&s, checksum, len(s.objects) > 0)
	if len(s.objects) > 0 || len(s.sources) > 0 || len(s.drop_loose) > 0 {
		barrier(db)
	}
	s.stats.objects = len(s.objects)
	return s.stats, .None
}

@(private)
write_new_pack :: proc(s: ^Repack_State) -> (checksum: Oid, err: Error) {
	db := s.db
	a := db.allocator
	for &o in s.objects {
		t, size := read_header(db, o.oid) or_return
		o.type, o.size = t, size
	}
	assign_names(s)
	slice.sort_by(s.objects[:], proc(x, y: Repack_Object) -> bool {
		if x.type != y.type {
			return x.type < y.type
		}
		if x.name_hash != y.name_hash {
			return x.name_hash < y.name_hash
		}
		return x.size > y.size
	})
	for o, i in s.objects {
		s.where_[o.oid] = i
	}
	if zlib.deflateInit(&s.z, c.int(s.opts.level)) != zlib.OK {
		return {}, .Out_Of_Memory
	}
	s.z_ready = true
	zbuf, zerr := make([]u8, IO_CHUNK, a)
	if zerr != nil {
		return {}, .Out_Of_Memory
	}
	s.zbuf = zbuf
	window, werr := make([]Window_Slot, max(s.opts.window, 1), a)
	if werr != nil {
		return {}, .Out_Of_Memory
	}
	s.window = window
	pack_begin(&s.b, db) or_return
	for i in 0 ..< len(s.objects) {
		if e := repack_one(s, i); e != .None {
			pack_abort(&s.b)
			return {}, e
		}
	}
	return pack_finish(&s.b)
}

@(private)
repack_cleanup :: proc(s: ^Repack_State) {
	a := s.db.allocator
	for &w in s.window {
		window_clear(s, &w)
	}
	delete(s.window, a)
	delete(s.zbuf, a)
	if s.z_ready {
		zlib.deflateEnd(&s.z)
	}
	for src in s.sources {
		delete(src.base, a)
		delete(src.rev, a)
	}
	delete(s.sources)
	delete(s.objects)
	delete(s.where_)
	delete(s.loose_seen)
	delete(s.drop_loose)
	delete(s.loosen)
	delete(s.delta)
	delete(s.best)
}

@(private)
any_loose :: proc(s: ^Repack_State) -> bool {
	for o in s.objects {
		if o.loose {
			return true
		}
	}
	return false
}

@(private)
sources_stored :: proc(s: ^Repack_State) -> bool {
	for src in s.sources {
		pb: [PATH_MAX]u8
		path := concat_into(pb[:], src.base, ".pack") or_else ""
		if path != "" && pack_file_is_stored(s.db.vfs, path) {
			return true
		}
	}
	return false
}

@(private)
pack_file_is_stored :: proc(vfs: prim.Vfs, path: string) -> bool {
	fd, err := prim.open_file(vfs, path)
	if err != .None {
		return false
	}
	defer prim.close_file(vfs, fd)
	buf: [64]u8
	n, _ := prim.read_at(vfs, fd, buf[:], 12)
	p := 0
	for p < n && buf[p] & 0x80 != 0 {
		p += 1
	}
	p += 1
	return p + 3 <= n && buf[p] == 0x78 && buf[p + 1] == 0x01 && buf[p + 2] & 0x06 == 0
}

@(private)
keep_object :: proc(s: ^Repack_State, oid: Oid) -> bool {
	if s.filter == nil {
		return true
	}
	if s.filter.drop != nil {
		return oid not_in s.filter.drop^
	}
	return oid in s.filter.reachable^
}

@(private)
collect_loose :: proc(s: ^Repack_State) -> Error {
	db := s.db
	hex_len := oid_size(db.format) * 2
	for i in 0 ..< 256 {
		pb: [PATH_MAX]u8
		fan := [2]u8{HEX_DIGITS[i >> 4], HEX_DIGITS[i & 15]}
		dir := concat_into(pb[:], db.dirs[0].path, "/", string(fan[:])) or_return
		d: prim.Dir
		if prim.dir_open(db.vfs, &d, dir, db.allocator) != .None {
			continue
		}
		defer prim.dir_close(db.vfs, &d)
		for {
			e, ok, derr := prim.dir_next(db.vfs, &d)
			if !ok || derr != .None {
				break
			}
			if len(e.name) != hex_len - 2 || (e.kind != .File && e.kind != .Unknown) {
				continue
			}
			hb: [MAX_HEX]u8
			copy(hb[:], fan[:])
			copy(hb[2:], e.name)
			oid, _, oid_ok := oid_from_hex(string(hb[:hex_len]))
			if !oid_ok {
				continue
			}
			fb: [PATH_MAX]u8
			fpath := concat_into(fb[:], dir, "/", e.name) or_continue
			st, serr := prim.lstat(db.vfs, fpath)
			if serr != .None || st.kind != .File {
				continue
			}
			s.loose_seen[oid] = {}
			if s.filter != nil && s.filter.drop != nil {
				if oid in s.filter.drop^ {
					append(&s.drop_loose, oid)
				}
				continue
			}
			if !keep_object(s, oid) {
				if st.mtime_ns < s.filter.cutoff {
					append(&s.drop_loose, oid)
				}
				continue
			}
			s.stats.bytes_before += st.size
			add_candidate(s, oid, -1, 0, 0)
		}
	}
	return .None
}

@(private)
add_candidate :: proc(s: ^Repack_State, oid: Oid, src: i32, pos: u32, off: i64) {
	if i, ok := s.where_[oid]; ok {
		o := &s.objects[i]
		if src < 0 {
			o.loose = true
		} else if o.src < 0 {
			o.src, o.src_pos, o.src_off = src, pos, off
		}
		return
	}
	s.where_[oid] = len(s.objects)
	append(&s.objects, Repack_Object{oid = oid, loose = src < 0, src = src, src_pos = pos, src_off = off})
}

@(private)
collect_packs :: proc(s: ^Repack_State) -> Error {
	db := s.db
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	d := &db.dirs[0]
	d.scanned = false
	scan_packs(db, d)
	for p in d.packs {
		pb: [PATH_MAX]u8
		keep := concat_into(pb[:], p.base, ".keep") or_return
		pinned := prim.exists(db.vfs, keep)
		promisor := concat_into(pb[:], p.base, ".promisor") or_return
		pinned = pinned || prim.exists(db.vfs, promisor)
		if s.filter != nil && s.filter.drop != nil {
			hits := 0
			for oid in s.filter.drop^ {
				if _, found := pack_find(p, oid); found {
					hits += 1
				}
			}
			if hits == 0 {
				continue
			}
			if pinned {
				s.stats.pinned_hits += hits
				continue
			}
		} else if pinned {
			continue
		}
		pack_path := concat_into(pb[:], p.base, ".pack") or_return
		st, err := prim.stat(db.vfs, pack_path)
		if err != .None {
			continue
		}
		size, mtime := st.size, st.mtime_ns
		if s.filter == nil && size >= s.opts.small_pack_bytes && !pack_file_is_stored(db.vfs, pack_path) {
			continue
		}
		pack_open_data(db, p) or_return
		rev, rerr := make([]Rev_Entry, p.count, db.allocator)
		if rerr != nil {
			return .Out_Of_Memory
		}
		for i in 0 ..< p.count {
			off, oerr := pack_offset_at(p, i)
			if oerr != .None {
				delete(rev, db.allocator)
				return oerr
			}
			rev[i] = {off, u32(i)}
		}
		slice.sort_by(rev, proc(x, y: Rev_Entry) -> bool {
			return x.offset < y.offset
		})
		base, cerr := strings.clone(p.base, db.allocator)
		if cerr != nil {
			delete(rev, db.allocator)
			return .Out_Of_Memory
		}
		s.stats.bytes_before += size
		src := i32(len(s.sources))
		append(&s.sources, Source{pack = p, base = base, mtime = mtime, rev = rev})
		for r in rev {
			oid := pack_oid_at(p, int(r.pos))
			if !keep_object(s, oid) {
				if s.filter.drop != nil || mtime < s.filter.cutoff {
					s.stats.packed_dropped += 1
				} else if oid not_in s.loose_seen {
					append(&s.loosen, Loosen{oid, mtime})
				}
				continue
			}
			add_candidate(s, oid, src, r.pos, r.offset)
		}
	}
	return .None
}

@(private)
assign_names :: proc(s: ^Repack_State) {
	db := s.db
	for i in 0 ..< len(s.objects) {
		if s.objects[i].type != .Tree {
			continue
		}
		_, data, err := read(db, s.objects[i].oid, db.allocator)
		if err != .None {
			continue
		}
		it := tree_iter(data, db.format)
		for e in tree_next(&it) {
			if j, ok := s.where_[e.oid]; ok && s.objects[j].name_hash == 0 {
				s.objects[j].name_hash = name_hash(e.name)
			}
		}
		delete(data, db.allocator)
	}
}

@(private)
window_clear :: proc(s: ^Repack_State, w: ^Window_Slot) {
	if w.used {
		delta_index_destroy(&w.index, s.db.allocator)
		delete(w.data, s.db.allocator)
		w^ = {}
	}
}

@(private)
rev_find :: proc(src: ^Source, offset: i64) -> int {
	lo, hi := 0, len(src.rev)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if src.rev[mid].offset < offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo if lo < len(src.rev) && src.rev[lo].offset == offset else -1
}

@(private)
put_ofs :: proc(w: ^Buf_Writer, rel: i64) {
	rel := u64(rel)
	ob: [16]u8
	k := len(ob) - 1
	ob[k] = u8(rel & 0x7f)
	rel >>= 7
	for rel != 0 {
		rel -= 1
		k -= 1
		ob[k] = 0x80 | u8(rel & 0x7f)
		rel >>= 7
	}
	bw_write(w, ob[k:])
}

@(private)
try_reuse :: proc(s: ^Repack_State, i: int) -> bool {
	db := s.db
	o := &s.objects[i]
	if o.src < 0 {
		return false
	}
	src := &s.sources[o.src]
	p := src.pack
	h, herr := pack_entry_header(db, p, o.src_off)
	if herr != .None {
		return false
	}
	ri := rev_find(src, o.src_off)
	if ri < 0 {
		return false
	}
	limit := p.size - i64(p.hsz)
	end := limit
	if ri + 1 < len(src.rev) {
		end = src.rev[ri + 1].offset
	}
	if end <= h.start || end > limit {
		return false
	}
	head: [8]u8
	first := pack_view(db, p, h.start, 3, head[:]) or_else nil
	base := -1
	switch h.kind {
	case 1 ..= 4:
		if len(first) < 3 || (first[0] == 0x78 && first[2] & 0x06 == 0) {
			return false
		}
	case OBJ_OFS_DELTA, OBJ_REF_DELTA:
		base_oid := h.base_oid
		if h.kind == OBJ_OFS_DELTA {
			bi := rev_find(src, h.base_off)
			if bi < 0 {
				return false
			}
			base_oid = pack_oid_at(p, int(src.rev[bi].pos))
		}
		j, ok := s.where_[base_oid]
		if !ok {
			return false
		}
		b := &s.objects[j]
		if !b.written || b.src != o.src || int(b.depth) + 1 > s.opts.depth {
			return false
		}
		base = j
	case:
		return false
	}
	start := s.b.w.pos
	s.b.w.crc = 0
	hb: [32]u8
	if base >= 0 {
		bw_write(&s.b.w, pack_entry_head(hb[:], OBJ_OFS_DELTA, h.size))
		put_ofs(&s.b.w, start - s.objects[base].offset)
	} else {
		bw_write(&s.b.w, pack_entry_head(hb[:], h.kind, h.size))
	}
	crc: u32
	buf: [IO_CHUNK]u8
	pos := o.src_off
	for pos < end {
		chunk, verr := pack_view(db, p, pos, int(min(end - pos, i64(len(buf)))), buf[:])
		if verr != .None || len(chunk) == 0 {
			pack_rewind(&s.b, start)
			return false
		}
		crc = hashing.crc32(chunk, crc)
		if pos + i64(len(chunk)) > h.start {
			skip := max(h.start - pos, 0)
			bw_write(&s.b.w, chunk[skip:])
		}
		pos += i64(len(chunk))
	}
	if s.b.w.err != .None || crc != endian.unchecked_get_u32be(p.idx[p.crcs + int(o.src_pos) * 4:]) {
		if s.b.w.err == .None {
			pack_rewind(&s.b, start)
		}
		return false
	}
	if base >= 0 {
		o.depth = s.objects[base].depth + 1
		s.stats.deltas += 1
	}
	o.offset = start
	o.written = true
	s.stats.reused += 1
	return pack_record(&s.b, o.oid, start) == .None
}

@(private)
repack_one :: proc(s: ^Repack_State, i: int) -> Error {
	db := s.db
	if try_reuse(s, i) {
		return s.b.w.err
	}
	o := &s.objects[i]
	if o.size > s.opts.delta_max_size {
		return write_streamed(s, i)
	}
	_, data := read(db, o.oid, db.allocator) or_return
	owned := true
	defer if owned {
		delete(data, db.allocator)
	}
	best := -1
	best_size := 0
	if s.opts.window > 0 && len(data) >= 32 {
		limit := len(data) / 2 - 20
		for &w in s.window {
			if !w.used {
				continue
			}
			base := &s.objects[w.obj]
			if base.type != o.type || int(base.depth) >= s.opts.depth || len(w.data) < len(data) / 32 {
				continue
			}
			max_size := limit * (s.opts.depth - int(base.depth)) / s.opts.depth
			if best >= 0 {
				max_size = min(max_size, best_size - 1)
			}
			diff := abs(len(w.data) - len(data))
			if max_size <= 0 || diff >= max_size {
				continue
			}
			if delta_create(&w.index, data, max_size, &s.delta) {
				best, best_size = w.obj, len(s.delta)
				s.delta, s.best = s.best, s.delta
			}
		}
	}
	start := s.b.w.pos
	s.b.w.crc = 0
	hb: [32]u8
	if best >= 0 {
		base := &s.objects[best]
		bw_write(&s.b.w, pack_entry_head(hb[:], OBJ_OFS_DELTA, i64(len(s.best))))
		put_ofs(&s.b.w, start - base.offset)
		deflate_payload(s, s.best[:]) or_return
		o.depth = base.depth + 1
		s.stats.deltas += 1
	} else {
		bw_write(&s.b.w, pack_entry_head(hb[:], u8(o.type), i64(len(data))))
		deflate_payload(s, data) or_return
	}
	o.offset = start
	o.written = true
	pack_record(&s.b, o.oid, start) or_return
	if s.opts.window > 0 && len(data) >= 32 {
		owned = false
		window_push(s, i, data) or_return
	}
	return s.b.w.err
}

@(private)
window_push :: proc(s: ^Repack_State, obj: int, data: []u8) -> Error {
	w := &s.window[s.next]
	s.next = (s.next + 1) % len(s.window)
	window_clear(s, w)
	w.obj = obj
	w.data = data
	w.used = true
	if e := delta_index_init(&w.index, data, s.db.allocator); e != .None {
		delete(data, s.db.allocator)
		w^ = {}
		return e
	}
	return .None
}

@(private)
deflate_payload :: proc(s: ^Repack_State, data: []u8) -> Error {
	if zlib.deflateReset(&s.z) != zlib.OK {
		return .Corrupt
	}
	rest := data
	for {
		chunk := rest[:min(len(rest), 1 << 30)]
		rest = rest[len(chunk):]
		flush: c.int = zlib.FINISH if len(rest) == 0 else zlib.NO_FLUSH
		deflate_feed(s, chunk, flush) or_return
		if len(rest) == 0 {
			return s.b.w.err
		}
	}
}

@(private)
deflate_feed :: proc(s: ^Repack_State, chunk: []u8, flush: c.int) -> Error {
	s.z.next_in = raw_data(chunk)
	s.z.avail_in = zlib.uInt(len(chunk))
	for {
		s.z.next_out = raw_data(s.zbuf)
		s.z.avail_out = zlib.uInt(len(s.zbuf))
		r := zlib.deflate(&s.z, flush)
		if r != zlib.OK && r != zlib.STREAM_END && r != zlib.BUF_ERROR {
			return .Corrupt
		}
		produced := len(s.zbuf) - int(s.z.avail_out)
		bw_write(&s.b.w, s.zbuf[:produced])
		if flush == zlib.FINISH {
			if r == zlib.STREAM_END {
				return s.b.w.err
			}
		} else if s.z.avail_in == 0 && s.z.avail_out != 0 {
			return s.b.w.err
		}
		if r == zlib.BUF_ERROR && produced == 0 {
			return .Corrupt
		}
	}
}

@(private)
Deflate_Sink :: struct {
	s:   ^Repack_State,
	err: Error,
}

@(private)
deflate_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	ds := (^Deflate_Sink)(data)
	#partial switch mode {
	case .Write:
		if e := deflate_feed(ds.s, p, zlib.NO_FLUSH); e != .None {
			ds.err = e
			return 0, .Unknown
		}
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

@(private)
write_streamed :: proc(s: ^Repack_State, i: int) -> Error {
	o := &s.objects[i]
	start := s.b.w.pos
	s.b.w.crc = 0
	hb: [32]u8
	bw_write(&s.b.w, pack_entry_head(hb[:], u8(o.type), o.size))
	if zlib.deflateReset(&s.z) != zlib.OK {
		return .Corrupt
	}
	ds := Deflate_Sink{s = s}
	_, size, err := stream(s.db, o.oid, io.Stream{procedure = deflate_sink_proc, data = &ds})
	if ds.err != .None {
		return ds.err
	}
	err or_return
	if size != o.size {
		return .Corrupt
	}
	deflate_feed(s, nil, zlib.FINISH) or_return
	o.offset = start
	o.written = true
	return pack_record(&s.b, o.oid, start)
}

@(private)
verify_new_pack :: proc(s: ^Repack_State, checksum: Oid) -> Error {
	db := s.db
	hb: [MAX_HEX]u8
	hex := oid_to_string(checksum, db.format, &hb)
	pb: [PATH_MAX]u8
	base := concat_into(pb[:], db.dirs[0].path, "/pack/pack-", hex) or_return
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	d := &db.dirs[0]
	d.scanned = false
	scan_packs(db, d)
	for p in d.packs {
		if p.base != base {
			continue
		}
		if p.count != len(s.objects) {
			return .Corrupt
		}
		for o in s.objects {
			if _, ok := pack_find(p, o.oid); !ok {
				return .Corrupt
			}
		}
		qb: [PATH_MAX]u8
		pack_path := concat_into(qb[:], base, ".pack") or_return
		if st, err := prim.stat(db.vfs, pack_path); err == .None {
			s.stats.bytes_after = st.size
		}
		return .None
	}
	return .Corrupt
}

@(private)
loosen_young :: proc(s: ^Repack_State) -> Error {
	db := s.db
	for l in s.loosen {
		t, data := read(db, l.oid, db.allocator) or_return
		err := write_loose_data(db, l.oid, t, data)
		delete(data, db.allocator)
		err or_return
		pb: [PATH_MAX]u8
		path := loose_path(pb[:], db.dirs[0].path, l.oid, db.format) or_return
		set_mtime(db, path, l.mtime)
		s.stats.loosened += 1
	}
	return .None
}

@(private)
remove_replaced :: proc(s: ^Repack_State, checksum: Oid, have_new: bool) {
	db := s.db
	hb: [MAX_HEX]u8
	hex := oid_to_string(checksum, db.format, &hb)
	nb: [PATH_MAX]u8
	new_base := concat_into(nb[:], db.dirs[0].path, "/pack/pack-", hex) or_else ""
	for src in s.sources {
		if have_new && src.base == new_base {
			continue
		}
		for ext in ([]string{".idx", ".pack", ".rev", ".bitmap", ".mtimes"}) {
			pb: [PATH_MAX]u8
			path := concat_into(pb[:], src.base, ext) or_continue
			prim.remove(db.vfs, path)
		}
		s.stats.packs_removed += 1
	}
	if len(s.sources) > 0 {
		pb: [PATH_MAX]u8
		if dir, err := concat_into(pb[:], db.dirs[0].path, "/pack"); err == .None {
			track(db, "", dir)
		}
	}
	for o in s.objects {
		if o.loose {
			remove_loose(s, o.oid)
		}
	}
	for oid in s.drop_loose {
		remove_loose(s, oid)
	}
	for i in 0 ..< 256 {
		pb: [PATH_MAX]u8
		fan := [2]u8{HEX_DIGITS[i >> 4], HEX_DIGITS[i & 15]}
		dir := concat_into(pb[:], db.dirs[0].path, "/", string(fan[:])) or_continue
		if prim.remove_dir(db.vfs, dir) == .None {
			track(db, "", db.dirs[0].path)
		}
	}
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	cache_clear(db)
	db.dirs[0].scanned = false
	scan_packs(db, &db.dirs[0])
}

@(private)
remove_loose :: proc(s: ^Repack_State, oid: Oid) {
	db := s.db
	pb: [PATH_MAX]u8
	path := loose_path(pb[:], db.dirs[0].path, oid, db.format) or_else ""
	if path != "" && prim.remove(db.vfs, path) == .None {
		s.stats.loose_removed += 1
		track(db, "", parent_dir(path))
	}
}

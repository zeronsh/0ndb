package search

import "base:runtime"
import "core:hash/xxhash"
import "../prim"

DOC_BLOCK :: 128
DICT_BLOCK :: 64
INLINE :: 2
MAX_TERM :: 256
CHUNK :: 64 * 1024
FRAME :: 32 * 1024
MAX_REF :: 255
MAX_FIELDS :: 32
MAX_NAME :: 64
MAX_SLOT :: 200
MAX_PATH :: 4096
MAX_DOCS :: u64(max(u32))
HEX :: "0123456789abcdef"

MANIFEST_MAGIC :: u64(0x6e61_6d68_6372_7330)
MANIFEST_VERSION :: u32(2)

DEFAULT_BUDGET :: 32 * 1024 * 1024
DEFAULT_CACHE_PAGES :: 512
DEFAULT_FACTOR :: 4
DEFAULT_PACE :: 3

Error :: enum u8 {
	None,
	Corrupt,
	Invalid,
	Syntax,
	Full,
	Busy,
	Not_Found,
	Missing,
	Too_Large,
	Permission,
	No_Space,
	No_Memory,
	Io,
}

Field :: struct {
	name:  string,
	value: string,
}

Doc :: struct {
	object:      prim.Id,
	ref:         []u8,
	part:        u32,
	kind:        u8,
	title:       bool,
	slot:        []u8,
	fields:      []Field,
	participant: prim.Id,
	hlc:         prim.Hlc,
	text:        []u8,
	vector:      []f32,
	embed:       bool,
}

Text_Ref :: struct {
	object: prim.Id,
	ref:    []u8,
	part:   u32,
	kind:   u8,
	title:  bool,
	offset: u64,
	len:    u32,
}

Fetch :: #type proc(data: rawptr, t: ^Text_Ref, out: []u8) -> bool

Embed :: #type proc(data: rawptr, kind: u8, text: []u8, out: []f32) -> bool

Embedder :: struct {
	dim:   int,
	embed: Embed,
	data:  rawptr,
}

Options :: struct {
	vfs:              prim.Vfs,
	store_text:       bool,
	fetch:            Fetch,
	fetch_data:       rawptr,
	embedder:         Embedder,
	substring_fields: []string,
	kind_names:       []string,
	budget:           int,
	cache_pages:      int,
	merge_factor:     int,
	pace:             int,
}

Span :: struct {
	byte_lo: u64,
	byte_hi: u64,
	line_lo: u32,
	line_hi: u32,
	scope:   prim.Id,
}

Scope :: struct {
	id:     prim.Id,
	object: prim.Id,
	ref:    []u8,
	hlc:    prim.Hlc,
}

Seg_Info :: struct {
	gen: u64,
	sum: u64,
}

Manifest :: struct {
	next_gen:  u64,
	next_doc:  u64,
	total_len: u64,
	store:     bool,
	dim:       u64,
	cb_gen:    u64,
	cb_n:      u64,
	segs:      [dynamic]Seg_Info,
	obsolete:  [dynamic]u64,
}

Index :: struct {
	vfs:       prim.Vfs,
	allocator: runtime.Allocator,
	dir:       string,
	opts:      Options,
	lock:      prim.Fd,
	man:       Manifest,
	segs:      [dynamic]Seg,
	mem:       Mem,
	merge:     ^Merge,
	cache:     Cache,
	broken:    bool,
}

@(private)
_perr :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Permission:
		return .Permission
	case .Busy, .Would_Block:
		return .Busy
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Too_Large:
		return .Too_Large
	case .Invalid:
		return .Invalid
	}
	return .Io
}

@(private)
_aerr :: proc "contextless" (e: runtime.Allocator_Error) -> Error {
	return .None if e == nil else .No_Memory
}

@(private)
_cerr :: proc "contextless" (e: prim.Codec_Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .No_Memory:
		return .No_Memory
	}
	return .Corrupt
}

Name_Buf :: [prim.PATH_MAX]u8

file_path :: proc(ix: ^Index, name: string, buf: ^Name_Buf) -> string {
	n := copy(buf[:], ix.dir)
	if n > 0 && buf[n - 1] != '/' && n < len(buf) {
		buf[n] = '/'
		n += 1
	}
	n += copy(buf[n:], name)
	return string(buf[:n])
}

seg_path :: proc(ix: ^Index, gen: u64, buf: ^Name_Buf) -> string {
	name: [20]u8
	hex := HEX
	copy(name[:], "seg-")
	for i in 0 ..< 16 {
		name[4 + i] = hex[(gen >> u64(60 - 4 * i)) & 0xf]
	}
	return file_path(ix, string(name[:]), buf)
}

open :: proc(ix: ^Index, dir: string, opts: Options, allocator := context.allocator) -> (rebuilt: bool, err: Error) {
	ix^ = {
		allocator = allocator,
		lock      = prim.INVALID_FD,
		opts      = opts,
	}
	if ix.opts.vfs.procs == nil {
		ix.opts.vfs = prim.os_vfs()
	}
	ix.vfs = ix.opts.vfs
	if ix.opts.merge_factor > 32 {
		ix.opts.merge_factor = 32
	}
	if ix.opts.budget <= 0 {
		ix.opts.budget = DEFAULT_BUDGET
	}
	if ix.opts.cache_pages <= 0 {
		ix.opts.cache_pages = DEFAULT_CACHE_PAGES
	}
	if ix.opts.merge_factor < 2 {
		ix.opts.merge_factor = DEFAULT_FACTOR
	}
	if ix.opts.pace <= 0 {
		ix.opts.pace = DEFAULT_PACE
	}
	if !ix.opts.store_text && ix.opts.fetch == nil {
		return false, .Invalid
	}
	if ix.opts.embedder.dim < 0 || ix.opts.embedder.dim > MAX_DIM {
		return false, .Invalid
	}
	if e := prim.mkdir_all(ix.vfs, dir); e != .None {
		return false, _perr(e)
	}
	d, aerr := make([]u8, len(dir), allocator)
	if aerr != nil {
		return false, .No_Memory
	}
	copy(d, dir)
	ix.dir = string(d)
	ix.man.segs = make([dynamic]Seg_Info, allocator)
	ix.man.obsolete = make([dynamic]u64, allocator)
	ix.segs = make([dynamic]Seg, allocator)
	buf: Name_Buf
	lock, lerr := prim.lock_file(ix.vfs, file_path(ix, "LOCK", &buf))
	if lerr != .None {
		close(ix)
		return false, _perr(lerr)
	}
	ix.lock = lock
	if e := cache_init(&ix.cache, ix.opts.cache_pages, allocator); e != .None {
		close(ix)
		return false, e
	}
	if e := mem_init(&ix.mem, allocator); e != .None {
		close(ix)
		return false, e
	}
	_remove(ix, "flush.tmp")
	_remove(ix, "merge.tmp")
	lerr2 := _load(ix)
	if lerr2 == .None && ix.man.store != ix.opts.store_text {
		lerr2 = .Corrupt
	}
	if lerr2 != .None {
		if lerr2 == .No_Memory || lerr2 == .Io || lerr2 == .Permission {
			close(ix)
			return false, lerr2
		}
		if e := reset(ix); e != .None {
			close(ix)
			return false, e
		}
		return true, .None
	}
	for g in ix.man.obsolete {
		_remove_gen(ix, g)
	}
	for g := ix.man.next_gen; prim.exists(ix.vfs, seg_path(ix, g, &buf)); g += 1 {
		_remove_gen(ix, g)
	}
	mem_reset(&ix.mem, ix.man.next_doc)
	cb_gc(ix)
	return false, .None
}

close :: proc(ix: ^Index) {
	if ix.merge != nil {
		merge_abort(ix)
	}
	for &s in ix.segs {
		seg_close(&s)
	}
	delete(ix.segs)
	delete(ix.man.segs)
	delete(ix.man.obsolete)
	mem_destroy(&ix.mem)
	cache_destroy(&ix.cache)
	if ix.lock != prim.INVALID_FD {
		prim.close_file(ix.vfs, ix.lock)
	}
	delete(ix.dir, ix.allocator)
	ix^ = {
		lock = prim.INVALID_FD,
	}
}

reset :: proc(ix: ^Index) -> Error {
	if ix.merge != nil {
		merge_abort(ix)
	}
	buf: Name_Buf
	gens := make([dynamic]u64, context.temp_allocator)
	for s in ix.man.segs {
		append(&gens, s.gen)
	}
	for g in ix.man.obsolete {
		append(&gens, g)
	}
	for &s in ix.segs {
		seg_close(&s)
	}
	clear(&ix.segs)
	start := ix.man.next_gen
	clear(&ix.man.segs)
	clear(&ix.man.obsolete)
	for g in gens {
		_remove_gen(ix, g)
	}
	for g := start; prim.exists(ix.vfs, seg_path(ix, g, &buf)); g += 1 {
		_remove_gen(ix, g)
	}
	ix.man.next_gen = start + 1
	ix.man.next_doc = 0
	ix.man.total_len = 0
	ix.man.store = ix.opts.store_text
	ix.man.dim = u64(max(ix.opts.embedder.dim, 0))
	ix.man.cb_gen = 0
	ix.man.cb_n = 0
	ix.broken = false
	cache_clear(&ix.cache)
	mem_reset(&ix.mem, 0)
	manifest_write(ix) or_return
	cb_gc(ix)
	return .None
}

@(private)
_remove :: proc(ix: ^Index, name: string) {
	buf: Name_Buf
	_ = prim.remove(ix.vfs, file_path(ix, name, &buf))
}

@(private)
_remove_gen :: proc(ix: ^Index, gen: u64) {
	buf: Name_Buf
	_ = prim.remove(ix.vfs, seg_path(ix, gen, &buf))
}

@(private)
_load :: proc(ix: ^Index) -> Error {
	buf: Name_Buf
	data, rerr := prim.read_file(ix.vfs, file_path(ix, "MANIFEST", &buf), context.temp_allocator)
	if rerr == .Not_Found {
		return .Corrupt
	}
	if rerr != .None {
		return _perr(rerr)
	}
	if len(data) < 8 + 8 {
		return .Corrupt
	}
	body := data[:len(data) - 8]
	if xxhash.XXH3_64_default(body) != prim.get_u64le(data[len(data) - 8:]) {
		return .Corrupt
	}
	r := prim.reader(body)
	if prim.read_u64le(&r) != MANIFEST_MAGIC || prim.read_u32le(&r) != MANIFEST_VERSION {
		return .Corrupt
	}
	flags := prim.read_u32le(&r)
	ix.man.store = flags & 1 != 0
	ix.man.next_gen = prim.read_u64le(&r)
	ix.man.next_doc = prim.read_u64le(&r)
	ix.man.total_len = prim.read_u64le(&r)
	ix.man.dim = prim.read_u64le(&r)
	ix.man.cb_gen = prim.read_u64le(&r)
	ix.man.cb_n = prim.read_u64le(&r)
	if ix.man.dim != u64(max(ix.opts.embedder.dim, 0)) {
		return .Corrupt
	}
	nseg := prim.read_uvarint(&r)
	if nseg > 1 << 16 {
		return .Corrupt
	}
	for _ in 0 ..< nseg {
		si := Seg_Info {
			gen = prim.read_u64le(&r),
			sum = prim.read_u64le(&r),
		}
		if r.err != .None {
			return .Corrupt
		}
		if _, e := append(&ix.man.segs, si); e != nil {
			return .No_Memory
		}
	}
	nobs := prim.read_uvarint(&r)
	if nobs > 1 << 16 {
		return .Corrupt
	}
	for _ in 0 ..< nobs {
		g := prim.read_u64le(&r)
		if r.err != .None {
			return .Corrupt
		}
		if _, e := append(&ix.man.obsolete, g); e != nil {
			return .No_Memory
		}
	}
	if !prim.reader_done(&r) {
		return .Corrupt
	}
	expect := u64(0)
	for si in ix.man.segs {
		s: Seg
		e := seg_open(&s, ix.vfs, seg_path(ix, si.gen, &buf), si.gen)
		if e == .None && s.f.sum != si.sum {
			e = .Corrupt
		}
		if e == .None && (s.f.lo != expect || s.f.hi < s.f.lo || s.f.hi > ix.man.next_doc || si.gen >= ix.man.next_gen) {
			e = .Corrupt
		}
		if e == .None && s.f.store != ix.man.store {
			e = .Corrupt
		}
		if e == .None && s.f.vec_n > 0 && s.f.vec_dim != ix.man.dim {
			e = .Corrupt
		}
		if e != .None {
			seg_close(&s)
			return e
		}
		expect = s.f.hi
		if _, ae := append(&ix.segs, s); ae != nil {
			seg_close(&s)
			return .No_Memory
		}
	}
	if expect != ix.man.next_doc {
		return .Corrupt
	}
	return .None
}

manifest_write :: proc(ix: ^Index) -> Error {
	out := make([dynamic]u8, 0, 256, context.temp_allocator)
	w := prim.writer(&out)
	prim.write_u64le(&w, MANIFEST_MAGIC)
	prim.write_u32le(&w, MANIFEST_VERSION)
	prim.write_u32le(&w, 1 if ix.man.store else 0)
	prim.write_u64le(&w, ix.man.next_gen)
	prim.write_u64le(&w, ix.man.next_doc)
	prim.write_u64le(&w, ix.man.total_len)
	prim.write_u64le(&w, ix.man.dim)
	prim.write_u64le(&w, ix.man.cb_gen)
	prim.write_u64le(&w, ix.man.cb_n)
	prim.write_uvarint(&w, u64(len(ix.man.segs)))
	for s in ix.man.segs {
		prim.write_u64le(&w, s.gen)
		prim.write_u64le(&w, s.sum)
	}
	prim.write_uvarint(&w, u64(len(ix.man.obsolete)))
	for g in ix.man.obsolete {
		prim.write_u64le(&w, g)
	}
	if w.err != .None {
		return .No_Memory
	}
	prim.write_u64le(&w, xxhash.XXH3_64_default(out[:]))
	if w.err != .None {
		return .No_Memory
	}
	buf: Name_Buf
	return _perr(prim.replace_atomic(ix.vfs, file_path(ix, "MANIFEST", &buf), out[:]))
}

commit_segment :: proc(ix: ^Index, tmp: string, replace_from, replace_to: int, f: ^Footer) -> Error {
	buf, tbuf: Name_Buf
	gen := ix.man.next_gen
	path := seg_path(ix, gen, &buf)
	if e := prim.rename(ix.vfs, file_path(ix, tmp, &tbuf), path); e != .None {
		return _perr(e)
	}
	if e := prim.sync_dir(ix.vfs, ix.dir); e != .None {
		return _perr(e)
	}
	s: Seg
	if e := seg_open(&s, ix.vfs, path, gen); e != .None {
		_ = prim.remove(ix.vfs, path)
		return e
	}
	old_segs := make([dynamic]Seg_Info, context.temp_allocator)
	for si in ix.man.segs {
		append(&old_segs, si)
	}
	old_obs := make([dynamic]u64, context.temp_allocator)
	for g in ix.man.obsolete {
		append(&old_obs, g)
	}
	old_next := ix.man
	clear(&ix.man.obsolete)
	removed := make([dynamic]u64, context.temp_allocator)
	for i in replace_from ..< replace_to {
		append(&removed, ix.man.segs[i].gen)
		append(&ix.man.obsolete, ix.man.segs[i].gen)
	}
	remove_range(&ix.man.segs, replace_from, replace_to)
	inject_at(&ix.man.segs, replace_from, Seg_Info{gen = gen, sum = s.f.sum})
	ix.man.next_gen = gen + 1
	if replace_from == replace_to {
		ix.man.next_doc = f.hi
		ix.man.total_len += f.total_len
	}
	if e := manifest_write(ix); e != .None {
		clear(&ix.man.segs)
		for si in old_segs {
			append(&ix.man.segs, si)
		}
		clear(&ix.man.obsolete)
		for g in old_obs {
			append(&ix.man.obsolete, g)
		}
		ix.man.next_gen = old_next.next_gen
		ix.man.next_doc = old_next.next_doc
		ix.man.total_len = old_next.total_len
		seg_close(&s)
		_ = prim.remove(ix.vfs, path)
		return e
	}
	for i in replace_from ..< replace_to {
		seg_close(&ix.segs[i])
	}
	remove_range(&ix.segs, replace_from, replace_to)
	inject_at(&ix.segs, replace_from, s)
	for g in removed {
		_remove_gen(ix, g)
	}
	return .None
}

total_docs :: proc "contextless" (ix: ^Index) -> u64 {
	return ix.man.next_doc
}

segment_count :: proc "contextless" (ix: ^Index) -> int {
	return len(ix.segs)
}

disk_size :: proc(ix: ^Index) -> i64 {
	n: i64
	for s in ix.segs {
		n += s.size
	}
	return n
}

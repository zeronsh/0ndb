package search

import "core:c"
import "core:dynlib"
import "core:hash/xxhash"
import "base:runtime"
import "core:slice"
import "core:sync"
import "../prim"

when ODIN_OS == .Darwin {
	ZSTD_LIBRARIES :: [?]string{"libzstd.1.dylib", "/opt/homebrew/lib/libzstd.1.dylib", "/usr/local/lib/libzstd.1.dylib", "libzstd.dylib"}
} else {
	ZSTD_LIBRARIES :: [?]string{"libzstd.so.1", "libzstd.so"}
}

@(private)
Zstd_Loader :: struct {
	mu:   sync.Mutex,
	lib:  dynlib.Library,
	refs: int,
}

@(private)
zstd_loader: Zstd_Loader

ZSTD_compressBound: proc "c" (src_size: c.size_t) -> c.size_t
ZSTD_isError: proc "c" (code: c.size_t) -> c.uint
ZSTD_createCCtx: proc "c" () -> rawptr
ZSTD_freeCCtx: proc "c" (cctx: rawptr) -> c.size_t
ZSTD_createDCtx: proc "c" () -> rawptr
ZSTD_freeDCtx: proc "c" (dctx: rawptr) -> c.size_t
ZSTD_createCDict: proc "c" (dict: rawptr, size: c.size_t, level: c.int) -> rawptr
ZSTD_freeCDict: proc "c" (cdict: rawptr) -> c.size_t
ZSTD_createDDict: proc "c" (dict: rawptr, size: c.size_t) -> rawptr
ZSTD_freeDDict: proc "c" (ddict: rawptr) -> c.size_t
ZSTD_compressCCtx: proc "c" (cctx: rawptr, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t, level: c.int) -> c.size_t
ZSTD_decompressDCtx: proc "c" (dctx: rawptr, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t) -> c.size_t
ZSTD_compress_usingCDict: proc "c" (cctx: rawptr, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t, cdict: rawptr) -> c.size_t
ZSTD_decompress_usingDDict: proc "c" (dctx: rawptr, dst: rawptr, cap: c.size_t, src: rawptr, size: c.size_t, ddict: rawptr) -> c.size_t
ZDICT_trainFromBuffer: proc "c" (dict: rawptr, cap: c.size_t, samples: rawptr, sizes: [^]c.size_t, n: c.uint) -> c.size_t
ZDICT_isError: proc "c" (code: c.size_t) -> c.uint

zstd_load :: proc() -> bool {
	sync.mutex_lock(&zstd_loader.mu)
	defer sync.mutex_unlock(&zstd_loader.mu)
	if zstd_loader.refs > 0 {
		zstd_loader.refs += 1
		return true
	}
	lib: dynlib.Library
	ok := false
	for name in ZSTD_LIBRARIES {
		if lib, ok = dynlib.load_library(name); ok {
			break
		}
	}
	if !ok {
		return false
	}
	resolved := true
	if p, found := dynlib.symbol_address(lib, "ZSTD_compressBound"); found {
		ZSTD_compressBound = cast(type_of(ZSTD_compressBound))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_isError"); found {
		ZSTD_isError = cast(type_of(ZSTD_isError))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_createCCtx"); found {
		ZSTD_createCCtx = cast(type_of(ZSTD_createCCtx))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_freeCCtx"); found {
		ZSTD_freeCCtx = cast(type_of(ZSTD_freeCCtx))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_createDCtx"); found {
		ZSTD_createDCtx = cast(type_of(ZSTD_createDCtx))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_freeDCtx"); found {
		ZSTD_freeDCtx = cast(type_of(ZSTD_freeDCtx))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_createCDict"); found {
		ZSTD_createCDict = cast(type_of(ZSTD_createCDict))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_freeCDict"); found {
		ZSTD_freeCDict = cast(type_of(ZSTD_freeCDict))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_createDDict"); found {
		ZSTD_createDDict = cast(type_of(ZSTD_createDDict))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_freeDDict"); found {
		ZSTD_freeDDict = cast(type_of(ZSTD_freeDDict))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_compressCCtx"); found {
		ZSTD_compressCCtx = cast(type_of(ZSTD_compressCCtx))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_decompressDCtx"); found {
		ZSTD_decompressDCtx = cast(type_of(ZSTD_decompressDCtx))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_compress_usingCDict"); found {
		ZSTD_compress_usingCDict = cast(type_of(ZSTD_compress_usingCDict))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZSTD_decompress_usingDDict"); found {
		ZSTD_decompress_usingDDict = cast(type_of(ZSTD_decompress_usingDDict))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZDICT_trainFromBuffer"); found {
		ZDICT_trainFromBuffer = cast(type_of(ZDICT_trainFromBuffer))p
	} else {
		resolved = false
	}
	if p, found := dynlib.symbol_address(lib, "ZDICT_isError"); found {
		ZDICT_isError = cast(type_of(ZDICT_isError))p
	} else {
		resolved = false
	}
	if !resolved {
		dynlib.unload_library(lib)
		_zstd_clear()
		return false
	}
	zstd_loader.lib = lib
	zstd_loader.refs = 1
	return true
}

zstd_unload :: proc() {
	sync.mutex_lock(&zstd_loader.mu)
	defer sync.mutex_unlock(&zstd_loader.mu)
	if zstd_loader.refs == 0 {
		return
	}
	zstd_loader.refs -= 1
	if zstd_loader.refs > 0 {
		return
	}
	dynlib.unload_library(zstd_loader.lib)
	zstd_loader.lib = nil
	_zstd_clear()
}

@(private)
_zstd_clear :: proc() {
	ZSTD_compressBound = nil
	ZSTD_isError = nil
	ZSTD_createCCtx = nil
	ZSTD_freeCCtx = nil
	ZSTD_createDCtx = nil
	ZSTD_freeDCtx = nil
	ZSTD_createCDict = nil
	ZSTD_freeCDict = nil
	ZSTD_createDDict = nil
	ZSTD_freeDDict = nil
	ZSTD_compressCCtx = nil
	ZSTD_decompressDCtx = nil
	ZSTD_compress_usingCDict = nil
	ZSTD_decompress_usingDDict = nil
	ZDICT_trainFromBuffer = nil
	ZDICT_isError = nil
}

@(private)
_zstd_ready :: proc(z: ^Zstd) -> bool {
	if z.loaded {
		return true
	}
	z.loaded = zstd_load()
	return z.loaded
}

ZSTD_LEVEL :: 6
DICT_CAP :: 112 * 1024
DICT_SAMPLE_MIN :: 1 << 20
DICT_SAMPLE_MAX :: 8 << 20
DICT_SAMPLE_PIECE :: 2048
FRAME_RAW :: u8(0)
FRAME_ZSTD :: u8(1)
FRAME_DICT :: u8(2)

Zd_Slot :: struct {
	gen:   u64,
	cdict: rawptr,
	ddict: rawptr,
	used:  u64,
}

Zstd :: struct {
	cctx:   rawptr,
	dctx:   rawptr,
	slots:  [2]Zd_Slot,
	tick:   u64,
	loaded: bool,
}

@(private)
_zd_slot_free :: proc(sl: ^Zd_Slot) {
	if sl.cdict != nil {
		ZSTD_freeCDict(sl.cdict)
	}
	if sl.ddict != nil {
		ZSTD_freeDDict(sl.ddict)
	}
	sl^ = {}
}

zstd_forget :: proc(z: ^Zstd, gen: u64) {
	for &sl in z.slots {
		if sl.gen == gen && gen != 0 {
			_zd_slot_free(&sl)
		}
	}
}

zstd_destroy :: proc(z: ^Zstd) {
	if !z.loaded {
		z^ = {}
		return
	}
	if z.cctx != nil {
		ZSTD_freeCCtx(z.cctx)
	}
	if z.dctx != nil {
		ZSTD_freeDCtx(z.dctx)
	}
	for &sl in z.slots {
		_zd_slot_free(&sl)
	}
	z^ = {}
	zstd_unload()
}

zd_path :: proc(ix: ^Index, gen: u64, buf: ^Name_Buf) -> string {
	name: [19]u8
	copy(name[:], "zd-")
	hex := HEX
	for i in 0 ..< 16 {
		name[3 + i] = hex[(gen >> u64(60 - 4 * i)) & 0xf]
	}
	return file_path(ix, string(name[:]), buf)
}

zd_parse :: proc(data: []u8) -> (dict: []u8, ids: []u8, ok: bool) {
	if len(data) < 16 || xxhash.XXH3_64_default(data[:len(data) - 8]) != prim.get_u64le(data[len(data) - 8:]) {
		return nil, nil, false
	}
	body := data[:len(data) - 8]
	dl := int(prim.get_u32le(body[len(body) - 4:]))
	n := int(prim.get_u32le(body[len(body) - 8:]))
	if dl < 8 || n < 0 || dl + 4 * n + 8 != len(body) {
		return nil, nil, false
	}
	return body[:dl], body[dl:][:4 * n], true
}

@(private)
_zstd_dict :: proc(ix: ^Index, gen: u64) -> (sl: ^Zd_Slot, err: Error) {
	z := &ix.zstd
	if gen == 0 {
		return nil, .None
	}
	z.tick += 1
	for &x in z.slots {
		if x.gen == gen {
			x.used = z.tick
			return &x, .None
		}
	}
	if !_zstd_ready(z) {
		return nil, .Io
	}
	buf: Name_Buf
	data, rerr := prim.read_file(ix.vfs, zd_path(ix, gen, &buf), context.temp_allocator)
	if rerr != .None {
		return nil, .Corrupt if rerr == .Not_Found else _perr(rerr)
	}
	d, _, ok := zd_parse(data)
	if !ok {
		return nil, .Corrupt
	}
	v := &z.slots[0]
	for &x in z.slots {
		if x.used < v.used {
			v = &x
		}
	}
	_zd_slot_free(v)
	v.cdict = ZSTD_createCDict(raw_data(d), c.size_t(len(d)), ZSTD_LEVEL)
	v.ddict = ZSTD_createDDict(raw_data(d), c.size_t(len(d)))
	slice.zero(data)
	if v.cdict == nil || v.ddict == nil {
		_zd_slot_free(v)
		return nil, .No_Memory
	}
	v.gen = gen
	v.used = z.tick
	return v, .None
}

zstd_train :: proc(ix: ^Index) -> Error {
	if !ix.man.store || ix.man.zd_gen != 0 || !_zstd_ready(&ix.zstd) {
		return .None
	}
	m := &ix.mem
	total := 0
	for d in m.docs {
		if d.flags & DF_TEXT != 0 && d.flags & DF_DELETED == 0 {
			total += min(int(d.len), DICT_SAMPLE_PIECE)
		}
	}
	if total < ix.opts.dict_sample_min {
		stored := u64(total)
		for s in ix.segs {
			stored += s.f.total_len
		}
		if stored >= u64(ix.opts.dict_sample_min) {
			return zd_retrain(ix)
		}
		return .None
	}
	zs := zd_samples_init(context.temp_allocator)
	for d, i in m.docs {
		if d.flags & DF_TEXT == 0 || d.flags & DF_DELETED != 0 || d.len < 8 {
			continue
		}
		if len(zs.bytes) >= DICT_SAMPLE_MAX {
			break
		}
		at := int(m.frames[d.frame]) + int(d.frame_off)
		zd_sample_add(&zs, u32(m.base) + u32(i), m.raw[at:][:d.len])
	}
	return zd_install(ix, &zs)
}

Zd_Samples :: struct {
	bytes: [dynamic]u8,
	sizes: [dynamic]c.size_t,
	ids:   [dynamic]u32,
}

zd_samples_init :: proc(allocator: runtime.Allocator) -> Zd_Samples {
	return Zd_Samples{bytes = make([dynamic]u8, allocator), sizes = make([dynamic]c.size_t, allocator), ids = make([dynamic]u32, allocator)}
}

zd_sample_add :: proc(zs: ^Zd_Samples, id: u32, text: []u8) {
	n := min(len(text), DICT_SAMPLE_PIECE)
	if n < 8 {
		return
	}
	append(&zs.bytes, ..text[:n])
	append(&zs.sizes, c.size_t(n))
	append(&zs.ids, id)
}

zd_install :: proc(ix: ^Index, zs: ^Zd_Samples) -> Error {
	gen := u64(0)
	defer slice.zero(zs.bytes[:])
	if len(zs.bytes) >= ix.opts.dict_sample_min && _zstd_ready(&ix.zstd) {
		out := make([]u8, DICT_CAP + 4 * len(zs.ids) + 16, context.temp_allocator)
		defer slice.zero(out)
		cap_n := min(DICT_CAP, max(len(zs.bytes) / 10, 1024))
		got := ZDICT_trainFromBuffer(raw_data(out), c.size_t(cap_n), raw_data(zs.bytes), raw_data(zs.sizes), c.uint(len(zs.sizes)))
		if ZDICT_isError(got) == 0 {
			n := int(got)
			at := n
			for id in zs.ids {
				prim.put_u32le(out[at:], id)
				at += 4
			}
			prim.put_u32le(out[at:], u32(len(zs.ids)))
			prim.put_u32le(out[at + 4:], u32(n))
			at += 8
			prim.put_u64le(out[at:], xxhash.XXH3_64_default(out[:at]))
			gen = ix.man.next_gen
			buf: Name_Buf
			if e := prim.replace_atomic(ix.vfs, zd_path(ix, gen, &buf), out[:at + 8]); e != .None {
				return _perr(e)
			}
		}
	}
	if gen == 0 && ix.man.zd_gen == 0 {
		return .None
	}
	old_gen, old_next := ix.man.zd_gen, ix.man.next_gen
	ix.man.zd_gen = gen
	if gen != 0 {
		ix.man.next_gen = gen + 1
	}
	if e := manifest_write(ix); e != .None {
		ix.man.zd_gen, ix.man.next_gen = old_gen, old_next
		if gen != 0 {
			buf: Name_Buf
			_ = prim.remove(ix.vfs, zd_path(ix, gen, &buf))
		}
		return e
	}
	ix.taint_check = true
	return .None
}

frame_write :: proc(ix: ^Index, w: ^prim.Writer, raw: []u8, scratch: ^[dynamic]u8) -> Error {
	z := &ix.zstd
	if !_zstd_ready(z) {
		prim.write_uvarint(w, u64(len(raw)))
		prim.write_u8(w, FRAME_RAW)
		prim.write_uvarint(w, u64(len(raw)))
		start := len(w.buf)
		prim.write_raw(w, raw)
		if w.err == .None {
			prim.write_u32le(w, xxhash.XXH32(w.buf[start:]))
		}
		return _cerr(w.err)
	}
	sl := _zstd_dict(ix, ix.man.zd_gen) or_return
	if z.cctx == nil {
		z.cctx = ZSTD_createCCtx()
		if z.cctx == nil {
			return .No_Memory
		}
	}
	bound := int(ZSTD_compressBound(c.size_t(len(raw))))
	if grow(scratch, bound) != nil {
		return .No_Memory
	}
	mode := FRAME_ZSTD
	got: c.size_t
	if sl != nil {
		mode = FRAME_DICT
		got = ZSTD_compress_usingCDict(z.cctx, raw_data(scratch[:]), c.size_t(bound), raw_data(raw), c.size_t(len(raw)), sl.cdict)
	} else {
		got = ZSTD_compressCCtx(z.cctx, raw_data(scratch[:]), c.size_t(bound), raw_data(raw), c.size_t(len(raw)), ZSTD_LEVEL)
	}
	payload := raw
	if ZSTD_isError(got) == 0 && int(got) < len(raw) {
		payload = scratch[:int(got)]
	} else {
		mode = FRAME_RAW
	}
	prim.write_uvarint(w, u64(len(raw)))
	prim.write_u8(w, mode)
	prim.write_uvarint(w, u64(len(payload)))
	start := len(w.buf)
	prim.write_raw(w, payload)
	if w.err == .None {
		prim.write_u32le(w, xxhash.XXH32(w.buf[start:]))
	}
	return _cerr(w.err)
}

@(private)
_frame_header :: proc(c: ^Cache, s: ^Seg, at: i64) -> (raw: int, mode: u8, plen: int, hdr: int, err: Error) {
	end := s.f.text_off + s.f.text_len
	if at < s.f.text_off || at >= end {
		return 0, 0, 0, 0, .Corrupt
	}
	hb: [24]u8
	hn := min(i64(len(hb)), end - at)
	cache_read(c, s, at, hb[:hn]) or_return
	pos := 0
	r, ok1 := uv(hb[:hn], &pos)
	if !ok1 || pos >= int(hn) {
		return 0, 0, 0, 0, .Corrupt
	}
	mode = hb[pos]
	pos += 1
	p, ok2 := uv(hb[:hn], &pos)
	if !ok2 || r > CHUNK + FRAME || mode > FRAME_DICT || (mode == FRAME_RAW && p != r) || p > r + 1024 {
		return 0, 0, 0, 0, .Corrupt
	}
	if at + i64(pos) + i64(p) + 4 > end {
		return 0, 0, 0, 0, .Corrupt
	}
	return int(r), mode, int(p), pos, .None
}

frame_size :: proc(c: ^Cache, s: ^Seg, at: i64) -> (size: i64, err: Error) {
	_, _, p, hdr := _frame_header(c, s, at) or_return
	return i64(hdr + p + 4), .None
}

frame_read :: proc(ix: ^Index, s: ^Seg, at: i64, out: ^[dynamic]u8, scratch: ^[dynamic]u8) -> Error {
	raw, mode, plen, hdr := _frame_header(&ix.cache, s, at) or_return
	ddict: rawptr
	if grow(scratch, plen + 4) != nil || grow(out, raw) != nil {
		return .No_Memory
	}
	cache_read(&ix.cache, s, at + i64(hdr), scratch[:]) or_return
	payload := scratch[:plen]
	if xxhash.XXH32(payload) != prim.get_u32le(scratch[plen:]) {
		return .Corrupt
	}
	switch mode {
	case FRAME_RAW:
		copy(out[:], payload)
		return .None
	case FRAME_DICT:
		sl := _zstd_dict(ix, s.f.zd_gen) or_return
		if sl == nil {
			return .Corrupt
		}
		ddict = sl.ddict
	}
	z := &ix.zstd
	if !_zstd_ready(z) {
		return .Io
	}
	if z.dctx == nil {
		z.dctx = ZSTD_createDCtx()
		if z.dctx == nil {
			return .No_Memory
		}
	}
	got: c.size_t
	if mode == FRAME_DICT {
		got = ZSTD_decompress_usingDDict(z.dctx, raw_data(out[:]), c.size_t(raw), raw_data(payload), c.size_t(plen), ddict)
	} else {
		got = ZSTD_decompressDCtx(z.dctx, raw_data(out[:]), c.size_t(raw), raw_data(payload), c.size_t(plen))
	}
	if ZSTD_isError(got) != 0 || int(got) != raw {
		return .Corrupt
	}
	return .None
}

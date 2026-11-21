package search

import "core:c"
import "core:dynlib"
import "core:hash/xxhash"
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

Zstd :: struct {
	cctx:  rawptr,
	dctx:  rawptr,
	cdict: rawptr,
	ddict:  rawptr,
	gen:    u64,
	loaded: bool,
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
	if z.cdict != nil {
		ZSTD_freeCDict(z.cdict)
	}
	if z.ddict != nil {
		ZSTD_freeDDict(z.ddict)
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

@(private)
_zstd_dict :: proc(ix: ^Index) -> Error {
	z := &ix.zstd
	if ix.man.zd_gen == 0 || z.gen == ix.man.zd_gen {
		return .None
	}
	if !_zstd_ready(z) {
		return .Io
	}
	buf: Name_Buf
	data, rerr := prim.read_file(ix.vfs, zd_path(ix, ix.man.zd_gen, &buf), context.temp_allocator)
	if rerr != .None {
		return .Corrupt if rerr == .Not_Found else _perr(rerr)
	}
	if len(data) < 12 || xxhash.XXH3_64_default(data[:len(data) - 8]) != prim.get_u64le(data[len(data) - 8:]) {
		return .Corrupt
	}
	d := data[:len(data) - 8]
	if z.cdict != nil {
		ZSTD_freeCDict(z.cdict)
		z.cdict = nil
	}
	if z.ddict != nil {
		ZSTD_freeDDict(z.ddict)
		z.ddict = nil
	}
	z.cdict = ZSTD_createCDict(raw_data(d), c.size_t(len(d)), ZSTD_LEVEL)
	z.ddict = ZSTD_createDDict(raw_data(d), c.size_t(len(d)))
	if z.cdict == nil || z.ddict == nil {
		return .No_Memory
	}
	z.gen = ix.man.zd_gen
	return .None
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
	if total < DICT_SAMPLE_MIN {
		return .None
	}
	samples := make([dynamic]u8, 0, min(total, DICT_SAMPLE_MAX), context.temp_allocator)
	sizes := make([dynamic]c.size_t, context.temp_allocator)
	for d in m.docs {
		if d.flags & DF_TEXT == 0 || d.flags & DF_DELETED != 0 || d.len < 8 {
			continue
		}
		if len(samples) >= DICT_SAMPLE_MAX {
			break
		}
		at := int(m.frames[d.frame]) + int(d.frame_off)
		n := min(int(d.len), DICT_SAMPLE_PIECE)
		append(&samples, ..m.raw[at:][:n])
		append(&sizes, c.size_t(n))
	}
	dict := make([]u8, DICT_CAP + 8, context.temp_allocator)
	got := ZDICT_trainFromBuffer(raw_data(dict), DICT_CAP, raw_data(samples), raw_data(sizes), c.uint(len(sizes)))
	if ZDICT_isError(got) != 0 {
		return .None
	}
	n := int(got)
	prim.put_u64le(dict[n:], xxhash.XXH3_64_default(dict[:n]))
	gen := ix.man.next_gen
	buf: Name_Buf
	if e := prim.replace_atomic(ix.vfs, zd_path(ix, gen, &buf), dict[:n + 8]); e != .None {
		return _perr(e)
	}
	old_gen, old_next := ix.man.zd_gen, ix.man.next_gen
	ix.man.zd_gen = gen
	ix.man.next_gen = gen + 1
	if e := manifest_write(ix); e != .None {
		ix.man.zd_gen, ix.man.next_gen = old_gen, old_next
		_ = prim.remove(ix.vfs, zd_path(ix, gen, &buf))
		return e
	}
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
	_zstd_dict(ix) or_return
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
	if z.cdict != nil {
		mode = FRAME_DICT
		got = ZSTD_compress_usingCDict(z.cctx, raw_data(scratch[:]), c.size_t(bound), raw_data(raw), c.size_t(len(raw)), z.cdict)
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
		_zstd_dict(ix) or_return
		if ix.zstd.ddict == nil {
			return .Corrupt
		}
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
		got = ZSTD_decompress_usingDDict(z.dctx, raw_data(out[:]), c.size_t(raw), raw_data(payload), c.size_t(plen), z.ddict)
	} else {
		got = ZSTD_decompressDCtx(z.dctx, raw_data(out[:]), c.size_t(raw), raw_data(payload), c.size_t(plen))
	}
	if ZSTD_isError(got) != 0 || int(got) != raw {
		return .Corrupt
	}
	return .None
}

package search

import "base:runtime"
import "core:hash/xxhash"
import "core:slice"
import "../prim"

KV_BLOCK :: 32
MAX_FILE_KEY :: 4096
MAX_VALUE :: 64 * 1024 * 1024

Kv :: enum u8 {
	Files,
	Scopes,
}

Kv_Writer :: struct {
	sw:      ^Seg_Writer,
	which:   Kv,
	blk:     [dynamic]u8,
	n:       int,
	prev:    [dynamic]u8,
	first:   [dynamic]u8,
	ix:      [dynamic]u8,
	ix_prev: i64,
	start:   i64,
}

kvw_begin :: proc(kw: ^Kv_Writer, sw: ^Seg_Writer, which: Kv, allocator: runtime.Allocator) {
	kw^ = {
		sw    = sw,
		which = which,
		start = sw_off(sw),
	}
	kw.blk = make([dynamic]u8, allocator)
	kw.prev = make([dynamic]u8, allocator)
	kw.first = make([dynamic]u8, allocator)
	kw.ix = make([dynamic]u8, allocator)
	kw.ix_prev = kw.start
}

kvw_destroy :: proc(kw: ^Kv_Writer) {
	delete(kw.blk)
	delete(kw.prev)
	delete(kw.first)
	delete(kw.ix)
}

kvw_put :: proc(kw: ^Kv_Writer, key, val: []u8) {
	if kw.n == 0 {
		clear(&kw.blk)
		clear(&kw.prev)
		clear(&kw.first)
		append(&kw.first, ..key)
		append(&kw.blk, 0)
	}
	shared := 0
	for shared < len(key) && shared < len(kw.prev) && key[shared] == kw.prev[shared] {
		shared += 1
	}
	w := prim.writer(&kw.blk)
	prim.write_uvarint(&w, u64(shared))
	prim.write_bytes(&w, key[shared:])
	prim.write_bytes(&w, val)
	if w.err != .None {
		kw.sw.out.err = .No_Memory
	}
	clear(&kw.prev)
	append(&kw.prev, ..key)
	kw.n += 1
	if kw.n == KV_BLOCK || len(kw.blk) > 256 * 1024 {
		_kvw_flush(kw)
	}
}

@(private)
_kvw_flush :: proc(kw: ^Kv_Writer) {
	if kw.n == 0 {
		return
	}
	kw.blk[0] = u8(kw.n)
	w := prim.writer(&kw.blk)
	prim.write_u32le(&w, xxhash.XXH32(kw.blk[:]))
	at := sw_off(kw.sw)
	sw_write(kw.sw, kw.blk[:])
	iw := prim.writer(&kw.ix)
	prim.write_bytes(&iw, kw.first[:])
	prim.write_uvarint(&iw, u64(at - kw.ix_prev))
	prim.write_uvarint(&iw, u64(len(kw.blk)))
	if w.err != .None || iw.err != .None {
		kw.sw.out.err = .No_Memory
	}
	kw.ix_prev = at
	kw.n = 0
}

kvw_end :: proc(kw: ^Kv_Writer) {
	_kvw_flush(kw)
	sw := kw.sw
	end := sw_off(sw)
	ix_off := end
	sw_meta(sw, kw.ix[:])
	ix_len := sw_off(sw) - ix_off
	switch kw.which {
	case .Files:
		sw.f.kvf_off, sw.f.kvf_len = kw.start, end - kw.start
		sw.f.kvf_ix_off, sw.f.kvf_ix_len = ix_off, ix_len
	case .Scopes:
		sw.f.kvs_off, sw.f.kvs_len = kw.start, end - kw.start
		sw.f.kvs_ix_off, sw.f.kvs_ix_len = ix_off, ix_len
	}
}

kv_write_map_str :: proc(sw: ^Seg_Writer, m: ^map[string][]u8, which: Kv) {
	keys := make([]string, len(m), context.temp_allocator)
	i := 0
	for k in prim.unordered(m^) {
		keys[i] = k
		i += 1
	}
	slice.sort(keys)
	kw: Kv_Writer
	kvw_begin(&kw, sw, which, context.temp_allocator)
	for k in keys {
		kvw_put(&kw, transmute([]u8)k, m[k])
	}
	kvw_end(&kw)
}

kv_write_map_id :: proc(sw: ^Seg_Writer, m: ^map[prim.Id][]u8, which: Kv) {
	keys := make([]prim.Id, len(m), context.temp_allocator)
	i := 0
	for k in prim.unordered(m^) {
		keys[i] = k
		i += 1
	}
	slice.sort_by(keys, proc(a, b: prim.Id) -> bool {
		x, y := a, b
		return key_less(x[:], y[:])
	})
	kw: Kv_Writer
	kvw_begin(&kw, sw, which, context.temp_allocator)
	for k in keys {
		kk := k
		kvw_put(&kw, kk[:], m[k])
	}
	kvw_end(&kw)
}

Kv_Index :: struct {
	keys: [][]u8,
	offs: []i64,
	lens: []u32,
}

kv_span :: proc "contextless" (s: ^Seg, which: Kv) -> (off, n, ix_off, ix_n: i64) {
	switch which {
	case .Files:
		return s.f.kvf_off, s.f.kvf_len, s.f.kvf_ix_off, s.f.kvf_ix_len
	case .Scopes:
		return s.f.kvs_off, s.f.kvs_len, s.f.kvs_ix_off, s.f.kvs_ix_len
	}
	return
}

kv_index_load :: proc(s: ^Seg, which: Kv, allocator: runtime.Allocator) -> (k: Kv_Index, err: Error) {
	off, n, ix_off, ix_n := kv_span(s, which)
	if ix_n == 0 {
		return
	}
	raw := make([]u8, int(ix_n), allocator)
	got, rerr := prim.read_at(s.vfs, s.fd, raw, ix_off)
	if rerr != .None {
		return k, _perr(rerr)
	}
	if i64(got) != ix_n {
		return k, .Corrupt
	}
	keys := make([dynamic][]u8, allocator)
	offs := make([dynamic]i64, allocator)
	lens := make([dynamic]u32, allocator)
	r := prim.reader(raw)
	prev := off
	for !prim.reader_done(&r) {
		key := prim.read_bytes(&r)
		d := prim.read_uvarint(&r)
		ln := prim.read_uvarint(&r)
		if r.err != .None || ln < 5 || ln > MAX_VALUE * 2 || d > u64(n) {
			return k, .Corrupt
		}
		prev += i64(d)
		if prev + i64(ln) > off + n || (len(keys) > 0 && !key_less(keys[len(keys) - 1], key)) {
			return k, .Corrupt
		}
		append(&keys, key)
		append(&offs, prev)
		append(&lens, u32(ln))
	}
	if r.err != .None {
		return k, .Corrupt
	}
	return Kv_Index{keys[:], offs[:], lens[:]}, .None
}

Kv_Cursor :: struct {
	s:     ^Seg,
	ix:    Kv_Index,
	blk:   int,
	data:  [dynamic]u8,
	r:     prim.Reader,
	left:  int,
	key:   [dynamic]u8,
	val:   []u8,
	err:   Error,
}

kvc_init :: proc(kc: ^Kv_Cursor, s: ^Seg, which: Kv, allocator: runtime.Allocator) -> Error {
	kc^ = {
		s   = s,
		blk = -1,
	}
	kc.data = make([dynamic]u8, allocator)
	kc.key = make([dynamic]u8, allocator)
	ix, err := kv_index_load(s, which, allocator)
	kc.ix = ix
	return err
}

kvc_load :: proc(kc: ^Kv_Cursor, blk: int) -> bool {
	if blk >= len(kc.ix.keys) {
		kc.left = 0
		kc.blk = blk
		return false
	}
	n := int(kc.ix.lens[blk])
	if grow(&kc.data, n) != nil {
		kc.err = .No_Memory
		return false
	}
	got, e := prim.read_at(kc.s.vfs, kc.s.fd, kc.data[:], kc.ix.offs[blk])
	if e != .None {
		kc.err = _perr(e)
		return false
	}
	if got != n || xxhash.XXH32(kc.data[:n - 4]) != prim.get_u32le(kc.data[n - 4:]) {
		kc.err = .Corrupt
		return false
	}
	kc.blk = blk
	kc.r = prim.reader(kc.data[:n - 4])
	kc.left = int(prim.read_u8(&kc.r))
	clear(&kc.key)
	if kc.left == 0 {
		kc.err = .Corrupt
		return false
	}
	return true
}

kvc_next :: proc(kc: ^Kv_Cursor) -> bool {
	if kc.err != .None {
		return false
	}
	for kc.left == 0 {
		if !kvc_load(kc, kc.blk + 1) {
			return false
		}
	}
	shared := int(prim.read_uvarint(&kc.r))
	suffix := prim.read_bytes(&kc.r)
	val := prim.read_bytes(&kc.r)
	if kc.r.err != .None || shared > len(kc.key) || shared + len(suffix) > MAX_FILE_KEY {
		kc.err = .Corrupt
		return false
	}
	if grow(&kc.key, shared) != nil {
		kc.err = .No_Memory
		return false
	}
	append(&kc.key, ..suffix)
	kc.val = val
	kc.left -= 1
	if kc.left == 0 && !prim.reader_done(&kc.r) {
		kc.err = .Corrupt
		return false
	}
	return true
}

kv_get :: proc(s: ^Seg, which: Kv, key: []u8, allocator: runtime.Allocator) -> (val: []u8, found: bool, err: Error) {
	kc: Kv_Cursor
	kvc_init(&kc, s, which, context.temp_allocator) or_return
	lo, hi := 0, len(kc.ix.keys)
	for lo < hi {
		mid := (lo + hi) / 2
		if key_less(key, kc.ix.keys[mid]) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	if lo == 0 {
		return nil, false, .None
	}
	if !kvc_load(&kc, lo - 1) {
		return nil, false, kc.err
	}
	for kc.left > 0 && kvc_next(&kc) {
		c := key_cmp(kc.key[:], key)
		if c == 0 {
			out := make([]u8, len(kc.val), allocator)
			copy(out, kc.val)
			return out, true, .None
		}
		if c > 0 {
			break
		}
	}
	return nil, false, kc.err
}

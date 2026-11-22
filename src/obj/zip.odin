package obj

import "core:c"
import "../journal"
import "../prim"
import "../zstd"

ZIP_TAG :: 5
ZIP_HEAD_TAG :: 6
ZIP_SPLIT :: 64
ZIP_MIN :: 128
ZIP_LEVEL :: 3
ZIP_MAX :: journal.MAX_BODY
ZIP_MAGIC :: 0xFD2FB528

zip_frame_size :: proc "contextless" (f: []u8) -> (n: i64, ok: bool) {
	if len(f) < 6 || prim.get_u32le(f) != ZIP_MAGIC {
		return 0, false
	}
	fhd := f[4]
	if fhd & 0x08 != 0 {
		return 0, false
	}
	single := fhd & 0x20 != 0
	pos := 5 if single else 6
	dict := [4]int{0, 1, 2, 4}
	sizes := [4]int{1 if single else 0, 2, 4, 8}
	pos += dict[fhd & 3]
	size := sizes[fhd >> 6]
	if size == 0 || pos + size > len(f) {
		return 0, false
	}
	v: u64
	switch size {
	case 1:
		v = u64(f[pos])
	case 2:
		v = (u64(f[pos]) | u64(f[pos + 1]) << 8) + 256
	case 4:
		v = u64(prim.get_u32le(f[pos:]))
	case 8:
		v = prim.get_u64le(f[pos:])
	}
	if v == 0 || v > ZIP_MAX {
		return 0, false
	}
	return i64(v), true
}

fields_head :: proc "contextless" (e: ^Envelope) -> []u8 {
	if e.links.zraw == 0 {
		return e.fields
	}
	return e.fields[:e.links.zhead]
}

inflate :: proc(e: ^Envelope, allocator := context.temp_allocator) -> Error {
	n := e.links.zraw
	if n == 0 {
		return .None
	}
	h := e.links.zhead
	if h < 0 || h >= i64(len(e.fields)) || h + n > ZIP_MAX {
		return .Corrupt
	}
	frame := e.fields[h:]
	if fs, ok := zip_frame_size(frame); !ok || fs != n {
		return .Corrupt
	}
	out, aerr := make([]u8, int(h + n), allocator)
	if aerr != nil {
		return .No_Memory
	}
	copy(out, e.fields[:h])
	d := zstd.ZSTD_createDCtx()
	if d == nil {
		delete(out, allocator)
		return .No_Memory
	}
	got := zstd.ZSTD_decompressDCtx(d, raw_data(out[h:]), c.size_t(n), raw_data(frame), c.size_t(len(frame)))
	zstd.ZSTD_freeDCtx(d)
	if zstd.ZSTD_isError(got) != 0 || i64(got) != n {
		delete(out, allocator)
		return .Corrupt
	}
	e.fields = out
	e.links.zraw = 0
	e.links.zhead = 0
	return .None
}

@(private)
_zip :: proc(rec: ^Rec) {
	buf := rec.pw.buf
	if rec.pw.err != .None || rec.fields_at <= rec.links_at || rec.fields_at > len(buf) {
		return
	}
	all := buf[rec.fields_at:]
	if len(all) > ZIP_MAX {
		return
	}
	fr := prim.reader(all)
	head := 0
	for {
		_, ok := next_field(&fr)
		if !ok || fr.pos - head >= ZIP_SPLIT {
			break
		}
		head = fr.pos
	}
	if fr.err != .None {
		return
	}
	fields := all[head:]
	n := len(fields)
	if n < ZIP_MIN {
		return
	}
	bound := int(zstd.ZSTD_compressBound(c.size_t(n)))
	tmp, aerr := make([]u8, bound, context.temp_allocator)
	if aerr != nil {
		return
	}
	cctx := zstd.ZSTD_createCCtx()
	if cctx == nil {
		return
	}
	got := zstd.ZSTD_compressCCtx(cctx, raw_data(tmp), c.size_t(bound), raw_data(fields), c.size_t(n), ZIP_LEVEL)
	zstd.ZSTD_freeCCtx(cctx)
	if zstd.ZSTD_isError(got) != 0 {
		return
	}
	frame := tmp[:int(got)]
	if fs, ok := zip_frame_size(frame); !ok || fs != i64(n) {
		return
	}
	lb: [dynamic]u8
	lb.allocator = context.temp_allocator
	lw := prim.writer(&lb)
	l := rec.links
	l.extra = rec.extra
	l.zraw = i64(n)
	l.zhead = i64(head)
	encode_links(&lw, rec.off, &l)
	prim.write_raw(&lw, all[:head])
	if lw.err != .None || len(lb) + len(frame) > rec.fields_at - rec.links_at + head + n - n / 8 {
		return
	}
	resize(buf, rec.links_at)
	prim.write_raw(&rec.pw, lb[:])
	prim.write_raw(&rec.pw, frame)
}

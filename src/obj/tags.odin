package obj

import "../prim"

F_UV :: 0
F_64 :: 1
F_BYTES :: 2

Field :: struct {
	tag: u32,
	ty:  u8,
	uv:  u64,
	b:   []u8,
}

Fixed :: struct {
	buf: [128]u8,
	n:   int,
	bad: bool,
}

@(private)
_key :: proc(w: ^prim.Writer, tag: u32, ty: u8) {
	prim.write_uvarint(w, u64(tag) << 2 | u64(ty))
}

tw_uv :: proc(w: ^prim.Writer, tag: u32, v: u64) {
	if v == 0 {
		return
	}
	_key(w, tag, F_UV)
	prim.write_uvarint(w, v)
}

tw_u64 :: proc(w: ^prim.Writer, tag: u32, v: u64) {
	if v == 0 {
		return
	}
	_key(w, tag, F_64)
	prim.write_u64le(w, v)
}

tw_bytes :: proc(w: ^prim.Writer, tag: u32, b: []u8) {
	if len(b) == 0 {
		return
	}
	_key(w, tag, F_BYTES)
	prim.write_bytes(w, b)
}

tw_str :: proc(w: ^prim.Writer, tag: u32, s: string) {
	tw_bytes(w, tag, transmute([]u8)s)
}

tw_id :: proc(w: ^prim.Writer, tag: u32, id: prim.Id) {
	if prim.id_is_zero(id) {
		return
	}
	v := id
	tw_bytes(w, tag, v[:])
}

tw_bool :: proc(w: ^prim.Writer, tag: u32, v: bool) {
	tw_uv(w, tag, 1 if v else 0)
}

tw_ref :: proc(w: ^prim.Writer, tag: u32, self: i64, r: Ref) {
	if ref_none(r) {
		return
	}
	f: Fixed
	fx_ref(&f, self, r)
	tw_bytes(w, tag, f.buf[:f.n])
}

tw_fixed :: proc(w: ^prim.Writer, tag: u32, f: ^Fixed) {
	if f.n == 0 {
		return
	}
	_key(w, tag, F_BYTES)
	prim.write_bytes(w, f.buf[:f.n])
}

fx_uv :: proc "contextless" (f: ^Fixed, v: u64) {
	if f.n + 10 > len(f.buf) {
		f.bad = true
		return
	}
	f.n += prim.put_uvarint(f.buf[f.n:], v)
}

fx_u64 :: proc "contextless" (f: ^Fixed, v: u64) {
	if f.n + 8 > len(f.buf) {
		f.bad = true
		return
	}
	prim.put_u64le(f.buf[f.n:], v)
	f.n += 8
}

fx_raw :: proc "contextless" (f: ^Fixed, b: []u8) {
	if f.n + len(b) > len(f.buf) {
		f.bad = true
		return
	}
	f.n += copy(f.buf[f.n:], b)
}

fx_ref :: proc "contextless" (f: ^Fixed, self: i64, r: Ref) {
	if ref_none(r) {
		fx_uv(f, 0)
		fx_uv(f, 0)
		return
	}
	fx_uv(f, u64(r.seg))
	if r.seg == 0 {
		fx_uv(f, u64(self - r.off + 1) if r.off <= self else 0)
	} else {
		fx_uv(f, u64(r.off))
	}
}

next_field :: proc "contextless" (r: ^prim.Reader) -> (f: Field, ok: bool) {
	if r.err != .None || prim.reader_remaining(r) == 0 {
		return
	}
	key := prim.read_uvarint(r)
	if key >> 2 > u64(max(u32)) {
		prim.reader_fail(r, .Invalid)
		return
	}
	f.tag = u32(key >> 2)
	f.ty = u8(key & 3)
	switch f.ty {
	case F_UV:
		f.uv = prim.read_uvarint(r)
	case F_64:
		f.uv = prim.read_u64le(r)
	case F_BYTES:
		f.b = prim.read_bytes(r)
	case:
		prim.reader_fail(r, .Invalid)
		return
	}
	return f, r.err == .None
}

read_ref :: proc "contextless" (r: ^prim.Reader, self: i64) -> (ref: Ref, ok: bool) {
	seg := prim.read_uvarint(r)
	v := prim.read_uvarint(r)
	if r.err != .None || seg >= MAX_SEGS {
		return {}, false
	}
	if v == 0 {
		return {}, true
	}
	if seg == 0 {
		if v > u64(self) || self <= 0 {
			return {}, false
		}
		return Ref{0, self - i64(v) + 1}, true
	}
	if v > u64(max(i64)) {
		return {}, false
	}
	return Ref{u32(seg), i64(v)}, true
}

field_ref :: proc "contextless" (f: Field, self: i64) -> (ref: Ref, ok: bool) {
	if f.ty != F_BYTES {
		return {}, false
	}
	r := prim.reader(f.b)
	ref, ok = read_ref(&r, self)
	return ref, ok && prim.reader_done(&r)
}

field_own :: proc "contextless" (f: Field, self: i64, strict: bool) -> (off: i64, ok: bool) {
	ref := field_ref(f, self) or_return
	if ref.seg != 0 || (strict && ref.off >= self) {
		return 0, false
	}
	return ref.off, true
}

field_id :: proc "contextless" (f: Field) -> (id: prim.Id, ok: bool) {
	if f.ty != F_BYTES || len(f.b) != 16 {
		return {}, false
	}
	copy(id[:], f.b)
	return id, true
}

field_oid :: proc "contextless" (f: Field) -> ([]u8, bool) {
	if f.ty != F_BYTES || (len(f.b) != 20 && len(f.b) != 32) {
		return nil, false
	}
	return f.b, true
}

Dec :: struct {
	r:    prim.Reader,
	off:  i64,
	bad:  bool,
	f:    Field,
}

dec_next :: proc "contextless" (d: ^Dec) -> bool {
	f, ok := next_field(&d.r)
	if !ok {
		if d.r.err != .None {
			d.bad = true
		}
		return false
	}
	d.f = f
	return true
}

dec_ref :: proc "contextless" (d: ^Dec) -> Ref {
	r, ok := field_ref(d.f, d.off)
	if !ok {
		d.bad = true
	}
	return r
}

dec_own :: proc "contextless" (d: ^Dec, strict := true) -> i64 {
	r, ok := field_own(d.f, d.off, strict)
	if !ok {
		d.bad = true
	}
	return r
}

dec_uv :: proc "contextless" (d: ^Dec) -> u64 {
	if d.f.ty != F_UV {
		d.bad = true
	}
	return d.f.uv
}

dec_u64 :: proc "contextless" (d: ^Dec) -> u64 {
	if d.f.ty != F_64 {
		d.bad = true
	}
	return d.f.uv
}

dec_bytes :: proc "contextless" (d: ^Dec) -> []u8 {
	if d.f.ty != F_BYTES {
		d.bad = true
	}
	return d.f.b
}

dec_id :: proc "contextless" (d: ^Dec) -> prim.Id {
	id, ok := field_id(d.f)
	if !ok {
		d.bad = true
	}
	return id
}

dec_enum :: proc "contextless" (d: ^Dec, lo, hi: u8) -> u8 {
	v := dec_uv(d)
	if v < u64(lo) || v > u64(hi) {
		d.bad = true
		return lo
	}
	return u8(v)
}

dec_oid :: proc "contextless" (d: ^Dec) -> []u8 {
	b, ok := field_oid(d.f)
	if !ok {
		d.bad = true
	}
	return b
}


dec_init :: proc "contextless" (data: []u8, off: i64) -> Dec {
	return Dec{r = prim.reader(data), off = off}
}

dec_str :: proc "contextless" (d: ^Dec) -> string {
	return string(dec_bytes(d))
}

dec_hlc :: proc "contextless" (d: ^Dec) -> prim.Hlc {
	return prim.Hlc(dec_u64(d))
}

dec_int :: proc "contextless" (d: ^Dec) -> i64 {
	return i64(min(dec_uv(d), 1 << 62))
}

dec_ok :: proc "contextless" (d: ^Dec) -> bool {
	return !d.bad && d.r.err == .None
}

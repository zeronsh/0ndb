package obj

import "../prim"

Links :: struct {
	event: i64,
	segs:  i64,
	prev:  i64,
	stamp: prim.Hlc,
	zraw:  i64,
	zhead: i64,
	gen:   u64,
	extra: []u8,
}

Head :: struct {
	object:   prim.Id,
	kind:     Kind,
	format:   u64,
	seg:      prim.Id,
	created:  prim.Hlc,
	settings: []u8,
}

Seg_Entry :: struct {
	index: u32,
	id:    prim.Id,
}

Redact :: struct {
	from:   Ref,
	to:     i64,
	target: Ref,
	cmd:    prim.Id,
}

Envelope :: struct {
	off:    i64,
	kind:   u8,
	links:  Links,
	fields: []u8,
}

links_is_event :: proc "contextless" (l: ^Links) -> bool {
	return l.stamp != 0
}

encode_links :: proc(w: ^prim.Writer, off: i64, l: ^Links) {
	buf: [dynamic]u8
	buf.allocator = context.temp_allocator
	lw := prim.writer(&buf)
	tw_ref(&lw, 1, off, Ref{0, l.event})
	tw_ref(&lw, 2, off, Ref{0, l.segs})
	tw_ref(&lw, 3, off, Ref{0, l.prev})
	tw_u64(&lw, 4, u64(l.stamp))
	tw_uv(&lw, ZIP_TAG, u64(max(l.zraw, 0)))
	tw_uv(&lw, ZIP_HEAD_TAG, u64(max(l.zhead, 0)))
	tw_uv(&lw, GEN_TAG, l.gen)
	prim.write_raw(&lw, l.extra)
	if lw.err != .None {
		w.err = lw.err
		return
	}
	prim.write_bytes(w, buf[:])
}

decode_envelope :: proc "contextless" (body: []u8, off: i64) -> (e: Envelope, err: Error) {
	r := prim.reader(body)
	e.off = off
	e.kind = prim.read_u8(&r)
	lb := prim.read_bytes(&r)
	if r.err != .None || e.kind == 0 {
		return e, .Corrupt
	}
	lr := prim.reader(lb)
	for {
		start := lr.pos
		f, ok := next_field(&lr)
		if !ok {
			break
		}
		if f.tag >= LINKS_KIND_TAG {
			e.links.extra = lb[start:]
			break
		}
		switch f.tag {
		case 1, 2, 3:
			v, vok := field_own(f, off, f.tag == 3)
			if !vok {
				return e, .Corrupt
			}
			switch f.tag {
			case 1:
				e.links.event = v
			case 2:
				e.links.segs = v
			case 3:
				e.links.prev = v
			}
		case 4:
			if f.ty != F_64 {
				return e, .Corrupt
			}
			e.links.stamp = prim.Hlc(f.uv)
		case ZIP_TAG:
			if f.ty != F_UV || f.uv == 0 || f.uv > ZIP_MAX || e.kind < RECORD_KIND_FIRST {
				return e, .Corrupt
			}
			e.links.zraw = i64(f.uv)
		case ZIP_HEAD_TAG:
			if f.ty != F_UV || f.uv == 0 || f.uv > ZIP_MAX {
				return e, .Corrupt
			}
			e.links.zhead = i64(f.uv)
		case GEN_TAG:
			if f.ty != F_UV {
				return e, .Corrupt
			}
			e.links.gen = f.uv
		case:
			return e, .Unsupported
		}
	}
	if lr.err != .None {
		return e, .Corrupt
	}
	e.fields = prim.read_rest(&r)
	if e.links.zraw == 0 ? e.links.zhead != 0 : e.links.zhead >= i64(len(e.fields)) {
		return e, .Corrupt
	}
	return e, .None
}

encode_head :: proc(w: ^prim.Writer, h: ^Head, gen: u64) {
	prim.write_u8(w, RECORD_HEAD)
	l := Links{gen = gen}
	encode_links(w, 0, &l)
	tw_id(w, 1, h.object)
	tw_uv(w, 2, u64(h.kind))
	tw_uv(w, 3, h.format)
	tw_id(w, 4, h.seg)
	tw_u64(w, 5, u64(h.created))
	prim.write_raw(w, h.settings)
}

decode_head :: proc(e: ^Envelope) -> (h: Head, err: Error) {
	if e.kind != RECORD_HEAD || e.off != 0 || e.links.zraw != 0 {
		return h, .Corrupt
	}
	d := dec_init(e.fields, 0)
	for {
		start := d.r.pos
		if !dec_next(&d) {
			break
		}
		if d.f.tag >= LINKS_KIND_TAG {
			h.settings = e.fields[start:]
			break
		}
		switch d.f.tag {
		case 1:
			h.object = dec_id(&d)
		case 2:
			h.kind = Kind(dec_enum(&d, 1, u8(max(Kind))))
		case 3:
			h.format = dec_uv(&d)
		case 4:
			h.seg = dec_id(&d)
		case 5:
			h.created = dec_hlc(&d)
		}
	}
	if !dec_ok(&d) || h.format == 0 {
		return h, .Corrupt
	}
	if h.format > FORMAT_VERSION {
		return h, .Unsupported
	}
	return h, .None
}

encode_seg :: proc(w: ^prim.Writer, off: i64, l: ^Links, entries: []Seg_Entry) {
	prim.write_u8(w, RECORD_SEG)
	encode_links(w, off, l)
	for e in entries {
		f: Fixed
		fx_uv(&f, u64(e.index))
		id := e.id
		fx_raw(&f, id[:])
		tw_fixed(w, 1, &f)
	}
}

decode_seg :: proc(e: ^Envelope, out: ^[dynamic]prim.Id) -> Error {
	if e.kind != RECORD_SEG || e.links.zraw != 0 {
		return .Corrupt
	}
	d := dec_init(e.fields, e.off)
	for dec_next(&d) {
		if d.f.tag != 1 {
			continue
		}
		fr := prim.reader(dec_bytes(&d))
		idx := prim.read_uvarint(&fr)
		id := prim.read_id(&fr)
		if !prim.reader_done(&fr) || idx == 0 || idx >= MAX_SEGS {
			return .Corrupt
		}
		for int(idx) >= len(out) {
			append(out, prim.Id{})
		}
		out[idx] = id
	}
	if !dec_ok(&d) {
		return .Corrupt
	}
	return .None
}

decode_redact :: proc(e: ^Envelope) -> (r: Redact, err: Error) {
	if e.kind != RECORD_REDACT || e.links.zraw != 0 {
		return r, .Corrupt
	}
	d := dec_init(e.fields, e.off)
	for dec_next(&d) {
		switch d.f.tag {
		case 1:
			r.from = dec_ref(&d)
		case 2:
			r.to = dec_int(&d)
		case 3:
			r.target = dec_ref(&d)
		case 4:
			r.cmd = dec_id(&d)
		}
	}
	if !dec_ok(&d) || ref_none(r.from) || r.to <= r.from.off {
		return r, .Corrupt
	}
	return r, .None
}

package api

import "core:strconv"
import "core:unicode/utf8"
import "../../prim"

MAX_DEPTH :: 32

Out :: struct {
	buf:   ^[dynamic]u8,
	w:     prim.Writer,
	json:  bool,
	depth: int,
	stack: [MAX_DEPTH]u8,
	first: [MAX_DEPTH]bool,
}

out_init :: proc(o: ^Out, buf: ^[dynamic]u8, json: bool) {
	o^ = {
		buf  = buf,
		w    = prim.writer(buf),
		json = json,
	}
	if json {
		append(buf, '{')
		o.stack[0] = '}'
		o.first[0] = true
		o.depth = 1
	}
}

out_reset :: proc(o: ^Out) {
	clear(o.buf)
	out_init(o, o.buf, o.json)
}

out_finish :: proc(o: ^Out) -> []u8 {
	if o.json {
		for o.depth > 0 {
			o.depth -= 1
			append(o.buf, o.stack[o.depth])
		}
	}
	return o.buf[:]
}

@(private)
_key :: proc(o: ^Out, name: string) {
	if o.depth == 0 {
		return
	}
	d := o.depth - 1
	if !o.first[d] {
		append(o.buf, ',')
	}
	o.first[d] = false
	if o.stack[d] == '}' {
		json_string(o.buf, name)
		append(o.buf, ':')
	}
}

@(private)
_push :: proc(o: ^Out, open: u8, close: u8) {
	append(o.buf, open)
	if o.depth < MAX_DEPTH {
		o.stack[o.depth] = close
		o.first[o.depth] = true
		o.depth += 1
	}
}

o_obj :: proc(o: ^Out, name: string) {
	if o.json {
		_key(o, name)
		_push(o, '{', '}')
	}
}

o_arr :: proc(o: ^Out, name: string, n: int) {
	if o.json {
		_key(o, name)
		_push(o, '[', ']')
	} else {
		prim.write_uvarint(&o.w, u64(max(n, 0)))
	}
}

o_end :: proc(o: ^Out) {
	if o.json && o.depth > 1 {
		o.depth -= 1
		append(o.buf, o.stack[o.depth])
	}
}

o_bool :: proc(o: ^Out, name: string, v: bool) {
	if o.json {
		_key(o, name)
		append(o.buf, "true" if v else "false")
	} else {
		prim.write_bool(&o.w, v)
	}
}

o_u64 :: proc(o: ^Out, name: string, v: u64) {
	if o.json {
		_key(o, name)
		b: [32]u8
		append(o.buf, strconv.write_uint(b[:], v, 10))
	} else {
		prim.write_uvarint(&o.w, v)
	}
}

o_int :: proc(o: ^Out, name: string, v: int) {
	o_u64(o, name, u64(max(v, 0)))
}

o_i64 :: proc(o: ^Out, name: string, v: i64) {
	if o.json {
		_key(o, name)
		b: [32]u8
		append(o.buf, strconv.write_int(b[:], v, 10))
	} else {
		prim.write_ivarint(&o.w, v)
	}
}

o_f64 :: proc(o: ^Out, name: string, v: f64) {
	if o.json {
		_key(o, name)
		if v != v || v > 1e308 || v < -1e308 {
			append(o.buf, "0")
			return
		}
		b: [64]u8
		s := strconv.write_float(b[:], v, 'g', -1, 64)
		if len(s) > 0 && s[0] == '+' {
			s = s[1:]
		}
		append(o.buf, s)
	} else {
		prim.write_u64le(&o.w, transmute(u64)v)
	}
}

o_str :: proc(o: ^Out, name: string, s: string) {
	if o.json {
		_key(o, name)
		json_string(o.buf, s)
	} else {
		prim.write_str(&o.w, s)
	}
}

o_text :: proc(o: ^Out, name: string, b: []u8) {
	o_str(o, name, string(b))
}

o_bytes :: proc(o: ^Out, name: string, b: []u8) {
	if o.json {
		_key(o, name)
		append(o.buf, '"')
		for c in b {
			append(o.buf, HEX[c >> 4], HEX[c & 15])
		}
		append(o.buf, '"')
	} else {
		prim.write_bytes(&o.w, b)
	}
}

o_id :: proc(o: ^Out, name: string, id: prim.Id) {
	if o.json {
		_key(o, name)
		if prim.id_is_zero(id) {
			append(o.buf, "null")
			return
		}
		h := prim.id_hex(id)
		append(o.buf, '"')
		append(o.buf, ..h[:])
		append(o.buf, '"')
	} else {
		x := id
		prim.write_raw(&o.w, x[:])
	}
}

o_rid :: proc(o: ^Out, name: string, r: Rid) {
	if o.json {
		_key(o, name)
		if prim.id_is_zero(r.seg) {
			append(o.buf, "null")
			return
		}
		append(o.buf, '"')
		rid_text(o.buf, r)
		append(o.buf, '"')
	} else {
		x := r.seg
		prim.write_raw(&o.w, x[:])
		prim.write_ivarint(&o.w, r.off)
		prim.write_uvarint(&o.w, r.gen)
	}
}

o_object :: proc(o: ^Out, name: string, ob: Object) {
	if o.json {
		_key(o, name)
		if prim.id_is_zero(ob.id) {
			append(o.buf, "null")
			return
		}
		append(o.buf, '"')
		object_text(o.buf, ob)
		append(o.buf, '"')
	} else {
		a, b := ob.space, ob.id
		prim.write_raw(&o.w, a[:])
		prim.write_raw(&o.w, b[:])
	}
}

o_enum :: proc(o: ^Out, name: string, v: u64, names: []string) {
	if o.json {
		if v < u64(len(names)) && len(names[v]) > 0 {
			o_str(o, name, names[v])
			return
		}
		o_u64(o, name, v)
	} else {
		prim.write_uvarint(&o.w, v)
	}
}

o_raw_json :: proc(o: ^Out, name: string, raw: string) {
	if o.json {
		_key(o, name)
		append(o.buf, raw if len(raw) > 0 else "null")
	} else {
		prim.write_str(&o.w, raw)
	}
}

HEX := "0123456789abcdef"

json_string :: proc(buf: ^[dynamic]u8, s: string) {
	append(buf, '"')
	i := 0
	for i < len(s) {
		c := s[i]
		if c < 0x80 {
			switch c {
			case '"':
				append(buf, '\\', '"')
			case '\\':
				append(buf, '\\', '\\')
			case '\n':
				append(buf, '\\', 'n')
			case '\r':
				append(buf, '\\', 'r')
			case '\t':
				append(buf, '\\', 't')
			case:
				if c < 0x20 || c == 0x7f {
					append(buf, '\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15])
				} else {
					append(buf, c)
				}
			}
			i += 1
			continue
		}
		r, n := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && n <= 1 {
			append(buf, "\xef\xbf\xbd")
			i += 1
			continue
		}
		append(buf, s[i:i + n])
		i += n
	}
	append(buf, '"')
}

rid_text :: proc(buf: ^[dynamic]u8, r: Rid) {
	h := prim.id_hex(r.seg)
	append(buf, ..h[:])
	append(buf, ':')
	b: [32]u8
	append(buf, strconv.write_int(b[:], r.off, 10))
	append(buf, ':')
	append(buf, strconv.write_uint(b[:], r.gen, 10))
}

object_text :: proc(buf: ^[dynamic]u8, ob: Object) {
	a := prim.id_hex(ob.space)
	b := prim.id_hex(ob.id)
	append(buf, ..a[:])
	append(buf, '/')
	append(buf, ..b[:])
}

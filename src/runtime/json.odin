package rt

import "base:runtime"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

Buf :: [dynamic]u8

Json_Value :: json.Value

@(private)
HEX_DIGITS :: "0123456789abcdef"

jw_str :: proc(b: ^Buf, s: string) {
	append(b, '"')
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch c {
		case '"':
			append(b, `\"`)
		case '\\':
			append(b, `\\`)
		case '\n':
			append(b, `\n`)
		case '\r':
			append(b, `\r`)
		case '\t':
			append(b, `\t`)
		case:
			if c < 0x20 {
				hx := HEX_DIGITS
				append(b, `\u00`)
				append(b, hx[c >> 4])
				append(b, hx[c & 0xf])
			} else {
				append(b, c)
			}
		}
	}
	append(b, '"')
}

jw_sep :: proc(b: ^Buf) {
	if len(b) == 0 {
		return
	}
	switch b[len(b) - 1] {
	case '{', '[', ':':
	case:
		append(b, ',')
	}
}

jw_key :: proc(b: ^Buf, k: string) {
	jw_sep(b)
	jw_str(b, k)
	append(b, ':')
}

jw_kstr :: proc(b: ^Buf, k: string, v: string) {
	jw_key(b, k)
	jw_str(b, v)
}

jw_kint :: proc(b: ^Buf, k: string, v: i64) {
	jw_key(b, k)
	jw_int(b, v)
}

jw_kbool :: proc(b: ^Buf, k: string, v: bool) {
	jw_key(b, k)
	append(b, "true" if v else "false")
}

jw_kraw :: proc(b: ^Buf, k: string, raw: string) {
	jw_key(b, k)
	append(b, raw if len(raw) > 0 else "null")
}

jw_kf64 :: proc(b: ^Buf, k: string, v: f64) {
	jw_key(b, k)
	tmp: [64]u8
	append(b, strconv.write_float(tmp[:], v, 'f', -1, 64))
}

jw_int :: proc(b: ^Buf, v: i64) {
	tmp: [32]u8
	append(b, strconv.write_int(tmp[:], v, 10))
}

jw_open :: proc(b: ^Buf) {
	jw_sep(b)
	append(b, '{')
}

jw_kopen :: proc(b: ^Buf, k: string) {
	jw_key(b, k)
	append(b, '{')
}

jw_karr :: proc(b: ^Buf, k: string) {
	jw_key(b, k)
	append(b, '[')
}

jw_arr :: proc(b: ^Buf) {
	jw_sep(b)
	append(b, '[')
}

jw_close :: proc(b: ^Buf) {
	append(b, '}')
}

jw_end :: proc(b: ^Buf) {
	append(b, ']')
}

jw_item_str :: proc(b: ^Buf, s: string) {
	jw_sep(b)
	jw_str(b, s)
}

jw_value :: proc(b: ^Buf, v: json.Value) {
	jw_sep(b)
	_jw_value(b, v)
}

@(private)
_jw_value :: proc(b: ^Buf, v: json.Value) {
	switch x in v {
	case json.Null:
		append(b, "null")
	case json.Integer:
		jw_int(b, x)
	case json.Float:
		tmp: [64]u8
		append(b, strconv.write_float(tmp[:], x, 'f', -1, 64))
	case json.Boolean:
		append(b, "true" if x else "false")
	case json.String:
		jw_str(b, x)
	case json.Array:
		append(b, '[')
		for e, i in x {
			if i > 0 {
				append(b, ',')
			}
			_jw_value(b, e)
		}
		append(b, ']')
	case json.Object:
		append(b, '{')
		keys := make([dynamic]string, 0, len(x), context.temp_allocator)
		for k in x {
			append(&keys, k)
		}
		_sort_strings(keys[:])
		for k, i in keys {
			if i > 0 {
				append(b, ',')
			}
			jw_str(b, k)
			append(b, ':')
			_jw_value(b, x[k])
		}
		append(b, '}')
	case:
		append(b, "null")
	}
}

@(private)
_sort_strings :: proc(list: []string) {
	for i in 1 ..< len(list) {
		j := i
		for j > 0 && list[j] < list[j - 1] {
			list[j], list[j - 1] = list[j - 1], list[j]
			j -= 1
		}
	}
}

json_text :: proc(v: json.Value, allocator := context.temp_allocator) -> string {
	b := make(Buf, allocator)
	_jw_value(&b, v)
	return string(b[:])
}

json_parse :: proc(text: string) -> (v: json.Value, ok: bool) {
	if len(text) == 0 {
		return json.Object{}, true
	}
	p, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	if err != .None {
		return nil, false
	}
	return p, true
}

jget :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok {
		return o[key]
	}
	return nil
}

jstr :: proc(v: json.Value, key: string) -> string {
	if s, ok := jget(v, key).(json.String); ok {
		return s
	}
	return ""
}

jhas :: proc(v: json.Value, key: string) -> bool {
	if o, ok := v.(json.Object); ok {
		_, found := o[key]
		return found
	}
	return false
}

jint :: proc(v: json.Value, key: string, default_value: i64 = 0) -> i64 {
	#partial switch x in jget(v, key) {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	}
	return default_value
}

jf64 :: proc(v: json.Value, key: string) -> f64 {
	#partial switch x in jget(v, key) {
	case json.Integer:
		return f64(x)
	case json.Float:
		return x
	}
	return 0
}

jbool :: proc(v: json.Value, key: string, default_value := false) -> bool {
	if b, ok := jget(v, key).(json.Boolean); ok {
		return b
	}
	return default_value
}

jarr :: proc(v: json.Value, key: string) -> json.Array {
	if a, ok := jget(v, key).(json.Array); ok {
		return a
	}
	return nil
}

jstrs :: proc(v: json.Value, key: string, allocator := context.temp_allocator) -> []string {
	a := jarr(v, key)
	out := make([dynamic]string, 0, len(a), allocator)
	for e in a {
		if s, ok := e.(json.String); ok {
			append(&out, s)
		}
	}
	return out[:]
}

text_result :: proc(text: string, allocator := context.temp_allocator) -> string {
	b := make(Buf, allocator)
	append(&b, `[{"type":"text","text":`)
	jw_str(&b, text)
	append(&b, "}]")
	return string(b[:])
}

concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

clone :: proc(s: string, allocator: runtime.Allocator) -> string {
	if len(s) == 0 {
		return ""
	}
	out, _ := strings.clone(s, allocator)
	return out
}

clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(b) == 0 {
		return nil
	}
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}

utf8_clip :: proc(s: string, limit: int) -> (string, bool) {
	if len(s) <= limit {
		return s, false
	}
	n := max(limit, 0)
	for n > 0 && (s[n] & 0xc0) == 0x80 {
		n -= 1
	}
	return s[:n], true
}

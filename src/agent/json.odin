package agent

import "core:encoding/json"
import "core:slice"
import "core:strconv"
import "core:strings"

@(private)
parse_line :: proc(line: []u8) -> (json.Value, bool) {
	text := strings.trim_space(string(line))
	if len(text) == 0 || text[0] != '{' {
		return nil, false
	}
	v, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	if err != .None {
		return nil, false
	}
	if _, ok := v.(json.Object); !ok {
		return nil, false
	}
	return v, true
}

@(private)
get :: proc(v: json.Value, key: string) -> json.Value {
	if obj, ok := v.(json.Object); ok {
		return obj[key]
	}
	return nil
}

@(private)
has :: proc(v: json.Value, key: string) -> bool {
	if obj, ok := v.(json.Object); ok {
		return key in obj
	}
	return false
}

@(private)
str :: proc(v: json.Value) -> string {
	if s, ok := v.(json.String); ok {
		return s
	}
	return ""
}

@(private)
get_str :: proc(v: json.Value, key: string) -> string {
	return str(get(v, key))
}

@(private)
num :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer:
		return f64(n)
	case json.Float:
		return n
	}
	return 0
}

@(private)
get_u64 :: proc(v: json.Value, key: string) -> u64 {
	#partial switch n in get(v, key) {
	case json.Integer:
		return n > 0 ? u64(n) : 0
	case json.Float:
		return n > 0 ? u64(n) : 0
	}
	return 0
}

@(private)
get_bool :: proc(v: json.Value, key: string) -> bool {
	if b, ok := get(v, key).(json.Boolean); ok {
		return b
	}
	return false
}

@(private)
get_arr :: proc(v: json.Value, key: string) -> json.Array {
	if a, ok := get(v, key).(json.Array); ok {
		return a
	}
	return nil
}

@(private)
is_object :: proc(v: json.Value) -> bool {
	_, ok := v.(json.Object)
	return ok
}

@(private)
id_text :: proc(v: json.Value) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	#partial switch x in v {
	case json.Integer, json.String:
		write_value(&b, v)
	case json.Float:
		w_int(&b, i64(x))
	}
	return string(b[:])
}

@(private)
id_int :: proc(v: json.Value) -> (i64, bool) {
	#partial switch x in v {
	case json.Integer:
		return x, true
	case json.Float:
		return i64(x), true
	case json.String:
		n, ok := strconv.parse_i64(x)
		return n, ok
	}
	return 0, false
}

@(private)
to_json :: proc(v: json.Value) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	write_value(&b, v)
	return string(b[:])
}

@(private)
text_of :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case nil, json.Null:
		return ""
	case json.String:
		return x
	case json.Array:
		b := make([dynamic]u8, context.temp_allocator)
		for part in x {
			t := get_str(part, "text")
			if t == "" {
				if s, ok := part.(json.String); ok {
					t = s
				}
			}
			if t == "" {
				continue
			}
			if len(b) > 0 {
				append(&b, '\n')
			}
			append(&b, t)
		}
		return string(b[:])
	case json.Object:
		if t, ok := x["text"].(json.String); ok {
			return t
		}
		if c, ok := x["content"]; ok {
			return text_of(c)
		}
	}
	return to_json(v)
}

@(private)
write_value :: proc(b: ^[dynamic]u8, v: json.Value) {
	switch x in v {
	case nil, json.Null:
		append(b, "null")
	case json.Boolean:
		append(b, x ? "true" : "false")
	case json.Integer:
		w_int(b, x)
	case json.Float:
		buf: [64]u8
		append(b, strconv.write_float(buf[:], x, 'g', -1, 64, {}))
	case json.String:
		w_str(b, x)
	case json.Array:
		append(b, '[')
		for e, i in x {
			if i > 0 {
				append(b, ',')
			}
			write_value(b, e)
		}
		append(b, ']')
	case json.Object:
		keys := make([dynamic]string, 0, len(x), context.temp_allocator)
		for k in x {
			append(&keys, k)
		}
		slice.sort(keys[:])
		append(b, '{')
		for k, i in keys {
			if i > 0 {
				append(b, ',')
			}
			w_str(b, k)
			append(b, ':')
			write_value(b, x[k])
		}
		append(b, '}')
	}
}

@(private)
w_int :: proc(b: ^[dynamic]u8, n: i64) {
	buf: [32]u8
	append(b, strconv.write_int(buf[:], n, 10))
}

@(private)
w_str :: proc(b: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	append(b, '"')
	start := 0
	for i in 0 ..< len(s) {
		c := s[i]
		esc: string
		switch c {
		case '"':
			esc = `\"`
		case '\\':
			esc = `\\`
		case '\n':
			esc = `\n`
		case '\r':
			esc = `\r`
		case '\t':
			esc = `\t`
		case:
			if c >= 0x20 {
				continue
			}
		}
		append(b, s[start:i])
		if esc != "" {
			append(b, esc)
		} else {
			append(b, `\u00`)
			append(b, hex[c >> 4], hex[c & 0xf])
		}
		start = i + 1
	}
	append(b, s[start:])
	append(b, '"')
}

@(private)
sep :: proc(b: ^[dynamic]u8) {
	if len(b) == 0 {
		return
	}
	switch b[len(b) - 1] {
	case '{', '[', ':', ',', '\n':
		return
	}
	append(b, ',')
}

@(private)
key :: proc(b: ^[dynamic]u8, k: string) {
	sep(b)
	w_str(b, k)
	append(b, ':')
}

@(private)
f_str :: proc(b: ^[dynamic]u8, k: string, v: string) {
	key(b, k)
	w_str(b, v)
}

@(private)
f_int :: proc(b: ^[dynamic]u8, k: string, v: i64) {
	key(b, k)
	w_int(b, v)
}

@(private)
f_bool :: proc(b: ^[dynamic]u8, k: string, v: bool) {
	key(b, k)
	append(b, v ? "true" : "false")
}

@(private)
f_raw :: proc(b: ^[dynamic]u8, k: string, raw: string) {
	key(b, k)
	append(b, raw)
}

@(private)
f_obj :: proc(b: ^[dynamic]u8, k: string) {
	key(b, k)
	append(b, '{')
}

@(private)
f_arr :: proc(b: ^[dynamic]u8, k: string) {
	key(b, k)
	append(b, '[')
}

@(private)
open :: proc(b: ^[dynamic]u8) {
	sep(b)
	append(b, '{')
}

@(private)
close_obj :: proc(b: ^[dynamic]u8) {
	append(b, '}')
}

@(private)
close_arr :: proc(b: ^[dynamic]u8) {
	append(b, ']')
}

@(private)
end_line :: proc(b: ^[dynamic]u8) {
	append(b, '\n')
}

@(private)
f_text_input :: proc(b: ^[dynamic]u8, k: string, text: string, elements := false) {
	f_arr(b, k)
	open(b)
	f_str(b, "type", "text")
	f_str(b, "text", text)
	if elements {
		f_raw(b, "text_elements", "[]")
	}
	close_obj(b)
	close_arr(b)
}

@(private)
rpc_request :: proc(b: ^[dynamic]u8, id: i64, method: string, versioned := true) {
	append(b, '{')
	if versioned {
		f_str(b, "jsonrpc", "2.0")
	}
	f_int(b, "id", id)
	f_str(b, "method", method)
	f_obj(b, "params")
}

@(private)
rpc_notify :: proc(b: ^[dynamic]u8, method: string, versioned := true) {
	append(b, '{')
	if versioned {
		f_str(b, "jsonrpc", "2.0")
	}
	f_str(b, "method", method)
	f_obj(b, "params")
}

@(private)
rpc_end :: proc(b: ^[dynamic]u8) {
	append(b, "}}\n")
}

@(private)
rpc_result :: proc(b: ^[dynamic]u8, raw_id: string, raw_result: string, versioned := true) {
	append(b, '{')
	if versioned {
		f_str(b, "jsonrpc", "2.0")
	}
	f_raw(b, "id", raw_id)
	f_raw(b, "result", raw_result)
	append(b, "}\n")
}

@(private)
rpc_error :: proc(b: ^[dynamic]u8, raw_id: string, code: i64, message: string, versioned := true) {
	append(b, '{')
	if versioned {
		f_str(b, "jsonrpc", "2.0")
	}
	f_raw(b, "id", raw_id)
	f_obj(b, "error")
	f_int(b, "code", code)
	f_str(b, "message", message)
	append(b, "}}\n")
}

@(private)
rpc_error_message :: proc(v: json.Value) -> string {
	e := get(v, "error")
	if m := get_str(e, "message"); m != "" {
		detail := get_str(get(e, "data"), "message")
		if detail != "" && detail != m {
			return strings.concatenate({m, ": ", detail}, context.temp_allocator)
		}
		return m
	}
	if is_object(e) {
		return to_json(e)
	}
	return "request failed"
}

@(private)
put :: proc(b: ^[dynamic]u8, parts: ..string) {
	for part in parts {
		append(b, part)
	}
}

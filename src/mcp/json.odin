package mcp

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Json_Kind :: enum u8 {
	Invalid,
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

JSON_MAX_DEPTH :: 256

Json_Iter :: struct {
	s:     string,
	i:     int,
	first: bool,
	done:  bool,
}

@(private)
_ws :: proc "contextless" (s: string, i: int) -> int {
	j := i
	for j < len(s) {
		switch s[j] {
		case ' ', '\t', '\n', '\r':
			j += 1
		case:
			return j
		}
	}
	return j
}

json_trim :: proc "contextless" (s: string) -> string {
	a := _ws(s, 0)
	b := len(s)
	for b > a {
		switch s[b - 1] {
		case ' ', '\t', '\n', '\r':
			b -= 1
			continue
		}
		break
	}
	return s[a:b]
}

json_kind :: proc "contextless" (raw: string) -> Json_Kind {
	s := json_trim(raw)
	if len(s) == 0 {
		return .Invalid
	}
	switch s[0] {
	case '{':
		return .Object
	case '[':
		return .Array
	case '"':
		return .String
	case 't':
		return .True
	case 'f':
		return .False
	case 'n':
		return .Null
	case '-', '0' ..= '9':
		return .Number
	}
	return .Invalid
}

@(private)
_skip_string :: proc "contextless" (s: string, i: int) -> (int, bool) {
	j := i + 1
	for j < len(s) {
		c := s[j]
		switch {
		case c == '"':
			return j + 1, true
		case c == '\\':
			if j + 1 >= len(s) {
				return 0, false
			}
			switch s[j + 1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				j += 2
			case 'u':
				if j + 6 > len(s) {
					return 0, false
				}
				for k in j + 2 ..< j + 6 {
					if _hexval(s[k]) < 0 {
						return 0, false
					}
				}
				j += 6
			case:
				return 0, false
			}
		case c < 0x20:
			return 0, false
		case c < 0x80:
			j += 1
		case:
			r, n := utf8.decode_rune_in_string(s[j:])
			if r == utf8.RUNE_ERROR && n <= 1 {
				return 0, false
			}
			j += n
		}
	}
	return 0, false
}

@(private)
_skip_number :: proc "contextless" (s: string, i: int) -> (int, bool) {
	j := i
	if j < len(s) && s[j] == '-' {
		j += 1
	}
	if j >= len(s) {
		return 0, false
	}
	if s[j] == '0' {
		j += 1
	} else if s[j] >= '1' && s[j] <= '9' {
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j += 1
		}
	} else {
		return 0, false
	}
	if j < len(s) && s[j] == '.' {
		j += 1
		start := j
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j += 1
		}
		if j == start {
			return 0, false
		}
	}
	if j < len(s) && (s[j] == 'e' || s[j] == 'E') {
		j += 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j += 1
		}
		start := j
		for j < len(s) && s[j] >= '0' && s[j] <= '9' {
			j += 1
		}
		if j == start {
			return 0, false
		}
	}
	return j, true
}

@(private)
_skip_value :: proc "contextless" (s: string, i: int, depth: int) -> (int, bool) {
	j := _ws(s, i)
	if j >= len(s) || depth > JSON_MAX_DEPTH {
		return 0, false
	}
	switch s[j] {
	case '"':
		return _skip_string(s, j)
	case '{':
		j = _ws(s, j + 1)
		if j < len(s) && s[j] == '}' {
			return j + 1, true
		}
		for {
			j = _ws(s, j)
			if j >= len(s) || s[j] != '"' {
				return 0, false
			}
			k, ok := _skip_string(s, j)
			if !ok {
				return 0, false
			}
			j = _ws(s, k)
			if j >= len(s) || s[j] != ':' {
				return 0, false
			}
			j, ok = _skip_value(s, j + 1, depth + 1)
			if !ok {
				return 0, false
			}
			j = _ws(s, j)
			if j >= len(s) {
				return 0, false
			}
			if s[j] == '}' {
				return j + 1, true
			}
			if s[j] != ',' {
				return 0, false
			}
			j += 1
		}
	case '[':
		j = _ws(s, j + 1)
		if j < len(s) && s[j] == ']' {
			return j + 1, true
		}
		for {
			ok: bool
			j, ok = _skip_value(s, j, depth + 1)
			if !ok {
				return 0, false
			}
			j = _ws(s, j)
			if j >= len(s) {
				return 0, false
			}
			if s[j] == ']' {
				return j + 1, true
			}
			if s[j] != ',' {
				return 0, false
			}
			j += 1
		}
	case 't':
		if len(s) - j >= 4 && s[j:j + 4] == "true" {
			return j + 4, true
		}
	case 'f':
		if len(s) - j >= 5 && s[j:j + 5] == "false" {
			return j + 5, true
		}
	case 'n':
		if len(s) - j >= 4 && s[j:j + 4] == "null" {
			return j + 4, true
		}
	case '-', '0' ..= '9':
		return _skip_number(s, j)
	}
	return 0, false
}

json_valid :: proc "contextless" (raw: string) -> bool {
	end, ok := _skip_value(raw, 0, 0)
	return ok && _ws(raw, end) == len(raw)
}

json_object :: proc "contextless" (raw: string) -> (it: Json_Iter, ok: bool) {
	s := json_trim(raw)
	if len(s) < 2 || s[0] != '{' {
		return {done = true}, false
	}
	return Json_Iter{s = s, i = 1, first = true}, true
}

json_array :: proc "contextless" (raw: string) -> (it: Json_Iter, ok: bool) {
	s := json_trim(raw)
	if len(s) < 2 || s[0] != '[' {
		return {done = true}, false
	}
	return Json_Iter{s = s, i = 1, first = true}, true
}

@(private)
_iter_open :: proc "contextless" (it: ^Json_Iter, close: u8) -> bool {
	if it.done {
		return false
	}
	j := _ws(it.s, it.i)
	if j >= len(it.s) {
		it.done = true
		return false
	}
	if it.s[j] == close {
		it.done = true
		return false
	}
	if !it.first {
		if it.s[j] != ',' {
			it.done = true
			return false
		}
		j = _ws(it.s, j + 1)
	}
	it.first = false
	it.i = j
	return true
}

json_next_member :: proc "contextless" (it: ^Json_Iter) -> (key: string, value: string, ok: bool) {
	if !_iter_open(it, '}') {
		return
	}
	j := it.i
	if j >= len(it.s) || it.s[j] != '"' {
		it.done = true
		return
	}
	k, kok := _skip_string(it.s, j)
	if !kok {
		it.done = true
		return
	}
	key = it.s[j:k]
	j = _ws(it.s, k)
	if j >= len(it.s) || it.s[j] != ':' {
		it.done = true
		return
	}
	vs := _ws(it.s, j + 1)
	ve, vok := _skip_value(it.s, vs, 1)
	if !vok {
		it.done = true
		return
	}
	it.i = ve
	return key, it.s[vs:ve], true
}

json_next_item :: proc "contextless" (it: ^Json_Iter) -> (value: string, ok: bool) {
	if !_iter_open(it, ']') {
		return
	}
	vs := it.i
	ve, vok := _skip_value(it.s, vs, 1)
	if !vok {
		it.done = true
		return
	}
	it.i = ve
	return it.s[vs:ve], true
}

json_key_is :: proc "contextless" (key_raw: string, name: string) -> bool {
	if len(key_raw) < 2 {
		return false
	}
	inner := key_raw[1:len(key_raw) - 1]
	if strings.index_byte(inner, '\\') < 0 {
		return inner == name
	}
	buf: [256]u8
	n, ok := _unescape_into(inner, buf[:])
	return ok && string(buf[:n]) == name
}

json_get :: proc "contextless" (obj: string, name: string) -> (value: string, ok: bool) {
	it := json_object(obj) or_return
	for k, v in json_next_member(&it) {
		if json_key_is(k, name) {
			return v, true
		}
	}
	return "", false
}

json_has :: proc "contextless" (obj: string, name: string) -> bool {
	_, ok := json_get(obj, name)
	return ok
}

json_get_object :: proc "contextless" (obj: string, name: string) -> (string, bool) {
	v, ok := json_get(obj, name)
	if !ok || json_kind(v) != .Object {
		return "", false
	}
	return v, true
}

json_get_array :: proc "contextless" (obj: string, name: string) -> (string, bool) {
	v, ok := json_get(obj, name)
	if !ok || json_kind(v) != .Array {
		return "", false
	}
	return v, true
}

json_get_string :: proc(obj: string, name: string, allocator := context.temp_allocator) -> (string, bool) {
	v, ok := json_get(obj, name)
	if !ok {
		return "", false
	}
	return json_string(v, allocator)
}

json_get_int :: proc(obj: string, name: string) -> (i64, bool) {
	v, ok := json_get(obj, name)
	if !ok {
		return 0, false
	}
	return json_int(v)
}

json_get_bool :: proc "contextless" (obj: string, name: string) -> bool {
	v, ok := json_get(obj, name)
	return ok && json_kind(v) == .True
}

@(private)
_hexval :: proc "contextless" (c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

@(private)
_hex4 :: proc "contextless" (s: string) -> (rune, bool) {
	if len(s) < 4 {
		return 0, false
	}
	v: rune
	for k in 0 ..< 4 {
		h := _hexval(s[k])
		if h < 0 {
			return 0, false
		}
		v = v << 4 | rune(h)
	}
	return v, true
}

@(private)
_unescape_into :: proc "contextless" (inner: string, out: []u8) -> (int, bool) {
	n := 0
	i := 0
	put :: proc "contextless" (out: []u8, n: ^int, b: []u8) -> bool {
		if n^ + len(b) > len(out) {
			return false
		}
		copy(out[n^:], b)
		n^ += len(b)
		return true
	}
	for i < len(inner) {
		c := inner[i]
		if c != '\\' {
			if n >= len(out) {
				return n, false
			}
			out[n] = c
			n += 1
			i += 1
			continue
		}
		if i + 1 >= len(inner) {
			return n, false
		}
		e := inner[i + 1]
		i += 2
		single: u8
		switch e {
		case '"':
			single = '"'
		case '\\':
			single = '\\'
		case '/':
			single = '/'
		case 'b':
			single = 8
		case 'f':
			single = 12
		case 'n':
			single = '\n'
		case 'r':
			single = '\r'
		case 't':
			single = '\t'
		case 'u':
			r, ok := _hex4(inner[i:])
			if !ok {
				return n, false
			}
			i += 4
			if r >= 0xd800 && r < 0xdc00 {
				if i + 6 <= len(inner) && inner[i] == '\\' && inner[i + 1] == 'u' {
					lo, lok := _hex4(inner[i + 2:])
					if lok && lo >= 0xdc00 && lo < 0xe000 {
						r = 0x10000 + ((r - 0xd800) << 10) + (lo - 0xdc00)
						i += 6
					} else {
						r = utf8.RUNE_ERROR
					}
				} else {
					r = utf8.RUNE_ERROR
				}
			} else if r >= 0xdc00 && r < 0xe000 {
				r = utf8.RUNE_ERROR
			}
			b, bn := utf8.encode_rune(r)
			if !put(out, &n, b[:bn]) {
				return n, false
			}
			continue
		case:
			return n, false
		}
		if n >= len(out) {
			return n, false
		}
		out[n] = single
		n += 1
	}
	return n, true
}

json_string :: proc(raw: string, allocator := context.temp_allocator) -> (string, bool) {
	s := json_trim(raw)
	if len(s) < 2 || s[0] != '"' || s[len(s) - 1] != '"' {
		return "", false
	}
	inner := s[1:len(s) - 1]
	if strings.index_byte(inner, '\\') < 0 {
		return inner, true
	}
	buf, err := make([]u8, len(inner), allocator)
	if err != nil {
		return "", false
	}
	n, ok := _unescape_into(inner, buf)
	if !ok {
		delete(buf, allocator)
		return "", false
	}
	return string(buf[:n]), true
}

json_int :: proc(raw: string) -> (i64, bool) {
	s := json_trim(raw)
	if json_kind(s) != .Number {
		return 0, false
	}
	if v, ok := strconv.parse_i64_of_base(s, 10); ok {
		return v, true
	}
	f, ok := strconv.parse_f64(s)
	if !ok || f != f || f > 9.2e18 || f < -9.2e18 {
		return 0, false
	}
	v := i64(f)
	if f64(v) != f {
		return 0, false
	}
	return v, true
}

json_number :: proc(raw: string) -> (f64, bool) {
	s := json_trim(raw)
	if json_kind(s) != .Number {
		return 0, false
	}
	return strconv.parse_f64(s)
}

Buf :: [dynamic]u8

w_raw :: proc(b: ^Buf, s: string) {
	append(b, s)
}

w_str :: proc(b: ^Buf, s: string) {
	hex := "0123456789abcdef"
	append(b, '"')
	start := 0
	i := 0
	for i < len(s) {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c < 0x80 {
			i += 1
			continue
		}
		if c >= 0x80 {
			r, n := utf8.decode_rune_in_string(s[i:])
			if r != utf8.RUNE_ERROR || n > 1 {
				i += n
				continue
			}
			append(b, s[start:i])
			append(b, "\\ufffd")
			i += 1
			start = i
			continue
		}
		append(b, s[start:i])
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
			append(b, `\u00`)
			append(b, hex[c >> 4], hex[c & 0xf])
		}
		i += 1
		start = i
	}
	append(b, s[start:])
	append(b, '"')
}

w_int :: proc(b: ^Buf, n: i64) {
	buf: [32]u8
	append(b, strconv.write_int(buf[:], n, 10))
}

w_f64 :: proc(b: ^Buf, f: f64) {
	if f != f || f > 1.7976931348623157e308 || f < -1.7976931348623157e308 {
		append(b, "0")
		return
	}
	if f == f64(i64(f)) && f < 9e15 && f > -9e15 {
		w_int(b, i64(f))
		return
	}
	buf: [64]u8
	append(b, strconv.write_float(buf[:], f, 'g', -1, 64))
}

w_sep :: proc(b: ^Buf) {
	if len(b) == 0 {
		return
	}
	switch b[len(b) - 1] {
	case '{', '[', ':', ',':
		return
	}
	append(b, ',')
}

w_key :: proc(b: ^Buf, k: string) {
	w_sep(b)
	w_str(b, k)
	append(b, ':')
}

f_str :: proc(b: ^Buf, k: string, v: string) {
	w_key(b, k)
	w_str(b, v)
}

f_int :: proc(b: ^Buf, k: string, v: i64) {
	w_key(b, k)
	w_int(b, v)
}

f_num :: proc(b: ^Buf, k: string, v: f64) {
	w_key(b, k)
	w_f64(b, v)
}

f_bool :: proc(b: ^Buf, k: string, v: bool) {
	w_key(b, k)
	append(b, "true" if v else "false")
}

f_raw :: proc(b: ^Buf, k: string, raw: string) {
	w_key(b, k)
	append(b, raw)
}

f_obj :: proc(b: ^Buf, k: string) {
	w_key(b, k)
	append(b, '{')
}

f_arr :: proc(b: ^Buf, k: string) {
	w_key(b, k)
	append(b, '[')
}

w_open :: proc(b: ^Buf) {
	w_sep(b)
	append(b, '{')
}

w_open_arr :: proc(b: ^Buf) {
	w_sep(b)
	append(b, '[')
}

w_item_raw :: proc(b: ^Buf, raw: string) {
	w_sep(b)
	append(b, raw)
}

w_item_str :: proc(b: ^Buf, s: string) {
	w_sep(b)
	w_str(b, s)
}

w_close :: proc(b: ^Buf) {
	append(b, '}')
}

w_close_arr :: proc(b: ^Buf) {
	append(b, ']')
}

json_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := make(Buf, 0, len(s) + 2, allocator)
	w_str(&b, s)
	return string(b[:])
}

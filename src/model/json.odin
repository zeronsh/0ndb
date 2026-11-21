package model

import "core:strconv"
import "core:unicode/utf8"

@(private)
HEX :: "0123456789abcdef"

@(private)
B64 :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

@(private)
w_raw :: #force_inline proc(b: ^[dynamic]u8, s: string) {
	append(b, s)
}

@(private)
w_byte :: #force_inline proc(b: ^[dynamic]u8, c: u8) {
	append(b, c)
}

@(private)
w_str :: proc(b: ^[dynamic]u8, s: string) {
	append(b, '"')
	w_escaped(b, transmute([]u8)s)
	append(b, '"')
}

@(private)
w_escaped :: proc(b: ^[dynamic]u8, s: []u8) {
	start := 0
	i := 0
	n := len(s)
	for i < n {
		c := s[i]
		if c >= 0x20 && c != '"' && c != '\\' && c < 0x80 {
			i += 1
			continue
		}
		if c >= 0x80 {
			r, size := utf8.decode_rune(s[i:])
			if r == utf8.RUNE_ERROR && size <= 1 {
				append(b, ..s[start:i])
				append(b, "\\ufffd")
				i += 1
				start = i
				continue
			}
			if r == 0x2028 || r == 0x2029 {
				append(b, ..s[start:i])
				append(b, r == 0x2028 ? "\\u2028" : "\\u2029")
				i += size
				start = i
				continue
			}
			i += size
			continue
		}
		append(b, ..s[start:i])
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
			hex := HEX
			append(b, hex[c >> 4], hex[c & 0xf])
		}
		i += 1
		start = i
	}
	append(b, ..s[start:])
}

@(private)
w_uint :: proc(b: ^[dynamic]u8, v: u64) {
	buf: [24]u8
	s := strconv.write_uint(buf[:], v, 10)
	append(b, s)
}

@(private)
w_key :: proc(b: ^[dynamic]u8, k: string) {
	append(b, '"')
	append(b, k)
	append(b, `":`)
}

@(private)
w_base64 :: proc(b: ^[dynamic]u8, data: []u8) {
	if len(data) == 0 {
		return
	}
	n := (len(data) + 2) / 3 * 4
	old := len(b)
	resize(b, old + n)
	enc := B64
	out := b[old:]
	j := 0
	i := 0
	for ; i + 3 <= len(data); i += 3 {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		out[j] = enc[v >> 18 & 63]
		out[j + 1] = enc[v >> 12 & 63]
		out[j + 2] = enc[v >> 6 & 63]
		out[j + 3] = enc[v & 63]
		j += 4
	}
	rem := len(data) - i
	if rem == 1 {
		v := u32(data[i]) << 16
		out[j] = enc[v >> 18 & 63]
		out[j + 1] = enc[v >> 12 & 63]
		out[j + 2] = '='
		out[j + 3] = '='
	} else if rem == 2 {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		out[j] = enc[v >> 18 & 63]
		out[j + 1] = enc[v >> 12 & 63]
		out[j + 2] = enc[v >> 6 & 63]
		out[j + 3] = '='
	}
}

@(private)
is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

@(private)
skip_ws :: #force_inline proc "contextless" (s: []u8, i: int) -> int {
	j := i
	for j < len(s) && is_ws(s[j]) {
		j += 1
	}
	return j
}

@(private)
skip_string :: proc "contextless" (s: []u8, i: int) -> (int, bool) {
	if i >= len(s) || s[i] != '"' {
		return i, false
	}
	j := i + 1
	for j < len(s) {
		c := s[j]
		if c == '"' {
			return j + 1, true
		}
		if c == '\\' {
			j += 2
			continue
		}
		if c < 0x20 {
			return j, false
		}
		j += 1
	}
	return j, false
}

@(private)
MAX_DEPTH :: 256

@(private)
skip_value :: proc "contextless" (s: []u8, i: int) -> (int, bool) {
	j := skip_ws(s, i)
	if j >= len(s) {
		return j, false
	}
	switch s[j] {
	case '"':
		return skip_string(s, j)
	case '{', '[':
		depth := 0
		for j < len(s) {
			c := s[j]
			switch c {
			case '"':
				k, ok := skip_string(s, j)
				if !ok {
					return k, false
				}
				j = k
				continue
			case '{', '[':
				depth += 1
				if depth > MAX_DEPTH {
					return j, false
				}
			case '}', ']':
				depth -= 1
				if depth == 0 {
					return j + 1, true
				}
			}
			j += 1
		}
		return j, false
	case 't':
		return lit(s, j, "true")
	case 'f':
		return lit(s, j, "false")
	case 'n':
		return lit(s, j, "null")
	case '-', '0' ..= '9':
		k := j + 1
		for k < len(s) {
			c := s[k]
			if (c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-' {
				k += 1
				continue
			}
			break
		}
		return k, true
	}
	return j, false
}

@(private)
lit :: proc "contextless" (s: []u8, j: int, word: string) -> (int, bool) {
	if j + len(word) > len(s) {
		return j, false
	}
	for k in 0 ..< len(word) {
		if s[j + k] != word[k] {
			return j, false
		}
	}
	return j + len(word), true
}

@(private)
key_equals :: proc "contextless" (raw: []u8, key: string) -> bool {
	if len(raw) != len(key) {
		return false
	}
	for k in 0 ..< len(key) {
		if raw[k] != key[k] {
			return false
		}
	}
	return true
}

j_get :: proc "contextless" (obj: []u8, key: string) -> ([]u8, bool) {
	i := skip_ws(obj, 0)
	if i >= len(obj) || obj[i] != '{' {
		return nil, false
	}
	i += 1
	for {
		i = skip_ws(obj, i)
		if i >= len(obj) {
			return nil, false
		}
		if obj[i] == '}' {
			return nil, false
		}
		if obj[i] == ',' {
			i += 1
			continue
		}
		ks := i
		ke, ok := skip_string(obj, i)
		if !ok {
			return nil, false
		}
		i = skip_ws(obj, ke)
		if i >= len(obj) || obj[i] != ':' {
			return nil, false
		}
		i = skip_ws(obj, i + 1)
		vs := i
		ve, vok := skip_value(obj, i)
		if !vok {
			return nil, false
		}
		if key_equals(obj[ks + 1:ke - 1], key) {
			return obj[vs:ve], true
		}
		i = ve
	}
}

j_path :: proc "contextless" (obj: []u8, keys: ..string) -> ([]u8, bool) {
	cur := obj
	for k in keys {
		v, ok := j_get(cur, k)
		if !ok {
			return nil, false
		}
		cur = v
	}
	return cur, true
}

j_is_null :: proc "contextless" (v: []u8) -> bool {
	return len(v) == 0 || (len(v) == 4 && v[0] == 'n')
}

j_raw_str :: proc "contextless" (v: []u8) -> (string, bool) {
	if len(v) < 2 || v[0] != '"' {
		return "", false
	}
	inner := v[1:len(v) - 1]
	for c in inner {
		if c == '\\' {
			return "", false
		}
	}
	return string(inner), true
}

j_str :: proc(v: []u8, scratch: ^[dynamic]u8) -> string {
	if len(v) < 2 || v[0] != '"' {
		return ""
	}
	if s, ok := j_raw_str(v); ok {
		return s
	}
	start := len(scratch)
	j_unescape(v[1:len(v) - 1], scratch)
	return string(scratch[start:])
}

j_unescape :: proc(inner: []u8, out: ^[dynamic]u8) {
	i := 0
	n := len(inner)
	run := 0
	for i < n {
		c := inner[i]
		if c != '\\' {
			i += 1
			continue
		}
		append(out, ..inner[run:i])
		if i + 1 >= n {
			i = n
			run = n
			break
		}
		e := inner[i + 1]
		i += 2
		switch e {
		case '"':
			append(out, '"')
		case '\\':
			append(out, '\\')
		case '/':
			append(out, '/')
		case 'b':
			append(out, 8)
		case 'f':
			append(out, 12)
		case 'n':
			append(out, '\n')
		case 'r':
			append(out, '\r')
		case 't':
			append(out, '\t')
		case 'u':
			r, ok := hex4(inner, i)
			if !ok {
				append(out, "�")
				break
			}
			i += 4
			if r >= 0xd800 && r < 0xdc00 {
				if i + 6 <= n && inner[i] == '\\' && inner[i + 1] == 'u' {
					lo, lok := hex4(inner, i + 2)
					if lok && lo >= 0xdc00 && lo < 0xe000 {
						r = 0x10000 + ((r - 0xd800) << 10) + (lo - 0xdc00)
						i += 6
					} else {
						r = 0xfffd
					}
				} else {
					r = 0xfffd
				}
			} else if r >= 0xdc00 && r < 0xe000 {
				r = 0xfffd
			}
			buf, w := utf8.encode_rune(rune(r))
			append(out, ..buf[:w])
		case:
			append(out, e)
		}
		run = i
	}
	append(out, ..inner[run:n])
}

@(private)
hex4 :: proc "contextless" (s: []u8, i: int) -> (u32, bool) {
	if i + 4 > len(s) {
		return 0, false
	}
	v: u32
	for k in 0 ..< 4 {
		c := s[i + k]
		d: u32
		switch c {
		case '0' ..= '9':
			d = u32(c - '0')
		case 'a' ..= 'f':
			d = u32(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(c - 'A' + 10)
		case:
			return 0, false
		}
		v = v << 4 | d
	}
	return v, true
}

j_u64 :: proc "contextless" (v: []u8) -> u64 {
	n: u64
	for c in v {
		if c < '0' || c > '9' {
			break
		}
		n = n * 10 + u64(c - '0')
	}
	return n
}

j_int :: proc "contextless" (v: []u8) -> int {
	if len(v) > 0 && v[0] == '-' {
		return -int(j_u64(v[1:]))
	}
	return int(j_u64(v))
}

j_get_u64 :: proc "contextless" (obj: []u8, key: string) -> u64 {
	v, ok := j_get(obj, key)
	if !ok {
		return 0
	}
	return j_u64(v)
}

j_get_str :: proc(obj: []u8, key: string, scratch: ^[dynamic]u8) -> string {
	v, ok := j_get(obj, key)
	if !ok {
		return ""
	}
	return j_str(v, scratch)
}

j_get_raw_str :: proc "contextless" (obj: []u8, key: string) -> string {
	v, ok := j_get(obj, key)
	if !ok {
		return ""
	}
	s, _ := j_raw_str(v)
	return s
}

j_bool :: proc "contextless" (v: []u8) -> bool {
	return len(v) == 4 && v[0] == 't'
}

Array_Iter :: struct {
	s: []u8,
	i: int,
}

j_array :: proc "contextless" (v: []u8) -> (Array_Iter, bool) {
	i := skip_ws(v, 0)
	if i >= len(v) || v[i] != '[' {
		return {}, false
	}
	return Array_Iter{s = v, i = i + 1}, true
}

j_next :: proc "contextless" (it: ^Array_Iter) -> ([]u8, bool) {
	for {
		it.i = skip_ws(it.s, it.i)
		if it.i >= len(it.s) || it.s[it.i] == ']' {
			return nil, false
		}
		if it.s[it.i] == ',' {
			it.i += 1
			continue
		}
		start := it.i
		end, ok := skip_value(it.s, it.i)
		if !ok {
			it.i = len(it.s)
			return nil, false
		}
		it.i = end
		return it.s[start:end], true
	}
}

j_valid :: proc "contextless" (v: []u8) -> bool {
	end, ok := j_validate(v, skip_ws(v, 0), 0)
	if !ok {
		return false
	}
	return skip_ws(v, end) == len(v)
}

@(private)
j_validate :: proc "contextless" (s: []u8, i: int, depth: int) -> (int, bool) {
	if depth > MAX_DEPTH || i >= len(s) {
		return i, false
	}
	switch s[i] {
	case '{':
		j := skip_ws(s, i + 1)
		if j < len(s) && s[j] == '}' {
			return j + 1, true
		}
		for {
			k, ok := skip_string(s, j)
			if !ok {
				return k, false
			}
			j = skip_ws(s, k)
			if j >= len(s) || s[j] != ':' {
				return j, false
			}
			j, ok = j_validate(s, skip_ws(s, j + 1), depth + 1)
			if !ok {
				return j, false
			}
			j = skip_ws(s, j)
			if j >= len(s) {
				return j, false
			}
			if s[j] == '}' {
				return j + 1, true
			}
			if s[j] != ',' {
				return j, false
			}
			j = skip_ws(s, j + 1)
		}
	case '[':
		j := skip_ws(s, i + 1)
		if j < len(s) && s[j] == ']' {
			return j + 1, true
		}
		for {
			ok: bool
			j, ok = j_validate(s, j, depth + 1)
			if !ok {
				return j, false
			}
			j = skip_ws(s, j)
			if j >= len(s) {
				return j, false
			}
			if s[j] == ']' {
				return j + 1, true
			}
			if s[j] != ',' {
				return j, false
			}
			j = skip_ws(s, j + 1)
		}
	case '"':
		j := i + 1
		for j < len(s) {
			c := s[j]
			if c == '"' {
				return j + 1, true
			}
			if c < 0x20 {
				return j, false
			}
			if c == '\\' {
				if j + 1 >= len(s) {
					return j, false
				}
				e := s[j + 1]
				switch e {
				case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
					j += 2
				case 'u':
					if _, ok := hex4(s, j + 2); !ok {
						return j, false
					}
					j += 6
				case:
					return j, false
				}
				continue
			}
			j += 1
		}
		return j, false
	case 't':
		return lit(s, i, "true")
	case 'f':
		return lit(s, i, "false")
	case 'n':
		return lit(s, i, "null")
	case '-', '0' ..= '9':
		j := i
		if s[j] == '-' {
			j += 1
		}
		if j >= len(s) {
			return j, false
		}
		if s[j] == '0' {
			j += 1
		} else if s[j] >= '1' && s[j] <= '9' {
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				j += 1
			}
		} else {
			return j, false
		}
		if j < len(s) && s[j] == '.' {
			j += 1
			d := j
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				j += 1
			}
			if j == d {
				return j, false
			}
		}
		if j < len(s) && (s[j] == 'e' || s[j] == 'E') {
			j += 1
			if j < len(s) && (s[j] == '+' || s[j] == '-') {
				j += 1
			}
			d := j
			for j < len(s) && s[j] >= '0' && s[j] <= '9' {
				j += 1
			}
			if j == d {
				return j, false
			}
		}
		return j, true
	}
	return i, false
}

j_is_object :: proc "contextless" (v: []u8) -> bool {
	i := skip_ws(v, 0)
	return i < len(v) && v[i] == '{'
}

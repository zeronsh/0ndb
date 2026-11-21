package jsonschema

import "base:runtime"
import "core:strconv"
import "core:unicode/utf8"

Kind :: enum u8 {
	Null,
	Bool,
	Number,
	String,
	Array,
	Object,
}

Value :: struct {
	kind:  Kind,
	b:     bool,
	n:     f64,
	s:     string,
	items: []Value,
	keys:  []string,
	vals:  []Value,
}

MAX_PARSE_DEPTH :: 512

@(private)
Parser :: struct {
	src:   []u8,
	i:     int,
	depth: int,
	a:     runtime.Allocator,
}

parse :: proc(src: []u8, allocator := context.allocator) -> (v: Value, ok: bool) {
	p := Parser {
		src = src,
		a   = allocator,
	}
	ws(&p)
	v, ok = value(&p)
	if !ok {
		return {}, false
	}
	ws(&p)
	return v, p.i == len(p.src)
}

get :: proc "contextless" (v: ^Value, key: string) -> (^Value, bool) {
	if v == nil || v.kind != .Object {
		return nil, false
	}
	for k, i in v.keys {
		if k == key {
			return &v.vals[i], true
		}
	}
	return nil, false
}

get_string :: proc "contextless" (v: ^Value, key: string) -> (string, bool) {
	x, ok := get(v, key)
	if !ok || x.kind != .String {
		return "", false
	}
	return x.s, true
}

@(private)
ws :: proc "contextless" (p: ^Parser) {
	for p.i < len(p.src) {
		c := p.src[p.i]
		if c != ' ' && c != '\n' && c != '\r' && c != '\t' {
			return
		}
		p.i += 1
	}
}

@(private)
value :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	if p.i >= len(p.src) {
		return {}, false
	}
	switch p.src[p.i] {
	case '{':
		return object(p)
	case '[':
		return array(p)
	case '"':
		s, sok := str(p)
		return Value{kind = .String, s = s}, sok
	case 't':
		return Value{kind = .Bool, b = true}, word(p, "true")
	case 'f':
		return Value{kind = .Bool}, word(p, "false")
	case 'n':
		return Value{kind = .Null}, word(p, "null")
	case '-', '0' ..= '9':
		return number(p)
	}
	return {}, false
}

@(private)
word :: proc "contextless" (p: ^Parser, w: string) -> bool {
	if p.i + len(w) > len(p.src) || string(p.src[p.i:p.i + len(w)]) != w {
		return false
	}
	p.i += len(w)
	return true
}

@(private)
number :: proc(p: ^Parser) -> (Value, bool) {
	start := p.i
	if p.src[p.i] == '-' {
		p.i += 1
	}
	digits :: proc "contextless" (p: ^Parser) -> int {
		n := 0
		for p.i < len(p.src) && p.src[p.i] >= '0' && p.src[p.i] <= '9' {
			p.i += 1
			n += 1
		}
		return n
	}
	if p.i < len(p.src) && p.src[p.i] == '0' {
		p.i += 1
	} else if digits(p) == 0 {
		return {}, false
	}
	if p.i < len(p.src) && p.src[p.i] == '.' {
		p.i += 1
		if digits(p) == 0 {
			return {}, false
		}
	}
	if p.i < len(p.src) && (p.src[p.i] == 'e' || p.src[p.i] == 'E') {
		p.i += 1
		if p.i < len(p.src) && (p.src[p.i] == '+' || p.src[p.i] == '-') {
			p.i += 1
		}
		if digits(p) == 0 {
			return {}, false
		}
	}
	f, _ := strconv.parse_f64(string(p.src[start:p.i]))
	return Value{kind = .Number, n = f}, true
}

@(private)
hexval :: proc "contextless" (s: []u8) -> (u32, bool) {
	if len(s) < 4 {
		return 0, false
	}
	v: u32
	for k in 0 ..< 4 {
		c := s[k]
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

@(private)
str :: proc(p: ^Parser) -> (string, bool) {
	p.i += 1
	start := p.i
	plain := true
	for p.i < len(p.src) {
		c := p.src[p.i]
		if c == '"' {
			break
		}
		if c < 0x20 {
			return "", false
		}
		if c == '\\' {
			plain = false
			p.i += 2
			continue
		}
		p.i += 1
	}
	if p.i >= len(p.src) {
		return "", false
	}
	raw := p.src[start:p.i]
	p.i += 1
	if plain {
		out := make([]u8, len(raw), p.a)
		copy(out, raw)
		return string(out), true
	}
	out := make([dynamic]u8, 0, len(raw), p.a)
	k := 0
	for k < len(raw) {
		c := raw[k]
		if c != '\\' {
			append(&out, c)
			k += 1
			continue
		}
		if k + 1 >= len(raw) {
			return "", false
		}
		e := raw[k + 1]
		k += 2
		switch e {
		case '"':
			append(&out, '"')
		case '\\':
			append(&out, '\\')
		case '/':
			append(&out, '/')
		case 'b':
			append(&out, 8)
		case 'f':
			append(&out, 12)
		case 'n':
			append(&out, '\n')
		case 'r':
			append(&out, '\r')
		case 't':
			append(&out, '\t')
		case 'u':
			r, ok := hexval(raw[k:])
			if !ok {
				return "", false
			}
			k += 4
			if r >= 0xd800 && r < 0xdc00 && k + 6 <= len(raw) && raw[k] == '\\' && raw[k + 1] == 'u' {
				if lo, lok := hexval(raw[k + 2:]); lok && lo >= 0xdc00 && lo < 0xe000 {
					r = 0x10000 + ((r - 0xd800) << 10) + (lo - 0xdc00)
					k += 6
				}
			}
			if r >= 0xd800 && r < 0xe000 {
				r = 0xfffd
			}
			buf, w := utf8.encode_rune(rune(r))
			append(&out, ..buf[:w])
		case:
			return "", false
		}
	}
	return string(out[:]), true
}

@(private)
array :: proc(p: ^Parser) -> (Value, bool) {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_PARSE_DEPTH {
		return {}, false
	}
	p.i += 1
	items := make([dynamic]Value, p.a)
	ws(p)
	if p.i < len(p.src) && p.src[p.i] == ']' {
		p.i += 1
		return Value{kind = .Array, items = items[:]}, true
	}
	for {
		ws(p)
		v, ok := value(p)
		if !ok {
			return {}, false
		}
		append(&items, v)
		ws(p)
		if p.i >= len(p.src) {
			return {}, false
		}
		if p.src[p.i] == ',' {
			p.i += 1
			continue
		}
		if p.src[p.i] == ']' {
			p.i += 1
			return Value{kind = .Array, items = items[:]}, true
		}
		return {}, false
	}
}

@(private)
object :: proc(p: ^Parser) -> (Value, bool) {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > MAX_PARSE_DEPTH {
		return {}, false
	}
	p.i += 1
	keys := make([dynamic]string, p.a)
	vals := make([dynamic]Value, p.a)
	ws(p)
	if p.i < len(p.src) && p.src[p.i] == '}' {
		p.i += 1
		return Value{kind = .Object, keys = keys[:], vals = vals[:]}, true
	}
	for {
		ws(p)
		if p.i >= len(p.src) || p.src[p.i] != '"' {
			return {}, false
		}
		k, kok := str(p)
		if !kok {
			return {}, false
		}
		ws(p)
		if p.i >= len(p.src) || p.src[p.i] != ':' {
			return {}, false
		}
		p.i += 1
		ws(p)
		v, ok := value(p)
		if !ok {
			return {}, false
		}
		dup := -1
		for x, xi in keys {
			if x == k {
				dup = xi
			}
		}
		if dup >= 0 {
			vals[dup] = v
		} else {
			append(&keys, k)
			append(&vals, v)
		}
		ws(p)
		if p.i >= len(p.src) {
			return {}, false
		}
		if p.src[p.i] == ',' {
			p.i += 1
			continue
		}
		if p.src[p.i] == '}' {
			p.i += 1
			return Value{kind = .Object, keys = keys[:], vals = vals[:]}, true
		}
		return {}, false
	}
}

equal :: proc "contextless" (a, b: ^Value) -> bool {
	if a.kind != b.kind {
		return false
	}
	switch a.kind {
	case .Null:
		return true
	case .Bool:
		return a.b == b.b
	case .Number:
		return a.n == b.n
	case .String:
		return a.s == b.s
	case .Array:
		if len(a.items) != len(b.items) {
			return false
		}
		for i in 0 ..< len(a.items) {
			if !equal(&a.items[i], &b.items[i]) {
				return false
			}
		}
		return true
	case .Object:
		if len(a.keys) != len(b.keys) {
			return false
		}
		for k, i in a.keys {
			other, ok := get(b, k)
			if !ok || !equal(&a.vals[i], other) {
				return false
			}
		}
		return true
	}
	return false
}

package search

import "base:runtime"
import "../prim"

MAX_ATOMS :: 32
MAX_RANGE_TERMS :: 512
MAX_WROTE_REFS :: 4096

Atom_Field :: enum u8 {
	Any,
	Title,
	Body,
	Named,
	Kind,
	Object,
	From,
	After,
	Before,
	Wrote,
}

Wrote_Ref :: struct {
	object: prim.Id,
	ref:    []u8,
}

Atom :: struct {
	field:   Atom_Field,
	name:    []u8,
	substr:  bool,
	neg:     bool,
	word:    bool,
	prefix:  bool,
	text:    []u8,
	nibbles: int,
	hlc:     u64,
	kind:    u8,
	ids:     [dynamic]prim.Id,
	refs:    [dynamic]Wrote_Ref,
	idf:     f64,
	scored:  bool,
}

Clause :: struct {
	atoms: [dynamic]Atom,
}

Query :: struct {
	clauses: [dynamic]Clause,
	natoms:  int,
}

Participants :: #type proc(data: rawptr, name: string, out: ^[dynamic]prim.Id)
File_Key :: #type proc(data: rawptr, path: string, out: ^[dynamic]u8) -> bool

@(private)
_field_name :: proc(name: string) -> (f: Atom_Field, word: bool) {
	switch name {
	case "title":
		return .Title, false
	case "body":
		return .Body, false
	case "kind":
		return .Kind, false
	case "object", "thread":
		return .Object, false
	case "from":
		return .From, false
	case "after":
		return .After, false
	case "before":
		return .Before, false
	case "wrote":
		return .Wrote, false
	case "word":
		return .Any, true
	}
	return .Named, false
}

@(private)
_is_space :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

parse :: proc(ix: ^Index, q: string, req: ^Request, now_ms: i64, allocator: runtime.Allocator) -> (out: Query, err: Error) {
	out.clauses = make([dynamic]Clause, allocator)
	s := transmute([]u8)q
	i := 0
	joining := false
	for {
		for i < len(s) && _is_space(s[i]) {
			i += 1
		}
		if i >= len(s) {
			break
		}
		if s[i] == '|' || (i + 1 < len(s) && s[i] == 'O' && s[i + 1] == 'R' && (i + 2 == len(s) || _is_space(s[i + 2]))) {
			if len(out.clauses) == 0 || joining {
				return out, .Syntax
			}
			i += 1 if s[i] == '|' else 2
			joining = true
			continue
		}
		a := Atom{}
		if s[i] == '-' && i + 1 < len(s) && !_is_space(s[i + 1]) {
			a.neg = true
			i += 1
		}
		j := i
		for j < len(s) && j - i < MAX_NAME && ((s[j] >= 'a' && s[j] <= 'z') || (s[j] >= '0' && s[j] <= '9') || s[j] == '_') {
			j += 1
		}
		if j < len(s) && s[j] == ':' && j > i && j + 1 < len(s) && !_is_space(s[j + 1]) && s[j + 1] != '/' {
			f, w := _field_name(string(s[i:j]))
			a.field = f
			a.word = w
			if f == .Named {
				a.name = make([]u8, j - i, allocator)
				copy(a.name, s[i:j])
				a.substr = substring_field(ix, a.name)
			}
			i = j + 1
		}
		val := make([dynamic]u8, allocator)
		if s[i] == '"' {
			i += 1
			closed := false
			for i < len(s) {
				c := s[i]
				if c == '\\' && i + 1 < len(s) {
					append(&val, s[i + 1])
					i += 2
					continue
				}
				if c == '"' {
					i += 1
					closed = true
					break
				}
				append(&val, c)
				i += 1
			}
			if !closed {
				return out, .Syntax
			}
		} else {
			for i < len(s) && !_is_space(s[i]) {
				append(&val, s[i])
				i += 1
			}
		}
		if len(val) == 0 || len(val) > MAX_PATH {
			return out, .Syntax
		}
		_build_atom(ix, &a, val[:], req, now_ms, allocator) or_return
		out.natoms += 1
		if out.natoms > MAX_ATOMS {
			return out, .Syntax
		}
		if joining {
			append(&out.clauses[len(out.clauses) - 1].atoms, a)
			joining = false
		} else {
			c := Clause{}
			c.atoms = make([dynamic]Atom, allocator)
			append(&c.atoms, a)
			append(&out.clauses, c)
		}
	}
	if joining {
		return out, .Syntax
	}
	return out, .None
}

@(private)
_build_atom :: proc(ix: ^Index, a: ^Atom, val: []u8, req: ^Request, now_ms: i64, allocator: runtime.Allocator) -> Error {
	switch a.field {
	case .Any, .Title, .Body:
		if len(val) > MAX_TERM {
			return .Syntax
		}
		a.text = make([]u8, len(val), allocator)
		fold_into(a.text, val)
	case .Named:
		v := val
		if !a.substr && v[len(v) - 1] == '*' {
			a.prefix = true
			v = v[:len(v) - 1]
		}
		if len(v) > MAX_PATH || (a.substr && len(v) > MAX_TERM) {
			return .Syntax
		}
		a.text = make([]u8, len(v), allocator)
		fold_into(a.text, v)
	case .Kind:
		found := false
		for k, i in ix.opts.kind_names {
			if k == string(val) && i < 256 {
				a.kind = u8(i)
				found = true
				break
			}
		}
		if !found {
			n, rest, ok := _parse_uint(val)
			if !ok || len(rest) > 0 || n > 255 {
				return .Syntax
			}
			a.kind = u8(n)
		}
	case .Object:
		_hex_prefix(a, val, allocator) or_return
	case .From:
		if _all_hex(val) && len(val) >= 4 {
			_hex_prefix(a, val, allocator) or_return
		} else {
			a.ids = make([dynamic]prim.Id, allocator)
			if req.participants != nil {
				req.participants(req.resolve_data, string(val), &a.ids)
			}
		}
	case .After, .Before:
		ms, ok := parse_time(string(val), now_ms)
		if !ok {
			return .Syntax
		}
		a.hlc = u64(ms) << 16
	case .Wrote:
		_build_wrote(ix, a, val, req, allocator) or_return
	}
	return .None
}

@(private)
_all_hex :: proc "contextless" (v: []u8) -> bool {
	for c in v {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

@(private)
_hex_prefix :: proc(a: ^Atom, val: []u8, allocator: runtime.Allocator) -> Error {
	v := val
	if len(v) > 0 && v[len(v) - 1] == '*' {
		v = v[:len(v) - 1]
	}
	if len(v) == 0 || len(v) > 32 || !_all_hex(v) {
		return .Syntax
	}
	a.text = make([]u8, (len(v) + 1) / 2, allocator)
	for k in 0 ..< len(v) {
		c := v[k] | 0x20
		n := c - '0' if c <= '9' else c - 'a' + 10
		if k % 2 == 0 {
			a.text[k / 2] = n << 4
		} else {
			a.text[k / 2] |= n
		}
	}
	a.nibbles = len(v)
	a.prefix = len(v) < 32
	return .None
}

id_matches :: proc "contextless" (a: ^Atom, id: prim.Id) -> bool {
	if len(a.ids) > 0 || a.nibbles == 0 {
		for x in a.ids {
			if x == id {
				return true
			}
		}
		return false
	}
	full := a.nibbles / 2
	for k in 0 ..< full {
		if id[k] != a.text[k] {
			return false
		}
	}
	if a.nibbles % 2 == 1 && id[full] >> 4 != a.text[full] >> 4 {
		return false
	}
	return true
}

@(private)
_build_wrote :: proc(ix: ^Index, a: ^Atom, val: []u8, req: ^Request, allocator: runtime.Allocator) -> Error {
	path := val
	unit := Unit.Lines
	lo, hi := u64(0), max(u64)
	for k := len(val) - 1; k >= 0; k -= 1 {
		if val[k] == '#' {
			path = val[:k]
			spec := val[k + 1:]
			if len(spec) > 0 && (spec[0] == 'L' || spec[0] == 'l') {
				spec = spec[1:]
			} else if len(spec) > 0 && (spec[0] == 'B' || spec[0] == 'b') {
				unit = .Bytes
				spec = spec[1:]
			}
			x, rest, ok := _parse_uint(spec)
			if !ok {
				return .Syntax
			}
			lo = x
			hi = x
			if len(rest) > 0 {
				if rest[0] != '-' {
					return .Syntax
				}
				rest = rest[1:]
				if len(rest) > 0 && (rest[0] == 'L' || rest[0] == 'l' || rest[0] == 'B' || rest[0] == 'b') {
					rest = rest[1:]
				}
				y, tail, ok2 := _parse_uint(rest)
				if !ok2 || len(tail) > 0 || y < x {
					return .Syntax
				}
				hi = y
			}
			if hi < max(u64) {
				hi += 1
			}
			break
		}
	}
	if len(path) == 0 {
		return .Syntax
	}
	key := make([dynamic]u8, allocator)
	if req.file_key != nil {
		if !req.file_key(req.resolve_data, string(path), &key) {
			clear(&key)
		}
	} else {
		append(&key, ..path)
	}
	a.refs = make([dynamic]Wrote_Ref, allocator)
	a.ids = make([dynamic]prim.Id, allocator)
	if len(key) == 0 {
		return .None
	}
	hits := wrote(ix, key[:], unit, lo, hi, allocator) or_return
	for h in hits {
		if !h.known || len(a.refs) >= MAX_WROTE_REFS {
			continue
		}
		append(&a.refs, Wrote_Ref{h.object, h.ref})
		seen := false
		for t in a.ids {
			if t == h.object {
				seen = true
				break
			}
		}
		if !seen {
			append(&a.ids, h.object)
		}
	}
	return .None
}

@(private)
_parse_uint :: proc "contextless" (s: []u8) -> (v: u64, rest: []u8, ok: bool) {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		if v > (max(u64) - 9) / 10 {
			return 0, s, false
		}
		v = v * 10 + u64(s[i] - '0')
		i += 1
	}
	return v, s[i:], i > 0
}

@(private)
_days_from_civil :: proc "contextless" (y0, m, d: i64) -> i64 {
	y := y0 - 1 if m <= 2 else y0
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := m + 9 if m <= 2 else m - 3
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

parse_time :: proc "contextless" (v: string, now_ms: i64) -> (ms: i64, ok: bool) {
	b := transmute([]u8)v
	n, rest, nok := _parse_uint(b)
	if !nok {
		return 0, false
	}
	if len(rest) == 0 {
		if n > 1 << 48 {
			return i64(n >> 16), true
		}
		return i64(n), true
	}
	if len(rest) == 1 {
		unit: i64
		switch rest[0] {
		case 's':
			unit = 1000
		case 'm':
			unit = 60 * 1000
		case 'h':
			unit = 3600 * 1000
		case 'd':
			unit = 86400 * 1000
		case 'w':
			unit = 7 * 86400 * 1000
		case:
			return 0, false
		}
		if n > u64(now_ms / unit) {
			return 0, true
		}
		return now_ms - i64(n) * unit, true
	}
	if rest[0] != '-' || n < 1970 || n > 9999 {
		return 0, false
	}
	mo, r2, ok2 := _parse_uint(rest[1:])
	if !ok2 || len(r2) < 2 || r2[0] != '-' || mo < 1 || mo > 12 {
		return 0, false
	}
	dd, r3, ok3 := _parse_uint(r2[1:])
	if !ok3 || dd < 1 || dd > 31 {
		return 0, false
	}
	days := _days_from_civil(i64(n), i64(mo), i64(dd))
	ms = days * 86400 * 1000
	if len(r3) == 0 {
		return ms, true
	}
	if r3[0] != 'T' && r3[0] != 't' {
		return 0, false
	}
	hh, r4, ok4 := _parse_uint(r3[1:])
	if !ok4 || hh > 23 || len(r4) < 2 || r4[0] != ':' {
		return 0, false
	}
	mm, r5, ok5 := _parse_uint(r4[1:])
	if !ok5 || mm > 59 {
		return 0, false
	}
	ss := u64(0)
	if len(r5) > 0 && r5[0] == ':' {
		x, r6, ok6 := _parse_uint(r5[1:])
		if !ok6 || x > 60 {
			return 0, false
		}
		ss = x
		r5 = r6
	}
	if len(r5) > 0 && !(len(r5) == 1 && (r5[0] == 'Z' || r5[0] == 'z')) {
		return 0, false
	}
	return ms + i64(hh) * 3600000 + i64(mm) * 60000 + i64(ss) * 1000, true
}

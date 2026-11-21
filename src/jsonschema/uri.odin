package jsonschema

import "core:strings"

@(private)
Uri :: struct {
	scheme:    string,
	authority: string,
	path:      string,
	query:     string,
	fragment:  string,
	has_auth:  bool,
	has_query: bool,
	has_frag:  bool,
}

@(private)
uri_parse :: proc(s: string) -> (u: Uri) {
	rest := s
	if i := strings.index_byte(rest, '#'); i >= 0 {
		u.fragment = rest[i + 1:]
		u.has_frag = true
		rest = rest[:i]
	}
	if i := strings.index_byte(rest, '?'); i >= 0 {
		u.query = rest[i + 1:]
		u.has_query = true
		rest = rest[:i]
	}
	for i in 0 ..< len(rest) {
		c := rest[i]
		if c == ':' {
			if i > 0 {
				u.scheme = rest[:i]
				rest = rest[i + 1:]
			}
			break
		}
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (i > 0 && ((c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'))) {
			break
		}
	}
	if strings.has_prefix(rest, "//") {
		rest = rest[2:]
		end := len(rest)
		if i := strings.index_byte(rest, '/'); i >= 0 {
			end = i
		}
		u.authority = rest[:end]
		u.has_auth = true
		rest = rest[end:]
	}
	u.path = rest
	return
}

@(private)
remove_dots :: proc(path: string, allocator := context.temp_allocator) -> string {
	if strings.index(path, ".") < 0 {
		return path
	}
	out := make([dynamic]string, allocator)
	segs := strings.split(path, "/", allocator)
	absolute := strings.has_prefix(path, "/")
	for seg, i in segs {
		if i == 0 && absolute {
			continue
		}
		switch seg {
		case ".":
			if i == len(segs) - 1 {
				append(&out, "")
			}
		case "..":
			if len(out) > 0 {
				pop(&out)
			}
			if i == len(segs) - 1 {
				append(&out, "")
			}
		case:
			append(&out, seg)
		}
	}
	joined := strings.join(out[:], "/", allocator)
	if absolute {
		return strings.concatenate({"/", joined}, allocator)
	}
	return joined
}

@(private)
uri_build :: proc(u: Uri, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	if u.scheme != "" {
		strings.write_string(&b, u.scheme)
		strings.write_byte(&b, ':')
	}
	if u.has_auth {
		strings.write_string(&b, "//")
		strings.write_string(&b, u.authority)
	}
	strings.write_string(&b, u.path)
	if u.has_query {
		strings.write_byte(&b, '?')
		strings.write_string(&b, u.query)
	}
	if u.has_frag {
		strings.write_byte(&b, '#')
		strings.write_string(&b, u.fragment)
	}
	return strings.to_string(b)
}

uri_resolve :: proc(base: string, ref: string, allocator := context.temp_allocator) -> string {
	r := uri_parse(ref)
	b := uri_parse(base)
	t: Uri
	if r.scheme != "" {
		t = r
		t.path = remove_dots(r.path, allocator)
	} else {
		if r.has_auth {
			t.authority = r.authority
			t.has_auth = true
			t.path = remove_dots(r.path, allocator)
			t.query = r.query
			t.has_query = r.has_query
		} else {
			if r.path == "" {
				t.path = b.path
				if r.has_query {
					t.query = r.query
					t.has_query = true
				} else {
					t.query = b.query
					t.has_query = b.has_query
				}
			} else {
				if strings.has_prefix(r.path, "/") {
					t.path = remove_dots(r.path, allocator)
				} else {
					merged: string
					if b.has_auth && b.path == "" {
						merged = strings.concatenate({"/", r.path}, allocator)
					} else {
						cut := strings.last_index_byte(b.path, '/')
						merged = strings.concatenate({b.path[:cut + 1], r.path}, allocator)
					}
					t.path = remove_dots(merged, allocator)
				}
				t.query = r.query
				t.has_query = r.has_query
			}
			t.authority = b.authority
			t.has_auth = b.has_auth
		}
		t.scheme = b.scheme
	}
	t.fragment = r.fragment
	t.has_frag = r.has_frag
	return uri_build(t, allocator)
}

uri_split :: proc "contextless" (u: string) -> (base: string, fragment: string) {
	for i in 0 ..< len(u) {
		if u[i] == '#' {
			return u[:i], u[i + 1:]
		}
	}
	return u, ""
}

@(private)
percent_decode :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '%') < 0 {
		return s
	}
	out := make([dynamic]u8, 0, len(s), allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			h, ok1 := hexdigit(s[i + 1])
			l, ok2 := hexdigit(s[i + 2])
			if ok1 && ok2 {
				append(&out, h << 4 | l)
				i += 3
				continue
			}
		}
		append(&out, s[i])
		i += 1
	}
	return string(out[:])
}

@(private)
hexdigit :: proc "contextless" (c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

pointer :: proc(root: ^Value, ptr: string) -> (^Value, bool) {
	cur := root
	if ptr == "" {
		return cur, true
	}
	if ptr[0] != '/' {
		return nil, false
	}
	rest := ptr[1:]
	for {
		seg := rest
		more := false
		if i := strings.index_byte(rest, '/'); i >= 0 {
			seg = rest[:i]
			rest = rest[i + 1:]
			more = true
		}
		tok := seg
		if strings.index_byte(seg, '~') >= 0 {
			tok, _ = strings.replace_all(seg, "~1", "/", context.temp_allocator)
			tok, _ = strings.replace_all(tok, "~0", "~", context.temp_allocator)
		}
		#partial switch cur.kind {
		case .Object:
			v, ok := get(cur, tok)
			if !ok {
				return nil, false
			}
			cur = v
		case .Array:
			n := 0
			if len(tok) == 0 || (len(tok) > 1 && tok[0] == '0') {
				return nil, false
			}
			for c in transmute([]u8)tok {
				if c < '0' || c > '9' {
					return nil, false
				}
				n = n * 10 + int(c - '0')
			}
			if n >= len(cur.items) {
				return nil, false
			}
			cur = &cur.items[n]
		case:
			return nil, false
		}
		if !more {
			return cur, true
		}
	}
}

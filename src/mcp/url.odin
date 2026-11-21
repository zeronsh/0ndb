package mcp

import "core:strconv"
import "core:strings"

Url :: struct {
	scheme: string,
	host:   string,
	port:   int,
	target: string,
	origin: string,
}

url_parse :: proc(raw: string, allocator := context.temp_allocator) -> (u: Url, ok: bool) {
	sep := strings.index(raw, "://")
	if sep <= 0 {
		return
	}
	u.scheme = raw[:sep]
	rest := raw[sep + 3:]
	slash := len(rest)
	for i in 0 ..< len(rest) {
		if rest[i] == '/' || rest[i] == '?' || rest[i] == '#' {
			slash = i
			break
		}
	}
	authority := rest[:slash]
	u.target = rest[slash:]
	if hash := strings.index_byte(u.target, '#'); hash >= 0 {
		u.target = u.target[:hash]
	}
	if len(u.target) == 0 || u.target[0] != '/' {
		u.target = strings.concatenate({"/", u.target}, allocator)
	}
	if at := strings.last_index_byte(authority, '@'); at >= 0 {
		authority = authority[at + 1:]
	}
	hostport := authority
	u.port = 443 if _ascii_equal_fold(u.scheme, "https") else 80
	if len(hostport) > 0 && hostport[0] == '[' {
		close := strings.index_byte(hostport, ']')
		if close < 0 {
			return
		}
		u.host = hostport[:close + 1]
		if close + 1 < len(hostport) {
			if hostport[close + 1] != ':' {
				return
			}
			p, pok := strconv.parse_int(hostport[close + 2:], 10)
			if !pok || p <= 0 || p > 65535 {
				return
			}
			u.port = p
		}
	} else if colon := strings.last_index_byte(hostport, ':'); colon >= 0 {
		u.host = hostport[:colon]
		if colon + 1 < len(hostport) {
			p, pok := strconv.parse_int(hostport[colon + 1:], 10)
			if !pok || p <= 0 || p > 65535 {
				return
			}
			u.port = p
		}
	} else {
		u.host = hostport
	}
	if len(u.host) == 0 {
		return
	}
	u.origin = raw[:sep + 3 + slash]
	return u, true
}

url_resolve :: proc(base: string, ref: string, allocator := context.allocator) -> string {
	if strings.contains(ref, "://") {
		return strings.clone(ref, allocator)
	}
	b, ok := url_parse(base)
	if !ok {
		return strings.clone(ref, allocator)
	}
	if strings.has_prefix(ref, "//") {
		return strings.concatenate({b.scheme, ":", ref}, allocator)
	}
	if strings.has_prefix(ref, "/") {
		return strings.concatenate({b.origin, ref}, allocator)
	}
	path := b.target
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}
	if strings.has_prefix(ref, "?") {
		return strings.concatenate({b.origin, path, ref}, allocator)
	}
	dir := path[:strings.last_index_byte(path, '/') + 1]
	return strings.concatenate({b.origin, dir, ref}, allocator)
}

package fs

import "base:runtime"

path_parent :: proc "contextless" (rel: string) -> string {
	for i := len(rel) - 1; i >= 0; i -= 1 {
		if rel[i] == '/' {
			return rel[:i]
		}
	}
	return ""
}

path_name :: proc "contextless" (rel: string) -> string {
	for i := len(rel) - 1; i >= 0; i -= 1 {
		if rel[i] == '/' {
			return rel[i + 1:]
		}
	}
	return rel
}

path_under :: proc "contextless" (p, dir: string) -> bool {
	if len(dir) == 0 {
		return len(p) > 0
	}
	return len(p) > len(dir) && p[len(dir)] == '/' && p[:len(dir)] == dir
}

path_at_or_under :: proc "contextless" (p, dir: string) -> bool {
	return p == dir || path_under(p, dir)
}

path_join :: proc(dir, name: string, allocator := context.allocator) -> (out: string, err: runtime.Allocator_Error) {
	if len(dir) == 0 {
		buf := make([]u8, len(name), allocator) or_return
		copy(buf, name)
		return string(buf), nil
	}
	buf := make([]u8, len(dir) + 1 + len(name), allocator) or_return
	n := copy(buf, dir)
	buf[n] = '/'
	copy(buf[n + 1:], name)
	return string(buf), nil
}

path_join_buf :: proc "contextless" (buf: []u8, parts: ..string) -> (string, bool) {
	n := 0
	for p in parts {
		if len(p) == 0 {
			continue
		}
		if n > 0 {
			if n >= len(buf) {
				return "", false
			}
			buf[n] = '/'
			n += 1
		}
		if n + len(p) > len(buf) {
			return "", false
		}
		n += copy(buf[n:], p)
	}
	return string(buf[:n]), true
}

path_valid :: proc "contextless" (rel: string) -> bool {
	if len(rel) == 0 || rel[0] == '/' || rel[len(rel) - 1] == '/' {
		return false
	}
	start := 0
	for i in 0 ..= len(rel) {
		if i == len(rel) || rel[i] == '/' {
			part := rel[start:i]
			if len(part) == 0 || part == "." || part == ".." {
				return false
			}
			start = i + 1
		} else if rel[i] == 0 {
			return false
		}
	}
	return true
}

name_internal :: proc "contextless" (name: string) -> bool {
	if name == ".git" || name == STATE_NAME {
		return true
	}
	return len(name) >= len(TEMP_PREFIX) && name[:len(TEMP_PREFIX)] == TEMP_PREFIX
}

path_internal :: proc "contextless" (rel: string) -> bool {
	start := 0
	for i in 0 ..= len(rel) {
		if i == len(rel) || rel[i] == '/' {
			if name_internal(rel[start:i]) {
				return true
			}
			start = i + 1
		}
	}
	return false
}

git_path_cmp :: proc "contextless" (a: string, a_dir: bool, b: string, b_dir: bool) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	ca: int = -1
	cb: int = -1
	if len(a) > n {
		ca = int(a[n])
	} else if a_dir {
		ca = '/'
	}
	if len(b) > n {
		cb = int(b[n])
	} else if b_dir {
		cb = '/'
	}
	if ca == cb {
		return 0
	}
	return -1 if ca < cb else 1
}

fnv64 :: proc "contextless" (data: string, seed: u64 = 0xcbf29ce484222325) -> u64 {
	h := seed
	for i in 0 ..< len(data) {
		h ~= u64(data[i])
		h *= 0x100000001b3
	}
	return h
}

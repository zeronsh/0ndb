package odb

import "base:runtime"
import "../prim"
import "core:strings"

config_lookup :: proc(text: string, section, key: string) -> (value: string, found: bool) {
	current := ""
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' || l[0] == ';' {
			continue
		}
		if l[0] == '[' {
			end := strings.index_byte(l, ']')
			if end < 0 {
				current = ""
				continue
			}
			name := strings.trim_space(l[1:end])
			if sp := strings.index_any(name, " \t\""); sp >= 0 {
				name = name[:sp]
			}
			current = name
			l = strings.trim_space(l[end + 1:])
			if len(l) == 0 {
				continue
			}
		}
		if !strings.equal_fold(current, section) {
			continue
		}
		name := l
		val := "true"
		if eq := strings.index_byte(l, '='); eq >= 0 {
			name = strings.trim_space(l[:eq])
			val = strings.trim_space(l[eq + 1:])
		}
		if !strings.equal_fold(name, key) {
			continue
		}
		if c := strings.index_any(val, "#;"); c >= 0 {
			val = strings.trim_space(val[:c])
		}
		if len(val) >= 2 && val[0] == '"' && val[len(val) - 1] == '"' {
			val = val[1:len(val) - 1]
		}
		value, found = val, true
	}
	return
}

@(private)
read_object_format :: proc(vfs: prim.Vfs, common_dir: string, allocator: runtime.Allocator) -> (format: Hash_Format, err: Error) {
	buf: [PATH_MAX]u8
	path := concat_into(buf[:], common_dir, "/config") or_return
	text, rerr := vfs_read_file(vfs, path, allocator)
	if rerr == .Not_Found {
		return .Sha1, .None
	}
	if rerr != .None {
		return .Sha1, rerr
	}
	defer delete(text, allocator)
	value, found := config_lookup(string(text), "extensions", "objectformat")
	if !found || strings.equal_fold(value, "sha1") {
		return .Sha1, .None
	}
	if strings.equal_fold(value, "sha256") {
		return .Sha256, .None
	}
	return .Sha1, .Invalid
}

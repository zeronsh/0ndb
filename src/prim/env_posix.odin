#+build linux, darwin
package prim

import "core:strings"
import "core:sys/posix"

environ :: proc(allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	base := posix.environ
	for i := 0; base != nil && base[i] != nil; i += 1 {
		append(&out, string(base[i]))
	}
	return out[:]
}

real_path :: proc(path: string, allocator := context.allocator) -> (string, Error) {
	buf: Path_Buf = ---
	cp, perr := cpath(path, &buf)
	if perr != .None {
		return "", perr
	}
	out: [PATH_MAX + 1]u8
	res := posix.realpath(cp, raw_data(out[:]))
	if res == nil {
		#partial switch posix.errno() {
		case .ENOENT, .ENOTDIR:
			return "", .Not_Found
		case .EACCES:
			return "", .Permission
		case .ENAMETOOLONG:
			return "", .Name_Too_Long
		}
		return "", .Io
	}
	s, err := strings.clone(string(res), allocator)
	if err != nil {
		return "", .No_Memory
	}
	return s, .None
}

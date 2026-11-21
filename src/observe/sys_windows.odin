package observe

import "core:strings"
import "../prim"

@(private)
_strip_firmlink :: proc "contextless" (p: string) -> string {
	return p
}

process_args :: proc(pid: prim.Pid, buf: []u8) -> ([]u8, bool) {
	return nil, false
}

@(private)
_is_sep :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == '/' || c == '\\'
}

@(private)
_is_drive :: proc "contextless" (p: string) -> bool {
	return len(p) >= 3 && ((p[0] >= 'A' && p[0] <= 'Z') || (p[0] >= 'a' && p[0] <= 'z')) && p[1] == ':' && _is_sep(p[2])
}

path_is_abs :: proc "contextless" (p: string) -> bool {
	return _is_drive(p) || (len(p) >= 3 && _is_sep(p[0]) && _is_sep(p[1]) && !_is_sep(p[2]))
}

@(private)
_abs_root_len :: proc "contextless" (p: string) -> int {
	if _is_drive(p) {
		return 2
	}
	if !path_is_abs(p) {
		return -1
	}
	i := 2
	parts := 0
	for i < len(p) && parts < 2 {
		for i < len(p) && !_is_sep(p[i]) {
			i += 1
		}
		parts += 1
		if parts < 2 && i < len(p) {
			i += 1
		}
	}
	return i
}

@(private)
_path_native :: proc(p: string) -> string {
	s := p
	if len(s) >= 4 && _is_sep(s[0]) && _is_sep(s[1]) && (s[2] == '?' || s[2] == '.') && _is_sep(s[3]) {
		s = s[4:]
		if len(s) >= 4 && strings.equal_fold(s[:3], "UNC") && _is_sep(s[3]) {
			s = strings.concatenate({"//", s[4:]}, context.temp_allocator)
		}
	}
	if strings.index_byte(s, '\\') < 0 && !(len(s) >= 2 && s[1] == ':' && s[0] >= 'a' && s[0] <= 'z') {
		return s
	}
	out := transmute([]u8)strings.clone(s, context.temp_allocator)
	for &c in out {
		if c == '\\' {
			c = '/'
		}
	}
	if len(out) >= 2 && out[1] == ':' && out[0] >= 'a' && out[0] <= 'z' {
		out[0] -= 32
	}
	return string(out)
}

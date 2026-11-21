#+build linux, darwin
package prim

import "base:runtime"
import "core:strings"

_Child_Os :: struct {}

@(private)
_child_os_close :: proc "contextless" (c: ^Child) {
}

@(private)
_child_kill :: proc "contextless" (c: ^Child, sig: Signal) -> Error {
	if c.group {
		return kill_group(c.pid, sig)
	}
	return kill_process(c.pid, sig)
}

@(private)
_resolve_exec :: proc(name: string, env: []string, allocator: runtime.Allocator) -> (cstring, Error) {
	if len(name) == 0 {
		return nil, .Not_Found
	}
	if strings.contains_rune(name, '/') {
		p, err := strings.clone_to_cstring(name, allocator)
		if err != nil {
			return nil, .No_Memory
		}
		return p, .None
	}
	search := "/usr/local/bin:/usr/bin:/bin"
	found := false
	if env != nil {
		for kv in env {
			if strings.has_prefix(kv, "PATH=") {
				search = kv[5:]
				found = true
			}
		}
	}
	if !found {
		if v, ok := getenv("PATH"); ok {
			search = v
		}
	}
	rest := search
	for dir in strings.split_iterator(&rest, ":") {
		d := dir if len(dir) > 0 else "."
		full, err := path_join(allocator, d, name)
		if err != .None {
			return nil, err
		}
		buf: Path_Buf = ---
		p, cerr := cpath(full, &buf)
		if cerr == .None && _is_exec_file(p) {
			out, aerr := strings.clone_to_cstring(full, allocator)
			if aerr != nil {
				return nil, .No_Memory
			}
			return out, .None
		}
	}
	return nil, .Not_Found
}

@(private)
_cstrings :: proc(list: []string, allocator: runtime.Allocator) -> ([^]cstring, Error) {
	out, err := make([]cstring, len(list) + 1, allocator)
	if err != nil {
		return nil, .No_Memory
	}
	for s, i in list {
		c, cerr := strings.clone_to_cstring(s, allocator)
		if cerr != nil {
			return nil, .No_Memory
		}
		out[i] = c
	}
	out[len(list)] = nil
	return raw_data(out), .None
}

@(private)
_decode_wait :: proc "contextless" (st: u32) -> Exit_Status {
	sig := st & 0x7f
	if sig == 0 {
		return {code = i32((st >> 8) & 0xff)}
	}
	return {code = -1, signal = i32(sig)}
}

package observe

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "../prim"

Tool_Call :: struct {
	id:        string,
	cwd:       string,
	paths:     [dynamic]string,
	commands:  [dynamic]string,
	allocator: runtime.Allocator,
}

Match :: enum u8 {
	None,
	Inside,
	Sibling,
	Exact,
}

@(rodata)
PATH_KEYS := [?]string {
	"path",
	"paths",
	"file",
	"files",
	"filename",
	"file_path",
	"filepath",
	"notebook_path",
	"target",
	"target_file",
	"destination",
	"dest",
	"source",
	"src",
	"dir",
	"directory",
	"output",
	"output_path",
	"out",
	"to",
	"from",
	"old_path",
	"new_path",
	"move_path",
	"location",
	"uri",
}

@(rodata)
BASE_KEYS := [?]string{"cwd", "workdir", "working_directory"}

@(rodata)
COMMAND_KEYS := [?]string{"command", "cmd", "commands", "script", "argv", "args"}

tool_call_init :: proc(c: ^Tool_Call, id: string, input: []u8, cwd: string, canonical := true, allocator := context.allocator) -> bool {
	c^ = {
		allocator = allocator,
	}
	c.paths = make([dynamic]string, allocator)
	c.commands = make([dynamic]string, allocator)
	c.id = strings.clone(id, allocator)
	v, err := json.parse(input, .JSON, true, context.temp_allocator)
	base := cwd
	if err == .None {
		if obj, ok := v.(json.Object); ok {
			if s, sok := obj["cwd"].(json.String); sok && len(s) > 0 {
				base = s if s[0] == '/' else _join(cwd, s, context.temp_allocator)
			} else if s2, sok2 := obj["workdir"].(json.String); sok2 && len(s2) > 0 {
				base = s2 if s2[0] == '/' else _join(cwd, s2, context.temp_allocator)
			}
		}
	}
	c.cwd = strings.clone(base, allocator)
	if err != .None {
		_collect_text(c, string(input))
		return false
	}
	_collect(c, v, "")
	if canonical {
		for &p in c.paths {
			if real, ok := _canonical(p, allocator); ok {
				delete(p, allocator)
				p = real
			}
		}
	}
	return true
}

tool_call_destroy :: proc(c: ^Tool_Call) {
	for p in c.paths {
		delete(p, c.allocator)
	}
	for s in c.commands {
		delete(s, c.allocator)
	}
	delete(c.paths)
	delete(c.commands)
	delete(c.id, c.allocator)
	delete(c.cwd, c.allocator)
	c^ = {}
}

@(private)
_is_key :: proc(key: string, list: []string) -> bool {
	k := strings.to_lower(key, context.temp_allocator)
	for x in list {
		if k == x {
			return true
		}
	}
	return false
}

@(private)
_collect :: proc(c: ^Tool_Call, v: json.Value, key: string) {
	#partial switch x in v {
	case json.Object:
		for k, child in x {
			_collect(c, child, k)
		}
	case json.Array:
		if _is_key(key, COMMAND_KEYS[:]) && len(x) > 0 {
			all := true
			for e in x {
				if _, ok := e.(json.String); !ok {
					all = false
				}
			}
			if all {
				b := strings.builder_make(context.temp_allocator)
				for e, i in x {
					if i > 0 {
						strings.write_byte(&b, 0)
					}
					strings.write_string(&b, e.(json.String))
				}
				_add_command(c, strings.to_string(b))
				for e in x {
					_collect_text(c, e.(json.String))
				}
				return
			}
		}
		for e in x {
			_collect(c, e, key)
		}
	case json.String:
		if _is_key(key, BASE_KEYS[:]) {
			return
		}
		if _is_key(key, COMMAND_KEYS[:]) {
			_add_command(c, x)
			return
		}
		if _is_key(key, PATH_KEYS[:]) {
			_add_path(c, x)
			return
		}
		_collect_text(c, x)
	}
}

@(private)
_collect_text :: proc(c: ^Tool_Call, s: string) {
	if strings.contains(s, "*** Begin Patch") || strings.contains(s, "\n+++ ") || strings.has_prefix(s, "--- ") || strings.has_prefix(s, "+++ ") {
		_collect_patch(c, s)
		return
	}
	if len(s) > 1 && len(s) < prim.PATH_MAX && (s[0] == '/' || strings.has_prefix(s, "file://")) && strings.index_any(s, "\n\r\t") < 0 {
		_add_path(c, s)
	}
}

@(private)
_collect_patch :: proc(c: ^Tool_Call, s: string) {
	rest := s
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		for prefix in ([]string{"*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "}) {
			if strings.has_prefix(l, prefix) {
				_add_path(c, strings.trim_space(l[len(prefix):]))
			}
		}
		if strings.has_prefix(l, "+++ ") || strings.has_prefix(l, "--- ") {
			p := strings.trim_space(l[4:])
			if i := strings.index_byte(p, '\t'); i >= 0 {
				p = p[:i]
			}
			if p == "/dev/null" {
				continue
			}
			if strings.has_prefix(p, "a/") || strings.has_prefix(p, "b/") {
				p = p[2:]
			}
			_add_path(c, p)
		}
	}
}

@(private)
_add_command :: proc(c: ^Tool_Call, s: string) {
	if len(strings.trim_space(s)) == 0 {
		return
	}
	for x in c.commands {
		if x == s {
			return
		}
	}
	append(&c.commands, strings.clone(s, c.allocator))
}

@(private)
_add_path :: proc(c: ^Tool_Call, raw: string) {
	s := raw
	if strings.has_prefix(s, "file://") {
		s = s[7:]
	}
	if len(s) == 0 || len(s) >= prim.PATH_MAX || strings.index_any(s, "\n\r\x00") >= 0 {
		return
	}
	if strings.has_prefix(s, "~/") {
		if home, ok := prim.getenv("HOME"); ok {
			s = _join(home, s[2:], context.temp_allocator)
		}
	}
	abs := s if s[0] == '/' else _join(c.cwd, s, context.temp_allocator)
	clean := clean_abs(abs, context.temp_allocator)
	if len(clean) == 0 {
		return
	}
	for x in c.paths {
		if x == clean {
			return
		}
	}
	append(&c.paths, strings.clone(clean, c.allocator))
}

@(private)
_join :: proc(a: string, b: string, allocator: runtime.Allocator) -> string {
	if len(a) == 0 {
		return strings.clone(b, allocator)
	}
	if a[len(a) - 1] == '/' {
		return strings.concatenate({a, b}, allocator)
	}
	return strings.concatenate({a, "/", b}, allocator)
}

clean_abs :: proc(p: string, allocator := context.allocator) -> string {
	if len(p) == 0 || p[0] != '/' {
		return ""
	}
	parts := make([dynamic]string, context.temp_allocator)
	rest := p
	for comp in strings.split_iterator(&rest, "/") {
		switch comp {
		case "", ".":
		case "..":
			if len(parts) > 0 {
				pop(&parts)
			}
		case:
			append(&parts, comp)
		}
	}
	if len(parts) == 0 {
		return strings.clone("/", allocator)
	}
	b := strings.builder_make(allocator)
	for x in parts {
		strings.write_byte(&b, '/')
		strings.write_string(&b, x)
	}
	return strings.to_string(b)
}

@(private)
_canonical :: proc(p: string, allocator: runtime.Allocator) -> (string, bool) {
	if real, _, _, ok := real_path(p, allocator); ok {
		return real, true
	}
	dir := p
	for {
		i := strings.last_index_byte(dir, '/')
		if i <= 0 {
			return "", false
		}
		tail := p[i:]
		dir = dir[:i]
		if real, _, _, ok := real_path(dir, context.temp_allocator); ok {
			if real == "/" {
				return strings.clone(tail, allocator), true
			}
			return strings.concatenate({real, tail}, allocator), true
		}
	}
}

match_path :: proc(c: ^Tool_Call, path: string) -> Match {
	best := Match.None
	for t in c.paths {
		m := _match_one(t, path)
		if m > best {
			best = m
		}
	}
	return best
}

@(private)
_match_one :: proc(target: string, path: string) -> Match {
	if target == path {
		return .Exact
	}
	if rel, ok := under(path, target); ok && len(rel) > 0 {
		return .Inside
	}
	ti := strings.last_index_byte(target, '/')
	pi := strings.last_index_byte(path, '/')
	if ti < 0 || pi < 0 || target[:ti] != path[:pi] {
		return .None
	}
	tn := target[ti + 1:]
	pn := path[pi + 1:]
	if len(tn) == 0 || len(pn) <= len(tn) {
		return .None
	}
	if strings.has_prefix(pn, tn) {
		c := pn[len(tn)]
		if c == '.' || c == '~' || c == '-' || c == '_' || c == '#' {
			return .Sibling
		}
	}
	if (pn[0] == '.' || pn[0] == '#') && strings.has_prefix(pn[1:], tn) {
		return .Sibling
	}
	return .None
}

match_write :: proc(calls: []Tool_Call, paths: ..string) -> (index: int, ambiguous: bool) {
	index = -1
	best := Match.None
	for &c, i in calls {
		m := Match.None
		for p in paths {
			if len(p) > 0 {
				m = max(m, match_path(&c, p))
			}
		}
		if m == .None {
			continue
		}
		if m > best {
			best = m
			index = i
			ambiguous = false
		} else if m == best && index >= 0 && calls[index].id != c.id {
			ambiguous = true
		}
	}
	return
}

match_command :: proc(calls: []Tool_Call, cmdline: []u8) -> (index: int, ambiguous: bool) {
	index = -1
	if len(cmdline) == 0 {
		return
	}
	line := string(cmdline)
	spaced := make([]u8, len(cmdline), context.temp_allocator)
	for b, i in cmdline {
		spaced[i] = ' ' if b == 0 else b
	}
	flat := string(spaced)
	best := 0
	for &c, i in calls {
		score := 0
		for cmd in c.commands {
			if len(cmd) > score && (strings.contains(line, cmd) || strings.contains(flat, cmd) || strings.contains(line, _shell_quoted(cmd))) {
				score = len(cmd)
			}
		}
		if score == 0 {
			continue
		}
		if score > best {
			best = score
			index = i
			ambiguous = false
		} else if score == best && calls[index].id != c.id {
			ambiguous = true
		}
	}
	return
}

@(private)
_shell_quoted :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "'", "'\\''", context.temp_allocator)
	return out
}

attribute :: proc(calls: []Tool_Call, w: ^Write, agent: prim.Pid) -> (index: int, ambiguous: bool) {
	index = -1
	if len(calls) == 0 {
		return
	}
	if w.pid != agent {
		child := prim.Pid(0)
		for p, i in w.lineage {
			if p == agent && i > 0 {
				child = w.lineage[i - 1]
				break
			}
		}
		args := w.args
		buf: [8192]u8
		if len(args) == 0 && child > 0 {
			if a, ok := process_args(child, buf[:]); ok {
				args = a
			}
		}
		if len(args) > 0 {
			index, ambiguous = match_command(calls, args)
			if index >= 0 && !ambiguous {
				return
			}
		}
	}
	return match_write(calls, w.path, w.from)
}

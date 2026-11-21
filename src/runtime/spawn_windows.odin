package rt

import "core:strings"
import "../fs"
import "../observe"
import "../prim"

@(private)
SHIM_MAX :: 16 * 1024

@(private)
Window_Spawn :: struct {
	r:        ^Runtime,
	w:        ^observe.Window,
	fallback: Spawner,
}

window_spawner :: proc(r: ^Runtime, w: ^observe.Window) -> Spawner {
	s := new(Window_Spawn, r.allocator)
	s.r = r
	s.w = w
	s.fallback = engine_spawner(r.e)
	observe.window_set_decider(w, window_decider(r))
	return Spawner{data = s, spawn = _window_spawn}
}

window_spawner_free :: proc(r: ^Runtime, sp: Spawner) {
	if sp.spawn == _window_spawn && sp.data != nil {
		s := (^Window_Spawn)(sp.data)
		if s.w.decider.data == r {
			observe.window_set_decider(s.w, {})
		}
		free(s, r.allocator)
	}
}

window_decider :: proc(r: ^Runtime) -> observe.Decider {
	return observe.Decider{data = r, decide = _window_decide}
}

@(private)
_window_spawn :: proc(data: rawptr, req: ^Spawn_Request) -> (prim.Child, prim.Error) {
	s := (^Window_Spawn)(data)
	sub := req^
	if argv, ok := direct_argv(req.argv, _env_merge(req.env)); ok {
		sub.argv = argv
	}
	child, err := s.fallback.spawn(s.fallback.data, &sub)
	if err == .None && req.observe {
		observe.window_add_root(s.w, child.pid)
	}
	return child, err
}

@(private)
_window_decide :: proc(data: rawptr, m: ^fs.Mount, w: ^observe.Write) -> (^fs.Scope, bool) {
	r := (^Runtime)(data)
	for run in r.runs {
		if !_run_has_mount(run, m) {
			continue
		}
		calls, idx := _open_calls(run)
		if !w.window || len(calls) == 0 {
			continue
		}
		k, ambiguous := observe.attribute_window(calls, w)
		if k >= 0 && !ambiguous {
			if s := _run_scope(run, m, idx[k]); s != nil {
				r.stats.inexact += 1
				return s, true
			}
			continue
		}
		if ambiguous {
			if s := _run_scope(run, m, -1); s != nil {
				r.stats.inexact += 1
				return s, true
			}
		}
	}
	return nil, false
}

direct_argv :: proc(argv: []string, env: []string, allocator := context.temp_allocator) -> ([]string, bool) {
	if len(argv) == 0 {
		return nil, false
	}
	exe, batch, err := prim.resolve_executable(argv[0], env, context.temp_allocator)
	if err != .None || !batch || !_has_suffix_fold(exe, ".cmd") {
		return nil, false
	}
	return npm_shim_argv(exe, argv[1:], env, allocator)
}

npm_shim_argv :: proc(shim: string, args: []string, env: []string, allocator := context.temp_allocator) -> ([]string, bool) {
	text, rerr := prim.read_file(prim.os_vfs(), shim, context.temp_allocator)
	if rerr != .None || len(text) == 0 || len(text) > SHIM_MAX {
		return nil, false
	}
	dir := prim.dir_name(shim)
	lines := strings.split_lines(string(text), context.temp_allocator)
	progs := make([dynamic]string, context.temp_allocator)
	cmds := make([dynamic]string, context.temp_allocator)
	exist := ""
	exist_before := -1
	for raw in lines {
		line := strings.trim_space(strings.trim_right(raw, "\r"))
		low := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(low, "@") {
			low = low[1:]
			line = line[1:]
		}
		if strings.has_prefix(low, "if exist \"") && len(exist) == 0 {
			rest := line[len("if exist \""):]
			if q := strings.index_byte(rest, '"'); q > 0 {
				exist = _shim_expand(rest[:q], dir)
				exist_before = len(cmds)
			}
			continue
		}
		if strings.has_prefix(low, "set \"_prog=") {
			v := line[len("set \"_prog="):]
			if q := strings.last_index_byte(v, '"'); q >= 0 {
				v = v[:q]
			}
			append(&progs, _shim_expand(v, dir))
			continue
		}
		if strings.contains(line, "%*") {
			append(&cmds, line)
		}
	}
	if len(cmds) == 0 {
		return nil, false
	}
	have := len(exist) > 0 && _file_exists(exist)
	cmd := cmds[len(cmds) - 1]
	if len(cmds) >= 2 && exist_before == 0 && have {
		cmd = cmds[0]
	}
	tokens, tok_ok := _shim_tokens(cmd)
	if !tok_ok || len(tokens) == 0 {
		return nil, false
	}
	out := make([dynamic]string, allocator)
	for t, i in tokens {
		v := t
		if strings.equal_fold(v, "%_prog%") {
			if len(progs) == 0 {
				return nil, false
			}
			v = progs[0] if have || len(progs) == 1 else progs[1]
		} else {
			v = _shim_expand(v, dir)
		}
		if strings.index_byte(v, '%') >= 0 || len(v) == 0 {
			return nil, false
		}
		if i == 0 {
			resolved, batch, err := prim.resolve_executable(v, env, allocator)
			if err != .None || batch {
				return nil, false
			}
			v = resolved
		} else if _looks_path(v) && !_file_exists(v) {
			return nil, false
		}
		append(&out, strings.clone(v, allocator))
	}
	for a in args {
		append(&out, a)
	}
	return out[:], true
}

shell_argv :: proc(cmd: string, allocator := context.temp_allocator) -> []string {
	if git, batch, err := prim.resolve_executable("git", nil, context.temp_allocator); err == .None && !batch {
		root := prim.dir_name(prim.dir_name(git))
		for rel in ([]string{"bin/bash.exe", "usr/bin/bash.exe"}) {
			if p, perr := prim.path_join(context.temp_allocator, root, rel); perr == .None && _file_exists(p) {
				out := make([]string, 3, allocator)
				out[0] = strings.clone(p, allocator)
				out[1] = "-c"
				out[2] = cmd
				return out
			}
		}
	}
	out := make([]string, 5, allocator)
	out[0] = "powershell.exe"
	out[1] = "-NoProfile"
	out[2] = "-NonInteractive"
	out[3] = "-Command"
	out[4] = cmd
	return out
}

@(private)
_shim_expand :: proc(s: string, dir: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		rest := s[i:]
		if len(rest) >= 5 && strings.equal_fold(rest[:5], "%~dp0") {
			strings.write_string(&b, dir)
			strings.write_byte(&b, '\\')
			i += 5
			continue
		}
		if len(rest) >= 5 && strings.equal_fold(rest[:5], "%dp0%") {
			strings.write_string(&b, dir)
			strings.write_byte(&b, '\\')
			i += 5
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	raw := strings.to_string(b)
	out := make([]u8, len(raw), context.temp_allocator)
	n := 0
	for c, k in transmute([]u8)raw {
		sep := c == '\\' || c == '/'
		if sep && k > 1 && n > 0 && (out[n - 1] == '\\' || out[n - 1] == '/') {
			continue
		}
		out[n] = c
		n += 1
	}
	return string(out[:n])
}

@(private)
_shim_tokens :: proc(line: string) -> ([]string, bool) {
	start := 0
	quoted := false
	for i in 0 ..< len(line) {
		switch line[i] {
		case '"':
			quoted = !quoted
		case '&':
			if !quoted {
				start = i + 1
			}
		}
	}
	seg := line[start:]
	toks := make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(seg) {
		for i < len(seg) && (seg[i] == ' ' || seg[i] == '\t') {
			i += 1
		}
		if i >= len(seg) {
			break
		}
		if seg[i] == '"' {
			j := i + 1
			for j < len(seg) && seg[j] != '"' {
				j += 1
			}
			if j >= len(seg) {
				return nil, false
			}
			append(&toks, seg[i + 1:j])
			i = j + 1
			continue
		}
		j := i
		for j < len(seg) && seg[j] != ' ' && seg[j] != '\t' {
			j += 1
		}
		tok := seg[i:j]
		i = j
		if tok == "%*" {
			return toks[:], true
		}
		if strings.index_any(tok, "<>|&()^") >= 0 {
			return nil, false
		}
		append(&toks, tok)
	}
	return nil, false
}

@(private)
_looks_path :: proc(s: string) -> bool {
	return strings.index_any(s, "\\/") >= 0
}

@(private)
_file_exists :: proc(p: string) -> bool {
	st, err := prim.stat(prim.os_vfs(), p)
	return err == .None && st.kind == .File
}

@(private)
_has_suffix_fold :: proc(s, suffix: string) -> bool {
	return len(s) >= len(suffix) && strings.equal_fold(s[len(s) - len(suffix):], suffix)
}

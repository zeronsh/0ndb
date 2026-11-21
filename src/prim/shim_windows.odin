package prim

import "core:strings"

@(private)
SHIM_MAX :: 16 * 1024

npm_shim_argv :: proc(shim: string, args: []string, env: []string = nil, allocator := context.temp_allocator) -> ([]string, bool) {
	text, rerr := read_file(os_vfs(), shim, context.temp_allocator)
	if rerr != .None || len(text) == 0 || len(text) > SHIM_MAX {
		return nil, false
	}
	dir := dir_name(shim)
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
	have := len(exist) > 0 && _is_file(exist)
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
			resolved, batch, err := _resolve_exec_windows(v, env, allocator)
			if err != .None || batch {
				return nil, false
			}
			v = resolved
		} else if strings.index_any(v, "\\/") >= 0 && !_is_file(v) {
			return nil, false
		}
		append(&out, strings.clone(v, allocator))
	}
	for a in args {
		append(&out, a)
	}
	return out[:], true
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

package agent

import "core:crypto/legacy/md5"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf16"

PORT_FORMAT :: "ondb-agent-session/1"

Port_Env :: struct {
	home:    string,
	cwd:     string,
	scratch: string,
	env:     []string,
}

Port_File :: struct {
	key:      string,
	path:     string,
	match:    string,
	dir:      bool,
	optional: bool,
	rewrite:  bool,
}

Port_Run :: struct {
	argv:   []string,
	cwd:    string,
	env:    []string,
	stdout: string,
}

Rewrite :: struct {
	from: string,
	to:   string,
}

Port_Plan :: struct {
	files:    []Port_File,
	runs:     []Port_Run,
	rewrites: []Rewrite,
	session:  string,
	seeded:   bool,
	reason:   string,
}

export_session :: proc(desc: Provider_Descriptor, env: Port_Env, session: string, native_path := "", allocator := context.allocator) -> Port_Plan {
	context.allocator = allocator
	files := make([dynamic]Port_File)
	runs := make([dynamic]Port_Run)
	plan := Port_Plan {
		session = strings.clone(session),
	}
	root := store_root(desc.store, env)
	switch desc.store {
	case .None:
		plan.seeded = true
		plan.reason = "this provider keeps sessions in a shared database with no per-session export"
	case .Claude_Projects:
		dir := join({root, "projects", claude_key(env.cwd)})
		append(&files, Port_File{key = "transcript", path = join({dir, strings.concatenate({session, ".jsonl"})}), rewrite = true})
		append(&files, Port_File{key = "session_dir", path = join({dir, session}), dir = true, optional = true, rewrite = true})
	case .Codex_Rollouts:
		if native_path != "" {
			append(&files, Port_File{key = "rollout", path = strings.clone(native_path), rewrite = true})
		} else {
			append(&files, Port_File{key = "rollout", path = join({root, "sessions"}), match = strings.concatenate({"-", session, ".jsonl"}), rewrite = true})
		}
	case .Pi_Sessions:
		path := native_path != "" ? native_path : session
		append(&files, Port_File{key = "session", path = strings.clone(path), rewrite = true})
	case .Muse_Sessions:
		if native_path != "" {
			append(&files, Port_File{key = "session", path = strings.clone(native_path)})
		} else {
			append(&files, Port_File{key = "session", path = join({root, "sessions"}), match = strings.concatenate({"/", session, "/session.jsonl"})})
		}
	case .OpenCode_Cli:
		append(&runs, Port_Run{argv = clone_list({desc.argv[0], "export", session}), cwd = strings.clone(env.cwd), env = clone_list(env.env), stdout = "session"})
	case .Hermes_Cli:
		out := join({env.scratch, strings.concatenate({"hermes-", session, ".jsonl"})})
		append(&runs, Port_Run{argv = clone_list({desc.argv[0], "sessions", "export", "--format", "trace", "--session-id", session, "--yes", out}), cwd = strings.clone(env.cwd), env = clone_list(env.env)})
		append(&files, Port_File{key = "trace", path = out, rewrite = true})
	case .Cursor_Chats:
		append(&files, Port_File{key = "chat", path = join({root, "chats", md5_hex(env.cwd), session}), dir = true})
	case .Antigravity_Conversations:
		conv := join({root, "antigravity-acp", "conversations"})
		append(&files, Port_File{key = "trajectory", path = join({conv, strings.concatenate({session, ".db"})})})
		append(&files, Port_File{key = "meta", path = join({conv, strings.concatenate({session, ".meta"})}), optional = true, rewrite = true})
		append(&files, Port_File{key = "brain", path = join({root, "antigravity-acp", "brain", session}), dir = true, optional = true})
	}
	plan.files = files[:]
	plan.runs = runs[:]
	return plan
}

export_manifest :: proc(desc: Provider_Descriptor, env: Port_Env, session: string, files: []Port_File, allocator := context.allocator) -> string {
	root := store_root(desc.store, env)
	b := make([dynamic]u8, allocator)
	append(&b, '{')
	f_str(&b, "format", PORT_FORMAT)
	f_str(&b, "provider", desc.id)
	key(&b, "store")
	w_int(&b, i64(desc.store))
	f_str(&b, "session", session)
	f_str(&b, "cwd", env.cwd)
	f_str(&b, "home", env.home)
	f_str(&b, "root", root)
	f_arr(&b, "files")
	for f in files {
		open(&b)
		f_str(&b, "key", f.key)
		f_str(&b, "path", f.path)
		f_str(&b, "rel", relative(root, f.path))
		f_bool(&b, "dir", f.dir)
		close_obj(&b)
	}
	close_arr(&b)
	close_obj(&b)
	return string(b[:])
}

import_session :: proc(desc: Provider_Descriptor, manifest: string, env: Port_Env, allocator := context.allocator) -> Port_Plan {
	context.allocator = allocator
	plan: Port_Plan
	m, err := json.parse_string(manifest, .JSON, true, context.temp_allocator)
	if err != .None || get_str(m, "format") != PORT_FORMAT || get_str(m, "provider") != desc.id {
		plan.seeded = true
		plan.reason = "the bundle is not a session export of this provider"
		return plan
	}
	if desc.store == .None || int(get_u64(m, "store")) != int(desc.store) {
		plan.seeded = true
		plan.reason = "this provider cannot import native sessions"
		return plan
	}
	session := get_str(m, "session")
	old_cwd := get_str(m, "cwd")
	old_home := get_str(m, "home")
	old_root := get_str(m, "root")
	root := store_root(desc.store, env)
	files := make([dynamic]Port_File)
	runs := make([dynamic]Port_Run)
	rewrites := make([dynamic]Rewrite)
	add_rewrite :: proc(list: ^[dynamic]Rewrite, from, to: string) {
		if from != "" && from != to {
			append(list, Rewrite{from = strings.clone(from), to = strings.clone(to)})
		}
	}
	plan.session = strings.clone(session)
	for f in get_arr(m, "files") {
		rel := get_str(f, "rel")
		k := get_str(f, "key")
		dst := ""
		switch desc.store {
		case .None, .OpenCode_Cli:
		case .Claude_Projects:
			dir := join({root, "projects", claude_key(env.cwd)})
			dst = k == "transcript" ? join({dir, strings.concatenate({session, ".jsonl"})}) : join({dir, session})
		case .Codex_Rollouts, .Muse_Sessions, .Antigravity_Conversations:
			dst = rel != "" ? join({root, rel}) : ""
		case .Pi_Sessions:
			dir := pi_sessions_dir(env)
			path := get_str(f, "path")
			base := path[strings.last_index_byte(path, '/') + 1:]
			dst = join({dir, strings.concatenate({"--", pi_key(env.cwd), "--"}), base})
			delete(plan.session)
			plan.session = strings.clone(dst)
		case .Hermes_Cli:
			dst = join({env.scratch, strings.concatenate({"hermes-", session, ".jsonl"})})
		case .Cursor_Chats:
			dst = join({root, "chats", md5_hex(env.cwd), session})
		}
		if dst == "" {
			continue
		}
		rewrite := desc.store != .Muse_Sessions && desc.store != .Cursor_Chats && k != "trajectory" && k != "brain"
		append(&files, Port_File{key = strings.clone(k), path = dst, dir = get_bool(f, "dir"), rewrite = rewrite})
	}
	#partial switch desc.store {
	case .Claude_Projects:
		add_rewrite(&rewrites, join({old_root, "projects", claude_key(old_cwd)}, context.temp_allocator), join({root, "projects", claude_key(env.cwd)}, context.temp_allocator))
		add_rewrite(&rewrites, claude_key(old_cwd), claude_key(env.cwd))
	case .OpenCode_Cli:
		dst := join({env.scratch, strings.concatenate({"opencode-", session, ".json"})})
		append(&files, Port_File{key = strings.clone("session"), path = dst, rewrite = true})
		append(&runs, Port_Run{argv = clone_list({desc.argv[0], "import", dst}), cwd = strings.clone(env.cwd), env = clone_list(env.env)})
		if len(old_cwd) > 1 && len(env.cwd) > 1 {
			add_rewrite(&rewrites, strings.concatenate({`"`, old_cwd[1:], `"`}, context.temp_allocator), strings.concatenate({`"`, env.cwd[1:], `"`}, context.temp_allocator))
		}
	case .Hermes_Cli:
		dst := join({env.scratch, strings.concatenate({"hermes-", session, ".jsonl"})})
		append(&runs, Port_Run{argv = clone_list({desc.argv[0], "sessions", "import", "--from", "claude", dst}), cwd = strings.clone(env.cwd), env = clone_list(env.env), stdout = "result"})
		delete(plan.session)
		plan.session = ""
	}
	add_rewrite(&rewrites, old_root, root)
	add_rewrite(&rewrites, old_cwd, env.cwd)
	add_rewrite(&rewrites, old_home, env.home)
	plan.files = files[:]
	plan.runs = runs[:]
	plan.rewrites = rewrites[:]
	return plan
}

import_result :: proc(desc: Provider_Descriptor, plan: Port_Plan, outputs: []string, allocator := context.allocator) -> string {
	if plan.session != "" {
		return strings.clone(plan.session, allocator)
	}
	if desc.store == .Hermes_Cli {
		MARK :: "session as "
		for out in outputs {
			if i := strings.index(out, MARK); i >= 0 {
				rest := out[i + len(MARK):]
				end := 0
				for end < len(rest) && rest[end] != '\n' && rest[end] != ' ' && rest[end] != '\r' {
					end += 1
				}
				return strings.clone(rest[:end], allocator)
			}
		}
	}
	return ""
}

apply_rewrites :: proc(plan: Port_Plan, data: []u8, allocator := context.allocator) -> []u8 {
	if len(plan.rewrites) == 0 {
		return data
	}
	for c in data {
		if c == 0 {
			return data
		}
	}
	order := make([]Rewrite, len(plan.rewrites), context.temp_allocator)
	copy(order, plan.rewrites)
	for i in 1 ..< len(order) {
		for j := i; j > 0 && len(order[j].from) > len(order[j - 1].from); j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	out := make([dynamic]u8, 0, len(data), allocator)
	text := string(data)
	i := 0
	scan: for i < len(text) {
		for r in order {
			if strings.has_prefix(text[i:], r.from) {
				append(&out, r.to)
				i += len(r.from)
				continue scan
			}
		}
		append(&out, text[i])
		i += 1
	}
	return out[:]
}

port_destroy :: proc(plan: ^Port_Plan, allocator := context.allocator) {
	for f in plan.files {
		delete(f.key, allocator)
		delete(f.path, allocator)
		delete(f.match, allocator)
	}
	delete(plan.files, allocator)
	for r in plan.runs {
		drop_strings(r.argv, allocator)
		drop_strings(r.env, allocator)
		delete(r.cwd, allocator)
		delete(r.stdout, allocator)
	}
	delete(plan.runs, allocator)
	for r in plan.rewrites {
		delete(r.from, allocator)
		delete(r.to, allocator)
	}
	delete(plan.rewrites, allocator)
	delete(plan.session, allocator)
	plan^ = {}
}

@(private)
clone_list :: proc(list: []string) -> []string {
	out := make([]string, len(list))
	for s, i in list {
		out[i] = strings.clone(s)
	}
	return out
}

@(private)
join :: proc(parts: []string, allocator := context.allocator) -> string {
	b := make([dynamic]u8, allocator)
	for p, i in parts {
		if i > 0 && (len(b) == 0 || b[len(b) - 1] != '/') {
			append(&b, '/')
		}
		append(&b, i > 0 ? strings.trim_left(p, "/") : p)
	}
	return string(b[:])
}

@(private)
relative :: proc(root, path: string) -> string {
	if root != "" && strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/' {
		return path[len(root) + 1:]
	}
	return ""
}

@(private)
env_get :: proc(env: []string, name: string) -> string {
	for e in env {
		if len(e) > len(name) && strings.has_prefix(e, name) && e[len(name)] == '=' {
			return e[len(name) + 1:]
		}
	}
	return ""
}

@(private)
store_root :: proc(store: Store, env: Port_Env) -> string {
	pick :: proc(env: Port_Env, var: string, parts: []string) -> string {
		if v := env_get(env.env, var); v != "" {
			return v
		}
		return join(parts, context.temp_allocator)
	}
	switch store {
	case .None, .OpenCode_Cli, .Hermes_Cli:
		return ""
	case .Claude_Projects:
		return pick(env, "CLAUDE_CONFIG_DIR", {env.home, ".claude"})
	case .Codex_Rollouts:
		return pick(env, "CODEX_HOME", {env.home, ".codex"})
	case .Pi_Sessions:
		return pi_sessions_dir(env)
	case .Muse_Sessions:
		if v := env_get(env.env, "XDG_DATA_HOME"); v != "" {
			return join({v, "muse"}, context.temp_allocator)
		}
		return join({env.home, ".local", "share", "muse"}, context.temp_allocator)
	case .Cursor_Chats:
		if v := env_get(env.env, "CURSOR_CONFIG_DIR"); v != "" {
			return v
		}
		if v := env_get(env.env, "XDG_CONFIG_HOME"); v != "" {
			return join({v, "cursor"}, context.temp_allocator)
		}
		return join({env.home, ".cursor"}, context.temp_allocator)
	case .Antigravity_Conversations:
		return pick(env, "GEMINI_HOME", {env.home, ".gemini"})
	}
	return ""
}

@(private)
pi_sessions_dir :: proc(env: Port_Env) -> string {
	if v := env_get(env.env, "PI_CODING_AGENT_SESSION_DIR"); v != "" {
		return v
	}
	if v := env_get(env.env, "PI_CODING_AGENT_DIR"); v != "" {
		return join({v, "sessions"}, context.temp_allocator)
	}
	return join({env.home, ".pi", "agent", "sessions"}, context.temp_allocator)
}

@(private)
pi_key :: proc(cwd: string) -> string {
	s := strings.trim_left(cwd, "/")
	b := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		b[i] = c == '/' || c == '\\' || c == ':' ? '-' : c
	}
	return string(b)
}

@(private)
claude_key :: proc(cwd: string) -> string {
	units := make([]u16, len(cwd) * 2 + 2, context.temp_allocator)
	n := utf16.encode_string(units, cwd)
	units = units[:n]
	b := make([dynamic]u8, 0, n + 16, context.temp_allocator)
	for u in units {
		alnum := (u >= '0' && u <= '9') || (u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z')
		append(&b, alnum ? u8(u) : '-')
	}
	if len(b) <= 200 {
		return string(b[:])
	}
	h: i32 = 0
	for u in units {
		h = (h << 5) - h + i32(u)
	}
	v := abs(i64(h))
	digits := "0123456789abcdefghijklmnopqrstuvwxyz"
	buf: [16]u8
	i := len(buf)
	for {
		i -= 1
		buf[i] = digits[v % 36]
		v /= 36
		if v == 0 {
			break
		}
	}
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, string(b[:200]))
	append(&out, '-')
	append(&out, string(buf[i:]))
	return string(out[:])
}

@(private)
md5_hex :: proc(s: string) -> string {
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, transmute([]u8)s)
	sum: [md5.DIGEST_SIZE]u8
	md5.final(&ctx, sum[:])
	hex := "0123456789abcdef"
	out := make([]u8, 32, context.temp_allocator)
	for x, i in sum {
		out[2 * i] = hex[x >> 4]
		out[2 * i + 1] = hex[x & 0xf]
	}
	return string(out)
}

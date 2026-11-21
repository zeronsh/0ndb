package agent

import "core:encoding/json"
import "core:strings"

REDACTED :: "[redacted]"

Purge_Target :: struct {
	from:      string,
	to:        string,
	text:      string,
	keep_from: bool,
}

Purge_Format :: enum u8 {
	None,
	Claude_Jsonl,
	Codex_Jsonl,
	Pi_Jsonl,
	OpenCode_Json,
}

Purge_Step_Kind :: enum u8 {
	Edit,
	Scrub,
	Run,
	Write,
	Delete,
	Sql,
}

Purge_Step :: struct {
	kind:     Purge_Step_Kind,
	path:     string,
	match:    string,
	key:      string,
	argv:     []string,
	cwd:      string,
	env:      []string,
	sql:      string,
	script:   string,
	args:     []string,
	launcher: string,
	optional: bool,
}

Purge_Plan :: struct {
	steps:   []Purge_Step,
	format:  Purge_Format,
	targets: []Purge_Target,
	session: string,
	seeded:  bool,
	reason:  string,
}

purge :: proc(d: ^Driver, env: Port_Env, targets: []Purge_Target, allocator := context.allocator) -> Purge_Plan {
	plan := purge_session(d.desc, env, d.session, d.native_path, targets, allocator)
	d.ready = false
	return plan
}

purge_session :: proc(desc: Provider_Descriptor, env: Port_Env, session, native_path: string, targets: []Purge_Target, allocator := context.allocator) -> Purge_Plan {
	context.allocator = allocator
	steps := make([dynamic]Purge_Step)
	plan := Purge_Plan {
		session = strings.clone(session),
	}
	owned := make([]Purge_Target, len(targets))
	for t, i in targets {
		owned[i] = Purge_Target{from = strings.clone(t.from), to = strings.clone(t.to), text = strings.clone(t.text), keep_from = t.keep_from}
	}
	plan.targets = owned
	root := store_root(desc.store, env)
	run :: proc(argv: []string, cwd: string, env: []string, key := "") -> Purge_Step {
		return Purge_Step{kind = .Run, argv = clone_list(argv), cwd = strings.clone(cwd), env = clone_list(env), key = strings.clone(key)}
	}
	switch desc.store {
	case .None:
		plan.seeded = true
		plan.reason = "this provider keeps sessions in a shared database; the session is replaced by a fresh one seeded with the redacted transcript"
		if desc.id == "devin" {
			append(&steps, run({desc.argv[0], "rm", session}, env.cwd, env.env))
		}
	case .Claude_Projects:
		plan.format = .Claude_Jsonl
		dir := join({root, "projects", claude_key(env.cwd)})
		append(&steps, Purge_Step{kind = .Edit, path = join({dir, strings.concatenate({session, ".jsonl"})})})
		append(&steps, Purge_Step{kind = .Edit, path = join({dir, session}), optional = true})
		append(&steps, Purge_Step{kind = .Delete, path = join({root, "file-history", session}), optional = true})
	case .Codex_Rollouts:
		plan.format = .Codex_Jsonl
		if native_path != "" {
			append(&steps, Purge_Step{kind = .Edit, path = strings.clone(native_path)})
		} else {
			append(&steps, Purge_Step{kind = .Edit, path = join({root, "sessions"}), match = strings.concatenate({"-", session, ".jsonl"})})
		}
	case .Pi_Sessions:
		plan.format = .Pi_Jsonl
		append(&steps, Purge_Step{kind = .Edit, path = strings.clone(native_path != "" ? native_path : session)})
	case .Muse_Sessions:
		plan.seeded = true
		plan.reason = "Muse fingerprints its session log; the session is deleted and replaced by a fresh one seeded with the redacted transcript"
		if native_path != "" {
			dir := native_path[:max(strings.last_index_byte(native_path, '/'), 0)]
			append(&steps, Purge_Step{kind = .Delete, path = strings.clone(dir)})
		} else {
			append(&steps, Purge_Step{kind = .Delete, path = join({root, "sessions"}), match = strings.concatenate({"/", session})})
		}
		append(&steps, Purge_Step{kind = .Delete, path = join({root, "sessions"}), match = strings.concatenate({".msp-view-g12/", session}), optional = true})
	case .OpenCode_Cli:
		plan.format = .OpenCode_Json
		file := join({env.scratch, strings.concatenate({"opencode-purge-", session, ".json"})})
		append(&steps, run({desc.argv[0], "export", session}, env.cwd, env.env, "session"))
		append(&steps, Purge_Step{kind = .Write, key = strings.clone("session"), path = file})
		append(&steps, run({desc.argv[0], "session", "delete", session}, env.cwd, env.env))
		append(&steps, run({desc.argv[0], "import", file}, env.cwd, env.env))
		append(&steps, run({desc.argv[0], "db", "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"}, env.cwd, env.env))
		append(&steps, Purge_Step{kind = .Delete, path = strings.clone(file)})
		append(&steps, Purge_Step{kind = .Scrub, path = join({root, "log"}), optional = true})
	case .Hermes_Cli:
		plan.format = .Claude_Jsonl
		file := join({env.scratch, strings.concatenate({"hermes-purge-", session, ".jsonl"})})
		append(&steps, run({desc.argv[0], "sessions", "export", "--format", "trace", "--session-id", session, "--yes", file}, env.cwd, env.env))
		append(&steps, Purge_Step{kind = .Edit, path = strings.clone(file)})
		append(&steps, run({desc.argv[0], "sessions", "delete", "--yes", session}, env.cwd, env.env))
		append(&steps, run({desc.argv[0], "sessions", "import", "--from", "claude", file}, env.cwd, env.env, "result"))
		if q := text_sql(targets, "state_meta", "value"); q != "" {
			db := join({root, "state.db"})
			append(
				&steps,
				Purge_Step {
					kind = .Sql,
					path = db,
					sql = q,
					script = strings.clone(SQL_SCRIPT),
					args = clone_list({db, "state_meta", "value", text_forms(targets), REDACTED}),
					launcher = strings.clone(desc.argv[0]),
				},
			)
		}
		append(&steps, run({desc.argv[0], "sessions", "optimize", "--force"}, env.cwd, env.env))
		append(&steps, Purge_Step{kind = .Delete, path = strings.clone(file)})
		append(&steps, Purge_Step{kind = .Scrub, path = join({root, "logs"}), optional = true})
		append(&steps, Purge_Step{kind = .Scrub, path = join({root, "sessions"}), optional = true})
		delete(plan.session)
		plan.session = ""
	case .Cursor_Chats:
		plan.seeded = true
		plan.reason = "Cursor keeps the chat in SQLite; the chat is deleted and replaced by a fresh one seeded with the redacted transcript"
		append(&steps, Purge_Step{kind = .Delete, path = join({root, "chats", md5_hex(env.cwd), session})})
	case .Antigravity_Conversations:
		plan.seeded = true
		plan.reason = "Antigravity keeps the trajectory in SQLite; it is deleted and replaced by a fresh session seeded with the redacted transcript"
		conv := join({root, "antigravity-acp", "conversations"})
		append(&steps, Purge_Step{kind = .Delete, path = join({conv, strings.concatenate({session, ".db"})})})
		append(&steps, Purge_Step{kind = .Delete, path = join({conv, strings.concatenate({session, ".meta"})}), optional = true})
		append(&steps, Purge_Step{kind = .Delete, path = join({root, "antigravity-acp", "brain", session}), optional = true})
	}
	if plan.seeded {
		delete(plan.session)
		plan.session = ""
	}
	plan.steps = steps[:]
	return plan
}

purge_result :: proc(desc: Provider_Descriptor, plan: Purge_Plan, outputs: []string, allocator := context.allocator) -> string {
	if plan.session != "" || plan.seeded {
		return strings.clone(plan.session, allocator)
	}
	return import_result(desc, Port_Plan{}, outputs, allocator)
}

purge_destroy :: proc(plan: ^Purge_Plan, allocator := context.allocator) {
	for s in plan.steps {
		delete(s.path, allocator)
		delete(s.match, allocator)
		delete(s.key, allocator)
		delete(s.sql, allocator)
		delete(s.script, allocator)
		drop_strings(s.args, allocator)
		delete(s.launcher, allocator)
		drop_strings(s.argv, allocator)
		delete(s.cwd, allocator)
		drop_strings(s.env, allocator)
	}
	delete(plan.steps, allocator)
	for t in plan.targets {
		delete(t.from, allocator)
		delete(t.to, allocator)
		delete(t.text, allocator)
	}
	delete(plan.targets, allocator)
	delete(plan.session, allocator)
	plan^ = {}
}

purge_bytes :: proc(plan: Purge_Plan, data: []u8, allocator := context.allocator) -> []u8 {
	for c in data {
		if c == 0 {
			return data
		}
	}
	switch plan.format {
	case .None:
		return data
	case .OpenCode_Json:
		v, err := json.parse_string(string(data), .JSON, true, context.temp_allocator)
		if err != .None {
			return scrub_raw(plan, data, allocator)
		}
		w := Range_Walker {
			plan = plan,
		}
		msgs := get_arr(v, "messages")
		for &m in msgs {
			if w_step(&w, get_str(get(m, "info"), "id")) {
				if obj, ok := m.(json.Object); ok {
					obj["parts"] = redact_tree(obj["parts"], "parts")
					obj["info"] = redact_info(obj["info"])
				}
			}
			m = scrub_tree(plan, m)
		}
		v = scrub_tree(plan, v)
		out := make([dynamic]u8, allocator)
		write_value(&out, v)
		return out[:]
	case .Claude_Jsonl, .Codex_Jsonl, .Pi_Jsonl:
		out := make([dynamic]u8, 0, len(data), allocator)
		w := Range_Walker {
			plan = plan,
		}
		rest := string(data)
		for len(rest) > 0 {
			line := rest
			nl := strings.index_byte(rest, '\n')
			if nl >= 0 {
				line = rest[:nl]
				rest = rest[nl + 1:]
			} else {
				rest = ""
			}
			append(&out, purge_line(plan, &w, line))
			if nl >= 0 {
				append(&out, '\n')
			}
		}
		return out[:]
	}
	return data
}

@(private)
Range_Walker :: struct {
	plan:   Purge_Plan,
	active: []bool,
	done:   []bool,
	turn:   string,
}

@(private)
w_step :: proc(w: ^Range_Walker, id: string) -> bool {
	if w.active == nil {
		w.active = make([]bool, len(w.plan.targets), context.temp_allocator)
		w.done = make([]bool, len(w.plan.targets), context.temp_allocator)
	}
	hit := false
	for t, i in w.plan.targets {
		if t.from == "" || w.done[i] {
			continue
		}
		if !w.active[i] && id != "" && id == t.from {
			w.active[i] = true
			if t.keep_from {
				if t.to == "" || t.to == t.from {
					w.done[i] = true
					w.active[i] = false
				}
				continue
			}
		}
		if w.active[i] {
			hit = true
			if id != "" && (id == t.to || t.to == "") {
				w.done[i] = true
				w.active[i] = false
			}
		}
	}
	return hit
}

@(private)
purge_line :: proc(plan: Purge_Plan, w: ^Range_Walker, line: string) -> string {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return line
	}
	v, err := json.parse_string(trimmed, .JSON, true, context.temp_allocator)
	if err != .None {
		return string(scrub_raw(plan, transmute([]u8)line, context.temp_allocator))
	}
	id: string
	switch plan.format {
	case .Claude_Jsonl:
		id = get_str(v, "uuid")
	case .Pi_Jsonl:
		id = get_str(v, "id")
	case .Codex_Jsonl:
		p := get(v, "payload")
		if t := get_str(p, "turn_id"); t != "" {
			id = t
		}
		if id == "" {
			id = get_str(p, "id")
		}
	case .None, .OpenCode_Json:
	}
	changed := false
	if w_step(w, id) {
		changed = true
		if obj, ok := v.(json.Object); ok {
			switch plan.format {
			case .Claude_Jsonl, .Pi_Jsonl:
				for k in ([]string{"message", "toolUseResult", "tool_use_result", "content", "summary", "details"}) {
					if k in obj {
						obj[k] = redact_tree(obj[k], k)
					}
				}
			case .Codex_Jsonl:
				p := get(v, "payload")
				if get_str(p, "type") == "reasoning" {
					return ""
				}
				if _, ok2 := p.(json.Object); ok2 {
					obj["payload"] = redact_tree(p, "payload")
				}
			case .None, .OpenCode_Json:
			}
		}
	}
	if plan.format == .Claude_Jsonl && len(plan.targets) > 0 {
		if obj, ok := v.(json.Object); ok {
			if "lastPrompt" in obj {
				obj["lastPrompt"] = json.String(REDACTED)
				changed = true
			}
			if strings.has_prefix(get_str(v, "type"), "api-request") && "message" in obj {
				obj["message"] = redact_tree(obj["message"], "message")
				changed = true
			}
		}
	}
	for t in plan.targets {
		if t.text != "" && strings.contains(trimmed, t.text) {
			changed = true
		}
	}
	if !changed {
		return line
	}
	v = scrub_tree(plan, v)
	b := make([dynamic]u8, context.temp_allocator)
	write_value(&b, v)
	return string(b[:])
}

@(private, rodata)
STRUCTURAL := [?]string {
	"type",
	"role",
	"id",
	"uuid",
	"parentUuid",
	"parentId",
	"call_id",
	"tool_use_id",
	"toolCallId",
	"name",
	"toolName",
	"status",
	"model",
	"stopReason",
	"stop_reason",
	"api",
	"provider",
	"sessionId",
	"session_id",
	"sessionID",
	"messageID",
	"turn_id",
	"timestamp",
	"phase",
	"callID",
	"tool",
	"mimeType",
	"media_type",
	"signature",
}

@(private, rodata)
DROPPED_BLOCKS := [?]string{"thinking", "redacted_thinking", "reasoning", "image", "document", "input_image", "localImage", "file"}

@(private)
is_structural :: proc(k: string) -> bool {
	for s in STRUCTURAL {
		if s == k {
			return true
		}
	}
	return false
}

@(private)
dropped_block :: proc(v: json.Value) -> bool {
	t := get_str(v, "type")
	for s in DROPPED_BLOCKS {
		if s == t {
			return true
		}
	}
	return false
}

@(private)
redact_tree :: proc(v: json.Value, field: string) -> json.Value {
	switch x in v {
	case nil, json.Null, json.Integer, json.Float, json.Boolean:
		return v
	case json.String:
		if field == "arguments" {
			return json.String("{}")
		}
		return json.String(REDACTED)
	case json.Array:
		out := make(json.Array, 0, len(x), context.temp_allocator)
		for e in x {
			if dropped_block(e) {
				continue
			}
			append(&out, redact_tree(e, field))
		}
		if len(x) > 0 && len(out) == 0 {
			block := make(json.Object, context.temp_allocator)
			block["type"] = json.String("text")
			block["text"] = json.String(REDACTED)
			append(&out, block)
		}
		return out
	case json.Object:
		out := make(json.Object, context.temp_allocator)
		for k, e in x {
			switch {
			case is_structural(k):
				out[k] = e
			case k == "input" || k == "args" || k == "rawInput":
				if _, is_obj := e.(json.Object); is_obj {
					out[k] = make(json.Object, context.temp_allocator)
				} else {
					out[k] = redact_tree(e, k)
				}
			case:
				out[k] = redact_tree(e, k)
			}
		}
		return out
	}
	return v
}

@(private)
redact_info :: proc(v: json.Value) -> json.Value {
	obj, ok := v.(json.Object)
	if !ok {
		return v
	}
	if s, has_summary := obj["summary"]; has_summary {
		obj["summary"] = redact_tree(s, "summary")
	}
	return obj
}

@(private)
scrub_tree :: proc(plan: Purge_Plan, v: json.Value) -> json.Value {
	any_text := false
	for t in plan.targets {
		if t.text != "" {
			any_text = true
		}
	}
	if !any_text {
		return v
	}
	return scrub_value(plan, v)
}

@(private)
scrub_value :: proc(plan: Purge_Plan, v: json.Value) -> json.Value {
	switch x in v {
	case nil, json.Null, json.Integer, json.Float, json.Boolean:
		return v
	case json.String:
		return json.String(scrub_string(plan, x))
	case json.Array:
		out := make(json.Array, 0, len(x), context.temp_allocator)
		for e in x {
			if dropped_block(e) && contains_target(plan, e) {
				continue
			}
			append(&out, scrub_value(plan, e))
		}
		return out
	case json.Object:
		out := make(json.Object, context.temp_allocator)
		for k, e in x {
			out[scrub_string(plan, k)] = scrub_value(plan, e)
		}
		return out
	}
	return v
}

@(private)
contains_target :: proc(plan: Purge_Plan, v: json.Value) -> bool {
	s := to_json(v)
	for t in plan.targets {
		if t.text != "" && strings.contains(s, t.text) {
			return true
		}
	}
	return false
}

@(private)
scrub_string :: proc(plan: Purge_Plan, s: string) -> string {
	out := s
	for t in plan.targets {
		if t.text != "" && strings.contains(out, t.text) {
			out, _ = strings.replace_all(out, t.text, REDACTED, context.temp_allocator)
		}
	}
	return out
}

@(private)
scrub_raw :: proc(plan: Purge_Plan, data: []u8, allocator := context.allocator) -> []u8 {
	rw := make([dynamic]Rewrite, context.temp_allocator)
	for t in plan.targets {
		if t.text != "" {
			append(&rw, Rewrite{from = t.text, to = REDACTED})
		}
	}
	return apply_rewrites(Port_Plan{rewrites = rw[:]}, data, allocator)
}

purge_text :: proc(plan: Purge_Plan, data: []u8, allocator := context.allocator) -> []u8 {
	return scrub_raw(plan, data, allocator)
}

@(private)
text_sql :: proc(targets: []Purge_Target, table, column: string) -> string {
	b := make([dynamic]u8)
	for t in targets {
		if t.text == "" {
			continue
		}
		forms := make([dynamic]string, context.temp_allocator)
		append(&forms, t.text)
		esc := make([dynamic]u8, context.temp_allocator)
		w_str(&esc, t.text)
		quoted := string(esc[1:len(esc) - 1])
		if quoted != t.text {
			append(&forms, quoted)
		}
		for f in forms {
			lit, _ := strings.replace_all(f, "'", "''", context.temp_allocator)
			put(&b, "UPDATE ", table, " SET ", column, " = replace(", column, ", '", lit, "', '", REDACTED, "') WHERE instr(", column, ", '", lit, "') > 0;\n")
		}
	}
	if len(b) == 0 {
		return ""
	}
	put(&b, "PRAGMA wal_checkpoint(TRUNCATE);\nVACUUM;\n")
	return string(b[:])
}

@(private, rodata)
SQL_SCRIPT := `import json, sqlite3, sys
db, table, column, forms, red = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4]), sys.argv[5]
if not table.isidentifier() or not column.isidentifier():
    sys.exit("bad identifier")
c = sqlite3.connect(db)
n = 0
for f in forms:
    n += c.execute(f'UPDATE "{table}" SET "{column}" = replace("{column}", ?, ?) WHERE instr("{column}", ?) > 0', (f, red, f)).rowcount
c.commit()
c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
c.execute("VACUUM")
c.close()
print(n)
`

@(private)
text_forms :: proc(targets: []Purge_Target) -> string {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, '[')
	for t in targets {
		if t.text == "" {
			continue
		}
		if len(b) > 1 {
			append(&b, ',')
		}
		w_str(&b, t.text)
		esc := make([dynamic]u8, context.temp_allocator)
		w_str(&esc, t.text)
		quoted := string(esc[1:len(esc) - 1])
		if quoted != t.text {
			append(&b, ',')
			w_str(&b, quoted)
		}
	}
	append(&b, ']')
	return string(b[:])
}

launcher_interpreter :: proc(text: string) -> (interpreter: string, next: string) {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) == 0 {
		return "", ""
	}
	first := strings.trim_space(lines[0])
	if strings.has_prefix(first, "#!") {
		fields := strings.fields(first[2:], context.temp_allocator)
		if len(fields) > 0 {
			prog := fields[0]
			if base_name(prog) == "env" && len(fields) > 1 {
				prog = fields[1]
				if prog == "-S" && len(fields) > 2 {
					prog = fields[2]
				}
			}
			if strings.has_prefix(base_name(prog), "python") {
				return prog, ""
			}
		}
	}
	for raw in lines[1:] {
		line := strings.trim_space(raw)
		if !strings.has_prefix(line, "exec ") {
			continue
		}
		fields := strings.fields(line[5:], context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		prog := strings.trim(fields[0], `"'`)
		if !strings.has_prefix(prog, "/") {
			continue
		}
		if strings.has_prefix(base_name(prog), "python") {
			return prog, ""
		}
		return "", prog
	}
	return "", ""
}

@(private)
base_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

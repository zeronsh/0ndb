package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../capi/api"
import "../prim"

Session :: struct {
	c:        Client,
	a:        ^Args,
	timeout:  i64,
	space:    prim.Id,
	resolved: bool,
}

session :: proc(a: ^Args, autostart := true) -> ^Session {
	s := new(Session, context.temp_allocator)
	s.a = a
	s.timeout = 10_000
	if v, ok := flag_value(a, "timeout"); ok {
		n, nok := strconv.parse_i64(v)
		if !nok || n < 0 {
			fail(.Usage, "--timeout takes milliseconds")
		}
		s.timeout = n
	}
	if !client_connect(&s.c, autostart) {
		fail(.Daemon, "cannot reach the daemon at %s (start it with 0ndb daemon)", socket_path(context.temp_allocator))
	}
	return s
}

call :: proc(s: ^Session, req: string) -> Reply {
	return client_call(&s.c, req, s.timeout)
}

must :: proc(s: ^Session, req: string, what := "") -> json.Value {
	r := call(s, req)
	if r.status != .Ok {
		label := what
		if len(label) == 0 {
			label = "request failed"
		}
		os.exit(report_error(r.status, "%s", label))
	}
	return r.value
}

jget :: proc(v: json.Value, key: string) -> json.Value {
	if ob, ok := v.(json.Object); ok {
		return ob[key]
	}
	return nil
}

jstr :: proc(v: json.Value, key: string) -> string {
	s, _ := jget(v, key).(json.String)
	return string(s)
}

jint :: proc(v: json.Value, key: string) -> i64 {
	#partial switch x in jget(v, key) {
	case json.Integer:
		return i64(x)
	case json.Float:
		return i64(x)
	}
	return 0
}

jf64 :: proc(v: json.Value, key: string) -> f64 {
	#partial switch x in jget(v, key) {
	case json.Integer:
		return f64(x)
	case json.Float:
		return f64(x)
	}
	return 0
}

jbool :: proc(v: json.Value, key: string) -> bool {
	b, _ := jget(v, key).(json.Boolean)
	return bool(b)
}

jarr :: proc(v: json.Value, key: string) -> json.Array {
	a, _ := jget(v, key).(json.Array)
	return a
}

jtext :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return string(s)
}

print_json :: proc(v: json.Value) {
	buf := make([dynamic]u8, context.temp_allocator)
	_json_write(&buf, v)
	fmt.println(string(buf[:]))
}

@(private)
_json_write :: proc(buf: ^[dynamic]u8, v: json.Value) {
	switch x in v {
	case json.Null:
		append(buf, "null")
	case json.Integer:
		b: [32]u8
		append(buf, strconv.write_int(b[:], i64(x), 10))
	case json.Float:
		b: [64]u8
		s := strconv.write_float(b[:], f64(x), 'g', -1, 64)
		if len(s) > 0 && s[0] == '+' {
			s = s[1:]
		}
		append(buf, s)
	case json.Boolean:
		append(buf, "true" if x else "false")
	case json.String:
		api.json_string(buf, string(x))
	case json.Array:
		append(buf, '[')
		for e, i in x {
			if i > 0 {
				append(buf, ',')
			}
			_json_write(buf, e)
		}
		append(buf, ']')
	case json.Object:
		keys := make([dynamic]string, context.temp_allocator)
		for k in x {
			append(&keys, k)
		}
		for i in 1 ..< len(keys) {
			j := i
			for j > 0 && keys[j - 1] > keys[j] {
				keys[j - 1], keys[j] = keys[j], keys[j - 1]
				j -= 1
			}
		}
		append(buf, '{')
		for k, i in keys {
			if i > 0 {
				append(buf, ',')
			}
			api.json_string(buf, k)
			append(buf, ':')
			_json_write(buf, x[k])
		}
		append(buf, '}')
	}
}

spaces :: proc(s: ^Session) -> json.Array {
	return jarr(must(s, `{"op":"space.list"}`), "spaces")
}

default_space :: proc(s: ^Session, create := false) -> prim.Id {
	if s.resolved {
		return s.space
	}
	list := spaces(s)
	if v, ok := flag_value(s.a, "space"); ok {
		found := 0
		for sp in list {
			id := jstr(sp, "id")
			if id_matches(id, v) || jstr(sp, "name") == v {
				s.space, _ = prim.id_parse(id)
				found += 1
			}
		}
		if found != 1 {
			fail(.Usage, "--space %q matches %d spaces", v, found)
		}
		s.resolved = true
		return s.space
	}
	st := must(s, `{"op":"state.get"}`)
	def := jstr(st, "default_space")
	for sp in list {
		if len(def) > 0 && jstr(sp, "id") == def {
			s.space, _ = prim.id_parse(def)
			s.resolved = true
			return s.space
		}
	}
	if len(list) >= 1 {
		s.space, _ = prim.id_parse(jstr(list[0], "id"))
		s.resolved = true
		r := req_begin("state.set")
		req_str(&r, "default_space", hex(s.space))
		must(s, req_end(&r))
		return s.space
	}
	if !create {
		fail(.Usage, "no space yet: create one with 0ndb new or 0ndb pair, or join one with 0ndb join")
	}
	r := req_begin("space.create")
	req_str(&r, "name", "default")
	v := must(s, req_end(&r), "cannot create a space")
	s.space, _ = prim.id_parse(jstr(v, "space"))
	s.resolved = true
	r2 := req_begin("state.set")
	req_str(&r2, "default_space", hex(s.space))
	must(s, req_end(&r2))
	return s.space
}

catalog_rows :: proc(s: ^Session, space: prim.Id, archived := false, limit := 100_000) -> [dynamic]json.Value {
	out := make([dynamic]json.Value, context.temp_allocator)
	after := ""
	for len(out) < limit {
		r := req_begin("catalog.list")
		req_str(&r, "space", hex(space))
		req_bool(&r, "archived", archived)
		req_int(&r, "limit", 500)
		req_opt(&r, "after", after)
		v := must(s, req_end(&r), "cannot list the catalog")
		for row in jarr(v, "rows") {
			append(&out, row)
		}
		after = jstr(v, "next")
		if !jbool(v, "more") || len(after) == 0 {
			break
		}
	}
	return out
}

resolve_object :: proc(s: ^Session, text: string) -> api.Object {
	if ob, ok := api.parse_object(text); ok {
		return ob
	}
	if id, ok := prim.id_parse(text); ok {
		list := spaces(s)
		if len(list) > 1 && !s.resolved {
			for sp in list {
				sid, _ := prim.id_parse(jstr(sp, "id"))
				r := req_begin("catalog.get")
				req_str(&r, "object", object_str(api.Object{sid, id}))
				if v := call(s, req_end(&r)); v.status == .Ok && jbool(v.value, "found") {
					return api.Object{sid, id}
				}
			}
		}
		return api.Object{default_space(s), id}
	}
	space := default_space(s)
	if len(text) == 0 {
		fail(.Usage, "an object id or title is required")
	}
	match: api.Object
	n := 0
	r := req_begin("catalog.find")
	req_str(&r, "space", hex(space))
	req_str(&r, "text", text)
	v := must(s, req_end(&r), "cannot search the catalog")
	for row in jarr(v, "rows") {
		x, _ := prim.id_parse(jstr(row, "object"))
		if n == 0 || x != match.id {
			n += 1
		}
		match = api.Object{space, x}
	}
	if n == 0 {
		os.exit(report_error(.Not_Found, "no object matches %q", text))
	}
	if n > 1 {
		fail(.Usage, "%q matches %d objects; use more characters", text, n)
	}
	return match
}

current_convo :: proc(s: ^Session) -> api.Object {
	st := must(s, `{"op":"state.get"}`)
	if ob, ok := api.parse_object(jstr(st, "current")); ok {
		return ob
	}
	fail(.Usage, "no current conversation: pass one or create one with 0ndb new")
}

set_current :: proc(s: ^Session, ob: api.Object) {
	r := req_begin("state.set")
	req_str(&r, "current", object_str(ob))
	must(s, req_end(&r))
}

object_str :: proc(ob: api.Object) -> string {
	buf := make([dynamic]u8, context.temp_allocator)
	api.object_text(&buf, ob)
	return string(buf[:])
}

rid_str :: proc(r: api.Rid) -> string {
	buf := make([dynamic]u8, context.temp_allocator)
	api.rid_text(&buf, r)
	return string(buf[:])
}

short :: proc(id: string) -> string {
	return id[max(len(id) - 8, 0):]
}

short_rid :: proc(rid: string) -> string {
	if len(rid) < 34 {
		return rid
	}
	return strings.concatenate({rid[24:32], rid[32:]}, context.temp_allocator)
}

id_matches :: proc(id: string, part: string) -> bool {
	p := strings.to_lower(part, context.temp_allocator)
	return len(p) > 0 && (strings.has_prefix(id, p) || strings.has_suffix(id, p))
}

page :: proc(s: ^Session, ob: api.Object, limit: int) -> [dynamic]json.Value {
	out := make([dynamic]json.Value, context.temp_allocator)
	from, seal := "", ""
	known := false
	for len(out) < limit {
		r := req_begin("convo.page")
		req_str(&r, "object", object_str(ob))
		req_int(&r, "limit", i64(min(limit - len(out), 256)))
		req_opt(&r, "from", from)
		req_opt(&r, "from_seal", seal)
		req_bool(&r, "from_known", known)
		v := must(s, req_end(&r), "cannot read the conversation")
		for m in jarr(v, "messages") {
			append(&out, m)
		}
		next := jget(v, "next")
		from = jstr(next, "msg")
		seal = jstr(next, "seal")
		known = jbool(next, "seal_known")
		if !jbool(v, "more") || len(from) == 0 {
			break
		}
	}
	return out
}

resolve_msg :: proc(s: ^Session, ob: api.Object, text: string) -> api.Rid {
	if r, ok := api.parse_rid(text); ok {
		return r
	}
	if len(text) > 1 && text[0] == '@' {
		n, ok := strconv.parse_int(text[1:])
		if !ok || n < 1 {
			fail(.Usage, "%q: use @N for the Nth most recent message", text)
		}
		msgs := page(s, ob, n)
		if len(msgs) < n {
			os.exit(report_error(.Not_Found, "the conversation has only %d messages", len(msgs)))
		}
		r, _ := api.parse_rid(jstr(msgs[n - 1], "id"))
		return r
	}
	colon := strings.index_byte(text, ':')
	if colon <= 0 {
		fail(.Usage, "%q is not a message (use SEG:OFF, a prefix of SEG with :OFF, or @N)", text)
	}
	seg := text[:colon]
	off := text[colon:]
	for m in page(s, ob, 4096) {
		id := jstr(m, "id")
		if len(id) == 32 + len(off) && strings.has_suffix(id, off) && id_matches(id[:32], seg) {
			r, _ := api.parse_rid(id)
			return r
		}
	}
	os.exit(report_error(.Not_Found, "no message matches %q", text))
}

read_text :: proc(a: ^Args, pos: string) -> string {
	if flag_bool(a, "stdin") {
		data, err := os.read_entire_file(os.stdin, context.temp_allocator)
		if err != nil {
			fail(.Io, "cannot read stdin")
		}
		return strings.trim_right(string(data), "\n")
	}
	return pos
}

abs_path :: proc(p: string) -> string {
	q := slashes(p)
	if !prim.is_abs(q) {
		cwd, err := os.get_working_directory(context.temp_allocator)
		if err != nil {
			fail(.Io, "cannot read the working directory")
		}
		q = strings.concatenate({slashes(cwd), "/", q}, context.temp_allocator)
	}
	root := "/"
	rest := q
	keep := 0
	when ODIN_OS == .Windows {
		if len(q) >= 2 && q[1] == ':' {
			d := q[0] - 32 if q[0] >= 'a' && q[0] <= 'z' else q[0]
			root = strings.concatenate({string([]u8{d}), ":/"}, context.temp_allocator)
			rest = q[2:]
		} else if strings.has_prefix(q, "//") {
			root = "//"
			rest = q[2:]
			keep = 2
		}
	}
	out := make([dynamic]string, context.temp_allocator)
	for x in strings.split(rest, "/", context.temp_allocator) {
		switch x {
		case "", ".":
		case "..":
			if len(out) > keep {
				pop(&out)
			}
		case:
			append(&out, x)
		}
	}
	return strings.concatenate({root, strings.join(out[:], "/", context.temp_allocator)}, context.temp_allocator)
}

slashes :: proc(p: string) -> string {
	when ODIN_OS == .Windows {
		b := make([]u8, len(p), context.temp_allocator)
		for c, i in transmute([]u8)p {
			b[i] = '/' if c == '\\' else c
		}
		return string(b)
	} else {
		return p
	}
}

placement :: proc(s: ^Session, ob: api.Object) -> (json.Value, bool) {
	r := req_begin("placement")
	req_str(&r, "object", object_str(ob))
	v := call(s, req_end(&r))
	return v.value, v.status == .Ok
}

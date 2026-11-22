package main

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "../capi/api"
import "../prim"
import osync "../sync"

cmd_daemon :: proc(a: ^Args) -> int {
	if len(a.pos) > 0 {
		switch a.pos[0] {
		case "stop":
			c: Client
			if !client_connect(&c, false) {
				return report_error(.Closed, "no daemon is running")
			}
			st := client_call(&c, `{"op":"daemon.status"}`, 5000)
			pid := u64(jint(st.value, "pid")) if st.status == .Ok else 0
			r := client_call(&c, `{"op":"daemon.stop"}`)
			client_close(&c)
			if r.status != .Ok {
				return report_error(r.status, "cannot stop the daemon")
			}
			deadline := prim.now_ms() + i64(flag_int(a, "timeout", 60)) * 1000
			for pid_running(pid) {
				if prim.now_ms() > deadline {
					return report_error(.Timeout, "the daemon (pid %d) has not exited yet", pid)
				}
				time.sleep(20 * time.Millisecond)
			}
			fmt.println("stopped")
			return 0
		case "start":
			return _daemon_start(a)
		case:
			return usage_error("usage: 0ndb daemon [start|stop] [daemon flags]")
		}
	}
	return daemon_main(a)
}

@(private)
_daemon_start :: proc(a: ^Args) -> int {
	c: Client
	if client_connect(&c, false) {
		r := client_call(&c, `{"op":"daemon.status"}`, 5000)
		client_close(&c)
		if a.json {
			fmt.println(r.payload)
		} else {
			fmt.printfln("already running (pid %d)", jint(r.value, "pid"))
		}
		return 0
	}
	extra := make([dynamic]string, context.temp_allocator)
	for name, value in a.flags {
		if name == "json" || name == "timeout" {
			continue
		}
		is_bool := false
		for b in BOOL_FLAGS {
			is_bool ||= b == name
		}
		if is_bool {
			if value == "true" {
				append(&extra, fmt.tprintf("--%s", name))
			}
		} else {
			append(&extra, fmt.tprintf("--%s", name), value)
		}
	}
	if !_spawn_daemon(extra[:]) {
		return report_error(.Io, "the daemon did not start (see %s)", "daemon.log in the data directory")
	}
	if !client_connect(&c, false) {
		return report_error(.Closed, "the daemon started but its socket is not reachable")
	}
	r := client_call(&c, `{"op":"daemon.status"}`, 5000)
	client_close(&c)
	if a.json {
		fmt.println(r.payload)
	} else {
		fmt.printfln("started (pid %d)", jint(r.value, "pid"))
	}
	return 0
}

cmd_runner :: proc(a: ^Args) -> int {
	delete_key(&a.flags, "no-runner")
	a.flags["pool"] = "1"
	if _, ok := a.flags["storage"]; !ok {
		a.flags["storage"] = "stored"
	}
	return daemon_main(a)
}

cmd_status :: proc(a: ^Args) -> int {
	s := session(a)
	d := must(s, `{"op":"daemon.status"}`)
	id := must(s, `{"op":"identity"}`)
	sp := must(s, `{"op":"space.list"}`)
	st := must(s, `{"op":"state.get"}`)
	mt := must(s, `{"op":"tree.mounts"}`)
	es := must(s, `{"op":"stats"}`)
	rr := call(s, `{"op":"runtime.stats"}`)
	if a.json {
		out := make(json.Object, context.temp_allocator)
		out["daemon"] = d
		out["identity"] = id
		out["spaces"] = jget(sp, "spaces")
		out["state"] = st
		out["mounts"] = jget(mt, "mounts")
		out["engine"] = es
		if rr.status == .Ok {
			out["runtime"] = rr.value
		}
		print_json(out)
		return 0
	}
	fmt.printfln("daemon   pid %d · up %s · rss %s · wakeups %d · %s", jint(d, "pid"), duration(jint(d, "uptime_ms")), bytes_human(jint(d, "rss")), jint(d, "wakeups"), jstr(d, "socket"))
	fmt.printfln("device   %s", jstr(id, "id"))
	fmt.printfln("home     %s", jstr(d, "home"))
	def := jstr(st, "default_space")
	reasons := make(map[string]string, context.temp_allocator)
	for l in jarr(d, "links") {
		reasons[jstr(l, "space")] = jstr(l, "reason")
	}
	for x in jarr(sp, "spaces") {
		conn := "local only"
		if len(jstr(x, "relay")) > 0 {
			state := "connected"
			if !jbool(x, "connected") {
				state = "offline"
				if why, ok := reasons[jstr(x, "id")]; ok {
					state = fmt.tprintf("offline: %s", why)
				}
			}
			conn = fmt.tprintf("%s %s · relay stores %s", jstr(x, "relay"), state, bytes_human(jint(x, "relay_usage")))
		}
		mark := " (default)" if jstr(x, "id") == def else ""
		fmt.printfln("space    %s %q · %s%s", short(jstr(x, "id")), jstr(x, "name"), conn, mark)
	}
	for m in jarr(mt, "mounts") {
		ob, _ := api.parse_object(jstr(m, "object"))
		fmt.printfln("mount    %s → tree %s (%s)", jstr(m, "root"), short(hex(ob.id)), jstr(m, "line"))
	}
	if rr.status == .Ok {
		role := "runner" if jbool(rr.value, "runner") else "client"
		fmt.printfln("runtime  %s · %d running · %d warm · %d runs started", role, jint(rr.value, "active_runs"), jint(rr.value, "warm_processes"), jint(rr.value, "runs_started"))
	}
	if cur, ok := api.parse_object(jstr(st, "current")); ok {
		line := short(hex(cur.id))
		if p, pok := placement(s, cur); pok {
			if t := placement_text(p); len(t) > 0 {
				line = fmt.tprintf("%s · %s", line, t)
			}
		}
		fmt.printfln("current  %s", line)
	}
	fmt.printfln("engine   %d open objects · %d subscriptions · %d pending reads", jint(es, "handles"), jint(es, "subs"), jint(es, "pending"))
	return 0
}

cmd_ls :: proc(a: ^Args) -> int {
	s := session(a)
	space := default_space(s)
	limit := 50
	if v, ok := flag_value(a, "limit"); ok {
		x, xok := strconv.parse_int(v)
		if !xok || x <= 0 {
			return usage_error("--limit takes a positive number")
		}
		limit = x
	}
	want := flag_string(a, "kind", "" if flag_bool(a, "all") else "conversation")
	rows := catalog_rows(s, space, flag_bool(a, "archived"))
	out := make([dynamic]json.Value, context.temp_allocator)
	for rw in rows {
		if len(want) > 0 && jstr(rw, "kind") != want {
			continue
		}
		append(&out, rw)
		if len(out) >= limit {
			break
		}
	}
	if a.json {
		print_json(json.Array(out))
		return 0
	}
	cur := jstr(must(s, `{"op":"state.get"}`), "current")
	tbl := make([dynamic][]string, context.temp_allocator)
	append(&tbl, row("", "ID", "KIND", "STATUS", "ACTIVE", "TITLE", "PLACEMENT"))
	for x in out {
		id := row_id(x)
		mark := "*" if len(cur) == 65 && cur[33:] == id else ""
		status := jstr(x, "status") if jstr(x, "kind") == "conversation" else ""
		title := jstr(x, "title")
		if p := jstr(jget(x, "parent"), "object"); len(p) > 0 {
			title = fmt.tprintf("%s (task of %s)", title, short(p))
		}
		place := ""
		if jstr(x, "kind") == "conversation" {
			xo, _ := prim.id_parse(id)
			if p, ok := placement(s, api.Object{space, xo}); ok {
				place = placement_text(p)
			}
		}
		append(&tbl, row(mark, short(id), jstr(x, "kind"), status, ago(jint(x, "activity")), one_line(title, 60), place))
	}
	if len(out) == 0 {
		fmt.println("nothing here yet (0ndb new TITLE)")
		return 0
	}
	table(tbl[:])
	return 0
}

cmd_search :: proc(a: ^Args) -> int {
	if len(a.pos) < 1 {
		return usage_error("usage: 0ndb search QUERY")
	}
	s := session(a)
	space := default_space(s)
	r := req_begin("search")
	req_str(&r, "query", strings.join(a.pos[:], " ", context.temp_allocator))
	req_str(&r, "space", hex(space))
	if flag_bool(a, "local") {
		req_str(&r, "scope", "local")
	} else if flag_bool(a, "everywhere") {
		req_str(&r, "scope", "everywhere")
	}
	req_int(&r, "limit", i64(max(1, int(parse_int_flag(a, "limit", 20)))))
	req_bool(&r, "semantic", flag_bool(a, "semantic"))
	if flag_bool(a, "newest") {
		req_str(&r, "sort", "newest")
	}
	v := must(s, req_end(&r), "search failed")
	if a.json {
		print_json(v)
		return 0
	}
	hits := jarr(v, "hits")
	if len(hits) == 0 {
		fmt.println("no matches")
	}
	for h in hits {
		where_ := short(jstr(h, "object"))
		if m := jstr(h, "msg"); len(m) > 0 {
			where_ = fmt.tprintf("%s %s", where_, short_rid(m))
		}
		fmt.printfln("%s  %s  %s", where_, jstr(h, "kind"), one_line(jstr(h, "snippet"), 100))
	}
	if jbool(v, "partial") {
		behind := jint(v, "behind")
		states := make([dynamic]string, context.temp_allocator)
		for src in jarr(v, "sources") {
			if !jbool(src, "local") && jstr(src, "state") != "ok" {
				append(&states, jstr(src, "state"))
			}
		}
		if behind > 0 {
			fmt.printfln("partial: %d objects behind", behind)
		} else if len(states) > 0 {
			fmt.printfln("partial: local results only (%s)", strings.join(states[:], ", ", context.temp_allocator))
		} else {
			fmt.println("partial: local results only (no indexer online)")
		}
	}
	return 0
}

parse_int_flag :: proc(a: ^Args, name: string, default_value: i64) -> i64 {
	v, ok := flag_value(a, name)
	if !ok {
		return default_value
	}
	x, xok := strconv.parse_i64(v)
	if !xok {
		fail(.Usage, "--%s takes a number", name)
	}
	return x
}

cmd_models :: proc(a: ^Args) -> int {
	s := session(a)
	if _, ok := flag_value(a, "timeout"); !ok {
		s.timeout = 30_000
	}
	r := req_begin("models")
	req_bool(&r, "refresh", flag_bool(a, "refresh"))
	v := must(s, req_end(&r), "cannot list models")
	if a.json {
		print_json(v)
		return 0
	}
	fmt.println("harness providers:")
	tbl := make([dynamic][]string, context.temp_allocator)
	append(&tbl, row("  ID", "NAME", "COMMAND", "PROTOCOL", "INSTALLED", "MODELS"))
	for p in jarr(v, "providers") {
		models := ""
		if jbool(p, "listed") {
			names := make([dynamic]string, context.temp_allocator)
			for m in jarr(p, "models") {
				append(&names, fmt.tprintf("%s%s", jstr(m, "id"), " (default)" if jbool(m, "default") else ""))
			}
			models = strings.join(names[:], ", ", context.temp_allocator) if len(names) > 0 else "none listed"
		} else if e := jstr(p, "error"); len(e) > 0 {
			models = fmt.tprintf("? %s", e)
		}
		append(&tbl, row(fmt.tprintf("  %s", jstr(p, "id")), jstr(p, "name"), jstr(p, "command"), jstr(p, "protocol"), "yes" if jbool(p, "available") else "no", models))
	}
	table(tbl[:])
	fmt.println("\nnative models (provider native, keys from ANTHROPIC_API_KEY / OPENAI_API_KEY):")
	tbl2 := make([dynamic][]string, context.temp_allocator)
	append(&tbl2, row("  ID", "API", "CONTEXT"))
	for m in jarr(v, "models") {
		append(&tbl2, row(fmt.tprintf("  %s", jstr(m, "id")), jstr(m, "api"), fmt.tprintf("%d", jint(m, "context_window"))))
	}
	table(tbl2[:])
	return 0
}

@(private)
_marked :: proc(s: ^Session, field: string) -> [dynamic]json.Value {
	out := make([dynamic]json.Value, context.temp_allocator)
	for row in catalog_rows(s, default_space(s)) {
		if jstr(row, "kind") == "map" && jstr(row, field) == row_id(row) {
			append(&out, row)
		}
	}
	return out
}

cmd_agent :: proc(a: ^Args) -> int {
	if len(a.pos) < 1 {
		return usage_error("usage: 0ndb agent new|ls|show")
	}
	s := session(a)
	switch a.pos[0] {
	case "new":
		if len(a.pos) < 2 {
			return usage_error("usage: 0ndb agent new NAME [--driver D] [--provider P] [--model M] [--instructions TEXT]")
		}
		r := req_begin("agent.create")
		req_str(&r, "space", hex(default_space(s, true)))
		req_str(&r, "name", a.pos[1])
		req_opt(&r, "instructions", flag_string(a, "instructions"))
		req_opt(&r, "driver", flag_string(a, "driver"))
		req_opt(&r, "provider", flag_string(a, "provider"))
		req_opt(&r, "model", flag_string(a, "model"))
		if w, ok := flag_value(a, "workspace"); ok {
			req_str(&r, "workspace", hex(resolve_object(s, w).id))
		}
		v := must(s, req_end(&r), "cannot create the agent")
		if a.json {
			print_json(v)
		} else {
			ob, _ := api.parse_object(jstr(v, "object"))
			fmt.printfln("agent %s %s", short(hex(ob.id)), a.pos[1])
		}
	case "ls":
		rows := _marked(s, "agent")
		if a.json {
			print_json(json.Array(rows))
			return 0
		}
		for row in rows {
			fmt.printfln("%s  %s", short(row_id(row)), jstr(row, "title"))
		}
	case "show":
		if len(a.pos) < 2 {
			return usage_error("usage: 0ndb agent show AGENT")
		}
		r := req_begin("agent.get")
		req_str(&r, "object", object_str(resolve_object(s, a.pos[1])))
		v := must(s, req_end(&r), "cannot read the agent")
		if a.json {
			print_json(v)
			return 0
		}
		fmt.printfln("agent %s\n  driver %s · provider %s · model %s", jstr(v, "name"), jstr(v, "driver"), jstr(v, "provider"), jstr(v, "model"))
		if t := jstr(v, "instructions"); len(t) > 0 {
			fmt.println(indent(t, "  | "))
		}
	case:
		return usage_error("usage: 0ndb agent new|ls|show")
	}
	return 0
}

cmd_workspace :: proc(a: ^Args) -> int {
	if len(a.pos) < 1 {
		return usage_error("usage: 0ndb workspace new|ls|show|add")
	}
	s := session(a)
	switch a.pos[0] {
	case "new":
		if len(a.pos) < 2 {
			return usage_error("usage: 0ndb workspace new NAME")
		}
		r := req_begin("workspace.create")
		req_str(&r, "space", hex(default_space(s, true)))
		req_str(&r, "name", a.pos[1])
		req_opt(&r, "provider", flag_string(a, "provider"))
		req_opt(&r, "model", flag_string(a, "model"))
		req_opt(&r, "setup", flag_string(a, "setup"))
		if ag, ok := flag_value(a, "agent"); ok {
			req_str(&r, "agent", hex(resolve_object(s, ag).id))
		}
		v := must(s, req_end(&r), "cannot create the workspace")
		if a.json {
			print_json(v)
		} else {
			ob, _ := api.parse_object(jstr(v, "object"))
			fmt.printfln("workspace %s %s", short(hex(ob.id)), a.pos[1])
		}
	case "ls":
		rows := _marked(s, "workspace")
		if a.json {
			print_json(json.Array(rows))
			return 0
		}
		for row in rows {
			fmt.printfln("%s  %s", short(row_id(row)), jstr(row, "title"))
		}
	case "show":
		if len(a.pos) < 2 {
			return usage_error("usage: 0ndb workspace show W")
		}
		r := req_begin("workspace.get")
		req_str(&r, "object", object_str(resolve_object(s, a.pos[1])))
		v := must(s, req_end(&r), "cannot read the workspace")
		if a.json {
			print_json(v)
			return 0
		}
		fmt.printfln("workspace %s · provider %s · model %s", jstr(v, "name"), jstr(v, "provider"), jstr(v, "model"))
		for m in jarr(v, "members") {
			fmt.printfln("  %s %s mount %q path %q", jstr(m, "role"), short(jstr(m, "object")), jstr(m, "mount"), jstr(m, "path"))
		}
	case "add":
		if len(a.pos) < 3 {
			return usage_error("usage: 0ndb workspace add W TREE [--mount NAME] [--path P]")
		}
		w := resolve_object(s, a.pos[1])
		t := resolve_object(s, a.pos[2])
		r := req_begin("workspace.add_member")
		req_str(&r, "object", object_str(w))
		req_str(&r, "member", hex(t.id))
		req_str(&r, "kind", "tree")
		req_str(&r, "role", "tree")
		req_str(&r, "mount", flag_string(a, "mount", short(hex(t.id))))
		req_opt(&r, "path", flag_string(a, "path"))
		must(s, req_end(&r), "cannot add the member")
		fmt.println("added")
	case:
		return usage_error("usage: 0ndb workspace new|ls|show|add")
	}
	return 0
}

cmd_mount :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) >= 1 && a.pos[0] == "ls" {
		v := must(s, `{"op":"tree.mounts"}`)
		if a.json {
			print_json(v)
			return 0
		}
		for m in jarr(v, "mounts") {
			ob, _ := api.parse_object(jstr(m, "object"))
			fmt.printfln("%s → tree %s (%s)", jstr(m, "root"), short(hex(ob.id)), jstr(m, "line"))
		}
		return 0
	}
	if len(a.pos) >= 2 && a.pos[0] == "rm" {
		r := req_begin("mount.remove")
		req_str(&r, "root", abs_path(a.pos[1]))
		must(s, req_end(&r), "cannot unmount")
		fmt.println("unmounted")
		return 0
	}
	if len(a.pos) != 1 {
		return usage_error("usage: 0ndb mount DIR [--tree T] [--convo C] [--name NAME] | mount ls | mount rm DIR")
	}
	root := abs_path(a.pos[0])
	convo: api.Object
	has_convo := false
	if c, ok := flag_value(a, "convo"); ok {
		convo = resolve_object(s, c)
		cr := req_begin("catalog.get")
		req_str(&cr, "object", object_str(convo))
		cv := must(s, req_end(&cr), "cannot read the catalog")
		if !jbool(cv, "found") || jstr(jget(cv, "entry"), "kind") != "conversation" {
			fail(.Usage, "%s is not a conversation", c)
		}
		has_convo = true
	}
	tree: api.Object
	if t, ok := flag_value(a, "tree"); ok {
		tree = resolve_object(s, t)
	} else {
		r := req_begin("tree.create")
		req_str(&r, "space", hex(default_space(s, true)))
		name := root[strings.last_index_byte(root, '/') + 1:]
		req_str(&r, "title", name if len(name) > 0 else root)
		v := must(s, req_end(&r), "cannot create the file tree")
		tree, _ = api.parse_object(jstr(v, "object"))
	}
	mr := req_begin("mount.add")
	req_str(&mr, "object", object_str(tree))
	req_str(&mr, "root", root)
	must(s, req_end(&mr), fmt.tprintf("cannot mount %s", root))
	name := flag_string(a, "name", root[strings.last_index_byte(root, '/') + 1:])
	if has_convo {
		cr := req_begin("mount")
		req_str(&cr, "object", object_str(convo))
		req_str(&cr, "name", name)
		req_str(&cr, "tree", hex(tree.id))
		req_str(&cr, "path", name)
		must(s, req_end(&cr), "mounted, but cannot attach it to the conversation")
	}
	if a.json {
		out := make(json.Object, context.temp_allocator)
		out["object"] = json.String(object_str(tree))
		out["root"] = json.String(root)
		print_json(out)
	} else {
		fmt.printfln("mounted %s → tree %s", root, short(hex(tree.id)))
	}
	return 0
}

cmd_schedule :: proc(a: ^Args) -> int {
	if len(a.pos) < 1 {
		return usage_error("usage: 0ndb schedule add|ls|rm")
	}
	s := session(a)
	switch a.pos[0] {
	case "add":
		if len(a.pos) < 3 {
			return usage_error("usage: 0ndb schedule add OWNER PROMPT (--cron EXPR | --at RFC3339|UNIX_MS) [--tz ZONE] [--convo C] [--fresh] [--id ID]")
		}
		r := req_begin("schedule.create")
		req_str(&r, "owner", object_str(resolve_object(s, a.pos[1])))
		req_str(&r, "prompt", a.pos[2])
		req_opt(&r, "id", flag_string(a, "id"))
		req_opt(&r, "cron", flag_string(a, "cron"))
		if at, ok := flag_value(a, "at"); ok {
			ms, mok := strconv.parse_i64(at)
			if !mok {
				ms, mok = parse_rfc3339(at)
			}
			if !mok {
				return usage_error("--at takes unix milliseconds or an RFC 3339 time")
			}
			req_int(&r, "at", ms)
		}
		req_opt(&r, "tz", flag_string(a, "tz"))
		if c, ok := flag_value(a, "convo"); ok {
			req_str(&r, "conversation", object_str(resolve_object(s, c)))
		}
		req_bool(&r, "fresh", flag_bool(a, "fresh"))
		v := must(s, req_end(&r), "cannot create the schedule")
		if a.json {
			print_json(v)
		} else {
			fmt.printfln("scheduled %s", jstr(v, "id"))
		}
	case "ls":
		r := req_begin("schedule.list")
		req_str(&r, "space", hex(default_space(s)))
		v := must(s, req_end(&r), "cannot list schedules")
		if a.json {
			print_json(v)
			return 0
		}
		for x in jarr(v, "schedules") {
			when_ := jstr(x, "cron")
			if len(when_) == 0 {
				when_ = "once"
			}
			fmt.printfln("%s  %s  %s  next %s  %s", short(jstr(x, "id")), short(jstr(x, "owner")[33:] if len(jstr(x, "owner")) == 65 else jstr(x, "owner")), when_, ago(-1) if jint(x, "next") == 0 else fmt.tprintf("in %ds", max((jint(x, "next") - prim.now_ms()) / 1000, 0)), one_line(jstr(x, "prompt"), 60))
		}
	case "rm":
		if len(a.pos) != 3 {
			return usage_error("usage: 0ndb schedule rm OWNER ID")
		}
		r := req_begin("schedule.remove")
		req_str(&r, "owner", object_str(resolve_object(s, a.pos[1])))
		req_str(&r, "id", a.pos[2])
		v := must(s, req_end(&r), "cannot remove the schedule")
		if !jbool(v, "found") {
			return report_error(.Not_Found, "no such schedule")
		}
		fmt.println("removed")
	case:
		return usage_error("usage: 0ndb schedule add|ls|rm")
	}
	return 0
}

parse_rfc3339 :: proc(s: string) -> (ms: i64, ok: bool) {
	if len(s) < 19 || s[4] != '-' || s[7] != '-' || (s[10] != 'T' && s[10] != ' ') || s[13] != ':' || s[16] != ':' {
		return 0, false
	}
	num :: proc(x: string) -> (i64, bool) {
		return strconv.parse_i64(x)
	}
	y := num(s[0:4]) or_return
	mo := num(s[5:7]) or_return
	d := num(s[8:10]) or_return
	h := num(s[11:13]) or_return
	mi := num(s[14:16]) or_return
	se := num(s[17:19]) or_return
	yy := y - (1 if mo <= 2 else 0)
	era := (yy if yy >= 0 else yy - 399) / 400
	yoe := yy - era * 400
	doy := (153 * (mo + (-3 if mo > 2 else 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := era * 146097 + doe - 719468
	ms = ((days * 24 + h) * 60 + mi) * 60_000 + se * 1000
	rest := s[19:]
	if len(rest) > 0 && rest[0] == '.' {
		i := 1
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			i += 1
		}
		rest = rest[i:]
	}
	switch {
	case rest == "Z" || rest == "":
	case len(rest) == 6 && (rest[0] == '+' || rest[0] == '-') && rest[3] == ':':
		oh := num(rest[1:3]) or_return
		om := num(rest[4:6]) or_return
		off := (oh * 60 + om) * 60_000
		ms = ms - off if rest[0] == '+' else ms + off
	case:
		return 0, false
	}
	return ms, true
}

cmd_blame :: proc(a: ^Args) -> int {
	if len(a.pos) != 1 {
		return usage_error("usage: 0ndb blame FILE")
	}
	s := session(a)
	path := abs_path(a.pos[0])
	fr := req_begin("tree.find")
	req_str(&fr, "path", path)
	f := call(s, req_end(&fr))
	if f.status != .Ok {
		return report_error(f.status, "%s is not inside a mounted directory (0ndb mount DIR)", path)
	}
	r := req_begin("tree.blame")
	req_str(&r, "object", jstr(f.value, "object"))
	req_str(&r, "path", jstr(f.value, "rel"))
	v := must(s, req_end(&r), "cannot blame")
	if a.json {
		print_json(v)
		return 0
	}
	names := actor_names(s)
	text := jstr(v, "text")
	spans := jarr(v, "spans")
	lines := strings.split(text, "\n", context.temp_allocator)
	if len(lines) > 0 && len(lines[len(lines) - 1]) == 0 {
		lines = lines[:len(lines) - 1]
	}
	at := 0
	si := 0
	for line, i in lines {
		lo := at
		hi := at + len(line)
		authors := make([dynamic]string, context.temp_allocator)
		for si < len(spans) && jint(spans[si], "hi") <= i64(lo) && jint(spans[si], "hi") != jint(spans[si], "lo") {
			si += 1
		}
		for j := si; j < len(spans); j += 1 {
			sl := jint(spans[j], "lo")
			sh := jint(spans[j], "hi")
			if sl > i64(hi) || (sl == i64(hi) && hi > lo) {
				break
			}
			if sh > i64(lo) || (sh == sl && sl == i64(lo)) {
				who := actor_name(names, jstr(spans[j], "actor"))
				if jbool(spans[j], "redacted") {
					who = "redacted"
				}
				dup := false
				for x in authors {
					dup ||= x == who
				}
				if !dup {
					append(&authors, who)
				}
			}
		}
		fmt.printfln("%-14s %4d │ %s", one_line(strings.join(authors[:], ",", context.temp_allocator), 14), i + 1, line)
		at = hi + 1
	}
	return 0
}

actor_names :: proc(s: ^Session) -> map[string]string {
	out := make(map[string]string, context.temp_allocator)
	out[jstr(must(s, `{"op":"identity"}`), "id")] = "this device"
	if v := call(s, `{"op":"agent.actor"}`); v.status == .Ok {
		out[jstr(v.value, "actor")] = "agent"
	}
	for row in _marked(s, "agent") {
		r := req_begin("agent.actor")
		req_str(&r, "agent", row_id(row))
		v := call(s, req_end(&r))
		if v.status == .Ok {
			out[jstr(v.value, "actor")] = jstr(row, "title")
		}
	}
	return out
}

actor_name :: proc(names: map[string]string, actor: string) -> string {
	if n, ok := names[actor]; ok {
		return n
	}
	return short(actor)
}

cmd_land :: proc(a: ^Args) -> int {
	if len(a.pos) != 1 {
		return usage_error("usage: 0ndb land TREE|DIR --from LINE [--into LINE] [--dry]")
	}
	from := flag_string(a, "from")
	if len(from) == 0 {
		return usage_error("land needs --from LINE")
	}
	s := session(a)
	tree: api.Object
	arg := a.pos[0]
	if strings.contains_rune(arg, '/') || arg == "." {
		fr := req_begin("tree.find")
		req_str(&fr, "path", abs_path(arg))
		f := must(s, req_end(&fr), "not a mounted directory")
		tree, _ = api.parse_object(jstr(f, "object"))
	} else {
		tree = resolve_object(s, arg)
	}
	if len(from) == 32 {
		from = strings.concatenate({"l/", from}, context.temp_allocator)
	}
	r := req_begin("land")
	req_str(&r, "tree", object_str(tree))
	req_str(&r, "from", from)
	req_str(&r, "into", flag_string(a, "into", "main"))
	req_bool(&r, "dry", flag_bool(a, "dry"))
	v := must(s, req_end(&r), "cannot land")
	if a.json {
		print_json(v)
	} else {
		cf := jarr(v, "conflicts")
		if len(cf) > 0 {
			fmt.printfln("%d conflicting regions; resolve them on %s first:", len(cf), from)
			for c in cf {
				fmt.printfln("  %s", jtext(c))
			}
			return int(Exit.Conflict)
		}
		verb := "would land" if flag_bool(a, "dry") else ("landed" if jbool(v, "landed") else "nothing to land")
		fmt.printfln("%s %d files", verb, jint(v, "files"))
	}
	return 0
}

SHARE_PREFIX :: "0ndbshare1"

cmd_share :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) == 1 && a.pos[0] == "card" {
		v := must(s, `{"op":"card"}`)
		if a.json {
			print_json(v)
		} else {
			fmt.println(jstr(v, "card"))
		}
		return 0
	}
	if len(a.pos) == 2 && a.pos[0] == "accept" {
		code := a.pos[1]
		if !strings.has_prefix(code, SHARE_PREFIX) {
			return usage_error("not a share code")
		}
		raw := make([]u8, (len(code) - len(SHARE_PREFIX)) / 2, context.temp_allocator)
		if !prim.hex_decode(raw, transmute([]u8)code[len(SHARE_PREFIX):]) {
			return usage_error("not a share code")
		}
		r := prim.reader(raw)
		share := prim.read_bytes(&r)
		token := prim.read_bytes(&r)
		space := prim.read_id(&r)
		relay := prim.read_str(&r)
		key := prim.read_bytes(&r)
		if !prim.reader_done(&r) {
			return usage_error("damaged share code")
		}
		cr := req_begin("credentials.add")
		req_str(&cr, "space", hex(space))
		req_str(&cr, "token", hex_of(token))
		must(s, req_end(&cr), "cannot store the capability")
		jr := req_begin("space.join_shared")
		req_str(&jr, "space", hex(space))
		req_opt(&jr, "relay", relay)
		req_opt(&jr, "relay_key", hex_of(key))
		must(s, req_end(&jr), "cannot join the shared space")
		ar := req_begin("share.accept")
		req_str(&ar, "share", hex_of(share))
		v := must(s, req_end(&ar), "cannot accept the share")
		if a.json {
			print_json(v)
		} else {
			fmt.printfln("shared object %s", jstr(v, "object"))
		}
		return 0
	}
	if len(a.pos) != 2 {
		return usage_error("usage: 0ndb share card | share OBJECT CARD [--write] | share accept CODE")
	}
	ob := resolve_object(s, a.pos[0])
	card := a.pos[1]
	sr := req_begin("share.object")
	req_str(&sr, "object", object_str(ob))
	req_str(&sr, "card", card)
	sv := must(s, req_end(&sr), "cannot share")
	cb := make([]u8, len(card) / 2, context.temp_allocator)
	if len(cb) < 32 || !prim.hex_decode(cb, transmute([]u8)card) {
		return usage_error("CARD is the hex string printed by 0ndb share card on the other device")
	}
	pk: osync.Public_Key
	copy(pk[:], cb[:32])
	grantee := hex(osync.device_id(pk))
	access := i64(1)
	if flag_bool(a, "write") {
		access = 3
	}
	tr := req_begin("capability.issue")
	req_str(&tr, "object", object_str(ob))
	req_str(&tr, "grantee", grantee)
	req_int(&tr, "access", access)
	tv := must(s, req_end(&tr), "cannot issue the capability")
	ir := req_begin("space.info")
	req_str(&ir, "space", hex(ob.space))
	iv := must(s, req_end(&ir))
	info := jarr(iv, "space")[0]
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_bytes(&w, unhex(jstr(sv, "share")))
	prim.write_bytes(&w, unhex(jstr(tv, "token")))
	prim.write_id(&w, ob.space)
	prim.write_str(&w, jstr(info, "relay"))
	prim.write_bytes(&w, unhex(jstr(info, "relay_key")))
	code := strings.concatenate({SHARE_PREFIX, hex_of(buf[:])}, context.temp_allocator)
	if a.json {
		out := make(json.Object, context.temp_allocator)
		out["code"] = json.String(code)
		print_json(out)
	} else {
		fmt.println(code)
	}
	return 0
}

hex_of :: proc(b: []u8) -> string {
	out := make([]u8, len(b) * 2, context.temp_allocator)
	prim.hex_encode(out, b)
	return string(out)
}

unhex :: proc(s: string) -> []u8 {
	out := make([]u8, len(s) / 2, context.temp_allocator)
	prim.hex_decode(out, transmute([]u8)s)
	return out
}

cmd_verify :: proc(a: ^Args) -> int {
	s := session(a)
	roots := make([dynamic]string, context.temp_allocator)
	if len(a.pos) > 0 {
		for p in a.pos {
			append(&roots, abs_path(p))
		}
	} else {
		for m in jarr(must(s, `{"op":"tree.mounts"}`), "mounts") {
			append(&roots, jstr(m, "root"))
		}
	}
	if len(roots) == 0 {
		fmt.println("nothing mounted")
		return 0
	}
	bad := 0
	for root in roots {
		r := req_begin("verify")
		req_str(&r, "root", root)
		v := must(s, req_end(&r), fmt.tprintf("cannot verify %s", root))
		if a.json {
			print_json(v)
		}
		mm := jarr(v, "mismatches")
		bad += len(mm)
		if !a.json {
			if len(mm) == 0 {
				fmt.printfln("%s: %d files match their history", root, jint(v, "files"))
			} else {
				fmt.printfln("%s: %d of %d files differ:", root, len(mm), jint(v, "files"))
				for x in mm {
					fmt.printfln("  %s", jtext(x))
				}
			}
		}
	}
	return 0 if bad == 0 else int(Exit.Error)
}

cmd_mcp :: proc(a: ^Args) -> int {
	s := session(a)
	ob := resolve_object(s, a.pos[0]) if len(a.pos) > 0 else current_convo(s)
	if !mcp_open(&s.c, ob) {
		return report_error(.Closed, "the daemon refused the MCP session")
	}
	return mcp_bridge(s.c.fd)
}

mcp_open :: proc(c: ^Client, caller: api.Object) -> bool {
	b: [32]u8
	sp, id := caller.space, caller.id
	copy(b[:16], sp[:])
	copy(b[16:], id[:])
	if !client_send(c, .Mcp, b[:]) {
		return false
	}
	k, p, ok := client_read(c, 10_000)
	return ok && k == .Result && len(p) == 9 && p[8] == 0 && len(c.rbuf) == 0
}

Mcp_Client :: struct {
	c:    ^Client,
	next: int,
	line: [dynamic]u8,
}

@(private)
_mcp_request :: proc(m: ^Mcp_Client, method: string, params: string, notify := false) -> (json.Value, bool) {
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, `{"jsonrpc":"2.0",`)
	if !notify {
		m.next += 1
		append(&b, fmt.tprintf(`"id":%d,`, m.next))
	}
	append(&b, `"method":`)
	api.json_string(&b, method)
	put(&b, `,"params":`, params, "}\n")
	if !_write_all(m.c.fd, b[:]) {
		return nil, false
	}
	if notify {
		return nil, true
	}
	for {
		for i := 0; i < len(m.line); i += 1 {
			if m.line[i] == '\n' {
				line := strings.clone(string(m.line[:i]), context.temp_allocator)
				remove_range(&m.line, 0, i + 1)
				v, err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
				if err != .None {
					i = -1
					continue
				}
				if jint(v, "id") == i64(m.next) {
					return v, true
				}
				if _, is_null := jget(v, "id").(json.Null); is_null && jget(v, "error") != nil {
					return v, true
				}
				i = -1
			}
		}
		buf: [65536]u8
		n, st := sock_read(m.c.fd, buf[:])
		if st == .Again {
			continue
		}
		if st != .Ok {
			return nil, false
		}
		append(&m.line, ..buf[:n])
	}
}

tool_call :: proc(s: ^Session, caller: api.Object, tool: string, input: string) -> (text: string, structured: json.Value, is_error: bool) {
	if !mcp_open(&s.c, caller) {
		fail(.Daemon, "the daemon refused the MCP session")
	}
	m := Mcp_Client{c = &s.c, line = make([dynamic]u8, context.temp_allocator)}
	if _, ok := _mcp_request(&m, "initialize", `{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"0ndb-cli","version":"1"}}`); !ok {
		fail(.Daemon, "MCP initialize failed")
	}
	_mcp_request(&m, "notifications/initialized", "{}", true)
	p := make([dynamic]u8, context.temp_allocator)
	append(&p, `{"name":`)
	api.json_string(&p, tool)
	put(&p, `,"arguments":`, input, "}")
	v, ok := _mcp_request(&m, "tools/call", string(p[:]))
	if !ok {
		fail(.Daemon, "lost the MCP session")
	}
	if e := jget(v, "error"); e != nil {
		return jstr(e, "message"), nil, true
	}
	res := jget(v, "result")
	b := strings.builder_make(context.temp_allocator)
	for c in jarr(res, "content") {
		if jstr(c, "type") == "text" {
			strings.write_string(&b, jstr(c, "text"))
		}
	}
	return strings.to_string(b), jget(res, "structuredContent"), jbool(res, "isError")
}

cmd_task :: proc(a: ^Args) -> int {
	if len(a.pos) < 1 {
		return usage_error("usage: 0ndb task spawn GOAL | send TASK TEXT | wait [TASK...] | ls | cancel TASK... | result TASK | merge TASK | status TASK")
	}
	s := session(a)
	from := resolve_object(s, flag_string(a, "from")) if len(flag_string(a, "from")) > 0 else current_convo(s)
	in_ := make([dynamic]u8, context.temp_allocator)
	tool := a.pos[0]
	ids :: proc(s: ^Session, list: []string, b: ^[dynamic]u8) {
		append(b, '[')
		for t, i in list {
			if i > 0 {
				append(b, ',')
			}
			api.json_string(b, hex(resolve_object(s, t).id))
		}
		append(b, ']')
	}
	switch tool {
	case "spawn":
		if len(a.pos) < 2 {
			return usage_error("usage: 0ndb task spawn GOAL [--title T] [--agent A] [--provider P] [--model M]")
		}
		append(&in_, `{"goal":`)
		api.json_string(&in_, strings.join(a.pos[1:], " ", context.temp_allocator))
		for k in ([]string{"title", "agent", "provider", "model", "context", "runner"}) {
			if v, ok := flag_value(a, k); ok {
				append(&in_, ',')
				api.json_string(&in_, k)
				append(&in_, ':')
				api.json_string(&in_, v)
			}
		}
		append(&in_, '}')
	case "send":
		if len(a.pos) < 3 {
			return usage_error("usage: 0ndb task send TASK TEXT [--mode queue|steer|interrupt]")
		}
		append(&in_, `{"task":`)
		api.json_string(&in_, hex(resolve_object(s, a.pos[1]).id))
		append(&in_, `,"message":`)
		api.json_string(&in_, a.pos[2])
		append(&in_, `,"mode":`)
		api.json_string(&in_, flag_string(a, "mode", "queue"))
		append(&in_, '}')
	case "wait":
		append(&in_, '{')
		if len(a.pos) > 1 {
			append(&in_, `"tasks":`)
			ids(s, a.pos[1:], &in_)
			append(&in_, ',')
		}
		append(&in_, `"condition":`)
		api.json_string(&in_, flag_string(a, "condition", "all"))
		if v, ok := flag_value(a, "seconds"); ok {
			put(&in_, `,"timeout_seconds":`, v)
		}
		append(&in_, '}')
	case "ls", "list":
		tool = "list"
		put(&in_, `{"recursive":`, "true" if flag_bool(a, "recursive") else "false", "}")
	case "cancel":
		if len(a.pos) < 2 {
			return usage_error("usage: 0ndb task cancel TASK... [--reason R]")
		}
		append(&in_, `{"tasks":`)
		ids(s, a.pos[1:], &in_)
		append(&in_, `,"reason":`)
		api.json_string(&in_, flag_string(a, "reason", "cancelled from the CLI"))
		append(&in_, '}')
	case "result", "merge":
		if len(a.pos) != 2 {
			return usage_error("usage: 0ndb task %s TASK", tool)
		}
		append(&in_, `{"task":`)
		api.json_string(&in_, hex(resolve_object(s, a.pos[1]).id))
		if tool == "result" {
			append(&in_, fmt.tprintf(`,"diff":%v`, flag_bool(a, "diff")))
		} else {
			append(&in_, fmt.tprintf(`,"dry_run":%v`, flag_bool(a, "dry")))
		}
		append(&in_, '}')
	case "status":
		if len(a.pos) != 2 {
			return usage_error("usage: 0ndb task status TASK")
		}
		r := req_begin("task.status")
		req_str(&r, "object", object_str(resolve_object(s, a.pos[1])))
		v := must(s, req_end(&r), "cannot read the task")
		if a.json {
			print_json(v)
		} else {
			fmt.printfln("%s%s", jstr(v, "status"), fmt.tprintf(": %s", one_line(jstr(v, "summary"), 200)) if len(jstr(v, "summary")) > 0 else "")
		}
		return 0
	case:
		return usage_error("unknown task command %q", tool)
	}
	text, structured, is_error := tool_call(s, from, tool, string(in_[:]))
	if a.json && structured != nil {
		print_json(structured)
	} else {
		fmt.println(text)
	}
	return int(Exit.Error) if is_error else 0
}

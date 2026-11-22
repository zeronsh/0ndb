package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../capi/api"
import "../prim"

@(private)
_convo_and_rest :: proc(s: ^Session, a: ^Args, need: int) -> (ob: api.Object, rest: []string) {
	if len(a.pos) > need {
		return resolve_object(s, a.pos[0]), a.pos[1:]
	}
	return current_convo(s), a.pos[:]
}

@(private)
_print_result :: proc(a: ^Args, v: json.Value, label: string, key: string) {
	if a.json {
		print_json(v)
		return
	}
	if len(key) > 0 && len(jstr(v, key)) > 0 {
		fmt.printfln("%s %s", label, short_rid(jstr(v, key)))
	} else if len(label) > 0 {
		fmt.println(label)
	}
}

cmd_new :: proc(a: ^Args) -> int {
	s := session(a)
	space := default_space(s, true)
	r := req_begin("convo.create")
	req_str(&r, "space", hex(space))
	title := strings.join(a.pos[:], " ", context.temp_allocator)
	req_opt(&r, "title", title)
	if v, ok := flag_value(a, "agent"); ok {
		req_str(&r, "agent", hex(resolve_object(s, v).id))
	}
	if v, ok := flag_value(a, "workspace"); ok {
		req_str(&r, "workspace", hex(resolve_object(s, v).id))
	}
	if v, ok := flag_value(a, "parent"); ok {
		req_str(&r, "parent", object_str(resolve_object(s, v)))
	}
	req_opt(&r, "provider", flag_string(a, "provider"))
	req_opt(&r, "model", flag_string(a, "model"))
	v := must(s, req_end(&r), "cannot create the conversation")
	ob, _ := api.parse_object(jstr(v, "object"))
	set_current(s, ob)
	msg := ""
	if text, ok := flag_value(a, "message"); ok {
		sr := req_begin("send")
		req_str(&sr, "object", object_str(ob))
		req_str(&sr, "text", text)
		sv := must(s, req_end(&sr), "cannot send")
		msg = jstr(sv, "item")
	}
	if a.json {
		out := make([dynamic]u8, context.temp_allocator)
		append(&out, `{"object":`)
		api.json_string(&out, object_str(ob))
		if len(msg) > 0 {
			append(&out, `,"msg":`)
			api.json_string(&out, msg)
		}
		append(&out, '}')
		fmt.println(string(out[:]))
	} else {
		fmt.printfln("conversation %s%s", short(hex(ob.id)), fmt.tprintf(" · sent %s", short_rid(msg)) if len(msg) > 0 else "")
	}
	_await_upload(s, ob)
	if len(msg) > 0 && flag_bool(a, "wait") {
		return follow(s, ob, true, msg)
	}
	return 0
}

@(private)
_await_upload :: proc(s: ^Session, ob: api.Object) {
	interrupt_note_on("\n0ndb: interrupted before the relay confirmed the upload; it is saved on this device and uploads in the background\n")
	defer interrupt_note_off()
	r := req_begin("object.uploaded")
	req_str(&r, "object", object_str(ob))
	v := client_call(&s.c, req_end(&r), 0)
	if v.status != .Ok {
		fmt.eprintfln("0ndb: saved on this device, but the relay did not take the upload (%v)", v.status)
	} else if jbool(v.value, "dropped") {
		fmt.eprintln("0ndb: saved on this device; the relay connection dropped before the upload was confirmed, so other devices see it once it reconnects")
	}
}

@(private)
_exec_text :: proc(a: ^Args, op: string, verb: string) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 1)
	text := read_text(a, rest[0] if len(rest) > 0 else "")
	if len(text) == 0 && !flag_bool(a, "stdin") {
		return usage_error("%s needs TEXT (or --stdin)", op)
	}
	r := req_begin(op)
	req_str(&r, "object", object_str(ob))
	req_str(&r, "text", text)
	if op == "send" {
		req_opt(&r, "provider", flag_string(a, "provider"))
		req_opt(&r, "model", flag_string(a, "model"))
		if p, ok := flag_value(a, "parent"); ok {
			req_str(&r, "parent", rid_str(resolve_msg(s, ob, p)))
		}
	}
	v := must(s, req_end(&r), fmt.tprintf("cannot %s", op))
	_print_result(a, v, verb, "item")
	if op == "send" && flag_bool(a, "wait") {
		return follow(s, ob, true, jstr(v, "item"))
	}
	return 0
}

cmd_send :: proc(a: ^Args) -> int {
	return _exec_text(a, "send", "sent")
}

cmd_queue :: proc(a: ^Args) -> int {
	return _exec_text(a, "queue", "queued")
}

cmd_steer :: proc(a: ^Args) -> int {
	return _exec_text(a, "steer", "steered")
}

cmd_edit :: proc(a: ^Args) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 2)
	if len(rest) < 2 {
		return usage_error("usage: 0ndb edit [CONVO] ITEM TEXT")
	}
	r := req_begin("edit")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "item", rid_str(resolve_intent(s, ob, rest[0])))
	req_str(&r, "text", rest[1])
	v := must(s, req_end(&r), "cannot edit")
	_print_result(a, v, "edited", "")
	return 0
}

resolve_intent :: proc(s: ^Session, ob: api.Object, text: string) -> api.Rid {
	if r, ok := api.parse_rid(text); ok {
		return r
	}
	r := req_begin("convo.intents")
	req_str(&r, "object", object_str(ob))
	v := must(s, req_end(&r))
	for it in jarr(v, "intents") {
		id := jstr(it, "item")
		if short_rid(id) == text || (len(id) > 33 && id_matches(id[:32], text)) {
			x, _ := api.parse_rid(id)
			return x
		}
	}
	os.exit(report_error(.Not_Found, "no queued item matches %q", text))
}

cmd_interrupt :: proc(a: ^Args) -> int {
	s := session(a)
	ob, _ := _convo_and_rest(s, a, 0)
	r := req_begin("interrupt")
	req_str(&r, "object", object_str(ob))
	v := must(s, req_end(&r), "cannot interrupt")
	_print_result(a, v, "interrupted", "")
	return 0
}

cmd_switch :: proc(a: ^Args) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 1)
	if len(rest) < 1 {
		return usage_error("usage: 0ndb switch [CONVO] SIBLING|next|prev")
	}
	target: api.Rid
	switch rest[0] {
	case "next", "prev":
		fork := ""
		for m in page(s, ob, 4096) {
			if jint(m, "siblings") > 1 {
				fork = jstr(m, "id")
				break
			}
		}
		if len(fork) == 0 {
			return report_error(.Not_Found, "the current branch has no fork")
		}
		lr := req_begin("convo.siblings")
		req_str(&lr, "object", object_str(ob))
		req_str(&lr, "msg", fork)
		v := must(s, req_end(&lr))
		list := jarr(v, "siblings")
		at := int(jint(v, "at")) - 1
		if len(list) < 2 || at < 0 {
			return report_error(.Not_Found, "the current branch has no fork")
		}
		i := (at + 1) % len(list) if rest[0] == "next" else (at + len(list) - 1) % len(list)
		target, _ = api.parse_rid(jtext(list[i]))
	case:
		target = resolve_msg(s, ob, rest[0])
	}
	if flag_bool(a, "preview") {
		n := int(parse_int_flag(a, "limit", 10))
		pr := req_begin("convo.peek_switch")
		req_str(&pr, "object", object_str(ob))
		req_str(&pr, "sibling", rid_str(target))
		req_int(&pr, "before", i64(max(n / 2, 0)))
		req_int(&pr, "after", i64(max(n - n / 2 - 1, 0)))
		pv := must(s, req_end(&pr), "cannot preview the branch")
		if a.json {
			print_json(pv)
			return 0
		}
		self := jstr(must(s, `{"op":"identity"}`), "id")
		_hint(a, "older", jbool(pv, "more_older"), jstr(pv, "older_cursor"))
		_print_list(a, jarr(pv, "messages")[:], self, int(jint(pv, "anchor")))
		_hint(a, "newer", jbool(pv, "more_newer"), jstr(pv, "newer_cursor"))
		fmt.printfln("preview only: switching would put you at %s", short_rid(jstr(pv, "leaf")))
		return 0
	}
	r := req_begin("switch")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "sibling", rid_str(target))
	v := must(s, req_end(&r), "cannot switch")
	_print_result(a, v, "now on", "leaf")
	return 0
}

cmd_back :: proc(a: ^Args) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 1)
	if len(rest) < 1 {
		return usage_error("usage: 0ndb back [CONVO] MSG")
	}
	msg := resolve_msg(s, ob, rest[0])
	r := req_begin("back")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "msg", rid_str(msg))
	v := must(s, req_end(&r), "cannot go back")
	g := req_begin("go_back")
	req_str(&g, "object", object_str(ob))
	req_str(&g, "msg", rid_str(msg))
	gr := call(s, req_end(&g))
	if gr.status != .Ok && gr.status != .Unsupported {
		return report_error(gr.status, "went back, but restoring the mounted files failed")
	}
	_print_result(a, v, "back at", "leaf")
	return 0
}

@(private)
_print_list :: proc(a: ^Args, msgs: []json.Value, self: string, anchor := -1) {
	for m, i in msgs {
		if a.json {
			print_json(m)
		} else {
			print_message(m, self, "▶" if i == anchor else "●")
		}
	}
}

@(private)
_hint :: proc(a: ^Args, label: string, more: bool, cursor: string) {
	if more && !a.json {
		fmt.printfln("  … %s: 0ndb log --%s %s", label, label, cursor)
	}
}

cmd_log :: proc(a: ^Args) -> int {
	s := session(a)
	ob, _ := _convo_and_rest(s, a, 0)
	n := int(parse_int_flag(a, "limit", 20))
	if n <= 0 {
		return usage_error("-n takes a positive number")
	}
	self := jstr(must(s, `{"op":"identity"}`), "id")
	leaf := ""
	if l, ok := flag_value(a, "leaf"); ok {
		leaf = rid_str(resolve_msg(s, ob, l))
	}
	if anchor, ok := flag_value(a, "around"); ok {
		r := req_begin("convo.window")
		req_str(&r, "object", object_str(ob))
		req_str(&r, "anchor", rid_str(resolve_msg(s, ob, anchor)))
		req_int(&r, "before", i64(n / 2))
		req_int(&r, "after", i64(max(n - n / 2 - 1, 0)))
		req_opt(&r, "leaf", leaf)
		v := must(s, req_end(&r), "cannot read the window")
		if a.json {
			print_json(v)
			return 0
		}
		_hint(a, "older", jbool(v, "more_older"), jstr(v, "older_cursor"))
		_print_list(a, jarr(v, "messages")[:], self, int(jint(v, "anchor")))
		_hint(a, "newer", jbool(v, "more_newer"), jstr(v, "newer_cursor"))
		return 0
	}
	older, has_older := flag_value(a, "older")
	newer, has_newer := flag_value(a, "newer")
	if has_older || has_newer {
		if has_older && has_newer {
			return usage_error("use either --older or --newer")
		}
		cursor := older if has_older else newer
		cb := make([]u8, len(cursor) / 2, context.temp_allocator)
		if len(cursor) < 4 || !prim.hex_decode(cb, transmute([]u8)cursor) {
			return usage_error("%q is not a cursor (use the one 0ndb log printed)", cursor)
		}
		is_newer := cb[1] & 2 != 0
		if is_newer != has_newer {
			return usage_error("that cursor pages %s; use --%s", "newer" if is_newer else "older", "newer" if is_newer else "older")
		}
		r := req_begin("convo.page")
		req_str(&r, "object", object_str(ob))
		req_int(&r, "limit", i64(n))
		req_str(&r, "cursor", cursor)
		v := must(s, req_end(&r), "cannot read the conversation")
		msgs := jarr(v, "messages")
		if len(msgs) == 0 && !a.json {
			fmt.printfln("no %s messages", "newer" if has_newer else "older")
		}
		if has_older {
			for i in 0 ..< len(msgs) / 2 {
				msgs[i], msgs[len(msgs) - 1 - i] = msgs[len(msgs) - 1 - i], msgs[i]
			}
		}
		if a.json {
			print_json(v)
			return 0
		}
		if has_older {
			_hint(a, "older", jbool(v, "more"), jstr(v, "cursor"))
		}
		_print_list(a, msgs[:], self)
		if has_newer {
			_hint(a, "newer", jbool(v, "more"), jstr(v, "cursor"))
		}
		return 0
	}
	r := req_begin("convo.page")
	req_str(&r, "object", object_str(ob))
	req_int(&r, "limit", i64(n))
	v := must(s, req_end(&r), "cannot read the conversation")
	msgs := jarr(v, "messages")
	for i in 0 ..< len(msgs) / 2 {
		msgs[i], msgs[len(msgs) - 1 - i] = msgs[len(msgs) - 1 - i], msgs[i]
	}
	if !a.json {
		_hint(a, "older", jbool(v, "more"), jstr(v, "cursor"))
	}
	_print_list(a, msgs[:], self)
	if !a.json {
		ir := req_begin("convo.intents")
		req_str(&ir, "object", object_str(ob))
		if iv := call(s, req_end(&ir)); iv.status == .Ok {
			for it in jarr(iv.value, "intents") {
				fmt.printfln("⇢ %s %s · %s", jstr(it, "kind"), short_rid(jstr(it, "item")), one_line(jstr(it, "text"), 100))
			}
		}
	}
	if flag_bool(a, "follow") {
		return follow(s, ob, false)
	}
	return 0
}

follow :: proc(s: ^Session, ob: api.Object, until_idle: bool, sent := "") -> int {
	seen_running := false
	if until_idle {
		sr := req_begin("convo.status")
		req_str(&sr, "object", object_str(ob))
		st := jstr(must(s, req_end(&sr)), "status")
		seen_running = st == "running" || st == "queued" || st == "awaiting_permission" || st == "reviving"
	}
	last_place := ""
	if until_idle {
		if p, ok := placement(s, ob); ok && !s.a.json {
			if t := placement_text(p); jstr(p, "state") == "waiting_runner" {
				fmt.printfln("  ⧗ %s", t)
				last_place = t
			}
		}
		ev_flags := [1]u8{1}
		client_send(&s.c, .Events, ev_flags[:])
	}
	r := req_begin("subscribe")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "kind", "conversation")
	tag := client_subscribe(&s.c, req_end(&r))
	self := jstr(must(s, `{"op":"identity"}`), "id")
	seen_seal := false
	open_block := false
	for {
		k, p, ok := client_read(&s.c)
		if !ok {
			return report_error(.Closed, "lost the connection to the daemon")
		}
		if k == .Result && len(p) >= 9 && prim.get_u64le(p[:8]) == tag {
			if api.Status(p[8]) != .Ok {
				return report_error(api.Status(p[8]), "cannot follow the conversation")
			}
			continue
		}
		if k == .Event {
			ev, eerr := json.parse(p, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
			if eerr == .None && jstr(ev, "kind") == "placement" && jstr(ev, "object") == hex(ob.id) {
				if s.a.json {
					fmt.println(string(p))
				} else if t := placement_text(ev); len(t) > 0 && t != last_place && jstr(ev, "state") != "running" {
					fmt.printfln("  ⧗ %s", t)
					last_place = t
				}
			}
			continue
		}
		if k != .Deltas || len(p) < 8 || prim.get_u64le(p[:8]) != tag {
			continue
		}
		if s.a.json {
			fmt.println(string(p[8:]))
		}
		v, err := json.parse(p[8:], json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if err != .None {
			continue
		}
		for d in jarr(v, "deltas") {
			kind := jstr(d, "kind")
			if kind == "seal" && jstr(d, "msg") != sent {
				seen_seal = true
			}
			if !s.a.json {
				switch kind {
				case "message":
					if open_block {
						fmt.println()
						open_block = false
					}
					who := jstr(d, "role")
					if by := jstr(d, "by"); who == "user" && len(by) > 0 && by != self {
						who = fmt.tprintf("user@%s", short(by))
					}
					fmt.printfln("● %s · %s", who, short_rid(jstr(d, "rid")))
				case "block":
					if open_block {
						fmt.println()
					}
					bk := jstr(d, "block")
					if bk != "text" {
						fmt.printf("  [%s] ", bk)
					} else {
						fmt.print("  ")
					}
					fmt.print(jstr(d, "text"))
					open_block = true
				case "chunk":
					fmt.print(jstr(d, "text"))
					open_block = true
				case "seal":
					if open_block {
						fmt.println()
						open_block = false
					}
					if st := jstr(d, "seal"); st != "done" {
						fmt.printfln("  (%s)", st)
					}
				case "intent":
					fmt.printfln("  ⇢ intent %s", one_line(jstr(d, "text"), 80))
				case "redacted":
					fmt.println("  ✂ redacted")
				}
			}
			if kind == "status" {
				st := jstr(d, "status")
				if st == "running" || st == "queued" || st == "awaiting_permission" || st == "reviving" {
					seen_running = true
				} else if until_idle && (seen_running || seen_seal || st == "failed" || st == "interrupted") {
					if open_block {
						fmt.println()
					}
					return 0 if st == "idle" else int(Exit.Error)
				}
			}
		}
	}
}

cmd_show :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) < 1 {
		return usage_error("usage: 0ndb show OBJECT|MSG [CONVO]")
	}
	target := a.pos[0]
	is_msg := strings.index_byte(target, ':') > 0 || (len(target) > 0 && target[0] == '@')
	if is_msg && len(target) != 65 {
		ob := resolve_object(s, a.pos[1]) if len(a.pos) > 1 else current_convo(s)
		msg := resolve_msg(s, ob, target)
		r := req_begin("convo.message")
		req_str(&r, "object", object_str(ob))
		req_str(&r, "msg", rid_str(msg))
		v := must(s, req_end(&r), "cannot read the message")
		if a.json {
			print_json(jget(v, "message"))
		} else {
			print_message(jget(v, "message"), jstr(must(s, `{"op":"identity"}`), "id"))
		}
		return 0
	}
	ob := resolve_object(s, target)
	cr := req_begin("catalog.get")
	req_str(&cr, "object", object_str(ob))
	cv := must(s, req_end(&cr), "cannot read the catalog")
	entry := jget(cv, "entry")
	kind := jstr(entry, "kind")
	if !jbool(cv, "found") {
		return _show_uncataloged(s, a, ob)
	}
	if a.json {
		print_json(cv)
	} else {
		fmt.printfln("%s %s %q", kind, hex(ob.id), jstr(entry, "title"))
		fmt.printfln("  space %s · activity %s · participants %d", short(hex(ob.space)), ago(jint(entry, "activity")), len(jarr(entry, "participants")))
		if p := jstr(jget(entry, "parent"), "object"); len(p) > 0 {
			fmt.printfln("  parent %s", short(p))
		}
	}
	switch kind {
	case "conversation":
		sr := req_begin("convo.status")
		req_str(&sr, "object", object_str(ob))
		st := must(s, req_end(&sr))
		mr := req_begin("convo.mounts")
		req_str(&mr, "object", object_str(ob))
		mv := must(s, req_end(&mr))
		if a.json {
			print_json(st)
			print_json(mv)
			return 0
		}
		fmt.printfln("  status %s · head %s · queued %d", jstr(st, "status"), short_rid(jstr(st, "head")), jint(st, "queued"))
		for m in jarr(mv, "mounts") {
			if !jbool(m, "removed") {
				fmt.printfln("  mount %s → tree %s", jstr(m, "name"), short(jstr(m, "tree")))
			}
		}
	case "text":
		tr := req_begin("text.read")
		req_str(&tr, "object", object_str(ob))
		tv := must(s, req_end(&tr))
		if a.json {
			print_json(tv)
		} else {
			fmt.println(jstr(tv, "text"))
		}
	case "tree":
		lr := req_begin("tree.list")
		req_str(&lr, "object", object_str(ob))
		req_str(&lr, "path", "")
		lv := must(s, req_end(&lr))
		if a.json {
			print_json(lv)
		} else {
			for n in jarr(lv, "names") {
				fmt.printfln("  %s", jtext(n))
			}
		}
	case "map":
		mr := req_begin("map.scan")
		req_str(&mr, "object", object_str(ob))
		req_int(&mr, "limit", 200)
		mv := must(s, req_end(&mr))
		if a.json {
			print_json(mv)
			return 0
		}
		for row in jarr(mv, "rows") {
			fmt.printfln("  key %s", printable(jstr(row, "key")))
			for rg in jarr(row, "registers") {
				fmt.printfln("    %d = %s", jint(rg, "tag"), printable(jstr(rg, "value")))
			}
			for el in jarr(row, "elements") {
				fmt.printfln("    %d ∋ %s", jint(el, "tag"), printable(jstr(el, "value")))
			}
		}
	}
	return 0
}

printable :: proc(hex_value: string) -> string {
	if len(hex_value) % 2 != 0 {
		return hex_value
	}
	b := make([]u8, len(hex_value) / 2, context.temp_allocator)
	if !prim.hex_decode(b, transmute([]u8)hex_value) {
		return hex_value
	}
	for c in b {
		if (c < 0x20 && c != '\n' && c != '\t') || c == 0x7f {
			return hex_value
		}
	}
	return one_line(string(b), 120)
}

cmd_record :: proc(a: ^Args) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 1)
	source := flag_string(a, "source")
	ext := flag_string(a, "id")
	if len(source) == 0 || len(ext) == 0 {
		return usage_error("record needs --source and --id")
	}
	text := read_text(a, rest[0] if len(rest) > 0 else "")
	r := req_begin("record")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "source", source)
	req_str(&r, "external_id", ext)
	seq := i64(1)
	if v, ok := flag_value(a, "seq"); ok {
		x, xok := strconv.parse_i64(v)
		if !xok || x < 0 {
			return usage_error("--seq takes a number")
		}
		seq = x
	}
	req_int(&r, "sequence", seq)
	req_str(&r, "role", flag_string(a, "role", "assistant"))
	req_str(&r, "status", flag_string(a, "status", "done"))
	req_opt(&r, "model", flag_string(a, "model"))
	req_opt(&r, "provider", flag_string(a, "provider"))
	blocks := make([dynamic]u8, context.temp_allocator)
	append(&blocks, `[{"kind":"text","text":`)
	api.json_string(&blocks, text)
	append(&blocks, "}]")
	req_raw(&r, "blocks", string(blocks[:]))
	v := must(s, req_end(&r), "cannot record")
	if a.json {
		print_json(v)
	} else {
		fmt.printfln("%s %s", jstr(v, "receipt"), short_rid(jstr(v, "msg")))
	}
	return 0
}

cmd_redact :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) >= 1 && a.pos[0] == "text" {
		if len(a.pos) != 4 {
			return usage_error("usage: 0ndb redact text OBJECT POS LEN")
		}
		pos, ok1 := strconv.parse_i64(a.pos[2])
		n, ok2 := strconv.parse_i64(a.pos[3])
		if !ok1 || !ok2 || pos < 0 || n <= 0 {
			return usage_error("POS and LEN are byte counts")
		}
		r := req_begin("text.redact")
		req_str(&r, "object", object_str(resolve_object(s, a.pos[1])))
		req_int(&r, "pos", pos)
		req_int(&r, "len", n)
		must(s, req_end(&r), "cannot redact")
		fmt.println("redacted")
		return 0
	}
	if len(a.pos) >= 1 && a.pos[0] == "key" {
		if len(a.pos) != 3 {
			return usage_error("usage: 0ndb redact key MAP KEY")
		}
		kb := make([dynamic]u8, context.temp_allocator)
		for c in transmute([]u8)a.pos[2] {
			append(&kb, api.HEX[c >> 4], api.HEX[c & 15])
		}
		r := req_begin("map.redact")
		req_str(&r, "object", object_str(resolve_object(s, a.pos[1])))
		req_str(&r, "key", string(kb[:]))
		must(s, req_end(&r), "cannot redact")
		fmt.println("redacted")
		return 0
	}
	ob, rest := _convo_and_rest(s, a, 1)
	if len(rest) < 1 {
		return usage_error("usage: 0ndb redact [CONVO] MSG")
	}
	msg := resolve_msg(s, ob, rest[0])
	r := req_begin("redact")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "msg", rid_str(msg))
	v := must(s, req_end(&r), "cannot redact")
	if a.json {
		print_json(v)
	} else {
		fmt.printfln("redacted %s", short_rid(rid_str(msg)))
	}
	return 0
}

cmd_revert :: proc(a: ^Args) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 1)
	if len(rest) < 1 {
		return usage_error("usage: 0ndb revert [CONVO] MSG")
	}
	r := req_begin("revert")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "msg", rid_str(resolve_msg(s, ob, rest[0])))
	v := must(s, req_end(&r), "cannot revert")
	if a.json {
		print_json(v)
		return 0
	}
	list := jarr(v, "reverted")
	if len(list) == 0 {
		fmt.println("nothing to revert (no mounted tree changed in that turn)")
	}
	for m in list {
		fmt.printfln("reverted %s", jtext(m))
	}
	return 0
}

@(private)
_show_uncataloged :: proc(s: ^Session, a: ^Args, ob: api.Object) -> int {
	tr := req_begin("text.read")
	req_str(&tr, "object", object_str(ob))
	if v := call(s, req_end(&tr)); v.status == .Ok {
		if a.json {
			print_json(v.value)
		} else {
			fmt.printfln("text %s", hex(ob.id))
			fmt.println(jstr(v.value, "text"))
		}
		return 0
	}
	lr := req_begin("tree.list")
	req_str(&lr, "object", object_str(ob))
	req_str(&lr, "path", "")
	if v := call(s, req_end(&lr)); v.status == .Ok && len(jarr(v.value, "names")) > 0 {
		if a.json {
			print_json(v.value)
		} else {
			fmt.printfln("tree %s", hex(ob.id))
			for n in jarr(v.value, "names") {
				fmt.printfln("  %s", jtext(n))
			}
		}
		return 0
	}
	msgs := page(s, ob, 20)
	if len(msgs) > 0 {
		self := jstr(must(s, `{"op":"identity"}`), "id")
		for i := len(msgs) - 1; i >= 0; i -= 1 {
			if a.json {
				print_json(msgs[i])
			} else {
				print_message(msgs[i], self)
			}
		}
		return 0
	}
	return report_error(.Not_Found, "no such object (or no access to it)")
}

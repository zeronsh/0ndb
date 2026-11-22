package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../capi/api"

cmd_takeover :: proc(a: ^Args) -> int {
	s := session(a)
	level := "conversation"
	target := ""
	n := 0
	for f in ([]string{"workspace", "agent", "convo"}) {
		if v, ok := flag_value(a, f); ok {
			level = "conversation" if f == "convo" else f
			target = v
			n += 1
		}
	}
	if n > 1 || len(a.pos) > 1 {
		return usage_error("usage: 0ndb takeover [default|auto|never] [--workspace W | --agent A | --convo C]")
	}
	ob := current_convo(s) if len(target) == 0 else resolve_object(s, target)
	if len(a.pos) == 1 {
		p := a.pos[0]
		if p != "default" && p != "auto" && p != "never" {
			return usage_error("takeover takes default, auto or never")
		}
		r := req_begin("takeover.set")
		req_str(&r, "object", object_str(ob))
		req_str(&r, "level", level)
		req_str(&r, "policy", p)
		must(s, req_end(&r), "cannot set the takeover policy")
	}
	r := req_begin("takeover.get")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "level", level)
	v := must(s, req_end(&r), "cannot read the takeover policy")
	if a.json {
		print_json(v)
		return 0
	}
	if jstr(v, "policy") == jstr(v, "effective") {
		fmt.printfln("%s %s: %s", level, short(object_str(ob)), jstr(v, "policy"))
	} else {
		fmt.printfln("%s %s: %s (effective %s)", level, short(object_str(ob)), jstr(v, "policy"), jstr(v, "effective"))
	}
	return 0
}

@(private)
_directory :: proc(s: ^Session, a: ^Args, convo: api.Object) -> json.Value {
	r := req_begin("runners")
	req_str(&r, "space", hex(convo.space if convo.space != {} else default_space(s)))
	if convo.id != {} {
		req_str(&r, "object", object_str(convo))
	}
	return must(s, req_end(&r), "cannot list runners")
}

cmd_runners :: proc(a: ^Args) -> int {
	s := session(a)
	ob: api.Object
	if len(a.pos) > 0 {
		ob = resolve_object(s, a.pos[0])
	} else if !flag_bool(a, "all") {
		st := must(s, `{"op":"state.get"}`)
		ob, _ = api.parse_object(jstr(st, "current"))
	}
	v := _directory(s, a, ob)
	if a.json {
		print_json(v)
		return 0
	}
	for x in jarr(v, "runners") {
		mark := "  "
		if jbool(x, "current") {
			mark = "* "
		} else if jbool(x, "last") {
			mark = "+ "
		}
		name := jstr(x, "name")
		if len(name) == 0 {
			name = "Cloud" if jstr(x, "kind") == "pool" else "-"
		}
		provs := strings.join(_strs(jarr(x, "providers")), ",", context.temp_allocator)
		signed := strings.join(_strs(jarr(x, "signed_in")), ",", context.temp_allocator)
		fmt.printfln("%s%s  %-20s %-6s %-8s providers %s  signed in %s", mark, short(jstr(x, "device")), name, jstr(x, "kind"), jstr(x, "state"), provs if len(provs) > 0 else "-", signed if len(signed) > 0 else "-")
	}
	return 0
}

@(private)
_strs :: proc(arr: json.Array) -> []string {
	out := make([]string, len(arr), context.temp_allocator)
	for x, i in arr {
		out[i], _ = x.(json.String)
	}
	return out
}

cmd_resume :: proc(a: ^Args) -> int {
	s := session(a)
	ob, rest := _convo_and_rest(s, a, 1)
	if len(rest) != 1 {
		return usage_error("usage: 0ndb resume [CONVO] RUNNER")
	}
	want := rest[0]
	match := ""
	n := 0
	for x in jarr(_directory(s, a, ob), "runners") {
		id := jstr(x, "device")
		name := jstr(x, "name")
		pool := jstr(x, "kind") == "pool"
		if id_matches(id, want) || (len(name) > 0 && strings.equal_fold(name, want)) || (pool && (strings.equal_fold(want, "cloud") || strings.equal_fold(want, "pool"))) {
			if id != match {
				n += 1
			}
			match = id
		}
	}
	if n == 0 {
		return report_error(.Not_Found, "no runner matches %q (0ndb runners lists them)", want)
	}
	if n > 1 {
		return usage_error("%q matches %d runners; use more characters", want, n)
	}
	r := req_begin("assign")
	req_str(&r, "object", object_str(ob))
	req_str(&r, "runner", match)
	v := must(s, req_end(&r), "cannot resume")
	if a.json {
		print_json(v)
		return 0
	}
	fmt.printfln("resumed on %s", short(match))
	return 0
}

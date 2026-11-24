package rt

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "../agent"
import eng "../engine"
import "../prim"

Driver_Kind :: enum u8 {
	Harness,
	Native,
}

Builtin :: enum u8 {
	Files,
	Shell,
	Orchestration,
	Memory,
	Schedule,
	History,
}

Builtins :: bit_set[Builtin;u8]

ALL_BUILTINS :: Builtins{.Files, .Shell, .Orchestration, .Memory, .Schedule, .History}

Mcp_Spec :: struct {
	name:    string,
	argv:    []string,
	env:     []string,
	cwd:     string,
	url:     string,
	headers: []string,
	allow:   []string,
}

Budget :: struct {
	tokens:  u64,
	usd:     f64,
	turns:   int,
	seconds: i64,
}

Agent_Info :: struct {
	object:          Object,
	name:            string,
	instructions:    string,
	kind:            Driver_Kind,
	provider:        string,
	model:           string,
	effort:          string,
	access:          agent.Access,
	ask_permissions: bool,
	observe:         bool,
	keepalive:       bool,
	keep_margin_ms:  i64,
	keep_window_ms:  i64,
	warm:            bool,
	catalog:         bool,
	compact_at:      f64,
	budget:          Budget,
	builtins:        Builtins,
	mcp:             []Mcp_Spec,
	memory:          []prim.Id,
	workspace:       prim.Id,
	policy:          []u8,
	takeover:        eng.Takeover,
	triggers:        [][]u8,
	setup:           string,
	linked:          []string,
	isolate:         Isolate,
}

agent_resolve :: proc(r: ^Runtime, o: Object, provider := "", model_id := "", allocator := context.allocator) -> (a: Agent_Info, ok: bool) {
	context = eng.context_for(r.e)
	settings, serr := eng.convo_settings(r.e, o, context.temp_allocator)
	if serr != .None && serr != .Pending {
		return a, false
	}
	def: eng.Agent_Def
	has_def := false
	ws: eng.Workspace_Def
	has_ws := false
	if !prim.id_is_zero(settings.workspace) {
		if w, werr := eng.workspace_get(r.e, Object{o.space, settings.workspace}, context.temp_allocator); werr == .None {
			ws = w
			has_ws = true
		}
	}
	agent_id := settings.agent
	if prim.id_is_zero(agent_id) && has_ws {
		agent_id = ws.agent
	}
	if !prim.id_is_zero(agent_id) {
		if d, derr := eng.agent_get(r.e, Object{o.space, agent_id}, context.temp_allocator); derr == .None {
			def = d
			has_def = true
			a.object = Object{o.space, agent_id}
		}
	}
	if !has_ws && has_def && !prim.id_is_zero(def.workspace) {
		if w, werr := eng.workspace_get(r.e, Object{o.space, def.workspace}, context.temp_allocator); werr == .None {
			ws = w
			has_ws = true
		}
	}
	pick :: proc(list: ..string) -> string {
		for s in list {
			if len(s) > 0 {
				return s
			}
		}
		return ""
	}
	prov := pick(provider, settings.provider, def.provider, ws.provider if has_ws else "", r.cfg.default_provider)
	mdl := pick(model_id, settings.model, def.model, ws.model if has_ws else "", r.cfg.default_model)
	a.takeover = def.takeover if has_def && def.takeover != .Default else (ws.takeover if has_ws else .Default)
	if c, found, cerr := eng.catalog_get(r.e, o, context.temp_allocator); cerr == .None && found && c.takeover != 0 && c.takeover <= u8(max(eng.Takeover)) {
		a.takeover = eng.Takeover(c.takeover)
	}
	if len(prov) == 0 && !has_def {
		return a, false
	}
	a.name = clone(def.name, allocator)
	a.instructions = clone(def.instructions, allocator)
	a.provider = clone(prov, allocator)
	a.model = clone(mdl, allocator)
	a.access = .Full
	a.observe = true
	a.warm = true
	a.catalog = r.cfg.mcp_http
	a.workspace = settings.workspace if !prim.id_is_zero(settings.workspace) else def.workspace
	a.policy = clone_bytes(def.runner_policy if len(def.runner_policy) > 0 else (ws.runner_policy if has_ws else nil), allocator)
	if has_ws {
		a.setup = clone(ws.setup, allocator)
		a.linked = _clone_list(ws.linked, allocator)
	}
	switch def.driver {
	case "native", "model":
		a.kind = .Native
	case "harness", "":
		_, known := _descriptor(r, prov)
		a.kind = .Harness if known else .Native
	case:
		_, known := _descriptor(r, def.driver)
		if known {
			a.kind = .Harness
			if len(provider) == 0 && len(settings.provider) == 0 {
				delete(a.provider, allocator)
				a.provider = clone(def.driver, allocator)
			}
		} else {
			a.kind = .Native
		}
	}
	if opts, pok := json_parse(string(def.options)); pok && len(def.options) > 0 {
		switch jstr(opts, "access") {
		case "plan":
			a.access = .Plan
		case "edit":
			a.access = .Edit
		case "full":
			a.access = .Full
		}
		a.ask_permissions = jbool(opts, "ask_permissions")
		a.observe = jbool(opts, "observe", true)
		a.keepalive = jbool(opts, "keepalive")
		a.keep_margin_ms = jint(opts, "keepalive_margin_ms")
		a.keep_window_ms = jint(opts, "keepalive_window_ms")
		a.warm = jbool(opts, "warm", true)
		a.catalog = jbool(opts, "catalog", a.catalog)
		a.effort = clone(jstr(opts, "effort"), allocator)
		a.compact_at = jf64(opts, "compact_at")
		if jhas(opts, "isolate") {
			a.isolate = .Yes if jbool(opts, "isolate") else .No
		}
	}
	a.budget = budget_parse(def.budget)
	mcps := make([dynamic]Mcp_Spec, allocator)
	listed := false
	for t in def.tools {
		v, pok := json_parse(string(t))
		if !pok {
			continue
		}
		if b := jstr(v, "builtin"); len(b) > 0 {
			listed = true
			switch b {
			case "files":
				a.builtins += {.Files}
			case "shell":
				a.builtins += {.Shell}
			case "orchestration":
				a.builtins += {.Orchestration}
				a.catalog = true
			case "memory":
				a.builtins += {.Memory}
			case "schedule":
				a.builtins += {.Schedule}
			case "history":
				a.builtins += {.History}
			case "all":
				a.builtins = ALL_BUILTINS
				a.catalog = true
			}
			continue
		}
		if name := jstr(v, "mcp"); len(name) > 0 {
			spec := Mcp_Spec {
				name = clone(name, allocator),
				url  = clone(jstr(v, "url"), allocator),
				cwd  = clone(jstr(v, "cwd"), allocator),
			}
			spec.argv = _clone_list(jstrs(v, "command"), allocator)
			spec.env = _clone_list(jstrs(v, "env"), allocator)
			spec.allow = _clone_list(jstrs(v, "allow"), allocator)
			hdrs := make([dynamic]string, allocator)
			if ho, hok := jget(v, "headers").(json.Object); hok {
				keys := make([dynamic]string, 0, len(ho), context.temp_allocator)
				for k in ho {
					append(&keys, k)
				}
				_sort_strings(keys[:])
				for k in keys {
					if s, sok := ho[k].(json.String); sok {
						append(&hdrs, clone(k, allocator), clone(s, allocator))
					}
				}
			}
			spec.headers = hdrs[:]
			if len(spec.argv) > 0 || len(spec.url) > 0 {
				append(&mcps, spec)
			}
		}
	}
	if !listed && a.kind == .Native {
		a.builtins = ALL_BUILTINS
	}
	a.mcp = mcps[:]
	mem := make([dynamic]prim.Id, allocator)
	append(&mem, ..def.memory)
	if has_ws {
		for m in ws.members {
			if m.role == .Memory {
				append(&mem, m.object)
			}
		}
	}
	a.memory = mem[:]
	trig := make([dynamic][]u8, allocator)
	for t in def.triggers {
		append(&trig, clone_bytes(t, allocator))
	}
	a.triggers = trig[:]
	return a, true
}

budget_parse :: proc(b: []u8) -> (out: Budget) {
	if len(b) == 0 {
		return
	}
	v, ok := json_parse(string(b))
	if !ok {
		return
	}
	out.tokens = u64(max(jint(v, "tokens"), 0))
	out.usd = jf64(v, "usd")
	out.turns = int(max(jint(v, "turns"), 0))
	out.seconds = max(jint(v, "seconds"), 0)
	return
}

budget_encode :: proc(b: Budget, allocator := context.temp_allocator) -> []u8 {
	if b == {} {
		return nil
	}
	w := make(Buf, allocator)
	append(&w, '{')
	if b.tokens > 0 {
		jw_kint(&w, "tokens", i64(b.tokens))
	}
	if b.usd > 0 {
		jw_kf64(&w, "usd", b.usd)
	}
	if b.turns > 0 {
		jw_kint(&w, "turns", i64(b.turns))
	}
	if b.seconds > 0 {
		jw_kint(&w, "seconds", b.seconds)
	}
	append(&w, '}')
	return w[:]
}

budget_min :: proc(a, b: Budget) -> Budget {
	pick_u :: proc(x, y: u64) -> u64 {
		if x == 0 {
			return y
		}
		if y == 0 {
			return x
		}
		return min(x, y)
	}
	pick_f :: proc(x, y: f64) -> f64 {
		if x == 0 {
			return y
		}
		if y == 0 {
			return x
		}
		return min(x, y)
	}
	return Budget{tokens = pick_u(a.tokens, b.tokens), usd = pick_f(a.usd, b.usd), turns = int(pick_u(u64(a.turns), u64(b.turns))), seconds = i64(pick_u(u64(a.seconds), u64(b.seconds)))}
}

@(private)
_clone_list :: proc(list: []string, allocator: runtime.Allocator) -> []string {
	if len(list) == 0 {
		return nil
	}
	out := make([]string, len(list), allocator)
	for s, i in list {
		out[i] = clone(s, allocator)
	}
	return out
}

@(private)
_descriptor :: proc(r: ^Runtime, id: string) -> (agent.Provider_Descriptor, bool) {
	if len(id) == 0 {
		return {}, false
	}
	if r.cfg.providers.lookup != nil {
		if d, ok := r.cfg.providers.lookup(r.cfg.providers.data, id); ok {
			return d, true
		}
	}
	return agent.lookup(&r.registry, id)
}

@(private)
_model_name_ok :: proc(s: string) -> bool {
	return len(s) > 0 && !strings.contains_any(s, " \t\n")
}

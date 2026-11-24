package rt

import "../agent"
import "core:strings"
import "../convo"
import eng "../engine"
import "../obj"
import "../prim"

Takeover :: eng.Takeover

@(private)
ASKS_MAX :: 256

@(private)
Ask :: struct {
	token:    u64,
	kind:     Placement_Kind,
	object:   Object,
	msg:      Rid,
	sender:   prim.Id,
	exclude:  prim.Id,
	provider: string,
	answered: bool,
	decided:  bool,
	runner:   prim.Id,
}

Runner_Kind :: enum u8 {
	Device,
	Pool,
}

Runner_State :: enum u8 {
	Offline,
	Online,
	Wakeable,
}

Runner_Entry :: struct {
	device:    prim.Id,
	name:      string,
	kind:      Runner_Kind,
	state:     Runner_State,
	providers: string,
	signed_in: string,
	current:   bool,
	last:      bool,
}

place_decided :: proc(r: ^Runtime, p: ^Placement) -> (runner: prim.Id, decided: bool) {
	s := r.cfg.scheduler
	if s.ask == nil {
		return s.place(s.data, r, p), true
	}
	for &a in r.asks {
		if a.kind == p.kind && a.object == p.object && a.msg == p.msg && a.sender == p.sender && a.exclude == p.exclude && a.provider == p.provider {
			if !a.answered {
				return {}, false
			}
			if !a.decided {
				return _default_place(nil, r, p), true
			}
			return a.runner, true
		}
	}
	if len(r.asks) >= ASKS_MAX {
		return _default_place(nil, r, p), true
	}
	r.next_token += 1
	token := r.next_token
	append(&r.asks, Ask{token = token, kind = p.kind, object = p.object, msg = p.msg, sender = p.sender, exclude = p.exclude, provider = clone(p.provider, r.allocator)})
	s.ask(s.data, r, p, token)
	for &a in r.asks {
		if a.token == token && a.answered {
			if !a.decided {
				return _default_place(nil, r, p), true
			}
			return a.runner, true
		}
	}
	return {}, false
}

placed :: proc(r: ^Runtime, token: u64, runner: prim.Id, decided: bool) {
	context = eng.context_for(r.e)
	for &a in r.asks {
		if a.token != token || a.answered {
			continue
		}
		a.answered = true
		a.decided = decided
		a.runner = runner
		if a.kind == .Schedule {
			_sched_rearm(r)
		} else {
			_queue_eval(r, a.object)
		}
		return
	}
}

@(private)
_ask_free :: proc(r: ^Runtime, i: int) {
	delete(r.asks[i].provider, r.allocator)
	unordered_remove(&r.asks, i)
}

@(private)
_asks_drop :: proc(r: ^Runtime, o: Object) {
	i := 0
	for i < len(r.asks) {
		if r.asks[i].answered && r.asks[i].object == o {
			_ask_free(r, i)
			continue
		}
		i += 1
	}
}

@(private)
_asks_forget :: proc(r: ^Runtime, space: prim.Id) {
	i := 0
	for i < len(r.asks) {
		if r.asks[i].answered && r.asks[i].object.space == space {
			_ask_free(r, i)
			continue
		}
		i += 1
	}
}

@(private)
_asks_close :: proc(r: ^Runtime) {
	for a in r.asks {
		if !a.answered && r.cfg.scheduler.cancel != nil {
			r.cfg.scheduler.cancel(r.cfg.scheduler.data, r, a.token)
		}
		delete(a.provider, r.allocator)
	}
	delete(r.asks)
}

runner_pool_id :: proc(r: ^Runtime, space: prim.Id, device: prim.Id) -> (pool: prim.Id, ok: bool) {
	d := device
	en, found := map_read(r, runners_object(space), d[:])
	if !found || entry_u64(&en, 3) == 0 {
		return {}, false
	}
	return entry_id(&en, 6), true
}

takeover_moves :: proc(r: ^Runtime, space: prim.Id, policy: Takeover, from: prim.Id, to: prim.Id) -> bool {
	if prim.id_is_zero(from) || prim.id_is_zero(to) || from == to {
		return true
	}
	switch policy {
	case .Auto:
		return true
	case .Never:
		return false
	case .Default:
		a, aok := runner_pool_id(r, space, from)
		b, bok := runner_pool_id(r, space, to)
		return aok && bok && a == b
	}
	return false
}

last_runner :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail, from: Rid, concrete := false) -> prim.Id {
	if id := _last_in(r, o, v, t, from, concrete); !prim.id_is_zero(id) {
		return id
	}
	cur := o
	for _ in 0 ..< 4 {
		c, found, cerr := eng.catalog_get(r.e, cur, context.temp_allocator)
		if cerr != .None || !found || prim.id_is_zero(c.parent.object) {
			break
		}
		cur = Object{o.space, c.parent.object}
		pv, perr := eng.convo_view(r.e, cur)
		if perr != .None {
			break
		}
		pt, pterr := convo.view_tail(pv, r.self, context.temp_allocator)
		if pterr != .None {
			break
		}
		if id := _last_in(r, cur, pv, &pt, c.parent.rid, concrete); !prim.id_is_zero(id) {
			return id
		}
	}
	return {}
}

@(private)
_last_in :: proc(r: ^Runtime, o: Object, v: ^obj.View, t: ^convo.Tail, from: Rid, concrete: bool) -> prim.Id {
	cur := from
	if obj.rid_none(cur) {
		cur, _ = convo.tail_head(v, t)
	}
	for _ in 0 ..< 64 {
		if obj.rid_none(cur) {
			break
		}
		m, merr := convo.message(v, t, convo.Position{msg = cur}, context.temp_allocator)
		if merr != .None {
			break
		}
		if as, aerr := convo.assignee(v, t, cur); aerr == .None && !prim.id_is_zero(as) && (!concrete || !is_pool_id(r, o.space, as)) {
			return as
		}
		if !prim.id_is_zero(m.runner) {
			return m.runner
		}
		cur = m.parent
	}
	return {}
}

is_pool_id :: proc(r: ^Runtime, space: prim.Id, id: prim.Id) -> bool {
	if prim.id_is_zero(id) {
		return false
	}
	for &row in map_rows(r, runners_object(space), nil) {
		if len(row.key) == 16 && entry_u64(&row.entry, 3) != 0 && entry_id(&row.entry, 6) == id {
			return true
		}
	}
	return false
}

runner_of :: proc(r: ^Runtime, o: Object) -> (current: prim.Id, last: prim.Id, ok: bool) {
	context = eng.context_for(r.e)
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return {}, {}, false
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return {}, {}, false
	}
	if t.running {
		if x, live := _open_live(r, o, v, &t); live {
			current = x
		}
	}
	return current, last_runner(r, o, v, &t, {}), true
}

@(private)
_placement_idle :: proc(r: ^Runtime, o: Object, msg: Rid, provider: string, last: prim.Id) {
	if _pending_put(r, o, Pending_Entry{msg = msg, provider = provider, since_ms = wall_ms(r), runner = last, idle = true}) {
		_placement_hook(r, o, Placement_Info{state = .Idle, msg = msg, provider = provider, last_runner = last, since_ms = wall_ms(r)})
	}
}

@(private)
_runners_changed :: proc(r: ^Runtime, space: prim.Id) {
	if r.cfg.hooks.runners != nil {
		r.cfg.hooks.runners(r.cfg.hooks.data, r, space)
	}
}

@(private)
_pool_of :: proc(r: ^Runtime, space: prim.Id) -> prim.Id {
	if !r.cfg.pool {
		return {}
	}
	list, err := eng.space_members(r.e, space, context.temp_allocator)
	if err != .None {
		return {}
	}
	for m in list {
		if m.device == r.self {
			return m.added_by
		}
	}
	return {}
}

@(private)
_env_set :: proc(r: ^Runtime, name: string) -> bool {
	for kv in r.cfg.env {
		if len(kv) > len(name) && kv[len(name)] == '=' && kv[:len(name)] == name {
			return len(kv) > len(name) + 1
		}
	}
	v, ok := prim.getenv(strings.clone_to_cstring(name, context.temp_allocator))
	return ok && len(v) > 0
}

@(private)
_providers_signed_in :: proc(r: ^Runtime, installed: string) -> string {
	out := make([dynamic]string, context.temp_allocator)
	rest := installed
	for len(rest) > 0 {
		n := strings.index_byte(rest, '\n')
		id := rest if n < 0 else rest[:n]
		rest = "" if n < 0 else rest[n + 1:]
		if id == PROVIDER_NATIVE {
			if r.cfg.model.resolve != nil || _env_set(r, "ANTHROPIC_API_KEY") || _env_set(r, "OPENAI_API_KEY") {
				append(&out, id)
			} else if _, ok := _secret(r, "ANTHROPIC_API_KEY"); ok {
				append(&out, id)
			}
			continue
		}
		if d, ok := _descriptor(r, id); ok && _descriptor_signed_in(r, d) && !_auth_marked(r, d) {
			append(&out, id)
		}
	}
	return strings.join(out[:], "\n", context.temp_allocator)
}

@(private)
_descriptor_signed_in :: proc(r: ^Runtime, d: agent.Provider_Descriptor) -> bool {
	vfs := prim.os_vfs()
	signed := len(d.auth_env) == 0 && len(d.auth_files) == 0
	for e in d.auth_env {
		signed ||= _env_set(r, e)
	}
	for f in d.auth_files {
		if signed || len(r.cfg.home_dir) == 0 {
			break
		}
		path := concat(r.cfg.home_dir, "/", f.path)
		if len(f.contains) == 0 {
			signed = prim.exists(vfs, path)
			continue
		}
		data, rerr := prim.read_file(vfs, path, context.temp_allocator)
		signed = rerr == .None && strings.contains(string(data), f.contains)
	}
	return signed
}

provider_signed_in :: proc(r: ^Runtime, id: string) -> bool {
	if id == PROVIDER_NATIVE {
		return strings.contains(_providers_signed_in(r, id), id)
	}
	d, ok := _descriptor(r, id)
	return ok && _descriptor_signed_in(r, d) && !_auth_marked(r, d)
}

@(private)
_auth_signature :: proc(r: ^Runtime, d: agent.Provider_Descriptor) -> string {
	b := strings.builder_make(context.temp_allocator)
	for f in d.auth_files {
		if len(r.cfg.home_dir) == 0 {
			break
		}
		st, err := prim.stat(prim.os_vfs(), concat(r.cfg.home_dir, "/", f.path))
		strings.write_string(&b, f.path)
		if err == .None {
			strings.write_byte(&b, ':')
			strings.write_i64(&b, st.mtime_ns)
			strings.write_byte(&b, ':')
			strings.write_i64(&b, st.size)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private)
_auth_marked :: proc(r: ^Runtime, d: agent.Provider_Descriptor) -> bool {
	sig, marked := r.auth_marks[d.id]
	if !marked {
		return false
	}
	if sig == _auth_signature(r, d) {
		return true
	}
	provider_auth_ok(r, d.id)
	return false
}

provider_auth_failed :: proc(r: ^Runtime, id: string) {
	d, ok := _descriptor(r, id)
	if !ok {
		return
	}
	if r.auth_marks == nil {
		r.auth_marks = make(map[string]string, r.allocator)
	}
	sig := strings.clone(_auth_signature(r, d), r.allocator)
	if old, had := &r.auth_marks[id]; had {
		delete(old^, r.allocator)
		old^ = sig
	} else {
		r.auth_marks[strings.clone(id, r.allocator)] = sig
	}
	readvertise_all(r)
}

provider_auth_ok :: proc(r: ^Runtime, id: string) {
	if id not_in r.auth_marks {
		return
	}
	k, v := delete_key(&r.auth_marks, id)
	delete(k, r.allocator)
	delete(v, r.allocator)
	readvertise_all(r)
}

runner_directory :: proc(r: ^Runtime, space: prim.Id, o: Object = {}, allocator := context.allocator) -> []Runner_Entry {
	context = eng.context_for(r.e)
	current, last: prim.Id
	if !prim.id_is_zero(o.id) {
		current, last, _ = runner_of(r, o)
	}
	out := make([dynamic]Runner_Entry, allocator)
	pools := make([dynamic]prim.Id, context.temp_allocator)
	merge :: proc(dst: ^[dynamic]string, list: string) {
		rest := list
		for len(rest) > 0 {
			n := strings.index_byte(rest, '\n')
			x := rest if n < 0 else rest[:n]
			rest = "" if n < 0 else rest[n + 1:]
			seen := false
			for y in dst {
				seen ||= y == x
			}
			if !seen && len(x) > 0 {
				append(dst, x)
			}
		}
	}
	for &row in map_rows(r, runners_object(space), nil) {
		if len(row.key) != 16 {
			continue
		}
		id: prim.Id
		copy(id[:], row.key)
		en := &row.entry
		if entry_u64(en, 3) == 0 {
			append(&out, Runner_Entry {
				device    = id,
				name      = clone(entry_str(en, 5), allocator),
				kind      = .Device,
				state     = .Online if runner_live(r, space, id, "") else .Offline,
				providers = clone(entry_str(en, 2), allocator),
				signed_in = clone(entry_str(en, 4), allocator),
				current   = !prim.id_is_zero(current) && id == current,
				last      = !prim.id_is_zero(last) && id == last,
			})
			continue
		}
		pool := entry_id(en, 6)
		known := false
		for p in pools {
			known ||= p == pool
		}
		if !known {
			append(&pools, pool)
		}
	}
	members, _ := eng.space_members(r.e, space, context.temp_allocator)
	for pool in pools {
		provs := make([dynamic]string, context.temp_allocator)
		signed := make([dynamic]string, context.temp_allocator)
		online, cur, lst := false, false, false
		for &row in map_rows(r, runners_object(space), nil) {
			if len(row.key) != 16 || entry_u64(&row.entry, 3) == 0 || entry_id(&row.entry, 6) != pool {
				continue
			}
			id: prim.Id
			copy(id[:], row.key)
			merge(&provs, entry_str(&row.entry, 2))
			merge(&signed, entry_str(&row.entry, 4))
			online ||= runner_live(r, space, id, "")
			cur ||= id == current
			lst ||= id == last
		}
		active := false
		name := ""
		for m in members {
			if m.device == pool && m.kind == .Pool && !m.removed {
				active = true
				name = m.label
			}
		}
		append(&out, Runner_Entry {
			device    = pool,
			name      = clone(name, allocator),
			kind      = .Pool,
			state     = .Online if online else (.Wakeable if active else .Offline),
			providers = strings.join(provs[:], "\n", allocator),
			signed_in = strings.join(signed[:], "\n", allocator),
			current   = cur || (!prim.id_is_zero(current) && current == pool),
			last      = lst || (!prim.id_is_zero(last) && last == pool),
		})
	}
	return out[:]
}

resume :: proc(r: ^Runtime, o: Object, runner: prim.Id, msg: Rid = {}) -> Error {
	context = eng.context_for(r.e)
	if prim.id_is_zero(runner) {
		return .Invalid
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return _eerr(verr)
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return .Pending if terr == .Missing else .Engine
	}
	target := msg
	if obj.rid_none(target) {
		head, herr := convo.tail_head(v, &t)
		if herr != .None || obj.rid_none(head) {
			return .Not_Found
		}
		target = head
		if hm, merr := convo.message(v, &t, convo.Position{msg = head}, context.temp_allocator); merr == .None && hm.role != .User && hm.role != .System && hm.open && !obj.rid_none(hm.parent) {
			target = hm.parent
		}
	}
	w := _convo_w(r, o)
	if w == nil {
		return .Engine
	}
	if _, aerr := convo.writer_assign(w, target, runner); aerr != .None {
		return .Not_Found if aerr == .Not_Found else .Engine
	}
	eng.touched(r.e, o)
	_sched_reown(r, o, runner)
	_queue_eval(r, o)
	return .None
}

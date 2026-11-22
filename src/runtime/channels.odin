package rt

import "core:strings"
import "../convo"
import eng "../engine"
import omap "../map"
import "../prim"

@(private)
KEY_ROUTE :: "route"

Channel_Message :: struct {
	channel:     string,
	key:         string,
	text:        string,
	sender:      string,
	title:       string,
	agent:       prim.Id,
	workspace:   prim.Id,
	attachments: []convo.Attachment,
}

channel_deliver :: proc(r: ^Runtime, space: prim.Id, m: Channel_Message) -> (o: Object, err: Error) {
	context = eng.context_for(r.e)
	routes := named_w(r, routes_named(space))
	k := key_of("k/", transmute([]u8)m.channel, []u8{0}, transmute([]u8)m.key)
	if en, ok := map_read(r, routes, k); ok {
		o = Object{space, entry_id(&en, 1)}
	}
	if prim.id_is_zero(o.id) {
		title := m.title
		if len(title) == 0 {
			title = concat(m.channel, ": ", m.key)
		}
		c, cerr := eng.convo_create(r.e, space, eng.Convo_Settings{title = title, agent = m.agent, workspace = m.workspace})
		if cerr != .None {
			return {}, .Engine
		}
		o = c
		map_put(r, routes, k, omap.field_id(1, o.id))
		id := o.id
		map_put(r, routes, key_of("c/", id[:]), omap.field_str(1, m.channel), omap.field_str(2, m.key))
	}
	text := m.text
	if len(m.sender) > 0 {
		text = concat(m.sender, ": ", m.text)
	}
	_, qerr := eng.convo_queue(r.e, o, text, m.attachments)
	if qerr != .None && qerr != .Pending {
		return o, .Engine
	}
	return o, .None
}

channel_route :: proc(r: ^Runtime, o: Object) -> (channel: string, key: string, ok: bool) {
	id := o.id
	en, found := map_read(r, routes_object(o.space), key_of("c/", id[:]))
	if !found {
		return "", "", false
	}
	return entry_str(&en, 1), entry_str(&en, 2), true
}

channel_reply :: proc(r: ^Runtime, o: Object, reply: Rid, status: convo.Seal_Status) {
	if r.cfg.channels.send == nil || status == .Cancelled {
		return
	}
	channel, key, ok := channel_route(r, o)
	if !ok {
		return
	}
	v, verr := eng.convo_view(r.e, o)
	if verr != .None {
		return
	}
	t, terr := convo.view_tail(v, r.self, context.temp_allocator)
	if terr != .None {
		return
	}
	m, merr := convo.message(v, &t, convo.Position{msg = reply}, context.temp_allocator)
	if merr != .None {
		return
	}
	b := make(Buf, context.temp_allocator)
	for blk in m.blocks {
		if blk.kind == .Text {
			if len(b) > 0 {
				append(&b, "\n\n")
			}
			append(&b, ..blk.text)
		}
	}
	text := strings.trim_space(string(b[:]))
	if len(text) == 0 {
		return
	}
	r.cfg.channels.send(r.cfg.channels.data, r, channel, key, o, text)
}

event_deliver :: proc(r: ^Runtime, space: prim.Id, agent_id: prim.Id, name: string, payload: string) -> Error {
	context = eng.context_for(r.e)
	a := Object{space, agent_id}
	def, err := eng.agent_get(r.e, a, context.temp_allocator)
	if err != .None {
		return .Not_Found
	}
	for t in def.triggers {
		v, ok := json_parse(string(t))
		if !ok || jstr(v, "event") != name {
			continue
		}
		_trigger_fire(r, a, v, payload)
	}
	return .None
}

_trigger_touched :: proc(r: ^Runtime, o: Object) {
	if !r.cfg.runner || !r.triggers {
		return
	}
	oid16 := rid_bytes(Rid{o.id, 0, 0})[:16]
	en, ok := map_read(r, state_object(r, o.space), key_of("trig/", oid16))
	if !ok {
		return
	}
	c, cfound, cerr := eng.catalog_get(r.e, o, context.temp_allocator)
	if cerr != .None || !cfound {
		return
	}
	fk := key_of("tf/", oid16)
	if fe, ffound := map_read(r, state_object(r, o.space), fk); ffound && entry_u64(&fe, 1) >= c.activity {
		return
	}
	map_put(r, state_w(r, o.space), fk, omap.field_u64(1, c.activity))
	for reg in en.registers {
		if len(reg.value) != 16 {
			continue
		}
		agent_id: prim.Id
		copy(agent_id[:], reg.value)
		a := Object{o.space, agent_id}
		def, derr := eng.agent_get(r.e, a, context.temp_allocator)
		if derr != .None {
			continue
		}
		oid := hex(o.id)
		for t in def.triggers {
			v, vok := json_parse(string(t))
			if !vok || jstr(v, "object") != oid {
				continue
			}
			_trigger_fire(r, a, v, concat("object ", oid, " changed"))
		}
	}
}

trigger_watch :: proc(r: ^Runtime, agent_obj: Object) -> Error {
	context = eng.context_for(r.e)
	def, err := eng.agent_get(r.e, agent_obj, context.temp_allocator)
	if err != .None {
		return .Not_Found
	}
	aid := agent_obj.id
	for t in def.triggers {
		v, ok := json_parse(string(t))
		if !ok {
			continue
		}
		if s := jstr(v, "object"); len(s) > 0 {
			if oid, iok := prim.id_parse(s); iok {
				tag := u32(prim.get_u64le(aid[:8]) & 0x7fff_ffff) | 1
				map_put(r, state_w(r, agent_obj.space), key_of("trig/", oid[:]), omap.Field{tag = tag, value = aid[:]})
				r.triggers = true
			}
		}
		if s := jstr(v, "cron"); len(s) > 0 {
			target := agent_obj
			if c := jstr(v, "conversation"); len(c) > 0 {
				if cid, iok := prim.id_parse(c); iok {
					target = Object{agent_obj.space, cid}
				}
			}
			id := jstr(v, "id")
			if len(id) == 0 {
				id = concat("trigger-", s)
			}
			if _, exists := schedule_get(r, agent_obj, id); !exists && target != agent_obj {
				schedule_create(r, agent_obj, id, jstr(v, "prompt"), s, 0, jstr(v, "timezone"), target)
			}
		}
	}
	return .None
}

@(private)
_trigger_fire :: proc(r: ^Runtime, a: Object, v: Json_Value, payload: string) {
	prompt := jstr(v, "prompt")
	if len(prompt) == 0 {
		prompt = payload
	} else if len(payload) > 0 {
		prompt = concat(prompt, "\n\n", payload)
	}
	if c := jstr(v, "conversation"); len(c) > 0 {
		if cid, ok := prim.id_parse(c); ok {
			eng.convo_queue(r.e, Object{a.space, cid}, prompt)
			return
		}
	}
	title, _ := utf8_clip(prompt, 80)
	child, err := eng.convo_create(r.e, a.space, eng.Convo_Settings{title = title, agent = a.id})
	if err == .None {
		eng.convo_send(r.e, child, prompt)
	}
}

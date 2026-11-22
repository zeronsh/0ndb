package sim

import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

Promo_Rec :: struct {
	obj:       int,
	node:      int,
	uncertain: bool,
}

storage_mode_of :: proc(s: string) -> (m: eng.Storage_Mode, ok: bool) {
	switch s {
	case "auto":
		return .Auto, true
	case "stored":
		return .Stored, true
	case "until-run", "until_run":
		return .Device_Until_Run, true
	case "device":
		return .Device, true
	}
	return
}

op_promote :: proc(w: ^World, n: ^Node) {
	m := &w.model
	cands := make([dynamic]int, context.temp_allocator)
	for &ob, oi in m.objs {
		if ob.kind != .Map && obj_exists(m, oi) && obj_reader(m, oi, n.idx) {
			si := space_index(m, ob.o.space)
			if si >= 0 && space_member(&m.spaces[si], n.idx) {
				append(&cands, oi)
			}
		}
	}
	if len(cands) == 0 {
		return
	}
	oi := cands[rng_int(&w.rng, len(cands))]
	context = instance_context(&n.inst)
	err := eng.object_promote(&n.e, m.objs[oi].o)
	world_note(w, "%s promote %v %s -> %v", n.name, m.objs[oi].kind, id_short(m.objs[oi].o.id), err)
	if err == .None || err == .Io || err == .No_Space {
		append(&w.promos, Promo_Rec{obj = oi, node = n.idx, uncertain = err != .None})
	}
}

@(private = "file")
_promoted :: proc(w: ^World, oi: int) -> bool {
	for p in w.promos {
		if p.obj == oi {
			return true
		}
	}
	return false
}

check_relay_storage :: proc(w: ^World) {
	m := &w.model
	for n in w.nodes {
		if n.alive && n.e_open && len(n.e.unavailable) > 0 {
			for id, holders in n.e.unavailable {
				world_fail(w, "availability: %s still reports %s unavailable after quiesce with every holder online (%d holders)", n.name, id_short(id), len(holders))
			}
		}
	}
	if !w.relay.alive || (w.cfg.storage != .Device && w.cfg.storage != .Device_Until_Run) {
		return
	}
	hollow_bytes, stored_bytes: i64
	for _, oi in m.objs {
		if !obj_exists(m, oi) || m.objs[oi].kind == .Map {
			continue
		}
		ob := &m.objs[oi]
		keyer := -1
		for idx in readers_of(w, oi) {
			n := w.nodes[idx]
			si := space_index(m, ob.o.space)
			if n.alive && n.e_open && si >= 0 && space_member(&m.spaces[si], idx) {
				keyer = idx
				break
			}
		}
		if keyer < 0 {
			continue
		}
		kn := w.nodes[keyer]
		scope: osync.Scope
		{
			context = instance_context(&kn.inst)
			key, kerr := eng.object_key(&kn.e, ob.o)
			info, _ := eng.space_info(&kn.e, ob.o.space)
			node_after(kn)
			if kerr != .None {
				continue
			}
			scope = osync.scope_make(key, info.mode)
		}
		name := make([]u8, 1 + prim.ID_HEX_LEN, context.temp_allocator)
		name[0] = _storage_prefix(ob.kind)
		hx := prim.id_hex(ob.o.id)
		copy(name[1:], hx[:])
		promoted := _promoted(w, oi)
		for n in w.nodes {
			sid := osync.stream_id(&scope, n.identity.id, string(name), 0)
			length, base, exists := relay_probe(w, ob.o.space, sid)
			if !exists || length == 0 {
				continue
			}
			hollow_bytes += base
			stored_bytes += length - base
			if !promoted && base != length && !trimmed_at(w, ob.o.space, sid) {
				world_fail(w, "relay storage: device-only %v %s segment of %s holds %d content bytes on the relay (base %d, length %d)", ob.kind, id_short(ob.o.id), n.name, length - base, base, length)
			}
		}
		for p in w.promos {
			if p.obj != oi || p.uncertain {
				continue
			}
			pn := w.nodes[p.node]
			sid := osync.stream_id(&scope, pn.identity.id, string(name), 0)
			length, base, exists := relay_probe(w, ob.o.space, sid)
			_, _, trimmed, _ := relay_stream_state(w, ob.o.space, sid)
			if exists && length > 0 && base != 0 && !trimmed {
				world_fail(w, "relay storage: promoted %v %s segment of promoter %s is stored only from %d of %d", ob.kind, id_short(ob.o.id), pn.name, base, length)
			}
		}
	}
	world_note(w, "relay storage: %d bytes of device-only segment lengths, %d content bytes stored", hollow_bytes, stored_bytes)
}

@(private = "file")
_storage_prefix :: proc(k: M_Kind) -> u8 {
	switch k {
	case .Convo:
		return 'c'
	case .Map:
		return 'm'
	case .Text:
		return 't'
	case .Tree:
		return 'f'
	}
	return 'm'
}

relay_probe :: proc(w: ^World, space: prim.Id, id: osync.Stream_Id) -> (length, base: i64, exists: bool) {
	rn := &w.relay
	if !rn.alive {
		return
	}
	context = instance_context(&rn.inst)
	defer relay_after(rn)
	r := &rn.r
	st := r.store
	ns: rawptr
	opened := false
	if sp, ok := r.spaces[space]; ok && sp.ns != nil {
		ns = sp.ns
	} else {
		h, _, err := st.namespace_open(st.data, space)
		if err != .None {
			return
		}
		ns = h
		opened = true
	}
	defer if opened {
		st.namespace_close(st.data, ns)
	}
	l, b, ex, err := st.stream_probe(st.data, ns, id)
	if err != .None {
		return
	}
	return l, b, ex
}

@(init)
_storage_hooks :: proc "contextless" () {
	register_final_check(100, check_relay_storage)
}

trimmed_at :: proc(w: ^World, space: prim.Id, id: osync.Stream_Id) -> bool {
	_, _, trimmed, _ := relay_stream_state(w, space, id)
	return trimmed
}

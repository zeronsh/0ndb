package engine

import "../journal"
import "../prim"
import osync "../sync"

@(private)
_repl_start :: proc(e: ^Engine, sp: ^Space) -> Error {
	hx := prim.id_hex(sp.id)
	dir := _join(context.temp_allocator, e.pack_root, "sync", string(hx[:])) or_return
	cfg := osync.Replicator_Config {
		vfs          = e.vfs,
		dir          = dir,
		relay        = sp.relay,
		relay_public = sp.relay_public,
		self         = e.self,
		padding      = e.cfg.padding,
		filtered     = true,
		random       = e.cfg.random,
		kernel_tls   = e.cfg.kernel_tls,
		on_event     = _on_repl_event,
		user         = sp,
	}
	creds_ok := false
	if e.cfg.credentials.produce != nil {
		cfg.credentials, creds_ok = e.cfg.credentials.produce(e.cfg.credentials.data, sp.id)
	}
	if !creds_ok {
		if sp.keyless {
			return .Permission
		}
		sp.creds = osync.Space_Credentials{space = &sp.keys, keyring = e.keyring}
		cfg.credentials = osync.space_credentials(&sp.creds)
	}
	if e.cfg.verify_chains {
		cfg.verify = _verify
	}
	if e.cfg.transport.open != nil {
		cfg.link = osync.Client_Link{data = sp, send = _link_send, close = _link_close}
	}
	_serr(osync.replicator_init(&sp.repl, e.loop, cfg, e.allocator)) or_return
	sp.repl_on = true
	if sp.link == 0 {
		append(&e.links, sp)
		sp.link = Link(len(e.links))
	}
	if e.cfg.transport.open != nil {
		conn, err := e.cfg.transport.open(e.cfg.transport.data, e, sp.link, Peer{space = sp.id, relay = sp.relay, relay_public = sp.relay_public})
		if err != .None {
			_log(e, .Warn, "transport open failed")
			_link_schedule(e, sp)
		} else {
			sp.conn = conn
		}
	} else {
		osync.replicator_start(&sp.repl)
	}
	_card_publish(e, sp)
	_owned_follow(e, sp)
	if !sp.keyless {
		_catalog_follow(e, sp)
	} else {
		for id in _sorted_keys(sp.grants) {
			if rec, found, _ := _rec_get(e, id); found {
				_shared_follow(e, sp, id, rec.kind)
			}
		}
	}
	_pending_republish(e, sp)
	return .None
}

@(private)
_repl_stop :: proc(e: ^Engine, sp: ^Space) {
	if !sp.repl_on {
		return
	}
	if sp.conn != nil && e.cfg.transport.close != nil {
		e.cfg.transport.close(e.cfg.transport.data, sp.conn)
	}
	sp.conn = nil
	if sp.reopen != 0 {
		prim.timer_cancel(e.loop, sp.reopen)
		sp.reopen = 0
	}
	osync.replicator_stop(&sp.repl)
	osync.replicator_destroy(&sp.repl)
	sp.repl_on = false
	sp.connected = false
	sp.card_ok = false
	if int(sp.link) >= 1 && int(sp.link) <= len(e.links) {
		e.links[sp.link - 1] = nil
	}
	sp.link = 0
}

link_up :: proc(e: ^Engine, link: Link, binding: []u8 = nil) -> Error {
	sp := _link_space(e, link)
	if sp == nil {
		return .Closed
	}
	sp.backoff = 0
	err := _serr(osync.replicator_link_up(&sp.repl, binding))
	_touch(e)
	return err
}

link_input :: proc(e: ^Engine, link: Link, data: []u8) -> Error {
	sp := _link_space(e, link)
	if sp == nil {
		return .Closed
	}
	err := _serr(osync.replicator_input(&sp.repl, data))
	_touch(e)
	return err
}

link_writable :: proc(e: ^Engine, link: Link) {
	if sp := _link_space(e, link); sp != nil {
		osync.replicator_writable(&sp.repl)
		_touch(e)
	}
}

link_down :: proc(e: ^Engine, link: Link) {
	if sp := _link_space(e, link); sp != nil {
		osync.replicator_link_down(&sp.repl)
		sp.connected = false
		_touch(e)
	}
}

@(private)
LINK_BACKOFF_MIN :: 250
@(private)
LINK_BACKOFF_MAX :: 30_000

@(private)
_link_schedule :: proc(e: ^Engine, sp: ^Space) {
	if e.closing || !sp.repl_on || e.cfg.transport.open == nil || sp.reopen != 0 {
		return
	}
	base := max(sp.backoff, LINK_BACKOFF_MIN)
	sp.backoff = min(base * 2, LINK_BACKOFF_MAX)
	j: [2]u8
	random_fill(e, j[:])
	delay := base * 3 / 4 + base * i64(u16(j[0]) | u16(j[1]) << 8) / (2 * 65536)
	sp.reopen = prim.timer(e.loop, delay, sp, _link_reopen)
}

@(private)
_link_reopen :: proc(l: ^prim.Loop, data: rawptr) {
	sp := (^Space)(data)
	e := sp.e
	sp.reopen = 0
	if e.closing || !sp.repl_on || sp.conn != nil {
		return
	}
	conn, err := e.cfg.transport.open(e.cfg.transport.data, e, sp.link, Peer{space = sp.id, relay = sp.relay, relay_public = sp.relay_public})
	if err != .None {
		_link_schedule(e, sp)
		return
	}
	sp.conn = conn
}

@(private)
_link_space :: proc(e: ^Engine, link: Link) -> ^Space {
	if link == 0 || int(link) > len(e.links) {
		return nil
	}
	sp := e.links[link - 1]
	if sp == nil || !sp.repl_on {
		return nil
	}
	return sp
}

@(private)
_link_send :: proc(data: rawptr, bytes: []u8) -> (int, osync.Error) {
	sp := (^Space)(data)
	e := sp.e
	if e.cfg.transport.send == nil || sp.conn == nil {
		return 0, .Closed
	}
	n, err := e.cfg.transport.send(e.cfg.transport.data, sp.conn, bytes)
	#partial switch err {
	case .None:
		return n, .None
	case .Busy:
		return n, .Would_Block
	}
	return n, .Closed
}

@(private)
_link_close :: proc(data: rawptr) {
	sp := (^Space)(data)
	e := sp.e
	if sp.conn != nil && e.cfg.transport.close != nil {
		e.cfg.transport.close(e.cfg.transport.data, sp.conn)
	}
	sp.conn = nil
	sp.connected = false
	_link_schedule(e, sp)
}

@(private)
_object_of_name :: proc(name: string) -> (id: prim.Id, kind: Kind, ok: bool) {
	k, kok := _seg_kind(name)
	if !kok {
		return
	}
	x, pok := prim.id_parse(name[1:])
	if !pok {
		return
	}
	return x, k, true
}

@(private)
_keys_target :: proc(name: string) -> (seg: string, ok: bool) {
	if len(name) > len(osync.KEYS_STREAM) && name[:len(osync.KEYS_STREAM)] == osync.KEYS_STREAM {
		return name[len(osync.KEYS_STREAM):], true
	}
	return "", false
}

@(private)
Repl_Ev :: struct {
	kind:   osync.Repl_Event_Kind,
	err:    osync.Error,
	device: prim.Id,
	name:   string,
	epoch:  u64,
	stream: osync.Stream_Id,
	from:   i64,
	to:     i64,
	length: i64,
}

@(private)
Need_Kind :: enum u8 {
	Card,
	Keys,
}

@(private)
Need :: struct {
	kind:   Need_Kind,
	device: prim.Id,
	name:   string,
}

@(private)
_on_repl_event :: proc(user: rawptr, ev: ^osync.Repl_Event) {
	sp := (^Space)(user)
	e := sp.e
	#partial switch ev.kind {
	case .Object_Stored, .Object_Fetched, .Object_Missing, .Object_Failed:
		_content_on_event(e, sp, ev)
		return
	case .Device_Seen, .Dropped, .Object_Shredded:
		return
	}
	name, _ := _clone(ev.name, e.allocator)
	append(&sp.events, Repl_Ev{kind = ev.kind, err = ev.err, device = ev.device, name = name, epoch = ev.epoch, stream = ev.stream, from = ev.from, to = ev.to, length = ev.length})
	_touch(e)
}

@(private)
_repl_events_process :: proc(e: ^Engine) {
	for sid in _sorted_keys(e.spaces) {
		sp := e.spaces[sid]
		if !sp.open || !sp.repl_on {
			continue
		}
		for len(sp.needs) > 0 || len(sp.events) > 0 {
			needs := sp.needs
			sp.needs = make([dynamic]Need, e.allocator)
			for n in needs {
				switch n.kind {
				case .Card:
					_card_want(e, sp, n.device, n.name)
				case .Keys:
					if id, _, ok := _object_of_name(n.name); ok {
						sc := _object_scope(sp, id)
						epoch: u64
						if rec, found, _ := _rec_get(e, id); found {
							if i := _rec_member(&rec, n.device); i >= 0 {
								epoch = rec.members[i].keys_epoch
							}
						}
						_remote_tree_get(e, sp, &sc, n.device, n.name, epoch)
						osync.scope_clear(&sc)
					}
				}
				delete(n.name, e.allocator)
			}
			delete(needs)
			evs := sp.events
			sp.events = make([dynamic]Repl_Ev, e.allocator)
			for &ev in evs {
				_repl_event_apply(e, sp, &ev)
				delete(ev.name, e.allocator)
			}
			delete(evs)
		}
	}
}

@(private)
_need_add :: proc(e: ^Engine, sp: ^Space, kind: Need_Kind, device: prim.Id, name: string) {
	for n in sp.needs {
		if n.kind == kind && n.device == device && n.name == name {
			return
		}
	}
	nm, _ := _clone(name, e.allocator)
	append(&sp.needs, Need{kind, device, nm})
	_touch(e)
}

@(private)
_repl_event_apply :: proc(e: ^Engine, sp: ^Space, ev: ^Repl_Ev) {
	#partial switch ev.kind {
	case .Connected:
		sp.connected = true
		_emit(e, Event{kind = .Connected, space = sp.id})
		_pending_republish(e, sp)
		_relay_redact_resend(e, sp)
	case .Disconnected:
		sp.connected = false
		_emit(e, Event{kind = .Disconnected, space = sp.id, err = _serr(ev.err)})
	case .Uploaded:
		_own_tree_uploaded(e, ev.stream, ev.length)
		if id, _, ok := _object_of_name(ev.name); ok {
			_pending_clear(e, sp.id, id, ev.length)
			_emit(e, Event{kind = .Uploaded, space = sp.id, object = id, length = ev.length})
		}
	case .Grew, .Present:
		_remote_changed(e, sp, ev.device, ev.name, ev.epoch, ev.length, ev.stream)
	case .Segment_Seen:
		if id, kind, ok := _object_of_name(ev.name); ok {
			_member_seen(e, sp, id, kind, ev.device)
		}
	case .Epoch_Seen:
		if seg, ok := _keys_target(ev.name); ok {
			if id, _, ok2 := _object_of_name(seg); ok2 {
				_keys_epoch_seen(e, sp, id, ev.device, seg, ev.epoch)
			}
		}
	case .Checkpoint:
		_ckpt_arrived(e, sp, ev.name, true)
	case .Checkpoint_Missing:
		_ckpt_arrived(e, sp, ev.name, false)
	case .Quarantined:
		obj_id, _, _ := _object_of_name(ev.name)
		_emit(e, Event{kind = .Quarantined, space = sp.id, object = obj_id, device = ev.device, length = ev.from})
		_object_changed(e, sp.id, obj_id, .Quarantined)
	case .Refused:
		_emit(e, Event{kind = .Refused, space = sp.id, device = ev.device, err = _serr(ev.err)})
	case .Fatal:
		obj_id, _, _ := _object_of_name(ev.name)
		_emit(e, Event{kind = .Fatal, space = sp.id, object = obj_id, err = _serr(ev.err), length = ev.length})
	case .Redacted:
		_relay_redacted_event(e, sp, ev.stream, ev.from, ev.to)
	case .Local_Redacted:
		_local_redacted(e, sp, ev.stream, ev.from, ev.to)
	}
}

@(private)
_remote_changed :: proc(e: ^Engine, sp: ^Space, device: prim.Id, name: string, epoch: u64, length: i64, stream: osync.Stream_Id) {
	if name == CARD_STREAM {
		_card_learn(e, sp, device, stream)
		return
	}
	if seg, ok := _keys_target(name); ok {
		if rt := _remote_tree_by_keys(sp, device, name); rt != nil && !rt.loaded && epoch >= rt.epoch {
			if epoch > rt.epoch || length > 0 {
				rt.requested = false
			}
			rt.epoch = epoch
			_remote_tree_load(e, sp, rt)
			if rt.loaded {
				_held_release(e, sp, device)
			}
		}
		if id, _, ok2 := _object_of_name(seg); ok2 {
			if h, hok := e.handles[id]; hok {
				_handle_refresh(h)
			}
			_object_changed(e, sp.id, id, .Keys)
		}
		return
	}
	id, kind, ok := _object_of_name(name)
	if !ok {
		return
	}
	if h, hok := e.handles[id]; hok {
		_handle_remote_grew(h, device)
	}
	_content_data_arrived(e, id)
	_object_changed(e, sp.id, id, .Data)
	_index_item_add(e, sp.id, id, kind)
}

@(private)
_member_seen :: proc(e: ^Engine, sp: ^Space, id: prim.Id, kind: Kind, device: prim.Id) {
	if device == e.self {
		return
	}
	rec, found, err := _rec_get(e, id)
	if err != .None {
		return
	}
	if !found {
		rec = Obj_Rec{space = sp.id, kind = kind, members = make([dynamic]Member, context.temp_allocator)}
	}
	if _rec_member(&rec, device) >= 0 {
		return
	}
	append(&rec.members, Member{device = device})
	_rec_put(e, id, &rec)
	_card_relay(e, sp, id, device)
	if h, ok := e.handles[id]; ok {
		_handle_add_member(h, device, 0)
	}
	_object_changed(e, sp.id, id, .Members)
	_emit(e, Event{kind = .Object_Seen, space = sp.id, object = id, device = device})
}

@(private)
_keys_epoch_seen :: proc(e: ^Engine, sp: ^Space, id: prim.Id, device: prim.Id, seg: string, epoch: u64) {
	rec, found, err := _rec_get(e, id)
	if err != .None || !found {
		return
	}
	i := _rec_member(&rec, device)
	if i < 0 || rec.members[i].keys_epoch >= epoch {
		return
	}
	rec.members[i].keys_epoch = epoch
	_rec_put(e, id, &rec)
	sc := _object_scope(sp, id)
	defer osync.scope_clear(&sc)
	stream := osync.stream_id(&sc, device, seg, 0)
	if rt, ok := sp.remote_trees[stream]; ok {
		_remote_tree_get(e, sp, &sc, device, seg, epoch)
		if h, hok := e.handles[id]; hok {
			_handle_rekey(h, device, rt)
		}
	}
	_object_changed(e, sp.id, id, .Keys)
}

@(private)
_verify :: proc(user: rawptr, req: ^osync.Verify_Request) -> osync.Verdict {
	sp := (^Space)(user)
	e := sp.e
	if _, _, ok := _object_of_name(req.name); !ok {
		return .Accept
	}
	if !(req.device in sp.identities) {
		_held_add(e, sp, req.device, req.name)
		_need_add(e, sp, .Card, req.device, req.name)
		return .Hold
	}
	rt, found := sp.remote_trees[req.stream]
	if !found || !rt.loaded {
		_held_add(e, sp, req.device, req.name)
		_need_add(e, sp, .Keys, req.device, req.name)
		return .Hold
	}
	V :: struct {
		sp: ^Space,
		rt: ^Remote_Tree,
	}
	v := V{sp, rt}
	cv := osync.Chain_Verifier {
		data = &v,
		identity = proc(data: rawptr, device: prim.Id) -> (osync.Identity, bool) {
			x := (^V)(data)
			id, ok := x.sp.identities[device]
			return id, ok
		},
		seed = proc(data: rawptr, stream: osync.Stream_Id) -> journal.Hash {
			return osync.chain_seed(stream)
		},
		keys = proc(data: rawptr, stream: osync.Stream_Id) -> journal.Key_Provider {
			x := (^V)(data)
			return osync.keytree_provider(&x.rt.tree)
		},
		keyring = e.keyring,
	}
	verdict := osync.chain_verify(&cv, req)
	if verdict == .Hold {
		_held_add(e, sp, req.device, req.name)
	}
	return verdict
}

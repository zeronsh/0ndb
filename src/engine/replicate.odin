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
		}
		sp.conn = conn
	} else {
		osync.replicator_start(&sp.repl)
	}
	_card_publish(e, sp)
	if !sp.keyless {
		_catalog_follow(e, sp)
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
	case .Device_Seen, .Dropped, .Object_Stored, .Object_Fetched, .Object_Missing, .Object_Failed, .Checkpoint, .Checkpoint_Missing, .Object_Shredded:
		return
	}
	name, _ := _clone(ev.name, e.allocator)
	append(&sp.events, Repl_Ev{kind = ev.kind, err = ev.err, device = ev.device, name = name, epoch = ev.epoch, stream = ev.stream, from = ev.from, to = ev.to, length = ev.length})
	_touch(e)
}

@(private)
_repl_events_process :: proc(e: ^Engine) {
	for _, sp in e.spaces {
		if !sp.open || !sp.repl_on {
			continue
		}
		for len(sp.needs) > 0 || len(sp.events) > 0 {
			needs := sp.needs
			sp.needs = make([dynamic]Need, e.allocator)
			for n in needs {
				switch n.kind {
				case .Card:
					osync.replicator_want_tail(&sp.repl, &sp.scope, n.device, CARD_STREAM, 0, 4096)
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
			_relay_redact_resend(e, sp, id)
			_emit(e, Event{kind = .Uploaded, space = sp.id, object = id, length = ev.length})
		}
	case .Grew, .Present:
		_remote_changed(e, sp, ev.device, ev.name, ev.epoch, ev.length)
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
		if osync.stream_device(ev.stream) == e.self {
			_relay_redact_done(e, sp, ev.stream, ev.from)
		} else if rm, ok := sp.repl.remotes[ev.stream]; ok {
			osync.replicator_zero_replica(&sp.repl, &sp.scope, rm.device, rm.name, rm.epoch, ev.from, ev.to)
			if id, _, ok2 := _object_of_name(rm.name); ok2 {
				_object_changed(e, sp.id, id, .Redacted)
			}
		}
	}
}

@(private)
_remote_changed :: proc(e: ^Engine, sp: ^Space, device: prim.Id, name: string, epoch: u64, length: i64) {
	if name == CARD_STREAM {
		_card_learn(e, sp, device)
		return
	}
	if seg, ok := _keys_target(name); ok {
		if rt := _remote_tree_by_keys(sp, device, name); rt != nil && !rt.loaded && epoch >= rt.epoch {
			rt.epoch = epoch
			rt.requested = false
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
	_, kind, ok := _object_of_name(req.name)
	if !ok || kind == .Text || kind == .File_Tree {
		return .Accept
	}
	if !(req.device in sp.identities) {
		_held_add(e, sp, req.device, req.name)
		_need_add(e, sp, .Card, req.device, CARD_STREAM)
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
	verdict := _chain_verify(&cv, req)
	if verdict == .Hold {
		_held_add(e, sp, req.device, req.name)
	}
	return verdict
}

@(private)
Sig_Check :: struct {
	cv:     ^osync.Chain_Verifier,
	signer: osync.Identity,
}

@(private)
_chain_verify :: proc(cv: ^osync.Chain_Verifier, req: ^osync.Verify_Request) -> osync.Verdict {
	signer, known := cv.identity(cv.data, req.device)
	if !known {
		return .Hold
	}
	check := Sig_Check{cv, signer}
	chain := journal.Chain {
		seed = cv.seed(cv.data, req.stream),
		verifier = journal.Verifier{data = &check, verify = proc(data: rawptr, msg: []u8, sig: []u8) -> bool {
				s := (^Sig_Check)(data)
				kr := s.cv.keyring
				if kr.verify != nil {
					return kr.verify(kr.data, &s.signer, msg, sig)
				}
				return osync.signature_verify(s.signer.sign, msg, sig)
			}},
	}
	if cv.keys != nil {
		chain.keys = cv.keys(cv.data, req.stream)
	}
	rd: journal.Reader
	journal.replica_reader(req.replica, &rd, context.temp_allocator)
	defer journal.reader_close(&rd)
	if chain.keys.key != nil {
		journal.reader_set_keys(&rd, chain.keys)
	}
	journal.reader_set_chain(&rd, &chain)
	pos, aligned := _align(req)
	if !aligned {
		return .Accept
	}
	last: journal.Sig_Info
	have_last := false
	for pos < req.to {
		_, next, err := journal.record_at(&rd, pos)
		if span, ok := journal.reader_span(&rd); ok && (!have_last || span.off != last.off) {
			if v := _span_cross(req, span); v != .Accept {
				return v
			}
			last = span
			have_last = true
		}
		#partial switch err {
		case .None, .Redacted:
			pos = next
			continue
		case .Eof:
			return .Accept
		case .Equivocation, .Forged, .Corrupt:
			return .Equivocation
		}
		return .Hold
	}
	return .Accept
}

@(private)
_span_cross :: proc(req: ^osync.Verify_Request, span: journal.Sig_Info) -> osync.Verdict {
	if req.span == nil || req.span_ok == nil {
		return .Accept
	}
	if req.span_ok^ {
		prev := req.span^
		if span.off == prev.off && span.head != prev.head {
			return .Equivocation
		}
		if span.off != prev.off && span.range_start < prev.end && span.end > prev.range_start {
			return .Equivocation
		}
		if span.range_start == prev.end && span.prev_head != prev.head {
			return .Equivocation
		}
		if prev.range_start == span.end && prev.prev_head != span.head {
			return .Equivocation
		}
		if span.end <= prev.end {
			return .Accept
		}
	}
	req.span^ = span
	req.span_ok^ = true
	return .Accept
}

@(private)
_align :: proc(req: ^osync.Verify_Request) -> (start: i64, ok: bool) {
	rep := req.replica
	if req.from == 0 {
		return 0, true
	}
	if req.span != nil && req.span_ok != nil && req.span_ok^ && req.span.end == req.from {
		return req.from, true
	}
	pos := req.to
	b: [4]u8
	for pos > req.from {
		if pos < journal.OVERHEAD || !journal.replica_covers(rep, pos - journal.TRAILER, pos) {
			break
		}
		n, rerr := prim.read_at(rep.vfs, rep.fd, b[:], pos - journal.TRAILER)
		if rerr != .None || n != 4 {
			return 0, false
		}
		size := i64(prim.get_u32le(b[:]))
		if size > journal.MAX_BODY {
			return 0, false
		}
		at := pos - size - journal.OVERHEAD
		if at < req.from || !journal.replica_covers(rep, at, pos) {
			break
		}
		n, rerr = prim.read_at(rep.vfs, rep.fd, b[:], at)
		if rerr != .None || n != 4 || i64(prim.get_u32le(b[:])) != size {
			return 0, false
		}
		pos = at
	}
	return pos, pos < req.to
}

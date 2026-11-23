package engine

import "../convo"
import "../journal"
import omap "../map"
import "../obj"
import "../prim"
import osync "../sync"

Delta_Kind :: enum u8 {
	Message,
	Block,
	Chunk,
	Seal,
	Leaf,
	Intent,
	Run,
	Mount,
	Record,
	Status,
	Field,
	Element,
	Counter,
	Catalog,
	Text,
	Files,
	Redacted,
	Members,
	Quarantined,
}

Delta :: struct {
	kind:   Delta_Kind,
	object: Object,
	rid:    Rid,
	msg:    Rid,
	record: u8,
	by:     prim.Id,
	local:  bool,
	hlc:    prim.Hlc,
	role:   convo.Role,
	index:  u32,
	block:  convo.Block_Kind,
	seal:   convo.Seal_Status,
	status: convo.Status,
	usage:  convo.Usage,
	text:   []u8,
	key:    []u8,
	tag:    u32,
	removed: bool,
	length: i64,
	draft:  bool,
}

Sub_Id :: distinct u64

Sub_Proc :: #type proc(data: rawptr, e: ^Engine, sub: Sub_Id, deltas: []Delta)

@(private)
Sub_Cursor :: struct {
	device: prim.Id,
	end:    i64,
}

@(private)
Sub :: struct {
	id:         Sub_Id,
	object:     Object,
	kind:       Kind,
	catalog:    bool,
	cb:         Sub_Proc,
	data:       rawptr,
	cursors:    [dynamic]Sub_Cursor,
	status:     convo.Status,
	has_status: bool,
	primed:     bool,
	drafts:     [dynamic]Sub_Draft,
}

subscribe :: proc(e: ^Engine, o: Object, kind: Kind, cb: Sub_Proc, data: rawptr) -> (id: Sub_Id, err: Error) {
	context = context_for(e)
	if cb == nil {
		return 0, .Invalid
	}
	h := _handle_get(e, o, kind) or_return
	s := new(Sub, e.allocator)
	e.next_sub += 1
	s.id = Sub_Id(e.next_sub)
	s.object = o
	s.kind = kind
	s.catalog = o.id == h.sp.catalog
	s.cb = cb
	s.data = data
	s.cursors = make([dynamic]Sub_Cursor, e.allocator)
	s.drafts = make([dynamic]Sub_Draft, e.allocator)
	_sub_prime(e, s, h)
	append(&e.subs, s)
	return s.id, .None
}

subscribe_catalog :: proc(e: ^Engine, space: prim.Id, cb: Sub_Proc, data: rawptr) -> (id: Sub_Id, err: Error) {
	context = context_for(e)
	sp := _space_open(e, space) or_return
	return subscribe(e, Object{space, sp.catalog}, .Map, cb, data)
}

unsubscribe :: proc(e: ^Engine, id: Sub_Id) {
	context = context_for(e)
	for s, i in e.subs {
		if s.id != id {
			continue
		}
		ordered_remove(&e.subs, i)
		if !_subscribed(e, s.object.id) && !s.catalog {
			if h, err := _handle_get(e, s.object, s.kind); err == .None && h.sp.repl_on && h.kind == .Conversation {
				_draft_live(e, h, false)
			}
		}
		_sub_free(e, s)
		return
	}
}

@(private)
_subscribed :: proc(e: ^Engine, id: prim.Id) -> bool {
	for s in e.subs {
		if s.object.id == id {
			return true
		}
	}
	return false
}

@(private)
_sub_free :: proc(e: ^Engine, s: ^Sub) {
	delete(s.cursors)
	delete(s.drafts)
	free(s, e.allocator)
}

@(private)
_subs_free_all :: proc(e: ^Engine) {
	for s in e.subs {
		_sub_free(e, s)
	}
	clear(&e.subs)
}

@(private)
_sub_cursor :: proc(s: ^Sub, device: prim.Id) -> ^Sub_Cursor {
	for &c in s.cursors {
		if c.device == device {
			return &c
		}
	}
	return nil
}

@(private)
_sub_prime :: proc(e: ^Engine, s: ^Sub, h: ^Handle) {
	_handle_refresh(h)
	_group_follow(h, h.kind != .Conversation)
	if h.w_open {
		append(&s.cursors, Sub_Cursor{e.self, _own_reader_end(h)})
	}
	for sg in h.segs {
		_follow(e, h, sg, h.kind == .Map)
		append(&s.cursors, Sub_Cursor{sg.device, journal.replica_length(sg.rep)})
	}
	if h.kind == .Conversation {
		if t, err := convo.view_tail(&h.view, e.self, context.temp_allocator); err == .None {
			s.status = t.status
			s.has_status = true
		}
		_sub_drafts_prime(e, s, h)
		_draft_live(e, h, true)
	}
	s.primed = true
}

@(private)
_own_reader :: proc(h: ^Handle) -> ^journal.Reader {
	if !h.w_open {
		return nil
	}
	#partial switch h.kind {
	case .Conversation:
		return &h.cw.core.jr
	case .Map:
		return &h.mw.core.jr
	}
	return nil
}

@(private)
_own_reader_end :: proc(h: ^Handle) -> i64 {
	if r := _own_reader(h); r != nil {
		return journal.reader_end(r)
	}
	return _own_len(h)
}

@(private)
_subs_deliver :: proc(e: ^Engine) {
	if len(e.changed) == 0 {
		return
	}
	changed := e.changed
	e.changed = make(map[prim.Id]Change, e.allocator)
	defer delete(changed)
	if len(e.subs) == 0 {
		return
	}
	list := make([dynamic]^Sub, 0, len(e.subs), context.temp_allocator)
	append(&list, ..e.subs[:])
	for s in list {
		c, ok := changed[s.object.id]
		if !ok {
			continue
		}
		alive := false
		for x in e.subs {
			alive ||= x == s
		}
		if !alive {
			continue
		}
		deltas := make([dynamic]Delta, context.temp_allocator)
		_sub_collect(e, s, c.kinds, &deltas)
		if len(deltas) > 0 {
			{
				context = _outer(e)
				s.cb(s.data, e, s.id, deltas[:])
			}
		}
	}
}

@(private)
_sub_collect :: proc(e: ^Engine, s: ^Sub, kinds: Change_Kinds, out: ^[dynamic]Delta) {
	h, err := _handle_get(e, s.object, s.kind)
	if err != .None {
		return
	}
	_handle_refresh(h)
	_group_follow(h, h.kind != .Conversation)
	joined := false
	for sg in h.segs {
		if _sub_cursor(s, sg.device) == nil && (.Members in kinds || sg.in_view) {
			_follow(e, h, sg, h.kind == .Map)
			start: i64
			if have := journal.replica_have(sg.rep); len(have) > 0 {
				start = have[0].from
			}
			append(&s.cursors, Sub_Cursor{sg.device, start})
			append(out, Delta{kind = .Members, object = s.object, by = sg.device})
			joined = true
		}
	}
	if (.Members in kinds || joined) && h.kind == .Conversation {
		_draft_live(e, h, true)
	}
	if .Quarantined in kinds {
		append(out, Delta{kind = .Quarantined, object = s.object})
	}
	if .Redacted in kinds {
		append(out, Delta{kind = .Redacted, object = s.object})
	}
	switch h.kind {
	case .Conversation, .Map:
		if h.kind == .Conversation {
			_draft_live(e, h, true)
			_drafts_prune(e, h)
		}
		if r := _own_reader(h); r != nil {
			if _sub_cursor(s, e.self) == nil {
				append(&s.cursors, Sub_Cursor{e.self, 0})
			}
			_sub_scan(e, s, h, e.self, r, true, out)
		}
		for sg in h.segs {
			if sg.in_view {
				_sub_scan(e, s, h, sg.device, &sg.jr, false, out)
			}
		}
		if h.kind == .Conversation {
			_sub_drafts(e, s, h, out)
			if t, terr := convo.view_tail(&h.view, e.self, context.temp_allocator); terr == .None {
				if !s.has_status || t.status != s.status {
					if head, herr := convo.tail_head(&h.view, &t); herr == .None {
						s.status = t.status
						s.has_status = true
						append(out, Delta{kind = .Status, object = s.object, status = t.status, hlc = t.head_hlc, msg = head})
					}
				}
			}
		}
	case .Text, .File_Tree:
		_hist_catch_up(e, h)
		changed := false
		if c := _sub_cursor(s, e.self); c != nil {
			n := _own_len(h)
			changed ||= n != c.end
			c.end = n
		} else {
			append(&s.cursors, Sub_Cursor{e.self, _own_len(h)})
			changed = true
		}
		for sg in h.segs {
			n := journal.replica_length(sg.rep)
			if c := _sub_cursor(s, sg.device); c != nil {
				changed ||= n != c.end
				c.end = n
			}
		}
		if changed {
			append(out, Delta{kind = .Text if h.kind == .Text else .Files, object = s.object})
		}
	}
}

@(private)
_sub_scan :: proc(e: ^Engine, s: ^Sub, h: ^Handle, device: prim.Id, r: ^journal.Reader, local: bool, out: ^[dynamic]Delta) {
	c := _sub_cursor(s, device)
	if c == nil {
		return
	}
	end := journal.reader_end(r)
	pos := c.end
	vs := obj.view_find(&h.view, device)
	for pos < end {
		body, next, je := journal.record_at(r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je == .Missing && !local && h.sp.repl_on {
			if gap := r.missing; gap.from < end {
				want := [1]journal.Range{{max(gap.from, pos), min(max(gap.to, gap.from + 1), end)}}
				osync.replicator_want(&h.sp.repl, &h.scope, device, h.name, 0, want[:])
			}
			if osync.replicator_relay_length(&h.sp.repl, &h.scope, device, h.name, 0) < 0 {
				osync.replicator_want_tail(&h.sp.repl, &h.scope, device, h.name, 0, 1)
			}
		}
		if je != .None {
			break
		}
		at := pos
		pos = next
		if obj.is_sig(body) || obj.is_redacted(body) {
			continue
		}
		k := obj.record_kind(body)
		if k == obj.RECORD_REDACT {
			if env, eerr := obj.decode_envelope(body, at); eerr == .None {
				append(out, Delta{kind = .Redacted, object = s.object, rid = Rid{device, at, env.links.gen}, by = device, local = local})
			}
			continue
		}
		if k < obj.RECORD_KIND_FIRST {
			continue
		}
		derr: obj.Error
		if h.kind == .Conversation {
			derr = _delta_convo(e, s, h, vs, device, at, body, local, out)
		} else {
			_delta_map(e, s, h, device, at, body, local, out)
		}
		if derr == .Missing {
			pos = at
			break
		}
	}
	c.end = pos
}

@(private)
_resolve_rid :: proc(h: ^Handle, vs: int, r: obj.Ref) -> (Rid, obj.Error) {
	if obj.ref_none(r) || vs < 0 {
		return {}, .None
	}
	v, err := obj.resolve(&h.view, vs, r)
	if err == .Missing {
		return {}, .Missing
	}
	if err != .None {
		return {}, .None
	}
	return _rid_or_missing(&h.view, v)
}

@(private)
_rid_or_missing :: proc(v: ^obj.View, x: obj.Vref) -> (Rid, obj.Error) {
	r, err := obj.rid(v, x)
	if err == .Missing {
		return {}, .Missing
	}
	if err != .None {
		return {}, .None
	}
	return r, .None
}

@(private)
_delta_convo :: proc(e: ^Engine, s: ^Sub, h: ^Handle, vs: int, device: prim.Id, at: i64, body: []u8, local: bool, out: ^[dynamic]Delta) -> obj.Error {
	rec, err := convo.decode_record(_tmp_bytes(body), at, context.temp_allocator)
	if err != .None {
		return .None
	}
	here := Rid{device, at, rec.env.links.gen}
	d := Delta{object = s.object, rid = here, by = device, local = local, record = rec.env.kind, hlc = rec.stamp}
	switch b in rec.body {
	case convo.Msg:
		d.kind = .Message
		d.role = b.role
		d.hlc = b.hlc
		d.msg = here
	case convo.Block:
		d.msg = _rid_or_missing(&h.view, obj.Vref{vs, b.msg}) or_return
		d.index = b.index
		d.block = b.kind
		d.text = _tmp_bytes(b.data)
		d.kind = .Block if .Start in b.flags else .Chunk
		if !_sub_block_delta(e, s, h, &d, device, b.msg, .Start in b.flags) {
			return .None
		}
		if d.kind == .Chunk {
			if n := len(out); n > 0 {
				p := &out[n - 1]
				if (p.kind == .Chunk || p.kind == .Block) && p.msg == d.msg && p.index == d.index {
					buf := make([]u8, len(p.text) + len(d.text), context.temp_allocator)
					copy(buf, p.text)
					copy(buf[len(p.text):], d.text)
					p.text = buf
					p.rid = d.rid
					return .None
				}
			}
		}
	case convo.Seal:
		d.kind = .Seal
		d.msg = _rid_or_missing(&h.view, obj.Vref{vs, b.msg}) or_return
		_sub_drafts_forget(s, device, b.msg)
		_draft_closed(h, device, b.msg)
		d.seal = b.status
		d.usage = b.usage
		d.hlc = b.hlc
	case convo.Leaf:
		d.kind = .Leaf
		d.msg = _resolve_rid(h, vs, b.msg) or_return
		d.hlc = b.hlc
	case convo.Queue:
		d.kind = .Intent
		d.text = _tmp_bytes(transmute([]u8)b.text)
	case convo.Steer:
		d.kind = .Intent
		d.text = _tmp_bytes(transmute([]u8)b.text)
		d.msg = _resolve_rid(h, vs, b.msg) or_return
	case convo.Edit_Queued:
		d.kind = .Intent
		d.text = _tmp_bytes(transmute([]u8)b.text)
		d.msg = _resolve_rid(h, vs, b.item) or_return
	case convo.Cancel:
		d.kind = .Intent
		d.msg = _resolve_rid(h, vs, b.item) or_return
	case convo.Interrupt:
		d.kind = .Intent
		d.msg = _resolve_rid(h, vs, b.msg) or_return
	case convo.Answer:
		d.kind = .Intent
		d.text = _tmp_bytes(transmute([]u8)b.text)
		d.msg = _resolve_rid(h, vs, b.request) or_return
	case convo.Await:
		d.kind = .Intent
	case convo.Hold:
		d.kind = .Intent
		d.text = _tmp_bytes(transmute([]u8)b.reason)
	case convo.Assign:
		d.kind = .Run
		d.msg = _resolve_rid(h, vs, b.msg) or_return
	case convo.Claim:
		d.kind = .Run
		d.msg = _resolve_rid(h, vs, b.msg) or_return
	case convo.Unqueue:
		d.kind = .Run
		d.msg = _resolve_rid(h, vs, b.item) or_return
	case convo.Superseded:
		d.kind = .Run
		d.msg = _resolve_rid(h, vs, b.run) or_return
	case convo.Landed:
		d.kind = .Run
		d.msg = _resolve_rid(h, vs, b.run) or_return
	case convo.Interrupted:
		d.kind = .Seal
		d.msg = _rid_or_missing(&h.view, obj.Vref{vs, b.msg}) or_return
		_sub_drafts_forget(s, device, b.msg)
		_draft_closed(h, device, b.msg)
		d.seal = .Interrupted
	case convo.Revived:
		d.kind = .Run
		d.msg = _rid_or_missing(&h.view, obj.Vref{vs, b.msg}) or_return
	case convo.Mount:
		d.kind = .Mount
		d.text = _tmp_bytes(transmute([]u8)b.name)
	case convo.Unmount:
		d.kind = .Mount
		d.text = _tmp_bytes(transmute([]u8)b.name)
		d.removed = true
	case convo.Fork, convo.Remember, convo.Forks, convo.Compact, convo.Scope, convo.Recorded, convo.Spine, convo.Files, convo.Redact_Msg:
		d.kind = .Record
	case:
		d.kind = .Record
	}
	append(out, d)
	return .None
}

@(private)
_delta_map :: proc(e: ^Engine, s: ^Sub, h: ^Handle, device: prim.Id, at: i64, body: []u8, local: bool, out: ^[dynamic]Delta) {
	env, err := obj.decode_envelope(body, at)
	if err != .None {
		return
	}
	b, berr := omap.decode_body(&env, context.temp_allocator)
	if berr != .None {
		return
	}
	switch v in b {
	case omap.Put:
		v_key := _tmp_bytes(v.key)
		if s.catalog {
			append(out, Delta{kind = .Catalog, object = s.object, rid = Rid{device, at, env.links.gen}, by = device, local = local, key = v_key, record = env.kind})
			return
		}
		for f in v.fields {
			append(out, Delta{kind = .Field, object = s.object, rid = Rid{device, at, env.links.gen}, by = device, local = local, key = v_key, tag = f.tag, text = _tmp_bytes(f.value), hlc = f.hlc, record = env.kind})
		}
	case omap.Add:
		k := Delta_Kind.Catalog if s.catalog else .Element
		append(out, Delta{kind = k, object = s.object, rid = Rid{device, at, env.links.gen}, by = device, local = local, key = _tmp_bytes(v.key), tag = v.tag, text = _tmp_bytes(v.element), record = env.kind})
		if s.catalog && v.tag == u32(omap.Catalog_Tag.Participants) && len(v.element) == 16 {
			_catalog_participant_seen(e, h.sp, v.key, v.element)
		}
	case omap.Del:
		k := Delta_Kind.Catalog if s.catalog else .Element
		append(out, Delta{kind = k, object = s.object, rid = Rid{device, at, env.links.gen}, by = device, local = local, key = _tmp_bytes(v.key), tag = v.tag, text = _tmp_bytes(v.element), removed = true, record = env.kind})
	case omap.Count:
		k := Delta_Kind.Catalog if s.catalog else .Counter
		append(out, Delta{kind = k, object = s.object, rid = Rid{device, at, env.links.gen}, by = device, local = local, key = _tmp_bytes(v.key), tag = v.tag, length = v.delta, record = env.kind})
	}
}

@(private)
_catalog_participant_seen :: proc(e: ^Engine, sp: ^Space, key: []u8, element: []u8) {
	id, ok := omap.value_id(key)
	dev, ok2 := omap.value_id(element)
	if !ok || !ok2 || dev == e.self {
		return
	}
	kind := Kind.Conversation
	rec, found, err := _rec_get(e, id)
	if err != .None {
		return
	}
	if found {
		kind = rec.kind
	} else {
		ch, ok3 := e.handles[sp.catalog]
		if !ok3 || !ch.table_open {
			return
		}
		c, cfound, cerr := omap.catalog_get(&ch.table, id, context.temp_allocator)
		if cerr != .None || !cfound || c.kind == Kind(0) {
			return
		}
		kind = c.kind
	}
	_member_seen(e, sp, id, kind, dev)
}

@(private)
_tmp_bytes :: proc(b: []u8) -> []u8 {
	if len(b) == 0 {
		return nil
	}
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out
}

package engine

import "core:crypto"
import "../convo"
import "../journal"
import "../obj"
import "../prim"
import osync "../sync"

@(private)
DRAFT_VIEW_MAX :: 4 * 1024 * 1024

@(private)
Draft_Block :: struct {
	index:  u32,
	kind:   convo.Block_Kind,
	start:  bool,
	failed: bool,
	id:     string,
	name:   string,
	pos:    i64,
	data:   [dynamic]u8,
}

@(private)
Draft_View :: struct {
	device:  prim.Id,
	msg:     i64,
	last:    i64,
	end:     i64,
	size:    int,
	pulling: bool,
	gap:     bool,
	blocks:  [dynamic]Draft_Block,
}

@(private)
DRAFT_CLOSED :: 32

@(private)
Draft_Key :: struct {
	device: prim.Id,
	msg:    i64,
}

@(private)
_draft_closed :: proc(h: ^Handle, device: prim.Id, msg: i64) {
	_drafts_drop(h, device, msg)
	for k in h.dclosed[:min(h.dclosed_n, DRAFT_CLOSED)] {
		if k.device == device && k.msg == msg {
			return
		}
	}
	h.dclosed[h.dclosed_n % DRAFT_CLOSED] = Draft_Key{device, msg}
	h.dclosed_n += 1
}

@(private)
_draft_was_closed :: proc(h: ^Handle, device: prim.Id, msg: i64) -> bool {
	for k in h.dclosed[:min(h.dclosed_n, DRAFT_CLOSED)] {
		if k.device == device && k.msg == msg {
			return true
		}
	}
	return false
}

@(private)
Draft_Pub :: struct {
	object: prim.Id,
	gen:    u64,
	end:    i64,
}

@(private)
Sub_Draft :: struct {
	device: prim.Id,
	msg:    i64,
	floor:  u32,
	index:  u32,
	seg:    i64,
	seen:   i64,
	started: bool,
}

@(private)
_draft_view :: proc(h: ^Handle, device: prim.Id, msg: i64, create: bool) -> ^Draft_View {
	for v in h.drafts {
		if v.device == device && v.msg == msg {
			return v
		}
	}
	if !create {
		return nil
	}
	v := new(Draft_View, h.e.allocator)
	v.device = device
	v.msg = msg
	v.last = -1
	v.blocks = make([dynamic]Draft_Block, h.e.allocator)
	append(&h.drafts, v)
	return v
}

@(private)
_draft_view_free :: proc(e: ^Engine, v: ^Draft_View) {
	for &b in v.blocks {
		delete(b.data)
		delete(b.id, e.allocator)
		delete(b.name, e.allocator)
	}
	delete(v.blocks)
	free(v, e.allocator)
}

@(private)
_drafts_drop :: proc(h: ^Handle, device: prim.Id, msg: i64) {
	for i := 0; i < len(h.drafts); {
		v := h.drafts[i]
		if v.device == device && (msg < 0 || v.msg == msg) {
			ordered_remove(&h.drafts, i)
			_draft_view_free(h.e, v)
			continue
		}
		i += 1
	}
}

@(private)
_drafts_free :: proc(h: ^Handle) {
	for v in h.drafts {
		_draft_view_free(h.e, v)
	}
	delete(h.drafts)
	h.drafts = nil
}

@(private)
_draft_seg_index :: proc(h: ^Handle, device: prim.Id) -> int {
	if !h.view_init {
		return -1
	}
	return obj.view_find(&h.view, device)
}

@(private)
_draft_state :: proc(h: ^Handle, device: prim.Id, msg: i64) -> convo.Draft_State {
	return convo.draft_msg_state(&h.view, _draft_seg_index(h, device), msg)
}

@(private)
_draft_apply :: proc(h: ^Handle, device: prim.Id, at, next: i64, body: []u8) -> (applied: bool, gap: bool) {
	d, err := convo.draft_decode(body)
	if err != .None {
		return false, false
	}
	if _draft_was_closed(h, device, d.msg) || _draft_state(h, device, d.msg) == .Closed {
		return false, false
	}
	v := _draft_view(h, device, d.msg, true)
	if at <= v.last {
		return false, false
	}
	if d.prev != v.last {
		v.gap = true
		return false, true
	}
	b: ^Draft_Block
	for &x in v.blocks {
		if x.index == d.index {
			b = &x
			break
		}
	}
	if b == nil {
		nb := Draft_Block{index = d.index, pos = d.off, data = make([dynamic]u8, h.e.allocator)}
		append(&v.blocks, nb)
		b = &v.blocks[len(v.blocks) - 1]
	}
	if d.start && !b.start {
		b.start = true
		b.kind = d.kind
		b.failed = d.failed
		b.id, _ = _clone(d.id, h.e.allocator)
		b.name, _ = _clone(d.name, h.e.allocator)
	}
	end := b.pos + i64(len(b.data))
	if d.off <= end {
		skip := end - d.off
		if skip < i64(len(d.data)) && v.size + len(d.data) - int(skip) <= DRAFT_VIEW_MAX {
			append(&b.data, ..d.data[skip:])
			v.size += len(d.data) - int(skip)
		}
	} else {
		v.size -= len(b.data)
		clear(&b.data)
		b.pos = d.off
		append(&b.data, ..d.data)
		v.size += len(d.data)
	}
	v.last = at
	v.end = next
	v.gap = false
	return true, false
}

@(private)
Draft_Mark :: struct {
	gen:  u64,
	view: i64,
	dur:  i64,
	pub:  i64,
}

@(private)
_draft_own_feed :: proc(e: ^Engine, h: ^Handle) {
	if h.kind != .Conversation || !h.w_open {
		return
	}
	w := &h.cw
	gen := convo.writer_draft_gen(w)
	if !h.dloaded {
		h.dloaded = true
		if m, ok := e.draft_marks[h.id]; ok && m.gen == gen {
			h.dgen = gen
			h.drep = m.view
			h.ddur = m.dur
			h.dpub = m.pub
		}
	}
	if gen != h.dgen {
		h.dgen = gen
		h.dview = 0
		h.ddur = 0
		h.dpub = 0
		h.drep = 0
	}
	end := convo.writer_draft_durable(w)
	if end <= h.dview {
		return
	}
	r: journal.Reader
	if !convo.writer_draft_reader(w, &r) {
		return
	}
	defer journal.reader_close(&r)
	pos := h.dview
	changed := false
	for pos < end {
		body, next, je := journal.record_at(&r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			break
		}
		if ok, _ := _draft_apply(h, e.self, pos, next, body); ok && next > h.drep {
			changed = true
		}
		pos = next
	}
	h.dview = pos
	h.drep = max(h.drep, pos)
	if pos > h.dpub {
		append(&e.draft_dirty, Draft_Pub{object = h.id, gen = gen, end = pos})
		h.dpub = pos
	}
	if changed {
		_object_changed(e, h.sp.id, h.id, .Data)
	}
}

@(private)
_draft_own_key :: proc(h: ^Handle, msg: i64) -> (key: journal.Key, plain: bool, ok: bool) {
	if h.sp.mode == .Transparent {
		return key, true, true
	}
	if h.own_tree == nil {
		return key, false, false
	}
	key, ok = osync.draft_key(osync.keytree_provider(&h.own_tree.tree), msg)
	return key, false, ok
}

@(private)
_draft_seal :: proc(h: ^Handle, msg: i64, rec: []u8, at: i64) -> bool {
	key, plain, ok := _draft_own_key(h, msg)
	if !ok {
		return false
	}
	defer crypto.zero_explicit(&key, size_of(key))
	if plain {
		return journal.check_record(rec, at) == .None
	}
	return journal.seal_range(rec, at, osync.static_provider(&key)) == .None
}

@(private)
_draft_collect :: proc(h: ^Handle, from, to: i64, only: i64, out: ^[dynamic]osync.Live_Run, msgs: ^[dynamic]i64) {
	r: journal.Reader
	if !convo.writer_draft_reader(&h.cw, &r) {
		return
	}
	defer journal.reader_close(&r)
	pos := from
	for pos < to {
		body, next, je := journal.record_at(&r, pos)
		if je == .Redacted {
			pos = next
			continue
		}
		if je != .None {
			break
		}
		d, derr := convo.draft_decode(body)
		if derr == .None && (only < 0 || d.msg == only) {
			rec := make([]u8, int(next - pos), context.temp_allocator)
			journal.encode_record(rec, body, pos)
			if _draft_seal(h, d.msg, rec, pos) {
				n := len(out)
				if n > 0 && msgs[n - 1] == d.msg && out[n - 1].at + i64(len(out[n - 1].data)) == pos {
					joined := make([]u8, len(out[n - 1].data) + len(rec), context.temp_allocator)
					copy(joined, out[n - 1].data)
					copy(joined[len(out[n - 1].data):], rec)
					out[n - 1].data = joined
				} else {
					append(out, osync.Live_Run{at = pos, data = rec})
					append(msgs, d.msg)
				}
			}
		}
		pos = next
	}
}

@(private)
_draft_publish :: proc(e: ^Engine, p: Draft_Pub) {
	h, ok := e.handles[p.object]
	if !ok || !h.w_open || h.kind != .Conversation || convo.writer_draft_gen(&h.cw) != p.gen || h.dgen != p.gen {
		return
	}
	from := h.ddur
	if p.end <= from {
		return
	}
	h.ddur = p.end
	sp := h.sp
	if !sp.repl_on || !osync.replicator_live_on(&sp.repl) {
		return
	}
	runs := make([dynamic]osync.Live_Run, context.temp_allocator)
	msgs := make([dynamic]i64, context.temp_allocator)
	_draft_collect(h, from, p.end, -1, &runs, &msgs)
	for x, i in runs {
		if osync.replicator_live_send(&sp.repl, &h.scope, h.name, 0, msgs[i], x.at, x.data) {
			e.stats.live_bytes += u64(len(x.data))
		}
	}
}

@(private)
_draft_settle :: proc(e: ^Engine, object: prim.Id, length: i64) {
	h, ok := e.handles[object]
	if !ok || !h.w_open || h.kind != .Conversation {
		return
	}
	convo.writer_draft_settle(&h.cw, length)
}

@(private)
_draft_handle_by_stream :: proc(e: ^Engine, sp: ^Space, id: osync.Stream_Id) -> (h: ^Handle, device: prim.Id, own: bool) {
	dev := osync.stream_device(id)
	for _, x in e.handles {
		if x.sp != sp || x.kind != .Conversation {
			continue
		}
		if osync.stream_id(&x.scope, dev, x.name, 0) == id {
			return x, dev, dev == e.self
		}
	}
	return nil, dev, false
}

@(private)
_draft_remote_key :: proc(sp: ^Space, id: osync.Stream_Id, msg: i64) -> (key: journal.Key, plain: bool, ok: bool) {
	if sp.mode == .Transparent {
		return key, true, true
	}
	rt, found := sp.remote_trees[id]
	if !found || !rt.loaded {
		return key, false, false
	}
	key, ok = osync.draft_key(osync.keytree_provider(&rt.tree), msg)
	return key, false, ok
}

@(private)
_draft_on_repl :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	if ev.kind == .Draft_Pulled {
		_draft_serve(e, sp, ev)
		return
	}
	h, device, own := _draft_handle_by_stream(e, sp, ev.stream)
	if h == nil && len(ev.name) > 0 {
		if id, kind, ok := _object_of_name(ev.name); ok && kind == .Conversation && _subscribed(e, id) {
			if x, herr := _handle_get(e, Object{sp.id, id}, .Conversation); herr == .None {
				_handle_refresh(x)
				h, device, own = _draft_handle_by_stream(e, sp, ev.stream)
			}
		}
	}
	if h == nil || own {
		return
	}
	msg := ev.to
	v := _draft_view(h, device, msg, false)
	done := ev.usage == 1
	if done && v != nil {
		v.pulling = false
	}
	if ev.err != .None || len(ev.meta) == 0 {
		return
	}
	key, plain, ok := _draft_remote_key(sp, ev.stream, msg)
	if !ok {
		if v == nil {
			v = _draft_view(h, device, msg, true)
		}
		v.gap = true
		return
	}
	defer crypto.zero_explicit(&key, size_of(key))
	data := make([]u8, len(ev.meta), context.temp_allocator)
	copy(data, ev.meta)
	pos := 0
	changed := false
	gap := false
	for pos < len(data) {
		k := journal.record_bounds(data[pos:])
		if k == 0 {
			break
		}
		n := int(prim.get_u32le(data[pos:])) + journal.OVERHEAD
		rec := data[pos:pos + n]
		at := ev.from + i64(pos)
		pos += n
		if plain {
			if journal.check_record(rec, at) != .None {
				break
			}
		} else if journal.open_record(rec, at, osync.static_provider(&key)) != .None {
			e.stats.draft_rejected += 1
			break
		}
		body, berr := journal.record_body(rec)
		if berr != .None || journal.classify(rec, at) == .Redacted {
			continue
		}
		d, derr := convo.draft_decode(body)
		if derr != .None || d.msg != msg {
			break
		}
		applied, g := _draft_apply(h, device, at, at + i64(n), body)
		changed ||= applied
		if g {
			gap = true
			break
		}
	}
	if changed {
		e.stats.draft_bytes += u64(len(data))
		_object_changed(e, sp.id, h.id, .Data)
	}
	v = _draft_view(h, device, msg, false)
	if v != nil && (gap || v.gap) && !v.pulling {
		_draft_pull(e, h, device, v)
	}
}

@(private)
_draft_pull :: proc(e: ^Engine, h: ^Handle, device: prim.Id, v: ^Draft_View) {
	if !h.sp.repl_on {
		return
	}
	from := v.end if v.last >= 0 else 0
	if osync.replicator_draft_pull(&h.sp.repl, &h.scope, device, h.name, 0, v.msg, from) {
		v.pulling = true
		e.stats.draft_pulls += 1
	}
}

@(private)
_draft_serve :: proc(e: ^Engine, sp: ^Space, ev: ^osync.Repl_Event) {
	requester := ev.device
	tag := u64(ev.length)
	msg := ev.to
	from := ev.from
	h, _, own := _draft_handle_by_stream(e, sp, ev.stream)
	if h == nil || !own || !h.w_open || convo.writer_draft_gen(&h.cw) != h.dgen {
		osync.replicator_draft_answer(&sp.repl, requester, tag, ev.stream, nil, 0)
		return
	}
	runs := make([dynamic]osync.Live_Run, context.temp_allocator)
	msgs := make([dynamic]i64, context.temp_allocator)
	served, serr := convo.writer_draft_serve(&h.cw, msg, from)
	if serr == .None {
		for x in served {
			to := min(x.end, h.ddur)
			if to > x.at {
				_draft_collect(h, x.at, to, msg, &runs, &msgs)
			}
		}
	}
	osync.replicator_draft_answer(&sp.repl, requester, tag, ev.stream, runs[:], h.ddur)
}

@(private)
_draft_live :: proc(e: ^Engine, h: ^Handle, on: bool) {
	if h.kind != .Conversation || !h.sp.repl_on {
		return
	}
	for sg in h.segs {
		if sg.device == e.self || sg.live == on {
			continue
		}
		sg.live = on
		osync.replicator_live_follow(&h.sp.repl, &h.scope, sg.device, h.name, 0, on)
		if on {
			_draft_catch_up(e, h, sg.device)
		}
	}
	if !on {
		for i := 0; i < len(h.drafts); {
			v := h.drafts[i]
			if v.device != e.self {
				ordered_remove(&h.drafts, i)
				_draft_view_free(e, v)
				continue
			}
			i += 1
		}
	}
}

@(private)
_draft_catch_up :: proc(e: ^Engine, h: ^Handle, device: prim.Id) {
	s := _draft_seg_index(h, device)
	if s < 0 {
		return
	}
	opens := make([dynamic]convo.Open, context.temp_allocator)
	if convo.draft_open_msgs(&h.view, s, &opens) != .None {
		return
	}
	for o in opens {
		v := _draft_view(h, device, o.msg, true)
		if !v.pulling {
			_draft_pull(e, h, device, v)
		}
	}
}

@(private)
_drafts_reconnected :: proc(e: ^Engine, sp: ^Space) {
	for _, h in e.handles {
		if h.sp != sp || h.kind != .Conversation {
			continue
		}
		for v in h.drafts {
			v.pulling = false
		}
		if !_subscribed(e, h.id) {
			continue
		}
		for sg in h.segs {
			if sg.live {
				_draft_catch_up(e, h, sg.device)
			}
		}
	}
}

@(private)
_drafts_prune :: proc(e: ^Engine, h: ^Handle) {
	for i := 0; i < len(h.drafts); {
		v := h.drafts[i]
		st := _draft_state(h, v.device, v.msg)
		drop := st == .Closed
		if !drop && v.device != e.self && h.sp.mode != .Transparent {
			sid := osync.stream_id(&h.scope, v.device, h.name, 0)
			if rt, ok := h.sp.remote_trees[sid]; ok && rt.loaded {
				k, kok := osync.draft_key(osync.keytree_provider(&rt.tree), v.msg)
				crypto.zero_explicit(&k, size_of(k))
				drop = !kok
			}
		}
		if drop {
			ordered_remove(&h.drafts, i)
			_draft_view_free(e, v)
			continue
		}
		i += 1
	}
}

@(private)
_sub_draft_entry :: proc(e: ^Engine, s: ^Sub, h: ^Handle, device: prim.Id, msg: i64, index: u32) -> ^Sub_Draft {
	for &x in s.drafts {
		if x.device == device && x.msg == msg && x.index == index {
			return &x
		}
	}
	floor: u32
	for x in s.drafts {
		if x.device == device && x.msg == msg {
			floor = max(floor, x.floor)
		}
	}
	append(&s.drafts, Sub_Draft{device = device, msg = msg, floor = floor, index = index})
	return &s.drafts[len(s.drafts) - 1]
}

@(private)
_sub_drafts_forget :: proc(s: ^Sub, device: prim.Id, msg: i64) {
	for i := 0; i < len(s.drafts); {
		if s.drafts[i].device == device && s.drafts[i].msg == msg {
			unordered_remove(&s.drafts, i)
			continue
		}
		i += 1
	}
}

@(private)
_sub_drafts_prime :: proc(e: ^Engine, s: ^Sub, h: ^Handle) {
	if h.kind != .Conversation || !h.view_init {
		return
	}
	for si in 0 ..< len(h.view.segs) {
		device := h.view.segs[si].id
		opens := make([dynamic]convo.Open, context.temp_allocator)
		if convo.draft_open_msgs(&h.view, si, &opens) != .None {
			continue
		}
		for o in opens {
			if o.blocks == 0 {
				continue
			}
			n, err := convo.draft_block_len(&h.view, si, o)
			if err != .None {
				continue
			}
			append(&s.drafts, Sub_Draft{device = device, msg = o.msg, floor = o.blocks - 1, index = o.blocks - 1, seg = n, seen = n, started = true})
		}
	}
}

@(private)
_sub_block_delta :: proc(e: ^Engine, s: ^Sub, h: ^Handle, d: ^Delta, device: prim.Id, msg: i64, start: bool) -> bool {
	x := _sub_draft_entry(e, s, h, device, msg, d.index)
	if d.index < x.floor {
		return false
	}
	p := x.seg
	x.seg += i64(len(d.text))
	end := p + i64(len(d.text))
	if start && !x.started {
		x.started = true
		d.kind = .Block
		d.text = d.text[min(max(x.seen - p, 0), i64(len(d.text))):]
		x.seen = max(x.seen, end)
		return true
	}
	if x.seen >= end {
		return false
	}
	d.text = d.text[max(x.seen - p, 0):]
	d.kind = .Chunk
	x.seen = end
	return true
}

@(private)
_sub_drafts :: proc(e: ^Engine, s: ^Sub, h: ^Handle, out: ^[dynamic]Delta) {
	for v in h.drafts {
		vs := _draft_seg_index(h, v.device)
		if vs < 0 || v.msg >= obj.end(&h.view, vs) {
			continue
		}
		rid, rerr := obj.rid(&h.view, obj.Vref{vs, v.msg})
		if rerr != .None || obj.rid_none(rid) {
			continue
		}
		for &b in v.blocks {
			x := _sub_draft_entry(e, s, h, v.device, v.msg, b.index)
			if b.index < x.floor {
				continue
			}
			end := b.pos + i64(len(b.data))
			d := Delta {
				object = s.object,
				msg    = rid,
				by     = v.device,
				local  = v.device == e.self,
				index  = b.index,
				block  = b.kind,
				draft  = true,
			}
			if !x.started {
				if !b.start || b.pos != 0 || len(b.data) == 0 {
					continue
				}
				x.started = true
				d.kind = .Block
				d.text = _tmp_bytes(b.data[:])
			} else {
				if b.pos > x.seen || end <= x.seen {
					continue
				}
				d.kind = .Chunk
				d.text = _tmp_bytes(b.data[x.seen - b.pos:])
			}
			x.seen = end
			append(out, d)
		}
	}
}

@(private)
_draft_redact_own :: proc(e: ^Engine, h: ^Handle, msg: i64) {
	_drafts_drop(h, e.self, msg)
	if h.w_open && h.kind == .Conversation {
		if convo.writer_draft_redact(&h.cw, msg) != .None {
			_log(e, .Warn, "draft redaction failed")
		}
	}
	t := h.own_tree
	if t == nil {
		return
	}
	k, ok := osync.draft_key(osync.keytree_provider(&t.tree), msg)
	crypto.zero_explicit(&k, size_of(k))
	if !ok {
		return
	}
	if osync.draft_puncture(&t.tree, msg) != .None {
		return
	}
	_own_tree_punctured(e, t)
	_dirty_keys(e, h.sp, h.id, h.kind, h.scope, t)
	cell := ((msg >> 4) + 1) << 4
	_own_rearchive(e, h, t, cell, cell + 1)
}

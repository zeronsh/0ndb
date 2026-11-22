package convo

import "base:runtime"
import "core:hash/xxhash"
import "../journal"
import "../obj"
import "../prim"

@(private)
CHILD_SYNC_BYTES :: 1024 * 1024
@(private)
BUF_KEEP :: 64 * 1024
@(private)
META_MAX :: 4096

Writer :: struct {
	core:         obj.Writer,
	sum:          Summary,
	buf:          Block_Buf,
	kids:         obj.Slots,
	updates:      [dynamic]Child_Update,
	seen:         [dynamic]i64,
	allocator:    runtime.Allocator,
}

@(private)
Block_Buf :: struct {
	active: bool,
	start:  bool,
	msg:    i64,
	index:  u32,
	kind:   Block_Kind,
	flags:  Block_Flags,
	id_len: int,
	meta:   [dynamic]u8,
	data:   [dynamic]u8,
}

@(private)
Child_Update :: struct {
	key:   u64,
	child: i64,
	seal:  i64,
}

Settings :: struct {
	title:     string,
	agent:     prim.Id,
	workspace: prim.Id,
	parent:    obj.Xref,
	provider:  string,
	model:     string,
}

Msg_Spec :: struct {
	role:       Role,
	author:     prim.Id,
	parent:     Rid,
	root:       bool,
	runner:     prim.Id,
	intent:     Rid,
	files:      []File_Delta,
	provider:   string,
	model:      string,
	native:     string,
	native_msg: string,
	claim:      i64,
}

encode_settings :: proc(s: Settings, allocator := context.temp_allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	w := prim.writer(&buf)
	obj.tw_str(&w, 16, s.title)
	obj.tw_id(&w, 17, s.agent)
	obj.tw_id(&w, 18, s.workspace)
	obj.tw_id(&w, 19, s.parent.object)
	obj.tw_id(&w, 20, s.parent.rid.seg)
	obj.tw_uv(&w, 21, u64(max(s.parent.rid.off, 0)))
	obj.tw_uv(&w, 24, s.parent.rid.gen)
	obj.tw_str(&w, 22, s.provider)
	obj.tw_str(&w, 23, s.model)
	return buf[:]
}

decode_settings :: proc(b: []u8) -> (s: Settings, err: Error) {
	d := obj.dec_init(b, 0)
	for obj.dec_next(&d) {
		switch d.f.tag {
		case 16:
			s.title = obj.dec_str(&d)
		case 17:
			s.agent = obj.dec_id(&d)
		case 18:
			s.workspace = obj.dec_id(&d)
		case 19:
			s.parent.object = obj.dec_id(&d)
		case 20:
			s.parent.rid.seg = obj.dec_id(&d)
		case 21:
			s.parent.rid.off = obj.dec_int(&d)
		case 24:
			s.parent.rid.gen = obj.dec_uv(&d)
		case 22:
			s.provider = obj.dec_str(&d)
		case 23:
			s.model = obj.dec_str(&d)
		}
	}
	if !obj.dec_ok(&d) {
		return s, .Corrupt
	}
	return s, .None
}

writer_create :: proc(w: ^Writer, v: ^obj.View, vfs: prim.Vfs, path: string, object: prim.Id, participant: prim.Id, gen: u64, created: prim.Hlc, settings: Settings = {}, opts := journal.Options{}, allocator := context.allocator, clock := obj.Clock{}) -> Error {
	_zero(w, allocator)
	obj.writer_create(&w.core, v, vfs, path, object, .Conversation, participant, gen, created, encode_settings(settings), opts, allocator, clock) or_return
	_attach(w)
	kp := _kids_path(path, context.temp_allocator) or_return
	if err := obj.slots_create(&w.kids, vfs, kp, participant, allocator); err != .None {
		_release(w)
		return err
	}
	w.kids.covered = obj.writer_durable(&w.core)
	if err := obj.slots_sync(&w.kids); err != .None {
		_release(w)
		return err
	}
	return .None
}

writer_open :: proc(w: ^Writer, v: ^obj.View, vfs: prim.Vfs, path: string, object: prim.Id, participant: prim.Id, gen: u64, opts := journal.Options{}, allocator := context.allocator, clock := obj.Clock{}) -> (settings: Settings, err: Error) {
	_zero(w, allocator)
	head := obj.writer_open(&w.core, v, vfs, path, object, .Conversation, participant, gen, opts, allocator, clock) or_return
	_attach(w)
	settings, err = decode_settings(head.settings)
	if err == .None {
		err = _recover(w, path)
	}
	if err != .None {
		_release(w)
	}
	return
}

writer_close :: proc(w: ^Writer) -> Error {
	err := writer_commit(w)
	if w.kids.fd >= 0 {
		if e := obj.slots_sync(&w.kids); e != .None && err == .None {
			err = e
		}
	}
	if e := obj.writer_close(&w.core); e != .None && err == .None {
		err = e
	}
	_release(w)
	return err
}

writer_commit :: proc(w: ^Writer) -> Error {
	_flush(w) or_return
	obj.writer_commit(&w.core) or_return
	applied := 0
	err: Error
	for u in w.updates {
		if err = obj.slots_put(&w.kids, u.key, u.child, u.seal); err != .None {
			if err == .Corrupt {
				err = _kids_rebuild(w)
				if err == .None {
					applied = len(w.updates)
				}
			}
			break
		}
		applied += 1
	}
	remove_range(&w.updates, 0, applied)
	if err != .None {
		return err
	}
	w.kids.covered = obj.writer_durable(&w.core)
	if w.kids.covered - w.kids.synced >= CHILD_SYNC_BYTES {
		return obj.slots_sync(&w.kids)
	}
	return .None
}

writer_flush :: proc(w: ^Writer) -> Error {
	return _flush(w)
}

writer_id :: proc "contextless" (w: ^Writer) -> prim.Id {
	return w.core.id
}

writer_summary :: proc "contextless" (w: ^Writer) -> Summary {
	return w.sum
}

writer_observe :: proc(w: ^Writer, hlc: prim.Hlc) {
	obj.observe(&w.core, hlc)
}

writer_sync :: proc(w: ^Writer) -> Error {
	return _prepare(w, true)
}

writer_message :: proc(w: ^Writer, spec: Msg_Spec) -> (msg: Rid, err: Error) {
	return _message(w, spec, 0, 0)
}

writer_block :: proc(w: ^Writer, msg: Rid, kind: Block_Kind, data: []u8 = nil, id := "", name := "", failed := false) -> (index: u32, err: Error) {
	m := _own_msg(w, msg) or_return
	i := _running(w, m) or_return
	if u8(kind) < 1 || kind > max(Block_Kind) {
		return 0, .Invalid
	}
	if len(id) + len(name) > META_MAX || ((kind == .Tool_Result || kind == .Image || kind == .File) && len(data) > INLINE_MAX) {
		return 0, .Too_Large
	}
	if w.sum.open[i].blocks == max(u32) {
		return 0, .Limit
	}
	_flush(w) or_return
	i = summary_find(&w.sum, m)
	b := &w.buf
	clear(&b.meta)
	clear(&b.data)
	append(&b.meta, id)
	append(&b.meta, name)
	if _, e := append(&b.data, ..data); e != nil {
		return 0, .No_Memory
	}
	index = w.sum.open[i].blocks
	w.sum.open[i].blocks += 1
	b.active = true
	b.start = true
	b.msg = m
	b.index = index
	b.kind = kind
	b.flags = {.Failed} if failed else {}
	b.id_len = len(id)
	if len(b.data) >= CHUNK_MAX {
		_flush_full(w, false) or_return
	}
	return index, .None
}

writer_chunk :: proc(w: ^Writer, msg: Rid, index: u32, data: []u8) -> Error {
	m := _own_msg(w, msg) or_return
	i := _running(w, m) or_return
	o := w.sum.open[i]
	if index + 1 != o.blocks {
		return .Invalid
	}
	if len(data) == 0 {
		return .None
	}
	b := &w.buf
	if !(b.active && b.msg == m && b.index == index) {
		_flush(w) or_return
		if o.last == 0 {
			return .Invalid
		}
		body, _ := obj.get(w.core.v, w.core.seg, o.last) or_return
		if obj.is_redacted(body) {
			return .Invalid
		}
		rec := decode_record(body, o.last, w.core.v.scratch) or_return
		blk, ok := rec.body.(Block)
		if !ok || blk.msg != m || blk.index != index {
			return .Invalid
		}
		if .Start in blk.flags && (.Ref in blk.flags || blk.kind == .Tool_Result || blk.kind == .Image || blk.kind == .File) {
			return .Invalid
		}
		clear(&b.meta)
		clear(&b.data)
		b.active = true
		b.start = false
		b.msg = m
		b.index = index
		b.flags = {}
		b.id_len = 0
	}
	if _, e := append(&b.data, ..data); e != nil {
		return .No_Memory
	}
	if len(b.data) >= CHUNK_MAX {
		return _flush_full(w, false)
	}
	return .None
}

writer_block_ref :: proc(w: ^Writer, msg: Rid, kind: Block_Kind, blob: Blob, id := "", name := "", failed := false) -> (index: u32, err: Error) {
	m := _own_msg(w, msg) or_return
	_running(w, m) or_return
	if u8(kind) < 1 || kind > max(Block_Kind) || (len(blob.oid) != 20 && len(blob.oid) != 32) {
		return 0, .Invalid
	}
	if len(id) + len(name) > META_MAX || len(blob.preview) > INLINE_MAX {
		return 0, .Too_Large
	}
	_flush(w) or_return
	off := _prep_off(w, false) or_return
	i := summary_find(&w.sum, m)
	sum := w.sum
	o := &sum.open[i]
	flags := Block_Flags{.Start, .Ref}
	if failed {
		flags += {.Failed}
	}
	blk := Block{
		msg   = m,
		prev  = o.last,
		index = o.blocks,
		flags = flags,
		kind  = kind,
		id    = id,
		name  = name,
		blob  = blob,
	}
	index = o.blocks
	o.blocks += 1
	o.last = off
	_append(w, &sum, blk) or_return
	return index, .None
}

writer_seal :: proc(w: ^Writer, msg: Rid, status: Seal_Status, usage: Usage = {}, native_msg := "", claim: i64 = 0) -> (seal: Rid, err: Error) {
	m := _own_msg(w, msg) or_return
	if status == .Open || status > max(Seal_Status) {
		return {}, .Invalid
	}
	_running(w, m) or_return
	_flush(w) or_return
	off := _prep_off(w, false) or_return
	i := summary_find(&w.sum, m)
	sum := w.sum
	last := sum.open[i].last
	_open_remove(&sum, i)
	sum.last_seal = off
	s := Seal{
		msg        = m,
		last_block = last,
		status     = status,
		usage      = usage,
		native_msg = native_msg,
		hlc        = obj.now(&w.core),
		claim      = claim if claim > 0 && claim < off else 0,
	}
	_append(w, &sum, s) or_return
	_update(w, {key = _ckey(Ref{0, m}), seal = off}) or_return
	return Rid{w.core.id, off, w.core.gen}, .None
}

writer_set_leaf :: proc(w: ^Writer, target: Rid) -> (off: i64, err: Error) {
	_prepare(w, false) or_return
	v := w.core.v
	_, _, _, lit := _positions(v, w.core.id) or_return
	y := Vref{}
	if !obj.rid_none(target) {
		y = _msg_at(v, target) or_return
		n := _node(v, y) or_return
		obj.observe(&w.core, n.hlc)
		_leave(w, lit, y) or_return
	} else if !obj.vref_none(lit.at) && !obj.ref_none(w.sum.leaf) && w.sum.leaf_hlc > w.sum.tip_hlc {
		_keep(w, lit) or_return
	}
	anchor, tdepth := y, i64(0)
	if obj.vref_none(y) && w.sum.tip != 0 {
		anchor = Vref{w.core.seg, w.sum.tip}
	}
	if !obj.vref_none(anchor) {
		na := _node(v, anchor) or_return
		tdepth = na.depth
	}
	spine := _spine_update(w, anchor, tdepth) or_return
	lr := obj.local(&w.core, y) or_return
	obj.seg_flush(&w.core, lr.seg != 0) or_return
	hlc := obj.now(&w.core)
	sum := w.sum
	sum.leaf = lr
	sum.leaf_hlc = hlc
	sum.spine = spine
	return _append(w, &sum, Leaf{msg = lr, hlc = hlc})
}

writer_follow :: proc(w: ^Writer) -> (off: i64, err: Error) {
	return writer_set_leaf(w, {})
}

writer_switch :: proc(w: ^Writer, sibling: Rid) -> (leaf: Rid, off: i64, err: Error) {
	_prepare(w, false) or_return
	t := view_tail(w.core.v, w.core.id, w.core.v.scratch) or_return
	leaf = switch_target(w.core.v, &t, sibling) or_return
	off = writer_set_leaf(w, leaf) or_return
	return leaf, off, .None
}

writer_assign :: proc(w: ^Writer, msg: Rid, runner: prim.Id) -> (off: i64, err: Error) {
	_prepare(w, false) or_return
	x := _msg_at(w.core.v, msg) or_return
	n := _node(w.core.v, x) or_return
	obj.observe(&w.core, n.hlc)
	r := obj.local(&w.core, x) or_return
	return _event(w, Assign{msg = r, runner = runner, hlc = obj.now(&w.core)})
}

writer_claim :: proc(w: ^Writer, msg: Rid, lease_ms: u64, lines: []Line = nil) -> (claim: Rid, err: Error) {
	_prepare(w, false) or_return
	v := w.core.v
	x := _msg_at(v, msg) or_return
	n := _node(v, x) or_return
	obj.observe(&w.core, n.hlc)
	st: Structure
	structure_load(v, nil, n.hlc, &st) or_return
	runner, ahlc := assign_winner(&st, x, n.runner, n.hlc)
	if runner != w.core.id {
		return {}, .Not_Assigned
	}
	r := obj.local(&w.core, x) or_return
	off := _event(w, Claim{msg = r, runner = w.core.id, lease = lease_ms, assign_hlc = ahlc, lines = lines}) or_return
	return Rid{w.core.id, off, w.core.gen}, .None
}

writer_queue :: proc(w: ^Writer, text: string, attachments: []Attachment = nil) -> (item: Rid, err: Error) {
	_check_atts(attachments) or_return
	return _intent(w, Queue{text = text, attachments = attachments})
}

writer_steer :: proc(w: ^Writer, text: string, msg: Rid = {}, attachments: []Attachment = nil) -> (item: Rid, err: Error) {
	_check_atts(attachments) or_return
	_prepare(w, false) or_return
	mr := _local_rid(w, msg) or_return
	return _intent(w, Steer{msg = mr, text = text, attachments = attachments})
}

writer_interrupt :: proc(w: ^Writer, msg: Rid = {}) -> (item: Rid, err: Error) {
	_prepare(w, false) or_return
	mr := _local_rid(w, msg) or_return
	return _intent(w, Interrupt{msg = mr})
}

writer_answer :: proc(w: ^Writer, request: Rid, allow: bool, text := "") -> (item: Rid, err: Error) {
	_prepare(w, false) or_return
	rr := _local_rid(w, request) or_return
	return _intent(w, Answer{request = rr, allow = allow, text = text})
}

writer_await :: proc(w: ^Writer, tasks: []prim.Id, condition: Condition, deadline: prim.Hlc = 0, expr := "") -> (item: Rid, err: Error) {
	if u8(condition) < 1 || condition > max(Condition) {
		return {}, .Invalid
	}
	return _intent(w, Await{tasks = tasks, condition = condition, deadline = deadline, expr = expr})
}

writer_edit_queued :: proc(w: ^Writer, item: Rid, text: string, attachments: []Attachment = nil) -> (off: i64, err: Error) {
	_check_atts(attachments) or_return
	_prepare(w, false) or_return
	r := _local_rid(w, item) or_return
	return _event(w, Edit_Queued{item = r, text = text, attachments = attachments})
}

writer_cancel :: proc(w: ^Writer, item: Rid) -> (off: i64, err: Error) {
	_prepare(w, false) or_return
	r := _local_rid(w, item) or_return
	sum := w.sum
	for p, i in summary_pending(&sum) {
		if p.item == r {
			_pending_remove(&sum, i)
			break
		}
	}
	return _event_sum(w, &sum, Cancel{item = r})
}

writer_unqueue :: proc(w: ^Writer, item: Rid, outcome: Outcome, msg: Rid = {}) -> (off: i64, err: Error) {
	if u8(outcome) < 1 || outcome > max(Outcome) {
		return 0, .Invalid
	}
	_prepare(w, false) or_return
	r := _local_rid(w, item) or_return
	mr := _local_rid(w, msg) or_return
	sum := w.sum
	for p, i in summary_pending(&sum) {
		if p.item == r {
			_pending_remove(&sum, i)
			break
		}
	}
	return _event_sum(w, &sum, Unqueue{item = r, outcome = outcome, msg = mr})
}

writer_superseded :: proc(w: ^Writer, run: Rid, by: Rid) -> (off: i64, err: Error) {
	_prepare(w, false) or_return
	rr := _local_rid(w, run) or_return
	br := _local_rid(w, by) or_return
	return _event(w, Superseded{run = rr, by = br})
}

writer_landed :: proc(w: ^Writer, run: Rid, files: []File_Delta, outcome := Seal_Status.Done) -> (off: i64, err: Error) {
	if outcome == .Open || outcome > max(Seal_Status) {
		return 0, .Invalid
	}
	_prepare(w, false) or_return
	rr := _local_rid(w, run) or_return
	return _event(w, Landed{run = rr, files = files, outcome = outcome})
}

writer_mount :: proc(w: ^Writer, name: string, tree: prim.Id, line: prim.Id, path := "") -> (off: i64, err: Error) {
	if len(name) == 0 {
		return 0, .Invalid
	}
	_prepare(w, false) or_return
	return _event(w, Mount{name = name, tree = tree, line = line, path = path})
}

writer_unmount :: proc(w: ^Writer, name: string) -> (off: i64, err: Error) {
	if len(name) == 0 {
		return 0, .Invalid
	}
	_prepare(w, false) or_return
	return _event(w, Unmount{name = name})
}

writer_compact :: proc(w: ^Writer, from: Rid, to: Rid, summary: string, blob: Blob = {}) -> (off: i64, err: Error) {
	if obj.rid_none(to) {
		return 0, .Invalid
	}
	_prepare(w, false) or_return
	fr := _local_rid(w, from) or_return
	tr := _local_rid(w, to) or_return
	return _event(w, Compact{from = fr, to = tr, summary = summary, blob = blob})
}

writer_scope :: proc(w: ^Writer, msg: Rid, kind: Scope_Kind, id: prim.Id, actor: prim.Id, before, after: []u8) -> (off: i64, err: Error) {
	if u8(kind) < 1 || kind > max(Scope_Kind) {
		return 0, .Invalid
	}
	_flush(w) or_return
	r := _local_rid(w, msg) or_return
	sum := w.sum
	return _append(w, &sum, Scope{msg = r, kind = kind, id = id, actor = actor, before = before, after = after})
}

writer_interrupt_open :: proc(w: ^Writer, now_ms: i64) -> (count: int, err: Error) {
	_flush(w) or_return
	for {
		i := -1
		for k in 0 ..< w.sum.open_len {
			if w.sum.open[k].state == .Running {
				i = k
				break
			}
		}
		if i < 0 {
			return count, .None
		}
		o := w.sum.open[i]
		n := _node(w.core.v, Vref{w.core.seg, o.msg}) or_return
		revive := o.attempt < MAX_REVIVALS && now_ms - prim.hlc_ms(n.hlc) <= REVIVE_WINDOW_MS
		off := _prep_off(w, false) or_return
		sum := w.sum
		if revive {
			sum.open[i].state = .Revive
		} else {
			_open_remove(&sum, i)
		}
		sum.last_seal = off
		_append(w, &sum, Interrupted{msg = o.msg, last_block = o.last, attempt = o.attempt, revive = revive}) or_return
		_update(w, {key = _ckey(Ref{0, o.msg}), seal = off}) or_return
		count += 1
	}
}

writer_revivable :: proc(w: ^Writer) -> (out: [MAX_OPEN]Rid, n: int) {
	for o in summary_open(&w.sum) {
		if o.state == .Revive {
			r, re := obj.rid(w.core.v, Vref{w.core.seg, o.msg})
			if re != .None {
				continue
			}
			out[n] = r
			n += 1
		}
	}
	return
}

writer_revive :: proc(w: ^Writer, msg: Rid, spec: Msg_Spec) -> (reply: Rid, err: Error) {
	m := _own_msg(w, msg) or_return
	i := summary_find(&w.sum, m)
	if i < 0 || w.sum.open[i].state != .Revive {
		return {}, .Invalid
	}
	attempt := w.sum.open[i].attempt
	if attempt >= 63 {
		return {}, .Limit
	}
	_flush(w) or_return
	s := spec
	s.parent = msg
	if s.role == Role(0) {
		s.role = .Assistant
	}
	_check_spec(&s) or_return
	sum := w.sum
	_append(w, &sum, Revived{msg = m, attempt = attempt + 1}) or_return
	return _message(w, s, m, attempt + 1)
}

writer_decline :: proc(w: ^Writer, msg: Rid) -> (off: i64, err: Error) {
	m := _own_msg(w, msg) or_return
	i := summary_find(&w.sum, m)
	if i < 0 || w.sum.open[i].state != .Revive {
		return 0, .Invalid
	}
	_flush(w) or_return
	i = summary_find(&w.sum, m)
	sum := w.sum
	_open_remove(&sum, i)
	return _append(w, &sum, Revived{msg = m})
}

writer_recorded :: proc(w: ^Writer, source, external_id: string) -> (sequence: u64, msg: Rid, found: bool, err: Error) {
	_record_catch_up(w) or_return
	v := w.core.v
	for s in 0 ..< len(v.segs) {
		at: i64
		if s == w.core.seg {
			_, at = _kids_get(w, _record_key(source, external_id)) or_return
		} else {
			_, at = obj.slots_get(&w.kids, _peer_record_key(source, external_id, v.segs[s].id)) or_return
		}
		if at == 0 {
			continue
		}
		body, _ := obj.get(v, s, at) or_return
		if obj.is_redacted(body) {
			continue
		}
		rec := decode_record(body, at, v.scratch) or_return
		r, ok := rec.body.(Recorded)
		if !ok {
			return 0, {}, false, .Corrupt
		}
		if r.source != source || r.external_id != external_id {
			continue
		}
		if found && r.sequence <= sequence {
			continue
		}
		mv := obj.resolve(v, s, r.msg) or_return
		mr := obj.rid(v, mv) or_return
		sequence, msg, found = r.sequence, mr, true
	}
	return
}

@(private)
_peer_record_key :: proc(source, external_id: string, seg: prim.Id) -> u64 {
	id := seg
	h := xxhash.XXH3_64_with_seed(id[:], 0x7065_6572)
	h = xxhash.XXH3_64_with_seed(transmute([]u8)source, h)
	h = xxhash.XXH3_64_with_seed(transmute([]u8)external_id, h)
	return (1 << 63) | (h & ((1 << 63) - 1)) | 1
}

@(private)
_progress_key :: proc(seg: prim.Id) -> u64 {
	id := seg
	h := xxhash.XXH3_64_with_seed(id[:], 0x7072_6f67)
	return (1 << 63) | (h & ((1 << 63) - 1)) | 1
}

@(private)
_record_catch_up :: proc(w: ^Writer) -> Error {
	v := w.core.v
	Ctx :: struct {
		w:     ^Writer,
		from:  i64,
		seg:   prim.Id,
		added: bool,
	}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		c := (^Ctx)(data)
		if off < c.from {
			return true, .None
		}
		if env.kind != u8(Kind.Recorded) {
			return false, .None
		}
		rec := decode_env(env, c.w.core.v.scratch) or_return
		r := rec.body.(Recorded)
		key := _peer_record_key(r.source, r.external_id, c.seg)
		seq := i64(min(r.sequence, u64(max(i64))))
		have, _ := obj.slots_get(&c.w.kids, key) or_return
		if seq > have {
			obj.slots_put(&c.w.kids, key, seq, off) or_return
			c.added = true
		}
		return false, .None
	}
	for s in 0 ..< len(v.segs) {
		if s == w.core.seg {
			continue
		}
		end := obj.end(v, s)
		pk := _progress_key(v.segs[s].id)
		from, _ := obj.slots_get(&w.kids, pk) or_return
		if from >= end {
			continue
		}
		ctx := Ctx{w, from, v.segs[s].id, false}
		obj.walk_events(v, s, 0, &ctx, visit) or_return
		if ctx.added {
			obj.slots_sync(&w.kids) or_return
		}
		obj.slots_put(&w.kids, pk, end, 0) or_return
	}
	return .None
}

writer_record :: proc(w: ^Writer, source, external_id: string, sequence: u64, msg: Rid) -> (receipt: Receipt, err: Error) {
	_prepare(w, false) or_return
	seq, _, found := writer_recorded(w, source, external_id) or_return
	if found {
		if sequence == seq {
			return .Duplicate, .None
		}
		if sequence < seq {
			return .Superseded, .None
		}
	}
	mr := _local_rid(w, msg) or_return
	off := _event(w, Recorded{source = source, external_id = external_id, sequence = sequence, msg = mr}) or_return
	_update(w, {key = _record_key(source, external_id), child = i64(min(sequence, u64(max(i64)))), seal = off}) or_return
	return .Recorded, .None
}

redact_ranges :: proc(v: ^obj.View, msg: Rid, allocator := context.allocator) -> (out: []obj.Redaction, err: Error) {
	x := _msg_at(v, msg) or_return
	m := Message{}
	sa := Vref{}
	last := _seal_info(v, x, {}, false, &m, &sa) or_return
	list := make([dynamic]obj.Redaction, allocator)
	off := last
	for off != 0 {
		body, next := obj.get(v, x.seg, off) or_return
		if obj.is_redacted(body) {
			break
		}
		rec := decode_record(body, off, v.scratch) or_return
		b, ok := rec.body.(Block)
		if !ok || b.msg != x.off {
			return nil, .Corrupt
		}
		if n := len(list); n > 0 && list[n - 1].from == next {
			list[n - 1].from = off
		} else {
			append(&list, obj.Redaction{v.segs[x.seg].id, off, next})
		}
		off = b.prev
	}
	return list[:], .None
}

writer_redact :: proc(w: ^Writer, msg: Rid) -> (ranges: []obj.Redaction, err: Error) {
	_prepare(w, false) or_return
	v := w.core.v
	ranges = redact_ranges(v, msg, v.scratch) or_return
	x := obj.vref_pos(v, msg) or_return
	for r in ranges {
		from := Vref{obj.view_find(v, r.seg), r.from}
		_redact_record(w, from, r.to, x) or_return
	}
	return ranges, .None
}

writer_redact_plan :: proc(w: ^Writer, msg: Rid, allocator := context.allocator) -> (ranges: []obj.Redaction, err: Error) {
	_prepare(w, false) or_return
	return redact_ranges(w.core.v, msg, allocator)
}

writer_redact_range :: proc(w: ^Writer, from: Vref, to: i64, target: Vref) -> Error {
	return _redact_record(w, from, to, target)
}

writer_digest :: proc(w: ^Writer) -> Error {
	_flush(w) or_return
	return _write_digest(w, true)
}

@(private)
_zero :: proc(w: ^Writer, allocator: runtime.Allocator) {
	w^ = {
		allocator = allocator,
	}
	w.kids.fd = prim.INVALID_FD
}

@(private)
_attach :: proc(w: ^Writer) {
	w.buf.meta = make([dynamic]u8, w.allocator)
	w.buf.data = make([dynamic]u8, w.allocator)
	w.updates = make([dynamic]Child_Update, w.allocator)
	w.seen = make([dynamic]i64, w.allocator)
}

@(private)
_release :: proc(w: ^Writer) {
	if w.core.j.fd >= 0 {
		obj.writer_close(&w.core)
	}
	obj.slots_close(&w.kids)
	delete(w.buf.meta)
	delete(w.buf.data)
	delete(w.updates)
	delete(w.seen)
	_zero(w, w.allocator)
}

@(private)
_kids_path :: proc(path: string, allocator: runtime.Allocator) -> (string, Error) {
	out, err := make([]u8, len(path) + len(".children"), allocator)
	if err != nil {
		return "", .No_Memory
	}
	n := copy(out, path)
	copy(out[n:], ".children")
	return string(out), .None
}

@(private)
_recover :: proc(w: ^Writer, path: string) -> Error {
	v := w.core.v
	sum, ok := _tail(v, w.core.seg) or_return
	if ok {
		w.sum = sum
		if last := v.segs[w.core.seg].last; sum.digest != 0 && sum.digest == last {
			_, next := obj.get(v, w.core.seg, last) or_return
			w.sum.digest_len = next - last
			if sum.base == last {
				w.sum.base_len = w.sum.digest_len
			}
		}
	}
	obj.observe(&w.core, w.sum.tip_hlc)
	obj.observe(&w.core, w.sum.leaf_hlc)
	vfs := w.core.vfs
	kp := _kids_path(path, context.temp_allocator) or_return
	if obj.slots_open(&w.kids, vfs, kp, w.core.id, w.allocator) == .None && w.kids.covered <= obj.writer_durable(&w.core) {
		if _kids_catch_up(w, w.kids.covered) == .None {
			return .None
		}
	}
	obj.slots_close(&w.kids)
	obj.slots_create(&w.kids, vfs, kp, w.core.id, w.allocator) or_return
	return _kids_catch_up(w, 0)
}

@(private)
_kids_rebuild :: proc(w: ^Writer) -> Error {
	buf: prim.Path_Buf
	if len(w.kids.path) >= len(buf) {
		return .Invalid
	}
	n := copy(buf[:], w.kids.path)
	kp := string(buf[:n])
	obj.slots_close(&w.kids)
	obj.slots_create(&w.kids, w.core.vfs, kp, w.core.id, w.allocator) or_return
	return _kids_catch_up(w, 0)
}

@(private)
_kids_catch_up :: proc(w: ^Writer, from: i64) -> Error {
	end := obj.writer_durable(&w.core)
	pos := from
	for pos < end {
		body, next, je := obj.jrec_at(&w.core.jr, pos)
		if je != .None {
			return .Corrupt
		}
		k := obj.record_kind(body)
		if !obj.is_redacted(body) && !obj.is_sig(body) && (k == u8(Kind.Msg) || k == u8(Kind.Seal) || k == u8(Kind.Interrupted) || k == u8(Kind.Recorded)) {
			rec, derr := decode_record(body, pos, w.core.v.scratch)
			if derr != .None {
				return .Corrupt
			}
			key: u64
			child, seal: i64
			#partial switch r in rec.body {
			case Msg:
				key, child = _ckey(r.parent), pos
			case Seal:
				key, seal = _ckey(Ref{0, r.msg}), pos
			case Interrupted:
				key, seal = _ckey(Ref{0, r.msg}), pos
			case Recorded:
				key, child, seal = _record_key(r.source, r.external_id), i64(min(r.sequence, u64(max(i64)))), pos
			}
			if key != 0 {
				obj.slots_put(&w.kids, key, child, seal) or_return
			}
		}
		pos = next
	}
	w.kids.covered = end
	return obj.slots_sync(&w.kids)
}

@(private)
_ckey :: proc "contextless" (r: Ref) -> u64 {
	if obj.ref_none(r) {
		return 1 << 62
	}
	return u64(r.seg) << 48 | u64(r.off)
}

@(private)
_record_key :: proc(source, external_id: string) -> u64 {
	h := xxhash.XXH3_64_with_seed(transmute([]u8)source, 0x7265_636f_7264)
	h = xxhash.XXH3_64_with_seed(transmute([]u8)external_id, h)
	return (1 << 63) | (h & ((1 << 63) - 1)) | 1
}

@(private)
_kids_get :: proc(w: ^Writer, key: u64) -> (child: i64, seal: i64, err: Error) {
	#reverse for u in w.updates {
		if u.key == key {
			if child == 0 && u.child != 0 {
				child = u.child
			}
			if seal == 0 && u.seal != 0 {
				seal = u.seal
			}
		}
	}
	c, s, e := obj.slots_get(&w.kids, key)
	if e == .Corrupt {
		_kids_rebuild(w) or_return
		c, s, e = obj.slots_get(&w.kids, key)
	}
	if e != .None {
		return 0, 0, e
	}
	if child == 0 {
		child = c
	}
	if seal == 0 {
		seal = s
	}
	return child, seal, .None
}

@(private)
_update :: proc(w: ^Writer, u: Child_Update) -> Error {
	if _, e := append(&w.updates, u); e != nil {
		return .No_Memory
	}
	if len(w.updates) >= MAX_UPDATES {
		return writer_commit(w)
	}
	return .None
}

@(private)
_own_msg :: proc(w: ^Writer, m: Rid) -> (off: i64, err: Error) {
	if m.seg != w.core.id || m.off <= 0 || m.off >= obj.writer_len(&w.core) {
		return 0, .Invalid
	}
	return m.off, .None
}

@(private)
_running :: proc(w: ^Writer, msg: i64) -> (index: int, err: Error) {
	i := summary_find(&w.sum, msg)
	if i < 0 || w.sum.open[i].state != .Running {
		return -1, .Invalid
	}
	return i, .None
}

@(private)
_check_spec :: proc(s: ^Msg_Spec) -> Error {
	if u8(s.role) < 1 || s.role > max(Role) || (s.root && !obj.rid_none(s.parent)) {
		return .Invalid
	}
	if len(s.files) > MAX_FILES {
		return .Too_Large
	}
	for f in s.files {
		if len(f.mount) == 0 {
			return .Invalid
		}
	}
	return .None
}

@(private)
_check_atts :: proc(attachments: []Attachment) -> Error {
	for a in attachments {
		if len(a.oid) != 0 && len(a.oid) != 20 && len(a.oid) != 32 {
			return .Invalid
		}
	}
	return .None
}

@(private)
_local_rid :: proc(w: ^Writer, r: Rid) -> (out: Ref, err: Error) {
	if obj.rid_none(r) {
		return {}, .None
	}
	x := obj.vref(w.core.v, r) or_return
	if x.off >= obj.end(w.core.v, x.seg) {
		return {}, .Invalid
	}
	return obj.local(&w.core, x)
}

@(private)
_prep_off :: proc(w: ^Writer, cross: bool) -> (off: i64, err: Error) {
	obj.seg_flush(&w.core, cross) or_return
	return obj.writer_len(&w.core), .None
}

@(private)
_cross :: proc "contextless" (k: Kind) -> bool {
	#partial switch k {
	case .Block, .Seal, .Interrupted, .Revived, .Files:
		return false
	}
	return true
}

@(private)
_append :: proc(w: ^Writer, sum: ^Summary, body: Body) -> (off: i64, err: Error) {
	k := body_kind(body)
	#partial switch k {
	case .Fork, .Remember, .Assign, .Superseded, .Landed, .Mount, .Unmount:
		sum.since += 1
	}
	rec := obj.begin(&w.core, u8(k), _cross(k), is_event_kind(k)) or_return
	if k == .Forks {
		sum.digest_hlc = rec.links.stamp
	}
	extra := encode_summary(rec.off, sum)
	obj.put_links(&rec, extra)
	encode_fields(&rec.pw, rec.off, body)
	if rec.pw.err != .None {
		obj.abort(&w.core, &rec)
		return 0, .No_Memory
	}
	off = obj.finish(&w.core, &rec) or_return
	w.sum = sum^
	if k != .Forks && k != .Spine {
		if int(w.sum.since) >= max(DIGEST_EVERY, int(w.sum.digest_size) / DIGEST_RATIO) {
			_write_digest(w, true) or_return
		} else if is_event_kind(k) && journal.journal_len(&w.core.j) - w.sum.digest > DIGEST_BYTES {
			_write_digest(w, w.sum.digest == 0) or_return
		}
	}
	return off, .None
}

@(private)
_event :: proc(w: ^Writer, body: Body) -> (off: i64, err: Error) {
	sum := w.sum
	return _event_sum(w, &sum, body)
}

@(private)
_event_sum :: proc(w: ^Writer, sum: ^Summary, body: Body) -> (off: i64, err: Error) {
	k := body_kind(body)
	if !is_event_kind(k) {
		return 0, .Invalid
	}
	return _append(w, sum, body)
}

@(private)
_intent :: proc(w: ^Writer, body: Body) -> (item: Rid, err: Error) {
	_prepare(w, false) or_return
	if w.sum.pending_len >= MAX_PENDING {
		return {}, .Limit
	}
	off := _prep_off(w, true) or_return
	sum := w.sum
	sum.pending[sum.pending_len] = Pending_Entry{Ref{0, off}, Ref{0, off}}
	sum.pending_len += 1
	got := _append(w, &sum, body) or_return
	if got != off {
		return {}, .Io
	}
	return Rid{w.core.id, off, w.core.gen}, .None
}

@(private)
_redact_record :: proc(w: ^Writer, from: Vref, to: i64, target: Vref) -> Error {
	_flush(w) or_return
	obj.local(&w.core, from) or_return
	obj.local(&w.core, target) or_return
	obj.seg_flush(&w.core, true) or_return
	off := obj.writer_len(&w.core)
	extra := encode_summary(off, &w.sum)
	obj.writer_redact(&w.core, from, to, target, extra) or_return
	return .None
}

@(private)
_write_digest :: proc(w: ^Writer, full: bool) -> Error {
	v := w.core.v
	Ctx :: struct {
		v:          ^obj.View,
		full:       bool,
		forks:      [dynamic]Remember,
		index:      map[[3]Ref]int,
		assigns:    [dynamic]Digest_Assign,
		mounts:     [dynamic]Digest_Mount,
		superseded: [dynamic]Superseded,
		landed:     [dynamic]Digest_Landed,
		heads:      map[i64]Spine_Head,
		prior:      Spine_Index,
		base:       i64,
		base_len:   i64,
		base_hlc:   prim.Hlc,
		need_base:  bool,
		base_spine: Spine_Index,
		delta:      bool,
	}
	ctx := Ctx{
		heads      = make(map[i64]Spine_Head, v.scratch),
		v          = v,
		full       = full,
		forks      = make([dynamic]Remember, v.scratch),
		index      = make(map[[3]Ref]int, v.scratch),
		assigns    = make([dynamic]Digest_Assign, v.scratch),
		mounts     = make([dynamic]Digest_Mount, v.scratch),
		superseded = make([dynamic]Superseded, v.scratch),
		landed     = make([dynamic]Digest_Landed, v.scratch),
	}
	add :: proc(c: ^Ctx, d: Remember) {
		key := [3]Ref{d.parent, d.child, d.leaf}
		if i, ok := c.index[key]; ok {
			cur := &c.forks[i]
			hlc := cur.child_hlc
			if d.leaf_hlc > cur.leaf_hlc {
				cur^ = d
			}
			if cur.child_hlc == 0 {
				cur.child_hlc = hlc if hlc != 0 else d.child_hlc
			}
			return
		}
		c.index[key] = len(c.forks)
		append(&c.forks, d)
	}
	add_all :: proc(c: ^Ctx, r: Forks) -> Error {
		for d in r.forks {
			add(c, d)
		}
		append(&c.assigns, ..r.assigns)
		for mt in r.mounts {
			x := mt
			x.name = obj.clone_str(mt.name, c.v.scratch) or_return
			x.path = obj.clone_str(mt.path, c.v.scratch) or_return
			append(&c.mounts, x)
		}
		append(&c.superseded, ..r.superseded)
		append(&c.landed, ..r.landed)
		return .None
	}
	visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
		c := (^Ctx)(data)
		if env.kind < obj.RECORD_KIND_FIRST {
			return false, .None
		}
		rec := decode_env(env, c.v.scratch) or_return
		#partial switch r in rec.body {
		case Spine:
			c.heads[off] = Spine_Head{r.prev, r.c, r.first}
		case Forks:
			c.prior = r.spine
			c.prior.blocks = make([]i64, len(r.spine.blocks), c.v.scratch)
			copy(c.prior.blocks, r.spine.blocks)
			c.delta = r.base != 0
			if r.base == 0 {
				c.base = off
				c.base_hlc = rec.stamp
				if c.full {
					add_all(c, r) or_return
				}
				return true, .None
			}
			add_all(c, r) or_return
			c.base = r.base
			c.base_len = r.base_len
			c.base_hlc = r.base_hlc
			c.need_base = c.full
			return true, .None
		case Fork:
			add(c, Remember{parent = r.parent, child = r.child, child_hlc = r.child_hlc})
		case Remember:
			add(c, r)
		case Assign:
			append(&c.assigns, Digest_Assign{r.msg, r.runner, r.hlc})
		case Superseded:
			append(&c.superseded, r)
		case Landed:
			append(&c.landed, Digest_Landed{r.run, r.outcome})
		case Mount:
			name := obj.clone_str(r.name, c.v.scratch) or_return
			path := obj.clone_str(r.path, c.v.scratch) or_return
			append(&c.mounts, Digest_Mount{name, r.tree, r.line, path, rec.stamp, false})
		case Unmount:
			name := obj.clone_str(r.name, c.v.scratch) or_return
			append(&c.mounts, Digest_Mount{name = name, stamp = rec.stamp, removed = true})
		}
		return false, .None
	}
	obj.walk_events(v, w.core.seg, 0, &ctx, visit) or_return
	if ctx.need_base {
		raw, _ := obj.get(v, w.core.seg, ctx.base) or_return
		body := obj.clone_bytes(raw, v.scratch) or_return
		rec := decode_record(body, ctx.base, v.scratch) or_return
		r, ok := rec.body.(Forks)
		if !ok || r.base != 0 {
			return .Corrupt
		}
		add_all(&ctx, r) or_return
		ctx.base_spine = r.spine
	}
	is_full := full || ctx.base == 0
	n := 0
	for a, i in ctx.assigns {
		keep := true
		for b, k in ctx.assigns {
			if k != i && b.msg == a.msg && (b.hlc > a.hlc || (b.hlc == a.hlc && k < i)) {
				keep = false
				break
			}
		}
		if keep {
			ctx.assigns[n] = a
			n += 1
		}
	}
	resize(&ctx.assigns, n)
	n = 0
	for a, i in ctx.mounts {
		keep := true
		for b, k in ctx.mounts {
			if k != i && b.name == a.name && (b.stamp > a.stamp || (b.stamp == a.stamp && k < i)) {
				keep = false
				break
			}
		}
		if keep {
			ctx.mounts[n] = a
			n += 1
		}
	}
	resize(&ctx.mounts, n)
	sc, sb, low, complete := spine_resolve(ctx.heads, w.sum.spine, &ctx.prior, v.scratch)
	spine := Spine_Index{}
	if complete {
		first := low
		if ctx.delta {
			first = min(first, ctx.prior.first)
		} else if ctx.prior.at == 0 && ctx.prior.c == 0 {
			first = 0
		}
		if is_full {
			for k in 0 ..< len(sb) {
				if sb[k] == 0 && ctx.base_spine.first == 0 && k < len(ctx.base_spine.blocks) {
					sb[k] = ctx.base_spine.blocks[k]
				}
			}
			first = 0
		}
		ok := true
		for x in sb[first:] {
			ok &&= x != 0
		}
		if ok {
			spine = Spine_Index{w.sum.spine, sc, first, sb[first:]}
		}
	}
	digest := Forks{ctx.forks[:], ctx.assigns[:], ctx.mounts[:], ctx.superseded[:], ctx.landed[:], spine, 0, 0, 0}
	off := _prep_off(w, true) or_return
	sum := w.sum
	sum.digest = off
	if is_full {
		sum.since = 0
		sum.base = off
		sum.digest_size = u32(min(u64(len(ctx.forks) + len(ctx.assigns) + len(ctx.mounts) + len(ctx.superseded) + len(ctx.landed)), u64(max(u32))))
	} else {
		digest.base = ctx.base
		digest.base_len = w.sum.base_len
		digest.base_hlc = ctx.base_hlc
	}
	_append(w, &sum, digest) or_return
	size := journal.journal_len(&w.core.j) - off
	w.sum.digest_len = size
	if is_full {
		w.sum.base_len = size
	}
	return .None
}

@(private)
_prepare :: proc(w: ^Writer, force: bool) -> Error {
	_flush(w) or_return
	v := w.core.v
	changed := force
	for len(w.seen) < len(v.segs) {
		append(&w.seen, -1)
	}
	for s in 0 ..< len(v.segs) {
		if s != w.core.seg && w.seen[s] != obj.end(v, s) {
			changed = true
		}
	}
	if !changed {
		return .None
	}
	complete := true
	for s in 0 ..< len(v.segs) {
		if s == w.core.seg {
			continue
		}
		sum, ok, te := _tail(v, s)
		if te == .Missing {
			complete = false
			continue
		}
		if te != .None {
			return te
		}
		if ok {
			obj.observe(&w.core, sum.tip_hlc)
			obj.observe(&w.core, sum.leaf_hlc)
		}
	}
	if e := _ack_pending(w); e == .Missing {
		complete = false
	} else if e != .None {
		return e
	}
	if complete {
		for s in 0 ..< len(v.segs) {
			w.seen[s] = obj.end(v, s)
		}
	}
	return .None
}

@(private)
Ack_Ctx :: struct {
	v:       ^obj.View,
	item:    Vref,
	found:   bool,
	cause:   Vref,
	outcome: Outcome,
	msg:     Vref,
}

@(private)
_ack_pending :: proc(w: ^Writer) -> Error {
	if w.sum.pending_len == 0 {
		return .None
	}
	v := w.core.v
	for k := 0; k < w.sum.pending_len; {
		p := w.sum.pending[k]
		if p.item.seg != 0 {
			k += 1
			continue
		}
		env, red := obj.envelope(v, w.core.seg, p.item.off) or_return
		if red {
			k += 1
			continue
		}
		ctx := Ack_Ctx{
			v    = v,
			item = Vref{w.core.seg, p.item.off},
		}
		visit :: proc(data: rawptr, s: int, off: i64, env: ^obj.Envelope) -> (stop: bool, err: Error) {
			c := (^Ack_Ctx)(data)
			k := Kind(env.kind)
			if k != .Unqueue && k != .Cancel {
				return false, .None
			}
			rec := decode_env(env, c.v.scratch) or_return
			item: Ref
			outcome := Outcome.Cancelled
			msg: Ref
			#partial switch r in rec.body {
			case Unqueue:
				item, outcome, msg = r.item, r.outcome, r.msg
			case Cancel:
				item = r.item
			}
			it, re := obj.resolve(c.v, s, item)
			if re != .None || it != c.item {
				return false, .None
			}
			c.found = true
			c.cause = Vref{s, off}
			c.outcome = outcome
			c.msg, _ = obj.resolve(c.v, s, msg)
			return true, .None
		}
		for s in 0 ..< len(v.segs) {
			if s == w.core.seg || ctx.found {
				continue
			}
			obj.walk_events(v, s, env.links.stamp, &ctx, visit) or_return
		}
		if !ctx.found {
			k += 1
			continue
		}
		cr := obj.local(&w.core, ctx.cause) or_return
		mr := obj.local(&w.core, ctx.msg) or_return
		sum := w.sum
		_pending_remove(&sum, k)
		_event_sum(w, &sum, Unqueue{item = p.item, outcome = ctx.outcome, msg = mr, cause = cr}) or_return
	}
	return .None
}

@(private)
_is_fork_point :: proc(st: ^Structure, p: Vref) -> bool {
	for e in st.entries {
		if e.parent == p {
			return true
		}
	}
	return false
}

@(private)
_keep :: proc(w: ^Writer, at: Pos) -> Error {
	v := w.core.v
	n := _node(v, at.at) or_return
	root := level_ancestor(v, at.at, 1) or_return
	cr := obj.local(&w.core, root.ref) or_return
	lr := obj.local(&w.core, at.at) or_return
	rem := Remember{child = cr, child_hlc = root.hlc, leaf = lr, leaf_hlc = at.hlc, child_depth = 1, leaf_depth = n.depth}
	_branch(w, at.at, &rem) or_return
	_, err := _event(w, rem)
	return err
}

@(private)
_branch :: proc(w: ^Writer, leaf: Vref, r: ^Remember) -> Error {
	v := w.core.v
	n := r.leaf_depth - r.child_depth - 1
	if n <= 0 {
		return .None
	}
	start := r.child_depth + 1
	if n > BRANCH_INLINE {
		st: Structure
		structure_load(v, nil, 0, &st) or_return
		for s in 0 ..< len(st.spines) {
			sp := _spine_get(v, &st, s) or_return
			if sp == nil || !sp.ready || sp.target != leaf {
				continue
			}
			k0 := r.child_depth / SPINE_SPAN
			kc := min(sp.c, r.leaf_depth - 1) / SPINE_SPAN
			if kc <= k0 {
				break
			}
			blocks := sp.blocks[k0:kc]
			ok := true
			for b in blocks {
				ok &&= b != 0
			}
			if !ok {
				break
			}
			r.blocks = blocks
			r.covered = kc * SPINE_SPAN
			r.bseg = (obj.local(&w.core, Vref{s, blocks[0]}) or_return).seg
			start = r.covered + 1
			break
		}
		if len(r.blocks) == 0 && n > BRANCH_MAX {
			_branch_blocks(w, &st, leaf, r) or_return
			start = max(start, r.covered + 1)
		}
	}
	count := r.leaf_depth - start
	if count <= 0 {
		return .None
	}
	nodes := make([]Ref, count, v.scratch)
	cur := _node(v, leaf) or_return
	for i := count - 1; i >= 0; i -= 1 {
		cur = _node(v, cur.parent) or_return
		nodes[i] = obj.local(&w.core, cur.ref) or_return
	}
	r.branch = spine_encode(nodes, v.scratch)
	return .None
}

@(private)
_leave :: proc(w: ^Writer, from: Pos, to: Vref) -> Error {
	v := w.core.v
	x := from.at
	if obj.vref_none(x) || x == to {
		return .None
	}
	a := lca(v, x, to) or_return
	if a == x {
		return .None
	}
	adepth: i64 = 0
	floor: prim.Hlc
	if !obj.vref_none(a) {
		na := _node(v, a) or_return
		adepth = na.depth
		floor = na.hlc
	}
	obj.observe(&w.core, from.hlc)
	nx := _node(v, x) or_return
	c := level_ancestor(v, x, adepth + 1) or_return
	pr := obj.local(&w.core, a) or_return
	cr := obj.local(&w.core, c.ref) or_return
	lr := obj.local(&w.core, x) or_return
	rem := Remember{parent = pr, child = cr, child_hlc = c.hlc, leaf = lr, leaf_hlc = from.hlc, child_depth = adepth + 1, leaf_depth = nx.depth}
	_branch(w, x, &rem) or_return
	_event(w, rem) or_return
	if to == a || obj.vref_none(to) {
		return .None
	}
	st: Structure
	structure_load(v, nil, floor, &st) or_return
	cy := level_ancestor(v, to, adepth + 1) or_return
	if _, ok := entry_find(&st, a, cy.ref); ok {
		return .None
	}
	yr := obj.local(&w.core, cy.ref) or_return
	_, err := _event(w, Fork{parent = pr, child = yr, child_hlc = cy.hlc})
	return err
}

@(private)
_message :: proc(w: ^Writer, spec: Msg_Spec, retire: i64, attempt: u8) -> (msg: Rid, err: Error) {
	s := spec
	_check_spec(&s) or_return
	_prepare(w, false) or_return
	v := w.core.v
	pos, _, _, lit := _positions(v, w.core.id) or_return
	p := pos.at
	if s.root {
		p = {}
	} else if !obj.rid_none(s.parent) {
		p = _msg_at(v, s.parent) or_return
	}
	depth, jump_depth: i64 = 1, 0
	jump := Vref{}
	files_prev := Vref{}
	np: Node
	if !obj.vref_none(p) {
		np = _node(v, p) or_return
		obj.observe(&w.core, np.hlc)
		depth = np.depth + 1
		jump, jump_depth = p, np.depth
		if !obj.vref_none(np.jump) {
			nj := _node(v, np.jump) or_return
			if np.depth - np.jump_depth == np.jump_depth - nj.jump_depth {
				jump, jump_depth = nj.jump, nj.jump_depth
			}
		}
		files_prev = p if np.files else np.files_prev
	}
	files_run: u32
	files_base: []File_Delta
	files_more: i64
	if len(s.files) > 0 && !obj.vref_none(files_prev) {
		fp := np if files_prev == p else (_node(v, files_prev) or_return)
		files_run = fp.files_run + 1
		if files_run >= FILES_SNAPSHOT {
			state := _files_walk(v, files_prev, nil, v.scratch) or_return
			base := make([dynamic]File_Delta, v.scratch)
			for f in state {
				own := false
				for g in s.files {
					own ||= g.mount == f.mount
				}
				if !own {
					append(&base, f)
				}
			}
			files_run = 0
			files_base = base[:]
			for len(files_base) > MAX_FILES {
				chunk := files_base[len(files_base) - MAX_FILES:]
				files_base = files_base[:len(files_base) - MAX_FILES]
				files_more = _append(w, &w.sum, Files{files = chunk, next = files_more}) or_return
			}
		}
	}
	st: Structure
	structure_load(v, nil, np.hlc, &st) or_return
	other := _is_fork_point(&st, p)
	pr := obj.local(&w.core, p) or_return
	if !other && !obj.vref_none(p) {
		c, _ := _kids_get(w, _ckey(pr)) or_return
		other = c != 0
	}
	if !other && !obj.vref_none(pos.at) && pos.at != p && !obj.vref_none(p) {
		other = is_ancestor(v, p, pos.at) or_return
	}
	if !other && obj.vref_none(p) && (w.sum.tip != 0 || !obj.vref_none(pos.at)) {
		other = true
	}
	if !obj.vref_none(lit.at) && lit.at != p {
		_leave(w, lit, p) or_return
	}
	if w.sum.tip != 0 {
		tip := Vref{w.core.seg, w.sum.tip}
		if tip != lit.at && tip != p {
			_leave(w, Pos{tip, w.sum.tip_hlc, w.core.id}, p) or_return
		}
	}
	spine := _spine_update(w, p, depth) or_return
	pseal := Vref{}
	if !obj.vref_none(p) {
		if p.seg == w.core.seg {
			if summary_find(&w.sum, p.off) < 0 {
				_, so := _kids_get(w, _ckey(Ref{0, p.off})) or_return
				if so != 0 {
					pseal = Vref{w.core.seg, so}
				}
			}
		} else {
			m := Message{}
			sa := Vref{}
			if _, e := _seal_info(v, p, {}, false, &m, &sa); e == .None {
				pseal = sa
			} else if e != .Missing {
				return {}, e
			}
		}
	}
	pr = obj.local(&w.core, p) or_return
	jr := obj.local(&w.core, jump) or_return
	sr := obj.local(&w.core, pseal) or_return
	fr := obj.local(&w.core, files_prev) or_return
	ir := _local_rid(w, s.intent) or_return
	off := _prep_off(w, true) or_return
	hlc := obj.now(&w.core)
	sum := w.sum
	if retire != 0 {
		if k := summary_find(&sum, retire); k >= 0 {
			_open_remove(&sum, k)
		}
	}
	if sum.open_len >= MAX_OPEN {
		return {}, .Limit
	}
	sum.open[sum.open_len] = Open{
		msg     = off,
		state   = .Running,
		attempt = attempt,
	}
	sum.open_len += 1
	sum.tip = off
	sum.tip_hlc = hlc
	sum.spine = spine
	author := s.author if !prim.id_is_zero(s.author) else w.core.id
	m := Msg{
		role        = s.role,
		author      = author,
		parent      = pr,
		depth       = depth,
		jump        = jr,
		jump_depth  = jump_depth,
		hlc         = hlc,
		files       = s.files,
		provider    = s.provider,
		model       = s.model,
		native      = s.native,
		native_msg  = s.native_msg,
		runner      = s.runner,
		intent      = ir,
		parent_seal = sr,
		claim       = s.claim if s.claim > 0 && s.claim < off else 0,
		files_prev  = fr,
		files_run   = files_run,
		files_base  = files_base,
		files_more  = files_more,
	}
	got := _append(w, &sum, m) or_return
	if got != off {
		return {}, .Io
	}
	_update(w, {key = _ckey(pr), child = off}) or_return
	if other {
		_event(w, Fork{parent = pr, child = Ref{0, off}, child_hlc = hlc}) or_return
	}
	return Rid{w.core.id, off, w.core.gen}, .None
}

@(private)
_flush :: proc(w: ^Writer) -> Error {
	if !w.buf.active {
		return .None
	}
	return _flush_full(w, true)
}

@(private)
_flush_full :: proc(w: ^Writer, all: bool) -> Error {
	b := &w.buf
	for b.active && (len(b.data) >= CHUNK_MAX || all) {
		i := summary_find(&w.sum, b.msg)
		if i < 0 {
			b.active = false
			return .Invalid
		}
		n := min(len(b.data), CHUNK_MAX)
		off := _prep_off(w, false) or_return
		sum := w.sum
		o := &sum.open[i]
		blk := Block{
			msg   = b.msg,
			prev  = o.last,
			index = b.index,
			data  = b.data[:n],
		}
		if b.start {
			blk.flags = b.flags + {.Start}
			blk.kind = b.kind
			blk.id = string(b.meta[:b.id_len])
			blk.name = string(b.meta[b.id_len:])
		}
		o.last = off
		got := _append(w, &sum, blk) or_return
		if got != off {
			return .Io
		}
		b.start = false
		remove_range(&b.data, 0, n)
		if len(b.data) == 0 {
			b.active = false
		}
	}
	if !b.active {
		if cap(b.data) > BUF_KEEP {
			delete(b.data)
			b.data = make([dynamic]u8, w.allocator)
		}
		clear(&b.meta)
	}
	return .None
}

@(private)
_spine_update :: proc(w: ^Writer, anchor: Vref, tdepth: i64) -> (spine: i64, err: Error) {
	v := w.core.v
	cnew := max(tdepth - 1, 0) / SPINE_SPAN * SPINE_SPAN
	old := w.sum.spine
	cold: i64
	told: Vref
	if old != 0 {
		body, _ := obj.get(v, w.core.seg, old) or_return
		if !obj.is_redacted(body) {
			rec := decode_record(body, old, v.scratch) or_return
			sp, ok := rec.body.(Spine)
			if !ok {
				return 0, .Corrupt
			}
			cold = sp.c
			told = obj.resolve(v, w.core.seg, sp.target) or_return
		}
	}
	keep: i64
	if cold > 0 && cnew > 0 && !obj.vref_none(told) && !obj.vref_none(anchor) {
		a := lca(v, told, anchor) or_return
		if !obj.vref_none(a) {
			na := _node(v, a) or_return
			keep = min(na.depth, cold, cnew) / SPINE_SPAN * SPINE_SPAN
		}
	}
	if cnew == cold && keep == cnew && (old != 0 || cnew == 0) {
		return old, .None
	}
	nodes := make([]Ref, cnew - keep, v.scratch)
	if cnew > keep {
		n := level_ancestor(v, anchor, cnew) or_return
		for i := len(nodes) - 1; i >= 0; i -= 1 {
			nodes[i] = obj.local(&w.core, n.ref) or_return
			if i > 0 {
				n = _node(v, n.parent) or_return
			}
		}
	}
	tr := obj.local(&w.core, anchor) or_return
	return _event(w, Spine{target = tr, prev = old, c = cnew, first = keep / SPINE_SPAN, nodes = spine_encode(nodes, v.scratch)})
}

@(private)
_branch_blocks :: proc(w: ^Writer, st: ^Structure, leaf: Vref, r: ^Remember) -> Error {
	v := w.core.v
	k0 := r.child_depth / SPINE_SPAN
	kc := (r.leaf_depth - 1) / SPINE_SPAN
	if kc <= k0 {
		return .None
	}
	best, depth: i64 = -1, 0
	for s in 0 ..< len(st.spines) {
		sp := _spine_get(v, st, s) or_return
		if sp == nil || !sp.ready || obj.vref_none(sp.target) {
			continue
		}
		a := lca(v, leaf, sp.target) or_return
		if obj.vref_none(a) {
			continue
		}
		na := _node(v, a) or_return
		if l := min(na.depth, sp.c); l > depth {
			best, depth = i64(s), l
		}
	}
	blocks := make([dynamic]i64, v.scratch)
	segs := make([dynamic]u32, v.scratch)
	k := k0
	if best >= 0 {
		sp := &st.spines[best]
		for ; k < kc && (k + 1) * SPINE_SPAN <= depth && sp.blocks[k] != 0; k += 1 {
			ref := obj.local(&w.core, Vref{int(best), sp.blocks[k]}) or_return
			append(&blocks, ref.off)
			append(&segs, ref.seg)
		}
	}
	if k < kc {
		nodes := make([]Ref, (kc - k) * SPINE_SPAN, v.scratch)
		n := level_ancestor(v, leaf, kc * SPINE_SPAN) or_return
		for i := len(nodes) - 1; i >= 0; i -= 1 {
			nodes[i] = obj.local(&w.core, n.ref) or_return
			if i > 0 {
				n = _node(v, n.parent) or_return
			}
		}
		tr := obj.local(&w.core, leaf) or_return
		off := _event(w, Spine{target = tr, c = kc * SPINE_SPAN, first = k, nodes = spine_encode(nodes, v.scratch)}) or_return
		for _ in k ..< kc {
			append(&blocks, off)
			append(&segs, 0)
		}
	}
	r.blocks = blocks[:]
	r.covered = kc * SPINE_SPAN
	r.bseg = segs[0]
	mixed := false
	for x in segs {
		mixed ||= x != segs[0]
	}
	if mixed {
		r.bsegs = segs[:]
	}
	return .None
}

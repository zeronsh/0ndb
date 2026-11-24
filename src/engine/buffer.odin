package engine

import "core:crypto/hash"
import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fs"
import "../fstree"
import "../prim"
import osync "../sync"

Buffer_Id :: distinct u64

Units :: enum u8 {
	Bytes,
	Utf16,
}

Buffer_Edit :: struct {
	pos: int,
	del: int,
	ins: []u8,
}

Buffer_Event_Kind :: enum u8 {
	Delta,
	Cursors,
	Closed,
}

Cursor_Range :: struct {
	anchor: int,
	head:   int,
}

Remote_Cursor :: struct {
	device: prim.Id,
	actor:  prim.Id,
	ranges: []Cursor_Range,
}

Buffer_Event :: struct {
	kind:    Buffer_Event_Kind,
	buffer:  Buffer_Id,
	rev:     u64,
	ack:     u64,
	length:  int,
	ops:     []crdt.Delta_Op,
	cursors: []Remote_Cursor,
	err:     Error,
}

Buffer_Proc :: #type proc(data: rawptr, e: ^Engine, ev: ^Buffer_Event)
Buffer_Ready :: #type proc(data: rawptr) -> bool

Buffer_Options :: struct {
	path:  string,
	line:  string,
	units: Units,
	actor: prim.Id,
	page:  int,
	cb:    Buffer_Proc,
	data:  rawptr,
	ready: Buffer_Ready,
	wait:  Ready,
}

Buffer_Info :: struct {
	id:     Buffer_Id,
	rev:    u64,
	length: int,
	page:   []u8,
	more:   bool,
	actor:  prim.Id,
	line:   string,
}

Buffer_Read :: struct {
	rev:    u64,
	ack:    u64,
	from:   int,
	length: int,
	text:   []u8,
}

BUFFER_KEEP_DELTAS :: 4096
BUFFER_KEEP_BYTES :: 8 << 20

@(private)
Sent :: struct {
	rev:   u64,
	ops:   []crdt.Delta_Op,
	bytes: int,
	gone:  []Gone,
}

@(private)
Undo_Del :: struct {
	runs: [dynamic]crdt.Op_Span,
}

@(private)
Undo_Group :: struct {
	id:      u64,
	inserts: [dynamic]crdt.Op_Span,
	deletes: [dynamic]Undo_Del,
}

@(private)
Buffer :: struct {
	id:         Buffer_Id,
	object:     Object,
	kind:       Kind,
	inode:      fstree.Inode_Id,
	line:       string,
	units:      Units,
	base:       prim.Id,
	actor:      prim.Id,
	cb:         Buffer_Proc,
	data:       rawptr,
	ready:      Buffer_Ready,
	view:       ^fs.Text_View,
	hist:       ^fs.History,
	version:    [dynamic]crdt.Op_Id,
	rev:        u64,
	recv:       u64,
	floor:      u64,
	sent:       [dynamic]Sent,
	sent_bytes: int,
	dirty:      bool,
	undo:       [dynamic]Undo_Group,
	redo:       [dynamic]Undo_Group,
	cursors:    [dynamic]Cursor_Set,
	mine:       [dynamic][2]Anchor,
	mine_dirty: bool,
	mine_seq:   u64,
	ovl:        [dynamic]^Ovl,
	oc:         [dynamic]crdt.Delta_Op,
	held:       [dynamic]Ready,
	pend:       [dynamic]Pend,
	peers:      [dynamic]prim.Id,
	shown:      u64,
}

editor_actor :: proc(e: ^Engine, line := "") -> (id: prim.Id) {
	self := e.self
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	hash.update(&ctx, transmute([]u8)string("0ndb-editor"))
	hash.update(&ctx, self[:])
	hash.update(&ctx, transmute([]u8)line)
	out: [32]u8
	hash.final(&ctx, out[:])
	copy(id[:], out[:16])
	return
}

@(private)
_buffer_find :: proc(e: ^Engine, id: Buffer_Id) -> ^Buffer {
	for b in e.buffers {
		if b.id == id {
			return b
		}
	}
	return nil
}

@(private)
_utf16 :: #force_inline proc "contextless" (b: ^Buffer) -> bool {
	return b.units == .Utf16
}

@(private)
_to_bytes :: proc(b: ^Buffer, u: int) -> int {
	if b.units == .Bytes {
		return u
	}
	if _ovl_on(b) {
		return _disp_byte_at(b, u)
	}
	return crdt.text_byte_at(&b.view.text, u)
}

@(private)
_unit_boundary :: proc(b: ^Buffer, u: int) -> bool {
	p := _to_bytes(b, u)
	if b.units == .Utf16 && _to_units(b, p) != u {
		return false
	}
	if p <= 0 || p >= _disp_len(b) {
		return true
	}
	c: [1]u8
	_disp_read(b, p, c[:])
	return c[0] & 0xc0 != 0x80
}

@(private)
_edit_bounds_ok :: proc(b: ^Buffer, d: []crdt.Delta_Op) -> bool {
	u := 0
	for o in d {
		switch o.kind {
		case .Retain, .Delete:
			if !_unit_boundary(b, u) {
				return false
			}
			u += o.n
			if !_unit_boundary(b, u) {
				return false
			}
		case .Insert:
		}
	}
	return true
}

@(private)
_to_units :: proc(b: ^Buffer, pos: int) -> int {
	if b.units == .Bytes {
		return pos
	}
	if _ovl_on(b) {
		return _disp_units_at(b, pos)
	}
	return crdt.text_units_at(&b.view.text, pos)
}

@(private)
_length :: proc(b: ^Buffer) -> int {
	if _ovl_on(b) {
		return _disp_len(b) if b.units == .Bytes else _disp_units(b)
	}
	if b.units == .Bytes {
		return crdt.text_len(&b.view.text)
	}
	return crdt.text_units(&b.view.text)
}

@(private)
_buffer_target :: proc(b: ^Buffer, h: ^Handle) -> (v: fs.Version, err: Error) {
	if b.kind == .Text {
		return fs.history_heads(h.hist, context.temp_allocator), .None
	}
	lv, found, lerr := fs.history_line(h.hist, b.line, context.temp_allocator)
	if lerr != .None {
		return nil, _ferr(lerr)
	}
	if !found {
		return fs.history_heads(h.hist, context.temp_allocator), .None
	}
	return lv, .None
}

@(private)
_buffer_follow :: proc(e: ^Engine, h: ^Handle) {
	_handle_refresh(h)
	_group_follow(h, true)
	for sg in h.segs {
		_follow(e, h, sg, false)
	}
}

@(private)
_buffer_wait :: proc(e: ^Engine, h: ^Handle, err: Error, wait: Ready) -> Error {
	r := _pending_result(e, h, err, wait)
	if r != .Missing || wait.call == nil || !h.sp.repl_on || !h.sp.connected {
		return r
	}
	ch, cerr := _catalog_handle(e, h.sp)
	if cerr != .None {
		return r
	}
	if !osync.replicator_caught_up(&h.sp.repl) || _handle_waiting(ch, false) {
		return _space_wait_on(e, h.sp, wait, .Catalog)
	}
	return r
}

buffer_open :: proc(e: ^Engine, o: Object, opts: Buffer_Options, allocator := context.allocator) -> (info: Buffer_Info, err: Error) {
	context = context_for(e)
	kind := Kind.Text if len(opts.path) == 0 else Kind.File_Tree
	h := _handle_get(e, o, kind) or_return
	if herr := _hist_ready(e, h); herr != .None {
		return {}, _buffer_wait(e, h, herr, opts.wait)
	}
	_buffer_follow(e, h)
	if cerr := _hist_caught_up(e, h); cerr != .None {
		return {}, _buffer_wait(e, h, cerr, opts.wait)
	}
	inode: fstree.Inode_Id
	tree_at: Tree_At
	if kind == .Text {
		id, found := _text_inode(h) or_return
		if !found {
			return {}, _buffer_wait(e, h, .Missing, opts.wait)
		}
		inode = id
	} else {
		tree_at = _tree_at(e, h, opts.line, nil) or_return
		snap := tree_at.snap
		id, ok, lerr := fstree.lookup(&snap, opts.path)
		if lerr != nil {
			return {}, .Corrupt
		}
		if !ok {
			return {}, .Not_Found
		}
		fi, iok, ierr := fstree.info(&snap, id, context.temp_allocator)
		if ierr != nil || !iok {
			return {}, .Corrupt
		}
		if fi.kind != .File {
			return {}, .Invalid
		}
		if .Opaque in fi.flags {
			return {}, .Too_Large
		}
		inode = id
	}
	b := new(Buffer, e.allocator)
	b.object = o
	b.kind = kind
	b.inode = inode
	b.units = opts.units
	b.cb = opts.cb
	b.data = opts.data
	b.ready = opts.ready
	b.hist = h.hist
	line := opts.line
	if kind == .File_Tree {
		line = tree_at.line
	}
	b.line = _clone(line, e.allocator) or_return
	b.base = opts.actor if opts.actor != {} else editor_actor(e, b.line)
	b.actor = _live_actor(e, b.base)
	b.version = make([dynamic]crdt.Op_Id, e.allocator)
	b.sent = make([dynamic]Sent, e.allocator)
	b.undo = make([dynamic]Undo_Group, e.allocator)
	b.redo = make([dynamic]Undo_Group, e.allocator)
	b.cursors = make([dynamic]Cursor_Set, e.allocator)
	b.mine = make([dynamic][2]Anchor, e.allocator)
	target, terr := _buffer_target(b, h)
	if terr != .None {
		_buffer_free(e, b)
		return {}, terr
	}
	view, verr := fs.history_view_open(h.hist, inode, target)
	if verr != .None {
		_buffer_free(e, b)
		return {}, _ferr(verr)
	}
	b.view = view
	append(&b.version, ..target)
	e.next_buffer += 1
	b.id = Buffer_Id(e.next_buffer)
	h.pins += 1
	append(&e.buffers, b)
	_buffer_live_follow(e, h, true)
	if h.sp.repl_on && !e.cfg.buffer_live_off && !e.closing {
		_live_arm(e)
	}
	info.id = b.id
	info.length = _length(b)
	info.actor = b.base
	info.line = _clone(b.line, allocator) or_return
	n := info.length if opts.page <= 0 else min(opts.page, info.length)
	end := _to_bytes(b, n)
	info.page = make([]u8, end, allocator)
	crdt.text_read(&b.view.text, 0, info.page)
	info.more = n < info.length
	return info, .None
}

buffer_close :: proc(e: ^Engine, id: Buffer_Id) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return
	}
	for x, i in e.buffers {
		if x == b {
			ordered_remove(&e.buffers, i)
			break
		}
	}
	if h, ok := e.handles[b.object.id]; ok {
		if h.pins > 0 {
			h.pins -= 1
		}
		if b.mine_seq > 0 {
			_cursors_publish(e, b, h, nil)
		}
		others := false
		for x in e.buffers {
			if x.object.id == h.id {
				others = true
				break
			}
		}
		if !others {
			_buffer_live_follow(e, h, false)
		}
	}
	_buffer_free(e, b)
}

@(private)
_buffer_free :: proc(e: ^Engine, b: ^Buffer) {
	for o in b.ovl {
		_ovl_free(e, o)
	}
	delete(b.ovl)
	_ops_release(e, &b.oc)
	for r in b.held {
		if r.call != nil {
			context = _outer(e)
			r.call(r.data, e, .Closed)
		}
	}
	delete(b.held)
	if b.view != nil && b.hist != nil {
		fs.history_view_close(b.hist, b.view)
	}
	for &s in b.sent {
		_ops_free(e, s.ops)
		_gone_free(e, s.gone)
	}
	delete(b.sent)
	_pend_clear(e, b)
	delete(b.pend)
	delete(b.peers)
	for &g in b.undo {
		_undo_free(&g)
	}
	for &g in b.redo {
		_undo_free(&g)
	}
	delete(b.undo)
	delete(b.redo)
	for &c in b.cursors {
		_cursor_set_free(e, &c)
	}
	delete(b.cursors)
	delete(b.mine)
	delete(b.version)
	delete(b.line, e.allocator)
	free(b, e.allocator)
}

@(private)
_buffers_detach :: proc(e: ^Engine, h: ^Handle) {
	i := 0
	for i < len(e.buffers) {
		b := e.buffers[i]
		if b.object.id != h.id {
			i += 1
			continue
		}
		ordered_remove(&e.buffers, i)
		if b.cb != nil {
			ev := Buffer_Event{kind = .Closed, buffer = b.id, rev = b.rev, ack = b.recv, err = .Closed}
			cb, data := b.cb, b.data
			{
				context = _outer(e)
				cb(data, e, &ev)
			}
		}
		_buffer_free(e, b)
	}
}

@(private)
_buffer_lost :: proc(e: ^Engine, b: ^Buffer) {
	for x, i in e.buffers {
		if x == b {
			ordered_remove(&e.buffers, i)
			break
		}
	}
	if h, ok := e.handles[b.object.id]; ok && h.pins > 0 {
		h.pins -= 1
	}
	if b.cb != nil {
		ev := Buffer_Event{kind = .Closed, buffer = b.id, rev = b.rev, ack = b.recv, err = .Conflict}
		cb, data := b.cb, b.data
		{
			context = _outer(e)
			cb(data, e, &ev)
		}
	}
	_buffer_free(e, b)
}

@(private)
_buffers_free_all :: proc(e: ^Engine) {
	_cursors_free_inbox(e)
	for b in e.buffers {
		_buffer_free(e, b)
	}
	delete(e.buffers)
	e.buffers = nil
	delete(e.live_boots)
	e.live_boots = nil
	delete(e.live_sent)
	e.live_sent = nil
	delete(e.live_ids)
	e.live_ids = nil
	delete(e.buffer_wakes)
	e.buffer_wakes = nil
}

@(private)
_ops_clone :: proc(e: ^Engine, ops: []crdt.Delta_Op) -> (out: []crdt.Delta_Op, bytes: int) {
	out = make([]crdt.Delta_Op, len(ops), e.allocator)
	for o, i in ops {
		out[i] = o
		if len(o.text) > 0 {
			t := make([]u8, len(o.text), e.allocator)
			copy(t, o.text)
			out[i].text = t
			bytes += len(t)
		}
	}
	bytes += len(ops) * size_of(crdt.Delta_Op)
	return
}

@(private)
_ops_free :: proc(e: ^Engine, ops: []crdt.Delta_Op) {
	for o in ops {
		if len(o.text) > 0 {
			delete(o.text, e.allocator)
		}
	}
	delete(ops, e.allocator)
}

@(private)
_undo_free :: proc(g: ^Undo_Group) {
	delete(g.inserts)
	for &d in g.deletes {
		delete(d.runs)
	}
	delete(g.deletes)
}

@(private)
_sent_drop :: proc(e: ^Engine, b: ^Buffer, upto: u64) {
	n := 0
	for n < len(b.sent) && b.sent[n].rev <= upto {
		_ops_free(e, b.sent[n].ops)
		_gone_free(e, b.sent[n].gone)
		b.sent_bytes -= b.sent[n].bytes
		n += 1
	}
	if n > 0 {
		remove_range(&b.sent, 0, n)
	}
}

@(private)
_sent_push :: proc(e: ^Engine, b: ^Buffer, ops: []crdt.Delta_Op, gone: []Gone = nil) {
	c, bytes := _ops_clone(e, ops)
	append(&b.sent, Sent{rev = b.rev, ops = c, bytes = bytes, gone = _gone_own(e, gone)})
	b.sent_bytes += bytes
	for len(b.sent) > BUFFER_KEEP_DELTAS || (b.sent_bytes > BUFFER_KEEP_BYTES && len(b.sent) > 1) {
		b.floor = b.sent[0].rev
		_sent_drop(e, b, b.sent[0].rev)
	}
}

@(private)
Sink_State :: struct {
	db:   crdt.Delta_Builder,
	hist: ^fs.History,
}

@(private)
_sink :: proc(st: ^Sink_State) -> crdt.Text_Sink {
	return crdt.Text_Sink {
		data = st,
		insert = proc(data: rawptr, pos: int, bytes: []u8, author: crdt.Op_Id) {
			s := (^Sink_State)(data)
			c := make([]u8, len(bytes), context.temp_allocator)
			copy(c, bytes)
			crdt.delta_step_insert(&s.db, pos, c, fs.history_epoch_base(s.hist, author.actor))
		},
		delete = proc(data: rawptr, pos: int, bytes: []u8) {
			s := (^Sink_State)(data)
			c := make([]u8, len(bytes), context.temp_allocator)
			copy(c, bytes)
			crdt.delta_step_delete(&s.db, pos, c)
		},
	}
}

@(private)
View_Reader :: struct {
	b: ^Buffer,
}

@(private)
_buffer_unavailable :: proc(e: ^Engine, b: ^Buffer, h: ^Handle) -> Error {
	_hist_fetch_full(e, h)
	return .Missing
}

@(private)
_buffer_view_ready :: proc(e: ^Engine, b: ^Buffer, h: ^Handle) -> Error {
	_hist_ready(e, h) or_return
	if b.hist != h.hist {
		return .Closed
	}
	if b.view.stale {
		st := Sink_State{hist = h.hist}
		crdt.delta_builder_init(&st.db, context.temp_allocator)
		if aerr := fs.history_view_advance(h.hist, b.view, b.version[:], _sink(&st)); aerr != .None {
			return _buffer_unavailable(e, b, h)
		}
		if _ovl_on(b) {
			_ovl_advanced(e, b, _regions_bytes(crdt.delta_regions(&st.db, context.temp_allocator))[:])
			return .None
		}
		if st.db.steps > 0 {
			b.dirty = true
			return _buffer_emit(e, b, &st)
		}
	}
	return .None
}

@(private)
_buffer_advance :: proc(e: ^Engine, b: ^Buffer, h: ^Handle) -> Error {
	scratch := virtual.arena_temp_begin(&e.temp)
	defer virtual.arena_temp_end(scratch)
	_hist_ready(e, h) or_return
	if b.hist != h.hist {
		return .Closed
	}
	_buffer_follow(e, h)
	_hist_caught_up(e, h) or_return
	_buffer_live_follow(e, h, true)
	target := _buffer_target(b, h) or_return
	st := Sink_State{hist = h.hist}
	crdt.delta_builder_init(&st.db, context.temp_allocator)
	if aerr := fs.history_view_advance(h.hist, b.view, target, _sink(&st)); aerr != .None {
		return _buffer_unavailable(e, b, h)
	}
	clear(&b.version)
	append(&b.version, ..target)
	if _ovl_on(b) {
		_ovl_advanced(e, b, _regions_bytes(crdt.delta_regions(&st.db, context.temp_allocator))[:])
		if _ovl_stray(b) {
			e.stats.buffer_live_stray += 1
			_ovl_drop(e, b)
		}
		return .None
	}
	if st.db.steps == 0 {
		return .None
	}
	return _buffer_emit(e, b, &st)
}

@(private)
_buffer_emit :: proc(e: ^Engine, b: ^Buffer, st: ^Sink_State) -> Error {
	vr := View_Reader{b}
	rd := crdt.Text_Reader {
		data = &vr,
		read = proc(data: rawptr, pos: int, dst: []u8) -> int {
			return crdt.text_read(&(^View_Reader)(data).b.view.text, pos, dst)
		},
		author = proc(data: rawptr, pos: int) -> prim.Id {
			b := (^View_Reader)(data).b
			a, _, _ := crdt.text_author(&b.view.text, &b.hist.g, pos)
			return fs.history_epoch_base(b.hist, a.actor)
		},
		len = crdt.text_len(&b.view.text),
	}
	regions := crdt.delta_regions(&st.db, context.temp_allocator)
	if len(b.pend) > 0 {
		_pend_rebase(e, b, _regions_bytes(regions)[:])
	}
	wide := crdt.delta_widen(regions, &rd, context.temp_allocator)
	ops := make([dynamic]crdt.Delta_Op, context.temp_allocator)
	crdt.delta_emit(wide, _utf16(b), proc(data: rawptr, pos: int) -> int {
		return crdt.text_units_at(&(^Buffer)(data).view.text, pos)
	}, b, &ops)
	crdt.delta_trim(&ops)
	if len(ops) == 0 {
		return .None
	}
	b.rev += 1
	_sent_push(e, b, ops[:])
	e.stats.buffer_deltas += 1
	if b.cb != nil {
		ev := Buffer_Event{kind = .Delta, buffer = b.id, rev = b.rev, ack = b.recv, length = _length(b), ops = ops[:]}
		cb, data := b.cb, b.data
		{
			context = _outer(e)
			cb(data, e, &ev)
		}
	}
	if slice.contains(e.buffers[:], b) {
		_cursors_after_delta(e, b)
	}
	return .None
}

@(private)
_buffers_tick :: proc(e: ^Engine) {
	_cursors_drain(e)
	_dlog_tick(e)
	if len(e.buffers) == 0 {
		return
	}
	for b in e.buffers {
		if _, ok := e.changed[b.object.id]; ok {
			b.dirty = true
		}
	}
	list := make([dynamic]^Buffer, 0, len(e.buffers), context.temp_allocator)
	append(&list, ..e.buffers[:])
	for b in list {
		if !slice.contains(e.buffers[:], b) || !b.dirty {
			continue
		}
		if b.ready != nil && !b.ready(b.data) {
			continue
		}
		b.dirty = false
		h, err := _handle_get(e, b.object, b.kind)
		if err != .None {
			continue
		}
		aerr := _buffer_advance(e, b, h)
		if aerr == .Busy {
			b.dirty = true
		} else if aerr != .None && aerr != .Missing && !_store_err(e, aerr) {
			_log(e, .Warn, "buffer advance failed")
		}
	}
	for b in list {
		if !slice.contains(e.buffers[:], b) || !b.mine_dirty {
			continue
		}
		b.mine_dirty = false
		if h, ok := e.handles[b.object.id]; ok {
			_cursors_publish(e, b, h, b.mine[:])
		}
	}
	_buffers_wake(e)
}

buffer_kick :: proc(e: ^Engine, id: Buffer_Id) {
	context = context_for(e)
	if b := _buffer_find(e, id); b != nil && b.dirty {
		_touch(e)
	}
}

buffer_ack :: proc(e: ^Engine, id: Buffer_Id, rev: u64) -> Error {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return .Not_Found
	}
	if rev > b.rev {
		return .Invalid
	}
	_sent_drop(e, b, rev)
	return .None
}

@(private)
_buffer_sync :: proc(e: ^Engine, b: ^Buffer, h: ^Handle) -> Error {
	_buffer_advance(e, b, h) or_return
	b.dirty = false
	_buffer_actor(e, b, h.hist)
	next := fs.history_next_seq(h.hist, b.actor)
	if next == 0 || fs.history_contains(h.hist, b.version[:], crdt.Op_Id{b.actor, next - 1}) {
		return .None
	}
	return .Conflict
}

@(private)
_buffer_writer :: proc(e: ^Engine, b: ^Buffer, h: ^Handle) -> Error {
	if h.w_open {
		return .None
	}
	_handle_create_writer(h) or_return
	_buffer_view_ready(e, b, h) or_return
	return _buffer_sync(e, b, h)
}

@(private)
_buffer_base :: proc(e: ^Engine, b: ^Buffer, rev: u64) -> Error {
	if rev > b.rev {
		return .Invalid
	}
	if rev < b.floor {
		return .Conflict
	}
	_sent_drop(e, b, rev)
	return .None
}

@(private)
_map_pos :: proc(b: ^Buffer, pos: int, after: bool) -> int {
	p := pos
	for s in b.sent {
		p = crdt.delta_transform_pos(s.ops, p, after, _utf16(b))
	}
	return p
}

buffer_read :: proc(e: ^Engine, id: Buffer_Id, rev: u64, from: int, n: int, allocator := context.allocator) -> (r: Buffer_Read, err: Error) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return {}, .Not_Found
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_base(e, b, rev) or_return
	_buffer_view_ready(e, b, h) or_return
	total := _length(b)
	at := clamp(_map_pos(b, from, false), 0, total)
	end := min(total, at + max(n, 0))
	lo := _to_bytes(b, at)
	hi := _to_bytes(b, end)
	r.text = make([]u8, hi - lo, allocator)
	if _ovl_on(b) {
		_disp_read(b, lo, r.text)
	} else {
		crdt.text_read(&b.view.text, lo, r.text)
	}
	r.rev = b.rev
	r.ack = b.recv
	r.from = at
	r.length = total
	return r, .None
}

@(private)
_edits_delta :: proc(b: ^Buffer, edits: []Buffer_Edit) -> (ops: [dynamic]crdt.Delta_Op, err: Error) {
	ops = make([dynamic]crdt.Delta_Op, context.temp_allocator)
	at := 0
	for ed in edits {
		if ed.pos < at || ed.del < 0 {
			return ops, .Invalid
		}
		crdt.delta_push(&ops, crdt.Delta_Op{kind = .Retain, n = ed.pos - at})
		crdt.delta_push(&ops, crdt.Delta_Op{kind = .Delete, n = ed.del})
		if len(ed.ins) > 0 {
			crdt.delta_push(&ops, crdt.Delta_Op{kind = .Insert, n = crdt.units(ed.ins) if _utf16(b) else len(ed.ins), text = ed.ins})
		}
		at = ed.pos + ed.del
	}
	crdt.delta_trim(&ops)
	return ops, .None
}

@(private)
Built :: struct {
	runs:  [dynamic]crdt.Op_Run,
	group: Undo_Group,
	n:     int,
}

@(private)
_built_init :: proc(x: ^Built) {
	x.runs = make([dynamic]crdt.Op_Run, context.temp_allocator)
	x.group.inserts = make([dynamic]crdt.Op_Span, context.temp_allocator)
	x.group.deletes = make([dynamic]Undo_Del, context.temp_allocator)
}

@(private)
_built_delete :: proc(b: ^Buffer, x: ^Built, target: crdt.Op_Id, at_old: int, at_new: int, k: int) {
	d := Undo_Del {
		runs = make([dynamic]crdt.Op_Span, context.temp_allocator),
	}
	crdt.text_ops(&b.view.text, &b.hist.g, at_old, k, &d.runs)
	append(&x.group.deletes, d)
	append(&x.runs, crdt.Op_Run{target = target, kind = .Delete, pos = at_new, len = k})
	x.n += k
}

@(private)
_built_insert :: proc(b: ^Buffer, x: ^Built, seq0: u64, run: crdt.Op_Run) {
	append(&x.group.inserts, crdt.Op_Span{crdt.Op_Id{b.actor, seq0 + u64(x.n)}, run.len})
	append(&x.runs, run)
	x.n += run.len
}

@(private)
_delta_runs :: proc(b: ^Buffer, ops: []crdt.Delta_Op, seq0: u64, x: ^Built) -> Error {
	target := fs.inode_op(b.hist, b.inode)
	total := _length(b)
	ou, ob, shift := 0, 0, 0
	for o in ops {
		switch o.kind {
		case .Retain:
			ou += o.n
			if ou > total {
				return .Invalid
			}
			ob = _to_bytes(b, ou)
		case .Delete:
			start := ob
			ou += o.n
			if ou > total {
				return .Invalid
			}
			ob = _to_bytes(b, ou)
			k := ob - start
			if k > 0 {
				_built_delete(b, x, target, start, start + shift, k)
				shift -= k
			}
		case .Insert:
			c := make([]u8, len(o.text), context.temp_allocator)
			copy(c, o.text)
			_built_insert(b, x, seq0, crdt.Op_Run{target = target, kind = .Insert, pos = ob + shift, len = len(c), content = c})
			shift += len(c)
		}
	}
	return .None
}

@(private)
_commit_runs :: proc(e: ^Engine, b: ^Buffer, h: ^Handle, x: ^Built, seq0: u64) -> (last: crdt.Op_Id, err: Error) {
	hist := h.hist
	_buffer_actor_register(e, b, hist) or_return
	batch := crdt.Batch {
		actor   = b.actor,
		seq     = seq0,
		lamport = fs.history_lamport_after(hist, b.version[:]),
		parents = b.version[:],
		ops     = x.runs[:],
	}
	line: Maybe(string)
	if b.kind == .File_Tree {
		line = b.line
	}
	ff := _log_frontier(b)
	flen := crdt.text_len(&b.view.text)
	off, cerr := fs.history_commit_local(hist, &batch, line)
	if cerr != .None {
		return {}, _ferr(cerr)
	}
	_buffer_live_send(e, b, h, &batch, off, ff, flen)
	if b.kind == .File_Tree {
		_mounts_wake(e, h.id)
	}
	_handle_mark(h)
	e.stats.buffer_edits += 1
	return crdt.Op_Id{b.actor, seq0 + u64(x.n) - 1}, .None
}

@(private)
_group_keep :: proc(e: ^Engine, stack: ^[dynamic]Undo_Group, g: ^Undo_Group, id: u64) {
	if len(g.inserts) == 0 && len(g.deletes) == 0 {
		return
	}
	if id != 0 && len(stack) > 0 && stack[len(stack) - 1].id == id {
		top := &stack[len(stack) - 1]
		append(&top.inserts, ..g.inserts[:])
		for d in g.deletes {
			runs := make([dynamic]crdt.Op_Span, e.allocator)
			append(&runs, ..d.runs[:])
			append(&top.deletes, Undo_Del{runs})
		}
		return
	}
	ng := Undo_Group {
		id      = id,
		inserts = make([dynamic]crdt.Op_Span, e.allocator),
		deletes = make([dynamic]Undo_Del, e.allocator),
	}
	append(&ng.inserts, ..g.inserts[:])
	for d in g.deletes {
		runs := make([dynamic]crdt.Op_Span, e.allocator)
		append(&runs, ..d.runs[:])
		append(&ng.deletes, Undo_Del{runs})
	}
	append(stack, ng)
}

buffer_edit :: proc(e: ^Engine, id: Buffer_Id, rev: u64, edits: []Buffer_Edit, group: u64 = 0, ready: Ready = {}) -> (ack: u64, applied: u64, err: Error) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return 0, 0, .Not_Found
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_base(e, b, rev) or_return
	_buffer_view_ready(e, b, h) or_return
	_buffer_sync(e, b, h) or_return
	_buffer_writer(e, b, h) or_return
	if _buffer_find(e, id) != b {
		return 0, 0, .Closed
	}
	if len(b.held) > 0 {
		_buffer_hold(e, b, ready) or_return
		if _buffer_find(e, id) != b {
			return 0, 0, .Closed
		}
	}
	scratch := virtual.arena_temp_begin(&e.temp)
	defer virtual.arena_temp_end(scratch)
	ops := _edits_delta(b, edits) or_return
	cur := ops[:]
	moved := make([][]crdt.Delta_Op, len(b.sent), context.temp_allocator)
	regone := make([][]Gone, len(b.sent), context.temp_allocator)
	hits := make([dynamic]crdt.Op_Span, context.temp_allocator)
	for s, i in b.sent {
		if len(s.gone) > 0 {
			kept, hit := _gone_rebase(b, s.gone, cur)
			regone[i] = kept[:]
			for g in hit {
				if prim.id_is_zero(g.id.actor) {
					e.stats.buffer_live_bad_gone += 1
					return 0, 0, .Invalid
				}
				append(&hits, crdt.Op_Span{g.id, len(g.text)})
			}
		}
		a2 := make([dynamic]crdt.Delta_Op, context.temp_allocator)
		b2 := make([dynamic]crdt.Delta_Op, context.temp_allocator)
		crdt.delta_transform(cur, s.ops, _utf16(b), &a2, &b2)
		moved[i] = b2[:]
		cur = a2[:]
	}
	if !_edit_bounds_ok(b, cur) {
		return 0, 0, .Invalid
	}
	ed, dok := _disp_delta_bytes(b, cur)
	if !dok {
		return 0, 0, .Invalid
	}
	ev := ed[:]
	ovl := _ovl_on(b)
	if ovl {
		m, mok := _ovl_unmap(b, ed[:])
		if !mok {
			if ready.call == nil {
				_ovl_drop(e, b)
				return buffer_edit(e, id, rev, edits, group, ready)
			}
			_buffer_hold(e, b, ready) or_return
		}
		ev = m
	}
	if len(hits) > 0 {
		_dlog_record(e, b, hits[:]) or_return
	}
	x: Built
	_built_init(&x)
	committed := false
	last: crdt.Op_Id
	seq0: u64
	if len(ev) > 0 {
		_handle_create_writer(h) or_return
		seq0 = fs.history_next_seq(h.hist, b.actor)
		_delta_runs_view(b, ev, seq0, &x) or_return
		if len(x.runs) > 0 {
			last = _commit_runs(e, b, h, &x, seq0) or_return
			committed = true
		}
	}
	for &s, i in b.sent {
		nops, nbytes := _ops_clone(e, moved[i])
		_ops_free(e, s.ops)
		b.sent_bytes += nbytes - s.bytes
		s.ops = nops
		s.bytes = nbytes
		if len(s.gone) > 0 {
			ng := _gone_own(e, regone[i])
			_gone_free(e, s.gone)
			s.gone = ng
		}
	}
	b.recv += 1
	if !committed {
		return b.recv, b.rev, .None
	}
	v := [1]crdt.Op_Id{last}
	reloaded, aerr := fs.history_view_advance_ex(h.hist, b.view, v[:], {})
	clear(&b.version)
	append(&b.version, last)
	if aerr != .None || reloaded {
		lost_ack, lost_rev := b.recv, b.rev
		_buffer_lost(e, b)
		return lost_ack, lost_rev, .None
	}
	if ovl && _ovl_on(b) {
		_ovl_rebase(e, b, ev)
	}
	_pend_add(e, b, b.actor, seq0, last.seq, ed[:])
	_group_keep(e, &b.undo, &x.group, group)
	for &g in b.redo {
		_undo_free(&g)
	}
	clear(&b.redo)
	return b.recv, b.rev, .None
}

@(private)
Undo_Action :: struct {
	pos:    int,
	len:    int,
	insert: bool,
	content: []u8,
	order:  int,
	runs:   [dynamic]crdt.Op_Span,
}

@(private)
_undo_apply :: proc(e: ^Engine, b: ^Buffer, h: ^Handle, g: ^Undo_Group) -> (inverse: Undo_Group, err: Error) {
	text := &b.view.text
	gr := &b.hist.g
	acts := make([dynamic]Undo_Action, context.temp_allocator)
	loc := make([dynamic]crdt.Located, context.temp_allocator)
	for sp in g.inserts {
		clear(&loc)
		crdt.text_locate(text, gr, sp.id, sp.len, &loc)
		for l in loc {
			a := Undo_Action{pos = l.pos, len = l.len, runs = make([dynamic]crdt.Op_Span, context.temp_allocator)}
			crdt.text_ops(text, gr, l.pos, l.len, &a.runs)
			append(&acts, a)
		}
	}
	order := 0
	for d in g.deletes {
		for r in d.runs {
			clear(&loc)
			crdt.text_locate(text, gr, r.id, r.len, &loc)
			cur := r.id.seq
			end := r.id.seq + u64(r.len)
			li := 0
			for cur < end {
				next_present := end
				if li < len(loc) {
					next_present = loc[li].seq
				}
				if cur < next_present {
					own, until := _own_insert(g, r.id.actor, cur, next_present)
					if !own {
						missing := crdt.Op_Id{r.id.actor, cur}
						p, aerr := crdt.anchor_resolve(text, gr, &b.view.log, crdt.Anchor{id = missing, bias = .Before})
						if aerr == .Missing_Ops {
							fp, ferr := fs.history_view_anchor_full(b.hist, b.view, crdt.Anchor{id = missing, bias = .Before})
							p, aerr = fp, .None if ferr == .None else .Unknown
						}
						if aerr == .None && !crdt.graph_redacted_any(gr, missing.actor, missing.seq, int(until - cur)) {
							data := make([]u8, int(until - cur), context.temp_allocator)
							got := fs.history_op_content(b.hist, missing, data)
							if got > 0 {
								append(&acts, Undo_Action{pos = p, len = got, insert = true, content = data[:got], order = order})
								order += 1
							}
						}
					}
					cur = until
					continue
				}
				cur = loc[li].seq + u64(loc[li].len)
				li += 1
			}
		}
	}
	slice.sort_by(acts[:], proc(a, b: Undo_Action) -> bool {
		if a.pos != b.pos {
			return a.pos > b.pos
		}
		if a.insert != b.insert {
			return !a.insert
		}
		return a.order > b.order
	})
	_handle_create_writer(h) or_return
	seq0 := fs.history_next_seq(h.hist, b.actor)
	target := fs.inode_op(b.hist, b.inode)
	x: Built
	_built_init(&x)
	for &a in acts {
		if a.insert {
			_built_insert(b, &x, seq0, crdt.Op_Run{target = target, kind = .Insert, pos = a.pos, len = a.len, content = a.content})
		} else {
			append(&x.group.deletes, Undo_Del{runs = a.runs})
			append(&x.runs, crdt.Op_Run{target = target, kind = .Delete, pos = a.pos, len = a.len})
			x.n += a.len
		}
	}
	if len(x.runs) == 0 {
		return {}, .None
	}
	_commit_runs(e, b, h, &x, seq0) or_return
	b.dirty = true
	return x.group, .None
}

@(private)
_own_insert :: proc(g: ^Undo_Group, actor: prim.Id, seq: u64, end: u64) -> (own: bool, until: u64) {
	stop := end
	for sp in g.inserts {
		if sp.id.actor != actor {
			continue
		}
		lo := sp.id.seq
		hi := sp.id.seq + u64(sp.len)
		if seq >= lo && seq < hi {
			return true, min(hi, end)
		}
		if lo > seq && lo < stop {
			stop = lo
		}
	}
	return false, stop
}

@(private)
_undo_step :: proc(e: ^Engine, id: Buffer_Id, redo: bool, ready: Ready = {}) -> (done: bool, err: Error) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return false, .Not_Found
	}
	from := &b.redo if redo else &b.undo
	to := &b.undo if redo else &b.redo
	if len(from) == 0 {
		return false, .None
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_view_ready(e, b, h) or_return
	_buffer_sync(e, b, h) or_return
	_buffer_writer(e, b, h) or_return
	if _buffer_find(e, id) != b || len(from) == 0 {
		return false, .Closed
	}
	if _ovl_on(b) || len(b.held) > 0 {
		_buffer_hold(e, b, ready) or_return
	}
	scratch := virtual.arena_temp_begin(&e.temp)
	defer virtual.arena_temp_end(scratch)
	g := pop(from)
	defer _undo_free(&g)
	inv, uerr := _undo_apply(e, b, h, &g)
	if uerr != .None {
		_group_keep(e, from, &g, g.id)
		return false, uerr
	}
	_group_keep(e, to, &inv, 0)
	return true, .None
}

buffer_undo :: proc(e: ^Engine, id: Buffer_Id, ready: Ready = {}) -> (done: bool, err: Error) {
	return _undo_step(e, id, false, ready)
}

buffer_redo :: proc(e: ^Engine, id: Buffer_Id, ready: Ready = {}) -> (done: bool, err: Error) {
	return _undo_step(e, id, true, ready)
}

Anchor :: crdt.Anchor

ANCHOR_START :: Anchor{offset = 0}
ANCHOR_END :: Anchor{offset = 1}

buffer_anchors :: proc(e: ^Engine, id: Buffer_Id, rev: u64, positions: []int, bias: crdt.Bias, allocator := context.allocator) -> (out: []Anchor, err: Error) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return nil, .Not_Found
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_base(e, b, rev) or_return
	_buffer_view_ready(e, b, h) or_return
	total := _length(b)
	out = make([]Anchor, len(positions), allocator)
	for p, i in positions {
		u := clamp(_map_pos(b, p, bias == .After), 0, total)
		pos := _to_bytes(b, u)
		if _ovl_on(b) {
			oa, vp, inside := _ovl_anchor(b, pos, bias)
			if inside {
				out[i] = oa
				continue
			}
			pos = vp
		}
		if bias == .Before && pos >= crdt.text_len(&b.view.text) {
			out[i] = ANCHOR_END
			continue
		}
		if bias == .After && pos <= 0 {
			out[i] = ANCHOR_START
			continue
		}
		a, ok := crdt.anchor_at(&b.view.text, &b.hist.g, pos, bias)
		out[i] = a if ok else ANCHOR_END
	}
	return out, .None
}

@(private)
_resolve_one :: proc(b: ^Buffer, a: Anchor) -> int {
	if a.id.actor == {} {
		return 0 if a.offset == 0 else _length(b)
	}
	if _ovl_on(b) {
		if op, inside := _ovl_resolve(b, a); inside {
			return _to_units(b, op)
		}
	}
	p, err := crdt.anchor_resolve(&b.view.text, &b.hist.g, &b.view.log, a)
	if err == .Missing_Ops {
		fp, ferr := fs.history_view_anchor_full(b.hist, b.view, a)
		if ferr != .None {
			return -1
		}
		p = fp
	} else if err != .None {
		return -1
	}
	if _ovl_on(b) {
		p = crdt.delta_transform_pos(b.oc[:], p, a.bias == .Before, false)
	}
	return _to_units(b, p)
}

buffer_resolve :: proc(e: ^Engine, id: Buffer_Id, rev: u64, anchors: []Anchor, allocator := context.allocator) -> (out: []int, at: u64, ack: u64, err: Error) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return nil, 0, 0, .Not_Found
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_base(e, b, rev) or_return
	_buffer_view_ready(e, b, h) or_return
	out = make([]int, len(anchors), allocator)
	for a, i in anchors {
		p := _resolve_one(b, a)
		if p >= 0 {
			after := a.bias == .Before if a.id.actor != {} else a.offset != 0
			#reverse for s in b.sent {
				p = crdt.delta_untransform_pos(s.ops, p, after, _utf16(b))
			}
		}
		out[i] = p
	}
	return out, rev, b.recv, .None
}

buffer_text :: proc(e: ^Engine, id: Buffer_Id, allocator := context.allocator) -> (text: []u8, rev: u64, err: Error) {
	context = context_for(e)
	b := _buffer_find(e, id)
	if b == nil {
		return nil, 0, .Not_Found
	}
	h := _handle_get(e, b.object, b.kind) or_return
	_buffer_view_ready(e, b, h) or_return
	if _ovl_on(b) {
		return _disp_bytes(b, allocator), b.rev, .None
	}
	return crdt.text_bytes(&b.view.text, allocator), b.rev, .None
}

package api

import "core:strconv"
import "core:strings"
import "../../crdt"
import eng "../../engine"
import "../../prim"

BUF :: Arg{"buffer", .U64, nil}
REV :: Arg{"rev", .U64, nil}

UNITS_NAMES := [2]string{"bytes", "utf16"}
BIAS_NAMES := [2]string{"before", "after"}
BUFFER_EVENT_NAMES := [4]string{"open", "delta", "cursors", "closed"}
DELTA_OP_NAMES := [3]string{"retain", "delete", "insert"}

BUFFER_OPS := []Op {
	{150, "buffer.open", {OBJ, {"path", .Str, nil}, {"line", .Str, nil}, {"units", .Enum, UNITS_NAMES[:]}, {"actor", .Id, nil}, {"page", .U64, nil}}, "BufferEvent", nil},
	{151, "buffer.read", {BUF, REV, {"from", .U64, nil}, {"len", .U64, nil}}, "rev:uvarint ack:uvarint from:uvarint length:uvarint text:str", op_buffer_read},
	{152, "buffer.edit", {BUF, REV, {"pos", .U64s, nil}, {"del", .U64s, nil}, {"ins", .Strs, nil}, {"group", .U64, nil}}, "ack:uvarint rev:uvarint", op_buffer_edit},
	{153, "buffer.ack", {BUF, REV}, "", op_buffer_ack},
	{154, "buffer.undo", {BUF}, "done:bool", op_buffer_undo},
	{155, "buffer.redo", {BUF}, "done:bool", op_buffer_redo},
	{156, "buffer.anchors", {BUF, REV, {"positions", .U64s, nil}, {"bias", .Enum, BIAS_NAMES[:]}}, "anchors:strs", op_buffer_anchors},
	{157, "buffer.resolve", {BUF, {"anchors", .Strs, nil}}, "positions:[ivarint] rev:uvarint ack:uvarint", op_buffer_resolve},
	{158, "buffer.cursors", {BUF, REV, {"ranges", .U64s, nil}}, "", op_buffer_cursors},
	{159, "buffer.text", {BUF}, "rev:uvarint text:str", op_buffer_text},
}

anchor_text :: proc(a: eng.Anchor, allocator := context.temp_allocator) -> string {
	if a.id.actor == {} {
		return "s" if a.offset == 0 else "e"
	}
	h := prim.id_hex(a.id.actor)
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, string(h[:]))
	strings.write_byte(&sb, '.')
	strings.write_u64(&sb, a.id.seq)
	if a.offset > 0 {
		strings.write_byte(&sb, '.')
		strings.write_int(&sb, a.offset)
	}
	strings.write_byte(&sb, '.')
	strings.write_byte(&sb, 'b' if a.bias == .Before else 'a')
	return strings.to_string(sb)
}

anchor_parse :: proc(s: string) -> (a: eng.Anchor, ok: bool) {
	switch s {
	case "s":
		return eng.ANCHOR_START, true
	case "e":
		return eng.ANCHOR_END, true
	}
	parts := strings.split(s, ".", context.temp_allocator)
	if len(parts) != 3 && len(parts) != 4 {
		return {}, false
	}
	id, iok := prim.id_parse(parts[0])
	if !iok || id == {} {
		return {}, false
	}
	seq, sok := strconv.parse_u64(parts[1], 10)
	if !sok {
		return {}, false
	}
	a.id = crdt.Op_Id{id, seq}
	if len(parts) == 4 {
		off, ook := strconv.parse_int(parts[2], 10)
		if !ook || off < 0 {
			return {}, false
		}
		a.offset = off
	}
	switch parts[len(parts) - 1] {
	case "b":
		a.bias = .Before
	case "a":
		a.bias = .After
	case:
		return {}, false
	}
	return a, true
}

emit_buffer_event :: proc(o: ^Out, kind: u64, ev: ^eng.Buffer_Event, info: ^eng.Buffer_Info) {
	o_enum(o, "kind", kind, BUFFER_EVENT_NAMES[:])
	o_u64(o, "buffer", u64(info.id) if info != nil else u64(ev.buffer))
	o_u64(o, "rev", ev.rev if ev != nil else 0)
	o_u64(o, "ack", ev.ack if ev != nil else 0)
	o_u64(o, "length", u64(info.length) if info != nil else u64(ev.length))
	o_text(o, "text", info.page if info != nil else nil)
	o_bool(o, "more", info != nil && info.more)
	o_id(o, "actor", info.actor if info != nil else {})
	o_str(o, "line", info.line if info != nil else "")
	ops: []crdt.Delta_Op
	cursors: []eng.Remote_Cursor
	if ev != nil {
		ops = ev.ops
		cursors = ev.cursors
	}
	o_arr(o, "ops", len(ops))
	for op in ops {
		o_obj(o, "")
		o_enum(o, "kind", u64(op.kind), DELTA_OP_NAMES[:])
		o_u64(o, "n", u64(op.n))
		o_text(o, "text", op.text)
		o_id(o, "author", op.author)
		o_end(o)
	}
	o_end(o)
	o_arr(o, "cursors", len(cursors))
	for c in cursors {
		o_obj(o, "")
		o_id(o, "device", c.device)
		o_id(o, "actor", c.actor)
		o_arr(o, "ranges", len(c.ranges))
		for r in c.ranges {
			o_obj(o, "")
			o_i64(o, "anchor", i64(r.anchor))
			o_i64(o, "head", i64(r.head))
			o_end(o)
		}
		o_end(o)
		o_end(o)
	}
	o_end(o)
	o_enum(o, "status", u64(status_of(ev.err)) if ev != nil else 0, STATUS_NAMES[:])
}

@(private)
_on_buffer :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	s := (^Sub)(data)
	buf := make([dynamic]u8, context.temp_allocator)
	o: Out
	out_init(&o, &buf, s.json)
	emit_buffer_event(&o, u64(ev.kind) + 1, ev, nil)
	s.cb(s.data, s.id, out_finish(&o))
}

@(private)
_on_buffer_ready :: proc(data: rawptr) -> bool {
	s := (^Sub)(data)
	return s.ready == nil || s.ready(s.data)
}

@(private)
_buffer_open :: proc(a: ^Api, c: ^Call, s: ^Sub) -> (open: []u8, err: eng.Error) {
	units := eng.Units(a_u64(c, "units"))
	if units > .Utf16 {
		return nil, .Invalid
	}
	opts := eng.Buffer_Options {
		path  = a_str(c, "path"),
		line  = a_str(c, "line"),
		units = units,
		actor = a_id(c, "actor"),
		page  = a_int(c, "page", 1 << 16),
		cb    = _on_buffer,
		data  = s,
		ready = _on_buffer_ready,
	}
	info := eng.buffer_open(a.e, a_object(c, "object"), opts, context.temp_allocator) or_return
	s.buffer = info.id
	buf := make([dynamic]u8, context.temp_allocator)
	o: Out
	out_init(&o, &buf, s.json)
	emit_buffer_event(&o, 0, nil, &info)
	return out_finish(&o), .None
}

request_is :: proc(a: ^Api, req: []u8, json_form: bool, name: string) -> bool {
	c: Call
	c.api = a
	c.json = json_form
	if _decode(a, &c, req, context.temp_allocator) != .Ok || c.op == nil {
		return false
	}
	return c.op.name == name
}

sub_kick :: proc(a: ^Api, id: u64) {
	for s in a.subs {
		if s.id == id && s.buffer != 0 {
			eng.buffer_kick(a.e, s.buffer)
		}
	}
}

op_buffer_read :: proc(c: ^Call, o: ^Out) -> Status {
	r, err := eng.buffer_read(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), a_u64(c, "rev"), a_int(c, "from"), a_int(c, "len", 1 << 16), context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_u64(o, "rev", r.rev)
	o_u64(o, "ack", r.ack)
	o_u64(o, "from", u64(r.from))
	o_u64(o, "length", u64(r.length))
	o_text(o, "text", r.text)
	return .Ok
}

op_buffer_edit :: proc(c: ^Call, o: ^Out) -> Status {
	pos := a_u64s(c, "pos")
	del := a_u64s(c, "del")
	ins := a_strs(c, "ins")
	if len(del) != len(pos) || len(ins) != len(pos) {
		return .Invalid
	}
	edits := make([]eng.Buffer_Edit, len(pos), context.temp_allocator)
	for i in 0 ..< len(pos) {
		if pos[i] > u64(crdt.MAX_POS) || del[i] > u64(crdt.MAX_POS) {
			return .Invalid
		}
		edits[i] = eng.Buffer_Edit{int(pos[i]), int(del[i]), transmute([]u8)ins[i]}
	}
	ack, rev, err := eng.buffer_edit(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), a_u64(c, "rev"), edits, a_u64(c, "group"))
	if err != .None {
		return status_of(err)
	}
	o_u64(o, "ack", ack)
	o_u64(o, "rev", rev)
	return .Ok
}

op_buffer_ack :: proc(c: ^Call, o: ^Out) -> Status {
	return status_of(eng.buffer_ack(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), a_u64(c, "rev")))
}

op_buffer_undo :: proc(c: ^Call, o: ^Out) -> Status {
	done, err := eng.buffer_undo(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")))
	if err != .None {
		return status_of(err)
	}
	o_bool(o, "done", done)
	return .Ok
}

op_buffer_redo :: proc(c: ^Call, o: ^Out) -> Status {
	done, err := eng.buffer_redo(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")))
	if err != .None {
		return status_of(err)
	}
	o_bool(o, "done", done)
	return .Ok
}

op_buffer_anchors :: proc(c: ^Call, o: ^Out) -> Status {
	raw := a_u64s(c, "positions")
	pos := make([]int, len(raw), context.temp_allocator)
	for p, i in raw {
		pos[i] = int(min(p, u64(crdt.MAX_POS)))
	}
	bias := crdt.Bias.After if a_u64(c, "bias") == 1 else crdt.Bias.Before
	list, err := eng.buffer_anchors(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), a_u64(c, "rev"), pos, bias, context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "anchors", len(list))
	for a in list {
		o_str(o, "", anchor_text(a))
	}
	o_end(o)
	return .Ok
}

op_buffer_resolve :: proc(c: ^Call, o: ^Out) -> Status {
	texts := a_strs(c, "anchors")
	list := make([]eng.Anchor, len(texts), context.temp_allocator)
	for t, i in texts {
		a, ok := anchor_parse(t)
		if !ok {
			return .Invalid
		}
		list[i] = a
	}
	pos, rev, ack, err := eng.buffer_resolve(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), list, context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_arr(o, "positions", len(pos))
	for p in pos {
		o_i64(o, "", i64(p))
	}
	o_end(o)
	o_u64(o, "rev", rev)
	o_u64(o, "ack", ack)
	return .Ok
}

op_buffer_cursors :: proc(c: ^Call, o: ^Out) -> Status {
	raw := a_u64s(c, "ranges")
	if len(raw) % 2 != 0 {
		return .Invalid
	}
	ranges := make([]eng.Cursor_Range, len(raw) / 2, context.temp_allocator)
	for &r, i in ranges {
		r = eng.Cursor_Range{int(min(raw[2 * i], u64(crdt.MAX_POS))), int(min(raw[2 * i + 1], u64(crdt.MAX_POS)))}
	}
	return status_of(eng.buffer_cursors(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), a_u64(c, "rev"), ranges))
}

op_buffer_text :: proc(c: ^Call, o: ^Out) -> Status {
	text, rev, err := eng.buffer_text(c.api.e, eng.Buffer_Id(a_u64(c, "buffer")), context.temp_allocator)
	if err != .None {
		return status_of(err)
	}
	o_u64(o, "rev", rev)
	o_text(o, "text", text)
	return .Ok
}

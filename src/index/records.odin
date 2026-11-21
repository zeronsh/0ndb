package index

import "base:runtime"
import "../prim"
import "../thread"

Device :: struct {
	hlc:      prim.Hlc,
	name:     string,
	platform: string,
}

Entity :: struct {
	id:     prim.Id,
	hlc:    prim.Hlc,
	fields: []Field,
}

Thread_Entity :: distinct Entity

Worktree_Entity :: distinct Entity

Cursor :: struct {
	source: prim.Id,
	offset: i64,
	hlc:    prim.Hlc,
}

Rejected :: struct {
	cmd:    prim.Id,
	reason: Reject_Reason,
	detail: string,
	hlc:    prim.Hlc,
}

Record :: union {
	Device,
	Thread_Entity,
	Worktree_Entity,
	Cursor,
	Rejected,
}

Thread_Update :: struct {
	id:       prim.Id,
	hlc:      prim.Hlc,
	title:    Maybe(string),
	worktree: Maybe(prim.Id),
	provider: Maybe(string),
	model:    Maybe(string),
	host:     Maybe(prim.Id),
	created:  Maybe(u64),
	activity: Maybe(u64),
	archived: Maybe(bool),
	pinned:   Maybe(bool),
	leaf:     Maybe(i64),
	length:   Maybe(i64),
	status:   Maybe(Status_Value),
	pending:  Maybe(u32),
	usage:    Maybe(thread.Usage),
}

Worktree_Update :: struct {
	id:           prim.Id,
	hlc:          prim.Hlc,
	path:         Maybe(string),
	host:         Maybe(prim.Id),
	repository:   Maybe(string),
	branch:       Maybe(string),
	source:       Maybe(prim.Id),
	fork_version: Maybe([]u8),
	archived:     Maybe(bool),
}

Cmd_Kind :: enum u8 {
	New_Thread        = 1,
	Send              = 2,
	Queue             = 3,
	Steer             = 4,
	Edit_Queued       = 5,
	Cancel_Queued     = 6,
	Edit_Message      = 7,
	Regenerate        = 8,
	Switch_Sibling    = 9,
	Back_To_Message   = 10,
	Interrupt         = 11,
	Answer_Permission = 12,
	Set_Model         = 13,
	Rename            = 14,
	Archive           = 15,
	Fork              = 16,
	Land              = 17,
	Want_Objects      = 18,
}

Cmd :: struct {
	id:      prim.Id,
	hlc:     prim.Hlc,
	host:    prim.Id,
	thread:  prim.Id,
	kind:    Cmd_Kind,
	payload: []u8,
}

New_Thread :: struct {
	worktree:    prim.Id,
	provider:    string,
	model:       string,
	title:       string,
	text:        string,
	attachments: []thread.Attachment,
}

Send :: struct {
	text:        string,
	attachments: []thread.Attachment,
}

Queue :: struct {
	text:        string,
	attachments: []thread.Attachment,
}

Steer :: struct {
	text: string,
}

Edit_Queued :: struct {
	item:        i64,
	text:        string,
	attachments: []thread.Attachment,
}

Cancel_Queued :: struct {
	item: i64,
}

Edit_Message :: struct {
	msg:         i64,
	text:        string,
	attachments: []thread.Attachment,
}

Regenerate :: struct {
	msg: i64,
}

Switch_Sibling :: struct {
	msg: i64,
}

Back_To_Message :: struct {
	msg: i64,
}

Interrupt :: struct {}

Answer_Permission :: struct {
	msg:     i64,
	request: string,
	allow:   bool,
	text:    string,
}

Set_Model :: struct {
	provider: string,
	model:    string,
}

Rename :: struct {
	title: string,
}

Archive :: struct {
	archived: bool,
}

Fork :: struct {
	msg:        i64,
	new_thread: prim.Id,
}

Land :: struct {
	worktree: prim.Id,
}

Want_Objects :: struct {
	oids: [][]u8,
}

Payload :: union {
	New_Thread,
	Send,
	Queue,
	Steer,
	Edit_Queued,
	Cancel_Queued,
	Edit_Message,
	Regenerate,
	Switch_Sibling,
	Back_To_Message,
	Interrupt,
	Answer_Permission,
	Set_Model,
	Rename,
	Archive,
	Fork,
	Land,
	Want_Objects,
}

encode_device :: proc(w: ^prim.Writer, d: Device) {
	prim.write_u8(w, u8(Kind.Device))
	prim.write_u64le(w, u64(d.hlc))
	prim.write_str(w, d.name)
	prim.write_str(w, d.platform)
}

encode_entity :: proc(w: ^prim.Writer, kind: Kind, e: Entity) {
	prim.write_u8(w, u8(kind))
	prim.write_id(w, e.id)
	prim.write_u64le(w, u64(e.hlc))
	prim.write_uvarint(w, u64(len(e.fields)))
	for f in e.fields {
		prim.write_u8(w, f.tag)
		prim.write_uvarint(w, u64(e.hlc) - u64(f.hlc) if f.hlc <= e.hlc else 0)
		prim.write_bytes(w, f.value)
	}
}

encode_cursor :: proc(w: ^prim.Writer, c: Cursor) {
	prim.write_u8(w, u8(Kind.Cursor))
	prim.write_id(w, c.source)
	prim.write_uvarint(w, u64(max(c.offset, 0)))
	prim.write_u64le(w, u64(c.hlc))
}

encode_rejected :: proc(w: ^prim.Writer, r: Rejected) {
	prim.write_u8(w, u8(Kind.Rejected))
	prim.write_id(w, r.cmd)
	prim.write_u8(w, u8(r.reason))
	prim.write_str(w, r.detail)
	prim.write_u64le(w, u64(r.hlc))
}

@(private)
Field_Buf :: struct {
	fields: [len(Thread_Tag) + 1]Field,
	n:      int,
	scratch: [len(Thread_Tag) + 1][48]u8,
}

@(private)
_add :: proc(b: ^Field_Buf, tag: u8, hlc: prim.Hlc, value: []u8) {
	b.fields[b.n] = Field{tag, hlc, value}
	b.n += 1
}

@(private)
_add_uv :: proc(b: ^Field_Buf, tag: u8, hlc: prim.Hlc, v: u64) {
	s := &b.scratch[b.n]
	n := prim.put_uvarint(s[:], v)
	_add(b, tag, hlc, s[:n])
}

@(private)
_add_id :: proc(b: ^Field_Buf, tag: u8, hlc: prim.Hlc, id: prim.Id) {
	s := &b.scratch[b.n]
	v := id
	copy(s[:16], v[:])
	_add(b, tag, hlc, s[:16])
}

@(private)
_add_bool :: proc(b: ^Field_Buf, tag: u8, hlc: prim.Hlc, v: bool) {
	s := &b.scratch[b.n]
	s[0] = 1 if v else 0
	_add(b, tag, hlc, s[:1])
}

encode_thread_update :: proc(w: ^prim.Writer, u: Thread_Update) {
	b: Field_Buf
	h := u.hlc
	if v, ok := u.title.?; ok {
		_add(&b, u8(Thread_Tag.Title), h, transmute([]u8)v)
	}
	if v, ok := u.worktree.?; ok {
		_add_id(&b, u8(Thread_Tag.Worktree), h, v)
	}
	if v, ok := u.provider.?; ok {
		_add(&b, u8(Thread_Tag.Provider), h, transmute([]u8)v)
	}
	if v, ok := u.model.?; ok {
		_add(&b, u8(Thread_Tag.Model), h, transmute([]u8)v)
	}
	if v, ok := u.host.?; ok {
		_add_id(&b, u8(Thread_Tag.Host), h, v)
	}
	if v, ok := u.created.?; ok {
		_add_uv(&b, u8(Thread_Tag.Created), h, v)
	}
	if v, ok := u.activity.?; ok {
		_add_uv(&b, u8(Thread_Tag.Activity), h, v)
	}
	if v, ok := u.archived.?; ok {
		_add_bool(&b, u8(Thread_Tag.Archived), h, v)
	}
	if v, ok := u.pinned.?; ok {
		_add_bool(&b, u8(Thread_Tag.Pinned), h, v)
	}
	if v, ok := u.leaf.?; ok {
		_add_uv(&b, u8(Thread_Tag.Leaf), h, u64(max(v, 0)))
	}
	if v, ok := u.length.?; ok {
		_add_uv(&b, u8(Thread_Tag.Length), h, u64(max(v, 0)))
	}
	if v, ok := u.status.?; ok {
		s := &b.scratch[b.n]
		s[0] = u8(v.status)
		n := prim.put_uvarint(s[1:], u64(v.queued))
		_add(&b, u8(Thread_Tag.Status), h, s[:1 + n])
	}
	if v, ok := u.pending.?; ok {
		_add_uv(&b, u8(Thread_Tag.Pending), h, u64(v))
	}
	if v, ok := u.usage.?; ok {
		s := &b.scratch[b.n]
		n := 0
		n += prim.put_uvarint(s[n:], 4)
		for x in ([4]u64{v.input, v.output, v.cache_read, v.cache_write}) {
			if n + 10 > len(s) {
				break
			}
			n += prim.put_uvarint(s[n:], x)
		}
		_add(&b, u8(Thread_Tag.Usage), h, s[:n])
	}
	encode_entity(w, .Thread, Entity{u.id, h, b.fields[:b.n]})
}

encode_worktree_update :: proc(w: ^prim.Writer, u: Worktree_Update) {
	b: Field_Buf
	h := u.hlc
	if v, ok := u.path.?; ok {
		_add(&b, u8(Worktree_Tag.Path), h, transmute([]u8)v)
	}
	if v, ok := u.host.?; ok {
		_add_id(&b, u8(Worktree_Tag.Host), h, v)
	}
	if v, ok := u.repository.?; ok {
		_add(&b, u8(Worktree_Tag.Repository), h, transmute([]u8)v)
	}
	if v, ok := u.branch.?; ok {
		_add(&b, u8(Worktree_Tag.Branch), h, transmute([]u8)v)
	}
	if v, ok := u.source.?; ok {
		_add_id(&b, u8(Worktree_Tag.Source), h, v)
	}
	if v, ok := u.fork_version.?; ok {
		_add(&b, u8(Worktree_Tag.Fork_Version), h, v)
	}
	if v, ok := u.archived.?; ok {
		_add_bool(&b, u8(Worktree_Tag.Archived), h, v)
	}
	encode_entity(w, .Worktree, Entity{u.id, h, b.fields[:b.n]})
}

decode_record :: proc(body: []u8, allocator := context.temp_allocator) -> (rec: Record, err: Error) {
	r := prim.reader(body)
	kind := Kind(prim.read_u8(&r))
	switch kind {
	case .Device:
		d: Device
		d.hlc = prim.Hlc(prim.read_u64le(&r))
		d.name = prim.read_str(&r)
		d.platform = prim.read_str(&r)
		rec = d
	case .Thread, .Worktree:
		e: Entity
		e.id = prim.read_id(&r)
		e.hlc = prim.Hlc(prim.read_u64le(&r))
		n := prim.read_uvarint(&r)
		if r.err == .None && (n > MAX_FIELDS || n > u64(prim.reader_remaining(&r) / 3)) {
			return nil, .Corrupt
		}
		if r.err == .None && n > 0 {
			fields, aerr := make([]Field, int(n), allocator)
			if aerr != nil {
				return nil, .No_Memory
			}
			for &f in fields {
				f.tag = prim.read_u8(&r)
				age := prim.read_uvarint(&r)
				f.value = prim.read_bytes(&r)
				if age > u64(e.hlc) {
					prim.reader_fail(&r, .Invalid)
				}
				f.hlc = prim.Hlc(u64(e.hlc) - age)
			}
			e.fields = fields
		}
		rec = Thread_Entity(e) if kind == .Thread else Worktree_Entity(e)
	case .Cursor:
		c: Cursor
		c.source = prim.read_id(&r)
		off := prim.read_uvarint(&r)
		if off > u64(max(i64)) {
			return nil, .Corrupt
		}
		c.offset = i64(off)
		c.hlc = prim.Hlc(prim.read_u64le(&r))
		rec = c
	case .Rejected:
		j: Rejected
		j.cmd = prim.read_id(&r)
		j.reason = Reject_Reason(prim.read_u8(&r))
		j.detail = prim.read_str(&r)
		j.hlc = prim.Hlc(prim.read_u64le(&r))
		rec = j
	case:
		return nil, .Unsupported
	}
	if r.err != .None {
		return nil, .Corrupt
	}
	return rec, .None
}

value_str :: proc "contextless" (v: []u8) -> string {
	return string(v)
}

value_id :: proc "contextless" (v: []u8) -> (id: prim.Id, ok: bool) {
	if len(v) != 16 {
		return
	}
	copy(id[:], v)
	return id, true
}

value_u64 :: proc "contextless" (v: []u8) -> (x: u64, ok: bool) {
	n: int
	x, n = prim.get_uvarint(v)
	return x, n > 0 && n == len(v)
}

value_bool :: proc "contextless" (v: []u8) -> (bool, bool) {
	if len(v) != 1 || v[0] > 1 {
		return false, false
	}
	return v[0] == 1, true
}

value_status :: proc "contextless" (v: []u8) -> (s: Status_Value, ok: bool) {
	if len(v) < 2 || v[0] > u8(max(thread.Status)) {
		return
	}
	q, n := prim.get_uvarint(v[1:])
	if n <= 0 || 1 + n != len(v) || q > u64(max(u32)) {
		return
	}
	return Status_Value{thread.Status(v[0]), u32(q)}, true
}

value_usage :: proc "contextless" (v: []u8) -> (u: thread.Usage, ok: bool) {
	r := prim.reader(v)
	u = thread.decode_usage(&r)
	return u, prim.reader_done(&r)
}

encode_cmd :: proc(w: ^prim.Writer, c: Cmd, p: Payload) {
	buf := make([dynamic]u8, context.temp_allocator)
	pw := prim.writer(&buf)
	kind := _payload_kind(p)
	encode_payload(&pw, p)
	if pw.err != .None {
		w.err = pw.err
		return
	}
	prim.write_u8(w, u8(Cmd_Record.Cmd))
	prim.write_id(w, c.id)
	prim.write_u64le(w, u64(c.hlc))
	prim.write_id(w, c.host)
	prim.write_id(w, c.thread)
	prim.write_u8(w, u8(kind))
	prim.write_bytes(w, buf[:])
}

decode_cmd :: proc "contextless" (body: []u8) -> (c: Cmd, err: Error) {
	r := prim.reader(body)
	if Cmd_Record(prim.read_u8(&r)) != .Cmd {
		return c, .Unsupported
	}
	c.id = prim.read_id(&r)
	c.hlc = prim.Hlc(prim.read_u64le(&r))
	c.host = prim.read_id(&r)
	c.thread = prim.read_id(&r)
	c.kind = Cmd_Kind(prim.read_u8(&r))
	c.payload = prim.read_bytes(&r)
	if r.err != .None {
		return c, .Corrupt
	}
	return c, .None
}

@(private)
_payload_kind :: proc(p: Payload) -> Cmd_Kind {
	switch _ in p {
	case New_Thread:
		return .New_Thread
	case Send:
		return .Send
	case Queue:
		return .Queue
	case Steer:
		return .Steer
	case Edit_Queued:
		return .Edit_Queued
	case Cancel_Queued:
		return .Cancel_Queued
	case Edit_Message:
		return .Edit_Message
	case Regenerate:
		return .Regenerate
	case Switch_Sibling:
		return .Switch_Sibling
	case Back_To_Message:
		return .Back_To_Message
	case Interrupt:
		return .Interrupt
	case Answer_Permission:
		return .Answer_Permission
	case Set_Model:
		return .Set_Model
	case Rename:
		return .Rename
	case Archive:
		return .Archive
	case Fork:
		return .Fork
	case Land:
		return .Land
	case Want_Objects:
		return .Want_Objects
	}
	return Cmd_Kind(0)
}

@(private)
_put_atts :: proc(w: ^prim.Writer, atts: []thread.Attachment) {
	prim.write_uvarint(w, u64(len(atts)))
	for a in atts {
		prim.write_str(w, a.name)
		prim.write_str(w, a.mime)
		prim.write_bytes(w, a.oid)
		prim.write_uvarint(w, a.size)
	}
}

@(private)
_get_atts :: proc(r: ^prim.Reader, allocator: runtime.Allocator) -> []thread.Attachment {
	n := prim.read_uvarint(r)
	if r.err != .None || n == 0 {
		return nil
	}
	if n > u64(prim.reader_remaining(r) / 4) {
		prim.reader_fail(r, .Invalid)
		return nil
	}
	out, err := make([]thread.Attachment, int(n), allocator)
	if err != nil {
		prim.reader_fail(r, .No_Memory)
		return nil
	}
	for &a in out {
		a.name = prim.read_str(r)
		a.mime = prim.read_str(r)
		a.oid = prim.read_bytes(r)
		a.size = prim.read_uvarint(r)
		if len(a.oid) != 0 && len(a.oid) != 20 && len(a.oid) != 32 {
			prim.reader_fail(r, .Invalid)
		}
	}
	return out
}

@(private)
_put_off :: proc(w: ^prim.Writer, off: i64) {
	prim.write_uvarint(w, u64(max(off, 0)))
}

@(private)
_get_off :: proc "contextless" (r: ^prim.Reader) -> i64 {
	v := prim.read_uvarint(r)
	if v > u64(max(i64)) {
		prim.reader_fail(r, .Overflow)
		return 0
	}
	return i64(v)
}

encode_payload :: proc(w: ^prim.Writer, p: Payload) {
	switch v in p {
	case New_Thread:
		prim.write_id(w, v.worktree)
		prim.write_str(w, v.provider)
		prim.write_str(w, v.model)
		prim.write_str(w, v.title)
		prim.write_str(w, v.text)
		_put_atts(w, v.attachments)
	case Send:
		prim.write_str(w, v.text)
		_put_atts(w, v.attachments)
	case Queue:
		prim.write_str(w, v.text)
		_put_atts(w, v.attachments)
	case Steer:
		prim.write_str(w, v.text)
	case Edit_Queued:
		_put_off(w, v.item)
		prim.write_str(w, v.text)
		_put_atts(w, v.attachments)
	case Cancel_Queued:
		_put_off(w, v.item)
	case Edit_Message:
		_put_off(w, v.msg)
		prim.write_str(w, v.text)
		_put_atts(w, v.attachments)
	case Regenerate:
		_put_off(w, v.msg)
	case Switch_Sibling:
		_put_off(w, v.msg)
	case Back_To_Message:
		_put_off(w, v.msg)
	case Interrupt:
	case Answer_Permission:
		_put_off(w, v.msg)
		prim.write_str(w, v.request)
		prim.write_bool(w, v.allow)
		prim.write_str(w, v.text)
	case Set_Model:
		prim.write_str(w, v.provider)
		prim.write_str(w, v.model)
	case Rename:
		prim.write_str(w, v.title)
	case Archive:
		prim.write_bool(w, v.archived)
	case Fork:
		_put_off(w, v.msg)
		prim.write_id(w, v.new_thread)
	case Land:
		prim.write_id(w, v.worktree)
	case Want_Objects:
		prim.write_uvarint(w, u64(len(v.oids)))
		for o in v.oids {
			prim.write_bytes(w, o)
		}
	}
}

decode_payload :: proc(kind: Cmd_Kind, data: []u8, allocator := context.temp_allocator) -> (p: Payload, err: Error) {
	r := prim.reader(data)
	switch kind {
	case .New_Thread:
		v: New_Thread
		v.worktree = prim.read_id(&r)
		v.provider = prim.read_str(&r)
		v.model = prim.read_str(&r)
		v.title = prim.read_str(&r)
		v.text = prim.read_str(&r)
		v.attachments = _get_atts(&r, allocator)
		p = v
	case .Send:
		v: Send
		v.text = prim.read_str(&r)
		v.attachments = _get_atts(&r, allocator)
		p = v
	case .Queue:
		v: Queue
		v.text = prim.read_str(&r)
		v.attachments = _get_atts(&r, allocator)
		p = v
	case .Steer:
		p = Steer{prim.read_str(&r)}
	case .Edit_Queued:
		v: Edit_Queued
		v.item = _get_off(&r)
		v.text = prim.read_str(&r)
		v.attachments = _get_atts(&r, allocator)
		p = v
	case .Cancel_Queued:
		p = Cancel_Queued{_get_off(&r)}
	case .Edit_Message:
		v: Edit_Message
		v.msg = _get_off(&r)
		v.text = prim.read_str(&r)
		v.attachments = _get_atts(&r, allocator)
		p = v
	case .Regenerate:
		p = Regenerate{_get_off(&r)}
	case .Switch_Sibling:
		p = Switch_Sibling{_get_off(&r)}
	case .Back_To_Message:
		p = Back_To_Message{_get_off(&r)}
	case .Interrupt:
		p = Interrupt{}
	case .Answer_Permission:
		v: Answer_Permission
		v.msg = _get_off(&r)
		v.request = prim.read_str(&r)
		v.allow = prim.read_bool(&r)
		v.text = prim.read_str(&r)
		p = v
	case .Set_Model:
		v: Set_Model
		v.provider = prim.read_str(&r)
		v.model = prim.read_str(&r)
		p = v
	case .Rename:
		p = Rename{prim.read_str(&r)}
	case .Archive:
		p = Archive{prim.read_bool(&r)}
	case .Fork:
		v: Fork
		v.msg = _get_off(&r)
		v.new_thread = prim.read_id(&r)
		p = v
	case .Land:
		p = Land{prim.read_id(&r)}
	case .Want_Objects:
		n := prim.read_uvarint(&r)
		if r.err == .None && (n > MAX_OIDS || n > u64(prim.reader_remaining(&r))) {
			return nil, .Corrupt
		}
		v: Want_Objects
		if r.err == .None && n > 0 {
			oids, aerr := make([][]u8, int(n), allocator)
			if aerr != nil {
				return nil, .No_Memory
			}
			for &o in oids {
				o = prim.read_bytes(&r)
				if r.err == .None && len(o) != 20 && len(o) != 32 {
					prim.reader_fail(&r, .Invalid)
				}
			}
			v.oids = oids
		}
		p = v
	case:
		return nil, .Unsupported
	}
	if r.err == .No_Memory {
		return nil, .No_Memory
	}
	if r.err != .None {
		return nil, .Corrupt
	}
	return p, .None
}

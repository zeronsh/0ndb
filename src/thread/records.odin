package thread

import "base:runtime"
import "../prim"

Head :: struct {
	version:  u8,
	thread:   prim.Id,
	created:  prim.Hlc,
	worktree: prim.Id,
	provider: string,
	model:    string,
	title:    string,
}

Msg :: struct {
	role:             Role,
	parent:           i64,
	depth:            i64,
	jump:             i64,
	jump_depth:       i64,
	prev_sibling:     i64,
	fork_head:        i64,
	prev_leaf_event:  i64,
	parent_seal:      i64,
	cmd:              prim.Id,
	hlc:              prim.Hlc,
	version:          []u8,
	git_branch:       string,
	git_commit:       []u8,
	provider_session: string,
	provider_msg:     string,
}

Block :: struct {
	msg:   i64,
	prev:  i64,
	index: u32,
	flags: Block_Flags,
	kind:  Block_Kind,
	id:    string,
	name:  string,
	data:  []u8,
	ref:   Ref,
}

Seal :: struct {
	msg:          i64,
	last_block:   i64,
	status:       Seal_Status,
	usage:        Usage,
	provider_msg: string,
	cmd:          prim.Id,
}

Leaf :: struct {
	msg:             i64,
	prev_leaf_event: i64,
	fork_head:       i64,
	cmd:             prim.Id,
}

Queue :: struct {
	cmd:          prim.Id,
	item:         i64,
	mode:         Queue_Mode,
	text:         string,
	attachments:  []Attachment,
	prev_pending: i64,
	list:         []Pending_Entry,
}

Unqueue :: struct {
	cmd:          prim.Id,
	item:         i64,
	outcome:      Outcome,
	msg:          i64,
	prev_pending: i64,
	list:         []Pending_Entry,
}

Scope :: struct {
	msg:    i64,
	kind:   Scope_Kind,
	id:     prim.Id,
	actor:  prim.Id,
	before: []u8,
	after:  []u8,
	cmd:    prim.Id,
}

Interrupted :: struct {
	msg:        i64,
	last_block: i64,
	attempt:    u8,
	revive:     bool,
	cmd:        prim.Id,
}

Revived :: struct {
	msg:     i64,
	attempt: u8,
	cmd:     prim.Id,
}

Body :: union {
	Head,
	Msg,
	Block,
	Seal,
	Leaf,
	Queue,
	Unqueue,
	Scope,
	Interrupted,
	Revived,
}

Record :: struct {
	off:   i64,
	kind:  Kind,
	links: Links,
	body:  Body,
}

@(private)
MAX_LIST :: 1 << 16

@(private)
USAGE_FIELDS :: 4

@(private)
MAX_USAGE_FIELDS :: 64

put_back :: proc(w: ^prim.Writer, off, target: i64) {
	if target <= 0 || target > off {
		prim.write_uvarint(w, 0)
		return
	}
	prim.write_uvarint(w, u64(off - target + 1))
}

get_back :: proc "contextless" (r: ^prim.Reader, off: i64, strict: bool) -> i64 {
	v := prim.read_uvarint(r)
	if r.err != .None || v == 0 {
		return 0
	}
	if off <= 0 || v > u64(off) || (strict && v < 2) {
		prim.reader_fail(r, .Invalid)
		return 0
	}
	return off - i64(v) + 1
}

@(private)
_put_opt_id :: proc(w: ^prim.Writer, id: prim.Id) {
	if prim.id_is_zero(id) {
		prim.write_u8(w, 0)
		return
	}
	prim.write_u8(w, 1)
	prim.write_id(w, id)
}

@(private)
_get_opt_id :: proc "contextless" (r: ^prim.Reader) -> prim.Id {
	switch prim.read_u8(r) {
	case 0:
		return {}
	case 1:
		return prim.read_id(r)
	}
	prim.reader_fail(r, .Invalid)
	return {}
}

@(private)
_get_oid :: proc "contextless" (r: ^prim.Reader) -> []u8 {
	b := prim.read_bytes(r)
	if len(b) != 0 && len(b) != 20 && len(b) != 32 {
		prim.reader_fail(r, .Invalid)
		return nil
	}
	return b
}

@(private)
_get_enum :: proc "contextless" (r: ^prim.Reader, lo, hi: u8) -> u8 {
	v := prim.read_u8(r)
	if v < lo || v > hi {
		prim.reader_fail(r, .Invalid)
		return lo
	}
	return v
}

@(private)
_get_u32 :: proc "contextless" (r: ^prim.Reader) -> u32 {
	v := prim.read_uvarint(r)
	if v > u64(max(u32)) {
		prim.reader_fail(r, .Overflow)
		return 0
	}
	return u32(v)
}

@(private)
_get_depth :: proc "contextless" (r: ^prim.Reader) -> i64 {
	v := prim.read_uvarint(r)
	if v > 1 << 40 {
		prim.reader_fail(r, .Overflow)
		return 0
	}
	return i64(v)
}

encode_links :: proc(w: ^prim.Writer, off: i64, l: ^Links) {
	put_back(w, off, l.leaf_event)
	put_back(w, off, l.leaf_seal)
	put_back(w, off, l.pending)
	prim.write_u8(w, u8(l.open_len))
	for i in 0 ..< l.open_len {
		o := &l.open[i]
		put_back(w, off, o.msg)
		put_back(w, off, o.last)
		prim.write_uvarint(w, u64(o.blocks))
		prim.write_u8(w, u8(o.state) | o.attempt << 2)
	}
}

decode_links :: proc "contextless" (r: ^prim.Reader, off: i64, l: ^Links) {
	l^ = {}
	l.leaf_event = get_back(r, off, false)
	l.leaf_seal = get_back(r, off, false)
	l.pending = get_back(r, off, false)
	n := int(prim.read_u8(r))
	if n > MAX_OPEN {
		prim.reader_fail(r, .Invalid)
		return
	}
	for i in 0 ..< n {
		o := &l.open[i]
		o.msg = get_back(r, off, false)
		o.last = get_back(r, off, false)
		o.blocks = _get_u32(r)
		b := prim.read_u8(r)
		if b & 3 > 1 || o.msg == 0 || (o.last != 0 && o.last <= o.msg) {
			prim.reader_fail(r, .Invalid)
			return
		}
		o.state = Open_State(b & 3)
		o.attempt = b >> 2
	}
	l.open_len = n
}

@(private)
_begin :: proc(w: ^prim.Writer, kind: Kind, off: i64, l: ^Links) {
	prim.write_u8(w, u8(kind))
	encode_links(w, off, l)
}

encode_head :: proc(w: ^prim.Writer, h: ^Head) {
	l: Links
	_begin(w, .Head, 0, &l)
	prim.write_u8(w, FORMAT_VERSION)
	prim.write_id(w, h.thread)
	prim.write_u64le(w, u64(h.created))
	prim.write_id(w, h.worktree)
	prim.write_str(w, h.provider)
	prim.write_str(w, h.model)
	prim.write_str(w, h.title)
}

encode_msg :: proc(w: ^prim.Writer, off: i64, l: ^Links, m: ^Msg) {
	_begin(w, .Msg, off, l)
	prim.write_u8(w, u8(m.role))
	put_back(w, off, m.parent)
	prim.write_uvarint(w, u64(m.depth))
	put_back(w, off, m.jump)
	prim.write_uvarint(w, u64(m.jump_depth))
	put_back(w, off, m.prev_sibling)
	put_back(w, off, m.fork_head)
	put_back(w, off, m.prev_leaf_event)
	put_back(w, off, m.parent_seal)
	_put_opt_id(w, m.cmd)
	prim.write_u64le(w, u64(m.hlc))
	prim.write_bytes(w, m.version)
	prim.write_str(w, m.git_branch)
	prim.write_bytes(w, m.git_commit)
	prim.write_str(w, m.provider_session)
	prim.write_str(w, m.provider_msg)
}

encode_block :: proc(w: ^prim.Writer, off: i64, l: ^Links, b: ^Block) {
	_begin(w, .Block, off, l)
	put_back(w, off, b.msg)
	put_back(w, off, b.prev)
	prim.write_uvarint(w, u64(b.index))
	prim.write_u8(w, transmute(u8)b.flags)
	if .Start in b.flags {
		prim.write_u8(w, u8(b.kind))
		prim.write_str(w, b.id)
		prim.write_str(w, b.name)
	}
	if .Ref in b.flags {
		prim.write_bytes(w, b.ref.oid)
		prim.write_uvarint(w, b.ref.size)
		prim.write_bytes(w, b.ref.preview)
	} else {
		prim.write_bytes(w, b.data)
	}
}

encode_usage :: proc(w: ^prim.Writer, u: Usage) {
	prim.write_uvarint(w, USAGE_FIELDS)
	prim.write_uvarint(w, u.input)
	prim.write_uvarint(w, u.output)
	prim.write_uvarint(w, u.cache_read)
	prim.write_uvarint(w, u.cache_write)
}

decode_usage :: proc "contextless" (r: ^prim.Reader) -> (u: Usage) {
	n := prim.read_uvarint(r)
	if n > MAX_USAGE_FIELDS {
		prim.reader_fail(r, .Invalid)
		return
	}
	for i in 0 ..< int(n) {
		v := prim.read_uvarint(r)
		switch i {
		case 0:
			u.input = v
		case 1:
			u.output = v
		case 2:
			u.cache_read = v
		case 3:
			u.cache_write = v
		}
	}
	return
}

encode_seal :: proc(w: ^prim.Writer, off: i64, l: ^Links, s: ^Seal) {
	_begin(w, .Seal, off, l)
	put_back(w, off, s.msg)
	put_back(w, off, s.last_block)
	prim.write_u8(w, u8(s.status))
	encode_usage(w, s.usage)
	prim.write_str(w, s.provider_msg)
	_put_opt_id(w, s.cmd)
}

encode_leaf :: proc(w: ^prim.Writer, off: i64, l: ^Links, f: ^Leaf) {
	_begin(w, .Leaf, off, l)
	put_back(w, off, f.msg)
	put_back(w, off, f.prev_leaf_event)
	put_back(w, off, f.fork_head)
	_put_opt_id(w, f.cmd)
}

@(private)
_put_list :: proc(w: ^prim.Writer, off: i64, list: []Pending_Entry) {
	prim.write_uvarint(w, u64(len(list)))
	for e in list {
		put_back(w, off, e.item)
		put_back(w, off, e.latest)
	}
}

encode_queue :: proc(w: ^prim.Writer, off: i64, l: ^Links, q: ^Queue) {
	_begin(w, .Queue, off, l)
	_put_opt_id(w, q.cmd)
	put_back(w, off, q.item if q.item != off else 0)
	prim.write_u8(w, u8(q.mode))
	prim.write_str(w, q.text)
	prim.write_uvarint(w, u64(len(q.attachments)))
	for a in q.attachments {
		prim.write_str(w, a.name)
		prim.write_str(w, a.mime)
		prim.write_bytes(w, a.oid)
		prim.write_uvarint(w, a.size)
	}
	put_back(w, off, q.prev_pending)
	_put_list(w, off, q.list)
}

encode_unqueue :: proc(w: ^prim.Writer, off: i64, l: ^Links, u: ^Unqueue) {
	_begin(w, .Unqueue, off, l)
	_put_opt_id(w, u.cmd)
	put_back(w, off, u.item)
	prim.write_u8(w, u8(u.outcome))
	put_back(w, off, u.msg)
	put_back(w, off, u.prev_pending)
	_put_list(w, off, u.list)
}

encode_scope :: proc(w: ^prim.Writer, off: i64, l: ^Links, s: ^Scope) {
	_begin(w, .Scope, off, l)
	put_back(w, off, s.msg)
	prim.write_u8(w, u8(s.kind))
	prim.write_id(w, s.id)
	prim.write_id(w, s.actor)
	prim.write_bytes(w, s.before)
	prim.write_bytes(w, s.after)
	_put_opt_id(w, s.cmd)
}

encode_interrupted :: proc(w: ^prim.Writer, off: i64, l: ^Links, s: ^Interrupted) {
	_begin(w, .Interrupted, off, l)
	put_back(w, off, s.msg)
	put_back(w, off, s.last_block)
	prim.write_u8(w, s.attempt)
	prim.write_bool(w, s.revive)
	_put_opt_id(w, s.cmd)
}

encode_revived :: proc(w: ^prim.Writer, off: i64, l: ^Links, s: ^Revived) {
	_begin(w, .Revived, off, l)
	put_back(w, off, s.msg)
	prim.write_u8(w, s.attempt)
	_put_opt_id(w, s.cmd)
}

peek_kind :: proc "contextless" (body: []u8) -> Kind {
	if len(body) == 0 {
		return Kind(0)
	}
	return Kind(body[0])
}

decode_head :: proc "contextless" (r: ^prim.Reader) -> (h: Head) {
	h.version = prim.read_u8(r)
	if h.version == 0 {
		prim.reader_fail(r, .Invalid)
		return
	}
	h.thread = prim.read_id(r)
	h.created = prim.Hlc(prim.read_u64le(r))
	h.worktree = prim.read_id(r)
	h.provider = prim.read_str(r)
	h.model = prim.read_str(r)
	h.title = prim.read_str(r)
	return
}

decode_msg :: proc "contextless" (r: ^prim.Reader, off: i64) -> (m: Msg) {
	m.role = Role(_get_enum(r, 1, 3))
	m.parent = get_back(r, off, true)
	m.depth = _get_depth(r)
	m.jump = get_back(r, off, true)
	m.jump_depth = _get_depth(r)
	m.prev_sibling = get_back(r, off, true)
	m.fork_head = get_back(r, off, false)
	m.prev_leaf_event = get_back(r, off, true)
	m.parent_seal = get_back(r, off, true)
	m.cmd = _get_opt_id(r)
	m.hlc = prim.Hlc(prim.read_u64le(r))
	m.version = prim.read_bytes(r)
	m.git_branch = prim.read_str(r)
	m.git_commit = _get_oid(r)
	m.provider_session = prim.read_str(r)
	m.provider_msg = prim.read_str(r)
	if r.err != .None {
		return
	}
	bad := m.depth < 1 || m.jump_depth >= m.depth || (m.jump == 0) != (m.jump_depth == 0) || (m.parent == 0) != (m.depth == 1)
	bad ||= m.jump > m.parent || (m.parent_seal != 0 && m.parent_seal <= m.parent) || (m.prev_sibling != 0 && m.prev_sibling <= m.parent)
	bad ||= m.fork_head != off && m.fork_head > m.prev_leaf_event
	bad ||= (m.prev_sibling != 0) != (m.fork_head == off)
	if bad {
		prim.reader_fail(r, .Invalid)
	}
	return
}

decode_block :: proc "contextless" (r: ^prim.Reader, off: i64) -> (b: Block) {
	b.msg = get_back(r, off, true)
	b.prev = get_back(r, off, true)
	b.index = _get_u32(r)
	flags := prim.read_u8(r)
	if flags & ~u8(7) != 0 {
		prim.reader_fail(r, .Invalid)
		return
	}
	b.flags = transmute(Block_Flags)flags
	if .Start in b.flags {
		b.kind = Block_Kind(_get_enum(r, 1, u8(max(Block_Kind))))
		b.id = prim.read_str(r)
		b.name = prim.read_str(r)
	}
	if .Ref in b.flags {
		b.ref.oid = _get_oid(r)
		b.ref.size = prim.read_uvarint(r)
		b.ref.preview = prim.read_bytes(r)
	} else {
		b.data = prim.read_bytes(r)
	}
	if r.err == .None && (b.msg == 0 || (b.prev != 0 && b.prev <= b.msg)) {
		prim.reader_fail(r, .Invalid)
	}
	return
}

decode_seal :: proc "contextless" (r: ^prim.Reader, off: i64) -> (s: Seal) {
	s.msg = get_back(r, off, true)
	s.last_block = get_back(r, off, true)
	s.status = Seal_Status(_get_enum(r, 1, u8(max(Seal_Status))))
	s.usage = decode_usage(r)
	s.provider_msg = prim.read_str(r)
	s.cmd = _get_opt_id(r)
	if r.err == .None && (s.msg == 0 || (s.last_block != 0 && s.last_block <= s.msg)) {
		prim.reader_fail(r, .Invalid)
	}
	return
}

decode_leaf :: proc "contextless" (r: ^prim.Reader, off: i64) -> (f: Leaf) {
	f.msg = get_back(r, off, true)
	f.prev_leaf_event = get_back(r, off, true)
	f.fork_head = get_back(r, off, true)
	f.cmd = _get_opt_id(r)
	if r.err == .None && (f.msg == 0 || f.prev_leaf_event == 0 || f.fork_head > f.prev_leaf_event) {
		prim.reader_fail(r, .Invalid)
	}
	return
}

@(private)
_get_list :: proc(r: ^prim.Reader, off: i64, allocator: runtime.Allocator) -> []Pending_Entry {
	n := prim.read_uvarint(r)
	if r.err != .None {
		return nil
	}
	if n > MAX_PENDING || n > u64(prim.reader_remaining(r) / 2) {
		prim.reader_fail(r, .Invalid)
		return nil
	}
	if n == 0 {
		return nil
	}
	list, err := make([]Pending_Entry, int(n), allocator)
	if err != nil {
		prim.reader_fail(r, .No_Memory)
		return nil
	}
	for &e in list {
		e.item = get_back(r, off, false)
		e.latest = get_back(r, off, false)
		if r.err == .None && (e.item == 0 || e.latest < e.item) {
			prim.reader_fail(r, .Invalid)
		}
	}
	return list
}

decode_queue :: proc(r: ^prim.Reader, off: i64, allocator := context.temp_allocator) -> (q: Queue) {
	q.cmd = _get_opt_id(r)
	q.item = get_back(r, off, true)
	if q.item == 0 {
		q.item = off
	}
	q.mode = Queue_Mode(_get_enum(r, 1, u8(max(Queue_Mode))))
	q.text = prim.read_str(r)
	n := prim.read_uvarint(r)
	if r.err == .None && (n > MAX_LIST || n > u64(prim.reader_remaining(r) / 4)) {
		prim.reader_fail(r, .Invalid)
	}
	if r.err == .None && n > 0 {
		atts, err := make([]Attachment, int(n), allocator)
		if err != nil {
			prim.reader_fail(r, .No_Memory)
			return
		}
		for &a in atts {
			a.name = prim.read_str(r)
			a.mime = prim.read_str(r)
			a.oid = _get_oid(r)
			a.size = prim.read_uvarint(r)
		}
		q.attachments = atts
	}
	q.prev_pending = get_back(r, off, true)
	q.list = _get_list(r, off, allocator)
	return
}

decode_unqueue :: proc(r: ^prim.Reader, off: i64, allocator := context.temp_allocator) -> (u: Unqueue) {
	u.cmd = _get_opt_id(r)
	u.item = get_back(r, off, true)
	u.outcome = Outcome(_get_enum(r, 1, u8(max(Outcome))))
	u.msg = get_back(r, off, true)
	u.prev_pending = get_back(r, off, true)
	u.list = _get_list(r, off, allocator)
	if r.err == .None && u.item == 0 {
		prim.reader_fail(r, .Invalid)
	}
	return
}

decode_scope :: proc "contextless" (r: ^prim.Reader, off: i64) -> (s: Scope) {
	s.msg = get_back(r, off, true)
	s.kind = Scope_Kind(_get_enum(r, 1, u8(max(Scope_Kind))))
	s.id = prim.read_id(r)
	s.actor = prim.read_id(r)
	s.before = prim.read_bytes(r)
	s.after = prim.read_bytes(r)
	s.cmd = _get_opt_id(r)
	return
}

decode_interrupted :: proc "contextless" (r: ^prim.Reader, off: i64) -> (s: Interrupted) {
	s.msg = get_back(r, off, true)
	s.last_block = get_back(r, off, true)
	s.attempt = prim.read_u8(r)
	s.revive = prim.read_bool(r)
	s.cmd = _get_opt_id(r)
	if r.err == .None && (s.msg == 0 || (s.last_block != 0 && s.last_block <= s.msg)) {
		prim.reader_fail(r, .Invalid)
	}
	return
}

decode_revived :: proc "contextless" (r: ^prim.Reader, off: i64) -> (s: Revived) {
	s.msg = get_back(r, off, true)
	s.attempt = prim.read_u8(r)
	s.cmd = _get_opt_id(r)
	if r.err == .None && s.msg == 0 {
		prim.reader_fail(r, .Invalid)
	}
	return
}

decode :: proc(data: []u8, off: i64, allocator := context.temp_allocator) -> (rec: Record, err: Error) {
	r := prim.reader(data)
	rec.off = off
	rec.kind = Kind(prim.read_u8(&r))
	decode_links(&r, off, &rec.links)
	if r.err != .None {
		return rec, .Corrupt
	}
	switch rec.kind {
	case .Head:
		if off != 0 {
			return rec, .Corrupt
		}
		rec.body = decode_head(&r)
	case .Msg:
		rec.body = decode_msg(&r, off)
	case .Block:
		rec.body = decode_block(&r, off)
	case .Seal:
		rec.body = decode_seal(&r, off)
	case .Leaf:
		rec.body = decode_leaf(&r, off)
	case .Queue:
		rec.body = decode_queue(&r, off, allocator)
	case .Unqueue:
		rec.body = decode_unqueue(&r, off, allocator)
	case .Scope:
		rec.body = decode_scope(&r, off)
	case .Interrupted:
		rec.body = decode_interrupted(&r, off)
	case .Revived:
		rec.body = decode_revived(&r, off)
	}
	if r.err == .No_Memory {
		return rec, .No_Memory
	}
	if r.err != .None {
		return rec, .Corrupt
	}
	return rec, .None
}

decode_links_only :: proc "contextless" (data: []u8, off: i64) -> (kind: Kind, l: Links, err: Error) {
	r := prim.reader(data)
	kind = Kind(prim.read_u8(&r))
	decode_links(&r, off, &l)
	if r.err != .None {
		return kind, l, .Corrupt
	}
	return kind, l, .None
}

package fshist

import "core:crypto/blake2b"
import "../crdt"
import "../fstree"
import "../prim"

Error :: enum u8 {
	None,
	Missing,
	Corrupt,
	Not_Found,
	Invalid,
	No_Memory,
	Redacted,
}

REC_BATCH :: u8(1)
REC_ACTORS :: u8(2)
REC_IMPORT :: u8(3)
REC_REDACT :: u8(4)
REC_REPLACE :: u8(5)
REC_SEAL :: u8(6)
REC_ALIAS :: u8(7)
REC_LINE :: u8(8)
REC_ACTOR :: u8(9)

TOP_CREATE :: u8(1)
TOP_MOVE :: u8(2)
TOP_REMOVE :: u8(3)
TOP_RESTORE :: u8(4)
TOP_FLAGS :: u8(5)
TOP_TARGET :: u8(6)
TOP_CONTENT :: u8(16)
TOP_GIT :: u8(17)
TOP_MOUNT :: u8(18)
TOP_OBSERVE :: u8(19)
TOP_RENAMED :: u8(21)
TOP_ACCEPT :: u8(22)

OBSERVE_VERSION :: u8(1)

Observe_Kind :: enum u8 {
	Read        = 0,
	Write_Begin = 1,
}

Observe_Op :: struct {
	kind:    Observe_Kind,
	inode:   crdt.Op_Id,
	path:    string,
	version: []crdt.Op_Id,
	hash:    [32]u8,
}

OPS_CHUNK :: 256
MOVES_CHUNK :: 512
LVIDX_REC :: 24
STATE_FORMAT :: u8(2)

Oid :: struct {
	bytes: [32]u8,
	len:   u8,
}

Raw_Oid :: [32]u8

Version :: []crdt.Op_Id

Blob_Reg :: struct {
	lamport: u64,
	actor:   prim.Id,
	seq:     u64,
	oid:     Raw_Oid,
	size:    i64,
}

Op_Ref :: struct {
	stream: u32,
	off:    u64,
	from:   u32,
	to:     u32,
}

File_Record :: struct {
	blob:       Blob_Reg,
	has_blob:   bool,
	cp_version: [dynamic]crdt.Op_Id,
	cp_text:    Raw_Oid,
	cp_spans:   [dynamic]crdt.Author_Span,
	cp_len:     i64,
	cp_count:   u32,
	has_cp:     bool,
	ops:        u32,
	base:       Op_Ref,
	has_base:   bool,
	spans_ext:  bool,
}

Content_Op :: struct {
	inode:   fstree.Inode_Id,
	oid:     Raw_Oid,
	oid_len: u8,
	size:    i64,
}

Git_Op :: struct {
	kind:   string,
	branch: string,
	commit: string,
}

Tree_Op :: struct {
	op: fstree.Op,
}

Opaque :: union {
	Tree_Op,
	Content_Op,
	Git_Op,
}

Inode_Of :: #type proc(data: rawptr, id: crdt.Op_Id) -> fstree.Inode_Id
Op_Of :: #type proc(data: rawptr, id: fstree.Inode_Id) -> crdt.Op_Id

oid_full :: proc "contextless" (raw: Raw_Oid) -> Oid {
	o := Oid{bytes = raw, len = 32}
	x := raw
	zero := true
	for b in x[20:] {
		if b != 0 {
			zero = false
			break
		}
	}
	if zero {
		o.len = 20
	}
	return o
}

oid_from_crdt :: proc "contextless" (o: crdt.Oid) -> (out: Raw_Oid) {
	x := o
	n := min(int(x.len), 32)
	copy(out[:n], x.bytes[:n])
	return
}

blob_newer :: proc(a, b: Blob_Reg) -> bool {
	if a.lamport != b.lamport {
		return a.lamport > b.lamport
	}
	if a.actor != b.actor {
		return crdt.id_less(b.actor, a.actor)
	}
	return a.seq > b.seq
}

batch_payload :: proc(body: []u8) -> (payload: []u8, ok: bool) {
	if len(body) == 0 {
		return nil, false
	}
	switch body[0] {
	case REC_BATCH, REC_IMPORT:
		return body[1:], true
	case REC_REPLACE:
		r, rok := replace_decode(body)
		return r.payload, rok
	}
	return nil, false
}

REPLACE_PREVS :: u8(0x80)

Replace :: struct {
	orig:    u64,
	kind:    u8,
	prevs:   []u8,
	payload: []u8,
}

replace_decode :: proc(body: []u8) -> (r: Replace, ok: bool) {
	if len(body) < 3 || body[0] != REC_REPLACE {
		return {}, false
	}
	orig, n := prim.get_uvarint(body[1:])
	if n <= 0 || 1 + n >= len(body) {
		return {}, false
	}
	at := 1 + n
	k := body[at]
	at += 1
	r.orig = orig
	r.kind = k & ~REPLACE_PREVS
	if k & REPLACE_PREVS != 0 {
		c, cn := prim.get_uvarint(body[at:])
		if cn <= 0 || c > u64(len(body)) {
			return {}, false
		}
		at += cn
		start := at
		for _ in 0 ..< c {
			_, pn := prim.get_uvarint(body[at:])
			if pn <= 0 {
				return {}, false
			}
			at += pn
		}
		r.prevs = body[start:at]
	}
	r.payload = body[at:]
	return r, true
}

replace_supersedes :: proc(r: Replace, off: u64) -> bool {
	if r.orig == off {
		return true
	}
	rest := r.prevs
	for len(rest) > 0 {
		v, n := prim.get_uvarint(rest)
		if n <= 0 {
			return false
		}
		if v == off {
			return true
		}
		rest = rest[n:]
	}
	return false
}

replace_old :: proc(body: []u8) -> (old: u64, ok: bool) {
	if len(body) < 2 || body[0] != REC_REPLACE {
		return 0, false
	}
	v, n := prim.get_uvarint(body[1:])
	return v, n > 0
}

encode_version :: proc(buf: ^[dynamic]u8, v: Version) {
	w := prim.writer(buf)
	prim.write_uvarint(&w, u64(len(v)))
	for x in v {
		prim.write_id(&w, x.actor)
		prim.write_uvarint(&w, x.seq)
	}
}

decode_version :: proc(data: []u8, allocator := context.allocator) -> (v: Version, err: Error) {
	rd := prim.reader(data)
	n := prim.read_uvarint(&rd)
	if n > u64(len(data)) {
		return nil, .Corrupt
	}
	out := make([]crdt.Op_Id, int(n), allocator)
	for i in 0 ..< int(n) {
		out[i].actor = prim.read_id(&rd)
		out[i].seq = prim.read_uvarint(&rd)
	}
	if !prim.reader_ok(&rd) {
		delete(out, allocator)
		return nil, .Corrupt
	}
	return out, .None
}

encode_file_record :: proc(buf: ^[dynamic]u8, r: ^File_Record) {
	w := prim.writer(buf)
	prim.write_bool(&w, r.has_blob)
	if r.has_blob {
		prim.write_uvarint(&w, r.blob.lamport)
		prim.write_id(&w, r.blob.actor)
		prim.write_uvarint(&w, r.blob.seq)
		oid := r.blob.oid
		prim.write_raw(&w, oid[:])
		prim.write_ivarint(&w, r.blob.size)
	}
	prim.write_uvarint(&w, u64(r.ops))
	prim.write_bool(&w, r.has_cp)
	if r.has_cp {
		prim.write_uvarint(&w, u64(r.cp_count))
		oid := r.cp_text
		prim.write_raw(&w, oid[:])
		prim.write_ivarint(&w, r.cp_len)
		prim.write_uvarint(&w, u64(len(r.cp_version)))
		for v in r.cp_version {
			prim.write_id(&w, v.actor)
			prim.write_uvarint(&w, v.seq)
		}
		if r.spans_ext {
			prim.write_uvarint(&w, 0)
		} else {
			encode_spans(buf, r.cp_spans[:])
		}
	}
	if r.has_base {
		prim.write_u8(&w, 1)
		prim.write_uvarint(&w, u64(r.base.stream))
		prim.write_uvarint(&w, r.base.off)
		prim.write_uvarint(&w, u64(r.base.from))
		prim.write_uvarint(&w, u64(r.base.to))
	}
	if r.has_cp && r.spans_ext {
		prim.write_u8(&w, 2)
	}
}

encode_spans :: proc(buf: ^[dynamic]u8, spans: []crdt.Author_Span) {
	w := prim.writer(buf)
	prim.write_uvarint(&w, u64(len(spans)))
	for s in spans {
		prim.write_id(&w, s.id.actor)
		prim.write_uvarint(&w, s.id.seq)
		prim.write_uvarint(&w, u64(s.len))
		flags: u8 = 1 if s.redacted else 0
		if s.op != s.id {
			flags |= 2
		}
		prim.write_u8(&w, flags)
		if s.op != s.id {
			prim.write_id(&w, s.op.actor)
			prim.write_uvarint(&w, s.op.seq)
		}
	}
}

decode_spans :: proc(data: []u8, out: ^[dynamic]crdt.Author_Span) -> Error {
	rd := prim.reader(data)
	read_spans(&rd, out) or_return
	return .None if prim.reader_ok(&rd) else .Corrupt
}

@(private)
read_spans :: proc(rd: ^prim.Reader, out: ^[dynamic]crdt.Author_Span) -> Error {
	ns := prim.read_uvarint(rd)
	if ns > u64(prim.reader_remaining(rd)) {
		return .Corrupt
	}
	for _ in 0 ..< ns {
		a := prim.read_id(rd)
		seq := prim.read_uvarint(rd)
		l := prim.read_uvarint(rd)
		flags := prim.read_u8(rd)
		span := crdt.Author_Span {
			id       = {a, seq},
			op       = {a, seq},
			len      = int(l),
			redacted = flags & 1 != 0,
		}
		if flags & 2 != 0 {
			span.op.actor = prim.read_id(rd)
			span.op.seq = prim.read_uvarint(rd)
		}
		append(out, span)
	}
	return .None
}

decode_file_record :: proc(data: []u8, r: ^File_Record) -> Error {
	rd := prim.reader(data)
	r.has_blob = prim.read_bool(&rd)
	if r.has_blob {
		r.blob.lamport = prim.read_uvarint(&rd)
		r.blob.actor = prim.read_id(&rd)
		r.blob.seq = prim.read_uvarint(&rd)
		prim.read_fixed(&rd, r.blob.oid[:])
		r.blob.size = prim.read_ivarint(&rd)
	}
	r.ops = u32(prim.read_uvarint(&rd))
	r.has_cp = prim.read_bool(&rd)
	if r.has_cp {
		r.cp_count = u32(prim.read_uvarint(&rd))
		prim.read_fixed(&rd, r.cp_text[:])
		r.cp_len = prim.read_ivarint(&rd)
		nv := prim.read_uvarint(&rd)
		if nv > u64(prim.reader_remaining(&rd)) {
			return .Corrupt
		}
		for _ in 0 ..< nv {
			a := prim.read_id(&rd)
			append(&r.cp_version, crdt.Op_Id{a, prim.read_uvarint(&rd)})
		}
		read_spans(&rd, &r.cp_spans) or_return
	}
	for prim.reader_ok(&rd) && !prim.reader_done(&rd) {
		switch prim.read_u8(&rd) {
		case 1:
			r.has_base = true
			r.base.stream = u32(prim.read_uvarint(&rd))
			r.base.off = prim.read_uvarint(&rd)
			r.base.from = u32(prim.read_uvarint(&rd))
			r.base.to = u32(prim.read_uvarint(&rd))
		case 2:
			r.spans_ext = true
		case:
			return .Corrupt
		}
	}
	if !prim.reader_ok(&rd) {
		return .Corrupt
	}
	return .None
}

file_record_destroy :: proc(r: ^File_Record) {
	delete(r.cp_version)
	delete(r.cp_spans)
	r.cp_version = nil
	r.cp_spans = nil
}

encode_op_ref :: proc(buf: ^[dynamic]u8, ref: Op_Ref) {
	w := prim.writer(buf)
	prim.write_uvarint(&w, u64(ref.stream))
	prim.write_uvarint(&w, ref.off)
	prim.write_uvarint(&w, u64(ref.from))
	prim.write_uvarint(&w, u64(ref.to))
}

op_ref_at :: proc(chunk: []u8, k: u32) -> (ref: Op_Ref, ok: bool) {
	rd := prim.reader(chunk)
	for _ in 0 ..= k {
		ref.stream = u32(prim.read_uvarint(&rd))
		ref.off = prim.read_uvarint(&rd)
		ref.from = u32(prim.read_uvarint(&rd))
		ref.to = u32(prim.read_uvarint(&rd))
	}
	return ref, prim.reader_ok(&rd)
}

page_key :: proc(k: crdt.Page_Key, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, 10, allocator)
	out[0] = 'g'
	out[1] = 'p'
	prim.put_u32le(out[2:6], k.actor)
	prim.put_u32le(out[6:10], k.page)
	return out
}

inode_key :: proc(prefix: string, id: fstree.Inode_Id, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, len(prefix) + 12, allocator)
	n := copy(out, prefix)
	prim.put_u32le(out[n:], id.actor)
	prim.put_u64le(out[n + 4:], id.seq)
	return out
}

node_key :: proc(k: fstree.Node_Key, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, 22, allocator)
	out[0] = 't'
	out[1] = 'n'
	prim.put_u32le(out[2:6], k.dir.actor)
	prim.put_u64le(out[6:14], k.dir.seq)
	prim.put_u64le(out[14:22], k.node)
	return out
}

ops_key :: proc(id: fstree.Inode_Id, chunk: u32, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, 18, allocator)
	out[0] = 'f'
	out[1] = 'o'
	prim.put_u32le(out[2:6], id.actor)
	prim.put_u64le(out[6:14], id.seq)
	prim.put_u32le(out[14:18], chunk)
	return out
}

moves_key :: proc(chunk: u64, allocator := context.temp_allocator) -> []u8 {
	out := make([]u8, 10, allocator)
	out[0] = 'm'
	out[1] = 'v'
	prim.put_u64le(out[2:10], chunk)
	return out
}

decode_moves :: proc(data: []u8, from_lamport: u64, out: ^[dynamic]fstree.Move_Ref) -> bool {
	rd := prim.reader(data)
	for !prim.reader_done(&rd) {
		m: fstree.Move_Ref
		m.event.lamport = prim.read_uvarint(&rd)
		m.event.seq = prim.read_uvarint(&rd)
		m.event.actor = u32(prim.read_uvarint(&rd))
		m.inode.actor = u32(prim.read_uvarint(&rd))
		m.inode.seq = prim.read_uvarint(&rd)
		if !prim.reader_ok(&rd) {
			return false
		}
		if m.event.lamport >= from_lamport {
			append(out, m)
		}
	}
	return true
}

encode_move :: proc(buf: ^[dynamic]u8, m: fstree.Move_Ref) {
	w := prim.writer(buf)
	prim.write_uvarint(&w, m.event.lamport)
	prim.write_uvarint(&w, m.event.seq)
	prim.write_uvarint(&w, u64(m.event.actor))
	prim.write_uvarint(&w, u64(m.inode.actor))
	prim.write_uvarint(&w, m.inode.seq)
}

encode_tree_op :: proc(buf: ^[dynamic]u8, op: fstree.Op, data: rawptr, op_of: Op_Of) {
	w := prim.writer(buf)
	put :: proc(w: ^prim.Writer, id: fstree.Inode_Id, data: rawptr, op_of: Op_Of) {
		o: crdt.Op_Id
		if id != fstree.ROOT {
			o = op_of(data, id)
		}
		prim.write_id(w, o.actor)
		prim.write_uvarint(w, o.seq)
	}
	switch o in op {
	case fstree.Op_Create:
		prim.write_u8(&w, TOP_CREATE)
		put(&w, o.parent, data, op_of)
		prim.write_u8(&w, u8(o.kind))
		prim.write_u8(&w, transmute(u8)o.flags)
		prim.write_str(&w, o.name)
		prim.write_str(&w, o.target)
	case fstree.Op_Move:
		prim.write_u8(&w, TOP_MOVE)
		put(&w, o.inode, data, op_of)
		put(&w, o.parent, data, op_of)
		prim.write_str(&w, o.name)
	case fstree.Op_Remove:
		prim.write_u8(&w, TOP_REMOVE)
		put(&w, o.inode, data, op_of)
	case fstree.Op_Restore:
		prim.write_u8(&w, TOP_RESTORE)
		put(&w, o.inode, data, op_of)
	case fstree.Op_Set_Flags:
		prim.write_u8(&w, TOP_FLAGS)
		put(&w, o.inode, data, op_of)
		prim.write_u8(&w, transmute(u8)o.mask)
		prim.write_u8(&w, transmute(u8)o.value)
	case fstree.Op_Set_Target:
		prim.write_u8(&w, TOP_TARGET)
		put(&w, o.inode, data, op_of)
		prim.write_str(&w, o.target)
	}
}

encode_content_op :: proc(buf: ^[dynamic]u8, inode: crdt.Op_Id, oid: Raw_Oid, oid_len: int, size: i64) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_CONTENT)
	prim.write_id(&w, inode.actor)
	prim.write_uvarint(&w, inode.seq)
	prim.write_u8(&w, u8(oid_len))
	x := oid
	prim.write_raw(&w, x[:oid_len])
	prim.write_uvarint(&w, u64(size))
}

encode_git_op :: proc(buf: ^[dynamic]u8, kind, branch, commit: string) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_GIT)
	prim.write_str(&w, kind)
	prim.write_str(&w, branch)
	prim.write_str(&w, commit)
}

encode_observe :: proc(buf: ^[dynamic]u8, o: Observe_Op) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_OBSERVE)
	prim.write_u8(&w, OBSERVE_VERSION)
	prim.write_u8(&w, u8(o.kind))
	prim.write_id(&w, o.inode.actor)
	prim.write_uvarint(&w, o.inode.seq)
	prim.write_str(&w, o.path)
	prim.write_uvarint(&w, u64(len(o.version)))
	for v in o.version {
		prim.write_id(&w, v.actor)
		prim.write_uvarint(&w, v.seq)
	}
	h := o.hash
	prim.write_raw(&w, h[:])
}

decode_observe :: proc(content: []u8, allocator := context.temp_allocator) -> (o: Observe_Op, ok: bool) {
	r := prim.reader(content)
	if prim.read_u8(&r) != TOP_OBSERVE || prim.read_u8(&r) != OBSERVE_VERSION {
		return o, false
	}
	k := prim.read_u8(&r)
	if k > u8(max(Observe_Kind)) {
		return o, false
	}
	o.kind = Observe_Kind(k)
	o.inode.actor = prim.read_id(&r)
	o.inode.seq = prim.read_uvarint(&r)
	o.path = prim.read_str(&r)
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || n > u64(prim.reader_remaining(&r)) {
		return o, false
	}
	v := make([]crdt.Op_Id, int(n), allocator)
	for i in 0 ..< int(n) {
		v[i].actor = prim.read_id(&r)
		v[i].seq = prim.read_uvarint(&r)
	}
	o.version = v
	prim.read_fixed(&r, o.hash[:])
	return o, prim.reader_ok(&r) && prim.reader_remaining(&r) == 0
}

decode_opaque :: proc(content: []u8, data: rawptr, inode_of: Inode_Of) -> (out: Opaque, ok: bool) {
	r := prim.reader(content)
	tag := prim.read_u8(&r)
	read_inode :: proc(r: ^prim.Reader, data: rawptr, inode_of: Inode_Of) -> fstree.Inode_Id {
		a := prim.read_id(r)
		s := prim.read_uvarint(r)
		id := crdt.Op_Id{a, s}
		if id == {} {
			return fstree.ROOT
		}
		return inode_of(data, id)
	}
	switch tag {
	case TOP_CREATE:
		parent := read_inode(&r, data, inode_of)
		kind := prim.read_u8(&r)
		flags := prim.read_u8(&r)
		name := prim.read_str(&r)
		target := prim.read_str(&r)
		if kind > u8(max(fstree.Kind)) {
			return nil, false
		}
		out = Tree_Op{fstree.Op_Create{parent, name, fstree.Kind(kind), transmute(fstree.Flags)flags & fstree.ALL_FLAGS, target}}
	case TOP_MOVE:
		inode := read_inode(&r, data, inode_of)
		parent := read_inode(&r, data, inode_of)
		name := prim.read_str(&r)
		out = Tree_Op{fstree.Op_Move{inode, parent, name}}
	case TOP_REMOVE:
		out = Tree_Op{fstree.Op_Remove{read_inode(&r, data, inode_of)}}
	case TOP_RESTORE:
		out = Tree_Op{fstree.Op_Restore{read_inode(&r, data, inode_of)}}
	case TOP_FLAGS:
		inode := read_inode(&r, data, inode_of)
		mask := prim.read_u8(&r)
		value := prim.read_u8(&r)
		out = Tree_Op{fstree.Op_Set_Flags{inode, transmute(fstree.Flags)mask & fstree.ALL_FLAGS, transmute(fstree.Flags)value & fstree.ALL_FLAGS}}
	case TOP_TARGET:
		inode := read_inode(&r, data, inode_of)
		out = Tree_Op{fstree.Op_Set_Target{inode, prim.read_str(&r)}}
	case TOP_CONTENT:
		c: Content_Op
		c.inode = read_inode(&r, data, inode_of)
		osz := prim.read_u8(&r)
		if osz > 32 {
			return nil, false
		}
		c.oid_len = osz
		prim.read_fixed(&r, c.oid[:osz])
		c.size = i64(prim.read_uvarint(&r))
		out = c
	case TOP_GIT:
		g: Git_Op
		g.kind = prim.read_str(&r)
		g.branch = prim.read_str(&r)
		g.commit = prim.read_str(&r)
		out = g
	case:
		return nil, false
	}
	return out, prim.reader_ok(&r)
}

text_targets :: proc(b: ^crdt.Batch, allocator := context.temp_allocator) -> []crdt.Op_Id {
	out := make([dynamic]crdt.Op_Id, allocator)
	for op in b.ops {
		if op.kind == .Opaque {
			continue
		}
		seen := false
		for t in out {
			if t == op.target {
				seen = true
				break
			}
		}
		if !seen {
			append(&out, op.target)
		}
	}
	return out[:]
}

ACTOR_INGEST :: u8(1)

ingestion_actor :: proc(device, mount: prim.Id) -> (id: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb ingestion actor"
	blake2b.update(&ctx, transmute([]u8)tag)
	d, m := device, mount
	blake2b.update(&ctx, d[:])
	blake2b.update(&ctx, m[:])
	blake2b.final(&ctx, id[:])
	return
}

encode_actor_record :: proc(buf: ^[dynamic]u8, actor, mount: prim.Id) {
	w := prim.writer(buf)
	prim.write_u8(&w, REC_ACTOR)
	prim.write_u8(&w, ACTOR_INGEST)
	prim.write_id(&w, actor)
	prim.write_id(&w, mount)
}

decode_actor_record :: proc(body: []u8, device: prim.Id) -> (actor: prim.Id, ok: bool) {
	if len(body) == 0 || body[0] != REC_ACTOR {
		return
	}
	r := prim.reader(body[1:])
	kind := prim.read_u8(&r)
	a := prim.read_id(&r)
	m := prim.read_id(&r)
	if !prim.reader_ok(&r) || kind != ACTOR_INGEST || a != ingestion_actor(device, m) {
		return
	}
	return a, true
}

actor_key :: proc(actor: prim.Id, allocator := context.temp_allocator) -> []u8 {
	k := make([]u8, 3 + len(actor), allocator)
	copy(k, "ao:")
	a := actor
	copy(k[3:], a[:])
	return k
}

Renamed_Op :: struct {
	dest:   crdt.Op_Id,
	source: crdt.Op_Id,
}

encode_renamed :: proc(buf: ^[dynamic]u8, o: Renamed_Op) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_RENAMED)
	prim.write_u8(&w, 1)
	prim.write_id(&w, o.dest.actor)
	prim.write_uvarint(&w, o.dest.seq)
	prim.write_id(&w, o.source.actor)
	prim.write_uvarint(&w, o.source.seq)
}

decode_renamed :: proc(content: []u8) -> (o: Renamed_Op, ok: bool) {
	r := prim.reader(content)
	if prim.read_u8(&r) != TOP_RENAMED || prim.read_u8(&r) != 1 {
		return o, false
	}
	o.dest.actor = prim.read_id(&r)
	o.dest.seq = prim.read_uvarint(&r)
	o.source.actor = prim.read_id(&r)
	o.source.seq = prim.read_uvarint(&r)
	return o, prim.reader_ok(&r) && prim.reader_remaining(&r) == 0
}

Accept_Op :: struct {
	kind:   u8,
	dest:   crdt.Op_Id,
	source: crdt.Op_Id,
	revert: prim.Id,
	index:  u64,
}

encode_accept :: proc(buf: ^[dynamic]u8, o: Accept_Op) {
	w := prim.writer(buf)
	prim.write_u8(&w, TOP_ACCEPT)
	prim.write_u8(&w, 1)
	prim.write_u8(&w, o.kind)
	prim.write_id(&w, o.dest.actor)
	prim.write_uvarint(&w, o.dest.seq)
	prim.write_id(&w, o.source.actor)
	prim.write_uvarint(&w, o.source.seq)
	prim.write_id(&w, o.revert)
	prim.write_uvarint(&w, o.index)
}

decode_accept :: proc(content: []u8) -> (o: Accept_Op, ok: bool) {
	r := prim.reader(content)
	if prim.read_u8(&r) != TOP_ACCEPT || prim.read_u8(&r) != 1 {
		return o, false
	}
	o.kind = prim.read_u8(&r)
	o.dest.actor = prim.read_id(&r)
	o.dest.seq = prim.read_uvarint(&r)
	o.source.actor = prim.read_id(&r)
	o.source.seq = prim.read_uvarint(&r)
	o.revert = prim.read_id(&r)
	o.index = prim.read_uvarint(&r)
	return o, prim.reader_ok(&r) && prim.reader_remaining(&r) == 0
}

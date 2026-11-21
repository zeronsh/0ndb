package convo

import "../obj"
import "../prim"

Msg :: struct {
	role:        Role,
	author:      prim.Id,
	parent:      Ref,
	depth:       i64,
	jump:        Ref,
	jump_depth:  i64,
	hlc:         prim.Hlc,
	files:       []File_Delta,
	provider:    string,
	model:       string,
	native:      string,
	native_msg:  string,
	runner:      prim.Id,
	intent:      Ref,
	parent_seal: Ref,
	claim:       i64,
	files_prev:  Ref,
	files_run:   u32,
	files_base:  []File_Delta,
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
	blob:  Blob,
}

Seal :: struct {
	msg:        i64,
	last_block: i64,
	status:     Seal_Status,
	usage:      Usage,
	native_msg: string,
	hlc:        prim.Hlc,
	claim:      i64,
}

Leaf :: struct {
	msg: Ref,
	hlc: prim.Hlc,
}

Fork :: struct {
	parent:    Ref,
	child:     Ref,
	child_hlc: prim.Hlc,
}

Remember :: struct {
	parent:      Ref,
	child:       Ref,
	child_hlc:   prim.Hlc,
	leaf:        Ref,
	leaf_hlc:    prim.Hlc,
	child_depth: i64,
	leaf_depth:  i64,
}

Digest_Assign :: struct {
	msg:    Ref,
	runner: prim.Id,
	hlc:    prim.Hlc,
}

Digest_Claim :: struct {
	msg:        Ref,
	claim:      i64,
	lease:      u64,
	stamp:      prim.Hlc,
	assign_hlc: prim.Hlc,
}

Digest_Mount :: struct {
	name:    string,
	tree:    prim.Id,
	line:    prim.Id,
	path:    string,
	stamp:   prim.Hlc,
	removed: bool,
}

Forks :: struct {
	forks:      []Remember,
	assigns:    []Digest_Assign,
	claims:     []Digest_Claim,
	mounts:     []Digest_Mount,
	superseded: []Superseded,
	landed:     []Ref,
	spine:      Spine_Index,
}

Spine_Index :: struct {
	at:     i64,
	c:      i64,
	blocks: []i64,
}

Spine :: struct {
	target: Ref,
	prev:   i64,
	c:      i64,
	first:  i64,
	nodes:  []u8,
}

Assign :: struct {
	msg:    Ref,
	runner: prim.Id,
	hlc:    prim.Hlc,
}

Claim :: struct {
	msg:        Ref,
	runner:     prim.Id,
	lease:      u64,
	assign_hlc: prim.Hlc,
	lines:      []Line,
}

Queue :: struct {
	text:        string,
	attachments: []Attachment,
}

Steer :: struct {
	msg:         Ref,
	text:        string,
	attachments: []Attachment,
}

Edit_Queued :: struct {
	item:        Ref,
	text:        string,
	attachments: []Attachment,
}

Cancel :: struct {
	item: Ref,
}

Interrupt :: struct {
	msg: Ref,
}

Answer :: struct {
	request: Ref,
	allow:   bool,
	text:    string,
}

Unqueue :: struct {
	item:    Ref,
	outcome: Outcome,
	msg:     Ref,
	cause:   Ref,
}

Superseded :: struct {
	run: Ref,
	by:  Ref,
}

Landed :: struct {
	run:   Ref,
	files: []File_Delta,
}

Mount :: struct {
	name: string,
	tree: prim.Id,
	line: prim.Id,
	path: string,
}

Unmount :: struct {
	name: string,
}

Compact :: struct {
	from:    Ref,
	to:      Ref,
	summary: string,
	blob:    Blob,
}

Await :: struct {
	tasks:     []prim.Id,
	condition: Condition,
	deadline:  prim.Hlc,
	expr:      string,
}

Scope :: struct {
	msg:    Ref,
	kind:   Scope_Kind,
	id:     prim.Id,
	actor:  prim.Id,
	before: []u8,
	after:  []u8,
}

Interrupted :: struct {
	msg:        i64,
	last_block: i64,
	attempt:    u8,
	revive:     bool,
}

Revived :: struct {
	msg:     i64,
	attempt: u8,
}

Recorded :: struct {
	source:      string,
	external_id: string,
	sequence:    u64,
	msg:         Ref,
}

Body :: union {
	Msg,
	Block,
	Seal,
	Leaf,
	Fork,
	Remember,
	Forks,
	Assign,
	Claim,
	Queue,
	Steer,
	Edit_Queued,
	Cancel,
	Interrupt,
	Answer,
	Unqueue,
	Superseded,
	Landed,
	Mount,
	Unmount,
	Compact,
	Await,
	Scope,
	Interrupted,
	Revived,
	Recorded,
	Spine,
}

Record :: struct {
	env:     obj.Envelope,
	summary: Summary,
	body:    Body,
	stamp:   prim.Hlc,
}

body_kind :: proc "contextless" (b: Body) -> Kind {
	switch _ in b {
	case Msg:
		return .Msg
	case Block:
		return .Block
	case Seal:
		return .Seal
	case Leaf:
		return .Leaf
	case Fork:
		return .Fork
	case Remember:
		return .Remember
	case Forks:
		return .Forks
	case Assign:
		return .Assign
	case Claim:
		return .Claim
	case Queue:
		return .Queue
	case Steer:
		return .Steer
	case Edit_Queued:
		return .Edit_Queued
	case Cancel:
		return .Cancel
	case Interrupt:
		return .Interrupt
	case Answer:
		return .Answer
	case Unqueue:
		return .Unqueue
	case Superseded:
		return .Superseded
	case Landed:
		return .Landed
	case Mount:
		return .Mount
	case Unmount:
		return .Unmount
	case Compact:
		return .Compact
	case Await:
		return .Await
	case Scope:
		return .Scope
	case Interrupted:
		return .Interrupted
	case Revived:
		return .Revived
	case Recorded:
		return .Recorded
	case Spine:
		return .Spine
	}
	return Kind(0)
}

is_event_kind :: proc "contextless" (k: Kind) -> bool {
	#partial switch k {
	case .Fork, .Remember, .Forks, .Assign, .Claim, .Queue, .Steer, .Edit_Queued, .Cancel, .Interrupt, .Answer, .Unqueue, .Superseded, .Landed, .Mount, .Unmount, .Compact, .Await, .Recorded, .Spine:
		return true
	}
	return false
}

is_intent_kind :: proc "contextless" (k: Kind) -> bool {
	#partial switch k {
	case .Queue, .Steer, .Interrupt, .Answer, .Await:
		return true
	}
	return false
}

encode_usage :: proc(w: ^prim.Writer, u: Usage) {
	prim.write_uvarint(w, 4)
	prim.write_uvarint(w, u.input)
	prim.write_uvarint(w, u.output)
	prim.write_uvarint(w, u.cache_read)
	prim.write_uvarint(w, u.cache_write)
}

decode_usage :: proc "contextless" (r: ^prim.Reader) -> (u: Usage) {
	n := prim.read_uvarint(r)
	if n > 64 {
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

@(private)
_nested :: proc(w: ^prim.Writer, tag: u32, b: []u8) {
	prim.write_uvarint(w, u64(tag) << 2 | obj.F_BYTES)
	prim.write_bytes(w, b)
}

@(private)
_put_atts :: proc(w: ^prim.Writer, tag: u32, atts: []Attachment) {
	for a in atts {
		ab := make([dynamic]u8, context.temp_allocator)
		aw := prim.writer(&ab)
		obj.tw_str(&aw, 1, a.name)
		obj.tw_str(&aw, 2, a.mime)
		obj.tw_bytes(&aw, 3, a.oid)
		obj.tw_uv(&aw, 4, a.size)
		_nested(w, tag, ab[:])
	}
}

@(private)
_put_files :: proc(w: ^prim.Writer, tag: u32, files: []File_Delta) {
	for f in files {
		fb := make([dynamic]u8, context.temp_allocator)
		fw := prim.writer(&fb)
		obj.tw_str(&fw, 1, f.mount)
		obj.tw_id(&fw, 2, f.tree)
		obj.tw_id(&fw, 3, f.line)
		obj.tw_bytes(&fw, 4, f.version)
		_nested(w, tag, fb[:])
	}
}

@(private)
_put_lines :: proc(w: ^prim.Writer, tag: u32, lines: []Line) {
	for l in lines {
		lb := make([dynamic]u8, context.temp_allocator)
		lw := prim.writer(&lb)
		obj.tw_str(&lw, 1, l.mount)
		obj.tw_id(&lw, 2, l.line)
		_nested(w, tag, lb[:])
	}
}

@(private)
_put_blob :: proc(w: ^prim.Writer, t0: u32, b: Blob) {
	obj.tw_bytes(w, t0, b.oid)
	obj.tw_uv(w, t0 + 1, b.size)
	obj.tw_bytes(w, t0 + 2, b.preview)
}

encode_fields :: proc(w: ^prim.Writer, off: i64, body: Body) {
	switch v in body {
	case Msg:
		obj.tw_uv(w, 1, u64(v.role))
		obj.tw_id(w, 2, v.author)
		obj.tw_ref(w, 3, off, v.parent)
		obj.tw_uv(w, 4, u64(v.depth))
		obj.tw_ref(w, 5, off, v.jump)
		obj.tw_uv(w, 6, u64(v.jump_depth))
		obj.tw_u64(w, 7, u64(v.hlc))
		_put_files(w, 8, v.files)
		obj.tw_str(w, 9, v.provider)
		obj.tw_str(w, 10, v.model)
		obj.tw_str(w, 11, v.native)
		obj.tw_str(w, 12, v.native_msg)
		obj.tw_id(w, 13, v.runner)
		obj.tw_ref(w, 14, off, v.intent)
		obj.tw_ref(w, 15, off, v.parent_seal)
		obj.tw_ref(w, 16, off, Ref{0, v.claim})
		obj.tw_ref(w, 17, off, v.files_prev)
		obj.tw_uv(w, 18, u64(v.files_run))
		_put_files(w, 19, v.files_base)
	case Block:
		obj.tw_ref(w, 1, off, Ref{0, v.msg})
		obj.tw_ref(w, 2, off, Ref{0, v.prev})
		obj.tw_uv(w, 3, u64(v.index) + 1)
		obj.tw_uv(w, 4, u64(transmute(u8)v.flags))
		obj.tw_uv(w, 5, u64(v.kind))
		obj.tw_str(w, 6, v.id)
		obj.tw_str(w, 7, v.name)
		obj.tw_bytes(w, 8, v.data)
		_put_blob(w, 9, v.blob)
	case Seal:
		obj.tw_ref(w, 1, off, Ref{0, v.msg})
		obj.tw_ref(w, 2, off, Ref{0, v.last_block})
		obj.tw_uv(w, 3, u64(v.status))
		ub := make([dynamic]u8, context.temp_allocator)
		uw := prim.writer(&ub)
		encode_usage(&uw, v.usage)
		obj.tw_bytes(w, 4, ub[:])
		obj.tw_str(w, 5, v.native_msg)
		obj.tw_u64(w, 6, u64(v.hlc))
		obj.tw_ref(w, 7, off, Ref{0, v.claim})
	case Leaf:
		obj.tw_ref(w, 1, off, v.msg)
		obj.tw_u64(w, 2, u64(v.hlc))
	case Fork:
		obj.tw_ref(w, 1, off, v.parent)
		obj.tw_ref(w, 2, off, v.child)
		obj.tw_u64(w, 3, u64(v.child_hlc))
	case Remember:
		_put_remember(w, off, v)
	case Forks:
		for e in v.forks {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			_put_remember(&bw, off, e)
			_nested(w, 1, b[:])
		}
		for e in v.assigns {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			obj.tw_ref(&bw, 1, off, e.msg)
			obj.tw_id(&bw, 2, e.runner)
			obj.tw_u64(&bw, 3, u64(e.hlc))
			_nested(w, 2, b[:])
		}
		for e in v.claims {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			obj.tw_ref(&bw, 1, off, e.msg)
			obj.tw_ref(&bw, 2, off, Ref{0, e.claim})
			obj.tw_uv(&bw, 3, e.lease)
			obj.tw_u64(&bw, 4, u64(e.stamp))
			obj.tw_u64(&bw, 5, u64(e.assign_hlc))
			_nested(w, 3, b[:])
		}
		for e in v.mounts {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			obj.tw_str(&bw, 1, e.name)
			obj.tw_id(&bw, 2, e.tree)
			obj.tw_id(&bw, 3, e.line)
			obj.tw_str(&bw, 4, e.path)
			obj.tw_u64(&bw, 5, u64(e.stamp))
			obj.tw_bool(&bw, 6, e.removed)
			_nested(w, 4, b[:])
		}
		for e in v.superseded {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			obj.tw_ref(&bw, 1, off, e.run)
			obj.tw_ref(&bw, 2, off, e.by)
			_nested(w, 5, b[:])
		}
		for e in v.landed {
			obj.tw_ref(w, 6, off, e)
		}
		if v.spine.at != 0 || v.spine.c != 0 {
			b := make([dynamic]u8, context.temp_allocator)
			bw := prim.writer(&b)
			obj.tw_ref(&bw, 1, off, Ref{0, v.spine.at})
			obj.tw_uv(&bw, 2, u64(v.spine.c))
			pb := make([dynamic]u8, context.temp_allocator)
			pw := prim.writer(&pb)
			last: i64
			for x in v.spine.blocks {
				prim.write_uvarint(&pw, _zigzag(x - last))
				last = x
			}
			obj.tw_bytes(&bw, 3, pb[:])
			_nested(w, 7, b[:])
		}
	case Spine:
		obj.tw_ref(w, 1, off, v.target)
		obj.tw_ref(w, 2, off, Ref{0, v.prev})
		obj.tw_uv(w, 3, u64(v.c))
		obj.tw_uv(w, 4, u64(v.first))
		obj.tw_bytes(w, 5, v.nodes)
	case Assign:
		obj.tw_ref(w, 1, off, v.msg)
		obj.tw_id(w, 2, v.runner)
		obj.tw_u64(w, 3, u64(v.hlc))
	case Claim:
		obj.tw_ref(w, 1, off, v.msg)
		obj.tw_id(w, 2, v.runner)
		obj.tw_uv(w, 3, v.lease)
		obj.tw_u64(w, 4, u64(v.assign_hlc))
		_put_lines(w, 5, v.lines)
	case Queue:
		obj.tw_str(w, 1, v.text)
		_put_atts(w, 2, v.attachments)
	case Steer:
		obj.tw_ref(w, 1, off, v.msg)
		obj.tw_str(w, 2, v.text)
		_put_atts(w, 3, v.attachments)
	case Edit_Queued:
		obj.tw_ref(w, 1, off, v.item)
		obj.tw_str(w, 2, v.text)
		_put_atts(w, 3, v.attachments)
	case Cancel:
		obj.tw_ref(w, 1, off, v.item)
	case Interrupt:
		obj.tw_ref(w, 1, off, v.msg)
	case Answer:
		obj.tw_ref(w, 1, off, v.request)
		obj.tw_bool(w, 2, v.allow)
		obj.tw_str(w, 3, v.text)
	case Unqueue:
		obj.tw_ref(w, 1, off, v.item)
		obj.tw_uv(w, 2, u64(v.outcome))
		obj.tw_ref(w, 3, off, v.msg)
		obj.tw_ref(w, 4, off, v.cause)
	case Superseded:
		obj.tw_ref(w, 1, off, v.run)
		obj.tw_ref(w, 2, off, v.by)
	case Landed:
		obj.tw_ref(w, 1, off, v.run)
		_put_files(w, 2, v.files)
	case Mount:
		obj.tw_str(w, 1, v.name)
		obj.tw_id(w, 2, v.tree)
		obj.tw_id(w, 3, v.line)
		obj.tw_str(w, 4, v.path)
	case Unmount:
		obj.tw_str(w, 1, v.name)
	case Compact:
		obj.tw_ref(w, 1, off, v.from)
		obj.tw_ref(w, 2, off, v.to)
		obj.tw_str(w, 3, v.summary)
		_put_blob(w, 4, v.blob)
	case Await:
		for t in v.tasks {
			obj.tw_id(w, 1, t)
		}
		obj.tw_uv(w, 2, u64(v.condition))
		obj.tw_u64(w, 3, u64(v.deadline))
		obj.tw_str(w, 4, v.expr)
	case Scope:
		obj.tw_ref(w, 1, off, v.msg)
		obj.tw_uv(w, 2, u64(v.kind))
		obj.tw_id(w, 3, v.id)
		obj.tw_id(w, 4, v.actor)
		obj.tw_bytes(w, 5, v.before)
		obj.tw_bytes(w, 6, v.after)
	case Interrupted:
		obj.tw_ref(w, 1, off, Ref{0, v.msg})
		obj.tw_ref(w, 2, off, Ref{0, v.last_block})
		obj.tw_uv(w, 3, u64(v.attempt))
		obj.tw_bool(w, 4, v.revive)
	case Revived:
		obj.tw_ref(w, 1, off, Ref{0, v.msg})
		obj.tw_uv(w, 2, u64(v.attempt))
	case Recorded:
		obj.tw_str(w, 1, v.source)
		obj.tw_str(w, 2, v.external_id)
		obj.tw_uv(w, 3, v.sequence)
		obj.tw_ref(w, 4, off, v.msg)
	}
}

@(private)
_put_remember :: proc(w: ^prim.Writer, off: i64, v: Remember) {
	obj.tw_ref(w, 1, off, v.parent)
	obj.tw_ref(w, 2, off, v.child)
	obj.tw_u64(w, 3, u64(v.child_hlc))
	obj.tw_ref(w, 4, off, v.leaf)
	obj.tw_u64(w, 5, u64(v.leaf_hlc))
	obj.tw_uv(w, 6, u64(v.child_depth))
	obj.tw_uv(w, 7, u64(v.leaf_depth))
}

@(private)
_get_remember :: proc(d: ^obj.Dec) -> (v: Remember) {
	for obj.dec_next(d) {
		switch d.f.tag {
		case 1:
			v.parent = obj.dec_ref(d)
		case 2:
			v.child = obj.dec_ref(d)
		case 3:
			v.child_hlc = obj.dec_hlc(d)
		case 4:
			v.leaf = obj.dec_ref(d)
		case 5:
			v.leaf_hlc = obj.dec_hlc(d)
		case 6:
			v.child_depth = obj.dec_int(d)
		case 7:
			v.leaf_depth = obj.dec_int(d)
		}
	}
	return
}

@(private)
_get_att :: proc(d: ^obj.Dec, off: i64) -> (a: Attachment) {
	ad := obj.dec_init(obj.dec_bytes(d), off)
	for obj.dec_next(&ad) {
		switch ad.f.tag {
		case 1:
			a.name = obj.dec_str(&ad)
		case 2:
			a.mime = obj.dec_str(&ad)
		case 3:
			a.oid = obj.dec_oid(&ad)
		case 4:
			a.size = obj.dec_uv(&ad)
		}
	}
	d.bad ||= !obj.dec_ok(&ad)
	return
}

@(private)
_get_file :: proc(d: ^obj.Dec, off: i64) -> (f: File_Delta) {
	fd := obj.dec_init(obj.dec_bytes(d), off)
	for obj.dec_next(&fd) {
		switch fd.f.tag {
		case 1:
			f.mount = obj.dec_str(&fd)
		case 2:
			f.tree = obj.dec_id(&fd)
		case 3:
			f.line = obj.dec_id(&fd)
		case 4:
			f.version = obj.dec_bytes(&fd)
		}
	}
	d.bad ||= !obj.dec_ok(&fd)
	return
}

@(private)
_get_line :: proc(d: ^obj.Dec, off: i64) -> (l: Line) {
	ld := obj.dec_init(obj.dec_bytes(d), off)
	for obj.dec_next(&ld) {
		switch ld.f.tag {
		case 1:
			l.mount = obj.dec_str(&ld)
		case 2:
			l.line = obj.dec_id(&ld)
		}
	}
	d.bad ||= !obj.dec_ok(&ld)
	return
}

decode_record :: proc(body: []u8, off: i64, allocator := context.temp_allocator) -> (rec: Record, err: Error) {
	rec.env = obj.decode_envelope(body, off) or_return
	return decode_env(&rec.env, allocator)
}

decode_env :: proc(env: ^obj.Envelope, allocator := context.temp_allocator) -> (rec: Record, err: Error) {
	rec.env = env^
	rec.stamp = env.links.stamp
	off := env.off
	if !decode_summary(env.links.extra, off, &rec.summary) {
		return rec, .Corrupt
	}
	d := obj.dec_init(env.fields, off)
	if env.kind < obj.RECORD_KIND_FIRST || env.kind > u8(max(Kind)) {
		return rec, .None
	}
	switch Kind(env.kind) {
	case .Msg:
		v: Msg
		files := make([dynamic]File_Delta, allocator)
		base := make([dynamic]File_Delta, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.role = Role(obj.dec_enum(&d, 1, u8(max(Role))))
			case 2:
				v.author = obj.dec_id(&d)
			case 3:
				v.parent = obj.dec_ref(&d)
			case 4:
				v.depth = obj.dec_int(&d)
			case 5:
				v.jump = obj.dec_ref(&d)
			case 6:
				v.jump_depth = obj.dec_int(&d)
			case 7:
				v.hlc = obj.dec_hlc(&d)
			case 8:
				if len(files) >= MAX_FILES {
					d.bad = true
				} else {
					append(&files, _get_file(&d, off))
				}
			case 9:
				v.provider = obj.dec_str(&d)
			case 10:
				v.model = obj.dec_str(&d)
			case 11:
				v.native = obj.dec_str(&d)
			case 12:
				v.native_msg = obj.dec_str(&d)
			case 13:
				v.runner = obj.dec_id(&d)
			case 14:
				v.intent = obj.dec_ref(&d)
			case 15:
				v.parent_seal = obj.dec_ref(&d)
			case 16:
				v.claim = obj.dec_own(&d)
			case 17:
				v.files_prev = obj.dec_ref(&d)
			case 18:
				v.files_run = u32(min(obj.dec_uv(&d), u64(max(u32))))
			case 19:
				if len(base) >= MAX_FILES {
					d.bad = true
				} else {
					append(&base, _get_file(&d, off))
				}
			}
		}
		v.files = files[:]
		v.files_base = base[:]
		bad := u8(v.role) == 0 || v.depth < 1 || v.jump_depth >= v.depth || obj.ref_none(v.jump) != (v.jump_depth == 0)
		bad ||= obj.ref_none(v.parent) != (v.depth == 1)
		bad ||= (v.parent.seg == 0 && !obj.ref_none(v.parent) && v.parent.off >= off) || (v.jump.seg == 0 && !obj.ref_none(v.jump) && v.jump.off >= off)
		d.bad ||= bad
		rec.body = v
	case .Block:
		v: Block
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_own(&d)
			case 2:
				v.prev = obj.dec_own(&d)
			case 3:
				x := obj.dec_uv(&d)
				if x == 0 || x - 1 > u64(max(u32)) {
					d.bad = true
				}
				v.index = u32(x - 1)
			case 4:
				x := obj.dec_uv(&d)
				if x & ~u64(7) != 0 {
					d.bad = true
				}
				v.flags = transmute(Block_Flags)u8(x)
			case 5:
				v.kind = Block_Kind(obj.dec_enum(&d, 1, u8(max(Block_Kind))))
			case 6:
				v.id = obj.dec_str(&d)
			case 7:
				v.name = obj.dec_str(&d)
			case 8:
				v.data = obj.dec_bytes(&d)
			case 9:
				v.blob.oid = obj.dec_oid(&d)
			case 10:
				v.blob.size = obj.dec_uv(&d)
			case 11:
				v.blob.preview = obj.dec_bytes(&d)
			}
		}
		d.bad ||= v.msg == 0 || (v.prev != 0 && v.prev <= v.msg) || (.Start in v.flags && u8(v.kind) == 0) || (.Ref in v.flags && len(v.blob.oid) == 0)
		rec.body = v
	case .Seal:
		v: Seal
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_own(&d)
			case 2:
				v.last_block = obj.dec_own(&d)
			case 3:
				v.status = Seal_Status(obj.dec_enum(&d, 1, u8(max(Seal_Status))))
			case 4:
				ur := prim.reader(obj.dec_bytes(&d))
				v.usage = decode_usage(&ur)
				d.bad ||= ur.err != .None
			case 5:
				v.native_msg = obj.dec_str(&d)
			case 6:
				v.hlc = obj.dec_hlc(&d)
			case 7:
				v.claim = obj.dec_own(&d)
			}
		}
		d.bad ||= v.msg == 0 || v.status == .Open || (v.last_block != 0 && v.last_block <= v.msg)
		rec.body = v
	case .Leaf:
		v: Leaf
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_ref(&d)
			case 2:
				v.hlc = obj.dec_hlc(&d)
			}
		}
		rec.body = v
	case .Fork:
		v: Fork
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.parent = obj.dec_ref(&d)
			case 2:
				v.child = obj.dec_ref(&d)
			case 3:
				v.child_hlc = obj.dec_hlc(&d)
			}
		}
		d.bad ||= obj.ref_none(v.child)
		rec.body = v
	case .Remember:
		v := _get_remember(&d)
		d.bad ||= obj.ref_none(v.leaf) || v.child_depth < 1 || v.leaf_depth < v.child_depth
		rec.body = v
	case .Forks:
		spine: Spine_Index
		forks := make([dynamic]Remember, allocator)
		assigns := make([dynamic]Digest_Assign, allocator)
		claims := make([dynamic]Digest_Claim, allocator)
		mounts := make([dynamic]Digest_Mount, allocator)
		sups := make([dynamic]Superseded, allocator)
		landed := make([dynamic]Ref, allocator)
		for obj.dec_next(&d) {
			if d.f.tag == 6 {
				append(&landed, obj.dec_ref(&d))
				continue
			}
			if d.f.tag == 7 {
				sub := obj.dec_init(obj.dec_bytes(&d), off)
				packed: []u8
				for obj.dec_next(&sub) {
					switch sub.f.tag {
					case 1:
						spine.at = obj.dec_own(&sub)
					case 2:
						spine.c = obj.dec_int(&sub)
					case 3:
						packed = obj.dec_bytes(&sub)
					}
				}
				d.bad ||= !obj.dec_ok(&sub) || spine.c % SPINE_SPAN != 0
				n := spine.c / SPINE_SPAN
				if !d.bad {
					blocks := make([]i64, n, allocator)
					pr := prim.reader(packed)
					last: i64
					for &x in blocks {
						last += _unzigzag(prim.read_uvarint(&pr))
						x = last
						d.bad ||= x <= 0 || x >= off
					}
					d.bad ||= pr.err != .None || !prim.reader_done(&pr)
					spine.blocks = blocks
				}
				continue
			}
			sub := obj.dec_init(obj.dec_bytes(&d), off)
			switch d.f.tag {
			case 1:
				e := _get_remember(&sub)
				d.bad ||= obj.ref_none(e.child)
				append(&forks, e)
			case 2:
				e: Digest_Assign
				for obj.dec_next(&sub) {
					switch sub.f.tag {
					case 1:
						e.msg = obj.dec_ref(&sub)
					case 2:
						e.runner = obj.dec_id(&sub)
					case 3:
						e.hlc = obj.dec_hlc(&sub)
					}
				}
				d.bad ||= obj.ref_none(e.msg)
				append(&assigns, e)
			case 3:
				e: Digest_Claim
				for obj.dec_next(&sub) {
					switch sub.f.tag {
					case 1:
						e.msg = obj.dec_ref(&sub)
					case 2:
						e.claim = obj.dec_own(&sub)
					case 3:
						e.lease = obj.dec_uv(&sub)
					case 4:
						e.stamp = obj.dec_hlc(&sub)
					case 5:
						e.assign_hlc = obj.dec_hlc(&sub)
					}
				}
				d.bad ||= obj.ref_none(e.msg)
				append(&claims, e)
			case 4:
				e: Digest_Mount
				for obj.dec_next(&sub) {
					switch sub.f.tag {
					case 1:
						e.name = obj.dec_str(&sub)
					case 2:
						e.tree = obj.dec_id(&sub)
					case 3:
						e.line = obj.dec_id(&sub)
					case 4:
						e.path = obj.dec_str(&sub)
					case 5:
						e.stamp = obj.dec_hlc(&sub)
					case 6:
						e.removed = obj.dec_uv(&sub) != 0
					}
				}
				append(&mounts, e)
			case 5:
				e: Superseded
				for obj.dec_next(&sub) {
					switch sub.f.tag {
					case 1:
						e.run = obj.dec_ref(&sub)
					case 2:
						e.by = obj.dec_ref(&sub)
					}
				}
				append(&sups, e)
			}
			d.bad ||= !obj.dec_ok(&sub)
		}
		rec.body = Forks{forks[:], assigns[:], claims[:], mounts[:], sups[:], landed[:], spine}
	case .Assign:
		v: Assign
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_ref(&d)
			case 2:
				v.runner = obj.dec_id(&d)
			case 3:
				v.hlc = obj.dec_hlc(&d)
			}
		}
		d.bad ||= obj.ref_none(v.msg)
		rec.body = v
	case .Claim:
		v: Claim
		lines := make([dynamic]Line, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_ref(&d)
			case 2:
				v.runner = obj.dec_id(&d)
			case 3:
				v.lease = obj.dec_uv(&d)
			case 4:
				v.assign_hlc = obj.dec_hlc(&d)
			case 5:
				append(&lines, _get_line(&d, off))
			}
		}
		v.lines = lines[:]
		d.bad ||= obj.ref_none(v.msg)
		rec.body = v
	case .Queue:
		v: Queue
		atts := make([dynamic]Attachment, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.text = obj.dec_str(&d)
			case 2:
				append(&atts, _get_att(&d, off))
			}
		}
		v.attachments = atts[:]
		rec.body = v
	case .Steer:
		v: Steer
		atts := make([dynamic]Attachment, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_ref(&d)
			case 2:
				v.text = obj.dec_str(&d)
			case 3:
				append(&atts, _get_att(&d, off))
			}
		}
		v.attachments = atts[:]
		rec.body = v
	case .Edit_Queued:
		v: Edit_Queued
		atts := make([dynamic]Attachment, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.item = obj.dec_ref(&d)
			case 2:
				v.text = obj.dec_str(&d)
			case 3:
				append(&atts, _get_att(&d, off))
			}
		}
		v.attachments = atts[:]
		d.bad ||= obj.ref_none(v.item)
		rec.body = v
	case .Cancel:
		v: Cancel
		for obj.dec_next(&d) {
			if d.f.tag == 1 {
				v.item = obj.dec_ref(&d)
			}
		}
		d.bad ||= obj.ref_none(v.item)
		rec.body = v
	case .Interrupt:
		v: Interrupt
		for obj.dec_next(&d) {
			if d.f.tag == 1 {
				v.msg = obj.dec_ref(&d)
			}
		}
		rec.body = v
	case .Answer:
		v: Answer
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.request = obj.dec_ref(&d)
			case 2:
				v.allow = obj.dec_uv(&d) != 0
			case 3:
				v.text = obj.dec_str(&d)
			}
		}
		rec.body = v
	case .Unqueue:
		v: Unqueue
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.item = obj.dec_ref(&d)
			case 2:
				v.outcome = Outcome(obj.dec_enum(&d, 1, u8(max(Outcome))))
			case 3:
				v.msg = obj.dec_ref(&d)
			case 4:
				v.cause = obj.dec_ref(&d)
			}
		}
		d.bad ||= obj.ref_none(v.item) || u8(v.outcome) == 0
		rec.body = v
	case .Superseded:
		v: Superseded
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.run = obj.dec_ref(&d)
			case 2:
				v.by = obj.dec_ref(&d)
			}
		}
		d.bad ||= obj.ref_none(v.run)
		rec.body = v
	case .Landed:
		v: Landed
		files := make([dynamic]File_Delta, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.run = obj.dec_ref(&d)
			case 2:
				append(&files, _get_file(&d, off))
			}
		}
		v.files = files[:]
		d.bad ||= obj.ref_none(v.run)
		rec.body = v
	case .Mount:
		v: Mount
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.name = obj.dec_str(&d)
			case 2:
				v.tree = obj.dec_id(&d)
			case 3:
				v.line = obj.dec_id(&d)
			case 4:
				v.path = obj.dec_str(&d)
			}
		}
		d.bad ||= len(v.name) == 0
		rec.body = v
	case .Unmount:
		v: Unmount
		for obj.dec_next(&d) {
			if d.f.tag == 1 {
				v.name = obj.dec_str(&d)
			}
		}
		d.bad ||= len(v.name) == 0
		rec.body = v
	case .Compact:
		v: Compact
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.from = obj.dec_ref(&d)
			case 2:
				v.to = obj.dec_ref(&d)
			case 3:
				v.summary = obj.dec_str(&d)
			case 4:
				v.blob.oid = obj.dec_oid(&d)
			case 5:
				v.blob.size = obj.dec_uv(&d)
			case 6:
				v.blob.preview = obj.dec_bytes(&d)
			}
		}
		d.bad ||= obj.ref_none(v.to)
		rec.body = v
	case .Await:
		v: Await
		tasks := make([dynamic]prim.Id, allocator)
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				append(&tasks, obj.dec_id(&d))
			case 2:
				v.condition = Condition(obj.dec_enum(&d, 1, u8(max(Condition))))
			case 3:
				v.deadline = obj.dec_hlc(&d)
			case 4:
				v.expr = obj.dec_str(&d)
			}
		}
		v.tasks = tasks[:]
		rec.body = v
	case .Scope:
		v: Scope
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_ref(&d)
			case 2:
				v.kind = Scope_Kind(obj.dec_enum(&d, 1, u8(max(Scope_Kind))))
			case 3:
				v.id = obj.dec_id(&d)
			case 4:
				v.actor = obj.dec_id(&d)
			case 5:
				v.before = obj.dec_bytes(&d)
			case 6:
				v.after = obj.dec_bytes(&d)
			}
		}
		rec.body = v
	case .Interrupted:
		v: Interrupted
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_own(&d)
			case 2:
				v.last_block = obj.dec_own(&d)
			case 3:
				v.attempt = u8(min(obj.dec_uv(&d), 63))
			case 4:
				v.revive = obj.dec_uv(&d) != 0
			}
		}
		d.bad ||= v.msg == 0 || (v.last_block != 0 && v.last_block <= v.msg)
		rec.body = v
	case .Revived:
		v: Revived
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.msg = obj.dec_own(&d)
			case 2:
				v.attempt = u8(min(obj.dec_uv(&d), 63))
			}
		}
		d.bad ||= v.msg == 0
		rec.body = v
	case .Spine:
		v: Spine
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.target = obj.dec_ref(&d)
			case 2:
				v.prev = obj.dec_own(&d)
			case 3:
				v.c = obj.dec_int(&d)
			case 4:
				v.first = obj.dec_int(&d)
			case 5:
				v.nodes = obj.dec_bytes(&d)
			}
		}
		d.bad ||= v.c < 0 || v.c % SPINE_SPAN != 0 || v.first < 0 || v.first * SPINE_SPAN > v.c || obj.ref_none(v.target)
		rec.body = v
	case .Recorded:
		v: Recorded
		for obj.dec_next(&d) {
			switch d.f.tag {
			case 1:
				v.source = obj.dec_str(&d)
			case 2:
				v.external_id = obj.dec_str(&d)
			case 3:
				v.sequence = obj.dec_uv(&d)
			case 4:
				v.msg = obj.dec_ref(&d)
			}
		}
		rec.body = v
	}
	if !obj.dec_ok(&d) {
		return rec, .Corrupt
	}
	if is_event_kind(Kind(env.kind)) != obj.links_is_event(&rec.env.links) {
		return rec, .Corrupt
	}
	return rec, .None
}

@(private)
_zigzag :: proc "contextless" (x: i64) -> u64 {
	return u64(x << 1) ~ u64(x >> 63)
}

@(private)
_unzigzag :: proc "contextless" (x: u64) -> i64 {
	return i64(x >> 1) ~ -i64(x & 1)
}

spine_encode :: proc(nodes: []Ref, allocator := context.temp_allocator) -> []u8 {
	b := make([dynamic]u8, allocator)
	w := prim.writer(&b)
	last := make(map[u32]i64, allocator)
	for n in nodes {
		prim.write_uvarint(&w, u64(n.seg))
		prev := last[n.seg]
		prim.write_uvarint(&w, u64(n.off - prev))
		last[n.seg] = n.off
	}
	return b[:]
}

spine_decode :: proc(b: []u8, count: int, allocator := context.temp_allocator) -> (nodes: []Ref, ok: bool) {
	out := make([]Ref, count, allocator)
	last := make(map[u32]i64, allocator)
	r := prim.reader(b)
	for &n in out {
		seg := prim.read_uvarint(&r)
		d := prim.read_uvarint(&r)
		if r.err != .None || seg > u64(obj.MAX_SEGS) || d == 0 || d > u64(max(i64)) {
			return nil, false
		}
		n.seg = u32(seg)
		prev := last[n.seg]
		if i64(d) > max(i64) - prev {
			return nil, false
		}
		n.off = prev + i64(d)
		last[n.seg] = n.off
	}
	return out, prim.reader_done(&r)
}

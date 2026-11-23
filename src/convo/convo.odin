package convo

import "../obj"
import "core:strings"
import "../prim"

MAX_OPEN :: 8
MAX_PENDING :: 64
MAX_REVIVALS :: 3
REVIVE_WINDOW_MS :: 12 * 60 * 60 * 1000
INLINE_MAX :: 4096
CHUNK_MAX :: 16 * 1024
MAX_UPDATES :: 256
DIGEST_EVERY :: 64
DIGEST_RATIO :: 16
MAX_FILES :: 1024
FILES_SNAPSHOT :: 8
SPINE_SPAN :: 64
DIGEST_BYTES :: 256 * 1024
BRANCH_INLINE :: 64
BRANCH_MAX :: 65536
NODE_CACHE :: 16384

Error :: obj.Error
Ref :: obj.Ref
Rid :: obj.Rid
Xref :: obj.Xref
Vref :: obj.Vref
Want :: obj.Want

Kind :: enum u8 {
	Msg         = 16,
	Block       = 17,
	Seal        = 18,
	Leaf        = 19,
	Fork        = 20,
	Remember    = 21,
	Forks       = 22,
	Assign      = 23,
	Claim       = 24,
	Queue       = 25,
	Steer       = 26,
	Edit_Queued = 27,
	Cancel      = 28,
	Interrupt   = 29,
	Answer      = 30,
	Unqueue     = 31,
	Superseded  = 32,
	Landed      = 33,
	Mount       = 34,
	Unmount     = 35,
	Compact     = 36,
	Await       = 37,
	Scope       = 38,
	Interrupted = 39,
	Revived     = 40,
	Recorded    = 41,
	Spine       = 42,
	Files       = 43,
	Redact_Msg  = 44,
	Hold        = 45,
	Undo        = 46,
	Undone      = 47,
	Notice      = 48,
}

Undo_Phase :: enum u8 {
	Staged   = 1,
	Held     = 2,
	Fenced   = 3,
	Reverted = 4,
	Moved    = 5,
	Leaves   = 6,
	Rewound  = 7,
	Released = 8,
}

Move_Cause :: enum u8 {
	Undo       = 0,
	Redo       = 1,
	Switch     = 2,
	Edit       = 3,
	Regenerate = 4,
	Rebase     = 5,
}

Notice_Kind :: enum u8 {
	Rewrote  = 1,
	Removed  = 2,
	Checkout = 3,
	Read     = 4,
}

Role :: enum u8 {
	User      = 1,
	Assistant = 2,
	System    = 3,
	Tool      = 4,
}

Block_Kind :: enum u8 {
	Text              = 1,
	Reasoning         = 2,
	Tool_Call         = 3,
	Tool_Result       = 4,
	Image             = 5,
	Error             = 6,
	Notice            = 7,
	Permission        = 8,
	Permission_Answer = 9,
	Question          = 10,
	File              = 11,
}

Block_Flag :: enum u8 {
	Start,
	Ref,
	Failed,
}

Block_Flags :: bit_set[Block_Flag;u8]

Seal_Status :: enum u8 {
	Open        = 0,
	Done        = 1,
	Interrupted = 2,
	Failed      = 3,
	Cancelled   = 4,
}

Open_State :: enum u8 {
	Running = 0,
	Revive  = 1,
	Held    = 2,
}

Hold_Reason :: enum u8 {
	None           = 0,
	Branch_Changed = 1,
	Branch_Deleted = 2,
	Undo           = 3,
}

Line_Bind :: struct {
	mount: string,
	tree:  prim.Id,
	line:  string,
}

Outcome :: enum u8 {
	Started   = 1,
	Steered   = 2,
	Cancelled = 3,
	Failed    = 4,
	Edited    = 5,
	Applied   = 6,
	Rejected  = 7,
	Released  = 8,
}

Scope_Kind :: enum u8 {
	Turn = 1,
	Tool = 2,
}

Condition :: enum u8 {
	Any = 1,
	All = 2,
}

Status :: enum u8 {
	Idle                = 0,
	Running             = 1,
	Queued              = 2,
	Awaiting_Permission = 3,
	Failed              = 4,
	Interrupted         = 5,
	Waiting             = 6,
	Reviving            = 7,
	Held                = 8,
}

Receipt :: enum u8 {
	Recorded   = 1,
	Duplicate  = 2,
	Superseded = 3,
}

Usage :: struct {
	input:       u64,
	output:      u64,
	cache_read:  u64,
	cache_write: u64,
}

Blob :: struct {
	oid:     []u8,
	size:    u64,
	preview: []u8,
}

Attachment :: struct {
	name: string,
	mime: string,
	oid:  []u8,
	size: u64,
}

File_Delta :: struct {
	mount:   string,
	tree:    prim.Id,
	line:    prim.Id,
	version: []u8,
}

Line :: struct {
	mount: string,
	line:  prim.Id,
}

Open :: struct {
	msg:     i64,
	last:    i64,
	blocks:  u32,
	state:   Open_State,
	attempt: u8,
}

Pending_Entry :: struct {
	item:   Ref,
	latest: Ref,
}

Summary :: struct {
	tip:         i64,
	tip_hlc:     prim.Hlc,
	leaf:        Ref,
	leaf_hlc:    prim.Hlc,
	last_seal:   i64,
	digest:      i64,
	digest_hlc:  prim.Hlc,
	spine:       i64,
	base:        i64,
	base_len:    i64,
	digest_len:  i64,
	since:       u32,
	digest_size: u32,
	pending:     [MAX_PENDING]Pending_Entry,
	pending_len: int,
	open:        [MAX_OPEN]Open,
	open_len:    int,
}

summary_open :: proc "contextless" (s: ^Summary) -> []Open {
	return s.open[:s.open_len]
}

summary_pending :: proc "contextless" (s: ^Summary) -> []Pending_Entry {
	return s.pending[:s.pending_len]
}

summary_find :: proc "contextless" (s: ^Summary, msg: i64) -> int {
	for i in 0 ..< s.open_len {
		if s.open[i].msg == msg {
			return i
		}
	}
	return -1
}

@(private)
_open_remove :: proc "contextless" (s: ^Summary, i: int) {
	for k in i ..< s.open_len - 1 {
		s.open[k] = s.open[k + 1]
	}
	s.open_len -= 1
	s.open[s.open_len] = {}
}

@(private)
_pending_remove :: proc "contextless" (s: ^Summary, i: int) {
	for k in i ..< s.pending_len - 1 {
		s.pending[k] = s.pending[k + 1]
	}
	s.pending_len -= 1
	s.pending[s.pending_len] = {}
}

encode_summary :: proc(off: i64, s: ^Summary, allocator := context.temp_allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	w := prim.writer(&buf)
	if s.tip != 0 {
		f: obj.Fixed
		obj.fx_ref(&f, off, Ref{0, s.tip})
		obj.fx_u64(&f, u64(s.tip_hlc))
		obj.tw_fixed(&w, 16, &f)
	}
	if !obj.ref_none(s.leaf) || s.leaf_hlc != 0 {
		f: obj.Fixed
		obj.fx_ref(&f, off, s.leaf)
		obj.fx_u64(&f, u64(s.leaf_hlc))
		obj.tw_fixed(&w, 17, &f)
	}
	obj.tw_ref(&w, 18, off, Ref{0, s.last_seal})
	obj.tw_ref(&w, 19, off, Ref{0, s.digest})
	obj.tw_uv(&w, 22, u64(s.since))
	obj.tw_uv(&w, 23, u64(s.digest_size))
	if s.digest_hlc != 0 {
		obj.tw_uv(&w, 24, u64(s.digest_hlc))
	}
	if s.spine != 0 {
		obj.tw_ref(&w, 25, off, Ref{0, s.spine})
	}
	if s.base != 0 && s.base != s.digest {
		obj.tw_ref(&w, 26, off, Ref{0, s.base})
	}
	if s.base_len != 0 {
		obj.tw_uv(&w, 27, u64(s.base_len))
	}
	if s.digest_len != 0 && s.digest_len != s.base_len {
		obj.tw_uv(&w, 28, u64(s.digest_len))
	}
	for p in summary_pending(s) {
		f: obj.Fixed
		obj.fx_ref(&f, off, p.item)
		obj.fx_ref(&f, off, p.latest)
		obj.tw_fixed(&w, 20, &f)
	}
	for o in summary_open(s) {
		f: obj.Fixed
		obj.fx_ref(&f, off, Ref{0, o.msg})
		obj.fx_ref(&f, off, Ref{0, o.last})
		obj.fx_uv(&f, u64(o.blocks))
		obj.fx_uv(&f, u64(o.state) | u64(o.attempt) << 2)
		obj.tw_fixed(&w, 21, &f)
	}
	return buf[:]
}

decode_summary :: proc "contextless" (extra: []u8, off: i64, s: ^Summary) -> bool {
	s^ = {}
	r := prim.reader(extra)
	for {
		f, ok := obj.next_field(&r)
		if !ok {
			break
		}
		switch f.tag {
		case 16:
			if f.ty != obj.F_BYTES {
				return false
			}
			fr := prim.reader(f.b)
			t := obj.read_ref(&fr, off) or_return
			s.tip_hlc = prim.Hlc(prim.read_u64le(&fr))
			if fr.err != .None || t.seg != 0 || obj.ref_none(t) {
				return false
			}
			s.tip = t.off
		case 17:
			if f.ty != obj.F_BYTES {
				return false
			}
			fr := prim.reader(f.b)
			s.leaf = obj.read_ref(&fr, off) or_return
			s.leaf_hlc = prim.Hlc(prim.read_u64le(&fr))
			if fr.err != .None {
				return false
			}
		case 18, 19, 25, 26:
			v := obj.field_own(f, off, false) or_return
			switch f.tag {
			case 18:
				s.last_seal = v
			case 19:
				s.digest = v
			case 25:
				s.spine = v
			case:
				s.base = v
			}
		case 27, 28:
			if f.ty != obj.F_UV || f.uv > u64(max(i64)) {
				return false
			}
			if f.tag == 27 {
				s.base_len = i64(f.uv)
			} else {
				s.digest_len = i64(f.uv)
			}
		case 22, 23:
			if f.ty != obj.F_UV || f.uv > u64(max(u32)) {
				return false
			}
			if f.tag == 22 {
				s.since = u32(f.uv)
			} else {
				s.digest_size = u32(f.uv)
			}
		case 24:
			if f.ty != obj.F_UV {
				return false
			}
			s.digest_hlc = prim.Hlc(f.uv)
		case 20:
			if f.ty != obj.F_BYTES || s.pending_len == MAX_PENDING {
				return false
			}
			fr := prim.reader(f.b)
			e: Pending_Entry
			e.item = obj.read_ref(&fr, off) or_return
			e.latest = obj.read_ref(&fr, off) or_return
			if obj.ref_none(e.item) {
				return false
			}
			s.pending[s.pending_len] = e
			s.pending_len += 1
		case 21:
			if f.ty != obj.F_BYTES || s.open_len == MAX_OPEN {
				return false
			}
			fr := prim.reader(f.b)
			m := obj.read_ref(&fr, off) or_return
			last := obj.read_ref(&fr, off) or_return
			blocks := prim.read_uvarint(&fr)
			st := prim.read_uvarint(&fr)
			if fr.err != .None || m.seg != 0 || last.seg != 0 || obj.ref_none(m) || (last.off != 0 && last.off <= m.off) || blocks > u64(max(u32)) || st & 3 > 2 || st >> 2 > 63 {
				return false
			}
			s.open[s.open_len] = Open{m.off, last.off, u32(blocks), Open_State(st & 3), u8(st >> 2)}
			s.open_len += 1
		}
	}
	if s.base == 0 {
		s.base = s.digest
	}
	if s.digest_len == 0 && s.base == s.digest {
		s.digest_len = s.base_len
	}
	return r.err == .None
}

binds_encode :: proc(binds: []Line_Bind) -> []u8 {
	if len(binds) == 0 {
		return nil
	}
	b := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&b)
	prim.write_uvarint(&w, u64(len(binds)))
	for x in binds {
		prim.write_str(&w, x.mount)
		prim.write_id(&w, x.tree)
		prim.write_str(&w, x.line)
	}
	return b[:]
}

binds_decode :: proc(b: []u8, allocator := context.temp_allocator) -> []Line_Bind {
	if len(b) == 0 {
		return nil
	}
	rd := prim.reader(b)
	n := prim.read_uvarint(&rd)
	if n > 4096 {
		return nil
	}
	out := make([dynamic]Line_Bind, 0, int(n), allocator)
	for _ in 0 ..< n {
		m := prim.read_str(&rd)
		t := prim.read_id(&rd)
		l := prim.read_str(&rd)
		if !prim.reader_ok(&rd) {
			return nil
		}
		append(&out, Line_Bind{mount = strings.clone(m, allocator), tree = t, line = strings.clone(l, allocator)})
	}
	return out[:]
}

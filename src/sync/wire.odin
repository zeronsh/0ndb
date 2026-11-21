package osync

import "../journal"
import "../prim"

PROTOCOL_VERSION :: 1

FRAME_HEADER :: 5
CONTROL_MAX :: 64 * 1024
APPEND_MAX :: journal.MAX_BODY + journal.OVERHEAD
DATA_MAX :: 4 * 1024 * 1024
OBJECT_MAX :: int(max(u32)) - 64
FOLLOW_BATCH :: 1024
GET_BATCH :: 1024
LIST_BATCH :: 1500
FOLLOW_END :: max(u64)

Kind :: enum u8 {
	None      = 0,
	Hello     = 0x01,
	List      = 0x02,
	Append    = 0x03,
	Read      = 0x04,
	Tail      = 0x05,
	Follow    = 0x06,
	Unfollow  = 0x07,
	Put       = 0x08,
	Get       = 0x09,
	Drop      = 0x0a,
	Redact    = 0x0b,
	Feed      = 0x0c,
	Forget    = 0x0d,
	Welcome   = 0x81,
	Listing   = 0x82,
	Appended  = 0x83,
	Conflict  = 0x84,
	Data      = 0x85,
	Stored    = 0x86,
	Object    = 0x87,
	Missing   = 0x88,
	Length    = 0x89,
	Created   = 0x8a,
	Dropped   = 0x8b,
	Refused   = 0x8c,
	Error     = 0x8d,
	Redacted  = 0x8e,
	Announce  = 0x8f,
	Forgotten = 0x90,
}

Code :: enum u8 {
	None      = 0,
	Protocol  = 1,
	Auth      = 2,
	Version   = 3,
	Quota     = 4,
	Not_Owner = 5,
	Too_Large = 6,
	Io        = 7,
	Busy      = 8,
	Limit     = 9,
	Not_Found = 10,
}

FOLLOW_WATCH :: 1
FEED_TAG :: 1
FEED_META_TAG :: 2
LIST_TAG :: 3
FEED_ENTRY :: 40
FEED_BATCH :: 1500
FEED_DROPPED :: max(u64)
FEED_PATTERNS_MAX :: 16384
FEED_PATTERNS_FRAME :: 1900
FEED_SKIP_REPORT :: 16 * FEED_BATCH * FEED_ENTRY
FEED_FILTERED :: 1
FEED_ADD :: 2

Feed_Pattern_Kind :: enum u8 {
	Prefix = 1,
	Suffix = 2,
	Exact  = 3,
}

Feed_Pattern :: struct {
	kind:  Feed_Pattern_Kind,
	bytes: [32]u8,
}

HELLO_LEN :: 1 + 32 + 32 + 64 + 64
APPEND_FIXED :: 32 + 8
PUT_FIXED :: 32
DATA_FIXED :: 32 + 8 + 8
OBJECT_FIXED :: 32

Listed :: struct {
	stream: Stream_Id,
	length: i64,
}

Item_Kind :: enum u8 {
	None,
	Control,
	Bulk_Begin,
	Bulk_Data,
	Bulk_End,
}

Item :: struct {
	kind:  Item_Kind,
	frame: Kind,
	data:  []u8,
	total: int,
}

Parser :: struct {
	head:      [FRAME_HEADER + DATA_FIXED]u8,
	have:      int,
	need:      int,
	frame:     Kind,
	len:       int,
	left:      int,
	bulk:      bool,
	ctl:       [dynamic]u8,
	relay:     bool,
}

parser_init :: proc(p: ^Parser, for_relay: bool, allocator := context.allocator) {
	p^ = {}
	p.relay = for_relay
	p.need = FRAME_HEADER
	p.ctl = make([dynamic]u8, allocator)
}

parser_destroy :: proc(p: ^Parser) {
	delete(p.ctl)
	p.ctl = nil
}

parser_reset :: proc(p: ^Parser) {
	clear(&p.ctl)
	p.have = 0
	p.need = FRAME_HEADER
	p.frame = .None
	p.len = 0
	p.left = 0
	p.bulk = false
}

parser_idle :: proc "contextless" (p: ^Parser) -> bool {
	return p.have == 0 && p.frame == .None
}

parser_next :: proc(p: ^Parser, data: []u8) -> (it: Item, used: int, err: Error) {
	if p.frame != .None && p.bulk && p.have == p.need {
		if p.left == 0 {
			it = {kind = .Bulk_End, frame = p.frame}
			_parser_done(p)
			return it, 0, .None
		}
		if len(data) == 0 {
			return {}, 0, .None
		}
		n := min(p.left, len(data))
		p.left -= n
		return Item{kind = .Bulk_Data, frame = p.frame, data = data[:n], total = p.len}, n, .None
	}
	for p.have < p.need {
		if used == len(data) {
			return {}, used, .None
		}
		n := min(p.need - p.have, len(data) - used)
		copy(p.head[p.have:], data[used:][:n])
		p.have += n
		used += n
		if p.have == FRAME_HEADER && p.need == FRAME_HEADER {
			if e := _parser_header(p); e != .None {
				return {}, used, e
			}
		}
	}
	if p.bulk {
		fixed := p.need - FRAME_HEADER
		return Item{kind = .Bulk_Begin, frame = p.frame, data = p.head[FRAME_HEADER:][:fixed], total = p.left}, used, .None
	}
	rest := data[used:]
	if len(p.ctl) == 0 && len(rest) >= p.left {
		it = Item{kind = .Control, frame = p.frame, data = rest[:p.left]}
		used += p.left
		_parser_done(p)
		return it, used, .None
	}
	n := min(p.left, len(rest))
	if n > 0 {
		if _, aerr := append(&p.ctl, ..rest[:n]); aerr != nil {
			return {}, used, .No_Memory
		}
		p.left -= n
		used += n
	}
	if p.left > 0 {
		return {}, used, .None
	}
	it = Item{kind = .Control, frame = p.frame, data = p.ctl[:]}
	_parser_done(p)
	return it, used, .None
}

parser_release :: proc(p: ^Parser) {
	if p.frame == .None && cap(p.ctl) > 4096 {
		delete(p.ctl)
		p.ctl = make([dynamic]u8, p.ctl.allocator)
	} else if p.frame == .None {
		clear(&p.ctl)
	}
}

@(private)
_parser_done :: proc(p: ^Parser) {
	p.have = 0
	p.need = FRAME_HEADER
	p.frame = .None
	p.len = 0
	p.left = 0
	p.bulk = false
}

@(private)
_parser_header :: proc(p: ^Parser) -> Error {
	n := int(prim.get_u32le(p.head[0:4]))
	k := Kind(p.head[4])
	fixed := 0
	limit := CONTROL_MAX
	bulk := false
	if p.relay {
		#partial switch k {
		case .Hello, .List, .Read, .Tail, .Follow, .Unfollow, .Get, .Drop, .Redact, .Feed, .Forget:
		case .Append:
			bulk, fixed, limit = true, APPEND_FIXED, APPEND_MAX
		case .Put:
			bulk, fixed, limit = true, PUT_FIXED, OBJECT_MAX
		case:
			return .Protocol
		}
	} else {
		#partial switch k {
		case .Welcome, .Listing, .Appended, .Conflict, .Stored, .Missing, .Length, .Created, .Dropped, .Refused, .Error, .Redacted, .Announce, .Forgotten:
		case .Data:
			bulk, fixed, limit = true, DATA_FIXED, OBJECT_MAX
		case .Object:
			bulk, fixed, limit = true, OBJECT_FIXED, OBJECT_MAX
		case:
			return .Protocol
		}
	}
	if n < fixed || n - fixed > limit {
		return .Too_Large if n >= fixed else .Protocol
	}
	clear(&p.ctl)
	p.frame = k
	p.len = n - fixed
	p.bulk = bulk
	p.need = FRAME_HEADER + fixed
	p.left = n - fixed
	return .None
}

frame_begin :: proc(out: ^[dynamic]u8, k: Kind) -> (start: int, err: Error) {
	start = len(out)
	if aerr := resize(out, start + FRAME_HEADER); aerr != nil {
		return start, .No_Memory
	}
	out[start + 4] = u8(k)
	return start, .None
}

frame_end :: proc(out: ^[dynamic]u8, start: int, w: ^prim.Writer) -> Error {
	if w.err != .None {
		resize(out, start)
		return .No_Memory
	}
	n := len(out) - start - FRAME_HEADER
	prim.put_u32le(out[start:start + 4], u32(n))
	return .None
}

frame_header :: proc "contextless" (dst: []u8, k: Kind, payload: int) {
	prim.put_u32le(dst[0:4], u32(payload))
	dst[4] = u8(k)
}

put_id :: proc(w: ^prim.Writer, id: [32]u8) {
	v := id
	prim.write_raw(w, v[:])
}

get_id32 :: proc "contextless" (r: ^prim.Reader) -> (id: [32]u8) {
	prim.read_fixed(r, id[:])
	return
}

get_i64 :: proc "contextless" (r: ^prim.Reader) -> i64 {
	v := prim.read_u64le(r)
	if v > u64(max(i64)) {
		prim.reader_fail(r, .Overflow)
		return 0
	}
	return i64(v)
}

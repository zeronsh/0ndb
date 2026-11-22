package osync

import "../journal"
import "../prim"

PROTOCOL_VERSION :: 3
DATA_FINAL :: u64(1) << 63

FRAME_HEADER :: 5
CONTROL_MAX :: 64 * 1024
APPEND_MAX :: journal.MAX_BODY + journal.OVERHEAD
DATA_MAX :: 4 * 1024 * 1024
FOLLOW_BATCH :: 1024
GET_BATCH :: 1024
LIST_BATCH :: 1500
FOLLOW_END :: max(u64)

when size_of(int) == 8 {
	OBJECT_MAX :: int(max(u32)) - 64
} else {
	OBJECT_MAX :: max(int) - 64
}

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
	Probe     = 0x0e,
	Direct    = 0x10,
	Note      = 0x11,
	Fill      = 0x12,
	Pull      = 0x13,
	Serve     = 0x14,
	Account   = 0x15,
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
	Probed    = 0x91,
	Presence  = 0x92,
	Directed  = 0x93,
	Undelivered = 0x94,
	Noted     = 0x95,
	Hollow    = 0x96,
	Pulled    = 0x97,
	Served    = 0x98,
	Unserved  = 0x99,
	Accounted = 0x9a,
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
REDLOG_TAG :: 4
REDLOG_RECORD :: 48
FEED_REDACT :: u64(1) << 63
FEED_REDACT_END :: u64(1) << 62
REDACT_LIMIT :: i64(1) << 62
FEED_ENTRY :: 40
FEED_BATCH :: 1500
FEED_DROPPED :: max(u64)
FEED_PATTERNS_MAX :: 16384
FEED_PATTERNS_FRAME :: 1900
FEED_SKIP_REPORT :: 16 * FEED_BATCH * FEED_ENTRY
FEED_FILTERED :: 1
FEED_ADD :: 2
FEED_PRESENCE :: 4
PRESENCE_ENTRY :: 16 + 1 + 8
PRESENCE_SNAPSHOT :: 1
DIRECT_FIXED :: 16 + 8
DIRECT_MAX :: CONTROL_MAX - FRAME_HEADER - DIRECT_FIXED
FEED_HOLLOW :: u64(1) << 61
NOTE_LEN :: 32 + 8
FILL_FIXED :: 32 + 8
NOTED_LEN :: 32 + 8 + 8
PULL_LEN :: 16 + 8 + 32 + 8 + 8
SERVE_FIXED :: 16 + 8 + 32 + 8 + 8
UNSERVED_LEN :: 16 + 8 + 32
SERVE_MAX :: 256 * 1024
SERVE_FINAL :: u64(1) << 63
SERVE_NONE :: u64(1) << 62
SERVE_LEN_MASK :: SERVE_NONE - 1
PIPES_MAX :: 64
PIPE_HIGH :: 4 * SERVE_MAX
BULK_FIXED_MAX :: SERVE_FIXED
ACCOUNT_TAG :: 5
ACCOUNTED_LEN :: 14 * 8
FEATURE_ACCOUNT :: u64(1)
RELAY_FEATURES :: FEATURE_ACCOUNT

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
	head:      [FRAME_HEADER + BULK_FIXED_MAX]u8,
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
		case .Hello, .List, .Read, .Tail, .Follow, .Unfollow, .Get, .Drop, .Redact, .Feed, .Forget, .Probe, .Direct, .Note, .Pull, .Account:
		case .Append:
			bulk, fixed, limit = true, APPEND_FIXED, APPEND_MAX
		case .Fill:
			bulk, fixed, limit = true, FILL_FIXED, APPEND_MAX
		case .Serve:
			bulk, fixed, limit = true, SERVE_FIXED, SERVE_MAX
		case .Put:
			bulk, fixed, limit = true, PUT_FIXED, OBJECT_MAX
		case:
			return .Protocol
		}
	} else {
		#partial switch k {
		case .Welcome, .Listing, .Appended, .Conflict, .Stored, .Missing, .Length, .Created, .Dropped, .Refused, .Error, .Redacted, .Announce, .Forgotten, .Probed, .Presence, .Directed, .Undelivered, .Noted, .Hollow, .Pulled, .Unserved, .Accounted:
		case .Data:
			bulk, fixed, limit = true, DATA_FIXED, OBJECT_MAX
		case .Served:
			bulk, fixed, limit = true, SERVE_FIXED, SERVE_MAX
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

reserved_id :: proc "contextless" (tag: u8, epoch: u64) -> (id: Stream_Id) {
	for i in 0 ..< 16 {
		id[i] = 0xff
	}
	id[16] = tag
	prim.put_u64le(id[24:], epoch)
	return
}

accounted_encode :: proc "contextless" (s: Relay_Space_Stats, out: []u8) {
	v := [14]u64{u64(max(s.stored, 0)), u64(max(s.quota, 0)), s.appends, s.bytes_in, s.notes, s.fills, s.pulls, s.piped_bytes, s.store.writes, s.store.write_bytes, u64(max(s.store.pending, 0)), u64(max(s.store.day, 0)), s.store.day_bytes, s.store.total_bytes}
	for x, i in v {
		prim.put_u64le(out[i * 8:], x)
	}
}

accounted_decode :: proc "contextless" (data: []u8) -> (s: Relay_Space_Stats, ok: bool) {
	if len(data) < ACCOUNTED_LEN {
		return
	}
	v: [14]u64
	for i in 0 ..< 14 {
		v[i] = min(prim.get_u64le(data[i * 8:]), u64(max(i64)))
	}
	s.stored, s.quota = i64(v[0]), i64(v[1])
	s.appends, s.bytes_in, s.notes, s.fills, s.pulls, s.piped_bytes = v[2], v[3], v[4], v[5], v[6], v[7]
	s.store = {writes = v[8], write_bytes = v[9], pending = i64(v[10]), day = i64(v[11]), day_bytes = v[12], total_bytes = v[13]}
	return s, true
}

feed_length :: proc "contextless" (word: u64) -> (length: i64, hollow: bool, ok: bool) {
	if word & (FEED_REDACT | FEED_REDACT_END) != 0 {
		return
	}
	return i64(word & (FEED_HOLLOW - 1)), word & FEED_HOLLOW != 0, true
}

feed_redaction :: proc "contextless" (length: u64) -> (at: i64, end: bool, ok: bool) {
	if length & FEED_REDACT == 0 || length == FEED_DROPPED {
		return
	}
	return i64(length & (FEED_REDACT_END - 1)), length & FEED_REDACT_END != 0, true
}

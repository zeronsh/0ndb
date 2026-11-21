package obj

import "../journal"
import "../prim"

FORMAT_VERSION :: 1
MAX_SEGS :: 1024
TAIL_GUESS :: 256 * 1024
MSG_GUESS :: 4096
BACK_SCAN :: 16 * 1024
CHAIN_MAX :: 64 * 1024 * 1024
SEG_SPAN :: 64 * 1024
LINKS_KIND_TAG :: 16

RECORD_HEAD :: 1
RECORD_SEG :: 2
RECORD_REDACT :: 3
RECORD_KIND_FIRST :: 16
RECORD_KIND_LAST :: 254

Kind :: enum u8 {
	Conversation = 1,
	Map          = 2,
	Text         = 3,
	File_Tree    = 4,
}

Error :: enum u8 {
	None,
	Missing,
	Corrupt,
	Invalid,
	Not_Found,
	Exists,
	Busy,
	Limit,
	Too_Large,
	Unsupported,
	Not_Assigned,
	Unknown_Segment,
	Forged,
	Permission,
	No_Space,
	No_Memory,
	Io,
}

Ref :: struct {
	seg: u32,
	off: i64,
}

Rid :: struct {
	seg: prim.Id,
	off: i64,
}

Xref :: struct {
	object: prim.Id,
	rid:    Rid,
}

Vref :: struct {
	seg: int,
	off: i64,
}

Want :: struct {
	object: prim.Id,
	seg:    prim.Id,
	from:   i64,
	to:     i64,
}

Range :: journal.Range

ref_none :: proc "contextless" (r: Ref) -> bool {
	return r.off <= 0
}

rid_none :: proc "contextless" (r: Rid) -> bool {
	return r.off <= 0
}

vref_none :: proc "contextless" (r: Vref) -> bool {
	return r.off <= 0
}

id_less :: proc "contextless" (a, b: prim.Id) -> bool {
	x, y := a, b
	for i in 0 ..< 16 {
		if x[i] != y[i] {
			return x[i] < y[i]
		}
	}
	return false
}

jerr :: proc "contextless" (e: journal.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Eof, .Bad_Offset, .Corrupt, .Redacted:
		return .Corrupt
	case .Missing:
		return .Missing
	case .No_Key:
		return .Permission
	case .Forged, .Unverified, .Equivocation:
		return .Forged
	case .Too_Large:
		return .Too_Large
	case .Invalid:
		return .Invalid
	case .Busy:
		return .Busy
	case .Not_Found:
		return .Not_Found
	case .Permission:
		return .Permission
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Io:
		return .Io
	}
	return .Io
}

perr :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Permission:
		return .Permission
	case .Busy, .Would_Block:
		return .Busy
	case .No_Space:
		return .No_Space
	case .No_Memory:
		return .No_Memory
	case .Too_Large:
		return .Too_Large
	case .Invalid:
		return .Invalid
	}
	return .Io
}

jrec_at :: proc(jr: ^journal.Reader, off: i64) -> (body: []u8, next: i64, err: journal.Error) {
	body, next, err = journal.record_at(jr, off)
	if err == .Redacted {
		return nil, next, .None
	}
	return
}

jrec_before :: proc(jr: ^journal.Reader, end: i64) -> (body: []u8, off: i64, err: journal.Error) {
	body, off, err = journal.record_before(jr, end)
	if err == .Redacted {
		return nil, off, .None
	}
	return
}

is_redacted :: proc "contextless" (body: []u8) -> bool {
	return len(body) == 0 || body[0] == 0
}

is_sig :: proc "contextless" (body: []u8) -> bool {
	return journal.is_sig(body)
}

record_kind :: proc "contextless" (body: []u8) -> u8 {
	if len(body) == 0 {
		return 0
	}
	return body[0]
}

suggested_tail :: proc "contextless" (length: i64) -> i64 {
	return min(length, TAIL_GUESS)
}

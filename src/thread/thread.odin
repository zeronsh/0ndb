package thread

import "../journal"
import "../prim"

FORMAT_VERSION :: 1
MAX_OPEN :: 8
MAX_PENDING :: 256
MAX_REVIVALS :: 3
REVIVE_WINDOW_MS :: 12 * 60 * 60 * 1000
INLINE_MAX :: 4096
CHUNK_MAX :: 16 * 1024
MAX_UPDATES :: 256
TAIL_GUESS :: 256 * 1024
MSG_GUESS :: 4096
BACK_SCAN :: 16 * 1024
CHAIN_MAX :: 64 * 1024 * 1024

LEAF :: i64(-1)

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
	Permission,
	No_Space,
	No_Memory,
	Io,
}

Kind :: enum u8 {
	Head        = 1,
	Msg         = 2,
	Block       = 3,
	Seal        = 4,
	Leaf        = 5,
	Queue       = 6,
	Unqueue     = 7,
	Scope       = 8,
	Interrupted = 9,
	Revived     = 10,
}

Role :: enum u8 {
	User      = 1,
	Assistant = 2,
	System    = 3,
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
}

Queue_Mode :: enum u8 {
	Queue = 1,
	Steer = 2,
}

Outcome :: enum u8 {
	Started   = 1,
	Steered   = 2,
	Cancelled = 3,
	Failed    = 4,
}

Scope_Kind :: enum u8 {
	Turn = 1,
	Tool = 2,
}

Status :: enum u8 {
	Idle                = 0,
	Running             = 1,
	Queued              = 2,
	Awaiting_Permission = 3,
	Failed              = 4,
	Interrupted         = 5,
}

Usage :: struct {
	input:       u64,
	output:      u64,
	cache_read:  u64,
	cache_write: u64,
}

Open :: struct {
	msg:     i64,
	last:    i64,
	blocks:  u32,
	state:   Open_State,
	attempt: u8,
}

Links :: struct {
	leaf_event: i64,
	leaf_seal:  i64,
	pending:    i64,
	open:       [MAX_OPEN]Open,
	open_len:   int,
}

Ref :: struct {
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

Pending_Entry :: struct {
	item:   i64,
	latest: i64,
}

Range :: journal.Range

links_open :: proc "contextless" (l: ^Links) -> []Open {
	return l.open[:l.open_len]
}

links_find :: proc "contextless" (l: ^Links, msg: i64) -> int {
	for i in 0 ..< l.open_len {
		if l.open[i].msg == msg {
			return i
		}
	}
	return -1
}

@(private)
_links_remove :: proc "contextless" (l: ^Links, i: int) {
	for k in i ..< l.open_len - 1 {
		l.open[k] = l.open[k + 1]
	}
	l.open_len -= 1
	l.open[l.open_len] = {}
}

@(private)
_jerr :: proc "contextless" (e: journal.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Eof, .Bad_Offset, .Corrupt:
		return .Corrupt
	case .Missing:
		return .Missing
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

@(private)
_perr :: proc "contextless" (e: prim.Error) -> Error {
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

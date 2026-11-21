package index

import "../journal"
import "../prim"
import "../thread"

MAX_FIELDS :: 64
MAX_OIDS :: 4096

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
	Device   = 1,
	Worktree = 2,
	Thread   = 3,
	Cursor   = 4,
	Rejected = 5,
}

Cmd_Record :: enum u8 {
	Cmd = 1,
}

Thread_Tag :: enum u8 {
	Title    = 1,
	Worktree = 2,
	Provider = 3,
	Model    = 4,
	Host     = 5,
	Created  = 6,
	Activity = 7,
	Archived = 8,
	Pinned   = 9,
	Leaf     = 10,
	Length   = 11,
	Status   = 12,
	Pending  = 13,
	Usage    = 14,
}

Worktree_Tag :: enum u8 {
	Path         = 1,
	Host         = 2,
	Repository   = 3,
	Branch       = 4,
	Source       = 5,
	Fork_Version = 6,
	Archived     = 7,
}

Reject_Reason :: enum u8 {
	Unknown     = 0,
	Not_Host    = 1,
	No_Thread   = 2,
	Busy        = 3,
	Invalid     = 4,
	Unsupported = 5,
	Failed      = 6,
	Limit       = 7,
}

Field :: struct {
	tag:   u8,
	hlc:   prim.Hlc,
	value: []u8,
}

Status_Value :: struct {
	status: thread.Status,
	queued: u32,
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

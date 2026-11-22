package osync

import "base:runtime"
import "../journal"
import "../prim"

Error :: enum u8 {
	None,
	Invalid,
	Corrupt,
	Auth,
	Protocol,
	Closed,
	Would_Block,
	Not_Found,
	Exists,
	Permission,
	No_Space,
	No_Memory,
	Too_Large,
	Busy,
	Quota,
	Conflict,
	Unsupported,
	Timeout,
	Resolve,
	Refused,
	Io,
	Pending,
}

code_error :: proc "contextless" (c: Code) -> Error {
	switch c {
	case .None:
		return .None
	case .Protocol:
		return .Protocol
	case .Auth:
		return .Auth
	case .Version:
		return .Unsupported
	case .Quota:
		return .Quota
	case .Not_Owner:
		return .Permission
	case .Too_Large:
		return .Too_Large
	case .Io:
		return .Io
	case .Busy:
		return .Busy
	case .Limit:
		return .Busy
	case .Not_Found:
		return .Not_Found
	}
	return .Refused
}

@(private)
_from_prim :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Permission:
		return .Permission
	case .Would_Block:
		return .Would_Block
	case .Broken_Pipe:
		return .Closed
	case .Busy:
		return .Busy
	case .Invalid, .Not_Dir, .Is_Dir, .Name_Too_Long:
		return .Invalid
	case .No_Space:
		return .No_Space
	case .No_Memory, .Too_Many_Files:
		return .No_Memory
	case .Too_Large:
		return .Too_Large
	case .Unsupported:
		return .Unsupported
	}
	return .Io
}

@(private)
_from_journal :: proc "contextless" (e: journal.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Corrupt, .Bad_Offset, .Missing, .Eof:
		return .Corrupt
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
	}
	return .Io
}

@(private)
_clone_string :: proc(s: string, allocator: runtime.Allocator) -> (string, Error) {
	b, e := make([]u8, len(s), allocator)
	if e != nil {
		return "", .No_Memory
	}
	copy(b, s)
	return string(b), .None
}

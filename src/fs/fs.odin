package fs

import "core:slice"
import "../fstree"
import "../odb"
import "../prim"

Error :: enum u8 {
	None,
	Not_Found,
	Exists,
	Permission,
	Busy,
	Invalid,
	Corrupt,
	Not_Dir,
	Is_Dir,
	Not_Empty,
	No_Space,
	No_Memory,
	Too_Large,
	Too_Many_Files,
	Name_Too_Long,
	Unsupported,
	Changed,
	Not_Repository,
	Stopped,
	Conflicts,
	Redacted,
	Io,
	Reloading,
	Deferred,
	Need_Source,
}

STATE_NAME :: ".0ndb"
TEMP_PREFIX :: ".0ndb-tmp-"

from_prim :: proc "contextless" (e: prim.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Not_Found, .No_Child:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Permission:
		return .Permission
	case .Would_Block, .Busy:
		return .Busy
	case .Interrupted, .Broken_Pipe, .Io:
		return .Io
	case .Invalid:
		return .Invalid
	case .Not_Dir:
		return .Not_Dir
	case .Is_Dir:
		return .Is_Dir
	case .Not_Empty:
		return .Not_Empty
	case .No_Space:
		return .No_Space
	case .Too_Many_Files:
		return .Too_Many_Files
	case .Name_Too_Long:
		return .Name_Too_Long
	case .Too_Large:
		return .Too_Large
	case .Unsupported:
		return .Unsupported
	case .No_Memory:
		return .No_Memory
	}
	return .Io
}

from_odb :: proc "contextless" (e: odb.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Corrupt, .Collision:
		return .Corrupt
	case .Too_Large:
		return .Too_Large
	case .Io, .Stale:
		return .Io
	case .Out_Of_Memory:
		return .No_Memory
	case .Invalid:
		return .Invalid
	case .Not_Repository:
		return .Not_Repository
	case .Locked:
		return .Busy
	case .Changed:
		return .Changed
	}
	return .Io
}

inode_less :: proc(a, b: fstree.Inode_Id) -> bool {
	if a.actor != b.actor {
		return a.actor < b.actor
	}
	return a.seq < b.seq
}

sorted_inodes :: proc(set: map[fstree.Inode_Id]$V, allocator := context.temp_allocator) -> []fstree.Inode_Id {
	out := make([]fstree.Inode_Id, len(set), allocator)
	i := 0
	for k in set {
		out[i] = k
		i += 1
	}
	slice.sort_by(out, inode_less)
	return out
}

sorted_strings :: proc(set: map[string]$V, allocator := context.temp_allocator) -> []string {
	out := make([]string, len(set), allocator)
	i := 0
	for k in set {
		out[i] = k
		i += 1
	}
	slice.sort(out)
	return out
}

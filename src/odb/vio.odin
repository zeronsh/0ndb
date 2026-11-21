package odb

import "base:runtime"
import "../prim"

@(private)
perr :: proc "contextless" (e: prim.Error) -> Error {
	#partial switch e {
	case .None:
		return .None
	case .Not_Found:
		return .Not_Found
	case .No_Memory:
		return .Out_Of_Memory
	case .Too_Large:
		return .Too_Large
	case .Invalid, .Name_Too_Long:
		return .Invalid
	case .Busy, .Would_Block:
		return .Locked
	}
	return .Io
}

@(private)
vfs_is_os :: proc "contextless" (vfs: prim.Vfs) -> bool {
	return vfs.procs == prim.os_vfs().procs
}

@(private)
vfs_read_file :: proc(vfs: prim.Vfs, path: string, allocator: runtime.Allocator) -> ([]u8, Error) {
	data, err := prim.read_file(vfs, path, allocator)
	return data, perr(err)
}

@(private)
vfs_mkdir :: proc(db: ^Odb, path: string) -> (created: bool, err: Error) {
	e := prim.mkdir(db.vfs, path, 0o777)
	if e == .None {
		return true, .None
	}
	if e == .Exists {
		return false, .None
	}
	return false, perr(e)
}

@(private)
vfs_size :: proc(vfs: prim.Vfs, fd: prim.Fd) -> (i64, Error) {
	size, e := prim.file_size(vfs, fd)
	return size, perr(e)
}

@(private)
vfs_mtime :: proc(vfs: prim.Vfs, path: string) -> (i64, bool) {
	st, e := prim.stat(vfs, path)
	return st.mtime_ns, e == .None
}

@(private)
set_mtime :: proc(db: ^Odb, path: string, ns: i64) -> bool {
	return prim.set_times(db.vfs, path, ns, ns) == .None
}

@(private)
now_ns :: proc(db: ^Odb) -> i64 {
	return prim.clock_wall_ns(db.clock)
}

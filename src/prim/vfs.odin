package prim

import "base:runtime"

Vfs :: struct {
	procs: ^Vfs_Procs,
	data:  rawptr,
}

File_Kind :: enum u8 {
	Unknown,
	File,
	Dir,
	Symlink,
	Other,
}

Stat :: struct {
	size:     i64,
	mode:     u32,
	kind:     File_Kind,
	ino:      u64,
	dev:      u64,
	nlink:    u64,
	mtime_ns: i64,
	ctime_ns: i64,
}

Dir :: struct {
	fd:        Fd,
	handle:    rawptr,
	buf:       []u8,
	pos:       int,
	len:       int,
	eof:       bool,
	allocator: runtime.Allocator,
}

Dir_Entry :: struct {
	name: string,
	ino:  u64,
	kind: File_Kind,
}

Vfs_Procs :: struct {
	open:       proc(data: rawptr, path: string, flags: Open_Flags, mode: u32) -> (Fd, Error),
	close:      proc(data: rawptr, fd: Fd) -> Error,
	read_at:    proc(data: rawptr, fd: Fd, buf: []u8, off: i64) -> (int, Error),
	write_at:   proc(data: rawptr, fd: Fd, src: []u8, off: i64) -> Error,
	datasync:   proc(data: rawptr, fd: Fd) -> Error,
	fullsync:   proc(data: rawptr, fd: Fd) -> Error,
	truncate:   proc(data: rawptr, fd: Fd, size: i64) -> Error,
	punch_hole: proc(data: rawptr, fd: Fd, off: i64, size: i64) -> Error,
	lock:       proc(data: rawptr, fd: Fd) -> Error,
	fstat:      proc(data: rawptr, fd: Fd) -> (Stat, Error),
	stat:       proc(data: rawptr, path: string, follow: bool) -> (Stat, Error),
	rename:     proc(data: rawptr, old: string, new: string) -> Error,
	unlink:     proc(data: rawptr, path: string) -> Error,
	rmdir:      proc(data: rawptr, path: string) -> Error,
	mkdir:      proc(data: rawptr, path: string, mode: u32) -> Error,
	symlink:    proc(data: rawptr, target: string, path: string) -> Error,
	readlink:   proc(data: rawptr, path: string, buf: []u8) -> (int, Error),
	fchmod:     proc(data: rawptr, fd: Fd, mode: u32) -> Error,
	set_times:  proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> Error,
	dir_open:   proc(data: rawptr, d: ^Dir, path: string) -> Error,
	dir_next:   proc(data: rawptr, d: ^Dir) -> (Dir_Entry, bool, Error),
	dir_close:  proc(data: rawptr, d: ^Dir),
}

os_vfs :: proc "contextless" () -> Vfs {
	return Vfs{procs = &OS_VFS_PROCS}
}

open_file :: #force_inline proc(vfs: Vfs, path: string, flags: Open_Flags = {}, mode: u32 = 0o644) -> (Fd, Error) {
	return vfs.procs.open(vfs.data, path, flags, mode)
}

close_file :: #force_inline proc(vfs: Vfs, fd: Fd) -> Error {
	return vfs.procs.close(vfs.data, fd)
}

read_at :: #force_inline proc(vfs: Vfs, fd: Fd, buf: []u8, off: i64) -> (int, Error) {
	return vfs.procs.read_at(vfs.data, fd, buf, off)
}

write_at :: #force_inline proc(vfs: Vfs, fd: Fd, src: []u8, off: i64) -> Error {
	return vfs.procs.write_at(vfs.data, fd, src, off)
}

datasync :: #force_inline proc(vfs: Vfs, fd: Fd) -> Error {
	return vfs.procs.datasync(vfs.data, fd)
}

fullsync :: #force_inline proc(vfs: Vfs, fd: Fd) -> Error {
	return vfs.procs.fullsync(vfs.data, fd)
}

truncate :: #force_inline proc(vfs: Vfs, fd: Fd, size: i64) -> Error {
	return vfs.procs.truncate(vfs.data, fd, size)
}

punch_hole :: #force_inline proc(vfs: Vfs, fd: Fd, off: i64, size: i64) -> Error {
	return vfs.procs.punch_hole(vfs.data, fd, off, size)
}

fstat :: #force_inline proc(vfs: Vfs, fd: Fd) -> (Stat, Error) {
	return vfs.procs.fstat(vfs.data, fd)
}

stat :: #force_inline proc(vfs: Vfs, path: string) -> (Stat, Error) {
	return vfs.procs.stat(vfs.data, path, true)
}

lstat :: #force_inline proc(vfs: Vfs, path: string) -> (Stat, Error) {
	return vfs.procs.stat(vfs.data, path, false)
}

rename :: #force_inline proc(vfs: Vfs, old: string, new: string) -> Error {
	return vfs.procs.rename(vfs.data, old, new)
}

remove :: #force_inline proc(vfs: Vfs, path: string) -> Error {
	return vfs.procs.unlink(vfs.data, path)
}

remove_dir :: #force_inline proc(vfs: Vfs, path: string) -> Error {
	return vfs.procs.rmdir(vfs.data, path)
}

mkdir :: #force_inline proc(vfs: Vfs, path: string, mode: u32 = 0o755) -> Error {
	return vfs.procs.mkdir(vfs.data, path, mode)
}

symlink :: #force_inline proc(vfs: Vfs, target: string, path: string) -> Error {
	return vfs.procs.symlink(vfs.data, target, path)
}

readlink :: #force_inline proc(vfs: Vfs, path: string, buf: []u8) -> (int, Error) {
	return vfs.procs.readlink(vfs.data, path, buf)
}

fchmod :: #force_inline proc(vfs: Vfs, fd: Fd, mode: u32) -> Error {
	return vfs.procs.fchmod(vfs.data, fd, mode)
}

set_times :: #force_inline proc(vfs: Vfs, path: string, atime_ns: i64, mtime_ns: i64) -> Error {
	return vfs.procs.set_times(vfs.data, path, atime_ns, mtime_ns)
}

dir_open :: proc(vfs: Vfs, d: ^Dir, path: string, allocator := context.allocator) -> Error {
	d^ = {
		fd        = INVALID_FD,
		allocator = allocator,
	}
	return vfs.procs.dir_open(vfs.data, d, path)
}

dir_next :: #force_inline proc(vfs: Vfs, d: ^Dir) -> (Dir_Entry, bool, Error) {
	return vfs.procs.dir_next(vfs.data, d)
}

dir_close :: #force_inline proc(vfs: Vfs, d: ^Dir) {
	vfs.procs.dir_close(vfs.data, d)
}

file_size :: proc(vfs: Vfs, fd: Fd) -> (i64, Error) {
	st, err := fstat(vfs, fd)
	return st.size, err
}

is_dir :: proc(vfs: Vfs, path: string) -> bool {
	st, err := stat(vfs, path)
	return err == .None && st.kind == .Dir
}

exists :: proc(vfs: Vfs, path: string) -> bool {
	_, err := lstat(vfs, path)
	return err == .None
}

sync_dir :: proc(vfs: Vfs, path: string) -> Error {
	fd, err := open_file(vfs, path, {.Directory})
	if err != .None {
		return err
	}
	err = fullsync(vfs, fd)
	close_file(vfs, fd)
	return err
}

lock_file :: proc(vfs: Vfs, path: string) -> (fd: Fd, err: Error) {
	fd = open_file(vfs, path, {.Write, .Create}, 0o600) or_return
	if err = vfs.procs.lock(vfs.data, fd); err != .None {
		close_file(vfs, fd)
		return INVALID_FD, err
	}
	return fd, .None
}

zero_range :: proc(vfs: Vfs, fd: Fd, off: i64, size: i64) -> Error {
	if size <= 0 {
		return .None
	}
	if punch_hole(vfs, fd, off, size) == .None {
		return .None
	}
	zeros: [4096]u8
	pos := off
	end := off + size
	for pos < end {
		n := min(end - pos, i64(len(zeros)))
		if err := write_at(vfs, fd, zeros[:n], pos); err != .None {
			return err
		}
		pos += n
	}
	return .None
}

@(private)
_kind_from_mode :: proc "contextless" (mode: u32) -> File_Kind {
	switch mode & 0o170000 {
	case 0o100000:
		return .File
	case 0o040000:
		return .Dir
	case 0o120000:
		return .Symlink
	case 0:
		return .Unknown
	}
	return .Other
}

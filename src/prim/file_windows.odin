package prim

import "base:runtime"
import win "core:sys/windows"

@(rodata)
OS_VFS_PROCS := Vfs_Procs {
	open       = _os_open,
	close      = _os_close,
	read_at    = _os_read_at,
	write_at   = _os_write_at,
	datasync   = _os_datasync,
	fullsync   = _os_fullsync,
	truncate   = _os_truncate,
	punch_hole = _os_punch_hole,
	preallocate = _os_preallocate,
	lock       = _os_lock,
	fstat      = _os_fstat,
	stat       = _os_stat,
	rename     = _os_rename,
	unlink     = _os_unlink,
	rmdir      = _os_rmdir,
	mkdir      = _os_mkdir,
	symlink    = _os_symlink,
	readlink   = _os_readlink,
	fchmod     = _os_fchmod,
	set_times  = _os_set_times,
	dir_open   = _os_dir_open,
	dir_next   = _os_dir_next,
	dir_close  = _os_dir_close,
	writeout   = _os_writeout,
}

@(private)
LOCK_OFFSET :: u64(0x7FFF_FFFF_FFFF_FFF0)

@(private)
_Handle_Kind :: enum u8 {
	Other,
	Disk,
	Char,
	Pipe,
	Socket,
}

@(private)
_handle_kind :: proc "contextless" (h: HANDLE) -> _Handle_Kind {
	switch win.GetFileType(h) {
	case FILE_TYPE_DISK:
		return .Disk
	case FILE_TYPE_CHAR:
		return .Char
	case FILE_TYPE_PIPE:
		if _is_socket(h) {
			return .Socket
		}
		return .Pipe
	}
	return .Other
}

@(private)
_is_socket :: proc "contextless" (h: HANDLE) -> bool {
	ty: i32
	n: i32 = size_of(ty)
	return win.getsockopt(win.SOCKET(uintptr(h)), SOL_SOCKET, SO_TYPE, ([^]u8)(&ty), &n) == 0
}

@(private)
_pipe_local :: proc "contextless" (h: HANDLE) -> (info: Pipe_Local_Info, ok: bool) {
	iosb: IO_STATUS_BLOCK
	st := win.NtQueryInformationFile(h, &iosb, &info, size_of(info), win.FILE_INFORMATION_CLASS(FilePipeLocalInformation))
	return info, st >= 0
}

@(private)
_pipe_nowait :: proc "contextless" (h: HANDLE) -> (nowait: bool, ok: bool) {
	iosb: IO_STATUS_BLOCK
	info: Pipe_Info
	st := win.NtQueryInformationFile(h, &iosb, &info, size_of(info), win.FILE_INFORMATION_CLASS(FilePipeInformation))
	return info.completion_mode == FILE_PIPE_COMPLETE_OPERATION, st >= 0
}

@(private)
_handle_synchronous :: proc "contextless" (h: HANDLE) -> bool {
	iosb: IO_STATUS_BLOCK
	mode: u32
	st := win.NtQueryInformationFile(h, &iosb, &mode, size_of(mode), win.FILE_INFORMATION_CLASS(FileModeInformation))
	return st >= 0 && mode & (FILE_SYNCHRONOUS_IO_ALERT | FILE_SYNCHRONOUS_IO_NONALERT) != 0
}

close :: proc "contextless" (fd: Fd) -> Error {
	if fd == INVALID_FD || fd == 0 {
		return .None
	}
	h := _h(fd)
	if win.GetFileType(h) == FILE_TYPE_PIPE && _is_socket(h) {
		if win.closesocket(win.SOCKET(uintptr(h))) != 0 {
			return _werror(u32(win.WSAGetLastError()))
		}
		return .None
	}
	if !win.CloseHandle(h) {
		return _last()
	}
	return .None
}

@(private)
_wait_overlapped :: proc "contextless" (h: HANDLE, ov: ^win.OVERLAPPED) -> (u32, Error) {
	n: u32
	if !win.GetOverlappedResult(h, ov, &n, true) {
		code := win.GetLastError()
		if code == ERROR_HANDLE_EOF {
			return n, .None
		}
		return n, _werror(code)
	}
	return n, .None
}

@(private)
_new_event :: proc "contextless" () -> HANDLE {
	return win.CreateEventW(nil, true, false, nil)
}

@(private)
_pipe_read :: proc "contextless" (h: HANDLE, buf: []u8) -> (int, Error) {
	avail: u32
	if !win.PeekNamedPipe(h, nil, 0, nil, &avail, nil) {
		code := win.GetLastError()
		if code == ERROR_BROKEN_PIPE || code == ERROR_PIPE_NOT_CONNECTED {
			return 0, .None
		}
		return 0, _werror(code)
	}
	want := u32(min(len(buf), int(max(u32))))
	if avail == 0 {
		if !_handle_synchronous(h) {
			return 0, .Would_Block
		}
		n: u32
		if !win.ReadFile(h, raw_data(buf), want, &n, nil) {
			code := win.GetLastError()
			if code == ERROR_BROKEN_PIPE {
				return 0, .None
			}
			return 0, _werror(code)
		}
		return int(n), .None
	}
	want = min(want, avail)
	ov: win.OVERLAPPED
	n: u32
	if !win.ReadFile(h, raw_data(buf), want, &n, &ov) {
		code := win.GetLastError()
		if code == ERROR_BROKEN_PIPE {
			return 0, .None
		}
		if code != ERROR_IO_PENDING {
			return 0, _werror(code)
		}
		got, err := _wait_overlapped(h, &ov)
		return int(got), err
	}
	return int(n), .None
}

@(private)
_pipe_write :: proc "contextless" (h: HANDLE, data: []u8) -> (int, Error) {
	nowait, ok := _pipe_nowait(h)
	if !ok {
		n: u32
		if !win.WriteFile(h, raw_data(data), u32(min(len(data), int(max(u32)))), &n, nil) {
			return 0, _last()
		}
		return int(n), .None
	}
	want := u32(min(len(data), int(max(u32))))
	if !nowait {
		ev := _new_event()
		if ev == nil {
			return 0, _last()
		}
		defer win.CloseHandle(ev)
		ov := win.OVERLAPPED {
			hEvent = HANDLE(uintptr(ev) | 1),
		}
		n: u32
		if !win.WriteFile(h, raw_data(data), want, &n, &ov) {
			code := win.GetLastError()
			if code != ERROR_IO_PENDING {
				return 0, _werror(code)
			}
			got, err := _wait_overlapped(h, &ov)
			return int(got), err
		}
		return int(n), .None
	}
	ov: win.OVERLAPPED
	n: u32
	if !win.WriteFile(h, raw_data(data), want, &n, &ov) {
		return 0, _werror(win.GetLastError())
	}
	if n > 0 {
		return int(n), .None
	}
	info, iok := _pipe_local(h)
	if !iok || info.write_quota == 0 {
		return 0, .Would_Block
	}
	ov = {}
	if !win.WriteFile(h, raw_data(data), min(want, info.write_quota), &n, &ov) {
		return 0, _werror(win.GetLastError())
	}
	if n == 0 {
		return 0, .Would_Block
	}
	return int(n), .None
}

read :: proc "contextless" (fd: Fd, buf: []u8) -> (int, Error) {
	if len(buf) == 0 {
		return 0, .None
	}
	h := _h(fd)
	switch _handle_kind(h) {
	case .Pipe:
		return _pipe_read(h, buf)
	case .Socket:
		r := win.recv(win.SOCKET(uintptr(h)), raw_data(buf), i32(min(len(buf), int(max(i32)))), 0)
		if r < 0 {
			return 0, _werror(u32(win.WSAGetLastError()))
		}
		return int(r), .None
	case .Disk, .Char, .Other:
	}
	n: u32
	if !win.ReadFile(h, raw_data(buf), u32(min(len(buf), int(max(u32)))), &n, nil) {
		code := win.GetLastError()
		if code == ERROR_BROKEN_PIPE || code == ERROR_HANDLE_EOF {
			return 0, .None
		}
		return 0, _werror(code)
	}
	return int(n), .None
}

write :: proc "contextless" (fd: Fd, data: []u8) -> (int, Error) {
	if len(data) == 0 {
		return 0, .None
	}
	h := _h(fd)
	switch _handle_kind(h) {
	case .Pipe:
		return _pipe_write(h, data)
	case .Socket:
		r := win.send(win.SOCKET(uintptr(h)), raw_data(data), i32(min(len(data), int(max(i32)))), 0)
		if r < 0 {
			return 0, _werror(u32(win.WSAGetLastError()))
		}
		return int(r), .None
	case .Disk, .Char, .Other:
	}
	n: u32
	if !win.WriteFile(h, raw_data(data), u32(min(len(data), int(max(u32)))), &n, nil) {
		return 0, _last()
	}
	return int(n), .None
}

write_all :: proc "contextless" (fd: Fd, data: []u8) -> Error {
	n := 0
	for n < len(data) {
		w, err := write(fd, data[n:])
		if err != .None {
			return err
		}
		if w == 0 {
			return .Io
		}
		n += w
	}
	return .None
}

set_nonblocking :: proc "contextless" (fd: Fd, on: bool = true) -> Error {
	h := _h(fd)
	switch _handle_kind(h) {
	case .Socket:
		arg: u32 = 1 if on else 0
		if win.ioctlsocket(win.SOCKET(uintptr(h)), i32(transmute(i32)u32(0x8004667e)), &arg) != 0 {
			return _werror(u32(win.WSAGetLastError()))
		}
		return .None
	case .Pipe:
		info, ok := _pipe_local(h)
		if !ok {
			return .Unsupported
		}
		if info.configuration == FILE_PIPE_INBOUND && info.end == FILE_PIPE_SERVER_END {
			if on && !_handle_synchronous(h) {
				return .None
			}
			return .Unsupported
		}
		mode: u32 = PIPE_READMODE_BYTE | (PIPE_NOWAIT if on else PIPE_WAIT)
		if !SetNamedPipeHandleState(h, &mode, nil, nil) {
			return _last()
		}
		return .None
	case .Disk, .Char, .Other:
	}
	return .Unsupported
}

@(private)
_os_open :: proc(data: rawptr, path: string, flags: Open_Flags, mode: u32) -> (Fd, Error) {
	buf: WPath_Buf = ---
	p, perr := _wpath(path, &buf)
	if perr != .None {
		return INVALID_FD, perr
	}
	access: u32 = GENERIC_READ
	if .Write in flags {
		access |= GENERIC_WRITE
		if .Append in flags {
			access = GENERIC_READ | FILE_APPEND_DATA | FILE_WRITE_ATTRIBUTES | SYNCHRONIZE
		}
	}
	disp: u32 = OPEN_EXISTING
	if .Create in flags {
		if .Exclusive in flags {
			disp = CREATE_NEW
		} else if .Truncate in flags {
			disp = CREATE_ALWAYS
		} else {
			disp = OPEN_ALWAYS
		}
	} else if .Truncate in flags {
		disp = TRUNCATE_EXISTING
	}
	attrs: u32 = FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS
	if .Directory in flags {
		if .Create in flags || .Truncate in flags {
			return INVALID_FD, .Invalid
		}
		h := win.CreateFileW(_ws(p), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
		if h == INVALID_HANDLE && win.GetLastError() == ERROR_ACCESS_DENIED {
			h = win.CreateFileW(_ws(p), GENERIC_READ, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
		}
		if h == INVALID_HANDLE {
			return INVALID_FD, _last()
		}
		tag: File_Attribute_Tag_Info
		if !win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) {
			err := _last()
			win.CloseHandle(h)
			return INVALID_FD, err
		}
		if tag.attributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
			win.CloseHandle(h)
			return INVALID_FD, .Not_Dir
		}
		return _fd(h), .None
	}
	h := win.CreateFileW(_ws(p), access, FILE_SHARE_ALL, nil, disp, attrs, nil)
	if h == INVALID_HANDLE {
		code := win.GetLastError()
		if code == ERROR_ACCESS_DENIED && .Write in flags {
			tag: File_Attribute_Tag_Info
			probe := win.CreateFileW(_ws(p), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
			if probe != INVALID_HANDLE {
				isdir := win.GetFileInformationByHandleEx(probe, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) && tag.attributes & FILE_ATTRIBUTE_DIRECTORY != 0
				win.CloseHandle(probe)
				if isdir {
					return INVALID_FD, .Is_Dir
				}
			}
		}
		return INVALID_FD, _werror(code)
	}
	return _fd(h), .None
}

@(private)
_os_close :: proc(data: rawptr, fd: Fd) -> Error {
	if fd == INVALID_FD {
		return .None
	}
	if !win.CloseHandle(_h(fd)) {
		return _last()
	}
	return .None
}

@(private)
CHUNK :: 1 << 30

@(private)
_os_read_at :: proc(data: rawptr, fd: Fd, buf: []u8, off: i64) -> (int, Error) {
	if off < 0 {
		return 0, .Invalid
	}
	h := _h(fd)
	n := 0
	for n < len(buf) {
		ov: win.OVERLAPPED
		ov.OffsetFull = u64(off + i64(n))
		want := u32(min(len(buf) - n, CHUNK))
		got: u32
		if !win.ReadFile(h, &buf[n], want, &got, &ov) {
			code := win.GetLastError()
			if code == ERROR_HANDLE_EOF {
				break
			}
			if code == ERROR_IO_PENDING {
				w, err := _wait_overlapped(h, &ov)
				if err != .None {
					return n, err
				}
				got = w
			} else {
				return n, _werror(code)
			}
		}
		if got == 0 {
			break
		}
		n += int(got)
	}
	return n, .None
}

@(private)
_os_write_at :: proc(data: rawptr, fd: Fd, src: []u8, off: i64) -> Error {
	if off < 0 {
		return .Invalid
	}
	h := _h(fd)
	n := 0
	for n < len(src) {
		ov: win.OVERLAPPED
		ov.OffsetFull = u64(off + i64(n))
		want := u32(min(len(src) - n, CHUNK))
		got: u32
		if !win.WriteFile(h, &src[n], want, &got, &ov) {
			code := win.GetLastError()
			if code != ERROR_IO_PENDING {
				return _werror(code)
			}
			w, err := _wait_overlapped(h, &ov)
			if err != .None {
				return err
			}
			got = w
		}
		if got == 0 {
			return .Io
		}
		n += int(got)
	}
	return .None
}

@(private)
_flush_data :: proc "contextless" (h: HANDLE) -> NTSTATUS {
	iosb: IO_STATUS_BLOCK
	st := NtFlushBuffersFileEx(h, FLUSH_FLAGS_FILE_DATA_SYNC_ONLY, nil, 0, &iosb)
	if st == STATUS_INVALID_PARAMETER || st == STATUS_NOT_SUPPORTED || st == STATUS_NOT_IMPLEMENTED || st == STATUS_INVALID_DEVICE_REQUEST {
		if win.FlushFileBuffers(h) {
			return 0
		}
		return STATUS_ACCESS_DENIED if win.GetLastError() == ERROR_ACCESS_DENIED else STATUS_UNSUCCESSFUL
	}
	return st
}

@(private)
_writable_twin :: proc "contextless" (h: HANDLE) -> HANDLE {
	return ReOpenFile(h, GENERIC_WRITE, FILE_SHARE_ALL, FILE_FLAG_BACKUP_SEMANTICS)
}

@(private)
_os_datasync :: proc(data: rawptr, fd: Fd) -> Error {
	h := _h(fd)
	st := _flush_data(h)
	if st == STATUS_ACCESS_DENIED {
		twin := _writable_twin(h)
		if twin == INVALID_HANDLE {
			return _last()
		}
		st = _flush_data(twin)
		win.CloseHandle(twin)
	}
	if st == STATUS_UNSUCCESSFUL {
		return _last()
	}
	return _nterror(st)
}

@(private)
FLUSH_FLAGS_NO_SYNC :: 0x2

@(private)
_os_writeout :: proc(data: rawptr, fd: Fd) -> Error {
	h := _h(fd)
	iosb: IO_STATUS_BLOCK
	st := NtFlushBuffersFileEx(h, FLUSH_FLAGS_NO_SYNC, nil, 0, &iosb)
	if st == STATUS_ACCESS_DENIED {
		twin := _writable_twin(h)
		if twin == INVALID_HANDLE {
			return _last()
		}
		st = NtFlushBuffersFileEx(twin, FLUSH_FLAGS_NO_SYNC, nil, 0, &iosb)
		win.CloseHandle(twin)
	}
	return _nterror(st)
}

@(private)
_os_fullsync :: proc(data: rawptr, fd: Fd) -> Error {
	h := _h(fd)
	if win.FlushFileBuffers(h) {
		return .None
	}
	if win.GetLastError() != ERROR_ACCESS_DENIED {
		return _last()
	}
	twin := _writable_twin(h)
	if twin == INVALID_HANDLE {
		return _last()
	}
	defer win.CloseHandle(twin)
	if !win.FlushFileBuffers(twin) {
		return _last()
	}
	return .None
}

@(private)
_os_truncate :: proc(data: rawptr, fd: Fd, size: i64) -> Error {
	if size < 0 {
		return .Invalid
	}
	eof := size
	if !win.SetFileInformationByHandle(_h(fd), win.FILE_INFO_BY_HANDLE_CLASS(FileEndOfFileInfo), &eof, size_of(eof)) {
		return _last()
	}
	return .None
}

@(private)
_os_preallocate :: proc(data: rawptr, fd: Fd, off: i64, size: i64) -> Error {
	h := _h(fd)
	si: File_Standard_Info
	if !win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileStandardInfo), &si, size_of(si)) {
		return _last()
	}
	want := off + size
	if si.allocation_size >= want {
		return .None
	}
	alloc := want
	if !win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAllocationInfo), &alloc, size_of(alloc)) {
		return _last()
	}
	return .None
}

@(private)
_os_punch_hole :: proc(data: rawptr, fd: Fd, off: i64, size: i64) -> Error {
	if size <= 0 {
		return .None
	}
	if off < 0 {
		return .Invalid
	}
	h := _h(fd)
	eof: i64
	if !win.GetFileSizeEx(h, (^win.LARGE_INTEGER)(&eof)) {
		return _last()
	}
	end := min(off + size, eof)
	if end <= off {
		return .None
	}
	tag: File_Attribute_Tag_Info
	if !win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) {
		return _last()
	}
	ret: u32
	if tag.attributes & FILE_ATTRIBUTE_SPARSE_FILE == 0 {
		if !win.DeviceIoControl(h, FSCTL_SET_SPARSE, nil, 0, nil, 0, &ret, nil) {
			return _last()
		}
	}
	z := Zero_Data_Info {
		offset = off,
		beyond = end,
	}
	if !win.DeviceIoControl(h, FSCTL_SET_ZERO_DATA, &z, size_of(z), nil, 0, &ret, nil) {
		return _last()
	}
	return .None
}

@(private)
_os_lock :: proc(data: rawptr, fd: Fd) -> Error {
	ov: win.OVERLAPPED
	ov.OffsetFull = LOCK_OFFSET
	if !win.LockFileEx(_h(fd), LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov) {
		code := win.GetLastError()
		if code == ERROR_LOCK_VIOLATION || code == ERROR_IO_PENDING {
			return .Busy
		}
		return _werror(code)
	}
	return .None
}

@(private)
_stat_build :: proc "contextless" (attrs: u32, tag: u32, follow: bool, size: i64, id: i64, links: u32, write: i64, change: i64, dev: u64) -> Stat {
	kind: File_Kind
	mode: u32
	switch {
	case attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 && !follow && (tag == IO_REPARSE_TAG_SYMLINK || tag == IO_REPARSE_TAG_MOUNT_POINT || tag == IO_REPARSE_TAG_LX_SYMLINK):
		kind = .Symlink
		mode = 0o120777
	case attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 && tag == IO_REPARSE_TAG_AF_UNIX:
		kind = .Other
		mode = 0o140777
	case attrs & FILE_ATTRIBUTE_DIRECTORY != 0:
		kind = .Dir
		mode = 0o040755
	case:
		kind = .File
		mode = 0o100444 if attrs & FILE_ATTRIBUTE_READONLY != 0 else 0o100644
	}
	return Stat {
		size = size if kind == .File || kind == .Other else 0,
		mode = mode,
		kind = kind,
		ino = u64(id),
		dev = dev,
		nlink = u64(links),
		mtime_ns = _filetime_ns(write),
		ctime_ns = _filetime_ns(change),
	}
}

@(private)
_fstat_handle :: proc "contextless" (h: HANDLE, follow: bool) -> (Stat, Error) {
	iosb: IO_STATUS_BLOCK
	b: File_Stat_Basic_Info
	st := win.NtQueryInformationFile(h, &iosb, &b, size_of(b), win.FILE_INFORMATION_CLASS(FileStatBasicInformation))
	if st >= 0 {
		return _stat_build(b.attributes, b.reparse_tag, follow, b.end_of_file, b.file_id, b.links, b.last_write, b.change, u64(u32(b.volume_serial))), .None
	}
	if st != STATUS_INVALID_INFO_CLASS && st != STATUS_INVALID_PARAMETER && st != STATUS_NOT_IMPLEMENTED {
		return {}, _nterror(st)
	}
	s: File_Stat_Info
	st = win.NtQueryInformationFile(h, &iosb, &s, size_of(s), win.FILE_INFORMATION_CLASS(FileStatInformation))
	if st < 0 {
		return {}, _nterror(st)
	}
	vol: [64]u8
	serial: u32
	if NtQueryVolumeInformationFile(h, &iosb, &vol[0], size_of(vol), FileFsVolumeInformation) >= 0 {
		serial = u32(vol[8]) | u32(vol[9]) << 8 | u32(vol[10]) << 16 | u32(vol[11]) << 24
	}
	return _stat_build(s.attributes, s.reparse_tag, follow, s.end_of_file, s.file_id, s.links, s.last_write, s.change, u64(serial)), .None
}

@(private)
_os_fstat :: proc(data: rawptr, fd: Fd) -> (Stat, Error) {
	return _fstat_handle(_h(fd), true)
}

@(private)
_by_name :: proc "contextless" () -> Proc_Get_File_Information_By_Name {
	name := [?]u16{'k', 'e', 'r', 'n', 'e', 'l', '3', '2', '.', 'd', 'l', 'l', 0}
	k := win.GetModuleHandleW(_ws(&name[0]))
	if k == nil {
		return nil
	}
	return Proc_Get_File_Information_By_Name(win.GetProcAddress(k, "GetFileInformationByName"))
}

@(private)
_os_stat :: proc(data: rawptr, path: string, follow: bool) -> (Stat, Error) {
	buf: WPath_Buf = ---
	p, perr := _wpath(path, &buf)
	if perr != .None {
		return {}, perr
	}
	if by_name := _by_name(); by_name != nil {
		b: File_Stat_Basic_Info
		if by_name(p, FileStatBasicByNameInfo, &b, size_of(b)) {
			reparse := b.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
			linkish := reparse && (b.reparse_tag == IO_REPARSE_TAG_SYMLINK || b.reparse_tag == IO_REPARSE_TAG_MOUNT_POINT || b.reparse_tag == IO_REPARSE_TAG_LX_SYMLINK)
			if !follow || !linkish {
				return _stat_build(b.attributes, b.reparse_tag, follow, b.end_of_file, b.file_id, b.links, b.last_write, b.change, u64(u32(b.volume_serial))), .None
			}
		} else {
			code := win.GetLastError()
			if code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND || code == ERROR_INVALID_NAME || code == ERROR_DIRECTORY {
				return {}, _werror(code)
			}
		}
	}
	flags: u32 = FILE_FLAG_BACKUP_SEMANTICS
	if !follow {
		flags |= FILE_FLAG_OPEN_REPARSE_POINT
	}
	h := win.CreateFileW(_ws(p), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, flags, nil)
	if h == INVALID_HANDLE {
		return {}, _last()
	}
	defer win.CloseHandle(h)
	return _fstat_handle(h, follow)
}

@(private)
_rename_info :: proc "contextless" (np: [^]u16, out: []u8, flags: u32) -> (int, bool) {
	n := _wlen(np)
	size := 20 + n * 2 + 2
	if size > len(out) {
		return 0, false
	}
	for i in 0 ..< len(out) {
		out[i] = 0
	}
	(^u32)(&out[0])^ = flags
	(^u32)(&out[16])^ = u32(n * 2)
	dst := ([^]u16)(&out[20])
	for i in 0 ..< n {
		dst[i] = np[i]
	}
	return size, true
}

@(private)
_os_rename :: proc(data: rawptr, old: string, new: string) -> Error {
	a: WPath_Buf = ---
	b: WPath_Buf = ---
	pa := _wpath(old, &a) or_return
	pb := _wpath(new, &b, true) or_return
	h := win.CreateFileW(_ws(pa), DELETE | SYNCHRONIZE | FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nil)
	if h == INVALID_HANDLE {
		return _last()
	}
	defer win.CloseHandle(h)
	info: [20 + WPATH_MAX * 2 + 8]u8 = ---
	size, ok := _rename_info(pb, info[:], FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS | FILE_RENAME_FLAG_IGNORE_READONLY_ATTRIBUTE)
	if !ok {
		return .Name_Too_Long
	}
	if win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileRenameInfoEx), &info[0], u32(size)) {
		return .None
	}
	code := win.GetLastError()
	if code != ERROR_INVALID_PARAMETER && code != ERROR_NOT_SUPPORTED && code != ERROR_INVALID_FUNCTION {
		return _rename_error(code, h, pb)
	}
	(^u32)(&info[0])^ = 1
	if win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileRenameInfo), &info[0], u32(size)) {
		return .None
	}
	return _rename_error(win.GetLastError(), h, pb)
}

@(private)
_rename_error :: proc "contextless" (code: u32, src: HANDLE, dst_nt: [^]u16) -> Error {
	if code != ERROR_ACCESS_DENIED {
		return _werror(code)
	}
	tag: File_Attribute_Tag_Info
	if !win.GetFileInformationByHandleEx(src, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) {
		return .Permission
	}
	dst_dos: WPath_Buf = ---
	n := _wlen(dst_nt)
	for i in 0 ..< n {
		dst_dos[i] = dst_nt[i]
	}
	dst_dos[1] = '\\'
	dst_dos[n] = 0
	h := win.CreateFileW(_ws(&dst_dos[0]), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nil)
	if h == INVALID_HANDLE {
		return .Permission
	}
	dtag: File_Attribute_Tag_Info
	ok := win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &dtag, size_of(dtag))
	win.CloseHandle(h)
	if !ok {
		return .Permission
	}
	src_dir := tag.attributes & FILE_ATTRIBUTE_DIRECTORY != 0 && tag.attributes & FILE_ATTRIBUTE_REPARSE_POINT == 0
	dst_dir := dtag.attributes & FILE_ATTRIBUTE_DIRECTORY != 0 && dtag.attributes & FILE_ATTRIBUTE_REPARSE_POINT == 0
	switch {
	case dst_dir && !src_dir:
		return .Is_Dir
	case src_dir && !dst_dir:
		return .Not_Dir
	case src_dir && dst_dir:
		return .Not_Empty
	}
	return .Permission
}

@(private)
_delete :: proc(path: string, want_dir: bool) -> Error {
	buf: WPath_Buf = ---
	p := _wpath(path, &buf) or_return
	h := win.CreateFileW(_ws(p), DELETE | SYNCHRONIZE | FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nil)
	if h == INVALID_HANDLE {
		return _last()
	}
	defer win.CloseHandle(h)
	tag: File_Attribute_Tag_Info
	if !win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) {
		return _last()
	}
	is_dir := tag.attributes & FILE_ATTRIBUTE_DIRECTORY != 0 && tag.attributes & FILE_ATTRIBUTE_REPARSE_POINT == 0
	if want_dir && !is_dir {
		return .Not_Dir
	}
	if !want_dir && is_dir {
		return .Is_Dir
	}
	flags: u32 = FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE
	if win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileDispositionInfoEx), &flags, size_of(flags)) {
		return .None
	}
	code := win.GetLastError()
	if code != ERROR_INVALID_PARAMETER && code != ERROR_NOT_SUPPORTED && code != ERROR_INVALID_FUNCTION {
		return _werror(code)
	}
	del: u8 = 1
	if !win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileDispositionInfo), &del, size_of(del)) {
		return _last()
	}
	return .None
}

@(private)
_os_unlink :: proc(data: rawptr, path: string) -> Error {
	return _delete(path, false)
}

@(private)
_os_rmdir :: proc(data: rawptr, path: string) -> Error {
	return _delete(path, true)
}

@(private)
_os_mkdir :: proc(data: rawptr, path: string, mode: u32) -> Error {
	buf: WPath_Buf = ---
	p := _wpath(path, &buf) or_return
	if !win.CreateDirectoryW(_ws(p), nil) {
		return _last()
	}
	return .None
}

@(private)
_link_target :: proc(target: string, out: []u16) -> (n: int, abs: bool, err: Error) {
	switch _path_kind(target) {
	case .Relative:
		n = _wtf8_to_wide(target, out[:len(out) - 1]) or_return
		for i in 0 ..< n {
			if out[i] == '/' {
				out[i] = '\\'
			}
		}
		out[n] = 0
		return n, false, .None
	case .Drive, .Unc, .Verbatim, .Device, .Rooted, .Drive_Relative:
		buf: WPath_Buf = ---
		p := _wpath(target, &buf) or_return
		wn := _wlen(p)
		src := p[:wn]
		if wn >= 8 && src[4] == 'U' && src[5] == 'N' && src[6] == 'C' && src[7] == '\\' {
			out[0] = '\\'
			copy(out[1:], src[7:])
			n = wn - 6
		} else {
			copy(out, src[4:])
			n = wn - 4
		}
		out[n] = 0
		return n, true, .None
	}
	return 0, false, .Invalid
}

@(private)
_os_symlink :: proc(data: rawptr, target: string, path: string) -> Error {
	lbuf: WPath_Buf = ---
	lp := _wpath(path, &lbuf) or_return
	tbuf: WPath_Buf = ---
	_, abs := _link_target(target, tbuf[:]) or_return
	flags: u32 = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
	resolved: string
	if abs {
		resolved = target
	} else {
		joined, jerr := path_join(context.temp_allocator, dir_name(path), target)
		if jerr != .None {
			return jerr
		}
		resolved = joined
	}
	rbuf: WPath_Buf = ---
	if rp, rerr := _wpath(resolved, &rbuf); rerr == .None {
		h := win.CreateFileW(_ws(rp), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
		if h != INVALID_HANDLE {
			tag: File_Attribute_Tag_Info
			if win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) && tag.attributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
				flags |= SYMBOLIC_LINK_FLAG_DIRECTORY
			}
			win.CloseHandle(h)
		}
	}
	if !bool(win.CreateSymbolicLinkW(_ws(lp), _ws(&tbuf[0]), flags)) {
		code := win.GetLastError()
		if code == ERROR_PRIVILEGE_NOT_HELD {
			return .Unsupported
		}
		return _werror(code)
	}
	return .None
}

@(private)
_os_readlink :: proc(data: rawptr, path: string, buf: []u8) -> (int, Error) {
	pbuf: WPath_Buf = ---
	p, perr := _wpath(path, &pbuf)
	if perr != .None {
		return 0, perr
	}
	h := win.CreateFileW(_ws(p), FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nil)
	if h == INVALID_HANDLE {
		return 0, _last()
	}
	defer win.CloseHandle(h)
	rp: [16 * 1024 + 16]u8 = ---
	ret: u32
	if !win.DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, nil, 0, &rp[0], size_of(rp), &ret, nil) {
		code := win.GetLastError()
		if code == ERROR_NOT_A_REPARSE_POINT {
			return 0, .Invalid
		}
		return 0, _werror(code)
	}
	if ret < 8 {
		return 0, .Invalid
	}
	tag := (^u32)(&rp[0])^
	data_len := int((^u16)(&rp[4])^)
	if 8 + data_len > int(ret) {
		return 0, .Invalid
	}
	body := rp[8:8 + data_len]
	n: int
	switch tag {
	case IO_REPARSE_TAG_LX_SYMLINK:
		if len(body) < 4 {
			return 0, .Invalid
		}
		t := body[4:]
		n = copy(buf, t)
		if len(t) >= len(buf) {
			return len(t), .Too_Large
		}
		return n, .None
	case IO_REPARSE_TAG_SYMLINK, IO_REPARSE_TAG_MOUNT_POINT:
		head := 12 if tag == IO_REPARSE_TAG_SYMLINK else 8
		if len(body) < head {
			return 0, .Invalid
		}
		sub_off := int((^u16)(&body[0])^)
		sub_len := int((^u16)(&body[2])^)
		print_off := int((^u16)(&body[4])^)
		print_len := int((^u16)(&body[6])^)
		relative := tag == IO_REPARSE_TAG_SYMLINK && (^u32)(&body[8])^ & SYMLINK_FLAG_RELATIVE != 0
		names := body[head:]
		off, ln := print_off, print_len
		if ln == 0 {
			off, ln = sub_off, sub_len
		}
		if off + ln > len(names) || ln % 2 != 0 {
			return 0, .Invalid
		}
		wide := ([^]u16)(&names[off])[:ln / 2]
		if !relative && len(wide) >= 4 && wide[0] == '\\' && wide[1] == '?' && wide[2] == '?' && wide[3] == '\\' {
			wide = wide[4:]
			if len(wide) >= 4 && wide[0] == 'U' && wide[1] == 'N' && wide[2] == 'C' && wide[3] == '\\' {
				wide = wide[2:]
				tmp: [WPATH_MAX]u16 = ---
				tmp[0] = '\\'
				copy(tmp[1:], wide[1:])
				out_n, fits := _wide_to_wtf8(tmp[:len(wide)], buf)
				return _slash_link(buf, out_n, fits)
			}
		}
		out_n, fits := _wide_to_wtf8(wide, buf)
		return _slash_link(buf, out_n, fits)
	}
	return 0, .Invalid
}

@(private)
_slash_link :: proc "contextless" (buf: []u8, n: int, fits: bool) -> (int, Error) {
	if !fits || n >= len(buf) {
		return n, .Too_Large
	}
	for i in 0 ..< n {
		if buf[i] == '\\' {
			buf[i] = '/'
		}
	}
	return n, .None
}

@(private)
_os_fchmod :: proc(data: rawptr, fd: Fd, mode: u32) -> Error {
	h := _h(fd)
	info: File_Basic_Info
	if !win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileBasicInfo), &info, size_of(info)) {
		return _last()
	}
	attrs := info.attributes
	if mode & 0o222 == 0 {
		attrs |= FILE_ATTRIBUTE_READONLY
	} else {
		attrs &~= FILE_ATTRIBUTE_READONLY
	}
	if attrs == info.attributes {
		return .None
	}
	set := File_Basic_Info {
		attributes = attrs if attrs != 0 else FILE_ATTRIBUTE_NORMAL,
	}
	if !win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileBasicInfo), &set, size_of(set)) {
		return _last()
	}
	return .None
}

@(private)
_os_set_times :: proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> Error {
	if atime_ns < 0 || mtime_ns < 0 {
		return .Invalid
	}
	buf: WPath_Buf = ---
	p := _wpath(path, &buf) or_return
	h := win.CreateFileW(_ws(p), FILE_WRITE_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == INVALID_HANDLE {
		return _last()
	}
	defer win.CloseHandle(h)
	info := File_Basic_Info {
		last_access = _ns_filetime(atime_ns),
		last_write  = _ns_filetime(mtime_ns),
	}
	if !win.SetFileInformationByHandle(h, win.FILE_INFO_BY_HANDLE_CLASS(FileBasicInfo), &info, size_of(info)) {
		return _last()
	}
	return .None
}

@(private)
DIR_BUF :: 64 * 1024

@(private)
DIR_NAME_BUF :: 1024

@(private)
_os_dir_open :: proc(data: rawptr, d: ^Dir, path: string) -> Error {
	buf: WPath_Buf = ---
	p := _wpath(path, &buf) or_return
	h := win.CreateFileW(_ws(p), FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_ALL, nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
	if h == INVALID_HANDLE {
		return _last()
	}
	tag: File_Attribute_Tag_Info
	if !win.GetFileInformationByHandleEx(h, win.FILE_INFO_BY_HANDLE_CLASS(FileAttributeTagInfo), &tag, size_of(tag)) || tag.attributes & FILE_ATTRIBUTE_DIRECTORY == 0 {
		win.CloseHandle(h)
		return .Not_Dir
	}
	if d.allocator.procedure == nil {
		d.allocator = context.allocator
	}
	b, aerr := make([]u8, DIR_BUF + DIR_NAME_BUF, d.allocator)
	if aerr != nil {
		win.CloseHandle(h)
		return .No_Memory
	}
	d.fd = _fd(h)
	d.buf = b
	d.handle = rawptr(uintptr(FileIdExtdDirectoryInfo))
	return .None
}

@(private)
_os_dir_next :: proc(data: rawptr, d: ^Dir) -> (Dir_Entry, bool, Error) {
	for {
		if d.pos >= d.len {
			if d.eof || d.fd == INVALID_FD {
				return {}, false, .None
			}
			class := int(uintptr(d.handle))
			if !win.GetFileInformationByHandleEx(_h(d.fd), win.FILE_INFO_BY_HANDLE_CLASS(class), &d.buf[0], DIR_BUF) {
				code := win.GetLastError()
				if code == ERROR_NO_MORE_FILES {
					d.eof = true
					return {}, false, .None
				}
				if code == ERROR_INVALID_PARAMETER && class == FileIdExtdDirectoryInfo {
					d.handle = rawptr(uintptr(FileIdBothDirectoryInfo))
					continue
				}
				if code == ERROR_INVALID_PARAMETER && class == FileIdBothDirectoryInfo {
					d.handle = rawptr(uintptr(FileFullDirectoryInfo))
					continue
				}
				return {}, false, _werror(code)
			}
			d.pos = 0
			d.len = DIR_BUF
		}
		rec := d.buf[d.pos:DIR_BUF]
		if len(rec) < 64 {
			d.pos = d.len
			continue
		}
		next := int((^u32)(&rec[0])^)
		if next == 0 {
			d.pos = d.len
		} else {
			if next > len(rec) {
				d.pos = d.len
				continue
			}
			d.pos += next
		}
		class := int(uintptr(d.handle))
		attrs := (^u32)(&rec[56])^
		name_len := int((^u32)(&rec[60])^)
		tag: u32
		ino: u64
		name_off: int
		switch class {
		case FileIdExtdDirectoryInfo:
			tag = (^u32)(&rec[68])^
			ino = (^u64)(&rec[72])^
			name_off = 88
		case FileIdBothDirectoryInfo:
			tag = (^u32)(&rec[64])^
			ino = (^u64)(&rec[96])^
			name_off = 104
		case:
			tag = (^u32)(&rec[64])^
			name_off = 68
		}
		if name_off + name_len > len(rec) || name_len % 2 != 0 {
			d.pos = d.len
			continue
		}
		wname := ([^]u16)(&rec[name_off])[:name_len / 2]
		if (len(wname) == 1 && wname[0] == '.') || (len(wname) == 2 && wname[0] == '.' && wname[1] == '.') || len(wname) == 0 {
			continue
		}
		out := d.buf[DIR_BUF:]
		n, ok := _wide_to_wtf8(wname, out)
		if !ok {
			continue
		}
		kind: File_Kind
		switch {
		case attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 && (tag == IO_REPARSE_TAG_SYMLINK || tag == IO_REPARSE_TAG_MOUNT_POINT || tag == IO_REPARSE_TAG_LX_SYMLINK):
			kind = .Symlink
		case attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 && tag == IO_REPARSE_TAG_AF_UNIX:
			kind = .Other
		case attrs & FILE_ATTRIBUTE_DIRECTORY != 0:
			kind = .Dir
		case:
			kind = .File
		}
		return Dir_Entry {
				name = string(out[:n]),
				ino = ino,
				kind = kind,
				has_stat = true,
				size = (^i64)(&rec[40])^ if kind == .File else 0,
				mtime_ns = _filetime_ns((^i64)(&rec[24])^),
				ctime_ns = _filetime_ns((^i64)(&rec[32])^),
			},
			true,
			.None
	}
}

@(private)
_os_dir_close :: proc(data: rawptr, d: ^Dir) {
	if d.fd != INVALID_FD {
		win.CloseHandle(_h(d.fd))
		d.fd = INVALID_FD
	}
	if d.buf != nil {
		delete(d.buf, d.allocator)
		d.buf = nil
	}
	d.pos = 0
	d.len = 0
}

@(private)
_platform_data_dir :: proc(allocator: runtime.Allocator) -> (dir: string, err: Error) {
	base, ok := _utf8_env("LOCALAPPDATA", context.temp_allocator)
	if !ok {
		base = _home() or_return
		base = path_join(context.temp_allocator, base, "AppData/Local") or_return
	}
	return path_join(allocator, _slashes(base), "0ndb")
}

@(private)
_slashes :: proc "contextless" (s: string) -> string {
	b := transmute([]u8)s
	for i in 0 ..< len(b) {
		if b[i] == '\\' {
			b[i] = '/'
		}
	}
	return s
}

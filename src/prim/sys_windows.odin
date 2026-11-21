package prim

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"
foreign import ntdll "system:ntdll.lib"

@(private)
HANDLE :: win.HANDLE

@(private)
INVALID_HANDLE :: win.INVALID_HANDLE_VALUE

@(private)
NTSTATUS :: i32

@(private)
IO_STATUS_BLOCK :: win.IO_STATUS_BLOCK

@(private)
WPATH_MAX :: PATH_MAX + 16

@(private)
WPath_Buf :: [WPATH_MAX]u16

@(private)
ERROR_INVALID_FUNCTION :: 1
@(private)
ERROR_FILE_NOT_FOUND :: 2
@(private)
ERROR_PATH_NOT_FOUND :: 3
@(private)
ERROR_TOO_MANY_OPEN_FILES :: 4
@(private)
ERROR_ACCESS_DENIED :: 5
@(private)
ERROR_INVALID_HANDLE :: 6
@(private)
ERROR_NOT_ENOUGH_MEMORY :: 8
@(private)
ERROR_INVALID_DRIVE :: 15
@(private)
ERROR_OUTOFMEMORY :: 14
@(private)
ERROR_NOT_SAME_DEVICE :: 17
@(private)
ERROR_NO_MORE_FILES :: 18
@(private)
ERROR_WRITE_PROTECT :: 19
@(private)
ERROR_NOT_READY :: 21
@(private)
ERROR_SHARING_VIOLATION :: 32
@(private)
ERROR_LOCK_VIOLATION :: 33
@(private)
ERROR_HANDLE_EOF :: 38
@(private)
ERROR_HANDLE_DISK_FULL :: 39
@(private)
ERROR_NOT_SUPPORTED :: 50
@(private)
ERROR_BAD_NETPATH :: 53
@(private)
ERROR_NETNAME_DELETED :: 64
@(private)
ERROR_FILE_EXISTS :: 80
@(private)
ERROR_CANNOT_MAKE :: 82
@(private)
ERROR_INVALID_PARAMETER :: 87
@(private)
ERROR_BROKEN_PIPE :: 109
@(private)
ERROR_DISK_FULL :: 112
@(private)
ERROR_CALL_NOT_IMPLEMENTED :: 120
@(private)
ERROR_INSUFFICIENT_BUFFER :: 122
@(private)
ERROR_INVALID_NAME :: 123
@(private)
ERROR_NEGATIVE_SEEK :: 131
@(private)
ERROR_DIR_NOT_EMPTY :: 145
@(private)
ERROR_BUSY :: 170
@(private)
ERROR_BAD_PATHNAME :: 161
@(private)
ERROR_ALREADY_EXISTS :: 183
@(private)
ERROR_BAD_EXE_FORMAT :: 193
@(private)
ERROR_FILENAME_EXCED_RANGE :: 206
@(private)
ERROR_ENVVAR_NOT_FOUND :: 203
@(private)
ERROR_NO_DATA :: 232
@(private)
ERROR_PIPE_NOT_CONNECTED :: 233
@(private)
ERROR_MORE_DATA :: 234
@(private)
ERROR_DIRECTORY :: 267
@(private)
ERROR_NOT_A_REPARSE_POINT :: 4390
@(private)
ERROR_INVALID_REPARSE_DATA :: 4392
@(private)
ERROR_OPERATION_ABORTED :: 995
@(private)
ERROR_IO_INCOMPLETE :: 996
@(private)
ERROR_IO_PENDING :: 997
@(private)
ERROR_NOACCESS :: 998
@(private)
ERROR_CANT_RESOLVE_FILENAME :: 1921
@(private)
ERROR_USER_MAPPED_FILE :: 1224
@(private)
ERROR_PRIVILEGE_NOT_HELD :: 1314
@(private)
ERROR_INVALID_INFO_CLASS :: 1302
@(private)
ERROR_DELETE_PENDING :: 303
@(private)
ERROR_STOPPED_ON_SYMLINK :: 681
@(private)
ERROR_NOT_FOUND :: 1168
@(private)
ERROR_NOT_ALL_ASSIGNED :: 1300
@(private)
WAIT_TIMEOUT :: 258
@(private)
SOL_SOCKET :: 0xffff
@(private)
SO_TYPE :: 0x1008
@(private)
WSAEWOULDBLOCK :: 10035
@(private)
WSAEINTR :: 10004
@(private)
WSAENOTSOCK :: 10038
@(private)
WSAECONNRESET :: 10054
@(private)
WSAECONNABORTED :: 10053
@(private)
WSAESHUTDOWN :: 10058
@(private)
WSAENOBUFS :: 10055
@(private)
WSAEMFILE :: 10024
@(private)
WSAEINVAL :: 10022
@(private)
WSAEACCES :: 10013
@(private)
WSAEMSGSIZE :: 10040
@(private)
WSANOTINITIALISED :: 10093

@(private)
STATUS_PENDING :: NTSTATUS(0x00000103)
@(private)
STATUS_PIPE_BROKEN :: NTSTATUS(-1073741493)
@(private)
STATUS_CANCELLED :: NTSTATUS(-1073741536)
@(private)
STATUS_ACCESS_DENIED :: NTSTATUS(-1073741790)
@(private)
STATUS_UNSUCCESSFUL :: NTSTATUS(-1073741823)
@(private)
STATUS_INVALID_INFO_CLASS :: NTSTATUS(-1073741821)
@(private)
STATUS_INVALID_PARAMETER :: NTSTATUS(-1073741811)
@(private)
STATUS_NOT_IMPLEMENTED :: NTSTATUS(-1073741822)
@(private)
STATUS_NOT_SUPPORTED :: NTSTATUS(-1073741637)
@(private)
STATUS_INVALID_DEVICE_REQUEST :: NTSTATUS(-1073741808)

@(private)
GENERIC_READ :: 0x80000000
@(private)
GENERIC_WRITE :: 0x40000000
@(private)
DELETE :: 0x00010000
@(private)
SYNCHRONIZE :: 0x00100000
@(private)
FILE_READ_DATA :: 0x0001
@(private)
FILE_LIST_DIRECTORY :: 0x0001
@(private)
FILE_WRITE_DATA :: 0x0002
@(private)
FILE_APPEND_DATA :: 0x0004
@(private)
FILE_READ_ATTRIBUTES :: 0x0080
@(private)
FILE_WRITE_ATTRIBUTES :: 0x0100
@(private)
FILE_SHARE_ALL :: 0x7

@(private)
CREATE_NEW :: 1
@(private)
CREATE_ALWAYS :: 2
@(private)
OPEN_EXISTING :: 3
@(private)
OPEN_ALWAYS :: 4
@(private)
TRUNCATE_EXISTING :: 5

@(private)
FILE_ATTRIBUTE_READONLY :: 0x1
@(private)
FILE_ATTRIBUTE_DIRECTORY :: 0x10
@(private)
FILE_ATTRIBUTE_NORMAL :: 0x80
@(private)
FILE_ATTRIBUTE_SPARSE_FILE :: 0x200
@(private)
FILE_ATTRIBUTE_REPARSE_POINT :: 0x400

@(private)
FILE_FLAG_OVERLAPPED :: 0x40000000
@(private)
FILE_FLAG_BACKUP_SEMANTICS :: 0x02000000
@(private)
FILE_FLAG_OPEN_REPARSE_POINT :: 0x00200000

@(private)
FILE_TYPE_DISK :: 1
@(private)
FILE_TYPE_CHAR :: 2
@(private)
FILE_TYPE_PIPE :: 3

@(private)
FileBasicInfo :: 0
@(private)
FileRenameInfo :: 3
@(private)
FileDispositionInfo :: 4
@(private)
FileEndOfFileInfo :: 6
@(private)
FileAttributeTagInfo :: 9
@(private)
FileIdBothDirectoryInfo :: 10
@(private)
FileFullDirectoryInfo :: 14
@(private)
FileIdExtdDirectoryInfo :: 19
@(private)
FileDispositionInfoEx :: 21
@(private)
FileRenameInfoEx :: 22

@(private)
FilePipeInformation :: 23
@(private)
FilePipeLocalInformation :: 24
@(private)
FileModeInformation :: 16
@(private)
FileStatInformation :: 68
@(private)
FileStatBasicInformation :: 77
@(private)
FileFsVolumeInformation :: 1

@(private)
FileStatBasicByNameInfo :: 3

@(private)
FILE_DISPOSITION_FLAG_DELETE :: 0x1
@(private)
FILE_DISPOSITION_FLAG_POSIX_SEMANTICS :: 0x2
@(private)
FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE :: 0x10

@(private)
FILE_RENAME_FLAG_REPLACE_IF_EXISTS :: 0x1
@(private)
FILE_RENAME_FLAG_POSIX_SEMANTICS :: 0x2
@(private)
FILE_RENAME_FLAG_IGNORE_READONLY_ATTRIBUTE :: 0x4

@(private)
FSCTL_SET_SPARSE :: 0x000900C4
@(private)
FSCTL_SET_ZERO_DATA :: 0x000980C8
@(private)
FSCTL_GET_REPARSE_POINT :: 0x000900A8

@(private)
IO_REPARSE_TAG_MOUNT_POINT :: 0xA0000003
@(private)
IO_REPARSE_TAG_SYMLINK :: 0xA000000C
@(private)
IO_REPARSE_TAG_LX_SYMLINK :: 0xA000001D
@(private)
IO_REPARSE_TAG_AF_UNIX :: 0x80000023
@(private)
SYMLINK_FLAG_RELATIVE :: 0x1

@(private)
SYMBOLIC_LINK_FLAG_DIRECTORY :: 0x1
@(private)
SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE :: 0x2

@(private)
LOCKFILE_FAIL_IMMEDIATELY :: 0x1
@(private)
LOCKFILE_EXCLUSIVE_LOCK :: 0x2

@(private)
FLUSH_FLAGS_FILE_DATA_SYNC_ONLY :: 0x4

@(private)
FILE_SYNCHRONOUS_IO_ALERT :: 0x10
@(private)
FILE_SYNCHRONOUS_IO_NONALERT :: 0x20

@(private)
FILE_PIPE_QUEUE_OPERATION :: 0
@(private)
FILE_PIPE_COMPLETE_OPERATION :: 1
@(private)
FILE_PIPE_INBOUND :: 0
@(private)
FILE_PIPE_OUTBOUND :: 1
@(private)
FILE_PIPE_FULL_DUPLEX :: 2
@(private)
FILE_PIPE_SERVER_END :: 1

@(private)
PIPE_ACCESS_INBOUND :: 0x1
@(private)
PIPE_ACCESS_DUPLEX :: 0x3
@(private)
FILE_FLAG_FIRST_PIPE_INSTANCE :: 0x00080000
@(private)
PIPE_TYPE_BYTE :: 0x0
@(private)
PIPE_READMODE_BYTE :: 0x0
@(private)
PIPE_WAIT :: 0x0
@(private)
PIPE_NOWAIT :: 0x1
@(private)
PIPE_REJECT_REMOTE_CLIENTS :: 0x8

@(private)
FILE_SKIP_COMPLETION_PORT_ON_SUCCESS :: 0x1
@(private)
FILE_SKIP_SET_EVENT_ON_HANDLE :: 0x2

@(private)
INFINITE :: 0xFFFFFFFF

@(private)
FILETIME_UNIX_OFFSET :: 116444736000000000

@(private)
Pipe_Local_Info :: struct {
	type:          u32,
	configuration: u32,
	max_instances: u32,
	cur_instances: u32,
	inbound_quota: u32,
	read_avail:    u32,
	outbound_quota: u32,
	write_quota:   u32,
	state:         u32,
	end:           u32,
}

@(private)
Pipe_Info :: struct {
	read_mode:       u32,
	completion_mode: u32,
}

@(private)
File_Stat_Info :: struct {
	file_id:      i64,
	creation:     i64,
	last_access:  i64,
	last_write:   i64,
	change:       i64,
	allocation:   i64,
	end_of_file:  i64,
	attributes:   u32,
	reparse_tag:  u32,
	links:        u32,
	access:       u32,
}

@(private)
File_Stat_Basic_Info :: struct {
	file_id:        i64,
	creation:       i64,
	last_access:    i64,
	last_write:     i64,
	change:         i64,
	allocation:     i64,
	end_of_file:    i64,
	attributes:     u32,
	reparse_tag:    u32,
	links:          u32,
	device_type:    u32,
	device_chars:   u32,
	reserved:       u32,
	volume_serial:  i64,
	file_id_128:    [16]u8,
}

@(private)
File_Basic_Info :: struct {
	creation:    i64,
	last_access: i64,
	last_write:  i64,
	change:      i64,
	attributes:  u32,
}

@(private)
File_Attribute_Tag_Info :: struct {
	attributes:  u32,
	reparse_tag: u32,
}

@(private)
Zero_Data_Info :: struct {
	offset: i64,
	beyond: i64,
}

@(private)
Proc_Get_File_Information_By_Name :: #type proc "system" (name: [^]u16, class: i32, buf: rawptr, size: u32) -> win.BOOL

@(private)
@(default_calling_convention = "system")
foreign kernel32 {
	CancelWaitableTimer :: proc(timer: HANDLE) -> win.BOOL ---
	CancelSynchronousIo :: proc(thread: HANDLE) -> win.BOOL ---
	SetNamedPipeHandleState :: proc(pipe: HANDLE, mode: ^u32, max_collection: ^u32, timeout: ^u32) -> win.BOOL ---
	CreateJobObjectW :: proc(attrs: rawptr, name: [^]u16) -> HANDLE ---
	OpenJobObjectW :: proc(access: u32, inherit: win.BOOL, name: [^]u16) -> HANDLE ---
	AssignProcessToJobObject :: proc(job: HANDLE, process: HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(job: HANDLE, code: u32) -> win.BOOL ---
	InitializeProcThreadAttributeList :: proc(list: rawptr, count: u32, flags: u32, size: ^uint) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(list: rawptr, flags: u32, attribute: uintptr, value: rawptr, size: uint, prev: rawptr, ret: ^uint) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(list: rawptr) ---
	GetConsoleProcessList :: proc(list: [^]u32, count: u32) -> u32 ---
	SetLastError :: proc(code: u32) ---
	ReOpenFile :: proc(file: HANDLE, access: u32, share: u32, flags: u32) -> HANDLE ---
}

@(private)
@(default_calling_convention = "system")
foreign ntdll {
	NtFlushBuffersFileEx :: proc(file: HANDLE, flags: u32, params: rawptr, size: u32, iosb: ^IO_STATUS_BLOCK) -> NTSTATUS ---
	NtQueryVolumeInformationFile :: proc(file: HANDLE, iosb: ^IO_STATUS_BLOCK, info: rawptr, size: u32, class: i32) -> NTSTATUS ---
	NtCreateWaitCompletionPacket :: proc(handle: ^HANDLE, access: u32, attrs: rawptr) -> NTSTATUS ---
	NtAssociateWaitCompletionPacket :: proc(packet: HANDLE, port: HANDLE, target: HANDLE, key: rawptr, apc: rawptr, status: NTSTATUS, info: uintptr, already: ^win.BOOLEAN) -> NTSTATUS ---
	NtCancelWaitCompletionPacket :: proc(packet: HANDLE, remove_signaled: win.BOOLEAN) -> NTSTATUS ---
	RtlNtStatusToDosError :: proc(status: NTSTATUS) -> u32 ---
	NtSetInformationFile :: proc(file: HANDLE, iosb: ^IO_STATUS_BLOCK, info: rawptr, size: u32, class: i32) -> NTSTATUS ---
}

@(private)
_h :: #force_inline proc "contextless" (fd: Fd) -> HANDLE {
	return HANDLE(uintptr(int(fd)))
}

@(private)
_fd :: #force_inline proc "contextless" (h: HANDLE) -> Fd {
	return Fd(i32(int(uintptr(h))))
}

@(private)
_last :: #force_inline proc "contextless" () -> Error {
	return _werror(win.GetLastError())
}

@(private)
_werror :: proc "contextless" (code: u32) -> Error {
	switch code {
	case 0:
		return .None
	case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_DRIVE, ERROR_BAD_NETPATH, ERROR_NOT_FOUND, ERROR_NOT_READY:
		return .Not_Found
	case ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS:
		return .Exists
	case ERROR_ACCESS_DENIED, ERROR_WRITE_PROTECT, ERROR_DELETE_PENDING, WSAEACCES, ERROR_NOT_ALL_ASSIGNED:
		return .Permission
	case WSAEWOULDBLOCK:
		return .Would_Block
	case WSAEINTR, ERROR_OPERATION_ABORTED:
		return .Interrupted
	case ERROR_BROKEN_PIPE, ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED, WSAECONNRESET, WSAECONNABORTED, WSAESHUTDOWN, ERROR_NETNAME_DELETED:
		return .Broken_Pipe
	case ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION, ERROR_BUSY, ERROR_USER_MAPPED_FILE:
		return .Busy
	case ERROR_INVALID_HANDLE, ERROR_INVALID_PARAMETER, ERROR_INVALID_NAME, ERROR_BAD_PATHNAME, ERROR_NEGATIVE_SEEK, ERROR_NOT_A_REPARSE_POINT, ERROR_INVALID_REPARSE_DATA, WSAENOTSOCK, WSAEINVAL, ERROR_NOACCESS:
		return .Invalid
	case ERROR_DIRECTORY:
		return .Not_Dir
	case ERROR_DIR_NOT_EMPTY:
		return .Not_Empty
	case ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL:
		return .No_Space
	case ERROR_TOO_MANY_OPEN_FILES, WSAEMFILE:
		return .Too_Many_Files
	case ERROR_FILENAME_EXCED_RANGE, ERROR_CANT_RESOLVE_FILENAME:
		return .Name_Too_Long
	case ERROR_MORE_DATA, ERROR_INSUFFICIENT_BUFFER, WSAEMSGSIZE:
		return .Too_Large
	case ERROR_INVALID_FUNCTION, ERROR_NOT_SUPPORTED, ERROR_CALL_NOT_IMPLEMENTED, ERROR_NOT_SAME_DEVICE, ERROR_PRIVILEGE_NOT_HELD, ERROR_INVALID_INFO_CLASS:
		return .Unsupported
	case ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY, WSAENOBUFS:
		return .No_Memory
	}
	return .Io
}

@(private)
_nterror :: proc "contextless" (st: NTSTATUS) -> Error {
	if st >= 0 {
		return .None
	}
	return _werror(RtlNtStatusToDosError(st))
}

@(private)
_filetime_ns :: #force_inline proc "contextless" (ft: i64) -> i64 {
	return (ft - FILETIME_UNIX_OFFSET) * 100
}

@(private)
_ns_filetime :: #force_inline proc "contextless" (ns: i64) -> i64 {
	return ns / 100 + FILETIME_UNIX_OFFSET
}

@(private)
_is_sep :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == '/' || c == '\\'
}

@(private)
_wtf8_to_wide :: proc "contextless" (s: string, out: []u16) -> (n: int, err: Error) {
	i := 0
	for i < len(s) {
		c := u32(s[i])
		cp: u32
		size: int
		switch {
		case c < 0x80:
			cp, size = c, 1
		case c & 0xE0 == 0xC0:
			if i + 1 >= len(s) || s[i + 1] & 0xC0 != 0x80 {
				return 0, .Invalid
			}
			cp, size = (c & 0x1F) << 6 | u32(s[i + 1] & 0x3F), 2
			if cp < 0x80 {
				return 0, .Invalid
			}
		case c & 0xF0 == 0xE0:
			if i + 2 >= len(s) || s[i + 1] & 0xC0 != 0x80 || s[i + 2] & 0xC0 != 0x80 {
				return 0, .Invalid
			}
			cp, size = (c & 0x0F) << 12 | u32(s[i + 1] & 0x3F) << 6 | u32(s[i + 2] & 0x3F), 3
			if cp < 0x800 {
				return 0, .Invalid
			}
		case c & 0xF8 == 0xF0:
			if i + 3 >= len(s) || s[i + 1] & 0xC0 != 0x80 || s[i + 2] & 0xC0 != 0x80 || s[i + 3] & 0xC0 != 0x80 {
				return 0, .Invalid
			}
			cp, size = (c & 0x07) << 18 | u32(s[i + 1] & 0x3F) << 12 | u32(s[i + 2] & 0x3F) << 6 | u32(s[i + 3] & 0x3F), 4
			if cp < 0x10000 || cp > 0x10FFFF {
				return 0, .Invalid
			}
		case:
			return 0, .Invalid
		}
		if cp == 0 {
			return 0, .Invalid
		}
		if cp >= 0x10000 {
			if n + 2 > len(out) {
				return 0, .Name_Too_Long
			}
			v := cp - 0x10000
			out[n] = u16(0xD800 + (v >> 10))
			out[n + 1] = u16(0xDC00 + (v & 0x3FF))
			n += 2
		} else {
			if n + 1 > len(out) {
				return 0, .Name_Too_Long
			}
			out[n] = u16(cp)
			n += 1
		}
		i += size
	}
	return n, .None
}

@(private)
_wide_to_wtf8 :: proc "contextless" (w: []u16, out: []u8) -> (n: int, ok: bool) {
	i := 0
	for i < len(w) {
		cp := u32(w[i])
		i += 1
		if cp >= 0xD800 && cp < 0xDC00 && i < len(w) && w[i] >= 0xDC00 && w[i] < 0xE000 {
			cp = 0x10000 + ((cp - 0xD800) << 10) + (u32(w[i]) - 0xDC00)
			i += 1
		}
		switch {
		case cp < 0x80:
			if n + 1 > len(out) {
				return n, false
			}
			out[n] = u8(cp)
			n += 1
		case cp < 0x800:
			if n + 2 > len(out) {
				return n, false
			}
			out[n] = u8(0xC0 | cp >> 6)
			out[n + 1] = u8(0x80 | cp & 0x3F)
			n += 2
		case cp < 0x10000:
			if n + 3 > len(out) {
				return n, false
			}
			out[n] = u8(0xE0 | cp >> 12)
			out[n + 1] = u8(0x80 | (cp >> 6) & 0x3F)
			out[n + 2] = u8(0x80 | cp & 0x3F)
			n += 3
		case:
			if n + 4 > len(out) {
				return n, false
			}
			out[n] = u8(0xF0 | cp >> 18)
			out[n + 1] = u8(0x80 | (cp >> 12) & 0x3F)
			out[n + 2] = u8(0x80 | (cp >> 6) & 0x3F)
			out[n + 3] = u8(0x80 | cp & 0x3F)
			n += 4
		}
	}
	return n, true
}

@(private)
_wstr :: proc "contextless" (s: string, buf: []u16) -> ([^]u16, Error) {
	n, err := _wtf8_to_wide(s, buf[:len(buf) - 1])
	if err != .None {
		return nil, err
	}
	buf[n] = 0
	return raw_data(buf), .None
}

@(private)
_ws :: #force_inline proc "contextless" (p: [^]u16) -> win.wstring {
	return win.wstring(p)
}

@(private)
_wlen :: proc "contextless" (w: [^]u16) -> int {
	n := 0
	for w[n] != 0 {
		n += 1
	}
	return n
}

@(private)
_Path_Kind :: enum u8 {
	Relative,
	Drive_Relative,
	Rooted,
	Drive,
	Unc,
	Verbatim,
	Device,
}

@(private)
_path_kind :: proc "contextless" (p: string) -> _Path_Kind {
	if len(p) >= 4 && _is_sep(p[0]) && _is_sep(p[1]) && (p[2] == '?' || p[2] == '.') && _is_sep(p[3]) {
		return .Verbatim if p[2] == '?' else .Device
	}
	if len(p) >= 2 && _is_sep(p[0]) && _is_sep(p[1]) {
		return .Unc
	}
	if len(p) >= 2 && p[1] == ':' && ((p[0] >= 'A' && p[0] <= 'Z') || (p[0] >= 'a' && p[0] <= 'z')) {
		if len(p) == 2 || _is_sep(p[2]) {
			return .Drive
		}
		return .Drive_Relative
	}
	if len(p) >= 1 && _is_sep(p[0]) {
		return .Rooted
	}
	return .Relative
}

@(private)
_is_abs_windows :: proc "contextless" (p: string) -> bool {
	#partial switch _path_kind(p) {
	case .Drive, .Unc, .Verbatim, .Device:
		return true
	}
	return false
}

@(private)
_wpath_push :: proc "contextless" (out: []u16, n: ^int, root: int, comp: []u16) -> Error {
	if len(comp) == 0 || (len(comp) == 1 && comp[0] == '.') {
		return .None
	}
	if len(comp) == 2 && comp[0] == '.' && comp[1] == '.' {
		j := n^
		for j > root && out[j - 1] != '\\' {
			j -= 1
		}
		if j > root {
			j -= 1
		}
		n^ = max(j, root)
		return .None
	}
	need := len(comp) + (1 if out[n^ - 1] != '\\' else 0)
	if n^ + need >= len(out) {
		return .Name_Too_Long
	}
	if out[n^ - 1] != '\\' {
		out[n^] = '\\'
		n^ += 1
	}
	copy(out[n^:], comp)
	n^ += len(comp)
	return .None
}

@(private)
_wpath_append :: proc "contextless" (out: []u16, n: ^int, root: int, src: []u16) -> Error {
	i := 0
	for i < len(src) {
		for i < len(src) && (src[i] == '/' || src[i] == '\\') {
			i += 1
		}
		j := i
		for j < len(src) && src[j] != '/' && src[j] != '\\' {
			j += 1
		}
		if j > i {
			if err := _wpath_push(out, n, root, src[i:j]); err != .None {
				return err
			}
		}
		i = j
	}
	return .None
}

@(private)
_wpath :: proc "contextless" (path: string, buf: ^WPath_Buf, nt := false) -> ([^]u16, Error) {
	if len(path) == 0 {
		return nil, .Not_Found
	}
	if len(path) >= PATH_MAX {
		return nil, .Name_Too_Long
	}
	tmp: [WPATH_MAX]u16 = ---
	tn, terr := _wtf8_to_wide(path, tmp[:PATH_MAX])
	if terr != .None {
		return nil, terr
	}
	src := tmp[:tn]
	out := buf[:]
	kind := _path_kind(path)
	if kind == .Verbatim || kind == .Device {
		if tn + 1 >= len(out) {
			return nil, .Name_Too_Long
		}
		copy(out, src)
		out[0], out[1], out[3] = '\\', '\\', '\\'
		if nt {
			out[1] = '?'
			out[2] = '?'
		}
		out[tn] = 0
		return raw_data(out), .None
	}
	out[0], out[1], out[2], out[3] = '\\', '?' if nt else '\\', '?', '\\'
	n := 4
	root := 0
	switch kind {
	case .Drive:
		out[4] = src[0] & ~u16(0x20) if src[0] >= 'a' && src[0] <= 'z' else src[0]
		out[5] = ':'
		out[6] = '\\'
		n = 7
		root = 7
		if err := _wpath_append(out, &n, root, src[2:]); err != .None {
			return nil, err
		}
	case .Unc:
		out[4], out[5], out[6], out[7] = 'U', 'N', 'C', '\\'
		n = 8
		i := 2
		parts := 0
		for parts < 2 && i < tn {
			for i < tn && (src[i] == '/' || src[i] == '\\') {
				i += 1
			}
			j := i
			for j < tn && src[j] != '/' && src[j] != '\\' {
				j += 1
			}
			if j == i {
				break
			}
			if n + (j - i) + 1 >= len(out) {
				return nil, .Name_Too_Long
			}
			if parts > 0 {
				out[n] = '\\'
				n += 1
			}
			copy(out[n:], src[i:j])
			n += j - i
			parts += 1
			i = j
		}
		if parts < 2 {
			return nil, .Invalid
		}
		out[n] = '\\'
		n += 1
		root = n
		if err := _wpath_append(out, &n, root, src[i:]); err != .None {
			return nil, err
		}
	case .Rooted, .Relative, .Drive_Relative:
		cwd: [WPATH_MAX]u16 = ---
		cn: int
		if kind == .Drive_Relative {
			drive := [4]u16{src[0], ':', 0, 0}
			cn = int(win.GetFullPathNameW(_ws(&drive[0]), u32(len(cwd)), _ws(&cwd[0]), nil))
			src = src[2:]
		} else {
			cn = int(win.GetCurrentDirectoryW(u32(len(cwd)), &cwd[0]))
		}
		if cn == 0 || cn >= len(cwd) {
			return nil, .Name_Too_Long
		}
		base := cwd[:cn]
		bkind: _Path_Kind
		if cn >= 4 && base[0] == '\\' && base[1] == '\\' && base[2] == '?' && base[3] == '\\' {
			base = base[4:]
			if len(base) >= 4 && base[0] == 'U' && base[1] == 'N' && base[2] == 'C' && base[3] == '\\' {
				base = base[2:]
				base[0] = '\\'
				bkind = .Unc
			} else {
				bkind = .Drive
			}
		} else if len(base) >= 2 && base[0] == '\\' && base[1] == '\\' {
			bkind = .Unc
		} else {
			bkind = .Drive
		}
		if bkind == .Drive {
			if len(base) < 2 {
				return nil, .Invalid
			}
			out[4] = base[0]
			out[5] = ':'
			out[6] = '\\'
			n = 7
			root = 7
			if kind != .Rooted {
				if err := _wpath_append(out, &n, root, base[2:]); err != .None {
					return nil, err
				}
			}
		} else {
			out[4], out[5], out[6], out[7] = 'U', 'N', 'C', '\\'
			n = 8
			i := 2
			parts := 0
			for parts < 2 && i < len(base) {
				j := i
				for j < len(base) && base[j] != '\\' {
					j += 1
				}
				if n + (j - i) + 1 >= len(out) {
					return nil, .Name_Too_Long
				}
				if parts > 0 {
					out[n] = '\\'
					n += 1
				}
				copy(out[n:], base[i:j])
				n += j - i
				parts += 1
				i = j + 1
			}
			out[n] = '\\'
			n += 1
			root = n
			if kind != .Rooted && i < len(base) {
				if err := _wpath_append(out, &n, root, base[i:]); err != .None {
					return nil, err
				}
			}
		}
		if err := _wpath_append(out, &n, root, src); err != .None {
			return nil, err
		}
	case .Verbatim, .Device:
	}
	if n >= len(out) {
		return nil, .Name_Too_Long
	}
	out[n] = 0
	return raw_data(out), .None
}

@(private)
_utf8_env :: proc(key: string, allocator := context.temp_allocator) -> (string, bool) {
	kbuf: [256]u16
	k, kerr := _wstr(key, kbuf[:])
	if kerr != .None {
		return "", false
	}
	stack: [1024]u16
	n := win.GetEnvironmentVariableW(_ws(k), &stack[0], u32(len(stack)))
	if n == 0 {
		return "", false
	}
	w := stack[:]
	if int(n) >= len(stack) {
		big, err := make([]u16, int(n), context.temp_allocator)
		if err != nil {
			return "", false
		}
		n = win.GetEnvironmentVariableW(_ws(k), raw_data(big), u32(len(big)))
		if n == 0 || int(n) >= len(big) {
			return "", false
		}
		w = big
	}
	out, aerr := make([]u8, int(n) * 3, allocator)
	if aerr != nil {
		return "", false
	}
	m, _ := _wide_to_wtf8(w[:n], out)
	return string(out[:m]), m > 0
}

@(private)
_root_len_windows :: proc "contextless" (p: string) -> int {
	switch _path_kind(p) {
	case .Drive:
		return min(len(p), 3)
	case .Rooted:
		return 1
	case .Drive_Relative:
		return 2
	case .Unc, .Verbatim, .Device:
		start := 2 if _path_kind(p) == .Unc else 4
		parts := 2
		if _path_kind(p) != .Unc && len(p) >= 6 && p[5] == ':' {
			return min(len(p), 7)
		}
		if _path_kind(p) == .Verbatim && len(p) >= 8 && (p[4] == 'U' || p[4] == 'u') && (p[5] == 'N' || p[5] == 'n') && (p[6] == 'C' || p[6] == 'c') && _is_sep(p[7]) {
			start = 8
		} else if _path_kind(p) != .Unc {
			parts = 1
		}
		i := start
		for parts > 0 && i < len(p) {
			for i < len(p) && !_is_sep(p[i]) {
				i += 1
			}
			parts -= 1
			if i < len(p) {
				i += 1
			}
		}
		return i
	case .Relative:
	}
	return 0
}

@(private)
_dir_name_windows :: proc "contextless" (path: string) -> string {
	root := _root_len_windows(path)
	end := len(path)
	for end > root && _is_sep(path[end - 1]) {
		end -= 1
	}
	for i := end - 1; i >= root; i -= 1 {
		if _is_sep(path[i]) {
			j := i
			for j > root && _is_sep(path[j - 1]) {
				j -= 1
			}
			if j <= root {
				return path[:root] if root > 0 else "."
			}
			return path[:j]
		}
	}
	if root > 0 {
		if root == 2 && _path_kind(path) == .Drive_Relative {
			return path[:2]
		}
		return path[:root]
	}
	return "."
}

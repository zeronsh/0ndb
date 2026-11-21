package fs

import win "core:sys/windows"
import "../prim"

foreign import ntdll_fs "system:ntdll.lib"

@(private)
@(default_calling_convention = "system")
foreign ntdll_fs {
	NtQueryDirectoryFile :: proc(file: win.HANDLE, event: win.HANDLE, apc: rawptr, apc_ctx: rawptr, iosb: ^win.IO_STATUS_BLOCK, info: rawptr, size: u32, class: i32, single: win.BOOLEAN, name: ^win.UNICODE_STRING, restart: win.BOOLEAN) -> i32 ---
	NtQueryInformationFile :: proc(file: win.HANDLE, iosb: ^win.IO_STATUS_BLOCK, info: rawptr, size: u32, class: i32) -> i32 ---
	NtQueryVolumeInformationFile :: proc(file: win.HANDLE, iosb: ^win.IO_STATUS_BLOCK, info: rawptr, size: u32, class: i32) -> i32 ---
	NtReadFile :: proc(file: win.HANDLE, event: win.HANDLE, apc: rawptr, apc_ctx: rawptr, iosb: ^win.IO_STATUS_BLOCK, buf: rawptr, size: u32, offset: ^i64, key: ^u32) -> i32 ---
}

@(private)
NT_FILE_LIST_DIRECTORY :: 0x0001
@(private)
NT_FILE_READ_DATA :: 0x0001
@(private)
NT_FILE_READ_ATTRIBUTES :: 0x0080
@(private)
NT_SYNCHRONIZE :: 0x0010_0000
@(private)
NT_SHARE_ALL :: 0x7
@(private)
NT_FILE_OPEN :: 1
@(private)
NT_FILE_DIRECTORY_FILE :: 0x0000_0001
@(private)
NT_FILE_SEQUENTIAL_ONLY :: 0x0000_0004
@(private)
NT_FILE_SYNCHRONOUS_IO_NONALERT :: 0x0000_0020
@(private)
NT_FILE_NON_DIRECTORY_FILE :: 0x0000_0040
@(private)
NT_FILE_OPEN_FOR_BACKUP_INTENT :: 0x0000_4000
@(private)
NT_FILE_OPEN_REPARSE_POINT :: 0x0020_0000
@(private)
NT_OBJ_CASE_INSENSITIVE :: 0x40

@(private)
NT_CLASS_FULL_DIR :: 2
@(private)
NT_CLASS_ID_FULL_DIR :: 38
@(private)
NT_CLASS_ID_EXTD_DIR :: 60
@(private)
NT_CLASS_CASE_SENSITIVE :: 71
@(private)
NT_FS_ATTRIBUTE_INFO :: 5

@(private)
STATUS_NO_MORE_FILES :: i32(-2147483642)
@(private)
STATUS_BUFFER_OVERFLOW :: i32(-2147483643)
@(private)
STATUS_NOTIFY_ENUM_DIR :: u32(0x10C)

@(private)
ATTR_READONLY :: u32(0x1)
@(private)
ATTR_DIRECTORY :: u32(0x10)
@(private)
ATTR_REPARSE :: u32(0x400)
@(private)
TAG_MOUNT_POINT :: u32(0xA0000003)
@(private)
TAG_SYMLINK :: u32(0xA000000C)
@(private)
TAG_LX_SYMLINK :: u32(0xA000001D)
@(private)
TAG_AF_UNIX :: u32(0x80000023)
@(private)
FILETIME_EPOCH :: i64(116444736000000000)

@(private)
nt_error :: proc "contextless" (st: i32) -> Error {
	switch u32(st) {
	case 0xC0000034, 0xC000003A, 0xC000000F, 0xC0000056:
		return .Not_Found
	case 0xC0000103:
		return .Not_Dir
	case 0xC00000BA:
		return .Is_Dir
	case 0xC0000022, 0xC0000043:
		return .Permission
	case 0xC0000033, 0xC000003B, 0xC000000D, 0xC0000003:
		return .Invalid
	case 0xC00000BB, 0xC0000002:
		return .Unsupported
	case 0xC000009A, 0xC0000017:
		return .No_Memory
	case 0xC000007F:
		return .No_Space
	case 0xC0000106:
		return .Name_Too_Long
	}
	return .Io
}

@(private)
win_error :: proc "contextless" (code: u32) -> Error {
	switch code {
	case 2, 3, 15:
		return .Not_Found
	case 5, 32, 33:
		return .Permission
	case 80, 183:
		return .Exists
	case 267:
		return .Not_Dir
	case 87, 123:
		return .Invalid
	case 50, 1, 120:
		return .Unsupported
	case 8, 14:
		return .No_Memory
	case 39, 112:
		return .No_Space
	case 206:
		return .Name_Too_Long
	}
	return .Io
}

@(private)
fd_handle :: #force_inline proc "contextless" (fd: prim.Fd) -> win.HANDLE {
	return win.HANDLE(uintptr(int(fd)))
}

@(private)
wtf8_to_wide :: proc "contextless" (s: string, out: []u16, slashes: bool) -> (n: int, ok: bool) {
	i := 0
	for i < len(s) {
		c := u32(s[i])
		cp: u32
		size: int
		switch {
		case c < 0x80:
			cp, size = c, 1
		case c & 0xE0 == 0xC0 && i + 1 < len(s):
			cp, size = (c & 0x1F) << 6 | u32(s[i + 1] & 0x3F), 2
		case c & 0xF0 == 0xE0 && i + 2 < len(s):
			cp, size = (c & 0x0F) << 12 | u32(s[i + 1] & 0x3F) << 6 | u32(s[i + 2] & 0x3F), 3
		case c & 0xF8 == 0xF0 && i + 3 < len(s):
			cp, size = (c & 0x07) << 18 | u32(s[i + 1] & 0x3F) << 12 | u32(s[i + 2] & 0x3F) << 6 | u32(s[i + 3] & 0x3F), 4
		case:
			return 0, false
		}
		for k in 1 ..< size {
			if s[i + k] & 0xC0 != 0x80 {
				return 0, false
			}
		}
		if cp == 0 {
			return 0, false
		}
		if slashes && cp == '/' {
			cp = '\\'
		}
		if cp >= 0x10000 {
			if n + 2 > len(out) {
				return 0, false
			}
			v := cp - 0x10000
			out[n] = u16(0xD800 + (v >> 10))
			out[n + 1] = u16(0xDC00 + (v & 0x3FF))
			n += 2
		} else {
			if n + 1 > len(out) {
				return 0, false
			}
			out[n] = u16(cp)
			n += 1
		}
		i += size
	}
	return n, true
}

@(private)
wide_to_wtf8 :: proc "contextless" (w: []u16, out: []u8, slashes: bool) -> (n: int, ok: bool) {
	i := 0
	for i < len(w) {
		cp := u32(w[i])
		i += 1
		if cp >= 0xD800 && cp < 0xDC00 && i < len(w) && w[i] >= 0xDC00 && w[i] < 0xE000 {
			cp = 0x10000 + ((cp - 0xD800) << 10) + (u32(w[i]) - 0xDC00)
			i += 1
		}
		if slashes && cp == '\\' {
			cp = '/'
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
nt_open_rel :: proc "contextless" (dir: win.HANDLE, rel: string, access: u32, options: u32) -> (win.HANDLE, Error) {
	wbuf: [prim.PATH_MAX]u16 = ---
	n, ok := wtf8_to_wide(rel, wbuf[:], true)
	if !ok {
		return nil, .Name_Too_Long if len(rel) > 0 else .Invalid
	}
	if n * 2 > 0xFFF0 {
		return nil, .Name_Too_Long
	}
	name := win.UNICODE_STRING {
		Length        = u16(n * 2),
		MaximumLength = u16(n * 2),
		Buffer        = &wbuf[0],
	}
	attrs := win.OBJECT_ATTRIBUTES {
		Length        = size_of(win.OBJECT_ATTRIBUTES),
		RootDirectory = dir,
		ObjectName    = &name,
	}
	iosb: win.IO_STATUS_BLOCK
	h: win.HANDLE
	st := win.NtCreateFile(&h, access, &attrs, &iosb, nil, 0, NT_SHARE_ALL, NT_FILE_OPEN, options | NT_FILE_OPEN_FOR_BACKUP_INTENT, nil, 0)
	if st < 0 {
		return nil, nt_error(i32(st))
	}
	return h, .None
}

@(private)
nt_stat :: proc "contextless" (attrs: u32, tag: u32, size: i64, id: u64, write: i64, change: i64) -> (Disk_Kind, Stat) {
	kind: Disk_Kind
	mode: u32
	switch {
	case attrs & ATTR_REPARSE != 0 && (tag == TAG_SYMLINK || tag == TAG_MOUNT_POINT || tag == TAG_LX_SYMLINK):
		kind = .Symlink
		mode = 0o120777
	case attrs & ATTR_REPARSE != 0 && tag == TAG_AF_UNIX:
		kind = .Other
		mode = 0o140777
	case attrs & ATTR_DIRECTORY != 0:
		kind = .Dir
		mode = 0o040755
	case:
		kind = .File
		mode = 0o100444 if attrs & ATTR_READONLY != 0 else 0o100644
	}
	return kind, Stat {
		mtime_ns = (write - FILETIME_EPOCH) * 100,
		ctime_ns = (change - FILETIME_EPOCH) * 100,
		size = size if kind == .File || kind == .Other else 0,
		ino = id,
		mode = mode,
	}
}

@(private)
Nt_Dir_Entry :: struct {
	wname: []u16,
	attrs: u32,
	tag:   u32,
	id:    u64,
	size:  i64,
	write: i64,
	change: i64,
}

@(private)
nt_dir_record :: proc "contextless" (class: i32, rec: []u8) -> (e: Nt_Dir_Entry, ok: bool) {
	if len(rec) < 68 {
		return
	}
	e.write = (^i64)(&rec[24])^
	e.change = (^i64)(&rec[32])^
	e.size = (^i64)(&rec[40])^
	e.attrs = (^u32)(&rec[56])^
	name_len := int((^u32)(&rec[60])^)
	name_off: int
	switch class {
	case NT_CLASS_ID_EXTD_DIR:
		if len(rec) < 88 {
			return
		}
		e.tag = (^u32)(&rec[68])^
		e.id = (^u64)(&rec[72])^
		name_off = 88
	case NT_CLASS_ID_FULL_DIR:
		if len(rec) < 80 {
			return
		}
		e.tag = (^u32)(&rec[64])^
		e.id = (^u64)(&rec[72])^
		name_off = 80
	case:
		e.tag = (^u32)(&rec[64])^
		name_off = 68
	}
	if e.attrs & ATTR_REPARSE == 0 {
		e.tag = 0
	}
	if name_len % 2 != 0 || name_off + name_len > len(rec) {
		return
	}
	e.wname = ([^]u16)(&rec[name_off])[:name_len / 2]
	return e, true
}

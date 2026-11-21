package fs

import win "core:sys/windows"
import "../prim"

foreign import kernel32_clone "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32_clone {
	GetVolumePathNameW :: proc(name: cstring16, out: [^]u16, size: u32) -> win.BOOL ---
	GetVolumeInformationW :: proc(root: cstring16, name: [^]u16, name_size: u32, serial: ^u32, max_component: ^u32, flags: ^u32, fs_name: [^]u16, fs_name_size: u32) -> win.BOOL ---
}

@(private)
FILE_SUPPORTS_BLOCK_REFCOUNTING :: u32(0x0800_0000)
@(private)
FSCTL_DUPLICATE_EXTENTS_TO_FILE :: u32(0x0009_8344)
@(private)
FSCTL_SET_SPARSE :: u32(0x0009_00C4)
@(private)
ATTR_SPARSE :: u32(0x200)
@(private)
CLONE_CHUNK :: i64(1 << 30)
@(private)
COPY_UNBUFFERED_MIN :: i64(256 << 20)

@(private)
Duplicate_Extents :: struct {
	file:       win.HANDLE,
	src_offset: i64,
	dst_offset: i64,
	count:      i64,
}

@(private)
Fs_Size_Info :: struct {
	total:             i64,
	available:         i64,
	sectors_per_unit:  u32,
	bytes_per_sector:  u32,
}

clone_file :: proc(vfs: prim.Vfs, src, dst: string, mode: u32) -> Error {
	if vfs.procs != prim.os_vfs().procs {
		return copy_file_vfs(vfs, src, dst, mode)
	}
	sw, dw: [prim.PATH_MAX + 8]u16
	if !abs_wide(src, sw[:]) || !abs_wide(dst, dw[:]) {
		return copy_file_vfs(vfs, src, dst, mode)
	}
	info: win.WIN32_FILE_ATTRIBUTE_DATA
	if !win.GetFileAttributesExW(cstring16(&sw[0]), win.GetFileExInfoStandard, &info) {
		return copy_file_vfs(vfs, src, dst, mode)
	}
	if volume_block_clone(sw[:]) {
		if in_fd, ierr := prim.open_file(vfs, src); ierr == .None {
			cloned := block_clone(vfs, in_fd, dst, mode)
			prim.close_file(vfs, in_fd)
			if cloned {
				return .None
			}
		}
	}
	size := i64(info.nFileSizeHigh) << 32 | i64(info.nFileSizeLow)
	flags: u32 = win.COPY_FILE_NO_BUFFERING if size >= COPY_UNBUFFERED_MIN else 0
	if win.CopyFileExW(cstring16(&sw[0]), cstring16(&dw[0]), nil, nil, nil, flags) {
		if (info.dwFileAttributes & ATTR_READONLY != 0) != (mode & 0o222 == 0) {
			win.SetFileAttributesW(cstring16(&dw[0]), info.dwFileAttributes ~ ATTR_READONLY)
		}
		return .None
	}
	return copy_file_vfs(vfs, src, dst, mode)
}

@(private)
@(thread_local)
clone_vol_key: u64

@(private)
@(thread_local)
clone_vol_ok: bool

@(private)
volume_block_clone :: proc(path: []u16) -> bool {
	parent := 0
	for i := 0; i < len(path) && path[i] != 0; i += 1 {
		if path[i] == '\\' {
			parent = i
		}
	}
	key := u64(14695981039346656037)
	for c in path[:parent] {
		key = (key ~ u64(c)) * 1099511628211
	}
	key |= 1
	if key == clone_vol_key {
		return clone_vol_ok
	}
	ok := false
	root: [prim.PATH_MAX + 8]u16
	flags: u32
	if GetVolumePathNameW(cstring16(&path[0]), &root[0], u32(len(root))) && GetVolumeInformationW(cstring16(&root[0]), nil, 0, nil, nil, &flags, nil, 0) {
		ok = flags & FILE_SUPPORTS_BLOCK_REFCOUNTING != 0
	}
	clone_vol_key = key
	clone_vol_ok = ok
	return ok
}

@(private)
block_clone :: proc(vfs: prim.Vfs, in_fd: prim.Fd, dst: string, mode: u32) -> bool {
	hin := fd_handle(in_fd)
	iosb: win.IO_STATUS_BLOCK
	attr: [64]u8
	if qs := NtQueryVolumeInformationFile(hin, &iosb, &attr[0], size_of(attr), NT_FS_ATTRIBUTE_INFO); qs < 0 && qs != STATUS_BUFFER_OVERFLOW {
		return false
	}
	if (^u32)(&attr[0])^ & FILE_SUPPORTS_BLOCK_REFCOUNTING == 0 {
		return false
	}
	fsz: Fs_Size_Info
	if NtQueryVolumeInformationFile(hin, &iosb, &fsz, size_of(fsz), 3) < 0 {
		return false
	}
	cluster := i64(fsz.sectors_per_unit) * i64(fsz.bytes_per_sector)
	if cluster <= 0 {
		return false
	}
	basic: win.FILE_BASIC_INFO
	if !win.GetFileInformationByHandleEx(hin, .FileBasicInfo, &basic, size_of(basic)) {
		return false
	}
	st, serr := prim.fstat(vfs, in_fd)
	if serr != .None {
		return false
	}
	out_fd, oerr := prim.open_file(vfs, dst, {.Write, .Create, .Truncate}, mode & 0o7777)
	if oerr != .None {
		return false
	}
	hout := fd_handle(out_fd)
	ok := false
	defer if !ok {
		prim.close_file(vfs, out_fd)
		prim.remove(vfs, dst)
	}
	ret: u32
	if basic.FileAttributes & ATTR_SPARSE != 0 {
		if !win.DeviceIoControl(hout, FSCTL_SET_SPARSE, nil, 0, nil, 0, &ret, nil) {
			return false
		}
	}
	eof := win.FILE_END_OF_FILE_INFO{EndOfFile = win.LARGE_INTEGER(st.size)}
	if !win.SetFileInformationByHandle(hout, .FileEndOfFileInfo, &eof, size_of(eof)) {
		return false
	}
	total := (st.size + cluster - 1) / cluster * cluster
	off: i64
	for off < total {
		n := min(CLONE_CHUNK, total - off)
		d := Duplicate_Extents{hin, off, off, n}
		if !win.DeviceIoControl(hout, FSCTL_DUPLICATE_EXTENTS_TO_FILE, &d, size_of(d), nil, 0, &ret, nil) {
			return false
		}
		off += n
	}
	prim.fchmod(vfs, out_fd, mode & 0o7777)
	prim.close_file(vfs, out_fd)
	ok = true
	return true
}

@(private)
abs_wide :: proc(p: string, out: []u16) -> bool {
	if len(p) < 3 || p[1] != ':' || (p[2] != '/' && p[2] != '\\') {
		return false
	}
	prefix := [4]u16{'\\', '\\', '?', '\\'}
	copy(out, prefix[:])
	n, ok := wtf8_to_wide(p, out[4:len(out) - 1], true)
	if !ok {
		return false
	}
	out[4 + n] = 0
	return true
}

@(private)
HAS_SYNCFS :: false

@(private)
os_syncfs :: proc(fd: prim.Fd) -> bool {
	return false
}

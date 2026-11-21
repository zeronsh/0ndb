package fs

import "core:c"
import "../prim"

foreign import libsystem_attr "system:System"

@(private)
Attr_List :: struct {
	bitmapcount: u16,
	reserved:    u16,
	commonattr:  u32,
	volattr:     u32,
	dirattr:     u32,
	fileattr:    u32,
	forkattr:    u32,
}

@(private)
ATTR_BIT_MAP_COUNT :: 5
@(private)
ATTR_CMN_NAME :: u32(0x1)
@(private)
FSOPT_NOFOLLOW :: c.uint(0x1)

@(private)
foreign libsystem_attr {
	getattrlist :: proc(path: cstring, list: ^Attr_List, buf: rawptr, size: c.size_t, options: c.uint) -> c.int ---
}

@(private)
disk_name_matches :: proc(vfs: prim.Vfs, abs: string) -> bool {
	if vfs.procs != prim.os_vfs().procs {
		return true
	}
	pbuf: prim.Path_Buf
	p, perr := prim.cpath(abs, &pbuf)
	if perr != .None {
		return true
	}
	al := Attr_List {
		bitmapcount = ATTR_BIT_MAP_COUNT,
		commonattr  = ATTR_CMN_NAME,
	}
	buf: [12 + 1024 + 4]u8
	if getattrlist(p, &al, &buf[0], len(buf), FSOPT_NOFOLLOW) != 0 {
		return true
	}
	total := int(prim.get_u32le(buf[0:4]))
	off := int(i32(prim.get_u32le(buf[4:8])))
	n := int(prim.get_u32le(buf[8:12]))
	start := 4 + off
	if n < 1 || start < 12 || start + n > min(total, len(buf)) {
		return true
	}
	name := string(buf[start:start + n - 1])
	return name == path_name(abs)
}

package fs

import win "core:sys/windows"
import "../prim"

@(private)
disk_name_matches :: proc(vfs: prim.Vfs, abs: string) -> bool {
	if vfs.procs != prim.os_vfs().procs {
		return true
	}
	name := path_name(abs)
	caseless := true
	for c in transmute([]u8)name {
		if c >= 0x80 || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') {
			caseless = false
			break
		}
	}
	if caseless || len(name) == len(abs) {
		return true
	}
	parent := abs[:len(abs) - len(name) - 1]
	if len(parent) == 2 && parent[1] == ':' {
		parent = abs[:3]
	}
	fd, err := prim.open_file(vfs, parent, {.Directory})
	if err != .None {
		return true
	}
	defer prim.close_file(vfs, fd)
	wname: [256]u16
	n, ok := wtf8_to_wide(name, wname[:], false)
	if !ok {
		return true
	}
	us := win.UNICODE_STRING {
		Length        = u16(n * 2),
		MaximumLength = u16(n * 2),
		Buffer        = &wname[0],
	}
	buf: [4096]u8 = ---
	iosb: win.IO_STATUS_BLOCK
	st := NtQueryDirectoryFile(fd_handle(fd), nil, nil, nil, &iosb, &buf[0], size_of(buf), NT_CLASS_FULL_DIR, true, &us, true)
	if st < 0 {
		return true
	}
	e, eok := nt_dir_record(NT_CLASS_FULL_DIR, buf[:int(iosb.Information)])
	if !eok {
		return true
	}
	out: [1024]u8
	m, mok := wide_to_wtf8(e.wname, out[:], false)
	if !mok {
		return true
	}
	return string(out[:m]) == name
}

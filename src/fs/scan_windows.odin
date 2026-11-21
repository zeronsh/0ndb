package fs

import "base:runtime"
import win "core:sys/windows"
import "../prim"

@(private)
SCAN_DIR_BUF :: 64 * 1024

@(private)
_open_root :: proc(sc: ^Scanner, root: string) -> (prim.Fd, Error) {
	fd, err := prim.open_file(sc.vfs, root, {.Directory})
	return fd, from_prim(err)
}

@(private)
_read_dir :: proc(sc: ^Scanner, t: ^Dir_Task, raw: ^[dynamic]Raw_Dirent, gitignore: ^[]u8) -> Error {
	dir: win.HANDLE
	if len(t.path) == 0 {
		h, err := nt_open_rel(fd_handle(sc.root_fd), "", NT_FILE_LIST_DIRECTORY | NT_SYNCHRONIZE, NT_FILE_DIRECTORY_FILE | NT_FILE_SYNCHRONOUS_IO_NONALERT)
		if err != .None {
			return err
		}
		dir = h
	} else {
		h, err := nt_open_rel(fd_handle(sc.root_fd), t.path, NT_FILE_LIST_DIRECTORY | NT_SYNCHRONIZE, NT_FILE_DIRECTORY_FILE | NT_FILE_SYNCHRONOUS_IO_NONALERT | NT_FILE_OPEN_REPARSE_POINT)
		if err != .None {
			return err
		}
		dir = h
	}
	defer win.CloseHandle(dir)
	buf: [SCAN_DIR_BUF]u8 = ---
	class := i32(NT_CLASS_ID_EXTD_DIR)
	restart := true
	nbuf: [prim.PATH_MAX]u8
	for {
		iosb: win.IO_STATUS_BLOCK
		st := NtQueryDirectoryFile(dir, nil, nil, nil, &iosb, &buf[0], u32(len(buf)), class, false, nil, win.BOOLEAN(restart))
		if st == STATUS_NO_MORE_FILES {
			break
		}
		if st < 0 {
			if restart && (u32(st) == 0xC0000003 || u32(st) == 0xC000000D || u32(st) == 0xC00000BB) && class != NT_CLASS_FULL_DIR {
				class = NT_CLASS_ID_FULL_DIR if class == NT_CLASS_ID_EXTD_DIR else NT_CLASS_FULL_DIR
				continue
			}
			return nt_error(st)
		}
		restart = false
		got := int(iosb.Information)
		if got <= 0 {
			break
		}
		pos := 0
		for pos < got {
			rec := buf[pos:got]
			next := int((^u32)(&rec[0])^) if len(rec) >= 4 else 0
			e, ok := nt_dir_record(class, rec)
			if next <= 0 || pos + next > got {
				pos = got
			} else {
				pos += next
			}
			if !ok {
				continue
			}
			w := e.wname
			if len(w) == 0 || (len(w) == 1 && w[0] == '.') || (len(w) == 2 && w[0] == '.' && w[1] == '.') {
				continue
			}
			n, nok := wide_to_wtf8(w, nbuf[:], false)
			if !nok {
				continue
			}
			name := string(nbuf[:n])
			if name_internal(name) {
				continue
			}
			kind, stat := nt_stat(e.attrs, e.tag, e.size, e.id, e.write, e.change)
			append(raw, Raw_Dirent{name_off = u32(len(t.names)), name_len = u32(n), kind = kind, stat = stat, statted = true})
			append(&t.names, ..nbuf[:n])
		}
	}
	budget := sc.opts.read_budget if sc.opts.read_budget > 0 else 8 << 20
	for &r in raw {
		name := string(t.names[r.name_off:][:r.name_len])
		switch {
		case r.kind == .Symlink:
			pbuf: prim.Path_Buf
			p, pok := path_join_buf(pbuf[:], sc.root, t.path, name)
			if !pok {
				r.kind = .Other
				continue
			}
			tbuf: [prim.PATH_MAX]u8
			tn, lerr := prim.readlink(sc.vfs, p, tbuf[:])
			if lerr != .None || tn <= 0 || tn >= len(tbuf) {
				r.kind = .Other
				continue
			}
			r.target_off = u32(len(t.names))
			r.target_len = u32(tn)
			append(&t.names, ..tbuf[:tn])
		case r.kind == .File && name == ".gitignore" && gitignore^ == nil && r.stat.size < 8 << 20:
			data, ok := read_rel(dir, name, int(r.stat.size), sc.allocator)
			if ok {
				gitignore^ = data
			}
		case r.kind == .File && sc.opts.read_limit > 0 && r.stat.size <= sc.opts.read_limit && r.stat.size <= budget:
			own := copy(nbuf[:], name)
			start := len(t.names)
			size := int(r.stat.size)
			resize(&t.names, start + size + 1)
			if !read_rel_into(dir, string(nbuf[:own]), t.names[start:]) {
				resize(&t.names, start)
				continue
			}
			resize(&t.names, start + size)
			r.data_off = u32(start)
			r.data_len = u32(size)
			r.has_data = true
			budget -= i64(size)
		}
	}
	return .None
}

@(private)
read_rel_into :: proc(dir: win.HANDLE, name: string, out: []u8) -> bool {
	h, err := nt_open_rel(dir, name, NT_FILE_READ_DATA | NT_SYNCHRONIZE, NT_FILE_NON_DIRECTORY_FILE | NT_FILE_SYNCHRONOUS_IO_NONALERT | NT_FILE_SEQUENTIAL_ONLY | NT_FILE_OPEN_REPARSE_POINT)
	if err != .None {
		return false
	}
	defer win.CloseHandle(h)
	n := 0
	for n < len(out) {
		got: u32
		if !win.ReadFile(h, &out[n], u32(min(len(out) - n, 1 << 30)), &got, nil) || got == 0 {
			break
		}
		n += int(got)
	}
	return n == len(out) - 1
}

@(private)
read_rel :: proc(dir: win.HANDLE, name: string, size: int, allocator: runtime.Allocator) -> ([]u8, bool) {
	buf := make([]u8, size + 1, allocator)
	if !read_rel_into(dir, name, buf) {
		delete(buf, allocator)
		return nil, false
	}
	return buf[:size], true
}

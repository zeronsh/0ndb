package fs

import win "core:sys/windows"
import "../prim"

foreign import kernel32 "system:Kernel32.lib"

@(private)
@(default_calling_convention = "system")
foreign kernel32 {
	HeapCompact :: proc(heap: win.HANDLE, flags: u32) -> uint ---
}

@(private)
WATCH_BUF :: 64 * 1024

@(private)
WATCH_DEPTH :: 2

@(private)
WATCH_FILTER :: u32(win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_ATTRIBUTES | win.FILE_NOTIFY_CHANGE_SIZE | win.FILE_NOTIFY_CHANGE_LAST_WRITE)

@(private)
GIT_FILTER :: u32(win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_SIZE | win.FILE_NOTIFY_CHANGE_LAST_WRITE)

@(private)
Win_Watch :: struct {
	reg:     ^Registry,
	m:       ^Mount,
	dir:     string,
	handle:  win.HANDLE,
	watch:   prim.Watch,
	git:     bool,
	pending: int,
	dead:    bool,
}

_Registry_Os :: struct {
	watches: [dynamic]^Win_Watch,
	full:    bool,
	got:     bool,
}

@(private)
_registry_os_init :: proc(reg: ^Registry) -> Error {
	reg.os.watches = make([dynamic]^Win_Watch, reg.allocator)
	return .None
}

@(private)
_registry_os_destroy :: proc(reg: ^Registry) {
	for w in reg.os.watches {
		watch_close(reg, w)
	}
	delete(reg.os.watches)
	reg.os.watches = nil
}

@(private)
watch_close :: proc(reg: ^Registry, w: ^Win_Watch) {
	if w.watch != 0 && reg.loop != nil {
		prim.unwatch(reg.loop, w.watch)
	}
	if w.handle != nil {
		win.CloseHandle(w.handle)
	}
	delete(w.dir, reg.allocator)
	free(w, reg.allocator)
}

@(private)
_registry_os_attach :: proc(reg: ^Registry, loop: ^prim.Loop) -> Error {
	for w in reg.os.watches {
		if w.watch == 0 {
			watch_start(reg, w)
		}
	}
	return .None
}

@(private)
_registry_wait :: proc(reg: ^Registry, ms: i32) -> bool {
	l := reg.loop
	if l == nil {
		return false
	}
	fired := false
	t := prim.timer(l, i64(ms), rawptr(&fired), proc(l: ^prim.Loop, data: rawptr) {
		(^bool)(data)^ = true
	})
	reg.os.got = false
	for !reg.os.got && !fired {
		if observer_wait(reg) != .None {
			break
		}
	}
	prim.timer_cancel(l, t)
	return reg.os.got
}

@(private)
open_watch_handle :: proc(vfs: prim.Vfs, dir: string) -> (win.HANDLE, Error) {
	fd, err := prim.open_file(vfs, dir, {.Directory})
	if err != .None {
		return nil, from_prim(err)
	}
	defer prim.close_file(vfs, fd)
	return nt_open_rel(fd_handle(fd), "", NT_FILE_LIST_DIRECTORY | NT_SYNCHRONIZE, NT_FILE_DIRECTORY_FILE)
}

@(private)
add_watch :: proc(reg: ^Registry, m: ^Mount, dir: string, git: bool) -> Error {
	h, err := open_watch_handle(reg.vfs, dir)
	if err != .None {
		return err
	}
	w := new(Win_Watch, reg.allocator)
	if w == nil {
		win.CloseHandle(h)
		return .No_Memory
	}
	w.reg = reg
	w.m = m
	w.handle = h
	w.git = git
	w.dir, _ = clone_string(dir, reg.allocator)
	append(&reg.os.watches, w)
	if reg.loop != nil {
		watch_start(reg, w)
	}
	return .None
}

@(private)
watch_start :: proc(reg: ^Registry, w: ^Win_Watch) {
	wt, err := prim.watch_overlapped(reg.loop, prim.Fd(i32(int(uintptr(w.handle)))), w, watch_done)
	if err != .None {
		watch_fail(w)
		return
	}
	w.watch = wt
	for _ in 0 ..< WATCH_DEPTH {
		if !watch_arm(w) {
			return
		}
	}
}

@(private)
watch_arm :: proc(w: ^Win_Watch) -> bool {
	l := w.reg.loop
	op, err := prim.overlapped_begin(l, w.watch, WATCH_BUF)
	if err != .None {
		watch_fail(w)
		return false
	}
	ok := win.ReadDirectoryChangesExW(w.handle, raw_data(op.buf), u32(len(op.buf)), win.BOOL(!w.git), GIT_FILTER if w.git else WATCH_FILTER, nil, (^win.OVERLAPPED)(prim.overlapped_ptr(op)), nil, .ReadDirectoryNotifyExtendedInformation)
	if prim.overlapped_submit(l, op, bool(ok)) != .None {
		watch_fail(w)
		return false
	}
	w.pending += 1
	return true
}

@(private)
watch_fail :: proc(w: ^Win_Watch) {
	if w.dead {
		return
	}
	w.dead = true
	w.reg.os.full = true
	w.reg.os.got = true
	if w.git {
		mount_mark_git(w.m)
	} else {
		note_unwatched(w.m, "")
		mount_mark_rescan(w.m)
	}
}

@(private)
watch_done :: proc(l: ^prim.Loop, wt: prim.Watch, op: ^prim.Overlapped_Op, bytes: int, err: prim.Error, data: rawptr) {
	w := (^Win_Watch)(data)
	w.pending -= 1
	if err == .Interrupted {
		return
	}
	reg := w.reg
	reg.os.got = true
	if err != .None {
		watch_fail(w)
		return
	}
	if !w.dead {
		watch_arm(w)
	}
	if bytes == 0 || op.status == STATUS_NOTIFY_ENUM_DIR || bytes > len(op.buf) {
		if w.git {
			mount_mark_git(w.m)
		} else {
			mount_mark_rescan(w.m)
		}
		return
	}
	watch_parse(w, op.buf[:bytes])
}

@(private)
watch_parse :: proc(w: ^Win_Watch, buf: []u8) {
	reg := w.reg
	pbuf: [prim.PATH_MAX]u8
	base := copy(pbuf[:], w.dir)
	if base >= len(pbuf) - 1 {
		return
	}
	pbuf[base] = '/'
	pos := 0
	for pos + 84 <= len(buf) {
		rec := buf[pos:]
		next := int((^u32)(&rec[0])^)
		action := (^u32)(&rec[4])^
		attrs := (^u32)(&rec[56])^
		name_len := int((^u32)(&rec[80])^)
		if next < 0 || name_len % 2 != 0 || 84 + name_len > len(rec) {
			break
		}
		wname := ([^]u16)(&rec[84])[:name_len / 2]
		pos = pos + next if next > 0 else len(buf)
		n, ok := wide_to_wtf8(wname, pbuf[base + 1:], true)
		if !ok || n == 0 {
			continue
		}
		if action == win.FILE_ACTION_MODIFIED && attrs & ATTR_DIRECTORY != 0 && attrs & ATTR_REPARSE == 0 {
			continue
		}
		abs := string(pbuf[:base + 1 + n])
		registry_notify(reg, abs, .Gone if action == win.FILE_ACTION_REMOVED || action == win.FILE_ACTION_RENAMED_OLD_NAME else .Changed)
	}
}

@(private)
_watch_mount :: proc(reg: ^Registry, m: ^Mount) -> Error {
	if err := add_watch(reg, m, m.root, false); err != .None {
		reg.os.full = true
		note_unwatched(m, "")
		return .None
	}
	if m.has_git && !path_at_or_under(m.git.dir, m.root) {
		add_watch(reg, m, m.git.dir, true)
	}
	return .None
}

@(private)
_unwatch_mount :: proc(reg: ^Registry, m: ^Mount) {
	i := 0
	for i < len(reg.os.watches) {
		w := reg.os.watches[i]
		if w.m == m {
			watch_close(reg, w)
			ordered_remove(&reg.os.watches, i)
			continue
		}
		i += 1
	}
}

@(private)
_os_watch_dir :: proc(reg: ^Registry, m: ^Mount, rel: string, parent_wd: i32) -> (wd: i32, err: Error) {
	return -1, .None
}

@(private)
_registry_os_read :: proc(reg: ^Registry) -> Error {
	return .None
}

@(private)
_heap_release :: proc() {
	HeapCompact(win.GetProcessHeap(), 0)
}

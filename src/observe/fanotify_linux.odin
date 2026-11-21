#+build linux
package observe

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "../fs"
import "../prim"

@(private)
FAN_CLOEXEC :: uintptr(0x1)
@(private)
FAN_NONBLOCK :: uintptr(0x2)
@(private)
FAN_UNLIMITED_QUEUE :: uintptr(0x10)
@(private)
FAN_REPORT_PIDFD :: uintptr(0x80)
@(private)
FAN_REPORT_DIR_FID :: uintptr(0x400)
@(private)
FAN_REPORT_NAME :: uintptr(0x800)
@(private)
FAN_MARK_ADD :: uintptr(0x1)
@(private)
FAN_MARK_FILESYSTEM :: uintptr(0x100)
@(private)
FAN_MODIFY :: u64(0x2)
@(private)
FAN_ATTRIB :: u64(0x4)
@(private)
FAN_MOVED_FROM :: u64(0x40)
@(private)
FAN_MOVED_TO :: u64(0x80)
@(private)
FAN_CREATE :: u64(0x100)
@(private)
FAN_DELETE :: u64(0x200)
@(private)
FAN_Q_OVERFLOW :: u64(0x4000)
@(private)
FAN_ONDIR :: u64(0x40000000)
@(private)
FAN_MASK :: FAN_MODIFY | FAN_ATTRIB | FAN_MOVED_FROM | FAN_MOVED_TO | FAN_CREATE | FAN_DELETE | FAN_ONDIR
@(private)
FAN_INFO_DFID_NAME :: u8(2)
@(private)
FAN_INFO_PIDFD :: u8(4)
@(private)
FAN_NOPIDFD :: i32(-1)

@(private)
Fan_Mark :: struct {
	dev:      u64,
	fsid:     [2]i32,
	mount_fd: i32,
}

Fanotify :: struct {
	loop:      ^prim.Loop,
	allocator: runtime.Allocator,
	router:    Router,
	sink:      Sink,
	fd:        i32,
	watch:     prim.Watch,
	pidfd:     bool,
	marks:     [dynamic]Fan_Mark,
	lineage:   Lineage_Table,
	cn_watch:  prim.Watch,
	buf:       []u8,
	path:      [prim.PATH_MAX * 2]u8,
	pids:      [MAX_LINEAGE]prim.Pid,
	self:      prim.Pid,
	stats:     Stats,
}

has_cap_sys_admin :: proc() -> bool {
	Cap_Header :: struct {
		version: u32,
		pid:     i32,
	}
	Cap_Data :: struct {
		effective:   u32,
		permitted:   u32,
		inheritable: u32,
	}
	h := Cap_Header{version = 0x20080522}
	d: [2]Cap_Data
	if _errno(intrinsics.syscall(linux.SYS_capget, uintptr(&h), uintptr(&d))) != 0 {
		return false
	}
	return d[0].effective & (1 << 21) != 0
}

fanotify_init :: proc(f: ^Fanotify, loop: ^prim.Loop, allocator := context.allocator) -> prim.Error {
	f^ = {
		loop      = loop,
		allocator = allocator,
		fd        = -1,
	}
	f.lineage.fd = -1
	f.self = prim.Pid(linux.getpid())
	if !has_cap_sys_admin() {
		return .Permission
	}
	base := FAN_CLOEXEC | FAN_NONBLOCK | FAN_UNLIMITED_QUEUE | FAN_REPORT_DIR_FID | FAN_REPORT_NAME
	ev_flags := uintptr(0o2000000 | 0o100000)
	r := intrinsics.syscall(linux.SYS_fanotify_init, base | FAN_REPORT_PIDFD, ev_flags)
	f.pidfd = true
	if _errno(r) == EINVAL {
		r = intrinsics.syscall(linux.SYS_fanotify_init, base, ev_flags)
		f.pidfd = false
	}
	if e := _errno(r); e != 0 {
		return _map_errno(linux.Errno(e))
	}
	f.fd = i32(int(r))
	buf, berr := make([]u8, 256 * 1024, allocator)
	if berr != nil {
		fanotify_destroy(f)
		return .No_Memory
	}
	f.buf = buf
	router_init(&f.router, allocator)
	f.marks = make([dynamic]Fan_Mark, allocator)
	if lineage_open(&f.lineage, allocator) == .None {
		w, werr := prim.watch(loop, prim.Fd(f.lineage.fd), {.Read}, f, _on_lineage)
		if werr == .None {
			f.cn_watch = w
		}
	}
	w, werr := prim.watch(loop, prim.Fd(f.fd), {.Read}, f, _on_fanotify)
	if werr != .None {
		fanotify_destroy(f)
		return werr
	}
	f.watch = w
	return .None
}

fanotify_destroy :: proc(f: ^Fanotify) {
	if f.loop != nil {
		if f.watch != 0 {
			prim.unwatch(f.loop, f.watch)
		}
		if f.cn_watch != 0 {
			prim.unwatch(f.loop, f.cn_watch)
		}
	}
	for m in f.marks {
		_sys_close(m.mount_fd)
	}
	delete(f.marks)
	lineage_close(&f.lineage)
	router_destroy(&f.router)
	if f.buf != nil {
		delete(f.buf, f.allocator)
	}
	_sys_close(f.fd)
	f^ = {}
	f.fd = -1
}

fanotify_set_sink :: proc(f: ^Fanotify, sink: Sink) {
	f.sink = sink
}

fanotify_stats :: proc(f: ^Fanotify) -> Stats {
	return f.stats
}

fanotify_watch :: proc(f: ^Fanotify, path: string) -> prim.Error {
	if f.fd < 0 {
		return .Invalid
	}
	pb: [prim.PATH_MAX + 1]u8
	cp, ok := _cstr(path, pb[:])
	if !ok {
		return .Name_Too_Long
	}
	st, se := _sys_statx(AT_FDCWD, cp, 0)
	if se != 0 {
		return _map_errno(linux.Errno(se))
	}
	for m in f.marks {
		if m.dev == st.dev {
			return .None
		}
	}
	mfd, oe := _sys_openat(AT_FDCWD, cp, SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
	if oe != 0 {
		return _map_errno(linux.Errno(oe))
	}
	sfs: [120]u8
	if e := _errno(intrinsics.syscall(linux.SYS_fstatfs, uintptr(int(mfd)), uintptr(&sfs))); e != 0 {
		_sys_close(mfd)
		return _map_errno(linux.Errno(e))
	}
	cwd := AT_FDCWD
	r := intrinsics.syscall(linux.SYS_fanotify_mark, uintptr(int(f.fd)), FAN_MARK_ADD | FAN_MARK_FILESYSTEM, uintptr(FAN_MASK), uintptr(int(cwd)), uintptr(rawptr(cp)))
	if e := _errno(r); e != 0 {
		_sys_close(mfd)
		return _map_errno(linux.Errno(e))
	}
	m := Fan_Mark{dev = st.dev, mount_fd = mfd}
	m.fsid = (^[2]i32)(&sfs[56])^
	append(&f.marks, m)
	return .None
}

fanotify_observer :: proc(f: ^Fanotify) -> fs.Write_Observer {
	return fs.Write_Observer{data = f, start = _fan_start, stop = _fan_stop}
}

@(private)
_fan_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	f := (^Fanotify)(data)
	router_bind(&f.router, reg)
	_fan_sync_marks(f)
	return .None
}

@(private)
_fan_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	f := (^Fanotify)(data)
	if f.router.reg == reg {
		router_bind(&f.router, nil)
	}
}

@(private)
_fan_sync_marks :: proc(f: ^Fanotify) {
	router_refresh(&f.router)
	for root in f.router.roots {
		fanotify_watch(f, root.real)
	}
}

@(private)
_on_lineage :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	f := (^Fanotify)(data)
	_fan_drain(f)
}

@(private)
_on_fanotify :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	f := (^Fanotify)(data)
	_fan_drain(f)
}

@(private)
_fan_drain :: proc(f: ^Fanotify) {
	if f.router.reg != nil && len(f.router.roots) != len(f.router.reg.mounts) {
		_fan_sync_marks(f)
	}
	lineage_drain(&f.lineage)
	began := lineage_epoch_begin(&f.lineage)
	for {
		r := intrinsics.syscall(linux.SYS_read, uintptr(int(f.fd)), uintptr(raw_data(f.buf)), uintptr(len(f.buf)))
		e := _errno(r)
		if e == EINTR {
			continue
		}
		if e != 0 {
			break
		}
		n := int(r)
		if n <= 0 {
			break
		}
		_fan_parse(f, f.buf[:n])
	}
	lineage_epoch_end(&f.lineage, began)
}

@(private)
_fan_parse :: proc(f: ^Fanotify, data: []u8) {
	off := 0
	for off + 24 <= len(data) {
		ev_len := int(prim.get_u32le(data[off:]))
		if ev_len < 24 || off + ev_len > len(data) {
			return
		}
		ev := data[off:off + ev_len]
		off += ev_len
		meta_len := int(_u16le(ev[6:]))
		mask := prim.get_u64le(ev[8:])
		efd := i32(prim.get_u32le(ev[16:]))
		pid := prim.Pid(i32(prim.get_u32le(ev[20:])))
		if efd >= 0 {
			_sys_close(efd)
		}
		if mask & FAN_Q_OVERFLOW != 0 {
			_fan_overflow(f)
			continue
		}
		dir_rec: []u8
		pidfd := FAN_NOPIDFD
		pos := meta_len
		for pos + 4 <= len(ev) {
			kind := ev[pos]
			rl := int(_u16le(ev[pos + 2:]))
			if rl < 4 || pos + rl > len(ev) {
				break
			}
			rec := ev[pos:pos + rl]
			pos += rl
			switch kind {
			case FAN_INFO_DFID_NAME:
				dir_rec = rec
			case FAN_INFO_PIDFD:
				if len(rec) >= 8 {
					pidfd = i32(prim.get_u32le(rec[4:]))
				}
			}
		}
		if pid != f.self {
			_fan_event(f, mask, pid, pidfd, dir_rec)
		}
		if pidfd >= 0 {
			_sys_close(pidfd)
		}
	}
}

@(private)
_fan_overflow :: proc(f: ^Fanotify) {
	if f.router.reg == nil {
		return
	}
	for m in f.router.reg.mounts {
		if m != nil {
			fs.mount_mark_rescan(m)
		}
	}
}

@(private)
_fan_event :: proc(f: ^Fanotify, mask: u64, pid: prim.Pid, pidfd: i32, rec: []u8) {
	f.stats.notifications += 1
	if len(rec) < 4 + 8 + 8 {
		f.stats.failed += 1
		return
	}
	fsid := [2]i32{i32(prim.get_u32le(rec[4:])), i32(prim.get_u32le(rec[8:]))}
	hbytes := int(prim.get_u32le(rec[12:]))
	if 12 + 8 + hbytes > len(rec) {
		f.stats.failed += 1
		return
	}
	handle := rec[12:12 + 8 + hbytes]
	name_bytes := rec[12 + 8 + hbytes:]
	nl := 0
	for nl < len(name_bytes) && name_bytes[nl] != 0 {
		nl += 1
	}
	name := string(name_bytes[:nl])
	if name == "." {
		name = ""
	}
	mount_fd: i32 = -1
	for m in f.marks {
		if m.fsid == fsid {
			mount_fd = m.mount_fd
			break
		}
	}
	if mount_fd < 0 {
		f.stats.failed += 1
		return
	}
	r := intrinsics.syscall(linux.SYS_open_by_handle_at, uintptr(int(mount_fd)), uintptr(raw_data(handle)), SYS_O_PATH | SYS_O_CLOEXEC)
	if _errno(r) != 0 {
		f.stats.failed += 1
		_fan_overflow_dir(f, mount_fd)
		return
	}
	dfd := i32(int(r))
	dp, ok := _readlink_fd(dfd, f.path[:prim.PATH_MAX])
	_sys_close(dfd)
	if !ok || len(dp) == 0 || dp[0] != '/' {
		f.stats.failed += 1
		return
	}
	n := len(dp)
	if len(name) > 0 {
		if n + 1 + len(name) > len(f.path) {
			f.stats.failed += 1
			return
		}
		if n > 1 {
			f.path[n] = '/'
			n += 1
		}
		copy(f.path[n:], name)
		n += len(name)
	}
	w := Write {
		pid   = pid,
		tid   = pid,
		path  = string(f.path[:n]),
		exact = true,
	}
	dir := mask & FAN_ONDIR != 0
	switch {
	case mask & FAN_CREATE != 0:
		w.op = .Mkdir if dir else .Write
	case mask & FAN_DELETE != 0:
		w.op = .Rmdir if dir else .Remove
	case mask & (FAN_MOVED_FROM | FAN_MOVED_TO) != 0:
		w.op = .Rename
		w.from = w.path
	case mask & FAN_MODIFY != 0:
		w.op = .Write
	case mask & FAN_ATTRIB != 0:
		w.op = .Chmod
	case:
		f.stats.ignored += 1
		return
	}
	w.lineage = lineage_of(&f.lineage, pid, f.pids[:])
	if len(w.lineage) == 0 {
		f.pids[0] = pid
		w.lineage = f.pids[:1]
	}
	f.stats.reported += 1
	deliver(&f.router, f.sink, &w)
}

@(private)
_fan_overflow_dir :: proc(f: ^Fanotify, mount_fd: i32) {
	if f.router.reg == nil {
		return
	}
	dp, ok := _readlink_fd(mount_fd, f.path[:prim.PATH_MAX])
	if !ok {
		return
	}
	router_refresh(&f.router)
	for root in f.router.roots {
		_, a := under(root.real, dp)
		_, b := under(dp, root.real)
		if a || b {
			fs.mount_mark_rescan(root.mount)
		}
	}
}

@(private)
_u16le :: #force_inline proc "contextless" (b: []u8) -> u16 {
	return u16(b[0]) | u16(b[1]) << 8
}

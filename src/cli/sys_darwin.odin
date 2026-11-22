package main

import "core:strings"
import "core:sys/kqueue"
import "core:sys/posix"
import "../prim"

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
	malloc_zone_pressure_relief :: proc(zone: rawptr, goal: uint) -> uint ---
	getpeereid :: proc(fd: posix.FD, uid: ^posix.uid_t, gid: ^posix.gid_t) -> i32 ---
	proc_pidinfo :: proc(pid: i32, flavor: i32, arg: u64, buffer: rawptr, size: i32) -> i32 ---
}

Signals :: struct {
	fd: prim.Fd,
}

signals_open :: proc(s: ^Signals) -> bool {
	kq, err := kqueue.kqueue()
	if err != .NONE {
		return false
	}
	sigs := [3]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP}
	changes: [3]kqueue.KEvent
	for sig, i in sigs {
		posix.signal(sig, auto_cast posix.SIG_IGN)
		changes[i] = kqueue.KEvent{ident = uintptr(sig), filter = .Signal, flags = {.Add, .Enable}}
	}
	if _, kerr := kqueue.kevent(kq, changes[:], nil, nil); kerr != .NONE {
		posix.close(kq)
		return false
	}
	s.fd = prim.Fd(kq)
	return true
}

signals_read :: proc(s: ^Signals) -> (sig: int, ok: bool) {
	events: [4]kqueue.KEvent
	ts := posix.timespec{}
	n, err := kqueue.kevent(posix.FD(s.fd), nil, events[:], &ts)
	if err != .NONE || n <= 0 {
		return 0, false
	}
	return int(events[0].ident), true
}

signals_close :: proc(s: ^Signals) {
	if s.fd >= 0 {
		posix.close(posix.FD(s.fd))
		s.fd = -1
	}
}

peer_is_self :: proc(fd: prim.Fd) -> bool {
	uid: posix.uid_t
	gid: posix.gid_t
	if getpeereid(posix.FD(fd), &uid, &gid) != 0 {
		return false
	}
	return uid == posix.getuid()
}

PROC_PIDTASKINFO :: 4

Proc_Taskinfo :: struct {
	virtual_size:  u64,
	resident_size: u64,
	total_user:    u64,
	total_system:  u64,
	threads_user:  u64,
	threads_sys:   u64,
	policy:        i32,
	faults:        i32,
	pageins:       i32,
	cow_faults:    i32,
	msgs_sent:     i32,
	msgs_received: i32,
	syscalls_mach: i32,
	syscalls_unix: i32,
	csw:           i32,
	threadnum:     i32,
	numrunning:    i32,
	priority:      i32,
}

rss_bytes :: proc() -> i64 {
	ti: Proc_Taskinfo
	if proc_pidinfo(i32(posix.getpid()), PROC_PIDTASKINFO, 0, &ti, size_of(ti)) != size_of(ti) {
		return 0
	}
	return i64(ti.resident_size)
}

idle_release :: proc() {
	malloc_zone_pressure_relief(nil, 0)
}

sys_hostname :: proc(allocator := context.allocator) -> string {
	buf: [256]u8
	if posix.gethostname(raw_data(buf[:]), len(buf) - 1) != .OK {
		return ""
	}
	n := 0
	for n < len(buf) && buf[n] != 0 {
		n += 1
	}
	return strings.clone(string(buf[:n]), allocator)
}

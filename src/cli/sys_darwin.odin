package main

import "core:sys/kqueue"
import "core:sys/posix"
import "../prim"

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
	malloc_zone_pressure_relief :: proc(zone: rawptr, goal: uint) -> uint ---
	getpeereid :: proc(fd: posix.FD, uid: ^posix.uid_t, gid: ^posix.gid_t) -> i32 ---
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

rss_bytes :: proc() -> i64 {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) != .OK {
		return 0
	}
	return i64(ru.ru_maxrss)
}

idle_release :: proc() {
	malloc_zone_pressure_relief(nil, 0)
}

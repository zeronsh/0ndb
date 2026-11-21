package prim

import "core:sys/linux"
import "core:sys/posix"

@(private)
MAX_EVENTS :: 64

_Slot_Os :: struct {}

_Loop_Os :: struct {
	epfd:      linux.Fd,
	wakefd:    linux.Fd,
	no_pwait2: bool,
	events:    [MAX_EVENTS]linux.EPoll_Event,
}

@(private)
_os_init :: proc(l: ^Loop) -> Error {
	l.os.epfd = -1
	l.os.wakefd = -1
	epfd, errno := linux.epoll_create1({.FDCLOEXEC})
	if errno != .NONE {
		return _error(errno)
	}
	l.os.epfd = epfd
	wakefd, werr := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if werr != .NONE {
		_os_destroy(l)
		return _error(werr)
	}
	l.os.wakefd = wakefd
	ev := linux.EPoll_Event {
		events = {.IN, .ET},
		data = {u64 = WAKE_TAG},
	}
	if cerr := linux.epoll_ctl(epfd, .ADD, wakefd, &ev); cerr != .NONE {
		_os_destroy(l)
		return _error(cerr)
	}
	return .None
}

@(private)
_os_destroy :: proc(l: ^Loop) {
	if l.os.wakefd >= 0 {
		linux.close(l.os.wakefd)
		l.os.wakefd = -1
	}
	if l.os.epfd >= 0 {
		linux.close(l.os.epfd)
		l.os.epfd = -1
	}
}

wake :: proc "contextless" (l: ^Loop) {
	one := u64(1)
	b := transmute([8]u8)one
	for {
		_, errno := linux.write(l.os.wakefd, b[:])
		if errno != .EINTR {
			return
		}
	}
}

@(private)
_os_wake_drain :: proc(l: ^Loop) {
	b: [8]u8
	for {
		_, errno := linux.read(l.os.wakefd, b[:])
		if errno != .EINTR {
			return
		}
	}
}

@(private)
_os_poll :: proc(l: ^Loop, timeout_ns: i64) -> Error {
	n: i32
	errno: linux.Errno
	if !l.os.no_pwait2 {
		ts: linux.Time_Spec
		tp: ^linux.Time_Spec
		if timeout_ns >= 0 {
			ts = {time_sec = uint(timeout_ns / 1_000_000_000), time_nsec = uint(timeout_ns % 1_000_000_000)}
			tp = &ts
		}
		n, errno = linux.epoll_pwait2(l.os.epfd, &l.os.events[0], MAX_EVENTS, tp, nil)
		if errno == .ENOSYS {
			l.os.no_pwait2 = true
		}
	}
	if l.os.no_pwait2 {
		ms: i32 = -1
		if timeout_ns >= 0 {
			ms = i32(min((timeout_ns + 999_999) / 1_000_000, i64(max(i32))))
		}
		n, errno = linux.epoll_wait(l.os.epfd, &l.os.events[0], MAX_EVENTS, ms)
	}
	if errno != .NONE {
		return _error(errno)
	}
	for i in 0 ..< int(n) {
		ev := l.os.events[i]
		set := ev.events
		events: Events
		if .IN in set {
			events += {.Read}
		}
		if .OUT in set {
			events += {.Write}
		}
		if .HUP in set || .RDHUP in set {
			events += {.Hangup}
		}
		if .ERR in set {
			events += {.Error}
		}
		_dispatch(l, ev.data.u64, events)
	}
	return .None
}

@(private)
_epoll_set :: proc "contextless" (events: Events) -> linux.EPoll_Event_Set {
	set := linux.EPoll_Event_Set{.ET, .RDHUP}
	if .Read in events {
		set += {.IN}
	}
	if .Write in events {
		set += {.OUT}
	}
	return set
}

@(private)
_os_watch :: proc(l: ^Loop, fd: Fd, events: Events, h: u64) -> Error {
	ev := linux.EPoll_Event {
		events = _epoll_set(events),
		data = {u64 = h},
	}
	return _error(linux.epoll_ctl(l.os.epfd, .ADD, linux.Fd(fd), &ev))
}

@(private)
_os_modify :: proc(l: ^Loop, fd: Fd, old, next: Events, h: u64) -> Error {
	ev := linux.EPoll_Event {
		events = _epoll_set(next),
		data = {u64 = h},
	}
	return _error(linux.epoll_ctl(l.os.epfd, .MOD, linux.Fd(fd), &ev))
}

@(private)
_os_unwatch :: proc(l: ^Loop, fd: Fd, events: Events, h: u64) {
	linux.epoll_ctl(l.os.epfd, .DEL, linux.Fd(fd), nil)
}

@(private)
_os_child_watch :: proc(l: ^Loop, s: ^_Slot, h: u64) -> Error {
	pidfd, errno := linux.pidfd_open(linux.Pid(s.pid), {})
	if errno != .NONE {
		if errno == .ESRCH {
			return .No_Child
		}
		return _error(errno)
	}
	ev := linux.EPoll_Event {
		events = {.IN, .ET},
		data = {u64 = h},
	}
	if cerr := linux.epoll_ctl(l.os.epfd, .ADD, linux.Fd(pidfd), &ev); cerr != .NONE {
		linux.close(linux.Fd(pidfd))
		return _error(cerr)
	}
	s.fd = Fd(pidfd)
	return .None
}

@(private)
_os_child_reap :: proc(l: ^Loop, idx: u32) -> (Exit_Status, bool) {
	s := &l.slots[idx]
	info: linux.Sig_Info
	for {
		errno := linux.waitid(.PIDFD, linux.Id(s.fd), &info, {.WEXITED, .WNOHANG}, nil)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return {code = -1}, true
		}
		break
	}
	if info._pid1 == 0 {
		return {}, false
	}
	switch info.code {
	case 1:
		return {code = info.status}, true
	case 2, 3:
		return {code = -1, signal = info.status}, true
	}
	return {}, false
}

@(private)
_os_child_release :: proc(l: ^Loop, s: ^_Slot) {
	if s.fd >= 0 {
		linux.epoll_ctl(l.os.epfd, .DEL, linux.Fd(s.fd), nil)
		linux.close(linux.Fd(s.fd))
		s.fd = INVALID_FD
	}
}

ignore_sigpipe :: proc "contextless" () {
	act: linux.Sig_Action
	act.special = .SIG_IGN
	linux.rt_sigaction(.SIGPIPE, &act, nil)
}

@(private)
_os_fd :: proc "contextless" (l: ^Loop) -> Fd {
	return Fd(l.os.epfd)
}

@(private)
_os_has_ready :: proc(l: ^Loop) -> bool {
	fds := [1]posix.pollfd{{fd = posix.FD(l.os.epfd), events = {.IN}}}
	return posix.poll(&fds[0], 1, 0) > 0
}

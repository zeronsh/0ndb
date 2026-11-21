package prim

import "core:c"
import "core:sys/kqueue"
import "core:sys/posix"

@(private)
MAX_EVENTS :: 64

_Loop_Os :: struct {
	kq:     posix.FD,
	events: [MAX_EVENTS]kqueue.KEvent,
}

@(private)
_os_init :: proc(l: ^Loop) -> Error {
	kq, err := kqueue.kqueue()
	if err != .NONE {
		l.os.kq = -1
		return _error(err)
	}
	l.os.kq = kq
	_set_cloexec(kq)
	ev := kqueue.KEvent {
		ident  = 0,
		filter = .User,
		flags  = {.Add, .Clear},
	}
	if _, kerr := kqueue.kevent(kq, {ev}, nil, nil); kerr != .NONE {
		_os_destroy(l)
		return _error(kerr)
	}
	return .None
}

@(private)
_os_destroy :: proc(l: ^Loop) {
	if l.os.kq >= 0 {
		posix.close(l.os.kq)
		l.os.kq = -1
	}
}

wake :: proc "contextless" (l: ^Loop) {
	ev := kqueue.KEvent {
		ident  = 0,
		filter = .User,
	}
	ev.fflags.user = {.Trigger}
	changes := [1]kqueue.KEvent{ev}
	for {
		n := _kevent_raw(l.os.kq, &changes[0], 1, nil, 0, nil)
		if n != -1 || posix.errno() != .EINTR {
			return
		}
	}
}

foreign import libsystem "system:System"

@(private)
foreign libsystem {
	@(link_name = "kevent")
	_kevent_raw :: proc(kq: posix.FD, changes: [^]kqueue.KEvent, nchanges: c.int, events: [^]kqueue.KEvent, nevents: c.int, timeout: ^posix.timespec) -> c.int ---
}

@(private)
_os_wake_drain :: proc(l: ^Loop) {
}

@(private)
_os_poll :: proc(l: ^Loop, timeout_ns: i64) -> Error {
	ts: posix.timespec
	tp: ^posix.timespec
	if timeout_ns >= 0 {
		ts.tv_sec = posix.time_t(timeout_ns / 1_000_000_000)
		ts.tv_nsec = c.long(timeout_ns % 1_000_000_000)
		tp = &ts
	}
	n, err := kqueue.kevent(l.os.kq, nil, l.os.events[:], tp)
	if err != .NONE {
		return _error(err)
	}
	for i in 0 ..< int(n) {
		ev := l.os.events[i]
		h := u64(uintptr(ev.udata))
		events: Events
		#partial switch ev.filter {
		case .User:
			_dispatch(l, WAKE_TAG, {})
			continue
		case .Read:
			events += {.Read}
		case .Write:
			events += {.Write}
		case .Proc:
			_dispatch(l, h, {})
			continue
		}
		if .EOF in ev.flags {
			events += {.Hangup}
		}
		if .Error in ev.flags {
			events += {.Error}
		}
		_dispatch(l, h, events)
	}
	return .None
}

@(private)
_kev :: proc "contextless" (fd: Fd, filter: kqueue.Filter, flags: kqueue.Flags, h: u64) -> kqueue.KEvent {
	return kqueue.KEvent{ident = uintptr(fd), filter = filter, flags = flags, udata = rawptr(uintptr(h))}
}

@(private)
_os_watch :: proc(l: ^Loop, fd: Fd, events: Events, h: u64) -> Error {
	changes: [2]kqueue.KEvent
	n := 0
	if .Read in events {
		changes[n] = _kev(fd, .Read, {.Add, .Clear}, h)
		n += 1
	}
	if .Write in events {
		changes[n] = _kev(fd, .Write, {.Add, .Clear}, h)
		n += 1
	}
	if n == 0 {
		return .None
	}
	if _, err := kqueue.kevent(l.os.kq, changes[:n], nil, nil); err != .NONE {
		_os_unwatch(l, fd, events)
		return _error(err)
	}
	return .None
}

@(private)
_os_modify :: proc(l: ^Loop, fd: Fd, old, next: Events, h: u64) -> Error {
	_os_unwatch(l, fd, old - next)
	return _os_watch(l, fd, next - old, h)
}

@(private)
_os_unwatch :: proc(l: ^Loop, fd: Fd, events: Events) {
	if .Read in events {
		kqueue.kevent(l.os.kq, {_kev(fd, .Read, {.Delete}, 0)}, nil, nil)
	}
	if .Write in events {
		kqueue.kevent(l.os.kq, {_kev(fd, .Write, {.Delete}, 0)}, nil, nil)
	}
}

@(private)
_os_child_watch :: proc(l: ^Loop, s: ^_Slot, h: u64) -> Error {
	ev := kqueue.KEvent {
		ident  = uintptr(s.pid),
		filter = .Proc,
		flags  = {.Add, .One_Shot},
		udata  = rawptr(uintptr(h)),
	}
	ev.fflags.fproc = {.Exit}
	if _, err := kqueue.kevent(l.os.kq, {ev}, nil, nil); err != .NONE {
		if err != .ESRCH {
			return _error(err)
		}
		if _, aerr := append(&l.pending, h); aerr != nil {
			return .No_Memory
		}
	}
	return .None
}

@(private)
_os_child_reap :: proc(l: ^Loop, idx: u32) -> (Exit_Status, bool) {
	s := &l.slots[idx]
	st: c.int
	for {
		r := posix.waitpid(posix.pid_t(s.pid), &st, {.NOHANG})
		if r < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return {code = -1}, true
		}
		if r == 0 {
			append(&l.pending, _handle(idx, s.gen))
			return {}, false
		}
		break
	}
	return _decode_wait(u32(st)), true
}

@(private)
_os_child_release :: proc(l: ^Loop, s: ^_Slot) {
	ev := kqueue.KEvent {
		ident  = uintptr(s.pid),
		filter = .Proc,
		flags  = {.Delete},
	}
	kqueue.kevent(l.os.kq, {ev}, nil, nil)
}

ignore_sigpipe :: proc "contextless" () {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

package prim

import "base:intrinsics"
import win "core:sys/windows"

@(private)
MAX_EVENTS :: 64

@(private)
WAKE_KEY :: uint(WAKE_TAG)
@(private)
TIMER_KEY :: uint(1)
@(private)
PIPE_KEY :: uint(2)
@(private)
WRITER_KEY :: uint(3)
@(private)
OVERLAPPED_KEY :: uint(4)
@(private)
OP_CACHE :: 16

@(private)
SOCK_NOTIFY_OP_ENABLE :: 1
@(private)
SOCK_NOTIFY_OP_DISABLE :: 2
@(private)
SOCK_NOTIFY_OP_REMOVE :: 4
@(private)
SOCK_NOTIFY_TRIGGER_PERSISTENT :: 2
@(private)
SOCK_NOTIFY_TRIGGER_EDGE :: 8
@(private)
SOCK_NOTIFY_EVENT_IN :: 0x01
@(private)
SOCK_NOTIFY_EVENT_OUT :: 0x02
@(private)
SOCK_NOTIFY_EVENT_HANGUP :: 0x04
@(private)
SOCK_NOTIFY_EVENT_ERR :: 0x40
@(private)
SOCK_NOTIFY_EVENT_REMOVE :: 0x80

@(private)
Sock_Notify_Registration :: struct {
	socket:  uintptr,
	key:     rawptr,
	filter:  u16,
	op:      u8,
	trigger: u8,
	result:  u32,
}

@(private)
Proc_Process_Socket_Notifications :: #type proc "system" (port: HANDLE, count: u32, regs: ^Sock_Notify_Registration, timeout: u32, n: u32, entries: ^win.OVERLAPPED_ENTRY, received: ^u32) -> u32

@(private)
_Watch_Kind :: enum u8 {
	None,
	Pipe,
	Socket,
	Overlapped,
}

Overlapped_Op :: struct {
	ov:     win.OVERLAPPED,
	buf:    []u8,
	user:   u64,
	status: u32,
	handle: u64,
	file:   HANDLE,
	index:  int,
	issued: bool,
}

Overlapped_Proc :: #type proc(l: ^Loop, w: Watch, op: ^Overlapped_Op, bytes: int, err: Error, data: rawptr)

@(private)
_Io :: struct {
	ov:      win.OVERLAPPED,
	handle:  u64,
	pipe:    HANDLE,
	pending: bool,
	skip:    bool,
	eof:     bool,
}

@(private)
_Writer :: struct {
	port:   HANDLE,
	pipe:   HANDLE,
	arm:    HANDLE,
	thread: HANDLE,
	handle: u64,
	stop:   i32,
	status: u32,
	busy:   bool,
}

_Slot_Os :: struct {
	kind:    _Watch_Kind,
	io:      ^_Io,
	writer:  ^_Writer,
	process: HANDLE,
	packet:  HANDLE,
	ocb:     Overlapped_Proc,
	ofile:   HANDLE,
}

@(private)
_Ready :: struct {
	handle: u64,
	events: Events,
}

_Loop_Os :: struct {
	port:        HANDLE,
	timer:       HANDLE,
	timer_pkt:   HANDLE,
	timer_assoc: bool,
	timer_due:   i64,
	wake_flag:   i32,
	psn:         Proc_Process_Socket_Notifications,
	winsock:     bool,
	ios:         [dynamic]^_Io,
	writers:     [dynamic]^_Writer,
	ready:       [dynamic]_Ready,
	ops:         [dynamic]^Overlapped_Op,
	op_cache:    [dynamic]^Overlapped_Op,
	stash_n:     int,
	stash_pos:   int,
	entries:     [MAX_EVENTS]win.OVERLAPPED_ENTRY,
}

@(private)
CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
@(private)
TIMER_ALL_ACCESS :: 0x1F0003
@(private)
GENERIC_ALL :: 0x10000000
@(private)
WAIT_OBJECT_0 :: 0
@(private)
STILL_ACTIVE :: 259

@(private)
_os_init :: proc(l: ^Loop) -> Error {
	l.os.ios = make([dynamic]^_Io, l.allocator)
	l.os.writers = make([dynamic]^_Writer, l.allocator)
	l.os.ready = make([dynamic]_Ready, l.allocator)
	l.os.ops = make([dynamic]^Overlapped_Op, l.allocator)
	l.os.op_cache = make([dynamic]^Overlapped_Op, l.allocator)
	l.os.port = win.CreateIoCompletionPort(INVALID_HANDLE, nil, 0, 1)
	if l.os.port == nil {
		err := _last()
		_os_destroy(l)
		return err
	}
	l.os.timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS)
	if l.os.timer == nil {
		l.os.timer = win.CreateWaitableTimerExW(nil, nil, 0, TIMER_ALL_ACCESS)
	}
	if l.os.timer == nil {
		err := _last()
		_os_destroy(l)
		return err
	}
	if st := NtCreateWaitCompletionPacket(&l.os.timer_pkt, GENERIC_ALL, nil); st < 0 {
		_os_destroy(l)
		return _nterror(st)
	}
	wsa: win.WSADATA
	if win.WSAStartup(0x0202, &wsa) == 0 {
		l.os.winsock = true
		name := [?]u16{'w', 's', '2', '_', '3', '2', '.', 'd', 'l', 'l', 0}
		if m := win.GetModuleHandleW(_ws(&name[0])); m != nil {
			l.os.psn = Proc_Process_Socket_Notifications(win.GetProcAddress(m, "ProcessSocketNotifications"))
		}
	}
	return .None
}

@(private)
_os_destroy :: proc(l: ^Loop) {
	for &s, i in l.slots {
		if s.kind == .Fd {
			_os_unwatch(l, s.fd, s.events, _handle(u32(i), s.gen))
		}
	}
	_drain_orphans(l)
	for io in l.os.ios {
		free(io, l.allocator)
	}
	for op in l.os.ops {
		_op_free(l, op)
	}
	for op in l.os.op_cache {
		_op_free(l, op)
	}
	delete(l.os.ops)
	delete(l.os.op_cache)
	l.os.ops = nil
	l.os.op_cache = nil
	delete(l.os.ios)
	delete(l.os.writers)
	delete(l.os.ready)
	l.os.ios = nil
	l.os.writers = nil
	l.os.ready = nil
	if l.os.timer_pkt != nil {
		NtCancelWaitCompletionPacket(l.os.timer_pkt, true)
		win.CloseHandle(l.os.timer_pkt)
		l.os.timer_pkt = nil
	}
	if l.os.timer != nil {
		win.CloseHandle(l.os.timer)
		l.os.timer = nil
	}
	if l.os.port != nil {
		win.CloseHandle(l.os.port)
		l.os.port = nil
	}
	if l.os.winsock {
		win.WSACleanup()
		l.os.winsock = false
	}
}

@(private)
_drain_orphans :: proc(l: ^Loop) {
	deadline := mono_ns() + 2_000_000_000
	for _io_outstanding(l) && mono_ns() < deadline {
		n: u32
		if !win.GetQueuedCompletionStatusEx(l.os.port, &l.os.entries[0], MAX_EVENTS, &n, 100, false) {
			continue
		}
		for i in 0 ..< int(n) {
			e := l.os.entries[i]
			if e.lpCompletionKey == PIPE_KEY {
				if k := _io_find(l, rawptr(e.lpOverlapped)); k >= 0 {
					l.os.ios[k].pending = false
				}
			} else if e.lpCompletionKey == OVERLAPPED_KEY {
				if op := _op_from(l, rawptr(e.lpOverlapped)); op != nil {
					op.issued = false
				}
			}
		}
	}
}

@(private)
_io_outstanding :: proc(l: ^Loop) -> bool {
	for io in l.os.ios {
		if io.pending {
			return true
		}
	}
	for op in l.os.ops {
		if op.issued {
			return true
		}
	}
	return false
}

wake :: proc "contextless" (l: ^Loop) {
	if intrinsics.atomic_compare_exchange_strong_explicit(&l.os.wake_flag, 0, 1, .Acq_Rel, .Acquire) != 0 {
		return
	}
	if !win.PostQueuedCompletionStatus(l.os.port, 0, WAKE_KEY, nil) {
		intrinsics.atomic_store_explicit(&l.os.wake_flag, 0, .Release)
	}
}

@(private)
_os_wake_drain :: proc(l: ^Loop) {
}

@(private)
_arm_timer :: proc(l: ^Loop, timeout_ns: i64) {
	due := mono_ns() + timeout_ns
	if l.os.timer_due != 0 && l.os.timer_assoc && abs(l.os.timer_due - due) < 50_000 {
		return
	}
	rel := win.LARGE_INTEGER(-max((timeout_ns + 99) / 100, 1))
	if !win.SetWaitableTimerEx(l.os.timer, &rel, 0, nil, nil, nil, 0) {
		return
	}
	l.os.timer_due = due
	if !l.os.timer_assoc {
		already: win.BOOLEAN
		if NtAssociateWaitCompletionPacket(l.os.timer_pkt, l.os.port, l.os.timer, rawptr(uintptr(TIMER_KEY)), nil, 0, 0, &already) >= 0 {
			l.os.timer_assoc = true
		}
	}
}

@(private)
_disarm_timer :: proc(l: ^Loop) {
	if l.os.timer_due != 0 {
		CancelWaitableTimer(l.os.timer)
		l.os.timer_due = 0
	}
}

@(private)
_os_poll :: proc(l: ^Loop, timeout_ns: i64) -> Error {
	ready := len(l.os.ready) > 0
	if ready {
		n := len(l.os.ready)
		for i in 0 ..< n {
			r := l.os.ready[i]
			if s := _slot_get(l, r.handle, .Fd); s != nil && s.os.kind == .Socket {
				_dispatch(l, r.handle, r.events & s.events + (r.events & {.Hangup, .Error}))
			} else {
				_deliver(l, r.handle, r.events)
			}
		}
		remove_range(&l.os.ready, 0, n)
	}
	n: int
	if l.os.stash_n > l.os.stash_pos {
		n = l.os.stash_n
	} else {
		l.os.stash_n = 0
		l.os.stash_pos = 0
		wait: u32 = INFINITE
		if ready || len(l.os.ready) > 0 || timeout_ns == 0 {
			wait = 0
		} else if timeout_ns > 0 {
			_arm_timer(l, timeout_ns)
			if !l.os.timer_assoc {
				wait = u32(min((timeout_ns + 999_999) / 1_000_000, i64(INFINITE - 1)))
			}
		} else {
			_disarm_timer(l)
		}
		got: u32
		if !win.GetQueuedCompletionStatusEx(l.os.port, &l.os.entries[0], MAX_EVENTS, &got, wait, false) {
			code := win.GetLastError()
			if code == WAIT_TIMEOUT {
				return .None
			}
			return _werror(code)
		}
		n = int(got)
		l.os.stash_n = n
		l.os.stash_pos = 0
	}
	for l.os.stash_pos < n {
		e := l.os.entries[l.os.stash_pos]
		l.os.stash_pos += 1
		_entry(l, e)
	}
	l.os.stash_n = 0
	l.os.stash_pos = 0
	return .None
}

@(private)
_entry :: proc(l: ^Loop, e: win.OVERLAPPED_ENTRY) {
	switch e.lpCompletionKey {
	case WAKE_KEY:
		intrinsics.atomic_store_explicit(&l.os.wake_flag, 0, .Release)
		_dispatch(l, WAKE_TAG, {})
	case TIMER_KEY:
		l.os.timer_assoc = false
		l.os.timer_due = 0
	case PIPE_KEY:
		k := _io_find(l, rawptr(e.lpOverlapped))
		if k < 0 {
			return
		}
		io := l.os.ios[k]
		io.pending = false
		if io.handle == 0 {
			unordered_remove(&l.os.ios, k)
			free(io, l.allocator)
			return
		}
		st := NTSTATUS(i32(e.Internal))
		events := Events{.Read}
		if st == STATUS_PIPE_BROKEN {
			events += {.Hangup}
			io.eof = true
		} else if st < 0 && st != STATUS_CANCELLED {
			events += {.Error}
			io.eof = true
		}
		_deliver(l, io.handle, events)
	case OVERLAPPED_KEY:
		op := _op_from(l, rawptr(e.lpOverlapped))
		if op == nil {
			return
		}
		op.issued = false
		op.status = u32(e.Internal)
		h := op.handle
		s := _slot_get(l, h, .Fd) if h != 0 else nil
		if s == nil || s.os.kind != .Overlapped || s.os.ocb == nil {
			_op_release(l, op)
			return
		}
		st := NTSTATUS(i32(op.status))
		err := Error.None
		if st == STATUS_CANCELLED {
			err = .Interrupted
		} else if st < 0 {
			err = _nterror(st)
		}
		op.handle = 0
		s.os.ocb(l, Watch(h), op, int(e.dwNumberOfBytesTransferred), err, s.data)
		_op_release(l, op)
	case WRITER_KEY:
		w := (^_Writer)(e.lpOverlapped)
		found := false
		for x in l.os.writers {
			if x == w {
				found = true
				break
			}
		}
		if !found {
			return
		}
		w.busy = false
		events := Events{.Write}
		status := e.dwNumberOfBytesTransferred
		if status != 0 {
			if _werror(status) == .Broken_Pipe {
				events += {.Hangup}
			} else {
				events += {.Error}
			}
		}
		_deliver(l, w.handle, events)
	case:
		s := _slot_get_any(l, u64(e.lpCompletionKey))
		if s == nil {
			return
		}
		#partial switch s.kind {
		case .Child:
			_dispatch(l, u64(e.lpCompletionKey), {})
		case .Fd:
			bits := e.dwNumberOfBytesTransferred
			if bits & SOCK_NOTIFY_EVENT_REMOVE != 0 {
				return
			}
			events: Events
			if bits & SOCK_NOTIFY_EVENT_IN != 0 {
				events += {.Read}
			}
			if bits & SOCK_NOTIFY_EVENT_OUT != 0 {
				events += {.Write}
			}
			if bits & SOCK_NOTIFY_EVENT_HANGUP != 0 {
				events += {.Hangup}
			}
			if bits & SOCK_NOTIFY_EVENT_ERR != 0 {
				events += {.Error}
			}
			if events != {} {
				_dispatch(l, u64(e.lpCompletionKey), events)
			}
		}
	}
}

@(private)
_slot_get_any :: proc "contextless" (l: ^Loop, h: u64) -> ^_Slot {
	idx := _handle_index(h)
	if h == WAKE_TAG || int(idx) >= len(l.slots) {
		return nil
	}
	s := &l.slots[idx]
	if s.gen != _handle_gen(h) {
		return nil
	}
	return s
}

@(private)
_deliver :: proc(l: ^Loop, h: u64, events: Events) {
	s := _slot_get(l, h, .Fd)
	if s == nil || s.os.kind != .Pipe {
		return
	}
	io := s.os.io
	w := s.os.writer
	_dispatch(l, h, events)
	s = _slot_get(l, h, .Fd)
	if s == nil {
		return
	}
	if .Read in events && .Read in s.events && s.os.io == io && io != nil && !io.pending && !io.eof {
		_io_arm(l, io)
	}
	if .Write in events && .Write in s.events && s.os.writer == w && w != nil && !w.busy && .Hangup not_in events && .Error not_in events {
		_writer_kick(w)
	}
}

@(private)
_io_find :: proc "contextless" (l: ^Loop, p: rawptr) -> int {
	for io, i in l.os.ios {
		if rawptr(io) == p {
			return i
		}
	}
	return -1
}

@(private)
_io_arm :: proc(l: ^Loop, io: ^_Io) {
	io.ov = {}
	io.pending = true
	if win.ReadFile(io.pipe, &io.ov, 0, nil, &io.ov) {
		if io.skip {
			io.pending = false
			append(&l.os.ready, _Ready{io.handle, {.Read}})
		}
		return
	}
	code := win.GetLastError()
	if code == ERROR_IO_PENDING {
		return
	}
	io.pending = false
	io.eof = true
	if code == ERROR_BROKEN_PIPE || code == ERROR_PIPE_NOT_CONNECTED {
		append(&l.os.ready, _Ready{io.handle, {.Read, .Hangup}})
	} else {
		append(&l.os.ready, _Ready{io.handle, {.Read, .Error}})
	}
}

@(private)
_writer_proc :: proc "system" (arg: rawptr) -> u32 {
	w := (^_Writer)(arg)
	for {
		win.WaitForSingleObject(w.arm, INFINITE)
		if intrinsics.atomic_load_explicit(&w.stop, .Acquire) != 0 {
			return 0
		}
		status: u32
		if !win.FlushFileBuffers(w.pipe) {
			status = win.GetLastError()
		}
		if intrinsics.atomic_load_explicit(&w.stop, .Acquire) != 0 {
			return 0
		}
		win.PostQueuedCompletionStatus(w.port, status, WRITER_KEY, (^win.OVERLAPPED)(w))
	}
}

@(private)
_writer_start :: proc(l: ^Loop, s: ^_Slot, fd: Fd, h: u64) -> Error {
	w, aerr := new(_Writer, l.allocator)
	if aerr != nil {
		return .No_Memory
	}
	w.port = l.os.port
	w.pipe = _h(fd)
	w.handle = h
	w.arm = win.CreateEventW(nil, false, false, nil)
	if w.arm == nil {
		free(w, l.allocator)
		return _last()
	}
	w.thread = win.CreateThread(nil, 64 * 1024, _writer_proc, w, 0, nil)
	if w.thread == nil {
		err := _last()
		win.CloseHandle(w.arm)
		free(w, l.allocator)
		return err
	}
	append(&l.os.writers, w)
	s.os.writer = w
	_writer_kick(w)
	return .None
}

@(private)
_writer_kick :: proc "contextless" (w: ^_Writer) {
	if w.busy {
		return
	}
	w.busy = true
	win.SetEvent(w.arm)
}

@(private)
_writer_stop :: proc(l: ^Loop, w: ^_Writer) {
	intrinsics.atomic_store_explicit(&w.stop, 1, .Release)
	win.SetEvent(w.arm)
	for {
		CancelSynchronousIo(w.thread)
		if win.WaitForSingleObject(w.thread, 5) == WAIT_OBJECT_0 {
			break
		}
	}
	win.CloseHandle(w.thread)
	win.CloseHandle(w.arm)
	for x, i in l.os.writers {
		if x == w {
			unordered_remove(&l.os.writers, i)
			break
		}
	}
	free(w, l.allocator)
}

@(private)
_pipe_read_start :: proc(l: ^Loop, s: ^_Slot, fd: Fd, h: u64) -> Error {
	pipe := _h(fd)
	if _handle_synchronous(pipe) {
		return .Unsupported
	}
	skip := true
	if win.CreateIoCompletionPort(pipe, l.os.port, PIPE_KEY, 0) == nil {
		if win.GetLastError() != ERROR_INVALID_PARAMETER {
			return _last()
		}
	}
	if !win.SetFileCompletionNotificationModes(pipe, FILE_SKIP_COMPLETION_PORT_ON_SUCCESS | FILE_SKIP_SET_EVENT_ON_HANDLE) {
		skip = false
	}
	io, aerr := new(_Io, l.allocator)
	if aerr != nil {
		return .No_Memory
	}
	io.handle = h
	io.pipe = pipe
	io.skip = skip
	append(&l.os.ios, io)
	s.os.io = io
	_io_arm(l, io)
	return .None
}

@(private)
_pipe_read_stop :: proc(l: ^Loop, s: ^_Slot) {
	io := s.os.io
	if io == nil {
		return
	}
	s.os.io = nil
	io.handle = 0
	if io.pending {
		win.CancelIoEx(io.pipe, &io.ov)
		return
	}
	if k := _io_find(l, io); k >= 0 {
		unordered_remove(&l.os.ios, k)
	}
	free(io, l.allocator)
}

@(private)
_sock_filter :: proc "contextless" (events: Events) -> u16 {
	f: u16
	if .Read in events {
		f |= SOCK_NOTIFY_EVENT_IN | SOCK_NOTIFY_EVENT_HANGUP
	}
	if .Write in events {
		f |= SOCK_NOTIFY_EVENT_OUT | SOCK_NOTIFY_EVENT_HANGUP
	}
	return f
}

@(private)
_sock_register :: proc(l: ^Loop, fd: Fd, events: Events, h: u64, op: u8) -> Error {
	if l.os.psn == nil {
		return .Unsupported
	}
	reg := Sock_Notify_Registration {
		socket  = uintptr(_h(fd)),
		key     = rawptr(uintptr(h)),
		filter  = _sock_filter(events),
		op      = op,
		trigger = SOCK_NOTIFY_TRIGGER_EDGE | SOCK_NOTIFY_TRIGGER_PERSISTENT,
	}
	if op == SOCK_NOTIFY_OP_ENABLE && reg.filter == 0 {
		reg.op = SOCK_NOTIFY_OP_DISABLE
	}
	code := l.os.psn(l.os.port, 1, &reg, 0, 0, nil, nil)
	if code != 0 {
		return _werror(code)
	}
	if reg.result != 0 {
		return _werror(reg.result)
	}
	if reg.op == SOCK_NOTIFY_OP_ENABLE {
		_sock_initial(l, fd, events, h)
	}
	return .None
}

@(private)
_sock_initial :: proc(l: ^Loop, fd: Fd, events: Events, h: u64) {
	pfd := win.WSA_POLLFD {
		fd = win.SOCKET(uintptr(_h(fd))),
	}
	if .Read in events {
		pfd.events |= win.POLLRDNORM
	}
	if .Write in events {
		pfd.events |= win.POLLWRNORM
	}
	if win.WSAPoll(&pfd, 1, 0) <= 0 {
		return
	}
	got: Events
	if pfd.revents & win.POLLRDNORM != 0 {
		got += {.Read}
	}
	if pfd.revents & win.POLLWRNORM != 0 {
		got += {.Write}
	}
	if pfd.revents & win.POLLHUP != 0 {
		got += {.Hangup}
	}
	if pfd.revents & win.POLLERR != 0 {
		got += {.Error}
	}
	if got != {} {
		append(&l.os.ready, _Ready{h, got})
	}
}

@(private)
_os_watch :: proc(l: ^Loop, fd: Fd, events: Events, h: u64) -> Error {
	s := &l.slots[_handle_index(h)]
	s.os = {}
	switch _handle_kind(_h(fd)) {
	case .Socket:
		s.os.kind = .Socket
		if l.os.psn == nil {
			return .Unsupported
		}
		return _sock_register(l, fd, events, h, SOCK_NOTIFY_OP_ENABLE)
	case .Pipe:
		s.os.kind = .Pipe
		if .Read in events {
			if err := _pipe_read_start(l, s, fd, h); err != .None {
				return err
			}
		}
		if .Write in events {
			if err := _writer_start(l, s, fd, h); err != .None {
				_pipe_read_stop(l, s)
				return err
			}
		}
		return .None
	case .Disk, .Char, .Other:
	}
	return .Unsupported
}

@(private)
_os_modify :: proc(l: ^Loop, fd: Fd, old, next: Events, h: u64) -> Error {
	s := &l.slots[_handle_index(h)]
	switch s.os.kind {
	case .Socket:
		return _sock_register(l, fd, next, h, SOCK_NOTIFY_OP_ENABLE)
	case .Pipe:
		if .Read in next && .Read not_in old {
			if err := _pipe_read_start(l, s, fd, h); err != .None {
				return err
			}
		}
		if .Read in old && .Read not_in next {
			_pipe_read_stop(l, s)
		}
		if .Write in next && .Write not_in old {
			if err := _writer_start(l, s, fd, h); err != .None {
				return err
			}
		}
		if .Write in old && .Write not_in next && s.os.writer != nil {
			_writer_stop(l, s.os.writer)
			s.os.writer = nil
		}
		return .None
	case .None, .Overlapped:
	}
	return .Unsupported
}

@(private)
_os_unwatch :: proc(l: ^Loop, fd: Fd, events: Events, h: u64) {
	if int(_handle_index(h)) >= len(l.slots) {
		return
	}
	s := &l.slots[_handle_index(h)]
	switch s.os.kind {
	case .Socket:
		_sock_register(l, fd, {}, h, SOCK_NOTIFY_OP_REMOVE)
	case .Pipe:
		_pipe_read_stop(l, s)
		if s.os.writer != nil {
			_writer_stop(l, s.os.writer)
			s.os.writer = nil
		}
	case .Overlapped:
		cancel := false
		for op in l.os.ops {
			if op.handle == h {
				op.handle = 0
				cancel ||= op.issued
			}
		}
		if cancel {
			win.CancelIoEx(s.os.ofile, nil)
		}
		i := 0
		for i < len(l.os.ops) {
			op := l.os.ops[i]
			if op.handle == 0 && !op.issued {
				_op_release(l, op)
				continue
			}
			i += 1
		}
	case .None:
	}
	s.os = {}
}

@(private)
FileReplaceCompletionInformation :: 61

@(private)
_Completion_Info :: struct {
	port: HANDLE,
	key:  uintptr,
}

watch_overlapped :: proc(l: ^Loop, fd: Fd, data: rawptr, cb: Overlapped_Proc) -> (Watch, Error) {
	if cb == nil {
		return 0, .Invalid
	}
	file := _h(fd)
	if _handle_synchronous(file) {
		return 0, .Unsupported
	}
	if win.CreateIoCompletionPort(file, l.os.port, OVERLAPPED_KEY, 0) == nil {
		if win.GetLastError() != ERROR_INVALID_PARAMETER {
			return 0, _last()
		}
		iosb: IO_STATUS_BLOCK
		info := _Completion_Info{l.os.port, uintptr(OVERLAPPED_KEY)}
		if st := NtSetInformationFile(file, &iosb, &info, size_of(info), FileReplaceCompletionInformation); st < 0 {
			return 0, _nterror(st)
		}
	}
	idx, gen, ok := _slot_alloc(l)
	if !ok {
		return 0, .No_Memory
	}
	s := &l.slots[idx]
	s.kind = .Fd
	s.fd = fd
	s.data = data
	s.os = {kind = .Overlapped, ocb = cb, ofile = file}
	return Watch(_handle(idx, gen)), .None
}

overlapped_begin :: proc(l: ^Loop, w: Watch, size: int) -> (^Overlapped_Op, Error) {
	s := _slot_get(l, u64(w), .Fd)
	if s == nil || s.os.kind != .Overlapped || size < 0 {
		return nil, .Invalid
	}
	op: ^Overlapped_Op
	for c, i in l.os.op_cache {
		if len(c.buf) == size {
			op = c
			unordered_remove(&l.os.op_cache, i)
			break
		}
	}
	if op == nil {
		n, aerr := new(Overlapped_Op, l.allocator)
		if aerr != nil {
			return nil, .No_Memory
		}
		if size > 0 {
			b, berr := make([]u8, size, l.allocator)
			if berr != nil {
				free(n, l.allocator)
				return nil, .No_Memory
			}
			n.buf = b
		}
		op = n
	}
	buf := op.buf
	op^ = {}
	op.buf = buf
	op.handle = u64(w)
	op.file = s.os.ofile
	op.index = len(l.os.ops)
	if _, aerr := append(&l.os.ops, op); aerr != nil {
		_op_free(l, op)
		return nil, .No_Memory
	}
	return op, .None
}

overlapped_ptr :: #force_inline proc "contextless" (op: ^Overlapped_Op) -> rawptr {
	return &op.ov
}

overlapped_submit :: proc(l: ^Loop, op: ^Overlapped_Op, ok: bool) -> Error {
	if ok {
		op.issued = true
		return .None
	}
	code := win.GetLastError()
	if code == ERROR_IO_PENDING {
		op.issued = true
		return .None
	}
	_op_release(l, op)
	return _werror(code)
}

overlapped_abort :: proc(l: ^Loop, op: ^Overlapped_Op) {
	if !op.issued {
		_op_release(l, op)
	}
}

@(private)
_op_from :: proc "contextless" (l: ^Loop, p: rawptr) -> ^Overlapped_Op {
	op := (^Overlapped_Op)(p)
	if op == nil || op.index < 0 || op.index >= len(l.os.ops) || l.os.ops[op.index] != op {
		return nil
	}
	return op
}

@(private)
_op_release :: proc(l: ^Loop, op: ^Overlapped_Op) {
	k := op.index
	if k >= 0 && k < len(l.os.ops) && l.os.ops[k] == op {
		last := len(l.os.ops) - 1
		l.os.ops[k] = l.os.ops[last]
		l.os.ops[k].index = k
		pop(&l.os.ops)
	}
	op.index = -1
	op.handle = 0
	if len(l.os.op_cache) < OP_CACHE {
		if _, err := append(&l.os.op_cache, op); err == nil {
			return
		}
	}
	_op_free(l, op)
}

@(private)
_op_free :: proc(l: ^Loop, op: ^Overlapped_Op) {
	if op.buf != nil {
		delete(op.buf, l.allocator)
	}
	free(op, l.allocator)
}

@(private)
PROCESS_QUERY_LIMITED_INFORMATION :: 0x1000

@(private)
_os_child_watch :: proc(l: ^Loop, s: ^_Slot, h: u64) -> Error {
	s.os = {}
	p := win.OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, false, u32(s.pid))
	if p == nil {
		code := win.GetLastError()
		if code == ERROR_INVALID_PARAMETER {
			return .No_Child
		}
		return _werror(code)
	}
	pkt: HANDLE
	if st := NtCreateWaitCompletionPacket(&pkt, GENERIC_ALL, nil); st < 0 {
		win.CloseHandle(p)
		return _nterror(st)
	}
	already: win.BOOLEAN
	if st := NtAssociateWaitCompletionPacket(pkt, l.os.port, p, rawptr(uintptr(h)), nil, 0, 0, &already); st < 0 {
		win.CloseHandle(pkt)
		win.CloseHandle(p)
		return _nterror(st)
	}
	s.os.process = p
	s.os.packet = pkt
	return .None
}

@(private)
_os_child_reap :: proc(l: ^Loop, idx: u32) -> (Exit_Status, bool) {
	s := &l.slots[idx]
	if s.os.process == nil {
		return {code = -1}, true
	}
	if win.WaitForSingleObject(s.os.process, 0) != WAIT_OBJECT_0 {
		already: win.BOOLEAN
		NtAssociateWaitCompletionPacket(s.os.packet, l.os.port, s.os.process, rawptr(uintptr(_handle(idx, s.gen))), nil, 0, 0, &already)
		return {}, false
	}
	code: u32
	if !win.GetExitCodeProcess(s.os.process, &code) {
		return {code = -1}, true
	}
	return {code = i32(code)}, true
}

@(private)
_os_child_release :: proc(l: ^Loop, s: ^_Slot) {
	if s.os.packet != nil {
		NtCancelWaitCompletionPacket(s.os.packet, true)
		win.CloseHandle(s.os.packet)
	}
	if s.os.process != nil {
		win.CloseHandle(s.os.process)
	}
	s.os = {}
}

ignore_sigpipe :: proc "contextless" () {
}

@(private)
_os_fd :: proc "contextless" (l: ^Loop) -> Fd {
	return _fd(l.os.port)
}

@(private)
_os_has_ready :: proc(l: ^Loop) -> bool {
	if len(l.os.ready) > 0 || l.os.stash_n > l.os.stash_pos {
		return true
	}
	got: u32
	if win.GetQueuedCompletionStatusEx(l.os.port, &l.os.entries[0], MAX_EVENTS, &got, 0, false) && got > 0 {
		l.os.stash_n = int(got)
		l.os.stash_pos = 0
		return true
	}
	return false
}

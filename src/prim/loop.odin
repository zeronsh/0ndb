#+build linux, darwin, windows
package prim

import "base:intrinsics"
import "base:runtime"

Event :: enum u8 {
	Read,
	Write,
	Hangup,
	Error,
}

Events :: bit_set[Event;u8]

Watch :: distinct u64
Timer :: distinct u64
Child_Watch :: distinct u64

Exit_Status :: struct {
	code:   i32,
	signal: i32,
}

Watch_Proc :: #type proc(l: ^Loop, fd: Fd, events: Events, data: rawptr)
Timer_Proc :: #type proc(l: ^Loop, data: rawptr)
Child_Proc :: #type proc(l: ^Loop, pid: Pid, status: Exit_Status, data: rawptr)
Wake_Proc :: #type proc(l: ^Loop, data: rawptr)

Loop :: struct {
	os:         _Loop_Os,
	slots:      [dynamic]_Slot,
	free_slot:  u32,
	timers:     [dynamic]_Timer_Slot,
	free_timer: u32,
	heap:       [dynamic]u32,
	pending:    [dynamic]u64,
	wake_cb:    Wake_Proc,
	wake_data:  rawptr,
	clock:      Clock,
	stopped:    bool,
	allocator:  runtime.Allocator,
}

@(private)
_Slot_Kind :: enum u8 {
	Free,
	Fd,
	Child,
}

@(private)
_Slot :: struct {
	data:      rawptr,
	watch_cb:  Watch_Proc,
	child_cb:  Child_Proc,
	fd:        Fd,
	pid:       Pid,
	gen:       u32,
	next_free: u32,
	kind:      _Slot_Kind,
	events:    Events,
	os:        _Slot_Os,
}

@(private)
_Timer_Slot :: struct {
	deadline:  i64,
	data:      rawptr,
	cb:        Timer_Proc,
	gen:       u32,
	pos:       i32,
	next_free: u32,
}

@(private)
WAKE_TAG :: u64(0)

@(private)
NO_SLOT :: ~u32(0)

loop_init :: proc(l: ^Loop, allocator := context.allocator) -> Error {
	l^ = {}
	l.allocator = allocator
	l.free_slot = NO_SLOT
	l.free_timer = NO_SLOT
	l.slots = make([dynamic]_Slot, allocator)
	l.timers = make([dynamic]_Timer_Slot, allocator)
	l.heap = make([dynamic]u32, allocator)
	l.pending = make([dynamic]u64, allocator)
	ignore_sigpipe()
	err := _os_init(l)
	if err != .None {
		_loop_free(l)
	}
	return err
}

loop_destroy :: proc(l: ^Loop) {
	for &s in l.slots {
		if s.kind == .Child {
			_os_child_release(l, &s)
		}
	}
	_os_destroy(l)
	_loop_free(l)
}

loop_on_wake :: proc(l: ^Loop, cb: Wake_Proc, data: rawptr) {
	l.wake_cb = cb
	l.wake_data = data
}

loop_set_clock :: proc(l: ^Loop, c: Clock) {
	l.clock = c
}

loop_now_ns :: proc(l: ^Loop) -> i64 {
	return clock_mono_ns(l.clock)
}

loop_timeout_ms :: proc(l: ^Loop) -> i64 {
	if len(l.pending) > 0 {
		return 0
	}
	if len(l.heap) == 0 {
		return -1
	}
	d := l.timers[l.heap[0]].deadline - loop_now_ns(l)
	if d <= 0 {
		return 0
	}
	return (d + 999_999) / 1_000_000
}

Timer_Info :: struct {
	deadline: i64,
	cb:       Timer_Proc,
	data:     rawptr,
}

loop_next_deadline :: proc "contextless" (l: ^Loop) -> (deadline: i64, ok: bool) {
	if len(l.heap) == 0 {
		return 0, false
	}
	return l.timers[l.heap[0]].deadline, true
}

loop_armed :: proc "contextless" (l: ^Loop) -> int {
	return len(l.heap)
}

loop_timer_info :: proc "contextless" (l: ^Loop, i: int) -> (info: Timer_Info, ok: bool) {
	if i < 0 || i >= len(l.heap) {
		return
	}
	t := l.timers[l.heap[i]]
	return Timer_Info{deadline = t.deadline, cb = t.cb, data = t.data}, true
}

loop_has_ready :: proc(l: ^Loop) -> bool {
	if len(l.pending) > 0 {
		return true
	}
	return _os_has_ready(l)
}

loop_fd :: proc "contextless" (l: ^Loop) -> Fd {
	return _os_fd(l)
}

loop_abandon :: proc(l: ^Loop) {
	for &s in l.slots {
		if s.kind == .Fd && s.fd >= 0 {
			close(s.fd)
		}
	}
	loop_destroy(l)
}

loop_stop :: proc "contextless" (l: ^Loop) {
	intrinsics.atomic_store_explicit(&l.stopped, true, .Release)
	wake(l)
}

loop_stopped :: proc "contextless" (l: ^Loop) -> bool {
	return intrinsics.atomic_load_explicit(&l.stopped, .Acquire)
}

loop_run :: proc(l: ^Loop) -> Error {
	intrinsics.atomic_store_explicit(&l.stopped, false, .Release)
	for !loop_stopped(l) {
		err := loop_step(l, true)
		if err != .None {
			return err
		}
	}
	return .None
}

loop_step :: proc(l: ^Loop, block := true) -> Error {
	timeout: i64 = -1
	if !block || len(l.pending) > 0 {
		timeout = 0
	} else if len(l.heap) > 0 {
		timeout = max(l.timers[l.heap[0]].deadline - loop_now_ns(l), 0)
	}
	err := _os_poll(l, timeout)
	if err == .Interrupted {
		err = .None
	}
	_run_pending(l)
	_run_timers(l)
	free_all(context.temp_allocator)
	return err
}

loop_idle :: proc "contextless" (l: ^Loop) -> bool {
	return len(l.heap) == 0 && len(l.pending) == 0
}

watch :: proc(l: ^Loop, fd: Fd, events: Events, data: rawptr, cb: Watch_Proc) -> (Watch, Error) {
	idx, gen, ok := _slot_alloc(l)
	if !ok {
		return 0, .No_Memory
	}
	s := &l.slots[idx]
	s.kind = .Fd
	s.fd = fd
	s.data = data
	s.watch_cb = cb
	s.events = events & {.Read, .Write}
	h := _handle(idx, gen)
	err := _os_watch(l, fd, s.events, h)
	if err != .None {
		_slot_free(l, idx)
		return 0, err
	}
	return Watch(h), .None
}

watch_modify :: proc(l: ^Loop, w: Watch, events: Events) -> Error {
	s := _slot_get(l, u64(w), .Fd)
	if s == nil {
		return .Invalid
	}
	next := events & {.Read, .Write}
	err := _os_modify(l, s.fd, s.events, next, u64(w))
	if err == .None {
		s.events = next
	}
	return err
}

unwatch :: proc(l: ^Loop, w: Watch) {
	s := _slot_get(l, u64(w), .Fd)
	if s == nil {
		return
	}
	_os_unwatch(l, s.fd, s.events, u64(w))
	_slot_free(l, _handle_index(u64(w)))
}

child_watch :: proc(l: ^Loop, pid: Pid, data: rawptr, cb: Child_Proc) -> (Child_Watch, Error) {
	idx, gen, ok := _slot_alloc(l)
	if !ok {
		return 0, .No_Memory
	}
	s := &l.slots[idx]
	s.kind = .Child
	s.pid = pid
	s.fd = INVALID_FD
	s.data = data
	s.child_cb = cb
	h := _handle(idx, gen)
	err := _os_child_watch(l, s, h)
	if err != .None {
		_slot_free(l, idx)
		return 0, err
	}
	return Child_Watch(h), .None
}

child_unwatch :: proc(l: ^Loop, cw: Child_Watch) {
	s := _slot_get(l, u64(cw), .Child)
	if s == nil {
		return
	}
	_os_child_release(l, s)
	_slot_free(l, _handle_index(u64(cw)))
}

timer :: proc(l: ^Loop, ms: i64, data: rawptr, cb: Timer_Proc) -> Timer {
	return timer_at(l, loop_now_ns(l) + max(ms, 0) * 1_000_000, data, cb)
}

timer_at :: proc(l: ^Loop, deadline_ns: i64, data: rawptr, cb: Timer_Proc) -> Timer {
	idx: u32
	if l.free_timer != NO_SLOT {
		idx = l.free_timer
		l.free_timer = l.timers[idx].next_free
	} else {
		if len(l.timers) >= int(NO_SLOT) {
			return 0
		}
		if _, err := append(&l.timers, _Timer_Slot{gen = 1}); err != nil {
			return 0
		}
		idx = u32(len(l.timers) - 1)
	}
	if _, err := append(&l.heap, idx); err != nil {
		l.timers[idx].next_free = l.free_timer
		l.free_timer = idx
		return 0
	}
	t := &l.timers[idx]
	t.deadline = deadline_ns
	t.data = data
	t.cb = cb
	t.pos = i32(len(l.heap) - 1)
	_heap_up(l, int(t.pos))
	return Timer(_handle(idx, t.gen))
}

timer_cancel :: proc(l: ^Loop, t: Timer) -> bool {
	idx := _handle_index(u64(t))
	if t == 0 || int(idx) >= len(l.timers) {
		return false
	}
	ts := &l.timers[idx]
	if ts.gen != _handle_gen(u64(t)) || ts.pos < 0 {
		return false
	}
	_heap_remove(l, int(ts.pos))
	_timer_free(l, idx)
	return true
}

timer_pending :: proc "contextless" (l: ^Loop, t: Timer) -> bool {
	idx := _handle_index(u64(t))
	if t == 0 || int(idx) >= len(l.timers) {
		return false
	}
	ts := &l.timers[idx]
	return ts.gen == _handle_gen(u64(t)) && ts.pos >= 0
}

@(private)
_loop_free :: proc(l: ^Loop) {
	delete(l.slots)
	delete(l.timers)
	delete(l.heap)
	delete(l.pending)
	l.slots = nil
	l.timers = nil
	l.heap = nil
	l.pending = nil
}

@(private)
_handle :: proc "contextless" (idx, gen: u32) -> u64 {
	return u64(gen) << 32 | u64(idx)
}

@(private)
_handle_index :: proc "contextless" (h: u64) -> u32 {
	return u32(h & 0xffff_ffff)
}

@(private)
_handle_gen :: proc "contextless" (h: u64) -> u32 {
	return u32(h >> 32)
}

@(private)
_next_gen :: proc "contextless" (gen: u32) -> u32 {
	g := gen + 1
	if g == 0 {
		g = 1
	}
	return g
}

@(private)
_slot_alloc :: proc(l: ^Loop) -> (idx: u32, gen: u32, ok: bool) {
	if l.free_slot != NO_SLOT {
		idx = l.free_slot
		l.free_slot = l.slots[idx].next_free
		return idx, l.slots[idx].gen, true
	}
	if len(l.slots) >= int(NO_SLOT) {
		return
	}
	if _, err := append(&l.slots, _Slot{gen = 1}); err != nil {
		return
	}
	return u32(len(l.slots) - 1), 1, true
}

@(private)
_slot_free :: proc(l: ^Loop, idx: u32) {
	s := &l.slots[idx]
	gen := _next_gen(s.gen)
	s^ = {}
	s.gen = gen
	s.fd = INVALID_FD
	s.next_free = l.free_slot
	l.free_slot = idx
}

@(private)
_slot_get :: proc "contextless" (l: ^Loop, h: u64, kind: _Slot_Kind) -> ^_Slot {
	if h == WAKE_TAG {
		return nil
	}
	idx := _handle_index(h)
	if int(idx) >= len(l.slots) {
		return nil
	}
	s := &l.slots[idx]
	if s.gen != _handle_gen(h) || s.kind != kind {
		return nil
	}
	return s
}

@(private)
_dispatch :: proc(l: ^Loop, h: u64, events: Events) {
	if h == WAKE_TAG {
		_os_wake_drain(l)
		if l.wake_cb != nil {
			l.wake_cb(l, l.wake_data)
		}
		return
	}
	idx := _handle_index(h)
	if int(idx) >= len(l.slots) {
		return
	}
	s := &l.slots[idx]
	if s.gen != _handle_gen(h) {
		return
	}
	#partial switch s.kind {
	case .Fd:
		if s.watch_cb != nil {
			s.watch_cb(l, s.fd, events, s.data)
		}
	case .Child:
		_child_exited(l, idx)
	}
}

@(private)
_child_exited :: proc(l: ^Loop, idx: u32) {
	s := &l.slots[idx]
	status, done := _os_child_reap(l, idx)
	if !done {
		return
	}
	pid := s.pid
	cb := s.child_cb
	data := s.data
	_os_child_release(l, s)
	_slot_free(l, idx)
	if cb != nil {
		cb(l, pid, status, data)
	}
}

@(private)
_run_pending :: proc(l: ^Loop) {
	for len(l.pending) > 0 {
		h := pop(&l.pending)
		if s := _slot_get(l, h, .Child); s != nil {
			_child_exited(l, _handle_index(h))
		}
	}
}

@(private)
_run_timers :: proc(l: ^Loop) {
	if len(l.heap) == 0 {
		return
	}
	now := loop_now_ns(l)
	for len(l.heap) > 0 && !loop_stopped(l) {
		idx := l.heap[0]
		t := &l.timers[idx]
		if t.deadline > now {
			break
		}
		cb := t.cb
		data := t.data
		_heap_remove(l, 0)
		_timer_free(l, idx)
		if cb != nil {
			cb(l, data)
		}
	}
}

@(private)
_timer_free :: proc(l: ^Loop, idx: u32) {
	t := &l.timers[idx]
	gen := _next_gen(t.gen)
	t^ = {}
	t.gen = gen
	t.pos = -1
	t.next_free = l.free_timer
	l.free_timer = idx
}

@(private)
_heap_less :: proc "contextless" (l: ^Loop, a, b: int) -> bool {
	return l.timers[l.heap[a]].deadline < l.timers[l.heap[b]].deadline
}

@(private)
_heap_swap :: proc "contextless" (l: ^Loop, a, b: int) {
	l.heap[a], l.heap[b] = l.heap[b], l.heap[a]
	l.timers[l.heap[a]].pos = i32(a)
	l.timers[l.heap[b]].pos = i32(b)
}

@(private)
_heap_up :: proc "contextless" (l: ^Loop, i: int) {
	j := i
	for j > 0 {
		parent := (j - 1) / 2
		if !_heap_less(l, j, parent) {
			break
		}
		_heap_swap(l, j, parent)
		j = parent
	}
}

@(private)
_heap_down :: proc "contextless" (l: ^Loop, i: int) {
	j := i
	n := len(l.heap)
	for {
		left := 2 * j + 1
		if left >= n {
			break
		}
		m := left
		if left + 1 < n && _heap_less(l, left + 1, left) {
			m = left + 1
		}
		if !_heap_less(l, m, j) {
			break
		}
		_heap_swap(l, j, m)
		j = m
	}
}

@(private)
_heap_remove :: proc(l: ^Loop, i: int) {
	last := len(l.heap) - 1
	l.timers[l.heap[i]].pos = -1
	if i != last {
		l.heap[i] = l.heap[last]
		l.timers[l.heap[i]].pos = i32(i)
	}
	pop(&l.heap)
	if i < len(l.heap) {
		_heap_down(l, i)
		_heap_up(l, i)
	}
}

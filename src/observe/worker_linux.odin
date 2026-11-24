#+build linux
package observe

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "core:thread"
import "../prim"

RING_SIZE :: 1 << 20

@(private)
Ring :: struct {
	buf:     []u8,
	head:    u64,
	tail:    u64,
	waiting: u32,
}

@(private)
_eventfd :: proc "contextless" () -> i32 {
	r := intrinsics.syscall(linux.SYS_eventfd2, 0, uintptr(0o2000000) | uintptr(0o4000))
	if _errno(r) != 0 {
		return -1
	}
	return i32(int(r))
}

@(private)
_efd_signal :: proc "contextless" (fd: i32) {
	one := u64(1)
	for {
		r := intrinsics.syscall(linux.SYS_write, uintptr(int(fd)), uintptr(&one), 8)
		if _errno(r) != EINTR {
			return
		}
	}
}

@(private)
_efd_drain :: proc "contextless" (fd: i32) {
	v: u64
	intrinsics.syscall(linux.SYS_read, uintptr(int(fd)), uintptr(&v), 8)
}

@(private)
_ring_put :: proc "contextless" (r: ^Ring, pos: u64, data: []u8) {
	mask := u64(len(r.buf) - 1)
	off := int(pos & mask)
	first := min(len(data), len(r.buf) - off)
	intrinsics.mem_copy_non_overlapping(&r.buf[off], raw_data(data), first)
	if first < len(data) {
		intrinsics.mem_copy_non_overlapping(&r.buf[0], &data[first], len(data) - first)
	}
}

@(private)
_ring_get :: proc "contextless" (r: ^Ring, pos: u64, out: []u8) {
	mask := u64(len(r.buf) - 1)
	off := int(pos & mask)
	first := min(len(out), len(r.buf) - off)
	intrinsics.mem_copy_non_overlapping(raw_data(out), &r.buf[off], first)
	if first < len(out) {
		intrinsics.mem_copy_non_overlapping(&out[first], &r.buf[0], len(out) - first)
	}
}

@(private)
_ring_push :: proc(t: ^Tree, rec: []u8) -> bool {
	r := &t.ring
	need := u64(4 + len(rec))
	if need > u64(len(r.buf)) {
		return false
	}
	head := intrinsics.atomic_load_explicit(&r.head, .Seq_Cst)
	tail: u64
	for {
		tail = intrinsics.atomic_load_explicit(&r.tail, .Seq_Cst)
		if u64(len(r.buf)) - (head - tail) >= need {
			break
		}
		_flush_wake(t)
		intrinsics.atomic_store_explicit(&r.waiting, 1, .Seq_Cst)
		intrinsics.atomic_thread_fence(.Seq_Cst)
		if u64(len(r.buf)) - (head - intrinsics.atomic_load_explicit(&r.tail, .Seq_Cst)) >= need {
			continue
		}
		pf := [2]Pollfd{{fd = t.space_fd, events = POLLIN}, {fd = t.stop_fd, events = POLLIN}}
		_sys_poll(&pf[0], 2, -1)
		if pf[1].revents != 0 {
			return false
		}
		_efd_drain(t.space_fd)
	}
	n := u32(len(rec))
	_ring_put(r, head, ([^]u8)(&n)[:4])
	_ring_put(r, head + 4, rec)
	intrinsics.atomic_store_explicit(&r.head, head + need, .Seq_Cst)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	t.unsignaled += 1
	if t.unsignaled >= WAKE_BATCH || (head + need - tail) * 2 > u64(len(r.buf)) {
		_flush_wake(t)
	}
	return true
}

WAKE_BATCH :: 256
WAKE_DELAY_MS :: 1

@(private)
_flush_wake :: proc(t: ^Tree) {
	if t.unsignaled == 0 {
		return
	}
	t.unsignaled = 0
	s := t.sup
	if intrinsics.atomic_exchange_explicit(&s.pending, 1, .Seq_Cst) == 0 {
		_efd_signal(s.wake_fd)
	}
}

@(private)
_stat_add :: #force_inline proc "contextless" (p: ^u64) {
	intrinsics.atomic_add_explicit(p, 1, .Relaxed)
}

@(private)
_worker_receive :: proc(t: ^Tree) -> bool {
	defer _efd_signal(t.ready_fd)
	pf := [2]Pollfd{{fd = t.sock, events = POLLIN}, {fd = t.stop_fd, events = POLLIN}}
	for {
		_, e := _sys_poll(&pf[0], 2, -1)
		if e != EINTR {
			break
		}
	}
	if pf[1].revents != 0 || pf[0].revents == 0 {
		return false
	}
	payload: [8]u8
	n, fd, e := _recv_fd(t.sock, payload[:])
	_sys_close(t.sock)
	t.sock = -1
	if e != 0 || n < 8 || fd < 0 {
		_sys_close(fd)
		return false
	}
	_sys_ioctl_val(fd, NOTIF_SET_FLAGS, uintptr(NOTIF_FD_SYNC_WAKE_UP))
	t.killable = payload[0] == 1
	t.root = prim.Pid((^i32)(&payload[4])^)
	intrinsics.atomic_store(&t.fd, fd)
	return true
}

@(private)
_worker_main :: proc(t: ^Tree) {
	if !_worker_receive(t) {
		intrinsics.atomic_store_explicit(&t.ended, 1, .Seq_Cst)
		return
	}
	for {
		pf := [4]Pollfd{{fd = t.fd, events = POLLIN}, {fd = t.stop_fd, events = POLLIN}, {fd = t.flush_fd, events = POLLIN}, {fd = t.gate_fd, events = POLLIN}}
		n, e := _sys_poll(&pf[0], 4, WAKE_DELAY_MS if t.unsignaled > 0 else -1)
		if e == EINTR {
			continue
		}
		if e != 0 || pf[1].revents != 0 {
			break
		}
		if n == 0 {
			_flush_wake(t)
			continue
		}
		if pf[2].revents != 0 {
			_efd_drain(t.flush_fd)
		}
		if pf[3].revents != 0 {
			_efd_drain(t.gate_fd)
			_release_parked(t.sup, t, false)
		}
		if intrinsics.atomic_exchange_explicit(&t.flush_req, 0, .Seq_Cst) != 0 {
			t.unsignaled += 1
			_flush_wake(t)
		}
		if pf[0].revents == 0 {
			continue
		}
		if pf[0].revents & POLLIN != 0 {
			if !_handle_one(t.sup, t) {
				break
			}
			runtime.free_all(context.temp_allocator)
			if intrinsics.atomic_exchange_explicit(&t.flush_req, 0, .Seq_Cst) != 0 {
				t.unsignaled += 1
				_flush_wake(t)
			}
			continue
		}
		if pf[0].revents & (POLLHUP | POLLERR | POLLNVAL) != 0 {
			break
		}
	}
	_release_parked(t.sup, t, true)
	intrinsics.atomic_store_explicit(&t.ended, 1, .Seq_Cst)
	t.unsignaled += 1
	_flush_wake(t)
}

@(private)
_worker_start :: proc(s: ^Supervisor, t: ^Tree) -> prim.Error {
	t.alloc = runtime.heap_allocator()
	t.stop_fd = _eventfd()
	t.space_fd = _eventfd()
	t.ready_fd = _eventfd()
	t.flush_fd = _eventfd()
	t.gate_fd = _eventfd()
	if t.stop_fd < 0 || t.space_fd < 0 || t.ready_fd < 0 || t.flush_fd < 0 || t.gate_fd < 0 {
		return .Too_Many_Files
	}
	buf, berr := make([]u8, RING_SIZE, t.alloc)
	if berr != nil {
		return .No_Memory
	}
	t.ring.buf = buf
	sc, serr := new(Scratch, t.alloc)
	if serr != nil {
		return .No_Memory
	}
	t.sc = sc
	_pcache_init(t)
	ctx := runtime.default_context()
	ctx.allocator = t.alloc
	th := thread.create_and_start_with_poly_data(t, _worker_main, ctx)
	if th == nil {
		return .No_Memory
	}
	t.thread = th
	return .None
}

@(private)
_worker_stop :: proc(t: ^Tree) {
	if t.thread != nil {
		_efd_signal(t.stop_fd)
		thread.join(t.thread)
		thread.destroy(t.thread)
		t.thread = nil
	}
}

@(private)
_worker_free :: proc(t: ^Tree) {
	_worker_stop(t)
	_pcache_destroy(t)
	if t.sc != nil {
		free(t.sc, t.alloc)
	}
	if t.ring.buf != nil {
		delete(t.ring.buf, t.alloc)
	}
	_sys_close(t.stop_fd)
	_sys_close(t.space_fd)
	_sys_close(t.ready_fd)
	_sys_close(t.flush_fd)
	_sys_close(t.gate_fd)
}

@(private)
_on_wake :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	s := (^Supervisor)(data)
	_efd_drain(s.wake_fd)
	intrinsics.atomic_store_explicit(&s.pending, 0, .Seq_Cst)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	if s.router.reg != nil {
		router_refresh(&s.router)
		_roots_publish(s)
	}
	for t, i in s.trees {
		if t == nil {
			continue
		}
		_ring_drain(s, t)
		if intrinsics.atomic_load_explicit(&t.ended, .Seq_Cst) == 1 {
			_ring_drain(s, t)
			s.trees[i] = nil
			_tree_free(s, t, true)
		}
	}
	_fences_run(s)
}

@(private)
_drain_all :: proc(s: ^Supervisor) {
	for t in s.trees {
		if t != nil {
			_ring_drain(s, t)
		}
	}
}

@(private)
_ring_drain :: proc(s: ^Supervisor, t: ^Tree) {
	r := &t.ring
	tail := intrinsics.atomic_load_explicit(&r.tail, .Seq_Cst)
	head := intrinsics.atomic_load_explicit(&r.head, .Seq_Cst)
	rec := make([dynamic]u8, context.temp_allocator)
	for tail < head {
		n: u32
		_ring_get(r, tail, ([^]u8)(&n)[:4])
		resize(&rec, int(n))
		_ring_get(r, tail + 4, rec[:])
		tail += 4 + u64(n)
		_deliver_record(s, rec[:])
		t.delivered = tail
		intrinsics.atomic_store_explicit(&r.tail, tail, .Seq_Cst)
		intrinsics.atomic_thread_fence(.Seq_Cst)
		if intrinsics.atomic_exchange_explicit(&r.waiting, 0, .Seq_Cst) == 1 {
			_efd_signal(t.space_fd)
		}
		head = intrinsics.atomic_load_explicit(&r.head, .Seq_Cst)
	}
}

@(private)
_encode_write :: proc(buf: ^[dynamic]u8, w: ^Write) {
	clear(buf)
	pw := prim.writer(buf)
	prim.write_u8(&pw, u8(w.op))
	prim.write_u8(&pw, u8(w.exact) | (2 if w.git else 0))
	prim.write_u32le(&pw, w.flags)
	prim.write_u32le(&pw, u32(w.tid))
	prim.write_u32le(&pw, u32(w.pid))
	prim.write_u32le(&pw, u32(w.tree))
	prim.write_u64le(&pw, w.dev)
	prim.write_u64le(&pw, u64(w.age))
	prim.write_uvarint(&pw, u64(len(w.lineage)))
	for p in w.lineage {
		prim.write_u32le(&pw, u32(p))
	}
	prim.write_str(&pw, w.path)
	prim.write_str(&pw, w.from)
	prim.write_bytes(&pw, w.args)
}

@(private)
_deliver_record :: proc(s: ^Supervisor, rec: []u8) {
	rd := prim.reader(rec)
	w: Write
	w.op = Op(prim.read_u8(&rd))
	bits := prim.read_u8(&rd)
	w.exact = bits & 1 != 0
	w.git = bits & 2 != 0
	w.flags = prim.read_u32le(&rd)
	w.tid = prim.Pid(i32(prim.read_u32le(&rd)))
	w.pid = prim.Pid(i32(prim.read_u32le(&rd)))
	w.tree = prim.Pid(i32(prim.read_u32le(&rd)))
	w.dev = prim.read_u64le(&rd)
	w.age = max(prim.mono_ns() - i64(prim.read_u64le(&rd)), 0)
	w.stamped = true
	n := int(prim.read_uvarint(&rd))
	if n > MAX_LINEAGE {
		return
	}
	pids: [MAX_LINEAGE]prim.Pid
	for i in 0 ..< n {
		pids[i] = prim.Pid(i32(prim.read_u32le(&rd)))
	}
	w.lineage = pids[:n]
	w.path = prim.read_str(&rd)
	w.from = prim.read_str(&rd)
	w.args = prim.read_bytes(&rd)
	if !prim.reader_ok(&rd) {
		return
	}
	deliver(&s.router, s.sink, &w)
}

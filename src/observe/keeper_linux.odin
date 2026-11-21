#+build linux
package observe

import "base:intrinsics"
import "core:sys/linux"
import "../prim"

KEEPER_SLOTS :: 4096

@(private)
KEEPER_ADD :: u32(1)
@(private)
KEEPER_DEL :: u32(2)

Keeper :: struct {
	ctl:     i32,
	watch:   prim.Watch,
	started: bool,
	spawns:  u64,
}

@(private)
Keeper_Msg :: struct {
	kind: u32,
	slot: u32,
}

@(private)
_keeper_ensure :: proc(s: ^Supervisor) {
	if s.keeper.ctl >= 0 {
		return
	}
	sock: [2]i32
	r := intrinsics.syscall(linux.SYS_socketpair, 1, uintptr(5) | uintptr(0o2000000), 0, uintptr(&sock))
	if _errno(r) != 0 {
		return
	}
	sh := s.shared
	pid, ferr := linux.fork()
	if ferr != .NONE {
		_sys_close(sock[0])
		_sys_close(sock[1])
		return
	}
	if pid == 0 {
		inner, ierr := linux.fork()
		if ierr == .NONE && inner == 0 {
			_keeper_main(sock[1], sh)
		}
		linux.exit_group(0)
	}
	_sys_close(sock[1])
	st: u32
	for {
		_, werr := linux.wait4(pid, &st, {}, nil)
		if werr != .EINTR {
			break
		}
	}
	if st != 0 {
		_sys_close(sock[0])
		return
	}
	s.keeper.ctl = sock[0]
	s.keeper.started = true
	s.keeper.spawns += 1
	w, werr := prim.watch(s.loop, prim.Fd(sock[0]), {.Read}, s, _on_keeper)
	if werr == .None {
		s.keeper.watch = w
	}
	for t in s.trees {
		if t != nil {
			_keeper_add(s, t)
		}
	}
}

@(private)
_on_keeper :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	s := (^Supervisor)(data)
	if .Hangup not_in events && .Error not_in events {
		return
	}
	_keeper_detach(s)
	if s.opts.keeper && s.live > 0 {
		_keeper_ensure(s)
	}
}

@(private)
_keeper_detach :: proc(s: ^Supervisor) {
	if s.keeper.watch != 0 && s.loop != nil {
		prim.unwatch(s.loop, s.keeper.watch)
	}
	s.keeper.watch = 0
	_sys_close(s.keeper.ctl)
	s.keeper.ctl = -1
}

@(private)
_keeper_add :: proc(s: ^Supervisor, t: ^Tree) {
	if s.keeper.ctl < 0 {
		return
	}
	m := Keeper_Msg{KEEPER_ADD, t.slot}
	if _send_fd(s.keeper.ctl, t.fd, ([^]u8)(&m)[:size_of(m)]) != 0 {
		_keeper_detach(s)
	}
}

@(private)
_keeper_del :: proc(s: ^Supervisor, t: ^Tree) {
	if s.keeper.ctl < 0 {
		return
	}
	m := Keeper_Msg{KEEPER_DEL, t.slot}
	if _send_fd(s.keeper.ctl, -1, ([^]u8)(&m)[:size_of(m)]) != 0 {
		_keeper_detach(s)
	}
}

@(private)
_kmap :: proc "contextless" (size: uintptr) -> rawptr {
	r := intrinsics.syscall(linux.SYS_mmap, 0, size, uintptr(0x3), uintptr(0x22), ~uintptr(0), 0)
	if _errno(r) != 0 {
		linux.exit_group(1)
	}
	return rawptr(r)
}

@(private)
_keeper_main :: proc "contextless" (ctl: i32, sh: [^]Shared) -> ! {
	intrinsics.syscall(linux.SYS_setsid)
	r := intrinsics.syscall(linux.SYS_close_range, 0, uintptr(ctl - 1), 0) if ctl > 0 else 0
	r2 := intrinsics.syscall(linux.SYS_close_range, uintptr(ctl + 1), ~uintptr(0) >> 1, 0)
	if _errno(r) != 0 || _errno(r2) != 0 {
		for fd in 0 ..< i32(65536) {
			if fd != ctl {
				_sys_close(fd)
			}
		}
	}
	fds := ([^]i32)(_kmap(KEEPER_SLOTS * size_of(i32)))
	pf := ([^]Pollfd)(_kmap(KEEPER_SLOTS * size_of(Pollfd)))
	who := ([^]u32)(_kmap(KEEPER_SLOTS * size_of(u32)))
	hi := u32(0)
	for {
		m: Keeper_Msg
		n, fd, e := _recv_fd(ctl, ([^]u8)(&m)[:size_of(m)])
		if e != 0 || n == 0 {
			_sys_close(fd)
			break
		}
		if n != size_of(m) || m.slot >= KEEPER_SLOTS {
			_sys_close(fd)
			continue
		}
		#no_bounds_check {
			if fds[m.slot] > 0 {
				_sys_close(fds[m.slot] - 1)
				fds[m.slot] = 0
			}
			if m.kind == KEEPER_ADD && fd >= 0 {
				fds[m.slot] = fd + 1
				if m.slot + 1 > hi {
					hi = m.slot + 1
				}
			} else {
				_sys_close(fd)
			}
		}
	}
	_sys_close(ctl)
	#no_bounds_check {
		for slot in 0 ..< hi {
			if fds[slot] <= 0 || intrinsics.volatile_load(&sh[slot].state) != 1 {
				continue
			}
			n := (^Notif)(&sh[slot].notif)
			if n.id != 0 {
				resp := Notif_Resp {
					id    = n.id,
					flags = NOTIF_FLAG_CONTINUE,
				}
				_sys_ioctl(fds[slot] - 1, NOTIF_SEND, &resp)
			}
		}
	}
	buf: [NOTIF_BUF]u8
	for {
		count := 0
		#no_bounds_check for i in 0 ..< hi {
			if fds[i] > 0 {
				pf[count] = Pollfd{fd = fds[i] - 1, events = POLLIN}
				who[count] = i
				count += 1
			}
		}
		if count == 0 {
			linux.exit_group(0)
		}
		_, pe := _sys_poll(pf, count, -1)
		if pe != 0 {
			continue
		}
		#no_bounds_check for i in 0 ..< count {
			ev := pf[i].revents
			if ev & POLLIN != 0 {
				intrinsics.mem_zero(&buf, NOTIF_BUF)
				if _sys_ioctl(pf[i].fd, NOTIF_RECV, &buf) == 0 {
					n := (^Notif)(&buf)
					resp := Notif_Resp {
						id    = n.id,
						flags = NOTIF_FLAG_CONTINUE,
					}
					_sys_ioctl(pf[i].fd, NOTIF_SEND, &resp)
				}
				continue
			}
			if ev & (POLLHUP | POLLERR | POLLNVAL) != 0 {
				_sys_close(pf[i].fd)
				fds[who[i]] = 0
			}
		}
	}
}

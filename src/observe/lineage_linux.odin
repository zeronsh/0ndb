#+build linux
package observe

import "base:intrinsics"
import "base:runtime"
import "core:strconv"
import "core:sys/linux"
import "../prim"

@(private)
NETLINK_CONNECTOR :: 11
@(private)
CN_IDX_PROC :: u32(1)
@(private)
PROC_CN_MCAST_LISTEN :: u32(1)
@(private)
PROC_EVENT_FORK :: u32(0x1)
@(private)
PROC_EVENT_EXIT :: u32(0x80000000)
@(private)
NLMSG_DONE :: u16(3)

@(private)
Proc_Entry :: struct {
	ppid:  prim.Pid,
	dead:  bool,
	epoch: u64,
}

Lineage_Table :: struct {
	fd:        i32,
	watch:     prim.Watch,
	procs:     map[prim.Pid]Proc_Entry,
	dying:     [dynamic]prim.Pid,
	epoch:     u64,
	lost:      bool,
	allocator: runtime.Allocator,
	buf:       []u8,
}

lineage_open :: proc(t: ^Lineage_Table, allocator := context.allocator) -> prim.Error {
	t^ = {
		fd        = -1,
		allocator = allocator,
	}
	r := intrinsics.syscall(linux.SYS_socket, 16, uintptr(2) | uintptr(0o2000000) | uintptr(0o4000), NETLINK_CONNECTOR)
	if e := _errno(r); e != 0 {
		return _map_errno(linux.Errno(e))
	}
	fd := i32(int(r))
	Sockaddr_Nl :: struct {
		family: u16,
		pad:    u16,
		pid:    u32,
		groups: u32,
	}
	sa := Sockaddr_Nl{family = 16, groups = CN_IDX_PROC}
	if e := _errno(intrinsics.syscall(linux.SYS_bind, uintptr(int(fd)), uintptr(&sa), size_of(sa))); e != 0 {
		_sys_close(fd)
		return _map_errno(linux.Errno(e))
	}
	Listen :: struct #packed {
		nl_len:   u32,
		nl_type:  u16,
		nl_flags: u16,
		nl_seq:   u32,
		nl_pid:   u32,
		idx:      u32,
		val:      u32,
		seq:      u32,
		ack:      u32,
		len:      u16,
		flags:    u16,
		op:       u32,
	}
	msg := Listen {
		nl_len  = size_of(Listen),
		nl_type = NLMSG_DONE,
		idx     = CN_IDX_PROC,
		val     = 1,
		len     = 4,
		op      = PROC_CN_MCAST_LISTEN,
	}
	if e := _errno(intrinsics.syscall(linux.SYS_sendto, uintptr(int(fd)), uintptr(&msg), size_of(msg), 0, 0, 0)); e != 0 {
		_sys_close(fd)
		return _map_errno(linux.Errno(e))
	}
	rcv := i32(4 << 20)
	intrinsics.syscall(linux.SYS_setsockopt, uintptr(int(fd)), 1, 8, uintptr(&rcv), size_of(rcv))
	t.fd = fd
	t.procs = make(map[prim.Pid]Proc_Entry, allocator)
	t.dying = make([dynamic]prim.Pid, allocator)
	buf, berr := make([]u8, 64 * 1024, allocator)
	if berr != nil {
		lineage_close(t)
		return .No_Memory
	}
	t.buf = buf
	_lineage_scan(t)
	return .None
}

lineage_close :: proc(t: ^Lineage_Table) {
	_sys_close(t.fd)
	delete(t.procs)
	delete(t.dying)
	if t.buf != nil {
		delete(t.buf, t.allocator)
	}
	t^ = {}
	t.fd = -1
}

@(private)
_lineage_scan :: proc(t: ^Lineage_Table) {
	d: prim.Dir
	if prim.dir_open(prim.os_vfs(), &d, "/proc", context.temp_allocator) != .None {
		return
	}
	defer prim.dir_close(prim.os_vfs(), &d)
	buf: [1024]u8
	for {
		e, ok, err := prim.dir_next(prim.os_vfs(), &d)
		if err != .None || !ok {
			break
		}
		v, vok := strconv.parse_int(e.name, 10)
		if !vok || v <= 0 {
			continue
		}
		pid := prim.Pid(v)
		if ppid, pok := _stat_ppid(pid, buf[:]); pok {
			t.procs[pid] = Proc_Entry{ppid = ppid}
		}
	}
}

lineage_drain :: proc(t: ^Lineage_Table) {
	if t.fd < 0 {
		return
	}
	for {
		r := intrinsics.syscall(linux.SYS_recvfrom, uintptr(int(t.fd)), uintptr(raw_data(t.buf)), uintptr(len(t.buf)), 0, 0, 0)
		e := _errno(r)
		if e == EINTR {
			continue
		}
		if e == 105 {
			t.lost = true
			clear(&t.procs)
			_lineage_scan(t)
			continue
		}
		if e != 0 {
			return
		}
		_lineage_parse(t, t.buf[:int(r)])
	}
}

@(private)
_lineage_parse :: proc(t: ^Lineage_Table, data: []u8) {
	off := 0
	for off + 16 <= len(data) {
		nl_len := int(prim.get_u32le(data[off:]))
		if nl_len < 16 || off + nl_len > len(data) {
			return
		}
		msg := data[off + 16:off + nl_len]
		off += (nl_len + 3) &~ 3
		if len(msg) < 20 + 16 {
			continue
		}
		ev := msg[20:]
		what := prim.get_u32le(ev[0:])
		body := ev[16:]
		switch what {
		case PROC_EVENT_FORK:
			if len(body) < 16 {
				continue
			}
			parent_tgid := prim.Pid(i32(prim.get_u32le(body[4:])))
			child_pid := prim.Pid(i32(prim.get_u32le(body[8:])))
			child_tgid := prim.Pid(i32(prim.get_u32le(body[12:])))
			if child_pid != child_tgid {
				continue
			}
			t.procs[child_tgid] = Proc_Entry{ppid = parent_tgid}
		case PROC_EVENT_EXIT:
			if len(body) < 8 {
				continue
			}
			pid := prim.Pid(i32(prim.get_u32le(body[0:])))
			tgid := prim.Pid(i32(prim.get_u32le(body[4:])))
			if pid != tgid {
				continue
			}
			if p, ok := &t.procs[tgid]; ok && !p.dead {
				p.dead = true
				p.epoch = t.epoch
				append(&t.dying, tgid)
			}
		}
	}
}

lineage_epoch_begin :: proc(t: ^Lineage_Table) -> u64 {
	t.epoch += 1
	return t.epoch
}

lineage_epoch_end :: proc(t: ^Lineage_Table, began: u64) {
	i := 0
	for i < len(t.dying) {
		pid := t.dying[i]
		p, ok := t.procs[pid]
		if !ok || !p.dead {
			unordered_remove(&t.dying, i)
			continue
		}
		if p.epoch < began {
			delete_key(&t.procs, pid)
			unordered_remove(&t.dying, i)
			continue
		}
		i += 1
	}
}

lineage_of :: proc(t: ^Lineage_Table, pid: prim.Pid, out: []prim.Pid) -> []prim.Pid {
	if len(out) == 0 {
		return nil
	}
	if _, ok := t.procs[pid]; !ok && t.fd >= 0 {
		lineage_drain(t)
	}
	n := 0
	cur := pid
	buf: [1024]u8
	for n < len(out) && cur > 1 {
		out[n] = cur
		n += 1
		if p, ok := t.procs[cur]; ok {
			cur = p.ppid
			continue
		}
		ppid, pok := _stat_ppid(cur, buf[:])
		if !pok {
			break
		}
		cur = ppid
	}
	return out[:n]
}

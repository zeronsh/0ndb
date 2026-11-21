#+build linux
package observe

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "../fs"
import "../prim"

@(private)
SECCOMP_SET_MODE_FILTER :: uintptr(1)
@(private)
SECCOMP_GET_NOTIF_SIZES :: uintptr(3)
@(private)
FILTER_FLAG_NEW_LISTENER :: uintptr(1 << 3)
@(private)
FILTER_FLAG_WAIT_KILLABLE_RECV :: uintptr(1 << 5)
@(private)
NOTIF_RECV :: uintptr(0xc0502100)
@(private)
NOTIF_SEND :: uintptr(0xc0182101)
@(private)
NOTIF_ID_VALID :: uintptr(0x40082102)
@(private)
NOTIF_SET_FLAGS :: uintptr(0x40082104)
@(private)
NOTIF_FD_SYNC_WAKE_UP :: u64(1)
@(private)
NOTIF_FLAG_CONTINUE :: u32(1)
@(private)
PR_SET_NO_NEW_PRIVS :: uintptr(38)
@(private)
PR_SET_CHILD_SUBREAPER :: uintptr(36)

NOTIF_BUF :: 256

Seccomp_Data :: struct {
	nr:   i32,
	arch: u32,
	ip:   u64,
	args: [6]u64,
}

Notif :: struct {
	id:    u64,
	pid:   u32,
	flags: u32,
	data:  Seccomp_Data,
}

Notif_Resp :: struct {
	id:    u64,
	val:   i64,
	error: i32,
	flags: u32,
}

@(private)
Notif_Sizes :: struct {
	notif: u16,
	resp:  u16,
	data:  u16,
}

Shared :: struct #align (64) {
	state: u32,
	slot:  u32,
	_pad:  [56]u8,
	notif: [NOTIF_BUF]u8,
}

Subreaper :: enum u8 {
	Auto,
	Always,
	Never,
}

Supervisor_Options :: struct {
	subreaper:     Subreaper,
	no_new_privs:  bool,
	keeper:        bool,
}

DEFAULT_SUPERVISOR :: Supervisor_Options {
	subreaper    = .Auto,
	no_new_privs = true,
	keeper       = true,
}


Tree :: struct {
	sup:      ^Supervisor,
	slot:     u32,
	fd:       i32,
	root:     prim.Pid,
	watch:    prim.Watch,
	killable: bool,
	moved:    bool,
}

@(private)
Scratch :: struct {
	arg:     [prim.PATH_MAX + 1]u8,
	arg2:    [prim.PATH_MAX + 1]u8,
	out:     [prim.PATH_MAX * 2]u8,
	out2:    [prim.PATH_MAX * 2]u8,
	tmp:     [prim.PATH_MAX * 2]u8,
	file:    [4096]u8,
	lineage: [MAX_LINEAGE]prim.Pid,
}

Supervisor :: struct {
	loop:       ^prim.Loop,
	allocator:  runtime.Allocator,
	router:     Router,
	sink:       Sink,
	opts:       Supervisor_Options,
	subreaper:  bool,
	prog:       []Insn,
	trees:      [dynamic]^Tree,
	live:       int,
	shared:     ^Shared,
	keeper:     Keeper,
	self:       prim.Pid,
	mnt_ns:     [64]u8,
	mnt_ns_len: int,
	has_openat2: bool,
	root_fd:    i32,
	pc:         Pcache,
	sc:         ^Scratch,
	stats:      Stats,
}

supervisor_init :: proc(s: ^Supervisor, loop: ^prim.Loop, opts := DEFAULT_SUPERVISOR, allocator := context.allocator) -> prim.Error {
	s^ = {
		loop      = loop,
		allocator = allocator,
		opts      = opts,
	}
	s.keeper.ctl = -1
	s.root_fd = -1
	when !NATIVE_SUPPORTED {
		return .Unsupported
	}
	sizes: Notif_Sizes
	r := intrinsics.syscall(linux.SYS_seccomp, SECCOMP_GET_NOTIF_SIZES, 0, uintptr(&sizes))
	if _errno(r) != 0 {
		return .Unsupported
	}
	if int(sizes.notif) > NOTIF_BUF || int(sizes.data) < size_of(Seccomp_Data) || int(sizes.resp) < size_of(Notif_Resp) {
		return .Unsupported
	}
	yama := _yama_scope()
	if yama >= 2 {
		return .Permission
	}
	switch opts.subreaper {
	case .Auto:
		s.subreaper = yama == 1
	case .Always:
		s.subreaper = true
	case .Never:
		s.subreaper = false
	}
	prog, ok := build_filter(allocator)
	if !ok {
		return .Unsupported
	}
	s.prog = prog
	mem := intrinsics.syscall(linux.SYS_mmap, 0, uintptr(size_of(Shared)), uintptr(0x3), uintptr(0x21), ~uintptr(0), 0)
	if _errno(mem) != 0 {
		delete(s.prog, allocator)
		return .No_Memory
	}
	s.shared = (^Shared)(rawptr(mem))
	sc, serr := new(Scratch, allocator)
	if serr != nil {
		supervisor_destroy(s)
		return .No_Memory
	}
	s.sc = sc
	s.self = prim.Pid(linux.getpid())
	pp: Proc_Path
	n, e := _sys_readlinkat(AT_FDCWD, _pp_proc(&pp, i64(s.self), "/ns/mnt"), s.mnt_ns[:])
	if e == 0 && n > 0 && n < len(s.mnt_ns) {
		s.mnt_ns_len = n
	}
	how := Open_How {
		flags = u64(SYS_O_PATH | SYS_O_CLOEXEC),
	}
	if fd, oe := _sys_openat2(AT_FDCWD, "/", &how); oe == 0 {
		_sys_close(fd)
		s.has_openat2 = true
	}
	rfd, re := _sys_openat(AT_FDCWD, "/", SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
	if re != 0 {
		supervisor_destroy(s)
		return .Io
	}
	s.root_fd = rfd
	_pcache_init(s)
	router_init(&s.router, allocator)
	s.trees = make([dynamic]^Tree, allocator)
	return .None
}

supervisor_destroy :: proc(s: ^Supervisor) {
	for t, i in s.trees {
		if t == nil {
			continue
		}
		_tree_free(s, t, false)
		s.trees[i] = nil
	}
	_keeper_detach(s)
	delete(s.trees)
	router_destroy(&s.router)
	_pcache_destroy(s)
	_sys_close(s.root_fd)
	if s.sc != nil {
		free(s.sc, s.allocator)
	}
	if s.prog != nil {
		delete(s.prog, s.allocator)
	}
	if s.shared != nil {
		intrinsics.syscall(linux.SYS_munmap, uintptr(s.shared), uintptr(size_of(Shared)))
	}
	s^ = {}
	s.keeper.ctl = -1
	s.root_fd = -1
}

supervisor_set_sink :: proc(s: ^Supervisor, sink: Sink) {
	s.sink = sink
}

supervisor_stats :: proc(s: ^Supervisor) -> Stats {
	return s.stats
}

supervisor_trees :: proc(s: ^Supervisor) -> int {
	return s.live
}

write_observer :: proc(s: ^Supervisor) -> fs.Write_Observer {
	return fs.Write_Observer{data = s, start = _observer_start, stop = _observer_stop}
}

@(private)
_observer_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	s := (^Supervisor)(data)
	router_bind(&s.router, reg)
	return .None
}

@(private)
_observer_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	s := (^Supervisor)(data)
	if s.router.reg == reg {
		router_bind(&s.router, nil)
	}
}

@(private)
_yama_scope :: proc() -> int {
	buf: [16]u8
	n, ok := _read_small("/proc/sys/kernel/yama/ptrace_scope", buf[:])
	if !ok || n == 0 {
		return 0
	}
	return int(buf[0] - '0')
}

Observation :: enum u8 {
	Observed,
	Unobserved,
}

Spawn_Options :: struct {
	cwd:               string,
	env:               []string,
	new_process_group: bool,
	pipes:             prim.Pipes,
	observation:       Observation,
	allow_setuid:      bool,
}

DEFAULT_SPAWN :: Spawn_Options {
	pipes = prim.ALL_PIPES,
}

spawn :: proc(
	s: ^Supervisor,
	argv: []string,
	cwd := "",
	env: []string = nil,
	new_process_group := false,
	pipes := prim.ALL_PIPES,
) -> (
	prim.Child,
	prim.Error,
) {
	return spawn_with(s, argv, Spawn_Options{cwd = cwd, env = env, new_process_group = new_process_group, pipes = pipes})
}

@(private)
Install :: struct {
	prog:      Fprog,
	sock:      i32,
	subreaper: bool,
	nnp:       bool,
}

spawn_with :: proc(s: ^Supervisor, argv: []string, opts: Spawn_Options) -> (child: prim.Child, err: prim.Error) {
	if opts.observation == .Unobserved {
		return prim.spawn(argv, opts.cwd, opts.env, opts.new_process_group, opts.pipes)
	}
	child = {
		stdin  = prim.INVALID_FD,
		stdout = prim.INVALID_FD,
		stderr = prim.INVALID_FD,
	}
	if s.prog == nil || s.loop == nil || len(argv) == 0 {
		return child, .Invalid
	}
	nnp := s.opts.no_new_privs && !opts.allow_setuid
	if !nnp && !has_cap_sys_admin() {
		return child, .Permission
	}
	if s.opts.keeper {
		_keeper_ensure(s)
	}
	slot := _slot_alloc(s) or_return
	sock: [2]i32 = {-1, -1}
	if e := _errno(intrinsics.syscall(linux.SYS_socketpair, 1, uintptr(5) | uintptr(0o2000000), 0, uintptr(&sock))); e != 0 {
		return child, _map_errno(linux.Errno(e))
	}
	install := Install {
		prog      = Fprog{u16(len(s.prog)), raw_data(s.prog)},
		sock      = sock[1],
		subreaper = s.subreaper,
		nnp       = nnp,
	}
	child, err = prim.spawn(argv, opts.cwd, opts.env, opts.new_process_group, opts.pipes, prim.Pre_Exec{&install, _install})
	_sys_close(sock[1])
	if err != .None {
		_sys_close(sock[0])
		return child, err
	}
	listener, killable := _recv_listener(sock[0])
	_sys_close(sock[0])
	if listener < 0 {
		prim.kill_process(child.pid, .Kill)
		prim.reap(child.pid, true)
		prim.child_close(&child)
		return child, .Io
	}
	t, terr := new(Tree, s.allocator)
	if terr != nil {
		_sys_close(listener)
		prim.kill_process(child.pid, .Kill)
		prim.reap(child.pid, true)
		prim.child_close(&child)
		return child, .No_Memory
	}
	t^ = {
		sup      = s,
		slot     = slot,
		fd       = listener,
		root     = child.pid,
		killable = killable,
	}
	_sys_ioctl_val(listener, NOTIF_SET_FLAGS, uintptr(NOTIF_FD_SYNC_WAKE_UP))
	w, werr := prim.watch(s.loop, prim.Fd(listener), {.Read}, t, _on_listener)
	if werr != .None {
		free(t, s.allocator)
		_sys_close(listener)
		prim.kill_process(child.pid, .Kill)
		prim.reap(child.pid, true)
		prim.child_close(&child)
		return child, werr
	}
	t.watch = w
	s.trees[slot] = t
	s.live += 1
	_keeper_add(s, t)
	return child, .None
}

@(private)
_install :: proc "contextless" (data: rawptr) -> i32 {
	c := (^Install)(data)
	if c.subreaper {
		intrinsics.syscall(linux.SYS_prctl, PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)
	}
	if c.nnp {
		if e := _errno(intrinsics.syscall(linux.SYS_prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)); e != 0 {
			return i32(e)
		}
	}
	killable := u8(1)
	r := intrinsics.syscall(linux.SYS_seccomp, SECCOMP_SET_MODE_FILTER, FILTER_FLAG_NEW_LISTENER | FILTER_FLAG_WAIT_KILLABLE_RECV, uintptr(&c.prog))
	if _errno(r) == EINVAL {
		killable = 0
		r = intrinsics.syscall(linux.SYS_seccomp, SECCOMP_SET_MODE_FILTER, FILTER_FLAG_NEW_LISTENER, uintptr(&c.prog))
	}
	if e := _errno(r); e != 0 {
		return i32(e)
	}
	listener := i32(int(r))
	payload := [4]u8{killable, 0, 0, 0}
	e := _send_fd(c.sock, listener, payload[:])
	_sys_close(listener)
	_sys_close(c.sock)
	return i32(e)
}

@(private)
_slot_alloc :: proc(s: ^Supervisor) -> (u32, prim.Error) {
	for t, i in s.trees {
		if t == nil {
			return u32(i), .None
		}
	}
	if len(s.trees) >= KEEPER_SLOTS {
		return 0, .Too_Many_Files
	}
	if _, err := append(&s.trees, nil); err != nil {
		return 0, .No_Memory
	}
	return u32(len(s.trees) - 1), .None
}

@(private)
_tree_free :: proc(s: ^Supervisor, t: ^Tree, notify_keeper: bool) {
	if t.watch != 0 && s.loop != nil {
		prim.unwatch(s.loop, t.watch)
	}
	if notify_keeper {
		_keeper_del(s, t)
	}
	_sys_close(t.fd)
	s.live -= 1
	free(t, s.allocator)
}

@(private)
_map_errno :: proc "contextless" (e: linux.Errno) -> prim.Error {
	#partial switch e {
	case .NONE:
		return .None
	case .ENOENT:
		return .Not_Found
	case .EEXIST:
		return .Exists
	case .EACCES, .EPERM:
		return .Permission
	case .EAGAIN:
		return .Would_Block
	case .EINTR:
		return .Interrupted
	case .EBUSY:
		return .Busy
	case .EINVAL:
		return .Invalid
	case .ENOTDIR:
		return .Not_Dir
	case .EISDIR:
		return .Is_Dir
	case .ENOSPC:
		return .No_Space
	case .EMFILE, .ENFILE:
		return .Too_Many_Files
	case .ENAMETOOLONG:
		return .Name_Too_Long
	case .ENOSYS, .EOPNOTSUPP:
		return .Unsupported
	case .ENOMEM:
		return .No_Memory
	}
	return .Io
}

@(private)
Msghdr :: struct {
	name:       rawptr,
	namelen:    u32,
	iov:        rawptr,
	iovlen:     uint,
	control:    rawptr,
	controllen: uint,
	flags:      i32,
}

@(private)
Cmsg_Fd :: struct #align (8) {
	len:   uint,
	level: i32,
	type:  i32,
	fd:    i32,
	_pad:  i32,
}

@(private)
SOL_SOCKET :: i32(1)
@(private)
SCM_RIGHTS :: i32(1)
@(private)
MSG_CMSG_CLOEXEC :: uintptr(0x40000000)

@(private)
_send_fd :: proc "contextless" (sock: i32, fd: i32, payload: []u8) -> int {
	iov := Iovec{raw_data(payload), uint(len(payload))}
	cm := Cmsg_Fd {
		len   = 16 + 4,
		level = SOL_SOCKET,
		type  = SCM_RIGHTS,
		fd    = fd,
	}
	msg := Msghdr {
		iov        = &iov,
		iovlen     = 1,
		control    = &cm,
		controllen = size_of(Cmsg_Fd) if fd >= 0 else 0,
	}
	if fd < 0 {
		msg.control = nil
	}
	for {
		r := intrinsics.syscall(linux.SYS_sendmsg, uintptr(int(sock)), uintptr(&msg), uintptr(0x4000))
		e := _errno(r)
		if e == EINTR {
			continue
		}
		return e
	}
}

@(private)
_recv_fd :: proc "contextless" (sock: i32, payload: []u8) -> (n: int, fd: i32, err: int) {
	iov := Iovec{raw_data(payload), uint(len(payload))}
	cm: Cmsg_Fd
	msg := Msghdr {
		iov        = &iov,
		iovlen     = 1,
		control    = &cm,
		controllen = size_of(Cmsg_Fd),
	}
	fd = -1
	for {
		r := intrinsics.syscall(linux.SYS_recvmsg, uintptr(int(sock)), uintptr(&msg), MSG_CMSG_CLOEXEC)
		e := _errno(r)
		if e == EINTR {
			continue
		}
		if e != 0 {
			return 0, -1, e
		}
		n = int(r)
		break
	}
	if msg.controllen >= 20 && cm.level == SOL_SOCKET && cm.type == SCM_RIGHTS {
		fd = cm.fd
	}
	return n, fd, 0
}

@(private)
_recv_listener :: proc(sock: i32) -> (fd: i32, killable: bool) {
	payload: [4]u8
	n, got, e := _recv_fd(sock, payload[:])
	if e != 0 || n < 1 {
		_sys_close(got)
		return -1, false
	}
	return got, payload[0] == 1
}

@(private)
_on_listener :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	t := (^Tree)(data)
	s := t.sup
	if .Read in events {
		_handle_one(s, t)
		if s.trees[t.slot] != t {
			return
		}
	}
	for {
		pfd := Pollfd{fd = t.fd, events = POLLIN}
		n, e := _sys_poll(&pfd, 1, 0)
		if e == EINTR {
			continue
		}
		if e != 0 || n == 0 {
			return
		}
		if pfd.revents & POLLIN != 0 {
			_handle_one(s, t)
			continue
		}
		if pfd.revents & (POLLHUP | POLLERR | POLLNVAL) != 0 {
			s.trees[t.slot] = nil
			_tree_free(s, t, true)
		}
		return
	}
}

@(private)
_reply :: proc(s: ^Supervisor, t: ^Tree, id: u64) {
	resp := Notif_Resp {
		id    = id,
		flags = NOTIF_FLAG_CONTINUE,
	}
	for {
		e := _sys_ioctl(t.fd, NOTIF_SEND, &resp)
		if e != EINTR {
			break
		}
	}
	intrinsics.volatile_store(&s.shared.state, 0)
}

@(private)
_handle_one :: proc(s: ^Supervisor, t: ^Tree) {
	sh := s.shared
	intrinsics.mem_zero(&sh.notif, NOTIF_BUF)
	intrinsics.volatile_store(&sh.slot, t.slot)
	intrinsics.volatile_store(&sh.state, 1)
	e := _sys_ioctl(t.fd, NOTIF_RECV, &sh.notif)
	if e != 0 {
		intrinsics.volatile_store(&sh.state, 0)
		return
	}
	n := (^Notif)(&sh.notif)
	s.stats.notifications += 1
	if s.sink.write == nil && s.router.reg == nil {
		_reply(s, t, n.id)
		return
	}
	tid := i32(n.pid)
	tgid, gok := _tgid_of(s, tid)
	if !gok {
		s.stats.failed += 1
		_reply(s, t, n.id)
		return
	}
	call := decode_call(n.data.arch, n.data.nr)
	if call >= .Chdir {
		_control(s, t, n, call, tid, tgid)
		s.stats.ignored += 1
		_reply(s, t, n.id)
		return
	}
	w: Write
	d: Decoded
	if !_decode(s, t, n, &w, &d) {
		s.stats.ignored += 1
		_reply(s, t, n.id)
		return
	}
	lineage, pe := _pcache_lineage(s, tgid, t.root)
	w.lineage = lineage
	w.pid = tgid
	w.tid = prim.Pid(tid)
	w.tree = t.root
	ctx := Ctx {
		s       = s,
		tid     = tid,
		tgid    = i32(tgid),
		root    = -1,
		cwd     = -1,
		moved   = t.moved,
	}
	if pe != nil {
		if pe.chdir_tid == tid {
			pe.chdir_tid = 0
		}
		if !pe.nocwd && pe.chdir_tid == 0 {
			if pe.cwd < 0 {
				pp: Proc_Path
				pe.cwd, _ = _sys_openat(AT_FDCWD, _pp_proc(&pp, i64(tid), "/cwd"), SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
			}
			ctx.cwd = pe.cwd
		}
	}
	if !t.moved {
		ctx.root = s.root_fd
		ctx.root_borrowed = true
	}
	p, exact, ok := _resolve(&ctx, d.one, s.sc.arg[:], s.sc.out[:])
	if ok && d.has_two {
		p2, exact2, ok2 := _resolve(&ctx, d.two, s.sc.arg2[:], s.sc.out2[:])
		w.from = p2
		exact = exact && exact2
		ok = ok2
	}
	if !ctx.root_borrowed {
		_sys_close(ctx.root)
	}
	if !ok {
		s.stats.failed += 1
		_reply(s, t, n.id)
		return
	}
	w.path = p
	w.exact = exact
	w.dev = ctx.dev
	if !_id_valid(t, n.id) {
		s.stats.stale += 1
		intrinsics.volatile_store(&sh.state, 0)
		return
	}
	s.stats.reported += 1
	if !w.exact {
		s.stats.inexact += 1
	}
	deliver(&s.router, s.sink, &w)
	_reply(s, t, n.id)
}

@(private)
_id_valid :: proc(t: ^Tree, id: u64) -> bool {
	x := id
	for {
		e := _sys_ioctl(t.fd, NOTIF_ID_VALID, &x)
		if e == EINTR {
			continue
		}
		return e == 0
	}
}

@(private)
Decoded :: struct {
	one:     Path_Arg,
	two:     Path_Arg,
	has_two: bool,
}

@(private)
Path_Arg :: struct {
	dirfd:   i32,
	addr:    u64,
	follow:  bool,
	empty:   bool,
	resolve: u64,
}

@(private)
_decode :: proc(s: ^Supervisor, t: ^Tree, n: ^Notif, w: ^Write, out: ^Decoded) -> bool {
	a := n.data.args
	tid := i32(n.pid)
	arch := n.data.arch
	call := decode_call(arch, n.data.nr)
	nofollow := nofollow_flag(arch)
	at :: proc "contextless" (v: u64) -> i32 {
		return i32(u32(v & 0xffffffff))
	}
	one: Path_Arg
	two: Path_Arg
	has_two := false
	one.dirfd = AT_FDCWD
	two.dirfd = AT_FDCWD
	flags: u64
	#partial switch call {
	case .Open, .Openat, .Openat2, .Creat:
		#partial switch call {
		case .Open:
			one.addr = a[0]
			flags = a[1] & 0xffffffff
		case .Openat:
			one.dirfd = at(a[0])
			one.addr = a[1]
			flags = a[2] & 0xffffffff
		case .Openat2:
			one.dirfd = at(a[0])
			one.addr = a[1]
			if a[3] < size_of(Open_How) {
				return false
			}
			how: Open_How
			if !_read_mem(tid, a[2], ([^]u8)(&how)[:size_of(Open_How)]) {
				return false
			}
			flags = how.flags
			one.resolve = how.resolve & RESOLVE_MASK
		case:
			one.addr = a[0]
			flags = O_CREAT | O_WRONLY | O_TRUNC
		}
		if flags & O_PATH != 0 || flags & WRITE_MASK == 0 || flags & O_TMPFILE_BIT != 0 {
			return false
		}
		one.follow = flags & nofollow == 0 && flags & (O_CREAT | O_EXCL) != (O_CREAT | O_EXCL)
		w.op = .Truncate if flags & O_TRUNC != 0 else .Write
		w.flags = u32(flags)
	case .Rename, .Renameat, .Renameat2:
		w.op = .Rename
		has_two = true
		if call == .Rename {
			two.addr = a[0]
			one.addr = a[1]
		} else {
			two.dirfd = at(a[0])
			two.addr = a[1]
			one.dirfd = at(a[2])
			one.addr = a[3]
			if call == .Renameat2 && a[4] & RENAME_EXCHANGE != 0 {
				w.op = .Exchange
			}
			if call == .Renameat2 {
				w.flags = u32(a[4])
			}
		}
	case .Unlink:
		w.op = .Remove
		one.addr = a[0]
	case .Unlinkat:
		w.op = .Rmdir if a[2] & AT_REMOVEDIR != 0 else .Remove
		one.dirfd = at(a[0])
		one.addr = a[1]
	case .Rmdir:
		w.op = .Rmdir
		one.addr = a[0]
	case .Mkdir:
		w.op = .Mkdir
		one.addr = a[0]
	case .Mkdirat:
		w.op = .Mkdir
		one.dirfd = at(a[0])
		one.addr = a[1]
	case .Mknod:
		w.op = .Mknod
		one.addr = a[0]
	case .Mknodat:
		w.op = .Mknod
		one.dirfd = at(a[0])
		one.addr = a[1]
	case .Link, .Linkat:
		w.op = .Link
		has_two = true
		if call == .Link {
			two.addr = a[0]
			one.addr = a[1]
		} else {
			two.dirfd = at(a[0])
			two.addr = a[1]
			one.dirfd = at(a[2])
			one.addr = a[3]
			two.follow = a[4] & AT_SYMLINK_FOLLOW != 0
			two.empty = a[4] & AT_EMPTY_PATH != 0
		}
	case .Symlink:
		w.op = .Symlink
		one.addr = a[1]
	case .Symlinkat:
		w.op = .Symlink
		one.dirfd = at(a[1])
		one.addr = a[2]
	case .Truncate:
		w.op = .Truncate
		one.addr = a[0]
		one.follow = true
	case .Chmod:
		w.op = .Chmod
		one.addr = a[0]
		one.follow = true
	case .Fchmodat:
		w.op = .Chmod
		one.dirfd = at(a[0])
		one.addr = a[1]
		one.follow = true
	case .Fchmodat2:
		w.op = .Chmod
		one.dirfd = at(a[0])
		one.addr = a[1]
		one.follow = a[3] & AT_SYMLINK_NOFOLLOW == 0
		one.empty = a[3] & AT_EMPTY_PATH != 0
	case .Fchmod:
		w.op = .Chmod
		one.dirfd = at(a[0])
		one.empty = true
		one.addr = 0
	case:
		return false
	}
	out.one = one
	out.two = two
	out.has_two = has_two
	return true
}

@(private)
_read_mem :: proc(tid: i32, addr: u64, out: []u8) -> bool {
	if addr == 0 {
		return false
	}
	local := [1]Iovec{{raw_data(out), uint(len(out))}}
	remote := [1]Iovec{{rawptr(uintptr(addr)), uint(len(out))}}
	n, e := _sys_vm_read(tid, local[:], remote[:])
	return e == 0 && n == len(out)
}

@(private)
Mem_Result :: enum u8 {
	Ok,
	Fault,
	Too_Long,
	Denied,
}

@(private)
_read_str :: proc(tid: i32, addr: u64, buf: []u8) -> (string, Mem_Result) {
	if addr == 0 {
		return "", .Fault
	}
	page := u64(4096)
	first := page - (addr & (page - 1))
	want := u64(len(buf))
	if first > want {
		first = want
	}
	local := [1]Iovec{{raw_data(buf), uint(want)}}
	remote := [2]Iovec{{rawptr(uintptr(addr)), uint(first)}, {rawptr(uintptr(addr + first)), uint(want - first)}}
	nr := 2 if want > first else 1
	n, e := _sys_vm_read(tid, local[:], remote[:nr])
	if e == EFAULT {
		return "", .Fault
	}
	if e != 0 {
		n, e = _read_proc_mem(tid, addr, buf)
		if e != 0 {
			return "", .Fault if e == EFAULT || e == 5 else .Denied
		}
	}
	for i in 0 ..< n {
		if buf[i] == 0 {
			return string(buf[:i]), .Ok
		}
	}
	if n < int(want) {
		return "", .Fault
	}
	return "", .Too_Long
}

@(private)
_read_proc_mem :: proc(tid: i32, addr: u64, buf: []u8) -> (int, int) {
	pp: Proc_Path
	fd, e := _sys_openat(AT_FDCWD, _pp_proc(&pp, i64(tid), "/mem"), SYS_O_RDONLY | SYS_O_CLOEXEC)
	if e != 0 {
		return 0, e
	}
	defer _sys_close(fd)
	page := u64(4096)
	first := int(page - (addr & (page - 1)))
	total := 0
	chunks := [2]int{min(first, len(buf)), len(buf) - min(first, len(buf))}
	for c in chunks {
		if c == 0 {
			break
		}
		r := intrinsics.syscall(linux.SYS_pread64, uintptr(int(fd)), uintptr(raw_data(buf[total:])), uintptr(c), uintptr(addr + u64(total)))
		re := _errno(r)
		if re != 0 {
			if total > 0 {
				return total, 0
			}
			return 0, re
		}
		total += int(r)
		if int(r) < c {
			break
		}
	}
	return total, 0
}

@(private)
_control :: proc(s: ^Supervisor, t: ^Tree, n: ^Notif, call: Call, tid: i32, tgid: prim.Pid) {
	pe := _pentry(s, tgid, t.root, 0)
	if pe != nil && pe.chdir_tid == tid {
		pe.chdir_tid = 0
	}
	flags := u64(n.data.args[0])
	#partial switch call {
	case .Chdir, .Fchdir:
		if pe != nil {
			_sys_close(pe.cwd)
			pe.cwd = -1
			pe.chdir_tid = tid
		}
	case .Chroot, .Setns:
		t.moved = true
		if pe != nil {
			_sys_close(pe.cwd)
			pe.cwd = -1
			pe.chdir_tid = tid
		}
	case .Pivot_Root:
		t.moved = true
		_pcache_drop_cwds(s)
		if pe != nil {
			pe.chdir_tid = tid
		}
	case .Clone3:
		if n.data.args[1] < 8 {
			return
		}
		f: u64
		if !_read_mem(tid, n.data.args[0], ([^]u8)(&f)[:8]) {
			t.moved = true
			if pe != nil {
				pe.nocwd = true
			}
			return
		}
		flags = f
		fallthrough
	case .Unshare, .Clone:
		if flags & u64(CLONE_NEWNS) != 0 {
			t.moved = true
		}
		thread_no_fs := call != .Unshare && flags & u64(CLONE_THREAD | CLONE_FS) == u64(CLONE_THREAD)
		unshare_fs := call == .Unshare && flags & u64(CLONE_FS) != 0
		if (thread_no_fs || unshare_fs) && pe != nil {
			_sys_close(pe.cwd)
			pe.cwd = -1
			pe.nocwd = true
		}
	}
}

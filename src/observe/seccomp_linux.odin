#+build linux
package observe

import "base:intrinsics"
import "base:runtime"
import "core:sys/linux"
import "core:sync"
import "core:thread"
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
	state:    u32,
	parked_n: u32,
	_pad:     [56]u8,
	notif:    [NOTIF_BUF]u8,
	parked:   [PARK_MAX]u64,
}

PARK_MAX :: 64
GATE_MAX :: 16
GATE_EXEMPT :: 16
LOCKS_SEEN :: 16

@(private)
Gate :: struct {
	id:       u32,
	root:     [prim.PATH_MAX]u8,
	root_len: int,
	exempt:   [GATE_EXEMPT]prim.Pid,
	exempt_n: int,
}

@(private)
Lock_Seen :: struct {
	path: [prim.PATH_MAX]u8,
	len:  int,
	pid:  prim.Pid,
}

@(private)
Parked :: struct {
	id:   u64,
	gate: u32,
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
	killable: bool,
	moved:    bool,
	ended:    u32,
	stop_fd:  i32,
	space_fd: i32,
	ready_fd: i32,
	sock:     i32,
	flush_fd: i32,
	gate_fd:  i32,
	parked:   [PARK_MAX]Parked,
	parked_n: int,
	unsignaled: int,
	recv:     u64,
	handled:  u64,
	flush_req: u32,
	delivered: u64,
	ring:     Ring,
	thread:   ^thread.Thread,
	alloc:    runtime.Allocator,
	sc:       ^Scratch,
	pc:       Pcache,
	wbuf:     [dynamic]u8,
}

@(private)
Scratch :: struct {
	arg:     [prim.PATH_MAX + 1]u8,
	arg2:    [prim.PATH_MAX + 1]u8,
	out:     [prim.PATH_MAX * 2]u8,
	out2:    [prim.PATH_MAX * 2]u8,
	tmp:     [prim.PATH_MAX * 2]u8,
	file:    [4096]u8,
	args:    [8192]u8,
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
	shared:     [^]Shared,
	keeper:     Keeper,
	pending:    u32,
	consumers:  u32,
	wake_fd:    i32,
	wake_watch: prim.Watch,
	snap_mu:    sync.Mutex,
	snap:       [dynamic]Root,
	fences:     [dynamic]^Fence,
	self:       prim.Pid,
	mnt_ns:     [64]u8,
	mnt_ns_len: int,
	has_openat2: bool,
	root_fd:    i32,
	stats:      Stats,
	gate_mu:    sync.Mutex,
	gates:      [GATE_MAX]Gate,
	gate_n:     int,
	gate_next:  u32,
	gate_count: u32,
	locks:      [LOCKS_SEEN]Lock_Seen,
	lock_next:  int,
}

supervisor_init :: proc(s: ^Supervisor, loop: ^prim.Loop, opts := DEFAULT_SUPERVISOR, allocator := context.allocator) -> prim.Error {
	s^ = {
		loop      = loop,
		allocator = allocator,
		opts      = opts,
	}
	s.keeper.ctl = -1
	s.root_fd = -1
	s.wake_fd = -1
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
	mem := intrinsics.syscall(linux.SYS_mmap, 0, uintptr(size_of(Shared) * KEEPER_SLOTS), uintptr(0x3), uintptr(0x21), ~uintptr(0), 0)
	if _errno(mem) != 0 {
		delete(s.prog, allocator)
		return .No_Memory
	}
	s.shared = ([^]Shared)(rawptr(mem))
	s.wake_fd = _eventfd()
	if s.wake_fd < 0 {
		supervisor_destroy(s)
		return .Too_Many_Files
	}
	ww, werr := prim.watch(loop, prim.Fd(s.wake_fd), {.Read}, s, _on_wake)
	if werr != .None {
		supervisor_destroy(s)
		return werr
	}
	s.wake_watch = ww
	s.snap = make([dynamic]Root, allocator)
	s.fences = make([dynamic]^Fence, allocator)
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
	_sys_close(s.root_fd)
	if s.wake_watch != 0 && s.loop != nil {
		prim.unwatch(s.loop, s.wake_watch)
	}
	_sys_close(s.wake_fd)
	_roots_clear(s)
	delete(s.snap)
	for f in s.fences {
		_fence_free(s, f)
	}
	delete(s.fences)
	if s.prog != nil {
		delete(s.prog, s.allocator)
	}
	if s.shared != nil {
		intrinsics.syscall(linux.SYS_munmap, uintptr(s.shared), uintptr(size_of(Shared) * KEEPER_SLOTS))
	}
	s^ = {}
	s.keeper.ctl = -1
	s.root_fd = -1
	s.wake_fd = -1
}

supervisor_set_sink :: proc(s: ^Supervisor, sink: Sink) {
	s.sink = sink
	_consumers_update(s)
}

@(private)
_consumers_update :: proc(s: ^Supervisor) {
	v := u32(1) if s.sink.write != nil || s.router.reg != nil else 0
	intrinsics.atomic_store_explicit(&s.consumers, v, .Relaxed)
}

@(private)
_roots_clear :: proc(s: ^Supervisor) {
	for r in s.snap {
		delete(r.real, s.allocator)
	}
	clear(&s.snap)
}

@(private)
_roots_publish :: proc(s: ^Supervisor) {
	same := len(s.snap) == len(s.router.roots)
	if same {
		for r, i in s.router.roots {
			if s.snap[i].real != r.real || s.snap[i].dev != r.dev || s.snap[i].ino != r.ino {
				same = false
				break
			}
		}
	}
	if same {
		return
	}
	sync.mutex_lock(&s.snap_mu)
	defer sync.mutex_unlock(&s.snap_mu)
	_roots_clear(s)
	for r in s.router.roots {
		c := make([]u8, len(r.real), s.allocator)
		copy(c, r.real)
		append(&s.snap, Root{real = string(c), dev = r.dev, ino = r.ino})
	}
}

supervisor_stats :: proc(s: ^Supervisor) -> Stats {
	st: Stats
	st.notifications = intrinsics.atomic_load(&s.stats.notifications)
	st.reported = intrinsics.atomic_load(&s.stats.reported)
	st.ignored = intrinsics.atomic_load(&s.stats.ignored)
	st.failed = intrinsics.atomic_load(&s.stats.failed)
	st.inexact = intrinsics.atomic_load(&s.stats.inexact)
	st.stale = intrinsics.atomic_load(&s.stats.stale)
	st.parked = intrinsics.atomic_load(&s.stats.parked)
	st.released = intrinsics.atomic_load(&s.stats.released)
	return st
}

supervisor_trees :: proc(s: ^Supervisor) -> int {
	return s.live
}

write_observer :: proc(s: ^Supervisor) -> fs.Write_Observer {
	return fs.Write_Observer{data = s, start = _observer_start, stop = _observer_stop, fence = _observer_fence, gate = _observer_gate, ungate = _observer_ungate, lock_creator = _observer_lock_creator}
}

@(private)
_observer_gate :: proc(data: rawptr, root: string, exempt: []prim.Pid) -> (u32, bool) {
	return supervisor_gate((^Supervisor)(data), root, exempt)
}

@(private)
_observer_ungate :: proc(data: rawptr, id: u32) {
	supervisor_ungate((^Supervisor)(data), id)
}

@(private)
_observer_lock_creator :: proc(data: rawptr, path: string) -> (prim.Pid, bool) {
	return supervisor_lock_creator((^Supervisor)(data), path)
}

supervisor_gate :: proc(s: ^Supervisor, root: string, exempt: []prim.Pid) -> (id: u32, ok: bool) {
	if len(root) == 0 || len(root) >= prim.PATH_MAX {
		return 0, false
	}
	sync.mutex_lock(&s.gate_mu)
	defer sync.mutex_unlock(&s.gate_mu)
	if s.gate_n == GATE_MAX {
		return 0, false
	}
	s.gate_next += 1
	if s.gate_next == 0 {
		s.gate_next = 1
	}
	g := &s.gates[s.gate_n]
	g^ = {}
	g.id = s.gate_next
	copy(g.root[:], root)
	g.root_len = len(root)
	for p in exempt {
		if g.exempt_n < GATE_EXEMPT && p > 0 {
			g.exempt[g.exempt_n] = p
			g.exempt_n += 1
		}
	}
	s.gate_n += 1
	intrinsics.atomic_store(&s.gate_count, u32(s.gate_n))
	return g.id, true
}

supervisor_ungate :: proc(s: ^Supervisor, id: u32) {
	sync.mutex_lock(&s.gate_mu)
	for i in 0 ..< s.gate_n {
		if s.gates[i].id == id {
			s.gates[i] = s.gates[s.gate_n - 1]
			s.gate_n -= 1
			break
		}
	}
	intrinsics.atomic_store(&s.gate_count, u32(s.gate_n))
	sync.mutex_unlock(&s.gate_mu)
	for t in s.trees {
		if t != nil && t.gate_fd >= 0 {
			_efd_signal(t.gate_fd)
		}
	}
}

supervisor_lock_creator :: proc(s: ^Supervisor, path: string) -> (pid: prim.Pid, ok: bool) {
	sync.mutex_lock(&s.gate_mu)
	defer sync.mutex_unlock(&s.gate_mu)
	for k in 0 ..< LOCKS_SEEN {
		i := (s.lock_next - 1 - k + 2 * LOCKS_SEEN) % LOCKS_SEEN
		l := &s.locks[i]
		if l.len > 0 && string(l.path[:l.len]) == path {
			return l.pid, true
		}
	}
	return 0, false
}

@(private)
_lock_record :: proc(s: ^Supervisor, path: string, pid: prim.Pid) {
	if len(path) >= prim.PATH_MAX {
		return
	}
	sync.mutex_lock(&s.gate_mu)
	defer sync.mutex_unlock(&s.gate_mu)
	l := &s.locks[s.lock_next]
	copy(l.path[:], path)
	l.len = len(path)
	l.pid = pid
	s.lock_next = (s.lock_next + 1) % LOCKS_SEEN
}

@(private)
_under :: proc "contextless" (p, root: string) -> bool {
	if len(p) < len(root) || p[:len(root)] != root {
		return false
	}
	return len(p) == len(root) || p[len(root)] == '/' || root[len(root) - 1] == '/'
}

@(private)
_gate_match :: proc(s: ^Supervisor, path, from: string, tgid: prim.Pid, lineage: []prim.Pid) -> (id: u32, gated: bool) {
	if intrinsics.atomic_load(&s.gate_count) == 0 {
		return 0, false
	}
	sync.mutex_lock(&s.gate_mu)
	defer sync.mutex_unlock(&s.gate_mu)
	outer: for i in 0 ..< s.gate_n {
		g := &s.gates[i]
		root := string(g.root[:g.root_len])
		if !_under(path, root) && !(len(from) > 0 && _under(from, root)) {
			continue
		}
		for e in g.exempt[:g.exempt_n] {
			if e == tgid {
				continue outer
			}
			for l in lineage {
				if l == e {
					continue outer
				}
			}
		}
		return g.id, true
	}
	return 0, false
}

@(private)
_gate_active :: proc(s: ^Supervisor, id: u32) -> bool {
	sync.mutex_lock(&s.gate_mu)
	defer sync.mutex_unlock(&s.gate_mu)
	for i in 0 ..< s.gate_n {
		if s.gates[i].id == id {
			return true
		}
	}
	return false
}

@(private)
_park :: proc(s: ^Supervisor, t: ^Tree, id: u64, gate: u32) -> bool {
	if t.parked_n >= PARK_MAX {
		return false
	}
	sh := &s.shared[t.slot]
	i := t.parked_n
	t.parked[i] = Parked{id, gate}
	intrinsics.volatile_store(&sh.parked[i], id)
	t.parked_n += 1
	intrinsics.volatile_store(&sh.parked_n, u32(t.parked_n))
	return true
}

@(private)
_reply_id :: proc(t: ^Tree, id: u64) {
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
}

@(private)
_release_parked :: proc(s: ^Supervisor, t: ^Tree, all: bool) {
	sh := &s.shared[t.slot]
	i := 0
	for i < t.parked_n {
		if !all && _gate_active(s, t.parked[i].gate) {
			i += 1
			continue
		}
		_reply_id(t, t.parked[i].id)
		last := t.parked_n - 1
		t.parked[i] = t.parked[last]
		intrinsics.volatile_store(&sh.parked[i], t.parked[i].id)
		t.parked_n = last
		intrinsics.volatile_store(&sh.parked_n, u32(t.parked_n))
		_stat_add(&s.stats.released)
	}
}

@(private)
_observer_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	s := (^Supervisor)(data)
	router_bind(&s.router, reg)
	router_refresh(&s.router)
	_roots_publish(s)
	_consumers_update(s)
	return .None
}

@(private)
_observer_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	s := (^Supervisor)(data)
	if s.router.reg == reg {
		router_bind(&s.router, nil)
		_consumers_update(s)
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
	t, terr := new(Tree, s.allocator)
	if terr != nil {
		_sys_close(sock[0])
		_sys_close(sock[1])
		return child, .No_Memory
	}
	t^ = {
		sup      = s,
		slot     = slot,
		fd       = -1,
		sock     = sock[0],
		stop_fd  = -1,
		space_fd = -1,
		ready_fd = -1,
		flush_fd = -1,
		gate_fd  = -1,
	}
	router_refresh(&s.router)
	_roots_publish(s)
	if werr := _worker_start(s, t); werr != .None {
		_sys_close(sock[1])
		_tree_discard(t)
		return child, werr
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
		_tree_discard(t)
		return child, err
	}
	pf := [1]Pollfd{{fd = t.ready_fd, events = POLLIN}}
	for {
		_, pe := _sys_poll(&pf[0], 1, -1)
		if pe != EINTR {
			break
		}
	}
	if intrinsics.atomic_load(&t.fd) < 0 {
		prim.kill_process(child.pid, .Kill)
		prim.reap(child.pid, true)
		prim.child_close(&child)
		_tree_discard(t)
		return child, .Io
	}
	s.trees[slot] = t
	s.live += 1
	_keeper_add(s, t)
	return child, .None
}

@(private)
_tree_discard :: proc(t: ^Tree) {
	s := t.sup
	_worker_free(t)
	_sys_close(t.fd)
	_sys_close(t.sock)
	free(t, s.allocator)
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
	pid := i32(int(intrinsics.syscall(linux.SYS_getpid)))
	payload := [8]u8{killable, 0, 0, 0, 0, 0, 0, 0}
	(^i32)(&payload[4])^ = pid
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
	_worker_free(t)
	_sys_close(t.sock)
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
_reply :: proc(s: ^Supervisor, t: ^Tree, id: u64) {
	sh := &s.shared[t.slot]
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
	intrinsics.volatile_store(&sh.state, 0)
}

@(private)
_handle_one :: proc(s: ^Supervisor, t: ^Tree) -> bool {
	sh := &s.shared[t.slot]
	intrinsics.mem_zero(&sh.notif, NOTIF_BUF)
	intrinsics.volatile_store(&sh.state, 1)
	e := _sys_ioctl(t.fd, NOTIF_RECV, &sh.notif)
	if e != 0 {
		intrinsics.volatile_store(&sh.state, 0)
		return true
	}
	intrinsics.atomic_add_explicit(&t.recv, 1, .Seq_Cst)
	defer intrinsics.atomic_add_explicit(&t.handled, 1, .Seq_Cst)
	n := (^Notif)(&sh.notif)
	_stat_add(&s.stats.notifications)
	tid := i32(n.pid)
	tgid, gok := _tgid_of(t, tid)
	if !gok {
		_stat_add(&s.stats.failed)
		_reply(s, t, n.id)
		return true
	}
	call := decode_call(n.data.arch, n.data.nr)
	if call >= .Chdir {
		_control(s, t, n, call, tid, tgid)
		_stat_add(&s.stats.ignored)
		_reply(s, t, n.id)
		return true
	}
	if intrinsics.atomic_load_explicit(&s.consumers, .Relaxed) == 0 && intrinsics.atomic_load(&s.gate_count) == 0 {
		_reply(s, t, n.id)
		return true
	}
	w: Write
	d: Decoded
	if !_decode(s, t, n, &w, &d) {
		_stat_add(&s.stats.ignored)
		_reply(s, t, n.id)
		return true
	}
	lineage, pe := _pcache_lineage(t, tgid, t.root)
	w.lineage = lineage
	w.pid = tgid
	w.tid = prim.Pid(tid)
	w.tree = t.root
	ctx := Ctx {
		s     = s,
		t     = t,
		tid   = tid,
		tgid  = i32(tgid),
		root  = -1,
		cwd   = -1,
		moved = t.moved,
	}
	if pe != nil {
		if pe.chdir_tid == tid {
			pe.chdir_tid = 0
		}
		if pe.exec_tid == tid {
			pe.exec_tid = 0
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
	p, exact, ok := _resolve(&ctx, d.one, t.sc.arg[:], t.sc.out[:])
	if ok && d.has_two {
		p2, exact2, ok2 := _resolve(&ctx, d.two, t.sc.arg2[:], t.sc.out2[:])
		w.from = p2
		exact = exact && exact2
		ok = ok2
	}
	if !ctx.root_borrowed {
		_sys_close(ctx.root)
	}
	if !ok {
		_stat_add(&s.stats.failed)
		_reply(s, t, n.id)
		return true
	}
	w.path = p
	w.exact = exact
	w.dev = ctx.dev
	w.args = _pcache_args(t, lineage)
	w.git = _pcache_git(t, lineage)
	if !_id_valid(t, n.id) {
		_stat_add(&s.stats.stale)
		intrinsics.volatile_store(&sh.state, 0)
		return true
	}
	_stat_add(&s.stats.reported)
	if !w.exact {
		_stat_add(&s.stats.inexact)
	}
	if w.op == .Write && w.flags & u32(O_CREAT | O_EXCL) == u32(O_CREAT | O_EXCL) && len(w.path) > 11 && w.path[len(w.path) - 11:] == "/index.lock" {
		_lock_record(s, w.path, tgid)
	}
	_encode_write(&t.wbuf, &w)
	if gid, gated := _gate_match(s, w.path, w.from, tgid, w.lineage); gated && _park(s, t, n.id, gid) {
		_stat_add(&s.stats.parked)
		intrinsics.volatile_store(&sh.state, 0)
		return _ring_push(t, t.wbuf[:])
	}
	_reply(s, t, n.id)
	return _ring_push(t, t.wbuf[:])
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
	pe := _pentry(t, tgid, t.root, 0)
	if pe != nil && pe.chdir_tid == tid {
		pe.chdir_tid = 0
	}
	if pe != nil && pe.exec_tid == tid {
		pe.exec_tid = 0
	}
	flags := u64(n.data.args[0])
	#partial switch call {
	case .Execve:
		if pe != nil {
			if pe.args != nil {
				delete(pe.args, t.alloc)
			}
			pe.args = nil
			pe.args_ok = false
			pe.git = 0
			pe.exec_tid = tid
		}
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
		_pcache_drop_cwds(t)
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

Fence_Proc :: #type proc(data: rawptr)

@(private)
Fence_Entry :: struct {
	tree: ^Tree,
	slot: u32,
	snap: u64,
	head: u64,
	took: bool,
	done: bool,
}

@(private)
Fence :: struct {
	entries: [dynamic]Fence_Entry,
	cb:      Fence_Proc,
	data:    rawptr,
}

supervisor_fence :: proc(s: ^Supervisor, cb: Fence_Proc, data: rawptr) {
	f, err := new(Fence, s.allocator)
	if err != nil {
		cb(data)
		return
	}
	f.cb = cb
	f.data = data
	f.entries = make([dynamic]Fence_Entry, s.allocator)
	for t, i in s.trees {
		if t == nil {
			continue
		}
		append(&f.entries, Fence_Entry{tree = t, slot = u32(i), snap = intrinsics.atomic_load_explicit(&t.recv, .Seq_Cst)})
	}
	_drain_all(s)
	if _fence_check(s, f) {
		_fence_free(s, f)
		cb(data)
		return
	}
	append(&s.fences, f)
	for e in f.entries {
		if !e.done {
			intrinsics.atomic_store_explicit(&e.tree.flush_req, 1, .Seq_Cst)
			_efd_signal(e.tree.flush_fd)
		}
	}
}

supervisor_pending_fences :: proc(s: ^Supervisor) -> int {
	return len(s.fences)
}

@(private)
_fence_free :: proc(s: ^Supervisor, f: ^Fence) {
	delete(f.entries)
	free(f, s.allocator)
}

@(private)
_fence_check :: proc(s: ^Supervisor, f: ^Fence) -> bool {
	all := true
	for &e in f.entries {
		if e.done {
			continue
		}
		t := e.tree
		if int(e.slot) >= len(s.trees) || s.trees[e.slot] != t {
			e.done = true
			continue
		}
		if !e.took {
			if intrinsics.atomic_load_explicit(&t.handled, .Seq_Cst) < e.snap {
				all = false
				continue
			}
			e.head = intrinsics.atomic_load_explicit(&t.ring.head, .Seq_Cst)
			e.took = true
		}
		if t.delivered >= e.head {
			e.done = true
		} else {
			all = false
		}
	}
	return all
}

@(private)
_fences_run :: proc(s: ^Supervisor) {
	i := 0
	for i < len(s.fences) {
		f := s.fences[i]
		if !_fence_check(s, f) {
			i += 1
			continue
		}
		ordered_remove(&s.fences, i)
		cb, data := f.cb, f.data
		_fence_free(s, f)
		cb(data)
	}
}

@(private)
_observer_fence :: proc(data: rawptr, reg: ^fs.Registry, done: proc(data: rawptr), done_data: rawptr) {
	supervisor_fence((^Supervisor)(data), done, done_data)
}

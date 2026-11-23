#+build darwin
package observe

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:sync"
import "core:sys/posix"
import "../fs"
import "../prim"

foreign import endpointsecurity "system:EndpointSecurity"

@(private)
foreign endpointsecurity {
	es_new_client :: proc(client: ^rawptr, handler: rawptr) -> c.int ---
	es_subscribe :: proc(client: rawptr, events: [^]u32, count: u32) -> c.int ---
	es_delete_client :: proc(client: rawptr) -> c.int ---
	es_mute_path :: proc(client: rawptr, path: cstring, type: u32) -> c.int ---
	es_unmute_path :: proc(client: rawptr, path: cstring, type: u32) -> c.int ---
	es_clear_cache :: proc(client: rawptr) -> c.int ---
}

foreign import blocks "system:System"

@(private)
foreign blocks {
	_NSConcreteGlobalBlock: intrinsics.objc_class
}

ES_NEW_CLIENT_SUCCESS :: 0
ES_NEW_CLIENT_ERR_INVALID_ARGUMENT :: 1
ES_NEW_CLIENT_ERR_INTERNAL :: 2
ES_NEW_CLIENT_ERR_NOT_ENTITLED :: 3
ES_NEW_CLIENT_ERR_NOT_PERMITTED :: 4
ES_NEW_CLIENT_ERR_NOT_PRIVILEGED :: 5
ES_NEW_CLIENT_ERR_TOO_MANY_CLIENTS :: 6

@(private)
ES_EVENT_TYPE_NOTIFY_OPEN :: u32(10)
@(private)
ES_EVENT_TYPE_NOTIFY_CLOSE :: u32(12)
@(private)
ES_EVENT_TYPE_NOTIFY_CREATE :: u32(13)
@(private)
ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA :: u32(14)
@(private)
ES_EVENT_TYPE_NOTIFY_LINK :: u32(19)
@(private)
ES_EVENT_TYPE_NOTIFY_RENAME :: u32(25)
@(private)
ES_EVENT_TYPE_NOTIFY_SETMODE :: u32(29)
@(private)
ES_EVENT_TYPE_NOTIFY_UNLINK :: u32(32)
@(private)
ES_EVENT_TYPE_NOTIFY_TRUNCATE :: u32(41)
@(private)
ES_EVENT_TYPE_NOTIFY_CLONE :: u32(61)
@(private)
ES_EVENT_TYPE_NOTIFY_COPYFILE :: u32(110)

@(private)
ES_DESTINATION_TYPE_EXISTING_FILE :: u32(0)
@(private)
ES_MUTE_PATH_TYPE_TARGET_PREFIX :: u32(2)
@(private)
ES_MUTE_INVERSION_TYPE_TARGET_PATH :: u32(2)

@(private)
OFF_MSG_VERSION :: 0
@(private)
OFF_MSG_PROCESS :: 40
@(private)
OFF_MSG_EVENT_TYPE :: 96
@(private)
OFF_MSG_EVENT :: 104
@(private)
OFF_PROC_PID :: 20
@(private)
OFF_PROC_PPID :: 32

@(private)
Es_Token :: struct {
	length: c.size_t,
	data:   [^]u8,
}

@(private)
Es_File :: struct {
	path:      Es_Token,
	truncated: bool,
}

@(private)
Block_Descriptor :: struct {
	reserved: c.ulong,
	size:     c.ulong,
}

@(private)
Es_Block :: struct {
	isa:        rawptr,
	flags:      i32,
	reserved:   i32,
	invoke:     proc "c" (b: ^Es_Block, client: rawptr, msg: rawptr),
	descriptor: ^Block_Descriptor,
	es:         ^Endpoint,
}

@(private, rodata)
_es_descriptor := Block_Descriptor{0, size_of(Es_Block)}

@(private)
BLOCK_IS_GLOBAL :: i32(1 << 28)

@(private)
ES_QUEUE_LIMIT :: 1 << 20

Endpoint :: struct {
	allocator: runtime.Allocator,
	loop:      ^prim.Loop,
	router:    Router,
	sink:      Sink,
	client:    rawptr,
	block:     Es_Block,
	mutex:     sync.Mutex,
	queue:     [dynamic]u8,
	spare:     [dynamic]u8,
	overflow:  bool,
	pipe:      [2]posix.FD,
	watch:     prim.Watch,
	self:      prim.Pid,
	inverted:  bool,
	muted:     [dynamic]string,
	fallback:  ^Libproc,
	stats:     Stats,
}

@(private)
Es_Invert :: #type proc "c" (client: rawptr, type: u32) -> c.int

endpoint_init :: proc(e: ^Endpoint, loop: ^prim.Loop, allocator := context.allocator) -> prim.Error {
	e^ = {
		allocator = allocator,
		loop      = loop,
		pipe      = {-1, -1},
	}
	e.self = prim.Pid(getpid())
	if posix.pipe(&e.pipe) != .OK {
		return .Io
	}
	for fd in e.pipe {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | i32(posix.O_NONBLOCK))
		posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	}
	router_init(&e.router, allocator)
	e.queue = make([dynamic]u8, 0, ES_QUEUE_LIMIT, allocator)
	e.spare = make([dynamic]u8, 0, ES_QUEUE_LIMIT, allocator)
	if cap(e.queue) < ES_QUEUE_LIMIT || cap(e.spare) < ES_QUEUE_LIMIT {
		endpoint_destroy(e)
		return .No_Memory
	}
	e.muted = make([dynamic]string, allocator)
	e.block = Es_Block {
		isa        = &_NSConcreteGlobalBlock,
		flags      = BLOCK_IS_GLOBAL,
		invoke     = _es_handler,
		descriptor = &_es_descriptor,
		es         = e,
	}
	client: rawptr
	r := es_new_client(&client, &e.block)
	if r != ES_NEW_CLIENT_SUCCESS {
		endpoint_destroy(e)
		switch r {
		case ES_NEW_CLIENT_ERR_NOT_ENTITLED, ES_NEW_CLIENT_ERR_NOT_PERMITTED, ES_NEW_CLIENT_ERR_NOT_PRIVILEGED:
			return .Permission
		case ES_NEW_CLIENT_ERR_TOO_MANY_CLIENTS:
			return .Busy
		}
		return .Unsupported
	}
	e.client = client
	if lib := posix.dlopen("/usr/lib/libEndpointSecurity.dylib", {.LAZY}); lib != nil {
		if sym := posix.dlsym(lib, "es_invert_muting"); sym != nil {
			invert := Es_Invert(sym)
			e.inverted = invert(client, ES_MUTE_INVERSION_TYPE_TARGET_PATH) == 0
		}
	}
	events := [?]u32 {
		ES_EVENT_TYPE_NOTIFY_CLOSE,
		ES_EVENT_TYPE_NOTIFY_OPEN,
		ES_EVENT_TYPE_NOTIFY_CREATE,
		ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA,
		ES_EVENT_TYPE_NOTIFY_LINK,
		ES_EVENT_TYPE_NOTIFY_RENAME,
		ES_EVENT_TYPE_NOTIFY_SETMODE,
		ES_EVENT_TYPE_NOTIFY_UNLINK,
		ES_EVENT_TYPE_NOTIFY_TRUNCATE,
		ES_EVENT_TYPE_NOTIFY_CLONE,
		ES_EVENT_TYPE_NOTIFY_COPYFILE,
	}
	if es_subscribe(client, raw_data(events[:]), u32(len(events))) != 0 {
		if es_subscribe(client, raw_data(events[:]), u32(len(events) - 1)) != 0 {
			endpoint_destroy(e)
			return .Unsupported
		}
	}
	w, werr := prim.watch(loop, prim.Fd(e.pipe[0]), {.Read}, e, _es_on_pipe)
	if werr != .None {
		endpoint_destroy(e)
		return werr
	}
	e.watch = w
	return .None
}

endpoint_destroy :: proc(e: ^Endpoint) {
	if e.client != nil {
		es_delete_client(e.client)
		e.client = nil
	}
	if e.watch != 0 && e.loop != nil {
		prim.unwatch(e.loop, e.watch)
	}
	for fd in e.pipe {
		if fd >= 0 {
			posix.close(fd)
		}
	}
	for m in e.muted {
		delete(m, e.allocator)
	}
	delete(e.muted)
	delete(e.queue)
	delete(e.spare)
	router_destroy(&e.router)
	e^ = {}
}

endpoint_set_sink :: proc(e: ^Endpoint, sink: Sink) {
	e.sink = sink
}

endpoint_stats :: proc(e: ^Endpoint) -> Stats {
	return e.stats
}

endpoint_observer :: proc(e: ^Endpoint) -> fs.Write_Observer {
	return fs.Write_Observer{data = e, start = _es_start, stop = _es_stop, changed = _es_changed, fence = _es_fence, gate = _es_gate, ungate = _es_ungate, gate_max_ms = SUSP_GATE_MAX_MS, lock_procs = _libproc_lock_procs}
}

@(private)
_es_start :: proc(data: rawptr, reg: ^fs.Registry) -> fs.Error {
	e := (^Endpoint)(data)
	router_bind(&e.router, reg)
	_es_sync_paths(e)
	return .None
}

@(private)
_es_stop :: proc(data: rawptr, reg: ^fs.Registry) {
	e := (^Endpoint)(data)
	if e.router.reg == reg {
		router_bind(&e.router, nil)
	}
}

@(private)
_es_sync_paths :: proc(e: ^Endpoint) {
	if !e.inverted || e.client == nil {
		return
	}
	router_refresh(&e.router)
	i := 0
	for i < len(e.muted) {
		keep := false
		for root in e.router.roots {
			if root.real == e.muted[i] {
				keep = true
				break
			}
		}
		if keep {
			i += 1
			continue
		}
		cp, _ := _es_cstr(e.muted[i])
		es_unmute_path(e.client, cp, ES_MUTE_PATH_TYPE_TARGET_PREFIX)
		delete(e.muted[i], e.allocator)
		unordered_remove(&e.muted, i)
	}
	for root in e.router.roots {
		have := false
		for m in e.muted {
			if m == root.real {
				have = true
				break
			}
		}
		if have {
			continue
		}
		cp, ok := _es_cstr(root.real)
		if !ok {
			continue
		}
		if es_mute_path(e.client, cp, ES_MUTE_PATH_TYPE_TARGET_PREFIX) == 0 {
			s := make([]u8, len(root.real), e.allocator)
			copy(s, root.real)
			append(&e.muted, string(s))
		}
	}
}

@(private)
_es_cstr :: proc(s: string) -> (cstring, bool) {
	b := make([]u8, len(s) + 1, context.temp_allocator)
	copy(b, s)
	return cstring(raw_data(b)), true
}

@(private)
_es_token :: proc "contextless" (p: rawptr) -> string {
	if p == nil {
		return ""
	}
	t := (^Es_Token)(p)
	if t.data == nil || t.length == 0 || t.length > 1 << 16 {
		return ""
	}
	return string(t.data[:t.length])
}

@(private)
_es_file :: proc "contextless" (p: rawptr) -> string {
	if p == nil {
		return ""
	}
	return _es_token(&(^Es_File)(p).path)
}

@(private)
_ptr_at :: #force_inline proc "contextless" (base: rawptr, off: uintptr) -> rawptr {
	return (^rawptr)(uintptr(base) + off)^
}

@(private)
_u32_at :: #force_inline proc "contextless" (base: rawptr, off: uintptr) -> u32 {
	return (^u32)(uintptr(base) + off)^
}

@(private)
_i32_at :: #force_inline proc "contextless" (base: rawptr, off: uintptr) -> i32 {
	return (^i32)(uintptr(base) + off)^
}

@(private)
_es_handler :: proc "c" (b: ^Es_Block, client: rawptr, msg: rawptr) {
	e := b.es
	context = runtime.default_context()
	proc_ptr := _ptr_at(msg, OFF_MSG_PROCESS)
	if proc_ptr == nil {
		return
	}
	pid := prim.Pid(_i32_at(proc_ptr, OFF_PROC_PID))
	ppid := prim.Pid(_i32_at(proc_ptr, OFF_PROC_PPID))
	if pid == e.self {
		return
	}
	ev := rawptr(uintptr(msg) + OFF_MSG_EVENT)
	op: Op
	path, dir, name, from: string
	flags: u32
	switch _u32_at(msg, OFF_MSG_EVENT_TYPE) {
	case ES_EVENT_TYPE_NOTIFY_OPEN:
		flags = _u32_at(ev, 0)
		if flags & FWRITE == 0 {
			return
		}
		op = .Truncate if flags & O_TRUNC_DARWIN != 0 else .Write
		path = _es_file(_ptr_at(ev, 8))
	case ES_EVENT_TYPE_NOTIFY_CLOSE:
		op = .Close
		path = _es_file(_ptr_at(ev, 8))
	case ES_EVENT_TYPE_NOTIFY_CREATE:
		op = .Write
		if _u32_at(ev, 0) == ES_DESTINATION_TYPE_EXISTING_FILE {
			path = _es_file(_ptr_at(ev, 8))
		} else {
			dir = _es_file(_ptr_at(ev, 8))
			name = _es_token(rawptr(uintptr(ev) + 16))
		}
	case ES_EVENT_TYPE_NOTIFY_RENAME:
		op = .Rename
		from = _es_file(_ptr_at(ev, 0))
		if _u32_at(ev, 8) == ES_DESTINATION_TYPE_EXISTING_FILE {
			path = _es_file(_ptr_at(ev, 16))
		} else {
			dir = _es_file(_ptr_at(ev, 16))
			name = _es_token(rawptr(uintptr(ev) + 24))
		}
	case ES_EVENT_TYPE_NOTIFY_UNLINK:
		op = .Remove
		path = _es_file(_ptr_at(ev, 0))
	case ES_EVENT_TYPE_NOTIFY_LINK:
		op = .Link
		from = _es_file(_ptr_at(ev, 0))
		dir = _es_file(_ptr_at(ev, 8))
		name = _es_token(rawptr(uintptr(ev) + 16))
	case ES_EVENT_TYPE_NOTIFY_TRUNCATE:
		op = .Truncate
		path = _es_file(_ptr_at(ev, 0))
	case ES_EVENT_TYPE_NOTIFY_SETMODE:
		op = .Chmod
		path = _es_file(_ptr_at(ev, 8))
	case ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA:
		op = .Exchange
		from = _es_file(_ptr_at(ev, 0))
		path = _es_file(_ptr_at(ev, 8))
	case ES_EVENT_TYPE_NOTIFY_CLONE:
		op = .Write
		from = _es_file(_ptr_at(ev, 0))
		dir = _es_file(_ptr_at(ev, 8))
		name = _es_token(rawptr(uintptr(ev) + 16))
	case ES_EVENT_TYPE_NOTIFY_COPYFILE:
		op = .Write
		from = _es_file(_ptr_at(ev, 0))
		if target := _ptr_at(ev, 8); target != nil {
			path = _es_file(target)
		} else {
			dir = _es_file(_ptr_at(ev, 16))
			name = _es_token(rawptr(uintptr(ev) + 24))
		}
	case:
		return
	}
	lineage: [MAX_LINEAGE]prim.Pid
	n := _walk_lineage(pid, ppid, lineage[:])
	sync.mutex_lock(&e.mutex)
	defer sync.mutex_unlock(&e.mutex)
	target_len := len(dir) + 1 + len(name) if len(dir) > 0 else len(path)
	size := 1 + 4 + 10 + n * 4 + 10 + target_len + 10 + len(from)
	if len(e.queue) + size > cap(e.queue) {
		e.overflow = true
	} else {
		w := prim.Writer{buf = &e.queue}
		prim.write_u8(&w, u8(op))
		prim.write_u32le(&w, flags)
		prim.write_uvarint(&w, u64(n))
		for p in lineage[:n] {
			prim.write_u32le(&w, u32(p))
		}
		if len(dir) > 0 {
			sz := len(dir) + 1 + len(name)
			prim.write_uvarint(&w, u64(sz))
			append(&e.queue, dir)
			append(&e.queue, '/')
			append(&e.queue, name)
		} else {
			prim.write_str(&w, path)
		}
		prim.write_str(&w, from)
	}
	one := [1]u8{1}
	posix.write(e.pipe[1], &one[0], 1)
}

@(private)
_es_on_pipe :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	e := (^Endpoint)(data)
	drain: [256]u8
	for posix.read(e.pipe[0], &drain[0], len(drain)) > 0 {
	}
	sync.mutex_lock(&e.mutex)
	e.queue, e.spare = e.spare, e.queue
	overflow := e.overflow
	e.overflow = false
	sync.mutex_unlock(&e.mutex)
	defer clear(&e.spare)
	if overflow && e.router.reg != nil {
		for m in e.router.reg.mounts {
			if m != nil {
				fs.mount_mark_rescan(m)
			}
		}
	}
	if e.router.reg != nil && len(e.router.roots) != len(e.router.reg.mounts) {
		_es_sync_paths(e)
	}
	rd := prim.reader(e.spare[:])
	pids: [MAX_LINEAGE]prim.Pid
	for prim.reader_remaining(&rd) > 0 {
		w: Write
		w.op = Op(prim.read_u8(&rd))
		w.flags = prim.read_u32le(&rd)
		n := int(prim.read_uvarint(&rd))
		if n > MAX_LINEAGE || !prim.reader_ok(&rd) {
			break
		}
		for i in 0 ..< n {
			pids[i] = prim.Pid(i32(prim.read_u32le(&rd)))
		}
		w.lineage = pids[:n]
		if n > 0 {
			w.pid = pids[0]
			w.tid = pids[0]
		}
		w.path = prim.read_str(&rd)
		w.from = prim.read_str(&rd)
		w.exact = true
		if !prim.reader_ok(&rd) {
			break
		}
		e.stats.notifications += 1
		e.stats.reported += 1
		deliver(&e.router, e.sink, &w)
	}
	intrinsics.atomic_thread_fence(.Seq_Cst)
}

endpoint_set_fallback :: proc(e: ^Endpoint, l: ^Libproc) {
	e.fallback = l
}

@(private)
_es_changed :: proc(data: rawptr, m: ^fs.Mount, rel: string) -> (^fs.Scope, bool) {
	e := (^Endpoint)(data)
	if e.fallback == nil {
		return nil, false
	}
	if e.fallback.router.reg == nil {
		router_bind(&e.fallback.router, e.router.reg)
	}
	return libproc_changed(e.fallback, m, rel)
}

@(private)
_es_fence :: proc(data: rawptr, reg: ^fs.Registry, done: proc(data: rawptr), done_data: rawptr) {
	e := (^Endpoint)(data)
	if e.client != nil {
		_es_on_pipe(e.loop, prim.Fd(e.pipe[0]), {.Read}, e)
	}
	done(done_data)
}

@(private)
_es_gate :: proc(data: rawptr, root: string, exempt: []prim.Pid) -> (u32, bool) {
	e := (^Endpoint)(data)
	if e.fallback == nil {
		return 0, false
	}
	return _libproc_gate(e.fallback, root, exempt)
}

@(private)
_es_ungate :: proc(data: rawptr, id: u32) {
	e := (^Endpoint)(data)
	if e.fallback != nil {
		_libproc_ungate(e.fallback, id)
	}
}

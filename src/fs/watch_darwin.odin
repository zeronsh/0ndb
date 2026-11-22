package fs

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "../prim"

foreign import coreservices "system:CoreServices.framework"
foreign import corefoundation "system:CoreFoundation.framework"
foreign import libsystem "system:System"

@(private)
FS_EVENT_STREAM_EVENT_ID_SINCE_NOW :: u64(0xFFFFFFFFFFFFFFFF)
@(private)
FLAG_NO_DEFER :: u32(0x02)
@(private)
FLAG_WATCH_ROOT :: u32(0x04)
@(private)
FLAG_FILE_EVENTS :: u32(0x10)
@(private)
EVENT_MUST_SCAN :: u32(0x01)
@(private)
EVENT_USER_DROPPED :: u32(0x02)
@(private)
EVENT_KERNEL_DROPPED :: u32(0x04)
@(private)
EVENT_ROOT_CHANGED :: u32(0x20)
@(private)
CF_STRING_ENCODING_UTF8 :: u32(0x08000100)

@(private)
Fs_Event_Context :: struct {
	version:          c.long,
	info:             rawptr,
	retain:           rawptr,
	release:          rawptr,
	copy_description: rawptr,
}

@(private)
Fs_Event_Callback :: #type proc "c" (stream: rawptr, info: rawptr, n: c.size_t, paths: [^]cstring, flags: [^]u32, ids: [^]u64)

@(private)
foreign coreservices {
	FSEventStreamCreate :: proc(allocator: rawptr, cb: Fs_Event_Callback, ctx: ^Fs_Event_Context, paths: rawptr, since: u64, latency: f64, flags: u32) -> rawptr ---
	FSEventStreamSetDispatchQueue :: proc(stream: rawptr, queue: rawptr) ---
	FSEventStreamStart :: proc(stream: rawptr) -> b8 ---
	FSEventStreamStop :: proc(stream: rawptr) ---
	FSEventStreamInvalidate :: proc(stream: rawptr) ---
	FSEventStreamRelease :: proc(stream: rawptr) ---
}

@(private)
foreign corefoundation {
	CFStringCreateWithBytes :: proc(alloc: rawptr, bytes: [^]u8, n: c.long, encoding: u32, external: b8) -> rawptr ---
	CFArrayCreate :: proc(alloc: rawptr, values: [^]rawptr, n: c.long, callbacks: rawptr) -> rawptr ---
	CFRelease :: proc(obj: rawptr) ---
	kCFTypeArrayCallBacks: u8
}

@(private)
foreign libsystem {
	malloc_zone_pressure_relief :: proc(zone: rawptr, goal: c.size_t) -> c.size_t ---
	dispatch_queue_create :: proc(label: cstring, attr: rawptr) -> rawptr ---
	dispatch_release :: proc(obj: rawptr) ---
}

@(private)
Darwin_Stream :: struct {
	reg:    ^Registry,
	slot:   int,
	stream: rawptr,
}

_Registry_Os :: struct {
	queue:   rawptr,
	pipe:    [2]posix.FD,
	mutex:   sync.Mutex,
	events:  [dynamic]u8,
	streams: [dynamic]^Darwin_Stream,
	watch:   prim.Watch,
	full:    bool,
}

@(private)
_registry_os_init :: proc(reg: ^Registry) -> Error {
	reg.os.pipe = {-1, -1}
	if posix.pipe(&reg.os.pipe) != .OK {
		return .Io
	}
	for fd in reg.os.pipe {
		flags := posix.fcntl(fd, .GETFL)
		posix.fcntl(fd, .SETFL, flags | i32(posix.O_NONBLOCK))
		posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))
	}
	reg.os.queue = dispatch_queue_create("0ndb.fsevents", nil)
	reg.os.events = make([dynamic]u8, reg.allocator)
	reg.os.streams = make([dynamic]^Darwin_Stream, reg.allocator)
	return .None
}

@(private)
_registry_os_destroy :: proc(reg: ^Registry) {
	for s in reg.os.streams {
		stop_stream(s)
		free(s, reg.allocator)
	}
	delete(reg.os.streams)
	if reg.loop != nil && reg.os.watch != 0 {
		prim.unwatch(reg.loop, reg.os.watch)
	}
	if reg.os.queue != nil {
		dispatch_release(reg.os.queue)
	}
	for fd in reg.os.pipe {
		if fd >= 0 {
			posix.close(fd)
		}
	}
	delete(reg.os.events)
}

@(private)
stop_stream :: proc(s: ^Darwin_Stream) {
	if s.stream != nil {
		FSEventStreamStop(s.stream)
		FSEventStreamInvalidate(s.stream)
		FSEventStreamRelease(s.stream)
		s.stream = nil
	}
}

@(private)
_registry_os_attach :: proc(reg: ^Registry, loop: ^prim.Loop) -> Error {
	w, err := prim.watch(loop, prim.Fd(reg.os.pipe[0]), {.Read}, reg, proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
		_registry_os_read((^Registry)(data))
	})
	if err != .None {
		return from_prim(err)
	}
	reg.os.watch = w
	return .None
}

@(private)
_registry_wait :: proc(reg: ^Registry, ms: i32) -> bool {
	fds := [1]posix.pollfd{{fd = reg.os.pipe[0], events = {.IN}}}
	return posix.poll(&fds[0], 1, ms) > 0
}

@(private)
fs_event_cb :: proc "c" (stream: rawptr, info: rawptr, n: c.size_t, paths: [^]cstring, flags: [^]u32, ids: [^]u64) {
	s := (^Darwin_Stream)(info)
	context = runtime.default_context()
	reg := s.reg
	sync.mutex_lock(&reg.os.mutex)
	for i in 0 ..< int(n) {
		p := string(paths[i])
		f := flags[i]
		hdr: [9]u8
		prim.put_u32le(hdr[0:4], u32(s.slot))
		hdr[4] = 1 if f & (EVENT_MUST_SCAN | EVENT_USER_DROPPED | EVENT_KERNEL_DROPPED | EVENT_ROOT_CHANGED) != 0 else 0
		prim.put_u32le(hdr[5:9], u32(len(p)))
		append(&reg.os.events, ..hdr[:])
		append(&reg.os.events, ..transmute([]u8)p)
	}
	sync.mutex_unlock(&reg.os.mutex)
	one := [1]u8{1}
	posix.write(reg.os.pipe[1], &one[0], 1)
}

@(private)
_watch_mount :: proc(reg: ^Registry, m: ^Mount) -> Error {
	s := new(Darwin_Stream, reg.allocator)
	s.reg = reg
	s.slot = m.slot
	str := CFStringCreateWithBytes(nil, raw_data(m.root), c.long(len(m.root)), CF_STRING_ENCODING_UTF8, false)
	if str == nil {
		free(s, reg.allocator)
		return .No_Memory
	}
	vals := [1]rawptr{str}
	arr := CFArrayCreate(nil, &vals[0], 1, &kCFTypeArrayCallBacks)
	CFRelease(str)
	if arr == nil {
		free(s, reg.allocator)
		return .No_Memory
	}
	ctx := Fs_Event_Context {
		info = s,
	}
	s.stream = FSEventStreamCreate(nil, fs_event_cb, &ctx, arr, FS_EVENT_STREAM_EVENT_ID_SINCE_NOW, 0.01, FLAG_NO_DEFER | FLAG_FILE_EVENTS | FLAG_WATCH_ROOT)
	CFRelease(arr)
	if s.stream == nil {
		free(s, reg.allocator)
		return .Unsupported
	}
	FSEventStreamSetDispatchQueue(s.stream, reg.os.queue)
	if !FSEventStreamStart(s.stream) {
		stop_stream(s)
		free(s, reg.allocator)
		return .Unsupported
	}
	append(&reg.os.streams, s)
	return .None
}

@(private)
_unwatch_mount :: proc(reg: ^Registry, m: ^Mount) {
	for s, i in reg.os.streams {
		if s.slot == m.slot {
			stop_stream(s)
			free(s, reg.allocator)
			ordered_remove(&reg.os.streams, i)
			return
		}
	}
}

@(private)
_os_watch_dir :: proc(reg: ^Registry, m: ^Mount, rel: string, parent_wd: i32) -> (wd: i32, err: Error) {
	return -1, .None
}

@(private)
_registry_os_read :: proc(reg: ^Registry) -> Error {
	drain: [256]u8
	for posix.read(reg.os.pipe[0], &drain[0], len(drain)) > 0 {
	}
	sync.mutex_lock(&reg.os.mutex)
	events := make([]u8, len(reg.os.events), context.temp_allocator)
	copy(events, reg.os.events[:])
	clear(&reg.os.events)
	sync.mutex_unlock(&reg.os.mutex)
	pos := 0
	for pos + 9 <= len(events) {
		slot := int(prim.get_u32le(events[pos:]))
		rescan := events[pos + 4] != 0
		l := int(prim.get_u32le(events[pos + 5:]))
		pos += 9
		if pos + l > len(events) {
			break
		}
		p := string(events[pos:pos + l])
		pos += l
		if slot >= len(reg.mounts) || reg.mounts[slot] == nil {
			continue
		}
		m := reg.mounts[slot]
		if rescan {
			mount_mark_rescan(m)
			continue
		}
		if m.has_git && (strings.has_prefix(p, m.git.dir) || strings.has_prefix(p, m.git.common)) {
			if path_parent(p) == m.git.dir && path_name(p) == "index.lock" {
				mount_git_lock(m, prim.exists(m.vfs, p))
			}
			mount_mark_git(m)
			continue
		}
		if p == m.root {
			continue
		}
		if path_under(p, m.root) {
			mount_mark(m, p[len(m.root) + 1:])
		}
	}
	return .None
}


@(private)
_heap_release :: proc() {
	malloc_zone_pressure_relief(nil, 0)
}

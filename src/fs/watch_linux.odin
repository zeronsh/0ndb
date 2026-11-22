package fs

import "core:c"
import "core:sync"
import "core:sys/linux"
import "../prim"

@(private)
WATCH_REC :: 16

@(private)
WATCH_MASK :: linux.Inotify_Event_Mask {
	.MODIFY,
	.ATTRIB,
	.CLOSE_WRITE,
	.MOVED_FROM,
	.MOVED_TO,
	.CREATE,
	.DELETE,
	.DELETE_SELF,
	.MOVE_SELF,
	.ONLYDIR,
	.DONT_FOLLOW,
	.EXCL_UNLINK,
}

@(private)
GIT_MASK :: linux.Inotify_Event_Mask{.MODIFY, .CLOSE_WRITE, .MOVED_TO, .MOVED_FROM, .CREATE, .DELETE, .ONLYDIR}

_Registry_Os :: struct {
	ifd:      linux.Fd,
	table:    linux.Fd,
	names:    linux.Fd,
	names_end: u64,
	mutex:    sync.Mutex,
	watch:    prim.Watch,
	full:     bool,
	buf:      [64 * 1024]u8,
}

@(private)
_registry_os_init :: proc(reg: ^Registry) -> Error {
	reg.os.ifd = -1
	reg.os.table = -1
	reg.os.names = -1
	fd, errno := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return from_errno(errno)
	}
	reg.os.ifd = fd
	id: prim.Id
	prim.random_fill(reg.random, id[:])
	hex := prim.id_hex(id)
	pbuf: prim.Path_Buf
	for ext, i in ([]string{".wd", ".names"}) {
		name := make([]u8, len(hex) + len(ext), context.temp_allocator)
		copy(name, hex[:])
		copy(name[len(hex):], ext)
		p, ok := path_join_buf(pbuf[:], reg.run_dir, string(name))
		if !ok {
			return .Name_Too_Long
		}
		cp, _ := prim.cpath(p, &pbuf)
		tfd, terr := linux.open(cp, {.RDWR, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
		if terr != .NONE {
			return from_errno(terr)
		}
		linux.unlink(cp)
		if i == 0 {
			reg.os.table = tfd
		} else {
			reg.os.names = tfd
		}
	}
	return .None
}

@(private)
_registry_os_destroy :: proc(reg: ^Registry) {
	if reg.loop != nil && reg.os.watch != 0 {
		prim.unwatch(reg.loop, reg.os.watch)
	}
	if reg.os.ifd >= 0 {
		linux.close(reg.os.ifd)
	}
	if reg.os.table >= 0 {
		linux.close(reg.os.table)
	}
	if reg.os.names >= 0 {
		linux.close(reg.os.names)
	}
	reg.os.ifd = -1
	reg.os.table = -1
	reg.os.names = -1
}

@(private)
_registry_os_attach :: proc(reg: ^Registry, loop: ^prim.Loop) -> Error {
	w, err := prim.watch(loop, prim.Fd(reg.os.ifd), {.Read}, reg, proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
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
	fds := [1]linux.Poll_Fd{{fd = reg.os.ifd, events = {.IN}}}
	n, errno := linux.poll(fds[:], ms)
	return errno == .NONE && n > 0
}

@(private)
put_watch :: proc(reg: ^Registry, wd: linux.Wd, slot: int, parent: i32, name: string, git: bool) -> Error {
	sync.mutex_lock(&reg.os.mutex)
	defer sync.mutex_unlock(&reg.os.mutex)
	off := reg.os.names_end
	if len(name) > 0 {
		n, errno := linux.pwrite(reg.os.names, transmute([]u8)name, i64(off))
		if errno != .NONE || n != len(name) {
			return .Io
		}
		reg.os.names_end += u64(len(name))
	}
	b: [WATCH_REC]u8
	prim.put_u32le(b[0:4], u32(slot + 1))
	prim.put_u32le(b[4:8], u32(parent))
	prim.put_u32le(b[8:12], u32(off))
	prim.put_u32le(b[12:16], u32(len(name)) | (0x8000_0000 if git else 0))
	n, errno := linux.pwrite(reg.os.table, b[:], i64(wd) * WATCH_REC)
	if errno != .NONE || n != WATCH_REC {
		return .Io
	}
	return .None
}

@(private)
get_watch :: proc(reg: ^Registry, wd: i32) -> (slot: int, parent: i32, name_off: u32, name_len: u32, git: bool, ok: bool) {
	if wd < 0 {
		return
	}
	b: [WATCH_REC]u8
	n, errno := linux.pread(reg.os.table, b[:], i64(wd) * WATCH_REC)
	if errno != .NONE || n != WATCH_REC {
		return
	}
	s := prim.get_u32le(b[0:4])
	if s == 0 {
		return
	}
	l := prim.get_u32le(b[12:16])
	return int(s) - 1, i32(prim.get_u32le(b[4:8])), prim.get_u32le(b[8:12]), l & 0x7fff_ffff, l & 0x8000_0000 != 0, true
}

@(private)
_watch_mount :: proc(reg: ^Registry, m: ^Mount) -> Error {
	if reg.os.ifd < 0 {
		return .None
	}
	pbuf: prim.Path_Buf
	cp, cerr := prim.cpath(m.root, &pbuf)
	if cerr != .None {
		return from_prim(cerr)
	}
	wd, errno := linux.inotify_add_watch(reg.os.ifd, cp, WATCH_MASK)
	if errno != .NONE {
		if errno == .ENOSPC {
			reg.os.full = true
			return .None
		}
		return from_errno(errno)
	}
	m.root_wd = i32(wd)
	put_watch(reg, wd, m.slot, -1, "", false) or_return
	if m.has_git {
		gp, _ := prim.cpath(m.git.dir, &pbuf)
		gwd, gerr := linux.inotify_add_watch(reg.os.ifd, gp, GIT_MASK)
		if gerr == .NONE {
			put_watch(reg, gwd, m.slot, -1, "", true) or_return
		}
	}
	return .None
}

@(private)
_unwatch_mount :: proc(reg: ^Registry, m: ^Mount) {
	if m.root_wd >= 0 && reg.os.ifd >= 0 {
		linux.inotify_rm_watch(reg.os.ifd, linux.Wd(m.root_wd))
	}
}

@(private)
_os_watch_dir :: proc(reg: ^Registry, m: ^Mount, rel: string, parent_wd: i32) -> (wd: i32, err: Error) {
	if !reg.os_ready || reg.os.ifd < 0 {
		return -1, .None
	}
	if len(rel) == 0 {
		return m.root_wd, .None
	}
	pbuf: prim.Path_Buf
	abs, ok := path_join_buf(pbuf[:], m.root, rel)
	if !ok {
		return -1, .Name_Too_Long
	}
	cbuf: prim.Path_Buf
	cp, _ := prim.cpath(abs, &cbuf)
	w, errno := linux.inotify_add_watch(reg.os.ifd, cp, WATCH_MASK)
	if errno != .NONE {
		if errno == .ENOSPC {
			reg.os.full = true
			note_unwatched(m, rel)
			return -1, .None
		}
		if errno == .ENOENT || errno == .ENOTDIR {
			return -1, .None
		}
		return -1, from_errno(errno)
	}
	parent := parent_wd
	if parent < 0 {
		parent = m.root_wd
		if pp := path_parent(rel); len(pp) > 0 {
			pbuf2: prim.Path_Buf
			pabs, pok := path_join_buf(pbuf2[:], m.root, pp)
			if pok {
				cbuf2: prim.Path_Buf
				pcp, _ := prim.cpath(pabs, &cbuf2)
				if pw, perr := linux.inotify_add_watch(reg.os.ifd, pcp, WATCH_MASK); perr == .NONE {
					parent = i32(pw)
				}
			}
		}
	}
	put_watch(reg, w, m.slot, parent, path_name(rel), false) or_return
	return i32(w), .None
}

@(private)
resolve_wd :: proc(reg: ^Registry, wd: i32, buf: []u8) -> (slot: int, rel: string, git: bool, ok: bool) {
	parts: [256][2]u32
	n := 0
	cur := wd
	for _ in 0 ..< 256 {
		s, parent, off, l, g, found := get_watch(reg, cur)
		if !found {
			return
		}
		if parent < 0 {
			slot = s
			git = g
			break
		}
		if n >= len(parts) {
			return
		}
		parts[n] = {off, l}
		n += 1
		cur = parent
	}
	pos := 0
	for i := n - 1; i >= 0; i -= 1 {
		l := int(parts[i][1])
		if pos + l + 1 > len(buf) {
			return
		}
		if pos > 0 {
			buf[pos] = '/'
			pos += 1
		}
		got, errno := linux.pread(reg.os.names, buf[pos:pos + l], i64(parts[i][0]))
		if errno != .NONE || got != l {
			return
		}
		pos += l
	}
	return slot, string(buf[:pos]), git, true
}

@(private)
_registry_os_read :: proc(reg: ^Registry) -> Error {
	if reg.os.ifd < 0 {
		return .None
	}
	for {
		n, errno := linux.read(reg.os.ifd, reg.os.buf[:])
		if errno == .EAGAIN {
			return .None
		}
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return from_errno(errno)
		}
		if n <= 0 {
			return .None
		}
		pos := 0
		for pos + 16 <= n {
			wd := i32(prim.get_u32le(reg.os.buf[pos:]))
			mask := transmute(linux.Inotify_Event_Mask)prim.get_u32le(reg.os.buf[pos + 4:])
			l := int(prim.get_u32le(reg.os.buf[pos + 12:]))
			name_bytes := reg.os.buf[pos + 16:][:min(l, n - pos - 16)]
			nl := 0
			for nl < len(name_bytes) && name_bytes[nl] != 0 {
				nl += 1
			}
			name := string(name_bytes[:nl])
			pos += 16 + l
			if .Q_OVERFLOW in mask {
				for m in reg.mounts {
					if m != nil {
						mount_mark_rescan(m)
					}
				}
				continue
			}
			if .IGNORED in mask {
				continue
			}
			pbuf: [prim.PATH_MAX]u8
			slot, dir, git, ok := resolve_wd(reg, wd, pbuf[:])
			if !ok || slot >= len(reg.mounts) || reg.mounts[slot] == nil {
				continue
			}
			m := reg.mounts[slot]
			if git {
				if name == "index.lock" {
					if .CREATE in mask || .MOVED_TO in mask {
						mount_git_lock(m, true)
					} else if .DELETE in mask || .MOVED_FROM in mask {
						mount_git_lock(m, false)
					}
				}
				if name == "HEAD" || name == "index" || name == "ORIG_HEAD" || name == "MERGE_HEAD" {
					mount_mark_git(m)
				}
				continue
			}
			if .DELETE_SELF in mask || .MOVE_SELF in mask {
				if len(dir) == 0 {
					mount_mark_rescan(m)
				} else {
					mount_mark(m, dir)
				}
				continue
			}
			if len(name) == 0 {
				continue
			}
			rel := name
			if len(dir) > 0 {
				full := make([]u8, len(dir) + 1 + len(name), context.temp_allocator)
				copy(full, dir)
				full[len(dir)] = '/'
				copy(full[len(dir) + 1:], name)
				rel = string(full)
			}
			mount_mark(m, rel)
			if .CLOSE_WRITE in mask {
				mount_closed(m, rel)
			}
		}
	}
}


foreign import libc "system:c"

@(private)
foreign libc {
	malloc_trim :: proc(pad: c.size_t) -> c.int ---
}

@(private)
_heap_release :: proc() {
	malloc_trim(0)
}

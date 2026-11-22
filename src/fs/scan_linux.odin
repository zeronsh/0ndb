package fs

import "core:sys/linux"
import "../prim"

@(private)
STATX_WANT :: linux.Statx_Mask{.TYPE, .MODE, .INO, .SIZE, .MTIME, .CTIME}

@(private)
_open_root :: proc(sc: ^Scanner, root: string) -> (prim.Fd, Error) {
	fd, err := prim.open_file(sc.vfs, root, {.Directory})
	return fd, from_prim(err)
}

@(private)
statx_to :: proc "contextless" (sx: ^linux.Statx) -> (Disk_Kind, Stat) {
	mode := transmute(u32)sx.mode
	st := Stat {
		mtime_ns = i64(sx.mtime.sec) * 1_000_000_000 + i64(sx.mtime.nsec),
		ctime_ns = i64(sx.ctime.sec) * 1_000_000_000 + i64(sx.ctime.nsec),
		size     = i64(sx.size),
		ino      = u64(sx.ino),
		mode     = mode,
	}
	kind: Disk_Kind
	switch mode & 0o170000 {
	case 0o100000:
		kind = .File
	case 0o040000:
		kind = .Dir
	case 0o120000:
		kind = .Symlink
	case:
		kind = .Other
	}
	return kind, st
}

@(private)
_read_dir :: proc(sc: ^Scanner, t: ^Dir_Task, raw: ^[dynamic]Raw_Dirent, gitignore: ^[]u8) -> Error {
	pbuf: prim.Path_Buf
	rel := t.path if len(t.path) > 0 else "."
	cp, cerr := prim.cpath(rel, &pbuf)
	if cerr != .None {
		return from_prim(cerr)
	}
	dfd, errno := linux.openat(linux.Fd(sc.root_fd), cp, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if errno != .NONE {
		return from_errno(errno)
	}
	defer linux.close(dfd)
	buf: [32 * 1024]u8
	for {
		n, gerr := linux.getdents(dfd, buf[:])
		if gerr == .EINTR {
			continue
		}
		if gerr != .NONE {
			return from_errno(gerr)
		}
		if n <= 0 {
			break
		}
		pos := 0
		for pos < n {
			if pos + 19 > n {
				return .Corrupt
			}
			reclen := int(u16(buf[pos + 16]) | u16(buf[pos + 17]) << 8)
			dtype := buf[pos + 18]
			if reclen < 20 || pos + reclen > n {
				return .Corrupt
			}
			name_bytes := buf[pos + 19:pos + reclen]
			nl := 0
			for nl < len(name_bytes) && name_bytes[nl] != 0 {
				nl += 1
			}
			name := string(name_bytes[:nl])
			pos += reclen
			if name == "." || name == ".." || name_internal(name) {
				continue
			}
			r := Raw_Dirent {
				name_off = u32(len(t.names)),
				name_len = u32(nl),
			}
			switch dtype {
			case 4:
				r.kind = .Dir
			case 8:
				r.kind = .File
			case 10:
				r.kind = .Symlink
			case 0:
				r.kind = .Missing
			case:
				r.kind = .Other
			}
			append(&t.names, ..transmute([]u8)name)
			append(raw, r)
		}
	}
	for &r in raw {
		name := string(t.names[r.name_off:][:r.name_len])
		ncp, nerr := prim.cpath(name, &pbuf)
		if nerr != .None {
			r.kind = .Other
			continue
		}
		if r.kind == .Other {
			continue
		}
		sx: linux.Statx
		if serr := linux.statx(dfd, ncp, {.SYMLINK_NOFOLLOW, .STATX_DONT_SYNC}, STATX_WANT, &sx); serr != .NONE {
			if serr == .ENOENT || serr == .ENOTDIR {
				r.kind = .Missing
				continue
			}
			return from_errno(serr)
		}
		r.kind, r.stat = statx_to(&sx)
		r.statted = true
		if r.kind == .Symlink {
			tbuf: [prim.PATH_MAX]u8
			tn, lerr := linux.readlinkat(dfd, ncp, tbuf[:])
			if lerr == .ENOENT || lerr == .ENOTDIR {
				r.kind = .Missing
				continue
			}
			if lerr != .NONE {
				return from_errno(lerr)
			}
			if tn <= 0 || tn >= len(tbuf) {
				r.kind = .Other
				continue
			}
			r.target_off = u32(len(t.names))
			r.target_len = u32(tn)
			append(&t.names, ..tbuf[:tn])
		} else if r.kind == .File && name == ".gitignore" && gitignore^ == nil && r.stat.size < 8 << 20 {
			gitignore^ = read_small_at(dfd, ncp, int(r.stat.size), sc.allocator) or_return
		}
	}
	if sc.opts.read_limit > 0 {
		budget := sc.opts.read_budget if sc.opts.read_budget > 0 else 8 << 20
		for &r in raw {
			if r.kind != .File || !r.statted || r.stat.size > sc.opts.read_limit || r.stat.size > budget {
				continue
			}
			name := string(t.names[r.name_off:][:r.name_len])
			ncp, nerr := prim.cpath(name, &pbuf)
			if nerr != .None {
				continue
			}
			fd, oerr := linux.openat(dfd, ncp, {.NOFOLLOW, .CLOEXEC})
			if oerr != .NONE {
				continue
			}
			size := int(r.stat.size)
			start := len(t.names)
			resize(&t.names, start + size + 1)
			n := 0
			for n < size + 1 {
				got, rerr := linux.pread(fd, t.names[start + n:], i64(n))
				if rerr == .EINTR {
					continue
				}
				if rerr != .NONE || got <= 0 {
					break
				}
				n += got
			}
			linux.close(fd)
			if n != size {
				resize(&t.names, start)
				continue
			}
			resize(&t.names, start + size)
			r.data_off = u32(start)
			r.data_len = u32(size)
			r.has_data = true
			budget -= i64(size)
		}
	}
	w := 0
	for r in raw {
		if r.kind != .Missing {
			raw[w] = r
			w += 1
		}
	}
	resize(raw, w)
	return .None
}

@(private)
read_small_at :: proc(dfd: linux.Fd, name: cstring, size: int, allocator := context.allocator) -> ([]u8, Error) {
	fd, errno := linux.openat(dfd, name, {.NOFOLLOW, .CLOEXEC})
	if errno == .ENOENT || errno == .ENOTDIR {
		return nil, .None
	}
	if errno != .NONE {
		return nil, from_errno(errno)
	}
	defer linux.close(fd)
	buf := make([]u8, size + 1, allocator)
	n := 0
	for n < len(buf) {
		r, rerr := linux.read(fd, buf[n:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE {
			delete(buf, allocator)
			return nil, from_errno(rerr)
		}
		if r <= 0 {
			break
		}
		n += r
	}
	if n > size {
		delete(buf, allocator)
		return nil, .None
	}
	return buf[:n], .None
}

from_errno :: proc "contextless" (e: linux.Errno) -> Error {
	#partial switch e {
	case .NONE:
		return .None
	case .ENOENT:
		return .Not_Found
	case .EEXIST:
		return .Exists
	case .EPERM, .EACCES, .EROFS:
		return .Permission
	case .EAGAIN, .EBUSY, .ETXTBSY:
		return .Busy
	case .EINVAL, .EBADF:
		return .Invalid
	case .ENOTDIR, .ELOOP:
		return .Not_Dir
	case .EISDIR:
		return .Is_Dir
	case .ENOTEMPTY:
		return .Not_Empty
	case .ENOSPC, .EDQUOT:
		return .No_Space
	case .ENOMEM:
		return .No_Memory
	case .EMFILE, .ENFILE:
		return .Too_Many_Files
	case .ENAMETOOLONG:
		return .Name_Too_Long
	case .EFBIG, .EOVERFLOW:
		return .Too_Large
	case .ENOSYS, .EOPNOTSUPP:
		return .Unsupported
	}
	return .Io
}

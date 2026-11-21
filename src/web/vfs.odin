package web

import "base:runtime"
import "../prim"

Extent :: struct {
	off:  i64,
	data: [dynamic]u8,
}

Mem_Node :: struct {
	path:   string,
	size:   i64,
	mode:   u32,
	refs:   int,
	linked: bool,
	ext:    [dynamic]Extent,
}

Mem_Vfs :: struct {
	files:     map[string]^Mem_Node,
	dirs:      map[string]bool,
	fds:       [dynamic]^Mem_Node,
	bytes:     i64,
	logging:   bool,
	muted:     bool,
	log:       [dynamic]u8,
	allocator: runtime.Allocator,
}

@(private)
DIR_FD :: prim.Fd(1 << 30)

@(private)
MEM_PROCS := prim.Vfs_Procs {
	open       = _mem_open,
	close      = _mem_close,
	read_at    = _mem_read_at,
	write_at   = _mem_write_at,
	datasync   = _mem_sync,
	fullsync   = _mem_sync,
	truncate   = _mem_truncate,
	punch_hole = _mem_punch,
	lock       = _mem_sync,
	fstat      = _mem_fstat,
	stat       = _mem_stat,
	rename     = _mem_rename,
	unlink     = _mem_unlink,
	rmdir      = _mem_rmdir,
	mkdir      = _mem_mkdir,
	symlink    = _mem_symlink,
	readlink   = _mem_readlink,
	fchmod     = _mem_fchmod,
	set_times  = _mem_set_times,
	dir_open   = _mem_dir_open,
	dir_next   = _mem_dir_next,
	dir_close  = _mem_dir_close,
	caps       = _mem_caps,
}

mem_vfs_init :: proc(m: ^Mem_Vfs, allocator := context.allocator) {
	m^ = {
		allocator = allocator,
	}
	m.files = make(map[string]^Mem_Node, allocator)
	m.dirs = make(map[string]bool, allocator)
	m.fds = make([dynamic]^Mem_Node, allocator)
	m.log = make([dynamic]u8, allocator)
}

mem_vfs_destroy :: proc(m: ^Mem_Vfs) {
	for k, n in m.files {
		delete(k, m.allocator)
		n.linked = false
		_node_release_unref(m, n)
	}
	for n, i in m.fds {
		if n != nil {
			m.fds[i] = nil
			_node_release(m, n)
		}
	}
	for k in m.dirs {
		delete(k, m.allocator)
	}
	delete(m.files)
	delete(m.dirs)
	delete(m.fds)
	delete(m.log)
	m^ = {}
}

mem_vfs :: proc(m: ^Mem_Vfs) -> prim.Vfs {
	return prim.Vfs{procs = &MEM_PROCS, data = m}
}

@(private)
_node_release :: proc(m: ^Mem_Vfs, n: ^Mem_Node) {
	if n.refs > 0 {
		n.refs -= 1
	}
	if n.refs > 0 || n.linked {
		return
	}
	for &e in n.ext {
		m.bytes -= i64(len(e.data))
		delete(e.data)
	}
	delete(n.ext)
	free(n, m.allocator)
}

@(private)
_node :: proc(m: ^Mem_Vfs, fd: prim.Fd) -> ^Mem_Node {
	i := int(fd) - 1
	if i < 0 || i >= len(m.fds) {
		return nil
	}
	return m.fds[i]
}

@(private)
_mem_open :: proc(data: rawptr, path: string, flags: prim.Open_Flags, mode: u32) -> (prim.Fd, prim.Error) {
	m := (^Mem_Vfs)(data)
	if .Directory in flags {
		return DIR_FD, .None
	}
	n, found := m.files[path]
	if found && .Exclusive in flags && .Create in flags {
		return prim.INVALID_FD, .Exists
	}
	if !found {
		if .Create not_in flags {
			return prim.INVALID_FD, .Not_Found
		}
		k, kerr := make([]u8, len(path), m.allocator)
		if kerr != nil {
			return prim.INVALID_FD, .No_Memory
		}
		copy(k, path)
		nn, nerr := new(Mem_Node, m.allocator)
		if nerr != nil {
			delete(k, m.allocator)
			return prim.INVALID_FD, .No_Memory
		}
		nn.mode = mode
		nn.linked = true
		nn.path = string(k)
		nn.ext = make([dynamic]Extent, m.allocator)
		m.files[string(k)] = nn
		n = nn
	} else if .Truncate in flags {
		_truncate(m, n, 0)
		_log(m, .Truncate, n.path, 0, nil)
	}
	slot := -1
	for x, i in m.fds {
		if x == nil {
			slot = i
			break
		}
	}
	if slot < 0 {
		if _, e := append(&m.fds, nil); e != nil {
			return prim.INVALID_FD, .No_Memory
		}
		slot = len(m.fds) - 1
	}
	m.fds[slot] = n
	n.refs += 1
	return prim.Fd(slot + 1), .None
}

@(private)
_mem_close :: proc(data: rawptr, fd: prim.Fd) -> prim.Error {
	m := (^Mem_Vfs)(data)
	if fd == DIR_FD {
		return .None
	}
	n := _node(m, fd)
	if n == nil {
		return .Invalid
	}
	m.fds[int(fd) - 1] = nil
	_node_release(m, n)
	return .None
}

@(private)
_mem_read_at :: proc(data: rawptr, fd: prim.Fd, buf: []u8, off: i64) -> (int, prim.Error) {
	m := (^Mem_Vfs)(data)
	n := _node(m, fd)
	if n == nil || off < 0 {
		return 0, .Invalid
	}
	if off >= n.size {
		return 0, .None
	}
	count := int(min(i64(len(buf)), n.size - off))
	out := buf[:count]
	for &b in out {
		b = 0
	}
	end := off + i64(count)
	for &e in n.ext {
		e_end := e.off + i64(len(e.data))
		if e_end <= off {
			continue
		}
		if e.off >= end {
			break
		}
		lo := max(e.off, off)
		hi := min(e_end, end)
		copy(out[lo - off:hi - off], e.data[lo - e.off:hi - e.off])
	}
	return count, .None
}

@(private)
_mem_write_at :: proc(data: rawptr, fd: prim.Fd, src: []u8, off: i64) -> prim.Error {
	m := (^Mem_Vfs)(data)
	n := _node(m, fd)
	if n == nil || off < 0 {
		return .Invalid
	}
	if len(src) == 0 {
		return .None
	}
	_write(m, n, src, off) or_return
	_log(m, .Write, n.path, off, src)
	return .None
}

@(private)
_write :: proc(m: ^Mem_Vfs, n: ^Mem_Node, src: []u8, off: i64) -> prim.Error {
	end := off + i64(len(src))
	first := len(n.ext)
	last := -1
	for &e, i in n.ext {
		e_end := e.off + i64(len(e.data))
		if e_end < off {
			continue
		}
		if e.off > end {
			if last < 0 {
				first = i
			}
			break
		}
		if i < first {
			first = i
		}
		last = i
	}
	if last < 0 {
		x := Extent{off = off, data = make([dynamic]u8, 0, len(src), m.allocator)}
		if _, e := append(&x.data, ..src); e != nil {
			delete(x.data)
			return .No_Memory
		}
		if _, e := inject_at(&n.ext, first, x); e != nil {
			delete(x.data)
			return .No_Memory
		}
		m.bytes += i64(len(src))
	} else {
		base := &n.ext[first]
		lo := min(base.off, off)
		hi := max(end, n.ext[last].off + i64(len(n.ext[last].data)))
		if lo < base.off {
			grow := int(base.off - lo)
			old := len(base.data)
			if resize(&base.data, old + grow) != nil {
				return .No_Memory
			}
			copy(base.data[grow:], base.data[:old])
			base.off = lo
			m.bytes += i64(grow)
		}
		want := int(hi - lo)
		if want > len(base.data) {
			old := len(base.data)
			if resize(&base.data, want) != nil {
				return .No_Memory
			}
			m.bytes += i64(want - old)
		}
		for k in first + 1 ..= last {
			x := &n.ext[k]
			copy(base.data[x.off - lo:], x.data[:])
			m.bytes -= i64(len(x.data))
			delete(x.data)
		}
		if last > first {
			remove_range(&n.ext, first + 1, last + 1)
		}
		copy(base.data[off - lo:], src)
	}
	n.size = max(n.size, end)
	return .None
}

@(private)
_mem_sync :: proc(data: rawptr, fd: prim.Fd) -> prim.Error {
	return .None
}

@(private)
_truncate :: proc(m: ^Mem_Vfs, n: ^Mem_Node, size: i64) {
	for i := len(n.ext) - 1; i >= 0; i -= 1 {
		e := &n.ext[i]
		if e.off >= size {
			m.bytes -= i64(len(e.data))
			delete(e.data)
			ordered_remove(&n.ext, i)
			continue
		}
		keep := int(size - e.off)
		if keep < len(e.data) {
			m.bytes -= i64(len(e.data) - keep)
			resize(&e.data, keep)
			shrink(&e.data)
		}
		break
	}
	n.size = size
}

@(private)
_mem_truncate :: proc(data: rawptr, fd: prim.Fd, size: i64) -> prim.Error {
	m := (^Mem_Vfs)(data)
	n := _node(m, fd)
	if n == nil || size < 0 {
		return .Invalid
	}
	if size < n.size {
		_truncate(m, n, size)
	}
	n.size = size
	_log(m, .Truncate, n.path, size, nil)
	return .None
}

@(private)
_mem_punch :: proc(data: rawptr, fd: prim.Fd, off: i64, size: i64) -> prim.Error {
	m := (^Mem_Vfs)(data)
	n := _node(m, fd)
	if n == nil || off < 0 || size < 0 {
		return .Invalid
	}
	end := off + size
	_log(m, .Punch, n.path, off, nil, size)
	for i := 0; i < len(n.ext); {
		e := &n.ext[i]
		e_end := e.off + i64(len(e.data))
		if e_end <= off || e.off >= end {
			i += 1
			continue
		}
		if e.off >= off && e_end <= end {
			m.bytes -= i64(len(e.data))
			delete(e.data)
			ordered_remove(&n.ext, i)
			continue
		}
		if e.off < off && e_end > end {
			tail := Extent{off = end, data = make([dynamic]u8, 0, int(e_end - end), m.allocator)}
			if _, ae := append(&tail.data, ..e.data[end - e.off:]); ae != nil {
				delete(tail.data)
				return .No_Memory
			}
			if _, ie := inject_at(&n.ext, i + 1, tail); ie != nil {
				delete(tail.data)
				return .No_Memory
			}
			e = &n.ext[i]
			m.bytes -= i64(len(e.data)) - (off - e.off) - (e_end - end)
			resize(&e.data, int(off - e.off))
			shrink(&e.data)
			i += 2
			continue
		}
		if e.off < off {
			m.bytes -= e_end - off
			resize(&e.data, int(off - e.off))
			shrink(&e.data)
		} else {
			cut := int(end - e.off)
			m.bytes -= i64(cut)
			rest := len(e.data) - cut
			copy(e.data[:rest], e.data[cut:])
			resize(&e.data, rest)
			shrink(&e.data)
			e.off = end
		}
		i += 1
	}
	return .None
}

@(private)
_mem_fstat :: proc(data: rawptr, fd: prim.Fd) -> (prim.Stat, prim.Error) {
	m := (^Mem_Vfs)(data)
	if fd == DIR_FD {
		return prim.Stat{kind = .Dir, mode = 0o040700}, .None
	}
	n := _node(m, fd)
	if n == nil {
		return {}, .Invalid
	}
	return prim.Stat{size = n.size, mode = 0o100000 | n.mode, kind = .File, nlink = 1}, .None
}

@(private)
_mem_stat :: proc(data: rawptr, path: string, follow: bool) -> (prim.Stat, prim.Error) {
	m := (^Mem_Vfs)(data)
	if n, ok := m.files[path]; ok {
		return prim.Stat{size = n.size, mode = 0o100000 | n.mode, kind = .File, nlink = 1}, .None
	}
	if path in m.dirs || path == "." || path == "/" {
		return prim.Stat{kind = .Dir, mode = 0o040700}, .None
	}
	return {}, .Not_Found
}

@(private)
_mem_rename :: proc(data: rawptr, old: string, new: string) -> prim.Error {
	m := (^Mem_Vfs)(data)
	if old not_in m.files {
		return .Not_Found
	}
	if old == new {
		return .None
	}
	_log(m, .Rename, old, 0, transmute([]u8)new)
	if new in m.files {
		nk, target := delete_key(&m.files, new)
		delete(nk, m.allocator)
		target.path = ""
		target.linked = false
		_node_release_unref(m, target)
	}
	k, kerr := make([]u8, len(new), m.allocator)
	if kerr != nil {
		return .No_Memory
	}
	copy(k, new)
	ok_key, n := delete_key(&m.files, old)
	delete(ok_key, m.allocator)
	n.path = string(k)
	m.files[string(k)] = n
	return .None
}

@(private)
_node_release_unref :: proc(m: ^Mem_Vfs, n: ^Mem_Node) {
	n.refs += 1
	_node_release(m, n)
}

@(private)
_mem_unlink :: proc(data: rawptr, path: string) -> prim.Error {
	m := (^Mem_Vfs)(data)
	if path not_in m.files {
		return .Not_Found
	}
	_log(m, .Unlink, path, 0, nil)
	k, n := delete_key(&m.files, path)
	delete(k, m.allocator)
	n.path = ""
	n.linked = false
	_node_release_unref(m, n)
	return .None
}

@(private)
_mem_rmdir :: proc(data: rawptr, path: string) -> prim.Error {
	m := (^Mem_Vfs)(data)
	if path not_in m.dirs {
		return .Not_Found
	}
	k, _ := delete_key(&m.dirs, path)
	delete(k, m.allocator)
	return .None
}

@(private)
_mem_mkdir :: proc(data: rawptr, path: string, mode: u32) -> prim.Error {
	m := (^Mem_Vfs)(data)
	if path in m.dirs {
		return .Exists
	}
	k, kerr := make([]u8, len(path), m.allocator)
	if kerr != nil {
		return .No_Memory
	}
	copy(k, path)
	m.dirs[string(k)] = true
	return .None
}

@(private)
_mem_symlink :: proc(data: rawptr, target: string, path: string) -> prim.Error {
	return .Unsupported
}

@(private)
_mem_readlink :: proc(data: rawptr, path: string, buf: []u8) -> (int, prim.Error) {
	return 0, .Unsupported
}

@(private)
_mem_fchmod :: proc(data: rawptr, fd: prim.Fd, mode: u32) -> prim.Error {
	m := (^Mem_Vfs)(data)
	if n := _node(m, fd); n != nil {
		n.mode = mode
	}
	return .None
}

@(private)
_mem_set_times :: proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> prim.Error {
	return .None
}

@(private)
_mem_dir_open :: proc(data: rawptr, d: ^prim.Dir, path: string) -> prim.Error {
	return .Unsupported
}

@(private)
_mem_dir_next :: proc(data: rawptr, d: ^prim.Dir) -> (prim.Dir_Entry, bool, prim.Error) {
	return {}, false, .Unsupported
}

@(private)
_mem_dir_close :: proc(data: rawptr, d: ^prim.Dir) {
}

@(private)
_mem_caps :: proc(data: rawptr, fd: prim.Fd) -> prim.Vfs_Caps {
	return {.Durable_Dir_Ops_With_Data, .Atomic_Group_Commit}
}

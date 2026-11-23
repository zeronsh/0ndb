package sim

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
import "core:strings"
import "../../src/obj"
import "../../src/prim"
import "../../src/zstd"

SECTOR :: 512

Inode_Kind :: enum u8 {
	File,
	Dir,
	Symlink,
}

Pend_Kind :: enum u8 {
	Write,
	Truncate,
}

Pend :: struct {
	kind:  Pend_Kind,
	off:   i64,
	size:  i64,
	bytes: []u8,
}

Inode :: struct {
	ino:      u64,
	kind:     Inode_Kind,
	mode:     u32,
	data:     [dynamic]u8,
	durable:  [dynamic]u8,
	ghost:    [dynamic]u8,
	pend:     [dynamic]Pend,
	entries:  map[string]u64,
	dentries: map[string]u64,
	target:   string,
	mtime_ns: i64,
	ctime_ns: i64,
	nlink:    int,
	lock_fd:  prim.Fd,
	opens:    int,
}

Meta_Kind :: enum u8 {
	Link,
	Unlink,
	Rename,
}

Meta_Op :: struct {
	kind:  Meta_Kind,
	dir:   u64,
	name:  string,
	ino:   u64,
	dir2:  u64,
	name2: string,
	gone:  u64,
}

Open_File :: struct {
	ino:      u64,
	writable: bool,
	append:   bool,
	wrote:    bool,
	path:     string,
}

Watch_Ev :: struct {
	path:   string,
	closed: bool,
}

Dir_Iter :: struct {
	names: []string,
	inos:  []u64,
	kinds: []prim.File_Kind,
	pos:   int,
}

Crash_Mode :: enum u8 {
	Process,
	Power,
}

Disk_Stats :: struct {
	ops:      u64,
	writes:   u64,
	syncs:    u64,
	dirsyncs: u64,
	bytes:    u64,
	crashes:  u64,
	torn:     u64,
	ghosts:   u64,
	lost:     u64,
	injected: u64,
}

Disk :: struct {
	quiet:     bool,
	probe:     int,
	freed_prefix: string,
	freed:     [dynamic][]u8,
	name:      string,
	inodes:    map[u64]^Inode,
	next_ino:  u64,
	fds:       map[prim.Fd]Open_File,
	next_fd:   prim.Fd,
	meta:      [dynamic]Meta_Op,
	wall:      proc(data: rawptr) -> i64,
	wall_data: rawptr,
	crash_at:  u64,
	force_ghost: bool,
	dead:      bool,
	fail_sync: u64,
	fail_nth:  u64,
	fail_stick: bool,
	fail_stuck: bool,
	fail_root: string,
	fail_rate: u64,
	runaway_size: i64,
	runaway_ino:  u64,
	runaway_pend: bool,
	pend_bytes:   i64,
	watching:  bool,
	watch_prefix: string,
	events:    [dynamic]Watch_Ev,
	fail_rng:  Rng,
	failing:   bool,
	trace:     u64,
	verbose:   bool,
	stats:     Disk_Stats,
	allocator: runtime.Allocator,
}

ROOT_INO :: 1

@(rodata)
DISK_PROCS := prim.Vfs_Procs {
	open       = _d_open,
	close      = _d_close,
	read_at    = _d_read_at,
	write_at   = _d_write_at,
	datasync   = _d_sync,
	fullsync   = _d_sync,
	truncate   = _d_truncate,
	punch_hole = _d_punch,
	lock       = _d_lock,
	fstat      = _d_fstat,
	stat       = _d_stat,
	rename     = _d_rename,
	unlink     = _d_unlink,
	rmdir      = _d_rmdir,
	mkdir      = _d_mkdir,
	symlink    = _d_symlink,
	readlink   = _d_readlink,
	fchmod     = _d_fchmod,
	set_times  = _d_set_times,
	dir_open   = _d_dir_open,
	dir_next   = _d_dir_next,
	dir_close  = _d_dir_close,
	caps       = _d_caps,
}

disk_init :: proc(d: ^Disk, name: string, allocator: runtime.Allocator) {
	d^ = {}
	d.allocator = allocator
	d.name = strings.clone(name, allocator)
	d.inodes = make(map[u64]^Inode, allocator)
	d.fds = make(map[prim.Fd]Open_File, allocator)
	d.meta = make([dynamic]Meta_Op, allocator)
	d.events = make([dynamic]Watch_Ev, allocator)
	d.next_ino = ROOT_INO
	d.next_fd = 16
	root := _inode_new(d, .Dir, 0o755)
	root.nlink = 2
}

disk_destroy :: proc(d: ^Disk) {
	for _, n in d.inodes {
		_inode_free(d, n)
	}
	delete(d.inodes)
	for _, of in d.fds {
		delete(of.path, d.allocator)
	}
	delete(d.fds)
	disk_events_clear(d)
	delete(d.events)
	for m in d.meta {
		_meta_free(d, m)
	}
	delete(d.meta)
	for b in d.freed {
		delete(b, d.allocator)
	}
	delete(d.freed)
	delete(d.freed_prefix, d.allocator)
	delete(d.name, d.allocator)
	d^ = {}
}

disk_vfs :: proc(d: ^Disk) -> prim.Vfs {
	return prim.Vfs{procs = &DISK_PROCS, data = d}
}

disk_open_fds :: proc(d: ^Disk) -> int {
	return len(d.fds)
}

@(private = "file")
_inode_new :: proc(d: ^Disk, kind: Inode_Kind, mode: u32) -> ^Inode {
	n := new(Inode, d.allocator)
	n.ino = d.next_ino
	d.next_ino += 1
	n.kind = kind
	n.mode = mode & 0o7777
	n.data = make([dynamic]u8, d.allocator)
	n.durable = make([dynamic]u8, d.allocator)
	n.pend = make([dynamic]Pend, d.allocator)
	if kind == .Dir {
		n.entries = make(map[string]u64, d.allocator)
		n.dentries = make(map[string]u64, d.allocator)
	}
	t := _now(d)
	n.mtime_ns = t
	n.ctime_ns = t
	d.inodes[n.ino] = n
	return n
}

@(private = "file")
_inode_free :: proc(d: ^Disk, n: ^Inode) {
	_pend_drop(d, n)
	delete(n.data)
	delete(n.durable)
	delete(n.ghost)
	for p in n.pend {
		delete(p.bytes, d.allocator)
	}
	delete(n.pend)
	if n.kind == .Dir {
		for k in n.entries {
			delete(k, d.allocator)
		}
		delete(n.entries)
		for k in n.dentries {
			delete(k, d.allocator)
		}
		delete(n.dentries)
	}
	delete(n.target, d.allocator)
	free(n, d.allocator)
}

@(private = "file")
_meta_free :: proc(d: ^Disk, m: Meta_Op) {
	delete(m.name, d.allocator)
	delete(m.name2, d.allocator)
}

@(private = "file")
_now :: proc(d: ^Disk) -> i64 {
	if d.wall != nil {
		return d.wall(d.wall_data)
	}
	return 0
}

@(private = "file")
_enter :: proc(d: ^Disk, op: u64) -> bool {
	if d.dead {
		return false
	}
	if d.quiet || d.probe > 0 {
		return true
	}
	d.stats.ops += 1
	if d.probe == 0 {
		d.trace = mix64(d.trace, op)
	}
	if d.crash_at != 0 && d.stats.ops >= d.crash_at {
		d.dead = true
		d.crash_at = 0
		return false
	}
	return true
}

disk_events_clear :: proc(d: ^Disk) {
	for ev in d.events {
		delete(ev.path, d.allocator)
	}
	clear(&d.events)
}

@(private = "file")
_event :: proc(d: ^Disk, path: string, closed := false) {
	if d.probe > 0 || !d.watching || len(d.watch_prefix) == 0 || !strings.has_prefix(path, d.watch_prefix) {
		return
	}
	if n := len(d.events); n > 0 && d.events[n - 1].path == path && d.events[n - 1].closed == closed {
		return
	}
	append(&d.events, Watch_Ev{path = strings.clone(path, d.allocator), closed = closed})
}

@(private = "file")
_inject_path :: proc(d: ^Disk, path: string, space: bool) -> prim.Error {
	under := len(d.fail_root) > 0 && strings.has_prefix(path, d.fail_root) && (len(path) == len(d.fail_root) || path[len(d.fail_root)] == '/')
	if d.fail_stuck && under && d.probe == 0 && !d.quiet {
		return .Io
	}
	if d.fail_nth > 0 && d.probe == 0 && !d.quiet && under {
		d.fail_nth -= 1
		if d.fail_nth == 0 {
			d.stats.injected += 1
			d.fail_stuck = d.fail_stick
			return .Io
		}
	}
	return _inject(d, space)
}

@(private = "file")
_inject_fd :: proc(d: ^Disk, fd: prim.Fd, space: bool) -> prim.Error {
	path := ""
	if of, ok := d.fds[fd]; ok {
		path = of.path
	}
	return _inject_path(d, path, space)
}

@(private = "file")
_inject :: proc(d: ^Disk, space: bool) -> prim.Error {
	if d.fail_rate == 0 || !d.failing || d.probe > 0 {
		return .None
	}
	if rng_below(&d.fail_rng, 1_000_000) >= d.fail_rate {
		return .None
	}
	d.stats.injected += 1
	if space && rng_chance(&d.fail_rng, 1, 2) {
		return .No_Space
	}
	return .Io
}

@(private = "file")
_split :: proc(path: string, out: ^[dynamic]string) -> bool {
	clear(out)
	if len(path) == 0 || path[0] != '/' {
		return false
	}
	i := 0
	for i < len(path) {
		for i < len(path) && path[i] == '/' {
			i += 1
		}
		j := i
		for j < len(path) && path[j] != '/' {
			j += 1
		}
		if j > i {
			c := path[i:j]
			if c == "." {
			} else if c == ".." {
				if len(out) > 0 {
					pop(out)
				}
			} else {
				append(out, c)
			}
		}
		i = j
	}
	return true
}

Lookup :: struct {
	parent: u64,
	name:   string,
	ino:    u64,
	found:  bool,
}

@(private = "file")
_lookup :: proc(d: ^Disk, path: string, follow: bool, depth := 0) -> (lk: Lookup, err: prim.Error) {
	if depth > 16 {
		return lk, .Invalid
	}
	comps := make([dynamic]string, context.temp_allocator)
	if !_split(path, &comps) {
		return lk, .Invalid
	}
	if len(comps) == 0 {
		return Lookup{parent = ROOT_INO, name = "", ino = ROOT_INO, found = true}, .None
	}
	cur := u64(ROOT_INO)
	prefix := make([dynamic]u8, context.temp_allocator)
	for c, i in comps {
		dir, ok := d.inodes[cur]
		if !ok {
			return lk, .Not_Found
		}
		if dir.kind != .Dir {
			return lk, .Not_Dir
		}
		last := i == len(comps) - 1
		child, has := dir.entries[c]
		if last {
			lk = Lookup{parent = cur, name = c, ino = child, found = has}
			if has && follow {
				n := d.inodes[child]
				if n.kind == .Symlink {
					target := _sym_target(n.target, string(prefix[:]))
					return _lookup(d, target, true, depth + 1)
				}
			}
			return lk, .None
		}
		if !has {
			return lk, .Not_Found
		}
		n := d.inodes[child]
		if n.kind == .Symlink {
			target := _sym_target(n.target, string(prefix[:]))
			rest := strings.join(comps[i + 1:], "/", context.temp_allocator)
			full := strings.concatenate({target, "/", rest}, context.temp_allocator)
			return _lookup(d, full, follow, depth + 1)
		}
		append(&prefix, '/')
		append(&prefix, c)
		cur = child
	}
	return lk, .Not_Found
}

@(private = "file")
_sym_target :: proc(target: string, dir: string) -> string {
	if len(target) > 0 && target[0] == '/' {
		return target
	}
	base := dir if len(dir) > 0 else "/"
	return strings.concatenate({base, "/", target}, context.temp_allocator)
}

@(private = "file")
_link :: proc(d: ^Disk, dir: ^Inode, name: string, ino: u64) {
	dir.entries[strings.clone(name, d.allocator)] = ino
	append(&d.meta, Meta_Op{kind = .Link, dir = dir.ino, name = strings.clone(name, d.allocator), ino = ino})
	dir.mtime_ns = _now(d)
	d.inodes[ino].nlink += 1
}

@(private = "file")
_unlink_entry :: proc(d: ^Disk, dir: ^Inode, name: string) -> u64 {
	k, v := delete_key(&dir.entries, name)
	delete(k, d.allocator)
	if n, ok := d.inodes[v]; ok {
		n.nlink -= 1
		n.ctime_ns = _now(d)
	}
	dir.mtime_ns = _now(d)
	return v
}

@(private = "file")
_maybe_orphan :: proc(d: ^Disk, ino: u64) {
	n, ok := d.inodes[ino]
	if !ok || n.nlink > 0 || n.opens > 0 {
		return
	}
	for m in d.meta {
		if m.ino == ino {
			return
		}
	}
	if _durably_linked(d, ino) {
		return
	}
	delete_key(&d.inodes, ino)
	_inode_free(d, n)
}

@(private = "file")
_durably_linked :: proc(d: ^Disk, ino: u64) -> bool {
	for _, n in d.inodes {
		if n.kind != .Dir {
			continue
		}
		for _, v in n.dentries {
			if v == ino {
				return true
			}
		}
	}
	return false
}

@(private = "file")
_fd_get :: proc(d: ^Disk, fd: prim.Fd) -> (^Open_File, ^Inode, prim.Error) {
	of, ok := &d.fds[fd]
	if !ok {
		return nil, nil, .Invalid
	}
	n, nok := d.inodes[of.ino]
	if !nok {
		return nil, nil, .Invalid
	}
	return of, n, .None
}

@(private = "file")
_kind :: proc "contextless" (k: Inode_Kind) -> prim.File_Kind {
	switch k {
	case .File:
		return .File
	case .Dir:
		return .Dir
	case .Symlink:
		return .Symlink
	}
	return .Unknown
}

@(private = "file")
_type_bits :: proc "contextless" (k: Inode_Kind) -> u32 {
	switch k {
	case .File:
		return 0o100000
	case .Dir:
		return 0o040000
	case .Symlink:
		return 0o120000
	}
	return 0
}

@(private = "file")
_d_open :: proc(data: rawptr, path: string, flags: prim.Open_Flags, mode: u32) -> (prim.Fd, prim.Error) {
	d := (^Disk)(data)
	if !_enter(d, 1) {
		return prim.INVALID_FD, .Io
	}
	if d.probe == 0 {
		d.trace = mix_str(d.trace, trace_path(path))
	}
	if d.verbose && d.probe == 0 {
		fmt.eprintf("dop %s open %s\n", d.name, path)
	}
	lk, err := _lookup(d, path, true)
	if err != .None {
		return prim.INVALID_FD, err
	}
	ino := lk.ino
	if !lk.found {
		if .Create not_in flags {
			return prim.INVALID_FD, .Not_Found
		}
		if .Directory in flags {
			return prim.INVALID_FD, .Not_Found
		}
		parent, ok := d.inodes[lk.parent]
		if !ok || parent.kind != .Dir {
			return prim.INVALID_FD, .Not_Found
		}
		if len(lk.name) == 0 {
			return prim.INVALID_FD, .Invalid
		}
		if ierr := _inject_path(d, path, true); ierr != .None {
			return prim.INVALID_FD, ierr
		}
		n := _inode_new(d, .File, mode)
		_link(d, parent, lk.name, n.ino)
		ino = n.ino
		_event(d, path)
	} else {
		if .Create in flags && .Exclusive in flags {
			return prim.INVALID_FD, .Exists
		}
		n := d.inodes[ino]
		if n.kind == .Symlink {
			return prim.INVALID_FD, .Not_Found
		}
		if n.kind == .Dir {
			if .Write in flags {
				return prim.INVALID_FD, .Is_Dir
			}
		} else if .Directory in flags {
			return prim.INVALID_FD, .Not_Dir
		}
		if n.kind == .File && .Truncate in flags && .Write in flags && len(n.data) > 0 {
			_event(d, path)
			resize(&n.data, 0)
			append(&n.pend, Pend{kind = .Truncate, size = 0})
			n.mtime_ns = _now(d)
		}
	}
	fd := d.next_fd
	d.next_fd += 1
	d.fds[fd] = Open_File{ino = ino, writable = .Write in flags, append = .Append in flags, path = strings.clone(path, d.allocator)}
	d.inodes[ino].opens += 1
	return fd, .None
}

@(private = "file")
_d_close :: proc(data: rawptr, fd: prim.Fd) -> prim.Error {
	d := (^Disk)(data)
	of, ok := d.fds[fd]
	if !ok {
		return .Invalid
	}
	delete_key(&d.fds, fd)
	if of.wrote && !d.dead {
		_event(d, of.path, true)
	}
	delete(of.path, d.allocator)
	if n, nok := d.inodes[of.ino]; nok {
		n.opens -= 1
		if n.lock_fd == fd {
			n.lock_fd = prim.INVALID_FD
		}
		_maybe_orphan(d, of.ino)
	}
	if d.dead || d.quiet || d.probe > 0 {
		return .None
	}
	d.stats.ops += 1
	return .None
}

@(private = "file")
_d_read_at :: proc(data: rawptr, fd: prim.Fd, buf: []u8, off: i64) -> (int, prim.Error) {
	d := (^Disk)(data)
	if !_enter(d, 2) {
		return 0, .Io
	}
	_, n, err := _fd_get(d, fd)
	if err != .None {
		return 0, err
	}
	if n.kind == .Dir {
		return 0, .Is_Dir
	}
	if off < 0 {
		return 0, .Invalid
	}
	if off >= i64(len(n.data)) {
		return 0, .None
	}
	c := copy(buf, n.data[off:])
	return c, .None
}

DISK_FILE_MAX :: i64(512) << 20

@(private = "file")
_write :: proc(d: ^Disk, n: ^Inode, src: []u8, off: i64) -> prim.Error {
	end := off + i64(len(src))
	if end > i64(len(n.data)) {
		if end > DISK_FILE_MAX {
			_runaway(d, n, end)
			return .No_Space
		}
		old := len(n.data)
		if resize(&n.data, int(end)) != nil {
			_runaway(d, n, end)
			return .No_Space
		}
		for i in old ..< int(off) {
			n.data[i] = 0
		}
	}
	copy(n.data[off:end], src)
	b := make([]u8, len(src), d.allocator)
	copy(b, src)
	append(&n.pend, Pend{kind = .Write, off = off, bytes = b})
	d.pend_bytes += i64(len(src))
	if d.pend_bytes > DISK_FILE_MAX && d.runaway_size == 0 {
		d.runaway_size = d.pend_bytes
		d.runaway_ino = n.ino
		d.runaway_pend = true
	}
	n.mtime_ns = _now(d)
	if d.probe == 0 {
		d.stats.writes += 1
		d.stats.bytes += u64(len(src))
	}
	return .None
}

@(private = "file")
_runaway :: proc(d: ^Disk, n: ^Inode, size: i64) {
	if d.runaway_size == 0 {
		d.runaway_size = size
		d.runaway_ino = n.ino
	}
}

disk_runaway :: proc(d: ^Disk) -> (path: string, size: i64, ok: bool) {
	if d.runaway_size == 0 {
		return "", 0, false
	}
	p := _path_of(d, d.runaway_ino, context.temp_allocator)
	if d.runaway_pend {
		p = strings.concatenate({"unsynced writes (latest to ", p, ")"}, context.temp_allocator)
	}
	return p, d.runaway_size, true
}

@(private = "file")
_d_write_at :: proc(data: rawptr, fd: prim.Fd, src: []u8, off: i64) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 3) {
		return .Io
	}
	if ierr := _inject_fd(d, fd, true); ierr != .None {
		return ierr
	}
	of, n, err := _fd_get(d, fd)
	if err != .None {
		return err
	}
	if !of.writable || n.kind != .File {
		return .Invalid
	}
	if off < 0 {
		return .Invalid
	}
	at := i64(len(n.data)) if of.append else off
	if d.probe == 0 {
		d.trace = mix64(d.trace, u64(at) ~ u64(len(src)) << 40)
	}
	if len(src) == 0 {
		return .None
	}
	if werr := _write(d, n, src, at); werr != .None {
		return werr
	}
	of.wrote = true
	_event(d, of.path)
	return .None
}

@(private = "file")
_d_sync :: proc(data: rawptr, fd: prim.Fd) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 4) {
		return .Io
	}
	_, n, err := _fd_get(d, fd)
	if err != .None {
		return err
	}
	if d.fail_sync > 0 || _inject_fd(d, fd, false) != .None {
		if d.fail_sync > 0 {
			d.fail_sync -= 1
		}
		if n.kind == .File {
			for p in n.pend {
				delete(p.bytes, d.allocator)
			}
			_pend_drop(d, n)
			clear(&n.pend)
		}
		return .Io
	}
	if n.kind == .Dir {
		if d.probe == 0 {
			d.stats.dirsyncs += 1
		}
		_commit_dir(d, n.ino)
		return .None
	}
	if d.probe == 0 {
		d.stats.syncs += 1
	}
	for p in n.pend {
		switch p.kind {
		case .Write:
			end := int(p.off) + len(p.bytes)
			if len(n.durable) < end {
				old := len(n.durable)
				resize(&n.durable, end)
				for i in old ..< int(p.off) {
					n.durable[i] = 0
				}
			}
			copy(n.durable[p.off:end], p.bytes)
		case .Truncate:
			old := len(n.durable)
			if int(p.size) < old {
				if n.ghost == nil {
					n.ghost = make([dynamic]u8, d.allocator)
				}
				if len(n.ghost) < old {
					resize(&n.ghost, old)
				}
				copy(n.ghost[p.size:old], n.durable[p.size:old])
			}
			resize(&n.durable, int(p.size))
			for i in old ..< int(p.size) {
				n.durable[i] = 0
			}
		}
		delete(p.bytes, d.allocator)
	}
	_pend_drop(d, n)
	clear(&n.pend)
	return .None
}

@(private = "file")
_commit_dir :: proc(d: ^Disk, dir: u64) {
	last := -1
	for m, i in d.meta {
		if m.dir == dir || (m.kind == .Rename && m.dir2 == dir) {
			last = i
		}
	}
	if last < 0 {
		return
	}
	gone := make([dynamic]u64, context.temp_allocator)
	for i in 0 ..= last {
		_meta_apply(d, d.meta[i])
		if d.meta[i].gone != 0 {
			append(&gone, d.meta[i].gone)
		}
		_meta_free(d, d.meta[i])
	}
	remove_range(&d.meta, 0, last + 1)
	for g in gone {
		_maybe_orphan(d, g)
	}
}

@(private = "file")
_dset :: proc(d: ^Disk, dir: u64, name: string, ino: u64) {
	n, ok := d.inodes[dir]
	if !ok || n.kind != .Dir {
		return
	}
	if _, has := n.dentries[name]; has {
		n.dentries[name] = ino
		return
	}
	n.dentries[strings.clone(name, d.allocator)] = ino
}

@(private = "file")
_ddel :: proc(d: ^Disk, dir: u64, name: string) {
	n, ok := d.inodes[dir]
	if !ok || n.kind != .Dir {
		return
	}
	if _, has := n.dentries[name]; has {
		k, _ := delete_key(&n.dentries, name)
		delete(k, d.allocator)
	}
}

@(private = "file")
_meta_apply :: proc(d: ^Disk, m: Meta_Op) {
	switch m.kind {
	case .Link:
		_dset(d, m.dir, m.name, m.ino)
	case .Unlink:
		_ddel(d, m.dir, m.name)
	case .Rename:
		_ddel(d, m.dir, m.name)
		_dset(d, m.dir2, m.name2, m.ino)
	}
}

@(private = "file")
_d_truncate :: proc(data: rawptr, fd: prim.Fd, size: i64) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 5) {
		return .Io
	}
	if ierr := _inject_fd(d, fd, true); ierr != .None {
		return ierr
	}
	of, n, err := _fd_get(d, fd)
	if err != .None {
		return err
	}
	if !of.writable || n.kind != .File || size < 0 {
		return .Invalid
	}
	if d.probe == 0 {
		d.trace = mix64(d.trace, u64(size))
	}
	old := len(n.data)
	if size > DISK_FILE_MAX || resize(&n.data, int(size)) != nil {
		_runaway(d, n, size)
		return .No_Space
	}
	for i in old ..< int(size) {
		n.data[i] = 0
	}
	append(&n.pend, Pend{kind = .Truncate, size = size})
	n.mtime_ns = _now(d)
	of.wrote = true
	_event(d, of.path)
	return .None
}

@(private = "file")
_d_punch :: proc(data: rawptr, fd: prim.Fd, off: i64, size: i64) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 6) {
		return .Io
	}
	if ierr := _inject_fd(d, fd, false); ierr != .None {
		return ierr
	}
	of, n, err := _fd_get(d, fd)
	if err != .None {
		return err
	}
	if !of.writable || n.kind != .File || off < 0 || size < 0 {
		return .Invalid
	}
	end := min(off + size, i64(len(n.data)))
	if end <= off {
		return .None
	}
	z := make([]u8, int(end - off), context.temp_allocator)
	return _write(d, n, z, off)
}

@(private = "file")
_d_lock :: proc(data: rawptr, fd: prim.Fd) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 7) {
		return .Io
	}
	_, n, err := _fd_get(d, fd)
	if err != .None {
		return err
	}
	if n.lock_fd != prim.INVALID_FD && n.lock_fd != 0 && n.lock_fd != fd {
		return .Busy
	}
	n.lock_fd = fd
	return .None
}

@(private = "file")
_stat_of :: proc(n: ^Inode) -> prim.Stat {
	size := i64(len(n.data))
	if n.kind == .Symlink {
		size = i64(len(n.target))
	} else if n.kind == .Dir {
		size = 4096
	}
	return prim.Stat {
		size = size,
		mode = _type_bits(n.kind) | n.mode,
		kind = _kind(n.kind),
		ino = n.ino,
		dev = 1,
		nlink = u64(max(n.nlink, 0)),
		mtime_ns = n.mtime_ns,
		ctime_ns = n.ctime_ns,
	}
}

@(private = "file")
_d_fstat :: proc(data: rawptr, fd: prim.Fd) -> (prim.Stat, prim.Error) {
	d := (^Disk)(data)
	if !_enter(d, 8) {
		return {}, .Io
	}
	_, n, err := _fd_get(d, fd)
	if err != .None {
		return {}, err
	}
	return _stat_of(n), .None
}

@(private = "file")
_d_stat :: proc(data: rawptr, path: string, follow: bool) -> (prim.Stat, prim.Error) {
	d := (^Disk)(data)
	if !_enter(d, 9) {
		return {}, .Io
	}
	lk, err := _lookup(d, path, follow)
	if err != .None {
		return {}, err
	}
	if !lk.found {
		return {}, .Not_Found
	}
	return _stat_of(d.inodes[lk.ino]), .None
}

@(private = "file")
_is_ancestor :: proc(d: ^Disk, anc: u64, ino: u64) -> bool {
	if anc == ino {
		return true
	}
	n, ok := d.inodes[anc]
	if !ok || n.kind != .Dir {
		return false
	}
	for _, v in n.entries {
		if _is_ancestor(d, v, ino) {
			return true
		}
	}
	return false
}

@(private = "file")
_d_rename :: proc(data: rawptr, old: string, new: string) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 10) {
		return .Io
	}
	if ierr := _inject_path(d, new, true); ierr != .None {
		return ierr
	}
	if d.probe == 0 {
		d.trace = mix_str(mix_str(d.trace, trace_path(old)), trace_path(new))
	}
	if d.verbose && d.probe == 0 {
		fmt.eprintf("dop %s rename %s %s\n", d.name, old, new)
	}
	a, aerr := _lookup(d, old, false)
	if aerr != .None {
		return aerr
	}
	if !a.found {
		return .Not_Found
	}
	b, berr := _lookup(d, new, false)
	if berr != .None {
		return berr
	}
	if len(a.name) == 0 || len(b.name) == 0 {
		return .Busy
	}
	src := d.inodes[a.ino]
	if b.found {
		if b.ino == a.ino {
			return .None
		}
		dst := d.inodes[b.ino]
		if src.kind == .Dir {
			if dst.kind != .Dir {
				return .Not_Dir
			}
			if len(dst.entries) > 0 {
				return .Not_Empty
			}
		} else if dst.kind == .Dir {
			return .Is_Dir
		}
	}
	if src.kind == .Dir && _is_ancestor(d, a.ino, b.parent) {
		return .Invalid
	}
	pa := d.inodes[a.parent]
	pb, ok := d.inodes[b.parent]
	if !ok || pb.kind != .Dir {
		return .Not_Found
	}
	replaced: u64
	if b.found {
		replaced = _unlink_entry(d, pb, b.name)
	}
	moved := _unlink_entry(d, pa, a.name)
	pb.entries[strings.clone(b.name, d.allocator)] = moved
	d.inodes[moved].nlink += 1
	append(&d.meta, Meta_Op{kind = .Rename, dir = a.parent, name = strings.clone(a.name, d.allocator), ino = moved, dir2 = b.parent, name2 = strings.clone(b.name, d.allocator), gone = replaced})
	_event(d, old)
	_event(d, new)
	if replaced != 0 {
		_freed_note(d, new, replaced)
		_maybe_orphan(d, replaced)
	}
	return .None
}

@(private = "file")
_d_unlink :: proc(data: rawptr, path: string) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 11) {
		return .Io
	}
	if ierr := _inject_path(d, path, false); ierr != .None {
		return ierr
	}
	if d.probe == 0 {
		d.trace = mix_str(d.trace, trace_path(path))
	}
	lk, err := _lookup(d, path, false)
	if err != .None {
		return err
	}
	if !lk.found {
		return .Not_Found
	}
	n := d.inodes[lk.ino]
	if n.kind == .Dir {
		return .Is_Dir
	}
	dir := d.inodes[lk.parent]
	_freed_note(d, path, lk.ino)
	ino := _unlink_entry(d, dir, lk.name)
	append(&d.meta, Meta_Op{kind = .Unlink, dir = lk.parent, name = strings.clone(lk.name, d.allocator), ino = 0, gone = ino})
	_maybe_orphan(d, ino)
	_event(d, path)
	return .None
}

@(private = "file")
_d_rmdir :: proc(data: rawptr, path: string) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 12) {
		return .Io
	}
	lk, err := _lookup(d, path, false)
	if err != .None {
		return err
	}
	if !lk.found {
		return .Not_Found
	}
	if len(lk.name) == 0 {
		return .Busy
	}
	n := d.inodes[lk.ino]
	if n.kind != .Dir {
		return .Not_Dir
	}
	if len(n.entries) > 0 {
		return .Not_Empty
	}
	dir := d.inodes[lk.parent]
	ino := _unlink_entry(d, dir, lk.name)
	append(&d.meta, Meta_Op{kind = .Unlink, dir = lk.parent, name = strings.clone(lk.name, d.allocator), ino = 0, gone = ino})
	_maybe_orphan(d, ino)
	return .None
}

@(private = "file")
_d_mkdir :: proc(data: rawptr, path: string, mode: u32) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 13) {
		return .Io
	}
	if ierr := _inject_path(d, path, true); ierr != .None {
		return ierr
	}
	if d.probe == 0 {
		d.trace = mix_str(d.trace, trace_path(path))
	}
	lk, err := _lookup(d, path, false)
	if err != .None {
		return err
	}
	if lk.found {
		return .Exists
	}
	parent, ok := d.inodes[lk.parent]
	if !ok || parent.kind != .Dir {
		return .Not_Found
	}
	n := _inode_new(d, .Dir, mode)
	n.nlink = 1
	_link(d, parent, lk.name, n.ino)
	_event(d, path)
	return .None
}

@(private = "file")
_d_symlink :: proc(data: rawptr, target: string, path: string) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 14) {
		return .Io
	}
	lk, err := _lookup(d, path, false)
	if err != .None {
		return err
	}
	if lk.found {
		return .Exists
	}
	parent, ok := d.inodes[lk.parent]
	if !ok || parent.kind != .Dir {
		return .Not_Found
	}
	n := _inode_new(d, .Symlink, 0o777)
	n.target = strings.clone(target, d.allocator)
	_link(d, parent, lk.name, n.ino)
	return .None
}

@(private = "file")
_d_readlink :: proc(data: rawptr, path: string, buf: []u8) -> (int, prim.Error) {
	d := (^Disk)(data)
	if !_enter(d, 15) {
		return 0, .Io
	}
	lk, err := _lookup(d, path, false)
	if err != .None {
		return 0, err
	}
	if !lk.found {
		return 0, .Not_Found
	}
	n := d.inodes[lk.ino]
	if n.kind != .Symlink {
		return 0, .Invalid
	}
	c := copy(buf, n.target)
	if len(n.target) >= len(buf) {
		return c, .Too_Large
	}
	return c, .None
}

@(private = "file")
_d_fchmod :: proc(data: rawptr, fd: prim.Fd, mode: u32) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 16) {
		return .Io
	}
	_, n, err := _fd_get(d, fd)
	if err != .None {
		return err
	}
	n.mode = mode & 0o7777
	n.ctime_ns = _now(d)
	return .None
}

@(private = "file")
_d_set_times :: proc(data: rawptr, path: string, atime_ns: i64, mtime_ns: i64) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 17) {
		return .Io
	}
	if atime_ns < 0 || mtime_ns < 0 {
		return .Invalid
	}
	lk, err := _lookup(d, path, true)
	if err != .None {
		return err
	}
	if !lk.found {
		return .Not_Found
	}
	d.inodes[lk.ino].mtime_ns = mtime_ns
	return .None
}

@(private = "file")
_d_dir_open :: proc(data: rawptr, dir: ^prim.Dir, path: string) -> prim.Error {
	d := (^Disk)(data)
	if !_enter(d, 18) {
		return .Io
	}
	lk, err := _lookup(d, path, true)
	if err != .None {
		return err
	}
	if !lk.found {
		return .Not_Found
	}
	n := d.inodes[lk.ino]
	if n.kind != .Dir {
		return .Not_Dir
	}
	a := dir.allocator
	if a.procedure == nil {
		a = context.allocator
		dir.allocator = a
	}
	it := new(Dir_Iter, a)
	names := make([]string, len(n.entries), a)
	i := 0
	for k in n.entries {
		names[i] = k
		i += 1
	}
	slice.sort(names)
	it.inos = make([]u64, len(names), a)
	it.kinds = make([]prim.File_Kind, len(names), a)
	for k, j in names {
		v := n.entries[k]
		names[j] = strings.clone(k, a)
		it.inos[j] = v
		it.kinds[j] = _kind(d.inodes[v].kind)
	}
	it.names = names
	fd := d.next_fd
	d.next_fd += 1
	d.fds[fd] = Open_File{ino = n.ino}
	n.opens += 1
	dir.fd = fd
	dir.handle = it
	return .None
}

@(private = "file")
_d_dir_next :: proc(data: rawptr, dir: ^prim.Dir) -> (prim.Dir_Entry, bool, prim.Error) {
	d := (^Disk)(data)
	it := (^Dir_Iter)(dir.handle)
	if it == nil {
		return {}, false, .None
	}
	if d.dead {
		return {}, false, .Io
	}
	if it.pos >= len(it.names) {
		return {}, false, .None
	}
	k := it.pos
	it.pos += 1
	return prim.Dir_Entry{name = it.names[k], ino = it.inos[k], kind = it.kinds[k]}, true, .None
}

@(private = "file")
_d_dir_close :: proc(data: rawptr, dir: ^prim.Dir) {
	d := (^Disk)(data)
	it := (^Dir_Iter)(dir.handle)
	if it != nil {
		a := dir.allocator
		for s in it.names {
			delete(s, a)
		}
		delete(it.names, a)
		delete(it.inos, a)
		delete(it.kinds, a)
		free(it, a)
		dir.handle = nil
	}
	if dir.fd != prim.INVALID_FD {
		_d_close(d, dir.fd)
		dir.fd = prim.INVALID_FD
	}
}

@(private = "file")
_d_caps :: proc(data: rawptr, fd: prim.Fd) -> prim.Vfs_Caps {
	return {}
}

disk_crash :: proc(d: ^Disk, mode: Crash_Mode, r: ^Rng) {
	d.stats.crashes += 1
	d.dead = false
	d.crash_at = 0
	d.fail_sync = 0
	d.fail_nth = 0
	d.fail_stick = false
	d.fail_stuck = false
	for _, n in d.inodes {
		n.lock_fd = prim.INVALID_FD
		n.opens = 0
	}
	for _, of in d.fds {
		delete(of.path, d.allocator)
	}
	clear(&d.fds)
	disk_events_clear(d)
	d.watching = false
	if mode == .Process {
		_collect(d)
		return
	}
	keep_meta := rng_int(r, len(d.meta) + 1)
	if rng_chance(r, 1, 4) {
		keep_meta = len(d.meta)
	} else if rng_chance(r, 1, 3) {
		keep_meta = 0
	}
	for i in 0 ..< keep_meta {
		_meta_apply(d, d.meta[i])
	}
	for m in d.meta {
		_meta_free(d, m)
	}
	clear(&d.meta)
	ladder := [?]u64{0, 1, 2, 3, 4}
	keep := ladder[rng_int(r, len(ladder))]
	ids := make([dynamic]u64, context.temp_allocator)
	for k in d.inodes {
		append(&ids, k)
	}
	slice.sort(ids[:])
	for k in ids {
		n := d.inodes[k]
		if n.kind == .File {
			_recover_file(d, n, keep, r)
		}
	}
	for k in ids {
		n := d.inodes[k]
		if n.kind == .Dir {
			for name in n.entries {
				delete(name, d.allocator)
			}
			clear(&n.entries)
			for name, v in n.dentries {
				n.entries[strings.clone(name, d.allocator)] = v
			}
		}
	}
	_collect(d)
}

@(private = "file")
_recover_file :: proc(d: ^Disk, n: ^Inode, keep: u64, r: ^Rng) {
	content := make([dynamic]u8, len(n.durable), d.allocator)
	copy(content[:], n.durable[:])
	for p in n.pend {
		switch p.kind {
		case .Truncate:
			if rng_below(r, 4) < keep {
				old := len(content)
				resize(&content, int(p.size))
				for i in old ..< int(p.size) {
					content[i] = 0
				}
			} else {
				d.stats.lost += 1
			}
		case .Write:
			end := p.off + i64(len(p.bytes))
			pos := p.off
			any := false
			for pos < end {
				next := min((pos / SECTOR + 1) * SECTOR, end)
				if rng_below(r, 4) < keep {
					if i64(len(content)) < next {
						old := len(content)
						resize(&content, int(next))
						for i in old ..< int(next) {
							content[i] = 0
						}
					}
					copy(content[pos:next], p.bytes[pos - p.off:next - p.off])
					any = true
				} else {
					d.stats.torn += 1
				}
				pos = next
			}
			if !any {
				d.stats.lost += 1
				if end > i64(len(content)) && rng_chance(r, 1, 3) {
					old := len(content)
					resize(&content, int(end))
					for i in old ..< int(end) {
						content[i] = 0
					}
				}
			}
		}
		delete(p.bytes, d.allocator)
	}
	_pend_drop(d, n)
	clear(&n.pend)
	if len(n.ghost) > len(content) && (d.force_ghost || rng_chance(r, 1, 2)) {
		old := len(content)
		resize(&content, len(n.ghost))
		copy(content[old:], n.ghost[old:])
		d.stats.ghosts += 1
	}
	clear(&n.ghost)
	delete(n.data)
	n.data = content
	resize(&n.durable, len(content))
	copy(n.durable[:], content[:])
}

@(private = "file")
_collect :: proc(d: ^Disk) {
	live := _reachable(d)
	dead := make([dynamic]u64, context.temp_allocator)
	for k in d.inodes {
		if !(k in live) {
			append(&dead, k)
		}
	}
	for k in dead {
		_inode_free(d, d.inodes[k])
		delete_key(&d.inodes, k)
	}
	for _, n in d.inodes {
		n.nlink = 0
	}
	d.inodes[ROOT_INO].nlink = 1
	for _, n in d.inodes {
		if n.kind == .Dir {
			for _, v in n.entries {
				if c, ok := d.inodes[v]; ok {
					c.nlink += 1
				}
			}
		}
	}
}

@(private = "file")
_reachable :: proc(d: ^Disk) -> map[u64]bool {
	live := make(map[u64]bool, context.temp_allocator)
	stack := make([dynamic]u64, context.temp_allocator)
	for _, of in d.fds {
		if !(of.ino in live) {
			live[of.ino] = true
			append(&stack, of.ino)
		}
	}
	append(&stack, ROOT_INO)
	live[ROOT_INO] = true
	for len(stack) > 0 {
		x := pop(&stack)
		n := d.inodes[x]
		if n.kind != .Dir {
			continue
		}
		for _, v in n.entries {
			if !(v in live) {
				if _, ok := d.inodes[v]; ok {
					live[v] = true
					append(&stack, v)
				}
			}
		}
		for _, v in n.dentries {
			if !(v in live) {
				if _, ok := d.inodes[v]; ok {
					live[v] = true
					append(&stack, v)
				}
			}
		}
	}
	for m in d.meta {
		if m.ino != 0 && !(m.ino in live) {
			if _, ok := d.inodes[m.ino]; ok {
				live[m.ino] = true
				append(&stack, m.ino)
			}
		}
	}
	for len(stack) > 0 {
		x := pop(&stack)
		n := d.inodes[x]
		if n.kind != .Dir {
			continue
		}
		for _, v in n.entries {
			if !(v in live) {
				if _, ok := d.inodes[v]; ok {
					live[v] = true
					append(&stack, v)
				}
			}
		}
		for _, v in n.dentries {
			if !(v in live) {
				if _, ok := d.inodes[v]; ok {
					live[v] = true
					append(&stack, v)
				}
			}
		}
	}
	return live
}

Disk_File :: struct {
	path:    string,
	data:    []u8,
	durable: []u8,
}

disk_walk :: proc(d: ^Disk, out: ^[dynamic]Disk_File, allocator := context.temp_allocator) {
	_walk(d, ROOT_INO, "", out, allocator)
}

@(private = "file")
_walk :: proc(d: ^Disk, ino: u64, prefix: string, out: ^[dynamic]Disk_File, allocator: runtime.Allocator) {
	n := d.inodes[ino]
	names := make([dynamic]string, context.temp_allocator)
	for k in n.entries {
		append(&names, k)
	}
	slice.sort(names[:])
	for k in names {
		v := n.entries[k]
		c := d.inodes[v]
		p := strings.concatenate({prefix, "/", k}, allocator)
		switch c.kind {
		case .File:
			append(out, Disk_File{path = p, data = c.data[:], durable = c.durable[:]})
		case .Dir:
			_walk(d, v, p, out, allocator)
		case .Symlink:
		}
	}
}

disk_contains :: proc(d: ^Disk, needle: []u8, allocator := context.temp_allocator) -> (path: string, found: bool) {
	if len(needle) == 0 {
		return "", false
	}
	live := _reachable(d)
	ids := make([dynamic]u64, context.temp_allocator)
	for k in live {
		append(&ids, k)
	}
	slice.sort(ids[:])
	for k in ids {
		n := d.inodes[k]
		if n.kind != .File {
			continue
		}
		if at := _index_of(n.data[:], needle); at >= 0 {
			return fmt.aprintf("%s (live bytes at offset %d of %d)", _path_of(d, k, context.temp_allocator), at, len(n.data), allocator = allocator), true
		}
		if at := _index_of(n.durable[:], needle); at >= 0 {
			return fmt.aprintf("%s (durable image at offset %d; zero-fill not yet synced)", _path_of(d, k, context.temp_allocator), at, allocator = allocator), true
		}
		for p in n.pend {
			if p.kind == .Write {
				if at := _index_of(p.bytes, needle); at >= 0 {
					return fmt.aprintf("%s (unsynced write at offset %d, survives a torn crash)", _path_of(d, k, context.temp_allocator), p.off + i64(at), allocator = allocator), true
				}
			}
		}
	}
	return "", false
}

ZSCAN_MAX :: 4 << 20

@(private = "file")
_index_of :: proc(hay: []u8, needle: []u8) -> int {
	if at := _plain_index(hay, needle); at >= 0 {
		return at
	}
	return _zstd_index(hay, needle)
}

@(private = "file")
_zstd_index :: proc(hay: []u8, needle: []u8) -> int {
	buf := make([dynamic]u8, context.temp_allocator)
	defer delete(buf)
	for i in 0 ..< max(len(hay) - 5, 0) {
		if hay[i] != 0x28 || hay[i + 1] != 0xb5 || hay[i + 2] != 0x2f || hay[i + 3] != 0xfd {
			continue
		}
		n, ok := obj.zip_frame_size(hay[i:])
		if !ok || n > ZSCAN_MAX || int(n) < len(needle) {
			continue
		}
		resize(&buf, int(n))
		slice.zero(buf[:])
		d := zstd.ZSTD_createDCtx()
		if d == nil {
			continue
		}
		zstd.ZSTD_decompressDCtx(d, raw_data(buf), c.size_t(n), raw_data(hay[i:]), c.size_t(len(hay[i:])))
		zstd.ZSTD_freeDCtx(d)
		if _plain_index(buf[:], needle) >= 0 {
			return i
		}
	}
	return -1
}

@(private = "file")
_plain_index :: proc(hay: []u8, needle: []u8) -> int {
	if len(needle) > len(hay) {
		return -1
	}
	first := needle[0]
	for i in 0 ..= len(hay) - len(needle) {
		if hay[i] == first && string(hay[i:i + len(needle)]) == string(needle) {
			return i
		}
	}
	return -1
}

@(private = "file")
_path_of :: proc(d: ^Disk, ino: u64, allocator: runtime.Allocator) -> string {
	files := make([dynamic]Disk_File, context.temp_allocator)
	_walk(d, ROOT_INO, "", &files, context.temp_allocator)
	for f in files {
		lk, err := _lookup(d, f.path, false)
		if err == .None && lk.found && lk.ino == ino {
			return strings.clone(f.path, allocator)
		}
	}
	return "<unlinked>"
}

disk_bytes :: proc(d: ^Disk) -> (total: u64) {
	for _, n in d.inodes {
		total += u64(len(n.data))
	}
	return
}

disk_digest :: proc(d: ^Disk) -> u64 {
	files := make([dynamic]Disk_File, context.temp_allocator)
	disk_walk(d, &files)
	h: u64 = 0x1234
	for f in files {
		h = mix_str(h, f.path)
		h = mix_bytes(h, f.data)
	}
	return h
}

disk_full_hash :: proc(d: ^Disk) -> u64 {
	inos := make([dynamic]u64, context.temp_allocator)
	for k in d.inodes {
		append(&inos, k)
	}
	slice.sort(inos[:])
	h := mix64(0x6469736b, d.next_ino)
	for k in inos {
		n := d.inodes[k]
		h = mix64(h, k)
		h = mix64(h, u64(n.kind) | u64(n.mode) << 8 | u64(n.nlink) << 40)
		h = mix64(h, u64(n.mtime_ns))
		h = mix64(h, u64(n.ctime_ns))
		h = mix_bytes(h, n.data[:])
		h = mix_bytes(h, n.durable[:])
		h = mix64(h, u64(len(n.pend)))
		for p in n.pend {
			h = mix64(h, u64(p.kind))
			h = mix64(h, u64(p.off))
			h = mix64(h, u64(p.size))
			h = mix_bytes(h, p.bytes)
		}
		h = mix_str(h, n.target)
		h = _mix_entries(h, n.entries)
		h = _mix_entries(h, n.dentries)
	}
	h = mix64(h, u64(len(d.meta)))
	for m in d.meta {
		h = mix64(h, u64(m.kind))
		h = mix64(h, m.dir)
		h = mix_str(h, m.name)
		h = mix64(h, m.ino)
		h = mix64(h, m.dir2)
		h = mix_str(h, m.name2)
		h = mix64(h, m.gone)
	}
	return h
}

@(private = "file")
_mix_entries :: proc(h: u64, entries: map[string]u64) -> u64 {
	names := make([dynamic]string, context.temp_allocator)
	for k in entries {
		append(&names, k)
	}
	slice.sort(names[:])
	x := mix64(h, u64(len(names)))
	for k in names {
		x = mix_str(x, k)
		x = mix64(x, entries[k])
	}
	return x
}

trace_path :: proc(path: string) -> string {
	out := path
	for marker in ([]string{"/.tmp_", "/tmp_obj_"}) {
		i := strings.index(out, marker)
		if i < 0 {
			continue
		}
		j := i + len(marker)
		for j < len(out) && out[j] != '/' {
			j += 1
		}
		out = strings.concatenate({out[:i], marker, "*", out[j:]}, context.temp_allocator)
	}
	return out
}

disk_put_virtual :: proc(d: ^Disk, path: string, data: []u8) {
	comps := make([dynamic]string, context.temp_allocator)
	_split(path, &comps)
	cur := u64(ROOT_INO)
	for c, i in comps {
		dir := d.inodes[cur]
		child, has := dir.entries[c]
		if !has {
			kind := Inode_Kind.Dir if i < len(comps) - 1 else Inode_Kind.File
			n := _inode_new(d, kind, 0o755 if kind == .Dir else 0o444)
			dir.entries[strings.clone(c, d.allocator)] = n.ino
			dir.dentries[strings.clone(c, d.allocator)] = n.ino
			n.nlink = 1
			child = n.ino
		}
		cur = child
	}
	n := d.inodes[cur]
	resize(&n.data, len(data))
	copy(n.data[:], data)
	resize(&n.durable, len(data))
	copy(n.durable[:], data)
}

@(private = "file")
_pend_drop :: proc(d: ^Disk, n: ^Inode) {
	for p in n.pend {
		if p.kind == .Write {
			d.pend_bytes -= i64(len(p.bytes))
		}
	}
}

disk_probe_begin :: proc(d: ^Disk) {
	d.probe += 1
}

disk_probe_end :: proc(d: ^Disk) {
	d.probe = max(d.probe - 1, 0)
}

disk_probe_read :: proc(d: ^Disk, path: string, allocator := context.temp_allocator) -> (data: []u8, durable: []u8, ok: bool) {
	d.probe += 1
	defer d.probe -= 1
	lk, err := _lookup(d, path, true)
	if err != .None || !lk.found {
		return nil, nil, false
	}
	n, has := d.inodes[lk.ino]
	if !has || n.kind != .File {
		return nil, nil, false
	}
	data = make([]u8, len(n.data), allocator)
	copy(data, n.data[:])
	durable = make([]u8, len(n.durable), allocator)
	copy(durable, n.durable[:])
	return data, durable, true
}

disk_probe_write :: proc(d: ^Disk, path: string, off: i64, src: []u8, durable := false) -> bool {
	d.probe += 1
	defer d.probe -= 1
	lk, err := _lookup(d, path, true)
	if err != .None || !lk.found || off < 0 {
		return false
	}
	n, has := d.inodes[lk.ino]
	if !has || n.kind != .File {
		return false
	}
	end := int(off) + len(src)
	if len(n.data) < end {
		resize(&n.data, end)
	}
	copy(n.data[off:], src)
	if durable {
		if len(n.durable) < end {
			resize(&n.durable, end)
		}
		copy(n.durable[off:], src)
	}
	return true
}

@(private = "file")
_freed_note :: proc(d: ^Disk, path: string, ino: u64) {
	if len(d.freed_prefix) == 0 || !strings.has_prefix(path, d.freed_prefix) {
		return
	}
	n, ok := d.inodes[ino]
	if !ok || n.kind != .File {
		return
	}
	for src in ([2][]u8{n.data[:], n.durable[:]}) {
		if len(src) == 0 {
			continue
		}
		b := make([]u8, len(src), d.allocator)
		copy(b, src)
		append(&d.freed, b)
	}
}

disk_probe_keep_freed :: proc(d: ^Disk, prefix: string) {
	if d.freed == nil {
		d.freed = make([dynamic][]u8, d.allocator)
	}
	delete(d.freed_prefix, d.allocator)
	d.freed_prefix = strings.clone(prefix, d.allocator)
}

disk_probe_freed_contains :: proc(d: ^Disk, needle: []u8) -> bool {
	if len(needle) == 0 {
		return false
	}
	for b in d.freed {
		for i := 0; i + len(needle) <= len(b); i += 1 {
			if string(b[i:][:len(needle)]) == string(needle) {
				return true
			}
		}
	}
	return false
}

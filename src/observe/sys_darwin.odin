#+build darwin
package observe

import "core:c"
import "../prim"

foreign import libsystem "system:System"

@(private)
PROC_PIDLISTFDS :: c.int(1)
@(private)
PROC_PIDTBSDINFO :: c.int(3)
@(private)
PROC_PIDFDVNODEPATHINFO :: c.int(2)
@(private)
PROX_FDTYPE_VNODE :: u32(1)
@(private)
FWRITE :: u32(0x2)
@(private)
O_TRUNC_DARWIN :: u32(0x400)
@(private)
MAXPATHLEN :: 1024
@(private)
CTL_KERN :: c.int(1)
@(private)
KERN_PROCARGS2 :: c.int(49)

@(private)
foreign libsystem {
	proc_pidinfo :: proc(pid: c.int, flavor: c.int, arg: u64, buffer: rawptr, buffersize: c.int) -> c.int ---
	proc_pidfdinfo :: proc(pid: c.int, fd: c.int, flavor: c.int, buffer: rawptr, buffersize: c.int) -> c.int ---
	proc_listchildpids :: proc(ppid: c.int, buffer: rawptr, buffersize: c.int) -> c.int ---
	sysctl :: proc(name: [^]c.int, namelen: c.uint, oldp: rawptr, oldlenp: ^c.size_t, newp: rawptr, newlen: c.size_t) -> c.int ---
	getpid :: proc() -> c.int ---
}

@(private)
Proc_Fdinfo :: struct {
	fd:   i32,
	type: u32,
}

@(private)
Proc_Fileinfo :: struct {
	openflags:  u32,
	status:     u32,
	offset:     i64,
	type:       i32,
	guardflags: u32,
}

@(private)
Vinfo_Stat :: struct {
	dev:           u32,
	mode:          u16,
	nlink:         u16,
	ino:           u64,
	uid:           u32,
	gid:           u32,
	atime:         i64,
	atimensec:     i64,
	mtime:         i64,
	mtimensec:     i64,
	ctime:         i64,
	ctimensec:     i64,
	birthtime:     i64,
	birthtimensec: i64,
	size:          i64,
	blocks:        i64,
	blksize:       i32,
	flags:         u32,
	gen:           u32,
	rdev:          u32,
	qspare:        [2]i64,
}

@(private)
Vnode_Info :: struct {
	stat: Vinfo_Stat,
	type: i32,
	pad:  i32,
	fsid: [2]i32,
}

@(private)
Vnode_Fdinfo_With_Path :: struct {
	pfi:  Proc_Fileinfo,
	vi:   Vnode_Info,
	path: [MAXPATHLEN]u8,
}

@(private)
Bsd_Info :: struct {
	flags:     u32,
	status:    u32,
	xstatus:   u32,
	pid:       u32,
	ppid:      u32,
	uid:       u32,
	gid:       u32,
	ruid:      u32,
	rgid:      u32,
	svuid:     u32,
	svgid:     u32,
	rfu_1:     u32,
	comm:      [16]u8,
	name:      [32]u8,
	nfiles:    u32,
	pgid:      u32,
	pjobc:     u32,
	e_tdev:    u32,
	e_tpgid:   u32,
	nice:      i32,
	start_sec: u64,
	start_us:  u64,
}

@(private)
_parent_of :: proc "contextless" (pid: prim.Pid) -> (prim.Pid, bool) {
	info: Bsd_Info
	n := proc_pidinfo(c.int(pid), PROC_PIDTBSDINFO, 0, &info, size_of(Bsd_Info))
	if n != size_of(Bsd_Info) {
		return 0, false
	}
	return prim.Pid(info.ppid), true
}

@(private)
_walk_lineage :: proc "contextless" (pid: prim.Pid, ppid: prim.Pid, out: []prim.Pid) -> int {
	if len(out) == 0 {
		return 0
	}
	out[0] = pid
	n := 1
	cur := ppid
	for n < len(out) && cur > 1 {
		out[n] = cur
		n += 1
		p, ok := _parent_of(cur)
		if !ok {
			break
		}
		cur = p
	}
	return n
}

process_args :: proc(pid: prim.Pid, buf: []u8) -> ([]u8, bool) {
	mib := [3]c.int{CTL_KERN, KERN_PROCARGS2, c.int(pid)}
	size := c.size_t(len(buf))
	if sysctl(raw_data(mib[:]), 3, raw_data(buf), &size, nil, 0) != 0 || size < 4 {
		return nil, false
	}
	data := buf[:size]
	argc := int(prim.get_u32le(data))
	i := 4
	for i < len(data) && data[i] != 0 {
		i += 1
	}
	for i < len(data) && data[i] == 0 {
		i += 1
	}
	start := i
	seen := 0
	for i < len(data) && seen < argc {
		if data[i] == 0 {
			seen += 1
		}
		i += 1
	}
	end := i
	for end > start && data[end - 1] == 0 {
		end -= 1
	}
	return data[start:end], end > start
}

@(private)
FIRMLINK_PREFIX :: "/System/Volumes/Data"

@(private)
_strip_firmlink :: proc "contextless" (p: string) -> string {
	if len(p) > len(FIRMLINK_PREFIX) && p[:len(FIRMLINK_PREFIX)] == FIRMLINK_PREFIX && p[len(FIRMLINK_PREFIX)] == '/' {
		return p[len(FIRMLINK_PREFIX):]
	}
	return p
}

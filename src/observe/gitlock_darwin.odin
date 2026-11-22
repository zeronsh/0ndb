#+build darwin
package observe

import "base:runtime"
import "core:c"
import "../fs"
import "../prim"

foreign import libsys_lock "system:System"

@(private)
PROC_PIDVNODEPATHINFO :: c.int(9)

@(private)
Vnode_Info_Path :: struct {
	vi:   Vnode_Info,
	path: [MAXPATHLEN]u8,
}

@(private)
Proc_Vnodepathinfo :: struct {
	cdir: Vnode_Info_Path,
	rdir: Vnode_Info_Path,
}

@(private)
foreign libsys_lock {
	proc_listallpids :: proc(buffer: rawptr, buffersize: c.int) -> c.int ---
}

@(private)
_cwd_of :: proc(pid: prim.Pid, buf: []u8) -> string {
	vpi: Proc_Vnodepathinfo
	n := proc_pidinfo(c.int(pid), PROC_PIDVNODEPATHINFO, 0, &vpi, size_of(Proc_Vnodepathinfo))
	if n != size_of(Proc_Vnodepathinfo) {
		return ""
	}
	l := 0
	for l < MAXPATHLEN && vpi.cdir.path[l] != 0 {
		l += 1
	}
	k := copy(buf, vpi.cdir.path[:l])
	return _strip_firmlink(string(buf[:k]))
}

@(private)
_path_under :: proc(p, root: string) -> bool {
	if len(root) == 0 || len(p) < len(root) || p[:len(root)] != root {
		return false
	}
	return len(p) == len(root) || p[len(root)] == '/' || root[len(root) - 1] == '/'
}

@(private)
_darwin_lock_procs :: proc(lock: string, roots: []string, allocator: runtime.Allocator) -> []fs.Git_Proc {
	out := make([dynamic]fs.Git_Proc, allocator)
	pids := make([]c.int, 8192, context.temp_allocator)
	n := proc_listallpids(raw_data(pids), c.int(len(pids) * size_of(c.int)))
	if n <= 0 {
		return out[:]
	}
	fds := make([]Proc_Fdinfo, 1024, context.temp_allocator)
	cb: [MAXPATHLEN]u8
	for i in 0 ..< min(int(n), len(pids)) {
		pid := prim.Pid(pids[i])
		if pid <= 1 {
			continue
		}
		info: Bsd_Info
		if proc_pidinfo(c.int(pid), PROC_PIDTBSDINFO, 0, &info, size_of(Bsd_Info)) != size_of(Bsd_Info) {
			continue
		}
		cl := 0
		for cl < len(info.comm) && info.comm[cl] != 0 {
			cl += 1
		}
		if string(info.comm[:cl]) != "git" {
			continue
		}
		holder := false
		bytes := proc_pidinfo(c.int(pid), PROC_PIDLISTFDS, 0, raw_data(fds), c.int(len(fds) * size_of(Proc_Fdinfo)))
		for k in 0 ..< max(int(bytes), 0) / size_of(Proc_Fdinfo) {
			if fds[k].type != PROX_FDTYPE_VNODE {
				continue
			}
			vfi: Vnode_Fdinfo_With_Path
			if proc_pidfdinfo(c.int(pid), fds[k].fd, PROC_PIDFDVNODEPATHINFO, &vfi, size_of(Vnode_Fdinfo_With_Path)) != size_of(Vnode_Fdinfo_With_Path) {
				continue
			}
			l := 0
			for l < MAXPATHLEN && vfi.path[l] != 0 {
				l += 1
			}
			if _strip_firmlink(string(vfi.path[:l])) == lock {
				holder = true
				break
			}
		}
		cwd := _cwd_of(pid, cb[:])
		near := false
		for r in roots {
			near ||= _path_under(cwd, r)
		}
		if !holder && !near {
			continue
		}
		append(&out, fs.Git_Proc{pid = pid, holder = holder})
	}
	return out[:]
}

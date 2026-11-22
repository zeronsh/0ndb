package fs

import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "../prim"

git_pid_alive :: proc(pid: prim.Pid) -> bool {
	if pid <= 0 {
		return false
	}
	return linux.kill(linux.Pid(pid), linux.Signal(0)) != .ESRCH
}

git_proc_argv :: proc(pid: prim.Pid, allocator := context.temp_allocator) -> []string {
	buf: [64]u8
	path := _proc_path(buf[:], pid, "cmdline")
	data, err := prim.read_file(prim.os_vfs(), path, allocator)
	if err != .None || len(data) == 0 {
		return nil
	}
	s := string(data)
	if s[len(s) - 1] == 0 {
		s = s[:len(s) - 1]
	}
	return strings.split(s, "\x00", allocator)
}

git_lock_procs :: proc(lock: string, roots: []string, allocator := context.temp_allocator) -> []Git_Proc {
	vfs := prim.os_vfs()
	out := make([dynamic]Git_Proc, allocator)
	d: prim.Dir
	if prim.dir_open(vfs, &d, "/proc", context.temp_allocator) != .None {
		return out[:]
	}
	defer prim.dir_close(vfs, &d)
	for {
		ent, more, err := prim.dir_next(vfs, &d)
		if err != .None || !more {
			break
		}
		n, ok := strconv.parse_int(ent.name)
		if !ok || n <= 0 {
			continue
		}
		pid := prim.Pid(n)
		buf: [64]u8
		comm, cerr := prim.read_file(vfs, _proc_path(buf[:], pid, "comm"), context.temp_allocator)
		if cerr != .None || strings.trim_space(string(comm)) != "git" {
			continue
		}
		holder := _proc_holds(pid, lock)
		lb: [prim.PATH_MAX]u8
		cn, lerr := prim.readlink(vfs, _proc_path(buf[:], pid, "cwd"), lb[:])
		cwd := string(lb[:cn]) if lerr == .None else ""
		near := false
		for r in roots {
			if len(r) > 0 && len(cwd) > 0 && (cwd == r || strings.has_prefix(cwd, r) && len(cwd) > len(r) && cwd[len(r)] == '/') {
				near = true
			}
		}
		if holder || near {
			append(&out, Git_Proc{pid = pid, argv = git_proc_argv(pid, allocator), holder = holder})
		}
	}
	return out[:]
}

@(private)
_proc_holds :: proc(pid: prim.Pid, lock: string) -> bool {
	vfs := prim.os_vfs()
	buf: [64]u8
	d: prim.Dir
	if prim.dir_open(vfs, &d, _proc_path(buf[:], pid, "fd"), context.temp_allocator) != .None {
		return false
	}
	defer prim.dir_close(vfs, &d)
	for {
		ent, more, err := prim.dir_next(vfs, &d)
		if err != .None || !more {
			return false
		}
		p := strings.concatenate({_proc_path(buf[:], pid, "fd"), "/", ent.name}, context.temp_allocator)
		lb: [prim.PATH_MAX]u8
		n, lerr := prim.readlink(vfs, p, lb[:])
		if lerr == .None && string(lb[:n]) == lock {
			return true
		}
	}
}

@(private)
_proc_path :: proc(buf: []u8, pid: prim.Pid, leaf: string) -> string {
	nb: [24]u8
	num := strconv.write_int(nb[:], i64(pid), 10)
	n := copy(buf, "/proc/")
	n += copy(buf[n:], num)
	n += copy(buf[n:], "/")
	n += copy(buf[n:], leaf)
	return string(buf[:n])
}

#+build linux
package observe

import "base:intrinsics"
import "core:sys/linux"
import "../prim"

@(private)
ELOOP :: 40
@(private)
PROC_SUPER_MAGIC :: i64(0x9fa0)
@(private)
MAX_LINKS :: 40

@(private)
Ctx :: struct {
	s:     ^Supervisor,
	tid:   i32,
	tgid:  i32,
	root:  i32,
	links: int,
	nsdiff: int,
}

@(private)
Loc :: struct {
	dfd:  i32,
	name: string,
}

@(private)
_split :: proc "contextless" (p: string) -> (dir: string, name: string) {
	q := p
	for len(q) > 1 && q[len(q) - 1] == '/' {
		q = q[:len(q) - 1]
	}
	if q == "/" {
		return "/", ""
	}
	i := len(q) - 1
	for i >= 0 && q[i] != '/' {
		i -= 1
	}
	if i < 0 {
		dir = "."
		name = q
	} else if i == 0 {
		dir = "/"
		name = q[1:]
	} else {
		dir = q[:i]
		name = q[i + 1:]
	}
	if name == "." || name == ".." {
		return q, ""
	}
	return
}

@(private)
_base :: proc(pp: ^Proc_Path, tid: i32, dirfd: i32) -> cstring {
	if dirfd == AT_FDCWD {
		return _pp_proc(pp, i64(tid), "/cwd")
	}
	_pp_reset(pp)
	_pp_str(pp, "/proc/")
	_pp_int(pp, i64(tid))
	_pp_str(pp, "/fd/")
	_pp_int(pp, i64(dirfd))
	return _pp_c(pp)
}

@(private)
_cstr :: proc(s: string, buf: []u8) -> (cstring, bool) {
	if len(s) + 1 > len(buf) {
		return nil, false
	}
	copy(buf, s)
	buf[len(s)] = 0
	return cstring(raw_data(buf)), true
}

@(private)
_dup_dir :: proc "contextless" (fd: i32) -> (i32, int) {
	return _sys_openat(fd, ".", SYS_O_PATH | SYS_O_CLOEXEC)
}

@(private)
_root_fd :: proc(c: ^Ctx) -> i32 {
	if c.root >= 0 {
		return c.root
	}
	pp: Proc_Path
	fd, e := _sys_openat(AT_FDCWD, _pp_proc(&pp, i64(c.tid), "/root"), SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
	if e != 0 {
		return -1
	}
	c.root = fd
	return fd
}

@(private)
_is_procfs :: proc "contextless" (fd: i32) -> bool {
	buf: [120]u8
	r := intrinsics.syscall(linux.SYS_fstatfs, uintptr(int(fd)), uintptr(&buf))
	if _errno(r) != 0 {
		return false
	}
	return (^i64)(&buf)^ == PROC_SUPER_MAGIC
}

@(private)
_resolve :: proc(c: ^Ctx, a: Path_Arg, arg: []u8, out: []u8) -> (path: string, exact: bool, ok: bool) {
	p := ""
	res := Mem_Result.Ok
	if a.addr != 0 {
		p, res = _read_str(c.tid, a.addr, arg)
	}
	pp: Proc_Path
	switch res {
	case .Fault, .Too_Long:
		return "", false, false
	case .Denied:
		fd, e := _sys_openat(AT_FDCWD, _base(&pp, c.tid, a.dirfd), SYS_O_PATH | SYS_O_CLOEXEC)
		if e != 0 {
			return "", false, false
		}
		dp, dok := _finish(c, Loc{fd, ""}, out)
		return dp, false, dok
	case .Ok:
	}
	if len(p) == 0 && !a.empty {
		return "", false, false
	}
	needs_base := len(p) == 0 || p[0] != '/' || a.resolve & RESOLVE_IN_ROOT != 0
	base: i32 = -1
	if needs_base {
		e: int
		base, e = _sys_openat(AT_FDCWD, _base(&pp, c.tid, a.dirfd), SYS_O_PATH | SYS_O_CLOEXEC)
		if e != 0 {
			return "", false, false
		}
		if len(p) == 0 {
			fp, fok := _finish(c, Loc{base, ""}, out)
			return fp, fok, fok
		}
		if a.resolve & RESOLVE_IN_ROOT != 0 {
			r, re := _dup_dir(base)
			if re != 0 {
				_sys_close(base)
				return "", false, false
			}
			c.root = r
		}
	}
	loc, lok := _locate(c, base, p, a.resolve)
	_sys_close(base)
	if !lok {
		return "", false, false
	}
	if a.follow && len(loc.name) > 0 && a.resolve & RESOLVE_NO_SYMLINKS == 0 {
		loc, lok = _follow(c, loc)
		if !lok {
			return "", false, false
		}
	}
	fp, fok := _finish(c, loc, out)
	return fp, fok, fok
}

@(private)
_locate :: proc(c: ^Ctx, base: i32, p: string, user_resolve: u64) -> (Loc, bool) {
	dir, name := _split(p)
	abs := p[0] == '/'
	from := base
	if abs {
		from = _root_fd(c)
		if from < 0 {
			return {}, false
		}
	}
	dbuf: [prim.PATH_MAX + 1]u8
	cdir, cok := _cstr(dir, dbuf[:])
	if !cok {
		return {}, false
	}
	if c.s.has_openat2 {
		how := Open_How {
			flags   = u64(SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC),
			resolve = RESOLVE_NO_SYMLINKS | user_resolve | (RESOLVE_IN_ROOT if abs else 0),
		}
		dfd, e := _sys_openat2(from, cdir, &how)
		if e == 0 {
			return Loc{dfd, name}, true
		}
		if e != ELOOP || user_resolve & RESOLVE_NO_SYMLINKS != 0 {
			return {}, false
		}
	}
	dfd, ok := _walk_dir(c, from, dir)
	if !ok {
		return {}, false
	}
	return Loc{dfd, name}, true
}

@(private)
_locate_manual :: proc(c: ^Ctx, from: i32, p: string) -> (Loc, bool) {
	if len(p) == 0 {
		return {}, false
	}
	dir, name := _split(p)
	start := from
	if p[0] == '/' {
		start = _root_fd(c)
		if start < 0 {
			return {}, false
		}
	}
	dfd, ok := _walk_dir(c, start, dir)
	if !ok {
		return {}, false
	}
	return Loc{dfd, name}, true
}

@(private)
_walk_dir :: proc(c: ^Ctx, from: i32, dir: string) -> (i32, bool) {
	start := from
	rest := dir
	if len(rest) > 0 && rest[0] == '/' {
		start = _root_fd(c)
		if start < 0 {
			return -1, false
		}
	}
	cur, e := _dup_dir(start)
	if e != 0 {
		return -1, false
	}
	for len(rest) > 0 {
		comp := rest
		if i := _index_byte(rest, '/'); i >= 0 {
			comp = rest[:i]
			rest = rest[i + 1:]
		} else {
			rest = ""
		}
		if len(comp) == 0 || comp == "." {
			continue
		}
		if comp == ".." {
			if c.root >= 0 && _same_dir(cur, c.root) {
				continue
			}
			up, ue := _sys_openat(cur, "..", SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
			_sys_close(cur)
			if ue != 0 {
				return -1, false
			}
			cur = up
			continue
		}
		next, ok := _step(c, cur, comp)
		_sys_close(cur)
		if !ok {
			return -1, false
		}
		cur = next
	}
	return cur, true
}

@(private)
_same_dir :: proc "contextless" (a: i32, b: i32) -> bool {
	x, xe := _sys_statx(a, "", uintptr(AT_EMPTY_PATH))
	y, ye := _sys_statx(b, "", uintptr(AT_EMPTY_PATH))
	return xe == 0 && ye == 0 && x.dev == y.dev && x.ino == y.ino
}

@(private)
_step :: proc(c: ^Ctx, cur: i32, comp: string) -> (i32, bool) {
	nb: [256]u8
	cname, cok := _cstr(comp, nb[:])
	if !cok {
		return -1, false
	}
	if (comp == "self" || comp == "thread-self") && _is_procfs(cur) {
		pp: Proc_Path
		cp: cstring
		if comp == "self" {
			cp = _pp_proc(&pp, i64(c.tgid), "")
		} else {
			_pp_reset(&pp)
			_pp_str(&pp, "/proc/")
			_pp_int(&pp, i64(c.tgid))
			_pp_str(&pp, "/task/")
			_pp_int(&pp, i64(c.tid))
			cp = _pp_c(&pp)
		}
		fd, e := _sys_openat(AT_FDCWD, cp, SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
		return fd, e == 0
	}
	st, se := _sys_statx(cur, cname, uintptr(AT_SYMLINK_NOFOLLOW))
	if se != 0 {
		return -1, false
	}
	if !_is_link(st.mode) {
		fd, e := _sys_openat(cur, cname, SYS_O_PATH | SYS_O_CLOEXEC | SYS_O_NOFOLLOW)
		return fd, e == 0
	}
	loc, ok := _follow(c, Loc{cur, comp}, false)
	if !ok {
		return -1, false
	}
	if len(loc.name) == 0 {
		return loc.dfd, true
	}
	lb: [256]u8
	lname, lok := _cstr(loc.name, lb[:])
	if !lok {
		_sys_close(loc.dfd)
		return -1, false
	}
	fd, e := _sys_openat(loc.dfd, lname, SYS_O_PATH | SYS_O_CLOEXEC | SYS_O_NOFOLLOW)
	_sys_close(loc.dfd)
	return fd, e == 0
}

@(private)
_follow :: proc(c: ^Ctx, start: Loc, owned := true) -> (Loc, bool) {
	loc := start
	own := owned
	for len(loc.name) > 0 {
		nb: [256]u8
		cname, cok := _cstr(loc.name, nb[:])
		if !cok {
			break
		}
		st, se := _sys_statx(loc.dfd, cname, uintptr(AT_SYMLINK_NOFOLLOW))
		if se != 0 || !_is_link(st.mode) {
			break
		}
		c.links += 1
		if c.links > MAX_LINKS {
			if own {
				_sys_close(loc.dfd)
			}
			return {}, false
		}
		if _is_procfs(loc.dfd) {
			fd, e := _sys_openat(loc.dfd, cname, SYS_O_PATH | SYS_O_CLOEXEC)
			if own {
				_sys_close(loc.dfd)
			}
			if e != 0 {
				return {}, false
			}
			return Loc{fd, ""}, true
		}
		target := make([]u8, prim.PATH_MAX, context.temp_allocator)
		n, le := _sys_readlinkat(loc.dfd, cname, target)
		if le != 0 || n <= 0 || n >= len(target) {
			if own {
				_sys_close(loc.dfd)
			}
			return {}, false
		}
		next, ok := _locate_manual(c, loc.dfd, string(target[:n]))
		if own {
			_sys_close(loc.dfd)
		}
		if !ok {
			return {}, false
		}
		loc = next
		own = true
	}
	if !own {
		fd, e := _dup_dir(loc.dfd)
		if e != 0 {
			return {}, false
		}
		loc.dfd = fd
	}
	return loc, true
}

@(private)
_is_foreign :: proc(c: ^Ctx) -> bool {
	if c.nsdiff != 0 {
		return c.nsdiff == 2
	}
	c.nsdiff = 1
	s := c.s
	if s.mnt_ns_len == 0 {
		return false
	}
	pp: Proc_Path
	buf: [64]u8
	n, e := _sys_readlinkat(AT_FDCWD, _pp_proc(&pp, i64(c.tid), "/ns/mnt"), buf[:])
	if e != 0 || n != s.mnt_ns_len || string(buf[:n]) != string(s.mnt_ns[:n]) {
		c.nsdiff = 2
	}
	return c.nsdiff == 2
}

@(private)
_finish :: proc(c: ^Ctx, loc: Loc, out: []u8) -> (string, bool) {
	defer _sys_close(loc.dfd)
	dp, ok := _readlink_fd(loc.dfd, out[:prim.PATH_MAX])
	if !ok || len(dp) == 0 || dp[0] != '/' {
		return "", false
	}
	n := len(dp)
	if _is_foreign(c) {
		mapped, mok := _map_foreign(c.s, loc.dfd, dp)
		if !mok || len(mapped) > len(out) {
			return "", false
		}
		copy(out, mapped)
		n = len(mapped)
	}
	if len(loc.name) > 0 {
		if n + 1 + len(loc.name) > len(out) {
			return "", false
		}
		if n > 1 {
			out[n] = '/'
			n += 1
		}
		copy(out[n:], loc.name)
		n += len(loc.name)
	}
	return string(out[:n]), true
}

@(private)
_map_foreign :: proc(s: ^Supervisor, fd: i32, dp: string) -> (string, bool) {
	cp: [prim.PATH_MAX + 1]u8
	cpath, _ := _cstr(dp, cp[:])
	mine, me := _sys_statx(AT_FDCWD, cpath, uintptr(AT_SYMLINK_NOFOLLOW))
	theirs, te := _sys_statx(fd, "", uintptr(AT_EMPTY_PATH))
	if te != 0 {
		return "", false
	}
	if me == 0 && mine.dev == theirs.dev && mine.ino == theirs.ino {
		return dp, true
	}
	router_refresh(&s.router)
	if len(s.router.roots) == 0 {
		return "", false
	}
	cur, ce := _dup_dir(fd)
	if ce != 0 {
		return "", false
	}
	defer _sys_close(cur)
	tail := len(dp)
	for {
		st, se := _sys_statx(cur, "", uintptr(AT_EMPTY_PATH))
		if se != 0 {
			return "", false
		}
		for root in s.router.roots {
			if root.dev == st.dev && root.ino == st.ino {
				rest := dp[tail:]
				out := s.sc.tmp[:]
				if len(root.real) + len(rest) > len(out) {
					return "", false
				}
				copy(out, root.real)
				copy(out[len(root.real):], rest)
				return string(out[:len(root.real) + len(rest)]), true
			}
		}
		if tail == 0 {
			return "", false
		}
		j := tail - 1
		for j > 0 && dp[j] != '/' {
			j -= 1
		}
		tail = j
		up, ue := _sys_openat(cur, "..", SYS_O_PATH | SYS_O_DIRECTORY | SYS_O_CLOEXEC)
		if ue != 0 {
			return "", false
		}
		_sys_close(cur)
		cur = up
	}
}

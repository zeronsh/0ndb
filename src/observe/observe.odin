package observe

import "base:runtime"
import "core:strings"
import "../fs"
import "../prim"

Op :: enum u8 {
	Write,
	Truncate,
	Mkdir,
	Remove,
	Rmdir,
	Rename,
	Exchange,
	Link,
	Symlink,
	Mknod,
	Chmod,
	Close,
}

MAX_LINEAGE :: 64

Write :: struct {
	op:      Op,
	tid:     prim.Pid,
	pid:     prim.Pid,
	tree:    prim.Pid,
	lineage: []prim.Pid,
	path:    string,
	from:    string,
	flags:   u32,
	exact:   bool,
	dev:     u64,
	args:    []u8,
	window:  bool,
	git:     bool,
}

Stats :: struct {
	notifications: u64,
	reported:      u64,
	ignored:       u64,
	failed:        u64,
	inexact:       u64,
	stale:         u64,
	parked:        u64,
	released:      u64,
}

Sink :: struct {
	data:  rawptr,
	write: proc(data: rawptr, w: ^Write),
}

Root :: struct {
	mount: ^fs.Mount,
	root:  string,
	real:  string,
	dev:   u64,
	ino:   u64,
}

Router :: struct {
	reg:       ^fs.Registry,
	roots:     [dynamic]Root,
	allocator: runtime.Allocator,
}

router_init :: proc(r: ^Router, allocator := context.allocator) {
	r^ = {
		allocator = allocator,
	}
	r.roots = make([dynamic]Root, allocator)
}

router_destroy :: proc(r: ^Router) {
	router_clear(r)
	delete(r.roots)
	r^ = {}
}

router_bind :: proc(r: ^Router, reg: ^fs.Registry) {
	router_clear(r)
	r.reg = reg
}

router_clear :: proc(r: ^Router) {
	for root in r.roots {
		delete(root.root, r.allocator)
		delete(root.real, r.allocator)
	}
	clear(&r.roots)
}

router_refresh :: proc(r: ^Router) {
	if r.reg == nil {
		return
	}
	live := 0
	for m in r.reg.mounts {
		if m == nil {
			continue
		}
		live += 1
		found := false
		for root in r.roots {
			if root.mount == m && root.root == m.root {
				found = true
				break
			}
		}
		if !found {
			_router_add(r, m)
		}
	}
	if len(r.roots) == live {
		return
	}
	i := 0
	for i < len(r.roots) {
		keep := false
		for m in r.reg.mounts {
			if m != nil && m == r.roots[i].mount && m.root == r.roots[i].root {
				keep = true
				break
			}
		}
		if keep {
			i += 1
			continue
		}
		delete(r.roots[i].root, r.allocator)
		delete(r.roots[i].real, r.allocator)
		unordered_remove(&r.roots, i)
	}
}

@(private)
_router_add :: proc(r: ^Router, m: ^fs.Mount) {
	root, rerr := strings.clone(m.root, r.allocator)
	if rerr != nil {
		return
	}
	real, dev, ino, ok := real_path(m.root, r.allocator)
	if !ok {
		real, _ = strings.clone(m.root, r.allocator)
	}
	append(&r.roots, Root{mount = m, root = root, real = real, dev = dev, ino = ino})
}

real_path :: proc(path: string, allocator := context.allocator) -> (real: string, dev: u64, ino: u64, ok: bool) {
	res, err := prim.real_path(path, allocator)
	if err != .None {
		return
	}
	st, serr := prim.stat(prim.os_vfs(), res)
	if serr != .None {
		delete(res, allocator)
		return
	}
	return res, st.dev, st.ino, true
}

under :: proc "contextless" (path: string, root: string) -> (rel: string, ok: bool) {
	if len(root) == 0 {
		return
	}
	if root == "/" {
		if len(path) > 0 && path[0] == '/' {
			return path[1:], true
		}
		return
	}
	if len(path) < len(root) || path[:len(root)] != root {
		return
	}
	if len(path) == len(root) {
		return "", true
	}
	if path[len(root)] != '/' {
		return
	}
	return path[len(root) + 1:], true
}

router_locate :: proc(r: ^Router, path: string) -> (m: ^fs.Mount, rel: string, ok: bool) {
	if r.reg == nil || !path_is_abs(path) {
		return
	}
	router_refresh(r)
	p := _strip_firmlink(path)
	best := -1
	for root, i in r.roots {
		if x, in_root := under(p, root.real); in_root {
			if best < 0 || len(root.real) > len(r.roots[best].real) {
				best = i
				rel = x
			}
		}
	}
	if best < 0 {
		return
	}
	return r.roots[best].mount, rel, true
}

scope_of :: proc(reg: ^fs.Registry, lineage: []prim.Pid) -> ^fs.Scope {
	if reg == nil {
		return nil
	}
	for pid in lineage {
		if pid <= 1 {
			continue
		}
		for i := len(reg.scopes) - 1; i >= 0; i -= 1 {
			s := reg.scopes[i]
			if s.closing {
				continue
			}
			for p in s.pids {
				if p == pid {
					return s
				}
			}
		}
	}
	return nil
}

route :: proc(r: ^Router, w: ^Write, scope: ^fs.Scope) {
	if r.reg == nil {
		return
	}
	if w.op == .Close {
		if m, rel, ok := router_locate(r, w.path); ok && len(rel) > 0 {
			fs.mount_closed(m, rel)
		}
		return
	}
	if !w.exact && w.dev != 0 {
		if _, _, found := router_locate(r, w.path); !found {
			for root in r.roots {
				if root.dev == w.dev {
					fs.mount_mark_rescan(root.mount)
				}
			}
			return
		}
	}
	_route_path(r, w.path, w.exact, scope)
	if w.op == .Rename || w.op == .Exchange {
		_route_path(r, w.from, w.exact, scope)
	}
}

route_write :: proc(r: ^Router, w: ^Write) {
	route(r, w, scope_of(r.reg, w.lineage))
}

@(private)
_route_path :: proc(r: ^Router, path: string, exact: bool, scope: ^fs.Scope) {
	m, rel, ok := router_locate(r, path)
	if !ok {
		return
	}
	if len(rel) == 0 {
		if !exact {
			fs.mount_mark_rescan(m)
		}
		return
	}
	if fs.path_internal(rel) {
		return
	}
	fs.mount_mark_observed(m, rel, scope)
}

deliver :: proc(r: ^Router, sink: Sink, w: ^Write) {
	if sink.write != nil {
		sink.write(sink.data, w)
		return
	}
	route_write(r, w)
}

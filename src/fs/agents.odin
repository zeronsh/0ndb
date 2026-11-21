package fs

import "base:runtime"
import "core:strings"
import "../prim"

AGENTS_SETUP :: ".agents/setup"
AGENTS_LINKED :: ".agents/linked"

agents_setup :: proc(vfs: prim.Vfs, root: string, allocator := context.allocator) -> (path: string, found: bool) {
	p, _ := path_join(root, AGENTS_SETUP, allocator)
	st, err := prim.stat(vfs, p)
	if err != .None || st.kind != .File || st.mode & 0o111 == 0 {
		delete(p, allocator)
		return "", false
	}
	return p, true
}

mount_needs_setup :: proc(m: ^Mount) -> bool {
	if _, found := agents_setup(m.vfs, m.root, context.temp_allocator); !found {
		return false
	}
	p, _ := path_join(m.dir, "setup-done", context.temp_allocator)
	return !prim.exists(m.vfs, p)
}

mount_setup_done :: proc(m: ^Mount) -> Error {
	p, _ := path_join(m.dir, "setup-done", context.temp_allocator)
	return from_prim(prim.replace_atomic(m.vfs, p, nil))
}

agents_link :: proc(vfs: prim.Vfs, source: ^Ignore, source_root, dest_root: string) -> (linked: int, err: Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	lp, _ := path_join(source_root, AGENTS_LINKED, context.temp_allocator)
	data, rerr := prim.read_file(vfs, lp, context.temp_allocator)
	if rerr == .Not_Found {
		return 0, .None
	}
	if rerr != .None {
		return 0, from_prim(rerr)
	}
	s := string(data)
	for raw in strings.split_lines_iterator(&s) {
		line := strings.trim_space(raw)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		for len(line) > 0 && line[len(line) - 1] == '/' {
			line = line[:len(line) - 1]
		}
		if len(line) > 0 && line[0] == '/' {
			line = line[1:]
		}
		if !path_valid(line) || path_internal(line) {
			continue
		}
		src, _ := path_join(source_root, line, context.temp_allocator)
		st, serr := prim.lstat(vfs, src)
		if serr != .None {
			continue
		}
		if !ignore_path(source, source_root, line, st.kind == .Dir) {
			continue
		}
		dst, _ := path_join(dest_root, line, context.temp_allocator)
		if prim.exists(vfs, dst) {
			continue
		}
		parent := path_parent(line)
		if len(parent) > 0 {
			pd, _ := path_join(dest_root, parent, context.temp_allocator)
			from_prim(prim.mkdir_all(vfs, pd, 0o755)) or_return
		}
		from_prim(prim.symlink(vfs, src, dst)) or_return
		linked += 1
	}
	return linked, .None
}

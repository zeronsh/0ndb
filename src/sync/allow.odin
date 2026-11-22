package osync

import "base:runtime"
import "core:strconv"
import "core:strings"
import "../prim"

Allow :: struct {
	vfs:       prim.Vfs,
	path:      string,
	spaces:    map[Space_Id]i64,
	size:      i64,
	mtime:     i64,
	ino:       u64,
	loaded:    bool,
	allocator: runtime.Allocator,
}

allow_init :: proc(a: ^Allow, vfs: prim.Vfs, path: string, allocator := context.allocator) {
	a^ = {
		vfs       = vfs,
		path      = path,
		allocator = allocator,
	}
	a.spaces = make(map[Space_Id]i64, allocator)
}

allow_destroy :: proc(a: ^Allow) {
	delete(a.spaces)
	a^ = {}
}

allow_lookup :: proc(a: ^Allow, id: Space_Id) -> (quota: i64, ok: bool) {
	_allow_refresh(a)
	quota, ok = a.spaces[id]
	return
}

@(private)
_allow_refresh :: proc(a: ^Allow) {
	if len(a.path) == 0 {
		return
	}
	fd, oerr := prim.open_file(a.vfs, a.path)
	if oerr != .None {
		if a.loaded {
			clear(&a.spaces)
			a.loaded = false
		}
		return
	}
	defer prim.close_file(a.vfs, fd)
	st, serr := prim.fstat(a.vfs, fd)
	size, mtime, ino := st.size, st.mtime_ns, st.ino
	if serr != .None {
		return
	}
	if a.loaded && size == a.size && mtime == a.mtime && ino == a.ino {
		return
	}
	if size > 16 * 1024 * 1024 {
		return
	}
	data, aerr := make([]u8, int(size), context.temp_allocator)
	if aerr != nil {
		return
	}
	n, rerr := prim.read_at(a.vfs, fd, data, 0)
	if rerr != .None {
		return
	}
	clear(&a.spaces)
	text := string(data[:n])
	for line in strings.split_lines_iterator(&text) {
		l := line
		if hash := strings.index_byte(l, '#'); hash >= 0 {
			l = l[:hash]
		}
		l = strings.trim_space(l)
		if len(l) == 0 {
			continue
		}
		fields := strings.fields(l, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		id, ok := prim.id_parse(fields[0])
		if !ok {
			continue
		}
		quota: i64
		if len(fields) > 1 {
			q, qok := parse_size(fields[1])
			if !qok {
				continue
			}
			quota = q
		}
		a.spaces[id] = quota
	}
	a.size = size
	a.mtime = mtime
	a.ino = ino
	a.loaded = true
}

parse_size :: proc(s: string) -> (v: i64, ok: bool) {
	if s == "unlimited" || s == "-" || s == "0" {
		return 0, true
	}
	mult: i64 = 1
	t := s
	if len(t) > 0 {
		switch t[len(t) - 1] {
		case 'k', 'K':
			mult = 1 << 10
		case 'm', 'M':
			mult = 1 << 20
		case 'g', 'G':
			mult = 1 << 30
		case 't', 'T':
			mult = 1 << 40
		}
		if mult != 1 {
			t = t[:len(t) - 1]
		}
	}
	n, pok := strconv.parse_u64_of_base(t, 10)
	if !pok || n == 0 || n > u64(max(i64) / mult) {
		return 0, false
	}
	return i64(n) * mult, true
}

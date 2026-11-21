package fs

import "core:slice"
import "../odb"
import "../prim"

Gitlink :: struct {
	path: string,
	oid:  odb.Oid,
}

@(private)
GITLINKS_FILE :: "gitlinks"

@(private)
gitlinks_refresh :: proc(m: ^Mount) -> (links: []Gitlink, err: Error) {
	if !m.has_git {
		return nil, .None
	}
	stamp := git_index_stamp(m.vfs, m.git)
	p, _ := path_join(m.dir, GITLINKS_FILE, context.temp_allocator)
	old := make([dynamic]Gitlink, context.temp_allocator)
	have_old := false
	if data, rerr := prim.read_file(m.vfs, p, context.temp_allocator); rerr == .None {
		rd := prim.reader(data)
		if prim.read_u8(&rd) == 1 {
			s := Index_Stamp{mtime_ns = prim.read_ivarint(&rd), size = prim.read_ivarint(&rd), ino = prim.read_uvarint(&rd)}
			n := prim.read_uvarint(&rd)
			if n <= u64(prim.reader_remaining(&rd)) {
				for _ in 0 ..< n {
					gl: Gitlink
					gl.path = prim.read_str(&rd)
					prim.read_fixed(&rd, gl.oid[:])
					append(&old, gl)
				}
			}
			if prim.reader_ok(&rd) {
				have_old = true
				if s == stamp {
					return old[:], .None
				}
			}
		}
	}
	cur := make([dynamic]Gitlink, context.temp_allocator)
	r: Index_Reader
	if index_open(&r, m.vfs, m.git.dir, m.git_format, context.temp_allocator) == .None {
		for {
			e, ok, ierr := index_next(&r)
			if ierr != .None || !ok {
				break
			}
			if e.stage == 0 && e.mode & 0o170000 == 0o160000 {
				path, _ := clone_string(e.path, context.temp_allocator)
				append(&cur, Gitlink{path, e.oid})
			}
		}
		index_close(&r)
	}
	slice.sort_by(cur[:], proc(a, b: Gitlink) -> bool {return a.path < b.path})
	for gl in cur {
		same := false
		for o in old {
			if o.path == gl.path && o.oid == gl.oid {
				same = true
				break
			}
		}
		if !same || !have_old {
			invalidate_parents(m, gl.path) or_return
		}
	}
	for o in old {
		found := false
		for gl in cur {
			if gl.path == o.path {
				found = true
				break
			}
		}
		if !found {
			invalidate_parents(m, o.path) or_return
		}
	}
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, 1)
	prim.write_ivarint(&w, stamp.mtime_ns)
	prim.write_ivarint(&w, stamp.size)
	prim.write_uvarint(&w, stamp.ino)
	prim.write_uvarint(&w, u64(len(cur)))
	for gl in cur {
		prim.write_str(&w, gl.path)
		o := gl.oid
		prim.write_raw(&w, o[:])
	}
	from_prim(prim.replace_atomic(m.vfs, p, buf[:])) or_return
	return cur[:], .None
}

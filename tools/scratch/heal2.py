p='src/fs/shadow.odin';s=open(p).read()
def one(a,b,n=1):
    global s
    assert s.count(a)==n,(s.count(a),a); s=s.replace(a,b)
one("	shadow_detach(&n)\n	old_log :=","	s.mark = {ng, n.log_end}\n	shadow_detach(&n)\n	old_log :=")
one("""	err := open_gen(s)
	if err != .None {
		shadow_detach(s)
	}
	return err""","""	err := open_gen(s)
	if err != .None {
		shadow_detach(s)
	} else if !s.damaged {
		s.mark = {s.gen, s.log_end}
	}
	return err""")
one("@(private = \"file\")\nkey_live ::","""Shadow_Row :: struct {
	path:  string,
	entry: Entry,
}

@(private)
shadow_salvage :: proc(s: ^Shadow, rows: ^map[string]Entry, allocator := context.temp_allocator) -> Error {
	if s.log_fd < 0 {
		return .None
	}
	end := s.log_end
	if s.gen == s.mark.gen && s.mark.end != 0 {
		end = min(end, s.mark.end)
	}
	off := u64(SHADOW_LOG_HEADER)
	for off < end {
		r, err := read_rec(s, off, &s.scratch)
		if err == .Corrupt || err == .None && off + r.size > end {
			off = next_rec(s, off, end) or_return
			if off == 0 {
				return .None
			}
			continue
		}
		if err != .None {
			return err
		}
		off += r.size
		if r.del {
			delete_key(rows, r.path)
			continue
		}
		if r.path in rows {
			rows[r.path] = r.entry
			continue
		}
		p, aerr := clone_string(r.path, allocator)
		if aerr != nil {
			return .No_Memory
		}
		rows[p] = r.entry
	}
	return .None
}

@(private = "file")
next_rec :: proc(s: ^Shadow, bad, end: u64) -> (off: u64, err: Error) {
	head: [4]u8
	got, rerr := prim.read_at(s.vfs, s.log_fd, head[:], i64(bad))
	if rerr != .None {
		return 0, from_prim(rerr)
	}
	n := u64(prim.get_u32le(head[:]))
	if got == 4 && n <= SHADOW_MAX_RECORD && bad + 8 + n < end {
		_, verr := read_rec(s, bad + 8 + n, &s.scratch)
		if verr == .None {
			return bad + 8 + n, .None
		}
		if verr != .Corrupt {
			return 0, verr
		}
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	buf := make([]u8, 1 << 16, context.temp_allocator)
	pos := bad + 1
	for pos + 10 <= end {
		got, rerr = prim.read_at(s.vfs, s.log_fd, buf[:min(u64(len(buf)), end - pos)], i64(pos))
		if rerr != .None {
			return 0, from_prim(rerr)
		}
		if got < 10 {
			break
		}
		for k in 0 ..= got - 10 {
			size := u64(prim.get_u32le(buf[k:k + 4]))
			if size < 3 || size > 1 << 16 || buf[k + 8] != 1 && buf[k + 8] != 2 || buf[k + 9] > 3 || pos + u64(k) + 8 + size > end {
				continue
			}
			_, verr := read_rec(s, pos + u64(k), &s.scratch)
			if verr == .None {
				return pos + u64(k), .None
			}
			if verr != .Corrupt {
				return 0, verr
			}
		}
		pos += u64(got - 9)
	}
	return 0, .None
}

@(private)
shadow_rewrite :: proc(s: ^Shadow, rows: []Shadow_Row) -> Error {
	held := s.lock
	s.lock = nil
	defer s.lock = held
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ng := max(s.gen, s.mark.gen, s.burned) + 1
	for prim.exists(s.vfs, gen_path(s.dir, ng, "log", context.temp_allocator)) {
		ng += 1
	}
	log_path := gen_path(s.dir, ng, "log", context.temp_allocator)
	idx_path := gen_path(s.dir, ng, "idx", context.temp_allocator)
	prim.remove(s.vfs, idx_path)
	n := Shadow {
		vfs       = s.vfs,
		dir       = s.dir,
		allocator = s.allocator,
		oid_size  = s.oid_size,
		gen       = ng,
		log_fd    = prim.INVALID_FD,
		idx_fd    = prim.INVALID_FD,
	}
	n.pending = make([dynamic]Pending_Rec, s.allocator)
	n.index = make(map[string]int, s.allocator)
	n.by_inode = make(map[fstree.Inode_Id]int, s.allocator)
	n.scratch = make([dynamic]u8, s.allocator)
	n.probe = make([dynamic]u8, s.allocator)
	n.out = make([dynamic]u8, s.allocator)
	n.versions = make([dynamic][]fstree.Op_Id, s.allocator)
	ok := false
	defer if !ok {
		shadow_detach(&n)
		prim.remove(s.vfs, log_path)
		prim.remove(s.vfs, idx_path)
	}
	slice.sort_by(rows, proc(a, b: Shadow_Row) -> bool {
		x, y := path_depth(a.path), path_depth(b.path)
		return x < y || x == y && a.path < b.path
	})
	root := Entry{inode = fstree.ROOT, kind = .Dir}
	body := rows
	if len(rows) > 0 && len(rows[0].path) == 0 {
		root = compact_entry(s, &n, rows[0].entry) or_return
		body = rows[1:]
	}
	create_files(&n, cap_for(u64(len(body)) + 1), root) or_return
	for r in body {
		shadow_append(&n, r.path, compact_entry(s, &n, r.entry) or_return) or_return
		if len(n.pending) >= 65536 {
			shadow_persist(&n) or_return
		}
	}
	shadow_persist(&n) or_return
	checkpoint(&n) or_return
	write_header(&n, true)
	from_prim(prim.datasync(s.vfs, n.idx_fd)) or_return
	ok = true
	if werr := write_gen(s, s.dir, ng); werr != .None {
		s.burned = max(s.burned, ng)
		shadow_detach(&n)
		return werr
	}
	old_gen := s.gen
	idx_unmap(s)
	prim.close_file(s.vfs, s.log_fd)
	prim.close_file(s.vfs, s.idx_fd)
	s.log_fd, s.idx_fd = n.log_fd, n.idx_fd
	s.cap, s.used, s.inode_used = n.cap, n.used, n.inode_used
	s.covered, s.log_end = n.covered, n.log_end
	s.live, s.garbage = n.live, n.garbage
	s.gen = ng
	s.mark = {ng, n.log_end}
	s.idx_lost = false
	s.damaged = false
	write_header(s, false)
	n.log_fd, n.idx_fd = prim.INVALID_FD, prim.INVALID_FD
	idx_unmap(&n)
	shadow_detach(&n)
	if old_gen != ng {
		prim.remove(s.vfs, gen_path(s.dir, old_gen, "log", context.temp_allocator))
		prim.remove(s.vfs, gen_path(s.dir, old_gen, "idx", context.temp_allocator))
	}
	return .None
}

@(private = "file")
key_live ::""")
open(p,'w').write(s)

p='src/fs/shadow.odin';s=open(p).read()
def one(a,b,n=1):
    global s
    assert s.count(a)==n,(s.count(a),a); s=s.replace(a,b)
one("	ver_ids:    [dynamic]fstree.Op_Id,\n}\n","	ver_ids:    [dynamic]fstree.Op_Id,\n	mark:       Shadow_Mark,\n	damaged:    bool,\n}\n")
one("allocator := context.allocator) -> Error {\n	s^ = {\n		vfs       = vfs,\n		allocator = allocator,\n		oid_size  = odb.oid_size(format),\n		log_fd    = prim.INVALID_FD,\n		idx_fd    = prim.INVALID_FD,\n	}","allocator := context.allocator, mark := Shadow_Mark{}) -> Error {\n	s^ = {\n		vfs       = vfs,\n		allocator = allocator,\n		oid_size  = odb.oid_size(format),\n		log_fd    = prim.INVALID_FD,\n		idx_fd    = prim.INVALID_FD,\n		mark      = mark,\n	}")
one("	s.gen = read_gen(s, dir)\n	if err := shadow_attach(s)","""	gen, have, gerr := read_gen(s, dir)
	if gerr == .Corrupt && mark.end != 0 {
		have, gerr = false, .None
	}
	if gerr != .None {
		shadow_close(s)
		return gerr
	}
	s.gen = gen if have else mark.gen
	s.damaged = mark.end != 0 && (!have || gen != mark.gen)
	if err := shadow_attach(s)""")
i=s.index("read_gen :: proc"); j=s.index("@(private = \"file\")\nwrite_gen ::")
s=s[:i]+"""read_gen :: proc(s: ^Shadow, dir: string) -> (gen: u64, have: bool, err: Error) {
	buf: prim.Path_Buf
	p, ok := path_join_buf(buf[:], dir, "shadow.gen")
	if !ok {
		return 0, false, .Name_Too_Long
	}
	fd, oerr := prim.open_file(s.vfs, p)
	if oerr == .Not_Found {
		return 0, false, .None
	}
	if oerr != .None {
		return 0, false, from_prim(oerr)
	}
	defer prim.close_file(s.vfs, fd)
	b: [16]u8
	n, rerr := prim.read_at(s.vfs, fd, b[:], 0)
	if rerr != .None {
		return 0, false, from_prim(rerr)
	}
	if n != 16 || u32(xxhash.XXH3_64_default(b[0:8])) != prim.get_u32le(b[8:12]) {
		return 0, false, .Corrupt
	}
	return prim.get_u64le(b[0:8]), true, .None
}

"""+s[j:]
one("""	if err == .Not_Found {
		prim.remove(s.vfs, idx_path)
		return create_files(s, SHADOW_MIN_CAP""","""	if err == .Not_Found {
		if s.mark.end != 0 {
			s.damaged = true
			return .None
		}
		prim.remove(s.vfs, idx_path)
		return create_files(s, SHADOW_MIN_CAP""")
one("""		prim.close_file(s.vfs, fd)
		prim.remove(s.vfs, idx_path)
		return create_files(""","""		prim.close_file(s.vfs, fd)
		if s.mark.end != 0 {
			s.damaged = true
			return .None
		}
		prim.remove(s.vfs, idx_path)
		return create_files(""")
one("""	s.log_end = u64(size)
	ifd, ierr := prim.open_file(s.vfs, idx_path, {.Write}, 0o600)
	if ierr == .None {
		s.idx_fd = ifd
		clean, valid := load_header(s)
		if valid {
			if rerr := recover_tail(s, clean); rerr != .None {
""","""	s.log_end = u64(size)
	if s.damaged || s.mark.end != 0 && s.gen == s.mark.gen && s.log_end < s.mark.end {
		s.damaged = true
		return .None
	}
	ifd, ierr := prim.open_file(s.vfs, idx_path, {.Write}, 0o600)
	if ierr == .None {
		s.idx_fd = ifd
		clean, valid := load_header(s)
		if valid {
			if rerr := recover_tail(s, clean); rerr != .None {
				if s.damaged {
					return .None
				}
""")
one("	return rebuild_index(s, SHADOW_MIN_CAP)\n}\n\n@(private = \"file\")\ncreate_files","""	if rerr := rebuild_index(s, SHADOW_MIN_CAP); rerr != .None {
		return .None if s.damaged else rerr
	}
	return from_prim(prim.datasync(s.vfs, s.log_fd))
}

@(private = "file")
create_files""")
one("""		if err == .Corrupt {
			break
		}
		if err != .None {
			return err
		}
		apply_rec(s, r) or_return
		off += r.size
	}
	if off < end {""","""		if err == .Corrupt {
			if off < s.mark.end {
				s.damaged = true
				return .Corrupt
			}
			break
		}
		if err != .None {
			return err
		}
		apply_rec(s, r) or_return
		off += r.size
	}
	if off > s.covered {
		from_prim(prim.datasync(s.vfs, s.log_fd)) or_return
	}
	if off < end {""")
one("""		if rerr == .Corrupt {
			break
		}
		if rerr != .None {
			return false, rerr
		}
		apply_rec""","""		if rerr == .Corrupt {
			if off < s.mark.end {
				s.damaged = true
				return false, .Corrupt
			}
			break
		}
		if rerr != .None {
			return false, rerr
		}
		apply_rec""")
for a in ("	r := read_rec(s, slot.off, &s.scratch) or_return\n	if r.del {\n		return {}, false, .None","			r := read_rec(s, slot.off, &s.scratch) or_return\n			cur: Path_Slot","		r := read_rec(s, off, &s.scratch) or_return\n		if !r.linked","				c := read_rec(s, cur.off, &s.scratch) or_return","		old := read_rec(s, slot.off, &s.scratch) or_return"):
    one(a,a.replace("read_rec(","read_live("))
one("		if !r.linked || len(r.path) == 0 || path_parent(r.path) != dir {\n			return .Corrupt","		if !r.linked || len(r.path) == 0 || path_parent(r.path) != dir {\n			s.damaged = true\n			return .Corrupt")
one("		if next >= off {\n			return .Corrupt","		if next >= off {\n			s.damaged = true\n			return .Corrupt")
one("				return i + k, {}, false, .Corrupt if bad else .None\n","				s.damaged ||= bad\n				return i + k, {}, false, .Corrupt if bad else .None\n")
one("@(private = \"file\")\ndecode_rec ::","""@(private = "file")
read_live :: proc(s: ^Shadow, off: u64, buf: ^[dynamic]u8) -> (r: Rec, err: Error) {
	r, err = read_rec(s, off, buf)
	s.damaged ||= err == .Corrupt
	return
}

@(private = "file")
decode_rec ::""")
one("	s.log_end = start + u64(len(s.out))\n	ierr: Error","	s.log_end = start + u64(len(s.out))\n	s.mark = {s.gen, s.log_end}\n	ierr: Error")
one("	if s.idx_fd >= 0 && !s.idx_lost && len(s.pending) == 0 && s.log_fd >= 0 {","	if s.idx_fd >= 0 && !s.idx_lost && !s.damaged && len(s.pending) == 0 && s.log_fd >= 0 {")
open(p,'w').write(s)

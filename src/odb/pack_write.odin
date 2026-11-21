package odb

import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:sync"

@(private)
Pack_Entry :: struct {
	oid:    Oid,
	offset: i64,
	crc:    u32,
}

Pack_Builder :: struct {
	db:       ^Odb,
	f:        ^os.File,
	path_buf: [PATH_MAX]u8,
	path:     string,
	w:        Buf_Writer,
	entries:  [dynamic]Pack_Entry,
	seen:     map[Oid]i32,
	active:   bool,
}

pack_begin :: proc(b: ^Pack_Builder, db: ^Odb) -> Error {
	if len(db.dirs) == 0 {
		return .Invalid
	}
	b^ = {}
	b.db = db
	dir_buf: [PATH_MAX]u8
	dir := concat_into(dir_buf[:], db.dirs[0].path, "/pack") or_return
	if e := os.make_directory(dir, os.perm_number(0o777)); e != nil && e != .Exist {
		return .Io
	} else if e == nil {
		track(db, "", db.dirs[0].path)
	}
	f, path := create_temp(dir, "tmp_pack_", b.path_buf[:]) or_return
	b.f = f
	b.path = path
	buf, aerr := make([]u8, IO_CHUNK, db.allocator)
	if aerr != nil {
		os.close(f)
		os.remove(path)
		return .Out_Of_Memory
	}
	b.w = Buf_Writer{f = f, buf = buf}
	b.entries = make([dynamic]Pack_Entry, db.allocator)
	b.seen = make(map[Oid]i32, db.allocator)
	b.active = true
	header := [12]u8{'P', 'A', 'C', 'K', 0, 0, 0, 2, 0, 0, 0, 0}
	bw_write(&b.w, header[:])
	return b.w.err
}

@(private)
pack_release :: proc(b: ^Pack_Builder) {
	delete(b.w.buf, b.db.allocator)
	delete(b.entries)
	delete(b.seen)
	b.w = {}
	b.active = false
}

pack_abort :: proc(b: ^Pack_Builder) {
	if !b.active {
		return
	}
	os.close(b.f)
	os.remove(b.path)
	pack_release(b)
}

pack_count :: proc(b: ^Pack_Builder) -> int {
	return len(b.entries)
}

pack_contains :: proc(b: ^Pack_Builder, oid: Oid) -> bool {
	return oid in b.seen
}

@(private)
pack_has :: proc(b: ^Pack_Builder, oid: Oid) -> bool {
	return oid in b.seen || exists_for_write(b.db, oid)
}

@(private)
pack_entry_head :: proc(buf: []u8, kind: u8, size: i64) -> []u8 {
	n := 0
	s := u64(size)
	c := kind << 4 | u8(s & 15)
	s >>= 4
	for s != 0 {
		buf[n] = c | 0x80
		n += 1
		c = u8(s & 0x7f)
		s >>= 7
	}
	buf[n] = c
	return buf[:n + 1]
}

@(private)
pack_record :: proc(b: ^Pack_Builder, oid: Oid, offset: i64) -> Error {
	if len(b.entries) >= 0x7fff_ffff {
		return .Too_Large
	}
	b.seen[oid] = i32(len(b.entries))
	append(&b.entries, Pack_Entry{oid, offset, b.w.crc})
	return .None
}

pack_add :: proc(b: ^Pack_Builder, type: Object_Type, data: []u8, mode := Hash_Mode.Fast) -> (oid: Oid, err: Error) {
	if !b.active || type == .None {
		return {}, .Invalid
	}
	oid = hash(b.db.format, type, data, mode) or_return
	if pack_has(b, oid) {
		return oid, .None
	}
	start := b.w.pos
	b.w.crc = 0
	hb: [16]u8
	bw_write(&b.w, pack_entry_head(hb[:], u8(type), i64(len(data))))
	z: Zstream
	z_begin(&b.w, &z, i64(len(data)))
	z_write(&b.w, &z, data) or_return
	z_end(&b.w, &z) or_return
	return oid, pack_record(b, oid, start)
}

pack_add_file :: proc(b: ^Pack_Builder, path: string) -> (oid: Oid, err: Error) {
	if !b.active {
		return {}, .Invalid
	}
	f, oerr := os.open(path)
	if oerr != nil {
		return {}, map_os_error(oerr)
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil {
		return {}, .Io
	}
	db := b.db
	if size >= db.two_pass_size {
		first := hash_file(path, db.format) or_return
		if pack_has(b, first) {
			return first, .None
		}
	}
	start := b.w.pos
	b.w.crc = 0
	h: Hasher
	hasher_init(&h, db.format)
	hasher_header(&h, .Blob, size)
	hb: [16]u8
	bw_write(&b.w, pack_entry_head(hb[:], u8(Object_Type.Blob), size))
	z: Zstream
	z_begin(&b.w, &z, size)
	rbuf: [IO_CHUNK]u8
	for err == .None {
		n, rerr := os.read(f, rbuf[:])
		if n > 0 {
			hasher_update(&h, rbuf[:n])
			err = z_write(&b.w, &z, rbuf[:n])
		}
		if rerr == .EOF || (rerr == nil && n == 0) {
			break
		}
		if rerr != nil {
			err = .Io
		}
	}
	if err == .None {
		err = z_end(&b.w, &z)
	}
	if err == .None {
		oid, err = hasher_final(&h)
	}
	if err == .None && pack_has(b, oid) {
		return oid, pack_rewind(b, start)
	}
	if err != .None {
		if b.w.err == .None {
			pack_rewind(b, start)
		}
		return {}, err
	}
	return oid, pack_record(b, oid, start)
}

@(private)
pack_rewind :: proc(b: ^Pack_Builder, offset: i64) -> Error {
	bw_flush(&b.w) or_return
	if os.truncate(b.f, offset) != nil {
		b.w.err = .Io
		return .Io
	}
	if _, e := os.seek(b.f, offset, .Start); e != nil {
		b.w.err = .Io
		return .Io
	}
	b.w.pos = offset
	return .None
}

pack_finish :: proc(b: ^Pack_Builder) -> (checksum: Oid, err: Error) {
	if !b.active {
		return {}, .Invalid
	}
	if len(b.entries) == 0 {
		pack_abort(b)
		return {}, .None
	}
	db := b.db
	defer if err != .None {
		pack_abort(b)
	}
	bw_flush(&b.w) or_return
	count: [4]u8
	endian.unchecked_put_u32be(count[:], u32(len(b.entries)))
	if _, e := os.write_at(b.f, count[:], 8); e != nil {
		return {}, .Io
	}
	h: Hasher
	hasher_init(&h, db.format)
	end := b.w.pos
	pos: i64
	for pos < end {
		n, e := os.read_at(b.f, b.w.buf[:min(i64(len(b.w.buf)), end - pos)], pos)
		if e != nil || n <= 0 {
			return {}, .Io
		}
		hasher_update(&h, b.w.buf[:n])
		pos += i64(n)
	}
	checksum = hasher_final(&h) or_return
	hsz := oid_size(db.format)
	if _, e := os.write_at(b.f, checksum[:hsz], end); e != nil {
		return {}, .Io
	}
	if db.sync_writes && os.sync(b.f) != nil {
		return {}, .Io
	}
	idx_buf: [PATH_MAX]u8
	idx_tmp := write_idx(db, b.entries[:], checksum, b.w.buf, idx_buf[:]) or_return
	final_err := install_pack(db, b.path, idx_tmp, checksum)
	os.close(b.f)
	b.f = nil
	if final_err != .None {
		os.remove(b.path)
		os.remove(idx_tmp)
		pack_release(b)
		return {}, final_err
	}
	pack_release(b)
	return checksum, .None
}

@(private)
write_idx :: proc(db: ^Odb, entries: []Pack_Entry, checksum: Oid, buf: []u8, path_buf: []u8) -> (path: string, err: Error) {
	slice.sort_by(entries, proc(a, b: Pack_Entry) -> bool {
		return oid_compare(a.oid, b.oid) < 0
	})
	dir_buf: [PATH_MAX]u8
	dir := concat_into(dir_buf[:], db.dirs[0].path, "/pack") or_return
	f, p := create_temp(dir, "tmp_idx_", path_buf) or_return
	hsz := oid_size(db.format)
	h: Hasher
	hasher_init(&h, db.format)
	w := Buf_Writer{f = f, buf = buf, sha = &h}
	tmp: [8]u8
	bw_write(&w, {0xff, 't', 'O', 'c', 0, 0, 0, 2})
	j := 0
	for i in 0 ..< 256 {
		for j < len(entries) && int(entries[j].oid[0]) <= i {
			j += 1
		}
		endian.unchecked_put_u32be(tmp[:], u32(j))
		bw_write(&w, tmp[:4])
	}
	for &e in entries {
		bw_write(&w, e.oid[:hsz])
	}
	for e in entries {
		endian.unchecked_put_u32be(tmp[:], e.crc)
		bw_write(&w, tmp[:4])
	}
	large := 0
	for e in entries {
		v := u32(e.offset)
		if e.offset > 0x7fff_ffff {
			v = 0x8000_0000 | u32(large)
			large += 1
		}
		endian.unchecked_put_u32be(tmp[:], v)
		bw_write(&w, tmp[:4])
	}
	for e in entries {
		if e.offset > 0x7fff_ffff {
			endian.unchecked_put_u64be(tmp[:], u64(e.offset))
			bw_write(&w, tmp[:8])
		}
	}
	checksum := checksum
	bw_write(&w, checksum[:hsz])
	w.sha = nil
	idx_sum, _ := hasher_final(&h)
	bw_write(&w, idx_sum[:hsz])
	err = bw_flush(&w)
	err = finish_temp(db, f, p, err)
	return p, err
}

@(private)
install_pack :: proc(db: ^Odb, pack_tmp, idx_tmp: string, checksum: Oid) -> Error {
	hb: [MAX_HEX]u8
	hex := oid_to_string(checksum, db.format, &hb)
	b1, b2: [PATH_MAX]u8
	pack_path := concat_into(b1[:], db.dirs[0].path, "/pack/pack-", hex, ".pack") or_return
	idx_path := concat_into(b2[:], db.dirs[0].path, "/pack/pack-", hex, ".idx") or_return
	if os.rename(pack_tmp, pack_path) != nil {
		return .Io
	}
	if os.rename(idx_tmp, idx_path) != nil {
		return .Io
	}
	if db.sync_writes {
		sync_dir(parent_dir(pack_path))
	}
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	track_locked(db, pack_path, parent_dir(pack_path))
	track_locked(db, idx_path)
	db.dirs[0].scanned = false
	return .None
}

@(private)
sync_dir :: proc(dir: string) {
	f, err := os.open(dir)
	if err != nil {
		return
	}
	os.sync(f)
	os.close(f)
}

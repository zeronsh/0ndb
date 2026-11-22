#+build linux, darwin, windows
package osync

import "base:runtime"
import "core:hash/xxhash"
import "../journal"
import "../prim"


Stream_File :: struct {
	fd:     prim.Fd,
	length: i64,
	base:   i64,
	seq:    u64,
	fresh:  bool,
	trimmed: bool,
	slotted: bool,
}

stream_file_open :: proc(vfs: prim.Vfs, path: string, create: bool, scratch: []u8, lay := LAYOUT_SECTOR) -> (f: Stream_File, err: Error) {
	f.fd = prim.INVALID_FD
	fd, oerr := prim.open_file(vfs, path, {.Write}, 0o600)
	if oerr == .Not_Found && create {
		fd, oerr = prim.open_file(vfs, path, {.Write, .Create, .Exclusive}, 0o600)
		if oerr == .None {
			f.fresh = true
		}
	}
	if oerr != .None {
		return f, _from_prim(oerr)
	}
	f.fd = fd
	if f.fresh {
		return f, .None
	}
	f.length, f.base, f.seq, f.trimmed, f.slotted, err = stream_file_recover(vfs, fd, scratch, lay)
	if err != .None {
		prim.close_file(vfs, fd)
		f.fd = prim.INVALID_FD
		return f, err
	}
	if size, serr := prim.file_size(vfs, fd); serr == .None && size > lay.base + f.length {
		if terr := prim.truncate(vfs, fd, lay.base + f.length); terr == .None {
			prim.datasync(vfs, fd)
		}
	}
	return f, .None
}

stream_file_recover :: proc(vfs: prim.Vfs, fd: prim.Fd, scratch: []u8, lay := LAYOUT_SECTOR) -> (length: i64, base: i64, seq: u64, trimmed: bool, slotted: bool, err: Error) {
	newest, older, count := slots_read(vfs, fd, lay.spacing) or_return
	if count == 0 {
		if !lay.exact {
			return 0, 0, 0, false, false, .None
		}
		size := _from_prim_size(prim.file_size(vfs, fd)) or_return
		return max(size - lay.base, 0), 0, 0, false, false, .None
	}
	ok := _chunk_verify(vfs, fd, newest, scratch, lay.base) or_return
	if ok {
		return newest.value, newest.base, newest.seq, newest.trimmed, true, .None
	}
	if count == 2 && older.seq + 1 == newest.seq {
		return older.value, older.base, older.seq, older.trimmed, true, .None
	}
	return 0, 0, 0, false, true, .None
}

@(private)
_from_prim_size :: proc(size: i64, err: prim.Error) -> (i64, Error) {
	return size, _from_prim(err)
}

stream_file_size :: proc(vfs: prim.Vfs, path: string, scratch: []u8, lay := LAYOUT_SECTOR) -> (length: i64, base: i64, exists: bool, err: Error) {
	fd, oerr := prim.open_file(vfs, path)
	if oerr == .Not_Found {
		return 0, 0, false, .None
	}
	if oerr != .None {
		return 0, 0, false, _from_prim(oerr)
	}
	defer prim.close_file(vfs, fd)
	length, base, _, _, _, err = stream_file_recover(vfs, fd, scratch, lay)
	return length, base, err == .None, err
}

@(private)
_chunk_verify :: proc(vfs: prim.Vfs, fd: prim.Fd, s: Slot, scratch: []u8, base: i64) -> (bool, Error) {
	end := slot_end(s)
	if end == s.start {
		return true, .None
	}
	state: xxhash.XXH64_state
	xxhash.XXH64_reset_state(&state, u64(s.start))
	pos := s.start
	for pos < end {
		n := int(min(i64(len(scratch)), end - pos))
		got, rerr := prim.read_at(vfs, fd, scratch[:n], base + pos)
		if rerr != .None {
			return false, _from_prim(rerr)
		}
		if got < n {
			return false, .None
		}
		xxhash.XXH64_update(&state, scratch[:n])
		pos += i64(n)
	}
	return xxhash.XXH64_digest(&state) == s.hash, .None
}

space_paths :: proc(vfs: prim.Vfs, root: string, id: Space_Id, allocator: runtime.Allocator) -> (dir: string, err: Error) {
	hex := prim.id_hex(id)
	d, perr := prim.path_join(allocator, root, "spaces", string(hex[:]))
	if perr != .None {
		return "", _from_prim(perr)
	}
	for sub in ([]string{"s", "o", "t"}) {
		p, jerr := prim.path_join(context.temp_allocator, d, sub)
		if jerr != .None {
			delete(d, allocator)
			return "", _from_prim(jerr)
		}
		if merr := prim.mkdir_all(vfs, p, 0o700); merr != .None {
			delete(d, allocator)
			return "", _from_prim(merr)
		}
	}
	return d, .None
}

stream_path :: proc(buf: ^prim.Path_Buf, space_dir: string, id: Stream_Id) -> string {
	n := copy(buf[:], space_dir)
	n += copy(buf[n:], "/s/")
	sid := id
	n += prim.hex_encode(buf[n:], sid[:])
	return string(buf[:n])
}

object_dir :: proc(buf: ^prim.Path_Buf, space_dir: string, key: Object_Key) -> string {
	n := copy(buf[:], space_dir)
	n += copy(buf[n:], "/o/")
	k := key
	n += prim.hex_encode(buf[n:], k[:1])
	return string(buf[:n])
}

object_path :: proc(buf: ^prim.Path_Buf, space_dir: string, key: Object_Key) -> string {
	n := len(object_dir(buf, space_dir, key))
	buf[n] = '/'
	n += 1
	k := key
	n += prim.hex_encode(buf[n:], k[1:])
	return string(buf[:n])
}

tmp_path :: proc(buf: ^prim.Path_Buf, space_dir: string, random: prim.Random) -> string {
	n := copy(buf[:], space_dir)
	n += copy(buf[n:], "/t/")
	r: [12]u8
	prim.random_fill(random, r[:])
	n += prim.hex_encode(buf[n:], r[:])
	return string(buf[:n])
}

parse_stream_name :: proc(name: string) -> (id: Stream_Id, ok: bool) {
	if len(name) != 64 {
		return
	}
	ok = prim.hex_decode(id[:], transmute([]u8)name)
	return
}

space_usage_scan :: proc(vfs: prim.Vfs, dir: string, allocator: runtime.Allocator, base: i64 = SLOTS_SIZE) -> (usage: i64, err: Error) {
	sdir, _ := prim.path_join(context.temp_allocator, dir, "s")
	usage += _dir_bytes(vfs, sdir, base, false, allocator)
	odir, _ := prim.path_join(context.temp_allocator, dir, "o")
	usage += _dir_bytes(vfs, odir, 0, true, allocator)
	tdir, _ := prim.path_join(context.temp_allocator, dir, "t")
	d: prim.Dir
	if prim.dir_open(vfs, &d, tdir, allocator) == .None {
		for {
			e, ok, derr := prim.dir_next(vfs, &d)
			if !ok || derr != .None {
				break
			}
			p, _ := prim.path_join(context.temp_allocator, tdir, e.name)
			prim.remove(vfs, p)
		}
		prim.dir_close(vfs, &d)
	}
	return usage, .None
}

@(private)
_dir_bytes :: proc(vfs: prim.Vfs, dir: string, base: i64, nested: bool, allocator: runtime.Allocator) -> (total: i64) {
	d: prim.Dir
	if prim.dir_open(vfs, &d, dir, allocator) != .None {
		return 0
	}
	defer prim.dir_close(vfs, &d)
	for {
		e, ok, derr := prim.dir_next(vfs, &d)
		if !ok || derr != .None {
			break
		}
		p, perr := prim.path_join(context.temp_allocator, dir, e.name)
		if perr != .None {
			continue
		}
		if nested {
			total += _dir_bytes(vfs, p, base, false, allocator)
			continue
		}
		st, serr := prim.stat(vfs, p)
		if serr == .None && st.size > base {
			total += st.size - base
		}
	}
	return
}

@(private)
_redact_records :: proc(vfs: prim.Vfs, fd: prim.Fd, from, to: i64, base: i64) -> Error {
	pos := from
	for pos < to {
		head: [4]u8
		if n, err := prim.read_at(vfs, fd, head[:], base + pos); err != .None || n != 4 {
			return .Corrupt
		}
		body := i64(prim.get_u32le(head[:]))
		size := body + journal.OVERHEAD
		if body > journal.MAX_BODY || pos + size > to {
			return .Invalid
		}
		trail: [4]u8
		if n, err := prim.read_at(vfs, fd, trail[:], base + pos + journal.HEADER + body); err != .None || n != 4 || prim.get_u32le(trail[:]) != u32(body) {
			return .Invalid
		}
		pos += size
	}
	pos = from
	for pos < to {
		head: [4]u8
		if n, err := prim.read_at(vfs, fd, head[:], base + pos); err != .None || n != 4 {
			return .Corrupt
		}
		body := i64(prim.get_u32le(head[:]))
		size := body + journal.OVERHEAD
		tag := journal.redacted_tag(pos, int(body))
		_from_prim(prim.write_at(vfs, fd, tag[:], base + pos + 4)) or_return
		_from_prim(prim.zero_range(vfs, fd, base + pos + journal.HEADER, body)) or_return
		pos += size
	}
	return .None
}

@(private)
_clear_tmp :: proc(vfs: prim.Vfs, tdir: string, allocator: runtime.Allocator) {
	d: prim.Dir
	if prim.dir_open(vfs, &d, tdir, allocator) != .None {
		return
	}
	defer prim.dir_close(vfs, &d)
	for {
		e, ok, derr := prim.dir_next(vfs, &d)
		if !ok || derr != .None {
			return
		}
		p, _ := prim.path_join(context.temp_allocator, tdir, e.name)
		prim.remove(vfs, p)
	}
}

Space_Authorizer :: struct {
	allow:         Allow,
	open:          bool,
	default_quota: i64,
	allocator:     runtime.Allocator,
}

space_authorizer_init :: proc(a: ^Space_Authorizer, vfs: prim.Vfs, allow_path: string, open: bool, default_quota: i64, allocator := context.allocator) -> Error {
	a^ = {
		open          = open,
		default_quota = default_quota,
		allocator     = allocator,
	}
	path := _clone_string(allow_path, allocator) or_return
	allow_init(&a.allow, vfs, path, allocator)
	return .None
}

space_authorizer_destroy :: proc(a: ^Space_Authorizer) {
	if len(a.allow.path) > 0 {
		delete(a.allow.path, a.allocator)
	}
	allow_destroy(&a.allow)
}

space_authorizer :: proc(a: ^Space_Authorizer) -> Authorizer {
	return Authorizer{data = a, authorize = _space_authorize}
}

@(private)
_space_authorize :: proc(data: rawptr, credential: []u8, binding: []u8, local: bool, p: ^Principal) -> Code {
	a := cast(^Space_Authorizer)data
	if len(credential) != SPACE_CREDENTIAL_LEN || credential[0] != 1 {
		return .Auth
	}
	space_pub: Public_Key
	part_pub: Public_Key
	copy(space_pub[:], credential[1:33])
	copy(part_pub[:], credential[33:65])
	if !local {
		if len(binding) == 0 || !hello_verify(space_pub, credential[65:129], binding) || !hello_verify(part_pub, credential[129:193], binding) {
			return .Auth
		}
	}
	id := space_id(space_pub)
	quota, allowed := allow_lookup(&a.allow, id)
	if !allowed {
		if !a.open {
			return .Auth
		}
		quota = a.default_quota
	}
	p^ = Principal {
		namespace   = id,
		participant = device_id(part_pub),
		quota       = quota,
		read_all    = true,
		append_own  = true,
		objects     = true,
	}
	return .None
}

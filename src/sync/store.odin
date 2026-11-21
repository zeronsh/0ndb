package osync

import "base:runtime"
import "core:hash/xxhash"
import "core:strconv"
import "core:strings"
import "../journal"
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

Stream_File :: struct {
	fd:     prim.Fd,
	length: i64,
	seq:    u64,
	fresh:  bool,
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
	f.length, f.seq, err = stream_file_recover(vfs, fd, scratch, lay)
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

stream_file_recover :: proc(vfs: prim.Vfs, fd: prim.Fd, scratch: []u8, lay := LAYOUT_SECTOR) -> (length: i64, seq: u64, err: Error) {
	newest, older, count := slots_read(vfs, fd, lay.spacing) or_return
	if count == 0 {
		return 0, 0, .None
	}
	ok := _chunk_verify(vfs, fd, newest, scratch, lay.base) or_return
	if ok {
		return newest.value, newest.seq, .None
	}
	if count == 2 && older.seq + 1 == newest.seq {
		return older.value, older.seq, .None
	}
	return 0, 0, .None
}

stream_file_size :: proc(vfs: prim.Vfs, path: string, scratch: []u8, lay := LAYOUT_SECTOR) -> (length: i64, exists: bool, err: Error) {
	fd, oerr := prim.open_file(vfs, path)
	if oerr == .Not_Found {
		return 0, false, .None
	}
	if oerr != .None {
		return 0, false, _from_prim(oerr)
	}
	defer prim.close_file(vfs, fd)
	length, _, err = stream_file_recover(vfs, fd, scratch, lay)
	return length, err == .None, err
}

@(private)
_chunk_verify :: proc(vfs: prim.Vfs, fd: prim.Fd, s: Slot, scratch: []u8, base: i64) -> (bool, Error) {
	if s.value == s.start {
		return true, .None
	}
	state: xxhash.XXH64_state
	xxhash.XXH64_reset_state(&state, u64(s.start))
	pos := s.start
	for pos < s.value {
		n := int(min(i64(len(scratch)), s.value - pos))
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

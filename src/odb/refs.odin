package odb

import "base:runtime"
import "../prim"
import "core:strings"

@(private)
REF_FILE_MAX :: 4096

ref_name_valid :: proc(name: string) -> bool {
	if name == "HEAD" {
		return true
	}
	if !strings.has_prefix(name, "refs/") || strings.has_suffix(name, "/") || strings.has_suffix(name, ".") {
		return false
	}
	if strings.contains(name, "..") || strings.contains(name, "@{") || strings.contains(name, "//") {
		return false
	}
	for c in transmute([]u8)name {
		switch c {
		case 0 ..< 0x20, 0x7f, ' ', '~', '^', ':', '?', '*', '[', '\\':
			return false
		}
	}
	rest := name
	for part in strings.split_iterator(&rest, "/") {
		if len(part) == 0 || part[0] == '.' || strings.has_suffix(part, ".lock") {
			return false
		}
	}
	return true
}

@(private)
ref_base_dir :: proc(db: ^Odb, name: string) -> string {
	if name == "HEAD" || !strings.has_prefix(name, "refs/") {
		return db.git_dir
	}
	if strings.has_prefix(name, "refs/worktree/") || strings.has_prefix(name, "refs/bisect/") || strings.has_prefix(name, "refs/rewritten/") {
		return db.git_dir
	}
	return db.common_dir
}

@(private)
read_small :: proc(vfs: prim.Vfs, path: string, buf: []u8) -> (text: string, err: Error) {
	fd, oerr := prim.open_file(vfs, path)
	if oerr != .None {
		return "", perr(oerr)
	}
	defer prim.close_file(vfs, fd)
	n, rerr := prim.read_at(vfs, fd, buf, 0)
	if rerr != .None {
		return "", perr(rerr)
	}
	if n == len(buf) {
		return "", .Too_Large
	}
	return string(buf[:n]), .None
}

@(private)
Ref_Value :: struct {
	oid:      Oid,
	symbolic: bool,
	target:   [REF_FILE_MAX]u8,
	tlen:     int,
	found:    bool,
	packed:   bool,
}

@(private)
read_loose_ref :: proc(db: ^Odb, name: string, v: ^Ref_Value) -> Error {
	if !ref_name_valid(name) {
		return .Invalid
	}
	pb: [PATH_MAX]u8
	path := concat_into(pb[:], ref_base_dir(db, name), "/", name) or_return
	if prim.is_dir(db.vfs, path) {
		return .None
	}
	buf: [REF_FILE_MAX]u8
	text, err := read_small(db.vfs, path, buf[:])
	if err == .Not_Found {
		return .None
	}
	if err != .None {
		return err
	}
	t := strings.trim_space(text)
	if strings.has_prefix(t, "ref:") {
		target := strings.trim_space(t[4:])
		v.symbolic = true
		v.tlen = copy(v.target[:], target)
		v.found = true
		return .None
	}
	oid, format, ok := oid_from_hex(t)
	if !ok || format != db.format {
		return .Corrupt
	}
	v.oid = oid
	v.found = true
	return .None
}

@(private)
read_packed_ref :: proc(db: ^Odb, name: string, v: ^Ref_Value) -> Error {
	pb: [PATH_MAX]u8
	path := concat_into(pb[:], db.common_dir, "/packed-refs") or_return
	data, rerr := vfs_read_file(db.vfs, path, db.allocator)
	if rerr == .Not_Found {
		return .None
	}
	rerr or_return
	defer delete(data, db.allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 || line[0] == '#' || line[0] == '^' {
			continue
		}
		sp := strings.index_byte(line, ' ')
		if sp < 0 || line[sp + 1:] != name {
			continue
		}
		oid, format, ok := oid_from_hex(line[:sp])
		if !ok || format != db.format {
			return .Corrupt
		}
		v.oid = oid
		v.found = true
		v.packed = true
		return .None
	}
	return .None
}

@(private)
read_ref_raw :: proc(db: ^Odb, name: string, v: ^Ref_Value) -> Error {
	read_loose_ref(db, name, v) or_return
	if v.found || ref_base_dir(db, name) != db.common_dir {
		return .None
	}
	return read_packed_ref(db, name, v)
}

read_ref :: proc(db: ^Odb, name: string) -> (oid: Oid, err: Error) {
	v: Ref_Value
	read_ref_raw(db, name, &v) or_return
	if !v.found {
		return {}, .Not_Found
	}
	if !v.symbolic {
		return v.oid, .None
	}
	target := string(v.target[:v.tlen])
	t: Ref_Value
	read_ref_raw(db, target, &t) or_return
	if !t.found || t.symbolic {
		return {}, .Not_Found
	}
	return t.oid, .None
}

read_symref :: proc(db: ^Odb, name: string, allocator := context.allocator) -> (target: string, err: Error) {
	v: Ref_Value
	read_ref_raw(db, name, &v) or_return
	if !v.found || !v.symbolic {
		return "", .Not_Found
	}
	s, aerr := strings.clone(string(v.target[:v.tlen]), allocator)
	if aerr != nil {
		return "", .Out_Of_Memory
	}
	return s, .None
}

read_head :: proc(db: ^Odb, allocator := context.allocator) -> (branch: string, oid: Oid, err: Error) {
	v: Ref_Value
	read_ref_raw(db, "HEAD", &v) or_return
	if !v.found {
		return "", {}, .Not_Found
	}
	if !v.symbolic {
		return "", v.oid, .None
	}
	target := string(v.target[:v.tlen])
	t: Ref_Value
	read_ref_raw(db, target, &t) or_return
	b, aerr := strings.clone(target, allocator)
	if aerr != nil {
		return "", {}, .Out_Of_Memory
	}
	if t.found && !t.symbolic {
		oid = t.oid
	}
	return b, oid, .None
}

@(private)
Ref_Lock :: struct {
	fd:          prim.Fd,
	held:        bool,
	marked:      bool,
	path_buf:    [PATH_MAX]u8,
	lock_buf:    [PATH_MAX]u8,
	marker_buf:  [PATH_MAX]u8,
	path:        string,
	lock_path:   string,
	marker_path: string,
	base:        string,
	created:     bool,
}

Lock_Owner :: struct {
	boot:     prim.Id,
	pid:      i64,
	instance: prim.Id,
}

Lock_Liveness :: struct {
	data:  rawptr,
	alive: proc(data: rawptr, owner: Lock_Owner) -> bool,
}

set_lock_owner :: proc(db: ^Odb, owner: Lock_Owner, live: Lock_Liveness) {
	db.lock_owner = owner
	db.lock_live = live
	db.lock_marked = true
}

@(private)
MARKER_MAGIC :: "0ndblck1"

@(private)
MARKER_SIZE :: len(MARKER_MAGIC) + 16 + 8 + 16 + 1 + MAX_HEX + 1

@(private)
Lock_Marker :: struct {
	owner: Lock_Owner,
	value: [MAX_HEX + 1]u8,
	vlen:  int,
}

@(private)
marker_write :: proc(db: ^Odb, l: ^Ref_Lock, mk: Lock_Marker, sync_parent: bool) -> Error {
	buf: [MARKER_SIZE]u8
	copy(buf[:], MARKER_MAGIC)
	at := len(MARKER_MAGIC)
	b := mk.owner.boot
	copy(buf[at:], b[:])
	at += 16
	prim.put_u64le(buf[at:], u64(mk.owner.pid))
	at += 8
	ins := mk.owner.instance
	copy(buf[at:], ins[:])
	at += 16
	buf[at] = u8(mk.vlen)
	at += 1
	v := mk.value
	copy(buf[at:], v[:mk.vlen])
	fd, err := prim.open_file(db.vfs, l.marker_path, {.Write, .Create, .Truncate}, 0o644)
	if err != .None {
		return perr(err)
	}
	werr := prim.write_at(db.vfs, fd, buf[:], 0)
	if werr == .None {
		werr = prim.datasync(db.vfs, fd)
	}
	prim.close_file(db.vfs, fd)
	if werr != .None {
		return perr(werr)
	}
	if sync_parent {
		return perr(prim.sync_dir(db.vfs, parent_dir(l.marker_path)))
	}
	return .None
}

@(private)
marker_read :: proc(db: ^Odb, l: ^Ref_Lock) -> (mk: Lock_Marker, ok: bool) {
	buf: [MARKER_SIZE + 1]u8
	fd, err := prim.open_file(db.vfs, l.marker_path)
	if err != .None {
		return
	}
	n, rerr := prim.read_at(db.vfs, fd, buf[:], 0)
	prim.close_file(db.vfs, fd)
	if rerr != .None || n != MARKER_SIZE || string(buf[:len(MARKER_MAGIC)]) != MARKER_MAGIC {
		return
	}
	at := len(MARKER_MAGIC)
	copy(mk.owner.boot[:], buf[at:at + 16])
	at += 16
	mk.owner.pid = i64(prim.get_u64le(buf[at:]))
	at += 8
	copy(mk.owner.instance[:], buf[at:at + 16])
	at += 16
	mk.vlen = int(buf[at])
	at += 1
	if mk.vlen > len(mk.value) {
		return
	}
	copy(mk.value[:], buf[at:at + mk.vlen])
	return mk, true
}

@(private)
lock_stale :: proc(db: ^Odb, l: ^Ref_Lock) -> bool {
	mk, ok := marker_read(db, l)
	if !ok {
		return false
	}
	content: [MAX_HEX + 2]u8
	fd, oerr := prim.open_file(db.vfs, l.lock_path)
	if oerr != .None {
		return false
	}
	n, rerr := prim.read_at(db.vfs, fd, content[:], 0)
	prim.close_file(db.vfs, fd)
	if rerr != .None || (n != 0 && string(content[:n]) != string(mk.value[:mk.vlen])) {
		return false
	}
	if mk.owner.boot != db.lock_owner.boot {
		return true
	}
	if db.lock_live.alive == nil {
		return false
	}
	return !db.lock_live.alive(db.lock_live.data, mk.owner)
}

@(private)
ref_lock :: proc(db: ^Odb, name: string, l: ^Ref_Lock, value: []u8 = nil) -> Error {
	if !ref_name_valid(name) {
		return .Invalid
	}
	base := ref_base_dir(db, name)
	l.path = concat_into(l.path_buf[:], base, "/", name) or_return
	l.lock_path = concat_into(l.lock_buf[:], l.path, ".lock") or_return
	parent := parent_dir(l.path)
	l.created = !prim.is_dir(db.vfs, parent)
	l.base = base
	if e := prim.mkdir_all(db.vfs, parent); e != .None {
		return perr(e)
	}
	if db.lock_marked {
		l.marker_path = concat_into(l.marker_buf[:], l.lock_path, ".0ndb") or_return
		if _, serr := prim.lstat(db.vfs, l.lock_path); serr == .None {
			if !lock_stale(db, l) {
				return .Locked
			}
			prim.remove(db.vfs, l.lock_path)
			prim.remove(db.vfs, l.marker_path)
			perr(prim.sync_dir(db.vfs, parent)) or_return
		}
		if len(value) > MAX_HEX + 1 {
			return .Invalid
		}
		intent := Lock_Marker{owner = db.lock_owner, vlen = len(value)}
		copy(intent.value[:], value)
		marker_write(db, l, intent, true) or_return
	}
	fd, err := prim.open_file(db.vfs, l.lock_path, {.Write, .Create, .Exclusive}, 0o644)
	if err != .None {
		if db.lock_marked {
			prim.remove(db.vfs, l.marker_path)
		}
		return .Locked if err == .Exists else perr(err)
	}
	l.fd = fd
	l.held = true
	l.marked = db.lock_marked
	if len(value) > 0 {
		perr(prim.write_at(db.vfs, fd, value, 0)) or_return
	}
	return .None
}

@(private)
ref_unlock :: proc(db: ^Odb, l: ^Ref_Lock) {
	if l.held {
		prim.close_file(db.vfs, l.fd)
		l.held = false
		prim.remove(db.vfs, l.lock_path)
	}
	if l.marked {
		l.marked = false
		prim.remove(db.vfs, l.marker_path)
	}
}



@(private)
ref_check_expected :: proc(db: ^Odb, name: string, expected: Maybe(Oid)) -> (current: Ref_Value, err: Error) {
	read_ref_raw(db, name, &current) or_return
	if current.symbolic {
		return current, .Invalid
	}
	if want, ok := expected.?; ok {
		if want == ZERO_OID {
			if current.found {
				return current, .Stale
			}
		} else if !current.found || current.oid != want {
			return current, .Stale
		}
	}
	return current, .None
}

update_ref :: proc(db: ^Odb, name: string, new: Oid, expected: Maybe(Oid) = nil) -> Error {
	if new == ZERO_OID {
		return .Invalid
	}
	hb: [MAX_HEX + 1]u8
	hex_buf: [MAX_HEX]u8
	hex := oid_to_string(new, db.format, &hex_buf)
	n := copy(hb[:], hex)
	hb[n] = '\n'
	l: Ref_Lock
	ref_lock(db, name, &l, hb[:n + 1]) or_return
	defer ref_unlock(db, &l)
	ref_check_expected(db, name, expected) or_return
	if db.sync_writes {
		perr(prim.datasync(db.vfs, l.fd)) or_return
	}
	prim.close_file(db.vfs, l.fd)
	l.held = false
	if e := prim.rename(db.vfs, l.lock_path, l.path); e != .None {
		prim.remove(db.vfs, l.lock_path)
		return perr(e)
	}
	track_tree(db, l.path, l.base, l.created)
	return .None
}

delete_ref :: proc(db: ^Odb, name: string, expected: Maybe(Oid) = nil) -> Error {
	l: Ref_Lock
	ref_lock(db, name, &l) or_return
	defer ref_unlock(db, &l)
	current := ref_check_expected(db, name, expected) or_return
	if !current.found {
		return .Not_Found
	}
	if ref_base_dir(db, name) == db.common_dir {
		remove_packed_ref(db, name) or_return
	}
	if e := prim.remove(db.vfs, l.path); e != .None && e != .Not_Found {
		return perr(e)
	}
	track(db, "", parent_dir(l.path))
	return .None
}

@(private)
remove_packed_ref :: proc(db: ^Odb, name: string) -> Error {
	pb, lb: [PATH_MAX]u8
	path := concat_into(pb[:], db.common_dir, "/packed-refs") or_return
	data, rerr := vfs_read_file(db.vfs, path, db.allocator)
	if rerr == .Not_Found {
		return .None
	}
	rerr or_return
	defer delete(data, db.allocator)
	if !packed_refs_has(string(data), name) {
		return .None
	}
	lock_path := concat_into(lb[:], path, ".lock") or_return
	fd, err := prim.open_file(db.vfs, lock_path, {.Write, .Create, .Exclusive}, 0o644)
	if err != .None {
		return .Locked if err == .Exists else perr(err)
	}
	fresh, ferr := vfs_read_file(db.vfs, path, db.allocator)
	if ferr != .None {
		prim.close_file(db.vfs, fd)
		prim.remove(db.vfs, lock_path)
		return ferr
	}
	defer delete(fresh, db.allocator)
	out := rewrite_packed_refs(string(fresh), name, db.allocator)
	defer delete(out, db.allocator)
	werr := prim.write_at(db.vfs, fd, transmute([]u8)out, 0)
	if werr == .None && db.sync_writes {
		werr = prim.datasync(db.vfs, fd)
	}
	prim.close_file(db.vfs, fd)
	if werr == .None {
		werr = prim.rename(db.vfs, lock_path, path)
	}
	if werr != .None {
		prim.remove(db.vfs, lock_path)
		return perr(werr)
	}
	track(db, path, db.common_dir)
	return .None
}

@(private)
packed_refs_has :: proc(text: string, name: string) -> bool {
	t := text
	for line in strings.split_lines_iterator(&t) {
		sp := strings.index_byte(line, ' ')
		if len(line) > 0 && line[0] != '#' && line[0] != '^' && sp >= 0 && line[sp + 1:] == name {
			return true
		}
	}
	return false
}

@(private)
rewrite_packed_refs :: proc(text: string, name: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make_len_cap(0, len(text), allocator)
	t := text
	skipping := false
	for line in strings.split_lines_iterator(&t) {
		if len(line) > 0 && line[0] == '^' {
			if !skipping {
				strings.write_string(&b, line)
				strings.write_byte(&b, '\n')
			}
			continue
		}
		sp := strings.index_byte(line, ' ')
		skipping = len(line) > 0 && line[0] != '#' && sp >= 0 && line[sp + 1:] == name
		if !skipping {
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

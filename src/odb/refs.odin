package odb

import "base:runtime"
import "core:os"
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
read_small :: proc(path: string, buf: []u8) -> (text: string, err: Error) {
	f, oerr := os.open(path)
	if oerr != nil {
		return "", map_os_error(oerr)
	}
	defer os.close(f)
	n, rerr := os.read_full(f, buf)
	if rerr != nil && rerr != .EOF && rerr != .Unexpected_EOF {
		return "", .Io
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
	if os.is_directory(path) {
		return .None
	}
	buf: [REF_FILE_MAX]u8
	text, err := read_small(path, buf[:])
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
	data, rerr := os.read_entire_file_from_path(path, db.allocator)
	if rerr != nil {
		return .None
	}
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
	f:         ^os.File,
	path_buf:  [PATH_MAX]u8,
	lock_buf:  [PATH_MAX]u8,
	path:      string,
	lock_path: string,
	base:      string,
	created:   bool,
}

@(private)
ref_lock :: proc(db: ^Odb, name: string, l: ^Ref_Lock) -> Error {
	if !ref_name_valid(name) {
		return .Invalid
	}
	base := ref_base_dir(db, name)
	l.path = concat_into(l.path_buf[:], base, "/", name) or_return
	l.lock_path = concat_into(l.lock_buf[:], l.path, ".lock") or_return
	parent := parent_dir(l.path)
	l.created = !os.is_directory(parent)
	l.base = base
	if e := os.make_directory_all(parent); e != nil && e != .Exist {
		return .Io
	}
	f, err := os.open(l.lock_path, {.Write, .Create, .Excl}, os.perm_number(0o644))
	if err != nil {
		return .Locked if err == .Exist else map_os_error(err)
	}
	l.f = f
	return .None
}

@(private)
ref_unlock :: proc(l: ^Ref_Lock) {
	if l.f != nil {
		os.close(l.f)
		l.f = nil
		os.remove(l.lock_path)
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
	l: Ref_Lock
	ref_lock(db, name, &l) or_return
	defer ref_unlock(&l)
	ref_check_expected(db, name, expected) or_return
	hb: [MAX_HEX + 1]u8
	hex_buf: [MAX_HEX]u8
	hex := oid_to_string(new, db.format, &hex_buf)
	n := copy(hb[:], hex)
	hb[n] = '\n'
	if _, err := os.write(l.f, hb[:n + 1]); err != nil {
		return .Io
	}
	if db.sync_writes && os.sync(l.f) != nil {
		return .Io
	}
	os.close(l.f)
	l.f = nil
	if os.rename(l.lock_path, l.path) != nil {
		os.remove(l.lock_path)
		return .Io
	}
	track_tree(db, l.path, l.base, l.created)
	return .None
}

delete_ref :: proc(db: ^Odb, name: string, expected: Maybe(Oid) = nil) -> Error {
	l: Ref_Lock
	ref_lock(db, name, &l) or_return
	defer ref_unlock(&l)
	current := ref_check_expected(db, name, expected) or_return
	if !current.found {
		return .Not_Found
	}
	if ref_base_dir(db, name) == db.common_dir {
		remove_packed_ref(db, name) or_return
	}
	if e := os.remove(l.path); e != nil && e != .Not_Exist {
		return .Io
	}
	track(db, "", parent_dir(l.path))
	return .None
}

@(private)
remove_packed_ref :: proc(db: ^Odb, name: string) -> Error {
	pb, lb: [PATH_MAX]u8
	path := concat_into(pb[:], db.common_dir, "/packed-refs") or_return
	data, rerr := os.read_entire_file_from_path(path, db.allocator)
	if rerr != nil {
		return .None
	}
	defer delete(data, db.allocator)
	if !packed_refs_has(string(data), name) {
		return .None
	}
	lock_path := concat_into(lb[:], path, ".lock") or_return
	f, err := os.open(lock_path, {.Write, .Create, .Excl}, os.perm_number(0o644))
	if err != nil {
		return .Locked if err == .Exist else map_os_error(err)
	}
	fresh, ferr := os.read_entire_file_from_path(path, db.allocator)
	if ferr != nil {
		os.close(f)
		os.remove(lock_path)
		return .Io
	}
	defer delete(fresh, db.allocator)
	out := rewrite_packed_refs(string(fresh), name, db.allocator)
	defer delete(out, db.allocator)
	_, werr := os.write(f, transmute([]u8)out)
	serr: os.Error
	if werr == nil && db.sync_writes {
		serr = os.sync(f)
	}
	os.close(f)
	if werr != nil || serr != nil || os.rename(lock_path, path) != nil {
		os.remove(lock_path)
		return .Io
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

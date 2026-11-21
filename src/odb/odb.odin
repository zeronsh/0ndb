package odb

import "base:runtime"
import "core:io"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

DEFAULT_CACHE_LIMIT :: 8 * 1024 * 1024
DEFAULT_DELTA_LIMIT :: 256 * 1024 * 1024
DEFAULT_TWO_PASS_SIZE :: 1024 * 1024

@(private)
CACHE_SLOTS :: 32

@(private)
PATH_MAX :: 4096

@(private)
MAP_THRESHOLD :: 1024 * 1024

@(private)
IO_CHUNK :: 64 * 1024

@(private)
Object_Dir :: struct {
	path:       string,
	packs:      [dynamic]^Pack,
	scanned:    bool,
	pack_mtime: i64,
	extra:      bool,
}

@(private)
Cache_Entry :: struct {
	pack:   u32,
	offset: i64,
	type:   Object_Type,
	data:   []u8,
	tick:   u64,
}

Odb :: struct {
	allocator:      runtime.Allocator,
	format:         Hash_Format,
	dirs:           [dynamic]Object_Dir,
	git_dir:        string,
	common_dir:     string,
	cache_limit:    int,
	delta_limit:    i64,
	two_pass_size:  i64,
	sync_writes:    bool,
	store:          bool,
	pending_files:  [dynamic]string,
	pending_dirs:   [dynamic]string,
	cache:          [CACHE_SLOTS]Cache_Entry,
	cache_bytes:    int,
	tick:           u64,
	next_pack:      u32,
	mutex:          sync.Mutex,
}

@(private)
Location :: struct {
	pack:   ^Pack,
	offset: i64,
	dir:    int,
	loose:  bool,
	found:  bool,
}

@(private)
init :: proc(db: ^Odb, allocator: runtime.Allocator) {
	db^ = {}
	db.allocator = allocator
	db.dirs = make([dynamic]Object_Dir, allocator)
	db.pending_files = make([dynamic]string, allocator)
	db.pending_dirs = make([dynamic]string, allocator)
	db.cache_limit = DEFAULT_CACHE_LIMIT
	db.delta_limit = DEFAULT_DELTA_LIMIT
	db.two_pass_size = DEFAULT_TWO_PASS_SIZE
}

open :: proc(db: ^Odb, worktree: string, extra_dirs: []string = nil, allocator := context.allocator) -> Error {
	init(db, allocator)
	git_dir, common_dir, err := discover(worktree, allocator)
	if err != .None {
		close(db)
		return err
	}
	db.git_dir = git_dir
	db.common_dir = common_dir
	format, ferr := read_object_format(common_dir, allocator)
	if ferr != .None {
		close(db)
		return ferr
	}
	db.format = format
	objects, jerr := join2(common_dir, "/objects", allocator)
	if jerr != .None {
		close(db)
		return jerr
	}
	if !os.is_directory(objects) {
		delete(objects, allocator)
		close(db)
		return .Not_Repository
	}
	add_dir(db, objects, false, 0)
	for d in extra_dirs {
		if e := add_object_dir(db, d); e != .None {
			close(db)
			return e
		}
	}
	return .None
}

open_store :: proc(db: ^Odb, dir: string, extra_dirs: []string = nil, format := Hash_Format.Sha1, allocator := context.allocator) -> Error {
	init(db, allocator)
	db.store = true
	err := init_store(db, dir, format)
	if err == .None {
		for d in extra_dirs {
			if err = add_object_dir(db, d); err != .None {
				break
			}
		}
	}
	if err != .None {
		close(db)
	}
	return err
}

@(private)
init_store :: proc(db: ^Odb, dir: string, format: Hash_Format) -> Error {
	a := db.allocator
	root := clean(dir, a) or_return
	db.git_dir = root
	common, cerr := strings.clone(root, a)
	if cerr != nil {
		return .Out_Of_Memory
	}
	db.common_dir = common
	for sub in ([]string{"", "/objects", "/objects/pack", "/objects/info", "/refs", "/refs/heads", "/refs/tags"}) {
		p := join2(root, sub, a) or_return
		e := os.make_directory_all(p)
		delete(p, a)
		if e != nil && e != .Exist {
			return .Io
		}
	}
	head := join2(root, "/HEAD", a) or_return
	defer delete(head, a)
	if !os.exists(head) {
		write_atomic(head, transmute([]u8)string("ref: refs/heads/main\n"), db.sync_writes) or_return
		track(db, head, root, parent_dir(root))
	}
	config := join2(root, "/config", a) or_return
	defer delete(config, a)
	if !os.exists(config) {
		text := "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n"
		if format == .Sha256 {
			text = "[core]\n\trepositoryformatversion = 1\n\tfilemode = true\n\tbare = true\n[extensions]\n\tobjectformat = sha256\n"
		}
		write_atomic(config, transmute([]u8)text, db.sync_writes) or_return
		track(db, config, root)
	}
	db.format = read_object_format(root, a) or_return
	objects := join2(root, "/objects", a) or_return
	add_dir(db, objects, false, 0)
	return .None
}

add_object_dir :: proc(db: ^Odb, path: string) -> Error {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	p := clean(path, db.allocator) or_return
	if !os.is_directory(p) {
		delete(p, db.allocator)
		return .Not_Found
	}
	if f, known := detect_dir_format(p, db.allocator); known && f != db.format {
		delete(p, db.allocator)
		return .Invalid
	}
	add_dir(db, p, true, 0)
	return .None
}

@(private)
detect_dir_format :: proc(objects: string, allocator: runtime.Allocator) -> (format: Hash_Format, known: bool) {
	parent := parent_dir(objects)
	buf: [PATH_MAX]u8
	if config, err := concat_into(buf[:], parent, "/config"); err == .None && os.exists(config) {
		f, ferr := read_object_format(parent, allocator)
		if ferr != .None {
			return .Sha1, true
		}
		return f, true
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	for i in 0 ..< 256 {
		fan := [2]u8{HEX_DIGITS[i >> 4], HEX_DIGITS[i & 15]}
		dir := concat_into(buf[:], objects, "/", string(fan[:])) or_continue
		entries, rerr := os.read_all_directory_by_path(dir, context.temp_allocator)
		if rerr != nil {
			continue
		}
		for e in entries {
			switch len(e.name) {
			case 38:
				return .Sha1, true
			case 62:
				return .Sha256, true
			}
		}
	}
	return .Sha1, false
}

close :: proc(db: ^Odb) {
	a := db.allocator
	cache_clear(db)
	for &d in db.dirs {
		for p in d.packs {
			pack_free(db, p)
		}
		delete(d.packs)
		delete(d.path, a)
	}
	delete(db.dirs)
	pending_clear(db)
	delete(db.git_dir, a)
	delete(db.common_dir, a)
	db.dirs = nil
	db.git_dir = ""
	db.common_dir = ""
}

trim :: proc(db: ^Odb) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	cache_clear(db)
	for &d in db.dirs {
		for p in d.packs {
			pack_free(db, p)
		}
		clear(&d.packs)
		d.scanned = false
		d.pack_mtime = 0
	}
}

primary_dir :: proc(db: ^Odb) -> string {
	return db.dirs[0].path if len(db.dirs) > 0 else ""
}

@(private)
pack_free :: proc(db: ^Odb, p: ^Pack) {
	pack_close(p)
	delete(p.base, db.allocator)
	free(p, db.allocator)
}

@(private)
add_dir :: proc(db: ^Odb, path: string, extra: bool, depth: int) {
	for d in db.dirs {
		if d.path == path {
			delete(path, db.allocator)
			return
		}
	}
	append(&db.dirs, Object_Dir{path = path, packs = make([dynamic]^Pack, db.allocator), extra = extra})
	if depth >= 5 {
		return
	}
	alt_path, jerr := join2(path, "/info/alternates", db.allocator)
	if jerr != .None {
		return
	}
	defer delete(alt_path, db.allocator)
	text, rerr := os.read_entire_file_from_path(alt_path, db.allocator)
	if rerr != nil {
		return
	}
	defer delete(text, db.allocator)
	s := string(text)
	for line in strings.split_lines_iterator(&s) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' {
			continue
		}
		target: string
		cerr: Error
		if l[0] == '/' {
			target, cerr = clean(l, db.allocator)
		} else {
			joined := join3(path, "/", l, db.allocator) or_continue
			target, cerr = clean(joined, db.allocator)
			delete(joined, db.allocator)
		}
		if cerr != .None {
			continue
		}
		if !os.is_directory(target) {
			delete(target, db.allocator)
			continue
		}
		add_dir(db, target, extra, depth + 1)
	}
}

@(private)
discover :: proc(worktree: string, allocator: runtime.Allocator) -> (git_dir, common_dir: string, err: Error) {
	start := clean(worktree, allocator) or_return
	defer delete(start, allocator)
	dir := start
	for {
		if gd, ok := git_dir_at(dir, allocator); ok {
			git_dir = gd
			break
		}
		if is_git_dir(dir) {
			git_dir = strings.clone(dir, allocator) or_else ""
			if git_dir == "" {
				return "", "", .Out_Of_Memory
			}
			break
		}
		parent := parent_dir(dir)
		if parent == dir {
			return "", "", .Not_Repository
		}
		dir = parent
	}
	common_dir, err = resolve_common_dir(git_dir, allocator)
	if err != .None {
		delete(git_dir, allocator)
		return "", "", err
	}
	return
}

@(private)
git_dir_at :: proc(dir: string, allocator: runtime.Allocator) -> (string, bool) {
	dot := join2(dir, "/.git", allocator) or_else ""
	if dot == "" {
		return "", false
	}
	if os.is_directory(dot) {
		if is_git_dir(dot) {
			return dot, true
		}
		delete(dot, allocator)
		return "", false
	}
	defer delete(dot, allocator)
	text, rerr := os.read_entire_file_from_path(dot, allocator)
	if rerr != nil {
		return "", false
	}
	defer delete(text, allocator)
	s := strings.trim_space(string(text))
	if !strings.has_prefix(s, "gitdir:") {
		return "", false
	}
	target := strings.trim_space(s[len("gitdir:"):])
	if len(target) == 0 {
		return "", false
	}
	resolved: string
	cerr: Error
	if target[0] == '/' {
		resolved, cerr = clean(target, allocator)
	} else {
		joined := join3(dir, "/", target, allocator) or_else ""
		if joined == "" {
			return "", false
		}
		resolved, cerr = clean(joined, allocator)
		delete(joined, allocator)
	}
	if cerr != .None {
		return "", false
	}
	if !is_git_dir(resolved) {
		delete(resolved, allocator)
		return "", false
	}
	return resolved, true
}

@(private)
is_git_dir :: proc(dir: string) -> bool {
	buf: [PATH_MAX]u8
	head := concat_into(buf[:], dir, "/HEAD") or_else ""
	if head == "" || !os.exists(head) {
		return false
	}
	common := concat_into(buf[:], dir, "/commondir") or_else ""
	if common != "" && os.exists(common) {
		return true
	}
	objects := concat_into(buf[:], dir, "/objects") or_else ""
	return objects != "" && os.is_directory(objects)
}

@(private)
resolve_common_dir :: proc(git_dir: string, allocator: runtime.Allocator) -> (dir: string, err: Error) {
	path := join2(git_dir, "/commondir", allocator) or_return
	defer delete(path, allocator)
	text, rerr := os.read_entire_file_from_path(path, allocator)
	if rerr != nil {
		return clean(git_dir, allocator)
	}
	defer delete(text, allocator)
	target := strings.trim_space(string(text))
	if len(target) == 0 {
		return clean(git_dir, allocator)
	}
	if target[0] == '/' {
		return clean(target, allocator)
	}
	joined := join3(git_dir, "/", target, allocator) or_return
	defer delete(joined, allocator)
	return clean(joined, allocator)
}

@(private)
parent_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	if i <= 0 {
		return "/" if len(path) > 0 && path[0] == '/' else path
	}
	return path[:i]
}

@(private)
clean :: proc(path: string, allocator: runtime.Allocator) -> (cleaned: string, err: Error) {
	p := path
	abs: string
	if len(p) == 0 || p[0] != '/' {
		cwd, werr := os.get_working_directory(allocator)
		if werr != nil {
			return "", .Io
		}
		defer delete(cwd, allocator)
		abs = join3(cwd, "/", p, allocator) or_return
		p = abs
	}
	defer if abs != "" {
		delete(abs, allocator)
	}
	out, cerr := os.clean_path(p, allocator)
	if cerr != nil {
		return "", .Out_Of_Memory
	}
	return out, .None
}

@(private)
join2 :: proc(a, b: string, allocator: runtime.Allocator) -> (string, Error) {
	s, err := strings.concatenate({a, b}, allocator)
	return s, .None if err == nil else .Out_Of_Memory
}

@(private)
join3 :: proc(a, b, c: string, allocator: runtime.Allocator) -> (string, Error) {
	s, err := strings.concatenate({a, b, c}, allocator)
	return s, .None if err == nil else .Out_Of_Memory
}

@(private)
concat_into :: proc(buf: []u8, parts: ..string) -> (string, Error) {
	n := 0
	for p in parts {
		if n + len(p) > len(buf) {
			return "", .Invalid
		}
		n += copy(buf[n:], p)
	}
	return string(buf[:n]), .None
}

@(private)
loose_path :: proc(buf: []u8, dir: string, oid: Oid, format: Hash_Format) -> (string, Error) {
	hb: [MAX_HEX]u8
	hex := oid_to_string(oid, format, &hb)
	return concat_into(buf, dir, "/", hex[:2], "/", hex[2:])
}

@(private)
scan_packs :: proc(db: ^Odb, d: ^Object_Dir) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ta := context.temp_allocator
	pack_dir := join2(d.path, "/pack", ta) or_else ""
	if pack_dir == "" {
		return false
	}
	fi, serr := os.stat(pack_dir, ta)
	mtime: i64 = -1
	if serr == nil {
		mtime = time.to_unix_nanoseconds(fi.modification_time)
	}
	racy := mtime >= 0 && time.to_unix_nanoseconds(time.now()) - mtime < 2 * i64(time.Second)
	if d.scanned && mtime == d.pack_mtime && !racy {
		return false
	}
	d.scanned = true
	d.pack_mtime = mtime
	for p in d.packs {
		p.present = false
	}
	if serr == nil {
		entries, rerr := os.read_all_directory_by_path(pack_dir, ta)
		if rerr == nil {
			for e in entries {
				if !strings.has_prefix(e.name, "pack-") || !strings.has_suffix(e.name, ".idx") {
					continue
				}
				base := join3(pack_dir, "/", e.name[:len(e.name) - 4], ta) or_continue
				known := false
				for p in d.packs {
					if p.base == base {
						p.present = true
						known = true
						break
					}
				}
				if !known {
					load_pack(db, d, base)
				}
			}
		}
	}
	i := 0
	for i < len(d.packs) {
		p := d.packs[i]
		if p.present {
			i += 1
			continue
		}
		cache_drop_pack(db, p.id)
		pack_free(db, p)
		ordered_remove(&d.packs, i)
	}
	return true
}

@(private)
load_pack :: proc(db: ^Odb, d: ^Object_Dir, base: string) -> ^Pack {
	buf: [PATH_MAX]u8
	idx_path := concat_into(buf[:], base, ".idx") or_else ""
	if idx_path == "" {
		return nil
	}
	idx, merr := virtual.map_file_from_path(idx_path, {.Read})
	if merr != .None {
		return nil
	}
	p, aerr := new(Pack, db.allocator)
	if aerr != nil {
		virtual.unmap_file(idx)
		return nil
	}
	p.idx = idx
	p.hsz = oid_size(db.format)
	if !pack_validate_idx(p) {
		virtual.unmap_file(idx)
		free(p, db.allocator)
		return nil
	}
	cloned, cerr := strings.clone(base, db.allocator)
	if cerr != nil {
		virtual.unmap_file(idx)
		free(p, db.allocator)
		return nil
	}
	p.base = cloned
	p.id = db.next_pack
	db.next_pack += 1
	p.present = true
	append(&d.packs, p)
	return p
}

@(private)
find_packed :: proc(db: ^Odb, oid: Oid, primary_only: bool) -> (loc: Location) {
	for &d, di in db.dirs {
		if primary_only && d.extra {
			continue
		}
		if !d.scanned {
			scan_packs(db, &d)
		}
		for p in d.packs {
			if i, ok := pack_find(p, oid); ok {
				off, err := pack_offset_at(p, i)
				if err == .None {
					return {pack = p, offset = off, dir = di, found = true}
				}
			}
		}
	}
	return
}

@(private)
locate :: proc(db: ^Odb, oid: Oid, primary_only := false) -> (loc: Location) {
	loc = find_packed(db, oid, primary_only)
	if loc.found {
		return
	}
	buf: [PATH_MAX]u8
	for d, di in db.dirs {
		if primary_only && d.extra {
			continue
		}
		path, err := loose_path(buf[:], d.path, oid, db.format)
		if err == .None && os.exists(path) {
			return {dir = di, loose = true, found = true}
		}
	}
	rescanned := false
	for &d in db.dirs {
		if primary_only && d.extra {
			continue
		}
		if scan_packs(db, &d) {
			rescanned = true
		}
	}
	if rescanned {
		loc = find_packed(db, oid, primary_only)
	}
	return
}

exists :: proc(db: ^Odb, oid: Oid) -> bool {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	return locate(db, oid).found
}

@(private)
exists_for_write :: proc(db: ^Odb, oid: Oid) -> bool {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	loc := locate(db, oid, true)
	if !loc.found {
		return false
	}
	now := time.now()
	buf: [PATH_MAX]u8
	if loc.loose {
		path, err := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format)
		if err != .None {
			return true
		}
		if os.change_times(path, now, now) != nil {
			return false
		}
		fi, serr := os.stat(path, context.temp_allocator)
		if serr != nil {
			return false
		}
		size := fi.size
		os.file_info_delete(fi, context.temp_allocator)
		return size > 0
	}
	if !loc.pack.freshened {
		loc.pack.freshened = true
		if path, err := concat_into(buf[:], loc.pack.base, ".pack"); err == .None {
			os.change_times(path, now, now)
		}
	}
	return true
}

read :: proc(db: ^Odb, oid: Oid, allocator := context.allocator) -> (type: Object_Type, data: []u8, err: Error) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	return read_locked(db, oid, allocator)
}

@(private)
read_locked :: proc(db: ^Odb, oid: Oid, allocator: runtime.Allocator) -> (type: Object_Type, data: []u8, err: Error) {
	loc := locate(db, oid)
	if !loc.found {
		return .None, nil, .Not_Found
	}
	if loc.loose {
		buf: [PATH_MAX]u8
		path := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format) or_return
		return read_loose(db, path, allocator)
	}
	return read_packed(db, loc.pack, loc.offset, allocator)
}

read_header :: proc(db: ^Odb, oid: Oid) -> (type: Object_Type, size: i64, err: Error) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	loc := locate(db, oid)
	if !loc.found {
		return .None, 0, .Not_Found
	}
	if loc.loose {
		buf: [PATH_MAX]u8
		path := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format) or_return
		return loose_header(db, path)
	}
	return packed_header(db, loc.pack, loc.offset)
}

@(private)
Loaded_File :: struct {
	data:   []u8,
	mapped: bool,
}

@(private)
load_file :: proc(path: string, allocator: runtime.Allocator) -> (lf: Loaded_File, err: Error) {
	f, oerr := os.open(path)
	if oerr != nil {
		return lf, map_os_error(oerr)
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil || size < 0 {
		return lf, .Io
	}
	if size >= MAP_THRESHOLD {
		data, merr := virtual.map_file_from_file(f, {.Read})
		if merr != .None {
			return lf, .Io
		}
		return {data = data, mapped = true}, .None
	}
	data, aerr := make([]u8, int(size), allocator)
	if aerr != nil {
		return lf, .Out_Of_Memory
	}
	n, rerr := os.read_full(f, data)
	if rerr != nil || n != len(data) {
		delete(data, allocator)
		return lf, .Io
	}
	return {data = data}, .None
}

@(private)
unload_file :: proc(lf: Loaded_File, allocator: runtime.Allocator) {
	if lf.mapped {
		virtual.unmap_file(lf.data)
	} else {
		delete(lf.data, allocator)
	}
}

@(private)
read_loose :: proc(db: ^Odb, path: string, allocator: runtime.Allocator) -> (type: Object_Type, data: []u8, err: Error) {
	lf := load_file(path, db.allocator) or_return
	defer unload_file(lf, db.allocator)
	hdr: [64]u8
	n := inflate_prefix(lf.data, hdr[:]) or_return
	size, hlen: int
	{
		t, s, h := parse_object_header(hdr[:n]) or_return
		if s > i64(max(int) - 64) || !inflate_plausible(s, len(lf.data)) {
			return .None, nil, .Corrupt
		}
		type, size, hlen = t, int(s), h
	}
	out, aerr := make([]u8, hlen + size, allocator)
	if aerr != nil {
		return .None, nil, .Out_Of_Memory
	}
	if e := inflate_exact(lf.data, out); e != .None {
		delete(out, allocator)
		return .None, nil, e
	}
	copy(out, out[hlen:])
	return type, out[:size], .None
}

@(private)
loose_header :: proc(db: ^Odb, path: string) -> (type: Object_Type, size: i64, err: Error) {
	f, oerr := os.open(path)
	if oerr != nil {
		return .None, 0, map_os_error(oerr)
	}
	defer os.close(f)
	src: [512]u8
	n, rerr := os.read_full(f, src[:])
	if rerr != nil && rerr != .EOF && rerr != .Unexpected_EOF {
		return .None, 0, .Io
	}
	hdr: [64]u8
	m, ierr := inflate_prefix(src[:n], hdr[:])
	if ierr != .None && m == 0 {
		return .None, 0, ierr
	}
	type, size, _ = parse_object_header(hdr[:m]) or_return
	return
}

@(private)
read_packed :: proc(db: ^Odb, pack: ^Pack, offset: i64, allocator: runtime.Allocator) -> (type: Object_Type, data: []u8, err: Error) {
	Link :: struct {
		pack:   ^Pack,
		offset: i64,
		header: Entry_Header,
	}
	buf: [PATH_MAX]u8
	links: [dynamic]Link
	links.allocator = db.allocator
	defer delete(links)

	base: []u8
	base_owned := false
	base_pack: ^Pack
	base_offset: i64
	base_from_cache := false

	cur, cur_off := pack, offset
	for depth := 0; ; depth += 1 {
		if depth > MAX_DELTA_DEPTH {
			return .None, nil, .Corrupt
		}
		if e := cache_get(db, cur.id, cur_off); e != nil {
			type, base, base_from_cache = e.type, e.data, true
			break
		}
		pack_open_data(cur, buf[:]) or_return
		h := pack_entry_header(cur, cur_off) or_return
		if h.kind <= 4 {
			if len(links) > 0 && h.size > db.delta_limit {
				return .None, nil, .Too_Large
			}
			if h.size > i64(max(int)) || !inflate_plausible(h.size, len(pack_entry_src(cur, h))) {
				return .None, nil, .Corrupt
			}
			alloc := allocator if len(links) == 0 else db.allocator
			out, aerr := make([]u8, int(h.size), alloc)
			if aerr != nil {
				return .None, nil, .Out_Of_Memory
			}
			if e := inflate_exact(pack_entry_src(cur, h), out); e != .None {
				delete(out, alloc)
				return .None, nil, e
			}
			type, base, base_owned, base_pack, base_offset = Object_Type(h.kind), out, true, cur, cur_off
			break
		}
		if h.size > db.delta_limit {
			return .None, nil, .Too_Large
		}
		if !inflate_plausible(h.size, len(pack_entry_src(cur, h))) {
			return .None, nil, .Corrupt
		}
		append(&links, Link{cur, cur_off, h})
		if h.kind == OBJ_OFS_DELTA {
			cur_off = h.base_off
			continue
		}
		loc := locate(db, h.base_oid)
		if !loc.found {
			return .None, nil, .Not_Found
		}
		if loc.loose {
			path := loose_path(buf[:], db.dirs[loc.dir].path, h.base_oid, db.format) or_return
			type, base = read_loose(db, path, db.allocator) or_return
			base_owned = true
			break
		}
		cur, cur_off = loc.pack, loc.offset
	}
	if len(links) == 0 {
		if base_from_cache {
			out, aerr := make([]u8, len(base), allocator)
			if aerr != nil {
				return .None, nil, .Out_Of_Memory
			}
			copy(out, base)
			return type, out, .None
		}
		return type, base, .None
	}
	defer if err != .None && base_owned {
		delete(base, db.allocator)
	}
	for i := len(links) - 1; i >= 0; i -= 1 {
		link := links[i]
		delta, aerr := make([]u8, int(link.header.size), db.allocator)
		if aerr != nil {
			return .None, nil, .Out_Of_Memory
		}
		defer delete(delta, db.allocator)
		inflate_exact(pack_entry_src(link.pack, link.header), delta) or_return
		base_size, result_size, pos := delta_sizes(delta) or_return
		if base_size != i64(len(base)) {
			return .None, nil, .Corrupt
		}
		if result_size > db.delta_limit {
			return .None, nil, .Too_Large
		}
		alloc := allocator if i == 0 else db.allocator
		out, oerr := make([]u8, int(result_size), alloc)
		if oerr != nil {
			return .None, nil, .Out_Of_Memory
		}
		if e := apply_delta(base, delta, out, pos); e != .None {
			delete(out, alloc)
			return .None, nil, e
		}
		if base_owned {
			if base_pack != nil {
				cache_put(db, base_pack.id, base_offset, type, base)
			} else {
				delete(base, db.allocator)
			}
		}
		base, base_owned, base_pack, base_offset = out, i != 0, link.pack, link.offset
	}
	return type, base, .None
}

@(private)
packed_header :: proc(db: ^Odb, pack: ^Pack, offset: i64) -> (type: Object_Type, size: i64, err: Error) {
	buf: [PATH_MAX]u8
	cur, cur_off := pack, offset
	size = -1
	for depth := 0; ; depth += 1 {
		if depth > MAX_DELTA_DEPTH {
			return .None, 0, .Corrupt
		}
		if e := cache_get(db, cur.id, cur_off); e != nil {
			if size < 0 {
				size = i64(len(e.data))
			}
			return e.type, size, .None
		}
		pack_open_data(cur, buf[:]) or_return
		h := pack_entry_header(cur, cur_off) or_return
		if h.kind <= 4 {
			if size < 0 {
				size = h.size
			}
			return Object_Type(h.kind), size, .None
		}
		if size < 0 {
			prefix: [32]u8
			n, ierr := inflate_prefix(pack_entry_src(cur, h), prefix[:])
			if ierr != .None && n == 0 {
				return .None, 0, ierr
			}
			_, r, _ := delta_sizes(prefix[:n]) or_return
			size = r
		}
		if h.kind == OBJ_OFS_DELTA {
			cur_off = h.base_off
			continue
		}
		loc := locate(db, h.base_oid)
		if !loc.found {
			return .None, 0, .Not_Found
		}
		if loc.loose {
			path := loose_path(buf[:], db.dirs[loc.dir].path, h.base_oid, db.format) or_return
			t, _ := loose_header(db, path) or_return
			return t, size, .None
		}
		cur, cur_off = loc.pack, loc.offset
	}
}

@(private)
cache_get :: proc(db: ^Odb, pack: u32, offset: i64) -> ^Cache_Entry {
	for &e in db.cache {
		if e.data != nil && e.pack == pack && e.offset == offset {
			db.tick += 1
			e.tick = db.tick
			return &e
		}
	}
	return nil
}

@(private)
cache_put :: proc(db: ^Odb, pack: u32, offset: i64, type: Object_Type, data: []u8) {
	if len(data) == 0 || len(data) > db.cache_limit / 2 {
		delete(data, db.allocator)
		return
	}
	for db.cache_bytes + len(data) > db.cache_limit {
		if !cache_evict(db) {
			break
		}
	}
	slot := -1
	for e, i in db.cache {
		if e.data == nil {
			slot = i
			break
		}
	}
	if slot < 0 {
		cache_evict(db)
		for e, i in db.cache {
			if e.data == nil {
				slot = i
				break
			}
		}
	}
	if slot < 0 {
		delete(data, db.allocator)
		return
	}
	db.tick += 1
	db.cache[slot] = {pack, offset, type, data, db.tick}
	db.cache_bytes += len(data)
}

@(private)
cache_evict :: proc(db: ^Odb) -> bool {
	oldest := -1
	for e, i in db.cache {
		if e.data != nil && (oldest < 0 || e.tick < db.cache[oldest].tick) {
			oldest = i
		}
	}
	if oldest < 0 {
		return false
	}
	cache_free_slot(db, oldest)
	return true
}

@(private)
cache_free_slot :: proc(db: ^Odb, i: int) {
	db.cache_bytes -= len(db.cache[i].data)
	delete(db.cache[i].data, db.allocator)
	db.cache[i] = {}
}

@(private)
cache_drop_pack :: proc(db: ^Odb, pack: u32) {
	for e, i in db.cache {
		if e.data != nil && e.pack == pack {
			cache_free_slot(db, i)
		}
	}
}

@(private)
cache_clear :: proc(db: ^Odb) {
	for e, i in db.cache {
		if e.data != nil {
			cache_free_slot(db, i)
		}
	}
}

@(private)
Strip_Writer :: struct {
	inner:     io.Writer,
	hdr:       [32]u8,
	n:         int,
	ready:     bool,
	type:      Object_Type,
	size:      i64,
	remaining: i64,
}

@(private)
strip_writer_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	sw := (^Strip_Writer)(data)
	#partial switch mode {
	case .Write:
		rest := p
		if !sw.ready {
			for len(rest) > 0 && !sw.ready {
				if sw.n >= len(sw.hdr) {
					return 0, .Unknown
				}
				c := rest[0]
				rest = rest[1:]
				sw.hdr[sw.n] = c
				sw.n += 1
				if c == 0 {
					t, s, _, perr := parse_object_header(sw.hdr[:sw.n])
					if perr != .None {
						return 0, .Unknown
					}
					sw.type, sw.size, sw.remaining, sw.ready = t, s, s, true
				}
			}
		}
		if len(rest) > 0 {
			if i64(len(rest)) > sw.remaining {
				return 0, .Unknown
			}
			if _, werr := io.write_full(sw.inner, rest); werr != nil {
				return 0, werr
			}
			sw.remaining -= i64(len(rest))
		}
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

@(private)
File_Source :: struct {
	f:   ^os.File,
	buf: []u8,
}

@(private)
file_source_refill :: proc(data: rawptr) -> ([]u8, Error) {
	fs := (^File_Source)(data)
	n, err := os.read(fs.f, fs.buf)
	if err != nil && err != .EOF {
		return nil, .Io
	}
	return fs.buf[:n], .None
}

stream :: proc(db: ^Odb, oid: Oid, w: io.Writer) -> (type: Object_Type, size: i64, err: Error) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	loc := locate(db, oid)
	if !loc.found {
		return .None, 0, .Not_Found
	}
	buf: [PATH_MAX]u8
	if loc.loose {
		path := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format) or_return
		f, oerr := os.open(path)
		if oerr != nil {
			return .None, 0, map_os_error(oerr)
		}
		defer os.close(f)
		mem_buf, aerr := make([]u8, STREAM_BUFFER_SIZE + IO_CHUNK, db.allocator)
		if aerr != nil {
			return .None, 0, .Out_Of_Memory
		}
		defer delete(mem_buf, db.allocator)
		src := File_Source{f, mem_buf[STREAM_BUFFER_SIZE:]}
		sw := Strip_Writer{inner = w}
		sink := io.Stream{procedure = strip_writer_proc, data = &sw}
		_, e := inflate_to_writer(nil, file_source_refill, &src, sink, -1, mem_buf[:STREAM_BUFFER_SIZE])
		if e != .None {
			return .None, 0, e
		}
		if !sw.ready || sw.remaining != 0 {
			return .None, 0, .Corrupt
		}
		return sw.type, sw.size, .None
	}
	pack_open_data(loc.pack, buf[:]) or_return
	h := pack_entry_header(loc.pack, loc.offset) or_return
	if h.kind <= 4 {
		window, aerr := make([]u8, STREAM_BUFFER_SIZE, db.allocator)
		if aerr != nil {
			return .None, 0, .Out_Of_Memory
		}
		defer delete(window, db.allocator)
		inflate_to_writer(pack_entry_src(loc.pack, h), nil, nil, w, h.size, window) or_return
		return Object_Type(h.kind), h.size, .None
	}
	t, data := read_packed(db, loc.pack, loc.offset, db.allocator) or_return
	defer delete(data, db.allocator)
	if _, werr := io.write_full(w, data); werr != nil {
		return .None, 0, .Io
	}
	return t, i64(len(data)), .None
}

write :: proc(db: ^Odb, type: Object_Type, data: []u8, mode := Hash_Mode.Fast) -> (oid: Oid, err: Error) {
	if type == .None || len(db.dirs) == 0 {
		return {}, .Invalid
	}
	oid = hash(db.format, type, data, mode) or_return
	if exists_for_write(db, oid) {
		return oid, .None
	}
	return oid, write_loose_data(db, oid, type, data)
}

@(private)
write_loose_data :: proc(db: ^Odb, oid: Oid, type: Object_Type, data: []u8) -> (err: Error) {
	hbuf: [32]u8
	header := object_header(hbuf[:], type, i64(len(data)))
	tmp_buf: [PATH_MAX]u8
	f, tmp_path := create_temp(db.dirs[0].path, "tmp_obj_", tmp_buf[:]) or_return
	stack: [IO_CHUNK]u8
	total := zlib_stored_size(i64(len(header) + len(data)))
	w := Buf_Writer{f = f, buf = stack[:min(i64(IO_CHUNK), total)]}
	z: Zstream
	z_begin(&w, &z, i64(len(header) + len(data)))
	err = z_write(&w, &z, header)
	if err == .None {
		err = z_write(&w, &z, data)
	}
	if err == .None {
		err = z_end(&w, &z)
	}
	if err == .None {
		err = bw_flush(&w)
	}
	finish_temp(db, f, tmp_path, err) or_return
	return install_loose(db, tmp_path, oid)
}

@(private)
finish_temp :: proc(db: ^Odb, f: ^os.File, path: string, err: Error) -> Error {
	err := err
	if err == .None && db.sync_writes && os.sync(f) != nil {
		err = .Io
	}
	if os.close(f) != nil && err == .None {
		err = .Io
	}
	if err != .None {
		os.remove(path)
	}
	return err
}

@(private)
install_loose :: proc(db: ^Odb, tmp_path: string, oid: Oid) -> Error {
	dir := db.dirs[0].path
	buf: [PATH_MAX]u8
	final, perr := loose_path(buf[:], dir, oid, db.format)
	if perr != .None {
		os.remove(tmp_path)
		return perr
	}
	fan := final[:len(final) - (oid_size(db.format) * 2 - 1)]
	e := os.make_directory(fan, os.perm_number(0o777))
	if e != nil && e != .Exist {
		os.remove(tmp_path)
		return .Io
	}
	created := e == nil
	if os.rename(tmp_path, final) != nil {
		created = os.make_directory(fan, os.perm_number(0o777)) == nil || created
		if os.rename(tmp_path, final) != nil {
			os.remove(tmp_path)
			return .Io
		}
	}
	track(db, final, fan, dir if created else "")
	return .None
}

hash_file :: proc(path: string, format := Hash_Format.Sha1, mode := Hash_Mode.Fast) -> (oid: Oid, err: Error) {
	f, oerr := os.open(path)
	if oerr != nil {
		return {}, map_os_error(oerr)
	}
	defer os.close(f)
	size, serr := os.file_size(f)
	if serr != nil {
		return {}, .Io
	}
	h: Hasher
	hasher_init(&h, format, mode)
	hasher_header(&h, .Blob, size)
	buf: [IO_CHUNK]u8
	total: i64
	for {
		n, rerr := os.read(f, buf[:])
		if n > 0 {
			total += i64(n)
			if total > size {
				return {}, .Changed
			}
			hasher_update(&h, buf[:n])
		}
		if rerr == .EOF || (rerr == nil && n == 0) {
			break
		}
		if rerr != nil {
			return {}, .Io
		}
	}
	if total != size {
		return {}, .Changed
	}
	return hasher_final(&h)
}

write_file :: proc(db: ^Odb, path: string) -> (oid: Oid, err: Error) {
	if len(db.dirs) == 0 {
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
	expected: Maybe(Oid)
	if size >= db.two_pass_size {
		first := hash_file(path, db.format) or_return
		if exists_for_write(db, first) {
			return first, .None
		}
		expected = first
		if _, e := os.seek(f, 0, .Start); e != nil {
			return {}, .Io
		}
	}
	tmp_buf: [PATH_MAX]u8
	tmp, tmp_path := create_temp(db.dirs[0].path, "tmp_obj_", tmp_buf[:]) or_return
	oid, err = write_file_body(db, f, size, tmp)
	if err == .None {
		if e, ok := expected.?; ok && e != oid {
			err = .Changed
		}
	}
	finish_temp(db, tmp, tmp_path, err) or_return
	if expected == nil && exists_for_write(db, oid) {
		os.remove(tmp_path)
		return oid, .None
	}
	return oid, install_loose(db, tmp_path, oid)
}

@(private)
write_file_body :: proc(db: ^Odb, f: ^os.File, size: i64, tmp: ^os.File) -> (oid: Oid, err: Error) {
	h: Hasher
	hasher_init(&h, db.format)
	hbuf: [32]u8
	header := object_header(hbuf[:], .Blob, size)
	hasher_update(&h, header)
	wstack: [IO_CHUNK]u8
	w := Buf_Writer{f = tmp, buf = wstack[:]}
	z: Zstream
	z_begin(&w, &z, i64(len(header)) + size)
	z_write(&w, &z, header) or_return
	rbuf: [IO_CHUNK]u8
	for {
		n, rerr := os.read(f, rbuf[:])
		if n > 0 {
			hasher_update(&h, rbuf[:n])
			z_write(&w, &z, rbuf[:n]) or_return
		}
		if rerr == .EOF || (rerr == nil && n == 0) {
			break
		}
		if rerr != nil {
			return {}, .Io
		}
	}
	z_end(&w, &z) or_return
	bw_flush(&w) or_return
	return hasher_final(&h)
}

@(private)
write_atomic :: proc(path: string, data: []u8, durable: bool) -> Error {
	buf: [PATH_MAX]u8
	dir := parent_dir(path)
	f, tmp_path := create_temp(dir, ".tmp_", buf[:]) or_return
	_, werr := os.write(f, data)
	serr: os.Error
	if werr == nil && durable {
		serr = os.sync(f)
	}
	os.close(f)
	if werr != nil || serr != nil {
		os.remove(tmp_path)
		return .Io
	}
	os.change_mode(tmp_path, os.perm_number(0o644))
	if os.rename(tmp_path, path) != nil {
		os.remove(tmp_path)
		return .Io
	}
	return .None
}

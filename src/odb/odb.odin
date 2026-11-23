package odb

import "base:runtime"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "../prim"

DEFAULT_CACHE_LIMIT :: 8 * 1024 * 1024
DEFAULT_DELTA_LIMIT :: 256 * 1024 * 1024
DEFAULT_TWO_PASS_SIZE :: 1024 * 1024

@(private)
CACHE_SLOTS :: 32

@(private)
PATH_MAX :: 4096

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
	vfs:            prim.Vfs,
	use_mmap:       bool,
	clock:          prim.Clock,
	random:         prim.Random,
	temp_seq:       u64,
	format:         Hash_Format,
	dirs:           [dynamic]Object_Dir,
	git_dir:        string,
	common_dir:     string,
	cache_limit:    int,
	delta_limit:    i64,
	two_pass_size:  i64,
	sync_writes:    bool,
	deferred:       bool,
	store:          bool,
	pending_files:  [dynamic]string,
	pending_dirs:   [dynamic]string,
	owed_files:     [dynamic]string,
	staged:         [dynamic]^Staged,
	staged_at:      map[Oid]^Staged,
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
	staged: ^Staged,
}

@(private)
init :: proc(db: ^Odb, vfs: prim.Vfs, clock: prim.Clock, random: prim.Random, allocator: runtime.Allocator) {
	db^ = {}
	db.allocator = allocator
	db.vfs = vfs
	db.clock = clock
	db.random = random
	seed: [8]u8
	prim.random_fill(random, seed[:])
	db.temp_seq = transmute(u64)seed
	db.dirs = make([dynamic]Object_Dir, allocator)
	db.pending_files = make([dynamic]string, allocator)
	db.pending_dirs = make([dynamic]string, allocator)
	db.cache_limit = DEFAULT_CACHE_LIMIT
	db.delta_limit = DEFAULT_DELTA_LIMIT
	db.two_pass_size = DEFAULT_TWO_PASS_SIZE
}

open :: proc(db: ^Odb, vfs: prim.Vfs, worktree: string, extra_dirs: []string = nil, allocator := context.allocator, clock := prim.Clock{}, random := prim.Random{}) -> Error {
	init(db, vfs, clock, random, allocator)
	git_dir, common_dir, err := discover(vfs, worktree, allocator)
	if err != .None {
		close(db)
		return err
	}
	db.git_dir = git_dir
	db.common_dir = common_dir
	format, ferr := read_object_format(vfs, common_dir, allocator)
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
	if !prim.is_dir(vfs, objects) {
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

open_store :: proc(db: ^Odb, vfs: prim.Vfs, dir: string, extra_dirs: []string = nil, format := Hash_Format.Sha1, allocator := context.allocator, clock := prim.Clock{}, random := prim.Random{}) -> Error {
	init(db, vfs, clock, random, allocator)
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

sweep_temps :: proc(db: ^Odb) {
	base := primary_dir(db)
	if len(base) == 0 {
		return
	}
	for sub in ([]string{"", "/pack"}) {
		dir := strings.concatenate({base, sub}, context.temp_allocator)
		d: prim.Dir
		if prim.dir_open(db.vfs, &d, dir, context.temp_allocator) != .None {
			continue
		}
		stale := make([dynamic]string, context.temp_allocator)
		for {
			ent, more, derr := prim.dir_next(db.vfs, &d)
			if derr != .None || !more {
				break
			}
			for prefix in ([]string{"tmp_obj_", "tmp_pack_", "tmp_idx_", ".tmp_"}) {
				if own_temp_name(ent.name, prefix) {
					append(&stale, strings.concatenate({dir, "/", ent.name}, context.temp_allocator))
					break
				}
			}
		}
		prim.dir_close(db.vfs, &d)
		for p in stale {
			prim.remove(db.vfs, p)
		}
	}
}

@(private)
own_temp_name :: proc(name, prefix: string) -> bool {
	if len(name) != len(prefix) + 16 || !strings.has_prefix(name, prefix) {
		return false
	}
	for c in transmute([]u8)name[len(prefix):] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
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
		e := prim.mkdir_all(db.vfs, p)
		delete(p, a)
		if e != .None {
			return perr(e)
		}
	}
	head := join2(root, "/HEAD", a) or_return
	defer delete(head, a)
	if !prim.exists(db.vfs, head) {
		write_atomic(db, head, transmute([]u8)string("ref: refs/heads/main\n")) or_return
		track(db, head, root, parent_dir(root))
	}
	config := join2(root, "/config", a) or_return
	defer delete(config, a)
	if !prim.exists(db.vfs, config) {
		text := "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n"
		if format == .Sha256 {
			text = "[core]\n\trepositoryformatversion = 1\n\tfilemode = true\n\tbare = true\n[extensions]\n\tobjectformat = sha256\n"
		}
		write_atomic(db, config, transmute([]u8)text) or_return
		track(db, config, root)
	}
	db.format = read_object_format(db.vfs, root, a) or_return
	objects := join2(root, "/objects", a) or_return
	add_dir(db, objects, false, 0)
	return .None
}

add_object_dir :: proc(db: ^Odb, path: string) -> Error {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	p := clean(path, db.allocator) or_return
	if !prim.is_dir(db.vfs, p) {
		delete(p, db.allocator)
		return .Not_Found
	}
	if f, known := detect_dir_format(db.vfs, p, db.allocator); known && f != db.format {
		delete(p, db.allocator)
		return .Invalid
	}
	add_dir(db, p, true, 0)
	return .None
}

@(private)
detect_dir_format :: proc(vfs: prim.Vfs, objects: string, allocator: runtime.Allocator) -> (format: Hash_Format, known: bool) {
	parent := parent_dir(objects)
	buf: [PATH_MAX]u8
	if config, err := concat_into(buf[:], parent, "/config"); err == .None && prim.exists(vfs, config) {
		f, ferr := read_object_format(vfs, parent, allocator)
		if ferr != .None {
			return .Sha1, true
		}
		return f, true
	}
	for i in 0 ..< 256 {
		fan := [2]u8{HEX_DIGITS[i >> 4], HEX_DIGITS[i & 15]}
		dir := concat_into(buf[:], objects, "/", string(fan[:])) or_continue
		d: prim.Dir
		if prim.dir_open(vfs, &d, dir, allocator) != .None {
			continue
		}
		for {
			e, ok, derr := prim.dir_next(vfs, &d)
			if !ok || derr != .None {
				break
			}
			switch len(e.name) {
			case 38:
				prim.dir_close(vfs, &d)
				return .Sha1, true
			case 62:
				prim.dir_close(vfs, &d)
				return .Sha256, true
			}
		}
		prim.dir_close(vfs, &d)
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
	staged_clear(db)
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
		j := 0
		for p in d.packs {
			if p.staged {
				d.packs[j] = p
				j += 1
				continue
			}
			pack_free(db, p)
		}
		resize(&d.packs, j)
		d.scanned = false
		d.pack_mtime = 0
	}
}

bulk_begin :: proc(db: ^Odb) -> bool {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	was := db.use_mmap
	db.use_mmap = true
	return was
}

bulk_end :: proc(db: ^Odb, previous := false) {
	if previous {
		return
	}
	sync.mutex_lock(&db.mutex)
	db.use_mmap = false
	sync.mutex_unlock(&db.mutex)
	trim(db)
}

primary_dir :: proc(db: ^Odb) -> string {
	return db.dirs[0].path if len(db.dirs) > 0 else ""
}

@(private)
pack_free :: proc(db: ^Odb, p: ^Pack) {
	pack_close(db, p)
	delete(p.base, db.allocator)
	delete(p.data_at, db.allocator)
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
	text, rerr := vfs_read_file(db.vfs, alt_path, db.allocator)
	if rerr != .None {
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
		if _rooted(l) {
			target, cerr = clean(l, db.allocator)
		} else {
			joined := join3(path, "/", l, db.allocator) or_continue
			target, cerr = clean(joined, db.allocator)
			delete(joined, db.allocator)
		}
		if cerr != .None {
			continue
		}
		if !prim.is_dir(db.vfs, target) {
			delete(target, db.allocator)
			continue
		}
		add_dir(db, target, extra, depth + 1)
	}
}

@(private)
discover :: proc(vfs: prim.Vfs, worktree: string, allocator: runtime.Allocator) -> (git_dir, common_dir: string, err: Error) {
	start := clean(worktree, allocator) or_return
	defer delete(start, allocator)
	dir := start
	for {
		if gd, ok := git_dir_at(vfs, dir, allocator); ok {
			git_dir = gd
			break
		}
		if is_git_dir(vfs, dir) {
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
	common_dir, err = resolve_common_dir(vfs, git_dir, allocator)
	if err != .None {
		delete(git_dir, allocator)
		return "", "", err
	}
	return
}

@(private)
git_dir_at :: proc(vfs: prim.Vfs, dir: string, allocator: runtime.Allocator) -> (string, bool) {
	dot := join2(dir, "/.git", allocator) or_else ""
	if dot == "" {
		return "", false
	}
	if prim.is_dir(vfs, dot) {
		if is_git_dir(vfs, dot) {
			return dot, true
		}
		delete(dot, allocator)
		return "", false
	}
	defer delete(dot, allocator)
	text, rerr := vfs_read_file(vfs, dot, allocator)
	if rerr != .None {
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
	if _rooted(target) {
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
	if !is_git_dir(vfs, resolved) {
		delete(resolved, allocator)
		return "", false
	}
	return resolved, true
}

@(private)
is_git_dir :: proc(vfs: prim.Vfs, dir: string) -> bool {
	buf: [PATH_MAX]u8
	head := concat_into(buf[:], dir, "/HEAD") or_else ""
	if head == "" || !prim.exists(vfs, head) {
		return false
	}
	common := concat_into(buf[:], dir, "/commondir") or_else ""
	if common != "" && prim.exists(vfs, common) {
		return true
	}
	objects := concat_into(buf[:], dir, "/objects") or_else ""
	return objects != "" && prim.is_dir(vfs, objects)
}

@(private)
resolve_common_dir :: proc(vfs: prim.Vfs, git_dir: string, allocator: runtime.Allocator) -> (dir: string, err: Error) {
	path := join2(git_dir, "/commondir", allocator) or_return
	defer delete(path, allocator)
	text, rerr := vfs_read_file(vfs, path, allocator)
	if rerr != .None {
		return clean(git_dir, allocator)
	}
	defer delete(text, allocator)
	target := strings.trim_space(string(text))
	if len(target) == 0 {
		return clean(git_dir, allocator)
	}
	if _rooted(target) {
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
_rooted :: proc "contextless" (p: string) -> bool {
	return prim.is_abs(p) || (len(p) > 0 && (p[0] == '/' || p[0] == '\\'))
}

@(private)
clean :: proc(path: string, allocator: runtime.Allocator) -> (cleaned: string, err: Error) {
	p := path
	abs: string
	if !_rooted(p) {
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
	when ODIN_OS == .Windows {
		return _clean_lexical(p, allocator)
	} else {
		out, cerr := os.clean_path(p, allocator)
		if cerr != nil {
			return "", .Out_Of_Memory
		}
		return out, .None
	}
}

@(private)
_clean_lexical :: proc(path: string, allocator: runtime.Allocator) -> (string, Error) {
	b := make([dynamic]u8, 0, len(path) + 1, allocator)
	if b == nil && len(path) > 0 {
		return "", .Out_Of_Memory
	}
	sep :: proc "contextless" (c: u8) -> bool {
		return c == '/' || c == '\\'
	}
	i := 0
	if len(path) >= 2 && sep(path[0]) && sep(path[1]) {
		append(&b, '/', '/')
		i = 2
		for parts := 0; parts < 2 && i < len(path); parts += 1 {
			for i < len(path) && sep(path[i]) {
				i += 1
			}
			for i < len(path) && !sep(path[i]) {
				append(&b, path[i])
				i += 1
			}
			append(&b, '/')
		}
	} else if len(path) >= 2 && path[1] == ':' {
		append(&b, path[0], ':')
		i = 2
		if i < len(path) && sep(path[i]) {
			append(&b, '/')
		}
	} else if len(path) > 0 && sep(path[0]) {
		append(&b, '/')
	}
	root := len(b)
	for i < len(path) {
		for i < len(path) && sep(path[i]) {
			i += 1
		}
		j := i
		for j < len(path) && !sep(path[j]) {
			j += 1
		}
		comp := path[i:j]
		i = j
		switch comp {
		case "", ".":
			continue
		case "..":
			k := len(b)
			for k > root && b[k - 1] == '/' {
				k -= 1
			}
			if k > root {
				for k > root && b[k - 1] != '/' {
					k -= 1
				}
				resize(&b, k)
				continue
			}
			if root > 0 {
				continue
			}
		}
		if len(b) > root && b[len(b) - 1] != '/' {
			append(&b, '/')
		}
		append(&b, ..transmute([]u8)comp)
	}
	for len(b) > root && b[len(b) - 1] == '/' {
		resize(&b, len(b) - 1)
	}
	if len(b) == 0 {
		append(&b, '.')
	}
	return string(b[:]), .None
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
	buf: [PATH_MAX]u8
	pack_dir := concat_into(buf[:], d.path, "/pack") or_else ""
	if pack_dir == "" {
		return false
	}
	mtime, have := vfs_mtime(db.vfs, pack_dir)
	if !have {
		mtime = -1
	}
	racy := mtime >= 0 && now_ns(db) - mtime < 2_000_000_000
	if d.scanned && mtime == d.pack_mtime && !racy {
		return false
	}
	d.scanned = true
	d.pack_mtime = mtime
	for p in d.packs {
		p.present = p.staged
	}
	dir: prim.Dir
	if have && prim.dir_open(db.vfs, &dir, pack_dir, db.allocator) == .None {
		for {
			e, ok, derr := prim.dir_next(db.vfs, &dir)
			if !ok || derr != .None {
				break
			}
			if !strings.has_prefix(e.name, "pack-") || !strings.has_suffix(e.name, ".idx") {
				continue
			}
			nb: [PATH_MAX]u8
			base := concat_into(nb[:], pack_dir, "/", e.name[:len(e.name) - 4]) or_continue
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
		prim.dir_close(db.vfs, &dir)
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
load_pack :: proc(db: ^Odb, d: ^Object_Dir, base: string, idx_at := "") -> ^Pack {
	buf: [PATH_MAX]u8
	idx_path := idx_at
	if idx_path == "" {
		idx_path = concat_into(buf[:], base, ".idx") or_else ""
	}
	if idx_path == "" {
		return nil
	}
	p, aerr := new(Pack, db.allocator)
	if aerr != nil {
		return nil
	}
	p.fd = prim.INVALID_FD
	p.hsz = oid_size(db.format)
	if db.use_mmap && vfs_is_os(db.vfs) && idx_at == "" {
		idx, merr := vfs_map_path(db.vfs, idx_path)
		if merr != .None {
			free(p, db.allocator)
			return nil
		}
		p.idx, p.idx_mapped = idx, true
	} else {
		idx, rerr := vfs_read_file(db.vfs, idx_path, db.allocator)
		if rerr != .None {
			free(p, db.allocator)
			return nil
		}
		p.idx = idx
	}
	cloned, cerr := strings.clone(base, db.allocator)
	if cerr != nil || !pack_validate_idx(p) {
		if cerr == nil {
			delete(cloned, db.allocator)
		}
		pack_close(db, p)
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
	if s := staged_lookup(db, oid); s != nil {
		return {loose = true, found = true, staged = s}
	}
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
		if err == .None && prim.exists(db.vfs, path) {
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
	if loc.staged != nil {
		return true
	}
	now := now_ns(db)
	buf: [PATH_MAX]u8
	if loc.loose {
		path, err := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format)
		if err != .None {
			return true
		}
		st, serr := prim.stat(db.vfs, path)
		if serr != .None || st.size == 0 {
			return false
		}
		if !set_mtime(db, path, now) {
			return false
		}
		return true
	}
	if !loc.pack.freshened {
		loc.pack.freshened = true
		if path, err := concat_into(buf[:], loc.pack.base, ".pack"); err == .None {
			set_mtime(db, path, now)
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
	if loc.staged != nil {
		return read_staged(db, loc.staged, allocator)
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
	if loc.staged != nil {
		t, data := read_staged(db, loc.staged, db.allocator) or_return
		delete(data, db.allocator)
		return t, i64(len(data)), .None
	}
	if loc.loose {
		buf: [PATH_MAX]u8
		path := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format) or_return
		return loose_header(db, path)
	}
	return packed_header(db, loc.pack, loc.offset)
}

@(private)
read_loose :: proc(db: ^Odb, path: string, allocator: runtime.Allocator) -> (type: Object_Type, data: []u8, err: Error) {
	raw := vfs_read_file(db.vfs, path, db.allocator) or_return
	defer delete(raw, db.allocator)
	hdr: [64]u8
	n := inflate_prefix(raw, hdr[:]) or_return
	size, hlen: int
	{
		t, s, h := parse_object_header(hdr[:n]) or_return
		if s > i64(max(int) - 64) || !inflate_plausible(s, len(raw)) {
			return .None, nil, .Corrupt
		}
		type, size, hlen = t, int(s), h
	}
	out, aerr := make([]u8, hlen + size, allocator)
	if aerr != nil {
		return .None, nil, .Out_Of_Memory
	}
	if e := inflate_exact(raw, out); e != .None {
		delete(out, allocator)
		return .None, nil, e
	}
	copy(out, out[hlen:])
	return type, out[:size], .None
}

@(private)
loose_header :: proc(db: ^Odb, path: string) -> (type: Object_Type, size: i64, err: Error) {
	fd, oerr := prim.open_file(db.vfs, path)
	if oerr != .None {
		return .None, 0, perr(oerr)
	}
	defer prim.close_file(db.vfs, fd)
	src: [512]u8
	n, rerr := prim.read_at(db.vfs, fd, src[:], 0)
	if rerr != .None {
		return .None, 0, perr(rerr)
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
		pack_open_data(db, cur) or_return
		h := pack_entry_header(db, cur, cur_off) or_return
		if h.kind <= 4 {
			if len(links) > 0 && h.size > db.delta_limit {
				return .None, nil, .Too_Large
			}
			if h.size > i64(max(int)) || !inflate_plausible(h.size, pack_compressed_avail(cur, h)) {
				return .None, nil, .Corrupt
			}
			alloc := allocator if len(links) == 0 else db.allocator
			out, aerr := make([]u8, int(h.size), alloc)
			if aerr != nil {
				return .None, nil, .Out_Of_Memory
			}
			if e := pack_inflate_exact(db, cur, h, out); e != .None {
				delete(out, alloc)
				return .None, nil, e
			}
			type, base, base_owned, base_pack, base_offset = Object_Type(h.kind), out, true, cur, cur_off
			break
		}
		if h.size > db.delta_limit {
			return .None, nil, .Too_Large
		}
		if !inflate_plausible(h.size, pack_compressed_avail(cur, h)) {
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
		if loc.staged != nil {
			type, base = read_staged(db, loc.staged, db.allocator) or_return
			base_owned = true
			break
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
		pack_inflate_exact(db, link.pack, link.header, delta) or_return
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
		pack_open_data(db, cur) or_return
		h := pack_entry_header(db, cur, cur_off) or_return
		if h.kind <= 4 {
			if size < 0 {
				size = h.size
			}
			return Object_Type(h.kind), size, .None
		}
		if size < 0 {
			prefix: [32]u8
			n, ierr := pack_inflate_prefix(db, cur, h, prefix[:])
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
		if loc.staged != nil {
			t, data := read_staged(db, loc.staged, db.allocator) or_return
			delete(data, db.allocator)
			return t, size, .None
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
	vfs: prim.Vfs,
	fd:  prim.Fd,
	pos: i64,
	buf: []u8,
}

@(private)
file_source_refill :: proc(data: rawptr) -> ([]u8, Error) {
	fs := (^File_Source)(data)
	n, err := prim.read_at(fs.vfs, fs.fd, fs.buf, fs.pos)
	if err != .None {
		return nil, perr(err)
	}
	fs.pos += i64(n)
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
	if loc.staged != nil {
		t, data := read_staged(db, loc.staged, db.allocator) or_return
		defer delete(data, db.allocator)
		if _, werr := io.write_full(w, data); werr != nil {
			return .None, 0, .Io
		}
		return t, i64(len(data)), .None
	}
	if loc.loose {
		path := loose_path(buf[:], db.dirs[loc.dir].path, oid, db.format) or_return
		fd, oerr := prim.open_file(db.vfs, path)
		if oerr != .None {
			return .None, 0, perr(oerr)
		}
		defer prim.close_file(db.vfs, fd)
		mem_buf, aerr := make([]u8, STREAM_BUFFER_SIZE + IO_CHUNK, db.allocator)
		if aerr != nil {
			return .None, 0, .Out_Of_Memory
		}
		defer delete(mem_buf, db.allocator)
		src := File_Source{db.vfs, fd, 0, mem_buf[STREAM_BUFFER_SIZE:]}
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
	pack_open_data(db, loc.pack) or_return
	h := pack_entry_header(db, loc.pack, loc.offset) or_return
	if h.kind <= 4 {
		window, aerr := make([]u8, STREAM_BUFFER_SIZE, db.allocator)
		if aerr != nil {
			return .None, 0, .Out_Of_Memory
		}
		defer delete(window, db.allocator)
		pack_inflate_to_writer(db, loc.pack, h, w, window) or_return
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
	fd, tmp_path := create_temp(db, db.dirs[0].path, "tmp_obj_", tmp_buf[:]) or_return
	stack: [IO_CHUNK]u8
	total := zlib_stored_size(i64(len(header) + len(data)))
	w := Buf_Writer{vfs = db.vfs, fd = fd, buf = stack[:min(i64(IO_CHUNK), total)]}
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
	finish_temp(db, fd, tmp_path, err) or_return
	return install_loose(db, tmp_path, oid)
}

@(private)
finish_temp :: proc(db: ^Odb, fd: prim.Fd, path: string, err: Error) -> Error {
	err := err
	if err == .None && db.sync_writes {
		err = perr(prim.datasync(db.vfs, fd))
	}
	if e := prim.close_file(db.vfs, fd); e != .None && err == .None {
		err = perr(e)
	}
	if err != .None {
		prim.remove(db.vfs, path)
	}
	return err
}

@(private)
install_loose :: proc(db: ^Odb, tmp_path: string, oid: Oid) -> Error {
	dir := db.dirs[0].path
	buf: [PATH_MAX]u8
	final, lerr := loose_path(buf[:], dir, oid, db.format)
	if lerr != .None {
		prim.remove(db.vfs, tmp_path)
		return lerr
	}
	fan := final[:len(final) - (oid_size(db.format) * 2 - 1)]
	created, merr := vfs_mkdir(db, fan)
	if merr != .None {
		prim.remove(db.vfs, tmp_path)
		return merr
	}
	if db.deferred {
		stage_loose(db, oid, tmp_path, final, fan)
		if created {
			track(db, "", dir)
		}
		return .None
	}
	if prim.rename(db.vfs, tmp_path, final) != .None {
		again, _ := vfs_mkdir(db, fan)
		created = created || again
		if e := prim.rename(db.vfs, tmp_path, final); e != .None {
			prim.remove(db.vfs, tmp_path)
			return perr(e)
		}
	}
	track(db, final, fan, dir if created else "")
	return .None
}

hash_file :: proc(vfs: prim.Vfs, path: string, format := Hash_Format.Sha1, mode := Hash_Mode.Fast) -> (oid: Oid, err: Error) {
	fd, oerr := prim.open_file(vfs, path)
	if oerr != .None {
		return {}, perr(oerr)
	}
	defer prim.close_file(vfs, fd)
	size := vfs_size(vfs, fd) or_return
	h: Hasher
	hasher_init(&h, format, mode)
	hasher_header(&h, .Blob, size)
	buf: [IO_CHUNK]u8
	pos: i64
	for {
		n, rerr := prim.read_at(vfs, fd, buf[:], pos)
		if rerr != .None {
			return {}, perr(rerr)
		}
		if n > 0 {
			pos += i64(n)
			if pos > size {
				return {}, .Changed
			}
			hasher_update(&h, buf[:n])
		}
		if n < len(buf) {
			break
		}
	}
	if pos != size {
		return {}, .Changed
	}
	return hasher_final(&h)
}

write_file :: proc(db: ^Odb, path: string) -> (oid: Oid, err: Error) {
	if len(db.dirs) == 0 {
		return {}, .Invalid
	}
	fd, oerr := prim.open_file(db.vfs, path)
	if oerr != .None {
		return {}, perr(oerr)
	}
	defer prim.close_file(db.vfs, fd)
	size := vfs_size(db.vfs, fd) or_return
	expected: Maybe(Oid)
	if size >= db.two_pass_size {
		first := hash_file(db.vfs, path, db.format) or_return
		if exists_for_write(db, first) {
			return first, .None
		}
		expected = first
	}
	tmp_buf: [PATH_MAX]u8
	tmp, tmp_path := create_temp(db, db.dirs[0].path, "tmp_obj_", tmp_buf[:]) or_return
	oid, err = write_file_body(db, fd, size, tmp)
	if err == .None {
		if e, ok := expected.?; ok && e != oid {
			err = .Changed
		}
	}
	finish_temp(db, tmp, tmp_path, err) or_return
	if expected == nil && exists_for_write(db, oid) {
		prim.remove(db.vfs, tmp_path)
		return oid, .None
	}
	return oid, install_loose(db, tmp_path, oid)
}

@(private)
write_file_body :: proc(db: ^Odb, fd: prim.Fd, size: i64, tmp: prim.Fd) -> (oid: Oid, err: Error) {
	h: Hasher
	hasher_init(&h, db.format)
	hbuf: [32]u8
	header := object_header(hbuf[:], .Blob, size)
	hasher_update(&h, header)
	wstack: [IO_CHUNK]u8
	w := Buf_Writer{vfs = db.vfs, fd = tmp, buf = wstack[:]}
	z: Zstream
	z_begin(&w, &z, i64(len(header)) + size)
	z_write(&w, &z, header) or_return
	rbuf: [IO_CHUNK]u8
	pos: i64
	for {
		n, rerr := prim.read_at(db.vfs, fd, rbuf[:], pos)
		if rerr != .None {
			return {}, perr(rerr)
		}
		if n > 0 {
			pos += i64(n)
			hasher_update(&h, rbuf[:n])
			z_write(&w, &z, rbuf[:n]) or_return
		}
		if n < len(rbuf) {
			break
		}
	}
	z_end(&w, &z) or_return
	bw_flush(&w) or_return
	return hasher_final(&h)
}

@(private)
write_atomic :: proc(db: ^Odb, path: string, data: []u8) -> Error {
	buf: [PATH_MAX]u8
	dir := parent_dir(path)
	fd, tmp_path := create_temp(db, dir, ".tmp_", buf[:]) or_return
	err := perr(prim.write_at(db.vfs, fd, data, 0))
	if err == .None {
		err = perr(prim.fchmod(db.vfs, fd, 0o644))
	}
	finish_temp(db, fd, tmp_path, err) or_return
	if e := prim.rename(db.vfs, tmp_path, path); e != .None {
		prim.remove(db.vfs, tmp_path)
		return perr(e)
	}
	track(db, path, dir)
	return .None
}

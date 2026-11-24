package fs

import "base:runtime"
import "core:mem/virtual"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"

Autocrlf :: enum u8 {
	False,
	True,
	Input,
}

Core_Eol :: enum u8 {
	Unset,
	Lf,
	Crlf,
	Native,
}

Filter_Driver :: struct {
	name:     string,
	clean:    string,
	smudge:   string,
	process:  string,
	required: bool,
}

Git_Settings :: struct {
	filters:      [dynamic]Filter_Driver,
	autocrlf:     Autocrlf,
	core_eol:     Core_Eol,
	trust_exec:   bool,
	symlinks:     bool,
	ignore_case:  bool,
	global_attrs: []u8,
	system_attrs: []u8,
	roundtrip:    string,
	has_roundtrip: bool,
	safecrlf:     Safe_Crlf,
}

Safe_Crlf :: enum u8 {
	Warn,
	Off,
	Die,
}

Crlf_Action :: enum u8 {
	Undefined,
	Binary,
	Text,
	Text_Input,
	Text_Crlf,
	Auto,
	Auto_Input,
	Auto_Crlf,
}

@(private)
Attr_State :: enum u8 {
	Unspecified,
	Set,
	Unset,
	Value,
}

@(private)
Attr_Assign :: struct {
	name:  string,
	value: string,
	state: Attr_State,
}

@(private)
Attr_Line :: struct {
	pattern: string,
	assigns: []Attr_Assign,
	macro:   string,
	nodir:   bool,
	mustdir: bool,
}

@(private)
Attr_File :: struct {
	base:  string,
	lines: []Attr_Line,
}

Attr_Ctx :: struct {
	arena:  virtual.Arena,
	alloc:  runtime.Allocator,
	files:  map[string]^Attr_File,
	info:   ^Attr_File,
	global: ^Attr_File,
	system: ^Attr_File,
	macros: map[string][]Attr_Assign,
	depth:  int,
	procs:  [dynamic]^Filter_Proc,
	index:  map[string]odb.Oid,
	indexed: bool,
	ix:      Index_Reader,
	ix_open: bool,
	ix_cur:  Index_Entry,
	ix_have: bool,
	ix_key:  string,
	ix_runs: int,
	snap:   ^fstree.Snapshot,
	version: []crdt.Lv,
}

@(private)
Text_Stat :: struct {
	nul:          int,
	lonecr:       int,
	lonelf:       int,
	crlf:         int,
	printable:    int,
	nonprintable: int,
}

@(private)
ATTR_FILE_MAX :: 100 << 20

path_is_abs :: proc "contextless" (p: string) -> bool {
	return prim.is_abs(p)
}

@(private)
git_home :: proc "contextless" () -> (string, bool) {
	return prim.getenv("HOME")
}

@(private)
git_program_data_config :: proc(buf: []u8) -> (string, bool) {
	pd, ok := prim.getenv("PROGRAMDATA")
	if !ok {
		return "", false
	}
	return path_join_buf(buf, pd, "Git/config")
}

@(private)
git_prefix :: proc(buf: []u8) -> (string, bool) {
	path, ok := prim.getenv("PATH")
	if !ok {
		return "", false
	}
	sep: u8 = ';' if ODIN_OS == .Windows else ':'
	exe_name := "git.exe" if ODIN_OS == .Windows else "git"
	rest := path
	for len(rest) > 0 {
		i := 0
		for i < len(rest) && rest[i] != sep {
			i += 1
		}
		dir := rest[:i]
		rest = rest[i + 1:] if i < len(rest) else ""
		for len(dir) > 1 && (dir[len(dir) - 1] == '\\' || dir[len(dir) - 1] == '/') {
			dir = dir[:len(dir) - 1]
		}
		if len(dir) == 0 {
			continue
		}
		pbuf: prim.Path_Buf
		exe, eok := path_join_buf(pbuf[:], dir, exe_name)
		if !eok || !prim.exists(prim.os_vfs(), exe) {
			continue
		}
		prefix := prim.dir_name(dir)
		leaf := path_leaf(dir, prefix)
		if ascii_fold_eq(leaf, "bin") || ascii_fold_eq(leaf, "cmd") || ascii_fold_eq(leaf, "libexec") {
			parent := prim.dir_name(prefix)
			pleaf := path_leaf(prefix, parent)
			if ODIN_OS == .Windows && (ascii_fold_eq(pleaf, "mingw64") || ascii_fold_eq(pleaf, "mingw32") || ascii_fold_eq(pleaf, "clangarm64") || ascii_fold_eq(pleaf, "usr")) {
				prefix = parent
			}
		} else {
			prefix = dir
		}
		if len(prefix) > len(buf) {
			return "", false
		}
		n := copy(buf, prefix)
		return string(buf[:n]), true
	}
	return "", false
}

@(private)
path_leaf :: proc "contextless" (dir, parent: string) -> string {
	leaf := dir[len(parent):]
	for len(leaf) > 0 && (leaf[0] == '\\' || leaf[0] == '/') {
		leaf = leaf[1:]
	}
	return leaf
}

@(private)
git_system_file :: proc(buf: []u8, rel: string) -> (string, bool) {
	when ODIN_OS == .Windows {
		pbuf: [prim.PATH_MAX]u8
		prefix, ok := git_prefix(pbuf[:])
		if !ok {
			return "", false
		}
		return path_join_buf(buf, prefix, rel)
	} else {
		return path_join_buf(buf, "/", rel)
	}
}

@(private)
ascii_fold_eq :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' {
			x += 32
		}
		if y >= 'A' && y <= 'Z' {
			y += 32
		}
		if x != y {
			return false
		}
	}
	return true
}

@(private)
git_settings_attributes :: proc(g: ^Git_Settings, vfs: prim.Vfs, global: string, allocator: runtime.Allocator) {
	if len(global) > 0 {
		if data, err := ignore_read(vfs, global, ATTR_FILE_MAX, allocator); err == .None && len(data) > 0 {
			g.global_attrs = data
		}
	}
	nosystem := false
	if v, ok := prim.getenv("GIT_ATTR_NOSYSTEM"); ok {
		nosystem = len(v) > 0 && v != "0" && !ascii_fold_eq(v, "false") && !ascii_fold_eq(v, "no") && !ascii_fold_eq(v, "off")
	}
	if !nosystem {
		buf: prim.Path_Buf
		if p, ok := git_system_file(buf[:], "etc/gitattributes"); ok {
			if data, err := ignore_read(vfs, p, ATTR_FILE_MAX, allocator); err == .None && len(data) > 0 {
				g.system_attrs = data
			}
		}
	}
}

git_settings_destroy :: proc(g: ^Git_Settings, allocator: runtime.Allocator) {
	for f in g.filters {
		delete(f.name, allocator)
		delete(f.clean, allocator)
		delete(f.smudge, allocator)
		delete(f.process, allocator)
	}
	delete(g.filters)
	g.filters = nil
	if g.global_attrs != nil {
		delete(g.global_attrs, allocator)
	}
	if g.system_attrs != nil {
		delete(g.system_attrs, allocator)
	}
	if g.has_roundtrip {
		delete(g.roundtrip, allocator)
	}
	g.global_attrs = nil
	g.system_attrs = nil
	g.roundtrip = ""
	g.has_roundtrip = false
}

@(private)
mount_git_settings :: proc(m: ^Mount) -> ^Git_Settings {
	return &m.ignore.git
}

mount_trust_exec :: proc(m: ^Mount) -> bool {
	when ODIN_OS == .Windows {
		return false
	} else {
		return !m.has_git || m.ignore.git.trust_exec
	}
}

mount_symlinks :: proc(m: ^Mount) -> bool {
	if m.link_mode == .Emulated || (m.has_git && !m.ignore.git.symlinks) {
		return false
	}
	when ODIN_OS == .Windows {
		if m.link_mode == .Unknown && m.vfs.procs == prim.os_vfs().procs {
			probe_path, _ := path_join(m.root, "x", context.temp_allocator)
			tmp := temp_name(m, probe_path, context.temp_allocator)
			prim.remove(m.vfs, tmp)
			#partial switch prim.symlink(m.vfs, "x", tmp) {
			case .None:
				prim.remove(m.vfs, tmp)
				m.link_mode = .Native
			case .Permission, .Unsupported, .Invalid:
				m.link_mode = .Emulated
			}
		}
	}
	return m.link_mode != .Emulated
}

mount_symlinks_emulated :: proc(m: ^Mount) -> bool {
	return m.link_mode == .Emulated || (m.has_git && !m.ignore.git.symlinks)
}

Link_Mode :: enum u8 {
	Unknown,
	Native,
	Emulated,
}

exec_bit :: proc(m: ^Mount, stat: Stat, prev: bool) -> bool {
	if mount_trust_exec(m) {
		return stat.mode & 0o100 != 0
	}
	return prev
}

attr_begin :: proc(m: ^Mount) {
	if m.attrs != nil {
		m.attrs.depth += 1
		return
	}
	c := new(Attr_Ctx, runtime.heap_allocator())
	if c == nil {
		return
	}
	if virtual.arena_init_growing(&c.arena, 64 << 10) != nil {
		free(c, runtime.heap_allocator())
		return
	}
	c.alloc = virtual.arena_allocator(&c.arena)
	c.files = make(map[string]^Attr_File, c.alloc)
	c.macros = make(map[string][]Attr_Assign, c.alloc)
	c.depth = 1
	m.attrs = c
	attr_load_globals(m, c)
}

attr_end :: proc(m: ^Mount) {
	c := m.attrs
	if c == nil {
		return
	}
	c.depth -= 1
	if c.depth > 0 {
		return
	}
	m.attrs = nil
	if c.ix_open {
		index_close(&c.ix)
	}
	for fp in c.procs {
		filter_proc_stop(fp)
		free(fp, runtime.heap_allocator())
	}
	delete(c.procs)
	virtual.arena_destroy(&c.arena)
	free(c, runtime.heap_allocator())
}

@(private)
attr_filter_proc :: proc(m: ^Mount, driver: ^Filter_Driver) -> ^Filter_Proc {
	c := m.attrs
	for fp in c.procs {
		if fp.driver == driver {
			return fp
		}
	}
	fp := new(Filter_Proc, runtime.heap_allocator())
	fp.driver = driver
	if c.procs == nil {
		c.procs = make([dynamic]^Filter_Proc, runtime.heap_allocator())
	}
	append(&c.procs, fp)
	return fp
}

attr_set_checkout :: proc(m: ^Mount, snap: ^fstree.Snapshot, version: []crdt.Lv) -> (prev: ^fstree.Snapshot, prev_version: []crdt.Lv) {
	c := m.attrs
	if c == nil {
		return
	}
	prev, prev_version = c.snap, c.version
	c.snap = snap
	c.version = version
	clear(&c.files)
	attr_load_globals(m, c)
	return
}

@(private)
attr_history_text :: proc(m: ^Mount, c: ^Attr_Ctx, rel: string) -> ([]u8, bool) {
	if c.snap == nil || m.history == nil {
		return nil, false
	}
	ino, found, lerr := fstree.lookup(c.snap, rel)
	if lerr != nil || !found {
		return nil, false
	}
	info, ok, ierr := fstree.info(c.snap, ino, c.alloc)
	if ierr != nil || !ok || !info.present || info.kind != .File {
		return nil, false
	}
	flags, ferr := tree_flags(m.history, ino)
	if ferr != .None {
		return nil, false
	}
	if .Opaque in flags && m.db != nil {
		if reg, has, berr := history_blob_at(m.history, ino, c.version); berr == .None && has {
			if _, size, herr := odb.read_header(m.db, odb.Oid(reg.oid)); herr != .None || size > ATTR_FILE_MAX {
				return nil, false
			}
			if t, blob, rerr := odb.read(m.db, odb.Oid(reg.oid), c.alloc); rerr == .None && t == .Blob {
				return blob, true
			}
			return nil, false
		}
	}
	ids := crdt.graph_version_ids(&m.history.g, c.version, c.alloc)
	data, err := history_text_at(m.history, ino, ids, c.alloc)
	if err != .None {
		return nil, false
	}
	return data, true
}

@(private)
INDEX_SCAN_RUNS :: 2

@(private)
index_blob :: proc(m: ^Mount, rel: string) -> (oid: odb.Oid, found: bool) {
	c := m.attrs
	if c == nil || !m.has_git || m.db == nil {
		return
	}
	if !c.indexed && c.ix_open && rel < c.ix_key {
		index_close(&c.ix)
		c.ix_open = false
	}
	if !c.indexed && !c.ix_open {
		if c.ix_runs >= INDEX_SCAN_RUNS {
			index_fill(m, c)
		} else {
			c.ix_runs += 1
			c.ix_have = false
			if index_open(&c.ix, m.vfs, m.git.dir, m.git_format, c.alloc) != .None {
				c.indexed = true
				c.index = make(map[string]odb.Oid, c.alloc)
				return
			}
			c.ix_open = true
		}
	}
	if c.indexed {
		oid, found = c.index[rel]
		return
	}
	c.ix_key, _ = clone_string(rel, c.alloc)
	for {
		if !c.ix_have {
			e, ok, err := index_next(&c.ix)
			if err != .None || !ok {
				return
			}
			c.ix_cur = e
			c.ix_have = true
		}
		e := c.ix_cur
		if e.path > rel {
			return
		}
		if e.path == rel {
			return e.oid, e.stage == 0 && e.mode & 0o170000 == 0o100000
		}
		c.ix_have = false
	}
}

@(private)
index_fill :: proc(m: ^Mount, c: ^Attr_Ctx) {
	c.indexed = true
	c.index = make(map[string]odb.Oid, c.alloc)
	r: Index_Reader
	if index_open(&r, m.vfs, m.git.dir, m.git_format, c.alloc) != .None {
		return
	}
	for {
		e, ok, err := index_next(&r)
		if err != .None || !ok {
			break
		}
		if e.stage == 0 && e.mode & 0o170000 == 0o100000 {
			k, _ := clone_string(e.path, c.alloc)
			c.index[k] = e.oid
		}
	}
	index_close(&r)
}

attr_invalidate :: proc(m: ^Mount, rel: string) {
	c := m.attrs
	if c == nil || path_name(rel) != ".gitattributes" {
		return
	}
	dir := path_parent(rel)
	delete_key(&c.files, dir)
	if len(dir) == 0 {
		clear(&c.macros)
		attr_load_globals(m, c)
	}
}

@(private)
attr_load_globals :: proc(m: ^Mount, c: ^Attr_Ctx) {
	clear(&c.macros)
	c.macros["binary"] = attr_parse_assigns("-diff -merge -text", c.alloc)
	g := mount_git_settings(m)
	c.system = attr_parse(g.system_attrs, "", true, c.alloc) if g.system_attrs != nil else nil
	attr_collect_macros(c, c.system)
	c.global = attr_parse(g.global_attrs, "", true, c.alloc) if g.global_attrs != nil else nil
	attr_collect_macros(c, c.global)
	root := attr_dir_file(m, c, "")
	attr_collect_macros(c, root)
	c.info = nil
	if m.has_git && len(m.git.common) > 0 {
		buf: prim.Path_Buf
		if p, ok := path_join_buf(buf[:], m.git.common, "info/attributes"); ok {
			if data, err := ignore_read(m.vfs, p, ATTR_FILE_MAX, c.alloc); err == .None && len(data) > 0 {
				c.info = attr_parse(data, "", true, c.alloc)
			}
		}
	}
	attr_collect_macros(c, c.info)
}

@(private)
attr_collect_macros :: proc(c: ^Attr_Ctx, f: ^Attr_File) {
	if f == nil {
		return
	}
	for l in f.lines {
		if len(l.macro) > 0 {
			c.macros[l.macro] = l.assigns
		}
	}
}

@(private)
attr_dir_file :: proc(m: ^Mount, c: ^Attr_Ctx, dir: string) -> ^Attr_File {
	if f, ok := c.files[dir]; ok {
		return f
	}
	key, _ := clone_string(dir, c.alloc)
	c.files[key] = nil
	rel, _ := path_join(dir, ".gitattributes", c.alloc)
	data, have := attr_history_text(m, c, rel)
	if !have {
		buf: prim.Path_Buf
		p, ok := path_join_buf(buf[:], m.root, rel)
		if !ok {
			return nil
		}
		st, serr := prim.lstat(m.vfs, p)
		if serr != .None || st.kind != .File {
			return nil
		}
		d, err := ignore_read(m.vfs, p, ATTR_FILE_MAX, c.alloc)
		if err != .None {
			return nil
		}
		data = d
	}
	f := attr_parse(data, key, len(dir) == 0, c.alloc)
	c.files[key] = f
	return f
}

@(private)
attr_space :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

@(private)
attr_parse :: proc(data: []u8, base: string, macros_ok: bool, allocator: runtime.Allocator) -> ^Attr_File {
	lines := make([dynamic]Attr_Line, allocator)
	text := string(data)
	if len(text) >= 3 && text[0] == 0xEF && text[1] == 0xBB && text[2] == 0xBF {
		text = text[3:]
	}
	for len(text) > 0 {
		i := 0
		for i < len(text) && text[i] != '\n' {
			i += 1
		}
		line := text[:i]
		text = text[i + 1:] if i < len(text) else ""
		j := 0
		for j < len(line) && attr_space(line[j]) {
			j += 1
		}
		line = line[j:]
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		pattern: string
		rest: string
		if line[0] == '"' {
			p, consumed, ok := attr_unquote(line, allocator)
			if !ok {
				continue
			}
			pattern = p
			rest = line[consumed:]
		} else {
			k := 0
			for k < len(line) && !attr_space(line[k]) {
				k += 1
			}
			pattern = line[:k]
			rest = line[k:]
		}
		l: Attr_Line
		if len(pattern) > 6 && pattern[:6] == "[attr]" {
			if !macros_ok {
				continue
			}
			l.macro = pattern[6:]
			if !attr_name_valid(l.macro) {
				continue
			}
		} else {
			if len(pattern) == 0 || pattern[0] == '!' {
				continue
			}
			if pattern[len(pattern) - 1] == '/' {
				l.mustdir = true
				pattern = pattern[:len(pattern) - 1]
			}
			l.nodir = true
			for ch in transmute([]u8)pattern {
				if ch == '/' {
					l.nodir = false
					break
				}
			}
			if !l.nodir && len(pattern) > 0 && pattern[0] == '/' {
				pattern = pattern[1:]
			}
			l.pattern = pattern
		}
		l.assigns = attr_parse_assigns(rest, allocator)
		append(&lines, l)
	}
	f := new(Attr_File, allocator)
	f.base = base
	f.lines = lines[:]
	return f
}

@(private)
attr_name_valid :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || s[0] == '-' {
		return false
	}
	for ch in transmute([]u8)s {
		if !(ch == '-' || ch == '.' || ch == '_' || (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
			return false
		}
	}
	return true
}

@(private)
attr_parse_assigns :: proc(rest: string, allocator: runtime.Allocator) -> []Attr_Assign {
	out := make([dynamic]Attr_Assign, allocator)
	s := rest
	for len(s) > 0 {
		for len(s) > 0 && attr_space(s[0]) {
			s = s[1:]
		}
		k := 0
		for k < len(s) && !attr_space(s[k]) {
			k += 1
		}
		tok := s[:k]
		s = s[k:]
		if len(tok) == 0 {
			continue
		}
		a: Attr_Assign
		switch tok[0] {
		case '-':
			a.state = .Unset
			tok = tok[1:]
		case '!':
			a.state = .Unspecified
			tok = tok[1:]
		case:
			a.state = .Set
			for c, i in transmute([]u8)tok {
				if c == '=' {
					a.state = .Value
					a.value = tok[i + 1:]
					tok = tok[:i]
					break
				}
			}
		}
		if !attr_name_valid(tok) {
			continue
		}
		a.name = tok
		append(&out, a)
	}
	return out[:]
}

@(private)
attr_unquote :: proc(line: string, allocator: runtime.Allocator) -> (out: string, consumed: int, ok: bool) {
	buf := make([dynamic]u8, allocator)
	i := 1
	for i < len(line) {
		ch := line[i]
		if ch == '"' {
			return string(buf[:]), i + 1, true
		}
		if ch != '\\' {
			append(&buf, ch)
			i += 1
			continue
		}
		i += 1
		if i >= len(line) {
			return "", 0, false
		}
		e := line[i]
		switch e {
		case 'a':
			append(&buf, 7)
		case 'b':
			append(&buf, 8)
		case 'f':
			append(&buf, 12)
		case 'n':
			append(&buf, '\n')
		case 'r':
			append(&buf, '\r')
		case 't':
			append(&buf, '\t')
		case 'v':
			append(&buf, 11)
		case '\\', '"':
			append(&buf, e)
		case '0' ..= '3':
			if i + 2 >= len(line) || line[i + 1] < '0' || line[i + 1] > '7' || line[i + 2] < '0' || line[i + 2] > '7' {
				return "", 0, false
			}
			append(&buf, (e - '0') << 6 | (line[i + 1] - '0') << 3 | (line[i + 2] - '0'))
			i += 2
		case:
			return "", 0, false
		}
		i += 1
	}
	return "", 0, false
}

@(private)
attr_line_matches :: proc(l: ^Attr_Line, base: string, rel: string, fold: bool) -> bool {
	if len(l.macro) > 0 || l.mustdir {
		return false
	}
	if l.nodir {
		return wild_do(l.pattern, 0, path_name(rel), 0, false, fold) == .Match
	}
	sub := rel
	if len(base) > 0 {
		if !path_under(rel, base) {
			return false
		}
		sub = rel[len(base) + 1:]
	}
	return wild_do(l.pattern, 0, sub, 0, true, fold) == .Match
}

@(private)
Attr_Want :: struct {
	text:  Attr_Assign,
	eol:   Attr_Assign,
	crlf:  Attr_Assign,
	ident: Attr_Assign,
	filter: Attr_Assign,
	encoding: Attr_Assign,
	have:  bit_set[0 ..< 6],
	seen:  map[string]bool,
}

@(private)
attr_apply :: proc(c: ^Attr_Ctx, w: ^Attr_Want, a: Attr_Assign) {
	slot := -1
	switch a.name {
	case "text":
		slot = 0
	case "eol":
		slot = 1
	case "crlf":
		slot = 2
	case "ident":
		slot = 3
	case "filter":
		slot = 4
	case "working-tree-encoding":
		slot = 5
	}
	if slot >= 0 {
		if slot in w.have {
			return
		}
		w.have += {slot}
		switch slot {
		case 0:
			w.text = a
		case 1:
			w.eol = a
		case 2:
			w.crlf = a
		case 3:
			w.ident = a
		case 4:
			w.filter = a
		case 5:
			w.encoding = a
		}
		return
	}
	defs, is_macro := c.macros[a.name]
	if !is_macro || w.seen[a.name] {
		return
	}
	w.seen[a.name] = true
	if a.state != .Set {
		return
	}
	for i := len(defs) - 1; i >= 0; i -= 1 {
		attr_apply(c, w, defs[i])
	}
}

@(private)
attr_fill :: proc(c: ^Attr_Ctx, w: ^Attr_Want, f: ^Attr_File, rel: string, fold: bool) {
	if f == nil {
		return
	}
	for i := len(f.lines) - 1; i >= 0; i -= 1 {
		l := &f.lines[i]
		if !attr_line_matches(l, f.base, rel, fold) {
			continue
		}
		for j := len(l.assigns) - 1; j >= 0; j -= 1 {
			attr_apply(c, w, l.assigns[j])
		}
		if card(w.have) == 6 {
			return
		}
	}
}

@(private)
attr_lookup :: proc(m: ^Mount, rel: string) -> Attr_Want {
	c := m.attrs
	w := Attr_Want {
		seen = make(map[string]bool, c.alloc),
	}
	fold := mount_git_settings(m).ignore_case
	attr_fill(c, &w, c.info, rel, fold)
	dir := path_parent(rel)
	for card(w.have) < 6 {
		attr_fill(c, &w, attr_dir_file(m, c, dir), rel, fold)
		if len(dir) == 0 {
			break
		}
		dir = path_parent(dir)
	}
	attr_fill(c, &w, c.global, rel, fold)
	attr_fill(c, &w, c.system, rel, fold)
	delete(w.seen)
	return w
}

@(private)
crlf_from_attr :: proc "contextless" (a: Attr_Assign) -> Crlf_Action {
	switch a.state {
	case .Set:
		return .Text
	case .Unset:
		return .Binary
	case .Value:
		if a.value == "input" {
			return .Text_Input
		}
		if a.value == "auto" {
			return .Auto
		}
	case .Unspecified:
	}
	return .Undefined
}

@(private)
native_crlf :: proc "contextless" () -> bool {
	return ODIN_OS == .Windows
}

@(private)
text_eol_is_crlf :: proc "contextless" (g: ^Git_Settings) -> bool {
	switch g.autocrlf {
	case .True:
		return true
	case .Input:
		return false
	case .False:
	}
	switch g.core_eol {
	case .Crlf:
		return true
	case .Unset, .Native:
		return native_crlf()
	case .Lf:
	}
	return false
}

Conv :: struct {
	action:   Crlf_Action,
	ident:    bool,
	encoding: string,
	enc_bad:  bool,
	driver:   ^Filter_Driver,
}

conv_attrs :: proc(m: ^Mount, rel: string, flagged := false) -> (cv: Conv) {
	cv.action = .Binary
	if !m.has_git && !flagged {
		return
	}
	owned := m.attrs == nil
	if owned {
		attr_begin(m)
		if m.attrs == nil {
			return
		}
	}
	defer if owned {
		attr_end(m)
	}
	w := attr_lookup(m, rel)
	g := mount_git_settings(m)
	action := crlf_from_attr(w.text) if 0 in w.have else Crlf_Action.Undefined
	if action == .Undefined && 2 in w.have {
		action = crlf_from_attr(w.crlf)
	}
	if action != .Binary && 1 in w.have && w.eol.state == .Value {
		lf := w.eol.value == "lf"
		crlf := w.eol.value == "crlf"
		switch {
		case action == .Auto && lf:
			action = .Auto_Input
		case action == .Auto && crlf:
			action = .Auto_Crlf
		case lf:
			action = .Text_Input
		case crlf:
			action = .Text_Crlf
		}
	}
	if action == .Text {
		action = .Text_Crlf if text_eol_is_crlf(g) else .Text_Input
	}
	if action == .Undefined {
		switch g.autocrlf {
		case .False:
			action = .Binary
		case .True:
			action = .Auto_Crlf
		case .Input:
			action = .Auto_Input
		}
	}
	cv.action = action
	cv.ident = 3 in w.have && w.ident.state == .Set
	if 4 in w.have && w.filter.state == .Value {
		cv.driver = filter_find(m, w.filter.value)
	}
	if 5 in w.have {
		switch w.encoding.state {
		case .Value:
			if len(w.encoding.value) > 0 && !enc_is_utf8(w.encoding.value) {
				cv.encoding, _ = clone_string(w.encoding.value, context.temp_allocator)
			}
		case .Set, .Unset:
			cv.enc_bad = true
		case .Unspecified:
		}
	}
	return
}

conv_needed :: proc(m: ^Mount, rel: string) -> bool {
	cv := conv_attrs(m, rel)
	return cv.action != .Binary || cv.ident || len(cv.encoding) > 0 || cv.enc_bad || cv.driver != nil
}

eol_action :: proc(m: ^Mount, rel: string) -> Crlf_Action {
	return conv_attrs(m, rel).action
}

@(private)
output_crlf :: proc(m: ^Mount, action: Crlf_Action) -> bool {
	switch action {
	case .Binary, .Text_Input, .Auto_Input:
		return false
	case .Text_Crlf, .Undefined, .Auto_Crlf:
		return true
	case .Text, .Auto:
		return text_eol_is_crlf(mount_git_settings(m))
	}
	return false
}

@(private)
text_is_binary :: proc "contextless" (s: Text_Stat) -> bool {
	return s.lonecr > 0 || s.nul > 0 || (s.printable >> 7) < s.nonprintable
}

@(private)
action_auto :: #force_inline proc "contextless" (a: Crlf_Action) -> bool {
	return a == .Auto || a == .Auto_Input || a == .Auto_Crlf
}


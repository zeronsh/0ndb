package fs

import "base:runtime"
import "core:io"
import "core:mem/virtual"
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

Git_Settings :: struct {
	autocrlf:     Autocrlf,
	core_eol:     Core_Eol,
	trust_exec:   bool,
	symlinks:     bool,
	ignore_case:  bool,
	global_attrs: []u8,
	system_attrs: []u8,
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
git_system_file :: proc(buf: []u8, rel: string) -> (string, bool) {
	when ODIN_OS == .Windows {
		path, ok := prim.getenv("PATH")
		if !ok {
			return "", false
		}
		rest := path
		for len(rest) > 0 {
			i := 0
			for i < len(rest) && rest[i] != ';' {
				i += 1
			}
			dir := rest[:i]
			rest = rest[i + 1:] if i < len(rest) else ""
			for len(dir) > 0 && (dir[len(dir) - 1] == '\\' || dir[len(dir) - 1] == '/') {
				dir = dir[:len(dir) - 1]
			}
			if len(dir) == 0 {
				continue
			}
			pbuf: prim.Path_Buf
			exe, eok := path_join_buf(pbuf[:], dir, "git.exe")
			if !eok || !prim.exists(prim.os_vfs(), exe) {
				continue
			}
			prefix := prim.dir_name(dir)
			leaf := dir[len(prefix):]
			for len(leaf) > 0 && (leaf[0] == '\\' || leaf[0] == '/') {
				leaf = leaf[1:]
			}
			if ascii_fold_eq(leaf, "bin") || ascii_fold_eq(leaf, "cmd") {
				parent := prim.dir_name(prefix)
				pleaf := prefix[len(parent):]
				for len(pleaf) > 0 && (pleaf[0] == '\\' || pleaf[0] == '/') {
					pleaf = pleaf[1:]
				}
				if ascii_fold_eq(pleaf, "mingw64") || ascii_fold_eq(pleaf, "mingw32") || ascii_fold_eq(pleaf, "clangarm64") || ascii_fold_eq(pleaf, "usr") {
					prefix = parent
				}
				return path_join_buf(buf, prefix, rel)
			}
		}
		return "", false
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
	if g.global_attrs != nil {
		delete(g.global_attrs, allocator)
	}
	if g.system_attrs != nil {
		delete(g.system_attrs, allocator)
	}
	g.global_attrs = nil
	g.system_attrs = nil
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
	return !m.has_git || m.ignore.git.symlinks
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
	virtual.arena_destroy(&c.arena)
	free(c, runtime.heap_allocator())
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
	buf: prim.Path_Buf
	p, ok := path_join_buf(buf[:], m.root, dir, ".gitattributes")
	if !ok {
		return nil
	}
	st, serr := prim.lstat(m.vfs, p)
	if serr != .None || st.kind != .File {
		return nil
	}
	data, err := ignore_read(m.vfs, p, ATTR_FILE_MAX, c.alloc)
	if err != .None {
		return nil
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
	have:  bit_set[0 ..< 3],
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
		if card(w.have) == 3 {
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
	for card(w.have) < 3 {
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

eol_action :: proc(m: ^Mount, rel: string) -> Crlf_Action {
	if !m.has_git {
		return .Binary
	}
	owned := m.attrs == nil
	if owned {
		attr_begin(m)
		if m.attrs == nil {
			return .Binary
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
	return action
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
text_stat :: proc "contextless" (buf: []u8) -> (s: Text_Stat) {
	n := len(buf)
	i := 0
	for i < n {
		c := buf[i]
		if c == '\r' {
			if i + 1 < n && buf[i + 1] == '\n' {
				s.crlf += 1
				i += 2
			} else {
				s.lonecr += 1
				i += 1
			}
			continue
		}
		i += 1
		if c == '\n' {
			s.lonelf += 1
			continue
		}
		if c == 127 {
			s.nonprintable += 1
		} else if c < 32 {
			switch c {
			case '\b', '\t', 0o33, 0o14:
				s.printable += 1
			case 0:
				s.nul += 1
				s.nonprintable += 1
			case:
				s.nonprintable += 1
			}
		} else {
			s.printable += 1
		}
	}
	if n >= 1 && buf[n - 1] == 0o32 {
		s.nonprintable -= 1
	}
	return
}

@(private)
text_is_binary :: proc "contextless" (s: Text_Stat) -> bool {
	return s.lonecr > 0 || s.nul > 0 || (s.printable >> 7) < s.nonprintable
}

@(private)
action_auto :: #force_inline proc "contextless" (a: Crlf_Action) -> bool {
	return a == .Auto || a == .Auto_Input || a == .Auto_Crlf
}

eol_clean_action :: proc(action: Crlf_Action, data: []u8, index_has_cr: proc(data: rawptr) -> bool, cr_data: rawptr, allocator := context.temp_allocator) -> []u8 {
	if action == .Binary || action == .Undefined || len(data) == 0 {
		return data
	}
	s := text_stat(data)
	if s.crlf == 0 {
		return data
	}
	if action_auto(action) {
		if text_is_binary(s) {
			return data
		}
		if index_has_cr != nil && index_has_cr(cr_data) {
			return data
		}
	}
	out := make([]u8, len(data) - s.crlf, allocator)
	n := 0
	if action_auto(action) {
		for c in data {
			if c != '\r' {
				out[n] = c
				n += 1
			}
		}
	} else {
		for c, i in data {
			if c == '\r' && i + 1 < len(data) && data[i + 1] == '\n' {
				continue
			}
			out[n] = c
			n += 1
		}
	}
	return out[:n]
}

eol_smudge_action :: proc(m: ^Mount, action: Crlf_Action, data: []u8, allocator := context.temp_allocator) -> []u8 {
	if len(data) == 0 || !output_crlf(m, action) {
		return data
	}
	s := text_stat(data)
	if s.lonelf == 0 {
		return data
	}
	if action_auto(action) && (s.lonecr > 0 || s.crlf > 0 || text_is_binary(s)) {
		return data
	}
	out := make([]u8, len(data) + s.lonelf, allocator)
	n := 0
	for c, i in data {
		if c == '\n' && (i == 0 || data[i - 1] != '\r') {
			out[n] = '\r'
			n += 1
		}
		out[n] = c
		n += 1
	}
	return out[:n]
}

@(private)
Old_Text :: struct {
	m:     ^Mount,
	inode: fstree.Inode_Id,
}

eol_clean :: proc(m: ^Mount, rel: string, data: []u8, inode := fstree.Inode_Id{}, has_old := false, allocator := context.temp_allocator) -> []u8 {
	if !m.has_git || len(data) == 0 {
		return data
	}
	action := eol_action(m, rel)
	if action == .Binary {
		return data
	}
	ot := Old_Text{m, inode}
	return eol_clean_action(action, data, proc(p: rawptr) -> bool {
		o := (^Old_Text)(p)
		if o.m.history == nil {
			return false
		}
		old, err := history_text_at(o.m.history, o.inode, o.m.synced[:], context.temp_allocator)
		if err != .None {
			return false
		}
		for c in old {
			if c == '\r' {
				return true
			}
		}
		return false
	} if has_old else nil, &ot, allocator)
}

eol_smudge :: proc(m: ^Mount, rel: string, data: []u8, allocator := context.temp_allocator) -> []u8 {
	if !m.has_git || len(data) == 0 {
		return data
	}
	return eol_smudge_action(m, eol_action(m, rel), data, allocator)
}

@(private)
Eol_Stream :: struct {
	s:    Text_Stat,
	cr:   bool,
	last: u8,
	n:    i64,
}

@(private)
eol_stream_feed :: proc "contextless" (es: ^Eol_Stream, data: []u8) {
	for c in data {
		if es.cr {
			es.cr = false
			if c == '\n' {
				es.s.crlf += 1
				continue
			}
			es.s.lonecr += 1
		}
		switch {
		case c == '\r':
			es.cr = true
		case c == '\n':
			es.s.lonelf += 1
		case c == 127:
			es.s.nonprintable += 1
		case c < 32:
			switch c {
			case '\b', '\t', 0o33, 0o14:
				es.s.printable += 1
			case 0:
				es.s.nul += 1
				es.s.nonprintable += 1
			case:
				es.s.nonprintable += 1
			}
		case:
			es.s.printable += 1
		}
	}
	if len(data) > 0 {
		es.last = data[len(data) - 1]
		es.n += i64(len(data))
	}
}

@(private)
eol_stream_finish :: proc "contextless" (es: ^Eol_Stream) -> Text_Stat {
	s := es.s
	if es.cr {
		s.lonecr += 1
	}
	if es.n >= 1 && es.last == 0o32 {
		s.nonprintable -= 1
	}
	return s
}

@(private)
LARGE_CHUNK :: 1 << 20

@(private)
blob_has_cr :: proc(m: ^Mount, inode: fstree.Inode_Id) -> bool {
	if m.history == nil || m.db == nil {
		return false
	}
	reg, has, err := history_blob(m.history, inode)
	if err != .None || !has {
		old, terr := history_text_at(m.history, inode, m.synced[:], context.temp_allocator)
		if terr != .None {
			return false
		}
		for c in old {
			if c == '\r' {
				return true
			}
		}
		return false
	}
	Cr_Sink :: struct {
		found: bool,
	}
	sink := Cr_Sink{}
	odb.stream(m.db, odb.Oid(reg.oid), io.Stream{procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		#partial switch mode {
		case .Write:
			s := (^Cr_Sink)(data)
			if !s.found {
				for c in p {
					if c == '\r' {
						s.found = true
						break
					}
				}
			}
			return i64(len(p)), nil
		case .Query:
			return io.query_utility({.Write, .Query})
		}
		return 0, .Unsupported
	}, data = &sink})
	return sink.found
}

store_large_clean :: proc(m: ^Mount, rel: string, abs: string, old := fstree.Inode_Id{}, has_old := false) -> (oid: odb.Oid, size: i64, ok: bool) {
	if !m.has_git || m.db == nil {
		return
	}
	action := eol_action(m, rel)
	if action == .Binary || action == .Undefined {
		return
	}
	fd, oerr := prim.open_file(m.vfs, abs)
	if oerr != .None {
		return
	}
	defer prim.close_file(m.vfs, fd)
	buf := make([]u8, LARGE_CHUNK, context.temp_allocator)
	es: Eol_Stream
	off: i64
	for {
		n, rerr := prim.read_at(m.vfs, fd, buf, off)
		if rerr != .None {
			return
		}
		if n <= 0 {
			break
		}
		eol_stream_feed(&es, buf[:n])
		off += i64(n)
	}
	s := eol_stream_finish(&es)
	if s.crlf == 0 {
		return
	}
	if action_auto(action) {
		if text_is_binary(s) {
			return
		}
		if has_old && blob_has_cr(m, old) {
			return
		}
	}
	tmp, _ := path_join(m.dir, "eol-clean.tmp", context.temp_allocator)
	out, cerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, 0o600)
	if cerr != .None {
		return
	}
	defer prim.remove(m.vfs, tmp)
	conv := make([]u8, LARGE_CHUNK, context.temp_allocator)
	auto := action_auto(action)
	pending := false
	woff: i64
	off = 0
	for {
		n, rerr := prim.read_at(m.vfs, fd, buf, off)
		if rerr != .None {
			prim.close_file(m.vfs, out)
			return
		}
		if n <= 0 {
			break
		}
		off += i64(n)
		k := 0
		for c in buf[:n] {
			if auto {
				if c != '\r' {
					conv[k] = c
					k += 1
				}
				continue
			}
			if pending {
				pending = false
				if c != '\n' {
					conv[k] = '\r'
					k += 1
				}
			}
			if c == '\r' {
				pending = true
				continue
			}
			conv[k] = c
			k += 1
			if k == len(conv) {
				if prim.write_at(m.vfs, out, conv[:k], woff) != .None {
					prim.close_file(m.vfs, out)
					return
				}
				woff += i64(k)
				k = 0
			}
		}
		if k > 0 {
			if prim.write_at(m.vfs, out, conv[:k], woff) != .None {
				prim.close_file(m.vfs, out)
				return
			}
			woff += i64(k)
		}
	}
	if pending {
		one := [1]u8{'\r'}
		if prim.write_at(m.vfs, out, one[:], woff) != .None {
			prim.close_file(m.vfs, out)
			return
		}
		woff += 1
	}
	prim.close_file(m.vfs, out)
	o, werr := odb.write_file(m.db, tmp)
	if werr != .None {
		return
	}
	history_note_blob(m.history, o)
	return o, woff, true
}

@(private)
Smudge_Sink :: struct {
	inner: io.Stream,
	prev:  u8,
	buf:   []u8,
	err:   bool,
}

@(private)
smudge_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Smudge_Sink)(data)
	#partial switch mode {
	case .Write:
		k := 0
		for c in p {
			if k + 2 > len(s.buf) {
				if _, e := io.write(s.inner, s.buf[:k]); e != nil {
					return 0, e
				}
				k = 0
			}
			if c == '\n' && s.prev != '\r' {
				s.buf[k] = '\r'
				k += 1
			}
			s.buf[k] = c
			k += 1
			s.prev = c
		}
		if k > 0 {
			if _, e := io.write(s.inner, s.buf[:k]); e != nil {
				return 0, e
			}
		}
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

eol_smudge_large :: proc(m: ^Mount, rel: string, oid: odb.Oid) -> (convert: bool) {
	if !m.has_git || m.db == nil {
		return false
	}
	action := eol_action(m, rel)
	if !output_crlf(m, action) {
		return false
	}
	es := new(Eol_Stream, context.temp_allocator)
	_, _, serr := odb.stream(m.db, oid, io.Stream{procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		#partial switch mode {
		case .Write:
			eol_stream_feed((^Eol_Stream)(data), p)
			return i64(len(p)), nil
		case .Query:
			return io.query_utility({.Write, .Query})
		}
		return 0, .Unsupported
	}, data = es})
	if serr != .None {
		return false
	}
	s := eol_stream_finish(es)
	if s.lonelf == 0 {
		return false
	}
	if action_auto(action) && (s.lonecr > 0 || s.crlf > 0 || text_is_binary(s)) {
		return false
	}
	return true
}

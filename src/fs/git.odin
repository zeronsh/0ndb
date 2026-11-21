package fs

import "base:runtime"
import "core:strings"
import "../odb"
import "../prim"

Git_Dirs :: struct {
	dir:    string,
	common: string,
}

Git_Head :: struct {
	branch: string,
	commit: string,
}

Index_Stamp :: struct {
	mtime_ns: i64,
	size:     i64,
	ino:      u64,
}

git_locate :: proc(vfs: prim.Vfs, root: string, allocator := context.allocator) -> (g: Git_Dirs, found: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	dot, _ := path_join(root, ".git", context.temp_allocator)
	dir: string
	st, err := prim.lstat(vfs, dot)
	if err != .None {
		return
	}
	if st.kind == .Dir {
		dir = dot
	} else if st.kind == .File {
		text, rerr := prim.read_file(vfs, dot, context.temp_allocator)
		if rerr != .None {
			return
		}
		s := strings.trim_space(string(text))
		if !strings.has_prefix(s, "gitdir:") {
			return
		}
		t := strings.trim_space(s[len("gitdir:"):])
		if len(t) == 0 {
			return
		}
		if t[0] == '/' {
			dir = t
		} else {
			dir, _ = path_join(root, t, context.temp_allocator)
		}
	} else {
		return
	}
	dir = clean_path(dir, context.temp_allocator)
	head, _ := path_join(dir, "HEAD", context.temp_allocator)
	if !prim.exists(vfs, head) {
		return
	}
	common := dir
	cfile, _ := path_join(dir, "commondir", context.temp_allocator)
	if text, rerr := prim.read_file(vfs, cfile, context.temp_allocator); rerr == .None {
		c := strings.trim_space(string(text))
		if len(c) > 0 {
			if c[0] == '/' {
				common = clean_path(c, context.temp_allocator)
			} else {
				j, _ := path_join(dir, c, context.temp_allocator)
				common = clean_path(j, context.temp_allocator)
			}
		}
	}
	g.dir, _ = clone_string(dir, allocator)
	g.common, _ = clone_string(common, allocator)
	return g, true
}

git_dirs_destroy :: proc(g: ^Git_Dirs, allocator := context.allocator) {
	delete(g.dir, allocator)
	delete(g.common, allocator)
	g^ = {}
}

git_head :: proc(vfs: prim.Vfs, g: Git_Dirs, allocator := context.allocator) -> (h: Git_Head, ok: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	p, _ := path_join(g.dir, "HEAD", context.temp_allocator)
	text, err := prim.read_file(vfs, p, context.temp_allocator)
	if err != .None {
		return
	}
	s := strings.trim_space(string(text))
	if !strings.has_prefix(s, "ref:") {
		h.commit, _ = clone_string(s, allocator)
		return h, true
	}
	ref := strings.trim_space(s[4:])
	h.branch, _ = clone_string(ref, allocator)
	commit, found := git_resolve_ref(vfs, g, ref, context.temp_allocator)
	if found {
		h.commit, _ = clone_string(commit, allocator)
	}
	return h, true
}

git_head_destroy :: proc(h: ^Git_Head, allocator := context.allocator) {
	delete(h.branch, allocator)
	delete(h.commit, allocator)
	h^ = {}
}

git_head_equal :: proc(a, b: Git_Head) -> bool {
	return a.branch == b.branch && a.commit == b.commit
}

git_resolve_ref :: proc(vfs: prim.Vfs, g: Git_Dirs, ref: string, allocator := context.allocator) -> (commit: string, found: bool) {
	cur := ref
	for _ in 0 ..< 8 {
		for base in ([]string{g.dir, g.common}) {
			p, _ := path_join(base, cur, context.temp_allocator)
			text, err := prim.read_file(vfs, p, context.temp_allocator)
			if err != .None {
				continue
			}
			s := strings.trim_space(string(text))
			if strings.has_prefix(s, "ref:") {
				cur = strings.trim_space(s[4:])
				break
			}
			out, _ := clone_string(s, allocator)
			return out, true
		}
		packed, _ := path_join(g.common, "packed-refs", context.temp_allocator)
		text, err := prim.read_file(vfs, packed, context.temp_allocator)
		if err != .None {
			return "", false
		}
		s := string(text)
		for line in strings.split_lines_iterator(&s) {
			if len(line) == 0 || line[0] == '#' || line[0] == '^' {
				continue
			}
			sp := strings.index_byte(line, ' ')
			if sp > 0 && strings.trim_space(line[sp + 1:]) == cur {
				out, _ := clone_string(line[:sp], allocator)
				return out, true
			}
		}
		return "", false
	}
	return "", false
}

git_reflog_len :: proc(vfs: prim.Vfs, g: Git_Dirs) -> i64 {
	p, _ := path_join(g.dir, "logs/HEAD", context.temp_allocator)
	st, err := prim.stat(vfs, p)
	if err != .None {
		return 0
	}
	return st.size
}

git_reflog_commits_only :: proc(vfs: prim.Vfs, g: Git_Dirs, from: i64) -> (commits_only: bool, any: bool, rewritten: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	p, _ := path_join(g.dir, "logs/HEAD", context.temp_allocator)
	fd, err := prim.open_file(vfs, p)
	if err != .None {
		return false, false, true
	}
	defer prim.close_file(vfs, fd)
	size, serr := prim.file_size(vfs, fd)
	if serr != .None || size < from {
		return false, false, true
	}
	n := size - from
	if n == 0 {
		return true, false, false
	}
	if n > 1 << 20 {
		return false, true, false
	}
	buf := make([]u8, int(n), context.temp_allocator)
	got, rerr := prim.read_at(vfs, fd, buf, from)
	if rerr != .None {
		return false, true, false
	}
	s := string(buf[:got])
	commits_only = true
	for line in strings.split_lines_iterator(&s) {
		tab := strings.index_byte(line, '\t')
		if tab < 0 {
			continue
		}
		any = true
		msg := line[tab + 1:]
		colon := strings.index_byte(msg, ':')
		action := msg if colon < 0 else msg[:colon]
		if !strings.has_prefix(strings.trim_space(action), "commit") {
			commits_only = false
		}
	}
	return commits_only, any, false
}

git_busy :: proc(vfs: prim.Vfs, g: Git_Dirs) -> bool {
	for name in ([]string{"index.lock", "HEAD.lock"}) {
		p, _ := path_join(g.dir, name, context.temp_allocator)
		if prim.exists(vfs, p) {
			return true
		}
	}
	return false
}

git_operation :: proc(vfs: prim.Vfs, g: Git_Dirs) -> string {
	ops := [?][2]string{{"MERGE_HEAD", "merge"}, {"CHERRY_PICK_HEAD", "cherry-pick"}, {"REVERT_HEAD", "revert"}, {"rebase-merge", "rebase"}, {"rebase-apply", "rebase"}}
	for o in ops {
		p, _ := path_join(g.dir, o[0], context.temp_allocator)
		if prim.exists(vfs, p) {
			return o[1]
		}
	}
	return ""
}

git_index_stamp :: proc(vfs: prim.Vfs, g: Git_Dirs) -> Index_Stamp {
	p, _ := path_join(g.dir, "index", context.temp_allocator)
	st, err := prim.stat(vfs, p)
	if err != .None {
		return {}
	}
	return Index_Stamp{st.mtime_ns, st.size, st.ino}
}

git_signals :: proc(g: Git_Dirs, abs: string) -> bool {
	if path_parent_abs(abs) == g.dir {
		n := path_name(abs)
		return n == "HEAD" || n == "HEAD.lock" || n == "index" || n == "index.lock"
	}
	return abs == g.common || path_under(abs, g.common) && (strings.has_prefix(abs[len(g.common):], "/refs") || abs[len(g.common):] == "/packed-refs")
}

@(private)
path_parent_abs :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	if i <= 0 {
		return "/"
	}
	return p[:i]
}

clean_path :: proc(p: string, allocator := context.allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	rest := p
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "", ".":
		case "..":
			if len(parts) > 0 {
				pop(&parts)
			}
		case:
			append(&parts, part)
		}
	}
	b := strings.builder_make(allocator)
	if len(p) > 0 && p[0] == '/' {
		strings.write_byte(&b, '/')
	}
	for part, i in parts {
		if i > 0 {
			strings.write_byte(&b, '/')
		}
		strings.write_string(&b, part)
	}
	return strings.to_string(b)
}

git_reflog_olds :: proc(vfs: prim.Vfs, g: Git_Dirs, from: i64, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	p, _ := path_join(g.dir, "logs/HEAD", context.temp_allocator)
	fd, err := prim.open_file(vfs, p)
	if err != .None {
		return out[:]
	}
	defer prim.close_file(vfs, fd)
	size, serr := prim.file_size(vfs, fd)
	if serr != .None || size <= from || size - from > 1 << 20 {
		return out[:]
	}
	buf := make([]u8, int(size - from), context.temp_allocator)
	got, rerr := prim.read_at(vfs, fd, buf, from)
	if rerr != .None {
		return out[:]
	}
	text := string(buf[:got])
	for line in strings.split_lines_iterator(&text) {
		sp := strings.index_byte(line, ' ')
		if sp <= 0 {
			continue
		}
		old := line[:sp]
		if strings.trim_left(old, "0") == "" {
			continue
		}
		c, _ := clone_string(old, allocator)
		append(&out, c)
	}
	return out[:]
}

git_special_head :: proc(vfs: prim.Vfs, g: Git_Dirs, name: string, allocator := context.allocator) -> (string, bool) {
	p, _ := path_join(g.dir, name, context.temp_allocator)
	data, err := prim.read_file(vfs, p, context.temp_allocator)
	if err != .None {
		return "", false
	}
	s := strings.trim_space(string(data))
	if len(s) < 40 {
		return "", false
	}
	out, _ := clone_string(s[:min(len(s), 64)], allocator)
	if i := strings.index_any(out, " \n\t"); i >= 0 {
		out = out[:i]
	}
	return out, true
}

git_object_format :: proc(vfs: prim.Vfs, common: string) -> odb.Hash_Format {
	p, _ := path_join(common, "config", context.temp_allocator)
	text, err := prim.read_file(vfs, p, context.temp_allocator)
	if err != .None {
		return .Sha1
	}
	s := string(text)
	for line in strings.split_lines_iterator(&s) {
		l := strings.trim_space(line)
		if !strings.has_prefix(strings.to_lower(l, context.temp_allocator), "objectformat") {
			continue
		}
		if eq := strings.index_byte(l, '='); eq >= 0 && strings.to_lower(strings.trim_space(l[eq + 1:]), context.temp_allocator) == "sha256" {
			return .Sha256
		}
	}
	return .Sha1
}

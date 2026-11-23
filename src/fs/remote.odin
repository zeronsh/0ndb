package fs

import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../odb"
import "../prim"

REMOTE_WALK_MAX :: 20_000
REMOTE_ANCHORS_MAX :: 64
REMOTE_STATE_VERSION :: u8(1)

Git_Remote_Url :: struct {
	name: string,
	url:  string,
}

Remote_Tip :: struct {
	ref:    string,
	commit: odb.Oid,
}

Remote_Update :: struct {
	changed:   bool,
	rewritten: bool,
	tips:      int,
	added:     int,
	format:    odb.Hash_Format,
}

Remote_Reach :: struct {
	data: []u8,
	size: int,
}

git_remote_urls :: proc(vfs: prim.Vfs, g: Git_Dirs, allocator := context.allocator) -> []Git_Remote_Url {
	out := make([dynamic]Git_Remote_Url, allocator)
	path, _ := path_join(g.common, "config", context.temp_allocator)
	text, err := prim.read_file(vfs, path, context.temp_allocator)
	if err != .None {
		return out[:]
	}
	s := string(text)
	section := ""
	for raw in strings.split_lines_iterator(&s) {
		line := strings.trim_space(raw)
		if len(line) == 0 || line[0] == '#' || line[0] == ';' {
			continue
		}
		if line[0] == '[' {
			end := strings.last_index_byte(line, ']')
			if end < 0 {
				section = ""
				continue
			}
			head := strings.trim_space(line[1:end])
			q := strings.index_byte(head, '"')
			if q > 0 && strings.equal_fold(strings.trim_space(head[:q]), "remote") && head[len(head) - 1] == '"' && len(head) > q + 1 {
				section = head[q + 1:len(head) - 1]
			} else {
				section = ""
			}
			continue
		}
		if len(section) == 0 {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 || !strings.equal_fold(strings.trim_space(line[:eq]), "url") {
			continue
		}
		v := strings.trim_space(line[eq + 1:])
		if len(v) >= 2 && v[0] == '"' && v[len(v) - 1] == '"' {
			v = v[1:len(v) - 1]
		}
		if len(v) == 0 {
			continue
		}
		dup := false
		for x in out {
			if x.name == section {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		name, _ := clone_string(section, allocator)
		url, _ := clone_string(v, allocator)
		append(&out, Git_Remote_Url{name, url})
	}
	return out[:]
}

remote_url_public :: proc(url: string, allocator := context.allocator) -> string {
	scheme := strings.index(url, "://")
	if scheme < 0 {
		out, _ := clone_string(url, allocator)
		return out
	}
	rest := url[scheme + 3:]
	slash := strings.index_byte(rest, '/')
	auth := rest if slash < 0 else rest[:slash]
	at := strings.last_index_byte(auth, '@')
	if at < 0 {
		out, _ := clone_string(url, allocator)
		return out
	}
	lower := strings.to_lower(url[:scheme], context.temp_allocator)
	if lower == "ssh" || lower == "git+ssh" || lower == "ssh+git" {
		user := auth[:at]
		if strings.index_byte(user, ':') < 0 {
			out, _ := clone_string(url, allocator)
			return out
		}
		return strings.concatenate({url[:scheme + 3], user[:strings.index_byte(user, ':')], rest[at:]}, allocator)
	}
	return strings.concatenate({url[:scheme + 3], rest[at + 1:]}, allocator)
}

git_remote_tips :: proc(vfs: prim.Vfs, g: Git_Dirs, allocator := context.allocator) -> []Remote_Tip {
	found := make(map[string]odb.Oid, context.temp_allocator)
	packed, _ := path_join(g.common, "packed-refs", context.temp_allocator)
	if text, err := prim.read_file(vfs, packed, context.temp_allocator); err == .None {
		s := string(text)
		for line in strings.split_lines_iterator(&s) {
			if len(line) == 0 || line[0] == '#' || line[0] == '^' {
				continue
			}
			sp := strings.index_byte(line, ' ')
			if sp <= 0 {
				continue
			}
			ref := strings.trim_space(line[sp + 1:])
			if !strings.has_prefix(ref, "refs/remotes/") || strings.has_suffix(ref, "/HEAD") {
				continue
			}
			if oid, _, ok := odb.oid_from_hex(line[:sp]); ok {
				found[ref] = oid
			}
		}
	}
	base, _ := path_join(g.common, "refs/remotes", context.temp_allocator)
	_tips_walk(vfs, base, "refs/remotes", &found, 0)
	keys := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(found) {
		append(&keys, k)
	}
	slice.sort(keys[:])
	out := make([]Remote_Tip, len(keys), allocator)
	for k, i in keys {
		r, _ := clone_string(k, allocator)
		out[i] = Remote_Tip{r, found[k]}
	}
	return out
}

@(private = "file")
_tips_walk :: proc(vfs: prim.Vfs, dir: string, prefix: string, found: ^map[string]odb.Oid, depth: int) {
	if depth > 16 {
		return
	}
	d: prim.Dir
	if prim.dir_open(vfs, &d, dir, context.temp_allocator) != .None {
		return
	}
	defer prim.dir_close(vfs, &d)
	for {
		e, ok, err := prim.dir_next(vfs, &d)
		if !ok || err != .None {
			break
		}
		if e.name == "." || e.name == ".." || strings.has_suffix(e.name, ".lock") {
			continue
		}
		p, _ := path_join(dir, e.name, context.temp_allocator)
		ref := strings.concatenate({prefix, "/", e.name}, context.temp_allocator)
		kind := e.kind
		if kind != .Dir && kind != .File {
			st, serr := prim.stat(vfs, p)
			if serr != .None {
				continue
			}
			kind = st.kind
		}
		if kind == .Dir {
			_tips_walk(vfs, p, ref, found, depth + 1)
			continue
		}
		if e.name == "HEAD" {
			continue
		}
		text, rerr := prim.read_file(vfs, p, context.temp_allocator)
		if rerr != .None {
			continue
		}
		s := strings.trim_space(string(text))
		if oid, _, hok := odb.oid_from_hex(s); hok {
			found[ref] = oid
		}
	}
}

@(private = "file")
Walk_Item :: struct {
	oid:  odb.Oid,
	time: i64,
}

@(private = "file")
_commit_meta :: proc(db: ^odb.Odb, oid: odb.Oid) -> (tree: odb.Oid, parents: []odb.Oid, time: i64, ok: bool) {
	t, data, err := odb.read(db, oid, context.allocator)
	if err != .None {
		return
	}
	defer delete(data, context.allocator)
	if t != .Commit {
		return
	}
	c, cerr := odb.commit_decode(data, db.format, context.temp_allocator)
	if cerr != .None {
		return
	}
	return c.tree, c.parents, c.committer.time, true
}

@(private = "file")
_heap_push :: proc(h: ^[dynamic]Walk_Item, it: Walk_Item) {
	append(h, it)
	i := len(h) - 1
	for i > 0 {
		p := (i - 1) / 2
		if h[p].time >= h[i].time {
			break
		}
		h[p], h[i] = h[i], h[p]
		i = p
	}
}

@(private = "file")
_heap_pop :: proc(h: ^[dynamic]Walk_Item) -> Walk_Item {
	top := h[0]
	last := pop(h)
	if len(h) > 0 {
		h[0] = last
		i := 0
		for {
			l := 2 * i + 1
			r := l + 1
			m := i
			if l < len(h) && h[l].time > h[m].time {
				m = l
			}
			if r < len(h) && h[r].time > h[m].time {
				m = r
			}
			if m == i {
				break
			}
			h[m], h[i] = h[i], h[m]
			i = m
		}
	}
	return top
}

remote_merge_base :: proc(db: ^odb.Odb, a, b: odb.Oid) -> (base: odb.Oid, found: bool) {
	if a == b {
		return a, true
	}
	flags := make(map[odb.Oid]u8, context.temp_allocator)
	times := make(map[odb.Oid]i64, context.temp_allocator)
	heap := make([dynamic]Walk_Item, context.temp_allocator)
	for x, i in ([2]odb.Oid{a, b}) {
		_, _, t, ok := _commit_meta(db, x)
		if !ok {
			return {}, false
		}
		times[x] = t
		flags[x] |= u8(1) << u8(i)
		_heap_push(&heap, Walk_Item{x, t})
	}
	for pops := 0; len(heap) > 0 && pops < REMOTE_WALK_MAX; pops += 1 {
		it := _heap_pop(&heap)
		f := flags[it.oid]
		if f & 3 == 3 {
			return it.oid, true
		}
		_, parents, _, ok := _commit_meta(db, it.oid)
		if !ok {
			continue
		}
		for p in parents {
			pf, seen := flags[p]
			nf := pf | f
			if seen && nf == pf {
				continue
			}
			flags[p] = nf
			t, known := times[p]
			if !known {
				_, _, pt, pok := _commit_meta(db, p)
				if !pok {
					continue
				}
				t = pt
				times[p] = t
			}
			_heap_push(&heap, Walk_Item{p, t})
		}
	}
	return {}, false
}

@(private = "file")
_head_advanced :: proc(db: ^odb.Odb, old, new: odb.Oid) -> bool {
	if old == {} || new == {} {
		return false
	}
	frontier := make([dynamic]odb.Oid, context.temp_allocator)
	append(&frontier, new)
	for steps := 0; len(frontier) > 0 && steps < 256; steps += 1 {
		c := pop(&frontier)
		if c == old {
			return true
		}
		_, parents, _, ok := _commit_meta(db, c)
		if ok {
			append(&frontier, ..parents)
		}
	}
	return false
}

remote_is_ancestor :: proc(db: ^odb.Odb, x, y: odb.Oid) -> bool {
	b, ok := remote_merge_base(db, x, y)
	return ok && b == x
}

@(private = "file")
Remote_State :: struct {
	format:  odb.Hash_Format,
	head:    odb.Oid,
	tips:    [dynamic]Remote_Tip,
	anchors: [dynamic]odb.Oid,
}

@(private = "file")
_state_read :: proc(vfs: prim.Vfs, dir: string) -> (st: Remote_State, ok: bool) {
	st.tips = make([dynamic]Remote_Tip, context.temp_allocator)
	st.anchors = make([dynamic]odb.Oid, context.temp_allocator)
	p, _ := path_join(dir, "state", context.temp_allocator)
	data, err := prim.read_file(vfs, p, context.temp_allocator)
	if err != .None {
		return
	}
	rd := prim.reader(data)
	if prim.read_u8(&rd) != REMOTE_STATE_VERSION {
		return
	}
	f := prim.read_u8(&rd)
	if f > u8(max(odb.Hash_Format)) {
		return
	}
	st.format = odb.Hash_Format(f)
	n := odb.oid_size(st.format)
	prim.read_fixed(&rd, st.head[:n])
	nt := prim.read_uvarint(&rd)
	if nt > u64(len(data)) {
		return
	}
	for _ in 0 ..< nt {
		t: Remote_Tip
		t.ref = prim.read_str(&rd)
		prim.read_fixed(&rd, t.commit[:n])
		append(&st.tips, t)
	}
	na := prim.read_uvarint(&rd)
	if na > u64(len(data)) {
		return
	}
	for _ in 0 ..< na {
		a: odb.Oid
		prim.read_fixed(&rd, a[:n])
		append(&st.anchors, a)
	}
	return st, prim.reader_ok(&rd)
}

@(private = "file")
_state_write :: proc(vfs: prim.Vfs, dir: string, st: ^Remote_State) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	n := odb.oid_size(st.format)
	prim.write_u8(&w, REMOTE_STATE_VERSION)
	prim.write_u8(&w, u8(st.format))
	prim.write_raw(&w, st.head[:n])
	prim.write_uvarint(&w, u64(len(st.tips)))
	for &t in st.tips {
		prim.write_str(&w, t.ref)
		prim.write_raw(&w, t.commit[:n])
	}
	prim.write_uvarint(&w, u64(len(st.anchors)))
	for &a in st.anchors {
		prim.write_raw(&w, a[:n])
	}
	p, _ := path_join(dir, "state", context.temp_allocator)
	return from_prim(prim.replace_atomic(vfs, p, buf[:]))
}

remote_reach_load :: proc(vfs: prim.Vfs, dir: string, format: odb.Hash_Format, allocator := context.allocator) -> (r: Remote_Reach, ok: bool) {
	p, _ := path_join(dir, "oids", context.temp_allocator)
	data, err := prim.read_file(vfs, p, allocator)
	n := odb.oid_size(format)
	if err != .None || len(data) % n != 0 {
		if err == .None {
			delete(data, allocator)
		}
		return {}, false
	}
	return Remote_Reach{data, n}, true
}

remote_reach_has :: proc(r: ^Remote_Reach, oid: odb.Oid) -> bool {
	if r.size == 0 {
		return false
	}
	o := oid
	key := o[:r.size]
	lo, hi := 0, len(r.data) / r.size
	for lo < hi {
		mid := (lo + hi) / 2
		c := _cmp(r.data[mid * r.size:][:r.size], key)
		if c == 0 {
			return true
		}
		if c < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return false
}

@(private = "file")
_cmp :: proc "contextless" (a, b: []u8) -> int {
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return -1 if a[i] < b[i] else 1
		}
	}
	return 0
}

remote_update :: proc(vfs: prim.Vfs, db: ^odb.Odb, g: Git_Dirs, dir: string) -> (u: Remote_Update, err: Error) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 1 << 20) != nil {
		return u, .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	format := git_object_format(vfs, g.common)
	u.format = format
	if db == nil || db.format != format {
		return u, .Unsupported
	}
	from_prim(prim.mkdir_all(vfs, dir, 0o700)) or_return
	head: odb.Oid
	if h, ok := git_head(vfs, g, context.temp_allocator); ok {
		if oid, _, hok := odb.oid_from_hex(h.commit); hok {
			head = oid
		}
	}
	tips := git_remote_tips(vfs, g, context.temp_allocator)
	u.tips = len(tips)
	old, had := _state_read(vfs, dir)
	if had && old.format == format && old.head == head && len(old.tips) == len(tips) {
		same := true
		for t, i in tips {
			if t.ref != old.tips[i].ref || t.commit != old.tips[i].commit {
				same = false
				break
			}
		}
		if same {
			return u, .None
		}
	}
	u.changed = true
	if had && old.format == format {
		for ot in old.tips {
			still := false
			for t in tips {
				if t.ref != ot.ref {
					continue
				}
				still = t.commit == ot.commit || remote_is_ancestor(db, ot.commit, t.commit)
				break
			}
			if !still {
				u.rewritten = true
				break
			}
		}
	}
	advanced := had && !u.rewritten && old.format == format && (old.head == head || _head_advanced(db, old.head, head))
	fresh := make([dynamic]odb.Oid, context.temp_allocator)
	for t in tips {
		append(&fresh, t.commit)
		if head == {} {
			continue
		}
		if advanced {
			known := false
			for ot in old.tips {
				if ot.ref == t.ref && ot.commit == t.commit {
					known = true
					break
				}
			}
			if known {
				continue
			}
		}
		if b, ok := remote_merge_base(db, head, t.commit); ok {
			append(&fresh, b)
		}
	}
	st := Remote_State {
		format  = format,
		head    = head,
		tips    = make([dynamic]Remote_Tip, context.temp_allocator),
		anchors = make([dynamic]odb.Oid, context.temp_allocator),
	}
	append(&st.tips, ..tips)
	if had && !u.rewritten && old.format == format {
		append(&st.anchors, ..old.anchors[:])
	}
	existing: Remote_Reach
	if !u.rewritten {
		existing, _ = remote_reach_load(vfs, dir, format, context.temp_allocator)
	}
	existing.size = odb.oid_size(format)
	added := make(map[odb.Oid]bool, context.temp_allocator)
	for a in fresh {
		dup := false
		for x in st.anchors {
			if x == a {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		append(&st.anchors, a)
		tree, _, _, ok := _commit_meta(db, a)
		if ok {
			_reach_walk(db, tree, &existing, &added)
		}
	}
	if len(st.anchors) > REMOTE_ANCHORS_MAX {
		remove_range(&st.anchors, 0, len(st.anchors) - REMOTE_ANCHORS_MAX)
	}
	u.added = len(added)
	if len(added) > 0 || u.rewritten {
		_reach_write(vfs, dir, &existing, &added) or_return
	}
	_state_write(vfs, dir, &st) or_return
	return u, .None
}

@(private = "file")
_reach_walk :: proc(db: ^odb.Odb, root: odb.Oid, have: ^Remote_Reach, added: ^map[odb.Oid]bool) {
	stack := make([dynamic]odb.Oid, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		t := pop(&stack)
		if added[t] || remote_reach_has(have, t) {
			continue
		}
		typ, data, err := odb.read(db, t, context.temp_allocator)
		if err != .None || typ != .Tree {
			continue
		}
		added[t] = true
		it := odb.tree_iter(data, db.format)
		for e in odb.tree_next(&it) {
			switch e.mode {
			case 0o40000:
				append(&stack, e.oid)
			case 0o160000:
			case:
				if !added[e.oid] && !remote_reach_has(have, e.oid) {
					added[e.oid] = true
				}
			}
		}
	}
}

@(private = "file")
_reach_write :: proc(vfs: prim.Vfs, dir: string, have: ^Remote_Reach, added: ^map[odb.Oid]bool) -> Error {
	n := have.size
	fresh := make([dynamic]odb.Oid, 0, len(added), context.temp_allocator)
	for k in prim.sorted_keys(added^) {
		append(&fresh, k)
	}
	slice.sort_by(fresh[:], proc(a, b: odb.Oid) -> bool {
		x, y := a, b
		return _cmp(x[:], y[:]) < 0
	})
	total := len(have.data) / n + len(fresh)
	out := make([]u8, total * n, context.temp_allocator)
	i, j, k := 0, 0, 0
	old := len(have.data) / n
	for i < old || j < len(fresh) {
		take_old := j >= len(fresh)
		if i < old && j < len(fresh) {
			f := fresh[j]
			take_old = _cmp(have.data[i * n:][:n], f[:n]) < 0
		}
		if take_old {
			copy(out[k * n:][:n], have.data[i * n:][:n])
			i += 1
		} else {
			f := fresh[j]
			copy(out[k * n:][:n], f[:n])
			j += 1
		}
		k += 1
	}
	p, _ := path_join(dir, "oids", context.temp_allocator)
	return from_prim(prim.replace_atomic(vfs, p, out[:k * n]))
}

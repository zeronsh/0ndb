package fs

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "../prim"

PLAIN_DEFAULTS :: [?]string {
	"node_modules/",
	".venv/",
	"__pycache__/",
	"*.pyc",
	"*.pyo",
	".pytest_cache/",
	".mypy_cache/",
	".ruff_cache/",
	".tox/",
	".nox/",
	".hypothesis/",
	".ipynb_checkpoints/",
	".next/",
	".nuxt/",
	".svelte-kit/",
	".turbo/",
	".parcel-cache/",
	".sass-cache/",
	".gradle/",
	".dart_tool/",
	".pnpm-store/",
	".terraform/",
	".Trash/",
	".Trashes/",
	".Spotlight-V100/",
	".fseventsd/",
	".TemporaryItems/",
	".DocumentRevisions-V100/",
	".DS_Store",
	"Thumbs.db",
	"ehthumbs.db",
}

IGNORE_FILE_MAX :: 100 * 1024 * 1024

Ignore_Pattern_Kind :: enum u8 {
	Name_Literal,
	Name_Suffix,
	Name_Glob,
	Path_Literal,
	Path_Glob,
}

Ignore_Pattern :: struct {
	text:     string,
	prefix:   int,
	grams:    u64,
	need_off: u32,
	need_len: u32,
	kind:     Ignore_Pattern_Kind,
	negate:   bool,
	dir:      bool,
	last:     u8,
	first:    u8,
	tail:     u8,
}

Ignore_Key_Tag :: enum u8 {
	Byte,
	Name,
	Path,
	Comp,
}

Ignore_Slot :: struct {
	hash:  u64,
	start: u32,
	count: u32,
}

Rules :: struct {
	base:      string,
	patterns:  []Ignore_Pattern,
	offsets:   ^[RULES_KEYS + 1]u32,
	slots:     []Ignore_Slot,
	index:     []u32,
	name_lens: u64,
	path_lens: u64,
	comp_lens: u64,
	size:      int,
}

@(private = "file")
RULES_INDEX_MIN :: 16

@(private = "file")
RULES_KEYS :: 3 * 256 + 1

Ignore_Chain :: struct {
	rules:  ^Rules,
	parent: ^Ignore_Chain,
}

Ignore :: struct {
	vfs:         prim.Vfs,
	excludes:    ^Rules,
	global:      ^Rules,
	defaults:    ^Rules,
	ignore_case: bool,
	git:         Git_Settings,
	allocator:   runtime.Allocator,
}

rules_parse :: proc(text: []u8, base: string, allocator := context.allocator) -> (r: ^Rules, err: Error) {
	start := 0
	if len(text) >= 3 && text[0] == 0xEF && text[1] == 0xBB && text[2] == 0xBF {
		start = 3
	}
	count := 0
	bytes := len(base)
	pos := start
	for {
		p, ok := ignore_next_pattern(text, &pos)
		if !ok {
			break
		}
		count += 1
		bytes += len(p.text)
	}
	if count == 0 {
		return nil, .None
	}
	indexed := count >= RULES_INDEX_MIN
	nslots := 0
	if indexed {
		hashed := 0
		pos = start
		for {
			p, ok := ignore_next_pattern(text, &pos)
			if !ok {
				break
			}
			if tag, _, _ := ignore_key(&p); tag != .Byte {
				hashed += 1
			}
		}
		if hashed > 0 {
			nslots = 4
			for nslots < 2 * hashed {
				nslots *= 2
			}
		}
	}
	pat_off := mem.align_forward_int(size_of(Rules), align_of(Ignore_Pattern))
	slots_off := mem.align_forward_int(pat_off + count * size_of(Ignore_Pattern), align_of(Ignore_Slot))
	offsets_off := slots_off + nslots * size_of(Ignore_Slot)
	index_off := offsets_off + (size_of([RULES_KEYS + 1]u32) if indexed else 0)
	text_off := index_off + (count * size_of(u32) if indexed else 0)
	size := text_off + bytes
	block, aerr := mem.alloc_bytes(size, align_of(Rules), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	r = (^Rules)(raw_data(block))
	r.size = size
	r.patterns = mem.slice_ptr((^Ignore_Pattern)(raw_data(block[pat_off:])), count)
	buf := block[text_off:]
	n := copy(buf, base)
	r.base = string(buf[:n])
	pos = start
	for i in 0 ..< count {
		p, _ := ignore_next_pattern(text, &pos)
		m := copy(buf[n:], p.text)
		p.text = string(buf[n:n + m])
		n += m
		r.patterns[i] = p
	}
	if indexed {
		r.offsets = (^[RULES_KEYS + 1]u32)(raw_data(block[offsets_off:]))
		r.index = mem.slice_ptr((^u32)(raw_data(block[index_off:])), count)
		if nslots > 0 {
			r.slots = mem.slice_ptr((^Ignore_Slot)(raw_data(block[slots_off:])), nslots)
		}
		ignore_build_index(r)
	}
	return r, .None
}

@(private = "file")
ignore_build_index :: proc "contextless" (r: ^Rules) {
	for &p in r.patterns {
		tag, key, n := ignore_key(&p)
		if tag == .Byte {
			r.offsets[key + 1] += 1
		} else {
			slot := ignore_slot(r.slots, key)
			slot.hash = key
			slot.count += 1
			bit := ignore_len_bit(n)
			switch tag {
			case .Name:
				r.name_lens |= bit
			case .Path:
				r.path_lens |= bit
			case .Comp:
				r.comp_lens |= bit
			case .Byte:
			}
		}
	}
	for k in 1 ..= RULES_KEYS {
		r.offsets[k] += r.offsets[k - 1]
	}
	next := r.offsets[RULES_KEYS]
	for &slot in r.slots {
		if slot.hash != 0 {
			slot.start = next
			next += slot.count
		}
	}
	fill: [RULES_KEYS]u32 = ---
	copy(fill[:], r.offsets[:RULES_KEYS])
	for i := len(r.patterns) - 1; i >= 0; i -= 1 {
		tag, key, _ := ignore_key(&r.patterns[i])
		if tag == .Byte {
			r.index[fill[key]] = u32(i)
			fill[key] += 1
		} else {
			slot := ignore_slot(r.slots, key)
			r.index[slot.start] = u32(i)
			slot.start += 1
		}
	}
	for &slot in r.slots {
		slot.start -= slot.count
	}
}

@(private = "file")
ignore_key :: proc "contextless" (p: ^Ignore_Pattern) -> (tag: Ignore_Key_Tag, key: u64, n: int) {
	#partial switch p.kind {
	case .Name_Literal:
		return .Name, ignore_hash(p.text, .Name), len(p.text)
	case .Path_Literal:
		return .Path, ignore_hash(p.text, .Path), len(p.text)
	case .Path_Glob:
		for i := p.prefix - 1; i >= 0; i -= 1 {
			if p.text[i] == '/' {
				return .Comp, ignore_hash(p.text[:i], .Comp), i
			}
		}
	}
	if p.last != 0 {
		return .Byte, u64(p.last), 0
	}
	if p.prefix > 0 {
		return .Byte, (256 if p.kind < .Path_Literal else 512) + u64(p.first), 0
	}
	return .Byte, RULES_KEYS - 1, 0
}

@(private = "file")
ignore_hash :: proc "contextless" (s: string, tag: Ignore_Key_Tag) -> u64 {
	head, tail: u64
	n := len(s)
	if n >= 8 {
		head = intrinsics.unaligned_load((^u64)(raw_data(s)))
		tail = intrinsics.unaligned_load((^u64)(raw_data(s[n - 8:])))
	} else {
		for i in 0 ..< n {
			head |= u64(s[i]) << (8 * uint(i))
		}
	}
	h := (head | 0x2020202020202020) * 0x9e3779b97f4a7c15
	h ~= (tail | 0x2020202020202020) * 0xc2b2ae3d27d4eb4f
	h ~= (u64(n) << 8 | u64(tag)) * 0x165667b19e3779f9
	h ~= h >> 32
	return h | 1
}

@(private = "file")
ignore_slot :: proc "contextless" (slots: []Ignore_Slot, key: u64) -> ^Ignore_Slot {
	mask := u64(len(slots) - 1)
	i := (key ~ (key >> 29)) & mask
	for slots[i].hash != 0 && slots[i].hash != key {
		i = (i + 1) & mask
	}
	return &slots[i]
}

rules_destroy :: proc(r: ^Rules, allocator := context.allocator) {
	if r == nil {
		return
	}
	_ = mem.free_with_size(r, r.size, allocator)
}

ignore_init :: proc(ig: ^Ignore, vfs: prim.Vfs, git_dir, common_dir: string, plain: bool, allocator := context.allocator) -> Error {
	ig^ = Ignore {
		vfs       = vfs,
		allocator = allocator,
	}
	err := ignore_load(ig, git_dir, common_dir, plain)
	if err != .None {
		ignore_destroy(ig)
	}
	return err
}

ignore_destroy :: proc(ig: ^Ignore) {
	if ig == nil {
		return
	}
	rules_destroy(ig.excludes, ig.allocator)
	rules_destroy(ig.global, ig.allocator)
	rules_destroy(ig.defaults, ig.allocator)
	git_settings_destroy(&ig.git, ig.allocator)
	ig.excludes = nil
	ig.global = nil
	ig.defaults = nil
}

ignore_match :: proc(ig: ^Ignore, chain: ^Ignore_Chain, rel: string, is_dir: bool) -> bool {
	if len(rel) == 0 {
		return false
	}
	q := Ignore_Query {
		rel    = rel,
		name   = path_name(rel),
		last   = ignore_lower(rel[len(rel) - 1]),
		is_dir = is_dir,
		fold   = ig != nil && ig.ignore_case,
	}
	for c := chain; c != nil; c = c.parent {
		if decided, ignored := ignore_decide(c.rules, &q); decided {
			return ignored
		}
	}
	if ig == nil {
		return false
	}
	if decided, ignored := ignore_decide(ig.excludes, &q); decided {
		return ignored
	}
	if decided, ignored := ignore_decide(ig.global, &q); decided {
		return ignored
	}
	if decided, ignored := ignore_decide(ig.defaults, &q); decided {
		return ignored
	}
	return false
}

ignore_path :: proc(ig: ^Ignore, root: string, rel: string, is_dir: bool) -> bool {
	if len(rel) == 0 {
		return false
	}
	return ignore_path_walk(ig, root, rel, 0, nil, is_dir)
}

@(private = "file")
ignore_path_walk :: proc(ig: ^Ignore, root, rel: string, start: int, parent: ^Ignore_Chain, is_dir: bool) -> bool {
	dir := rel[:start - 1] if start > 0 else ""
	rules := ignore_read_gitignore(ig.vfs if ig != nil else prim.os_vfs(), root, dir)
	defer rules_destroy(rules, context.temp_allocator)
	node := Ignore_Chain {
		rules  = rules,
		parent = parent,
	}
	chain := &node if rules != nil else parent
	slash := ignore_index_byte(rel[start:], '/')
	if slash < 0 {
		return ignore_match(ig, chain, rel, is_dir)
	}
	if ignore_match(ig, chain, rel[:start + slash], true) {
		return true
	}
	return ignore_path_walk(ig, root, rel, start + slash + 1, chain, is_dir)
}

@(private = "file")
ignore_read_gitignore :: proc(vfs: prim.Vfs, root, dir: string) -> ^Rules {
	buf: prim.Path_Buf = ---
	path, ok := path_join_buf(buf[:], root, dir, ".gitignore")
	if !ok {
		return nil
	}
	if st, serr := prim.lstat(vfs, path); serr != .None || st.kind == .Symlink {
		return nil
	}
	data, err := ignore_read(vfs, path, IGNORE_FILE_MAX, context.temp_allocator)
	if err != .None {
		return nil
	}
	defer delete(data, context.temp_allocator)
	r, _ := rules_parse(data, dir, context.temp_allocator)
	return r
}

@(private = "file")
Ignore_Query :: struct {
	rel:    string,
	name:   string,
	sub:    string,
	grams:  u64,
	last:   u8,
	is_dir: bool,
	fold:   bool,
	graded: bool,
}

@(private = "file")
ignore_decide :: proc "contextless" (r: ^Rules, q: ^Ignore_Query) -> (decided, ignored: bool) {
	if r == nil {
		return
	}
	q.sub = q.rel
	if len(r.base) > 0 {
		if len(q.rel) <= len(r.base) || q.rel[len(r.base)] != '/' || !ignore_equal(q.rel[:len(r.base)], r.base, q.fold) {
			return
		}
		q.sub = q.rel[len(r.base) + 1:]
	}
	if r.offsets == nil {
		name_first := ignore_lower(q.name[0])
		sub_first := ignore_lower(q.sub[0])
		for i := len(r.patterns) - 1; i >= 0; i -= 1 {
			p := &r.patterns[i]
			if p.dir && !q.is_dir {
				continue
			}
			if p.last != 0 {
				if p.last != q.last {
					continue
				}
			} else if p.prefix > 0 && p.first != (name_first if p.kind < .Path_Literal else sub_first) {
				continue
			}
			if ignore_try(p, q) {
				return true, !p.negate
			}
		}
		return
	}
	best := -1
	ignore_scan(r, ignore_byte_list(r, RULES_KEYS - 1), &best, q)
	ignore_scan(r, ignore_byte_list(r, int(q.last)), &best, q)
	ignore_scan(r, ignore_byte_list(r, 256 + int(ignore_lower(q.name[0]))), &best, q)
	ignore_scan(r, ignore_byte_list(r, 512 + int(ignore_lower(q.sub[0]))), &best, q)
	if r.name_lens & ignore_len_bit(len(q.name)) != 0 {
		ignore_scan(r, ignore_hash_list(r, q.name, .Name), &best, q)
	}
	if r.path_lens & ignore_len_bit(len(q.sub)) != 0 {
		ignore_scan(r, ignore_hash_list(r, q.sub, .Path), &best, q)
	}
	if r.comp_lens != 0 {
		lens := r.comp_lens
		if len(q.sub) <= 63 {
			lens &= (u64(1) << uint(len(q.sub))) - 1
		}
		for lens != 0 {
			i := int(intrinsics.count_trailing_zeros(lens))
			lens &= lens - 1
			if i < 63 {
				if q.sub[i] == '/' {
					ignore_scan(r, ignore_hash_list(r, q.sub[:i], .Comp), &best, q)
				}
				continue
			}
			for j in 63 ..< len(q.sub) {
				if q.sub[j] == '/' {
					ignore_scan(r, ignore_hash_list(r, q.sub[:j], .Comp), &best, q)
				}
			}
		}
	}
	if best < 0 {
		return
	}
	return true, !r.patterns[best].negate
}

@(private = "file")
ignore_len_bit :: #force_inline proc "contextless" (n: int) -> u64 {
	return u64(1) << uint(min(n, 63))
}

@(private = "file")
ignore_byte_list :: #force_inline proc "contextless" (r: ^Rules, key: int) -> []u32 {
	return r.index[r.offsets[key]:r.offsets[key + 1]]
}

@(private = "file")
ignore_hash_list :: #force_inline proc "contextless" (r: ^Rules, s: string, tag: Ignore_Key_Tag) -> []u32 {
	slot := ignore_slot(r.slots, ignore_hash(s, tag))
	return r.index[slot.start:][:slot.count]
}

@(private = "file")
ignore_scan :: proc "contextless" (r: ^Rules, list: []u32, best: ^int, q: ^Ignore_Query) {
	for i in list {
		if int(i) <= best^ {
			return
		}
		p := &r.patterns[i]
		if !(p.dir && !q.is_dir) && ignore_try(p, q) {
			best^ = int(i)
			return
		}
	}
}

@(private = "file")
ignore_try :: proc "contextless" (p: ^Ignore_Pattern, q: ^Ignore_Query) -> bool {
	switch p.kind {
	case .Name_Literal:
		return len(q.name) == len(p.text) && ignore_equal(q.name, p.text, q.fold)
	case .Name_Suffix:
		suffix := p.text[1:]
		return len(q.name) >= len(suffix) && ignore_equal(q.name[len(q.name) - len(suffix):], suffix, q.fold)
	case .Path_Literal:
		return len(q.sub) == len(p.text) && ignore_equal(q.sub, p.text, q.fold)
	case .Name_Glob, .Path_Glob:
		if p.tail != 0 && ignore_lower(q.name[0]) != p.tail {
			return false
		}
		text := q.name if p.kind == .Name_Glob else q.sub
		if p.prefix > len(text) || !ignore_equal(text[:p.prefix], p.text[:p.prefix], q.fold) {
			return false
		}
		pattern := p.text[p.prefix:]
		text = text[p.prefix:]
		if p.kind == .Path_Glob && len(pattern) == 0 && len(text) == 0 {
			return true
		}
		if p.grams != 0 {
			if !q.graded {
				q.grams = ignore_grams(q.rel)
				q.graded = true
			}
			if q.grams & p.grams != p.grams {
				return false
			}
		}
		if p.need_len > 0 && !ignore_contains(text, p.text[p.need_off:][:p.need_len], q.fold) {
			return false
		}
		return wild_do(pattern, 0, text, 0, p.kind == .Path_Glob, q.fold) == .Match
	}
	return false
}

@(private = "file")
ignore_grams :: proc "contextless" (s: string) -> (grams: u64) {
	for i in 1 ..< len(s) {
		grams |= u64(1) << ignore_gram(s[i - 1], s[i])
	}
	return
}

@(private = "file")
ignore_gram :: #force_inline proc "contextless" (a, b: u8) -> uint {
	return uint(((a | 0x20) ~ ((b | 0x20) << 2)) & 63)
}

@(private = "file")
ignore_next_pattern :: proc "contextless" (text: []u8, pos: ^int) -> (p: Ignore_Pattern, ok: bool) {
	for pos^ < len(text) {
		start := pos^
		end := start
		for end < len(text) && text[end] != '\n' {
			end += 1
		}
		pos^ = end + 1
		if end == start || text[start] == '#' {
			continue
		}
		line := text[start:end]
		if line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		for c, i in line {
			if c == 0 {
				line = line[:i]
				break
			}
		}
		if p, ok = ignore_compile(ignore_trim(string(line))); ok {
			return
		}
	}
	return
}

@(private = "file")
ignore_trim :: proc "contextless" (s: string) -> string {
	last_space := -1
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case ' ':
			if last_space < 0 {
				last_space = i
			}
		case '\\':
			i += 1
			if i >= len(s) {
				return s
			}
			last_space = -1
		case:
			last_space = -1
		}
	}
	if last_space >= 0 {
		return s[:last_space]
	}
	return s
}

@(private = "file")
ignore_compile :: proc "contextless" (line: string) -> (p: Ignore_Pattern, ok: bool) {
	s := line
	if len(s) > 0 && s[0] == '!' {
		p.negate = true
		s = s[1:]
	}
	full := s
	if len(s) > 0 && s[len(s) - 1] == '/' {
		p.dir = true
		s = s[:len(s) - 1]
	}
	if len(s) == 0 {
		return
	}
	prefix := min(ignore_simple_len(full), len(s))
	if ignore_index_byte(s, '/') < 0 {
		switch {
		case prefix == len(s):
			p.kind = .Name_Literal
		case full[0] == '*' && ignore_simple_len(full[1:]) == len(full) - 1:
			p.kind = .Name_Suffix
		case:
			p.kind = .Name_Glob
		}
	} else {
		if s[0] == '/' {
			s = s[1:]
			prefix -= 1
		}
		if len(s) == 0 {
			return
		}
		p.kind = .Path_Literal if prefix == len(s) else .Path_Glob
	}
	last, never := ignore_last_byte(s)
	if never {
		return
	}
	p.text = s
	p.prefix = prefix
	p.last = last
	p.first = ignore_lower(s[0])
	if p.kind == .Name_Glob || p.kind == .Path_Glob {
		off, n := ignore_longest_run(s, prefix)
		p.need_off = u32(off)
		p.need_len = u32(n)
		for i in off + 1 ..< off + n {
			p.grams |= u64(1) << ignore_gram(s[i - 1], s[i])
		}
	}
	if p.kind == .Path_Glob && ignore_index_byte(s, '\\') < 0 && !ignore_has_prefix(s[prefix:], "**") && !(len(s) >= 2 && s[len(s) - 2:] == "**") {
		seg := 0
		for i := 0; i < len(s); i += 1 {
			switch s[i] {
			case '/':
				seg = i + 1
			case '[':
				_, end, _ := wild_class(s, i, 0, false)
				i = end
			}
		}
		if seg < len(s) && !ignore_glob_special(s[seg]) {
			p.tail = ignore_lower(s[seg])
		}
	}
	return p, true
}

@(private = "file")
ignore_longest_run :: proc "contextless" (s: string, from: int) -> (off, n: int) {
	i := from
	run := i
	for i <= len(s) {
		c := wild_at(s, i)
		if c == 0 || c == '/' || ignore_glob_special(c) {
			if i - run > n {
				off, n = run, i - run
			}
			switch c {
			case 0:
				return
			case '\\':
				i += 2
			case '[':
				_, end, _ := wild_class(s, i, 0, false)
				i = end + 1
			case:
				i += 1
			}
			run = i
			continue
		}
		i += 1
	}
	return
}

@(private = "file")
ignore_contains :: proc "contextless" (hay, needle: string, fold: bool) -> bool {
	if len(needle) > len(hay) {
		return false
	}
	c := ignore_lower(needle[0])
	for i in 0 ..= len(hay) - len(needle) {
		if ignore_lower(hay[i]) == c && ignore_equal(hay[i:i + len(needle)], needle, fold) {
			return true
		}
	}
	return false
}

@(private = "file")
ignore_last_byte :: proc "contextless" (s: string) -> (last: u8, never: bool) {
	i := 0
	for i < len(s) {
		switch s[i] {
		case '\\':
			if i + 1 >= len(s) {
				return 0, true
			}
			last = s[i + 1]
			i += 2
		case '*', '?':
			last = 0
			i += 1
		case '[':
			_, end, abort := wild_class(s, i, 0, false)
			if abort {
				return 0, true
			}
			last = 0
			i = end + 1
		case:
			last = s[i]
			i += 1
		}
	}
	return ignore_lower(last), false
}

@(private = "file")
ignore_simple_len :: proc "contextless" (s: string) -> int {
	for i in 0 ..< len(s) {
		if ignore_glob_special(s[i]) {
			return i
		}
	}
	return len(s)
}

@(private = "file")
ignore_glob_special :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == '*' || c == '?' || c == '[' || c == '\\'
}

@(private = "file")
ignore_lower :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c + 32 if c >= 'A' && c <= 'Z' else c
}

@(private = "file")
ignore_equal :: proc "contextless" (a, b: string, fold: bool) -> bool {
	if len(a) != len(b) {
		return false
	}
	if !fold {
		return a == b
	}
	for i in 0 ..< len(a) {
		if ignore_lower(a[i]) != ignore_lower(b[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
ignore_index_byte :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

@(private = "file")
ignore_has_prefix :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

@(private)
Wild_Result :: enum u8 {
	Match,
	No_Match,
	Abort_All,
	Abort_To_Star_Star,
}

@(private = "file")
wild_at :: #force_inline proc "contextless" (s: string, i: int) -> u8 {
	return s[i] if i < len(s) else 0
}

@(private)
wild_do :: proc "contextless" (pat: string, p0: int, text: string, t0: int, pathname, fold: bool) -> Wild_Result {
	p, t := p0, t0
	for ; p < len(pat); p, t = p + 1, t + 1 {
		p_ch := pat[p]
		t_ch := wild_at(text, t)
		if t_ch == 0 && p_ch != '*' {
			return .Abort_All
		}
		if fold {
			t_ch = ignore_lower(t_ch)
			p_ch = ignore_lower(p_ch)
		}
		switch p_ch {
		case '\\':
			p += 1
			if wild_at(pat, p) != t_ch {
				return .No_Match
			}
		case '?':
			if pathname && t_ch == '/' {
				return .No_Match
			}
		case '[':
			hit, end, abort := wild_class(pat, p, t_ch, fold)
			if abort {
				return .Abort_All
			}
			if !hit || (pathname && t_ch == '/') {
				return .No_Match
			}
			p = end
		case '*':
			match_slash: bool
			p += 1
			if wild_at(pat, p) == '*' {
				prev := p - 2
				p += 1
				for wild_at(pat, p) == '*' {
					p += 1
				}
				c := wild_at(pat, p)
				if (prev < p0 || pat[prev] == '/') && (c == 0 || c == '/' || (c == '\\' && wild_at(pat, p + 1) == '/')) {
					if c == '/' && wild_do(pat, p + 1, text, t, pathname, fold) == .Match {
						return .Match
					}
					match_slash = true
				}
			} else {
				match_slash = !pathname
			}
			if p >= len(pat) {
				if !match_slash && ignore_index_byte(text[t:], '/') >= 0 {
					return .No_Match
				}
				return .Match
			}
			if !match_slash && pat[p] == '/' {
				slash := ignore_index_byte(text[t:], '/')
				if slash < 0 {
					return .No_Match
				}
				t += slash
				continue
			}
			for t_ch != 0 {
				c := pat[p]
				if !ignore_glob_special(c) {
					if fold {
						c = ignore_lower(c)
					}
					for {
						t_ch = wild_at(text, t)
						if t_ch == 0 || (!match_slash && t_ch == '/') {
							break
						}
						if fold {
							t_ch = ignore_lower(t_ch)
						}
						if t_ch == c {
							break
						}
						t += 1
					}
					if t_ch != c {
						return .No_Match
					}
				}
				m := wild_do(pat, p, text, t, pathname, fold)
				if m != .No_Match {
					if !match_slash || m != .Abort_To_Star_Star {
						return m
					}
				} else if !match_slash && t_ch == '/' {
					return .Abort_To_Star_Star
				}
				t += 1
				t_ch = wild_at(text, t)
			}
			return .Abort_All
		case:
			if t_ch != p_ch {
				return .No_Match
			}
		}
	}
	return .Match if t >= len(text) else .No_Match
}

@(private = "file")
wild_class :: proc "contextless" (pat: string, open: int, t_ch: u8, fold: bool) -> (hit: bool, end: int, abort: bool) {
	p := open + 1
	p_ch := wild_at(pat, p)
	if p_ch == '^' {
		p_ch = '!'
	}
	negated := p_ch == '!'
	if negated {
		p += 1
		p_ch = wild_at(pat, p)
	}
	prev_ch: u8 = 0
	matched := false
	for {
		if p_ch == 0 {
			return false, p, true
		}
		if p_ch == '\\' {
			p += 1
			p_ch = wild_at(pat, p)
			if p_ch == 0 {
				return false, p, true
			}
			if t_ch == p_ch {
				matched = true
			}
		} else if p_ch == '-' && prev_ch != 0 && wild_at(pat, p + 1) != 0 && wild_at(pat, p + 1) != ']' {
			p += 1
			p_ch = pat[p]
			if p_ch == '\\' {
				p += 1
				p_ch = wild_at(pat, p)
				if p_ch == 0 {
					return false, p, true
				}
			}
			if t_ch <= p_ch && t_ch >= prev_ch {
				matched = true
			} else if fold && t_ch >= 'a' && t_ch <= 'z' {
				upper := t_ch - 32
				if upper <= p_ch && upper >= prev_ch {
					matched = true
				}
			}
			p_ch = 0
		} else if p_ch == '[' && wild_at(pat, p + 1) == ':' {
			p += 2
			s := p
			for {
				p_ch = wild_at(pat, p)
				if p_ch == 0 || p_ch == ']' {
					break
				}
				p += 1
			}
			if p_ch == 0 {
				return false, p, true
			}
			if p - s - 1 < 0 || pat[p - 1] != ':' {
				p = s - 2
				p_ch = '['
				if t_ch == p_ch {
					matched = true
				}
			} else {
				in_class, known := wild_posix_class(pat[s:p - 1], t_ch, fold)
				if !known {
					return false, p, true
				}
				if in_class {
					matched = true
				}
				p_ch = 0
			}
		} else if t_ch == p_ch {
			matched = true
		}
		prev_ch = p_ch
		p += 1
		p_ch = wild_at(pat, p)
		if p_ch == ']' {
			break
		}
	}
	return matched != negated, p, false
}

@(private = "file")
wild_posix_class :: proc "contextless" (name: string, c: u8, fold: bool) -> (in_class, known: bool) {
	upper := c >= 'A' && c <= 'Z'
	lower := c >= 'a' && c <= 'z'
	digit := c >= '0' && c <= '9'
	switch name {
	case "alnum":
		return upper || lower || digit, true
	case "alpha":
		return upper || lower, true
	case "blank":
		return c == ' ' || c == '\t', true
	case "cntrl":
		return c < 0x20 || c == 0x7f, true
	case "digit":
		return digit, true
	case "graph":
		return c > 0x20 && c < 0x7f, true
	case "lower":
		return lower, true
	case "print":
		return c >= 0x20 && c < 0x7f, true
	case "punct":
		return c > 0x20 && c < 0x7f && !upper && !lower && !digit, true
	case "space":
		return c == ' ' || c == '\t' || c == '\n' || c == '\r', true
	case "upper":
		return upper || (fold && lower), true
	case "xdigit":
		return digit || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'), true
	}
	return false, false
}

@(private)
ignore_read :: proc(vfs: prim.Vfs, path: string, limit: i64, allocator: runtime.Allocator) -> (data: []u8, err: Error) {
	fd, perr := prim.open_file(vfs, path)
	if perr != .None {
		return nil, from_prim(perr)
	}
	defer prim.close_file(vfs, fd)
	size, serr := prim.file_size(vfs, fd)
	if serr != .None {
		return nil, from_prim(serr)
	}
	if size > limit {
		return nil, .Too_Large
	}
	buf, aerr := make([]u8, int(size), allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	n, rerr := prim.read_at(vfs, fd, buf, 0)
	if rerr != .None {
		delete(buf, allocator)
		return nil, from_prim(rerr)
	}
	return buf[:n], .None
}

@(private = "file")
ignore_load_rules :: proc(vfs: prim.Vfs, path, base: string, allocator: runtime.Allocator) -> (r: ^Rules, err: Error) {
	if len(path) == 0 {
		return nil, .None
	}
	data, rerr := ignore_read(vfs, path, IGNORE_FILE_MAX, allocator)
	if rerr != .None {
		return nil, .No_Memory if rerr == .No_Memory else .None
	}
	defer delete(data, allocator)
	return rules_parse(data, base, allocator)
}

@(private = "file")
ignore_load :: proc(ig: ^Ignore, git_dir, common_dir: string, plain: bool) -> Error {
	if plain {
		defaults: [1024]u8 = ---
		n := 0
		for line in PLAIN_DEFAULTS {
			if n + len(line) + 1 > len(defaults) {
				return .Too_Large
			}
			n += copy(defaults[n:], line)
			defaults[n] = '\n'
			n += 1
		}
		ig.defaults = rules_parse(defaults[:n], "", ig.allocator) or_return
	}
	common := common_dir if len(common_dir) > 0 else git_dir
	gd := git_dir if len(git_dir) > 0 else common_dir
	c := Git_Config {
		vfs       = ig.vfs,
		allocator = ig.allocator,
		git_dir   = gd,
		filemode  = true,
		symlinks  = true,
	}
	buf: prim.Path_Buf = ---
	nosystem := false
	if v, ok := prim.getenv("GIT_CONFIG_NOSYSTEM"); ok {
		nosystem, _ = config_bool(v, true)
	}
	if !nosystem {
		system, ok := prim.getenv("GIT_CONFIG_SYSTEM")
		if !ok {
			when ODIN_OS == .Windows {
				if p, pok := git_program_data_config(buf[:]); pok {
					config_load(&c, p) or_return
				}
				if p, pok := git_system_file(buf[:], "etc/gitconfig"); pok {
					system = p
				}
			} else {
				system = "/etc/gitconfig"
			}
		}
		config_load(&c, system) or_return
	}
	if global, ok := prim.getenv("GIT_CONFIG_GLOBAL"); ok {
		config_load(&c, global) or_return
	} else {
		if p, pok := ignore_xdg_path(buf[:], "config"); pok {
			config_load(&c, p) or_return
		}
		if home, hok := git_home(); hok {
			if p, pok := path_join_buf(buf[:], home, ".gitconfig"); pok {
				config_load(&c, p) or_return
			}
		}
	}
	if len(common) > 0 {
		c.worktree_config = false
		if p, ok := path_join_buf(buf[:], common, "config"); ok {
			config_load(&c, p) or_return
		}
		if c.worktree_config && len(gd) > 0 {
			if p, ok := path_join_buf(buf[:], gd, "config.worktree"); ok {
				config_load(&c, p) or_return
			}
		}
	}
	ig.ignore_case = c.ignore_case
	ig.git = Git_Settings {
		autocrlf     = c.autocrlf,
		core_eol     = c.core_eol,
		trust_exec   = c.filemode && ODIN_OS != .Windows,
		symlinks     = c.symlinks,
		ignore_case  = c.ignore_case,
	}
	attributes_file := ""
	if c.has_attributes {
		attributes_file = string(c.attributes[:c.attributes_len])
	} else if p, ok := ignore_xdg_path(buf[:], "attributes"); ok {
		attributes_file = p
	}
	git_settings_attributes(&ig.git, ig.vfs, attributes_file, ig.allocator)
	ig.git.filters = c.filters
	ig.git.roundtrip = c.roundtrip
	ig.git.has_roundtrip = c.has_roundtrip
	excludes_file := ""
	if c.has_excludes {
		excludes_file = string(c.excludes[:c.excludes_len])
		if len(excludes_file) > 0 && !path_is_abs(excludes_file) {
			root_buf: prim.Path_Buf = ---
			root, ok := ignore_worktree_root(ig.vfs, gd, root_buf[:])
			if !ok {
				excludes_file = ""
			} else if excludes_file, ok = path_join_buf(buf[:], root, string(c.excludes[:c.excludes_len])); !ok {
				excludes_file = ""
			}
		}
	} else if p, ok := ignore_xdg_path(buf[:], "ignore"); ok {
		excludes_file = p
	}
	ig.global = ignore_load_rules(ig.vfs, excludes_file, "", ig.allocator) or_return
	if len(common) > 0 {
		if p, ok := path_join_buf(buf[:], common, "info/exclude"); ok {
			ig.excludes = ignore_load_rules(ig.vfs, p, "", ig.allocator) or_return
		}
	}
	return .None
}

@(private = "file")
ignore_xdg_path :: proc "contextless" (buf: []u8, name: string) -> (string, bool) {
	if xdg, ok := prim.getenv("XDG_CONFIG_HOME"); ok {
		return path_join_buf(buf, xdg, "git", name)
	}
	if home, ok := git_home(); ok {
		return path_join_buf(buf, home, ".config/git", name)
	}
	return "", false
}

@(private = "file")
ignore_worktree_root :: proc(vfs: prim.Vfs, git_dir: string, buf: []u8) -> (string, bool) {
	if len(git_dir) == 0 {
		return "", false
	}
	pbuf: prim.Path_Buf = ---
	if p, ok := path_join_buf(pbuf[:], git_dir, "gitdir"); ok {
		if text, tok := ignore_read_small(vfs, p, buf); tok && len(text) > 0 {
			return prim.dir_name(text), true
		}
	}
	if path_name(git_dir) == ".git" {
		root := path_parent(git_dir)
		if len(root) == 0 {
			return "/", true
		}
		return root, true
	}
	return "", false
}

@(private = "file")
ignore_read_small :: proc(vfs: prim.Vfs, path: string, buf: []u8) -> (string, bool) {
	fd, err := prim.open_file(vfs, path)
	if err != .None {
		return "", false
	}
	defer prim.close_file(vfs, fd)
	n, rerr := prim.read_at(vfs, fd, buf, 0)
	if rerr != .None || n == len(buf) {
		return "", false
	}
	for n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ' || buf[n - 1] == '\t') {
		n -= 1
	}
	return string(buf[:n]), true
}

@(private = "file")
CONFIG_MAX_DEPTH :: 10

@(private = "file")
CONFIG_BUF :: 8192

@(private = "file")
Git_Config :: struct {
	vfs:             prim.Vfs,
	allocator:       runtime.Allocator,
	git_dir:         string,
	depth:           int,
	excludes:        [prim.PATH_MAX]u8,
	excludes_len:    int,
	has_excludes:    bool,
	ignore_case:     bool,
	worktree_config: bool,
	autocrlf:        Autocrlf,
	core_eol:        Core_Eol,
	filemode:        bool,
	symlinks:        bool,
	attributes:      [prim.PATH_MAX]u8,
	attributes_len:  int,
	has_attributes:  bool,
	filters:         [dynamic]Filter_Driver,
	roundtrip:       string,
	has_roundtrip:   bool,
}

@(private = "file")
Config_Reader :: struct {
	data:     []u8,
	pos:      int,
	eof:      bool,
	key:      []u8,
	key_len:  int,
	val:      []u8,
	val_len:  int,
	val_over: bool,
}

@(private = "file")
config_load :: proc(c: ^Git_Config, path: string) -> Error {
	if len(path) == 0 || c.depth >= CONFIG_MAX_DEPTH {
		return .None
	}
	data, err := ignore_read(c.vfs, path, IGNORE_FILE_MAX, c.allocator)
	if err != .None {
		return .No_Memory if err == .No_Memory else .None
	}
	defer delete(data, c.allocator)
	scratch, aerr := make([]u8, 2 * CONFIG_BUF, c.allocator)
	if aerr != nil {
		return .No_Memory
	}
	defer delete(scratch, c.allocator)
	r := Config_Reader {
		data = data,
		key  = scratch[:CONFIG_BUF],
		val  = scratch[CONFIG_BUF:],
	}
	c.depth += 1
	defer c.depth -= 1
	return config_parse(c, &r, path)
}

@(private = "file")
config_parse :: proc(c: ^Git_Config, r: ^Config_Reader, path: string) -> Error {
	if len(r.data) >= 3 && r.data[0] == 0xEF && r.data[1] == 0xBB && r.data[2] == 0xBF {
		r.pos = 3
	}
	base := 0
	comment := false
	for {
		ch := config_char(r)
		if ch == '\n' {
			if r.eof {
				return .None
			}
			comment = false
			continue
		}
		if comment || config_space(ch) {
			continue
		}
		if ch == '#' || ch == ';' {
			comment = true
			continue
		}
		if ch == '[' {
			r.key_len = 0
			if !config_section(r) || r.key_len == 0 || !config_push_key(r, '.') {
				return .None
			}
			base = r.key_len
			continue
		}
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
			return .None
		}
		r.key_len = base
		if !config_push_key(r, ignore_lower(ch)) {
			return .None
		}
		has_value, ok := config_value(r)
		if !ok {
			return .None
		}
		if !r.val_over {
			config_entry(c, string(r.key[:r.key_len]), string(r.val[:r.val_len]), has_value, path) or_return
		}
	}
}

@(private = "file")
config_char :: proc "contextless" (r: ^Config_Reader) -> u8 {
	if r.pos >= len(r.data) {
		r.eof = true
		return '\n'
	}
	ch := r.data[r.pos]
	r.pos += 1
	if ch == '\r' && r.pos < len(r.data) && r.data[r.pos] == '\n' {
		r.pos += 1
		return '\n'
	}
	return ch
}

@(private = "file")
config_space :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}

@(private = "file")
config_key_char :: #force_inline proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-'
}

@(private = "file")
config_push_key :: proc "contextless" (r: ^Config_Reader, ch: u8) -> bool {
	if r.key_len >= len(r.key) {
		return false
	}
	r.key[r.key_len] = ch
	r.key_len += 1
	return true
}

@(private = "file")
config_push_val :: proc "contextless" (r: ^Config_Reader, ch: u8) {
	if r.val_len >= len(r.val) {
		r.val_over = true
		return
	}
	r.val[r.val_len] = ch
	r.val_len += 1
}

@(private = "file")
config_section :: proc "contextless" (r: ^Config_Reader) -> bool {
	for {
		ch := config_char(r)
		if r.eof {
			return false
		}
		if ch == ']' {
			return true
		}
		if config_space(ch) {
			for config_space(ch) && !r.eof {
				ch = config_char(r)
			}
			if r.eof || ch != '"' || !config_push_key(r, '.') {
				return false
			}
			for {
				ch = config_char(r)
				if r.eof || ch == '\n' {
					return false
				}
				if ch == '"' {
					break
				}
				if ch == '\\' {
					ch = config_char(r)
					if r.eof || ch == '\n' {
						return false
					}
				}
				if !config_push_key(r, ch) {
					return false
				}
			}
			return config_char(r) == ']'
		}
		if !config_key_char(ch) && ch != '.' {
			return false
		}
		if !config_push_key(r, ignore_lower(ch)) {
			return false
		}
	}
}

@(private = "file")
config_value :: proc "contextless" (r: ^Config_Reader) -> (has_value, ok: bool) {
	ch: u8
	for {
		ch = config_char(r)
		if r.eof || !config_key_char(ch) {
			break
		}
		if !config_push_key(r, ignore_lower(ch)) {
			return false, false
		}
	}
	for ch == ' ' || ch == '\t' {
		ch = config_char(r)
	}
	r.val_len = 0
	r.val_over = false
	if ch == '\n' {
		return false, true
	}
	if ch != '=' {
		return false, false
	}
	quote := false
	comment := false
	trim := 0
	for {
		ch = config_char(r)
		if ch == '\n' {
			if quote {
				return false, false
			}
			if trim > 0 {
				r.val_len = trim
			}
			return true, true
		}
		if comment {
			continue
		}
		if config_space(ch) && !quote {
			if trim == 0 {
				trim = r.val_len
			}
			if r.val_len > 0 {
				config_push_val(r, ch)
			}
			continue
		}
		if !quote && (ch == ';' || ch == '#') {
			comment = true
			continue
		}
		trim = 0
		if ch == '\\' {
			ch = config_char(r)
			switch ch {
			case '\n':
				continue
			case 't':
				ch = '\t'
			case 'b':
				ch = 8
			case 'n':
				ch = '\n'
			case '\\', '"':
			case:
				return false, false
			}
			config_push_val(r, ch)
			continue
		}
		if ch == '"' {
			quote = !quote
			continue
		}
		config_push_val(r, ch)
	}
}

@(private = "file")
config_entry :: proc(c: ^Git_Config, key, val: string, has_value: bool, from: string) -> Error {
	switch key {
	case "core.excludesfile":
		if has_value {
			c.has_excludes = true
			c.excludes_len = 0
			if p, ok := config_path(c.excludes[:], val, ""); ok {
				c.excludes_len = len(p)
			}
		}
	case "core.ignorecase":
		if b, ok := config_bool(val, has_value); ok {
			c.ignore_case = b
		}
	case "core.autocrlf":
		if has_value && ignore_equal(val, "input", true) {
			c.autocrlf = .Input
		} else if b, ok := config_bool(val, has_value); ok {
			c.autocrlf = .True if b else .False
		}
	case "core.eol":
		switch {
		case ignore_equal(val, "lf", true):
			c.core_eol = .Lf
		case ignore_equal(val, "crlf", true):
			c.core_eol = .Crlf
		case ignore_equal(val, "native", true):
			c.core_eol = .Native
		}
	case "core.filemode":
		if b, ok := config_bool(val, has_value); ok {
			c.filemode = b
		}
	case "core.symlinks":
		if b, ok := config_bool(val, has_value); ok {
			c.symlinks = b
		}
	case "core.attributesfile":
		if has_value {
			c.has_attributes = true
			c.attributes_len = 0
			if p, ok := config_path(c.attributes[:], val, ""); ok {
				c.attributes_len = len(p)
			}
		}
	case "core.checkroundtripencoding":
		if has_value {
			if c.has_roundtrip {
				delete(c.roundtrip, c.allocator)
			}
			c.roundtrip, _ = clone_string(val, c.allocator)
			c.has_roundtrip = true
		}
	case "extensions.worktreeconfig":
		if b, ok := config_bool(val, has_value); ok {
			c.worktree_config = b
		}
	case "include.path":
		if has_value {
			return config_include(c, val, from)
		}
	case:
		if len(key) > 7 && ignore_has_prefix(key, "filter.") {
			config_filter(c, key[7:], val, has_value)
			return .None
		}
		if has_value && len(key) >= 15 && ignore_has_prefix(key, "includeif.") && key[len(key) - 5:] == ".path" {
			if config_condition(c, key[10:len(key) - 5], from) {
				return config_include(c, val, from)
			}
		}
	}
	return .None
}

@(private = "file")
config_filter :: proc(c: ^Git_Config, rest, val: string, has_value: bool) {
	dot := -1
	for i := len(rest) - 1; i >= 0; i -= 1 {
		if rest[i] == '.' {
			dot = i
			break
		}
	}
	if dot <= 0 {
		return
	}
	name, field := rest[:dot], rest[dot + 1:]
	if field != "clean" && field != "smudge" && field != "process" && field != "required" {
		return
	}
	if c.filters == nil {
		c.filters = make([dynamic]Filter_Driver, c.allocator)
	}
	d: ^Filter_Driver
	for &f in c.filters {
		if f.name == name {
			d = &f
		}
	}
	if d == nil {
		n, _ := clone_string(name, c.allocator)
		append(&c.filters, Filter_Driver{name = n})
		d = &c.filters[len(c.filters) - 1]
	}
	switch field {
	case "required":
		if b, ok := config_bool(val, has_value); ok {
			d.required = b
		}
	case:
		if !has_value {
			return
		}
		v, _ := clone_string(val, c.allocator)
		switch field {
		case "clean":
			d.clean = v
		case "smudge":
			d.smudge = v
		case "process":
			d.process = v
		}
	}
}

@(private = "file")
config_include :: proc(c: ^Git_Config, val, from: string) -> Error {
	if len(from) == 0 {
		return .None
	}
	buf: prim.Path_Buf = ---
	p, ok := config_path(buf[:], val, from)
	if !ok || len(p) == 0 || !path_is_abs(p) {
		return .None
	}
	return config_load(c, p)
}

@(private = "file")
config_path :: proc(buf: []u8, val, from: string) -> (string, bool) {
	n := 0
	rest := val
	if len(val) > 0 && val[0] == '~' {
		slash := ignore_index_byte(val, '/')
		if slash != 1 && !(slash < 0 && len(val) == 1) {
			return "", false
		}
		home, ok := git_home()
		if !ok || len(home) > len(buf) {
			return "", false
		}
		n = copy(buf, home)
		rest = val[1:]
	} else if ignore_has_prefix(val, "%(prefix)/") {
		pbuf: [prim.PATH_MAX]u8
		prefix, ok := git_prefix(pbuf[:])
		if !ok || len(prefix) > len(buf) {
			return "", false
		}
		n = copy(buf, prefix)
		rest = val[len("%(prefix)"):]
	} else if len(val) > 0 && !path_is_abs(val) && len(from) > 0 {
		slash := len(from) - 1
		for slash >= 0 && from[slash] != '/' {
			slash -= 1
		}
		if slash + 1 > len(buf) {
			return "", false
		}
		n = copy(buf, from[:slash + 1])
	}
	if n + len(rest) > len(buf) {
		return "", false
	}
	n += copy(buf[n:], rest)
	when ODIN_OS == .Windows {
		for i in 0 ..< n {
			if buf[i] == '\\' {
				buf[i] = '/'
			}
		}
	}
	return string(buf[:n]), true
}

@(private = "file")
config_bool :: proc "contextless" (val: string, has_value: bool) -> (value, ok: bool) {
	if !has_value {
		return true, true
	}
	if len(val) == 0 {
		return false, true
	}
	if ignore_equal(val, "true", true) || ignore_equal(val, "yes", true) || ignore_equal(val, "on", true) {
		return true, true
	}
	if ignore_equal(val, "false", true) || ignore_equal(val, "no", true) || ignore_equal(val, "off", true) {
		return false, true
	}
	s := val
	if s[0] == '-' || s[0] == '+' {
		s = s[1:]
	}
	hex := len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')
	if hex {
		s = s[2:]
	}
	if len(s) > 0 {
		switch ignore_lower(s[len(s) - 1]) {
		case 'k', 'm', 'g':
			s = s[:len(s) - 1]
		}
	}
	if len(s) == 0 {
		return false, false
	}
	nonzero := false
	for ch in transmute([]u8)s {
		l := ignore_lower(ch)
		if !((ch >= '0' && ch <= '9') || (hex && l >= 'a' && l <= 'f')) {
			return false, false
		}
		if ch != '0' {
			nonzero = true
		}
	}
	return nonzero, true
}

@(private = "file")
config_condition :: proc(c: ^Git_Config, cond, from: string) -> bool {
	if ignore_has_prefix(cond, "gitdir:") {
		return config_gitdir(c, cond[7:], from, false)
	}
	if ignore_has_prefix(cond, "gitdir/i:") {
		return config_gitdir(c, cond[9:], from, true)
	}
	if ignore_has_prefix(cond, "onbranch:") {
		return config_onbranch(c, cond[9:])
	}
	return false
}

@(private = "file")
config_gitdir :: proc(c: ^Git_Config, cond, from: string, icase: bool) -> bool {
	if len(c.git_dir) == 0 {
		return false
	}
	buf: prim.Path_Buf = ---
	n := 0
	prefix := 0
	pat := cond
	if len(pat) > 0 && pat[0] == '~' {
		expanded, ok := config_path(buf[:], pat, "")
		if !ok {
			return false
		}
		n = len(expanded)
		pat = ""
	} else if len(pat) >= 2 && pat[0] == '.' && pat[1] == '/' {
		slash := len(from) - 1
		for slash >= 0 && from[slash] != '/' {
			slash -= 1
		}
		if slash < 0 || slash + len(pat) - 1 > len(buf) {
			return false
		}
		n = copy(buf[:], from[:slash])
		n += copy(buf[n:], pat[1:])
		prefix = slash + 1
		pat = ""
	} else if len(pat) == 0 || pat[0] != '/' {
		n = copy(buf[:], "**/")
	}
	if n + len(pat) + 2 > len(buf) {
		return false
	}
	n += copy(buf[n:], pat)
	if n > 0 && buf[n - 1] == '/' {
		n += copy(buf[n:], "**")
	}
	pattern := string(buf[:n])
	text := c.git_dir
	if prefix > 0 {
		if len(text) < prefix || !ignore_equal(text[:prefix], pattern[:prefix], icase) {
			return false
		}
	}
	return wild_do(pattern[prefix:], 0, text[prefix:], 0, true, icase) == .Match
}

@(private = "file")
config_onbranch :: proc(c: ^Git_Config, cond: string) -> bool {
	if len(c.git_dir) == 0 {
		return false
	}
	pbuf: prim.Path_Buf = ---
	head_path, ok := path_join_buf(pbuf[:], c.git_dir, "HEAD")
	if !ok {
		return false
	}
	hbuf: [1024]u8 = ---
	head, hok := ignore_read_small(c.vfs, head_path, hbuf[:])
	if !hok || !ignore_has_prefix(head, "ref: refs/heads/") {
		return false
	}
	branch := head[len("ref: refs/heads/"):]
	if len(cond) + 2 > len(pbuf) {
		return false
	}
	n := copy(pbuf[:], cond)
	if n > 0 && pbuf[n - 1] == '/' {
		n += copy(pbuf[n:], "**")
	}
	return wild_do(string(pbuf[:n]), 0, branch, 0, true, false) == .Match
}

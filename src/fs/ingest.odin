package fs

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"
import "../textdiff"

Builder :: struct {
	h:       ^History,
	actor:   prim.Id,
	aix:     u32,
	seq0:    u64,
	n:       int,
	ops:     [dynamic]crdt.Op_Run,
	imports: [dynamic]Import_File,
	git:     bool,
}

@(private)
builder_init :: proc(b: ^Builder, h: ^History, actor: prim.Id) {
	b^ = {
		h     = h,
		actor = actor,
		aix   = history_actor_ix(h, actor),
		seq0  = history_next_seq(h, actor),
	}
	b.ops = make([dynamic]crdt.Op_Run, context.temp_allocator)
	b.imports = make([dynamic]Import_File, context.temp_allocator)
}

@(private)
builder_reset :: proc(b: ^Builder) {
	b.seq0 = history_next_seq(b.h, b.actor)
	b.n = 0
	clear(&b.ops)
	clear(&b.imports)
}

@(private)
builder_next_id :: proc(b: ^Builder) -> fstree.Inode_Id {
	return fstree.Inode_Id{b.aix, b.seq0 + u64(b.n)}
}

@(private)
builder_opaque :: proc(b: ^Builder, payload: []u8) -> fstree.Inode_Id {
	id := builder_next_id(b)
	content := make([]u8, len(payload), context.temp_allocator)
	copy(content, payload)
	append(&b.ops, crdt.Op_Run{kind = .Opaque, len = 1, content = content})
	b.n += 1
	return id
}

@(private)
builder_tree :: proc(b: ^Builder, op: fstree.Op) -> fstree.Inode_Id {
	buf := make([dynamic]u8, context.temp_allocator)
	encode_tree_op(b.h, &buf, op)
	return builder_opaque(b, buf[:])
}

@(private)
builder_content :: proc(b: ^Builder, inode: fstree.Inode_Id, oid: odb.Oid, size: i64) {
	buf := make([dynamic]u8, context.temp_allocator)
	encode_content_op(b.h, &buf, inode, oid, size)
	builder_opaque(b, buf[:])
}

@(private)
builder_insert :: proc(b: ^Builder, inode: fstree.Inode_Id, pos: int, data: []u8) {
	if len(data) == 0 {
		return
	}
	c := make([]u8, len(data), context.temp_allocator)
	copy(c, data)
	append(&b.ops, crdt.Op_Run{target = target_id(b, inode), kind = .Insert, pos = pos, len = len(data), content = c})
	b.n += len(data)
}

@(private)
builder_insert_ref :: proc(b: ^Builder, inode: fstree.Inode_Id, pos: int, oid: odb.Oid, n: int) -> (first: crdt.Op_Id, last: crdt.Op_Id) {
	ref: crdt.Content_Ref
	x := oid
	copy(ref.oid[:], x[:20])
	first = crdt.Op_Id{b.actor, b.seq0 + u64(b.n)}
	append(&b.ops, crdt.Op_Run{target = target_id(b, inode), kind = .Insert_Ref, pos = pos, len = n, ref = ref})
	b.n += n
	last = crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1}
	return
}

@(private)
builder_delete :: proc(b: ^Builder, inode: fstree.Inode_Id, pos: int, n: int) {
	if n <= 0 {
		return
	}
	append(&b.ops, crdt.Op_Run{target = target_id(b, inode), kind = .Delete, pos = pos, len = n})
	b.n += n
}

@(private)
target_id :: proc(b: ^Builder, inode: fstree.Inode_Id) -> crdt.Op_Id {
	if inode.actor == b.aix {
		return crdt.Op_Id{b.actor, inode.seq}
	}
	return inode_op(b.h, inode)
}

@(private)
builder_commit :: proc(m: ^Mount, b: ^Builder) -> Error {
	if b.n == 0 {
		return .None
	}
	h := m.history
	batch := crdt.Batch {
		actor   = b.actor,
		seq     = b.seq0,
		lamport = history_lamport_after(h, m.synced[:]),
		parents = m.synced[:],
		ops     = b.ops[:],
	}
	append(&m.intents, Intent{b.actor, b.seq0, u64(b.n)})
	save_mount_state(m) or_return
	history_commit_local(h, &batch) or_return
	clear(&m.synced)
	append(&m.synced, crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1})
	set_line(m) or_return
	builder_reset(b)
	return .None
}

@(private)
set_line :: proc(m: ^Mount) -> Error {
	h := m.history
	cur, found := history_line(h, m.line, context.temp_allocator) or_return
	if !found {
		return history_set_line(h, m.line, m.synced[:])
	}
	a := make([dynamic]crdt.Lv, context.temp_allocator)
	c := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, cur, &a) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &c) != .None {
		return history_set_line(h, m.line, m.synced[:])
	}
	out := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, a[:], c[:], &out)
	return history_set_line(h, m.line, crdt.graph_version_ids(&h.g, out[:], context.temp_allocator))
}

@(private)
Dir_Frame :: struct {
	path:  string,
	inode: fstree.Inode_Id,
	depth: int,
	wd:    i32,
}

@(private)
abs_path :: proc(m: ^Mount, rel: string, buf: []u8) -> string {
	p, _ := path_join_buf(buf, m.root, rel)
	return p
}

@(private)
sniff_binary :: proc(m: ^Mount, abs: string) -> (binary: bool, err: Error) {
	fd, oerr := prim.open_file(m.vfs, abs)
	if oerr != .None {
		return false, from_prim(oerr)
	}
	defer prim.close_file(m.vfs, fd)
	buf: [textdiff.BINARY_SNIFF_BYTES]u8
	n, rerr := prim.read_at(m.vfs, fd, buf[:], 0)
	if rerr != .None {
		return false, from_prim(rerr)
	}
	return textdiff.is_binary(buf[:n]), .None
}

@(private)
store_file :: proc(m: ^Mount, abs: string, pack: ^odb.Pack_Builder) -> (oid: odb.Oid, err: Error) {
	if m.db == nil {
		return {}, .Invalid
	}
	if pack != nil {
		o, perr := odb.pack_add_file(pack, abs)
		return o, from_odb(perr)
	}
	o, werr := odb.write_file(m.db, abs)
	return o, from_odb(werr)
}

@(private)
index_clean :: proc(e: ^Index_Entry, st: Stat, kind: Disk_Kind, index_mtime: i64) -> bool {
	if e.stage != 0 || .Skip_Worktree in e.flags || .Intent_To_Add in e.flags || .Sparse_Dir in e.flags {
		return false
	}
	mtime := i64(e.mtime_s) * 1_000_000_000 + i64(e.mtime_ns)
	ctime := i64(e.ctime_s) * 1_000_000_000 + i64(e.ctime_ns)
	if mtime != st.mtime_ns || ctime != st.ctime_ns || u32(st.size) != e.size || u32(st.ino) != e.ino {
		return false
	}
	if mtime >= index_mtime {
		return false
	}
	switch e.mode & 0o170000 {
	case 0o100000:
		return kind == .File && (e.mode & 0o111 != 0) == (st.mode & 0o100 != 0)
	case 0o120000:
		return kind == .Symlink
	}
	return false
}

@(private)
Import_State :: struct {
	m:         ^Mount,
	b:         Builder,
	stack:     [dynamic]Dir_Frame,
	pack:      odb.Pack_Builder,
	use_pack:  bool,
	files:     int,
	index:     Index_Reader,
	has_index: bool,
	entry:     Index_Entry,
	have_entry: bool,
	index_mtime: i64,
	long:      runtime.Allocator,
	chunk:     virtual.Arena,
	path_buf:  [dynamic]u8,
	resume:    bool,
}

mount_import :: proc(m: ^Mount) -> Error {
	long: virtual.Arena
	if virtual.arena_init_growing(&long, 1 << 20) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&long)
	st: Import_State
	st.m = m
	st.long = virtual.arena_allocator(&long)
	if virtual.arena_init_growing(&st.chunk, 1 << 20) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&st.chunk)
	context.temp_allocator = virtual.arena_allocator(&st.chunk)
	empty := shadow_empty(&m.shadow) or_return
	st.resume = !empty
	builder_init(&st.b, m.history, m.actor)
	st.stack = make([dynamic]Dir_Frame, st.long)
	st.path_buf = make([dynamic]u8, st.long)
	append(&st.stack, Dir_Frame{path = "", inode = fstree.ROOT, depth = 0, wd = m.root_wd})
	if m.has_git && m.db != nil {
		if index_open(&st.index, m.vfs, m.git.dir, m.db.format, st.long) == .None {
			st.has_index = true
			st.index_mtime = index_file_mtime_ns(&st.index)
			if err := index_advance(&st); err != .None {
				index_close(&st.index)
				st.has_index = false
			}
		}
	}
	defer if st.has_index {
		index_close(&st.index)
	}
	bulk_prev := m.db != nil && odb.bulk_begin(m.db)
	defer if m.db != nil {
		odb.bulk_end(m.db, bulk_prev)
	}
	if !m.has_git && m.db != nil {
		if odb.pack_begin(&st.pack, m.db) == .None {
			st.use_pack = true
		}
	}
	defer if st.use_pack {
		odb.pack_abort(&st.pack)
	}
	sc: Scanner
	scan_open(&sc, m.vfs, m.root, "", &m.ignore, nil, {threads = m.opts.threads}) or_return
	defer scan_close(&sc)
	for {
		it, ok, err := scan_next(&sc)
		if err != .None {
			return err
		}
		if !ok {
			break
		}
		for len(st.stack) > 1 && st.stack[len(st.stack) - 1].depth >= it.depth {
			pop(&st.stack)
		}
		parent := st.stack[len(st.stack) - 1]
		tracked := false
		entry: Index_Entry
		if st.has_index {
			tracked, entry = index_seek(&st, it.path) or_return
		}
		if it.ignored && !tracked {
			if it.kind == .Dir {
				if st.has_index && index_has_under(&st, it.path) {
					import_dir(&st, it, parent, &sc) or_return
					continue
				}
				scan_skip(&sc)
			}
			continue
		}
		if st.resume {
			have, found := shadow_get(&m.shadow, it.path) or_return
			if found {
				if it.kind == .Dir && have.kind == .Dir {
					wd, _ := watch_dir(m.reg, m, it.path, parent.wd)
					p, _ := clone_string(it.path, st.long)
					append(&st.stack, Dir_Frame{path = p, inode = have.inode, depth = it.depth, wd = wd})
				} else if it.kind == .Dir {
					scan_skip(&sc)
				}
				continue
			}
		}
		switch it.kind {
		case .Dir:
			if tracked && entry.mode & 0o170000 == 0o160000 {
				scan_skip(&sc)
				continue
			}
			import_dir(&st, it, parent, &sc) or_return
		case .File, .Symlink:
			import_file(&st, it, parent, tracked, &entry) or_return
		case .Missing, .Other:
		}
		if st.b.n > 0 && (st.files >= m.opts.import_chunk || shadow_pending_count(&m.shadow) >= 65536) {
			import_flush(&st) or_return
		}
	}
	import_flush(&st) or_return
	if m.has_git && m.db != nil {
		import_cache_tree(m) or_return
	}
	m.imported = true
	_heap_release()
	return save_mount_state(m)
}

@(private)
index_advance :: proc(st: ^Import_State) -> Error {
	e, ok, err := index_next(&st.index)
	if err != .None {
		return err
	}
	st.have_entry = ok
	if ok {
		st.entry = e
		clear(&st.path_buf)
		append(&st.path_buf, ..transmute([]u8)e.path)
		st.entry.path = string(st.path_buf[:])
	}
	return .None
}

@(private)
index_seek :: proc(st: ^Import_State, path: string) -> (tracked: bool, e: Index_Entry, err: Error) {
	for st.have_entry {
		c := git_path_cmp(st.entry.path, false, path, false)
		if c >= 0 {
			break
		}
		index_advance(st) or_return
	}
	for st.have_entry && st.entry.path == path {
		if !tracked || st.entry.stage == 0 {
			e = st.entry
			tracked = true
		}
		index_advance(st) or_return
	}
	return
}

@(private)
index_has_under :: proc(st: ^Import_State, dir: string) -> bool {
	return st.have_entry && path_under(st.entry.path, dir)
}

@(private)
import_dir :: proc(st: ^Import_State, it: ^Scan_Item, parent: Dir_Frame, sc: ^Scanner) -> Error {
	m := st.m
	name := it.name
	if !fstree.valid_name(name) {
		scan_skip(sc)
		return .None
	}
	inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = name, kind = .Dir})
	shadow_append(&m.shadow, it.path, Entry{inode = inode, kind = .Dir, stat = it.stat}) or_return
	wd, _ := watch_dir(m.reg, m, it.path, parent.wd)
	p, _ := clone_string(it.path, st.long)
	append(&st.stack, Dir_Frame{path = p, inode = inode, depth = it.depth, wd = wd})
	return .None
}

@(private)
import_file :: proc(st: ^Import_State, it: ^Scan_Item, parent: Dir_Frame, tracked: bool, e: ^Index_Entry) -> Error {
	m := st.m
	if !fstree.valid_name(it.name) {
		return .None
	}
	abuf: prim.Path_Buf
	abs := abs_path(m, it.path, abuf[:])
	stat := it.stat
	kind := it.kind
	if !it.statted {
		s, serr := prim.lstat(m.vfs, abs)
		if serr != .None {
			return .None
		}
		stat = disk_stat(s)
		kind = disk_kind(s.kind)
	}
	if kind == .Symlink {
		target := it.target
		if len(target) == 0 {
			tbuf: [prim.PATH_MAX]u8
			n, lerr := prim.readlink(m.vfs, abs, tbuf[:])
			if lerr != .None {
				return .None
			}
			target, _ = clone_string(string(tbuf[:n]), context.temp_allocator)
		}
		inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = it.name, kind = .Symlink, target = target})
		oid: odb.Oid
		if tracked && index_clean(e, stat, kind, st.index_mtime) {
			oid = e.oid
		} else if m.db != nil {
			oid, _ = odb.hash(m.db.format, .Blob, transmute([]u8)target)
		}
		shadow_append(&m.shadow, it.path, Entry{inode = inode, kind = .Symlink, stat = stat, oid = oid}) or_return
		st.files += 1
		return .None
	}
	if kind != .File {
		return .None
	}
	flags: fstree.Flags
	if stat.mode & 0o100 != 0 {
		flags += {.Exec}
	}
	oid: odb.Oid
	binary := false
	clean := tracked && index_clean(e, stat, kind, st.index_mtime)
	if clean {
		oid = e.oid
		binary = stat.size > m.opts.large_limit
	} else {
		if stat.size > m.opts.large_limit {
			binary = true
		} else if stat.size > 0 {
			b, serr := sniff_binary(m, abs)
			if serr != .None {
				return .None
			}
			binary = b
		}
		o, werr := store_file(m, abs, &st.pack if st.use_pack else nil)
		if werr != .None {
			return .None
		}
		oid = o
	}
	if binary {
		flags += {.Opaque}
	}
	inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = it.name, kind = .File, flags = flags})
	if binary {
		builder_content(&st.b, inode, oid, stat.size)
	} else if stat.size > 0 {
		first, last := builder_insert_ref(&st.b, inode, 0, oid, int(stat.size))
		append(&st.b.imports, Import_File{inode = inode, oid = oid, len = stat.size, first = first, last = last})
	} else {
		append(&st.b.imports, Import_File{inode = inode, oid = oid, len = 0, last = crdt.Op_Id{st.b.actor, inode.seq}})
	}
	shadow_append(&m.shadow, it.path, Entry{inode = inode, kind = .File, stat = stat, oid = oid}) or_return
	st.files += 1
	return .None
}

@(private)
import_flush :: proc(st: ^Import_State) -> Error {
	m := st.m
	if st.use_pack && odb.pack_count(&st.pack) > 0 {
		if _, err := odb.pack_finish(&st.pack); err != .None {
			return from_odb(err)
		}
		st.use_pack = odb.pack_begin(&st.pack, m.db) == .None
	}
	if len(st.b.imports) == 0 && st.b.n > 0 {
		append(&st.b.imports, Import_File{inode = fstree.ROOT, len = -1})
	}
	builder_commit_import(m, &st.b) or_return
	shadow_persist(&m.shadow) or_return
	clear(&m.intents)
	save_mount_state(m) or_return
	history_trim(m.history)
	st.files = 0
	virtual.arena_destroy(&st.chunk)
	if virtual.arena_init_growing(&st.chunk, 1 << 20) != nil {
		return .No_Memory
	}
	context.temp_allocator = virtual.arena_allocator(&st.chunk)
	builder_init(&st.b, m.history, m.actor)
	return .None
}

@(private)
builder_commit_import :: proc(m: ^Mount, b: ^Builder) -> Error {
	if b.n == 0 {
		return .None
	}
	h := m.history
	batch := crdt.Batch {
		actor   = b.actor,
		seq     = b.seq0,
		lamport = history_lamport_after(h, m.synced[:]),
		parents = m.synced[:],
		ops     = b.ops[:],
	}
	append(&m.intents, Intent{b.actor, b.seq0, u64(b.n)})
	save_mount_state(m) or_return
	history_commit_import(h, &batch) or_return
	clear(&m.synced)
	append(&m.synced, crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1})
	set_line(m) or_return
	builder_reset(b)
	return .None
}

@(private)
import_cache_tree :: proc(m: ^Mount) -> Error {
	ct, err := index_cache_tree(m.vfs, m.git.dir, m.db.format, context.temp_allocator)
	if err != .None {
		return .None
	}
	defer cache_tree_destroy(&ct)
	for dir, node in ct.nodes {
		if len(dir) == 0 {
			continue
		}
		e, found := shadow_get(&m.shadow, dir) or_return
		if found && e.kind == .Dir {
			e.oid = node.oid
			shadow_put(&m.shadow, dir, e) or_return
		}
		if shadow_pending_count(&m.shadow) >= 65536 {
			shadow_persist(&m.shadow) or_return
		}
	}
	return shadow_persist(&m.shadow)
}

@(private)
Change_Kind :: enum u8 {
	Create,
	Remove,
	Modify,
}

@(private)
Change :: struct {
	kind:   Change_Kind,
	path:   string,
	disk:   Disk_Kind,
	stat:   Stat,
	target: string,
	old:    Entry,
	scope:   ^Scope,
	moved:   string,
	carried: bool,
}

@(private)
Pass :: struct {
	m:          ^Mount,
	changes:    [dynamic]Change,
	seen:       map[string]bool,
	young:      [dynamic]string,
	scope_of:   map[string]^Scope,
	cutoff:     i64,
	settle:     bool,
	full:       bool,
	git_wrote:  bool,
	head_moved: bool,
	marked:     bool,
	operation:  string,
	head:       Git_Head,
	long:       runtime.Allocator,
	chunk:      virtual.Arena,
}

PASS_CHUNK :: 4096

mount_pass :: proc(m: ^Mount, full: bool, settle := false) -> Error {
	long: virtual.Arena
	if virtual.arena_init_growing(&long, 256 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&long)
	p: Pass
	p.m = m
	p.long = virtual.arena_allocator(&long)
	if virtual.arena_init_growing(&p.chunk, 1 << 20) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&p.chunk)
	context.temp_allocator = virtual.arena_allocator(&p.chunk)
	mount_wake(m) or_return
	if m.history != nil {
		defer history_trim(m.history)
	}
	if m.has_git {
		p.head, _ = git_head(m.vfs, m.git, p.long)
		p.head_moved = !git_head_equal(p.head, m.head)
		stamp := git_index_stamp(m.vfs, m.git)
		commits_only, _, rewritten := git_reflog_commits_only(m.vfs, m.git, m.reflog_pos)
		p.operation = git_operation(m.vfs, m.git)
		p.git_wrote = (p.head_moved && (!commits_only || rewritten)) || (p.operation != "" && stamp != m.stamp)
	}
	p.changes = make([dynamic]Change, p.long)
	p.seen = make(map[string]bool, p.long)
	p.young = make([dynamic]string, p.long)
	p.scope_of = make(map[string]^Scope, p.long)
	p.settle = settle && !p.git_wrote
	p.cutoff = prim.now_ns() - m.opts.settle_ms * 1_000_000
	p.full = full || m.rescan || p.git_wrote
	keys := make([dynamic]string, 0, len(m.dirty), p.long)
	for k, v in m.dirty {
		c, _ := clone_string(k, p.long)
		p.scope_of[c] = v
		append(&keys, c)
	}
	for k in m.dirty {
		delete(k, m.allocator)
	}
	clear(&m.dirty)
	m.rescan = false
	m.git_moved = false
	if p.full {
		collect_full(&p) or_return
	} else {
		slice.sort_by(keys[:], proc(a, b: string) -> bool {return git_path_cmp(a, false, b, false) < 0})
		for k in keys {
			collect_path(&p, k) or_return
			pass_maybe_flush(&p) or_return
		}
	}
	pass_flush(&p) or_return
	for y in p.young {
		k, _ := clone_string(y, m.allocator)
		m.dirty[k] = p.scope_of[y]
	}
	if p.head_moved && m.has_git && !p.git_wrote {
		b: Builder
		builder_init(&b, m.history, m.actor)
		buf := make([dynamic]u8, context.temp_allocator)
		encode_git_op(&buf, "commit", p.head.branch, p.head.commit)
		builder_opaque(&b, buf[:])
		builder_commit(m, &b) or_return
	}
	if m.has_git {
		git_head_destroy(&m.head, m.allocator)
		m.head.branch, _ = clone_string(p.head.branch, m.allocator)
		m.head.commit, _ = clone_string(p.head.commit, m.allocator)
		m.reflog_pos = git_reflog_len(m.vfs, m.git)
		m.stamp = git_index_stamp(m.vfs, m.git)
	}
	shadow_persist(&m.shadow) or_return
	clear(&m.intents)
	if len(m.dirty) > 0 {
		mount_schedule(m, m.opts.settle_ms)
	}
	return save_mount_state(m)
}

@(private)
pass_maybe_flush :: proc(p: ^Pass) -> Error {
	if len(p.changes) < PASS_CHUNK {
		return .None
	}
	return pass_flush(p)
}

@(private)
pass_flush :: proc(p: ^Pass) -> Error {
	m := p.m
	if len(p.changes) == 0 && !(p.git_wrote && !p.marked) {
		return .None
	}
	for &c in p.changes {
		c.scope = p.scope_of[c.path]
		if c.scope == nil {
			for q := path_parent(c.path); len(q) > 0; q = path_parent(q) {
				if sc, ok := p.scope_of[q]; ok {
					c.scope = sc
					break
				}
			}
		}
	}
	detect_moves(p)
	if p.git_wrote {
		b: Builder
		builder_init(&b, m.history, m.actor)
		if !p.marked {
			buf := make([dynamic]u8, context.temp_allocator)
			kind := p.operation if p.operation != "" else "checkout"
			if !p.head_moved {
				kind = p.operation if p.operation != "" else "git"
			}
			encode_git_op(&buf, kind, p.head.branch, p.head.commit)
			builder_opaque(&b, buf[:])
			p.marked = true
		}
		all := make([dynamic]int, 0, len(p.changes), context.temp_allocator)
		for _, i in p.changes {
			append(&all, i)
		}
		emit_order(p, all[:])
		for i in all {
			emit_change(p, &b, &p.changes[i]) or_return
		}
		builder_commit(m, &b) or_return
	} else {
		groups := make(map[prim.Id][dynamic]int, context.temp_allocator)
		order := make([dynamic]prim.Id, context.temp_allocator)
		for c, i in p.changes {
			actor := m.actor if c.scope == nil else c.scope.actor
			if _, ok := groups[actor]; !ok {
				groups[actor] = make([dynamic]int, context.temp_allocator)
				append(&order, actor)
			}
			l := groups[actor]
			append(&l, i)
			groups[actor] = l
		}
		for actor in order {
			b: Builder
			builder_init(&b, m.history, actor)
			emit_order(p, groups[actor][:])
			for i in groups[actor] {
				emit_change(p, &b, &p.changes[i]) or_return
			}
			builder_commit(m, &b) or_return
		}
	}
	shadow_persist(&m.shadow) or_return
	clear(&m.intents)
	save_mount_state(m) or_return
	history_trim(m.history)
	clear(&p.changes)
	virtual.arena_free_all(&p.chunk)
	return .None
}

@(private)
Probe :: struct {
	kind:   Disk_Kind,
	stat:   Stat,
	target: string,
}

@(private)
probe :: proc(m: ^Mount, rel: string) -> Probe {
	abuf: prim.Path_Buf
	abs := abs_path(m, rel, abuf[:])
	st, err := prim.lstat(m.vfs, abs)
	if err != .None {
		return {kind = .Missing}
	}
	out := Probe{kind = disk_kind(st.kind), stat = disk_stat(st)}
	if out.kind == .Symlink {
		tbuf: [prim.PATH_MAX]u8
		n, lerr := prim.readlink(m.vfs, abs, tbuf[:])
		if lerr != .None {
			return {kind = .Missing}
		}
		out.target, _ = clone_string(string(tbuf[:n]), context.temp_allocator)
	}
	return out
}

@(private)
collect_path :: proc(p: ^Pass, rel: string) -> Error {
	m := p.m
	if len(rel) == 0 || path_internal(rel) || p.seen[rel] {
		return .None
	}
	for q := path_parent(rel); len(q) > 0; q = path_parent(q) {
		if p.seen[q] {
			e, found := shadow_get(&m.shadow, q) or_return
			if !found || e.kind != .Dir {
				return .None
			}
		}
	}
	d := probe(m, rel)
	e, found := shadow_get(&m.shadow, rel) or_return
	if !found {
		if d.kind == .Missing || d.kind == .Other {
			return .None
		}
		if !parent_tracked(p, rel) {
			parent := path_parent(rel)
			if len(parent) > 0 {
				return collect_path(p, parent)
			}
			return .None
		}
		if ignore_path(&m.ignore, m.root, rel, d.kind == .Dir) {
			return .None
		}
		add_create(p, rel, d) or_return
		if d.kind == .Dir {
			collect_subtree(p, rel) or_return
		}
		return .None
	}
	switch {
	case d.kind == .Missing || d.kind == .Other || disk_to_tree(d.kind) != e.kind:
		add_remove_tree(p, rel, e) or_return
		if d.kind != .Missing && d.kind != .Other {
			add_create(p, rel, d) or_return
			if d.kind == .Dir {
				collect_subtree(p, rel) or_return
			}
		}
	case d.kind == .Dir:
		mark_seen(p, rel)
		compare_dir(p, rel) or_return
	case d.kind == .File:
		if d.stat != e.stat {
			if p.settle && d.stat.mtime_ns > p.cutoff {
				append(&p.young, clone_string(rel, p.long) or_else "")
				return .None
			}
			add_modify(p, rel, d, e)
		}
	case d.kind == .Symlink:
		add_modify(p, rel, d, e)
	}
	return .None
}

@(private)
mark_seen :: proc(p: ^Pass, rel: string) {
	if p.full {
		return
	}
	k, _ := clone_string(rel, p.long)
	p.seen[k] = true
}

@(private)
parent_tracked :: proc(p: ^Pass, rel: string) -> bool {
	parent := path_parent(rel)
	if len(parent) == 0 {
		return true
	}
	for c in p.changes {
		if c.kind == .Create && c.path == parent && c.disk == .Dir {
			return true
		}
	}
	e, found, _ := shadow_get(&p.m.shadow, parent)
	return found && e.kind == .Dir
}

@(private)
disk_to_tree :: proc(k: Disk_Kind) -> fstree.Kind {
	#partial switch k {
	case .Dir:
		return .Dir
	case .Symlink:
		return .Symlink
	}
	return .File
}

@(private)
add_create :: proc(p: ^Pass, rel: string, d: Probe) -> Error {
	c := Change {
		kind   = .Create,
		path   = clone_string(rel, context.temp_allocator) or_else "",
		disk   = d.kind,
		stat   = d.stat,
		target = d.target,
	}
	mark_seen(p, c.path)
	append(&p.changes, c)
	return .None
}

@(private)
add_modify :: proc(p: ^Pass, rel: string, d: Probe, e: Entry) {
	c := Change {
		kind   = .Modify,
		path   = clone_string(rel, context.temp_allocator) or_else "",
		disk   = d.kind,
		stat   = d.stat,
		target = d.target,
		old    = e,
	}
	mark_seen(p, c.path)
	append(&p.changes, c)
}

@(private)
add_remove_tree :: proc(p: ^Pass, rel: string, e: Entry) -> Error {
	m := p.m
	if e.kind == .Dir {
		heap := runtime.heap_allocator()
		kids := make([dynamic]Shadow_Child, heap)
		defer {
			shadow_children_free(kids[:], heap)
			delete(kids)
		}
		shadow_children(&m.shadow, rel, &kids, heap) or_return
		own, _ := clone_string(rel, heap)
		defer delete(own, heap)
		cbuf: [prim.PATH_MAX]u8
		for k in kids {
			child, ok := path_join_buf(cbuf[:], own, k.name)
			if !ok {
				continue
			}
			add_remove_tree(p, child, k.entry) or_return
			pass_maybe_flush(p) or_return
		}
		c := Change {
			kind = .Remove,
			path = clone_string(own, context.temp_allocator) or_else "",
			old  = e,
		}
		mark_seen(p, c.path)
		append(&p.changes, c)
		return .None
	}
	c := Change {
		kind = .Remove,
		path = clone_string(rel, context.temp_allocator) or_else "",
		old  = e,
	}
	mark_seen(p, c.path)
	append(&p.changes, c)
	return .None
}

@(private)
compare_dir :: proc(p: ^Pass, rel: string) -> Error {
	m := p.m
	heap := runtime.heap_allocator()
	own, _ := clone_string(rel, heap)
	defer delete(own, heap)
	kids := make([dynamic]Shadow_Child, heap)
	defer {
		shadow_children_free(kids[:], heap)
		delete(kids)
	}
	shadow_children(&m.shadow, own, &kids, heap) or_return
	abuf: prim.Path_Buf
	abs := abs_path(m, own, abuf[:])
	d: prim.Dir
	if err := prim.dir_open(m.vfs, &d, abs, heap); err != .None {
		return .None
	}
	names := make(map[string]bool, heap)
	defer {
		for k in names {
			delete(k, heap)
		}
		delete(names)
	}
	for {
		de, more, err := prim.dir_next(m.vfs, &d)
		if err != .None || !more {
			break
		}
		if de.name == "." || de.name == ".." || name_internal(de.name) {
			continue
		}
		names[clone_string(de.name, heap) or_else ""] = true
	}
	prim.dir_close(m.vfs, &d)
	cbuf: [prim.PATH_MAX]u8
	for k in kids {
		child, ok := path_join_buf(cbuf[:], own, k.name)
		if !ok {
			continue
		}
		if !names[k.name] {
			if !p.seen[child] {
				add_remove_tree(p, child, k.entry) or_return
			}
		} else if k.entry.kind != .Dir {
			collect_path(p, child) or_return
		}
		pass_maybe_flush(p) or_return
	}
	for name in names {
		found := false
		for k in kids {
			if k.name == name {
				found = true
				break
			}
		}
		if found {
			continue
		}
		child, ok := path_join_buf(cbuf[:], own, name)
		if !ok {
			continue
		}
		collect_path(p, child) or_return
		pass_maybe_flush(p) or_return
	}
	return .None
}

@(private)
collect_subtree :: proc(p: ^Pass, rel: string) -> Error {
	m := p.m
	heap := runtime.heap_allocator()
	own, _ := clone_string(rel, heap)
	defer delete(own, heap)
	chain, nodes := chain_for(m, own, heap)
	defer chain_free(nodes, heap)
	sc: Scanner
	scan_open(&sc, m.vfs, m.root, own, &m.ignore, chain, {threads = 1}) or_return
	defer scan_close(&sc)
	for {
		it, ok, err := scan_next(&sc)
		if err != .None || !ok {
			break
		}
		if it.ignored {
			if it.kind == .Dir {
				scan_skip(&sc)
			}
			continue
		}
		if it.kind == .Missing || it.kind == .Other {
			continue
		}
		_, found := shadow_get(&m.shadow, it.path) or_return
		if found {
			collect_path(p, it.path) or_return
			if it.kind == .Dir {
				scan_skip(&sc)
			}
		} else {
			add_create(p, it.path, Probe{kind = it.kind, stat = it.stat, target = clone_string(it.target, context.temp_allocator) or_else ""}) or_return
		}
		pass_maybe_flush(p) or_return
	}
	return .None
}

@(private)
chain_for :: proc(m: ^Mount, dir: string, allocator: runtime.Allocator) -> (chain: ^Ignore_Chain, nodes: [dynamic]^Ignore_Chain) {
	nodes = make([dynamic]^Ignore_Chain, allocator)
	cur := ""
	rest := dir
	pbuf: [prim.PATH_MAX]u8
	for {
		gp, gok := path_join_buf(pbuf[:], cur, ".gitignore")
		if gok {
			abuf: prim.Path_Buf
			abs := abs_path(m, gp, abuf[:])
			if st, err := prim.lstat(m.vfs, abs); err == .None && st.kind == .File {
				if data, rerr := prim.read_file(m.vfs, abs, allocator); rerr == .None {
					if r, perr := rules_parse(data, cur, allocator); perr == .None && r != nil {
						c := new(Ignore_Chain, allocator)
						c.rules = r
						c.parent = chain
						chain = c
						append(&nodes, c)
					}
					delete(data, allocator)
				}
			}
		}
		if len(rest) == 0 {
			break
		}
		i := 0
		for i < len(rest) && rest[i] != '/' {
			i += 1
		}
		cur = dir[:len(dir) - len(rest) + i]
		rest = rest[i + 1:] if i < len(rest) else ""
	}
	return
}

@(private)
chain_free :: proc(nodes: [dynamic]^Ignore_Chain, allocator: runtime.Allocator) {
	for c in nodes {
		rules_destroy(c.rules, allocator)
		free(c, allocator)
	}
	delete(nodes)
}

@(private)
collect_full :: proc(p: ^Pass) -> Error {
	m := p.m
	return compare_dir_deep(p, "", m.root_wd)
}

@(private)
compare_dir_deep :: proc(p: ^Pass, rel: string, wd: i32) -> Error {
	m := p.m
	heap := runtime.heap_allocator()
	kids := make([dynamic]Shadow_Child, heap)
	defer {
		shadow_children_free(kids[:], heap)
		delete(kids)
	}
	shadow_children(&m.shadow, rel, &kids, heap) or_return
	abuf: prim.Path_Buf
	abs := abs_path(m, rel, abuf[:])
	d: prim.Dir
	if err := prim.dir_open(m.vfs, &d, abs, heap); err != .None {
		return .None
	}
	names := make(map[string]bool, heap)
	defer {
		for k in names {
			delete(k, heap)
		}
		delete(names)
	}
	for {
		de, more, err := prim.dir_next(m.vfs, &d)
		if err != .None || !more {
			break
		}
		if de.name == "." || de.name == ".." || name_internal(de.name) {
			continue
		}
		names[clone_string(de.name, heap) or_else ""] = true
	}
	prim.dir_close(m.vfs, &d)
	cbuf: [prim.PATH_MAX]u8
	for k in kids {
		child, ok := path_join_buf(cbuf[:], rel, k.name)
		if !ok {
			continue
		}
		if !names[k.name] {
			add_remove_tree(p, child, k.entry) or_return
			continue
		}
		key: string
		for n in names {
			if n == k.name {
				key = n
				break
			}
		}
		delete_key(&names, k.name)
		delete(key, heap)
		dp := probe(m, child)
		if k.entry.kind == .Dir && dp.kind == .Dir {
			c, _ := clone_string(child, heap)
			cwd, _ := watch_dir(m.reg, m, c, wd)
			err := compare_dir_deep(p, c, cwd)
			delete(c, heap)
			err or_return
		} else if dp.kind == .File && k.entry.kind == .File && dp.stat == k.entry.stat {
			continue
		} else {
			collect_path(p, child) or_return
		}
		pass_maybe_flush(p) or_return
	}
	for name in names {
		child, ok := path_join_buf(cbuf[:], rel, name)
		if !ok {
			continue
		}
		collect_path(p, child) or_return
		if c := last_change(p); c != nil && c.path == child && c.kind == .Create && c.disk == .Dir {
			watch_dir(m.reg, m, child, wd)
		}
		pass_maybe_flush(p) or_return
	}
	return .None
}

@(private)
last_change :: proc(p: ^Pass) -> ^Change {
	for i := len(p.changes) - 1; i >= 0; i -= 1 {
		if p.changes[i].kind == .Create {
			return &p.changes[i]
		}
	}
	return nil
}

@(private)
Dir_Move :: struct {
	from: string,
	to:   string,
}

@(private)
detect_moves :: proc(p: ^Pass) {
	by_ino := make(map[u64]int, context.temp_allocator)
	for c, i in p.changes {
		if c.kind == .Remove && c.old.stat.ino != 0 {
			by_ino[c.old.stat.ino] = i
		}
	}
	moves := make([dynamic]Dir_Move, context.temp_allocator)
	for &c in p.changes {
		if c.kind != .Create || c.stat.ino == 0 {
			continue
		}
		ri, ok := by_ino[c.stat.ino]
		if !ok {
			continue
		}
		r := &p.changes[ri]
		if r.old.kind != disk_to_tree(c.disk) || r.moved != "" || r.carried {
			continue
		}
		carried := false
		for mv in moves {
			if path_under(r.path, mv.from) && path_under(c.path, mv.to) && r.path[len(mv.from):] == c.path[len(mv.to):] {
				carried = true
				break
			}
		}
		if carried {
			r.carried = true
			c.carried = true
			c.old = r.old
			c.kind = .Modify
			continue
		}
		r.moved = c.path
		c.old = r.old
		c.moved = r.path
		if c.disk == .Dir {
			append(&moves, Dir_Move{r.path, c.path})
		}
	}
	for &c in p.changes {
		if c.kind != .Remove || c.carried || c.moved != "" {
			continue
		}
		for mv in moves {
			if path_under(c.path, mv.from) {
				np, _ := path_join(mv.to, c.path[len(mv.from) + 1:], context.temp_allocator)
				c.path = np
				break
			}
		}
	}
}

@(private)
emit_order :: proc(p: ^Pass, idx: []int) {
	context.user_ptr = p
	slice.stable_sort_by(idx, proc(a, b: int) -> bool {
		pp := (^Pass)(context.user_ptr)
		ca := &pp.changes[a]
		cb := &pp.changes[b]
		ma := ca.kind == .Create && ca.moved != ""
		mb := cb.kind == .Create && cb.moved != ""
		if ma != mb {
			return ma
		}
		if ma {
			return count_depth(ca.path) < count_depth(cb.path)
		}
		return false
	})
}

@(private)
find_change :: proc(p: ^Pass, path: string, kind: Change_Kind) -> (int, bool) {
	for c, i in p.changes {
		if c.kind == kind && c.path == path {
			return i, true
		}
	}
	return 0, false
}

@(private)
parent_inode :: proc(p: ^Pass, rel: string) -> (fstree.Inode_Id, bool) {
	parent := path_parent(rel)
	if len(parent) == 0 {
		return fstree.ROOT, true
	}
	e, found, _ := shadow_get(&p.m.shadow, parent)
	if found && e.kind == .Dir {
		return e.inode, true
	}
	return {}, false
}

@(private)
emit_change :: proc(p: ^Pass, b: ^Builder, c: ^Change) -> Error {
	m := p.m
	switch c.kind {
	case .Remove:
		if c.moved != "" || c.carried {
			return .None
		}
		builder_tree(b, fstree.Op_Remove{inode = c.old.inode})
		shadow_remove(&m.shadow, c.path) or_return
	case .Create:
		parent, ok := parent_inode(p, c.path)
		if !ok {
			mount_mark(m, c.path)
			return .None
		}
		if c.moved != "" {
			builder_tree(b, fstree.Op_Move{inode = c.old.inode, parent = parent, name = path_name(c.path)})
			if c.old.kind == .Dir {
				watch_dir(m.reg, m, c.path, -1)
				move_shadow_tree(m, c.moved, c.path) or_return
				e := c.old
				e.stat = c.stat
				shadow_put(&m.shadow, c.path, e) or_return
				return .None
			}
			shadow_remove(&m.shadow, c.moved) or_return
			e := c.old
			shadow_put(&m.shadow, c.path, e) or_return
			if c.disk == .File && c.stat != c.old.stat {
				return emit_modify(p, b, c, e)
			}
			if c.disk == .Symlink {
				return emit_modify(p, b, c, e)
			}
			return .None
		}
		return emit_create(p, b, c, parent)
	case .Modify:
		if c.carried {
			if c.disk == .Dir {
				e := c.old
				e.stat = c.stat
				return shadow_put(&m.shadow, c.path, e)
			}
			if c.disk == .File && c.stat == c.old.stat {
				return .None
			}
		}
		return emit_modify(p, b, c, c.old)
	}
	return .None
}

@(private)
move_shadow_tree :: proc(m: ^Mount, from, to: string) -> Error {
	kids := make([dynamic]Shadow_Child, context.temp_allocator)
	shadow_children(&m.shadow, from, &kids, context.temp_allocator) or_return
	for k in kids {
		a, _ := path_join(from, k.name, context.temp_allocator)
		b, _ := path_join(to, k.name, context.temp_allocator)
		if k.entry.kind == .Dir {
			move_shadow_tree(m, a, b) or_return
		}
		shadow_remove(&m.shadow, a) or_return
		shadow_put(&m.shadow, b, k.entry) or_return
	}
	return shadow_remove(&m.shadow, from)
}

@(private)
emit_create :: proc(p: ^Pass, b: ^Builder, c: ^Change, parent: fstree.Inode_Id) -> Error {
	m := p.m
	name := path_name(c.path)
	if !fstree.valid_name(name) {
		return .None
	}
	switch c.disk {
	case .Dir:
		inode := builder_tree(b, fstree.Op_Create{parent = parent, name = name, kind = .Dir})
		shadow_put(&m.shadow, c.path, Entry{inode = inode, kind = .Dir, stat = c.stat}) or_return
		watch_dir(m.reg, m, c.path, -1)
	case .Symlink:
		inode := builder_tree(b, fstree.Op_Create{parent = parent, name = name, kind = .Symlink, target = c.target})
		oid: odb.Oid
		if m.db != nil {
			oid, _ = odb.hash(m.db.format, .Blob, transmute([]u8)c.target)
		}
		shadow_put(&m.shadow, c.path, Entry{inode = inode, kind = .Symlink, stat = c.stat, oid = oid}) or_return
	case .File:
		data, oid, binary, ok := read_content(m, c.path, c.stat) or_return
		if !ok {
			return .None
		}
		flags: fstree.Flags
		if c.stat.mode & 0o100 != 0 {
			flags += {.Exec}
		}
		if binary {
			flags += {.Opaque}
		}
		if (binary || len(data) > m.opts.inline_limit) && data != nil {
			store_blob(m, data) or_return
		}
		inode := builder_tree(b, fstree.Op_Create{parent = parent, name = name, kind = .File, flags = flags})
		if binary {
			builder_content(b, inode, oid, c.stat.size)
		} else if len(data) > m.opts.inline_limit {
			builder_insert_ref(b, inode, 0, oid, len(data))
		} else {
			builder_insert(b, inode, 0, data)
		}
		shadow_put(&m.shadow, c.path, Entry{inode = inode, kind = .File, stat = c.stat, oid = oid}) or_return
	case .Missing, .Other:
	}
	return .None
}

@(private)
read_content :: proc(m: ^Mount, rel: string, stat: Stat) -> (data: []u8, oid: odb.Oid, binary: bool, ok: bool, err: Error) {
	abuf: prim.Path_Buf
	abs := abs_path(m, rel, abuf[:])
	if stat.size > m.opts.large_limit {
		o, werr := store_file(m, abs, nil)
		if werr != .None {
			return nil, {}, true, false, .None
		}
		return nil, o, true, true, .None
	}
	d, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
	if rerr != .None {
		return nil, {}, false, false, .None
	}
	binary = textdiff.is_binary(d)
	if m.db != nil {
		o, herr := odb.hash(m.db.format, .Blob, d)
		if herr != .None {
			return nil, {}, false, false, from_odb(herr)
		}
		oid = o
	}
	return d, oid, binary, true, .None
}

@(private)
store_blob :: proc(m: ^Mount, data: []u8) -> Error {
	if m.db == nil {
		return .Invalid
	}
	_, err := odb.write(m.db, .Blob, data)
	return from_odb(err)
}

@(private)
emit_modify :: proc(p: ^Pass, b: ^Builder, c: ^Change, e: Entry) -> Error {
	m := p.m
	h := m.history
	path := c.path
	if c.disk == .Symlink {
		if m.db != nil {
			oid, _ := odb.hash(m.db.format, .Blob, transmute([]u8)c.target)
			if oid == e.oid {
				ne := e
				ne.stat = c.stat
				return shadow_put(&m.shadow, path, ne)
			}
			builder_tree(b, fstree.Op_Set_Target{inode = e.inode, target = c.target})
			ne := e
			ne.stat = c.stat
			ne.oid = oid
			return shadow_put(&m.shadow, path, ne)
		}
		return .None
	}
	data, oid, binary, ok := read_content(m, path, c.stat) or_return
	if !ok {
		return .None
	}
	ne := e
	ne.stat = c.stat
	ne.oid = oid
	old_flags := tree_flags(h, e.inode)
	exec := c.stat.mode & 0o100 != 0
	if exec != (.Exec in old_flags) {
		builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Exec}, value = {.Exec} if exec else {}})
	}
	if oid == e.oid && m.db != nil {
		return shadow_put(&m.shadow, path, ne)
	}
	was_binary := .Opaque in old_flags
	if binary {
		if data != nil {
			store_blob(m, data) or_return
		}
		if !was_binary {
			builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Opaque}, value = {.Opaque}})
		}
		builder_content(b, e.inode, oid, c.stat.size)
		return shadow_put(&m.shadow, path, ne)
	}
	old := history_text_at(h, e.inode, m.synced[:], context.temp_allocator) or_return
	if was_binary {
		builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Opaque}, value = {}})
	}
	edits, derr := textdiff.byte_diff(old, data, context.temp_allocator)
	if derr != nil {
		builder_delete(b, e.inode, 0, len(old))
		if len(data) > m.opts.inline_limit {
			store_blob(m, data) or_return
			builder_insert_ref(b, e.inode, 0, oid, len(data))
		} else {
			builder_insert(b, e.inode, 0, data)
		}
		return shadow_put(&m.shadow, path, ne)
	}
	for ed in edits {
		builder_delete(b, e.inode, int(ed.pos), int(ed.del))
		ins := data[ed.pos:][:ed.ins]
		if len(ins) > m.opts.inline_limit {
			sub, werr := odb.write(m.db, .Blob, ins)
			if werr == .None {
				builder_insert_ref(b, e.inode, int(ed.pos), sub, len(ins))
				continue
			}
		}
		builder_insert(b, e.inode, int(ed.pos), ins)
	}
	return shadow_put(&m.shadow, path, ne)
}

@(private)
tree_flags :: proc(h: ^History, inode: fstree.Inode_Id) -> fstree.Flags {
	n, err := fstree.get(&h.tree, inode)
	if err != nil || n == nil {
		return {}
	}
	return n.flags
}

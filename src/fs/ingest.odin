package fs

import "base:runtime"
import "core:bytes"
import "core:crypto/blake2b"
import "core:strings"
import "core:mem/virtual"
import "core:slice"
import "../crdt"
import "../fshist"
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
	local:   bool,
	scope:   []u8,
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
	encode_tree_op(b.h, &buf, op, Local_Actor{b.aix, b.actor, b.local})
	return builder_opaque(b, buf[:])
}

@(private)
builder_content :: proc(b: ^Builder, inode: fstree.Inode_Id, oid: odb.Oid, size: i64) {
	buf := make([dynamic]u8, context.temp_allocator)
	encode_content_op(b.h, &buf, inode, oid, size, Local_Actor{b.aix, b.actor, b.local})
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
	ref.oid = crdt_oid(oid, b.h.db.format if b.h.db != nil else .Sha1)
	first = crdt.Op_Id{b.actor, b.seq0 + u64(b.n)}
	append(&b.ops, crdt.Op_Run{target = target_id(b, inode), kind = .Insert_Ref, pos = pos, len = n, ref = ref})
	b.n += n
	last = crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1}
	return
}

@(private)
builder_copy :: proc(b: ^Builder, inode: fstree.Inode_Id, pos: int, src: crdt.Op_Id, n: int) {
	if n <= 0 {
		return
	}
	r := crdt.Op_Run{target = target_id(b, inode), kind = .Insert_Copy, pos = pos, len = n}
	r.src = src
	append(&b.ops, r)
	b.n += n
}

@(private)
builder_copy_spans :: proc(b: ^Builder, inode: fstree.Inode_Id, pos: int, spans: []crdt.Author_Span, start: int, n: int) {
	from := start
	at := 0
	p := pos
	left := n
	for s in spans {
		if left <= 0 {
			break
		}
		end := at + s.len
		if end <= from {
			at = end
			continue
		}
		k := max(from - at, 0)
		take := min(s.len - k, left)
		builder_copy(b, inode, p, crdt.Op_Id{s.op.actor, s.op.seq + u64(k)}, take)
		p += take
		left -= take
		from += take
		at = end
	}
}

@(private)
note_builder_blob :: proc(b: ^Builder, inode: fstree.Inode_Id, oid: odb.Oid) {
	if b.n == 0 {
		return
	}
	v := [1]crdt.Op_Id{{b.actor, b.seq0 + u64(b.n) - 1}}
	history_note_file_blob(b.h, inode, oid, v[:])
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
	if b.scope != nil {
		builder_opaque(b, b.scope)
	}
	builder_opaque(b, commit_mark(m))
	batch.ops = b.ops[:]
	line: Maybe(string)
	if !m.hold_line {
		line = m.line
	}
	history_commit_local(h, &batch, line) or_return
	m.jpend = mount_jlen(m)
	clear(&m.synced)
	append(&m.synced, crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1})
	builder_reset(b)
	return .Reloading if history_reloading(h) else .None
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
	path:    string,
	inode:   fstree.Inode_Id,
	depth:   int,
	wd:      i32,
	kids:    [dynamic]odb.Tree_Entry,
	partial: bool,
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
store_file :: proc(m: ^Mount, abs: string, pack: ^odb.Pack_Builder, pin := true) -> (oid: odb.Oid, err: Error) {
	if m.db == nil {
		return {}, .Invalid
	}
	if pack != nil {
		o, perr := odb.pack_add_file(pack, abs)
		if perr == .None && pin {
			history_note_blob(m.history, o)
		}
		return o, from_odb(perr)
	}
	o, werr := odb.write_file(m.db, abs)
	if werr == .None && pin {
		history_note_blob(m.history, o)
	}
	return o, from_odb(werr)
}

@(private)
index_clean :: proc(e: ^Index_Entry, st: Stat, kind: Disk_Kind, index_mtime: i64, trust_exec := true, symlinks := true) -> bool {
	if e.stage != 0 || .Skip_Worktree in e.flags || .Intent_To_Add in e.flags || .Sparse_Dir in e.flags {
		return false
	}
	mtime := i64(e.mtime_s) * 1_000_000_000 + i64(e.mtime_ns)
	when ODIN_OS == .Windows {
		if mtime != st.mtime_ns || u32(st.size) != e.size {
			return false
		}
	} else {
		ctime := i64(e.ctime_s) * 1_000_000_000 + i64(e.ctime_ns)
		if mtime != st.mtime_ns || ctime != st.ctime_ns || u32(st.size) != e.size || u32(st.ino) != e.ino {
			return false
		}
	}
	if mtime >= index_mtime {
		return false
	}
	switch e.mode & 0o170000 {
	case 0o100000:
		return kind == .File && (!trust_exec || (e.mode & 0o111 != 0) == (st.mode & 0o100 != 0))
	case 0o120000:
		return kind == .Symlink || (!symlinks && kind == .File)
	}
	return false
}

@(private)
Import_State :: struct {
	resync:     bool,
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
	adopt:     bool,
	snap:      fstree.Snapshot,
	line:      []crdt.Lv,
	dirty_dirs: map[string]bool,
	packp:     ^odb.Pack_Builder,
	cur:       ^Pipe_Chunk,
	pipe:      ^Pipe,
}

mount_import :: proc(m: ^Mount) -> Error {
	attr_begin(m)
	defer attr_end(m)
	held := m.shadow.hold
	m.shadow.hold = false
	defer m.shadow.hold = held
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
	if m.history != nil && (m.adopt_pending || (empty && len(m.synced) == 0)) {
		if line, has := history_line(m.history, m.line, st.long) or_return; has && len(line) > 0 {
			lvs := make([dynamic]crdt.Lv, st.long)
			if crdt.graph_version_lvs(&m.history.g, line, &lvs) == .None {
				st.snap = version_snapshot(m.history, lvs[:]) or_return
				st.line = lvs[:]
				st.adopt = true
				if !m.adopt_pending {
					m.adopt_pending = true
					m.img.adopt_pending = true
					save_mount_state(m) or_return
				}
				clear(&m.synced)
				append(&m.synced, ..line)
			}
		}
	} else if m.history != nil && len(m.synced) > 0 {
		lvs := make([dynamic]crdt.Lv, st.long)
		if crdt.graph_version_lvs(&m.history.g, m.synced[:], &lvs) == .None {
			st.snap = version_snapshot(m.history, lvs[:]) or_return
			st.line = lvs[:]
			st.resync = true
		}
	}
	defer if st.adopt || st.resync {
		fstree.snapshot_destroy(&st.snap)
	}
	builder_init(&st.b, m.history, m.actor)
	st.stack = make([dynamic]Dir_Frame, st.long)
	st.path_buf = make([dynamic]u8, st.long)
	st.dirty_dirs = make(map[string]bool, st.long)
	append(&st.stack, Dir_Frame{path = "", inode = fstree.ROOT, depth = 0, wd = m.root_wd, partial = true})
	defer for &f in st.stack {
		frame_free(&f)
	}
	if m.has_git && m.db != nil {
		if index_open(&st.index, m.vfs, m.git.dir, m.git_format, st.long) == .None {
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
	st.use_pack = !m.has_git && m.db != nil
	pipe := new(Pipe, runtime.heap_allocator())
	if pipe == nil {
		return .No_Memory
	}
	defer free(pipe, runtime.heap_allocator())
	pipe_start(&st, pipe) or_return
	defer if st.cur != nil {
		chunk_free(st.cur)
		st.cur = nil
	}
	defer if st.pipe != nil {
		pipe_finish(&st)
	}
	context.temp_allocator = runtime.Allocator{chunk_allocator_proc, &st} if st.cur != nil else virtual.arena_allocator(&st.chunk)
	if st.pipe != nil {
		pipe_builder(&st)
	}
	sc: Scanner
	sopts := Scan_Options {
		threads = m.opts.threads,
	}
	if st.use_pack {
		sopts.read_limit = min(m.opts.large_limit, 1 << 20)
		sopts.read_budget = 8 << 20
	}
	scan_open(&sc, m.vfs, m.root, "", &m.ignore, nil, sopts) or_return
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
			import_dir_pop(&st) or_return
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
					import_tracked_under(&st, it, parent, &sc) or_return
					continue
				}
				scan_skip(&sc)
			}
			continue
		}
		if it.kind == .Dir && tracked && entry.mode & 0o170000 == 0o160000 {
			import_gitlink(&st, it, parent) or_return
			scan_skip(&sc)
			continue
		}
		if st.resume {
			have, found := shadow_get(&m.shadow, it.path) or_return
			if found {
				st.stack[len(st.stack) - 1].partial = true
				if it.kind == .Dir && have.kind == .Dir {
					wd, _ := watch_dir(m.reg, m, it.path, parent.wd)
					p, _ := clone_string(it.path, st.long)
					append(&st.stack, Dir_Frame{path = p, inode = have.inode, depth = it.depth, wd = wd, partial = true})
				} else if it.kind == .Dir {
					scan_skip(&sc)
				}
				continue
			}
		}
		if (st.adopt || st.resync) && import_adopt(&st, it, parent, tracked, &entry) {
			continue
		}
		switch it.kind {
		case .Dir:
			import_dir(&st, it, parent, &sc) or_return
		case .File, .Symlink:
			import_file(&st, it, parent, tracked, &entry) or_return
		case .Missing, .Other:
		}
		chunk := m.opts.import_chunk
		if st.pipe != nil {
			if st.b.n > 0 && (st.files >= chunk || len(st.cur.shadow) >= 65536) {
				pipe_rotate(&st, false) or_return
				pipe_builder(&st)
			}
		} else if st.b.n > 0 && (st.files >= chunk || shadow_pending_count(&m.shadow) >= 65536) {
			import_flush(&st) or_return
		}
	}
	if st.pipe != nil {
		for len(st.stack) > 1 {
			import_dir_pop(&st) or_return
		}
		pipe_rotate(&st, true) or_return
		pipe_finish(&st) or_return
	} else {
		import_flush(&st) or_return
	}
	if !m.hold_line {
		set_line(m) or_return
	}
	if m.has_git && m.db != nil {
		for st.have_entry {
			mark_dirty_dirs(&st, st.entry.path)
			index_advance(&st) or_return
		}
		import_cache_tree(m, &st.dirty_dirs) or_return
	}
	if m.db != nil {
		mount_commit(m, {message = "0ndb: first mount"}) or_return
	}
	m.imported = true
	adopt_finish(m) or_return
	_heap_release()
	return mount_settle(m)
}

@(private)
adopt_finish :: proc(m: ^Mount) -> Error {
	if !m.adopt_pending {
		return .None
	}
	line, has := history_line(m.history, m.line, context.temp_allocator) or_return
	if has {
		clear(&m.synced)
		m.adopting = true
		merr := materialize_to(m, line, false)
		m.adopting = false
		merr or_return
	}
	m.adopt_pending = false
	return .None
}

@(private)
import_adopt :: proc(st: ^Import_State, it: ^Scan_Item, parent: Dir_Frame, tracked: bool, entry: ^Index_Entry) -> bool {
	m := st.m
	ino, found, lerr := fstree.lookup(&st.snap, it.path)
	if lerr != nil || !found {
		return false
	}
	info, ok, ierr := fstree.info(&st.snap, ino, context.temp_allocator)
	if ierr != nil || !ok || !info.present {
		return false
	}
	want: fstree.Kind
	#partial switch it.kind {
	case .Dir:
		want = .Dir
	case .File:
		want = .File
	case .Symlink:
		want = .Symlink
	case:
		return false
	}
	if info.kind != want {
		if !(info.kind == .Symlink && want == .File && !mount_symlinks(m)) {
			return false
		}
		want = .Symlink
	}
	st.stack[len(st.stack) - 1].partial = true
	if want == .Dir {
		import_shadow(st, it.path, Entry{inode = ino, kind = .Dir, stat = it.stat})
		wd, _ := watch_dir(m.reg, m, it.path, parent.wd)
		p, _ := clone_string(it.path, st.long)
		append(&st.stack, Dir_Frame{path = p, inode = ino, depth = it.depth, wd = wd, partial = true})
		return true
	}
	e := Entry{inode = ino, kind = want}
	if want == .File {
		if oid, same := adopt_same(st, it, ino, info.flags, tracked, entry); same {
			e.stat = it.stat
			e.oid = oid
		}
	}
	import_shadow(st, it.path, e)
	return true
}

@(private)
adopt_same :: proc(st: ^Import_State, it: ^Scan_Item, ino: fstree.Inode_Id, flags: fstree.Flags, tracked: bool, entry: ^Index_Entry) -> (oid: odb.Oid, same: bool) {
	m := st.m
	h := m.history
	if !tracked || !m.git_refs || m.db == nil || !it.statted || !index_clean(entry, it.stat, .File, st.index_mtime, mount_trust_exec(m), mount_symlinks(m)) {
		return {}, false
	}
	if exec_bit(m, it.stat, .Exec in flags) != (.Exec in flags) {
		return {}, false
	}
	if .Opaque in flags {
		reg, has, err := history_blob_at(h, ino, st.line)
		return entry.oid, err == .None && has && odb.Oid(reg.oid) == entry.oid
	}
	rec: File_Record
	owned := false
	if f, ok := h.files[ino]; ok {
		if len(f.new_refs) > 0 {
			return {}, false
		}
		rec = f.rec
	} else {
		owned = true
		if read_file_record(h, ino, &rec) != .None {
			delete(rec.cp_version)
			delete(rec.cp_spans)
			return {}, false
		}
	}
	defer if owned {
		delete(rec.cp_version)
		delete(rec.cp_spans)
	}
	if !rec.has_cp || rec.ops != rec.cp_count || odb.Oid(rec.cp_text) != entry.oid {
		return {}, false
	}
	for id in rec.cp_version {
		lv, known := crdt.graph_lv(&h.g, id)
		if !known || !crdt.graph_contains(&h.g, st.line, lv) {
			return {}, false
		}
	}
	return entry.oid, true
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
		mark_dirty_dirs(st, st.entry.path)
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
import_tracked_under :: proc(st: ^Import_State, it: ^Scan_Item, parent: Dir_Frame, sc: ^Scanner) -> Error {
	m := st.m
	scan_skip(sc)
	if st.resume {
		if _, found := shadow_get(&m.shadow, it.path) or_return; !found {
			import_dir(st, it, parent, sc) or_return
		} else {
			return .None
		}
	} else {
		import_dir(st, it, parent, sc) or_return
	}
	top := it.path
	top_inode := st.stack[len(st.stack) - 1].inode
	dirs := make(map[string]fstree.Inode_Id, context.temp_allocator)
	dirs[clone_string(top, context.temp_allocator) or_else ""] = top_inode
	for st.have_entry && path_under(st.entry.path, top) {
		e := st.entry
		path, _ := clone_string(e.path, context.temp_allocator)
		pdir := path_parent(path)
		pino, have := dirs[pdir]
		if !have {
			cur := top
			pino = top_inode
			rest := pdir[len(top) + 1:]
			for len(rest) > 0 {
				i := 0
				for i < len(rest) && rest[i] != '/' {
					i += 1
				}
				next := pdir[:len(pdir) - len(rest) + i]
				if ino, ok := dirs[next]; ok {
					pino = ino
				} else {
					abuf: prim.Path_Buf
					dst, derr := prim.lstat(m.vfs, abs_path(m, next, abuf[:]))
					if derr != .None && !gone(derr) {
						return from_prim(derr)
					}
					if derr != .None || dst.kind != .Dir {
						break
					}
					created := builder_tree(&st.b, fstree.Op_Create{parent = pino, name = path_name(next), kind = .Dir})
					import_shadow(st, next, Entry{inode = created, kind = .Dir, stat = disk_stat(dst)}) or_return
					dirs[clone_string(next, context.temp_allocator) or_else ""] = created
					pino = created
				}
				cur = next
				rest = rest[i + 1:] if i < len(rest) else ""
			}
			if cur != pdir {
				index_advance(st) or_return
				continue
			}
		}
		abuf: prim.Path_Buf
		fst, ferr := prim.lstat(m.vfs, abs_path(m, path, abuf[:]))
		if ferr == .None && e.stage == 0 && (fst.kind == .File || fst.kind == .Symlink) {
			item := Scan_Item {
				path    = path,
				name    = path_name(path),
				kind    = disk_kind(fst.kind),
				statted = true,
				stat    = disk_stat(fst),
			}
			import_file(st, &item, Dir_Frame{path = pdir, inode = pino}, true, &e) or_return
		}
		index_advance(st) or_return
	}
	return .None
}

nested_repo :: proc(m: ^Mount, rel: string) -> bool {
	buf: prim.Path_Buf
	p, ok := path_join_buf(buf[:], m.root, rel, ".git")
	if !ok {
		return false
	}
	_, err := prim.lstat(m.vfs, p)
	return err == .None
}

@(private)
import_gitlink :: proc(st: ^Import_State, it: ^Scan_Item, parent: Dir_Frame) -> Error {
	m := st.m
	if !fstree.valid_name(it.name) {
		return .None
	}
	if st.resume {
		if _, found := shadow_get(&m.shadow, it.path) or_return; found {
			st.stack[len(st.stack) - 1].partial = true
			return .None
		}
	}
	if st.adopt || st.resync {
		if ino, found, lerr := fstree.lookup(&st.snap, it.path); lerr == nil && found {
			if info, ok, ierr := fstree.info(&st.snap, ino, context.temp_allocator); ierr == nil && ok && info.present && info.kind == .Dir {
				st.stack[len(st.stack) - 1].partial = true
				return import_shadow(st, it.path, Entry{inode = ino, kind = .Dir, stat = it.stat})
			}
		}
	}
	inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = it.name, kind = .Dir})
	return import_shadow(st, it.path, Entry{inode = inode, kind = .Dir, stat = it.stat})
}

@(private)
import_dir :: proc(st: ^Import_State, it: ^Scan_Item, parent: Dir_Frame, sc: ^Scanner) -> Error {
	m := st.m
	name := it.name
	if !fstree.valid_name(name) || nested_repo(m, it.path) {
		scan_skip(sc)
		return .None
	}
	inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = name, kind = .Dir})
	import_shadow(st, it.path, Entry{inode = inode, kind = .Dir, stat = it.stat}) or_return
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
		if gone(serr) {
			return .None
		}
		from_prim(serr) or_return
		stat = disk_stat(s)
		kind = disk_kind(s.kind)
	}
	link_text: string
	link_file := kind == .File && tracked && e.mode & 0o170000 == 0o120000 && !mount_symlinks(m)
	if link_file {
		link_text, link_file = read_link_file(m, abs, stat) or_return
	}
	if kind == .Symlink || link_file {
		target := it.target if !link_file else link_text
		if len(target) == 0 && !link_file {
			tbuf: [prim.PATH_MAX]u8
			n, lerr := prim.readlink(m.vfs, abs, tbuf[:])
			if gone(lerr) {
				return .None
			}
			from_prim(lerr) or_return
			target, _ = clone_string(string(tbuf[:n]), context.temp_allocator)
		}
		inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = it.name, kind = .Symlink, target = target})
		oid: odb.Oid
		if tracked && m.git_refs && index_clean(e, stat, kind, st.index_mtime, mount_trust_exec(m), mount_symlinks(m)) {
			oid = e.oid
		} else if m.db != nil {
			mark_dirty_dirs(st, it.path)
			o, werr := odb.write(m.db, .Blob, transmute([]u8)target)
			from_odb(werr) or_return
			oid = o
		}
		import_shadow(st, it.path, Entry{inode = inode, kind = .Symlink, stat = stat, oid = oid}) or_return
		frame_add(st, it.name, oid, odb.MODE_LINK)
		st.files += 1
		return .None
	}
	if kind != .File {
		return .None
	}
	flags: fstree.Flags
	exec := exec_bit(m, stat, tracked && e.mode & 0o170000 == 0o100000 && e.mode & 0o111 != 0)
	if exec {
		flags += {.Exec}
	}
	if m.has_git {
		flags += {.Git_Clean}
	}
	oid: odb.Oid
	binary := false
	size := stat.size
	clean := tracked && m.git_refs && index_clean(e, stat, kind, st.index_mtime, mount_trust_exec(m), mount_symlinks(m))
	if !clean {
		mark_dirty_dirs(st, it.path)
	}
	if clean && m.has_git && m.db != nil && conv_needed(m, it.path) {
		if _, hsize, herr := odb.read_header(m.db, e.oid); herr == .None {
			size = hsize
		} else {
			clean = false
			mark_dirty_dirs(st, it.path)
		}
	}
	if clean {
		oid = e.oid
		binary = size > m.opts.large_limit
	} else {
		if it.has_data && st.use_pack {
			binary = it.binary
			o, perr := odb.pack_add(st.packp, .Blob, it.data)
			from_odb(perr) or_return
			oid = o
		} else if m.has_git && m.db != nil && stat.size <= m.opts.large_limit && conv_needed(m, it.path) {
			d, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
			if gone(rerr) {
				return .None
			}
			from_prim(rerr) or_return
			cd, cok := eol_clean(m, it.path, d)
			if !cok {
				return .None
			}
			d = cd
			binary = textdiff.is_binary(d)
			o, werr := odb.write(m.db, .Blob, d)
			from_odb(werr) or_return
			oid = o
			size = i64(len(d))
		} else {
			if stat.size > m.opts.large_limit {
				binary = true
				co, csize, cst, cerr := store_large_clean(m, it.path, abs)
				if cerr == .Not_Found || cerr == .Not_Dir {
					return .None
				}
				cerr or_return
				if cst == .Failed {
					return .None
				}
				if cst == .Stored {
					oid = co
					size = csize
				}
			} else if stat.size > 0 {
				b, serr := sniff_binary(m, abs)
				if serr == .Not_Found || serr == .Not_Dir {
					return .None
				}
				serr or_return
				binary = b
			}
			if oid == {} {
				o, werr := store_file(m, abs, st.packp if st.use_pack else nil, false)
				if werr == .Not_Found || werr == .Not_Dir {
					return .None
				}
				werr or_return
				oid = o
			}
		}
	}
	if binary {
		flags += {.Opaque}
	}
	inode := builder_tree(&st.b, fstree.Op_Create{parent = parent.inode, name = it.name, kind = .File, flags = flags})
	if binary {
		builder_content(&st.b, inode, oid, size)
	} else if size > 0 {
		first, last := builder_insert_ref(&st.b, inode, 0, oid, int(size))
		append(&st.b.imports, Import_File{inode = inode, oid = oid, len = size, first = first, last = last})
	} else {
		append(&st.b.imports, Import_File{inode = inode, oid = oid, len = 0, last = crdt.Op_Id{st.b.actor, inode.seq}})
	}
	import_shadow(st, it.path, Entry{inode = inode, kind = .File, stat = stat, oid = oid}) or_return
	frame_add(st, it.name, oid, odb.MODE_EXEC if exec else odb.MODE_FILE)
	st.files += 1
	return .None
}

@(private)
gone :: proc "contextless" (e: prim.Error) -> bool {
	return e == .Not_Found || e == .Not_Dir
}

@(private)
read_link_file :: proc(m: ^Mount, abs: string, stat: Stat) -> (string, bool, Error) {
	if stat.size <= 0 || stat.size >= prim.PATH_MAX {
		return "", false, .None
	}
	d, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
	if rerr != .None && !gone(rerr) {
		return "", false, from_prim(rerr)
	}
	if rerr != .None || len(d) == 0 || len(d) >= prim.PATH_MAX {
		return "", false, .None
	}
	for c in d {
		if c == 0 {
			return "", false, .None
		}
	}
	return string(d), true, .None
}

@(private)
mark_dirty_dirs :: proc(st: ^Import_State, rel: string) {
	q := rel
	for len(q) > 0 {
		q = path_parent(q)
		if st.dirty_dirs[q] {
			return
		}
		k, _ := clone_string(q, st.long)
		st.dirty_dirs[k] = true
	}
}

@(private)
import_flush :: proc(st: ^Import_State) -> Error {
	m := st.m
	if st.use_pack && odb.pack_count(&st.pack) > 0 {
		if _, err := odb.pack_finish(&st.pack); err != .None {
			return from_odb(err)
		}
		st.use_pack = odb.pack_begin(&st.pack, m.db) == .None
		if st.use_pack {
			odb.pack_set_local(&st.pack, true)
		}
	}
	if len(st.b.imports) == 0 && st.b.n > 0 {
		append(&st.b.imports, Import_File{inode = fstree.ROOT, len = -1})
	}
	builder_commit_import(m, &st.b) or_return
	names_durable(m.db) or_return
	shadow_flush(m) or_return
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
	line: Maybe(string)
	if !m.hold_line {
		line = m.line
	}
	history_commit_import(h, &batch, line) or_return
	clear(&m.synced)
	append(&m.synced, crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1})
	builder_reset(b)
	return .Reloading if history_reloading(h) else .None
}

@(private)
import_cache_tree :: proc(m: ^Mount, dirty: ^map[string]bool) -> Error {
	if !m.git_refs {
		return .None
	}
	ct, err := index_cache_tree(m.vfs, m.git.dir, m.git_format, context.temp_allocator)
	if err != .None {
		return .None
	}
	defer cache_tree_destroy(&ct)
	for dir in sorted_strings(ct.nodes) {
		node := ct.nodes[dir]
		if dirty[dir] {
			continue
		}
		e, found := shadow_get(&m.shadow, dir) or_return
		if found && e.kind == .Dir {
			e.oid = node.oid
			shadow_put(&m.shadow, dir, e) or_return
		}
		if shadow_pending_count(&m.shadow) >= 65536 {
			names_durable(m.db) or_return
			shadow_persist(&m.shadow) or_return
		}
	}
	names_durable(m.db) or_return
	return shadow_persist(&m.shadow)
}

@(private)
adopt_changes :: proc(p: ^Pass) -> Error {
	m := p.m
	h := m.history
	if h == nil || len(p.changes) == 0 {
		return .None
	}
	line, found := history_line(h, m.line, context.temp_allocator) or_return
	if !found {
		return .None
	}
	ll := make([dynamic]crdt.Lv, context.temp_allocator)
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, line, &ll) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None || crdt.frontier_eq(ll[:], sl[:]) {
		return .None
	}
	snap := version_snapshot(h, ll[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	ver: u32
	Adopt_Dir :: struct {
		depth: int,
		i:     int,
	}
	adopted := make([]bool, len(p.changes), context.temp_allocator)
	dirs := make([dynamic]Adopt_Dir, context.temp_allocator)
	for c, i in p.changes {
		if c.moved != "" || c.scope != nil || path_internal(c.path) {
			continue
		}
		if c.kind == .Create && c.disk == .Dir {
			append(&dirs, Adopt_Dir{strings.count(c.path, "/"), i})
			continue
		}
		adopted[i] = adopt_one(p, &snap, ll[:], line, c, &ver) or_return
	}
	slice.sort_by(dirs[:], proc(a, b: Adopt_Dir) -> bool {
		return a.depth > b.depth || (a.depth == b.depth && a.i < b.i)
	})
	for d in dirs {
		i := d.i
		c := p.changes[i]
		owned := false
		for k, j in p.changes {
			if !adopted[j] && j != i && k.kind == .Create && path_at_or_under(k.path, c.path) {
				owned = true
				break
			}
		}
		if !owned {
			adopted[i] = adopt_one(p, &snap, ll[:], line, c, &ver) or_return
		}
	}
	keep := make([dynamic]Change, 0, len(p.changes), context.temp_allocator)
	for c, i in p.changes {
		if !adopted[i] {
			append(&keep, c)
		}
	}
	if len(keep) != len(p.changes) {
		clear(&p.changes)
		append(&p.changes, ..keep[:])
	}
	return .None
}

@(private)
adopt_one :: proc(p: ^Pass, snap: ^fstree.Snapshot, ll: []crdt.Lv, line: Version, c: Change, ver: ^u32) -> (adopted: bool, err: Error) {
	m := p.m
	h := m.history
	ino, at_line, lerr := fstree.lookup(snap, c.path)
	if lerr != nil {
		return false, .Corrupt
	}
	if c.kind == .Remove {
		if c.old.kind != .File || (at_line && ino == c.old.inode) {
			return false, .None
		}
		shadow_remove(&m.shadow, c.path) or_return
		mount_absent_add(m, c.path)
		return true, .None
	}
	if c.kind == .Create && c.disk == .Dir {
		if !at_line {
			return false, .None
		}
		info, ok, ierr := fstree.info(snap, ino, context.temp_allocator)
		if ierr != nil || !ok || !info.present || info.kind != .Dir {
			return false, .None
		}
		adopt_version(p, line, ver) or_return
		shadow_put(&m.shadow, c.path, Entry{inode = ino, kind = .Dir, ver = ver^}) or_return
		return true, .None
	}
	if c.disk != .File || !at_line || (c.kind == .Modify && (c.old.kind != .File || c.old.inode != ino)) {
		return false, .None
	}
	info, ok, ierr := fstree.info(snap, ino, context.temp_allocator)
	if ierr != nil || !ok || !info.present || info.kind != .File || m.db == nil {
		return false, .None
	}
	_, disk_oid, _, rok := read_content(m, c.path, c.stat, ino, true) or_return
	if !rok || (c.kind == .Modify && c.old.oid == disk_oid) {
		return false, .None
	}
	want: odb.Oid
	if .Opaque in info.flags {
		reg, has := history_blob_at(h, ino, ll) or_return
		if !has {
			return false, .None
		}
		want = odb.Oid(reg.oid)
	} else if oid, has := history_text_oid(h, ino, line) or_return; has {
		want = oid
	} else {
		text := history_text_at(h, ino, line, context.temp_allocator) or_return
		want, _ = odb.hash(m.db.format, .Blob, text)
	}
	if want != disk_oid {
		return false, .None
	}
	adopt_version(p, line, ver) or_return
	e := Entry{inode = ino, kind = .File, stat = c.stat, oid = disk_oid, ver = ver^}
	shadow_put(&m.shadow, c.path, e) or_return
	return true, .None
}

@(private)
adopt_version :: proc(p: ^Pass, line: Version, ver: ^u32) -> Error {
	if ver^ != 0 {
		return .None
	}
	m := p.m
	ids := make([dynamic]fstree.Op_Id, context.temp_allocator)
	for id in line {
		append(&ids, op_inode(m.history, id))
	}
	ver^ = shadow_version_add(&m.shadow, ids[:]) or_return
	return .None
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
	actor:   prim.Id,
	scope_id: prim.Id,
	moved:   string,
	carried: bool,
	copy_src: fstree.Inode_Id,
	has_copy: bool,
}

@(private)
Pass :: struct {
	m:          ^Mount,
	switched:   bool,
	line_from:  string,
	line_to:    string,
	changes:    [dynamic]Change,
	seen:       map[string]bool,
	young:      [dynamic]string,
	deferred:   map[u64]bool,
	holding:    [dynamic]string,
	rebased:    [dynamic]crdt.Op_Id,
	scope_of:   map[string]^Scope,
	cutoff:     i64,
	now:        i64,
	settle:     bool,
	full:       bool,
	git_wrote:  bool,
	head_moved: bool,
	marked:     bool,
	operation:  string,
	head:       Git_Head,
	long:       runtime.Allocator,
	chunk:      virtual.Arena,
	held:       [dynamic]Change,
	alias_commits: [dynamic]string,
	held_r:     map[string]bool,
	held_c:     map[string]bool,
}

PASS_CHUNK :: 4096
MOVE_MIN :: 32

@(private)
catch_up :: proc(m: ^Mount) -> Error {
	h := m.history
	if h == nil {
		return .None
	}
	known := crdt.graph_known(&h.g, m.actor)
	if known == 0 {
		return .None
	}
	latest, ok := crdt.graph_lv(&h.g, crdt.Op_Id{m.actor, known - 1})
	if !ok {
		return .None
	}
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
		return .Corrupt
	}
	if crdt.graph_contains(&h.g, sl[:], latest) {
		return .None
	}
	if !mount_durable_now(m) {
		m.mat_held = true
		return .Deferred
	}
	one := [1]crdt.Lv{latest}
	both := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, sl[:], one[:], &both)
	return materialize_to(m, crdt.graph_version_ids(&h.g, both[:], context.temp_allocator), true)
}

@(private)
commit_bounded :: proc(p: ^Pass, actor: prim.Id, indices: []int, marker: []u8 = nil, scope: []u8 = nil) -> Error {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch, 1 << 20) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	b: Builder
	builder_init(&b, p.m.history, actor)
	if marker != nil {
		builder_opaque(&b, marker)
	}
	b.scope = scope
	commit_group(p, &b, indices) or_return
	history_trim(p.m.history)
	return .None
}

@(private)
commit_group :: proc(p: ^Pass, b: ^Builder, indices: []int) -> Error {
	m := p.m
	shadow_txn_begin(&m.shadow)
	err: Error
	for i in indices {
		if err = emit_change(p, b, &p.changes[i]); err != .None {
			break
		}
	}
	if err == .None {
		err = builder_commit(m, b)
	}
	if err != .None && err != .Reloading {
		shadow_txn_rollback(&m.shadow)
		return err
	}
	shadow_txn_end(&m.shadow)
	return err
}

@(private)
attribute_consumed :: proc(p: ^Pass, actor: prim.Id, idx: []int, scope := prim.Id{}) -> Error {
	m := p.m
	logged := false
	for i in idx {
		c := &p.changes[i]
		if (c.kind != .Modify && c.kind != .Create) || c.disk != .File {
			continue
		}
		e, found, serr := shadow_get(&m.shadow, c.path)
		if serr != .None || !found || e.oid == {} {
			continue
		}
		attrib_set(m, c.path, actor, true, e.oid, scope)
		attrib_log_append(m, c.path, actor, e.oid, scope) or_return
		logged = true
	}
	if logged {
		attrib_log_durable(m, nil, nil)
	}
	return .None
}

@(private)
attribute_changes :: proc(p: ^Pass) -> Error {
	m := p.m
	for &c in p.changes {
		if c.scope != nil {
			continue
		}
		a, has := m.attrib[c.path]
		chain, chained := m.attrib_chain[c.path]
		if !has && !chained {
			continue
		}
		if has && a.used && !m.lost && !chained {
			continue
		}
		if has && !m.lost && !actor_on_line(m, a.actor) && a.scope == {} {
			has = false
		}
		steps := make([dynamic]Attrib_Step, context.temp_allocator)
		if chained {
			append(&steps, ..chain[:])
			attrib_chain_drop(m, c.path)
		}
		if has && a.oid != {} && (len(steps) == 0 || steps[len(steps) - 1] != Attrib_Step{a.actor, a.oid, a.scope}) {
			append(&steps, Attrib_Step{a.actor, a.oid, a.scope})
		}
		if !m.lost {
			kept := 0
			for st in steps {
				if actor_on_line(m, st.actor) || st.scope != {} {
					steps[kept] = st
					kept += 1
				}
			}
			resize(&steps, kept)
		}
		if !has && len(steps) == 0 {
			continue
		}
		file := (c.kind == .Modify || c.kind == .Create) && c.disk == .File && c.moved == ""
		if !file || m.db == nil || len(steps) == 0 {
			if has {
				c.actor = unattributed_actor(m.actor) if m.lost else a.actor
				c.scope_id = a.scope
			}
			continue
		}
		_, disk_oid, _, ok := read_content(m, c.path, c.stat, c.old.inode, c.kind == .Modify) or_return
		if !ok {
			if has {
				c.actor = a.actor
				c.scope_id = a.scope
			}
			continue
		}
		matched, broken, gone := false, false, false
		cur := c.old.oid if c.kind == .Modify else odb.Oid{}
		for st in steps {
			if disk_oid == st.oid {
				c.actor = st.actor
				c.scope_id = st.scope
				matched = true
				break
			}
			if st.oid == cur {
				continue
			}
			if !odb.exists(m.db, st.oid) {
				broken = true
				break
			}
			committed := attribute_step(p, &c, st) or_return
			if !committed {
				gone = true
				break
			}
			cur = st.oid
		}
		if matched || gone {
			continue
		}
		if broken {
			c.actor = unattributed_actor(m.actor)
		} else if has && a.oid == {} {
			c.actor = unattributed_actor(m.actor) if m.lost else a.actor
			c.scope_id = a.scope
		} else {
			c.actor = {}
		}
	}
	if p.full && len(m.attrib_chain) > 0 {
		attrib_chain_settle(p)
	}
	return .None
}

@(private)
attrib_chain_settle :: proc(p: ^Pass) {
	m := p.m
	keep := make(map[string]bool, context.temp_allocator)
	for c in p.changes {
		keep[c.path] = true
	}
	for r in p.young {
		keep[r] = true
	}
	for r in p.holding {
		keep[r] = true
	}
	for h in p.held {
		keep[h.path] = true
	}
	drop := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(m.attrib_chain) {
		if !keep[k] {
			append(&drop, k)
		}
	}
	for k in drop {
		attrib_chain_drop(m, k)
	}
}

@(private)
attribute_step :: proc(p: ^Pass, c: ^Change, st: Attrib_Step) -> (committed: bool, err: Error) {
	m := p.m
	first := c^
	first.stat = {}
	if m.override == nil {
		m.override = make(map[string]odb.Oid, m.allocator)
	}
	k, _ := clone_string(c.path, m.allocator)
	m.override[k] = st.oid
	actor := st.actor
	if st.scope != {} && !actor_on_line(m, actor) {
		actor = scope_line_actor(m, actor)
	}
	b: Builder
	builder_init(&b, m.history, actor)
	b.scope = scope_marker(actor, st.scope)
	attrib_set(m, c.path, st.actor, true, st.oid, st.scope)
	shadow_txn_begin(&m.shadow)
	eerr := emit_change(p, &b, &first)
	key, _ := delete_key(&m.override, k)
	delete(key, m.allocator)
	if eerr == .None {
		eerr = builder_commit(m, &b)
	}
	if eerr != .None && eerr != .Reloading {
		shadow_txn_rollback(&m.shadow)
		return false, eerr
	}
	shadow_txn_end(&m.shadow)
	eerr or_return
	e, found := shadow_get(&m.shadow, c.path) or_return
	if !found {
		return false, .None
	}
	c.kind = .Modify
	c.old = e
	c.actor = {}
	return true, .None
}

mount_pass :: proc(m: ^Mount, full: bool, settle := false) -> (err: Error) {
	if !m.imported && !m.importing {
		m.importing = true
		ierr := mount_recover(m)
		if ierr == .None {
			warm_import(m)
			ierr = mount_import(m)
		}
		m.importing = false
		ierr or_return
		return mount_pass(m, true, false)
	}
	adopt_finish(m) or_return
	attr_begin(m)
	defer attr_end(m)
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
	catch_up(m) or_return
	if m.has_git {
		p.head, _ = git_head(m.vfs, m.git, p.long)
		p.head_moved = !git_head_equal(p.head, m.head)
		stamp := git_index_stamp(m.vfs, m.git)
		commits_only, _, rewritten := git_reflog_commits_only(m.vfs, m.git, m.reflog_pos)
		p.operation = git_operation(m.vfs, m.git)
		p.git_wrote = (p.head_moved && (!commits_only || rewritten)) || (p.operation != "" && stamp != m.stamp)
		if key := branch_key(m, p.head, p.long); key != m.branch && p.operation == "" {
			p.switched = true
			p.line_from, _ = clone_string(m.branch, p.long)
			p.line_to = key
			follow := m.opts.follow_branch && m.line == m.branch
			delete(m.branch, m.allocator)
			m.branch, _ = clone_string(key, m.allocator)
			if follow {
				line_follow(m, key) or_return
				p.git_wrote = true
			}
		}
	}
	if p.git_wrote {
		collect_alias_sources(m, &p)
		trust_index(m)
	}
	defer {
		delete(m.alias)
		m.alias = nil
		trust_drop(m)
	}
	p.changes = make([dynamic]Change, p.long)
	p.held = make([dynamic]Change, p.long)
	p.held_r = make(map[string]bool, p.long)
	p.held_c = make(map[string]bool, p.long)
	p.seen = make(map[string]bool, p.long)
	p.young = make([dynamic]string, p.long)
	p.deferred = make(map[u64]bool, p.long)
	p.holding = make([dynamic]string, p.long)
	p.rebased = make([dynamic]crdt.Op_Id, p.long)
	p.scope_of = make(map[string]^Scope, p.long)
	p.settle = settle && !p.git_wrote
	p.now = history_wall_ns(m.history)
	p.cutoff = p.now - m.opts.settle_ms * 1_000_000
	p.full = full || m.rescan || p.git_wrote
	m.hold_line = p.git_wrote
	defer m.hold_line = false
	keys := make([dynamic]string, 0, len(m.dirty), p.long)
	for k in prim.sorted_keys(m.dirty) {
		if k not_in m.dirty {
			continue
		}
		v := m.dirty[k]
		c, _ := clone_string(k, p.long)
		p.scope_of[c] = v
		append(&keys, c)
	}
	for k in m.dirty {
		delete(k, m.allocator)
	}
	clear(&m.dirty)
	dirty_at := make(map[string]i64, p.long)
	for k, v in prim.unordered(m.dirty_at) {
		c, _ := clone_string(k, p.long)
		dirty_at[c] = v
	}
	dirty_at_clear(m)
	rescan_was := m.rescan
	m.rescan = false
	m.git_moved = false
	defer if err != .None {
		for k in prim.sorted_keys(p.scope_of) {
			if k not_in p.scope_of {
				continue
			}
			v := p.scope_of[k]
			if k not_in m.dirty {
				c, _ := clone_string(k, m.allocator)
				m.dirty[c] = v
				if at, ok := dirty_at[k]; ok && v == nil {
					dirty_at_note(m, k, at)
				}
			}
		}
		m.rescan ||= rescan_was || p.full
	}
	if p.full {
		collect_full(&p) or_return
		m.sweep_temps = false
	} else {
		slice.sort_by(keys[:], proc(a, b: string) -> bool {return git_path_cmp(a, false, b, false) < 0})
		pre_moves(&p, keys[:]) or_return
		for k in keys {
			collect_path(&p, k) or_return
			pass_maybe_flush(&p) or_return
		}
		if !settle {
			scoped := make([dynamic]string, 0, len(m.unwatched), p.long)
			for u in m.unwatched {
				append(&scoped, clone_string(u, p.long) or_else "")
			}
			for u in scoped {
				d := probe(m, u) or_return
				if d.kind != .Dir {
					collect_path(&p, u) or_return
					continue
				}
				compare_dir_deep(&p, u, -1) or_return
			}
		}
	}
	pass_flush(&p) or_return
	if m.hold_line {
		m.hold_line = false
		set_line(m) or_return
	}
	for y in p.young {
		if v, ok := &m.dirty[y]; ok {
			v^ = p.scope_of[y]
			continue
		}
		k, _ := clone_string(y, m.allocator)
		m.dirty[k] = p.scope_of[y]
		if at, ok := dirty_at[y]; ok && p.scope_of[y] == nil {
			dirty_at_note(m, y, at)
		}
	}
	for y in p.holding {
		if y in m.dirty {
			continue
		}
		k, _ := clone_string(y, m.allocator)
		m.dirty[k] = p.scope_of[y]
		if at, ok := dirty_at[y]; ok && p.scope_of[y] == nil {
			dirty_at_note(m, y, at)
		}
	}
	if rerr := rebase_materialize(m, p.rebased[:]); rerr != .None && rerr != .Deferred {
		return rerr
	}
	if p.head_moved && m.has_git && !p.git_wrote {
		b: Builder
		builder_init(&b, m.history, m.actor)
		buf := make([dynamic]u8, context.temp_allocator)
		encode_git_op(&buf, "commit", p.head.branch, p.head.commit)
		builder_opaque(&b, buf[:])
		builder_commit(m, &b) or_return
	}
	if m.has_git && len(p.head.commit) > 0 {
		record_commit_version(m, p.head.commit, p.git_wrote, p.alias_commits[:]) or_return
	}
	if m.has_git {
		git_head_destroy(&m.head, m.allocator)
		m.head.branch, _ = clone_string(p.head.branch, m.allocator)
		m.head.commit, _ = clone_string(p.head.commit, m.allocator)
		m.reflog_pos = git_reflog_len(m.vfs, m.git)
		m.stamp = git_index_stamp(m.vfs, m.git)
	}
	if len(m.dirty) > len(p.holding) {
		mount_schedule(m, m.opts.settle_ms)
	}
	m.passes += 1
	serr := mount_settle(m)
	if p.switched && m.reg != nil && m.reg.on_line != nil {
		m.reg.on_line(m, line_key_of(m, p.line_from, context.temp_allocator), line_key_of(m, p.line_to, context.temp_allocator), m.reg.hook_data)
	}
	return serr
}

@(private)
line_follow :: proc(m: ^Mount, key: string) -> Error {
	h := m.history
	v, found := history_line(h, key, context.temp_allocator) or_return
	if !found || len(v) == 0 {
		history_set_line(h, key, m.synced[:]) or_return
	} else {
		line_retarget(m, v) or_return
	}
	delete(m.line, m.allocator)
	m.line, _ = clone_string(key, m.allocator)
	return mount_line_actor(m)
}

@(private)
line_retarget :: proc(m: ^Mount, target: Version) -> Error {
	h := m.history
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None || crdt.graph_version_lvs(&h.g, target, &tl) != .None {
		return .Corrupt
	}
	if !crdt.frontier_eq(sl[:], tl[:]) {
		only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
		only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
		crdt.graph_diff(&h.g, sl[:], tl[:], &only_a, &only_b)
		touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
		spans_touched(h, only_a[:], &touched) or_return
		spans_touched(h, only_b[:], &touched) or_return
		snap := version_snapshot(h, tl[:]) or_return
		defer fstree.snapshot_destroy(&snap)
		was := version_snapshot(h, sl[:]) or_return
		defer fstree.snapshot_destroy(&was)
		for {
			before := len(touched)
			dirs := make([dynamic]fstree.Inode_Id, 0, len(touched), context.temp_allocator)
			for ino in prim.sorted_keys(touched) {
				append(&dirs, ino)
			}
			for ino in dirs {
				retarget_subtree(&was, ino, &touched) or_return
				retarget_subtree(&snap, ino, &touched) or_return
			}
			displaced_touch(m, &snap, &touched) or_return
			if len(touched) == before {
				break
			}
		}
		tracked := make(map[string]Commit_Entry, context.temp_allocator)
		has_git_tree := departed_entries(m, &tracked)
		order := sorted_inodes(touched)
		for ino in order {
			if old, _, had := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return; had {
				shadow_remove(&m.shadow, old) or_return
			}
		}
		for ino in order {
			info, ok, ierr := fstree.info(&snap, ino, context.temp_allocator)
			if ierr != nil {
				return .Corrupt
			}
			if !ok || !info.present {
				continue
			}
			p, pok, perr := fstree.path(&snap, ino, context.temp_allocator)
			if perr != nil {
				return .Corrupt
			}
			if !pok {
				continue
			}
			d := probe(m, p) or_return
			if d.kind == .Missing && has_git_tree && p not_in tracked {
				mount_absent_add(m, p)
				continue
			}
			shadow_put(&m.shadow, p, Entry{inode = ino, kind = info.kind}) or_return
		}
	}
	clear(&m.synced)
	append(&m.synced, ..target)
	m.rescan = true
	return .None
}

@(private)
departed_entries :: proc(m: ^Mount, out: ^map[string]Commit_Entry) -> bool {
	if !m.has_git || m.db == nil || len(m.head.commit) == 0 {
		return false
	}
	oid, _, ok := odb.oid_from_hex(m.head.commit)
	return ok && commit_entries(m.db, oid, out) == .None
}

@(private)
retarget_subtree :: proc(snap: ^fstree.Snapshot, dir: fstree.Inode_Id, touched: ^map[fstree.Inode_Id]bool) -> Error {
	info, ok, ierr := fstree.info(snap, dir, context.temp_allocator)
	if ierr != nil {
		return .Corrupt
	}
	if !ok || !info.present || info.kind != .Dir {
		return .None
	}
	kids, kerr := fstree.children(snap, dir, nil, 0, context.temp_allocator)
	if kerr != nil {
		return .Corrupt
	}
	for c in kids {
		touched[c.inode] = true
		if c.kind == .Dir {
			retarget_subtree(snap, c.inode, touched) or_return
		}
	}
	return .None
}

@(private)
pre_moves :: proc(p: ^Pass, keys: []string) -> Error {
	m := p.m
	gone := make(map[u64]string, p.long)
	gone_entry := make(map[u64]Entry, p.long)
	for k in keys {
		e, found := shadow_get(&m.shadow, k) or_return
		if !found || e.kind != .Dir || e.stat.ino == 0 {
			continue
		}
		d := probe(m, k) or_return
		if d.kind == .Dir && d.stat.ino == e.stat.ino {
			continue
		}
		gone[e.stat.ino] = k
		gone_entry[e.stat.ino] = e
	}
	if len(gone) == 0 {
		return .None
	}
	moved := false
	for k in keys {
		d := probe(m, k) or_return
		if d.kind != .Dir {
			continue
		}
		old, has := gone[d.stat.ino]
		if !has || old == k {
			continue
		}
		if _, exists := shadow_get(&m.shadow, k) or_return; exists {
			continue
		}
		parent_ok := parent_tracked(p, k)
		if !parent_ok {
			continue
		}
		c := Change {
			kind  = .Create,
			path  = clone_string(k, context.temp_allocator) or_else "",
			disk  = .Dir,
			stat  = d.stat,
			old   = gone_entry[d.stat.ino],
			moved = clone_string(old, context.temp_allocator) or_else "",
		}
		append(&p.changes, c)
		mark_seen(p, old)
		delete_key(&gone, d.stat.ino)
		moved = true
	}
	if moved {
		targets := make([dynamic]string, 0, len(p.changes), p.long)
		for c in p.changes {
			append(&targets, clone_string(c.path, p.long) or_else "")
		}
		pass_flush(p) or_return
		for t in targets {
			compare_dir_deep(p, t, -1) or_return
		}
	}
	return .None
}

@(private)
collect_alias_sources :: proc(m: ^Mount, p: ^Pass) {
	h := m.history
	p.alias_commits = make([dynamic]string, p.long)
	add :: proc(p: ^Pass, c: string) {
		if len(c) == 0 {
			return
		}
		for x in p.alias_commits {
			if x == c {
				return
			}
		}
		append(&p.alias_commits, clone_string(c, p.long) or_else "")
	}
	add(p, m.head.commit)
	for c in git_reflog_olds(m.vfs, m.git, m.reflog_pos, p.long) {
		add(p, c)
	}
	for name in ([]string{"ORIG_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"}) {
		if c, ok := git_special_head(m.vfs, m.git, name, p.long); ok {
			add(p, c)
		}
	}
	if m.db != nil && len(p.head.commit) > 0 {
		if oid, _, ok := odb.oid_from_hex(p.head.commit); ok {
			if t, data, err := odb.read(m.db, oid, context.temp_allocator); err == .None && t == .Commit {
				if c, cerr := odb.commit_decode(data, m.db.format, context.temp_allocator); cerr == .None {
					msg := c.message
					marker := "(cherry picked from commit "
					for {
						i := strings.index(msg, marker)
						if i < 0 {
							break
						}
						rest := msg[i + len(marker):]
						j := strings.index_byte(rest, ')')
						if j > 0 {
							add(p, rest[:j])
						}
						msg = rest
					}
				}
			}
		}
	}
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
		return
	}
	outer: for c in p.alias_commits {
		key := strings.concatenate({"cv:", c}, context.temp_allocator)
		data, found, err := kv_get(&h.kv, transmute([]u8)key, context.temp_allocator)
		if err != .None || !found {
			continue
		}
		v, derr := decode_version(data, p.long)
		if derr != .None {
			continue
		}
		al := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, v, &al) != .None {
			continue
		}
		for lv in al {
			if !crdt.graph_contains(&h.g, sl[:], lv) {
				continue outer
			}
		}
		append(&m.alias, v)
	}
}

@(private)
record_commit_version :: proc(m: ^Mount, commit: string, rewrite: bool, sources: []string) -> Error {
	h := m.history
	key := strings.concatenate({"cv:", commit}, context.temp_allocator)
	if _, found := kv_get(&h.kv, transmute([]u8)key, context.temp_allocator) or_return; !found {
		buf := make([dynamic]u8, context.temp_allocator)
		encode_version(&buf, m.synced[:])
		kv_put(&h.kv, transmute([]u8)key, buf[:]) or_return
	}
	if rewrite && len(sources) > 0 {
		history_alias(h, sources, commit, m.synced[:]) or_return
	}
	return history_kv_commit(h)
}

@(private)
pass_maybe_flush :: proc(p: ^Pass) -> Error {
	if len(p.changes) < PASS_CHUNK {
		return .None
	}
	return pass_flush(p, false)
}

HOLD_MAX :: 65536

@(private)
held_under :: proc(set: map[string]bool, path: string) -> bool {
	for q := path; len(q) > 0; q = path_parent(q) {
		if set[q] {
			return true
		}
	}
	return false
}

@(private)
pass_flush :: proc(p: ^Pass, final := true) -> Error {
	m := p.m
	if len(p.held) > 0 {
		merged := make([dynamic]Change, 0, len(p.held) + len(p.changes), context.temp_allocator)
		append(&merged, ..p.held[:])
		append(&merged, ..p.changes[:])
		clear(&p.changes)
		append(&p.changes, ..merged[:])
		clear(&p.held)
	}
	clear(&p.held_r)
	clear(&p.held_c)
	if len(p.deferred) > 0 {
		keep := make([dynamic]Change, 0, len(p.changes), context.temp_allocator)
		for c in p.changes {
			if c.kind == .Create && c.stat.ino != 0 && p.deferred[c.stat.ino] {
				append(&p.young, clone_string(c.path, p.long) or_else "")
				continue
			}
			append(&keep, c)
		}
		clear(&p.changes)
		append(&p.changes, ..keep[:])
	}
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
	adopt_changes(p) or_return
	if !final && p.full {
		for c in p.changes {
			if c.kind == .Remove && c.old.kind == .Dir && c.moved == "" && !c.carried && c.old.stat.ino != 0 {
				p.held_r[clone_string(c.path, p.long) or_else ""] = true
			} else if c.kind == .Create && c.disk == .Dir && c.moved == "" && c.stat.ino != 0 {
				p.held_c[clone_string(c.path, p.long) or_else ""] = true
			}
		}
		holding := 0
		for c in p.changes {
			if (c.kind == .Remove && held_under(p.held_r, c.path)) || held_under(p.held_c, c.path) {
				holding += 1
			}
		}
		if holding <= HOLD_MAX {
			keep := make([dynamic]Change, 0, len(p.changes), context.temp_allocator)
			for c in p.changes {
				if (c.kind == .Remove && held_under(p.held_r, c.path)) || held_under(p.held_c, c.path) {
					h2 := c
					h2.path = clone_string(c.path, p.long) or_else ""
					h2.target = clone_string(c.target, p.long) or_else ""
					h2.moved = clone_string(c.moved, p.long) or_else ""
					append(&p.held, h2)
				} else {
					append(&keep, c)
				}
			}
			clear(&p.changes)
			append(&p.changes, ..keep[:])
		} else {
			clear(&p.held_r)
			clear(&p.held_c)
		}
	}
	if p.git_wrote {
		all := make([dynamic]int, 0, len(p.changes), context.temp_allocator)
		for _, i in p.changes {
			append(&all, i)
		}
		emit_order(p, all[:])
		for lo := 0; lo == 0 || lo < len(all); lo += PASS_CHUNK {
			marker: []u8
			if !p.marked {
				buf := make([dynamic]u8, context.temp_allocator)
				kind := p.operation if p.operation != "" else "checkout"
				if !p.head_moved {
					kind = p.operation if p.operation != "" else "git"
				}
				encode_git_op(&buf, kind, p.head.branch, p.head.commit)
				marker = buf[:]
				p.marked = true
			}
			commit_bounded(p, m.actor, all[lo:min(lo + PASS_CHUNK, len(all))], marker) or_return
		}
	} else {
		rebase_changes(p) or_return
		attribute_changes(p) or_return
		groups := make(map[prim.Id][dynamic]int, context.temp_allocator)
		group_actor := make(map[prim.Id]prim.Id, context.temp_allocator)
		group_scope := make(map[prim.Id]prim.Id, context.temp_allocator)
		order := make([dynamic]prim.Id, context.temp_allocator)
		for c, i in p.changes {
			actor := m.actor
			scope: prim.Id
			if c.scope != nil {
				actor = c.scope.actor
				scope = c.scope.id
			} else if c.actor != {} {
				actor = c.actor
				scope = c.scope_id
				if os, open := m.open_scopes[c.path]; scope == {} && open && os != nil && os.actor == actor {
					scope = os.id
				}
			}
			if actor != m.actor && !actor_on_line(m, actor) {
				if scope != {} && !is_unattributed(actor) {
					actor = scope_line_actor(m, actor)
				} else {
					actor = m.actor
					scope = {}
				}
			}
			key := actor
			if scope != {} && scope != actor {
				key = scope_group_key(actor, scope)
			}
			if _, ok := groups[key]; !ok {
				groups[key] = make([dynamic]int, context.temp_allocator)
				group_actor[key] = actor
				group_scope[key] = scope
				append(&order, key)
			}
			l := groups[key]
			append(&l, i)
			groups[key] = l
		}
		moving := make([dynamic]prim.Id, 0, len(order), context.temp_allocator)
		rest := make([dynamic]prim.Id, 0, len(order), context.temp_allocator)
		for actor in order {
			mv := false
			for i in groups[actor] {
				mv ||= p.changes[i].kind == .Create && p.changes[i].moved != ""
			}
			append(&moving if mv else &rest, actor)
		}
		clear(&order)
		append(&order, ..moving[:])
		append(&order, ..rest[:])
		for key in order {
			idx := groups[key][:]
			actor := group_actor[key]
			marker: []u8
			if actor != m.actor {
				marker = scope_marker(actor, group_scope[key])
			}
			emit_order(p, idx)
			if actor != m.actor {
				for i in idx {
					attrib_set(m, p.changes[i].path, actor, true, {}, group_scope[key])
				}
			}
			for lo := 0; lo < len(idx); lo += PASS_CHUNK {
				commit_bounded(p, actor, idx[lo:min(lo + PASS_CHUNK, len(idx))], nil, marker) or_return
			}
			if actor != m.actor {
				attribute_consumed(p, actor, idx, group_scope[key]) or_return
			}
		}
	}
	mount_settle(m) or_return
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
probe :: proc(m: ^Mount, rel: string, listed := false) -> (out: Probe, err: Error) {
	abuf: prim.Path_Buf
	abs := abs_path(m, rel, abuf[:])
	st, serr := prim.lstat(m.vfs, abs)
	if gone(serr) {
		return {kind = .Missing}, .None
	}
	if serr != .None {
		return {kind = .Other}, from_prim(serr)
	}
	if !listed && !disk_name_matches(m.vfs, abs) {
		return {kind = .Missing}, .None
	}
	out = Probe{kind = disk_kind(st.kind), stat = disk_stat(st)}
	if out.kind == .Symlink {
		tbuf: [prim.PATH_MAX]u8
		n, lerr := prim.readlink(m.vfs, abs, tbuf[:])
		if gone(lerr) {
			return {kind = .Missing}, .None
		}
		if lerr != .None {
			return {kind = .Other}, from_prim(lerr)
		}
		out.target, _ = clone_string(string(tbuf[:n]), context.temp_allocator)
	}
	return out, .None
}

@(private)
collect_path :: proc(p: ^Pass, rel: string, listed := false) -> Error {
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
	d := probe(m, rel, listed) or_return
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
		if d.kind == .Dir && nested_repo(m, rel) {
			return .None
		}
		add_create(p, rel, d) or_return
		if d.kind == .Dir {
			collect_subtree(p, rel) or_return
		}
		return .None
	}
	if d.kind == .File && e.kind == .Symlink && !mount_symlinks(m) {
		if stat_clean(d.stat, e) {
			return .None
		}
		abuf: prim.Path_Buf
		if t, ok := read_link_file(m, abs_path(m, rel, abuf[:]), d.stat) or_return; ok {
			d.kind = .Symlink
			d.target = t
		}
	}
	if (d.kind == .Missing || d.kind == .Other) && mount_absent_has(m, rel) {
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
		if !stat_clean(d.stat, e) {
			if mount_held_by(m, rel, p.scope_of[rel]) {
				append(&p.holding, clone_string(rel, p.long) or_else "")
				defer_ino(p, e)
				return .None
			}
			if p.settle && d.stat.mtime_ns > p.cutoff && d.stat.mtime_ns <= p.now {
				append(&p.young, clone_string(rel, p.long) or_else "")
				defer_ino(p, e)
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
defer_ino :: proc(p: ^Pass, e: Entry) {
	if e.stat.ino != 0 {
		p.deferred[e.stat.ino] = true
	}
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
		if gone(err) {
			return .None
		}
		return from_prim(err)
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
		if err != .None {
			prim.dir_close(m.vfs, &d)
			return from_prim(err)
		}
		if !more {
			break
		}
		if de.name == "." || de.name == ".." || name_internal(de.name) {
			mount_sweep_temp(m, abs, de.name)
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
			collect_path(p, child, true) or_return
		}
		pass_maybe_flush(p) or_return
	}
	pending := sorted_strings(names, heap)
	defer delete(pending, heap)
	for name in pending {
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
		} else if it.kind == .Dir && nested_repo(m, it.path) {
			scan_skip(&sc)
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
		if gone(err) {
			return .None
		}
		return from_prim(err)
	}
	names := make(map[string]Listed, heap)
	defer {
		for k in names {
			delete(k, heap)
		}
		delete(names)
	}
	for {
		de, more, err := prim.dir_next(m.vfs, &d)
		if err != .None {
			prim.dir_close(m.vfs, &d)
			return from_prim(err)
		}
		if !more {
			break
		}
		if de.name == "." || de.name == ".." || name_internal(de.name) {
			mount_sweep_temp(m, abs, de.name)
			continue
		}
		names[clone_string(de.name, heap) or_else ""] = Listed{kind = de.kind, has_stat = de.has_stat, size = de.size, mtime_ns = de.mtime_ns, ctime_ns = de.ctime_ns, ino = de.ino}
	}
	prim.dir_close(m.vfs, &d)
	cbuf: [prim.PATH_MAX]u8
	for k in kids {
		child, ok := path_join_buf(cbuf[:], rel, k.name)
		if !ok {
			continue
		}
		ls, listed := names[k.name]
		if !listed {
			add_remove_tree(p, child, k.entry) or_return
			continue
		}
		dk, _ := delete_key(&names, k.name)
		delete(dk, heap)
		if ls.has_stat && ls.kind == .File && k.entry.kind == .File && !k.entry.racy && ls.size == k.entry.stat.size && ls.mtime_ns == k.entry.stat.mtime_ns && ls.ctime_ns == k.entry.stat.ctime_ns && ls.ino == k.entry.stat.ino {
			continue
		}
		dp := Probe{kind = .Dir}
		if !(ls.kind == .Dir && k.entry.kind == .Dir) {
			dp = probe(m, child, true) or_return
		}
		if k.entry.kind == .Dir && dp.kind == .Dir {
			c, _ := clone_string(child, heap)
			cwd, _ := watch_dir(m.reg, m, c, wd)
			err := compare_dir_deep(p, c, cwd)
			delete(c, heap)
			err or_return
		} else if dp.kind == .File && k.entry.kind == .File && stat_clean(dp.stat, k.entry) {
			continue
		} else {
			collect_path(p, child, true) or_return
		}
		pass_maybe_flush(p) or_return
	}
	pending := sorted_strings(names, heap)
	defer delete(pending, heap)
	for name in pending {
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
Listed :: struct {
	kind:     prim.File_Kind,
	has_stat: bool,
	size:     i64,
	mtime_ns: i64,
	ctime_ns: i64,
	ino:      u64,
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
	held := make(map[u64]fstree.Kind, context.temp_allocator)
	for c in p.changes {
		if c.kind == .Create && c.stat.ino != 0 {
			held[c.stat.ino] = disk_to_tree(c.disk)
		}
	}
	for i in 0 ..< len(p.changes) {
		c := p.changes[i]
		if c.kind != .Modify || c.carried || c.old.stat.ino == 0 || c.stat.ino == c.old.stat.ino {
			continue
		}
		if k, ok := held[c.old.stat.ino]; !ok || k != c.old.kind {
			continue
		}
		p.changes[i].kind = .Create
		p.changes[i].old = {}
		append(&p.changes, Change{kind = .Remove, path = c.path, old = c.old})
	}
	by_ino := make(map[u64]int, context.temp_allocator)
	for c, i in p.changes {
		if c.kind == .Remove && c.old.stat.ino != 0 {
			by_ino[c.old.stat.ino] = i
		}
	}
	for &c in p.changes {
		if c.kind != .Modify || c.disk != .File || c.old.kind != .File || c.stat.ino == 0 || c.stat.ino == c.old.stat.ino {
			continue
		}
		ri, ok := by_ino[c.stat.ino]
		if !ok {
			continue
		}
		r := &p.changes[ri]
		if r.old.kind != .File || r.moved != "" || r.carried {
			continue
		}
		c.copy_src = r.old.inode
		c.has_copy = true
		delete_key(&by_ino, c.stat.ino)
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
	emit_change_inner(p, b, c) or_return
	if c.carried && c.kind == .Modify && c.disk == .Dir {
		return .None
	}
	invalidate_parents(p.m, c.path) or_return
	if c.moved != "" {
		invalidate_parents(p.m, c.moved) or_return
	}
	return .None
}

@(private)
emit_change_inner :: proc(p: ^Pass, b: ^Builder, c: ^Change) -> Error {
	m := p.m
	switch c.kind {
	case .Remove:
		if c.moved != "" || c.carried {
			return .None
		}
		builder_tree(b, fstree.Op_Remove{inode = c.old.inode})
		shadow_remove(&m.shadow, c.path) or_return
		if shadow_has_losers(m, c.path) or_return {
			mount_reshow_add(m, c.path)
		}
	case .Create:
		parent, ok := parent_inode(p, c.path)
		if !ok {
			mount_mark(m, c.path)
			if c.moved != "" {
				mount_mark(m, c.moved)
			}
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
				if shadow_has_losers(m, c.moved) or_return {
					mount_reshow_add(m, c.moved)
				}
				return .None
			}
			shadow_remove(&m.shadow, c.moved) or_return
			e := c.old
			shadow_put(&m.shadow, c.path, e) or_return
			if shadow_has_losers(m, c.moved) or_return {
				mount_reshow_add(m, c.moved)
			}
			if c.disk == .File && !stat_clean(c.stat, c.old) {
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
			if c.disk == .File && stat_clean(c.stat, c.old) {
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
		if exec_bit(m, c.stat, false) {
			flags += {.Exec}
		}
		if binary {
			flags += {.Opaque}
		}
		if m.has_git {
			flags += {.Git_Clean}
		}
		if (binary || len(data) > m.opts.inline_limit) && data != nil {
			store_blob(m, data) or_return
		}
		inode := builder_tree(b, fstree.Op_Create{parent = parent, name = name, kind = .File, flags = flags})
		if binary {
			builder_content(b, inode, oid, blob_size(m, data, oid, c.stat.size))
		} else if len(m.alias) > 0 && len(data) >= MOVE_MIN {
			emit_text_edits(m, b, inode, c.path, nil, data) or_return
		} else if len(data) > m.opts.inline_limit {
			builder_insert_ref(b, inode, 0, oid, len(data))
		} else {
			builder_insert(b, inode, 0, data)
		}
		if binary || len(data) > m.opts.inline_limit {
			note_builder_blob(b, inode, oid)
		}
		shadow_put(&m.shadow, c.path, Entry{inode = inode, kind = .File, stat = c.stat, oid = oid}) or_return
	case .Missing, .Other:
	}
	return .None
}

@(private)
trust_index :: proc(m: ^Mount) {
	if !m.has_git || !m.git_refs || m.db == nil {
		return
	}
	r: Index_Reader
	if index_open(&r, m.vfs, m.git.dir, m.git_format, context.temp_allocator) != .None {
		return
	}
	defer index_close(&r)
	m.trusted = make(map[string]Index_Entry, m.allocator)
	for {
		e, ok, err := index_next(&r)
		if err != .None {
			trust_drop(m)
			return
		}
		if !ok {
			break
		}
		if e.path in m.trusted {
			continue
		}
		e.path = strings.clone(e.path, m.allocator) or_else ""
		m.trusted[e.path] = e
	}
	m.trust_mtime = index_file_mtime_ns(&r)
}

@(private)
trust_drop :: proc(m: ^Mount) {
	for k in m.trusted {
		delete(k, m.allocator)
	}
	delete(m.trusted)
	m.trusted = nil
}

@(private)
read_content :: proc(m: ^Mount, rel: string, stat: Stat, old := fstree.Inode_Id{}, has_old := false) -> (data: []u8, oid: odb.Oid, binary: bool, ok: bool, err: Error) {
	if m.trusted != nil && m.db != nil && stat.size <= m.opts.large_limit {
		if e, has := &m.trusted[rel]; has && index_clean(e, stat, .File, m.trust_mtime, mount_trust_exec(m), mount_symlinks(m)) {
			if t, d, rerr := odb.read(m.db, e.oid, context.temp_allocator); rerr == .None && t == .Blob {
				return d, e.oid, textdiff.is_binary(d), true, .None
			}
		}
	}
	if o, has := m.override[rel]; has && m.db != nil {
		t, d, rerr := odb.read(m.db, o, context.temp_allocator)
		if rerr != .None {
			return nil, {}, false, false, from_odb(rerr)
		}
		if t != .Blob {
			return nil, {}, false, false, .Corrupt
		}
		return d, o, textdiff.is_binary(d), true, .None
	}
	abuf: prim.Path_Buf
	abs := abs_path(m, rel, abuf[:])
	if stat.size > m.opts.large_limit {
		co, _, cst, cerr := store_large_clean(m, rel, abs, old, has_old)
		if cerr == .Not_Found || cerr == .Not_Dir {
			return nil, {}, true, false, .None
		}
		if cerr != .None {
			return nil, {}, true, false, cerr
		}
		if cst == .Failed {
			return nil, {}, true, false, .None
		}
		if cst == .Stored {
			return nil, co, true, true, .None
		}
		o, werr := store_file(m, abs, nil)
		if werr == .Not_Found || werr == .Not_Dir {
			return nil, {}, true, false, .None
		}
		if werr != .None {
			return nil, {}, true, false, werr
		}
		return nil, o, true, true, .None
	}
	d, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
	if gone(rerr) {
		return nil, {}, false, false, .None
	}
	if rerr != .None {
		return nil, {}, false, false, from_prim(rerr)
	}
	cd, cok := eol_clean(m, rel, d, old, has_old)
	if !cok {
		return nil, {}, false, false, .None
	}
	d = cd
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
blob_size :: proc(m: ^Mount, data: []u8, oid: odb.Oid, disk: i64) -> i64 {
	if data != nil {
		return i64(len(data))
	}
	if !m.has_git || m.db == nil {
		return disk
	}
	if _, hs, he := odb.read_header(m.db, oid); he == .None {
		return hs
	}
	return disk
}

@(private)
store_blob :: proc(m: ^Mount, data: []u8) -> Error {
	if m.db == nil {
		return .Invalid
	}
	oid, err := odb.write(m.db, .Blob, data)
	if err == .None {
		history_note_blob(m.history, oid)
	}
	return from_odb(err)
}

@(private)
emit_modify :: proc(p: ^Pass, b: ^Builder, c: ^Change, e: Entry) -> Error {
	e := e
	e.ver = 0
	m := p.m
	h := m.history
	if c.has_copy {
		renamed_marker(h, b, e.inode, c.copy_src)
	}
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
	data, oid, binary, ok := read_content(m, path, c.stat, e.inode, true) or_return
	if !ok {
		return .None
	}
	ne := e
	ne.stat = c.stat
	ne.oid = oid
	old_flags := tree_flags(h, e.inode)
	exec := exec_bit(m, c.stat, .Exec in old_flags)
	if exec != (.Exec in old_flags) {
		builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Exec}, value = {.Exec} if exec else {}})
	}
	if m.has_git && .Git_Clean not_in old_flags {
		builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Git_Clean}, value = {.Git_Clean}})
	}
	if oid == e.oid && m.db != nil {
		return shadow_put(&m.shadow, path, ne)
	}
	was_binary := .Opaque in old_flags
	if binary && was_binary && m.db != nil && blob_current(h, e.inode, m.synced[:], oid) {
		return shadow_put(&m.shadow, path, ne)
	}
	if binary && !was_binary && data != nil {
		cur := history_text_at(h, e.inode, m.synced[:], context.temp_allocator) or_return
		if string(cur) == string(data) {
			return shadow_put(&m.shadow, path, ne)
		}
	}
	if binary {
		if data != nil {
			store_blob(m, data) or_return
		}
		if !was_binary {
			builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Opaque}, value = {.Opaque}})
		}
		builder_content(b, e.inode, oid, blob_size(m, data, oid, c.stat.size))
		note_builder_blob(b, e.inode, oid)
		return shadow_put(&m.shadow, path, ne)
	}
	old := history_text_at(h, e.inode, m.synced[:], context.temp_allocator) or_return
	if was_binary {
		builder_tree(b, fstree.Op_Set_Flags{inode = e.inode, mask = {.Opaque}, value = {}})
	}
	copy_begin(m, c, data) or_return
	defer m.copy = nil
	emit_text_edits(m, b, e.inode, path, old, data) or_return
	return shadow_put(&m.shadow, path, ne)
}

@(private)
renamed_marker :: proc(h: ^History, b: ^Builder, dest: fstree.Inode_Id, source: fstree.Inode_Id) {
	buf := make([dynamic]u8, context.temp_allocator)
	fshist.encode_renamed(&buf, fshist.Renamed_Op{dest = inode_op(h, dest), source = inode_op(h, source)})
	builder_opaque(b, buf[:])
}

@(private)
Copy_Map :: struct {
	data:  []u8,
	src:   []int,
	spans: []crdt.Author_Span,
}

@(private)
copy_begin :: proc(m: ^Mount, c: ^Change, data: []u8) -> Error {
	m.copy = nil
	if !c.has_copy || len(data) == 0 {
		return .None
	}
	h := m.history
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &lvs) != .None {
		return .Corrupt
	}
	text, spans, terr := history_text_spans_at(h, c.copy_src, lvs[:], context.temp_allocator)
	if terr != .None || len(text) == 0 {
		return .None
	}
	la, aerr := textdiff.split_lines(text, context.temp_allocator)
	lb, berr := textdiff.split_lines(data, context.temp_allocator)
	if aerr != nil || berr != nil {
		return .None
	}
	hunks, herr := textdiff.diff_lines(la, lb, textdiff.DEFAULT_DIFF, context.temp_allocator)
	if herr != nil {
		return .None
	}
	cm := new(Copy_Map, context.temp_allocator)
	cm.data = data
	cm.spans = spans
	cm.src = make([]int, len(data), context.temp_allocator)
	for &x in cm.src {
		x = -1
	}
	same :: proc(cm: ^Copy_Map, la, lb: textdiff.Lines, a0, a1, b0: int) {
		ao := int(la.offs[a0])
		bo := int(lb.offs[b0])
		for k in 0 ..< int(la.offs[a1]) - ao {
			cm.src[bo + k] = ao + k
		}
	}
	ai, bi := 0, 0
	for hk in hunks {
		same(cm, la, lb, ai, int(hk.a_start), bi)
		ai = int(hk.a_start + hk.a_len)
		bi = int(hk.b_start + hk.b_len)
	}
	same(cm, la, lb, ai, len(la.offs) - 1, bi)
	m.copy = cm
	return .None
}

@(private)
blob_current :: proc(h: ^History, inode: fstree.Inode_Id, synced: []crdt.Op_Id, oid: odb.Oid) -> bool {
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, synced, &lvs) != .None {
		return false
	}
	reg, has, err := history_blob_at(h, inode, lvs[:])
	return err == .None && has && odb.Oid(reg.oid) == oid
}

@(private)
emit_text_edits :: proc(m: ^Mount, b: ^Builder, inode: fstree.Inode_Id, path: string, full_old, full_data: []u8) -> Error {
	h := m.history
	pre := 0
	for pre < len(full_old) && pre < len(full_data) && full_old[pre] == full_data[pre] {
		pre += 1
	}
	for pre > 0 && full_old[pre - 1] != '\n' {
		pre -= 1
	}
	suf := 0
	for suf < len(full_old) - pre && suf < len(full_data) - pre && full_old[len(full_old) - 1 - suf] == full_data[len(full_data) - 1 - suf] {
		suf += 1
	}
	for suf > 0 {
		oa := len(full_old) - suf
		na := len(full_data) - suf
		if (oa == pre || full_old[oa - 1] == '\n') && (na == pre || full_data[na - 1] == '\n') {
			break
		}
		suf -= 1
	}
	if pre == len(full_old) && pre == len(full_data) {
		return .None
	}
	old := full_old[pre:len(full_old) - suf]
	data := full_data[pre:len(full_data) - suf]
	la, lerr := textdiff.split_lines(old, context.temp_allocator)
	lb, lerr2 := textdiff.split_lines(data, context.temp_allocator)
	hunks: []textdiff.Edit
	herr: textdiff.Error
	if lerr == nil && lerr2 == nil {
		hunks, herr = textdiff.diff_lines(la, lb, textdiff.DEFAULT_DIFF, context.temp_allocator)
	}
	if lerr != nil || lerr2 != nil || herr != nil {
		builder_delete(b, inode, pre, len(old))
		return emit_insert(m, b, inode, pre, data)
	}
	A :: struct {
		a0, a1, b0, b1: int,
	}
	rs := make([]A, len(hunks), context.temp_allocator)
	for hk, i in hunks {
		rs[i] = A{int(la.offs[hk.a_start]), int(la.offs[hk.a_start + hk.a_len]), int(lb.offs[hk.b_start]), int(lb.offs[hk.b_start + hk.b_len])}
	}
	Win :: struct {
		q, w0, w1: int,
		src:       int,
	}
	wins := make([]Win, len(rs), context.temp_allocator)
	any_pair := false
	for r, i in rs {
		wins[i] = Win{-1, 0, 0, -1}
		hk := hunks[i]
		if r.a0 != r.a1 || r.b1 - r.b0 < MOVE_MIN {
			continue
		}
		nl := int(hk.b_len)
		found := false
		for front in 0 ..= min(3, nl - 1) {
			for back in 0 ..= min(3, nl - 1 - front) {
				w0 := int(lb.offs[int(hk.b_start) + front])
				w1 := int(lb.offs[int(hk.b_start) + nl - back])
				if w1 - w0 < MOVE_MIN {
					continue
				}
				q := bytes.index(full_old, data[w0:w1])
				if q < 0 {
					continue
				}
				overlap := 0
				for d in rs {
					lo := max(q, pre + d.a0)
					hi := min(q + (w1 - w0), pre + d.a1)
					if d.a0 != d.a1 && hi > lo {
						overlap += hi - lo
					}
				}
				if overlap * 2 >= w1 - w0 {
					wins[i] = Win{q, w0, w1, -1}
					any_pair = true
					found = true
					break
				}
			}
			if found {
				break
			}
		}
	}
	Alias_Text :: struct {
		text:  []u8,
		spans: []crdt.Author_Span,
	}
	alias_texts := make([dynamic]Alias_Text, context.temp_allocator)
	alias_loaded := false
	for r, i in rs {
		if wins[i].q >= 0 || len(m.alias) == 0 || r.b1 - r.b0 < MOVE_MIN {
			continue
		}
		if !alias_loaded {
			alias_loaded = true
			for av in m.alias {
				al := make([dynamic]crdt.Lv, context.temp_allocator)
				if crdt.graph_version_lvs(&h.g, av, &al) != .None {
					continue
				}
				snap, serr := version_snapshot(h, al[:])
				if serr != .None {
					continue
				}
				ino, found, lerr := fstree.lookup(&snap, path)
				fstree.snapshot_destroy(&snap)
				if lerr != nil || !found {
					continue
				}
				t, sp, terr := history_text_spans_at(h, ino, al[:], context.temp_allocator)
				if terr == .None {
					append(&alias_texts, Alias_Text{t, sp})
				}
			}
		}
		hk := hunks[i]
		nl := int(hk.b_len)
		found := false
		for front in 0 ..= min(3, nl - 1) {
			for back in 0 ..= min(3, nl - 1 - front) {
				w0 := int(lb.offs[int(hk.b_start) + front])
				w1 := int(lb.offs[int(hk.b_start) + nl - back])
				if w1 - w0 < MOVE_MIN {
					continue
				}
				for at, k in alias_texts {
					q := bytes.index(at.text, data[w0:w1])
					if q >= 0 {
						wins[i] = Win{q, w0, w1, k}
						found = true
						break
					}
				}
				if found {
					break
				}
			}
			if found {
				break
			}
		}
	}
	old_spans: []crdt.Author_Span
	if any_pair {
		lvs := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, m.synced[:], &lvs) == .None {
			_, sp, serr := history_text_spans_at(h, inode, lvs[:], context.temp_allocator)
			if serr == .None {
				old_spans = sp
			}
		}
	}
	for r, i in rs {
		if wins[i].q >= 0 && (wins[i].src >= 0 || old_spans != nil) {
			w := wins[i]
			if r.a1 > r.a0 {
				builder_delete(b, inode, pre + r.b0, r.a1 - r.a0)
			}
			spans := old_spans if w.src < 0 else alias_texts[w.src].spans
			emit_insert(m, b, inode, pre + r.b0, data[r.b0:w.w0]) or_return
			builder_copy_spans(b, inode, pre + w.w0, spans, w.q, w.w1 - w.w0)
			emit_insert(m, b, inode, pre + w.w1, data[w.w1:r.b1]) or_return
			continue
		}
		if at, del, ins, ok := textdiff.single_edit_aligned(old[r.a0:r.a1], data[r.b0:r.b1]); ok {
			builder_delete(b, inode, pre + r.b0 + at, del)
			emit_insert(m, b, inode, pre + r.b0 + at, data[r.b0 + at:][:ins]) or_return
			continue
		}
		builder_delete(b, inode, pre + r.b0, r.a1 - r.a0)
		emit_insert(m, b, inode, pre + r.b0, data[r.b0:r.b1]) or_return
	}
	return .None
}

@(private)
emit_insert :: proc(m: ^Mount, b: ^Builder, inode: fstree.Inode_Id, pos: int, ins: []u8) -> Error {
	if len(ins) == 0 {
		return .None
	}
	if cm := m.copy; cm != nil && len(cm.data) > 0 {
		base := uintptr(raw_data(cm.data))
		at := uintptr(raw_data(ins))
		if at >= base && at + uintptr(len(ins)) <= base + uintptr(len(cm.data)) {
			off := int(at - base)
			m.copy = nil
			defer m.copy = cm
			i := 0
			for i < len(ins) {
				j := i + 1
				if s := cm.src[off + i]; s >= 0 {
					for j < len(ins) && cm.src[off + j] == s + (j - i) {
						j += 1
					}
					builder_copy_spans(b, inode, pos + i, cm.spans, s, j - i)
				} else {
					for j < len(ins) && cm.src[off + j] < 0 {
						j += 1
					}
					emit_insert(m, b, inode, pos + i, ins[i:j]) or_return
				}
				i = j
			}
			return .None
		}
	}
	if len(ins) > m.opts.inline_limit && m.db != nil {
		sub, werr := odb.write(m.db, .Blob, ins)
		if werr == .None {
			history_note_blob(m.history, sub)
			builder_insert_ref(b, inode, pos, sub, len(ins))
			note_builder_blob(b, inode, sub)
			return .None
		}
	}
	builder_insert(b, inode, pos, ins)
	return .None
}

@(private)
tree_flags :: proc(h: ^History, inode: fstree.Inode_Id) -> fstree.Flags {
	n, err := fstree.get(&h.tree, inode)
	if err != nil || n == nil {
		return {}
	}
	return n.flags
}

@(private)
shadow_has_losers :: proc(m: ^Mount, rel: string) -> (found: bool, err: Error) {
	kids := make([dynamic]Shadow_Child, context.temp_allocator)
	shadow_children(&m.shadow, path_parent(rel), &kids, context.temp_allocator) or_return
	name := path_name(rel)
	for k in kids {
		if len(k.name) > len(name) && k.name[len(name)] == '~' && k.name[:len(name)] == name {
			return true, .None
		}
	}
	return false, .None
}

@(private)
scope_group_key :: proc(actor, scope: prim.Id) -> (key: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	a, sc := actor, scope
	blake2b.update(&ctx, a[:])
	blake2b.update(&ctx, sc[:])
	blake2b.final(&ctx, key[:])
	return
}

@(private)
scope_marker :: proc(actor, scope: prim.Id) -> []u8 {
	if scope == {} || scope == actor {
		return nil
	}
	mb := make([dynamic]u8, context.temp_allocator)
	fshist.encode_scope(&mb, scope)
	return mb[:]
}

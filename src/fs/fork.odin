package fs

import "base:runtime"
import "core:strings"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"
import "../textdiff"

copy_file_vfs :: proc(vfs: prim.Vfs, src, dst: string, mode: u32) -> Error {
	in_fd, ierr := prim.open_file(vfs, src)
	if ierr != .None {
		return from_prim(ierr)
	}
	defer prim.close_file(vfs, in_fd)
	out_fd, oerr := prim.open_file(vfs, dst, {.Write, .Create, .Truncate}, mode & 0o7777)
	if oerr != .None {
		return from_prim(oerr)
	}
	defer prim.close_file(vfs, out_fd)
	buf: [64 * 1024]u8
	off: i64
	for {
		n, rerr := prim.read_at(vfs, in_fd, buf[:], off)
		if rerr != .None {
			return from_prim(rerr)
		}
		if n == 0 {
			break
		}
		from_prim(prim.write_at(vfs, out_fd, buf[:n], off)) or_return
		off += i64(n)
	}
	return from_prim(prim.fchmod(vfs, out_fd, mode & 0o7777))
}

Fork_Options :: struct {
	branch: string,
	line:   string,
}

mount_fork :: proc(src: ^Mount, dst: ^Mount, id: prim.Id, root: string, state_dir: string, version: Version, opts: Fork_Options, mopts := DEFAULT_MOUNT, allocator := context.allocator) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	mount_sync(src) or_return
	vfs := src.vfs
	if prim.exists(vfs, root) {
		return .Exists
	}
	from_prim(prim.mkdir_all(vfs, root, 0o755)) or_return
	from_prim(prim.mkdir_all(vfs, state_dir, 0o700)) or_return
	sp, _ := path_join(state_dir, "shadow", context.temp_allocator)
	fmt_ := src.db.format if src.db != nil else odb.Hash_Format.Sha1
	sh: Shadow
	shadow_open(&sh, vfs, sp, fmt_, runtime.heap_allocator()) or_return
	err := clone_tree(src, &sh, root, "")
	if err == .None {
		err = names_durable(src.db)
	}
	if err == .None {
		err = shadow_persist(&sh)
	}
	shadow_close(&sh)
	if err != .None {
		return err
	}
	if src.has_git {
		make_git_clone(src, root, opts.branch) or_return
	}
	line := opts.line
	if len(line) == 0 {
		hex := prim.id_hex(id)
		line = strings.concatenate({"fork/", string(hex[:])}, context.temp_allocator)
	}
	history_set_line(src.history, line, version) or_return
	tmp := Mount {
		vfs       = vfs,
		dir       = state_dir,
		actor     = history_id_new(src.history),
		allocator = context.temp_allocator,
	}
	tmp.synced = make([dynamic]crdt.Op_Id, context.temp_allocator)
	append(&tmp.synced, ..src.synced[:])
	if src.has_git {
		g, ok := git_locate(vfs, root, context.temp_allocator)
		if ok {
			tmp.head, _ = git_head(vfs, g, context.temp_allocator)
			tmp.reflog_pos = git_reflog_len(vfs, g)
			tmp.stamp = git_index_stamp(vfs, g)
		}
	}
	save_mount_state(&tmp) or_return
	o := mopts
	o.line = line
	return mount_open(dst, src.reg, src.history, src.db, id, root, state_dir, tmp.actor, o, allocator)
}

@(private)
clone_tree :: proc(src: ^Mount, sh: ^Shadow, root: string, rel: string) -> Error {
	kids := make([dynamic]Shadow_Child, context.temp_allocator)
	shadow_children(&src.shadow, rel, &kids, context.temp_allocator) or_return
	for k in kids {
		child, _ := path_join(rel, k.name, context.temp_allocator)
		sbuf, dbuf: prim.Path_Buf
		s := abs_path(src, child, sbuf[:])
		d, _ := path_join_buf(dbuf[:], root, child)
		switch k.entry.kind {
		case .Dir:
			if e := prim.mkdir(src.vfs, d, 0o755); e != .None && e != .Exists {
				return from_prim(e)
			}
		case .File:
			if clone_file(src.vfs, s, d, k.entry.stat.mode) != .None {
				continue
			}
		case .Symlink:
			if !mount_symlinks(src) {
				if clone_file(src.vfs, s, d, 0o644) != .None {
					continue
				}
				break
			}
			tbuf: [prim.PATH_MAX]u8
			n, lerr := prim.readlink(src.vfs, s, tbuf[:])
			if lerr != .None {
				continue
			}
			if prim.symlink(src.vfs, string(tbuf[:n]), d) != .None {
				continue
			}
		}
		st, serr := prim.lstat(src.vfs, d)
		if serr != .None {
			continue
		}
		e := k.entry
		e.stat = disk_stat(st)
		shadow_append(sh, child, e) or_return
		if k.entry.kind == .Dir {
			clone_tree(src, sh, root, child) or_return
		}
		if shadow_pending_count(sh) >= 65536 {
			names_durable(src.db) or_return
			shadow_persist(sh) or_return
		}
	}
	return .None
}

@(private)
make_git_clone :: proc(src: ^Mount, root: string, branch: string) -> Error {
	vfs := src.vfs
	gd, _ := path_join(root, ".git", context.temp_allocator)
	for sub in ([]string{"", "objects/info", "objects/pack", "refs/heads", "refs/tags", "logs"}) {
		p, _ := path_join(gd, sub, context.temp_allocator)
		from_prim(prim.mkdir_all(vfs, p, 0o755)) or_return
	}
	objects, _ := path_join(src.git.common, "objects", context.temp_allocator)
	alt, _ := path_join(gd, "objects/info/alternates", context.temp_allocator)
	line := strings.concatenate({objects, "\n"}, context.temp_allocator)
	from_prim(prim.replace_atomic(vfs, alt, transmute([]u8)line)) or_return
	cfg_src, _ := path_join(src.git.common, "config", context.temp_allocator)
	cfg, _ := path_join(gd, "config", context.temp_allocator)
	if data, rerr := prim.read_file(vfs, cfg_src, context.temp_allocator); rerr == .None {
		from_prim(prim.replace_atomic(vfs, cfg, data)) or_return
	}
	commit := src.head.commit
	head_text: string
	if len(branch) > 0 {
		ref := strings.concatenate({"refs/heads/", branch}, context.temp_allocator)
		rp, _ := path_join(gd, ref, context.temp_allocator)
		from_prim(prim.mkdir_all(vfs, path_parent_abs(rp), 0o755)) or_return
		if len(commit) > 0 {
			from_prim(prim.replace_atomic(vfs, rp, transmute([]u8)strings.concatenate({commit, "\n"}, context.temp_allocator))) or_return
		}
		head_text = strings.concatenate({"ref: ", ref, "\n"}, context.temp_allocator)
	} else {
		head_text = strings.concatenate({commit, "\n"}, context.temp_allocator)
	}
	hp, _ := path_join(gd, "HEAD", context.temp_allocator)
	from_prim(prim.replace_atomic(vfs, hp, transmute([]u8)head_text)) or_return
	idx_src, _ := path_join(src.git.dir, "index", context.temp_allocator)
	idx, _ := path_join(gd, "index", context.temp_allocator)
	if prim.exists(vfs, idx_src) {
		clone_file(vfs, idx_src, idx, 0o644) or_return
	}
	return .None
}

Land_Conflict :: struct {
	path:  string,
	inode: fstree.Inode_Id,
}

mount_sync_from :: proc(fork: ^Mount, source_line: string, conflicts: ^[dynamic]Land_Conflict, allocator := context.allocator) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator.data == context.temp_allocator.data)
	mount_sync(fork) or_return
	h := fork.history
	theirs, found := history_line(h, source_line, context.temp_allocator) or_return
	if !found {
		return .Not_Found
	}
	ours, ofound := history_line(h, fork.line, context.temp_allocator) or_return
	if !ofound {
		return .Not_Found
	}
	ol := make([dynamic]crdt.Lv, context.temp_allocator)
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, ours, &ol) != .None || crdt.graph_version_lvs(&h.g, theirs, &tl) != .None {
		return .Corrupt
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, ol[:], tl[:], &only_a, &only_b)
	a_set := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	b_set := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	spans_touched(h, only_a[:], &a_set) or_return
	spans_touched(h, only_b[:], &b_set) or_return
	both := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	for ino in sorted_inodes(a_set) {
		if b_set[ino] {
			append(&both, ino)
		}
	}
	common := make([dynamic]crdt.Lv, context.temp_allocator)
	walk := make([dynamic]crdt.Walk_Span, context.temp_allocator)
	crdt.graph_conflicting(&h.g, ol[:], tl[:], &walk, &common)
	base := crdt.graph_version_ids(&h.g, common[:], context.temp_allocator)
	union_lv := make([dynamic]crdt.Lv, context.temp_allocator)
	crdt.version_union(&h.g, ol[:], tl[:], &union_lv)
	merged := crdt.graph_version_ids(&h.g, union_lv[:], context.temp_allocator)
	Marked :: struct {
		inode: fstree.Inode_Id,
		data:  []u8,
	}
	marked := make([dynamic]Marked, context.temp_allocator)
	for ino in both {
		if .Opaque in (tree_flags(h, ino) or_return) {
			continue
		}
		b := history_text_at(h, ino, base, context.temp_allocator) or_continue
		o := history_text_at(h, ino, ours, context.temp_allocator) or_continue
		t := history_text_at(h, ino, theirs, context.temp_allocator) or_continue
		res, merr := textdiff.merge3(b, o, t, {style = .Diff3, ours_label = fork.line, base_label = "base", theirs_label = source_line}, context.temp_allocator)
		if merr != nil || res.conflicts == 0 {
			continue
		}
		append(&marked, Marked{ino, res.data})
	}
	history_set_line(h, fork.line, merged) or_return
	mount_materialize(fork) or_return
	for mk in marked {
		path, _, has := shadow_by_inode(&fork.shadow, mk.inode, context.temp_allocator) or_return
		if !has {
			continue
		}
		abuf: prim.Path_Buf
		abs := abs_path(fork, path, abuf[:])
		tmp := temp_name(fork, abs, context.temp_allocator)
		fd, oerr := prim.open_file(fork.vfs, tmp, {.Write, .Create, .Truncate}, 0o644)
		if oerr != .None {
			return from_prim(oerr)
		}
		werr := prim.write_at(fork.vfs, fd, mk.data, 0)
		if st, serr := prim.lstat(fork.vfs, abs); serr == .None {
			prim.fchmod(fork.vfs, fd, st.mode & 0o7777)
		}
		prim.close_file(fork.vfs, fd)
		if werr != .None {
			prim.remove(fork.vfs, tmp)
			return from_prim(werr)
		}
		from_prim(prim.rename(fork.vfs, tmp, abs)) or_return
		mount_mark(fork, path)
		record_conflict(fork, mk.inode, path) or_return
	}
	mount_pass(fork, false) or_return
	return list_conflicts(fork, conflicts, allocator)
}

mount_land :: proc(fork: ^Mount, source: ^Mount, conflicts: ^[dynamic]Land_Conflict, allocator := context.allocator) -> Error {
	mount_sync(source) or_return
	mount_sync_from(fork, source.line, conflicts, allocator) or_return
	if len(conflicts) > 0 {
		return .Conflicts
	}
	h := fork.history
	v, found := history_line(h, fork.line, context.temp_allocator) or_return
	if !found {
		return .Not_Found
	}
	history_set_line(h, source.line, v) or_return
	return mount_materialize(source)
}

history_lv_end :: proc "contextless" (h: ^History) -> crdt.Lv {
	return h.g.next
}

history_touched_between :: proc(h: ^History, from, to: crdt.Lv, out: ^map[fstree.Inode_Id]bool) -> Error {
	if to <= from {
		return .None
	}
	spans := []crdt.Lv_Span{{lv = from, len = to - from}}
	return spans_touched(h, spans, out)
}

@(private)
spans_touched :: proc(h: ^History, spans: []crdt.Lv_Span, out: ^map[fstree.Inode_Id]bool) -> Error {
	for span in spans {
		lv := span.lv
		end := span.lv + span.len
		for lv < end {
			first, n, stream, off, ok := history_batch_at(h, lv)
			if !ok {
				return .Corrupt
			}
			b, berr := history_read_batch(h, stream, off, context.temp_allocator)
			if berr == .None {
				collect_touched(h, &b, first, lv, min(end, first + n), out)
			} else if berr != .Redacted {
				return berr
			}
			lv = first + n
		}
	}
	return .None
}

@(private)
conflict_key :: proc(m: ^Mount, inode: fstree.Inode_Id) -> []u8 {
	k := strings.concatenate({"cf:", m.line, ":"}, context.temp_allocator)
	out := make([]u8, len(k) + 12, context.temp_allocator)
	n := copy(out, k)
	prim.put_u32le(out[n:], inode.actor)
	prim.put_u64le(out[n + 4:], inode.seq)
	return out
}

@(private)
record_conflict :: proc(m: ^Mount, inode: fstree.Inode_Id, path: string) -> Error {
	h := m.history
	list_key := strings.concatenate({"cfl:", m.line}, context.temp_allocator)
	data, _ := kv_get(&h.kv, transmute([]u8)list_key, context.temp_allocator) or_return
	buf := make([dynamic]u8, 0, len(data) + 12, context.temp_allocator)
	append(&buf, ..data)
	w := prim.writer(&buf)
	prim.write_u32le(&w, inode.actor)
	prim.write_u64le(&w, inode.seq)
	kv_put(&h.kv, transmute([]u8)list_key, buf[:]) or_return
	kv_put(&h.kv, conflict_key(m, inode), transmute([]u8)path) or_return
	return history_kv_commit(h)
}

mount_conflicts :: proc(m: ^Mount, out: ^[dynamic]Land_Conflict, allocator := context.allocator) -> Error {
	mount_wake(m) or_return
	return list_conflicts(m, out, allocator)
}

@(private)
list_conflicts :: proc(m: ^Mount, out: ^[dynamic]Land_Conflict, allocator: runtime.Allocator) -> Error {
	h := m.history
	list_key := strings.concatenate({"cfl:", m.line}, context.temp_allocator)
	data, found := kv_get(&h.kv, transmute([]u8)list_key, context.temp_allocator) or_return
	if !found {
		return .None
	}
	keep := make([dynamic]u8, context.temp_allocator)
	rd := prim.reader(data)
	for prim.reader_remaining(&rd) >= 12 {
		ino := fstree.Inode_Id{prim.read_u32le(&rd), prim.read_u64le(&rd)}
		path, _, has := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return
		if !has {
			continue
		}
		abuf: prim.Path_Buf
		abs := abs_path(m, path, abuf[:])
		text, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
		if rerr != .None || !has_markers(text) {
			continue
		}
		p, _ := clone_string(path, allocator)
		append(out, Land_Conflict{p, ino})
		w := prim.writer(&keep)
		prim.write_u32le(&w, ino.actor)
		prim.write_u64le(&w, ino.seq)
	}
	if len(keep) != len(data) {
		if len(keep) == 0 {
			kv_del(&h.kv, transmute([]u8)list_key) or_return
		} else {
			kv_put(&h.kv, transmute([]u8)list_key, keep[:]) or_return
		}
		history_kv_commit(h) or_return
	}
	return .None
}

@(private)
has_markers :: proc(text: []u8) -> bool {
	s := string(text)
	for line in strings.split_lines_iterator(&s) {
		if strings.has_prefix(line, "<<<<<<< ") || line == "=======" || strings.has_prefix(line, ">>>>>>> ") {
			return true
		}
	}
	return false
}

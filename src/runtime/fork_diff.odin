package rt

import "base:runtime"
import "core:hash/xxhash"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../crdt"
import eng "../engine"
import "../fs"
import "../fstree"
import "../prim"
import "../textdiff"

@(private)
Fd_File :: struct {
	path:   string,
	change: string,
	diff:   string,
}

@(private)
Fd_Mount :: struct {
	name:      string,
	tree:      prim.Id,
	base_line: string,
	fork_line: string,
	base_v:    []crdt.Op_Id,
	fork_v:    []crdt.Op_Id,
	files:     map[fstree.Inode_Id]Fd_File,
}

Fork_Diff :: struct {
	r:         ^Runtime,
	caller:    Object,
	task:      Object,
	want_diff: bool,
	max_chars: int,
	arena:     virtual.Arena,
	alloc:     runtime.Allocator,
	mounts:    [dynamic]Fd_Mount,
	hash:      u64,
}

fork_diff_open :: proc(r: ^Runtime, caller: Object, task: Object, want_diff: bool, max_chars: int) -> (fd: ^Fork_Diff, err: Error) {
	context = eng.context_for(r.e)
	fd = new(Fork_Diff, r.allocator)
	fd.r = r
	fd.caller = caller
	fd.task = task
	fd.want_diff = want_diff
	fd.max_chars = max_chars if max_chars > 0 else 200_000
	if !_arena_init(&fd.arena) {
		free(fd, r.allocator)
		return nil, .Limit
	}
	fd.alloc = virtual.arena_allocator(&fd.arena)
	if prim.id_is_zero(fd.caller.id) {
		if s, serr := eng.convo_settings(r.e, task, context.temp_allocator); serr == .None {
			fd.caller = Object{task.space, s.parent.object}
		}
	}
	_fd_reset(fd)
	_fd_rehash(fd)
	return fd, .None
}

fork_diff_close :: proc(fd: ^Fork_Diff) {
	r := fd.r
	virtual.arena_destroy(&fd.arena)
	free(fd, r.allocator)
}

fork_diff_trees :: proc(fd: ^Fork_Diff, allocator := context.temp_allocator) -> []Object {
	out := make([dynamic]Object, 0, len(fd.mounts), allocator)
	for m in fd.mounts {
		ob := Object{fd.task.space, m.tree}
		if !slice.contains(out[:], ob) {
			append(&out, ob)
		}
	}
	return out[:]
}

fork_diff_reset :: proc(fd: ^Fork_Diff) -> (changed: bool) {
	context = eng.context_for(fd.r.e)
	_fd_reset(fd)
	return _fd_rehash(fd)
}

fork_diff_update :: proc(fd: ^Fork_Diff) -> (changed: bool) {
	context = eng.context_for(fd.r.e)
	for &m in fd.mounts {
		_fd_mount_update(fd, &m)
	}
	return _fd_rehash(fd)
}

fork_diff_result :: proc(fd: ^Fork_Diff, allocator := context.temp_allocator) -> (out: []File_Change, diff: string) {
	list := make([dynamic]File_Change, allocator)
	db := make([dynamic]u8, context.temp_allocator)
	for &m in fd.mounts {
		keys := make([dynamic]fstree.Inode_Id, 0, len(m.files), context.temp_allocator)
		for k in m.files {
			append(&keys, k)
		}
		slice.sort_by(keys[:], proc(a, b: fstree.Inode_Id) -> bool {
			return a.actor < b.actor || a.actor == b.actor && a.seq < b.seq
		})
		for k in keys {
			f := m.files[k]
			append(&list, File_Change{mount = strings.clone(m.name, allocator), path = strings.clone(f.path, allocator), change = f.change})
			if fd.want_diff && len(db) < fd.max_chars {
				append(&db, ..transmute([]u8)f.diff)
			}
		}
	}
	d, _ := utf8_clip(string(db[:]), fd.max_chars)
	return list[:], strings.clone(d, allocator)
}

@(private)
_fd_reset :: proc(fd: ^Fork_Diff) {
	r := fd.r
	free_all(fd.alloc)
	fd.mounts = make([dynamic]Fd_Mount, fd.alloc)
	kms, kerr := eng.convo_mounts(r.e, fd.task, context.temp_allocator)
	if kerr != .None {
		return
	}
	cms, _ := eng.convo_mounts(r.e, fd.caller, context.temp_allocator)
	for km in kms {
		base := ""
		for cm in cms {
			if cm.name == km.name && cm.tree == km.tree {
				base = line_name(cm.line)
			}
		}
		if len(base) == 0 || base == line_name(km.line) {
			continue
		}
		m := Fd_Mount {
			name      = strings.clone(km.name, fd.alloc),
			tree      = km.tree,
			base_line = strings.clone(base, fd.alloc),
			fork_line = strings.clone(line_name(km.line), fd.alloc),
			files     = make(map[fstree.Inode_Id]Fd_File, fd.alloc),
		}
		append(&fd.mounts, m)
	}
	for &m in fd.mounts {
		_fd_mount_full(fd, &m)
	}
}

@(private)
_fd_rehash :: proc(fd: ^Fork_Diff) -> bool {
	list, diff := fork_diff_result(fd)
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, 2)
	for c in list {
		append(&buf, ..transmute([]u8)c.mount)
		append(&buf, 0)
		append(&buf, ..transmute([]u8)c.path)
		append(&buf, 0)
		append(&buf, ..transmute([]u8)c.change)
		append(&buf, 1)
	}
	append(&buf, ..transmute([]u8)diff)
	h := xxhash.XXH3_64(buf[:])
	changed := h != fd.hash
	fd.hash = h
	return changed
}

@(private)
_fd_versions :: proc(fd: ^Fork_Diff, h: ^fs.History, m: ^Fd_Mount) -> (base, fork: []crdt.Op_Id, ok: bool) {
	b, f1, e1 := fs.history_line(h, m.base_line, context.temp_allocator)
	if e1 != .None || !f1 {
		return nil, nil, false
	}
	if run := run_find(fd.r, fd.task); run != nil && run.ws != nil {
		for mb in run.ws.members {
			if mb.name == m.name && mb.tree == m.tree && !prim.id_is_zero(mb.run_line) {
				if f, found, err := fs.history_line(h, line_name(mb.run_line), context.temp_allocator); err == .None && found {
					return b, f, true
				}
			}
		}
	}
	f, f2, e2 := fs.history_line(h, m.fork_line, context.temp_allocator)
	if e2 != .None || !f2 {
		return nil, nil, false
	}
	return b, f, true
}

@(private)
_fd_mount_full :: proc(fd: ^Fork_Diff, m: ^Fd_Mount) {
	r := fd.r
	tree := Object{fd.task.space, m.tree}
	h, herr := eng.tree_history(r.e, tree)
	if herr != .None {
		return
	}
	defer eng.tree_release(r.e, tree)
	base, fork, ok := _fd_versions(fd, h, m)
	if !ok {
		return
	}
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	fl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, base, &bl) != .None || crdt.graph_version_lvs(&h.g, fork, &fl) != .None {
		return
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, bl[:], fl[:], &only_a, &only_b)
	cand := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	structural := false
	_fd_touched(h, only_a[:], &cand, &structural)
	_fd_touched(h, only_b[:], &cand, &structural)
	clear(&m.files)
	_fd_classify(fd, m, h, base, fork, bl[:], fl[:], cand, true)
	m.base_v = slice.clone(base, fd.alloc)
	m.fork_v = slice.clone(fork, fd.alloc)
}

@(private)
_fd_mount_update :: proc(fd: ^Fork_Diff, m: ^Fd_Mount) {
	r := fd.r
	tree := Object{fd.task.space, m.tree}
	h, herr := eng.tree_history(r.e, tree)
	if herr != .None {
		return
	}
	defer eng.tree_release(r.e, tree)
	base, fork, ok := _fd_versions(fd, h, m)
	if !ok {
		return
	}
	if _fd_ids_eq(base, m.base_v) && _fd_ids_eq(fork, m.fork_v) {
		return
	}
	cand := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	structural := false
	moved := [2]struct {
		old, new: []crdt.Op_Id,
	}{{m.base_v, base}, {m.fork_v, fork}}
	for x in moved {
		if _fd_ids_eq(x.old, x.new) {
			continue
		}
		ol := make([dynamic]crdt.Lv, context.temp_allocator)
		nl := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, x.old, &ol) != .None || crdt.graph_version_lvs(&h.g, x.new, &nl) != .None {
			_fd_mount_full(fd, m)
			return
		}
		gone := make([dynamic]crdt.Lv_Span, context.temp_allocator)
		came := make([dynamic]crdt.Lv_Span, context.temp_allocator)
		crdt.graph_diff(&h.g, ol[:], nl[:], &gone, &came)
		if len(gone) > 0 {
			structural = true
		}
		_fd_touched(h, gone[:], &cand, &structural)
		_fd_touched(h, came[:], &cand, &structural)
	}
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	fl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, base, &bl) != .None || crdt.graph_version_lvs(&h.g, fork, &fl) != .None {
		return
	}
	if !structural {
		cur := fstree.current(&h.tree)
		for ino in cand {
			if ino in m.files {
				continue
			}
			if inf, iok, ierr := fstree.info(&cur, ino, context.temp_allocator); ierr != nil || !iok || !inf.present {
				structural = true
				break
			}
		}
	}
	_fd_classify(fd, m, h, base, fork, bl[:], fl[:], cand, structural)
	delete(m.base_v, fd.alloc)
	delete(m.fork_v, fd.alloc)
	m.base_v = slice.clone(base, fd.alloc)
	m.fork_v = slice.clone(fork, fd.alloc)
}

@(private)
_fd_classify :: proc(fd: ^Fork_Diff, m: ^Fd_Mount, h: ^fs.History, base, fork: []crdt.Op_Id, bl, fl: []crdt.Lv, cand: map[fstree.Inode_Id]bool, structural: bool) {
	if len(cand) == 0 {
		return
	}
	sa, sb: fstree.Snapshot
	if structural {
		e1, e2: fs.Error
		sa, e1 = fs.version_snapshot(h, bl)
		if e1 != .None {
			return
		}
		sb, e2 = fs.version_snapshot(h, fl)
		if e2 != .None {
			fstree.snapshot_destroy(&sa)
			return
		}
	} else {
		sa = fstree.current(&h.tree)
		sb = sa
	}
	defer if structural {
		fstree.snapshot_destroy(&sa)
		fstree.snapshot_destroy(&sb)
	}
	for ino in _sorted_inodes(cand) {
		pa, pb: bool
		path_a, path_b: string
		kind_dir := false
		kept_rename := false
		if prev, cached := m.files[ino]; cached && !structural {
			kept_rename = prev.change == "renamed"
			pa = prev.change != "added"
			pb = prev.change != "deleted"
			path_a = prev.path
			path_b = prev.path
		} else {
			ia, oka, _ := fstree.info(&sa, ino, context.temp_allocator)
			ib, okb, _ := fstree.info(&sb, ino, context.temp_allocator)
			pa = oka && ia.present
			pb = okb && ib.present
			kind_dir = (pa && ia.kind == .Dir) || (pb && ib.kind == .Dir)
			if pa {
				path_a, _, _ = fstree.path(&sa, ino, context.temp_allocator)
			}
			if pb {
				path_b, _, _ = fstree.path(&sb, ino, context.temp_allocator)
			}
		}
		if old, had := m.files[ino]; had {
			delete(old.path, fd.alloc)
			delete(old.diff, fd.alloc)
			delete_key(&m.files, ino)
		}
		if kind_dir || (!pa && !pb) {
			continue
		}
		a, b: []u8
		if pa {
			a, _ = fs.history_text_at(h, ino, base, context.temp_allocator)
		}
		if pb {
			b, _ = fs.history_text_at(h, ino, fork, context.temp_allocator)
		}
		change := ""
		path := path_b if pb else path_a
		switch {
		case !pa && pb:
			change = "added"
		case pa && !pb:
			change = "deleted"
		case kept_rename || path_a != path_b:
			change = "renamed"
		case string(a) != string(b):
			change = "modified"
		case:
			continue
		}
		f := Fd_File{path = strings.clone(path, fd.alloc), change = change}
		if fd.want_diff {
			if txt, _, derr := textdiff.unified(a, b, textdiff.DEFAULT_UNIFIED, context.temp_allocator); derr == nil {
				f.diff = strings.concatenate({"--- a/", m.name, "/", path, "\n+++ b/", m.name, "/", path, "\n", string(txt)}, fd.alloc)
			}
		}
		m.files[ino] = f
	}
}

@(private)
_fd_touched :: proc(h: ^fs.History, spans: []crdt.Lv_Span, out: ^map[fstree.Inode_Id]bool, structural: ^bool) {
	for span in spans {
		lv := span.lv
		end := span.lv + span.len
		for lv < end {
			first, n, stream, off, ok := fs.history_batch_at(h, lv)
			if !ok {
				structural^ = true
				return
			}
			b, berr := fs.history_read_batch(h, stream, off, context.temp_allocator)
			if berr == .None {
				x := first
				for op in b.ops {
					lo := x
					hi := x + op.len
					x = hi
					if hi <= lv || lo >= min(end, first + n) {
						continue
					}
					if op.kind != .Opaque {
						out[fs.op_inode(h, op.target)] = true
						continue
					}
					rd := prim.reader(op.content)
					tag := prim.read_u8(&rd)
					switch tag {
					case fs.TOP_CREATE:
						_, seq := crdt.graph_op(&h.g, lo)
						out[fstree.Inode_Id{crdt.graph_intern(&h.g, b.actor), seq}] = true
						structural^ = true
					case fs.TOP_MOVE, fs.TOP_REMOVE, fs.TOP_RESTORE, fs.TOP_FLAGS, fs.TOP_TARGET:
						a := prim.read_id(&rd)
						s := prim.read_uvarint(&rd)
						if prim.reader_ok(&rd) {
							out[fs.op_inode(h, crdt.Op_Id{a, s})] = true
						}
						structural^ = true
					case fs.TOP_CONTENT:
						a := prim.read_id(&rd)
						s := prim.read_uvarint(&rd)
						if prim.reader_ok(&rd) {
							out[fs.op_inode(h, crdt.Op_Id{a, s})] = true
						}
					}
				}
			}
			lv = first + n
		}
	}
}

@(private)
_fd_ids_eq :: proc(a, b: []crdt.Op_Id) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x in a {
		if !slice.contains(b, x) {
			return false
		}
	}
	return true
}

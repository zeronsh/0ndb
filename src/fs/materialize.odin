package fs

import "base:runtime"
import "core:slice"
import "core:io"
import "core:mem/virtual"
import "core:strconv"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"

@(private)
Mat_Item :: struct {
	inode:   fstree.Inode_Id,
	present: bool,
	path:    string,
	kind:    fstree.Kind,
	flags:   fstree.Flags,
	target:  string,
	old:     string,
	has_old: bool,
	entry:   Entry,
	depth:   int,
}

mount_materialize :: proc(m: ^Mount) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	if m.history == nil {
		return .None
	}
	mount_wake(m) or_return
	h := m.history
	target, found := history_line(h, m.line, context.temp_allocator) or_return
	if !found {
		return .None
	}
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, target, &tl) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
		return .Corrupt
	}
	if crdt.frontier_eq(tl[:], sl[:]) {
		return .None
	}
	if len(m.dirty) > 0 || m.rescan {
		mount_pass(m, false) or_return
		clear(&sl)
		crdt.graph_version_lvs(&h.g, m.synced[:], &sl)
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, sl[:], tl[:], &only_a, &only_b)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	spans_touched(h, only_a[:], &touched) or_return
	spans_touched(h, only_b[:], &touched) or_return
	snap := version_snapshot(h, tl[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	displaced_touch(m, &snap, &touched) or_return
	items := make([dynamic]Mat_Item, context.temp_allocator)
	for ino in sorted_inodes(touched) {
		it := Mat_Item {
			inode = ino,
		}
		info, ok, ierr := fstree.info(&snap, ino, context.temp_allocator)
		if ierr != nil {
			return .Corrupt
		}
		if ok && info.present {
			p, pok, perr := fstree.path(&snap, ino, context.temp_allocator)
			if perr != nil {
				return .Corrupt
			}
			if pok {
				it.present = true
				it.path = p
				it.kind = info.kind
				it.flags = info.flags
				it.target = info.target
				it.depth = count_depth(p)
			}
		}
		old, e, has := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return
		it.old = old
		it.has_old = has
		it.entry = e
		if !it.present && !has {
			continue
		}
		append(&items, it)
	}
	slice.sort_by(items[:], proc(a, b: Mat_Item) -> bool {
		if a.present != b.present {
			return !a.present
		}
		if !a.present {
			return count_depth(a.old) > count_depth(b.old)
		}
		if a.depth != b.depth {
			return a.depth < b.depth
		}
		am := a.has_old && a.old != a.path
		bm := b.has_old && b.old != b.path
		return am && !bm
	})
	for &it in items {
		materialize_one(m, &it, tl[:]) or_return
	}
	shadow_persist(&m.shadow) or_return
	clear(&m.intents)
	if !m.restoring {
		clear(&m.synced)
		append(&m.synced, ..target)
	}
	history_trim(h)
	return save_mount_state(m)
}

@(private)
displaced_touch :: proc(m: ^Mount, snap: ^fstree.Snapshot, touched: ^map[fstree.Inode_Id]bool) -> Error {
	work := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	for ino in touched {
		append(&work, ino)
	}
	for len(work) > 0 {
		ino := pop(&work)
		info, ok, ierr := fstree.info(snap, ino, context.temp_allocator)
		if ierr != nil {
			return .Corrupt
		}
		if !ok || !info.present {
			continue
		}
		p, pok, perr := fstree.path(snap, ino, context.temp_allocator)
		if perr != nil {
			return .Corrupt
		}
		if !pok {
			continue
		}
		e, found := shadow_get(&m.shadow, p) or_return
		if found && e.inode != ino && !touched[e.inode] {
			touched[e.inode] = true
			append(&work, e.inode)
		}
	}
	return .None
}

@(private)
count_depth :: proc(p: string) -> int {
	n := 0
	for c in p {
		if c == '/' {
			n += 1
		}
	}
	return n
}

@(private)
collect_touched :: proc(h: ^History, b: ^crdt.Batch, first: crdt.Lv, from: crdt.Lv, to: crdt.Lv, out: ^map[fstree.Inode_Id]bool) {
	lv := first
	for op in b.ops {
		lo := lv
		hi := lv + op.len
		lv = hi
		if hi <= from || lo >= to {
			continue
		}
		if op.kind != .Opaque {
			out[op_inode(h, op.target)] = true
			continue
		}
		r := prim.reader(op.content)
		tag := prim.read_u8(&r)
		switch tag {
		case TOP_CREATE:
			_, seq := crdt.graph_op(&h.g, lo)
			out[fstree.Inode_Id{crdt.graph_intern(&h.g, b.actor), seq}] = true
		case TOP_MOVE, TOP_REMOVE, TOP_RESTORE, TOP_FLAGS, TOP_TARGET, TOP_CONTENT:
			a := prim.read_id(&r)
			s := prim.read_uvarint(&r)
			if prim.reader_ok(&r) {
				out[op_inode(h, crdt.Op_Id{a, s})] = true
			}
		}
	}
}

@(private)
disk_matches :: proc(m: ^Mount, rel: string, e: Entry) -> bool {
	d := probe(m, rel)
	if d.kind == .Missing {
		return true
	}
	if disk_to_tree(d.kind) != e.kind {
		return false
	}
	if e.kind == .Dir {
		return true
	}
	return d.stat == e.stat
}

@(private)
materialize_one :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> Error {
	materialize_inner(m, it, tl) or_return
	if m.restoring {
		return .None
	}
	if it.present {
		invalidate_parents(m, it.path) or_return
	}
	if it.has_old {
		invalidate_parents(m, it.old) or_return
	}
	return .None
}

@(private)
materialize_inner :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> Error {
	if it.has_old && !disk_matches(m, it.old, it.entry) {
		mount_mark(m, it.old)
		return .None
	}
	abuf: prim.Path_Buf
	if !it.present {
		if !it.has_old {
			return .None
		}
		abs := abs_path(m, it.old, abuf[:])
		if it.entry.kind == .Dir {
			prim.remove_dir(m.vfs, abs)
		} else {
			prim.remove(m.vfs, abs)
		}
		return .None if m.restoring else shadow_remove(&m.shadow, it.old)
	}
	abs := abs_path(m, it.path, abuf[:])
	if it.has_old && it.old != it.path {
		if !disk_matches(m, it.path, Entry{kind = it.kind}) && probe(m, it.path).kind != .Missing {
			mount_mark(m, it.path)
			return .None
		}
		obuf: prim.Path_Buf
		oabs := abs_path(m, it.old, obuf[:])
		ensure_parent(m, abs) or_return
		if err := prim.rename(m.vfs, oabs, abs); err != .None && err != .Not_Found {
			return from_prim(err)
		}
		if m.restoring {
		} else if it.kind == .Dir {
			move_shadow_tree(m, it.old, it.path) or_return
		} else {
			shadow_remove(&m.shadow, it.old) or_return
		}
	} else if !it.has_old && probe(m, it.path).kind != .Missing && it.kind != .Dir {
		mount_mark(m, it.path)
		return .None
	}
	e := it.entry
	e.inode = it.inode
	e.kind = it.kind
	switch it.kind {
	case .Dir:
		ensure_parent(m, abs) or_return
		if err := prim.mkdir(m.vfs, abs, 0o755); err != .None && err != .Exists {
			return from_prim(err)
		}
		if !m.restoring {
			watch_dir(m.reg, m, it.path, -1)
		}
	case .Symlink:
		ensure_parent(m, abs) or_return
		tmp := temp_name(m, abs, context.temp_allocator)
		prim.remove(m.vfs, tmp)
		from_prim(prim.symlink(m.vfs, it.target, tmp)) or_return
		from_prim(prim.rename(m.vfs, tmp, abs)) or_return
		if m.db != nil {
			e.oid, _ = odb.hash(m.db.format, .Blob, transmute([]u8)it.target)
		}
	case .File:
		ensure_parent(m, abs) or_return
		write_file_content(m, it, abs, tl, &e) or_return
	}
	if st, serr := prim.lstat(m.vfs, abs); serr == .None {
		e.stat = disk_stat(st)
	}
	if m.restoring {
		return .None
	}
	return shadow_put(&m.shadow, it.path, e)
}

@(private)
write_file_content :: proc(m: ^Mount, it: ^Mat_Item, abs: string, tl: []crdt.Lv, e: ^Entry) -> Error {
	h := m.history
	mode: u32 = 0o755 if .Exec in it.flags else 0o644
	tmp := temp_name(m, abs, context.temp_allocator)
	if .Opaque in it.flags {
		reg, has := history_blob_at(h, it.inode, tl) or_return
		if !has || m.db == nil {
			return .None
		}
		if e.oid == reg.oid && it.has_old && it.old == it.path {
			return set_mode(m, abs, mode)
		}
		fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, mode)
		if oerr != .None {
			return from_prim(oerr)
		}
		sink := Fd_Sink{m.vfs, fd, 0, .None}
		_, _, serr := odb.stream(m.db, reg.oid, io.Stream{procedure = fd_sink_proc, data = &sink})
		prim.fchmod(m.vfs, fd, mode)
		prim.close_file(m.vfs, fd)
		if serr != .None || sink.err != .None {
			prim.remove(m.vfs, tmp)
			return from_odb(serr) if serr != .None else sink.err
		}
		from_prim(prim.rename(m.vfs, tmp, abs)) or_return
		e.oid = reg.oid
		return .None
	}
	ids := crdt.graph_version_ids(&h.g, tl, context.temp_allocator)
	data := history_text_at(h, it.inode, ids, context.temp_allocator) or_return
	oid: odb.Oid
	if m.db != nil {
		oid, _ = odb.hash(m.db.format, .Blob, data)
		if oid == e.oid && it.has_old && it.old == it.path {
			return set_mode(m, abs, mode)
		}
	}
	fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, mode)
	if oerr != .None {
		return from_prim(oerr)
	}
	werr := prim.write_at(m.vfs, fd, data, 0)
	prim.fchmod(m.vfs, fd, mode)
	prim.close_file(m.vfs, fd)
	if werr != .None {
		prim.remove(m.vfs, tmp)
		return from_prim(werr)
	}
	from_prim(prim.rename(m.vfs, tmp, abs)) or_return
	e.oid = oid
	return .None
}

@(private)
Fd_Sink :: struct {
	vfs: prim.Vfs,
	fd:  prim.Fd,
	off: i64,
	err: Error,
}

@(private)
fd_sink_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Fd_Sink)(data)
	#partial switch mode {
	case .Write:
		if e := prim.write_at(s.vfs, s.fd, p, s.off); e != .None {
			s.err = from_prim(e)
			return 0, .Unknown
		}
		s.off += i64(len(p))
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Unsupported
}

@(private)
set_mode :: proc(m: ^Mount, abs: string, mode: u32) -> Error {
	fd, err := prim.open_file(m.vfs, abs)
	if err != .None {
		return from_prim(err)
	}
	defer prim.close_file(m.vfs, fd)
	return from_prim(prim.fchmod(m.vfs, fd, mode))
}

@(private)
ensure_parent :: proc(m: ^Mount, abs: string) -> Error {
	parent := path_parent_abs(abs)
	if parent == m.root || len(parent) <= len(m.root) {
		return .None
	}
	return from_prim(prim.mkdir_all(m.vfs, parent, 0o755))
}

@(private)
temp_name :: proc(m: ^Mount, abs: string, allocator: runtime.Allocator) -> string {
	m.fence_seq += 1
	digits: [24]u8
	num := strconv.write_uint(digits[:], m.fence_seq, 10)
	parent := path_parent_abs(abs)
	name := make([]u8, len(TEMP_PREFIX) + len(num), allocator)
	copy(name, TEMP_PREFIX)
	copy(name[len(TEMP_PREFIX):], num)
	out, _ := path_join(parent, string(name), allocator)
	return out
}

version_snapshot :: proc(h: ^History, lvs: []crdt.Lv) -> (snap: fstree.Snapshot, err: Error) {
	if crdt.frontier_eq(lvs, h.g.heads[:]) {
		return fstree.current(&h.tree), .None
	}
	Vis :: struct {
		h:  ^History,
		tl: []crdt.Lv,
	}
	vis := new(Vis, context.temp_allocator)
	vis^ = {h, lvs}
	view := fstree.View {
		data = vis,
		visible = proc(data: rawptr, id: fstree.Op_Id) -> bool {
			v := (^Vis)(data)
			lv, ok := crdt.graph_lv(&v.h.g, inode_op(v.h, id))
			return ok && crdt.graph_contains(&v.h.g, v.tl, lv)
		},
		floor = 0,
	}
	s, serr := fstree.snapshot(&h.tree, view, context.temp_allocator)
	if serr != nil {
		return {}, .Corrupt
	}
	return s, .None
}

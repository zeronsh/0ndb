package fs

import "base:runtime"
import "core:slice"
import "core:io"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"
import "../textdiff"

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
	parent:  fstree.Inode_Id,
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
	if m.adopt_pending {
		if !m.imported {
			return .None
		}
		return adopt_finish(m)
	}
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
	if crdt.frontier_eq(tl[:], sl[:]) && !mount_absent_ready(m) && len(m.reshow) == 0 {
		return .None
	}
	if len(m.dirty) > 0 || m.rescan {
		line_was, _ := clone_string(m.line, context.temp_allocator)
		mount_pass(m, false) or_return
		if m.line != line_was {
			return mount_materialize(m)
		}
	}
	if !mount_durable_now(m) {
		return .None
	}
	m.mat_ingest = true
	merr := materialize_to(m, target, false)
	m.mat_ingest = false
	merr or_return
	return mount_settle(m)
}

@(private)
materialize_to :: proc(m: ^Mount, target: Version, merge: bool) -> Error {
	attr_begin(m)
	defer attr_end(m)
	h := m.history
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, target, &tl) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
		return .Corrupt
	}
	target := target
	if len(m.holds) > 0 {
		reduced, changed := hold_target(m, tl[:], sl[:]) or_return
		if changed {
			r := make([dynamic]crdt.Lv, context.temp_allocator)
			append(&r, ..reduced)
			tl = r
			target = crdt.graph_version_ids(&h.g, tl[:], context.temp_allocator)
		}
	}
	if crdt.frontier_eq(tl[:], sl[:]) && len(m.absent) == 0 && len(m.reshow) == 0 {
		return .None
	}
	m.merge_base = m.synced[:] if merge else nil
	defer m.merge_base = nil
	if m.mat_retries == 0 {
		m.mat_bytes = 0
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, sl[:], tl[:], &only_a, &only_b)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	spans_touched(h, only_a[:], &touched) or_return
	spans_touched(h, only_b[:], &touched) or_return
	snap := version_snapshot(h, tl[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	prev_snap, prev_version := attr_set_checkout(m, new_clone(snap, context.temp_allocator), tl[:])
	defer attr_set_checkout(m, prev_snap, prev_version)
	moved_ancestors_touch(h, &snap, sl[:], &touched) or_return
	displaced_touch(m, &snap, &touched) or_return
	for c in m.collided {
		if ino, ok, lerr := fstree.lookup(&snap, c); lerr == nil && ok {
			touched[ino] = true
		}
		delete(c, m.allocator)
	}
	clear(&m.collided)
	for a in m.absent {
		if ino, ok, lerr := fstree.lookup(&snap, a); lerr == nil && ok {
			touched[ino] = true
		}
		delete(a, m.allocator)
	}
	clear(&m.absent)
	for r in m.reshow {
		if ino, ok, lerr := fstree.lookup(&snap, r); lerr == nil && ok {
			touched[ino] = true
		}
		delete(r, m.allocator)
	}
	clear(&m.reshow)
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
				it.parent = info.parent
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
	if m.mat_ingest && !merge {
		held := false
		for &it in items {
			if p, blocked := mat_blocker(m, &it, tl[:]); blocked {
				mount_mark(m, p)
				held = true
			}
		}
		if held {
			line_was, _ := clone_string(m.line, context.temp_allocator)
			mount_pass(m, false) or_return
			if m.line != line_was {
				return .None
			}
			one := make([dynamic]crdt.Lv, context.temp_allocator)
			if crdt.graph_version_lvs(&h.g, m.synced[:], &one) != .None {
				return .Corrupt
			}
			if crdt.frontier_eq(one[:], sl[:]) {
				for &it in items {
					if p, blocked := mat_blocker(m, &it, tl[:]); blocked {
						c, _ := clone_string(p, m.allocator)
						append(&m.collided, c)
					}
				}
				return .None
			}
			both := make([dynamic]crdt.Lv, context.temp_allocator)
			crdt.version_union(&h.g, tl[:], one[:], &both)
			return materialize_to(m, crdt.graph_version_ids(&h.g, both[:], context.temp_allocator), false)
		}
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
		ag := path_name(a.path) == ".gitattributes"
		bg := path_name(b.path) == ".gitattributes"
		if ag != bg {
			return ag
		}
		am := a.has_old && a.old != a.path
		bm := b.has_old && b.old != b.path
		return am && !bm
	})
	ms := Mat_Sync {
		files = make([dynamic]string, context.temp_allocator),
		dirs  = make(map[string]bool, context.temp_allocator),
	}
	m.mat = &ms
	defer m.mat = nil
	for &it in items {
		if err := materialize_one(m, &it, tl[:]); err != .None {
			mat_owe(m, &ms)
			return err
		}
	}
	if err := mat_pay_owed(m, &ms); err != .None {
		mat_owe(m, &ms)
		return err
	}
	if berr := mat_barrier(m, &ms); berr != .None {
		mat_owe(m, &ms)
		return berr
	}
	mat_owed_clear(m)
	if ms.raced && !merge && !m.restoring && m.mat_retries < MAT_RACE_RETRIES {
		m.mat = nil
		m.mat_retries += 1
		defer m.mat_retries -= 1
		line_was, _ := clone_string(m.line, context.temp_allocator)
		mount_pass(m, false) or_return
		if m.line != line_was {
			return .None
		}
		one := make([dynamic]crdt.Lv, context.temp_allocator)
		if crdt.graph_version_lvs(&h.g, m.synced[:], &one) != .None {
			return .Corrupt
		}
		both := make([dynamic]crdt.Lv, context.temp_allocator)
		crdt.version_union(&h.g, tl[:], one[:], &both)
		return materialize_to(m, crdt.graph_version_ids(&h.g, both[:], context.temp_allocator), false)
	}
	if !m.restoring {
		clear(&m.synced)
		append(&m.synced, ..target)
	}
	m.passes += 1
	history_trim(h)
	return .None
}

Mat_Sync :: struct {
	files: [dynamic]string,
	dirs:  map[string]bool,
	raced: bool,
}

@(private)
mat_owe :: proc(m: ^Mount, ms: ^Mat_Sync) {
	have := make(map[string]bool, context.temp_allocator)
	for f in m.owed.files {
		have[f] = true
	}
	for f in ms.files {
		if !have[f] {
			have[f] = true
			append(&m.owed.files, clone_string(f, m.allocator) or_else "")
		}
	}
	if m.owed.dirs == nil {
		m.owed.dirs = make(map[string]bool, m.allocator)
	}
	for d in ms.dirs {
		if d not_in m.owed.dirs {
			m.owed.dirs[clone_string(d, m.allocator) or_else ""] = true
		}
	}
	m.shadow.owed = true
}

@(private)
mat_owed_clear :: proc(m: ^Mount) {
	for f in m.owed.files {
		delete(f, m.allocator)
	}
	clear(&m.owed.files)
	for d in m.owed.dirs {
		delete(d, m.allocator)
	}
	clear(&m.owed.dirs)
	m.shadow.owed = false
}

@(private)
mat_settle_owed :: proc(m: ^Mount) -> Error {
	if len(m.owed.files) == 0 && len(m.owed.dirs) == 0 {
		return .None
	}
	ms := Mat_Sync {
		files = make([dynamic]string, context.temp_allocator),
		dirs  = make(map[string]bool, context.temp_allocator),
	}
	mat_pay_owed(m, &ms) or_return
	if berr := mat_barrier(m, &ms); berr != .None {
		mat_owe(m, &ms)
		return berr
	}
	mat_owed_clear(m)
	return .None
}

@(private)
mat_pay_owed :: proc(m: ^Mount, ms: ^Mat_Sync) -> Error {
	for f in m.owed.files {
		mat_rewrite(m, f, ms) or_return
	}
	for d in m.owed.dirs {
		ms.dirs[clone_string(d, context.temp_allocator) or_else ""] = true
	}
	return .None
}

@(private)
mat_rewrite :: proc(m: ^Mount, abs: string, ms: ^Mat_Sync) -> Error {
	if len(abs) <= len(m.root) + 1 || !strings.has_prefix(abs, m.root) {
		return .None
	}
	rel := abs[len(m.root) + 1:]
	e, known := shadow_get(&m.shadow, rel) or_return
	if !known || e.kind != .File {
		return .None
	}
	d := probe(m, rel) or_return
	if d.kind != .File || !stat_clean(d.stat, e) {
		return .None
	}
	data, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
	if rerr == .Not_Found {
		return .None
	}
	from_prim(rerr) or_return
	mode := d.stat.mode & 0o7777
	tmp := temp_name(m, abs, context.temp_allocator)
	fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, mode)
	from_prim(oerr) or_return
	werr := prim.write_at(m.vfs, fd, data, 0)
	prim.fchmod(m.vfs, fd, mode)
	prim.close_file(m.vfs, fd)
	if werr != .None {
		prim.remove(m.vfs, tmp)
		return from_prim(werr)
	}
	from_prim(prim.rename(m.vfs, tmp, abs)) or_return
	nd := probe(m, rel) or_return
	e.stat = nd.stat
	shadow_put(&m.shadow, rel, e) or_return
	append(&ms.files, clone_string(abs, context.temp_allocator) or_else "")
	ms.dirs[clone_string(path_parent_abs(abs), context.temp_allocator) or_else ""] = true
	return .None
}

@(private)
MAT_SYNCFS_THRESHOLD :: 128

@(private)
MAT_RACE_RETRIES :: 8

mount_coalesce_ms :: proc(m: ^Mount) -> i64 {
	return min(i64(m.mat_bytes >> 17), 200)
}

@(private)
mat_raced :: proc(m: ^Mount) {
	if m.mat != nil {
		m.mat.raced = true
	}
}

@(private)
mat_file :: proc(m: ^Mount, abs: string) {
	if m.mat == nil {
		return
	}
	p, _ := clone_string(abs, context.temp_allocator)
	append(&m.mat.files, p)
	mat_dir(m, path_parent_abs(abs))
}

@(private)
mat_dir :: proc(m: ^Mount, dir: string) {
	if m.mat == nil || m.mat.dirs[dir] {
		return
	}
	d, _ := clone_string(dir, context.temp_allocator)
	m.mat.dirs[d] = true
}

@(private)
mat_ancestors :: proc(m: ^Mount, abs: string) {
	if m.mat == nil {
		return
	}
	p := path_parent_abs(abs)
	for len(p) >= len(m.root) {
		mat_dir(m, p)
		if len(p) == len(m.root) {
			break
		}
		p = path_parent_abs(p)
	}
}

@(private)
mat_barrier :: proc(m: ^Mount, ms: ^Mat_Sync) -> Error {
	if len(ms.files) == 0 && len(ms.dirs) == 0 {
		return .None
	}
	os := m.vfs.procs == prim.os_vfs().procs
	when ODIN_OS == .Windows {
		if os && len(ms.files) + len(ms.dirs) > 1 && mat_writeout(m, ms) == .None {
			return .None
		}
	}
	if HAS_SYNCFS && os && len(ms.files) + len(ms.dirs) > MAT_SYNCFS_THRESHOLD {
		if fd, e := prim.open_file(m.vfs, m.root, {.Directory}); e == .None {
			ok := os_syncfs(fd)
			prim.close_file(m.vfs, fd)
			if ok {
				return .None
			}
		}
	}
	darwin_batch := ODIN_OS == .Darwin && os
	last := prim.INVALID_FD
	defer if last != prim.INVALID_FD {
		prim.close_file(m.vfs, last)
	}
	keep :: proc(m: ^Mount, last: ^prim.Fd, fd: prim.Fd) {
		if last^ != prim.INVALID_FD {
			prim.close_file(m.vfs, last^)
		}
		last^ = fd
	}
	for f in ms.files {
		fd, e := prim.open_file(m.vfs, f)
		if e == .Not_Found {
			continue
		}
		from_prim(e) or_return
		se := prim.fullsync(m.vfs, fd) if darwin_batch else prim.datasync(m.vfs, fd)
		if se != .None {
			prim.close_file(m.vfs, fd)
			return from_prim(se)
		}
		keep(m, &last, fd)
	}
	dirs := sorted_strings(ms.dirs)
	for d in dirs {
		fd, e := prim.open_file(m.vfs, d, {.Directory})
		if e == .Not_Found {
			continue
		}
		from_prim(e) or_return
		se := prim.fullsync(m.vfs, fd)
		if se != .None && se != .Invalid {
			prim.close_file(m.vfs, fd)
			return from_prim(se)
		}
		keep(m, &last, fd)
	}
	if darwin_batch && last != prim.INVALID_FD {
		from_prim(prim.datasync(m.vfs, last)) or_return
	}
	return .None
}

@(private)
mat_writeout :: proc(m: ^Mount, ms: ^Mat_Sync) -> Error {
	for f in ms.files {
		fd, e := prim.open_file(m.vfs, f)
		if e == .Not_Found {
			continue
		}
		from_prim(e) or_return
		we := prim.writeout(m.vfs, fd)
		prim.close_file(m.vfs, fd)
		from_prim(we) or_return
	}
	for d in sorted_strings(ms.dirs) {
		fd, e := prim.open_file(m.vfs, d, {.Directory})
		if e == .Not_Found {
			continue
		}
		from_prim(e) or_return
		we := prim.writeout(m.vfs, fd)
		prim.close_file(m.vfs, fd)
		if we != .None && we != .Invalid && we != .Unsupported {
			return from_prim(we)
		}
	}
	probe_path, _ := path_join(m.root, "x", context.temp_allocator)
	tmp := temp_name(m, probe_path, context.temp_allocator)
	fd := from_prim_fd(prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, 0o600)) or_return
	err := from_prim(prim.fullsync(m.vfs, fd))
	prim.close_file(m.vfs, fd)
	prim.remove(m.vfs, tmp)
	return err
}

@(private)
from_prim_fd :: proc "contextless" (fd: prim.Fd, e: prim.Error) -> (prim.Fd, Error) {
	return fd, from_prim(e)
}

@(private)
moved_ancestors_touch :: proc(h: ^History, snap: ^fstree.Snapshot, sl: []crdt.Lv, touched: ^map[fstree.Inode_Id]bool) -> Error {
	if len(touched) == 0 {
		return .None
	}
	ssnap := version_snapshot(h, sl) or_return
	defer fstree.snapshot_destroy(&ssnap)
	work := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	for ino in touched {
		append(&work, ino)
	}
	up :: proc(s: ^fstree.Snapshot, from: fstree.Inode_Id, touched: ^map[fstree.Inode_Id]bool) -> Error {
		cur := from
		for _ in 0 ..< fstree.MAX_DEPTH {
			if cur == fstree.ROOT {
				return .None
			}
			touched[cur] = true
			info, ok, ierr := fstree.info(s, cur, context.temp_allocator)
			if ierr != nil {
				return .Corrupt
			}
			if !ok {
				return .None
			}
			cur = info.parent
		}
		return .None
	}
	for ino in work {
		ti, tok, terr := fstree.info(snap, ino, context.temp_allocator)
		si, sok, serr := fstree.info(&ssnap, ino, context.temp_allocator)
		if terr != nil || serr != nil {
			return .Corrupt
		}
		if tok && sok && ti.parent == si.parent && ti.name == si.name {
			continue
		}
		if tok {
			up(snap, ti.parent, touched) or_return
		}
		if sok {
			up(&ssnap, si.parent, touched) or_return
		}
	}
	return .None
}

@(private)
displaced_touch :: proc(m: ^Mount, snap: ^fstree.Snapshot, touched: ^map[fstree.Inode_Id]bool) -> Error {
	work := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	for ino in touched {
		append(&work, ino)
	}
	for len(work) > 0 {
		ino := pop(&work)
		if old, _, had := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return; had {
			if z, zok, zerr := fstree.lookup(snap, conflict_base(old)); zerr == nil && zok && z != ino && !touched[z] {
				touched[z] = true
				append(&work, z)
			}
		}
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
mat_blocker :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> (path: string, blocked: bool) {
	if it.has_old && it.entry.kind != .Dir && !disk_matches(m, it.old, it.entry) {
		return it.old, true
	}
	if it.present && it.kind != .Dir && (!it.has_old || it.old != it.path) {
		if d, _ := probe(m, it.path); d.kind != .Missing {
			if _, known, _ := shadow_get(&m.shadow, it.path); !known && !mat_is_item(m, it, tl) {
				return it.path, true
			}
		}
	}
	return "", false
}

@(private)
mat_is_item :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> bool {
	d, perr := probe(m, it.path)
	if perr != .None || disk_to_tree(d.kind) != it.kind {
		return false
	}
	switch it.kind {
	case .Dir:
		return true
	case .Symlink:
		return d.target == it.target
	case .File:
		if .Opaque in it.flags {
			return false
		}
		abuf: prim.Path_Buf
		raw, rerr := prim.read_file(m.vfs, abs_path(m, it.path, abuf[:]), context.temp_allocator)
		if rerr != .None {
			return false
		}
		disk, cok := eol_clean(m, it.path, raw, it.inode, true)
		if !cok {
			return false
		}
		ids := crdt.graph_version_ids(&m.history.g, tl, context.temp_allocator)
		want, werr := history_text_at(m.history, it.inode, ids, context.temp_allocator)
		return werr == .None && string(disk) == string(want)
	}
	return false
}

@(private)
mat_adopt :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> (adopted: bool, err: Error) {
	if m.restoring || !it.present || !mat_is_item(m, it, tl) {
		return false, .None
	}
	if it.has_old && it.old != it.path {
		if od, _ := probe(m, it.old); od.kind != .Missing {
			return false, .None
		}
		shadow_remove(&m.shadow, it.old) or_return
	}
	d, _ := probe(m, it.path)
	e := Entry{inode = it.inode, kind = it.kind, stat = d.stat}
	if it.kind == .File && m.db != nil {
		ids := crdt.graph_version_ids(&m.history.g, tl, context.temp_allocator)
		data := history_text_at(m.history, it.inode, ids, context.temp_allocator) or_return
		e.oid, _ = odb.hash(m.db.format, .Blob, data)
	}
	shadow_put(&m.shadow, it.path, e) or_return
	return true, .None
}

@(private)
mat_collides :: proc(m: ^Mount, it: ^Mat_Item, abs: string) -> bool {
	for c in m.collided {
		if path_under(it.path, c) {
			return true
		}
	}
	if it.has_old && it.old == it.path {
		return false
	}
	st, err := prim.lstat(m.vfs, abs)
	if err != .None || disk_name_matches(m.vfs, abs) {
		return false
	}
	if it.has_old {
		obuf: prim.Path_Buf
		if ost, oerr := prim.lstat(m.vfs, abs_path(m, it.old, obuf[:])); oerr == .None && ost.ino == st.ino && ost.dev == st.dev {
			return false
		}
	}
	c, _ := clone_string(it.path, m.allocator)
	append(&m.collided, c)
	return true
}

mount_collisions :: proc(m: ^Mount) -> []string {
	return m.collided[:]
}

@(private)
conflict_base :: proc(p: string) -> string {
	start := 0
	for i := len(p) - 1; i >= 0; i -= 1 {
		if p[i] == '/' {
			start = i + 1
			break
		}
	}
	for i in start ..< len(p) {
		if p[i] == '~' && i > start {
			return p[:i]
		}
	}
	return p
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
	d, _ := probe(m, rel)
	if d.kind == .Missing {
		return true
	}
	if d.kind == .File && e.kind == .Symlink && !mount_symlinks(m) {
		return stat_clean(d.stat, e)
	}
	if disk_to_tree(d.kind) != e.kind {
		return false
	}
	if e.kind == .Dir {
		return true
	}
	if d.stat != e.stat {
		return false
	}
	return !e.racy || e.kind != .File || disk_content_matches(m, rel, d.stat, e)
}

@(private)
disk_content_matches :: proc(m: ^Mount, rel: string, st: Stat, e: Entry) -> bool {
	if m.db == nil || e.oid == {} || st.size > m.opts.large_limit {
		return false
	}
	_, oid, _, ok, err := read_content(m, rel, st, e.inode, true)
	return err == .None && ok && oid == e.oid
}

@(private)
materialize_one :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> Error {
	if it.present && it.kind == .File && .Opaque in it.flags && m.db != nil && !m.restoring {
		reg, has, berr := history_blob_at(m.history, it.inode, tl)
		if berr == .None && has && !odb.exists(m.db, odb.Oid(reg.oid)) {
			mount_absent_add(m, it.path)
			return .None
		}
	}
	if m.adopting && it.present && it.has_old && it.old == it.path && it.kind == .File && it.entry.kind == .File && it.entry.oid != {} && disk_matches(m, it.path, it.entry) {
		return .None
	}
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
		removal := m.merge_base != nil && !it.present && it.entry.kind != .Dir
		if !removal {
			if m.merge_base != nil && it.present && it.kind == .File && it.old == it.path && .Opaque not_in it.flags && it.entry.kind == .File {
				merge_dirty(m, it, tl) or_return
			}
			mat_raced(m)
			mount_mark(m, it.old)
			return .None
		}
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
		mat_dir(m, path_parent_abs(abs))
		return .None if m.restoring else shadow_remove(&m.shadow, it.old)
	}
	if up := path_parent(it.path); len(up) > 0 && !m.restoring {
		if pe, found := shadow_get(&m.shadow, up) or_return; !found || pe.kind != .Dir || pe.inode != it.parent {
			mat_raced(m)
			mount_reshow_add(m, it.path)
			return .None
		}
	}
	abs := abs_path(m, it.path, abuf[:])
	if mat_collides(m, it, abs) {
		return .None
	}
	if it.has_old && it.old != it.path {
		if occ, found := shadow_get(&m.shadow, it.path) or_return; found && occ.inode != it.inode {
			mat_raced(m)
			mount_reshow_add(m, it.path)
			return .None
		}
		if d, _ := probe(m, it.path); !disk_matches(m, it.path, Entry{kind = it.kind}) && d.kind != .Missing {
			if adopted := mat_adopt(m, it, tl) or_return; adopted {
				return .None
			}
			mount_mark(m, it.path)
			return .None
		}
		obuf: prim.Path_Buf
		oabs := abs_path(m, it.old, obuf[:])
		ensure_parent(m, abs) or_return
		if err := prim.rename(m.vfs, oabs, abs); err != .None && err != .Not_Found {
			return from_prim(err)
		}
		mat_dir(m, path_parent_abs(oabs))
		mat_ancestors(m, abs)
		if m.restoring {
		} else if it.kind == .Dir {
			move_shadow_tree(m, it.old, it.path) or_return
		} else {
			shadow_remove(&m.shadow, it.old) or_return
		}
	} else if !it.has_old {
		if occ, found := shadow_get(&m.shadow, it.path) or_return; found && occ.inode != it.inode {
			mat_raced(m)
			mount_reshow_add(m, it.path)
			return .None
		}
		if it.kind != .Dir {
			if d, _ := probe(m, it.path); d.kind != .Missing {
				if adopted := mat_adopt(m, it, tl) or_return; adopted {
					return .None
				}
				mount_mark(m, it.path)
				return .None
			}
		}
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
		mat_ancestors(m, abs)
		if !m.restoring {
			watch_dir(m.reg, m, it.path, -1)
		}
	case .Symlink:
		ensure_parent(m, abs) or_return
		tmp := temp_name(m, abs, context.temp_allocator)
		prim.remove(m.vfs, tmp)
		linked := false
		if mount_symlinks(m) {
			#partial switch serr := prim.symlink(m.vfs, it.target, tmp); serr {
			case .None:
				linked = true
			case .Permission, .Unsupported, .Invalid:
				m.link_mode = .Emulated
			case:
				return from_prim(serr)
			}
		}
		if !linked {
			fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, 0o644)
			from_prim(oerr) or_return
			werr := prim.write_at(m.vfs, fd, transmute([]u8)it.target, 0)
			prim.close_file(m.vfs, fd)
			if werr != .None {
				prim.remove(m.vfs, tmp)
				return from_prim(werr)
			}
			mat_file(m, abs)
		}
		from_prim(prim.rename(m.vfs, tmp, abs)) or_return
		mat_ancestors(m, abs)
		if m.db != nil {
			e.oid, _ = odb.hash(m.db.format, .Blob, transmute([]u8)it.target)
		}
	case .File:
		ensure_parent(m, abs) or_return
		ours, raced := write_file_content(m, it, abs, tl, &e) or_return
		attr_invalidate(m, it.path)
		if raced {
			mat_raced(m)
			mount_mark(m, it.path)
			return .None
		}
		if ours != 0 && it.has_old && it.entry.stat.ino != 0 {
			if st, serr := prim.lstat(m.vfs, abs); serr == .None && st.ino != ours {
				mat_raced(m)
				mount_mark(m, it.path)
				return .None
			}
		}
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
write_file_content :: proc(m: ^Mount, it: ^Mat_Item, abs: string, tl: []crdt.Lv, e: ^Entry) -> (ours: u64, raced: bool, err: Error) {
	h := m.history
	mode: u32 = 0o755 if .Exec in it.flags else 0o644
	tmp := temp_name(m, abs, context.temp_allocator)
	if .Opaque in it.flags {
		reg, has := history_blob_at(h, it.inode, tl) or_return
		if !has || m.db == nil {
			return 0, false, .None
		}
		if e.oid == odb.Oid(reg.oid) && it.has_old && it.old == it.path {
			return 0, false, set_mode(m, abs, mode)
		}
		fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, mode)
		if oerr != .None {
			return 0, false, from_prim(oerr)
		}
		sink := Fd_Sink{m.vfs, fd, 0, .None}
		out := io.Stream{procedure = fd_sink_proc, data = &sink}
		sok := eol_smudge_blob(m, it.path, odb.Oid(reg.oid), out, fd_sink_rewind, &sink, it.inode, true)
		prim.fchmod(m.vfs, fd, mode)
		ours = tmp_ino(m, fd)
		prim.close_file(m.vfs, fd)
		if !sok || sink.err != .None {
			prim.remove(m.vfs, tmp)
			return 0, false, sink.err if sink.err != .None else .Io
		}
		if mat_replace(m, it, tmp, abs, ours) or_return {
			return 0, true, .None
		}
		mat_file(m, abs)
		mat_ancestors(m, abs)
		e.oid = odb.Oid(reg.oid)
		return ours, false, .None
	}
	ids := crdt.graph_version_ids(&h.g, tl, context.temp_allocator)
	data := history_text_at(h, it.inode, ids, context.temp_allocator) or_return
	m.mat_bytes += len(data)
	oid: odb.Oid
	if m.db != nil {
		oid, _ = odb.hash(m.db.format, .Blob, data)
		if oid == e.oid && it.has_old && it.old == it.path {
			return 0, false, set_mode(m, abs, mode)
		}
	}
	fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, mode)
	if oerr != .None {
		return 0, false, from_prim(oerr)
	}
	sink := Fd_Sink{m.vfs, fd, 0, .None}
	sok := eol_smudge_to(m, it.path, data, io.Stream{procedure = fd_sink_proc, data = &sink}, it.inode, true)
	prim.fchmod(m.vfs, fd, mode)
	ours = tmp_ino(m, fd)
	prim.close_file(m.vfs, fd)
	if !sok || sink.err != .None {
		prim.remove(m.vfs, tmp)
		return 0, false, sink.err if sink.err != .None else .Io
	}
	if mat_replace(m, it, tmp, abs, ours) or_return {
		return 0, true, .None
	}
	mat_file(m, abs)
	mat_ancestors(m, abs)
	e.oid = oid
	return ours, false, .None
}

@(private)
mat_replace :: proc(m: ^Mount, it: ^Mat_Item, tmp, abs: string, ours: u64) -> (raced: bool, err: Error) {
	if !it.has_old {
		return false, from_prim(prim.rename(m.vfs, tmp, abs))
	}
	if !disk_matches(m, it.old, it.entry) {
		prim.remove(m.vfs, tmp)
		return true, .None
	}
	if it.old != it.path || it.entry.kind != .File || ours == 0 || it.entry.stat.ino == 0 {
		return false, from_prim(prim.rename(m.vfs, tmp, abs))
	}
	if prim.rename_exchange(m.vfs, tmp, abs) != .None {
		return false, from_prim(prim.rename(m.vfs, tmp, abs))
	}
	st, serr := prim.lstat(m.vfs, tmp)
	if serr == .None && (st.ino != it.entry.stat.ino || st.size != it.entry.stat.size || st.mtime_ns != it.entry.stat.mtime_ns) {
		if cur, cerr := prim.lstat(m.vfs, abs); cerr == .None && cur.ino == ours {
			prim.rename_exchange(m.vfs, tmp, abs)
		}
		prim.remove(m.vfs, tmp)
		return true, .None
	}
	prim.remove(m.vfs, tmp)
	return false, .None
}

@(private)
tmp_ino :: proc(m: ^Mount, fd: prim.Fd) -> u64 {
	st, err := prim.fstat(m.vfs, fd)
	if err != .None {
		return 0
	}
	return st.ino
}

@(private)
merge_dirty :: proc(m: ^Mount, it: ^Mat_Item, tl: []crdt.Lv) -> Error {
	h := m.history
	abuf: prim.Path_Buf
	abs := abs_path(m, it.path, abuf[:])
	raw, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
	if rerr != .None {
		return .None
	}
	ours, cok := eol_clean(m, it.path, raw, it.inode, true)
	if !cok || textdiff.is_binary(ours) {
		return .None
	}
	base, berr := history_text_at(h, it.inode, m.merge_base, context.temp_allocator)
	if berr != .None {
		return .None
	}
	ids := crdt.graph_version_ids(&h.g, tl, context.temp_allocator)
	theirs := history_text_at(h, it.inode, ids, context.temp_allocator) or_return
	if string(base) == string(theirs) {
		return .None
	}
	merged := merge_union(base, ours, theirs) or_return
	if string(merged) == string(ours) {
		return .None
	}
	before, serr := prim.lstat(m.vfs, abs)
	if serr != .None {
		return .None
	}
	mode: u32 = 0o755 if .Exec in it.flags else 0o644
	tmp := temp_name(m, abs, context.temp_allocator)
	fd, oerr := prim.open_file(m.vfs, tmp, {.Write, .Create, .Truncate}, mode)
	if oerr != .None {
		return from_prim(oerr)
	}
	werr := prim.write_at(m.vfs, fd, eol_smudge(m, it.path, merged, context.temp_allocator, it.inode, true), 0)
	prim.fchmod(m.vfs, fd, mode)
	prim.close_file(m.vfs, fd)
	if werr != .None {
		prim.remove(m.vfs, tmp)
		return from_prim(werr)
	}
	now, nerr := prim.lstat(m.vfs, abs)
	if nerr != .None || disk_stat(now) != disk_stat(before) {
		prim.remove(m.vfs, tmp)
		return .None
	}
	from_prim(prim.rename(m.vfs, tmp, abs)) or_return
	mat_file(m, abs)
	return .None
}

@(private)
MERGE_OURS :: "0ndb-merge-ours-8f3a1c"
@(private)
MERGE_BASE :: "0ndb-merge-base-8f3a1c"
@(private)
MERGE_THEIRS :: "0ndb-merge-theirs-8f3a1c"

@(private)
merge_union :: proc(base, ours, theirs: []u8) -> (out: []u8, err: Error) {
	opts := textdiff.Merge_Options {
		style        = .Diff3,
		ours_label   = MERGE_OURS,
		base_label   = MERGE_BASE,
		theirs_label = MERGE_THEIRS,
	}
	res, merr := textdiff.merge3(base, ours, theirs, opts, context.temp_allocator)
	if merr != nil {
		return nil, .No_Memory
	}
	if res.conflicts == 0 {
		return res.data, .None
	}
	buf := make([dynamic]u8, 0, len(res.data), context.temp_allocator)
	o_lines := make([dynamic]string, context.temp_allocator)
	b_lines := make([dynamic]string, context.temp_allocator)
	t_lines := make([dynamic]string, context.temp_allocator)
	Section :: enum {
		Outside,
		Ours,
		Base,
		Theirs,
	}
	sec := Section.Outside
	rest := string(res.data)
	for line in strings.split_lines_after_iterator(&rest) {
		t := strings.trim_right(line, "\r\n")
		switch sec {
		case .Outside:
			if t == "<<<<<<< " + MERGE_OURS {
				sec = .Ours
				clear(&o_lines)
				clear(&b_lines)
				clear(&t_lines)
				continue
			}
			append(&buf, ..transmute([]u8)line)
		case .Ours:
			if t == "||||||| " + MERGE_BASE {
				sec = .Base
				continue
			}
			append(&o_lines, line)
		case .Base:
			if t == "=======" {
				sec = .Theirs
				continue
			}
			append(&b_lines, line)
		case .Theirs:
			if t == ">>>>>>> " + MERGE_THEIRS {
				sec = .Outside
				for l in t_lines {
					append(&buf, ..transmute([]u8)l)
				}
				used := make([]bool, len(b_lines), context.temp_allocator)
				for l in o_lines {
					in_base := false
					for bl, k in b_lines {
						if !used[k] && bl == l {
							used[k] = true
							in_base = true
							break
						}
					}
					if !in_base {
						append(&buf, ..transmute([]u8)l)
					}
				}
				continue
			}
			append(&t_lines, line)
		}
	}
	return buf[:], .None
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
fd_sink_rewind :: proc(data: rawptr) -> bool {
	s := (^Fd_Sink)(data)
	s.off = 0
	return prim.truncate(s.vfs, s.fd, 0) == .None
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

mount_absent_add :: proc(m: ^Mount, path: string) {
	for a in m.absent {
		if a == path {
			return
		}
	}
	p, _ := clone_string(path, m.allocator)
	append(&m.absent, p)
}

mount_reshow_add :: proc(m: ^Mount, path: string) {
	for r in m.reshow {
		if r == path {
			return
		}
	}
	p, _ := clone_string(path, m.allocator)
	append(&m.reshow, p)
}

mount_absent :: proc(m: ^Mount) -> []string {
	return m.absent[:]
}

@(private)
mount_absent_ready :: proc(m: ^Mount) -> bool {
	if len(m.absent) == 0 || m.db == nil || m.history == nil {
		return false
	}
	snap := fstree.current(&m.history.tree)
	for a in m.absent {
		ino, ok, lerr := fstree.lookup(&snap, a)
		if lerr != nil || !ok {
			return true
		}
		reg, has, berr := history_blob(m.history, ino)
		if berr != .None || !has || odb.exists(m.db, odb.Oid(reg.oid)) {
			return true
		}
	}
	return false
}

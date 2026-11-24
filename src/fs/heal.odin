package fs

import "base:runtime"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"

@(private = "file")
Heal :: struct {
	m:       ^Mount,
	snap:    fstree.Snapshot,
	synced:  Version,
	lvs:     []crdt.Lv,
	old:     map[string]Entry,
	rows:    [dynamic]Shadow_Row,
	tree:    map[string]bool,
	held:    [dynamic]string,
	missing: [dynamic]int,
}

@(private)
mount_heal :: proc(m: ^Mount) -> Error {
	if !m.shadow.damaged || m.shadow.txn {
		return .None
	}
	h := m.history
	if h == nil || !h.awake {
		return .Corrupt
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	a := context.temp_allocator
	x := Heal {
		m       = m,
		synced  = m.saved_synced[:] if m.saved_synced != nil else m.synced[:],
		old     = make(map[string]Entry, a),
		rows    = make([dynamic]Shadow_Row, a),
		tree    = make(map[string]bool, a),
		held    = make([dynamic]string, a),
		missing = make([dynamic]int, a),
	}
	shadow_salvage(&m.shadow, &x.old, a) or_return
	lvs := make([dynamic]crdt.Lv, a)
	if crdt.graph_version_lvs(&h.g, x.synced, &lvs) != .None {
		return .Corrupt
	}
	x.lvs = lvs[:]
	x.snap = version_snapshot(h, lvs[:]) or_return
	defer fstree.snapshot_destroy(&x.snap)
	root := Entry{inode = fstree.ROOT, kind = .Dir}
	if e, ok := x.old[""]; ok {
		root = e
	}
	append(&x.rows, Shadow_Row{"", root})
	heal_tree(&x, fstree.ROOT, "") or_return
	for p in prim.sorted_keys(x.old) {
		e := x.old[p]
		if len(p) == 0 || x.tree[p] || e.ver == 0 && !heal_unshown(m, p) {
			continue
		}
		if heal_unshown(m, p) {
			append(&x.rows, Shadow_Row{p, e})
		} else if d := probe(m, p) or_return; d.kind != .Missing {
			append(&x.held, p)
		}
	}
	heal_pair(&x) or_return
	shadow_rewrite(&m.shadow, x.rows[:]) or_return
	m.img.shadow = _shadow_mark_of(&m.shadow)
	for p in x.held {
		mount_stuck_add(m, p)
	}
	m.rescan = true
	m.saved = 0
	return .None
}

@(private = "file")
heal_unshown :: proc(m: ^Mount, p: string) -> bool {
	for c in m.collided {
		if path_at_or_under(p, c) {
			return true
		}
	}
	for r in m.reshow {
		if path_at_or_under(p, r) || path_at_or_under(conflict_base(p), r) {
			return true
		}
	}
	for q in m.absent {
		if path_at_or_under(p, q) {
			return true
		}
	}
	return false
}

@(private = "file")
heal_tree :: proc(x: ^Heal, dir: fstree.Inode_Id, prefix: string) -> Error {
	kids, kerr := fstree.children(&x.snap, dir, nil, 0, context.temp_allocator)
	if kerr != nil {
		return .Corrupt
	}
	for c in kids {
		p, _ := path_join(prefix, c.name, context.temp_allocator)
		if path_internal(p) {
			continue
		}
		x.tree[p] = true
		heal_row(x, p, c.inode, c.kind) or_return
		if c.kind == .Dir {
			heal_tree(x, c.inode, p) or_return
		}
	}
	return .None
}

@(private = "file")
heal_row :: proc(x: ^Heal, p: string, inode: fstree.Inode_Id, kind: fstree.Kind) -> Error {
	m := x.m
	e, found := x.old[p]
	found &&= e.inode == inode && e.kind == kind
	unshown := heal_unshown(m, p)
	if found && (kind == .Dir || unshown) {
		append(&x.rows, Shadow_Row{p, e})
		return .None
	}
	d := probe(m, p) or_return
	if unshown {
		if d.kind != .Missing && d.kind != .Dir {
			append(&x.held, p)
		}
		return .None
	}
	want, known := heal_oid(x, inode, kind) or_return
	if found && e.ver == 0 && (!known || e.oid == want) {
		append(&x.rows, Shadow_Row{p, e})
		return .None
	}
	abuf: prim.Path_Buf
	if d.kind != .Missing && !disk_name_matches(m.vfs, abs_path(m, p, abuf[:])) {
		append(&x.held, p)
		return .None
	}
	if found && e.ver != 0 {
		if d.kind == .Missing {
			append(&x.held, p)
			append(&x.rows, Shadow_Row{p, e})
			return .None
		}
		_, oid, _, rok := read_content(m, p, d.stat, inode, true) or_return
		if rok && known && oid == want {
			append(&x.rows, Shadow_Row{p, Entry{inode = inode, kind = kind, oid = want, stat = {ino = d.stat.ino}}})
			return .None
		}
		if !rok || oid != e.oid {
			append(&x.held, p)
		}
		append(&x.rows, Shadow_Row{p, e})
		return .None
	}
	ne := Entry{inode = inode, kind = kind, oid = want}
	if d.kind != .Missing && disk_to_tree(d.kind) == kind {
		ne.stat.ino = d.stat.ino
	}
	if d.kind == .Missing && kind == .File && known {
		append(&x.missing, len(x.rows))
	}
	append(&x.rows, Shadow_Row{p, ne})
	return .None
}

@(private = "file")
heal_oid :: proc(x: ^Heal, inode: fstree.Inode_Id, kind: fstree.Kind) -> (oid: odb.Oid, known: bool, err: Error) {
	m := x.m
	h := m.history
	if m.db == nil || kind == .Dir {
		return {}, false, .None
	}
	info, ok, ierr := fstree.info(&x.snap, inode, context.temp_allocator)
	if ierr != nil {
		return {}, false, .Corrupt
	}
	if !ok || !info.present {
		return {}, false, .None
	}
	if kind == .Symlink {
		oid, _ = odb.hash(m.db.format, .Blob, transmute([]u8)info.target)
		return oid, true, .None
	}
	if .Opaque in info.flags {
		reg, has := history_blob_at(h, inode, x.lvs) or_return
		return odb.Oid(reg.oid), has, .None
	}
	if o, has := history_text_oid(h, inode, x.synced) or_return; has {
		return o, true, .None
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	text := history_text_at(h, inode, x.synced, context.temp_allocator) or_return
	oid, _ = odb.hash(m.db.format, .Blob, text)
	return oid, true, .None
}

@(private = "file")
heal_pair :: proc(x: ^Heal) -> Error {
	m := x.m
	if len(x.missing) == 0 || m.db == nil {
		return .None
	}
	empty, _ := odb.hash(m.db.format, .Blob, nil)
	Pair :: struct {
		rows:  int,
		row:   int,
		files: int,
		ino:   u64,
	}
	pairs := make(map[odb.Oid]Pair, context.temp_allocator)
	for i in x.missing {
		o := x.rows[i].entry.oid
		if o == empty {
			continue
		}
		pr := pairs[o]
		pr.rows += 1
		pr.row = i
		pairs[o] = pr
	}
	if len(pairs) == 0 {
		return .None
	}
	heap := runtime.heap_allocator()
	chain, nodes := chain_for(m, "", heap)
	defer chain_free(nodes, heap)
	sc: Scanner
	scan_open(&sc, m.vfs, m.root, "", &m.ignore, chain, {threads = 1}) or_return
	defer scan_close(&sc)
	for {
		it, ok, err := scan_next(&sc)
		if err != .None {
			return err
		}
		if !ok {
			break
		}
		if it.ignored || it.kind == .Dir && len(it.path) > 0 && nested_repo(m, it.path) {
			if it.kind == .Dir {
				scan_skip(&sc)
			}
			continue
		}
		if it.kind != .File || x.tree[it.path] || it.stat.size == 0 {
			continue
		}
		path, _ := clone_string(it.path, context.temp_allocator)
		stat := it.stat
		if !it.statted {
			d := probe(m, path) or_return
			stat = d.stat
		}
		_, oid, _, rok := read_content(m, path, stat) or_return
		if !rok {
			continue
		}
		if pr, has := pairs[oid]; has {
			pr.files += 1
			pr.ino = stat.ino
			pairs[oid] = pr
		}
	}
	for _, pr in prim.unordered(pairs) {
		if pr.rows == 1 && pr.files == 1 {
			x.rows[pr.row].entry.stat.ino = pr.ino
		}
	}
	return .None
}

mount_stuck :: proc(m: ^Mount) -> []string {
	return m.stuck[:]
}

@(private)
mount_stuck_add :: proc(m: ^Mount, path: string) {
	for q in m.stuck {
		if q == path {
			return
		}
	}
	p, _ := clone_string(path, m.allocator)
	append(&m.stuck, p)
}

@(private)
mount_stuck_has :: proc(m: ^Mount, path: string) -> bool {
	for q in m.stuck {
		if path_at_or_under(path, q) || path_at_or_under(q, path) {
			return true
		}
	}
	return false
}

@(private)
mount_stuck_settle :: proc(m: ^Mount, rel: string, d: Probe) -> (held: bool, err: Error) {
	if len(m.stuck) == 0 || !mount_stuck_has(m, rel) {
		return false, .None
	}
	at := -1
	for q, i in m.stuck {
		if q == rel {
			at = i
		}
	}
	h := m.history
	if at < 0 || d.kind != .File || h == nil || m.db == nil {
		return true, .None
	}
	_, oid, _, rok := read_content(m, rel, d.stat) or_return
	if !rok {
		return true, .None
	}
	e, found := shadow_get(&m.shadow, rel) or_return
	same := found && e.kind == .File && e.oid == oid
	if !same {
		text, has, terr := heal_synced(m, rel)
		if terr != .None {
			return true, terr
		}
		if !has || text.oid != oid {
			return true, .None
		}
		shadow_put(&m.shadow, rel, Entry{inode = text.inode, kind = .File, oid = oid, stat = d.stat}) or_return
	}
	delete(m.stuck[at], m.allocator)
	ordered_remove(&m.stuck, at)
	m.saved = 0
	return !same, .None
}

@(private = "file")
Synced_File :: struct {
	inode: fstree.Inode_Id,
	oid:   odb.Oid,
}

@(private = "file")
heal_synced :: proc(m: ^Mount, rel: string) -> (f: Synced_File, has: bool, err: Error) {
	h := m.history
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &lvs) != .None {
		return {}, false, .Corrupt
	}
	x := Heal {
		m      = m,
		synced = m.synced[:],
		lvs    = lvs[:],
	}
	x.snap = version_snapshot(h, lvs[:]) or_return
	defer fstree.snapshot_destroy(&x.snap)
	ino, ok, lerr := fstree.lookup(&x.snap, rel)
	if lerr != nil {
		return {}, false, .Corrupt
	}
	if !ok {
		return {}, false, .None
	}
	info, iok, ierr := fstree.info(&x.snap, ino, context.temp_allocator)
	if ierr != nil {
		return {}, false, .Corrupt
	}
	if !iok || info.kind != .File {
		return {}, false, .None
	}
	oid, known := heal_oid(&x, ino, .File) or_return
	return {ino, oid}, known, .None
}

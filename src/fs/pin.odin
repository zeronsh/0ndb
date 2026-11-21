package fs

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"

PINS_BATCH :: 4096

Commit_Info :: struct {
	message: string,
	name:    string,
	email:   string,
	time:    i64,
}

history_note_blob :: proc(h: ^History, oid: odb.Oid) {
	if h == nil || oid == {} {
		return
	}
	append(&h.pins, oid)
}

history_pin_ref :: proc(h: ^History, buf: []u8) -> string {
	hex := prim.id_hex(h.id)
	out, _ := path_join_buf(buf, "refs/0ndb", string(hex[:]))
	return out
}

history_pins_flush :: proc(h: ^History, info: Commit_Info) -> Error {
	if h.db == nil {
		return .None
	}
	stored, _ := kv_get(&h.kv, transmute([]u8)string("pins"), context.temp_allocator) or_return
	n := odb.oid_size(h.db.format)
	total := len(stored) / n + len(h.pins)
	if total == 0 {
		return .None
	}
	entries := make([dynamic]odb.Tree_Entry, 0, total, context.temp_allocator)
	seen := make(map[odb.Oid]bool, total, context.temp_allocator)
	add :: proc(h: ^History, entries: ^[dynamic]odb.Tree_Entry, seen: ^map[odb.Oid]bool, oid: odb.Oid) {
		if seen[oid] {
			return
		}
		seen[oid] = true
		hb: [odb.MAX_HEX]u8
		name, _ := clone_string(odb.oid_to_string(oid, h.db.format, &hb), context.temp_allocator)
		append(entries, odb.Tree_Entry{name = name, oid = oid, mode = odb.MODE_FILE})
	}
	for i := 0; i + n <= len(stored); i += n {
		oid: odb.Oid
		copy(oid[:n], stored[i:i + n])
		add(h, &entries, &seen, oid)
	}
	for oid in h.pins {
		add(h, &entries, &seen, oid)
	}
	if len(entries) == 0 {
		return .None
	}
	odb.tree_sort(entries[:])
	tree := from_odb_v(odb.write_tree(h.db, entries[:])) or_return
	rbuf: [128]u8
	base := history_pin_ref(h, rbuf[:])
	ref := strings.concatenate({base, ".pins"}, context.temp_allocator)
	commit_on_ref(h.db, ref, tree, info, "0ndb pins", history_wall_ms(h) / 1000) or_return
	clear(&h.pins)
	return kv_del(&h.kv, transmute([]u8)string("pins"))
}

@(private)
pins_persist :: proc(h: ^History) -> Error {
	if len(h.pins) == 0 || h.db == nil {
		return .None
	}
	if len(h.pins) >= PINS_BATCH {
		return history_pins_flush(h, {})
	}
	stored, _ := kv_get(&h.kv, transmute([]u8)string("pins"), context.temp_allocator) or_return
	n := odb.oid_size(h.db.format)
	buf := make([dynamic]u8, 0, len(stored) + len(h.pins) * n, context.temp_allocator)
	append(&buf, ..stored)
	for &oid in h.pins {
		append(&buf, ..oid[:n])
	}
	kv_put(&h.kv, transmute([]u8)string("pins"), buf[:]) or_return
	clear(&h.pins)
	return .None
}

@(private)
from_odb_v :: proc(oid: odb.Oid, err: odb.Error) -> (odb.Oid, Error) {
	return oid, from_odb(err)
}

@(private)
commit_on_ref :: proc(db: ^odb.Odb, ref: string, tree: odb.Oid, info: Commit_Info, fallback: string, now_s: i64) -> Error {
	parent, perr := odb.read_ref(db, ref)
	parents: []odb.Oid
	if perr == .None {
		ps := make([]odb.Oid, 1, context.temp_allocator)
		ps[0] = parent
		parents = ps
	}
	t := info.time if info.time != 0 else now_s
	sig := odb.Signature {
		name  = info.name if len(info.name) > 0 else "0ndb",
		email = info.email if len(info.email) > 0 else "0ndb@localhost",
		time  = t,
	}
	msg := info.message if len(info.message) > 0 else fallback
	if !strings.has_suffix(msg, "\n") {
		msg = strings.concatenate({msg, "\n"}, context.temp_allocator)
	}
	c := odb.Commit {
		tree      = tree,
		parents   = parents,
		author    = sig,
		committer = sig,
		message   = msg,
	}
	oid := from_odb_v(odb.write_commit(db, c)) or_return
	from_odb(odb.barrier(db)) or_return
	expected: Maybe(odb.Oid)
	if perr == .None {
		expected = parent
	} else {
		expected = odb.ZERO_OID
	}
	from_odb(odb.update_ref(db, ref, oid, expected)) or_return
	return from_odb(odb.barrier(db))
}

mount_commit :: proc(m: ^Mount, info: Commit_Info) -> (commit: odb.Oid, err: Error) {
	if m.db == nil || m.history == nil {
		return {}, .Invalid
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return {}, .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	mount_wake(m) or_return
	m.gitlinks = gitlinks_refresh(m) or_return
	defer m.gitlinks = nil
	tree, nonempty := dir_tree(m, "") or_return
	if !nonempty {
		tree = from_odb_v(odb.write_tree(m.db, nil)) or_return
	}
	shadow_persist(&m.shadow) or_return
	msg := info.message
	if len(m.line) > 0 {
		msg = strings.concatenate({msg, "\n\n0ndb-line: ", m.line}, context.temp_allocator)
	}
	if len(m.head.commit) > 0 {
		msg = strings.concatenate({msg, "\n\n0ndb-head: ", m.head.branch, "@", m.head.commit}, context.temp_allocator)
	}
	ci := info
	ci.message = msg
	rbuf: [128]u8
	ref := history_pin_ref(m.history, rbuf[:])
	commit_on_ref(m.db, ref, tree, ci, "0ndb snapshot", history_wall_ms(m.history) / 1000) or_return
	history_pins_flush(m.history, info) or_return
	kv_commit(&m.history.kv) or_return
	c, _ := odb.read_ref(m.db, ref)
	return c, .None
}

@(private)
dir_tree :: proc(m: ^Mount, dir: string, pack: ^odb.Pack_Builder = nil) -> (oid: odb.Oid, nonempty: bool, err: Error) {
	self, found := shadow_get(&m.shadow, dir) or_return
	if found && self.kind == .Dir && self.oid != {} {
		return self.oid, true, .None
	}
	heap := runtime.heap_allocator()
	kids := make([dynamic]Shadow_Child, heap)
	defer {
		shadow_children_free(kids[:], heap)
		delete(kids)
	}
	shadow_children(&m.shadow, dir, &kids, heap) or_return
	entries := make([dynamic]odb.Tree_Entry, 0, len(kids), heap)
	defer delete(entries)
	names := make([dynamic]string, 0, len(kids), heap)
	defer {
		for n in names {
			delete(n, heap)
		}
		delete(names)
	}
	cbuf: [prim.PATH_MAX]u8
	for k in kids {
		child, ok := path_join_buf(cbuf[:], dir, k.name)
		if !ok {
			continue
		}
		e := k.entry
		mode: u32
		switch e.kind {
		case .Dir:
			c, _ := clone_string(child, heap)
			sub, any, serr := dir_tree(m, c, pack)
			delete(c, heap)
			serr or_return
			if !any {
				continue
			}
			e.oid = sub
			mode = odb.MODE_TREE
		case .File:
			ensure_blob(m, child, &e) or_continue
			mode = odb.MODE_EXEC if .Exec in tree_flags(m.history, e.inode) else odb.MODE_FILE
		case .Symlink:
			ensure_link_blob(m, child, &e) or_continue
			mode = odb.MODE_LINK
		}
		n, _ := clone_string(k.name, heap)
		append(&names, n)
		append(&entries, odb.Tree_Entry{name = n, oid = e.oid, mode = mode})
	}
	for gl in m.gitlinks {
		if !path_under(gl.path, dir) && len(dir) > 0 {
			continue
		}
		sub := gl.path[len(dir) + 1:] if len(dir) > 0 else gl.path
		slash := -1
		for c, i in transmute([]u8)sub {
			if c == '/' {
				slash = i
				break
			}
		}
		name := sub if slash < 0 else sub[:slash]
		exists := false
		for en in entries {
			if en.name == name {
				exists = true
				break
			}
		}
		if exists {
			continue
		}
		if slash < 0 {
			n, _ := clone_string(name, heap)
			append(&names, n)
			append(&entries, odb.Tree_Entry{name = n, oid = gl.oid, mode = odb.MODE_GITLINK})
			continue
		}
		child, _ := path_join(dir, name, heap)
		sub_oid, any, serr := dir_tree(m, child, pack)
		delete(child, heap)
		serr or_return
		if any {
			n, _ := clone_string(name, heap)
			append(&names, n)
			append(&entries, odb.Tree_Entry{name = n, oid = sub_oid, mode = odb.MODE_TREE})
		}
	}
	if len(entries) == 0 {
		return {}, false, .None
	}
	odb.tree_sort(entries[:])
	if pack != nil {
		oid = from_odb_v(odb.pack_add_tree(pack, entries[:])) or_return
	} else {
		oid = from_odb_v(odb.write_tree(m.db, entries[:])) or_return
	}
	if found && self.kind == .Dir {
		self.oid = oid
		shadow_put(&m.shadow, dir, self) or_return
	}
	if shadow_pending_count(&m.shadow) >= 65536 {
		shadow_persist(&m.shadow) or_return
	}
	return oid, true, .None
}

@(private)
ensure_blob :: proc(m: ^Mount, rel: string, e: ^Entry) -> Error {
	if e.oid != {} && odb.exists(m.db, e.oid) {
		return .None
	}
	h := m.history
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch, 64 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	if .Opaque in tree_flags(h, e.inode) {
		reg, has := history_blob(h, e.inode) or_return
		if has && odb.exists(m.db, odb.Oid(reg.oid)) {
			e.oid = odb.Oid(reg.oid)
			return .None
		}
	} else {
		if oid, ok := history_text_oid(h, e.inode, m.synced[:]) or_return; ok {
			e.oid = oid
			return .None
		}
		text, terr := history_text_at(h, e.inode, m.synced[:], context.temp_allocator)
		if terr == .None {
			oid := from_odb_v(odb.write(m.db, .Blob, text)) or_return
			history_note_blob(h, oid)
			history_note_file_blob(h, e.inode, oid, m.synced[:])
			e.oid = oid
			return .None
		}
	}
	return .Not_Found
}

@(private)
ensure_link_blob :: proc(m: ^Mount, rel: string, e: ^Entry) -> Error {
	if e.oid != {} && odb.exists(m.db, e.oid) {
		return .None
	}
	snap := fstree.current(&m.history.tree)
	info, ok, ierr := fstree.info(&snap, e.inode, context.temp_allocator)
	if ierr != nil || !ok {
		return .Not_Found
	}
	oid := from_odb_v(odb.write(m.db, .Blob, transmute([]u8)info.target)) or_return
	history_note_blob(m.history, oid)
	e.oid = oid
	return .None
}

invalidate_parents :: proc(m: ^Mount, rel: string) -> Error {
	q := rel
	for len(q) > 0 {
		q = path_parent(q)
		e, found := shadow_get(&m.shadow, q) or_return
		if !found || e.kind != .Dir || e.oid == {} {
			return .None
		}
		e.oid = {}
		shadow_put(&m.shadow, q, e) or_return
	}
	return .None
}

history_note_file_blob :: proc(h: ^History, inode: fstree.Inode_Id, oid: odb.Oid, version: Version) {
	if h == nil || oid == {} || len(version) == 0 {
		return
	}
	key := inode_key("fv", inode)
	data, _, err := kv_get(&h.kv, key, context.temp_allocator)
	if err != .None {
		return
	}
	buf := make([dynamic]u8, 0, len(data) + 64, context.temp_allocator)
	append(&buf, ..data)
	w := prim.writer(&buf)
	o := oid
	prim.write_raw(&w, o[:])
	vb := make([dynamic]u8, context.temp_allocator)
	encode_version(&vb, version)
	prim.write_bytes(&w, vb[:])
	kv_put(&h.kv, key, buf[:])
}

blob_versions_hit :: proc(h: ^History, inode: fstree.Inode_Id, spans: []crdt.Op_Span, out: ^[dynamic]odb.Oid) -> Error {
	key := inode_key("fv", inode)
	data, found := kv_get(&h.kv, key, context.temp_allocator) or_return
	if !found {
		return .None
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	rd := prim.reader(data)
	keep := make([dynamic]u8, 0, len(data), context.temp_allocator)
	for !prim.reader_done(&rd) {
		start := rd.pos
		oid: odb.Oid
		prim.read_fixed(&rd, oid[:])
		vb := prim.read_bytes(&rd)
		if !prim.reader_ok(&rd) {
			return .Corrupt
		}
		v := decode_version(vb, context.temp_allocator) or_return
		hit := false
		if crdt.graph_version_lvs(&h.g, v, &lvs) == .None {
			for sp in spans {
				for k := 0; k < sp.len && !hit; k += 1 {
					lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{sp.id.actor, sp.id.seq + u64(k)})
					if ok && crdt.graph_contains(&h.g, lvs[:], lv) {
						hit = true
					}
					if ok {
						break
					}
				}
				if hit {
					break
				}
			}
		}
		if hit {
			append(out, oid)
		} else {
			append(&keep, ..data[start:rd.pos])
		}
	}
	if len(keep) == len(data) {
		return .None
	}
	return kv_put(&h.kv, key, keep[:])
}

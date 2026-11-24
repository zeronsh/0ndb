package fs

import "core:slice"
import "core:strings"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"
import "../textdiff"

@(private)
Commit_Entry :: struct {
	oid:  odb.Oid,
	mode: u32,
}

line_from_commit :: proc(m: ^Mount, line: string, base: Version, commit_hex: string, ref: string) -> (head: Version, err: Error) {
	if m.db == nil || m.history == nil {
		return nil, .Unsupported
	}
	mount_wake(m) or_return
	h := m.history
	commit, _, ok := odb.oid_from_hex(commit_hex)
	if !ok {
		return nil, .Invalid
	}
	entries := make(map[string]Commit_Entry, context.temp_allocator)
	commit_entries(m.db, commit, &entries) or_return
	bl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, base, &bl) != .None {
		return nil, .Corrupt
	}
	snap := version_snapshot(h, bl[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	actor := line_actor(m, line) or_return
	b: Builder
	builder_init(&b, h, actor)
	b.parents = bl[:]
	gbuf := make([dynamic]u8, context.temp_allocator)
	encode_git_op(&gbuf, "checkout", ref, commit_hex)
	builder_opaque(&b, gbuf[:])
	marked := b.n
	paths := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for p in prim.sorted_keys(entries) {
		append(&paths, p)
	}
	slice.sort(paths[:])
	inodes := make(map[string]fstree.Inode_Id, context.temp_allocator)
	inodes[""] = fstree.ROOT
	for p in paths {
		e := entries[p]
		parent, pok := inodes[path_parent(p)]
		if !pok {
			continue
		}
		kind := commit_kind(e.mode)
		cur, found, lerr := fstree.lookup(&snap, p)
		if lerr != nil {
			return nil, .Corrupt
		}
		info: fstree.Info
		if found {
			i, iok, ierr := fstree.info(&snap, cur, context.temp_allocator)
			if ierr != nil {
				return nil, .Corrupt
			}
			info = i
			if !iok || !i.present || i.kind != kind {
				builder_tree(&b, fstree.Op_Remove{inode = cur})
				found = false
			}
		}
		if kind == .Dir {
			inodes[p] = cur if found else builder_tree(&b, fstree.Op_Create{parent = parent, name = path_name(p), kind = .Dir})
			continue
		}
		t, data, rerr := odb.read(m.db, e.oid, context.temp_allocator)
		if rerr != .None || t != .Blob {
			return nil, from_odb(rerr) if rerr != .None else .Corrupt
		}
		if kind == .Symlink {
			if !found {
				builder_tree(&b, fstree.Op_Create{parent = parent, name = path_name(p), kind = .Symlink, target = string(data)})
			} else if info.target != string(data) {
				builder_tree(&b, fstree.Op_Set_Target{inode = cur, target = string(data)})
			}
			continue
		}
		binary := len(data) > int(m.opts.large_limit) || textdiff.is_binary(data)
		flags: fstree.Flags
		if e.mode == odb.MODE_EXEC {
			flags += {.Exec}
		}
		if binary {
			flags += {.Opaque}
		}
		flags += {.Git_Clean}
		if !found {
			inode := builder_tree(&b, fstree.Op_Create{parent = parent, name = path_name(p), kind = .File, flags = flags})
			if binary {
				builder_content(&b, inode, e.oid, i64(len(data)))
				note_builder_blob(&b, inode, e.oid)
			} else if len(data) > m.opts.inline_limit {
				builder_insert_ref(&b, inode, 0, e.oid, len(data))
				note_builder_blob(&b, inode, e.oid)
			} else {
				builder_insert(&b, inode, 0, data)
			}
			continue
		}
		if (.Exec in flags) != (.Exec in info.flags) {
			builder_tree(&b, fstree.Op_Set_Flags{inode = cur, mask = {.Exec}, value = flags & {.Exec}})
		}
		if binary || .Opaque in info.flags {
			reg, has := history_blob_at(h, cur, bl[:]) or_return
			if !has || odb.Oid(reg.oid) != e.oid {
				if .Opaque not_in info.flags {
					builder_tree(&b, fstree.Op_Set_Flags{inode = cur, mask = {.Opaque}, value = {.Opaque}})
				}
				builder_content(&b, cur, e.oid, i64(len(data)))
				note_builder_blob(&b, cur, e.oid)
			}
			continue
		}
		old := history_text_at(h, cur, base, context.temp_allocator) or_return
		if string(old) != string(data) {
			emit_text_edits(m, &b, cur, p, old, data) or_return
		}
	}
	gone := make([dynamic]fstree.Inode_Id, context.temp_allocator)
	commit_removals(&snap, fstree.ROOT, "", &entries, &gone) or_return
	for ino in gone {
		builder_tree(&b, fstree.Op_Remove{inode = ino})
	}
	if b.n == marked {
		history_set_line(h, line, base) or_return
		return slice.clone(base, context.temp_allocator), .None
	}
	batch := crdt.Batch {
		actor   = b.actor,
		seq     = b.seq0,
		lamport = history_lamport_after(h, base),
		parents = base,
		ops     = b.ops[:],
	}
	history_commit_local(h, &batch, line) or_return
	out := make([]crdt.Op_Id, 1, context.temp_allocator)
	out[0] = crdt.Op_Id{b.actor, b.seq0 + u64(b.n) - 1}
	builder_reset(&b)
	return out, .Reloading if history_reloading(h) else .None
}

@(private)
commit_kind :: proc "contextless" (mode: u32) -> fstree.Kind {
	switch mode {
	case odb.MODE_TREE:
		return .Dir
	case odb.MODE_LINK:
		return .Symlink
	}
	return .File
}

@(private)
commit_entries :: proc(db: ^odb.Odb, commit: odb.Oid, out: ^map[string]Commit_Entry) -> Error {
	t, data, err := odb.read(db, commit, context.temp_allocator)
	if err != .None {
		return from_odb(err)
	}
	if t != .Commit {
		return .Corrupt
	}
	c, cerr := odb.commit_decode(data, db.format, context.temp_allocator)
	if cerr != .None {
		return .Corrupt
	}
	return tree_entries(db, c.tree, "", out)
}

@(private)
tree_entries :: proc(db: ^odb.Odb, tree: odb.Oid, prefix: string, out: ^map[string]Commit_Entry) -> Error {
	t, data, err := odb.read(db, tree, context.temp_allocator)
	if err != .None {
		return from_odb(err)
	}
	if t != .Tree {
		return .Corrupt
	}
	list, derr := odb.tree_decode(data, db.format, context.temp_allocator)
	if derr != .None {
		return .Corrupt
	}
	for e in list {
		if e.mode == odb.MODE_GITLINK {
			continue
		}
		p := e.name if len(prefix) == 0 else strings.concatenate({prefix, "/", e.name}, context.temp_allocator)
		out[p] = Commit_Entry{oid = e.oid, mode = e.mode}
		if e.mode == odb.MODE_TREE {
			tree_entries(db, e.oid, p, out) or_return
		}
	}
	return .None
}

@(private)
commit_removals :: proc(snap: ^fstree.Snapshot, dir: fstree.Inode_Id, prefix: string, keep: ^map[string]Commit_Entry, out: ^[dynamic]fstree.Inode_Id) -> Error {
	kids, err := fstree.children(snap, dir, nil, 0, context.temp_allocator)
	if err != nil {
		return .Corrupt
	}
	for k in kids {
		p := k.name if len(prefix) == 0 else strings.concatenate({prefix, "/", k.name}, context.temp_allocator)
		if path_internal(p) {
			continue
		}
		if _, ok := keep[p]; !ok {
			if k.kind == .Dir {
				commit_removals(snap, k.inode, p, keep, out) or_return
			}
			append(out, k.inode)
			continue
		}
		if k.kind == .Dir {
			commit_removals(snap, k.inode, p, keep, out) or_return
		}
	}
	return .None
}

@(private)
line_actor :: proc(m: ^Mount, line: string) -> (actor: prim.Id, err: Error) {
	was, _ := clone_string(m.line, context.temp_allocator)
	saved := m.actor
	delete(m.line, m.allocator)
	m.line, _ = clone_string(line, m.allocator)
	aerr := mount_line_actor(m)
	actor = m.actor
	delete(m.line, m.allocator)
	m.line, _ = clone_string(was, m.allocator)
	m.actor = saved
	return actor, aerr
}

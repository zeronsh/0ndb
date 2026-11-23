package fs

import "core:fmt"
import "../crdt"
import "../fstree"
import "../prim"

mount_synced_mismatches :: proc(m: ^Mount, out: ^[dynamic]string, allocator := context.allocator) -> Error {
	return verify_mount(m, true, out, allocator)
}

mount_shadow_mismatches :: proc(m: ^Mount, out: ^[dynamic]string, allocator := context.allocator) -> Error {
	if len(m.intents) > 0 || !m.imported {
		return .None
	}
	return verify_mount(m, false, out, allocator)
}

@(private = "file")
verify_mount :: proc(m: ^Mount, disk: bool, out: ^[dynamic]string, allocator := context.allocator) -> Error {
	h := m.history
	if h == nil || !m.awake || m.rescan || len(m.fences) > 0 || m.restoring || m.adopting || m.adopt_pending || len(m.unwatched) > 0 {
		return .None
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &lvs) != .None {
		return .Corrupt
	}
	snap := version_snapshot(h, lvs[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	seen := make(map[string]bool, context.temp_allocator)
	verify_tree(m, &snap, fstree.ROOT, "", disk, &seen, out, allocator) or_return
	return verify_shadow(m, "", &seen, out, allocator)
}

@(private = "file")
verify_skip :: proc(m: ^Mount, p: string) -> bool {
	if path_internal(p) {
		return true
	}
	for q := p; len(q) > 0; q = path_parent(q) {
		if q in m.dirty {
			return true
		}
	}
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
	return false
}

@(private = "file")
verify_tree :: proc(m: ^Mount, snap: ^fstree.Snapshot, dir: fstree.Inode_Id, prefix: string, disk: bool, seen: ^map[string]bool, out: ^[dynamic]string, allocator := context.allocator) -> Error {
	kids, kerr := fstree.children(snap, dir, nil, 0, context.temp_allocator)
	if kerr != nil {
		return .Corrupt
	}
	for c in kids {
		p, _ := path_join(prefix, c.name, context.temp_allocator)
		seen[p] = true
		if verify_skip(m, p) {
			continue
		}
		e, found := shadow_get(&m.shadow, p) or_return
		if found && e.has_at {
			verify_at(m, p, e, disk, out, allocator) or_return
			continue
		}
		if !found || e.inode != c.inode {
			append(out, fmt.aprintf("%s: synced inode %v, shadow %v (found %v)", p, c.inode, e.inode, found, allocator = allocator))
		}
		if !disk {
			if c.kind == .Dir {
				verify_tree(m, snap, c.inode, p, disk, seen, out, allocator) or_return
			}
			continue
		}
		d := probe(m, p) or_return
		switch c.kind {
		case .Dir:
			if d.kind != .Dir {
				append(out, fmt.aprintf("%s: synced directory, disk %v", p, d.kind, allocator = allocator))
				continue
			}
			verify_tree(m, snap, c.inode, p, disk, seen, out, allocator) or_return
		case .File:
			if d.kind != .File {
				append(out, fmt.aprintf("%s: synced file, disk %v", p, d.kind, allocator = allocator))
				continue
			}
			info, ok, ierr := fstree.info(snap, c.inode, context.temp_allocator)
			if ierr != nil || !ok || .Opaque in info.flags {
				continue
			}
			abuf: prim.Path_Buf
			raw, rerr := prim.read_file(m.vfs, abs_path(m, p, abuf[:]), context.temp_allocator)
			if rerr != .None {
				append(out, fmt.aprintf("%s: unreadable on disk: %v", p, rerr, allocator = allocator))
				continue
			}
			disk, cok := eol_clean(m, p, raw, c.inode, true)
			if !cok {
				continue
			}
			want := history_text_at(m.history, c.inode, m.synced[:], context.temp_allocator) or_return
			if string(disk) != string(want) {
				append(out, fmt.aprintf("%s: disk %q, synced %q", p, disk, want, allocator = allocator))
			}
		case .Symlink:
			if d.kind == .Missing {
				append(out, fmt.aprintf("%s: synced symlink missing on disk", p, allocator = allocator))
			}
		}
	}
	return .None
}

@(private = "file")
verify_at :: proc(m: ^Mount, p: string, e: Entry, disk: bool, out: ^[dynamic]string, allocator := context.allocator) -> Error {
	h := m.history
	at := [1]crdt.Op_Id{inode_op(h, e.at)}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, at[:], &lvs) != .None {
		append(out, fmt.aprintf("%s: shadow version %v is not in the history", p, at[0], allocator = allocator))
		return .None
	}
	snap := version_snapshot(h, lvs[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	id, ok, lerr := fstree.lookup(&snap, p)
	if lerr != nil {
		return .Corrupt
	}
	if !ok || id != e.inode {
		append(out, fmt.aprintf("%s: shadow inode %v at its own version, tree %v (found %v)", p, e.inode, id, ok, allocator = allocator))
		return .None
	}
	if !disk || e.kind != .File {
		return .None
	}
	abuf: prim.Path_Buf
	raw, rerr := prim.read_file(m.vfs, abs_path(m, p, abuf[:]), context.temp_allocator)
	if rerr != .None {
		append(out, fmt.aprintf("%s: unreadable on disk: %v", p, rerr, allocator = allocator))
		return .None
	}
	data, cok := eol_clean(m, p, raw, e.inode, true)
	if !cok {
		return .None
	}
	want := history_text_at(h, e.inode, at[:], context.temp_allocator) or_return
	if string(data) != string(want) {
		append(out, fmt.aprintf("%s: disk %q, at its own version %q", p, data, want, allocator = allocator))
	}
	return .None
}

@(private = "file")
verify_shadow :: proc(m: ^Mount, dir: string, seen: ^map[string]bool, out: ^[dynamic]string, allocator := context.allocator) -> Error {
	kids := make([dynamic]Shadow_Child, context.temp_allocator)
	shadow_children(&m.shadow, dir, &kids, context.temp_allocator) or_return
	for k in kids {
		p, _ := path_join(dir, k.name, context.temp_allocator)
		if verify_skip(m, p) {
			continue
		}
		if k.entry.has_at {
			if !seen[p] {
				seen[p] = true
				verify_at(m, p, k.entry, true, out, allocator) or_return
			}
			continue
		}
		if !seen[p] {
			append(out, fmt.aprintf("%s: in the shadow as %v but not in the synced tree", p, k.entry.inode, allocator = allocator))
		}
		if k.entry.kind == .Dir {
			verify_shadow(m, p, seen, out, allocator) or_return
		}
	}
	return .None
}

mount_synced_text :: proc(m: ^Mount, rel: string, allocator := context.allocator) -> (text: []u8, found: bool, err: Error) {
	h := m.history
	if h == nil || !h.awake {
		return nil, false, .Busy
	}
	lvs := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &lvs) != .None {
		return nil, false, .Corrupt
	}
	snap := version_snapshot(h, lvs[:]) or_return
	defer fstree.snapshot_destroy(&snap)
	id, ok, lerr := fstree.lookup(&snap, rel)
	if lerr != nil {
		return nil, false, .Corrupt
	}
	if !ok {
		return nil, false, .None
	}
	t := history_text_at(h, id, m.synced[:], allocator) or_return
	return t, true, .None
}

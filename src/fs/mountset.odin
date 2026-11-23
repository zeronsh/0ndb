package fs

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "../crdt"
import "../fshist"
import "../fstree"
import "../odb"
import "../prim"
import "../textdiff"

Spawner :: struct {
	data: rawptr,
	run:  proc(data: rawptr, argv: []string, cwd: string) -> Error,
}

Set_Member :: struct {
	name:  string,
	path:  string,
	mount: ^Mount,
}

Mount_Set :: struct {
	root:      string,
	members:   [dynamic]Set_Member,
	allocator: runtime.Allocator,
}

Tree_Version :: struct {
	name:    string,
	line:    string,
	version: Version,
	branch:  string,
	commit:  string,
}

mount_set_init :: proc(s: ^Mount_Set, root: string, allocator := context.allocator) {
	s^ = {
		allocator = allocator,
	}
	s.root, _ = clone_string(root, allocator)
	s.members = make([dynamic]Set_Member, allocator)
}

mount_set_destroy :: proc(s: ^Mount_Set) {
	for mb in s.members {
		delete(mb.name, s.allocator)
		delete(mb.path, s.allocator)
	}
	delete(s.members)
	delete(s.root, s.allocator)
	s^ = {}
}

mount_set_add :: proc(s: ^Mount_Set, name: string, path: string, m: ^Mount) -> Error {
	for mb in s.members {
		if mb.name == name || mb.path == path || path_at_or_under(path, mb.path) || path_at_or_under(mb.path, path) {
			return .Exists
		}
	}
	n, _ := clone_string(name, s.allocator)
	p, _ := clone_string(path, s.allocator)
	append(&s.members, Set_Member{n, p, m})
	return .None
}

mount_set_remove :: proc(s: ^Mount_Set, name: string) -> ^Mount {
	for mb, i in s.members {
		if mb.name == name {
			m := mb.mount
			delete(mb.name, s.allocator)
			delete(mb.path, s.allocator)
			ordered_remove(&s.members, i)
			return m
		}
	}
	return nil
}

mount_set_member_root :: proc(s: ^Mount_Set, path: string, allocator := context.allocator) -> string {
	out, _ := path_join(s.root, path, allocator)
	return out
}

mount_set_sync :: proc(s: ^Mount_Set) -> Error {
	for mb in s.members {
		mount_sync(mb.mount) or_return
	}
	return .None
}

mount_set_versions :: proc(s: ^Mount_Set, allocator := context.allocator) -> (out: []Tree_Version, err: Error) {
	mount_set_sync(s) or_return
	list := make([dynamic]Tree_Version, 0, len(s.members), allocator)
	for mb in s.members {
		m := mb.mount
		v := make([]crdt.Op_Id, len(m.synced), allocator)
		copy(v, m.synced[:])
		tv := Tree_Version {
			name    = clone_string(mb.name, allocator) or_else "",
			line    = clone_string(m.line, allocator) or_else "",
			version = v,
			branch  = clone_string(m.head.branch, allocator) or_else "",
			commit  = clone_string(m.head.commit, allocator) or_else "",
		}
		append(&list, tv)
	}
	return list[:], .None
}

mount_set_land :: proc(s: ^Mount_Set, targets: []^Mount, conflicts: ^[dynamic]Land_Conflict, allocator := context.allocator) -> Error {
	if len(targets) != len(s.members) {
		return .Invalid
	}
	for mb, i in s.members {
		mount_sync_from(mb.mount, targets[i].line, conflicts, allocator) or_return
	}
	if len(conflicts) > 0 {
		return .Conflicts
	}
	for mb, i in s.members {
		h := mb.mount.history
		v, found := history_line(h, mb.mount.line, context.temp_allocator) or_return
		if !found {
			return .Not_Found
		}
		history_set_line(h, targets[i].line, v) or_return
	}
	for t in targets {
		mount_materialize(t) or_return
	}
	return .None
}

mount_set_go_back :: proc(s: ^Mount_Set, versions: []Tree_Version, spawner: Spawner, thread: prim.Id) -> Error {
	for tv in versions {
		for mb in s.members {
			if mb.name != tv.name {
				continue
			}
			mount_restore(mb.mount, tv.version, thread) or_return
			if mb.mount.has_git && len(tv.commit) > 0 {
				git_restore(mb.mount, tv.branch, tv.commit, spawner, thread) or_return
			}
		}
	}
	return .None
}

mount_restore :: proc(m: ^Mount, target: Version, owner: prim.Id) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 256 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	mount_sync(m) or_return
	h := m.history
	cl := make([dynamic]crdt.Lv, context.temp_allocator)
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &cl) != .None || crdt.graph_version_lvs(&h.g, target, &tl) != .None {
		return .Not_Found
	}
	pseudo := mount_revert_pseudo(m.id, m.line, owner)
	ractor := fshist.ingestion_actor(h.self, pseudo)
	if known := crdt.graph_known(&h.g, ractor); known > 0 {
		if prev, pok := crdt.graph_lv(&h.g, crdt.Op_Id{ractor, known - 1}); pok {
			one := [1]crdt.Lv{prev}
			both := make([dynamic]crdt.Lv, context.temp_allocator)
			crdt.version_union(&h.g, cl[:], one[:], &both)
			clear(&cl)
			append(&cl, ..both[:])
		}
	}
	only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
	crdt.graph_diff(&h.g, cl[:], tl[:], &only_a, &only_b)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	spans_touched(h, only_a[:], &touched) or_return
	spans_touched(h, only_b[:], &touched) or_return
	if len(touched) == 0 {
		return .None
	}
	snap_c := version_snapshot(h, cl[:]) or_return
	defer fstree.snapshot_destroy(&snap_c)
	snap_t := version_snapshot(h, tl[:]) or_return
	defer fstree.snapshot_destroy(&snap_t)
	order := sorted_inodes(touched)
	b: Builder
	builder_init(&b, h, ractor)
	for ino in order {
		it, okt, e1 := fstree.info(&snap_t, ino, context.temp_allocator)
		ic, okc, e2 := fstree.info(&snap_c, ino, context.temp_allocator)
		if e1 != nil || e2 != nil {
			return .Corrupt
		}
		pt := okt && it.present
		pc := okc && ic.present
		if !pt {
			if pc {
				builder_tree(&b, fstree.Op_Remove{inode = ino})
			}
			continue
		}
		if !pc {
			builder_tree(&b, fstree.Op_Restore{inode = ino})
		}
		if !pc || it.parent != ic.parent || it.name != ic.name {
			builder_tree(&b, fstree.Op_Move{inode = ino, parent = it.parent, name = it.name})
		}
		if it.flags != ic.flags {
			builder_tree(&b, fstree.Op_Set_Flags{inode = ino, mask = fstree.ALL_FLAGS, value = it.flags})
		}
		if it.kind == .Symlink && it.target != ic.target {
			builder_tree(&b, fstree.Op_Set_Target{inode = ino, target = it.target})
		}
		if it.kind == .File && .Opaque in it.flags {
			want_reg, has_want := history_blob_at(h, ino, tl[:]) or_return
			cur_reg, has_cur := history_blob_at(h, ino, cl[:]) or_return
			if has_want && (!has_cur || cur_reg.oid != want_reg.oid) {
				builder_content(&b, ino, odb.Oid(want_reg.oid), want_reg.size)
			}
			continue
		}
		if it.kind != .File {
			continue
		}
		cur, _, cerr := history_text_spans_at(h, ino, cl[:], context.temp_allocator)
		cerr or_return
		want, spans, werr := history_text_spans_at(h, ino, tl[:], context.temp_allocator)
		werr or_return
		edits, derr := textdiff.line_edits(cur, want, context.temp_allocator)
		if derr != nil {
			builder_delete(&b, ino, 0, len(cur))
			builder_copy_spans(&b, ino, 0, spans, 0, len(want))
			continue
		}
		for ed in edits {
			builder_delete(&b, ino, int(ed.pos), int(ed.del))
			builder_copy_spans(&b, ino, int(ed.pos), spans, int(ed.pos), int(ed.ins))
		}
		history_unload_files(h)
	}
	if b.n == 0 {
		return .None
	}
	history_register_actor(h, ractor, pseudo) or_return
	before := make([]crdt.Op_Id, len(m.synced), context.temp_allocator)
	copy(before, m.synced[:])
	if cerr := builder_commit(m, &b); cerr != .None && cerr != .Reloading {
		return cerr
	}
	clear(&m.synced)
	append(&m.synced, ..before)
	if merr := mount_materialize(m); merr != .Reloading {
		return merr
	}
	m.reload_owed = true
	mount_reload_retry(m)
	return .None
}

git_restore :: proc(m: ^Mount, branch: string, commit: string, spawner: Spawner, thread: prim.Id) -> Error {
	if spawner.run == nil {
		return .Unsupported
	}
	head, _ := git_head(m.vfs, m.git, context.temp_allocator)
	if head.commit == commit && head.branch == branch {
		return .None
	}
	use := ""
	if len(branch) > 0 {
		cur, found := git_resolve_ref(m.vfs, m.git, branch, context.temp_allocator)
		if found && cur == commit && !branch_checked_out_elsewhere(m, branch) {
			use = branch
		}
	}
	if len(use) == 0 {
		hex := prim.id_hex(thread)
		base := strings.concatenate({"refs/heads/ondb/", string(hex[:12])}, context.temp_allocator)
		cand := base
		for i := 2; i < 1000; i += 1 {
			_, exists := git_resolve_ref(m.vfs, m.git, cand, context.temp_allocator)
			if !exists {
				break
			}
			digits: [8]u8
			n := 0
			x := i
			for x > 0 {
				digits[7 - n] = u8('0' + x % 10)
				x /= 10
				n += 1
			}
			cand = strings.concatenate({base, "-", string(digits[8 - n:])}, context.temp_allocator)
		}
		rp, _ := path_join(m.git.common, cand, context.temp_allocator)
		from_prim(prim.mkdir_all(m.vfs, path_parent_abs(rp), 0o755)) or_return
		from_prim(prim.replace_atomic(m.vfs, rp, transmute([]u8)strings.concatenate({commit, "\n"}, context.temp_allocator))) or_return
		use = cand
	}
	hp, _ := path_join(m.git.dir, "HEAD", context.temp_allocator)
	from_prim(prim.replace_atomic(m.vfs, hp, transmute([]u8)strings.concatenate({"ref: ", use, "\n"}, context.temp_allocator))) or_return
	argv := []string{"git", "read-tree", commit}
	spawner.run(spawner.data, argv, m.root) or_return
	return mount_sync(m)
}

@(private)
branch_checked_out_elsewhere :: proc(m: ^Mount, branch: string) -> bool {
	wt, _ := path_join(m.git.common, "worktrees", context.temp_allocator)
	d: prim.Dir
	if prim.dir_open(m.vfs, &d, wt, context.temp_allocator) != .None {
		return false
	}
	defer prim.dir_close(m.vfs, &d)
	for {
		e, more, err := prim.dir_next(m.vfs, &d)
		if err != .None || !more {
			return false
		}
		if e.name == "." || e.name == ".." {
			continue
		}
		dir, _ := path_join(wt, e.name, context.temp_allocator)
		if dir == m.git.dir {
			continue
		}
		hp, _ := path_join(dir, "HEAD", context.temp_allocator)
		text, rerr := prim.read_file(m.vfs, hp, context.temp_allocator)
		if rerr == .None && strings.trim_space(string(text)) == strings.concatenate({"ref: ", branch}, context.temp_allocator) {
			return true
		}
	}
}

package fs

import "base:runtime"
import "core:strings"
import "../crdt"
import "../prim"

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

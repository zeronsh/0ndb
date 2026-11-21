package odb

import "base:runtime"
import "core:strings"
import "../prim"

Named_Ref :: struct {
	name: string,
	oid:  Oid,
}

Rewrite :: struct {
	old: Oid,
	new: Oid,
}

Redact_Stats :: struct {
	refs_updated:      int,
	commits_rewritten: int,
	trees_rewritten:   int,
	protected:         int,
	repack:            Repack_Stats,
}

list_refs :: proc(db: ^Odb, allocator := context.allocator) -> (refs: []Named_Ref, err: Error) {
	out := make([dynamic]Named_Ref, allocator)
	defer if err != .None {
		refs_destroy(out[:], allocator)
	}
	seen := make(map[string]struct{}, db.allocator)
	defer {
		for k in seen {
			delete(k, db.allocator)
		}
		delete(seen)
	}
	collect_loose_refs(db, db.common_dir, "refs", &out, &seen, allocator) or_return
	pb: [PATH_MAX]u8
	path := concat_into(pb[:], db.common_dir, "/packed-refs") or_return
	data, rerr := vfs_read_file(db.vfs, path, db.allocator)
	if rerr == .None {
		defer delete(data, db.allocator)
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if len(line) == 0 || line[0] == '#' || line[0] == '^' {
				continue
			}
			sp := strings.index_byte(line, ' ')
			if sp < 0 {
				return nil, .Corrupt
			}
			name := line[sp + 1:]
			if name in seen || !ref_name_valid(name) {
				continue
			}
			oid, format, ok := oid_from_hex(line[:sp])
			if !ok || format != db.format {
				return nil, .Corrupt
			}
			append(&out, Named_Ref{strings.clone(name, allocator), oid})
		}
	} else if rerr != .Not_Found {
		return nil, rerr
	}
	return out[:], .None
}

refs_destroy :: proc(refs: []Named_Ref, allocator := context.allocator) {
	for r in refs {
		delete(r.name, allocator)
	}
	delete(refs, allocator)
}

@(private)
collect_loose_refs :: proc(db: ^Odb, root, rel: string, out: ^[dynamic]Named_Ref, seen: ^map[string]struct{}, allocator: runtime.Allocator) -> Error {
	db_buf: [PATH_MAX]u8
	dir := concat_into(db_buf[:], root, "/", rel) or_return
	d: prim.Dir
	if e := prim.dir_open(db.vfs, &d, dir, db.allocator); e != .None {
		return .None if e == .Not_Found else perr(e)
	}
	defer prim.dir_close(db.vfs, &d)
	for {
		e, ok, derr := prim.dir_next(db.vfs, &d)
		if derr != .None {
			return perr(derr)
		}
		if !ok {
			break
		}
		if e.name == "." || e.name == ".." {
			continue
		}
		nb: [PATH_MAX]u8
		name := concat_into(nb[:], rel, "/", e.name) or_return
		kind := e.kind
		if kind == .Unknown {
			fb: [PATH_MAX]u8
			full := concat_into(fb[:], root, "/", name) or_return
			st, serr := prim.lstat(db.vfs, full)
			if serr != .None {
				continue
			}
			kind = st.kind
		}
		#partial switch kind {
		case .Dir:
			collect_loose_refs(db, root, name, out, seen, allocator) or_return
		case .File:
			if strings.has_suffix(e.name, ".lock") || !ref_name_valid(name) {
				continue
			}
			v: Ref_Value
			read_loose_ref(db, name, &v) or_return
			if !v.found || v.symbolic {
				continue
			}
			owned := strings.clone(name, allocator)
			seen[strings.clone(name, db.allocator)] = {}
			append(out, Named_Ref{owned, v.oid})
		}
	}
	return .None
}

@(private)
Redactor :: struct {
	db:      ^Odb,
	targets: ^map[Oid]struct{},
	trees:   map[Oid]Tree_Result,
	commits: map[Oid]Commit_Result,
	stats:   ^Redact_Stats,
}

@(private)
Tree_Result :: struct {
	oid:   Oid,
	empty: bool,
}

@(private)
Commit_Result :: struct {
	oid:     Oid,
	dropped: bool,
	parents: []Oid,
}

redact :: proc(db: ^Odb, targets: []Oid, ref_prefix := "refs/0ndb/", protect: []Oid = nil, drop_superseded := true, allocator := context.allocator) -> (rewrites: []Rewrite, stats: Redact_Stats, err: Error) {
	if len(targets) == 0 || len(db.dirs) == 0 || !strings.has_prefix(ref_prefix, "refs/") {
		return nil, {}, .Invalid
	}
	a := db.allocator
	target_set := make(map[Oid]struct{}, a)
	defer delete(target_set)
	for t in targets {
		target_set[t] = {}
	}
	refs := list_refs(db, a) or_return
	defer refs_destroy(refs, a)

	r := Redactor{db = db, targets = &target_set, stats = &stats}
	r.trees = make(map[Oid]Tree_Result, a)
	r.commits = make(map[Oid]Commit_Result, a)
	defer redactor_destroy(&r)

	out := make([dynamic]Rewrite, allocator)
	defer if err != .None {
		delete(out)
	}
	Update :: struct {
		name:   string,
		old:    Oid,
		new:    Oid,
		remove: bool,
	}
	updates := make([dynamic]Update, a)
	defer delete(updates)
	for ref in refs {
		if !strings.has_prefix(ref.name, ref_prefix) {
			continue
		}
		res := rewrite_commits(&r, ref.oid) or_return
		if res.dropped {
			if len(res.parents) > 0 {
				append(&updates, Update{ref.name, ref.oid, res.parents[0], false})
			} else {
				append(&updates, Update{ref.name, ref.oid, {}, true})
			}
		} else if res.oid != ref.oid {
			append(&updates, Update{ref.name, ref.oid, res.oid, false})
		}
	}
	for old, res in r.commits {
		if !res.dropped && res.oid != old {
			append(&out, Rewrite{old, res.oid})
		}
	}
	barrier(db) or_return
	for u in updates {
		if u.remove {
			delete_ref(db, u.name, u.old) or_return
		} else {
			update_ref(db, u.name, u.new, u.old) or_return
		}
		stats.refs_updated += 1
	}
	barrier(db) or_return

	reachable := make(map[Oid]struct{}, a)
	defer delete(reachable)
	roots := make([dynamic]Oid, a)
	defer delete(roots)
	append(&roots, ..protect)
	for ref in refs {
		if !strings.has_prefix(ref.name, ref_prefix) {
			append(&roots, ref.oid)
		}
	}
	if head, herr := read_ref(db, "HEAD"); herr == .None {
		append(&roots, head)
	}
	if !db.store {
		collect_reflog_roots(db, &roots) or_return
	}
	mark(db, roots[:], &reachable) or_return
	drop := make(map[Oid]struct{}, a)
	defer delete(drop)
	for t in targets {
		if t in reachable {
			stats.protected += 1
		} else {
			drop[t] = {}
		}
	}
	for old, res in r.commits {
		if drop_superseded && (res.dropped || res.oid != old) && old not_in reachable {
			drop[old] = {}
		}
	}
	for old, res in r.trees {
		if drop_superseded && res.oid != old && old not_in reachable {
			drop[old] = {}
		}
	}
	if len(drop) > 0 {
		filter := Prune_Filter{drop = &drop}
		stats.repack = repack_run(db, DEFAULT_REPACK, &filter) or_return
	}
	return out[:], stats, .None
}

@(private)
redactor_destroy :: proc(r: ^Redactor) {
	for _, res in r.commits {
		delete(res.parents, r.db.allocator)
	}
	delete(r.commits)
	delete(r.trees)
}

@(private)
rewrite_tree :: proc(r: ^Redactor, oid: Oid) -> (res: Tree_Result, err: Error) {
	if cached, ok := r.trees[oid]; ok {
		return cached, .None
	}
	db := r.db
	_, data := read(db, oid, db.allocator) or_return
	defer delete(data, db.allocator)
	entries := make([dynamic]Tree_Entry, db.allocator)
	defer delete(entries)
	changed := false
	it := tree_iter(data, db.format)
	for e in tree_next(&it) {
		if e.oid in r.targets^ {
			changed = true
			continue
		}
		if e.mode == MODE_TREE {
			sub := rewrite_tree(r, e.oid) or_return
			if sub.empty {
				changed = true
				continue
			}
			if sub.oid != e.oid {
				changed = true
				append(&entries, Tree_Entry{e.name, sub.oid, e.mode})
				continue
			}
		}
		append(&entries, e)
	}
	if it.err != .None {
		return {}, it.err
	}
	res = {oid = oid}
	if changed {
		res.empty = len(entries) == 0
		if res.empty {
			res.oid = hash(db.format, .Tree, nil) or_return
		} else {
			res.oid = write_tree(db, entries[:]) or_return
		}
		r.stats.trees_rewritten += 1
	}
	r.trees[oid] = res
	return res, .None
}

@(private)
rewrite_commits :: proc(r: ^Redactor, head: Oid) -> (res: Commit_Result, err: Error) {
	db := r.db
	Frame :: struct {
		oid:      Oid,
		expanded: bool,
	}
	stack := make([dynamic]Frame, db.allocator)
	defer delete(stack)
	append(&stack, Frame{head, false})
	for len(stack) > 0 {
		f := pop(&stack)
		if f.oid in r.commits {
			continue
		}
		t, data, rerr := read(db, f.oid, db.allocator)
		if rerr != .None {
			return {}, rerr
		}
		if t != .Commit {
			delete(data, db.allocator)
			return {}, .Corrupt
		}
		c, derr := commit_decode(data, db.format, db.allocator)
		if derr != .None {
			delete(data, db.allocator)
			return {}, derr
		}
		if !f.expanded {
			append(&stack, Frame{f.oid, true})
			for p in c.parents {
				if p not_in r.commits {
					append(&stack, Frame{p, false})
				}
			}
			commit_destroy(&c, db.allocator)
			delete(data, db.allocator)
			continue
		}
		result, cerr := rewrite_one(r, f.oid, &c)
		commit_destroy(&c, db.allocator)
		delete(data, db.allocator)
		cerr or_return
		r.commits[f.oid] = result
	}
	return r.commits[head], .None
}

@(private)
rewrite_one :: proc(r: ^Redactor, oid: Oid, c: ^Commit) -> (res: Commit_Result, err: Error) {
	db := r.db
	parents := make([dynamic]Oid, db.allocator)
	parents_changed := false
	for p in c.parents {
		pr, ok := r.commits[p]
		if !ok {
			delete(parents)
			return {}, .Corrupt
		}
		if pr.dropped {
			parents_changed = true
			for q in pr.parents {
				append_unique(&parents, q)
			}
			continue
		}
		if pr.oid != p {
			parents_changed = true
		}
		append_unique(&parents, pr.oid)
	}
	if oid in r.targets^ {
		return {oid = oid, dropped = true, parents = parents[:]}, .None
	}
	tree := rewrite_tree(r, c.tree) or_return
	if tree.empty {
		write(db, .Tree, nil) or_return
	}
	if tree.oid == c.tree && !parents_changed {
		delete(parents)
		return {oid = oid}, .None
	}
	nc := c^
	nc.tree = tree.oid
	nc.parents = parents[:]
	new_oid, werr := write_commit(db, nc)
	delete(parents)
	werr or_return
	r.stats.commits_rewritten += 1
	return {oid = new_oid}, .None
}

@(private)
append_unique :: proc(list: ^[dynamic]Oid, oid: Oid) {
	for o in list {
		if o == oid {
			return
		}
	}
	append(list, oid)
}

@(private)
collect_reflog_roots :: proc(db: ^Odb, out: ^[dynamic]Oid) -> Error {
	walk_logs(db, db.common_dir, "logs", out) or_return
	if db.git_dir != db.common_dir {
		walk_logs(db, db.git_dir, "logs", out) or_return
	}
	return .None
}

@(private)
walk_logs :: proc(db: ^Odb, root, rel: string, out: ^[dynamic]Oid) -> Error {
	db_buf: [PATH_MAX]u8
	dir := concat_into(db_buf[:], root, "/", rel) or_return
	d: prim.Dir
	if e := prim.dir_open(db.vfs, &d, dir, db.allocator); e != .None {
		return .None if e == .Not_Found || e == .Not_Dir else perr(e)
	}
	defer prim.dir_close(db.vfs, &d)
	hex_len := oid_size(db.format) * 2
	for {
		e, ok, derr := prim.dir_next(db.vfs, &d)
		if derr != .None {
			return perr(derr)
		}
		if !ok {
			break
		}
		if e.name == "." || e.name == ".." {
			continue
		}
		nb: [PATH_MAX]u8
		name := concat_into(nb[:], rel, "/", e.name) or_return
		fb: [PATH_MAX]u8
		full := concat_into(fb[:], root, "/", name) or_return
		st, serr := prim.lstat(db.vfs, full)
		if serr != .None {
			continue
		}
		if st.kind == .Dir {
			walk_logs(db, root, name, out) or_return
			continue
		}
		if st.kind != .File {
			continue
		}
		data, rerr := vfs_read_file(db.vfs, full, db.allocator)
		if rerr != .None {
			continue
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if len(line) < hex_len * 2 + 1 {
				continue
			}
			for part in ([]string{line[:hex_len], line[hex_len + 1:][:hex_len]}) {
				if oid, format, valid := oid_from_hex(part); valid && format == db.format && oid != ZERO_OID {
					append(out, oid)
				}
			}
		}
		delete(data, db.allocator)
	}
	return .None
}

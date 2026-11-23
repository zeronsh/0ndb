package sim

import "core:fmt"
import "core:slice"
import "core:strings"
import "../../src/fs"
import "../../src/odb"
import "../../src/prim"

Git_File :: struct {
	name: string,
	data: []u8,
}

@(private = "file")
_put32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private = "file")
_write_file :: proc(vfs: prim.Vfs, path: string, data: []u8) -> prim.Error {
	fd := prim.open_file(vfs, path, {.Write, .Create, .Truncate}, 0o644) or_return
	err := prim.write_at(vfs, fd, data, 0)
	if err == .None {
		err = prim.datasync(vfs, fd)
	}
	cerr := prim.close_file(vfs, fd)
	if err == .None {
		err = cerr
	}
	return err
}

git_checkout_create :: proc(vfs: prim.Vfs, root: string, files: []Git_File, when_s: i64, clock: prim.Clock, random: prim.Random, remote := "", pushed: ^[dynamic]odb.Oid = nil) -> prim.Error {
	git := strings.concatenate({root, "/.git"}, context.temp_allocator)
	for d in ([]string{"objects", "refs/heads", "refs/tags", "refs/remotes/origin"}) {
		prim.mkdir_all(vfs, strings.concatenate({git, "/", d}, context.temp_allocator), 0o755) or_return
	}
	_write_file(vfs, strings.concatenate({git, "/HEAD"}, context.temp_allocator), transmute([]u8)string("ref: refs/heads/main\n")) or_return
	config := "[core]\n\trepositoryformatversion = 0\n\tbare = false\n"
	if len(remote) > 0 {
		config = strings.concatenate({config, "[remote \"origin\"]\n\turl = ", remote, "\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"}, context.temp_allocator)
	}
	_write_file(vfs, strings.concatenate({git, "/config"}, context.temp_allocator), transmute([]u8)config) or_return
	db: odb.Odb
	if err := odb.open(&db, vfs, root, nil, context.allocator, clock, random); err != .None {
		return .Io
	}
	defer odb.close(&db)
	sorted := make([]Git_File, len(files), context.temp_allocator)
	copy(sorted, files)
	slice.sort_by(sorted, proc(a, b: Git_File) -> bool {
		return a.name < b.name
	})
	oids := make([]odb.Oid, len(sorted), context.temp_allocator)
	entries := make([]odb.Tree_Entry, len(sorted), context.temp_allocator)
	for f, i in sorted {
		oid, err := odb.write(&db, .Blob, f.data)
		if err != .None {
			return .Io
		}
		oids[i] = oid
		entries[i] = odb.Tree_Entry{name = f.name, oid = oid, mode = 0o100644}
		if pushed != nil {
			append(pushed, oid)
		}
	}
	tree, terr := odb.write_tree(&db, entries)
	if terr != .None {
		return .Io
	}
	sig := odb.Signature{name = "sim", email = "sim@0ndb.invalid", time = when_s}
	body, cerr := odb.commit_encode(odb.Commit{tree = tree, author = sig, committer = sig, message = "initial\n"}, .Sha1, context.temp_allocator)
	if cerr != .None {
		return .Io
	}
	commit, werr := odb.write(&db, .Commit, body)
	if werr != .None {
		return .Io
	}
	if odb.barrier(&db) != .None {
		return .Io
	}
	hb: [odb.MAX_HEX]u8
	hexs := odb.oid_to_string(commit, .Sha1, &hb)
	_write_file(vfs, strings.concatenate({git, "/refs/heads/main"}, context.temp_allocator), transmute([]u8)strings.concatenate({hexs, "\n"}, context.temp_allocator)) or_return
	if len(remote) > 0 {
		_write_file(vfs, strings.concatenate({git, "/refs/remotes/origin/main"}, context.temp_allocator), transmute([]u8)strings.concatenate({hexs, "\n"}, context.temp_allocator)) or_return
		if pushed != nil {
			append(pushed, tree, commit)
		}
		prim.sync_dir(vfs, strings.concatenate({git, "/refs/remotes/origin"}, context.temp_allocator)) or_return
	}
	idx := make([dynamic]u8, context.temp_allocator)
	append(&idx, 'D', 'I', 'R', 'C')
	_put32(&idx, 2)
	_put32(&idx, u32(len(sorted)))
	for f, i in sorted {
		path := strings.concatenate({root, "/", f.name}, context.temp_allocator)
		_write_file(vfs, path, f.data) or_return
		st := prim.stat(vfs, path) or_return
		start := len(idx)
		_put32(&idx, u32(st.ctime_ns / 1_000_000_000))
		_put32(&idx, u32(st.ctime_ns % 1_000_000_000))
		_put32(&idx, u32(st.mtime_ns / 1_000_000_000))
		_put32(&idx, u32(st.mtime_ns % 1_000_000_000))
		_put32(&idx, u32(st.dev))
		_put32(&idx, u32(st.ino))
		_put32(&idx, 0o100644)
		_put32(&idx, 0)
		_put32(&idx, 0)
		_put32(&idx, u32(st.size))
		o := oids[i]
		append(&idx, ..o[:20])
		nl := min(len(f.name), 0xfff)
		append(&idx, u8(nl >> 8), u8(nl))
		append(&idx, ..transmute([]u8)f.name)
		entry := len(idx) - start
		pad := 8 - entry % 8
		for _ in 0 ..< pad {
			append(&idx, 0)
		}
	}
	sum := odb.hash_bytes(.Sha1, idx[:])
	append(&idx, ..sum[:20])
	_write_file(vfs, strings.concatenate({git, "/index"}, context.temp_allocator), idx[:]) or_return
	prim.sync_dir(vfs, git) or_return
	prim.sync_dir(vfs, strings.concatenate({git, "/refs/heads"}, context.temp_allocator)) or_return
	return prim.sync_dir(vfs, root)
}

Git_Change :: struct {
	name: string,
	old:  []u8,
	new:  []u8,
	gone: bool,
}

Git_Checkout_Result :: enum u8 {
	Done,
	Refused,
	Locked,
	Missing,
}

@(private = "file")
Git_Index_Row :: struct {
	oid: odb.Oid,
	raw: []u8,
}

@(private = "file")
_get32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

@(private = "file")
_git_index_rows :: proc(vfs: prim.Vfs, git: string) -> map[string]Git_Index_Row {
	out := make(map[string]Git_Index_Row, context.temp_allocator)
	data, err := prim.read_file(vfs, strings.concatenate({git, "/index"}, context.temp_allocator), context.temp_allocator)
	if err != .None || len(data) < 12 || string(data[:4]) != "DIRC" {
		return out
	}
	n := int(_get32(data[8:12]))
	pos := 12
	for _ in 0 ..< n {
		if pos + 62 > len(data) {
			break
		}
		nl := int(u16(data[pos + 60]) << 8 | u16(data[pos + 61])) & 0xfff
		el := 62 + nl
		size := el + 8 - el % 8
		if pos + size > len(data) {
			break
		}
		row: Git_Index_Row
		copy(row.oid[:20], data[pos + 40:pos + 60])
		row.raw = data[pos:pos + size]
		out[string(data[pos + 62:pos + 62 + nl])] = row
		pos += size
	}
	return out
}

@(private = "file")
_git_index_entry :: proc(idx: ^[dynamic]u8, vfs: prim.Vfs, path: string, name: string, oid: odb.Oid) -> prim.Error {
	st := prim.stat(vfs, path) or_return
	start := len(idx)
	_put32(idx, u32(st.ctime_ns / 1_000_000_000))
	_put32(idx, u32(st.ctime_ns % 1_000_000_000))
	_put32(idx, u32(st.mtime_ns / 1_000_000_000))
	_put32(idx, u32(st.mtime_ns % 1_000_000_000))
	_put32(idx, u32(st.dev))
	_put32(idx, u32(st.ino))
	_put32(idx, 0o100644)
	_put32(idx, 0)
	_put32(idx, 0)
	_put32(idx, u32(st.size))
	o := oid
	append(idx, ..o[:20])
	nl := min(len(name), 0xfff)
	append(idx, u8(nl >> 8), u8(nl))
	append(idx, ..transmute([]u8)name)
	entry := len(idx) - start
	for _ in 0 ..< 8 - entry % 8 {
		append(idx, 0)
	}
	return .None
}

@(private = "file")
_git_tree_files :: proc(db: ^odb.Odb, commit: odb.Oid) -> (files: map[string]odb.Oid, ok: bool) {
	files = make(map[string]odb.Oid, context.temp_allocator)
	t, data, err := odb.read(db, commit, context.temp_allocator)
	if err != .None || t != .Commit {
		return
	}
	c, cerr := odb.commit_decode(data, .Sha1, context.temp_allocator)
	if cerr != .None {
		return
	}
	tt, tdata, terr := odb.read(db, c.tree, context.temp_allocator)
	if terr != .None || tt != .Tree {
		return
	}
	entries, derr := odb.tree_decode(tdata, .Sha1, context.temp_allocator)
	if derr != .None {
		return
	}
	for e in entries {
		files[e.name] = e.oid
	}
	return files, true
}

git_branch_files :: proc(n: ^Node, vfs: prim.Vfs, root, branch: string) -> (files: map[string][]u8, ok: bool) {
	git := strings.concatenate({root, "/.git"}, context.temp_allocator)
	commit, cok := _git_ref_commit(vfs, git, strings.concatenate({"refs/heads/", branch}, context.temp_allocator))
	if !cok {
		return
	}
	db: odb.Odb
	if odb.open(&db, vfs, root, nil, context.allocator, node_clock(&n.clock), rng_random(&n.rng)) != .None {
		return
	}
	defer odb.close(&db)
	oids, tok := _git_tree_files(&db, commit)
	if !tok {
		return
	}
	files = make(map[string][]u8, context.temp_allocator)
	for name, oid in oids {
		t, data, err := odb.read(&db, oid, context.temp_allocator)
		if err != .None || t != .Blob {
			return
		}
		files[name] = data
	}
	return files, true
}

@(private = "file")
_git_ref_commit :: proc(vfs: prim.Vfs, git: string, ref: string) -> (oid: odb.Oid, ok: bool) {
	data, err := prim.read_file(vfs, strings.concatenate({git, "/", ref}, context.temp_allocator), context.temp_allocator)
	if err != .None {
		return
	}
	o, _, hok := odb.oid_from_hex(strings.trim_space(string(data)))
	return o, hok
}

@(private = "file")
_git_head_ref :: proc(vfs: prim.Vfs, git: string) -> (ref: string, ok: bool) {
	data, err := prim.read_file(vfs, strings.concatenate({git, "/HEAD"}, context.temp_allocator), context.temp_allocator)
	if err != .None {
		return
	}
	s := strings.trim_space(string(data))
	if !strings.has_prefix(s, "ref:") {
		return
	}
	return strings.trim_space(s[4:]), true
}

@(private = "file")
_git_hex :: proc(oid: odb.Oid) -> string {
	hb: [odb.MAX_HEX]u8
	return strings.clone(odb.oid_to_string(oid, .Sha1, &hb), context.temp_allocator)
}

git_branch_commit :: proc(vfs: prim.Vfs, root: string, branch: string, files: []Git_File, removed: []string, when_s: i64, clock: prim.Clock, random: prim.Random, pushed: ^[dynamic]odb.Oid = nil) -> prim.Error {
	git := strings.concatenate({root, "/.git"}, context.temp_allocator)
	ref, rok := _git_head_ref(vfs, git)
	if !rok {
		return .Not_Found
	}
	head, hok := _git_ref_commit(vfs, git, ref)
	if !hok {
		return .Not_Found
	}
	db: odb.Odb
	if err := odb.open(&db, vfs, root, nil, context.allocator, clock, random); err != .None {
		return .Io
	}
	defer odb.close(&db)
	base, bok := _git_tree_files(&db, head)
	if !bok {
		return .Io
	}
	for r in removed {
		delete_key(&base, r)
	}
	for f in files {
		oid, err := odb.write(&db, .Blob, f.data)
		if err != .None {
			return .Io
		}
		base[f.name] = oid
		if pushed != nil {
			append(pushed, oid)
		}
	}
	entries := make([dynamic]odb.Tree_Entry, context.temp_allocator)
	for name, oid in base {
		append(&entries, odb.Tree_Entry{name = name, oid = oid, mode = 0o100644})
	}
	slice.sort_by(entries[:], proc(a, b: odb.Tree_Entry) -> bool {
		return a.name < b.name
	})
	tree, terr := odb.write_tree(&db, entries[:])
	if terr != .None {
		return .Io
	}
	sig := odb.Signature{name = "sim", email = "sim@0ndb.invalid", time = when_s}
	parents := [1]odb.Oid{head}
	body, cerr := odb.commit_encode(odb.Commit{tree = tree, parents = parents[:], author = sig, committer = sig, message = strings.concatenate({branch, "\n"}, context.temp_allocator)}, .Sha1, context.temp_allocator)
	if cerr != .None {
		return .Io
	}
	commit, werr := odb.write(&db, .Commit, body)
	if werr != .None {
		return .Io
	}
	if pushed != nil {
		append(pushed, tree, commit)
	}
	if odb.barrier(&db) != .None {
		return .Io
	}
	_write_file(vfs, strings.concatenate({git, "/refs/heads/", branch}, context.temp_allocator), transmute([]u8)strings.concatenate({_git_hex(commit), "\n"}, context.temp_allocator)) or_return
	return prim.sync_dir(vfs, strings.concatenate({git, "/refs/heads"}, context.temp_allocator))
}

git_checkout :: proc(vfs: prim.Vfs, root: string, branch: string, force: bool, when_s: i64, clock: prim.Clock, random: prim.Random, changes: ^[dynamic]Git_Change) -> (res: Git_Checkout_Result, err: prim.Error) {
	git := strings.concatenate({root, "/.git"}, context.temp_allocator)
	lock := strings.concatenate({git, "/index.lock"}, context.temp_allocator)
	cur_ref, rok := _git_head_ref(vfs, git)
	target_ref := strings.concatenate({"refs/heads/", branch}, context.temp_allocator)
	cur, cok := _git_ref_commit(vfs, git, cur_ref)
	target, tok := _git_ref_commit(vfs, git, target_ref)
	if !rok || !cok || !tok {
		return .Missing, .None
	}
	db: odb.Odb
	if oerr := odb.open(&db, vfs, root, nil, context.allocator, clock, random); oerr != .None {
		return .Missing, .Io
	}
	defer odb.close(&db)
	old_files, ook := _git_tree_files(&db, cur)
	new_files, nok := _git_tree_files(&db, target)
	if !ook || !nok {
		return .Missing, .Io
	}
	lfd, lerr := prim.open_file(vfs, lock, {.Write, .Create, .Exclusive}, 0o644)
	if lerr == .Exists {
		return .Locked, .None
	}
	if lerr != .None {
		return .Missing, lerr
	}
	prim.close_file(vfs, lfd) or_return
	rows := _git_index_rows(vfs, git)
	names := make([dynamic]string, context.temp_allocator)
	for k in old_files {
		append(&names, k)
	}
	for k in new_files {
		if k not_in old_files {
			append(&names, k)
		}
	}
	slice.sort(names[:])
	for name in names {
		path := strings.concatenate({root, "/", name}, context.temp_allocator)
		data, derr := prim.read_file(vfs, path, context.temp_allocator)
		on_disk := derr == .None
		if derr != .None && derr != .Not_Found {
			prim.remove(vfs, lock)
			return .Missing, derr
		}
		row, indexed := rows[name]
		dirty := false
		if on_disk {
			h, herr := odb.hash(.Sha1, .Blob, data)
			if herr != .None {
				prim.remove(vfs, lock)
				return .Missing, .Io
			}
			dirty = !indexed || h != row.oid
		} else {
			dirty = indexed
		}
		o, in_old := old_files[name]
		nw, in_new := new_files[name]
		moves := in_old != in_new || o != nw
		if dirty && !force && moves {
			clear(changes)
			prim.remove(vfs, lock)
			return .Refused, .None
		}
		if moves || (force && dirty) {
			c := Git_Change{name = name, old = data if on_disk else nil, gone = !in_new}
			if in_new {
				_, blob, berr := odb.read(&db, nw, context.temp_allocator)
				if berr != .None {
					prim.remove(vfs, lock)
					return .Missing, .Io
				}
				c.new = blob
			}
			append(changes, c)
		}
	}
	for c in changes {
		if c.gone {
			path := strings.concatenate({root, "/", c.name}, context.temp_allocator)
			if rerr := prim.remove(vfs, path); rerr != .None && rerr != .Not_Found {
				return .Done, rerr
			}
		}
	}
	for c in changes {
		if !c.gone {
			path := strings.concatenate({root, "/", c.name}, context.temp_allocator)
			if rerr := prim.remove(vfs, path); rerr != .None && rerr != .Not_Found {
				return .Done, rerr
			}
			_write_file(vfs, path, c.new) or_return
		}
	}
	written := make(map[string]bool, context.temp_allocator)
	for c in changes {
		written[c.name] = true
	}
	kept := make([dynamic]string, context.temp_allocator)
	for k in new_files {
		append(&kept, k)
	}
	slice.sort(kept[:])
	idx := make([dynamic]u8, context.temp_allocator)
	append(&idx, 'D', 'I', 'R', 'C')
	_put32(&idx, 2)
	_put32(&idx, u32(len(kept)))
	for name in kept {
		row, indexed := rows[name]
		if indexed && !written[name] && row.oid == new_files[name] {
			append(&idx, ..row.raw)
			continue
		}
		_git_index_entry(&idx, vfs, strings.concatenate({root, "/", name}, context.temp_allocator), name, new_files[name]) or_return
	}
	sum := odb.hash_bytes(.Sha1, idx[:])
	append(&idx, ..sum[:20])
	_write_file(vfs, lock, idx[:]) or_return
	prim.rename(vfs, lock, strings.concatenate({git, "/index"}, context.temp_allocator)) or_return
	head_lock := strings.concatenate({git, "/HEAD.lock"}, context.temp_allocator)
	_write_file(vfs, head_lock, transmute([]u8)strings.concatenate({"ref: ", target_ref, "\n"}, context.temp_allocator)) or_return
	prim.mkdir_all(vfs, strings.concatenate({git, "/logs"}, context.temp_allocator), 0o755) or_return
	from := cur_ref[len("refs/heads/"):] if strings.has_prefix(cur_ref, "refs/heads/") else cur_ref
	line := fmt.tprintf("%s %s sim <sim@0ndb.invalid> %d +0000\tcheckout: moving from %s to %s\n", _git_hex(cur), _git_hex(target), when_s, from, branch)
	rfd := prim.open_file(vfs, strings.concatenate({git, "/logs/HEAD"}, context.temp_allocator), {.Write, .Create, .Append}, 0o644) or_return
	werr := prim.write_at(vfs, rfd, transmute([]u8)line, 0)
	if werr == .None {
		werr = prim.datasync(vfs, rfd)
	}
	cerr := prim.close_file(vfs, rfd)
	werr = werr if werr != .None else cerr
	if werr != .None {
		return .Done, werr
	}
	prim.rename(vfs, head_lock, strings.concatenate({git, "/HEAD"}, context.temp_allocator)) or_return
	prim.sync_dir(vfs, git) or_return
	return .Done, prim.sync_dir(vfs, root)
}

git_dirty_paths :: proc(vfs: prim.Vfs, root: string) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	rows := _git_index_rows(vfs, strings.concatenate({root, "/.git"}, context.temp_allocator))
	paths := TREE_PATHS
	for p in paths {
		data, err := prim.read_file(vfs, strings.concatenate({root, "/", p}, context.temp_allocator), context.temp_allocator)
		row, indexed := rows[p]
		if err != .None {
			out[p] = indexed
			continue
		}
		h, herr := odb.hash(.Sha1, .Blob, data)
		out[p] = herr != .None || !indexed || h != row.oid
	}
	return out
}

git_head_line :: proc(vfs: prim.Vfs, root: string) -> string {
	git := strings.concatenate({root, "/.git"}, context.temp_allocator)
	data, err := prim.read_file(vfs, strings.concatenate({git, "/HEAD"}, context.temp_allocator), context.temp_allocator)
	if err != .None {
		return ""
	}
	s := strings.trim_space(string(data))
	if !strings.has_prefix(s, "ref:") {
		return strings.concatenate({"git:detached:", s}, context.temp_allocator)
	}
	ref := strings.trim_space(s[4:])
	if ref == "refs/heads/main" {
		return ""
	}
	return strings.concatenate({"git:", ref}, context.temp_allocator)
}

git_branches_other :: proc(vfs: prim.Vfs, root: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	git := strings.concatenate({root, "/.git"}, context.temp_allocator)
	cur, _ := _git_head_ref(vfs, git)
	d: prim.Dir
	d.allocator = context.temp_allocator
	if prim.dir_open(vfs, &d, strings.concatenate({git, "/refs/heads"}, context.temp_allocator), context.temp_allocator) != .None {
		return out[:]
	}
	defer prim.dir_close(vfs, &d)
	for {
		de, more, err := prim.dir_next(vfs, &d)
		if err != .None || !more {
			break
		}
		if de.name == "." || de.name == ".." || strings.concatenate({"refs/heads/", de.name}, context.temp_allocator) == cur {
			continue
		}
		append(&out, strings.clone(de.name, context.temp_allocator))
	}
	slice.sort(out[:])
	return out[:]
}

sim_git_spawner :: proc(n: ^Node) -> fs.Spawner {
	return fs.Spawner{data = n, run = _sgs_run}
}

@(private = "file")
_sgs_run :: proc(data: rawptr, argv: []string, cwd: string) -> fs.Error {
	n := (^Node)(data)
	if len(argv) < 2 || argv[0] != "git" {
		return .Unsupported
	}
	vfs := disk_vfs(&n.disk)
	git := strings.concatenate({cwd, "/.git"}, context.temp_allocator)
	switch argv[1] {
	case "read-tree":
		if len(argv) != 3 {
			return .Invalid
		}
		return .None if _sgs_read_tree(n, vfs, cwd, git, argv[2]) == .None else .Io
	case "update-index":
		return .None
	case "symbolic-ref", "update-ref":
		msg, target: string
		for i := 2; i < len(argv); i += 1 {
			if argv[i] == "-m" && i + 1 < len(argv) {
				msg = argv[i + 1]
				i += 1
			} else if argv[i] != "--no-deref" && argv[i] != "HEAD" {
				target = argv[i]
			}
		}
		if len(target) == 0 {
			return .Invalid
		}
		return .None if _sgs_set_head(n, vfs, git, target, argv[1] == "symbolic-ref", msg) == .None else .Io
	}
	return .Unsupported
}

@(private = "file")
_sgs_read_tree :: proc(n: ^Node, vfs: prim.Vfs, root, git, hex: string) -> prim.Error {
	commit, _, ok := odb.oid_from_hex(hex)
	if !ok {
		return .Invalid
	}
	db: odb.Odb
	if odb.open(&db, vfs, root, nil, context.allocator, node_clock(&n.clock), rng_random(&n.rng)) != .None {
		return .Io
	}
	defer odb.close(&db)
	files, fok := _git_tree_files(&db, commit)
	if !fok {
		return .Io
	}
	lock := strings.concatenate({git, "/index.lock"}, context.temp_allocator)
	lfd := prim.open_file(vfs, lock, {.Write, .Create, .Exclusive}, 0o644) or_return
	prim.close_file(vfs, lfd) or_return
	names := make([dynamic]string, context.temp_allocator)
	for k in files {
		append(&names, k)
	}
	slice.sort(names[:])
	idx := make([dynamic]u8, context.temp_allocator)
	append(&idx, 'D', 'I', 'R', 'C')
	_put32(&idx, 2)
	_put32(&idx, u32(len(names)))
	for name in names {
		path := strings.concatenate({root, "/", name}, context.temp_allocator)
		oid := files[name]
		data, derr := prim.read_file(vfs, path, context.temp_allocator)
		clean := false
		if derr == .None {
			h, herr := odb.hash(.Sha1, .Blob, data)
			clean = herr == .None && h == oid
		}
		if clean {
			if err := _git_index_entry(&idx, vfs, path, name, oid); err != .None {
				prim.remove(vfs, lock)
				return err
			}
			continue
		}
		start := len(idx)
		for _ in 0 ..< 6 {
			_put32(&idx, 0)
		}
		_put32(&idx, 0o100644)
		_put32(&idx, 0)
		_put32(&idx, 0)
		_put32(&idx, 0)
		o := oid
		append(&idx, ..o[:20])
		nl := min(len(name), 0xfff)
		append(&idx, u8(nl >> 8), u8(nl))
		append(&idx, ..transmute([]u8)name)
		entry := len(idx) - start
		for _ in 0 ..< 8 - entry % 8 {
			append(&idx, 0)
		}
	}
	sum := odb.hash_bytes(.Sha1, idx[:])
	append(&idx, ..sum[:20])
	_write_file(vfs, lock, idx[:]) or_return
	return prim.rename(vfs, lock, strings.concatenate({git, "/index"}, context.temp_allocator))
}

@(private = "file")
_sgs_set_head :: proc(n: ^Node, vfs: prim.Vfs, git, target: string, symbolic: bool, msg: string) -> prim.Error {
	old_hex := "0000000000000000000000000000000000000000"
	if ref, ok := _git_head_ref(vfs, git); ok {
		if c, cok := _git_ref_commit(vfs, git, ref); cok {
			old_hex = _git_hex(c)
		}
	} else if data, err := prim.read_file(vfs, strings.concatenate({git, "/HEAD"}, context.temp_allocator), context.temp_allocator); err == .None {
		old_hex = strings.trim_space(string(data))
	}
	new_hex := target
	body := strings.concatenate({target, "\n"}, context.temp_allocator)
	if symbolic {
		c, ok := _git_ref_commit(vfs, git, target)
		if !ok {
			return .Not_Found
		}
		new_hex = _git_hex(c)
		body = strings.concatenate({"ref: ", target, "\n"}, context.temp_allocator)
	}
	head_lock := strings.concatenate({git, "/HEAD.lock"}, context.temp_allocator)
	_write_file(vfs, head_lock, transmute([]u8)body) or_return
	prim.mkdir_all(vfs, strings.concatenate({git, "/logs"}, context.temp_allocator), 0o755) or_return
	when_s := clock_wall(&n.clock) / 1_000_000_000
	line := fmt.tprintf("%s %s sim <sim@0ndb.invalid> %d +0000\t%s\n", old_hex, new_hex, when_s, msg)
	rfd := prim.open_file(vfs, strings.concatenate({git, "/logs/HEAD"}, context.temp_allocator), {.Write, .Create, .Append}, 0o644) or_return
	werr := prim.write_at(vfs, rfd, transmute([]u8)line, 0)
	if werr == .None {
		werr = prim.datasync(vfs, rfd)
	}
	cerr := prim.close_file(vfs, rfd)
	if werr != .None {
		return werr
	}
	cerr or_return
	prim.rename(vfs, head_lock, strings.concatenate({git, "/HEAD"}, context.temp_allocator)) or_return
	return prim.sync_dir(vfs, git)
}

git_index_oids :: proc(vfs: prim.Vfs, root: string) -> map[string]odb.Oid {
	out := make(map[string]odb.Oid, context.temp_allocator)
	for k, v in _git_index_rows(vfs, strings.concatenate({root, "/.git"}, context.temp_allocator)) {
		out[k] = v.oid
	}
	return out
}

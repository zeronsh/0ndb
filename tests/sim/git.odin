package sim

import "core:slice"
import "core:strings"
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

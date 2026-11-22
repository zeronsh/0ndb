package odb

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "../prim"

@(private)
track :: proc(db: ^Odb, file: string, dirs: ..string) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	track_locked(db, file, ..dirs)
}

@(private)
track_locked :: proc(db: ^Odb, file: string, dirs: ..string) {
	a := db.allocator
	if file != "" {
		if s, err := strings.clone(file, a); err == nil {
			append(&db.pending_files, s)
		}
	}
	for d in dirs {
		if d == "" {
			continue
		}
		if s, err := strings.clone(d, a); err == nil {
			append(&db.pending_dirs, s)
		}
	}
}

@(private)
track_tree :: proc(db: ^Odb, file: string, base: string, created: bool) {
	dir := parent_dir(file)
	if !created {
		track(db, file, dir)
		return
	}
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	track_locked(db, file, dir)
	for len(dir) > len(base) && strings.has_prefix(dir, base) {
		dir = parent_dir(dir)
		track_locked(db, "", dir)
	}
}

barrier :: proc(db: ^Odb) -> Error {
	sync.mutex_lock(&db.mutex)
	files := db.pending_files
	dirs := db.pending_dirs
	db.pending_files = make([dynamic]string, db.allocator)
	db.pending_dirs = make([dynamic]string, db.allocator)
	sync.mutex_unlock(&db.mutex)
	if len(files) == 0 && len(dirs) == 0 {
		delete(files)
		delete(dirs)
		return .None
	}
	slice.sort(files[:])
	slice.sort(dirs[:])
	uf := distinct_sorted(files[:], db.allocator)
	ud := distinct_sorted(dirs[:], db.allocator)
	defer delete(uf, db.allocator)
	defer delete(ud, db.allocator)
	roots := [2]string{primary_dir(db), db.common_dir}
	err := sync_paths(db, uf, ud, roots[:])
	if err != .None {
		sync.mutex_lock(&db.mutex)
		for f in uf {
			if is_loose_object(db, f) {
				prim.remove(db.vfs, f)
				track_locked(db, "", parent_dir(f))
				continue
			}
			track_locked(db, f)
		}
		for d in ud {
			track_locked(db, "", d)
		}
		sync.mutex_unlock(&db.mutex)
	}
	for s in files {
		delete(s, db.allocator)
	}
	for s in dirs {
		delete(s, db.allocator)
	}
	delete(files)
	delete(dirs)
	return err
}

@(private)
is_loose_object :: proc(db: ^Odb, path: string) -> bool {
	n := oid_size(db.format) * 2
	for d in db.dirs {
		if len(path) != len(d.path) + n + 2 || !strings.has_prefix(path, d.path) || path[len(d.path)] != '/' {
			continue
		}
		rest := path[len(d.path) + 1:]
		if rest[2] != '/' {
			continue
		}
		hex := true
		for c, k in transmute([]u8)rest {
			if k != 2 && !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				hex = false
				break
			}
		}
		if hex {
			return true
		}
	}
	return false
}

@(private)
distinct_sorted :: proc(list: []string, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, 0, len(list), allocator)
	for v, i in list {
		if i == 0 || v != list[i - 1] {
			append(&out, v)
		}
	}
	return out[:]
}

pending_count :: proc(db: ^Odb) -> int {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	return len(db.pending_files) + len(db.pending_dirs)
}

@(private)
pending_clear :: proc(db: ^Odb) {
	for s in db.pending_files {
		delete(s, db.allocator)
	}
	for s in db.pending_dirs {
		delete(s, db.allocator)
	}
	delete(db.pending_files)
	delete(db.pending_dirs)
	db.pending_files = nil
	db.pending_dirs = nil
}

@(private)
SYNCFS_THRESHOLD :: 128

@(private)
sync_one :: proc(db: ^Odb, path: string, dir: bool, data_only: bool) -> (fd: prim.Fd, kept: bool, err: Error) {
	flags := prim.Open_Flags{.Directory} if dir else prim.Open_Flags{}
	f, e := prim.open_file(db.vfs, path, flags)
	if e == .Not_Found {
		return prim.INVALID_FD, false, .None
	}
	if e != .None {
		return prim.INVALID_FD, false, perr(e)
	}
	se := prim.datasync(db.vfs, f) if data_only else prim.fullsync(db.vfs, f)
	if se != .None && !(dir && se == .Invalid) {
		prim.close_file(db.vfs, f)
		return prim.INVALID_FD, false, perr(se)
	}
	return f, true, .None
}

@(private)
sync_paths :: proc(db: ^Odb, files, dirs: []string, roots: []string) -> Error {
	when ODIN_OS == .Windows {
		if vfs_is_os(db.vfs) && len(files) + len(dirs) > 1 && writeout_batch(db, files, dirs, roots) == .None {
			return .None
		}
	}
	if HAS_SYNCFS && vfs_is_os(db.vfs) && len(files) + len(dirs) > SYNCFS_THRESHOLD {
		done := 0
		for r in roots {
			if r == "" {
				continue
			}
			fd, e := prim.open_file(db.vfs, r, {.Directory})
			if e != .None {
				continue
			}
			ok := os_syncfs(fd)
			prim.close_file(db.vfs, fd)
			if !ok {
				return .Io
			}
			done += 1
		}
		if done > 0 {
			return .None
		}
	}
	darwin_batch := ODIN_OS == .Darwin && vfs_is_os(db.vfs)
	last := prim.INVALID_FD
	defer if last != prim.INVALID_FD {
		prim.close_file(db.vfs, last)
	}
	for list, li in ([][]string{files, dirs}) {
		for p in list {
			data_only := li == 0 && !darwin_batch
			fd, kept := sync_one(db, p, li == 1, data_only) or_return
			if !kept {
				continue
			}
			if last != prim.INVALID_FD {
				prim.close_file(db.vfs, last)
			}
			last = fd
		}
	}
	if darwin_batch {
		if last == prim.INVALID_FD {
			for r in roots {
				if r == "" {
					continue
				}
				fd, e := prim.open_file(db.vfs, r, {.Directory})
				if e == .None {
					last = fd
					break
				}
			}
		}
		if last != prim.INVALID_FD {
			perr(prim.datasync(db.vfs, last)) or_return
		}
	}
	return .None
}

@(private)
writeout_batch :: proc(db: ^Odb, files, dirs: []string, roots: []string) -> Error {
	for list, li in ([][]string{files, dirs}) {
		for p in list {
			flags := prim.Open_Flags{.Directory} if li == 1 else prim.Open_Flags{}
			fd, e := prim.open_file(db.vfs, p, flags)
			if e == .Not_Found {
				continue
			}
			if e != .None {
				return perr(e)
			}
			we := prim.writeout(db.vfs, fd)
			prim.close_file(db.vfs, fd)
			if we != .None && !(li == 1 && (we == .Invalid || we == .Unsupported)) {
				return perr(we)
			}
		}
	}
	root := ""
	for r in roots {
		if r != "" {
			root = r
			break
		}
	}
	if root == "" {
		return .Invalid
	}
	buf: [PATH_MAX]u8
	fd, path := create_temp(db, root, ".barrier_", buf[:]) or_return
	err := perr(prim.fullsync(db.vfs, fd))
	prim.close_file(db.vfs, fd)
	prim.remove(db.vfs, path)
	return err
}

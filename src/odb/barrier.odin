package odb

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"

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
	err := sync_paths(uf, ud, roots[:])
	if err != .None {
		sync.mutex_lock(&db.mutex)
		for f in uf {
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
open_for_sync :: proc(path: string) -> (^os.File, Error) {
	f, err := os.open(path)
	if err != nil {
		return nil, .Not_Found if err == .Not_Exist else .Io
	}
	return f, .None
}

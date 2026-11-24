package odb

import "core:strings"
import "core:sync"
import "../prim"

@(private)
SCRUB_FILE :: "/info/0ndb-scrub"

@(private)
Scrub_Intent :: struct {
	targets:    map[Oid]struct{},
	protect:    map[Oid]struct{},
	superseded: map[Oid]struct{},
}

@(private)
scrub_init :: proc(db: ^Odb, it: ^Scrub_Intent) {
	it.targets = make(map[Oid]struct{}, db.allocator)
	it.protect = make(map[Oid]struct{}, db.allocator)
	it.superseded = make(map[Oid]struct{}, db.allocator)
}

@(private)
scrub_destroy :: proc(it: ^Scrub_Intent) {
	delete(it.targets)
	delete(it.protect)
	delete(it.superseded)
}

@(private)
scrub_read :: proc(db: ^Odb, it: ^Scrub_Intent) -> (found: bool, err: Error) {
	pb: [PATH_MAX]u8
	path := concat_into(pb[:], db.dirs[0].path, SCRUB_FILE) or_return
	data, rerr := vfs_read_file(db.vfs, path, db.allocator)
	if rerr == .Not_Found {
		return false, .None
	}
	rerr or_return
	defer delete(data, db.allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 {
			continue
		}
		if len(line) < 3 || line[1] != ' ' {
			return true, .Corrupt
		}
		oid, format, ok := oid_from_hex(line[2:])
		if !ok || format != db.format {
			return true, .Corrupt
		}
		switch line[0] {
		case 't':
			it.targets[oid] = {}
		case 'p':
			it.protect[oid] = {}
		case 's':
			it.superseded[oid] = {}
		case:
			return true, .Corrupt
		}
	}
	return true, .None
}

scrub_targets :: proc(db: ^Odb, allocator := context.allocator) -> (out: []Oid, err: Error) {
	if len(db.dirs) == 0 {
		return nil, .None
	}
	sync.mutex_lock(&db.scrub_mutex)
	defer sync.mutex_unlock(&db.scrub_mutex)
	it: Scrub_Intent
	scrub_init(db, &it)
	defer scrub_destroy(&it)
	if _, rerr := scrub_read(db, &it); rerr != .None {
		return nil, rerr
	}
	res := make([dynamic]Oid, 0, len(it.targets), allocator)
	for o in prim.sorted_keys(it.targets) {
		append(&res, o)
	}
	return res[:], .None
}

scrub_targeted :: proc(db: ^Odb, oid: Oid) -> bool {
	if !scrub_pending(db) {
		return false
	}
	list, err := scrub_targets(db, context.temp_allocator)
	if err != .None {
		return true
	}
	for o in list {
		if o == oid {
			return true
		}
	}
	return false
}

scrub_pending :: proc(db: ^Odb) -> bool {
	if len(db.dirs) == 0 {
		return false
	}
	pb: [PATH_MAX]u8
	path, err := concat_into(pb[:], db.dirs[0].path, SCRUB_FILE)
	return err == .None && prim.exists(db.vfs, path)
}


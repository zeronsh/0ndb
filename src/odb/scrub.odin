package odb

import "base:runtime"
import "core:strings"
import "core:sync"
import "../prim"

@(private)
SCRUB_FILE :: "/info/0ndb-scrub"

Scrub_Hook :: struct {
	data: rawptr,
	call: proc(data: rawptr, targets: []Oid),
}

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
scrub_empty :: proc(it: ^Scrub_Intent) -> bool {
	return len(it.targets) == 0 && len(it.protect) == 0 && len(it.superseded) == 0
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

@(private)
scrub_write :: proc(db: ^Odb, it: ^Scrub_Intent, existed: bool) -> Error {
	pb: [PATH_MAX]u8
	path := concat_into(pb[:], db.dirs[0].path, SCRUB_FILE) or_return
	if scrub_empty(it) {
		if !existed {
			return .None
		}
		if e := prim.remove(db.vfs, path); e != .None && e != .Not_Found {
			return perr(e)
		}
		track(db, "", parent_dir(path))
		return barrier(db)
	}
	if e := prim.mkdir_all(db.vfs, parent_dir(path)); e != .None {
		return perr(e)
	}
	b := strings.builder_make(db.allocator)
	defer strings.builder_destroy(&b)
	hb: [MAX_HEX]u8
	kinds := [3]u8{'t', 'p', 's'}
	sets := [3]^map[Oid]struct{}{&it.targets, &it.protect, &it.superseded}
	for set, i in sets {
		for oid in set^ {
			strings.write_byte(&b, kinds[i])
			strings.write_byte(&b, ' ')
			strings.write_string(&b, oid_to_string(oid, db.format, &hb))
			strings.write_byte(&b, '\n')
		}
	}
	write_atomic(db, path, b.buf[:]) or_return
	return barrier(db)
}

scrub_note :: proc(db: ^Odb, targets: []Oid, protect: []Oid = nil, superseded: []Oid = nil) -> Error {
	if len(db.dirs) == 0 {
		return .Invalid
	}
	if len(targets) == 0 && len(protect) == 0 && len(superseded) == 0 {
		return .None
	}
	sync.mutex_lock(&db.scrub_mutex)
	defer sync.mutex_unlock(&db.scrub_mutex)
	it: Scrub_Intent
	scrub_init(db, &it)
	defer scrub_destroy(&it)
	existed := scrub_read(db, &it) or_return
	n := len(it.targets) + len(it.protect) + len(it.superseded)
	for o in targets {
		it.targets[o] = {}
	}
	for o in protect {
		it.protect[o] = {}
	}
	for o in superseded {
		it.superseded[o] = {}
	}
	if !existed || len(it.targets) + len(it.protect) + len(it.superseded) != n {
		scrub_write(db, &it, existed) or_return
	}
	if db.scrub_hook.call != nil && len(targets) > 0 {
		db.scrub_hook.call(db.scrub_hook.data, targets)
	}
	return .None
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

@(private)
scrub_done :: proc(db: ^Odb, targets: []Oid, protect: []Oid, superseded: []Oid) -> Error {
	sync.mutex_lock(&db.scrub_mutex)
	defer sync.mutex_unlock(&db.scrub_mutex)
	it: Scrub_Intent
	scrub_init(db, &it)
	defer scrub_destroy(&it)
	existed := scrub_read(db, &it) or_return
	if !existed {
		return .None
	}
	for o in targets {
		delete_key(&it.targets, o)
	}
	for o in protect {
		delete_key(&it.protect, o)
	}
	for o in superseded {
		delete_key(&it.superseded, o)
	}
	return scrub_write(db, &it, true)
}

scrub_pending :: proc(db: ^Odb) -> bool {
	if len(db.dirs) == 0 {
		return false
	}
	pb: [PATH_MAX]u8
	path, err := concat_into(pb[:], db.dirs[0].path, SCRUB_FILE)
	return err == .None && prim.exists(db.vfs, path)
}

scrub_resume :: proc(db: ^Odb, allocator := context.allocator) -> (stats: Redact_Stats, err: Error) {
	if len(db.dirs) == 0 {
		return {}, .Invalid
	}
	it: Scrub_Intent
	scrub_init(db, &it)
	defer scrub_destroy(&it)
	sync.mutex_lock(&db.scrub_mutex)
	found, rerr := scrub_read(db, &it)
	sync.mutex_unlock(&db.scrub_mutex)
	rerr or_return
	if !found {
		return {}, .None
	}
	targets := make([dynamic]Oid, db.allocator)
	protect := make([dynamic]Oid, db.allocator)
	superseded := make([dynamic]Oid, db.allocator)
	defer delete(targets)
	defer delete(protect)
	defer delete(superseded)
	for o in prim.sorted_keys(it.targets) {
		append(&targets, o)
	}
	for o in prim.sorted_keys(it.protect) {
		append(&protect, o)
	}
	for o in prim.sorted_keys(it.superseded) {
		append(&superseded, o)
	}
	if len(targets) == 0 && len(superseded) == 0 {
		return {}, scrub_done(db, nil, protect[:], nil)
	}
	rewrites: []Rewrite
	rewrites, stats, err = redact_run(db, targets[:], "refs/0ndb/", protect[:], true, superseded[:], allocator)
	delete(rewrites, allocator)
	return
}

@(private)
scrub_left :: proc(db: ^Odb, oid: Oid) -> (left: bool, pinned: string) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	buf: [PATH_MAX]u8
	for &d in db.dirs {
		if d.extra {
			continue
		}
		d.scanned = false
		scan_packs(db, &d)
		for p in d.packs {
			if _, ok := pack_find(p, oid); !ok {
				continue
			}
			kb, rb: [PATH_MAX]u8
			keep, kerr := concat_into(kb[:], p.base, ".keep")
			prom, perr2 := concat_into(rb[:], p.base, ".promisor")
			if (kerr == .None && prim.exists(db.vfs, keep)) || (perr2 == .None && prim.exists(db.vfs, prom)) {
				pinned = p.base
			} else {
				left = true
			}
		}
		path, err := loose_path(buf[:], d.path, oid, db.format)
		if err == .None && prim.exists(db.vfs, path) {
			left = true
		}
	}
	return
}

Unreached_Reason :: enum u8 {
	Protected,
	Shared,
	Pinned,
	Repository,
	Left,
}

Unreached :: struct {
	oid:    Oid,
	reason: Unreached_Reason,
	ref:    string,
	commit: Oid,
	place:  string,
}

@(private)
Named_Root :: struct {
	name: string,
	oid:  Oid,
}

@(private)
reach_named :: proc(db: ^Odb, roots: []Named_Root, pending: ^map[Oid]struct{}, reason: Unreached_Reason, place: string, out: ^[dynamic]Unreached, allocator: runtime.Allocator) {
	for root in roots {
		if len(pending) == 0 {
			return
		}
		seen := make(map[Oid]struct{}, db.allocator)
		defer delete(seen)
		one := [1]Oid{root.oid}
		if mark(db, one[:], &seen) != .None {
			continue
		}
		hits := make([dynamic]Oid, db.allocator)
		defer delete(hits)
		for oid in prim.sorted_keys(pending^) {
			if oid in seen {
				append(&hits, oid)
			}
		}
		for oid in hits {
			delete_key(pending, oid)
			append(out, Unreached{oid = oid, reason = reason, ref = strings.clone(root.name, allocator), commit = root.oid, place = strings.clone(place, allocator)})
		}
	}
}

@(private)
reach_repository :: proc(db: ^Odb, dir: string, targets: []Oid, out: ^[dynamic]Unreached, allocator: runtime.Allocator) {
	inside := make(map[Oid]struct{}, db.allocator)
	defer delete(inside)
	buf: [PATH_MAX]u8
	for t in targets {
		path, err := loose_path(buf[:], dir, t, db.format)
		if err == .None && prim.exists(db.vfs, path) {
			inside[t] = {}
		}
	}
	x: Odb
	init(&x, db.vfs, db.clock, db.random, db.allocator)
	x.format = db.format
	common := parent_dir(dir)
	x.git_dir = strings.clone(common, db.allocator)
	x.common_dir = strings.clone(common, db.allocator)
	if p, cerr := strings.clone(dir, db.allocator); cerr == nil {
		add_dir(&x, p, false, 0)
	}
	defer close(&x)
	for t in targets {
		if t in inside {
			continue
		}
		if find_packed(&x, t, false).found {
			inside[t] = {}
		}
	}
	if len(inside) == 0 {
		return
	}
	roots := make([dynamic]Named_Root, db.allocator)
	defer delete(roots)
	refs, rerr := list_refs(&x, db.allocator)
	if rerr == .None {
		for r in refs {
			append(&roots, Named_Root{r.name, r.oid})
		}
	}
	head, herr := read_ref(&x, "HEAD")
	if herr == .None {
		append(&roots, Named_Root{"HEAD", head})
	}
	reach_named(&x, roots[:], &inside, .Repository, common, out, allocator)
	if rerr == .None {
		refs_destroy(refs, db.allocator)
	}
	for oid in prim.sorted_keys(inside) {
		append(out, Unreached{oid = oid, reason = .Repository, place = strings.clone(common, allocator)})
	}
}

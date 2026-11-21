package odb

import "base:runtime"
import "core:os"
import "core:strings"
import "core:time"

Prune_Stats :: struct {
	reachable: int,
	repack:    Repack_Stats,
}

prune :: proc(db: ^Odb, roots: []Oid, grace_seconds: i64, opts := DEFAULT_REPACK) -> (stats: Prune_Stats, err: Error) {
	if !db.store || len(db.dirs) == 0 || grace_seconds < 0 {
		return {}, .Invalid
	}
	a := db.allocator
	reachable := make(map[Oid]struct{}, a)
	defer delete(reachable)
	start := make([dynamic]Oid, a)
	defer delete(start)
	append(&start, ..roots)
	collect_ref_roots(db, &start) or_return
	mark(db, start[:], &reachable) or_return
	cutoff := time.time_add(time.now(), -time.Duration(grace_seconds) * time.Second)
	filter := Prune_Filter{&reachable, cutoff}
	stats.reachable = len(reachable)
	stats.repack = repack_run(db, opts, &filter) or_return
	return stats, .None
}

@(private)
collect_ref_roots :: proc(db: ^Odb, out: ^[dynamic]Oid) -> Error {
	if oid, err := read_ref(db, "HEAD"); err == .None {
		append(out, oid)
	} else if err != .Not_Found {
		return err
	}
	walk_refs(db, db.common_dir, "refs", out) or_return
	pb: [PATH_MAX]u8
	path := concat_into(pb[:], db.common_dir, "/packed-refs") or_return
	data, rerr := os.read_entire_file_from_path(path, db.allocator)
	if rerr != nil {
		return .None if rerr == .Not_Exist else .Io
	}
	defer delete(data, db.allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		hex := line[1:] if line[0] == '^' else line
		if sp := strings.index_byte(hex, ' '); sp >= 0 {
			hex = hex[:sp]
		}
		oid, format, ok := oid_from_hex(hex)
		if !ok || format != db.format {
			return .Corrupt
		}
		append(out, oid)
	}
	return .None
}

@(private)
walk_refs :: proc(db: ^Odb, root, rel: string, out: ^[dynamic]Oid) -> Error {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	ta := context.temp_allocator
	dir := strings.concatenate({root, "/", rel}, ta)
	entries, err := os.read_all_directory_by_path(dir, ta)
	if err != nil {
		return .None if err == .Not_Exist else .Io
	}
	for e in entries {
		name := strings.concatenate({rel, "/", e.name}, ta)
		#partial switch e.type {
		case .Directory:
			walk_refs(db, root, name, out) or_return
		case .Regular:
			if strings.has_suffix(e.name, ".lock") || !ref_name_valid(name) {
				continue
			}
			oid, rerr := read_ref(db, name)
			if rerr == .None {
				append(out, oid)
			} else if rerr != .Not_Found {
				return rerr
			}
		}
	}
	return .None
}

@(private)
mark :: proc(db: ^Odb, roots: []Oid, reachable: ^map[Oid]struct{}) -> Error {
	Item :: struct {
		oid:  Oid,
		type: Object_Type,
	}
	stack := make([dynamic]Item, db.allocator)
	defer delete(stack)
	for r in roots {
		append(&stack, Item{r, .None})
	}
	hsz := oid_size(db.format)
	for len(stack) > 0 {
		it := pop(&stack)
		if it.oid in reachable^ {
			continue
		}
		type := it.type
		if type == .None {
			t, _, herr := read_header(db, it.oid)
			if herr == .Not_Found {
				continue
			}
			herr or_return
			type = t
		}
		reachable[it.oid] = {}
		if type == .Blob {
			continue
		}
		t, data, rerr := read(db, it.oid, db.allocator)
		if rerr == .Not_Found {
			continue
		}
		rerr or_return
		defer delete(data, db.allocator)
		switch t {
		case .Commit:
			c := commit_decode(data, db.format, db.allocator) or_return
			append(&stack, Item{c.tree, .Tree})
			for p in c.parents {
				append(&stack, Item{p, .Commit})
			}
			commit_destroy(&c, db.allocator)
		case .Tree:
			ti := tree_iter(data, db.format)
			for e in tree_next(&ti) {
				switch e.mode {
				case MODE_TREE:
					append(&stack, Item{e.oid, .Tree})
				case MODE_GITLINK:
				case:
					reachable[e.oid] = {}
				}
			}
			if ti.err != .None {
				return ti.err
			}
		case .Tag:
			text := string(data)
			if !strings.has_prefix(text, "object ") || len(text) < 7 + hsz * 2 {
				return .Corrupt
			}
			oid, format, ok := oid_from_hex(text[7:7 + hsz * 2])
			if !ok || format != db.format {
				return .Corrupt
			}
			append(&stack, Item{oid, .None})
		case .Blob, .None:
		}
	}
	return .None
}

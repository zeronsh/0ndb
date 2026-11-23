package odb

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "../prim"

@(private)
Staged :: struct {
	oid:       Oid,
	tmp:       string,
	final:     string,
	fan:       string,
	data:      string,
	data_to:   string,
	packp:     ^Pack,
	pack:      bool,
	installed: bool,
	taken:     bool,
	retired:   bool,
}

Install :: struct {
	db:    ^Odb,
	items: [dynamic]^Staged,
	files: []string,
	dirs:  []string,
	roots: [2]string,
	nsync: u64,
}

@(private)
staged_free :: proc(db: ^Odb, s: ^Staged) {
	a := db.allocator
	delete(s.tmp, a)
	delete(s.final, a)
	delete(s.fan, a)
	delete(s.data, a)
	delete(s.data_to, a)
	free(s, a)
}

@(private)
staged_clear :: proc(db: ^Odb) {
	for s in db.staged {
		staged_free(db, s)
	}
	delete(db.staged)
	delete(db.staged_at)
	db.staged = nil
	db.staged_at = nil
}

@(private)
staged_new :: proc(db: ^Odb, oid: Oid, tmp, final, fan, data: string, pack: bool) -> ^Staged {
	a := db.allocator
	s := new(Staged, a)
	s.oid = oid
	s.tmp = strings.clone(tmp, a)
	s.final = strings.clone(final, a)
	s.fan = strings.clone(fan, a)
	s.data = strings.clone(data, a)
	s.pack = pack
	if db.staged == nil {
		db.staged = make([dynamic]^Staged, a)
		db.staged_at = make(map[Oid]^Staged, a)
	}
	append(&db.staged, s)
	return s
}

@(private)
stage_loose :: proc(db: ^Odb, oid: Oid, tmp, final, fan: string) {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	if s, ok := db.staged_at[oid]; ok && !s.installed {
		prim.remove(db.vfs, tmp)
		return
	}
	s := staged_new(db, oid, tmp, final, fan, "", false)
	db.staged_at[oid] = s
}

@(private)
stage_pack :: proc(db: ^Odb, base, pack_tmp, pack_path, idx_tmp, idx_path: string) -> Error {
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	p := load_pack(db, &db.dirs[0], base, idx_tmp)
	if p == nil {
		return .Corrupt
	}
	p.staged = true
	p.data_tmp = true
	p.data_at = strings.clone(pack_tmp, db.allocator)
	s := staged_new(db, {}, idx_tmp, idx_path, parent_dir(idx_path), pack_tmp, true)
	s.data_to = strings.clone(pack_path, db.allocator)
	s.packp = p
	return .None
}

@(private)
staged_lookup :: proc(db: ^Odb, oid: Oid) -> ^Staged {
	if s, ok := db.staged_at[oid]; ok && !s.installed {
		return s
	}
	return nil
}

@(private)
read_staged :: proc(db: ^Odb, s: ^Staged, allocator: runtime.Allocator) -> (type: Object_Type, data: []u8, err: Error) {
	type, data = read_loose(db, s.tmp, allocator) or_return
	got, herr := hash(db.format, type, data)
	if herr != .None || got != s.oid {
		delete(data, allocator)
		return .None, nil, .Corrupt
	}
	return type, data, .None
}

install_take :: proc(db: ^Odb, allocator := context.temp_allocator) -> (b: ^Install, err: Error) {
	files, dirs := take_pending(db, allocator) or_return
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	fresh := 0
	for s in db.staged {
		if !s.taken {
			fresh += 1
		}
	}
	if fresh == 0 && len(files) == 0 && len(dirs) == 0 {
		return nil, .None
	}
	b = new(Install, db.allocator)
	b.db = db
	b.items = make([dynamic]^Staged, 0, fresh, db.allocator)
	for s in db.staged {
		if !s.taken {
			s.taken = true
			append(&b.items, s)
		}
	}
	b.files = install_clone_list(db, files)
	b.dirs = install_clone_list(db, dirs)
	b.roots = {primary_dir(db), db.common_dir}
	return b, .None
}

@(private)
install_clone_list :: proc(db: ^Odb, list: []string) -> []string {
	out := make([]string, len(list), db.allocator)
	for v, i in list {
		out[i] = strings.clone(v, db.allocator)
	}
	return out
}

@(private)
install_free :: proc(b: ^Install) {
	a := b.db.allocator
	for f in b.files {
		delete(f, a)
	}
	for d in b.dirs {
		delete(d, a)
	}
	delete(b.files, a)
	delete(b.dirs, a)
	delete(b.items)
	free(b, a)
}

install_run :: proc(b: ^Install) -> Error {
	db := b.db
	files := make([dynamic]string, 0, len(b.items) * 2 + len(b.files), db.allocator)
	dirs := make([dynamic]string, 0, len(b.items) + len(b.dirs) + 1, db.allocator)
	defer delete(files)
	defer delete(dirs)
	loose := false
	sync.mutex_lock(&db.mutex)
	for s in b.items {
		if !s.installed {
			if s.pack {
				append(&files, s.data)
			}
			append(&files, s.tmp)
		}
		append(&dirs, s.fan)
		loose = loose || !s.pack
	}
	sync.mutex_unlock(&db.mutex)
	append(&files, ..b.files)
	append(&dirs, ..b.dirs)
	if loose && b.roots[0] != "" {
		append(&dirs, b.roots[0])
	}
	slice.sort(files[:])
	slice.sort(dirs[:])
	uf := distinct_sorted(files[:], db.allocator)
	ud := distinct_sorted(dirs[:], db.allocator)
	defer delete(uf, db.allocator)
	defer delete(ud, db.allocator)
	b.nsync = u64(len(uf) + len(ud))
	sync_paths(db, uf, nil, b.roots[:], true) or_return
	install_rename(b) or_return
	return sync_paths(db, nil, ud, b.roots[:])
}

@(private)
install_rename :: proc(b: ^Install) -> Error {
	db := b.db
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	for s in b.items {
		if s.installed {
			continue
		}
		if s.pack {
			if s.packp.data_tmp {
				perr(prim.rename(db.vfs, s.data, s.data_to)) or_return
				s.packp.data_tmp = false
			}
			perr(prim.rename(db.vfs, s.tmp, s.final)) or_return
			s.installed = true
			continue
		}
		if prim.rename(db.vfs, s.tmp, s.final) != .None {
			vfs_mkdir(db, s.fan)
			perr(prim.rename(db.vfs, s.tmp, s.final)) or_return
		}
		s.installed = true
	}
	return .None
}

install_done :: proc(b: ^Install, ok: bool) {
	db := b.db
	sync.mutex_lock(&db.mutex)
	for s in b.items {
		s.taken = false
		if ok && s.installed {
			install_retire(db, s)
		}
	}
	install_compact(db)
	if !ok {
		for f in b.files {
			track_locked(db, f)
		}
		for d in b.dirs {
			track_locked(db, "", d)
		}
	}
	sync.mutex_unlock(&db.mutex)
	install_free(b)
}

@(private)
install_retire :: proc(db: ^Odb, s: ^Staged) {
	if s.pack {
		s.packp.staged = false
	} else if cur, has := db.staged_at[s.oid]; has && cur == s {
		delete_key(&db.staged_at, s.oid)
	}
	s.retired = true
}

@(private)
install_compact :: proc(db: ^Odb) {
	j := 0
	for s in db.staged {
		if s.retired {
			staged_free(db, s)
			continue
		}
		db.staged[j] = s
		j += 1
	}
	resize(&db.staged, j)
}

@(private)
install_now :: proc(db: ^Odb) -> Error {
	sync.mutex_lock(&db.mutex)
	if len(db.staged) == 0 {
		sync.mutex_unlock(&db.mutex)
		return .None
	}
	b := Install{db = db, roots = {primary_dir(db), db.common_dir}}
	b.items = make([dynamic]^Staged, 0, len(db.staged), db.allocator)
	append(&b.items, ..db.staged[:])
	sync.mutex_unlock(&db.mutex)
	defer delete(b.items)
	install_run(&b) or_return
	sync.mutex_lock(&db.mutex)
	defer sync.mutex_unlock(&db.mutex)
	for s in b.items {
		if !s.taken && s.installed {
			install_retire(db, s)
		}
	}
	install_compact(db)
	return .None
}

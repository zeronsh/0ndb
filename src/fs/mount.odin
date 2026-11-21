package fs

import "base:runtime"
import "core:strconv"
import "../crdt"
import "../fstree"
import "../odb"
import "../prim"

Mount_Options :: struct {
	settle_ms:    i64,
	idle_ms:      i64,
	large_limit:  i64,
	inline_limit: int,
	threads:      int,
	import_chunk: int,
	line:         string,
}

DEFAULT_MOUNT :: Mount_Options {
	settle_ms    = 100,
	idle_ms      = 30_000,
	large_limit  = 16 << 20,
	inline_limit = 4096,
	threads      = 8,
	import_chunk = 8192,
	line         = "main",
}

Scope :: struct {
	id:     prim.Id,
	actor:  prim.Id,
	pids:   [dynamic]prim.Pid,
	mount:  ^Mount,
	closed: bool,
}

Fence_Proc :: #type proc(m: ^Mount, data: rawptr, err: Error)

@(private)
Fence :: struct {
	name:    string,
	arrived: bool,
	cb:      Fence_Proc,
	data:    rawptr,
}

Registry :: struct {
	vfs:       prim.Vfs,
	allocator: runtime.Allocator,
	run_dir:   string,
	mounts:    [dynamic]^Mount,
	scopes:    [dynamic]^Scope,
	loop:      ^prim.Loop,
	os:        _Registry_Os,
	on_ready:  proc(m: ^Mount, data: rawptr),
	ready_data: rawptr,
	observer:  Write_Observer,
	os_ready:  bool,
}

Write_Observer :: struct {
	data:    rawptr,
	start:   proc(data: rawptr, reg: ^Registry) -> Error,
	stop:    proc(data: rawptr, reg: ^Registry),
	changed: proc(data: rawptr, m: ^Mount, rel: string) -> (^Scope, bool),
}

Mount :: struct {
	reg:         ^Registry,
	slot:        int,
	vfs:         prim.Vfs,
	allocator:   runtime.Allocator,
	id:          prim.Id,
	root:        string,
	dir:         string,
	history:     ^History,
	db:          ^odb.Odb,
	actor:       prim.Id,
	line:        string,
	opts:        Mount_Options,
	lock_fd:     prim.Fd,
	git:         Git_Dirs,
	has_git:     bool,
	head:        Git_Head,
	reflog_pos:  i64,
	stamp:       Index_Stamp,
	shadow:      Shadow,
	ignore:      Ignore,
	awake:       bool,
	synced:      [dynamic]crdt.Op_Id,
	dirty:       map[string]^Scope,
	rescan:      bool,
	git_moved:   bool,
	fence_seq:   u64,
	fences:      [dynamic]Fence,
	timer:       prim.Timer,
	idle_timer:  prim.Timer,
	root_wd:     i32,
	watched:     bool,
	last_activity: i64,
	restoring:   bool,
	open_scopes: map[string]^Scope,
	intents:     [dynamic]Intent,
	imported:    bool,
	hold_line:   bool,
	alias:       [dynamic]Version,
	unwatched:   [dynamic]string,
}

Intent :: struct {
	actor: prim.Id,
	seq:   u64,
	n:     u64,
}

registry_init :: proc(reg: ^Registry, vfs: prim.Vfs, run_dir: string, allocator := context.allocator) -> Error {
	reg^ = {
		vfs       = vfs,
		allocator = allocator,
	}
	d, aerr := clone_string(run_dir, allocator)
	if aerr != nil {
		return .No_Memory
	}
	reg.run_dir = d
	reg.mounts = make([dynamic]^Mount, allocator)
	reg.scopes = make([dynamic]^Scope, allocator)
	return .None
}

@(private)
registry_ready :: proc(reg: ^Registry) -> Error {
	if reg.os_ready {
		return .None
	}
	from_prim(prim.mkdir_all(reg.vfs, reg.run_dir, 0o700)) or_return
	_registry_os_init(reg) or_return
	reg.os_ready = true
	if reg.loop != nil {
		return _registry_os_attach(reg, reg.loop)
	}
	return .None
}

registry_destroy :: proc(reg: ^Registry) {
	if reg.observer.stop != nil {
		reg.observer.stop(reg.observer.data, reg)
	}
	if reg.os_ready {
		_registry_os_destroy(reg)
	}
	for s in reg.scopes {
		delete(s.pids)
		free(s, reg.allocator)
	}
	delete(reg.scopes)
	delete(reg.mounts)
	delete(reg.run_dir, reg.allocator)
	reg^ = {}
}

registry_attach :: proc(reg: ^Registry, loop: ^prim.Loop, on_ready: proc(m: ^Mount, data: rawptr) = nil, data: rawptr = nil) -> Error {
	reg.loop = loop
	reg.on_ready = on_ready
	reg.ready_data = data
	if !reg.os_ready {
		return .None
	}
	return _registry_os_attach(reg, loop)
}

registry_set_observer :: proc(reg: ^Registry, obs: Write_Observer) -> Error {
	if reg.observer.stop != nil {
		reg.observer.stop(reg.observer.data, reg)
	}
	reg.observer = obs
	if obs.start != nil {
		return obs.start(obs.data, reg)
	}
	return .None
}

registry_poll :: proc(reg: ^Registry) -> Error {
	if !reg.os_ready {
		return .None
	}
	return _registry_os_read(reg)
}

mount_open :: proc(m: ^Mount, reg: ^Registry, h: ^History, db: ^odb.Odb, id: prim.Id, root: string, state_dir: string, actor: prim.Id, opts := DEFAULT_MOUNT, allocator := context.allocator) -> Error {
	m^ = {
		reg       = reg,
		vfs       = reg.vfs,
		allocator = allocator,
		id        = id,
		history   = h,
		db        = db,
		actor     = actor,
		opts      = opts,
		lock_fd   = prim.INVALID_FD,
		root_wd   = -1,
		slot      = -1,
	}
	m.root = clean_path(root, allocator)
	m.dir, _ = clone_string(state_dir, allocator)
	m.line, _ = clone_string(opts.line, allocator)
	m.synced = make([dynamic]crdt.Op_Id, allocator)
	m.dirty = make(map[string]^Scope, allocator)
	m.open_scopes = make(map[string]^Scope, allocator)
	m.fences = make([dynamic]Fence, allocator)
	m.intents = make([dynamic]Intent, allocator)
	m.unwatched = make([dynamic]string, allocator)
	ok := false
	defer if !ok {
		mount_close(m)
	}
	from_prim(prim.mkdir_all(m.vfs, state_dir, 0o700)) or_return
	lp, _ := path_join(state_dir, "lock", context.temp_allocator)
	fd, lerr := prim.lock_file(m.vfs, lp)
	if lerr != .None {
		return .Busy if lerr == .Busy || lerr == .Would_Block else from_prim(lerr)
	}
	m.lock_fd = fd
	m.git, m.has_git = git_locate(m.vfs, m.root, allocator)
	fresh := load_mount_state(m) or_return
	slot := -1
	for x, i in reg.mounts {
		if x == nil {
			slot = i
			break
		}
	}
	if slot < 0 {
		append(&reg.mounts, m)
		slot = len(reg.mounts) - 1
	} else {
		reg.mounts[slot] = m
	}
	m.slot = slot
	mount_wake(m) or_return
	if fresh {
		save_mount_state(m) or_return
		mount_import(m) or_return
	} else if !m.imported {
		mount_recover(m) or_return
		mount_import(m) or_return
		mount_pass(m, true) or_return
	} else {
		mount_recover(m) or_return
		mount_pass(m, true) or_return
	}
	mount_materialize(m) or_return
	ok = true
	mount_touch(m)
	return .None
}

mount_close :: proc(m: ^Mount) {
	if m.awake && len(m.dirty) > 0 {
		mount_pass(m, false)
	}
	mount_hibernate(m)
	if m.shadow.dir != "" {
		shadow_close(&m.shadow)
	}
	if m.reg != nil && m.slot >= 0 && m.slot < len(m.reg.mounts) {
		if m.reg.os_ready {
			_unwatch_mount(m.reg, m)
		}
		m.reg.mounts[m.slot] = nil
	}
	if m.reg != nil && m.reg.loop != nil {
		prim.timer_cancel(m.reg.loop, m.timer)
		prim.timer_cancel(m.reg.loop, m.idle_timer)
	}
	for s in m.reg.scopes {
		if s.mount == m {
			s.mount = nil
		}
	}
	for &f in m.fences {
		if f.cb != nil {
			f.cb(m, f.data, .Stopped)
		}
		delete(f.name, m.allocator)
	}
	delete(m.fences)
	delete(m.intents)
	for u in m.unwatched {
		delete(u, m.allocator)
	}
	delete(m.unwatched)
	for k in m.dirty {
		delete(k, m.allocator)
	}
	delete(m.dirty)
	for k in m.open_scopes {
		delete(k, m.allocator)
	}
	delete(m.open_scopes)
	delete(m.synced)
	git_head_destroy(&m.head, m.allocator)
	if m.has_git {
		git_dirs_destroy(&m.git, m.allocator)
	}
	if m.lock_fd >= 0 {
		prim.close_file(m.vfs, m.lock_fd)
	}
	delete(m.root, m.allocator)
	delete(m.dir, m.allocator)
	delete(m.line, m.allocator)
	m^ = {}
}

mount_wake :: proc(m: ^Mount) -> Error {
	if m.awake {
		return .None
	}
	sp, _ := path_join(m.dir, "shadow", context.temp_allocator)
	format := m.db.format if m.db != nil else odb.Hash_Format.Sha1
	if !shadow_attached(&m.shadow) {
		if m.shadow.dir == "" {
			shadow_open(&m.shadow, m.vfs, sp, format, m.allocator) or_return
		} else {
			shadow_attach(&m.shadow) or_return
		}
	}
	gd := m.git.dir if m.has_git else ""
	cd := m.git.common if m.has_git else ""
	if err := ignore_init(&m.ignore, m.vfs, gd, cd, !m.has_git, m.allocator); err != .None {
		shadow_detach(&m.shadow)
		return err
	}
	if m.history != nil {
		if err := history_wake(m.history); err != .None {
			ignore_destroy(&m.ignore)
			shadow_detach(&m.shadow)
			return err
		}
	}
	m.awake = true
	if !m.watched {
		registry_ready(m.reg) or_return
		_watch_mount(m.reg, m) or_return
		m.watched = true
	}
	return .None
}

mount_hibernate :: proc(m: ^Mount) -> Error {
	if !m.awake {
		return .None
	}
	if len(m.dirty) > 0 || m.rescan {
		return .Busy
	}
	err := shadow_persist(&m.shadow)
	save_mount_state(m)
	shadow_detach(&m.shadow)
	ignore_destroy(&m.ignore)
	if m.history != nil {
		history_trim(m.history)
		any_awake := false
		for x in m.reg.mounts {
			if x != nil && x != m && x.history == m.history && x.awake {
				any_awake = true
			}
		}
		if !any_awake {
			history_sleep(m.history)
		}
	}
	if m.db != nil {
		odb.trim(m.db)
	}
	m.awake = false
	if m.reg != nil && m.reg.loop != nil {
		prim.timer_cancel(m.reg.loop, m.idle_timer)
		m.idle_timer = 0
	}
	_heap_release()
	return err
}

mount_synced :: proc(m: ^Mount) -> Version {
	return m.synced[:]
}

mount_root :: proc(m: ^Mount) -> string {
	return m.root
}

mount_touch :: proc(m: ^Mount) {
	m.last_activity = prim.mono_ns()
	if m.reg.loop == nil || m.opts.idle_ms <= 0 {
		return
	}
	prim.timer_cancel(m.reg.loop, m.idle_timer)
	m.idle_timer = prim.timer(m.reg.loop, m.opts.idle_ms, m, proc(l: ^prim.Loop, data: rawptr) {
		mm := (^Mount)(data)
		if mount_hibernate(mm) == .Busy {
			mount_touch(mm)
		}
	})
}

mount_mark :: proc(m: ^Mount, rel: string, scope: ^Scope = nil) {
	if path_internal(rel) {
		name := path_name(rel)
		for &f in m.fences {
			if f.name == name {
				f.arrived = true
				mount_schedule(m, 0)
				return
			}
		}
		return
	}
	s := scope
	explicit := scope != nil
	if !explicit {
		if os, open := m.open_scopes[rel]; open {
			s = os
			explicit = true
		} else if obs := m.reg.observer; obs.changed != nil {
			if cs, found := obs.changed(obs.data, m, rel); found {
				s = cs
				explicit = true
			}
		}
	}
	if !explicit && !observer_installed(m.reg) {
		s = active_scope(m)
	}
	if v, ok := &m.dirty[rel]; ok {
		if explicit || (!observer_installed(m.reg) && s != nil) {
			v^ = s
		}
	} else {
		k, _ := clone_string(rel, m.allocator)
		m.dirty[k] = s
	}
	mount_schedule(m, m.opts.settle_ms)
}

mount_mark_observed :: proc(m: ^Mount, rel: string, scope: ^Scope) {
	if path_internal(rel) {
		mount_mark(m, rel)
		return
	}
	if v, ok := &m.open_scopes[rel]; ok {
		v^ = scope
	} else {
		k, _ := clone_string(rel, m.allocator)
		m.open_scopes[k] = scope
	}
	if v, ok := &m.dirty[rel]; ok {
		v^ = scope
	} else {
		k, _ := clone_string(rel, m.allocator)
		m.dirty[k] = scope
	}
	mount_schedule(m, m.opts.settle_ms)
}

mount_closed :: proc(m: ^Mount, rel: string) {
	if _, ok := m.open_scopes[rel]; ok {
		k, _ := delete_key(&m.open_scopes, rel)
		delete(k, m.allocator)
	}
}

observer_installed :: proc(reg: ^Registry) -> bool {
	return reg.observer.start != nil || reg.observer.changed != nil
}

mount_mark_rescan :: proc(m: ^Mount) {
	m.rescan = true
	mount_schedule(m, m.opts.settle_ms)
}

mount_mark_git :: proc(m: ^Mount) {
	m.git_moved = true
	mount_schedule(m, m.opts.settle_ms)
}

mount_schedule :: proc(m: ^Mount, delay_ms: i64) {
	if m.reg.loop == nil {
		return
	}
	if prim.timer_pending(m.reg.loop, m.timer) {
		if delay_ms > 0 {
			return
		}
		prim.timer_cancel(m.reg.loop, m.timer)
	}
	m.timer = prim.timer(m.reg.loop, delay_ms, m, proc(l: ^prim.Loop, data: rawptr) {
		mm := (^Mount)(data)
		if mm.reg.on_ready != nil {
			mm.reg.on_ready(mm, mm.reg.ready_data)
		} else {
			mount_run(mm)
		}
	})
}

mount_run :: proc(m: ^Mount) -> Error {
	fence := false
	for f in m.fences {
		if f.arrived {
			fence = true
		}
	}
	err := mount_pass(m, false, !fence)
	if err == .None {
		err = mount_materialize(m)
	}
	if fence {
		i := 0
		for i < len(m.fences) {
			f := m.fences[i]
			if f.arrived {
				if f.cb != nil {
					f.cb(m, f.data, err)
				}
				delete(f.name, m.allocator)
				ordered_remove(&m.fences, i)
				continue
			}
			i += 1
		}
	}
	mount_touch(m)
	return err
}

mount_fence :: proc(m: ^Mount, cb: Fence_Proc, data: rawptr) -> Error {
	m.fence_seq += 1
	digits: [24]u8
	num := strconv.write_uint(digits[:], m.fence_seq, 10)
	hex := prim.id_hex(m.id)
	name := make([]u8, len(TEMP_PREFIX) + 6 + len(hex) + 1 + len(num), m.allocator)
	n := copy(name, TEMP_PREFIX)
	n += copy(name[n:], "fence-")
	n += copy(name[n:], hex[:])
	name[n] = '-'
	copy(name[n + 1:], num)
	append(&m.fences, Fence{name = string(name), cb = cb, data = data})
	p, _ := path_join(m.root, string(name), context.temp_allocator)
	fd, err := prim.open_file(m.vfs, p, {.Write, .Create, .Truncate}, 0o600)
	if err != .None {
		pop(&m.fences)
		delete(name, m.allocator)
		return from_prim(err)
	}
	prim.close_file(m.vfs, fd)
	prim.remove(m.vfs, p)
	if !m.watched {
		m.fences[len(m.fences) - 1].arrived = true
		mount_schedule(m, 0)
	}
	return .None
}

mount_sync :: proc(m: ^Mount) -> Error {
	done := false
	result: Error
	State :: struct {
		done:   ^bool,
		result: ^Error,
	}
	st := State{&done, &result}
	mount_fence(m, proc(m: ^Mount, data: rawptr, err: Error) {
		s := (^State)(data)
		s.done^ = true
		s.result^ = err
	}, rawptr(&st)) or_return
	defer if !done {
		for f, i in m.fences {
			if f.data == rawptr(&st) {
				delete(f.name, m.allocator)
				ordered_remove(&m.fences, i)
				break
			}
		}
	}
	for !done {
		registry_poll(m.reg) or_return
		arrived := false
		for f in m.fences {
			arrived ||= f.arrived
		}
		if arrived || !m.watched {
			mount_run(m) or_return
		} else if !m.reg.os_ready || !_registry_wait(m.reg, 2000) {
			m.rescan = true
			for &f in m.fences {
				f.arrived = true
			}
			mount_run(m) or_return
		}
	}
	return result
}

scope_open :: proc(reg: ^Registry, m: ^Mount, id: prim.Id, actor: prim.Id, pids: []prim.Pid = nil) -> ^Scope {
	if m != nil && m.awake && len(m.dirty) > 0 {
		mount_pass(m, false)
	}
	s := new(Scope, reg.allocator)
	s.id = id
	s.actor = actor
	s.mount = m
	s.pids = make([dynamic]prim.Pid, reg.allocator)
	append(&s.pids, ..pids)
	append(&reg.scopes, s)
	return s
}

scope_add_pid :: proc(s: ^Scope, pid: prim.Pid) {
	append(&s.pids, pid)
}

scope_close :: proc(reg: ^Registry, s: ^Scope) -> Error {
	err: Error
	if s.mount != nil {
		err = mount_sync(s.mount)
		if err == .None && s.mount.db != nil {
			_, err = mount_commit(s.mount, {message = "0ndb: scope"})
		}
	}
	for x, i in reg.scopes {
		if x == s {
			ordered_remove(&reg.scopes, i)
			break
		}
	}
	for m in reg.mounts {
		if m == nil {
			continue
		}
		for k, v in m.dirty {
			if v == s {
				m.dirty[k] = nil
			}
		}
		for k, v in m.open_scopes {
			if v == s {
				m.open_scopes[k] = nil
			}
		}
	}
	delete(s.pids)
	free(s, reg.allocator)
	return err
}

@(private)
active_scope :: proc(m: ^Mount) -> ^Scope {
	for i := len(m.reg.scopes) - 1; i >= 0; i -= 1 {
		s := m.reg.scopes[i]
		if s.mount == m && !s.closed {
			return s
		}
	}
	return nil
}

@(private)
load_mount_state :: proc(m: ^Mount) -> (fresh: bool, err: Error) {
	p, _ := path_join(m.dir, "mount", context.temp_allocator)
	data, rerr := prim.read_file(m.vfs, p, context.temp_allocator)
	if rerr == .Not_Found {
		if m.has_git {
			m.head, _ = git_head(m.vfs, m.git, m.allocator)
			m.reflog_pos = git_reflog_len(m.vfs, m.git)
			m.stamp = git_index_stamp(m.vfs, m.git)
		}
		return true, .None
	}
	if rerr != .None {
		return false, from_prim(rerr)
	}
	rd := prim.reader(data)
	if prim.read_u8(&rd) != 1 {
		return false, .Corrupt
	}
	m.actor = prim.read_id(&rd)
	v := decode_version(prim.read_bytes(&rd), context.temp_allocator) or_return
	append(&m.synced, ..v)
	branch := prim.read_str(&rd)
	commit := prim.read_str(&rd)
	m.head.branch, _ = clone_string(branch, m.allocator)
	m.head.commit, _ = clone_string(commit, m.allocator)
	m.reflog_pos = prim.read_ivarint(&rd)
	m.stamp.mtime_ns = prim.read_ivarint(&rd)
	m.stamp.size = prim.read_ivarint(&rd)
	m.stamp.ino = prim.read_uvarint(&rd)
	ni := prim.read_uvarint(&rd)
	if ni > u64(prim.reader_remaining(&rd)) {
		return false, .Corrupt
	}
	for _ in 0 ..< ni {
		it: Intent
		it.actor = prim.read_id(&rd)
		it.seq = prim.read_uvarint(&rd)
		it.n = prim.read_uvarint(&rd)
		append(&m.intents, it)
	}
	m.imported = prim.read_bool(&rd) if prim.reader_remaining(&rd) > 0 else true
	if !prim.reader_ok(&rd) {
		return false, .Corrupt
	}
	return false, .None
}

save_mount_state :: proc(m: ^Mount) -> Error {
	buf := make([dynamic]u8, context.temp_allocator)
	vb := make([dynamic]u8, context.temp_allocator)
	encode_version(&vb, m.synced[:])
	w := prim.writer(&buf)
	prim.write_u8(&w, 1)
	prim.write_id(&w, m.actor)
	prim.write_bytes(&w, vb[:])
	prim.write_str(&w, m.head.branch)
	prim.write_str(&w, m.head.commit)
	prim.write_ivarint(&w, m.reflog_pos)
	prim.write_ivarint(&w, m.stamp.mtime_ns)
	prim.write_ivarint(&w, m.stamp.size)
	prim.write_uvarint(&w, m.stamp.ino)
	prim.write_uvarint(&w, u64(len(m.intents)))
	for it in m.intents {
		prim.write_id(&w, it.actor)
		prim.write_uvarint(&w, it.seq)
		prim.write_uvarint(&w, it.n)
	}
	prim.write_bool(&w, m.imported)
	p, _ := path_join(m.dir, "mount", context.temp_allocator)
	return from_prim(prim.replace_atomic(m.vfs, p, buf[:]))
}

mount_recover :: proc(m: ^Mount) -> Error {
	if len(m.intents) == 0 {
		return .None
	}
	h := m.history
	last: Maybe(crdt.Op_Id)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	for it in m.intents {
		lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{it.actor, it.seq})
		if !ok {
			break
		}
		spans := []crdt.Lv_Span{{lv = lv, len = int(it.n)}}
		spans_touched(h, spans, &touched) or_return
		last = crdt.Op_Id{it.actor, it.seq + it.n - 1}
	}
	if l, ok := last.?; ok {
		snap := fstree.current(&h.tree)
		for ino in touched {
			info, found, ierr := fstree.info(&snap, ino, context.temp_allocator)
			if ierr != nil {
				return .Corrupt
			}
			old, _, had := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return
			if !found || !info.present {
				if had {
					shadow_remove(&m.shadow, old) or_return
				}
				continue
			}
			p, pok, perr := fstree.path(&snap, ino, context.temp_allocator)
			if perr != nil || !pok {
				continue
			}
			if had && old != p {
				shadow_remove(&m.shadow, old) or_return
			}
			shadow_put(&m.shadow, p, Entry{inode = ino, kind = info.kind}) or_return
		}
		shadow_persist(&m.shadow) or_return
		clear(&m.synced)
		append(&m.synced, l)
	}
	clear(&m.intents)
	history_trim(h)
	return save_mount_state(m)
}

note_unwatched :: proc(m: ^Mount, rel: string) {
	for u in m.unwatched {
		if path_at_or_under(rel, u) {
			return
		}
	}
	i := 0
	for i < len(m.unwatched) {
		if path_under(m.unwatched[i], rel) {
			delete(m.unwatched[i], m.allocator)
			unordered_remove(&m.unwatched, i)
			continue
		}
		i += 1
	}
	c, _ := clone_string(rel, m.allocator)
	append(&m.unwatched, c)
}

mount_unwatched :: proc(m: ^Mount) -> []string {
	return m.unwatched[:]
}

package fs

import "base:runtime"
import "core:hash/xxhash"
import "core:crypto/blake2b"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "../crdt"
import "../fshist"
import "../fstree"
import "../journal"
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
	follow_branch: bool,
	index_trust:  bool,
}

DEFAULT_MOUNT :: Mount_Options {
	settle_ms    = 100,
	idle_ms      = 30_000,
	large_limit  = 16 << 20,
	inline_limit = 4096,
	threads      = 8,
	import_chunk = 8192,
	line         = "main",
	follow_branch = true,
	index_trust  = ODIN_OS == .Windows,
}

Scope :: struct {
	id:     prim.Id,
	actor:  prim.Id,
	pids:   [dynamic]prim.Pid,
	mount:  ^Mount,
	closed: bool,
	pins:   [dynamic]Pin,
	allocator: runtime.Allocator,
}

Fence_Proc :: #type proc(m: ^Mount, data: rawptr, err: Error)

@(private)
Fence :: struct {
	name:     string,
	arrived:  bool,
	observed: bool,
	token:    u64,
	cb:       Fence_Proc,
	data:     rawptr,
}

@(private)
fence_ready :: proc "contextless" (f: Fence) -> bool {
	return f.arrived && f.observed
}

@(private)
Fence_Token :: struct {
	reg:   ^Registry,
	m:     ^Mount,
	token: u64,
}

Registry :: struct {
	vfs:       prim.Vfs,
	allocator: runtime.Allocator,
	run_dir:   string,
	mounts:    [dynamic]^Mount,
	scopes:    [dynamic]^Scope,
	dirs:      [dynamic]^Dir_Watch,
	loop:      ^prim.Loop,
	os:        _Registry_Os,
	on_ready:  proc(m: ^Mount, data: rawptr),
	ready_data: rawptr,
	observer:  Write_Observer,
	fence_token: u64,
	watcher:   Watcher,
	random:    prim.Random,
	os_ready:  bool,
	boot:      prim.Id,
	on_eol:    Eol_Warning_Proc,
	eol_data:  rawptr,
	on_base:   Base_Proc,
	base_data: rawptr,
	exec:      Sync_Exec,
	spawner:   Spawner,
	on_line:   Line_Proc,
	on_lock:   Git_Lock_Proc,
	hook_data: rawptr,
}

Line_Proc :: #type proc(m: ^Mount, from, to: string, data: rawptr)
Git_Lock_Proc :: #type proc(m: ^Mount, held: bool, data: rawptr)

registry_set_line_hooks :: proc(reg: ^Registry, on_line: Line_Proc, on_lock: Git_Lock_Proc, data: rawptr) {
	reg.on_line = on_line
	reg.on_lock = on_lock
	reg.hook_data = data
}

mount_line :: proc(m: ^Mount) -> string {
	if len(m.branch) > 0 {
		return line_key_of(m, m.branch, context.temp_allocator)
	}
	return m.line
}

Observe_Done :: proc(ctx: rawptr, err: Error)

Sync_Exec :: struct {
	data: rawptr,
	run:  proc(data: rawptr, job: proc(arg: rawptr), done: proc(arg: rawptr), arg: rawptr),
}

registry_set_exec :: proc(reg: ^Registry, exec: Sync_Exec) {
	reg.exec = exec
}

@(private)
Obs_Wait :: struct {
	done: Observe_Done,
	ctx:  rawptr,
}

@(private)
Log_Sync :: struct {
	m:         ^Mount,
	vfs:       prim.Vfs,
	fd:        prim.Fd,
	err:       Error,
	waits:     [dynamic]Obs_Wait,
	detached:  bool,
	allocator: runtime.Allocator,
}

line_key_of :: proc(m: ^Mount, line: string, allocator := context.allocator) -> string {
	if m.has_git && line == m.home_line && len(m.home) > 0 {
		out, _ := strings.concatenate({"git:", m.home}, allocator)
		return out
	}
	return line
}

@(private)
line_name_of :: proc(m: ^Mount, key: string) -> string {
	if m.has_git && len(m.home) > 0 && len(key) == 4 + len(m.home) && key[:4] == "git:" && key[4:] == m.home {
		return m.home_line
	}
	return key
}

@(private)
UNATTRIBUTED_PREFIX :: [8]u8{'0', 'n', 'd', 'b', '-', 'u', 'n', 'a'}

unattributed_actor :: proc(device: prim.Id) -> (id: prim.Id) {
	p := UNATTRIBUTED_PREFIX
	copy(id[:8], p[:])
	d := device
	prim.put_u64le(id[8:16], xxhash.XXH3_64_with_seed(d[:], 0x756e61))
	return
}

is_unattributed :: proc "contextless" (id: prim.Id) -> bool {
	p := UNATTRIBUTED_PREFIX
	x := id
	return string(x[:8]) == string(p[:])
}

registry_set_boot :: proc(reg: ^Registry, boot: prim.Id) {
	reg.boot = boot
}

@(private)
BOOT_ID_PATH :: "/proc/sys/kernel/random/boot_id"

@(private)
registry_boot :: proc(reg: ^Registry) -> prim.Id {
	if reg.boot == {} {
		buf: [64]u8
		n := 0
		err := prim.Error.Not_Found
		if fd, oerr := prim.open_file(reg.vfs, BOOT_ID_PATH); oerr == .None {
			n, err = prim.read_at(reg.vfs, fd, buf[:], 0)
			prim.close_file(reg.vfs, fd)
		}
		data := buf[:max(n, 0)]
		if err == .None && len(data) > 0 {
			id: prim.Id
			prim.put_u64le(id[0:8], xxhash.XXH3_64_with_seed(data, 1))
			prim.put_u64le(id[8:16], xxhash.XXH3_64_with_seed(data, 2))
			reg.boot = id
		}
	}
	return reg.boot
}

Watcher :: struct {
	data:      rawptr,
	start:     proc(data: rawptr, reg: ^Registry) -> Error,
	stop:      proc(data: rawptr, reg: ^Registry),
	attach:    proc(data: rawptr, reg: ^Registry, loop: ^prim.Loop) -> Error,
	watch:     proc(data: rawptr, reg: ^Registry, m: ^Mount) -> Error,
	unwatch:   proc(data: rawptr, reg: ^Registry, m: ^Mount),
	watch_dir: proc(data: rawptr, reg: ^Registry, m: ^Mount, rel: string, parent: i32) -> (i32, Error),
	watch_path:   proc(data: rawptr, reg: ^Registry, id: int, path: string) -> Error,
	unwatch_path: proc(data: rawptr, reg: ^Registry, id: int),
	poll:      proc(data: rawptr, reg: ^Registry) -> Error,
	wait:      proc(data: rawptr, reg: ^Registry, ms: i32) -> bool,
	exhausted: proc(data: rawptr, reg: ^Registry) -> bool,
}

Watch_Kind :: enum u8 {
	Changed,
	Closed,
	Gone,
	Overflow,
}

os_watcher :: proc() -> Watcher {
	return Watcher {
		start = proc(data: rawptr, reg: ^Registry) -> Error {
			return _registry_os_init(reg)
		},
		stop = proc(data: rawptr, reg: ^Registry) {
			_registry_os_destroy(reg)
		},
		attach = proc(data: rawptr, reg: ^Registry, loop: ^prim.Loop) -> Error {
			return _registry_os_attach(reg, loop)
		},
		watch = proc(data: rawptr, reg: ^Registry, m: ^Mount) -> Error {
			return _watch_mount(reg, m)
		},
		unwatch = proc(data: rawptr, reg: ^Registry, m: ^Mount) {
			_unwatch_mount(reg, m)
		},
		watch_dir = proc(data: rawptr, reg: ^Registry, m: ^Mount, rel: string, parent: i32) -> (i32, Error) {
			return _os_watch_dir(reg, m, rel, parent)
		},
		watch_path = proc(data: rawptr, reg: ^Registry, id: int, path: string) -> Error {
			return _os_watch_path(reg, id, path)
		},
		unwatch_path = proc(data: rawptr, reg: ^Registry, id: int) {
			_os_unwatch_path(reg, id)
		},
		poll = proc(data: rawptr, reg: ^Registry) -> Error {
			return _registry_os_read(reg)
		},
		wait = proc(data: rawptr, reg: ^Registry, ms: i32) -> bool {
			return _registry_wait(reg, ms)
		},
		exhausted = proc(data: rawptr, reg: ^Registry) -> bool {
			return reg.os.full
		},
	}
}

Dir_Watch_Proc :: #type proc(data: rawptr, name: string)

@(private)
Dir_Watch :: struct {
	path: string,
	cb:   Dir_Watch_Proc,
	data: rawptr,
	wd:   i32,
}

@(private)
DIR_WATCH_SLOT :: 1 << 24

registry_watch_dir :: proc(reg: ^Registry, path: string, cb: Dir_Watch_Proc, data: rawptr) -> (id: int, err: Error) {
	w := reg.watcher
	if w.watch_path == nil || w.unwatch_path == nil {
		return -1, .Unsupported
	}
	registry_ready(reg) or_return
	id = -1
	for d, i in reg.dirs {
		if d == nil {
			id = i
			break
		}
	}
	if id < 0 {
		append(&reg.dirs, nil)
		id = len(reg.dirs) - 1
	}
	dw := new(Dir_Watch, reg.allocator)
	dw.path, _ = clone_string(path, reg.allocator)
	dw.cb = cb
	dw.data = data
	dw.wd = -1
	reg.dirs[id] = dw
	if werr := w.watch_path(w.data, reg, id, dw.path); werr != .None {
		delete(dw.path, reg.allocator)
		free(dw, reg.allocator)
		reg.dirs[id] = nil
		return -1, werr
	}
	return id, .None
}

registry_unwatch_dir :: proc(reg: ^Registry, id: int) {
	if id < 0 || id >= len(reg.dirs) || reg.dirs[id] == nil {
		return
	}
	if reg.watcher.unwatch_path != nil {
		reg.watcher.unwatch_path(reg.watcher.data, reg, id)
	}
	dw := reg.dirs[id]
	reg.dirs[id] = nil
	delete(dw.path, reg.allocator)
	free(dw, reg.allocator)
}

@(private)
registry_dir_event :: proc(reg: ^Registry, id: int, name: string) {
	if id < 0 || id >= len(reg.dirs) || reg.dirs[id] == nil {
		return
	}
	dw := reg.dirs[id]
	dw.cb(dw.data, name)
}

registry_set_watcher :: proc(reg: ^Registry, w: Watcher) -> Error {
	if reg.os_ready {
		return .Busy
	}
	reg.watcher = w
	return .None
}

registry_notify :: proc(reg: ^Registry, path: string, kind: Watch_Kind) {
	if kind == .Overflow {
		for m in reg.mounts {
			if m != nil {
				mount_events_lost(m)
			}
		}
		return
	}
	best: ^Mount
	for m in reg.mounts {
		if m == nil {
			continue
		}
		if m.has_git && (path_under(path, m.git.dir) || (len(m.git.common) > 0 && path_under(path, m.git.common))) {
			name := path_name(path)
			parent := path_parent(path)
			if parent == m.git.dir && name == "index.lock" {
				mount_git_lock(m, kind != .Gone && prim.exists(m.vfs, path))
			}
			if (parent == m.git.dir || parent == m.git.common) && (name == "HEAD" || name == "index" || name == "ORIG_HEAD" || name == "MERGE_HEAD") {
				mount_mark_git(m)
			}
			if parent == m.git.dir && name == "index.lock" {
				held := prim.exists(m.vfs, path)
				if held != m.lock_held {
					m.lock_held = held
					if reg.on_lock != nil {
						reg.on_lock(m, held, reg.hook_data)
					}
				}
			}
			return
		}
		if path == m.root {
			if kind == .Gone {
				mount_mark_rescan(m)
			}
			return
		}
		if path_under(path, m.root) && (best == nil || len(m.root) > len(best.root)) {
			best = m
		}
	}
	if best == nil {
		return
	}
	rel := path[len(best.root) + 1:]
	mount_mark(best, rel)
	if kind == .Closed {
		mount_closed(best, rel)
	}
}

watch_dir :: proc(reg: ^Registry, m: ^Mount, rel: string, parent_wd: i32) -> (wd: i32, err: Error) {
	if reg == nil || !reg.os_ready || reg.watcher.watch_dir == nil {
		return -1, .None
	}
	return reg.watcher.watch_dir(reg.watcher.data, reg, m, rel, parent_wd)
}

watch_exhausted :: proc(reg: ^Registry) -> bool {
	return reg.os_ready && reg.watcher.exhausted != nil && reg.watcher.exhausted(reg.watcher.data, reg)
}

Write_Observer :: struct {
	data:    rawptr,
	start:   proc(data: rawptr, reg: ^Registry) -> Error,
	stop:    proc(data: rawptr, reg: ^Registry),
	changed: proc(data: rawptr, m: ^Mount, rel: string) -> (^Scope, bool),
	fence:   proc(data: rawptr, reg: ^Registry, done: proc(data: rawptr), done_data: rawptr),
	lock_procs: proc(data: rawptr, lock: string, roots: []string, allocator: runtime.Allocator) -> []Git_Proc,
	lock_creator: proc(data: rawptr, path: string) -> (prim.Pid, bool),
	gate:       proc(data: rawptr, root: string, exempt: []prim.Pid) -> (u32, bool),
	ungate:     proc(data: rawptr, id: u32),
	gate_max_ms: i64,
	opened:     proc(data: rawptr, m: ^Mount),
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
	git_refs:    bool,
	git_format:  odb.Hash_Format,
	head:        Git_Head,
	reflog_pos:  i64,
	stamp:       Index_Stamp,
	shadow:      Shadow,
	ignore:      Ignore,
	awake:       bool,
	shown:       map[string][]crdt.Op_Id,
	synced:      [dynamic]crdt.Op_Id,
	placed:      [dynamic]crdt.Op_Id,
	has_placed:  bool,
	mat_ready:   bool,
	mat_fast:    bool,
	dirty:       map[string]^Scope,
	dirty_at:    map[string]i64,
	closed:      map[string]i64,
	rescan:      bool,
	git_moved:   bool,
	fence_seq:   u64,
	git_locked:  bool,
	lock_first:  bool,
	lock_stale:  bool,
	gate_id:     u32,
	gate_timer:  prim.Timer,
	hold_id:     u32,
	hold_timer:  prim.Timer,
	gate_overruns: u64,
	lock_watches: [dynamic]Lock_Watch,
	conv_seq:    u64,
	fences:      [dynamic]Fence,
	timer:       prim.Timer,
	warm:        ^Warm_Job,
	warm_timer:  prim.Timer,
	warmed:      bool,
	idle_timer:  prim.Timer,
	root_wd:     i32,
	watched:     bool,
	restoring:   bool,
	adopting:    bool,
	img:         Mount_Image,
	mat:         ^Mat_Sync,
	owed:        Mat_Sync,
	merge_base:  Version,
	mat_retries: int,
	mat_bytes:   int,
	attrib:      map[string]Attrib,
	log_fd:      prim.Fd,
	attrib_chain: map[string][dynamic]Attrib_Step,
	landed: map[prim.Id]bool,
	landed_gone: bool,
	log_sync:    ^Log_Sync,
	log_next:    [dynamic]Obs_Wait,
	log_len:     i64,
	log_gen:     u64,
	log_at:      i64,
	saved:       u64,
	saved_synced: [dynamic]crdt.Op_Id,
	saved_jpos:  i64,
	state_seq:   u64,
	legacy:      bool,
	lost:        bool,
	retained:    bool,
	override:    map[string]odb.Oid,
	trusted:     map[string]Index_Entry,
	trust_mtime: i64,
	trust_reads: int,
	trust_refused: int,
	clean:       bool,
	waits:       [dynamic]Mount_Wait,
	open_scopes: map[string]^Scope,
	intents:     [dynamic]Intent,
	nonce:       prim.Id,
	mat_wait:    bool,
	mat_waits:   [dynamic]Mat_Wait,
	reverts:     [dynamic]Pending_Revert,
	mat_held:    bool,
	mat_ingest:  bool,
	copy:        ^Copy_Map,
	importing:   bool,
	shadow_mark: Shadow_Mark,
	passes:      u64,
	reconciles:  u64,
	jpos:        i64,
	jpend:       i64,
	imported:    bool,
	adopt_pending: bool,
	hold_line:   bool,
	alias:       [dynamic]Version,
	unwatched:   [dynamic]string,
	attrs:       ^Attr_Ctx,
	collided:    [dynamic]string,
	absent:      [dynamic]string,
	absent_set:  map[string]bool,
	sweep_temps: bool,
	stale_temps: [dynamic]string,
	holds:       [dynamic]Path_Hold,
	reload_ms:   i64,
	reload_owed: bool,
	reshow:      [dynamic]string,
	branch:      string,
	home:        string,
	home_line:   string,
	lock_held:   bool,
	switch_to:   string,
	switch_from: string,
	switch_phase: u8,
	switch_tail: bool,
	switch_fence: u64,
	switch_fence_ok: bool,
	switch_timer: prim.Timer,
	switch_fences: u64,
	event_actors: u64,
	switch_done: Switch_Done,
	switch_data: rawptr,
	link_mode:   Link_Mode,
	gitlinks:    []Gitlink,
}

Intent :: struct {
	actor: prim.Id,
	seq:   u64,
	n:     u64,
}

registry_init :: proc(reg: ^Registry, vfs: prim.Vfs, run_dir: string, allocator := context.allocator, random := prim.Random{}) -> Error {
	reg^ = {
		vfs       = vfs,
		allocator = allocator,
		watcher   = os_watcher(),
		random    = random,
	}
	d, aerr := clone_string(run_dir, allocator)
	if aerr != nil {
		return .No_Memory
	}
	reg.run_dir = d
	reg.mounts = make([dynamic]^Mount, allocator)
	reg.scopes = make([dynamic]^Scope, allocator)
	reg.dirs = make([dynamic]^Dir_Watch, allocator)
	return .None
}

@(private)
registry_ready :: proc(reg: ^Registry) -> Error {
	if reg.os_ready {
		return .None
	}
	from_prim(prim.mkdir_all(reg.vfs, reg.run_dir, 0o700)) or_return
	w := reg.watcher
	if w.start != nil {
		w.start(w.data, reg) or_return
	}
	reg.os_ready = true
	if reg.loop != nil && w.attach != nil {
		return w.attach(w.data, reg, reg.loop)
	}
	return .None
}

registry_destroy :: proc(reg: ^Registry) {
	if reg.observer.stop != nil {
		reg.observer.stop(reg.observer.data, reg)
	}
	for _, i in reg.dirs {
		registry_unwatch_dir(reg, i)
	}
	delete(reg.dirs)
	if reg.os_ready && reg.watcher.stop != nil {
		reg.watcher.stop(reg.watcher.data, reg)
	}
	for s in reg.scopes {
		scope_pins_free(s)
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
	if !reg.os_ready || reg.watcher.attach == nil {
		return .None
	}
	return reg.watcher.attach(reg.watcher.data, reg, loop)
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
	if !reg.os_ready || reg.watcher.poll == nil {
		return .None
	}
	return reg.watcher.poll(reg.watcher.data, reg)
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
		log_fd    = prim.INVALID_FD,
		log_next  = make([dynamic]Obs_Wait, allocator),
		root_wd   = -1,
		slot      = -1,
	}
	m.root = clean_path(root, allocator)
	m.dir, _ = clone_string(state_dir, allocator)
	m.line, _ = clone_string(opts.line, allocator)
	m.synced = make([dynamic]crdt.Op_Id, allocator)
	m.dirty = make(map[string]^Scope, allocator)
	m.dirty_at = make(map[string]i64, allocator)
	m.closed = make(map[string]i64, allocator)
	m.open_scopes = make(map[string]^Scope, allocator)
	m.fences = make([dynamic]Fence, allocator)
	m.intents = make([dynamic]Intent, allocator)
	m.landed = make(map[prim.Id]bool, allocator)
	m.unwatched = make([dynamic]string, allocator)
	m.collided = make([dynamic]string, allocator)
	m.absent = make([dynamic]string, allocator)
	m.absent_set = make(map[string]bool, allocator)
	m.stale_temps = make([dynamic]string, allocator)
	m.holds = make([dynamic]Path_Hold, allocator)
	m.reshow = make([dynamic]string, allocator)
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
	m.waits = make([dynamic]Mount_Wait, allocator)
	m.attrib = make(map[string]Attrib, allocator)
	if h != nil {
		history_retain(h)
		m.retained = true
	}
	fresh := load_mount_state(m) or_return
	m.actor = fshist.ingestion_actor(h.self if h != nil else actor, id)
	if h != nil {
		history_register_actor(h, m.actor, id) or_return
	}
	m.home_line, _ = clone_string(opts.line, allocator)
	if m.has_git {
		if len(m.home) == 0 && len(m.branch) == 0 {
			m.home, _ = clone_string(m.head.branch, allocator)
		}
		if len(m.branch) == 0 {
			m.branch, _ = clone_string(branch_key(m, m.head, context.temp_allocator), allocator)
		}
		if len(m.switch_to) > 0 {
			delete(m.line, allocator)
			m.line, _ = clone_string(m.switch_to if m.switch_phase >= SWITCH_TARGET else m.switch_from, allocator)
		} else if m.opts.follow_branch && m.line == m.home_line && m.branch != m.home_line {
			delete(m.line, allocator)
			m.line, _ = clone_string(m.branch, allocator)
		}
		mount_line_actor(m) or_return
	}
	attrib_log_open(m) or_return
	image_take(m, &m.img)
	if h != nil {
		append(&h.mounts, m)
	}
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
	mount_shadow_reconcile(m) or_return
	if reg.observer.opened != nil {
		reg.observer.opened(reg.observer.data, m)
	}
	if m.has_git {
		if lock, lerr := path_join(m.git.dir, "index.lock", context.temp_allocator); lerr == nil && prim.exists(m.vfs, lock) {
			mount_git_lock(m, true)
		}
	}
	m.shadow.hold = true
	m.clean = false
	save_mount_state(m) or_return
	mount_git_sources(m) or_return
	before := mount_jlen(m)
	m.sweep_temps = true
	rerr := mount_open_rest(m, fresh)
	if err := rerr; err != .None {
		if mount_jlen(m) == before {
			return err
		}
		m.rescan = true
		mount_schedule(m, 0)
	}
	ok = true
	if len(m.switch_to) > 0 {
		mount_schedule(m, 0)
	}
	mount_touch(m)
	return .None
}

@(private)
mount_open_rest :: proc(m: ^Mount, fresh: bool) -> Error {
	if fresh {
		save_mount_state(m) or_return
		mount_import(m) or_return
	} else if !m.imported {
		mount_recover(m) or_return
		mount_import(m) or_return
		mount_pass(m, true) or_return
	} else {
		mount_recover(m) or_return
		if perr := mount_pass(m, true); perr == .Deferred {
			m.rescan = true
			return .None
		} else if perr != .None {
			return perr
		}
	}
	mount_materialize(m) or_return
	if m.lost {
		m.lost = false
		save_mount_state(m) or_return
	}
	return .None
}

@(private)
mount_git_sources :: proc(m: ^Mount) -> Error {
	if !m.has_git || m.db == nil {
		return .None
	}
	f := git_object_format(m.vfs, m.git.common)
	m.git_format = f
	if f != m.db.format || (m.history.db != nil && f != m.history.db.format) {
		return .None
	}
	objects, _ := path_join(m.git.common, "objects", context.temp_allocator)
	if e := odb.add_object_dir(m.db, objects); e != .None && e != .Not_Found {
		return .None
	}
	history_add_source(m.history, objects) or_return
	m.git_refs = true
	return .None
}

@(private)
Lost_Range :: struct {
	actor: u32,
	from:  u64,
	to:    u64,
}

@(private)
drop_lost :: proc(m: ^Mount, dir: string, lost: []Lost_Range) -> Error {
	heap := runtime.heap_allocator()
	kids := make([dynamic]Shadow_Child, heap)
	defer {
		shadow_children_free(kids[:], heap)
		delete(kids)
	}
	shadow_children(&m.shadow, dir, &kids, heap) or_return
	for k in kids {
		child, _ := path_join(dir, k.name, heap)
		defer delete(child, heap)
		if k.entry.kind == .Dir {
			drop_lost(m, child, lost) or_return
		}
		for r in lost {
			if k.entry.inode.actor == r.actor && k.entry.inode.seq >= r.from && k.entry.inode.seq < r.to {
				shadow_remove(&m.shadow, child) or_return
				break
			}
		}
	}
	return .None
}

mount_close :: proc(m: ^Mount) {
	warm_stop(m)
	mount_release_writes(m)
	mount_unlock(m)
	delete(m.lock_watches)
	m.lock_watches = nil
	if m.awake && len(m.dirty) > 0 {
		mount_pass(m, false)
	}
	mount_hibernate(m)
	if m.lock_fd >= 0 && m.dir != "" {
		m.clean = true
		save_mount_state(m)
	}
	if m.log_fd >= 0 {
		if len(m.log_next) > 0 {
			err := from_prim(prim.datasync(m.vfs, m.log_fd))
			for w in m.log_next {
				if w.done != nil {
					w.done(w.ctx, err)
				}
			}
			clear(&m.log_next)
		}
		if ls := m.log_sync; ls != nil {
			ls.detached = true
			ls.m = nil
			m.log_sync = nil
		} else {
			prim.close_file(m.vfs, m.log_fd)
		}
		m.log_fd = prim.INVALID_FD
	}
	delete(m.log_next)
	for k, l in m.attrib_chain {
		delete(l)
		delete(k, m.allocator)
	}
	delete(m.attrib_chain)
	delete(m.landed)
	if m.shadow.dir != "" {
		shadow_close(&m.shadow)
	}
	if m.reg != nil && m.slot >= 0 && m.slot < len(m.reg.mounts) {
		if m.reg.os_ready && m.reg.watcher.unwatch != nil {
			m.reg.watcher.unwatch(m.reg.watcher.data, m.reg, m)
		}
		m.reg.mounts[m.slot] = nil
	}
	if m.reg != nil && m.reg.loop != nil {
		prim.timer_cancel(m.reg.loop, m.timer)
		prim.timer_cancel(m.reg.loop, m.idle_timer)
		prim.timer_cancel(m.reg.loop, m.switch_timer)
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
	mat_owed_clear(m)
	delete(m.owed.files)
	delete(m.owed.dirs)
	held := m.history if m.retained else nil
	if m.history != nil {
		for x, i in m.history.mounts {
			if x == m {
				unordered_remove(&m.history.mounts, i)
				break
			}
		}
	}
	for &w in m.waits {
		image_free(m, &w.img)
	}
	delete(m.waits)
	delete(m.override)
	image_free(m, &m.img)
	for k in m.attrib {
		delete(k, m.allocator)
	}
	delete(m.attrib)
	for u in m.unwatched {
		delete(u, m.allocator)
	}
	delete(m.unwatched)
	for c in m.collided {
		delete(c, m.allocator)
	}
	delete(m.collided)
	delete(m.absent_set)
	for c in m.absent {
		delete(c, m.allocator)
	}
	delete(m.absent)
	for t in m.stale_temps {
		delete(t, m.allocator)
	}
	delete(m.stale_temps)
	for x in m.holds {
		delete(x.path, m.allocator)
	}
	delete(m.holds)
	delete(m.mat_waits)
	for c in m.reshow {
		delete(c, m.allocator)
	}
	delete(m.reshow)
	for k in m.dirty {
		delete(k, m.allocator)
	}
	delete(m.dirty)
	dirty_at_clear(m)
	delete(m.dirty_at)
	for k in m.closed {
		delete(k, m.allocator)
	}
	delete(m.closed)
	for k in m.open_scopes {
		delete(k, m.allocator)
	}
	delete(m.open_scopes)
	delete(m.synced)
	shown_free(&m.shown, m.allocator)
	delete(m.placed)
	for p in m.reverts {
		delete(p.before)
		delete(p.after)
	}
	delete(m.reverts)
	delete(m.saved_synced)
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
	delete(m.branch, m.allocator)
	delete(m.home, m.allocator)
	delete(m.home_line, m.allocator)
	delete(m.switch_to, m.allocator)
	delete(m.switch_from, m.allocator)
	m^ = {}
	history_release(held)
}

mount_wake :: proc(m: ^Mount) -> Error {
	if m.awake {
		if m.history == nil {
			return .None
		}
		err := history_ready(m.history)
		if err == .Reloading {
			mount_reload_retry(m)
		} else if err == .None {
			m.reload_ms = 0
			m.reload_owed = false
		}
		return err
	}
	sp, _ := path_join(m.dir, "shadow", context.temp_allocator)
	format := m.db.format if m.db != nil else odb.Hash_Format.Sha1
	if !shadow_attached(&m.shadow) {
		if m.shadow.dir == "" {
			shadow_open(&m.shadow, m.vfs, sp, format, m.allocator) or_return
			if m.history != nil {
				m.shadow.clock = m.history.opts.clock
			}
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
		if err := history_ready(m.history); err != .None {
			ignore_destroy(&m.ignore)
			shadow_detach(&m.shadow)
			if err == .Reloading {
				mount_reload_retry(m)
			}
			return err
		}
		m.reload_ms = 0
		m.reload_owed = false
	}
	m.awake = true
	if !m.watched {
		registry_ready(m.reg) or_return
		if m.reg.watcher.watch != nil {
			m.reg.watcher.watch(m.reg.watcher.data, m.reg, m) or_return
		}
		m.watched = true
	}
	return .None
}

mount_hibernate :: proc(m: ^Mount) -> Error {
	if !m.awake {
		return .None
	}
	if len(m.dirty) > 0 || m.rescan || len(m.waits) > 0 || len(m.reverts) > 0 {
		return .Busy
	}
	err := shadow_flush(m)
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

Mat_Wait :: struct {
	cb:   proc(m: ^Mount, data: rawptr),
	data: rawptr,
}

mount_on_materialized :: proc(m: ^Mount, cb: proc(m: ^Mount, data: rawptr), data: rawptr) {
	if m.mat_waits == nil {
		m.mat_waits = make([dynamic]Mat_Wait, m.allocator)
	}
	append(&m.mat_waits, Mat_Wait{cb = cb, data = data})
	mount_schedule(m, 0)
}

mount_materialized_cancel :: proc(m: ^Mount, data: rawptr) {
	for i := 0; i < len(m.mat_waits); {
		if m.mat_waits[i].data == data {
			ordered_remove(&m.mat_waits, i)
			continue
		}
		i += 1
	}
}

mount_holds :: proc(m: ^Mount, target: Version) -> bool {
	h := m.history
	if h == nil || history_ready(h) != .None {
		return false
	}
	tl := make([dynamic]crdt.Lv, context.temp_allocator)
	sl := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, target, &tl) != .None || crdt.graph_version_lvs(&h.g, m.synced[:], &sl) != .None {
		return false
	}
	for lv in tl {
		if !crdt.graph_contains(&h.g, sl[:], lv) {
			return false
		}
	}
	return true
}

mount_placed :: proc(m: ^Mount) -> Version {
	if m.has_placed {
		return m.placed[:]
	}
	return mount_synced(m)
}

mount_materialize_soon :: proc(m: ^Mount) {
	m.mat_fast = true
	mount_schedule(m, 0)
}

mount_take_ready :: proc(m: ^Mount) -> bool {
	r := m.mat_ready
	m.mat_ready = false
	return r
}

mount_synced :: proc(m: ^Mount) -> Version {
	return m.synced[:]
}

mount_root :: proc(m: ^Mount) -> string {
	return m.root
}

mount_touch :: proc(m: ^Mount) {
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
				if f.observed {
					mount_schedule(m, 0)
				}
				return
			}
		}
		return
	}
	if rel in m.closed {
		k, _ := delete_key(&m.closed, rel)
		delete(k, m.allocator)
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
		if s == nil {
			dirty_at_note(m, rel, mount_mono_ns(m))
		}
	}
	mount_schedule(m, m.opts.settle_ms)
}

Observe_Since :: struct {
	mono: i64,
	wall: i64,
}

mount_since :: proc(m: ^Mount, age: i64) -> Observe_Since {
	mono := mount_mono_ns(m)
	if mono == 0 {
		return {}
	}
	return {mono = mono - age, wall = history_wall_ns(m.history) - age}
}

@(private)
mount_mono_ns :: proc(m: ^Mount) -> i64 {
	if m.history != nil && m.history.opts.clock.mono_ns != nil {
		return m.history.opts.clock.mono_ns(m.history.opts.clock.data)
	}
	return 0
}

@(private)
dirty_at_note :: proc(m: ^Mount, rel: string, at: i64) {
	if at == 0 || rel in m.dirty_at {
		return
	}
	k, _ := clone_string(rel, m.allocator)
	m.dirty_at[k] = at
}

@(private)
dirty_at_drop :: proc(m: ^Mount, rel: string) {
	if rel in m.dirty_at {
		k, _ := delete_key(&m.dirty_at, rel)
		delete(k, m.allocator)
	}
}

@(private)
_pass_before :: proc(m: ^Mount, since: Observe_Since) -> Error {
	Kept :: struct {
		key:    string,
		at:     i64,
		closed: i64,
	}
	kept := make([dynamic]Kept, context.temp_allocator)
	if since.mono != 0 {
		for k in prim.sorted_keys(m.dirty) {
			if k not_in m.dirty {
				continue
			}
			v := m.dirty[k]
			if at, ok := m.dirty_at[k]; ok && v == nil && at >= since.mono {
				append(&kept, Kept{k, at, m.closed[k] or_else 0})
			}
		}
	}
	for &x in kept {
		x.key, _ = delete_key(&m.dirty, x.key)
		dirty_at_drop(m, x.key)
	}
	err := Error.None
	if len(m.dirty) > 0 {
		err = mount_pass(m, false)
	}
	for x in kept {
		if x.key in m.dirty {
			delete(x.key, m.allocator)
		} else {
			m.dirty[x.key] = nil
		}
		dirty_at_note(m, x.key, x.at)
		if x.closed != 0 && x.key not_in m.closed {
			k, _ := clone_string(x.key, m.allocator)
			m.closed[k] = x.closed
		}
	}
	if len(kept) > 0 {
		mount_schedule(m, m.opts.settle_ms)
	}
	return err
}

@(private)
dirty_at_clear :: proc(m: ^Mount) {
	for k in m.dirty_at {
		delete(k, m.allocator)
	}
	clear(&m.dirty_at)
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
	mount_mark_written(m, rel, scope)
}

mount_mark_written :: proc(m: ^Mount, rel: string, scope: ^Scope) {
	if path_internal(rel) {
		mount_mark(m, rel)
		return
	}
	if v, ok := &m.dirty[rel]; ok {
		v^ = scope
	} else {
		k, _ := clone_string(rel, m.allocator)
		m.dirty[k] = scope
	}
	mount_schedule(m, m.opts.settle_ms)
}

mount_observe_begin :: proc(m: ^Mount, rel: string, scope: ^Scope, done: Observe_Done = nil, ctx: rawptr = nil, since := Observe_Since{}) -> Error {
	logged, err := _observe_begin(m, rel, scope, since)
	if err != .None || !logged {
		if done != nil {
			done(ctx, err)
		}
		return err
	}
	return attrib_log_durable(m, done, ctx)
}

@(private)
_observe_begin :: proc(m: ^Mount, rel: string, scope: ^Scope, since: Observe_Since) -> (logged: bool, err: Error) {
	if scope == nil || path_internal(rel) {
		return false, .None
	}
	a, attributed := m.attrib[rel]
	stale := attributed && !a.used && a.actor != scope.actor
	pending, dirty := m.dirty[rel]
	other := dirty && pending != scope
	owned := attributed && !a.used && a.actor == scope.actor
	claimed := false
	if other && pending == nil && since.mono != 0 {
		if at, marked := m.dirty_at[rel]; marked && at >= since.mono {
			other = false
			claimed = true
			m.dirty[rel] = scope
			dirty_at_drop(m, rel)
		}
	}
	if !stale && !dirty && !owned && m.open_scopes[rel] != scope && mount_disk_unseen(m, rel) {
		other = !_written_since(m, rel, since)
		pending = nil
	}
	if other || (stale && !claimed) {
		if o := m.open_scopes[rel]; o != nil && o != scope {
			m.open_scopes[rel] = nil
		}
		mount_mark_observed(m, rel, pending if other else nil)
		if perr := _pass_before(m, since); perr != .None {
			return false, perr
		}
	}
	if stale {
		if b, still := m.attrib[rel]; still && !b.used && b.actor == a.actor {
			key, _ := delete_key(&m.attrib, rel)
			delete(key, m.allocator)
		}
	}
	if at, closed := m.closed[rel]; closed && since.mono != 0 && at >= since.mono && m.dirty[rel] == scope {
		if rel in m.open_scopes {
			k, _ := delete_key(&m.open_scopes, rel)
			delete(k, m.allocator)
		}
	} else if v, ok := &m.open_scopes[rel]; ok {
		v^ = scope
	} else {
		k, _ := clone_string(rel, m.allocator)
		m.open_scopes[k] = scope
	}
	if c, ok := m.attrib[rel]; ok && c.actor == scope.actor && !c.used {
		return false, .None
	}
	base := observe_base(m, rel, scope)
	attrib_set(m, rel, scope.actor, false, {}, scope.id, base)
	if aerr := attrib_log_append(m, rel, scope.actor, {}, scope.id, base); aerr != .None {
		return false, aerr
	}
	return m.log_fd >= 0, .None
}

attrib_default_actor :: proc(m: ^Mount, path: string) -> prim.Id {
	if a, has := m.attrib[path]; has && (!a.used || m.lost) {
		return unattributed_actor(m.actor) if m.lost else a.actor
	}
	return m.actor
}

@(private)
attrib_log_durable :: proc(m: ^Mount, done: Observe_Done, ctx: rawptr) -> Error {
	if m.log_fd < 0 {
		if done != nil {
			done(ctx, .None)
		}
		return .None
	}
	exec := m.reg.exec if m.reg != nil else Sync_Exec{}
	if exec.run == nil {
		err := from_prim(prim.datasync(m.vfs, m.log_fd))
		if done != nil {
			done(ctx, err)
		}
		return err
	}
	if m.log_sync != nil {
		append(&m.log_next, Obs_Wait{done, ctx})
		return .None
	}
	_log_sync_start(m, exec, Obs_Wait{done, ctx})
	return .None
}

@(private)
_log_sync_start :: proc(m: ^Mount, exec: Sync_Exec, first: Maybe(Obs_Wait)) {
	ls := new(Log_Sync, m.allocator)
	ls^ = {m = m, vfs = m.vfs, fd = m.log_fd, allocator = m.allocator}
	ls.waits = make([dynamic]Obs_Wait, m.allocator)
	if w, ok := first.?; ok {
		append(&ls.waits, w)
	}
	append(&ls.waits, ..m.log_next[:])
	clear(&m.log_next)
	m.log_sync = ls
	exec.run(exec.data, _log_sync_job, _log_sync_done, ls)
}

@(private)
_log_sync_job :: proc(arg: rawptr) {
	ls := cast(^Log_Sync)arg
	ls.err = from_prim(prim.datasync(ls.vfs, ls.fd))
}

@(private)
_log_sync_done :: proc(arg: rawptr) {
	ls := cast(^Log_Sync)arg
	m := ls.m
	if ls.detached {
		prim.close_file(ls.vfs, ls.fd)
	} else if m != nil {
		m.log_sync = nil
	}
	for w in ls.waits {
		if w.done != nil {
			w.done(w.ctx, ls.err)
		}
	}
	delete(ls.waits)
	free(ls, ls.allocator)
	if m != nil && len(m.log_next) > 0 && m.reg != nil && m.reg.exec.run != nil {
		_log_sync_start(m, m.reg.exec, nil)
	}
}

@(private)
_written_since :: proc(m: ^Mount, rel: string, since: Observe_Since) -> bool {
	if since.wall == 0 {
		return false
	}
	d, perr := probe(m, rel)
	return perr == .None && d.kind == .File && stat_racy(d.stat, since.wall)
}

@(private)
mount_disk_unseen :: proc(m: ^Mount, rel: string) -> bool {
	e, found, serr := shadow_get(&m.shadow, rel)
	if serr != .None {
		return false
	}
	if found {
		return !disk_matches(m, rel, e)
	}
	d, perr := probe(m, rel)
	return perr == .None && d.kind != .Missing
}

@(private)
ATTRIB_LOG :: "attrib.log"

@(private)
attrib_log_open :: proc(m: ^Mount) -> Error {
	p, _ := path_join(m.dir, ATTRIB_LOG, context.temp_allocator)
	fd, err := prim.open_file(m.vfs, p, {.Write, .Create}, 0o600)
	if err != .None {
		return from_prim(err)
	}
	m.log_fd = fd
	size, serr := prim.file_size(m.vfs, fd)
	if serr != .None {
		return from_prim(serr)
	}
	if size == 0 {
		return .None
	}
	data := make([]u8, int(size), context.temp_allocator)
	got, rerr := prim.read_at(m.vfs, fd, data, 0)
	if rerr != .None {
		return from_prim(rerr)
	}
	pos := 0
	for pos + 8 <= got {
		n := int(prim.get_u32le(data[pos:]))
		if n <= 0 || pos + 8 + n > got {
			break
		}
		body := data[pos + 8:][:n]
		if u32(xxhash.XXH3_64_with_seed(body, m.log_gen)) != prim.get_u32le(data[pos + 4:]) {
			break
		}
		rd := prim.reader(body)
		path := prim.read_str(&rd)
		actor := prim.read_id(&rd)
		o: odb.Oid
		if prim.reader_remaining(&rd) >= len(o) {
			prim.read_fixed(&rd, o[:])
		}
		sc: prim.Id
		if prim.reader_remaining(&rd) >= len(sc) {
			sc = prim.read_id(&rd)
		}
		base: Step_Base
		step: prim.Id
		if prim.reader_remaining(&rd) > 0 {
			bok: bool
			if base, bok = step_base_read(&rd); !bok {
				break
			}
		}
		at: i64
		if prim.reader_remaining(&rd) >= len(step) {
			step = prim.read_id(&rd)
			at = prim.read_ivarint(&rd)
		}
		if !prim.reader_ok(&rd) {
			break
		}
		if i64(pos) >= m.log_at {
			if actor == {} {
				if path in m.attrib {
					key, _ := delete_key(&m.attrib, path)
					delete(key, m.allocator)
				}
			} else {
				attrib_set(m, path, actor, false, o, sc, base, step, at)
				if o != {} {
					attrib_chain_add(m, path, Attrib_Step{actor, o, sc, base, step, at})
				}
			}
		}
		pos += 8 + n
	}
	m.log_len = i64(pos)
	return .None
}

@(private)
attrib_log_append :: proc(m: ^Mount, rel: string, actor: prim.Id, oid := odb.Oid{}, scope := prim.Id{}, base := Step_Base{}, step := prim.Id{}, at := i64(0)) -> Error {
	if m.log_fd < 0 {
		return save_mount_state(m)
	}
	body := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&body)
	prim.write_str(&w, rel)
	prim.write_id(&w, actor)
	if oid != {} || scope != {} || base.kind != STEP_BASE_NONE || step != {} {
		o := oid
		prim.write_raw(&w, o[:])
	}
	if scope != {} || base.kind != STEP_BASE_NONE || step != {} {
		prim.write_id(&w, scope)
	}
	if base.kind != STEP_BASE_NONE || step != {} {
		step_base_write(&w, base)
	}
	if step != {} {
		prim.write_id(&w, step)
		prim.write_ivarint(&w, at)
	}
	rec := make([]u8, 8 + len(body), context.temp_allocator)
	prim.put_u32le(rec[0:4], u32(len(body)))
	prim.put_u32le(rec[4:8], u32(xxhash.XXH3_64_with_seed(body[:], m.log_gen)))
	copy(rec[8:], body[:])
	from_prim(prim.write_at(m.vfs, m.log_fd, rec, m.log_len)) or_return
	m.log_len += i64(len(rec))
	return .None
}

Attrib_Step :: struct {
	actor: prim.Id,
	oid:   odb.Oid,
	scope: prim.Id,
	base:  Step_Base,
	step:  prim.Id,
	at:    i64,
}

@(private)
attrib_chain_add :: proc(m: ^Mount, path: string, st: Attrib_Step) {
	if m.attrib_chain == nil {
		m.attrib_chain = make(map[string][dynamic]Attrib_Step, m.allocator)
	}
	l, ok := &m.attrib_chain[path]
	if !ok {
		k, _ := clone_string(path, m.allocator)
		m.attrib_chain[k] = make([dynamic]Attrib_Step, m.allocator)
		l = &m.attrib_chain[k]
	}
	if len(l) > 0 && l[len(l) - 1] == st {
		return
	}
	append(l, st)
}

@(private)
attrib_chain_drop :: proc(m: ^Mount, path: string) {
	if _, ok := m.attrib_chain[path]; ok {
		k, l := delete_key(&m.attrib_chain, path)
		delete(l)
		delete(k, m.allocator)
	}
}

@(private)
attrib_covered :: proc(m: ^Mount, img: ^Mount_Image) -> bool {
	if img.chained || len(m.attrib_chain) > 0 || len(img.attrib) != len(m.attrib) {
		return false
	}
	for k in prim.sorted_keys(m.attrib) {
		if k not_in m.attrib {
			continue
		}
		a := m.attrib[k]
		b, ok := img.attrib[k]
		if !ok || b != a {
			return false
		}
	}
	return true
}

@(private)
attrib_log_reset :: proc(m: ^Mount) {
	if m.log_fd < 0 || m.log_len == 0 {
		return
	}
	_ = prim.truncate(m.vfs, m.log_fd, 0)
	m.log_len = 0
}

mount_closed :: proc(m: ^Mount, rel: string) {
	if _, ok := m.open_scopes[rel]; ok {
		k, _ := delete_key(&m.open_scopes, rel)
		delete(k, m.allocator)
	}
	if rel in m.dirty && rel not_in m.closed {
		k, _ := clone_string(rel, m.allocator)
		m.closed[k] = mount_mono_ns(m)
	}
	a, ok := m.attrib[rel]
	if !ok || a.used || m.db == nil {
		return
	}
	abuf: prim.Path_Buf
	abs := abs_path(m, rel, abuf[:])
	st, serr := prim.lstat(m.vfs, abs)
	if serr != .None || st.kind != .File || st.size > m.opts.large_limit {
		return
	}
	data, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
	if rerr != .None {
		return
	}
	prev, has_prev, _ := shadow_get(&m.shadow, rel)
	cleaned, cok := eol_clean(m, rel, data, prev.inode, has_prev && prev.kind == .File)
	if !cok {
		return
	}
	data = cleaned
	oid, werr := odb.write(m.db, .Blob, data)
	if werr != .None || oid == a.oid {
		return
	}
	if has_prev && prev.kind == .File && prev.oid != {} && prev.oid != oid && a.oid != prev.oid && attrib_base_stored(m, prev) {
		attrib_log_append(m, rel, m.actor, prev.oid)
	}
	step := step_new(m)
	at := mount_jlen(m)
	attrib_set(m, rel, a.actor, false, oid, a.scope, a.base, step, at)
	if attrib_log_append(m, rel, a.actor, oid, a.scope, a.base, step, at) == .None {
		attrib_log_durable(m, nil, nil)
	}
}

@(private)
attrib_base_stored :: proc(m: ^Mount, e: Entry) -> bool {
	if odb.exists(m.db, e.oid) {
		return true
	}
	h := m.history
	if h == nil {
		return false
	}
	text, terr := history_text_at(h, e.inode, m.synced[:], context.temp_allocator)
	if terr != .None {
		return false
	}
	got, werr := odb.write(m.db, .Blob, text)
	return werr == .None && got == e.oid
}

observer_installed :: proc(reg: ^Registry) -> bool {
	return reg.observer.start != nil || reg.observer.changed != nil
}

mount_mark_rescan :: proc(m: ^Mount) {
	m.rescan = true
	mount_schedule(m, m.opts.settle_ms)
}

mount_events_lost :: proc(m: ^Mount) {
	mount_mark_rescan(m)
	ready := false
	for &f in m.fences {
		f.arrived = true
		ready ||= fence_ready(f)
	}
	if ready {
		mount_schedule(m, 0)
	}
}

mount_mark_git :: proc(m: ^Mount) {
	m.git_moved = true
	mount_schedule(m, m.opts.settle_ms)
}

RELOAD_RETRY_MAX_MS :: 30_000

@(private)
mount_reload_retry :: proc(m: ^Mount) {
	if len(m.dirty) == 0 && !m.rescan && !m.reload_owed && len(m.switch_to) == 0 && !mount_absent_ready(m) {
		return
	}
	m.reload_ms = max(m.opts.settle_ms, 1) if m.reload_ms == 0 else min(m.reload_ms * 2, RELOAD_RETRY_MAX_MS)
	mount_schedule(m, m.reload_ms)
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
		if mount_lock_held(mm) {
			return
		}
		if mm.reg.on_ready != nil {
			mm.reg.on_ready(mm, mm.reg.ready_data)
		} else {
			mount_run(mm, true)
		}
	})
}

mount_run :: proc(m: ^Mount, may_park := false) -> Error {
	if may_park && warm_park(m) {
		return .None
	}
	err := mount_step(m)
	return .None if err == .Deferred else err
}

@(private)
mount_step :: proc(m: ^Mount) -> Error {
	m.lock_first = false
	fence := false
	for f in m.fences {
		if fence_ready(f) {
			fence = true
		}
	}
	err := mount_pass(m, false, !fence)
	if err == .Deferred {
		mount_touch(m)
		return err
	}
	if err == .None && len(m.reverts) > 0 {
		err = mount_reverts_run(m)
	}
	if err == .None {
		err = mount_materialize(m)
		if err != .None && err != .Reloading {
			mount_reload_retry(m)
		}
	}
	if err == .None && len(m.switch_to) > 0 {
		mount_switch_step(m)
	}
	if err == .Reloading {
		mount_reload_retry(m)
	}
	if fence {
		i := 0
		for i < len(m.fences) {
			f := m.fences[i]
			if fence_ready(f) {
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
	append(&m.fences, Fence{name = string(name), cb = cb, data = data, observed = true})
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
	}
	observer_fence(m, len(m.fences) - 1)
	if fence_ready(m.fences[len(m.fences) - 1]) {
		mount_schedule(m, 0)
	}
	return .None
}

@(private)
observer_wait :: proc(reg: ^Registry) -> Error {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena, 64 << 10) != nil {
		return .No_Memory
	}
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	prim.loop_nest(reg.loop)
	defer prim.loop_unnest(reg.loop)
	return from_prim(prim.loop_step(reg.loop, true))
}

@(private)
observer_fence :: proc(m: ^Mount, i: int) {
	reg := m.reg
	obs := reg.observer
	if obs.fence == nil || reg.loop == nil {
		return
	}
	reg.fence_token += 1
	t := new(Fence_Token, reg.allocator)
	if t == nil {
		return
	}
	t^ = {reg, m, reg.fence_token}
	m.fences[i].token = t.token
	m.fences[i].observed = false
	obs.fence(obs.data, reg, proc(data: rawptr) {
		t := (^Fence_Token)(data)
		reg := t.reg
		defer free(t, reg.allocator)
		for mm in reg.mounts {
			if mm != t.m {
				continue
			}
			for &f in mm.fences {
				if f.token == t.token {
					f.observed = true
					if f.arrived {
						mount_schedule(mm, 0)
					}
					return
				}
			}
			return
		}
	}, t)
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
		waiting := false
		for f in m.fences {
			arrived ||= fence_ready(f)
			waiting ||= f.arrived && !f.observed
		}
		if arrived {
			mount_step(m) or_return
		} else if waiting {
			observer_wait(m.reg) or_return
		} else if !m.watched {
			mount_step(m) or_return
		} else if !m.reg.os_ready || m.reg.watcher.wait == nil || !m.reg.watcher.wait(m.reg.watcher.data, m.reg, 2000) {
			m.rescan = true
			for &f in m.fences {
				f.arrived = true
			}
			mount_step(m) or_return
		}
	}
	return result
}

scope_open :: proc(reg: ^Registry, m: ^Mount, id: prim.Id, actor: prim.Id, pids: []prim.Pid = nil, since := Observe_Since{}) -> ^Scope {
	if m != nil && len(m.dirty) > 0 {
		_pass_before(m, since)
	}
	s := new(Scope, reg.allocator)
	s.id = id
	s.actor = actor
	s.mount = m
	s.allocator = reg.allocator
	s.pins = make([dynamic]Pin, reg.allocator)
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
	scope_unhold(s)
	if s.mount != nil {
		err = mount_sync(s.mount)
		deferred := err == .Deferred
		if deferred {
			err = .None
		}
		if err != .None || deferred {
			sm := s.mount
			for k in prim.sorted_keys(sm.dirty) {
				if k not_in sm.dirty {
					continue
				}
				v := sm.dirty[k]
				if v == s {
					base := Step_Base{}
					if prev, had := sm.attrib[k]; had && prev.scope == s.id && prev.actor == s.actor {
						base = prev.base
					} else {
						base = observe_base(sm, k, s)
					}
					attrib_set(sm, k, s.actor, false, {}, s.id, base)
					attrib_log_append(sm, k, s.actor, {}, s.id, base)
				}
			}
			scope_retire_unwritten(sm, s)
			if sm.log_fd >= 0 && sm.log_len > 0 {
				prim.datasync(sm.vfs, sm.log_fd)
			}
			save_mount_state(sm)
		} else {
			sm := s.mount
			scope_retire_unwritten(sm, s)
			if sm.db != nil {
				_, err = mount_commit(sm, {message = "0ndb: scope"})
			}
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
	scope_release(s)
	delete(s.pids)
	free(s, reg.allocator)
	return err
}

@(private)
scope_retire_unwritten :: proc(m: ^Mount, s: ^Scope) {
	keys := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(m.attrib) {
		a := m.attrib[k]
		if o := m.open_scopes[k]; !a.used && a.actor == s.actor && k not_in m.dirty && (o == nil || o == s) {
			append(&keys, k)
		}
	}
	logged := false
	for k in keys {
		if mount_disk_unseen(m, k) {
			mount_closed(m, k)
			continue
		}
		key, _ := delete_key(&m.attrib, k)
		attrib_log_append(m, key, prim.Id{})
		delete(key, m.allocator)
		logged = true
	}
	if logged {
		attrib_log_durable(m, nil, nil)
	}
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
	data, have := state_read(m) or_return
	if !have {
		mount_new_nonce(m)
		if m.has_git {
			m.head, _ = git_head(m.vfs, m.git, m.allocator)
			m.reflog_pos = git_reflog_len(m.vfs, m.git)
			m.stamp = git_index_stamp(m.vfs, m.git)
		}
		return true, .None
	}
	rd := prim.reader(data)
	if prim.read_u8(&rd) != 1 {
		return false, .Corrupt
	}
	m.actor = prim.read_id(&rd)
	v := decode_version(prim.read_bytes(&rd), context.temp_allocator) or_return
	append(&m.synced, ..v)
	if m.saved_synced == nil {
		m.saved_synced = make([dynamic]crdt.Op_Id, m.allocator)
	}
	clear(&m.saved_synced)
	append(&m.saved_synced, ..v)
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
	if prim.reader_remaining(&rd) > 0 {
		na := prim.read_uvarint(&rd)
		if na > u64(prim.reader_remaining(&rd)) {
			return false, .Corrupt
		}
		for _ in 0 ..< na {
			k := prim.read_str(&rd)
			a := prim.read_id(&rd)
			used := prim.read_bool(&rd)
			o: odb.Oid
			prim.read_fixed(&rd, o[:])
			if prim.reader_ok(&rd) {
				attrib_set(m, k, a, used, o)
			}
		}
	}
	if prim.reader_remaining(&rd) > 0 {
		boot := prim.read_id(&rd)
		clean := prim.read_bool(&rd)
		was_lost := prim.read_bool(&rd) if prim.reader_remaining(&rd) > 0 else false
		if prim.reader_ok(&rd) {
			now := registry_boot(m.reg)
			m.lost = was_lost || (!clean && (boot != now || now == {}))
		}
	}
	if prim.reader_remaining(&rd) > 0 {
		m.nonce = prim.read_id(&rd)
		m.jpos = prim.read_ivarint(&rd)
		m.saved_jpos = m.jpos
	} else {
		mount_new_nonce(m)
	}
	if prim.reader_remaining(&rd) > 0 {
		m.log_gen = prim.read_uvarint(&rd)
	}
	if prim.reader_remaining(&rd) > 0 {
		na := prim.read_uvarint(&rd)
		if na > u64(prim.reader_remaining(&rd)) {
			return false, .Corrupt
		}
		for _ in 0 ..< na {
			a := prim.read_str(&rd)
			if prim.reader_ok(&rd) {
				mount_absent_add(m, a)
			}
		}
	}
	if prim.reader_remaining(&rd) > 0 {
		m.shadow_mark.gen = prim.read_uvarint(&rd)
		m.shadow_mark.end = prim.read_uvarint(&rd)
	}
	if prim.reader_remaining(&rd) > 0 {
		m.adopt_pending = prim.read_bool(&rd)
	}
	if prim.reader_remaining(&rd) > 0 {
		m.log_at = prim.read_ivarint(&rd)
	}
	if prim.reader_remaining(&rd) > 0 {
		nr := prim.read_uvarint(&rd)
		if nr > u64(prim.reader_remaining(&rd)) {
			return false, .Corrupt
		}
		for _ in 0 ..< nr {
			r := prim.read_str(&rd)
			if prim.reader_ok(&rd) {
				mount_reshow_add(m, r)
			}
		}
	}
	if prim.reader_remaining(&rd) > 0 {
		home_s := prim.read_str(&rd)
		branch_s := prim.read_str(&rd)
		if prim.reader_ok(&rd) {
			m.home, _ = clone_string(home_s, m.allocator)
			m.branch, _ = clone_string(branch_s, m.allocator)
		}
	}
	if prim.reader_remaining(&rd) > 0 {
		to_s := prim.read_str(&rd)
		from_s := prim.read_str(&rd)
		if prim.reader_ok(&rd) {
			m.switch_to, _ = clone_string(to_s, m.allocator)
			m.switch_from, _ = clone_string(from_s, m.allocator)
		}
		if prim.reader_remaining(&rd) > 0 {
			m.switch_phase = prim.read_u8(&rd)
		}
		if prim.reader_remaining(&rd) > 0 {
			ns := prim.read_uvarint(&rd)
			if ns > u64(prim.reader_remaining(&rd)) {
				return false, .Corrupt
			}
			for _ in 0 ..< ns {
				k := prim.read_str(&rd)
				sc := prim.read_id(&rd)
				if a, ok := &m.attrib[k]; ok && prim.reader_ok(&rd) {
					a.scope = sc
				}
			}
		}
	}
	rec_head: Git_Head
	rec_reflog: i64
	if prim.reader_remaining(&rd) > 0 {
		rec_head.branch = prim.read_str(&rd)
		rec_head.commit = prim.read_str(&rd)
		rec_reflog = prim.read_ivarint(&rd)
	}
	if prim.reader_remaining(&rd) > 0 {
		nr := prim.read_uvarint(&rd)
		if nr > u64(prim.reader_remaining(&rd)) {
			return false, .Corrupt
		}
		for _ in 0 ..< nr {
			k := prim.read_str(&rd)
			row := decode_version(prim.read_bytes(&rd), context.temp_allocator) or_return
			if !prim.reader_ok(&rd) {
				return false, .Corrupt
			}
			shown_put(&m.shown, k, row, m.allocator)
		}
	}
	if prim.reader_remaining(&rd) > 0 {
		ns := prim.read_uvarint(&rd)
		if ns > u64(prim.reader_remaining(&rd)) {
			return false, .Corrupt
		}
		for _ in 0 ..< ns {
			k := prim.read_str(&rd)
			step := prim.read_id(&rd)
			at := prim.read_ivarint(&rd)
			base, bok := step_base_read(&rd)
			if !bok || !prim.reader_ok(&rd) {
				return false, .Corrupt
			}
			if a, ok := &m.attrib[k]; ok {
				a.step = step
				a.at = at
				a.base = base
			}
		}
	}
	m.jpend = m.jpos
	if !prim.reader_ok(&rd) {
		return false, .Corrupt
	}
	switch_record_load(m, rec_head, rec_reflog)
	return false, .None
}

@(private)
mount_new_nonce :: proc(m: ^Mount) {
	prim.random_fill(m.reg.random if m.reg != nil else prim.Random{}, m.nonce[:])
	m.jpos = 0
	m.jpend = 0
}

@(private)
commit_mark :: proc(m: ^Mount) -> []u8 {
	out := make([]u8, 17, context.temp_allocator)
	out[0] = fshist.TOP_MOUNT
	n := m.nonce
	copy(out[1:], n[:])
	return out
}

@(private)
mount_jlen :: proc(m: ^Mount) -> i64 {
	if m.history != nil && m.history.awake {
		return journal.journal_durable_len(&m.history.journal)
	}
	return m.jpend
}

Shadow_Mark :: struct {
	gen: u64,
	end: u64,
}

@(private)
mount_shadow_reconcile :: proc(m: ^Mount) -> Error {
	g, e := shadow_end(&m.shadow)
	if m.shadow_mark.end != 0 && g == m.shadow_mark.gen && e > m.shadow_mark.end {
		shadow_rollback(&m.shadow, m.shadow_mark.end) or_return
	}
	m.img.shadow = _shadow_mark_of(&m.shadow)
	return .None
}

@(private)
_shadow_mark_of :: proc "contextless" (s: ^Shadow) -> (mk: Shadow_Mark) {
	mk.gen, mk.end = shadow_end(s)
	return
}

Mount_Image :: struct {
	synced:     [dynamic]crdt.Op_Id,
	jpos:       i64,
	branch:     string,
	commit:     string,
	reflog_pos: i64,
	stamp:      Index_Stamp,
	imported:   bool,
	adopt_pending: bool,
	attrib:     map[string]Attrib,
	log_at:     i64,
	shadow:     Shadow_Mark,
	chained:    bool,
	line:       string,
	absent:     [dynamic]string,
	shown:      map[string][]crdt.Op_Id,
}

Mount_Wait :: struct {
	mark: u64,
	img:  Mount_Image,
}

@(private)
names_durable :: proc(db: ^odb.Odb) -> Error {
	if db == nil {
		return .None
	}
	return from_odb(odb.install_staged(db))
}

@(private)
image_take :: proc(m: ^Mount, img: ^Mount_Image) {
	image_free(m, img)
	img.synced = make([dynamic]crdt.Op_Id, m.allocator)
	append(&img.synced, ..m.synced[:])
	img.branch, _ = clone_string(m.head.branch, m.allocator)
	img.line, _ = clone_string(m.branch, m.allocator)
	img.commit, _ = clone_string(m.head.commit, m.allocator)
	img.reflog_pos = m.reflog_pos
	img.stamp = m.stamp
	img.imported = m.imported
	img.adopt_pending = m.adopt_pending
	img.jpos = m.jpos if m.mat_held else m.jpend
	img.shadow = m.shadow_mark
	if shadow_attached(&m.shadow) {
		img.shadow.gen, img.shadow.end = shadow_end(&m.shadow)
	}
	img.attrib = make(map[string]Attrib, m.allocator)
	for k, a in prim.unordered(m.attrib) {
		key, _ := clone_string(k, m.allocator)
		img.attrib[key] = a
	}
	img.chained = len(m.attrib_chain) > 0
	img.log_at = m.log_at if img.chained else m.log_len
	img.absent = make([dynamic]string, m.allocator)
	for a in m.absent {
		c, _ := clone_string(a, m.allocator)
		append(&img.absent, c)
	}
	for k, v in prim.unordered(m.shown) {
		shown_put(&img.shown, k, v, m.allocator)
	}
}

@(private)
image_free :: proc(m: ^Mount, img: ^Mount_Image) {
	delete(img.synced)
	delete(img.branch, m.allocator)
	delete(img.line, m.allocator)
	delete(img.commit, m.allocator)
	for k in img.attrib {
		delete(k, m.allocator)
	}
	delete(img.attrib)
	for a in img.absent {
		delete(a, m.allocator)
	}
	delete(img.absent)
	shown_free(&img.shown, m.allocator)
	img^ = {}
}

@(private)
mount_durable_now :: proc(m: ^Mount) -> bool {
	h := m.history
	fp := history_fp(h)
	if fp != h.mark_fp {
		h.mark += 1
		h.mark_fp = fp
		h.content_mark = h.mark
	}
	if (h.content_mark if m.mat_fast else h.mark) <= h.durable {
		return true
	}
	if !m.mat_wait {
		m.mat_wait = true
		mount_schedule(m, 0)
	}
	return false
}

@(private)
shadow_flush :: proc(m: ^Mount) -> Error {
	mat_settle_owed(m) or_return
	held := m.shadow.hold
	m.shadow.hold = false
	defer m.shadow.hold = held
	return shadow_persist(&m.shadow)
}

@(private)
Attrib :: struct {
	actor: prim.Id,
	used:  bool,
	oid:   odb.Oid,
	scope: prim.Id,
	base:  Step_Base,
	step:  prim.Id,
	at:    i64,
}

STEP_BASE_NONE :: u8(0)
STEP_BASE_VERSION :: u8(1)
STEP_BASE_CHAIN :: u8(2)
STEP_BASE_CONTENT :: u8(3)
STEP_BASE_HEADS :: 4

Step_Base :: struct {
	kind: u8,
	oid:  odb.Oid,
	n:    u8,
	ver:  [STEP_BASE_HEADS]crdt.Op_Id,
}

@(private)
attrib_set :: proc(m: ^Mount, path: string, actor: prim.Id, used := false, oid := odb.Oid{}, scope := prim.Id{}, base := Step_Base{}, step := prim.Id{}, at := i64(0)) {
	if p, ok := &m.attrib[path]; ok {
		p^ = Attrib{actor, used, oid, scope, base, step, at}
		return
	}
	k, _ := clone_string(path, m.allocator)
	m.attrib[k] = Attrib{actor, used, oid, scope, base, step, at}
}

@(private)
landed_read :: proc(m: ^Mount) -> Error {
	clear(&m.landed)
	m.landed_gone = false
	from := max(i64)
	for _, l in prim.unordered(m.attrib_chain) {
		for st in l {
			if st.step != {} {
				from = min(from, st.at)
			}
		}
	}
	for _, a in prim.unordered(m.attrib) {
		if a.step != {} {
			from = min(from, a.at)
		}
	}
	if from == max(i64) {
		return .None
	}
	return history_steps(m.history, min(from, m.jpos), &m.landed, &m.landed_gone)
}

@(private)
step_new :: proc(m: ^Mount) -> (id: prim.Id) {
	prim.random_fill(m.reg.random if m.reg != nil else prim.Random{}, id[:])
	return
}

@(private)
step_base_write :: proc(w: ^prim.Writer, base: Step_Base) {
	prim.write_u8(w, base.kind)
	if base.kind == STEP_BASE_NONE {
		return
	}
	bo := base.oid
	prim.write_raw(w, bo[:])
	prim.write_uvarint(w, u64(base.n))
	bv := base.ver
	for id in bv[:base.n] {
		prim.write_id(w, id.actor)
		prim.write_uvarint(w, id.seq)
	}
}

@(private)
step_base_read :: proc(rd: ^prim.Reader) -> (base: Step_Base, ok: bool) {
	base.kind = prim.read_u8(rd)
	if base.kind == STEP_BASE_NONE {
		return base, prim.reader_ok(rd)
	}
	if base.kind > STEP_BASE_CONTENT {
		return {}, false
	}
	prim.read_fixed(rd, base.oid[:])
	n := prim.read_uvarint(rd)
	if n > STEP_BASE_HEADS {
		return {}, false
	}
	base.n = u8(n)
	for i in 0 ..< int(n) {
		base.ver[i].actor = prim.read_id(rd)
		base.ver[i].seq = prim.read_uvarint(rd)
	}
	return base, prim.reader_ok(rd)
}

@(private)
step_base_version :: proc(v: []crdt.Op_Id, oid: odb.Oid) -> (b: Step_Base) {
	if len(v) == 0 || len(v) > STEP_BASE_HEADS {
		return Step_Base{kind = STEP_BASE_CONTENT, oid = oid}
	}
	b.kind = STEP_BASE_VERSION
	b.oid = oid
	b.n = u8(len(v))
	copy(b.ver[:], v)
	return
}

@(private)
observe_base :: proc(m: ^Mount, rel: string, scope: ^Scope) -> Step_Base {
	h := m.history
	if h == nil || m.db == nil {
		return {}
	}
	if p := _pin(scope, rel, false); p != nil {
		if p.has_read {
			if t, err := history_text_at(h, p.read_inode, p.read[:], context.temp_allocator); err == .None && _content_hash(t) == p.read_hash {
				if oid, werr := odb.write(m.db, .Blob, t); werr == .None {
					return step_base_version(p.read[:], oid)
				}
			}
		}
		if p.has_write && p.has_base {
			if t, err := history_text_at(h, p.write_inode, p.write[:], context.temp_allocator); err == .None && _content_hash(t) == p.base_hash {
				if oid, werr := odb.write(m.db, .Blob, t); werr == .None {
					return step_base_version(p.write[:], oid)
				}
			}
		}
	}
	e, found, serr := shadow_get(&m.shadow, rel)
	if serr != .None || !found || e.kind != .File {
		return {}
	}
	if !disk_matches(m, rel, e) {
		abuf: prim.Path_Buf
		abs := abs_path(m, rel, abuf[:])
		st, lerr := prim.lstat(m.vfs, abs)
		if lerr != .None || st.kind != .File || st.size > m.opts.large_limit {
			return Step_Base{kind = STEP_BASE_CHAIN}
		}
		data, rerr := prim.read_file(m.vfs, abs, context.temp_allocator)
		if rerr != .None {
			return Step_Base{kind = STEP_BASE_CHAIN}
		}
		clean, cok := eol_clean(m, rel, data, e.inode, true)
		if !cok {
			return Step_Base{kind = STEP_BASE_CHAIN}
		}
		oid, werr := odb.write(m.db, .Blob, clean)
		if werr != .None {
			return Step_Base{kind = STEP_BASE_CHAIN}
		}
		return Step_Base{kind = STEP_BASE_CHAIN, oid = oid}
	}
	at, text, terr := _pin_at(m, rel, e.inode)
	if terr != .None {
		return {}
	}
	oid, werr := odb.write(m.db, .Blob, text)
	if werr != .None {
		return {}
	}
	if oid != e.oid {
		if e.oid != {} && odb.exists(m.db, e.oid) {
			return Step_Base{kind = STEP_BASE_CONTENT, oid = e.oid}
		}
		return {}
	}
	return step_base_version(at, oid)
}

@(private)
attrib_prune :: proc(m: ^Mount) {
	if len(m.attrib) == 0 {
		return
	}
	drop := make([dynamic]string, context.temp_allocator)
	for k in prim.sorted_keys(m.attrib) {
		if k not_in m.attrib {
			continue
		}
		a := m.attrib[k]
		if a.used && k not_in m.dirty && m.open_scopes[k] == nil {
			append(&drop, k)
		}
	}
	for k in drop {
		key, _ := delete_key(&m.attrib, k)
		delete(key, m.allocator)
	}
}

mount_settle :: proc(m: ^Mount) -> Error {
	h := m.history
	fp := history_fp(h)
	if fp == h.mark_fp && h.mark <= h.settled && len(m.waits) == 0 {
		shadow_flush(m) or_return
		image_take(m, &m.img)
		clear(&m.intents)
		if !m.mat_held {
			m.jpos = m.jpend
		}
		attrib_prune(m)
		return save_mount_state(m)
	}
	if fp != h.mark_fp {
		h.mark += 1
		h.mark_fp = fp
		h.content_mark = h.mark
	}
	shadow_flush(m) or_return
	if n := len(m.waits); n > 0 && m.waits[n - 1].mark == h.mark {
		image_take(m, &m.waits[n - 1].img)
	} else {
		w := Mount_Wait{mark = h.mark}
		image_take(m, &w.img)
		append(&m.waits, w)
	}
	m.shadow.hold = true
	return save_mount_state(m)
}

@(private)
mount_ack :: proc(m: ^Mount) -> Error {
	h := m.history
	if m.mat_wait && (h.content_mark if m.mat_fast else h.mark) <= h.durable {
		m.mat_wait = false
		m.mat_ready = true
		mount_schedule(m, 0)
	}
	n := 0
	for n < len(m.waits) && m.waits[n].mark <= h.settled {
		n += 1
	}
	if n == 0 {
		return .None
	}
	image_free(m, &m.img)
	m.img = m.waits[n - 1].img
	for i in 0 ..< n - 1 {
		image_free(m, &m.waits[i].img)
	}
	remove_range(&m.waits, 0, n)
	if len(m.waits) == 0 && m.awake {
		shadow_flush(m) or_return
		clear(&m.intents)
		m.jpos = m.img.jpos
		attrib_prune(m)
	}
	return save_mount_state(m)
}

save_mount_state :: proc(m: ^Mount) -> Error {
	img := &m.img
	synced := m.img.synced[:]
	jpos := m.jpos
	if shadow_attached(&m.shadow) && m.shadow.owed && shadow_dirty(&m.shadow) && m.saved_synced != nil {
		synced = m.saved_synced[:]
		jpos = min(jpos, m.saved_jpos)
	}
	buf := make([dynamic]u8, context.temp_allocator)
	vb := make([dynamic]u8, context.temp_allocator)
	encode_version(&vb, synced)
	w := prim.writer(&buf)
	prim.write_u8(&w, 1)
	prim.write_id(&w, m.actor)
	prim.write_bytes(&w, vb[:])
	prim.write_str(&w, img.branch)
	prim.write_str(&w, img.commit)
	prim.write_ivarint(&w, img.reflog_pos)
	prim.write_ivarint(&w, img.stamp.mtime_ns)
	prim.write_ivarint(&w, img.stamp.size)
	prim.write_uvarint(&w, img.stamp.ino)
	prim.write_uvarint(&w, u64(len(m.intents)))
	for it in m.intents {
		prim.write_id(&w, it.actor)
		prim.write_uvarint(&w, it.seq)
		prim.write_uvarint(&w, it.n)
	}
	prim.write_bool(&w, img.imported)
	live := m.log_fd < 0
	attrib := m.attrib if live else img.attrib
	covered := live || attrib_covered(m, img)
	prim.write_uvarint(&w, u64(len(attrib)))
	for k in sorted_strings(attrib) {
		a := attrib[k]
		prim.write_str(&w, k)
		prim.write_id(&w, a.actor)
		prim.write_bool(&w, a.used)
		o := a.oid
		prim.write_raw(&w, o[:])
	}
	boot := registry_boot(m.reg) if m.reg != nil else prim.Id{}
	prim.write_id(&w, boot)
	prim.write_bool(&w, m.clean)
	prim.write_bool(&w, m.lost)
	prim.write_id(&w, m.nonce)
	prim.write_ivarint(&w, jpos)
	gen := m.log_gen + 1 if covered && m.log_len > 0 else m.log_gen
	prim.write_uvarint(&w, gen)
	owed := make([dynamic]string, context.temp_allocator)
	owed_set := make(map[string]bool, context.temp_allocator)
	for list in ([][]string{img.absent[:], m.absent[:]}) {
		for a in list {
			if a in owed_set {
				continue
			}
			owed_set[a] = true
			append(&owed, a)
		}
	}
	prim.write_uvarint(&w, u64(len(owed)))
	for a in owed {
		prim.write_str(&w, a)
	}
	m.shadow_mark = img.shadow
	prim.write_uvarint(&w, m.shadow_mark.gen)
	prim.write_uvarint(&w, m.shadow_mark.end)
	prim.write_bool(&w, img.adopt_pending)
	prim.write_ivarint(&w, 0 if covered else img.log_at)
	prim.write_uvarint(&w, u64(len(m.reshow)))
	for r in m.reshow {
		prim.write_str(&w, r)
	}
	prim.write_str(&w, m.home)
	prim.write_str(&w, img.line if len(img.line) > 0 else m.branch)
	rec := switch_record(m, img)
	prim.write_str(&w, rec.to)
	prim.write_str(&w, rec.from)
	prim.write_u8(&w, rec.phase)
	scoped := make([dynamic]string, context.temp_allocator)
	for k in sorted_strings(attrib) {
		if attrib[k].scope != {} {
			append(&scoped, k)
		}
	}
	prim.write_uvarint(&w, u64(len(scoped)))
	for k in scoped {
		prim.write_str(&w, k)
		prim.write_id(&w, attrib[k].scope)
	}
	prim.write_str(&w, rec.head.branch)
	prim.write_str(&w, rec.head.commit)
	prim.write_ivarint(&w, rec.reflog_pos)
	prim.write_uvarint(&w, u64(len(img.shown)))
	for k in sorted_strings(img.shown) {
		rb := make([dynamic]u8, context.temp_allocator)
		encode_version(&rb, img.shown[k])
		prim.write_str(&w, k)
		prim.write_bytes(&w, rb[:])
	}
	stepped := make([dynamic]string, context.temp_allocator)
	for k in sorted_strings(attrib) {
		if attrib[k].step != {} || attrib[k].base.kind != STEP_BASE_NONE {
			append(&stepped, k)
		}
	}
	prim.write_uvarint(&w, u64(len(stepped)))
	for k in stepped {
		prim.write_str(&w, k)
		prim.write_id(&w, attrib[k].step)
		prim.write_ivarint(&w, attrib[k].at)
		step_base_write(&w, attrib[k].base)
	}
	sum := xxhash.XXH3_64_with_seed(buf[:], 0) | 1
	if sum == m.saved {
		return .None
	}
	m.saved = 0
	state_write(m, buf[:]) or_return
	m.saved = sum
	m.saved_jpos = jpos
	if raw_data(synced) != raw_data(m.saved_synced[:]) {
		if m.saved_synced == nil {
			m.saved_synced = make([dynamic]crdt.Op_Id, m.allocator)
		}
		clear(&m.saved_synced)
		append(&m.saved_synced, ..synced)
	}
	m.log_gen = gen
	if covered {
		attrib_log_reset(m)
		img.log_at = 0
	}
	if shadow_attached(&m.shadow) && !shadow_dirty(&m.shadow) && shadow_wants_compact(&m.shadow) && len(m.waits) == 0 && img.shadow == _shadow_mark_of(&m.shadow) {
		shadow_compact(&m.shadow) or_return
		img.shadow = _shadow_mark_of(&m.shadow)
		return save_mount_state(m)
	}
	return .None
}

@(private)
intents_dedupe :: proc(list: ^[dynamic]Intent) {
	Key :: struct {
		actor: prim.Id,
		seq:   u64,
	}
	at := make(map[Key]int, context.temp_allocator)
	kept := 0
	for i in 0 ..< len(list) {
		it := list[i]
		if j, seen := at[Key{it.actor, it.seq}]; seen {
			list[j].n = max(list[j].n, it.n)
			continue
		}
		at[Key{it.actor, it.seq}] = kept
		list[kept] = it
		kept += 1
	}
	resize(list, kept)
}

mount_recover :: proc(m: ^Mount) -> Error {
	h := m.history
	if h != nil {
		landed_read(m) or_return
		history_marked(h, m.jpos, commit_mark(m), &m.intents) or_return
	}
	intents_dedupe(&m.intents)
	if len(m.intents) == 0 {
		return .None
	}
	recovered := false
	ends := make([dynamic]crdt.Lv, context.temp_allocator)
	touched := make(map[fstree.Inode_Id]bool, context.temp_allocator)
	by_intent := make([dynamic]Recovered_Intent, context.temp_allocator)
	lost := make([dynamic]Lost_Range, context.temp_allocator)
	have := make([dynamic]crdt.Lv, context.temp_allocator)
	if crdt.graph_version_lvs(&h.g, m.synced[:], &have) != .None {
		return .Corrupt
	}
	for it in m.intents {
		lv, ok := crdt.graph_lv(&h.g, crdt.Op_Id{it.actor, it.seq})
		if !ok {
			append(&lost, Lost_Range{crdt.graph_intern(&h.g, it.actor), it.seq, it.seq + it.n})
			continue
		}
		if end, known := crdt.graph_lv(&h.g, crdt.Op_Id{it.actor, it.seq + it.n - 1}); known && crdt.graph_contains(&h.g, have[:], end) {
			continue
		}
		spans := []crdt.Lv_Span{{lv = lv, len = int(it.n)}}
		spans_touched(h, spans, &touched) or_return
		recovered = true
		if end, known := crdt.graph_lv(&h.g, crdt.Op_Id{it.actor, it.seq + it.n - 1}); known {
			append(&ends, end)
			own := make(map[fstree.Inode_Id]bool, context.temp_allocator)
			spans_touched(h, spans, &own) or_return
			append(&by_intent, Recovered_Intent{end = crdt.Op_Id{it.actor, it.seq + it.n - 1}, touched = own})
		}
	}
	if len(lost) > 0 {
		drop_lost(m, "", lost[:]) or_return
	}
	if recovered {
		target := have[:]
		if len(ends) > 0 {
			both := make([dynamic]crdt.Lv, context.temp_allocator)
			crdt.version_union(&h.g, have[:], ends[:], &both)
			target = both[:]
			only_a := make([dynamic]crdt.Lv_Span, context.temp_allocator)
			only_b := make([dynamic]crdt.Lv_Span, context.temp_allocator)
			crdt.graph_diff(&h.g, have[:], target, &only_a, &only_b)
			spans_touched(h, only_b[:], &touched) or_return
		}
		snap := version_snapshot(h, target) or_return
		defer fstree.snapshot_destroy(&snap)
		for ino in sorted_inodes(touched) {
			info, found, ierr := fstree.info(&snap, ino, context.temp_allocator)
			if ierr != nil {
				return .Corrupt
			}
			old, oe, had := shadow_by_inode(&m.shadow, ino, context.temp_allocator) or_return
			if !found || !info.present {
				if had && !(recover_orphan(m, old, oe, ino, by_intent[:]) or_return) {
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
			e := Entry{inode = ino, kind = info.kind}
			if info.kind == .File {
				recover_at(m, &e, p, ino, target, by_intent[:], oe if had && oe.inode == ino else Entry{}, have[:]) or_return
			}
			shadow_put(&m.shadow, p, e) or_return
		}
		if len(ends) > 0 {
			v := crdt.graph_version_ids(&h.g, target, context.temp_allocator)
			clear(&m.synced)
			append(&m.synced, ..v)
		}
	}
	m.jpend = mount_jlen(m)
	history_trim(h)
	return mount_settle(m)
}

@(private)
Recovered_Intent :: struct {
	end:     crdt.Op_Id,
	touched: map[fstree.Inode_Id]bool,
}

@(private)
recover_orphan :: proc(m: ^Mount, p: string, e: Entry, ino: fstree.Inode_Id, intents: []Recovered_Intent) -> (kept: bool, err: Error) {
	h := m.history
	if e.kind != .File {
		return false, .None
	}
	d := probe(m, p) or_return
	if d.kind != .File {
		return false, .None
	}
	data, oid, binary, ok := read_content(m, p, d.stat, ino, true) or_return
	if !ok || binary || .Opaque in tree_flags(h, ino) {
		return false, .None
	}
	#reverse for it in intents {
		if !it.touched[ino] {
			continue
		}
		at := [1]crdt.Op_Id{it.end}
		t, terr := history_text_at(h, ino, at[:], context.temp_allocator)
		if terr != .None || string(t) != string(data) {
			continue
		}
		one := [1]fstree.Op_Id{op_inode(h, it.end)}
		ne := e
		ne.ver = shadow_version_add(&m.shadow, one[:]) or_return
		ne.stat = d.stat
		ne.oid = oid
		shadow_put(&m.shadow, p, ne) or_return
		mount_absent_add(m, p)
		return true, .None
	}
	return false, .None
}

@(private)
recover_at :: proc(m: ^Mount, e: ^Entry, p: string, ino: fstree.Inode_Id, target: []crdt.Lv, intents: []Recovered_Intent, was: Entry, have: []crdt.Lv) -> Error {
	h := m.history
	d := probe(m, p) or_return
	if d.kind != .File {
		return .None
	}
	data, oid, binary, ok := read_content(m, p, d.stat, ino, true) or_return
	if !ok || binary || .Opaque in tree_flags(h, ino) {
		return .None
	}
	want := history_text_at(h, ino, crdt.graph_version_ids(&h.g, target, context.temp_allocator), context.temp_allocator) or_return
	if string(want) == string(data) {
		return .None
	}
	#reverse for it in intents {
		if !it.touched[ino] {
			continue
		}
		at := [1]crdt.Op_Id{it.end}
		t, terr := history_text_at(h, ino, at[:], context.temp_allocator)
		if terr != .None || string(t) != string(data) {
			continue
		}
		one := [1]fstree.Op_Id{op_inode(h, it.end)}
		e.ver = shadow_version_add(&m.shadow, one[:]) or_return
		e.stat = d.stat
		e.oid = oid
		mount_reshow_add(m, p)
		return .None
	}
	if was.ver != 0 {
		if ids, vok := shadow_version(&m.shadow, was); vok && len(ids) > 0 {
			v := make([]crdt.Op_Id, len(ids), context.temp_allocator)
			for id, i in ids {
				v[i] = inode_op(h, id)
			}
			if t, terr := history_text_at(h, ino, v, context.temp_allocator); terr == .None && string(t) == string(data) {
				e.ver = was.ver
				e.stat = d.stat
				e.oid = oid
				mount_reshow_add(m, p)
				return .None
			}
		}
	}
	held := crdt.graph_version_ids(&h.g, have, context.temp_allocator)
	if t, terr := history_text_at(h, ino, held, context.temp_allocator); terr == .None && string(t) == string(data) {
		at := make([]fstree.Op_Id, len(held), context.temp_allocator)
		for id, i in held {
			at[i] = op_inode(h, id)
		}
		e.ver = shadow_version_add(&m.shadow, at) or_return
		e.stat = d.stat
		e.oid = oid
		mount_reshow_add(m, p)
	}
	return .None
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

STATE_MAGIC :: u64(0x31736d62646e3030)
STATE_HEADER :: 28

@(private)
state_path :: proc(m: ^Mount, slot: u64) -> string {
	p, _ := path_join(m.dir, "state.1" if slot & 1 == 1 else "state.0", context.temp_allocator)
	return p
}

@(private)
state_write :: proc(m: ^Mount, payload: []u8) -> Error {
	seq := m.state_seq + 1
	out := make([]u8, STATE_HEADER + len(payload), context.temp_allocator)
	prim.put_u64le(out[0:8], STATE_MAGIC)
	prim.put_u64le(out[8:16], seq)
	prim.put_u32le(out[16:20], u32(len(payload)))
	copy(out[STATE_HEADER:], payload)
	prim.put_u64le(out[20:28], xxhash.XXH3_64_with_seed(out[8:20], xxhash.XXH3_64_with_seed(payload, 0)))
	p := state_path(m, seq)
	created := false
	fd, oerr := prim.open_file(m.vfs, p, {.Write})
	if oerr == .Not_Found {
		fd, oerr = prim.open_file(m.vfs, p, {.Write, .Create}, 0o600)
		created = true
	}
	from_prim(oerr) or_return
	werr := prim.write_at(m.vfs, fd, out, 0)
	if werr == .None {
		werr = prim.datasync(m.vfs, fd)
	}
	cerr := prim.close_file(m.vfs, fd)
	from_prim(werr) or_return
	from_prim(cerr) or_return
	if created {
		from_prim(prim.sync_dir(m.vfs, m.dir)) or_return
	}
	m.state_seq = seq
	if m.legacy {
		lp, _ := path_join(m.dir, "mount", context.temp_allocator)
		if prim.remove(m.vfs, lp) == .None {
			prim.sync_dir(m.vfs, m.dir)
		}
		m.legacy = false
	}
	return .None
}

@(private)
state_read :: proc(m: ^Mount) -> (payload: []u8, found: bool, err: Error) {
	best: u64
	for slot in u64(0) ..< 2 {
		data, rerr := prim.read_file(m.vfs, state_path(m, slot), context.temp_allocator)
		if rerr == .Not_Found {
			continue
		}
		from_prim(rerr) or_return
		if len(data) < STATE_HEADER || prim.get_u64le(data[0:8]) != STATE_MAGIC {
			continue
		}
		seq := prim.get_u64le(data[8:16])
		n := int(prim.get_u32le(data[16:20]))
		if n > len(data) - STATE_HEADER || seq & 1 != slot {
			continue
		}
		body := data[STATE_HEADER:][:n]
		if xxhash.XXH3_64_with_seed(data[8:20], xxhash.XXH3_64_with_seed(body, 0)) != prim.get_u64le(data[20:28]) {
			continue
		}
		if !found || seq > best {
			best = seq
			payload = body
			found = true
		}
	}
	if found {
		m.state_seq = best
		return payload, true, .None
	}
	lp, _ := path_join(m.dir, "mount", context.temp_allocator)
	data, rerr := prim.read_file(m.vfs, lp, context.temp_allocator)
	if rerr == .Not_Found {
		return nil, false, .None
	}
	from_prim(rerr) or_return
	m.legacy = true
	return data, true, .None
}

@(private)
branch_key :: proc(m: ^Mount, head: Git_Head, allocator: runtime.Allocator) -> string {
	if len(head.branch) > 0 {
		if head.branch == m.home {
			return m.home_line
		}
		out, _ := strings.concatenate({"git:", head.branch}, allocator)
		return out
	}
	if len(head.commit) > 0 && len(m.home) > 0 {
		out, _ := strings.concatenate({"git:detached:", head.commit}, allocator)
		return out
	}
	return m.home_line
}

@(private)
mount_line_pseudo :: proc(mount: prim.Id, line: string) -> (pseudo: prim.Id) {
	ctx: blake2b.Context
	blake2b.init(&ctx, 16)
	tag := "0ndb mount line"
	blake2b.update(&ctx, transmute([]u8)tag)
	id := mount
	blake2b.update(&ctx, id[:])
	blake2b.update(&ctx, transmute([]u8)line)
	blake2b.final(&ctx, pseudo[:])
	return
}

mount_line_actor :: proc(m: ^Mount) -> Error {
	self := m.history.self if m.history != nil else m.actor
	if m.line == m.home_line {
		m.actor = fshist.ingestion_actor(self, m.id)
		return .None
	}
	pseudo := mount_line_pseudo(m.id, m.line)
	m.actor = fshist.ingestion_actor(self, pseudo)
	if m.history != nil {
		history_register_actor(m.history, m.actor, pseudo) or_return
	}
	return .None
}

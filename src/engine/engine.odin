package engine

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import "../convo"
import "../fs"
import "../http"
import "../obj"
import "../odb"
import "../pack"
import "../prim"
import "../search"
import osync "../sync"

Error :: enum u8 {
	None,
	Pending,
	Not_Found,
	Exists,
	Invalid,
	Busy,
	Closed,
	Offline,
	Permission,
	Forged,
	Quarantined,
	Missing,
	Corrupt,
	Limit,
	Too_Large,
	Unsupported,
	Not_Assigned,
	No_Space,
	No_Memory,
	Io,
	Conflict,
}

Kind :: obj.Kind

Object :: struct {
	space: prim.Id,
	id:    prim.Id,
}

Rid :: obj.Rid

Durability :: enum u8 {
	Async,
	Deferred,
}

Log_Level :: enum u8 {
	Debug,
	Info,
	Warn,
	Error,
}

Log :: struct {
	data:  rawptr,
	write: proc(data: rawptr, level: Log_Level, msg: string),
}

Clock :: prim.Clock

Id_Source :: struct {
	data: rawptr,
	next: proc(data: rawptr) -> prim.Id,
}

Spawner :: struct {
	data:  rawptr,
	spawn: proc(data: rawptr, argv: []string, cwd: string, env: []string, new_group: bool) -> (prim.Child, prim.Error),
}

Peer :: struct {
	space:        prim.Id,
	relay:        string,
	relay_public: osync.Public_Key,
}

Link :: distinct u64

Transport :: struct {
	data:  rawptr,
	open:  proc(data: rawptr, e: ^Engine, link: Link, peer: Peer) -> (conn: rawptr, err: Error),
	send:  proc(data: rawptr, conn: rawptr, bytes: []u8) -> (int, Error),
	close: proc(data: rawptr, conn: rawptr),
}

Credentials_Source :: struct {
	data:    rawptr,
	produce: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool),
}

Purge_Request :: struct {
	object:   Object,
	msg:      Rid,
	role:     convo.Role,
	provider: string,
	native:   string,
	ids:      []string,
	texts:    []string,
	bodies:   []string,
	claim:    Rid,
}

Purge_Hook :: struct {
	data:  rawptr,
	purge: proc(data: rawptr, e: ^Engine, req: ^Purge_Request),
}

Event_Kind :: enum u8 {
	Connected,
	Disconnected,
	Durable,
	Uploaded,
	Quarantined,
	Refused,
	Fatal,
	Space_Joined,
	Object_Seen,
	Failure,
	Relay_Misbehaving,
	Presence,
	Caught_Up,
	Indexer_Wanted,
	Members_Changed,
	Epoch_Changed,
	Access_Revoked,
	Runner_Enrolled,
	Runner_Anomaly,
	Approval_Requested,
	Login_Done,
	Login_Failed,
	Unavailable,
	Available,
	Promoted,
	Peer_Misbehaving,
	Lease_Lapsed,
	Space_Left,
	Line_Switched,
	Replica_Redacted,
}

Event :: struct {
	kind:   Event_Kind,
	space:  prim.Id,
	object: prim.Id,
	device: prim.Id,
	tick:   u64,
	length: i64,
	err:    Error,
	detail: string,
}

Event_Hook :: struct {
	data:  rawptr,
	event: proc(data: rawptr, e: ^Engine, ev: ^Event),
}

Config :: struct {
	dir:             string,
	vfs:             prim.Vfs,
	loop:            ^prim.Loop,
	keyring:         osync.Keyring,
	credentials:     Credentials_Source,
	transport:       Transport,
	clock:           Clock,
	random:          prim.Random,
	ids:             Id_Source,
	log:             Log,
	spawner:         Spawner,
	embedder:        search.Embedder,
	purge:           Purge_Hook,
	events:          Event_Hook,
	http:            http.Client,
	write_observer:  fs.Write_Observer,
	fs_exec:         fs.Sync_Exec,
	watcher:         fs.Watcher,
	boot_id:         Boot_Source,
	search_options:  search.Options,
	durability:      Durability,
	verify_chains:   bool,
	page_heap:       bool,
	system_heap:     bool,
	kernel_tls:      bool,
	padding:         bool,
	search:          bool,
	handle_cache:    int,
	settle_ms:       i64,
	pack_options:    pack.Options,
	use_pack_options: bool,
	search_budget:   int,
	search_full:     bool,
	search_trees:    bool,
	search_remote:   Search_Remote,
	search_hedge_ms: i64,
	search_deadline_ms: i64,
	unlock:          osync.Unlock,
	sealed_store:    osync.Sealed_Store,
	runner_pool:     Runner_Pool,
	runner_alarm:    int,
	approver:        bool,
	notices_rotate:  i64,
	seed_guard:      osync.Seed_Guard,
	storage:         Storage_Mode,
	storage_policy:  Storage_Policy,
	git_remote:      Git_Remote,
	git_credentials: Git_Credentials,
	content_budget:  i64,
	always_on:       bool,
	holder_budget:   i64,
	history_fault:   fs.Persist_Fault,
	user:            rawptr,
}

DEFAULT_HANDLE_CACHE :: 64
DEFAULT_SETTLE_MS :: 1000
DEFAULT_SEARCH_BUDGET :: 1 << 20

default_config :: proc(dir: string) -> Config {
	return Config {
		dir           = dir,
		verify_chains = true,
		kernel_tls    = true,
		search        = true,
		handle_cache  = DEFAULT_HANDLE_CACHE,
		settle_ms     = DEFAULT_SETTLE_MS,
		search_budget = DEFAULT_SEARCH_BUDGET,
	}
}

Posted :: struct {
	call: proc(e: ^Engine, data: rawptr),
	data: rawptr,
}

Stats :: struct {
	ticks:       u64,
	commits:     u64,
	durable:     u64,
	handles:     int,
	opened:      u64,
	evicted:     u64,
	pending:     int,
	subs:        int,
	fetches:     u64,
	probes:      u64,
	indexed:     u64,
	wakeups:     u64,
	live_bytes:  u64,
	draft_bytes: u64,
	draft_pulls: u64,
	draft_rejected: u64,
	fetched_bytes:  u64,
	remote_skipped:  u64,
	remote_rewrites: u64,
	git_fetches:     u64,
	git_objects:     u64,
	over_budget:     u64,
	buffers:     int,
	buffer_deltas: u64,
	buffer_edits: u64,
	base_merged:  u64,
	base_current: u64,
	base_mismatch: u64,
	base_not_text: u64,
	damaged:      u64,
	restored:     u64,
}

Engine :: struct {
	cfg:          Config,
	unavailable:  map[prim.Id][dynamic]prim.Id,
	allocator:    runtime.Allocator,
	dir:          string,
	pack_root:    string,
	base:         prim.Vfs,
	vfs:          prim.Vfs,
	pk:           pack.Pack,
	pk_open:      bool,
	lock_fd:      prim.Fd,
	gen_next:     u64,
	gen_ceil:     u64,
	loop:         ^prim.Loop,
	own_loop:     prim.Loop,
	owns_loop:    bool,
	prev_wake:    prim.Wake_Proc,
	prev_wake_data: rawptr,
	thread:       ^thread.Thread,
	running:      bool,
	post_mu:      sync.Mutex,
	posted:       [dynamic]Posted,
	post_swap:    [dynamic]Posted,
	wake_hooks:   [dynamic]Posted,
	file_keyring: osync.File_Keyring,
	owns_keyring: bool,
	keyring:      osync.Keyring,
	identity:     osync.Identity,
	account:      Account_State,
	approvals:    Approvals,
	notices:      Notices,
	self:         prim.Id,
	hlc:          prim.Hlc,
	reg:          Registry,
	spaces:       map[prim.Id]^Space,
	links:        [dynamic]^Space,
	handles:      map[prim.Id]^Handle,
	lru:          [dynamic]^Handle,
	own_trees:    map[osync.Stream_Id]^Own_Tree,
	leave_ready:  [dynamic]prim.Id,
	refused_stop: [dynamic]prim.Id,
	drain_wait:   [dynamic]prim.Id,
	waiters:      [dynamic]^Waiter,
	space_waits:  [dynamic]Space_Wait,
	space_woke:   bool,
	held:         [dynamic]^Pending_Cmd,
	subs:         [dynamic]^Sub,
	next_sub:     u64,
	buffers:      [dynamic]^Buffer,
	next_buffer:  u64,
	cursor_inbox: [dynamic]Cursor_Msg,
	tick:         u64,
	tick_timer:   prim.Timer,
	tick_hook:    Tick_Hook,
	deliver_hook: Tick_Hook,
	tick_wanted:  bool,
	settle_timer: prim.Timer,
	settling:     bool,
	in_tick:      bool,
	closing:      bool,
	dirty:        [dynamic]Dirty_Seg,
	draft_dirty:  [dynamic]Draft_Pub,
	damaged:      [dynamic]Damaged,
	checks:       map[osync.Stream_Id]Check,
	restores:     [dynamic]Restore,
	batches:      [dynamic]^Durable_Batch,
	batch_seq:    u64,
	durable_seq:  u64,
	changed:      map[prim.Id]Change,
	catalog_q:    map[prim.Id]^Catalog_Update,
	catalog_parked: map[prim.Id]^Catalog_Update,
	remote:       Remote_State,
	index:        search.Index,
	index_open:   bool,
	index_dirty:  [dynamic]Index_Item,
	index_busy:   bool,
	db:           odb.Odb,
	db_open:      bool,
	pack_more:    bool,
	purged:       [dynamic]Rid,
	redact_tick:  u64,
	rlog:         Rlog,
	plug:         Plug_State,
	pages:        Page_Heap,
	temp:         virtual.Arena,
	outer:        runtime.Context,
	outer_set:    bool,
	content:      Content_State,
	git:          Git_State,
	budget:       Budget_State,
	card_pubs:    [dynamic]Card_Pub,
	stats:        Stats,
	fatal:        Error,
}

open :: proc(e: ^Engine, cfg: Config, allocator := context.allocator) -> (err: Error) {
	e^ = {
		cfg       = cfg,
		allocator = allocator,
		lock_fd   = prim.INVALID_FD,
	}
	if (cfg.page_heap || PAGES_DEFAULT && !cfg.system_heap) && allocator.procedure == runtime.heap_allocator_proc {
		_pages_init(&e.pages)
		e.allocator = _pages_allocator(&e.pages)
	}
	context = context_for(e)
	if len(cfg.dir) == 0 {
		return .Invalid
	}
	if e.cfg.handle_cache <= 0 {
		e.cfg.handle_cache = DEFAULT_HANDLE_CACHE
	}
	if e.cfg.settle_ms <= 0 {
		e.cfg.settle_ms = DEFAULT_SETTLE_MS
	}
	if e.cfg.search_budget <= 0 {
		e.cfg.search_budget = DEFAULT_SEARCH_BUDGET
	}
	if e.cfg.git_remote.fetch == nil {
		e.cfg.git_remote = default_git_remote()
	}
	e.base =cfg.vfs if cfg.vfs.procs != nil else prim.os_vfs()
	e.dir = _clone(cfg.dir, e.allocator) or_return
	e.pack_root = _join(e.allocator, e.dir, "pack") or_return
	e.spaces = make(map[prim.Id]^Space, e.allocator)
	e.unavailable = make(map[prim.Id][dynamic]prim.Id, e.allocator)
	e.links = make([dynamic]^Space, e.allocator)
	e.handles = make(map[prim.Id]^Handle, e.allocator)
	e.lru = make([dynamic]^Handle, e.allocator)
	e.own_trees = make(map[osync.Stream_Id]^Own_Tree, e.allocator)
	e.leave_ready = make([dynamic]prim.Id, e.allocator)
	e.refused_stop = make([dynamic]prim.Id, e.allocator)
	e.drain_wait = make([dynamic]prim.Id, e.allocator)
	e.waiters = make([dynamic]^Waiter, e.allocator)
	e.space_waits = make([dynamic]Space_Wait, e.allocator)
	e.held = make([dynamic]^Pending_Cmd, e.allocator)
	e.purged = make([dynamic]Rid, e.allocator)
	e.subs = make([dynamic]^Sub, e.allocator)
	e.posted = make([dynamic]Posted, e.allocator)
	e.post_swap = make([dynamic]Posted, e.allocator)
	e.wake_hooks = make([dynamic]Posted, e.allocator)
	e.dirty = make([dynamic]Dirty_Seg, e.allocator)
	e.draft_dirty = make([dynamic]Draft_Pub, e.allocator)
	e.batches = make([dynamic]^Durable_Batch, e.allocator)
	e.changed = make(map[prim.Id]Change, e.allocator)
	_content_init(e)
	_git_init(e)
	_budget_init(e)
	e.card_pubs = make([dynamic]Card_Pub, e.allocator)
	e.catalog_q = make(map[prim.Id]^Catalog_Update, e.allocator)
	e.catalog_parked = make(map[prim.Id]^Catalog_Update, e.allocator)
	e.index_dirty = make([dynamic]Index_Item, e.allocator)
	defer if err != .None {
		_teardown(e)
	}
	_perr(prim.mkdir_all(e.base, e.dir, 0o700)) or_return
	lock_path := _join(context.temp_allocator, e.dir, "lock") or_return
	fd, lerr := prim.lock_file(e.base, lock_path)
	if lerr != .None {
		return .Busy if lerr == .Busy || lerr == .Would_Block else _perr(lerr)
	}
	e.lock_fd = fd
	_gen_load(e) or_return
	if cfg.loop != nil {
		e.loop = cfg.loop
	} else {
		_perr(prim.loop_init(&e.own_loop, e.allocator)) or_return
		e.loop = &e.own_loop
		e.owns_loop = true
		prim.loop_set_clock(e.loop, cfg.clock)
	}
	e.prev_wake = e.loop.wake_cb
	e.prev_wake_data = e.loop.wake_data
	prim.loop_on_wake(e.loop, _on_wake, e)
	opts := cfg.pack_options if cfg.use_pack_options else pack.DEFAULT_OPTIONS
	if opts.clock.mono_ns == nil && opts.clock.wall_ns == nil {
		opts.clock = cfg.clock
	}
	opts.before_commit = _pack_before_commit
	opts.before_data = e
	if cfg.durability == .Deferred {
		opts.deferred_sync = true
		opts.wake = nil
		opts.wake_data = nil
	} else {
		opts.wake = _pack_wake
		opts.wake_data = e
	}
	_perr(prim.mkdir_all(e.base, e.pack_root, 0o700)) or_return
	_perr(pack.open(&e.pk, e.base, e.pack_root, opts, e.allocator)) or_return
	e.pk_open = true
	e.vfs = pack.vfs(&e.pk)
	pack.batch_begin(&e.pk)
	if cfg.keyring.identity != nil {
		e.keyring = cfg.keyring
	} else {
		kdir := _join(context.temp_allocator, e.dir, "device") or_return
		_perr(prim.mkdir_all(e.base, kdir, 0o700)) or_return
		_serr(osync.file_keyring_open_guarded(&e.file_keyring, e.base, kdir, e.cfg.seed_guard, e.cfg.random)) or_return
		e.owns_keyring = true
		e.keyring = osync.file_keyring(&e.file_keyring)
	}
	e.identity = osync.keyring_identity(&e.keyring)
	e.self = e.identity.id
	_registry_open(e) or_return
	_registry_recover(e) or_return
	_spaces_load(e) or_return
	_account_load(e)
	_redact_recover(e)
	_leave_resume(e)
	if e.account.have {
		_touch(e)
	}
	return .None
}

close :: proc(e: ^Engine) -> Error {
	context = context_for(e)
	if e.running {
		stop(e)
	}
	e.closing = true
	err := flush(e)
	_teardown(e)
	return err
}

identity :: proc "contextless" (e: ^Engine) -> osync.Identity {
	return e.identity
}

self :: proc "contextless" (e: ^Engine) -> prim.Id {
	return e.self
}

loop :: proc "contextless" (e: ^Engine) -> ^prim.Loop {
	return e.loop
}

vfs :: proc "contextless" (e: ^Engine) -> prim.Vfs {
	return e.vfs
}

base_vfs :: proc "contextless" (e: ^Engine) -> prim.Vfs {
	return e.base
}

stats :: proc(e: ^Engine) -> Stats {
	context = context_for(e)
	s := e.stats
	s.handles = len(e.handles)
	s.buffers = len(e.buffers)
	s.pending = len(e.waiters)
	s.subs = len(e.subs)
	for _, sp in e.spaces {
		s.fetched_bytes += sp.repl.fetched_bytes
	}
	return s
}

fd :: proc "contextless" (e: ^Engine) -> prim.Fd {
	return prim.loop_fd(e.loop)
}

timeout_ms :: proc(e: ^Engine) -> i64 {
	context = context_for(e)
	return prim.loop_timeout_ms(e.loop)
}

new_id :: proc(e: ^Engine) -> prim.Id {
	context = context_for(e)
	if e.cfg.ids.next != nil {
		return e.cfg.ids.next(e.cfg.ids.data)
	}
	return prim.id_new_with(e.cfg.clock, e.cfg.random)
}

random_fill :: proc(e: ^Engine, out: []u8) {
	context = context_for(e)
	prim.random_fill(e.cfg.random, out)
}

step :: proc(e: ^Engine, block := false) -> Error {
	context = context_for(e)
	context = context_for(e)
	return _perr(prim.loop_step(e.loop, block))
}

run :: proc(e: ^Engine) -> Error {
	context = context_for(e)
	context = context_for(e)
	return _perr(prim.loop_run(e.loop))
}

context_for :: proc(e: ^Engine) -> runtime.Context {
	if context.allocator.procedure != e.allocator.procedure || context.allocator.data != e.allocator.data {
		e.outer = context
		e.outer_set = true
	}
	c := context
	c.allocator = e.allocator
	c.temp_allocator = virtual.arena_allocator(&e.temp)
	return c
}

start :: proc(e: ^Engine) -> Error {
	context = context_for(e)
	if e.running {
		return .Busy
	}
	if !e.owns_loop {
		return .Invalid
	}
	t := thread.create(_thread_main)
	if t == nil {
		return .No_Memory
	}
	t.data = e
	e.thread = t
	e.running = true
	thread.start(t)
	return .None
}

stop :: proc(e: ^Engine) {
	context = context_for(e)
	if !e.running {
		return
	}
	post(e, _stop_call, nil)
	thread.join(e.thread)
	thread.destroy(e.thread)
	e.thread = nil
	e.running = false
}

post :: proc(e: ^Engine, call: proc(e: ^Engine, data: rawptr), data: rawptr) -> Error {
	context = context_for(e)
	sync.mutex_lock(&e.post_mu)
	_, aerr := append(&e.posted, Posted{call, data})
	sync.mutex_unlock(&e.post_mu)
	if aerr != nil {
		return .No_Memory
	}
	prim.wake(e.loop)
	return .None
}

flush :: proc(e: ^Engine) -> Error {
	context = context_for(e)
	if !e.pk_open {
		return .Closed
	}
	err: Error
	for round in 0 ..< 4 {
		_tick_end(e)
		_durable_begin(e)
		err = _perr(pack.batch_end(&e.pk))
		pack.batch_begin(&e.pk)
		_batches_done(e, err)
		if err != .None {
			return err
		}
		_held_retry(e)
		if !_tick_pending(e) && len(e.held) == 0 {
			break
		}
		_ = round
	}
	return e.fatal
}

durable_seq :: proc "contextless" (e: ^Engine) -> u64 {
	return e.durable_seq
}

pending_seq :: proc "contextless" (e: ^Engine) -> u64 {
	return e.batch_seq + 1
}

hlc_now :: proc(e: ^Engine) -> prim.Hlc {
	context = context_for(e)
	return prim.hlc_now_with(&e.hlc, e.cfg.clock)
}

@(private)
_outer :: proc(e: ^Engine) -> runtime.Context {
	if e.outer_set {
		return e.outer
	}
	return context
}

@(private)
_thread_main :: proc(t: ^thread.Thread) {
	e := (^Engine)(t.data)
	context = context_for(e)
	for !prim.loop_stopped(e.loop) {
		if prim.loop_step(e.loop, true) != .None {
			break
		}
	}
}

@(private)
_stop_call :: proc(e: ^Engine, data: rawptr) {
	flush(e)
	prim.loop_stop(e.loop)
}

@(private)
_wall_ms :: proc(e: ^Engine) -> i64 {
	return prim.clock_wall_ms(e.cfg.clock)
}

@(private)
_wall_ns_data :: proc(data: rawptr) -> i64 {
	return prim.clock_wall_ns((^Engine)(data).cfg.clock)
}

@(private)
_wall_ms_data :: proc(data: rawptr) -> i64 {
	return _wall_ms((^Engine)(data))
}

@(private)
_obj_clock :: proc(e: ^Engine) -> obj.Clock {
	return obj.Clock{data = e, wall_ms = _wall_ms_data}
}

@(private)
_fs_clock :: proc(e: ^Engine) -> fs.Clock {
	return fs.Clock{data = e, wall_ms = _wall_ms_data}
}

@(private)
_pack_wake :: proc(data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	prim.wake(e.loop)
}

@(private)
_on_wake :: proc(l: ^prim.Loop, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	e.stats.wakeups += 1
	if e.prev_wake != nil {
		e.prev_wake(l, e.prev_wake_data)
	}
	sync.mutex_lock(&e.post_mu)
	e.posted, e.post_swap = e.post_swap, e.posted
	sync.mutex_unlock(&e.post_mu)
	for p in e.post_swap {
		{
			context = _outer(e)
			p.call(e, p.data)
		}
	}
	clear(&e.post_swap)
	_pack_poll(e)
	_loopback_drain(e)
}

@(private)
_pack_poll :: proc(e: ^Engine) {
	if !e.pk_open {
		return
	}
	was := pack.pressure(&e.pk)
	if err := pack.poll(&e.pk); err != .None {
		_fatal(e, _perr(err))
	}
	if was && !pack.pressure(&e.pk) {
		_held_retry(e)
		if _tick_pending(e) {
			_touch(e)
		}
	}
}

Tick_Hook :: struct {
	data: rawptr,
	call: proc(data: rawptr, e: ^Engine),
}

set_deliver_hook :: proc(e: ^Engine, hook: Tick_Hook) {
	e.deliver_hook = hook
}

@(private)
_deliver_hook :: proc(e: ^Engine) {
	if e.deliver_hook.call != nil {
		hook := e.deliver_hook
		context = _outer(e)
		hook.call(hook.data, e)
	}
}

set_tick_hook :: proc(e: ^Engine, hook: Tick_Hook) {
	e.tick_hook = hook
}

request_tick :: proc(e: ^Engine) {
	context = context_for(e)
	e.tick_wanted = true
	_touch(e)
}

@(private)
_touch :: proc(e: ^Engine) {
	if e.closing {
		return
	}
	if e.tick_timer == 0 || !prim.timer_pending(e.loop, e.tick_timer) {
		e.tick_timer = prim.timer(e.loop, 0, e, _on_tick)
		if !e.in_tick {
			prim.wake(e.loop)
		}
	}
}

@(private)
_on_tick :: proc(l: ^prim.Loop, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	e.tick_timer = 0
	_tick_end(e)
	if !e.in_tick {
		virtual.arena_free_all(&e.temp)
	}
}

@(private)
_tick_end :: proc(e: ^Engine) {
	if e.in_tick {
		return
	}
	e.in_tick = true
	defer e.in_tick = false
	if e.tick_timer != 0 {
		prim.timer_cancel(e.loop, e.tick_timer)
		e.tick_timer = 0
	}
	e.tick += 1
	e.stats.ticks += 1
	e.tick_wanted = false
	_repl_events_process(e)
	_approvals_step(e)
	_space_waits_run(e)
	_content_events_process(e)
	_waiters_run(e)
	_remote_step(e)
	_catalog_reconcile(e)
	_catalog_flush(e)
	_budget_flush(e)
	_mounts_commit(e)
	_handles_commit(e)
	_mounts_changed(e)
	_buffers_tick(e)
	_deliver_hook(e)
	_subs_deliver(e)
	_deliver_hook(e)
	if e.tick_hook.call != nil {
		hook := e.tick_hook
		{
			context = _outer(e)
			hook.call(hook.data, e)
		}
	}
	_full_step(e)
	_index_step(e)
	_damage_step(e)
	_handles_commit(e)
	_index_durable_advanced(e)
	_handles_sweep(e, e.cfg.handle_cache)
	_git_flush(e)
	_durable_begin(e)
	_leave_step(e)
	_refused_step(e)
	if e.fatal == .None && (e.pk_open && e.pk.poisoned || e.reg.open && e.reg.db.poisoned) {
		_fatal(e, .Io)
	}
	_settle_arm(e)
	if (!_tick_pending(e) || pack.pressure(&e.pk)) && e.tick_timer != 0 {
		prim.timer_cancel(e.loop, e.tick_timer)
		e.tick_timer = 0
	}
}

@(private)
_tick_pending :: proc(e: ^Engine) -> bool {
	if e.tick_wanted || e.space_woke || len(e.changed) > 0 || len(e.catalog_q) > 0 || len(e.dirty) > 0 || len(e.index_dirty) > 0 || len(e.content.events) > 0 || len(e.cursor_inbox) > 0 || len(e.leave_ready) > 0 || len(e.refused_stop) > 0 || _remote_pending(e) {
		return true
	}
	for _, sp in e.spaces {
		if len(sp.events) > 0 || len(sp.needs) > 0 {
			return true
		}
	}
	for h in e.lru {
		if h.local {
			return true
		}
	}
	return false
}

@(private)
_settle_arm :: proc(e: ^Engine) {
	if e.closing {
		return
	}
	if e.settle_timer != 0 {
		prim.timer_cancel(e.loop, e.settle_timer)
	}
	e.settle_timer = prim.timer(e.loop, e.cfg.settle_ms, e, _on_settle)
}

@(private)
_on_settle :: proc(l: ^prim.Loop, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	e.settle_timer = 0
	if len(e.batches) > 0 || len(e.dirty) > 0 || e.in_tick {
		e.settle_timer = prim.timer(e.loop, e.cfg.settle_ms, e, _on_settle)
		return
	}

	e.settling = true
	_redact_settle(e)
	_mounts_settle(e)
	_full_settle(e)
	_index_settle(e)
	_checkpoints_write(e)
	_handles_sweep(e, 0)
	e.settling = false
	_spaces_settle(e)
	_trees_release(e)
	_durable_begin(e)
	if e.pack_more {
		e.settle_timer = prim.timer(e.loop, 0, e, _on_settle)
	}
	_curl_settle(e)
	when !runtime.NO_DEFAULT_TEMP_ALLOCATOR {
		if context.temp_allocator.data == &runtime.global_default_temp_allocator_data {
			runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
		}
	}
	if context.temp_allocator.data == &e.temp {
		virtual.arena_destroy(&e.temp)
	}
	if !e.pack_more {
		_pages_release(&e.pages)
		_heap_release(e)
	}
}

@(private)
_fatal :: proc(e: ^Engine, err: Error) {
	if e.fatal == .None {
		e.fatal = err
	}
	_emit(e, Event{kind = .Failure, err = err})
}

@(private)
_emit :: proc(e: ^Engine, ev: Event) {
	if ev.kind == .Space_Joined || ev.kind == .Members_Changed {
		_notices_space_changed(e, ev.space)
	}
	if ev.kind == .Members_Changed || ev.kind == .Epoch_Changed || ev.kind == .Access_Revoked {
		_space_waits_wake(e, ev.space)
		_space_waits_wake(e, ev.space, .Members)
	}
	if ev.kind == .Caught_Up || ev.kind == .Disconnected || ev.kind == .Access_Revoked {
		_space_waits_wake(e, ev.space, .Catalog)
	}
	if ev.kind == .Uploaded || ev.kind == .Disconnected || ev.kind == .Access_Revoked {
		_space_waits_wake(e, ev.space, .Upload)
	}
	if ev.kind == .Refused && len(e.space_waits) > 0 {
		_space_waits_refused(e, ev.space, ev.err if ev.err != .None else .Limit)
	}
	if e.cfg.events.event != nil {
		x := ev
		{
			context = _outer(e)
			e.cfg.events.event(e.cfg.events.data, e, &x)
		}
	}
}

@(private)
_log :: proc(e: ^Engine, level: Log_Level, msg: string) {
	if e.cfg.log.write != nil {
		{
			context = _outer(e)
			e.cfg.log.write(e.cfg.log.data, level, msg)
		}
	}
}

@(private)
_teardown :: proc(e: ^Engine) {
	e.closing = true
	_subs_free_all(e)
	_buffers_free_all(e)
	_waiters_fail_all(e, .Closed)
	_space_waits_fail_all(e, .Closed)
	_remote_close(e)
	_plugs_close(e)
	_handles_sweep(e, -1)
	_index_close(e)
	_trees_persist(e)
	if e.reg.open {
		_registry_flush(e)
	}
	if e.pk_open {
		if pack.batch_end(&e.pk) == .None {
			_batches_done(e, .None)
			e.durable_seq = e.batch_seq + 1
		} else {
			_batches_done(e, .None)
		}
	}
	_dirty_drop(e)
	_account_close(e)
	_spaces_close_all(e)
	_trees_free_all(e)
	if e.db_open {
		odb.close(&e.db)
		e.db_open = false
	}
	_registry_close(e)
	if e.pk_open {
		pack.close(&e.pk)
		e.pk_open = false
	}
	if e.owns_keyring {
		osync.file_keyring_close(&e.file_keyring)
		e.owns_keyring = false
	}
	if e.loop != nil {
		if e.tick_timer != 0 {
			prim.timer_cancel(e.loop, e.tick_timer)
			e.tick_timer = 0
		}
		if e.settle_timer != 0 {
			prim.timer_cancel(e.loop, e.settle_timer)
			e.settle_timer = 0
		}
		if e.loop.wake_cb == _on_wake && e.loop.wake_data == rawptr(e) {
			prim.loop_on_wake(e.loop, e.prev_wake, e.prev_wake_data)
		}
	}
	if e.owns_loop {
		prim.loop_destroy(&e.own_loop)
		e.owns_loop = false
	}
	e.loop = nil
	if e.lock_fd >= 0 {
		prim.close_file(e.base, e.lock_fd)
		e.lock_fd = prim.INVALID_FD
	}
	delete(e.spaces)
	_unavailable_destroy(e)
	delete(e.links)
	delete(e.handles)
	delete(e.lru)
	delete(e.own_trees)
	delete(e.leave_ready)
	delete(e.refused_stop)
	delete(e.drain_wait)
	for p in e.held {
		_cmd_fail(e, p, .Closed)
	}
	delete(e.held)
	delete(e.purged)
	delete(e.waiters)
	delete(e.space_waits)
	delete(e.subs)
	delete(e.posted)
	delete(e.post_swap)
	delete(e.wake_hooks)
	delete(e.dirty)
	delete(e.draft_dirty)
	delete(e.damaged)
	delete(e.checks)
	delete(e.restores)
	delete(e.batches)
	delete(e.changed)
	_git_destroy(e)
	_budget_destroy(e)
	_content_destroy(e)
	delete(e.card_pubs)
	for _, u in e.catalog_q {
		_catalog_update_free(e, u)
	}
	delete(e.catalog_q)
	for _, u in e.catalog_parked {
		_catalog_update_free(e, u)
	}
	delete(e.catalog_parked)
	delete(e.index_dirty)
	delete(e.pack_root, e.allocator)
	delete(e.dir, e.allocator)
	e.pack_root = ""
	e.dir = ""
	virtual.arena_destroy(&e.temp)
	if e.pages.on {
		_pages_destroy(&e.pages)
	}
}

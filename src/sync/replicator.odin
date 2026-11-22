#+build linux, darwin, windows
package osync

import "base:runtime"
import "core:crypto"
import "core:crypto/ecdh"
import "core:mem"
import "core:slice"
import "../journal"
import "../prim"

Repl_Event_Kind :: enum u8 {
	Connected,
	Disconnected,
	Uploaded,
	Fatal,
	Refused,
	Grew,
	Present,
	Device_Seen,
	Epoch_Seen,
	Dropped,
	Object_Stored,
	Object_Fetched,
	Object_Missing,
	Object_Failed,
	Segment_Seen,
	Checkpoint,
	Checkpoint_Missing,
	Redacted,
	Local_Redacted,
	Quarantined,
	Relay_Misbehaving,
	Keys_Needed,
	Presence,
	Direct,
	Undelivered,
	Object_Shredded,
	Caught_Up,
	Unavailable,
	Peer_Misbehaving,
	Promoted,
	Draft,
	Draft_Pulled,
}

Repl_Event :: struct {
	kind:   Repl_Event_Kind,
	err:    Error,
	code:   Code,
	device: Device_Id,
	name:   string,
	epoch:  u64,
	stream: Stream_Id,
	from:   i64,
	to:     i64,
	length: i64,
	oid:    []u8,
	meta:   []u8,
	path:   string,
	usage:  i64,
	quota:  i64,
}

Repl_Handler :: #type proc(user: rawptr, ev: ^Repl_Event)

Replicator_Config :: struct {
	vfs:          prim.Vfs,
	dir:          string,
	relay:        string,
	relay_public: Public_Key,
	noise_static: ^ecdh.Private_Key,
	self:         Device_Id,
	credentials:  Credentials,
	link:         Client_Link,
	verify:       proc(user: rawptr, req: ^Verify_Request) -> Verdict,
	filtered:     bool,
	padding:      bool,
	random:       prim.Random,
	relays:       []Relay_Address,
	keys:         proc(user: rawptr, device: Device_Id, name: string, epoch: u64, stream: Stream_Id) -> (sealing: Stream_Sealing, tree: journal.Key_Provider),
	kernel_tls:   bool,
	seal:         proc(user: rawptr, name: string, id: Stream_Id, data: []u8, off: i64) -> Error,
	on_event:     Repl_Handler,
	user:         rawptr,
	durable:      proc(user: rawptr, path: string) -> (length: i64, ok: bool),
}

Stream_Sealing :: enum u8 {
	Unknown,
	Stream_Key,
	Key_Tree,
	Key_Tree_Stale,
}

Presence_State :: struct {
	up:    bool,
	since: i64,
	seen:  bool,
}

Relay_Address :: struct {
	addr:   string,
	public: Public_Key,
}

Client_Link :: struct {
	data:  rawptr,
	send:  proc(data: rawptr, bytes: []u8) -> (int, Error),
	close: proc(data: rawptr),
}

Phase :: enum u8 {
	Stopped,
	Waiting,
	Resolving,
	Connecting,
	Handshake,
	Hello,
	Ready,
	Credential,
}

@(private)
Cred_Req :: struct {
	r:   ^Replicator,
	gen: u64,
}

Local :: struct {
	name:      string,
	epoch:     u64,
	id:        Stream_Id,
	key:       journal.Key,
	path:      string,
	fd:        prim.Fd,
	floor_fd:  prim.Fd,
	floor:     i64,
	floor_seq: u64,
	cursor:    i64,
	durable:   i64,
	inflight:  i64,
	fatal:     bool,
	blocked:   bool,
	retry:     bool,
	verifying: bool,
	verify_at: i64,
	verify_to: i64,
	ahead:     i64,
	plain:     bool,
	tree:      ^Key_Tree,
	drop_id:   Stream_Id,
	drop_path: string,
	dropping:  bool,
	superseded: bool,
	reaping:   bool,
	verify:    [dynamic]u8,
	hollow:    bool,
	noting:    bool,
}

Remote :: struct {
	device:    Device_Id,
	name:      string,
	epoch:     u64,
	id:        Stream_Id,
	path:      string,
	rep:       journal.Replica,
	full:      bool,
	follow:    bool,
	refs:      int,
	relay_len: i64,
	tail:      i64,
	wants:     [dynamic]journal.Range,
	inflight:  [dynamic]journal.Range,
	probes:    [PROBES]Stream_Id,
	grouped:   bool,
	quarantined: bool,
	keys_wait: bool,
	kheld_at:  i64,
	kheld:     [dynamic]u8,
	claims:    [dynamic]i64,
	backward:  bool,
	last_from: i64,
	scope:     Scope,
	head_keys: string,
	head_min:  u64,
	is_head:   bool,
	tamper_hold: bool,
	plain:     bool,
	skey:      journal.Key,
	reaping:   bool,
	probing:   bool,
	kfollow:   bool,
	kwait_head: Stream_Id,
	kstream:   Stream_Id,
	retry_hold: bool,
	denied:    bool,
	want_gen:  u64,
	probe_gen: u64,
	fresh_gen: u64,
	held:      i64,
	pulled:    i64,
	pulling:   bool,
	verified:  [dynamic]journal.Range,
	span:      journal.Sig_Info,
	span_ok:   bool,
	span_fd:   prim.Fd,
	span_seq:  u64,
	base:      i64,
	suspect:   Device_Id,
	base_checked: bool,
	unavail:   bool,
	pulls:     [dynamic]Pull_Flight,
	refused:   [dynamic]Device_Id,
	carry:     [dynamic]u8,
	carry_at:  i64,
}

Group :: struct {
	scope:   Scope,
	name:    string,
	epoch:   u64,
	suffix:  [16]u8,
	full:    bool,
	members: [dynamic]Device_Id,
}



Replicator :: struct {
	vfs:        prim.Vfs,
	loop:       ^prim.Loop,
	cfg:        Replicator_Config,
	dir:        string,
	endpoint:   Endpoint,
	endpoints:  [dynamic]Endpoint,
	publics:    [dynamic]Public_Key,
	relay_at:   int,
	deadline:   prim.Timer,
	tampered:   bool,
	presence:   map[Device_Id]Presence_State,
	present_ok: bool,
	read_reqs:  int,
	read_bytes: i64,
	tamper_run: int,
	phase:      Phase,
	cred_gen:   u64,
	cred_req:   ^Cred_Req,
	fd:         prim.Fd,
	watch:      prim.Watch,
	timer:      prim.Timer,
	retry:      prim.Timer,
	backoff:    i64,
	tr:         Transport,
	client:     Client,
	rbuf:       []u8,
	resolver:   Resolver,
	locals:     map[Stream_Id]^Local,
	remotes:    map[Stream_Id]^Remote,
	probes:     map[Stream_Id]^Remote,
	devices:    map[Device_Id]bool,
	objs:       Objects,
	uploading:  int,
	external:   bool,
	static:     ecdh.Private_Key,
	groups:     map[[16]u8]^Group,
	feed_cursor: i64,
	feed_target: i64,
	caught:     bool,
	feed_fd:    prim.Fd,
	feed_seq:   u64,
	fetches:    [dynamic]^Ckpt_Fetch,
	list_sent:  u64,
	list_done:  u64,
	hold:       int,
	reap:       [dynamic]^Remote,
	reap_local: [dynamic]^Local,
	cursor:     i64,
	listed:     bool,
	rx_remote:  ^Remote,
	rx_local:   ^Local,
	rx_at:      i64,
	rx_start:   i64,
	stage:      [dynamic]u8,
	stage_at:   i64,
	usage:      i64,
	quota:      i64,
	features:   u64,
	account:    Relay_Space_Stats,
	accounted:  bool,
	pumping:    bool,
	kwait_dirty: bool,
	serves:     [dynamic]Serve_Req,
	parked:     [dynamic]Serve_Req,
	pull_tag:   u64,
	rx_holder:  Device_Id,
	rx_tag:     u64,
	rx_skip:    bool,
	served_bytes: i64,
	peer_tampered: int,
	promos:     [dynamic]^Promotion,
	lives:      map[Stream_Id]Live_Sub,
	dflights:   [dynamic]Draft_Flight,
	live_rx:    Live_Rx,
	live_sent:  i64,
	live_recv:  i64,
	allocator:  runtime.Allocator,
}

@(private)
PROBES :: 4
@(private)
UPLOAD_CHUNK :: 4 * 1024 * 1024
@(private)
MAX_UPLOADS :: 8
@(private)
OUT_HIGH :: 8 * 1024 * 1024
@(private)
STAGE_MAX :: 1 << 20
@(private)
MIN_FETCH :: 64 * 1024
TAIL_DEFAULT :: 64 * 1024
@(private)
BACKOFF_MIN :: 250
@(private)
BACKOFF_MAX :: 30_000
@(private)
CONNECT_TIMEOUT :: 15_000
@(private)
RETRY_MS :: 1000

replicator_init :: proc(r: ^Replicator, l: ^prim.Loop, cfg: Replicator_Config, allocator := context.allocator) -> Error {
	r^ = {
		loop      = l,
		cfg       = cfg,
		fd        = prim.INVALID_FD,
		allocator = allocator,
		backoff   = BACKOFF_MIN,
	}
	if cfg.credentials.produce == nil || cfg.on_event == nil {
		return .Invalid
	}
	r.vfs = cfg.vfs if cfg.vfs.procs != nil else prim.os_vfs()
	r.external = cfg.link.send != nil
	if !r.external {
		r.endpoints = make([dynamic]Endpoint, allocator)
		r.publics = make([dynamic]Public_Key, allocator)
		if len(cfg.relays) > 0 {
			for a in cfg.relays {
				append(&r.endpoints, endpoint_parse(a.addr) or_return)
				append(&r.publics, a.public)
			}
		} else {
			append(&r.endpoints, endpoint_parse(cfg.relay) or_return)
			append(&r.publics, cfg.relay_public)
		}
		r.endpoint = r.endpoints[0]
		r.cfg.relay_public = r.publics[0]
		r.cfg.relays = nil
		if cfg.noise_static != nil {
			ecdh.private_key_set(&r.static, cfg.noise_static)
		} else if !x25519_generate(&r.static, cfg.random) {
			return .Invalid
		}
	}
	r.dir = _clone_string(cfg.dir, allocator) or_return
	r.cfg.dir = r.dir
	r.cfg.relay = ""
	for sub in ([]string{"up", "replicas", "ckpt"}) {
		p, perr := prim.path_join(context.temp_allocator, r.dir, sub)
		if perr != .None {
			return _from_prim(perr)
		}
		if merr := prim.mkdir_all(r.vfs, p, 0o700); merr != .None {
			return _from_prim(merr)
		}
	}
	client_init(&r.client, allocator)
	r.locals = make(map[Stream_Id]^Local, allocator)
	r.remotes = make(map[Stream_Id]^Remote, allocator)
	r.probes = make(map[Stream_Id]^Remote, allocator)
	r.devices = make(map[Device_Id]bool, allocator)
	_objs_init(r)
	r.stage = make([dynamic]u8, allocator)
	r.groups = make(map[[16]u8]^Group, allocator)
	r.feed_cursor = -1
	r.feed_target = -1
	r.feed_fd = prim.INVALID_FD
	_feed_cursor_load(r)
	r.fetches = make([dynamic]^Ckpt_Fetch, allocator)
	r.reap = make([dynamic]^Remote, allocator)
	r.presence = make(map[Device_Id]Presence_State, allocator)
	r.reap_local = make([dynamic]^Local, allocator)
	r.serves = make([dynamic]Serve_Req, allocator)
	r.parked = make([dynamic]Serve_Req, allocator)
	r.promos = make([dynamic]^Promotion, allocator)
	r.tr.fd = prim.INVALID_FD
	return .None
}

replicator_destroy :: proc(r: ^Replicator) {
	_repl_close(r)
	if r.timer != 0 {
		prim.timer_cancel(r.loop, r.timer)
	}
	if r.retry != 0 {
		prim.timer_cancel(r.loop, r.retry)
	}
	_resolver_stop(r)
	for _, l in r.locals {
		_local_free(r, l)
	}
	clear(&r.reap)
	clear(&r.reap_local)
	for _, rm in r.remotes {
		_remote_free(r, rm)
	}
	r.kwait_dirty = false
	_objs_destroy(r)
	delete(r.locals)
	delete(r.remotes)
	delete(r.probes)
	delete(r.devices)
	delete(r.stage)
	for _, g in r.groups {
		_group_free(r, g)
	}
	delete(r.groups)
	for f in r.fetches {
		_fetch_free(r, f)
	}
	delete(r.fetches)
	delete(r.reap)
	delete(r.reap_local)
	delete(r.presence)
	delete(r.serves)
	delete(r.parked)
	_lives_destroy(r)
	for pr in r.promos {
		_promotion_free(r, pr)
	}
	delete(r.promos)
	delete(r.endpoints)
	delete(r.publics)
	if r.deadline != 0 {
		prim.timer_cancel(r.loop, r.deadline)
		r.deadline = 0
	}
	ecdh.private_key_clear(&r.static)
	if r.feed_fd >= 0 {
		prim.close_file(r.vfs, r.feed_fd)
	}
	client_destroy(&r.client)
	if r.rbuf != nil {
		delete(r.rbuf, r.allocator)
	}
	delete(r.dir, r.allocator)
	r^ = {}
}

replicator_start :: proc(r: ^Replicator) {
	_enter(r)
	defer _leave(r)
	if r.phase == .Stopped && !r.external {
		r.phase = .Waiting
		_repl_connect(r)
	}
}

replicator_stop :: proc(r: ^Replicator) {
	_enter(r)
	defer _leave(r)
	_repl_close(r)
	if r.timer != 0 {
		prim.timer_cancel(r.loop, r.timer)
		r.timer = 0
	}
	if r.retry != 0 {
		prim.timer_cancel(r.loop, r.retry)
		r.retry = 0
	}
	_resolver_stop(r)
	r.phase = .Stopped
}

replicator_account :: proc(r: ^Replicator) -> Error {
	if r.phase != .Ready || r.features & FEATURE_ACCOUNT == 0 {
		return .Unsupported if r.phase == .Ready else .Busy
	}
	_enter(r)
	defer _leave(r)
	client_account(&r.client) or_return
	_repl_flush(r)
	return .None
}

replicator_ready :: proc "contextless" (r: ^Replicator) -> bool {
	return r.phase == .Ready
}

replicator_floor :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64) -> (floor: i64, err: Error) {
	id := stream_id(scope, r.cfg.self, name, epoch)
	if l, ok := r.locals[id]; ok {
		return l.floor, .None
	}
	pbuf: prim.Path_Buf = ---
	fd, oerr := prim.open_file(r.vfs, _floor_path(r, &pbuf, id))
	if oerr == .Not_Found {
		return 0, .None
	}
	if oerr != .None {
		return 0, _from_prim(oerr)
	}
	defer prim.close_file(r.vfs, fd)
	newest, _, count := slots_read(r.vfs, fd) or_return
	if count == 0 {
		return 0, .None
	}
	return newest.value, .None
}

replicator_durable :: proc(r: ^Replicator) {
	list := make([dynamic]^Local, context.temp_allocator)
	for _, l in r.locals {
		if l.cursor < l.durable && l.inflight == 0 && !l.fatal && !l.blocked && !l.retry && !l.verifying && l.ahead == 0 && !l.dropping {
			append(&list, l)
		}
	}
	if len(list) == 0 || r.phase != .Ready {
		return
	}
	_enter(r)
	defer _leave(r)
	for l in list {
		_local_pump(r, l)
	}
	_repl_flush(r)
}


@(private)
_limit :: proc(r: ^Replicator, l: ^Local) -> i64 {
	if r.cfg.durable == nil {
		return l.cursor
	}
	n, ok := r.cfg.durable(r.cfg.user, l.path)
	if !ok {
		return l.cursor
	}
	return max(min(l.durable, n), l.cursor)
}

replicator_publish :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, path: string, durable: i64, tree: ^Key_Tree = nil, hollow := false) -> Error {
	_enter(r)
	defer _leave(r)
	id := stream_id(scope, r.cfg.self, name, epoch)
	l, ok := r.locals[id]
	if !ok {
		l = _local_open(r, scope, name, epoch, id, path) or_return
	}
	if tree != nil {
		l.tree = tree
	}
	if !l.noting {
		l.hollow = hollow
	}
	l.durable = max(l.durable, durable)
	l.blocked = false
	_local_pump(r, l)
	_repl_flush(r)
	return .None
}

replicator_drop :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64) -> Error {
	_enter(r)
	defer _leave(r)
	id := stream_id(scope, r.cfg.self, name, epoch)
	if l, ok := r.locals[id]; ok && l.inflight > 0 {
		return .Busy
	}
	if r.phase != .Ready {
		return .Closed
	}
	client_drop(&r.client, id) or_return
	_repl_flush(r)
	return .None
}

replicator_follow :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, full: bool) -> Error {
	_enter(r)
	defer _leave(r)
	rm := _remote_get(r, scope, device, name, epoch) or_return
	was := rm.follow
	upgrade := full && !rm.full
	rm.follow = true
	rm.full = rm.full || full
	if was && !upgrade {
		return .None
	}
	rm.want_gen += 1
	if r.phase == .Ready {
		if r.cfg.filtered && !was && !rm.grouped {
			pat := [1]Feed_Pattern{{kind = .Exact, bytes = cast([32]u8)rm.id}}
			from := u64(r.feed_cursor) if r.feed_cursor >= 0 else 0
			client_feed_follow(&r.client, from, pat[:], true, true)
		}
		_remote_follow_send(r, rm)
		_remote_settle(r, rm)
		_repl_flush(r)
	}
	return .None
}

replicator_unfollow :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) {
	_enter(r)
	defer _leave(r)
	id := stream_id(scope, device, name, epoch)
	rm, ok := r.remotes[id]
	if !ok || !rm.follow {
		return
	}
	rm.follow = false
	if rm.kfollow {
		_remote_maybe_free(r, rm)
		return
	}
	rm.full = false
	if r.phase == .Ready {
		if r.cfg.filtered {
			_feed_subscribe(r, false)
		} else {
			ids := [1]Stream_Id{id}
			client_unfollow(&r.client, ids[:])
		}
		_repl_flush(r)
	}
	_remote_maybe_free(r, rm)
}

replicator_want :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, ranges: []journal.Range) -> Error {
	_enter(r)
	defer _leave(r)
	for g in ranges {
		if g.from < 0 || g.to < g.from {
			return .Invalid
		}
	}
	rm := _remote_get(r, scope, device, name, epoch) or_return
	for g in ranges {
		rm.backward = g.from < rm.last_from
		rm.last_from = g.from
		_claim(rm, g.from)
		_claim(rm, g.to)
		merged := false
		for &w in rm.wants {
			if w.from <= g.to && g.from <= w.to {
				w.from = min(w.from, g.from)
				w.to = max(w.to, g.to)
				merged = true
				break
			}
		}
		if !merged {
			if _, e := append(&rm.wants, g); e != nil {
				return .No_Memory
			}
		}
		if rm.relay_len < 0 || g.to > rm.relay_len {
			rm.want_gen += 1
		}
	}
	_remote_settle(r, rm)
	_repl_flush(r)
	return .None
}

replicator_want_tail :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, n: i64 = TAIL_DEFAULT) -> Error {
	_enter(r)
	defer _leave(r)
	rm := _remote_get(r, scope, device, name, epoch) or_return
	return _remote_want_tail(r, rm, n)
}

@(private)
_remote_want_tail :: proc(r: ^Replicator, rm: ^Remote, n: i64) -> Error {
	rm.tail = max(rm.tail, max(n, 1))
	rm.backward = true
	rm.want_gen += 1
	_remote_settle(r, rm)
	_repl_flush(r)
	return .None
}

replicator_acquire :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) -> (^journal.Replica, Error) {
	rm, err := _remote_get(r, scope, device, name, epoch)
	if err != .None {
		return nil, err
	}
	rm.refs += 1
	return &rm.rep, .None
}

replicator_release :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) {
	_enter(r)
	defer _leave(r)
	id := stream_id(scope, device, name, epoch)
	if rm, ok := r.remotes[id]; ok && rm.refs > 0 {
		rm.refs -= 1
		_remote_maybe_free(r, rm)
	}
}

replicator_relay_length :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) -> i64 {
	id := stream_id(scope, device, name, epoch)
	if rm, ok := r.remotes[id]; ok {
		return rm.relay_len
	}
	return -1
}

replicator_current :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) -> bool {
	id := stream_id(scope, device, name, epoch)
	if rm, ok := r.remotes[id]; ok {
		return rm.follow
	}
	return false
}




@(private)
_emit :: proc(r: ^Replicator, ev: Repl_Event) {
	_enter(r)
	defer _leave(r)
	e := ev
	r.cfg.on_event(r.cfg.user, &e)
}

@(private)
_floor_path :: proc(r: ^Replicator, buf: ^prim.Path_Buf, id: Stream_Id) -> string {
	n := copy(buf[:], r.dir)
	n += copy(buf[n:], "/up/")
	sid := id
	n += prim.hex_encode(buf[n:], sid[:])
	return string(buf[:n])
}

@(private)
_replica_path :: proc(r: ^Replicator, buf: ^prim.Path_Buf, id: Stream_Id) -> string {
	n := copy(buf[:], r.dir)
	n += copy(buf[n:], "/replicas/")
	sid := id
	n += prim.hex_encode(buf[n:], sid[:])
	return string(buf[:n])
}

@(private)
_local_open :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, id: Stream_Id, path: string) -> (l: ^Local, err: Error) {
	pbuf: prim.Path_Buf = ---
	fpath := _floor_path(r, &pbuf, id)
	ffd, oerr := prim.open_file(r.vfs, fpath, {.Write}, 0o600)
	if oerr == .Not_Found {
		ffd, oerr = prim.open_file(r.vfs, fpath, {.Write, .Create, .Exclusive}, 0o600)
		if oerr == .None {
			_floor_meta_write(r, ffd, name, path)
			if serr := prim.sync_dir(r.vfs, prim.dir_name(fpath)); serr != .None {
				prim.close_file(r.vfs, ffd)
				return nil, _from_prim(serr)
			}
		}
	}
	if oerr != .None {
		return nil, _from_prim(oerr)
	}
	newest, _, count, serr := slots_read(r.vfs, ffd)
	if serr != .None {
		prim.close_file(r.vfs, ffd)
		return nil, serr
	}
	aerr: runtime.Allocator_Error
	l, aerr = new(Local, r.allocator)
	if aerr != nil {
		prim.close_file(r.vfs, ffd)
		return nil, .No_Memory
	}
	l.fd = prim.INVALID_FD
	l.floor_fd = ffd
	if count > 0 {
		l.floor = newest.value
		l.floor_seq = newest.seq
	}
	l.cursor = l.floor
	l.durable = l.floor
	l.epoch = epoch
	l.id = id
	l.key = stream_key(scope, id)
	l.plain = scope.mode == .Transparent
	l.verify = make([dynamic]u8, r.allocator)
	n1, e1 := _clone_string(name, r.allocator)
	p1, e2 := _clone_string(path, r.allocator)
	l.name = n1
	l.path = p1
	if e1 != .None || e2 != .None {
		_local_free(r, l)
		return nil, .No_Memory
	}
	r.locals[id] = l
	return l, .None
}

@(private)
_local_free :: proc(r: ^Replicator, l: ^Local) {
	if l.fd >= 0 {
		prim.close_file(r.vfs, l.fd)
	}
	if l.floor_fd >= 0 {
		prim.close_file(r.vfs, l.floor_fd)
	}
	crypto.zero_explicit(&l.key, size_of(l.key))
	if len(l.drop_path) > 0 {
		delete(l.drop_path, r.allocator)
	}
	delete(l.verify)
	delete(l.name, r.allocator)
	delete(l.path, r.allocator)
	free(l, r.allocator)
}

@(private)
_local_maybe_free :: proc(r: ^Replicator, l: ^Local) {
	if l.fatal || l.inflight > 0 || l.verifying || l.retry || l.ahead > 0 || l.dropping || l.cursor < l.durable || r.rx_local == l {
		return
	}
	if r.hold > 0 {
		if !l.reaping {
			l.reaping = true
			append(&r.reap_local, l)
		}
		return
	}
	delete_key(&r.locals, l.id)
	_local_free(r, l)
}

@(private)
_local_fatal :: proc(r: ^Replicator, l: ^Local, err: Error, length: i64) {
	l.fatal = true
	l.inflight = 0
	l.verifying = false
	clear(&l.verify)
	_emit(r, Repl_Event{kind = .Fatal, err = err, device = r.cfg.self, name = l.name, epoch = l.epoch, stream = l.id, from = l.cursor, to = l.durable, length = length})
}

@(private)
_local_pump :: proc(r: ^Replicator, l: ^Local) {
	if l.superseded {
		_local_maybe_free(r, l)
		return
	}
	if r.phase != .Ready || l.fatal || l.blocked || l.retry || l.inflight > 0 || l.verifying || l.ahead > 0 || l.cursor >= l.durable {
		_local_drop_prev(r, l)
		_local_maybe_free(r, l)
		return
	}
	limit := _limit(r, l)
	if l.cursor >= limit || r.uploading >= MAX_UPLOADS || client_queued(&r.client) >= OUT_HIGH {
		return
	}
	if l.hollow {
		_local_note(r, l, limit)
		return
	}
	if l.fd < 0 {
		fd, err := prim.open_file(r.vfs, l.path)
		if err != .None {
			_local_fatal(r, l, _from_prim(err), -1)
			return
		}
		l.fd = fd
	}
	head: [4]u8
	if n, err := prim.read_at(r.vfs, l.fd, head[:], l.cursor); err != .None || n < 4 {
		_local_fatal(r, l, .Corrupt, -1)
		return
	}
	first := i64(prim.get_u32le(head[:])) + journal.OVERHEAD
	want := min(limit - l.cursor, UPLOAD_CHUNK)
	if first > want {
		want = first
	}
	if first > l.durable - l.cursor || want > APPEND_MAX {
		_local_fatal(r, l, .Corrupt, -1)
		return
	}
	if first > limit - l.cursor {
		return
	}
	dst, rerr := client_append_reserve(&r.client, l.id, l.cursor, int(want))
	if rerr != .None {
		return
	}
	got, gerr := prim.read_at(r.vfs, l.fd, dst, l.cursor)
	k := 0
	if gerr == .None && i64(got) == want {
		k = journal.record_bounds(dst)
	}
	if k == 0 {
		client_append_commit(&r.client, int(want), 0)
		_local_fatal(r, l, .Corrupt, -1)
		return
	}
	if serr := _wire_form(l, dst[:k], l.cursor); serr != .None {
		client_append_commit(&r.client, int(want), 0)
		_local_fatal(r, l, .Corrupt, -1)
		return
	}
	client_append_commit(&r.client, int(want), k)
	l.inflight = i64(k)
	r.uploading += 1
}

@(private)
_wire_form :: proc(l: ^Local, data: []u8, off: i64) -> Error {
	if l.plain {
		pos := 0
		for pos < len(data) {
			if len(data) - pos < journal.OVERHEAD {
				return .Corrupt
			}
			n := int(prim.get_u32le(data[pos:])) + journal.OVERHEAD
			if n > len(data) - pos {
				return .Corrupt
			}
			if e := journal.check_record(data[pos:][:n], off + i64(pos)); e != .None && e != .Redacted {
				return _from_journal(e)
			}
			pos += n
		}
		return .None
	}
	if l.tree != nil {
		return keytree_seal_range(l.tree, data, off)
	}
	return _from_journal(journal.seal_range(data, off, static_provider(&l.key)))
}

@(private)
_local_advance :: proc(r: ^Replicator, l: ^Local, to: i64) -> Error {
	l.cursor = to
	if to > l.floor {
		l.floor = to
		l.floor_seq += 1
		slot_write(r.vfs, l.floor_fd, Slot{seq = l.floor_seq, value = to, start = 0}) or_return
		_from_prim(prim.datasync(r.vfs, l.floor_fd)) or_return
	}
	_emit(r, Repl_Event{kind = .Uploaded, device = r.cfg.self, name = l.name, epoch = l.epoch, stream = l.id, length = to})
	return .None
}

@(private)
_local_drop_prev :: proc(r: ^Replicator, l: ^Local) {
	if !l.dropping || l.fatal || l.inflight > 0 || l.verifying || l.ahead > 0 || l.cursor < l.durable || r.phase != .Ready {
		return
	}
	if client_drop(&r.client, l.drop_id) != .None {
		return
	}
	if prev, ok := r.locals[l.drop_id]; ok && prev != l {
		_local_supersede(r, prev)
	}
	if len(l.drop_path) > 0 {
		journal.journal_remove(r.vfs, l.drop_path)
		delete(l.drop_path, r.allocator)
		l.drop_path = ""
	}
	l.dropping = false
}

@(private)
_local_supersede :: proc(r: ^Replicator, l: ^Local) {
	l.superseded = true
	if l.dropping {
		if r.phase == .Ready {
			client_drop(&r.client, l.drop_id)
		}
		if len(l.drop_path) > 0 {
			journal.journal_remove(r.vfs, l.drop_path)
			delete(l.drop_path, r.allocator)
			l.drop_path = ""
		}
		l.dropping = false
	}
	if l.inflight > 0 && client_cancel_appends(&r.client, l.id) > 0 {
		r.uploading -= 1
		l.inflight = 0
	}
	l.retry = false
	l.blocked = false
	l.verifying = false
	clear(&l.verify)
	l.ahead = 0
	l.durable = l.cursor
	if l.fd >= 0 {
		prim.close_file(r.vfs, l.fd)
		l.fd = prim.INVALID_FD
	}
	_local_maybe_free(r, l)
}

@(private)
_local_ack :: proc(r: ^Replicator, l: ^Local, ev: ^Event) {
	if l.inflight == 0 {
		return
	}
	r.uploading -= 1
	expect := l.cursor + l.inflight
	l.inflight = 0
	if l.superseded {
		_local_maybe_free(r, l)
		return
	}
	if ev.kind == .Appended && ev.length == expect {
		if err := _local_advance(r, l, expect); err != .None {
			_local_fatal(r, l, err, ev.length)
			return
		}
		_local_pump(r, l)
		return
	}
	_local_conflict(r, l, ev.length)
}

@(private)
_local_conflict :: proc(r: ^Replicator, l: ^Local, relay_len: i64) {
	switch {
	case relay_len < l.cursor:
		l.cursor = relay_len
		_local_pump(r, l)
	case relay_len == l.cursor:
		_local_retry(r, l)
	case relay_len > l.durable:
		_local_fatal(r, l, .Conflict, relay_len)
	case:
		l.ahead = relay_len
		_local_verify_next(r, l)
	}
}

@(private)
_local_verify_next :: proc(r: ^Replicator, l: ^Local) {
	if l.cursor >= l.ahead {
		l.ahead = 0
		_local_pump(r, l)
		return
	}
	if l.fd < 0 {
		fd, err := prim.open_file(r.vfs, l.path)
		if err != .None {
			_local_fatal(r, l, _from_prim(err), -1)
			return
		}
		l.fd = fd
	}
	head: [4]u8
	if n, err := prim.read_at(r.vfs, l.fd, head[:], l.cursor); err != .None || n < 4 {
		_local_fatal(r, l, .Corrupt, -1)
		return
	}
	span := l.ahead - l.cursor
	want := min(span, UPLOAD_CHUNK)
	first := i64(prim.get_u32le(head[:])) + journal.OVERHEAD
	if first > span {
		_local_fatal(r, l, .Conflict, l.ahead)
		return
	}
	want = max(want, first)
	buf, aerr := make([]u8, int(want), context.temp_allocator)
	if aerr != nil {
		_local_retry(r, l)
		return
	}
	defer delete(buf, context.temp_allocator)
	got, rerr := prim.read_at(r.vfs, l.fd, buf, l.cursor)
	k := 0
	if rerr == .None && i64(got) == want {
		k = journal.record_bounds(buf)
	}
	if k == 0 {
		_local_fatal(r, l, .Corrupt, -1)
		return
	}
	l.verifying = true
	l.verify_at = l.cursor
	l.verify_to = l.cursor + i64(k)
	clear(&l.verify)
	client_read(&r.client, l.id, l.verify_at, l.verify_to)
}

@(private)
_local_verify_done :: proc(r: ^Replicator, l: ^Local) {
	l.verifying = false
	if l.superseded {
		clear(&l.verify)
		_local_maybe_free(r, l)
		return
	}
	n := l.verify_to - l.verify_at
	if i64(len(l.verify)) != n {
		_local_retry(r, l)
		clear(&l.verify)
		return
	}
	mine, aerr := make([]u8, int(n), context.temp_allocator)
	if aerr != nil {
		_local_retry(r, l)
		return
	}
	defer delete(mine, context.temp_allocator)
	ok := false
	if l.fd < 0 {
		l.fd, _ = prim.open_file(r.vfs, l.path)
	}
	redacted := make([dynamic]journal.Range, context.temp_allocator)
	if got, err := prim.read_at(r.vfs, l.fd, mine, l.verify_at); err == .None && i64(got) == n && journal.record_bounds(mine) == int(n) {
		if _wire_form(l, mine, l.verify_at) == .None {
			ok = _records_match(mine, l.verify[:], l.verify_at, &redacted)
		}
	}
	clear(&l.verify)
	if !ok {
		_local_fatal(r, l, .Conflict, l.verify_to)
		return
	}
	for g in redacted {
		_emit(r, Repl_Event{kind = .Local_Redacted, device = r.cfg.self, name = l.name, epoch = l.epoch, stream = l.id, from = g.from, to = g.to})
	}
	if err := _local_advance(r, l, l.verify_to); err != .None {
		_local_fatal(r, l, err, l.verify_to)
		return
	}
	_local_verify_next(r, l)
}

@(private)
_records_match :: proc(mine, theirs: []u8, base: i64, redacted: ^[dynamic]journal.Range) -> bool {
	if len(mine) != len(theirs) || journal.record_bounds(theirs) != len(theirs) {
		return false
	}
	pos := 0
	for pos < len(mine) {
		n := int(prim.get_u32le(mine[pos:])) + journal.OVERHEAD
		if n > len(mine) - pos || int(prim.get_u32le(theirs[pos:])) + journal.OVERHEAD != n {
			return false
		}
		a := mine[pos:][:n]
		b := theirs[pos:][:n]
		off := base + i64(pos)
		if !_ct_eq(a, b) {
			mr := journal.classify(a, off) == .Redacted
			tr := journal.classify(b, off) == .Redacted
			if !mr && !tr {
				return false
			}
			if tr && !mr {
				append(redacted, journal.Range{off, off + i64(n)})
			}
		}
		pos += n
	}
	return true
}

@(private)
_local_retry :: proc(r: ^Replicator, l: ^Local) {
	l.retry = true
	l.ahead = 0
	if r.retry == 0 {
		r.retry = prim.timer(r.loop, RETRY_MS, r, _on_retry)
	}
}

@(private)
_on_retry :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Replicator)data
	_enter(r)
	defer _leave(r)
	r.retry = 0
	for _, lo in r.locals {
		lo.retry = false
	}
	for id in _sorted_ids(r.remotes) {
		if rm, ok := r.remotes[id]; ok && (rm.tamper_hold || rm.retry_hold) {
			rm.tamper_hold = false
			rm.retry_hold = false
			_remote_pull(r, rm)
			_remote_settle(r, rm)
		}
	}
	_repl_pump(r)
}

@(private)
_remote_get :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) -> (rm: ^Remote, err: Error) {
	id := stream_id(scope, device, name, epoch)
	if existing, ok := r.remotes[id]; ok {
		return existing, .None
	}
	aerr: runtime.Allocator_Error
	rm, aerr = new(Remote, r.allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	pbuf: prim.Path_Buf = ---
	path := _replica_path(r, &pbuf, id)
	if jerr := journal.replica_open(&rm.rep, r.vfs, path, r.allocator); jerr != .None {
		free(rm, r.allocator)
		return nil, _from_journal(jerr)
	}
	rm.device = device
	rm.epoch = epoch
	rm.id = id
	rm.plain = scope.mode == .Transparent
	rm.skey = stream_key(scope, id)
	rm.scope = scope^
	rm.relay_len = -1
	rm.span_fd = prim.INVALID_FD
	_span_load(r, rm, path)
	rm.wants = make([dynamic]journal.Range, r.allocator)
	rm.inflight = make([dynamic]journal.Range, r.allocator)
	rm.verified = make([dynamic]journal.Range, r.allocator)
	rm.claims = make([dynamic]i64, r.allocator)
	rm.pulls = make([dynamic]Pull_Flight, r.allocator)
	rm.refused = make([dynamic]Device_Id, r.allocator)
	rm.carry = make([dynamic]u8, r.allocator)
	nerr, perr: Error
	rm.name, nerr = _clone_string(name, r.allocator)
	rm.path, perr = _clone_string(path, r.allocator)
	if nerr != .None || perr != .None {
		_remote_free(r, rm)
		return nil, .No_Memory
	}
	_pending_apply(r, rm)
	for i in 0 ..< PROBES {
		rm.probes[i] = stream_id(scope, device, name, epoch + 1 + u64(i))
		r.probes[rm.probes[i]] = rm
	}
	r.remotes[id] = rm
	return rm, .None
}

@(private)
_remote_free :: proc(r: ^Replicator, rm: ^Remote) {
	_kwait_release(r, rm)
	for p in rm.probes {
		if cur, ok := r.probes[p]; ok && cur == rm {
			delete_key(&r.probes, p)
		}
	}
	if r.rx_remote == rm {
		_stage_flush(r, true, -1)
		r.rx_remote = nil
	}
	journal.replica_close(&rm.rep)
	delete(rm.kheld)
	crypto.zero_explicit(&rm.skey, size_of(rm.skey))
	scope_clear(&rm.scope)
	if len(rm.head_keys) > 0 {
		delete(rm.head_keys, r.allocator)
	}
	if rm.span_fd >= 0 {
		prim.close_file(r.vfs, rm.span_fd)
	}
	delete(rm.wants)
	delete(rm.inflight)
	delete(rm.verified)
	delete(rm.claims)
	delete(rm.pulls)
	delete(rm.refused)
	delete(rm.carry)
	delete(rm.name, r.allocator)
	delete(rm.path, r.allocator)
	free(rm, r.allocator)
}

@(private)
_remote_maybe_free :: proc(r: ^Replicator, rm: ^Remote) {
	if _following(rm) || rm.refs > 0 || rm.probing || rm.pulling || len(rm.wants) > 0 || len(rm.inflight) > 0 || len(rm.pulls) > 0 || rm.tail > 0 || r.rx_remote == rm {
		return
	}
	if r.hold > 0 {
		if !rm.reaping {
			rm.reaping = true
			append(&r.reap, rm)
		}
		return
	}
	delete_key(&r.remotes, rm.id)
	_remote_free(r, rm)
}

replicator_presence :: proc(r: ^Replicator, device: Device_Id) -> (up: bool, since: i64, known: bool) {
	p, ok := r.presence[device]
	if !ok && r.present_ok && r.phase == .Ready {
		return false, 0, true
	}
	return p.up, p.since, ok
}

replicator_caught_up :: proc(r: ^Replicator) -> bool {
	return r.caught && r.phase == .Ready
}

@(private)
_caught_check :: proc(r: ^Replicator) {
	if r.caught || r.phase != .Ready || r.feed_target < 0 || r.feed_cursor < r.feed_target || r.list_done < r.list_sent {
		return
	}
	r.caught = true
	_emit(r, Repl_Event{kind = .Caught_Up, length = r.feed_cursor})
}

@(private)
_on_presence :: proc(r: ^Replicator, ev: ^Event) {
	if ev.at < 0 {
		if ev.first {
			for _, &p in r.presence {
				p.seen = false
			}
			return
		}
		r.present_ok = true
		gone := make([dynamic]Device_Id, context.temp_allocator)
		for d, p in r.presence {
			if !p.seen && p.up {
				append(&gone, d)
			}
		}
		slice.sort_by(gone[:], proc(a, b: Device_Id) -> bool {
			x, y := a, b
			return mem.compare(x[:], y[:]) < 0
		})
		for d in gone {
			p := r.presence[d]
			p.up = false
			r.presence[d] = p
			_emit(r, Repl_Event{kind = .Presence, device = d, from = 0, length = p.since})
			_peers_presence(r, d, false)
		}
		return
	}
	d: Device_Id
	copy(d[:], ev.id[:16])
	if d == r.cfg.self {
		return
	}
	up := ev.at != 0
	old, had := r.presence[d]
	r.presence[d] = Presence_State{up = up, since = ev.length, seen = true}
	if !had || old.up != up || old.since != ev.length {
		_emit(r, Repl_Event{kind = .Presence, device = d, from = 1 if up else 0, length = ev.length})
		_peers_presence(r, d, up)
	}
}

@(private)
DEADLINE_TICK_MS :: 10_000

@(private)
_deadline_sync :: proc(r: ^Replicator) {
	if r.loop == nil {
		return
	}
	if r.phase == .Ready && client_awaiting(&r.client) > 0 {
		if r.deadline == 0 {
			r.deadline = prim.timer(r.loop, DEADLINE_TICK_MS, r, _on_deadline)
		}
	} else if r.deadline != 0 {
		prim.timer_cancel(r.loop, r.deadline)
		r.deadline = 0
	}
}

@(private)
_on_deadline :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Replicator)data
	r.deadline = 0
	_enter(r)
	defer _leave(r)
	if r.phase == .Ready && client_deadline_tick(&r.client) {
		_repl_fail(r, .Timeout)
	}
}

@(private)
_enter :: proc(r: ^Replicator) {
	r.hold += 1
}

@(private)
_leave :: proc(r: ^Replicator) {
	r.hold -= 1
	if r.hold > 0 {
		return
	}
	if r.kwait_dirty {
		_kwait_sync(r)
	}
	_deadline_sync(r)
	for len(r.reap) > 0 {
		rm := pop(&r.reap)
		rm.reaping = false
		_remote_maybe_free(r, rm)
	}
	for len(r.reap_local) > 0 {
		l := pop(&r.reap_local)
		l.reaping = false
		_local_maybe_free(r, l)
	}
}

@(private)
_contiguous :: proc(rm: ^Remote) -> i64 {
	have := journal.replica_have(&rm.rep)
	if len(have) > 0 && have[0].from == 0 {
		return have[0].to
	}
	return 0
}

@(private)
_remote_follow_send :: proc(r: ^Replicator, rm: ^Remote) {
	rm.pulled = _contiguous(rm) if rm.full else journal.replica_length(&rm.rep)
	_remote_pull(r, rm)
}

@(private)
_remote_pull :: proc(r: ^Replicator, rm: ^Remote) {
	if !_following(rm) || rm.quarantined || rm.keys_wait || rm.tamper_hold || rm.retry_hold || r.phase != .Ready {
		return
	}
	if rm.full {
		from := max(_contiguous(rm), rm.pulled)
		if rm.relay_len < 0 {
			if !rm.pulling {
				rm.pulling = true
				client_read(&r.client, rm.id, from, max(i64))
			}
			return
		}
		if rm.relay_len > from {
			_read_range(r, rm, from, rm.relay_len)
			rm.pulled = rm.relay_len
		}
		return
	}
	if rm.pulled == 0 {
		if rm.relay_len < 0 {
			if rm.tail == 0 {
				rm.tail = TAIL_DEFAULT
			}
			if !_covered_inflight(rm, {-1, -1}) || len(rm.inflight) == 0 {
				client_tail(&r.client, rm.id, rm.tail)
				append(&rm.inflight, journal.Range{-1, -1})
			}
			return
		}
		rm.pulled = rm.relay_len
		return
	}
	if rm.relay_len > rm.pulled {
		_read_range(r, rm, rm.pulled, rm.relay_len)
		rm.pulled = rm.relay_len
	}
}

@(private)
_fetch_gap :: proc(r: ^Replicator, rm: ^Remote, gap: journal.Range) {
	if r.phase != .Ready || rm.keys_wait || rm.tamper_hold || rm.retry_hold || _covered_inflight(rm, gap) {
		return
	}
	prev_end := i64(0)
	next_start := rm.relay_len if rm.relay_len >= gap.to else gap.to
	for h in journal.replica_have(&rm.rep) {
		if h.to <= gap.from {
			prev_end = max(prev_end, h.to)
		} else if h.from >= gap.to {
			next_start = h.from
			break
		}
	}
	fetch := gap
	if fetch.to - fetch.from < MIN_FETCH {
		if rm.backward {
			fetch.from = max(fetch.to - MIN_FETCH, prev_end)
			fetch.to = max(fetch.to, min(fetch.from + MIN_FETCH, next_start))
		} else {
			fetch.to = max(fetch.to, min(fetch.from + MIN_FETCH, next_start))
			fetch.from = min(fetch.from, max(fetch.to - MIN_FETCH, prev_end))
		}
	}
	if !_is_boundary(rm, fetch.from) && !_is_boundary(rm, fetch.to) {
		if rm.backward && next_start > fetch.to && next_start - fetch.from <= STAGE_MAX {
			fetch.to = next_start
		} else {
			fetch.from = prev_end
		}
	}
	if fetch.to - fetch.from > STAGE_MAX {
		if rm.backward && _is_boundary(rm, fetch.to) || !_is_boundary(rm, fetch.from) {
			fetch.from = fetch.to - STAGE_MAX
		} else {
			fetch.to = fetch.from + STAGE_MAX
		}
	}
	if fetch.from < rm.base {
		_pull_range(r, rm, fetch.from, min(fetch.to, rm.base))
		if fetch.to <= rm.base {
			_pull_ahead(r, rm, fetch.to, min(gap.to, rm.base))
			return
		}
		fetch.from = rm.base
	}
	if client_read(&r.client, rm.id, fetch.from, fetch.to) == .None {
		append(&rm.inflight, fetch)
		r.read_reqs += 1
	} else {
		_remote_hold_retry(r, rm)
	}
}

replicator_read_counters :: proc "contextless" (r: ^Replicator) -> (requests: int, bytes: i64) {
	return r.read_reqs, r.read_bytes
}

@(private)
CLAIMS_MAX :: 64

@(private)
_claim :: proc(rm: ^Remote, x: i64) {
	if x <= 0 {
		return
	}
	for c in rm.claims {
		if c == x {
			return
		}
	}
	if len(rm.claims) >= CLAIMS_MAX {
		ordered_remove(&rm.claims, 0)
	}
	append(&rm.claims, x)
}

@(private)
_unclaim :: proc(rm: ^Remote, x: i64) {
	for c, i in rm.claims {
		if c == x {
			ordered_remove(&rm.claims, i)
			return
		}
	}
}

@(private)
_covered_inflight :: proc(rm: ^Remote, g: journal.Range) -> bool {
	for f in rm.inflight {
		if f.from < 0 || (f.from <= g.from && f.to >= g.to) {
			return true
		}
	}
	for p in rm.pulls {
		if g.from >= 0 && p.from <= g.from && p.to >= g.to {
			return true
		}
	}
	return false
}

@(private)
_remote_settle :: proc(r: ^Replicator, rm: ^Remote) {
	fresh := rm.relay_len >= 0 && rm.fresh_gen >= rm.want_gen
	if !fresh {
		_remote_probe(r, rm)
	}
	if rm.tail > 0 && fresh {
		append(&rm.wants, journal.Range{max(rm.relay_len - rm.tail, 0), rm.relay_len})
		rm.tail = 0
	}
	if rm.relay_len < 0 {
		_remote_maybe_free(r, rm)
		return
	}
	for i := 0; i < len(rm.wants); {
		w := rm.wants[i]
		to := min(w.to, rm.relay_len)
		complete := fresh || w.to <= rm.relay_len
		if to <= w.from {
			if !complete {
				i += 1
				continue
			}
			ordered_remove(&rm.wants, i)
			if rm.is_head {
				continue
			}
			_emit(r, Repl_Event{kind = .Present, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = w.from, to = w.from, length = rm.relay_len})
			continue
		}
		gap, missing := journal.replica_missing(&rm.rep, w.from, to)
		if !missing {
			if !complete {
				i += 1
				continue
			}
			v, tlo, thi := _verdict(r, rm, w.from, to)
			if v == .Hold {
				i += 1
				continue
			}
			if v == .Equivocation {
				_quarantine(r, rm, w.from)
				return
			}
			if v == .Tampered {
				_tamper_forget(r, rm, tlo, thi)
				i += 1
				continue
			}
			ordered_remove(&rm.wants, i)
			if rm.is_head {
				_keys_head_seen(r, rm)
				continue
			}
			_emit(r, Repl_Event{kind = .Present, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = w.from, to = to, length = rm.relay_len})
			continue
		}
		_fetch_gap(r, rm, gap)
		i += 1
	}
	_remote_maybe_free(r, rm)
}

@(private)
_remote_probe :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.probing || r.phase != .Ready || rm.quarantined {
		return
	}
	ids: [1 + PROBES]Stream_Id
	ids[0] = rm.id
	copy(ids[1:], rm.probes[:])
	if client_probe(&r.client, ids[:]) == .None {
		rm.probing = true
		rm.probe_gen = rm.want_gen
	}
	_keys_head_watch(r, rm)
}

@(private)
_keys_head_watch :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.is_head || len(rm.name) <= len(KEYS_STREAM) || rm.name[:len(KEYS_STREAM)] != KEYS_STREAM {
		return
	}
	_keys_head_start(r, &rm.scope, rm.device, rm.name, rm.epoch + 1)
}

@(private)
_keys_head_start :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, keys_name: string, min_epoch: u64) {
	hname, err := keys_head_name(keys_name)
	if err != .None {
		return
	}
	head, herr := _remote_get(r, scope, device, hname, 0)
	if herr != .None {
		return
	}
	head.is_head = true
	if len(head.head_keys) == 0 {
		head.head_keys, _ = _clone_string(keys_name, r.allocator)
		head.head_min = min_epoch
	} else {
		head.head_min = min(head.head_min, min_epoch)
	}
	if head.tail == 0 && len(head.wants) == 0 {
		head.tail = 64
		head.want_gen += 1
		_remote_settle(r, head)
	}
}

@(private)
_keys_needed :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.keys_wait {
		return
	}
	rm.keys_wait = true
	_emit(r, Repl_Event{kind = .Keys_Needed, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
	if kn, err := keys_stream_name(rm.name); err == .None {
		_keys_head_start(r, &rm.scope, rm.device, kn, 0)
	}
	_kwait_hold(r, rm)
}

@(private)
_keys_head_seen :: proc(r: ^Replicator, head: ^Remote) {
	if len(head.head_keys) == 0 {
		return
	}
	epoch, ok := _keys_head_epoch(r, head)
	if ok && epoch >= head.head_min {
		_emit(r, Repl_Event{kind = .Epoch_Seen, device = head.device, name = head.head_keys, epoch = epoch, stream = stream_id(&head.scope, head.device, head.head_keys, epoch)})
	}
}

@(private)
_remote_landed :: proc(r: ^Replicator, rm: ^Remote, from, to: i64, stream_len: i64) {
	for i := 0; i < len(rm.inflight); {
		f := rm.inflight[i]
		if f.from < 0 {
			if stream_len >= 0 {
				ordered_remove(&rm.inflight, i)
				continue
			}
		} else if (from <= f.from && to >= f.to) || (to >= stream_len && f.from >= from) || (f.from >= stream_len && to >= stream_len) {
			ordered_remove(&rm.inflight, i)
			continue
		} else if from <= f.from && to > f.from {
			rm.inflight[i].from = to
		}
		i += 1
	}
}

@(private)
_stage_flush :: proc(r: ^Replicator, final: bool, stream_len: i64) {
	if len(r.stage) == 0 {
		return
	}
	rm := r.rx_remote
	keep := 0
	if rm != nil && !rm.quarantined {
		lo, hi, rest, bad := _stage_check(r, rm, final, stream_len)
		if rest == 0 {
			_hold_unchecked(r, rm, lo, hi, bad)
		}
		if hi > lo {
			if err := _stage_write(rm, r.stage_at + i64(lo), r.stage[lo:hi]); err != .None {
				_emit(r, Repl_Event{kind = .Refused, err = _from_journal(err), device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
			} else if !bad {
				r.tamper_run = 0
			}
		}
		if bad {
			_tamper(r, rm)
		} else {
			keep = rest
		}
	}
	if keep > 0 {
		n := len(r.stage) - keep
		copy(r.stage[:], r.stage[n:])
		resize(&r.stage, keep)
		r.stage_at += i64(n)
		return
	}
	r.stage_at += i64(len(r.stage))
	clear(&r.stage)
	if cap(r.stage) > STAGE_MAX * 2 {
		delete(r.stage)
		r.stage = make([dynamic]u8, r.allocator)
	}
}

@(private)
_hold_unchecked :: proc(r: ^Replicator, rm: ^Remote, lo, hi: int, bad: bool) {
	if bad || !rm.keys_wait {
		return
	}
	from, to := 0, len(r.stage)
	if lo == 0 && hi < len(r.stage) {
		from = hi
	} else if lo > 0 && hi == len(r.stage) {
		to = lo
	} else if hi > lo {
		return
	}
	if to <= from {
		return
	}
	at := r.stage_at + i64(from)
	if len(rm.kheld) > 0 && rm.kheld_at + i64(len(rm.kheld)) == at {
		append(&rm.kheld, ..r.stage[from:to])
		return
	}
	clear(&rm.kheld)
	append(&rm.kheld, ..r.stage[from:to])
	rm.kheld_at = at
}

@(private)
_held_apply :: proc(r: ^Replicator, rm: ^Remote) {
	if len(rm.kheld) == 0 {
		return
	}
	saved := r.stage
	saved_at := r.stage_at
	r.stage = rm.kheld
	r.stage_at = rm.kheld_at
	rm.kheld = make([dynamic]u8, r.allocator)
	lo, hi, _, bad := _stage_check(r, rm, true, rm.relay_len)
	if !bad && hi > lo {
		if err := _stage_write(rm, r.stage_at + i64(lo), r.stage[lo:hi]); err == .None {
			_remote_landed(r, rm, r.stage_at + i64(lo), r.stage_at + i64(hi), rm.relay_len)
		}
	}
	delete(r.stage)
	r.stage = saved
	r.stage_at = saved_at
}

@(private)
_tamper :: proc(r: ^Replicator, rm: ^Remote) {
	if _peer_tampered(r, rm) {
		return
	}
	r.tamper_run += 1
	if r.tamper_run == TAMPER_REPORT {
		_emit(r, Repl_Event{kind = .Relay_Misbehaving, err = .Corrupt, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
	}
	if len(r.endpoints) > 1 {
		r.tampered = true
		return
	}
	rm.tamper_hold = true
	if r.retry == 0 {
		r.retry = prim.timer(r.loop, RETRY_MS, r, _on_retry)
	}
}

@(private)
_tamper_forget :: proc(r: ^Replicator, rm: ^Remote, from, to: i64) {
	if to > from {
		journal.replica_forget(&rm.rep, from, to)
		if c := _contiguous(rm); c < rm.pulled {
			rm.pulled = c
		}
	}
	_tamper(r, rm)
}

@(private)
TAMPER_REPORT :: 3











@(private)
_on_data :: proc(r: ^Replicator, ev: ^Event) {
	id := Stream_Id(ev.id)
	if ev.first {
		r.rx_local = nil
		if l, ok := r.locals[id]; ok && l.verifying && ev.at == l.verify_at + i64(len(l.verify)) && ev.at < l.verify_to {
			r.rx_local = l
		}
		if rm := r.rx_remote; rm != nil {
			if rm.id == id && ev.at == r.rx_at {
				return
			}
			if len(r.stage) > 0 && !rm.quarantined && len(r.stage) <= STAGE_MAX {
				clear(&rm.carry)
				append(&rm.carry, ..r.stage[:])
				rm.carry_at = r.stage_at
				clear(&r.stage)
				_remote_landed(r, rm, r.rx_start, rm.carry_at, -1)
			} else {
				_stage_flush(r, true, -1)
				_remote_landed(r, rm, r.rx_start, r.rx_at, -1)
			}
		}
		r.rx_remote = nil
		r.rx_at = ev.at
		r.rx_start = ev.at
		r.stage_at = ev.at
		clear(&r.stage)
		rm, ok := r.remotes[id]
		if !ok {
			return
		}
		r.rx_remote = rm
		if ev.kind == .Data && ev.at < rm.base && r.rx_holder == {} {
			rm.base = ev.at
		}
		if len(rm.carry) > 0 {
			if rm.carry_at + i64(len(rm.carry)) == ev.at {
				append(&r.stage, ..rm.carry[:])
				r.stage_at = rm.carry_at
				r.rx_start = rm.carry_at
			}
			clear(&rm.carry)
		}
		if ev.length > rm.relay_len {
			rm.relay_len = ev.length
		}
		if ev.length > journal.replica_length(&rm.rep) {
			journal.replica_set_length(&rm.rep, ev.length)
		}
		return
	}
	if len(ev.data) > 0 {
		if l := r.rx_local; l != nil && r.rx_at == l.verify_at + i64(len(l.verify)) {
			append(&l.verify, ..ev.data[:min(i64(len(ev.data)), l.verify_to - r.rx_at)])
		}
		if r.rx_remote != nil {
			r.read_bytes += i64(len(ev.data))
			append(&r.stage, ..ev.data)
			if len(r.stage) >= STAGE_MAX {
				_stage_flush(r, false, ev.length)
			}
		}
		r.rx_at += i64(len(ev.data))
	}
	if !ev.last {
		return
	}
	if l := r.rx_local; l != nil {
		r.rx_local = nil
		if r.rx_at >= l.verify_to || r.rx_at >= ev.length {
			_local_verify_done(r, l)
		}
	}
	rm := r.rx_remote
	if rm == nil {
		return
	}
	_stage_flush(r, ev.final, ev.length)
	if !ev.final {
		return
	}
	r.rx_remote = nil
	_remote_landed(r, rm, r.rx_start, r.rx_at, ev.length)
	if rm.full && r.rx_at >= rm.pulled {
		if c := _contiguous(rm); c < rm.pulled {
			rm.pulled = c
		}
	}
	if rm.is_head && rm.kfollow {
		_kwait_head_landed(r, rm)
	} else if rm.kfollow {
		_kwait_keys_landed(r, rm)
	}
	if _following(rm) && r.rx_at > r.rx_start && !rm.quarantined {
		v, vlo, vhi := _verdict(r, rm, r.rx_start, r.rx_at)
		switch v {
		case .Accept:
			from := min(r.rx_start, vlo) if vhi > vlo else r.rx_start
			_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = from, to = r.rx_at, length = rm.relay_len})
		case .Hold:
			if vhi > vlo {
				_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = vlo, to = vhi, length = rm.relay_len})
			}
		case .Equivocation:
			_quarantine(r, rm, r.rx_start)
			return
		case .Tampered:
			_tamper_forget(r, rm, vlo, vhi)
		}
	}
	rm.pulling = false
	if ev.length < rm.pulled {
		rm.pulled = ev.length
	}
	if ev.length < rm.relay_len {
		rm.relay_len = ev.length
	}
	if !rm.full && rm.pulled == 0 && rm.relay_len >= 0 {
		rm.pulled = rm.relay_len
	}
	_remote_settle(r, rm)
	_remote_pull(r, rm)
	_fetch_check(r)
}

@(private)
_seen_stream :: proc(r: ^Replicator, id: Stream_Id, length: i64) {
	dev := stream_device(id)
	if dev != r.cfg.self && !(dev in r.devices) {
		r.devices[dev] = true
		_emit(r, Repl_Event{kind = .Device_Seen, device = dev, stream = id, length = length})
	}
	if rm, ok := r.remotes[id]; ok {
		if length > rm.relay_len {
			rm.relay_len = length
			if length > journal.replica_length(&rm.rep) {
				journal.replica_set_length(&rm.rep, length)
			}
			if rm.is_head && rm.kfollow {
				_kwait_head_want(r, rm)
			}
			if _following(rm) && !rm.full {
				_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = length, to = length, length = length})
			}
		}
		_remote_settle(r, rm)
	}
	_segments_seen(r, id, length)
	if rm, ok := r.probes[id]; ok {
		for p, i in rm.probes {
			if p == id {
				_emit(r, Repl_Event{kind = .Epoch_Seen, device = rm.device, name = rm.name, epoch = rm.epoch + 1 + u64(i), stream = id, length = length})
			}
		}
	}
}

@(private)
_on_event :: proc(user: rawptr, ev: ^Event) -> Error {
	r := cast(^Replicator)user
	_enter(r)
	defer _leave(r)
	switch ev.kind {
	case .Welcome:
		r.phase = .Ready
		if r.tamper_run == 0 {
			r.backoff = BACKOFF_MIN
		}
		r.usage = ev.usage
		r.quota = ev.quota
		r.features = ev.tag
		if r.timer != 0 {
			prim.timer_cancel(r.loop, r.timer)
			r.timer = 0
		}
		_emit(r, Repl_Event{kind = .Connected, usage = ev.usage, quota = ev.quota})
		_repl_on_ready(r)
		_lives_resend(r)
	case .Listing:
		for i in 0 ..< listing_count(ev) {
			l := listing_entry(ev, i)
			_seen_stream(r, l.stream, l.length)
		}
		if !ev.more {
			r.cursor = ev.cursor
			r.listed = true
			_lists_finished(r, .None)
			_caught_check(r)
		}
	case .Appended, .Conflict:
		if l, ok := r.locals[Stream_Id(ev.id)]; ok {
			_local_ack(r, l, ev)
		}
	case .Data:
		_on_data(r, ev)
	case .Object:
		_objs_on_object(r, ev)
	case .Stored:
		_objs_on_stored(r, Object_Key(ev.id))
	case .Missing:
		_objs_on_missing(r, Object_Key(ev.id))
	case .Forgotten:
		_objs_on_forgotten(r, Object_Key(ev.id))
	case .Presence:
		_on_presence(r, ev)
	case .Direct, .Undelivered:
		_on_direct_event(r, ev)
	case .Noted:
		_on_noted(r, ev)
	case .Hollow:
		_on_hollow(r, ev)
	case .Pulled:
		if !_on_draft_pulled(r, ev) {
			_on_pulled(r, ev)
		}
	case .Served:
		if !_on_draft_served(r, ev) {
			_on_served(r, ev)
		}
	case .Accounted:
		if st, ok := accounted_decode(ev.data); ok {
			r.account = st
			r.accounted = true
		}
	case .Unserved:
		if !_on_draft_unserved(r, ev) {
			_on_unserved(r, ev)
		}
	case .Lived:
		_on_lived(r, ev)
	case .Probed:
		if Stream_Id(ev.id) == reserved_id(FEED_TAG, 0) {
			r.feed_target = ev.length
			_caught_check(r)
		} else if rm, ok := r.remotes[Stream_Id(ev.id)]; ok {
			if rm.probing {
				rm.probing = false
				rm.fresh_gen = rm.probe_gen
			}
			rm.relay_len = ev.length
			if ev.length > journal.replica_length(&rm.rep) {
				journal.replica_set_length(&rm.rep, ev.length)
			}
			_remote_pull(r, rm)
			_remote_settle(r, rm)
		}
		_promote_on_probed(r, Stream_Id(ev.id), ev.length)
		if _, known := r.remotes[Stream_Id(ev.id)]; known || ev.length > 0 {
			_seen_stream(r, Stream_Id(ev.id), ev.length)
		}
	case .Length, .Created:
		_seen_stream(r, Stream_Id(ev.id), ev.length)
		if rm, ok := r.remotes[Stream_Id(ev.id)]; ok && ev.kind == .Length {
			_remote_landed(r, rm, ev.length, ev.length, ev.length)
			_remote_settle(r, rm)
		}
	case .Dropped:
		if rm, ok := r.remotes[Stream_Id(ev.id)]; ok {
			_emit(r, Repl_Event{kind = .Dropped, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
		}
	case .Refused:
		_on_refused(r, ev)
	case .Redacted:
		_emit(r, Repl_Event{kind = .Redacted, stream = Stream_Id(ev.id), from = ev.at, to = ev.length})
	case .Announce:
		_on_announce(r, ev)
		_caught_check(r)
	case .Error:
		err := code_error(ev.code)
		if err == .None {
			err = .Refused
		}
		_emit(r, Repl_Event{kind = .Refused, code = ev.code, err = err})
		return err
	}
	if r.tampered {
		r.tampered = false
		return .Corrupt
	}
	_repl_pump(r)
	return .None
}

@(private)
_on_refused :: proc(r: ^Replicator, ev: ^Event) {
	id := Stream_Id(ev.id)
	rv := Repl_Event {
		kind   = .Refused,
		code   = ev.code,
		stream = id,
	}
	if id == reserved_id(ACCOUNT_TAG, 0) {
		return
	}
	if id == reserved_id(LIST_TAG, 0) {
		_lists_finished(r, .Permission if ev.code == .Not_Owner else .Refused)
		_emit(r, rv)
		return
	}
	if _promote_on_refused(r, id, ev.code) {
		return
	}
	if l, ok := r.locals[id]; ok {
		l.noting = false
		if l.inflight > 0 {
			r.uploading -= 1
			l.inflight = 0
		}
		rv.name, rv.epoch, rv.device = l.name, l.epoch, r.cfg.self
		#partial switch ev.code {
		case .Not_Owner:
			_local_fatal(r, l, .Permission, -1)
			return
		case .Quota, .Too_Large:
			l.blocked = true
		case:
			_local_retry(r, l)
		}
		_emit(r, rv)
		return
	}
	if _objs_on_refused(r, Object_Key(ev.id), ev.code) {
		return
	}
	rm, ok := r.remotes[id]
	if ok {
		clear(&rm.inflight)
		rm.probing = false
		rm.pulling = false
		rm.pulled = _contiguous(rm) if rm.full else journal.replica_length(&rm.rep)
		if ev.code == .Not_Owner {
			_remote_deny(r, rm)
		} else {
			_remote_hold_retry(r, rm)
		}
		rv.name, rv.epoch, rv.device = rm.name, rm.epoch, rm.device
	}
	_emit(r, rv)
	if ok {
		_remote_maybe_free(r, rm)
	}
}

@(private)
_repl_on_ready :: proc(r: ^Replicator) {
	if r.cfg.filtered {
		_feed_subscribe(r, r.feed_cursor < 0)
	} else {
		_list_send(r, r.cursor if r.listed else 0)
		if r.feed_cursor >= 0 {
			client_feed_follow(&r.client, u64(r.feed_cursor), nil, false, false, true)
		} else {
			client_feed_follow(&r.client, FEED_DROPPED, nil, false, false, true)
		}
	}
	feed := [1]Stream_Id{reserved_id(FEED_TAG, 0)}
	client_probe(&r.client, feed[:])
	_fetches_ready(r)
	ids := _sorted_ids(r.remotes)
	for id in ids {
		if rm, ok := r.remotes[id]; ok && _following(rm) {
			_remote_follow_send(r, rm)
		}
	}
	for id in ids {
		if rm, ok := r.remotes[id]; ok {
			_remote_settle(r, rm)
		}
	}
}

@(private)
_sorted_ids :: proc(m: map[Stream_Id]$V) -> []Stream_Id {
	ids := make([dynamic]Stream_Id, 0, len(m), context.temp_allocator)
	for id in m {
		append(&ids, id)
	}
	slice.sort_by(ids[:], proc(a, b: Stream_Id) -> bool {
		x, y := a, b
		return mem.compare(x[:], y[:]) < 0
	})
	return ids[:]
}

@(private)
_repl_pump :: proc(r: ^Replicator) {
	if r.pumping {
		return
	}
	r.pumping = true
	defer r.pumping = false
	if r.phase == .Ready {
		for id in _sorted_ids(r.locals) {
			if r.uploading >= MAX_UPLOADS || client_queued(&r.client) >= OUT_HIGH {
				break
			}
			if l, ok := r.locals[id]; ok {
				_local_pump(r, l)
			}
		}
		_objs_pump(r)
		_serves_pump(r)
		_promotions_pump(r)
	}
	_repl_flush(r)
}

@(private)
_repl_reset_state :: proc(r: ^Replicator) {
	_lives_reset(r)
	if r.rx_remote != nil {
		_stage_flush(r, true, -1)
	}
	r.rx_remote = nil
	r.rx_local = nil
	clear(&r.stage)
	r.uploading = 0
	for _, l in r.locals {
		l.inflight = 0
		l.noting = false
		l.verifying = false
		l.ahead = 0
		clear(&l.verify)
	}
	for _, rm in r.remotes {
		clear(&rm.inflight)
		clear(&rm.pulls)
		clear(&rm.refused)
		rm.unavail = false
		rm.base_checked = false
		clear(&rm.carry)
		rm.pulling = false
		rm.probing = false
		rm.retry_hold = false
		rm.denied = false
	}
	clear(&r.serves)
	clear(&r.parked)
	r.rx_holder = {}
	r.rx_skip = false
	_promotions_reset(r)
	_objs_reset(r)
	_fetches_reset(r)
}

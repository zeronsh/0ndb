package osync

import "base:runtime"
import "core:crypto"
import "core:crypto/ecdh"
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
	Quarantined,
	Object_Shredded,
}

Verdict :: enum u8 {
	Accept,
	Hold,
	Equivocation,
}

Verify_Request :: struct {
	device:  Device_Id,
	name:    string,
	epoch:   u64,
	stream:  Stream_Id,
	replica: ^journal.Replica,
	from:    i64,
	to:      i64,
	span:    ^journal.Sig_Info,
	span_ok: ^bool,
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
	padding:      bool,
	kernel_tls:   bool,
	on_event:     Repl_Handler,
	user:         rawptr,
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
	verify:    [dynamic]u8,
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
	held:      i64,
	pulled:    i64,
	pulling:   bool,
	span:      journal.Sig_Info,
	span_ok:   bool,
	span_fd:   prim.Fd,
	span_seq:  u64,
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
	phase:      Phase,
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
	feed_fd:    prim.Fd,
	feed_seq:   u64,
	fetches:    [dynamic]^Ckpt_Fetch,
	lists_out:  int,
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
	pumping:    bool,
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
		r.endpoint = endpoint_parse(cfg.relay) or_return
		if cfg.noise_static != nil {
			ecdh.private_key_set(&r.static, cfg.noise_static)
		} else if !ecdh.private_key_generate(&r.static, .X25519) {
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
	r.feed_fd = prim.INVALID_FD
	_feed_cursor_load(r)
	r.fetches = make([dynamic]^Ckpt_Fetch, allocator)
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
	for _, rm in r.remotes {
		_remote_free(r, rm)
	}
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
	if r.phase == .Stopped && !r.external {
		r.phase = .Waiting
		_repl_connect(r)
	}
}

replicator_stop :: proc(r: ^Replicator) {
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

replicator_publish :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64, path: string, durable: i64, tree: ^Key_Tree = nil) -> Error {
	id := stream_id(scope, r.cfg.self, name, epoch)
	l, ok := r.locals[id]
	if !ok {
		l = _local_open(r, scope, name, epoch, id, path) or_return
	}
	if tree != nil {
		l.tree = tree
	}
	l.durable = max(l.durable, durable)
	l.blocked = false
	_local_pump(r, l)
	_repl_flush(r)
	return .None
}

replicator_drop :: proc(r: ^Replicator, scope: ^Scope, name: string, epoch: u64) -> Error {
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
	rm := _remote_get(r, scope, device, name, epoch) or_return
	was := rm.follow
	rm.follow = true
	rm.full = rm.full || full
	if !was && r.phase == .Ready {
		_remote_follow_send(r, rm)
		_repl_flush(r)
	}
	return .None
}

replicator_unfollow :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64) {
	id := stream_id(scope, device, name, epoch)
	rm, ok := r.remotes[id]
	if !ok || !rm.follow {
		return
	}
	rm.follow = false
	rm.full = false
	if r.phase == .Ready {
		ids := [1]Stream_Id{id}
		client_unfollow(&r.client, ids[:])
		_repl_flush(r)
	}
	_remote_maybe_free(r, rm)
}

replicator_want :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, ranges: []journal.Range) -> Error {
	rm := _remote_get(r, scope, device, name, epoch) or_return
	for g in ranges {
		if g.from < 0 || g.to < g.from {
			return .Invalid
		}
		if _, e := append(&rm.wants, g); e != nil {
			return .No_Memory
		}
	}
	_remote_settle(r, rm)
	_repl_flush(r)
	return .None
}

replicator_want_tail :: proc(r: ^Replicator, scope: ^Scope, device: Device_Id, name: string, epoch: u64, n: i64 = TAIL_DEFAULT) -> Error {
	rm := _remote_get(r, scope, device, name, epoch) or_return
	return _remote_want_tail(r, rm, n)
}

@(private)
_remote_want_tail :: proc(r: ^Replicator, rm: ^Remote, n: i64) -> Error {
	rm.tail = max(rm.tail, max(n, 1))
	if rm.relay_len < 0 && r.phase == .Ready {
		client_tail(&r.client, rm.id, rm.tail) or_return
		if _, e := append(&rm.inflight, journal.Range{-1, -1}); e != nil {
			return .No_Memory
		}
	}
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




@(private)
_emit :: proc(r: ^Replicator, ev: Repl_Event) {
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
	if l.fatal || l.inflight > 0 || l.verifying || l.retry || l.ahead > 0 || l.dropping || l.cursor < l.durable {
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
	if r.phase != .Ready || l.fatal || l.blocked || l.retry || l.inflight > 0 || l.verifying || l.ahead > 0 || l.cursor >= l.durable {
		_local_maybe_free(r, l)
		return
	}
	if r.uploading >= MAX_UPLOADS || client_queued(&r.client) >= OUT_HIGH {
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
	want := min(l.durable - l.cursor, UPLOAD_CHUNK)
	if first > want {
		want = first
	}
	if first > l.durable - l.cursor || want > APPEND_MAX {
		_local_fatal(r, l, .Corrupt, -1)
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
	if l.dropping && l.cursor >= l.durable && r.phase == .Ready {
		client_drop(&r.client, l.drop_id)
		if len(l.drop_path) > 0 {
			journal.journal_remove(r.vfs, l.drop_path)
			delete(l.drop_path, r.allocator)
			l.drop_path = ""
		}
		l.dropping = false
	}
	return .None
}

@(private)
_local_ack :: proc(r: ^Replicator, l: ^Local, ev: ^Event) {
	if l.inflight == 0 {
		return
	}
	r.uploading -= 1
	expect := l.cursor + l.inflight
	l.inflight = 0
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
	if got, err := prim.read_at(r.vfs, l.fd, mine, l.verify_at); err == .None && i64(got) == n && journal.record_bounds(mine) == int(n) {
		if _wire_form(l, mine, l.verify_at) == .None {
			ok = _ct_eq(mine, l.verify[:])
		}
	}
	clear(&l.verify)
	if !ok {
		_local_fatal(r, l, .Conflict, l.verify_to)
		return
	}
	if err := _local_advance(r, l, l.verify_to); err != .None {
		_local_fatal(r, l, err, l.verify_to)
		return
	}
	_local_verify_next(r, l)
}

@(private)
_local_retry :: proc(r: ^Replicator, l: ^Local) {
	l.retry = true
	if r.retry == 0 {
		r.retry = prim.timer(r.loop, RETRY_MS, r, _on_retry)
	}
}

@(private)
_on_retry :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Replicator)data
	r.retry = 0
	for _, lo in r.locals {
		lo.retry = false
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
	rm.relay_len = -1
	rm.span_fd = prim.INVALID_FD
	_span_load(r, rm, path)
	rm.wants = make([dynamic]journal.Range, r.allocator)
	rm.inflight = make([dynamic]journal.Range, r.allocator)
	nerr, perr: Error
	rm.name, nerr = _clone_string(name, r.allocator)
	rm.path, perr = _clone_string(path, r.allocator)
	if nerr != .None || perr != .None {
		_remote_free(r, rm)
		return nil, .No_Memory
	}
	for i in 0 ..< PROBES {
		rm.probes[i] = stream_id(scope, device, name, epoch + 1 + u64(i))
		r.probes[rm.probes[i]] = rm
	}
	r.remotes[id] = rm
	return rm, .None
}

@(private)
_remote_free :: proc(r: ^Replicator, rm: ^Remote) {
	for p in rm.probes {
		if cur, ok := r.probes[p]; ok && cur == rm {
			delete_key(&r.probes, p)
		}
	}
	if r.rx_remote == rm {
		_stage_flush(r)
		r.rx_remote = nil
	}
	journal.replica_close(&rm.rep)
	if rm.span_fd >= 0 {
		prim.close_file(r.vfs, rm.span_fd)
	}
	delete(rm.wants)
	delete(rm.inflight)
	delete(rm.name, r.allocator)
	delete(rm.path, r.allocator)
	free(rm, r.allocator)
}

@(private)
_remote_maybe_free :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.follow || rm.refs > 0 || len(rm.wants) > 0 || len(rm.inflight) > 0 || rm.tail > 0 || r.rx_remote == rm {
		return
	}
	delete_key(&r.remotes, rm.id)
	_remote_free(r, rm)
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
	if !rm.follow || rm.quarantined || r.phase != .Ready {
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
			client_read(&r.client, rm.id, from, rm.relay_len)
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
		client_read(&r.client, rm.id, rm.pulled, rm.relay_len)
		rm.pulled = rm.relay_len
	}
}

@(private)
_covered_inflight :: proc(rm: ^Remote, g: journal.Range) -> bool {
	for f in rm.inflight {
		if f.from < 0 || (f.from <= g.from && f.to >= g.to) {
			return true
		}
	}
	return false
}

@(private)
_remote_settle :: proc(r: ^Replicator, rm: ^Remote) {
	if rm.tail > 0 && rm.relay_len >= 0 {
		append(&rm.wants, journal.Range{max(rm.relay_len - rm.tail, 0), rm.relay_len})
		rm.tail = 0
	}
	if rm.relay_len < 0 {
		return
	}
	for i := 0; i < len(rm.wants); {
		w := rm.wants[i]
		to := min(w.to, rm.relay_len)
		if to <= w.from {
			ordered_remove(&rm.wants, i)
			_emit(r, Repl_Event{kind = .Present, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = w.from, to = w.from, length = rm.relay_len})
			continue
		}
		gap, missing := journal.replica_missing(&rm.rep, w.from, to)
		if !missing {
			v := _verdict(r, rm, w.from, to)
			if v == .Hold {
				i += 1
				continue
			}
			if v == .Equivocation {
				_quarantine(r, rm, w.from)
				return
			}
			ordered_remove(&rm.wants, i)
			_emit(r, Repl_Event{kind = .Present, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = w.from, to = to, length = rm.relay_len})
			continue
		}
		if r.phase == .Ready && !_covered_inflight(rm, gap) {
			fetch := gap
			if fetch.to - fetch.from < MIN_FETCH {
				fetch.from = max(fetch.to - MIN_FETCH, 0)
			}
			if client_read(&r.client, rm.id, fetch.from, fetch.to) == .None {
				append(&rm.inflight, fetch)
			}
		}
		i += 1
	}
	_remote_maybe_free(r, rm)
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
_stage_flush :: proc(r: ^Replicator) {
	if len(r.stage) == 0 {
		return
	}
	if rm := r.rx_remote; rm != nil && !rm.quarantined {
		if err := _stage_write(rm, r.stage_at, r.stage[:]); err != .None {
			_emit(r, Repl_Event{kind = .Refused, err = _from_journal(err), device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id})
		}
	}
	r.stage_at += i64(len(r.stage))
	clear(&r.stage)
	if cap(r.stage) > STAGE_MAX * 2 {
		delete(r.stage)
		r.stage = make([dynamic]u8, r.allocator)
	}
}











@(private)
_on_data :: proc(r: ^Replicator, ev: ^Event) {
	id := Stream_Id(ev.id)
	if ev.first {
		r.rx_remote = nil
		r.rx_local = nil
		r.rx_at = ev.at
		r.rx_start = ev.at
		r.stage_at = ev.at
		clear(&r.stage)
		if l, ok := r.locals[id]; ok && l.verifying {
			r.rx_local = l
			return
		}
		rm, ok := r.remotes[id]
		if !ok {
			return
		}
		r.rx_remote = rm
		if ev.length > rm.relay_len {
			rm.relay_len = ev.length
		}
		if ev.length > journal.replica_length(&rm.rep) {
			journal.replica_set_length(&rm.rep, ev.length)
		}
		return
	}
	if len(ev.data) > 0 {
		if l := r.rx_local; l != nil {
			if r.rx_at >= l.verify_at && r.rx_at + i64(len(ev.data)) <= l.verify_to && r.rx_at == l.verify_at + i64(len(l.verify)) {
				append(&l.verify, ..ev.data)
			}
		} else if r.rx_remote != nil {
			append(&r.stage, ..ev.data)
			if len(r.stage) >= STAGE_MAX {
				_stage_flush(r)
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
		return
	}
	rm := r.rx_remote
	if rm == nil {
		return
	}
	_stage_flush(r)
	r.rx_remote = nil
	_remote_landed(r, rm, r.rx_start, r.rx_at, ev.length)
	if rm.follow && r.rx_at > r.rx_start && !rm.quarantined {
		switch _verdict(r, rm, r.rx_start, r.rx_at) {
		case .Accept:
			_emit(r, Repl_Event{kind = .Grew, device = rm.device, name = rm.name, epoch = rm.epoch, stream = rm.id, from = r.rx_start, to = r.rx_at, length = rm.relay_len})
		case .Hold:
		case .Equivocation:
			_quarantine(r, rm, r.rx_start)
			return
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
			if rm.follow && !rm.full {
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
	switch ev.kind {
	case .Welcome:
		r.phase = .Ready
		r.backoff = BACKOFF_MIN
		r.usage = ev.usage
		r.quota = ev.quota
		if r.timer != 0 {
			prim.timer_cancel(r.loop, r.timer)
			r.timer = 0
		}
		_emit(r, Repl_Event{kind = .Connected, usage = ev.usage, quota = ev.quota})
		_repl_on_ready(r)
	case .Listing:
		for i in 0 ..< listing_count(ev) {
			l := listing_entry(ev, i)
			_seen_stream(r, l.stream, l.length)
		}
		if !ev.more {
			r.cursor = ev.cursor
			r.listed = true
			_lists_finished(r)
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
	case .Error:
		return .Auth if ev.code == .Auth else .Refused
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
	if l, ok := r.locals[id]; ok {
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
	if rm, ok := r.remotes[id]; ok {
		clear(&rm.inflight)
		rv.name, rv.epoch, rv.device = rm.name, rm.epoch, rm.device
	}
	_emit(r, rv)
}

@(private)
_repl_on_ready :: proc(r: ^Replicator) {
	if client_list(&r.client, r.cursor if r.listed else 0) == .None {
		r.lists_out += 1
	}
	if r.feed_cursor >= 0 {
		client_feed_follow(&r.client, u64(r.feed_cursor))
	} else {
		client_feed_follow(&r.client, FEED_DROPPED)
	}
	_fetches_ready(r)
	for _, rm in r.remotes {
		if rm.follow {
			_remote_follow_send(r, rm)
		}
	}
	for _, rm in r.remotes {
		_remote_settle(r, rm)
	}
}

@(private)
_repl_pump :: proc(r: ^Replicator) {
	if r.pumping {
		return
	}
	r.pumping = true
	defer r.pumping = false
	if r.phase == .Ready {
		for _, l in r.locals {
			if r.uploading >= MAX_UPLOADS || client_queued(&r.client) >= OUT_HIGH {
				break
			}
			_local_pump(r, l)
		}
		_objs_pump(r)
	}
	_repl_flush(r)
}

@(private)
_repl_reset_state :: proc(r: ^Replicator) {
	if r.rx_remote != nil {
		_stage_flush(r)
	}
	r.rx_remote = nil
	r.rx_local = nil
	clear(&r.stage)
	r.uploading = 0
	for _, l in r.locals {
		l.inflight = 0
		l.verifying = false
		l.ahead = 0
		clear(&l.verify)
	}
	for _, rm in r.remotes {
		clear(&rm.inflight)
		rm.pulling = false
	}
	_objs_reset(r)
	_fetches_reset(r)
}

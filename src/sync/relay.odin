#+build linux, darwin, windows
package osync

import "base:runtime"
import "core:strings"
import "../pack"
import "../prim"

Relay_Config :: struct {
	vfs:             prim.Vfs,
	dir:             string,
	listen:          []string,
	allow_file:      string,
	open:            bool,
	default_quota:   i64,
	authorizer:      Authorizer,
	storage:         Relay_Storage,
	max_conns:       int,
	max_pending:     int,
	max_space_conns: int,
	max_follows:     int,
	handshake_ms:    i64,
	sync_threads:    int,
	compact_header:  bool,
	pack:            bool,
	feed_compact:    i64,
	source_conns:    int,
	source_rate:     int,
	source_burst:    int,
	principal_conns: int,
	kernel_tls:      bool,
	random:          prim.Random,
	clock:           prim.Clock,
	objects:         Object_Store,
	flush_ms:        i64,
	flush_max_ms:    i64,
	flush_bytes:     i64,
	hot:             i64,
}

Relay :: struct {
	core:       Relay_Core,
	vfs:        prim.Vfs,
	loop:       ^prim.Loop,
	cfg:        Relay_Config,
	root:       string,
	lock:       prim.Fd,
	key:        Relay_Key,
	has_key:    bool,
	own_store:  ^File_Store,
	own_pack:   ^pack.Pack,
	own_auth:   ^Relay_Auth,
	own_tier:   ^Tier_Store,
	listeners:  [dynamic]^Listener,
	socks:      [dynamic]^Sock,
	graveyard:  [dynamic]^Sock,
	sources:    map[[16]u8]Source,
	scratch:    []u8,
	wake_timer: prim.Timer,
	pack_timer: prim.Timer,
	prev_wake:  prim.Wake_Proc,
	prev_data:  rawptr,
	waking:     bool,
	shaking:    int,
	kernel:     int,
	accepted:   u64,
	limited:    u64,
	allocator:  runtime.Allocator,
}

Listener :: struct {
	relay: ^Relay,
	fd:    prim.Fd,
	watch: prim.Watch,
	unix:  bool,
	ws:    bool,
	path:  string,
}

@(private)
Sock_State :: enum u8 {
	Upgrade,
	Handshake,
	Attached,
}

@(private)
Sock :: struct {
	relay:    ^Relay,
	fd:       prim.Fd,
	watch:    prim.Watch,
	timer:    prim.Timer,
	state:    Sock_State,
	local:    bool,
	tr:       Transport,
	hs:       [2 + MSG1_LEN]u8,
	hs_have:  int,
	source:   [16]u8,
	sourced:  bool,
	ref:      Conn_Ref,
	attached: bool,
	shaking:  bool,
	kernel:   bool,
	dead:     bool,
}

RELAY_PACK_ROLL :: 256 << 10

relay_config :: proc(dir: string) -> Relay_Config {
	return Relay_Config {
		dir = dir,
		max_conns = 100_000,
		max_pending = 1024,
		max_space_conns = 4096,
		max_follows = 16384,
		handshake_ms = 10_000,
		sync_threads = 4,
		kernel_tls = true,
	}
}

relay_init :: proc(r: ^Relay, l: ^prim.Loop, cfg: Relay_Config, allocator := context.allocator) -> (err: Error) {
	r^ = {
		loop      = l,
		cfg       = cfg,
		lock      = prim.INVALID_FD,
		allocator = allocator,
	}
	r.vfs = cfg.vfs if cfg.vfs.procs != nil else prim.os_vfs()
	if r.cfg.max_conns <= 0 {
		r.cfg.max_conns = 100_000
	}
	if r.cfg.max_pending <= 0 {
		r.cfg.max_pending = 1024
	}
	if r.cfg.handshake_ms <= 0 {
		r.cfg.handshake_ms = 10_000
	}
	if r.cfg.source_conns <= 0 {
		r.cfg.source_conns = 256
	}
	if r.cfg.source_rate <= 0 {
		r.cfg.source_rate = 50
	}
	if r.cfg.source_burst <= 0 {
		r.cfg.source_burst = 100
	}
	r.sources = make(map[[16]u8]Source, allocator)
	r.cfg.listen = nil
	r.listeners = make([dynamic]^Listener, allocator)
	r.socks = make([dynamic]^Sock, allocator)
	r.graveyard = make([dynamic]^Sock, allocator)
	defer if err != .None {
		relay_destroy(r)
	}
	if len(cfg.dir) > 0 {
		r.root = _clone_string(cfg.dir, allocator) or_return
		if merr := prim.mkdir_all(r.vfs, r.root, 0o700); merr != .None {
			return _from_prim(merr)
		}
		lock_path, _ := prim.path_join(context.temp_allocator, r.root, "relay.lock")
		lfd, lerr := prim.lock_file(r.vfs, lock_path)
		if lerr != .None {
			return _from_prim(lerr)
		}
		r.lock = lfd
		r.key = relay_key_load_or_create(r.vfs, r.root, r.cfg.random) or_return
		r.has_key = true
	}
	r.cfg.dir = r.root
	sc, serr := make([]u8, WSCRATCH, allocator)
	if serr != nil {
		return .No_Memory
	}
	r.scratch = sc
	store := cfg.storage
	if store.data == nil {
		store = _relay_own_storage(r, l, cfg) or_return
	}
	if cfg.objects.put != nil {
		ts, aerr := new(Tier_Store, allocator)
		if aerr != nil {
			return .No_Memory
		}
		if terr := tier_store_init(ts, l, store, Tier_Config{objects = cfg.objects, window_ms = cfg.flush_ms, max_ms = cfg.flush_max_ms, max_bytes = cfg.flush_bytes, hot = cfg.hot}, cfg.clock, allocator); terr != .None {
			free(ts, allocator)
			return terr
		}
		r.own_tier = ts
		store = tier_store(ts)
		if r.own_store != nil {
			tier_store_sweep(ts, _relay_spaces(r))
		}
	}
	auth := cfg.authorizer
	if auth.authorize == nil {
		ra, rerr := relay_auth_new(r.vfs, r.root, cfg, store, allocator)
		if rerr != .None {
			return rerr
		}
		r.own_auth = ra
		auth = member_authorizer(&ra.members)
	}
	core := Relay_Core_Config {
		storage         = store,
		authorizer      = auth,
		clock           = cfg.clock,
		max_space_conns = cfg.max_space_conns,
		max_follows     = cfg.max_follows,
		principal_conns = cfg.principal_conns,
		feed_compact    = cfg.feed_compact,
		wake            = _relay_wake,
		wake_data       = r,
	}
	relay_core_init(&r.core, core, allocator) or_return
	_raise_nofile()
	return .None
}

@(private)
_relay_own_storage :: proc(r: ^Relay, l: ^prim.Loop, cfg: Relay_Config) -> (store: Relay_Storage, err: Error) {
	allocator := r.allocator
	if len(r.root) == 0 {
		return {}, .Invalid
	}
	fs, aerr := new(File_Store, allocator)
	if aerr != nil {
		return {}, .No_Memory
	}
	store_vfs := r.vfs
	threads := cfg.sync_threads
	lay := LAYOUT_COMPACT if cfg.compact_header else LAYOUT_SECTOR
	if cfg.pack {
		pk, perr := new(pack.Pack, allocator)
		if perr != nil {
			free(fs, allocator)
			return {}, .No_Memory
		}
		proot, _ := prim.path_join(context.temp_allocator, r.root, "spaces")
		if merr := prim.mkdir_all(r.vfs, proot, 0o700); merr != .None {
			free(pk, allocator)
			free(fs, allocator)
			return {}, _from_prim(merr)
		}
		popts := pack.DEFAULT_OPTIONS
		popts.roll_min = RELAY_PACK_ROLL
		popts.wake = _relay_pack_wake
		popts.wake_data = r
		if oerr := pack.open(pk, r.vfs, proot, popts, allocator); oerr != .None {
			free(pk, allocator)
			free(fs, allocator)
			return {}, _from_prim(oerr)
		}
		r.own_pack = pk
		store_vfs = pack.vfs(pk)
		threads = 0
		lay = LAYOUT_COMPACT
		lay.exact = true
	}
	group: Group_Commit
	if r.own_pack != nil {
		group = Group_Commit{data = r, begin = _pack_begin, end = _pack_end, end_async = _pack_end_async}
		r.prev_wake, r.prev_data = l.wake_cb, l.wake_data
		prim.loop_on_wake(l, _relay_on_wake, r)
		r.waking = true
	}
	if ferr := file_store_init(fs, l, store_vfs, r.root, threads, lay, group, cfg.random, cfg.clock, allocator); ferr != .None {
		if r.own_pack != nil {
			pack.close(r.own_pack)
			free(r.own_pack, allocator)
			r.own_pack = nil
		}
		free(fs, allocator)
		return {}, ferr
	}
	r.own_store = fs
	if r.own_pack != nil {
		fs.resolver = _pack_resolver(r.own_pack)
		fs.pack = r.own_pack
		fs.worker.prepare = proc(data: rawptr) {
			relay_core_prepare(&(cast(^Relay)data).core)
		}
		fs.worker.prep_data = r
	}
	return file_store(fs), .None
}

@(private)
_relay_spaces :: proc(r: ^Relay) -> []Space_Id {
	fs := r.own_store
	ids := make([dynamic]Space_Id, context.temp_allocator)
	root, _ := prim.path_join(context.temp_allocator, fs.root, "spaces")
	d: prim.Dir
	if prim.dir_open(fs.vfs, &d, root, context.temp_allocator) != .None {
		return nil
	}
	defer prim.dir_close(fs.vfs, &d)
	for {
		e, more, err := prim.dir_next(fs.vfs, &d)
		if !more || err != .None {
			break
		}
		if id, ok := prim.id_parse(e.name); ok {
			append(&ids, Space_Id(id))
		}
	}
	return ids[:]
}

relay_destroy :: proc(r: ^Relay) {
	for ln in r.listeners {
		_listener_close(r, ln)
	}
	delete(r.listeners)
	for len(r.socks) > 0 {
		_sock_close(r.socks[len(r.socks) - 1])
	}
	relay_core_close_all(&r.core)
	if r.own_tier != nil {
		tier_store_flush_all(r.own_tier)
	}
	if r.own_pack != nil {
		pack.sync(r.own_pack)
	}
	if r.waking && r.loop != nil {
		prim.loop_on_wake(r.loop, r.prev_wake, r.prev_data)
		r.waking = false
	}
	if r.own_store != nil {
		w := &r.own_store.worker
		for i := 0; i < 64 && (len(w.inline_q) > 0 || w.inflight > 0); i += 1 {
			_worker_ready(w.loop, prim.INVALID_FD, {}, w)
			if r.own_pack != nil {
				pack.sync(r.own_pack)
			}
		}
		worker_destroy(w)
		if r.own_pack != nil {
			pack.sync(r.own_pack)
		}
		r.own_store.worker = {}
	}
	if r.wake_timer != 0 {
		prim.timer_cancel(r.loop, r.wake_timer)
		r.wake_timer = 0
	}
	if r.pack_timer != 0 {
		prim.timer_cancel(r.loop, r.pack_timer)
		r.pack_timer = 0
	}
	relay_core_destroy(&r.core)
	if r.own_tier != nil {
		tier_store_destroy(r.own_tier)
		free(r.own_tier, r.allocator)
	}
	_sock_reap(r)
	delete(r.socks)
	delete(r.graveyard)
	delete(r.sources)
	if r.own_store != nil {
		delete(r.own_store.scratch, r.allocator)
		delete(r.own_store.udirty)
		delete(r.own_store.root, r.allocator)
		free(r.own_store, r.allocator)
	}
	if r.own_pack != nil {
		pack.close(r.own_pack)
		free(r.own_pack, r.allocator)
	}
	if r.own_auth != nil {
		relay_auth_free(r.own_auth, r.allocator)
	}
	if r.scratch != nil {
		delete(r.scratch, r.allocator)
	}
	relay_key_clear(&r.key)
	if r.lock >= 0 {
		prim.close_file(r.vfs, r.lock)
	}
	if len(r.root) > 0 {
		delete(r.root, r.allocator)
	}
	r^ = {}
}

relay_public_key :: proc "contextless" (r: ^Relay) -> Public_Key {
	return r.key.public
}

relay_stats :: proc "contextless" (r: ^Relay) -> Relay_Stats {
	s := relay_core_stats(&r.core)
	s.conns += r.shaking
	s.pending += r.shaking
	s.kernel_tls = r.kernel
	s.accepted = r.accepted
	s.limited = r.limited
	return s
}

relay_quiet :: proc "contextless" (r: ^Relay) -> bool {
	if r.shaking > 0 || r.wake_timer != 0 || r.pack_timer != 0 || !relay_core_quiet(&r.core) {
		return false
	}
	if r.own_store != nil && worker_busy(&r.own_store.worker) {
		return false
	}
	for s in r.socks {
		if !s.dead && transport_pending(&s.tr) {
			return false
		}
	}
	return true
}

relay_space_stats :: proc(r: ^Relay, space: Space_Id) -> (Relay_Space_Stats, bool) {
	return relay_core_space_stats(&r.core, space)
}

relay_storage :: proc "contextless" (r: ^Relay) -> Relay_Storage {
	return r.core.store
}

relay_attach :: proc(r: ^Relay, link: Link, local: bool, binding: []u8 = nil) -> (ref: Conn_Ref, err: Error) {
	return relay_core_attach(&r.core, link, local, binding)
}

relay_input :: proc(r: ^Relay, ref: Conn_Ref, data: []u8) -> Error {
	return relay_core_input(&r.core, ref, data)
}

relay_writable :: proc(r: ^Relay, ref: Conn_Ref) {
	relay_core_writable(&r.core, ref)
}

relay_detach :: proc(r: ^Relay, ref: Conn_Ref) {
	relay_core_detach(&r.core, ref)
}

relay_listen :: proc(r: ^Relay, addr: string) -> Error {
	a := addr
	ws := false
	if strings.has_prefix(a, "ws://") {
		ws = true
		a = a[len("ws://"):]
		if slash := strings.index_byte(a, '/'); slash >= 0 {
			a = a[:slash]
		}
	}
	ep := endpoint_parse(a) or_return
	if ws && ep.family == .Unix {
		return .Invalid
	}
	if ep.family == .Host {
		ep = endpoint_resolve(&ep) or_return
	}
	if ep.family != .Unix && !r.has_key {
		return .Invalid
	}
	fd := _listen(&ep) or_return
	ln, aerr := new(Listener, r.allocator)
	if aerr != nil {
		prim.close(fd)
		return .No_Memory
	}
	ln.relay = r
	ln.fd = fd
	ln.ws = ws
	ln.unix = ep.family == .Unix
	if ln.unix {
		ln.path, _ = _clone_string(string(ep.path[:ep.path_len]), r.allocator)
		_tighten_mode(prim.os_vfs(), ln.path)
	}
	w, werr := prim.watch(r.loop, fd, {.Read}, ln, _on_listen)
	if werr != .None {
		prim.close(fd)
		if len(ln.path) > 0 {
			delete(ln.path, r.allocator)
		}
		free(ln, r.allocator)
		return _from_prim(werr)
	}
	ln.watch = w
	if _, e := append(&r.listeners, ln); e != nil {
		_listener_close(r, ln)
		return .No_Memory
	}
	return .None
}

relay_adopt :: proc(r: ^Relay, fd: prim.Fd, unix: bool, initial: []u8 = nil) -> Error {
	s := _sock_new(r, fd, unix) or_return
	if s.attached && len(initial) > 0 {
		relay_core_input(&r.core, s.ref, initial)
	}
	_sock_readable(s)
	_sock_writable(s)
	_sock_reap(r)
	return .None
}

relay_run :: proc(cfg: Relay_Config) -> Error {
	l: prim.Loop
	if err := prim.loop_init(&l); err != .None {
		return _from_prim(err)
	}
	defer prim.loop_destroy(&l)
	r: Relay
	relay_init(&r, &l, cfg) or_return
	defer relay_destroy(&r)
	for a in cfg.listen {
		relay_listen(&r, a) or_return
	}
	return _from_prim(prim.loop_run(&l))
}

@(private)
_relay_wake :: proc(data: rawptr) {
	r := cast(^Relay)data
	if r.wake_timer == 0 {
		r.wake_timer = prim.timer(r.loop, 0, r, _on_relay_wake)
	}
}

@(private)
_on_relay_wake :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Relay)data
	r.wake_timer = 0
	relay_core_resume(&r.core)
	_sock_reap(r)
}

@(private)
_listener_close :: proc(r: ^Relay, ln: ^Listener) {
	if ln.watch != 0 {
		prim.unwatch(r.loop, ln.watch)
	}
	prim.close(ln.fd)
	if ln.unix && len(ln.path) > 0 {
		prim.remove(prim.os_vfs(), ln.path)
		delete(ln.path, r.allocator)
	}
	free(ln, r.allocator)
}

@(private)
_on_listen :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	ln := cast(^Listener)data
	r := ln.relay
	for {
		cfd, src, err := _accept(ln.fd)
		if err != .None {
			break
		}
		r.accepted += 1
		st := relay_stats(r)
		if st.conns >= r.cfg.max_conns || (!ln.unix && st.pending >= r.cfg.max_pending) {
			prim.close(cfd)
			continue
		}
		if ln.unix && !_peer_is_self(cfd) {
			prim.close(cfd)
			continue
		}
		if !ln.unix && !_source_admit(r, src) {
			r.limited += 1
			prim.close(cfd)
			continue
		}
		s, serr := _sock_new(r, cfd, ln.unix, ln.ws)
		if !ln.unix {
			if serr == .None {
				s.source = src
				s.sourced = true
			} else {
				_source_leave(r, src)
			}
		}
	}
	_sock_reap(r)
}

@(private)
_sock_new :: proc(r: ^Relay, fd: prim.Fd, unix: bool, ws := false) -> (s: ^Sock, err: Error) {
	ns, aerr := new(Sock, r.allocator)
	if aerr != nil {
		prim.close(fd)
		return nil, .No_Memory
	}
	s = ns
	s.relay = r
	s.fd = fd
	s.local = unix
	s.state = .Handshake
	transport_init_plain(&s.tr, fd, r.allocator)
	if _, e := append(&r.socks, s); e != nil {
		prim.close(fd)
		free(s, r.allocator)
		return nil, .No_Memory
	}
	s.shaking = true
	r.shaking += 1
	if ws {
		s.tr.ws, err = ws_new(r.allocator)
		if err != .None {
			_sock_close(s)
			return nil, err
		}
		s.state = .Upgrade
	}
	if !unix {
		_tune_tcp(fd)
	}
	w, werr := prim.watch(r.loop, fd, {.Read, .Write}, s, _on_sock)
	if werr != .None {
		_sock_close(s)
		return nil, _from_prim(werr)
	}
	s.watch = w
	transport_attach(&s.tr, r.loop, w)
	s.timer = prim.timer(r.loop, r.cfg.handshake_ms, s, _on_sock_timeout)
	if unix {
		if e := _sock_attach(s, nil); e != .None {
			_sock_close(s)
			return nil, e
		}
	}
	return s, .None
}

@(private)
_sock_attach :: proc(s: ^Sock, binding: []u8) -> Error {
	r := s.relay
	link := Link {
		data     = s,
		send     = _sock_send,
		sendfile = _sock_sendfile,
		close    = _sock_core_closed,
		recv     = _sock_recv,
	}
	ref := relay_core_attach(&r.core, link, s.local, binding) or_return
	s.ref = ref
	s.attached = true
	s.state = .Attached
	if s.shaking {
		s.shaking = false
		r.shaking -= 1
	}
	return .None
}

@(private)
_on_sock_timeout :: proc(l: ^prim.Loop, data: rawptr) {
	s := cast(^Sock)data
	r := s.relay
	s.timer = 0
	if !s.attached || !relay_core_ready(&r.core, s.ref) {
		_sock_close(s)
	}
	_sock_reap(r)
}

@(private)
_on_sock :: proc(l: ^prim.Loop, fd: prim.Fd, events: prim.Events, data: rawptr) {
	s := cast(^Sock)data
	r := s.relay
	if .Read in events || .Hangup in events || .Error in events {
		_sock_readable(s)
	}
	_sock_writable(s)
	_sock_reap(r)
}

@(private)
_sock_readable :: proc(s: ^Sock) {
	r := s.relay
	if s.dead {
		return
	}
	if s.state == .Upgrade {
		err := ws_upgrade(s.tr.ws, s.fd)
		if err == .Would_Block {
			return
		}
		if err != .None {
			_sock_close(s)
			return
		}
		s.state = .Handshake
	}
	if s.state == .Handshake {
		_sock_handshake(s)
		if s.dead || s.state == .Handshake {
			return
		}
	}
	relay_core_readable(&r.core, s.ref)
	if !s.dead && s.timer != 0 && relay_core_ready(&r.core, s.ref) {
		prim.timer_cancel(r.loop, s.timer)
		s.timer = 0
	}
}

@(private)
_sock_writable :: proc(s: ^Sock) {
	r := s.relay
	if s.dead {
		return
	}
	if transport_pending(&s.tr) {
		if e := transport_flush(&s.tr); e != .None {
			if e != .Would_Block {
				_sock_close(s)
			}
			return
		}
	}
	if s.attached {
		relay_core_writable(&r.core, s.ref)
	}
}

@(private)
_sock_handshake :: proc(s: ^Sock) {
	r := s.relay
	need := 2 + MSG1_LEN
	for s.hs_have < need {
		want := 2 if s.hs_have < 2 else need
		n, err := _t_recv(&s.tr, s.hs[s.hs_have:want])
		if err == .Would_Block {
			return
		}
		if err != .None {
			_sock_close(s)
			return
		}
		s.hs_have += n
		if s.hs_have == 2 && int(s.hs[0]) | int(s.hs[1]) << 8 != MSG1_LEN {
			_sock_close(s)
			return
		}
	}
	h: Handshake
	out: [2 + MSG2_LEN + 16]u8
	_, keys, err := handshake_respond(&h, &r.key, s.hs[2:need], out[2:], r.cfg.random)
	if err != .None {
		_sock_close(s)
		return
	}
	defer session_keys_clear(&keys)
	out[0] = u8(MSG2_LEN)
	out[1] = 0
	w, serr := _t_send(&s.tr, out[:2 + MSG2_LEN], false)
	if serr != .None || w != 2 + MSG2_LEN {
		_sock_close(s)
		return
	}
	transport_init_secure(&s.tr, s.fd, &keys, r.cfg.kernel_tls && s.tr.ws == nil, r.allocator)
	if s.tr.ktx || s.tr.krx {
		s.kernel = true
		r.kernel += 1
	}
	if e := _sock_attach(s, keys.hash[:]); e != .None {
		_sock_close(s)
	}
}

@(private)
_sock_send :: proc(data: rawptr, bytes: []u8, more: bool) -> (int, Error) {
	s := cast(^Sock)data
	if transport_pending(&s.tr) {
		if e := transport_flush(&s.tr); e != .None {
			return 0, e
		}
	}
	return transport_send(&s.tr, bytes, more)
}

@(private)
_sock_sendfile :: proc(data: rawptr, fd: prim.Fd, off: i64, n: int) -> (int, Error) {
	s := cast(^Sock)data
	if transport_pending(&s.tr) {
		if e := transport_flush(&s.tr); e != .None {
			return 0, e
		}
	}
	return transport_sendfile(&s.tr, fd, off, n, s.relay.scratch)
}

@(private)
_sock_recv :: proc(data: rawptr, buf: []u8) -> (int, Error) {
	s := cast(^Sock)data
	return transport_recv(&s.tr, buf)
}

@(private)
_sock_core_closed :: proc(data: rawptr) {
	s := cast(^Sock)data
	s.attached = false
	_sock_close(s)
}

@(private)
_sock_close :: proc(s: ^Sock) {
	if s.dead {
		return
	}
	r := s.relay
	s.dead = true
	if s.timer != 0 {
		prim.timer_cancel(r.loop, s.timer)
		s.timer = 0
	}
	if s.watch != 0 {
		prim.unwatch(r.loop, s.watch)
		s.watch = 0
	}
	if s.attached {
		s.attached = false
		relay_core_detach(&r.core, s.ref)
	}
	transport_close(&s.tr)
	s.fd = prim.INVALID_FD
	if s.sourced {
		_source_leave(r, s.source)
		s.sourced = false
	}
	if s.shaking {
		s.shaking = false
		r.shaking -= 1
	}
	if s.kernel {
		s.kernel = false
		r.kernel -= 1
	}
	for i := 0; i < len(r.socks); i += 1 {
		if r.socks[i] == s {
			unordered_remove(&r.socks, i)
			break
		}
	}
	append(&r.graveyard, s)
}

@(private)
_sock_reap :: proc(r: ^Relay) {
	for s in r.graveyard {
		free(s, r.allocator)
	}
	clear(&r.graveyard)
}

Source :: struct {
	conns:  int,
	tokens: i64,
	last:   i64,
}

@(private)
SOURCE_TABLE_MAX :: 65536

@(private)
_source_admit :: proc(r: ^Relay, src: [16]u8) -> bool {
	now := prim.clock_mono_ns(r.cfg.clock)
	burst := i64(r.cfg.source_burst) * 1_000_000
	s, ok := r.sources[src]
	if !ok {
		if len(r.sources) >= SOURCE_TABLE_MAX {
			_source_sweep(r, now)
			if len(r.sources) >= SOURCE_TABLE_MAX {
				return false
			}
		}
		s = Source{tokens = burst, last = now}
	}
	s.tokens = min(burst, s.tokens + (now - s.last) / 1000 * i64(r.cfg.source_rate))
	s.last = now
	if s.conns >= r.cfg.source_conns || s.tokens < 1_000_000 {
		r.sources[src] = s
		return false
	}
	s.tokens -= 1_000_000
	s.conns += 1
	r.sources[src] = s
	return true
}

@(private)
_source_leave :: proc(r: ^Relay, src: [16]u8) {
	if s, ok := r.sources[src]; ok {
		s.conns = max(s.conns - 1, 0)
		r.sources[src] = s
	}
}

@(private)
_source_sweep :: proc(r: ^Relay, now: i64) {
	burst := i64(r.cfg.source_burst) * 1_000_000
	gone := make([dynamic][16]u8, context.temp_allocator)
	for k in prim.sorted_keys(r.sources) {
		if k not_in r.sources {
			continue
		}
		s := r.sources[k]
		refilled := min(burst, s.tokens + (now - s.last) / 1000 * i64(r.cfg.source_rate))
		if s.conns == 0 && refilled >= burst {
			append(&gone, k)
		}
	}
	for k in gone {
		delete_key(&r.sources, k)
	}
}

@(private)
_pack_begin :: proc(data: rawptr) {
	pack.batch_begin((cast(^Relay)data).own_pack)
}

@(private)
_pack_end :: proc(data: rawptr) -> Error {
	r := cast(^Relay)data
	err := _from_prim(pack.batch_end(r.own_pack))
	if err == .None && r.pack_timer == 0 && r.loop != nil {
		r.pack_timer = prim.timer(r.loop, 0, r, _on_pack_timer)
	}
	return err
}

@(private)
Relay_Commit :: struct {
	r:    ^Relay,
	done: proc(ctx: rawptr, err: Error),
	ctx:  rawptr,
}

@(private)
_pack_end_async :: proc(data: rawptr, done: proc(ctx: rawptr, err: Error), ctx: rawptr) {
	r := cast(^Relay)data
	g := new(Relay_Commit, r.allocator)
	g^ = {r = r, done = done, ctx = ctx}
	if err := pack.batch_end_async(r.own_pack, _relay_commit_done, g); err != .None {
		free(g, r.allocator)
		done(ctx, _from_prim(err))
		return
	}
	if r.pack_timer == 0 && r.loop != nil {
		r.pack_timer = prim.timer(r.loop, 0, r, _on_pack_timer)
	}
}

@(private)
_relay_commit_done :: proc(data: rawptr, err: prim.Error) {
	g := cast(^Relay_Commit)data
	done, ctx := g.done, g.ctx
	free(g, g.r.allocator)
	done(ctx, _from_prim(err))
}

@(private)
_relay_pack_wake :: proc(data: rawptr) {
	r := cast(^Relay)data
	if r.loop != nil {
		prim.wake(r.loop)
	}
}

@(private)
_relay_on_wake :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Relay)data
	if r.prev_wake != nil {
		r.prev_wake(l, r.prev_data)
	}
	if r.own_pack != nil {
		pack.poll(r.own_pack)
		if r.pack_timer == 0 {
			r.pack_timer = prim.timer(r.loop, 0, r, _on_pack_timer)
		}
	}
}

@(private)
_on_pack_timer :: proc(l: ^prim.Loop, data: rawptr) {
	r := cast(^Relay)data
	r.pack_timer = 0
	more, err := pack.step(r.own_pack)
	if err == .None && more {
		r.pack_timer = prim.timer(r.loop, 0, r, _on_pack_timer)
	}
}

@(private)
_pack_resolver :: proc(p: ^pack.Pack) -> Extent_Resolver {
	when #defined(pack.extent) {
		return Extent_Resolver{data = p, resolve = proc(data: rawptr, fd: prim.Fd, off: i64, n: i64) -> (prim.Fd, i64, i64, bool) {
			ph, ok := pack.extent(cast(^pack.Pack)data, fd, off, n)
			return ph.fd, ph.off, ph.len, ok
		}}
	} else {
		return {}
	}
}

Relay_Auth :: struct {
	allow:   Allow,
	members: Member_Authorizer,
}

relay_auth_new :: proc(vfs: prim.Vfs, root: string, cfg: Relay_Config, store: Relay_Storage, allocator := context.allocator) -> (ra: ^Relay_Auth, err: Error) {
	aerr: runtime.Allocator_Error
	ra, aerr = new(Relay_Auth, allocator)
	if aerr != nil {
		return nil, .No_Memory
	}
	allow_path := cfg.allow_file
	if len(allow_path) == 0 && len(root) > 0 {
		allow_path, _ = prim.path_join(context.temp_allocator, root, "allow")
	}
	ap := _clone_string(allow_path, allocator) or_return
	allow_init(&ra.allow, vfs, ap, allocator)
	dir := "members"
	if len(root) > 0 {
		dir, _ = prim.path_join(context.temp_allocator, root, "members")
	}
	if e := member_authorizer_init(&ra.members, vfs, dir, {}, cfg.open, cfg.default_quota, cfg.clock, &ra.allow, allocator); e != .None {
		allow_destroy(&ra.allow)
		delete(ap, allocator)
		free(ra, allocator)
		return nil, e
	}
	ra.members.store = store
	return ra, .None
}

relay_auth_free :: proc(ra: ^Relay_Auth, allocator := context.allocator) {
	member_authorizer_destroy(&ra.members)
	if len(ra.allow.path) > 0 {
		delete(ra.allow.path, allocator)
	}
	allow_destroy(&ra.allow)
	free(ra, allocator)
}

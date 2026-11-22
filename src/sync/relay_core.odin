package osync

import "base:runtime"
import "core:mem"
import "core:slice"
import "../prim"

Relay_Stats :: struct {
	conns:      int,
	pending:    int,
	ready:      int,
	kernel_tls: int,
	spaces:     int,
	streams:    int,
	accepted:   u64,
	limited:    u64,
	appends:    u64,
	bytes_in:   u64,
	bytes_out:  u64,
	notes:      u64,
	fills:      u64,
	pulls:      u64,
	served:     u64,
	piped_bytes: u64,
}

Relay_Space_Stats :: struct {
	loaded:      bool,
	conns:       int,
	streams:     int,
	stored:      i64,
	quota:       i64,
	appends:     u64,
	bytes_in:    u64,
	notes:       u64,
	fills:       u64,
	pulls:       u64,
	piped_bytes: u64,
	store:       Store_Account,
}

Conn_Ref :: struct {
	slot: u32,
	gen:  u32,
}

Link :: struct {
	data:     rawptr,
	send:     proc(data: rawptr, bytes: []u8, more: bool) -> (int, Error),
	sendfile: proc(data: rawptr, fd: prim.Fd, off: i64, n: int) -> (int, Error),
	close:    proc(data: rawptr),
	pause:    proc(data: rawptr, paused: bool),
	recv:     proc(data: rawptr, buf: []u8) -> (int, Error),
}

Relay_Core_Config :: struct {
	storage:         Relay_Storage,
	authorizer:      Authorizer,
	clock:           prim.Clock,
	max_space_conns: int,
	max_follows:     int,
	principal_conns: int,
	feed_compact:    i64,
	wake:            proc(data: rawptr),
	wake_data:       rawptr,
}

Relay_Core :: struct {
	cfg:        Relay_Core_Config,
	store:      Relay_Storage,
	auth:       Authorizer,
	conns:      [dynamic]^Conn,
	gens:       [dynamic]u32,
	free:       [dynamic]u32,
	graveyard:  [dynamic]^Conn,
	spaces:     map[Space_Id]^Space_State,
	principals: map[[32]u8]int,
	yielded:    [dynamic]^Space_State,
	rscratch:   []u8,
	wscratch:   []u8,
	stats:      Relay_Stats,
	allocator:  runtime.Allocator,
}

Space_State :: struct {
	id:       Space_Id,
	ns:       rawptr,
	quota:    i64,
	usage:    i64,
	reserved: i64,
	streams:  map[Stream_Id]^Stream_State,
	watchers: [dynamic]^Conn,
	conns:    int,
	jobs:     int,
	feed:     ^Stream_State,
	feed_len: i64,
	feed_q:   [dynamic]u8,
	feed_busy: bool,
	feeders:  [dynamic]^Conn,
	feed_epoch: u64,
	feed_base: i64,
	feed_flight: [dynamic]u8,
	feed_wait: [dynamic]^Pending,
	feed_ready: bool,
	feed_folded: i64,
	phase:    Compact_Phase,
	relay:    ^Relay_Core,
	compact_buf: [dynamic]u8,
	compact_yield: bool,
	freeze:   bool,
	compact_busy: bool,
	compact_it: rawptr,
	compact_copied: i64,
	next_epoch: u64,
	meta:     ^Stream_State,
	next_feed: ^Stream_State,
	redlog:   ^Stream_State,
	redlog_q: [dynamic]u8,
	redlog_qp: [dynamic]^Pending,
	redlog_flight: [dynamic]u8,
	redlog_fp: [dynamic]^Pending,
	redlog_busy: bool,
	compact_red: i64,
	compact_red_end: i64,
	present:  map[Device_Id]Presence_Entry,
	pipes:    [dynamic]Pipe,
	live:     [dynamic]^Conn,
	count:    Relay_Space_Stats,
}

@(private)
Presence_Entry :: struct {
	conns: int,
	since: i64,
}

Stream_State :: struct {
	space:     ^Space_State,
	id:        Stream_Id,
	h:         rawptr,
	length:    i64,
	base:      i64,
	refs:      int,
	followers: [dynamic]^Conn,
	busy:      bool,
	poisoned:  bool,
	dropped:   bool,
}

Sub :: struct {
	stream: ^Stream_State,
	offset: i64,
}

Op_Kind :: enum u8 {
	None,
	Append,
	Put,
	Discard,
	Fill,
	Serve,
}

Op :: struct {
	kind:   Op_Kind,
	stream: ^Stream_State,
	w:      rawptr,
	total:  i64,
	failed: Error,
	key:    Object_Key,
	reply:  Kind,
	code:   Code,
	id:     [32]u8,
	len:    i64,
	base:   i64,
	buf:    []u8,
	pos:    int,
	pipe:   Pipe,
}

Out_Kind :: enum u8 {
	Bytes,
	Data,
	Object,
}

Out :: struct {
	kind:    Out_Kind,
	small:   [64]u8,
	hlen:    int,
	hpos:    int,
	buf:     []u8,
	stream:  ^Stream_State,
	at:      i64,
	to:      i64,
	left:    i64,
	started: bool,
	reply:   bool,
	key:     Object_Key,
	obj:     rawptr,
	piped:   bool,
}


@(private)
Pending_Kind :: enum u8 {
	Append,
	Put,
	Drop,
	Redact,
	Feed,
	Forget,
	Compact,
	Meta,
	Redlog,
	Note,
	Fill,
}

@(private)
Pending :: struct {
	relay:  ^Relay_Core,
	kind:   Pending_Kind,
	conn:   Conn_Ref,
	stream: ^Stream_State,
	space:  ^Space_State,
	total:  i64,
	from:   i64,
	need:   i64,
	length: i64,
	id:     [32]u8,
}

@(private)
MAX_INFLIGHT :: 32
@(private)
MAX_OUT :: 256
@(private)
SENDFILE_CHUNK :: 1 << 20
@(private)
RSCRATCH :: 256 * 1024
@(private)
WSCRATCH :: 64 * 1024

Conn_State :: enum u8 {
	Hello,
	Ready,
}

Conn :: struct {
	relay:     ^Relay_Core,
	ref:       Conn_Ref,
	state:     Conn_State,
	local:     bool,
	link:      Link,
	binding:   [HASH_LEN]u8,
	bind_len:  int,
	principal: Principal,
	space:     ^Space_State,
	parser:    Parser,
	op:        Op,
	out:       [dynamic]Out,
	out_head:  int,
	subs:      [dynamic]Sub,
	rr:        int,
	scan:      bool,
	listing:   ^Listing,
	stash:     [dynamic]u8,
	inflight:  int,
	paused:    bool,
	feeding:   bool,
	pumping:   bool,
	again:     bool,
	closing:   bool,
	dead:      bool,
	watching:  bool,
	counted:   bool,
	blocked:   bool,
	feed_on:   bool,
	feed_off:  i64,
	feed_told: i64,
	feed_hint: bool,
	filter:    ^Feed_Filter,
	presence:  bool,
	present:   bool,
	pkey:      [32]u8,
	pcounted:  bool,
	piped:     i64,
	pipe_wait: bool,
	pipe_on:   Conn_Ref,
}

relay_core_config :: proc() -> Relay_Core_Config {
	return Relay_Core_Config {
		max_space_conns = 4096,
		max_follows = 16384,
		principal_conns = 1024,
		feed_compact = FEED_COMPACT_DEFAULT,
	}
}

relay_core_init :: proc(r: ^Relay_Core, cfg: Relay_Core_Config, allocator := context.allocator) -> Error {
	r^ = {
		cfg       = cfg,
		store     = cfg.storage,
		auth      = cfg.authorizer,
		allocator = allocator,
	}
	if r.cfg.max_space_conns <= 0 {
		r.cfg.max_space_conns = 4096
	}
	if r.cfg.max_follows <= 0 {
		r.cfg.max_follows = 16384
	}
	if r.cfg.principal_conns <= 0 {
		r.cfg.principal_conns = 1024
	}
	if r.cfg.feed_compact == 0 {
		r.cfg.feed_compact = FEED_COMPACT_DEFAULT
	}
	if r.store.namespace_open == nil || r.auth.authorize == nil {
		return .Invalid
	}
	r.conns = make([dynamic]^Conn, allocator)
	r.gens = make([dynamic]u32, allocator)
	r.free = make([dynamic]u32, allocator)
	r.graveyard = make([dynamic]^Conn, allocator)
	r.spaces = make(map[Space_Id]^Space_State, allocator)
	r.principals = make(map[[32]u8]int, allocator)
	r.yielded = make([dynamic]^Space_State, allocator)
	rs, e1 := make([]u8, RSCRATCH, allocator)
	ws, e2 := make([]u8, WSCRATCH, allocator)
	r.rscratch = rs
	r.wscratch = ws
	if e1 != nil || e2 != nil {
		relay_core_destroy(r)
		return .No_Memory
	}
	return .None
}

relay_core_destroy :: proc(r: ^Relay_Core) {
	for c in r.conns {
		if c != nil {
			_conn_close(c)
		}
	}
	_reap(r)
	for _, sp in r.spaces {
		if sp.compact_it != nil {
			r.store.list_end(r.store.data, sp.compact_it)
		}
		for _, st in sp.streams {
			if st.h != nil {
				r.store.stream_close(r.store.data, st.h)
			}
			delete(st.followers)
			free(st, r.allocator)
		}
		delete(sp.streams)
		delete(sp.watchers)
		if sp.ns != nil {
			r.store.namespace_close(r.store.data, sp.ns)
		}
		free(sp, r.allocator)
	}
	delete(r.spaces)
	delete(r.principals)
	delete(r.conns)
	delete(r.gens)
	delete(r.free)
	delete(r.graveyard)
	delete(r.yielded)
	if r.rscratch != nil {
		delete(r.rscratch, r.allocator)
	}
	if r.wscratch != nil {
		delete(r.wscratch, r.allocator)
	}
	r^ = {}
}

relay_core_close_all :: proc(r: ^Relay_Core) {
	for c in r.conns {
		if c != nil {
			_conn_close(c)
		}
	}
	_reap(r)
}

relay_core_stats :: proc "contextless" (r: ^Relay_Core) -> Relay_Stats {
	s := r.stats
	s.spaces = len(r.spaces)
	return s
}

relay_core_quiet :: proc "contextless" (r: ^Relay_Core) -> bool {
	if len(r.yielded) > 0 {
		return false
	}
	for c in r.conns {
		if c == nil || c.dead {
			continue
		}
		if c.op.kind != .None || c.inflight > 0 || c.out_head < len(c.out) || c.listing != nil || !parser_idle(&c.parser) {
			return false
		}
	}
	return true
}

relay_core_space_stats :: proc(r: ^Relay_Core, space: Space_Id) -> (st: Relay_Space_Stats, ok: bool) {
	if sp, loaded := r.spaces[space]; loaded {
		st = sp.count
		st.loaded = true
		st.conns = sp.conns
		st.streams = len(sp.streams)
		st.stored = sp.usage
		st.quota = sp.quota
		if r.store.account != nil {
			st.store = r.store.account(r.store.data, sp.ns)
		}
		return st, true
	}
	ns, usage, err := r.store.namespace_open(r.store.data, space)
	if err != .None {
		return {}, false
	}
	st.stored = usage
	if r.store.account != nil {
		st.store = r.store.account(r.store.data, ns)
	}
	r.store.namespace_close(r.store.data, ns)
	return st, true
}

relay_core_attach :: proc(r: ^Relay_Core, link: Link, local: bool, binding: []u8 = nil) -> (ref: Conn_Ref, err: Error) {
	c := _conn_alloc(r) or_return
	c.link = link
	c.local = local
	c.state = .Hello
	c.bind_len = copy(c.binding[:], binding)
	if len(binding) > HASH_LEN {
		buf: [16 + HASH_LEN]u8
		m := hello_message(binding, &buf)
		c.bind_len = copy(c.binding[:], m[16:])
	}
	return c.ref, .None
}

relay_core_ready :: proc "contextless" (r: ^Relay_Core, ref: Conn_Ref) -> bool {
	c := _conn_lookup(r, ref)
	return c != nil && c.state == .Ready
}

relay_core_readable :: proc(r: ^Relay_Core, ref: Conn_Ref) -> Error {
	c := _conn_lookup(r, ref)
	if c == nil {
		return .Closed
	}
	_conn_read(c)
	_conn_pump(c)
	dead := c.dead
	_reap(r)
	return .Closed if dead else .None
}

relay_core_resume :: proc(r: ^Relay_Core) {
	if len(r.yielded) == 0 {
		return
	}
	list := make([dynamic]^Space_State, 0, len(r.yielded), context.temp_allocator)
	append(&list, ..r.yielded[:])
	clear(&r.yielded)
	for sp in list {
		sp.compact_yield = false
	}
	for sp in list {
		if sp.compact_yield {
			continue
		}
		_compact_step(r, sp)
		_feed_flush(r, sp)
	}
	_reap(r)
}

@(private)
_core_yield :: proc(r: ^Relay_Core, sp: ^Space_State) {
	sp.compact_yield = true
	append(&r.yielded, sp)
	if len(r.yielded) == 1 {
		r.cfg.wake(r.cfg.wake_data)
	}
}

@(private)
_core_unyield :: proc(r: ^Relay_Core, sp: ^Space_State) {
	if !sp.compact_yield {
		return
	}
	sp.compact_yield = false
	for i := 0; i < len(r.yielded); i += 1 {
		if r.yielded[i] == sp {
			ordered_remove(&r.yielded, i)
			return
		}
	}
}

relay_core_input :: proc(r: ^Relay_Core, ref: Conn_Ref, data: []u8) -> Error {
	c := _conn_lookup(r, ref)
	if c == nil {
		return .Closed
	}
	r.stats.bytes_in += u64(len(data))
	if c.paused || len(c.stash) > 0 {
		if _, e := append(&c.stash, ..data); e != nil {
			_conn_close(c)
			_reap(r)
			return .No_Memory
		}
	} else {
		_feed(c, data)
	}
	_conn_pump(c)
	dead := c.dead
	_reap(r)
	return .Closed if dead else .None
}

relay_core_writable :: proc(r: ^Relay_Core, ref: Conn_Ref) {
	if c := _conn_lookup(r, ref); c != nil {
		_conn_pump(c)
	}
	_reap(r)
}

relay_core_detach :: proc(r: ^Relay_Core, ref: Conn_Ref) {
	if c := _conn_lookup(r, ref); c != nil {
		c.link.close = nil
		_conn_close(c)
	}
	_reap(r)
}

relay_core_stream_changed :: proc(r: ^Relay_Core, space: Space_Id, id: Stream_Id, length: i64) {
	sp, ok := r.spaces[space]
	if !ok {
		return
	}
	st, sok := sp.streams[id]
	if !sok || st.busy || length <= st.length {
		return
	}
	st.length = length
	for f in st.followers {
		f.scan = true
		_conn_kick(f)
	}
	_reap(r)
}

@(private)
_conn_alloc :: proc(r: ^Relay_Core) -> (c: ^Conn, err: Error) {
	slot: u32
	if n := len(r.free); n > 0 {
		slot = r.free[n - 1]
		pop(&r.free)
	} else {
		if _, e := append(&r.conns, nil); e != nil {
			return nil, .No_Memory
		}
		if _, e := append(&r.gens, 0); e != nil {
			pop(&r.conns)
			return nil, .No_Memory
		}
		slot = u32(len(r.conns) - 1)
	}
	nc, aerr := new(Conn, r.allocator)
	if aerr != nil {
		append(&r.free, slot)
		return nil, .No_Memory
	}
	c = nc
	r.gens[slot] += 1
	r.conns[slot] = c
	c.relay = r
	c.ref = {slot, r.gens[slot]}
	parser_init(&c.parser, true, r.allocator)
	c.out = make([dynamic]Out, r.allocator)
	c.subs = make([dynamic]Sub, r.allocator)
	c.stash = make([dynamic]u8, r.allocator)
	r.stats.conns += 1
	r.stats.pending += 1
	c.counted = true
	return c, .None
}

@(private)
_reap :: proc(r: ^Relay_Core) {
	for c in r.graveyard {
		parser_destroy(&c.parser)
		delete(c.out)
		delete(c.subs)
		delete(c.stash)
		free(c, r.allocator)
	}
	clear(&r.graveyard)
}

@(private)
_conn_lookup :: proc "contextless" (r: ^Relay_Core, ref: Conn_Ref) -> ^Conn {
	if u64(ref.slot) >= u64(len(r.conns)) || r.gens[ref.slot] != ref.gen {
		return nil
	}
	c := r.conns[ref.slot]
	if c == nil || c.dead {
		return nil
	}
	return c
}

@(private)
_conn_close :: proc(c: ^Conn) {
	if c.dead {
		return
	}
	r := c.relay
	c.dead = true
	_op_abort(c)
	for &s in c.subs {
		_remove_conn(&s.stream.followers, c)
		_stream_unref(r, s.stream)
	}
	clear(&c.subs)
	for i in c.out_head ..< len(c.out) {
		_out_release(r, &c.out[i])
	}
	clear(&c.out)
	c.out_head = 0
	if c.listing != nil {
		_listing_end(c)
	}
	if c.pcounted {
		if n := r.principals[c.pkey] - 1; n > 0 {
			r.principals[c.pkey] = n
		} else {
			delete_key(&r.principals, c.pkey)
		}
		c.pcounted = false
	}
	sp := c.space
	if sp != nil {
		_pipes_conn_closed(r, sp, c)
		_remove_conn(&sp.live, c)
		_presence_leave(r, sp, c)
		if c.watching {
			_remove_conn(&sp.watchers, c)
		}
		if c.feed_on {
			_remove_conn(&sp.feeders, c)
		}
		_filter_free(c)
		sp.conns -= 1
		c.space = nil
		_space_release(r, sp)
	}
	if c.link.close != nil {
		c.link.close(c.link.data)
	}
	if c.counted {
		r.stats.conns -= 1
		switch c.state {
		case .Ready:
			r.stats.ready -= 1
		case .Hello:
			r.stats.pending -= 1
		}
		c.counted = false
	}
	r.conns[c.ref.slot] = nil
	append(&r.free, c.ref.slot)
	append(&r.graveyard, c)
}

@(private)
_presence_join :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn) {
	d := c.principal.participant
	e := sp.present[d]
	e.conns += 1
	c.present = true
	if e.conns == 1 {
		e.since = prim.clock_mono_ns(r.cfg.clock)
		sp.present[d] = e
		_presence_send(r, sp, c, d, true, e.since)
		return
	}
	sp.present[d] = e
}

@(private)
_presence_leave :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn) {
	if !c.present {
		return
	}
	c.present = false
	d := c.principal.participant
	e, ok := sp.present[d]
	if !ok {
		return
	}
	e.conns -= 1
	if e.conns > 0 {
		sp.present[d] = e
		return
	}
	delete_key(&sp.present, d)
	_presence_send(r, sp, c, d, false, prim.clock_mono_ns(r.cfg.clock))
}

@(private)
_presence_send :: proc(r: ^Relay_Core, sp: ^Space_State, from: ^Conn, d: Device_Id, up: bool, at: i64) {
	b: [FRAME_HEADER + 3 + PRESENCE_ENTRY]u8
	frame_header(b[:], .Presence, 3 + PRESENCE_ENTRY)
	b[FRAME_HEADER] = 0
	b[FRAME_HEADER + 1] = 1
	b[FRAME_HEADER + 2] = 0
	e := b[FRAME_HEADER + 3:]
	v := d
	copy(e[:16], v[:])
	e[16] = 1 if up else 0
	prim.put_u64le(e[17:], u64(at))
	for f in sp.feeders {
		if f != from && f.presence && _can(f, .List, {}) {
			_push_small(f, b[:])
			_conn_kick(f)
		}
	}
}

@(private)
_presence_snapshot :: proc(r: ^Relay_Core, sp: ^Space_State, c: ^Conn) {
	n := len(sp.present)
	buf, aerr := make([]u8, FRAME_HEADER + 3 + n * PRESENCE_ENTRY, r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	ids := make([dynamic]Device_Id, 0, n, context.temp_allocator)
	for d in sp.present {
		append(&ids, d)
	}
	slice.sort_by(ids[:], proc(a, b: Device_Id) -> bool {
		x, y := a, b
		return mem.compare(x[:], y[:]) < 0
	})
	frame_header(buf, .Presence, 3 + n * PRESENCE_ENTRY)
	buf[FRAME_HEADER] = PRESENCE_SNAPSHOT
	buf[FRAME_HEADER + 1] = u8(n)
	buf[FRAME_HEADER + 2] = u8(n >> 8)
	for d, i in ids {
		e := buf[FRAME_HEADER + 3 + i * PRESENCE_ENTRY:]
		v := d
		copy(e[:16], v[:])
		e[16] = 1
		prim.put_u64le(e[17:], u64(sp.present[d].since))
	}
	_push_buf(c, buf)
}

@(private)
_remove_conn :: proc(list: ^[dynamic]^Conn, c: ^Conn) {
	for i := 0; i < len(list); i += 1 {
		if list[i] == c {
			unordered_remove(list, i)
			return
		}
	}
}

@(private)
_conn_ready :: proc(c: ^Conn) {
	r := c.relay
	c.state = .Ready
	r.stats.pending -= 1
	r.stats.ready += 1
}

@(private)
_conn_read :: proc(c: ^Conn) {
	r := c.relay
	if c.dead {
		return
	}
	if len(c.stash) > 0 && !c.paused {
		tmp := c.stash
		c.stash = make([dynamic]u8, r.allocator)
		_feed(c, tmp[:])
		delete(tmp)
	}
	if c.link.recv == nil {
		return
	}
	for !c.dead && !c.paused && !c.closing {
		n, err := c.link.recv(c.link.data, r.rscratch)
		if err == .Would_Block {
			break
		}
		if err != .None {
			_conn_close(c)
			return
		}
		if n <= 0 {
			break
		}
		r.stats.bytes_in += u64(n)
		_feed(c, r.rscratch[:n])
	}
}

@(private)
_should_pause :: proc "contextless" (c: ^Conn) -> bool {
	return c.inflight >= MAX_INFLIGHT || len(c.out) - c.out_head >= MAX_OUT || c.listing != nil || c.pipe_wait
}

@(private)
_set_paused :: proc(c: ^Conn, p: bool) {
	c.paused = p
	if c.link.pause != nil && c.blocked != p {
		c.blocked = p
		c.link.pause(c.link.data, p)
	}
}

@(private)
_feed :: proc(c: ^Conn, data: []u8) {
	c.feeding = true
	defer c.feeding = false
	pos := 0
	for !c.dead && !c.closing {
		if _should_pause(c) {
			if pos < len(data) {
				if _, e := append(&c.stash, ..data[pos:]); e != nil {
					_conn_close(c)
					return
				}
			}
			_set_paused(c, true)
			return
		}
		it, used, err := parser_next(&c.parser, data[pos:])
		pos += used
		if err != .None {
			_fail(c, .Too_Large if err == .Too_Large else .Protocol)
			return
		}
		if it.kind == .None {
			break
		}
		_handle(c, &it)
	}
	parser_release(&c.parser)
}

@(private)
_fail :: proc(c: ^Conn, code: Code) {
	if c.dead || c.closing {
		return
	}
	_op_abort(c)
	b: [FRAME_HEADER + 1]u8
	frame_header(b[:], .Error, 1)
	b[FRAME_HEADER] = u8(code)
	_push_small(c, b[:])
	c.closing = true
	c.paused = true
}

@(private)
_handle :: proc(c: ^Conn, it: ^Item) {
	if c.state != .Ready {
		if it.kind == .Control && it.frame == .Hello && c.state == .Hello {
			_on_hello(c, it.data)
		} else {
			_fail(c, .Protocol)
		}
		return
	}
	switch it.kind {
	case .None:
	case .Control:
		rd := prim.reader(it.data)
		#partial switch it.frame {
		case .List:
			_on_list(c, &rd)
		case .Read:
			_on_read(c, &rd, false)
		case .Tail:
			_on_read(c, &rd, true)
		case .Follow:
			_on_follow(c, &rd)
		case .Unfollow:
			_on_unfollow(c, &rd)
		case .Get:
			_on_get(c, &rd)
		case .Drop:
			_on_drop(c, &rd)
		case .Redact:
			_on_redact(c, &rd)
		case .Feed:
			_on_feed(c, &rd)
		case .Forget:
			_on_forget(c, &rd)
		case .Probe:
			_on_probe(c, &rd)
		case .Direct:
			_on_direct(c, &rd)
		case .Note:
			_on_note(c, &rd)
		case .Pull:
			_on_pull(c, &rd)
		case .Account:
			_on_account(c, &rd)
		case:
			_fail(c, .Protocol)
		}
	case .Bulk_Begin:
		rd := prim.reader(it.data)
		#partial switch it.frame {
		case .Append:
			_on_append_begin(c, &rd, i64(it.total))
		case .Put:
			_on_put_begin(c, &rd, i64(it.total))
		case .Fill:
			_on_fill_begin(c, &rd, i64(it.total))
		case .Serve:
			_on_serve_begin(c, &rd, i64(it.total))
		case:
			_fail(c, .Protocol)
		}
	case .Bulk_Data:
		_on_bulk_data(c, it.data)
	case .Bulk_End:
		_on_bulk_end(c)
	}
}

@(private)
_on_hello :: proc(c: ^Conn, payload: []u8) {
	r := c.relay
	if len(payload) < 1 || len(payload) > 1 + CREDENTIAL_MAX {
		_fail(c, .Protocol)
		return
	}
	if payload[0] != PROTOCOL_VERSION {
		_fail(c, .Version)
		return
	}
	p: Principal
	if code := r.auth.authorize(r.auth.data, payload[1:], c.binding[:c.bind_len], c.local, &p); code != .None {
		_fail(c, code)
		return
	}
	pk: [32]u8
	ns := p.namespace
	pid := p.participant
	copy(pk[:16], ns[:])
	copy(pk[16:], pid[:])
	limit := p.max_conns if p.max_conns > 0 else r.cfg.principal_conns
	if r.principals[pk] >= limit {
		_fail(c, .Limit)
		return
	}
	sp, err := _space_get(r, p.namespace)
	if err != .None {
		_fail(c, .Io)
		return
	}
	if sp.conns >= r.cfg.max_space_conns {
		_space_release(r, sp)
		_fail(c, .Limit)
		return
	}
	sp.quota = p.quota
	sp.conns += 1
	c.space = sp
	r.principals[pk] += 1
	c.pkey = pk
	c.pcounted = true
	c.principal = p
	_conn_ready(c)
	append(&sp.live, c)
	_presence_join(r, sp, c)
	b: [FRAME_HEADER + 33]u8
	frame_header(b[:], .Welcome, 33)
	b[FRAME_HEADER] = PROTOCOL_VERSION
	prim.put_u64le(b[FRAME_HEADER + 1:], u64(prim.clock_wall_ns(c.relay.cfg.clock)))
	prim.put_u64le(b[FRAME_HEADER + 9:], u64(max(sp.usage, 0)))
	prim.put_u64le(b[FRAME_HEADER + 17:], u64(sp.quota))
	prim.put_u64le(b[FRAME_HEADER + 25:], RELAY_FEATURES)
	_push_small(c, b[:])
}

@(private)
_on_account :: proc(c: ^Conn, rd: ^prim.Reader) {
	if !prim.reader_done(rd) {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .List, {}) {
		_reply_refused(c, .Not_Owner, cast([32]u8)reserved_id(ACCOUNT_TAG, 0))
		return
	}
	st, _ := relay_core_space_stats(c.relay, c.space.id)
	b: [FRAME_HEADER + ACCOUNTED_LEN]u8
	frame_header(b[:], .Accounted, ACCOUNTED_LEN)
	accounted_encode(st, b[FRAME_HEADER:])
	_push_small(c, b[:])
}

@(private)
_can :: proc(c: ^Conn, access: Access, id: [32]u8) -> bool {
	if _reserved(id) {
		return false
	}
	return principal_allows(&c.principal, access, id)
}

@(private)
_space_get :: proc(r: ^Relay_Core, id: Space_Id) -> (sp: ^Space_State, err: Error) {
	if existing, ok := r.spaces[id]; ok {
		return existing, .None
	}
	ns, usage := r.store.namespace_open(r.store.data, id) or_return
	aerr: runtime.Allocator_Error
	sp, aerr = new(Space_State, r.allocator)
	if aerr != nil {
		r.store.namespace_close(r.store.data, ns)
		return nil, .No_Memory
	}
	sp.id = id
	sp.ns = ns
	sp.usage = usage
	sp.streams = make(map[Stream_Id]^Stream_State, r.allocator)
	sp.watchers = make([dynamic]^Conn, r.allocator)
	sp.feeders = make([dynamic]^Conn, r.allocator)
	sp.feed_q = make([dynamic]u8, r.allocator)
	sp.feed_flight = make([dynamic]u8, r.allocator)
	sp.compact_buf = make([dynamic]u8, r.allocator)
	sp.relay = r
	sp.feed_wait = make([dynamic]^Pending, r.allocator)
	sp.redlog_q = make([dynamic]u8, r.allocator)
	sp.redlog_qp = make([dynamic]^Pending, r.allocator)
	sp.redlog_flight = make([dynamic]u8, r.allocator)
	sp.redlog_fp = make([dynamic]^Pending, r.allocator)
	sp.present = make(map[Device_Id]Presence_Entry, r.allocator)
	sp.pipes = make([dynamic]Pipe, r.allocator)
	sp.live = make([dynamic]^Conn, r.allocator)
	r.spaces[id] = sp
	return sp, .None
}

@(private)
_space_release :: proc(r: ^Relay_Core, sp: ^Space_State) {
	if sp.conns > 0 || len(sp.pipes) > 0 || sp.jobs > 0 || sp.feed_busy || sp.redlog_busy || sp.phase != .Idle || len(sp.feed_q) > 0 || len(sp.feed_wait) > 0 || len(sp.redlog_q) > 0 || len(sp.streams) > _owned_streams(sp) {
		return
	}
	for st in ([]^Stream_State{sp.feed, sp.meta, sp.redlog}) {
		if st == nil {
			continue
		}
		delete_key(&sp.streams, st.id)
		if st.h != nil {
			r.store.stream_close(r.store.data, st.h)
		}
		delete(st.followers)
		free(st, r.allocator)
		r.stats.streams -= 1
	}
	sp.feed = nil
	sp.meta = nil
	sp.redlog = nil
	delete_key(&r.spaces, sp.id)
	delete(sp.streams)
	delete(sp.watchers)
	delete(sp.feeders)
	delete(sp.feed_q)
	delete(sp.feed_flight)
	delete(sp.compact_buf)
	delete(sp.feed_wait)
	delete(sp.redlog_q)
	delete(sp.redlog_qp)
	delete(sp.redlog_flight)
	delete(sp.redlog_fp)
	delete(sp.present)
	delete(sp.pipes)
	delete(sp.live)
	r.store.namespace_close(r.store.data, sp.ns)
	free(sp, r.allocator)
}

@(private)
_stream_get :: proc(r: ^Relay_Core, sp: ^Space_State, id: Stream_Id, create: bool) -> (^Stream_State, Error) {
	st, ok := sp.streams[id]
	if ok {
		if st.poisoned && !st.busy {
			if st.h != nil {
				r.store.stream_close(r.store.data, st.h)
				st.h = nil
			}
			h, length, err := r.store.stream_open(r.store.data, sp.ns, id, false)
			if err != .None && err != .Not_Found {
				return nil, err
			}
			st.h = h if err == .None else nil
			st.length = length if err == .None else 0
			st.base = r.store.stream_base(r.store.data, h) if err == .None else 0
			st.poisoned = false
		}
		if create && st.h == nil {
			h, length, err := r.store.stream_open(r.store.data, sp.ns, id, true)
			if err != .None {
				return nil, err
			}
			st.h = h
			st.length = length
			st.base = r.store.stream_base(r.store.data, h)
		}
		return st, .None
	}
	h, length, err := r.store.stream_open(r.store.data, sp.ns, id, create)
	if err != .None && err != .Not_Found {
		return nil, err
	}
	nst, aerr := new(Stream_State, r.allocator)
	if aerr != nil {
		if err == .None {
			r.store.stream_close(r.store.data, h)
		}
		return nil, .No_Memory
	}
	nst.space = sp
	nst.id = id
	if err == .None {
		nst.h = h
		nst.length = length
		nst.base = r.store.stream_base(r.store.data, h)
	}
	nst.followers = make([dynamic]^Conn, r.allocator)
	sp.streams[id] = nst
	r.stats.streams += 1
	return nst, .None
}

@(private)
_stream_ref :: proc "contextless" (st: ^Stream_State) {
	st.refs += 1
}

@(private)
_stream_unref :: proc(r: ^Relay_Core, st: ^Stream_State) {
	st.refs -= 1
	_stream_maybe_release(r, st)
}

@(private)
_stream_maybe_release :: proc(r: ^Relay_Core, st: ^Stream_State) {
	if st.refs > 0 || st.busy {
		return
	}
	sp := st.space
	if cur, ok := sp.streams[st.id]; ok && cur == st {
		delete_key(&sp.streams, st.id)
	}
	if st.h != nil {
		r.store.stream_close(r.store.data, st.h)
	}
	delete(st.followers)
	free(st, r.allocator)
	r.stats.streams -= 1
	_space_release(r, sp)
}

@(private)
_live_len :: proc "contextless" (st: ^Stream_State) -> i64 {
	return st.length if st.h != nil && !st.dropped else 0
}

@(private)
_push :: proc(c: ^Conn, o: Out) -> bool {
	if c.dead {
		return false
	}
	if c.out_head > 0 && c.out_head == len(c.out) {
		clear(&c.out)
		c.out_head = 0
	}
	if _, e := append(&c.out, o); e != nil {
		_conn_close(c)
		return false
	}
	return true
}

@(private)
_push_small :: proc(c: ^Conn, frame: []u8) {
	o: Out
	o.kind = .Bytes
	if len(frame) <= len(o.small) {
		o.hlen = copy(o.small[:], frame)
	} else {
		b, e := make([]u8, len(frame), c.relay.allocator)
		if e != nil {
			_conn_close(c)
			return
		}
		copy(b, frame)
		o.buf = b
	}
	_push(c, o)
}

@(private)
_push_buf :: proc(c: ^Conn, buf: []u8) {
	o: Out
	o.kind = .Bytes
	o.buf = buf
	if !_push(c, o) {
		delete(buf, c.relay.allocator)
	}
}

@(private)
_reply_len :: proc(c: ^Conn, k: Kind, id: [32]u8, length: i64) {
	b: [FRAME_HEADER + 40]u8
	frame_header(b[:], k, 40)
	v := id
	copy(b[FRAME_HEADER:], v[:])
	prim.put_u64le(b[FRAME_HEADER + 32:], u64(length))
	_push_small(c, b[:])
}

@(private)
_reply_id :: proc(c: ^Conn, k: Kind, id: [32]u8) {
	b: [FRAME_HEADER + 32]u8
	frame_header(b[:], k, 32)
	v := id
	copy(b[FRAME_HEADER:], v[:])
	_push_small(c, b[:])
}

@(private)
_reply_refused :: proc(c: ^Conn, code: Code, id: [32]u8) {
	b: [FRAME_HEADER + 33]u8
	frame_header(b[:], .Refused, 33)
	b[FRAME_HEADER] = u8(code)
	v := id
	copy(b[FRAME_HEADER + 1:], v[:])
	_push_small(c, b[:])
}

@(private)
_out_release :: proc(r: ^Relay_Core, o: ^Out, c: ^Conn = nil) {
	if o.piped && c != nil {
		o.piped = false
		_pipe_drained(c, len(o.buf))
	}
	if o.buf != nil {
		delete(o.buf, r.allocator)
		o.buf = nil
	}
	if o.stream != nil {
		_stream_unref(r, o.stream)
		o.stream = nil
	}
	if o.obj != nil {
		r.store.object_close(r.store.data, o.obj)
		o.obj = nil
	}
}




@(private)
_on_read :: proc(c: ^Conn, rd: ^prim.Reader, tail: bool) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	a := prim.read_u64le(rd)
	b: u64
	if !tail {
		b = prim.read_u64le(rd)
	}
	if !prim.reader_done(rd) || a > u64(max(i64)) || b > u64(max(i64)) {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .Read, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	st, err := _stream_get(r, c.space, id, false)
	if err != .None {
		_reply_refused(c, .Io, cast([32]u8)id)
		return
	}
	length := _live_len(st)
	from, to: i64
	if tail {
		from = max(length - i64(a), 0)
		to = length
	} else {
		from = i64(a)
		to = clamp(i64(b), from, max(length, from))
		if from > length {
			to = from
		}
	}
	if st.base > 0 && st.h != nil && !st.dropped {
		_reply_hollow(c, .Hollow, cast([32]u8)id, st.base, length)
		if from < st.base {
			from = min(st.base, length)
			to = max(to, from)
		}
	}
	o: Out
	o.kind = .Data
	o.stream = st
	o.at = from
	o.to = to
	o.reply = true
	_stream_ref(st)
	if !_push(c, o) {
		_stream_unref(r, st)
	}
}

@(private)
_on_probe :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	count := int(prim.read_u16le(rd))
	if !prim.reader_ok(rd) || count > FOLLOW_BATCH || prim.reader_remaining(rd) != count * 32 {
		_fail(c, .Protocol)
		return
	}
	buf, aerr := make([]u8, FRAME_HEADER + 2 + count * 40, r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	sp := c.space
	n := 0
	for _ in 0 ..< count {
		id := Stream_Id(get_id32(rd))
		length: i64
		if id == reserved_id(FEED_TAG, 0) {
			if _can(c, .List, {}) && _feed_open(r, sp) == .None {
				length = _feed_end(sp)
			}
		} else if !_can(c, .Read, cast([32]u8)id) {
			length = 0
		} else if st, ok := sp.streams[id]; ok && st.h != nil && !st.poisoned {
			length = _live_len(st)
			if st.base > 0 && !st.dropped {
				_reply_hollow(c, .Hollow, cast([32]u8)id, st.base, length)
			}
		} else {
			l, base, exists, err := r.store.stream_probe(r.store.data, sp.ns, id)
			if err != .None {
				_reply_refused(c, .Io, cast([32]u8)id)
				continue
			}
			length = l if exists else 0
			if exists && base > 0 {
				_reply_hollow(c, .Hollow, cast([32]u8)id, base, length)
			}
		}
		e := buf[FRAME_HEADER + 2 + n * 40:]
		v := id
		copy(e[:32], v[:])
		prim.put_u64le(e[32:], u64(max(length, 0)))
		n += 1
	}
	frame_header(buf, .Probed, 2 + n * 40)
	buf[FRAME_HEADER] = u8(n)
	buf[FRAME_HEADER + 1] = u8(n >> 8)
	_push_buf(c, buf[:FRAME_HEADER + 2 + n * 40])
}

@(private)
_on_follow :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	flags := prim.read_u8(rd)
	count := int(prim.read_u16le(rd))
	if !prim.reader_ok(rd) || count > FOLLOW_BATCH || prim.reader_remaining(rd) != count * 40 {
		_fail(c, .Protocol)
		return
	}
	if flags & FOLLOW_WATCH != 0 && !c.watching {
		if _, e := append(&c.space.watchers, c); e != nil {
			_conn_close(c)
			return
		}
		c.watching = true
	}
	buf, aerr := make([]u8, FRAME_HEADER + 2 + count * 40, r.allocator)
	if aerr != nil {
		_conn_close(c)
		return
	}
	n := 0
	for _ in 0 ..< count {
		id := Stream_Id(get_id32(rd))
		off := prim.read_u64le(rd)
		if !_can(c, .Read, cast([32]u8)id) {
			_reply_refused(c, .Not_Owner, cast([32]u8)id)
			continue
		}
		st, err := _stream_get(r, c.space, id, false)
		if err != .None {
			_reply_refused(c, .Io, cast([32]u8)id)
			continue
		}
		length := _live_len(st)
		offset := length if off == FOLLOW_END else i64(min(off, u64(max(i64))))
		if st.base > 0 && st.h != nil && !st.dropped {
			_reply_hollow(c, .Hollow, cast([32]u8)id, st.base, length)
			offset = max(offset, st.base)
		}
		found := false
		for &s in c.subs {
			if s.stream == st {
				s.offset = offset
				found = true
				break
			}
		}
		if !found {
			if len(c.subs) >= r.cfg.max_follows {
				_reply_refused(c, .Limit, cast([32]u8)id)
				_stream_maybe_release(r, st)
				continue
			}
			if _, e := append(&c.subs, Sub{st, offset}); e != nil {
				_stream_maybe_release(r, st)
				delete(buf, r.allocator)
				_conn_close(c)
				return
			}
			if _, e := append(&st.followers, c); e != nil {
				pop(&c.subs)
				_stream_maybe_release(r, st)
				delete(buf, r.allocator)
				_conn_close(c)
				return
			}
			_stream_ref(st)
		}
		e := buf[FRAME_HEADER + 2 + n * 40:]
		v := id
		copy(e[:32], v[:])
		prim.put_u64le(e[32:], u64(length))
		n += 1
	}
	frame_header(buf, .Length, 2 + n * 40)
	buf[FRAME_HEADER] = u8(n)
	buf[FRAME_HEADER + 1] = u8(n >> 8)
	_push_buf(c, buf[:FRAME_HEADER + 2 + n * 40])
	c.scan = true
}

@(private)
_on_unfollow :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	count := int(prim.read_u16le(rd))
	if !prim.reader_ok(rd) || count > FOLLOW_BATCH || prim.reader_remaining(rd) != count * 32 {
		_fail(c, .Protocol)
		return
	}
	for _ in 0 ..< count {
		id := Stream_Id(get_id32(rd))
		for i := 0; i < len(c.subs); i += 1 {
			st := c.subs[i].stream
			if st.id == id {
				unordered_remove(&c.subs, i)
				_remove_conn(&st.followers, c)
				_stream_unref(r, st)
				break
			}
		}
	}
}

@(private)
_on_get :: proc(c: ^Conn, rd: ^prim.Reader) {
	count := int(prim.read_u16le(rd))
	if !prim.reader_ok(rd) || count > GET_BATCH || prim.reader_remaining(rd) != count * 32 {
		_fail(c, .Protocol)
		return
	}
	for _ in 0 ..< count {
		key := Object_Key(get_id32(rd))
		if !_can(c, .Get, cast([32]u8)key) {
			_reply_refused(c, .Not_Owner, cast([32]u8)key)
			continue
		}
		o: Out
		o.kind = .Object
		o.key = key
		if !_push(c, o) {
			return
		}
	}
}

@(private)
_pending_new :: proc(c: ^Conn, kind: Pending_Kind, st: ^Stream_State, total: i64, id: [32]u8) -> ^Pending {
	r := c.relay
	p, aerr := new(Pending, r.allocator)
	if aerr != nil {
		return nil
	}
	p^ = {
		relay  = r,
		kind   = kind,
		conn   = c.ref,
		stream = st,
		space  = c.space,
		total  = total,
		id     = id,
	}
	if st != nil {
		_stream_ref(st)
	}
	c.space.jobs += 1
	c.inflight += 1
	return p
}

@(private)
_on_drop :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	if !prim.reader_done(rd) {
		_fail(c, .Protocol)
		return
	}
	if !_can(c, .Drop, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	st, err := _stream_get(r, c.space, id, false)
	if err != .None {
		_reply_refused(c, .Io, cast([32]u8)id)
		return
	}
	if st.busy {
		_reply_refused(c, .Busy, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	p := _pending_new(c, .Drop, st, 0, cast([32]u8)id)
	if p == nil {
		_stream_maybe_release(r, st)
		_reply_refused(c, .Io, cast([32]u8)id)
		return
	}
	st.busy = true
	r.store.drop(r.store.data, c.space.ns, id, _relay_done, p)
}

@(private)
_reply_redacted :: proc(c: ^Conn, id: [32]u8, from, to: i64) {
	b: [FRAME_HEADER + 48]u8
	frame_header(b[:], .Redacted, 48)
	v := id
	copy(b[FRAME_HEADER:], v[:])
	prim.put_u64le(b[FRAME_HEADER + 32:], u64(from))
	prim.put_u64le(b[FRAME_HEADER + 40:], u64(to))
	_push_small(c, b[:])
}

@(private)
_on_redact :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	from := prim.read_u64le(rd)
	to := prim.read_u64le(rd)
	if !prim.reader_done(rd) || from > u64(REDACT_LIMIT) || to > u64(REDACT_LIMIT) || to < from {
		_fail(c, .Protocol)
		return
	}
	if _reserved(cast([32]u8)id) || !_can(c, .Redact, cast([32]u8)id) {
		_reply_refused(c, .Not_Owner, cast([32]u8)id)
		return
	}
	st, err := _stream_get(r, c.space, id, false)
	if err != .None {
		_reply_refused(c, .Io, cast([32]u8)id)
		return
	}
	if to <= from || st.h == nil {
		_reply_redacted(c, cast([32]u8)id, i64(from), i64(to))
		_stream_maybe_release(r, st)
		return
	}
	p := _pending_new(c, .Redact, st, i64(to), cast([32]u8)id)
	if p == nil {
		_reply_refused(c, .Io, cast([32]u8)id)
		_stream_maybe_release(r, st)
		return
	}
	p.from = i64(from)
	r.store.redact(r.store.data, st.h, i64(from), i64(to), _relay_done, p)
}

@(private)
_on_append_begin :: proc(c: ^Conn, rd: ^prim.Reader, total: i64) {
	r := c.relay
	id := Stream_Id(get_id32(rd))
	at_raw := prim.read_u64le(rd)
	c.op = Op {
		kind  = .Discard,
		id    = cast([32]u8)id,
		total = total,
	}
	if !prim.reader_ok(rd) || at_raw > u64(max(i64)) {
		_fail(c, .Protocol)
		return
	}
	at := i64(at_raw)
	sp := c.space
	if !_can(c, .Append, cast([32]u8)id) {
		c.op.reply, c.op.code = .Refused, .Not_Owner
		return
	}
	if sp.quota > 0 && sp.usage + sp.reserved + total > sp.quota {
		c.op.reply, c.op.code = .Refused, .Quota
		return
	}
	st, err := _stream_get(r, sp, id, at == 0)
	if err != .None {
		c.op.reply, c.op.code = .Refused, .Io
		return
	}
	length := _live_len(st)
	if st.busy || st.h == nil || st.dropped || at != st.length {
		c.op.reply, c.op.len = .Conflict, length
		if !st.busy && st.h != nil && !st.dropped && at < st.length {
			_feed_add(r, sp, cast([32]u8)id, u64(st.length))
		}
		_stream_maybe_release(r, st)
		return
	}
	if total == 0 {
		c.op.reply, c.op.len = .Appended, length
		_stream_maybe_release(r, st)
		return
	}
	w, werr := r.store.append_begin(r.store.data, st.h, at, total)
	if werr != .None {
		if werr == .Conflict {
			c.op.reply, c.op.len = .Conflict, length
		} else {
			c.op.reply, c.op.code = .Refused, .Io
		}
		_stream_maybe_release(r, st)
		return
	}
	sp.reserved += total
	st.busy = true
	_stream_ref(st)
	c.op.kind = .Append
	c.op.stream = st
	c.op.w = w
}

@(private)
_on_put_begin :: proc(c: ^Conn, rd: ^prim.Reader, total: i64) {
	r := c.relay
	key := Object_Key(get_id32(rd))
	c.op = Op {
		kind  = .Discard,
		id    = cast([32]u8)key,
		key   = key,
		total = total,
	}
	sp := c.space
	if !_can(c, .Put, cast([32]u8)key) {
		c.op.reply, c.op.code = .Refused, .Not_Owner
		return
	}
	if sp.quota > 0 && sp.usage + sp.reserved + total > sp.quota {
		c.op.reply, c.op.code = .Refused, .Quota
		return
	}
	w, exists, err := r.store.put_begin(r.store.data, sp.ns, key, total)
	if exists {
		c.op.reply = .Stored
		return
	}
	if err != .None {
		c.op.reply, c.op.code = .Refused, .Io
		return
	}
	sp.reserved += total
	c.op.kind = .Put
	c.op.w = w
}

@(private)
_on_bulk_data :: proc(c: ^Conn, data: []u8) {
	r := c.relay
	op := &c.op
	switch op.kind {
	case .None, .Discard:
	case .Append:
		if op.failed == .None {
			op.failed = r.store.append_write(r.store.data, op.w, data)
		}
	case .Put:
		if op.failed == .None {
			op.failed = r.store.put_write(r.store.data, op.w, data)
		}
	case .Fill:
		if op.failed == .None {
			op.failed = r.store.append_write(r.store.data, op.w, data)
		}
	case .Serve:
		if op.buf != nil {
			op.pos += copy(op.buf[op.pos:], data)
		}
	}
}

@(private)
_on_bulk_end :: proc(c: ^Conn) {
	r := c.relay
	op := c.op
	c.op = {}
	switch op.kind {
	case .None:
	case .Discard:
		switch op.reply {
		case .Refused:
			_reply_refused(c, op.code, op.id)
		case .Conflict, .Appended:
			_reply_len(c, op.reply, op.id, op.len)
		case .Stored:
			_reply_id(c, .Stored, op.id)
		case .Noted:
			_reply_hollow(c, .Noted, op.id, op.base, op.len)
		case .None, .Hello, .List, .Append, .Read, .Tail, .Follow, .Unfollow, .Put, .Get, .Drop, .Redact, .Feed, .Forget, .Probe, .Welcome, .Listing, .Data, .Object, .Missing, .Length, .Created, .Dropped, .Error, .Redacted, .Announce, .Forgotten, .Probed, .Presence, .Direct, .Directed, .Undelivered, .Note, .Fill, .Pull, .Serve, .Hollow, .Pulled, .Served, .Unserved, .Account, .Accounted:
		}
	case .Append:
		st := op.stream
		p := _pending_new(c, .Append, st, op.total, op.id)
		_stream_unref(r, st)
		if p == nil {
			r.store.append_abort(r.store.data, op.w)
			c.space.reserved -= op.total
			st.busy = false
			st.poisoned = true
			_reply_refused(c, .Io, op.id)
			_stream_maybe_release(r, st)
			return
		}
		r.stats.appends += 1
		r.store.append_commit(r.store.data, op.w, _relay_done, p)
	case .Put:
		p := _pending_new(c, .Put, nil, op.total, op.id)
		if p == nil {
			r.store.put_abort(r.store.data, op.w)
			c.space.reserved -= op.total
			_reply_refused(c, .Io, op.id)
			return
		}
		r.store.put_commit(r.store.data, op.w, _relay_done, p)
	case .Fill:
		_fill_end(c, &op)
	case .Serve:
		_serve_end(c, &op)
	}
}

@(private)
_op_abort :: proc(c: ^Conn) {
	r := c.relay
	op := &c.op
	switch op.kind {
	case .None, .Discard:
	case .Append:
		r.store.append_abort(r.store.data, op.w)
		c.space.reserved -= op.total
		op.stream.busy = false
		op.stream.poisoned = true
		_stream_unref(r, op.stream)
	case .Put:
		r.store.put_abort(r.store.data, op.w)
		c.space.reserved -= op.total
	case .Fill:
		r.store.append_abort(r.store.data, op.w)
		c.space.reserved -= op.total
		op.stream.busy = false
		op.stream.poisoned = true
		_stream_unref(r, op.stream)
	case .Serve:
		if op.buf != nil {
			delete(op.buf, r.allocator)
		}
	}
	c.op = {}
	parser_reset(&c.parser)
}

@(private)
_relay_done :: proc(ctx: rawptr, result: Error, value: i64) {
	p := cast(^Pending)ctx
	r := p.relay
	c := _conn_lookup(r, p.conn)
	sp := p.space
	switch p.kind {
	case .Append:
		st := p.stream
		st.busy = false
		sp.reserved -= p.total
		if result == .None {
			was := st.length
			st.length = value
			sp.usage += p.total
			sp.count.appends += 1
			sp.count.bytes_in += u64(p.total)
			p.length = value
			if was == 0 {
				for w in sp.watchers {
					if _can(w, .Read, p.id) {
						_reply_len(w, .Created, p.id, st.length)
						_conn_kick(w)
					}
				}
			}
			for f in st.followers {
				f.scan = true
				_conn_kick(f)
			}
			_relay_observe(r, sp, st, was, value)
			_feed_wait(r, sp, p, u64(st.length))
			_reap(r)
			return
		} else {
			st.poisoned = true
			if c != nil {
				_reply_refused(c, .Quota if result == .No_Space else .Io, p.id)
			}
		}
	case .Put:
		sp.reserved -= p.total
		if result == .None {
			sp.usage += value
			if c != nil {
				_reply_id(c, .Stored, p.id)
			}
		} else if c != nil {
			_reply_refused(c, .Quota if result == .No_Space else .Io, p.id)
		}
	case .Redact:
		if result == .None {
			_redlog_add(r, sp, p)
			_reap(r)
			return
		}
		if c != nil {
			_reply_refused(c, .Io, p.id)
		}
	case .Redlog:
		_redlog_done(r, sp, result, value)
	case .Drop:
		st := p.stream
		st.busy = false
		if result == .None {
			sp.usage = max(sp.usage - value, 0)
			st.dropped = true
			if cur, ok := sp.streams[st.id]; ok && cur == st {
				delete_key(&sp.streams, st.id)
			}
			for f in st.followers {
				for i := 0; i < len(f.subs); i += 1 {
					if f.subs[i].stream == st {
						unordered_remove(&f.subs, i)
						st.refs -= 1
						break
					}
				}
				if f != c {
					_reply_id(f, .Dropped, p.id)
					_conn_kick(f)
				}
			}
			for w in sp.watchers {
				if w != c && _can(w, .Read, p.id) && !slice.contains(st.followers[:], w) {
					_reply_id(w, .Dropped, p.id)
					_conn_kick(w)
				}
			}
			clear(&st.followers)
			if !_reserved(p.id) {
				p.length = -1
				_feed_wait(r, sp, p, FEED_DROPPED)
				_reap(r)
				return
			}
		} else if c != nil {
			_reply_refused(c, .Io, p.id)
		}
	case .Forget:
		if result == .None {
			sp.usage = max(sp.usage - value, 0)
			if c != nil {
				_reply_id(c, .Forgotten, p.id)
			}
		} else if c != nil {
			_reply_refused(c, .Io, p.id)
		}
	case .Feed, .Compact, .Meta:
		_feed_done(r, sp, p.kind, result, value)
	case .Note, .Fill:
		if _hollow_done(r, sp, c, p, result, value) {
			_reap(r)
			return
		}
	}
	if p.stream != nil {
		_stream_unref(r, p.stream)
	}
	sp.jobs -= 1
	free(p, r.allocator)
	if c != nil {
		c.inflight -= 1
		_conn_kick(c)
	}
	_space_release(r, sp)
	_reap(r)
}

@(private)
_conn_kick :: proc(c: ^Conn) {
	if c.dead {
		return
	}
	if c.feeding || c.pumping {
		c.again = true
		return
	}
	_conn_pump(c)
}

@(private)
_conn_pump :: proc(c: ^Conn) {
	if c.pumping {
		c.again = true
		return
	}
	c.pumping = true
	defer c.pumping = false
	for !c.dead {
		c.again = false
		_conn_write(c)
		if c.dead {
			return
		}
		if c.paused && !c.closing && !_should_pause(c) {
			_set_paused(c, false)
			_conn_read(c)
			continue
		}
		if !c.again {
			return
		}
	}
}

@(private)
_c_send :: proc(c: ^Conn, data: []u8, more: bool) -> (int, Error) {
	return c.link.send(c.link.data, data, more)
}

@(private)
_c_zero_copy :: proc "contextless" (c: ^Conn) -> bool {
	return c.link.sendfile != nil
}

@(private)
_c_sendfile :: proc(c: ^Conn, fd: prim.Fd, off: i64, n: int) -> (int, Error) {
	return c.link.sendfile(c.link.data, fd, off, n)
}

@(private)
_stream_extent :: proc(r: ^Relay_Core, h: rawptr, at: i64, n: i64) -> (prim.Fd, i64, i64, bool) {
	if r.store.stream_extent == nil {
		return prim.INVALID_FD, 0, 0, false
	}
	return r.store.stream_extent(r.store.data, h, at, n)
}

@(private)
_object_extent :: proc(r: ^Relay_Core, o: rawptr, at: i64, n: i64) -> (prim.Fd, i64, i64, bool) {
	if r.store.object_extent == nil {
		return prim.INVALID_FD, 0, 0, false
	}
	return r.store.object_extent(r.store.data, o, at, n)
}

@(private)
_c_copy :: proc(c: ^Conn, read: proc(data: rawptr, h: rawptr, at: i64, dst: []u8) -> (int, Error), h: rawptr, at: i64, n: int) -> (int, Error) {
	r := c.relay
	k := min(n, len(r.wscratch))
	got, rerr := read(r.store.data, h, at, r.wscratch[:k])
	if rerr != .None {
		return 0, rerr
	}
	if got < k {
		return 0, .Corrupt
	}
	return _c_send(c, r.wscratch[:k], k < n)
}

@(private)
_conn_write :: proc(c: ^Conn) {
	r := c.relay
	if c.dead {
		return
	}
	for !c.dead {
		if c.out_head == len(c.out) {
			if c.out_head > 0 {
				clear(&c.out)
				c.out_head = 0
			}
			if c.closing {
				_conn_close(c)
				return
			}
			if !_produce(c) {
				break
			}
			continue
		}
		o := &c.out[c.out_head]
		done, err := _out_step(c, o)
		if err == .Would_Block {
			return
		}
		if err != .None {
			_conn_close(c)
			return
		}
		if done {
			_out_release(r, o, c)
			c.out_head += 1
		}
	}
}

@(private)
_produce :: proc(c: ^Conn) -> bool {
	if c.state != .Ready {
		return false
	}
	if c.scan {
		n := len(c.subs)
		for k in 0 ..< n {
			i := (c.rr + k) % n
			s := &c.subs[i]
			st := s.stream
			if st.dropped || st.h == nil {
				continue
			}
			if s.offset < st.base {
				s.offset = st.base
			}
			if st.length <= s.offset {
				continue
			}
			o: Out
			o.kind = .Data
			o.stream = st
			o.at = s.offset
			o.to = min(st.length, s.offset + DATA_MAX)
			s.offset = o.to
			_stream_ref(st)
			c.rr = (i + 1) % n
			if !_push(c, o) {
				_stream_unref(c.relay, st)
				return false
			}
			return true
		}
		c.scan = false
	}
	if c.feed_on && c.feed_hint {
		if _produce_feed(c) {
			return true
		}
		c.feed_hint = false
	}
	if c.listing != nil {
		return _produce_listing(c)
	}
	return false
}

@(private)
_out_step :: proc(c: ^Conn, o: ^Out) -> (done: bool, err: Error) {
	r := c.relay
	switch o.kind {
	case .Bytes:
		data := o.buf if o.buf != nil else o.small[:o.hlen]
		for o.hpos < len(data) {
			n := _c_send(c, data[o.hpos:], c.out_head + 1 < len(c.out)) or_return
			o.hpos += n
			r.stats.bytes_out += u64(n)
		}
		return true, .None
	case .Data:
		st := o.stream
		for {
			if o.hpos == o.hlen && o.left == 0 {
				if o.started && o.at >= o.to {
					return true, .None
				}
				n := min(o.to - o.at, DATA_MAX)
				frame_header(o.small[:], .Data, DATA_FIXED + int(n))
				v := st.id
				copy(o.small[FRAME_HEADER:], v[:])
				prim.put_u64le(o.small[FRAME_HEADER + 32:], u64(o.at))
				length := u64(_live_len(st))
				if n > 0 {
					length = max(length, u64(o.at + n))
				}
				if o.reply && o.at + n >= o.to {
					length |= DATA_FINAL
				}
				prim.put_u64le(o.small[FRAME_HEADER + 40:], length)
				o.hlen = FRAME_HEADER + DATA_FIXED
				o.hpos = 0
				o.left = n
				o.started = true
			}
			for o.hpos < o.hlen {
				n := _c_send(c, o.small[o.hpos:o.hlen], o.left > 0) or_return
				o.hpos += n
			}
			for o.left > 0 {
				k := int(min(o.left, SENDFILE_CHUNK))
				w: int
				if fd, off, ext, ok := _stream_extent(r, st.h, o.at, i64(k)); ok && ext > 0 && _c_zero_copy(c) {
					w = _c_sendfile(c, fd, off, int(min(ext, i64(k)))) or_return
				} else {
					w = _c_copy(c, r.store.stream_read, st.h, o.at, k) or_return
				}
				o.at += i64(w)
				o.left -= i64(w)
				r.stats.bytes_out += u64(w)
			}
		}
	case .Object:
		if !o.started {
			o.started = true
			v := o.key
			ob, size, oerr := r.store.object_open(r.store.data, c.space.ns, o.key)
			if oerr != .None || size > i64(OBJECT_MAX) {
				if oerr == .None {
					r.store.object_close(r.store.data, ob)
				}
				frame_header(o.small[:], .Missing, 32)
				copy(o.small[FRAME_HEADER:], v[:])
				o.hlen = FRAME_HEADER + 32
			} else {
				o.obj = ob
				o.left = size
				frame_header(o.small[:], .Object, OBJECT_FIXED + int(size))
				copy(o.small[FRAME_HEADER:], v[:])
				o.hlen = FRAME_HEADER + OBJECT_FIXED
			}
		}
		for o.hpos < o.hlen {
			n := _c_send(c, o.small[o.hpos:o.hlen], o.left > 0) or_return
			o.hpos += n
		}
		for o.left > 0 {
			k := int(min(o.left, SENDFILE_CHUNK))
			w: int
			if fd, off, ext, ok := _object_extent(r, o.obj, o.at, i64(k)); ok && ext > 0 && _c_zero_copy(c) {
				w = _c_sendfile(c, fd, off, int(min(ext, i64(k)))) or_return
			} else {
				w = _c_copy(c, r.store.object_read, o.obj, o.at, k) or_return
			}
			o.at += i64(w)
			o.left -= i64(w)
			r.stats.bytes_out += u64(w)
		}
		return true, .None
	}
	return true, .None
}








@(private)
_on_forget :: proc(c: ^Conn, rd: ^prim.Reader) {
	r := c.relay
	count := int(prim.read_u16le(rd))
	if !prim.reader_ok(rd) || count > GET_BATCH || prim.reader_remaining(rd) != count * 32 {
		_fail(c, .Protocol)
		return
	}
	for _ in 0 ..< count {
		key := Object_Key(get_id32(rd))
		if !_can(c, .Forget, cast([32]u8)key) {
			_reply_refused(c, .Not_Owner, cast([32]u8)key)
			continue
		}
		p := _pending_new(c, .Forget, nil, 0, cast([32]u8)key)
		if p == nil {
			_reply_refused(c, .Io, cast([32]u8)key)
			continue
		}
		r.store.object_remove(r.store.data, c.space.ns, key, _relay_done, p)
	}
}
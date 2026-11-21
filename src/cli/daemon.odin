package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../capi/api"
import eng "../engine"
import "../mcp"
import "../prim"
import rt "../runtime"
import osync "../sync"

STATE_VERSION :: u8(1)

Cap_Entry :: struct {
	space: prim.Id,
	token: []u8,
	cc:    eng.Cap_Credentials,
}

Mount_Entry :: struct {
	object: api.Object,
	root:   string,
}

State :: struct {
	default_space: prim.Id,
	current:       api.Object,
	mounts:        [dynamic]Mount_Entry,
}

Mcp_Session :: struct {
	sess: ^rt.Stdio_Session,
	fd:   Sock,
	out:  Sock,
}

Daemon :: struct {
	s:          api.Stack,
	home:       string,
	engine_dir: string,
	sock:       string,
	state_path: string,
	lfd:        Sock,
	lwatch:     prim.Watch,
	sig:        Signals,
	swatch:     prim.Watch,
	conns:      [dynamic]^Conn,
	relay:      osync.Relay,
	relay_on:   bool,
	state:      State,
	caps:       [dynamic]^Cap_Entry,
	mcp:        [dynamic]Mcp_Session,
	links:      map[prim.Id]eng.Error,
	started:    i64,
	stopping:   bool,
	runner:     bool,
	acct:       ^Acct,
	hc:         Host_Chan,
	serial:     u64,
}

Pending :: struct {
	conn: ^Conn,
	tag:  u64,
	id:   u64,
	json: bool,
}

Sub_Tag :: struct {
	conn:    ^Conn,
	tag:     u64,
	id:      u64,
	json:    bool,
	catalog: bool,
	gap:     bool,
	compact: bool,
	buffer:  bool,
	object:  api.Object,
	changed: [dynamic]api.Object,
}

Ev_Key :: struct {
	kind:   u64,
	space:  prim.Id,
	object: prim.Id,
	device: prim.Id,
}

Conn :: struct {
	d:       ^Daemon,
	fd:      Sock,
	watch:   prim.Watch,
	writing: bool,
	rbuf:    [dynamic]u8,
	wbuf:    [dynamic]u8,
	sniffed: bool,
	calls:   [dynamic]^Pending,
	subs:    [dynamic]^Sub_Tag,
	events:  bool,
	ev_json: bool,
	ev_mask: u64,
	dead:    bool,
	serial:  u64,
	plugs:   Host_Plugs,
	host_json: bool,
	pushed:  bool,
	lagging: bool,
	ev_keys: [dynamic]Ev_Key,
	ev_last: map[Ev_Key][]u8,
}

HOST_REGISTER_CODE :: 1009
CONN_WBUF_MAX :: 2 * FRAME_MAX
LAG_HIGH :: 1 << 20
LAG_LOW :: 64 << 10
GAP_OBJECTS_MAX :: 4096

HOST_OPS := []api.Op {
	{1000, "daemon.status", {}, "DaemonStatus", op_daemon_status},
	{1001, "daemon.stop", {}, "", op_daemon_stop},
	{1002, "state.get", {}, "default_space:id current:object", op_state_get},
	{1003, "state.set", {{"default_space", .Id, nil}, {"current", .Object, nil}}, "", op_state_set},
	{1004, "mount.add", {{"object", .Object, nil}, {"root", .Str, nil}}, "", op_mount_add},
	{1005, "mount.remove", {{"root", .Str, nil}}, "", op_mount_remove},
	{1006, "credentials.add", {{"space", .Id, nil}, {"token", .Bytes, nil}}, "", op_credentials_add},
	{1007, "verify", {{"root", .Str, nil}}, "files:uvarint mismatches:[str]", op_verify},
	{1008, "pool.token", {}, "token:str", op_pool_token},
	{HOST_REGISTER_CODE, "host.register", {{"plugs", .Strs, nil}, {"replace", .Bool, nil}, {"identity", .Bytes, nil}, {"spaces", .Ids, nil}}, "plugs:[str]", op_host_register},
}

daemon_main :: proc(args: ^Args) -> int {
	d := new(Daemon)
	d.runner = !flag_bool(args, "no-runner")
	d.home = home_dir()
	d.engine_dir, _ = prim.path_join(context.allocator, d.home, "engine")
	d.state_path, _ = prim.path_join(context.allocator, d.home, "daemon.state")
	d.sock = socket_path()
	d.lfd = NO_SOCK
	d.sig.fd = -1
	d.conns = make([dynamic]^Conn)
	d.links = make(map[prim.Id]eng.Error)
	d.caps = make([dynamic]^Cap_Entry)
	d.mcp = make([dynamic]Mcp_Session)
	d.state.mounts = make([dynamic]Mount_Entry)
	if prim.mkdir_all(prim.os_vfs(), d.home, 0o700) != .None {
		return report_error(.Io, "cannot create %s", d.home)
	}
	ignore_broken_pipes()
	_state_load(d)
	ec := eng.default_config(d.engine_dir)
	ec.credentials = eng.Credentials_Source{data = d, produce = _cred_produce}
	ec.idle_pageout = true
	ec.search_full = !flag_bool(args, "no-full-index")
	ec.events = eng.Event_Hook{data = d, event = _on_event}
	if !acct_setup(d, &ec, args) {
		return report_error(.Io, "cannot open the account store")
	}
	if !host_plugs_setup(d, &ec, args) {
		return usage_error("--host-plugs takes a comma-separated list of sealed_store, unlock, credentials and either runner_pool or pool_user")
	}
	opts := api.Stack_Options {
		runtime = true,
		observe = true,
		attach  = true,
		host    = api.Host{data = d, ops = HOST_OPS},
	}
	opts.placement = api.Placement_Hook{data = d, call = _on_placement}
	opts.rt_cfg.runner = d.runner
	opts.rt_cfg.pool = flag_bool(args, "pool")
	if v, ok := flag_value(args, "storage"); ok {
		switch v {
		case "auto":
			ec.storage = .Auto
		case "stored":
			ec.storage = .Stored
		case "until-run":
			ec.storage = .Device_Until_Run
		case "device":
			ec.storage = .Device
		case:
			return usage_error("--storage takes auto, stored, until-run or device")
		}
	}
	if v, ok := flag_value(args, "content-budget"); ok {
		n, nok := strconv.parse_i64(v)
		if !nok || n == 0 {
			return usage_error("--content-budget takes a byte count (negative: nothing is relay-stored)")
		}
		ec.content_budget = n
	}
	ec.always_on = flag_bool(args, "always-on")
	if v, ok := flag_value(args, "holder-budget"); ok {
		n, nok := strconv.parse_i64(v)
		if !nok || n == 0 {
			return usage_error("--holder-budget takes a byte count (negative: no limit)")
		}
		ec.holder_budget = n
	}
	if v, ok := flag_value(args, "capacity"); ok {
		n, nok := strconv.parse_int(v)
		if !nok || n <= 0 {
			return usage_error("--capacity takes a positive number")
		}
		opts.rt_cfg.capacity = n
	}
	if exe, eerr := os.get_executable_path(context.allocator); eerr == nil {
		cmd := make([]string, 2)
		cmd[0] = exe
		cmd[1] = "mcp"
		opts.rt_cfg.catalog_command = cmd
	}
	opts.rt_cfg.homes = rt.Homes{data = d, home = _home_of}
	opts.rt_cfg.default_provider = flag_string(args, "provider")
	opts.rt_cfg.default_model = flag_string(args, "model")
	if st := api.stack_open(&d.s, ec, opts); st != .Ok {
		if st == .Busy {
			return report_error(.Busy, "another daemon is running for %s", d.home)
		}
		return report_error(st, "cannot open the engine in %s", d.engine_dir)
	}
	d.started = prim.now_ms()
	for m in d.state.mounts {
		if _, st := api.mount_open(&d.s.a, m.object, m.root); st != .Ok {
			fmt.eprintfln("0ndb: cannot remount %s: %s", m.root, api.STATUS_NAMES[int(st)])
		}
	}
	acct_started(d, args)
	if !_listen(d) {
		api.stack_close(&d.s)
		return report_error(.Io, "cannot listen on %s", d.sock)
	}
	if signals_open(&d.sig) {
		d.swatch, _ = prim.watch(&d.s.loop, d.sig.fd, {.Read}, d, _on_signal)
	}
	ready_notify()
	fmt.eprintfln("0ndb daemon %s listening on %s (device %s, runner %v)", VERSION, d.sock, hex(eng.self(&d.s.e)), d.runner)
	for !d.stopping {
		if prim.loop_step(&d.s.loop, true) != .None {
			break
		}
		api.stack_attach_joined(&d.s)
		_flush_pushed(d)
		if len(d.mcp) > 0 {
			_mcp_sweep(d)
		}
	}
	_shutdown(d)
	return 0
}

@(private)
_listen :: proc(d: ^Daemon) -> bool {
	dir := prim.dir_name(d.sock)
	if prim.mkdir_all(prim.os_vfs(), dir, 0o700) != .None {
		return false
	}
	if fd, ok := sock_connect(d.sock); ok {
		sock_close(fd)
		return false
	}
	fd, lok := sock_listen(d.sock)
	if !lok {
		return false
	}
	d.lfd = fd
	w, err := prim.watch(&d.s.loop, watch_fd(fd), {.Read}, d, _on_accept)
	if err != .None {
		sock_close(fd)
		d.lfd = NO_SOCK
		return false
	}
	d.lwatch = w
	return true
}

@(private)
_on_signal :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	d := (^Daemon)(data)
	for {
		sig, ok := signals_read(&d.sig)
		if !ok {
			break
		}
		fmt.eprintfln("0ndb daemon: signal %d, shutting down", sig)
		d.stopping = true
	}
}

@(private)
_on_accept :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	d := (^Daemon)(data)
	_mcp_sweep(d)
	for {
		cfd, aok := sock_accept(d.lfd)
		if !aok {
			break
		}
		if !peer_is_self(watch_fd(cfd)) {
			sock_close(cfd)
			continue
		}
		_conn_new(d, cfd)
	}
}

@(private)
_conn_new :: proc(d: ^Daemon, cfd: Sock) -> ^Conn {
	c := new(Conn)
	c.d = d
	c.fd = cfd
	d.serial += 1
	c.serial = d.serial
	c.rbuf = make([dynamic]u8)
	c.wbuf = make([dynamic]u8)
	c.calls = make([dynamic]^Pending)
	c.subs = make([dynamic]^Sub_Tag)
	w, err := prim.watch(&d.s.loop, watch_fd(cfd), {.Read}, c, _on_conn)
	if err != .None {
		sock_close(cfd)
		_conn_free(c)
		return nil
	}
	c.watch = w
	append(&d.conns, c)
	return c
}

@(private)
_conn_version_mismatch :: proc(c: ^Conn) {
	t := u64_bytes(0)
	s := [1]u8{u8(api.Status.Unsupported)}
	buf := make([dynamic]u8, context.temp_allocator)
	o: api.Out
	api.out_init(&o, &buf, true)
	api.o_str(&o, "error", api.STATUS_NAMES[int(api.Status.Unsupported)])
	api.o_u64(&o, "proto", u64(PROTO_VERSION))
	c.sniffed = true
	_conn_write(c, .Result, t[:], s[:], api.out_finish(&o))
	c.dead = true
}

@(private)
_conn_call :: proc(c: ^Conn, payload: []u8) {
	d := c.d
	tag := prim.get_u64le(payload[:8])
	json_form := payload[8] & 1 != 0
	timeout := i64(prim.get_u64le(payload[9:17]))
	pc := new(Pending)
	pc.conn = c
	pc.tag = tag
	pc.json = json_form
	id, st, out := api.call(&d.s.a, payload[17:], json_form, _on_call_done, pc, timeout, context.temp_allocator)
	if st == .Pending {
		pc.id = id
		append(&c.calls, pc)
		return
	}
	free(pc)
	if out == nil && st != .Ok {
		out = _status_payload(st, json_form)
	}
	_send_result(c, tag, st, out)
}

@(private)
_status_payload :: proc(st: api.Status, json_form: bool) -> []u8 {
	buf := make([dynamic]u8, context.temp_allocator)
	o: api.Out
	api.out_init(&o, &buf, json_form)
	if json_form {
		api.o_str(&o, "error", api.STATUS_NAMES[int(st)])
	} else {
		api.o_u64(&o, "status", u64(st))
	}
	return api.out_finish(&o)
}

@(private)
_call_cancel :: proc(c: ^Conn, tag: u64) {
	for pc, i in c.calls {
		if pc.tag == tag {
			ordered_remove(&c.calls, i)
			api.cancel(&c.d.s.a, pc.id)
			json_form := pc.json
			free(pc)
			_send_result(c, tag, .Cancelled, _status_payload(.Cancelled, json_form))
			return
		}
	}
}

@(private)
_on_conn :: proc(l: ^prim.Loop, fd: prim.Fd, ev: prim.Events, data: rawptr) {
	c := (^Conn)(data)
	if .Write in ev {
		_conn_flush(c)
	}
	if .Read in ev || .Hangup in ev || .Error in ev {
		if !_conn_read(c) {
			return
		}
	}
	if c.dead {
		_conn_drop(c, true)
	}
}

@(private)
_conn_read :: proc(c: ^Conn) -> (alive: bool) {
	buf: [65536]u8
	for !c.dead {
		n, st := sock_read(c.fd, buf[:])
		if st == .Again {
			break
		}
		if st != .Ok {
			c.dead = true
			break
		}
		append(&c.rbuf, ..buf[:n])
		if !_conn_process(c) {
			return false
		}
	}
	return true
}

@(private)
_conn_process :: proc(c: ^Conn) -> bool {
	d := c.d
	if !c.sniffed {
		if len(c.rbuf) < 4 {
			return true
		}
		if string(c.rbuf[:4]) != MAGIC {
			_relay_handoff(c)
			return false
		}
		if len(c.rbuf) < 5 {
			return true
		}
		if c.rbuf[4] != PROTO_VERSION {
			_conn_version_mismatch(c)
			return true
		}
		remove_range(&c.rbuf, 0, 5)
		c.sniffed = true
	}
	for !c.dead {
		k, p, used, have, bad := frame_next(c.rbuf[:])
		if bad {
			c.dead = true
			return true
		}
		if !have {
			break
		}
		payload := make([]u8, len(p), context.temp_allocator)
		copy(payload, p)
		remove_range(&c.rbuf, 0, used)
		#partial switch k {
		case .Call:
			if len(payload) < 17 {
				c.dead = true
				return true
			}
			_conn_call(c, payload)
		case .Subscribe:
			if len(payload) < 9 {
				c.dead = true
				return true
			}
			tag := prim.get_u64le(payload[:8])
			st_ := new(Sub_Tag)
			st_.conn = c
			st_.tag = tag
			st_.json = payload[8] & 1 != 0
			st_.compact = payload[8] & 2 != 0
			id: u64
			st: api.Status
			open: []u8
			if api.request_is(&d.s.a, payload[9:], st_.json, "buffer.open") {
				st_.buffer = true
				id, st, open = api.subscribe_open(&d.s.a, payload[9:], st_.json, _on_buffer_sub, st_, _sub_ready)
			} else {
				catalog: bool
				object: api.Object
				id, catalog, object, st = api.subscribe_raw(&d.s.a, payload[9:], st_.json, _on_sub, st_)
				st_.catalog = catalog
				st_.object = object
			}
			if st != .Ok {
				free(st_)
				_send_result(c, tag, st, _status_payload(st, payload[8] & 1 != 0))
			} else {
				st_.id = id
				append(&c.subs, st_)
				_send_result(c, tag, .Ok, open)
			}
		case .Unsubscribe:
			if len(payload) < 8 {
				c.dead = true
				return true
			}
			tag := prim.get_u64le(payload[:8])
			st := api.Status.Not_Found
			for s, i in c.subs {
				if s.tag == tag {
					api.unsubscribe(&d.s.a, s.id)
					ordered_remove(&c.subs, i)
					_sub_free(s)
					st = .Ok
					break
				}
			}
			_send_result(c, tag, st, nil)
		case .Events:
			flags := payload[0] if len(payload) > 0 else 1
			c.events = flags & 2 == 0
			c.ev_json = flags & 1 != 0
			c.ev_mask = prim.get_u64le(payload[1:9]) if len(payload) >= 9 else max(u64)
		case .Cancel:
			if len(payload) < 8 {
				c.dead = true
				return true
			}
			_call_cancel(c, prim.get_u64le(payload[:8]))
		case .Plug_Reply:
			host_plug_reply(d, c, payload)
		case .Mcp:
			return !_mcp_handoff(c, payload)
		case:
			c.dead = true
			return true
		}
	}
	return true
}

@(private)
_send_result :: proc(c: ^Conn, tag: u64, st: api.Status, payload: []u8) {
	t := u64_bytes(tag)
	s := [1]u8{u8(st)}
	_conn_write(c, .Result, t[:], s[:], payload)
}

@(private)
_conn_write :: proc(c: ^Conn, kind: Frame_Kind, parts: ..[]u8) {
	if c.dead {
		return
	}
	frame_put(&c.wbuf, kind, ..parts)
	_conn_flush(c)
	if len(c.wbuf) > CONN_WBUF_MAX {
		fmt.eprintfln("0ndb daemon: dropping a client that stopped reading (%d bytes queued)", len(c.wbuf))
		c.dead = true
		_host_schedule_sweep(c.d)
	}
}

@(private)
_conn_flush :: proc(c: ^Conn) {
	for len(c.wbuf) > 0 && !c.dead {
		n, st := sock_write(c.fd, c.wbuf[:])
		if st == .Again {
			break
		}
		if st != .Ok {
			c.dead = true
			return
		}
		remove_range(&c.wbuf, 0, int(n))
		if c.lagging && len(c.wbuf) <= LAG_LOW {
			_conn_resume(c)
		}
	}
	want := len(c.wbuf) > 0
	if want != c.writing && !c.dead {
		c.writing = want
		evs := prim.Events{.Read}
		if want {
			evs += {.Write}
		}
		prim.watch_modify(&c.d.s.loop, c.watch, evs)
	}
}

@(private)
_on_call_done :: proc(data: rawptr, id: u64, st: api.Status, payload: []u8) {
	pc := (^Pending)(data)
	c := pc.conn
	for x, i in c.calls {
		if x == pc {
			ordered_remove(&c.calls, i)
			break
		}
	}
	_send_result(c, pc.tag, st, payload)
	free(pc)
	if c.dead {
		_conn_drop(c, true)
	}
}

@(private)
_on_sub :: proc(data: rawptr, id: u64, deltas: []eng.Delta) {
	s := (^Sub_Tag)(data)
	c := s.conn
	if c.dead {
		return
	}
	if c.lagging || len(c.wbuf) > LAG_HIGH {
		c.lagging = true
		if !s.catalog || s.gap {
			s.gap = true
			return
		}
		for &dl in deltas {
			seen := false
			for x in s.changed {
				seen ||= x == dl.object
			}
			if !seen {
				append(&s.changed, dl.object)
			}
		}
		if len(s.changed) > GAP_OBJECTS_MAX {
			s.gap = true
			clear(&s.changed)
		}
		return
	}
	t := u64_bytes(s.tag)
	_conn_push(c, .Deltas, t[:], api.encode_deltas_compact(deltas, s.object) if s.json && s.compact else api.encode_deltas(deltas, s.json))
}

@(private)
_conn_push :: proc(c: ^Conn, kind: Frame_Kind, parts: ..[]u8) {
	if c.dead {
		return
	}
	frame_put(&c.wbuf, kind, ..parts)
	c.pushed = true
}

@(private)
_flush_pushed :: proc(d: ^Daemon) {
	for c in d.conns {
		if c.pushed && !c.dead {
			c.pushed = false
			_conn_flush(c)
			if c.dead {
				_host_schedule_sweep(d)
			}
		}
	}
}

@(private)
_sub_ready :: proc(data: rawptr) -> bool {
	s := (^Sub_Tag)(data)
	c := s.conn
	if c.dead {
		return false
	}
	if c.lagging || len(c.wbuf) > LAG_HIGH {
		c.lagging = true
		return false
	}
	return true
}

@(private)
_on_buffer_sub :: proc(data: rawptr, id: u64, payload: []u8) {
	s := (^Sub_Tag)(data)
	t := u64_bytes(s.tag)
	_conn_push(s.conn, .Deltas, t[:], payload)
}

@(private)
_conn_resume :: proc(c: ^Conn) {
	c.lagging = false
	for s in c.subs {
		if s.buffer {
			api.sub_kick(&c.d.s.a, s.id)
		}
	}
	for s in c.subs {
		if !s.gap && len(s.changed) == 0 {
			continue
		}
		buf := make([dynamic]u8, context.temp_allocator)
		o: api.Out
		api.out_init(&o, &buf, s.json)
		api.o_bool(&o, "full", s.gap)
		api.o_arr(&o, "objects", len(s.changed))
		for ob in s.changed {
			api.o_object(&o, "", ob)
		}
		api.o_end(&o)
		t := u64_bytes(s.tag)
		frame_put(&c.wbuf, .Gap, t[:], api.out_finish(&o))
		s.gap = false
		clear(&s.changed)
	}
	for k in c.ev_keys {
		if p, ok := c.ev_last[k]; ok {
			frame_put(&c.wbuf, .Event, p)
			delete(p)
		}
	}
	clear(&c.ev_keys)
	clear(&c.ev_last)
}

@(private)
_sub_free :: proc(s: ^Sub_Tag) {
	delete(s.changed)
	free(s)
}

@(private)
_on_event :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Event) {
	d := (^Daemon)(data)
	#partial switch ev.kind {
	case .Space_Joined, .Members_Changed:
		api.stack_space_joined(&d.s, ev.space)
	case .Connected:
		delete_key(&d.links, ev.space)
		fmt.eprintfln("0ndb daemon: space %s connected", hex(ev.space))
	case .Disconnected:
		prev, had := d.links[ev.space]
		d.links[ev.space] = ev.err
		if !had || prev != ev.err {
			fmt.eprintfln("0ndb daemon: space %s disconnected: %s", hex(ev.space), link_reason(ev.err))
		}
	case .Quarantined, .Refused, .Fatal, .Failure:
		fmt.eprintfln("0ndb daemon: %s space %s object %s (%s)", api.EVENT_NAMES[int(ev.kind)], hex(ev.space), hex(ev.object), api.STATUS_NAMES[int(api.status_of(ev.err))])
	case .Unavailable:
		fmt.eprintfln("0ndb daemon: %s available when %s is online", hex(ev.object), hex(ev.device))
	case .Available:
		fmt.eprintfln("0ndb daemon: %s available", hex(ev.object))
	case .Access_Revoked:
		fmt.eprintfln("0ndb daemon: access to space %s was revoked: this device was removed", hex(ev.space))
	case .Epoch_Changed:
		api.stack_space_joined(&d.s, ev.space)
		fmt.eprintfln("0ndb daemon: space %s key epoch %d", hex(ev.space), ev.length)
	case .Runner_Enrolled:
		fmt.eprintfln("0ndb daemon: runner %s enrolled in space %s through the pool", hex(ev.device), hex(ev.space))
	case .Runner_Anomaly:
		fmt.eprintfln("0ndb daemon: %d runner enrollments in the last minute in space %s", ev.length, hex(ev.space))
	case .Approval_Requested:
		fmt.eprintfln("0ndb daemon: device %s asks to sign in (0ndb approve %s)", hex(ev.device), ev.detail)
	case .Login_Done:
		fmt.eprintfln("0ndb daemon: signed in")
	case .Login_Failed:
		fmt.eprintfln("0ndb daemon: sign-in did not complete: %s", ev.detail)
	case .Promoted:
		fmt.eprintfln("0ndb daemon: %s promoted segment of %s (%d bytes uploaded)", hex(ev.object), hex(ev.device), ev.length)
	case .Peer_Misbehaving:
		fmt.eprintfln("0ndb daemon: device %s served bytes of %s that failed verification", hex(ev.device), hex(ev.object))
	}
	_broadcast_event(d, ev, {}, {})
}

@(private)
_broadcast_event :: proc(d: ^Daemon, ev: ^eng.Event, o: api.Object, info: rt.Placement_Info) {
	jp, bp: []u8
	key := Ev_Key{kind = api.EVENT_PLACEMENT, space = o.space, object = o.id}
	if ev != nil {
		key = Ev_Key{api.event_code(ev.kind), ev.space, ev.object, ev.device}
	}
	for c in d.conns {
		if !c.events || c.dead || key.kind >= 64 || c.ev_mask & (u64(1) << key.kind) == 0 {
			continue
		}
		if c.ev_json && jp == nil {
			jp = api.encode_event(ev, true) if ev != nil else api.encode_placement_event(o, info, true)
		}
		if !c.ev_json && bp == nil {
			bp = api.encode_event(ev, false) if ev != nil else api.encode_placement_event(o, info, false)
		}
		p := jp if c.ev_json else bp
		if c.lagging || len(c.wbuf) > LAG_HIGH {
			c.lagging = true
			if old, had := c.ev_last[key]; had {
				delete(old)
			} else {
				append(&c.ev_keys, key)
			}
			c.ev_last[key] = clone_bytes(p)
			continue
		}
		_conn_push(c, .Event, p)
	}
}

@(private)
_on_placement :: proc(data: rawptr, o: api.Object, info: rt.Placement_Info) {
	d := (^Daemon)(data)
	if info.state == .Waiting_Runner {
		fmt.eprintfln("0ndb daemon: %s waits for a runner (provider %s)", hex(o.id), info.provider)
	}
	_broadcast_event(d, nil, o, info)
}

@(private)
_conn_drop :: proc(c: ^Conn, close_fd: bool) {
	d := c.d
	for x, i in d.conns {
		if x == c {
			ordered_remove(&d.conns, i)
			break
		}
	}
	if c.watch != 0 {
		prim.unwatch(&d.s.loop, c.watch)
		c.watch = 0
	}
	if close_fd && c.fd != NO_SOCK {
		sock_close(c.fd)
	}
	c.fd = NO_SOCK
	c.dead = true
	host_release(d, c)
	for pc in c.calls {
		api.cancel(&d.s.a, pc.id)
		free(pc)
	}
	clear(&c.calls)
	for s in c.subs {
		api.unsubscribe(&d.s.a, s.id)
		_sub_free(s)
	}
	clear(&c.subs)
	_conn_free(c)
}

@(private)
_conn_free :: proc(c: ^Conn) {
	for _, p in c.ev_last {
		delete(p)
	}
	delete(c.ev_last)
	delete(c.ev_keys)
	delete(c.rbuf)
	delete(c.wbuf)
	delete(c.calls)
	delete(c.subs)
	free(c)
}

@(private)
_relay_handoff :: proc(c: ^Conn) {
	d := c.d
	if !d.relay_on {
		dir, _ := prim.path_join(context.temp_allocator, d.home, "local-relay")
		cfg := osync.relay_config(dir)
		cfg.pack = true
		cfg.open = true
		cfg.kernel_tls = false
		cfg.sync_threads = 0
		if err := osync.relay_init(&d.relay, &d.s.loop, cfg); err != .None {
			fmt.eprintfln("0ndb daemon: cannot start the local relay: %v", err)
			c.dead = true
			_conn_drop(c, true)
			return
		}
		d.relay_on = true
	}
	initial := make([]u8, len(c.rbuf), context.temp_allocator)
	copy(initial, c.rbuf[:])
	fd := c.fd
	_conn_drop(c, false)
	if err := osync.relay_adopt(&d.relay, watch_fd(fd), true, initial); err != .None {
		sock_close(fd)
	}
}

@(private)
_mcp_handoff :: proc(c: ^Conn, payload: []u8) -> (gone: bool) {
	d := c.d
	if len(payload) != 32 || !d.s.r_on || len(c.rbuf) > 0 {
		c.dead = true
		return false
	}
	r := prim.reader(payload)
	sp := prim.read_id(&r)
	caller := api.Object{sp, prim.read_id(&r)}
	ack_tag := u64_bytes(0)
	ok := [1]u8{0}
	_conn_write(c, .Result, ack_tag[:], ok[:])
	if len(c.wbuf) > 0 || c.dead {
		c.dead = true
		return false
	}
	fd := c.fd
	_conn_drop(c, false)
	out, dok := sock_dup(fd)
	if !dok {
		sock_close(fd)
		return true
	}
	sess, err := rt.serve_stdio(&d.s.r, caller, watch_fd(fd), watch_fd(out))
	if err != .None {
		_mcp_close_fds(fd, out)
		return true
	}
	append(&d.mcp, Mcp_Session{sess, fd, out})
	return true
}

@(private)
_mcp_close_fds :: proc(fd, out: Sock) {
	sock_close(fd)
	if out != fd {
		sock_close(out)
	}
}

@(private)
_mcp_sweep :: proc(d: ^Daemon) {
	i := 0
	for i < len(d.mcp) {
		m := d.mcp[i]
		if !m.sess.closed {
			i += 1
			continue
		}
		list := &d.s.r.serve.stdio
		for x, j in list {
			if x == m.sess {
				ordered_remove(list, j)
				break
			}
		}
		mcp.stdio_server_destroy(&m.sess.ss)
		free(m.sess, d.s.r.allocator)
		_mcp_close_fds(m.fd, m.out)
		unordered_remove(&d.mcp, i)
	}
}

@(private)
_shutdown :: proc(d: ^Daemon) {
	for len(d.conns) > 0 {
		_conn_drop(d.conns[len(d.conns) - 1], true)
	}
	if d.lwatch != 0 {
		prim.unwatch(&d.s.loop, d.lwatch)
	}
	if d.lfd != NO_SOCK {
		sock_close(d.lfd)
		sock_unlink(d.sock)
	}
	if d.swatch != 0 {
		prim.unwatch(&d.s.loop, d.swatch)
	}
	signals_close(&d.sig)
	_state_save(d)
	host_plugs_destroy(d)
	for m in d.mcp {
		_mcp_close_fds(m.fd, m.out)
	}
	if d.relay_on {
		osync.relay_destroy(&d.relay)
		d.relay_on = false
	}
	api.stack_close(&d.s)
	fmt.eprintln("0ndb daemon: stopped")
}

@(private)
_home_of :: proc(data: rawptr, tree: prim.Id, allocator: runtime.Allocator) -> (string, bool) {
	d := (^Daemon)(data)
	for m in d.s.a.mounts {
		if m.object.id == tree {
			return strings.clone(m.root, allocator), true
		}
	}
	return "", false
}

@(private)
_cred_produce :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	d := (^Daemon)(data)
	for ce in d.caps {
		if ce.space == space {
			c, err := eng.capability_credentials(&ce.cc, eng.keyring(&d.s.e), ce.token)
			return c, err == .None
		}
	}
	return {}, false
}

@(private)
_caps_dir :: proc(d: ^Daemon) -> string {
	p, _ := prim.path_join(context.temp_allocator, d.home, "credentials")
	return p
}

@(private)
_state_load :: proc(d: ^Daemon) {
	data, err := prim.read_file(prim.os_vfs(), d.state_path, context.temp_allocator)
	if err == .None {
		r := prim.reader(data)
		if prim.read_u8(&r) == STATE_VERSION {
			d.state.default_space = prim.read_id(&r)
			sp := prim.read_id(&r)
			d.state.current = api.Object{sp, prim.read_id(&r)}
			n := prim.read_len(&r)
			for _ in 0 ..< n {
				osp := prim.read_id(&r)
				oid := prim.read_id(&r)
				root := prim.read_str(&r)
				if !prim.reader_ok(&r) {
					break
				}
				append(&d.state.mounts, Mount_Entry{api.Object{osp, oid}, clone(root)})
			}
		}
	}
	dir := _caps_dir(d)
	h, derr := os.open(dir)
	if derr != nil {
		return
	}
	defer os.close(h)
	infos, _ := os.read_dir(h, -1, context.temp_allocator)
	for fi in infos {
		id, ok := prim.id_parse(fi.name)
		if !ok {
			continue
		}
		tok, rerr := prim.read_file(prim.os_vfs(), fi.fullpath, context.allocator)
		if rerr != .None || len(tok) != eng.CAPABILITY_LEN {
			delete(tok)
			continue
		}
		ce := new(Cap_Entry)
		ce.space = id
		ce.token = tok
		append(&d.caps, ce)
	}
}

@(private)
_state_save :: proc(d: ^Daemon) {
	buf := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&buf)
	prim.write_u8(&w, STATE_VERSION)
	prim.write_id(&w, d.state.default_space)
	prim.write_id(&w, d.state.current.space)
	prim.write_id(&w, d.state.current.id)
	prim.write_uvarint(&w, u64(len(d.state.mounts)))
	for m in d.state.mounts {
		prim.write_id(&w, m.object.space)
		prim.write_id(&w, m.object.id)
		prim.write_str(&w, m.root)
	}
	prim.replace_atomic(prim.os_vfs(), d.state_path, buf[:])
}

@(private)
_host :: proc(c: ^api.Call) -> ^Daemon {
	return (^Daemon)(c.api.host.data)
}

op_daemon_status :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	api.o_str(o, "version", VERSION)
	api.o_u64(o, "proto", u64(PROTO_VERSION))
	api.o_u64(o, "api", api.VERSION)
	api.o_u64(o, "pid", self_pid())
	api.o_str(o, "home", d.home)
	api.o_str(o, "socket", d.sock)
	api.o_i64(o, "uptime_ms", prim.now_ms() - d.started)
	api.o_i64(o, "rss", rss_bytes())
	api.o_bool(o, "runner", d.runner)
	api.o_int(o, "connections", len(d.conns))
	api.o_bool(o, "local_relay", d.relay_on)
	api.o_int(o, "mcp_sessions", len(d.mcp))
	api.o_u64(o, "wakeups", eng.stats(&d.s.e).wakeups)
	api.o_i64(o, "timeout_ms", prim.loop_timeout_ms(&d.s.loop))
	enabled := host_plug_names(d.hc.enabled)
	api.o_arr(o, "host_plugs", len(enabled))
	for n in enabled {
		api.o_str(o, "", n)
	}
	api.o_end(o)
	api.o_int(o, "host_pending", host_pending(d))
	registered := host_plug_names(host_registered(d))
	api.o_arr(o, "hosts", len(registered))
	for n in registered {
		api.o_str(o, "", n)
	}
	api.o_end(o)
	api.o_arr(o, "links", len(d.links))
	for sp, err in d.links {
		api.o_obj(o, "")
		api.o_id(o, "space", sp)
		api.o_str(o, "error", api.STATUS_NAMES[int(api.status_of(err))])
		api.o_str(o, "reason", link_reason(err))
		api.o_end(o)
	}
	api.o_end(o)
	return .Ok
}

op_daemon_stop :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	d.stopping = true
	return .Ok
}

op_state_get :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	api.o_id(o, "default_space", d.state.default_space)
	api.o_object(o, "current", d.state.current)
	return .Ok
}

op_state_set :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	if api.has(c, "default_space") {
		d.state.default_space = api.a_id(c, "default_space")
	}
	if api.has(c, "current") {
		d.state.current = api.a_object(c, "current")
	}
	_state_save(d)
	return .Ok
}

op_mount_add :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	ob := api.a_object(c, "object")
	m, st := api.mount_open(c.api, ob, api.a_str(c, "root"))
	if st != .Ok {
		return st
	}
	for x in d.state.mounts {
		if x.root == m.root {
			return .Ok
		}
	}
	append(&d.state.mounts, Mount_Entry{ob, clone(m.root)})
	_state_save(d)
	return .Ok
}

op_mount_remove :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	root := trim_slash(api.a_str(c, "root"))
	found := false
	for m in c.api.mounts {
		if m.root == root {
			api.mount_close(c.api, m)
			found = true
			break
		}
	}
	for x, i in d.state.mounts {
		if x.root == root {
			delete(x.root)
			ordered_remove(&d.state.mounts, i)
			found = true
			break
		}
	}
	_state_save(d)
	return .Ok if found else .Not_Found
}

op_credentials_add :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	space := api.a_id(c, "space")
	token := api.a_bytes(c, "token")
	if len(token) != eng.CAPABILITY_LEN {
		return .Invalid
	}
	dir := _caps_dir(d)
	if prim.mkdir_all(prim.os_vfs(), dir, 0o700) != .None {
		return .Io
	}
	path, _ := prim.path_join(context.temp_allocator, dir, hex(space))
	if prim.replace_atomic(prim.os_vfs(), path, token) != .None {
		return .Io
	}
	for ce in d.caps {
		if ce.space == space {
			delete(ce.token)
			ce.token = clone_bytes(token)
			return .Ok
		}
	}
	ce := new(Cap_Entry)
	ce.space = space
	ce.token = clone_bytes(token)
	append(&d.caps, ce)
	return .Ok
}

link_reason :: proc(err: eng.Error) -> string {
	#partial switch err {
	case .None, .Closed:
		return "connection closed"
	case .Offline:
		return "relay unreachable"
	case .Permission:
		return "the relay rejected these credentials"
	case .Unsupported:
		return "the relay speaks a different protocol version"
	case .Corrupt:
		return "the relay sent malformed or tampered data"
	}
	return "the relay refused the connection (credentials, quota or protocol version)"
}

package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
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
	fd:   prim.Fd,
	out:  prim.Fd,
}

Daemon :: struct {
	s:          api.Stack,
	home:       string,
	engine_dir: string,
	sock:       string,
	state_path: string,
	lfd:        posix.FD,
	lwatch:     prim.Watch,
	sig:        Signals,
	swatch:     prim.Watch,
	conns:      [dynamic]^Conn,
	relay:      osync.Relay,
	relay_on:   bool,
	state:      State,
	caps:       [dynamic]^Cap_Entry,
	mcp:        [dynamic]Mcp_Session,
	started:    i64,
	stopping:   bool,
	runner:     bool,
}

Pending :: struct {
	conn: ^Conn,
	tag:  u64,
	id:   u64,
}

Sub_Tag :: struct {
	conn: ^Conn,
	tag:  u64,
	id:   u64,
}

Conn :: struct {
	d:       ^Daemon,
	fd:      posix.FD,
	watch:   prim.Watch,
	writing: bool,
	rbuf:    [dynamic]u8,
	wbuf:    [dynamic]u8,
	sniffed: bool,
	calls:   [dynamic]^Pending,
	subs:    [dynamic]^Sub_Tag,
	events:  bool,
	dead:    bool,
}

HOST_OPS := []api.Op {
	{1000, "daemon.status", {}, "DaemonStatus", op_daemon_status},
	{1001, "daemon.stop", {}, "", op_daemon_stop},
	{1002, "state.get", {}, "default_space:id current:object", op_state_get},
	{1003, "state.set", {{"default_space", .Id, nil}, {"current", .Object, nil}}, "", op_state_set},
	{1004, "mount.add", {{"object", .Object, nil}, {"root", .Str, nil}}, "", op_mount_add},
	{1005, "mount.remove", {{"root", .Str, nil}}, "", op_mount_remove},
	{1006, "credentials.add", {{"space", .Id, nil}, {"token", .Bytes, nil}}, "", op_credentials_add},
	{1007, "verify", {{"root", .Str, nil}}, "files:uvarint mismatches:[str]", op_verify},
}

daemon_main :: proc(args: ^Args) -> int {
	d := new(Daemon)
	d.runner = !flag_bool(args, "no-runner")
	d.home = home_dir()
	d.engine_dir, _ = prim.path_join(context.allocator, d.home, "engine")
	d.state_path, _ = prim.path_join(context.allocator, d.home, "daemon.state")
	d.sock = socket_path()
	d.lfd = -1
	d.sig.fd = -1
	d.conns = make([dynamic]^Conn)
	d.caps = make([dynamic]^Cap_Entry)
	d.mcp = make([dynamic]Mcp_Session)
	d.state.mounts = make([dynamic]Mount_Entry)
	if prim.mkdir_all(prim.os_vfs(), d.home, 0o700) != .None {
		return report_error(.Io, "cannot create %s", d.home)
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	_state_load(d)
	ec := eng.default_config(d.engine_dir)
	ec.credentials = eng.Credentials_Source{data = d, produce = _cred_produce}
	ec.events = eng.Event_Hook{data = d, event = _on_event}
	opts := api.Stack_Options {
		runtime = true,
		observe = true,
		attach  = true,
		host    = api.Host{data = d, ops = HOST_OPS},
	}
	opts.rt_cfg.runner = d.runner
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
	if code, ok := flag_value(args, "join"); ok {
		_, err := eng.space_join_pairing(&d.s.e, code)
		if err != .None && err != .Exists {
			api.stack_close(&d.s)
			return report_error(api.status_of(err), "cannot join with that pairing code")
		}
		for sp in eng.space_list(&d.s.e, context.temp_allocator) {
			rt.attach(&d.s.r, sp.id)
		}
	}
	if !_listen(d) {
		api.stack_close(&d.s)
		return report_error(.Io, "cannot listen on %s", d.sock)
	}
	if signals_open(&d.sig) {
		d.swatch, _ = prim.watch(&d.s.loop, d.sig.fd, {.Read}, d, _on_signal)
	}
	_ready_notify()
	fmt.eprintfln("0ndb daemon %s listening on %s (device %s, runner %v)", VERSION, d.sock, hex(eng.self(&d.s.e)), d.runner)
	for !d.stopping {
		if prim.loop_step(&d.s.loop, true) != .None {
			break
		}
	}
	_shutdown(d)
	return 0
}

@(private)
_ready_notify :: proc() {
	v, ok := os.lookup_env("ONDB_READY_FD", context.temp_allocator)
	if !ok {
		return
	}
	n, nok := strconv.parse_int(v)
	if !nok {
		return
	}
	b := [1]u8{'1'}
	posix.write(posix.FD(n), raw_data(b[:]), 1)
	posix.close(posix.FD(n))
	posix.unsetenv("ONDB_READY_FD")
}

@(private)
_listen :: proc(d: ^Daemon) -> bool {
	dir := prim.dir_name(d.sock)
	if prim.mkdir_all(prim.os_vfs(), dir, 0o700) != .None {
		return false
	}
	if fd, ok := _connect_once(d.sock); ok {
		posix.close(fd)
		return false
	}
	cpath := cstr(d.sock)
	posix.unlink(cpath)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {
		return false
	}
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	if len(d.sock) >= len(addr.sun_path) {
		posix.close(fd)
		return false
	}
	copy(addr.sun_path[:], d.sock)
	old := posix.umask({.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	bok := posix.bind(fd, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK
	posix.umask(old)
	if !bok || posix.listen(fd, 128) != .OK {
		posix.close(fd)
		return false
	}
	_nonblock(fd)
	d.lfd = fd
	w, err := prim.watch(&d.s.loop, prim.Fd(fd), {.Read}, d, _on_accept)
	if err != .None {
		posix.close(fd)
		d.lfd = -1
		return false
	}
	d.lwatch = w
	return true
}

@(private)
_nonblock :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
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
		cfd := posix.accept(d.lfd, nil, nil)
		if cfd < 0 {
			break
		}
		_nonblock(cfd)
		if !peer_is_self(prim.Fd(cfd)) {
			posix.close(cfd)
			continue
		}
		c := new(Conn)
		c.d = d
		c.fd = cfd
		c.rbuf = make([dynamic]u8)
		c.wbuf = make([dynamic]u8)
		c.calls = make([dynamic]^Pending)
		c.subs = make([dynamic]^Sub_Tag)
		w, err := prim.watch(l, prim.Fd(cfd), {.Read}, c, _on_conn)
		if err != .None {
			posix.close(cfd)
			_conn_free(c)
			continue
		}
		c.watch = w
		append(&d.conns, c)
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
		n := posix.read(c.fd, raw_data(buf[:]), len(buf))
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			if e != .EAGAIN && e != .EWOULDBLOCK {
				c.dead = true
			}
			break
		}
		if n == 0 {
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
			c.dead = true
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
			tag := prim.get_u64le(payload[:8])
			json_form := payload[8] & 1 != 0
			timeout := i64(prim.get_u64le(payload[9:17]))
			pc := new(Pending)
			pc.conn = c
			pc.tag = tag
			id, st, out := api.call(&d.s.a, payload[17:], json_form, _on_call_done, pc, timeout, context.temp_allocator)
			if st == .Pending {
				pc.id = id
				append(&c.calls, pc)
			} else {
				free(pc)
				_send_result(c, tag, st, out)
			}
		case .Subscribe:
			if len(payload) < 9 {
				c.dead = true
				return true
			}
			tag := prim.get_u64le(payload[:8])
			st_ := new(Sub_Tag)
			st_.conn = c
			st_.tag = tag
			id, st := api.subscribe(&d.s.a, payload[9:], payload[8] & 1 != 0, _on_sub, st_)
			if st != .Ok {
				free(st_)
				_send_result(c, tag, st, nil)
			} else {
				st_.id = id
				append(&c.subs, st_)
				_send_result(c, tag, .Ok, nil)
			}
		case .Unsubscribe:
			if len(payload) >= 8 {
				tag := prim.get_u64le(payload[:8])
				for s, i in c.subs {
					if s.tag == tag {
						api.unsubscribe(&d.s.a, s.id)
						ordered_remove(&c.subs, i)
						free(s)
						break
					}
				}
			}
		case .Events:
			c.events = true
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
}

@(private)
_conn_flush :: proc(c: ^Conn) {
	for len(c.wbuf) > 0 && !c.dead {
		n := posix.write(c.fd, raw_data(c.wbuf[:]), uint(len(c.wbuf)))
		if n < 0 {
			e := posix.errno()
			if e == .EINTR {
				continue
			}
			if e == .EAGAIN || e == .EWOULDBLOCK {
				break
			}
			c.dead = true
			return
		}
		remove_range(&c.wbuf, 0, int(n))
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
_on_sub :: proc(data: rawptr, id: u64, payload: []u8) {
	s := (^Sub_Tag)(data)
	t := u64_bytes(s.tag)
	_conn_write(s.conn, .Deltas, t[:], payload)
}

@(private)
_on_event :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Event) {
	d := (^Daemon)(data)
	#partial switch ev.kind {
	case .Connected:
		fmt.eprintfln("0ndb daemon: space %s connected", hex(ev.space))
	case .Disconnected:
		fmt.eprintfln("0ndb daemon: space %s disconnected", hex(ev.space))
	case .Quarantined, .Refused, .Fatal, .Failure:
		fmt.eprintfln("0ndb daemon: %s space %s object %s (%s)", api.EVENT_NAMES[int(ev.kind)], hex(ev.space), hex(ev.object), api.STATUS_NAMES[int(api.status_of(ev.err))])
	}
	if len(d.conns) == 0 {
		return
	}
	payload := api.encode_event(ev, true)
	for c in d.conns {
		if c.events {
			_conn_write(c, .Event, payload)
		}
	}
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
	if close_fd && c.fd >= 0 {
		posix.close(c.fd)
	}
	c.fd = -1
	c.dead = true
	for pc in c.calls {
		api.cancel(&d.s.a, pc.id)
		free(pc)
	}
	clear(&c.calls)
	for s in c.subs {
		api.unsubscribe(&d.s.a, s.id)
		free(s)
	}
	clear(&c.subs)
	_conn_free(c)
}

@(private)
_conn_free :: proc(c: ^Conn) {
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
	if err := osync.relay_adopt(&d.relay, prim.Fd(fd), true, initial); err != .None {
		posix.close(fd)
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
	out := posix.dup(fd)
	if out < 0 {
		posix.close(fd)
		return true
	}
	posix.fcntl(out, .SETFD, posix.FD_CLOEXEC)
	sess, err := rt.serve_stdio(&d.s.r, caller, prim.Fd(fd), prim.Fd(out))
	if err != .None {
		posix.close(fd)
		posix.close(out)
		return true
	}
	append(&d.mcp, Mcp_Session{sess, prim.Fd(fd), prim.Fd(out)})
	return true
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
		posix.close(posix.FD(m.fd))
		posix.close(posix.FD(m.out))
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
	if d.lfd >= 0 {
		posix.close(d.lfd)
		posix.unlink(cstr(d.sock))
	}
	if d.swatch != 0 {
		prim.unwatch(&d.s.loop, d.swatch)
	}
	signals_close(&d.sig)
	_state_save(d)
	for m in d.mcp {
		posix.close(posix.FD(m.fd))
		posix.close(posix.FD(m.out))
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
	api.o_u64(o, "pid", u64(posix.getpid()))
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

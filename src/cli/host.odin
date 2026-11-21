package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../capi/api"
import eng "../engine"
import "../prim"
import osync "../sync"

Host_Plug :: enum u8 {
	Sealed_Store,
	Unlock,
	Runner_Pool,
	Pool_User,
	Credentials,
}

Host_Plugs :: bit_set[Host_Plug;u8]

HOST_PLUG_NAMES := [Host_Plug]string {
	.Sealed_Store = "sealed_store",
	.Unlock       = "unlock",
	.Runner_Pool  = "runner_pool",
	.Pool_User    = "pool_user",
	.Credentials  = "credentials",
}

UNLOCK_MODE_NAMES := []string{"local", "cross_device"}
ECOSYSTEM_NAMES := []string{"unknown", "apple", "google", "microsoft", "1password", "bitwarden", "security_key", "recovery", "test"}

PLUG_VERSION :: u8(1)
PLUG_NOTES_MAX :: 256
PLUG_RBUF_MAX :: FRAME_MAX + 4096
HOST_CONN_WBUF_MAX :: 2 * FRAME_MAX

Plug_Fn :: struct {
	code:      u16,
	name:      string,
	plug:      Host_Plug,
	timeout:   i64,
	wait_host: bool,
	request:   []api.Arg,
	reply:     []api.Arg,
}

PLUG_STORE_GET :: 1
PLUG_STORE_PUT :: 2
PLUG_STORE_ADD :: 3
PLUG_UNLOCK :: 4
PLUG_REGISTER :: 5
PLUG_POOL_IDENTITY :: 6
PLUG_POOL_VERIFY :: 7
PLUG_POOL_ATTEST :: 8
PLUG_USER_IDENTITY :: 9
PLUG_USER_JOINED :: 10
PLUG_CRED_AVAILABLE :: 11
PLUG_CRED_PRODUCE :: 12

PLUG_FNS := []Plug_Fn {
	{PLUG_STORE_GET, "sealed_store.get", .Sealed_Store, 15_000, true, {{"subject", .Bytes, nil}}, {{"record", .Bytes, nil}, {"entries", .Strs, nil}}},
	{PLUG_STORE_PUT, "sealed_store.put", .Sealed_Store, 15_000, true, {{"subject", .Bytes, nil}, {"record", .Bytes, nil}, {"prev_seq", .U64, nil}, {"seq", .U64, nil}}, {}},
	{PLUG_STORE_ADD, "sealed_store.add", .Sealed_Store, 15_000, true, {{"subject", .Bytes, nil}, {"entry", .Bytes, nil}}, {}},
	{PLUG_UNLOCK, "unlock.unlock", .Unlock, 120_000, true, {{"rp_user", .Bytes, nil}, {"credentials", .Strs, nil}, {"salts", .Strs, nil}, {"mode", .Enum, UNLOCK_MODE_NAMES}}, {{"credential", .Bytes, nil}, {"prf", .Bytes, nil}}},
	{PLUG_REGISTER, "unlock.register", .Unlock, 120_000, true, {{"rp_user", .Bytes, nil}, {"label", .Str, nil}, {"salt", .Bytes, nil}}, {{"credential", .Bytes, nil}, {"prf", .Bytes, nil}, {"ecosystem", .Enum, ECOSYSTEM_NAMES}}},
	{PLUG_POOL_IDENTITY, "runner_pool.identity", .Runner_Pool, 15_000, true, {}, {{"sign", .Bytes, nil}, {"box", .Bytes, nil}}},
	{PLUG_POOL_VERIFY, "runner_pool.verify", .Runner_Pool, 15_000, true, {{"token", .Bytes, nil}, {"sign", .Bytes, nil}, {"box", .Bytes, nil}}, {{"lease_ms", .U64, nil}}},
	{PLUG_POOL_ATTEST, "runner_pool.attest", .Runner_Pool, 15_000, true, {{"evidence", .Bytes, nil}, {"sign", .Bytes, nil}, {"box", .Bytes, nil}}, {}},
	{PLUG_USER_IDENTITY, "pool_user.identity", .Pool_User, 15_000, true, {}, {{"sign", .Bytes, nil}, {"box", .Bytes, nil}}},
	{PLUG_USER_JOINED, "pool_user.joined", .Pool_User, 0, false, {{"space", .Id, nil}, {"name", .Str, nil}, {"relay", .Str, nil}, {"relay_key", .Bytes, nil}, {"proof", .Bytes, nil}}, {}},
	{PLUG_CRED_AVAILABLE, "credentials.available", .Credentials, 5_000, false, {{"space", .Id, nil}}, {{"available", .Bool, nil}}},
	{PLUG_CRED_PRODUCE, "credentials.produce", .Credentials, 5_000, false, {{"space", .Id, nil}, {"binding", .Bytes, nil}}, {{"credential", .Bytes, nil}}},
}

Plug_Enum :: struct {
	v:     u64,
	names: []string,
}

Plug_Value :: union {
	[]u8,
	string,
	u64,
	bool,
	prim.Id,
	[][]u8,
	Plug_Enum,
}

Plug_Field :: struct {
	name:  string,
	value: Plug_Value,
}

Plug_Note :: struct {
	json: []u8,
	bin:  []u8,
}

Host_Cred :: struct {
	d:     ^Daemon,
	space: prim.Id,
}

Host_Chan :: struct {
	enabled:   Host_Plugs,
	owner:     [Host_Plug]^Conn,
	next_tag:  u64,
	req_tag:   u64,
	req_from:  ^Conn,
	req_done:  bool,
	req_st:    api.Status,
	req_body:  [dynamic]u8,
	req_json:  bool,
	waiting:   bool,
	current:   ^Conn,
	cur_tag:   u64,
	cancelled: bool,
	failure:   api.Status,
	notes:     [dynamic]Plug_Note,
	creds:     map[prim.Id]^Host_Cred,
	sweep:     prim.Timer,
}

host_plugs_setup :: proc(d: ^Daemon, ec: ^eng.Config, args: ^Args) -> bool {
	hc := &d.hc
	hc.req_body = make([dynamic]u8)
	hc.notes = make([dynamic]Plug_Note)
	hc.creds = make(map[prim.Id]^Host_Cred)
	spec := flag_string(args, "host-plugs")
	if len(spec) == 0 {
		return true
	}
	for name in strings.split(spec, ",", context.temp_allocator) {
		n := strings.trim_space(name)
		if len(n) == 0 {
			continue
		}
		found := false
		for p in Host_Plug {
			if HOST_PLUG_NAMES[p] == n {
				hc.enabled += {p}
				found = true
			}
		}
		if !found {
			return false
		}
	}
	if .Sealed_Store in hc.enabled {
		ec.sealed_store = osync.Sealed_Store{data = d, get = _hp_store_get, put = _hp_store_put, add = _hp_store_add}
	}
	if .Unlock in hc.enabled {
		ec.unlock = osync.Unlock{data = d, unlock = _hp_unlock, register = _hp_register}
	}
	if .Runner_Pool in hc.enabled && .Pool_User in hc.enabled {
		return false
	}
	if .Runner_Pool in hc.enabled {
		ec.runner_pool = eng.Runner_Pool{data = d, identity = _hp_pool_identity, verify = _hp_pool_verify, attest = _hp_pool_attest}
	}
	if .Pool_User in hc.enabled {
		ec.runner_pool = eng.Runner_Pool{data = d, identity = _hp_user_identity, joined = _hp_user_joined}
	}
	if .Credentials in hc.enabled {
		ec.credentials = eng.Credentials_Source{data = d, produce = _hp_cred_source}
	}
	return true
}

host_plugs_destroy :: proc(d: ^Daemon) {
	hc := &d.hc
	if hc.sweep != 0 {
		prim.timer_cancel(&d.s.loop, hc.sweep)
		hc.sweep = 0
	}
	for n in hc.notes {
		delete(n.json)
		delete(n.bin)
	}
	delete(hc.notes)
	for _, c in hc.creds {
		free(c)
	}
	delete(hc.creds)
	delete(hc.req_body)
}

host_release :: proc(d: ^Daemon, c: ^Conn) {
	hc := &d.hc
	for p in Host_Plug {
		if hc.owner[p] == c {
			hc.owner[p] = nil
			fmt.eprintfln("0ndb daemon: host for %s disconnected", HOST_PLUG_NAMES[p])
		}
	}
	c.plugs = {}
	if hc.current == c {
		hc.current = nil
	}
	if hc.req_from == c {
		hc.req_from = nil
	}
}

host_plug_names :: proc(set: Host_Plugs, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for p in Host_Plug {
		if p in set {
			append(&out, HOST_PLUG_NAMES[p])
		}
	}
	return out[:]
}

host_registered :: proc(d: ^Daemon) -> Host_Plugs {
	set: Host_Plugs
	for p in Host_Plug {
		if d.hc.owner[p] != nil {
			set += {p}
		}
	}
	return set
}

op_host_register :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	pc := (^Pending)(c.data)
	if pc == nil || pc.conn == nil {
		return .Unsupported
	}
	conn := pc.conn
	hc := &d.hc
	want: Host_Plugs
	for name in api.a_strs(c, "plugs") {
		found := false
		for p in Host_Plug {
			if HOST_PLUG_NAMES[p] == name {
				want += {p}
				found = true
			}
		}
		if !found {
			return .Invalid
		}
	}
	if want - hc.enabled != {} {
		return .Unsupported
	}
	replace := api.a_bool(c, "replace")
	for p in want {
		if hc.owner[p] != nil && hc.owner[p] != conn && !hc.owner[p].dead && !replace {
			return .Busy
		}
	}
	for p in Host_Plug {
		if hc.owner[p] == conn && p not_in want {
			hc.owner[p] = nil
		}
	}
	for p in want {
		prev := hc.owner[p]
		if prev != nil && prev != conn {
			prev.plugs -= {p}
		}
		hc.owner[p] = conn
	}
	conn.plugs = want
	conn.host_json = c.json
	if card(want) > 0 {
		fmt.eprintfln("0ndb daemon: host registered for %s", strings.join(host_plug_names(want), ",", context.temp_allocator))
	}
	names := host_plug_names(want)
	api.o_arr(o, "plugs", len(names))
	for n in names {
		api.o_str(o, "", n)
	}
	api.o_end(o)
	if .Pool_User in want {
		_host_flush_notes(d)
	}
	return .Ok
}

@(private)
_plug_fn :: proc(code: u16) -> ^Plug_Fn {
	for &f in PLUG_FNS {
		if f.code == code {
			return &f
		}
	}
	return nil
}

@(private)
_plug_encode :: proc(fn: ^Plug_Fn, fields: []Plug_Field, json_form: bool) -> []u8 {
	buf := make([dynamic]u8, context.temp_allocator)
	o: api.Out
	api.out_init(&o, &buf, json_form)
	if json_form {
		api.o_str(&o, "plug", fn.name)
	} else {
		prim.write_u8(&o.w, PLUG_VERSION)
		prim.write_uvarint(&o.w, u64(fn.code))
	}
	for f in fields {
		switch v in f.value {
		case []u8:
			api.o_bytes(&o, f.name, v)
		case string:
			api.o_str(&o, f.name, v)
		case u64:
			api.o_u64(&o, f.name, v)
		case bool:
			api.o_bool(&o, f.name, v)
		case prim.Id:
			api.o_id(&o, f.name, v)
		case Plug_Enum:
			api.o_enum(&o, f.name, v.v, v.names)
		case [][]u8:
			api.o_arr(&o, f.name, len(v))
			for b in v {
				api.o_bytes(&o, "", b)
			}
			api.o_end(&o)
		}
	}
	return api.out_finish(&o)
}

@(private)
_plug_write :: proc(c: ^Conn, kind: Frame_Kind, tag: u64, body: []u8) {
	t := u64_bytes(tag)
	_conn_write(c, kind, t[:], body)
}

@(private)
_host_owner :: proc(d: ^Daemon, p: Host_Plug) -> ^Conn {
	c := d.hc.owner[p]
	if c != nil && c.dead {
		host_release(d, c)
		return nil
	}
	return c
}

@(private)
_plug_decode :: proc(fn: ^Plug_Fn, body: []u8, json_form: bool, out: ^api.Call) -> bool {
	out.op = new_clone(api.Op{fn.code, fn.name, fn.reply, "", nil}, context.temp_allocator)
	op := out.op
	if json_form {
		if len(body) == 0 {
			out.args.values = make([]api.Value, len(fn.reply), context.temp_allocator)
			return true
		}
		root, perr := json.parse(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if perr != .None {
			return false
		}
		ob, ok := root.(json.Object)
		if !ok {
			return false
		}
		out.json = true
		return api.decode_json(op, ob, &out.args, context.temp_allocator)
	}
	r := prim.reader(body)
	return api.decode_binary(op, &r, &out.args, context.temp_allocator)
}

@(private)
_plug_call :: proc(d: ^Daemon, code: u16, fields: []Plug_Field, out: ^api.Call) -> api.Status {
	hc := &d.hc
	fn := _plug_fn(code)
	if hc.waiting {
		return .Busy
	}
	jreq := _plug_encode(fn, fields, true)
	breq := _plug_encode(fn, fields, false)
	hc.next_tag += 1
	tag := hc.next_tag
	hc.req_tag = tag
	hc.req_done = false
	hc.req_from = nil
	clear(&hc.req_body)
	hc.waiting = true
	defer {
		hc.waiting = false
		hc.req_tag = 0
		hc.req_from = nil
		_host_schedule_sweep(d)
	}
	deadline := prim.now_ms() + fn.timeout
	sent_to: ^Conn
	st := api.Status.Ok
	for {
		if hc.req_done {
			st = hc.req_st
			break
		}
		h := _host_owner(d, fn.plug)
		if sent_to != nil && (sent_to != h || sent_to.dead) {
			if !sent_to.dead && h != sent_to {
				_plug_write(sent_to, .Plug_Cancel, tag, nil)
			}
			sent_to = nil
		}
		if hc.cancelled || d.stopping {
			st = .Cancelled
			break
		}
		if h != nil && sent_to == nil {
			_plug_write(h, .Plug, tag, jreq if h.host_json else breq)
			sent_to = h
			hc.req_from = h
		}
		if h == nil && !fn.wait_host {
			st = .Offline
			break
		}
		now := prim.now_ms()
		if now >= deadline {
			st = .Timeout if h != nil else .Offline
			break
		}
		_host_wait(d, deadline - now)
	}
	if st != .Ok && sent_to != nil && !sent_to.dead && !hc.req_done {
		_plug_write(sent_to, .Plug_Cancel, tag, nil)
	}
	if st != .Ok {
		if hc.failure == .Ok && !hc.req_done {
			hc.failure = st
		}
		return st
	}
	if !_plug_decode(fn, hc.req_body[:], hc.req_json, out) {
		if hc.failure == .Ok {
			hc.failure = .Bad_Request
		}
		return .Bad_Request
	}
	return .Ok
}

@(private)
_host_wait :: proc(d: ^Daemon, timeout_ms: i64) {
	items := make([dynamic]Poll_Item, context.temp_allocator)
	conns := make([dynamic]^Conn, context.temp_allocator)
	lidx, sidx := -1, -1
	if d.lfd != NO_SOCK {
		lidx = len(items)
		append(&items, Poll_Item{fd = d.lfd})
	}
	if sfd, sok := signals_sock(&d.sig); sok {
		sidx = len(items)
		append(&items, Poll_Item{fd = sfd})
	}
	nfixed := len(items)
	for c in d.conns {
		if c.dead || c.fd == NO_SOCK {
			continue
		}
		append(&items, Poll_Item{fd = c.fd, write = len(c.wbuf) > 0})
		append(&conns, c)
	}
	if !sock_poll(items[:], timeout_ms) {
		return
	}
	if lidx >= 0 && items[lidx].ready {
		_host_accept(d)
	}
	if sidx >= 0 && items[sidx].ready {
		for {
			sig, ok := signals_read(&d.sig)
			if !ok {
				break
			}
			fmt.eprintfln("0ndb daemon: signal %d, shutting down", sig)
			d.stopping = true
		}
	}
	for c, i in conns {
		if items[nfixed + i].ready && !c.dead {
			_host_scan(d, c)
		}
	}
}

@(private)
_host_accept :: proc(d: ^Daemon) {
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
_host_scan :: proc(d: ^Daemon, c: ^Conn) {
	if len(c.wbuf) > 0 {
		_conn_flush(c)
	}
	buf: [65536]u8
	for !c.dead && len(c.rbuf) < PLUG_RBUF_MAX {
		n, st := sock_read(c.fd, buf[:])
		if st == .Again {
			break
		}
		if st != .Ok {
			c.dead = true
			break
		}
		append(&c.rbuf, ..buf[:n])
	}
	if !c.sniffed {
		if len(c.rbuf) < 5 || string(c.rbuf[:4]) != MAGIC {
			return
		}
		if c.rbuf[4] != PROTO_VERSION {
			_conn_version_mismatch(c)
			return
		}
		remove_range(&c.rbuf, 0, 5)
		c.sniffed = true
	}
	pos := 0
	for !c.dead {
		k, p, used, have, bad := frame_next(c.rbuf[pos:])
		if bad {
			c.dead = true
			return
		}
		if !have {
			break
		}
		take := false
		#partial switch k {
		case .Plug_Reply:
			take = true
			host_plug_reply(d, c, p)
		case .Cancel:
			if len(p) >= 8 && c == d.hc.current && prim.get_u64le(p[:8]) == d.hc.cur_tag {
				d.hc.cancelled = true
				take = true
			}
		case .Call:
			if len(p) >= 17 && _is_register(d, p[8] & 1 != 0, p[17:]) {
				payload := make([]u8, len(p), context.temp_allocator)
				copy(payload, p)
				remove_range(&c.rbuf, pos, pos + used)
				_conn_call(c, payload)
				continue
			}
		}
		if take {
			remove_range(&c.rbuf, pos, pos + used)
		} else {
			pos += used
		}
	}
}

@(private)
_is_register :: proc(d: ^Daemon, json_form: bool, req: []u8) -> bool {
	if json_form {
		root, err := json.parse(req, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if err != .None {
			return false
		}
		ob, ok := root.(json.Object)
		if !ok {
			return false
		}
		name, nok := ob["op"].(json.String)
		return nok && string(name) == "host.register"
	}
	r := prim.reader(req)
	if prim.read_u8(&r) != api.VERSION {
		return false
	}
	code := prim.read_uvarint(&r)
	return prim.reader_ok(&r) && code == HOST_REGISTER_CODE
}

host_plug_reply :: proc(d: ^Daemon, c: ^Conn, p: []u8) {
	hc := &d.hc
	if len(p) < 9 {
		c.dead = true
		return
	}
	tag := prim.get_u64le(p[:8])
	if !hc.waiting || tag != hc.req_tag || c != hc.req_from || hc.req_done {
		return
	}
	hc.req_st = api.Status(p[8]) if p[8] <= u8(max(api.Status)) else .Io
	clear(&hc.req_body)
	append(&hc.req_body, ..p[9:])
	hc.req_json = c.host_json
	hc.req_done = true
}

@(private)
_host_schedule_sweep :: proc(d: ^Daemon) {
	if d.hc.sweep == 0 {
		d.hc.sweep = prim.timer(&d.s.loop, 0, d, _host_sweep)
	}
}

@(private)
_host_sweep :: proc(l: ^prim.Loop, data: rawptr) {
	d := (^Daemon)(data)
	d.hc.sweep = 0
	snapshot := make([]^Conn, len(d.conns), context.temp_allocator)
	serials := make([]u64, len(d.conns), context.temp_allocator)
	for c, i in d.conns {
		snapshot[i] = c
		serials[i] = c.serial
	}
	for c, i in snapshot {
		live := false
		for x in d.conns {
			if x == c && x.serial == serials[i] {
				live = true
				break
			}
		}
		if !live {
			continue
		}
		if !c.dead && len(c.rbuf) > 0 {
			if !_conn_process(c) {
				continue
			}
		}
		if c.dead {
			_conn_drop(c, true)
		}
	}
}

@(private)
_host_flush_notes :: proc(d: ^Daemon) {
	h := _host_owner(d, .Pool_User)
	if h == nil {
		return
	}
	for n in d.hc.notes {
		_plug_write(h, .Plug, 0, n.json if h.host_json else n.bin)
		delete(n.json)
		delete(n.bin)
	}
	clear(&d.hc.notes)
}

@(private)
_plug_err :: proc(st: api.Status) -> osync.Error {
	#partial switch st {
	case .Ok:
		return .None
	case .Not_Found:
		return .Not_Found
	case .Exists:
		return .Exists
	case .Conflict:
		return .Conflict
	case .Permission:
		return .Permission
	case .Unsupported:
		return .Unsupported
	case .Invalid, .Bad_Request:
		return .Invalid
	case .Busy:
		return .Busy
	case .Too_Large:
		return .Too_Large
	case .Timeout:
		return .Timeout
	case .Offline, .Cancelled, .Closed:
		return .Closed
	}
	return .Io
}

@(private)
_hp_store_get :: proc(data: rawptr, subject: []u8, record: ^[dynamic]u8, entries: ^[dynamic][]u8) -> osync.Error {
	d := (^Daemon)(data)
	out: api.Call
	st := _plug_call(d, PLUG_STORE_GET, {{"subject", subject}}, &out)
	if st != .Ok {
		return _plug_err(st)
	}
	rec := api.a_bytes(&out, "record")
	if len(rec) > 64 * 1024 {
		return .Too_Large
	}
	append(record, ..rec)
	total := 0
	for e in api.a_strs(&out, "entries") {
		raw := transmute([]u8)e
		if out.json {
			v, ok := hex_decode(e)
			if !ok {
				return .Corrupt
			}
			raw = v
		}
		total += len(raw)
		if total > 4 * 1024 * 1024 {
			return .Too_Large
		}
		b := make([]u8, len(raw), context.temp_allocator)
		copy(b, raw)
		append(entries, b)
	}
	return .None
}

@(private)
_hp_store_put :: proc(data: rawptr, subject: []u8, record: []u8, prev_seq: u64) -> osync.Error {
	d := (^Daemon)(data)
	rec: osync.Account_Record
	if err := osync.account_record_decode(record, &rec, context.temp_allocator); err != .None {
		return err
	}
	out: api.Call
	return _plug_err(_plug_call(d, PLUG_STORE_PUT, {{"subject", subject}, {"record", record}, {"prev_seq", prev_seq}, {"seq", rec.seq}}, &out))
}

@(private)
_hp_store_add :: proc(data: rawptr, subject: []u8, entry: []u8) -> osync.Error {
	d := (^Daemon)(data)
	out: api.Call
	return _plug_err(_plug_call(d, PLUG_STORE_ADD, {{"subject", subject}, {"entry", entry}}, &out))
}

@(private)
_hp_prf :: proc(out: ^api.Call, credential: ^[dynamic]u8, prf: ^[32]u8) -> osync.Error {
	cred := api.a_bytes(out, "credential")
	p := api.a_bytes(out, "prf")
	if len(cred) == 0 || len(cred) > 1024 || len(p) != 32 {
		return .Invalid
	}
	append(credential, ..cred)
	copy(prf[:], p)
	return .None
}

@(private)
_hp_unlock :: proc(data: rawptr, rp_user: []u8, options: []osync.Unlock_Option, mode: osync.Unlock_Mode, credential: ^[dynamic]u8, prf: ^[32]u8) -> osync.Error {
	d := (^Daemon)(data)
	out: api.Call
	creds := make([][]u8, len(options), context.temp_allocator)
	salts := make([][]u8, len(options), context.temp_allocator)
	for opt, i in options {
		creds[i] = opt.credential
		salt := make([]u8, 32, context.temp_allocator)
		x := opt.salt
		copy(salt, x[:])
		salts[i] = salt
	}
	st := _plug_call(d, PLUG_UNLOCK, {{"rp_user", rp_user}, {"credentials", creds}, {"salts", salts}, {"mode", Plug_Enum{u64(mode), UNLOCK_MODE_NAMES}}}, &out)
	if st != .Ok {
		return _plug_err(st)
	}
	return _hp_prf(&out, credential, prf)
}

@(private)
_hp_register :: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, credential: ^[dynamic]u8, prf: ^[32]u8, ecosystem: ^osync.Ecosystem) -> osync.Error {
	d := (^Daemon)(data)
	out: api.Call
	s := salt
	st := _plug_call(d, PLUG_REGISTER, {{"rp_user", rp_user}, {"label", label}, {"salt", s[:]}}, &out)
	if st != .Ok {
		return _plug_err(st)
	}
	eco := api.a_int(&out, "ecosystem")
	if eco < 0 || eco > int(max(osync.Ecosystem)) {
		return .Invalid
	}
	ecosystem^ = osync.Ecosystem(eco)
	return _hp_prf(&out, credential, prf)
}

@(private)
_hp_identity :: proc(d: ^Daemon, code: u16) -> osync.Identity {
	out: api.Call
	if _plug_call(d, code, {}, &out) != .Ok {
		return {}
	}
	sign := api.a_bytes(&out, "sign")
	box := api.a_bytes(&out, "box")
	if len(sign) != 32 || len(box) != 32 {
		return {}
	}
	s, b: osync.Public_Key
	copy(s[:], sign)
	copy(b[:], box)
	return osync.identity_of(s, b)
}

@(private)
_hp_pool_identity :: proc(data: rawptr) -> osync.Identity {
	return _hp_identity((^Daemon)(data), PLUG_POOL_IDENTITY)
}

@(private)
_hp_user_identity :: proc(data: rawptr) -> osync.Identity {
	return _hp_identity((^Daemon)(data), PLUG_USER_IDENTITY)
}

@(private)
_hp_pool_verify :: proc(data: rawptr, token: []u8, runner: osync.Identity) -> (u64, osync.Error) {
	d := (^Daemon)(data)
	out: api.Call
	r := runner
	st := _plug_call(d, PLUG_POOL_VERIFY, {{"token", token}, {"sign", r.sign[:]}, {"box", r.box[:]}}, &out)
	if st != .Ok {
		return 0, .Auth if st == .Permission else _plug_err(st)
	}
	return api.a_u64(&out, "lease_ms"), .None
}

@(private)
_hp_pool_attest :: proc(data: rawptr, evidence: []u8, runner: osync.Identity) -> osync.Error {
	d := (^Daemon)(data)
	out: api.Call
	r := runner
	return _plug_err(_plug_call(d, PLUG_POOL_ATTEST, {{"evidence", evidence}, {"sign", r.sign[:]}, {"box", r.box[:]}}, &out))
}

@(private)
_hp_user_joined :: proc(data: rawptr, space: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, proof: []u8) {
	d := (^Daemon)(data)
	fn := _plug_fn(PLUG_USER_JOINED)
	rk := relay_public
	fields := []Plug_Field{{"space", space}, {"name", name}, {"relay", relay}, {"relay_key", rk[:]}, {"proof", proof}}
	jreq := _plug_encode(fn, fields, true)
	breq := _plug_encode(fn, fields, false)
	if h := _host_owner(d, .Pool_User); h != nil {
		_plug_write(h, .Plug, 0, jreq if h.host_json else breq)
		return
	}
	if len(d.hc.notes) >= PLUG_NOTES_MAX {
		n := d.hc.notes[0]
		delete(n.json)
		delete(n.bin)
		ordered_remove(&d.hc.notes, 0)
	}
	append(&d.hc.notes, Plug_Note{clone_bytes(jreq), clone_bytes(breq)})
}

@(private)
_hp_cred_source :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	d := (^Daemon)(data)
	if c, ok := _cred_produce(d, space); ok {
		return c, true
	}
	out: api.Call
	if _plug_call(d, PLUG_CRED_AVAILABLE, {{"space", space}}, &out) != .Ok || !api.a_bool(&out, "available") {
		return {}, false
	}
	hcred, have := d.hc.creds[space]
	if !have {
		hcred = new(Host_Cred)
		hcred.d = d
		hcred.space = space
		d.hc.creds[space] = hcred
	}
	return osync.Credentials{data = hcred, produce = _hp_cred_produce}, true
}

@(private)
_hp_cred_produce :: proc(data: rawptr, binding: []u8, out_buf: ^[dynamic]u8) -> osync.Error {
	hcred := (^Host_Cred)(data)
	out: api.Call
	st := _plug_call(hcred.d, PLUG_CRED_PRODUCE, {{"space", hcred.space}, {"binding", binding}}, &out)
	if st != .Ok {
		return .Auth
	}
	cred := api.a_bytes(&out, "credential")
	if len(cred) == 0 || len(cred) > osync.CREDENTIAL_MAX {
		return .Auth
	}
	append(out_buf, ..cred)
	return .None
}

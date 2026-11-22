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
PLUG_POOL_VERIFY :: 7
PLUG_POOL_ATTEST :: 8
PLUG_USER_JOINED :: 10
PLUG_CRED_PRODUCE :: 12

PLUG_FNS := []Plug_Fn {
	{PLUG_STORE_GET, "sealed_store.get", .Sealed_Store, 15_000, true, {{"subject", .Bytes, nil}}, {{"record", .Bytes, nil}, {"entries", .Strs, nil}}},
	{PLUG_STORE_PUT, "sealed_store.put", .Sealed_Store, 15_000, true, {{"subject", .Bytes, nil}, {"record", .Bytes, nil}, {"prev_seq", .U64, nil}, {"seq", .U64, nil}}, {}},
	{PLUG_STORE_ADD, "sealed_store.add", .Sealed_Store, 15_000, true, {{"subject", .Bytes, nil}, {"entry", .Bytes, nil}}, {}},
	{PLUG_UNLOCK, "unlock.unlock", .Unlock, 120_000, true, {{"rp_user", .Bytes, nil}, {"credentials", .Strs, nil}, {"salts", .Strs, nil}, {"mode", .Enum, UNLOCK_MODE_NAMES}}, {{"credential", .Bytes, nil}, {"prf", .Bytes, nil}}},
	{PLUG_REGISTER, "unlock.register", .Unlock, 120_000, true, {{"rp_user", .Bytes, nil}, {"label", .Str, nil}, {"salt", .Bytes, nil}}, {{"credential", .Bytes, nil}, {"prf", .Bytes, nil}, {"ecosystem", .Enum, ECOSYSTEM_NAMES}}},
	{PLUG_POOL_VERIFY, "runner_pool.verify", .Runner_Pool, 15_000, true, {{"token", .Bytes, nil}, {"sign", .Bytes, nil}, {"box", .Bytes, nil}}, {{"lease_ms", .U64, nil}}},
	{PLUG_POOL_ATTEST, "runner_pool.attest", .Runner_Pool, 15_000, true, {{"evidence", .Bytes, nil}, {"sign", .Bytes, nil}, {"box", .Bytes, nil}}, {}},
	{PLUG_USER_JOINED, "pool_user.joined", .Pool_User, 0, false, {{"space", .Id, nil}, {"name", .Str, nil}, {"relay", .Str, nil}, {"relay_key", .Bytes, nil}, {"proof", .Bytes, nil}}, {}},
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

Plug_Req :: struct {
	d:       ^Daemon,
	tag:     u64,
	fn:      ^Plug_Fn,
	done:    osync.Plug_Done,
	json:    []u8,
	bin:     []u8,
	sent_to: ^Conn,
	serial:  u64,
	timer:   prim.Timer,
}

Host_Cred :: struct {
	d:     ^Daemon,
	space: prim.Id,
}

Host_Chan :: struct {
	enabled:  Host_Plugs,
	owner:    [Host_Plug]^Conn,
	next_tag: u64,
	reqs:     [dynamic]^Plug_Req,
	notes:    [dynamic]Plug_Note,
	creds:    map[prim.Id]^Host_Cred,
	identity: [Host_Plug]osync.Identity,
	spaces:   [dynamic]prim.Id,
	sweep:    prim.Timer,
	dispatch: bool,
	resume:   bool,
}

host_plugs_setup :: proc(d: ^Daemon, ec: ^eng.Config, args: ^Args) -> bool {
	hc := &d.hc
	hc.reqs = make([dynamic]^Plug_Req)
	hc.notes = make([dynamic]Plug_Note)
	hc.creds = make(map[prim.Id]^Host_Cred)
	hc.spaces = make([dynamic]prim.Id)
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
		ec.sealed_store = osync.Sealed_Store{data = d, get = _hp_store_get, put = _hp_store_put, add = _hp_store_add, cancel = _hp_cancel}
	}
	if .Unlock in hc.enabled {
		ec.unlock = osync.Unlock{data = d, unlock = _hp_unlock, register = _hp_register, cancel = _hp_cancel}
	}
	if .Runner_Pool in hc.enabled && .Pool_User in hc.enabled {
		return false
	}
	if .Runner_Pool in hc.enabled {
		ec.runner_pool = eng.Runner_Pool{data = d, identity = _hp_pool_identity, verify = _hp_pool_verify, attest = _hp_pool_attest, cancel = _hp_cancel}
	}
	if .Pool_User in hc.enabled {
		ec.runner_pool = eng.Runner_Pool{data = d, identity = _hp_user_identity, joined = _hp_user_joined, cancel = _hp_cancel}
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
	for len(hc.reqs) > 0 {
		r := hc.reqs[len(hc.reqs) - 1]
		_req_finish(r, .Closed, nil)
	}
	delete(hc.reqs)
	for n in hc.notes {
		delete(n.json)
		delete(n.bin)
	}
	delete(hc.notes)
	for _, c in hc.creds {
		free(c)
	}
	delete(hc.creds)
	delete(hc.spaces)
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
	for r in hc.reqs {
		if r.sent_to == c {
			r.sent_to = nil
		}
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

host_pending :: proc(d: ^Daemon) -> int {
	return len(d.hc.reqs)
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
	ident := api.a_bytes(c, "identity")
	if (.Runner_Pool in want || .Pool_User in want) && len(ident) != 64 {
		return .Invalid
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
		if p == .Runner_Pool || p == .Pool_User {
			s, b: osync.Public_Key
			copy(s[:], ident[:32])
			copy(b[:], ident[32:])
			hc.identity[p] = osync.identity_of(s, b)
		}
	}
	if .Credentials in want {
		clear(&hc.spaces)
		append(&hc.spaces, ..api.a_ids(c, "spaces"))
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
	hc.dispatch = true
	hc.resume ||= .Sealed_Store in want
	_host_schedule_sweep(d)
	return .Ok
}

@(private)
_host_dispatch :: proc(d: ^Daemon) {
	hc := &d.hc
	hc.dispatch = false
	for r in hc.reqs {
		if r.sent_to == nil {
			if h := _host_owner(d, r.fn.plug); h != nil {
				_req_send(r, h)
			}
		}
	}
	_host_flush_notes(d)
	if hc.resume {
		hc.resume = false
		eng.account_resume(&d.s.e)
	}
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
_req_send :: proc(r: ^Plug_Req, c: ^Conn) {
	r.sent_to = c
	r.serial = c.serial
	_plug_write(c, .Plug, r.tag, r.json if c.host_json else r.bin)
}

@(private)
_req_remove :: proc(r: ^Plug_Req) {
	hc := &r.d.hc
	for x, i in hc.reqs {
		if x == r {
			ordered_remove(&hc.reqs, i)
			break
		}
	}
	if r.timer != 0 {
		prim.timer_cancel(&r.d.s.loop, r.timer)
		r.timer = 0
	}
	if r.sent_to != nil && !r.sent_to.dead {
		_plug_write(r.sent_to, .Plug_Cancel, r.tag, nil)
	}
}

@(private)
_req_free :: proc(r: ^Plug_Req) {
	delete(r.json)
	delete(r.bin)
	free(r)
}

@(private)
_req_finish :: proc(r: ^Plug_Req, err: osync.Error, reply: ^osync.Plug_Reply) {
	_req_remove(r)
	done := r.done
	_req_free(r)
	empty: osync.Plug_Reply
	done.call(done.data, err, reply if reply != nil else &empty)
}

@(private)
_plug_issue :: proc(d: ^Daemon, code: u16, fields: []Plug_Field, done: osync.Plug_Done) -> osync.Error {
	hc := &d.hc
	fn := _plug_fn(code)
	h := _host_owner(d, fn.plug)
	if h == nil && !fn.wait_host {
		return .Closed
	}
	r := new(Plug_Req)
	r.d = d
	hc.next_tag += 1
	r.tag = hc.next_tag
	r.fn = fn
	r.done = done
	r.json = clone_bytes(_plug_encode(fn, fields, true))
	r.bin = clone_bytes(_plug_encode(fn, fields, false))
	r.timer = prim.timer(&d.s.loop, fn.timeout, r, _req_deadline)
	append(&hc.reqs, r)
	if h != nil {
		_req_send(r, h)
	}
	return .Pending
}

@(private)
_req_deadline :: proc(l: ^prim.Loop, data: rawptr) {
	r := (^Plug_Req)(data)
	r.timer = 0
	_req_finish(r, .Timeout if r.sent_to != nil else .Closed, nil)
}

@(private)
_hp_cancel :: proc(data: rawptr, done: osync.Plug_Done) {
	d := (^Daemon)(data)
	for r in d.hc.reqs {
		if r.done.data == done.data {
			_req_remove(r)
			_req_free(r)
			return
		}
	}
}

host_plug_reply :: proc(d: ^Daemon, c: ^Conn, p: []u8) {
	if len(p) < 9 {
		c.dead = true
		return
	}
	tag := prim.get_u64le(p[:8])
	r: ^Plug_Req
	for x in d.hc.reqs {
		if x.tag == tag && x.sent_to == c && x.serial == c.serial {
			r = x
			break
		}
	}
	if r == nil {
		return
	}
	r.sent_to = nil
	st := api.Status(p[8]) if p[8] <= u8(max(api.Status)) else .Io
	if st != .Ok {
		_req_finish(r, _plug_err(st), nil)
		return
	}
	out: api.Call
	if !_plug_decode(r.fn, p[9:], c.host_json, &out) {
		_req_finish(r, .Invalid, nil)
		return
	}
	reply: osync.Plug_Reply
	err := _plug_reply(r.fn, &out, &reply)
	_req_finish(r, err, &reply)
}

@(private)
_plug_decode :: proc(fn: ^Plug_Fn, body: []u8, json_form: bool, out: ^api.Call) -> bool {
	out.op = new_clone(api.Op{fn.code, fn.name, fn.reply, "", nil}, context.temp_allocator)
	out.json = json_form
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
		return api.decode_json(out.op, ob, &out.args, context.temp_allocator)
	}
	r := prim.reader(body)
	return api.decode_binary(out.op, &r, &out.args, context.temp_allocator)
}

@(private)
_plug_reply :: proc(fn: ^Plug_Fn, out: ^api.Call, reply: ^osync.Plug_Reply) -> osync.Error {
	switch fn.code {
	case PLUG_STORE_GET:
		reply.record = api.a_bytes(out, "record")
		if len(reply.record) > 64 * 1024 {
			return .Too_Large
		}
		list := make([dynamic][]u8, context.temp_allocator)
		total := 0
		for e in api.a_strs(out, "entries") {
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
			append(&list, raw)
		}
		reply.entries = list[:]
	case PLUG_UNLOCK, PLUG_REGISTER:
		cred := api.a_bytes(out, "credential")
		p := api.a_bytes(out, "prf")
		if len(cred) == 0 || len(cred) > 1024 || len(p) != 32 {
			return .Invalid
		}
		reply.credential = cred
		copy(reply.prf[:], p)
		if fn.code == PLUG_REGISTER {
			eco := api.a_int(out, "ecosystem")
			if eco < 0 || eco > int(max(osync.Ecosystem)) {
				return .Invalid
			}
			reply.ecosystem = osync.Ecosystem(eco)
		}
	case PLUG_POOL_VERIFY:
		reply.lease_ms = api.a_u64(out, "lease_ms")
	case PLUG_CRED_PRODUCE:
		cred := api.a_bytes(out, "credential")
		if len(cred) == 0 || len(cred) > osync.CREDENTIAL_MAX {
			return .Auth
		}
		reply.credential = cred
	}
	return .None
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
		if live && c.dead {
			_conn_drop(c, true)
		}
	}
	if d.hc.dispatch {
		_host_dispatch(d)
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
_hp_store_get :: proc(data: rawptr, subject: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	return _plug_issue((^Daemon)(data), PLUG_STORE_GET, {{"subject", subject}}, done)
}

@(private)
_hp_store_put :: proc(data: rawptr, subject: []u8, record: []u8, prev_seq: u64, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	rec: osync.Account_Record
	if err := osync.account_record_decode(record, &rec, context.temp_allocator); err != .None {
		return err
	}
	return _plug_issue((^Daemon)(data), PLUG_STORE_PUT, {{"subject", subject}, {"record", record}, {"prev_seq", prev_seq}, {"seq", rec.seq}}, done)
}

@(private)
_hp_store_add :: proc(data: rawptr, subject: []u8, entry: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	return _plug_issue((^Daemon)(data), PLUG_STORE_ADD, {{"subject", subject}, {"entry", entry}}, done)
}

@(private)
_hp_unlock :: proc(data: rawptr, rp_user: []u8, options: []osync.Unlock_Option, mode: osync.Unlock_Mode, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	creds := make([][]u8, len(options), context.temp_allocator)
	salts := make([][]u8, len(options), context.temp_allocator)
	for opt, i in options {
		creds[i] = opt.credential
		salt := make([]u8, 32, context.temp_allocator)
		x := opt.salt
		copy(salt, x[:])
		salts[i] = salt
	}
	return _plug_issue((^Daemon)(data), PLUG_UNLOCK, {{"rp_user", rp_user}, {"credentials", creds}, {"salts", salts}, {"mode", Plug_Enum{u64(mode), UNLOCK_MODE_NAMES}}}, done)
}

@(private)
_hp_register :: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	s := salt
	return _plug_issue((^Daemon)(data), PLUG_REGISTER, {{"rp_user", rp_user}, {"label", label}, {"salt", s[:]}}, done)
}

@(private)
_hp_pool_identity :: proc(data: rawptr) -> osync.Identity {
	return (^Daemon)(data).hc.identity[.Runner_Pool]
}

@(private)
_hp_user_identity :: proc(data: rawptr) -> osync.Identity {
	return (^Daemon)(data).hc.identity[.Pool_User]
}

@(private)
_hp_pool_verify :: proc(data: rawptr, token: []u8, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	r := runner
	return _plug_issue((^Daemon)(data), PLUG_POOL_VERIFY, {{"token", token}, {"sign", r.sign[:]}, {"box", r.box[:]}}, done)
}

@(private)
_hp_pool_attest :: proc(data: rawptr, evidence: []u8, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	r := runner
	return _plug_issue((^Daemon)(data), PLUG_POOL_ATTEST, {{"evidence", evidence}, {"sign", r.sign[:]}, {"box", r.box[:]}}, done)
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
	if _host_owner(d, .Credentials) == nil {
		return {}, false
	}
	listed := false
	for x in d.hc.spaces {
		listed ||= x == space
	}
	if !listed {
		return {}, false
	}
	hcred, have := d.hc.creds[space]
	if !have {
		hcred = new(Host_Cred)
		hcred.d = d
		hcred.space = space
		d.hc.creds[space] = hcred
	}
	return osync.Credentials{data = hcred, produce = _hp_cred_sync, begin = _hp_cred_begin, cancel = _hp_cred_cancel}, true
}

@(private)
_hp_cred_sync :: proc(data: rawptr, binding: []u8, out_buf: ^[dynamic]u8) -> osync.Error {
	return .Unsupported
}

@(private)
_hp_cred_begin :: proc(data: rawptr, binding: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	hcred := (^Host_Cred)(data)
	return _plug_issue(hcred.d, PLUG_CRED_PRODUCE, {{"space", hcred.space}, {"binding", binding}}, done)
}

@(private)
_hp_cred_cancel :: proc(data: rawptr, done: osync.Plug_Done) {
	_hp_cancel((^Host_Cred)(data).d, done)
}

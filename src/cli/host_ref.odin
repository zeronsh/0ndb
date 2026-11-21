package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../capi/api"
import "../prim"
import osync "../sync"

Ref_Host :: struct {
	plugs:     []string,
	json:      bool,
	quiet:     bool,
	store:     osync.File_Sealed_Store,
	passkey:   osync.Soft_Passkey,
	secret:    [32]u8,
	pool_id:   osync.Identity,
	have_pool: bool,
	user_id:   osync.Identity,
	have_user: bool,
	cred_dir:  string,
	pool_sock: string,
}

cmd_host :: proc(a: ^Args) -> int {
	h := new(Ref_Host, context.allocator)
	home := home_dir(context.temp_allocator)
	store_dir := flag_string(a, "store", account_store_dir(home))
	if osync.file_sealed_store_init(&h.store, prim.os_vfs(), store_dir) != .None {
		return report_error(.Io, "cannot open the account store at %s", store_dir)
	}
	_ref_secret(h, store_dir)
	if len(a.pos) > 0 && a.pos[0] == "token" {
		fmt.println(_ref_token(h, POOL_TOKEN_TTL_MS))
		return 0
	}
	local, _ := prim.path_join(context.temp_allocator, home, "passkey")
	h.passkey = osync.Soft_Passkey {
		vfs    = prim.os_vfs(),
		local  = strings.clone(flag_string(a, "passkey", local)),
		remote = strings.clone(os.get_env("ONDB_PHONE_PASSKEY", context.temp_allocator)),
	}
	h.json = a.json
	h.quiet = flag_bool(a, "quiet")
	h.cred_dir = strings.clone(flag_string(a, "credentials-dir"))
	h.pool_sock = strings.clone(os.get_env("ONDB_POOL_HOST_SOCK", context.temp_allocator))
	if card := flag_string(a, "pool-card", os.get_env("ONDB_POOL_CARD", context.temp_allocator)); len(card) > 0 {
		raw, ok := hex_decode(card)
		if !ok {
			return usage_error("--pool-card takes a hex card")
		}
		id, err := osync.card_verify(raw)
		if err != .None {
			return usage_error("--pool-card is not a valid card")
		}
		h.user_id = id
		h.have_user = true
	}
	list := make([dynamic]string)
	for n in strings.split(flag_string(a, "plugs", "sealed_store,unlock"), ",", context.temp_allocator) {
		if x := strings.trim_space(n); len(x) > 0 {
			append(&list, strings.clone(x))
		}
	}
	h.plugs = list[:]
	backoff := i64(50)
	announced := false
	for {
		free_all(context.temp_allocator)
		c: Client
		if !client_connect(&c, false) {
			if !announced {
				fmt.eprintln("0ndb host: waiting for the daemon")
				announced = true
			}
			time.sleep(time.Duration(backoff) * time.Millisecond)
			backoff = min(backoff * 2, 2000)
			continue
		}
		backoff = 50
		announced = false
		code := _ref_session(h, &c, flag_bool(a, "replace"))
		client_close(&c)
		if code >= 0 {
			return code
		}
		fmt.eprintln("0ndb host: lost the daemon, reconnecting")
	}
}

@(private)
_ref_secret :: proc(h: ^Ref_Host, dir: string) {
	sp, _ := prim.path_join(context.temp_allocator, dir, "pool.secret")
	data, err := prim.read_file(prim.os_vfs(), sp, context.temp_allocator)
	if err == .None && len(data) == 32 {
		copy(h.secret[:], data)
		return
	}
	prim.random_fill({}, h.secret[:])
	prim.replace_atomic(prim.os_vfs(), sp, h.secret[:])
}

@(private)
_ref_token :: proc(h: ^Ref_Host, ttl_ms: i64) -> string {
	body: [8 + 16]u8
	prim.put_u64le(body[:8], u64(prim.now_ms() + ttl_ms))
	prim.random_fill({}, body[8:])
	mac := _pool_token_mac(&h.secret, body[:])
	out: [8 + 16 + 32]u8
	copy(out[:], body[:])
	copy(out[24:], mac[:])
	return hex_of(out[:])
}

@(private)
_ref_call :: proc(c: ^Client, req: []u8, json_form: bool) -> (st: api.Status, payload: []u8, ok: bool) {
	c.tag += 1
	tag := u64_bytes(c.tag)
	flags := [1]u8{1 if json_form else 0}
	to: [8]u8
	if !client_send(c, .Call, tag[:], flags[:], to[:], req) {
		return
	}
	for {
		k, p, rok := client_read(c)
		if !rok {
			return
		}
		if k == .Result && len(p) >= 9 && prim.get_u64le(p[:8]) == c.tag {
			return api.Status(p[8]), p[9:], true
		}
	}
}

@(private)
_ref_session :: proc(h: ^Ref_Host, c: ^Client, replace: bool) -> int {
	for p in h.plugs {
		if p == "runner_pool" && !h.have_pool {
			st, payload, ok := _ref_call(c, transmute([]u8)string(`{"op":"identity"}`), true)
			if !ok {
				return -1
			}
			v, _ := json.parse(payload, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
			sign, sok := hex_decode(jstr(v, "sign"))
			box, bok := hex_decode(jstr(v, "box"))
			if st != .Ok || !sok || !bok || len(sign) != 32 || len(box) != 32 {
				return report_error(st, "cannot read the daemon identity for the runner pool")
			}
			s, b: osync.Public_Key
			copy(s[:], sign)
			copy(b[:], box)
			h.pool_id = osync.identity_of(s, b)
			h.have_pool = true
		}
	}
	buf := make([dynamic]u8, context.temp_allocator)
	o: api.Out
	api.out_init(&o, &buf, h.json)
	if h.json {
		api.o_str(&o, "op", "host.register")
	} else {
		prim.write_u8(&o.w, api.VERSION)
		prim.write_uvarint(&o.w, HOST_REGISTER_CODE)
	}
	api.o_arr(&o, "plugs", len(h.plugs))
	for p in h.plugs {
		api.o_str(&o, "", p)
	}
	api.o_end(&o)
	api.o_bool(&o, "replace", replace)
	st, _, ok := _ref_call(c, api.out_finish(&o), h.json)
	if !ok {
		return -1
	}
	if st != .Ok {
		return report_error(st, "the daemon refused the host registration (start it with --host-plugs %s)", strings.join(h.plugs, ",", context.temp_allocator))
	}
	fmt.eprintfln("0ndb host: serving %s (%s form)", strings.join(h.plugs, ",", context.temp_allocator), "json" if h.json else "binary")
	for {
		free_all(context.temp_allocator)
		k, p, rok := client_read(c)
		if !rok {
			return -1
		}
		#partial switch k {
		case .Plug:
			if len(p) < 8 {
				return -1
			}
			tag := prim.get_u64le(p[:8])
			reply := make([dynamic]u8, context.temp_allocator)
			rst := _ref_handle(h, p[8:], &reply)
			if tag == 0 {
				continue
			}
			t := u64_bytes(tag)
			s := [1]u8{u8(rst)}
			if !client_send(c, .Plug_Reply, t[:], s[:], reply[:]) {
				return -1
			}
		case .Plug_Cancel:
			if len(p) >= 8 && !h.quiet {
				fmt.eprintfln("0ndb host: request %d cancelled by the daemon", prim.get_u64le(p[:8]))
			}
		}
	}
}

@(private)
_ref_err :: proc(err: osync.Error) -> api.Status {
	#partial switch err {
	case .None:
		return .Ok
	case .Not_Found:
		return .Not_Found
	case .Conflict:
		return .Conflict
	case .Permission, .Auth:
		return .Permission
	case .Unsupported:
		return .Unsupported
	case .Invalid, .Corrupt:
		return .Invalid
	case .Too_Large:
		return .Too_Large
	}
	return .Io
}

@(private)
_ref_raw :: proc(c: ^api.Call, s: string) -> []u8 {
	if !c.json {
		return transmute([]u8)s
	}
	b, _ := hex_decode(s)
	return b
}

@(private)
_ref_handle :: proc(h: ^Ref_Host, body: []u8, reply: ^[dynamic]u8) -> api.Status {
	req: api.Call
	req.json = h.json
	fn: ^Plug_Fn
	if h.json {
		root, err := json.parse(body, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		ob, ok := root.(json.Object)
		if err != .None || !ok {
			return .Bad_Request
		}
		name, _ := ob["plug"].(json.String)
		for &f in PLUG_FNS {
			if f.name == string(name) {
				fn = &f
			}
		}
		if fn == nil {
			return .Unsupported
		}
		req.op = new_clone(api.Op{fn.code, fn.name, fn.request, "", nil}, context.temp_allocator)
		if !api.decode_json(req.op, ob, &req.args, context.temp_allocator) {
			return .Bad_Request
		}
	} else {
		r := prim.reader(body)
		if prim.read_u8(&r) != PLUG_VERSION {
			return .Bad_Request
		}
		fn = _plug_fn(u16(prim.read_uvarint(&r)))
		if fn == nil {
			return .Unsupported
		}
		req.op = new_clone(api.Op{fn.code, fn.name, fn.request, "", nil}, context.temp_allocator)
		if !api.decode_binary(req.op, &r, &req.args, context.temp_allocator) {
			return .Bad_Request
		}
	}
	if !h.quiet {
		fmt.eprintfln("0ndb host: %s", fn.name)
	}
	o: api.Out
	api.out_init(&o, reply, h.json)
	st := _ref_run(h, fn, &req, &o)
	if st == .Ok {
		api.out_finish(&o)
	} else {
		clear(reply)
	}
	return st
}

@(private)
_ref_run :: proc(h: ^Ref_Host, fn: ^Plug_Fn, req: ^api.Call, o: ^api.Out) -> api.Status {
	store := osync.file_sealed_store(&h.store)
	unlock := osync.soft_passkey(&h.passkey)
	switch fn.code {
	case PLUG_STORE_GET:
		rec := make([dynamic]u8, context.temp_allocator)
		entries := make([dynamic][]u8, context.temp_allocator)
		if err := store.get(store.data, api.a_bytes(req, "subject"), &rec, &entries); err != .None {
			return _ref_err(err)
		}
		api.o_bytes(o, "record", rec[:])
		api.o_arr(o, "entries", len(entries))
		for e in entries {
			api.o_bytes(o, "", e)
		}
		api.o_end(o)
	case PLUG_STORE_PUT:
		return _ref_err(store.put(store.data, api.a_bytes(req, "subject"), api.a_bytes(req, "record"), api.a_u64(req, "prev_seq")))
	case PLUG_STORE_ADD:
		return _ref_err(store.add(store.data, api.a_bytes(req, "subject"), api.a_bytes(req, "entry")))
	case PLUG_UNLOCK:
		creds := api.a_strs(req, "credentials")
		salts := api.a_strs(req, "salts")
		if len(creds) != len(salts) {
			return .Bad_Request
		}
		opts := make([]osync.Unlock_Option, len(creds), context.temp_allocator)
		for i in 0 ..< len(creds) {
			opts[i].credential = _ref_raw(req, creds[i])
			s := _ref_raw(req, salts[i])
			if len(s) != 32 {
				return .Bad_Request
			}
			copy(opts[i].salt[:], s)
		}
		cred := make([dynamic]u8, context.temp_allocator)
		prf: [32]u8
		if err := unlock.unlock(unlock.data, api.a_bytes(req, "rp_user"), opts, osync.Unlock_Mode(api.a_int(req, "mode")), &cred, &prf); err != .None {
			return _ref_err(err)
		}
		api.o_bytes(o, "credential", cred[:])
		api.o_bytes(o, "prf", prf[:])
	case PLUG_REGISTER:
		s := api.a_bytes(req, "salt")
		if len(s) != 32 {
			return .Bad_Request
		}
		salt: [32]u8
		copy(salt[:], s)
		cred := make([dynamic]u8, context.temp_allocator)
		prf: [32]u8
		eco: osync.Ecosystem
		if err := unlock.register(unlock.data, api.a_bytes(req, "rp_user"), api.a_str(req, "label"), salt, &cred, &prf, &eco); err != .None {
			return _ref_err(err)
		}
		api.o_bytes(o, "credential", cred[:])
		api.o_bytes(o, "prf", prf[:])
		api.o_enum(o, "ecosystem", u64(eco), ECOSYSTEM_NAMES)
	case PLUG_POOL_IDENTITY:
		if !h.have_pool {
			return .Unsupported
		}
		api.o_bytes(o, "sign", h.pool_id.sign[:])
		api.o_bytes(o, "box", h.pool_id.box[:])
	case PLUG_POOL_VERIFY:
		raw, ok := hex_decode(string(api.a_bytes(req, "token")))
		if !ok || len(raw) != 56 {
			return .Permission
		}
		mac := _pool_token_mac(&h.secret, raw[:24])
		diff: u8
		for i in 0 ..< 32 {
			diff |= mac[i] ~ raw[24 + i]
		}
		if diff != 0 || i64(prim.get_u64le(raw[:8])) < prim.now_ms() {
			return .Permission
		}
		api.o_u64(o, "lease_ms", POOL_LEASE_MS)
	case PLUG_POOL_ATTEST:
	case PLUG_USER_IDENTITY:
		if !h.have_user {
			return .Unsupported
		}
		api.o_bytes(o, "sign", h.user_id.sign[:])
		api.o_bytes(o, "box", h.user_id.box[:])
	case PLUG_USER_JOINED:
		sp := api.a_id(req, "space")
		fmt.eprintfln("0ndb host: the runner pool was added to space %s", hex(sp))
		if len(h.pool_sock) > 0 {
			r := req_begin("space.join_enrollment")
			req_str(&r, "space", hex(sp))
			req_str(&r, "proof", hex_of(api.a_bytes(req, "proof")))
			req_str(&r, "name", api.a_str(req, "name"))
			req_str(&r, "relay", api.a_str(req, "relay"))
			req_str(&r, "relay_key", hex_of(api.a_bytes(req, "relay_key")))
			call_at(h.pool_sock, req_end(&r), 5000)
		}
	case PLUG_CRED_AVAILABLE:
		_, ok := _ref_cred(h, api.a_id(req, "space"))
		api.o_bool(o, "available", ok)
	case PLUG_CRED_PRODUCE:
		cred, ok := _ref_cred(h, api.a_id(req, "space"))
		if !ok {
			return .Not_Found
		}
		api.o_bytes(o, "credential", cred)
	case:
		return .Unsupported
	}
	return .Ok
}

@(private)
_ref_cred :: proc(h: ^Ref_Host, space: prim.Id) -> ([]u8, bool) {
	if len(h.cred_dir) == 0 {
		return nil, false
	}
	p, _ := prim.path_join(context.temp_allocator, h.cred_dir, hex(space))
	data, err := prim.read_file(prim.os_vfs(), p, context.temp_allocator)
	return data, err == .None && len(data) > 0
}

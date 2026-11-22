package main

import "core:crypto/blake2b"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../capi/api"
import eng "../engine"
import "../keystore"
import "../prim"
import rt "../runtime"
import osync "../sync"

POOL_LEASE_MS :: u64(15 * 60 * 1000)
POOL_TOKEN_TTL_MS :: i64(10 * 60 * 1000)

Acct :: struct {
	store:     osync.File_Sealed_Store,
	passkey:   osync.Soft_Passkey,
	pool_host: bool,
	pool_card: [osync.CARD_LEN]u8,
	have_card: bool,
	host_sock: string,
	secret:    [32]u8,
	d:         ^Daemon,
	renew_timer: prim.Timer,
}

account_store_dir :: proc(home: string) -> string {
	if v := os.get_env("ONDB_ACCOUNT_STORE", context.temp_allocator); len(v) > 0 {
		return v
	}
	p, _ := prim.path_join(context.temp_allocator, prim.dir_name(home), "0ndb-account-store")
	return p
}

acct_setup :: proc(d: ^Daemon, ec: ^eng.Config, args: ^Args) -> bool {
	a := new(Acct)
	a.d = d
	d.acct = a
	if osync.file_sealed_store_init(&a.store, prim.os_vfs(), account_store_dir(d.home)) != .None {
		return false
	}
	local, _ := prim.path_join(context.temp_allocator, d.home, "passkey")
	a.passkey = osync.Soft_Passkey {
		vfs    = prim.os_vfs(),
		local  = strings.clone(local),
		remote = strings.clone(os.get_env("ONDB_PHONE_PASSKEY", context.temp_allocator)),
	}
	ec.sealed_store = osync.file_sealed_store(&a.store)
	if g, ok := guard_open(); ok {
		ec.seed_guard = g
	}
	ec.unlock = osync.soft_passkey(&a.passkey)
	ec.approver = true
	a.pool_host = flag_bool(args, "pool-host")
	a.host_sock = strings.clone(os.get_env("ONDB_POOL_HOST_SOCK", context.temp_allocator))
	if a.pool_host {
		sp, _ := prim.path_join(context.temp_allocator, d.home, "pool.secret")
		data, err := prim.read_file(prim.os_vfs(), sp, context.temp_allocator)
		if err == .None && len(data) == 32 {
			copy(a.secret[:], data)
		} else {
			prim.random_fill({}, a.secret[:])
			prim.replace_atomic(prim.os_vfs(), sp, a.secret[:])
		}
		ec.runner_pool = eng.Runner_Pool{data = a, identity = _pool_host_identity, verify = _pool_host_verify, renew = _pool_host_renew}
	} else if card := os.get_env("ONDB_POOL_CARD", context.temp_allocator); len(card) > 0 {
		raw, ok := hex_decode(card)
		if ok && len(raw) == osync.CARD_LEN {
			if _, cerr := osync.card_verify(raw); cerr == .None {
				copy(a.pool_card[:], raw)
				a.have_card = true
				ec.runner_pool = eng.Runner_Pool{data = a, identity = _pool_user_identity, joined = _pool_user_joined}
			}
		}
	}
	return true
}

acct_started :: proc(d: ^Daemon, args: ^Args) {
	a := d.acct
	e := &d.s.e
	if a.pool_host {
		card, err := osync.keyring_card(&e.keyring)
		if err == .None {
			p, _ := prim.path_join(context.temp_allocator, d.home, "pool.card")
			prim.replace_atomic(prim.os_vfs(), p, transmute([]u8)hex_of(card[:]))
		}
	}
	if eng.account_state(e).have {
		eng.account_listen(e)
	}
	if token, ok := flag_value(args, "pool-token"); ok {
		_runner_enroll(d, token)
	}
}

@(private)
_pool_host_identity :: proc(data: rawptr) -> osync.Identity {
	a := (^Acct)(data)
	return eng.identity(&a.d.s.e)
}

@(private)
_pool_token_mac :: proc(secret: ^[32]u8, body: []u8) -> (mac: [32]u8) {
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, secret[:], 32)
	blake2b.update(&ctx, transmute([]u8)string("0ndb pool token"))
	blake2b.update(&ctx, body)
	blake2b.final(&ctx, mac[:])
	return
}

pool_token_make :: proc(a: ^Acct, ttl_ms: i64) -> string {
	body: [8 + 16]u8
	prim.put_u64le(body[:8], u64(prim.now_ms() + ttl_ms))
	prim.random_fill({}, body[8:])
	mac := _pool_token_mac(&a.secret, body[:])
	out: [8 + 16 + 32]u8
	copy(out[:], body[:])
	copy(out[24:], mac[:])
	return hex_of(out[:])
}

@(private)
_pool_host_verify :: proc(data: rawptr, token: []u8, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	a := (^Acct)(data)
	raw, ok := hex_decode(string(token))
	if !ok || len(raw) != 56 {
		return .Auth
	}
	mac := _pool_token_mac(&a.secret, raw[:24])
	diff: u8
	for i in 0 ..< 32 {
		diff |= mac[i] ~ raw[24 + i]
	}
	if diff != 0 || i64(prim.get_u64le(raw[:8])) < prim.now_ms() {
		return .Auth
	}
	reply.lease_ms = POOL_LEASE_MS
	return .None
}

@(private)
_pool_host_renew :: proc(data: rawptr, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	reply.lease_ms = POOL_LEASE_MS
	return .None
}

runner_lease_lapsed :: proc(d: ^Daemon) {
	if len(d.acct.host_sock) == 0 || d.acct.renew_timer != 0 {
		return
	}
	d.acct.renew_timer = prim.timer(&d.s.loop, 0, d, _runner_renew)
}

@(private)
_runner_renew :: proc(l: ^prim.Loop, data: rawptr) {
	d := (^Daemon)(data)
	d.acct.renew_timer = 0
	req, err := eng.runner_renewal_request(&d.s.e, context.temp_allocator)
	if err != .None {
		return
	}
	r := req_begin("pool.renew")
	req_str(&r, "request", hex_of(req))
	rep, ok := call_at(d.acct.host_sock, req_end(&r), 10000)
	if !ok || rep.status != .Ok {
		fmt.eprintfln("0ndb runner: the pool did not renew the lease (%s)", api.STATUS_NAMES[int(rep.status)])
		return
	}
	en, hok := hex_decode(jstr(rep.value, "renewal"))
	if !hok {
		return
	}
	n, rerr := eng.runner_renew(&d.s.e, en)
	if rerr != .None {
		fmt.eprintfln("0ndb runner: cannot apply the lease renewal (%v)", rerr)
		return
	}
	fmt.eprintfln("0ndb runner: the pool renewed the lease in %d spaces", n)
}

@(private)
_pool_user_identity :: proc(data: rawptr) -> osync.Identity {
	a := (^Acct)(data)
	id, _ := osync.card_verify(a.pool_card[:])
	return id
}

@(private)
_pool_user_joined :: proc(data: rawptr, space: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, proof: []u8) {
	a := (^Acct)(data)
	if len(a.host_sock) == 0 {
		return
	}
	r := req_begin("space.join_enrollment")
	req_str(&r, "space", hex(space))
	req_str(&r, "proof", hex_of(proof))
	req_str(&r, "name", name)
	req_str(&r, "relay", relay)
	rp := relay_public
	req_str(&r, "relay_key", hex_of(rp[:]))
	call_at(a.host_sock, req_end(&r), 5000)
}

@(private)
_runner_enroll :: proc(d: ^Daemon, token: string) {
	a := d.acct
	if len(a.host_sock) == 0 {
		fmt.eprintln("0ndb runner: set ONDB_POOL_HOST_SOCK to the pool host's daemon socket")
		return
	}
	card, err := osync.keyring_card(&d.s.e.keyring)
	if err != .None {
		return
	}
	r := req_begin("pool.enroll")
	req_str(&r, "token", hex_of(transmute([]u8)token))
	req_str(&r, "card", hex_of(card[:]))
	rep, ok := call_at(a.host_sock, req_end(&r), 10000)
	if !ok || rep.status != .Ok {
		fmt.eprintfln("0ndb runner: pool enrollment refused (%s)", api.STATUS_NAMES[int(rep.status)])
		return
	}
	en, hok := hex_decode(jstr(rep.value, "enrollment"))
	if !hok {
		return
	}
	n, eerr := eng.runner_enroll(&d.s.e, en)
	if eerr != .None {
		fmt.eprintfln("0ndb runner: cannot apply the enrollment (%v)", eerr)
		return
	}
	for sp in eng.space_list(&d.s.e, context.temp_allocator) {
		attach_space(d, sp.id)
	}
	fmt.eprintfln("0ndb runner: enrolled into %d spaces through the pool", n)
}

call_at :: proc(path: string, req: string, timeout_ms: i64) -> (r: Reply, ok: bool) {
	fd, cok := sock_connect(path)
	if !cok {
		return r, false
	}
	c := Client{fd = fd, rbuf = make([dynamic]u8, context.temp_allocator)}
	defer sock_close(fd)
	hello: [5]u8
	copy(hello[:4], MAGIC)
	hello[4] = PROTO_VERSION
	if !_write_all(fd, hello[:]) {
		return r, false
	}
	tag := u64_bytes(1)
	flags := [1]u8{1}
	to: [8]u8
	prim.put_u64le(to[:], u64(timeout_ms))
	if !client_send(&c, .Call, tag[:], flags[:], to[:], transmute([]u8)req) {
		return r, false
	}
	for {
		k, p, rok := client_read(&c, timeout_ms)
		if !rok {
			return r, false
		}
		if k != .Result || len(p) < 9 || prim.get_u64le(p[:8]) != 1 {
			continue
		}
		r.status = api.Status(p[8])
		r.payload = string(p[9:])
		if v, err := json.parse(p[9:], json.DEFAULT_SPECIFICATION, true, context.temp_allocator); err == .None {
			r.value = v
		}
		return r, true
	}
}

op_pool_token :: proc(c: ^api.Call, o: ^api.Out) -> api.Status {
	d := _host(c)
	if d.acct == nil || !d.acct.pool_host {
		return .Permission
	}
	api.o_str(o, "token", pool_token_make(d.acct, POOL_TOKEN_TTL_MS))
	return .Ok
}

account_subject :: proc(a: ^Args) -> string {
	if v, ok := flag_value(a, "subject"); ok {
		return v
	}
	if v := os.get_env("ONDB_SUBJECT", context.temp_allocator); len(v) > 0 {
		return v
	}
	return os.get_env("USER", context.temp_allocator)
}

cmd_login :: proc(a: ^Args) -> int {
	s := session(a)
	subject := account_subject(a)
	if len(subject) == 0 {
		return usage_error("usage: 0ndb login [--subject ID] (or set ONDB_SUBJECT)")
	}
	r: Request
	if key, ok := flag_value(a, "recovery"); ok {
		r = req_begin("account.login_recovery")
		req_str(&r, "subject", subject)
		req_str(&r, "key", key)
	} else if flag_bool(a, "cross-device") {
		r = req_begin("account.login_cross_device")
		req_str(&r, "subject", subject)
	} else {
		r = req_begin("account.login")
		req_str(&r, "subject", subject)
		req_str(&r, "label", flag_string(a, "label", "0ndb cli"))
		req_opt(&r, "relay", flag_string(a, "relay"))
		req_opt(&r, "relay_key", flag_string(a, "relay-key"))
	}
	v := must(s, req_end(&r), "cannot sign in")
	if jstr(v, "status") == "waiting" {
		code := jstr(v, "code")
		fmt.printfln("Approve this device on any signed-in device: 0ndb approve %s-%s", code[:4], code[4:])
		os.flush(os.stdout)
		deadline := prim.now_ms() + i64(flag_int(a, "wait", 120)) * 1000
		for prim.now_ms() < deadline {
			st := must(s, `{"op":"account.state"}`)
			if !jbool(st, "waiting") {
				if jbool(st, "signed_in") {
					fmt.println("signed in through another device")
					_login_finish(s, a)
					return 0
				}
				return report_error(.Permission, "the approval was denied")
			}
			if jbool(st, "no_approver") {
				fmt.println("no signed-in device is online; using a passkey from another device")
				cr := req_begin("account.login_cross_device")
				req_str(&cr, "subject", subject)
				rep := call(s, req_end(&cr))
				if rep.status == .Ok {
					fmt.println("signed in with a passkey from another device")
					_login_finish(s, a)
					return 0
				}
				return report_error(rep.status, "no approver online and no cross-device passkey available")
			}
			time.sleep(200 * time.Millisecond)
		}
		return report_error(.Timeout, "no approval arrived")
	}
	if a.json {
		print_json(v)
	} else {
		fmt.printfln("signed in (%s, %d spaces)", jstr(v, "path"), jint(v, "spaces"))
	}
	_login_finish(s, a)
	return 0
}

@(private)
_login_finish :: proc(s: ^Session, a: ^Args) {
	st := must(s, `{"op":"state.get"}`)
	if len(jstr(st, "default_space")) > 0 {
		return
	}
	sp := must(s, `{"op":"space.list"}`)
	list := jarr(sp, "spaces")
	if len(list) > 0 {
		sr := req_begin("state.set")
		req_str(&sr, "default_space", jstr(list[0], "id"))
		must(s, req_end(&sr))
	}
}

cmd_approve :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) == 0 {
		v := must(s, `{"op":"approval.list"}`)
		list := jarr(v, "approvals")
		if len(list) == 0 {
			fmt.println("no devices are waiting for approval")
			return 0
		}
		for x in list {
			code := jstr(x, "code")
			fmt.printfln("%s-%s  %s  device %s", code[:4], code[4:], jstr(x, "label"), short(jstr(x, "device")))
		}
		return 0
	}
	r := req_begin("approval.respond")
	req_str(&r, "code", a.pos[0])
	req_bool(&r, "approve", !flag_bool(a, "deny"))
	must(s, req_end(&r), "cannot answer that approval")
	fmt.println("denied" if flag_bool(a, "deny") else "approved")
	return 0
}

cmd_devices :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) >= 2 && a.pos[0] == "remove" {
		r := req_begin("device.remove")
		req_str(&r, "device", resolve_device(s, a.pos[1]))
		v := must(s, req_end(&r), "cannot remove that device")
		fmt.printfln("removed from %d spaces; a new key epoch excludes it", jint(v, "spaces"))
		return 0
	}
	if len(a.pos) >= 2 && a.pos[0] == "forget-passkey" {
		r := req_begin("account.passkey_remove")
		req_str(&r, "credential", a.pos[1])
		must(s, req_end(&r), "cannot remove that passkey")
		fmt.println("passkey removed")
		return 0
	}
	v := must(s, `{"op":"account.devices"}`)
	if a.json {
		print_json(v)
		return 0
	}
	for x in jarr(v, "devices") {
		mark := " (this device)" if jbool(x, "self") else ""
		state := "removed" if jbool(x, "removed") else "active"
		fmt.printfln("%s  %-7s %-8s via %-9s %d spaces%s", short(jstr(x, "device")), jstr(x, "kind"), state, jstr(x, "method"), jint(x, "spaces"), mark)
	}
	pk := call(s, `{"op":"account.passkeys"}`)
	if pk.status == .Ok {
		for x in jarr(pk.value, "passkeys") {
			fmt.printfln("passkey %s  %s  %s", short(jstr(x, "credential")), jstr(x, "ecosystem"), jstr(x, "label"))
		}
	}
	return 0
}

resolve_device :: proc(s: ^Session, prefix: string) -> string {
	v := must(s, `{"op":"account.devices"}`)
	for x in jarr(v, "devices") {
		id := jstr(x, "device")
		if strings.has_prefix(id, prefix) || strings.has_suffix(id, prefix) {
			return id
		}
	}
	return prefix
}

cmd_members :: proc(a: ^Args) -> int {
	s := session(a)
	space := default_space(s, false)
	r := req_begin("space.members")
	req_str(&r, "space", hex(space))
	v := must(s, req_end(&r), "cannot list members")
	sr := req_begin("space.members_status")
	req_str(&sr, "space", hex(space))
	st := must(s, req_end(&sr), "cannot read the membership state")
	if a.json {
		print_json(v)
		return 0
	}
	fmt.printfln("epoch %d%s · %d members · %d records", jint(st, "epoch"), "" if jbool(st, "eligible") else " (rotation pending)", jint(st, "members"), jint(st, "records"))
	for x in jarr(v, "members") {
		mark := " (this device)" if jbool(x, "self") else ""
		state := "removed" if jbool(x, "removed") else ("in epoch" if jbool(x, "in_epoch") else "active")
		fmt.printfln("%s  %-8s %-6s %-8s via %-9s by %s%s", short(jstr(x, "device")), jstr(x, "kind"), jstr(x, "role"), state, jstr(x, "method"), short(jstr(x, "added_by")), mark)
	}
	return 0
}

cmd_remove :: proc(a: ^Args) -> int {
	if len(a.pos) != 1 {
		return usage_error("usage: 0ndb remove DEVICE [--space SPACE]")
	}
	s := session(a)
	if _, ok := flag_value(a, "space"); ok {
		space := default_space(s, false)
		r := req_begin("member.remove")
		req_str(&r, "space", hex(space))
		req_str(&r, "device", resolve_device(s, a.pos[0]))
		must(s, req_end(&r), "cannot remove that member")
		fmt.println("removed; a new key epoch excludes it")
		return 0
	}
	r := req_begin("device.remove")
	req_str(&r, "device", resolve_device(s, a.pos[0]))
	v := must(s, req_end(&r), "cannot remove that device")
	fmt.printfln("removed from %d spaces; a new key epoch excludes it", jint(v, "spaces"))
	return 0
}

cmd_rotate :: proc(a: ^Args) -> int {
	s := session(a)
	space := default_space(s, false)
	r := req_begin("space.rotate")
	req_str(&r, "space", hex(space))
	must(s, req_end(&r), "cannot rotate")
	fmt.println("started a new key epoch")
	return 0
}

cmd_recovery_key :: proc(a: ^Args) -> int {
	s := session(a)
	v := must(s, `{"op":"account.recovery_key"}`, "cannot create a recovery key")
	fmt.println(jstr(v, "key"))
	fmt.println("Keep this key offline. With it, 0ndb login --recovery KEY signs in a new device with no other device online.")
	return 0
}

cmd_pool :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) >= 1 && a.pos[0] == "token" {
		v := must(s, `{"op":"pool.token"}`, "this daemon is not a pool host (start it with --pool-host)")
		fmt.println(jstr(v, "token"))
		return 0
	}
	if len(a.pos) >= 1 && (a.pos[0] == "on" || a.pos[0] == "off") {
		space := default_space(s, false)
		r := req_begin("space.pool")
		req_str(&r, "space", hex(space))
		req_bool(&r, "on", a.pos[0] == "on")
		must(s, req_end(&r), "cannot change cloud runner access")
		fmt.printfln("cloud runners %s for this space", "included" if a.pos[0] == "on" else "removed; a new key epoch excludes them")
		return 0
	}
	return usage_error("usage: 0ndb pool token | on | off")
}

cmd_pair :: proc(a: ^Args) -> int {
	if len(a.pos) != 1 {
		return usage_error("usage: 0ndb pair DEVICE-CODE (from 0ndb join on the new device)")
	}
	s := session(a)
	space := default_space(s, true)
	if relay, has := flag_value(a, "relay"); has {
		r := req_begin("space.set_relay")
		req_str(&r, "space", hex(space))
		req_str(&r, "relay", relay)
		req_opt(&r, "relay_key", flag_string(a, "relay-key"))
		must(s, req_end(&r), "cannot set the relay")
	}
	card, ok := hex_decode(strings.trim_space(a.pos[0]))
	if !ok {
		return usage_error("that is not a device code")
	}
	r := req_begin("member.add")
	req_str(&r, "space", hex(space))
	req_str(&r, "card", hex_of(card))
	req_str(&r, "role", "admin")
	v := must(s, req_end(&r), "cannot add that device")
	relay, relay_key := "", ""
	for sp in jarr(must(s, `{"op":"space.list"}`, "cannot list spaces"), "spaces") {
		if jstr(sp, "id") == hex(space) {
			relay = jstr(sp, "relay")
			relay_key = jstr(sp, "relay_key")
		}
	}
	ticket := fmt.tprintf("%s.%s.%s.%s", hex(space), hex_of(transmute([]u8)relay), relay_key, jstr(v, "proof"))
	fmt.println(ticket)
	return 0
}

cmd_join :: proc(a: ^Args) -> int {
	s := session(a)
	if len(a.pos) == 0 {
		v := must(s, `{"op":"card"}`)
		fmt.println(jstr(v, "card"))
		return 0
	}
	parts := strings.split(strings.trim_space(a.pos[0]), ".", context.temp_allocator)
	if len(parts) != 4 {
		return usage_error("usage: 0ndb join [TICKET]")
	}
	relay, rok := hex_decode(parts[1])
	if !rok {
		return usage_error("that ticket is damaged")
	}
	r := req_begin("space.join_enrollment")
	req_str(&r, "space", parts[0])
	req_str(&r, "proof", parts[3])
	req_str(&r, "relay", string(relay))
	req_opt(&r, "relay_key", parts[2])
	req_opt(&r, "name", flag_string(a, "name"))
	v := must(s, req_end(&r), "cannot join")
	st := must(s, `{"op":"state.get"}`)
	if len(jstr(st, "default_space")) == 0 {
		sr := req_begin("state.set")
		req_str(&sr, "default_space", jstr(v, "space"))
		must(s, req_end(&sr))
	}
	fmt.printfln("joined space %s", short(jstr(v, "space")))
	return 0
}

hex_decode :: proc(s: string) -> ([]u8, bool) {
	if len(s) % 2 != 0 {
		return nil, false
	}
	out := make([]u8, len(s) / 2, context.temp_allocator)
	if !prim.hex_decode(out, transmute([]u8)s) {
		return nil, false
	}
	return out, true
}

flag_int :: proc(a: ^Args, name: string, default_value: int) -> int {
	v, ok := flag_value(a, name)
	if !ok {
		return default_value
	}
	n := 0
	for c in v {
		if c < '0' || c > '9' {
			return default_value
		}
		n = n * 10 + int(c - '0')
	}
	return n
}

attach_space :: proc(d: ^Daemon, id: prim.Id) {
	rt.attach(&d.s.r, id)
}

Guard :: struct {
	ks: keystore.Keystore,
}

guard_open :: proc() -> (osync.Seed_Guard, bool) {
	if os.get_env("ONDB_KEYSTORE", context.temp_allocator) == "file" {
		return {}, false
	}
	g := new(Guard)
	ks, err := keystore.open_default()
	if err != .None {
		free(g)
		return {}, false
	}
	g.ks = ks
	return osync.Seed_Guard{data = g, seal = _guard_seal, unseal = _guard_unseal}, true
}

@(private)
_guard_seal :: proc(data: rawptr, secret: []u8, out: ^[dynamic]u8) -> osync.Error {
	g := (^Guard)(data)
	return .None if keystore.seal(g.ks, "device", secret, out) == .None else .Io
}

@(private)
_guard_unseal :: proc(data: rawptr, sealed: []u8, out: []u8) -> osync.Error {
	g := (^Guard)(data)
	if kind, kerr := keystore.sealed_kind(sealed); kerr == .None && kind != g.ks.kind {
		if other, oerr := keystore.open(kind); oerr == .None {
			g.ks = other
		}
	}
	switch keystore.unseal(g.ks, "device", sealed, out) {
	case .None:
		return .None
	case .Denied:
		return .Permission
	case .Corrupt:
		return .Corrupt
	case .Invalid, .Not_Found, .Unavailable, .Io, .No_Memory:
	}
	return .Io
}

cmd_logout :: proc(a: ^Args) -> int {
	s := session(a)
	r := req_begin("account.sign_out")
	req_bool(&r, "keep_relay", flag_bool(a, "keep-relay"))
	v := must(s, req_end(&r), "cannot sign out")
	fmt.printfln("signed out; %d spaces keep working on this device (local only)", jint(v, "spaces"))
	return 0
}

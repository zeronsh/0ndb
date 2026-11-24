package sim

import "core:crypto/blake2b"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:testing"
import "../../src/convo"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

M_A :: 0
M_B :: 1
M_C :: 2
M_POOL :: 3
M_RUNNER :: 4
M_D :: 5
M_THIEF :: 6
M_X :: 7
M_DIR :: 8
M_NODES :: 9
M_SUBJECT :: "user@sim"
M_LEASE_MS :: u64(10 * 60 * 1000)

Mem_World :: struct {
	w:          ^World,
	creds:      map[int][48]u8,
	phone:      [48]u8,
	have_phone: bool,
	to_phone:   bool,
	record:     [dynamic]u8,
	entries:    [dynamic][]u8,
	plugs:      [M_NODES]Mem_Plug,
	pool_inbox: [dynamic]Pool_Note,
	token_ok:   i64,
	rng:        Rng,
}

Mem_Plug :: struct {
	mw:  ^Mem_World,
	idx: int,
}

Pool_Note :: struct {
	space: prim.Id,
	proof: []u8,
}

Mem_Result :: struct {
	seed:     u64,
	failures: [dynamic]string,
	notes:    [dynamic]string,
}

@(private = "file")
_mw: ^Mem_World

@(private = "file")
_prf :: proc(seed: []u8, salt: [32]u8, out: ^[32]u8) {
	s := salt
	ctx: blake2b.Context
	blake2b.init_mac(&ctx, seed, 32)
	blake2b.update(&ctx, s[:])
	blake2b.final(&ctx, out[:])
}

@(private = "file")
_unlock :: proc(data: rawptr, rp_user: []u8, options: []osync.Unlock_Option, mode: osync.Unlock_Mode, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Mem_Plug)(data)
	mw := p.mw
	key: [48]u8
	if mode == .Local {
		k, ok := mw.creds[p.idx]
		if !ok {
			return .Not_Found
		}
		key = k
	} else {
		if !mw.have_phone {
			return .Not_Found
		}
		key = mw.phone
	}
	for o in options {
		if string(o.credential) == string(key[:16]) {
			_prf(key[16:], o.salt, &reply.prf)
			c := make([]u8, 16, context.temp_allocator)
			copy(c, key[:16])
			reply.credential = c
			return .None
		}
	}
	return .Not_Found
}

@(private = "file")
_register :: proc(data: rawptr, rp_user: []u8, label: string, salt: [32]u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	p := (^Mem_Plug)(data)
	mw := p.mw
	key: [48]u8
	if mw.to_phone {
		if !mw.have_phone {
			rng_fill(&mw.rng, mw.phone[:])
			mw.have_phone = true
		}
		key = mw.phone
	} else {
		k, ok := mw.creds[p.idx]
		if !ok {
			rng_fill(&mw.rng, k[:])
			mw.creds[p.idx] = k
		}
		key = k
	}
	_prf(key[16:], salt, &reply.prf)
	c := make([]u8, 16, context.temp_allocator)
	copy(c, key[:16])
	reply.credential = c
	reply.ecosystem = .Test
	return .None
}

@(private = "file")
_store_get :: proc(data: rawptr, subject: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	mw := (^Mem_Plug)(data).mw
	if len(mw.record) == 0 {
		return .Not_Found
	}
	reply.record = mw.record[:]
	reply.entries = mw.entries[:]
	return .None
}

@(private = "file")
_store_put :: proc(data: rawptr, subject: []u8, record: []u8, prev: u64, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	mw := (^Mem_Plug)(data).mw
	if len(mw.record) > 0 {
		cur: osync.Account_Record
		if osync.account_record_decode(mw.record[:], &cur, context.temp_allocator) == .None && cur.seq != prev {
			return .Conflict
		}
	}
	clear(&mw.record)
	append(&mw.record, ..record)
	return .None
}

@(private = "file")
_store_add :: proc(data: rawptr, subject: []u8, entry: []u8, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	mw := (^Mem_Plug)(data).mw
	c := make([]u8, len(entry), mw.w.allocator)
	copy(c, entry)
	append(&mw.entries, c)
	return .None
}

@(private = "file")
_pool_identity :: proc(data: rawptr) -> osync.Identity {
	mw := (^Mem_Plug)(data).mw
	return mw.w.nodes[M_POOL].identity
}

@(private = "file")
_pool_verify :: proc(data: rawptr, token: []u8, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
	mw := (^Mem_Plug)(data).mw
	if string(token) != "launch" || mw.w.now > mw.token_ok {
		return .Auth
	}
	reply.lease_ms = M_LEASE_MS
	return .None
}

@(private = "file")
_pool_joined :: proc(data: rawptr, space: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, proof: []u8) {
	mw := (^Mem_Plug)(data).mw
	c := make([]u8, len(proof), mw.w.allocator)
	copy(c, proof)
	append(&mw.pool_inbox, Pool_Note{space = space, proof = c})
}

@(private = "file")
_node_cfg :: proc(n: ^Node, cfg: ^eng.Config) {
	mw := _mw
	p := &mw.plugs[n.idx]
	p.mw = mw
	p.idx = n.idx
	cfg.unlock = osync.Unlock{data = p, unlock = _unlock, register = _register}
	cfg.sealed_store = osync.Sealed_Store{data = p, get = _store_get, put = _store_put, add = _store_add}
	cfg.approver = true
	if n.idx == M_POOL {
		cfg.runner_pool = eng.Runner_Pool{data = p, identity = _pool_identity, verify = _pool_verify}
	} else {
		cfg.runner_pool = eng.Runner_Pool{data = p, identity = _pool_identity, joined = _pool_joined}
	}
}

@(private = "file")
_fail :: proc(w: ^World, format: string, args: ..any) {
	world_fail(w, format, ..args)
}

@(private = "file")
_settle :: proc(w: ^World, ms: i64) {
	run_until(w, w.now + ms * 1_000_000, true)
}

@(private = "file")
_up :: proc(w: ^World, idx: int) -> ^Node {
	n := w.nodes[idx]
	if !n.alive && !node_start(n) {
		_fail(w, "n%d did not start", idx)
	}
	return n
}

@(private = "file")
_down :: proc(w: ^World, idx: int) {
	n := w.nodes[idx]
	if n.alive {
		context = instance_context(&n.inst)
		eng.flush(&n.e)
		node_after(n)
		node_kill(n)
		context = w.ctx
		disk_crash(&n.disk, .Process, &w.fault_rng)
	}
}

@(private = "file")
_read :: proc(w: ^World, idx: int, o: eng.Object, r: eng.Rid) -> (text: string, err: eng.Error) {
	n := w.nodes[idx]
	if !n.alive {
		return "", .Offline
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	ready := eng.Ready{call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}}
	msg, merr := eng.convo_message(&n.e, o, convo.Position{msg = r}, context.temp_allocator, ready)
	if merr != .None {
		return "", merr
	}
	t := msg_text(msg)
	return fmt.aprintf("%s", t, allocator = w.allocator), .None
}

@(private = "file")
_wait_read :: proc(w: ^World, idx: int, o: eng.Object, r: eng.Rid, want: string, ms: i64) -> bool {
	for _ in 0 ..< int(ms / 100) {
		if t, err := _read(w, idx, o, r); err == .None && t == want {
			return true
		}
		_settle(w, 100)
	}
	return false
}

@(private = "file")
_send :: proc(w: ^World, idx: int, o: eng.Object, text: string) -> (r: eng.Rid, ok: bool) {
	n := w.nodes[idx]
	if !n.alive {
		return {}, false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	rid, err := eng.convo_send(&n.e, o, text)
	return rid, err == .None
}

@(private = "file")
_status :: proc(w: ^World, idx: int, space: prim.Id) -> (s: eng.Members_Status, err: eng.Error) {
	n := w.nodes[idx]
	if !n.alive {
		return s, .Offline
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	return eng.space_members_status(&n.e, space)
}

@(private = "file")
_roster :: proc(w: ^World, idx: int, space: prim.Id) -> string {
	n := w.nodes[idx]
	if !n.alive {
		return "offline"
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	list, err := eng.space_members(&n.e, space, context.temp_allocator)
	if err != .None {
		return fmt.tprintf("error %v", err)
	}
	ids := make([dynamic]prim.Id, context.temp_allocator)
	out := ""
	for x in list {
		append(&ids, x.device)
	}
	for i in 0 ..< len(ids) {
		for j in i + 1 ..< len(ids) {
			if id_less(ids[j], ids[i]) {
				ids[i], ids[j] = ids[j], ids[i]
			}
		}
	}
	for id in ids {
		for x in list {
			if x.device == id {
				out = fmt.tprintf("%s|%s:%v:%v", out, id_short(id), x.kind, x.removed)
			}
		}
	}
	st, _ := eng.space_members_status(&n.e, space)
	return fmt.aprintf("%s epoch=%d eligible=%v", out, st.epoch, st.eligible, allocator = n.w.allocator)
}

@(private = "file")
_converged :: proc(w: ^World, space: prim.Id, idxs: []int, what: string) {
	first := ""
	for idx, k in idxs {
		r := _roster(w, idx, space)
		if k == 0 {
			first = r
		} else if r != first {
			_fail(w, "%s: n%d roster %s differs from n%d %s", what, idx, r, idxs[0], first)
		}
	}
}

@(private = "file")
_login :: proc(w: ^World, idx: int) -> (eng.Login_Result, eng.Error) {
	n := w.nodes[idx]
	if !n.alive {
		return {}, .Offline
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	return eng.account_login(&n.e, M_SUBJECT, fmt.tprintf("n%d", idx), "relay", w.relay.public)
}

membership_run :: proc(seed: u64) -> (res: Mem_Result) {
	res.seed = seed
	res.failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = M_NODES
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 3072
	cfg.storage = .Stored
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	mw := new(Mem_World)
	mw.w = w
	mw.creds = make(map[int][48]u8)
	mw.record = make([dynamic]u8)
	mw.entries = make([dynamic][]u8)
	mw.pool_inbox = make([dynamic]Pool_Note)
	rng_init(&mw.rng, seed, 4242)
	_mw = mw
	w.node_cfg = _node_cfg
	defer {
		_mw = nil
		delete(mw.creds)
		delete(mw.record)
		for x in mw.entries {
			delete(x, w.allocator)
		}
		delete(mw.entries)
		for x in mw.pool_inbox {
			delete(x.proof, w.allocator)
		}
		delete(mw.pool_inbox)
		free(mw)
		world_destroy(w)
		free(w)
	}
	if !relay_start(&w.relay) {
		append(&res.failures, "relay start")
		return
	}
	for i in 0 ..< M_NODES {
		if i != M_THIEF && i != M_X && i != M_DIR && !node_start(w.nodes[i]) {
			append(&res.failures, fmt.aprintf("n%d start", i))
			return
		}
	}
	_down(w, M_D)
	_down(w, M_RUNNER)
	_down(w, M_C)
	_scenario(w, mw)
	for f in w.failures {
		append(&res.failures, fmt.aprintf("%s", f))
	}
	return
}

@(private = "file")
_scenario :: proc(w: ^World, mw: ^Mem_World) {
	a := w.nodes[M_A]
	r, err := _login(w, M_A)
	if err != .None || r.path != .Created {
		_fail(w, "n0 account creation: %v %v", err, r.path)
		return
	}
	step1: {
		context = instance_context(&a.inst)
		mw.to_phone = true
		if perr := eng.account_passkey_add(&a.e, "phone"); perr != .None {
			_fail(w, "phone passkey registration: %v", perr)
		}
		mw.to_phone = false
		node_after(a)
	}
	spaces: [2]prim.Id
	convs: [2]eng.Object
	for i in 0 ..< 2 {
		context = instance_context(&a.inst)
		id, cerr := eng.space_create(&a.e, fmt.tprintf("space%d", i), "relay", w.relay.public)
		if cerr != .None {
			_fail(w, "space_create: %v", cerr)
			node_after(a)
			return
		}
		spaces[i] = id
		o, oerr := eng.convo_create(&a.e, id, eng.Convo_Settings{title = "c"})
		if oerr != .None {
			_fail(w, "convo_create: %v", oerr)
		}
		convs[i] = o
		node_after(a)
	}
	r0, _ := _send(w, M_A, convs[0], "before-b")
	_settle(w, 2000)

	r, err = _login(w, M_B)
	if err != .None || r.status != .Waiting {
		_fail(w, "n1 should wait for approval: %v %v", err, r.status)
		return
	}
	code: string
	for _ in 0 ..< 100 {
		context = instance_context(&a.inst)
		ps := eng.approvals_pending(&a.e, context.temp_allocator)
		node_after(a)
		if len(ps) > 0 {
			c := ps[0].code
			code = fmt.aprintf("%s", string(c[:]), allocator = w.allocator)
			break
		}
		_settle(w, 100)
	}
	if len(code) == 0 {
		_fail(w, "n0 never saw n1's approval request")
		return
	}
	step2: {
		context = instance_context(&a.inst)
		if aerr := eng.approval_respond(&a.e, code, true); aerr != .None {
			_fail(w, "approval_respond: %v", aerr)
		}
		node_after(a)
	}
	_settle(w, 3000)
	if !_wait_read(w, M_B, convs[0], r0, "before-b", 20_000) {
		_fail(w, "n1 cannot read history after approval")
	}
	for s in spaces {
		st, serr := _status(w, M_B, s)
		if serr != .None || st.removed {
			_fail(w, "n1 not enrolled in every space: %v", serr)
		}
	}
	_converged(w, spaces[0], {M_A, M_B}, "after approval")

	_down(w, M_A)
	_down(w, M_B)
	_up(w, M_C)
	r, err = _login(w, M_C)
	if err != .None || r.status != .Waiting {
		_fail(w, "n2 should first try an approval: %v %v", err, r.status)
	}
	no_approver := false
	for _ in 0 ..< 100 {
		if !w.nodes[M_C].alive {
			break
		}
		_, _, failed := eng.login_waiting(&w.nodes[M_C].e)
		if failed {
			no_approver = true
			break
		}
		_settle(w, 100)
	}
	if !no_approver {
		_fail(w, "n2 was never told that no approver is online")
	}
	step3: {
		c := w.nodes[M_C]
		context = instance_context(&c.inst)
		cr, cerr := eng.account_login_cross_device(&c.e, M_SUBJECT)
		node_after(c)
		if cerr != .None || cr.path != .Cross_Device {
			_fail(w, "cross-device fallback: %v", cerr)
		}
	}
	_settle(w, 3000)
	if !_wait_read(w, M_C, convs[0], r0, "before-b", 20_000) {
		st0, e0 := _status(w, M_C, spaces[0])
		t, rerr := _read(w, M_C, convs[0], r0)
		c := w.nodes[M_C]
		context = instance_context(&c.inst)
		info, _ := eng.space_info(&c.e, spaces[0])
		stats := eng.stats(&c.e)
		node_after(c)
		_fail(w, "n2 cannot read history after cross-device sign-in: %v %q st=%v %v connected=%v fetches=%d pending=%d", rerr, t, st0, e0, info.connected, stats.fetches, stats.pending)
	}

	_up(w, M_A)
	_up(w, M_B)
	_settle(w, 3000)
	recovery: string
	{
		context = instance_context(&a.inst)
		k, kerr := eng.account_recovery_key(&a.e, w.allocator)
		if kerr != .None {
			_fail(w, "recovery key: %v", kerr)
		}
		recovery = k
		node_after(a)
	}
	{
		context = instance_context(&a.inst)
		mw.token_ok = w.now + 60_000_000_000
		if perr := eng.account_pool_set(&a.e, .Everything); perr != .None {
			_fail(w, "account_pool_set: %v", perr)
		}
		node_after(a)
	}
	pool := w.nodes[M_POOL]
	for note in mw.pool_inbox {
		context = instance_context(&pool.inst)
		if _, jerr := eng.space_join_enrollment(&pool.e, note.space, note.proof); jerr != .None {
			_fail(w, "pool join: %v", jerr)
		}
		eng.space_open(&pool.e, note.space)
		node_after(pool)
	}
	clear(&mw.pool_inbox)
	_settle(w, 4000)
	_up(w, M_RUNNER)
	runner := w.nodes[M_RUNNER]
	enrollment: []u8
	{
		context = instance_context(&runner.inst)
		kr := eng.keyring(&runner.e)
		card, _ := osync.keyring_card(&kr)
		node_after(runner)
		context = instance_context(&pool.inst)
		en, perr := eng.pool_enroll(&pool.e, transmute([]u8)string("launch"), card[:], nil, w.allocator)
		node_after(pool)
		if perr != .None {
			_fail(w, "pool_enroll: %v", perr)
		}
		enrollment = en
		context = instance_context(&pool.inst)
		_, again := eng.pool_enroll(&pool.e, transmute([]u8)string("launch"), card[:], nil, w.allocator)
		node_after(pool)
		if again != .None {
			_fail(w, "pool_enroll is not idempotent: %v", again)
		}
		context = instance_context(&runner.inst)
		if _, rerr := eng.runner_enroll(&runner.e, enrollment); rerr != .None {
			_fail(w, "runner_enroll: %v", rerr)
		}
		node_after(runner)
	}
	_settle(w, 4000)
	if !_wait_read(w, M_RUNNER, convs[0], r0, "before-b", 20_000) {
		_fail(w, "pool runner cannot read the conversation")
	}
	step4: {
		context = instance_context(&pool.inst)
		kr := eng.keyring(&pool.e)
		bad, _ := osync.keyring_card(&kr)
		node_after(pool)
		context = instance_context(&pool.inst)
		_, berr := eng.pool_enroll(&pool.e, transmute([]u8)string("forged"), bad[:], nil, w.allocator)
		node_after(pool)
		if berr == .None {
			_fail(w, "pool accepted a forged launch token")
		}
	}

	_down(w, M_A)
	_down(w, M_B)
	_down(w, M_C)
	rs, ok := _send(w, M_RUNNER, convs[0], "runner-while-users-offline")
	if !ok {
		_fail(w, "runner could not write with every user device offline")
	}
	_settle(w, 2000)
	_up(w, M_A)
	if !_wait_read(w, M_A, convs[0], rs, "runner-while-users-offline", 20_000) {
		_fail(w, "n0 cannot read what the runner wrote while it was offline")
	}

	_up(w, M_D)
	{
		d := w.nodes[M_D]
		_down(w, M_A)
		context = instance_context(&d.inst)
		dr, derr := eng.account_login_recovery(&d.e, M_SUBJECT, recovery)
		node_after(d)
		if derr != .None || dr.spaces != 2 {
			_fail(w, "recovery sign-in with every device offline: %v spaces=%d", derr, dr.spaces)
		}
	}
	_settle(w, 3000)
	if !_wait_read(w, M_D, convs[0], r0, "before-b", 20_000) {
		_fail(w, "recovered device cannot read history")
	}

	_up(w, M_A)
	_up(w, M_B)
	_up(w, M_C)
	_settle(w, 3000)
	b := w.nodes[M_B]
	x_card: [osync.CARD_LEN]u8
	{
		x := w.nodes[M_X]
		node_start(x)
		context = instance_context(&x.inst)
		kr := eng.keyring(&x.e)
		x_card, _ = osync.keyring_card(&kr)
		node_after(x)
		_down(w, M_X)
	}
	{
		xid, _ := osync.card_verify(x_card[:])
		context = instance_context(&b.inst)
		_, aerr := eng.member_add(&b.e, spaces[0], xid, .Device, .Member, .Approval, 0, w.allocator)
		node_after(b)
		context = instance_context(&a.inst)
		rerr := eng.member_remove(&a.e, spaces[0], b.identity.id)
		node_after(a)
		if aerr != .None || rerr != .None {
			_fail(w, "concurrent add/remove: %v %v", aerr, rerr)
		}
	}
	_settle(w, 4000)
	secret, sok := _send(w, M_A, convs[0], "after-removal-of-b")
	if !sok {
		_fail(w, "send after removal")
	}
	_settle(w, 4000)
	if !_wait_read(w, M_C, convs[0], secret, "after-removal-of-b", 20_000) {
		sa, _ := _status(w, M_A, spaces[0])
		sc, _ := _status(w, M_C, spaces[0])
		t, rerr := _read(w, M_C, convs[0], secret)
		_fail(w, "remaining member n2 cannot read after removal (false rejection): %v %q a=%v c=%v | %s | %s", rerr, t, sa, sc, _roster(w, M_A, spaces[0]), _roster(w, M_C, spaces[0]))
	}
	if t, rerr := _read(w, M_B, convs[0], secret); rerr == .None && t == "after-removal-of-b" {
		_fail(w, "removed n1 decrypted data written after its removal")
	}
	stb, _ := _status(w, M_B, spaces[0])
	if !stb.removed && !stb.revoked {
		_fail(w, "removed n1 was not told it was removed")
	}
	step5: {
		x := w.nodes[M_X]
		node_start(x)
		context = instance_context(&x.inst)
		eng.space_join_enrollment(&x.e, spaces[0], nil, "space0", "relay", w.relay.public)
		eng.space_open(&x.e, spaces[0])
		node_after(x)
		_settle(w, 3000)
		if t, rerr := _read(w, M_X, convs[0], secret); rerr == .None && t == "after-removal-of-b" {
			_fail(w, "device added by a concurrently removed member read new data")
		}
	}
	step6: {
		context = w.ctx
		key, kerr := prim.read_file(disk_vfs(&b.disk), NODE_DIR + "/device/" + osync.DEVICE_KEY_FILE, context.temp_allocator)
		if kerr != .None {
			_fail(w, "cannot steal n1's device key: %v", kerr)
		} else {
			tv := disk_vfs(&w.nodes[M_THIEF].disk)
			prim.mkdir_all(tv, NODE_DIR + "/device", 0o700)
			prim.replace_atomic(tv, NODE_DIR + "/device/" + osync.DEVICE_KEY_FILE, key)
			x := w.nodes[M_THIEF]
			node_start(x)
			if x.identity.id != b.identity.id {
				_fail(w, "thief did not assume n1's identity")
			}
			context = instance_context(&x.inst)
			eng.space_join_enrollment(&x.e, spaces[0], nil, "space0", "relay", w.relay.public)
			eng.space_open(&x.e, spaces[0])
			node_after(x)
			_settle(w, 3000)
			if t, rerr := _read(w, M_THIEF, convs[0], secret); rerr == .None && t == "after-removal-of-b" {
				_fail(w, "stolen device key read data written after the device was removed")
			}
			if ts, _ := _status(w, M_THIEF, spaces[0]); ts.held {
				_fail(w, "stolen device key obtained the current epoch")
			}
			_down(w, M_THIEF)
		}
	}
	_converged(w, spaces[0], {M_A, M_C, M_POOL, M_RUNNER, M_D}, "after concurrent add/remove")

	{
		c := w.nodes[M_C]
		context = instance_context(&c.inst)
		rerr := eng.space_pool_set(&c.e, spaces[0], false)
		node_after(c)
		if rerr != .None {
			_fail(w, "pool removal: %v", rerr)
		}
	}
	_settle(w, 4000)
	p2, _ := _send(w, M_A, convs[0], "after-pool-removal")
	_settle(w, 4000)
	if t, rerr := _read(w, M_RUNNER, convs[0], p2); rerr == .None && t == "after-pool-removal" {
		_fail(w, "runner read data written after its pool was removed")
	}
	if !_wait_read(w, M_D, convs[0], p2, "after-pool-removal", 20_000) {
		_fail(w, "n5 cannot read after pool removal")
	}

	_down(w, M_RUNNER)
	run_until(w, w.now + i64(M_LEASE_MS + 120_000) * 1_000_000, true)
	l2, _ := _send(w, M_A, convs[1], "after-lease")
	_settle(w, 3000)
	_up(w, M_RUNNER)
	_settle(w, 4000)
	if t, rerr := _read(w, M_RUNNER, convs[1], l2); rerr == .None && t == "after-lease" {
		_fail(w, "runner kept access after its lease lapsed")
	}
	if !_wait_read(w, M_D, convs[1], l2, "after-lease", 20_000) {
		_fail(w, "n5 cannot read space1 after the runner's lease lapsed")
	}

	{
		context = instance_context(&a.inst)
		ws, werr := eng.account_wrappers(&a.e, context.temp_allocator)
		node_after(a)
		phone: []u8
		for x in ws {
			if x.label == "phone" {
				phone = x.credential
			}
		}
		if werr != .None || phone == nil {
			_fail(w, "phone passkey wrapper missing: %v", werr)
		} else {
			context = instance_context(&a.inst)
			if rerr := eng.account_wrapper_remove(&a.e, phone); rerr != .None {
				_fail(w, "wrapper removal: %v", rerr)
			}
			node_after(a)
			x := _up(w, M_X)
			context = instance_context(&x.inst)
			_, xerr := eng.account_login_cross_device(&x.e, M_SUBJECT)
			node_after(x)
			if xerr == .None {
				_fail(w, "a removed passkey still unlocked the account")
			}
		}
	}
	_directory_case(w, spaces[1], convs[1])
	_settle(w, 3000)
	_converged(w, spaces[0], {M_A, M_C, M_D}, "final")
	_converged(w, spaces[1], {M_A, M_C, M_D}, "final space1")
}

@(test)
membership :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	sync.mutex_guard(&serial)
	from: u64 = 1
	count: u64 = 6
	if s, ok := os.lookup_env("SIM_MEMBER_SEED", context.temp_allocator); ok && len(s) > 0 {
		from, _ = strconv.parse_u64(s)
		count = 1
	}
	if s, ok := os.lookup_env("SIM_MEMBER_SEEDS", context.temp_allocator); ok && len(s) > 0 {
		count, _ = strconv.parse_u64(s)
	}
	for seed in from ..< from + count {
		res := membership_run(seed)
		if len(res.failures) > 0 {
			for f in res.failures {
				fmt.eprintfln("membership seed %d: %s", seed, f)
			}
			testing.expect(t, false, fmt.tprintf("membership seed %d failed", seed))
		}
		delete(res.failures)
	}
}

@(private = "file")
_directory_case :: proc(w: ^World, space: prim.Id, o: eng.Object) {
	a := w.nodes[M_A]
	dir := _up(w, M_DIR)
	proof: []u8
	{
		context = instance_context(&a.inst)
		p, aerr := eng.member_add(&a.e, space, dir.identity, .Directory, .Admin, .Directory, 0, w.allocator)
		node_after(a)
		if aerr != .None {
			_fail(w, "adding the directory admin: %v", aerr)
			return
		}
		proof = p
	}
	{
		context = instance_context(&dir.inst)
		eng.space_join_enrollment(&dir.e, space, proof, "space1", "relay", w.relay.public)
		eng.space_open(&dir.e, space)
		node_after(dir)
	}
	_settle(w, 4000)
	x := _up(w, M_X)
	seed: [32]u8
	seed[0] = 0x5a
	person, _ := osync.device_from_seed(seed[:])
	pid := osync.device_identity(&person)
	{
		context = instance_context(&dir.inst)
		derr := eng.directory_add(&dir.e, space, pid, .Member, {x.identity})
		node_after(dir)
		if derr != .None {
			_fail(w, "directory add: %v", derr)
			return
		}
	}
	_settle(w, 3000)
	{
		context = instance_context(&x.inst)
		eng.space_join_enrollment(&x.e, space, nil, "space1", "relay", w.relay.public)
		eng.space_open(&x.e, space)
		node_after(x)
	}
	before, _ := _send(w, M_A, o, "directory-before")
	_settle(w, 3000)
	if !_wait_read(w, M_X, o, before, "directory-before", 20_000) {
		_fail(w, "member added by the directory admin cannot read")
	}
	dir1: {
		context = instance_context(&dir.inst)
		rerr := eng.directory_remove(&dir.e, space, pid.sign)
		node_after(dir)
		if rerr != .None {
			_fail(w, "directory remove: %v", rerr)
		}
	}
	_settle(w, 4000)
	after, _ := _send(w, M_A, o, "directory-after")
	_settle(w, 4000)
	if t, rerr := _read(w, M_X, o, after); rerr == .None && t == "directory-after" {
		_fail(w, "member removed by the directory admin read data written after its removal")
	}
	if !_wait_read(w, M_D, o, after, "directory-after", 20_000) {
		_fail(w, "n5 cannot read after the directory removal")
	}
}

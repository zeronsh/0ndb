package sim

import "core:crypto/blake2b"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"
import "../../src/convo"
import omap "../../src/map"
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
M_GUEST :: 9
M_NODES :: 10
M_REGION_MB :: 192
M_TEMP_MB :: 16
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
	owned:      [dynamic]prim.Id,
	guest_space: prim.Id,
	guest_token: [2 * eng.CAPABILITY_LEN]u8,
	guest_ntok:  int,
	guest_cc:    eng.Cap_Credentials,
	guest_ok:    bool,
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

members_world :: proc() -> ^Mem_World {
	return _mw
}

members_world_set :: proc(mw: ^Mem_World) {
	_mw = mw
}

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
_pool_renew :: proc(data: rawptr, runner: osync.Identity, reply: ^osync.Plug_Reply, done: osync.Plug_Done) -> osync.Error {
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
	cfg.notices_rotate = 2048
	if n.idx == M_GUEST {
		cfg.credentials = eng.Credentials_Source{data = p, produce = _guest_credentials}
	}
	if n.idx == M_POOL {
		cfg.runner_pool = eng.Runner_Pool{data = p, identity = _pool_identity, verify = _pool_verify, renew = _pool_renew}
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
_advance :: proc(w: ^World, ms: i64) {
	until := w.now + ms * 1_000_000
	run_until(w, until, true)
	w.now = max(w.now, until)
}

@(private = "file")
_renewal :: proc(w: ^World) -> (renewal: []u8, ok: bool) {
	rn := w.nodes[M_RUNNER]
	pool := w.nodes[M_POOL]
	if !rn.alive || !pool.alive {
		return nil, false
	}
	context = instance_context(&rn.inst)
	req, qerr := eng.runner_renewal_request(&rn.e, w.allocator)
	node_after(rn)
	if qerr != .None {
		return nil, false
	}
	context = instance_context(&pool.inst)
	en, perr := eng.pool_renew(&pool.e, req, w.allocator)
	node_after(pool)
	context = w.ctx
	return en, perr == .None
}

@(private = "file")
_renew :: proc(w: ^World) -> bool {
	en, ok := _renewal(w)
	if !ok {
		return false
	}
	rn := w.nodes[M_RUNNER]
	context = instance_context(&rn.inst)
	n, err := eng.runner_renew(&rn.e, en)
	node_after(rn)
	context = w.ctx
	return err == .None && n > 0
}

@(private = "file")
_sleep_wake :: proc(w: ^World, space: prim.Id, o: eng.Object) {
	before, berr := _status(w, M_A, space)
	if berr != .None {
		_fail(w, "membership status: %v", berr)
		return
	}
	for i in 0 ..< 3 {
		_down(w, M_RUNNER)
		_advance(w, i64(M_LEASE_MS) + 60_000)
		a_text := fmt.aprintf("while-asleep-%d", i, allocator = w.allocator)
		b_text := fmt.aprintf("after-wake-%d", i, allocator = w.allocator)
		defer delete(a_text, w.allocator)
		defer delete(b_text, w.allocator)
		p_text := fmt.aprintf("pending-at-refusal-%d", i, allocator = w.allocator)
		defer delete(p_text, w.allocator)
		asleep, _ := _send(w, M_A, o, a_text)
		_settle(w, 2000)
		_up(w, M_RUNNER)
		pending, pok := _send(w, M_RUNNER, o, p_text)
		_settle(w, 4000)
		if st, serr := _status(w, M_RUNNER, space); serr != .None || st.removed || st.revoked || !st.lapsed {
			_fail(w, "wake %d: a lapsed runner is not held as lapsed: %v %v", i, serr, st)
		}
		if t, rerr := _read(w, M_RUNNER, o, asleep); rerr == .None && t == a_text {
			_fail(w, "wake %d: a lapsed runner read before its pool renewed it", i)
		}
		if !_renew(w) {
			_fail(w, "wake %d: the pool did not renew the runner", i)
			return
		}
		if !_wait_read(w, M_RUNNER, o, asleep, a_text, 20_000) {
			_fail(w, "wake %d: access did not return after the pool renewed the lease", i)
		}
		if !pok || !_wait_read(w, M_A, o, pending, p_text, 20_000) {
			_fail(w, "wake %d: a write the runner made as it was refused did not reach n0 after renewal", i)
		}
		woke, wok := _send(w, M_RUNNER, o, b_text)
		if !wok || !_wait_read(w, M_A, o, woke, b_text, 20_000) {
			_fail(w, "wake %d: a renewed runner's write did not reach n0", i)
		}
	}
	_settle(w, 3000)
	after, aerr := _status(w, M_A, space)
	if aerr != .None || after.records != before.records {
		_fail(w, "the membership log grew with sleep/wake cycles: %d -> %d records, %d -> %d members", before.records, after.records, before.members, after.members)
	}
	for i in 0 ..< 6 {
		_advance(w, i64(M_LEASE_MS) / 2)
		if !_renew(w) {
			_fail(w, "awake %d: the pool did not renew the runner", i)
			return
		}
		_settle(w, 2000)
		text := fmt.aprintf("awake-%d", i, allocator = w.allocator)
		defer delete(text, w.allocator)
		x, xok := _send(w, M_RUNNER, o, text)
		if !xok || !_wait_read(w, M_A, o, x, text, 20_000) {
			_fail(w, "awake %d: a runner kept alive by pool leases could not write", i)
		}
	}
	_settle(w, 3000)
	up, uerr := _status(w, M_A, space)
	if uerr != .None || up.records != before.records {
		_fail(w, "the membership log grew with runner uptime: %d -> %d records", before.records, up.records)
	}
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
_send_wait :: proc(w: ^World, idx: int, o: eng.Object, text: string, ms: i64) -> (r: eng.Rid, ok: bool) {
	n := w.nodes[idx]
	if !n.alive {
		return {}, false
	}
	p := new(Window_Probe, w.allocator)
	defer free(p, w.allocator)
	done := eng.Done {
		data = p,
		call = proc(data: rawptr, e: ^eng.Engine, res: ^eng.Result, err: eng.Error) {
			x := (^Window_Probe)(data)
			x.fired += 1
			x.err = err
			x.rid = res.item
		},
	}
	context = instance_context(&n.inst)
	rid, err := eng.convo_send(&n.e, o, text, done = done)
	node_after(n)
	context = w.ctx
	if err != .Pending {
		return rid, err == .None
	}
	for _ in 0 ..< int(ms / 100) {
		if p.fired > 0 {
			break
		}
		_settle(w, 100)
	}
	return p.rid, p.fired > 0 && p.err == .None
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
		return fmt.aprintf("error %v", err, allocator = n.w.allocator)
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
	for _ in 0 ..< 200 {
		if _rosters_match(w, space, idxs) {
			return
		}
		_settle(w, 100)
	}
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
_rosters_match :: proc(w: ^World, space: prim.Id, idxs: []int) -> bool {
	first := ""
	for idx, k in idxs {
		r := _roster(w, idx, space)
		if k == 0 {
			first = r
		} else if r != first {
			return false
		}
	}
	return true
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
	prev_main, prev_temp := region_main_size, region_temp_size
	region_configure(M_REGION_MB, M_TEMP_MB)
	defer {
		region_main_size = prev_main
		region_temp_size = prev_temp
	}
	w := new(World)
	world_init(w, cfg)
	mw := new(Mem_World)
	mw.w = w
	mw.creds = make(map[int][48]u8)
	mw.record = make([dynamic]u8)
	mw.entries = make([dynamic][]u8)
	mw.pool_inbox = make([dynamic]Pool_Note)
	mw.owned = make([dynamic]prim.Id)
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
		delete(mw.owned)
		free(mw)
		world_destroy(w)
		free(w)
	}
	if w.aborted || !relay_start(&w.relay) {
		append(&res.failures, "relay start")
		for f in w.failures {
			append(&res.failures, fmt.aprintf("%s", f))
		}
		return
	}
	for i in 0 ..< M_NODES {
		if i != M_THIEF && i != M_X && i != M_DIR && i != M_GUEST && !node_start(w.nodes[i]) {
			append(&res.failures, fmt.aprintf("n%d start", i))
			for f in w.failures {
				append(&res.failures, fmt.aprintf("%s", f))
			}
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
		append(&mw.owned, id)
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
	_live_space(w, mw, M_A, {M_B}, "live-from-a")
	_grant_case(w, mw)
	_adoption_window(w, mw)
	_short_id_wait(w, mw.owned[len(mw.owned) - 1])
	_short_id_instant(w, mw.owned[len(mw.owned) - 1])
	_upload_wait_case(w, mw.owned[len(mw.owned) - 1])
	_fresh_unfollowed(w, mw)
	_fresh_link_down(w, mw)
	_fresh_offline(w, mw, .Refused)
	_fresh_offline(w, mw, .Timeout)
	_fresh_offline(w, mw, .Close_Early)

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
		if _, jerr := eng.space_join_enrollment(&pool.e, note.space, note.proof, "", "relay", w.relay.public); jerr != .None {
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
	_sleep_wake(w, spaces[0], convs[0])

	_up(w, M_D)
	{
		d := w.nodes[M_D]
		_down(w, M_A)
		context = instance_context(&d.inst)
		dr, derr := eng.account_login_recovery(&d.e, M_SUBJECT, recovery)
		node_after(d)
		if derr != .None || dr.spaces != len(mw.owned) {
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
	_live_space(w, mw, M_C, {M_A, M_B, M_D}, "live-from-c")
	_down(w, M_D)
	if _, o, r, live := _live_space(w, mw, M_A, {M_B, M_C}, "live-while-d-down"); live {
		_up(w, M_D)
		if !_wait_read(w, M_D, o, r, "live-while-d-down", 30_000) {
			_fail(w, "n5 never opened the space created while it was offline")
		}
	}
	b := w.nodes[M_B]
	x_card: [osync.CARD_LEN]u8
	{
		x := w.nodes[M_X]
		if !node_start(x) {
			_fail(w, "n%d did not start", M_X)
			return
		}
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
		if !node_start(x) {
			_fail(w, "n%d did not start", M_X)
			return
		}
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
			if !node_start(x) {
				_fail(w, "n%d did not start", M_THIEF)
				return
			}
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
	_advance(w, i64(M_LEASE_MS) + 120_000)
	l2, _ := _send(w, M_A, convs[1], "after-lease")
	_settle(w, 3000)
	_up(w, M_RUNNER)
	_settle(w, 4000)
	if t, rerr := _read(w, M_RUNNER, convs[1], l2); rerr == .None && t == "after-lease" {
		_fail(w, "runner kept access after its lease lapsed")
	}
	stale, stale_ok := _renewal(w)
	if !stale_ok {
		_fail(w, "the pool did not renew a lapsed runner")
	}
	remove: {
		context = instance_context(&pool.inst)
		rerr := eng.member_remove(&pool.e, spaces[1], w.nodes[M_RUNNER].identity.id)
		node_after(pool)
		context = w.ctx
		if rerr != .None {
			_fail(w, "the pool could not remove its runner: %v", rerr)
		}
	}
	_settle(w, 4000)
	l3, _ := _send(w, M_A, convs[1], "after-removal")
	_settle(w, 2000)
	replay: {
		rn := w.nodes[M_RUNNER]
		context = instance_context(&rn.inst)
		eng.runner_renew(&rn.e, stale)
		node_after(rn)
		context = w.ctx
	}
	_settle(w, 5000)
	if t, rerr := _read(w, M_RUNNER, convs[1], l3); rerr == .None && t == "after-removal" {
		_fail(w, "a removed runner was readmitted by a replayed lease")
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
	_every_device_opens(w, mw, {M_A, M_B, M_C, M_D})
	_leave_case(w)
	{
		context = instance_context(&a.inst)
		_, rerr := eng.device_remove(&a.e, w.nodes[M_B].identity.id)
		node_after(a)
		if rerr != .None {
			_fail(w, "device_remove: %v", rerr)
		}
	}
	_settle(w, 3000)
	if id, _, _, live := _live_space(w, mw, M_C, {M_A, M_D}, "after-device-remove"); live {
		_settle(w, 3000)
		nb := w.nodes[M_B]
		context = instance_context(&nb.inst)
		for x in eng.space_list(&nb.e, context.temp_allocator) {
			if x.id == id {
				_fail(w, "the removed n1 was handed a space created after its removal")
			}
		}
		node_after(nb)
	}
	quiet := attaches_snapshot(w)
	_settle(w, 120_000)
	check_reconnects(w, quiet, "the final quiet window")
}

@(private = "file")
_live_space :: proc(w: ^World, mw: ^Mem_World, from: int, readers: []int, name: string) -> (id: prim.Id, o: eng.Object, r: eng.Rid, ok: bool) {
	n := _up(w, from)
	context = instance_context(&n.inst)
	sid, cerr := eng.space_create(&n.e, name, "relay", w.relay.public)
	if cerr != .None {
		node_after(n)
		_fail(w, "%s: space_create on n%d: %v", name, from, cerr)
		return
	}
	obj, oerr := eng.convo_create(&n.e, sid, eng.Convo_Settings{title = name})
	node_after(n)
	append(&mw.owned, sid)
	if oerr != .None {
		_fail(w, "%s: convo_create on n%d: %v", name, from, oerr)
		return
	}
	rid, sent := _send(w, from, obj, name)
	if !sent {
		_fail(w, "%s: send on n%d", name, from)
		return
	}
	for idx in readers {
		if !_wait_read(w, idx, obj, rid, name, 30_000) {
			_fail(w, "%s: signed-in n%d never opened the space n%d created", name, idx, from)
		}
	}
	return sid, obj, rid, true
}

@(private = "file")
Window_Probe :: struct {
	fired: int,
	err:   eng.Error,
	rid:   eng.Rid,
}

@(private = "file")
_adoption_window :: proc(w: ^World, mw: ^Mem_World) {
	a := w.nodes[M_A]
	b := w.nodes[M_B]
	context = instance_context(&a.inst)
	sid, cerr := eng.space_create(&a.e, "window", "relay", w.relay.public)
	ao, oerr := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "window"})
	node_after(a)
	if cerr != .None || oerr != .None {
		_fail(w, "window: n0 create %v %v", cerr, oerr)
		return
	}
	append(&mw.owned, sid)
	found := false
	for _ in 0 ..< 30_000 {
		context = instance_context(&b.inst)
		for x in eng.space_list(&b.e, context.temp_allocator) {
			if x.id == sid {
				found = true
			}
		}
		node_after(b)
		if found {
			break
		}
		run_until(w, w.now + 1_000_000, false)
	}
	if !found {
		_fail(w, "window: n1 never adopted the space")
		return
	}
	cp := new(Window_Probe, w.allocator)
	sp := new(Window_Probe, w.allocator)
	ready := eng.Ready {
		data = cp,
		call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
			p := (^Window_Probe)(data)
			p.fired += 1
			p.err = err
		},
	}
	done := eng.Done {
		data = sp,
		call = proc(data: rawptr, e: ^eng.Engine, res: ^eng.Result, err: eng.Error) {
			p := (^Window_Probe)(data)
			p.fired += 1
			p.err = err
			p.rid = res.item
		},
	}
	context = instance_context(&b.inst)
	st, _ := eng.space_members_status(&b.e, sid)
	_, c1 := eng.convo_create(&b.e, sid, eng.Convo_Settings{title = "in-window"}, ready)
	_, s1 := eng.convo_send(&b.e, ao, "sent-in-window", done = done)
	node_after(b)
	if c1 != .Pending || s1 != .Pending {
		_fail(w, "window: create %v and send %v issued while n1 adopts (eligible=%v epoch=%d) should wait for its membership", c1, s1, st.eligible, st.epoch)
		return
	}
	for _ in 0 ..< 300 {
		if cp.fired > 0 && sp.fired > 0 {
			break
		}
		_settle(w, 100)
	}
	if cp.fired != 1 || cp.err != .None || sp.fired != 1 || sp.err != .None {
		_fail(w, "window: waits finished create=%d/%v send=%d/%v", cp.fired, cp.err, sp.fired, sp.err)
		return
	}
	rid := sp.rid
	free(sp, w.allocator)
	context = instance_context(&b.inst)
	bo, c2 := eng.convo_create(&b.e, sid, eng.Convo_Settings{title = "in-window"})
	node_after(b)
	free(cp, w.allocator)
	if c2 != .None {
		_fail(w, "window: create after the wait: %v", c2)
		return
	}
	if !_wait_read(w, M_A, ao, rid, "sent-in-window", 20_000) {
		_fail(w, "window: n0 cannot read what n1 sent in the adoption window")
	}
	if r, ok := _send(w, M_B, bo, "created-in-window"); !ok || !_wait_read(w, M_A, bo, r, "created-in-window", 20_000) {
		_fail(w, "window: n0 cannot read the conversation n1 created in the adoption window")
	}
}

@(private = "file")
_short_id_wait :: proc(w: ^World, sid: prim.Id) {
	a := w.nodes[M_A]
	_down(w, M_B)
	context = instance_context(&a.inst)
	o, oerr := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "short-id"})
	node_after(a)
	if oerr != .None {
		_fail(w, "short id: n0 create: %v", oerr)
		return
	}
	uploaded := false
	for _ in 0 ..< 300 {
		context = instance_context(&a.inst)
		up, _ := eng.upload_wait(&a.e, o)
		node_after(a)
		if up {
			uploaded = true
			break
		}
		_settle(w, 100)
	}
	if !uploaded {
		_fail(w, "short id: n0's conversation never reached the relay")
		return
	}
	hx := prim.id_hex(o.id)
	short := string(hx[24:])
	fp := new(Window_Probe, w.allocator)
	ready := eng.Ready {
		data = fp,
		call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
			p := (^Window_Probe)(data)
			p.fired += 1
			p.err = err
		},
	}
	b := _up(w, M_B)
	context = instance_context(&b.inst)
	eng.space_open(&b.e, sid)
	rows0, e0 := eng.catalog_find(&b.e, sid, short, context.temp_allocator, ready)
	n0 := len(rows0)
	node_after(b)
	if e0 != .None || n0 != 0 {
		_fail(w, "short id: with no relay connection the lookup should answer at once with nothing: %v rows=%d", e0, n0)
		return
	}
	connected := false
	for _ in 0 ..< 30_000 {
		context = instance_context(&b.inst)
		info, _ := eng.space_info(&b.e, sid)
		node_after(b)
		if info.connected {
			connected = true
			break
		}
		run_until(w, w.now + 1_000_000, false)
	}
	if !connected {
		_fail(w, "short id: n1 never reconnected")
		return
	}
	context = instance_context(&b.inst)
	rows1, e1 := eng.catalog_find(&b.e, sid, short, context.temp_allocator, ready)
	node_after(b)
	if e1 != .Pending {
		_fail(w, "short id: right after connecting, before its feed caught up, n1 should wait instead of answering %v rows=%d", e1, len(rows1))
		return
	}
	e2 := e1
	n2 := 0
	got: prim.Id
	reruns := 0
	for e2 == .Pending && reruns < 20 {
		want := fp.fired + 1
		for _ in 0 ..< 300 {
			if fp.fired >= want {
				break
			}
			_settle(w, 100)
		}
		if fp.fired < want || fp.err != .None {
			_fail(w, "short id: wait %d finished %d/%v", reruns, fp.fired, fp.err)
			return
		}
		reruns += 1
		context = instance_context(&b.inst)
		rows2: []eng.Catalog_Row
		rows2, e2 = eng.catalog_find(&b.e, sid, short, context.temp_allocator, ready)
		n2 = len(rows2)
		got = rows2[0].object if n2 > 0 else prim.Id{}
		node_after(b)
	}
	if e2 != .None || n2 != 1 || got != o.id {
		_fail(w, "short id: after catching up %s should resolve to n0's conversation: %v rows=%d after %d reruns", short, e2, n2, reruns)
		return
	}
	free(fp, w.allocator)
	if r, ok := _send_wait(w, M_B, eng.Object{sid, got}, "via-short-id", 20_000); !ok || !_wait_read(w, M_A, o, r, "via-short-id", 20_000) {
		_fail(w, "short id: n0 cannot read what n1 sent through the resolved short id")
	}
}

@(private = "file")
_short_id_instant :: proc(w: ^World, sid: prim.Id) {
	a := w.nodes[M_A]
	b := _up(w, M_B)
	_settle(w, 2000)
	context = instance_context(&a.inst)
	o, oerr := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "instant"})
	node_after(a)
	if oerr != .None {
		_fail(w, "instant: n0 create: %v", oerr)
		return
	}
	hx := prim.id_hex(o.id)
	short := string(hx[24:])
	fp := new(Window_Probe, w.allocator)
	ready := eng.Ready {
		data = fp,
		call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
			p := (^Window_Probe)(data)
			p.fired += 1
			p.err = err
		},
	}
	unknown := 0
	waited := 0
	resolved := false
	for step in 0 ..< 20_000 {
		context = instance_context(&a.inst)
		on_relay, _ := eng.upload_wait(&a.e, o)
		node_after(a)
		context = instance_context(&b.inst)
		rows, err := eng.catalog_find(&b.e, sid, short, context.temp_allocator, ready)
		n := len(rows)
		got := rows[0].object if n > 0 else prim.Id{}
		node_after(b)
		for err == .Pending {
			waited += 1
			want := fp.fired + 1
			for _ in 0 ..< 300 {
				if fp.fired >= want {
					break
				}
				_settle(w, 100)
			}
			if fp.fired < want || fp.err != .None {
				_fail(w, "instant: lookup at %d ms waited and finished %d/%v", step, fp.fired, fp.err)
				return
			}
			context = instance_context(&b.inst)
			rows, err = eng.catalog_find(&b.e, sid, short, context.temp_allocator, ready)
			n = len(rows)
			got = rows[0].object if n > 0 else prim.Id{}
			node_after(b)
			if err == .None && n == 0 && on_relay {
				_fail(w, "instant: lookup at %d ms began after n0's entry reached the relay, waited, and then answered not found", step)
				return
			}
		}
		if err != .None {
			_fail(w, "instant: lookup at %d ms: %v", step, err)
			return
		}
		if n > 0 {
			if n != 1 || got != o.id {
				_fail(w, "instant: %s resolved to %d rows", short, n)
				return
			}
			resolved = true
			break
		}
		unknown += 1
		run_until(w, w.now + 1_000_000, false)
	}
	if !resolved {
		_fail(w, "instant: %s never resolved on n1", short)
		return
	}
	free(fp, w.allocator)
	if r, ok := _send_wait(w, M_B, eng.Object{sid, o.id}, "instant-via-short-id", 20_000); !ok || !_wait_read(w, M_A, o, r, "instant-via-short-id", 20_000) {
		_fail(w, "instant: n0 cannot read what n1 sent through the short id")
	}
	world_note(w, "instant short id: %d lookups before n1 knew of it, %d waits", unknown, waited)
}

@(private = "file")
_upload_wait_case :: proc(w: ^World, sid: prim.Id) {
	a := w.nodes[M_A]
	fp := new(Window_Probe, w.allocator)
	ready := eng.Ready {
		data = fp,
		call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
			p := (^Window_Probe)(data)
			p.fired += 1
			p.err = err
		},
	}
	context = instance_context(&a.inst)
	o, oerr := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "uploaded"})
	up0, e0 := eng.upload_wait(&a.e, o, ready)
	node_after(a)
	if oerr != .None || up0 || e0 != .Pending {
		_fail(w, "upload: a fresh create while connected should wait for the relay: create %v uploaded=%v %v", oerr, up0, e0)
		return
	}
	for _ in 0 ..< 300 {
		if fp.fired > 0 {
			break
		}
		_settle(w, 100)
	}
	free_probe := fp.fired == 1
	if fp.fired != 1 || fp.err != .None {
		_fail(w, "upload: wait finished %d/%v", fp.fired, fp.err)
		return
	}
	context = instance_context(&a.inst)
	up1, e1 := eng.upload_wait(&a.e, o)
	node_after(a)
	if !up1 || e1 != .None {
		_fail(w, "upload: after the relay acknowledged the create, uploaded=%v %v", up1, e1)
		return
	}
	if free_probe {
		free(fp, w.allocator)
	}
	cancelled := new(Window_Probe, w.allocator)
	cready := eng.Ready {
		data = cancelled,
		call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
			p := (^Window_Probe)(data)
			p.fired += 1
		},
	}
	context = instance_context(&a.inst)
	oc, ocerr := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "uploaded-cancelled"})
	upc, ec := eng.upload_wait(&a.e, oc, cready)
	eng.cancel_waits(&a.e, cancelled)
	node_after(a)
	if ocerr != .None || upc || ec != .Pending {
		_fail(w, "upload: second create should wait: %v uploaded=%v %v", ocerr, upc, ec)
		return
	}
	uploaded := false
	for _ in 0 ..< 300 {
		context = instance_context(&a.inst)
		up, _ := eng.upload_wait(&a.e, oc)
		node_after(a)
		if up {
			uploaded = true
			break
		}
		_settle(w, 100)
	}
	_settle(w, 500)
	if !uploaded || cancelled.fired != 0 {
		_fail(w, "upload: a cancelled wait fired %d times (uploaded=%v); its caller is gone", cancelled.fired, uploaded)
		return
	}
	free(cancelled, w.allocator)
	_down(w, M_A)
	a = _up(w, M_A)
	context = instance_context(&a.inst)
	eng.space_open(&a.e, sid)
	o2, oerr2 := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "uploaded-offline"})
	up2, e2 := eng.upload_wait(&a.e, o2, eng.Ready{data = nil, call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}})
	node_after(a)
	if oerr2 != .None || up2 || e2 != .None {
		_fail(w, "upload: without a relay connection the create should answer at once with uploaded=false: %v uploaded=%v %v", oerr2, up2, e2)
	}
	_settle(w, 3000)
}

@(private = "file")
_guest_credentials :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	p := (^Mem_Plug)(data)
	mw := p.mw
	if !mw.guest_ok || space != mw.guest_space {
		return {}, false
	}
	n := mw.w.nodes[p.idx]
	c, err := eng.capability_credentials(&mw.guest_cc, osync.file_keyring(&n.keyring), mw.guest_token[:mw.guest_ntok * eng.CAPABILITY_LEN])
	return c, err == .None
}

@(private = "file")
_guest_reads :: proc(w: ^World, o: eng.Object, r: eng.Rid, want: string, ms: i64) -> bool {
	return _wait_read(w, M_GUEST, o, r, want, ms)
}

@(private = "file")
_grant_share :: proc(w: ^World, mw: ^Mem_World, sid: prim.Id, o: eng.Object) -> bool {
	a := w.nodes[M_A]
	g := w.nodes[M_GUEST]
	context = instance_context(&a.inst)
	share, serr := eng.share_object(&a.e, o, g.identity, {.Read})
	tok, terr := eng.capability_issue(&a.e, eng.Capability{space = sid, grantee = g.identity.id, object = o.id, kind = .Conversation, access = {.Read}}, context.temp_allocator)
	if serr == .None && terr == .None {
		copy(mw.guest_token[mw.guest_ntok * eng.CAPABILITY_LEN:], tok)
		mw.guest_ntok += 1
	}
	node_after(a)
	if serr != .None || terr != .None {
		_fail(w, "grant: share %v capability %v", serr, terr)
		return false
	}
	mw.guest_space = sid
	mw.guest_ok = true
	context = instance_context(&g.inst)
	jerr := eng.Error.None
	if mw.guest_ntok == 1 {
		jerr = eng.space_join_shared(&g.e, sid, "guest", "relay", w.relay.public)
		eng.space_open(&g.e, sid)
	}
	aerr := eng.accept_share(&g.e, share)
	node_after(g)
	if jerr != .None || aerr != .None {
		_fail(w, "grant: guest join %v accept %v", jerr, aerr)
		return false
	}
	return true
}

@(private = "file")
_grant_rotate :: proc(w: ^World, sid: prim.Id) -> bool {
	a := w.nodes[M_A]
	context = instance_context(&a.inst)
	rerr := eng.space_rotate(&a.e, sid)
	node_after(a)
	if rerr != .None {
		_fail(w, "grant: rotate: %v", rerr)
		return false
	}
	_settle(w, 1000)
	return true
}

@(private = "file")
_grant_case :: proc(w: ^World, mw: ^Mem_World) {
	a := w.nodes[M_A]
	context = instance_context(&a.inst)
	sid, cerr := eng.space_create(&a.e, "granted", "relay", w.relay.public)
	o1, oerr1 := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "granted-1"})
	o2, oerr2 := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "granted-2"})
	node_after(a)
	if cerr != .None || oerr1 != .None || oerr2 != .None {
		_fail(w, "grant: create %v %v %v", cerr, oerr1, oerr2)
		return
	}
	append(&mw.owned, sid)
	r1, _ := _send(w, M_A, o1, "one-0")
	r2, _ := _send(w, M_A, o2, "two-0")
	_up(w, M_GUEST)
	if !_grant_share(w, mw, sid, o1) {
		return
	}
	if !_guest_reads(w, o1, r1, "one-0", 20_000) {
		_fail(w, "grant: the guest cannot read the first shared conversation")
		return
	}
	if !_wait_read(w, M_B, o1, r1, "one-0", 20_000) {
		_fail(w, "grant: n1 never saw the shared conversation")
		return
	}
	_down(w, M_A)
	rb, bok := _send_wait(w, M_B, o1, "from-another-member", 20_000)
	read := bok && _guest_reads(w, o1, rb, "from-another-member", 20_000)
	a = _up(w, M_A)
	if !bok {
		_fail(w, "grant: n1 could not write the shared conversation")
		return
	}
	if !read {
		_fail(w, "grant: with the sharer offline, the guest cannot read a member who first wrote the shared conversation after the share (writer card never reached the guest)")
		return
	}
	if !_grant_share(w, mw, sid, o2) {
		return
	}
	if !_guest_reads(w, o2, r2, "two-0", 20_000) {
		_fail(w, "grant: the guest cannot read a second conversation shared from the same space")
		return
	}
	ones := [3]string{"one-1", "one-2", "one-3"}
	twos := [4]string{"two-1", "two-2", "two-3", "two-4"}
	for i in 0 ..< 2 {
		if !_grant_rotate(w, sid) {
			return
		}
		ri1, _ := _send(w, M_A, o1, ones[i])
		ri2, _ := _send(w, M_A, o2, twos[i])
		if !_guest_reads(w, o1, ri1, ones[i], 20_000) || !_guest_reads(w, o2, ri2, twos[i], 20_000) {
			context = instance_context(&a.inst)
			st, _ := eng.space_members_status(&a.e, sid)
			node_after(a)
			_fail(w, "grant: after epoch advance %d (epoch %d) the guest cannot read both granted conversations", i + 1, st.epoch)
			return
		}
	}
	g := w.nodes[M_GUEST]
	context = instance_context(&a.inst)
	verr := eng.share_revoke(&a.e, o1, g.identity.id)
	node_after(a)
	if verr != .None {
		_fail(w, "grant: revoke the first: %v", verr)
		return
	}
	_settle(w, 2000)
	rs1, _ := _send(w, M_A, o1, ones[2])
	rk2, _ := _send(w, M_A, o2, twos[2])
	if !_guest_reads(w, o2, rk2, twos[2], 20_000) {
		_fail(w, "grant: after revoking only the first conversation the guest lost the second")
		return
	}
	if !_grant_rotate(w, sid) {
		return
	}
	rk3, _ := _send(w, M_A, o2, twos[3])
	if !_guest_reads(w, o2, rk3, twos[3], 20_000) {
		_fail(w, "grant: the guest stopped reading the conversation still granted after another epoch advance")
		return
	}
	if t, rerr := _read(w, M_GUEST, o1, rs1); rerr == .None && t == ones[2] {
		_fail(w, "grant: the guest decrypted a record of the revoked conversation written after the revoke, although only its relay access was left")
	}
	context = instance_context(&a.inst)
	lerr := eng.share_revoke(&a.e, o2, g.identity.id)
	node_after(a)
	if lerr != .None {
		_fail(w, "grant: revoke the last: %v", lerr)
		return
	}
	_settle(w, 2000)
	rl, _ := _send(w, M_A, o2, "two-after-last-revoke")
	_settle(w, 5000)
	if t, rerr := _read(w, M_GUEST, o2, rl); rerr == .None && t == "two-after-last-revoke" {
		_fail(w, "grant: a guest whose last grant was revoked decrypted a later record")
	}
	mw.guest_ok = false
	_down(w, M_GUEST)
}

@(private = "file")
_every_device_opens :: proc(w: ^World, mw: ^Mem_World, idxs: []int) {
	missing := 0
	who := 0
	what: prim.Id
	for _ in 0 ..< 200 {
		missing = 0
		for idx in idxs {
			n := w.nodes[idx]
			if !n.alive {
				continue
			}
			context = instance_context(&n.inst)
			list := eng.space_list(&n.e, context.temp_allocator)
			for s in mw.owned {
				found := false
				for x in list {
					if x.id == s && x.open {
						found = true
					}
				}
				if !found {
					missing += 1
					who = idx
					what = s
				}
			}
			node_after(n)
		}
		context = w.ctx
		if missing == 0 {
			return
		}
		_settle(w, 100)
	}
	_fail(w, "%d account spaces were never opened by a signed-in device, e.g. n%d %s", missing, who, id_short(what))
}

@(test)
membership :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
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
Dir_Woke :: struct {
	fired: bool,
	err:   eng.Error,
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
		woke := new(Dir_Woke, w.allocator)
		ready := eng.Ready{data = woke, call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {
			x := (^Dir_Woke)(data)
			x.fired = true
			x.err = err
		}}
		context = instance_context(&dir.inst)
		derr := eng.directory_add(&dir.e, space, pid, .Member, {x.identity}, ready)
		node_after(dir)
		context = w.ctx
		if derr == .Pending {
			for _ in 0 ..< 300 {
				if woke.fired {
					break
				}
				_settle(w, 100)
			}
			derr = woke.err if woke.fired else .Pending
			if derr == .None {
				context = instance_context(&dir.inst)
				derr = eng.directory_add(&dir.e, space, pid, .Member, {x.identity})
				node_after(dir)
				context = w.ctx
			}
		}
		if woke.fired || derr != .Pending {
			free(woke, w.allocator)
		}
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

@(private = "file")
_has_space :: proc(w: ^World, idx: int, space: prim.Id) -> (has: bool, left: bool) {
	n := w.nodes[idx]
	if !n.alive {
		return false, false
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	for x in eng.space_list(&n.e, context.temp_allocator) {
		if x.id == space {
			has = true
		}
	}
	return has, eng.space_left(&n.e, space)
}

@(private = "file")
_leave :: proc(w: ^World, idx: int, space: prim.Id, only_device: bool) -> (eng.Leave_Result, eng.Error) {
	n := w.nodes[idx]
	context = instance_context(&n.inst)
	defer node_after(n)
	return eng.space_leave(&n.e, space, only_device)
}

@(private = "file")
_leaver_gone :: proc(w: ^World, idx: int, space: prim.Id, o: eng.Object, secret: string, on_disk: bool, what: string, idle: bool, key_row: []u8 = nil) {
	gone := false
	for _ in 0 ..< 200 {
		if has, left := _has_space(w, idx, space); !has && left {
			gone = true
			break
		}
		_settle(w, 100)
	}
	if !gone {
		has, left := _has_space(w, idx, space)
		_fail(w, "%s: n%d still holds the space after leaving (listed=%v tombstone=%v)", what, idx, has, left)
		return
	}
	_settle(w, 5000)
	if idle {
		ln := w.nodes[idx]
		w0 := eng.stats(&ln.e).wakeups
		_settle(w, 30_000)
		w1 := eng.stats(&ln.e).wakeups
		if w1 != w0 || loop_armed(&ln.inst.loop) > 0 {
			_fail(w, "%s: n%d is not idle after the erase: %d wakeups in 30 s, armed: %s", what, idx, w1 - w0, armed_timers(&ln.inst.loop))
		}
	}
	if p, found := disk_contains(&w.nodes[idx].disk, transmute([]u8)secret); on_disk && found {
		_fail(w, "%s: %s still on n%d disk after leaving, in %s", what, secret, idx, p)
	}
	if len(key_row) > 0 {
		if disk_probe_freed_contains(&w.nodes[idx].disk, key_row) {
			_fail(w, "%s: n%d's own key tree for the conversation survives in freed blocks of a replaced or removed registry file", what, idx)
		}
		if p, found := disk_contains(&w.nodes[idx].disk, key_row); found {
			_fail(w, "%s: n%d's own key tree for the conversation is still on its disk after leaving, in %s", what, idx, p)
		}
	}
	_down(w, idx)
	_up(w, idx)
	_settle(w, 3000)
	if has, left := _has_space(w, idx, space); has || !left {
		_fail(w, "%s: n%d got the space back after a restart (listed=%v tombstone=%v)", what, idx, has, left)
	}
	after := fmt.aprintf("after-%s", what, allocator = w.allocator)
	r, ok := _send_wait(w, M_A, o, after, 20_000)
	if !ok {
		_fail(w, "%s: n0 cannot write after the leave", what)
		return
	}
	_settle(w, 3000)
	if t, rerr := _read(w, idx, o, r); rerr == .None && t == after {
		_fail(w, "%s: n%d read data written after it left", what, idx)
	}
	readers := [2]int{M_C, M_D}
	for x in readers {
		if x != idx && !_wait_read(w, x, o, r, after, 20_000) {
			_fail(w, "%s: remaining n%d cannot read after the leave | %s", what, x, _roster(w, x, space))
		}
	}
	a := w.nodes[M_A]
	context = instance_context(&a.inst)
	list, lerr := eng.space_members(&a.e, space, context.temp_allocator)
	st, _ := eng.space_members_status(&a.e, space)
	node_after(a)
	context = w.ctx
	if lerr != .None || !st.eligible {
		_fail(w, "%s: n0 has no eligible epoch after the leave: %v eligible=%v", what, lerr, st.eligible)
	}
	for x in list {
		if x.device == w.nodes[idx].identity.id && (!x.removed || x.in_tree) {
			_fail(w, "%s: n%d is still a member of the new epoch (removed=%v in_tree=%v)", what, idx, x.removed, x.in_tree)
		}
	}
}

@(private = "file")
_leave_case :: proc(w: ^World) {
	a := _up(w, M_A)
	x := _up(w, M_X)
	_up(w, M_C)
	_up(w, M_D)
	disk_probe_keep_freed(&x.disk, fmt.tprintf("%s/registry", x.e.dir))
	context = instance_context(&a.inst)
	sid, cerr := eng.space_create(&a.e, "leave", "relay", w.relay.public)
	o, oerr := eng.convo_create(&a.e, sid, eng.Convo_Settings{title = "leave"})
	proof, aerr := eng.member_add(&a.e, sid, x.identity, .Device, .Member, .Approval, 0, w.allocator)
	node_after(a)
	if cerr != .None || oerr != .None || aerr != .None {
		_fail(w, "leave: setup %v %v %v", cerr, oerr, aerr)
		return
	}
	context = instance_context(&x.inst)
	eng.space_join_enrollment(&x.e, sid, proof, "leave", "relay", w.relay.public)
	eng.space_open(&x.e, sid)
	node_after(x)
	context = w.ctx
	secret := "leave-secret-before"
	r, ok := _send(w, M_A, o, secret)
	if !ok {
		_fail(w, "leave: send")
		return
	}
	for idx in ([3]int{M_X, M_C, M_D}) {
		if !_wait_read(w, idx, o, r, secret, 30_000) {
			_fail(w, "leave: n%d cannot read before leaving", idx)
			return
		}
	}
	if _, lerr := _leave(w, M_A, sid, false); lerr != .Permission {
		_fail(w, "leave: the last owner's person left without transferring ownership: %v", lerr)
	}
	if _, xok := _send(w, M_X, o, "leave-member-wrote"); !xok {
		_fail(w, "leave: n%d cannot write before leaving", M_X)
		return
	}
	_settle(w, 3000)
	x_row := _own_key_row(w, M_X, o.id)
	if len(x_row) == 0 {
		_fail(w, "leave: n%d has no own key tree row for the conversation it wrote to", M_X)
		return
	}
	if _, found := disk_contains(&x.disk, x_row); !found {
		_fail(w, "leave: n%d's own key tree row is not visible on its disk before leaving (the check would be vacuous)", M_X)
	}
	_, x_disk := disk_contains(&x.disk, transmute([]u8)secret)
	res, lerr := _leave(w, M_X, sid, false)
	if lerr != .None || res.removed != 1 {
		_fail(w, "leave: n%d leave %v removed=%d", M_X, lerr, res.removed)
		return
	}
	_leaver_gone(w, M_X, sid, o, secret, x_disk, "member-leave", false, x_row)
	_, d_disk := disk_contains(&w.nodes[M_D].disk, transmute([]u8)secret)
	res, lerr = _leave(w, M_D, sid, true)
	if lerr != .None || res.removed != 1 {
		_fail(w, "leave: n%d device-only leave %v removed=%d", M_D, lerr, res.removed)
		return
	}
	_leaver_gone(w, M_D, sid, o, secret, d_disk, "device-leave", true)
	_converged(w, sid, {M_A, M_C}, "after leave")
}

@(private = "file")
_own_key_row :: proc(w: ^World, idx: int, object: prim.Id) -> []u8 {
	n := w.nodes[idx]
	if !n.alive || !n.e_open {
		return nil
	}
	disk_probe_begin(&n.disk)
	defer disk_probe_end(&n.disk)
	db: omap.Db
	if omap.db_open(&db, disk_vfs(&n.disk), fmt.tprintf("%s/registry", n.e.dir), context.temp_allocator) != .None {
		return nil
	}
	defer {
		db.poisoned = true
		omap.db_close(&db)
	}
	key: [17]u8
	o := object
	copy(key[:16], o[:])
	key[16] = 'k'
	v, found, err := omap.db_get(&db, 0, key[:], context.temp_allocator)
	if err != .None || !found {
		return nil
	}
	out := make([]u8, len(v), w.allocator)
	copy(out, v)
	return out
}

@(private = "file")
FRESH_POLL_MAX :: 32

@(private = "file")
_fresh_unfollowed :: proc(w: ^World, mw: ^Mem_World) {
	_, o, _, live := _live_space(w, mw, M_A, {M_B}, "fresh-unfollowed")
	if !live {
		return
	}
	run_until(w, w.now + 5_000 * 1_000_000, false)
	r2, sent := _send(w, M_A, o, "fresh-unfollowed-2")
	if !sent {
		_fail(w, "fresh-unfollowed: second send on n0")
		return
	}
	run_until(w, w.now + 5_000 * 1_000_000, false)
	b := w.nodes[M_B]
	if !b.alive || !b.e_open {
		_fail(w, "fresh-unfollowed: n1 is down")
		return
	}
	before := b.e.stats.probes
	links := b.connects
	polls := 0
	for polls < FRESH_POLL_MAX {
		polls += 1
		context = instance_context(&b.inst)
		ready := eng.Ready{call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}, fresh = true}
		st, err := eng.convo_status(&b.e, o, ready)
		node_after(b)
		context = w.ctx
		if err == .None {
			if st.head != r2 {
				_fail(w, "fresh-unfollowed: a fresh read on n1 completed without n0's newer message (head %v, want %v) after %d polls", st.head, r2, polls)
			}
			probes := b.e.stats.probes - before
			if probes > u64(1 + b.connects - links) {
				_fail(w, "fresh-unfollowed: n1 needed %d probes over %d new connections for one segment", probes, b.connects - links)
			}
			return
		}
		if err != .Missing && err != .Pending && err != .Busy {
			_fail(w, "fresh-unfollowed: fresh read on n1 failed: %v", err)
			return
		}
		run_until(w, w.now + 2_000 * 1_000_000, false)
	}
	_fail(w, "fresh-unfollowed: n1 polled %d fresh reads without completing (%d probes)", polls, b.e.stats.probes - before)
}

@(private = "file")
_fresh_status :: proc(w: ^World, idx: int, o: eng.Object) -> (st: eng.Convo_Status, err: eng.Error) {
	n := w.nodes[idx]
	if !n.alive || !n.e_open {
		return st, .Offline
	}
	context = instance_context(&n.inst)
	defer node_after(n)
	ready := eng.Ready{call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}, fresh = true}
	return eng.convo_status(&n.e, o, ready)
}

@(private = "file")
_fresh_link_down :: proc(w: ^World, mw: ^Mem_World) {
	_, o, _, live := _live_space(w, mw, M_A, {M_B}, "fresh-link-down")
	if !live {
		return
	}
	run_until(w, w.now + 5_000 * 1_000_000, false)
	r2, sent := _send(w, M_A, o, "fresh-link-down-2")
	if !sent {
		_fail(w, "fresh-link-down: second send on n0")
		return
	}
	run_until(w, w.now + 5_000 * 1_000_000, false)
	b := w.nodes[M_B]
	b.partitioned = true
	for c in b.conns {
		conn_reset(c, true)
	}
	run_until(w, w.now + 2_000 * 1_000_000, false)
	for polls in 1 ..= 5 {
		st, err := _fresh_status(w, M_B, o)
		if err == .None {
			_fail(w, "fresh-link-down: with n1 cut off a fresh read on n1 completed from local data (head %v) at poll %d", st.head, polls)
			break
		}
		if err != .Pending && err != .Missing && err != .Offline {
			_fail(w, "fresh-link-down: fresh read on n1 while cut off failed: %v", err)
			break
		}
		run_until(w, w.now + 2_000 * 1_000_000, false)
	}
	b.partitioned = false
	for _ in 1 ..= FRESH_POLL_MAX {
		st, err := _fresh_status(w, M_B, o)
		if err == .None {
			if st.head != r2 {
				_fail(w, "fresh-link-down: after the partition healed a fresh read on n1 completed without n0's newer message (head %v, want %v)", st.head, r2)
			}
			return
		}
		run_until(w, w.now + 2_000 * 1_000_000, false)
	}
	_fail(w, "fresh-link-down: after the partition healed n1 polled %d fresh reads without completing", FRESH_POLL_MAX)
}

@(private = "file")
_fresh_offline :: proc(w: ^World, mw: ^Mem_World, fault: Connect_Fault) {
	name := "fresh-offline-refused"
	switch fault {
	case .None, .Refused:
	case .Timeout:
		name = "fresh-offline-timeout"
	case .Close_Early:
		name = "fresh-offline-close-early"
	}
	_, o, _, live := _live_space(w, mw, M_A, {M_B}, name)
	if !live {
		return
	}
	run_until(w, w.now + 5_000 * 1_000_000, false)
	r2, sent := _send(w, M_A, o, "fresh-offline-2")
	if !sent {
		_fail(w, "%s: second send on n0", name)
		return
	}
	run_until(w, w.now + 5_000 * 1_000_000, false)
	b := w.nodes[M_B]
	before := b.unavailable
	b.connect_fault = fault
	b.partitioned = true
	for c in b.conns {
		conn_reset(c, true)
	}
	offline := false
	for polls in 1 ..= 10 {
		st, err := _fresh_status(w, M_B, o)
		if err == .None {
			_fail(w, "%s: with n1 cut off a fresh read on n1 completed from local data (head %v) at poll %d", name, st.head, polls)
			break
		}
		if err == .Offline {
			offline = true
			break
		}
		if err != .Pending && err != .Missing {
			_fail(w, "%s: fresh read on n1 while cut off failed: %v", name, err)
			break
		}
		run_until(w, w.now + 2_000 * 1_000_000, false)
	}
	if !offline {
		_fail(w, "%s: a fresh read on n1 never answered Offline while every connect attempt failed", name)
	} else if b.unavailable == before {
		_fail(w, "%s: n1 answered Offline without an Unavailable event", name)
	}
	b.connect_fault = .None
	b.partitioned = false
	for _ in 1 ..= FRESH_POLL_MAX {
		st, err := _fresh_status(w, M_B, o)
		if err == .None {
			if st.head != r2 {
				_fail(w, "%s: after the partition healed a fresh read on n1 completed without n0's newer message (head %v, want %v)", name, st.head, r2)
			}
			return
		}
		run_until(w, w.now + 2_000 * 1_000_000, false)
	}
	_fail(w, "%s: after the partition healed n1 polled %d fresh reads without completing", name, FRESH_POLL_MAX)
}

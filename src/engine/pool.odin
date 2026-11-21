package engine

import "../prim"
import osync "../sync"

@(private)
ENROLLMENT_VERSION :: 1

Runner_Pool :: struct {
	data:     rawptr,
	identity: proc(data: rawptr) -> osync.Identity,
	verify:   proc(data: rawptr, token: []u8, runner: osync.Identity) -> (lease_ms: u64, err: osync.Error),
	attest:   proc(data: rawptr, evidence: []u8, runner: osync.Identity) -> osync.Error,
	joined:   proc(data: rawptr, space: prim.Id, name: string, relay: string, relay_public: osync.Public_Key, proof: []u8),
}

@(private)
_pool_notify :: proc(e: ^Engine, sp: ^Space) {
	if e.cfg.runner_pool.joined == nil {
		return
	}
	zero: osync.Public_Key
	if e.account.pool_sign == zero {
		return
	}
	m: osync.Membership
	if _members_load(e, sp, &m) != .None {
		return
	}
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return
	}
	idx := osync.roster_find(&m.roster, e.account.pool_sign)
	if idx < 0 || m.roster.members[idx].removed {
		return
	}
	ri, ok := m.ids[m.roster.members[idx].added]
	if !ok {
		return
	}
	proof := make([]u8, len(m.raws[ri]), context.temp_allocator)
	copy(proof, m.raws[ri])
	context = _outer(e)
	e.cfg.runner_pool.joined(e.cfg.runner_pool.data, sp.id, sp.name, sp.relay, sp.relay_public, proof)
}

pool_enroll :: proc(e: ^Engine, token: []u8, card: []u8, evidence: []u8 = nil, allocator := context.allocator) -> (enrollment: []u8, err: Error) {
	context = context_for(e)
	if e.cfg.runner_pool.verify == nil {
		return nil, .Unsupported
	}
	runner, cerr := osync.card_verify(card)
	if cerr != .None {
		return nil, .Invalid
	}
	lease: u64
	verr: osync.Error
	{
		context = _outer(e)
		lease, verr = e.cfg.runner_pool.verify(e.cfg.runner_pool.data, token, runner)
		if verr == .None && e.cfg.runner_pool.attest != nil {
			verr = e.cfg.runner_pool.attest(e.cfg.runner_pool.data, evidence, runner)
		}
	}
	if verr != .None || lease == 0 {
		return nil, .Permission
	}
	out := make([dynamic]u8, context.temp_allocator)
	w := prim.writer(&out)
	prim.write_u8(&w, ENROLLMENT_VERSION)
	items := make([dynamic][]u8, context.temp_allocator)
	ids := make([dynamic]^Space, context.temp_allocator)
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if sp.keyless {
			continue
		}
		if _, oerr := _space_open(e, id); oerr != .None {
			continue
		}
		proof, perr := _pool_enroll_space(e, sp, runner, lease)
		if perr != .None {
			continue
		}
		append(&items, proof)
		append(&ids, sp)
	}
	prim.write_uvarint(&w, u64(len(items)))
	for p, i in items {
		sp := ids[i]
		prim.write_id(&w, sp.id)
		prim.write_str(&w, sp.name)
		prim.write_str(&w, sp.relay)
		prim.write_raw(&w, sp.relay_public[:])
		prim.write_bytes(&w, p)
	}
	if w.err != .None {
		return nil, .No_Memory
	}
	enrollment = make([]u8, len(out), allocator)
	copy(enrollment, out[:])
	return enrollment, .None
}

@(private)
_pool_enroll_space :: proc(e: ^Engine, sp: ^Space, runner: osync.Identity, lease: u64) -> (proof: []u8, err: Error) {
	m: osync.Membership
	_members_load(e, sp, &m) or_return
	defer osync.membership_destroy(&m)
	if osync.membership_resolve(&m) != .None {
		return nil, .Not_Found
	}
	now := _now_ms(e)
	me := osync.roster_find(&m.roster, e.identity.sign)
	if me < 0 || m.roster.members[me].kind != .Pool || !osync.member_active(&m.roster.members[me], now) {
		return nil, .Permission
	}
	osync.membership_open(&m, osync.Opener{keyring = &e.keyring, self = e.identity})
	if x := osync.roster_find(&m.roster, runner.sign); x >= 0 && osync.member_active(&m.roster.members[x], now) {
		ri, ok := m.ids[m.roster.members[x].added]
		if ok {
			c := make([]u8, len(m.raws[ri]), context.temp_allocator)
			copy(c, m.raws[ri])
			return c, .None
		}
	}
	k := osync.membership_current(&m, now)
	if k == nil {
		return nil, .Permission
	}
	wrap := make([dynamic]u8, context.temp_allocator)
	_serr(osync.membership_bundle(&m, k, runner, &wrap, e.cfg.random)) or_return
	b := osync.Add_Body{sign = runner.sign, box = runner.box, kind = .Runner, role = .Member, method = .Pool, lease_ms = lease, person = e.account.sign, history = true, seal = wrap[:]}
	raw, aerr := osync.membership_add(&m, osync.keyring_member_signer(&e.keyring), b, now)
	_serr(aerr) or_return
	c := make([]u8, len(raw), context.temp_allocator)
	copy(c, raw)
	_members_emit(e, sp, &m, [][]u8{c}) or_return
	return c, .None
}

runner_enroll :: proc(e: ^Engine, enrollment: []u8) -> (spaces: int, err: Error) {
	context = context_for(e)
	r := prim.reader(enrollment)
	if prim.read_u8(&r) != ENROLLMENT_VERSION {
		return 0, .Invalid
	}
	n := prim.read_uvarint(&r)
	if !prim.reader_ok(&r) || n > 4096 {
		return 0, .Invalid
	}
	for _ in 0 ..< int(n) {
		id := prim.read_id(&r)
		name := prim.read_str(&r)
		relay := prim.read_str(&r)
		rp: osync.Public_Key
		prim.read_fixed(&r, rp[:])
		proof := prim.read_bytes(&r)
		if !prim.reader_ok(&r) {
			return spaces, .Invalid
		}
		space_join_enrollment(e, id, proof, name, relay, rp) or_return
		space_open(e, id)
		spaces += 1
	}
	_lease_arm(e)
	return spaces, .None
}

@(private)
_pool_reseal :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership) {
	if sp.mem.me != .Pool {
		return
	}
	now := _now_ms(e)
	cur := osync.membership_current(m, now)
	if cur == nil {
		return
	}
	ei := osync.roster_epoch(&m.roster, cur.id)
	if ei < 0 {
		return
	}
	epos := _order_pos(m, m.roster.epochs[ei].record)
	raws := make([dynamic][]u8, context.temp_allocator)
	for i in 0 ..< len(m.roster.members) {
		x := m.roster.members[i]
		if x.kind != .Runner || x.added_by != e.identity.sign || !osync.member_active(&x, now) {
			continue
		}
		ai, ok := m.ids[x.added]
		if ok && _order_pos(m, ai) > epos {
			continue
		}
		sealed := false
		for s in m.roster.seals {
			if s.subject == x.sign && s.epoch == cur.id {
				sealed = true
			}
		}
		if sealed {
			continue
		}
		raw, err := osync.membership_seal(m, osync.keyring_member_signer(&e.keyring), osync.identity_of(x.sign, x.box), now, now, e.cfg.random)
		if err != .None {
			continue
		}
		c := make([]u8, len(raw), context.temp_allocator)
		copy(c, raw)
		append(&raws, c)
	}
	if len(raws) > 0 {
		_members_emit(e, sp, m, raws[:])
	}
}

@(private)
_order_pos :: proc(m: ^osync.Membership, record: int) -> int {
	for x, i in m.roster.order {
		if x == record {
			return i
		}
	}
	return -1
}

@(private)
_lease_arm :: proc(e: ^Engine) {
	if e.loop == nil {
		return
	}
	if e.approvals.lease_timer != 0 {
		prim.timer_cancel(e.loop, e.approvals.lease_timer)
		e.approvals.lease_timer = 0
	}
	now := i64(_now_ms(e))
	next := i64(-1)
	for _, sp in e.spaces {
		if sp.keyless || sp.mem.me != .Runner || sp.mem.lease_ms == 0 || sp.mem.removed {
			continue
		}
		due := i64(sp.mem.expires) - i64(sp.mem.lease_ms) / 3
		if next < 0 || due < next {
			next = due
		}
	}
	if next < 0 {
		return
	}
	e.approvals.lease_timer = prim.timer(e.loop, max(next - now, 1), e, _on_lease)
}

@(private)
_on_lease :: proc(l: ^prim.Loop, data: rawptr) {
	e := (^Engine)(data)
	context = context_for(e)
	e.approvals.lease_timer = 0
	lease_renew(e)
}

lease_renew :: proc(e: ^Engine) -> int {
	context = context_for(e)
	n := 0
	now := _now_ms(e)
	for id in _sorted_keys(e.spaces) {
		sp := e.spaces[id]
		if sp.keyless || sp.mem.me != .Runner || sp.mem.lease_ms == 0 || sp.mem.removed {
			continue
		}
		if now + sp.mem.lease_ms / 3 < sp.mem.expires {
			continue
		}
		rc := Renew_Ctx{expires = now + sp.mem.lease_ms}
		build :: proc(e: ^Engine, sp: ^Space, m: ^osync.Membership, data: rawptr) -> ([]u8, Error) {
			c := (^Renew_Ctx)(data)
			raw, err := osync.membership_renew(m, osync.keyring_member_signer(&e.keyring), c.expires, _now_ms(e))
			return raw, _serr(err)
		}
		if _members_change(e, sp, build, &rc, false) == .None {
			n += 1
		}
	}
	_lease_arm(e)
	return n
}

@(private)
Renew_Ctx :: struct {
	expires: u64,
}

package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/prim"
import osync "../../src/sync"

@(private = "file")
TIE_ROUNDS :: 8

@(private = "file")
Tie_World :: struct {
	accused: map[int]int,
}

@(private = "file")
_tie: ^Tie_World

@(init)
_epoch_tie_init :: proc "contextless" () {
	register_world(60, _tie_init, _tie_destroy)
	register_engine_event(60, _tie_event)
}

@(private = "file")
_tie_init :: proc(w: ^World) {
	_tie = new(Tie_World, w.allocator)
	_tie.accused = make(map[int]int, w.allocator)
}

@(private = "file")
_tie_destroy :: proc(w: ^World) {
	if _tie == nil {
		return
	}
	delete(_tie.accused)
	free(_tie, w.allocator)
	_tie = nil
}

@(private = "file")
_tie_event :: proc(w: ^World, n: ^Node, ev: ^eng.Event) {
	if _tie != nil && (ev.kind == .Relay_Misbehaving || ev.kind == .Peer_Misbehaving) {
		_tie.accused[n.idx] += 1
	}
}

epoch_tie_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 3
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_epoch_tie(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_tie_epoch :: proc(n: ^Node, space: prim.Id) -> (u32, bool) {
	context = instance_context(&n.inst)
	defer node_after(n)
	st, err := eng.space_members_status(&n.e, space)
	return st.epoch, err == .None
}

@(private = "file")
_tie_write :: proc(w: ^World, n: ^Node, o: eng.Object, text: string) -> bool {
	context = instance_context(&n.inst)
	defer node_after(n)
	cur, err := eng.text_read(&n.e, o, context.temp_allocator)
	if err != .None {
		world_fail(w, "epoch tie: %s text_read before its write: %v", n.name, err)
		return false
	}
	if eerr := eng.text_edit(&n.e, o, len(cur), 0, text); eerr != .None && eerr != .Pending {
		world_fail(w, "epoch tie: %s text_edit: %v", n.name, eerr)
		return false
	}
	return true
}

@(private = "file")
_tie_sees :: proc(w: ^World, n: ^Node, o: eng.Object, want: string, ms: i64) -> bool {
	for i: i64 = 0; i < ms / 500; i += 1 {
		run_until(w, w.now + 500_000_000, false)
		context = instance_context(&n.inst)
		data, err := eng.text_read(&n.e, o, context.temp_allocator)
		node_after(n)
		if err == .None && strings.contains(string(data), want) {
			return true
		}
	}
	return false
}

@(private = "file")
_epoch_tie :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	a, b, c := w.nodes[0], w.nodes[1], w.nodes[2]
	if !node_start(a) || !node_start(b) || !node_start(c) {
		world_fail(w, "node start")
		return
	}
	space: prim.Id
	o: eng.Object
	setup: {
		context = instance_context(&a.inst)
		id, err := eng.space_create(&a.e, "tie", "relay", w.relay.public)
		if err != .None || eng.space_open(&a.e, id) != .None {
			world_fail(w, "epoch tie: space setup: %v", err)
			return
		}
		space = id
		info, _ := eng.space_info(&a.e, space)
		if info.mode != .End_To_End {
			world_fail(w, "epoch tie: the space is %v, not end to end, so the check proves nothing", info.mode)
			return
		}
		pb, berr := eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator)
		pc, cerr := eng.member_add(&a.e, space, c.identity, .Device, .Member, .Approval, 0, w.allocator)
		if berr != .None || cerr != .None {
			world_fail(w, "epoch tie: member_add: %v %v", berr, cerr)
			return
		}
		o, err = eng.text_create(&a.e, space, "tie", "base\n")
		if err != .None {
			world_fail(w, "epoch tie: text_create: %v", err)
			return
		}
		node_after(a)
		for x in ([]struct {
				n: ^Node,
				p: []u8,
			}{{b, pb}, {c, pc}}) {
			context = instance_context(&x.n.inst)
			if _, jerr := eng.space_join_enrollment(&x.n.e, space, x.p, "tie", "relay", w.relay.public); jerr != .None {
				world_fail(w, "epoch tie: %s join: %v", x.n.name, jerr)
				return
			}
			if oerr := eng.space_open(&x.n.e, space); oerr != .None {
				world_fail(w, "epoch tie: %s space_open: %v", x.n.name, oerr)
				return
			}
			node_after(x.n)
		}
	}
	if !_tie_sees(w, c, o, "base", 30_000) {
		world_fail(w, "epoch tie: the reader never read the text, so the check proves nothing")
		return
	}
	ties := 0
	for round in 0 ..< TIE_ROUNDS {
		a.partitioned = true
		for cn in a.conns {
			conn_reset(cn, true)
		}
		run_until(w, w.now + 500_000_000, false)
		rotate_b: {
			context = instance_context(&b.inst)
			defer node_after(b)
			if err := eng.space_rotate(&b.e, space); err != .None {
				world_fail(w, "epoch tie: round %d: %s rotate: %v", round, b.name, err)
				return
			}
		}
		run_until(w, w.now + 3_000_000_000, false)
		rotate_a: {
			context = instance_context(&a.inst)
			defer node_after(a)
			if err := eng.space_rotate(&a.e, space); err != .None {
				world_fail(w, "epoch tie: round %d: %s rotate while partitioned: %v", round, a.name, err)
				return
			}
		}
		ea, aok := _tie_epoch(a, space)
		eb, bok := _tie_epoch(b, space)
		if aok && bok && ea == eb {
			ties += 1
		}
		before := fmt.aprintf("before-%d\n", round, allocator = w.allocator)
		defer delete(before, w.allocator)
		if !_tie_write(w, a, o, before) {
			return
		}
		run_until(w, w.now + 500_000_000, false)
		a.partitioned = false
		if !_tie_sees(w, c, o, before, 60_000) {
			world_fail(w, "epoch tie: round %d: the reader never read what the writer wrote under its own epoch %d while cut off", round, ea)
			return
		}
		after := fmt.aprintf("after-%d\n", round, allocator = w.allocator)
		defer delete(after, w.allocator)
		if !_tie_write(w, a, o, after) {
			return
		}
		if !_tie_sees(w, c, o, after, 60_000) {
			world_fail(w, "epoch tie: round %d: the reader never read the writer's text after two admins each made epoch %d concurrently and the writer re-keyed to the one the roster chose", round, ea)
			return
		}
		run_until(w, w.now + 2_000_000_000, false)
	}
	if ties == 0 {
		world_fail(w, "epoch tie: no round produced two epochs with the same number, so the check proves nothing")
	}
	for n in ([]^Node{a, b, c}) {
		if k := _tie.accused[n.idx]; k > 0 {
			world_fail(w, "epoch tie: %s accused the relay or a peer of tampering %d times while every device was honest", n.name, k)
		}
	}
}

@(test)
epoch_tie :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := epoch_tie_run(1)
	for f in failures {
		fmt.eprintf("epoch_tie: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "epoch_tie failed")
	delete(failures)
}

@(private = "file")
TIE_GUEST_ROUNDS :: 3

@(private = "file")
Tie_Guest :: struct {
	node:   int,
	spaces: [2]prim.Id,
	tokens: [2][eng.CAPABILITY_LEN]u8,
	ok:     [2]bool,
	cc:     [2]eng.Cap_Credentials,
}

@(private = "file")
_tieg: Tie_Guest

@(private = "file")
_tieg_cfg :: proc(n: ^Node, cfg: ^eng.Config) {
	if n.idx == _tieg.node {
		cfg.credentials = eng.Credentials_Source{data = n, produce = _tieg_credentials}
	}
}

@(private = "file")
_tieg_credentials :: proc(data: rawptr, space: prim.Id) -> (osync.Credentials, bool) {
	n := (^Node)(data)
	for sid, i in _tieg.spaces {
		if _tieg.ok[i] && sid == space {
			c, err := eng.capability_credentials(&_tieg.cc[i], osync.file_keyring(&n.keyring), _tieg.tokens[i][:])
			return c, err == .None
		}
	}
	return {}, false
}

epoch_tie_guest_run :: proc(seed: u64) -> (failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 4
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	_tieg = Tie_Guest{node = 3}
	w.node_cfg = _tieg_cfg
	_epoch_tie_guest(w)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	_tieg = {}
	return
}

@(private = "file")
_tieg_current :: proc(w: ^World, nodes: []^Node, space: prim.Id) -> (tag: osync.Epoch_Tag, ok: bool) {
	for n, i in nodes {
		context = instance_context(&n.inst)
		t, has := eng.space_epoch_current(&n.e, space)
		node_after(n)
		if !has {
			return {}, false
		}
		if i == 0 {
			tag = t
		} else if t != tag {
			return {}, false
		}
	}
	return tag, true
}

@(private = "file")
_tieg_pick :: proc(g: ^Node, space: prim.Id, object: prim.Id, want: osync.Epoch_Tag) -> (pick: osync.Epoch_Tag, held: bool) {
	context = instance_context(&g.inst)
	defer node_after(g)
	for x in eng.grant_picks(&g.e, context.temp_allocator) {
		if x.space != space || x.object != object {
			continue
		}
		for t in x.tags {
			held ||= t == want
		}
		return x.pick, held
	}
	return
}

@(private = "file")
_tieg_wraps :: proc(x: ^Node, space: prim.Id, object: prim.Id, grantee: osync.Public_Key, tag: osync.Epoch_Tag) -> (n: int) {
	context = instance_context(&x.inst)
	defer node_after(x)
	for wr in eng.grant_wraps(&x.e, space, object, context.temp_allocator) {
		if wr.grantee == grantee && wr.tag == tag {
			n += 1
		}
	}
	return
}

@(private = "file")
_tieg_cut :: proc(w: ^World, n: ^Node, cut: bool) {
	n.partitioned = cut
	if cut {
		for cn in n.conns {
			conn_reset(cn, true)
		}
	}
}

@(private = "file")
Tieg_Space :: struct {
	id:     prim.Id,
	o:      eng.Object,
	senior: ^Node,
	junior: ^Node,
}

@(private = "file")
_tieg_space :: proc(w: ^World, o, first, second, g: ^Node, slot: int) -> (ts: Tieg_Space, ok: bool) {
	share: eng.Share
	setup: {
		context = instance_context(&o.inst)
		defer node_after(o)
		id, err := eng.space_create(&o.e, fmt.tprintf("tie-guest-%d", slot), "relay", w.relay.public)
		if err != .None || eng.space_open(&o.e, id) != .None {
			world_fail(w, "epoch tie guest: space setup: %v", err)
			return
		}
		ts.id = id
		p1, e1 := eng.member_add(&o.e, id, first.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if e1 != .None {
			world_fail(w, "epoch tie guest: member_add %s: %v", first.name, e1)
			return
		}
		run_until(w, w.now + 1_000_000_000, false)
		context = instance_context(&o.inst)
		p2, e2 := eng.member_add(&o.e, id, second.identity, .Device, .Admin, .Approval, 0, w.allocator)
		if e2 != .None {
			world_fail(w, "epoch tie guest: member_add %s: %v", second.name, e2)
			return
		}
		ts.o, err = eng.text_create(&o.e, id, "granted", "base\n")
		if err != .None {
			world_fail(w, "epoch tie guest: text_create: %v", err)
			return
		}
		s, serr := eng.share_object(&o.e, ts.o, g.identity, {.Read})
		tok, terr := eng.capability_issue(&o.e, eng.Capability{space = id, grantee = g.identity.id, object = ts.o.id, kind = .Text, access = {.Read}}, context.temp_allocator)
		if serr != .None || terr != .None {
			world_fail(w, "epoch tie guest: share %v capability %v", serr, terr)
			return
		}
		share = s
		copy(_tieg.tokens[slot][:], tok)
		_tieg.spaces[slot] = id
		_tieg.ok[slot] = true
		for x in ([]struct {
				n: ^Node,
				p: []u8,
			}{{first, p1}, {second, p2}}) {
			context = instance_context(&x.n.inst)
			if _, jerr := eng.space_join_enrollment(&x.n.e, id, x.p, "tie-guest", "relay", w.relay.public); jerr != .None {
				node_after(x.n)
				world_fail(w, "epoch tie guest: %s join: %v", x.n.name, jerr)
				return
			}
			eng.space_open(&x.n.e, id)
			node_after(x.n)
		}
	}
	accept: {
		context = instance_context(&g.inst)
		defer node_after(g)
		if jerr := eng.space_join_shared(&g.e, ts.id, "guest", "relay", w.relay.public); jerr != .None {
			world_fail(w, "epoch tie guest: guest join: %v", jerr)
			return
		}
		eng.space_open(&g.e, ts.id)
		if aerr := eng.accept_share(&g.e, share); aerr != .None {
			world_fail(w, "epoch tie guest: accept_share: %v", aerr)
			return
		}
	}
	ts.senior, ts.junior = first, second
	return ts, true
}

@(private = "file")
_epoch_tie_guest :: proc(w: ^World) {
	if !relay_start(&w.relay) {
		world_fail(w, "relay start")
		return
	}
	o, b, d, g := w.nodes[0], w.nodes[1], w.nodes[2], w.nodes[3]
	if !node_start(o) || !node_start(b) || !node_start(d) || !node_start(g) {
		world_fail(w, "node start")
		return
	}
	spaces: [2]Tieg_Space
	ok: bool
	if spaces[0], ok = _tieg_space(w, o, b, d, g, 0); !ok {
		return
	}
	if spaces[1], ok = _tieg_space(w, o, d, b, g, 1); !ok {
		return
	}
	run_until(w, w.now + 10_000_000_000, false)
	_tieg_cut(w, o, true)
	run_until(w, w.now + 5_000_000_000, false)
	admins := []^Node{b, d}
	proven := 0
	ties := 0
	for &ts in spaces {
		sen, jun := ts.senior, ts.junior
		for round in 0 ..< TIE_GUEST_ROUNDS {
			_tieg_cut(w, jun, true)
			run_until(w, w.now + 500_000_000, false)
			rotate_s: {
				context = instance_context(&sen.inst)
				defer node_after(sen)
				if err := eng.space_rotate(&sen.e, ts.id); err != .None {
					world_fail(w, "epoch tie guest: round %d: %s rotate: %v", round, sen.name, err)
					return
				}
			}
			run_until(w, w.now + 3_000_000_000, false)
			grow: {
				context = instance_context(&sen.inst)
				defer node_after(sen)
				extra, xerr := eng.text_create(&sen.e, ts.id, "extra", "")
				if xerr != .None {
					world_fail(w, "epoch tie guest: round %d: extra text_create: %v", round, xerr)
					return
				}
				if _, serr := eng.share_object(&sen.e, extra, g.identity, {.Read}); serr != .None {
					world_fail(w, "epoch tie guest: round %d: extra share: %v", round, serr)
					return
				}
			}
			run_until(w, w.now + 3_000_000_000, false)
			rotate_j: {
				context = instance_context(&jun.inst)
				defer node_after(jun)
				if err := eng.space_rotate(&jun.e, ts.id); err != .None {
					world_fail(w, "epoch tie guest: round %d: %s rotate while cut off: %v", round, jun.name, err)
					return
				}
			}
			es, sok := _tie_epoch(sen, ts.id)
			ej, jok := _tie_epoch(jun, ts.id)
			if sok && jok && es == ej {
				ties += 1
			}
			jtag: osync.Epoch_Tag
			jtag_ok: {
				context = instance_context(&jun.inst)
				defer node_after(jun)
				jtag, _ = eng.space_epoch_current(&jun.e, ts.id)
			}
			run_until(w, w.now + 2_000_000_000, false)
			pre := _tieg_wraps(jun, ts.id, ts.o.id, g.identity.sign, jtag)
			_tieg_cut(w, jun, false)
			run_until(w, w.now + 20_000_000_000, false)
			cur, agreed := _tieg_current(w, admins, ts.id)
			if !agreed {
				world_fail(w, "epoch tie guest: round %d: the admins do not agree on a current epoch after the heal", round)
				return
			}
			pick: osync.Epoch_Tag
			held := false
			for i := 0; i < 60 && !held; i += 1 {
				pick, held = _tieg_pick(g, ts.id, ts.o.id, cur)
				if !held {
					run_until(w, w.now + 500_000_000, false)
				}
			}
			if !held {
				world_fail(w, "epoch tie guest: round %d: the guest never received the admins' current epoch %x", round, cur)
				return
			}
			if pick != cur {
				world_fail(w, "epoch tie guest: round %d: after two admins made epoch %d concurrently the guest picks %x, the admins' current is %x", round, es, pick, cur)
			}
			if cur == jtag && pre > 0 && _tieg_wraps(jun, ts.id, ts.o.id, g.identity.sign, jtag) > pre {
				proven += 1
			}
			run_until(w, w.now + 2_000_000_000, false)
		}
	}
	if ties == 0 {
		world_fail(w, "epoch tie guest: no round produced two epochs with the same number, so the check proves nothing")
	}
	if proven == 0 {
		world_fail(w, "epoch tie guest: no round had the elected admin re-wrap its own winning epoch after a heal, so the check proves nothing")
	}
}

@(test)
epoch_tie_guest :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	failures := epoch_tie_guest_run(1)
	for f in failures {
		fmt.eprintf("epoch_tie_guest: %s\n", f)
		delete(f)
	}
	testing.expect(t, len(failures) == 0, "epoch_tie_guest failed")
	delete(failures)
}

package sim

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import eng "../../src/engine"
import "../../src/crdt"
import "../../src/prim"

@(private = "file")
Ril_Result :: struct {
	crashed: bool,
	shown:   bool,
	lost:    int,
	changed: int,
	stale:   bool,
}

@(private = "file")
Ril_Peer :: enum {
	Watch,
	Type,
	Type_Inside,
	Type_Inside_Now,
	Delete_Inside,
	Delete_Inside_Now,
	Delete_Stale,
}

@(private = "file")
Ril_Buffer :: struct {
	info: eng.Buffer_Info,
	rev:  u64,
}

@(private = "file")
_ril_cb :: proc(data: rawptr, e: ^eng.Engine, ev: ^eng.Buffer_Event) {
	b := (^Ril_Buffer)(data)
	if ev.kind == .Delta {
		b.rev = ev.rev
	}
}

@(private = "file")
_ril_open :: proc(w: ^World, n: ^Node, o: eng.Object, actor: prim.Id, b: ^Ril_Buffer) -> bool {
	for _ in 0 ..< 40 {
		err: eng.Error
		{
			context = instance_context(&n.inst)
			b.info, err = eng.buffer_open(&n.e, o, eng.Buffer_Options{units = .Bytes, actor = actor, cb = _ril_cb, data = b}, w.allocator)
			node_after(n)
		}
		if err == .None {
			b.rev = b.info.rev
			return true
		}
		run_until(w, w.now + 1_000_000_000, true)
		if !reissue_going(w) || !n.alive {
			break
		}
	}
	return false
}

@(private = "file")
_ril_edit :: proc(n: ^Node, b: ^Ril_Buffer, rev: u64, pos, del: int, ins: string, held: bool) -> eng.Error {
	context = instance_context(&n.inst)
	ready := eng.Ready{}
	if held {
		ready.call = proc(data: rawptr, e: ^eng.Engine, err: eng.Error) {}
	}
	_, _, err := eng.buffer_edit(&n.e, b.info.id, rev, []eng.Buffer_Edit{{pos, del, transmute([]u8)ins}}, 0, ready)
	return err
}

@(private = "file")
_ril_shown :: proc(w: ^World, n: ^Node, b: ^Ril_Buffer) -> string {
	context = instance_context(&n.inst)
	data, _, err := eng.buffer_text(&n.e, b.info.id, context.temp_allocator)
	if err != .None {
		return fmt.aprintf("<%v>", err, allocator = w.allocator)
	}
	return strings.clone(string(data), w.allocator)
}

@(private = "file")
_ril_case :: proc(seed: u64, k: u64, peer: Ril_Peer) -> (res: Ril_Result, failures: [dynamic]string) {
	failures = make([dynamic]string)
	cfg := default_config(seed)
	cfg.nodes = 2
	cfg.spaces = 0
	cfg.ops = 0
	cfg.crash_rate = 0
	cfg.fault_rate = 0
	cfg.io_rate = 0
	cfg.byzantine = false
	cfg.bulk = false
	cfg.durability = .Async
	cfg.mem_max = 1500
	cfg.verbose = env_u64("SIM_VERBOSE", 0) != 0
	w := new(World)
	world_init(w, cfg)
	w.node_cfg = reissue_hold
	res = _ril_run(w, k, peer)
	for f in w.failures {
		append(&failures, fmt.aprintf("%s", f))
	}
	world_destroy(w)
	free(w)
	return
}

@(private = "file")
_ril_text :: proc(w: ^World, n: ^Node, o: eng.Object) -> string {
	context = instance_context(&n.inst)
	defer node_after(n)
	data, err := eng.text_read(&n.e, o, context.temp_allocator)
	if err != .None {
		return fmt.aprintf("<%v>", err, allocator = w.allocator)
	}
	return strings.clone(string(data), w.allocator)
}

@(private = "file")
_ril_run :: proc(w: ^World, k: u64, peer: Ril_Peer) -> (res: Ril_Result) {
	if !relay_start(&w.relay) {
		world_fail(w, "reissue live: relay start")
		return
	}
	a, b := w.nodes[0], w.nodes[1]
	if !node_start(a) || !node_start(b) {
		world_fail(w, "reissue live: node start")
		return
	}
	space: prim.Id
	text: eng.Object
	proof: []u8
	{
		context = instance_context(&a.inst)
		defer node_after(a)
		err: eng.Error
		if space, err = eng.space_create(&a.e, "reissue-live", "relay", w.relay.public); err != .None {
			world_fail(w, "reissue live: space_create: %v", err)
			return
		}
		if err = eng.space_open(&a.e, space); err != .None {
			world_fail(w, "reissue live: space_open: %v", err)
			return
		}
		if text, err = eng.text_create(&a.e, space, "notes", "base\n"); err != .None {
			world_fail(w, "reissue live: text_create: %v", err)
			return
		}
		if proof, err = eng.member_add(&a.e, space, b.identity, .Device, .Admin, .Approval, 0, w.allocator); err != .None {
			world_fail(w, "reissue live: member_add: %v", err)
			return
		}
	}
	{
		context = instance_context(&b.inst)
		defer node_after(b)
		if _, err := eng.space_join_enrollment(&b.e, space, proof, "reissue-live", "relay", w.relay.public); err != .None {
			world_fail(w, "reissue live: space_join_enrollment: %v", err)
			return
		}
		if err := eng.space_open(&b.e, space); err != .None {
			world_fail(w, "reissue live: n1 space_open: %v", err)
			return
		}
	}
	run_until(w, w.now + 20_000_000_000, true)
	actors: [2]prim.Id
	for &x in actors {
		x = prim.id_new_with(node_clock(&b.clock), rng_random(&w.rng))
	}
	ba, bb: Ril_Buffer
	if !_ril_open(w, a, text, actors[0], &ba) || !_ril_open(w, b, text, actors[1], &bb) {
		world_fail(w, "reissue live: buffers did not open")
		return
	}
	run_until(w, w.now + 5_000_000_000, true)
	if err := _ril_edit(b, &bb, bb.rev, 0, 0, "warm ", false); err != .None {
		world_fail(w, "reissue live: n1 first edit: %v", err)
		return
	}
	node_after(b)
	run_until(w, w.now + 20_000_000_000, true)
	if err := _ril_edit(a, &ba, ba.rev, len("warm base\n"), 0, "peer\n", false); err != .None {
		world_fail(w, "reissue live: n0 first edit: %v", err)
		return
	}
	node_after(a)
	run_until(w, w.now + 20_000_000_000, true)
	if x, y := _ril_shown(w, a, &ba), _ril_shown(w, b, &bb); x != "warm base\npeer\n" || y != x {
		world_fail(w, "reissue live: the buffers did not converge before the crash: %q and %q", x, y)
		return
	}
	seen := make([dynamic]Reissue_Batch, w.allocator)
	crashes := w.stats.crashes
	b.disk.crash_at = b.disk.stats.ops + k
	if err := _ril_edit(b, &bb, bb.rev, 0, 0, "LOSTLOST ", false); err != .None && !b.disk.dead {
		world_fail(w, "reissue live: n1 edit before the crash: %v", err)
		return
	}
	reissue_see(w, b, text, &seen, true)
	node_after(b)
	for limit := w.now + 1_500_000_000; w.now < limit && reissue_going(w) && !res.shown; {
		t, ok := next_time(w)
		if !ok || t > limit {
			break
		}
		run_until(w, t, false)
		reissue_see(w, b, text, &seen, true)
		context = instance_context(&a.inst)
		res.shown = eng.buffer_overlay(&a.e, ba.info.id) > 0 && strings.contains(_ril_shown(w, a, &ba), "LOSTLOST")
	}
	anchors: []crdt.Anchor
	peer_text := ""
	old := ba.rev
	if res.shown {
		{
			context = instance_context(&a.inst)
			aerr: eng.Error
			anchors, aerr = eng.buffer_anchors(&a.e, ba.info.id, ba.rev, []int{4}, .Before, w.allocator)
			if aerr != .None {
				world_fail(w, "reissue live: buffer_anchors: %v", aerr)
				return
			}
		}
		err := eng.Error.None
		switch peer {
		case .Watch:
		case .Type:
			peer_text = "near"
			err = _ril_edit(a, &ba, ba.rev, len("LOSTLOST warm base\npeer\n"), 0, peer_text, true)
		case .Type_Inside, .Type_Inside_Now:
			peer_text = "near"
			err = _ril_edit(a, &ba, ba.rev, 4, 0, peer_text, peer == .Type_Inside)
		case .Delete_Inside, .Delete_Inside_Now:
			err = _ril_edit(a, &ba, ba.rev, 2, 4, "", peer == .Delete_Inside)
		case .Delete_Stale:
		}
		if err != .None {
			if err != .Pending && err != .Busy {
				world_fail(w, "reissue live: n0 edit (%v): %v", peer, err)
				return
			}
			peer_text = ""
		}
		node_after(a)
	}
	reissue_watch(w, b, text, &seen, w.now + 6_000_000_000, true)
	b.disk.crash_at = 0
	res.crashed = w.stats.crashes > crashes
	if !reissue_restarted(w, b) {
		world_fail(w, "reissue live: n1 did not restart after the crash at op %d", k)
		return
	}
	if peer == .Delete_Stale && res.shown {
		run_until(w, w.now + 500_000_000, false)
		if err := _ril_edit(a, &ba, old, 2, 4, "", true); err == .None {
			res.stale = !strings.contains(_ril_shown(w, a, &ba), "LOST")
		} else if err != .Pending && err != .Busy && err != .Conflict {
			world_fail(w, "reissue live: n0 stale edit: %v", err)
			return
		}
		node_after(a)
	}
	if res.crashed {
		if !_ril_open(w, b, text, actors[1], &bb) {
			world_fail(w, "reissue live: n1's buffer did not open again")
			return
		}
		if err := _ril_edit(b, &bb, bb.rev, 0, 0, "NEWERTEXT ", false); err != .None {
			world_fail(w, "reissue live: n1 edit after the crash: %v", err)
			return
		}
		node_after(b)
	}
	run_until(w, w.now + 30_000_000_000, true)
	what := fmt.tprintf("reissue live %v: crash at op %d", peer, k)
	ta, tb := _ril_text(w, a, text), _ril_text(w, b, text)
	if ta != tb {
		world_fail(w, "%s: n0 holds %q but n1 holds %q", what, ta, tb)
	}
	if x, y := _ril_shown(w, a, &ba), _ril_shown(w, b, &bb); x != ta || y != tb {
		world_fail(w, "%s: the buffers show %q and %q but the text is %q", what, x, y, ta)
	}
	if res.crashed && strings.count(ta, "NEWERTEXT ") != 1 {
		world_fail(w, "%s: n1's edit after the crash appears %d times in %q", what, strings.count(ta, "NEWERTEXT "), ta)
	}
	if len(peer_text) > 0 && strings.count(ta, peer_text) != 1 {
		world_fail(w, "%s: n0's edit appears %d times in %q", what, strings.count(ta, peer_text), ta)
	}
	res.lost, res.changed = reissue_settle(w, what, a, b, text, seen[:], true)
	if len(anchors) == 1 && res.lost > 0 && !strings.contains(ta, "LOST") {
		context = instance_context(&a.inst)
		at, _, _, err := eng.buffer_resolve(&a.e, ba.info.id, ba.rev, anchors, context.temp_allocator)
		if err == .None && len(at) == 1 && at[0] >= 0 {
			world_fail(w, "%s: an anchor in the lost text %v resolves to %d in %q", what, anchors[0], at[0], ta)
		}
	}
	if res.shown && res.changed > 0 {
		world_fail(w, "%s: %d batches n0 was shown and n1 lost were re-issued with other operations", what, res.changed)
	}
	check_uploaded(w)
	check_derived(a, fmt.tprintf("%s, n0", what))
	check_derived(b, fmt.tprintf("%s, n1", what))
	return
}

@(test)
reissue_live_crash :: proc(t: ^testing.T) {
	if s, ok := os.lookup_env("SIM_SEED", context.temp_allocator); ok && len(s) > 0 {
		return
	}
	test_begin(t)
	defer test_end(t)
	for peer in Ril_Peer {
		points, shown, lost := 0, 0, 0
		for k := u64(1); k < 2000; k += 1 {
			res, failures := _ril_case(1, k, peer)
			for f in failures {
				fmt.eprintf("reissue_live_crash %v crash %d: %s\n", peer, k, f)
				delete(f)
			}
			testing.expectf(t, len(failures) == 0, "reissue_live_crash %v crash at op %d failed", peer, k)
			n := len(failures)
			delete(failures)
			if !res.crashed || n > 0 {
				break
			}
			points += 1
			shown += 1 if res.shown else 0
			lost += 1 if res.shown && res.lost > 0 else 0
		}
		testing.expectf(t, lost > 0, "reissue_live_crash %v never lost a batch a peer had been shown", peer)
		fmt.eprintf("reissue_live_crash %v: %d crash points, %d shown live before durability, %d of those lost\n", peer, points, shown, lost)
	}
	free_all(context.temp_allocator)
}
